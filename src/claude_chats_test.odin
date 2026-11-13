package main

// Claude in chats (claude.odin; docs/CLAUDE.md §3): Claude-only chats and Claude tabs in pi chats
// start like a project's, as full agents (what a chat's agent may do is the chats folder's
// AGENTS.md / CLAUDE.md's to say); the user's default flags apply at the starts the user makes.

import "base:runtime"
import "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"
import gh "ghostty"

@(private = "file")
CH_UI :: core.Caller{kind = .UI}
@(private = "file")
CH_SCRIPT :: core.Caller{kind = .Script}
@(private = "file")
CH_CONTROL :: core.Caller{kind = .Control}

@(private = "file")
ch_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-ch-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

// A fresh state with a Chats entry (temp HOME and data dir); claude's argv goes to argf at each
// start.
@(private = "file")
Ch_Env :: struct {
	home, root, argf, cli: string,
}

@(private = "file")
ch_reset :: proc(env: ^Ch_Env, keep_dirs := false) -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.persist = {}
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	core.claude_found = .Yes
	if !keep_dirs {
		env.home = ch_dir("home")
		env.root = ch_dir("data")
		d := ch_dir("argv")
		env.argf = fmt.aprintf("%s/argv", d)

		// the CLI's path, with a space and a quote (the hook's command line quotes it)
		cdir := fmt.aprintf("%s/it's here", ch_dir("cli"))
		os.make_directory_all(cdir)
		env.cli = fmt.aprintf("%s/deckhand-cli", cdir)
		_ = os.write_entire_file(env.cli, transmute([]u8)string("#!/bin/sh\nexit 0\n"))
	}
	core.claude_cli_override = env.cli
	os.set_env("HOME", env.home)
	core.home_root = env.root
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s.tmp'; mv '%s.tmp' '%s'; exec sleep 30`, env.argf, env.argf, env.argf))
	core.rescan_now()
	return runtime.heap_allocator()
}

@(private = "file")
ch_done :: proc(old_home: string, old_root: string) {
	os.set_env("HOME", old_home)
	core.home_root = old_root
	core.claude_cli_override = ""
}

// claude's argv at its next start (call ch_clear before the start)
@(private = "file")
ch_argv :: proc(env: Ch_Env) -> []string {
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(env.argf, context.temp_allocator); err == nil && len(data) > 0 {
			return strings.split(strings.trim_right(string(data), "\n"), "\n", context.temp_allocator)
		}
		time.sleep(20 * time.Millisecond)
	}
	return nil
}


@(private = "file")
ch_clear :: proc(env: Ch_Env) {
	os.remove(env.argf)
}

@(private = "file")
ch_has :: proc(argv: []string, a: string) -> bool {
	for x in argv do if x == a do return true
	return false
}

// The value after flag `f` ("" = none).
@(private = "file")
ch_after :: proc(argv: []string, f: string) -> string {
	for x, i in argv do if x == f && i + 1 < len(argv) do return argv[i + 1]
	return ""
}


@(private = "file")
ch_full :: proc(t: ^testing.T, argv: []string, loc := #caller_location) {
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expectf(t, len(argv) > 0, "claude started", loc = loc)
	testing.expectf(t, !ch_has(argv, "--disallowedTools") && !ch_has(argv, "plan") && !ch_has(argv, "--settings"), "a full agent: %s", joined, loc = loc)
}


// A Claude chat and a Claude tab in a pi chat start like a project's (the user's flags, a full
// agent); the chat's row lists in Chats, marked Claude.
@(test)
ch_chats_full :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	testing.expect(t, c != nil)
	if c == nil do return
	ch_clear(env)
	r := core.run_command(core.New_Claude_Session{project_id = c.id, args = {"--dangerously-skip-permissions"}}, CH_UI)
	testing.expect(t, r.ok, r.error)
	argv := ch_argv(env)
	ch_full(t, argv)
	testing.expect(t, ch_has(argv, "--dangerously-skip-permissions"), "the user's flags")
	s := core.find_session(r.created_id)
	testing.expect(t, s != nil && s.agent == .Claude && core.open_session_is_chat(s))
	if s == nil do return
	core.run_command(core.Claude_Session_Report{tab_id = s.tabs[0].id, session_id = "c1c1c1c1-0000-4000-8000-0000000000aa"}, CH_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = s.tabs[0].id, state = "submitted", title = "chat about cats"}, CH_SCRIPT)
	found := false
	for row in core.sidebar_sessions(.Chats) do if row.session.claude && row.session.title == "chat about cats" do found = true
	testing.expect(t, found, "its row in Chats")
	// a Claude tab in a pi chat: the user's, and an agent's
	chat := core.run_command(core.New_Chat{project_id = c.id}, CH_UI).created_id
	ch_clear(env)
	rt := core.run_command(core.New_Claude_Tab{session = chat}, CH_UI)
	testing.expect(t, rt.ok, rt.error)
	ch_full(t, ch_argv(env))
	ch_clear(env)
	ra := core.run_command(core.New_Claude_Tab{session = chat}, CH_CONTROL)
	testing.expect(t, ra.ok, ra.error)
	ch_full(t, ch_argv(env))
}

