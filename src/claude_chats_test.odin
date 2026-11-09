package main

// Claude in chats and the read-only profile (claude.odin; docs/CLAUDE.md §1a, §3): Claude-only
// chats and Claude tabs in pi chats. With chats read-only off they are like a project's; with it
// on, every start of such a tab (new, resume, restore, restart; any caller) gets Deckhand's
// profile last in argv, the user's flags only from a short list; the profile is the tab's (saved,
// restored, kept by an agent's resume) and its token may not act on pages or apps.

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

// A fresh state with a Chats entry (temp HOME and data dir); claude's argv goes to argf and its
// DECKHAND_CLAUDE_READONLY to envf at each start.
@(private = "file")
Ch_Env :: struct {
	home, root, argf, envf, cli: string,
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
	core.platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
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
		env.envf = fmt.aprintf("%s/env", d)
		// the CLI's path, with a space and a quote (the hook's command line quotes it)
		cdir := fmt.aprintf("%s/it's here", ch_dir("cli"))
		os.make_directory_all(cdir)
		env.cli = fmt.aprintf("%s/deckhand-cli", cdir)
		_ = os.write_entire_file(env.cli, transmute([]u8)string("#!/bin/sh\nexit 0\n"))
	}
	core.claude_cli_override = env.cli
	os.set_env("HOME", env.home)
	core.home_root = env.root
	// the environment first, the argv last: once ch_argv sees this start's argv, its env file is
	// there too (a start's env written after the next start's ch_clear would be read as the next's)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf(`printf '%%s' "${{DECKHAND_CLAUDE_READONLY:-unset}}" > '%s.tmp'; mv '%s.tmp' '%s'; printf '%%s\n' "$@" > '%s.tmp'; mv '%s.tmp' '%s'; exec sleep 30`, env.envf, env.envf, env.envf, env.argf, env.argf, env.argf))
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
ch_env_ro :: proc(env: Ch_Env) -> string {
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(env.envf, context.temp_allocator); err == nil && len(data) > 0 do return string(data)
		time.sleep(20 * time.Millisecond)
	}
	return ""
}

