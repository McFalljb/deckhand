package main

// Terminal input without a process: the macOS line-editing keys, the key
// encoder's Option keys, and mouse selection while a drag is under way (the
// bytes an app gets go to a pipe instead of a PTY).

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

// A 40x5 terminal with 10x20 px cells at 0,0; what it sends to the "app" is
// read from the returned fd.
@(private = "file")
test_term :: proc(term: ^Term) -> posix.FD {
	app_context = context
	font.cell_w, font.cell_h = 10, 20
	term_init(term, 40, 5)
	term.w, term.h = 400, 100
	fds: [2]posix.FD
	posix.pipe(&fds)
	term.pty.fd = c_int(fds[1])
	term.running = true
	return fds[0]
}

@(private = "file")
c_int :: proc(fd: posix.FD) -> i32 {return i32(fd)}

@(private = "file")
sent :: proc(fd: posix.FD) -> string {
	posix.fcntl(fd, .SETFL, posix.O_NONBLOCK)
	buf: [256]u8
	n := posix.read(fd, &buf[0], len(buf))
	return n > 0 ? strings.clone(string(buf[:n]), context.temp_allocator) : ""
}

@(private = "file")
key :: proc(term: ^Term, k: sapp.Keycode, mods: u32) {
	e := sapp.Event{type = .KEY_DOWN, key_code = k, modifiers = mods}
	term_key_down(term, &e)
	e.type = .KEY_UP
	term_key_up(term, &e)
}

@(private = "file")
mouse :: proc(term: ^Term, type: sapp.Event_Type, col, row: f32, mods: u32 = 0, clicks := 1) {
	e := sapp.Event{type = type, mouse_button = .LEFT, mouse_x = term_pad() + (col + 0.5) * font.cell_w, mouse_y = term_pad() + (row + 0.5) * font.cell_h, modifiers = mods}
	#partial switch type {
	case .MOUSE_DOWN: term_mouse_down(term, &e, clicks)
	case .MOUSE_MOVE: term_mouse_move(term, &e)
	case .MOUSE_UP:   term_mouse_up(term, &e)
	}
}

// Selected cells as term_draw counts them (drawn_selected; the scene's assert_drawn_selection):
// the render state's .Selected flag, read without drawing.
@(private = "file")
render_selected_cells :: proc(t: ^Term) -> int {
	gh.render_state_update(t.rs, t.gt)
	gh.render_state_get(t.rs, .Row_Iterator, &t.it)
	n := 0
	for gh.render_state_row_iterator_next(t.it) {
		gh.render_state_row_get(t.it, .Cells, &t.cells)
		for gh.render_state_row_cells_next(t.cells) {
			selected: bool
			gh.render_state_row_cells_get(t.cells, .Selected, &selected)
			if selected do n += 1
		}
	}
	return n
}

