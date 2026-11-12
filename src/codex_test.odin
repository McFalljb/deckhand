package main

// Codex CLI tabs (codex.odin; `./build.sh test`). As claude_test.odin: shared State, one thread,
// harmless processes (a shell line stands in for codex: DECKHAND_CODEX_CMD), never the real codex.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"
import gh "ghostty"

@(private = "file")
CX_UI :: core.Caller{kind = .UI}
@(private = "file")
CX_SCRIPT :: core.Caller{kind = .Script}
@(private = "file")
CX_CONTROL :: core.Caller{kind = .Control}

// A CLI path with everything that must not break out of the TOML or the sh command: a double quote,
// a single quote, a backslash, a space and an equals sign (it never has to exist).
@(private = "file")
CX_CLI :: `/tmp/De"ck h=and/it's\x/deckhand-cli`

@(private = "file")
cx_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/deckhand-codex-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

// A fake npm install of codex at version v under dir: <dir>/bin/codex -> the package's bin/codex.js.
@(private = "file")
cx_fake_install :: proc(dir, v: string) -> string {
	pkg := fmt.tprintf("%s/lib/node_modules/@openai/codex", dir)
	os.make_directory_all(fmt.tprintf("%s/bin", pkg))
	os.make_directory_all(fmt.tprintf("%s/bin", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/package.json", pkg), transmute([]u8)fmt.tprintf(`{{"name":"@openai/codex","version":"%s"}}`, v))
	_ = os.write_entire_file(fmt.tprintf("%s/bin/codex.js", pkg), transmute([]u8)string("#!/bin/sh\nexit 1\n"))
	link := fmt.aprintf("%s/bin/codex", dir)
	os.remove(link)
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/bin/codex.js", pkg), context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	return link
}

@(private = "file")
cx_reset :: proc(version := "0.167.2") -> runtime.Allocator {
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
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	os.set_env("DECKHAND_CODEX_CMD", "sleep 30")
	os.set_env("DECKHAND_CODEX_BIN", cx_fake_install(cx_dir("bin"), version))
	core.claude_found = .Yes
	core.codex_found = .Yes
	core.codex_login_set(.Signed_In) // never asks (a stand-in would only sleep)
	core.claude_cli_override = CX_CLI
	core.claude_status_reset()
	return runtime.heap_allocator()
}

@(private = "file")
cx_done :: proc() {
	core.claude_cli_override = ""
	core.codex_login_set(.Unknown)
	os.unset_env("DECKHAND_CODEX_BIN")
	os.unset_env("DECKHAND_CODEX_CMD")
}

// A project with one open pi session; and one Codex-only session in it (its id, its tab's).
@(private = "file")
cx_codex_session :: proc(t: ^testing.T, tag: string) -> (dir: string, sess, tab: u64) {
	dir = cx_dir(tag)
	pid := core.run_command(core.Add_Project{cwd = dir}, CX_UI).created_id
	r := core.run_command(core.New_Claude_Session{project_id = pid, codex = true}, CX_UI)
	testing.expect(t, r.ok, r.error)
	s := core.find_session(r.created_id)
	if s == nil do return dir, 0, 0
	return dir, s.id, s.tabs[0].id
}

@(private = "file")
cx_osc :: proc(tab_id: u64, st: core.Prog_State, kind := core.Prog_Kind.None) {
	core.run_command(core.Program_Status{tab_id = tab_id, summary = {state = st, kind = kind, app = "codex", progress = -1}})
}

@(private = "file")
cx_paste_mode :: proc(id: u64) {
	t := core.term_of(id)
	if t == nil do return
	msg := "\x1b[?2004h"
	gh.terminal_vt_write(t.gt, raw_data(msg), len(msg))
}

@(private = "file")
cx_read_after :: proc(path: string, ms: int) -> string {
	time.sleep(time.Duration(ms) * time.Millisecond)
	core.claude_tick()
	time.sleep(150 * time.Millisecond)
	core.claude_tick()
	time.sleep(150 * time.Millisecond)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

// ---- the command line ----

// Codex 0.167.2's hook-trust hash (the research's reference, hookhash.py, which matched the
// app-server's hooks/list currentHash). A newer Codex that changes the recipe shows its review
// dialog again: re-check against it and pin the new vector here.
@(test)
codex_hook_hash_vectors :: proc(t: ^testing.T) {
	testing.expect_value(t, core.CODEX_HASH_PINNED, "0.167.2")
	testing.expect_value(t, core.codex_hook_hash("stop", `"$DECKHAND_CLI" hook Stop`, 600), "sha256:7f2778c2187f90b9f933e524d2f3043d611ef2bdf1305b583becb0f02e88883f")
	testing.expect_value(t, core.codex_hook_hash("stop", `'/Applications/Deckhand.app/Contents/MacOS/deckhand-cli' hook codex-stop`, 10), "sha256:b753b5c97f939aba215a22c5000dd5b70b9e3f49dfafc2189f2b1fccdb5607e0")
	// quotes and a backslash in the command: escaped in the JSON as serde_json does
	testing.expect_value(t, core.codex_hook_hash("session_start", core.codex_hook_command(CX_CLI, "codex-session-start"), 10), "sha256:48f7baad2a00602dafa84fb9f059aadb66c31598c05c62935aca0f65a8f723a9")
}

@(test)
codex_toml_and_ids :: proc(t: ^testing.T) {
	q, ok := core.codex_toml_string(`a"b\c d=e 'f'`)
	testing.expect(t, ok)
	testing.expect_value(t, q, `"a\"b\\c d=e 'f'"`)
	q, ok = core.codex_toml_string("x\ny\t\x01\x7f é")
	testing.expect_value(t, q, `"x\ny\t\u0001\u007F é"`)
	_, ok = core.codex_toml_string("bad \xff utf8")
	testing.expect(t, !ok, "not UTF-8: refused")
	testing.expect(t, core.codex_id_ok("01a1d0d6-5353-7ff3-9308-ff91070ad530"))
	testing.expect(t, core.codex_id_ok("7DF238B2-FD48-4586-9110-35EA73669D4D"))
	for bad in ([]string{"", "abc-1", "--resume", "01a1d0d6-5353-7ff3-9308-ff91070ad53", "01a1d0d6-5353-7ff3-9308-ff91070ad530 ", "01a1d0d6_5353-7ff3-9308-ff91070ad530", "0g a1d0d6-5353-7ff3-9308-ff91070ad53"}) do testing.expectf(t, !core.codex_id_ok(bad), "%q", bad)
}

// The argv: --no-daemon always; the cwd its own element; nothing that overrides the user's own
// Codex settings; the hooks' TOML holds whatever the CLI's path has; a resume only by a UUID.
@(test)
codex_argv :: proc(t: ^testing.T) {
	cwd := `/w/my "proj" = x/it's`
	args, why := core.codex_args(CX_CLI, cwd, "")
	testing.expect_value(t, why, "")
	testing.expect_value(t, args[0], "--no-daemon")
	testing.expect_value(t, args[1], "-C")
	testing.expect_value(t, args[2], cwd)
	testing.expect_value(t, len(args), 3 + 2 * (len(core.CODEX_HOOKS) + 1))
	for a, i in args {
		if i >= 3 do testing.expectf(t, (i % 2 == 1) == (a == "-c"), "%d: %q", i, a)
		for no in ([]string{"-s", "-a", "-m", "-p", "--sandbox", "--ask-for-approval", "--model", "--profile", "--dangerously-bypass-hook-trust", "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--yolo"}) do testing.expectf(t, a != no, "%q is the user's own setting", a)
		testing.expectf(t, !strings.has_prefix(a, "projects") && !strings.has_prefix(a, "notify") && !strings.has_prefix(a, "mcp_servers"), "%q", a)
	}
	testing.expect_value(t, args[4], `hooks.SessionStart=[{hooks=[{type="command",command="'/tmp/De\"ck h=and/it'\\''s\\x/deckhand-cli' hook codex-session-start",timeout=10}]}]`)
	testing.expect_value(t, args[10], `hooks.Stop=[{hooks=[{type="command",command="'/tmp/De\"ck h=and/it'\\''s\\x/deckhand-cli' hook codex-stop",timeout=10}]}]`)
	st := args[len(args) - 1]
	testing.expect(t, strings.has_prefix(st, `hooks.state={"/<session-flags>/config.toml:session_start:0:0"={trusted_hash="sha256:48f7baad2a00602dafa84fb9f059aadb66c31598c05c62935aca0f65a8f723a9"},`), st)
	for h in core.CODEX_HOOKS do testing.expectf(t, strings.contains(st, fmt.tprintf(`"/<session-flags>/config.toml:%s:0:0"={{trusted_hash="%s"}}`, h.key, core.codex_hook_hash(h.key, core.codex_hook_command(CX_CLI, h.arg), core.CODEX_HOOK_TIMEOUT))), "%s trusted", h.key)
	// resume: the subcommand and its UUID first
	args, why = core.codex_args(CX_CLI, "/w/p", "01a1d0d6-5353-7ff3-9308-ff91070ad530")
	testing.expect_value(t, why, "")
	testing.expect(t, args[0] == "resume" && args[1] == "01a1d0d6-5353-7ff3-9308-ff91070ad530" && args[2] == "--no-daemon" && args[3] == "-C" && args[4] == "/w/p")
	// refused: a resume id that is not a UUID, a relative cwd, a CLI path that can't go into TOML
	_, why = core.codex_args(CX_CLI, "/w/p", "--last")
	testing.expect_value(t, why, "not a Codex session id")
	_, why = core.codex_args(CX_CLI, "w/p", "")
	testing.expect(t, why != "")
	for bad in ([]string{"", "deckhand-cli", "/tmp/a\nb/deckhand-cli", "/tmp/a\x1bb/cli", "/tmp/\xff/cli"}) {
		_, why = core.codex_args(bad, "/w/p", "")
		testing.expectf(t, why != "", "%q refused", bad)
	}
}

// ---- text into Codex's composer ----

@(test)
codex_composer_text :: proc(t: ^testing.T) {
	for bad in ([]string{
		"/status", "!rm -rf ~", "$deploy", "  /model", "\n\n/new", "\t!ls", " \n $skill",
		"@src/main.rs please", "look at @README", "a\n@file", "a\t@x", "use $deploy now", "x\n$skill",
		"escape \x1b[2J", "cr\rhere", "del\x7f",
	}) {
		testing.expectf(t, core.codex_command_text(bad) != "", "%q refused", bad)
	}
	for good in ([]string{
		"fix #12 and run /tmp/x !", "email me@example.com", "costs $5 or $ 6", "a @ b", "ends with @",
		"line one\n/not a command on a later line", "line one\n!not shell either", "tabs\tand\nnewlines",
		"unicode ／status is not a slash", "price:$5", "x@y",
	}) {
		testing.expectf(t, core.codex_command_text(good) == "", "%q allowed: %s", good, core.codex_command_text(good))
	}
	// Claude's rule is unchanged (its own tests: claude_prompt_no_commands)
	testing.expect_value(t, core.claude_command_text("$deploy"), "")
	testing.expect_value(t, core.claude_command_text("look at @README"), "")
}

// ---- a Codex tab ----

@(test)
codex_session_start_and_row :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	dir := cx_dir("argv")
	argf := fmt.tprintf("%s/argv", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s'; env | grep -E '^DECKHAND_(CLAUDE_TAB|SOCKET|CLI)=' | sed 's/=.*//' >> '%s'; exec sleep 30`, argf, argf))
	_, sess, tab := cx_codex_session(t, "start")
	testing.expect(t, tab != 0)
	s := core.find_session(sess)
	testing.expect_value(t, s.agent, core.Session_Agent.Claude)
	_, tb, ct := core.claude_tab_of(tab)
	testing.expect(t, ct != nil && ct.codex && tb.title == "Codex" && ct.account == "" && len(ct.args) == 0)
	snap := core.state_json()
	testing.expect_value(t, core.json_path(snap, "open_sessions.0.tabs.0.harness"), "codex")
	testing.expect_value(t, core.json_path(snap, "codex_installed"), "true")
	testing.expect_value(t, core.open_session_title(s), "Untitled Codex session")
	// what codex got: --no-daemon, its folder, Deckhand's hooks; the environment of a Claude tab
	got := ""
	for _ in 0 ..< 50 {
		data, _ := os.read_entire_file(argf, context.temp_allocator)
		got = string(data)
		if strings.contains(got, "DECKHAND_CLI") do break
		time.sleep(20 * time.Millisecond)
	}
	lines := strings.split_lines(got, context.temp_allocator)
	testing.expectf(t, len(lines) > 3 && lines[0] == "--no-daemon" && lines[1] == "-C", "%q", got)
	testing.expect(t, strings.contains(got, "hooks.state={"), got)
	testing.expect(t, strings.contains(got, "DECKHAND_CLAUDE_TAB") || !core.socket_running(), got)
	// before the first prompt: no session id, no row; held text waits for Codex's own idle
	testing.expect_value(t, len(state.claude_history), 0)
	r := core.run_command(core.Claude_Prompt{tab_id = tab, text = "hello"}, CX_CONTROL)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.json_path(r.data, "waits"), "Codex is starting (or a dialog of its own is open)")
	// the first prompt: SessionStart (lazy) with Codex's id; a Claude-style id is refused
	testing.expect(t, !core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = "abc-1"}, CX_SCRIPT).ok, "not a UUID")
	sid := "01a1d0d6-5353-7ff3-9308-ff91070ad530"
	r = core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup", transcript_path = "/Users/u/.codex/sessions/2026/11/12/x.jsonl", model = "gpt-5.5"}, CX_SCRIPT)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, r.data, "") // never a title for Codex
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted", title = "Fix the login bug"}, CX_SCRIPT)
	testing.expect_value(t, len(state.claude_history), 1)
	rec := state.claude_history[0]
	testing.expect(t, rec.codex && rec.id == sid && rec.account == "" && rec.transcript == "" && rec.title == "Fix the login bug", "the row: a Codex conversation")
	testing.expect_value(t, core.find_session(sess).pi_session_id, sid)
	snap = core.state_json()
	testing.expect_value(t, core.json_path(snap, "claude_sessions.0.harness"), "codex")
	testing.expect(t, strings.contains(core.claude_tab_tip(core.find_session(sess).tabs[0]), "Codex · model gpt-5.5"))
	// a Claude tab's report never names a Codex conversation (one record, one harness)
	cl := core.run_command(core.New_Claude_Tab{session = sess}, CX_UI)
	testing.expect(t, cl.ok, cl.error)
	core.run_command(core.Close_Tab{tab_id = tab}, core.Caller{kind = .Internal})
	testing.expect_value(t, core.run_command(core.Claude_Session_Report{tab_id = cl.created_id, session_id = sid}, CX_SCRIPT).error, "that id is another harness's conversation")
}

