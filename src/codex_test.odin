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
	// a Claude tab beside it (one test) needs Deckhand's plugin: the checkout's, as on CI (no
	// build/claude-code next to the test binary there); never the user's real Claude folder
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	os.set_env("CLAUDE_CONFIG_DIR", fmt.tprintf("%s/deckhand-cx-no-claude-config", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")))
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
	testing.expect_value(t, len(args), 3 + 2 * (len(core.CODEX_HOOKS) + 2))
	for a, i in args {
		if i >= 3 do testing.expectf(t, (i % 2 == 1) == (a == "-c"), "%d: %q", i, a)
		for no in ([]string{"-s", "-a", "-m", "-p", "--sandbox", "--ask-for-approval", "--model", "--profile", "--dangerously-bypass-hook-trust", "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--yolo"}) do testing.expectf(t, a != no, "%q is the user's own setting", a)
		testing.expectf(t, !strings.has_prefix(a, "projects") && !strings.has_prefix(a, "notify") && (!strings.has_prefix(a, "mcp_servers") || i == len(args) - 1), "%q", a)
	}
	// Deckhand's tools: the CLI's MCP server, its token passed by name only (env_vars), never in argv
	testing.expect_value(t, args[len(args) - 1], `mcp_servers.deckhand={command="/tmp/De\"ck h=and/it's\\x/deckhand-cli",args=["mcp"],env_vars=["DECKHAND_SOCKET","DECKHAND_CLAUDE_TOKEN","DECKHAND_SHOTS_DIR"],tool_timeout_sec=620}`)
	testing.expect_value(t, args[4], `hooks.SessionStart=[{hooks=[{type="command",command="'/tmp/De\"ck h=and/it'\\''s\\x/deckhand-cli' hook codex-session-start",timeout=10}]}]`)
	testing.expect_value(t, args[10], `hooks.Stop=[{hooks=[{type="command",command="'/tmp/De\"ck h=and/it'\\''s\\x/deckhand-cli' hook codex-stop",timeout=10}]}]`)
	st := args[len(args) - 3]
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

// One id, one harness, decided by where it was first legitimately seen: a Codex tab never claims a
// Claude conversation Deckhand can see on disk (its report and a Codex resume are refused, nothing
// recorded), and a Codex claim on an id that turns out to be Claude Code's own transcript never
// keeps the Claude tab from it (the Claude tab's report wins; the Codex claim goes).
@(test)
codex_claude_ids_not_claimed :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	cfg := cx_dir("claude-cfg")
	os.set_env("CLAUDE_CONFIG_DIR", cfg)
	_, sess, tab := cx_codex_session(t, "ids")
	p := core.find_project(core.find_session(sess).project_id)
	d := fmt.tprintf("%s/projects/%s", cfg, core.claude_project_slug(p.cwd))
	os.make_directory_all(d)
	transcript :: proc(d, cwd, id: string) {
		line := fmt.tprintf(`{{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":%q,"sessionId":%q,"type":"user","message":{{"role":"user","content":"claude work"}},"uuid":"u1","timestamp":"2026-11-01T10:00:00.000Z"}}`+"\n", cwd, id)
		_ = os.write_entire_file(fmt.tprintf("%s/%s.jsonl", d, id), transmute([]u8)line)
	}
	id_a := "0c1a0de0-1111-4222-8333-444455556666"
	transcript(d, p.cwd, id_a)
	r := core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = id_a}, CX_SCRIPT)
	testing.expect_value(t, r.error, "that id is another harness's conversation")
	testing.expect_value(t, len(state.claude_history), 0)
	r = core.run_command(core.New_Claude_Tab{session = sess, codex = true, resume = id_a}, CX_SCRIPT)
	testing.expect_value(t, r.error, "that id is another harness's conversation")
	testing.expect_value(t, len(state.claude_history), 0)
	// the reverse: a Codex claim first (no transcript yet), then Claude Code's own transcript and
	// its Claude tab's report: the Claude tab gets it, the Codex claim goes
	id_b := "0c1a0de0-1111-4222-8333-444455557777"
	r = core.run_command(core.Claude_Session_Report{tab_id = tab, session_id = id_b}, CX_SCRIPT)
	testing.expect(t, r.ok, r.error)
	cl := core.run_command(core.New_Claude_Tab{session = sess}, CX_UI)
	testing.expect(t, cl.ok, cl.error)
	transcript(d, p.cwd, id_b)
	r = core.run_command(core.Claude_Session_Report{tab_id = cl.created_id, session_id = id_b}, CX_SCRIPT)
	testing.expect(t, r.ok, r.error)
	rec, _ := core.claude_record(id_b)
	testing.expect(t, rec != nil && !rec.codex, "Claude Code's conversation now")
	_, _, ct := core.claude_tab_of(tab)
	testing.expect(t, ct != nil && ct.session_id == "", "the Codex claim is gone")
	testing.expect_value(t, core.claude_tab_of_session(id_b), cl.created_id)
	// another project's Claude transcript (not scanned, so Codex here could claim its id): its own
	// project's row still opens it in Claude Code, and the claim goes
	other := cx_dir("ids-other")
	opid := core.run_command(core.Add_Project{cwd = other}, CX_UI).created_id
	ocwd := strings.clone(core.find_project(opid).cwd, context.temp_allocator)
	od := fmt.tprintf("%s/projects/%s", cfg, core.claude_project_slug(ocwd))
	os.make_directory_all(od)
	id_c := "0c1a0de0-1111-4222-8333-444455558888"
	transcript(od, ocwd, id_c)
	_, sess2, tab2 := cx_codex_session(t, "ids-2")
	r = core.run_command(core.Claude_Session_Report{tab_id = tab2, session_id = id_c}, CX_SCRIPT)
	testing.expect(t, r.ok, r.error) // nothing of the other project's is looked at from here
	r = core.run_command(core.Open_Session_Cmd{project_id = opid, pi_session_id = id_c}, CX_UI)
	testing.expect(t, r.ok, r.error)
	rc, _ := core.claude_record(id_c)
	testing.expect(t, rc != nil && !rc.codex, "Claude Code's row opens it")
	_, _, ct2 := core.claude_tab_of(tab2)
	testing.expect(t, ct2 != nil && ct2.session_id == "", "the claim is gone")
	_ = sess2
	// a Codex record in this project over Claude Code's own transcript (closed, so no tab holds it):
	// clicking the row resumes Claude Code, never codex
	id_e := "0c1a0de0-1111-4222-8333-44445555aaaa"
	_, sess4, tab4 := cx_codex_session(t, "ids-4")
	pid4 := core.find_session(sess4).project_id
	cwd4 := strings.clone(core.find_project(pid4).cwd, context.temp_allocator)
	r = core.run_command(core.Claude_Session_Report{tab_id = tab4, session_id = id_e}, CX_SCRIPT)
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Close_Session{session = sess4}, core.Caller{kind = .Internal})
	d4 := fmt.tprintf("%s/projects/%s", cfg, core.claude_project_slug(cwd4))
	os.make_directory_all(d4)
	transcript(d4, cwd4, id_e)
	r = core.run_command(core.Open_Session_Cmd{project_id = pid4, pi_session_id = id_e}, CX_UI)
	testing.expect(t, r.ok, r.error)
	re, _ := core.claude_record(id_e)
	testing.expect(t, re != nil && !re.codex, "Claude Code's conversation")
	if tid := core.claude_tab_of_session(id_e); tid != 0 {
		_, tb4, _ := core.find_tab(tid)
		testing.expect(t, tb4 != nil && !core.claude_tab_is_codex(tb4^), "a Claude tab, never codex resume")
	} else do testing.fail_now(t, "no tab resumed it")
	// a Codex conversation is never a Claude row whose transcript is gone (no Claude transcript)
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted", title = "codex work"}, CX_SCRIPT)
	id_d := "0c1a0de0-1111-4222-8333-444455559999"
	_, sess3, tab3 := cx_codex_session(t, "ids-3")
	core.run_command(core.Claude_Session_Report{tab_id = tab3, session_id = id_d}, CX_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = tab3, state = "submitted", title = "codex work"}, CX_SCRIPT)
	core.run_command(core.Select_Project{project_id = core.find_session(sess3).project_id}, CX_UI)
	core.claude_disk_rescan()
	core.claude_disk_wait()
	f := core.claude_disk_of(id_d)
	testing.expect(t, f == nil || !f.gone, "a Codex row is not greyed as gone")
}

