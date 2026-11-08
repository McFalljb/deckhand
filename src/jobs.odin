package main

// Atlas jobs, step 1 (docs/ATLAS.md §3–§5, §7, §9): the scheduler runs
// inside the window. The disk is the shared state:
//
//   <jobs folder>/<slug>.md             the job notes (definition + Recent runs);
//                                       folder_of(.Jobs): <main folder>/jobs/ (folders.odin)
//   <data dir>/jobs/<id>/state.json     next due, failure streak, paused, run lines
//   <data dir>/jobs/<id>/runs/<stamp>/  events.jsonl, stderr.log, preamble.md,
//                                       summary.md (redacted), meta.json
//   <data dir>/jobs/<id>/sessions/      pi's --session-dir
//   <data dir>/jobs/<id>/run.lock       the run lock (jobs_run.odin)
//   <data dir>/jobs/scheduler.log       due, started, skipped, stopped
//
// jobs_tick (every frame, cheap) looks at the notes folder every
// JOBS_SCAN_EVERY, at the clock every JOBS_CHECK_EVERY (wall clock, so a
// sleep shows as a jump), and watches running runs once a second. It never
// asks for a redraw itself: State changes go through Jobs_Sync, which bumps
// the version only when the Jobs rows changed.
//
// Delivery (§7, as changed by the user on 2026-11-01): nothing goes into
// Atlas's context. A finished run is unread on the Jobs tab, raises a macOS
// notification by the job's `notify` while pi-desk is in the background,
// and emits the `job.finished` event (the top bar's notification centre
// consumes it). Atlas reads job state on demand: job_list, job_runs.
//
// No approvals (ATLAS.md §10.3): a job note runs as it says,
// whoever wrote it. The controls are the note's `enabled`, the per-job pause,
// Pause all and the limits and safety stops below. Approval fields left in
// an old state.json are ignored and dropped at its next write. pi-desk never
// touches the Keychain for jobs.

import "base:runtime"
import "core:hash"
import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:math/rand"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

JOBS_SCAN_EVERY :: 2 * time.Second
JOBS_CHECK_EVERY :: 30 // seconds of wall clock between due checks
RUNS_KEEP :: 100
RUNS_KEEP_DAYS :: 30
JOBS_MAX :: 200 // notes read from jobs/
JOB_NOTE_MAX :: 256 * 1024

// Defaults of the safety stops (§4.5, §10.2); settings change them, never off.
LOOP_CALLS_DEFAULT :: 5
STALL_DEFAULT :: 10 * 60
FAIL_PAUSE_DEFAULT :: 3

// Limits and safety-stop thresholds (Settings.job_limits). 0 = off for the
// limits, the default for the thresholds.
Job_Limits :: struct {
	max_cost:    f64, // per run, USD
	timeout:     i64, // per run, seconds
	max_turns:   int, // per run
	day:         f64, // USD across all jobs per calendar day / week (Mon) / month
	week:        f64,
	month:       f64,
	concurrency: int, // runs at once
	loop_calls:  int, // identical tool calls in a row → looping (default 5)
	stall:       i64, // seconds without an event → stalled (default 600)
	fail_pause:  int, // failures in a row → paused (default 3)
}

limit_loop :: proc() -> int {return state.settings.job_limits.loop_calls > 0 ? state.settings.job_limits.loop_calls : LOOP_CALLS_DEFAULT}
limit_stall :: proc() -> i64 {return state.settings.job_limits.stall > 0 ? state.settings.job_limits.stall : STALL_DEFAULT}
limit_fail :: proc() -> int {return state.settings.job_limits.fail_pause > 0 ? state.settings.job_limits.fail_pause : FAIL_PAUSE_DEFAULT}

// A job as the Jobs tab and job_list show it (State.jobs).
Job_Row :: struct {
	id:            string,
	name:          string,
	path:          string, // the note
	project:       string, // for_project as written ("" = none; the owner: jobs_owner.odin)
	folder:        string, // where it runs (absolute)
	schedule:      string,
	enabled:       bool,
	paused:        bool,
	paused_why:    string,
	running:       bool,
	queued:        bool,
	err:           string, // the note does not parse: it does not run
	warnings:      [dynamic]string,
	next_due:      i64, // Unix seconds, 0 = none
	last_at:       i64,
	last_status:   string,
	last_headline: string,
	last_run:      string, // the last run's folder name
	unread:        int,
	recent:        [dynamic]string, // the note's run lines, newest first
	needs_you:     [dynamic]string, // the last run's
}

// ---- runtime ----

@(private = "file")
Job :: struct {
	path:          string,
	mtime:         i64,
	size:          i64,
	arena:         virtual.Arena,
	def:           Job_Def,
	gone:          bool, // its note was removed (kept while a run finishes)
	dup_of:        string,
	// state.json
	next_due:      i64,
	last_end:      i64,
	last_at:       i64,
	failures:      int,
	paused:        bool,
	paused_why:    string,
	recent:        [dynamic]string,
	last_status:   string,
	last_headline: string,
	last_run:      string,
	needs_you:     [dynamic]string,
	skip_reason:   string, // recent[0] is this skip, skip_count times
	skip_count:    int,
	loaded:        bool, // state.json read
	// runtime
	run:           ^Job_Run,
	queued:        bool,
	queued_due:    i64,
	unread:        [dynamic]string, // unread run folder names
}

@(private = "file")
Spent :: struct {
	at:   i64,
	cost: f64,
}

@(private = "file")
Sched :: struct {
	jobs:        [dynamic]^Job,
	scan_at:     time.Tick,
	watch_at:    time.Tick,
	last_check:  i64, // wall clock of the last due check
	started:     i64, // wall clock of the first check: earlier due times were missed while closed
	dirty:       bool, // the rows need a Jobs_Sync
	ledger:      [dynamic]Spent, // cost of finished runs (31 days), for the period limits
	ledger_read: bool,
	last_notify: time.Tick,
	env_asked:   bool,
	env_known:   bool, // the login shell answered (or test mode: never asked)
	env_until:   i64, // wall clock: the due check waits for it until then
	notes_seen:  string, // the jobs folder the jobs were read from
	scanned:     bool,
	log:         ^os.File,
	run_seq:     int,
	quitting:    bool,
	timer:       ^thread.Thread,
	running:     int, // runs going (atomic: the timer reads it)
	stop_timer:  bool, // atomic
}

@(private = "file")
sched: Sched

// Test mode moves the scheduler's clock (autotest `jobs_clock`).
jobs_clock_offset: i64

jobs_now :: proc() -> i64 {return time.time_to_unix(time.now()) + jobs_clock_offset}

// ---- commands ----

Job_List :: struct {
	unread: bool, // only jobs with unread runs
}
Job_Runs :: struct {
	job:   string,
	limit: int,
}
Job_Run_Now :: struct {
	job: string,
}
Job_Stop :: struct {
	job: string, // "" = every running job
}
Jobs_Pause :: struct {
	job: string, // "" = all jobs (the kill switch)
}
Jobs_Resume :: struct {
	job: string,
}
Job_Create :: struct {
	name, schedule, prompt, folder: string,
	for_project: string, // the owner: a project (folder or name), atlas, chats, none; "" = none set (jobs_owner.odin)
}
// The job sheet's Create / Save (ui_job_sheet.odin): the whole note.
Job_Save :: struct {
	path:     string, // "" = a new note
	text:     string,
	based_on: string, // editing: job_note_hash of the note's text the edit started from (refused when the file has changed since)
}
Job_Mark_Read :: struct {
	job: string, // "" = every job
	run: string, // "" = all its runs
}
Job_Set_Enabled :: struct {
	job: string,
	on:  bool,
}
Job_Delete :: struct {
	job:     string,
	confirm: string,
}
Job_Open :: struct {
	job:  string,
	what: string, // note | report (the last run's summary; marks it read) | run_folder
}
Set_Pi_Path :: struct {
	path: string,
}
Set_Job_Limits :: struct {
	max_cost, day, week, month:                      Maybe(f64),
	timeout, stall:                                  Maybe(i64),
	max_turns, concurrency, loop_calls, fail_pause: Maybe(int),
}
// Internal only.
Jobs_Sync :: struct {} // the rows follow the scheduler
Jobs_Tick :: struct {} // the scheduler's timer thread (jobs_timer)
Job_Run_Done :: struct {
	run: ^Job_Run,
}
Jobs_Env :: struct {
	path, notes: string, // the login shell's PATH and PI_KIT_NOTES_DIR
	login:       bool, // from the login shell (not a saved jobs_path)
}

// The due check waits this long at most for the login shell's
// PI_KIT_NOTES_DIR (a catch-up run at launch would get the main folder
// instead of the user's own); then it runs with what is known.
JOBS_ENV_WAIT :: 10 // seconds

// The event the notification centre consumes (and any subscriber).
Job_Event :: struct {
	job, title, status, headline, run, run_dir, summary_path: string,
	scheduled_at:                                             i64,
	needs_you:                                                []string,
	unread:                                                   bool,
}

// job_approve (a removed command; json_read.odin): a clear refusal, never
// "unknown command".
JOB_APPROVE_REMOVED :: "job_approve was removed: jobs need no approval (a job note runs on its schedule while it says enabled: true; enabled: false, jobs_pause and the limits stop it)"

