package main

// Terminal streams (design §5.5, M3-H): the window's copy of a core terminal, fed by the core's
// stream over the in-memory link, against the core's own terminal, compared by screen hash (never
// by snapshot bytes). The core's terminals here run no process: their "program output" is written
// with core.term_vt_write, as term_pump does.

import "base:runtime"
import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core"
import cw "corewire"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
TS_TAB :: u64(77001)

// The window's link without the rest of the client (no state stream): terminal frames and
// term.* messages go where client_on_frames sends them.
@(private = "file")
ts_on_frames :: proc() {
	for {
		f, err := cw.mem_recv(client.end, context.temp_allocator)
		if err != .None do return
		if f.channel != cw.JSON_CHANNEL {
			term_view_frame(f)
			continue
		}
		text := string(f.payload)
		if strings.contains(text, `"type":"term.`) do term_view_json(text)
	}
}

@(private = "file")
ts_begin :: proc(cols: u16 = 80, rows: u16 = 24) -> ^core.Term {
	core.app_context = context
	font.cell_w, font.cell_h = 8, 16
	tl_host_off() // the unit tests' tab host link (tabhost_link_test.odin): one window per core
	ok: bool
	client.end, ok = core.core_attach_window(ts_on_frames)
	assert(ok, "attach")
	client.attached = true
	tm := new(core.Term, runtime.heap_allocator())
	core.term_init(tm, cols, rows)
	tm.cell = {8, 16}
	core.terms[TS_TAB] = tm
	return tm
}

@(private = "file")
ts_end :: proc(tm: ^core.Term) {
	term_views_drop_all()
	core.core_detach_window()
	client.attached = false
	client.end = {}
	tl_host_on()
	term_view_credit_off = false
	delete_key(&core.terms, TS_TAB)
	core.term_free(tm)
	free(tm, runtime.heap_allocator())
}

@(private = "file")
ts_write :: proc(tm: ^core.Term, s: string) {core.term_vt_write(tm, transmute([]u8)s)}

// The core's terminal and the window's copy: the same offset and the same screen (all of the
// scrollback), after the stream sent what waits.
@(private = "file")
ts_same :: proc(t: ^testing.T, tm: ^core.Term, what: string, loc := #caller_location) -> bool {
	core.term_streams_flush()
	v := term_view_peek(TS_TAB)
	if v == nil || v.gt == nil {
		testing.expectf(t, false, "%s: no window copy", what, loc = loc)
		return false
	}
	term_view_history_finish(v)
	if v.offset != tm.offset {
		testing.expectf(t, false, "%s: window at offset %d, core at %d", what, v.offset, tm.offset, loc = loc)
		return false
	}
	a, _ := core.screen_hash(tm.gt)
	b, _ := core.screen_hash(v.gt)
	if a != b {
		da := strings.builder_make(context.temp_allocator)
		db := strings.builder_make(context.temp_allocator)
		core.screen_dump(tm.gt, &da)
		core.screen_dump(v.gt, &db)
		la, lb := strings.split_lines(strings.to_string(da), context.temp_allocator), strings.split_lines(strings.to_string(db), context.temp_allocator)
		for i in 0 ..< max(len(la), len(lb)) {
			x := i < len(la) ? la[i] : "<none>"
			y := i < len(lb) ? lb[i] : "<none>"
			if x != y {
				testing.expectf(t, false, "%s: line %d differs\n  core:   %.200s\n  window: %.200s", what, i, x, y, loc = loc)
				break
			}
		}
		return false
	}
	return true
}

