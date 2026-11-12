package main

// The left column's Jobs tab (docs/ATLAS.md §7 "Jobs tab"): Atlas's jobs
// from State.jobs (jobs.odin). The header: New job, Pause all / Resume
// all, Limits, the unread count. Rows: a status dot, the name, the project
// (or global), next run and last result, an unread dot, warnings (paused,
// an error, a schedule more often than 30 min); a click expands a row to
// its runs (skipped ticks included), what needs the user and its buttons
// (Run now, Edit, Open note, Report). Each row's "…" (and a right click) has
// Run now, Stop, Pause/Resume, Enable/Disable, Edit, Open note, Open last
// report, Open run folder, Mark read, Delete. Jobs need no approval: a note
// runs as it says. Without a notes folder the tab asks for one. Every
// action is a command (ui_do) with a button.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core"
import clay "../build/clay-odin"

Jobs_Hit_Kind :: enum u8 {
	Tool, // index: Jobs_Tool
	Row, // index: the drawn slot
	More, // a row's "…"
	Button, // index: ju.buttons
	Limit, // index: Job_Limit_Row
	Notes_Dir, // "Set up Deckhand…" (no main folder)
	Resume_All, // the paused banner's button
	List,
	Group, // index: the drawn group: go to its project (Atlas, Chats), or fold Other
	Group_Fold, // its chevron
	Group_New, // its "+": New job for it
	Machine, // index: a machine's number (0 = this Mac): its "On <name>" header folds it
	Machine_Group, // index: another machine's drawn owner row (ju.mgroups): folds it
}
Hit_Jobs :: struct {
	what:  Jobs_Hit_Kind,
	index: int,
}

Jobs_Tool :: enum {
	New_Job,
	Pause_All,
	Limits,
}

Job_Button :: enum u8 {
	Run_Now,
	Stop,
	Edit,
	Open_Note,
	Report,
	Mark_Read,
}
JOB_BUTTON_LABELS := [Job_Button]string {
	.Run_Now   = "Run now",
	.Stop      = "Stop",
	.Edit      = "Edit",
	.Open_Note = "Open note",
	.Report    = "Last report",
	.Mark_Read = "Mark read",
}

Job_Limit_Row :: enum {
	Max_Cost,
	Timeout,
	Max_Turns,
	Day,
	Week,
	Month,
	Concurrency,
	Loop_Calls,
	Stall,
	Fail_Pause,
}
JOB_LIMIT_LABELS := [Job_Limit_Row]string {
	.Max_Cost    = "Cost per run",
	.Timeout     = "Time per run",
	.Max_Turns   = "Turns per run",
	.Day         = "Spend per day",
	.Week        = "Spend per week",
	.Month       = "Spend per month",
	.Concurrency = "Runs at once",
	.Loop_Calls  = "Looping after (same call)",
	.Stall       = "Stalled after (silence)",
	.Fail_Pause  = "Pause after failures",
}
// The values a click steps through (0 = off; the safety stops have no off).
JOB_LIMIT_STEPS := [Job_Limit_Row][]f64 {
	.Max_Cost    = {0, 0.1, 0.5, 1, 5},
	.Timeout     = {0, 300, 600, 1200, 3600},
	.Max_Turns   = {0, 20, 40, 100},
	.Day         = {0, 1, 5, 20},
	.Week        = {0, 5, 20, 100},
	.Month       = {0, 20, 50, 200},
	.Concurrency = {0, 1, 2, 4},
	.Loop_Calls  = {5, 10, 20},
	.Stall       = {600, 1200, 3600},
	.Fail_Pause  = {3, 5, 10},
}

JOB_ROW_H :: 44 // two lines

Menu_Job :: struct {
	id: string, // owned by the menu
}

@(private = "file")
Jobs_Ui :: struct {
	arena:       virtual.Arena,
	drawn:       [dynamic]string, // job ids by slot
	buttons:     [dynamic]struct {
		job:  string,
		what: Job_Button,
	},
	expanded:    string, // owned: the row shown open
	limits_open: bool,
	groups:      [dynamic]core.Job_Owner, // drawn group rows by slot (strings in the arena)
	folded:      [dynamic]string, // owned: folded groups (job_owner_key; another machine's: machine_group_key); not saved
	mgroups:     [dynamic]string, // another machine's drawn owner rows by slot: their fold keys (in the arena)
}

@(private = "file")
ju: Jobs_Ui

jobs_shown :: proc() -> bool {return state.layout.left_open && state.layout.left_tab == .Jobs}

@(private = "file")
job_row_of :: proc(id: string) -> ^core.Job_Row {
	for &r in state.jobs do if r.id == id do return &r
	return nil
}

// "in 5m", "in 3h", "in 2d" from the scheduler's clock.
@(private = "file")
rel_future :: proc(t: i64) -> string {
	d := t - core.jobs_now()
	switch {
	case d < 60:        return "now"
	case d < 3600:      return fmt.tprintf("in %dm", d / 60)
	case d < 86400:     return fmt.tprintf("in %dh", d / 3600)
	}
	return fmt.tprintf("in %dd", d / 86400)
}

