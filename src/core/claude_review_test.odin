package core

// Claude sessions, review round 1 (claude.odin; docs/CLAUDE.md §1, §3, §4): a Claude tab cannot
// take a pi session's id; a dead Claude-only session resumes in place; agents never start restored
// Claude tabs (the user's saved flags); the history is checked on load. (Claude in chats:
// claude_chats_test.odin.)
// Starts from the reviewer's rv_collision and rv_dead_dup.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
RV_UI :: Caller{kind = .UI}
@(private = "file")
RV_SCRIPT :: Caller{kind = .Script}
@(private = "file")
RV_CONTROL :: Caller{kind = .Control}

@(private = "file")
rv_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	persist = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	claude_found = .Yes
	return runtime.heap_allocator()
}

@(private = "file")
rv_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-rv-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

@(private = "file")
rv_project :: proc(tag: string) -> (dir: string, pid: u64) {
	dir = rv_dir(tag)
	pid = run_command(Add_Project{cwd = dir}, RV_UI).created_id
	return
}

// A project with one pi session file in a pi store under a temp HOME (HOME is set; restore it).
@(private = "file")
rv_store_project :: proc(tag, pi_id: string) -> (dir: string, pid: u64) {
	dir = rv_dir(tag)
	home := rv_dir(fmt.tprintf("%s-home", tag))
	name, _ := strings.replace_all(strings.trim_prefix(dir, "/"), "/", "-", context.temp_allocator)
	store := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
	os.make_directory_all(store)
	header := fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", pi_id, dir)
	_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-00-000Z_%s.jsonl", store, pi_id), transmute([]u8)header)
	os.set_env("HOME", home)
	rescan_now()
	for p in state.projects do if p.cwd == dir do pid = p.id
	run_command(Select_Project{project_id = pid}, RV_UI)
	return
}

@(private = "file")
rv_wait_file :: proc(path: string) -> string {
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 do return string(data)
		time.sleep(20 * time.Millisecond)
	}
	return ""
}

@(private = "file")
rv_keyed :: proc(id: string) -> int {
	n := 0
	for x in state.open_sessions do if !x.home && x.pi_session_id == id do n += 1
	return n
}

// A Claude tab cannot claim a pi session's id (a prompt-injected Claude reporting its own pi
// session's id would make the pi row resume Claude); open_session finds the pi file first; a
// history entry with a pi id (older data) is not a second row; two open Claude-only sessions
// never share one key.
@(test)
rv_collision :: proc(t: ^testing.T) {
	context.allocator = rv_reset()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	P := "rvp-1"
	_, pid := rv_store_project("col", P)
	r := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = P}, RV_UI)
	testing.expect(t, r.ok, r.error)
	sid := r.created_id
	ct := run_command(New_Claude_Tab{session = sid}, RV_UI).created_id
	rep := run_command(Claude_Session_Report{tab_id = ct, session_id = P}, RV_SCRIPT)
	testing.expect(t, !rep.ok, "a pi session's id is not a Claude session's")
	testing.expect(t, claude_open_tab(P) == 0)
	rec, _ := claude_record(P)
	testing.expect(t, rec == nil, "not in the history")
	// older data: a history entry holding the pi id; the pi row still opens pi, listed once
	run_command(Claude_Turn_Report{tab_id = ct, state = "idle"}, RV_SCRIPT)
	run_command(Close_Session{session = sid}, {kind = .Internal})
	run_command(Claude_Restore_History{records = {{id = P, cwd = "", project = find_project(pid).cwd, title = "poisoned", used = 1}}}, {kind = .Internal})
	n := 0
	for row in sidebar_sessions(.Sessions) do if row.session.id == P do n += 1
	testing.expect_value(t, n, 1)
	o := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = P}, RV_UI)
	s := find_session(o.created_id)
	testing.expect(t, o.ok && s != nil && s.agent == .Pi, "the pi session opens")
	// another open session's key (a pi one, or a Claude-only one) is refused too
	a := run_command(New_Claude_Session{project_id = pid}, RV_UI).created_id
	ka := "a1a1a1a1-0000-4000-8000-000000000001"
	run_command(Claude_Session_Report{tab_id = find_session(a).tabs[0].id, session_id = ka}, RV_SCRIPT)
	b := run_command(New_Claude_Session{project_id = pid}, RV_UI).created_id
	bt := find_session(b).tabs[0].id
	testing.expect(t, !run_command(Claude_Session_Report{tab_id = bt, session_id = ka}, RV_SCRIPT).ok, "a /resume to a conversation another session runs")
	testing.expect_value(t, rv_keyed(ka), 1)
	testing.expect(t, !run_command(Claude_Session_Report{tab_id = bt, session_id = P}, RV_SCRIPT).ok, "the open pi session's id")
}

