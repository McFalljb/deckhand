package main

import "core:fmt"
import "core:path/filepath"
import "core"

// "New session on <machine>…" (core/handoff.odin; docs/GUIDE.md, Other machines): in a local
// project's, session's and open row's menus, and the palette's "New session on another machine…".
// Each row is that remote project's "+ New session": it selects that project and opens its
// harness picker (menu_run: the picker field, with the remote project's packed id and no folder).

// The palette's menu of the matches, while there are several (this Mac's project id).
Menu_Handoff :: distinct u64

// One row per match for this Mac's project pid (none: no rows).
handoff_items :: proc(items: ^[dynamic]core.Menu_Item, pid: u64) {
	for t in core.handoff_targets(pid) do append(items, core.Menu_Item{label = t.label, picker = core.Menu_New_Session{project_id = t.project_id}})
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
	switch len(targets) {
	case 0:
		name := core.handoff_name(p.cwd)
		if name == "" do name = filepath.base(p.cwd)
		toast_show(fmt.tprintf("No other machine has a project called %s", name))
	case 1:
		handoff_start(targets[0].project_id, nil)
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
