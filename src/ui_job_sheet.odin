package main

// The job sheet (focus widget "job_sheet"): New job and Edit job as a form
// that writes the job's note (jobs_form.odin). The note stays the source of
// truth: Create writes a new note as job_create does (enabled: true), Save
// rewrites only the frontmatter keys the form shows, the title and the
// `## Prompt` section.
//
//   left:  Name; Project (your projects, Atlas, Chats, None: sets folder:
//          and for_project:); Schedule (presets or custom, the next run or
//          why it does not parse, live); Prompt; Access; Notify; Advanced
//          (folded: model, hours, max_cost, timeout, max_turns).
//   right: the note the form will write, read-only, as it changes (a
//          narrow window: a Form | Note toggle instead).
//
// "Edit as note" turns the sheet into the note's text, editable (Edit job:
// the real note, `## Recent runs` too); Create/Save checks it with the job
// note parser and says what is wrong. "Back to form" reads the text into the
// form again (it stays in note mode while the text does not read). One mode
// at a time.
//
// Opened by the Jobs tab's New job (+), "New job…" under the selected
// project and on a project's menu (that project preselected), a Jobs group's
// "+", the palette's New job, and a job's Edit (its row and menu). Esc or
// Cancel closes it and changes nothing. The writes are Job_Save (the
// user's); scripts open it with job_sheet.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

Job_Sheet :: struct {
	open:        bool,
	job:         string, // a job's id: edit it ("" = a new job)
	for_project: string, // a new job's owner, preselected
}

Sheet_Field :: enum u8 {
	Name,
	Every_N,
	At,
	Custom,
	Prompt,
	Model,
	Hours,
	Max_Cost,
	Timeout,
	Max_Turns,
	Note, // note mode: the whole note
}
SHEET_FIELD_LABELS := [Sheet_Field]string {
	.Name      = "Name",
	.Every_N   = "Every",
	.At        = "At",
	.Custom    = "Schedule",
	.Prompt    = "Prompt",
	.Model     = "Model",
	.Hours     = "Hours",
	.Max_Cost  = "Max cost",
	.Timeout   = "Timeout",
	.Max_Turns = "Max turns",
	.Note      = "Note",
}
SHEET_FIELD_HINTS := [Sheet_Field]string {
	.Name      = "Morning PR triage",
	.Every_N   = "2",
	.At        = "07:00",
	.Custom    = `cron "0 7 * * 1-5", "every 30m" or "at 2026-11-03 09:00"`,
	.Prompt    = "What should pi do, and what should its summary say?",
	.Model     = "provider/id (default: Atlas's model)",
	.Hours     = `"07-22": only start in these hours`,
	.Max_Cost  = "0.50 (USD per run)",
	.Timeout   = "20m",
	.Max_Turns = "40",
	.Note      = "",
}

JOB_ACCESS_CHOICES := [?]string{"read", "full"}
JOB_NOTIFY_CHOICES := [?]string{"always", "attention", "never"}
SHEET_OWNER_MAX :: 40 // projects listed in the picker

Sheet_Hit_Kind :: enum u8 {
	Field, // index: Sheet_Field
	Owner, // index: the choice
	Preset, // index: Sched_Preset
	Access,
	Notify,
	Advanced,
	Mode, // Edit as note / Back to form
	Preview, // the narrow toggle
	Cancel,
	Save,
	Reload, // the note changed on disk: read it again
}
Hit_Job_Sheet :: struct {
	what:  Sheet_Hit_Kind,
	index: int,
}

Job_Sheet_UI :: struct {
	open:         bool, // its own state: a focus change elsewhere does not drop the user's edits
	start:        string, // heap: the note as the sheet showed it when opened (changed since: Cancel asks)
	discard:      bool, // Cancel / Esc asked "Discard your changes?"; again discards
	stale:        bool, // Save was refused: the note changed on disk since it was read (Reload shows)
	reload_armed: bool, // Reload asked "Discard your changes and load the new version?"; again loads
	path:         string, // heap: the note edited ("" = new)
	orig:         string, // heap: its text when opened (Save refuses when the file changed since)
	base:         string, // heap: the note the form is written into ("" = a new one from the template)
	id, date:     string, // heap: a new note's
	fields:       [Sheet_Field]Text_Field,
	focus:        Sheet_Field,
	owner:        string, // heap: the for_project value
	folder:       string, // heap: folder: as written
	preset:       Sched_Preset,
	access:       int,
	notify:       int,
	advanced:     bool,
	note_mode:    bool,
	show_note:    bool, // narrow: the preview instead of the form
	err:          string, // heap
	choices:      [dynamic]Sheet_Owner, // drawn owner rows
	caret_shown:  string, // the focused field's text as laid out this frame (temp allocator; "" = none)
	caret_at:     int, // the caret's byte offset in caret_shown
}
Sheet_Owner :: struct {
	label, value, folder: string, // heap
}
job_sheet: Job_Sheet_UI