// Resume from its row: `codex resume <id>` in a Codex-only session of its project; flags and
// accounts never; a Claude conversation's id is not a Codex one.
@(test)
codex_resume_from_row :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	dir, sess, tab := cx_codex_session(t, "resume")
	sid := "01a1d0d6-5353-7ff3-9308-ff91070ad530"
	testing.expect(t, core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid}, CX_SCRIPT).ok)
	core.run_command(core.Close_Session{session = sess}, core.Caller{kind = .Internal})
	testing.expect(t, core.find_session(sess) == nil, "closed")
	argf := fmt.tprintf("%s/argv", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s'; exec sleep 30`, argf))
	r := core.run_command(core.Claude_Resume{claude_session_id = sid}, CX_UI)
	testing.expect(t, r.ok, r.error)
	_, tb, ct := core.claude_tab_of(r.created_id)
	testing.expect(t, ct != nil && ct.codex && ct.session_id == sid && tb.title == "Codex")
	got := ""
	for _ in 0 ..< 50 {
		data, _ := os.read_entire_file(argf, context.temp_allocator)
		got = string(data)
		if strings.contains(got, "hooks.state") do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, strings.has_prefix(got, fmt.tprintf("resume\n%s\n--no-daemon\n-C\n", sid)), "%q", got)
	// the same conversation again: its tab is focused, never a second one
	r2 := core.run_command(core.Claude_Resume{claude_session_id = sid}, CX_UI)
	testing.expect_value(t, r2.created_id, r.created_id)
	// harness mismatch: a Claude tab never resumes a Codex conversation, nor the reverse
	s, _, _ := core.find_tab(r.created_id)
	testing.expect_value(t, core.run_command(core.New_Claude_Tab{session = s.id, resume = sid}, CX_UI).error, "that id is another harness's conversation")
	// flags and accounts: refused for Codex
	testing.expect_value(t, core.run_command(core.New_Claude_Tab{session = s.id, codex = true, args = {"-m", "o3"}}, CX_UI).error, core.CODEX_NO_FLAGS)
	testing.expect(t, !core.run_command(core.New_Claude_Tab{session = s.id, codex = true, account = "/x"}, CX_UI).ok)
	testing.expect_value(t, core.run_command(core.New_Claude_Tab{session = s.id, codex = true, resume = "--last"}, CX_UI).error, "resume must be a Codex session id")
}

