package main

// Peek (ui_peek.odin): input goes to the peeked tab only (keys, Esc and Enter, an input method's
// text, the mouse), the peek's own ⌘ chords, any other closing it and going on, the keyboard's
// owner untouched; the entry points; what can and cannot be peeked; seen-marking; no resize of a
// tab laid out here (one never laid out gets the panel's grid once, another machine's never); it
// closes when its tab, session or machine goes; ⌥⌘A steps it; the panel's layout and hits down to
// the smallest window. Window copies (Term_View) with no core behind them: what a program would
// get is caught from term_view_input (term_view_input_hook).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
pk_sent: map[u64][dynamic]u8

@(private = "file")
pk_hook :: proc(v: ^Term_View, b: []u8) {
	if v.tab_id not_in pk_sent do pk_sent[v.tab_id] = make([dynamic]u8, runtime.heap_allocator())
	append(&pk_sent[v.tab_id], ..b)
}

// What tab's program got since the last call.
pk_take :: proc(tab: u64) -> string {
	buf, ok := &pk_sent[tab]
	if !ok do return ""
	s := strings.clone(string(buf[:]), context.temp_allocator)
	clear(buf)
	return s
}

@(private = "file")
pk_views: [dynamic]^Term_View
// stand-ins for the core's terminals (never started): the core's facts keep has_term from them
@(private = "file")
pk_terms: [dynamic]u64

// A window copy of tab's terminal, cols x rows, as a decoded one is set up.
pk_view :: proc(tab: u64, cols, rows: u16) -> ^Term_View {
	v := new(Term_View, runtime.heap_allocator())
	term_view_init(v)
	gh.terminal_new(nil, &v.gt, cols, rows)
	core.gt_setup(v.gt, core.term_colors())
	v.cols, v.rows, v.tab_id = cols, rows, tab
	v.snapshots = 1 // its first snapshot drew
	term_views[tab] = v
	append(&pk_views, v)
	term_view_input_hook = pk_hook
	return v
}

pk_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	peek = {}
	peek_moving = false
	away := sapp.Event{type = .UNFOCUSED} // no button down, no key held from another test
	_ = peek_event(&away)
	for v in pk_views {
		delete_key(&term_views, v.tab_id)
		term_view_free(v)
		free(v)
	}
	clear(&pk_views)
	for id in pk_terms {
		if t := core.terms[id]; t != nil do free(t)
		delete_key(&core.terms, id)
	}
	clear(&pk_terms)
	for _, b in pk_sent do delete(b)
	clear(&pk_sent)
	clear(&term_fits)
	term_view_input_hook = nil
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	win_os = {set_clipboard = proc(s: string) {}, get_clipboard = proc() -> string {return "pasted"}}
	append(&state.projects, core.Project{id = 1, group = .Projects, cwd = strings.clone("/tmp/pk-proj"), label = strings.clone("web")})
	state.selected_project = 1
	ui_hover = nil
	attention_idle_open, attention_sel, attention_keyed = false, 0, false
	tf_set(&filter_field, "")
	state.settings.reduce_motion = true
	menu = {}
	toast_clear()
}

// A tab: shell (or "browser", "editor"), "" idle or "waiting", "unseen", "error", "working".
pk_tab :: proc(id: u64, need := "", ago: time.Duration = 0, kind := "shell", has_term := true) -> core.Tab {
	t := core.Tab{id = id, title = strings.clone(fmt.tprintf("tab %d", id), runtime.heap_allocator()), status = .Running, has_term = has_term}
	switch kind {
	case "editor":  t.kind, t.has_term = core.Editor_Tab{path = "/tmp/pk-proj/a.txt"}, false
	case "browser": t.kind, t.has_term = core.Browser_Tab{url = "about:blank"}, false
	case:           t.kind = core.Shell_Tab{}
	}
	t.prog.progress = -1
	switch need {
	case "waiting": t.prog.state, t.prog.kind = .Blocked, .Permission
	case "error":   t.prog.state = .Error
	case "unseen":  t.unseen = true
	case "working": t.prog.state = .Working
	}
	t.status_key = core.status_key(core.tab_status_view(t))
	if ago > 0 do t.status_since = time.time_add(time.now(), -ago)
	return t
}

pk_session :: proc(id: u64, title: string, tabs: ..core.Tab) {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("pk%d", id)), cwd = strings.clone("/tmp/pk-proj"), title = strings.clone(title), shown_at = i64(id)}
	for t in tabs {
		append(&s.tabs, t)
		if t.has_term && t.id not_in core.terms {
			core.terms[t.id] = new(core.Term)
			append(&pk_terms, t.id)
		}
	}
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
}

pk_key :: proc(k: sapp.Keycode, mods: u32 = 0, ch: rune = 0) {
	e := sapp.Event{type = .KEY_DOWN, key_code = k, modifiers = mods}
	event(&e)
	if ch != 0 {
		c := sapp.Event{type = .CHAR, char_code = u32(ch), modifiers = mods}
		event(&c)
	}
	e.type = .KEY_UP
	event(&e)
}

