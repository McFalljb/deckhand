package main

// Command layer tests (`./build.sh test`). They share the global State, so
// the runner is single-threaded (ODIN_TEST_THREADS=1 in build.sh). Processes
// are real but harmless: /bin/sh and `sleep`.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import gh "ghostty"

@(private = "file")
quits: int

@(private = "file")
reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	quits = 0
	platform = {quit = proc() {quits += 1}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	return runtime.heap_allocator()
}

// A fake pi store under a temp HOME: one project per cwd, given session ids.
@(private = "file")
fake_home :: proc(cwds: []string, ids: []string) -> string {
	home := fmt.aprintf("%s/pi-desk-test-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	for cwd, i in cwds {
		dir, _ := filepath.join({home, ".pi", "agent", "sessions", fmt.tprintf("--p%d--", i)}, context.temp_allocator)
		os.make_directory_all(dir)
		path := fmt.tprintf("%s/2026-10-30T10-00-0%d-000Z_%s.jsonl", dir, i, ids[i])
		header := fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", ids[i], cwd)
		_ = os.write_entire_file(path, transmute([]u8)header)
	}
	os.set_env("HOME", home)
	return home
}

@(private = "file")
script :: Caller{kind = .Script}

@(test)
command_json_round_trip :: proc(t: ^testing.T) {
	context.allocator = reset()
	cmds := [?]Command {
		Add_Project{cwd = `/tmp/a "b"\c`},
		Select_Project{project_id = 3},
		Rename_Project{project_id = 3, name = "naïve ✓ name"},
		Open_Session_Cmd{project_id = 3, pi_session_id = "0b0c-uuid"},
		New_Chat{project_id = 9},
		Focus_Session{session = 4},
		New_Shell_Tab{session = 4},
		Close_Tab{tab_id = 7},
		Close_Tab{tab_id = 7, confirm = "tok"},
		Focus_Tab{tab_id = 8},
		Copy_Selection{tab_id = 8},
		Terminal_Link{tab_id = 8, url = "https://example.com/a?b=1"},
		Terminal_Link{tab_id = 8, url = "mailto:a@example.invalid", external = true},
		Send_Text{tab_id = 8, text = "line1\nline2\t\x01end"},
		Set_Focus{widget = "rename_project"},
		Set_Focus{},
		Set_Layout{left_width = 280, right_open = true},
		Set_Layout{left_open = false},
		Set_Layout{right_width = 333.5},
		Set_Panel{panel = "todos", open = true},
		Cancel_Confirmation{token = "tok"},
		Rescan{},
		Quit{},
		Quit{confirm = "tok"},
		Get_State{},
		Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Trusted},
		Set_Close_Confirm{tab_kind = .Shell, rule = .Never},
		Set_Theme{name = .Ghostty},
		Set_Reduce_Motion{on = true},
		Set_Terminal_Text_Size{pt = 16},
		Set_Appearance{mode = .Light},
		Set_Appearance{mode = .System},
		Panel_Set{tab_id = 2, panel = "todos", title = "Todos", rows = {{text = "Todos 1/2", head = true}, {text = "✓ \"done\"", tone = .Dim}, {text = "○ next"}}},
		Panel_Remove{tab_id = 2, panel = "todos"},
		Set_Panel_Collapsed{panel = "shells", collapsed = true},
	}
	for c in cmds {
		text := command_json(c)
		back, err := parse_command(text, context.temp_allocator)
		testing.expectf(t, err == "", "%s: %s", text, err)
		testing.expectf(t, command_json(back) == text, "round trip: %s -> %s", text, command_json(back))
	}
	// redaction for events
	red := command_json(Send_Text{tab_id = 1, text = "secret"}, redact = true)
	testing.expect(t, !strings.contains(red, "secret") && strings.contains(red, "redacted 6 bytes"), red)
	red = command_json(Panel_Set{tab_id = 1, panel = "todos", rows = {{text = "secret row"}}}, redact = true)
	testing.expect(t, !strings.contains(red, "secret") && strings.contains(red, "redacted 1 rows"), red)
	red = command_json(Close_Tab{tab_id = 1, confirm = "tok"}, redact = true)
	testing.expect(t, !strings.contains(red, "tok\""), red)
}

@(test)
command_parse_errors :: proc(t: ^testing.T) {
	context.allocator = reset()
	bad := [?][2]string {
		{`not json`, "invalid JSON"},
		{`[1]`, "a command must be a JSON object"},
		{`{"tab_id":1}`, "missing field type"},
		{`{"type":"nope"}`, "unknown command nope"},
		{`{"type":"tab_exited","tab_id":1}`, "unknown command tab_exited"}, // internal only
		{`{"type":"close_tab"}`, "missing field tab_id"},
		{`{"type":"close_tab","tab_id":-1}`, "tab_id must be a non-negative integer"},
		{`{"type":"close_tab","tab_id":"1"}`, "tab_id must be a non-negative integer"},
		{`{"type":"send_text","tab_id":1,"text":5}`, "text must be a string"},
		{`{"type":"set_layout","right_open":1}`, "right_open must be a boolean"},
		{`{"type":"set_confirm_policy","caller":"control","class":"tab_close","mode":"yolo"}`, "unknown mode yolo"},
		{`{"type":"set_theme","name":"neon"}`, "unknown name neon"},
		{`{"type":"set_theme"}`, "missing field name"},
		{`{"type":"set_reduce_motion","on":"yes"}`, "on must be a boolean"},
	}
	for b in bad {
		_, err := parse_command(b[0], context.temp_allocator)
		testing.expectf(t, err == b[1], "%s: got %q want %q", b[0], err, b[1])
	}
	m, err := parse_request(`{"id":"7","type":"command","v":1,"command":{"type":"focus_tab","tab_id":2}}`)
	testing.expect(t, err == "" && m.id == "7" && m.command.(Focus_Tab).tab_id == 2, err)
	_, err = parse_request(`{"id":"1","type":"hello","v":2,"token":"x"}`)
	testing.expect_value(t, err, "unsupported protocol version 2 (pi-desk speaks 1)")
}

