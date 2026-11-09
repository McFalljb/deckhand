package main

// Claude status feeds (`./build.sh test`; docs/CLAUDE.md §5, §6a, §6b): dots from the hooks when
// Claude Code reports no OSC 7501, background work at a turn's end (Stop's background_tasks) as
// busy for waits and named by the restart confirmation, the Background panel, the "hooks not
// running" bar, the minimum-version hint, and subagents' current tool, durations and own todos.
// Same rules as core_test.odin: shared global State, one thread, `sleep` stands in for claude.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import gh "ghostty"

@(private = "file")
F_UI :: core.Caller{kind = .UI}
@(private = "file")
F_SCRIPT :: core.Caller{kind = .Script}

@(private = "file")
f_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	core.claude_wait_reset()
	core.claude_status_reset()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.persist = {}
	core.dead_tab_reset()
	core.claude_installed_probe = stand_in_installed // the stand-in claude counts as installed
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	return runtime.heap_allocator()
}

@(private = "file")
f_done :: proc() {
	core.inbox_drain()
	for _, t in core.terms do core.reader_stop_and_close(t)
	core.claude_installed_probe = nil
	core.claude_wait_reset()
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
}

// A project at a temp folder, one open session (its pi a `sleep`) and a Claude tab in it, on screen.
@(private = "file")
f_claude :: proc(t: ^testing.T, tag: string) -> (sess, id: u64) {
	d := fmt.aprintf("%s/deckhand-feeds-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	pid := core.run_command(core.Add_Project{cwd = d}, F_UI).created_id
	r := core.run_command(core.New_Chat{project_id = pid}, F_UI)
	testing.expect(t, r.ok, r.error)
	sess = r.created_id
	r = core.run_command(core.New_Claude_Tab{session = sess}, F_UI)
	testing.expect(t, r.ok, r.error)
	return sess, r.created_id
}

@(private = "file")
f_rows :: proc(tab_id: u64, id: string) -> string {
	_, tab, _ := core.find_tab(tab_id)
	if tab == nil do return "<no tab>"
	for p in tab.panels do if p.id == id {
		parts := make([dynamic]string, context.temp_allocator)
		for r in p.rows do append(&parts, r.text)
		return strings.join(parts[:], "|", context.temp_allocator)
	}
	return ""
}

@(private = "file")
f_tone :: proc(tab_id: u64, id: string, row: int) -> core.Panel_Tone {
	_, tab, _ := core.find_tab(tab_id)
	for p in tab.panels do if p.id == id && row < len(p.rows) do return p.rows[row].tone
	return .Normal
}

@(private = "file")
f_dot :: proc(id: u64) -> core.Row_Status {
	_, tab, _ := core.find_tab(id)
	return core.tab_status_view(tab^).dot
}

@(private = "file")
f_turn :: proc(id: u64, st: string) {core.run_command(core.Claude_Turn_Report{tab_id = id, state = st}, F_SCRIPT)}

@(private = "file")
f_snapshot :: proc(id: u64, tasks: []core.Claude_Bg_In, crons: []core.Claude_Cron_In = nil, seq: u64 = 0) -> core.Result {
	return core.run_command(core.Claude_Background{tab_id = id, event = "snapshot", tasks = tasks, crons = crons, seq = seq}, F_SCRIPT)
}

// As if Claude had turned bracketed paste on (its prompt is up).
@(private = "file")
f_paste_mode :: proc(id: u64) {
	tm := core.term_of(id)
	if tm == nil do return
	msg := "\x1b[?2004h"
	gh.terminal_vt_write(tm.gt, raw_data(msg), len(msg))
}

// ---- #10: dots from the hooks on a Claude Code without OSC 7501 ----

@(test)
claude_dot_from_hooks :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	sess, id := f_claude(t, "dots")
	pitab := core.find_session(sess).tabs[0].id
	testing.expect_value(t, f_dot(id), core.Row_Status.None) // starting: nothing yet
	f_turn(id, "submitted")
	testing.expect_value(t, f_dot(id), core.Row_Status.Running)
	_, tab, _ := core.find_tab(id)
	testing.expect(t, strings.contains(core.status_explain(tab^), "Claude Code hooks"), core.status_explain(tab^))
	f_turn(id, "waiting")
	testing.expect_value(t, f_dot(id), core.Row_Status.Waiting)
	// the session's roll-up and the quick filter see it too
	st, _ := core.session_row_status(core.find_session(sess))
	testing.expect_value(t, st, core.Row_Status.Waiting)
	f_turn(id, "idle")
	testing.expect_value(t, f_dot(id), core.Row_Status.None) // on screen: seen
	// a turn that ends while the user looks elsewhere: the unseen dot, as OSC 7501's done gives
	core.run_command(core.Focus_Tab{tab_id = pitab}, F_UI)
	f_turn(id, "submitted")
	f_turn(id, "idle")
	testing.expect_value(t, f_dot(id), core.Row_Status.Unseen)
	f_turn(id, "submitted") // working again: nothing left unseen
	testing.expect_value(t, f_dot(id), core.Row_Status.Running)
	f_turn(id, "idle")
	// idle_prompt (a while after the Stop) is not a second end of turn
	core.run_command(core.Focus_Tab{tab_id = id}, F_UI)
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "idle", idle_prompt = true}, F_SCRIPT)
	testing.expect_value(t, f_dot(id), core.Row_Status.None)
	// once Claude's own OSC 7501 status is seen, it alone gives the dot (as before)
	core.run_command(core.Program_Status{tab_id = id, summary = {state = .Idle, app = "claude-code"}})
	f_turn(id, "submitted")
	testing.expect_value(t, f_dot(id), core.Row_Status.None)
	core.run_command(core.Program_Status{tab_id = id, summary = {state = .Working, app = "claude-code"}})
	testing.expect_value(t, f_dot(id), core.Row_Status.Running)
}

