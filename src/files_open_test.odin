package main

// Opening a file from the Files tree with no session of its project on screen: the project's
// Files session (core/files_session.odin) holds it, with no agent; only the user makes one.
// Refusals reach the window as a toast. The Files session's tabs: reorder, split, drag, close
// (the last one closes it); terminals, browser, app and agent tabs are refused in it; it is saved
// by project and comes back with the files the open rules still allow.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
fo_setup :: proc() -> (dir, other: string) {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.platform = {quit = proc() {}}
	core.files_refresh()
	core.files_state_gen += 1
	toast_clear()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	base := fmt.tprintf("%s/deckhand-files-open-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/proj", base))
	os.make_directory_all(fmt.tprintf("%s/other", base))
	dir = core.fs_real(fmt.tprintf("%s/proj", base), context.allocator)
	other = core.fs_real(fmt.tprintf("%s/other", base), context.allocator)
	ensure(strings.contains(dir, "/deckhand-files-open-test-") && os.is_directory(dir), "files open tests: no temp folder")
	for name in ([]string{"a.txt", "b.txt", "c.txt", "d.md"}) do _ = os.write_entire_file(fmt.tprintf("%s/%s", dir, name), transmute([]u8)string("a\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/o.txt", other), transmute([]u8)string("o\n"))
	append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(dir), label = strings.clone("proj")})
	append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(other), label = strings.clone("other")})
	state.selected_project = state.projects[0].id
	return
}

@(private = "file")
fo_done :: proc(dir: string) {
	core.inbox_drain()
	os.remove_all(strings.trim_suffix(dir, "/proj"))
}

@(private = "file")
fo_files :: proc() -> (n: int) {
	for s in state.open_sessions do if s.agent == .Files do n += 1
	return
}

@(private = "file")
fo_titles :: proc(s: ^core.Open_Session) -> string {
	b := strings.builder_make(context.temp_allocator)
	for t, i in s.tabs {
		if i > 0 do strings.write_byte(&b, ' ')
		strings.write_string(&b, t.title)
	}
	return strings.to_string(b)
}

// No session: the file opens in the project's new Files session, on screen; the next files too.
@(test)
files_open_makes_a_files_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, other := fo_setup()
	defer fo_done(dir)
	testing.expect_value(t, core.files_root(), dir)
	// a click: a preview tab
	files_open(fmt.tprintf("%s/a.txt", dir), preview = true)
	testing.expect_value(t, toast.text, "")
	testing.expect_value(t, len(state.open_sessions), 1)
	s := &state.open_sessions[0]
	testing.expect_value(t, s.agent, core.Session_Agent.Files)
	testing.expect_value(t, s.project_id, state.projects[0].id)
	testing.expect_value(t, state.current_session, s.id)
	testing.expect_value(t, fo_titles(s), "a.txt")
	testing.expect(t, s.tabs[0].kind.(core.Editor_Tab).preview)
	testing.expect_value(t, core.files_root(), dir) // the tree stays on the project
	testing.expect_value(t, core.open_session_title(s), "Files")
	testing.expect(t, core.session_pi_tab(s) == nil)
	testing.expect_value(t, core.session_main_tab(s), 0)
	// the next preview replaces it; Enter keeps one; a Markdown preview opens beside them
	files_open(fmt.tprintf("%s/b.txt", dir), preview = true)
	testing.expect_value(t, fo_titles(s), "b.txt")
	files_open(fmt.tprintf("%s/c.txt", dir))
	testing.expect_value(t, fo_titles(s), "b.txt c.txt")
	r := core.run_command(core.Markdown_Open{path = fmt.tprintf("%s/d.md", dir)}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(s.tabs), 3)
	testing.expect_value(t, fo_files(), 1) // at most one per project
	// the state stream and get_state say what it is
	testing.expect(t, strings.contains(core.state_json(), `"agent":"files"`))

	// by the file's project: another project's file opens in that project's Files session, not
	// the one on screen
	r = core.run_command(core.Open_File{path = fmt.tprintf("%s/o.txt", other), session = s.id}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, fo_files(), 2)
	o := core.files_session_of(state.projects[1].id)
	testing.expect(t, o != nil && state.current_session == o.id)
	testing.expect_value(t, len(core.files_session_of(state.projects[0].id).tabs), 3)
	// and back: a.txt goes to proj's again (made once only)
	testing.expect(t, core.run_command(core.Open_File{path = fmt.tprintf("%s/a.txt", dir)}, {kind = .UI}).ok)
	testing.expect_value(t, fo_files(), 2)
	testing.expect_value(t, state.current_session, core.files_session_of(state.projects[0].id).id)

	// a file in no project: said so, nothing made
	r = core.run_command(core.Open_File{path = "/etc/hosts"}, {kind = .UI})
	testing.expect(t, r.ok, r.error) // on screen is proj's Files session: it opens there
	state.current_session = 0
	r = core.run_command(core.Open_File{path = "/etc/hosts"}, {kind = .UI})
	testing.expect_value(t, r.error, "Open a session to open files outside a project")
	testing.expect_value(t, fo_files(), 2)
	// an agent session on screen keeps what the user opens (as before)
	pi := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("p-1"), project_id = state.projects[1].id, cwd = strings.clone(other)}
	append(&pi.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = strings.clone("pi"), status = .Exited})
	pi.active_tab = pi.tabs[0].id
	core.session_panes_init(&pi)
	append(&state.open_sessions, pi)
	state.current_session = pi.id
	testing.expect(t, core.run_command(core.Open_File{path = fmt.tprintf("%s/o.txt", other), session = pi.id}, {kind = .UI}).ok)
	testing.expect_value(t, len(core.find_session(pi.id).tabs), 2)
}

