package main

// Saved workspace tests (persist.odin). Same rules as core_test.odin: shared
// global State, one thread, harmless processes (/bin/sh, `sleep`).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
ws_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.persist = {}
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	return runtime.heap_allocator()
}

// A temp dir (resolved: macOS TMPDIR is behind a symlink, and a shell's cwd
// is reported resolved).
@(private = "file")
tmp_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-ws-%s-%d", os.get_env("TMPDIR", context.temp_allocator), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

// Fake pi store under a temp HOME: project i at cwds[i] with session ids[i].
@(private = "file")
ws_home :: proc(cwds: []string, ids: []string) -> string {
	home := tmp_dir("home")
	for cwd, i in cwds {
		dir := pi_store_dir_in(home, cwd)
		os.make_directory_all(dir)
		path := fmt.tprintf("%s/2026-10-30T10-00-0%d-000Z_%s.jsonl", dir, i, ids[i])
		header := fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", ids[i], cwd)
		_ = os.write_entire_file(path, transmute([]u8)header)
	}
	os.set_env("HOME", home)
	return home
}

@(private = "file")
pi_store_dir_in :: proc(home, cwd: string) -> string {
	name, _ := strings.replace_all(strings.trim_prefix(cwd, "/"), "/", "-", context.temp_allocator)
	return fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
}

@(private = "file")
project_by :: proc(cwd: string) -> ^core.Project {
	for &p in state.projects do if p.cwd == cwd do return &p
	return nil
}

// After a restart: empty State, rescanned store, the file restored and the
// first frame's focus done.
@(private = "file")
relaunch :: proc(t: ^testing.T, text: string) {
	ws_reset()
	core.rescan_now()
	err := core.workspace_restore(text)
	testing.expect_value(t, err, "")
	core.persist_after_layout(skip = false)
}

