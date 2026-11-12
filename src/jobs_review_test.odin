package main

// Jobs, review round 1 (`./build.sh test`): the prompt never read as a flag
// or a file; Recent runs writes keep the user's edits; Run now's caller
// rules; no approvals (an agent's job note runs on its schedule, old
// approval records are ignored, no Keychain code); read jobs get pi's tool
// allowlist; stops and quit kill the whole process
// tree; sessions pruned, events.jsonl capped, CRLF notes, pi only from
// absolute PATH entries. A fake HOME, notes and data folder in TMPDIR; fake
// `pi` scripts (/bin/sh).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
Fx :: struct {
	dir, notes, data, home: string,
	old_root, old_home:     string,
	saved:                  core.Settings,
}

@(private = "file")
fx_setup :: proc() -> (fx: Fx) {
	fx.dir = fmt.aprintf("%s/pd-jobsr-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	fx.notes = fmt.aprintf("%s/notes", fx.dir)
	fx.data = fmt.aprintf("%s/data", fx.dir)
	fx.home = fmt.aprintf("%s/home", fx.dir)
	for d in ([]string{fmt.tprintf("%s/jobs", fx.notes), fx.data, fx.home}) do os.make_directory_all(d)
	fx.old_root = core.home_root
	fx.old_home = os.get_env("HOME", context.allocator)
	os.set_env("HOME", fx.home)
	core.home_root = fx.data
	core.jobs_reset()
	fx.saved = state.settings
	state.settings.home_dir = fx.notes
	state.settings.jobs_paused = false
	state.settings.job_limits = {}
	state.settings.pi_path = ""
	state.settings.jobs_path = "/usr/bin:/bin"
	return
}

@(private = "file")
fx_done :: proc(fx: Fx) {
	core.jobs_shutdown()
	for _ in 0 ..< 200 {
		core.inbox_drain()
		if !core.jobs_any_running() do break
		time.sleep(20 * time.Millisecond)
	}
	core.jobs_reset()
	core.jobs_rows_free_all()
	state.settings = fx.saved
	core.home_root = fx.old_root
	os.set_env("HOME", fx.old_home)
	os.remove_all(fx.dir)
}

// A job note with the notes-vault fields and the given extra frontmatter.
@(private = "file")
note :: proc(fx: Fx, file, id, schedule, prompt: string, extra: ..string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "---\ntype: job\nproject: atlas\ndate: 2026-11-01\nstatus: active\nsummary: %s\ntags: [job]\nupdated_by: claude\nid: %s\nenabled: false\nschedule: \"%s\"\n", id, id, schedule)
	for l in extra do fmt.sbprintf(&b, "%s\n", l)
	fmt.sbprintf(&b, "---\n# Job %s\n\n## Prompt\n%s\n", id, prompt)
	path := fmt.tprintf("%s/jobs/%s.md", fx.notes, file)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b))
	return path
}

// A fake pi: a /bin/sh script.
@(private = "file")
fake_pi :: proc(fx: Fx, body: string) -> string {
	p := fmt.aprintf("%s/pi-%d", fx.dir, time.now()._nsec % 1_000_000)
	_ = os.write_entire_file(p, transmute([]u8)fmt.tprintf("#!/bin/sh\n%s\n", body))
	os.chmod(p, {.Read_User, .Write_User, .Execute_User})
	state.settings.pi_path = p
	return p
}

@(private = "file")
sync_rows :: proc() {
	core.jobs_scan(true)
	core.run_command(core.Jobs_Sync{})
}

@(private = "file")
row :: proc(id: string) -> ^core.Job_Row {
	for &r in state.jobs do if r.id == id do return &r
	return nil
}

