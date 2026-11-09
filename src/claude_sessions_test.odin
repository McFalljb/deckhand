package main

// Claude-only sessions and Claude rows in the left column (claude.odin, sidebar.odin; docs/CLAUDE.md
// §1, §4), and Deckhand without Claude Code installed. Same rules as core_test.odin: shared global
// State, one thread, harmless processes (`sleep` or a shell line standing in for claude).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
CS_UI :: core.Caller{kind = .UI}
@(private = "file")
CS_SCRIPT :: core.Caller{kind = .Script}
@(private = "file")
CS_CONTROL :: core.Caller{kind = .Control}

@(private = "file")
cs_reset :: proc() -> runtime.Allocator {
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
	core.platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	core.claude_found = .Yes // the tests' stand-in for claude is installed (detection: claude_detection)
	return runtime.heap_allocator()
}

@(private = "file")
cs_dir :: proc(tag: string) -> string {
	// not "deckhand-": its e-c-n-d plus an s in TMPDIR's random part made the "secnd" filter
	// below match every row by its path (claude_session_rows, a flake after the rename)
	d := fmt.aprintf("%s/dhx-cs-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

@(private = "file")
cs_project :: proc(tag: string) -> (dir: string, pid: u64) {
	dir = cs_dir(tag)
	pid = core.run_command(core.Add_Project{cwd = dir}, CS_UI).created_id
	return
}

// A Claude-only session with its Claude session id reported and a first prompt (its title).
@(private = "file")
cs_claude_session :: proc(t: ^testing.T, pid: u64, sid, title: string, caller := CS_UI) -> (sess: u64, tab: u64) {
	r := core.run_command(core.New_Claude_Session{project_id = pid}, caller)
	testing.expect(t, r.ok, r.error)
	sess = r.created_id
	s := core.find_session(sess)
	if s == nil || len(s.tabs) == 0 do return
	tab = s.tabs[0].id
	testing.expect(t, core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup"}, CS_SCRIPT).ok)
	if title != "" do core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted", title = title}, CS_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "idle"}, CS_SCRIPT)
	return
}

@(private = "file")
cs_row_ids :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in core.sidebar_sessions(.Sessions) {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, core.session_label(r.session^))
		if r.session.claude do strings.write_string(&b, "(c)")
	}
	return strings.to_string(b)
}

@(private = "file")
cs_wait_file :: proc(path: string) -> string {
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 do return string(data)
		time.sleep(20 * time.Millisecond)
	}
	return ""
}

// A new Claude session: an open session whose main tab is a Claude tab (no pi tab), on screen for
// the user, behind for an agent (and without flags); the main tab closes only with its session.
@(test)
claude_session_new :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	dir, pid := cs_project("new")
	r := core.run_command(core.New_Claude_Session{project_id = pid, args = {"--model", "opus"}}, CS_UI)
	testing.expect(t, r.ok, r.error)
	s := core.find_session(r.created_id)
	testing.expect(t, s != nil)
	testing.expect_value(t, s.agent, core.Session_Agent.Claude)
	testing.expect_value(t, len(s.tabs), 1)
	ct, is := s.tabs[0].kind.(core.Claude_Tab)
	testing.expect(t, is && len(ct.args) == 2)
	testing.expect(t, core.session_pi_tab(s) == nil, "no pi tab")
	testing.expect_value(t, state.current_session, s.id)
	testing.expect_value(t, s.cwd, dir)
	testing.expect_value(t, s.project_id, pid)
	main := s.tabs[0].id
	testing.expect(t, strings.contains(core.run_command(core.Close_Tab{tab_id = main}, CS_UI).error, "cannot be closed"), "the main tab goes with its session")
	// its Claude session id is the session's key (pins, rows, status)
	sid := "c1c1c1c1-0000-4000-8000-000000000001"
	core.run_command(core.Claude_Session_Report{tab_id = main, session_id = sid}, CS_SCRIPT)
	testing.expect_value(t, core.find_session(r.created_id).pi_session_id, sid)
	testing.expect_value(t, core.open_session_title(core.find_session(r.created_id)), "Untitled Claude session")
	core.run_command(core.Claude_Turn_Report{tab_id = main, state = "submitted", title = "write the parser"}, CS_SCRIPT)
	testing.expect_value(t, core.open_session_title(core.find_session(r.created_id)), "write the parser")
	// other tabs open beside it, as in a pi session
	testing.expect(t, core.run_command(core.New_Shell_Tab{session = r.created_id}, CS_UI).ok)
	// an agent's: behind the user's view, and the user's flags only
	testing.expect_value(t, core.run_command(core.New_Claude_Session{project_id = pid, args = {"--verbose"}}, CS_CONTROL).error, "only the user sets Claude Code's flags")
	r2 := core.run_command(core.New_Claude_Session{project_id = pid}, CS_CONTROL)
	testing.expect(t, r2.ok, r2.error)
	testing.expect_value(t, state.current_session, r.created_id)
	testing.expect_value(t, core.run_command(core.New_Claude_Session{project_id = 99999}, CS_UI).error, "no such project")
	// a cwd outside the project is refused
	testing.expect(t, !core.run_command(core.New_Claude_Session{project_id = pid, cwd = "/"}, CS_UI).ok)
	// the snapshot says what kind of session it is
	js := core.state_json()
	testing.expect(t, strings.contains(js, `"agent":"claude"`), js)
	testing.expect(t, strings.contains(js, `"claude_installed":true`), "Atlas learns whether it can start Claude")
	// closing it stops its tabs
	core.run_command(core.Claude_Turn_Report{tab_id = main, state = "idle"}, CS_SCRIPT)
	r3 := core.run_command(core.Close_Session{session = r.created_id}, CS_UI)
	testing.expect(t, r3.ok || r3.error == "needs_confirmation", r3.error)
}