// Every corpus case streamed in random chunks, with resizes at random offsets (the core's
// term_resize), attaches and detaches at random points, the stream flushed at random points:
// the window's copy equals the core's terminal at the end and at every check.
@(test)
stream_determinism :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	for cs, ci in snap_corpus() {
		for seed in 0 ..< u64(4) {
			tm := ts_begin(cs.cols, cs.rows)
			st := rand.create(seed * 7919 + u64(ci))
			gen := rand.default_random_generator(&st)
			attached := term_view_of(TS_TAB) != nil
			testing.expect(t, attached, "attach")
			checks := 0
			for ev in cs.events {
				switch e in ev {
				case Snap_Resize:
					core.term_resize(tm, e.cols, e.rows, 8, 16)
				case string:
					for i := 0; i < len(e); {
						n := min(1 + rand.int_max(rand.int_max(2, gen) == 0 ? 4 : 2048, gen), len(e) - i)
						ts_write(tm, e[i:i + n])
						i += n
						switch rand.int_max(40, gen) {
						case 0: // a resize mid-stream (even mid-escape): the copy follows at this offset
							core.term_resize(tm, u16(20 + rand.int_max(100, gen)), u16(5 + rand.int_max(40, gen)), 8, 16)
						case 1:
							core.term_streams_flush()
						case 2: // hidden, then shown again: a fresh snapshot
							if v := term_view_peek(TS_TAB); v != nil do term_view_detach(v)
							else do term_view_of(TS_TAB)
						case 3:
							if term_view_peek(TS_TAB) != nil {
								ts_same(t, tm, fmt.tprintf("%s seed %d mid-stream", cs.name, seed))
								checks += 1
							}
						}
					}
				}
			}
			if term_view_peek(TS_TAB) == nil do term_view_of(TS_TAB)
			ts_same(t, tm, fmt.tprintf("%s seed %d", cs.name, seed))
			v := term_view_peek(TS_TAB)
			testing.expectf(t, v != nil && !v.stale, "%s: a RESIZE came at another offset than the window's", cs.name)
			ts_end(tm)
		}
	}
}

// A window that stops taking DATA: the core sends STREAM_CREDIT, holds the rest, and past
// STREAM_BEHIND_MAX sends a fresh snapshot instead (exempt from credit). A resize while DATA
// waits is sent after exactly the bytes before it.
@(test)
stream_credit_exhausted :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(80, 24)
	defer ts_end(tm)
	v := term_view_of(TS_TAB)
	testing.expect(t, v != nil && v.gt != nil, "attached")
	s := core.term_streams()[0]
	testing.expect_value(t, s.snapshots, 1)
	term_view_credit_off = true
	line := strings.repeat("x", 99, context.temp_allocator)
	for i in 0 ..< 3000 do ts_write(tm, fmt.tprintf("%s %05d\r\n", line, i)) // ~315 KB
	core.term_streams_flush()
	testing.expect_value(t, int(s.sent), core.STREAM_CREDIT) // the credit, no more
	testing.expect_value(t, v.offset, u64(core.STREAM_CREDIT))
	core.term_resize(tm, 60, 20, 8, 16) // waits behind the held DATA
	ts_write(tm, "after the resize\r\n")
	core.term_streams_flush()
	testing.expect_value(t, v.cols, u16(80)) // not yet: its bytes are not there
	// the window takes it all again: the rest, then the resize at its offset
	term_view_credit_off = false
	credit: [4]u8
	endian.put_u32(credit[:], .Little, u32(core.STREAM_CREDIT))
	client_frame(v.channel, .Credit, credit[:])
	core.window_link_pump()
	testing.expect(t, ts_same(t, tm, "after credit"))
	testing.expect_value(t, v.cols, u16(60))
	testing.expect(t, !v.stale, "the resize came at the window's offset")
	testing.expect_value(t, s.snapshots, 1)

	// stopped again, and over STREAM_BEHIND_MAX: a snapshot instead of the bytes
	term_view_credit_off = true
	big := strings.repeat("y", 1023, context.temp_allocator)
	for i in 0 ..< 5000 do ts_write(tm, fmt.tprintf("%s\n", big)) // 5 MB
	core.term_streams_flush()
	testing.expectf(t, s.snapshots >= 2, "a fresh snapshot (%d)", s.snapshots)
	testing.expect_value(t, v.offset, tm.offset) // the snapshot is at the core's offset
	term_view_history_finish(v)
	a, _ := core.screen_hash(tm.gt, 200)
	b, _ := core.screen_hash(v.gt, 200)
	testing.expect_value(t, a, b)
}

