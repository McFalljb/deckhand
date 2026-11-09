package main

// Claude sessions, review round 2 (claude.odin; docs/CLAUDE.md §3, §4): no agent path starts a
// restored Claude tab (focus_session takes the real caller); a saved chat's Claude tab does not
// come back and cannot start; new_claude_tab's resume goes through the same id checks as
// claude_resume.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
R2_UI :: core.Caller{kind = .UI}
@(private = "file")
R2_SCRIPT :: core.Caller{kind = .Script}
@(private = "file")
R2_CONTROL :: core.Caller{kind = .Control}

@(private = "file")
r2_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.persist = {}
	core.platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	core.claude_found = .Yes
	return runtime.heap_allocator()
}

@(private = "file")
r2_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-r2-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

@(private = "file")
r2_claude_tabs :: proc(id: string) -> int {
	n := 0
	for s in state.open_sessions do for tab in s.tabs do if ct, is := tab.kind.(core.Claude_Tab); is && ct.session_id == id do n += 1
	return n
}

// Two restored Claude-only sessions: A (its Claude tab not started yet) and B on screen; claude's
// argv goes to the returned log at each start (A's id in it = A started).
@(private = "file")
R2_A :: "b2b2b2b2-0000-4000-8000-000000000001"

@(private = "file")
r2_restored :: proc(t: ^testing.T, tag: string) -> (a, b: ^core.Open_Session, dir, log: string) {
	context.allocator = r2_reset()
	dir = r2_dir(tag)
	pid := core.run_command(core.Add_Project{cwd = dir}, R2_UI).created_id
	sa := core.run_command(core.New_Claude_Session{project_id = pid}, R2_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = core.find_session(sa).tabs[0].id, session_id = R2_A}, R2_SCRIPT)
	sb := core.run_command(core.New_Claude_Session{project_id = pid}, R2_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = core.find_session(sb).tabs[0].id, session_id = "b2b2b2b2-0000-4000-8000-000000000002"}, R2_SCRIPT)
	text := strings.clone(core.workspace_json())
	context.allocator = r2_reset()
	log = fmt.tprintf("%s/argv.log", dir)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" >> %s; exec sleep 30`, log))
	core.rescan_now()
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 2)
	if len(state.open_sessions) < 2 do return
	a, b = &state.open_sessions[0], &state.open_sessions[1]
	if a.pi_session_id != R2_A do a, b = b, a
	state.current_session = b.id
	return
}

@(private = "file")
r2_a_ran :: proc(log: string) -> bool {
	time.sleep(150 * time.Millisecond)
	data, _ := os.read_entire_file(log, context.temp_allocator)
	return strings.contains(string(data), R2_A)
}

@(private = "file")
r2_claude_status :: proc(s: ^core.Open_Session) -> core.Tab_Status {
	for tab in s.tabs do if _, is := tab.kind.(core.Claude_Tab); is do return tab.status
	return .Exited
}

// An agent's new_shell_tab, open_file and close_session that bring a restored session to the
// front leave its Claude tab not started (it would run with the user's saved flags).
@(test)
r2_agent_shell_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	{
		a, _, _, log := r2_restored(t, "shell")
		if a == nil do return
		r := core.run_command(core.New_Shell_Tab{session = a.id}, R2_CONTROL)
		testing.expect(t, r.ok, r.error)
		testing.expect_value(t, r2_claude_status(a), core.Tab_Status.Not_Started)
		testing.expect(t, !r2_a_ran(log), "new_shell_tab: claude never ran")
	}
}

@(test)
r2_agent_open_file :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	{
		a, _, dir, log := r2_restored(t, "file")
		if a == nil do return
		f := fmt.tprintf("%s/notes.txt", dir)
		_ = os.write_entire_file(f, transmute([]u8)string("hi\n"))
		r := core.run_command(core.Open_File{path = f, session = a.id}, R2_CONTROL)
		testing.expect(t, r.ok, r.error)
		testing.expect_value(t, r2_claude_status(a), core.Tab_Status.Not_Started)
		testing.expect(t, !r2_a_ran(log), "open_file: claude never ran")
	}
}

@(test)
r2_agent_close_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	{
		a, b, _, log := r2_restored(t, "close")
		if a == nil do return
		r := core.run_command(core.Close_Session{session = b.id}, R2_CONTROL)
		if !r.ok && r.confirm_token != "" do r = core.run_command(core.Close_Session{session = b.id, confirm = r.confirm_token}, R2_CONTROL)
		testing.expect(t, r.ok, r.error)
		testing.expect_value(t, len(state.open_sessions), 1)
		a = &state.open_sessions[0]
		testing.expect_value(t, r2_claude_status(a), core.Tab_Status.Not_Started)
		testing.expect(t, !r2_a_ran(log), "close_session: claude never ran")
		// the user's
		core.run_command(core.Focus_Session{session = a.id}, R2_UI)
		testing.expect_value(t, r2_claude_status(a), core.Tab_Status.Running)
	}
}