// A project's Claude sessions are rows in its session list, from Deckhand's own history: titles,
// a Claude flag, never another project's; an open one is not listed twice.
@(test)
claude_session_rows :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	_, pid := cs_project("rows")
	_, other := cs_project("rows-other")
	cs_claude_session(t, other, "c2c2c2c2-0000-4000-8000-000000000009", "elsewhere")
	core.run_command(core.Select_Project{project_id = pid}, CS_UI)
	sess, _ := cs_claude_session(t, pid, "c2c2c2c2-0000-4000-8000-000000000001", "first claude")
	testing.expect_value(t, cs_row_ids(), "first claude(c)")
	r := core.run_command(core.Close_Session{session = sess}, CS_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, cs_row_ids(), "first claude(c)") // closed: still listed (the history)
	cs_claude_session(t, pid, "c2c2c2c2-0000-4000-8000-000000000002", "second claude")
	testing.expect_value(t, len(core.sidebar_sessions(.Sessions)), 2)
	// a Claude tab inside a pi session is listed too: its row focuses that tab
	pi := core.run_command(core.New_Chat{project_id = pid}, CS_UI).created_id
	tab := core.run_command(core.New_Claude_Tab{session = pi}, CS_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = "c2c2c2c2-0000-4000-8000-000000000003"}, CS_SCRIPT)
	rows := cs_row_ids()
	testing.expect(t, strings.contains(rows, "first claude(c)") && strings.contains(rows, "second claude(c)"), rows)
	// the filter matches titles
	core.run_command(core.Set_Filter{text = "secnd"}, CS_UI)
	testing.expect_value(t, cs_row_ids(), "second claude(c)")
	core.run_command(core.Set_Filter{text = ""}, CS_UI)
	// rename: a Deckhand title of the user's
	testing.expect(t, core.run_command(core.Claude_Rename{claude_session_id = "c2c2c2c2-0000-4000-8000-000000000001", title = "  parser work\n"}, CS_UI).ok)
	testing.expect(t, strings.contains(cs_row_ids(), "parser work(c)"), cs_row_ids())
	rec, _ := core.claude_record("c2c2c2c2-0000-4000-8000-000000000001")
	testing.expect_value(t, rec.title, "parser work")
	testing.expect(t, !core.run_command(core.Claude_Rename{claude_session_id = "nope", title = "x"}, CS_UI).ok)
	testing.expect(t, !strings.contains(core.command_json(core.Claude_Rename{claude_session_id = "x", title = "secret"}, redact = true), "secret"), "titles never logged")
}