// Who makes one: the user at this window and a paired browser (show_file from its tree); a
// script, an agent and another machine's core keep the refusal, and nothing is made.
@(test)
files_open_who_may_make_one :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, _ := fo_setup()
	defer fo_done(dir)
	path := fmt.tprintf("%s/a.txt", dir)
	testing.expect_value(t, core.run_command(core.Open_File{path = path}, {kind = .Script}).error, "no open session to open the file in")
	testing.expect_value(t, core.run_command(core.Open_File{path = path}, {kind = .Control}).error, "no open session to open the file in")
	testing.expect_value(t, core.run_command(core.Show_File{path = path}, {kind = .Script}).error, "no session on screen")
	testing.expect(t, !core.run_command(core.Show_File{path = path}, {kind = .Control}).ok)
	hub := core.Caller{kind = .UI, hub = true}
	testing.expect_value(t, core.run_command(core.Open_File{path = path}, hub).error, "Open a session in proj to open files")
	testing.expect_value(t, core.run_command(core.Show_File{path = path}, hub).error, "Open a session in proj to open files")
	testing.expect_value(t, len(state.open_sessions), 0)
	// a refused file makes nothing either (and the window's open says why)
	files_open(fmt.tprintf("%s/missing.txt", dir))
	testing.expect_value(t, toast.text, "no such file")
	testing.expect(t, toast.err)
	testing.expect_value(t, len(state.open_sessions), 0)
	// a paired browser's tree (show_file, the ui caller from the web link)
	r := core.run_command(core.Show_File{path = path}, {kind = .UI, web = true})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, fo_files(), 1)
	testing.expect_value(t, len(state.open_sessions[0].tabs), 1)
	// a script may open a file in the Files session it names (it makes none)
	r = core.run_command(core.Open_File{path = fmt.tprintf("%s/b.txt", dir), session = state.open_sessions[0].id}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, fo_files(), 1)
}