@(private = "file")
ch_clear :: proc(env: Ch_Env) {
	os.remove(env.argf)
	os.remove(env.envf)
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

// Deckhand's read-only profile, last in argv, and its environment variable
@(private = "file")
ch_readonly :: proc(t: ^testing.T, env: Ch_Env, argv: []string, loc := #caller_location) {
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expectf(t, ch_after(argv, "--permission-mode") == "plan", "plan mode: %s", joined, loc = loc)
	testing.expectf(t, ch_after(argv, "--setting-sources") == "user", "user settings only: %s", joined, loc = loc)
	for tool in ([]string{"Edit", "Write", "NotebookEdit", "Agent", "Workflow", "CronCreate", "RemoteTrigger", "EnterWorktree", "mcp__*", "PowerShell", "Monitor"}) do testing.expectf(t, ch_has(argv, tool), "%s denied: %s", tool, joined, loc = loc)
	testing.expectf(t, !ch_has(argv, "Bash"), "Bash stays, behind the guard: %s", joined, loc = loc)
	prof := core.claude_readonly_profile(env.cli, ch_nonce(argv))
	n := len(prof)
	testing.expectf(t, len(argv) >= n && strings.join(argv[len(argv) - n:], "\x1f", context.temp_allocator) == strings.join(prof, "\x1f", context.temp_allocator), "the profile is last: %s", joined, loc = loc)
	// the settings: deny rules, no bypass or auto mode, hooks on, the guard with an absolute,
	// quoted path that fails closed
	v, err := json.parse_string(ch_after(argv, "--settings"), .JSON, true, context.temp_allocator)
	testing.expectf(t, err == nil, "settings JSON: %v", err, loc = loc)
	o, _ := v.(json.Object)
	perms, _ := o["permissions"].(json.Object)
	testing.expect_value(t, perms["disableBypassPermissionsMode"].(json.String) or_else "", "disable", loc = loc)
	testing.expect_value(t, perms["disableAutoMode"].(json.String) or_else "", "disable", loc = loc)
	testing.expect_value(t, perms["defaultMode"].(json.String) or_else "", "plan", loc = loc)
	testing.expect_value(t, o["disableAllHooks"].(json.Boolean) or_else true, false, loc = loc)
	testing.expect_value(t, o["disableSkillShellExecution"].(json.Boolean) or_else false, true, loc = loc)
	deny, _ := perms["deny"].(json.Array)
	has_deny :: proc(a: json.Array, s: string) -> bool {
		for x in a do if str, ok := x.(json.String); ok && string(str) == s do return true
		return false
	}
	for r in ([]string{"Edit", "Write", "mcp__*", "Bash(git commit *)", "Bash(rm *)", "Bash(sed -i *)"}) do testing.expectf(t, has_deny(deny, r), "deny %s", r, loc = loc)
	hooks, _ := o["hooks"].(json.Object)
	pre, _ := hooks["PreToolUse"].(json.Array)
	testing.expectf(t, len(pre) == 1, "one PreToolUse group", loc = loc)
	if len(pre) == 1 {
		g, _ := pre[0].(json.Object)
		testing.expect_value(t, g["matcher"].(json.String) or_else "", "*", loc = loc)
		hs, _ := g["hooks"].(json.Array)
		h: json.Object
		if len(hs) > 0 do h, _ = hs[0].(json.Object)
		testing.expect_value(t, h["onFailure"].(json.String) or_else "", "block", loc = loc)
		testing.expectf(t, (h["async"].(json.Boolean) or_else false) == false, "sync", loc = loc)
		cmd := string(h["command"].(json.String) or_else "")
		testing.expectf(t, strings.has_prefix(cmd, core.claude_sh_quote(env.cli)) && strings.has_suffix(cmd, " hook readonly || exit 2"), "guard command: %s", cmd, loc = loc)
	}
	testing.expectf(t, ch_env_ro(env) == "1", "DECKHAND_CLAUDE_READONLY=1", loc = loc)
}

@(private = "file")
ch_not_readonly :: proc(t: ^testing.T, env: Ch_Env, argv: []string, loc := #caller_location) {
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expectf(t, len(argv) > 0, "claude started", loc = loc)
	testing.expectf(t, !ch_has(argv, "--disallowedTools") && !ch_has(argv, "plan") && !ch_has(argv, "--settings"), "no read-only profile: %s", joined, loc = loc)
	testing.expectf(t, ch_env_ro(env) == "unset", "no DECKHAND_CLAUDE_READONLY", loc = loc)
}

// The user's flags a read-only tab keeps (an allowlist), the first it refuses.
@(test)
ch_readonly_args :: proc(t: ^testing.T) {
	kept, bad := core.claude_readonly_args({"--model", "opus", "--effort=high", "--verbose", "--fallback-model", "sonnet"})
	testing.expect_value(t, bad, "")
	testing.expect_value(t, len(kept), 6)
	refused := [][]string {
		{"--dangerously-skip-permissions"}, {"--allow-dangerously-skip-permissions"}, {"--permission-mode", "acceptEdits"},
		{"--permission-mode=bypassPermissions"}, {"--allowedTools", "Bash"}, {"--allowed-tools=Edit"}, {"--settings", "{}"},
		{"--setting-sources", "project"}, {"--tools", "Bash"}, {"--mcp-config", "x.json"}, {"--add-dir", "/"}, {"--agents", "{}"},
		{"--disallowedTools", "Read"}, {"--plugin-dir", "/x"}, {"--append-system-prompt", "x"}, {"--model"}, {"--model", "--settings"},
		{"-m", "x"}, {"--ide"}, {"--strict-mcp-config"},
	}
	for args in refused {
		_, b := core.claude_readonly_args(args)
		testing.expectf(t, b != "", "%v refused", args)
	}
	// the refusal names the flag, never its value
	_, b := core.claude_readonly_args({`--settings={"env":{"X":"secret"}}`})
	testing.expect_value(t, b, "--settings")
}

// Read-only off: a Claude chat and a Claude tab in a pi chat start like a project's (the user's
// flags, no profile); the chat's row lists in Chats, marked Claude.
@(test)
ch_chats_off :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	testing.expect(t, c != nil)
	if c == nil do return
	testing.expect(t, !state.settings.chats_readonly)
	ch_clear(env)
	r := core.run_command(core.New_Claude_Session{project_id = c.id, args = {"--dangerously-skip-permissions"}}, CH_UI)
	testing.expect(t, r.ok, r.error)
	argv := ch_argv(env)
	ch_not_readonly(t, env, argv)
	testing.expect(t, ch_has(argv, "--dangerously-skip-permissions"), "the user's flags")
	s := core.find_session(r.created_id)
	testing.expect(t, s != nil && s.agent == .Claude && core.open_session_is_chat(s))
	if s == nil do return
	core.run_command(core.Claude_Session_Report{tab_id = s.tabs[0].id, session_id = "c1c1c1c1-0000-4000-8000-0000000000aa"}, CH_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = s.tabs[0].id, state = "submitted", title = "chat about cats"}, CH_SCRIPT)
	found := false
	for row in core.sidebar_sessions(.Chats) do if row.session.claude && row.session.title == "chat about cats" do found = true
	testing.expect(t, found, "its row in Chats")
	_, label, extra := tab_label(s, s.tabs[0])
	testing.expect(t, extra != "read-only", label)
	// a Claude tab in a pi chat: the user's, and an agent's
	chat := core.run_command(core.New_Chat{project_id = c.id}, CH_UI).created_id
	ch_clear(env)
	rt := core.run_command(core.New_Claude_Tab{session = chat}, CH_UI)
	testing.expect(t, rt.ok, rt.error)
	ch_not_readonly(t, env, ch_argv(env))
	ch_clear(env)
	ra := core.run_command(core.New_Claude_Tab{session = chat}, CH_CONTROL)
	testing.expect(t, ra.ok, ra.error)
	ch_not_readonly(t, env, ch_argv(env))
}