// The row's second line and its colour.
@(private = "file")
job_line :: proc(r: core.Job_Row) -> (string, core.Rgba) {
	th := theme()
	switch {
	case r.err != "":  return fmt.tprintf("Error: %s", r.err), th.error
	case r.running:    return "Running…", th.running
	case r.paused:     return fmt.tprintf("Paused: %s", r.paused_why), th.waiting
	case r.queued:     return "Queued (runs at once limit)", th.text_muted
	}
	next := "manual"
	if r.schedule == "manual" do next = "manual"
	else if !r.enabled do next = "disabled"
	else if r.next_due > 0 do next = fmt.tprintf("next %s", rel_future(r.next_due))
	if r.last_status == "" do return fmt.tprintf("%s · no runs yet", next), th.text_muted
	return fmt.tprintf("%s · %s %s", next, core.job_status_icon(r.last_status), r.last_headline), th.text_muted
}

@(private = "file")
job_dot :: proc(r: core.Job_Row) -> core.Rgba {
	th := theme()
	switch {
	case r.err != "":   return th.error
	case r.running:     return status_color(.Running)
	case r.paused || len(r.needs_you) > 0: return th.waiting
	case !r.enabled:    return with_alpha(th.text_muted, EXITED_ALPHA)
	case r.last_status == "ok" || r.last_status == "quiet": return th.done
	case r.last_status != "" && r.last_status != "needs_you": return th.error
	}
	return with_alpha(th.text_muted, EXITED_ALPHA)
}

@(private = "file")
limit_value :: proc(row: Job_Limit_Row) -> f64 {
	l := state.settings.job_limits
	switch row {
	case .Max_Cost:    return l.max_cost
	case .Timeout:     return f64(l.timeout)
	case .Max_Turns:   return f64(l.max_turns)
	case .Day:         return l.day
	case .Week:        return l.week
	case .Month:       return l.month
	case .Concurrency: return f64(l.concurrency)
	case .Loop_Calls:  return f64(core.limit_loop())
	case .Stall:       return f64(core.limit_stall())
	case .Fail_Pause:  return f64(core.limit_fail())
	}
	return 0
}

limit_text :: proc(row: Job_Limit_Row, v: f64) -> string {
	if v == 0 do return "off"
	#partial switch row {
	case .Max_Cost, .Day, .Week, .Month: return fmt.tprintf("$%.2f", v)
	case .Timeout, .Stall:               return v >= 3600 ? fmt.tprintf("%.0fh", v / 3600) : v >= 60 ? fmt.tprintf("%.0fm", v / 60) : fmt.tprintf("%.0fs", v)
	case .Max_Turns:                     return fmt.tprintf("%.0f turns", v)
	case .Loop_Calls:                    return fmt.tprintf("%.0f calls", v)
	case .Fail_Pause:                    return fmt.tprintf("%.0f in a row", v)
	}
	return fmt.tprintf("%.0f", v)
}

// The command a limit's button sends: the next step after its value.
@(private = "file")
limit_next :: proc(row: Job_Limit_Row) -> core.Command {
	steps := JOB_LIMIT_STEPS[row]
	cur := limit_value(row)
	next := steps[0]
	for v, i in steps do if v == cur {
		next = steps[(i + 1) % len(steps)]
		break
	}
	c: core.Set_Job_Limits
	switch row {
	case .Max_Cost:    c.max_cost = next
	case .Timeout:     c.timeout = i64(next)
	case .Max_Turns:   c.max_turns = int(next)
	case .Day:         c.day = next
	case .Week:        c.week = next
	case .Month:       c.month = next
	case .Concurrency: c.concurrency = int(next)
	case .Loop_Calls:  c.loop_calls = int(next)
	case .Stall:       c.stall = i64(next)
	case .Fail_Pause:  c.fail_pause = int(next)
	}
	return c
}

// ---- layout ----