// The actions and menus offer Claude in chats: "New chat"'s harness picker (harness.odin) lists
// Claude Code, and a Claude tab in a pi chat.
@(test)
ch_chats_offered :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.claude_installed_probe = proc() -> bool {return true}
	testing.expect(t, action_ok("new_chat"), "New chat")
	all_choices := ""
	for it in core.new_session_choices(c, "") do all_choices = strings.concatenate({all_choices, it.label, "|"}, context.temp_allocator)
	testing.expect(t, strings.contains(all_choices, "Claude Code"), all_choices)
	core.claude_installed_probe = nil
	chat := core.run_command(core.New_Chat{project_id = c.id}, CH_UI).created_id
	testing.expect(t, action_ok("new_claude_tab"), "with a chat on screen")
	menu_open(Menu_Session{project_id = c.id, pi_session_id = core.find_session(chat).pi_session_id}, {})
	labels := make([dynamic]string, context.temp_allocator)
	for it in menu_items() do append(&labels, it.label)
	menu_close()
	all := strings.join(labels[:], "|", context.temp_allocator)
	testing.expect(t, strings.contains(all, "New Claude tab"), all)
	// not installed: not offered, and refused
	core.claude_found = .No
	core.claude_installed_probe = proc() -> bool {return false}
	defer core.claude_installed_probe = nil
	for it in core.new_session_choices(c, "") do testing.expect(t, !strings.contains(it.label, "Claude"), it.label)
	testing.expect(t, !core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI).ok)
}