// Read-only on: every new Claude tab in a chat gets the profile last, whoever opens it; flags
// outside the allowlist are refused; a model goes along; a project's Claude is unchanged.
@(test)
ch_chats_readonly_new :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	testing.expect(t, core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI).ok)
	ch_clear(env)
	r := core.run_command(core.New_Claude_Session{project_id = c.id, args = {"--model", "opus"}}, CH_UI)
	testing.expect(t, r.ok, r.error)
	argv := ch_argv(env)
	ch_readonly(t, env, argv)
	testing.expect(t, ch_after(argv, "--model") == "opus", "a model goes along")
	s := core.find_session(r.created_id)
	_, _, extra := tab_label(s, s.tabs[0])
	testing.expect_value(t, extra, "read-only")
	tb := strings.builder_make(context.temp_allocator)
	core.claude_tab_json(&tb, s.tabs[0])
	testing.expect(t, strings.contains(strings.to_string(tb), `"readonly":true`), "the snapshot says so")
	n := len(state.open_sessions)
	for args in ([][]string{{"--dangerously-skip-permissions"}, {"--permission-mode", "acceptEdits"}, {"--settings", "{}"}, {"--allowedTools", "Bash"}}) {
		rr := core.run_command(core.New_Claude_Session{project_id = c.id, args = args}, CH_UI)
		testing.expectf(t, !rr.ok && strings.contains(rr.error, "read-only chat"), "%v refused: %s", args, rr.error)
	}
	testing.expect_value(t, len(state.open_sessions), n)
	// in a pi chat: the user's tab and an agent's
	chat := core.run_command(core.New_Chat{project_id = c.id}, CH_UI).created_id
	testing.expect(t, !core.run_command(core.New_Claude_Tab{session = chat, args = {"--permission-mode", "default"}}, CH_UI).ok)
	ch_clear(env)
	testing.expect(t, core.run_command(core.New_Claude_Tab{session = chat}, CH_UI).ok)
	ch_readonly(t, env, ch_argv(env))
	ch_clear(env)
	ra := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_CONTROL)
	testing.expect(t, ra.ok, ra.error)
	ch_readonly(t, env, ch_argv(env))
	ch_clear(env)
	testing.expect(t, core.run_command(core.New_Claude_Tab{session = chat}, CH_CONTROL).ok)
	ch_readonly(t, env, ch_argv(env))
	// a project's Claude stays as it was
	pdir := ch_dir("proj")
	pid := core.run_command(core.Add_Project{cwd = pdir}, CH_UI).created_id
	ch_clear(env)
	testing.expect(t, core.run_command(core.New_Claude_Session{project_id = pid, args = {"--dangerously-skip-permissions"}}, CH_UI).ok)
	ch_not_readonly(t, env, ch_argv(env))
}

// Without Deckhand's CLI (the guard) a read-only tab does not start: never read-only without it.
@(test)
ch_readonly_needs_guard :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	core.claude_cli_override = "-" // "-": no CLI (tests)
	ch_clear(env)
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	testing.expect(t, !r.ok, "refused")
	testing.expect(t, !os.exists(env.argf), "claude never started")
}