@(test)
state_json_round_trip :: proc(t: ^testing.T) {
	context.allocator = reset()
	s := State {
		version          = 12,
		next_id          = 40,
		selected_project = 2,
		current_session  = 5,
		focus_widget     = "rename_project",
		layout           = {left_width = 280, right_width = 300, right_open = true},
	}
	append(&s.projects, Project{id = 2, cwd = "/a", label = "~/a", name = "A", dir = "/s/--a--"})
	append(&s.sessions, Session{id = "u1", path = "/s/--a--/x_u1.jsonl", when_ = "2026-10-30 10:00", title = `say "hi"`})
	os_ := Open_Session{id = 5, pi_session_id = "u1", project_id = 2, cwd = "/a", active_tab = 7}
	pi := Tab{id = 6, kind = Pi_Tab{}, title = "pi", agent = .Working}
	todos := Panel{id = "todos", title = "Todos"}
	append(&todos.rows, Panel_Row{text = "Todos 1/2", head = true}, Panel_Row{text = "✓ a", tone = .Dim}, Panel_Row{text = "▸ b", tone = .Accent}, Panel_Row{text = ""})
	append(&pi.panels, todos, Panel{id = "shells", title = "Shells"})
	append(&os_.tabs, pi, Tab{id = 7, kind = Shell_Tab{}, title = "shell 1", status = .Exited})
	append(&s.open_sessions, os_)
	append(&s.layout.panels, "todos", "workers")
	append(&s.layout.collapsed, "shells")
	append(&s.pending_confirmations, Pending_Confirmation{token = "secret-token", summary = "Close?", command = Quit{}, class = .App_Quit, caller = script})
	s.settings.confirm[.Control][.Tab_Close] = .Trusted
	s.settings.confirm[.Panel][.Delete] = .Auto
	s.settings.confirm_close[.Shell] = .Never
	s.settings.theme = .Warm
	s.settings.reduce_motion = true
	s.system_light = true // appearance system: the snapshot's "light" follows the OS

	b := strings.builder_make(context.temp_allocator)
	write_state(&b, s)
	text := strings.to_string(b)
	testing.expect(t, !strings.contains(text, "secret-token"), "tokens stay out of the snapshot")
	back, err := state_from_json(text)
	testing.expect_value(t, err, "")
	b2 := strings.builder_make(context.temp_allocator)
	write_state(&b2, back)
	testing.expect_value(t, strings.to_string(b2), text)
	testing.expect_value(t, back.open_sessions[0].tabs[1].status, Tab_Status.Exited)
	testing.expect_value(t, back.open_sessions[0].tabs[0].panels[0].rows[2].tone, Panel_Tone.Accent)
	testing.expect_value(t, json_path(text, "open_sessions.0.tabs.0.panels.0.rows.0.head"), "true")
	testing.expect_value(t, json_path(text, "layout.collapsed.0"), "shells")
}

// Rows are capped per tab across its panels (a max-size set would overflow
// the glyph run cache and reshape every frame), row text is short.
@(test)
panel_bounds :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	tab := find_session(sess).tabs[0].id
	own := Caller{kind = .Panel, tab_id = tab}
	rows :: proc(n: int, text := "row") -> []Panel_Row {
		out := make([]Panel_Row, n, context.temp_allocator)
		for &r in out do r.text = text
		return out
	}
	run_command(Panel_Set{tab_id = tab, panel = "a", rows = rows(150)}, own)
	run_command(Panel_Set{tab_id = tab, panel = "b", rows = rows(100)}, own)
	run_command(Panel_Set{tab_id = tab, panel = "c", rows = rows(10)}, own)
	_, pt, _ := find_tab(tab)
	testing.expect_value(t, len(pt.panels[0].rows), 150)
	testing.expect_value(t, len(pt.panels[1].rows), 51) // 50 fit, then "+50 more"
	testing.expect_value(t, pt.panels[1].rows[50].text, "+50 more")
	testing.expect_value(t, len(pt.panels[2].rows), 1)
	testing.expect_value(t, pt.panels[2].rows[0].text, "+10 more")
	// a panel's own old rows do not count against it
	run_command(Panel_Set{tab_id = tab, panel = "a", rows = rows(10)}, own)
	run_command(Panel_Set{tab_id = tab, panel = "c", rows = rows(10)}, own)
	testing.expect_value(t, len(pt.panels[2].rows), 10)
	// the worst case (a fresh tab): 16 full panels stay near 200 rows of short text in all
	s2 := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	tab2 := find_session(s2).tabs[0].id
	long := strings.repeat("é", 1000, context.temp_allocator) // 2 bytes each
	for i in 0 ..< 16 do run_command(Panel_Set{tab_id = tab2, panel = fmt.tprintf("p%d", i), rows = rows(500, long)}, Caller{kind = .Panel, tab_id = tab2})
	_, pt, _ = find_tab(tab2)
	testing.expect_value(t, len(pt.panels), 16)
	n, bytes := 0, 0
	for p in pt.panels do for r in p.rows {
		n += 1
		bytes += len(r.text)
		testing.expect(t, len(r.text) <= 160, "row text cut to 160 bytes")
	}
	testing.expect(t, n <= 200 + 16, fmt.tprintf("rows per tab: %d", n))
	testing.expect(t, bytes <= (200 + 16) * 160, fmt.tprintf("bytes per tab: %d", bytes))
	testing.expect_value(t, len(pt.panels[0].rows[0].text), 160)
}