@(test)
mac_line_editing_keys :: proc(t: ^testing.T) {
	SUPER, ALT, SHIFT: u32 = sapp.MODIFIER_SUPER, sapp.MODIFIER_ALT, sapp.MODIFIER_SHIFT
	testing.expect_value(t, mac_key_text(.BACKSPACE, SUPER, false), "\x15")
	testing.expect_value(t, mac_key_text(.LEFT, SUPER, true), "\x01")
	testing.expect_value(t, mac_key_text(.RIGHT, SUPER, true), "\x05")
	testing.expect_value(t, mac_key_text(.LEFT, ALT, true), "\x1bb")
	testing.expect_value(t, mac_key_text(.RIGHT, ALT, false), "\x1bf")
	testing.expect_value(t, mac_key_text(.DELETE, ALT, false), "\x1bd")
	testing.expect_value(t, mac_key_text(.DELETE, ALT, true), "") // kitty: the encoder's CSI 3;3~
	// other modifier sets keep the encoder (⇧⌥← selects in apps that know it)
	testing.expect_value(t, mac_key_text(.LEFT, ALT | SHIFT, false), "")
	testing.expect_value(t, mac_key_text(.BACKSPACE, SUPER | SHIFT, false), "")
	testing.expect_value(t, mac_key_text(.BACKSPACE, ALT, false), "")
	testing.expect_value(t, mac_key_text(.BACKSPACE, 0, false), "")

	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	key(&term, .BACKSPACE, ALT)
	testing.expect_value(t, sent(fd), "\x1b\x7f") // ⌥⌫: delete word back (zsh, readline, pi)
	key(&term, .BACKSPACE, SUPER)
	testing.expect_value(t, sent(fd), "\x15") // ⌘⌫: delete to line start
	key(&term, .LEFT, ALT)
	key(&term, .RIGHT, ALT)
	key(&term, .LEFT, SUPER)
	key(&term, .RIGHT, SUPER)
	key(&term, .DELETE, ALT)
	testing.expect_value(t, sent(fd), "\x1bb\x1bf\x01\x05\x1bd")
	key(&term, .LEFT, 0)
	testing.expect_value(t, sent(fd), "\x1b[D") // plain keys: the encoder, as before

	// pi turns on the kitty keyboard protocol: the bound keys stay legacy
	// text (no release events for them), ⌥⌫ and ⌥⌦ are what pi reads as
	// alt+backspace and alt+delete
	kitty := "\x1b[>1u"
	gh.terminal_vt_write(term.gt, raw_data(kitty), len(kitty))
	testing.expect_value(t, kitty_flags(&term), 1)
	key(&term, .BACKSPACE, SUPER)
	key(&term, .LEFT, ALT)
	testing.expect_value(t, sent(fd), "\x15\x1bb")
	key(&term, .BACKSPACE, ALT)
	testing.expect_value(t, sent(fd), "\x1b[127;3u")
	key(&term, .DELETE, ALT)
	testing.expect_value(t, sent(fd), "\x1b[3;3~")
}

// The selection follows the drag (drawn every move), not just the release.
@(test)
selection_updates_during_drag :: proc(t: ^testing.T) {
	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	line := "hello-world foo.bar"
	gh.terminal_vt_write(term.gt, raw_data(line), len(line))

	mouse(&term, .MOUSE_DOWN, 2, 0)
	testing.expect_value(t, term_selection_text(&term), "")
	term.changed = false
	mouse(&term, .MOUSE_MOVE, 8, 0)
	testing.expect_value(t, term_selection_text(&term), "llo-wor") // before any release
	testing.expect(t, term.changed, "a drag step must ask for a redraw")
	testing.expect(t, render_selected_cells(&term) > 0, "the frame drawn now shows the selection")
	mouse(&term, .MOUSE_MOVE, 12, 0)
	testing.expect_value(t, term_selection_text(&term), "llo-world f")
	mouse(&term, .MOUSE_UP, 12, 0)
	testing.expect_value(t, term_selection_text(&term), "llo-world f")

	// ⇧-click extends from where the selection started
	mouse(&term, .MOUSE_DOWN, 16, 0, sapp.MODIFIER_SHIFT)
	mouse(&term, .MOUSE_UP, 16, 0, sapp.MODIFIER_SHIFT)
	testing.expect_value(t, term_selection_text(&term), "llo-world foo.b")
	// a click without a drag clears it
	mouse(&term, .MOUSE_DOWN, 4, 0)
	mouse(&term, .MOUSE_UP, 4, 0)
	testing.expect_value(t, term_selection_text(&term), "")
	testing.expect_value(t, render_selected_cells(&term), 0)
	// double-click a word, triple-click the line
	mouse(&term, .MOUSE_DOWN, 14, 0, clicks = 2)
	mouse(&term, .MOUSE_UP, 14, 0)
	testing.expect_value(t, term_selection_text(&term), "foo.bar")
	mouse(&term, .MOUSE_DOWN, 14, 0, clicks = 3)
	mouse(&term, .MOUSE_UP, 14, 0)
	testing.expect_value(t, term_selection_text(&term), line)
	testing.expect_value(t, sent(fd), "") // no mouse mode: nothing reported
}

