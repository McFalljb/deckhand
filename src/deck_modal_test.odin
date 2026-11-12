package main

// The Deck view is the centre with no session shown (core Show_No_Session; ui_deck.odin): while
// it shows there is no current session, so nothing of the session it covers is laid out, hit,
// typed into, focused, scrolled or seen, and every input path finds no pane, by construction.
// Esc (or the toggle) shows that session again.
//
// Review round 2 of #104 found pointer events reaching the hidden panes through stale rects
// (wheel, clicks after a layout change, moves, pages and apps), a restore to a field that could
// not take the keyboard, and terminals left unfocused. These tests hold each of them.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"
import gh "ghostty"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
dc_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	p := core.Project{id = 1, group = .Projects, cwd = strings.clone("/tmp/dc-proj"), label = strings.clone("web")}
	append(&state.projects, p)
	state.selected_project = p.id
	ui_hover = nil
	deck = {cards = deck.cards}
	tab_drag = {}
	state.settings.reduce_motion = true
	toast_clear()
}

@(private = "file")
dc_tab :: proc(id: u64, need := "") -> core.Tab {
	t := core.Tab{id = id, kind = core.Shell_Tab{}, title = strings.clone(fmt.tprintf("tab %d", id), runtime.heap_allocator()), status = .Running, has_term = true}
	t.prog.progress = -1
	switch need {
	case "waiting": t.prog.state, t.prog.kind = .Blocked, .Permission
	case "unseen":  t.unseen = true
	}
	return t
}

@(private = "file")
dc_session :: proc(id: u64, tabs: ..core.Tab) -> ^core.Open_Session {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("s%d", id)), cwd = strings.clone("/tmp/dc-proj"), title = strings.clone(fmt.tprintf("Session %d", id)), shown_at = i64(id)}
	for t in tabs do append(&s.tabs, t)
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	append(&state.sessions, core.Session{id = s.pi_session_id, path = strings.clone(fmt.tprintf("/tmp/dc-proj/%d.jsonl", id)), title = s.title})
	return &state.open_sessions[len(state.open_sessions) - 1]
}

@(private = "file")
dc_sent: [dynamic]u8

// A terminal copy for tab_id (no core: what it would send the program lands in dc_sent).
@(private = "file")
dc_term :: proc(tab_id: u64) -> ^Term_View {
	core.app_context = context
	font.cell_w, font.cell_h = 10, 20
	v := new(Term_View, runtime.heap_allocator())
	term_view_init(v)
	gh.terminal_new(nil, &v.gt, 40, 5)
	core.gt_setup(v.gt, core.term_colors())
	gh.terminal_resize(v.gt, 40, 5, 10, 20)
	v.cols, v.rows, v.w, v.h = 40, 5, 400, 100
	term_views[tab_id] = v
	dc_sent.allocator = runtime.heap_allocator()
	clear(&dc_sent)
	term_view_input_hook = proc(v: ^Term_View, b: []u8) {append(&dc_sent, ..b)}
	return v
}

@(private = "file")
dc_term_free :: proc(tab_id: u64) {
	if v := term_views[tab_id]; v != nil {
		term_view_free(v)
		free(v, runtime.heap_allocator())
	}
	delete_key(&term_views, tab_id)
	term_view_input_hook = nil
}

@(private = "file")
dc_key :: proc(k: sapp.Keycode, mods: u32 = 0) {
	e := sapp.Event{type = .KEY_DOWN, key_code = k, modifiers = mods}
	event(&e)
	e.type = .KEY_UP
	event(&e)
}

// 1. ⌘W, ⌘T: the deck closes, the hidden tab is neither closed nor joined by a new one; ⌥⌘A and

@(private = "file")
dc_open :: proc() {
	deck_toggle()
	core.inbox_drain()
	_ = ui_layout(1600, 900)
}

// Opening the deck: no session is current, every session stays open and running, nothing is on
// screen (no key view, no view on screen, no tab on screen, get_state's on_screen false).
@(test)
deck_modal_no_current_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dc_reset()
	defer {
		dc_term_free(101)
		dc_reset()
	}
	dc_session(100, dc_tab(101, "unseen"), dc_tab(102))
	dc_session(200, dc_tab(201, "waiting"))
	state.current_session = 100
	dc_term(101)
	_ = ui_layout(1600, 900)
	testing.expect(t, key_view() != nil && core.tab_on_screen(101), "the fixture: its terminal has the keyboard and shows")
	dc_open()
	testing.expect(t, deck_shown(), "the deck shows")
	testing.expect_value(t, state.current_session, u64(0))
	testing.expect_value(t, len(state.open_sessions), 2)
	testing.expect_value(t, len(core.find_session(100).tabs), 2)
	testing.expect(t, key_view() == nil && active_view() == nil, "no terminal takes keys")
	testing.expect(t, len(views_on_screen()) == 0, "no terminal view on screen (no frames)")
	testing.expect(t, !core.tab_on_screen(101), "no tab on screen")
	testing.expect(t, len(core.status_wants_seen()) == 0, "nothing wants marking seen")
	e := sapp.Event{type = .FOCUSED}
	event(&e)
	core.inbox_drain()
	testing.expect(t, core.find_session(100).tabs[0].unseen, "the window coming to the front keeps it unseen")
	js := core.state_json()
	testing.expectf(t, !strings.contains(js, `"on_screen":true`), "get_state: nothing on_screen")
}

