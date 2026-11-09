package main

// The window's copies of its core's terminals (docs/plans/background-core.md §5.5, M3-H): each
// terminal tab the window shows has a Term_View with its own ghostty terminal, fed by the core's
// stream (src/core/term_stream.odin has the messages): a snapshot at attach, then the same bytes
// the core's terminal parses, with resizes at their byte offsets. The window draws, selects,
// finds links and encodes keys and the mouse on its copy; what the user types goes back as the
// stream's DATA, and the core writes it to the program. The copy never answers queries: it has
// no write_pty (or any other) callback, only what core.gt_setup gives every terminal.
//
// A view attaches when its tab is shown and detaches 2 s after it stops showing (HIDDEN_DETACH):
// a hidden tab costs the window nothing, and shows again from a snapshot. The grid's size is the
// core's to set: the window asks for what its pane fits (term_fit_rect) and its copy follows when
// the RESIZE comes back.

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:time"
import "core"
import cw "corewire"
import gh "ghostty"
import jg "jsonguard"

HIDDEN_DETACH :: 2 * time.Second // a tab off screen this long gives up its copy
SNAP_FAIL_GAP :: time.Second // a tab whose snapshot did not decode attaches again at most this often
HISTORY_BUDGET :: 2 * time.Millisecond // history pages decoded per frame after a snapshot shows

Term_View :: struct {
	tab_id:       u64,
	gt:           gh.Terminal, // the window's copy (nil until its snapshot came)
	cols, rows:   u16, // its grid (the core's, as the stream last sized it)
	channel:      u32, // its stream (0: not attached yet)
	offset:       u64, // the stream offset its copy has parsed up to
	changed:      bool, // something visible changed since it was drawn
	shown:        time.Tick, // last on screen (term_views_tick)
	cont_fed:     int, // bytes parsed since its continuation buffer was trimmed (core.term_continuation_trim)
	// a snapshot's history still being decoded, newest page first (the screen shows at READY)
	dec:          gh.Snapshot_Decoder,
	dec_blob:     []u8, // the snapshot the decoder reads (heap)
	snapshots:    int, // snapshots taken (tests)
	stale:        bool, // a RESIZE at another offset than ours: it attaches again (term_views_tick)
	snap_failed:  time.Tick, // its snapshot did not decode then: attached again SNAP_FAIL_GAP later, not at once
	// drawing and input
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
	// the link under the pointer while ⌘ is held (term_links.odin)
	link:         core.Term_Link, // url owned
	link_on:      bool,
	link_at:      [2]f32, // the pointer when it was looked up
	link_key:     core.Link_Key, // what that lookup depended on
	link_scanned: bool, // link_key is current
	link_scans:   int, // lookups made (tests)
}

// What the window asked the core to size a tab's terminal to (term_fit_rect), by tab: asked
// again only when it changes, and at most every RESIZE_THROTTLE while a divider drags.
Term_Fit :: struct {
	cols, rows: u16,
	cell:       [2]f32,
	resized:    time.Tick,
	rect:       [4]f32, // the pane rect it was given last: a view attached later starts there
}

term_views: map[u64]^Term_View
term_fits: map[u64]Term_Fit
// tests: where a view's input goes instead of its stream (no core attached)
term_view_input_hook: proc(v: ^Term_View, bytes: []u8)
// tests: the window takes DATA but never sends CREDIT (a window that has stopped reading)
term_view_credit_off: bool
@(private = "file")
theme_applied: ^core.Term_Colors // the look the copies' default colours are from

// ---- finding views ----

// The view of a tab the window shows: attached now if it was not (a snapshot). nil: no terminal.
term_view_of :: proc(tab_id: u64) -> ^Term_View {
	if tab_id == 0 do return nil
	if v := term_views[tab_id]; v != nil {
		v.shown = time.tick_now()
		return v
	}
	if !client.attached || core.term_of(tab_id) == nil do return nil // M4: the replica's tab kinds
	return term_view_attach(tab_id)
}

// The view of a tab if it has one (no attach).
term_view_peek :: proc(tab_id: u64) -> ^Term_View {return term_views[tab_id] or_else nil}

