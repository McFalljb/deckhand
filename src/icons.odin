package main

// A tiny built-in icon set: simple vector shapes (lines, rings, dots) drawn
// with the same sokol_gl quads as the rest of the chrome, so they need no
// image assets, follow the look's colours and stay crisp at any display scale.
// Every edge gets a one-pixel feather (alpha ramp) instead of MSAA; strokes
// that run along an axis are snapped to the pixel grid.
//
// Icons are designed on a 16x16 grid (ICON_GRID) and scaled to the element.
// In a layout, `icon(...)` is a Clay custom element: ui_draw calls
// draw_icon for it.

import "core:math"
import "core"
import clay "../build/clay-odin"
import sgl "../vendor/sokol-odin/sokol/gl"

// The logo an icon draws (.None: a vector icon in the caller's colour).
icon_logo :: proc(ic: core.Icon) -> Logo {
	#partial switch ic {
	case .Logo_Pi:
		return .Pi
	case .Logo_Claude:
		return .Claude
	}
	return .None
}

ICON_GRID :: 16

// A Clay element that draws `ic` in `col`, `size` logical px square.
// customData carries the icon, its parameter (a mark's step or percent: bits 8-15) and how much it
// is drawn larger than its box (a flashing mark's pop, 1..ICON_GROW_MAX: bits 16-23), userData the
// colour (packed RGBA). The box (the layout) never grows: only the drawing does, around its centre.
icon :: proc(ic: core.Icon, col: core.Rgba, size: f32 = ICON_SIZE, param: u8 = 0, scale: f32 = 1) {
	packed := uintptr(col.r) | uintptr(col.g) << 8 | uintptr(col.b) << 16 | uintptr(col.a) << 24
	grow := uintptr(u8(clamp((scale - 1) * ICON_GROW_STEPS, 0, 255) + 0.5))
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(px(size)), clay.SizingFixed(px(size))}},
		custom = {customData = rawptr(uintptr(ic) | uintptr(param) << 8 | grow << 16)},
		userData = rawptr(packed),
	}) {}
}

ICON_GROW_STEPS :: 400 // per 1.0 of scale: 255 steps is up to 1.64x

// From a custom render command (ui_draw).
icon_of_command :: proc(cmd: ^clay.RenderCommand) -> (core.Icon, core.Rgba, u8) {
	p := uintptr(cmd.userData)
	d := uintptr(cmd.renderData.custom.customData)
	return core.Icon(u8(d)), {u8(p), u8(p >> 8), u8(p >> 16), u8(p >> 24)}, u8(d >> 8)
}

// How much larger than its box an icon is drawn (icon's scale; exactly 1 at rest).
icon_scale_of_command :: proc(cmd: ^clay.RenderCommand) -> f32 {
	return 1 + f32(u8(uintptr(cmd.renderData.custom.customData) >> 16)) / ICON_GROW_STEPS
}

// The box an icon is drawn in: its layout box, or (popping) that box grown about its centre.
icon_draw_box :: proc(cmd: ^clay.RenderCommand) -> (x, y, w, h: f32) {
	b := cmd.boundingBox
	g := icon_scale_of_command(cmd)
	if g == 1 do return b.x, b.y, b.width, b.height
	w, h = b.width * g, b.height * g
	return b.x - (w - b.width) / 2, b.y - (h - b.height) / 2, w, h
}

