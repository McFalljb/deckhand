package core

// A browser's Settings page data (web_settings.odin) and its job sheet's form (web_jobs.odin).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
obj_of :: proc(v: json.Value) -> json.Object {o, _ := v.(json.Object); return o}

@(private = "file")
str_of :: proc(o: json.Object, k: string) -> string {s, _ := o[k].(json.String); return string(s)}

@(private = "file")
bool_of :: proc(o: json.Object, k: string) -> bool {b, _ := o[k].(json.Boolean); return bool(b)}

// webset: every registry row, its value, and whether a browser may change it: the gate's own
// answer (User_Here and the refused commands: no), less the window's own sheets.
@(test)
web_settings_rows :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	core_detach_window()
	defer {
		state = State{}
		core_detach_window()
	}
	state.settings.reduce_motion = true
	state.settings.theme = .Warm
	state.settings.term_text_pt = 16
	v, err := json.parse_string(web_settings_json(), allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := obj_of(v)
	rows, _ := root["settings"].(json.Array)
	testing.expect_value(t, len(rows), len(SETTINGS))
	by := make(map[string]json.Object, context.temp_allocator)
	for r in rows do by[str_of(obj_of(r), "id")] = obj_of(r)
	for s in SETTINGS do testing.expectf(t, s.id in by, "%s sent", s.id)
	testing.expect(t, bool_of(by["reduce_motion"], "value") && bool_of(by["reduce_motion"], "web"), "a browser's switch, on")
	testing.expect_value(t, str_of(by["look"], "value"), "warm")
	n, _ := by["term_text"]["value"].(json.Float)
	testing.expect_value(t, int(n), 16)
	for id in ([]string{"web_access", "web_listen", "web_pair", "machines_reachable", "remote_machines", "claude_skip_permissions", "codex_full_access", "pi_ext_guardrails", "notify_grid", "bell_dock", "machine_add"}) {
		testing.expectf(t, !bool_of(by[id], "web") && bool_of(by[id], "here"), "%s: this Mac's user's only", id)
	}
	for id in ([]string{"control_token", "setup", "shortcuts", "pi_status"}) do testing.expectf(t, !bool_of(by[id], "web"), "%s: not from a browser", id)
	for id in ([]string{"appearance", "keep_sessions", "tidy_projects", "update_checks", "chats_dir", "subfolders", "main_folder", "agent_notify"}) do testing.expectf(t, bool_of(by[id], "web"), "%s: a browser's", id)
	secs, _ := root["sections"].(json.Array)
	testing.expect_value(t, len(secs), len(Setting_Section) - 1) // This project's files are the window's

	// the view command: a browser's only; webset only while its page shows
	testing.expect(t, !run_command(Web_Settings{open = true}, {kind = .UI}).ok, "the window's own page needs no webset")
	out := make([dynamic][2]string, context.temp_allocator)
	web_settings_sections(&out)
	testing.expect_value(t, len(out), 0)
}

// job_draft: the window's form → note, its messages and its next run; the note back into a form.
@(test)
web_job_draft :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	data :: proc(r: Result) -> json.Object {
		v, _ := json.parse_string(r.data, allocator = context.temp_allocator)
		return obj_of(v)
	}
	r := job_draft_apply({op = "write", id = "abc123", date = "2026-11-16", preset = "manual"})
	testing.expect(t, r.ok, "write")
	testing.expect_value(t, str_of(data(r), "err"), "Name: give the job a name")
	r = job_draft_apply({op = "write", id = "abc123", date = "2026-11-16", name = "Triage", preset = "manual"})
	testing.expect_value(t, str_of(data(r), "err"), "Prompt: say what the job should do")
	r = job_draft_apply({op = "write", id = "abc123", date = "2026-11-16", name = "Triage", prompt = "Look.", preset = "daily", at = "25:00"})
	testing.expect_value(t, str_of(data(r), "err"), "At: a time as HH:MM (24 h), e.g. 07:30")
	testing.expect(t, !bool_of(data(r), "next_ok"), "the schedule's line says what is wrong")
	r = job_draft_apply({op = "write", id = "abc123", date = "2026-11-16", name = "Triage", prompt = "Look at the PRs.", preset = "weekdays", at = "07:30", for_project = "none", folder = "~", access = "full", notify = "never"})
	d := data(r)
	text := str_of(d, "text")
	testing.expect_value(t, str_of(d, "err"), "")
	testing.expect(t, bool_of(d, "next_ok") && strings.has_prefix(str_of(d, "next"), "Next run: "), "the next run")
	testing.expect(t, strings.contains(text, "# Triage") && strings.contains(text, "## Prompt\nLook at the PRs.") && strings.contains(text, `schedule: "30 7 * * 1-5"`) && strings.contains(text, "access: full"), "the note")
	// back into the form
	r = job_draft_apply({op = "read", text = text})
	f := obj_of(data(r)["form"])
	testing.expect(t, str_of(f, "name") == "Triage" && str_of(f, "preset") == "weekdays" && str_of(f, "at") == "07:30" && str_of(f, "notify") == "never", "read back")
	r = job_draft_apply({op = "read", text = "no frontmatter"})
	_, null := data(r)["form"].(json.Null)
	testing.expect(t, null && strings.has_prefix(str_of(data(r), "form_err"), "Stays a note: "), "a text that is not a form stays a note")
	// open: no main folder, the window's words; a new one's form and owners
	testing.expect_value(t, job_draft_apply({op = "open"}).error, "no main folder (Set up Deckhand…, in the Jobs tab)")
	state.settings.home_dir = "/nonexistent-deckhand-test"
	r = job_draft_apply({op = "open"})
	testing.expect(t, r.ok, "open")
	f = obj_of(data(r)["form"])
	testing.expect(t, str_of(f, "for_project") == "none" && str_of(f, "preset") == "manual" && str_of(f, "access") == "read", "a new job's form")
	owners, _ := data(r)["owners"].(json.Array)
	testing.expect(t, len(owners) >= 2 && str_of(obj_of(owners[len(owners) - 1]), "value") == "none", "the owners end with None")
	testing.expect_value(t, job_draft_apply({op = "open", job = "nope"}).error, "no such job")
	testing.expect_value(t, job_draft_apply({op = "x"}).error, "op: open, write or read")
}