jobs_panel :: proc(row_w: f32) {
	th := theme()
	virtual.arena_destroy(&ju.arena)
	_ = virtual.arena_init_growing(&ju.arena)
	a := virtual.arena_allocator(&ju.arena)
	ju.drawn = make([dynamic]string, a)
	ju.buttons = make(type_of(ju.buttons), a)
	ju.groups = make([dynamic]core.Job_Owner, a)
	ju.mgroups = make([dynamic]string, a)

	// header: Jobs, unread, then the buttons
	if clay.UI(clay.ID("jobs_head"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), 0, 0, 0}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}},
	}) {
		unread := state.jobs_unread > 0 ? fmt.tprintf("%d unread", state.jobs_unread) : ""
		room := row_w - px(PAD_ROW + KIND_ICON + GAP_INLINE + GAP_GROUP) - f32(len(Jobs_Tool)) * px(FILES_TOOL + GAP_BUTTONS)
		icon(.Clock, th.text_muted, KIND_ICON)
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE - GAP_BUTTONS)), clay.SizingFit()}}}) {}
		title := clip("Jobs", room, WEIGHT_BOLD)
		clay.TextDynamic(title, txt(th.text_secondary, WEIGHT_BOLD))
		if unread != "" && text_w("Jobs", WEIGHT_BOLD) + px(GAP_INLINE) + text_w(unread, FONT_UI_SMALL) <= room {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE)), clay.SizingFit()}}}) {}
			clay.TextDynamic(unread, txt(th.accent, FONT_UI_SMALL))
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow({min = px(GAP_GROUP - 2 * GAP_BUTTONS)}), clay.SizingFit()}}}) {}
		for tool in Jobs_Tool {
			id := clay.ID("jobstool", u32(tool))
			enabled := tool != .New_Job || core.folder_of(.Jobs) != ""
			hovered := enabled && ui_hover == Hit(Hit_Jobs{what = .Tool, index = int(tool)})
			bg, em := overlay(id, tool == .Limits && ju.limits_open, hovered)
			ic: core.Icon
			switch tool {
			case .New_Job:   ic = .Plus
			case .Pause_All: ic = state.settings.jobs_paused ? .Play : .Pause
			case .Limits:    ic = .Sliders
			}
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFixed(px(FILES_TOOL)), clay.SizingFixed(px(FILES_TOOL))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				col := enabled ? mix(th.text_muted, th.text, em) : with_alpha(th.text_muted, DISABLED_ALPHA)
				icon(ic, col, ICON_SIZE_SM)
			}
		}
	}
	gap(SP_1)
	if state.settings.jobs_paused {
		if clay.UI(clay.ID("jobs_paused"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(PAD_ROW), pu(SP_1), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
			backgroundColor = cc(with_alpha(th.waiting, 0.14)),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			msg := "All jobs paused"
			room := row_w - px(PAD_ROW + SP_1 + GAP_INLINE) - text_w("Resume all") - px(2 * SP_3)
			clay.TextDynamic(clip(msg, room), txt(th.text))
			spacer()
			small_button(clay.ID("jobs_resume_all"), "Resume all", ui_hover == Hit(Hit_Jobs{what = .Resume_All}))
		}
		gap(SP_1)
	}
	if ju.limits_open do jobs_limits(row_w)
	if core.folder_of(.Jobs) == "" {
		empty_state("No main folder", "Job notes live in its jobs/ folder", row_w)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), 0, 0, 0}}}) {
			small_button(clay.ID("jobs_notes_dir"), "Set up Deckhand…", ui_hover == Hit(Hit_Jobs{what = .Notes_Dir}))
		}
		return
	}
	if clay.UI(clay.ID("jobs_list"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = pu(2)},
		clip = {vertical = true, childOffset = clay.GetScrollOffset()},
	}) {
		if len(state.jobs) == 0 && len(state.machine_jobs) == 0 do empty_state("No jobs yet", "New job (+) writes a job note", row_w)
		// this Mac's, under its name while Machines over SSH is on (as other machines' are below;
		// no header while it has none)
		if state.settings.remote_machines && len(state.jobs) > 0 do jobs_machine_header(0, core.machine_here_name(), "this Mac", fmt.tprintf("%d", len(state.jobs)), row_w)
		// grouped by owner (jobs_owner.odin): projects by name, then Atlas, Chats, Other
		if !(state.settings.remote_machines && jobs_machine_folded(0)) do for g in core.jobs_groups() {
			folded := core.list_index(ju.folded[:], core.job_owner_key(g.owner)) >= 0
			job_group_row(g, folded, row_w, a)
			if folded do continue
			for i in g.rows do job_row(state.jobs[i], g.owner, row_w, a)
		}
		machine_jobs_sections(row_w, a)
	}
}

// Other machines' jobs (machine_mirror.odin, M6-F), after this Mac's: under each machine's name,
// then under their owner there (its project, Atlas, Chats, Other: as this Mac's are grouped),
// read-only rows (what it is up to, and the first thing it needs you for). Greyed while that
// machine is not online (what it showed last). Nothing here while no machine has jobs.
@(private = "file")
machine_jobs_sections :: proc(row_w: f32, a: runtime.Allocator) {
	if len(state.machine_jobs) == 0 do return
	th := theme()
	inner := row_w - px(2 * PAD_ROW)
	for m in state.machines {
		n := 0
		for r in state.machine_jobs do if r.machine == m.no do n += 1
		if n == 0 do continue
		live := m.status == .Online
		gap(SP_2)
		label, _, _ := core.machine_status_text(m) // as the sidebar says it
		jobs_machine_header(m.no, m.name, "", live ? fmt.tprintf("%d", n) : label, row_w)
		if jobs_machine_folded(m.no) do continue
		k := 0
		for g in machine_job_groups(m.no) {
			key := machine_group_key(m.no, g.kind, g.label)
			folded := core.list_index(ju.folded[:], key) >= 0
			unread := false
			for i in g.rows do if state.machine_jobs[i].unread > 0 do unread = true
			machine_job_group_row(strings.clone(key, a), g.kind, g.label, len(g.rows), unread, folded, live, row_w)
			if folded do continue
			for i in g.rows {
				r := state.machine_jobs[i]
				k += 1
				if clay.UI(clay.ID("jobmachrow", u32(m.no) * 1000 + u32(k)))({
					layout = {sizing = {clay.SizingGrow(), clay.SizingFit({min = px(JOB_ROW_H)})}, padding = {pu(PAD_ROW), pu(PAD_ROW), pu(SP_1), pu(SP_1)}, layoutDirection = .TopToBottom, childGap = pu(2)},
				}) {
					name_col := live ? th.text : th.text_secondary
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_BUTTON))}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
						dot(live ? job_dot(r) : with_alpha(th.text_muted, EXITED_ALPHA))
						clay.TextDynamic(clip(r.name, inner - px(DOT + GAP_INLINE)), txt(name_col))
					}
					line, col := job_line(r)
					if len(r.needs_you) > 0 do line, col = fmt.tprintf("Needs you: %s", r.needs_you[0]), th.waiting
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H - 6))}, padding = {pu(DOT + GAP_INLINE), 0, 0, 0}, childAlignment = {y = .Center}}}) {
						clay.TextDynamic(clip(line, inner - px(DOT + GAP_INLINE), FONT_UI_SMALL), txt(live ? col : th.text_muted, FONT_UI_SMALL))
					}
				}
			}
		}
	}
}