// ---- #11: background work never blocks; a wait's result and the restart confirmation name it ----

@(private = "file")
f_bells :: proc(tab_id: u64) -> int {
	n := 0
	for x in state.notices.items do if x.tab_id == tab_id do n += 1
	return n
}

@(test)
claude_background_never_blocks :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	ends: map[u64]string
	core.claude_wait_test_finished = &ends
	defer core.claude_wait_test_finished = nil
	sess, id := f_claude(t, "bgblock")
	pitab := core.find_session(sess).tabs[0].id
	_, tab, _ := core.find_tab(id)
	core.run_command(core.Focus_Tab{tab_id = pitab}, F_UI) // the user looks elsewhere
	f_turn(id, "submitted")
	// Stop: a dev server still runs (the snapshot first, then idle); the last answer asks something
	testing.expect(t, f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", description = "Start the dev server", command = "npm run dev"}, {id = "m1", kind = "monitor", status = "running"}}, {{id = "c1", schedule = "30 14 4 11 *", recurring = false}}, seq = 10).ok)
	bells := f_bells(id)
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "idle", question = true}, F_SCRIPT)
	testing.expect_value(t, core.claude_background_running(id), 3)
	// a finished turn: the question dot, the unseen flag and a bell entry, whatever runs
	testing.expect_value(t, f_dot(id), core.Row_Status.Question)
	testing.expect(t, tab.unseen, "unseen")
	testing.expect_value(t, f_bells(id), bells + 1)
	testing.expect_value(t, core.claude_wait_why(tab), "")
	// a wait ends, and its result lists what runs (descriptions, else kind #id; never a command)
	core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 60_000}, core.Caller{kind = .Control}, 201)
	now := time.tick_now()
	core.claude_wait_tick(now)
	core.claude_wait_tick(time.tick_add(now, time.Second))
	testing.expect(t, 201 in ends, "the wait ended")
	res := ends[201]
	testing.expect_value(t, core.json_path(res, "ok"), "true")
	testing.expect_value(t, core.json_path(res, "data.background_count"), "3")
	testing.expect_value(t, core.json_path(res, "data.background.0.label"), "Start the dev server")
	testing.expect_value(t, core.json_path(res, "data.background.1.label"), "monitor #m1")
	testing.expect_value(t, core.json_path(res, "data.background.2.kind"), "wakeup")
	testing.expect(t, !strings.contains(res, "npm run dev"), res)
	// an error ending wins too
	f_turn(id, "submitted")
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", description = "Start the dev server"}}, seq = 11)
	f_turn(id, "error")
	testing.expect_value(t, f_dot(id), core.Row_Status.Error)
	// only known running statuses count; a recurring cron never does
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "weird"}, {id = "q1", kind = "shell", status = "pending"}}, {{id = "c2", schedule = "* * * * *", recurring = true}}, seq = 12)
	testing.expect_value(t, core.claude_background_running(id), 1)
	// an older snapshot (async SubagentStop) never overwrites a newer one
	f_snapshot(id, {}, seq = 5)
	testing.expect_value(t, core.claude_background_running(id), 1)
	// a new process forgets it
	core.claude_work_reset(id)
	testing.expect_value(t, core.claude_background_running(id), 0)
	// bad input
	testing.expect(t, !core.run_command(core.Claude_Background{tab_id = id, event = "dance"}, F_SCRIPT).ok)
	testing.expect(t, !core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "a b"}, F_SCRIPT).ok)
	many := make([]core.Claude_Bg_In, core.CLAUDE_BG_IN_MAX + 1, context.temp_allocator)
	for &m, i in many do m = {id = fmt.tprintf("t%d", i), kind = "shell", status = "running"}
	testing.expect(t, !f_snapshot(id, many, seq = 20).ok, "a list over the limit is refused")
	// the command log has ids and counts, never Claude's text
	line := core.command_json(core.Claude_Background{tab_id = id, event = "launch", task_id = "b1", description = "secret plan", command = "curl -H 'Authorization: x'"})
	testing.expect(t, !strings.contains(line, "secret plan") && !strings.contains(line, "Authorization"), line)
}

