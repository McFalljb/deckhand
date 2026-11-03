package main

// The job sheet's form (ui_job_sheet.odin) and the note it writes. The note
// stays the source of truth: the form is read from a note and written into
// one, changing only the frontmatter keys it shows, the `# Title` line and
// the `## Prompt` section. Every other line (unknown keys, comments, `id`,
// `enabled`, `## Check`, `## Recent runs`) stays as it is.
//
// Schedule presets → schedule strings (schedule_parse reads them):
//   manual → "manual"; hourly → "0 * * * *"; every N hours → "every Nh";
//   daily at HH:MM → "MM HH * * *"; weekdays at HH:MM → "MM HH * * 1-5";
//   custom → the text as typed (cron, "every …", "at …").

import "core:fmt"
import "core:strconv"
import "core:strings"

Job_Form :: struct {
	name:        string,
	for_project: string, // the owner: a project's folder (~/…) or name, atlas, chats, none; "" = none set
	folder:      string, // as written (~/… or absolute)
	schedule:    string,
	prompt:      string,
	access:      string, // read | full
	notify:      string, // always | attention | never
	model:       string, // the advanced ones: "" = not set
	hours:       string,
	max_cost:    string,
	timeout:     string,
	max_turns:   string,
}

// The frontmatter keys the form writes, in the order new ones are added.
JOB_FORM_KEYS := [?]string{"summary", "schedule", "folder", "for_project", "access", "notify", "model", "hours", "max_cost", "timeout", "max_turns"}

// The form's value for a key.
@(private = "file")
form_value :: proc(f: Job_Form, key: string, summary := "") -> string {
	switch key {
	case "summary":     return summary != "" ? summary : f.name
	case "schedule":    return f.schedule
	case "folder":      return f.folder
	case "for_project": return f.for_project
	case "access":      return f.access
	case "notify":      return f.notify
	case "model":       return f.model
	case "hours":       return f.hours
	case "max_cost":    return f.max_cost
	case "timeout":     return f.timeout
	case "max_turns":   return f.max_turns
	}
	return ""
}

// The index of the note's title line: its first `# ` line before the first
// `## ` (one inside a section, say ## Check, is not it); -1 when none.
@(private = "file")
title_index :: proc(lines: []string) -> int {
	for l, i in lines {
		if strings.has_prefix(l, "## ") do break
		if strings.has_prefix(l, "# ") do return i
	}
	return -1
}

// The note's title: its title line, else its summary.
@(private = "file")
note_title :: proc(body: string, summary: string) -> string {
	lines := strings.split_lines(body, context.temp_allocator)
	if i := title_index(lines); i >= 0 do return strings.trim_space(strings.trim_right(lines[i][2:], "\r"))
	return summary
}

// The form from a note (temp allocator); err when it cannot be read as one.
job_form_from_note :: proc(text: string) -> (f: Job_Form, err: string) {
	vals, ferr, ok := note_front_values(text)
	if !ok do return f, ferr
	_, body, _, _ := note_split(text)
	f.name = note_title(body, vals["summary"])
	f.for_project = vals["for_project"]
	f.folder = vals["folder"]
	f.schedule = vals["schedule"]
	prompt, _ := note_section(body, "prompt")
	f.prompt = strings.trim_space(prompt)
	f.access = vals["access"] != "" ? vals["access"] : "read"
	f.notify = vals["notify"] != "" ? vals["notify"] : "always"
	f.model, f.hours, f.max_cost, f.timeout, f.max_turns = vals["model"], vals["hours"], vals["max_cost"], vals["timeout"], vals["max_turns"]
	return f, ""
}

// What is wrong with the form before it becomes a note ("" = nothing).
job_form_check :: proc(f: Job_Form) -> string {
	if strings.trim_space(f.name) == "" do return "Name: give the job a name"
	if strings.contains_any(f.name, "\r\n") do return "Name: one line"
	if strings.trim_space(f.prompt) == "" do return "Prompt: say what the job should do"
	for l in strings.split_lines(f.prompt, context.temp_allocator) do if note_known_heading(l) do return "Prompt: it cannot hold a ## Prompt, ## Check or ## Recent runs heading"
	for k in JOB_FORM_KEYS do if strings.contains_any(form_value(f, k), "\r\n") do return fmt.tprintf("%s: one line", k)
	return ""
}