// Another machine's owner group: its kind, its label as drawn, its rows (indices into
// state.machine_jobs).
@(private = "file")
Machine_Job_Group :: struct {
	kind:  core.Job_Owner_Kind,
	label: string,
	rows:  [dynamic]int,
}

// Machine no's jobs by owner, in this Mac's order: projects by name, then Atlas, Chats, Other (temp).
@(private = "file")
machine_job_groups :: proc(no: u64) -> []Machine_Job_Group {
	groups := make([dynamic]Machine_Job_Group, context.temp_allocator)
	for r, i in state.machine_jobs do if r.machine == no {
		label := r.owner == .Project ? r.project : core.job_owner_label(core.Job_Owner{kind = r.owner})
		at := -1
		for g, j in groups do if g.kind == r.owner && g.label == label do at = j
		if at < 0 {
			append(&groups, Machine_Job_Group{kind = r.owner, label = label, rows = make([dynamic]int, context.temp_allocator)})
			at = len(groups) - 1
		}
		append(&groups[at].rows, i)
	}
	slice.sort_by(groups[:], proc(a, b: Machine_Job_Group) -> bool {
		if a.kind != b.kind do return a.kind < b.kind
		return strings.to_lower(a.label, context.temp_allocator) < strings.to_lower(b.label, context.temp_allocator)
	})
	return groups[:]
}

// Its fold key (not saved; temp).
@(private = "file")
machine_group_key :: proc(no: u64, kind: core.Job_Owner_Kind, label: string) -> string {
	return fmt.tprintf("machine:%d:%s:%s", no, core.JOB_OWNER_NAMES[kind], label)
}

// Another machine's owner row, drawn as this Mac's (job_group_row): its chevron, icon, name, a dot
// while one is unread, its count. Read-only: a click folds it.
@(private = "file")
machine_job_group_row :: proc(key: string, kind: core.Job_Owner_Kind, label: string, n: int, unread, folded, live: bool, row_w: f32) {
	th := theme()
	slot := len(ju.mgroups)
	append(&ju.mgroups, key)
	id := clay.ID("jobmgroup", u32(slot))
	hovered := ui_hover == Hit(Hit_Jobs{what = .Machine_Group, index = slot})
	bg, em := overlay(id, false, hovered)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(PAD_ROW - SP_1), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(TREE_CHEVRON + SP_1)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}}}) {
			icon(folded ? .Chevron_Right : .Chevron_Down, th.text_muted, TREE_CHEVRON)
		}
		ic := core.Icon.Folder
		switch kind {
		case .Project: ic = .Folder
		case .Atlas:   ic = .Compose
		case .Chats:   ic = .Chat
		case .Other:   ic = .Clock
		}
		icon(ic, th.text_muted, KIND_ICON)
		count := fmt.tprintf("%d", n)
		right := text_w(count) + (unread ? px(DOT + GAP_INLINE) : 0)
		room := row_w - px(PAD_ROW - SP_1 + PAD_ROW + TREE_CHEVRON + SP_1 + KIND_ICON + 4 * GAP_INLINE) - right
		col := live ? mix(th.text_secondary, th.text, em) : th.text_muted
		clay.TextDynamic(clip(label, room, WEIGHT_BOLD), txt(col, WEIGHT_BOLD))
		spacer()
		if unread do dot(th.accent)
		clay.TextDynamic(count, txt(th.text_muted))
	}
}

// A machine's header in the Jobs tab: its fold chevron (a click folds it, as an owner's row folds),
// On <name>, a muted note after it ("this Mac", for no 0), and on the right its count (or its
// status while it shows what it showed last).
@(private = "file")
jobs_machine_header :: proc(no: u64, name, note, right: string, row_w: f32) {
	th := theme()
	inner := row_w - px(2 * PAD_ROW)
	id := clay.ID("jobmach", u32(no))
	bg, _ := overlay(id, false, ui_hover == Hit(Hit_Jobs{what = .Machine, index = int(no)}))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(PAD_ROW - SP_1), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(TREE_CHEVRON + SP_1)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}}}) {
			icon(jobs_machine_folded(no) ? .Chevron_Right : .Chevron_Down, th.text_muted, TREE_CHEVRON)
		}
		label := fmt.tprintf("On %s", name)
		room := inner + px(SP_1) - px(TREE_CHEVRON + SP_1) - text_w(right) - 2 * px(GAP_INLINE)
		lw := clip(label, room, WEIGHT_BOLD)
		clay.TextDynamic(lw, txt(th.text_secondary, WEIGHT_BOLD))
		if nr := room - text_w(lw, WEIGHT_BOLD) - px(GAP_INLINE); note != "" && nr > px(SP_6) do clay.TextDynamic(clip(note, nr), txt(th.text_muted))
		spacer()
		clay.TextDynamic(right, txt(th.text_muted))
	}
}

