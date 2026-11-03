// CoreText + CoreGraphics text backend for pi-desk (macOS). Called from
// src/text_coretext.odin; the platform-neutral atlas, caches and drawing are
// in src/font.odin.
//
// Faces live in one table and are addressed by index. Fallback fonts that
// CoreText picks while shaping (emoji, CJK, symbols) are added to the same
// table, so glyph caches can key on (face, glyph).
//
// Everything here runs on the main thread, and only on glyph-cache misses.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

typedef struct {
	float ascent, descent, leading; // px, descent positive
	float advance;                  // advance of 'M' (cell width for monospace)
	float cap_height, x_height;
	float underline_pos;            // px below the baseline (positive = down)
	float underline_thickness;
	int color;                      // colour glyphs (emoji)
} pd_metrics;

typedef struct {
	int32_t face;
	uint32_t glyph;
	float x, y;    // pen position of this glyph from the run origin (y down)
	float advance;
	int32_t cluster; // byte offset into the UTF-8 input
} pd_glyph;

typedef struct {
	CTFontRef font;
	int color;
	int synth_bold; // the family has no bold: stroke the outline
} face_t;

#define MAX_FACES 256
static face_t faces[MAX_FACES];
static int nfaces;

static int add_face(CTFontRef f, int synth_bold) {
	for (int i = 0; i < nfaces; i++) {
		if (faces[i].synth_bold == synth_bold && CFEqual(faces[i].font, f)) return i;
	}
	if (nfaces == MAX_FACES) return 0; // table full: draw with the first face
	CFRetain(f);
	faces[nfaces].font = f;
	faces[nfaces].color = (CTFontGetSymbolicTraits(f) & kCTFontTraitColorGlyphs) != 0;
	faces[nfaces].synth_bold = synth_bold;
	return nfaces++;
}

#define SEMIBOLD 0.3 // kCTFontWeightTrait of a semibold face (AppKit's NSFontWeightSemibold)

static int family_is(CTFontRef f, CFStringRef want) {
	CFStringRef fam = CTFontCopyFamilyName(f);
	int ok = fam && CFStringCompare(fam, want, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
	if (fam) CFRelease(fam);
	return ok;
}

// Opens `family` (UTF-8; "" = the system UI font, "ui-monospace" = the
// system monospaced font) at px pixels. traits: 1 bold, 2 italic, or 4
// semibold (alone). Missing bold is synthesised (stroke); missing italic is
// synthesised with a skew. Returns the face index, or -1 if the family is not
// installed or (semibold) has no semibold weight.
int pd_face_open(const char *family, int len, double px, int traits) {
	CTFontRef base = NULL;
	if (len == 0) {
		base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, px, NULL);
	} else {
		CFStringRef name = CFStringCreateWithBytes(NULL, (const UInt8 *)family, len, kCFStringEncodingUTF8, false);
		if (!name) return -1;
		if (CFStringCompare(name, CFSTR("ui-monospace"), 0) == kCFCompareEqualTo) {
			// SF Mono: not addressable by family name outside Apple apps
			base = CTFontCreateWithName(CFSTR(".AppleSystemUIFontMonospaced-Regular"), px, NULL);
			if (base && !(CTFontGetSymbolicTraits(base) & kCTFontTraitMonoSpace)) {
				CFRelease(base);
				base = NULL;
			}
		} else {
			const void *k[] = {kCTFontFamilyNameAttribute};
			const void *v[] = {name};
			CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
			CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(attrs);
			base = CTFontCreateWithFontDescriptor(d, px, NULL);
			CFRelease(d);
			CFRelease(attrs);
			if (base && !family_is(base, name)) { // CoreText substitutes silently
				CFRelease(base);
				base = NULL;
			}
		}
		CFRelease(name);
	}
	if (!base) return -1;

	CTFontRef f = base;
	int synth_bold = 0;
	if (traits == 4) {
		// the same family at semibold weight (SF Pro has it; families without
		// one come back lighter: the caller uses bold instead)
		CGFloat weight = SEMIBOLD;
		CFNumberRef w = CFNumberCreate(NULL, kCFNumberCGFloatType, &weight);
		const void *tk[] = {kCTFontWeightTrait};
		const void *tv[] = {w};
		CFDictionaryRef td = CFDictionaryCreate(NULL, tk, tv, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		const void *ak[] = {kCTFontTraitsAttribute};
		const void *av[] = {td};
		CFDictionaryRef ad = CFDictionaryCreate(NULL, ak, av, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(ad);
		CTFontRef v = CTFontCreateCopyWithAttributes(base, px, NULL, d);
		CFRelease(d);
		CFRelease(ad);
		CFRelease(td);
		CFRelease(w);
		CFRelease(base);
		if (!v) return -1;
		CGFloat got = 0;
		CFDictionaryRef tr = CTFontCopyTraits(v);
		if (tr) {
			CFNumberRef n = CFDictionaryGetValue(tr, kCTFontWeightTrait);
			if (n) CFNumberGetValue(n, kCFNumberCGFloatType, &got);
			CFRelease(tr);
		}
		if (got < SEMIBOLD - 0.05 || got > SEMIBOLD + 0.05) {
			CFRelease(v);
			return -1;
		}
		int id = add_face(v, 0);
		CFRelease(v);
		return id;
	}
	if (traits) {
		CTFontSymbolicTraits want = 0;
		if (traits & 1) want |= kCTFontTraitBold;
		if (traits & 2) want |= kCTFontTraitItalic;
		CTFontRef v = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, want, want);
		if (!v && (traits & 3) == 3) { // no bold italic: italic + stroke
			v = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, kCTFontTraitItalic, kCTFontTraitItalic);
			if (v) synth_bold = 1;
		}
		if (!v && (traits & 2)) { // no italic: skew the upright face
			CGAffineTransform skew = CGAffineTransformMake(1, 0, 0.2, 1, 0, 0);
			CTFontRef src = base;
			CTFontRef b = NULL;
			if (traits & 1) b = CTFontCreateCopyWithSymbolicTraits(base, 0, NULL, kCTFontTraitBold, kCTFontTraitBold);
			if (b) src = b; else if (traits & 1) synth_bold = 1;
			v = CTFontCreateCopyWithAttributes(src, px, &skew, NULL);
			if (b) CFRelease(b);
		}
		if (!v) { // no bold: stroke the regular face
			v = (CTFontRef)CFRetain(base);
			synth_bold = 1;
		}
		f = v;
		CFRelease(base);
	}
	int id = add_face(f, synth_bold);
	CFRelease(f);
	return id;
}