// Nothing runs in a Files session: terminals, browser, app and agent tabs, comments are refused.
@(test)
files_session_runs_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, _ := fo_setup()
	defer fo_done(dir)
	files_open(fmt.tprintf("%s/a.txt", dir))
	s := core.cur()
	testing.expect(t, s != nil && s.agent == .Files)
	sid := s.id
	ui := core.Caller{kind = .UI}
	testing.expect_value(t, core.run_command(core.New_Shell_Tab{session = sid}, ui).error, "Start a session in proj for a terminal")
	testing.expect_value(t, core.run_command(core.Split_Pane{direction = .Right}, ui).error, "Start a session in proj for a terminal")
	testing.expect_value(t, core.run_command(core.Browser_Open{session = sid, url = "https://example.com"}, ui).error, "Start a session in proj for a browser tab")
	testing.expect_value(t, core.run_command(core.New_App_Tab{session = sid, argv = {"true"}}, ui).error, "Start a session in proj for an app tab")
	testing.expect_value(t, core.run_command(core.New_Claude_Tab{session = sid, harness = .Claude}, ui).error, "Start a session in proj for Claude Code")
	testing.expect_value(t, core.run_command(core.New_Claude_Tab{session = sid, harness = .Codex}, ui).error, "Start a session in proj for Codex")
	testing.expect_value(t, core.run_command(core.Comment_Add{tab_id = s.tabs[0].id, text = "x"}, {kind = .Internal}).error, "Start a session in proj for comments to an agent")
	testing.expect_value(t, len(core.find_session(sid).tabs), 1)
}

// Its tabs: reorder, split, drag (no main tab to stay first), close any of them; the last one
// closes the session.
@(test)
files_session_tabs_move_and_close :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, _ := fo_setup()
	defer fo_done(dir)
	for name in ([]string{"a.txt", "b.txt", "c.txt"}) do files_open(fmt.tprintf("%s/%s", dir, name))
	s := core.cur()
	testing.expect_value(t, fo_titles(s), "a.txt b.txt c.txt")
	ui := core.Caller{kind = .UI}
	pane := s.tabs[0].pane
	// reorder: the first to the end, then the last to the front
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = s.tabs[0].id, pane = pane, index = -1}, ui).ok)
	testing.expect_value(t, fo_titles(s), "b.txt c.txt a.txt")
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = s.tabs[2].id, pane = pane, index = 0}, ui).ok)
	testing.expect_value(t, fo_titles(s), "a.txt b.txt c.txt")
	// a drag in the strip to its front: allowed (the window's drop rule, no main tab)
	rect :: proc(i: int) -> [4]f32 {return {f32(i) * 100, 0, 100, 30}}
	dts := []Drop_Tab{{s.tabs[0].id, rect(0)}, {s.tabs[1].id, rect(1)}, {s.tabs[2].id, rect(2)}}
	panes := []Drop_Pane{{id = pane, zone = {0, 30, 300, 300}, strip = {0, 0, 300, 30}, tabs = dts}}
	d := tab_drop_at({panes = panes, tab = s.tabs[2].id, from = pane, from_count = 3, main = core.session_main_tab(s), edge_min = 20, edge_max = 60, mark_w = 2}, 10, 15)
	cmd, ok := tab_drop_command(d, s.tabs[2].id)
	testing.expect(t, ok)
	testing.expect(t, core.run_command(cmd, ui).ok)
	testing.expect_value(t, fo_titles(s), "c.txt a.txt b.txt")
	// split: the first tab into a new pane on the right
	testing.expect(t, core.run_command(core.Split_Pane{pane = pane, direction = .Right, tab_id = s.tabs[0].id}, ui).ok)
	testing.expect_value(t, len(s.panes), 2)
	// close: the first tab (no main tab to keep), then the rest; the last closes the session
	sid := s.id
	for len(core.find_session(sid).tabs) > 0 {
		x := core.find_session(sid)
		left := len(x.tabs)
		r := core.run_command(core.Close_Tab{tab_id = x.tabs[0].id}, ui)
		testing.expect(t, r.ok, r.error)
		if left == 1 do break
	}
	testing.expect(t, core.find_session(sid) == nil)
	testing.expect_value(t, state.current_session, 0)
}