job_sheet_open :: proc() -> bool {return job_sheet.open}

@(private = "file")
set_s :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

@(private = "file")
fset :: proc(f: Sheet_Field, s: string) {
	tf := &job_sheet.fields[f]
	tf.multiline = f == .Prompt || f == .Note
	tf_set(tf, s)
	tf.anchor = tf.cursor
}

@(private = "file")
ftext :: proc(f: Sheet_Field) -> string {return tf_text(&job_sheet.fields[f])}

// The owner choices: projects (shown ones, the selected first, then by
// recent activity), then Atlas, Chats, None.
@(private = "file")
sheet_owners_build :: proc() {
	u := &job_sheet
	for c in u.choices {
		delete(c.label)
		delete(c.value)
		delete(c.folder)
	}
	clear(&u.choices)
	ps := make([dynamic]^Project, context.temp_allocator)
	for &p in state.projects do if p.group == .Projects && project_hide_reason(p) == .None do append(&ps, &p)
	slice.sort_by(ps[:], proc(a, b: ^Project) -> bool {
		if (a.id == state.selected_project) != (b.id == state.selected_project) do return a.id == state.selected_project
		return project_active(a^) > project_active(b^)
	})
	add :: proc(label, value, folder: string) {append(&job_sheet.choices, Sheet_Owner{strings.clone(label), strings.clone(value), strings.clone(folder)})}
	found := false
	for p, i in ps {
		if i >= SHEET_OWNER_MAX do break
		t := path_tilde(p.cwd)
		if t == u.owner do found = true
		add(project_display(p^), t, t)
	}
	// the note's own project, also when it is not among them (hidden, named)
	if !found && u.owner != "" && !slice.contains([]string{"atlas", "chats", "none"}, strings.to_lower(u.owner, context.temp_allocator)) {
		label := u.owner
		if pp, _ := owner_project_named(u.owner, owner_projects()); pp != nil do label = pp.shown
		inject_at(&u.choices, 0, Sheet_Owner{strings.clone(label), strings.clone(u.owner), strings.clone(u.folder)})
	}
	if a := folder_of(.Atlas); a != "" do add(agent_name(), "atlas", path_tilde(a))
	add("Chats", "chats", path_tilde(folder_of(.Chats)))
	add("None", "none", "~")
}

// The form as the fields say now; err: a field that is not right.
job_sheet_form :: proc() -> (f: Job_Form, err: string) {
	u := &job_sheet
	f.name = strings.trim_space(ftext(.Name))
	f.for_project = u.owner
	f.folder = u.folder
	f.prompt = ftext(.Prompt)
	f.access = JOB_ACCESS_CHOICES[clamp(u.access, 0, len(JOB_ACCESS_CHOICES) - 1)]
	f.notify = JOB_NOTIFY_CHOICES[clamp(u.notify, 0, len(JOB_NOTIFY_CHOICES) - 1)]
	f.model, f.hours, f.max_cost = strings.trim_space(ftext(.Model)), strings.trim_space(ftext(.Hours)), strings.trim_space(ftext(.Max_Cost))
	f.timeout, f.max_turns = strings.trim_space(ftext(.Timeout)), strings.trim_space(ftext(.Max_Turns))
	f.schedule, err = sched_preset_text(u.preset, ftext(.Every_N), ftext(.At), ftext(.Custom))
	return
}

// The note the sheet would write now, and what is wrong with it ("" = it
// parses). lenient: the form's own checks are skipped (Edit as note).
job_sheet_note :: proc(lenient := false) -> (text, err: string) {
	u := &job_sheet
	if u.note_mode do text = ftext(.Note)
	else {
		f, ferr := job_sheet_form()
		if ferr != "" && !lenient do return "", ferr
		if f.schedule == "" do f.schedule = "manual"
		if u.base != "" do text, err = job_note_apply_form(u.base, f, check = !lenient)
		else do text, err = job_form_new_note(f, u.id, u.date, check = !lenient)
		if err != "" do return text, err
	}
	d := job_parse(text, u.path != "" ? u.path : "/new.md", context.temp_allocator)
	return text, d.err
}

// Fills the fields from a form.
@(private = "file")
sheet_fill :: proc(f: Job_Form) {
	u := &job_sheet
	fset(.Name, f.name)
	fset(.Prompt, f.prompt)
	set_s(&u.owner, f.for_project)
	set_s(&u.folder, f.folder != "" ? f.folder : "~")
	p, n, at := sched_preset_detect(f.schedule)
	u.preset = p
	fset(.Every_N, n != "" ? n : "2")
	fset(.At, at != "" ? at : "07:00")
	fset(.Custom, p == .Custom ? f.schedule : "")
	u.access = f.access == "full" ? 1 : 0
	u.notify = 0
	for c, i in JOB_NOTIFY_CHOICES do if c == f.notify do u.notify = i
	fset(.Model, f.model)
	fset(.Hours, f.hours)
	fset(.Max_Cost, f.max_cost)
	fset(.Timeout, f.timeout)
	fset(.Max_Turns, f.max_turns)
	u.advanced = f.model != "" || f.hours != "" || f.max_cost != "" || f.timeout != "" || f.max_turns != ""
	sheet_owners_build()
}

