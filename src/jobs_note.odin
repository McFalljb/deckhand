package main

// Job notes (docs/ATLAS.md §3.1): `<notes>/jobs/<slug>.md`, one job each.
// The definition is the frontmatter (a strict flat YAML subset: `key:
// value`, quoted strings, `[a, b]` lists, `#` comments) plus the `##
// Prompt` and `## Check` sections. `## Recent runs` is pi-desk's, written by
// the scheduler only (job_note_set_recent). Anything the parser does not
// know is an error on the job's row, and the job does not run: a job never
// runs with a key pi-desk does not understand (an `approved: true` too:
// approval was never a note key, and jobs need none).
//
// Also here: the run report (§7: `## Summary`, `## Needs you`) and the
// redaction of summaries (pi-kit's guardrails patterns, §2 Git).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:text/regex"

Job_Access :: enum u8 {
	Read, // PI_KIT_READONLY=1
	Workspace, // step 4 (PI_KIT_WRITE_ROOTS): refused for now
	Full,
}
JOB_ACCESS_NAMES := [Job_Access]string {
	.Read      = "read",
	.Workspace = "workspace",
	.Full      = "full",
}

Job_Notify :: enum u8 {
	Always,
	Attention, // needs_you, failures and safety stops, folder_missing
	Never,
}
JOB_NOTIFY_NAMES := [Job_Notify]string {
	.Always    = "always",
	.Attention = "attention",
	.Never     = "never",
}

// A job's definition as parsed from its note. Strings live in the
// allocator job_parse was given (the job's own arena).
Job_Def :: struct {
	id:          string,
	name:        string, // the note's `# Title`, else its summary, else the file name
	slug:        string, // the file name without .md
	enabled:     bool,
	schedule:    Schedule,
	sched_text:  string,
	hours_from:  int, // -1 = any hour
	hours_to:    int,
	model:       string,
	folder:      string, // absolute, ~ expanded ("" = the home folder)
	for_project: string,
	access:      Job_Access,
	notify:      Job_Notify,
	touches:     []string,
	max_cost:    f64, // 0 = the global limit (if any)
	timeout:     i64, // seconds; 0 = the global limit
	max_turns:   int,
	prompt:      string,
	check:       string,
	err:         string, // why it cannot run ("" = fine)
	warnings:    []string,
}

JOB_ID_MAX :: 64

// The frontmatter keys a job note may have: the notes vault's fields, then
// the job's (docs/ATLAS.md §3.1).
JOB_KEYS := [?]string{"type", "project", "date", "status", "summary", "tags", "aliases", "updated_by", "id", "enabled", "schedule", "hours", "model", "folder", "for_project", "access", "worktree", "notify", "touches", "max_cost", "timeout", "max_turns"}

// A frontmatter value: a scalar or a list.
@(private = "file")
Fm_Value :: struct {
	s:       string,
	list:    []string,
	is_list: bool,
}

// Splits a note into its frontmatter lines and its body (after the closing
// ---). ok = false when there is no frontmatter.
note_split :: proc(text: string) -> (front: string, body: string, front_end: int, ok: bool) {
	t := strings.trim_prefix(text, "\xef\xbb\xbf")
	skip := len(text) - len(t)
	first, _, rest_ := strings.partition(t, "\n")
	if strings.trim_right(first, "\r") != "---" do return "", text, 0, false
	start := len(first) + 1
	at := start
	rest := rest_
	for len(rest) > 0 || at <= len(t) {
		nl := strings.index_byte(rest, '\n')
		line := nl < 0 ? rest : rest[:nl]
		if strings.trim_right(line, "\r") == "---" {
			end := at + len(line) + (nl < 0 ? 0 : 1)
			return t[start:at], t[end:], skip + end, true
		}
		if nl < 0 do break
		at += nl + 1
		rest = rest[nl + 1:]
	}
	return "", text, 0, false
}