// A small text button (the row's actions, the banners').
@(private = "file")
small_button :: proc(id: clay.ElementId, label: string, hovered: bool) {
	th := theme()
	h := fade(id, 0, hovered ? 1 : 0, DUR_HOVER)
	bg := mix(th.bg_elevated, th.text, TINT_BUTTON + h * (TINT_BUTTON_HOVER - TINT_BUTTON))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(ROW_BUTTON + 4))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(bg),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		clay.TextDynamic(label, txt(th.text, FONT_UI_SMALL))
	}
}

@(private = "file")
jobs_limits :: proc(row_w: f32) {
	th := theme()
	if clay.UI(clay.ID("jobs_limits"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = {pu(SP_1), pu(SP_1), pu(SP_1), pu(SP_1)}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_1), 0, 0, 0}, childAlignment = {y = .Center}}}) {
			clay.TextDynamic(clip("Limits (off unless set) and safety stops", row_w - px(4 * SP_1)), txt(th.text_muted, FONT_UI_SMALL))
		}
		for row in Job_Limit_Row {
			id := clay.ID("joblimit", u32(row))
			value := limit_text(row, limit_value(row))
			hovered := ui_hover == Hit(Hit_Jobs{what = .Limit, index = int(row)})
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H + 2))}, padding = {pu(SP_1), 0, 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
				vw := text_w(value, FONT_UI_SMALL) + px(2 * SP_2)
				clay.TextDynamic(clip(JOB_LIMIT_LABELS[row], row_w - px(4 * SP_1 + GAP_INLINE) - vw, FONT_UI_SMALL), txt(th.text_secondary, FONT_UI_SMALL))
				spacer()
				small_button(id, value, hovered)
			}
		}
	}
	gap(SP_1)
}