// The OSC 7501 path: a turn's end with background work running still leaves the unseen dot and a
// bell entry (§5a's rule on both paths).
@(test)
claude_background_osc_path :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	sess, id := f_claude(t, "bgosc")
	pitab := core.find_session(sess).tabs[0].id
	_, tab, _ := core.find_tab(id)
	core.run_command(core.Focus_Tab{tab_id = pitab}, F_UI)
	core.run_command(core.Program_Status{tab_id = id, summary = {state = .Working, app = "claude-code", records = 1, progress = -1}})
	f_turn(id, "submitted")
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", description = "dev"}}, seq = 1)
	f_turn(id, "idle")
	bells := f_bells(id)
	core.run_command(core.Program_Status{tab_id = id, summary = {state = .Done, app = "claude-code", records = 1, progress = -1}})
	testing.expect(t, tab.unseen, "unseen")
	testing.expect_value(t, f_bells(id), bells + 1)
	testing.expect_value(t, f_dot(id), core.Row_Status.Unseen)
}

// A launch that no Stop ever confirms (an older Claude Code sends backgroundTaskId but no
// background_tasks; or the snapshot was lost): shown during its turn, never counted, gone at the
// Stop that comes without a snapshot.
@(test)
claude_background_launch_unconfirmed :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	ends: map[u64]string
	core.claude_wait_test_finished = &ends
	defer core.claude_wait_test_finished = nil
	sess, id := f_claude(t, "bglaunch")
	pitab := core.find_session(sess).tabs[0].id
	_, tab, _ := core.find_tab(id)
	core.run_command(core.Focus_Tab{tab_id = pitab}, F_UI)
	f_turn(id, "submitted")
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "bash_1", kind = "shell", description = "Start the dev server", seq = 5}, F_SCRIPT)
	testing.expect(t, strings.contains(f_rows(id, "background"), "● shell · Start the dev server"), f_rows(id, "background"))
	testing.expect_value(t, core.claude_background_running(id), 0)
	bells := f_bells(id)
	f_turn(id, "idle") // a Stop with no snapshot
	testing.expect_value(t, f_rows(id, "background"), "")
	testing.expect_value(t, core.claude_background_running(id), 0)
	testing.expect_value(t, f_dot(id), core.Row_Status.Unseen)
	testing.expect(t, tab.unseen)
	testing.expect_value(t, f_bells(id), bells + 1)
	core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 60_000}, core.Caller{kind = .Control}, 301)
	now := time.tick_now()
	core.claude_wait_tick(now)
	core.claude_wait_tick(time.tick_add(now, time.Second))
	testing.expect_value(t, core.json_path(ends[301], "ok"), "true")
	testing.expect_value(t, core.json_path(ends[301], "data.background_count"), "<missing>")
	// with a snapshot in its turn the launch is confirmed and stays
	f_turn(id, "submitted")
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "bash_2", kind = "shell", description = "tail", seq = 6}, F_SCRIPT)
	f_snapshot(id, {{id = "bash_2", kind = "shell", status = "running", description = "tail"}}, seq = 7)
	f_turn(id, "idle")
	testing.expect_value(t, core.claude_background_running(id), 1)
	// Bash's id and the Stop's differ by a prefix: still one task
	f_turn(id, "submitted")
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "b9xyz", kind = "shell", description = "watch", seq = 8}, F_SCRIPT)
	f_snapshot(id, {{id = "bash_2", kind = "shell", status = "running"}, {id = "task-b9xyz", kind = "shell", status = "running"}}, seq = 9)
	testing.expect_value(t, core.claude_background_running(id), 2)
	testing.expect_value(t, strings.count(f_rows(id, "background"), "watch"), 1)
}