// Parses the flat YAML subset (temp allocator for the values).
@(private = "file")
fm_parse :: proc(front: string) -> (vals: map[string]Fm_Value, keys: [dynamic]string, err: string) {
	vals = make(map[string]Fm_Value, context.temp_allocator)
	keys = make([dynamic]string, context.temp_allocator)
	n := 0
	it := front
	for raw in strings.split_lines_iterator(&it) {
		n += 1
		line := strings.trim_right(raw, "\r")
		if strings.trim_space(line) == "" || strings.has_prefix(line, "#") do continue
		if line[0] == ' ' || line[0] == '\t' do return vals, keys, fmt.tprintf("frontmatter line %d: indented lines are not supported (flat key: value only)", n)
		colon := strings.index_byte(line, ':')
		if colon <= 0 do return vals, keys, fmt.tprintf("frontmatter line %d: expected key: value", n)
		key := line[:colon]
		for c in key do if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') do return vals, keys, fmt.tprintf("frontmatter line %d: bad key %q", n, key)
		rest := line[colon + 1:]
		if len(rest) > 0 && rest[0] != ' ' && rest[0] != '\t' do return vals, keys, fmt.tprintf("frontmatter line %d: expected a space after %s:", n, key)
		if key in vals do return vals, keys, fmt.tprintf("frontmatter line %d: %s is set twice", n, key)
		v, verr := fm_value(strings.trim_space(rest))
		if verr != "" do return vals, keys, fmt.tprintf("frontmatter line %d (%s): %s", n, key, verr)
		vals[key] = v
		append(&keys, key)
	}
	return vals, keys, ""
}

// After a value: nothing, or a ` # comment`.
@(private = "file")
fm_tail_ok :: proc(s: string) -> bool {
	t := strings.trim_left(s, " \t")
	return t == "" || (strings.has_prefix(t, "#") && len(t) < len(s))
}

