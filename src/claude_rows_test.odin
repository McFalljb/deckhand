package main

// Claude rows and tabs at parity with pi's (claude_rows.odin; docs/CLAUDE.md §4b): the transcript
// path and model in the history, the row's session info, Reveal and Copy path, the model's
// switches, the question and error dots, the rename pushed to Claude Code, the exit's bell entry,
// Send and close in a Claude-only session, Ask Claude to review, PI_KIT_NOTES_DIR and
// `pi-desk --claude DIR`. Same rules as core_test.odin: shared global State, one thread, harmless
// processes standing in for claude.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import sapp "../vendor/sokol-odin/sokol/app"
import gh "ghostty"

@(private = "file")
R_UI :: Caller{kind = .UI}
@(private = "file")
R_SCRIPT :: Caller{kind = .Script}
@(private = "file")
R_CONTROL :: Caller{kind = .Control}

@(private = "file")
r_clip: string
@(private = "file")
r_revealed: string

@(private = "file")
r_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	persist = {}
	dead_tab_reset()
	claude_installed_probe = stand_in_installed // the stand-in claude counts as installed
	r_clip, r_revealed = "", ""
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {r_clip = strings.clone(s, runtime.heap_allocator())}, reveal = proc(p: string) {r_revealed = strings.clone(p, runtime.heap_allocator())}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	os.set_env("PI_DESK_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("PI_DESK_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	claude_found = .Yes
	// never the user's real Claude folder: a fake one (tests that need files make their own)
	os.set_env("CLAUDE_CONFIG_DIR", fmt.tprintf("%s/pi-desk-cr-no-claude-config", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")))
	return runtime.heap_allocator()
}

@(private = "file")
r_done :: proc() {
	inbox_drain()
	for _, t in terms do reader_stop_and_close(t)
	os.set_env("PI_DESK_CLAUDE_CMD", "sleep 30")
	os.unset_env("CLAUDE_CONFIG_DIR")
}

@(private = "file")
r_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/pi-desk-cr-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

// A Claude config dir (CLAUDE_CONFIG_DIR) with a transcript for sid under projects/.
@(private = "file")
r_config :: proc(tag, sid: string) -> (cfg, transcript: string) {
	cfg = r_dir(tag)
	os.set_env("CLAUDE_CONFIG_DIR", cfg)
	os.make_directory_all(fmt.tprintf("%s/projects/-x", cfg))
	transcript = fmt.aprintf("%s/projects/-x/%s.jsonl", cfg, sid)
	_ = os.write_entire_file(transcript, transmute([]u8)string("{}\n"))
	return
}

@(private = "file")
r_claude_session :: proc(t: ^testing.T, pid: u64) -> (sess, tab: u64) {
	r := run_command(New_Claude_Session{project_id = pid}, R_UI)
	testing.expect(t, r.ok, r.error)
	sess = r.created_id
	if s := find_session(sess); s != nil && len(s.tabs) > 0 do tab = s.tabs[0].id
	return
}

@(private = "file")
r_wait_exit :: proc(tab_id: u64) -> bool {
	for _ in 0 ..< 500 {
		pump_all()
		if _, tab, _ := find_tab(tab_id); tab != nil && tab.status == .Exited do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// SessionStart's transcript_path is kept only under Claude's config dir's projects/ (real paths:
// no `..`, no symlink out, a .jsonl file); its model is kept, one clean token.
@(test)
claude_rows_transcript_and_model :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	sid := "a1a1a1a1-0000-4000-8000-000000000001"
	cfg, transcript := r_config("cfg", sid)
	dir := r_dir("proj")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	_, tab := r_claude_session(t, pid)
	r := run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup", transcript_path = transcript, model = "claude-opus-5[1m]"}, R_SCRIPT)
	testing.expect(t, r.ok, r.error)
	rec, _ := claude_record(sid)
	if !testing.expect(t, rec != nil) do return
	testing.expect_value(t, rec.transcript, transcript)
	testing.expect_value(t, rec.model, "claude-opus-5[1m]")
	_, _, ct := claude_tab_of(tab)
	testing.expect_value(t, ct.model, "claude-opus-5[1m]")
	// a new conversation's file may not exist yet: its folder is checked
	later := fmt.tprintf("%s/projects/-y/%s.jsonl", cfg, sid)
	testing.expect_value(t, claude_transcript_ok(later), later)
	// refused: outside, `..`, a symlink out, not .jsonl, relative, a line break
	outside := r_dir("outside")
	_ = os.write_entire_file(fmt.tprintf("%s/o.jsonl", outside), transmute([]u8)string("{}"))
	os.symlink(outside, fmt.tprintf("%s/projects/link", cfg))
	for bad in ([]string {
			fmt.tprintf("%s/o.jsonl", outside),
			fmt.tprintf("%s/projects/../evil.jsonl", cfg),
			fmt.tprintf("%s/projects/-x/../../evil.jsonl", cfg),
			fmt.tprintf("%s/projects/link/o.jsonl", cfg),
			fmt.tprintf("%s/projects/-x/%s.txt", cfg, sid),
			fmt.tprintf("%s/projects", cfg),
			fmt.tprintf("%s/settings.jsonl", cfg),
			"projects/-x/a.jsonl",
			fmt.tprintf("%s/projects/-x/a\n.jsonl", cfg),
		}) {
		testing.expectf(t, claude_transcript_ok(bad) == "", "refused: %q", bad)
	}
	// a report with one: kept as before, the bad path not
	r = run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "resume", transcript_path = fmt.tprintf("%s/projects/link/o.jsonl", cfg)}, R_SCRIPT)
	testing.expect(t, r.ok, r.error)
	rec, _ = claude_record(sid)
	testing.expect_value(t, rec.transcript, transcript)
	testing.expect_value(t, rec.model, "claude-opus-5[1m]") // no model in this report: kept
	// models: one bounded token
	testing.expect_value(t, claude_model_clean("us.anthropic.claude-sonnet-5:0"), "us.anthropic.claude-sonnet-5:0")
	testing.expect_value(t, claude_model_clean("opus\x1b[31m"), "")
	testing.expect_value(t, claude_model_clean("a b"), "")
	testing.expect_value(t, claude_model_clean(strings.repeat("x", CLAUDE_MODEL_MAX + 1, context.temp_allocator)), "")
	// saved and restored (checked again on load)
	text := strings.clone(workspace_json())
	testing.expect(t, strings.contains(text, `"transcript"`), "saved")
	context.allocator = r_reset()
	os.set_env("CLAUDE_CONFIG_DIR", cfg)
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	rec, _ = claude_record(sid)
	if testing.expect(t, rec != nil) {
		testing.expect_value(t, rec.transcript, transcript)
		testing.expect_value(t, rec.model, "claude-opus-5[1m]")
	}
	// a saved path outside is dropped on load
	replaced, _ := strings.replace_all(text, transcript, fmt.tprintf("%s/o.jsonl", outside), context.temp_allocator)
	bad := strings.clone(replaced)
	context.allocator = r_reset()
	os.set_env("CLAUDE_CONFIG_DIR", cfg)
	rescan_now()
	testing.expect_value(t, workspace_restore(bad), "")
	rec, _ = claude_record(sid)
	if testing.expect(t, rec != nil) do testing.expect_value(t, rec.transcript, "")
}

// A Claude row's session info (from pi-desk's own record: never Claude's files), Copy session
// info, Reveal in Finder and Copy path (its transcript, checked again at each use).
@(test)
claude_rows_info_reveal_copy :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	sid := "a2a2a2a2-0000-4000-8000-000000000001"
	cfg, transcript := r_config("info", sid)
	dir := r_dir("infoproj")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	_, tab := r_claude_session(t, pid)
	run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup", transcript_path = transcript, model = "claude-opus-5"}, R_SCRIPT)
	run_command(Claude_Turn_Report{tab_id = tab, state = "submitted", title = "Fix the flaky test"}, R_SCRIPT)
	// the path
	p, err := sidebar_path(pid, sid)
	testing.expect_value(t, err, "")
	testing.expect_value(t, p, transcript)
	testing.expect(t, run_command(Copy_Path{project_id = pid, pi_session_id = sid}, R_UI).ok)
	testing.expect_value(t, r_clip, transcript)
	testing.expect(t, run_command(Reveal_Path{project_id = pid, pi_session_id = sid}, R_UI).ok)
	testing.expect_value(t, r_revealed, transcript)
	// the info
	r := run_command(Session_Info{project_id = pid, pi_session_id = sid, to = "clipboard"}, R_UI)
	testing.expect(t, r.ok, r.error)
	for want in ([]string{"```claude-session\n", fmt.tprintf("id: %s\n", sid), fmt.tprintf("file: %s\n", transcript), fmt.tprintf("folder: %s\n", dir), "title: Fix the flaky test\n", "model: claude-opus-5\n", "agent: Claude Code\n", "used: "}) {
		testing.expectf(t, strings.contains(r_clip, want), "%q in %q", want, r_clip)
	}
	testing.expect_value(t, json_path(r.data, "model"), "claude-opus-5")
	testing.expect_value(t, json_path(r.data, "file"), transcript)
	_, text, ierr := session_info_build(pid, sid)
	testing.expect_value(t, ierr, "")
	testing.expect(t, strings.contains(text, sid))
	// an agent may read it (as for pi rows); only the user sends it to Atlas
	testing.expect(t, run_command(Session_Info{project_id = pid, pi_session_id = sid}, R_CONTROL).ok)
	testing.expect(t, !run_command(Session_Info{project_id = pid, pi_session_id = sid, to = "agent"}, R_CONTROL).ok)
	// another project's row: none of it
	other := run_command(Add_Project{cwd = r_dir("other")}, R_UI).created_id
	_, err = sidebar_path(other, sid)
	testing.expect(t, err != "", "not that project's")
	testing.expect(t, !run_command(Session_Info{project_id = other, pi_session_id = sid}, R_UI).ok)
	// the file replaced by a symlink out of Claude's folder: checked again, refused
	outside := r_dir("infoout")
	_ = os.write_entire_file(fmt.tprintf("%s/secret.jsonl", outside), transmute([]u8)string("x"))
	os.remove(transcript)
	os.symlink(fmt.tprintf("%s/secret.jsonl", outside), transcript)
	_, err = sidebar_path(pid, sid)
	testing.expect(t, err != "", "a symlink out")
	r_revealed = ""
	testing.expect(t, !run_command(Reveal_Path{project_id = pid, pi_session_id = sid}, R_UI).ok)
	testing.expect_value(t, r_revealed, "")
	// gone: no Reveal, the info still (without the file)
	os.remove(transcript)
	_, err = sidebar_path(pid, sid)
	testing.expect(t, err != "", "gone")
	r = run_command(Session_Info{project_id = pid, pi_session_id = sid}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, !strings.contains(json_path(r.data, "text"), "file:"), "no file line")
	_ = cfg
}