// Draws `ic` into the box (framebuffer px), inside draw_begin/draw_end. param: a working mark's
// step (0..SPIN_STEPS-1), a progress mark's percent (0..100).
draw_icon :: proc(ic: core.Icon, x, y, w, h: f32, col: core.Rgba, param: u8 = 0) {
	if col.a == 0 do return
	if logo := icon_logo(ic); logo != .None {
		// a logo: rasterised at the box's whole-px size, centred on the pixel grid
		n := int(math.round(min(w, h)))
		draw_logo(logo, x + (w - f32(n)) / 2, y + (h - f32(n)) / 2, n, col.a)
		return
	}
	s := min(w, h) / ICON_GRID // grid unit in px
	ox := math.round(x + (w - s * ICON_GRID) / 2)
	oy := math.round(y + (h - s * ICON_GRID) / 2)
	sw := max(1, math.round(ICON_STROKE * app.dpi)) // stroke in px
	// grid point -> px; axis-aligned strokes sit on the pixel grid
	P :: proc(o, s, v: f32) -> f32 {return o + v * s}
	snap :: proc(v, sw: f32) -> f32 {return int(sw) % 2 == 1 ? math.floor(v) + 0.5 : math.round(v)}
	X :: proc(ox, s, sw, v: f32) -> f32 {return snap(ox + v * s, sw)}
	switch ic {
	case .None, .Logo_Pi, .Logo_Claude:
	case .Search:
		cx, cy, r := P(ox, s, 7), P(oy, s, 7), 4.5 * s
		stroke_ring(cx, cy, r, sw, col)
		d := (r + sw / 2) / math.SQRT_TWO
		stroke_line(cx + d, cy + d, P(ox, s, 13.5), P(oy, s, 13.5), sw, col, true)
	case .Compose:
		// an open square (the page), a pencil across its top-right corner
		l, t, r, b := X(ox, s, sw, 2.5), X(oy, s, sw, 3.5), X(ox, s, sw, 12.5), X(oy, s, sw, 13.5)
		stroke_line(l, t, P(ox, s, 8), t, sw, col)
		stroke_line(l, t, l, b, sw, col)
		stroke_line(l, b, r, b, sw, col)
		stroke_line(r, b, r, P(oy, s, 9), sw, col)
		stroke_line(P(ox, s, 7), P(oy, s, 9), P(ox, s, 13.5), P(oy, s, 2.5), sw, col, true)
	case .Plus:
		c, d := X(ox, s, sw, 8), X(oy, s, sw, 8)
		stroke_line(c, P(oy, s, 3), c, P(oy, s, 13), sw, col)
		stroke_line(P(ox, s, 3), d, P(ox, s, 13), d, sw, col)
	case .Chevron_Down:
		stroke_line(P(ox, s, 4), P(oy, s, 6), P(ox, s, 8), P(oy, s, 10), sw, col, true)
		stroke_line(P(ox, s, 8), P(oy, s, 10), P(ox, s, 12), P(oy, s, 6), sw, col, true)
	case .Sidebar_Left, .Sidebar_Left_On, .Sidebar_Right, .Sidebar_Right_On:
		l, t, r, b := X(ox, s, sw, 1.5), X(oy, s, sw, 2.5), X(ox, s, sw, 14.5), X(oy, s, sw, 13.5)
		stroke_rect(l, t, r, b, sw, col)
		left := ic == .Sidebar_Left || ic == .Sidebar_Left_On
		on := ic == .Sidebar_Left_On || ic == .Sidebar_Right_On
		edge := left ? X(ox, s, sw, 6) : X(ox, s, sw, 10)
		stroke_line(edge, t, edge, b, sw, col)
		if on {
			// the column filled in (inside the strokes)
			x0 := left ? l : edge
			x1 := left ? edge : r
			draw_rect(x0, t, x1 - x0, b - t, col)
		}
	case .Sliders:
		// two rails with a knob each (a ring that interrupts its rail)
		y1, y2, kr := X(oy, s, sw, 5), X(oy, s, sw, 11), 2 * s
		k1, k2 := P(ox, s, 10.5), P(ox, s, 5.5)
		stroke_line(P(ox, s, 1.5), y1, k1 - kr, y1, sw, col)
		stroke_line(k1 + kr, y1, P(ox, s, 14.5), y1, sw, col)
		stroke_ring(k1, y1, kr, sw, col)
		stroke_line(P(ox, s, 1.5), y2, k2 - kr, y2, sw, col)
		stroke_line(k2 + kr, y2, P(ox, s, 14.5), y2, sw, col)
		stroke_ring(k2, y2, kr, sw, col)
	case .Close:
		stroke_line(P(ox, s, 4), P(oy, s, 4), P(ox, s, 12), P(oy, s, 12), sw, col, true)
		stroke_line(P(ox, s, 12), P(oy, s, 4), P(ox, s, 4), P(oy, s, 12), sw, col, true)
	case .More:
		r := max(1.1 * s, sw * 0.8)
		for gx in ([]f32{3.5, 8, 12.5}) do fill_disc(P(ox, s, gx), P(oy, s, 8), r, col)
	case .Check:
		stroke_line(P(ox, s, 3), P(oy, s, 8.5), P(ox, s, 6.5), P(oy, s, 12), sw, col, true)
		stroke_line(P(ox, s, 6.5), P(oy, s, 12), P(ox, s, 13), P(oy, s, 4), sw, col, true)
	case .New_File:
		// a page with a folded corner, a plus at its bottom right
		l, t, r, b := X(ox, s, sw, 2.5), X(oy, s, sw, 1.5), X(ox, s, sw, 11.5), X(oy, s, sw, 14.5)
		f := P(ox, s, 8)
		stroke_line(l, t, f, t, sw, col)
		stroke_line(f, t, r, P(oy, s, 5), sw, col, true)
		stroke_line(r, P(oy, s, 5), r, P(oy, s, 8.5), sw, col)
		stroke_line(l, t, l, b, sw, col)
		stroke_line(l, b, P(ox, s, 8.5), b, sw, col)
		c, d := X(ox, s, sw, 12.5), X(oy, s, sw, 12)
		stroke_line(c, P(oy, s, 9.5), c, P(oy, s, 14.5), sw, col)
		stroke_line(P(ox, s, 10), d, P(ox, s, 15), d, sw, col)
	case .Folder, .New_Folder, .Reveal:
		// a folder: tab on the top left
		l, t, r, b := X(ox, s, sw, 1.5), X(oy, s, sw, 3.5), X(ox, s, sw, 14.5), X(oy, s, sw, 13.5)
		m := X(oy, s, sw, 5.5)
		stroke_line(l, t, P(ox, s, 6), t, sw, col)
		stroke_line(P(ox, s, 6), t, P(ox, s, 7.5), m, sw, col, true)
		stroke_line(P(ox, s, 7.5), m, r, m, sw, col)
		stroke_line(l, t, l, b, sw, col)
		stroke_line(l, b, r, b, sw, col)
		stroke_line(r, m, r, b, sw, col)
		if ic == .New_Folder {
			c, d := X(ox, s, sw, 8), X(oy, s, sw, 9.5)
			stroke_line(c, P(oy, s, 7.5), c, P(oy, s, 11.5), sw, col)
			stroke_line(P(ox, s, 6), d, P(ox, s, 10), d, sw, col)
		} else if ic == .Reveal {
			// an arrow up and to the right, out of the folder
			stroke_line(P(ox, s, 6), P(oy, s, 11.5), P(ox, s, 10), P(oy, s, 7.5), sw, col, true)
			stroke_line(P(ox, s, 7.5), P(oy, s, 7.5), P(ox, s, 10), P(oy, s, 7.5), sw, col, true)
			stroke_line(P(ox, s, 10), P(oy, s, 7.5), P(ox, s, 10), P(oy, s, 10), sw, col, true)
		}
	case .Chat:
		// a rounded bubble with a tail at its bottom left
		l, t, r, b := X(ox, s, sw, 2), X(oy, s, sw, 3), X(ox, s, sw, 14), X(oy, s, sw, 11)
		k := 1.5 * s // corner cut
		stroke_line(l + k, t, r - k, t, sw, col)
		stroke_line(r - k, t, r, t + k, sw, col, true)
		stroke_line(r, t + k, r, b - k, sw, col)
		stroke_line(r, b - k, r - k, b, sw, col, true)
		stroke_line(r - k, b, P(ox, s, 7.5), b, sw, col)
		stroke_line(P(ox, s, 7.5), b, P(ox, s, 4.5), P(oy, s, 14), sw, col, true)
		stroke_line(P(ox, s, 4.5), P(oy, s, 14), P(ox, s, 4.5), b, sw, col, true)
		stroke_line(P(ox, s, 4.5), b, l + k, b, sw, col)
		stroke_line(l + k, b, l, b - k, sw, col, true)
		stroke_line(l, b - k, l, t + k, sw, col)
		stroke_line(l, t + k, l + k, t, sw, col, true)
	case .Branch:
		// a line with a commit at each end, a side branch curving into it
		r := 1.8 * s
		a := X(ox, s, sw, 5)
		stroke_ring(a, P(oy, s, 3.5), r, sw, col)
		stroke_ring(a, P(oy, s, 12.5), r, sw, col)
		stroke_ring(P(ox, s, 11.5), P(oy, s, 4.5), r, sw, col)
		stroke_line(a, P(oy, s, 3.5) + r, a, P(oy, s, 12.5) - r, sw, col)
		stroke_line(P(ox, s, 11.5), P(oy, s, 4.5) + r, P(ox, s, 11.5), P(oy, s, 7), sw, col, true)
		stroke_line(P(ox, s, 11.5), P(oy, s, 7), P(ox, s, 9.5), P(oy, s, 9.5), sw, col, true)
		stroke_line(P(ox, s, 9.5), P(oy, s, 9.5), a, P(oy, s, 10.5), sw, col, true)
	case .Chevron_Right:
		stroke_line(P(ox, s, 6), P(oy, s, 4), P(ox, s, 10), P(oy, s, 8), sw, col, true)
		stroke_line(P(ox, s, 10), P(oy, s, 8), P(ox, s, 6), P(oy, s, 12), sw, col, true)
	case .Sort:
		// an arrow up on the left, an arrow down on the right
		a, c := X(ox, s, sw, 5), X(ox, s, sw, 11)
		stroke_line(a, P(oy, s, 2.5), a, P(oy, s, 13), sw, col)
		stroke_line(P(ox, s, 2), P(oy, s, 5.5), a, P(oy, s, 2.5), sw, col, true)
		stroke_line(a, P(oy, s, 2.5), P(ox, s, 8), P(oy, s, 5.5), sw, col, true)
		stroke_line(c, P(oy, s, 3), c, P(oy, s, 13.5), sw, col)
		stroke_line(P(ox, s, 8), P(oy, s, 10.5), c, P(oy, s, 13.5), sw, col, true)
		stroke_line(c, P(oy, s, 13.5), P(ox, s, 14), P(oy, s, 10.5), sw, col, true)
	case .Collapse_All:
		stroke_rect(X(ox, s, sw, 2.5), X(oy, s, sw, 2.5), X(ox, s, sw, 13.5), X(oy, s, sw, 13.5), sw, col)
		d := X(oy, s, sw, 8)
		stroke_line(P(ox, s, 5.5), d, P(ox, s, 10.5), d, sw, col)
	case .Bell:
		// a dome (half circle), its sides flaring to a rim, the clapper under it
		cx, cy, r := P(ox, s, 8), P(oy, s, 7.5), 4 * s
		arc(cx, cy, r, 0, math.PI, sw, col)
		rim := X(oy, s, sw, 11.5)
		stroke_line(cx + r, cy, P(ox, s, 12.5), P(oy, s, 10.5), sw, col, true)
		stroke_line(P(ox, s, 12.5), P(oy, s, 10.5), P(ox, s, 13.5), rim, sw, col, true)
		stroke_line(cx - r, cy, P(ox, s, 3.5), P(oy, s, 10.5), sw, col, true)
		stroke_line(P(ox, s, 3.5), P(oy, s, 10.5), P(ox, s, 2.5), rim, sw, col, true)
		stroke_line(P(ox, s, 2.5), rim, P(ox, s, 13.5), rim, sw, col)
		fill_disc(cx, P(oy, s, 13.5), max(1.2 * s, sw * 0.8), col)
		c := X(ox, s, sw, 8)
		stroke_line(c, P(oy, s, 2), c, cy - r, sw, col)
	case .Alert:
		// a triangle on its base, "!" inside
		top, bl, br := [2]f32{P(ox, s, 8), P(oy, s, 2)}, [2]f32{P(ox, s, 1.5), X(oy, s, sw, 13.5)}, [2]f32{P(ox, s, 14.5), X(oy, s, sw, 13.5)}
		stroke_line(top.x, top.y, br.x, br.y, sw, col, true)
		stroke_line(br.x, br.y, bl.x, bl.y, sw, col)
		stroke_line(bl.x, bl.y, top.x, top.y, sw, col, true)
		c := X(ox, s, sw, 8)
		stroke_line(c, P(oy, s, 6), c, P(oy, s, 9), sw, col)
		fill_disc(c, P(oy, s, 11.25), max(0.9 * s, sw * 0.7), col)
	case .Harness_Pi:
		// π: the bar, a straight left leg, a right leg that turns out at its foot
		t := X(oy, s, sw, 4.5)
		stroke_line(P(ox, s, 2.5), t, P(ox, s, 13.5), t, sw, col, true)
		stroke_line(P(ox, s, 6), t, P(ox, s, 5.5), P(oy, s, 13), sw, col, true)
		stroke_line(P(ox, s, 10.5), t, P(ox, s, 10.5), P(oy, s, 11.5), sw, col, true)
		stroke_line(P(ox, s, 10.5), P(oy, s, 11.5), P(ox, s, 12.5), P(oy, s, 13), sw, col, true)
	case .Harness_Claude:
		// an asterisk: three strokes through the middle
		cx, cy, r := P(ox, s, 8), P(oy, s, 8), 5.5 * s
		for deg in ([3]f32{90, 30, 150}) {
			a := deg * math.PI / 180
			dx, dy := r * math.cos(a), r * math.sin(a)
			stroke_line(cx - dx, cy - dy, cx + dx, cy + dy, sw, col, true)
		}
	case .Info:
		cx, cy := X(ox, s, sw, 8), X(oy, s, sw, 8)
		stroke_ring(cx, cy, 6 * s, sw, col)
		fill_disc(cx, P(oy, s, 5), max(0.9 * s, sw * 0.7), col)
		stroke_line(cx, P(oy, s, 7.5), cx, P(oy, s, 11.5), sw, col)
	case .Clock:
		cx, cy := X(ox, s, sw, 8), X(oy, s, sw, 8)
		stroke_ring(cx, cy, 6 * s, sw, col)
		stroke_line(cx, cy, cx, P(oy, s, 4.5), sw, col)
		stroke_line(cx, cy, P(ox, s, 10.5), P(oy, s, 9.5), sw, col, true)
	case .Refresh:
		// three quarters of a circle, an arrow head at its open end
		cx, cy, r := P(ox, s, 8), P(oy, s, 8), 5.5 * s
		steps :: 18
		a0, a1 := f32(-0.25 * math.PI), f32(1.25 * math.PI)
		for i in 0 ..< steps {
			u0 := a0 + (a1 - a0) * f32(i) / steps
			u1 := a0 + (a1 - a0) * f32(i + 1) / steps
			stroke_line(cx + r * math.cos(u0), cy - r * math.sin(u0), cx + r * math.cos(u1), cy - r * math.sin(u1), sw, col, true)
		}
		ex, ey := cx + r * math.cos(a0), cy - r * math.sin(a0)
		stroke_line(ex, ey, ex, ey - 3.5 * s, sw, col, true)
		stroke_line(ex, ey, ex - 3.5 * s, ey, sw, col, true)
	case .Play:
		x0, x1 := P(ox, s, 5), P(ox, s, 12)
		y0, ym, y1 := P(oy, s, 3.5), P(oy, s, 8), P(oy, s, 12.5)
		stroke_line(x0, y0, x0, y1, sw, col, true)
		stroke_line(x0, y0, x1, ym, sw, col, true)
		stroke_line(x0, y1, x1, ym, sw, col, true)
	case .Pause:
		stroke_line(X(ox, s, sw, 6), P(oy, s, 4), X(ox, s, sw, 6), P(oy, s, 12), sw, col, false)
		stroke_line(X(ox, s, sw, 10), P(oy, s, 4), X(ox, s, sw, 10), P(oy, s, 12), sw, col, false)
	case .Mark_Idle, .Mark_Exited, .Mark_Working, .Mark_Progress, .Mark_Waiting, .Mark_Permission, .Mark_Question, .Mark_Auth, .Mark_Done, .Mark_Error:
		draw_mark(ic, ox, oy, s, sw, col, param)
	}
}