// A hub (another machine's Deckhand) never starts a Codex tab here, even with this machine's own
// ids (Codex tabs run on the Mac the user works at only, for now): refused before anything runs.
@(test)
codex_hub_refused :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	_, sess, _ := cx_codex_session(t, "hub")
	pid := core.find_session(sess).project_id
	n := len(state.open_sessions)
	hub := core.Caller{kind = .UI, hub = true}
	testing.expect_value(t, core.run_command(core.New_Claude_Session{project_id = pid, codex = true}, hub).error, core.CODEX_REMOTE)
	testing.expect_value(t, core.run_command(core.New_Claude_Tab{session = sess, codex = true}, hub).error, core.CODEX_REMOTE)
	testing.expect_value(t, len(state.open_sessions), n)
	testing.expect_value(t, len(core.find_session(sess).tabs), 1)
	// nor from a Codex row (its resume makes a new Codex tab)
	main_tab := core.find_session(sess).tabs[0].id
	sid := "01a1d0d6-5353-7ff3-9308-ff91070ad5aa"
	core.run_command(core.Claude_Session_Report{tab_id = main_tab, session_id = sid}, CX_SCRIPT)
	core.run_command(core.Close_Session{session = sess}, core.Caller{kind = .Internal})
	testing.expect_value(t, core.run_command(core.Claude_Resume{claude_session_id = sid}, hub).error, core.CODEX_REMOTE)
	testing.expect_value(t, len(state.open_sessions), n - 1)
	// this machine's own callers still can
	testing.expect(t, core.run_command(core.Claude_Resume{claude_session_id = sid}, CX_UI).ok)
}

