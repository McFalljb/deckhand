package main

// Jobs by owner (jobs_owner.odin), the job sheet's note (jobs_form.odin) and
// session info (session_info.odin): owner rules, New job's template per
// owner, form ↔ note round trips, schedule presets, Save keeping Recent runs
// and unknown keys, the session info block from a fixture header.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
HOME_T :: "/Users/tester"

@(private = "file")
OWNER_FIXTURE := [?]core.Owner_Project {
		{id = 1, cwd = "/Users/tester/code/api", name = "", shown = "api"},
		{id = 2, cwd = "/Users/tester/code/api/web", name = "Frontend", shown = "Frontend"},
		{id = 3, cwd = "/Users/tester/code/docs", name = "", shown = "docs"},
		{id = 4, cwd = "/Users/tester/other/docs", name = "", shown = "other/docs"},
		{id = 5, cwd = "/Users/tester/code/old", name = "", shown = "old", hidden = true},
		{id = 6, cwd = "/Users/tester", name = "", shown = "tester"},
		{id = 7, cwd = "/Users/tester/code/apifoo", name = "", shown = "apifoo"},
}

@(test)
jobs_owner_rules :: proc(t: ^testing.T) {
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("HOME", HOME_T)
	defer os.set_env("HOME", old_home)
	ps := OWNER_FIXTURE[:]
	atlas := "/Users/tester/deckhand/atlas"
	chats := "/Users/tester/deckhand/chats"
	r :: proc(fp, folder: string, ps: []core.Owner_Project, atlas, chats: string) -> core.Job_Owner {return core.job_owner_resolve(fp, folder, ps, atlas, chats)}
	// folder inference: the deepest listed project, whole components
	o := r("", "/Users/tester/code/api/web/src", ps, atlas, chats)
	testing.expect_value(t, o.kind, core.Job_Owner_Kind.Project)
	testing.expect_value(t, o.project, 2)
	testing.expect_value(t, r("", "/Users/tester/code/api/lib", ps, atlas, chats).project, 1)
	testing.expect_value(t, r("", "/Users/tester/code/api", ps, atlas, chats).project, 1)
	testing.expect_value(t, r("", "/Users/tester/code/apifoo/x", ps, atlas, chats).project, 7) // not api
	// hidden projects never take a job by folder; home only exactly
	testing.expect_value(t, r("", "/Users/tester/code/old/x", ps, atlas, chats).kind, core.Job_Owner_Kind.Other)
	testing.expect_value(t, r("", "/Users/tester/random", ps, atlas, chats).kind, core.Job_Owner_Kind.Other)
	testing.expect_value(t, r("", "/Users/tester", ps, atlas, chats).project, 6)
	testing.expect_value(t, r("", "/tmp/x", ps, atlas, chats).kind, core.Job_Owner_Kind.Other)
	// Atlas's and the chats folder
	testing.expect_value(t, r("", atlas, ps, atlas, chats).kind, core.Job_Owner_Kind.Atlas)
	testing.expect_value(t, r("", "/Users/tester/deckhand/chats/sub", ps, atlas, chats).kind, core.Job_Owner_Kind.Chats)
	testing.expect_value(t, r("", "/Users/tester/deckhand/atlasx", ps, atlas, chats).kind, core.Job_Owner_Kind.Other)
	testing.expect_value(t, r("", atlas, ps, "", chats).kind, core.Job_Owner_Kind.Other) // no main folder
	// for_project wins over the folder
	testing.expect_value(t, r("atlas", "/Users/tester/code/api", ps, atlas, chats).kind, core.Job_Owner_Kind.Atlas)
	testing.expect_value(t, r("Chats", "/Users/tester/code/api", ps, atlas, chats).kind, core.Job_Owner_Kind.Chats)
	testing.expect_value(t, r("none", "/Users/tester/code/api", ps, atlas, chats).kind, core.Job_Owner_Kind.Other)
	testing.expect_value(t, r("~/code/docs", "/Users/tester/code/api", ps, atlas, chats).project, 3) // by path
	testing.expect_value(t, r("/Users/tester/code/docs/", "/x", ps, atlas, chats).project, 3)
	testing.expect_value(t, r("frontend", "/x", ps, atlas, chats).project, 2) // by its rename, any case
	testing.expect_value(t, r("web", "/x", ps, atlas, chats).project, 2) // by its folder's name
	testing.expect_value(t, r("~/code/old", "/x", ps, atlas, chats).project, 5) // named: hidden ones too
	// a missing project: the folder decides, and the row says so
	o = r("pi-kit", "/Users/tester/code/api/x", ps, atlas, chats)
	testing.expect_value(t, o.kind, core.Job_Owner_Kind.Project)
	testing.expect_value(t, o.project, 1)
	testing.expect_value(t, o.unmatched, "pi-kit")
	o = r("docs", "/tmp", ps, atlas, chats) // two projects named docs: no match
	testing.expect_value(t, o.kind, core.Job_Owner_Kind.Other)
	testing.expect_value(t, o.unmatched, "docs")
	// the row says which: several projects of that name, or none
	testing.expect_value(t, core.job_owner_warning(o), "⚠ for_project: several projects are named docs (use the folder); grouped by its folder")
	o = r("pi-kit", "/x", ps, atlas, chats)
	testing.expect_value(t, core.job_owner_warning(o), "⚠ for_project: pi-kit is not one of your projects; grouped by its folder")
	testing.expect_value(t, core.job_owner_warning(r("web", "/x", ps, atlas, chats)), "")
	testing.expect_value(t, core.path_tilde("/Users/tester/code"), "~/code")
	testing.expect_value(t, core.path_tilde("/Users/testerx"), "/Users/testerx")
}