// Detached (hidden more than HIDDEN_DETACH), the copy goes; shown again, it comes back from a
// snapshot, equal. A view whose tab is gone from the core gets CLOSE.
@(test)
stream_detach_reattach :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(40, 10)
	defer ts_end(tm)
	ts_write(tm, "\x1b[31mred\x1b[0m before\r\n")
	v := term_view_of(TS_TAB)
	testing.expect(t, ts_same(t, tm, "attached"))
	v.shown = {} // long ago, and its tab is on no screen (no session here)
	term_views_tick()
	testing.expect(t, term_view_peek(TS_TAB) == nil, "detached")
	testing.expect_value(t, len(core.term_streams()), 0)
	ts_write(tm, "while hidden \x1b[1mbold\x1b[0m\r\n")
	core.term_resize(tm, 50, 12, 8, 16)
	testing.expect(t, term_view_of(TS_TAB) != nil, "attached again")
	testing.expect(t, ts_same(t, tm, "reattached"))
	// a new terminal for the tab (term_start's): a snapshot of it
	gh.terminal_free(tm.gt)
	core.term_new_gt(tm)
	ts_write(tm, "a new process\r\n")
	testing.expect(t, ts_same(t, tm, "new terminal"))
}

// The screen first: a copy is drawable at the snapshot's READY, its history follows a little per
// frame (newest page first) while output goes on, and ends equal.
@(test)
stream_history_after_ready :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(100, 30)
	defer ts_end(tm)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 10_000 do fmt.sbprintf(&b, "\x1b[3%dmline %05d\x1b[0m %s\r\n", i % 8, i, strings.repeat("w", i % 70, context.temp_allocator))
	ts_write(tm, strings.to_string(b))
	v := term_view_of(TS_TAB)
	testing.expect(t, v != nil && v.gt != nil, "drawable at READY")
	testing.expect(t, v.dec != nil, "history still to come")
	for i in 0 ..< 50 do ts_write(tm, fmt.tprintf("live output %d while history loads\r\n", i))
	core.term_streams_flush()
	testing.expect(t, v.dec != nil, "history still to come")
	testing.expect(t, ts_same(t, tm, "output while history loads"))
	// a resize while history loads: the window takes the rest of it first (a page that comes
	// after a reflow cannot be applied)
	term_view_detach(v)
	v = term_view_of(TS_TAB)
	testing.expect(t, v.dec != nil, "history to come again")
	core.term_resize(tm, 90, 28, 8, 16)
	ts_write(tm, "and after a resize\r\n")
	testing.expect(t, ts_same(t, tm, "a resize while history loads"))
}

// A snapshot over the frame limit is cut, oldest scrollback first, until it fits (§5.1: the
// limit is never raised for it).
@(test)
stream_snapshot_fits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(120, 30)
	defer ts_end(tm)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20_000 do fmt.sbprintf(&b, "\x1b[38;2;%d;%d;%dmrow %06d %s\x1b[0m\r\n", i % 256, (i * 7) % 256, (i * 13) % 256, i, strings.repeat("z", 100, context.temp_allocator))
	ts_write(tm, strings.to_string(b))
	full, _, err := core.snapshot_encode(tm.gt, {}, {core.SNAPSHOT_GHOSTSNP}, allocator = context.temp_allocator)
	testing.expect_value(t, err, core.Snapshot_Error.None)
	limit := len(full) / 3
	cut, cerr := core.snapshot_encode_fit(tm.gt, {}, limit)
	testing.expect_value(t, cerr, core.Snapshot_Error.None)
	testing.expectf(t, len(cut) <= limit, "%d bytes over the limit %d", len(cut), limit)
	gt, _, derr := core.snapshot_decode(cut)
	testing.expect_value(t, derr, core.Snapshot_Error.None)
	if gt == nil do return
	defer gh.terminal_free(gt)
	testing.expect_value(t, gt_screen_text(gt), gt_screen_text(tm.gt)) // the screen itself is whole
	h1, h2: c.size_t
	gh.terminal_get(tm.gt, .Scrollback_Rows, &h1)
	gh.terminal_get(gt, .Scrollback_Rows, &h2)
	testing.expectf(t, h2 > 0 && h2 < h1, "history cut, not dropped: %d of %d rows", h2, h1)
}