jobs_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Job_List:
		return {ok = true, data = jobs_list_json(c.unread)}, false
	case Job_Runs:
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		return {ok = true, data = job_runs_json(j, c.limit > 0 ? min(c.limit, RUNS_KEEP) : 10)}, false
	case Job_Run_Now:
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		if state.settings.jobs_paused do return fail("jobs are paused (Resume all first)"), false
		if err := job_runnable(j); err != "" do return fail(err), false
		if j.run != nil do return fail("this job is running"), false
		// the user may run a paused or disabled job by hand; nobody else may
		if caller.kind != .UI {
			if j.paused do return fail(fmt.tprintf("this job is paused (%s): only the user may run it now", j.paused_why)), false
			if !job_enabled(j) do return fail("this job is disabled: only the user may run it now"), false
		}
		// the limits hold for everyone
		if period_limit_reached(jobs_now()) do return fail("a spending limit (day, week or month) is reached"), false
		if !slot_free() do return fail("no free slot (Runs at once limit)"), false
		if err := job_start(j, jobs_now()); err != "" do return fail(err), true
		return {ok = true}, true
	case Job_Stop:
		n := 0
		for j in sched.jobs do if j.run != nil && (c.job == "" || j.def.id == c.job) {
			run_stop(j.run, .User)
			n += 1
		}
		if c.job != "" && n == 0 do return fail(job_by_id(c.job) == nil ? "no such job" : "this job is not running"), false
		return {ok = true}, false
	case Jobs_Pause:
		if c.job == "" {
			if state.settings.jobs_paused do return {ok = true}, false
			state.settings.jobs_paused = true
			sched_log("paused all jobs (%s)", CALLER_NAMES[caller.kind])
			sched.dirty = true
			return {ok = true}, true
		}
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		if j.paused do return {ok = true}, false
		job_pause(j, caller.kind == .UI ? "paused by you" : home_bound(caller) ? fmt.tprintf("paused by %s", agent_name()) : "paused by a script")
		return {ok = true}, true
	case Jobs_Resume:
		if c.job == "" {
			if !state.settings.jobs_paused do return {ok = true}, false
			state.settings.jobs_paused = false
			sched_log("resumed all jobs")
			sched.dirty = true
			return {ok = true}, true
		}
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		if !j.paused do return {ok = true}, false
		j.paused = false
		set_str(&j.paused_why, "")
		j.failures = 0
		j.next_due = 0 // from now, never a burst
		job_save(j)
		sched_log("%s: resumed", j.def.id)
		sched.dirty = true
		return {ok = true}, true
	case Job_Create:
		path, err := job_create(c.name, c.schedule, c.prompt, c.folder, c.for_project)
		if err != "" do return fail(err), false
		jobs_scan(true)
		// the user's New job: the draft opens in an editor tab to fill in
		if caller.kind == .UI && cur() != nil do run_command(Open_File{path = path}, caller)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"path":`)
		json_quote(&b, path)
		strings.write_byte(&b, '}')
		return {ok = true, data = strings.to_string(b)}, true
	case Job_Save:
		path, err := job_note_save(c.path, c.text, c.based_on)
		// the sheet closes (the Jobs tab shows, its row open), or says why
		if caller.kind == .UI && job_sheet_saved(path, err) {
			state.layout.left_open = true
			state.layout.left_tab = .Jobs
		}
		if err != "" do return fail(err), false
		jobs_scan(true)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"path":`)
		json_quote(&b, path)
		strings.write_byte(&b, '}')
		return {ok = true, data = strings.to_string(b)}, true
	case Job_Mark_Read:
		n := 0
		for j in sched.jobs do if c.job == "" || j.def.id == c.job do n += job_mark_read(j, c.run)
		if c.job != "" && job_by_id(c.job) == nil do return fail("no such job"), false
		return {ok = true}, n > 0
	case Job_Set_Enabled:
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		if j.def.enabled == c.on do return {ok = true}, false
		if err := job_note_enable(j, c.on); err != "" do return fail(err), false
		return {ok = true}, true
	case Job_Delete:
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		if j.run != nil do return fail("this job is running: stop it first"), false
		gr, go_on, ch := confirm_gate(Job_Delete{job = c.job}, .Delete, caller, c.confirm, fmt.tprintf("move job %q (%s) to the Trash? Its run history stays in Deckhand's data folder.", j.def.name, fs_display(j.path)))
		if !go_on do return gr, ch
		if !fs_trash_fn(j.path) do return fail("could not move the note to the Trash"), ch
		sched_log("%s: note moved to the Trash", j.def.id)
		jobs_scan(true)
		return {ok = true}, true
	case Job_Open:
		j := job_by_id(c.job)
		if j == nil do return fail("no such job"), false
		switch c.what {
		case "note":
			return run_command(Open_File{path = j.path}, caller), false
		case "report":
			if j.last_run == "" do return fail("no run yet"), false
			p := fmt.tprintf("%s/runs/%s/summary.md", job_data_dir(j.def.id), j.last_run)
			res := run_command(Open_File{path = p}, caller)
			if res.ok && job_mark_read(j, j.last_run) > 0 do return res, true
			return res, false
		case "run_folder":
			if j.last_run == "" do return fail("no run yet"), false
			if platform.reveal != nil do platform.reveal(fmt.tprintf("%s/runs/%s", job_data_dir(j.def.id), j.last_run))
			return {ok = true}, false
		}
		return fail("what: note, report or run_folder"), false
	case Set_Pi_Path:
		path := strings.trim_space(c.path)
		if path != "" && !filepath.is_abs(path) do return fail("path must be absolute"), false
		if path == state.settings.pi_path do return {ok = true}, false
		delete(state.settings.pi_path)
		state.settings.pi_path = strings.clone(path)
		return {ok = true}, true
	case Set_Job_Limits:
		l := &state.settings.job_limits
		old := l^
		money :: proc(dst: ^f64, v: Maybe(f64)) -> bool {
			x, ok := v.?
			if !ok do return true
			if x < 0 do return false
			dst^ = x
			return true
		}
		if !money(&l.max_cost, c.max_cost) || !money(&l.day, c.day) || !money(&l.week, c.week) || !money(&l.month, c.month) {
			l^ = old
			return fail("amounts must be 0 (off) or more"), false
		}
		if v, ok := c.timeout.?; ok do l.timeout = max(v, 0)
		if v, ok := c.max_turns.?; ok do l.max_turns = max(v, 0)
		if v, ok := c.concurrency.?; ok do l.concurrency = max(v, 0)
		// the safety stops cannot be turned off: at least 1
		if v, ok := c.stall.?; ok do l.stall = max(v, 1)
		if v, ok := c.loop_calls.?; ok do l.loop_calls = max(v, 2)
		if v, ok := c.fail_pause.?; ok do l.fail_pause = max(v, 1)
		return {ok = true}, l^ != old
	case Jobs_Sync:
		return {ok = true}, jobs_rows_build()
	case Jobs_Tick:
		jobs_tick()
		return {ok = true}, false
	case Job_Run_Done:
		job_finish(c.run)
		return {ok = true}, jobs_rows_build()
	case Jobs_Env:
		if c.login do sched.env_known = true
		ch := false
		if state.settings.jobs_path == "" && c.path != "" {
			state.settings.jobs_path = strings.clone(c.path)
			ch = true
		}
		// the user's own PI_KIT_NOTES_DIR: it wins (folders.odin), and the setup sheet offers it
		if n := strings.trim_right(c.notes, "/"); n != folders_login_notes {
			delete(folders_login_notes)
			folders_login_notes = strings.clone(n)
			setup_detect_again()
			ch = true
		}
		return {ok = true}, ch
	}
	return fail("unknown command"), false
}

// Why a job may not run now ("" = it may).
@(private = "file")
job_runnable :: proc(j: ^Job) -> string {
	if j.def.err != "" do return fmt.tprintf("the note does not parse: %s", j.def.err)
	if j.dup_of != "" do return j.dup_of
	return ""
}

// Runs on its schedule: the note says enabled (no approval step).
@(private = "file")
job_enabled :: proc(j: ^Job) -> bool {return j.def.enabled}

// ---- small helpers ----

@(private = "file")
set_str :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	delete(dst^)
	dst^ = strings.clone(v)
}

@(private = "file")
job_by_id :: proc(id: string) -> ^Job {
	if id == "" do return nil
	for j in sched.jobs do if j.def.id == id && j.dup_of == "" && !j.gone do return j
	return nil
}

job_data_dir :: proc(id: string) -> string {
	return fmt.tprintf("%s/jobs/%s", home_root, id)
}

@(private = "file")
mkdir_private :: proc(p: string) {
	os.make_directory_all(p, {.Read_User, .Write_User, .Execute_User})
}

// <data dir>/jobs/scheduler.log: one line per scheduler decision (rotated at 1 MB).
@(private = "file")
sched_log :: proc(format: string, args: ..any) {
	if home_root == "" do return
	if sched.log == nil {
		dir := fmt.tprintf("%s/jobs", home_root)
		mkdir_private(dir)
		p := fmt.tprintf("%s/scheduler.log", dir)
		if st, err := os.stat(p, context.temp_allocator); err == nil && st.size > 1024 * 1024 do os.rename(p, fmt.tprintf("%s.1", p))
		sched.log, _ = os.open(p, {.Write, .Create, .Append}, {.Read_User, .Write_User})
		if sched.log == nil do return
	}
	c, _ := unix_to_local(jobs_now())
	fmt.fprintf(sched.log, "%04d-%02d-%02d %02d:%02d ", c.year, c.month, c.day, c.hour, c.minute)
	fmt.fprintfln(sched.log, format, ..args)
}