// Text Deckhand puts into a Codex composer on its own initiative goes through the one rule
// (codex_paste_refusal: the composer rule, and only while Codex is not working or blocked): a
// dropped file's path, anyone's send_text but the user's. The user's own typing and ⌘V are theirs.
@(test)
codex_generated_paste :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	dir := cx_dir("paste")
	got := fmt.tprintf("%s/stdin", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf("exec cat > %s", got))
	_, _, tab := cx_codex_session(t, "paste")
	_, tb, _ := core.claude_tab_of(tab)
	cx_paste_mode(tab)
	cx_osc(tab, .Idle)
	mention := "'/tmp/example @README.txt' "
	testing.expect_value(t, core.codex_paste_refusal(tb, mention), "an @mention would open Codex's file or agent picker; send the name without @")
	testing.expect_value(t, core.codex_paste_refusal(tb, "'/tmp/notes.txt' "), "")
	// the user typing first: a drop still goes in beside it
	core.claude_note_typed(tb)
	testing.expect_value(t, core.codex_paste_refusal(tb, "'/tmp/notes.txt' "), "")
	cx_osc(tab, .Working)
	testing.expect_value(t, core.codex_paste_refusal(tb, "'/tmp/notes.txt' "), "Codex is working")
	cx_osc(tab, .Idle)
	// send_text: a script's and a hub's go through the rule; the user's own paste is theirs
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = tab, text = mention}, CX_SCRIPT).error, "an @mention would open Codex's file or agent picker; send the name without @")
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = tab, text = "/new"}, CX_SCRIPT).error, "text starting with / would be a Codex command (/ slash command, ! shell, $ skill): Deckhand sends only messages")
	testing.expect(t, !core.run_command(core.Send_Text{tab_id = tab, text = mention}, core.Caller{kind = .UI, hub = true}).ok, "a hub's")
	// a drop (generated: the window sets it for dropped paths only): the core decides, on its own
	// state, right before writing; the reason comes back for the toast
	cx_osc(tab, .Working)
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = tab, text = "'/tmp/notes.txt' ", generated = true}, CX_UI).error, "Codex is working")
	cx_osc(tab, .Idle)
	testing.expect_value(t, core.run_command(core.Send_Text{tab_id = tab, text = mention, generated = true}, CX_UI).error, "an @mention would open Codex's file or agent picker; send the name without @")
	testing.expect_value(t, core.json_path(core.command_wire_json(core.Send_Text{tab_id = tab, text = "x", generated = true}), "generated"), "true")
	// the flag only ever makes the core stricter: claiming it gains a caller nothing (not set, a
	// script is checked all the same; set on a shell tab, nothing changes)
	testing.expect(t, !core.run_command(core.Send_Text{tab_id = tab, text = mention, generated = false}, CX_SCRIPT).ok)
	ts, _, _ := core.find_tab(tab)
	sh := core.run_command(core.New_Shell_Tab{session = ts.id}, CX_UI).created_id
	testing.expect(t, core.run_command(core.Send_Text{tab_id = sh, text = "echo @x", generated = true}, CX_UI).ok, "not a Codex tab: as without it")
	testing.expect(t, core.run_command(core.Send_Text{tab_id = tab, text = "@mine\n"}, CX_UI).ok, "the user's own ⌘V")
	testing.expectf(t, strings.contains(cx_read_after(got, 100), "@mine"), "the user's paste went in")
}