// base with the form written into it (temp allocator). base must have
// frontmatter (a new note starts from job_template). Keys the form leaves
// empty are removed (the required ones parse as errors then); a key whose
// value did not change keeps its line as it was.
job_note_apply_form :: proc(base: string, f: Job_Form, check := true) -> (text: string, err: string) {
	if check do if e := job_form_check(f); e != "" do return "", e
	vals, ferr, ok := note_front_values(base)
	if !ok do return "", ferr
	eol := note_eol(base)
	_, body, front_end, _ := note_split(base)
	head := base[:front_end]
	// summary: a summary of its own stays; one that was the title follows the name
	summary := ""
	if old, has := vals["summary"]; has && old != note_title(body, old) do summary = old
	b := strings.builder_make(context.temp_allocator)
	done := make(map[string]bool, context.temp_allocator)
	lines := strings.split_after(head, "\n", context.temp_allocator)
	closing := -1
	for l, i in lines do if i > 0 && strings.trim_right(l, "\r\n") == "---" do closing = i
	for l, i in lines {
		bare := strings.trim_right(l, "\r\n")
		if i == closing {
			// the closing line: the form's keys that were not there go before it
			for k in JOB_FORM_KEYS {
				v := strings.trim_space(form_value(f, k, summary))
				if done[k] || v == "" do continue
				fmt.sbprintf(&b, "%s: %s%s", k, yaml_quote(v), eol)
			}
			strings.write_string(&b, l)
			continue
		}
		key := ""
		if i > 0 && !strings.has_prefix(bare, "#") && !strings.has_prefix(bare, " ") {
			if c := strings.index_byte(bare, ':'); c > 0 do key = bare[:c]
		}
		managed := false
		for k in JOB_FORM_KEYS do if k == key do managed = true
		if !managed || done[key] {
			strings.write_string(&b, l)
			continue
		}
		done[key] = true
		v := strings.trim_space(form_value(f, key, summary))
		if v == "" do continue // cleared: the line goes
		if old, has := vals[key]; has && old == v {
			strings.write_string(&b, l) // unchanged: its quoting and comment stay
			continue
		}
		fmt.sbprintf(&b, "%s: %s%s", key, yaml_quote(v), eol)
	}
	// the body: the title, then the Prompt section
	name := strings.trim_space(one_line(f.name, context.temp_allocator))
	prompt := strings.trim_space(f.prompt)
	blines := strings.split_lines(body, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	append(&out, ..blines)
	if ti := title_index(blines); ti >= 0 do out[ti] = fmt.tprintf("# %s", name)
	else {
		// no title: one after the frontmatter
		at := 0
		for at < len(out) && strings.trim_space(out[at]) == "" do at += 1
		inject_at(&out, at, fmt.tprintf("# %s", name), "")
	}
	start, end := -1, len(out)
	for l, i in out {
		n := strings.trim_right(l, "\r")
		if start >= 0 && note_known_heading(n) {
			end = i
			break
		}
		if start < 0 && strings.has_prefix(n, "## ") && strings.equal_fold(strings.trim_space(n[3:]), "prompt") do start = i
	}
	section := make([dynamic]string, context.temp_allocator)
	for l in strings.split_lines(prompt, context.temp_allocator) do append(&section, strings.trim_right(l, "\r"))
	final := make([dynamic]string, context.temp_allocator)
	if start < 0 {
		// no Prompt section: after the title
		at := title_index(out[:]) + 1
		append(&final, ..out[:at])
		append(&final, "", "## Prompt")
		append(&final, ..section[:])
		append(&final, "")
		rest := out[at:]
		for len(rest) > 0 && strings.trim_space(rest[0]) == "" do rest = rest[1:]
		append(&final, ..rest)
	} else {
		append(&final, ..out[:start + 1])
		append(&final, ..section[:])
		if end < len(out) do append(&final, "")
		append(&final, ..out[end:])
	}
	for l, i in final {
		if i > 0 do strings.write_string(&b, eol)
		strings.write_string(&b, strings.trim_right(l, "\r"))
	}
	text = strings.to_string(b)
	if !strings.has_suffix(text, "\n") do text = strings.concatenate({text, eol}, context.temp_allocator)
	return text, ""
}

// A new note from the form: the template (id, date), with the form in it.
job_form_new_note :: proc(f: Job_Form, id, date: string, check := true) -> (string, string) {
	base := job_template(id, one_line(strings.trim_space(f.name) != "" ? f.name : "New job", context.temp_allocator), "manual", "-", "~", date, f.for_project)
	return job_note_apply_form(base, f, check)
}

// ---- schedule presets ----

Sched_Preset :: enum u8 {
	Manual,
	Hourly,
	Every_Hours,
	Daily,
	Weekdays,
	Custom,
}
SCHED_PRESET_LABELS := [Sched_Preset]string {
	.Manual      = "Manual",
	.Hourly      = "Hourly",
	.Every_Hours = "Every N hours",
	.Daily       = "Daily",
	.Weekdays    = "Weekdays",
	.Custom      = "Custom",
}

// "HH:MM" → hour, minute.
@(private = "file")
parse_hhmm :: proc(s: string) -> (h, m: int, ok: bool) {
	a, _, b := strings.partition(strings.trim_space(s), ":")
	hh, ok1 := strconv.parse_int(a, 10)
	mm, ok2 := strconv.parse_int(b, 10)
	if !ok1 || !ok2 || len(b) != 2 || hh < 0 || hh > 23 || mm < 0 || mm > 59 do return 0, 0, false
	return hh, mm, true
}

EVERY_HOURS_MAX :: 168 // a week

// The schedule string of a preset (temp); err when its value is not right.
sched_preset_text :: proc(p: Sched_Preset, every_n, at, custom: string) -> (string, string) {
	switch p {
	case .Manual: return "manual", ""
	case .Hourly: return "0 * * * *", ""
	case .Every_Hours:
		n, ok := strconv.parse_int(strings.trim_space(every_n), 10)
		if !ok || n < 1 || n > EVERY_HOURS_MAX do return "", fmt.tprintf("Every N hours: a number of hours, 1 to %d", EVERY_HOURS_MAX)
		return fmt.tprintf("every %dh", n), ""
	case .Daily, .Weekdays:
		h, m, ok := parse_hhmm(at)
		if !ok do return "", "At: a time as HH:MM (24 h), e.g. 07:30"
		return fmt.tprintf("%d %d * * %s", m, h, p == .Daily ? "*" : "1-5"), ""
	case .Custom: return strings.trim_space(custom), ""
	}
	return "", ""
}

// The preset a schedule string is (Custom when none), with its values.
sched_preset_detect :: proc(s: string) -> (p: Sched_Preset, every_n, at: string) {
	t := strings.trim_space(s)
	if t == "manual" || t == "" do return .Manual, "", ""
	if t == "0 * * * *" do return .Hourly, "", ""
	if strings.has_prefix(t, "every ") && strings.has_suffix(t, "h") {
		n, ok := strconv.parse_int(t[6:len(t) - 1], 10)
		if ok && n >= 1 && n <= EVERY_HOURS_MAX do return .Every_Hours, fmt.tprintf("%d", n), ""
	}
	f := strings.fields(t, context.temp_allocator)
	if len(f) == 5 && f[2] == "*" && f[3] == "*" && (f[4] == "*" || f[4] == "1-5") {
		m, ok1 := strconv.parse_int(f[0], 10)
		h, ok2 := strconv.parse_int(f[1], 10)
		if ok1 && ok2 && m >= 0 && m < 60 && h >= 0 && h < 24 do return f[4] == "*" ? .Daily : .Weekdays, "", fmt.tprintf("%02d:%02d", h, m)
	}
	return .Custom, "", ""
}

// "next run: Mon 03 Nov 07:00 (local)", "runs only when you click Run now",
// or why the schedule does not parse.
sched_next_text :: proc(s: string) -> (text: string, ok: bool) {
	sc, err := schedule_parse(s)
	if err != "" do return fmt.tprintf("Schedule: %s", err), false
	if sc.kind == .Manual do return "Runs only when you click Run now", true
	now := jobs_now()
	next := schedule_next(sc, now, 0)
	if next <= 0 do return "No next run", true
	if sc.kind == .At && next <= now do return "That time has passed", false
	c, wday := unix_to_local(next)
	days := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	return fmt.tprintf("Next run: %s %04d-%02d-%02d %02d:%02d", days[wday % 7], c.year, c.month, c.day, c.hour, c.minute), true
}