// The job_sheet command (commands.odin): open (new or edit) or close.
job_sheet_apply :: proc(c: Job_Sheet, caller: Caller) -> (Result, bool) {
	u := &job_sheet
	if !c.open {
		if !job_sheet_open() do return {ok = true}, false
		u.open = false
		run_command(Focus_Release{widget = "job_sheet"})
		return {ok = true}, true
	}
	if harness_run_holds_sheet() do return fail("an install is running on the setup sheet: wait for it, or ⌃C in its terminal"), false
	// open already: the user's fields stay (save or cancel it first)
	if job_sheet_open() do return fail("the job sheet is open (save or cancel it first)"), false
	if folder_of(.Jobs) == "" do return fail("no main folder (Set up Deckhand…, in the Jobs tab)"), false
	set_s(&u.err, "")
	set_s(&u.path, "")
	set_s(&u.orig, "")
	set_s(&u.base, "")
	u.note_mode, u.show_note, u.focus = false, false, .Name
	id, date := job_new_id_date()
	set_s(&u.id, id)
	set_s(&u.date, date)
	if c.job != "" {
		path := ""
		for r in state.jobs do if r.id == c.job do path = r.path
		if path == "" do return fail("no such job"), false
		if err := sheet_load(path); err != "" do return fail(err), false
	} else {
		owner, folder, oerr := job_owner_for_create(c.for_project)
		if oerr != "" do owner, folder = "none", "~"
		if c.for_project == "" do owner, folder = "none", "~"
		sheet_fill({for_project = owner, folder = folder, schedule = "manual", access = "read", notify = "always"})
		fset(.Note, "")
	}
	set_s(&u.start, sheet_now_text())
	u.discard, u.stale, u.reload_armed = false, false, false
	u.open = true
	run_command(Focus_Move{widget = "job_sheet"})
	app.redraw = true
	return {ok = true}, true
}

// Reads the job's note into the sheet: the form, or its text when it does
// not read as one. "" or why not.
@(private = "file")
sheet_load :: proc(path_: string) -> string {
	u := &job_sheet
	path := strings.clone(path_, context.temp_allocator) // path_ may be u.path, which set_s frees
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return fmt.tprintf("could not read %s", fs_display(path))
	set_s(&u.err, "")
	set_s(&u.path, path)
	set_s(&u.orig, string(data))
	set_s(&u.base, string(data))
	u.note_mode, u.focus = false, .Name
	f, ferr := job_form_from_note(string(data))
	if ferr != "" { 	// the note does not read as a form: its text
		sheet_fill({access = "read", notify = "always"})
		u.note_mode = true
		fset(.Note, string(data))
		u.focus = .Note
		set_s(&u.err, fmt.tprintf("The note does not read as a form (%s): edit it as a note", ferr))
	} else {
		sheet_fill(f)
		fset(.Note, "")
	}
	return ""
}

// Reload (after a refused Save): the note as it is on disk now; with changes
// in the sheet, asks first (again: loads).
@(private = "file")
sheet_reload :: proc() {
	u := &job_sheet
	if u.path == "" do return
	if !u.reload_armed && sheet_now_text() != u.start {
		u.reload_armed = true
		return
	}
	if err := sheet_load(u.path); err != "" {
		set_s(&u.err, err)
		u.reload_armed = false
		return
	}
	set_s(&u.start, sheet_now_text())
	u.stale, u.reload_armed, u.discard = false, false, false
}

// Job_Save's answer for the sheet (jobs.odin): closed (true: Job_Save shows the Jobs tab), the
// job's row open; or why not (the note changed on disk: Reload shows; the fields stay).
job_sheet_saved :: proc(path, err: string) -> bool {
	if !job_sheet_open() do return false
	if err == JOB_NOTE_STALE {
		job_sheet.stale = true
		set_s(&job_sheet.err, "")
		return false
	}
	if err != "" {
		set_s(&job_sheet.err, err)
		return false
	}
	job_sheet.open = false
	run_command(Focus_Release{widget = "job_sheet"})
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
		if vals, _, ok := note_front_values(string(data)); ok do jobs_ui_set(vals["id"], false)
	}
	return true
}

// Create / Save.
@(private = "file")
sheet_save :: proc() {
	u := &job_sheet
	text, err := job_sheet_note()
	if err != "" {
		set_s(&u.err, err)
		return
	}
	// an edit names the note it started from; jobs.odin refuses it (on the
	// main thread) when the file changed since: job_sheet_saved
	based_on := u.path != "" ? job_note_hash(u.orig) : ""
	set_s(&u.err, "")
	ui_do(Job_Save{path = u.path, text = text, based_on = based_on})
}