// The Enter after a held text's paste is written only if nothing changed meanwhile: a submission
// (the hooks' submitted) cancels it, and Codex working or blocked by then drops it (an Enter
// during a turn would steer it).
@(test)
codex_delayed_enter_rechecked :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	dir := cx_dir("enter")
	got := fmt.tprintf("%s/stdin", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf("stty raw -echo; exec cat > %s", got))
	_, _, tab := cx_codex_session(t, "enter")
	cx_paste_mode(tab)
	time.sleep(100 * time.Millisecond) // stty ran
	enters :: proc(s: string) -> int {return strings.count(s, "\r")}
	now :: proc(path: string) -> string { 	// what codex got, without a tick (cx_read_after ticks: the Enter would go)
		time.sleep(40 * time.Millisecond)
		data, _ := os.read_entire_file(path, context.temp_allocator)
		return string(data)
	}
	// 1. Codex reports working between the paste and its Enter: no Enter
	testing.expect(t, core.run_command(core.Claude_Prompt{tab_id = tab, text = "first"}, CX_CONTROL).ok)
	cx_osc(tab, .Idle)
	core.claude_tick()
	testing.expectf(t, strings.contains(now(got), "first"), "pasted")
	cx_osc(tab, .Working)
	time.sleep(core.CLAUDE_ENTER_DELAY + 20 * time.Millisecond)
	core.claude_tick()
	testing.expect_value(t, enters(cx_read_after(got, 100)), 0)
	// 2. a submission between the paste and its Enter: cancelled
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "idle"}, CX_SCRIPT)
	cx_osc(tab, .Idle)
	testing.expect(t, core.run_command(core.Claude_Prompt{tab_id = tab, text = "second"}, CX_CONTROL).ok)
	core.claude_tick()
	testing.expectf(t, strings.contains(now(got), "second"), "pasted")
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "submitted"}, CX_SCRIPT)
	time.sleep(core.CLAUDE_ENTER_DELAY + 20 * time.Millisecond)
	core.claude_tick()
	testing.expect_value(t, enters(cx_read_after(got, 100)), 0)
	// 3. nothing changed: the Enter goes
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "idle"}, CX_SCRIPT)
	testing.expect(t, core.run_command(core.Claude_Prompt{tab_id = tab, text = "third"}, CX_CONTROL).ok)
	core.claude_tick()
	time.sleep(core.CLAUDE_ENTER_DELAY + 20 * time.Millisecond)
	core.claude_tick()
	testing.expect_value(t, enters(cx_read_after(got, 100)), 1)
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
	// Restart with model's /model is Claude Code's: never pasted into Codex
	testing.expect_value(t, core.claude_paste_message(tb, core.CLAUDE_MODEL_COMMAND, slash = true), "not Deckhand's own command")
}