// Until the job's run ended (the inbox delivers Job_Run_Done; the watchdog runs).
@(private = "file")
wait_done :: proc(t: ^testing.T, id: string, ms := 15000) -> bool {
	for _ in 0 ..< ms / 20 {
		core.inbox_drain()
		core.jobs_watch_all()
		core.run_command(core.Jobs_Sync{})
		if r := row(id); r != nil && !r.running && r.last_status != "" do return true
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, false, "%s: the run did not end", id)
	return false
}

@(private = "file")
alive :: proc(pid: int) -> bool {return pid > 0 && posix.getpgid(posix.pid_t(pid)) >= 0} // a zombie has none

@(private = "file")
UI :: core.Caller{kind = .UI}
@(private = "file")
CTL :: core.Caller{kind = .Control}

// 1, 6: the prompt after `--` (never a flag), never `@file`; read jobs get
// pi's tool allowlist and no MCP.
@(test)
jobs_argv_prompt_and_tools :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	for p in ([]string{"-v delete everything", "--help", "@~/.ssh/id_rsa", "plain"}) {
		argv := core.job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", p, .Full)
		dd := -1
		for a, i in argv do if a == "--" do dd = i
		testing.expectf(t, dd == len(argv) - 2, "-- right before the prompt: %v", argv)
		last := argv[len(argv) - 1]
		testing.expectf(t, !strings.has_prefix(last, "@"), "never a file argument: %q", last)
		testing.expect_value(t, strings.trim_left(last, "\n"), p)
		for a in argv do testing.expect(t, a != "--tools", "full: pi's own tools")
	}
	argv := core.job_argv("/bin/pi", "/s", "uuid", "", "", "/pre.md", "x", .Read)
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expectf(t, strings.contains(joined, "--tools read,grep,find,ls"), "read: the tool allowlist: %s", joined)
	testing.expectf(t, strings.contains(joined, "--no-mcp"), "read: no MCP tools: %s", joined)
}

// A read job on a known pi older than 1.0.4 never starts pi (its read-only flags would not
// hold); a full job still runs.
@(test)
jobs_read_needs_pi_1_0_4 :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	saved_v := state.reload.pi_version
	defer state.reload.pi_version = saved_v
	state.reload.pi_version = "1.0.3"
	ran := fmt.tprintf("%s/ran", fx.dir)
	fake_pi(fx, fmt.tprintf("touch %s\necho '{\"type\":\"agent_end\"}'", ran))
	note(fx, "r", "r1", "manual", "OK")
	note(fx, "f", "f1", "manual", "OK", "access: full")
	sync_rows()
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "r1"}, UI).ok)
	wait_done(t, "r1")
	testing.expect(t, !os.exists(ran), "the read job's pi never ran")
	if r := row("r1"); r != nil {
		testing.expect_value(t, r.last_status, "failed")
		testing.expect_value(t, r.last_headline, core.PI_READONLY_JOB_TOO_OLD)
	}
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "f1"}, UI).ok)
	wait_done(t, "f1")
	testing.expect(t, os.exists(ran), "a full job runs")
}

// 2: a Recent runs write right after the user's edit (no scan between)
// must not hide the edit from the next scan.
@(test)
jobs_recent_write_keeps_user_edit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	path := note(fx, "gone", "gone1", "manual", "OK", fmt.tprintf("folder: %s/nope", fx.dir))
	sync_rows()
	sync_rows()
	data, _ := os.read_entire_file(path, context.temp_allocator)
	time.sleep(5 * time.Millisecond)
	edited, _ := strings.replace(string(data), "# Job gone1\n", "# Job gone1 renamed\n", 1, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)edited) // the user's edit
	r := core.run_command(core.Job_Run_Now{job = "gone1"}, UI) // folder_missing: finishes at once, writes Recent runs
	testing.expect(t, r.ok, r.error)
	core.jobs_scan(false) // an ordinary scan
	core.run_command(core.Jobs_Sync{})
	testing.expect(t, row("gone1") != nil && row("gone1").name == "Job gone1 renamed", "the edit is seen by the next scan")
	after, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(after), "Job gone1 renamed") && strings.contains(string(after), "folder_missing"))
}

