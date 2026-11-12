package main

// Borders follow their box's rounded corners (draw_border, ui.odin): a ring over the fill
// (draw_round_rect), not four rectangles. The quads are recorded and rasterised here the way the
// GPU does it (a pixel is covered when its centre is inside a quad), so the tests read pixels.

import "core:fmt"
import "core:math"
import "core:testing"
import clay "../build/clay-odin"
import "core"

@(private = "file")
GRID :: 600

@(private = "file")
Rec :: struct {
	cover: [GRID * GRID]f32, // summed alpha (0..1 per quad): above 1 = a pixel drawn twice
	quads: [dynamic][5]f32, // x, y, w, h, alpha
}

@(private = "file")
rec: ^Rec

@(private = "file")
rec_sink :: proc(x, y, w, h: f32, col: core.Rgba) {
	append(&rec.quads, [5]f32{x, y, w, h, f32(col.a) / 255})
	x0, x1 := int(math.ceil(x - 0.5)), int(math.ceil(x + w - 0.5)) // centres in [x, x + w)
	y0, y1 := int(math.ceil(y - 0.5)), int(math.ceil(y + h - 0.5))
	for py in max(y0, 0) ..< min(y1, GRID) do for px in max(x0, 0) ..< min(x1, GRID) do rec.cover[py * GRID + px] += f32(col.a) / 255
}

@(private = "file")
rec_new :: proc() -> ^Rec {
	r := new(Rec)
	return r
}

@(private = "file")
rec_free :: proc(r: ^Rec) {
	delete(r.quads)
	free(r)
}

@(private = "file")
fill_of :: proc(x, y, w, h: f32, radius: clay.CornerRadius) -> ^Rec {
	rec = rec_new()
	draw_round_rect(x, y, w, h, radius, {255, 255, 255, 255}, rec_sink)
	return rec
}

@(private = "file")
border_of :: proc(x, y, w, h: f32, radius: clay.CornerRadius, width: clay.BorderWidth, alpha: f32 = 255) -> ^Rec {
	rec = rec_new()
	draw_border(x, y, w, h, {color = {255, 255, 255, alpha}, cornerRadius = radius, width = width}, rec_sink)
	return rec
}

@(private = "file")
all4 :: proc(r: f32) -> clay.CornerRadius {return {r, r, r, r}}

@(private = "file")
sides :: proc(w: u16) -> clay.BorderWidth {return {w, w, w, w, 0}}

// The fill before borders followed corners: one radius (top left) for all four.
@(private = "file")
old_round_rect :: proc(x, y, w, h, radius: f32, col: core.Rgba, rect: Rect_Sink) {
	r := math.floor(min(radius, w / 2, h / 2))
	if r < 1 {
		rect(x, y, w, h, col)
		return
	}
	rect(x, y + r, w, h - 2 * r, col)
	for i in 0 ..< int(r) {
		dy := r - f32(i) - 0.5
		inset := r - math.sqrt(r * r - dy * dy)
		full := math.ceil(inset)
		edge := with_alpha(col, full - inset)
		rows := [2]f32{y + f32(i), y + h - 1 - f32(i)}
		for row_y in rows {
			rect(x + full, row_y, w - 2 * full, 1, col)
			if full - inset > 0.01 {
				rect(x + full - 1, row_y, 1, 1, edge)
				rect(x + w - full, row_y, 1, 1, edge)
			}
		}
	}
}

// The scales a box is drawn at: 1x, 2x and DECKHAND_SCALE's in-between values.
@(private = "file")
SCALES :: [?]f32{1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4}

@(test)
round_rect_one_radius_is_unchanged :: proc(t: ^testing.T) {
	for s in SCALES {
		for base in ([]f32{0, 0.5, RADIUS_SM, RADIUS_MD, RADIUS_MD + SP_1, CHIP_H / 2, 40}) {
			for size in ([][2]f32{{80, 28}, {CHIP_H * 2, CHIP_H}, {17, 9}, {9, 30}}) {
				x, y, w, h := f32(3), f32(5), math.round(size.x * s), math.round(size.y * s)
				now := fill_of(x, y, w, h, all4(base * s))
				before := rec_new()
				rec = before
				old_round_rect(x, y, w, h, base * s, {255, 255, 255, 255}, rec_sink)
				same := true
				for i in 0 ..< GRID * GRID do if now.cover[i] != before.cover[i] do same = false
				testing.expectf(t, same, "fill at %vx, radius %v, %vx%v: the same pixels as before", s, base, w, h)
				rec_free(now)
				rec_free(before)
			}
		}
	}
}