// A running task is never pushed out: past CLAUDE_BG_MAX they are counted.
@(test)
claude_background_full :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	_, id := f_claude(t, "bgfull")
	many := make([]core.Claude_Bg_In, core.CLAUDE_BG_MAX + 4, context.temp_allocator)
	for &m, i in many do m = {id = fmt.tprintf("t%d", i), kind = "shell", status = "running", description = fmt.tprintf("job %d", i)}
	f_snapshot(id, many, seq = 1)
	testing.expect_value(t, core.claude_background_running(id), core.CLAUDE_BG_MAX + 4)
	rows := f_rows(id, "background")
	testing.expect(t, strings.contains(rows, "· job 0|") && strings.contains(rows, "+4 more running"), rows)
	// a launch when full of running ones: not kept, nothing evicted
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "new1", kind = "shell", description = "late", seq = 2}, F_SCRIPT)
	rows = f_rows(id, "background")
	testing.expect(t, !strings.contains(rows, "late") && strings.contains(rows, "· job 0|"), rows)
}

// Commands: masked in the panel; never in names, results, confirmations or the command log.
@(test)
claude_background_secrets :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	cases := [][2]string {
		{"API_TOKEN=abc123 npm run deploy", "API_TOKEN=… npm run deploy"},
		{"curl -H 'Authorization: Bearer s3cr3t' https://x", "curl -H 'Authorization: …' https://x"},
		{`curl -H "authorization: token s3cr3t" -s`, `curl -H "authorization: …" -s`},
		{"gh auth --token s3cr3t --x", "gh auth --token … --x"},
		{"tool --password=hunter2 go", "tool --password=… go"},
		{"export DB_PASSWORD=p4ss; run", "export DB_PASSWORD=… run"},
		{"make test VERBOSE=1", "make test VERBOSE=1"},
	}
	for c in cases do testing.expect_value(t, core.claude_mask_secrets(c[0]), c[1])
	sess, id := f_claude(t, "bgsecret")
	_ = sess
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", command = "API_TOKEN=abc123 npm run deploy"}}, seq = 1)
	rows := f_rows(id, "background")
	testing.expect(t, strings.contains(rows, "API_TOKEN=… npm run deploy") && !strings.contains(rows, "abc123"), rows)
	testing.expect(t, !strings.contains(core.state_json(), "abc123"), "the snapshot")
	names := core.claude_background_names(id)
	testing.expect_value(t, names, "shell #bash_1")
	testing.expect(t, !strings.contains(core.claude_background_result(id), "npm"), core.claude_background_result(id))
}

// The restart confirmation names what stops.
@(test)
claude_background_restart_confirm :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	_, id := f_claude(t, "bgrestart")
	core.run_command(core.Claude_Session_Report{tab_id = id, session_id = "0c1a0de0-dddd-4222-8333-444455556666", source = "startup"}, F_SCRIPT)
	f_turn(id, "idle")
	core.claude_reload_tick()
	testing.expect(t, core.run_command(core.Claude_Reload_Watch{paths = {"/x/CLAUDE.md"}, scopes = {""}}).ok)
	r := core.run_command(core.Claude_Restart_Changed{}, F_UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, !strings.contains(r.confirm_summary, "dev server"), r.confirm_summary)
	core.run_command(core.Cancel_Confirmation{token = r.confirm_token}, F_UI)
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", description = "Start the dev server"}, {id = "m1", kind = "monitor", status = "running", description = "watch CI"}, {id = "bash_9", kind = "shell", status = "running", command = "SECRET_CMD=1 run"}}, seq = 1)
	r = core.run_command(core.Claude_Restart_Changed{}, F_UI)
	testing.expectf(t, strings.contains(r.confirm_summary, "Start the dev server") && strings.contains(r.confirm_summary, "watch CI") && strings.contains(r.confirm_summary, "shell #bash_9"), "names them: %s", r.confirm_summary)
	testing.expectf(t, !strings.contains(r.confirm_summary, "SECRET_CMD"), "never a command: %s", r.confirm_summary)
}

// ---- #14 phase 1: the Background panel (launches and Stop snapshots; display only) ----