pk_mouse :: proc(type: sapp.Event_Type, x, y: f32, button := sapp.Mousebutton.LEFT) {
	e := sapp.Event{type = type, mouse_button = button, mouse_x = x, mouse_y = y}
	event(&e)
}

// A frame's layout and the peek's placing after it (frame()).
@(private = "file")
pk_layout :: proc(w: f32 = 1400, h: f32 = 860) -> clay.ClayArray(clay.RenderCommand) {
	cmds := ui_layout(w, h)
	peek_after_layout()
	return cmds
}

@(private = "file")
pk_box :: proc(name: string, i: u32 = 0) -> (clay.BoundingBox, bool) {
	d := clay.GetElementData(clay.ID(name, i))
	return d.boundingBox, d.found
}

@(private = "file")
pk_centre :: proc(b: clay.BoundingBox) -> [2]f32 {return {b.x + b.width / 2, b.y + b.height / 2}}

// Nothing ever reaches the peeked terminal, nor the one under it: keys (Enter, ⌘← too), an input
// method's text and composition, a paste, the mouse and the wheel. Keys and clicks are the bell
// popover's (popover_event): Esc closes; other keys do nothing; a ⌘ chord not its own closes it and
// goes on (⌘K: the palette); ⌘W and the menu bar's Close tab close the peek, never the tab under
// it; a click in the panel keeps it, on the scrim closes it; ⌘↩ and Open open it as the session's
// tab. Space after an input method typed into the Attention filter is a space.
@(test)
peek_sends_nothing_to_its_terminal :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101), pk_tab(102))
	pk_session(200, "There", pk_tab(201, "waiting", 3 * time.Minute))
	state.current_session = 100
	a := pk_view(101, 80, 24)
	b := pk_view(201, 80, 24)
	vt := "\x1b[?1003h\x1b[?1006h" // the programs track the mouse (any motion, SGR)
	gh.terminal_vt_write(a.gt, raw_data(vt), len(vt))
	gh.terminal_vt_write(b.gt, raw_data(vt), len(vt))
	// the Attention view's field had the keyboard: ↓ picks the waiting row, Space peeks at it
	state.sidebar.view = .Attention
	state.layout.left_tab = .Sessions
	filter_focus()
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	pk_key(.DOWN)
	testing.expect_value(t, attention_sel, u64(200))
	pk_key(.SPACE, 0, ' ')
	testing.expect(t, peek_is_open() && peek.tab == 201, "Space peeks at the keyboard's row")
	testing.expect_value(t, tf_text(&filter_field), "") // its CHAR went nowhere
	_ = pk_layout()
	testing.expect(t, peek.area.z > 0, "laid out")

	nothing :: proc(t: ^testing.T, what: string) {
		testing.expectf(t, pk_take(201) == "", "%s: nothing to the peeked terminal", what)
		testing.expectf(t, pk_take(101) == "", "%s: nothing to the terminal under it", what)
		testing.expectf(t, tf_text(&filter_field) == "", "%s: nothing into the field", what)
		testing.expectf(t, peek_is_open(), "%s: still peeking", what)
	}
	pk_key(.X, 0, 'x')
	nothing(t, "a key")
	pk_key(.ENTER, 0, '\r')
	nothing(t, "Enter")
	pk_key(.LEFT, sapp.MODIFIER_CTRL)
	nothing(t, "⌃←")
	ime_set_marked("に", 1)
	testing.expect_value(t, ime.marked, "") // no composition: not in the field under it either
	ime_commit("に")
	nothing(t, "an input method's text")
	paste := sapp.Event{type = .CLIPBOARD_PASTED}
	testing.expect(t, peek_event(&paste), "a paste is taken (nowhere)")
	event(&paste)
	nothing(t, "a paste")
	at := pk_centre({peek.area.x, peek.area.y, peek.area.z, peek.area.w})
	pk_mouse(.MOUSE_MOVE, at.x, at.y)
	pk_mouse(.MOUSE_DOWN, at.x, at.y)
	pk_mouse(.MOUSE_MOVE, at.x + 30, at.y + 30)
	pk_mouse(.MOUSE_UP, at.x + 30, at.y + 30)
	wheel := sapp.Event{type = .MOUSE_SCROLL, mouse_x = at.x, mouse_y = at.y, scroll_y = -3}
	event(&wheel)
	nothing(t, "the mouse and the wheel")
	testing.expect(t, !a.mouse_down && !b.mouse_down, "no press anywhere")
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	// a click on the panel's header (not a button) keeps it
	head, _ := pk_box("peek_title")
	pk_mouse(.MOUSE_DOWN, head.x + 2, head.y + head.height / 2)
	pk_mouse(.MOUSE_UP, head.x + 2, head.y + head.height / 2)
	nothing(t, "a click in the panel")

	// Esc: closes (the bell popover's), the field has the keyboard as before
	pk_key(.ESCAPE)
	testing.expect(t, !peek_is_open(), "Esc closes the peek")
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, pk_take(201), "")

	// typed in the field (by an input method too): Space is a space again
	pk_key(.DOWN)
	testing.expect(t, attention_keyed, "picked with ↓")
	ime_commit("ü")
	testing.expect(t, !attention_keyed, "typed in by an input method")
	pk_key(.SPACE, 0, ' ')
	testing.expect(t, !peek_is_open(), "no peek once the field was typed in")
	testing.expect_value(t, tf_text(&filter_field), "ü ")
	tf_set(&filter_field, "")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()

	// ⌘W: the peek closes, not the tab under it
	testing.expect(t, peek_open_session(200), "peeks")
	pk_key(.W, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "⌘W closes the peek")
	testing.expect_value(t, len(find_session(100).tabs), 2)
	testing.expect_value(t, len(state.pending_confirmations), 0)

	// the scrim: closes, nothing else
	testing.expect(t, peek_open_session(200), "peeks")
	_ = pk_layout()
	pk_mouse(.MOUSE_DOWN, 3, 857)
	pk_mouse(.MOUSE_UP, 3, 857)
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "a click on the scrim closes it")
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect(t, !a.mouse_down && !b.mouse_down, "no press anywhere")

	// another ⌘ chord: the peek closes and the chord does what it does (⌘K: the palette)
	testing.expect(t, peek_open_session(200), "peeks")
	pk_key(.K, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "⌘K closes the peek")
	testing.expect_value(t, state.focus_widget, "palette")
	// opened from the palette (⌃⌥⌘A as it runs it): the palette closes
	action_run("peek_next_needing_you")
	core.inbox_drain()
	testing.expect(t, peek_is_open() && state.focus_widget == "", "peeking, the palette closed")

	// a menu bar item clicked while peeking: Close tab closes the peek, never the tab under it
	action_run("close_tab")
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "Close tab closes the peek")
	testing.expect_value(t, len(find_session(100).tabs), 2)

	// Close and Open, the header's buttons
	testing.expect(t, peek_open_session(200), "peeks")
	_ = pk_layout()
	cb, _ := pk_box("peek_close")
	pk_mouse(.MOUSE_DOWN, pk_centre(cb).x, pk_centre(cb).y)
	pk_mouse(.MOUSE_UP, pk_centre(cb).x, pk_centre(cb).y)
	testing.expect(t, !peek_is_open(), "Close closes it")
	testing.expect(t, peek_open_session(200), "peeks")
	_ = pk_layout()
	ob, _ := pk_box("peek_open")
	pk_mouse(.MOUSE_DOWN, pk_centre(ob).x, pk_centre(ob).y)
	pk_mouse(.MOUSE_UP, pk_centre(ob).x, pk_centre(ob).y)
	core.inbox_drain()
	testing.expect(t, !peek_is_open() && state.current_session == 200, "Open: the tab on screen")
	state.current_session = 100

	// ⌘↩: the peeked tab becomes the tab on screen
	testing.expect(t, peek_open_session(200), "peeks")
	pk_key(.ENTER, sapp.MODIFIER_SUPER)
	testing.expect(t, !peek_is_open(), "⌘↩ closes the peek")
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(200))
	testing.expect_value(t, pk_take(201), "")
	testing.expect_value(t, pk_take(101), "")
}