// The template per owner: for_project and folder written, the note parses
// and resolves to the same owner.
@(test)
jobs_owner_template :: proc(t: ^testing.T) {
	for fp in ([]string{"", "atlas", "chats", "none", "~/code/api"}) {
		text := core.job_template("abc123", "Triage", "manual", "Do it.", fp == "" ? "~" : (fp == "~/code/api" ? fp : "~/x"), "2026-11-01", fp)
		d := core.job_parse(text, "/n/jobs/triage.md", context.temp_allocator)
		testing.expectf(t, d.err == "", "%q: %s", fp, d.err)
		testing.expect_value(t, d.for_project, fp)
		testing.expect_value(t, strings.contains(text, "\nfor_project: "), fp != "")
		testing.expect(t, strings.contains(text, "enabled: true"))
	}
}

// job_create with an owner, the job sheet's Save: needs a main folder.
@(test)
jobs_owner_create_and_save :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fmt.aprintf("%s/pd-owner-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	notes := fmt.aprintf("%s/notes", dir)
	os.make_directory_all(fmt.tprintf("%s/jobs", notes))
	proj := fmt.aprintf("%s/code/api", dir)
	os.make_directory_all(proj)
	old_root := core.home_root
	core.home_root = fmt.aprintf("%s/data", dir)
	os.make_directory_all(core.home_root)
	core.jobs_reset()
	saved := state.settings
	// a fake HOME: setting the main folder rescans pi's store (never the user's)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	fake_home := fmt.aprintf("%s/home", dir)
	os.make_directory_all(fake_home)
	os.set_env("HOME", fake_home)
	defer {
		core.jobs_reset()
		core.jobs_rows_free_all()
		// the rescan's projects live in its arena: leave none behind
		state.projects = {}
		state.settings = saved
		core.home_root = old_root
		os.set_env("HOME", old_home)
		os.remove_all(dir)
	}
	ui := core.Caller{kind = .UI}
	ctl := core.Caller{kind = .Control}
	state.settings.home_dir = ""
	testing.expect(t, core.run_command(core.Set_Home_Dir{path = notes}, ui).ok)
	state.projects = make([dynamic]core.Project, context.temp_allocator)
	append(&state.projects, core.Project{id = 77, cwd = proj, label = "api"})
	cases := [?]struct {
		fp, want_fp, folder_suffix: string,
		kind:                       core.Job_Owner_Kind,
	}{{"atlas", "atlas", "/notes/atlas", .Atlas}, {"chats", "chats", "/notes/chats", .Chats}, {"none", "none", "", .Other}, {"api", "", "/code/api", .Project}, {proj, "", "/code/api", .Project}}
	for c, i in cases {
		r := core.run_command(core.Job_Create{name = fmt.tprintf("job %d", i), prompt = "Check it.", for_project = c.fp}, ctl)
		testing.expectf(t, r.ok, "%s: %s", c.fp, r.error)
		path := strings.clone(r.data[len(`{"path":"`):len(r.data) - 2], context.temp_allocator)
		data, _ := os.read_entire_file(path, context.temp_allocator)
		d := core.job_parse(string(data), path, context.temp_allocator)
		testing.expectf(t, d.err == "", "%s: %s", c.fp, d.err)
		if c.want_fp != "" do testing.expect_value(t, d.for_project, c.want_fp)
		else do testing.expectf(t, strings.has_suffix(d.for_project, "/code/api"), "for_project %q", d.for_project)
		if c.folder_suffix != "" do testing.expectf(t, strings.has_suffix(d.folder, c.folder_suffix), "%s: folder %s", c.fp, d.folder)
		testing.expect_value(t, core.job_owner_resolve(d.for_project, d.folder, core.owner_projects(), core.folder_of(.Atlas), core.folder_of(.Chats)).kind, c.kind)
	}
	testing.expect(t, !core.run_command(core.Job_Create{for_project = "no-such-project"}, ctl).ok, "an unknown project is refused")
	// job_save and job_sheet are the user's
	testing.expect_value(t, core.run_command(core.Job_Save{text = "x"}, ctl).error, "not allowed for this caller")
	testing.expect_value(t, core.run_command(core.Job_Sheet{open = true}, ctl).error, "not allowed for this caller")
	// the sheet's Create: enabled, whatever the text said
	f := Job_Form{name = "Sheet job", for_project = "none", folder = "~", schedule = "every 2h", prompt = "Line one.\nLine two.", access = "full", notify = "attention", max_turns = "40"}
	id, date := core.job_new_id_date()
	text, err := job_form_new_note(f, id, date)
	testing.expect_value(t, err, "")
	testing.expect(t, strings.contains(text, "# Sheet job\n\n## Prompt\nLine one.\nLine two.\n\n## Recent runs"), text)
	text, _ = strings.replace(text, "enabled: true", "enabled: false", 1, context.temp_allocator)
	r := core.run_command(core.Job_Save{text = text}, ui)
	testing.expect(t, r.ok, r.error)
	path := strings.clone(r.data[len(`{"path":"`):len(r.data) - 2], context.temp_allocator)
	// the sheet's keyboard and the Jobs tab are commands (focus_take, focus_release, Job_Save's own
	// layout), not the window's writes: open takes the keyboard, Cancel gives it back, Save
	// gives it back and shows the Jobs tab
	{
		testing.expect(t, core.run_command(core.Job_Sheet{open = true}, ui).ok)
		testing.expect_value(t, state.focus_widget, "job_sheet")
		testing.expect(t, core.run_command(core.Job_Sheet{open = false}, ui).ok)
		testing.expect_value(t, state.focus_widget, "")
		testing.expect(t, core.run_command(core.Job_Sheet{open = true}, ui).ok)
		state.layout.left_open, state.layout.left_tab = false, .Sessions
		id2, date2 := core.job_new_id_date()
		f2 := f
		f2.name = "Sheet job 2"
		text2, _ := job_form_new_note(f2, id2, date2)
		r2 := core.run_command(core.Job_Save{text = text2}, ui)
		testing.expect(t, r2.ok, r2.error)
		testing.expect(t, !job_sheet_open())
		testing.expect_value(t, state.focus_widget, "")
		testing.expect(t, state.layout.left_open)
		testing.expect_value(t, state.layout.left_tab, core.Left_Tab.Jobs)
	}
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, strings.contains(string(data), "enabled: true"), "written enabled")
	testing.expect_value(t, core.run_command(core.Job_Save{text = text}, ui).error, fmt.tprintf("id: %s is another job's (give this one its own)", id))
	// Save: Recent runs and unknown keys stay; the id must stay
	with_runs := core.job_note_set_recent(string(data), {"- 2026-11-01 07:00 ✅ ok — fine"})
	with_runs, _ = strings.replace(with_runs, "notify: attention", "notify: attention\ntouches: [outside]\naliases: [x]", 1, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)with_runs)
	core.jobs_scan(true)
	g, _ := job_form_from_note(with_runs)
	g.prompt = "A new prompt."
	g.schedule = "30 7 * * 1-5"
	g.max_turns = ""
	edited, eerr := job_note_apply_form(with_runs, g)
	testing.expect_value(t, eerr, "")
	// an edit names the text it started from: refused once the file changed since
	testing.expect(t, !core.run_command(core.Job_Save{path = path, text = edited}, ui).ok, "based_on is required")
	r = core.run_command(core.Job_Save{path = path, text = edited, based_on = core.job_note_hash(string(data))}, ui)
	testing.expect_value(t, r.error, core.JOB_NOTE_STALE)
	still, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(still), with_runs) // refused: the file as it was
	os.chmod(path, {.Read_User, .Write_User, .Read_Group, .Read_Other}) // 0644, as an editor leaves it
	r = core.run_command(core.Job_Save{path = path, text = edited, based_on = core.job_note_hash(with_runs)}, ui)
	testing.expect(t, r.ok, r.error)
	if fi, serr := os.stat(path, context.temp_allocator); serr == nil {
		testing.expect_value(t, fi.mode & os.Permissions_All, os.Permissions{.Read_User, .Write_User, .Read_Group, .Read_Other})
	} else do testing.fail_now(t, "stat")
	if ents, derr := os.read_all_directory_by_path(core.folder_of(.Jobs), context.temp_allocator); derr == nil {
		for e in ents do testing.expect(t, !strings.contains(e.name, ".deckhand-") && !strings.contains(e.name, ".tmp-"), e.name) // no temp file left
	}
	data, _ = os.read_entire_file(path, context.temp_allocator)
	s := string(data)
	testing.expect(t, strings.contains(s, "✅ ok — fine"), "Recent runs kept")
	testing.expect(t, strings.contains(s, "touches: [outside]") && strings.contains(s, "aliases: [x]"), "unknown keys kept")
	testing.expect(t, strings.contains(s, "A new prompt.") && !strings.contains(s, "Line two."), "the prompt replaced")
	testing.expect(t, !strings.contains(s, "\nmax_turns:"), "a cleared key goes")
	testing.expect(t, strings.contains(s, `schedule: "30 7 * * 1-5"`), s)
	other, _ := strings.replace(edited, fmt.tprintf("id: %s", id), "id: zzz999", 1, context.temp_allocator)
	testing.expect(t, strings.has_prefix(core.run_command(core.Job_Save{path = path, text = other, based_on = core.job_note_hash(s)}, ui).error, "id: keep"), "the id stays")
	testing.expect(t, !core.run_command(core.Job_Save{path = path, text = "no frontmatter", based_on = core.job_note_hash(s)}, ui).ok, "it must parse")
}