@(test)
claude_background_panel :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	_, id := f_claude(t, "bgpanel")
	testing.expect_value(t, f_rows(id, "background"), "")
	// a launch (PostToolUse on Bash) shows at once
	r := core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "bash_1", kind = "shell", description = "Start the dev server", command = "npm run dev", seq = 5}, F_SCRIPT)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, f_rows(id, "background"), "Background · 1 running|● shell · Start the dev server|Deckhand can't stop these: ask Claude")
	testing.expect_value(t, f_tone(id, "background", 1), core.Panel_Tone.Accent)
	// no description: its command
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "bash_2", kind = "shell", command = "pytest -x", seq = 6}, F_SCRIPT)
	testing.expect(t, strings.contains(f_rows(id, "background"), "● shell · pytest -x"), f_rows(id, "background"))
	// a Stop's snapshot: bash_1 still runs, bash_2 gone (finished), a monitor and a cron;
	// a subagent's task is the Subagents panel's
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", description = "Start the dev server"}, {id = "m1", kind = "monitor", status = "running", description = "watch CI"}, {id = "a1", kind = "subagent", status = "running", description = "Explore"}}, {{id = "c1", schedule = "*/5 * * * *", recurring = true, prompt = "check the build"}}, seq = 10)
	testing.expect_value(t, f_rows(id, "background"), "Background · 2 running|● shell · Start the dev server|● monitor · watch CI|✓ shell · pytest -x|⏲ */5 * * * * · repeats|  check the build|As of Claude's last turn|Deckhand can't stop these: ask Claude")
	testing.expect_value(t, f_tone(id, "background", 3), core.Panel_Tone.Success)
	// a launch after that snapshot stays running at the next older-than-it snapshot's absence
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "bash_3", kind = "shell", description = "tail logs", seq = 20}, F_SCRIPT)
	f_snapshot(id, {{id = "bash_1", kind = "shell", status = "running", description = "Start the dev server"}}, seq = 15)
	testing.expect(t, strings.contains(f_rows(id, "background"), "● shell · tail logs"), f_rows(id, "background"))
	// the user's next message: finished ones leave, running ones stay
	f_turn(id, "submitted")
	rows := f_rows(id, "background")
	testing.expect(t, !strings.contains(rows, "pytest") && !strings.contains(rows, "watch CI") && strings.contains(rows, "dev server"), rows)
	// untrusted text: one line, no control or bidi characters, bounded
	evil := strings.concatenate({"\x1b]0;x\x07red‮evil\nnext", strings.repeat("z", 1000)})
	core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "bash_9", kind = "she\x1bll", description = evil, seq = 30}, F_SCRIPT)
	rows = f_rows(id, "background")
	testing.expect(t, !strings.contains_any(rows, "\x1b\x07\n") && !strings.contains_rune(rows, 0x202e), rows)
	// bounded: at most CLAUDE_BG_MAX kept
	for i in 0 ..< 40 do core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = fmt.tprintf("x%d", i), kind = "shell", command = "x", seq = u64(40 + i)}, F_SCRIPT)
	_, tab, _ := core.find_tab(id)
	n := 0
	for p in tab.panels do if p.id == "background" do for row in p.rows do if strings.has_prefix(row.text, "●") || strings.has_prefix(row.text, "✓") do n += 1
	testing.expect(t, n <= core.CLAUDE_BG_MAX, "bounded")
	// reports for a tab not running are refused; it goes with the exit
	core.run_command(core.Tab_Exited{tab_id = id})
	testing.expect_value(t, f_rows(id, "background"), "")
	testing.expect(t, !core.run_command(core.Claude_Background{tab_id = id, event = "launch", task_id = "late", kind = "shell"}, F_SCRIPT).ok)
}