// PostModelSwitch: claude.model sets the tab's and the history's model; shown in the tab's tooltip.
@(test)
claude_rows_model_switch :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	sid := "a3a3a3a3-0000-4000-8000-000000000001"
	dir := r_dir("model")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	_, tab := r_claude_session(t, pid)
	run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup"}, R_SCRIPT)
	r := run_command(Claude_Model_Report{tab_id = tab, model = "claude-sonnet-5"}, R_SCRIPT)
	testing.expect(t, r.ok, r.error)
	_, ttab, ct := claude_tab_of(tab)
	testing.expect_value(t, ct.model, "claude-sonnet-5")
	rec, _ := claude_record(sid)
	testing.expect_value(t, rec.model, "claude-sonnet-5")
	testing.expect(t, strings.contains(claude_tab_tip(ttab^), "claude-sonnet-5"), claude_tab_tip(ttab^))
	testing.expect(t, strings.contains(json_path(run_command(Session_Info{project_id = pid, pi_session_id = sid}, R_UI).data, "model"), "claude-sonnet-5"))
	// a bad one is refused; unknown tab, a pi tab
	testing.expect(t, !run_command(Claude_Model_Report{tab_id = tab, model = "x\x1by"}, R_SCRIPT).ok)
	testing.expect_value(t, ct.model, "claude-sonnet-5")
	testing.expect(t, !run_command(Claude_Model_Report{tab_id = 999, model = "m"}, R_SCRIPT).ok)
	// who: the tab's own plugin (and scripts); never Atlas
	testing.expect(t, !run_command(Claude_Model_Report{tab_id = tab, model = "m"}, R_CONTROL).ok)
	testing.expect(t, !run_command(Claude_Model_Report{tab_id = tab, model = "m"}, Caller{kind = .Panel, tab_id = tab + 1, claude = true}).ok)
	testing.expect(t, run_command(Claude_Model_Report{tab_id = tab, model = "m"}, Caller{kind = .Panel, tab_id = tab, claude = true}).ok)
	// in the snapshot
	testing.expect(t, strings.contains(state_json(), `"model":"m"`), "snapshot")
}

