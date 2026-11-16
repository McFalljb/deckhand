package core

// A browser's job sheet (#148, web/src/app/JobSheet.tsx): the window's New job / Edit job form
// (src/ui_job_sheet.odin), with the form and the note it writes computed here by the same procs
// (jobs_form.odin), so the browser shows the same note, the same next run and the same messages.
// job_draft changes nothing: Create and Save are job_save, as the window's sheet sends it.
//
//   op "open"  (job: edit that job; else a new one, for_project preselected)
//              → {path, text, based_on, id, date, note (the note does not read as a form), err,
//                 form, owners [{label, value, folder}]}
//   op "write" (the form's fields, base: the note it is written into ("" new: id, date), path)
//              → {text (as the preview shows it), err (what Create/Save would refuse), next, next_ok}
//   op "read"  (text: Edit as note's) → {form (null: it stays a note), form_err, err (the parse's)}

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sys/posix"

JOB_DRAFT_OWNERS_MAX :: 40 // projects listed in the picker, as the window's

Job_Draft :: struct {
	op:          string,
	job:         string,
	for_project: string, // open: the owner preselected; write: the form's
	folder:      string,
	name:        string,
	preset:      string, // manual | hourly | every_hours | daily | weekdays | custom
	every_n:     string,
	at:          string,
	custom:      string,
	prompt:      string,
	access:      string,
	notify:      string,
	model:       string,
	hours:       string,
	max_cost:    string,
	timeout:     string,
	max_turns:   string,
	base:        string,
	id, date:    string,
	path:        string,
	text:        string,
}

JOB_DRAFT_PRESETS := [Sched_Preset]string {
	.Manual      = "manual",
	.Hourly      = "hourly",
	.Every_Hours = "every_hours",
	.Daily       = "daily",
	.Weekdays    = "weekdays",
	.Custom      = "custom",
}

job_draft_apply :: proc(c: Job_Draft) -> Result {
	b := strings.builder_make(context.temp_allocator)
	switch c.op {
	case "open":
		if folder_of(.Jobs) == "" do return fail("no main folder (Set up Deckhand…, in the Jobs tab)")
		id, date := job_new_id_date()
		path, text, note_err := "", "", ""
		f: Job_Form
		if c.job != "" {
			for r in state.jobs do if r.id == c.job do path = r.path
			if path == "" do return fail("no such job")
			data, ok := job_note_read_no_link(path)
			if !ok do return fail(fmt.tprintf("could not read %s", fs_display(path)))
			text = string(data)
			ferr: string
			f, ferr = job_form_from_note(text)
			if ferr != "" {
				f = {access = "read", notify = "always"}
				note_err = fmt.tprintf("The note does not read as a form (%s): edit it as a note", ferr)
			}
		} else {
			owner, folder, oerr := job_owner_for_create(c.for_project)
			if oerr != "" || c.for_project == "" do owner, folder = "none", "~"
			f = {for_project = owner, folder = folder, schedule = "manual", access = "read", notify = "always"}
		}
		if f.folder == "" do f.folder = "~"
		strings.write_string(&b, `{"path":`)
		json_quote(&b, path)
		strings.write_string(&b, `,"text":`)
		json_quote(&b, text)
		strings.write_string(&b, `,"shown":`)
		json_quote(&b, path != "" ? fs_display(path) : "")
		strings.write_string(&b, `,"based_on":`)
		json_quote(&b, path != "" ? job_note_hash(text) : "")
		strings.write_string(&b, `,"id":`)
		json_quote(&b, id)
		strings.write_string(&b, `,"date":`)
		json_quote(&b, date)
		fmt.sbprintf(&b, `,"note":%v,"err":`, note_err != "")
		json_quote(&b, note_err)
		strings.write_string(&b, `,"form":`)
		job_draft_form_json(&b, f)
		strings.write_string(&b, `,"owners":`)
		job_draft_owners_json(&b, f.for_project, f.folder)
		strings.write_byte(&b, '}')
	case "write":
		f, ferr := job_draft_form(c)
		check := job_draft_path(c.path)
		// as the preview shows it: leniently (the form's own checks skipped)
		text, _ := job_draft_note(c, f, lenient = true)
		err := ferr
		if err == "" {
			_, err = job_draft_note(c, f, lenient = false)
			if err == "" do err = job_parse(text, check, context.temp_allocator).err
		}
		next, next_ok := "", false
		if ferr != "" do next = ferr
		else do next, next_ok = sched_next_text(f.schedule)
		strings.write_string(&b, `{"text":`)
		json_quote(&b, text)
		strings.write_string(&b, `,"err":`)
		json_quote(&b, err)
		strings.write_string(&b, `,"next":`)
		json_quote(&b, next)
		fmt.sbprintf(&b, `,"next_ok":%v}}`, next_ok)
	case "read":
		f, ferr := job_form_from_note(c.text)
		if ferr == "" do ferr = job_form_check(f)
		strings.write_string(&b, `{"form":`)
		if ferr == "" do job_draft_form_json(&b, f)
		else do strings.write_string(&b, "null")
		strings.write_string(&b, `,"form_err":`)
		json_quote(&b, ferr != "" ? fmt.tprintf("Stays a note: %s", ferr) : "")
		strings.write_string(&b, `,"err":`)
		json_quote(&b, job_parse(c.text, job_draft_path(c.path), context.temp_allocator).err)
		if ferr == "" {
			strings.write_string(&b, `,"owners":`)
			job_draft_owners_json(&b, f.for_project, f.folder)
		}
		strings.write_byte(&b, '}')
	case:
		return fail("op: open, write or read")
	}
	return {ok = true, data = strings.to_string(b)}
}