// Comments into a Codex tab: Send now pastes only Deckhand's fixed line, at Codex's idle (OSC 7501
// and its hooks), as for Claude; its UserPromptSubmit hook takes them (claude.comments) and
// claude.attached clears them. Deckhand's paste keeps the composer rule.
@(test)
codex_comments_send_now :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	dir := cx_dir("cmsend")
	got := fmt.tprintf("%s/stdin", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf("exec cat > %s", got))
	_, sess, tab := cx_codex_session(t, "cmsend")
	s := core.find_session(sess)
	b := core.Tab{id = core.new_id(), kind = core.Browser_Tab{url = "about:blank"}, title = strings.clone("Page"), status = .Running}
	core.pane_add_tab(s, b)
	testing.expect(t, core.run_command(core.Comment_Add{source = .Browser, tab_id = b.id, what = "button", text = "make it blue"}).ok)
	core.session_show_tab(s, tab)
	cx_paste_mode(tab)
	// working: refused with Codex's words
	cx_osc(tab, .Working)
	r := core.run_command(core.Comments_Send_Now{session = sess}, CX_UI)
	testing.expect_value(t, r.error, "Codex is working: wait for its turn to end")
	cx_osc(tab, .Idle)
	r = core.run_command(core.Comments_Send_Now{session = sess}, CX_UI)
	testing.expect(t, r.ok, r.error)
	text := cx_read_after(got, 100)
	testing.expectf(t, strings.has_prefix(text, strings.concatenate({"\x1b[200~", core.CLAUDE_SEND_NOW_LINE, "\x1b[201~"})), "%q", text)
	// the hook's take, then its ack: gone
	data := core.run_command(core.Claude_Comments{tab_id = tab}, CX_SCRIPT).data
	testing.expect(t, strings.contains(core.json_path(data, "text"), "make it blue"), data)
	att := core.json_path(data, "attachment_id")
	id: u64
	for ch in att do id = id * 10 + u64(ch - '0')
	testing.expect(t, core.run_command(core.Claude_Attached{tab_id = tab, attachment_id = id}, CX_SCRIPT).ok)
	testing.expect_value(t, len(core.find_session(sess).comments), 0)
	// Deckhand's own text into Codex keeps the composer rule
	core.run_command(core.Claude_Turn_Report{tab_id = tab, state = "idle"}, CX_SCRIPT)
	time.sleep(core.CLAUDE_ENTER_DELAY + 20 * time.Millisecond)
	core.claude_tick()
	_, tb, _ := core.claude_tab_of(tab) // (the browser tab moved the session's tabs)
	why := core.claude_paste_message(tb, "see @x")
	testing.expectf(t, strings.contains(why, "@mention"), "%q", why)
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
	// CODEX_HOME is HOME (or above it): Codex's sign-in is $CODEX_HOME/auth.json, refused there too
	// (its folder is not all Codex's: only that file), and by inode
	os.set_env("CODEX_HOME", home)
	defer os.unset_env("CODEX_HOME")
	_ = os.write_entire_file(fmt.tprintf("%s/auth.json", home), transmute([]u8)string("{}"))
	testing.expect(t, core.settings_credential(fmt.tprintf("%s/auth.json", home)), "$CODEX_HOME/auth.json")
	testing.expect(t, !core.settings_credential(fmt.tprintf("%s/proj/notes.md", home)), "the rest of HOME is not Codex's")
	link2 := fmt.tprintf("%s/innocent2.json", home)
	posix.link(strings.clone_to_cstring(fmt.tprintf("%s/auth.json", home), context.temp_allocator), strings.clone_to_cstring(link2, context.temp_allocator))
	testing.expect(t, core.settings_credential(link2, core.credential_ids()), "a hard link to $CODEX_HOME/auth.json")
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
	// a saved Codex main tab with flags or read-only (a Codex tab has neither) is skipped cleanly:
	// refused before anything is restored, never a session without its main tab
	n := len(state.open_sessions)
	bid := "01a1d0d6-5353-7ff3-9308-ff91070ad5ff"
	r = core.run_command(core.Restore_Session{project_id = pid, pi_session_id = bid, agent = .Claude, tabs = {{kind = .Claude, claude_id = bid, codex = true, args = {"-m", "o3"}}, {kind = .Shell}}}, core.Caller{kind = .Internal})
	testing.expect(t, !r.ok, "flags")
	r = core.run_command(core.Restore_Session{project_id = pid, pi_session_id = bid, agent = .Claude, tabs = {{kind = .Claude, claude_id = bid, codex = true, readonly = true}}}, core.Caller{kind = .Internal})
	testing.expect(t, !r.ok, "read-only")
	testing.expect_value(t, len(state.open_sessions), n)
}