// Stop's question flag and StopFailure: the question and error dots when OSC 7501 says nothing
// stronger; a new turn clears them.
@(test)
claude_rows_question_error_dots :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	dir := r_dir("dots")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	sess, tab := r_claude_session(t, pid)
	run_command(Claude_Session_Report{tab_id = tab, session_id = "a4a4a4a4-0000-4000-8000-000000000001", source = "startup"}, R_SCRIPT)
	view :: proc(id: u64) -> Row_Status {
		_, tab, _ := find_tab(id)
		return tab_status_view(tab^).dot
	}
	run_command(Claude_Turn_Report{tab_id = tab, state = "submitted", title = "q"}, R_SCRIPT)
	testing.expect(t, run_command(Claude_Turn_Report{tab_id = tab, state = "idle", question = true}, R_SCRIPT).ok)
	testing.expect_value(t, view(tab), Row_Status.Question)
	st, _ := session_row_status(find_session(sess))
	testing.expect_value(t, st, Row_Status.Question)
	run_command(Claude_Turn_Report{tab_id = tab, state = "submitted"}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.Running) // working, from the hooks (no OSC 7501 here: claude_status.odin)
	// StopFailure: error, and the turn is over (held text may go)
	testing.expect(t, run_command(Claude_Turn_Report{tab_id = tab, state = "error"}, R_SCRIPT).ok)
	testing.expect_value(t, view(tab), Row_Status.Error)
	_, _, ct := claude_tab_of(tab)
	testing.expect_value(t, ct.turn, Claude_Turn.Idle)
	// OSC 7501 working wins
	_, ttab, _ := find_tab(tab)
	ttab.prog.state = .Working
	testing.expect_value(t, view(tab), Row_Status.Running)
	ttab.prog.state = .Idle
	testing.expect_value(t, view(tab), Row_Status.Error)
	// Notification idle_prompt (idle a while after Stop) keeps it; a refused state changes nothing
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle", idle_prompt = true}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.Error)
	testing.expect(t, !run_command(Claude_Turn_Report{tab_id = tab, state = "bogus"}, R_SCRIPT).ok)
	testing.expect_value(t, view(tab), Row_Status.Error)
	// a Stop is authoritative: a turn with no UserPromptSubmit (a background wake, a /loop, after a
	// compaction) that ends with a statement clears an old error or question
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle"}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.None)
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle", question = true}, R_SCRIPT)
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle", idle_prompt = true}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.Question)
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle"}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.None)
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle", question = true}, R_SCRIPT)
	run_command(Claude_Turn_Report{tab_id = tab, state = "waiting"}, R_SCRIPT)
	testing.expect(t, view(tab) != .Question, "waiting ends the question")
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle", question = true}, R_SCRIPT)
	run_command(Claude_Session_Report{tab_id = tab, session_id = "a4a4a4a4-0000-4000-8000-000000000002", source = "clear"}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.None)
	// a compaction keeps it
	run_command(Claude_Turn_Report{tab_id = tab, state = "idle", question = true}, R_SCRIPT)
	run_command(Claude_Session_Report{tab_id = tab, session_id = "a4a4a4a4-0000-4000-8000-000000000002", source = "compact"}, R_SCRIPT)
	testing.expect_value(t, view(tab), Row_Status.Question)
}