// The profile is the tab's: a restart by the user or an agent, a restore (even after the setting
// went off) and a resume from its row by an agent all keep it; saved flags outside the allowlist
// are left out.
@(test)
ch_readonly_kept :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	sid := "c2c2c2c2-0000-4000-8000-000000000001"
	// begun before read-only went on, with flags of the user's
	r := core.run_command(core.New_Claude_Session{project_id = c.id, args = {"--dangerously-skip-permissions", "--model", "opus"}}, CH_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, len(ch_argv(env)) > 0, "started") // its argv written before the next start's
	s := core.find_session(r.created_id)
	tab := s.tabs[0].id
	core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid}, CH_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted", title = "later"}, CH_SCRIPT)
	testing.expect(t, core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI).ok)
	// an agent's restart after it exited (its process gone)
	core.drop_term(tab)
	core.run_command(core.Tab_Exited{tab_id = tab, exit = {known = true, code = 1}}, {kind = .Internal})
	ch_clear(env)
	rr0 := core.run_command(core.Claude_Restart{tab_id = tab}, CH_CONTROL)
	testing.expect(t, rr0.ok, rr0.error)
	ch_readonly(t, env, ch_argv(env))
	// the user's restart: the saved bypass is left out, the model goes along
	core.drop_term(tab)
	core.run_command(core.Tab_Exited{tab_id = tab, exit = {known = true, code = 1}}, {kind = .Internal})
	ch_clear(env)
	testing.expect(t, core.run_command(core.Focus_Session{session = s.id, reopen = true}, CH_UI).ok)
	argv := ch_argv(env)
	ch_readonly(t, env, argv)
	testing.expect(t, !ch_has(argv, "--dangerously-skip-permissions"), "the saved bypass is left out")
	testing.expect(t, ch_has(argv, "--model") && ch_after(argv, "--resume") == sid)
	// saved, then the setting goes off, then restored: still read-only (the tab's)
	text := strings.clone(core.workspace_json())
	testing.expect(t, strings.contains(text, `"readonly": true`) || strings.contains(text, `"readonly":true`), "saved with the tab")
	context.allocator = ch_reset(&env, keep_dirs = true)
	testing.expect_value(t, core.workspace_restore(text), "")
	core.run_command(core.Set_Chats_Readonly{on = false}, CH_UI)
	testing.expect_value(t, len(state.open_sessions), 1)
	if len(state.open_sessions) != 1 do return
	rs := &state.open_sessions[0]
	testing.expect(t, core.open_session_is_chat(rs), "restored into Chats")
	ch_clear(env)
	state.current_session = 0
	core.run_command(core.Focus_Session{session = rs.id}, CH_UI)
	argv = ch_argv(env)
	ch_readonly(t, env, argv)
	testing.expect(t, !ch_has(argv, "--dangerously-skip-permissions"))
	// closed, then resumed from its row by an agent (no flags of the user's, the profile kept)
	rsid := rs.id
	core.run_command(core.Close_Session{session = rsid, confirm = ""}, CH_UI)
	for &p in state.pending_confirmations do core.run_command(core.Close_Session{session = rsid, confirm = p.token}, CH_UI)
	testing.expect_value(t, len(state.open_sessions), 0)
	ch_clear(env)
	ar := core.run_command(core.Claude_Resume{claude_session_id = sid}, CH_CONTROL)
	testing.expect(t, ar.ok, ar.error)
	argv = ch_argv(env)
	ch_readonly(t, env, argv)
	testing.expect(t, !ch_has(argv, "--model"), "an agent's resume: no flags of the user's")
	testing.expect(t, len(state.open_sessions) == 1 && core.open_session_is_chat(&state.open_sessions[0]), "resumed into Chats")
	// and as a Claude tab of another chat by an agent (resume): still read-only
	if len(state.open_sessions) == 1 {
		id := state.open_sessions[0].id
		core.run_command(core.Close_Session{session = id, confirm = ""}, CH_UI)
		for &p in state.pending_confirmations do core.run_command(core.Close_Session{session = id, confirm = p.token}, CH_UI)
	}
	c = core.chats_project() // a new state since the restore
	chat := core.run_command(core.New_Chat{project_id = c.id}, CH_UI).created_id
	ch_clear(env)
	nt := core.run_command(core.New_Claude_Tab{session = chat, resume = sid}, CH_CONTROL)
	testing.expect(t, nt.ok, nt.error)
	ch_readonly(t, env, ch_argv(env))
}

// A read-only tab's token may read pages but not act on them or on apps (Deckhand refuses it
// whatever the guard let through).
@(test)
ch_readonly_no_act :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	testing.expect(t, r.ok, r.error)
	tab := core.find_session(r.created_id).tabs[0].id
	me := core.Caller{kind = .Panel, tab_id = tab, claude = true}
	acts := []core.Command{core.Browser_Click{tab_id = 1}, core.Browser_Type{tab_id = 1}, core.Browser_Press{tab_id = 1}, core.Browser_Select{tab_id = 1}, core.Browser_Upload{tab_id = 1}, core.App_Input{tab_id = 1}, core.App_Call{tab_id = 1}}
	for cmd in acts {
		rr := core.run_command(cmd, me)
		testing.expectf(t, !rr.ok && strings.contains(rr.error, "read-only"), "%v: %s", core.command_type(cmd), rr.error)
	}
	// reading is the session checks' as before (no such tab here), not the read-only refusal
	rr := core.run_command(core.Browser_Tabs{session = r.created_id}, me)
	testing.expect(t, !strings.contains(rr.error, "read-only"), rr.error)
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

@(private = "file")
ch_title :: proc(id: string) -> string {
	a := action_by_id(id)
	return a != nil ? action_label(a) : ""
}