// The note as the sheet shows it now (the form's, leniently; or the text).
@(private = "file")
sheet_now_text :: proc() -> string {
	if job_sheet.note_mode do return ftext(.Note)
	text, _ := job_sheet_note(lenient = true)
	return text
}

// Quit (commands.odin) while the sheet has changes: the sheet asks
// "Discard your changes?" and the quit stops; asked already: it goes on.
job_sheet_holds_quit :: proc() -> bool {
	u := &job_sheet
	if !u.open || u.discard || sheet_now_text() == u.start do return false
	u.discard = true
	app.redraw = true
	return true
}

// Cancel / Esc: closes; with changes, asks first (again: discards).
@(private = "file")
sheet_cancel :: proc() {
	u := &job_sheet
	if !u.discard && sheet_now_text() != u.start {
		u.discard = true
		return
	}
	ui_do(Job_Sheet{open = false})
}

// Edit as note / Back to form.
@(private = "file")
sheet_mode :: proc() {
	u := &job_sheet
	if !u.note_mode {
		text, _ := job_sheet_note(lenient = true)
		if text == "" do text = u.base
		fset(.Note, text)
		u.note_mode, u.focus = true, .Note
		set_s(&u.err, "")
		return
	}
	text := ftext(.Note)
	f, err := job_form_from_note(text)
	if err == "" do err = job_form_check(f)
	if err != "" {
		set_s(&u.err, fmt.tprintf("Stays a note: %s", err))
		return
	}
	set_s(&u.base, text)
	sheet_fill(f)
	u.note_mode, u.focus = false, .Name
	set_s(&u.err, "")
}

@(private = "file")
sheet_pick_owner :: proc(i: int) {
	u := &job_sheet
	if i < 0 || i >= len(u.choices) do return
	c := u.choices[i]
	if c.value == u.owner do return
	set_s(&u.owner, c.value)
	set_s(&u.folder, c.folder)
}

// ---- layout ----

@(private = "file")
sheet_label :: proc(text: string, w: f32) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingFixed(w), clay.SizingFit({min = px(BUTTON_H)})}, childAlignment = {y = .Center}}}) {
		clay.TextDynamic(text, txt(th.text_secondary, FONT_UI_SMALL))
	}
}

// A field: its text with a caret while it has the keyboard, else its hint.
@(private = "file")
sheet_field :: proc(f: Sheet_Field, min_h: f32 = 0, mono := false) {
	th := theme()
	u := &job_sheet
	id := clay.ID("jsfield", u32(f))
	focused := u.focus == f
	hov := ui_hover == Hit(Hit_Job_Sheet{what = .Field, index = int(f)})
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit({min = max(px(BUTTON_H), min_h)})}, padding = {pu(SP_2), pu(SP_2), pu(SP_1), pu(SP_1)}, childAlignment = {y = min_h > 0 ? .Top : .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(focused ? th.accent : mix(th.border, th.text_muted, hov ? 0.5 : 0)), width = clay.BorderOutside(pu(focused ? FOCUS_RING_W : BORDER_W))},
	}) {
		tf := &u.fields[f]
		s := tf_text(tf)
		font: u16 = mono ? FONT_MONO : FONT_UI
		if s == "" && !focused {
			cfg := txt(th.text_muted, FONT_UI_SMALL)
			cfg.wrapMode = .Words
			clay.TextDynamic(SHEET_FIELD_HINTS[f], cfg)
		} else {
			shown := s
			// an input method's composition shows at the caret until committed
			if focused {
				shown = strings.concatenate({s[:tf.cursor], ime.marked, "▏", s[tf.cursor:]}, context.temp_allocator)
				// for the candidate window (job_sheet_caret_rect): the composition's caret
				u.caret_shown, u.caret_at = shown, tf.cursor + clamp(ime.caret, 0, len(ime.marked))
			}
			cfg := txt(th.text, font)
			cfg.wrapMode = tf.multiline && !mono ? .Words : .Newlines
			if clay.UI(focused ? clay.ID("jstext") : clay.ID("jstext_idle", u32(f)))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {
				clay.TextDynamic(shown, cfg)
			}
		}
	}
}

// A row of choices (presets, access, notify).
@(private = "file")
sheet_chips :: proc(what: Sheet_Hit_Kind, labels: []string, selected: int, first := 0) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_1)}}) {
		for l, j in labels {
			i := first + j
			id := clay.ID(SHEET_CHIP_IDS[what], u32(i))
			on := i == selected
			bg, em := overlay(id, on, ui_hover == Hit(Hit_Job_Sheet{what = what, index = i}))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(CHIP_H))}, padding = {pu(CHIP_PAD), pu(CHIP_PAD), 0, 0}, childAlignment = {y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(CHIP_H / 2)),
				border = {color = cc(on ? th.accent : th.border), width = clay.BorderOutside(pu(BORDER_W))},
			}) {
				clay.TextDynamic(l, txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
			}
		}
	}
}