// Pin and hide work for Claude rows as for pi rows (by id); the quick filters and the attention
// sort see an open Claude session's status like a pi session's.
@(test)
claude_session_pin_hide_filters :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	_, pid := cs_project("pin")
	a := "c3c3c3c3-0000-4000-8000-00000000000a"
	b := "c3c3c3c3-0000-4000-8000-00000000000b"
	sa, _ := cs_claude_session(t, pid, a, "alpha")
	core.run_command(core.Close_Session{session = sa}, CS_UI)
	sb, tb := cs_claude_session(t, pid, b, "beta")
	pisess := core.run_command(core.New_Chat{project_id = pid}, CS_UI).created_id
	_ = pisess
	core.run_command(core.Set_Sort{section = .Sessions, by = .Name}, CS_UI)
	// pin
	testing.expect(t, core.run_command(core.Set_Pinned{pi_session_id = b, pinned = true}, CS_UI).ok)
	rows := core.sidebar_sessions(.Sessions)
	testing.expect(t, len(rows) > 0 && rows[0].session.id == b && rows[0].pin == 0, "pinned on top")
	core.run_command(core.Set_Pinned{pi_session_id = b, pinned = false}, CS_UI)
	// hide (and show hidden)
	testing.expect(t, core.run_command(core.Set_Hidden{pi_session_id = a, hidden = true}, CS_UI).ok)
	testing.expect(t, !strings.contains(cs_row_ids(), "alpha"), cs_row_ids())
	core.run_command(core.Set_Filter{show_hidden = true}, CS_UI)
	testing.expect(t, strings.contains(cs_row_ids(), "alpha"))
	core.run_command(core.Set_Filter{show_hidden = false}, CS_UI)
	core.run_command(core.Set_Hidden{pi_session_id = a, hidden = false}, CS_UI)
	// status: the open Claude session works (OSC 7501), the closed one does not
	s := core.find_session(sb)
	_, tab, _ := core.find_tab(tb)
	tab.prog.state = .Working
	testing.expect_value(t, core.session_status(b), core.Row_Status.Running)
	testing.expect_value(t, core.session_status(a), core.Row_Status.None)
	core.run_command(core.Set_Filter{running = true}, CS_UI)
	testing.expect_value(t, cs_row_ids(), "beta(c)")
	testing.expect(t, len(core.sidebar_open()) == 1 && core.sidebar_open()[0].id == s.id, "the Open group too")
	core.run_command(core.Set_Filter{running = false}, CS_UI)
	// attention: a Claude session that waits for the user comes before the pi session and the rest
	tab.prog.state = .Blocked
	core.run_command(core.Set_Sort{section = .Sessions, by = .Attention}, CS_UI)
	rows = core.sidebar_sessions(.Sessions)
	testing.expect(t, len(rows) == 3 && rows[0].session.id == b, cs_row_ids())
	testing.expect_value(t, core.project_status(pid), core.Row_Status.Waiting)
	// waiting work is never concealed: hiding it does not take the row away
	core.run_command(core.Set_Hidden{pi_session_id = b, hidden = true}, CS_UI)
	testing.expect(t, strings.contains(cs_row_ids(), "beta"))
	// a Claude tab inside a pi session: its row shows that tab's status
	tab.prog.state = .Idle
	pt := core.run_command(core.New_Claude_Tab{session = pisess}, CS_UI).created_id
	c := "c3c3c3c3-0000-4000-8000-00000000000c"
	core.run_command(core.Claude_Session_Report{tab_id = pt, session_id = c}, CS_SCRIPT)
	_, ptab, _ := core.find_tab(pt)
	ptab.prog.state = .Error
	testing.expect_value(t, core.session_status(c), core.Row_Status.Error)
}

