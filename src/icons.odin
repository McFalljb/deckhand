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
import clay "../build/clay-odin"
import sgl "../vendor/sokol-odin/sokol/gl"

Icon :: enum u8 {
	None,
	Search, // magnifier
	Compose, // square and pencil: new chat
	Plus,
	Chevron_Down,
	Sidebar_Left, // a window with its left column (filled while shown)
	Sidebar_Left_On,
	Sidebar_Right,
	Sidebar_Right_On,
	Sliders, // settings
	Close,
	More, // three dots
	Check,
	// the Files tab's header (ui_files.odin)
	New_File, // a page and a plus
	New_Folder, // a folder and a plus
	Collapse_All, // a box with a minus
	Refresh, // a circular arrow
	Reveal, // a folder with an arrow out of it
	// the left column: what a row is (ui_sidebar.odin), the tree and sort controls
	Folder, // a project (and its sessions)
	Chat, // a speech bubble: a chat, outside any project
	Chevron_Right, // a folded tree row or section
	Sort, // two arrows, up and down
	Branch, // a git branch: two commits on a line, a third off it (the Files tab's checkout switcher)
	// the bell (ui_bell.odin)
	Bell, // the notification centre
	Alert, // a triangle with "!": an error, pi exited
	Clock, // a job (the bell; the left column's Jobs tab)
	Play, // a triangle: run now
	Pause, // two bars: pause
	Info, // a ring with an "i": a session's info (ui_sidebar.odin)
	// which agent a session runs (sidebar.odin: HARNESSES): its real logo (logos.odin), in its
	// own colours; the plain glyphs stay as the fallback for a harness without one
	Logo_Pi,
	Logo_Claude,
	Harness_Pi, // "π": a bar on two legs
	Harness_Claude, // a six-pointed asterisk
}

// The logo an icon draws (.None: a vector icon in the caller's colour).
icon_logo :: proc(ic: Icon) -> Logo {
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
// customData carries the icon, userData the colour (packed RGBA).
icon :: proc(ic: Icon, col: Rgba, size: f32 = ICON_SIZE) {
	packed := uintptr(col.r) | uintptr(col.g) << 8 | uintptr(col.b) << 16 | uintptr(col.a) << 24
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(px(size)), clay.SizingFixed(px(size))}},
		custom = {customData = rawptr(uintptr(ic))},
		userData = rawptr(packed),
	}) {}
}

// From a custom render command (ui_draw).
icon_of_command :: proc(cmd: ^clay.RenderCommand) -> (Icon, Rgba) {
	p := uintptr(cmd.userData)
	return Icon(uintptr(cmd.renderData.custom.customData)), {u8(p), u8(p >> 8), u8(p >> 16), u8(p >> 24)}
}

// Draws `ic` into the box (framebuffer px), inside draw_begin/draw_end.
draw_icon :: proc(ic: Icon, x, y, w, h: f32, col: Rgba) {
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
	}
}

// ---- primitives (framebuffer px; inside sgl.begin_quads) ----

@(private = "file")
vtx :: proc(x, y: f32, col: Rgba, a: f32) {
	u := f32(0.5) / f32(font.size) // the atlas's white texel (draw_rect)
	sgl.v2f_t2f_c4b(x, y, u, u, col.r, col.g, col.b, u8(f32(col.a) * a))
}

// A quad with alpha a0 along edge p0-p1 and a1 along edge p3-p2.
@(private = "file")
quad :: proc(p0, p1, p2, p3: [2]f32, col: Rgba, a0, a1: f32) {
	vtx(p0.x, p0.y, col, a0)
	vtx(p1.x, p1.y, col, a0)
	vtx(p2.x, p2.y, col, a1)
	vtx(p3.x, p3.y, col, a1)
}

// A stroke from (x0,y0) to (x1,y1), w px wide, with a feathered edge.
// Square caps (half the width beyond each end) unless `round`.
stroke_line :: proc(x0, y0, x1, y1, w: f32, col: Rgba, round := false) {
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
arc :: proc(cx, cy, r, a0, a1, w: f32, col: Rgba) {
	steps :: 16
	for i in 0 ..< steps {
		u0 := a0 + (a1 - a0) * f32(i) / steps
		u1 := a0 + (a1 - a0) * f32(i + 1) / steps
		stroke_line(cx + r * math.cos(u0), cy - r * math.sin(u0), cx + r * math.cos(u1), cy - r * math.sin(u1), w, col, true)
	}
}

// A rectangle outline whose strokes are centred on l, t, r, b.
stroke_rect :: proc(l, t, r, b, w: f32, col: Rgba) {
	stroke_line(l, t, r, t, w, col)
	stroke_line(l, b, r, b, w, col)
	stroke_line(l, t, l, b, w, col)
	stroke_line(r, t, r, b, w, col)
}

ICON_SEGMENTS :: 32

// A circle outline of radius r (stroke centre), w px wide.
stroke_ring :: proc(cx, cy, r, w: f32, col: Rgba) {
	inner, outer := max(r - w / 2, 0), r + w / 2
	ring(cx, cy, inner - 0.5, inner + 0.5, col, 0, 1)
	ring(cx, cy, inner + 0.5, outer - 0.5, col, 1, 1)
	ring(cx, cy, outer - 0.5, outer + 0.5, col, 1, 0)
}

// A filled circle of radius r.
fill_disc :: proc(cx, cy, r: f32, col: Rgba) {
	ring(cx, cy, 0, max(r - 0.5, 0), col, 1, 1)
	ring(cx, cy, max(r - 0.5, 0), r + 0.5, col, 1, 0)
}

// The band between radii r0 and r1, alpha a0 at r0 and a1 at r1.
@(private = "file")
ring :: proc(cx, cy, r0, r1: f32, col: Rgba, a0, a1: f32) {
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