SHEET_CHIP_IDS := [Sheet_Hit_Kind]string {
	.Preset  = "jspreset",
	.Access  = "jsaccess",
	.Notify  = "jsnotify",
	.Preview = "jspreview",
	.Field = "", .Owner = "", .Advanced = "", .Mode = "", .Cancel = "", .Save = "", .Reload = "",
}

@(private = "file")
sheet_form :: proc(lw: f32) {
	th := theme()
	u := &job_sheet
	row :: proc(label: string, lw: f32) -> clay.ElementDeclaration {
		return {layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Top}}}
	}
	if clay.UI()(row("", lw)) {
		sheet_label("Name", lw)
		sheet_field(.Name)
	}
	if clay.UI()(row("", lw)) {
		sheet_label("Project", lw)
		if clay.UI(clay.ID("jsowners"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(5 * SHEET_ROW_H + 2 * SP_1))}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_1))},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
			border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			for c, i in u.choices {
				id := clay.ID("jsowner", u32(i))
				on := c.value == u.owner
				bg, em := overlay(id, on, ui_hover == Hit(Hit_Job_Sheet{what = .Owner, index = i}))
				if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(SHEET_ROW_H))}, padding = {pu(SP_1), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}, backgroundColor = bg, cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM))}) {
					clay.TextDynamic(on ? "●" : "○", txt(on ? th.accent : th.text_muted, FONT_UI_SMALL))
					clay.TextDynamic(c.label, txt(mix(th.text_secondary, th.text, max(em, on ? 1 : 0)), FONT_UI_SMALL))
					spacer()
					clay.TextDynamic(c.folder, txt(th.text_muted, FONT_UI_SMALL))
				}
			}
		}
	}
	if clay.UI()(row("", lw)) {
		sheet_label("Schedule", lw)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = pu(SP_1)}}) {
			labels: [len(Sched_Preset)]string
			for p in Sched_Preset do labels[p] = SCHED_PRESET_LABELS[p]
			sheet_chips(.Preset, labels[:3], int(u.preset))
			sheet_chips(.Preset, labels[3:], int(u.preset), 3)
			#partial switch u.preset {
			case .Every_Hours: if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
					sheet_field(.Every_N)
					clay.TextDynamic("hours", txt(th.text_secondary, FONT_UI_SMALL))
				}
			case .Daily, .Weekdays: if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
					clay.TextDynamic("at", txt(th.text_secondary, FONT_UI_SMALL))
					sheet_field(.At)
				}
			case .Custom: sheet_field(.Custom)
			}
			f, ferr := job_sheet_form()
			line, ok := ferr != "" ? ferr : "", ferr == ""
			if ok do line, ok = sched_next_text(f.schedule)
			cfg := txt(ok ? th.text_muted : th.error, FONT_UI_SMALL)
			cfg.wrapMode = .Words
			clay.TextDynamic(line, cfg)
		}
	}
	if clay.UI()(row("", lw)) {
		sheet_label("Prompt", lw)
		sheet_field(.Prompt, px(5 * SHEET_ROW_H))
	}
	if clay.UI()(row("", lw)) {
		sheet_label("Access", lw)
		sheet_chips(.Access, {"Read (look only)", "Full (pi's tools)"}, u.access)
	}
	if clay.UI()(row("", lw)) {
		sheet_label("Notify", lw)
		sheet_chips(.Notify, JOB_NOTIFY_CHOICES[:], u.notify)
	}
	id := clay.ID("jsadvanced")
	_, em := overlay(id, false, ui_hover == Hit(Hit_Job_Sheet{what = .Advanced}))
	if clay.UI(id)({layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SHEET_ROW_H))}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
		icon(u.advanced ? .Chevron_Down : .Chevron_Right, mix(th.text_muted, th.text, em), ICON_SIZE_SM)
		clay.TextDynamic("Advanced: model, hours, limits", txt(mix(th.text_secondary, th.text, em), FONT_UI_SMALL))
	}
	if u.advanced {
		for f in ([]Sheet_Field{.Model, .Hours, .Max_Cost, .Timeout, .Max_Turns}) {
			if clay.UI()(row("", lw)) {
				sheet_label(SHEET_FIELD_LABELS[f], lw)
				sheet_field(f)
			}
		}
	}
}