// Codex conversations found on disk (claude_disk.odin): CODEX_HOME's sessions/YYYY/MM/DD rollouts
// whose first line (session_meta) records the project's folder are rows ("harness":"codex", no
// path); a subagent's, one whose id is not its file's, another folder's and one Deckhand's history
// has are not; a click resumes it with `codex resume <id>`. The files are never written.
@(test)
codex_sessions_on_disk :: proc(t: ^testing.T) {
	context.allocator = cx_reset()
	defer cx_done()
	home := cx_dir("codexhome")
	os.set_env("CODEX_HOME", home)
	defer os.unset_env("CODEX_HOME")
	dir := cx_dir("disk")
	day := fmt.tprintf("%s/sessions/2026/11/12", home)
	os.make_directory_all(day)
	ids := [5]string{"01a1d0d6-5353-7ff3-9308-ff91070ad531", "01a1d0d6-5353-7ff3-9308-ff91070ad532", "01a1d0d6-5353-7ff3-9308-ff91070ad533", "01a1d0d6-5353-7ff3-9308-ff91070ad534", "01a1d0d6-5353-7ff3-9308-ff91070ad535"}
	meta :: proc(id, cwd, source: string) -> string {
		return fmt.tprintf(`{{"timestamp":"2026-11-12T10:00:00Z","type":"session_meta","payload":{{"id":"%s","cwd":"%s","source":%s,"base_instructions":{{"text":"x"}}}}}}`+"\n"+`{{"type":"response_item"}}`+"\n", id, cwd, source)
	}
	write :: proc(day, id, text: string) {
		_ = os.write_entire_file(fmt.tprintf("%s/rollout-2026-11-12T10-00-00-%s.jsonl", day, id), transmute([]u8)text)
	}
	write(day, ids[0], meta(ids[0], dir, `"cli"`)) // listed
	write(day, ids[1], meta(ids[1], dir, `{"subagent":"review"}`)) // a subagent's
	write(day, ids[2], meta(ids[3], dir, `"cli"`)) // an id that is not its file's
	write(day, ids[3], meta(ids[3], "/elsewhere", `"cli"`)) // another folder's
	write(day, ids[4], meta(ids[4], dir, `"cli"`)) // Deckhand's own (its history row)
	core.run_command(core.Claude_Restore_History{records = {{id = ids[4], cwd = dir, project = dir, title = "mine", used = 1, codex = true}}}, core.Caller{kind = .Internal})
	pid := core.run_command(core.Add_Project{cwd = dir}, CX_UI).created_id
	core.run_command(core.Select_Project{project_id = pid}, CX_UI)
	core.claude_disk_wait()
	listed := 0
	for f in state.claude_disk do if f.listed {
		listed += 1
		testing.expect_value(t, f.id, ids[0])
		testing.expect(t, f.codex && f.path == "", "a Codex row, no path kept")
	}
	testing.expect_value(t, listed, 1)
	js := core.state_json()
	testing.expect(t, strings.contains(js, fmt.tprintf(`"id":"%s","project":`, ids[0])) && strings.contains(js, `"harness":"codex","found":true`), js)
	// a click: `codex resume <id>` in a Codex-only session of the project
	argf := fmt.tprintf("%s/argv", dir)
	os.set_env("DECKHAND_CODEX_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s'; exec sleep 30`, argf))
	r := core.run_command(core.Open_Session_Cmd{project_id = pid, pi_session_id = ids[0]}, CX_UI)
	testing.expect(t, r.ok, r.error)
	s := core.find_session(r.created_id)
	testing.expect(t, s != nil && core.open_session_harness(s) == .Codex)
	got := ""
	for _ in 0 ..< 50 {
		data, _ := os.read_entire_file(argf, context.temp_allocator)
		got = string(data)
		if strings.contains(got, "hooks.state") do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, strings.has_prefix(got, fmt.tprintf("resume\n%s\n--no-daemon\n-C\n", ids[0])), "%q", got)
	rec, _ := core.claude_record(ids[0])
	testing.expect(t, rec != nil && rec.codex, "the history keeps it")
}