// Held prompts: only at Codex's idle per OSC 7501 (and the hooks once they report), bracketed paste,
// nothing typed; never during a turn or a dialog; Send now too.
@(test)
codex_held_prompts :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	dir := cx_dir("held")
	got := fmt.tprintf("%s/stdin", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf("exec cat > %s", got))
	_, _, tab := cx_codex_session(t, "held")
	_, tb, ct := core.claude_tab_of(tab)
	cx_paste_mode(tab)
	// refusals, with the reason
	for bad in ([]string{"/new", "!ls", "$skill", "look at @x"}) {
		r := core.run_command(core.Claude_Prompt{tab_id = tab, text = bad}, CX_CONTROL)
		testing.expectf(t, !r.ok && r.error != "", "%q: %v", bad, r)
	}
	testing.expect(t, core.run_command(core.Claude_Prompt{tab_id = tab, text = "hello codex"}, CX_CONTROL).ok)
	// no OSC 7501 yet (a login or trust dialog): it waits, Send now too
	testing.expect_value(t, cx_read_after(got, 50), "")
	testing.expect_value(t, core.run_command(core.Claude_Held_Op{tab_id = tab, op = "send"}, CX_UI).error, "Codex is starting (or a dialog of its own is open)")
	// working: Enter would steer the turn
	cx_osc(tab, .Working)
	testing.expect_value(t, cx_read_after(got, 50), "")
	testing.expect_value(t, core.run_command(core.Claude_Held_Op{tab_id = tab, op = "send"}, CX_UI).error, "Codex is working")
	// a permission dialog
	cx_osc(tab, .Blocked, .Permission)
	_, why := core.claude_ready(tb, ct)
	testing.expect_value(t, why, "Codex is waiting for you")
	testing.expect_value(t, core.json_path(core.state_json(), "open_sessions.0.tabs.0.held_wait"), "Codex is waiting for you")
	// idle (its composer up, before any hook: SessionStart is lazy): it goes, as a bracketed paste
	cx_osc(tab, .Idle)
	text := cx_read_after(got, 100)
	testing.expectf(t, strings.contains(text, "\x1b[200~hello codex\x1b[201~"), "%q", text)
	testing.expect_value(t, len(ct.held), 0)
	testing.expect_value(t, ct.turn, core.Claude_Turn.Working) // until its hooks say otherwise
	// the hooks say working: held again even if OSC 7501 lags at idle
	time.sleep(core.CLAUDE_ENTER_DELAY + 20 * time.Millisecond)
	core.claude_tick()
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted"}, CX_SCRIPT)
	core.run_command(core.Claude_Prompt{tab_id = tab, text = "second"}, CX_CONTROL)
	_, why = core.claude_ready(tb, ct)
	testing.expect_value(t, why, "Codex is working")
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "waiting"}, CX_SCRIPT)
	_, why = core.claude_ready(tb, ct)
	testing.expect_value(t, why, "Codex is waiting for you")
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "idle"}, CX_SCRIPT)
	core.claude_note_typed(tb)
	_, why = core.claude_ready(tb, ct)
	testing.expect_value(t, why, "you are typing a message")
	// Send now: into what is typed, at idle only
	testing.expect(t, core.run_command(core.Claude_Held_Op{tab_id = tab, op = "send"}, CX_UI).ok)
	testing.expect_value(t, len(ct.held), 0)
	// comments and Deckhand's own pastes are Claude's: refused
	testing.expect_value(t, core.claude_paste_message(tb, "x"), core.CODEX_NO_COMMENTS)
	testing.expect_value(t, core.run_command(core.Claude_Comments{tab_id = tab}, CX_SCRIPT).error, core.CODEX_NO_COMMENTS)
}