// Entry points: the session row's menu, the eyes of the Attention view's, the empty centre's and
// the bell's rows (shown on hover, only where a tab can be peeked, hit where drawn), the action
// (Window menu, palette, ⌃⌥⌘A); and what can be peeked: not the session on screen, not a page or
// an editor, not a tab without a terminal, another machine's only while it is online.
@(test)
peek_entry_points_and_what_can_be_peeked :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101, "waiting", time.Minute))
	pk_session(200, "There", pk_tab(201, "waiting", 9 * time.Minute))
	pk_session(300, "Page", pk_tab(301), pk_tab(302, "unseen", time.Minute, kind = "editor"))
	pk_session(400, "Gone", pk_tab(401, "waiting", 2 * time.Minute, has_term = false))
	state.current_session = 100
	testing.expect(t, peek_tab_of(find_session(100)) == nil, "not the session on screen")
	tab := peek_tab_of(find_session(200))
	testing.expect(t, tab != nil && tab.id == 201, "a waiting shell")
	testing.expect(t, peek_tab_of(find_session(300)) == nil, "not an editor (its row's tab)")
	testing.expect(t, peek_tab_of(find_session(400)) == nil, "not a tab without a terminal")

	// other machines: online, yes (relayed on demand, no new command); offline, no
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	state.machines[1] = {no = 4, name = "studio", status = .Offline}
	mirror :: proc(no: u64, r: ^core.State, m: ^core.Machine_Mirror) {
		s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/api"), title = strings.clone("Remote")}
		append(&s.tabs, pk_tab(10, "waiting", 4 * time.Minute))
		s.active_tab = 10
		append(&r.open_sessions, s)
		core.mirror_merge(no, r, m)
	}
	r3, r4: core.State
	m3, m4: core.Machine_Mirror
	mirror(3, &r3, &m3)
	mirror(4, &r4, &m4)
	defer {
		core.mirror_unmerge(3)
		core.mirror_unmerge(4)
		core.mirror_free(&m3)
		core.mirror_free(&m4)
		core.replica_free(&r3, runtime.heap_allocator())
		core.replica_free(&r4, runtime.heap_allocator())
	}
	on3, on4: ^core.Open_Session
	for &s in state.open_sessions do if s.machine == 3 do on3 = &s
	for &s in state.open_sessions do if s.machine == 4 do on4 = &s
	testing.expect(t, on3 != nil && peek_tab_of(on3) != nil, "an online machine's terminal tab")
	testing.expect(t, on4 != nil && peek_tab_of(on4) == nil, "not an offline machine's")

	// the row's menu: Peek where it can, not elsewhere
	has_peek :: proc(sid: u64) -> bool {
		s := find_session(sid)
		menu_open(Menu_Session{project_id = s.project_id, pi_session_id = s.pi_session_id}, {})
		defer menu_close()
		for it in menu_items() do if it.label == "Peek" do return it.peek == sid
		return false
	}
	testing.expect(t, has_peek(200), "Peek in its menu")
	testing.expect(t, !has_peek(300), "no Peek for an editor's row")
	testing.expect(t, !has_peek(100), "no Peek for the session on screen")
	s200 := find_session(200)
	menu_open(Menu_Session{project_id = 1, pi_session_id = s200.pi_session_id}, {})
	for it, i in menu_items() do if it.label == "Peek" do menu_run(i)
	testing.expect(t, peek_is_open() && peek.tab == 201 && !menu.open, "the menu's Peek")
	peek_close()

	// the Attention view's rows: an eye on hover where it can peek, hit where it is drawn
	state.sidebar.view = .Attention
	state.layout.left_tab = .Sessions
	row_of :: proc(sid: u64) -> u32 {
		for id, i in drawn.open do if id == sid do return u32(i)
		return 999
	}
	_ = ui_layout(1600, 900)
	k := row_of(200)
	ui_hover = Hit_Open_Row(200)
	_ = ui_layout(1600, 900)
	eye, found := pk_box("openpeek", k)
	testing.expect(t, found && eye.width > 0, "an eye on the hovered row")
	clay.SetPointerState(pk_centre(eye), false)
	testing.expect_value(t, ui_hit(), Hit(Hit_Peek_Row(200)))
	ui_hover = Hit_Open_Row(300)
	_ = ui_layout(1600, 900)
	_, found = pk_box("openpeek", row_of(300))
	testing.expect(t, !found, "no eye on an editor's row")
	// another machine's row: an eye too (no menu, but Peek)
	ui_hover = Hit_Open_Row(on3.id)
	_ = ui_layout(1600, 900)
	eye, found = pk_box("openpeek", row_of(on3.id))
	testing.expect(t, found && eye.width > 0, "an eye on an online machine's row")
	ui_hover = nil
	e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = pk_centre(eye).x, mouse_y = pk_centre(eye).y}
	_ = ui_layout(1600, 900)
	ui_hover = Hit_Open_Row(on3.id)
	_ = ui_layout(1600, 900)
	event(&e)
	testing.expect(t, peek_is_open() && peek.session == on3.id, "the eye's click peeks at another machine's tab")
	e.type = .MOUSE_UP
	event(&e)
	pk_key(.ESCAPE)
	testing.expect(t, !peek_is_open(), "closed")
	ui_hover = nil

	// the empty centre's list: no session on screen
	state.current_session = 0
	state.sidebar.view = .Projects
	ui_hover = Hit_Fleet_Row(200)
	_ = ui_layout(1600, 900)
	fk := -1
	for i in 0 ..< FLEET_ROWS do if d, ok := pk_box("fleetrow", u32(i)); ok && d.width > 0 {
		clay.SetPointerState(pk_centre(d), false)
		if h, is := ui_hit().(Hit_Fleet_Row); is && u64(h) == 200 do fk = i
	}
	testing.expect(t, fk >= 0, "the centre lists it")
	if fk >= 0 {
		ui_hover = Hit_Fleet_Row(200)
		_ = ui_layout(1600, 900)
		eye, found = pk_box("fleetpeek", u32(fk))
		testing.expect(t, found && eye.width > 0, "an eye on the centre's hovered row")
		clay.SetPointerState(pk_centre(eye), false)
		testing.expect_value(t, ui_hit(), Hit(Hit_Peek_Row(200)))
	}
	ui_hover = nil
	state.current_session = 100

	// the bell: an entry about a tab that can be peeked has an eye; its click peeks, reads it and closes the popover
	append(&state.notices.items, core.Notice{id = 77, kind = .Waiting, session = 200, tab_id = 201, title = strings.clone("There"), at = time.now()})
	state.focus_widget = "notifications"
	_ = ui_layout(1600, 900)
	ui_hover = Hit_Bell{what = .Row, id = 77}
	_ = ui_layout(1600, 900)
	eye, found = pk_box("bellpeek", 0)
	testing.expect(t, found && eye.width > 0, "an eye on the hovered entry")
	if found {
		be := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = pk_centre(eye).x, mouse_y = pk_centre(eye).y}
			event(&be)
		be.type = .MOUSE_UP
		event(&be)
		core.inbox_drain()
		testing.expect(t, peek_is_open() && peek.tab == 201, "its click peeks")
		testing.expect_value(t, state.focus_widget, "")
		testing.expect(t, state.notices.items[0].read, "and reads it")
	}
	peek_close()
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "") // the popover does not open again
	ui_hover = nil

	// the action: the Window menu's, the palette's, ⌃⌥⌘A
	a := action_by_id("peek_next_needing_you")
	testing.expect(t, a != nil && a.keys == "⌃⌥⌘A" && !a.no_palette, "the action, in the palette, ⌃⌥⌘A")
	testing.expect_value(t, menubar_key_action(.A, sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER), "peek_next_needing_you")
	in_window := false
	for it in menubar_items() do if it.action == "peek_next_needing_you" do in_window = true
	testing.expect(t, in_window, "in the menu bar")
	pk_key(.A, sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect(t, peek_is_open() && peek.tab == 201, "⌃⌥⌘A peeks where ⌥⌘A would go")
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(100))
}