// A group's row: chevron (folds), its icon and name, how many jobs, a dot
// while one is unread; on hover "+" (New job for it). A click goes to its
// project (Atlas: the drawer; Chats: the Sessions tab); Other folds.
@(private = "file")
job_group_row :: proc(g: core.Job_Group, folded: bool, row_w: f32, a: runtime.Allocator) {
	th := theme()
	slot := len(ju.groups)
	append(&ju.groups, core.Job_Owner{kind = g.owner.kind, project = g.owner.project, path = strings.clone(g.owner.path, a), name = strings.clone(g.owner.name, a)})
	id := clay.ID("jobgroup", u32(slot))
	new_hover := ui_hover == Hit(Hit_Jobs{what = .Group_New, index = slot})
	fold_hover := ui_hover == Hit(Hit_Jobs{what = .Group_Fold, index = slot})
	hovered := ui_hover == Hit(Hit_Jobs{what = .Group, index = slot}) || new_hover || fold_hover
	bg, em := overlay(id, false, hovered)
	unread := false
	for i in g.rows do if state.jobs[i].unread > 0 do unread = true
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(PAD_ROW - SP_1), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		fid := clay.ID("jobgroupfold", u32(slot))
		if clay.UI(fid)({layout = {sizing = {clay.SizingFixed(px(TREE_CHEVRON + SP_1)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}}}) {
			icon(folded ? .Chevron_Right : .Chevron_Down, fold_hover ? th.text : th.text_muted, TREE_CHEVRON)
		}
		ic := core.Icon.Folder
		switch g.owner.kind {
		case .Project: ic = .Folder
		case .Atlas:   ic = .Compose
		case .Chats:   ic = .Chat
		case .Other:   ic = .Clock
		}
		icon(ic, th.text_muted, KIND_ICON)
		count := fmt.tprintf("%d", len(g.rows))
		right := text_w(count) + (hovered ? px(ROW_BUTTON + GAP_INLINE) : 0) + (unread ? px(DOT + GAP_INLINE) : 0)
		room := row_w - px(PAD_ROW - SP_1 + PAD_ROW + TREE_CHEVRON + SP_1 + KIND_ICON + 4 * GAP_INLINE) - right
		clay.TextDynamic(clip(core.job_owner_label(g.owner), room, WEIGHT_BOLD), txt(mix(th.text_secondary, th.text, em), WEIGHT_BOLD))
		spacer()
		if unread do dot(th.accent)
		clay.TextDynamic(count, txt(th.text_muted))
		if hovered {
			nid := clay.ID("jobgroupnew", u32(slot))
			nbg, nem := overlay(nid, false, new_hover)
			if clay.UI(nid)({
				layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = nbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				icon(.Plus, mix(th.text_muted, th.text, nem), ICON_SIZE_SM)
			}
		}
	}
}

// The for_project value of a group's owner (New job for it).
@(private = "file")
owner_value :: proc(o: core.Job_Owner) -> string {
	switch o.kind {
	case .Project: return core.path_tilde(o.path)
	case .Atlas:   return "atlas"
	case .Chats:   return "chats"
	case .Other:   return "none"
	}
	return ""
}

// Whether machine no's jobs are folded (0 = this Mac's), and folding them: as the owners' rows, in
// ju.folded (not saved).
@(private = "file")
jobs_machine_folded :: proc(no: u64) -> bool {return core.list_index(ju.folded[:], fmt.tprintf("machine:%d", no)) >= 0}

@(private = "file")
jobs_machine_fold :: proc(no: u64) {
	key := fmt.tprintf("machine:%d", no)
	if at := core.list_index(ju.folded[:], key); at >= 0 {
		delete(ju.folded[at])
		ordered_remove(&ju.folded, at)
	} else do append(&ju.folded, strings.clone(key))
}

@(private = "file")
group_fold :: proc(slot: int) {
	if slot >= len(ju.groups) do return
	key := core.job_owner_key(ju.groups[slot])
	if at := core.list_index(ju.folded[:], key); at >= 0 {
		delete(ju.folded[at])
		ordered_remove(&ju.folded, at)
	} else do append(&ju.folded, strings.clone(key))
}

@(private = "file")
job_row :: proc(r: core.Job_Row, owner: core.Job_Owner, row_w: f32, a: runtime.Allocator) {
	th := theme()
	slot := len(ju.drawn)
	append(&ju.drawn, strings.clone(r.id, a))
	id := clay.ID("jobrow", u32(slot))
	open := ju.expanded != "" && ju.expanded == r.id
	hovered := ui_hover == Hit(Hit_Jobs{what = .Row, index = slot}) || ui_hover == Hit(Hit_Jobs{what = .More, index = slot})
	bg, _ := overlay(id, open, hovered)
	inner := row_w - px(2 * PAD_ROW)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit({min = px(JOB_ROW_H)})}, padding = {pu(PAD_ROW), pu(PAD_ROW), pu(SP_1), pu(SP_1)}, layoutDirection = .TopToBottom, childGap = pu(2)},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		// line 1: dot, name, project, unread, "…"
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_BUTTON))}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
			dot(job_dot(r))
			// where it runs, when that is not the group's own folder
			where_ := ""
			if owner.kind != .Project || r.folder != owner.path do where_ = core.path_tilde(r.folder)
			if owner.kind == .Project && r.folder != owner.path && core.path_within(r.folder, owner.path) do where_ = r.folder[len(owner.path) + 1:]
			right := px(DOT + GAP_INLINE + ROW_BUTTON) + (r.unread > 0 ? px(DOT + GAP_INLINE) : 0)
			name_room := inner - right - px(GAP_INLINE)
			pw := text_w(where_, FONT_UI_SMALL)
			show_where := where_ != "" && text_w(r.name) + px(GAP_INLINE) + pw <= name_room
			if show_where do name_room -= pw + px(GAP_INLINE)
			clay.TextDynamic(clip(r.name, name_room), txt(r.enabled ? th.text : th.text_secondary))
			if show_where do clay.TextDynamic(where_, txt(th.text_muted, FONT_UI_SMALL))
			spacer()
			if r.unread > 0 do dot(th.accent)
			more := clay.ID("jobmore", u32(slot))
			mh := ui_hover == Hit(Hit_Jobs{what = .More, index = slot})
			mbg, mem_ := overlay(more, false, mh)
			if clay.UI(more)({
				layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = mbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				icon(.More, mix(th.text_muted, th.text, mem_), ICON_SIZE_SM)
			}
		}
		// line 2: what it is up to
		line, col := job_line(r)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H - 6))}, padding = {pu(DOT + GAP_INLINE), 0, 0, 0}, childAlignment = {y = .Center}}}) {
			clay.TextDynamic(clip(line, inner - px(DOT + GAP_INLINE), FONT_UI_SMALL), txt(col, FONT_UI_SMALL))
		}
		if !open do return
		// the open row's text wraps: nothing it says is cut off
		small :: proc(text: string, col: core.Rgba, room: f32, mono := false) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit({min = px(FILES_ROW_H - 4)})}, padding = {pu(DOT + GAP_INLINE), 0, 2, 2}, childAlignment = {y = .Center}}}) {
				cfg := txt(col, mono ? FONT_MONO : FONT_UI_SMALL)
				cfg.wrapMode = .Words
				clay.TextDynamic(text, cfg)
			}
		}
		for w in r.warnings do small(fmt.tprintf("⚠ %s", w), th.waiting, inner)
		if w := core.job_owner_warning(core.job_owner_of(r, core.owner_projects())); w != "" do small(w, th.waiting, inner)
		if len(r.needs_you) > 0 {
			small("Needs you:", th.text_secondary, inner)
			for n in r.needs_you do small(fmt.tprintf("• %s", n), th.waiting, inner)
		}
		if len(r.recent) > 0 {
			small("Recent runs:", th.text_secondary, inner)
			for l in r.recent {
				t := strings.trim_prefix(l, "- ")
				if i := strings.index(t, " · [run]("); i >= 0 do t = t[:i]
				small(t, th.text_muted, inner)
			}
		}
		// the row's buttons, on as many lines as they need
		shown_btns := make([dynamic]Job_Button, context.temp_allocator)
		for b in Job_Button {
			show := false
			switch b {
			case .Run_Now:   show = !r.running && r.err == ""
			case .Stop:      show = r.running
			case .Edit:      show = true
			case .Open_Note: show = true
			case .Report:    show = r.last_run != ""
			case .Mark_Read: show = r.unread > 0
			}
			if show do append(&shown_btns, b)
		}
		for at := 0; at < len(shown_btns); {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(DOT + GAP_INLINE), 0, pu(SP_1), 0}, childGap = pu(GAP_BUTTONS)}}) {
				used := px(DOT + GAP_INLINE)
				for at < len(shown_btns) {
					b := shown_btns[at]
					w := text_w(JOB_BUTTON_LABELS[b], FONT_UI_SMALL) + px(2 * SP_2 + GAP_BUTTONS)
					if used + w > inner && used > px(DOT + GAP_INLINE) do break // the next line
					used += w
					at += 1
					i := len(ju.buttons)
					append(&ju.buttons, type_of(ju.buttons[0]){job = strings.clone(r.id, a), what = b})
					small_button(clay.ID("jobbtn", u32(i)), JOB_BUTTON_LABELS[b], ui_hover == Hit(Hit_Jobs{what = .Button, index = i}))
				}
			}
		}
	}
}