// "2026-11-01 07:00" local.
@(private = "file")
local_stamp :: proc(t: i64) -> string {
	c, _ := unix_to_local(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d", c.year, c.month, c.day, c.hour, c.minute)
}

// RFC 3339 local time with its offset (PI_DESK_SCHEDULED_AT).
iso_local :: proc(t: i64) -> string {
	tt := posix.time_t(t)
	tm: posix.tm
	posix.localtime_r(&tt, &tm)
	off := int(tm.tm_gmtoff) / 60
	sign := off < 0 ? '-' : '+'
	off = abs(off)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d%c%02d:%02d", int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday), int(tm.tm_hour), int(tm.tm_min), int(tm.tm_sec), sign, off / 60, off % 60)
}

@(private = "file")
dur_text :: proc(s: i64) -> string {
	switch {
	case s < 60:   return fmt.tprintf("%ds", s)
	case s < 3600: return fmt.tprintf("%dm%02ds", s / 60, s % 60)
	}
	return fmt.tprintf("%dh%02dm", s / 3600, (s % 3600) / 60)
}

job_status_icon :: proc(status: string) -> string {
	switch status {
	case "ok":                     return "✅"
	case "quiet":                  return "💤"
	case "unchanged":              return "·"
	case "needs_you":              return "🙋"
	case "failed", "check_failed": return "❌"
	case "timeout":                return "⏱"
	case "over_limit":             return "💸"
	case "looping":                return "🔁"
	case "stalled":                return "⏸"
	case "folder_missing":         return "📁"
	}
	return "•"
}

@(private = "file")
job_failure :: proc(status: string) -> bool {
	switch status {
	case "failed", "timeout", "looping", "stalled", "check_failed": return true
	}
	return false
}

// ---- the notes folder ----

// Reads <jobs folder>/*.md when something there changed (or force).
jobs_scan :: proc(force_ := false) {
	force := force_
	notes := folder_of(.Jobs)
	if notes != sched.notes_seen {
		delete(sched.notes_seen)
		sched.notes_seen = strings.clone(notes)
		force = true
	}
	sched.scan_at = time.tick_now()
	sched.scanned = true
	seen := make(map[string]bool, context.temp_allocator)
	if notes != "" && home_root != "" {
		dir := notes
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		n := 0
		for e in entries {
			if e.type != .Regular || !strings.has_suffix(e.name, ".md") || strings.has_prefix(e.name, ".") do continue
			n += 1
			if n > JOBS_MAX do break
			seen[e.fullpath] = true
			j: ^Job
			for x in sched.jobs do if x.path == e.fullpath do j = x
			mt := time.time_to_unix_nano(e.modification_time)
			if j != nil && !force && j.mtime == mt && j.size == e.size && !j.gone do continue
			if j == nil {
				j = new(Job)
				j.path = strings.clone(e.fullpath)
				append(&sched.jobs, j)
			}
			if j.gone || j.mtime == 0 do settings_gen += 1 // the Settings tab lists the notes
			j.gone = false
			j.mtime, j.size = mt, e.size
			job_reparse(j)
		}
	}
	// notes that went: their jobs go (a running one once it ends)
	for i := len(sched.jobs) - 1; i >= 0; i -= 1 {
		j := sched.jobs[i]
		if seen[j.path] do continue
		if !j.gone {
			sched_log("%s: note gone (%s)", j.def.id, j.path)
			settings_gen += 1
		}
		j.gone = true
		if j.run == nil {
			job_drop(j)
			ordered_remove(&sched.jobs, i)
		}
	}
	// one id, one job: later notes with a used id are errors
	for j in sched.jobs do set_str(&j.dup_of, "")
	for j, i in sched.jobs {
		if j.def.id == "" || j.gone do continue
		for k in sched.jobs[:i] do if !k.gone && k.def.id == j.def.id && k.dup_of == "" {
			set_str(&j.dup_of, fmt.tprintf("id %s is also used by %s: give this note its own id", j.def.id, filepath.base(k.path)))
			break
		}
	}
	sched.dirty = true
}

@(private = "file")
job_reparse :: proc(j: ^Job) {
	old_id := strings.clone(j.def.id, context.temp_allocator)
	virtual.arena_destroy(&j.arena)
	_ = virtual.arena_init_growing(&j.arena)
	text := ""
	if data, err := os.read_entire_file(j.path, context.temp_allocator); err == nil && len(data) <= JOB_NOTE_MAX do text = string(data)
	j.def = job_parse(text, j.path, virtual.arena_allocator(&j.arena))
	if text == "" && j.def.err == "" do j.def.err = "cannot read the note (or it is over 256 KB)"
	if j.def.id != old_id || !j.loaded do job_load(j)
}

@(private = "file")
job_drop :: proc(j: ^Job) {
	virtual.arena_destroy(&j.arena)
	job_clear_state(j)
	delete(j.path)
	delete(j.dup_of)
	for u in j.unread do delete(u)
	delete(j.unread)
	free(j)
}

@(private = "file")
job_clear_state :: proc(j: ^Job) {
	delete(j.paused_why)
	delete(j.last_status)
	delete(j.last_headline)
	delete(j.last_run)
	delete(j.skip_reason)
	for l in j.recent do delete(l)
	delete(j.recent)
	for l in j.needs_you do delete(l)
	delete(j.needs_you)
	j.paused_why, j.last_status, j.last_headline, j.last_run, j.skip_reason = "", "", "", "", ""
	j.recent, j.needs_you = {}, {}
	j.next_due, j.last_end, j.last_at, j.failures, j.paused, j.skip_count = 0, 0, 0, 0, false, 0
}

// ---- state.json ----

@(private = "file")
job_load :: proc(j: ^Job) {
	job_clear_state(j)
	for u in j.unread do delete(u)
	clear(&j.unread)
	j.loaded = true
	if !job_id_valid(j.def.id) || home_root == "" do return
	dir := job_data_dir(j.def.id)
	if data, err := os.read_entire_file(fmt.tprintf("%s/state.json", dir), context.temp_allocator); err == nil {
		v, perr := jg.parse(data, .JSON, true, context.temp_allocator)
		o, _ := v.(json.Object)
		if perr == nil {
			i :: proc(o: json.Object, k: string) -> i64 {
				#partial switch n in o[k] {
				case json.Integer: return i64(n)
				case json.Float:   return i64(n)
				}
				return 0
			}
			s :: proc(o: json.Object, k: string) -> string {x, _ := o[k].(json.String); return strings.clone(string(x))}
			j.next_due, j.last_end, j.last_at = i(o, "next_due"), i(o, "last_end"), i(o, "last_at")
			j.failures = int(i(o, "failures"))
			p, _ := o["paused"].(json.Boolean)
			j.paused = bool(p)
			// approved_mac, approved_on, approved_def (approvals, removed): ignored, dropped at the next write
			j.paused_why = s(o, "paused_why")
			j.last_status, j.last_headline, j.last_run = s(o, "last_status"), s(o, "last_headline"), s(o, "last_run")
			j.skip_reason, j.skip_count = s(o, "skip_reason"), int(i(o, "skip_count"))
			if a, ok := o["recent"].(json.Array); ok do for x in a do if str, sok := x.(json.String); sok && len(j.recent) < RECENT_MAX do append(&j.recent, strings.clone(string(str)))
			if a, ok := o["needs_you"].(json.Array); ok do for x in a do if str, sok := x.(json.String); sok && len(j.needs_you) < 50 do append(&j.needs_you, strings.clone(string(str)))
		}
	}
	// unread runs: meta.json read = false
	runs, _ := os.read_all_directory_by_path(fmt.tprintf("%s/runs", dir), context.temp_allocator)
	for r in runs {
		if r.type != .Directory do continue
		data, err := os.read_entire_file(fmt.tprintf("%s/meta.json", r.fullpath), context.temp_allocator)
		if err != nil do continue
		v, _ := jg.parse(data, .JSON, true, context.temp_allocator)
		o, _ := v.(json.Object)
		if rd, ok := o["read"].(json.Boolean); ok && !rd do append(&j.unread, strings.clone(r.name))
	}
	slice.sort(j.unread[:])
}

@(private = "file")
job_save :: proc(j: ^Job) {
	if !job_id_valid(j.def.id) || home_root == "" do return
	dir := job_data_dir(j.def.id)
	mkdir_private(dir)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":3,"next_due":%d,"last_end":%d,"last_at":%d,"failures":%d,"paused":%v,"skip_count":%d`, j.next_due, j.last_end, j.last_at, j.failures, j.paused, j.skip_count)
	pairs := [?][2]string{{"paused_why", j.paused_why}, {"last_status", j.last_status}, {"last_headline", j.last_headline}, {"last_run", j.last_run}, {"skip_reason", j.skip_reason}}
	for p in pairs {
		strings.write_string(&b, ",")
		json_quote(&b, p[0])
		strings.write_byte(&b, ':')
		json_quote(&b, p[1])
	}
	lists := [2]struct {
		k: string,
		l: []string,
	}{{"recent", j.recent[:]}, {"needs_you", j.needs_you[:]}}
	for l in lists {
		fmt.sbprintf(&b, `,"%s":[`, l.k)
		for x, i in l.l {
			if i > 0 do strings.write_byte(&b, ',')
			json_quote(&b, x)
		}
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "}\n")
	write_atomic(fmt.tprintf("%s/state.json", dir), strings.to_string(b))
}

// ---- the note: pi-desk's lines ----