@(test)
workspace_round_trip :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a, b, hand := tmp_dir("a"), tmp_dir("b"), tmp_dir("hand")
	ws_home({a, b}, {"aaaa-1", "bbbb-2"})
	core.rescan_now()
	pa, pb := project_by(a), project_by(b)
	testing.expect(t, pa != nil && pb != nil)
	r := core.run_command(core.Open_Session_Cmd{project_id = pa.id, pi_session_id = "aaaa-1"})
	testing.expect(t, r.ok, r.error)
	sa := r.created_id
	r = core.run_command(core.New_Shell_Tab{session = sa})
	testing.expect(t, r.ok, r.error)
	r = core.run_command(core.New_Shell_Tab{session = sa})
	shell2 := r.created_id
	r = core.run_command(core.Open_Session_Cmd{project_id = project_by(b).id, pi_session_id = "bbbb-2"})
	sb := r.created_id
	core.run_command(core.Focus_Tab{tab_id = shell2}) // session a current, its second shell active
	core.run_command(core.Rename_Project{project_id = project_by(b).id, name = "Bee ✓"})
	core.run_command(core.Add_Project{cwd = hand}) // by hand, no sessions (selects it)
	core.run_command(core.Set_Panel{panel = "todos", open = true})
	core.run_command(core.Set_Panel_Collapsed{panel = "shells", collapsed = true})
	core.run_command(core.Set_Layout{left_width = 280, right_width = 333, left_open = false, right_open = false})
	core.run_command(core.Set_Theme{name = core.Theme_Id(1)})
	core.run_command(core.Set_Reduce_Motion{on = true})
	core.run_command(core.Set_Terminal_Text_Size{pt = 17})
	core.run_command(core.Set_Appearance{mode = .Light})
	core.run_command(core.Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Trusted})
	core.run_command(core.Set_Close_Confirm{tab_kind = .Shell, rule = .Always})
	_ = sb

	saved := strings.clone(core.workspace_json())
	testing.expect(t, strings.contains(saved, `"v":1`), saved)
	testing.expect(t, strings.contains(saved, `"aaaa-1"`) && strings.contains(saved, `"bbbb-2"`), saved)

	relaunch(t, saved)
	testing.expect_value(t, len(state.open_sessions), 2)
	if len(state.open_sessions) != 2 do return
	s0, s1 := &state.open_sessions[0], &state.open_sessions[1]
	testing.expect_value(t, s0.pi_session_id, "aaaa-1")
	testing.expect_value(t, s1.pi_session_id, "bbbb-2")
	testing.expect_value(t, len(s0.tabs), 3)
	testing.expect_value(t, state.current_session, s0.id)
	testing.expect_value(t, s0.active_tab, s0.tabs[2].id)
	testing.expect_value(t, s0.tabs[2].title, "shell 2")
	// lazy: the current session runs, the other waits
	for tab in s0.tabs do testing.expect_value(t, tab.status, core.Tab_Status.Running)
	testing.expect_value(t, s1.tabs[0].status, core.Tab_Status.Not_Started)
	testing.expect(t, core.term_of(s1.tabs[0].id) == nil)
	testing.expect_value(t, project_by(b).name, "Bee ✓")
	testing.expect(t, project_by(hand) != nil && project_by(hand).dir == "")
	testing.expect_value(t, state.selected_project, project_by(hand).id)
	testing.expect_value(t, state.layout.left_width, 280)
	testing.expect_value(t, state.layout.right_width, 333)
	testing.expect_value(t, state.layout.right_open, false)
	testing.expect_value(t, state.layout.left_open, false)
	testing.expect_value(t, len(state.layout.panels), 1)
	testing.expect(t, core.panel_collapsed("shells"))
	testing.expect_value(t, state.settings.theme, core.Theme_Id(1))
	testing.expect_value(t, state.settings.reduce_motion, true)
	testing.expect_value(t, state.settings.term_text_pt, 17)
	testing.expect_value(t, state.settings.appearance, core.Appearance.Light)
	testing.expect_value(t, state.settings.confirm[.Control][.Tab_Close], core.Confirm_Mode.Trusted)
	testing.expect_value(t, state.settings.confirm_close[.Shell], core.Close_Confirm.Always)
	// the same file again: nothing lost or added
	again := core.workspace_json()
	testing.expectf(t, again == saved, "second save differs:\n%s\n---\n%s", saved, again)

	// focusing the other session starts it
	core.run_command(core.Focus_Session{session = s1.id})
	testing.expect_value(t, s1.tabs[0].status, core.Tab_Status.Running)
	testing.expect(t, core.term_of(s1.tabs[0].id) != nil)
}

@(test)
workspace_saves_nothing_sensitive :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a := tmp_dir("a")
	ws_home({a}, {"aaaa-1"})
	core.rescan_now()
	r := core.run_command(core.Open_Session_Cmd{project_id = project_by(a).id, pi_session_id = "aaaa-1"})
	s := core.find_session(r.created_id)
	pi := s.tabs[0].id
	r = core.run_command(core.New_Shell_Tab{session = s.id})
	shell := r.created_id
	core.run_command(core.Send_Text{tab_id = shell, text = "echo typed-secret\n"})
	core.run_command(core.Panel_Set{tab_id = pi, panel = "todos", title = "Todos", rows = {{text = "row-secret"}}}, {kind = .Panel, tab_id = pi})
	core.run_command(core.Pi_Status_Update{tab_id = pi, agent = .Working, blockers = {"blocker-secret"}})
	q := core.run_command(core.Quit{}, {kind = .UI}) // running tabs: parks a confirmation
	testing.expect(t, q.confirm_token != "")
	core.run_command(core.Set_Confirm_Policy{caller = .Script, class = .Tab_Close, mode = .Trusted})
	c := core.run_command(core.Close_Tab{tab_id = pi + 100}, {kind = .Script})
	_ = c
	tf_set(&rename_field, "field-secret")
	core.run_command(core.Set_Focus{widget = "rename_project"})

	text := core.workspace_json()
	for bad in ([]string{q.confirm_token, "typed-secret", "row-secret", "blocker-secret", "field-secret", "rename_project", "working", "token", "pending", "Todos"}) {
		testing.expectf(t, !strings.contains(text, bad), "workspace contains %q:\n%s", bad, text)
	}
	tf_set(&rename_field, "")
}

