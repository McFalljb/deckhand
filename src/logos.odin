package main

// Harness logos: the real marks of the agents Deckhand runs (sidebar.odin: HARNESSES), not
// glyphs drawn for them. Sources, colours and usage terms: assets/harness/README.md.
//
// Both marks are pixel art: a grid of cells, each one colour or empty. A logo is rasterised
// once per pixel size into the glyph atlas (font.odin: raster_get, sprite LOGO_SPRITE) with
// every cell a whole number of px, so every edge sits on the pixel grid and the mark is crisp
// at every size: no blur, no anti-aliasing, drawn 1:1 as one textured quad. A logo keeps its
// own colours whatever the row's colour (the caller's alpha still fades it); a dimmed row
// shows the harness's plain glyph instead (sidebar.odin: harness_row_icon).

import "core:math"

Logo :: enum u8 {
	None,
	Pi,
	Claude,
}

Logo_Ink :: struct {
	key:   u8,
	color: Rgba,
}

Logo_Art :: struct {
	rows: []string, // the grid, top row first, all rows as wide; '.' is empty, any other byte an ink's key
	inks: []Logo_Ink,
}

// How much of its square a logo fills (the icon set's strokes span about 13 of 16).
LOGO_FILL :: 0.86
// How wide a wide mark may be, as a share of its square: Clawd (17 x 10 cells) gets whole px
// cells at a row's 14 px only by reaching a little past the square, into the gap beside it
// (GAP_INLINE). Its height stays within LOGO_FILL.
LOGO_WIDE :: 1.25

// pi: pi.dev/logo.svg (the README's logo), three shapes on a 4 x 4 grid, cell for cell
// (SVG = 165.29 + 117.36 * cell, as published).
@(rodata)
LOGO_PI := []string{
	"PPP.",
	"B.P.",
	"BB.G",
	"B..G",
}

// Whether Claude Code's mascot is shown. Anthropic's trademark guidelines ask for approval
// before its marks are used (assets/harness/README.md); build with
// -define:DECKHAND_CLAUDE_LOGO=false and Claude rows show the plain glyph instead.
LOGO_CLAUDE_ON :: #config(DECKHAND_CLAUDE_LOGO, true)

// Claude Code: Clawd, the mascot on its welcome screen, as Claude Code 2.1.318 draws it. In the
// terminal it is three rows of quadrant block characters, each quadrant a cell one wide and
// two tall (a terminal cell is twice as tall as wide):
//      ▐▛███▛█
//     ▝▜██████▀
//      ▝▝   ▝▝
// in its theme's clawd_body colour, rgb(215,119,87), on clawd_background, rgb(0,0,0), which
// shows through as the eyes. Here in square cells, each quadrant row twice; the same grid as
// the pixel-art Clawd (crispEdges SVG, 8 units a cell, fill #d77757) Claude Code also ships.
@(rodata)
LOGO_CLAWD := []string{
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

LOGO_ART := [Logo]Logo_Art {
	.None = {},
	.Pi = {
		rows = LOGO_PI,
		inks = {{'P', {0xF0, 0x90, 0x82, 255}}, {'B', {0x4D, 0x9A, 0xBF, 255}}, {'G', {0xF1, 0xBE, 0x58, 255}}},
	},
	.Claude = {
		rows = LOGO_CLAWD,
		inks = {{'#', {0xD7, 0x77, 0x57, 255}}, {'e', {0x00, 0x00, 0x00, 255}}},
	},
}

// The px per cell for an n px square: the most that keeps the mark within LOGO_FILL of the
// square's height and LOGO_WIDE of its width, at least 1. 0 for no logo.
@(private = "file")
logo_cell :: proc(art: Logo_Art, n: int) -> int {
	if len(art.rows) == 0 || len(art.rows[0]) == 0 || n <= 0 do return 0
	cols, rows := f32(len(art.rows[0])), f32(len(art.rows))
	return max(1, int(math.floor(min(f32(n) * LOGO_WIDE / cols, f32(n) * LOGO_FILL / rows))))
}

// The side of the square sprite a logo drawn for an n px square needs: n, or more for a mark
// wider than its square, by an even number of px so the two share a centre. 0 for no logo.
logo_side :: proc(logo: Logo, n: int) -> int {
	art := LOGO_ART[logo]
	cell := logo_cell(art, n)
	if cell == 0 do return 0
	w := max(len(art.rows[0]), len(art.rows)) * cell
	return w <= n ? n : n + 2 * ((w - n + 1) / 2)
}

// Where the mark goes in its sprite (logo_side(logo, n) px square): its top-left cell's px
// and the px per cell. Centred, within half a px.
logo_transform :: proc(logo: Logo, n: int) -> (origin: [2]int, cell: int) {
	art := LOGO_ART[logo]
	cell = logo_cell(art, n)
	if cell == 0 do return
	side := logo_side(logo, n)
	origin = {(side - len(art.rows[0]) * cell) / 2, (side - len(art.rows) * cell) / 2}
	return
}

// Rasterises `logo` drawn for an n px square into dst, its sprite: logo_side(logo, n) px
// square, RGBA (straight alpha, rows of side * 4 bytes). Empty cells are left as they are.
// False for no logo or a buffer too small.
logo_render :: proc(logo: Logo, n: int, dst: []u8) -> bool {
	art := LOGO_ART[logo]
	side := logo_side(logo, n)
	if side == 0 || len(dst) < side * side * 4 do return false
	origin, cell := logo_transform(logo, n)
	for row, cy in art.rows do for key, cx in transmute([]u8)row {
		if key == '.' do continue
		color: Rgba
		for ink in art.inks do if ink.key == key do color = ink.color
		if color[3] == 0 do continue
		for y in 0 ..< cell do for x in 0 ..< cell {
			px := origin + {cx * cell + x, cy * cell + y}
			p := dst[(px.y * side + px.x) * 4:][:4]
			p[0], p[1], p[2], p[3] = color[0], color[1], color[2], color[3]
		}
	}
	return true
}