@(test)
claude_background_json :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	c, err := core.parse_command(`{"type":"claude.background","event":"snapshot","seq":4,"tasks":[{"id":"t1","kind":"shell","status":"running","description":"d","command":"c"}],"crons":[{"id":"c1","schedule":"0 9 * * *","recurring":true,"prompt":"p"}]}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	bg := c.(core.Claude_Background)
	testing.expect_value(t, bg.seq, 4)
	testing.expect_value(t, len(bg.tasks), 1)
	testing.expect_value(t, bg.tasks[0].command, "c")
	testing.expect_value(t, len(bg.crons), 1)
	testing.expect(t, bg.crons[0].recurring)
	c, err = core.parse_command(`{"type":"claude.background","event":"launch","task_id":"b1","kind":"shell","description":"d"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(core.Claude_Background).task_id, "b1")
	_, err = core.parse_command(`{"type":"claude.background","event":"snapshot","tasks":"x"}`, context.temp_allocator)
	testing.expect(t, err != "", "tasks must be a list")
	_, err = core.parse_command(`{"type":"claude.background","event":"snapshot","tasks":[{"kind":"shell"}]}`, context.temp_allocator)
	testing.expect(t, err != "", "each task needs an id")
	spec := core.command_spec("claude.background")
	testing.expect(t, spec != nil && spec.who == .Claude, "who claude")
	me := core.Caller{kind = .Panel, tab_id = 7, claude = true}
	testing.expect(t, core.caller_may(me, core.Claude_Background{tab_id = 7}))
	testing.expect(t, !core.caller_may(core.Caller{kind = .Panel, tab_id = 7}, core.Claude_Background{tab_id = 7}), "never a pi tab")
	testing.expect(t, !core.caller_may(core.Caller{kind = .Panel, tab_id = 8, claude = true}, core.Claude_Background{tab_id = 7}), "not another tab's")
	testing.expect(t, !core.caller_may(core.Caller{kind = .Control}, core.Claude_Background{tab_id = 7}), "never control")
	c, err = core.parse_command(`{"type":"claude.subagent","event":"tool","agent_id":"a1","tool_name":"Grep"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(core.Claude_Subagent).tool_name, "Grep")
	c, err = core.parse_command(`{"type":"claude.todos","agent_id":"a1","todos":[]}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(core.Claude_Todos).agent_id, "a1")
}

// ---- #12: a Claude tab whose hooks never report ----

@(test)
claude_hooks_silent_bar :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	_, id := f_claude(t, "silent")
	_, tab, _ := core.find_tab(id)
	// the clock in the past, so the snapshot (real time) sees the grace period over too
	now := time.tick_add(time.tick_now(), -(core.CLAUDE_HOOKS_GRACE + 5 * time.Second))
	core.claude_status_tick(now)
	testing.expect(t, !core.claude_hooks_silent(tab, now), "its prompt is not up yet (a startup dialog may be open)")
	f_paste_mode(id) // Claude's prompt is up
	core.claude_status_tick(now)
	testing.expect(t, !core.claude_hooks_silent(tab, now), "not at once")
	later := time.tick_now()
	core.claude_status_tick(later)
	testing.expect(t, core.claude_hooks_silent(tab, later), "no hook in the grace period")
	msg := core.claude_status_message(tab, later)
	testing.expect(t, strings.contains(msg, "disableAllHooks") && strings.contains(msg, "allowManagedHooksOnly") && strings.contains(msg, "not saved"), msg)
	testing.expect_value(t, core.json_path(core.state_json(), "open_sessions.0.tabs.1.hooks"), "silent")
	// any hook report clears it
	f_turn(id, "idle")
	testing.expect(t, !core.claude_hooks_silent(tab, later))
	testing.expect_value(t, core.claude_status_message(tab, later), "")
	// dismissed for this run of the tab
	_, id2 := f_claude(t, "silent2")
	_, tab2, _ := core.find_tab(id2)
	f_paste_mode(id2)
	core.claude_status_tick(now)
	core.claude_status_tick(later)
	testing.expect(t, core.claude_status_message(tab2, later) != "")
	core.claude_status_dismiss(tab2, later)
	testing.expect_value(t, core.claude_status_message(tab2, later), "")
	testing.expect(t, core.claude_hooks_silent(tab2, later), "still silent: only the bar is dismissed")
	// a restored tab already has its session id: silent all the same (no turn in this run)
	_, id3 := f_claude(t, "silent3")
	_, tab3, _ := core.find_tab(id3)
	ct3 := &tab3.kind.(core.Claude_Tab)
	ct3.session_id = strings.clone("0c1a0de0-eeee-4222-8333-444455556666")
	f_paste_mode(id3)
	core.claude_status_tick(now)
	core.claude_status_tick(later)
	testing.expect(t, core.claude_hooks_silent(tab3, later), "restored, hooks silent")
	// a read-only tab has its own check (it is stopped without its ack): no bar
	ct2 := &tab2.kind.(core.Claude_Tab)
	ct2.readonly = true
	testing.expect(t, !core.claude_hooks_silent(tab2, later))
}

// ---- #13: a minimum-version hint (the version from where `claude` links to; never run) ----