@(test)
workspace_atomic_write :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	dir := tmp_dir("atomic")
	path := fmt.tprintf("%s/sub/workspace.json", dir)
	testing.expect_value(t, core.write_atomic(path, "one"), "")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "one")
	// an existing world-readable file is replaced by a private one
	os.change_mode(path, {.Read_User, .Write_User, .Read_Group, .Read_Other})
	testing.expect_value(t, core.write_atomic(path, "two"), "")
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "two")
	fi, _ := os.stat(path, context.temp_allocator)
	testing.expect_value(t, fi.mode & os.Permissions_All, os.Permissions{.Read_User, .Write_User})
	// no temp files left behind
	files, _ := os.read_all_directory_by_path(fmt.tprintf("%s/sub", dir), context.temp_allocator)
	testing.expect_value(t, len(files), 1)
	// a write that cannot happen leaves the old file alone
	testing.expect(t, core.write_atomic("/dev/null/x/workspace.json", "three") != "")
	// persist_save writes only when the content changed
	core.persist_init(fmt.tprintf("%s/sub", dir))
	core.run_command(core.Set_Reduce_Motion{on = true})
	core.persist_save()
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"reduce_motion":true`), string(data))
	core.persist_quit()
	core.run_command(core.Set_Reduce_Motion{on = false})
	core.persist_save() // after the final save: no more writes
	data, _ = os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), `"reduce_motion":true`), string(data))
}

@(private = "file")
bad_files :: proc(dir, tag: string) -> int {
	n := 0
	files, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for f in files do if strings.has_prefix(f.name, fmt.tprintf("workspace.json.%s-", tag)) do n += 1
	return n
}

@(test)
workspace_corrupt_and_version :: proc(t: ^testing.T) {
	cases := [?]string{"{not json", `[1,2]`, `{"projects":[]}`, `{"v":2,"open_sessions":[]}`, `{"v":"1"}`}
	for text, i in cases {
		context.allocator = ws_reset()
		ws_home({}, {})
		dir := tmp_dir(fmt.tprintf("bad%d", i))
		path := fmt.tprintf("%s/workspace.json", dir)
		_ = os.write_entire_file(path, transmute([]u8)text)
		core.persist_init(dir)
		core.persist_load()
		testing.expectf(t, !os.exists(path), "%s: file still in place", text)
		testing.expectf(t, bad_files(dir, "bad") == 1, "%s: no backup", text)
		testing.expect_value(t, len(state.open_sessions), 0)
		testing.expect_value(t, len(state.projects), 0)
	}
	// --fresh: not restored, kept aside
	context.allocator = ws_reset()
	ws_home({}, {})
	dir := tmp_dir("fresh")
	path := fmt.tprintf("%s/workspace.json", dir)
	_ = os.write_entire_file(path, transmute([]u8)string(`{"v":1,"projects":[{"cwd":"/tmp"}]}`))
	core.persist_init(dir)
	core.persist_load(fresh = true)
	testing.expect_value(t, len(state.projects), 0)
	testing.expect_value(t, bad_files(dir, "bak"), 1)
	// a good file is restored and stays
	_ = os.write_entire_file(path, transmute([]u8)string(`{"v":1,"projects":[{"cwd":"/tmp","name":"T"}]}`))
	core.persist_load()
	testing.expect(t, os.exists(path))
	testing.expect(t, project_by(resolved("/tmp")) != nil && project_by(resolved("/tmp")).name == "T")
}

@(test)
workspace_missing_dirs :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a, gone_proj := tmp_dir("a"), tmp_dir("gone")
	ws_home({a, gone_proj}, {"aaaa-1", "gggg-2"})
	os.remove(gone_proj) // project folder deleted; its session file is still in pi's store
	text := fmt.tprintf(`{{"v":1,
"projects":[{{"cwd":"/nowhere/at/all","name":"Gone"}}],
"open_sessions":[
 {{"pi_session_id":"dead-0","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi"}},{{"kind":"shell","title":"shell 1","cwd":"/nowhere/x"}}],"active_tab":1}},
 {{"pi_session_id":"gggg-2","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi"}}],"active_tab":0}},
 {{"pi_session_id":"nope-3","cwd":"/nowhere/at/all","session_dir":"","project":"/nowhere/at/all","tabs":[{{"kind":"pi"}},{{"kind":"browser"}}],"active_tab":0}}
],
"current_session":0}}`, a, a, gone_proj, gone_proj)
	relaunch(t, text)
	testing.expect_value(t, len(state.open_sessions), 3)
	if len(state.open_sessions) != 3 do return
	dead, gp, nowhere := &state.open_sessions[0], &state.open_sessions[1], &state.open_sessions[2]
	testing.expect(t, dead.missing, "session file never existed")
	testing.expect(t, gp.missing, "project folder deleted")
	testing.expect(t, nowhere.missing)
	testing.expect_value(t, len(nowhere.tabs), 1) // the unknown tab kind is dropped
	p := project_by("/nowhere/at/all")
	testing.expect(t, p != nil && p.missing && p.name == "Gone")
	pg := project_by(gone_proj)
	testing.expect(t, pg != nil && pg.missing)
	// the current session is gone: focusing it starts nothing
	testing.expect_value(t, state.current_session, dead.id)
	for tab in dead.tabs {
		testing.expect_value(t, tab.status, core.Tab_Status.Not_Started)
		testing.expect(t, core.term_of(tab.id) == nil)
	}
	// closing a gone session's shell tab works (no process to ask about)
	r := core.run_command(core.Close_Tab{tab_id = dead.tabs[1].id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	// state JSON shows them
	sj := core.state_json()
	testing.expect(t, strings.contains(sj, `"missing":true`) && strings.contains(sj, `"status":"not_started"`), sj)
	// restored sessions stay in the file even while gone (a volume may come
	// back): the save right after launch must not drop them
	saved := core.workspace_json()
	for id in ([]string{"dead-0", "nope-3", "gggg-2"}) do testing.expectf(t, strings.contains(saved, id), "%s dropped:\n%s", id, saved)
	// a second restore of that file brings back the same sessions
	relaunch(t, strings.clone(saved, context.temp_allocator))
	testing.expect_value(t, len(state.open_sessions), 3)
}

// A new chat pi has not written yet is not saved; once its file appears it is.
@(test)
workspace_drops_unwritten_chats :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a := tmp_dir("a")
	ws_home({a}, {"aaaa-1"})
	core.rescan_now()
	r := core.run_command(core.New_Chat{project_id = project_by(a).id})
	testing.expect(t, r.ok, r.error)
	id := core.find_session(r.created_id).pi_session_id
	testing.expect(t, !strings.contains(core.workspace_json(), id))
	path := fmt.tprintf("%s/2026-10-31T00-00-00-000Z_%s.jsonl", core.pi_store_dir(a), id)
	_ = os.write_entire_file(path, transmute([]u8)string("{}\n"))
	testing.expect(t, strings.contains(core.workspace_json(), id))
}

// Status and panel reports from a working pi are not saved: they must not
// make the workspace dirty (each save check lists session dirs and asks
// every shell for its cwd).
@(test)
workspace_status_does_not_dirty :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a := tmp_dir("a")
	ws_home({a}, {"aaaa-1"})
	core.rescan_now()
	core.persist_init(tmp_dir("data"))
	r := core.run_command(core.Open_Session_Cmd{project_id = project_by(a).id, pi_session_id = "aaaa-1"})
	pi := core.find_session(r.created_id).tabs[0].id
	core.persist_save()
	testing.expect(t, !core.persist_dirty())
	own := core.Caller{kind = .Panel, tab_id = pi}
	core.run_command(core.Pi_Status_Update{tab_id = pi, agent = .Working}, own)
	core.run_command(core.Panel_Set{tab_id = pi, panel = "todos", rows = {{text = "x"}}}, own)
	core.run_command(core.Panel_Remove{tab_id = pi, panel = "todos"}, own)
	core.run_command(core.Set_Focus{widget = "rename_project"})
	testing.expect(t, !core.persist_dirty())
	core.run_command(core.Rename_Project{project_id = project_by(a).id, name = "A"})
	testing.expect(t, core.persist_dirty())
}

// The session-file lookup for a session without a known file lists its dir
// once, then again only when the dir changes.
@(test)
workspace_lookup_cached :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a := tmp_dir("a")
	ws_home({a}, {"aaaa-1"})
	core.rescan_now()
	r := core.run_command(core.New_Chat{project_id = project_by(a).id})
	id := core.find_session(r.created_id).pi_session_id
	core.workspace_json()
	n := core.persist.dir_lists
	testing.expect(t, n >= 1)
	core.workspace_json()
	core.workspace_json()
	testing.expect_value(t, core.persist.dir_lists, n)
	time.sleep(10 * time.Millisecond)
	path := fmt.tprintf("%s/2026-10-31T00-00-00-000Z_%s.jsonl", core.pi_store_dir(a), id)
	_ = os.write_entire_file(path, transmute([]u8)string("{}\n"))
	testing.expect(t, strings.contains(core.workspace_json(), id))
	testing.expect_value(t, core.persist.dir_lists, n + 1)
	core.workspace_json() // found: a stat, no listing
	testing.expect_value(t, core.persist.dir_lists, n + 1)
}

// Not a regular file, or too big: moved aside without reading it.
@(test)
workspace_load_checks_file :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	ws_home({}, {})
	dir := tmp_dir("notfile")
	os.make_directory_all(fmt.tprintf("%s/workspace.json", dir))
	core.persist_init(dir)
	core.persist_load()
	testing.expect_value(t, bad_files(dir, "bad"), 1)
	ws_reset()
	dir = tmp_dir("big")
	path := fmt.tprintf("%s/workspace.json", dir)
	f, _ := os.open(path, {.Write, .Create}, {.Read_User, .Write_User})
	os.truncate(f, core.WORKSPACE_MAX + 1)
	os.close(f)
	core.persist_init(dir)
	core.persist_load()
	testing.expect_value(t, bad_files(dir, "bad"), 1)
}

@(test)
workspace_lazy_start :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a, b := tmp_dir("a"), tmp_dir("b")
	ws_home({a, b}, {"aaaa-1", "bbbb-2"})
	text := fmt.tprintf(`{{"v":1,"projects":[],
"open_sessions":[
 {{"pi_session_id":"aaaa-1","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi"}},{{"kind":"shell","title":"build","cwd":"%s"}}],"active_tab":1}},
 {{"pi_session_id":"bbbb-2","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi"}},{{"kind":"shell","title":"logs","cwd":"/nowhere"}}],"active_tab":0}}
],
"current_session":1}}`, a, a, a, b, b)
	ws_reset()
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	// before the first layout nothing runs
	testing.expect_value(t, len(core.terms), 0)
	testing.expect_value(t, core.any_running(), false)
	core.persist_after_layout(skip = false)
	sa, sb := &state.open_sessions[0], &state.open_sessions[1]
	testing.expect_value(t, state.current_session, sb.id)
	testing.expect_value(t, len(core.terms), 2) // b's pi and shell
	testing.expect_value(t, sb.tabs[1].title, "logs")
	testing.expect_value(t, sb.tabs[1].status, core.Tab_Status.Running) // saved cwd gone: starts in the session's
	testing.expect_value(t, sa.tabs[0].status, core.Tab_Status.Not_Started)
	testing.expect_value(t, sa.active_tab, sa.tabs[1].id)
	// a shell restored in its saved cwd
	core.run_command(core.Focus_Tab{tab_id = sa.tabs[1].id})
	testing.expect_value(t, len(core.terms), 4)
	if tt := core.term_of(sa.tabs[1].id); tt != nil do testing.expect_value(t, core.pty_child_cwd(&tt.pty), a)
	// `deckhand DIR` wins over the restored focus
	ws_reset()
	core.rescan_now()
	core.workspace_restore(text)
	core.persist_after_layout(skip = true)
	testing.expect_value(t, len(core.terms), 0)
}

// Browser tabs are saved per session (their URL and title) and come back in their own session's
// list; a restored session's pages load once it is first focused (browser_nav.odin).
@(test)
workspace_browser_tabs :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	a, b := tmp_dir("a"), tmp_dir("b")
	ws_home({a, b}, {"aaaa-1", "bbbb-2"})
	core.rescan_now()
	r := core.run_command(core.Open_Session_Cmd{project_id = project_by(a).id, pi_session_id = "aaaa-1"})
	sa := r.created_id
	r = core.run_command(core.Open_Session_Cmd{project_id = project_by(b).id, pi_session_id = "bbbb-2"})
	sb := r.created_id
	r = core.run_command(core.Browser_Open{session = sa, url = "https://a.example/one"}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Browser_Update{tab_id = r.created_id, what = {.Url}, url = "https://a.example/two"})
	r = core.run_command(core.Browser_Open{session = sb, url = "b.example"}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	r = core.run_command(core.Browser_Open{session = sa, url = "localhost:3000"}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Focus_Session{session = sb}) // b current at quit
	saved := strings.clone(core.workspace_json())
	defer delete(saved)
	testing.expect(t, strings.contains(saved, `"kind":"browser","url":"https://a.example/two"`), saved)
	for id, _ in browsers do browser_drop(id)
	relaunch(t, saved)
	testing.expect_value(t, len(state.open_sessions), 2)
	if len(state.open_sessions) != 2 do return
	ra, rb := &state.open_sessions[0], &state.open_sessions[1]
	testing.expect_value(t, len(ra.tabs), 3)
	testing.expect_value(t, len(rb.tabs), 2)
	if len(ra.tabs) != 3 || len(rb.tabs) != 2 do return
	testing.expect_value(t, ra.tabs[1].kind.(core.Browser_Tab).url, "https://a.example/two")
	testing.expect_value(t, ra.tabs[2].kind.(core.Browser_Tab).url, "http://localhost:3000")
	testing.expect_value(t, rb.tabs[1].kind.(core.Browser_Tab).url, "https://b.example")
	// b is on screen: its page has its runtime; a's wait for a to be focused
	testing.expect_value(t, state.current_session, rb.id)
	testing.expect_value(t, rb.tabs[1].status, core.Tab_Status.Running)
	testing.expect(t, browser_of(rb.tabs[1].id) != nil)
	testing.expect_value(t, ra.tabs[1].status, core.Tab_Status.Not_Started)
	testing.expect(t, browser_of(ra.tabs[1].id) == nil)
	core.run_command(core.Focus_Session{session = ra.id}, {kind = .UI})
	testing.expect_value(t, ra.tabs[1].status, core.Tab_Status.Running)
	testing.expect_value(t, ra.tabs[2].status, core.Tab_Status.Running)
	testing.expect(t, browser_of(ra.tabs[2].id) != nil && browser_of(ra.tabs[2].id).url == "http://localhost:3000")
	for id, _ in browsers do browser_drop(id)
	for &s in state.open_sessions do for tab in s.tabs do core.drop_term(tab.id)
}


// keep_sessions (on by default; test mode off unless a scene turns it on): the user's only,
// saved once the user chose it (keep_sessions_default_not_saved), restored; a workspace.json
// without it (never chosen, or written while it was Experimental and off by default) gets the
// default.
@(test)
keep_sessions_setting :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	core.persist_init(tmp_dir("ks"))
	testing.expect(t, core.keep_sessions_default(), "on by default")
	testing.expect(t, !strings.contains(core.workspace_json(), `"keep_sessions"`), "not chosen: not saved")
	for k in ([]core.Caller_Kind{.Control, .Script, .Panel, .App}) {
		r := core.run_command(core.Set_Keep_Sessions{on = true}, {kind = k, tab_id = 1})
		testing.expectf(t, !r.ok && r.error == "not allowed for this caller", "%v: %s", k, r.error)
	}
	testing.expect(t, !core.run_command(core.Set_Keep_Sessions{on = true}, {kind = .Panel, tab_id = 1, claude = true}).ok, "a Claude tab")
	testing.expect(t, !state.settings.keep_sessions)
	testing.expect(t, core.run_command(core.Set_Keep_Sessions{on = true}, {kind = .UI}).ok)
	text := strings.clone(core.workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(text, `"keep_sessions":true`), text)
	testing.expect(t, strings.contains(core.state_json(), `"keep_sessions":true`), "in the snapshot")
	core.run_command(core.Set_Keep_Sessions{on = false}, {kind = .UI})
	off := strings.clone(core.workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(off, `"keep_sessions":false`), off)
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect(t, state.settings.keep_sessions, "restored on")
	testing.expect_value(t, core.workspace_restore(off), "")
	testing.expect(t, !state.settings.keep_sessions, "restored off: the user's off stays off")
	old, _ := strings.replace(off, `"keep_sessions":false,`, "", 1, context.temp_allocator)
	old, _ = strings.replace(old, `,"keep_sessions":false`, "", 1, context.temp_allocator)
	testing.expect(t, !strings.contains(old, "keep_sessions"), old)
	testing.expect_value(t, core.workspace_restore(old), "")
	testing.expect(t, state.settings.keep_sessions, "absent: the default (on)")
	c, ok := core.parse_command(`{"type":"set_keep_sessions","on":false}`, context.temp_allocator)
	_, is := c.(core.Set_Keep_Sessions)
	testing.expect(t, ok == "" && is, ok)
}

// keep_sessions is saved only once the user chose it: a run with the default on that never
// changed it leaves no key, so a build whose default is off again (the default-on commit
// reverted) reads it as off. A choice is kept across a default change either way.
@(test)
keep_sessions_default_not_saved :: proc(t: ^testing.T) {
	context.allocator = ws_reset()
	core.persist_init(tmp_dir("ksd"))
	saved_default := core.keep_sessions_default_on
	defer core.keep_sessions_default_on = saved_default
	core.keep_sessions_default_on = true
	testing.expect_value(t, core.workspace_restore(`{"v":1,"settings":{}}`), "")
	testing.expect(t, state.settings.keep_sessions == core.keep_sessions_default(), "absent: the default")
	untouched := strings.clone(core.workspace_json(), context.temp_allocator)
	testing.expect(t, !strings.contains(untouched, `"keep_sessions"`), untouched)
	core.run_command(core.Set_Keep_Sessions{on = true}, {kind = .UI}) // the user turns it on (already on): a choice
	chose_on := strings.clone(core.workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(chose_on, `"keep_sessions":true`), chose_on)
	core.keep_sessions_default_on = false // the default-off build
	testing.expect_value(t, core.workspace_restore(untouched), "")
	testing.expect(t, !state.settings.keep_sessions, "never chosen: off under the default-off build")
	testing.expect_value(t, core.workspace_restore(chose_on), "")
	testing.expect(t, state.settings.keep_sessions, "chosen on: stays on")
}
