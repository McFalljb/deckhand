package main

// Text: fonts, shaping caches, one RGBA glyph atlas, and sokol_gl quads.
//
// Text backend (one per OS, the only platform-specific part):
//   text_coretext.odin  macOS: CoreText lookup/fallback/shaping, CoreGraphics raster
//   text_stb.odin       others for now: stb_truetype, fixed paths, no shaping
// Each provides:
//   tb_face_open(family, px, bold, italic, semibold) -> (Face_Id, ok)   "" = system UI font
//   tb_face_metrics(face) -> Face_Metrics
//   tb_shape(face, text, ligatures, out) -> (count, width)    fallback fonts come back as
//                                                             new Face_Ids in the glyphs
//   tb_glyph_box(face, glyph, scale, subx) -> (x0, y0, w, h)  y0 from baseline, down +
//   tb_glyph_render(face, glyph, scale, subx, box..., dst RGBA, stride, thicken) -> colour
//   DEFAULT_MONO_FAMILIES, DEFAULT_UI_FAMILY, TEXT_BACKEND
//
// Here: three font sets (UI, UI small, terminal mono; Clay's fontId picks
// one), a cache of shaped runs (UI strings and terminal cells), a cache of
// rasterised glyphs in the atlas, box-drawing/block sprites
// (text_sprites.odin), and the quads. Glyphs are rasterised on first use, at
// framebuffer pixels (HiDPI), UI text at quarter-pixel x positions.
// The atlas grows 1024 -> 2048 -> 4096 and starts over when full; new glyphs
// reach the GPU through a staging buffer, only the rows that changed.

import "core:hash"
import "core:math"
import "core:mem"
import "core:unicode/utf8"
import sg "../vendor/sokol-odin/sokol/gfx"
import sgl "../vendor/sokol-odin/sokol/gl"
import clay "../build/clay-odin"

Face_Id :: distinct i32

// Matches pd_metrics in src/native/text_coretext.c. Pixels.
Face_Metrics :: struct {
	ascent, descent, leading: f32, // descent positive
	advance:                  f32, // of 'M'
	cap_height, x_height:     f32,
	underline_pos:            f32, // below the baseline, positive = down
	underline_thickness:      f32,
	color:                    i32,
}

// Matches pd_glyph.
Shaped_Glyph :: struct {
	face:    Face_Id,
	glyph:   u32,
	x, y:    f32, // from the run origin, y down
	advance: f32,
	cluster: i32, // byte offset into the text
}

Font_Kind :: enum u8 {
	UI, // Clay fontId 0, the default
	UI_Small,
	Mono, // terminal
}
// Clay fontId = kind | FONT_BOLD (theme.odin's WEIGHT_* are these).
FONT_UI :: u16(Font_Kind.UI)
FONT_UI_SMALL :: u16(Font_Kind.UI_Small)
FONT_MONO :: u16(Font_Kind.Mono)
FONT_BOLD :: u16(4)
FONT_ITALIC :: u16(8) // UI text in the set's italic face (preview tabs)
FONT_SEMIBOLD :: u16(16) // section headers; bold where the family has no semibold

font_id_split :: proc(id: u16) -> (kind: Font_Kind, bold: bool) {
	k := id & 3
	return k <= u16(max(Font_Kind)) ? Font_Kind(k) : .UI, id & FONT_BOLD != 0
}

font_id_italic :: proc(id: u16) -> bool {return id & FONT_ITALIC != 0}
font_id_semibold :: proc(id: u16) -> bool {return id & FONT_SEMIBOLD != 0}

// What the theme sets. Sizes in points (scaled by the display's DPI).
Font_Config :: struct {
	mono_families: []string, // first installed one wins
	mono_pt:       f32,
	ui_family:     string, // "" = system font
	ui_pt:         f32,
	ui_small_pt:   f32,
	thicken:       bool, // heavier strokes (CoreText font smoothing), like Terminal.app
	mono_ligatures: bool, // off: ligatures and a cell grid interact badly
}

font_config := Font_Config {
	mono_families = DEFAULT_MONO_FAMILIES,
	mono_pt       = 13,
	ui_family     = DEFAULT_UI_FAMILY,
	ui_pt         = 13,
	ui_small_pt   = 11,
}

Font_Set :: struct {
	faces:    [5]Face_Id, // regular, bold, italic, bold italic, semibold
	family:   string,
	px:       f32,
	metrics:  Face_Metrics,
	line_h:   f32, // line box height
	baseline: f32, // from the line top
}