// A dead Claude-only session: open_session and claude_resume start its main tab again in place
// (flags only for the user), never a second session with its key.
@(test)
rv_dead_dup :: proc(t: ^testing.T) {
	context.allocator = rv_reset()
	dir, pid := rv_project("dead")
	sidc := "d1d1d1d1-0000-4000-8000-000000000001"
	r := run_command(New_Claude_Session{project_id = pid, args = {"--verbose"}}, RV_UI)
	main := find_session(r.created_id).tabs[0].id
	run_command(Claude_Session_Report{tab_id = main, session_id = sidc}, RV_SCRIPT)
	argf := fmt.tprintf("%s/argv", dir)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s.tmp; mv %s.tmp %s; exec sleep 30`, argf, argf, argf))
	run_command(Tab_Exited{tab_id = main, exit = {known = true, code = 0}}, {kind = .Internal})
	o := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = sidc}, RV_UI)
	testing.expect_value(t, o.created_id, r.created_id)
	s := find_session(r.created_id)
	testing.expect_value(t, s.tabs[0].status, Tab_Status.Running)
	testing.expect(t, strings.contains(rv_wait_file(argf), fmt.tprintf("--resume\n%s\n--verbose", sidc)), "the user's: with its flags")
	os.remove(argf)
	run_command(Tab_Exited{tab_id = s.tabs[0].id, exit = {known = true, code = 0}}, {kind = .Internal})
	cr := run_command(Claude_Resume{claude_session_id = sidc}, RV_CONTROL)
	testing.expect(t, cr.ok, cr.error)
	testing.expect_value(t, rv_keyed(sidc), 1)
	testing.expect_value(t, find_session(r.created_id).tabs[0].status, Tab_Status.Running)
	got := rv_wait_file(argf)
	testing.expect(t, strings.contains(got, sidc) && !strings.contains(got, "--verbose"), got)
}

// Restored without Claude Code, installed since: the user's open_session starts it (the cached
// "not installed" is looked up again).
@(test)
rv_restore_then_install :: proc(t: ^testing.T) {
	context.allocator = rv_reset()
	// one HOME throughout: the Claude session's account (~/.claude) is the same after the relaunch
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator))
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer {
		os.set_env("PATH", old_path)
		os.set_env("HOME", old_home)
	}
	home := rv_dir("inst-home")
	os.set_env("HOME", home)
	_, pid := rv_project("inst")
	sidc := "e1e1e1e1-0000-4000-8000-000000000001"
	r := run_command(New_Claude_Session{project_id = pid}, RV_UI)
	run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = sidc}, RV_SCRIPT)
	text := strings.clone(workspace_json())
	context.allocator = rv_reset()
	os.set_env("PATH", "/usr/bin:/bin")
	claude_found = .Unknown
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	persist_after_layout(skip = false)
	s := &state.open_sessions[0]
	testing.expect_value(t, s.tabs[0].status, Tab_Status.Exited)
	// installed (the native installer's place)
	os.make_directory_all(fmt.tprintf("%s/.local/bin", home))
	_ = os.write_entire_file(fmt.tprintf("%s/.local/bin/claude", home), transmute([]u8)string("#!/bin/sh\nexit 1\n"))
	posix.chmod(strings.clone_to_cstring(fmt.tprintf("%s/.local/bin/claude", home), context.temp_allocator), transmute(posix.mode_t)u16(0o755))
	o := run_command(Open_Session_Cmd{project_id = s.project_id, pi_session_id = sidc}, RV_UI)
	testing.expect(t, o.ok, o.error)
	testing.expect_value(t, rv_keyed(sidc), 1)
	testing.expect_value(t, state.open_sessions[0].tabs[0].status, Tab_Status.Running)
	// and a restored tab not started yet looks again too, when its session is focused
	context.allocator = rv_reset()
	claude_found = .No
	rescan_now()
	workspace_restore(text)
	state.current_session = 0
	run_command(Focus_Session{session = state.open_sessions[0].id}, RV_UI)
	testing.expect_value(t, state.open_sessions[0].tabs[0].status, Tab_Status.Running)
}

// Agents (Atlas) bringing up a restored session never start its Claude tabs (they would run with
// the user's saved flags): they stay not started until the user shows them.
@(test)
rv_agents_do_not_start_restored :: proc(t: ^testing.T) {
	context.allocator = rv_reset()
	dir, pid := rv_project("agents")
	sidc := "f1f1f1f1-0000-4000-8000-000000000001"
	r := run_command(New_Claude_Session{project_id = pid, args = {"--dangerously-skip-permissions"}}, RV_UI)
	run_command(Claude_Session_Report{tab_id = find_session(r.created_id).tabs[0].id, session_id = sidc}, RV_SCRIPT)
	sidp := "f1f1f1f1-0000-4000-8000-000000000002"
	r2 := run_command(New_Claude_Session{project_id = pid, args = {"--dangerously-skip-permissions"}}, RV_UI)
	run_command(Claude_Session_Report{tab_id = find_session(r2.created_id).tabs[0].id, session_id = sidp}, RV_SCRIPT)
	text := strings.clone(workspace_json())
	context.allocator = rv_reset()
	argf := fmt.tprintf("%s/argv", dir)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > %s.tmp; mv %s.tmp %s; exec sleep 30`, argf, argf, argf))
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	a, b := &state.open_sessions[0], &state.open_sessions[1]
	pidA := a.project_id
	for cmd in ([]Command{Open_Session_Cmd{project_id = pidA, pi_session_id = sidc}, Focus_Session{session = a.id, reopen = true}, Focus_Tab{tab_id = a.tabs[0].id}, Claude_Resume{claude_session_id = sidc}}) {
		rr := run_command(cmd, RV_CONTROL)
		testing.expectf(t, rr.ok, "%v: %v", command_type(cmd), rr.error)
		testing.expectf(t, a.tabs[0].status == .Not_Started, "%v by an agent: not started", command_type(cmd))
	}
	testing.expect(t, !os.exists(argf), "claude never ran for the agent")
	testing.expect(t, strings.contains(state_json(), `"not_started"`), "agents see it waiting")
	// the user's
	run_command(Focus_Session{session = b.id}, RV_UI)
	testing.expect_value(t, b.tabs[0].status, Tab_Status.Running)
	testing.expect(t, strings.contains(rv_wait_file(argf), "--dangerously-skip-permissions"))
}

// The history from the saved file is checked like a report: no flags Deckhand sets, one-line
// titles of at most 80 characters, ids that can go into argv.
@(test)
rv_history_checked_on_load :: proc(t: ^testing.T) {
	context.allocator = rv_reset()
	run_command(Claude_Restore_History{records = {
		{id = "aaaa1111-0000-4000-8000-000000000001", project = "/p", title = "line one\nline two", used = 1},
		{id = "aaaa1111-0000-4000-8000-000000000002", project = "/p", title = "flags", used = 1, args = {"--resume", "x"}},
		{id = "aaaa1111-0000-4000-8000-000000000003", project = "/p", title = strings.repeat("x", 200, context.temp_allocator), used = 1},
		{id = "aaaa1111-0000-4000-8000-000000000004", project = "relative", title = "r", used = 1},
	}}, {kind = .Internal})
	testing.expect_value(t, len(state.claude_history), 2)
	r1, _ := claude_record("aaaa1111-0000-4000-8000-000000000001")
	testing.expect(t, r1 != nil && r1.title == "line one line two")
	r3, _ := claude_record("aaaa1111-0000-4000-8000-000000000003")
	testing.expect(t, r3 != nil && len(r3.title) <= CLAUDE_TITLE_MAX)
}