// Rewrites the note's Recent runs from j.recent (re-read first; a temp
// file renamed over it; once more if it changed in between).
@(private = "file")
job_note_write_recent :: proc(j: ^Job) {
	for attempt in 0 ..< 3 {
		info, serr := os.stat(j.path, context.temp_allocator)
		data, err := os.read_entire_file(j.path, context.temp_allocator)
		if err != nil || serr != nil do return
		seen := time.time_to_unix_nano(info.modification_time) == j.mtime && info.size == j.size // the scan has read this version
		out := job_note_set_recent(string(data), j.recent[:])
		if out == string(data) do return
		// a temp file next to it, renamed over it only if the note did not
		// change since it was read (else read it again: never lose a save)
		slash := strings.last_index_byte(j.path, '/')
		tmp := fmt.tprintf("%s/.%s.pi-desk-%d", j.path[:max(slash, 0)], j.path[slash + 1:], posix.getpid())
		if werr := write_atomic(tmp, out); werr != "" {
			sched_log("%s: could not write Recent runs: %s", j.def.id, werr)
			return
		}
		if mode, merr := os.stat(j.path, context.temp_allocator); merr == nil do os.chmod(tmp, mode.mode)
		info2, e2 := os.stat(j.path, context.temp_allocator)
		if e2 != nil || info2.modification_time != info.modification_time || info2.size != info.size {
			os.remove(tmp)
			continue
		}
		if os.rename(tmp, j.path) != nil {
			os.remove(tmp)
			sched_log("%s: could not write Recent runs", j.def.id)
			return
		}
		// our own write: no reparse needed, unless the scan has not read the
		// version we started from (a user's edit: the next scan reads it)
		if seen do if info3, e3 := os.stat(j.path, context.temp_allocator); e3 == nil {
			j.mtime, j.size = time.time_to_unix_nano(info3.modification_time), info3.size
		}
		return
	}
	sched_log("%s: Recent runs not written: the note keeps changing", j.def.id)
}

// Sets `enabled:` in the note (at jobs disable themselves; job_set_enabled).
@(private = "file")
job_note_enable :: proc(j: ^Job, on: bool) -> string {
	data, err := os.read_entire_file(j.path, context.temp_allocator)
	if err != nil do return "cannot read the note"
	out := job_note_set_enabled(string(data), on)
	if out == "" do return "the note has no frontmatter"
	if werr := write_atomic(j.path, out); werr != "" do return werr
	j.def.enabled = on // the scan reads it again
	j.next_due = 0
	job_save(j)
	sched.dirty = true // the scan reads the note again (its time changed)
	return ""
}

// Adds a run line (newest first, at most RECENT_MAX). Skips of the same
// reason in a row are one line with a count.
@(private = "file")
job_add_line :: proc(j: ^Job, line: string, skip_reason := "") {
	if skip_reason != "" && skip_reason == j.skip_reason && len(j.recent) > 0 {
		j.skip_count += 1
		delete(j.recent[0])
		j.recent[0] = strings.clone(fmt.tprintf("%s ×%d", line, j.skip_count))
	} else {
		inject_at(&j.recent, 0, strings.clone(line))
		set_str(&j.skip_reason, skip_reason)
		j.skip_count = skip_reason != "" ? 1 : 0
		for len(j.recent) > RECENT_MAX {
			delete(j.recent[len(j.recent) - 1])
			pop(&j.recent)
		}
	}
	job_note_write_recent(j)
}

@(private = "file")
job_skip :: proc(j: ^Job, due: i64, reason: string) {
	sched_log("%s: skipped (%s), due %s", j.def.id, reason, local_stamp(due))
	job_add_line(j, fmt.tprintf("- %s ⏭ skipped (%s)", local_stamp(due), reason), reason)
	sched.dirty = true
}

@(private = "file")
job_pause :: proc(j: ^Job, why: string) {
	j.paused = true
	set_str(&j.paused_why, why)
	job_save(j)
	sched_log("%s: paused (%s)", j.def.id, why)
	sched.dirty = true
}

// ---- the clock ----

// Every frame (main.odin): the notes folder, the due check, the watchdog.
jobs_tick :: proc() {
	if home_root == "" do return
	if !sched.env_asked {
		sched.env_asked = true
		sched.env_until = jobs_now() + JOBS_ENV_WAIT
		jobs_env_start()
		jobs_startup()
		if !ODIN_TEST do sched.timer = thread.create_and_start(jobs_timer)
	}
	if !sched.scanned || time.tick_since(sched.scan_at) >= JOBS_SCAN_EVERY do jobs_scan()
	now := jobs_now()
	env_ready := sched.env_known || now >= sched.env_until
	if env_ready && (sched.last_check == 0 || now - sched.last_check >= JOBS_CHECK_EVERY || now < sched.last_check) do jobs_check(now)
	if time.tick_since(sched.watch_at) >= time.Second {
		sched.watch_at = time.tick_now()
		for j in sched.jobs do if j.run != nil do run_watch(j.run, now)
	}
	if sched.dirty {
		sched.dirty = false
		run_command(Jobs_Sync{})
	}
}

// The scheduler's clock while frames are paused (the window minimised or
// hidden, App Nap): a Jobs_Tick every second while a run goes (the
// watchdog), else every JOBS_CHECK_EVERY (the due check). The inbox wakes
// the main thread for it; it draws nothing.
@(private = "file")
jobs_timer :: proc() {
	n := 0
	for !sync.atomic_load(&sched.stop_timer) {
		time.sleep(time.Second)
		n += 1
		if sync.atomic_load(&sched.running) > 0 || n >= JOBS_CHECK_EVERY {
			n = 0
			inbox_submit(Jobs_Tick{}, {kind = .Internal})
		}
	}
}

// The due check: start what is due, skip (with a reason) what is too late
// or not allowed now, queue what waits for a free slot.
jobs_check :: proc(now: i64) {
	if !ledger_ready() do return
	if sched.started == 0 do sched.started = now
	sched.last_check = now
	for j in sched.jobs {
		if j.gone || job_runnable(j) != "" || !job_enabled(j) || j.def.schedule.kind == .Manual {
			if j.next_due != 0 && !j.gone && j.def.schedule.kind != .At {
				j.next_due = 0 // computed again from when it may run
				job_save(j)
				sched.dirty = true
			}
			continue
		}
		s := j.def.schedule
		if j.next_due == 0 {
			j.next_due = schedule_next(s, now, j.last_end)
			if s.kind == .At && s.at <= j.last_at do j.next_due = 0 // ran already
			job_save(j)
			sched.dirty = true
			continue
		}
		if now < j.next_due || j.queued do continue
		due := j.next_due
		late := now - due
		reason := ""
		switch {
		case state.settings.jobs_paused || j.paused: reason = "paused"
		case late > grace_window(s, due):           reason = due < sched.started ? "closed" : "asleep"
		case !in_hours(j.def.hours_from, j.def.hours_to, now): reason = "outside hours"
		case period_limit_reached(now):             reason = "limit reached"
		case j.run != nil:                          reason = "previous run still going"
		}
		// the next due time, after this tick
		switch s.kind {
		case .Cron:  j.next_due = cron_next(s.cron, now)
		case .Every: j.next_due = now + s.every // again from the run's end when it runs
		case .At, .Manual: j.next_due = 0
		}
		if reason != "" {
			job_skip(j, due, reason)
		} else if !slot_free() {
			j.queued, j.queued_due = true, due
			sched_log("%s: queued (concurrency limit)", j.def.id)
			sched.dirty = true
		} else if err := job_start(j, due); err != "" {
			sched_log("%s: not started: %s", j.def.id, err)
		}
		if s.kind == .At {
			j.last_at = max(j.last_at, s.at)
			job_note_enable(j, false) // an `at` job runs once, then disables itself
		}
		job_save(j)
	}
	jobs_dequeue()
}

@(private = "file")
slot_free :: proc() -> bool {
	limit := state.settings.job_limits.concurrency
	if limit <= 0 do return true
	n := 0
	for j in sched.jobs do if j.run != nil do n += 1
	return n < limit
}

// Queued runs start in due order as slots free up.
@(private = "file")
jobs_dequeue :: proc() {
	for slot_free() {
		next: ^Job
		for j in sched.jobs do if j.queued && j.run == nil && (next == nil || j.queued_due < next.queued_due) do next = j
		if next == nil do return
		next.queued = false
		if state.settings.jobs_paused || next.paused || job_runnable(next) != "" {
			job_skip(next, next.queued_due, "paused")
			continue
		}
		if err := job_start(next, next.queued_due); err != "" do sched_log("%s: not started: %s", next.def.id, err)
	}
}

// ---- the cost ledger (period limits) ----

@(private = "file")
ledger_ready :: proc() -> bool {
	if sched.ledger_read do return true
	sched.ledger_read = true
	if home_root == "" do return true
	cut := jobs_now() - 32 * 86400
	jobs, _ := os.read_all_directory_by_path(fmt.tprintf("%s/jobs", home_root), context.temp_allocator)
	for jd in jobs {
		if jd.type != .Directory do continue
		runs, _ := os.read_all_directory_by_path(fmt.tprintf("%s/runs", jd.fullpath), context.temp_allocator)
		for r in runs {
			data, err := os.read_entire_file(fmt.tprintf("%s/meta.json", r.fullpath), context.temp_allocator)
			if err != nil do continue
			v, _ := jg.parse(data, .JSON, true, context.temp_allocator)
			o, _ := v.(json.Object)
			at := i64(o["ended"].(json.Integer) or_else 0)
			cost := f64(o["cost"].(json.Float) or_else 0)
			if at >= cut && cost > 0 do append(&sched.ledger, Spent{at, cost})
		}
	}
	return true
}

// Spent since the start of today, this week (Monday) and this month, local.
period_spent :: proc(now: i64) -> (day, week, month: f64) {
	c, wday := unix_to_local(now)
	d0, _ := local_to_unix({c.year, c.month, c.day, 0, 0})
	if d0 == 0 do d0 = now - i64(c.hour * 3600 + c.minute * 60)
	w0 := d0 - i64((wday + 6) % 7) * 86400
	m0, _ := local_to_unix({c.year, c.month, 1, 0, 0})
	if m0 == 0 do m0 = d0 - i64(c.day - 1) * 86400
	for s in sched.ledger {
		if s.at >= d0 do day += s.cost
		if s.at >= w0 do week += s.cost
		if s.at >= m0 do month += s.cost
	}
	return
}

@(private = "file")
period_limit_reached :: proc(now: i64) -> bool {
	l := state.settings.job_limits
	if l.day <= 0 && l.week <= 0 && l.month <= 0 do return false
	ledger_ready()
	d, w, m := period_spent(now)
	return (l.day > 0 && d >= l.day) || (l.week > 0 && w >= l.week) || (l.month > 0 && m >= l.month)
}

