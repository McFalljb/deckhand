package core

// From src/term_view.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

import "core:time"
import gh "../ghostty"

Term_View :: struct {
	rs:           gh.Render_State,
	it:           gh.Row_Iterator,
	cells:        gh.Row_Cells,
	kenc:         gh.Key_Encoder,
	kev:          gh.Key_Event,
	menc:         gh.Mouse_Encoder,
	mev:          gh.Mouse_Event,
	x, y, w, h:   f32, // pane rect in framebuffer px
	// input state
	pending_key:  gh.Key, // KEY_DOWN deferred to the CHAR event that follows
	pending_mods: gh.Mods,
	pending_cp:   rune,
	char_handled: bool, // KEY_DOWN already sent the key: drop its CHAR events
	surrogate:    u32,
	selecting:    bool,
	// a drag's anchor and what its press selected (word or line: lo, hi),
	// tracked by libghostty so they stay on their text through scrolling
	// and scrollback trims; only while a drag is on
	sel_refs:     [3]gh.Tracked_Grid_Ref,
	sel_unit:     int, // 1 cells, 2 words, 3 lines (click count of the press)
	drag_at:      [2]f32, // the pointer during a selection drag (auto-scroll)
	drag_scrolled: time.Tick, // last auto-scroll step
	cursor_px:    [2]f32, // cursor cell's top-left as last drawn (input method anchor)
	mouse_down:   bool,
	mouse_button: gh.Mouse_Button, // the press reported to the app (its drags carry it)
	mouse_cell:   [2]i32,
	scroll_acc:   f32,
	focused:      bool,
	drawn_selected: int, // selected cells in the last drawn frame (test mode reads it)
	resized:      time.Tick, // last grid resize (throttled while a divider is dragged)
	// the link under the pointer while ⌘ is held (term_links.odin)
	link:         Term_Link, // url owned
	link_on:      bool,
	link_at:      [2]f32, // the pointer when it was looked up
	link_key:     Link_Key, // what that lookup depended on
	link_scanned: bool, // link_key is current
	link_scans:   int, // lookups made (tests)
}
