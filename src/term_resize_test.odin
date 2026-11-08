package main

// The core's terminal size (term.odin, design §10.2 M2-A): the window hands it cols, rows and
// cell pixels (term_resize); the terminal and the program's PTY follow, and a process starts at
// the size the terminal has. term_set_rect (term_view.odin) is the window working them out.

import "core:testing"
import gh "ghostty"

TIOCGWINSZ_TEST :: 0x40087468 // macOS

@(private = "file")
rz_winsize :: proc(t: ^Term) -> Winsize {
	ws: Winsize
	ioctl(t.pty.fd, TIOCGWINSZ_TEST, &ws)
	return ws
}

@(private = "file")
rz_grid :: proc(t: ^Term) -> (cols, rows: u16) {
	gh.terminal_get(t.gt, .Cols, &cols)
	gh.terminal_get(t.gt, .Rows, &rows)
	return
}

@(test)
term_resize_by_cols_and_rows :: proc(t: ^testing.T) {
	app_context = context
	saved := term_cell
	defer term_cell = saved
	term_cell = {9, 18.5} // the window's fonts (fonts_apply)
	term := new(Term)
	defer free(term)
	testing.expect(t, term_init(term, 80, 24))
	defer term_free(term)
	testing.expect_value(t, term.cell, [2]f32{9, 18.5})

	// a process starts at the terminal's size, cell pixels included
	testing.expect(t, term_start(term, {"/bin/sh", "-c", "exec sleep 30"}, "/tmp"))
	ws := rz_winsize(term)
	testing.expect_value(t, ws, Winsize{ws_row = 24, ws_col = 80, ws_xpixel = 720, ws_ypixel = 444})

	// by cols and rows: the grid and the PTY follow
	term.changed = false
	term_resize(term, 100, 30, 10, 20)
	c, r := rz_grid(term)
	testing.expect_value(t, c, 100)
	testing.expect_value(t, r, 30)
	testing.expect_value(t, rz_winsize(term), Winsize{ws_row = 30, ws_col = 100, ws_xpixel = 1000, ws_ypixel = 600})
	testing.expect(t, term.changed)
	testing.expect_value(t, term.cell, [2]f32{10, 20})

	// the same size again: nothing happens
	term.changed = false
	term_resize(term, 100, 30, 10, 20)
	testing.expect(t, !term.changed)

	// new cells, same grid (another font size): the pixel sizes follow
	term_resize(term, 100, 30, 8, 16)
	testing.expect(t, term.changed)
	testing.expect_value(t, rz_winsize(term), Winsize{ws_row = 30, ws_col = 100, ws_xpixel = 800, ws_ypixel = 480})

	// the window's side: a pane rect becomes cols and rows from its font
	saved_w, saved_h, saved_dpi := font.cell_w, font.cell_h, app.dpi
	defer font.cell_w, font.cell_h, app.dpi = saved_w, saved_h, saved_dpi
	font.cell_w, font.cell_h, app.dpi = 10, 20, 1
	term_set_rect(term, 0, 0, 40 * 10 + 2 * TERM_PAD, 12 * 20 + 2 * TERM_PAD)
	c, r = rz_grid(term)
	testing.expect_value(t, c, 40)
	testing.expect_value(t, r, 12)
	testing.expect_value(t, rz_winsize(term), Winsize{ws_row = 12, ws_col = 40, ws_xpixel = 400, ws_ypixel = 240})
	reader_stop_and_close(term)
}