job_sheet_layout :: proc(w, h: f32) {
	job_sheet.caret_shown = "" // set again by the focused field
	if !job_sheet_open() do return
	th := theme()
	u := &job_sheet
	box_w := min(px(1000), w - px(2 * SP_4))
	box_h := h - px(SHEET_TOP / 2 + SP_4)
	narrow := box_w < px(760)
	lw := px(72)
	if clay.UI(clay.ID("jobsheet_scrim"))({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = {0, 0, pu(SHEET_TOP / 2), pu(SP_4)}, childAlignment = {x = .Center}},
		backgroundColor = cc(th.scrim),
		floating = {attachTo = .Root, zIndex = 10},
	}) {
		if clay.UI(clay.ID("jobsheet_box"))({
			layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFixed(box_h)}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_3)), childGap = pu(SP_2)},
			backgroundColor = cc(th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
			border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		}) {
			title := u.path != "" ? "Edit job" : "New job"
			if clay.UI(clay.ID("jobsheet_head"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_1), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				clay.TextDynamic(title, txt(th.text, WEIGHT_BOLD))
				if u.path != "" do clay.TextDynamic(fs_display(u.path), txt(th.text_muted, FONT_UI_SMALL))
				spacer()
				if narrow && !u.note_mode do sheet_chips(.Preview, {"Form", "Note"}, u.show_note ? 1 : 0)
			}
			if clay.UI(clay.ID("jobsheet_body"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childGap = pu(SP_3)}}) {
				if u.note_mode {
					if clay.UI(clay.ID("jobsheet_left"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}, clip = {vertical = true, childOffset = clay.GetScrollOffset()}}) {
						sheet_field(.Note, box_h - px(HEADER_H + BUTTON_H + 6 * SP_3), mono = true)
					}
				} else {
					if !narrow || !u.show_note {
						if clay.UI(clay.ID("jobsheet_left"))({layout = {sizing = {narrow ? clay.SizingGrow() : clay.SizingPercent(0.55), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = pu(SP_2)}, clip = {vertical = true, childOffset = clay.GetScrollOffset()}}) {
							sheet_form(lw)
						}
					}
					if !narrow || u.show_note {
						if clay.UI(clay.ID("jobsheet_preview"))({
							layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_2))},
							backgroundColor = cc(th.bg_field),
							cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
							clip = {vertical = true, horizontal = true, childOffset = clay.GetScrollOffset()},
						}) {
							text, _ := job_sheet_note(lenient = true)
							cfg := txt(th.text_secondary, FONT_MONO)
							cfg.wrapMode = .Newlines
							clay.TextDynamic(text, cfg)
						}
					}
				}
			}
			// the footer: what is wrong (or the next run), the buttons
			_, verr := job_sheet_note()
			msg := u.discard ? "Discard your changes? Cancel or Esc again discards them" : u.reload_armed ? "Discard your changes and load the new version? Reload again loads it" : u.stale ? "This job's note changed on disk since you opened it. Reload reads it again (your changes here go)" : u.err != "" ? u.err : verr
			if clay.UI(clay.ID("jobsheet_foot"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				button(clay.ID("jsbtn", u32(Sheet_Hit_Kind.Mode)), u.note_mode ? "Back to form" : "Edit as note", false, ui_hover == Hit(Hit_Job_Sheet{what = .Mode}))
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_1), pu(SP_1), 0, 0}}}) {
					cfg := txt(msg != "" ? th.error : th.text_muted, FONT_UI_SMALL)
					cfg.wrapMode = .Words
					clay.TextDynamic(msg != "" ? msg : (u.path != "" ? "Save rewrites the note's settings, title and prompt; the rest stays" : "Create writes the job's note in the jobs folder"), cfg)
				}
				if u.stale do button(clay.ID("jsbtn", u32(Sheet_Hit_Kind.Reload)), "Reload", false, ui_hover == Hit(Hit_Job_Sheet{what = .Reload}))
				button(clay.ID("jsbtn", u32(Sheet_Hit_Kind.Cancel)), u.discard ? "Discard" : "Cancel", false, ui_hover == Hit(Hit_Job_Sheet{what = .Cancel}))
				button(clay.ID("jsbtn", u32(Sheet_Hit_Kind.Save)), u.path != "" ? "Save" : "Create", true, ui_hover == Hit(Hit_Job_Sheet{what = .Save}))
			}
		}
	}
}

// ---- input ----

job_sheet_hit :: proc() -> Hit {
	for k in ([]Sheet_Hit_Kind{.Mode, .Cancel, .Save, .Reload}) do if clay.PointerOver(clay.ID("jsbtn", u32(k))) do return Hit_Job_Sheet{what = k}
	for i in 0 ..< 2 do if clay.PointerOver(clay.ID("jspreview", u32(i))) do return Hit_Job_Sheet{what = .Preview, index = i}
	if clay.PointerOver(clay.ID("jsadvanced")) do return Hit_Job_Sheet{what = .Advanced}
	for f in Sheet_Field do if clay.PointerOver(clay.ID("jsfield", u32(f))) do return Hit_Job_Sheet{what = .Field, index = int(f)}
	for _, i in job_sheet.choices do if clay.PointerOver(clay.ID("jsowner", u32(i))) do return Hit_Job_Sheet{what = .Owner, index = i}
	for i in 0 ..< len(Sched_Preset) do if clay.PointerOver(clay.ID("jspreset", u32(i))) do return Hit_Job_Sheet{what = .Preset, index = i}
	for i in 0 ..< len(JOB_ACCESS_CHOICES) do if clay.PointerOver(clay.ID("jsaccess", u32(i))) do return Hit_Job_Sheet{what = .Access, index = i}
	for i in 0 ..< len(JOB_NOTIFY_CHOICES) do if clay.PointerOver(clay.ID("jsnotify", u32(i))) do return Hit_Job_Sheet{what = .Notify, index = i}
	return nil
}