// ---- hits, tips, clicks ----

jobs_hit :: proc() -> Hit {
	if !jobs_shown() do return nil
	for tool in Jobs_Tool do if clay.PointerOver(clay.ID("jobstool", u32(tool))) {
		if tool == .New_Job && core.folder_of(.Jobs) == "" do return nil
		return Hit_Jobs{what = .Tool, index = int(tool)}
	}
	if clay.PointerOver(clay.ID("jobs_resume_all")) do return Hit_Jobs{what = .Resume_All}
	if clay.PointerOver(clay.ID("jobs_notes_dir")) do return Hit_Jobs{what = .Notes_Dir}
	if ju.limits_open do for row in Job_Limit_Row do if clay.PointerOver(clay.ID("joblimit", u32(row))) do return Hit_Jobs{what = .Limit, index = int(row)}
	if !clay.PointerOver(clay.ID("jobs_list")) do return nil
	for _, i in ju.buttons do if clay.PointerOver(clay.ID("jobbtn", u32(i))) do return Hit_Jobs{what = .Button, index = i}
	if clay.PointerOver(clay.ID("jobmach", 0)) do return Hit_Jobs{what = .Machine, index = 0}
	for m in state.machines do if clay.PointerOver(clay.ID("jobmach", u32(m.no))) do return Hit_Jobs{what = .Machine, index = int(m.no)}
	for _, i in ju.mgroups do if clay.PointerOver(clay.ID("jobmgroup", u32(i))) do return Hit_Jobs{what = .Machine_Group, index = i}
	for _, i in ju.groups {
		if clay.PointerOver(clay.ID("jobgroupnew", u32(i))) do return Hit_Jobs{what = .Group_New, index = i}
		if clay.PointerOver(clay.ID("jobgroupfold", u32(i))) do return Hit_Jobs{what = .Group_Fold, index = i}
		if clay.PointerOver(clay.ID("jobgroup", u32(i))) do return Hit_Jobs{what = .Group, index = i}
	}
	for _, i in ju.drawn {
		if clay.PointerOver(clay.ID("jobmore", u32(i))) do return Hit_Jobs{what = .More, index = i}
		if clay.PointerOver(clay.ID("jobrow", u32(i))) do return Hit_Jobs{what = .Row, index = i}
	}
	return Hit_Jobs{what = .List}
}

jobs_tip :: proc(h: Hit_Jobs) -> (label, keys: string) {
	switch h.what {
	case .Tool:
		switch Jobs_Tool(h.index) {
		case .New_Job:   return "New job: a form that writes the job's note", ""
		case .Pause_All: return state.settings.jobs_paused ? "Resume all jobs" : "Pause all jobs (running ones finish)", ""
		case .Limits:    return "Limits and safety stops", ""
		}
	case .Row:
		if h.index < len(ju.drawn) do if r := job_row_of(ju.drawn[h.index]); r != nil do return fmt.tprintf("%s · %s · %s", r.name, r.schedule, core.fs_display(r.path)), ""
	case .More:       return "More actions", ""
	case .Group:
		if h.index < len(ju.groups) {
			o := ju.groups[h.index]
			switch o.kind {
			case .Project: return fmt.tprintf("Go to %s (%s)", o.name, core.fs_display(o.path)), ""
			case .Atlas:   return fmt.tprintf("Open %s", core.agent_name()), ""
			case .Chats:   return "Show Chats", ""
			case .Other:   return "Jobs of no project: click to fold or unfold", ""
			}
		}
	case .Group_Fold, .Machine, .Machine_Group: return "Fold or unfold", ""
	case .Group_New:
		if h.index < len(ju.groups) do return fmt.tprintf("New job for %s", core.job_owner_label(ju.groups[h.index])), ""
	case .Button:
		if h.index < len(ju.buttons) do switch ju.buttons[h.index].what {
		case .Run_Now:   return "Run it now", ""
		case .Stop:      return "Stop this run", ""
		case .Edit:      return "Edit the job in a form (or as its note)", ""
		case .Open_Note: return "Open the job's note in an editor tab", ""
		case .Report:    return "Open the last run's report", ""
		case .Mark_Read: return "Mark its runs read", ""
		}
	case .Limit:      return "Click for the next value", ""
	case .Notes_Dir:  return "Choose the main folder (job notes go in its jobs/)", ""
	case .Resume_All: return "Resume all jobs", ""
	case .List:
	}
	return "", ""
}