// A rasterised glyph in the atlas.
Atlas_Glyph :: struct {
	x, y, w, h:   i32, // atlas pixels
	x_off, y_off: i32, // from the pen position / the baseline
	color:        bool,
}

Raster_Key :: struct {
	face:    Face_Id,
	glyph:   u32, // codepoint for sprites
	scale_q: u16, // scale * 1024
	subx:    u8, // quarter pixels
	sprite:  u8, // 1: box drawing / block sprite (cell-sized); LOGO_SPRITE: a logo (glyph = Logo, scale_q = px)
}

LOGO_SPRITE :: 2

// A shaped run: a UI string, or one terminal cell's grapheme.
Run :: struct {
	first, count: u32, // into font.run_glyphs
	width:        f32,
}

Run_Glyph :: struct {
	face:    Face_Id,
	glyph:   u32,
	x, y:    f32, // from the run origin (pen at the baseline)
	advance: f32,
	scale:   f32,
	cluster: i32,
	sprite:  bool,
}

ATLAS_MIN :: #config(PI_DESK_ATLAS_MIN, 1024) // -define:PI_DESK_ATLAS_MIN=128 etc. exercise grow/evict
ATLAS_MAX :: #config(PI_DESK_ATLAS_MAX, 4096)
RUN_GLYPHS_MAX :: 1 << 18 // run cache starts over past this
MAX_RUN_GLYPHS :: 16 // glyphs kept per terminal cell

Font :: struct {
	// terminal cell metrics (framebuffer px), from the mono set
	cell_w, cell_h:    f32,
	baseline:          f32, // from the cell top
	underline_y:       f32, // from the cell top
	strike_y:          f32,
	line_thick:        f32,
	dpi:               f32,
	sets:              [Font_Kind]Font_Set,
	// caches
	raster:            map[Raster_Key]Atlas_Glyph,
	runs_by_key:       map[u64]u32,
	runs:              [dynamic]Run,
	run_glyphs:        [dynamic]Run_Glyph,
	shape_buf:         [256]Shaped_Glyph,
	scratch:           [dynamic]u8, // one glyph's RGBA before it goes into the atlas
	// atlas
	size:              i32,
	pixels:            []u8, // CPU copy (RGBA)
	pen_x, pen_y:      i32,
	row_h:             i32,
	dirty_y0, dirty_y1: i32, // rows to upload
	recreate:          bool, // size changed: new GPU image
	evicted:           bool, // started over this frame
	overflow:          bool, // a glyph found no room even after starting over
	redraw:            bool, // quads recorded this frame may be stale: draw again
	image:             sg.Image,
	view:              sg.View,
	staging:           sg.Buffer,
	retired:           [dynamic]Gpu_Atlas, // destroyed after this frame's commit
	sampler:           sg.Sampler,
	pipeline:          sgl.Pipeline,
	// stats
	glyphs_rasterised: int,
	evictions:         int,
}

Gpu_Atlas :: struct {
	image:   sg.Image,
	view:    sg.View,
	staging: sg.Buffer,
}

font: Font

// ---- setup ----

@(private = "file")
open_set :: proc(families: []string, pt, dpi: f32) -> (s: Font_Set, ok: bool) {
	px := pt * dpi
	for fam in families {
		if id, fok := tb_face_open(fam, px, false, false); fok {
			s.faces[0] = id
			s.family = fam
			ok = true
			break
		}
	}
	if !ok do return
	s.px = px
	for i in 1 ..< 4 {
		id, vok := tb_face_open(s.family, px, i & 1 != 0, i & 2 != 0)
		s.faces[i] = vok ? id : s.faces[0]
	}
	semi, sok := tb_face_open(s.family, px, false, false, semibold = true)
	s.faces[4] = sok ? semi : s.faces[1]
	m := tb_face_metrics(s.faces[0])
	s.metrics = m
	s.line_h = math.ceil(m.ascent + m.descent + m.leading)
	s.baseline = math.round(m.ascent + m.leading / 2)
	return s, true
}