// 3: Run now from callers other than the user: not a paused or disabled
// job, not at a period limit, not without a free slot. The user's Run now
// may override paused and disabled, never the limits.
@(test)
jobs_run_now_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	fake_pi(fx, "echo '{\"type\":\"agent_start\"}'; exec sleep 30")
	note(fx, "a", "a1", "manual", "OK")
	note(fx, "b", "b1", "manual", "OK")
	sync_rows()
	// disabled (the note says enabled: false)
	r := core.run_command(core.Job_Run_Now{job = "a1"}, CTL)
	testing.expectf(t, !r.ok && strings.contains(r.error, "disabled"), "control, disabled: %v", r.error)
	testing.expect(t, core.run_command(core.Job_Set_Enabled{job = "a1", on = true}, UI).ok)
	testing.expect(t, core.run_command(core.Jobs_Pause{job = "a1"}, UI).ok)
	sync_rows()
	r = core.run_command(core.Job_Run_Now{job = "a1"}, CTL)
	testing.expectf(t, !r.ok && strings.contains(r.error, "paused"), "control, paused: %v", r.error)
	r = core.run_command(core.Job_Run_Now{job = "a1"}, core.Caller{kind = .Script})
	testing.expect(t, !r.ok, "a script, paused")
	// the user may run a paused, disabled job
	r = core.run_command(core.Job_Run_Now{job = "b1"}, UI)
	testing.expectf(t, r.ok, "the user, disabled: %v", r.error)
	// no free slot: refused for everyone
	core.run_command(core.Set_Job_Limits{concurrency = 1}, UI)
	r = core.run_command(core.Job_Run_Now{job = "a1"}, UI)
	testing.expectf(t, !r.ok && strings.contains(r.error, "at once"), "the user, no slot: %v", r.error)
	core.run_command(core.Job_Stop{}, UI)
	wait_done(t, "b1")
	core.run_command(core.Set_Job_Limits{concurrency = 0}, UI)
	// a period limit: refused for everyone
	ledger := fmt.tprintf("%s/jobs/old/runs/r1", fx.data)
	os.make_directory_all(ledger)
	_ = os.write_entire_file(fmt.tprintf("%s/meta.json", ledger), transmute([]u8)strings.concatenate({`{"ended":`, fmt.tprint(core.jobs_now()), `,"cost":2.5}`}, context.temp_allocator))
	core.jobs_reset()
	sync_rows()
	core.run_command(core.Set_Job_Limits{day = 1}, UI)
	r = core.run_command(core.Job_Run_Now{job = "b1"}, UI)
	testing.expectf(t, !r.ok && strings.contains(r.error, "limit"), "the user, over the daily limit: %v", r.error)
}

// 4: unknown frontmatter keys are errors (a job never runs with a key
// Deckhand does not understand), approval keys too (never job settings).
@(test)
jobs_unknown_keys_error :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	parse :: proc(text: string) -> core.Job_Def {return core.job_parse(text, "/n/jobs/x.md", context.temp_allocator)}
	u := parse("---\nid: x1\nschedule: manual\nacess: full\n---\n# T\n\n## Prompt\nhi\n")
	testing.expectf(t, strings.contains(u.err, "acess"), "an unknown key is an error: %q", u.err)
	o := parse("---\nid: x1\nschedule: manual\napproved: true\n---\n# T\n\n## Prompt\nhi\n")
	testing.expectf(t, strings.contains(o.err, "approved"), "an approval key is an error: %q", o.err)
}