// An app that tracks button motion (1002 + SGR 1006, as pi does) gets the
// drag with its button: 32+0, not 35 ("no button"), which pi ignores.
@(test)
reported_drag_carries_its_button :: proc(t: ^testing.T) {
	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	modes := "hello\x1b[?1002h\x1b[?1006h"
	gh.terminal_vt_write(term.gt, raw_data(modes), len(modes))

	mouse(&term, .MOUSE_DOWN, 2, 0)
	mouse(&term, .MOUSE_MOVE, 5, 0)
	mouse(&term, .MOUSE_UP, 5, 0)
	testing.expect_value(t, sent(fd), "\x1b[<0;3;1M\x1b[<32;6;1M\x1b[<0;6;1m")
	testing.expect_value(t, term_selection_text(&term), "")

	// ⇧+drag selects instead, and is not reported
	mouse(&term, .MOUSE_DOWN, 0, 0, sapp.MODIFIER_SHIFT)
	mouse(&term, .MOUSE_MOVE, 3, 0, sapp.MODIFIER_SHIFT)
	testing.expect_value(t, term_selection_text(&term), "hell")
	mouse(&term, .MOUSE_UP, 3, 0, sapp.MODIFIER_SHIFT)
	testing.expect_value(t, sent(fd), "")
	// a reported click clears that selection
	mouse(&term, .MOUSE_DOWN, 1, 0)
	mouse(&term, .MOUSE_UP, 1, 0)
	testing.expect_value(t, term_selection_text(&term), "")
}

// A drag above the grid scrolls back a row per step; the selection follows.
@(test)
selection_drag_autoscrolls :: proc(t: ^testing.T) {
	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 20 do strings.write_string(&b, i < 19 ? "line\r\n" : "last")
	text := strings.to_string(b)
	gh.terminal_vt_write(term.gt, raw_data(text), len(text))

	mouse(&term, .MOUSE_DOWN, 0, 2)
	mouse(&term, .MOUSE_MOVE, 0, -3) // above the pane: row 0
	testing.expect_value(t, strings.count(term_selection_text(&term), "\n"), 2)
	term_drag_tick(&term, true)
	testing.expect_value(t, strings.count(term_selection_text(&term), "\n"), 3)
	term_drag_tick(&term, true) // within AUTOSCROLL_STEP: no second step yet
	testing.expect_value(t, strings.count(term_selection_text(&term), "\n"), 3)
	mouse(&term, .MOUSE_UP, 0, -3)
	term.drag_scrolled = {}
	term_drag_tick(&term, true) // released: nothing moves
	testing.expect_value(t, strings.count(term_selection_text(&term), "\n"), 3)
}

// Output streams in during a drag and the scrollback limit drops the oldest
// rows: the selection keeps its start on the text it was pressed on.
@(test)
selection_anchor_survives_scrollback_trim :: proc(t: ^testing.T) {
	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	max_bytes: uint = 1 // as little as libghostty keeps: older pages go
	gh.terminal_set(term.gt, .Scrollback_Max_Bytes, &max_bytes)
	lines :: proc(term: ^Term, from, to: int) {
		b := strings.builder_make(context.temp_allocator)
		for i in from ..< to do fmt.sbprintf(&b, "\r\nrow %06d", i)
		s := strings.to_string(b)
		gh.terminal_vt_write(term.gt, raw_data(s), len(s))
	}
	lines(&term, 0, 2000)
	mouse(&term, .MOUSE_DOWN, 0, 2) // on "row 001997"
	mouse(&term, .MOUSE_MOVE, 5, 2)
	testing.expect_value(t, term_selection_text(&term), "row 00")
	lines(&term, 2000, 3000) // trims the oldest rows (about 1600 kept), not this one
	mouse(&term, .MOUSE_MOVE, 9, 4)
	got := term_selection_text(&term)
	testing.expectf(t, strings.has_prefix(got, "row 001997"), "selection drifted: starts %q", got[:min(len(got), 40)])
	mouse(&term, .MOUSE_UP, 9, 4)
}

// ⇧+right press with mouse tracking on: neither reported (⇧ overrides) nor a
// selection; the moves and the release after it report no button or release.
@(test)
shift_right_press_reports_nothing :: proc(t: ^testing.T) {
	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	modes := "hello\x1b[?1002h\x1b[?1006h"
	gh.terminal_vt_write(term.gt, raw_data(modes), len(modes))
	e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .RIGHT, mouse_x = term_pad() + 25, mouse_y = term_pad() + 10, modifiers = sapp.MODIFIER_SHIFT}
	term_mouse_down(&term, &e, 1)
	e.type, e.mouse_x = .MOUSE_MOVE, term_pad() + 55
	term_mouse_move(&term, &e)
	e.type = .MOUSE_UP
	term_mouse_up(&term, &e)
	testing.expect_value(t, sent(fd), "")
}

