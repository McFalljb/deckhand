package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core"

// "New session on <machine>…" (core/handoff.odin; docs/GUIDE.md, Other machines): in a local
// project's, session's and open row's menus, and the palette's "New session on another machine…".
// Each row is that remote project's "+ New session": it selects that project and opens its
// harness picker (menu_run: the picker field, with the remote project's packed id and no folder).
//
// A row acts on what it showed: the menu is made again every frame, so a click acts on the row
// as last drawn (handoff_drawn), checked again (that machine online, its core the same run, the
// project still there with that folder), or on nothing. An open picker for another machine's
// project checks its core's run and the project's folder again before a choice starts anything.

HANDOFF_GONE :: "That machine is no longer available"
HANDOFF_RESTARTED :: "That machine restarted: choose the project again"

// The palette's menu of the matches, while there are several (this Mac's project id).
Menu_Handoff :: distinct u64

// One row per match for this Mac's project pid, then "and N more on <machine>" as plain text
// (none: no rows).
handoff_items :: proc(items: ^[dynamic]core.Menu_Item, pid: u64) {
	for t in core.handoff_targets(pid) {
		if t.project_id == 0 do append(items, core.Menu_Item{label = t.label, note = true})
		else do append(items, core.Menu_Item{label = t.label, picker = core.Menu_New_Session{project_id = t.project_id, run = t.run, folder = t.folder}})
	}
}

// Another machine's project rows of the open menu as last drawn: row index, and the project,
// core run and folder it showed (heap).
Handoff_Drawn :: struct {
	row: int,
	ns:  core.Menu_New_Session,
}
handoff_drawn: [dynamic]Handoff_Drawn

handoff_drawn_clear :: proc() {
	for d in handoff_drawn {
		delete(d.ns.run)
		delete(d.ns.folder)
	}
	clear(&handoff_drawn)
}

// The menu is drawn with these rows: another machine's project rows are kept as drawn.
handoff_drawn_note :: proc(items: []core.Menu_Item) {
	handoff_drawn_clear()
	for it, i in items {
		ns, ok := it.picker.?
		if !ok || core.id_machine(ns.project_id) == 0 do continue
		append(&handoff_drawn, Handoff_Drawn{row = i, ns = {project_id = ns.project_id, run = strings.clone(ns.run), folder = strings.clone(ns.folder)}})
	}
}

// Row i of the menu (closed since) was chosen: the remote project it showed when drawn, if that
// is still so; else nothing starts and a toast says so.
handoff_run :: proc(i: int, at: [2]f32) {
	for d in handoff_drawn do if d.row == i {
		if !handoff_still(d.ns) do break
		handoff_start(d.ns.project_id, at)
		return
	}
	toast_show(HANDOFF_GONE, err = true)
}

// That machine is online with the same core run, and the project under that id has that folder.
@(private = "file")
handoff_still :: proc(ns: core.Menu_New_Session) -> bool {
	no := core.id_machine(ns.project_id)
	for m in state.machines do if m.no == no {
		if m.status != .Online || m.core_run != ns.run do return false
		p := core.find_project(ns.project_id)
		return p != nil && p.machine == no && p.cwd == ns.folder
	}
	return false
}

// Another machine's project p: its core's run and p's folder now, for its picker (this Mac's: "").
handoff_picker_identity :: proc(p: core.Project) -> (run, folder: string) {
	no := core.id_machine(p.id)
	if no == 0 do return "", ""
	for m in state.machines do if m.no == no do run = m.core_run
	return run, p.cwd
}

// An open picker for another machine's project whose machine restarted since (another run, or the
// project under that id has another folder): closed, with a toast; true = start nothing.
handoff_picker_stale :: proc(t: core.Menu_New_Session) -> bool {
	no := core.id_machine(t.project_id)
	if no == 0 do return false
	run := ""
	for m in state.machines do if m.no == no do run = m.core_run
	p := core.find_project(t.project_id)
	if run == t.run && p != nil && p.machine == no && p.cwd == t.folder do return false
	menu_close()
	toast_show(HANDOFF_RESTARTED, err = true)
	return true
}

// The palette action applies: the selected project is this Mac's, and other machines are listed.
handoff_action_ok :: proc() -> bool {
	p := core.find_project(state.selected_project)
	return p != nil && p.machine == 0 && p.group == .Projects && core.machines_in_sidebar()
}

// The palette action: one match starts as its row would; several, their menu; none, a toast.
handoff_action_ui :: proc() {
	p := core.find_project(state.selected_project)
	if p == nil do return
	targets := core.handoff_targets(p.id)
	switch {
	case len(targets) == 0:
		name := core.handoff_name(p.cwd)
		if name == "" do name = filepath.base(p.cwd)
		toast_show(fmt.tprintf("No other machine has a project called %s", name))
	case len(targets) == 1 && targets[0].project_id != 0:
		handoff_start(targets[0].project_id, nil) // just made from the state now: nothing to check
	case:
		menu_open(Menu_Handoff(p.id), new_session_anchor())
	}
}

// What "+ New session" on that machine's project does: select it, then its harness picker
// (at: where; nil = new_session_anchor). Only the remote project's id goes: no folder.
handoff_start :: proc(remote_pid: u64, at: Maybe([2]f32)) {
	if core.id_machine(remote_pid) == 0 do return
	if remote_pid != state.selected_project do ui_do(core.Select_Project{remote_pid})
	new_session_ui(remote_pid, "", at)
}