// form → note → form gives the same fields; note text edited → form.
@(test)
jobs_form_round_trip :: proc(t: ^testing.T) {
	f := Job_Form{name = "Morning: triage", for_project = "~/code/api", folder = "~/code/api", schedule = "0 7 * * 1-5", prompt = "List PRs.\n\nOldest first.", access = "read", notify = "never", model = "anthropic/claude-x", hours = "07-22", max_cost = "0.50", timeout = "20m", max_turns = "40"}
	text, err := job_form_new_note(f, "abc123", "2026-11-01")
	testing.expect_value(t, err, "")
	d := core.job_parse(text, "/n/jobs/x.md", context.temp_allocator)
	testing.expect_value(t, d.err, "")
	testing.expect_value(t, d.name, "Morning: triage")
	testing.expect_value(t, d.max_turns, 40)
	g, gerr := job_form_from_note(text)
	testing.expect_value(t, gerr, "")
	testing.expect_value(t, g, f)
	// applying the same form again changes nothing
	again, _ := job_note_apply_form(text, g)
	testing.expect_value(t, again, text)
	// a note edited as text reads back into the form
	edited, _ := strings.replace(text, "notify: never", "notify: always", 1, context.temp_allocator)
	edited, _ = strings.replace(edited, "Oldest first.", "Newest first.", 1, context.temp_allocator)
	h, _ := job_form_from_note(edited)
	testing.expect_value(t, h.notify, "always")
	testing.expect_value(t, h.prompt, "List PRs.\n\nNewest first.")
	// the form refuses a prompt that would end its section
	bad := f
	bad.prompt = "x\n## Recent runs\ny"
	_, berr := job_note_apply_form(text, bad)
	testing.expect(t, berr != "", "a heading in the prompt")
	_, nerr := job_form_from_note("no frontmatter")
	testing.expect(t, nerr != "")
}

