package main

// Harness logos (logos.odin) and the harness table (sidebar.odin: HARNESSES): every harness
// resolves to an icon, a logo when it has one and its glyph otherwise, and the logos rasterise
// in their own colours. No GPU: logo_render writes into a plain buffer.

import "core:testing"

@(test)
harness_table_maps_every_harness :: proc(t: ^testing.T) {
	seen: map[Icon]Harness
	defer delete(seen)
	for m, h in HARNESSES {
		testing.expectf(t, m.name != "", "%v has a name", h)
		testing.expectf(t, m.glyph != .None, "%v has a fallback glyph", h)
		testing.expectf(t, icon_logo(m.glyph) == .None, "%v's glyph is a plain glyph", h)
		ic := harness_icon(h)
		testing.expectf(t, ic != .None, "%v has an icon", h)
		if m.logo != .None {
			testing.expect_value(t, ic, m.logo)
			logo := icon_logo(m.logo)
			testing.expectf(t, logo != .None, "%v's logo is a logo icon", h)
			testing.expectf(t, len(LOGO_ART[logo].rows) > 0, "%v's logo has art", h)
		}
		if other, dup := seen[ic]; dup do testing.expectf(t, false, "%v and %v share an icon", h, other)
		seen[ic] = h
	}
	// the two shipped today have their real logos (Claude's unless built without it)
	testing.expect_value(t, harness_icon(.Pi), Icon.Logo_Pi)
	testing.expect_value(t, harness_icon(.Claude), LOGO_CLAUDE_ON ? Icon.Logo_Claude : Icon.Harness_Claude)
	testing.expect_value(t, icon_logo(.Logo_Pi), Logo.Pi)
	testing.expect_value(t, icon_logo(.Logo_Claude), Logo.Claude)
}

@(test)
harness_without_logo_falls_back_to_its_glyph :: proc(t: ^testing.T) {
	testing.expect_value(t, harness_mark_icon({name = "new", glyph = .Harness_Pi}), Icon.Harness_Pi)
	testing.expect_value(t, harness_mark_icon({name = "new", logo = .Logo_Claude, glyph = .Harness_Claude}), Icon.Logo_Claude)
	for ic in Icon do if ic != .Logo_Pi && ic != .Logo_Claude do testing.expectf(t, icon_logo(ic) == .None, "%v is no logo", ic)
}