// A click on the Jobs tab (main.odin).
jobs_click :: proc(h: Hit_Jobs) {
	app.redraw = true
	switch h.what {
	case .Tool:
		switch Jobs_Tool(h.index) {
		case .New_Job:   ui_do(core.Job_Sheet{open = true}) // the job sheet (ui_job_sheet.odin)
		case .Pause_All: ui_do(state.settings.jobs_paused ? core.Command(core.Jobs_Resume{}) : core.Command(core.Jobs_Pause{}))
		case .Limits:    ju.limits_open = !ju.limits_open
		}
	case .Row:
		if h.index >= len(ju.drawn) do return
		id := ju.drawn[h.index]
		was := ju.expanded == id
		delete(ju.expanded)
		ju.expanded = was ? "" : strings.clone(id)
	case .More:
		if h.index < len(ju.drawn) do menu_open(Menu_Job{id = ju.drawn[h.index]}, app.pointer)
	case .Button:
		if h.index >= len(ju.buttons) do return
		b := ju.buttons[h.index]
		switch b.what {
		case .Run_Now:   ui_do(core.Job_Run_Now{job = b.job})
		case .Stop:      ui_do(core.Job_Stop{job = b.job})
		case .Edit:      ui_do(core.Job_Sheet{open = true, job = b.job})
		case .Open_Note: ui_do(core.Job_Open{job = b.job, what = "note"})
		case .Report:    ui_do(core.Job_Open{job = b.job, what = "report"})
		case .Mark_Read: ui_do(core.Job_Mark_Read{job = b.job})
		}
	case .Limit:      ui_do(limit_next(Job_Limit_Row(h.index)))
	case .Notes_Dir:  action_run("setup") // the first-run sheet (ui_setup.odin)
	case .Group:
		if h.index >= len(ju.groups) do return
		o := ju.groups[h.index]
		switch o.kind {
		case .Project:
			ui_do(core.Set_Left_Tab{tab = .Sessions})
			if state.sidebar.folded[.This_Mac] do ui_do(core.Set_Sidebar_Folded{section = .This_Mac, folded = false})
			ui_do(core.Select_Project{o.project})
		case .Atlas: ui_do(core.Set_Home{open = true})
		case .Chats:
			ui_do(core.Set_Left_Tab{tab = .Sessions})
			if state.sidebar.folded[.Chats] do ui_do(core.Set_Sidebar_Folded{section = .Chats, folded = false})
			if state.sidebar.folded[.This_Mac] do ui_do(core.Set_Sidebar_Folded{section = .This_Mac, folded = false})
		case .Other: group_fold(h.index)
		}
	case .Group_Fold: group_fold(h.index)
	case .Machine:    jobs_machine_fold(u64(h.index))
	case .Machine_Group:
		if h.index >= len(ju.mgroups) do return
		key := ju.mgroups[h.index]
		if at := core.list_index(ju.folded[:], key); at >= 0 {
			delete(ju.folded[at])
			ordered_remove(&ju.folded, at)
		} else do append(&ju.folded, strings.clone(key))
	case .Group_New:
		if h.index < len(ju.groups) do ui_do(core.Job_Sheet{open = true, for_project = owner_value(ju.groups[h.index])})
	case .Resume_All: ui_do(core.Jobs_Resume{})
	case .List:
	}
}

// A right click: a row's menu.
jobs_context :: proc(h: Hit_Jobs, at: [2]f32) {
	if (h.what == .Row || h.what == .More) && h.index < len(ju.drawn) do menu_open(Menu_Job{id = ju.drawn[h.index]}, at)
}

// The "…" menu of a job.
jobs_menu_items :: proc(id: string, items: ^[dynamic]core.Menu_Item) {
	r := job_row_of(id)
	if r == nil do return
	add :: proc(items: ^[dynamic]core.Menu_Item, label: string, cmd: core.Command) {append(items, core.Menu_Item{label = label, cmd = cmd})}
	if r.running do add(items, "Stop", core.Job_Stop{job = r.id})
	else if r.err == "" do add(items, "Run now", core.Job_Run_Now{job = r.id})
	if r.paused do add(items, "Resume", core.Jobs_Resume{job = r.id})
	else do add(items, "Pause", core.Jobs_Pause{job = r.id})
	if r.err == "" do add(items, r.enabled ? "Disable" : "Enable", core.Job_Set_Enabled{job = r.id, on = !r.enabled})
	append(items, core.Menu_Item{sep = true})
	add(items, "Edit…", core.Job_Sheet{open = true, job = r.id})
	add(items, "Open note", core.Job_Open{job = r.id, what = "note"})
	if r.last_run != "" {
		add(items, "Open last report", core.Job_Open{job = r.id, what = "report"})
		add(items, "Open run folder", core.Job_Open{job = r.id, what = "run_folder"})
	}
	if r.unread > 0 do add(items, "Mark read", core.Job_Mark_Read{job = r.id})
	append(items, core.Menu_Item{sep = true})
	add(items, "Delete…", core.Job_Delete{job = r.id})
}

// Opens a row and the limits (tests: the layout audit, scenes).
jobs_ui_set :: proc(expanded: string, limits: bool) {
	delete(ju.expanded)
	ju.expanded = strings.clone(expanded)
	ju.limits_open = limits
}