// MARK_RING_R: a working or progress mark's ring (grid units): its outer edge stays inside the box with
// the stroke, as the glyphs' do (each spans about 2..14 of the 16 units, centred on 8,8).
MARK_RING_R :: 5.5

// A status mark (core.Status_Mark) on the 16-unit grid at (ox, oy), unit s px, stroke sw px.
@(private = "file")
draw_mark :: proc(ic: core.Icon, ox, oy, s, sw: f32, col: core.Rgba, param: u8) {
	P :: proc(o, s, v: f32) -> f32 {return o + v * s}
	snap :: proc(v, sw: f32) -> f32 {return int(sw) % 2 == 1 ? math.floor(v) + 0.5 : math.round(v)}
	X :: proc(ox, s, sw, v: f32) -> f32 {return snap(ox + v * s, sw)}
	// round shapes on the box's centre; a glyph's vertical strokes on the pixel grid (cx)
	mx, my := P(ox, s, 8), P(oy, s, 8)
	cx := X(ox, s, sw, 8)
	dot_r := max(1.1 * s, sw * 0.75) // a glyph's dot ("?", "!"), as Alert's and Info's
	#partial switch ic {
	case .Mark_Idle:
		fill_disc(mx, my, 2 * s, col)
	case .Mark_Exited:
		fill_disc(mx, my, 3.5 * s, col)
	case .Mark_Waiting:
		fill_disc(mx, my, 4.5 * s, col)
	case .Mark_Working:
		// a faint track, a bright arc turning clockwise one step a frame
		track := col
		track.a = u8(f32(col.a) * 0.25)
		r := MARK_RING_R * s
		stroke_ring(mx, my, r, sw, track)
		head := f32(math.PI / 2) - f32(param % SPIN_STEPS) * 2 * math.PI / SPIN_STEPS
		arc(mx, my, r, head - 0.55 * math.PI, head, sw, col)
	case .Mark_Progress:
		// the ring, and a pie inside it from twelve o'clock, clockwise
		stroke_ring(mx, my, MARK_RING_R * s, sw, col)
		f := f32(min(param, 100)) / 100
		pr := MARK_RING_R * s - sw / 2 - max(1, 1.25 * s) // a clear gap inside the ring
		if f >= 0.995 do fill_disc(mx, my, pr, col)
		else if f > 0 do fill_sector(mx, my, pr, math.PI / 2 - f * 2 * math.PI, math.PI / 2, col)
	case .Mark_Permission:
		// a shield: a flat top rising to a point, straight sides, a point below
		l, r := X(ox, s, sw, 3.5), X(ox, s, sw, 12.5)
		c := (l + r) / 2 // between its snapped sides, so it is symmetric
		t, peak, side, bot := P(oy, s, 3.25), P(oy, s, 1.75), P(oy, s, 8.5), P(oy, s, 14.25)
		stroke_line(l, t, c, peak, sw, col, true)
		stroke_line(c, peak, r, t, sw, col, true)
		stroke_line(r, t, r, side, sw, col)
		stroke_line(r, side, c, bot, sw, col, true)
		stroke_line(c, bot, l, side, sw, col, true)
		stroke_line(l, side, l, t, sw, col)
	case .Mark_Question:
		// a hook over the top, down to the middle, a dot under it
		hx, hy, hr := cx, P(oy, s, 5.5), 3.25 * s
		a0 := f32(-40 * math.PI / 180)
		arc(hx, hy, hr, a0, math.PI, sw, col)
		ex, ey := hx + hr * math.cos(a0), hy - hr * math.sin(a0)
		stroke_line(ex, ey, cx, P(oy, s, 9.25), sw, col, true)
		stroke_line(cx, P(oy, s, 9.25), cx, P(oy, s, 10.25), sw, col, true)
		fill_disc(cx, P(oy, s, 13.25), dot_r, col)
	case .Mark_Auth:
		// a lock: a solid body, a shackle over it (together about 2.75..13.25: centred)
		l, r := math.round(P(ox, s, 3.5)), math.round(P(ox, s, 12.5))
		top, bot := math.round(P(oy, s, 6.75)), math.round(P(oy, s, 13.25))
		draw_rect(l, top, r - l, bot - top, col)
		arc((l + r) / 2, top, 3 * s, 0, math.PI, sw, col)
	case .Mark_Done:
		stroke_line(P(ox, s, 3), P(oy, s, 8.5), P(ox, s, 6.5), P(oy, s, 12), sw, col, true)
		stroke_line(P(ox, s, 6.5), P(oy, s, 12), P(ox, s, 13), P(oy, s, 4), sw, col, true)
	case .Mark_Error:
		stroke_line(cx, P(oy, s, 2.75), cx, P(oy, s, 9.5), sw, col, true)
		fill_disc(cx, P(oy, s, 13), dot_r, col)
	}
}