// Round 2, finding 1: the pointer finds no pane under the deck, wherever the panes were last laid
// out: a press, a move or the wheel at the hidden terminal's last place (or over the tab strip,
// after the columns changed) reaches no terminal, page or app.
@(test)
deck_modal_pointer_has_no_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dc_reset()
	defer {
		dc_term_free(101)
		dc_reset()
	}
	dc_session(100, dc_tab(101))
	dc_session(200, dc_tab(201, "waiting"))
	state.current_session = 100
	v := dc_term(101)
	_ = ui_layout(1600, 900)
	d := clay.GetElementData(clay.ID("terminal"))
	if !testing.expect(t, d.found, "the fixture: its terminal is laid out") do return
	at := [2]f32{d.boundingBox.x + 20, d.boundingBox.y + 20}
	press := sapp.Event{type = .MOUSE_DOWN, mouse_x = at.x, mouse_y = at.y, mouse_button = .LEFT}
	testing.expect(t, pane_view(event_pane(&press)) != nil, "the fixture: a press there is the terminal's")
	dc_open()
	ui_do(core.Set_Layout{left_open = false}) // ⌘B: the centre moves under the old rects
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	for ty in ([]sapp.Event_Type{.MOUSE_DOWN, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_UP}) {
		for p in ([][2]f32{at, {at.x, 10}}) {
			e := sapp.Event{type = ty, mouse_x = p.x, mouse_y = p.y, mouse_button = .LEFT, scroll_y = -3}
			testing.expectf(t, pane_view(event_pane(&e)) == nil, "%v at %v: no pane under the deck", ty, p)
			event(&e)
		}
	}
	testing.expectf(t, len(dc_sent) == 0, "the hidden terminal got input: %q", string(dc_sent[:]))
	testing.expect(t, !v.mouse_down, "no press reached the hidden terminal")
	testing.expect(t, deck_shown(), "the deck stays")
}

// Keys, text and the input method under the deck reach no terminal; the arrows are the deck's.
@(test)
deck_modal_keys_reach_no_terminal :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dc_reset()
	defer {
		dc_term_free(101)
		dc_reset()
	}
	dc_session(100, dc_tab(101))
	dc_session(200, dc_tab(201, "waiting"))
	state.current_session = 100
	dc_term(101)
	_ = ui_layout(1600, 900)
	dc_open()
	dc_key(.DOWN)
	testing.expect(t, deck.sel != 0, "↓ picks a card")
	ch := sapp.Event{type = .CHAR, char_code = 'x'}
	event(&ch)
	ime_commit("é")
	paste := sapp.Event{type = .CLIPBOARD_PASTED}
	win_os.get_clipboard = proc() -> string {return "pasted"}
	event(&paste)
	dc_key(.W, u32(sapp.MODIFIER_SUPER)) // ⌘W: no tab to close
	core.inbox_drain()
	testing.expectf(t, len(dc_sent) == 0, "the hidden terminal got: %q", string(dc_sent[:]))
	testing.expect_value(t, len(core.find_session(100).tabs), 1)
	testing.expect(t, deck_shown(), "the deck stays")
	win_os.get_clipboard = nil
}

// Esc (and the toggle) shows the session it was opened from again, with its terminal focused as
// before (round 2, finding 3: never unfocused); a field of the panes does not get the keyboard
// back (finding 2: nothing to restore, nothing stuck).
@(test)
deck_modal_esc_returns :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dc_reset()
	defer {
		dc_term_free(101)
		dc_reset()
	}
	dc_session(100, dc_tab(101))
	dc_session(200, dc_tab(201, "waiting"))
	state.current_session = 100
	v := dc_term(101)
	term_focus(v, true)
	state.focus_widget = "changes_message"
	_ = ui_layout(1600, 900)
	dc_open()
	testing.expect_value(t, state.focus_widget, "")
	dc_key(.ESCAPE)
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !deck_shown() && !deck.on, "Esc closes the deck")
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect(t, v.focused, "its terminal kept the keyboard's focus")
	testing.expect(t, key_view() == v, "and has the keys again")
	// the toggle, the same
	dc_open()
	testing.expect(t, deck_shown(), "opens again")
	deck_toggle()
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect(t, !deck_shown(), "the toggle closes it")
	// the drawer's field keeps the keyboard (it stays on screen)
	state.home_open = true
	state.focus_widget = "agent_input"
	dc_open()
	testing.expect_value(t, state.focus_widget, "agent_input")
	state.focus_widget = ""
	dc_key(.ESCAPE)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(100))
}