// The guard's command line fails closed: a missing, failing or killed CLI exits 2 (Claude Code
// blocks the call on exit 2; onFailure "block" covers a timeout too).
@(test)
ch_guard_fails_closed :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/it's a dir", ch_dir("guard"))
	os.make_directory_all(dir)
	run :: proc(cmd: string) -> int {
		st := libc.system(strings.clone_to_cstring(fmt.tprintf("%s </dev/null >/dev/null 2>&1", cmd), context.temp_allocator))
		return int(st >> 8) & 0xff
	}
	script :: proc(path, body: string) {
		_ = os.write_entire_file(path, transmute([]u8)strings.concatenate({"#!/bin/sh\n", body, "\n"}, context.temp_allocator))
		posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	}
	cli := fmt.tprintf("%s/deckhand-cli", dir)
	sh :: proc(c: string) -> string {return fmt.tprintf("/bin/sh -c %s", core.claude_sh_quote(c))}
	testing.expect_value(t, run(sh(core.claude_readonly_hook_command(cli))), 2) // missing
	script(cli, "exit 1")
	testing.expect_value(t, run(sh(core.claude_readonly_hook_command(cli))), 2)
	script(cli, "kill -9 $$")
	testing.expect_value(t, run(sh(core.claude_readonly_hook_command(cli))), 2)
	script(cli, "exit 2")
	testing.expect_value(t, run(sh(core.claude_readonly_hook_command(cli))), 2)
	script(cli, `[ "$1 $2" = "hook readonly" ] || exit 1; exit 0`)
	testing.expect_value(t, run(sh(core.claude_readonly_hook_command(cli))), 0)
}

// ---- review round 1 ----

// The nonce of the read-only ack hook in a start's argv ("" = none).
@(private = "file")
ch_nonce :: proc(argv: []string) -> string {
	v, err := json.parse_string(ch_after(argv, "--settings"), .JSON, true, context.temp_allocator)
	if err != nil do return ""
	o, _ := v.(json.Object)
	hooks, _ := o["hooks"].(json.Object)
	ss, _ := hooks["SessionStart"].(json.Array)
	if len(ss) != 1 do return ""
	g, _ := ss[0].(json.Object)
	hs, _ := g["hooks"].(json.Array)
	if len(hs) != 1 do return ""
	h, _ := hs[0].(json.Object)
	cmd := string(h["command"].(json.String) or_else "")
	if !strings.contains(cmd, " hook readonly-ack ") do return ""
	return cmd[strings.last_index_byte(cmd, ' ') + 1:]
}

// 1. The tab's label says what its process started with: a full chat tab that runs on after the
// setting went on is not "read-only" (it is, after a restart); a tab not started yet says what it
// will start as.
@(test)
ch_label_follows_process :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	testing.expect(t, r.ok, r.error)
	ch_not_readonly(t, env, ch_argv(env))
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	s := core.find_session(r.created_id)
	_, _, extra := tab_label(s, s.tabs[0])
	testing.expect_value(t, extra, "read-only after restart")
	// its token still acts (it is a full Claude): consistent with the label
	me := core.Caller{kind = .Panel, tab_id = s.tabs[0].id, claude = true}
	testing.expect(t, !strings.contains(core.run_command(core.Browser_Click{tab_id = 1}, me).error, "read-only"))
}