// Panel text, titles and ids are one line each: no control characters
// (Clay breaks lines at \n even without wrapping) and no bidi overrides.
@(test)
panel_text_is_one_clean_line :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	tab := find_session(sess).tabs[0].id
	own := Caller{kind = .Panel, tab_id = tab}
	dirty := "a\nb\r\tc\x1b[31md\u202Ee\u2066f\u2069g\x7fh"
	run_command(Panel_Set{tab_id = tab, panel = "to\ndos", title = "T\ni\u202Atle", rows = {{text = dirty}}}, own)
	_, pt, _ := find_tab(tab)
	testing.expect_value(t, pt.panels[0].rows[0].text, "a b  c [31mdefg h")
	testing.expect_value(t, pt.panels[0].title, "T itle")
	testing.expect_value(t, pt.panels[0].id, "to dos")
	// the same raw id still addresses it
	run_command(Panel_Remove{tab_id = tab, panel = "to\ndos"}, own)
	testing.expect_value(t, len(pt.panels), 0)
	run_command(Set_Panel_Collapsed{panel = "to\ndos", collapsed = true}, script)
	testing.expect_value(t, state.layout.collapsed[0], "to dos")
}

// The folded-panel list cannot grow without bound: the oldest entries go.
@(test)
collapsed_is_capped :: proc(t: ^testing.T) {
	context.allocator = reset()
	for i in 0 ..< 70 do run_command(Set_Panel_Collapsed{panel = fmt.tprintf("p%d", i), collapsed = true}, script)
	testing.expect_value(t, len(state.layout.collapsed), 64)
	testing.expect_value(t, state.layout.collapsed[0], "p6")
	testing.expect_value(t, state.layout.collapsed[63], "p69")
}

// Panels: only the tab's own bridge publishes them; bounded; replaced in
// place; gone when the bridge is gone or the tab exits.
@(test)
panel_commands :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	s1 := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	s2 := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	tab1, tab2 := find_session(s1).tabs[0].id, find_session(s2).tabs[0].id
	shell := run_command(New_Shell_Tab{session = s1}, script).created_id
	own := Caller{kind = .Panel, tab_id = tab1}
	set :: proc(tab: u64, panel: string, rows: ..Panel_Row) -> Panel_Set {return {tab_id = tab, panel = panel, title = panel, rows = rows}}

	r := run_command(set(tab1, "todos", {text = "Todos 0/1", head = true}, {text = "○ a"}), own)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.0.rows.1.text"), "○ a")
	// nobody else: another tab's bridge, control, scripts, the user
	for c in ([?]Caller{{kind = .Panel, tab_id = tab2}, {kind = .Control}, script, {kind = .UI}}) {
		testing.expect_value(t, run_command(set(tab1, "todos"), c).error, "not allowed for this caller")
		testing.expect_value(t, run_command(Panel_Remove{tab_id = tab1, panel = "todos"}, c).error, "not allowed for this caller")
	}
	// a shell tab has no panels
	testing.expect_value(t, run_command(set(shell, "x"), Caller{kind = .Panel, tab_id = shell}).error, "no such pi tab")
	testing.expect_value(t, run_command(set(tab1, ""), own).error, "panel is empty")
	testing.expect_value(t, run_command(set(tab1, strings.repeat("x", PANEL_ID_MAX + 1)), own).error, "panel id too long (max 64 bytes)")

	// replaced in place (order kept), removed, re-added at the end
	run_command(set(tab1, "shells", {text = "Shells", head = true}), own)
	run_command(set(tab1, "todos", {text = "Todos 1/1", head = true}), own)
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.0.rows.0.text"), "Todos 1/1")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "2")
	v := state.version
	testing.expect(t, run_command(Panel_Remove{tab_id = tab1, panel = "nope"}, own).ok)
	testing.expect_value(t, state.version, v) // nothing to remove: no change
	run_command(Panel_Remove{tab_id = tab1, panel = "todos"}, own)
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.0.panel"), "shells")

	// bounds: panels per tab (rows and text: panel_bounds)
	run_command(set(tab1, "big"), own)
	_, pt, _ := find_tab(tab1)
	for i in len(pt.panels) ..< PANELS_MAX do testing.expect(t, run_command(set(tab1, fmt.tprintf("p%d", i)), own).ok)
	testing.expect_value(t, run_command(set(tab1, "one-more"), own).error, "too many panels (max 16)")
	testing.expect(t, run_command(set(tab1, "big"), own).ok, "replacing one still works at the cap")

	// folding is layout, for anyone
	testing.expect(t, run_command(Set_Panel_Collapsed{panel = "todos", collapsed = true}, {kind = .UI}).ok)
	testing.expect_value(t, json_path(state_json(), "layout.collapsed.0"), "todos")
	v = state.version
	run_command(Set_Panel_Collapsed{panel = "todos", collapsed = true}, script)
	testing.expect_value(t, state.version, v)
	run_command(Set_Panel_Collapsed{panel = "todos", collapsed = false}, script)
	testing.expect_value(t, json_path(state_json(), "layout.collapsed.#"), "0")

	// the last bridge connection gone (pi-desk sets unknown): panels cleared
	run_command(set(tab2, "todos", {text = "x"}), Caller{kind = .Panel, tab_id = tab2})
	run_command(Pi_Status_Update{tab_id = tab1, agent = .Unknown})
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "0")
	testing.expect_value(t, json_path(state_json(), "open_sessions.1.tabs.0.panels.#"), "1") // other tab untouched
	// the tab exits: cleared, and no new ones
	run_command(Tab_Exited{tab_id = tab2})
	testing.expect_value(t, json_path(state_json(), "open_sessions.1.tabs.0.panels.#"), "0")
	testing.expect_value(t, run_command(set(tab2, "todos"), Caller{kind = .Panel, tab_id = tab2}).error, "the tab's process has exited")

	// parse: rows required; other kinds not yet; unknown tones read as plain
	_, err := parse_command(`{"type":"panel.set","panel":"x"}`, context.temp_allocator)
	testing.expect_value(t, err, "missing field rows")
	_, err = parse_command(`{"type":"panel.set","panel":"x","kind":"table"}`, context.temp_allocator)
	testing.expect_value(t, err, "panel kinds other than rows are not supported yet")
	_, err = parse_command(`{"type":"panel.set","panel":"x","rows":[{"tone":"dim"}]}`, context.temp_allocator)
	testing.expect_value(t, err, "each row needs a text string")
	c, err2 := parse_command(`{"type":"panel.set","panel":"x","rows":[{"text":"a","tone":"sparkly","id":"r1"}]}`, context.temp_allocator)
	testing.expect_value(t, err2, "")
	testing.expect_value(t, c.(Panel_Set).rows[0].tone, Panel_Tone.Normal)
}