@(private = "file")
ws_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/dh-webset-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}

// A draft is its caller's only: no command event carries it and commands.log keeps none of it, as
// file_read (a control subscriber may not call job_draft).
@(test)
web_job_draft_not_in_events :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	dir := ws_dir("log")
	event_log_open(dir)
	r := run_command(Job_Draft{op = "write", id = "abc123", date = "2026-11-16", name = "Secret job", prompt = "PROMPT-TEXT-XYZ", preset = "manual"}, {kind = .UI, web = true})
	run_command(Job_Draft{op = "read", text = "---\ntype: job\n---\n# NOTE-TEXT-XYZ\n"}, {kind = .UI, web = true})
	event_log_close()
	testing.expect(t, r.ok && strings.contains(r.data, "PROMPT-TEXT-XYZ"), "its caller has it")
	data, _ := os.read_entire_file(fmt.tprintf("%s/commands.log", dir), context.temp_allocator)
	testing.expectf(t, !strings.contains(string(data), "XYZ") && !strings.contains(string(data), "Secret"), "nothing of it logged: %s", string(data))
}

// webset: built when the page opens and when a section it reads changes, never on a timer (no
// disk work on the main thread while it just shows); a replacement link does not inherit it.
@(test)
web_settings_open_bound :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer {
		state = State{}
		web_settings_reset()
	}
	web_settings_reset()
	web_set_open_for(true, 7)
	out := make([dynamic][2]string, context.temp_allocator)
	web_settings_sections_for(&out, 7)
	testing.expect(t, len(out) == 1 && out[0][0] == WEB_SETTINGS_SECTION, "sent to the link that opened it")
	first := out[0][1]
	builds := web_settings_builds()
	clear(&out)
	web_settings_sections_for(&out, 7)
	testing.expect_value(t, web_settings_builds(), builds) // nothing changed: not built again
	testing.expect_value(t, out[0][1], first)
	// a section it reads changed: built again, and the old one compared before it is freed
	state.settings.reduce_motion = !state.settings.reduce_motion
	clear(&out)
	append(&out, [2]string{"settings", "changed"})
	web_settings_sections_for(&out, 7)
	testing.expect_value(t, web_settings_builds(), builds + 1)
	testing.expect(t, strings.contains(out[1][1], `"id":"reduce_motion"`), "the new build")
	// another link (a takeover): no webset until it opens its own page
	clear(&out)
	web_settings_sections_for(&out, 8)
	testing.expect_value(t, len(out), 0)
}

// job_draft open reads the job's note without following a link put in its place.
@(test)
web_job_draft_no_link :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	dir := ws_dir("link")
	secret := fmt.tprintf("%s/secret.txt", dir)
	_ = os.write_entire_file(secret, transmute([]u8)string("SECRET-BYTES"))
	note := fmt.tprintf("%s/job.md", dir)
	_ = os.symlink(secret, note)
	state.settings.home_dir = dir
	append(&state.jobs, Job_Row{id = "j1", path = note})
	r := job_draft_apply({op = "open", job = "j1"})
	testing.expect(t, !r.ok && !strings.contains(r.data, "SECRET"), "a link is not read")
}