// ⌥⌘A while peeking steps the peek (never the session on screen) through what needs you that can
// be peeked, round; ⇧⌥⌘A goes back; Next needing you clicked in the menu bar does the same.
@(test)
peek_steps_with_next_needing_you :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101, "waiting", 20 * time.Minute))
	pk_session(200, "Longest", pk_tab(201, "waiting", 9 * time.Minute))
	pk_session(300, "Page", pk_tab(301, "waiting", 5 * time.Minute, kind = "browser"))
	pk_session(400, "Shorter", pk_tab(401, "waiting", 3 * time.Minute))
	pk_session(500, "Done", pk_tab(501, "unseen", time.Minute))
	_ = pk_view(501, 80, 24)
	state.current_session = 100
	peek_next()
	testing.expect_value(t, peek.tab, u64(201))
	pk_key(.A, sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect_value(t, peek.tab, u64(401)) // the page's session is passed over
	pk_key(.A, sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect_value(t, peek.tab, u64(501))
	peek_tick() // (a frame: it has shown)
	core.inbox_drain()
	_, t5, _ := find_tab(501)
	testing.expect(t, !t5.unseen, "finished, seen once peeked: it needs nothing now")
	pk_key(.A, sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect_value(t, peek.tab, u64(201)) // round, never the session on screen
	pk_key(.A, sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT | sapp.MODIFIER_SUPER)
	testing.expect_value(t, peek.tab, u64(401))
	action_run("next_needing_you") // the Window menu's item, clicked
	core.inbox_drain()
	testing.expect_value(t, peek.tab, u64(201))
	testing.expect_value(t, state.current_session, u64(100))
	for id in ([]u64{101, 201, 301, 401, 501}) do testing.expect_value(t, pk_take(id), "")
	// nothing else: it stays, and says so
	peek_close()
	clear(&state.open_sessions)
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "Only", pk_tab(201, "waiting", time.Minute))
	peek_next()
	testing.expect_value(t, peek.tab, u64(201))
	peek_next()
	testing.expect_value(t, peek.tab, u64(201))
	testing.expect(t, strings.contains(toast.text, "Nothing else"), toast.text)
}

// Seen: a tab that finished unseen is seen once peeked (and its bell entry read), again if it
// finishes while peeked; a waiting one stays waiting. Sizes: a tab laid out here is never resized
// (its grid drawn 1:1 from the area's top-left, the bottom rows in view when it is taller); one
// never laid out gets the panel's grid once; another machine's never.
@(test)
peek_seen_and_sizes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "Finished", pk_tab(201, "unseen", time.Minute))
	pk_session(300, "Waiting", pk_tab(301, "waiting", time.Minute))
	state.current_session = 100
	append(&state.notices.items, core.Notice{id = 5, kind = .Finished, session = 200, tab_id = 201, title = strings.clone("Finished"), at = time.now()})
	_ = pk_view(201, 80, 24)
	testing.expect(t, peek_open_session(200), "peeks")
	peek_tick() // (a frame: it has shown)
	core.inbox_drain()
	_, t2, _ := find_tab(201)
	testing.expect(t, !t2.unseen, "seen once peeked")
	testing.expect(t, state.notices.items[0].read, "its entry read")
	t2.unseen = true // finished again while peeked
	peek.seen_at = {}
	peek_tick()
	core.inbox_drain()
	_, t2, _ = find_tab(201)
	testing.expect(t, !t2.unseen, "seen again")
	// a bell entry it rings while peeked is read, as for a session on screen
	append(&state.notices.items, core.Notice{id = 6, kind = .Waiting, session = 200, tab_id = 201, title = strings.clone("Finished"), at = time.now()})
	peek.seen_at = {}
	peek_tick()
	core.inbox_drain()
	testing.expect(t, state.notices.items[1].read, "a new entry read while peeked")
	peek_close()
	testing.expect(t, peek_open_session(300), "peeks")
	core.inbox_drain()
	_, t3, _ := find_tab(301)
	testing.expect_value(t, core.tab_need(t3^), core.NEED_WAITING)
	peek_close()

	// laid out here at 120 x 40: never resized, drawn 1:1, its bottom rows in view
	v := pk_view(301, 120, 40)
	term_fits[301] = {cols = 120, rows = 40, cell = {font.cell_w, font.cell_h}}
	testing.expect(t, peek_open_session(300), "peeks")
	for _ in 0 ..< 2 do _ = pk_layout(1400, 700)
	testing.expect_value(t, term_fits[301].cols, u16(120))
	testing.expect_value(t, term_fits[301].rows, u16(40))
	a := peek.area
	testing.expect(t, a.z > 0, "laid out")
	testing.expect(t, v.x == a.x && v.x == f32(i32(v.x)) && v.y == f32(i32(v.y)), "on whole pixels at the area's left")
	gh_ := f32(v.rows) * font.cell_h + 2 * term_pad()
	if gh_ > a.w do testing.expectf(t, v.y + gh_ >= a.y + a.w - 1 && v.y + gh_ <= a.y + a.w + 1, "its bottom at the area's bottom: %v + %v vs %v", v.y, gh_, a)
	else do testing.expect_value(t, v.y, a.y)
	box, _ := pk_box("peek_box")
	testing.expect(t, box.width >= f32(v.cols) * font.cell_w || box.x <= px(PEEK_MARGIN) + 1 || box.width >= 1400 * PEEK_FRAC, "grown to its grid where it can")
	peek_close()

	// never laid out here: the panel's grid, once
	pk_session(400, "Fresh", pk_tab(401, "waiting", time.Minute))
	_ = pk_view(401, 80, 24)
	testing.expect(t, peek_open_session(400), "peeks")
	_ = pk_layout(1400, 860)
	f, had := term_fits[401]
	testing.expect(t, had, "given a size")
	cols, rows := term_grid_fit(peek.area.z, peek.area.w)
	testing.expect(t, f.cols == cols && f.rows == rows, "the panel's grid")
	_ = pk_layout(1600, 900) // the window grows: no second resize
	testing.expect(t, term_fits[401].cols == cols && term_fits[401].rows == rows, "once")
	peek_close()

	// another machine's: never
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	r3: core.State
	m3: core.Machine_Mirror
	rs := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/api"), title = strings.clone("Remote")}
	append(&rs.tabs, pk_tab(10, "waiting", 4 * time.Minute))
	rs.active_tab = 10
	append(&r3.open_sessions, rs)
	core.mirror_merge(3, &r3, &m3)
	defer {
		core.mirror_unmerge(3)
		core.mirror_free(&m3)
		core.replica_free(&r3, runtime.heap_allocator())
	}
	rsess: ^core.Open_Session
	for &s in state.open_sessions do if s.machine == 3 do rsess = &s
	if !testing.expect(t, rsess != nil, "mirrored") do return
	rtab := rsess.tabs[0].id
	_ = pk_view(rtab, 80, 24)
	// the bell entry its mirror rang here is read when it is peeked (not this Mac's with the same tab id)
	clear(&state.notices.items)
	append(&state.notices.items, core.Notice{id = 90, kind = .Waiting, session = rsess.id, tab_id = rtab, machine = 3, title = strings.clone("Remote"), at = time.now()})
	append(&state.notices.items, core.Notice{id = 91, kind = .Waiting, session = rsess.id, tab_id = rtab, machine = 4, title = strings.clone("Other"), at = time.now()})
	testing.expect(t, peek_open_session(rsess.id), "peeks at another machine's tab")
	peek_tick()
	core.inbox_drain()
	testing.expect(t, state.notices.items[0].read, "another machine's entry read")
	testing.expect(t, !state.notices.items[1].read, "not another machine's with the same ids")
	_ = pk_layout(1400, 860)
	_, had = term_fits[rtab]
	testing.expect(t, !had, "another machine's tab is not resized")
}