active_view :: proc() -> ^Term_View {
	if tab := core.active_tab(); tab != nil do return term_view_of(tab.id)
	return nil
}
key_view :: proc() -> ^Term_View {
	if tab := core.key_tab(); tab != nil do return term_view_of(tab.id)
	return nil
}
// Atlas's, in the drawer: attached only while the drawer is open (it still draws while it slides
// shut, from the view it had).
agent_view :: proc() -> ^Term_View {
	tab := core.home_tab()
	if tab == nil do return nil
	return state.home_open ? term_view_of(tab.id) : term_view_peek(tab.id)
}
pane_view :: proc(p: ^core.Pane) -> ^Term_View {
	if tab := core.pane_shown(p); tab != nil do return term_view_of(tab.id)
	return nil
}
// The setup sheet's install run's (ui_harness.odin): attached while the sheet is open.
harness_view :: proc() -> ^Term_View {
	id := core.harness_run.term_id
	return setup_open() ? term_view_of(id) : term_view_peek(id)
}

// The views of the terminals on screen in the current session's panes (temp allocator).
views_on_screen :: proc() -> []^Term_View {
	out := make([dynamic]^Term_View, context.temp_allocator)
	cs := core.cur()
	if cs == nil do return out[:]
	for tab in cs.tabs do if core.session_tab_shown(cs, tab.id) {
		if v := term_view_peek(tab.id); v != nil do append(&out, v)
	}
	return out[:]
}

// ---- the grid's size ----

// The grid a pane rect fits (capped at what a snapshot carries, snapshot.odin, so ours always decode).
term_grid_fit :: proc(w, h: f32) -> (cols, rows: u16) {
	cols = u16(clamp(int((w - 2 * term_pad()) / font.cell_w), 2, core.MAX_TERM_COLS))
	rows = u16(clamp(int((h - 2 * term_pad()) / font.cell_h), 2, core.MAX_TERM_ROWS))
	return
}

// Tab tab_id's terminal goes in this pane rect (shown or not, so a tab switch never reflows): its
// view takes the rect, and the core is asked for the grid it fits (the core resizes the terminal
// and the program's PTY, and the view's copy follows at the RESIZE's offset).
term_fit_rect :: proc(tab_id: u64, x, y, w, h: f32) {
	if v := term_view_peek(tab_id); v != nil do v.x, v.y, v.w, v.h = x, y, w, h
	cols, rows := term_grid_fit(w, h)
	f, had := &term_fits[tab_id]
	if had do f.rect = {x, y, w, h}
	if had && f.cols == cols && f.rows == rows && f.cell == {font.cell_w, font.cell_h} do return
	// a column divider is being dragged: the grid (and the child's PTY)
	// follows at most every RESIZE_THROTTLE; the release resizes it exactly
	if (divider.active || pane_dragging()) && had && time.tick_since(f.resized) < RESIZE_THROTTLE do return
	term_fits[tab_id] = {cols = cols, rows = rows, cell = {font.cell_w, font.cell_h}, resized = time.tick_now(), rect = {x, y, w, h}}
	if !client.attached {
		if t := core.term_of(tab_id); t != nil do core.term_resize(t, cols, rows, font.cell_w, font.cell_h)
		return
	}
	client_frame(cw.JSON_CHANNEL, .Data, transmute([]u8)fmt.tprintf(`{{"v":%d,"type":"term.resize","tab_id":%d,"cols":%d,"rows":%d,"cell_w":%v,"cell_h":%v}}`, core.PROTOCOL_VERSION, tab_id, cols, rows, font.cell_w, font.cell_h))
	core.window_link_pump()
}

// A new cell size (fonts_apply): every terminal is asked for its grid again at the next layout.
term_fits_forget :: proc() {for _, &f in term_fits do f.cols = 0}

// ---- each frame ----

// Frame upkeep (main.odin, before the draw): views off screen for HIDDEN_DETACH detach; a
// snapshot's history decodes a little; a new look's colours reach every copy.
term_views_tick :: proc() {
	now := time.tick_now()
	home := core.home_tab()
	gone := make([dynamic]^Term_View, context.temp_allocator)
	for id, v in term_views {
		on := core.tab_on_screen(id) || (home != nil && id == home.id && state.home_open) || (id == core.harness_run.term_id && setup_open())
		if on do v.shown = now
		// a snapshot that does not decode: attached again once a second, never every frame (the
		// core encodes each one anew)
		if v.stale && v.snap_failed != {} && time.tick_diff(v.snap_failed, now) < SNAP_FAIL_GAP do continue
		if v.stale || time.tick_diff(v.shown, now) > HIDDEN_DETACH do append(&gone, v)
	}
	for v in gone {
		stale, id := v.stale, v.tab_id
		term_view_detach(v)
		if stale do term_view_of(id) // a fresh snapshot now
	}
	term_views_theme()
	budget := time.tick_now()
	for _, v in term_views do if v.dec != nil {
		for v.dec != nil && time.tick_since(budget) < HISTORY_BUDGET do view_history_step(v)
	}
}