// 5: no approvals (ATLAS.md §10.3). A job note an agent
// writes (enabled, on a schedule) runs at its due tick with no approval
// step; an old state.json's approval record is ignored and dropped at the
// next write; no key file is
// made; `enabled: false` in the note stops the schedule.
@(test)
jobs_agent_note_runs_without_approval :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	fake_pi(fx, "echo '{\"type\":\"agent_start\"}'; exit 0")
	// an old approval record that no longer matches anything
	sd := fmt.tprintf("%s/jobs/a1", fx.data)
	os.make_directory_all(sd)
	_ = os.write_entire_file(fmt.tprintf("%s/state.json", sd), transmute([]u8)string(`{"v":2,"next_due":0,"approved_on":false,"approved_mac":"00ff","approved_def":"title: \"old\"\n","paused_why":"","recent":[],"needs_you":[]}`))
	// written by an agent, as a file: enabled, every hour
	path := note(fx, "a", "a1", "every 1h", "OK")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	on, _ := strings.replace(string(data), "enabled: false", "enabled: true", 1, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)on)
	core.jobs_startup()
	sync_rows()
	r := row("a1")
	testing.expect(t, r != nil && r.err == "" && r.enabled, "loaded and enabled")
	// the first due check sets the next run; an hour later it starts: no approval asked
	core.jobs_clock_advance(0)
	testing.expect(t, row("a1").next_due > 0, "scheduled")
	core.jobs_clock_advance(3600)
	if !wait_done(t, "a1") do return
	runs, _ := os.read_all_directory_by_path(fmt.tprintf("%s/runs", sd), context.temp_allocator)
	testing.expectf(t, len(runs) == 1, "one run on its schedule: %d", len(runs))
	sj, _ := os.read_entire_file(fmt.tprintf("%s/state.json", sd), context.temp_allocator)
	testing.expectf(t, !strings.contains(string(sj), "approved"), "the old approval record is dropped: %s", sj)
	testing.expect(t, !os.exists(fmt.tprintf("%s/jobs/approval.key", fx.data)), "no approval key file")
	// enabled: false in the note stops the schedule
	data, _ = os.read_entire_file(path, context.temp_allocator)
	off, _ := strings.replace(string(data), "enabled: true", "enabled: false", 1, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)off)
	sync_rows()
	core.jobs_clock_advance(7200)
	testing.expect(t, !row("a1").enabled && !row("a1").running && row("a1").next_due == 0, "disabled: not scheduled")
	testing.expect(t, !core.run_command(core.Job_Run_Now{job = "a1"}, CTL).ok, "a disabled job: not for control")
}

// 7: a stop kills pi's whole tree, detached process groups too; quit
// does the same and records the run "stopped (quit)".
@(test)
jobs_stop_kills_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	gc := fmt.tprintf("%s/gc.pid", fx.dir)
	// a background job in its own process group (sh job control), as pi's bash tool starts commands
	fake_pi(fx, fmt.tprintf("echo '{\"type\":\"agent_start\"}'\nset -m\nsleep 61 &\necho $! > %s\nset +m\nexec sleep 60", gc))
	note(fx, "a", "a1", "manual", "OK")
	note(fx, "b", "b1", "manual", "OK")
	sync_rows()
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "a1"}, UI).ok)
	pid := 0
	for _ in 0 ..< 250 {
		data, _ := os.read_entire_file(gc, context.temp_allocator)
		pid, _ = strconv.parse_int(strings.trim_space(string(data)))
		if pid > 0 do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, alive(pid), "the detached grandchild runs")
	core.run_command(core.Job_Stop{job = "a1"}, UI)
	wait_done(t, "a1")
	for _ in 0 ..< 400 {
		if !alive(pid) do break
		core.jobs_watch_all()
		time.sleep(20 * time.Millisecond)
	}
	gone := !alive(pid)
	testing.expect(t, gone, "stop: the detached grandchild is gone")
	if !gone do posix.kill(posix.pid_t(pid), .SIGKILL) // ours: never leave it
	// quit
	os.remove(gc)
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "b1"}, UI).ok)
	pid = 0
	for _ in 0 ..< 250 {
		data, _ := os.read_entire_file(gc, context.temp_allocator)
		pid, _ = strconv.parse_int(strings.trim_space(string(data)))
		if pid > 0 do break
		time.sleep(20 * time.Millisecond)
	}
	core.jobs_shutdown()
	gone = !alive(pid)
	testing.expect(t, gone, "quit: the detached grandchild is gone")
	if !gone do posix.kill(posix.pid_t(pid), .SIGKILL)
	core.run_command(core.Jobs_Sync{})
	testing.expect_value(t, row("b1").last_status, "stopped (quit)")
	testing.expect(t, !core.jobs_any_running())
}

