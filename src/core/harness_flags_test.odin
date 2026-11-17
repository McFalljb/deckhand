package core

// The user's flags for harness tabs (harness_flags.odin): one line split as a shell splits words
// (nothing evaluated), pi's own flag rule, the per-harness defaults before a tab's own flags, and
// the setting only this Mac's user may change.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:testing"

@(test)
flags_split_shell_words :: proc(t: ^testing.T) {
	cases := [?]struct {
		line: string,
		want: []string,
	} {
		{"", {}},
		{"   ", {}},
		{"  --model   opus ", {"--model", "opus"}},
		{"a\tb", {"a", "b"}},
		{`--append-system-prompt "be brief, please"`, {"--append-system-prompt", "be brief, please"}},
		{`-c 'model_reasoning_effort="high"'`, {"-c", `model_reasoning_effort="high"`}},
		{`--x=a\ b`, {"--x=a b"}},
		// nothing is evaluated: no variables, commands, globs or ~
		{`"$HOME" '$(rm -rf ~)' ~ * ;`, {"$HOME", "$(rm -rf ~)", "~", "*", ";"}},
		{`a"b"'c'`, {"abc"}},
		// in double quotes a backslash escapes only $ ` " and \ (as sh)
		{`"say \"hi\" \\ \$x \n"`, {`say "hi" \ $x \n`}},
		{`''`, {""}},
	}
	for c in cases {
		got, err := flags_split(c.line)
		testing.expectf(t, err == "" && slice.equal(got, c.want), "%q: %v %q", c.line, got, err)
	}
	for bad in ([]string{`"open`, `'open`, `trailing\`}) {
		_, err := flags_split(bad)
		testing.expectf(t, err != "", "%q: refused", bad)
	}
	// what join writes, split reads back the same
	for args in ([][]string{{"--model", "opus"}, {"a b", `it's`, `"q"`, "$x", "", `back\slash`}}) {
		back, err := flags_split(flags_join(args))
		testing.expectf(t, err == "" && slice.equal(back, args), "%v: %v %q", args, back, err)
	}
	testing.expect_value(t, flags_join({"--model", "opus", "-c", `a="b"`}), `--model opus -c 'a="b"'`)
}

// pi takes only the flags known safe for a tab: model, provider, thinking, a few switches. Never
// its session, extension, print or RPC flags (Deckhand's integration and session need them), no
// prompt words, and `--model=x` is not pi's form (it would read it as an extension's flag).
@(test)
pi_args_rule :: proc(t: ^testing.T) {
	for ok in ([][]string{{}, {"--model", "sonnet:high"}, {"--provider", "anthropic", "--model", "claude-opus"}, {"--thinking", "high"}, {"--models", "a,b"}, {"--offline"}, {"--no-mcp", "--verbose"}, {"--tui-mode", "regular"}}) {
		testing.expectf(t, pi_args_check(ok) == "", "%v: %s", ok, pi_args_check(ok))
	}
	refused := [?]struct {
		args: []string,
		has:  string,
	} {
		{{"-e", "x.ts"}, "-e is refused"},
		{{"--extension", "x.ts"}, "--extension is refused"},
		{{"--no-extensions"}, "is refused"},
		{{"--session", "x"}, "Deckhand picks the session"},
		{{"--session-id", "x"}, "Deckhand picks the session"},
		{{"--fork", "x"}, "Deckhand picks the session"},
		{{"-c"}, "Deckhand picks the session"},
		{{"--no-session"}, "is refused"},
		{{"-p"}, "is refused"},
		{{"--mode", "rpc"}, "is refused"},
		{{"--api-key", "sk-1"}, "is refused"},
		{{"--list-models"}, "is refused"},
		{{"--whatever"}, "--whatever is not a pi flag Deckhand passes on"},
		{{"--model"}, "--model needs a value"},
		{{"--model", "--offline"}, "--model needs a value"},
		{{"--model=opus"}, "two words"},
		{{"--offline", "hello"}, "not a flag"},
		{{"@notes.md"}, "not a flag"},
		{{"--model", "a\nb"}, "line break"},
	}
	for r in refused {
		e := pi_args_check(r.args)
		testing.expectf(t, strings.contains(e, r.has), "%v: %q", r.args, e)
	}
	many := make([]string, CLAUDE_ARGS_MAX + 1, context.temp_allocator)
	for &a in many do a = "--offline"
	testing.expect(t, pi_args_check(many) != "", "at most CLAUDE_ARGS_MAX")
}

// The defaults go first and the tab's own flags after them; a default the tab names itself is
// left out (one flag, short or long; Codex's -c by its key); one that would not pass, or past the
// cap, leaves all the defaults out.
@(test)
harness_flags_merge :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	set :: proc(h: Harness, s: string) {
		delete(state.settings.harness_flags[h])
		state.settings.harness_flags[h] = strings.clone(s)
	}
	defer {
		for &s in state.settings.harness_flags {
			delete(s)
			s = ""
		}
		state.settings.claude_skip_permissions = false
		state.settings.codex_full_access = false
	}
	j :: proc(a: []string) -> string {return strings.join(a, " ", context.temp_allocator)}
	testing.expect_value(t, j(harness_with_defaults(.Claude, {"--model", "opus"})), "--model opus") // none set
	set(.Claude, "--model sonnet --permission-mode plan --add-dir /tmp/x")
	testing.expect_value(t, j(harness_with_defaults(.Claude, nil)), "--model sonnet --permission-mode plan --add-dir /tmp/x")
	testing.expect_value(t, j(harness_with_defaults(.Claude, {"--model", "opus"})), "--permission-mode plan --add-dir /tmp/x --model opus")
	testing.expect_value(t, j(harness_with_defaults(.Claude, {"--model=opus"})), "--permission-mode plan --add-dir /tmp/x --model=opus")
	// Codex: -m and --model are one flag; -c by its key
	set(.Codex, `-m o3 -c 'model_reasoning_effort="high"' --search`)
	testing.expect_value(t, j(harness_with_defaults(.Codex, {"--model", "gpt-5"})), `-c model_reasoning_effort="high" --search --model gpt-5`)
	testing.expect_value(t, j(harness_with_defaults(.Codex, {"-c", `model_reasoning_effort="low"`})), `-m o3 --search -c model_reasoning_effort="low"`)
	testing.expect_value(t, j(harness_with_defaults(.Codex, {"-c", "foo=1"})), `-m o3 -c model_reasoning_effort="high" --search -c foo=1`)
	set(.Pi, "--model sonnet --offline")
	testing.expect_value(t, j(harness_with_defaults(.Pi, {"--thinking", "high"})), "--model sonnet --offline --thinking high")
	testing.expect_value(t, j(harness_with_defaults(.Pi, {"--model", "opus"})), "--offline --model opus")
	// past the cap: the tab's own only
	many := make([]string, CLAUDE_ARGS_MAX, context.temp_allocator)
	for &a in many do a = "--verbose"
	testing.expect_value(t, j(harness_with_defaults(.Claude, many)), j(many))
	// a saved default that no longer passes the rule (an older file): left out
	state.settings.harness_flags[.Codex] = strings.clone("--no-daemon")
	testing.expect_value(t, j(harness_with_defaults(.Codex, {"--search"})), "--search")
	// the switches still come after, and a permission chosen by a default wins over them
	set(.Claude, "--model sonnet")
	state.settings.claude_skip_permissions = true
	testing.expect_value(t, j(claude_with_defaults({"--verbose"})), "--model sonnet --verbose --dangerously-skip-permissions")
	set(.Claude, "--permission-mode plan")
	testing.expect_value(t, j(claude_with_defaults(nil)), "--permission-mode plan")
	state.settings.codex_full_access = true
	set(.Codex, "-s workspace-write")
	testing.expect_value(t, j(codex_with_defaults(nil)), "-s workspace-write")
	set(.Codex, "--search")
	testing.expect_value(t, j(codex_with_defaults(nil)), "--search --dangerously-bypass-approvals-and-sandbox")
}