// Opens the fonts for `cfg` at `dpi` and resets the caches (ours and Clay's
// text widths). Call again when the theme, the text size or the display
// scale changes.
fonts_apply :: proc(cfg: Font_Config, dpi: f32) -> bool {
	font_config = cfg
	font.dpi = dpi
	mono, ok := open_set(cfg.mono_families, cfg.mono_pt, dpi)
	if !ok do mono, ok = open_set(DEFAULT_MONO_FAMILIES, cfg.mono_pt, dpi)
	if !ok do return false
	ui_fams := []string{cfg.ui_family, DEFAULT_UI_FAMILY}
	ui, uok := open_set(ui_fams, cfg.ui_pt, dpi)
	small, sok := open_set(ui_fams, cfg.ui_small_pt, dpi)
	if !uok do ui = mono
	if !sok do small = ui
	font.sets = {.UI = ui, .UI_Small = small, .Mono = mono}

	m := mono.metrics
	font.cell_w = max(1, math.round(m.advance))
	font.cell_h = mono.line_h
	font.baseline = mono.baseline
	font.line_thick = max(1, math.round(m.underline_thickness))
	font.underline_y = min(font.cell_h - font.line_thick, font.baseline + max(1, math.round(m.underline_pos)))
	font.strike_y = font.baseline - math.round(m.x_height / 2)

	clear(&font.runs_by_key)
	clear(&font.runs)
	clear(&font.run_glyphs)
	atlas_reset()
	// Clay keeps the widths it measured (per string and fontId): measure again
	if clay.GetCurrentContext() != nil do clay.ResetMeasureTextCache()
	return true
}

font_init :: proc(dpi: f32) -> bool {
	font.size = ATLAS_MIN
	font.pixels = make([]u8, ATLAS_MIN * ATLAS_MIN * 4)
	if !fonts_apply(font_config, dpi) do return false
	font.sampler = sg.make_sampler({min_filter = .NEAREST, mag_filter = .NEAREST})
	font.pipeline = sgl.make_pipeline(
		{
			colors = {
				0 = {
					blend = {
						enabled = true,
						src_factor_rgb = .SRC_ALPHA,
						dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
						src_factor_alpha = .ONE,
						dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
					},
				},
			},
		},
	)
	font.recreate = true
	font_upload()
	return true
}

// ---- atlas ----

// Empties the atlas (glyphs re-rasterise on demand). Keeps the size.
@(private = "file")
atlas_reset :: proc() {
	clear(&font.raster)
	mem.zero_slice(font.pixels)
	// 2x2 white block at the origin for solid rectangles
	for y in 0 ..< 2 do for x in 0 ..< 2 do for k in 0 ..< 4 do font.pixels[(y * int(font.size) + x) * 4 + k] = 255
	font.pen_x, font.pen_y, font.row_h = 4, 0, 4
	font.dirty_y0, font.dirty_y1 = 0, font.size
	font.redraw = true
}

@(private = "file")
atlas_grow :: proc() {
	old, old_size := font.pixels, int(font.size)
	n := old_size * 2
	font.pixels = make([]u8, n * n * 4)
	for y in 0 ..< old_size do copy(font.pixels[y * n * 4:][:old_size * 4], old[y * old_size * 4:][:old_size * 4])
	delete(old)
	font.size = i32(n)
	font.recreate = true
	font.dirty_y0, font.dirty_y1 = 0, font.size
	font.redraw = true // quads recorded earlier this frame used the old size
}

// Finds room for a w x h glyph (1 px gutter). False if there is none even
// after growing or starting over (only once per frame).
@(private = "file")
atlas_alloc :: proc(w, h: i32) -> (x, y: i32, ok: bool) {
	if w + 1 > font.size || h + 1 > font.size do return
	for {
		if font.pen_x + w + 1 > font.size {
			font.pen_x = 0
			font.pen_y += font.row_h + 1
			font.row_h = 0
		}
		if font.pen_y + h + 1 <= font.size do break
		if font.size < ATLAS_MAX {
			atlas_grow()
		} else if !font.evicted {
			font.evicted = true
			font.evictions += 1
			atlas_reset()
		} else {
			font.overflow = true
			return
		}
	}
	x, y = font.pen_x, font.pen_y
	font.pen_x += w + 1
	font.row_h = max(font.row_h, h)
	font.dirty_y0 = min(font.dirty_y0, y)
	font.dirty_y1 = max(font.dirty_y1, y + h)
	return x, y, true
}