// It closes when its tab, its session or its machine goes, when its session comes on screen, and
// under a sheet that takes all input.
@(test)
peek_closes_when_its_tab_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "There", pk_tab(201, "waiting", time.Minute), pk_tab(202, "waiting", 2 * time.Minute))
	state.current_session = 100
	open :: proc() -> bool {return peek_open_tab(find_session(200), &find_session(200).tabs[1])}
	// its tab closes
	testing.expect(t, open(), "peeks")
	s := find_session(200)
	ordered_remove(&s.tabs, 1)
	peek_tick()
	testing.expect(t, !peek_is_open(), "its tab closed")
	append(&s.tabs, pk_tab(202, "waiting", time.Minute))
	// its session closes
	testing.expect(t, open(), "peeks")
	for x, i in state.open_sessions do if x.id == 200 {
		ordered_remove(&state.open_sessions, i)
		break
	}
	key := sapp.Event{type = .KEY_DOWN, key_code = .X}
	event(&key) // before the frame: closed first (the key meant for it goes nowhere)
	testing.expect(t, !peek_is_open(), "its session closed")
	pk_session(200, "There", pk_tab(201, "waiting", time.Minute), pk_tab(202, "waiting", 2 * time.Minute))
	// its session comes on screen
	testing.expect(t, open(), "peeks")
	state.current_session = 200
	peek_tick()
	testing.expect(t, !peek_is_open(), "its session is on screen")
	state.current_session = 100
	// its terminal goes
	testing.expect(t, open(), "peeks")
	find_session(200).tabs[1].has_term = false // (the core's facts: its terminal went)
	peek_tick()
	testing.expect(t, !peek_is_open(), "its terminal went")
	find_session(200).tabs[1].has_term = true
	// the job sheet opens
	testing.expect(t, open(), "peeks")
	job_sheet.open = true
	peek_tick()
	job_sheet.open = false
	testing.expect(t, !peek_is_open(), "under the job sheet")

	// another machine goes offline
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	r3: core.State
	m3: core.Machine_Mirror
	rs := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/api"), title = strings.clone("Remote")}
	append(&rs.tabs, pk_tab(10, "waiting", 4 * time.Minute))
	rs.active_tab = 10
	append(&r3.open_sessions, rs)
	core.mirror_merge(3, &r3, &m3)
	defer {
		core.mirror_unmerge(3)
		core.mirror_free(&m3)
		core.replica_free(&r3, runtime.heap_allocator())
	}
	rsid: u64
	for x in state.open_sessions do if x.machine == 3 do rsid = x.id
	testing.expect(t, peek_open_session(rsid), "peeks at another machine's")
	state.machines[0].status = .Offline
	peek_tick()
	testing.expect(t, !peek_is_open(), "its machine went offline")
}

