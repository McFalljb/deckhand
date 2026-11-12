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
	term_views[tab] = v
	append(&pk_views, v)
	term_view_input_hook = pk_hook
	return v
}

pk_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	peek = {}
	peek_moving = false
	cover_reset()
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

// A key typed at a person's pace (after a cover's quiet gate: cover_wait).
pk_key :: proc(k: sapp.Keycode, mods: u32 = 0, ch: rune = 0) {
	cover_wait(COVER_QUIET)
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
	if type == .MOUSE_DOWN do cover_wait(COVER_QUIET)
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

// Keys, Esc and Enter, an input method's text, the mouse: the peeked tab's alone; the field that
// had the keyboard keeps it and gets nothing; ⌘W closes (never the tab under it), ⌘↩ opens it as
// the session's tab; a ⌘ chord that is not the peek's closes it and does what it does; the scrim
// closes it and nothing else.
@(test)
peek_input_goes_to_the_peeked_tab_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "There", pk_tab(201, "waiting", 3 * time.Minute))
	state.current_session = 100
	a := pk_view(101, 80, 24)
	b := pk_view(201, 80, 24)
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
	testing.expect_value(t, pk_take(201), "")
	_ = pk_layout()
	testing.expect(t, peek.area.z > 0, "laid out")

	pk_key(.X, 0, 'x')
	testing.expect_value(t, pk_take(201), "x")
	pk_key(.ENTER)
	testing.expect_value(t, pk_take(201), "\r")
	pk_key(.ESCAPE)
	testing.expect_value(t, pk_take(201), "\x1b")
	testing.expect(t, peek_is_open(), "Esc is the program's")
	pk_key(.LEFT, sapp.MODIFIER_SUPER) // ⌘←: line editing, the peeked program's
	testing.expect_value(t, pk_take(201), "\x01")
	testing.expect(t, !ime_option_composes(), "Option is Alt in the peeked terminal, though a field is focused")
	ime_commit("é")
	testing.expect_value(t, pk_take(201), "é")
	testing.expect_value(t, tf_text(&filter_field), "")
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, state.focus_widget, "sidebar_filter")

	// the mouse: a press in its terminal is its program's (a selection here); none reaches the tab under it
	at := pk_centre({peek.area.x, peek.area.y, peek.area.z, peek.area.w})
	pk_mouse(.MOUSE_DOWN, at.x, at.y)
	testing.expect(t, b.mouse_down && !a.mouse_down, "the press is the peeked terminal's")
	pk_mouse(.MOUSE_UP, at.x, at.y)
	testing.expect(t, !b.mouse_down, "released")
	// a click on the panel's header (not a button) does nothing
	head, _ := pk_box("peek_title")
	pk_mouse(.MOUSE_DOWN, head.x + 2, head.y + head.height / 2)
	pk_mouse(.MOUSE_UP, head.x + 2, head.y + head.height / 2)
	testing.expect(t, peek_is_open(), "a click in the panel keeps it")

	// ⌘W: the peek closes, not the tab under it; the field has the keyboard as before
	pk_key(.W, sapp.MODIFIER_SUPER)
	testing.expect(t, !peek_is_open(), "⌘W closes the peek")
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	testing.expect_value(t, len(find_session(100).tabs), 1)
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect_value(t, attention_sel, u64(200))
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, pk_take(201), "")

	// typed in the field: Space is a space again
	pk_key(.A, 0, 'a')
	pk_key(.SPACE, 0, ' ')
	testing.expect(t, !peek_is_open(), "no peek once the field was typed in")
	testing.expect_value(t, tf_text(&filter_field), "a ")
	tf_set(&filter_field, "")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()

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
	ui_do(core.Set_Focus{""})
	core.inbox_drain()

	// a menu bar item clicked while peeking: Close tab closes the peek, never the tab under it
	testing.expect(t, peek_open_session(200), "peeks")
	action_run("close_tab")
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "Close tab closes the peek")
	testing.expect_value(t, len(find_session(100).tabs), 1)

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
	// the field had the keyboard: the click ends its editing on the way, and ⌘W gives it back
	filter_focus()
	core.inbox_drain()
	e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = pk_centre(eye).x, mouse_y = pk_centre(eye).y}
	_ = ui_layout(1600, 900)
	ui_hover = Hit_Open_Row(on3.id)
	_ = ui_layout(1600, 900)
	cover_wait(COVER_QUIET)
	event(&e)
	testing.expect(t, peek_is_open() && peek.session == on3.id, "the eye's click peeks at another machine's tab")
	e.type = .MOUSE_UP
	event(&e)
	pk_key(.W, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect(t, !peek_is_open(), "closed")
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()
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
		cover_wait(COVER_QUIET)
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
	state.current_session = 100
	peek_next()
	testing.expect_value(t, peek.tab, u64(201))
	pk_key(.A, sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect_value(t, peek.tab, u64(401)) // the page's session is passed over
	pk_key(.A, sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER)
	testing.expect_value(t, peek.tab, u64(501))
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
	testing.expect(t, peek_open_session(200), "peeks")
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
	cover_wait(COVER_QUIET)
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
	pk_session(200, "A session title long enough to be clipped in a narrow panel header", pk_tab(201, "waiting", 3 * time.Minute))
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
				for b in audit(cmds, where_, w, within = "peek_box", layer = PEEK_Z_BOX, own = []string{"peek_head", "peek_title", "peek_open", "peek_close"}) {
					problems += 1
					if problems <= 20 do testing.expectf(t, false, "%s", b)
				}
				head, _ := pk_box("peek_head")
				a := peek.area
				testing.expectf(t, a.z > 0 && a.w > 0 && a.y >= head.y + head.height - 0.5 && a.x >= box.x && a.x + a.z <= box.x + box.width && a.y + a.w <= box.y + box.height, "%s: the terminal's area %v in the panel %v under its header", where_, a, box)
				for name, want in ([2]string{"peek_open", "peek_close"}) {
					d, dok := pk_box(name)
					if !testing.expectf(t, dok && d.width > 0, "%s: %s", where_, name) do continue
					testing.expectf(t, d.x >= box.x && d.x + d.width <= box.x + box.width, "%s: %s inside the panel", where_, name)
					clay.SetPointerState(pk_centre(d), false)
					testing.expectf(t, ui_hit() == Hit(Hit_Peek(want == 0 ? .Open : .Close)), "%s: %s hit where drawn", where_, name)
				}
				// the terminal's area is hit as the terminal (nothing of the chrome under it)
				mid := pk_centre({a.x, a.y, a.z, a.w})
				testing.expect(t, peek_in_term(mid.x, mid.y), "the area is the terminal's")
				clay.SetPointerState(mid, false)
				testing.expectf(t, ui_hit() == nil, "%s: nothing under the scrim is hit", where_)
			}
		}
	}
	testing.expectf(t, problems == 0, "%d layout problems", problems)
	state.layout.left_open, state.layout.right_open = true, false
}