// 8: sessions/ pruned like runs/; events.jsonl capped; CRLF notes keep
// CRLF; pi only from absolute PATH entries.
@(test)
jobs_small_fixes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	// events.jsonl: about 6 MB of events
	fake_pi(fx, "i=0; while [ $i -lt 60000 ]; do echo '{\"type\":\"turn_start\",\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}'; i=$((i+1)); done")
	note(fx, "a", "a1", "manual", "OK")
	sync_rows()
	// an old session file: pruned at the run's end
	sd := fmt.tprintf("%s/jobs/a1/sessions", fx.data)
	os.make_directory_all(sd)
	old := fmt.tprintf("%s/2026-01-01T00-00-00-000Z_old.jsonl", sd)
	_ = os.write_entire_file(old, transmute([]u8)string("{}\n"))
	then := time.time_add(time.now(), -40 * 24 * time.Hour)
	cerr := os.change_times(old, then, then)
	testing.expectf(t, cerr == nil, "change_times: %v", cerr)
	ost, _ := os.stat(old, context.temp_allocator)
	testing.expectf(t, time.diff(ost.modification_time, time.now()) > 39 * 24 * time.Hour, "old mtime: %v", ost.modification_time)
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "a1"}, UI).ok)
	wait_done(t, "a1", 60000)
	testing.expect(t, !os.exists(old), "an old session is pruned")
	runs, _ := os.read_all_directory_by_path(fmt.tprintf("%s/jobs/a1/runs", fx.data), context.temp_allocator)
	testing.expect(t, len(runs) == 1)
	if len(runs) == 1 {
		st, _ := os.stat(fmt.tprintf("%s/events.jsonl", runs[0].fullpath), context.temp_allocator)
		testing.expectf(t, st.size <= 5 * 1024 * 1024 + 64 * 1024, "events.jsonl capped: %d", st.size)
	}
	// CRLF
	crlf := "---\r\nid: x\r\n---\r\n# T\r\n\r\n## Prompt\r\nhi\r\n"
	out := core.job_note_set_recent(crlf, {"- a line"})
	for i in 0 ..< len(out) do if out[i] == '\n' {
		testing.expectf(t, i > 0 && out[i - 1] == '\r', "CRLF kept at %d: %q", i, out)
		break
	}
	testing.expect(t, strings.count(out, "\n") == strings.count(out, "\r\n"), "every line ends CRLF")
	en := core.job_note_set_enabled("---\r\nid: x\r\n---\r\n", true)
	testing.expect(t, strings.count(en, "\n") == strings.count(en, "\r\n"), "enabled: added with CRLF")
	// pi on PATH: absolute entries only
	cwd, _ := os.get_working_directory(context.temp_allocator)
	defer os.set_working_directory(cwd)
	os.set_working_directory(fx.dir)
	os.make_directory_all(fmt.tprintf("%s/rel", fx.dir))
	_ = os.write_entire_file(fmt.tprintf("%s/rel/pi", fx.dir), transmute([]u8)string("#!/bin/sh\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/pi", fx.dir), transmute([]u8)string("#!/bin/sh\n"))
	state.settings.pi_path = ""
	state.settings.jobs_path = "rel:.::/nonexistent"
	// pi's managed install is looked for too: none under this HOME (never the machine's)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	defer os.set_env("HOME", old_home)
	old_cad, had_cad := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer if had_cad do os.set_env("PI_CODING_AGENT_DIR", old_cad)
	os.unset_env("PI_CODING_AGENT_DIR")
	os.set_env("HOME", fmt.tprintf("%s/rel", fx.dir))
	testing.expect_value(t, core.job_pi_path(), "")
	// with one there: that pi
	mbin := fmt.tprintf("%s/rel/.pi/agent/bin", fx.dir)
	os.make_directory_all(mbin)
	_ = os.write_entire_file(fmt.tprintf("%s/pi", mbin), transmute([]u8)string("#!/bin/sh\n"))
	_ = os.chmod(fmt.tprintf("%s/pi", mbin), os.perm_number(0o755))
	testing.expect_value(t, core.job_pi_path(), fmt.tprintf("%s/pi", mbin))
}