// ---- primitives (framebuffer px; inside sgl.begin_quads) ----

@(private = "file")
vtx :: proc(x, y: f32, col: core.Rgba, a: f32) {
	u := f32(0.5) / f32(font.size) // the atlas's white texel (draw_rect)
	sgl.v2f_t2f_c4b(x, y, u, u, col.r, col.g, col.b, u8(f32(col.a) * a))
}

// A quad with alpha a0 along edge p0-p1 and a1 along edge p3-p2.
@(private = "file")
quad :: proc(p0, p1, p2, p3: [2]f32, col: core.Rgba, a0, a1: f32) {
	vtx(p0.x, p0.y, col, a0)
	vtx(p1.x, p1.y, col, a0)
	vtx(p2.x, p2.y, col, a1)
	vtx(p3.x, p3.y, col, a1)
}

// A stroke from (x0,y0) to (x1,y1), w px wide, with a feathered edge.
// Square caps (half the width beyond each end) unless `round`.
stroke_line :: proc(x0, y0, x1, y1, w: f32, col: core.Rgba, round := false) {
	a, b := [2]f32{x0, y0}, [2]f32{x1, y1}
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.001 do return
	d /= l
	n := [2]f32{-d.y, d.x}
	axis := abs(d.x) < 0.001 || abs(d.y) < 0.001
	if !round {
		a -= d * (w / 2)
		b += d * (w / 2)
	}
	if axis {
		// on the pixel grid: a plain rectangle, no feather needed
		an := [2]f32{abs(n.x), abs(n.y)}
		lo := [2]f32{min(a.x, b.x), min(a.y, b.y)} - an * (w / 2)
		hi := [2]f32{max(a.x, b.x), max(a.y, b.y)} + an * (w / 2)
		draw_rect(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y, col)
	} else {
		core := max(w / 2 - 0.5, 0)
		outer := w / 2 + 0.5
		ca := min(w, 1) // a hairline is fainter
		quad(a - n * core, b - n * core, b + n * core, a + n * core, col, ca, ca)
		quad(a + n * core, b + n * core, b + n * outer, a + n * outer, col, ca, 0)
		quad(a - n * core, b - n * core, b - n * outer, a - n * outer, col, ca, 0)
	}
	if round {
		fill_disc(x0, y0, w / 2, col)
		fill_disc(x1, y1, w / 2, col)
	}
}