@(private = "file")
px_at :: proc(buf: []u8, n, x, y: int) -> Rgba {
	p := buf[(y * n + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(test)
logo_pi_is_crisp_cells_in_its_colours :: proc(t: ^testing.T) {
	// 1x sidebar (14), 2x sidebar (28), 1x and 2x picker (16, 32)
	for n in ([]int{14, 16, 28, 32}) {
		side := logo_side(.Pi, n)
		testing.expect_value(t, side, n) // a square mark stays inside its square
		buf := make([]u8, side * side * 4)
		defer delete(buf)
		testing.expect(t, logo_render(.Pi, n, buf))
		origin, cell := logo_transform(.Pi, n)
		testing.expectf(t, cell >= 3, "n=%d: whole px cells (%d)", n, cell)
		// every pixel fully on or off: the grid's edges sit on whole pixels
		for i in 0 ..< side * side do if a := buf[i * 4 + 3]; a != 0 && a != 255 {
			testing.expectf(t, false, "n=%d: px %d has alpha %d", n, i, a)
			break
		}
		at :: proc(buf: []u8, n: int, origin: [2]int, cell, cx, cy: int) -> Rgba {
			return px_at(buf, n, origin.x + cx * cell + cell / 2, origin.y + cy * cell + cell / 2)
		}
		testing.expect_value(t, at(buf, side, origin, cell, 0, 0), Rgba{0xF0, 0x90, 0x82, 255}) // pink, top left
		testing.expect_value(t, at(buf, side, origin, cell, 2, 1), Rgba{0xF0, 0x90, 0x82, 255})
		testing.expect_value(t, at(buf, side, origin, cell, 0, 3), Rgba{0x4D, 0x9A, 0xBF, 255}) // blue, the left leg
		testing.expect_value(t, at(buf, side, origin, cell, 1, 2), Rgba{0x4D, 0x9A, 0xBF, 255})
		testing.expect_value(t, at(buf, side, origin, cell, 3, 3), Rgba{0xF1, 0xBE, 0x58, 255}) // gold, bottom right
		testing.expect_value(t, at(buf, side, origin, cell, 3, 0)[3], 0) // empty cells
		testing.expect_value(t, at(buf, side, origin, cell, 1, 1)[3], 0)
		testing.expect_value(t, at(buf, side, origin, cell, 2, 3)[3], 0)
		// centred: equal margins (within a px)
		testing.expectf(t, abs(origin.x * 2 + 4 * cell - n) <= 1, "n=%d centred", n)
	}
}

// Clawd, Claude Code's mascot, exactly as Claude Code draws it (logos.odin: LOGO_CLAWD has the
// sources): 17 x 10 square cells, '#' its body, 'e' an eye. Written out here on its own so the
// test checks the art rather than repeating it.
@(private = "file")
CLAWD_EXPECTED := [?]string {
	"..#############..",
	"..#############..",
	"..##e#######e##..",
	"..##e#######e##..",
	"#################",
	"#################",
	"..#############..",
	"..#############..",
	"..#.#.......#.#..",
	"..#.#.......#.#..",
}

@(test)
logo_claude_is_clawd_in_crisp_cells :: proc(t: ^testing.T) {
	body := Rgba{0xD7, 0x77, 0x57, 255} // Claude Code's clawd_body, rgb(215,119,87)
	eye := Rgba{0, 0, 0, 255} // its clawd_background, rgb(0,0,0)
	// 1x and 2x row (14, 28), 1x and 2x picker (16, 32): one px per cell at 1x, two at 2x
	for c in ([][2]int{{14, 1}, {16, 1}, {28, 2}, {32, 2}}) {
		n, want_cell := c[0], c[1]
		side := logo_side(.Claude, n)
		buf := make([]u8, side * side * 4)
		defer delete(buf)
		testing.expect(t, logo_render(.Claude, n, buf))
		origin, cell := logo_transform(.Claude, n)
		testing.expect_value(t, cell, want_cell)
		w, h := 17 * cell, 10 * cell
		// the sprite holds the whole mark, centred on the n px square it is drawn for: the
		// sprite and the square share a centre (an even difference), the mark within a px of it
		testing.expectf(t, side >= max(n, w) && (side - n) % 2 == 0, "n=%d: sprite %d for a %d px mark", n, side, w)
		testing.expectf(t, abs(origin.x * 2 + w - side) <= 1 && abs(origin.y * 2 + h - side) <= 1, "n=%d: centred (%v)", n, origin)
		// no wider than LOGO_WIDE of its square, no taller than LOGO_FILL
		testing.expectf(t, f32(w) <= f32(n) * LOGO_WIDE && f32(h) <= f32(n) * LOGO_FILL, "n=%d: %d x %d px", n, w, h)
		bad := 0
		for y in 0 ..< side do for x in 0 ..< side {
			got := px_at(buf, side, x, y)
			cx, cy := x - origin.x, y - origin.y
			want := Rgba{}
			if cx >= 0 && cy >= 0 && cx < w && cy < h {
				switch CLAWD_EXPECTED[cy / cell][cx / cell] {
				case '#': want = body
				case 'e': want = eye
				}
			}
			if got[3] == 0 && want[3] == 0 do continue
			if got != want {
				if bad == 0 do testing.expectf(t, false, "n=%d: px (%d, %d) is %v, want %v", n, x, y, got, want)
				bad += 1
			}
		}
		testing.expectf(t, bad == 0, "n=%d: %d px differ from Clawd", n, bad)
	}
}

@(test)
logo_render_refuses_nothing_to_draw :: proc(t: ^testing.T) {
	buf: [16 * 16 * 4]u8
	testing.expect(t, !logo_render(.None, 16, buf[:]))
	testing.expect(t, !logo_render(.Pi, 0, buf[:]))
	testing.expect(t, !logo_render(.Pi, 32, buf[:])) // buffer too small
	testing.expect(t, !logo_render(.Claude, 16, buf[:])) // its sprite is wider than 16 px
}

// A dimmed row (hidden, or its folder gone) shows the plain glyph in the muted colour, not the
// logo: a logo keeps its colours, so it would stand out next to the dimmed text, and fading a
// brand mark would alter it.
@(test)
harness_row_icon_dims_to_the_glyph :: proc(t: ^testing.T) {
	for m, h in HARNESSES {
		testing.expect_value(t, harness_row_icon(h, false), harness_icon(h))
		testing.expect_value(t, harness_row_icon(h, true), m.glyph)
		testing.expectf(t, icon_logo(harness_row_icon(h, true)) == .None, "%v dimmed is no logo", h)
	}
}