// Input and focus go back on the stream: the core writes them to the program's PTY (a pipe here);
// a paste the core typed scrolls the copy back down; the selection the core copies is the copy's.
@(test)
stream_input_focus_scroll_selection :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(40, 5)
	defer ts_end(tm)
	fds: [2]posix.FD
	posix.pipe(&fds)
	defer posix.close(fds[0])
	tm.pty.fd = i32(fds[1]) // closed by term_free (reader_stop_and_close)
	tm.running = true
	v := term_view_of(TS_TAB)
	read_all :: proc(fd: posix.FD) -> string {
		posix.fcntl(fd, .SETFL, posix.O_NONBLOCK)
		buf: [256]u8
		n := posix.read(fd, &buf[0], len(buf))
		return n > 0 ? strings.clone(string(buf[:n]), context.temp_allocator) : ""
	}
	e := sapp_key_event(.LEFT)
	term_key_down(v, &e)
	testing.expect_value(t, read_all(fds[0]), "\x1b[D")
	ts_write(tm, "\x1b[?1004h") // the program asks for focus reports: the core knows, from its own terminal
	core.term_streams_flush()
	term_focus(v, false)
	term_focus(v, true)
	testing.expect_value(t, read_all(fds[0]), "\x1b[O\x1b[I")
	// scrolled back, then a paste from the core (Send_Text, Claude's held text): down again
	for i in 0 ..< 30 do ts_write(tm, fmt.tprintf("l%d\r\n", i))
	core.term_streams_flush()
	sv := gh.Scroll_Viewport{tag = .Top}
	gh.terminal_scroll_viewport(v.gt, sv)
	sb: gh.Scrollbar
	gh.terminal_get(v.gt, .Scrollbar, &sb)
	testing.expect(t, sb.offset == 0, "at the top")
	core.term_paste(tm, "pasted")
	core.term_scroll_to_bottom(tm)
	gh.terminal_get(v.gt, .Scrollbar, &sb)
	testing.expect(t, sb.offset + sb.len >= sb.total, "back at the bottom")
	testing.expect_value(t, read_all(fds[0]), "pasted")
	// Copy_Selection reads the window's copy (core.window_term_selection)
	sel_a, sel_b := gh.Grid_Ref{size = size_of(gh.Grid_Ref)}, gh.Grid_Ref{size = size_of(gh.Grid_Ref)}
	pa := gh.Point{tag = .Active}
	pa.value.coordinate = {0, 0}
	pb := gh.Point{tag = .Active}
	pb.value.coordinate = {2, 0}
	gh.terminal_grid_ref(v.gt, pa, &sel_a)
	gh.terminal_grid_ref(v.gt, pb, &sel_b)
	sel := gh.Selection{size = size_of(gh.Selection), start = sel_a, end = sel_b}
	gh.terminal_set(v.gt, .Selection, &sel)
	testing.expect(t, term_view_selection(TS_TAB) != "", "the copy's selection")
	testing.expect_value(t, core.term_selection_text(tm), "") // the core's terminal has none
}

@(private = "file")
sapp_key_event :: proc(k: sapp.Keycode) -> sapp.Event {return {type = .KEY_DOWN, key_code = k}}