@(test)
claude_version_hint :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	testing.expect(t, core.claude_version_below("2.1.250", core.CLAUDE_MIN_VERSION))
	testing.expect(t, core.claude_version_below("1.0.99", core.CLAUDE_MIN_VERSION))
	testing.expect(t, !core.claude_version_below("2.1.295", core.CLAUDE_MIN_VERSION))
	testing.expect(t, !core.claude_version_below("2.1.300", core.CLAUDE_MIN_VERSION))
	testing.expect(t, !core.claude_version_below("2.2.0", core.CLAUDE_MIN_VERSION))
	testing.expect(t, !core.claude_version_below("10.0.0", core.CLAUDE_MIN_VERSION))
	testing.expect(t, !core.claude_version_below("2.1.295-beta.1", core.CLAUDE_MIN_VERSION))
	testing.expect(t, core.claude_version_below("2.1.29", core.CLAUDE_MIN_VERSION))
	for unknown in ([]string{"", "build:1:2:3", "latest", "x.y.z"}) do testing.expectf(t, !core.claude_version_below(unknown, core.CLAUDE_MIN_VERSION), "unknown %q: no hint", unknown)
	_, id := f_claude(t, "version")
	_, tab, _ := core.find_tab(id)
	f_turn(id, "idle")
	now := time.tick_now()
	testing.expect_value(t, core.claude_status_message(tab, now), "")
	tab.reload.version = strings.clone("2.1.250")
	msg := core.claude_status_message(tab, now)
	testing.expect(t, strings.contains(msg, "2.1.250") && strings.contains(msg, core.CLAUDE_MIN_VERSION), msg)
	// the update command for how it was installed
	testing.expect_value(t, core.claude_update_command("/Users/u/.local/share/claude/versions/2.1.250"), "claude update")
	testing.expect_value(t, core.claude_update_command("/opt/homebrew/Caskroom/claude-code/2.1.250/claude"), "brew upgrade --cask claude-code")
	testing.expect_value(t, core.claude_update_command("/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"), "npm install -g @anthropic-ai/claude-code@latest")
	testing.expect_value(t, core.claude_update_command("/nix/store/abc-claude/bin/claude"), "") // nix updates it (harness_test.odin)
	// dismissed: gone for that version only, and saved (a relaunch keeps it hidden)
	saved_root := core.home_root
	core.home_root = fmt.aprintf("%s/deckhand-feeds-hints-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	defer core.home_root = saved_root
	os.make_directory_all(core.home_root)
	core.claude_status_dismiss(tab, now)
	testing.expect_value(t, core.claude_status_message(tab, now), "")
	core.claude_status_reset() // as after a relaunch: nothing in memory
	testing.expect_value(t, core.claude_status_message(tab, now), "")
	delete(tab.reload.version)
	tab.reload.version = strings.clone("2.1.251")
	testing.expect(t, core.claude_status_message(tab, now) != "", "another old version shows it again")
	// an unknown layout ("a new build"): no hint
	delete(tab.reload.version)
	tab.reload.version = strings.clone("build:1:2:3")
	testing.expect_value(t, core.claude_status_message(tab, now), "")
}

// ---- #16: subagents' current tool and durations; #17: their own todos ----

@(test)
claude_subagent_tool_and_time :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	_, id := f_claude(t, "agenttool")
	sub :: proc(id: u64, event: string, agent_id := "", kind := "", tool := "", seq: u64 = 0) -> core.Result {
		return core.run_command(core.Claude_Subagent{tab_id = id, event = event, agent_id = agent_id, agent_type = kind, tool_name = tool, seq = seq}, F_SCRIPT)
	}
	testing.expect(t, sub(id, "start", agent_id = "a1", kind = "Explore").ok)
	start := time.tick_now()
	testing.expect(t, sub(id, "tool", agent_id = "a1", tool = "Grep", seq = 2).ok)
	core.claude_panels_tick(time.tick_add(start, 65 * time.Second))
	testing.expect_value(t, f_rows(id, "subagents"), "Subagents · 1 running|● Explore · 1m 05s · Grep")
	// an older tool report (async) never replaces a newer current tool, but counts as a step
	sub(id, "tool", agent_id = "a1", tool = "Read", seq = 1)
	sub(id, "tool", agent_id = "a1", tool = "Bash", seq = 3)
	core.claude_panels_tick(time.tick_add(start, 3725 * time.Second))
	testing.expect_value(t, f_rows(id, "subagents"), "Subagents · 1 running|● Explore · 1h 02m · Bash")
	// silent past CLAUDE_AGENT_STALE (its SubagentStop lost?): no longer redrawn every second
	core.claude_panels_tick(time.tick_add(start, core.CLAUDE_AGENT_STALE + 3725 * time.Second))
	testing.expect_value(t, f_rows(id, "subagents"), "Subagents · 1 running|● Explore · 1h 02m · Bash")
	// an unknown agent's tool (its start not here yet, or an in-process teammate): nothing new
	testing.expect(t, sub(id, "tool", agent_id = "zz", tool = "Grep").ok)
	testing.expect(t, !strings.contains(f_rows(id, "subagents"), "zz"))
	testing.expect(t, !sub(id, "tool", agent_id = "a b", tool = "Grep").ok)
	// untrusted tool names are cleaned
	sub(id, "tool", agent_id = "a1", tool = "mcp__x\x1b[2J‮", seq = 4)
	testing.expect(t, !strings.contains_any(f_rows(id, "subagents"), "\x1b"), f_rows(id, "subagents"))
	// stopped: its time is frozen, its steps counted
	sub(id, "stop", agent_id = "a1", kind = "Explore")
	rows := f_rows(id, "subagents")
	testing.expect(t, strings.has_prefix(rows, "Subagents|✓ Explore · ") && strings.has_suffix(rows, " · 4 tools"), rows)
	core.claude_panels_tick(time.tick_add(start, 9000 * time.Second))
	testing.expect_value(t, f_rows(id, "subagents"), rows)
	// one tool: singular
	sub(id, "start", agent_id = "a2", kind = "Plan")
	sub(id, "tool", agent_id = "a2", tool = "Read")
	sub(id, "stop", agent_id = "a2")
	testing.expect(t, strings.contains(f_rows(id, "subagents"), "· 1 tool"), f_rows(id, "subagents"))
}