// Saved by project ("files_sessions", its own key: an older Deckhand reads open_sessions only and
// keeps everything else); back with the files the open rules still allow; a project that is gone
// from the list is skipped; nothing else of the workspace is lost.
@(test)
files_session_saved_and_restored :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, other := fo_setup()
	defer fo_done(dir)
	// a pi session of the other project, restored (kept whether or not its file is there)
	pi := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("p-1"), project_id = state.projects[1].id, cwd = strings.clone(other), restored = true}
	append(&pi.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = strings.clone("pi"), status = .Exited})
	pi.active_tab = pi.tabs[0].id
	core.session_panes_init(&pi)
	append(&state.open_sessions, pi)
	files_open(fmt.tprintf("%s/a.txt", dir))
	files_open(fmt.tprintf("%s/b.txt", dir))
	testing.expect(t, core.run_command(core.Markdown_Open{path = fmt.tprintf("%s/d.md", dir)}, {kind = .UI}).ok)
	text := strings.clone(core.workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(text, `"files_sessions"`), text)
	// open_sessions (what an older Deckhand reads) holds the pi session only
	testing.expect(t, !strings.contains(text, `"pi_session_id":""`), text)
	testing.expect_value(t, strings.count(text, `"pi_session_id":"p-1"`), 1)

	// what a later run finds: b.txt gone, a sign-in file, a file outside the project, a second
	// entry for a project no longer listed, an entry of the wrong shape
	os.remove(fmt.tprintf("%s/b.txt", dir))
	agent := fmt.tprintf("%s/agent", dir)
	os.make_directory_all(agent)
	_ = os.write_entire_file(fmt.tprintf("%s/auth.json", agent), transmute([]u8)string("{}"))
	os.set_env("PI_CODING_AGENT_DIR", agent)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	extra := fmt.tprintf(`{{"kind":"editor","path":"%s/auth.json"}},{{"kind":"editor","path":"%s/o.txt"}},{{"kind":"shell","path":"%s/a.txt"}},`, agent, other, dir)
	text, _ = strings.replace(text, `"files_sessions":[{"project":`, `"files_sessions":[7,{"project":"/nowhere/gone","tabs":[{"kind":"editor","path":"/etc/hosts"}]},{"project":`, 1, context.temp_allocator)
	text, _ = strings.replace(text, fmt.tprintf(`"tabs":[{{"kind":"editor","path":"%s`, dir), fmt.tprintf(`"tabs":[%s{{"kind":"editor","path":"%s`, extra, dir), 1, context.temp_allocator)
	testing.expect(t, strings.contains(text, "auth.json"), text)

	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	projects := [2]string{strings.clone(dir, context.temp_allocator), strings.clone(other, context.temp_allocator)}
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	for p in projects do append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(p), label = strings.clone(p == dir ? "proj" : "other")})
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 2)
	testing.expect_value(t, state.open_sessions[0].pi_session_id, "p-1")
	f := core.files_session_of(state.projects[0].id)
	testing.expect(t, f != nil)
	if f == nil do return
	testing.expect_value(t, fo_titles(f), "a.txt d.md") // b.txt gone; the sign-in, the outside file and the shell left out
	for tab in f.tabs do testing.expect_value(t, tab.status, core.Tab_Status.Not_Started)
	// it was on screen: it comes back on screen, its tabs open then
	core.persist_after_layout(false)
	testing.expect_value(t, state.current_session, f.id)
	for tab in f.tabs do testing.expect_value(t, tab.status, core.Tab_Status.Running)
	// a file without files_sessions (an older Deckhand's) restores as before
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	for p in projects do append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(p), label = strings.clone("x")})
	bad, _ := strings.replace(text, `"files_sessions":`, `"files_sessions_of_a_newer_kind":`, 1, context.temp_allocator)
	testing.expect_value(t, core.workspace_restore(bad), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	testing.expect_value(t, fo_files(), 0)
}