// A click on a closed Claude row (open_session with its id, as the row sends) resumes it in a
// Claude-only session: --resume with the user's saved flags for the user, none for anyone else.
// An open one is focused, a Claude tab in a pi session included.
@(test)
claude_session_resume_from_row :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	dir, pid := cs_project("resume")
	sid := "c4c4c4c4-0000-4000-8000-000000000001"
	r := core.run_command(core.New_Claude_Session{project_id = pid, args = {"--model", "m", "--dangerously-skip-permissions"}}, CS_UI)
	main := core.find_session(r.created_id).tabs[0].id
	core.run_command(core.Claude_Session_Report{tab_id = main, session_id = sid}, CS_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = main, state = "idle"}, CS_SCRIPT)
	core.run_command(core.Close_Session{session = r.created_id}, CS_UI)
	argf := fmt.tprintf("%s/argv", dir)
	plugin := os.get_env("DECKHAND_CLAUDE_PLUGIN", context.temp_allocator)
	bare := fmt.tprintf("--plugin-dir\n%s\n--resume\n%s\n", plugin, sid)
	for caller in ([]core.Caller{CS_CONTROL, CS_SCRIPT, CS_UI}) {
		os.remove(argf)
		os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s.tmp; mv %s.tmp %s; exec sleep 30`, argf, argf, argf))
		rr := core.run_command(core.Open_Session_Cmd{project_id = pid, pi_session_id = sid}, caller)
		testing.expect(t, rr.ok, rr.error)
		s := core.find_session(rr.created_id)
		testing.expect(t, s != nil && s.agent == .Claude && s.pi_session_id == sid, "a Claude-only session")
		want := caller.kind == .UI ? fmt.tprintf("%s--model\nm\n--dangerously-skip-permissions\n", bare) : bare
		testing.expect_value(t, cs_wait_file(argf), want)
		if caller.kind == .UI do testing.expect_value(t, state.current_session, s.id)
		// again: the open one, focused for the user
		again := core.run_command(core.Open_Session_Cmd{project_id = pid, pi_session_id = sid}, CS_UI)
		testing.expect_value(t, again.created_id, s.id)
		core.run_command(core.Claude_Turn_Report{tab_id = s.tabs[0].id, state = "idle"}, CS_SCRIPT)
		core.run_command(core.Close_Session{session = s.id}, CS_UI)
	}
	// claude_resume opens a Claude-only session as well
	rr := core.run_command(core.Claude_Resume{claude_session_id = sid}, CS_UI)
	testing.expect(t, rr.ok, rr.error)
	s, _, _ := core.find_tab(rr.created_id)
	testing.expect(t, s != nil && s.agent == .Claude)
	// another project's id is not this project's row
	_, other := cs_project("resume-other")
	testing.expect(t, !core.run_command(core.Open_Session_Cmd{project_id = other, pi_session_id = sid}, CS_UI).ok)
	// the project menu: one New session (the harness picker), New Claude tab, no "Resume Claude: …" list (the rows replace it)
	menu_open(Menu_Project(pid), {})
	labels := make([dynamic]string, context.temp_allocator)
	for it in menu_items() do append(&labels, it.label)
	menu_close()
	all := strings.join(labels[:], "|", context.temp_allocator)
	testing.expect(t, strings.contains(all, "New session") && strings.contains(all, "New Claude tab") && !strings.contains(all, "New Claude session"), all)
	testing.expect(t, !strings.contains(all, "Resume Claude"), all)
}

// Saved and restored: a Claude-only session comes back not started, as a Claude-only session, and
// starts with --resume and its flags when shown. One whose id never came is not saved.
@(test)
claude_session_restore :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	dir, pid := cs_project("rs")
	sid := "c5c5c5c5-0000-4000-8000-000000000001"
	r := core.run_command(core.New_Claude_Session{project_id = pid, args = {"--verbose"}}, CS_UI)
	main := core.find_session(r.created_id).tabs[0].id
	core.run_command(core.Claude_Session_Report{tab_id = main, session_id = sid}, CS_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = main, state = "submitted", title = "restore me"}, CS_SCRIPT)
	core.run_command(core.Set_Pinned{pi_session_id = sid, pinned = true}, CS_UI)
	core.run_command(core.New_Shell_Tab{session = r.created_id}, CS_UI)
	core.run_command(core.New_Claude_Session{project_id = pid}, CS_UI) // no id yet: not saved
	core.run_command(core.Focus_Session{session = r.created_id}, CS_UI)
	text := strings.clone(core.workspace_json())
	testing.expect(t, strings.contains(text, `"agent":"claude"`), text)
	testing.expect_value(t, strings.count(text, `"agent":"claude"`), 1)
	context.allocator = cs_reset()
	argf := fmt.tprintf("%s/argv", dir)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s.tmp; mv %s.tmp %s; exec sleep 30`, argf, argf, argf))
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	s := &state.open_sessions[0]
	testing.expect_value(t, s.agent, core.Session_Agent.Claude)
	testing.expect_value(t, s.pi_session_id, sid)
	testing.expect_value(t, len(s.tabs), 2)
	ct, is := s.tabs[0].kind.(core.Claude_Tab)
	testing.expect(t, is && ct.session_id == sid && len(ct.args) == 1)
	testing.expect_value(t, s.tabs[0].status, core.Tab_Status.Not_Started)
	testing.expect_value(t, core.session_pinned(sid), 0)
	testing.expect_value(t, core.open_session_title(s), "restore me")
	core.persist_after_layout(skip = false)
	testing.expect_value(t, s.tabs[0].status, core.Tab_Status.Running)
	testing.expect(t, strings.contains(cs_wait_file(argf), fmt.tprintf("--resume\n%s\n--verbose", sid)))
	// saved again as it came
	testing.expect(t, strings.contains(core.workspace_json(), `"agent":"claude"`))
	// a tampered id drops the session, never reaching argv
	bad, _ := strings.replace_all(text, sid, "--plugin-dir", context.temp_allocator)
	context.allocator = cs_reset()
	core.rescan_now()
	core.workspace_restore(bad)
	testing.expect_value(t, len(state.open_sessions), 0)
}