@(private = "file")
job_draft_path :: proc(path: string) -> string {return path != "" ? path : "/new.md"}

// The form from the fields (as the window's job_sheet_form); err: a field that is not right.
@(private = "file")
job_draft_form :: proc(c: Job_Draft) -> (f: Job_Form, err: string) {
	f.name = strings.trim_space(c.name)
	f.for_project = c.for_project
	f.folder = c.folder
	f.prompt = c.prompt
	f.access = c.access == "full" ? "full" : "read"
	f.notify = c.notify == "attention" || c.notify == "never" ? c.notify : "always"
	f.model, f.hours, f.max_cost = strings.trim_space(c.model), strings.trim_space(c.hours), strings.trim_space(c.max_cost)
	f.timeout, f.max_turns = strings.trim_space(c.timeout), strings.trim_space(c.max_turns)
	p := Sched_Preset.Manual
	for name, x in JOB_DRAFT_PRESETS do if name == c.preset do p = x
	f.schedule, err = sched_preset_text(p, c.every_n, c.at, c.custom)
	return
}

// The note the form writes (as the window's job_sheet_note).
@(private = "file")
job_draft_note :: proc(c: Job_Draft, form: Job_Form, lenient: bool) -> (string, string) {
	f := form
	if f.schedule == "" do f.schedule = "manual"
	if c.base != "" do return job_note_apply_form(c.base, f, check = !lenient)
	return job_form_new_note(f, c.id, c.date, check = !lenient)
}

@(private = "file")
job_draft_form_json :: proc(b: ^strings.Builder, f: Job_Form) {
	p, n, at := sched_preset_detect(f.schedule)
	kv :: proc(b: ^strings.Builder, k, v: string) {
		fmt.sbprintf(b, `"%s":`, k)
		json_quote(b, v)
		strings.write_byte(b, ',')
	}
	strings.write_byte(b, '{')
	kv(b, "name", f.name)
	kv(b, "for_project", f.for_project)
	kv(b, "folder", f.folder != "" ? f.folder : "~")
	kv(b, "preset", JOB_DRAFT_PRESETS[p])
	kv(b, "every_n", n != "" ? n : "2")
	kv(b, "at", at != "" ? at : "07:00")
	kv(b, "custom", p == .Custom ? f.schedule : "")
	kv(b, "prompt", f.prompt)
	kv(b, "access", f.access == "full" ? "full" : "read")
	kv(b, "notify", f.notify != "" ? f.notify : "always")
	kv(b, "model", f.model)
	kv(b, "hours", f.hours)
	kv(b, "max_cost", f.max_cost)
	kv(b, "timeout", f.timeout)
	strings.write_string(b, `"max_turns":`)
	json_quote(b, f.max_turns)
	strings.write_byte(b, '}')
}