// The bars: signed out (Codex reports no OSC 7501 behind its login screen); hooks silent after its
// first turn began with no hook in GRACE; both go when what they say is no longer so.
@(test)
codex_status_bars :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	core.codex_login_set(.Signed_Out)
	_, _, tab := cx_codex_session(t, "bars")
	_, tb, _ := core.claude_tab_of(tab)
	core.claude_status_tick()
	testing.expect_value(t, core.claude_status_message(tb), core.CODEX_SIGNED_OUT)
	testing.expect(t, !core.claude_hooks_silent(tb), "no turn yet")
	// signed in on its own screen: the composer reports idle
	cx_osc(tab, .Idle)
	core.claude_status_tick()
	testing.expect_value(t, core.claude_status_message(tb), "")
	testing.expect_value(t, core.codex_login_state(), core.Codex_Login.Unknown) // asked again at the next start
	core.codex_login_set(.Signed_In)
	// idle for long: not silent (SessionStart is lazy)
	later := time.tick_add(time.tick_now(), core.CLAUDE_HOOKS_GRACE + time.Second)
	core.claude_status_tick(later)
	testing.expect(t, !core.claude_hooks_silent(tb, later))
	// a turn ran, no hook in GRACE: silent
	cx_osc(tab, .Working)
	now := time.tick_now()
	core.claude_status_tick(now)
	later = time.tick_add(now, core.CLAUDE_HOOKS_GRACE + time.Second)
	testing.expect(t, core.claude_hooks_silent(tb, later))
	testing.expect_value(t, core.claude_status_message(tb, later), core.CODEX_HOOKS_SILENT)
	testing.expect(t, !strings.contains(core.state_json(), "claude_version_old"), "never Claude's version bar")
	// a hook reports: no bar
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted"}, CX_SCRIPT)
	testing.expect(t, !core.claude_hooks_silent(tb, later))
	testing.expect_value(t, core.claude_status_message(tb, later), "")
}