@(test)
round_rect_each_corner_its_own :: proc(t: ^testing.T) {
	x, y, w, h := f32(2), f32(2), f32(60), f32(30)
	r := fill_of(x, y, w, h, {topLeft = 0, topRight = 10, bottomLeft = 6, bottomRight = 0})
	defer rec_free(r)
	at :: proc(r: ^Rec, px, py: f32) -> f32 {return r.cover[int(py) * GRID + int(px)]}
	testing.expect(t, at(r, x, y) == 1, "top left square")
	testing.expect(t, at(r, x + w - 1, y + h - 1) == 1, "bottom right square")
	testing.expect(t, at(r, x + w - 1, y) == 0, "top right rounded")
	testing.expect(t, at(r, x, y + h - 1) == 0, "bottom left rounded")
	testing.expect(t, at(r, x + w - 4, y + 1) < 1, "top right's curve is 10 px")
	testing.expect(t, at(r, x + 2, y + h - 2) < 1 && at(r, x + 3, y + h - 3) == 1, "bottom left's curve is 6 px")
	for i in 0 ..< GRID * GRID do if r.cover[i] > 1.001 {
		testing.expectf(t, false, "pixel %v drawn twice", i)
		break
	}
}

// The ring checks for one box: nothing drawn twice; outside the fill nothing, and the fill's
// anti-aliased rim covered exactly as much as the fill covers it; inside the inner curve nothing;
// the straight runs solid; and the ring's area within a pixel or so of the true one.
@(private = "file")
expect_ring :: proc(t: ^testing.T, label: string, x, y, w, h: f32, radius: f32, l, r, tp, b: u16) {
	f := fill_of(x, y, w, h, all4(radius))
	defer rec_free(f)
	bd := border_of(x, y, w, h, all4(radius), {l, r, tp, b, 0})
	defer rec_free(bd)
	k := corner_px(radius, w, h)
	L, R, T, B := f32(l), f32(r), f32(tp), f32(b)
	testing.expectf(t, len(bd.quads) > 4, "%s: a ring, not four rectangles (%d quads)", label, len(bd.quads))

	twice, outside, hole, gaps := 0, 0, 0, 0
	area: f32
	for py in 0 ..< GRID do for px in 0 ..< GRID {
		c := bd.cover[py * GRID + px]
		fc := f.cover[py * GRID + px]
		area += c
		if c > 1.001 do twice += 1
		if fc < 0.999 && abs(c - fc) > 1.5 / 255 do outside += 1
		// the hole: more than a pixel inside the inner rounded rect (radii k - side)
		cx, cy := f32(px) + 0.5 - x, f32(py) + 0.5 - y
		if cx > L + 1 && cx < w - R - 1 && cy > T + 1 && cy < h - B - 1 {
			// distance inside the inner curve's ellipse at the nearest corner
			ex := cx < w / 2 ? k - L : k - R
			ey := cy < h / 2 ? k - T : k - B
			ox := cx < w / 2 ? k : w - k
			oy := cy < h / 2 ? k : h - k
			dx, dy := abs(cx - ox), abs(cy - oy)
			in_corner := (cx < k || cx > w - k) && (cy < k || cy > h - k)
			inside := !in_corner || (dx / (ex - 1)) * (dx / (ex - 1)) + (dy / (ey - 1)) * (dy / (ey - 1)) < 1
			if inside && c != 0 do hole += 1
		}
		// the straight runs
		on_side := ((cx > 0 && cx < L) || (cx > w - R && cx < w)) && cy > k && cy < h - k
		on_top := ((cy > 0 && cy < T) || (cy > h - B && cy < h)) && cx > k && cx < w - k
		if (on_side || on_top) && c != 1 do gaps += 1
	}
	testing.expectf(t, twice == 0, "%s: %d pixels drawn twice", label, twice)
	testing.expectf(t, outside == 0, "%s: %d pixels off the fill's edge", label, outside)
	testing.expectf(t, hole == 0, "%s: %d pixels inside the inner curve", label, hole)
	testing.expectf(t, gaps == 0, "%s: %d pixels missing on the straight runs", label, gaps)

	// outer rounded rect minus the inner one (its corners quarter ellipses k - side across)
	outer := w * h - (4 - math.PI) * k * k
	inner := (w - L - R) * (h - T - B)
	for c in ([4][2]f32{{L, T}, {R, T}, {L, B}, {R, B}}) do inner -= (1 - math.PI / 4) * (k - c.x) * (k - c.y)
	want := outer - inner
	testing.expectf(t, abs(area - want) < 1 + 0.004 * want, "%s: area %.2f, want %.2f", label, area, want)
}

@(test)
border_rounded_ring_at_every_scale :: proc(t: ^testing.T) {
	for s in SCALES {
		for base in ([]f32{RADIUS_SM, RADIUS_MD, RADIUS_MD + SP_1, CHIP_H / 2}) {
			for wd in ([]u16{1, 2, u16(math.round(s))}) {
				w, h := math.round(90 * s), math.round(CHIP_H * s)
				if base * s > h / 2 do h = math.round(2 * base * s)
				label := fmt.tprintf("%vx radius %v width %d", s, base, wd)
				expect_ring(t, label, 3, 4, w, h, base * s, wd, wd, wd, wd)
			}
		}
	}
}