// Past the scrollback limit (TERM_SCROLLBACK_MAX), both copies drop their oldest rows: the same rows.
@(test)
stream_scrollback_limit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(120, 40)
	defer ts_end(tm)
	ts_write(tm, "first\r\n")
	term_view_of(TS_TAB)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 400_000 do fmt.sbprintf(&b, "\x1b[3%dm%06d\x1b[0m \x1b[1mbold\x1b[22m text %s \x1b[38;5;%dmcolour\x1b[0m\r\n", i % 8, i, strings.repeat("w", i % 40, context.temp_allocator), i % 256)
	s := strings.to_string(b)
	for i := 0; i < len(s); i += 65536 do ts_write(tm, s[i:min(i + 65536, len(s))])
	core.term_streams_flush()
	v := term_view_peek(TS_TAB)
	testing.expect_value(t, v.offset, tm.offset)
	// the newest rows (what term_views_check compares) are the same; how many of the oldest each
	// keeps may differ by a page (see core.screen_hash)
	ha, _ := core.screen_hash(tm.gt, VIEW_CHECK_ROWS)
	hb, _ := core.screen_hash(v.gt, VIEW_CHECK_ROWS)
	testing.expect_value(t, ha, hb)
	if ha != hb {
		da := strings.builder_make(context.temp_allocator)
		db := strings.builder_make(context.temp_allocator)
		core.screen_dump(tm.gt, &da, VIEW_CHECK_ROWS)
		core.screen_dump(v.gt, &db, VIEW_CHECK_ROWS)
		la, lb := strings.split_lines(strings.to_string(da), context.temp_allocator), strings.split_lines(strings.to_string(db), context.temp_allocator)
		for i in 0 ..< max(len(la), len(lb)) {
			x := i < len(la) ? la[i] : "<none>"
			y := i < len(lb) ? lb[i] : "<none>"
			if x != y {
				testing.expectf(t, false, "line %d differs\n  core:   %.300s\n  window: %.300s", i, x, y)
				break
			}
		}
	}
	h1, h2: c.size_t
	gh.terminal_get(tm.gt, .Scrollback_Rows, &h1)
	gh.terminal_get(v.gt, .Scrollback_Rows, &h2)
	testing.expectf(t, abs(int(h1) - int(h2)) <= 1000, "scrollback depths %d and %d", h1, h2)
}

// Test mode's detach_window, then attach_window (M3-G): the copies go with the link, and come
// back live from fresh snapshots, never frozen on the old channels.
@(test)
stream_detach_window_then_attach :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tl_host_off()
	defer tl_host_on()
	saved_state, saved_client := state, client
	core.state = core.State{}
	client = {}
	client_attach()
	if !testing.expect(t, client.attached) do return
	core.app_context = context
	font.cell_w, font.cell_h = 8, 16
	tm := new(core.Term, runtime.heap_allocator())
	core.term_init(tm, 60, 10)
	tm.cell = {8, 16}
	core.terms[TS_TAB] = tm
	defer {
		term_views_drop_all()
		delete_key(&core.terms, TS_TAB)
		core.term_free(tm)
		free(tm, runtime.heap_allocator())
		if client.attached do core.core_detach_window()
		core.replica_free(&client.replica, deferred_allocator(&client.deferred))
		deferred_release(&client.deferred)
		deferred_release(&client.deferred)
		for r in client.deferred.retired do delete(r)
		delete(client.results)
		delete(client.facts_sent)
		client, state = saved_client, saved_state
		core.state = core.State{}
	}
	ts_write(tm, "before the detach\r\n")
	v := term_view_of(TS_TAB)
	testing.expect(t, v != nil && ts_same(t, tm, "attached"))
	client_detach()
	testing.expect(t, term_view_peek(TS_TAB) == nil, "the copies went with the link")
	testing.expect(t, term_view_of(TS_TAB) == nil, "no copy while detached")
	ts_write(tm, "while detached\r\n")
	client_reattach()
	testing.expect(t, client.attached, "attached again")
	v = term_view_of(TS_TAB)
	testing.expect(t, v != nil && ts_same(t, tm, "reattached"))
	ts_write(tm, "live after the attach\r\n") // streamed on the new channel, not frozen
	testing.expect(t, ts_same(t, tm, "live"))
	testing.expect(t, strings.contains(term_screen_text(term_view_peek(TS_TAB)), "live after the attach"))
}