@(private = "file")
os_notes: [dynamic]string

// The bell (notify.odin) gets every delivered run: job id, title, status,
// one-line summary, run folder; one OS notification per run, not two (the
// bell's paced one for attention; Deckhand's own only for what the bell does
// not notify).
@(test)
jobs_deliver_to_bell :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	saved_platform := core.platform
	defer {
		core.platform = saved_platform
		for x in state.notices.items do _ = x
		core.run_command(core.Notifications_Clear{})
		clear(&os_notes)
		fx_done(fx)
	}
	core.platform.notify = proc(title, body: string) {append(&os_notes, strings.clone(title))}
	app.window_active = false // the window in the background: OS notifications go (its facts, client.odin)
	defer app.window_active = true
	core.run_command(core.Notifications_Clear{})
	clear(&os_notes)
	note(fx, "gone", "gone1", "manual", "OK", fmt.tprintf("folder: %s/nope", fx.dir))
	sync_rows()
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "gone1"}, UI).ok) // folder_missing: at once
	core.inbox_drain()
	found := false
	for x in state.notices.items do if x.job_id == "gone1" {
		found = true
		testing.expect_value(t, x.kind, core.Notice_Kind.Job_Failed)
		testing.expect_value(t, x.title, "Job gone1")
		testing.expectf(t, strings.contains(x.summary, "folder missing"), "summary: %q", x.summary)
		testing.expectf(t, strings.contains(x.run_dir, "/jobs/gone1/runs/"), "run_dir: %q", x.run_dir)
	}
	testing.expect(t, found, "the bell has the run")
	testing.expectf(t, len(os_notes) == 1, "one OS notification, not two: %v", os_notes)
}

// The Jobs row decides a job's banners: Bell off still notifies as its macOS says, and macOS
// never means no banner at all (no fallback of Deckhand's own).
@(test)
jobs_follow_the_jobs_row :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	saved_platform := core.platform
	defer {
		core.platform = saved_platform
		core.run_command(core.Set_Bell{jobs = true, macos = #partial [core.Bell_Group]Maybe(core.Os_When){.Jobs = .Default}}, UI)
		core.run_command(core.Notifications_Clear{})
		clear(&os_notes)
		fx_done(fx)
	}
	core.platform.notify = proc(title, body: string) {append(&os_notes, strings.clone(title))}
	app.window_active = false
	defer app.window_active = true
	core.run_command(core.Notifications_Clear{})
	clear(&os_notes)
	core.run_command(core.Set_Bell{jobs = false}, UI)
	note(fx, "gone", "gone2", "manual", "OK", fmt.tprintf("folder: %s/nope", fx.dir))
	sync_rows()
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "gone2"}, UI).ok)
	core.inbox_drain()
	for x in state.notices.items do testing.expectf(t, x.job_id != "gone2", "Bell off: not in the bell")
	testing.expectf(t, len(os_notes) == 1, "Bell off, macOS background: one banner: %v", os_notes)
	clear(&os_notes)
	core.run_command(core.Set_Bell{macos = #partial [core.Bell_Group]Maybe(core.Os_When){.Jobs = .Never}}, UI)
	note(fx, "gone", "gone3", "manual", "OK", fmt.tprintf("folder: %s/nope", fx.dir))
	sync_rows()
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "gone3"}, UI).ok)
	core.inbox_drain()
	testing.expectf(t, len(os_notes) == 0, "Bell off, macOS never: no banner: %v", os_notes)
}