// Rasterises (once) and returns the atlas glyph for k.
@(private = "file")
raster_get :: proc(k: Raster_Key) -> (Atlas_Glyph, bool) {
	if g, ok := font.raster[k]; ok do return g, true
	g: Atlas_Glyph
	scale := f32(k.scale_q) / 1024
	subx := f32(k.subx) / 4
	if k.sprite == LOGO_SPRITE {
		side := i32(logo_side(Logo(k.glyph), int(k.scale_q))) // n, or more for a wide mark
		g.w, g.h = side, side
	} else if k.sprite != 0 {
		g.w, g.h = i32(font.cell_w) * i32(max(1, k.scale_q / 1024)), i32(font.cell_h)
		g.y_off = -i32(font.baseline)
	} else {
		g.x_off, g.y_off, g.w, g.h = tb_glyph_box(k.face, k.glyph, scale, subx)
	}
	if g.w > 0 && g.h > 0 {
		n := int(g.w * g.h * 4)
		if len(font.scratch) < n do resize(&font.scratch, n)
		px := font.scratch[:n]
		mem.zero_slice(px)
		if k.sprite == LOGO_SPRITE {
			if !logo_render(Logo(k.glyph), int(k.scale_q), px) do g.w = 0
			g.color = true
		} else if k.sprite != 0 {
			if !sprite_render(rune(k.glyph), int(g.w), int(g.h), px) do g.w = 0
		} else {
			g.color = tb_glyph_render(k.face, k.glyph, scale, subx, g.x_off, g.y_off, g.w, g.h, px, int(g.w) * 4, font_config.thicken)
		}
		if g.w > 0 {
			x, y, ok := atlas_alloc(g.w, g.h)
			if !ok do return {}, false
			stride := int(font.size) * 4
			for row in 0 ..< int(g.h) {
				copy(font.pixels[(int(y) + row) * stride + int(x) * 4:][:int(g.w) * 4], px[row * int(g.w) * 4:][:int(g.w) * 4])
			}
			g.x, g.y = x, y
			font.glyphs_rasterised += 1
		}
	}
	font.raster[k] = g
	return g, true
}

// Sends new glyphs to the GPU (call after recording, outside a pass), and
// recreates the texture after a resize.
font_upload :: proc() {
	if font.recreate {
		if font.image.id != 0 do append(&font.retired, Gpu_Atlas{font.image, font.view, font.staging})
		n := int(font.size)
		font.image = sg.make_image({width = font.size, height = font.size, pixel_format = .RGBA8, usage = {copy_dst = true}})
		font.view = sg.make_view({texture = {image = font.image}})
		font.staging = sg.make_buffer({size = uint(n * n * 4), usage = {staging_buffer = true, write_transient = true, copy_src = true}})
		font.recreate = false
		font.dirty_y0, font.dirty_y1 = 0, font.size
	}
	if font.dirty_y1 > font.dirty_y0 {
		stride := int(font.size) * 4
		band := font.pixels[int(font.dirty_y0) * stride:int(font.dirty_y1) * stride]
		sg.write_buffer_transient({src = {data = {ptr = raw_data(band), size = uint(len(band))}}, dst = {buffer = font.staging}})
		sg.copy_buffer_to_image(
			{
				src = {buffer = font.staging, bytes_per_row = i32(stride)},
				dst = {image = font.image, y = font.dirty_y0},
				size = {width = font.size, height = font.dirty_y1 - font.dirty_y0, num_slices = 1},
			},
		)
		font.dirty_y0, font.dirty_y1 = font.size, 0
	}
	// keep the run cache bounded (indices stay valid within a frame)
	if len(font.run_glyphs) > RUN_GLYPHS_MAX {
		clear(&font.runs_by_key)
		clear(&font.runs)
		clear(&font.run_glyphs)
	}
}

// After sg.commit: frees replaced GPU atlases; true if the frame should be
// drawn again (the atlas grew or started over while recording).
font_frame_done :: proc() -> (redraw: bool) {
	for r in font.retired {
		sg.destroy_buffer(r.staging)
		sg.destroy_view(r.view)
		sg.destroy_image(r.image)
	}
	clear(&font.retired)
	// One screen needing more than the largest atlas would start over on
	// every frame: draw what fits and stop asking for frames.
	redraw = font.redraw && !font.overflow
	font.redraw = false
	font.evicted = false
	font.overflow = false
	return
}

font_stats :: proc() -> (atlas_px: i32, glyphs, rasterised, evictions, runs: int) {
	return font.size, len(font.raster), font.glyphs_rasterised, font.evictions, len(font.runs)
}