// Every copy's default colours from the look (the core sets its own when the look changes:
// they are not in the byte stream).
term_views_theme :: proc() {
	tc := core.term_colors()
	if tc == theme_applied do return
	theme_applied = tc
	for _, v in term_views do if v.gt != nil {
		core.gt_apply_theme(v.gt, tc)
		v.changed = true
	}
}

// Test mode (autotest.odin, after each script step): "" while each shown copy's screen hash
// equals the core's terminal's; else which differ. Both sides first take what waits (the core's
// stream, the copy's history).
term_views_check :: proc() -> (out: string, compared: int) {
	if !client.attached do return
	core.term_streams_flush(retry_now = true)
	term_views_theme()
	for id, v in term_views {
		t := core.term_of(id)
		if t == nil do continue
		compared += 1
		if v.gt == nil {
			// attached, but no snapshot it could use: not equal, and said so
			out = fmt.tprintf("%s%stab %d: the window's copy has no snapshot", out, out == "" ? "" : "; ", id)
			continue
		}
		term_view_history_finish(v)
		if v.offset != t.offset {
			out = fmt.tprintf("%s%stab %d: the window's copy is at offset %d, the core's at %d", out, out == "" ? "" : "; ", id, v.offset, t.offset)
			continue
		}
		a, _ := core.screen_hash(t.gt, VIEW_CHECK_ROWS)
		b, _ := core.screen_hash(v.gt, VIEW_CHECK_ROWS)
		if a != b do out = fmt.tprintf("%s%stab %d: screen hash core %x, window %x (offset %d)", out, out == "" ? "" : "; ", id, a, b, v.offset)
	}
	return
}

// The rows the per-step check hashes, from the end (screen and recent history): a 20 MiB
// scrollback would take seconds per step. Snapshot tests hash all of it.
VIEW_CHECK_ROWS :: 2000

// ---- attach, detach ----

@(private = "file")
term_view_attach :: proc(tab_id: u64) -> ^Term_View {
	heap := runtime.heap_allocator()
	v := new(Term_View, heap)
	v.tab_id = tab_id
	v.shown = time.tick_now()
	if f, ok := term_fits[tab_id]; ok do v.x, v.y, v.w, v.h = f.rect[0], f.rect[1], f.rect[2], f.rect[3] // laid out already this frame
	term_view_init(v)
	term_views[tab_id] = v
	client_frame(cw.JSON_CHANNEL, .Data, transmute([]u8)fmt.tprintf(`{{"v":%d,"type":"term.attach","id":"t%d","tab_id":%d,"history_lines":0}}`, core.PROTOCOL_VERSION, tab_id, tab_id))
	core.window_link_pump() // term.attached, then the snapshot, arrive at once (term_view_frame)
	if term_views[tab_id] != v do return nil // refused (term_view_json freed it)
	return v
}

// Stops streaming v's terminal and frees v.
term_view_detach :: proc(v: ^Term_View) {
	if v.channel != 0 && client.attached {
		client_frame(cw.JSON_CHANNEL, .Data, transmute([]u8)fmt.tprintf(`{{"v":%d,"type":"term.detach","channel":%d}}`, core.PROTOCOL_VERSION, v.channel))
		core.window_link_pump()
	}
	term_view_drop(v)
}

@(private = "file")
term_view_drop :: proc(v: ^Term_View) {
	if term_views[v.tab_id] == v do delete_key(&term_views, v.tab_id)
	term_view_free(v)
	free(v, runtime.heap_allocator())
}

// The window's link went (tests): every view goes.
term_views_drop_all :: proc() {
	for _, v in term_views {
		term_view_free(v)
		free(v, runtime.heap_allocator())
	}
	clear(&term_views)
}

@(private = "file")
view_of_channel :: proc(channel: u32) -> ^Term_View {
	for _, v in term_views do if v.channel == channel do return v
	return nil
}

// ---- from the core (client.odin's client_on_frames) ----