// The peek is a cover (ui_cover.odin): opened from the palette, the palette closes; a key held
// when it closes (its tab went) does not go on under it; holding ⌘W closes the peek, never the tab
// under it; a paste in it is its tab's, and one that comes after it closed goes nowhere; a composition
// shows in it, never in the field under it; Space after an input method typed into the Attention
// filter is a space; the pointer outside its terminal is not the program's unless a press is
// held; the window to the background and back (⌘H, ⌘M) keeps typing in it.
@(test)
peek_is_a_cover :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101), pk_tab(102))
	pk_session(200, "There", pk_tab(201, "waiting", 3 * time.Minute))
	state.current_session = 100
	a := pk_view(101, 80, 24)
	b := pk_view(201, 80, 24)
	pasted: [dynamic]u64
	defer delete(pasted)
	@(static) paste_log: ^[dynamic]u64
	paste_log = &pasted
	tab_paste_hook = proc(tab: u64, text: string) {append(paste_log, tab)}

	// from the palette (⌃⌥⌘A as it runs it): the palette closes
	ui_do(core.Set_Focus{"palette"})
	core.inbox_drain()
	action_run("peek_next_needing_you")
	core.inbox_drain()
	testing.expect(t, peek_is_open() && state.focus_widget == "", "peeking, the palette closed")
	peek_close()
	ui_do(core.Set_Focus{""})
	core.inbox_drain()
	testing.expect(t, peek_open_session(200), "peeks")

	// holding ⌘W: the peek closes, the repeats close nothing
	cover_wait(COVER_QUIET)
	ev := sapp.Event{type = .KEY_DOWN, key_code = .W, modifiers = sapp.MODIFIER_SUPER}
	event(&ev)
	testing.expect(t, !peek_is_open(), "⌘W closed it")
	ev.key_repeat = true
	for _ in 0 ..< 3 {
		cover_wait(40 * time.Millisecond)
		event(&ev)
	}
	ev.type = .KEY_UP
	event(&ev)
	core.inbox_drain()
	testing.expect_value(t, len(find_session(100).tabs), 2)
	testing.expect_value(t, len(state.pending_confirmations), 0)
	testing.expect_value(t, len(find_session(200).tabs), 1)

	// Enter held when its tab goes: nothing types under it
	testing.expect(t, peek_open_session(200), "peeks")
	cover_wait(COVER_QUIET)
	en := sapp.Event{type = .KEY_DOWN, key_code = .ENTER}
	event(&en)
	testing.expect_value(t, pk_take(201), "\r")
	find_session(200).tabs[0].has_term = false // its terminal went
	en.key_repeat = true
	event(&en)
	testing.expect(t, !peek_is_open(), "closed")
	event(&en)
	ch := sapp.Event{type = .CHAR, char_code = '\r'}
	event(&ch)
	en.type = .KEY_UP
	event(&en)
	testing.expect_value(t, pk_take(101), "")
	find_session(200).tabs[0].has_term = true

	// ⌘V in it: its tab's; the peek closed before a paste came: nowhere, not the tab under it
	testing.expect(t, peek_open_session(200), "peeks")
	cover_wait(COVER_QUIET)
	pv := sapp.Event{type = .KEY_DOWN, key_code = .V, modifiers = sapp.MODIFIER_SUPER}
	event(&pv)
	pv.type = .CLIPBOARD_PASTED
	event(&pv)
	testing.expect(t, len(pasted) == 1 && pasted[0] == 201, "pasted into the peeked tab")
	peek_close()
	event(&pv)
	testing.expect_value(t, len(pasted), 1)
	pv.type = .KEY_UP
	event(&pv)

	// a composition over the Attention filter: drawn in the peek only; Space after a commit into the filter is a space
	state.sidebar.view = .Attention
	state.layout.left_tab = .Sessions
	filter_focus()
	core.inbox_drain()
	testing.expect(t, peek_open_session(200), "peeks")
	cover_wait(COVER_QUIET)
	ime_set_marked("に", 1)
	testing.expect_value(t, ime.marked, "")
	m, _ := cover_marked()
	testing.expect_value(t, m, "に")
	ime_commit("に")
	testing.expect_value(t, pk_take(201), "に")
	testing.expect_value(t, tf_text(&filter_field), "")
	peek_close()
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	pk_key(.DOWN)
	testing.expect(t, attention_keyed, "picked with ↓")
	ime_commit("ü")
	testing.expect(t, !attention_keyed, "typed in by an input method: Space is a space again")
	pk_key(.SPACE, 0, ' ')
	testing.expect(t, !peek_is_open(), "no peek")
	testing.expect_value(t, tf_text(&filter_field), "ü ")
	tf_set(&filter_field, "")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()

	// the pointer: outside its terminal's area (over the header, where its taller grid is clipped)
	// the program (tracking the mouse) hears nothing, unless a press is held
	pk_session(300, "Tall", pk_tab(301, "waiting", time.Minute))
	tall := pk_view(301, 80, 100)
	term_fits[301] = {cols = 80, rows = 100, cell = {font.cell_w, font.cell_h}}
	testing.expect(t, peek_open_session(300), "peeks")
	for _ in 0 ..< 2 do _ = pk_layout()
	vt := "\x1b[?1003h\x1b[?1006h" // any motion, SGR
	gh.terminal_vt_write(tall.gt, raw_data(vt), len(vt))
	_ = pk_take(301)
	in_at := pk_centre({peek.area.x, peek.area.y, peek.area.z, peek.area.w})
	head, _ := pk_box("peek_title")
	head_at := pk_centre(head)
	testing.expect(t, in_pane(tall, head_at.x, head_at.y), "its grid runs under the header")
	pk_mouse(.MOUSE_MOVE, in_at.x, in_at.y)
	testing.expect(t, pk_take(301) != "", "over it: reported")
	pk_mouse(.MOUSE_MOVE, head_at.x, head_at.y)
	testing.expect_value(t, pk_take(301), "")
	pk_mouse(.MOUSE_MOVE, in_at.x, in_at.y)
	_ = pk_take(301)
	pk_mouse(.MOUSE_DOWN, in_at.x, in_at.y)
	pk_mouse(.MOUSE_MOVE, head_at.x, head_at.y)
	testing.expect(t, pk_take(301) != "", "a held press drags outside")
	pk_mouse(.MOUSE_UP, head_at.x, head_at.y)
	testing.expect(t, !a.mouse_down && !tall.mouse_down, "no press anywhere")
	peek_close()
	testing.expect(t, peek_open_session(200), "peeks")

	// ⌘H or ⌘M (the system's): the peek stays; back in front, typing is its
	send :: proc(type: sapp.Event_Type) {
		x := sapp.Event{type = type}
		event(&x)
	}
	send(.UNFOCUSED)
	send(.FOCUSED)
	testing.expect(t, peek_is_open() && b.focused && !a.focused, "the peek has the keyboard again")
	_ = pk_take(201)
	pk_key(.Y, 0, 'y')
	testing.expect_value(t, pk_take(201), "y")
	testing.expect_value(t, pk_take(101), "")
	peek_close()
	testing.expect(t, a.focused, "the terminal under it has it back")
}