// The owner choices, as the window's (ui_job_sheet.odin sheet_owners_build): the shown projects,
// the selected first, then by recent activity; the note's own when it is not among them; then
// Atlas, Chats, None.
@(private = "file")
job_draft_owners_json :: proc(b: ^strings.Builder, owner, folder: string) {
	Owner :: struct {
		label, value, folder: string,
	}
	out := make([dynamic]Owner, context.temp_allocator)
	ps := make([dynamic]^Project, context.temp_allocator)
	for &p in state.projects do if p.group == .Projects && p.machine == 0 && project_hide_reason(p) == .None do append(&ps, &p)
	slice.sort_by(ps[:], proc(a, b: ^Project) -> bool {
		if (a.id == state.selected_project) != (b.id == state.selected_project) do return a.id == state.selected_project
		return project_active(a^) > project_active(b^)
	})
	found := false
	for p, i in ps {
		if i >= JOB_DRAFT_OWNERS_MAX do break
		t := path_tilde(p.cwd)
		if t == owner do found = true
		append(&out, Owner{project_display(p^), t, t})
	}
	if !found && owner != "" && !slice.contains([]string{"atlas", "chats", "none"}, strings.to_lower(owner, context.temp_allocator)) {
		label := owner
		if pp, _ := owner_project_named(owner, owner_projects()); pp != nil do label = pp.shown
		inject_at(&out, 0, Owner{label, owner, folder})
	}
	if a := folder_of(.Atlas); a != "" do append(&out, Owner{agent_name(), "atlas", path_tilde(a)})
	append(&out, Owner{"Chats", "chats", path_tilde(folder_of(.Chats))})
	append(&out, Owner{"None", "none", "~"})
	strings.write_byte(b, '[')
	for o, i in out {
		if i > 0 do strings.write_byte(b, ',')
		strings.write_string(b, `{"label":`)
		json_quote(b, o.label)
		strings.write_string(b, `,"value":`)
		json_quote(b, o.value)
		strings.write_string(b, `,"folder":`)
		json_quote(b, o.folder)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// ---- the commands' plumbing (inbox.odin, json_write.odin): both view commands of a browser ----

web_extra_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	#partial switch c in cmd {
	case Job_Draft:    return job_draft_apply(c), false
	case Web_Settings: return web_settings_apply(c, caller), false
	}
	return fail("not a browser view command"), false
}

web_extra_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	#partial switch c in cmd {
	case Job_Draft:
		x := c
		for &f in job_draft_strings(&x) do f^ = strings.clone(f^, allocator)
		return x
	case Web_Settings: return c
	}
	return cmd
}

web_extra_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Job_Draft:
		x := c
		for f in job_draft_strings(&x) do delete(f^, allocator)
	}
}

web_extra_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Job_Draft:    return "job_draft"
	case Web_Settings: return "web_settings"
	}
	return ""
}

// Its fields' names, in job_draft_strings' order.
JOB_DRAFT_FIELDS := [?]string{"op", "job", "for_project", "folder", "name", "preset", "every_n", "at", "custom", "prompt", "access", "notify", "model", "hours", "max_cost", "timeout", "max_turns", "base", "id", "date", "path", "text"}

// A Job_Draft's strings (temp slice of pointers into c).
job_draft_strings :: proc(c: ^Job_Draft) -> []^string {
	return slice.clone([]^string{&c.op, &c.job, &c.for_project, &c.folder, &c.name, &c.preset, &c.every_n, &c.at, &c.custom, &c.prompt, &c.access, &c.notify, &c.model, &c.hours, &c.max_cost, &c.timeout, &c.max_turns, &c.base, &c.id, &c.date, &c.path, &c.text}, context.temp_allocator)
}


// A job's note: a regular file, never through a link put in its place (as file_read), at most
// JOB_NOTE_MAX.
@(private = "file")
job_note_read_no_link :: proc(path: string) -> ([]u8, bool) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
	if fd < 0 do return nil, false
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) || i64(st.st_size) > JOB_NOTE_MAX do return nil, false
	buf := make([]u8, int(st.st_size) + 1, context.temp_allocator)
	n := 0
	for n < len(buf) {
		rem := len(buf) - n
		k := posix.read(fd, raw_data(buf[n:]), uint(rem))
		if k < 0 {
			if posix.errno() == .EINTR do continue
			return nil, false
		}
		if k == 0 do break
		n += int(k)
	}
	if n > JOB_NOTE_MAX do return nil, false
	return buf[:n], true
}