// ---- review round 2 ----

// The open row's text wraps in the Jobs tab, never clipped.
@(test)
jobs_ui_open_row_wraps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	saved := state.settings.home_dir
	state.settings.home_dir = strings.clone("/tmp/pd-wrap-notes")
	r := core.Job_Row{id = "w1", name = "Wrap", schedule = "manual", path = "/tmp/pd-wrap-notes/jobs/w.md"}
	append(&r.needs_you, "delete every branch that is merged and then also force push the rewritten history of main to origin TAILMARK")
	append(&state.jobs, r)
	old_left, old_tab, old_w := state.layout.left_open, state.layout.left_tab, state.layout.left_width
	state.layout.left_open, state.layout.left_tab, state.layout.left_width = true, .Jobs, 240
	jobs_ui_set("w1", false)
	defer {
		jobs_ui_set("", false)
		clear(&state.jobs)
		state.settings.home_dir = saved
		state.layout.left_open, state.layout.left_tab, state.layout.left_width = old_left, old_tab, old_w
	}
	cmds := ui_layout(1000, 1400)
	all := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		tx := c.renderData.text
		strings.write_string(&all, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&all, ' ')
	}
	got := strings.to_string(all)
	testing.expectf(t, strings.contains(got, "TAILMARK"), "the end of a long line shows (wrapped, not clipped)")
	testing.expect(t, strings.contains(got, "force"), "its middle too")
	testing.expect(t, !strings.contains(got, "Approve"), "no Approve button")
}

// R2-2: a stopped run's children die even when pi exits on SIGTERM at once
// (a child that ignores SIGTERM, in its own group, not holding pi's output);
// at quit too.
@(test)
jobs_stop_kills_term_ignoring_child :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	gc := fmt.tprintf("%s/gc.pid", fx.dir)
	fake_pi(fx, fmt.tprintf("echo '{\"type\":\"agent_start\"}'\nset -m\n(trap '' TERM; exec sleep 62) > /dev/null 2>&1 &\necho $! > %s\nset +m\nexec sleep 60", gc))
	note(fx, "a", "a1", "manual", "OK")
	sync_rows()
	for round in 0 ..< 2 {
		os.remove(gc)
		testing.expect(t, core.run_command(core.Job_Run_Now{job = "a1"}, UI).ok)
		pid := 0
		for _ in 0 ..< 250 {
			data, _ := os.read_entire_file(gc, context.temp_allocator)
			pid, _ = strconv.parse_int(strings.trim_space(string(data)))
			if pid > 0 do break
			time.sleep(20 * time.Millisecond)
		}
		testing.expect(t, alive(pid), "the child runs")
		if round == 0 {
			core.run_command(core.Job_Stop{job = "a1"}, UI)
			wait_done(t, "a1")
		} else {
			core.jobs_shutdown()
		}
		gone := false
		for _ in 0 ..< 50 {
			if !alive(pid) {
				gone = true
				break
			}
			time.sleep(20 * time.Millisecond)
		}
		testing.expectf(t, gone, "%s: the SIGTERM-ignoring child is gone", round == 0 ? "stop" : "quit")
		if !gone do posix.kill(posix.pid_t(pid), .SIGKILL) // ours: never leave it
	}
}