@(test)
border_rounded_uneven_widths :: proc(t: ^testing.T) {
	expect_ring(t, "left 1 top 2", 3, 4, 120, 50, 12, 1, 1, 2, 2)
	expect_ring(t, "left 3 top 1", 3, 4, 120, 50, 12, 3, 2, 1, 2)
	expect_ring(t, "pill 2", 3, 4, 96, 24, 12, 2, 2, 2, 2)
}

@(test)
border_square_corners_drawn_once :: proc(t: ^testing.T) {
	x, y, w, h := f32(3), f32(4), f32(50), f32(20)
	bd := border_of(x, y, w, h, all4(0), sides(2), 128)
	defer rec_free(bd)
	testing.expectf(t, len(bd.quads) == 4, "four rectangles: %v", bd.quads[:])
	a := f32(128) / 255
	ok := true
	for py in 0 ..< GRID do for px in 0 ..< GRID {
		cx, cy := f32(px) + 0.5, f32(py) + 0.5
		in_box := cx > x && cx < x + w && cy > y && cy < y + h
		in_hole := cx > x + 2 && cx < x + w - 2 && cy > y + 2 && cy < y + h - 2
		want := in_box && !in_hole ? a : 0
		if abs(bd.cover[py * GRID + px] - want) > 1e-4 do ok = false
	}
	testing.expect(t, ok, "the frame of the old four rectangles, each corner pixel drawn once")
}

@(test)
border_one_side_stays_straight :: proc(t: ^testing.T) {
	x, y, w, h := f32(3), f32(4), f32(50), f32(20)
	{
		bd := border_of(x, y, w, h, all4(6), {top = 1})
		defer rec_free(bd)
		testing.expectf(t, len(bd.quads) == 1 && bd.quads[0] == {x, y, w, 1, 1}, "top alone: one full-width line, %v", bd.quads[:])
	}
	{
		bd := border_of(x, y, w, h, all4(6), {left = 2})
		defer rec_free(bd)
		testing.expectf(t, len(bd.quads) == 1 && bd.quads[0] == {x, y, 2, h, 1}, "left alone: one full-height line, %v", bd.quads[:])
	}
	{
		bd := border_of(x, y, w, h, all4(6), {bottom = 1, top = 1})
		defer rec_free(bd)
		testing.expectf(t, len(bd.quads) == 2 && bd.quads[0] == {x, y, w, 1, 1} && bd.quads[1] == {x, y + h - 1, w, 1, 1}, "top and bottom: two lines, %v", bd.quads[:])
	}
	{
		// three sides: the top corners round, the bottom ones square (no bottom border)
		f := fill_of(x, y, w, h, all4(6))
		defer rec_free(f)
		bd := border_of(x, y, w, h, all4(6), {left = 1, right = 1, top = 1})
		defer rec_free(bd)
		at :: proc(r: ^Rec, px, py: f32) -> f32 {return r.cover[int(py) * GRID + int(px)]}
		testing.expect(t, at(bd, x, y) == at(f, x, y) && at(bd, x, y) < 1, "top left follows the fill")
		testing.expect(t, at(bd, x + w - 1, y) == at(f, x + w - 1, y), "top right follows the fill")
		testing.expect(t, at(bd, x, y + h - 1) == 1 && at(bd, x + w - 1, y + h - 1) == 1, "the sides run straight to the bottom")
		twice := 0
		for i in 0 ..< GRID * GRID do if bd.cover[i] > 1.001 do twice += 1
		testing.expectf(t, twice == 0, "%d pixels drawn twice", twice)
	}
	{
		// a border as wide as the radius: square corners
		bd := border_of(x, y, w, h, all4(2), sides(2))
		defer rec_free(bd)
		testing.expectf(t, len(bd.quads) == 4, "width 2 on radius 2: four rectangles, %v", bd.quads[:])
	}
}

@(test)
border_each_corner_its_own :: proc(t: ^testing.T) {
	x, y, w, h := f32(3), f32(4), f32(80), f32(40)
	radius := clay.CornerRadius{topLeft = 0, topRight = 12, bottomLeft = 8, bottomRight = 4}
	f := fill_of(x, y, w, h, radius)
	defer rec_free(f)
	bd := border_of(x, y, w, h, radius, sides(1))
	defer rec_free(bd)
	off, twice := 0, 0
	for i in 0 ..< GRID * GRID {
		if f.cover[i] < 0.999 && abs(bd.cover[i] - f.cover[i]) > 1.5 / 255 do off += 1
		if bd.cover[i] > 1.001 do twice += 1
	}
	testing.expectf(t, off == 0, "%d pixels off the fill's edge", off)
	testing.expectf(t, twice == 0, "%d pixels drawn twice", twice)
	testing.expect(t, bd.cover[int(y) * GRID + int(x)] == 1, "the square corner is solid")
}

@(test)
border_transparent_draws_nothing :: proc(t: ^testing.T) {
	bd := border_of(3, 4, 50, 20, all4(6), sides(1), 0)
	defer rec_free(bd)
	testing.expect(t, len(bd.quads) == 0, "no quads")
}