// The user's rename goes back to Claude Code at the next SessionStart (its hook's sessionTitle);
// a title from the first prompt does not.
@(test)
claude_rows_title_push :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	sid := "a5a5a5a5-0000-4000-8000-000000000001"
	dir := r_dir("title")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	_, tab := r_claude_session(t, pid)
	r := run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup"}, R_SCRIPT)
	testing.expect(t, !strings.contains(r.data, "title"), r.data)
	run_command(Claude_Turn_Report{tab_id = tab, state = "submitted", title = "first prompt"}, R_SCRIPT)
	r = run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "resume"}, R_SCRIPT)
	testing.expect(t, !strings.contains(r.data, "title"), r.data)
	testing.expect(t, run_command(Claude_Rename{claude_session_id = sid, title = "Auth refactor"}, R_UI).ok)
	r = run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "resume"}, R_SCRIPT)
	testing.expect_value(t, json_path(r.data, "title"), "Auth refactor")
	// kept over a relaunch
	text := strings.clone(workspace_json())
	context.allocator = r_reset()
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	rec, _ := claude_record(sid)
	if testing.expect(t, rec != nil) do testing.expect(t, rec.named, "named")
	// renamed to nothing: not pushed
	run_command(Claude_Rename{claude_session_id = sid, title = ""}, R_UI)
	rec, _ = claude_record(sid)
	testing.expect(t, !rec.named)
}