// The session it was opened from closed meanwhile: Esc ends the deck, the empty centre stays.
// Showing a session any other way (its row, ⌥⌘A, an agent's focus_session) ends it too.
@(test)
deck_modal_back_gone_and_other_ways :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dc_reset()
	defer dc_reset()
	dc_session(100, dc_tab(101))
	dc_session(200, dc_tab(201, "waiting"))
	dc_session(300, dc_tab(301))
	state.current_session = 100
	_ = ui_layout(1600, 900)
	dc_open()
	ui_do(core.Close_Session{session = 100})
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, deck_shown(), "closing another session leaves the deck")
	testing.expect_value(t, state.current_session, u64(0))
	dc_key(.ESCAPE)
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !deck.on, "Esc ends it")
	testing.expect_value(t, state.current_session, u64(0))
	// ⌥⌘A from the deck
	dc_open()
	dc_key(.A, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT))
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect_value(t, state.current_session, u64(200))
	testing.expect(t, !deck.on, "⌥⌘A ends the deck")
	// an agent's focus_session
	dc_open()
	_ = core.run_command(core.Focus_Session{session = 300}, core.Caller{kind = .Control})
	_ = ui_layout(1600, 900)
	testing.expect_value(t, state.current_session, u64(300))
	testing.expect(t, !deck.on, "a session shown by an agent ends the deck")
}

// show_no_session is the user's at this Mac: an agent may not send it.
@(test)
deck_modal_show_no_session_is_the_users :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dc_reset()
	defer dc_reset()
	dc_session(100, dc_tab(101))
	state.current_session = 100
	r := core.run_command(core.Show_No_Session{}, core.Caller{kind = .Control})
	testing.expect(t, !r.ok, "an agent's is refused")
	testing.expect_value(t, state.current_session, u64(100))
	r = core.run_command(core.Show_No_Session{}, core.Caller{kind = .UI})
	testing.expect(t, r.ok, "the user's applies")
	testing.expect_value(t, state.current_session, u64(0))
	testing.expect_value(t, len(state.open_sessions), 1)
}

// Peek (ui_peek.odin): opening the deck closes a peek; ⌃⌥⌘A peeks over the deck (the session it
// was opened from too: it is not on screen); Esc closes the peek and leaves the deck; Open goes
// there and the deck goes with it.
@(test)
deck_modal_peek :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	dc_reset()
	defer {
		peek_close()
		dc_term_free(201)
		free(core.terms[201], runtime.heap_allocator())
		delete_key(&core.terms, 201)
		dc_reset()
	}
	dc_session(100, dc_tab(101))
	dc_session(200, dc_tab(201, "waiting"))
	state.current_session = 100
	dc_term(201)
	core.terms[201] = new(core.Term, runtime.heap_allocator()) // the core has its terminal (has_term)
	unf := sapp.Event{type = .UNFOCUSED} // (a peek's held key from another test let go)
	event(&unf)
	app.window_active = true
	_ = ui_layout(1600, 900)
	testing.expect(t, peek_open_session(200), "the fixture peeks")
	dc_open()
	testing.expect(t, deck_shown(), "the deck opens")
	testing.expect(t, !peek_is_open(), "opening the deck closes the peek")
	dc_key(.A, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL))
	core.inbox_drain()
	testing.expect(t, peek_is_open(), "⌃⌥⌘A peeks over the deck")
	testing.expect(t, deck_shown(), "the deck stays under the peek")
	_ = ui_layout(1600, 900)
	dc_key(.ESCAPE)
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !peek_is_open(), "Esc closes the peek")
	testing.expect(t, deck_shown(), "the deck is still there after the peek")
	testing.expect(t, peek_open_session(200), "peeks again (a card's … Peek)")
	dc_key(.ENTER, u32(sapp.MODIFIER_SUPER))
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !peek_is_open(), "Open closes the peek")
	testing.expect_value(t, state.current_session, u64(200))
	testing.expect(t, !deck_shown() && !deck.on, "and the deck goes with it")
}