// Settings › Coding agents › Default flags: only this Mac's user (never a machine viewing it, a
// browser, an agent, a script or a tab); the harness's own rule with its own reason; a saved one
// comes back through the same rule; on the wire as set_harness_flags.
@(test)
harness_flags_setting :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hf_reset()
	defer hf_reset()
	cmd := Set_Harness_Flags{harness = .Codex, flags = "-m o3"}
	spec := command_spec(command_type(cmd))
	testing.expect(t, spec != nil && spec.who == .User_Here, "this Mac's user's only")
	for c in ([]Caller{{kind = .UI, hub = true}, {kind = .UI, web = true}, {kind = .Control}, {kind = .Script}, {kind = .Panel, tab_id = 1}, {kind = .Panel, tab_id = 1, claude = true}}) {
		testing.expectf(t, !run_command(cmd, c).ok, "refused for %v", c)
	}
	testing.expect_value(t, state.settings.harness_flags[.Codex], "")
	testing.expect(t, run_command(cmd, {kind = .UI}).ok)
	testing.expect_value(t, state.settings.harness_flags[.Codex], "-m o3")
	// the harness's own rule, its reason as it is
	testing.expect_value(t, run_command(Set_Harness_Flags{harness = .Codex, flags = "--no-daemon"}, {kind = .UI}).error, codex_args_check({"--no-daemon"}))
	testing.expect_value(t, run_command(Set_Harness_Flags{harness = .Claude, flags = "--resume x"}, {kind = .UI}).error, "--resume is Deckhand's to set")
	testing.expect_value(t, run_command(Set_Harness_Flags{harness = .Pi, flags = "-e x.ts"}, {kind = .UI}).error, pi_args_check({"-e", "x.ts"}))
	testing.expect(t, strings.contains(run_command(Set_Harness_Flags{harness = .Claude, flags = `--model "opus`}, {kind = .UI}).error, "quote"))
	testing.expect(t, !run_command(Set_Harness_Flags{harness = .Claude, flags = "--model a\nb"}, {kind = .UI}).ok, "one line")
	testing.expect_value(t, state.settings.harness_flags[.Codex], "-m o3") // unchanged
	testing.expect_value(t, state.settings.harness_flags[.Claude], "")
	// a saved one comes back (Internal) through the same rule
	testing.expect(t, run_command(Set_Harness_Flags{harness = .Pi, flags = "--model sonnet"}, {kind = .Internal}).ok)
	testing.expect(t, !run_command(Set_Harness_Flags{harness = .Pi, flags = "--session x"}, {kind = .Internal}).ok)
	testing.expect_value(t, state.settings.harness_flags[.Pi], "--model sonnet")
	// cleared
	testing.expect(t, run_command(Set_Harness_Flags{harness = .Codex, flags = "  "}, {kind = .UI}).ok)
	testing.expect_value(t, state.settings.harness_flags[.Codex], "")
	// the wire, both ways
	text := command_json(Set_Harness_Flags{harness = .Pi, flags = `--model "a b"`})
	back, err := parse_command(text, context.temp_allocator)
	got, is := back.(Set_Harness_Flags)
	testing.expectf(t, err == "" && is && got.harness == .Pi && got.flags == `--model "a b"`, "%s: %v %s", text, back, err)
	_, err = parse_command(`{"type":"set_harness_flags","harness":"vim","flags":""}`, context.temp_allocator)
	testing.expect(t, err != "", "an unknown harness")
}