// A Claude tab that exits with an error code makes a bell entry ("Claude exited"); exit 0 (the
// user's /exit) and 127 (not installed) do not.
@(test)
claude_rows_exit_bell :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	dir := r_dir("bell")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	sess := run_command(New_Chat{project_id = pid}, R_UI).created_id
	for code in ([]int{0, 127, 3}) {
		os.set_env("PI_DESK_CLAUDE_CMD", fmt.tprintf("exit %d", code))
		id := run_command(New_Claude_Tab{session = sess}, R_UI).created_id
		state.current_session = 0 // not on screen
		before := len(state.notices.items)
		testing.expect(t, r_wait_exit(id), "exited")
		got := len(state.notices.items) - before
		if code == 3 {
			testing.expect_value(t, got, 1)
			if got == 1 {
				n := state.notices.items[len(state.notices.items) - 1]
				testing.expect_value(t, n.kind, Notice_Kind.Exited)
				testing.expect_value(t, n.tab_id, id)
				testing.expect_value(t, notice_label(n), "Claude exited")
			}
		} else do testing.expectf(t, got == 0, "exit %d: no entry", code)
	}
}

// A Claude-only session: the close prompt's Send and close (a tab's comments) goes to its main
// Claude tab (its hook takes all of the session's comments with that message).
@(test)
claude_rows_send_and_close :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	dir := r_dir("sendclose")
	got := fmt.tprintf("%s/claude-stdin", dir)
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	os.set_env("PI_DESK_CLAUDE_CMD", fmt.tprintf("exec cat > %s", got))
	sess, main := r_claude_session(t, pid)
	run_command(Claude_Session_Report{tab_id = main, session_id = "a6a6a6a6-0000-4000-8000-000000000001", source = "startup"}, R_SCRIPT)
	s := find_session(sess)
	b := Tab{id = new_id(), kind = Browser_Tab{url = "about:blank"}, title = strings.clone("Page"), status = .Running}
	append(&s.tabs, b)
	br := b.id
	testing.expect(t, run_command(Comment_Add{source = .Browser, tab_id = br, what = "w", text = "make it blue"}).ok)
	run_command(Focus_Tab{tab_id = br}, R_UI)
	// Claude not ready yet: refused with why
	ok, why := comments_can_send(find_session(sess), for_tab = true)
	testing.expect(t, !ok, "Claude is starting")
	testing.expect(t, strings.contains(why, "Claude"), why)
	tm := term_of(main)
	msg := "\x1b[?2004h"
	gh.terminal_vt_write(tm.gt, raw_data(msg), len(msg))
	run_command(Claude_Turn_Report{tab_id = main, state = "idle"}, R_SCRIPT)
	ok, why = comments_can_send(find_session(sess), for_tab = true)
	testing.expect(t, ok, why)
	r := run_command(Close_Tab{tab_id = br, comments = .Send}, R_UI)
	testing.expect(t, r.ok, r.error)
	inbox_drain()
	_, gone, _ := find_tab(br)
	testing.expect(t, gone == nil, "the tab closed")
	for _ in 0 ..< 50 {
		claude_tick()
		time.sleep(10 * time.Millisecond)
	}
	data, _ := os.read_entire_file(got, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), CLAUDE_SEND_NOW_LINE), string(data))
	// pending until the hook takes them
	testing.expect_value(t, len(find_session(sess).comments), 1)
}