// term.attached, term.scroll.
term_view_json :: proc(text: string) {
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if err != nil do return
	obj, ok := v.(json.Object)
	if !ok do return
	switch obj["type"].(json.String) or_else "" {
	case "term.attached":
		tab_id := u64(obj["tab_id"].(json.Integer) or_else 0)
		tv := term_view_peek(tab_id)
		if tv == nil || tv.channel != 0 do return
		if e, has := obj["error"].(json.String); has {
			fmt.eprintln("Deckhand: the core has no terminal for tab", tab_id, "(", e, ")")
			term_view_drop(tv)
			return
		}
		tv.channel = u32(obj["channel"].(json.Integer) or_else 0)
	case "term.scroll":
		if tv := view_of_channel(u32(obj["channel"].(json.Integer) or_else 0)); tv != nil && tv.gt != nil {
			view_scroll_bottom(tv)
		}
	}
}

// A frame on a terminal channel.
term_view_frame :: proc(f: cw.Frame) {
	v := view_of_channel(f.channel)
	if v == nil do return // detached: what was still on its way
	switch cw.Kind(f.kind) {
	case .Snapshot:
		view_snapshot(v, f.payload)
	case .Data:
		if v.gt != nil && !v.stale {
			gh.terminal_vt_write(v.gt, raw_data(f.payload), len(f.payload))
			v.offset += u64(len(f.payload))
			v.cont_fed += len(f.payload)
			if v.cont_fed >= core.CONT_TRIM_EVERY && core.term_continuation_trim(v.gt) do v.cont_fed = 0
			v.changed = true
		}
		if !term_view_credit_off {
			credit: [4]u8
			endian.put_u32(credit[:], .Little, u32(len(f.payload)))
			client_frame(v.channel, .Credit, credit[:])
		}
	case .Resize:
		if !v.stale do view_resize(v, f.payload)
	case .Close: // its terminal went
		term_view_drop(v)
	case .Credit, .Focus: // the window's to send
	}
}

@(private = "file")
view_snapshot :: proc(v: ^Term_View, blob: []u8) {
	meta, body, err := core.snapshot_unpack(blob)
	if err != .None {
		fmt.eprintln("Deckhand: a terminal snapshot the window cannot read:", err)
		view_snap_failed(v) // what follows is relative to it: attach again (term_views_tick)
		return
	}
	gt: gh.Terminal
	dec: gh.Snapshot_Decoder
	heap := runtime.heap_allocator()
	kept: []u8
	switch meta.format {
	case core.SNAPSHOT_GHOSTSNP:
		ok, grid := core.snapshot_ghostsnp_grid(body)
		if !ok || i64(grid[0]) != meta.cols || i64(grid[1]) != meta.rows {
			fmt.eprintln("Deckhand: a terminal snapshot whose size does not match its header")
			view_snap_failed(v)
			return
		}
		// the decoder reads the snapshot as it goes: kept until its history is in
		kept = make([]u8, len(body), heap)
		copy(kept, body)
		if gh.snapshot_decoder_new_buf(nil, &dec, raw_data(kept), c.size_t(len(kept))) != .Success {
			delete(kept, heap)
			view_snap_failed(v)
			return
		}
		limit := core.TERM_CONTINUATION_MAX
		retain, compress := true, true
		gh.snapshot_decoder_set(dec, .Max_Continuation_Bytes, &limit)
		gh.snapshot_decoder_set(dec, .Retain_Continuation, &retain)
		gh.snapshot_decoder_set(dec, .Compress_History, &compress)
		if gh.snapshot_decoder_ready(dec, &gt) != .Success { // the screen, the modes, the unfinished escape: drawable now
			gh.snapshot_decoder_free(dec)
			delete(kept, heap)
			fmt.eprintln("Deckhand: a terminal snapshot that does not decode")
			view_snap_failed(v)
			return
		}
	case:
		e: core.Snapshot_Error
		gt, _, e = core.snapshot_decode(blob)
		if e != .None {
			fmt.eprintln("Deckhand: a terminal snapshot that does not decode:", e)
			view_snap_failed(v)
			return
		}
	}
	view_replace_gt(v, gt)
	v.dec, v.dec_blob = dec, kept
	v.offset = meta.offset
	v.snapshots += 1
	core.gt_setup(v.gt, core.term_colors()) // the one helper the core's terminals use too (term.odin)
	gh.terminal_get(v.gt, .Cols, &v.cols)
	gh.terminal_get(v.gt, .Rows, &v.rows)
	// the core sized it otherwise meanwhile (a holder adopt): the next layout asks again
	if f, ok := &term_fits[v.tab_id]; ok && (f.cols != v.cols || f.rows != v.rows) do f.cols = 0
	v.changed = true
}