// 2. The profile must prove it loaded: its SessionStart hook acks with the start's nonce. No ack
// within 10 s of the session report (or 120 s of the start), or a prompt before it: stopped.
@(test)
ch_readonly_ack :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	start :: proc(env: Ch_Env, c: ^core.Project) -> (tab: u64, nonce: string) {
		ch_clear(env)
		r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
		argv := ch_argv(env)
		return core.find_session(r.created_id).tabs[0].id, strings.clone(ch_nonce(argv))
	}
	now := time.tick_now()
	// a: the session reports, no ack: stopped after 10 s
	a, na := start(env, c)
	testing.expect(t, len(na) >= 32, "a nonce in the ack hook")
	core.run_command(core.Claude_Session_Report{tab_id = a, session_id = "a0a0a0a0-0000-4000-8000-000000000001"}, CH_SCRIPT)
	core.claude_readonly_tick(time.tick_add(now, 5 * time.Second))
	testing.expect(t, !core.claude_readonly_stopped(a), "not before its time")
	core.claude_readonly_tick(time.tick_add(now, 11 * time.Second))
	testing.expect(t, core.claude_readonly_stopped(a), "stopped without the ack")
	sa, ta, _ := core.find_tab(a)
	_, _, ex := tab_label(sa, ta^)
	testing.expectf(t, strings.contains(ex, "not confirmed"), "label: %s", ex)
	// b: acked (its own token, its nonce): runs on
	b, nb := start(env, c)
	me := core.Caller{kind = .Panel, tab_id = b, claude = true}
	testing.expect(t, !core.run_command(core.Claude_Readonly_Ack{tab_id = b, nonce = "wrong"}, me).ok, "a wrong nonce")
	testing.expect(t, !core.run_command(core.Claude_Readonly_Ack{tab_id = b, nonce = nb}, core.Caller{kind = .Panel, tab_id = a, claude = true}).ok, "another tab's token")
	testing.expect(t, !core.run_command(core.Claude_Readonly_Ack{tab_id = b, nonce = nb}, CH_CONTROL).ok, "an agent")
	rb := core.run_command(core.Claude_Readonly_Ack{tab_id = b, nonce = nb}, me)
	testing.expect(t, rb.ok, rb.error)
	testing.expect(t, !core.run_command(core.Claude_Readonly_Ack{tab_id = b, nonce = nb}, me).ok, "once")
	core.run_command(core.Claude_Session_Report{tab_id = b, session_id = "a0a0a0a0-0000-4000-8000-000000000002"}, CH_SCRIPT)
	core.claude_readonly_tick(time.tick_add(now, 200 * time.Second))
	testing.expect(t, !core.claude_readonly_stopped(b), "acked: runs on")
	// c: a prompt before the ack: stopped at once, and a late ack is refused
	cc, nc := start(env, c)
	core.run_command(core.Claude_Turn_Report{tab_id = cc, state = "submitted", title = "x"}, CH_SCRIPT)
	testing.expect(t, core.claude_readonly_stopped(cc), "a prompt before the ack")
	testing.expect(t, !core.run_command(core.Claude_Readonly_Ack{tab_id = cc, nonce = nc}, core.Caller{kind = .Panel, tab_id = cc, claude = true}).ok)
	// d: no hook ran at all: stopped 120 s after Claude's prompt came up (bracketed paste on), not
	// while a startup dialog (folder trust, login) sits open before it
	d, _ := start(env, c)
	core.claude_readonly_tick(time.tick_add(time.tick_now(), 200 * time.Second))
	testing.expect(t, !core.claude_readonly_stopped(d), "a startup dialog left open: not stopped")
	td := core.term_of(d)
	if td == nil {testing.fail(t);return}
	on := "\x1b[?2004h"
	gh.terminal_vt_write(td.gt, raw_data(on), len(on))
	up := time.tick_add(time.tick_now(), 300 * time.Second)
	core.claude_readonly_tick(up) // its prompt is up: the clock starts
	core.claude_readonly_tick(time.tick_add(up, 60 * time.Second))
	testing.expect(t, !core.claude_readonly_stopped(d))
	core.claude_readonly_tick(time.tick_add(up, 121 * time.Second))
	testing.expect(t, core.claude_readonly_stopped(d), "no hook within 120 s of its prompt")
	testing.expect(t, strings.contains(core.CLAUDE_GUARD_STOPPED, "startup dialog"), "the message names both causes")
	// d2: Claude's own OSC 7501 reporting (not blocked, which may be a dialog) starts it too
	d2, _ := start(env, c)
	_, tab2, _ := core.find_tab(d2)
	tab2.prog.state = .Blocked
	core.claude_readonly_tick(time.tick_add(time.tick_now(), 200 * time.Second))
	testing.expect(t, !core.claude_readonly_stopped(d2), "blocked: maybe a dialog")
	tab2.prog.state = .Idle
	up2 := time.tick_add(time.tick_now(), 300 * time.Second)
	core.claude_readonly_tick(up2)
	core.claude_readonly_tick(time.tick_add(up2, 121 * time.Second))
	testing.expect(t, core.claude_readonly_stopped(d2), "OSC 7501 idle: the clock ran")
	// a full tab needs no ack
	core.run_command(core.Set_Chats_Readonly{on = false}, CH_UI)
	e, _ := start(env, c)
	core.claude_readonly_tick(time.tick_add(time.tick_now(), 200 * time.Second))
	testing.expect(t, !core.claude_readonly_stopped(e))
}