// The user's default flags (Settings: "Default Claude Code flags for new tabs"; off by default).
// The CURRENT setting applies at each start the user makes (a new tab, session or chat, the
// user's resume, restore and restart): it is never saved into a tab's or a record's flags, so
// turning it off takes it away from them all. Agents' starts never get it; at the flag cap it is
// left out; only the user turns it on, after confirming.
@(test)
ch_default_flags :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	SKIP :: "--dangerously-skip-permissions"
	args_of :: proc(id: u64) -> string {
		_, _, ct := core.claude_tab_of(id)
		return ct != nil ? strings.join(ct.args, " ", context.temp_allocator) : "<none>"
	}
	// start: clear the argv file, run, wait for this start's argv (a late write never lands in
	// the next check)
	start :: proc(env: Ch_Env, cmd: core.Command, caller: core.Caller) -> (core.Result, []string) {
		ch_clear(env)
		r := core.run_command(cmd, caller)
		if !r.ok do return r, nil
		return r, ch_argv(env)
	}
	// a dead tab started again, by the user or an agent
	restart :: proc(env: Ch_Env, tab: u64, caller: core.Caller) -> []string {
		core.drop_term(tab)
		core.run_command(core.Tab_Exited{tab_id = tab, exit = {known = true, code = 1}}, {kind = .Internal})
		ch_clear(env)
		if r := core.run_command(core.Claude_Restart{tab_id = tab}, caller); !r.ok do return nil
		return ch_argv(env)
	}
	on :: proc(t: ^testing.T) {
		r := core.run_command(core.Set_Claude_Default_Flags{skip_permissions = true}, CH_UI)
		testing.expect_value(t, r.error, "needs_confirmation") // the user confirms, with the warning
		testing.expect(t, strings.contains(r.confirm_summary, "without asking"), r.confirm_summary)
		testing.expect(t, !state.settings.claude_skip_permissions, "not before the confirmation")
		testing.expect(t, core.run_command(core.Set_Claude_Default_Flags{skip_permissions = true, confirm = r.confirm_token}, CH_UI).ok)
		testing.expect(t, state.settings.claude_skip_permissions)
	}
	off :: proc(t: ^testing.T) {
		testing.expect(t, core.run_command(core.Set_Claude_Default_Flags{skip_permissions = false}, CH_UI).ok, "off: no confirmation")
		testing.expect(t, !state.settings.claude_skip_permissions)
	}
	pdir := ch_dir("defaults")
	pid := core.run_command(core.Add_Project{cwd = pdir}, CH_UI).created_id
	sess := core.run_command(core.New_Chat{project_id = pid}, CH_UI).created_id
	// off (the default): nothing changes
	testing.expect(t, !state.settings.claude_skip_permissions, "off by default")
	r, argv := start(env, core.New_Claude_Tab{session = sess}, CH_UI)
	testing.expect(t, r.ok && !ch_has(argv, SKIP))
	// only the user turns it on (an agent's, a Claude tab's: refused)
	testing.expect(t, !core.run_command(core.Set_Claude_Default_Flags{skip_permissions = true}, CH_CONTROL).ok, "an agent may not")
	testing.expect(t, !core.run_command(core.Set_Claude_Default_Flags{skip_permissions = true}, core.Caller{kind = .Panel, tab_id = r.created_id, claude = true}).ok, "a Claude tab may not")
	testing.expect(t, !state.settings.claude_skip_permissions)
	on(t)
	// the user's new tab: in argv, never in the tab's saved flags
	r, argv = start(env, core.New_Claude_Tab{session = sess}, CH_UI)
	testing.expect(t, ch_has(argv, SKIP), "in claude's argv")
	testing.expect_value(t, args_of(r.created_id), "")
	// the user's own flags: kept (saved), the default after them; never twice; a permission mode wins
	r, argv = start(env, core.New_Claude_Tab{session = sess, args = {"--model", "opus"}}, CH_UI)
	testing.expect_value(t, args_of(r.created_id), "--model opus")
	testing.expect_value(t, ch_after(argv, "opus"), SKIP)
	_, argv = start(env, core.New_Claude_Tab{session = sess, args = {SKIP}}, CH_UI)
	n := 0
	for a in argv do if a == SKIP do n += 1
	testing.expect_value(t, n, 1)
	_, argv = start(env, core.New_Claude_Tab{session = sess, args = {"--permission-mode", "plan"}}, CH_UI)
	testing.expect(t, !ch_has(argv, SKIP), "an explicit permission mode wins")
	// at the flag cap: left out, silently (the tab starts)
	full := make([]string, core.CLAUDE_ARGS_MAX, context.temp_allocator)
	for &a in full do a = "--verbose"
	r, argv = start(env, core.New_Claude_Tab{session = sess, args = full}, CH_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, !ch_has(argv, SKIP), "not past the cap")
	r, argv = start(env, core.New_Claude_Session{project_id = pid, args = full}, CH_UI)
	testing.expect(t, r.ok, r.error)
	// the user's new Claude session
	r, argv = start(env, core.New_Claude_Session{project_id = pid}, CH_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, ch_has(argv, SKIP), "the session's claude has it")
	// an agent's tab and session: never
	ra, aargv := start(env, core.New_Claude_Tab{session = sess}, CH_CONTROL)
	aid := ra.created_id
	testing.expect(t, aid != 0 && !ch_has(aargv, SKIP), "an agent's tab")
	rs, sargv := start(env, core.New_Claude_Session{project_id = pid}, CH_CONTROL)
	testing.expect(t, rs.ok && !ch_has(sargv, SKIP), "an agent's session")
	// a conversation an agent started: an agent's resume never, the user's with the setting now
	sid := "0d0d0d0d-1111-4222-8333-444455556666"
	testing.expect(t, core.run_command(core.Claude_Session_Report{tab_id = aid, session_id = sid, source = "startup"}, CH_SCRIPT).ok)
	core.run_command(core.Claude_Turn_Report{tab_id = aid, state = "idle"}, CH_SCRIPT)
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = aid}, CH_UI).ok)
	close_it :: proc(tab: u64) {
		if rs, _, _ := core.find_tab(tab); rs != nil {
			rsid := rs.id
			core.run_command(core.Close_Session{session = rsid, confirm = ""}, CH_UI)
			for &p in state.pending_confirmations do core.run_command(core.Close_Session{session = rsid, confirm = p.token}, CH_UI)
		}
	}
	rc, cargv := start(env, core.Claude_Resume{claude_session_id = sid}, CH_CONTROL)
	testing.expect(t, rc.ok && !ch_has(cargv, SKIP), "an agent's resume")
	close_it(rc.created_id)
	testing.expect_value(t, core.claude_open_tab(sid), 0)
	ru, uargv := start(env, core.Claude_Resume{claude_session_id = sid}, CH_UI)
	testing.expect(t, ru.ok && ch_has(uargv, SKIP), "the user's resume")
	testing.expect_value(t, args_of(ru.created_id), "")
	rec, _ := core.claude_record(sid)
	testing.expect(t, rec != nil && len(rec.args) == 0, "never in the record's flags")
	// restarts: the user's with the setting as it is now, an agent's never
	testing.expect(t, ch_has(restart(env, ru.created_id, CH_UI), SKIP), "the user's restart, on")
	testing.expect(t, !ch_has(restart(env, ru.created_id, CH_CONTROL), SKIP), "an agent's restart")
	// turned off: the user's restart and resume of the same tab and conversation lose it
	off(t)
	testing.expect(t, !ch_has(restart(env, ru.created_id, CH_UI), SKIP), "the user's restart, off")
	core.run_command(core.Claude_Turn_Report{tab_id = ru.created_id, state = "idle"}, CH_SCRIPT)
	close_it(ru.created_id)
	ru2, u2argv := start(env, core.Claude_Resume{claude_session_id = sid}, CH_UI)
	testing.expect(t, ru2.ok && !ch_has(u2argv, SKIP), "the user's resume, off")
	on(t)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	testing.expect(t, strings.contains(core.state_json(), `"claude_skip_permissions":true`), "in the snapshot")
	// a chat, and its restore: a saved Claude chat shown by the user gets the setting as it is then
	r, argv = start(env, core.New_Claude_Session{project_id = c.id}, CH_UI)
	testing.expect(t, r.ok && ch_has(argv, SKIP), r.error)
	rsid := "0e0e0e0e-1111-4222-8333-444455556666"
	core.run_command(core.Claude_Session_Report{tab_id = core.find_session(r.created_id).tabs[0].id, session_id = rsid}, CH_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = core.find_session(r.created_id).tabs[0].id, state = "submitted", title = "restore me"}, CH_SCRIPT)
	text := strings.clone(core.workspace_json())
	testing.expect(t, !strings.contains(text, SKIP), "never saved")
	for want_on in ([]bool{false, true}) {
		context.allocator = ch_reset(&env, keep_dirs = true)
		testing.expect_value(t, core.workspace_restore(text), "")
		state.settings.claude_skip_permissions = want_on // as the user has it now (whatever was saved)
		target: ^core.Open_Session
		for &o in state.open_sessions do if o.pi_session_id == rsid do target = &o
		if target == nil {testing.fail(t);return}
		ch_clear(env)
		state.current_session = 0
		testing.expect(t, core.run_command(core.Focus_Session{session = target.id}, CH_UI).ok)
		got := ch_argv(env)
		testing.expectf(t, ch_has(got, SKIP) == want_on, "a restore with the setting %v: %v", want_on, got)
	}
}