@(test)
jobs_form_summary_and_title :: proc(t: ^testing.T) {
	// a summary of its own stays when the form saves (even renamed)
	base := "---\nsummary: Nightly build check of main\nschedule: manual\nfolder: ~\naccess: read\nnotify: always\n---\n\n# Build\n\n## Prompt\nRun it.\n"
	f, ferr := job_form_from_note(base)
	testing.expect_value(t, ferr, "")
	testing.expect_value(t, f.name, "Build")
	same, _ := job_note_apply_form(base, f)
	testing.expect_value(t, same, base)
	f.name = "Build main"
	renamed, _ := job_note_apply_form(base, f)
	testing.expect(t, strings.contains(renamed, "summary: Nightly build check of main\n"), renamed)
	testing.expect(t, strings.contains(renamed, "\n# Build main\n"), renamed)
	// a summary that was the title follows the name
	plain := "---\nsummary: Build\nschedule: manual\nfolder: ~\naccess: read\nnotify: always\n---\n\n# Build\n\n## Prompt\nRun it.\n"
	g, _ := job_form_from_note(plain)
	g.name = "Build main"
	out, _ := job_note_apply_form(plain, g)
	testing.expect(t, strings.contains(out, "summary: Build main\n"), out)
	// the title is a `# ` line before the first `## `; one inside ## Check is not it
	untitled := "---\nsummary: Lint\nschedule: manual\nfolder: ~\naccess: read\nnotify: always\n---\n\n## Prompt\nLint.\n\n## Check\n# exit code\nzero\n"
	h, _ := job_form_from_note(untitled)
	testing.expect_value(t, h.name, "Lint")
	h.name = "Lint all"
	titled, _ := job_note_apply_form(untitled, h)
	testing.expect(t, strings.contains(titled, "## Check\n# exit code\nzero\n"), titled)
	testing.expect(t, strings.contains(titled, "---\n\n# Lint all\n"), titled)
	testing.expect_value(t, strings.count(titled, "# Lint all"), 1)
	// a value that reads as a YAML list item is quoted, and reads back
	testing.expect_value(t, core.yaml_quote("- nightly"), `"- nightly"`)
	h.name = "- nightly"
	h.model = "-x"
	listy, _ := job_note_apply_form(untitled, h)
	back, berr := job_form_from_note(listy)
	testing.expect_value(t, berr, "")
	testing.expect_value(t, back.model, "-x")
	testing.expect(t, strings.contains(listy, "\nsummary: \"- nightly\"\n"), listy)
}