job_sheet_tip :: proc(h: Hit_Job_Sheet) -> (string, string) {
	switch h.what {
	case .Field:    return "", ""
	case .Owner:    return "The project the job belongs to: it runs in that folder", ""
	case .Preset:   return "When it runs", ""
	case .Access:   return h.index == 0 ? "Read: pi's read-only tools" : "Full: pi's normal tools (its guardrails block what would ask you)", ""
	case .Notify:   return "When a run raises a macOS notification", ""
	case .Advanced: return "Model, hours and limits", ""
	case .Mode:     return job_sheet.note_mode ? "Read the note into the form again" : "Edit the note's text itself", ""
	case .Preview:  return "Show the form or the note", ""
	case .Cancel:   return "Close without changing anything", "Esc"
	case .Reload:   return "Read the note as it is on disk now", ""
	case .Save:     return job_sheet.path != "" ? "Save the note" : "Write the job's note", "⌘↩"
	}
	return "", ""
}

@(private = "file")
sheet_click :: proc(h: Hit_Job_Sheet) {
	u := &job_sheet
	switch h.what {
	case .Field:
		u.focus = Sheet_Field(h.index)
		tf := &u.fields[u.focus]
		tf.cursor = len(tf.buf)
		tf.anchor = tf.cursor
	case .Owner:    sheet_pick_owner(h.index)
	case .Preset:
		u.preset = Sched_Preset(clamp(h.index, 0, len(Sched_Preset) - 1))
		// the preset's own field takes the keyboard; a hidden one gives it back
		to := u.focus
		switch u.preset {
		case .Every_Hours:     to = .Every_N
		case .Daily, .Weekdays: to = .At
		case .Custom:          to = .Custom
		case .Manual, .Hourly: if u.focus == .Every_N || u.focus == .At || u.focus == .Custom do to = .Name
		}
		if to != u.focus {
			u.focus = to
			nf := &u.fields[to]
			nf.cursor = len(nf.buf)
			nf.anchor = nf.cursor
		}
	case .Access:   u.access = h.index
	case .Notify:   u.notify = h.index
	case .Advanced: u.advanced = !u.advanced
	case .Mode:     sheet_mode()
	case .Preview:  u.show_note = h.index == 1
	case .Cancel:   sheet_cancel()
	case .Reload:   sheet_reload()
	case .Save:     sheet_save()
	}
}

// The fields Tab steps through, in order (the shown ones).
@(private = "file")
sheet_tab_order :: proc() -> []Sheet_Field {
	u := &job_sheet
	out := make([dynamic]Sheet_Field, context.temp_allocator)
	if u.note_mode {
		append(&out, Sheet_Field.Note)
		return out[:]
	}
	append(&out, Sheet_Field.Name)
	#partial switch u.preset {
	case .Every_Hours:      append(&out, Sheet_Field.Every_N)
	case .Daily, .Weekdays: append(&out, Sheet_Field.At)
	case .Custom:           append(&out, Sheet_Field.Custom)
	}
	append(&out, Sheet_Field.Prompt)
	if u.advanced do append(&out, Sheet_Field.Model, Sheet_Field.Hours, Sheet_Field.Max_Cost, Sheet_Field.Timeout, Sheet_Field.Max_Turns)
	return out[:]
}

// A multi-line field's cursor one line up or down, at the same column.
@(private = "file")
tf_line_move :: proc(f: ^Text_Field, d: int) {
	s := tf_text(f)
	start := strings.last_index_byte(s[:f.cursor], '\n') + 1
	col := f.cursor - start
	if d < 0 {
		if start == 0 do f.cursor = 0
		else {
			prev := strings.last_index_byte(s[:start - 1], '\n') + 1
			f.cursor = min(prev + col, start - 1)
		}
	} else {
		nl := strings.index_byte(s[f.cursor:], '\n')
		if nl < 0 do f.cursor = len(s)
		else {
			next := f.cursor + nl + 1
			end := strings.index_byte(s[next:], '\n')
			line_end := end < 0 ? len(s) : next + end
			f.cursor = min(next + col, line_end)
		}
	}
	for f.cursor > 0 && f.cursor < len(s) && (s[f.cursor] & 0xC0) == 0x80 do f.cursor -= 1
	f.anchor = f.cursor
}