// An arc of radius r from angle a0 to a1 (radians, counter-clockwise from
// the right, y up), w px wide.
arc :: proc(cx, cy, r, a0, a1, w: f32, col: core.Rgba) {
	steps :: 16
	for i in 0 ..< steps {
		u0 := a0 + (a1 - a0) * f32(i) / steps
		u1 := a0 + (a1 - a0) * f32(i + 1) / steps
		stroke_line(cx + r * math.cos(u0), cy - r * math.sin(u0), cx + r * math.cos(u1), cy - r * math.sin(u1), w, col, true)
	}
}

// A rectangle outline whose strokes are centred on l, t, r, b.
stroke_rect :: proc(l, t, r, b, w: f32, col: core.Rgba) {
	stroke_line(l, t, r, t, w, col)
	stroke_line(l, b, r, b, w, col)
	stroke_line(l, t, l, b, w, col)
	stroke_line(r, t, r, b, w, col)
}

ICON_SEGMENTS :: 32

// A circle outline of radius r (stroke centre), w px wide.
stroke_ring :: proc(cx, cy, r, w: f32, col: core.Rgba) {
	inner, outer := max(r - w / 2, 0), r + w / 2
	ring(cx, cy, inner - 0.5, inner + 0.5, col, 0, 1)
	ring(cx, cy, inner + 0.5, outer - 0.5, col, 1, 1)
	ring(cx, cy, outer - 0.5, outer + 0.5, col, 1, 0)
}

