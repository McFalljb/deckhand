#+build darwin
package main

// Text backend, macOS: CoreText for font lookup, fallback and shaping,
// CoreGraphics for rasterising (src/native/text_coretext.c). The interface
// every backend provides is listed in font.odin ("Text backend").

import "core:c"

foreign import pdtext {
	"../build/dh_text.a",
	"system:CoreText.framework",
	"system:CoreGraphics.framework",
	"system:CoreFoundation.framework",
}

@(default_calling_convention = "c")
foreign pdtext {
	dh_face_open :: proc(family: [^]u8, len: c.int, px: f64, traits: c.int) -> c.int ---
	dh_face_metrics :: proc(face: c.int, m: ^Face_Metrics) ---
	dh_shape :: proc(face: c.int, text: [^]u8, len: c.int, ligatures: c.int, out: [^]Shaped_Glyph, cap: c.int, width: ^f32) -> c.int ---
	dh_glyph_box :: proc(face: c.int, glyph: u32, scale, subx: f32, x0, y0, w, h: ^c.int) ---
	dh_glyph_render :: proc(face: c.int, glyph: u32, scale, subx: f32, x0, y0, w, h: c.int, dst: [^]u8, stride: c.int, thicken: c.int) -> c.int ---
}

TEXT_BACKEND :: "coretext"

// Default families, tried in order. "ui-monospace" is SF Mono; "" is the
// system UI font (SF Pro).
DEFAULT_MONO_FAMILIES :: []string{"JetBrains Mono", "ui-monospace", "Menlo"}
DEFAULT_UI_FAMILY :: ""

tb_face_open :: proc(family: string, px: f32, bold, italic: bool, semibold := false) -> (Face_Id, bool) {
	traits: c.int = semibold ? 4 : (bold ? 1 : 0) | (italic ? 2 : 0)
	id := dh_face_open(raw_data(family), c.int(len(family)), f64(px), traits)
	return Face_Id(id), id >= 0
}

tb_face_metrics :: proc(f: Face_Id) -> (m: Face_Metrics) {
	dh_face_metrics(c.int(f), &m)
	return
}

tb_shape :: proc(f: Face_Id, text: string, ligatures: bool, out: []Shaped_Glyph) -> (n: int, width: f32) {
	if len(text) == 0 do return
	n = int(dh_shape(c.int(f), raw_data(text), c.int(len(text)), ligatures ? 1 : 0, raw_data(out), c.int(len(out)), &width))
	return
}

tb_glyph_box :: proc(f: Face_Id, glyph: u32, scale, subx: f32) -> (x0, y0, w, h: i32) {
	cx0, cy0, cw, ch: c.int
	dh_glyph_box(c.int(f), glyph, scale, subx, &cx0, &cy0, &cw, &ch)
	return i32(cx0), i32(cy0), i32(cw), i32(ch)
}

tb_glyph_render :: proc(f: Face_Id, glyph: u32, scale, subx: f32, x0, y0, w, h: i32, dst: []u8, stride: int, thicken: bool) -> (color: bool) {
	return dh_glyph_render(c.int(f), glyph, scale, subx, x0, y0, w, h, raw_data(dst), c.int(stride), thicken ? 1 : 0) != 0
}