// Files saved before Claude-only sessions: Claude tabs inside pi sessions and the history come
// back as they did; their Claude sessions become rows of their project.
@(test)
claude_session_migration :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	dir := cs_dir("mig")
	home := cs_dir("mig-home")
	name, _ := strings.replace_all(strings.trim_prefix(dir, "/"), "/", "-", context.temp_allocator)
	store := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
	os.make_directory_all(store)
	header := fmt.tprintf(`{{"type":"session","version":3,"id":"mig-1","cwd":"%s"}}`+"\n", dir)
	_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-00-000Z_mig-1.jsonl", store), transmute([]u8)header)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	os.set_env("HOME", home)
	core.rescan_now()
	sid := "c6c6c6c6-0000-4000-8000-000000000001"
	old := fmt.tprintf(`{{"v":1,"projects":[{{"cwd":%q}}],"selected_project":%q,
"open_sessions":[{{"pi_session_id":"mig-1","cwd":%q,"session_dir":"","project":%q,"tabs":[{{"kind":"pi"}},{{"kind":"claude","claude_session_id":%q,"cwd":%q,"args":["--verbose"]}}],"active_tab":1}}],"current_session":0,
"claude_sessions":[{{"id":%q,"cwd":%q,"project":%q,"title":"old one","used":1700000000,"args":["--verbose"]}},{{"id":"c6c6c6c6-0000-4000-8000-000000000002","cwd":%q,"project":%q,"title":"older","used":1690000000}}]}}`, dir, dir, dir, dir, sid, dir, sid, dir, dir, dir, dir)
	testing.expect_value(t, core.workspace_restore(old), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	s := &state.open_sessions[0]
	testing.expect_value(t, s.agent, core.Session_Agent.Pi)
	testing.expect_value(t, len(s.tabs), 2)
	_, is := s.tabs[1].kind.(core.Claude_Tab)
	testing.expect(t, is, "the Claude tab stays in its pi session")
	testing.expect_value(t, len(state.claude_history), 2)
	rows := cs_row_ids()
	testing.expect(t, strings.contains(rows, "old one(c)") && strings.contains(rows, "older(c)"), rows)
	// the old one's row focuses its tab (open inside the pi session)
	r := core.run_command(core.Open_Session_Cmd{project_id = s.project_id, pi_session_id = sid}, CS_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(state.open_sessions), 1)
}

// A Claude-only session whose claude exited: it stays, shows, focuses, reports and closes; nothing
// of pi's (restart, comments, the bell's pi rules) trips on it.
@(test)
claude_session_dead :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	_, pid := cs_project("dead")
	sid := "c7c7c7c7-0000-4000-8000-000000000001"
	sess, main := cs_claude_session(t, pid, sid, "dies")
	core.run_command(core.New_Chat{project_id = pid}, CS_UI) // another session on screen
	testing.expect(t, core.run_command(core.Tab_Exited{tab_id = main, exit = {known = true, code = 1}}, {kind = .Internal}).ok)
	s := core.find_session(sess)
	testing.expect(t, s != nil && s.tabs[0].status == .Exited)
	// shown (not reopened: reopening restarts it in place, claude_review_test rv_dead_dup)
	testing.expect(t, core.run_command(core.Focus_Session{session = sess}, CS_UI).ok)
	st, _ := core.session_row_status(s)
	_ = st
	_ = core.session_explain(s)
	_ = core.state_json()
	_ = core.workspace_json()
	ok, _ := core.comments_ready(s)
	testing.expect(t, !ok, "no pi to take comments")
	_ = core.open_session_title(s)
	_, _, _ = tab_label(s, s.tabs[0])
	testing.expect(t, core.run_command(core.Set_Unread{pi_session_id = sid, unread = true}, CS_UI).ok)
	testing.expect(t, !core.run_command(core.Pi_Restart{tab_id = main}, CS_UI).ok, "not a pi tab")
	r := core.run_command(core.Close_Session{session = sess}, CS_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, core.find_session(sess) == nil)
}

