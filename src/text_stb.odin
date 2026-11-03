#+build !darwin
package main

// Text backend for Linux/Windows until they get their own (FreeType +
// HarfBuzz + fontconfig on Linux, DirectWrite on Windows): stb_truetype with
// fixed font paths, one glyph per codepoint (no shaping, no ligatures),
// fallback by walking a fixed list, no colour glyphs. Same interface as
// text_coretext.odin.

import "core:c"
import "core:os"
import "core:unicode/utf8"

foreign import stb "../build/stb_truetype.a"

Stbtt_Fontinfo :: struct #align (8) {
	_: [160]u8, // sizeof(stbtt_fontinfo) on 64-bit, checked once with clang
}

@(default_calling_convention = "c", link_prefix = "stbtt_")
foreign stb {
	GetFontOffsetForIndex :: proc(data: [^]u8, index: c.int) -> c.int ---
	InitFont :: proc(info: ^Stbtt_Fontinfo, data: [^]u8, offset: c.int) -> c.int ---
	ScaleForPixelHeight :: proc(info: ^Stbtt_Fontinfo, pixels: f32) -> f32 ---
	GetFontVMetrics :: proc(info: ^Stbtt_Fontinfo, ascent, descent, line_gap: ^c.int) ---
	FindGlyphIndex :: proc(info: ^Stbtt_Fontinfo, codepoint: c.int) -> c.int ---
	GetGlyphHMetrics :: proc(info: ^Stbtt_Fontinfo, glyph: c.int, advance, lsb: ^c.int) ---
	GetGlyphBitmapBoxSubpixel :: proc(info: ^Stbtt_Fontinfo, glyph: c.int, sx, sy, shx, shy: f32, x0, y0, x1, y1: ^c.int) ---
	MakeGlyphBitmapSubpixel :: proc(info: ^Stbtt_Fontinfo, output: [^]u8, w, h, stride: c.int, sx, sy, shx, shy: f32, glyph: c.int) ---
}

TEXT_BACKEND :: "stb_truetype"

DEFAULT_MONO_FAMILIES :: []string{"DejaVu Sans Mono"}
DEFAULT_UI_FAMILY :: "DejaVu Sans"

@(private = "file")
FAMILY_PATHS := [?]struct {
	family:       string,
	bold:         bool,
	path:         string,
} {
	{"DejaVu Sans Mono", false, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"},
	{"DejaVu Sans Mono", true, "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"},
	{"DejaVu Sans", false, "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"},
	{"DejaVu Sans", true, "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"},
}

@(private = "file")
FALLBACK_PATHS := [?]string{"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"}

@(private = "file")
Stb_Face :: struct {
	info:      Stbtt_Fontinfo,
	scale:     f32,
	px:        f32,
	fallbacks: [dynamic]Face_Id,
}

@(private = "file")
stb_faces: [dynamic]Stb_Face

@(private = "file")
load :: proc(path: string, px: f32) -> (Face_Id, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return -1, false
	f: Stb_Face
	off := GetFontOffsetForIndex(raw_data(data), 0)
	if off < 0 || InitFont(&f.info, raw_data(data), off) == 0 do return -1, false
	f.scale = ScaleForPixelHeight(&f.info, px)
	f.px = px
	append(&stb_faces, f)
	return Face_Id(len(stb_faces) - 1), true
}

// No semibold files: the caller uses bold.
tb_face_open :: proc(family: string, px: f32, bold, italic: bool, semibold := false) -> (Face_Id, bool) {
	if semibold do return -1, false
	fam := family == "" ? DEFAULT_UI_FAMILY : family
	path := ""
	for e in FAMILY_PATHS do if e.family == fam && e.bold == bold do path = e.path
	if path == "" do for e in FAMILY_PATHS do if e.family == fam do path = e.path
	if path == "" do return -1, false
	id, ok := load(path, px)
	if !ok do return -1, false
	for p in FALLBACK_PATHS {
		if fb, fok := load(p, px); fok do append(&stb_faces[id].fallbacks, fb)
	}
	return id, true
}

tb_face_metrics :: proc(f: Face_Id) -> (m: Face_Metrics) {
	sf := &stb_faces[f]
	asc, desc, gap: c.int
	GetFontVMetrics(&sf.info, &asc, &desc, &gap)
	m.ascent = f32(asc) * sf.scale
	m.descent = -f32(desc) * sf.scale
	m.leading = f32(gap) * sf.scale
	adv, lsb: c.int
	GetGlyphHMetrics(&sf.info, FindGlyphIndex(&sf.info, 'M'), &adv, &lsb)
	m.advance = f32(adv) * sf.scale
	m.cap_height = m.ascent * 0.7
	m.x_height = m.ascent * 0.5
	m.underline_pos = m.descent * 0.4
	m.underline_thickness = max(1, sf.px / 14)
	return
}

tb_shape :: proc(f: Face_Id, text: string, ligatures: bool, out: []Shaped_Glyph) -> (n: int, width: f32) {
	for i := 0; i < len(text); {
		r, size := utf8.decode_rune_in_string(text[i:])
		face := f
		g := FindGlyphIndex(&stb_faces[f].info, c.int(r))
		if g == 0 {
			for fb in stb_faces[f].fallbacks {
				if fg := FindGlyphIndex(&stb_faces[fb].info, c.int(r)); fg != 0 {
					face, g = fb, fg
					break
				}
			}
		}
		adv, lsb: c.int
		GetGlyphHMetrics(&stb_faces[face].info, g, &adv, &lsb)
		a := f32(adv) * stb_faces[face].scale
		if n < len(out) do out[n] = {face = face, glyph = u32(g), x = width, advance = a, cluster = i32(i)}
		n += 1
		width += a
		i += size
	}
	return
}

tb_glyph_box :: proc(f: Face_Id, glyph: u32, scale, subx: f32) -> (x0, y0, w, h: i32) {
	sf := &stb_faces[f]
	s := sf.scale * scale
	a, b, cc, d: c.int
	GetGlyphBitmapBoxSubpixel(&sf.info, c.int(glyph), s, s, subx, 0, &a, &b, &cc, &d)
	return i32(a), i32(b), i32(cc - a), i32(d - b)
}

tb_glyph_render :: proc(f: Face_Id, glyph: u32, scale, subx: f32, x0, y0, w, h: i32, dst: []u8, stride: int, thicken: bool) -> (color: bool) {
	sf := &stb_faces[f]
	s := sf.scale * scale
	tmp := make([]u8, int(w * h), context.temp_allocator)
	MakeGlyphBitmapSubpixel(&sf.info, raw_data(tmp), w, h, w, s, s, subx, 0, c.int(glyph))
	for y in 0 ..< int(h) do for x in 0 ..< int(w) {
		o := y * stride + x * 4
		dst[o + 0], dst[o + 1], dst[o + 2] = 255, 255, 255
		dst[o + 3] = tmp[y * int(w) + x]
	}
	return false
}