// ---- starting a run ----

// pi: the setting pi_path, else `pi` on the jobs' PATH, else pi's managed
// install (login_env.odin; jobs_path is usually the login shell's, saved).
// Test mode: only pi_path (a scene's fake) or PI_DESK_REAL_PI=1; never the real pi by search.
job_pi_path :: proc() -> string {
	if p := state.settings.pi_path; p != "" do return p
	if test_mode() && hook_env(.Real_Pi) != "1" {
		test_mode_refused("pi (jobs: no pi_path)")
		return ""
	}
	for d in strings.split(jobs_env_path(), ":", context.temp_allocator) {
		if !strings.has_prefix(d, "/") do continue // "", ".", relative: never pi from wherever the cwd is
		p := fmt.tprintf("%s/pi", d)
		if path_kind(p) == .File do return p
	}
	return pi_managed_path()
}

@(private = "file")
jobs_env_path :: proc() -> string {
	if p := state.settings.jobs_path; p != "" do return p
	if p, _ := env_lookup(child_base_env(), "PATH"); p != "" do return p // refreshed (login_env.odin), else ours
	return "/usr/bin:/bin:/usr/sbin:/sbin"
}

// Atlas's prompt for job runs (§3.7): the notes copy, else whatever Atlas uses.
@(private = "file")
job_atlas_prompt :: proc() -> string {
	if n := folder_of(.Atlas); n != "" {
		p := fmt.tprintf("%s/%s", n, ATLAS_PROMPT_FILE)
		if path_kind(p) == .File do return p
	}
	if p := agent_prompt_path(); p != "" && path_kind(p) == .File do return p
	return ""
}

@(private = "file")
job_preamble :: proc(j: ^Job, scheduled: i64) -> string {
	return fmt.tprintf(`# Deckhand job run

- You are job "%s" (id %s), scheduled for %s, running unattended: nobody can answer questions, so do not ask any.
- This scheduled prompt cannot approve risky actions: a blocked action stays blocked. Do not work around it; list it under "## Needs you".
- You cannot create or edit jobs. To propose one, describe it under "## Needs you".
- Never write to protected paths: .git, .pi/, AGENTS.md, CLAUDE.md, shell rc files, and Deckhand's jobs and atlas folders.
- Your access: %s.
- End your answer with "## Summary" (its first line: a one-line headline) and, only if something needs the user, "## Needs you" with one item per line.
`, j.def.name, j.def.id, iso_local(scheduled), j.def.access == .Full ? "full (pi's normal guardrails)" : "read-only (PI_KIT_READONLY)")
}

// Starts a run of j for the tick `scheduled`. "" = started (or recorded
// as folder_missing); else why it could not start at all.
@(private = "file")
job_start :: proc(j: ^Job, scheduled: i64) -> string {
	if home_root == "" do return "no data folder"
	if !job_id_valid(j.def.id) do return "bad id"
	jd := job_data_dir(j.def.id)
	mkdir_private(fmt.tprintf("%s/runs", jd))
	mkdir_private(fmt.tprintf("%s/sessions", jd))
	now := jobs_now()
	// the run folder: UTC stamp + a counter
	utc := time.unix(now, 0)
	y, mo, d := time.date(utc)
	h, mi, s := time.clock(utc)
	sched.run_seq += 1
	name := fmt.tprintf("%04d%02d%02dT%02d%02d%02dZ-%d", y, int(mo), d, h, mi, s, sched.run_seq)
	dir := fmt.tprintf("%s/runs/%s", jd, name)
	mkdir_private(dir)
	r := new(Job_Run)
	r.job_id = strings.clone(j.def.id)
	r.name = strings.clone(name)
	r.dir = strings.clone(dir)
	r.cwd = strings.clone(j.def.folder)
	r.scheduled_at = scheduled
	r.started = now
	r.lock_fd = -1
	l := state.settings.job_limits
	r.max_cost = j.def.max_cost > 0 ? j.def.max_cost : l.max_cost
	r.max_turns = j.def.max_turns > 0 ? j.def.max_turns : l.max_turns
	r.timeout = j.def.timeout > 0 ? j.def.timeout : l.timeout
	r.loop_calls = limit_loop()
	r.stall = limit_stall()
	sched.dirty = true
	// the folder must be there (§3.5): else folder_missing, paused, history kept
	if !os.is_dir(j.def.folder) {
		r.spawn_error = strings.clone("folder_missing")
		r.exit_code = -1
		j.run = r
		sched_log("%s: folder missing: %s", j.def.id, j.def.folder)
		job_finish(r)
		return ""
	}
	r.lock_fd = run_lock(fmt.tprintf("%s/run.lock", jd))
	if r.lock_fd < 0 {
		run_free(r)
		os.remove(dir)
		job_skip(j, scheduled, "previous run still going")
		return ""
	}
	pi := job_pi_path()
	if j.def.access == .Read && pi_readonly_too_old() {
		// its read-only flags would not hold on this pi: never started
		r.spawn_error = strings.clone(PI_READONLY_JOB_TOO_OLD)
		r.exit_code = -1
		j.run = r
		sched_log("%s: %s (pi %s)", j.def.id, PI_READONLY_JOB_TOO_OLD, state.reload.pi_version)
		job_finish(r)
		return ""
	}
	preamble := fmt.tprintf("%s/preamble.md", dir)
	_ = os.write_entire_file(preamble, transmute([]u8)job_preamble(j, scheduled))
	argv := job_argv(pi, fmt.tprintf("%s/sessions", jd), new_uuid(), j.def.model, job_atlas_prompt(), preamble, j.def.prompt, j.def.access)
	env := make([dynamic]string, context.temp_allocator)
	for k in ([]string{"HOME", "USER", "LANG", "TMPDIR", "PI_CODING_AGENT_DIR"}) {
		if v := os.get_env(k, context.temp_allocator); v != "" do append(&env, fmt.tprintf("%s=%s", k, v)) // env-read-ok: k from the literal list above
	}
	append(&env, fmt.tprintf("PATH=%s", jobs_env_path()))
	if n := notes_env_job(); n != "" do append(&env, n) // the user's own, else the main folder (folders.odin)
	if j.def.access == .Read do append(&env, "PI_KIT_READONLY=1")
	append(&env, fmt.tprintf("PI_DESK_JOB=%s", j.def.id), fmt.tprintf("PI_DESK_RUN=%s", name), fmt.tprintf("PI_DESK_RUN_DIR=%s", dir), fmt.tprintf("PI_DESK_SCHEDULED_AT=%s", iso_local(scheduled)))
	if pi == "" || !run_spawn(r, argv[:], env[:], j.def.folder, fmt.tprintf("%s/stderr.log", dir)) {
		r.spawn_error = strings.clone(pi == "" ? JOBS_NEED_PI : "could not start pi")
		r.exit_code = -1
		j.run = r
		job_finish(r)
		return ""
	}
	j.run = r
	jobs_running_changed()
	sched_log("%s: started %s (scheduled %s)", j.def.id, name, local_stamp(scheduled))
	return ""
}

// pi's command line for a run (temp allocator). The prompt comes after
// `--`, so it is never read as an option; pi still reads an argument
// starting with "@" there as a file to attach, so such a prompt starts with
// a newline. Read jobs get pi's built-in read tools only and no MCP tools
// (PI_READONLY_ARGS, as read-only chats), on top of PI_KIT_READONLY.
job_argv :: proc(pi, session_dir, session_id, model, atlas_prompt, preamble, prompt: string, access: Job_Access) -> []string {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, pi, "--mode", "json", "--session-dir", session_dir, "--session-id", session_id)
	if model != "" do append(&argv, "--model", model)
	if access == .Read {
		ro := PI_READONLY_ARGS
		append(&argv, ..ro[:])
	}
	if atlas_prompt != "" do append(&argv, "--append-system-prompt", atlas_prompt)
	append(&argv, "--append-system-prompt", preamble, "--", strings.has_prefix(prompt, "@") ? strings.concatenate({"\n", prompt}, context.temp_allocator) : prompt)
	return argv[:]
}

// ---- finishing a run ----