@(test)
ids_stable_across_rescan_and_add_project :: proc(t: ^testing.T) {
	context.allocator = reset()
	fake_home({"/w/one", "/w/two"}, {"aaaa-1", "bbbb-2"})
	rescan_now()
	testing.expect_value(t, len(state.projects), 2)
	ids := map[string]u64{}
	for p in state.projects do ids[strings.clone(p.cwd)] = p.id // cwd strings live in the scan arena

	r := run_command(Add_Project{cwd = "/w/new"}, script)
	testing.expect(t, r.ok && r.created_id != 0)
	testing.expect_value(t, state.projects[0].cwd, "/w/new") // inserted at the top...
	for p in state.projects[1:] do testing.expect_value(t, p.id, ids[p.cwd]) // ...without moving ids
	testing.expect_value(t, state.selected_project, r.created_id)
	run_command(Rename_Project{project_id = ids["/w/one"], name = "One"}, script)

	rescan_now()
	testing.expect_value(t, len(state.projects), 3) // hand-added project kept
	for p in state.projects {
		if p.cwd == "/w/new" do testing.expect_value(t, p.id, r.created_id)
		else do testing.expect_value(t, p.id, ids[p.cwd])
		if p.cwd == "/w/one" do testing.expect_value(t, p.name, "One")
	}
	// same ids through the async Rescan
	res := run_command(Rescan{}, script, 77)
	testing.expect(t, res.ok && res.pending)
	deadline := time.tick_now()
	for scan_thread != nil && time.tick_since(deadline) < 5 * time.Second do inbox_drain()
	testing.expect(t, scan_thread == nil, "rescan finished")
	for p in state.projects do if p.cwd != "/w/new" do testing.expect_value(t, p.id, ids[p.cwd])
}

@(test)
new_chat_and_reopen_dedupe :: proc(t: ^testing.T) {
	context.allocator = reset()
	fake_home({"/tmp"}, {"cccc-3"})
	rescan_now()
	pid := state.projects[0].id
	r := run_command(New_Chat{project_id = pid}, script)
	testing.expect(t, r.ok, r.error)
	s := find_session(r.created_id)
	testing.expect(t, s != nil && len(s.pi_session_id) == 36, "pi-desk picked a UUID")
	testing.expect_value(t, s.tabs[0].status, Tab_Status.Running)

	// opening a listed session twice focuses the first one
	a := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "cccc-3"}, script)
	testing.expect(t, a.ok, a.error)
	b := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "cccc-3"}, script)
	testing.expect_value(t, b.created_id, a.created_id)
	testing.expect_value(t, len(state.open_sessions), 2)
	testing.expect_value(t, state.current_session, a.created_id)
	// the new chat, once pi wrote its file, is the same session too
	c := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = s.pi_session_id}, script)
	testing.expect_value(t, c.created_id, r.created_id)
	testing.expect_value(t, len(state.open_sessions), 2)

	bad := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "nope"}, script)
	testing.expect_value(t, bad.error, "no such session in this project")
	bad = run_command(New_Chat{project_id = 999}, script)
	testing.expect_value(t, bad.error, "no such project")
}

@(private = "file")
ui :: Caller{kind = .UI}

@(private = "file")
wait_busy :: proc(tab: u64, want: bool) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		if t := term_of(tab); t != nil && pty_foreground_busy(&t.pty) == want do return true
		time.sleep(20 * time.Millisecond)
	}
	return false
}