// Round 1 of the G+H review. A RESIZE the link refuses is never lost: a snapshot follows instead.
// A snapshot that cannot be made backs off (not every tick) and, too large even with little
// scrollback, falls back to fewer images, then the screen alone. A snapshot the window cannot
// decode makes its copy stale (attached again), and the test check counts a copy with none.
@(test)
stream_failures_recover :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(80, 24)
	defer ts_end(tm)
	defer core.stream_snap_limit = 0
	ts_write(tm, "hello\r\n")
	// nothing fits: the attach's snapshot fails, and is not tried on every flush after
	core.stream_snap_limit = 10
	v := term_view_of(TS_TAB)
	testing.expect(t, v != nil && v.gt == nil, "attached, no copy yet")
	s := core.term_streams()[0]
	for _ in 0 ..< 20 do core.term_streams_flush()
	testing.expectf(t, s.snap_retries <= 2, "backed off: %d tries", s.snap_retries)
	out, compared := term_views_check()
	testing.expect_value(t, compared, 1)
	testing.expectf(t, strings.contains(out, "no snapshot"), "the check says so: %q", out)
	core.stream_snap_limit = 0
	out, _ = term_views_check() // tried at once
	testing.expect_value(t, out, "")
	testing.expect(t, ts_same(t, tm, "after the back-off"))
	// a snapshot the window cannot read: stale, so term_views_tick attaches it again
	junk := [?]u8{1, 2, 3, 4, 5, 6, 7, 8}
	term_view_frame(cw.Frame{channel = v.channel, kind = u8(cw.Kind.Snapshot), payload = junk[:]})
	testing.expect(t, v.stale, "a snapshot that does not decode: stale")
	term_views_tick()
	v = term_view_peek(TS_TAB)
	testing.expect(t, v != nil && !v.stale && ts_same(t, tm, "attached again"))
	// the link refuses a RESIZE: a snapshot is due instead
	s = core.term_streams()[0]
	cw.mem_close(client.end)
	core.term_resize(tm, 60, 20, 8, 16)
	core.term_streams_flush()
	testing.expect(t, s.need_snap, "a snapshot replaces the lost RESIZE")
}

// Too large with even a little scrollback: the screen alone (never nothing).
@(test)
stream_snapshot_screen_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tm := ts_begin(120, 30)
	defer ts_end(tm)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20_000 do fmt.sbprintf(&b, "\x1b[38;2;%d;%d;%dmrow %06d %s\x1b[0m\r\n", i % 256, (i * 7) % 256, (i * 13) % 256, i, strings.repeat("z", 100, context.temp_allocator))
	ts_write(tm, strings.to_string(b))
	clone, ok := core.gt_clone(tm.gt)
	if !testing.expect(t, ok) do return
	none: uint = 0
	gh.terminal_set(clone, .Scrollback_Max_Bytes, &none)
	screen, _, err := core.snapshot_encode(clone, {}, {core.SNAPSHOT_GHOSTSNP}, allocator = context.temp_allocator)
	gh.terminal_free(clone)
	testing.expect_value(t, err, core.Snapshot_Error.None)
	limit := len(screen) + 256
	cut, cerr := core.snapshot_encode_fit(tm.gt, {}, limit)
	testing.expect_value(t, cerr, core.Snapshot_Error.None)
	testing.expectf(t, len(cut) <= limit, "%d bytes over the limit %d", len(cut), limit)
	gt, _, derr := core.snapshot_decode(cut)
	if !testing.expect_value(t, derr, core.Snapshot_Error.None) || gt == nil do return
	defer gh.terminal_free(gt)
	testing.expect_value(t, gt_screen_text(gt), gt_screen_text(tm.gt))
}
