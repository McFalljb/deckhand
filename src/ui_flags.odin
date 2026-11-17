package main

// Flags for a harness tab (docs/GUIDE.md "Flags for a tab"; core/harness_flags.odin).
//
//   - "New Claude tab with flags…", "New Codex tab with flags…" (the tab strip's "+", a project's
//     menu, the palette) and "New session with flags…" (the "+" and a project's menu: the harness
//     picker, each harness's row "<harness> with flags…") open the palette as a one-line field
//     (palette.flags_for: the start it sends), prefilled with the flags last used for that harness
//     from this window. Enter splits the line as a shell splits words (quotes honoured, nothing
//     evaluated) and sends the start with them as `args`, through the inbox as the user; its row
//     says why first when the harness's rule (the core's own check) or the quoting refuses them.
//   - Settings › Coding agents › Default flags… (each harness's card): the page's field, sent as
//     set_harness_flags (this Mac's user's only); the core says why when it refuses.
//   - Another machine's start (its project's or open session's ids) takes them too: sent as the
//     start's `args` as typed, never this Mac's defaults; that machine's core checks them by its own
//     rule and adds its own defaults (core/machine_route.odin), so the row checks only the quoting
//     here. The palette keeps which run of that machine's core and which folder it asked for: a
//     restart there since, and nothing starts (the ids may name something else now).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core"

// The flags each harness was last started with from this window, as typed (this run; heap), and
// where: the field is prefilled with them only for a start on the same machine and project.
flags_last: [core.Harness]string
flags_last_for: [core.Harness][2]u64 // {machine, project id}

// Another machine's start the palette asks flags for: its machine, the run of its core and the
// project's folder when it asked (heap; machine 0: this Mac's).
flags_remote: struct {
	machine:     u64,
	run, folder: string,
}

// The harness a start command runs, when it can take the user's flags from here (new_chat,
// new_claude_session, new_claude_tab; on this Mac or another machine).
flags_harness :: proc(cmd: core.Command) -> (h: core.Harness, ok: bool) {
	#partial switch c in cmd {
	case core.New_Chat:           return .Pi, true
	case core.New_Claude_Session: return c.harness, true
	case core.New_Claude_Tab:     return c.harness, true
	}
	return
}

// The machine a start runs on (0: this Mac), and its project (temp).
@(private = "file")
flags_where :: proc(cmd: core.Command) -> (no: u64, p: ^core.Project) {
	no, _ = core.command_machine(cmd)
	#partial switch c in cmd {
	case core.New_Chat:           p = core.find_project(c.project_id)
	case core.New_Claude_Session: p = core.find_project(c.project_id)
	case core.New_Claude_Tab:
		if c.project_id != 0 do p = core.find_project(c.project_id)
		else if s := core.find_session(c.session); s != nil do p = core.find_project(s.project_id)
	}
	return
}

// The palette asks for the flags of cmd (a start flags_harness takes), prefilled with the last.
flags_open :: proc(cmd: core.Command) {
	h, ok := flags_harness(cmd)
	if !ok do return
	palette_reset()
	palette.flags_for = core.command_clone(cmd, runtime.heap_allocator())
	// another machine's: what it is now, checked again before the start goes
	if no, p := flags_where(cmd); no != 0 {
		run, folder := "", ""
		if p != nil do run, folder = handoff_picker_identity(p^)
		flags_remote = {machine = no, run = strings.clone(run, runtime.heap_allocator()), folder = strings.clone(folder, runtime.heap_allocator())}
	}
	// the last flags, only where they were typed (never another project's or machine's)
	if no, p := flags_where(cmd); p != nil && flags_last_for[h] == {no, p.id} do tf_set(&palette.field, flags_last[h])
	palette.was_open = true
	ui_do(core.Set_Focus{"palette"})
}

// Drops the start the palette asked for (palette_reset).
flags_forget :: proc() {
	if palette.flags_for == nil do return
	core.command_free(palette.flags_for, runtime.heap_allocator())
	palette.flags_for = nil
	delete(flags_remote.run, runtime.heap_allocator())
	delete(flags_remote.folder, runtime.heap_allocator())
	flags_remote = {}
}

// What the field holds as args, and why it cannot start ("" = it can): the quoting, then the
// harness's own rule (the core's check, its words). Another machine's start: the quoting only
// (that machine's core checks them by its own rule, which may be newer or older). Temp.
@(private = "file")
flags_parse :: proc(h: core.Harness, text: string, remote := false) -> (args: []string, why: string) {
	args, why = core.flags_split(strings.trim_space(text))
	if why != "" || remote do return
	return args, core.harness_args_check(h, args)
}

// Why another machine's start cannot go now ("" = it can): it went offline, its core restarted
// since the palette asked, or the project's folder is another one.
@(private = "file")
flags_remote_why :: proc(cmd: core.Command) -> string {
	no, p := flags_where(cmd)
	if no == 0 do return ""
	if no != flags_remote.machine || p == nil do return HANDOFF_GONE
	run, folder := handoff_picker_identity(p^)
	if run != flags_remote.run || folder != flags_remote.folder do return HANDOFF_RESTARTED
	return ""
}