@(private = "file")
fm_quoted :: proc(s: string) -> (val: string, rest: string, err: string) {
	q := s[0]
	b := strings.builder_make(context.temp_allocator)
	i := 1
	for i < len(s) {
		c := s[i]
		if q == '\'' {
			if c == '\'' {
				if i + 1 < len(s) && s[i + 1] == '\'' {
					strings.write_byte(&b, '\'')
					i += 2
					continue
				}
				return strings.to_string(b), s[i + 1:], ""
			}
		} else {
			if c == '"' do return strings.to_string(b), s[i + 1:], ""
			if c == '\\' && i + 1 < len(s) {
				switch s[i + 1] {
				case 'n':  strings.write_byte(&b, '\n')
				case 't':  strings.write_byte(&b, '\t')
				case '"':  strings.write_byte(&b, '"')
				case '\\': strings.write_byte(&b, '\\')
				case:      return "", "", "unsupported escape in a quoted string"
				}
				i += 2
				continue
			}
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return "", "", "a quoted string that never ends"
}

@(private = "file")
fm_value :: proc(s: string) -> (v: Fm_Value, err: string) {
	if s == "" do return {}, ""
	switch s[0] {
	case '"', '\'':
		val, rest, e := fm_quoted(s)
		if e != "" do return {}, e
		if !fm_tail_ok(rest) do return {}, "text after a quoted string"
		return {s = val}, ""
	case '[':
		end := strings.index_byte(s, ']')
		if end < 0 do return {}, "a list that never ends (lists stay on one line)"
		if !fm_tail_ok(s[end + 1:]) do return {}, "text after a list"
		inner := strings.trim_space(s[1:end])
		items := make([dynamic]string, context.temp_allocator)
		if inner != "" {
			for part in strings.split(inner, ",", context.temp_allocator) {
				p := strings.trim_space(part)
				if p == "" do return {}, "an empty list item"
				if p[0] == '"' || p[0] == '\'' {
					val, rest, e := fm_quoted(p)
					if e != "" do return {}, e
					if strings.trim_space(rest) != "" do return {}, "text after a quoted list item"
					p = val
				} else if strings.index_any(p, "[]{}:#") >= 0 do return {}, "nested values are not supported"
				append(&items, p)
			}
		}
		return {list = items[:], is_list = true}, ""
	case '{', '|', '>', '&', '*', '!', '%', '@', '`':
		return {}, "only plain values, quoted strings and [a, b] lists are supported"
	}
	val := s
	if i := strings.index(s, " #"); i >= 0 do val = s[:i]
	if i := strings.index(val, "\t#"); i >= 0 do val = val[:i]
	val = strings.trim_space(val)
	if strings.has_prefix(val, "- ") do return {}, "block lists are not supported (use [a, b])"
	return {s = val}, ""
}

// A level-2 heading's name, or "".
@(private = "file")
h2 :: proc(line: string) -> string {
	l := strings.trim_right(line, "\r")
	if !strings.has_prefix(l, "## ") do return ""
	return strings.trim_space(l[3:])
}

// The sections pi-desk reads; any other `## ` heading belongs to the
// section above it (a prompt may ask for its own headings).
@(private = "file")
known_section :: proc(name: string) -> bool {
	n := strings.to_lower(name, context.temp_allocator)
	return n == "prompt" || n == "check" || n == "recent runs"
}

// The text of section `name` in body (between its heading and the next
// known heading), and whether it is there.
note_section :: proc(body, name: string) -> (text: string, found: bool) {
	lines := strings.split_lines(body, context.temp_allocator)
	start := -1
	for l, i in lines {
		n := h2(l)
		if n == "" do continue
		if start >= 0 && known_section(n) {
			return strings.join(lines[start:i], "\n", context.temp_allocator), true
		}
		if start < 0 && strings.equal_fold(n, name) do start = i + 1
	}
	if start < 0 do return "", false
	return strings.join(lines[start:], "\n", context.temp_allocator), true
}

// The fenced code block in a Check section ("" = none).
@(private = "file")
fenced :: proc(s: string) -> string {
	lines := strings.split_lines(s, context.temp_allocator)
	open := -1
	for l, i in lines {
		if !strings.has_prefix(strings.trim_space(l), "```") do continue
		if open < 0 {
			open = i
			continue
		}
		return strings.trim_space(strings.join(lines[open + 1:i], "\n", context.temp_allocator))
	}
	return ""
}

// "20m", "90s", "1h", "2d" in seconds; -1 = not a duration.
parse_duration :: proc(s: string) -> i64 {
	if len(s) < 2 do return -1
	n, ok := strconv.parse_i64(s[:len(s) - 1])
	if !ok || n <= 0 do return -1
	switch s[len(s) - 1] {
	case 's': return n
	case 'm': return n * 60
	case 'h': return n * 3600
	case 'd': return n * 86400
	}
	return -1
}

// A job id: short, safe as a folder name.
job_id_valid :: proc(id: string) -> bool {
	if id == "" || len(id) > JOB_ID_MAX do return false
	for c, i in id {
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || ((c == '-' || c == '_') && i > 0)
		if !ok do return false
	}
	return true
}

// Parses a job note. path: the note's file (its name is the slug).
job_parse :: proc(text, path: string, allocator: runtime.Allocator) -> (d: Job_Def) {
	context.allocator = allocator
	base := path[strings.last_index_byte(path, '/') + 1:]
	d.slug = strings.clone(strings.trim_suffix(base, ".md"))
	d.name = d.slug
	d.hours_from, d.hours_to = -1, -1
	warns := make([dynamic]string)
	defer d.warnings = warns[:]
	bad :: proc(d: ^Job_Def, msg: string) {if d.err == "" do d.err = strings.clone(msg)}

	front, body, _, ok := note_split(text)
	// the title, also for a broken note
	for l in strings.split_lines(body, context.temp_allocator) {
		if strings.has_prefix(l, "# ") {
			if t := strings.trim_space(l[2:]); t != "" do d.name = strings.clone(cut_utf8(one_line(t, context.temp_allocator), 120))
			break
		}
	}
	if !ok {
		bad(&d, "no frontmatter (the note must start with ---)")
		return
	}
	vals, keys, ferr := fm_parse(front)
	if ferr != "" {
		bad(&d, ferr)
		return
	}
	str :: proc(vals: map[string]Fm_Value, k: string) -> (string, bool) {
		v, has := vals[k]
		if !has || v.is_list do return "", has && !v.is_list
		return v.s, true
	}
	if v, has := vals["summary"]; has && !v.is_list && v.s != "" && d.name == d.slug do d.name = strings.clone(cut_utf8(one_line(v.s, context.temp_allocator), 120))
	for k in keys {
		known := false
		for x in JOB_KEYS do if x == k do known = true
		if !known do bad(&d, fmt.tprintf("%s: not a job setting (check the spelling; see docs/ATLAS.md §3.1)", k))
	}
	for k in keys do if vals[k].is_list && k != "touches" && k != "tags" && k != "aliases" do bad(&d, fmt.tprintf("%s: a list where one value is expected", k))

	id, _ := str(vals, "id")
	if id == "" do bad(&d, "id: missing (a short stable id, e.g. id: 7f3a2c)")
	else if !job_id_valid(id) do bad(&d, "id: use a-z, 0-9, - and _ (at most 64)")
	d.id = strings.clone(id)

	en, has_en := str(vals, "enabled")
	switch {
	case !has_en || en == "" || en == "false": d.enabled = false
	case en == "true":                         d.enabled = true
	case:                                      bad(&d, "enabled: true or false")
	}

	sc, _ := str(vals, "schedule")
	d.sched_text = strings.clone(sc)
	if sc == "" do bad(&d, `schedule: missing (cron "0 7 * * 1-5", "every 30m", "at 2026-11-03 09:00" or "manual")`)
	else {
		s, serr := schedule_parse(sc)
		if serr != "" do bad(&d, fmt.tprintf("schedule: %s", serr))
		d.schedule = s
		if s.kind == .Every && s.every < 30 * 60 do append(&warns, "runs more often than every 30 minutes (cost)")
		if s.kind == .Cron && s.min_gap < 30 * 60 do append(&warns, "runs more often than every 30 minutes (cost)")
	}
	if h, _ := str(vals, "hours"); h != "" {
		a, _, b := strings.partition(h, "-")
		x, ok1 := strconv.parse_int(a)
		y, ok2 := strconv.parse_int(b)
		if !ok1 || !ok2 || x < 0 || x > 23 || y < 0 || y > 23 do bad(&d, `hours: "HH-HH" in local time, e.g. "07-22"`)
		else do d.hours_from, d.hours_to = x, y
	}
	if m, _ := str(vals, "model"); m != "" {
		if !agent_model_valid(m) do bad(&d, `model: "provider/id" (optionally ":thinking")`)
		d.model = strings.clone(m)
	}
	folder, _ := str(vals, "folder")
	home := os.get_env("HOME", context.temp_allocator)
	switch {
	case folder == "" || folder == "~": d.folder = strings.clone(home)
	case strings.has_prefix(folder, "~/"): d.folder = strings.concatenate({home, folder[1:]})
	case strings.has_prefix(folder, "/"):  d.folder = strings.clone(strings.trim_right(folder, "/") != "" ? strings.trim_right(folder, "/") : "/")
	case: bad(&d, "folder: an absolute path or ~/…")
	}
	fp, _ := str(vals, "for_project")
	d.for_project = strings.clone(fp)
	acc, _ := str(vals, "access")
	switch acc {
	case "", "read": d.access = .Read
	case "full":     d.access = .Full
	case "workspace":
		d.access = .Workspace
		bad(&d, "access: workspace is not supported yet (a later pi-desk step); use read or full")
	case: bad(&d, "access: read or full")
	}
	if wt, _ := str(vals, "worktree"); wt == "true" do bad(&d, "worktree: true is not supported yet (a later pi-desk step)")
	else if wt != "" && wt != "false" do bad(&d, "worktree: true or false")
	nt, _ := str(vals, "notify")
	switch nt {
	case "", "always": d.notify = .Always
	case "attention":  d.notify = .Attention
	case "never":      d.notify = .Never
	case:              bad(&d, "notify: always, attention or never")
	}
	if v, has := vals["touches"]; has {
		list := v.is_list ? v.list : (v.s != "" ? []string{v.s} : nil)
		out := make([]string, len(list))
		for x, i in list do out[i] = strings.clone(x)
		d.touches = out
	}
	if mc, _ := str(vals, "max_cost"); mc != "" {
		f, fok := strconv.parse_f64(strings.trim_prefix(mc, "$"))
		if !fok || f <= 0 do bad(&d, "max_cost: a USD amount, e.g. 0.50")
		d.max_cost = f
	}
	if to, _ := str(vals, "timeout"); to != "" {
		s := parse_duration(to)
		if s <= 0 do bad(&d, `timeout: e.g. "20m", "90s", "1h"`)
		d.timeout = max(s, 0)
	}
	if mt, _ := str(vals, "max_turns"); mt != "" {
		n, nok := strconv.parse_int(mt)
		if !nok || n <= 0 do bad(&d, "max_turns: a positive number")
		d.max_turns = max(n, 0)
	}

	prompt, _ := note_section(body, "prompt")
	d.prompt = strings.clone(strings.trim_space(prompt))
	check_sec, has_check := note_section(body, "check")
	if has_check do d.check = strings.clone(fenced(check_sec))
	if d.prompt == "" do bad(&d, "## Prompt is empty")
	if d.check != "" do append(&warns, "## Check is not run yet (a later pi-desk step): the prompt runs every time")
	return
}

// ---- writing the note (pi-desk's parts only) ----

RECENT_MARKER :: "<!-- written by pi-desk; edits here are overwritten -->"
RECENT_MAX :: 10

// text with its `## Recent runs` section replaced by `lines` (newest
// first); the section is added at the end when missing. Everything else
// stays as it is (temp allocator).
job_note_set_recent :: proc(text: string, lines: []string) -> string {
	eol := note_eol(text)
	b := strings.builder_make(context.temp_allocator)
	sec := strings.builder_make(context.temp_allocator)
	strings.write_string(&sec, "## Recent runs")
	strings.write_string(&sec, eol)
	strings.write_string(&sec, RECENT_MARKER)
	strings.write_string(&sec, eol)
	for l in lines {
		strings.write_string(&sec, l)
		strings.write_string(&sec, eol)
	}
	_, _, front_end, _ := note_split(text)
	all := strings.split_after(text[front_end:], "\n", context.temp_allocator)
	start, end := -1, len(all)
	for l, i in all {
		n := h2(strings.trim_right(l, "\n"))
		if n == "" do continue
		if start >= 0 && known_section(n) {
			end = i
			break
		}
		if start < 0 && strings.equal_fold(n, "recent runs") do start = i
	}
	strings.write_string(&b, text[:front_end])
	if start < 0 {
		body := text[front_end:]
		strings.write_string(&b, body)
		if body != "" && !strings.has_suffix(body, "\n") do strings.write_string(&b, eol)
		if body != "" && !strings.has_suffix(body, strings.concatenate({eol, eol}, context.temp_allocator)) do strings.write_string(&b, eol)
		strings.write_string(&b, strings.to_string(sec))
		return strings.to_string(b)
	}
	for l in all[:start] do strings.write_string(&b, l)
	strings.write_string(&b, strings.to_string(sec))
	if end < len(all) do strings.write_string(&b, eol)
	for l in all[end:] do strings.write_string(&b, l)
	return strings.to_string(b)
}

// text with `enabled:` set in the frontmatter (added when missing); the
// rest stays (temp allocator). "" when the note has no frontmatter.
job_note_set_enabled :: proc(text: string, on: bool) -> string {
	_, _, front_end, ok := note_split(text)
	if !ok do return ""
	head := text[:front_end]
	val := on ? "enabled: true" : "enabled: false"
	lines := strings.split_after(head, "\n", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	done := false
	for l, i in lines {
		bare := strings.trim_right(l, "\r\n")
		if !done && i > 0 && strings.has_prefix(bare, "enabled:") {
			strings.write_string(&b, val)
			strings.write_string(&b, l[len(bare):])
			done = true
			continue
		}
		if !done && i > 0 && bare == "---" { 	// the closing line: add it before
			strings.write_string(&b, val)
			strings.write_string(&b, note_eol(text))
			done = true
		}
		strings.write_string(&b, l)
	}
	strings.write_string(&b, text[front_end:])
	return strings.to_string(b)
}

// The note's line ending: CRLF when its first line ends so.
note_eol :: proc(text: string) -> string {
	nl := strings.index_byte(text, '\n')
	return nl > 0 && text[nl - 1] == '\r' ? "\r\n" : "\n"
}

// A new job note (enabled: true): what the job sheet and job_create write.
// for_project: the owner (jobs_owner.odin) or "" (no line).
job_template :: proc(id, name, schedule, prompt, folder, date: string, for_project := "") -> string {
	owner := for_project != "" ? fmt.tprintf("for_project: %s\n", yaml_quote(for_project)) : ""
	optional := for_project != "" ? `# optional: hours: "07-22", model: provider/id, max_cost: 0.50, timeout: 20m, max_turns: 40` : `# optional: hours: "07-22", model: provider/id, for_project: name, max_cost: 0.50, timeout: 20m, max_turns: 40`
	return fmt.tprintf(`---
type: job
project: atlas
date: %s
status: active
summary: %s
tags: [job]
updated_by: pi-desk
id: %s
enabled: true
schedule: %s
folder: %s
%saccess: read
notify: always
%s
---
# %s

## Prompt
%s

## Recent runs
%s
`, date, yaml_quote(name), id, yaml_quote(schedule), yaml_quote(folder), owner, optional, name, prompt, RECENT_MARKER)
}

// s as a double-quoted YAML string when it needs quoting.
yaml_quote :: proc(s: string) -> string {
	// "- x", "? x": a list item or a key to YAML; quoted
	plain := s != "" && strings.index_any(s, "#:\"'[]{}|>&*!%@`,\\") < 0 && s == strings.trim_space(s) && s[0] != '-' && s[0] != '?'
	if plain do return s
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\t': strings.write_string(&b, `\t`)
		case:      strings.write_rune(&b, r)
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// ---- the report (§7) ----

Job_Report :: struct {
	headline:    string,
	summary:     string, // the Summary section (or the whole last message)
	needs_you:   []string,
	has_summary: bool, // false: the last message was used ("no summary")
}

// The report from a run's final answer (temp allocator).
job_report :: proc(final: string) -> (r: Job_Report) {
	body := strings.trim_space(final)
	section :: proc(body, name: string) -> (string, bool) {
		lines := strings.split_lines(body, context.temp_allocator)
		start := -1
		for l, i in lines {
			t := strings.trim_space(l)
			if !strings.has_prefix(t, "#") do continue
			n := strings.trim_space(strings.trim_left(t, "#"))
			if start >= 0 do return strings.join(lines[start:i], "\n", context.temp_allocator), true
			if strings.equal_fold(n, name) do start = i + 1
		}
		if start < 0 do return "", false
		return strings.join(lines[start:], "\n", context.temp_allocator), true
	}
	first_line :: proc(s: string) -> string {
		for l in strings.split_lines(s, context.temp_allocator) {
			t := strings.trim_space(l)
			t = strings.trim_left(t, "#*-> ")
			t = strings.trim_space(t)
			if t != "" do return t
		}
		return ""
	}
	sum, found := section(body, "summary")
	r.has_summary = found && strings.trim_space(sum) != ""
	r.summary = r.has_summary ? strings.trim_space(sum) : body
	r.headline = first_line(r.summary)
	if r.headline == "" do r.headline = "(no answer)"
	if ny, ok := section(body, "needs you"); ok {
		items := make([dynamic]string, context.temp_allocator)
		for l in strings.split_lines(ny, context.temp_allocator) {
			t := strings.trim_space(l)
			t = strings.trim_space(strings.trim_left(t, "-*•"))
			if t == "" do continue
			low := strings.to_lower(strings.trim_right(t, ".!"), context.temp_allocator)
			if low == "none" || low == "nothing" || low == "n/a" || low == "-" do continue
			append(&items, t)
		}
		r.needs_you = items[:]
	}
	return
}

// The reply is the heartbeat's "nothing to report" (§3.4): HEARTBEAT_OK
// at its start or end, ignoring case, whitespace and punctuation around it.
// (Used from step 5; kept with the report code.)
heartbeat_ok :: proc(text: string) -> bool {
	t := strings.to_upper(strings.trim(text, " \t\r\n.!*_`\"'"), context.temp_allocator)
	return strings.has_prefix(t, "HEARTBEAT_OK") || strings.has_suffix(t, "HEARTBEAT_OK")
}

// ---- redaction (pi-kit extensions/guardrails/core.ts: TOKEN_PATTERNS + ASSIGNMENT) ----

@(private = "file")
Redaction :: struct {
	pattern: string,
	flags:   regex.Flags,
	keep:    int, // capture groups kept in front (1: $1, 3: $1…$3 around the secret)
	with:    string,
}

@(private = "file")
REDACTIONS := [?]Redaction {
	{`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----`, {}, 0, "[REDACTED PRIVATE KEY]"},
	{`\bAKIA[0-9A-Z]{16}\b`, {}, 0, "[REDACTED]"},
	{`\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bgithub_pat_[A-Za-z0-9_]{40,}\b`, {}, 0, "[REDACTED]"},
	{`\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{20,}`, {}, 0, "[REDACTED]"},
	{`\bxox[abprs]-[A-Za-z0-9\-]{10,}`, {}, 0, "[REDACTED]"},
	{`\bAIza[0-9A-Za-z_\-]{35}\b`, {}, 0, "[REDACTED]"},
	{`\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}`, {}, 0, "[REDACTED JWT]"},
	{`(\b[a-z][a-z0-9+.\-]*://[^:/\s@]+:)([^@\s]+)(@)`, {}, 3, "[REDACTED]"},
	{`((?:password|passwd|secret|token|api[_\-]?key|access[_\-]?key|auth)["']?\s*[:=]\s*["']?)([A-Za-z0-9_\-+/=.]{12,})`, {.Case_Insensitive}, 1, "[REDACTED]"},
}

// s with secret-shaped strings replaced, as pi-kit's guardrails do for
// tool output (the key=value rule included: a summary is prose, not code).
// Temp allocator.
redact_secrets :: proc(s: string) -> string {
	out := s
	for red in REDACTIONS {
		re, err := regex.create(red.pattern, red.flags, context.temp_allocator, context.temp_allocator)
		if err != nil do continue
		b := strings.builder_make(context.temp_allocator)
		cap := regex.preallocate_capture(context.temp_allocator)
		at := 0
		changed := false
		for at <= len(out) {
			c, ok := regex.match_with_preallocated_capture(re, out[at:], &cap)
			if !ok || c == 0 do break
			m := cap.pos[0]
			if m[1] <= m[0] { 	// an empty match: step over one byte
				if at >= len(out) do break
				strings.write_byte(&b, out[at])
				at += 1
				continue
			}
			strings.write_string(&b, out[at:at + m[0]])
			switch red.keep {
			case 1:
				g := cap.pos[1]
				strings.write_string(&b, out[at + g[0]:at + g[1]])
				strings.write_string(&b, red.with)
			case 3:
				g1, g3 := cap.pos[1], cap.pos[3]
				strings.write_string(&b, out[at + g1[0]:at + g1[1]])
				strings.write_string(&b, red.with)
				strings.write_string(&b, out[at + g3[0]:at + g3[1]])
			case:
				strings.write_string(&b, red.with)
			}
			at += m[1]
			changed = true
		}
		if !changed do continue
		if at < len(out) do strings.write_string(&b, out[at:])
		out = strings.to_string(b)
	}
	return out
}

// The frontmatter's plain values by key (lists left out; temp allocator);
// ok = false when the note has no frontmatter or it does not parse.
note_front_values :: proc(text: string) -> (vals: map[string]string, err: string, ok: bool) {
	front, _, _, has := note_split(text)
	vals = make(map[string]string, context.temp_allocator)
	if !has do return vals, "no frontmatter (the note must start with ---)", false
	fm, _, ferr := fm_parse(front)
	if ferr != "" do return vals, ferr, false
	for k, v in fm do if !v.is_list do vals[k] = v.s
	return vals, "", true
}

// Whether a line is a level-2 heading pi-desk reads (## Prompt, ## Check, ## Recent runs).
note_known_heading :: proc(line: string) -> bool {
	n := h2(line)
	return n != "" && known_section(n)
}