// pi's flags on a new session: only the user's (and scripts'), pi's rule.
@(test)
new_chat_args_rule :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hf_reset()
	defer hf_reset()
	append(&state.projects, Project{id = 7, cwd = strings.clone("/nonexistent-deckhand-hf"), group = .Projects})
	testing.expect_value(t, run_command(New_Chat{project_id = 7, args = {"--model", "o"}}, {kind = .Control}).error, "only the user sets pi's flags")
	testing.expect_value(t, run_command(New_Chat{project_id = 7, args = {"--session", "x"}}, {kind = .UI}).error, pi_args_check({"--session", "x"}))
	text := command_json(New_Chat{project_id = 7, args = {"--model", "o"}})
	back, err := parse_command(text, context.temp_allocator)
	nc, is := back.(New_Chat)
	testing.expectf(t, err == "" && is && slice.equal(nc.args, []string{"--model", "o"}), "%s: %v", text, back)
}

// A refused flag's reason names the flag only (its text before `=`, when it looks like a flag),
// never its value or a word that is not a flag: errors reach the log and agents' events. The
// events carry the flags themselves by count or length only.
@(test)
harness_flags_no_secret_in_errors :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hf_reset()
	defer hf_reset()
	SECRET :: "s3cr3tT0KEN"
	checks := [?]string {
		pi_args_check({"--api-key=" + SECRET}),
		pi_args_check({"--model", "x", SECRET}),
		pi_args_check({"--bogus=" + SECRET}),
		pi_args_check({"--x:" + SECRET}),
		pi_args_check({"--model=" + SECRET}),
		codex_args_check({SECRET}),
		codex_args_check({"--bogus=" + SECRET}),
		codex_args_check({"--x:" + SECRET}),
		codex_args_check({"-m", "o3", SECRET}),
		codex_args_check({"--search=" + SECRET}),
		codex_args_check({"--profile=../" + SECRET}),
		claude_args_check({"--resume=" + SECRET}),
	}
	for e in checks do testing.expectf(t, e != "" && !strings.contains(e, SECRET), "%q", e)
	testing.expect_value(t, pi_args_check({"--api-key=" + SECRET}), pi_args_check({"--api-key"})) // named, refused as itself
	// through the commands: the error, and the event agents and the log see
	for cmd in ([]Command{Set_Harness_Flags{harness = .Pi, flags = "--api-key=" + SECRET}, Set_Harness_Flags{harness = .Codex, flags = "--x:" + SECRET}, New_Chat{project_id = 1, args = {SECRET}}}) {
		r := run_command(cmd, {kind = .UI})
		testing.expectf(t, !r.ok && !strings.contains(r.error, SECRET), "%v: %q", cmd, r.error)
	}
	for cmd in ([]Command{Set_Harness_Flags{harness = .Pi, flags = "--model " + SECRET}, New_Chat{project_id = 1, args = {"--model", SECRET}}, New_Claude_Tab{session = 1, args = {"--x", SECRET}}, New_Claude_Session{project_id = 1, codex = true, args = {"-c", "k=" + SECRET}}}) {
		ev := event_json(Command_Event{command = cmd, result = {error = "refused"}})
		testing.expectf(t, !strings.contains(ev, SECRET), "%s", ev)
		testing.expectf(t, !strings.contains(command_json(cmd, redact = true), SECRET), "the log: %v", cmd)
	}
	// the window's and a hub's own wire still carries them (the core needs them)
	back, err := parse_command(command_wire_json(New_Chat{project_id = 1, args = {"--model", SECRET}}), context.temp_allocator)
	nc, _ := back.(New_Chat)
	testing.expect(t, err == "" && len(nc.args) == 2 && nc.args[1] == SECRET, "the wire")
}