@(test)
jobs_form_presets :: proc(t: ^testing.T) {
	cases := [?]struct {
		p:             Sched_Preset,
		n, at, custom: string,
		want:          string,
	}{{.Manual, "", "", "", "manual"}, {.Hourly, "", "", "", "0 * * * *"}, {.Every_Hours, "3", "", "", "every 3h"}, {.Daily, "", "07:30", "", "30 7 * * *"}, {.Weekdays, "", "18:05", "", "5 18 * * 1-5"}, {.Custom, "", "", " every 45m ", "every 45m"}}
	for c in cases {
		s, err := sched_preset_text(c.p, c.n, c.at, c.custom)
		testing.expect_value(t, err, "")
		testing.expect_value(t, s, c.want)
		_, perr := core.schedule_parse(s)
		testing.expectf(t, perr == "", "%s: %s", s, perr)
		p, n, at := sched_preset_detect(s)
		testing.expect_value(t, p, c.p)
		if c.p == .Every_Hours do testing.expect_value(t, n, c.n)
		if c.p == .Daily || c.p == .Weekdays do testing.expect_value(t, at, c.at)
	}
	_, e1 := sched_preset_text(.Daily, "", "25:00", "")
	testing.expect(t, e1 != "")
	_, e2 := sched_preset_text(.Every_Hours, "0", "", "")
	testing.expect(t, e2 != "")
	p, _, _ := sched_preset_detect("0 7 1 * *")
	testing.expect_value(t, p, Sched_Preset.Custom)
	// what Every N hours cannot write is Custom (the form would refuse it)
	big, _, _ := sched_preset_detect("every 200h")
	testing.expect_value(t, big, Sched_Preset.Custom)
	_, ok := sched_next_text("not a schedule")
	testing.expect(t, !ok)
	line, ok2 := sched_next_text("0 7 * * *")
	testing.expect(t, ok2 && strings.has_prefix(line, "Next run: "), line)
}