// A saved chat with a Claude tab and a Claude-only chat come back (Claude in chats, claude.odin):
// an agent's focus starts nothing; the user's starts the Claude chat read-only while chats are
// (the profile is applied at the start, the saved tab had none; the pi chat here is gone, its
// session file missing, so its tabs stay not started).
@(test)
r2_chat_claude_restored :: proc(t: ^testing.T) {
	context.allocator = r2_reset()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	old_root := core.home_root
	defer {
		os.set_env("HOME", old_home)
		core.home_root = old_root
		core.claude_cli_override = ""
	}
	core.home_root = r2_dir("chat-data")
	os.set_env("HOME", r2_dir("chat-home"))
	dir := r2_dir("chat-mark")
	log := fmt.tprintf("%s/argv", dir)
	core.claude_cli_override = fmt.tprintf("%s/deckhand-cli", dir)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$*" >> %s; exec sleep 30`, log))
	core.rescan_now()
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	os.make_directory_all(c.cwd)
	core.run_command(core.Set_Chats_Readonly{on = true}, R2_UI)
	sid1 := "c3c3c3c3-0000-4000-8000-000000000001"
	sid2 := "c3c3c3c3-0000-4000-8000-000000000002"
	text := fmt.tprintf(`{{"v":1,"open_sessions":[{{"pi_session_id":"chat-pi-1","cwd":%q,"session_dir":"","project":%q,"chat":true,"tabs":[{{"kind":"pi"}},{{"kind":"claude","claude_session_id":%q,"cwd":%q,"args":["--dangerously-skip-permissions"]}}],"active_tab":1}},{{"agent":"claude","claude_session_id":%q,"pi_session_id":"","cwd":%q,"session_dir":"","project":%q,"chat":true,"tabs":[{{"kind":"claude","claude_session_id":%q,"cwd":%q}}],"active_tab":0}}],"current_session":0,
"claude_sessions":[{{"id":%q,"cwd":%q,"project":%q,"title":"in a chat","used":1700000000}}]}}`, c.cwd, c.cwd, sid1, c.cwd, sid2, c.cwd, c.cwd, sid2, c.cwd, sid1, c.cwd, c.cwd)
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, r2_claude_tabs(sid1), 1)
	testing.expect_value(t, r2_claude_tabs(sid2), 1)
	claude_chat := false
	for &s in state.open_sessions do if s.agent == .Claude && core.open_session_is_chat(&s) do claude_chat = true
	testing.expect(t, claude_chat, "the Claude-only chat is back, in Chats")
	// an agent's focus: nothing starts
	for &s in state.open_sessions do core.run_command(core.Focus_Session{session = s.id}, R2_CONTROL)
	time.sleep(100 * time.Millisecond)
	testing.expect(t, !os.exists(log), "an agent never starts them")
	// the user's: read-only, the saved bypass left out
	for &s in state.open_sessions do core.run_command(core.Focus_Session{session = s.id, reopen = true}, R2_UI)
	data := ""
	for _ in 0 ..< 200 {
		if d, err := os.read_entire_file(log, context.temp_allocator); err == nil && strings.count(string(d), "\n") >= 1 {data = string(d);break}
		time.sleep(20 * time.Millisecond)
	}
	lines := strings.split(strings.trim_space(data), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 1) // the Claude-only chat; the pi chat's session file is gone (missing: nothing of it starts)
	for l in lines {
		testing.expectf(t, strings.contains(l, "--permission-mode plan") && strings.contains(l, "--disallowedTools"), "read-only: %s", l)
		testing.expectf(t, !strings.contains(l, "dangerously"), "no bypass: %s", l)
	}
}

// new_claude_tab with resume: an id whose tab is dead elsewhere starts that tab again in place
// (never a second tab for one conversation); a pi session's id, or another open session's key,
// is refused.
@(test)
r2_new_tab_resume_checked :: proc(t: ^testing.T) {
	context.allocator = r2_reset()
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	dir := r2_dir("resume")
	home := r2_dir("resume-home")
	name, _ := strings.replace_all(strings.trim_prefix(dir, "/"), "/", "-", context.temp_allocator)
	store := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
	os.make_directory_all(store)
	P := "r2pi-1"
	_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-00-000Z_%s.jsonl", store, P), transmute([]u8)fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", P, dir))
	os.set_env("HOME", home)
	core.rescan_now()
	pid: u64
	for p in state.projects do if p.cwd == dir do pid = p.id
	testing.expect(t, pid != 0)
	X := "d2d2d2d2-0000-4000-8000-000000000001"
	a := core.run_command(core.New_Chat{project_id = pid}, R2_UI).created_id
	xt := core.run_command(core.New_Claude_Tab{session = a}, R2_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = xt, session_id = X}, R2_SCRIPT)
	core.run_command(core.Tab_Exited{tab_id = xt, exit = {known = true, code = 0}}, {kind = .Internal})
	b := core.run_command(core.New_Chat{project_id = pid}, R2_UI).created_id
	r := core.run_command(core.New_Claude_Tab{session = b, resume = X}, R2_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, r.created_id, xt)
	testing.expect_value(t, r2_claude_tabs(X), 1)
	_, tab, _ := core.find_tab(xt)
	testing.expect(t, tab != nil && tab.status == .Running, "started again in place")
	// a pi session's id: refused, from anyone
	for caller in ([]core.Caller{R2_UI, R2_SCRIPT, R2_CONTROL}) {
		rp := core.run_command(core.New_Claude_Tab{session = b, resume = P}, caller)
		testing.expectf(t, !rp.ok, "%v: a pi session's id", caller.kind)
	}
	// another open Claude-only session's key
	k := core.run_command(core.New_Claude_Session{project_id = pid}, R2_UI).created_id
	K := "d2d2d2d2-0000-4000-8000-000000000002"
	core.run_command(core.Claude_Session_Report{tab_id = core.find_session(k).tabs[0].id, session_id = K}, R2_SCRIPT)
	rk := core.run_command(core.New_Claude_Tab{session = b, resume = K}, R2_UI)
	testing.expect(t, rk.ok && rk.created_id == core.find_session(k).tabs[0].id, "its own tab, focused")
	testing.expect_value(t, r2_claude_tabs(K), 1)
}