// A filled circle of radius r.
fill_disc :: proc(cx, cy, r: f32, col: core.Rgba) {
	ring(cx, cy, 0, max(r - 0.5, 0), col, 1, 1)
	ring(cx, cy, max(r - 0.5, 0), r + 0.5, col, 1, 0)
}

// A filled pie slice of radius r from angle a0 to a1 (radians, counter-clockwise from the right,
// y up), its round edge feathered.
fill_sector :: proc(cx, cy, r, a0, a1: f32, col: core.Rgba) {
	if a1 <= a0 || r <= 0 do return
	steps := max(2, int((a1 - a0) / (2 * math.PI) * ICON_SEGMENTS) + 1)
	c := [2]f32{cx, cy}
	inner, outer := max(r - 0.5, 0), r + 0.5
	for i in 0 ..< steps {
		u0 := a0 + (a1 - a0) * f32(i) / f32(steps)
		u1 := a0 + (a1 - a0) * f32(i + 1) / f32(steps)
		d0, d1 := [2]f32{math.cos(u0), -math.sin(u0)}, [2]f32{math.cos(u1), -math.sin(u1)}
		quad(c, c, c + d1 * inner, c + d0 * inner, col, 1, 1)
		quad(c + d0 * inner, c + d1 * inner, c + d1 * outer, c + d0 * outer, col, 1, 0)
	}
}

// The band between radii r0 and r1, alpha a0 at r0 and a1 at r1.
@(private = "file")
ring :: proc(cx, cy, r0, r1: f32, col: core.Rgba, a0, a1: f32) {
	if r1 <= r0 do return
	r0 := max(r0, 0)
	for i in 0 ..< ICON_SEGMENTS {
		t0 := f32(i) / ICON_SEGMENTS * 2 * math.PI
		t1 := f32(i + 1) / ICON_SEGMENTS * 2 * math.PI
		u0, u1 := [2]f32{math.cos(t0), math.sin(t0)}, [2]f32{math.cos(t1), math.sin(t1)}
		c := [2]f32{cx, cy}
		quad(c + u0 * r0, c + u1 * r0, c + u1 * r1, c + u0 * r1, col, a0, a1)
	}
}