// Start chats read-only was removed: a saved file from before (the setting on, a tab and a
// conversation marked read-only) loads, and its chat starts again as a full agent.
@(test)
ch_saved_readonly_ignored :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	sid := "0f0f0f0f-1111-4222-8333-444455556666"
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	testing.expect(t, r.ok, r.error)
	ch_argv(env)
	tab := core.find_session(r.created_id).tabs[0].id
	core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid}, CH_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted", title = "old chat"}, CH_SCRIPT)
	// what an older Deckhand saved: chats_readonly on, the tab and its conversation read-only
	text := core.workspace_json()
	insert :: proc(text, before, add: string) -> string {
		i := strings.index(text, before)
		if i < 0 do return text
		return strings.concatenate({text[:i], add, text[i:]})
	}
	si := strings.index(text, `"settings"`)
	testing.expect(t, si >= 0, "settings saved")
	if si < 0 do return
	bi := si + strings.index_byte(text[si:], '{') + 1
	text = strings.concatenate({text[:bi], strings.has_prefix(strings.trim_left_space(text[bi:]), "}") ? `"chats_readonly":true` : `"chats_readonly":true,`, text[bi:]})
	text = insert(text, `"claude_session_id"`, `"readonly":true,`)
	text = strings.concatenate({"{\"claude_readonly_ids\":[\"", sid, "\"],", text[1:]})
	text = strings.clone(text)
	context.allocator = ch_reset(&env, keep_dirs = true)
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect(t, !state.settings.chats_readonly, "the setting is ignored")
	testing.expect_value(t, core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI).error, core.CHATS_READONLY_REMOVED)
	target: ^core.Open_Session
	for &o in state.open_sessions do if o.pi_session_id == sid do target = &o
	if target == nil {testing.fail(t);return}
	ch_clear(env)
	state.current_session = 0
	testing.expect(t, core.run_command(core.Focus_Session{session = target.id}, CH_UI).ok)
	ch_full(t, ch_argv(env))
	testing.expect(t, ch_after(ch_argv(env), "--resume") == sid, "the same conversation")
}