// A drag whose release never arrived (no left button down any more) stops,
// and term_cancel_drag ends one outright.
@(test)
drag_ends_without_the_button :: proc(t: ^testing.T) {
	term: Term
	fd := test_term(&term)
	defer {term_free(&term); posix.close(fd)}
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 20 do strings.write_string(&b, "line\r\n")
	gh.terminal_vt_write(term.gt, raw_data(strings.to_string(b)), len(strings.to_string(b)))
	mouse(&term, .MOUSE_DOWN, 0, 2)
	mouse(&term, .MOUSE_MOVE, 0, -3)
	n := strings.count(term_selection_text(&term), "\n")
	term_drag_tick(&term, false) // the button is up: no scroll, the drag is over
	testing.expect_value(t, strings.count(term_selection_text(&term), "\n"), n)
	testing.expect(t, !term.selecting, "drag still on")
	mouse(&term, .MOUSE_DOWN, 0, 2)
	mouse(&term, .MOUSE_MOVE, 0, -3)
	term_cancel_drag(&term)
	testing.expect(t, !term.selecting && !term.mouse_down, "drag still on")
	term_drag_tick(&term, true)
	testing.expect_value(t, strings.count(term_selection_text(&term), "\n"), n)
}

// Through the app's event handler (moved from the term scene): ⌘ chords without a mapping send
// the terminal nothing (they are the app's or nobody's), ⌘← alone is line editing; a drag
// belongs to the tab it started in: a tab switch, or the window going to the background, ends
// it, so a later move past the top edge neither extends the selection nor scrolls.
@(test)
terminal_through_the_app :: proc(t: ^testing.T) {
	a, b: Term
	fda := test_term(&a)
	fdb := test_term(&b)
	s := Open_Session{id = 9101}
	append(&s.tabs, Tab{id = 9102, kind = Shell_Tab{}}, Tab{id = 9103, kind = Shell_Tab{}})
	s.active_tab = 9102
	saved_sessions, saved_current := state.open_sessions, state.current_session
	state.open_sessions = {}
	append(&state.open_sessions, s)
	state.current_session = 9101
	terms[9102], terms[9103] = &a, &b
	defer {
		delete_key(&terms, 9102)
		delete_key(&terms, 9103)
		delete(state.open_sessions[0].tabs)
		delete(state.open_sessions)
		state.open_sessions, state.current_session = saved_sessions, saved_current
		term_free(&a); term_free(&b)
		posix.close(fda); posix.close(fdb)
	}
	app_key :: proc(k: sapp.Keycode, mods: u32) {
		e := sapp.Event{type = .KEY_DOWN, key_code = k, modifiers = mods}
		event(&e)
		e.type = .KEY_UP
		event(&e)
	}
	app_key(.LEFT, sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT)
	app_key(.BACKSPACE, sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)
	app_key(.RIGHT, sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL)
	testing.expect_value(t, sent(fda), "")
	app_key(.LEFT, sapp.MODIFIER_SUPER)
	testing.expect_value(t, sent(fda), "\x01")

	drags_follow_focus()
	mouse(&a, .MOUSE_DOWN, 2, 2)
	mouse(&a, .MOUSE_MOVE, 2, 3)
	testing.expect(t, a.selecting, "dragging")
	state.open_sessions[0].active_tab = 9103 // ⌘2
	drags_follow_focus()
	state.open_sessions[0].active_tab = 9102 // ⌘1
	drags_follow_focus()
	testing.expect(t, !a.selecting && !a.mouse_down, "a tab switch ends the drag")

	mouse(&a, .MOUSE_DOWN, 2, 2)
	mouse(&a, .MOUSE_MOVE, 2, 3)
	testing.expect(t, a.selecting, "dragging again")
	e := sapp.Event{type = .UNFOCUSED}
	event(&e)
	testing.expect(t, !a.selecting && !a.mouse_down, "the window going to the background ends the drag")
	e.type = .FOCUSED
	event(&e)
}