// 5. A read-only conversation stays read-only after its history entry is gone (the 100 cap, or
// dropped on load): new_claude_tab resume=<id> in a project session still gets the profile.
@(test)
ch_readonly_ids_kept :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	sid := "b1b1b1b1-0000-4000-8000-000000000001"
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	ch_argv(env)
	tab := core.find_session(r.created_id).tabs[0].id
	core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid}, CH_SCRIPT)
	// saved; then loaded with its history entry gone
	text := strings.clone(core.workspace_json())
	if i := strings.index(text, `"claude_sessions"`); i >= 0 {
		// drop the history from the saved text
		j := strings.index(text[i:], "]")
		text = strings.concatenate({text[:i], `"claude_sessions_x":[`, text[i + j:]})
	}
	context.allocator = ch_reset(&env, keep_dirs = true)
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect(t, rec_none(sid), "the history entry is gone")
	for len(state.open_sessions) > 0 {
		id := state.open_sessions[0].id
		core.run_command(core.Close_Session{session = id, confirm = ""}, CH_UI)
		for &p in state.pending_confirmations do core.run_command(core.Close_Session{session = id, confirm = p.token}, CH_UI)
		if len(state.open_sessions) > 0 && state.open_sessions[0].id == id do break
	}
	pdir := ch_dir("proj")
	pid := core.run_command(core.Add_Project{cwd = pdir}, CH_UI).created_id
	ch_clear(env)
	nt := core.run_command(core.New_Claude_Tab{project_id = pid, resume = sid}, CH_UI)
	testing.expect(t, nt.ok, nt.error)
	ch_readonly(t, env, ch_argv(env))
	// and the user's flags are limited there too
	testing.expect(t, !core.run_command(core.New_Claude_Tab{project_id = pid, resume = sid, args = {"--dangerously-skip-permissions"}}, CH_UI).ok)
}

@(private = "file")
rec_none :: proc(id: string) -> bool {
	r, _ := core.claude_record(id)
	return r == nil
}

// Polish: hovering is refused too (it can fire a page's scripts); Task and ExitPlanMode denied.
@(test)
ch_readonly_polish :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	argv := ch_argv(env)
	tail := argv[len(argv) - len(core.CLAUDE_READONLY_DENY):]
	testing.expect(t, ch_has(tail, "Task") && ch_has(tail, "ExitPlanMode"), strings.join(tail, " ", context.temp_allocator))
	me := core.Caller{kind = .Panel, tab_id = core.find_session(r.created_id).tabs[0].id, claude = true}
	testing.expect(t, strings.contains(core.run_command(core.Browser_Hover{tab_id = 1}, me).error, "read-only"))
}

// Nothing Deckhand types (an agent's held message, Restart with model's /model) goes into a
// read-only tab before its ack: a prompt before the ack would stop it (claude_ready waits).
@(test)
ch_ack_holds_messages :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
	nonce := strings.clone(ch_nonce(ch_argv(env)))
	tid := core.find_session(r.created_id).tabs[0].id
	core.run_command(core.Claude_Session_Report{tab_id = tid, session_id = "c4c4c4c4-0000-4000-8000-000000000001"}, CH_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = tid, state = "idle"}, CH_SCRIPT)
	_, tab, ct := core.claude_tab_of(tid)
	_, why := core.claude_ready(tab, ct)
	testing.expectf(t, strings.contains(why, "read-only guard"), "waits for the ack: %s", why)
	testing.expect(t, core.run_command(core.Claude_Readonly_Ack{tab_id = tid, nonce = nonce}, core.Caller{kind = .Panel, tab_id = tid, claude = true}).ok)
	_, why = core.claude_ready(tab, ct)
	testing.expectf(t, !strings.contains(why, "read-only guard"), "after the ack: %s", why)
}

// Round 2: the read-only ids are a most-recently-used list (marked again: to the back; the least
// recently used goes at the cap, 10,000). A restore puts the saved list first, then the history's
// read-only records while there is room: never past the cap.
@(test)
ch_readonly_ids_lru :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	testing.expect_value(t, core.CLAUDE_READONLY_IDS_MAX, 10_000)
	id :: proc(n: int) -> string {return fmt.tprintf("%08x-0000-4000-8000-000000000000", n)}
	for n in 0 ..< core.CLAUDE_READONLY_IDS_MAX do core.claude_readonly_mark(id(n))
	core.claude_readonly_mark(id(0)) // used again: now the most recent
	core.claude_readonly_mark(id(core.CLAUDE_READONLY_IDS_MAX)) // one more: the least recent (1) goes
	testing.expect_value(t, len(state.claude_readonly_ids), core.CLAUDE_READONLY_IDS_MAX)
	testing.expect(t, core.claude_readonly_known(id(0)), "re-marked: kept")
	testing.expect(t, !core.claude_readonly_known(id(1)), "least recently used: gone")
	testing.expect_value(t, state.claude_readonly_ids[len(state.claude_readonly_ids) - 2], id(0))
	// restore: the saved list first (its order), then records not in it, up to the cap
	clear(&state.claude_readonly_ids)
	rec := proc(n: int) -> core.Claude_Record {return core.Claude_Record{id = id(n), project = "/p", readonly = true}}
	core.run_command(core.Claude_Restore_History{readonly_ids = {id(5), id(6)}, records = {rec(7), rec(5)}}, {kind = .Internal})
	got := strings.join(state.claude_readonly_ids[:], ",", context.temp_allocator)
	testing.expect_value(t, got, strings.join({id(5), id(6), id(7)}, ",", context.temp_allocator))
	clear(&state.claude_readonly_ids)
	clear(&state.claude_history)
	saved := make([]string, core.CLAUDE_READONLY_IDS_MAX, context.temp_allocator)
	for &s, n in saved do s = strings.clone(id(n), context.temp_allocator)
	core.run_command(core.Claude_Restore_History{readonly_ids = saved, records = {rec(core.CLAUDE_READONLY_IDS_MAX + 1)}}, {kind = .Internal})
	testing.expect_value(t, len(state.claude_readonly_ids), core.CLAUDE_READONLY_IDS_MAX)
	testing.expect(t, core.claude_readonly_known(id(0)), "the saved list comes first")
	testing.expect_value(t, state.claude_readonly_ids[len(state.claude_readonly_ids) - 1], id(core.CLAUDE_READONLY_IDS_MAX - 1))
}