// Too old (no OSC 7501), not installed: never started, with what to do.
@(test)
codex_too_old_and_missing :: proc(t: ^testing.T) {
	context.allocator = cx_reset(version = "0.160.0")
	defer cx_done()
	testing.expect_value(t, core.codex_version(), "0.160.0")
	dir := cx_dir("old")
	pid := core.run_command(core.Add_Project{cwd = dir}, CX_UI).created_id
	r := core.run_command(core.New_Claude_Session{project_id = pid, codex = true}, CX_UI)
	testing.expect_value(t, r.error, "could not start Codex")
	testing.expect_value(t, len(state.open_sessions), 0)
	core.codex_installed_probe = proc() -> bool {return false}
	defer core.codex_installed_probe = nil
	r = core.run_command(core.New_Claude_Session{project_id = pid, codex = true}, CX_SCRIPT)
	testing.expect_value(t, r.error, core.CODEX_MISSING)
	testing.expect_value(t, core.codex_label("New Codex tab"), "New Codex tab — Codex not installed")
	// Chats while chats are read-only: no read-only Codex yet
	state.settings.chats_readonly = true
	ch := core.chats_project()
	if ch != nil do testing.expect_value(t, core.run_command(core.New_Claude_Session{project_id = ch.id, codex = true}, CX_UI).error, core.CODEX_READONLY)
}