// Whether Claude Code is installed: a `claude` file that can run, on the login PATH or where its
// installer puts it (~/.local/bin, ~/.claude/local); found by stat only, never run.
@(test)
claude_detection :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	root := cs_dir("detect")
	bin := fmt.tprintf("%s/bin", root)
	home := fmt.tprintf("%s/home", root)
	os.make_directory_all(bin)
	os.make_directory_all(fmt.tprintf("%s/.local/bin", home))
	os.make_directory_all(fmt.tprintf("%s/.claude/local", home))
	testing.expect(t, !core.claude_detect(fmt.tprintf("/nonexistent:%s", bin), home), "nothing there")
	write :: proc(path: string, mode: u16) {
		_ = os.write_entire_file(path, transmute([]u8)string("#!/bin/sh\nexit 1\n"))
		posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), transmute(posix.mode_t)mode)
	}
	write(fmt.tprintf("%s/claude", bin), 0o644)
	testing.expect(t, !core.claude_detect(bin, home), "not executable")
	write(fmt.tprintf("%s/claude", bin), 0o755)
	testing.expect(t, core.claude_detect(fmt.tprintf("/nonexistent:%s", bin), home), "on PATH")
	testing.expect(t, !core.claude_detect("relative/bin", home), "relative PATH entries are skipped")
	os.make_directory_all(fmt.tprintf("%s/dir/claude", root))
	testing.expect(t, !core.claude_detect(fmt.tprintf("%s/dir", root), home), "a folder named claude is not claude")
	write(fmt.tprintf("%s/.local/bin/claude", home), 0o755)
	testing.expect(t, core.claude_detect("/usr/bin:/bin", home), "the native installer's ~/.local/bin")
	os.remove(fmt.tprintf("%s/.local/bin/claude", home))
	write(fmt.tprintf("%s/.claude/local/claude", home), 0o755)
	testing.expect(t, core.claude_detect("", home), "the old ~/.claude/local")
	testing.expect(t, !core.claude_detect("", "relative"), "a relative HOME is not searched")
}