// The session info: the header and the file only, never the messages.
@(test)
session_info_from_header :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/pd-sinfo-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/2026-10-30T10-00-00-000Z_demo-1.jsonl", dir)
	body := `{"type":"session","version":3,"id":"demo-1","timestamp":"2026-10-30T10:00:00.000Z","cwd":"/Users/tester/code/demo","provider":"anthropic","modelId":"claude-x"}` + "\n" + `{"type":"message","message":{"role":"user","content":"SECRET CONVERSATION TEXT"}}` + "\n"
	_ = os.write_entire_file(path, transmute([]u8)body)
	f, err := core.session_facts_read(path)
	testing.expect_value(t, err, "")
	testing.expect_value(t, f.id, "demo-1")
	testing.expect_value(t, f.cwd, "/Users/tester/code/demo")
	testing.expect_value(t, f.created, "2026-10-30T10:00:00.000Z")
	testing.expect_value(t, f.model, "anthropic/claude-x")
	testing.expect(t, strings.has_suffix(f.modified, "Z"), f.modified)
	f.project, f.title = "demo", "Fix the ``` demo build"
	text := core.session_info_text(f)
	testing.expect(t, strings.has_prefix(text, "````pi-session\n") && strings.has_suffix(text, "\n````"), text)
	testing.expect(t, strings.contains(text, "\nid: demo-1\n") && strings.contains(text, fmt.tprintf("\nfile: %s\n", path)) && strings.contains(text, "\nfolder: /Users/tester/code/demo\n") && strings.contains(text, "\nproject: demo\n") && strings.contains(text, "\nmodel: anthropic/claude-x\n"), text)
	testing.expect(t, !strings.contains(text, "SECRET"), "never the conversation")
	// a title is the user's words: a secret pasted into it is not passed on
	f.title = "deploy with API_KEY=abcdef1234567890xyz"
	testing.expect(t, !strings.contains(core.session_info_text(f), "abcdef1234567890xyz"), "title redacted")
	// a header without a timestamp: the file name's; no model: no line
	path2 := fmt.tprintf("%s/2026-10-31T08-15-30-000Z_demo-2.jsonl", dir)
	_ = os.write_entire_file(path2, transmute([]u8)string(`{"type":"session","version":3,"id":"demo-2","cwd":"/x"}` + "\n"))
	f2, _ := core.session_facts_read(path2)
	testing.expect_value(t, f2.created, "2026-10-31T08:15:30Z")
	testing.expect(t, !strings.contains(core.session_info_text(f2), "model:"))
	// not a session file
	path3 := fmt.tprintf("%s/x.jsonl", dir)
	_ = os.write_entire_file(path3, transmute([]u8)string(`{"type":"message"}` + "\n"))
	_, e3 := core.session_facts_read(path3)
	testing.expect(t, e3 != "")
}

// The Jobs tab's groups are worked out once per change, not every frame;
// a changed row or project list works them out again.
@(test)
jobs_groups_cached :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_jobs, old_projects := state.jobs, state.projects
	defer {
		state.jobs, state.projects = old_jobs, old_projects
		state.version += 1
	}
	state.projects = {}
	rows := make([dynamic]core.Job_Row, context.temp_allocator)
	append(&rows, core.Job_Row{id = "a", name = "A", project = "none", folder = "/x"}, core.Job_Row{id = "b", name = "B", project = "chats", folder = "/y"})
	state.jobs = rows
	state.version += 1
	g1 := core.jobs_groups()
	g2 := core.jobs_groups()
	testing.expect_value(t, len(g1), 2)
	testing.expect(t, raw_data(g1) == raw_data(g2), "the same groups while nothing changed")
	testing.expect_value(t, g1[0].owner.kind, core.Job_Owner_Kind.Chats)
	// a row's owner changed (a rescan)
	state.jobs[1].project = "none"
	g3 := core.jobs_groups()
	testing.expect_value(t, len(g3), 1)
	testing.expect_value(t, len(g3[0].rows), 2)
}
