package main

// A terminal's grid is the one its client asked for last (the core alone resizes: term.resize).
// A paired browser's page asks for its own grid when it attaches or its size changes; this window
// asked only when its pane's size changed, so after a page's resize it kept showing the page's
// grid: wider than the pane, the lines of a Codex tab ran off the pane's right edge (and wrapped
// nowhere). The window asks again once the user is at it (term_fits_reclaim, from event()).

import "base:runtime"
import "core:testing"
import "core:time"
import "core"
import cw "corewire"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

@(test)
term_fit_reclaimed_after_another_client_resized :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	core.app_context = context
	font.cell_w, font.cell_h = 10, 20
	tab: u64 = 9101
	v := new(Term_View, runtime.heap_allocator())
	term_view_init(v)
	gh.terminal_new(nil, &v.gt, 40, 5)
	core.gt_setup(v.gt, core.term_colors())
	gh.terminal_resize(v.gt, 40, 5, 10, 20)
	v.cols, v.rows, v.channel = 40, 5, 9101
	term_views[tab] = v
	defer {
		if term_views[tab] == v {
			term_view_free(v)
			free(v, runtime.heap_allocator())
			delete_key(&term_views, tab)
		}
		delete_key(&term_fits, tab)
	}
	// the window laid the tab out: its pane fits 40 x 5
	w, h := 40 * font.cell_w + 2 * term_pad(), 5 * font.cell_h + 2 * term_pad()
	term_fit_rect(tab, 0, 0, w, h)
	testing.expect_value(t, term_fits[tab].cols, u16(40))
	asked := term_fits[tab].resized

	// a browser page asked for 120 x 30: the core's RESIZE on this window's channel
	resize := `{"offset":0,"cols":120,"rows":30,"xpixel":1200,"ypixel":600}`
	term_view_frame(cw.Frame{channel = v.channel, kind = u8(cw.Kind.Resize), payload = transmute([]u8)resize})
	testing.expect_value(t, v.cols, u16(120))

	// nobody at this window: the page keeps its grid however often the window lays out
	time.sleep(time.Millisecond)
	term_fit_rect(tab, 0, 0, w, h)
	testing.expect(t, term_fits[tab].resized == asked, "not asked again while nobody uses this window")

	// the user comes back to the window: its pane's grid is asked for again at the next layout
	e := sapp.Event{type = .FOCUSED}
	event(&e)
	testing.expect_value(t, term_fits[tab].cols, u16(0))
	term_fit_rect(tab, 0, 0, w, h)
	testing.expect(t, term_fits[tab].resized != asked, "asked again")
	testing.expect_value(t, term_fits[tab].cols, u16(40))

	// its own resize coming back (the grid it asked for): nothing to ask again
	again := `{"offset":0,"cols":40,"rows":5,"xpixel":400,"ypixel":100}`
	term_view_frame(cw.Frame{channel = v.channel, kind = u8(cw.Kind.Resize), payload = transmute([]u8)again})
	term_fits_reclaim()
	testing.expect_value(t, term_fits[tab].cols, u16(40))
}