// The default flags go to this Mac's own window only: never in a hub's or a paired browser's
// state stream, nor in get_state's snapshot (agents).
@(test)
harness_flags_not_streamed_elsewhere :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hf_reset()
	defer hf_reset()
	SECRET :: "s3cr3tDEFAULT"
	state.settings.harness_flags[.Codex] = strings.clone("-c k=" + SECRET)
	settings_of :: proc() -> string {
		for x in state_sections(&state) do if x[0] == "settings" do return x[1]
		return "<none>"
	}
	when TEST_HOOKS { // the stream kinds stand in through a test hook (a release-hooks build has none)
		old := window_link_swap_for_test(nil)
		defer window_link_swap_for_test(old)
		testing.expect(t, strings.contains(settings_of(), SECRET), "this Mac's window")
		hub := Window_Link{hub = true}
		window_link_swap_for_test(&hub)
		testing.expect(t, !strings.contains(settings_of(), SECRET), "a hub's stream")
		web := Window_Link{web = true}
		window_link_swap_for_test(&web)
		testing.expect(t, !strings.contains(settings_of(), SECRET), "a browser's stream")
		window_link_swap_for_test(nil)
	}
	testing.expect_value(t, state.settings.harness_flags[.Codex], "-c k=" + SECRET) // left as it was
	testing.expect(t, !strings.contains(state_json(), SECRET), "agents' snapshot")
}

// Deckhand's history file: a Codex record's flags are checked by Codex's rule when it loads (a
// profile, a -c), a Claude record's by Claude's.
@(test)
harness_flags_history_load :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hf_reset()
	defer hf_reset()
	recs := []Claude_Record {
		{id = "01a1d0d6-5353-7ff3-9308-ff91070ad501", project = "/w/p", cwd = "/w/p", codex = true, args = {"-p", "work"}},
		{id = "01a1d0d6-5353-7ff3-9308-ff91070ad502", project = "/w/p", cwd = "/w/p", codex = true, args = {"-c", "model=o3"}},
		{id = "01a1d0d6-5353-7ff3-9308-ff91070ad503", project = "/w/p", cwd = "/w/p", args = {"--model", "opus"}},
	}
	run_command(Claude_Restore_History{records = recs}, {kind = .Internal})
	testing.expect_value(t, len(state.claude_history), 3)
	saved := workspace_json()
	clear(&state.claude_history)
	testing.expect_value(t, workspace_restore(saved), "")
	for r in recs {
		got, _ := claude_record(r.id)
		testing.expectf(t, got != nil && slice.equal(got.args, r.args), "%s kept with its flags", r.id)
	}
}

@(private = "file")
hf_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	core_detach_window()
}