@(test)
confirmation_flow :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	pitab := find_session(sess).tabs[0].id
	agent := Caller{kind = .Control, tab_id = 0}

	testing.expect_value(t, run_command(Close_Tab{tab_id = pitab}, script).error, "a session's pi tab cannot be closed")
	tab := run_command(New_Shell_Tab{session = sess}, script).created_id
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab}, {kind = .Control, tab_id = tab}).error, "a caller cannot close its own tab")
	state.settings.confirm_close[.Shell] = .Always

	// ask (default): an agent gets no token and cannot confirm; the user can
	v := state.version
	r := run_command(Close_Tab{tab_id = tab}, agent)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, r.confirm_token == "" && r.confirm_by_user && r.confirm_summary != "")
	testing.expect(t, state.version > v, "a pending confirmation is a state change")
	token := strings.clone(state.pending_confirmations[0].token)
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab, confirm = token}, agent).error, "only the user can confirm this, in pi-desk")
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab, confirm = token}, script).error, "only the user can confirm this, in pi-desk")
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab, confirm = "wrong"}, ui).error, "unknown or expired confirmation token")
	testing.expect_value(t, run_command(Close_Tab{tab_id = pitab, confirm = token}, ui).error, "a session's pi tab cannot be closed")
	ok := run_command(Close_Tab{tab_id = tab, confirm = token}, ui)
	testing.expect(t, ok.ok, ok.error)
	testing.expect_value(t, len(find_session(sess).tabs), 1)
	testing.expect_value(t, len(state.pending_confirmations), 0)
	testing.expect_value(t, find_session(sess).active_tab, pitab)

	// agents cannot change their own (or anyone's) mode; the user can
	raise := Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Trusted}
	testing.expect_value(t, run_command(raise, agent).error, "not allowed for this caller")
	testing.expect_value(t, run_command(raise, script).error, "not allowed for this caller")
	testing.expect_value(t, run_command(Set_Close_Confirm{tab_kind = .Shell, rule = .Never}, agent).error, "not allowed for this caller")
	testing.expect_value(t, state.settings.confirm[.Control][.Tab_Close], Confirm_Mode.Ask)
	testing.expect(t, run_command(raise, ui).ok)

	// trusted for tab_close: the agent confirms its own token...
	tab = run_command(New_Shell_Tab{session = sess}, script).created_id
	r = run_command(Close_Tab{tab_id = tab}, agent)
	testing.expect(t, r.confirm_token != "" && !r.confirm_by_user)
	other := Caller{kind = .Control, tab_id = 99}
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab, confirm = r.confirm_token}, other).error, "only the user can confirm this, in pi-desk")
	testing.expect(t, run_command(Close_Tab{tab_id = tab, confirm = r.confirm_token}, agent).ok)
	// ...but not for classes it is not trusted with
	q := run_command(Quit{}, agent)
	testing.expect(t, q.error == "needs_confirmation" && q.confirm_token == "")
	qt := strings.clone(state.pending_confirmations[0].token)
	testing.expect_value(t, run_command(Quit{confirm = qt}, agent).error, "only the user can confirm this, in pi-desk")
	testing.expect_value(t, quits, 0)
	testing.expect(t, run_command(Cancel_Confirmation{token = qt}, ui).ok)

	// auto: no confirmation at all
	run_command(Set_Confirm_Policy{caller = .Control, class = .App_Quit, mode = .Auto}, ui)
	testing.expect(t, run_command(Quit{}, agent).ok)
	testing.expect_value(t, quits, 1)
	// the user confirms quit in the UI
	q = run_command(Quit{}, ui)
	testing.expect(t, q.confirm_token != "")
	testing.expect(t, run_command(Quit{confirm = q.confirm_token}, ui).ok)
	testing.expect_value(t, quits, 2)
	// the app itself is not asked
	testing.expect(t, run_command(Quit{}).ok)
	testing.expect_value(t, quits, 3)
}

@(test)
close_rules :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	pitab := find_session(sess).tabs[0].id

	// auto, shell idle at its prompt: closes at once
	tab := run_command(New_Shell_Tab{session = sess}, ui).created_id
	testing.expect(t, wait_busy(tab, false), "shell idle")
	testing.expect(t, run_command(Close_Tab{tab_id = tab}, ui).ok)
	// auto, shell running a command: asks
	tab = run_command(New_Shell_Tab{session = sess}, ui).created_id
	run_command(Send_Text{tab_id = tab, text = "sleep 30\n"}, ui)
	testing.expect(t, wait_busy(tab, true), "sleep in the foreground")
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab}, ui).error, "needs_confirmation")
	// never: closes even while busy
	run_command(Set_Close_Confirm{tab_kind = .Shell, rule = .Never}, ui)
	testing.expect(t, run_command(Close_Tab{tab_id = tab}, ui).ok)
	testing.expect_value(t, len(state.pending_confirmations), 0) // dropped with the tab
	// always: asks even when idle
	run_command(Set_Close_Confirm{tab_kind = .Shell, rule = .Always}, ui)
	tab = run_command(New_Shell_Tab{session = sess}, ui).created_id
	testing.expect_value(t, run_command(Close_Tab{tab_id = tab}, ui).error, "needs_confirmation")
	// pi tabs (auto) always ask until the bridge reports busy/idle
	_, pt, _ := find_tab(pitab)
	testing.expect(t, close_needs_confirm(pt^))
	state.settings.confirm_close[.Pi] = .Never
	testing.expect(t, !close_needs_confirm(pt^))
}