void pd_face_metrics(int face, pd_metrics *m) {
	CTFontRef f = faces[face].font;
	m->ascent = CTFontGetAscent(f);
	m->descent = CTFontGetDescent(f);
	m->leading = CTFontGetLeading(f);
	m->cap_height = CTFontGetCapHeight(f);
	m->x_height = CTFontGetXHeight(f);
	m->underline_pos = -CTFontGetUnderlinePosition(f);
	m->underline_thickness = CTFontGetUnderlineThickness(f);
	m->color = faces[face].color;
	UniChar ch = 'M';
	CGGlyph g = 0;
	CGSize adv = {0, 0};
	if (CTFontGetGlyphsForCharacters(f, &ch, &g, 1)) CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &g, &adv, 1);
	m->advance = adv.width;
}

int pd_face_is_color(int face) { return faces[face].color; }

// Shapes UTF-8 text with `face` (CoreText applies the system fallback
// cascade, kerning, and emoji sequences). ligatures: 0 off, 1 standard.
// Writes up to cap glyphs; returns the glyph count (may exceed cap: then
// only cap were written) and the total advance in *width.
int pd_shape(int face, const char *text, int len, int ligatures, pd_glyph *out, int cap, float *width) {
	*width = 0;
	if (len <= 0) return 0;
	CFStringRef s = CFStringCreateWithBytes(NULL, (const UInt8 *)text, len, kCFStringEncodingUTF8, false);
	if (!s) return 0;

	// UTF-16 index -> UTF-8 byte offset
	CFIndex n16 = CFStringGetLength(s);
	int32_t stackmap[256];
	int32_t *map = n16 + 1 <= 256 ? stackmap : malloc(sizeof(int32_t) * (n16 + 1));
	{
		CFIndex u = 0;
		for (int i = 0; i < len && u <= n16;) {
			unsigned char c = (unsigned char)text[i];
			int bytes = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
			map[u++] = i;
			if (bytes == 4 && u <= n16) map[u++] = i; // surrogate pair
			i += bytes;
		}
		while (u <= n16) map[u++] = len;
	}

	int lig = ligatures;
	CFNumberRef ligv = CFNumberCreate(NULL, kCFNumberIntType, &lig);
	const void *k[] = {kCTFontAttributeName, kCTLigatureAttributeName};
	const void *v[] = {faces[face].font, ligv};
	CFDictionaryRef attrs = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFAttributedStringRef as = CFAttributedStringCreate(NULL, s, attrs);
	CTLineRef line = CTLineCreateWithAttributedString(as);

	int count = 0;
	CFArrayRef runs = CTLineGetGlyphRuns(line);
	CFIndex nruns = CFArrayGetCount(runs);
	for (CFIndex r = 0; r < nruns; r++) {
		CTRunRef run = CFArrayGetValueAtIndex(runs, r);
		CFDictionaryRef ra = CTRunGetAttributes(run);
		CTFontRef rf = CFDictionaryGetValue(ra, kCTFontAttributeName);
		int fid = face;
		if (rf && !CFEqual(rf, faces[face].font)) fid = add_face(rf, 0);
		CFIndex ng = CTRunGetGlyphCount(run);
		for (CFIndex i = 0; i < ng; i++, count++) {
			if (count >= cap) continue;
			CGGlyph g;
			CGPoint p;
			CGSize a;
			CFIndex si;
			CTRunGetGlyphs(run, CFRangeMake(i, 1), &g);
			CTRunGetPositions(run, CFRangeMake(i, 1), &p);
			CTRunGetAdvances(run, CFRangeMake(i, 1), &a);
			CTRunGetStringIndices(run, CFRangeMake(i, 1), &si);
			out[count].face = fid;
			out[count].glyph = g;
			out[count].x = p.x;
			out[count].y = -p.y;
			out[count].advance = a.width;
			out[count].cluster = si <= n16 ? map[si] : len;
		}
	}
	*width = (float)CTLineGetTypographicBounds(line, NULL, NULL, NULL);

	CFRelease(line);
	CFRelease(as);
	CFRelease(attrs);
	CFRelease(ligv);
	CFRelease(s);
	if (map != stackmap) free(map);
	return count;
}