// R2-3: once pi is reaped its pid is cleared, so nothing signals a reused pid.
@(test)
jobs_pid_cleared_after_reap :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	fake_pi(fx, "echo '{\"type\":\"agent_start\"}'; exit 0")
	note(fx, "a", "a1", "manual", "OK")
	sync_rows()
	testing.expect(t, core.run_command(core.Job_Run_Now{job = "a1"}, UI).ok)
	pid, done := 0, false
	for _ in 0 ..< 250 {
		pid, done = core.jobs_run_pid("a1")
		if done do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, done, "the reader reaped pi")
	testing.expect_value(t, pid, 0)
	wait_done(t, "a1")
}

// No approval key: startup makes none and removes the old file (test mode
// and non-macOS kept it there); no Keychain code is left in Deckhand (the
// browser's mock keychain switch, cef_macos.m, is Chromium's and unrelated).
@(test)
jobs_no_approval_key :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	kp := fmt.tprintf("%s/jobs/approval.key", fx.data)
	core.jobs_startup()
	testing.expect(t, !os.exists(kp), "no key made at startup")
	os.make_directory_all(fmt.tprintf("%s/jobs", fx.data))
	_ = os.write_entire_file(kp, transmute([]u8)string("00"))
	core.jobs_startup()
	testing.expect(t, !os.exists(kp), "an old key file is removed")
	sources := [?]struct {
		name, text: string,
	}{
		{"native/platform_macos.m", #load("native/platform_macos.m", string)},
		{"platform_darwin.odin", #load("platform_darwin.odin", string)},
		{"platform_other.odin", #load("platform_other.odin", string)},
		{"jobs.odin", #load("core/jobs.odin", string)},
		{"jobs_note.odin", #load("core/jobs_note.odin", string)},
	}
	for src in sources {
		for bad in ([]string{"SecItem", "kSecClass", "Security.framework", "Security/Security.h", "keychain_key", "crypto/hmac", "job_mac", "job_verified"}) {
			testing.expectf(t, !strings.contains(src.text, bad), "%s still has %q", src.name, bad)
		}
	}
}

// Review round 1: no due check before the login shell's PI_KIT_NOTES_DIR
// is known (a catch-up job at launch would get the main folder instead of
// the user's own), at most JOBS_ENV_WAIT seconds; a saved jobs_path at
// restore is not the login shell.
@(test)
jobs_wait_for_login_env :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	core.jobs_tick()
	testing.expect_value(t, core.jobs_last_check(), 0)
	core.run_command(core.Jobs_Env{path = "/usr/bin:/bin"}, {kind = .Internal}) // persist.odin's restore
	core.jobs_tick()
	testing.expect_value(t, core.jobs_last_check(), 0)
	core.run_command(core.Jobs_Env{path = "/usr/bin:/bin", notes = "", login = true}, {kind = .Internal})
	core.jobs_tick()
	testing.expect(t, core.jobs_last_check() != 0, "checked once the login shell answered")
	// no answer: the check runs after the wait anyway
	core.jobs_reset()
	core.jobs_tick()
	testing.expect_value(t, core.jobs_last_check(), 0)
	core.jobs_clock_offset += core.JOBS_ENV_WAIT + 1
	core.jobs_tick()
	testing.expect(t, core.jobs_last_check() != 0, "checked after the wait")
}

// Review round 1: a chats folder above a job's folder gets no starter.
@(test)
jobs_chats_above_job_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fx := fx_setup()
	defer fx_done(fx)
	work := fmt.tprintf("%s/work", fx.dir)
	repo := fmt.tprintf("%s/repo", work)
	os.make_directory_all(repo)
	note(fx, "j", "j1", "manual", "Do it.", fmt.tprintf("folder: %s", repo))
	core.jobs_scan(true)
	found := false
	for f in core.jobs_folders() do if f == repo do found = true
	testing.expect(t, found, "the job's folder is known")
	saved := state.settings.folders[.Chats]
	defer state.settings.folders[.Chats] = saved
	state.settings.folders[.Chats] = work
	core.chats_instructions_ensure("2026-11-01")
	testing.expect(t, !os.exists(fmt.tprintf("%s/AGENTS.md", work)), "no starter above a job's folder")
}