@(test)
command_log_rotates :: proc(t: ^testing.T) {
	context.allocator = reset()
	dir := fmt.tprintf("%s/pi-desk-log-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	event_log_open(dir)
	defer event_log_close()
	log_cap = 1000
	defer log_cap = LOG_CAP
	for i in 0 ..< 60 do run_command(Set_Panel{panel = fmt.tprintf("panel-%d", i), open = true}, script)
	for name in ([]string{"commands.log", "commands.log.1", "commands.log.2"}) {
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)
		testing.expectf(t, err == nil && len(data) > 0 && len(data) <= 1000, "%s: %d %v", name, len(data), err)
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/commands.log.3", dir)))
}

@(test)
failed_launch_is_an_error :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	os.set_env("SHELL", "/nonexistent/shell")
	r := run_command(New_Shell_Tab{session = sess}, script)
	testing.expect_value(t, r.error, "could not start the shell")
	testing.expect_value(t, len(find_session(sess).tabs), 1)
	testing.expect_value(t, len(terms), 1)
	r = run_command(New_Chat{project_id = state.selected_project}, script)
	testing.expect_value(t, r.error, "could not start pi")
	testing.expect_value(t, len(state.open_sessions), 1)
}

@(test)
version_only_moves_on_state_changes :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	tab := find_session(sess).tabs[0].id
	v := state.version
	run_command(Get_State{}, script)
	run_command(Copy_Selection{tab_id = tab}, script) // nothing selected: fails
	run_command(Send_Text{tab_id = tab, text = "x"}, script)
	run_command(Focus_Tab{tab_id = 9999}, script)
	run_command(Set_Focus{}, script) // already the terminal
	testing.expect_value(t, state.version, v)
	run_command(Set_Focus{widget = "rename_project"}, script)
	testing.expect_value(t, state.version, v + 1)
	testing.expect_value(t, run_command(Set_Focus{widget = "nope"}, script).error, "no such widget")
	g := run_command(Get_State{}, script)
	testing.expect(t, strings.contains(g.data, `"focus":{"kind":"widget","id":"rename_project"}`), g.data)
}

@(test)
theme_and_motion :: proc(t: ^testing.T) {
	context.allocator = reset()
	testing.expect_value(t, state.settings.theme, Theme_Id.Graphite)
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	tab := find_session(sess).tabs[0].id
	term := term_of(tab)
	bg_of :: proc(term: ^Term) -> gh.Color_Rgb {
		c: gh.Color_Rgb
		gh.terminal_get(term.gt, .Color_Background_Default, &c)
		return c
	}
	g := THEMES[.Graphite].term_bg
	testing.expect_value(t, bg_of(term), gh.Color_Rgb{g.r, g.g, g.b}) // new terminals start in the look
	v := state.version
	r := run_command(Set_Theme{name = .Ghostty}, script)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.version, v + 1)
	testing.expect_value(t, bg_of(term), gh.Color_Rgb{0x28, 0x2c, 0x34}) // Ghostty's default background
	pal: [256]gh.Color_Rgb
	gh.terminal_get(term.gt, .Color_Palette_Default, &pal)
	testing.expect_value(t, pal[1], gh.Color_Rgb{0xcc, 0x66, 0x66})
	testing.expect_value(t, pal[16 + 36 * 5 + 6 * 5 + 5], gh.Color_Rgb{255, 255, 255}) // cube
	testing.expect_value(t, pal[232], gh.Color_Rgb{8, 8, 8}) // grey ramp
	run_command(Set_Theme{name = .Ghostty}, script) // unchanged
	testing.expect_value(t, state.version, v + 1)
	run_command(Set_Reduce_Motion{on = true}, script)
	testing.expect_value(t, state.settings.reduce_motion, true)
	g2 := run_command(Get_State{}, script)
	testing.expect(t, strings.contains(g2.data, `"theme":"ghostty","reduce_motion":true`), g2.data)
	// panels may only query
	r = run_command(Set_Theme{name = .Warm}, Caller{kind = .Panel})
	testing.expect_value(t, r.error, "not allowed for this caller")
}