@(private = "file")
job_finish :: proc(r: ^Job_Run) {
	j: ^Job
	for x in sched.jobs do if x.run == r do j = x
	if j == nil do return // already recorded (quit): a late Job_Run_Done
	// a stopped run: whatever of its tree is left gets SIGKILL now, even if
	// pi itself exited on SIGTERM (children may ignore it)
	sync.lock(&r.mu)
	finish_kill := r.stop != .None && !r.killed
	sync.unlock(&r.mu)
	if finish_kill do run_kill(r)
	if r.th != nil {
		thread.join(r.th)
		thread.destroy(r.th)
		r.th = nil
	}
	now := jobs_now()
	sync.lock(&r.mu)
	stop, exit_code := r.stop, r.exit_code
	final := strings.clone(r.final_text, context.temp_allocator)
	err_text := strings.clone(r.error_text, context.temp_allocator)
	cost, turns, tokens := r.cost, r.turns, r.tokens
	blocked := slice.clone(r.blocked[:], context.temp_allocator)
	sync.unlock(&r.mu)

	rep := job_report(final)
	status := "ok"
	switch {
	case r.spawn_error == "folder_missing": status = "folder_missing"
	case r.spawn_error != "":               status = "failed"
	case stop == .Looping:                  status = "looping"
	case stop == .Stalled:                  status = "stalled"
	case stop == .Over_Limit:               status = "over_limit"
	case stop == .Timeout:                  status = "timeout"
	case stop == .User:                     status = "failed"
	case stop == .Quit:                     status = "stopped (quit)"
	case exit_code != 0 || err_text != "":  status = "failed"
	case len(blocked) > 0 || len(rep.needs_you) > 0: status = "needs_you"
	}
	headline := one_line(redact_secrets(rep.headline), context.temp_allocator)
	switch status {
	case "folder_missing": headline = fmt.tprintf("folder missing: %s", fs_display(j.def.folder))
	case "looping":        headline = fmt.tprintf("stopped: the same tool call %d times in a row", r.loop_calls)
	case "stalled":        headline = fmt.tprintf("stopped: no event from pi for %s", dur_text(r.stall))
	case "over_limit":     headline = "stopped: over a per-run limit (cost or turns)"
	case "timeout":        headline = fmt.tprintf("stopped: over its timeout (%s)", dur_text(r.timeout))
	case "stopped (quit)": headline = "stopped: Deckhand quit"
	case "failed":
		if stop == .User do headline = "stopped by the user"
		else if r.spawn_error != "" do headline = r.spawn_error
		else if err_text != "" do headline = one_line(redact_secrets(err_text), context.temp_allocator)
		else if final == "" do headline = fmt.tprintf("pi exited with %d", exit_code)
	}
	headline = cut_utf8(headline, 200)
	needs := make([dynamic]string, context.temp_allocator)
	for n in rep.needs_you do append(&needs, one_line(redact_secrets(n), context.temp_allocator))
	for b in blocked do append(&needs, fmt.tprintf("blocked: %s `%s` in %s", b.tool, one_line(redact_secrets(b.command), context.temp_allocator), fs_display(b.cwd)))

	// summary.md (redacted)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "# %s — %s\n\nScheduled %s · started %s · %s", j.def.name, status, local_stamp(r.scheduled_at), local_stamp(r.started), dur_text(now - r.started))
	if cost > 0 do fmt.sbprintf(&sb, " · $%.2f", cost)
	strings.write_string(&sb, "\n\n## Summary\n")
	if !rep.has_summary && final != "" do strings.write_string(&sb, "(no summary section: the last message)\n\n")
	strings.write_string(&sb, final != "" ? redact_secrets(rep.summary) : headline)
	strings.write_string(&sb, "\n")
	if len(needs) > 0 {
		strings.write_string(&sb, "\n## Needs you\n")
		for n in needs do fmt.sbprintf(&sb, "- %s\n", n)
	}
	summary_path := fmt.tprintf("%s/summary.md", r.dir)
	_ = os.write_entire_file(summary_path, transmute([]u8)strings.to_string(sb))
	os.chmod(summary_path, {.Read_User, .Write_User})

	delivered := j.def.notify != .Never && status != "quiet" && status != "unchanged"
	// meta.json
	mb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&mb, `{{"v":1,"job":`)
	json_quote(&mb, j.def.id)
	fmt.sbprintf(&mb, `,"status":"%s","scheduled_at":%d,"started":%d,"ended":%d,"exit":%d,"cost":%f,"turns":%d,"tokens":%d,"no_summary":%v,"delivered":%v,"read":%v,"headline":`, status, r.scheduled_at, r.started, now, exit_code, cost, turns, tokens, !rep.has_summary, delivered, !delivered)
	json_quote(&mb, headline)
	strings.write_string(&mb, `,"needs_you":[`)
	for n, i in needs {
		if i > 0 do strings.write_byte(&mb, ',')
		json_quote(&mb, n)
	}
	strings.write_string(&mb, `],"blocked":[`)
	for b, i in blocked {
		if i > 0 do strings.write_byte(&mb, ',')
		strings.write_string(&mb, `{"tool":`)
		json_quote(&mb, b.tool)
		strings.write_string(&mb, `,"command":`)
		json_quote(&mb, redact_secrets(b.command))
		strings.write_string(&mb, `,"cwd":`)
		json_quote(&mb, b.cwd)
		strings.write_string(&mb, `,"sha256":`)
		json_quote(&mb, b.sha256)
		strings.write_byte(&mb, '}')
	}
	strings.write_string(&mb, "]}\n")
	write_atomic(fmt.tprintf("%s/meta.json", r.dir), strings.to_string(mb))

	// the record: state, the note's line
	icon := job_status_icon(status)
	line := fmt.tprintf("- %s %s %s %s", local_stamp(r.scheduled_at), icon, status, dur_text(now - r.started))
	if cost > 0 do line = fmt.tprintf("%s $%.2f", line, cost)
	line = fmt.tprintf("%s — %s · [run](file://%s)", line, headline, summary_path)
	job_add_line(j, line)
	set_str(&j.last_status, status)
	set_str(&j.last_headline, headline)
	set_str(&j.last_run, r.name)
	for n in j.needs_you do delete(n)
	clear(&j.needs_you)
	for n in needs do append(&j.needs_you, strings.clone(n))
	j.last_end = now
	if j.def.schedule.kind == .Every do j.next_due = now + j.def.schedule.every
	if cost > 0 do append(&sched.ledger, Spent{now, cost})
	// the failure streak and auto-pause (§4.5)
	nudge := false
	switch {
	case job_failure(status):
		j.failures += 1
		if j.failures >= limit_fail() && !j.paused {
			job_pause(j, fmt.tprintf("%d failures in a row", j.failures))
			nudge = true
		}
	case status == "folder_missing":
		job_pause(j, fmt.tprintf("folder missing: %s", fs_display(j.def.folder)))
	case status == "ok" || status == "needs_you" || status == "quiet":
		j.failures = 0
	}
	job_save(j)
	sched_log("%s: %s %s (exit %d, $%.2f, %d turns)", j.def.id, r.name, status, exit_code, cost, turns)
	scheduled_at := r.scheduled_at
	j.run = nil
	run_free(r)
	jobs_running_changed()
	job_retention(j)

	jobs_deliver(j, Job_Event{job = j.def.id, title = j.def.name, status = status, headline = headline, run = j.last_run, run_dir = fmt.tprintf("%s/runs/%s", job_data_dir(j.def.id), j.last_run), summary_path = summary_path, scheduled_at = scheduled_at, needs_you = needs[:], unread = delivered}, nudge)
	if j.gone {
		for x, i in sched.jobs do if x == j {
			ordered_remove(&sched.jobs, i)
			break
		}
		job_drop(j)
	}
	sched.dirty = true
	jobs_dequeue()
}

// How many runs go: the timer's pace, and no App Nap while any does.
@(private = "file")
jobs_running_changed :: proc() {
	n := 0
	for j in sched.jobs do if j.run != nil do n += 1
	sync.atomic_store(&sched.running, n)
	platform_activity(n > 0)
}

// Delivery (§7), all in one place: the Jobs tab's unread marker, the
// job.finished event, the bell (notify_job_finished: job id, title, status,
// one-line summary, run folder; the bell sends the OS notification for runs
// that need the user or failed, paced) and pi-desk's own OS notification
// for what the bell does not notify (a finished run with `notify: always`,
// the auto-pause nudge, anything while the bell's Jobs group is off). Never
// a notice to Atlas. Nothing but the event and the record at quit.
@(private = "file")
jobs_deliver :: proc(j: ^Job, e: Job_Event, nudge: bool) {
	if e.unread do append(&j.unread, strings.clone(e.run))
	emit_event(e)
	if sched.quitting do return
	attention := e.status != "ok" && e.status != "quiet" && e.status != "unchanged"
	push := j.def.notify == .Always || (j.def.notify == .Attention && attention)
	bell := j.def.notify != .Never && .Jobs not_in state.settings.bell_off
	if bell {
		st := Job_Status.Finished
		if e.status == "needs_you" do st = .Needs_You
		else if attention do st = .Failed
		notify_job_finished({job_id = e.job, title = e.title, status = st, summary = e.headline, run_dir = e.run_dir})
	}
	if push && (!bell || !attention) do jobs_notify(fmt.tprintf("%s: %s", e.title, e.status), e.headline, attention)
	if nudge do jobs_notify(fmt.tprintf("%s is paused", e.title), fmt.tprintf("%d failures in a row. Resume it in the Jobs tab.", j.failures), true)
}

// Runs older than RUNS_KEEP_DAYS or beyond the newest RUNS_KEEP go (§3.5).
@(private = "file")
job_retention :: proc(j: ^Job) {
	runs, err := os.read_all_directory_by_path(fmt.tprintf("%s/runs", job_data_dir(j.def.id)), context.temp_allocator)
	if err != nil do return
	slice.sort_by(runs, proc(a, b: os.File_Info) -> bool {return a.name > b.name}) // newest first (UTC stamps)
	cut := time.time_add(time.now(), -RUNS_KEEP_DAYS * 24 * time.Hour)
	for r, i in runs {
		if r.type != .Directory do continue
		if i < RUNS_KEEP && time.diff(cut, r.modification_time) > 0 do continue
		os.remove_all(r.fullpath)
		for u, k in j.unread do if u == r.name {
			delete(u)
			ordered_remove(&j.unread, k)
			break
		}
	}
	// pi's sessions of the runs: the same rule (newest first by time)
	ses, serr := os.read_all_directory_by_path(fmt.tprintf("%s/sessions", job_data_dir(j.def.id)), context.temp_allocator)
	if serr != nil do return
	slice.sort_by(ses, proc(a, b: os.File_Info) -> bool {return time.diff(a.modification_time, b.modification_time) < 0})
	for e, i in ses {
		if i < RUNS_KEEP && time.diff(cut, e.modification_time) > 0 do continue
		if e.type == .Directory do os.remove_all(e.fullpath)
		else do os.remove(e.fullpath)
	}
}