// The panel at every audited width and down to the smallest window, columns on and off: inside the
// window (and the centre while it has room), its header's text and buttons clear of each other and
// inside it, the terminal's area below the header, on whole pixels; the buttons hit where drawn.
@(test)
peek_panel_layout_and_hits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "A session title long enough to be clipped in a narrow panel header", pk_tab(201, "waiting", 3 * time.Minute)) // waiting: "Open to answer"
	state.current_session = 100
	_ = pk_view(201, 80, 24)
	problems := 0
	for cols in ([][2]bool{{true, true}, {false, false}, {true, false}}) {
		state.layout.left_open, state.layout.right_open = cols[0], cols[1]
		for w in ([]f32{WINDOW_MIN_W, 1280, 2000}) {
			for h in ([]f32{WINDOW_MIN_H, AUDIT_H}) {
				clear(&term_fits)
				term_fits[201] = {cols = 80, rows = 24, cell = {font.cell_w, font.cell_h}}
				peek_close()
				testing.expect(t, peek_open_session(200), "peeks")
				_ = pk_layout(w, h)
				cmds := pk_layout(w, h)
				where_ := fmt.tprintf("peek w=%v h=%v cols=%v", w, h, cols)
				box, ok := pk_box("peek_box")
				if !testing.expectf(t, ok, "%s: no panel", where_) do continue
				in_win := box.x >= 0 && box.y >= 0 && box.x + box.width <= w && box.y + box.height <= h
				testing.expectf(t, in_win, "%s: the panel %v leaves the window", where_, box)
				testing.expectf(t, box.x == f32(i32(box.x)) && box.y == f32(i32(box.y)), "%s: the panel on whole pixels %v", where_, box)
				if c, cok := pk_box("centre"); cok && c.width >= px(PEEK_MIN_W + 2 * PEEK_MARGIN) && c.height >= px(PEEK_MIN_H + 2 * PEEK_MARGIN) {
					testing.expectf(t, box.x >= c.x && box.x + box.width <= c.x + c.width && box.y >= c.y && box.y + box.height <= c.y + c.height, "%s: the panel %v leaves the centre %v", where_, box, c)
				}
				for b in audit(cmds, where_, w, within = "peek_box", layer = PEEK_Z_BOX, own = []string{"peek_head", "peek_title", "peek_open", "peek_close", "peek_note"}) {
					problems += 1
					if problems <= 20 do testing.expectf(t, false, "%s", b)
				}
				head, nok := pk_box("peek_note") // under the header while it waits
				testing.expectf(t, nok && head.height > 0, "%s: Open to answer", where_)
				a := peek.area
				testing.expectf(t, a.z > 0 && a.w > 0 && a.y >= head.y + head.height - 0.5 && a.x >= box.x && a.x + a.z <= box.x + box.width && a.y + a.w <= box.y + box.height, "%s: the terminal's area %v in the panel %v under its header", where_, a, box)
				for name, want in ([2]string{"peek_open", "peek_close"}) {
					d, dok := pk_box(name)
					if !testing.expectf(t, dok && d.width > 0, "%s: %s", where_, name) do continue
					testing.expectf(t, d.x >= box.x && d.x + d.width <= box.x + box.width, "%s: %s inside the panel", where_, name)
					clay.SetPointerState(pk_centre(d), false)
					testing.expectf(t, ui_hit() == Hit(Hit_Peek(want == 0 ? .Open : .Close)), "%s: %s hit where drawn", where_, name)
				}
				// nothing under the scrim is hit through the terminal's area
				mid := pk_centre({a.x, a.y, a.z, a.w})
				clay.SetPointerState(mid, false)
				testing.expectf(t, ui_hit() == nil, "%s: nothing under the scrim is hit", where_)
			}
		}
	}
	testing.expectf(t, problems == 0, "%d layout problems", problems)
	state.layout.left_open, state.layout.right_open = true, false
}