// ---- shaping caches ----

@(private = "file")
add_run :: proc(key: u64, face: Face_Id, text: string, ligatures: bool, max_glyphs: int) -> u32 {
	buf := font.shape_buf[:]
	n, width := tb_shape(face, text, ligatures, buf)
	if n > len(buf) && max_glyphs > len(buf) {
		buf = make([]Shaped_Glyph, n, context.temp_allocator)
		n, width = tb_shape(face, text, ligatures, buf)
	}
	n = min(n, len(buf), max_glyphs)
	r := Run{first = u32(len(font.run_glyphs)), count = u32(n), width = width}
	for g in buf[:n] {
		append(&font.run_glyphs, Run_Glyph{face = g.face, glyph = g.glyph, x = g.x, y = g.y, advance = g.advance, scale = 1, cluster = g.cluster})
	}
	append(&font.runs, r)
	idx := u32(len(font.runs) - 1)
	font.runs_by_key[key] = idx
	return idx
}

// The shaped run for a UI string.
text_run :: proc(s: string, kind: Font_Kind, bold := false, italic := false, semibold := false) -> u32 {
	style := semibold ? 4 : (bold ? 1 : 0) | (italic ? 2 : 0)
	key := hash.fnv64a(transmute([]u8)s, 0xcbf29ce484222325 ~ u64(int(kind) | 8 | style << 4) * 0x100000001b3)
	if i, ok := font.runs_by_key[key]; ok do return i
	return add_run(key, font.sets[kind].faces[style], s, true, 1 << 30)
}

// The shaped run for a string at `scale` times its set's size (Markdown
// headings and body text): shaped once at the set's size, its glyphs
// rasterised at the scaled size, so they stay crisp.
text_run_scaled :: proc(s: string, kind: Font_Kind, bold, italic: bool, scale: f32) -> u32 {
	if scale == 1 do return text_run(s, kind, bold, italic)
	style := (bold ? 1 : 0) | (italic ? 2 : 0)
	q := u64(math.round(scale * 256))
	key := hash.fnv64a(transmute([]u8)s, 0xcbf29ce484222325 ~ u64(int(kind) | 8 | style << 4) * 0x100000001b3 ~ q << 40)
	if i, ok := font.runs_by_key[key]; ok do return i
	idx := add_run(key, font.sets[kind].faces[style], s, true, 1 << 30)
	r := &font.runs[idx]
	for &g in font.run_glyphs[r.first:][:r.count] {
		g.x *= scale
		g.y *= scale
		g.advance *= scale
		g.scale = scale
	}
	r.width *= scale
	return idx
}

// The run for one terminal cell: its grapheme's codepoints in the mono set's
// style face, fitted into `span` cells (1 or 2): too-wide glyphs (emoji,
// some symbols) shrink, colour glyphs centre vertically, everything centres
// horizontally.
text_cell_run :: proc(cps: []rune, bold, italic: bool, span: int) -> u32 {
	style := (bold ? 1 : 0) | (italic ? 2 : 0)
	h := u64(0xcbf29ce484222325) ~ u64(style | span << 2) * 0x100000001b3
	h = hash.fnv64a(mem.slice_to_bytes(cps), h)
	if i, ok := font.runs_by_key[h]; ok do return i

	span_w := font.cell_w * f32(span)
	if len(cps) == 1 && sprite_supported(cps[0]) {
		append(&font.run_glyphs, Run_Glyph{glyph = u32(cps[0]), scale = f32(span), sprite = true})
		append(&font.runs, Run{first = u32(len(font.run_glyphs) - 1), count = 1, width = span_w})
		idx := u32(len(font.runs) - 1)
		font.runs_by_key[h] = idx
		return idx
	}
	buf: [64]u8
	n := 0
	for r in cps {
		b, l := utf8.encode_rune(r)
		if n + l > len(buf) do break
		copy(buf[n:], b[:l])
		n += l
	}
	set := &font.sets[.Mono]
	idx := add_run(h, set.faces[style], string(buf[:n]), font_config.mono_ligatures, MAX_RUN_GLYPHS)
	r := &font.runs[idx]
	gs := font.run_glyphs[r.first:][:r.count]
	if len(gs) == 0 do return idx

	color := false
	for g in gs do if tb_face_metrics(g.face).color != 0 do color = true
	w := r.width
	s := f32(1)
	if w > span_w + 0.5 do s = span_w / w
	dy := f32(0)
	if color && len(gs) == 1 {
		// emoji: size the bitmap (not the advance, which has side bearings)
		// to the cell span and height, centred
		bx, y0, bw, bh := tb_glyph_box(gs[0].face, gs[0].glyph, 1, 0)
		if bw > 2 && bh > 2 {
			s = min((span_w + 2) / f32(bw), (font.cell_h + 2) / f32(bh))
			bx, y0, bw, bh = tb_glyph_box(gs[0].face, gs[0].glyph, s, 0)
			dy = math.round((font.cell_h - f32(bh)) / 2 - font.baseline - f32(y0))
			for &g in gs {
				g.x = math.round((span_w - f32(bw)) / 2 - f32(bx))
				g.y = dy
				g.scale = s
			}
			r.width = span_w
			return idx
		}
	}
	dx := (span_w - w * s) / 2
	for &g in gs {
		g.x = g.x * s + dx
		g.y = g.y * s + dy
		g.scale = s
	}
	r.width = span_w
	return idx
}