// Marks runs read (run "" = all); how many changed.
@(private = "file")
job_mark_read :: proc(j: ^Job, run: string) -> int {
	n := 0
	for i := len(j.unread) - 1; i >= 0; i -= 1 {
		name := j.unread[i]
		if run != "" && name != run do continue
		p := fmt.tprintf("%s/runs/%s/meta.json", job_data_dir(j.def.id), name)
		if data, err := os.read_entire_file(p, context.temp_allocator); err == nil {
			text, _ := strings.replace(string(data), `"read":false`, `"read":true`, 1, context.temp_allocator)
			write_atomic(p, text)
		}
		delete(name)
		ordered_remove(&j.unread, i)
		n += 1
	}
	if n > 0 do sched.dirty = true
	return n
}

// A macOS notification while pi-desk is in the background: attention
// (needs you, failures, safety stops) always, others at most one per 5 s.
@(private = "file")
jobs_notify :: proc(title, body: string, urgent: bool) {
	if platform.notify == nil do return
	if platform.window_active != nil && platform.window_active() do return
	if !urgent && sched.last_notify != {} && time.tick_since(sched.last_notify) < NOTIFY_GAP do return
	sched.last_notify = time.tick_now()
	state.jobs_notified += 1
	platform.notify(title, body)
}

// ---- creating a job (a draft) ----

// Writes a template note (enabled: true) in the jobs folder;
// returns its path. Never over an existing file.
job_create :: proc(name_, schedule_, prompt_, folder_: string, for_project_ := "") -> (string, string) {
	notes := folder_of(.Jobs)
	if notes == "" do return "", "no main folder (Set up Deckhand…, in the Jobs tab)"
	// the owner: its for_project value, and its folder when none is given
	for_project, owner_folder, oerr := job_owner_for_create(one_line(for_project_, context.temp_allocator))
	if oerr != "" do return "", oerr
	name := strings.trim_space(one_line(name_, context.temp_allocator))
	if name == "" do name = "New job"
	name = cut_utf8(name, 80)
	schedule := strings.trim_space(schedule_) != "" ? strings.trim_space(one_line(schedule_, context.temp_allocator)) : "manual"
	if _, err := schedule_parse(schedule); err != "" do return "", fmt.tprintf("schedule: %s", err)
	prompt := strings.trim_space(prompt_) != "" ? strings.trim_space(prompt_) : "Describe what this job should do, and what its summary should say."
	folder := strings.trim_space(one_line(folder_, context.temp_allocator))
	if folder == "" do folder = owner_folder
	if folder == "" do folder = "~"
	if folder != "~" && !strings.has_prefix(folder, "~/") && !strings.has_prefix(folder, "/") do return "", "folder: an absolute path or ~/…"
	// a prompt cannot end the Prompt section early
	for l in strings.split_lines(prompt, context.temp_allocator) do if n := strings.trim_space(strings.trim_prefix(l, "## ")); strings.has_prefix(l, "## ") && known_section_name(n) do return "", "the prompt cannot contain a ## Prompt, ## Check or ## Recent runs heading"
	id, date := job_new_id_date()
	text := job_template(id, name, schedule, prompt, folder, date, for_project)
	path, err := job_note_write_new(name, text)
	if err == "" do sched_log("%s: draft created (%s)", id, path)
	return path, err
}

// A fresh id and today's date for a new note.
job_new_id_date :: proc() -> (id, date: string) {
	id_bytes: [3]u8
	for &b in id_bytes do b = u8(rand.uint32())
	id = fmt.tprintf("%02x%02x%02x", id_bytes[0], id_bytes[1], id_bytes[2])
	c, _ := unix_to_local(jobs_now())
	date = fmt.tprintf("%04d-%02d-%02d", c.year, c.month, c.day)
	return
}

// Writes a new note in the jobs folder, its file named after name, never
// over an existing file; returns its path (temp).
job_note_write_new :: proc(name, text: string) -> (string, string) {
	dir := folder_of(.Jobs)
	if dir == "" do return "", "no main folder (Set up Deckhand…, in the Jobs tab)"
	os.make_directory_all(dir)
	slug := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(name, context.temp_allocator) {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'): strings.write_rune(&slug, r)
		case strings.builder_len(slug) > 0 && !strings.has_suffix(strings.to_string(slug), "-"): strings.write_byte(&slug, '-')
		}
		if strings.builder_len(slug) >= 40 do break
	}
	base := strings.trim_right(strings.to_string(slug), "-")
	if base == "" do base = "job"
	for n in 1 ..< 100 {
		path := n == 1 ? fmt.tprintf("%s/%s.md", dir, base) : fmt.tprintf("%s/%s-%d.md", dir, base, n)
		f, err := os.open(path, {.Write, .Create, .Excl}, os.perm_number(0o644))
		if err != nil {
			if os.exists(path) do continue
			return "", fmt.tprintf("could not create %s: %v", fs_display(path), err)
		}
		_, werr := os.write_string(f, text)
		os.close(f)
		if werr != nil do return "", fmt.tprintf("could not write %s: %v", fs_display(path), werr)
		return strings.clone(path, context.temp_allocator), ""
	}
	return "", "too many notes with that name"
}

// The job sheet's Create and Save (user only): text is the whole note.
// path "" = a new note, written enabled: true, with an id no other job
// has. Else the job note at path is rewritten (its id stays). The text
// must parse.
// Job_Save's refusal when the note changed since the edit started (the
// sheet shows Reload for it).
JOB_NOTE_STALE :: "the note changed on disk since you opened it"

// A note's text as Job_Save's based_on names it.
job_note_hash :: proc(text: string) -> string {
	return fmt.tprintf("%016x", hash.fnv64a(transmute([]u8)text))
}

job_note_save :: proc(path, text_: string, based_on := "") -> (string, string) {
	if folder_of(.Jobs) == "" do return "", "no main folder (Set up Deckhand…, in the Jobs tab)"
	if len(text_) > JOB_NOTE_MAX do return "", "the note is too long"
	text := text_
	if path == "" {
		text = job_note_set_enabled(text, true)
		if text == "" do return "", "no frontmatter (the note must start with ---)"
	}
	d := job_parse(text, path != "" ? path : fmt.tprintf("%s/new.md", folder_of(.Jobs)), context.temp_allocator)
	if d.err != "" do return "", d.err
	if path == "" {
		for j in sched.jobs do if !j.gone && j.def.id == d.id do return "", fmt.tprintf("id: %s is another job's (give this one its own)", d.id)
		p, err := job_note_write_new(d.name, text)
		if err == "" do sched_log("%s: draft created in the job sheet (%s)", d.id, p)
		return p, err
	}
	var_j: ^Job
	// (the scan's paths are real ones: /private/var/… for /var/…)
	want := real_path(path)
	for j in sched.jobs do if !j.gone && (j.path == path || real_path(j.path) == want) do var_j = j
	if var_j == nil do return "", "no such job note"
	if var_j.def.id != "" && d.id != var_j.def.id do return "", fmt.tprintf("id: keep %s (the job's history follows its id)", var_j.def.id)
	// the edit started from the note as it is now (a run's Recent runs, another
	// editor may have written it since); checked here, on the main thread
	if based_on == "" do return "", "based_on: the hash of the note the edit started from"
	now, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return "", fmt.tprintf("could not read %s", fs_display(path))
	if job_note_hash(string(now)) != based_on do return "", JOB_NOTE_STALE
	// temp file + rename, with the note's own mode (write_atomic makes 0600)
	slash := strings.last_index_byte(path, '/')
	tmp := fmt.tprintf("%s/.%s.pi-desk-%d", path[:max(slash, 0)], path[slash + 1:], posix.getpid())
	if err := write_atomic(tmp, text); err != "" do return "", fmt.tprintf("could not write %s: %s", fs_display(path), err)
	if fi, serr := os.stat(path, context.temp_allocator); serr == nil do os.chmod(tmp, fi.mode & os.Permissions_All)
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return "", fmt.tprintf("could not write %s", fs_display(path))
	}
	sched_log("%s: note saved in the job sheet", d.id)
	return strings.clone(path, context.temp_allocator), ""
}

@(private = "file")
known_section_name :: proc(n: string) -> bool {
	return strings.equal_fold(n, "prompt") || strings.equal_fold(n, "check") || strings.equal_fold(n, "recent runs")
}

// ---- the login shell's PATH and notes folder (once) ----

@(private = "file")
jobs_env_start :: proc() {
	// test mode never reads the user's shell. Every start: the user's
	// PI_KIT_NOTES_DIR may have changed (it wins over the main folder).
	// Unit tests never read it either; they send Jobs_Env themselves.
	if autotest.active {
		sched.env_known = true
		return
	}
	if ODIN_TEST do return
	thread.run(proc() {
		shell := os.get_env("SHELL", context.temp_allocator)
		if shell == "" do shell = "/bin/zsh"
		out, ok := run_bounded("", shell_script_argv(shell, `printf '%s\n%s' "$PATH" "$PI_KIT_NOTES_DIR"`, "sh")[:], 10 * time.Second) // fish and co.: /bin/sh
		if !ok do return
		path, _, notes := strings.partition(strings.trim_right(out, "\n"), "\n")
		inbox_submit(Jobs_Env{path = strings.clone(path), notes = strings.clone(strings.trim_space(notes)), login = true}, {kind = .Internal})
	})
}

// ---- State: the rows ----