// One history page (or image) of v's snapshot; the decoder goes at FINISH or on an error.
@(private = "file")
view_history_step :: proc(v: ^Term_View) {
	if v.dec == nil do return
	if r := gh.snapshot_decoder_next(v.dec); r == .Success {
		v.changed = true
		return
	} else if r != .No_Value {
		fmt.eprintln("Deckhand: a terminal snapshot's history did not decode:", r)
	}
	view_history_end(v)
}

// All of a snapshot's history now (the per-step check, tests).
term_view_history_finish :: proc(v: ^Term_View) {
	for v.dec != nil do view_history_step(v)
}

@(private = "file")
view_history_end :: proc(v: ^Term_View) {
	if v.dec != nil do gh.snapshot_decoder_free(v.dec)
	v.dec = nil
	if v.dec_blob != nil do delete(v.dec_blob, runtime.heap_allocator())
	v.dec_blob = nil
}

// v's snapshot did not decode: stale (nothing more applies to it), attached again SNAP_FAIL_GAP on.
@(private = "file")
view_snap_failed :: proc(v: ^Term_View) {
	v.stale = true
	v.snap_failed = time.tick_now()
}

// v's copy becomes gt (a snapshot's): what belonged to the old one goes first.
@(private = "file")
view_replace_gt :: proc(v: ^Term_View, gt: gh.Terminal) {
	term_cancel_drag(v) // its tracked ends belong to the old terminal
	term_link_clear(v)
	view_history_end(v)
	if v.gt != nil do gh.terminal_free(v.gt)
	v.gt = gt
	v.cont_fed = 0
}

@(private = "file")
view_resize :: proc(v: ^Term_View, payload: []u8) {
	if v.gt == nil do return
	r: struct {
		offset:         u64,
		cols, rows:     u16,
		xpixel, ypixel: u32,
	}
	if jg.unmarshal(payload, &r, .JSON, context.temp_allocator) != nil || r.cols < 2 || r.rows < 2 do return
	if r.offset != v.offset {
		// never at another byte than the core's: the copy would wrap differently from then on
		fmt.eprintfln("Deckhand: a terminal resize at offset %d, the window's copy is at %d: attached again", r.offset, v.offset)
		v.stale = true // never pumped from in here: term_views_tick attaches it again
		return
	}
	// history pages still to come could not be applied after a reflow (the decoder drops them):
	// the rest of the snapshot first
	term_view_history_finish(v)
	gh.terminal_resize(v.gt, r.cols, r.rows, r.xpixel / u32(r.cols), r.ypixel / u32(r.rows))
	v.cols, v.rows = r.cols, r.rows
	v.changed = true
}

// ---- to the core ----

// Input for the program (the encoders' bytes, typed text, a paste): the stream's DATA.
term_view_input :: proc(v: ^Term_View, bytes: []u8) {
	if len(bytes) == 0 do return
	if term_view_input_hook != nil {
		term_view_input_hook(v, bytes)
		return
	}
	if v.channel == 0 || !client.attached do return
	client_frame(v.channel, .Data, bytes)
	core.window_link_pump() // written to the PTY now, as the window's own pty_write did
}

// The terminal gained or lost the keyboard: the core reports it to the program if it asked (1004).
term_view_focus_send :: proc(v: ^Term_View, focused: bool) {
	if v.channel == 0 || !client.attached do return
	b := [1]u8{focused ? 1 : 0}
	client_frame(v.channel, .Focus, b[:])
	core.window_link_pump()
}

// The user's selection in tab tab_id's copy (core.window_term_selection: Copy_Selection).
term_view_selection :: proc(tab_id: u64) -> string {
	v := term_view_peek(tab_id)
	return v != nil && v.gt != nil ? core.gt_selection_text(v.gt) : ""
}

view_scroll_bottom :: proc(v: ^Term_View) {
	if v.gt == nil do return
	sv := gh.Scroll_Viewport{tag = .Bottom}
	gh.terminal_scroll_viewport(v.gt, sv)
	v.changed = true
}

view_mode_on :: proc(v: ^Term_View, n: u16) -> bool {
	if v.gt == nil do return false
	mc := gh.Mode_Config{mode = gh.mode_dec(n)}
	gh.terminal_get(v.gt, .Mode, &mc)
	return mc.value
}