// ---- measuring ----

text_line_height :: proc(kind: Font_Kind) -> f32 {return font.sets[kind].line_h}

text_width :: proc(s: string, kind: Font_Kind, bold := false, italic := false, semibold := false) -> f32 {
	if s == "" do return 0
	ri := text_run(s, kind, bold, italic, semibold) // before indexing: it may append to font.runs
	return font.runs[ri].width
}

// Width of the first `runes` codepoints of s (text field cursor).
text_prefix_width :: proc(s: string, runes: int, kind: Font_Kind) -> f32 {
	i := 0
	for _, off in s {
		if i == runes do return text_width(s[:off], kind)
		i += 1
	}
	return text_width(s, kind)
}

// s cut to fit max_w with an ellipsis (temp allocator when cut).
text_clip :: proc(s: string, max_w: f32, kind: Font_Kind, bold := false, italic := false, semibold := false) -> string {
	if max_w <= 0 do return ""
	ri := text_run(s, kind, bold, italic, semibold)
	r := font.runs[ri]
	if r.width <= max_w do return s
	limit := max_w - text_width("…", kind, bold, italic, semibold)
	cut := len(s)
	for g in font.run_glyphs[r.first:][:r.count] {
		if g.x + g.advance > limit {
			cut = int(g.cluster)
			break
		}
	}
	return concat_ellipsis(s[:cut])
}

// How many bytes of s fit in max_w (len(s) when all of it does), at a
// character boundary, from s's shaped run.
text_fit :: proc(s: string, max_w: f32, kind: Font_Kind, bold := false, italic := false, semibold := false) -> int {
	if s == "" do return 0
	ri := text_run(s, kind, bold, italic, semibold)
	r := font.runs[ri]
	if r.width <= max_w do return len(s)
	for g in font.run_glyphs[r.first:][:r.count] {
		if g.x + g.advance > max_w do return int(g.cluster)
	}
	return len(s)
}

@(private = "file")
concat_ellipsis :: proc(s: string) -> string {
	t := s
	for len(t) > 0 && t[len(t) - 1] == ' ' do t = t[:len(t) - 1]
	out := make([]u8, len(t) + 3, context.temp_allocator)
	copy(out, t)
	copy(out[len(t):], "…")
	return string(out)
}

// ---- drawing ----

Rgba :: [4]u8

// Draw calls below must happen between draw_begin() and draw_end().
draw_begin :: proc(fb_w, fb_h: f32) {
	sgl.defaults()
	sgl.load_pipeline(font.pipeline)
	sgl.enable_texture()
	sgl.texture(font.view, font.sampler)
	sgl.matrix_mode_projection()
	sgl.ortho(0, fb_w, fb_h, 0, -1, 1)
	sgl.begin_quads()
}

draw_end :: proc() {
	sgl.end()
}

draw_rect :: proc(x, y, w, h: f32, col: Rgba) {
	u := f32(0.5) / f32(font.size)
	sgl.v2f_t2f_c4b(x, y, u, u, col.r, col.g, col.b, col.a)
	sgl.v2f_t2f_c4b(x + w, y, u, u, col.r, col.g, col.b, col.a)
	sgl.v2f_t2f_c4b(x + w, y + h, u, u, col.r, col.g, col.b, col.a)
	sgl.v2f_t2f_c4b(x, y + h, u, u, col.r, col.g, col.b, col.a)
}