// Changes' review button asks the session's agent: Claude's main tab in a Claude-only session.
@(test)
claude_rows_review_target :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	dir := r_dir("review")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	sess, main := r_claude_session(t, pid)
	cmd, label := changes_review_command(find_session(sess), "Review it.")
	p, is := cmd.(Claude_Prompt)
	testing.expect(t, is, "a Claude prompt")
	testing.expect_value(t, p.tab_id, main)
	testing.expect_value(t, label, "Ask Claude to review")
	// a pi session: pi
	pis := run_command(New_Chat{project_id = pid}, R_UI).created_id
	cmd, label = changes_review_command(find_session(pis), "Review it.")
	pp, ispi := cmd.(Pi_Prompt)
	testing.expect(t, ispi, "pi's")
	testing.expect_value(t, pp.tab_id, find_session(pis).tabs[0].id)
	testing.expect_value(t, label, "Ask pi to review")
}

// Claude tabs get PI_KIT_NOTES_DIR as pi tabs do (folders.odin notes_env_pi).
@(test)
claude_rows_notes_env :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	dir := r_dir("notes")
	envf := fmt.tprintf("%s/env", dir)
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	state.settings.home_dir = "/m-notes"
	defer state.settings.home_dir = ""
	os.unset_env("PI_KIT_NOTES_DIR")
	os.set_env("PI_DESK_CLAUDE_CMD", fmt.tprintf("env > %s.tmp; mv %s.tmp %s; exec sleep 30", envf, envf, envf))
	r_claude_session(t, pid)
	text := ""
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(envf, context.temp_allocator); err == nil && len(data) > 0 {
			text = string(data)
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, strings.contains(text, "PI_KIT_NOTES_DIR=/m-notes\n"), "the notes folder")
}

// `pi-desk --claude DIR`: a Claude session there on start; a bare DIR stays a pi chat.
@(test)
claude_rows_launch_args :: proc(t: ^testing.T) {
	a, ok := app_args_parse({"--claude", "/x"})
	testing.expect(t, ok)
	testing.expect_value(t, a.dir, "/x")
	testing.expect(t, a.claude)
	a, ok = app_args_parse({"/x"})
	testing.expect(t, ok && !a.claude && a.dir == "/x")
	_, ok = app_args_parse({"--claude"})
	testing.expect(t, !ok, "--claude needs DIR")
	_, ok = app_args_parse({"--bogus", "/x"})
	testing.expect(t, !ok)
	a, ok = app_args_parse({"--fresh", "--claude", "/y"})
	testing.expect(t, ok && a.fresh && a.claude && a.dir == "/y")
	// no shortcut of its own: "New session" (⇧⌘N) offers Claude Code in its picker (harness.odin)
	testing.expect(t, action_by_id("new_claude_session") == nil, "no separate action")
	testing.expect_value(t, menubar_key_action(.N, sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT | sapp.MODIFIER_SUPER), "")
}

// The wire: claude.turn without `question` (every hook but a questioning Stop) parses; with it too.
@(test)
claude_rows_turn_wire :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	cmd, err := parse_command(`{"type":"claude.turn","state":"idle"}`)
	testing.expect_value(t, err, "")
	c, is := cmd.(Claude_Turn_Report)
	testing.expect(t, is && !c.question)
	cmd, err = parse_command(`{"type":"claude.turn","state":"idle","question":true}`)
	testing.expect_value(t, err, "")
	c, is = cmd.(Claude_Turn_Report)
	testing.expect(t, is && c.question)
	cmd, err = parse_command(`{"type":"claude.turn","state":"idle","idle_prompt":true}`)
	testing.expect_value(t, err, "")
	c, is = cmd.(Claude_Turn_Report)
	testing.expect(t, is && c.idle_prompt)
	cmd, err = parse_command(`{"type":"claude.session","session_id":"x","transcript_path":"/a.jsonl","model":"m"}`)
	testing.expect_value(t, err, "")
	s, _ := cmd.(Claude_Session_Report)
	testing.expect_value(t, s.transcript_path, "/a.jsonl")
	testing.expect_value(t, s.model, "m")
	cmd, err = parse_command(`{"type":"claude.model","model":"m"}`)
	testing.expect_value(t, err, "")
	_, is_model := cmd.(Claude_Model_Report)
	testing.expect(t, is_model)
}