// Flags mode: one row, the start with these flags (or why it cannot).
flags_palette_results :: proc(query: string) -> []Palette_Item {
	out := make([dynamic]Palette_Item, context.temp_allocator)
	h, ok := flags_harness(palette.flags_for)
	if !ok do return out[:]
	no, _ := flags_where(palette.flags_for)
	args, why := flags_parse(h, query, no != 0)
	what := "tab"
	#partial switch _ in palette.flags_for {
	case core.New_Chat, core.New_Claude_Session: what = "session"
	}
	title := fmt.tprintf("Start a %s %s with %s", core.HARNESSES[h].name, what, len(args) == 0 ? "no extra flags" : "these flags")
	if no != 0 do title = fmt.tprintf("%s on %s", title, core.machine_name(no))
	detail := why
	if why == "" && len(args) > 0 do detail = core.flags_join(args)
	if why == "" && no != 0 do detail = detail != "" ? fmt.tprintf("%s · checked there, with its own defaults", detail) : "its own defaults"
	else if why == "" && core.harness_default_args(h) != nil do detail = fmt.tprintf("%s · after your defaults", detail)
	append(&out, Palette_Item{kind = .Flags, key = fmt.tprintf("flags:%s", core.HARNESS_KEYS[h]), title = title, detail = detail, why = why})
	return out[:]
}

// Enter on the row: the start with the field's flags, as the user. Refused flags start nothing
// (the toast says why, as the row did).
flags_run :: proc(it: Palette_Item) {
	cmd := palette.flags_for
	h, ok := flags_harness(cmd)
	if !ok do return
	text := strings.trim_space(tf_text(&palette.field))
	no, _ := flags_where(cmd)
	args, why := flags_parse(h, text, no != 0)
	if why == "" do why = flags_remote_why(cmd) // another machine's: still the one it asked for
	if why != "" || it.why != "" {
		toast_show(why != "" ? why : it.why, err = true)
		return
	}
	label := "New tab with flags"
	#partial switch &c in cmd {
	case core.New_Chat:
		c.args = args
		label = "New session with flags"
	case core.New_Claude_Session:
		c.args = args
		label = "New session with flags"
	case core.New_Claude_Tab:
		c.args = args
	}
	_, p := flags_where(cmd)
	place := [2]u64{no, p != nil ? p.id : 0}
	if _, is := cmd.(core.New_Claude_Tab); !is do harness_used(cmd) // a session's harness goes first in the picker next time
	// its answer first: a start the core refuses is a toast, and its flags are not kept
	r := client_run(cmd)
	if !r.ok && !r.pending {
		if r.error != core.CLAUDE_MISSING do toast_show(fmt.tprintf("%s: %s", label, r.error != "" ? r.error : "it did not work"), err = true) // (Claude Code missing: the command said how to install it)
		return
	}
	if p == nil do return
	delete(flags_last[h])
	flags_last[h] = strings.clone(text, runtime.heap_allocator())
	flags_last_for[h] = place
}

// The harness picker in flags mode: one "<harness> with flags…" row per choice that takes flags
// here (the account the project would use first).
flags_picker_items :: proc(p: ^core.Project, cwd: string, items: ^[dynamic]core.Menu_Item) {
	seen: [core.Harness]bool
	for it in core.new_session_choices(p, cwd) {
		h, ok := flags_harness(it.cmd)
		if !ok || seen[h] do continue
		seen[h] = true
		append(items, core.Menu_Item{label = fmt.tprintf("%s with flags…", core.HARNESSES[h].name), icon = it.icon, cmd = it.cmd, flags = true})
	}
}

// Whether the project's picker has a row that takes flags here ("With flags…", "New session with
// flags…").
flags_picker_any :: proc(pid: u64, cwd := "") -> bool {
	p := core.find_project(pid)
	if p == nil do return false
	for it in core.new_session_choices(p, cwd) do if _, ok := flags_harness(it.cmd); ok do return true
	return false
}

// Settings › Coding agents › <harness> › Default flags…: the page's field, with the line as set.
settings_page_flags_edit :: proc(h: core.Harness) {
	settings_page_open(.Agents)
	sp_edit_begin(.Harness_Flags, core.HARNESS_KEYS[h], state.settings.harness_flags[h])
}

// The harness a Default flags field is for (its target: HARNESS_KEYS).
flags_edit_harness :: proc(target: string) -> (core.Harness, bool) {
	for k, h in core.HARNESS_KEYS do if k == target do return h, true
	return .Pi, false
}

// A Default flags row's hint: the line as set, or none.
flags_default_hint :: proc(h: core.Harness) -> string {
	if state.settings.harness_flags[h] == "" do return "None · added before a tab's own flags, in the tabs you start"
	return fmt.tprintf("%s · before a tab's own flags", state.settings.harness_flags[h])
}