// Without Claude Code: the buttons stay, say so and explain instead of opening dead tabs; agents
// get the same answer; the history's rows still list; a recheck (Refresh shell environment, a
// Claude tab that exited 127) flips it.
@(test)
claude_not_installed :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	_, pid := cs_project("missing")
	sid := "c8c8c8c8-0000-4000-8000-000000000001"
	sess, _ := cs_claude_session(t, pid, sid, "made before")
	core.run_command(core.Claude_Turn_Report{tab_id = core.find_session(sess).tabs[0].id, state = "idle"}, CS_SCRIPT)
	core.run_command(core.Close_Session{session = sess}, CS_UI)
	pisess := core.run_command(core.New_Chat{project_id = pid}, CS_UI).created_id
	// no claude anywhere: a PATH and HOME without it (the user's click looks again: it is not there)
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer {
		os.set_env("PATH", old_path)
		os.set_env("HOME", old_home)
	}
	os.set_env("PATH", "/usr/bin:/bin")
	os.set_env("HOME", cs_dir("missing-home"))
	core.claude_found = .Unknown
	n_open := len(state.open_sessions)
	for cmd in ([]core.Command{core.New_Claude_Session{project_id = pid}, core.New_Claude_Tab{session = pisess}, core.New_Claude_Tab{project_id = pid}, core.Claude_Resume{claude_session_id = sid}, core.Open_Session_Cmd{project_id = pid, pi_session_id = sid}}) {
		for caller in ([]core.Caller{CS_UI, CS_CONTROL}) {
			r := core.run_command(cmd, caller)
			testing.expectf(t, !r.ok && strings.contains(r.error, "not installed"), "%v: %v", core.command_type(cmd), r.error)
		}
	}
	testing.expect_value(t, len(state.open_sessions), n_open)
	testing.expect_value(t, len(core.find_session(pisess).tabs), 1)
	testing.expect(t, strings.contains(toast.text, "claude.ai/install.sh"), toast.text)
	testing.expect(t, strings.contains(toast.text, "npm or a managed install: code.claude.com/docs/en/setup"), toast.text) // other setups: the setup page
	// the rows still list (Deckhand's own records)
	testing.expect(t, strings.contains(cs_row_ids(), "made before(c)"), cs_row_ids())
	// the menus offer no Claude rows (one-harness users see nothing extra; harness.odin)
	menu_open(Menu_Project(pid), {})
	labels := make([dynamic]string, context.temp_allocator)
	for it in menu_items() do append(&labels, it.label)
	menu_close()
	all := strings.join(labels[:], "|", context.temp_allocator)
	testing.expect(t, !strings.contains(all, "Claude"), all)
	testing.expect(t, strings.contains(core.state_json(), `"claude_installed":false`))
	// pi works as ever
	testing.expect(t, core.run_command(core.New_Chat{project_id = pid}, CS_UI).ok)
	testing.expect(t, core.run_command(core.New_Shell_Tab{session = pisess}, CS_UI).ok)
	// a recheck: the cache is dropped and looked up again
	core.claude_found = .No
	core.run_command(core.Refresh_Shell_Env_Done{ok = false}, {kind = .Internal})
	testing.expect_value(t, core.claude_found, core.Claude_Found.Unknown)
	core.claude_found = .Yes
	tab := core.run_command(core.New_Claude_Tab{session = pisess}, CS_SCRIPT).created_id
	testing.expect(t, tab != 0)
	core.run_command(core.Tab_Exited{tab_id = tab, exit = {known = true, code = 127}}, {kind = .Internal})
	testing.expect_value(t, core.claude_found, core.Claude_Found.Unknown)
	// installed meanwhile (the native installer's ~/.local/bin): the user's next click finds it
	home := os.get_env("HOME", context.temp_allocator)
	os.make_directory_all(fmt.tprintf("%s/.local/bin", home))
	_ = os.write_entire_file(fmt.tprintf("%s/.local/bin/claude", home), transmute([]u8)string("#!/bin/sh\nexit 1\n"))
	posix.chmod(strings.clone_to_cstring(fmt.tprintf("%s/.local/bin/claude", home), context.temp_allocator), transmute(posix.mode_t)u16(0o755))
	core.claude_found = .No
	testing.expect(t, core.run_command(core.New_Claude_Session{project_id = pid}, CS_UI).ok, "found again at the click")
}

// Restored Claude tabs and sessions when claude has gone since: not started (no process), each
// says why in its terminal, no bell entry; the session stays usable and closable, and a later
// focus does not try again in a loop.
@(test)
claude_restore_not_installed :: proc(t: ^testing.T) {
	context.allocator = cs_reset()
	_, pid := cs_project("rs-missing")
	sid := "c9c9c9c9-0000-4000-8000-000000000001"
	cs_claude_session(t, pid, sid, "will be gone")
	text := strings.clone(core.workspace_json())
	context.allocator = cs_reset()
	core.claude_found = .No
	// still missing when looked up again (the real lookup would find this machine's claude)
	core.claude_installed_probe = proc() -> bool {return false}
	defer core.claude_installed_probe = nil
	marker := fmt.tprintf("%s/ran", cs_dir("rs-missing-ran"))
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`touch %s; exec sleep 30`, marker))
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	s := &state.open_sessions[0]
	core.persist_after_layout(skip = false)
	testing.expect_value(t, s.tabs[0].status, core.Tab_Status.Exited)
	testing.expect_value(t, len(state.notices.items), 0)
	time.sleep(200 * time.Millisecond)
	testing.expect(t, !os.exists(marker), "claude never started")
	tm := core.term_of(s.tabs[0].id)
	testing.expect(t, tm != nil && !tm.running, "a terminal with the note, no process")
	core.pump_all()
	testing.expect_value(t, len(state.notices.items), 0)
	testing.expect(t, core.run_command(core.Focus_Session{session = s.id, reopen = true}, CS_UI).ok)
	r := core.run_command(core.Close_Session{session = s.id}, CS_UI)
	testing.expect(t, r.ok, r.error)
}