// Review round 1, item 2: the first transcript path of an id stays; a later report cannot repoint it
// (another projects/<slug> folder, or another file in the same one).
@(test)
claude_rows_transcript_kept :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	sid := "a7a7a7a7-0000-4000-8000-000000000001"
	cfg, transcript := r_config("kept", sid)
	dir := r_dir("keptproj")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	_, tab := r_claude_session(t, pid)
	testing.expect(t, run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup", transcript_path = transcript}, R_SCRIPT).ok)
	for other in ([]string{fmt.tprintf("%s/projects/-y/%s.jsonl", cfg, sid), fmt.tprintf("%s/projects/-x/other.jsonl", cfg)}) {
		os.make_directory_all(fmt.tprintf("%s/projects/-y", cfg))
		_ = os.write_entire_file(other, transmute([]u8)string("{}"))
		run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "resume", transcript_path = other}, R_SCRIPT)
		rec, _ := claude_record(sid)
		testing.expectf(t, rec.transcript == transcript, "kept %q, not %q", rec.transcript, other)
	}
}

// Review round 1, item 3: `pi-desk [--claude] DIR` starts in DIR's project only: never in the
// project that happened to be selected.
@(test)
claude_rows_launch_needs_its_project :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	testing.expect(t, launch_start(true, 0) == nil, "no project: nothing")
	testing.expect(t, launch_start(false, 0) == nil, "no project: no chat either")
	testing.expect(t, launch_start(true, 987654321) == nil, "not a project")
	pid := run_command(Add_Project{cwd = r_dir("launch")}, R_UI).created_id
	_, is := launch_start(true, pid).(New_Claude_Session)
	testing.expect(t, is, "a Claude session")
	chat, is_chat := launch_start(false, pid).(New_Chat)
	testing.expect(t, is_chat && chat.project_id == pid, "a pi chat in DIR's project")
	// a failed Add_Project (Chats' folder, an empty path): no project to start in
	testing.expect_value(t, launch_project(Result{ok = false, created_id = pid}), u64(0))
	testing.expect_value(t, launch_project(Result{ok = true, created_id = pid}), pid)
}

// Review round 1, item 4: the polish.
@(test)
claude_rows_polish :: proc(t: ^testing.T) {
	context.allocator = r_reset()
	defer r_done()
	dir := r_dir("polish")
	pid := run_command(Add_Project{cwd = dir}, R_UI).created_id
	sess, tab := r_claude_session(t, pid)
	s := find_session(sess)
	// the close prompt names Claude in a Claude-only session
	msg, send := comments_ask_text(s, nil, 2)
	testing.expect(t, strings.contains(msg, "Claude") && !strings.contains(msg, "pi"), msg)
	testing.expect_value(t, send, "Send now")
	b := Tab{title = "Page"}
	msg, send = comments_ask_text(s, &b, 1)
	testing.expect(t, strings.contains(msg, "not sent to Claude yet"), msg)
	testing.expect_value(t, send, "Send and close")
	testing.expect_value(t, comments_agent_word(s), "Claude")
	// ⓘ only with a history entry
	testing.expect(t, session_row_has_info(Session{id = "x"}), "a pi row")
	testing.expect(t, !session_row_has_info(Session{id = "a8a8a8a8-0000-4000-8000-000000000009", claude = true}), "no history entry")
	sid := "a8a8a8a8-0000-4000-8000-000000000001"
	run_command(Claude_Session_Report{tab_id = tab, session_id = sid, source = "startup"}, R_SCRIPT)
	testing.expect(t, session_row_has_info(Session{id = sid, claude = true}))
	// /clear: the new entry keeps the tab's model
	run_command(Claude_Model_Report{tab_id = tab, model = "claude-sonnet-5"}, R_SCRIPT)
	sid2 := "a8a8a8a8-0000-4000-8000-000000000002"
	run_command(Claude_Session_Report{tab_id = tab, session_id = sid2, source = "clear"}, R_SCRIPT)
	rec, _ := claude_record(sid2)
	if testing.expect(t, rec != nil) do testing.expect_value(t, rec.model, "claude-sonnet-5")
	// a model switch is saved
	before := persist.gen
	persist_on_event(Command_Event{changed = true, command = Claude_Model_Report{tab_id = tab, model = "m"}})
	testing.expect(t, persist.gen != before, "a model switch marks the workspace dirty")
	// the review button only with a Claude tab first
	odd := Open_Session{agent = .Claude}
	append(&odd.tabs, Tab{id = 5, kind = Shell_Tab{}})
	cmd, _ := changes_review_command(&odd, "x")
	testing.expect(t, cmd == nil, "not a Claude tab")
}
