package main

// Jobs (docs/ATLAS.md §9 step 1, unit acceptance): the flat-YAML subset,
// cron next-due incl. DST, grace window clamps, the note writers for
// `enabled` and `## Recent runs`, approval keys in a note are errors,
// summary/Needs-you extraction and its fallback, redaction; no approvals.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:time"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(private = "file")
NOTE :: `---
type: job
project: atlas                 # notes frontmatter field
date: 2026-11-01
summary: "Morning triage: open PRs"
tags: [job, triage]
id: 7f3a2c
enabled: true
schedule: "0 7 * * 1-5"
hours: "07-22"
model: anthropic/claude-sonnet-4-5
folder: ~/workspace
access: read
touches: [outside, 'private']
notify: attention
# optional limits
max_cost: 0.50
timeout: 20m
max_turns: 40
---
# Morning PR triage

## Prompt
List open PRs that wait on me.

## Output format
(a heading inside the prompt stays in it)

## Check
` + "```sh\ngh pr list\n```" + `

## Recent runs
<!-- written by pi-desk; edits here are overwritten -->
- 2026-11-01 07:00 ✅ ok 1m12s $0.08 — 3 PRs
`

@(private = "file")
parse :: proc(text: string, path := "/n/jobs/triage.md") -> Job_Def {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	return job_parse(text, path, virtual.arena_allocator(&arena)) // leaked in tests
}

@(test)
jobs_note_parse :: proc(t: ^testing.T) {
	d := parse(NOTE)
	testing.expect_value(t, d.err, "")
	testing.expect_value(t, d.id, "7f3a2c")
	testing.expect_value(t, d.name, "Morning PR triage")
	testing.expect_value(t, d.slug, "triage")
	testing.expect(t, d.enabled)
	testing.expect_value(t, d.schedule.kind, Schedule_Kind.Cron)
	testing.expect_value(t, d.hours_from, 7)
	testing.expect_value(t, d.hours_to, 22)
	testing.expect_value(t, d.model, "anthropic/claude-sonnet-4-5")
	testing.expect(t, strings.has_suffix(d.folder, "/workspace") && strings.has_prefix(d.folder, "/"), d.folder)
	testing.expect_value(t, d.access, Job_Access.Read)
	testing.expect_value(t, d.notify, Job_Notify.Attention)
	testing.expect_value(t, len(d.touches), 2)
	testing.expect_value(t, d.touches[1], "private")
	testing.expect_value(t, d.max_cost, 0.5)
	testing.expect_value(t, d.timeout, 20 * 60)
	testing.expect_value(t, d.max_turns, 40)
	testing.expect(t, strings.contains(d.prompt, "List open PRs") && strings.contains(d.prompt, "## Output format"), d.prompt)
	testing.expect_value(t, d.check, "gh pr list")
}

// Approval was never a frontmatter key (it lived in state.json): an
// `approved: true` an agent writes into a note is an unknown key, an error.
@(test)
jobs_note_approval_keys_are_errors :: proc(t: ^testing.T) {
	for k in ([]string{"approved", "approved_hash", "approved_mac", "approved_on", "approval"}) {
		text := strings.concatenate({"---\nid: a1\nenabled: true\nschedule: manual\n", k, ": true\n---\n## Prompt\nhi\n"}, context.temp_allocator)
		d := parse(text)
		testing.expectf(t, strings.contains(d.err, "not a job setting"), "%s: %q", k, d.err)
	}
	// a typo is an error too
	testing.expect(t, parse("---\nid: a1\nschedule: manual\naproved: true\n---\n## Prompt\nhi\n").err != "")
}

@(test)
jobs_note_yaml_errors :: proc(t: ^testing.T) {
	base :: "---\nid: a1\nschedule: manual\n%s\n---\n## Prompt\nhi\n"
	bad := []string{
		"nested:\n  child: 1", // indented
		"list:\n- a", // block list
		"x: {a: 1}", // flow map
		"x: |", // block scalar
		"x: \"never ends", // open quote
		"x: [a, b", // open list
		"x: \"a\" tail", // text after a quote
		"id: again", // twice
		"no colon here",
		"access: workspace", // a later step
		"worktree: true",
		"enabled: yes",
		"notify: sometimes",
		"hours: 7 to 22",
		"folder: relative/path",
	}
	for b in bad {
		text := strings.concatenate({"---\nid: a1\nschedule: manual\n", b, "\n---\n## Prompt\nhi\n"}, context.temp_allocator)
		d := parse(text)
		testing.expectf(t, d.err != "", "accepted: %q", b)
	}
	_ = base
	testing.expect(t, parse("no frontmatter\n## Prompt\nhi").err != "")
	testing.expect(t, parse("---\nid: a1\nschedule: manual\n---\n## Prompt\n\n").err != "", "empty prompt")
	testing.expect(t, parse("---\nschedule: manual\n---\n## Prompt\nhi\n").err != "", "no id")
	testing.expect(t, parse("---\nid: ../x\nschedule: manual\n---\n## Prompt\nhi\n").err != "", "unsafe id")
	ok := parse("---\nid: a1\nschedule: manual\nsummary: 'it''s fine' # c\nstatus: plain value # comment\n---\n## Prompt\nhi\n")
	testing.expect_value(t, ok.err, "")
	testing.expect(t, strings.contains(parse("---\nid: a1\nschedule: manual\nx: 1\n---\n## Prompt\nhi\n").err, "not a job setting"), "unknown keys: errors")
}