static float stroke_width(CTFontRef f) { return (float)fmax(0.5, CTFontGetSize(f) / 28.0); }

// Pixel box of a glyph drawn at `scale` with its origin shifted right by
// subx (0..1): x0 from the pen position, y0 from the baseline (down is
// positive, so y0 is usually negative). Padded by one pixel for AA.
void pd_glyph_box(int face, uint32_t glyph, float scale, float subx, int *x0, int *y0, int *w, int *h) {
	CTFontRef f = faces[face].font;
	CGGlyph g = (CGGlyph)glyph;
	CGRect r = CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, &g, NULL, 1);
	if (CGRectIsEmpty(r) || r.size.width <= 0 || r.size.height <= 0) {
		*x0 = *y0 = *w = *h = 0;
		return;
	}
	float pad = 1 + (faces[face].synth_bold ? stroke_width(f) * scale : 0);
	int left = (int)floorf(r.origin.x * scale + subx - pad);
	int right = (int)ceilf((r.origin.x + r.size.width) * scale + subx + pad);
	int top = (int)ceilf((r.origin.y + r.size.height) * scale + pad);
	int bottom = (int)floorf(r.origin.y * scale - pad);
	*x0 = left;
	*y0 = -top;
	*w = right - left;
	*h = top - bottom;
}

// Rasterises a glyph into dst (RGBA8, w x h, stride bytes per row, rows
// top-down), using the box from pd_glyph_box. Monochrome glyphs come out as
// white with coverage in alpha; colour glyphs as straight (not
// premultiplied) RGBA. thicken: CoreText font smoothing (heavier strokes,
// like Terminal.app). Returns 1 for a colour glyph.
int pd_glyph_render(int face, uint32_t glyph, float scale, float subx, int x0, int y0, int w, int h, uint8_t *dst, int stride, int thicken) {
	if (w <= 0 || h <= 0) return 0;
	face_t *fc = &faces[face];
	int color = fc->color;
	uint8_t *buf = calloc((size_t)w * h, color ? 4 : 1);
	CGColorSpaceRef cs = color ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray();
	CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, color ? w * 4 : w, cs,
		color ? (kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : kCGImageAlphaNone);
	CGColorSpaceRelease(cs);
	if (!ctx) {
		free(buf);
		return 0;
	}
	CGContextSetAllowsAntialiasing(ctx, true);
	CGContextSetShouldAntialias(ctx, true);
	CGContextSetAllowsFontSmoothing(ctx, true);
	CGContextSetShouldSmoothFonts(ctx, thicken ? true : false);
	CGContextSetAllowsFontSubpixelPositioning(ctx, true);
	CGContextSetShouldSubpixelPositionFonts(ctx, true);
	CGContextSetAllowsFontSubpixelQuantization(ctx, false);
	CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
	if (color) CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
	else CGContextSetGrayFillColor(ctx, 1, 1);
	if (fc->synth_bold) {
		CGContextSetTextDrawingMode(ctx, kCGTextFillStroke);
		CGContextSetLineWidth(ctx, stroke_width(fc->font));
		if (color) CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
		else CGContextSetGrayStrokeColor(ctx, 1, 1);
	}
	// CG's origin is the bottom-left pixel. The box spans y0 .. y0+h below the
	// baseline (down positive), so the baseline is y0+h px above the bottom.
	CGContextScaleCTM(ctx, scale, scale);
	CGPoint pos = {(subx - x0) / scale, (y0 + h) / scale};
	CGGlyph g = (CGGlyph)glyph;
	CTFontDrawGlyphs(fc->font, &g, &pos, 1, ctx);
	CGContextFlush(ctx);

	for (int y = 0; y < h; y++) {
		uint8_t *row = dst + (size_t)y * stride;
		for (int x = 0; x < w; x++) {
			uint8_t *o = row + x * 4;
			if (color) {
				uint8_t *p = buf + ((size_t)y * w + x) * 4;
				uint8_t a = p[3];
				if (a == 0) {
					o[0] = o[1] = o[2] = o[3] = 0;
				} else {
					o[0] = (uint8_t)(p[0] * 255 / a > 255 ? 255 : p[0] * 255 / a);
					o[1] = (uint8_t)(p[1] * 255 / a > 255 ? 255 : p[1] * 255 / a);
					o[2] = (uint8_t)(p[2] * 255 / a > 255 ? 255 : p[2] * 255 / a);
					o[3] = a;
				}
			} else {
				o[0] = o[1] = o[2] = 255;
				o[3] = buf[(size_t)y * w + x];
			}
		}
	}
	CGContextRelease(ctx);
	free(buf);
	return color;
}