// The review's five: an input method's composition is dropped in the platform too while peeking,
// and when a peek opens and closes; holding the peek's own ⌘W or Esc does not repeat into what is
// under it once it closed (a new press does); a peek does not open while a mouse button is down
// (its release would be lost); a key that arrives as its tab goes (closed before it) goes nowhere;
// seen only once its terminal has shown.
@(test)
peek_edges :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101), pk_tab(102))
	pk_session(200, "There", pk_tab(201, "unseen", 3 * time.Minute))
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	b := pk_view(201, 80, 24)
	key :: proc(k: sapp.Keycode, mods: u32 = 0, repeat := false, up := false) {
		e := sapp.Event{type = up ? .KEY_UP : .KEY_DOWN, key_code = k, modifiers = mods, key_repeat = repeat}
		event(&e)
	}

	// 5. seen only once its terminal has shown (a snapshot drew)
	append(&state.notices.items, core.Notice{id = 7, kind = .Finished, session = 200, tab_id = 201, title = strings.clone("There"), at = time.now()})
	b.snapshots = 0
	testing.expect(t, peek_open_session(200), "peeks")
	peek_tick()
	core.inbox_drain()
	_, t2, _ := find_tab(201)
	testing.expect(t, t2.unseen && !state.notices.items[0].read, "not seen before it showed")
	b.snapshots = 1
	peek_tick()
	core.inbox_drain()
	_, t2, _ = find_tab(201)
	testing.expect(t, !t2.unseen && state.notices.items[0].read, "seen once it showed")

	// 1. a composition while peeking is dropped in the platform too; opening and closing drop one
	n := ime.os_cancels
	ime_set_marked("か", 1)
	testing.expect_value(t, ime.marked, "")
	testing.expect(t, ime.os_cancels > n, "dropped in the platform's input method too")
	n = ime.os_cancels
	peek_close()
	testing.expect(t, ime.os_cancels > n, "closing drops a composition")
	n = ime.os_cancels
	testing.expect(t, peek_open_session(200), "peeks")
	testing.expect(t, ime.os_cancels > n, "opening drops a composition")

	// 2. ⌘W held: the first closes the peek, its repeats close nothing under it
	key(.W, sapp.MODIFIER_SUPER)
	testing.expect(t, !peek_is_open(), "⌘W closed it")
	for _ in 0 ..< 3 do key(.W, sapp.MODIFIER_SUPER, repeat = true)
	key(.W, sapp.MODIFIER_SUPER, up = true)
	core.inbox_drain()
	testing.expect_value(t, len(find_session(100).tabs), 2)
	testing.expect_value(t, len(state.pending_confirmations), 0)
	// Esc held: closes it, its repeats do not reach the terminal under it; pressed again, they do
	testing.expect(t, peek_open_session(200), "peeks")
	_ = pk_take(101)
	key(.ESCAPE)
	testing.expect(t, !peek_is_open(), "Esc closed it")
	for _ in 0 ..< 3 do key(.ESCAPE, repeat = true)
	key(.ESCAPE, up = true)
	testing.expect_value(t, pk_take(101), "")
	key(.ESCAPE)
	testing.expect_value(t, pk_take(101), "\x1b")
	key(.ESCAPE, up = true)

	// 3. a button down (a divider or a program's drag): ⌃⌥⌘A does nothing until it is up
	w := &find_session(200).tabs[0] // it waits for you now: ⌃⌥⌘A peeks at it
	w.prog.state, w.prog.kind = .Blocked, .Permission
	w.status_key = core.status_key(core.tab_status_view(w^))
	press := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = 5, mouse_y = 5}
	event(&press)
	key(.A, sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect(t, !peek_is_open(), "no peek while a button is down")
	press.type = .MOUSE_UP
	event(&press)
	key(.A, sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect(t, peek_is_open(), "after the release it peeks")

	// 4. a key that arrives as its tab goes (its state update came first): nowhere
	_ = pk_take(101)
	find_session(200).tabs[0].has_term = false // its terminal went
	key(.ESCAPE)
	testing.expect(t, !peek_is_open(), "closed")
	testing.expect_value(t, pk_take(101), "")
	find_session(200).tabs[0].has_term = true
	testing.expect(t, peek_open_session(200), "peeks")
	find_session(200).tabs[0].has_term = false
	key(.W, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "closed")
	testing.expect_value(t, len(find_session(100).tabs), 2)
	testing.expect_value(t, len(state.pending_confirmations), 0)
	find_session(200).tabs[0].has_term = true
}