@(test)
jobs_note_writers_enabled_and_recent :: proc(t: ^testing.T) {
	a := parse(NOTE)
	b := parse(job_note_set_enabled(NOTE, false))
	testing.expect(t, !b.enabled)
	testing.expect_value(t, b.prompt, a.prompt)
	c := parse(job_note_set_recent(NOTE, {"- 2026-11-02 07:00 ❌ failed 3s — boom"}))
	testing.expect_value(t, c.prompt, a.prompt)
	testing.expect_value(t, c.err, "")
	testing.expect(t, strings.contains(job_note_set_recent(NOTE, {"- new line"}), "- new line"))
	testing.expect(t, !strings.contains(job_note_set_recent(NOTE, {"- new line"}), "3 PRs"))
	// the writer adds the section when it is missing and keeps the rest
	plain := "---\nid: a1\nschedule: manual\n---\n# T\n\n## Prompt\nhi\n"
	out := job_note_set_recent(plain, {"- one"})
	testing.expect(t, strings.has_suffix(out, "## Recent runs\n" + RECENT_MARKER + "\n- one\n"), out)
	testing.expect_value(t, parse(out).prompt, parse(plain).prompt)
	// enabled added when missing
	en := job_note_set_enabled(plain, true)
	testing.expect(t, parse(en).enabled, en)
}

@(private = "file")
with_tz :: proc(tz: cstring) -> cstring {
	old := posix.getenv("TZ")
	posix.setenv("TZ", tz, true)
	posix.tzset()
	return old
}