@(test)
appearance_resolution :: proc(t: ^testing.T) {
	context.allocator = reset()
	window_modes: [dynamic]Appearance
	defer delete(window_modes)
	@(static) wm: ^[dynamic]Appearance
	wm = &window_modes
	platform.set_appearance = proc(m: Appearance) {append(wm, m)}
	testing.expect_value(t, state.settings.appearance, Appearance.System)
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	term := term_of(find_session(sess).tabs[0].id)
	bg_of :: proc(term: ^Term) -> Rgba {
		c: gh.Color_Rgb
		gh.terminal_get(term.gt, .Color_Background_Default, &c)
		return {c.r, c.g, c.b, 255}
	}
	// system follows the OS: dark until the platform says light
	testing.expect(t, !theme_is_light())
	testing.expect(t, theme() == &THEMES[.Graphite])
	testing.expect_value(t, bg_of(term), THEMES[.Graphite].term_bg)
	v := state.version
	run_command(System_Appearance{light = true})
	testing.expect_value(t, state.version, v + 1)
	testing.expect(t, theme_is_light())
	testing.expect(t, theme() == &THEMES_LIGHT[.Graphite])
	testing.expect_value(t, bg_of(term), THEMES_LIGHT[.Graphite].term_bg) // terminals follow live
	run_command(System_Appearance{light = true}) // unchanged
	testing.expect_value(t, state.version, v + 1)
	// dark wins over a light OS; the OS still records its changes
	r := run_command(Set_Appearance{mode = .Dark}, script)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, !theme_is_light())
	testing.expect_value(t, bg_of(term), THEMES[.Graphite].term_bg)
	run_command(System_Appearance{light = false})
	run_command(Set_Appearance{mode = .Light}, script)
	testing.expect(t, theme_is_light())
	testing.expect_value(t, bg_of(term), THEMES_LIGHT[.Graphite].term_bg)
	// the look is independent: ghostty light
	run_command(Set_Theme{name = .Ghostty}, script)
	testing.expect(t, theme() == &THEMES_LIGHT[.Ghostty])
	testing.expect_value(t, bg_of(term), Rgba{0xff, 0xff, 0xff, 255})
	run_command(Set_Appearance{mode = .System}, script) // OS is dark now
	testing.expect(t, theme() == &THEMES[.Ghostty])
	testing.expect_value(t, bg_of(term), THEMES[.Ghostty].term_bg)
	// the window's own appearance followed each setting
	testing.expect_value(t, len(window_modes), 3)
	if len(window_modes) == 3 do testing.expect(t, window_modes[0] == .Dark && window_modes[1] == .Light && window_modes[2] == .System)
	// snapshot, light palette derivation, who may send it
	g := run_command(Get_State{}, script)
	testing.expect(t, strings.contains(g.data, `"appearance":"system","light":false`), g.data)
	pal: [256]gh.Color_Rgb
	run_command(Set_Appearance{mode = .Light}, script)
	gh.terminal_get(term.gt, .Color_Palette_Default, &pal)
	fg, bg := THEMES_LIGHT[.Ghostty].term_fg, THEMES_LIGHT[.Ghostty].term_bg
	testing.expect_value(t, pal[16], gh.Color_Rgb{fg.r, fg.g, fg.b}) // cube from the foreground...
	testing.expect_value(t, pal[231], gh.Color_Rgb{bg.r, bg.g, bg.b}) // ...to the background
	for i in 232 ..< 255 do testing.expectf(t, lab_of({pal[i].r, pal[i].g, pal[i].b, 255}).l < lab_of({pal[i + 1].r, pal[i + 1].g, pal[i + 1].b, 255}).l, "grey ramp runs dark to light at %d", i)
	r = run_command(Set_Appearance{mode = .Dark}, Caller{kind = .Panel})
	testing.expect_value(t, r.error, "not allowed for this caller")
	_, err := parse_command(`{"type":"system_appearance","light":true}`, context.temp_allocator)
	testing.expect(t, err != "", "system_appearance is internal")
	_, err = parse_command(`{"type":"set_appearance","mode":"sepia"}`, context.temp_allocator)
	testing.expect_value(t, err, "unknown mode sepia")
}

// pi follows the terminal's light/dark: it turns on mode 2031, and on a
// report (CSI ? 997 ; 1|2 n) queries the colours again (OSC 10/11/4).
@(test)
appearance_reports_to_apps :: proc(t: ^testing.T) {
	context.allocator = reset()
	app_context = context // libghostty-vt's replies (on_write_pty) run in it
	out := fmt.tprintf("%s/pi-desk-2031-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	defer os.remove(out)
	os.set_env("PI_DESK_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", out))
	run_command(Add_Project{cwd = "/tmp"}, script)
	sess := run_command(New_Chat{project_id = state.selected_project}, script).created_id
	term := term_of(find_session(sess).tabs[0].id)
	got :: proc(path, want: string) -> bool {
		for _ in 0 ..< 200 {
			data, _ := os.read_entire_file(path, context.temp_allocator)
			if strings.contains(string(data), want) do return true
			time.sleep(10 * time.Millisecond)
		}
		return false
	}
	time.sleep(200 * time.Millisecond) // stty ran
	// no report until the app asks for them
	run_command(Set_Appearance{mode = .Light}, script)
	// the app enables mode 2031 and asks once (CSI ? 996 n)
	seq := "\x1b[?2031h\x1b[?996n"
	gh.terminal_vt_write(term.gt, raw_data(seq), len(seq))
	testing.expect(t, got(out, "\x1b[?997;2n"), "996 query answered: light")
	run_command(Set_Appearance{mode = .Dark}, script)
	testing.expect(t, got(out, "\x1b[?997;2n\x1b[?997;1n"), "switch reported: dark")
	// the re-query gets the new colours
	q := "\x1b]11;?\x1b\\"
	gh.terminal_vt_write(term.gt, raw_data(q), len(q))
	bg := THEMES[.Graphite].term_bg
	want := fmt.tprintf("\x1b]11;rgb:%02x%02x/%02x%02x/%02x%02x", bg.r, bg.r, bg.g, bg.g, bg.b, bg.b)
	testing.expectf(t, got(out, want), "OSC 11 answer %q", want)
	run_command(Set_Theme{name = .Warm}, script) // a new look: same scheme, new colours, reported too
	n := 0
	for _ in 0 ..< 200 {
		data, _ := os.read_entire_file(out, context.temp_allocator)
		n = strings.count(string(data), "\x1b[?997")
		if n >= 3 do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, n, 3)
}

@(test)
layout_and_panels :: proc(t: ^testing.T) {
	context.allocator = reset()
	run_command(Set_Layout{left_width = 250}, script)
	testing.expect_value(t, state.layout.left_width, 250)
	testing.expect_value(t, state.layout.right_open, false)
	run_command(Set_Layout{left_width = 5}, script)
	testing.expect_value(t, state.layout.left_width, LEFT_MIN) // clamped
	run_command(Set_Layout{left_width = 5000, right_width = 1}, script)
	testing.expect_value(t, state.layout.left_width, LEFT_MAX)
	testing.expect_value(t, state.layout.right_width, RIGHT_MIN)
	run_command(Set_Panel{panel = "todos", open = true}, script)
	run_command(Set_Panel{panel = "todos", open = true}, script)
	testing.expect_value(t, len(state.layout.panels), 1)
	testing.expect_value(t, state.layout.right_open, true)
	run_command(Set_Panel{panel = "todos", open = false}, script)
	testing.expect_value(t, len(state.layout.panels), 0)
	// the left column hides; focusing one of its fields shows it again
	run_command(Set_Layout{left_open = false}, script)
	testing.expect_value(t, state.layout.left_open, false)
	run_command(Set_Focus{widget = "sidebar_filter"}, script)
	testing.expect_value(t, state.layout.left_open, true)
	run_command(Set_Focus{}, script)
}