// The version from where codex links to (never run).
@(test)
codex_version_detection :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	link := cx_fake_install(cx_dir("ver"), "0.167.2")
	testing.expect_value(t, core.codex_version_of(link), "0.167.2")
	testing.expect_value(t, core.codex_version_of("/opt/homebrew/Caskroom/codex/0.170.1/codex-aarch64-apple-darwin"), "0.170.1")
	testing.expect_value(t, core.codex_version_of("/usr/local/bin/some-other"), "")
	testing.expect(t, core.claude_version_below("0.141.0", core.CODEX_MIN_VERSION))
	testing.expect(t, !core.claude_version_below("0.163.0", core.CODEX_MIN_VERSION))
	// a unit test never finds the developer's own codex on PATH (the other tests' pickers and
	// checklists stay as they were): only DECKHAND_CODEX_BIN's
	os.unset_env("DECKHAND_CODEX_BIN")
	core.codex_recheck()
	testing.expect_value(t, core.codex_binary(), "")
	testing.expect(t, !core.codex_installed(), "no codex in a unit test without DECKHAND_CODEX_BIN")
	os.set_env("DECKHAND_CODEX_BIN", link)
	core.codex_recheck()
	testing.expect(t, core.codex_installed())
	os.unset_env("DECKHAND_CODEX_BIN")
	core.codex_recheck()
}