// Input while the sheet shows: it takes everything but ⌘Q.
job_sheet_event :: proc(e: ^sapp.Event) -> bool {
	u := &job_sheet
	f := &u.fields[u.focus]
	cmd := e.modifiers & sapp.MODIFIER_SUPER != 0
	alt := e.modifiers & sapp.MODIFIER_ALT != 0
	shift := e.modifiers & sapp.MODIFIER_SHIFT != 0
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		if e.key_code != .ESCAPE && e.key_code != .LEFT_SHIFT && e.key_code != .RIGHT_SHIFT && e.key_code != .LEFT_SUPER && e.key_code != .RIGHT_SUPER {u.discard, u.reload_armed = false, false} // anything else: the question is gone
		if cmd {
			app.key_taken = true // its CHAR goes nowhere
			#partial switch e.key_code {
			case .Q:                return false
			case .ENTER, .KP_ENTER: sheet_save()
			case .A:                tf_select_all(f)
			case .C:                if s := tf_selected_text(f); s != "" && platform.set_clipboard != nil do platform.set_clipboard(s)
			case .LEFT:             tf_home(f, shift)
			case .RIGHT:            tf_end(f, shift)
			case .BACKSPACE:        tf_delete_to_start(f)
			}
			return true
		}
		// a key it acts on: its CHAR (if any) goes nowhere; a printable
		// key's CHAR types into the field
		#partial switch e.key_code {
		case .ESCAPE, .TAB, .ENTER, .KP_ENTER, .BACKSPACE, .DELETE: app.key_taken = true
		}
		#partial switch e.key_code {
		case .ESCAPE: sheet_cancel()
		case .TAB:
			order := sheet_tab_order()
			at := 0
			for x, i in order do if x == u.focus do at = i
			u.focus = order[(at + (shift ? len(order) - 1 : 1)) % len(order)]
			nf := &u.fields[u.focus]
			nf.cursor = len(nf.buf)
			nf.anchor = nf.cursor
		case .ENTER, .KP_ENTER:
			if f.multiline do tf_insert(f, "\n")
			else do sheet_save()
		case .BACKSPACE: if alt do tf_delete_word_left(f); else do tf_backspace(f)
		case .DELETE:    tf_delete(f)
		case .LEFT:      if alt do tf_word_left(f, shift); else do tf_move(f, -1, shift)
		case .RIGHT:     if alt do tf_word_right(f, shift); else do tf_move(f, 1, shift)
		case .HOME:      tf_home(f, shift)
		case .END:       tf_end(f, shift)
		case .UP:        if f.multiline do tf_line_move(f, -1); else do tf_home(f, shift)
		case .DOWN:      if f.multiline do tf_line_move(f, 1); else do tf_end(f, shift)
		}
		return true
	case .CHAR:
		if !cmd && e.char_code >= 0x20 && e.char_code != 0x7f {
			if r, ok := utf16_unit(&app_surrogate, e.char_code); ok do tf_insert(f, utf8_string(r))
		}
		app.redraw = true
		return true
	case .CLIPBOARD_PASTED:
		tf_insert(f, clipboard_text())
		app.redraw = true
		return true
	case .MOUSE_MOVE:
		set_hover(chrome_hit({e.mouse_x, e.mouse_y}), false)
		return true
	case .MOUSE_DOWN:
		h, ok := chrome_hit({e.mouse_x, e.mouse_y}).(Hit_Job_Sheet)
		if !ok || h.what != .Cancel do u.discard = false
		if !ok || h.what != .Reload do u.reload_armed = false
		if ok && e.mouse_button == .LEFT do sheet_click(h)
		app.redraw = true
		return true
	case .MOUSE_SCROLL:
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
		app.redraw = true
		return true
	case .KEY_UP, .MOUSE_UP:
		return true
	}
	return false
}


// The focused field's caret, for the input method's candidate window: the
// laid-out line (a Text render command: Clay's wrapped lines point into the
// string the field drew) that holds the caret, and the width before it.
job_sheet_caret_rect :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> ([4]f32, bool) {
	u := &job_sheet
	if !u.open || u.caret_shown == "" do return {}, false
	base := uintptr(raw_data(u.caret_shown))
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		td := c.renderData.text
		p := uintptr(td.stringContents.chars)
		if p < base || p >= base + uintptr(len(u.caret_shown)) do continue
		start := int(p - base)
		n := int(td.stringContents.length)
		if u.caret_at < start || u.caret_at >= start + n do continue
		kind, bold := font_id_split(td.fontId)
		b := c.boundingBox
		x := b.x + text_width(u.caret_shown[start:u.caret_at], kind, bold)
		return {x, b.y, px(CARET_W), b.height}, true
	}
	return {}, false
}