@(test)
callers_and_events :: proc(t: ^testing.T) {
	context.allocator = reset()
	panel := Caller{kind = .Panel, tab_id = 5}
	testing.expect_value(t, run_command(Add_Project{cwd = "/tmp"}, panel).error, "not allowed for this caller")
	testing.expect(t, run_command(Get_State{}, panel).ok)
	ev := Command_Event{caller = panel, command = Rescan{}}
	testing.expect(t, !event_visible_to(ev, {kind = .Panel, tab_id = 5}), "own events are not delivered")
	testing.expect(t, event_visible_to(ev, {kind = .Control, tab_id = 6}))
	line := event_json(Command_Event{command = Send_Text{tab_id = 1, text = "pw"}, result = {error = "needs_confirmation", confirm_token = "tk", confirm_summary = "s"}})
	testing.expect(t, strings.contains(line, `"by":"caller"`), line)
	testing.expect(t, !strings.contains(line, `"pw"`) && !strings.contains(line, `"tk"`), line)
}

@(test)
inbox_order_and_replies :: proc(t: ^testing.T) {
	context.allocator = reset()
	pid := run_command(Add_Project{cwd = "/tmp"}, script).created_id
	// a worker thread submits in order and waits for a reply
	Ctx :: struct {
		pid:   u64,
		reply: Reply,
		ids:   [20]u64,
	}
	ctx := Ctx{pid = pid}
	th := thread.create_and_start_with_poly_data(&ctx, proc(c: ^Ctx) {
		for i in 0 ..< 19 do c.ids[i] = inbox_submit(Rename_Project{project_id = c.pid, name = fmt.tprint(i)}, {kind = .Control})
		c.ids[19] = inbox_submit(Get_State{}, {kind = .Control}, &c.reply)
		sync.one_shot_event_wait(&c.reply.done)
	})
	deadline := time.tick_now()
	for !thread.is_done(th) && time.tick_since(deadline) < 5 * time.Second do inbox_drain()
	thread.join(th)
	thread.destroy(th)
	for i in 1 ..< 20 do testing.expect(t, ctx.ids[i] > ctx.ids[i - 1], "request ids increase")
	testing.expect_value(t, find_project(pid).name, "18") // the last rename won
	testing.expect(t, ctx.reply.result.ok && strings.contains(ctx.reply.result.data, `"name":"18"`))
	result_free(ctx.reply.result)
}

@(test)
text_field_editing :: proc(t: ^testing.T) {
	f: Text_Field
	tf_set(&f, "héllo")
	testing.expect_value(t, tf_selected_text(&f), "héllo") // set selects all
	tf_insert(&f, "ab\ncd")
	testing.expect_value(t, tf_text(&f), "abcd") // line breaks dropped
	tf_move(&f, -1, false)
	tf_backspace(&f)
	testing.expect_value(t, tf_text(&f), "abd")
	tf_home(&f, false)
	tf_delete(&f)
	testing.expect_value(t, tf_text(&f), "bd")
	tf_insert(&f, "é")
	tf_move(&f, -1, true)
	testing.expect_value(t, tf_selected_text(&f), "é")
	tf_move(&f, 1, false) // collapses to the right edge
	testing.expect_value(t, tf_text(&f)[:f.cursor], "é")
	tf_select_all(&f)
	tf_backspace(&f)
	testing.expect_value(t, tf_text(&f), "")
	tf_insert(&f, "xyz")
	tf_end(&f, false)
	tf_home(&f, true)
	c, lo, hi := tf_columns(&f)
	testing.expect(t, c == 0 && lo == 0 && hi == 3)
	// setting a shorter text after editing (stale cursor past the end)
	tf_end(&f, false)
	tf_move(&f, -1, true)
	tf_set(&f, "")
	testing.expect_value(t, tf_text(&f), "")
	tf_set(&f, "q")
	testing.expect_value(t, tf_selected_text(&f), "q")
	delete(f.buf)
}

// The app fills in every platform entry: a nil one makes its commands
// succeed without doing anything (Reveal in Finder on a session or project
// row, a job's Open run folder).
@(test)
platform_app_sets_every_entry :: proc(t: ^testing.T) {
	p := platform_app()
	testing.expect(t, p.set_clipboard != nil, "set_clipboard")
	testing.expect(t, p.quit != nil, "quit")
	testing.expect(t, p.wake != nil, "wake")
	testing.expect(t, p.pick_folder != nil, "pick_folder")
	testing.expect(t, p.run_later != nil, "run_later")
	testing.expect(t, p.set_appearance != nil, "set_appearance")
	testing.expect(t, p.reveal != nil, "reveal")
	testing.expect(t, p.notify != nil, "notify")
	testing.expect(t, p.window_active != nil, "window_active")
	testing.expect(t, p.left_button != nil, "left_button")
	testing.expect(t, p.open_url != nil, "open_url")
}