// Codex's sign-in and state are never opened, listed or uploaded; its config is the user's.
@(test)
codex_credential_guard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	home := cx_dir("home")
	old := os.get_env("HOME", context.temp_allocator)
	os.set_env("HOME", home)
	defer os.set_env("HOME", old)
	os.make_directory_all(fmt.tprintf("%s/.codex/sessions/2026/11/12", home))
	_ = os.write_entire_file(fmt.tprintf("%s/.codex/auth.json", home), transmute([]u8)string("{}"))
	for p in ([]string{"/.codex/auth.json", "/.codex/sessions/2026/11/12/rollout-x.jsonl", "/.codex/history.jsonl", "/.codex/state_5.sqlite", "/.codex/log/codex-tui.log"}) {
		testing.expectf(t, core.settings_credential(strings.concatenate({home, p}, context.temp_allocator)), "%s refused", p)
	}
	for p in ([]string{"/.codex/config.toml", "/.codex/AGENTS.md", "/.codex/prompts/x.md", "/proj/.codex/config.toml", "/proj/notes.md"}) {
		testing.expectf(t, !core.settings_credential(strings.concatenate({home, p}, context.temp_allocator)), "%s allowed", p)
	}
	// a repo's own .codex/auth.json, and a hard link to the sign-in elsewhere
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/proj/.codex/auth.json", home)))
	link := fmt.tprintf("%s/innocent.json", home)
	posix.link(strings.clone_to_cstring(fmt.tprintf("%s/.codex/auth.json", home), context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	testing.expect(t, core.settings_credential(link, core.credential_ids()), "a hard link to auth.json")
}

// The wire: harness "codex" on new_claude_session and new_claude_tab (anything else refused); the
// workspace keeps a Codex tab as kind "codex" (an older Deckhand drops it, never starting claude on
// its id) and its record with codex: true.
@(test)
codex_wire_and_persist :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	cmd, err := core.parse_command(`{"type":"new_claude_session","project_id":1,"harness":"codex"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	c, is := cmd.(core.New_Claude_Session)
	testing.expect(t, is && c.codex)
	cmd, err = core.parse_command(`{"type":"new_claude_tab","session":1,"harness":"claude"}`, context.temp_allocator)
	testing.expect(t, err == "" && !cmd.(core.New_Claude_Tab).codex)
	_, err = core.parse_command(`{"type":"new_claude_tab","session":1,"harness":"gpt"}`, context.temp_allocator)
	testing.expect_value(t, err, "harness must be claude or codex")
	testing.expect(t, strings.contains(core.command_json(core.New_Claude_Session{project_id = 3, codex = true}, true), `"harness":"codex"`))
	testing.expect(t, !strings.contains(core.command_json(core.New_Claude_Session{project_id = 3}, true), `harness`), "Claude's wire is unchanged")
	// the window's commands to its core (command_wire_json): the harness crosses, both commands
	for c in ([]core.Command{core.New_Claude_Session{project_id = 3, codex = true}, core.New_Claude_Tab{session = 2, codex = true}}) {
		js := core.command_wire_json(c)
		back, perr := core.parse_command(js, context.temp_allocator)
		testing.expect_value(t, perr, "")
		#partial switch x in back {
		case core.New_Claude_Session: testing.expect(t, x.codex, js)
		case core.New_Claude_Tab:     testing.expect(t, x.codex, js)
		case:                         testing.fail_now(t, js)
		}
	}
	testing.expect(t, !strings.contains(core.command_wire_json(core.New_Claude_Session{project_id = 3}), "harness"), "Claude's wire is unchanged")
	_, sess, tab := cx_codex_session(t, "persist")
	sid := "01a1d0d6-5353-7ff3-9308-ff91070ad530"
	core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = sid}, CX_SCRIPT)
	saved := core.workspace_json()
	testing.expect(t, strings.contains(saved, `"kind":"codex"`), saved)
	testing.expect(t, strings.contains(saved, `"codex":true`), saved)
	// back from the saved workspace: the Codex tab (not started until shown) and its record
	pid := core.find_session(sess).project_id
	core.run_command(core.Close_Session{session = sess}, core.Caller{kind = .Internal})
	clear(&state.claude_history)
	testing.expect_value(t, core.workspace_restore(saved), "")
	testing.expect(t, len(state.claude_history) == 1 && state.claude_history[0].codex, "its record")
	found := false
	for &o in state.open_sessions do if o.project_id == pid && o.pi_session_id == sid {
		testing.expect(t, core.claude_tab_is_codex(o.tabs[0]) && o.tabs[0].status == .Not_Started && o.tabs[0].title == "Codex")
		found = true
	}
	testing.expect(t, found, "restored")
	// shown, it starts with Codex installed and Claude Code not (its harness's check, not Claude's)
	core.claude_installed_probe = proc() -> bool {return false}
	defer core.claude_installed_probe = nil
	core.claude_found = .No
	for &o in state.open_sessions do if o.project_id == pid && o.pi_session_id == sid {
		core.focus_session(o.id, core.Caller{kind = .UI})
		testing.expect(t, o.tabs[0].status != .Not_Started && o.tabs[0].status != .Exited, "started")
	}
	core.claude_found = .Yes
	// a saved Codex tab with flags or a non-UUID id is not restored
	r := core.run_command(core.Restore_Session{project_id = pid, pi_session_id = "abc-1", agent = .Claude, tabs = {{kind = .Claude, claude_id = "abc-1", codex = true}}}, core.Caller{kind = .Internal})
	testing.expect(t, !r.ok, "not a Codex session id")
}