@(test)
claude_subagent_todos :: proc(t: ^testing.T) {
	context.allocator = f_reset()
	defer f_done()
	_, id := f_claude(t, "agenttodos")
	core.run_command(core.Claude_Todos{tab_id = id, todos = {{content = "Main work", status = "pending"}}}, F_SCRIPT)
	core.run_command(core.Claude_Subagent{tab_id = id, event = "launch", agent_type = "Explore", description = "Find it"}, F_SCRIPT)
	core.run_command(core.Claude_Subagent{tab_id = id, event = "start", agent_id = "a1", agent_type = "Explore"}, F_SCRIPT)
	r := core.run_command(core.Claude_Todos{tab_id = id, agent_id = "a1", seq = 5, todos = {{content = "Scan", status = "completed"}, {content = "Grep", status = "in_progress", active_form = "Grepping"}, {content = "Report", status = "pending"}}}, F_SCRIPT)
	testing.expect(t, r.ok, r.error)
	core.claude_panels_tick(time.tick_now())
	rows := f_rows(id, "subagents")
	testing.expect(t, strings.has_suffix(rows, "|  Find it|  Todos 1/3|  ✓ Scan|  ▸ Grepping|  ○ Report"), rows)
	// the main list is untouched
	testing.expect_value(t, f_rows(id, "todos"), "Todos 0/1|○ Main work")
	// an older list never overwrites a newer one
	core.run_command(core.Claude_Todos{tab_id = id, agent_id = "a1", seq = 3, todos = {{content = "stale", status = "pending"}}}, F_SCRIPT)
	testing.expect(t, !strings.contains(f_rows(id, "subagents"), "stale"))
	// an unknown subagent's list goes nowhere (never the main list)
	testing.expect(t, core.run_command(core.Claude_Todos{tab_id = id, agent_id = "zz", todos = {{content = "lost", status = "pending"}}}, F_SCRIPT).ok)
	testing.expect_value(t, f_rows(id, "todos"), "Todos 0/1|○ Main work")
	testing.expect(t, !strings.contains(f_rows(id, "subagents"), "lost"))
	testing.expect(t, !core.run_command(core.Claude_Todos{tab_id = id, agent_id = "a b", todos = {}}, F_SCRIPT).ok)
	// bounded: at most CLAUDE_AGENT_TODOS_SHOWN shown, the rest "+N more"
	many := make([]core.Claude_Todo_In, 30, context.temp_allocator)
	for &m, i in many do m = {content = fmt.tprintf("t%d", i), status = "pending"}
	core.run_command(core.Claude_Todos{tab_id = id, agent_id = "a1", seq = 6, todos = many}, F_SCRIPT)
	rows = f_rows(id, "subagents")
	testing.expect(t, strings.contains(rows, "  Todos 0/30") && strings.contains(rows, fmt.tprintf("  +%d more", 30 - core.CLAUDE_AGENT_TODOS_SHOWN)), rows)
	// done: only its count
	core.run_command(core.Claude_Subagent{tab_id = id, event = "stop", agent_id = "a1"}, F_SCRIPT)
	rows = f_rows(id, "subagents")
	testing.expect(t, strings.contains(rows, "  Todos 0/30") && !strings.contains(rows, "○ t0"), rows)
}