// Draws run `ri` with its pen at (x, baseline).
draw_run :: proc(ri: u32, x, baseline: f32, col: Rgba) {
	r := font.runs[ri]
	inv := 1 / f32(font.size)
	by := math.round(baseline)
	for g in font.run_glyphs[r.first:][:r.count] {
		k := Raster_Key{face = g.face, glyph = g.glyph, scale_q = u16(math.round(g.scale * 1024))}
		px := x + g.x
		ix := math.floor(px)
		q := math.round((px - ix) * 4)
		if q >= 4 {
			ix += 1
			q = 0
		}
		if g.sprite {
			k.face, k.sprite = 0, 1
			q = 0
		}
		k.subx = u8(q)
		ag, ok := raster_get(k)
		if !ok || ag.w == 0 do continue
		c := ag.color ? Rgba{255, 255, 255, col.a} : col
		gx := ix + f32(ag.x_off)
		gy := by + math.round(g.y) + f32(ag.y_off)
		u0, v0 := f32(ag.x) * inv, f32(ag.y) * inv
		u1, v1 := f32(ag.x + ag.w) * inv, f32(ag.y + ag.h) * inv
		w, h := f32(ag.w), f32(ag.h)
		sgl.v2f_t2f_c4b(gx, gy, u0, v0, c.r, c.g, c.b, c.a)
		sgl.v2f_t2f_c4b(gx + w, gy, u1, v0, c.r, c.g, c.b, c.a)
		sgl.v2f_t2f_c4b(gx + w, gy + h, u1, v1, c.r, c.g, c.b, c.a)
		sgl.v2f_t2f_c4b(gx, gy + h, u0, v1, c.r, c.g, c.b, c.a)
	}
}

// Draws `logo` (logos.odin) in its own colours, for the n framebuffer px square with its
// top-left at (x, y) rounded to the pixel grid, faded by alpha a. A mark wider than the square
// (logo_side) reaches past it equally on both sides.
draw_logo :: proc(logo: Logo, x, y: f32, n: int, a: u8) {
	if logo == .None || n <= 0 || n > 1024 || a == 0 do return
	ag, ok := raster_get(Raster_Key{glyph = u32(logo), scale_q = u16(n), sprite = LOGO_SPRITE})
	if !ok || ag.w == 0 do return
	inv := 1 / f32(font.size)
	over := f32((int(ag.w) - n) / 2) // logo_side: an even number of px more than n, or none
	gx, gy := math.round(x) - over, math.round(y) - over
	u0, v0 := f32(ag.x) * inv, f32(ag.y) * inv
	u1, v1 := f32(ag.x + ag.w) * inv, f32(ag.y + ag.h) * inv
	w, h := f32(ag.w), f32(ag.h)
	sgl.v2f_t2f_c4b(gx, gy, u0, v0, 255, 255, 255, a)
	sgl.v2f_t2f_c4b(gx + w, gy, u1, v0, 255, 255, 255, a)
	sgl.v2f_t2f_c4b(gx + w, gy + h, u1, v1, 255, 255, 255, a)
	sgl.v2f_t2f_c4b(gx, gy + h, u0, v1, 255, 255, 255, a)
}

// Draws a single-line string whose line box's top-left is (x, y). Returns
// the x after it.
draw_text :: proc(x, y: f32, s: string, col: Rgba, kind := Font_Kind.UI, bold := false, italic := false, semibold := false) -> f32 {
	if s == "" do return x
	ri := text_run(s, kind, bold, italic, semibold)
	draw_run(ri, x, y + font.sets[kind].baseline, col)
	return x + font.runs[ri].width
}

// Byte offset of the character boundary nearest to x in s (a click in a
// text field), from the shaped run's clusters.
text_offset_at :: proc(s: string, x: f32, kind: Font_Kind) -> int {
	if s == "" || x <= 0 do return 0
	ri := text_run(s, kind)
	r := font.runs[ri]
	if x >= r.width do return len(s)
	gs := font.run_glyphs[r.first:][:r.count]
	for g in gs {
		if x >= g.x + g.advance do continue
		if x < g.x + g.advance / 2 do return int(g.cluster)
		next := len(s) // right half: the next cluster boundary
		for h in gs do if int(h.cluster) > int(g.cluster) do next = min(next, int(h.cluster))
		return next
	}
	return len(s)
}