// Rebuilds State.jobs from the scheduler; true when they changed.
jobs_rows_build :: proc() -> bool {
	before := jobs_rows_json(state.jobs[:], context.temp_allocator)
	before_unread := state.jobs_unread
	jobs_rows_free()
	unread := 0
	for j in sched.jobs {
		if j.gone && j.run == nil do continue
		d := j.def
		row := Job_Row {
			id            = strings.clone(d.id),
			name          = strings.clone(d.name),
			path          = strings.clone(j.path),
			project       = strings.clone(d.for_project),
			folder        = strings.clone(d.folder),
			schedule      = strings.clone(d.sched_text),
			enabled       = job_enabled(j),
			paused        = j.paused,
			paused_why    = strings.clone(j.paused_why),
			running       = j.run != nil,
			queued        = j.queued,
			err           = strings.clone(d.err != "" ? d.err : j.dup_of),
			next_due      = j.next_due,
			last_at       = j.last_end,
			last_status   = strings.clone(j.last_status),
			last_headline = strings.clone(j.last_headline),
			last_run      = strings.clone(j.last_run),
			unread        = len(j.unread),
		}
		for w in d.warnings do append(&row.warnings, strings.clone(w))
		for l in j.recent do append(&row.recent, strings.clone(l))
		for l in j.needs_you do append(&row.needs_you, strings.clone(l))
		unread += row.unread
		append(&state.jobs, row)
	}
	state.jobs_unread = unread
	return jobs_rows_json(state.jobs[:], context.temp_allocator) != before || unread != before_unread
}

jobs_rows_free_all :: proc() {jobs_rows_free()}

@(private = "file")
jobs_rows_free :: proc() {
	for &r in state.jobs {
		delete(r.id)
		delete(r.name)
		delete(r.path)
		delete(r.project)
		delete(r.folder)
		delete(r.schedule)
		delete(r.paused_why)
		delete(r.err)
		delete(r.last_status)
		delete(r.last_headline)
		delete(r.last_run)
		for l in r.warnings do delete(l)
		delete(r.warnings)
		for l in r.recent do delete(l)
		delete(r.recent)
		for l in r.needs_you do delete(l)
		delete(r.needs_you)
	}
	clear(&state.jobs)
}

// The rows as JSON (state snapshot, job_list).
jobs_rows_json :: proc(rows: []Job_Row, allocator: runtime.Allocator) -> string {
	b := strings.builder_make(allocator)
	write_job_rows(&b, rows, false)
	return strings.to_string(b)
}

write_job_rows :: proc(b: ^strings.Builder, rows: []Job_Row, only_unread: bool) {
	strings.write_byte(b, '[')
	first := true
	projects := owner_projects()
	for r in rows {
		if only_unread && r.unread == 0 do continue
		if !first do strings.write_byte(b, ',')
		first = false
		s :: proc(b: ^strings.Builder, k, v: string, comma := true) {
			if comma do strings.write_byte(b, ',')
			json_quote(b, k)
			strings.write_byte(b, ':')
			json_quote(b, v)
		}
		l :: proc(b: ^strings.Builder, k: string, v: []string) {
			fmt.sbprintf(b, `,"%s":[`, k)
			for x, i in v {
				if i > 0 do strings.write_byte(b, ',')
				json_quote(b, x)
			}
			strings.write_byte(b, ']')
		}
		strings.write_byte(b, '{')
		s(b, "id", r.id, false)
		s(b, "name", r.name)
		s(b, "path", r.path)
		s(b, "project", r.project)
		s(b, "folder", r.folder)
		// the owner (jobs_owner.odin): project, atlas, chats or other
		o := job_owner_of(r, projects)
		s(b, "owner", JOB_OWNER_NAMES[o.kind])
		s(b, "owner_name", job_owner_label(o))
		s(b, "owner_path", o.path)
		if o.unmatched != "" do s(b, "owner_unmatched", o.unmatched)
		s(b, "schedule", r.schedule)
		fmt.sbprintf(b, `,"enabled":%v,"paused":%v,"running":%v,"queued":%v,"next_due":%d,"last_at":%d,"unread":%d`, r.enabled, r.paused, r.running, r.queued, r.next_due, r.last_at, r.unread)
		s(b, "paused_why", r.paused_why)
		s(b, "error", r.err)
		s(b, "last_status", r.last_status)
		s(b, "last_headline", r.last_headline)
		s(b, "last_run", r.last_run)
		l(b, "warnings", r.warnings[:])
		l(b, "recent", r.recent[:])
		l(b, "needs_you", r.needs_you[:])
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

@(private = "file")
jobs_list_json :: proc(only_unread: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"jobs_dir":`)
	json_quote(&b, folder_of(.Jobs))
	fmt.sbprintf(&b, `,"paused":%v,"unread":%d,"jobs":`, state.settings.jobs_paused, state.jobs_unread)
	write_job_rows(&b, state.jobs[:], only_unread)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// A job's last runs from their meta.json (already redacted), newest first.
@(private = "file")
job_runs_json :: proc(j: ^Job, limit: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"job":`)
	json_quote(&b, j.def.id)
	strings.write_string(&b, `,"runs":[`)
	runs, _ := os.read_all_directory_by_path(fmt.tprintf("%s/runs", job_data_dir(j.def.id)), context.temp_allocator)
	slice.sort_by(runs, proc(a, b: os.File_Info) -> bool {return a.name > b.name})
	n := 0
	for r in runs {
		if n >= limit do break
		data, err := os.read_entire_file(fmt.tprintf("%s/meta.json", r.fullpath), context.temp_allocator)
		if err != nil do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		strings.write_string(&b, `{"run":`)
		json_quote(&b, r.name)
		strings.write_string(&b, `,"summary_path":`)
		json_quote(&b, fmt.tprintf("%s/summary.md", r.fullpath))
		strings.write_string(&b, `,"meta":`)
		strings.write_string(&b, strings.trim_space(string(data)))
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// The job.finished event's JSON.
job_event_json :: proc(e: Job_Event) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"event","event":"job.finished","job":`, PROTOCOL_VERSION)
	json_quote(&b, e.job)
	pairs := [?][2]string{{"title", e.title}, {"status", e.status}, {"headline", e.headline}, {"run", e.run}, {"run_dir", e.run_dir}, {"summary_path", e.summary_path}}
	for p in pairs {
		strings.write_byte(&b, ',')
		json_quote(&b, p[0])
		strings.write_byte(&b, ':')
		json_quote(&b, p[1])
	}
	strings.write_string(&b, `,"scheduled_at":`)
	json_quote(&b, e.scheduled_at > 0 ? iso_local(e.scheduled_at) : "")
	fmt.sbprintf(&b, `,"unread":%v,"needs_you":[`, e.unread)
	for n, i in e.needs_you {
		if i > 0 do strings.write_byte(&b, ',')
		json_quote(&b, n)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// Stops every run (quit): they would outlive pi-desk's records otherwise.
// The watchdog for every run now (tests).
jobs_watch_all :: proc() {
	now := jobs_now()
	for j in sched.jobs do if j.run != nil do run_watch(j.run, now)
}

// Tests: a run's pid and whether its reader has reaped pi.
jobs_run_pid :: proc(id: string) -> (pid: int, reaped: bool) {
	j := job_by_id(id)
	if j == nil || j.run == nil do return 0, true
	sync.lock(&j.run.mu)
	defer sync.unlock(&j.run.mu)
	return int(j.run.pid), j.run.th != nil && thread.is_done(j.run.th)
}

jobs_last_check :: proc() -> i64 {return sched.last_check}

// Every job's folder (temp).
jobs_folders :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for j in sched.jobs do if !j.gone && j.def.folder != "" do append(&out, j.def.folder)
	return out[:]
}

// At startup (the first tick): the approval key file older pi-desk made
// where the Keychain was not used (tests, test mode) goes; approvals were
// removed. The Keychain is never touched (its old item stays until the user
// deletes it in Keychain Access).
jobs_startup :: proc() {
	if home_root == "" do return
	old := fmt.tprintf("%s/jobs/approval.key", home_root)
	if os.exists(old) && os.remove(old) == nil do sched_log("approval key file removed (approvals were removed)")
}

jobs_any_running :: proc() -> bool {
	for j in sched.jobs do if j.run != nil do return true
	return false
}

// Quit: every run's tree gets SIGTERM, a short grace, then SIGKILL; each
// run is recorded "stopped (quit)" (no notifications).
jobs_shutdown :: proc() {
	sync.atomic_store(&sched.stop_timer, true)
	if sched.timer != nil {
		thread.join(sched.timer)
		thread.destroy(sched.timer)
		sched.timer = nil
	}
	runs := make([dynamic]^Job_Run, context.temp_allocator)
	for j in sched.jobs do if j.run != nil do append(&runs, j.run)
	if len(runs) == 0 do return
	sched.quitting = true
	defer sched.quitting = false
	for r in runs do run_stop(r, .Quit)
	ended :: proc(runs: []^Job_Run, ms: int) -> bool {
		for _ in 0 ..< ms / 20 {
			all := true
			for r in runs do if r.th != nil && !thread.is_done(r.th) do all = false
			if all do return true
			time.sleep(20 * time.Millisecond)
		}
		return false
	}
	if !ended(runs[:], 1500) {
		for r in runs do run_kill(r)
		ended(runs[:], 2000)
	}
	for r in runs {
		if r.th != nil && !thread.is_done(r.th) {
			sched_log("%s: %s did not end at quit (pid %d)", r.job_id, r.name, r.pid)
			continue
		}
		job_finish(r)
	}
	run_command(Jobs_Sync{})
}

// Test hooks (autotest): move the scheduler's clock and check at once.
jobs_clock_advance :: proc(seconds: i64) {
	jobs_clock_offset += seconds
	jobs_check(jobs_now())
	if sched.dirty {
		sched.dirty = false
		run_command(Jobs_Sync{})
	}
}

// The next due check runs at the next frame (tests, wake).
jobs_check_soon :: proc() {sched.last_check = 0}


// Forgets every job and the scheduler's memory (tests; nothing on disk changes).
jobs_reset :: proc() {
	for j in sched.jobs {
		if j.run != nil do continue // never in tests
		job_drop(j)
	}
	clear(&sched.jobs)
	delete(sched.notes_seen)
	if sched.log != nil do os.close(sched.log)
	sched = {}
	jobs_clock_offset = 0
}
