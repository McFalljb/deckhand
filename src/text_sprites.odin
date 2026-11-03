package main

// Box drawing (light/heavy lines, rounded corners) and block elements drawn
// by hand at the cell size, so lines join across cells with no gaps whatever
// the font's line height. Other box characters (dashes, double lines,
// diagonals) come from the font: double lines would need proper junctions.

import "core:math"

// Arms per character, "urdl" (up, right, down, left): 0 none, 1 light,
// 2 heavy; "...." = not drawn here. U+2500..U+254B, then U+2574..U+257F.
@(private = "file")
ARMS_2500 :: "0101020210102020" + "................................" + // ─━│┃ dashes
	"0110021001200220" + "0011001200210022" + "1100120021002200" + "1001100220012002" + // ┌..┛
	"1110121021101120" + "2120221012202220" + "1011101220111021" + "2021201210222022" + // ├..┫
	"0111011202110212" + "0121012202210222" + "1101110212011202" + "2101210222012202" + // ┬..┻
	"1111111212111212" + "2111112121212112" + "2211112212212212" + "1222212222212222" // ┼..╋
@(private = "file")
ARMS_2574 :: "000110000100001000022000020000200201102001022010"

@(private = "file")
arms :: proc(cp: rune) -> (a: [4]u8, ok: bool) {
	s: string
	t1, t2 := ARMS_2500, ARMS_2574
	switch cp {
	case 0x2500 ..= 0x254B: s = t1[int(cp - 0x2500) * 4:][:4]
	case 0x2574 ..= 0x257F: s = t2[int(cp - 0x2574) * 4:][:4]
	case: return
	}
	if s[0] == '.' do return
	for i in 0 ..< 4 do a[i] = s[i] - '0'
	return a, true
}

sprite_supported :: proc(cp: rune) -> bool {
	switch cp {
	case 0x256D ..= 0x2570, 0x2580 ..= 0x259F: return true
	}
	_, ok := arms(cp)
	return ok
}

@(private = "file")
Canvas :: struct {
	w, h: int,
	px:   []u8, // RGBA
}

@(private = "file")
fill :: proc(c: Canvas, x0, y0, x1, y1: int, a: u8 = 255) {
	for y in max(0, y0) ..< min(c.h, y1) do for x in max(0, x0) ..< min(c.w, x1) {
		o := (y * c.w + x) * 4
		c.px[o + 0], c.px[o + 1], c.px[o + 2] = 255, 255, 255
		c.px[o + 3] = max(c.px[o + 3], a)
	}
}

// Renders cp into px (w x h RGBA, white + coverage). False if not handled.
sprite_render :: proc(cp: rune, w, h: int, px: []u8) -> bool {
	c := Canvas{w, h, px}
	light := int(max(font.line_thick, math.round(font.dpi)))
	heavy := 2 * light
	// stroke start for thickness t, centred in the cell
	vx :: proc(w, t: int) -> int {return (w - t) / 2}

	if a, ok := arms(cp); ok {
		th := [3]int{0, light, heavy}
		tv := max(th[a[0]], th[a[2]]) // vertical stroke through the centre
		thz := max(th[a[1]], th[a[3]])
		if a[0] > 0 {
			t := th[a[0]]
			m := max(thz, t)
			fill(c, vx(w, t), 0, vx(w, t) + t, vx(h, m) + m)
		}
		if a[2] > 0 {
			t := th[a[2]]
			m := max(thz, t)
			fill(c, vx(w, t), vx(h, m), vx(w, t) + t, h)
		}
		if a[3] > 0 {
			t := th[a[3]]
			m := max(tv, t)
			fill(c, 0, vx(h, t), vx(w, m) + m, vx(h, t) + t)
		}
		if a[1] > 0 {
			t := th[a[1]]
			m := max(tv, t)
			fill(c, vx(w, m), vx(h, t), w, vx(h, t) + t)
		}
		return true
	}

	switch cp {
	case 0x256D ..= 0x2570: // ╭ ╮ ╯ ╰
		t := light
		cx := f32(vx(w, t)) + f32(t) / 2 // stroke centre lines
		cy := f32(vx(h, t)) + f32(t) / 2
		r := f32(min(w, h)) / 2
		sx: f32 = cp == 0x256D || cp == 0x2570 ? 1 : -1 // arc centre to the right?
		sy: f32 = cp == 0x256D || cp == 0x256E ? 1 : -1 // ... below?
		ax, ay := cx + sx * r, cy + sy * r
		for y in 0 ..< h do for x in 0 ..< w {
			px_, py := f32(x) + 0.5, f32(y) + 0.5
			if (px_ - ax) * sx > 0.5 || (py - ay) * sy > 0.5 do continue // other quadrants
			d := math.sqrt((px_ - ax) * (px_ - ax) + (py - ay) * (py - ay))
			cov := clamp(f32(t) / 2 + 0.5 - abs(d - r), 0, 1)
			if cov > 0 do fill(c, x, y, x + 1, y + 1, u8(cov * 255))
		}
		// straight parts from the arc's ends to the cell edges
		if sy > 0 do fill(c, vx(w, t), int(ay), vx(w, t) + t, h)
		else do fill(c, vx(w, t), 0, vx(w, t) + t, int(math.ceil(ay)))
		if sx > 0 do fill(c, int(ax), vx(h, t), w, vx(h, t) + t)
		else do fill(c, 0, vx(h, t), int(math.ceil(ax)), vx(h, t) + t)
	case 0x2580: fill(c, 0, 0, w, h / 2) // ▀
	case 0x2581 ..= 0x2588: // ▁..█ lower eighths
		n := int(cp - 0x2580)
		fill(c, 0, h - int(math.round(f32(h * n) / 8)), w, h)
	case 0x2589 ..= 0x258F: // ▉..▏ left eighths, 7/8 down to 1/8
		n := 8 - int(cp - 0x2588)
		fill(c, 0, 0, int(math.round(f32(w * n) / 8)), h)
	case 0x2590: fill(c, w / 2, 0, w, h) // ▐
	case 0x2591 ..= 0x2593: fill(c, 0, 0, w, h, u8(64 * int(cp - 0x2590))) // ░▒▓
	case 0x2594: fill(c, 0, 0, w, int(math.round(f32(h) / 8))) // ▔
	case 0x2595: fill(c, w - int(math.round(f32(w) / 8)), 0, w, h) // ▕
	case 0x2596 ..= 0x259F: // quadrants: bits UL 1, UR 2, LL 4, LR 8
		Q := [10]u8{4, 8, 1, 13, 9, 7, 11, 2, 6, 14}
		q := Q[cp - 0x2596]
		hw, hh := w / 2, h / 2
		if q & 1 != 0 do fill(c, 0, 0, hw, hh)
		if q & 2 != 0 do fill(c, hw, 0, w, hh)
		if q & 4 != 0 do fill(c, 0, hh, hw, h)
		if q & 8 != 0 do fill(c, hw, hh, w, h)
	case:
		return false
	}
	return true
}