@(test)
jobs_cron_next_and_dst :: proc(t: ^testing.T) {
	with_tz("America/New_York")
	defer {posix.unsetenv("TZ"); posix.tzset()}
	at :: proc(s: string) -> i64 {v, _ := parse_local_minute(s); return v}
	s, err := schedule_parse("0 7 * * 1-5")
	testing.expect_value(t, err, "")
	// Friday 2026-10-30 08:00 -> Monday 07:00
	testing.expect_value(t, cron_next(s.cron, at("2026-10-30 08:00")), at("2026-11-02 07:00"))
	// spring forward: 2026-03-08 02:30 does not exist -> skipped to the next day
	s2, _ := schedule_parse("30 2 * * *")
	_, exists := parse_local_minute("2026-03-08 02:30")
	testing.expect(t, !exists, "02:30 on the spring-forward day exists?")
	testing.expect_value(t, cron_next(s2.cron, at("2026-03-08 00:00")), at("2026-03-09 02:30"))
	// fall back: 01:30 happens twice on 2026-11-01; it runs once
	s3, _ := schedule_parse("30 1 * * *")
	first := cron_next(s3.cron, at("2026-11-01 00:00"))
	c, _ := unix_to_local(first)
	testing.expect_value(t, c, Civil{2026, 11, 1, 1, 30})
	second := cron_next(s3.cron, first)
	c2, _ := unix_to_local(second)
	testing.expect_value(t, c2, Civil{2026, 11, 2, 1, 30})
	// every 15 minutes through the repeated hour: no minute twice
	s4, _ := schedule_parse("*/15 * * * *")
	seen := make(map[Civil]bool, context.temp_allocator)
	x := at("2026-11-01 00:50")
	for _ in 0 ..< 12 {
		x = cron_next(s4.cron, x)
		cv, _ := unix_to_local(x)
		testing.expectf(t, !seen[cv], "%v twice", cv)
		seen[cv] = true
	}
	// day fields: both restricted = either
	s5, _ := schedule_parse("0 9 1 * 1")
	testing.expect_value(t, cron_next(s5.cron, at("2026-10-31 10:00")), at("2026-11-01 09:00")) // the 1st (a Sunday)
	testing.expect_value(t, cron_next(s5.cron, at("2026-11-01 10:00")), at("2026-11-02 09:00")) // a Monday
	for b in ([]string{"* * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "*/0 * * * *", "every 10s", "at 2026-13-01 09:00", "at tomorrow"}) {
		_, e := schedule_parse(b)
		testing.expectf(t, e != "", "accepted %q", b)
	}
	m, _ := schedule_parse("manual")
	testing.expect_value(t, schedule_next(m, 100, 0), 0)
	ev, _ := schedule_parse("every 30m")
	testing.expect_value(t, schedule_next(ev, 1000, 900), 900 + 1800)
}

@(test)
jobs_grace_window :: proc(t: ^testing.T) {
	ev := Schedule{kind = .Every, every = 30 * 60}
	testing.expect_value(t, grace_window(ev, 0), 15 * 60)
	testing.expect_value(t, grace_window(Schedule{kind = .Every, every = 60}, 0), GRACE_MIN) // clamped up
	testing.expect_value(t, grace_window(Schedule{kind = .Every, every = 86400}, 0), GRACE_MAX) // clamped down
	testing.expect_value(t, grace_window(Schedule{kind = .At}, 0), GRACE_MAX)
	hourly, _ := schedule_parse("0 * * * *")
	testing.expect_value(t, grace_window(hourly, cron_next(hourly.cron, 0)), 30 * 60)
	minutely, _ := schedule_parse("* * * * *")
	testing.expect_value(t, grace_window(minutely, cron_next(minutely.cron, 0)), GRACE_MIN)
	testing.expect(t, in_hours(-1, -1, 0))
}

@(test)
jobs_report :: proc(t: ^testing.T) {
	r := job_report("Some thinking.\n\n## Summary\n3 PRs wait on you (oldest: pi-kit#9)\n- a\n- b\n\n## Needs you\n- Approve `git push` in ~/x\n- none\n")
	testing.expect(t, r.has_summary)
	testing.expect_value(t, r.headline, "3 PRs wait on you (oldest: pi-kit#9)")
	testing.expect_value(t, len(r.needs_you), 1)
	testing.expect_value(t, r.needs_you[0], "Approve `git push` in ~/x")
	n := job_report("## Summary\nAll quiet.\n\n## Needs you\nNothing.\n")
	testing.expect_value(t, len(n.needs_you), 0)
	f := job_report("\n\nJust an answer without sections.\nSecond line.")
	testing.expect(t, !f.has_summary)
	testing.expect_value(t, f.headline, "Just an answer without sections.")
	testing.expect(t, strings.contains(f.summary, "Second line."))
	testing.expect_value(t, job_report("").headline, "(no answer)")
	testing.expect(t, heartbeat_ok("  heartbeat_ok.") && heartbeat_ok("All fine. HEARTBEAT_OK") && !heartbeat_ok("not ok"))
}

@(test)
jobs_redaction :: proc(t: ^testing.T) {
	// The fake keys are put together from pieces, so no source line holds a
	// whole key-shaped string (secret scanners would flag it).
	secrets := []string{
		"sk-" + "ant-api03-" + "ABCDEFGHIJKLMNOPQRSTUVWX",
		"ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789AB",
		"AKIA" + "ABCDEFGHIJKLMNOP",
		"xox" + "b-1234567890-abcdef",
		"AIza" + "SyA-abcdefghijklmnopqrstuvwxyz01234",
		"eyJ" + "hbGciOiJIUzI1NiJ9" + "." + "eyJ" + "zdWIiOiIxMjM0NTY3ODkwIn0" + "." + "abcdefghijklmnop",
	}
	for s in secrets {
		out := redact_secrets(strings.concatenate({"found ", s, " in the log"}, context.temp_allocator))
		testing.expectf(t, !strings.contains(out, s) && strings.contains(out, "[REDACTED"), "%q -> %q", s, out)
		testing.expect(t, strings.has_prefix(out, "found ") && strings.has_suffix(out, " in the log"), out)
	}
	u := redact_secrets("db at postgres://admin:" + "hunter2secret" + "@db.local/x")
	testing.expect_value(t, u, "db at postgres://admin:" + "[REDACTED]" + "@db.local/x")
	a := redact_secrets("set API_KEY=" + "abcdef1234567890xyz now")
	testing.expect(t, !strings.contains(a, "abcdef1234567890xyz") && strings.contains(a, "API_KEY=[REDACTED]"), a)
	pem_begin, pem_end := "-----BEGIN RSA " + "PRIVATE KEY-----", "-----END RSA " + "PRIVATE KEY-----"
	pem := redact_secrets(strings.concatenate({"k:\n", pem_begin, "\nMIIabc\n", pem_end, "\nend"}, context.temp_allocator))
	testing.expect_value(t, pem, "k:\n[REDACTED PRIVATE KEY]\nend")
	plain := "3 PRs wait on you (oldest: pi-kit#9)"
	testing.expect_value(t, redact_secrets(plain), plain)
}

// The job commands' caller rules (§9 step 1). No approvals: a job created
// by an agent (control) is enabled and runs on its schedule; a prompt edited
// in the file runs as edited; job_approve is gone (a clear error).
@(test)
jobs_commands_callers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fmt.aprintf("%s/pd-jobs-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	notes := fmt.aprintf("%s/notes", dir)
	os.make_directory_all(fmt.tprintf("%s/jobs", notes))
	old_root := home_root
	home_root = fmt.aprintf("%s/data", dir)
	os.make_directory_all(home_root)
	jobs_reset()
	saved := state.settings
	state.settings.home_dir = ""
	defer {
		jobs_reset()
		jobs_rows_free_all()
		state.settings = saved
		home_root = old_root
		os.remove_all(dir)
	}
	ui := Caller{kind = .UI}
	ctl := Caller{kind = .Control}
	testing.expect(t, !run_command(Set_Home_Dir{path = notes}, ctl).ok, "set_notes_dir is the user's")
	testing.expect(t, run_command(Set_Home_Dir{path = notes}, ui).ok)
	// control (an agent) creates a job: enabled, nothing to approve
	r := run_command(Job_Create{name = "Morning triage", schedule = "0 7 * * *", prompt = "List PRs."}, ctl)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, strings.contains(r.data, "/jobs/morning-triage.md"), r.data)
	run_command(Jobs_Sync{})
	testing.expect_value(t, len(state.jobs), 1)
	row := state.jobs[0]
	testing.expect(t, row.enabled, "an agent's job is enabled")
	testing.expect_value(t, row.err, "")
	id := strings.clone(row.id, context.temp_allocator)
	// the job list has no approval fields
	jl := run_command(Job_List{}, ctl)
	for k in ([]string{`"approved"`, `"draft"`, `"changed"`, `"diff"`, `"hash"`}) do testing.expectf(t, !strings.contains(jl.data, k), "job_list: no %s", k)
	// job_approve: gone, with a clear error (never a crash or a bare unknown command)
	_, perr := parse_command(`{"type":"job_approve","job":"x"}`, context.temp_allocator)
	testing.expect_value(t, perr, JOB_APPROVE_REMOVED)
	pm, rerr := parse_request(`{"id":"1","v":1,"type":"command","command":{"type":"job_approve","job":"x","hash":"00"}}`, context.temp_allocator)
	testing.expect_value(t, rerr, JOB_APPROVE_REMOVED)
	testing.expect(t, pm.command == nil)
	// a file edit to the prompt: still enabled, runs as edited
	path := strings.clone(state.jobs[0].path, context.temp_allocator)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	edited, _ := strings.replace(string(data), "List PRs.", "List PRs and issues.", 1, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)edited)
	jobs_scan(true)
	run_command(Jobs_Sync{})
	testing.expect(t, state.jobs[0].enabled && state.jobs[0].err == "", "an edited note stays enabled")
	// the controls: Disable (the user's), Pause (anyone)
	testing.expect(t, !run_command(Job_Set_Enabled{job = id, on = false}, ctl).ok, "enable/disable is the user's")
	testing.expect(t, run_command(Job_Set_Enabled{job = id, on = false}, ui).ok)
	run_command(Jobs_Sync{})
	testing.expect(t, !state.jobs[0].enabled)
	rr := run_command(Job_Run_Now{job = id}, ctl)
	testing.expect(t, !rr.ok && strings.contains(rr.error, "disabled"), rr.error)
	testing.expect(t, run_command(Job_Set_Enabled{job = id, on = true}, ui).ok)
	// user-only settings
	testing.expect(t, !run_command(Set_Job_Limits{day = 5}, ctl).ok)
	testing.expect(t, !run_command(Jobs_Resume{}, ctl).ok)
	testing.expect(t, run_command(Jobs_Pause{}, ctl).ok, "anyone may pause")
	testing.expect(t, !run_command(Job_Set_Enabled{job = id, on = true}, ctl).ok)
	// a job's notes may not hold a section heading that ends its prompt early
	testing.expect(t, !run_command(Job_Create{prompt = "x\n## Recent runs\ny"}, ctl).ok)
	// queries: any caller, a pi tab's too
	testing.expect(t, run_command(Job_List{}, Caller{kind = .Panel, tab_id = 1}).ok)
	// the safety stops cannot be turned off
	run_command(Set_Job_Limits{stall = 0, loop_calls = 0, fail_pause = 0}, ui)
	testing.expect(t, limit_stall() >= 1 && limit_loop() >= 2 && limit_fail() >= 1)
}