// The user's default flags (Settings: "Default Claude Code flags for new tabs"; off by default).
// The CURRENT setting applies at each start the user makes (a new tab, session or chat, the
// user's resume, restore and restart): it is never saved into a tab's or a record's flags, so
// turning it off takes it away from them all. Agents' starts never get it; a read-only chat leaves
// it out and says so; at the flag cap it is left out; only the user turns it on, after confirming.
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
	// a read-only chat: the default is left out, and the user is told
	on(t)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	testing.expect(t, core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI).ok)
	toast_show("")
	rr, rargv := start(env, core.New_Claude_Session{project_id = c.id}, CH_UI)
	testing.expect(t, rr.ok, rr.error)
	ch_readonly(t, env, rargv)
	testing.expect(t, !ch_has(rargv, SKIP), "not in a read-only chat")
	testing.expect(t, strings.contains(toast.text, SKIP) && strings.contains(toast.text, "Read-only chat"), toast.text)
	testing.expect(t, strings.contains(core.state_json(), `"claude_skip_permissions":true`), "in the snapshot")
	testing.expect(t, core.run_command(core.Set_Chats_Readonly{on = false}, CH_UI).ok)
	// restore: a saved Claude chat shown by the user gets the setting as it is then
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

// 2b. A read-only Claude kept by the session holder across a relaunch keeps running only with a
// trusted ack (tokens.json, socket.odin): acked → ok; not acked or nothing saved → stopped, and
// the tab says so.
@(test)
ch_readonly_adopt_fails_closed :: proc(t: ^testing.T) {
	env: Ch_Env
	old_home, old_root := strings.clone(os.get_env("HOME", context.temp_allocator)), core.home_root
	defer ch_done(old_home, old_root)
	context.allocator = ch_reset(&env)
	c := core.chats_project()
	if c == nil {testing.fail(t);return}
	core.run_command(core.Set_Chats_Readonly{on = true}, CH_UI)
	start :: proc(env: Ch_Env, c: ^core.Project) -> (tab: u64, nonce: string) {
		ch_clear(env)
		r := core.run_command(core.New_Claude_Session{project_id = c.id}, CH_UI)
		argv := ch_argv(env)
		return core.find_session(r.created_id).tabs[0].id, strings.clone(ch_nonce(argv))
	}
	a, na := start(env, c)
	core.socket_tokens_bind(a, 21, {kind = .Claude})
	testing.expect(t, !core.claude_adopt_ro_ok(21), "not acked yet")
	testing.expect(t, core.run_command(core.Claude_Readonly_Ack{tab_id = a, nonce = na}, core.Caller{kind = .Panel, tab_id = a, claude = true}).ok)
	testing.expect(t, core.claude_adopt_ro_ok(21), "acked")
	b, _ := start(env, c)
	core.socket_tokens_bind(b, 22, {kind = .Claude})
	testing.expect(t, !core.claude_adopt_ro_ok(22), "not acked")
	testing.expect(t, !core.claude_adopt_ro_ok(23), "nothing saved (no file, or a bad MAC)")
	core.claude_adopt_ro_stop(b)
	testing.expect(t, core.claude_readonly_stopped(b), "stopped")
	sb, tb, _ := core.find_tab(b)
	_, _, ex := tab_label(sb, tb^)
	testing.expectf(t, strings.contains(ex, "not confirmed"), "label: %s", ex)
	testing.expect(t, !core.claude_adopt_ro_ok(22), "its state went with its token")
	testing.expect(t, !core.claude_readonly_stopped(a))
	core.socket_forget_tab(a)
	testing.expect(t, !core.claude_adopt_ro_ok(21), "the tab's end drops it")
}
