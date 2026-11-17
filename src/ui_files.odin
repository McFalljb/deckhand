package main

// The left column's tab switch (Sessions | Files | Jobs) and the Files tab's
// tree. The header (the project's name and its buttons), the filter field,
// then the tree (files.odin) as a virtualised list: only the rows in view
// are laid out. (Settings is a page in the centre: ui_settings_page.odin; the
// Settings_Row_Op handlers and the row menu below are its.)
// Every action is a command (ui_do) or an action from actions.odin, and has
// a button: the header's, the row's "…" and the right-click menu.
//
// Mouse: a press selects; on release a folder opens or closes and a file
// opens in a preview tab (a double-click or Enter keeps it). ⌘-click adds or
// takes out a row, shift-click selects a range (core files_sel_*); neither opens
// anything. A plain press inside a selection of several keeps it until the release.
// Dragging a row onto a terminal pastes its quoted path. Keyboard (focus widget
// "files"): ↑/↓ move (with shift: extend), ←/→ close/open or go to the
// parent/child, Enter opens, Space previews, F2 renames, ⌘A selects every row,
// ⌘⌫ moves the selection to the Trash (one confirmation), Esc clears a selection
// of several, else gives the keyboard back; letters jump to the next row whose
// name starts with them (files_type). Renaming is inline (focus widget "files_name"; Enter or a click elsewhere
// renames, Esc cancels); a new file or folder's name field is a row of its own, the first in its
// folder (files_new_row_at), with the error under it. Right-click selects the row first.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Files_Hit_Kind :: enum u8 {
	Tab_Sessions,
	Tab_Files,
	Tab_Settings, // not drawn (the old Settings tab): kept for LEFT_TAB_HITS
	Tab_Jobs,
	Tool, // index: Files_Tool
	Filter,
	Filter_Clear,
	Row,
	More,
	List, // empty space in the list
	Name, // the inline name field
	Retry, // a folder that could not be listed: list it again (index: the drawn slot)
	// the checkout switcher and its menu (ui_worktrees.odin)
	Switcher,
	Wt_Row, // index: the menu's row
	Wt_More, // a row's "…"
	Wt_Box, // the menu's empty space
}
Hit_Files :: struct {
	what:  Files_Hit_Kind,
	index: int, // Tool: Files_Tool; Row/More: the drawn slot
}

Files_Tool :: enum {
	New_File,
	New_Folder,
	Collapse_All,
	Refresh,
	Reveal,
}

FILES_TOOLS := [Files_Tool]struct {
	action: string,
	icon:   core.Icon,
}{
	.New_File     = {"files_new_file", .New_File},
	.New_Folder   = {"files_new_folder", .New_Folder},
	.Collapse_All = {"files_collapse_all", .Collapse_All},
	.Refresh      = {"files_refresh", .Refresh},
	.Reveal       = {"files_reveal_finder", .Reveal},
}

LEFT_TAB_HITS := [core.Left_Tab]Files_Hit_Kind {
	.Sessions = .Tab_Sessions,
	.Files    = .Tab_Files,
	.Settings = .Tab_Settings,
	.Jobs     = .Tab_Jobs,
}
LEFT_TAB_ICONS := [core.Left_Tab]core.Icon {
	.Sessions = .Chat,
	.Files    = .Folder,
	.Settings = .Sliders,
	.Jobs     = .Clock,
}
LEFT_TAB_LABELS := [core.Left_Tab]string {
	.Sessions = "Sessions",
	.Files    = "Files",
	.Settings = "Settings",
	.Jobs     = "Jobs",
}

Menu_Files :: struct {
	path: string, // owned (menu_close frees it)
	page: bool, // a Settings page row's (settings_page_context): the old Settings tab's items
}

Files_Edit_Mode :: enum u8 {
	None,
	Rename, // target: the path being renamed (its row shows the field)
	New_File, // target: the folder it goes in
	New_Folder,
}

files_filter_field: Text_Field
files_name_field: Text_Field

@(private = "file")
Files_Ui :: struct {
	edit:       Files_Edit_Mode,
	target:     string, // owned
	edit_err:   string, // owned: why the last try failed
	// rows drawn in the last layout, by slot (paths in the arena)
	arena:      virtual.Arena,
	drawn:      [dynamic]string,
	drawn_dir:  [dynamic]bool,
	drawn_row:  [dynamic]int, // the row each slot shows (-1: the new name's field or its error)
	count:      int, // rows in the list at the last layout (the new name's included)
	reveal_new: bool, // scroll the new name's field into view at the next layout
	reveal_near: bool, // the next reveal scrolls only as far as needed (a new file: no jump)
	input_at:   time.Tick, // armed: this window's event moved (or may move) the keyboard off the name field (files_event_begin)
	first:      int, // row index of slot 0
	view_h:     f32, // the list's height at the last layout (logical px)
	// a press on a row: acts on release unless it became a drag
	press:      bool,
	press_path: string, // owned: what was pressed (the rows may change before the release)
	press_dir:  bool,
	press_at:   [2]f32,
	press_clicks: int,
	press_mods: bool, // the press had ⌘ or shift: it changed the selection; its release opens nothing
	press_keep: bool, // a plain press on a row of a selection of several: kept until the release
	dragging:   bool,
	drag_path:  string, // owned
	multi:      bool, // several rows selected (drawn: the cursor's row ringed too)
	// type-to-select: what was typed, the last key's time
	typed:      [64]u8,
	typed_n:    int,
	typed_at:   time.Tick,
}

@(private = "file")
fu: Files_Ui

// The Files tab shows now.
files_shown :: proc() -> bool {return state.layout.left_open && state.layout.left_tab == .Files}

// ---- layout ----

// The segmented switch under the title bar: Sessions | Files | Jobs (Settings is a page in the
// centre: ui_settings_page.odin; the enum keeps its value for older callers and saved workspaces).
left_tabs_switch :: proc() {
	th := theme()
	if clay.UI(clay.ID("lefttabs"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(LEFT_TABS_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		// labels while each fits its segment, else icons (tooltips name them)
		left, _ := column_widths()
		shown := len(core.Left_Tab) - 1
		seg := (left - 2 * SP_2 - 4 - 2 * f32(shown - 1)) / f32(shown)
		icons_only := false
		for tab in core.Left_Tab {
			if tab == .Settings do continue
			extra := tab == .Jobs && state.jobs_unread > 0 ? f32(DOT + SP_1) : 0
			if text_w(LEFT_TAB_LABELS[tab], FONT_UI_SMALL) / app.dpi + extra + 2 * SP_1 > seg do icons_only = true
		}
		for tab in core.Left_Tab {
			if tab == .Settings do continue
			what := LEFT_TAB_HITS[tab]
			id := clay.ID("lefttab", u32(tab))
			on := state.layout.left_tab == tab
			bg, em := overlay(id, false, ui_hover == Hit(Hit_Files{what = what}))
			if on do bg = cc(mix(th.bg_elevated, th.text, TINT_SEGMENT))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childGap = pu(SP_1), childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				col := on ? th.text : mix(th.text_muted, th.text_secondary, em)
				if icons_only do icon(LEFT_TAB_ICONS[tab], col, ICON_SIZE_SM)
				else do clay.TextDynamic(LEFT_TAB_LABELS[tab], txt(col, FONT_UI_SMALL))
				if tab == .Jobs && state.jobs_unread > 0 do dot(th.accent) // unread job runs
			}
		}
	}
}

// The Files tab: header, filter, the tree. Below the switch in the column.
files_panel :: proc(row_w_: f32) {
	row_w := row_w_
	th := theme()
	virtual.arena_destroy(&fu.arena)
	_ = virtual.arena_init_growing(&fu.arena)
	a := virtual.arena_allocator(&fu.arena)
	fu.drawn = make([dynamic]string, a)
	fu.drawn_dir = make([dynamic]bool, a)
	fu.drawn_row = make([dynamic]int, a)
	v := core.tree_view()
	root := core.files_root()
	files_follow_active(root)

	// header: the folder's name, then its buttons
	if clay.UI(clay.ID("files_head"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), 0, 0, 0}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}},
	}) {
		// the folder's name on the left (as the Sessions tab's project rows: a folder), the buttons on the right
		name := root != "" ? filepath.base(core.files_base()) : "No folder" // the project's; the switcher below names the checkout
		room := row_w - px(PAD_ROW + KIND_ICON + GAP_INLINE + GAP_GROUP) - f32(len(Files_Tool)) * px(FILES_TOOL + GAP_BUTTONS)
		icon(.Folder, th.text_muted, KIND_ICON)
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE - GAP_BUTTONS)), clay.SizingFit()}}}) {}
		clay.TextDynamic(clip(name, room, WEIGHT_BOLD), txt(th.text_secondary, WEIGHT_BOLD))
		if clay.UI()({layout = {sizing = {clay.SizingGrow({min = px(GAP_GROUP - 2 * GAP_BUTTONS)}), clay.SizingFit()}}}) {}
		for tool in Files_Tool {
			id := clay.ID("filestool", u32(tool))
			enabled := action_ok(FILES_TOOLS[tool].action)
			hovered := enabled && ui_hover == Hit(Hit_Files{what = .Tool, index = int(tool)})
			bg, em := overlay(id, false, hovered)
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFixed(px(FILES_TOOL)), clay.SizingFixed(px(FILES_TOOL))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				col := enabled ? mix(th.text_muted, th.text, em) : with_alpha(th.text_muted, DISABLED_ALPHA)
				icon(FILES_TOOLS[tool].icon, col, ICON_SIZE_SM)
			}
		}
	}
	if root != "" {
		wt_switcher(row_w) // which checkout the tree shows (ui_worktrees.odin)
		gap(SP_1)
	}
	files_filter_row(row_w)
	gap(SP_1)
	if root == "" {
		empty_state("No project", "Pick a project or open a session", row_w)
		return
	}
	// a new name's folder that is no longer in this tree (another session or checkout shows): it ends
	if (fu.edit == .New_File || fu.edit == .New_Folder) && !core.within(fu.target, root) do files_cancel_edit()
	rows := core.tree_rows()
	// New file / New folder: the name field is a row of the tree (its error one more), the first
	// in the folder it goes in
	ph, ph_depth, ph_n := -1, 0, 0
	if fu.edit == .New_File || fu.edit == .New_Folder {
		ph, ph_depth = core.files_new_row_at(rows, root, fu.target)
		if ph < 0 do ph, ph_depth = 0, 0 // its folder's row is not shown (yet): the top
		ph_n = fu.edit_err != "" ? 2 : 1
	}
	n := len(rows) + ph_n
	fu.count = n
	fu.multi = len(v.selected) > 1
	if d := clay.GetElementData(clay.ID("files_list")); d.found do fu.view_h = d.boundingBox.height / app.dpi
	if fu.view_h <= 0 do fu.view_h = 600
	if v.reveal {
		v.reveal = false
		if i := core.files_row_of(rows, v.cursor); i >= 0 do files_scroll_to(ph >= 0 && i >= ph ? i + ph_n : i, n, center = !fu.reveal_near)
		fu.reveal_near = false
	}
	if fu.reveal_new && ph >= 0 {
		fu.reveal_new = false
		files_scroll_to(ph + ph_n - 1, n) // the error under it too, then the field itself
		files_scroll_to(ph, n)
	}
	first, last, sc := core.files_visible(n, v.scroll, fu.view_h, FILES_ROW_H)
	v.scroll = sc
	fu.first = first
	offset := sc - f32(first) * FILES_ROW_H
	total := f32(n) * FILES_ROW_H
	overflow := total > fu.view_h
	if overflow do row_w -= px(FILES_SCROLL_THUMB + 2)
	if clay.UI(clay.ID("files_list"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childGap = pu(2)}}) {
		if clay.UI(clay.ID("files_rows"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = {0, -px(offset)}},
		}) {
			if n == 0 {
				d := core.files_dir(root, false)
				if state.files.filter != "" do empty_state("No matching files", "Esc in the filter clears it", row_w)
				else if d.err != "" do empty_state("Cannot list this folder", d.err, row_w)
				else do empty_state("Empty folder", "New file (the first button) starts one", row_w)
			}
			for k in first ..< last {
				if ph >= 0 && k >= ph && k < ph + ph_n do files_new_slot(k - ph, ph_depth, row_w)
				else do files_row(rows, ph >= 0 && k >= ph + ph_n ? k - ph_n : k, len(fu.drawn), row_w, a)
			}
		}
		// where the view is, while the rows overflow: a thin thumb in its own track
		if overflow {
			h := max(fu.view_h * fu.view_h / total, 24)
			y := (fu.view_h - h) * sc / (total - fu.view_h)
			if clay.UI()({layout = {sizing = {clay.SizingFixed(px(FILES_SCROLL_THUMB)), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
				gap(y)
				if clay.UI(clay.ID("files_thumb"))({
					layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(h))}},
					backgroundColor = cc(with_alpha(th.text_muted, 0.6)),
					cornerRadius = clay.CornerRadiusAll(px(FILES_SCROLL_THUMB / 2)),
				}) {}
			}
		}
	}
}

// Test mode (autotest's `@PATH` row index): the slot of the drawn Files row whose path
// ends with suffix (a whole path component or more), else -1.
files_drawn_slot :: proc(suffix: string) -> int {
	for p, i in fu.drawn {
		if p == "" || !strings.has_suffix(p, suffix) do continue
		if len(p) == len(suffix) || suffix[0] == '/' || p[len(p) - len(suffix) - 1] == '/' do return i
	}
	return -1
}

// One tree row (or "N more…"), drawn as slot `slot`.
@(private = "file")
files_row :: proc(rows: []core.Files_Row, i, slot: int, row_w: f32, a: runtime.Allocator) {
	th := theme()
	r := rows[i]
	append(&fu.drawn, r.more > 0 || r.error != "" ? "" : strings.clone(r.path, a))
	append(&fu.drawn_dir, r.kind == .Dir)
	append(&fu.drawn_row, i)
	id := clay.ID("frow", u32(slot))
	if r.error != "" {
		// a folder that could not be listed: why, and Retry (never an empty-looking folder)
		retry_w := text_w("Retry", FONT_UI_SMALL) + px(2 * SP_2)
		if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2 + FILES_INDENT * f32(r.depth) + SP_3), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
			room := row_w - px(2 * SP_2 + FILES_INDENT * f32(r.depth) + SP_3 + SP_1) - retry_w
			clay.TextDynamic(clip(r.error, room, FONT_UI_SMALL), txt(th.error, FONT_UI_SMALL))
			spacer()
			rid := clay.ID("fretry", u32(slot))
			rh := ui_hover == Hit(Hit_Files{what = .Retry, index = slot})
			rbg, rem := overlay(rid, false, rh)
			if !rh do rbg = cc(mix(th.bg_elevated, th.text, TINT_BUTTON))
			if clay.UI(rid)({
				layout = {sizing = {clay.SizingFixed(retry_w), clay.SizingFixed(px(FILES_ROW_H - 4))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = rbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				clay.TextDynamic("Retry", txt(mix(th.text_secondary, th.text, rem), FONT_UI_SMALL))
			}
		}
		return
	}
	if r.more > 0 {
		if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2 + FILES_INDENT * f32(r.depth) + SP_3), 0, 0, 0}, childAlignment = {y = .Center}}}) {
			clay.TextDynamic(fmt.tprintf("%d more…", r.more), txt(th.text_muted, FONT_UI_SMALL))
		}
		return
	}
	v := core.tree_view()
	more_hover := ui_hover == Hit(Hit_Files{what = .More, index = slot})
	hovered := ui_hover == Hit(Hit_Files{what = .Row, index = slot}) || more_hover
	selected := core.files_sel_has(v, r.path)
	is_cursor := r.path == v.cursor
	active := r.path == v.active_file
	bg, em := overlay(id, selected, hovered)
	// the keyboard's row: the accent ring while the tree has the keyboard; among several selected
	// rows, a muted ring otherwise
	ring: core.Rgba
	if is_cursor && state.focus_widget == "files" do ring = th.accent
	else if is_cursor && fu.multi do ring = th.text_muted
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2 + FILES_INDENT * f32(r.depth)), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(ring), width = clay.BorderOutside(pu(ring != {} ? core.BORDER_W : 0))},
	}) {
		chev := r.kind == .Dir ? (r.expanded ? "▾" : "▸") : ""
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_3)), clay.SizingFit()}}}) {
			if chev != "" do clay.TextDynamic(chev, txt(th.text_muted, FONT_UI_SMALL))
		}
		code := core.fs_git_code_cached(r.path, r.kind == .Dir)
		letter := core.files_git_letter(code, r.kind == .Dir)
		col := files_git_color(letter)
		if col == {} do col = mix(th.text_secondary, th.text, em)
		dot_file := strings.has_prefix(r.name, ".")
		if r.ignored || dot_file do col = with_alpha(th.text_muted, r.ignored ? 0.7 : 1)
		if active do col = th.text
		weight: u16 = active ? WEIGHT_BOLD : WEIGHT_REGULAR
		room := row_w - px(2 * SP_2 + FILES_INDENT * f32(r.depth) + SP_3 + SP_1) - px(ROW_BUTTON + SP_1)
		if fu.edit == .Rename && fu.target == r.path && state.focus_widget == "files_name" {
			files_name_box(room)
		} else if r.rel != "" {
			// filter results: the name, then its folder
			dir := filepath.dir(r.rel)
			nw := min(text_w(r.name, weight), room)
			clay.TextDynamic(clip(r.name, nw, weight), txt(col, weight))
			if dir != "." do clay.TextDynamic(clip(dir, room - nw - px(SP_1), FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		} else {
			clay.TextDynamic(clip(r.name, room, weight), txt(col, weight))
		}
		spacer()
		if hovered {
			mid := clay.ID("fmore", u32(slot))
			mbg, _ := overlay(mid, false, more_hover)
			if clay.UI(mid)({
				layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON - SP_1)), clay.SizingFixed(px(ROW_BUTTON - SP_1))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = mbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				icon(.More, more_hover ? th.text : th.text_muted, ICON_SIZE_SM)
			}
		} else if letter != "" {
			clay.TextDynamic(letter, txt(files_git_color(letter), FONT_UI_SMALL))
		}
	}
}

// The colour of a git letter (and of its row's name): added and untracked
// green, modified amber, deleted and conflicted red; {} = none.
files_git_color :: proc(letter: string) -> core.Rgba {
	th := theme()
	switch letter {
	case "A", "U":      return th.done
	case "M", "R", "•": return th.waiting
	case "D", "!":      return th.error
	}
	return {}
}

// The filter field: "Filter files", a clear button while it holds text.
@(private = "file")
files_filter_row :: proc(row_w: f32) {
	th := theme()
	focused := state.focus_widget == "files_filter"
	if !focused && tf_text(&files_filter_field) != state.files.filter do tf_set(&files_filter_field, state.files.filter)
	hov := ui_hover == Hit(Hit_Files{what = .Filter})
	ring := focused ? th.accent : mix(th.border, th.text_muted, hov ? 0.5 : 0)
	if clay.UI(clay.ID("files_filter_box"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FIELD_H))}, padding = clay.PaddingAll(pu(FOCUS_RING_W))},
		backgroundColor = cc(ring),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(SP_2 - FOCUS_RING_W), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD - FOCUS_RING_W)),
		}) {
			icon(.Search, focused ? th.text_secondary : th.text_muted, ICON_SIZE_SM)
			if focused {
				field_text(clay.ID("files_filter_text"), &files_filter_field, "Filter files")
			} else {
				room := row_w - px(3 * SP_2 + SP_6 + ICON_SIZE_SM)
				text := state.files.filter
				if text != "" do clay.TextDynamic(clip(text, room), txt(th.text))
				else do clay.TextDynamic(clip("Filter files", room), txt(th.text_muted))
			}
			spacer()
			if state.files.filter != "" {
				id := clay.ID("files_filter_clear")
				bg, em := overlay(id, false, ui_hover == Hit(Hit_Files{what = .Filter_Clear}))
				if clay.UI(id)({
					layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON - SP_1)), clay.SizingFixed(px(ROW_BUTTON - SP_1))}, childAlignment = {x = .Center, y = .Center}},
					backgroundColor = bg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				}) {
					icon(.Close, mix(th.text_muted, th.text, em), ICON_SIZE_SM - 2)
				}
			}
		}
	}
}

// New file / New folder's row in the tree (part 0: the name field, where its folder's first child
// goes) and, while the last try failed, the error under it (part 1).
@(private = "file")
files_new_slot :: proc(part, depth: int, row_w: f32) {
	th := theme()
	append(&fu.drawn, "")
	append(&fu.drawn_dir, false)
	append(&fu.drawn_row, -1)
	room := row_w - px(2 * SP_2 + FILES_INDENT * f32(depth) + SP_3 + SP_1)
	if clay.UI(clay.ID("fnew", u32(part)))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2 + FILES_INDENT * f32(depth)), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
	}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_3)), clay.SizingFit()}}}) {
			if part == 0 && fu.edit == .New_Folder do clay.TextDynamic("▸", txt(th.text_muted, FONT_UI_SMALL))
		}
		if part == 1 do clay.TextDynamic(clip(fu.edit_err, room, FONT_UI_SMALL), txt(th.error, FONT_UI_SMALL))
		else do files_name_box(room, fu.edit == .New_File ? "File name" : "Folder name")
	}
}

// Opens the add field (no = 0) or machine no's rename field: Settings › Machines.
machine_edit_begin :: proc(no: u64 = 0) {
	settings_page_open(.Machines) // Settings › Machines, its field (ui_settings_page.odin)
	if no == 0 {
		sp_edit_begin(.Add_Machine, core.MACHINE_ADD_ROW, "")
		return
	}
	for m in state.machines do if m.no == no do sp_edit_begin(.Rename_Machine, fmt.tprintf("%s%d", core.MACHINE_ROW, no), m.name)
}

// The name field (rename in a row, or new file/folder): accent ring.
@(private = "file")
files_name_box :: proc(w: f32, placeholder := "") {
	th := theme()
	if clay.UI(clay.ID("files_name_box"))({
		layout = {sizing = {w > 0 ? clay.SizingFixed(w) : clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H - 2))}, padding = clay.PaddingAll(pu(FOCUS_RING_W))},
		backgroundColor = cc(fu.edit_err != "" ? th.error : th.accent),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(SP_1), 0, 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM - FOCUS_RING_W)),
		}) {
			field_text(clay.ID("files_name_text"), &files_name_field, placeholder)
		}
	}
}

// A press on a row, or a drag from it, ends where it is: nothing opens or drops (an overlay
// opened over it: ui_bell.odin).
files_drag_cancel :: proc() {
	if fu.press || fu.dragging do app.redraw = true
	fu.press, fu.dragging = false, false
}

when core.TEST_HOOKS {
	// Tests: a drag of path from the Files tab in progress; whether one is.
	files_drag_for_test :: proc(path: string) {
		delete(fu.press_path)
		delete(fu.drag_path)
		fu.press_path, fu.drag_path = strings.clone(path), strings.clone(path)
		fu.press, fu.dragging = true, true
	}
	files_dragging :: proc() -> bool {return fu.press || fu.dragging}
}

// The file being dragged, under the pointer.
files_drag_layout :: proc() {
	if !fu.dragging do return
	th := theme()
	name := filepath.base(fu.drag_path)
	if clay.UI(clay.ID("files_drag"))({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(th.accent), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {app.pointer.x + px(SP_3), app.pointer.y + px(SP_2)}, zIndex = 20},
	}) {
		clay.TextDynamic(name, txt(th.text))
	}
}

// ---- the active file ----

// The editor tab on screen changed: its file is revealed (folders above it
// opened) and selected. Only while the Files tab shows.
@(private = "file")
files_follow_active :: proc(root: string) {
	e := tab_editor()
	if e == nil || e.view != .File || e.path == "" || root == "" do return
	p := core.fs_real(e.path)
	if p == core.files_ui.active_file do return
	delete(core.files_ui.active_file)
	core.files_ui.active_file = strings.clone(p)
	if strings.has_prefix(p, strings.concatenate({root, "/"}, context.temp_allocator)) do ui_do(core.Files_Reveal{path = p})
}

// Scrolls so row i shows (centred when far).
@(private = "file")
files_scroll_to :: proc(i, n: int, center := false) {
	v := core.tree_view()
	top := f32(i) * FILES_ROW_H
	h := fu.view_h > 0 ? fu.view_h : 600
	if top < v.scroll || top + FILES_ROW_H > v.scroll + h {
		v.scroll = center ? top - h / 2 + FILES_ROW_H / 2 : (top < v.scroll ? top : top + FILES_ROW_H - h)
	}
	_, _, v.scroll = core.files_visible(n, v.scroll, h, FILES_ROW_H)
	app.redraw = true
}

// ---- hits ----

files_hit :: proc() -> Hit {
	for tab in core.Left_Tab do if tab != .Settings && clay.PointerOver(clay.ID("lefttab", u32(tab))) do return Hit_Files{what = LEFT_TAB_HITS[tab]}
	if state.layout.left_tab == .Sessions || state.layout.left_tab == .Jobs do return nil
	for tool in Files_Tool do if clay.PointerOver(clay.ID("filestool", u32(tool))) && action_ok(FILES_TOOLS[tool].action) do return Hit_Files{what = .Tool, index = int(tool)}
	if clay.PointerOver(clay.ID("wt_switch")) do return Hit_Files{what = .Switcher}
	if clay.PointerOver(clay.ID("files_filter_clear")) do return Hit_Files{what = .Filter_Clear}
	if clay.PointerOver(clay.ID("files_filter_box")) do return Hit_Files{what = .Filter}
	if clay.PointerOver(clay.ID("files_name_box")) do return Hit_Files{what = .Name}
	if !clay.PointerOver(clay.ID("files_list")) do return nil
	for p, i in fu.drawn {
		if clay.PointerOver(clay.ID("fretry", u32(i))) do return Hit_Files{what = .Retry, index = i} // an error row (drawn "")
		if p == "" do continue
		if clay.PointerOver(clay.ID("fmore", u32(i))) do return Hit_Files{what = .More, index = i}
		if clay.PointerOver(clay.ID("frow", u32(i))) do return Hit_Files{what = .Row, index = i}
	}
	return Hit_Files{what = .List}
}

files_tip :: proc(h: Hit_Files) -> (label, keys: string) {
	#partial switch h.what {
	case .Tab_Sessions: return "Projects and sessions", ""
	case .Tab_Files:
		if a := action_by_id("show_files"); a != nil do return a.label, a.keys
	case .Tab_Jobs:
		return state.jobs_unread > 0 ? fmt.tprintf("%s's jobs: %d unread", core.agent_name(), state.jobs_unread) : fmt.tprintf("%s's jobs", core.agent_name()), ""
	case .Tool:
		if a := action_by_id(FILES_TOOLS[Files_Tool(h.index)].action); a != nil do return action_label(a), a.keys
	case .Retry:
		if r, ok := files_error_row(h.index); ok do return fmt.tprintf("%s. Retry lists the folder again", r.error), ""
	case .Filter:       return "Filter files", ""
	case .Filter_Clear: return "Clear the filter", "Esc"
	case .More:         return "More actions", ""
	case .Switcher, .Wt_Row, .Wt_More: return wt_tip(h)
	}
	return "", ""
}

// ---- input ----

// Events for the Files tab and the tab switch, before the generic handling
// (main.odin). True if consumed.
files_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN:
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		h, ok := files_hit().(Hit_Files)
		if !ok {
			// a click anywhere else takes the keyboard from the tree
			if state.focus_widget == "files" do ui_do(core.Set_Focus{""})
			return false
		}
		app.pointer = {e.mouse_x, e.mouse_y}
		app.redraw = true
		right := e.mouse_button == .RIGHT || (e.mouse_button == .LEFT && e.modifiers & sapp.MODIFIER_CTRL != 0)
		if right {
			if (h.what == .Row || h.what == .More) && fu.drawn[h.index] != "" {
				files_mark_for_menu(fu.drawn[h.index]) // the row the menu is for shows selected (a selection it is in stays)
				files_menu_at(fu.drawn[h.index], app.pointer)
			} else if h.what == .List do files_menu_at(core.files_root(), app.pointer)
			return true
		}
		if e.mouse_button != .LEFT do return true
		switch h.what {
		case .Tab_Sessions: ui_do(core.Set_Left_Tab{tab = .Sessions})
		case .Tab_Files:    ui_do(core.Set_Left_Tab{tab = .Files})
		case .Tab_Settings: // not drawn
		case .Tab_Jobs:     ui_do(core.Set_Left_Tab{tab = .Jobs})
		case .Tool:         action_run(FILES_TOOLS[Files_Tool(h.index)].action)
		case .Filter:
			if state.focus_widget != "files_filter" {
				tf_set(&files_filter_field, state.files.filter)
				tf_select_all(&files_filter_field)
				ui_do(core.Set_Focus{"files_filter"})
			}
		case .Filter_Clear: ui_do(core.Set_Files_Filter{text = ""})
		case .Retry:
			if r, ok := files_error_row(h.index); ok do core.files_retry(r.path)
		case .More:
			if d := clay.GetElementData(clay.ID("fmore", u32(h.index))); d.found {
				files_mark_for_menu(fu.drawn[h.index])
				b := d.boundingBox
				files_menu_at(fu.drawn[h.index], {b.x, b.y + b.height})
			}
		case .Row:
			p := fu.drawn[h.index]
			if p == "" do return true
			v := core.tree_view()
			rows := core.tree_rows()
			shift, cmd := e.modifiers & sapp.MODIFIER_SHIFT != 0, e.modifiers & sapp.MODIFIER_SUPER != 0
			fu.typed_n = 0
			fu.press_mods = shift || cmd
			// a plain press on a row of a selection of several keeps it (a drag of them all, later);
			// the release selects that row alone
			fu.press_keep = !fu.press_mods && len(v.selected) > 1 && core.files_sel_has(v, p) && app.clicks == 1
			if fu.press_mods do core.files_sel_click(v, rows, core.files_row_of(rows, p), shift, cmd)
			else if !fu.press_keep do core.files_select_in(v, p)
			v.reveal = false
			if state.focus_widget != "files" do ui_do(core.Set_Focus{"files"})
			delete(fu.press_path)
			fu.press_path = strings.clone(p)
			fu.press, fu.press_dir, fu.press_at, fu.press_clicks = true, fu.drawn_dir[h.index], {e.mouse_x, e.mouse_y}, app.clicks
		case .List:
			if state.focus_widget != "files" do ui_do(core.Set_Focus{"files"})
		case .Name: return false // the field's own handling (widget_event) ran first
		case .Switcher: wt_menu_toggle()
		case .Wt_Row, .Wt_More, .Wt_Box: // wt_menu_event took these
		}
		return true
	case .MOUSE_MOVE:
		if fu.press && e.modifiers & sapp.MODIFIER_LMB != 0 {
			d := [2]f32{e.mouse_x, e.mouse_y} - fu.press_at
			if !fu.dragging && abs(d.x) + abs(d.y) > px(FILES_DRAG_START) {
				fu.dragging = true
				delete(fu.drag_path)
				fu.drag_path = strings.clone(fu.press_path)
			}
			if fu.dragging {
				app.pointer = {e.mouse_x, e.mouse_y}
				app.redraw = true
				return true
			}
		}
	case .MOUSE_UP:
		if !fu.press do return false
		fu.press = false
		if fu.dragging {
			fu.dragging = false
			app.redraw = true
			// onto a terminal: its quoted path, as a dropped file
			if !over_sidebar(e.mouse_x) do sidebar_drop({fu.drag_path}, e.mouse_x, e.mouse_y)
			return true
		}
		if fu.press_mods do return true // ⌘ or shift changed the selection: nothing opens
		{
			p := fu.press_path
			if fu.press_keep do files_mark(p) // the press kept a selection of several: this row alone now
			if fu.press_dir {
				if fu.press_clicks == 1 do files_toggle(p)
			} else {
				if core.path_kind(p) == .File do files_open(p, preview = fu.press_clicks < 2)
			}
		}
		return true
	case .MOUSE_LEAVE:
		files_drag_cancel() // a press that leaves the window is dropped (its release may never come)
		return false
	case .MOUSE_SCROLL:
		if !files_shown() || !inside(clay.ID("files_list"), e.mouse_x, e.mouse_y) do return false
		v := core.tree_view()
		v.scroll -= e.scroll_y * SCROLL_STEP
		_, _, v.scroll = core.files_visible(max(fu.count, len(v.rows)), v.scroll, fu.view_h, FILES_ROW_H)
		app.redraw = true
		return true
	case .KEY_DOWN, .CHAR, .KEY_UP:
		// only while the tree has the keyboard: then no key it takes reaches a terminal or an agent
		if state.focus_widget != "files" do return false
		if e.type == .CHAR && e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL) == 0 {
			files_type(rune(e.char_code))
			return true
		}
		if e.type != .KEY_DOWN do return e.modifiers & sapp.MODIFIER_SUPER == 0
		return files_key(e)
	}
	return false
}

// A key while the tree has the keyboard. ⌘ shortcuts other than ⌘⌫, ⌘A and ⌘↑/↓ pass.
@(private = "file")
files_key :: proc(e: ^sapp.Event) -> bool {
	cmd := e.modifiers & sapp.MODIFIER_SUPER != 0
	if cmd && e.key_code != .BACKSPACE && e.key_code != .UP && e.key_code != .DOWN && e.key_code != .A do return false
	if cmd && e.modifiers & sapp.MODIFIER_ALT != 0 do return false // ⌥⌘↑ ⌥⌘↓: sessions (menubar.odin)
	app.redraw = true
	rows := core.tree_rows()
	v := core.tree_view()
	i := core.files_row_of(rows, v.cursor)
	// a key that is not typed text ends type-to-select's word (Space, while typing, is part of it)
	typing := fu.typed_n > 0 && time.tick_since(fu.typed_at) < FILES_TYPE_RESET
	if e.key_code == .SPACE && typing do return true // its CHAR follows (files_type)
	if !(e.key_code >= .SPACE && e.key_code <= .GRAVE_ACCENT) || cmd do fu.typed_n = 0
	shift := e.modifiers & sapp.MODIFIER_SHIFT != 0
	move :: proc(rows: []core.Files_Row, to: int, back := false, extend := false) {
		k := files_move_target(rows, to, back)
		if k < 0 do return
		if extend do core.files_sel_range(core.tree_view(), rows, k) // shift: from the anchor to it
		else do core.files_select_in(core.tree_view(), rows[k].path)
		core.tree_view().reveal = false
		files_scroll_to(k, len(rows))
	}
	page := max(int(fu.view_h / FILES_ROW_H) - 1, 1)
	#partial switch e.key_code {
	case .A:
		if cmd do core.files_sel_all(v, rows)
	case .ESCAPE:
		if !core.files_sel_collapse(v) do ui_do(core.Set_Focus{""}) // several selected: the cursor's row alone first
	case .UP:
		// up past a heading: the row above it
		move(rows, cmd ? 0 : (i < 0 ? 0 : i - 1), back = true, extend = shift)
	case .DOWN:   move(rows, cmd ? len(rows) - 1 : i + 1, extend = shift)
	case .HOME:   move(rows, 0, back = true, extend = shift)
	case .END:    move(rows, len(rows) - 1, extend = shift)
	case .PAGE_UP: move(rows, i - page, back = true, extend = shift)
	case .PAGE_DOWN: move(rows, i + page, extend = shift)
	case .LEFT:
		if i < 0 do break
		if rows[i].kind == .Dir && rows[i].expanded do files_toggle(rows[i].path)
		else if j := core.files_parent_row(rows, rows[i].path); j >= 0 do move(rows, j)
	case .RIGHT:
		if i < 0 do break
		if rows[i].kind == .Dir && !rows[i].expanded do files_toggle(rows[i].path)
		else if rows[i].kind == .Dir && i + 1 < len(rows) && rows[i + 1].depth > rows[i].depth do move(rows, i + 1)
	case .ENTER, .KP_ENTER, .SPACE:
		if i < 0 do break
		if rows[i].kind == .Dir do files_toggle(rows[i].path)
		else do files_open(rows[i].path, preview = e.key_code == .SPACE)
	case .F2:
		if i >= 0 do files_step(rows[i].path, .Rename)
	case .BACKSPACE, .DELETE:
		if !(cmd || e.key_code == .DELETE) do break
		if sel := core.files_sel_paths(v, rows); len(sel) > 1 do ui_do(core.Delete_Path{paths = sel}) // one confirmation for them all
		else if i >= 0 do ui_do(core.Delete_Path{path = rows[i].path})
	}
	return true
}

// Type-to-select resets after this long without a key.
FILES_TYPE_RESET :: time.Second

// A character typed while the tree has the keyboard: added to what was typed (a new word after
// FILES_TYPE_RESET), and the cursor goes to the next row whose name starts with it (core
// files_type_match). Never opens anything. Space alone is the preview key (files_key).
@(private = "file")
files_type :: proc(c: rune) {
	if c < ' ' || c == 0x7f do return
	if fu.typed_n > 0 && time.tick_since(fu.typed_at) >= FILES_TYPE_RESET do fu.typed_n = 0
	if c == ' ' && fu.typed_n == 0 do return
	buf, n := utf8.encode_rune(c)
	if fu.typed_n + n > len(fu.typed) do return
	copy(fu.typed[fu.typed_n:], buf[:n])
	fu.typed_n += n
	fu.typed_at = time.tick_now()
	rows := core.tree_rows()
	v := core.tree_view()
	i := core.files_row_of(rows, v.cursor)
	// a new word looks from the row after the cursor; a longer one may stay on it
	from := i < 0 ? 0 : (fu.typed_n == n ? i + 1 : i)
	j := core.files_type_match(rows, from, string(fu.typed[:fu.typed_n]))
	if j < 0 do return
	core.files_select_in(v, rows[j].path)
	v.reveal = false
	files_scroll_to(j, len(rows))
	app.redraw = true
}

// Selects the row at path where the pointer is (a click, its menu), without scrolling.
@(private = "file")
files_mark :: proc(path: string) {
	core.files_select_in(core.tree_view(), path)
	core.tree_view().reveal = false
}

// A row's menu: a row of the selection keeps it (the menu acts on them all); another row is
// selected alone.
@(private = "file")
files_mark_for_menu :: proc(path: string) {
	if !core.files_sel_has(core.tree_view(), path) do files_mark(path)
}

// The paths path's menu acts on: the selection that shows, when path is one of several
// selected; nil otherwise (temp allocator).
files_menu_multi :: proc(path: string) -> []string {
	v := core.tree_view()
	if len(v.selected) < 2 || !core.files_sel_has(v, path) do return nil
	sel := core.files_sel_paths(v, core.tree_rows())
	return len(sel) > 1 ? sel : nil
}

// Opens or closes a folder; a failure shows (never a click that does nothing).
files_toggle :: proc(path: string) {
	ui_do_menu(core.Files_Expand{path = path, expanded = !core.files_is_open(path)}, "Open folder")
}

// The error row drawn at slot (files_row: rows [fu.first, ...) are drawn).
@(private = "file")
files_error_row :: proc(slot: int) -> (core.Files_Row, bool) {
	rows := core.tree_rows()
	if slot < 0 || slot >= len(fu.drawn_row) do return {}, false
	i := fu.drawn_row[slot]
	if i < 0 || i >= len(rows) || rows[i].error == "" do return {}, false
	return rows[i], true
}

// The session files open in: the one on screen (0 = the command's default).
@(private = "file")
files_session :: proc() -> u64 {
	if cs := core.cur(); cs != nil && !cs.home do return cs.id
	return 0
}

// ---- menu ----

@(private = "file")
files_menu_at :: proc(path: string, at: [2]f32) {
	menu_open(Menu_Files{path = path}, at) // menu_open keeps its own copy
}

// A Settings page file row's menu (the old Settings tab's): Open, New file/folder in prompts/ and
// skills/, Rename and Move to Trash only inside prompts/, skills/, extensions/, themes/ and a project's .pi/
// (settings_row_editable: never pi's own config files), Reveal, Copy path. Opens go to the session
// the page was opened from (settings_page_session).
@(private = "file")
settings_menu_items :: proc(path: string, items: ^[dynamic]core.Menu_Item) {
	files_session :: settings_page_session
	kind := core.path_kind(path)
	is_dir := kind == .Dir
	sep :: proc(items: ^[dynamic]core.Menu_Item) {append(items, core.Menu_Item{sep = true})}
	if kind == .File {
		append(items, core.Menu_Item{label = "Open", cmd = core.Open_File{path = path, session = files_session()}})
		append(items, core.Menu_Item{label = "Open in preview", cmd = core.Open_File{path = path, session = files_session(), preview = true}})
		if core.md_is_markdown_path(path) do append(items, core.Menu_Item{label = "Open Markdown preview", cmd = core.Markdown_Open{path = path, session = files_session()}})
		sep(items)
	}
	if kind != .Missing && core.settings_new_ok(is_dir ? path : filepath.dir(path)) {
		append(items, core.Menu_Item{label = "New file…", files = .New_File})
		append(items, core.Menu_Item{label = "New folder…", files = .New_Folder})
		sep(items)
	}
	if kind != .Missing && core.settings_row_editable(path) {
		append(items, core.Menu_Item{label = "Rename…", files = .Rename})
		append(items, core.Menu_Item{label = "Move to Trash…", cmd = core.Delete_Path{path = path}})
		sep(items)
	}
	if kind != .Missing do append(items, core.Menu_Item{label = "Reveal in Finder", cmd = core.Reveal_In_Finder{path = path}})
	append(items, core.Menu_Item{label = "Copy path", files = .Copy_Path})
}

// The row menu's items for path (ui_sidebar.odin's menu draws and runs them); page: a Settings
// page row's.
files_menu_items :: proc(path: string, items: ^[dynamic]core.Menu_Item, page := false) {
	if page {
		settings_menu_items(path, items)
		return
	}
	root := core.files_root()
	is_dir := core.path_kind(path) == .Dir
	is_root := path == root
	sep :: proc(items: ^[dynamic]core.Menu_Item) {append(items, core.Menu_Item{sep = true})}
	if multi := files_menu_multi(path); multi != nil {
		// several rows: only what acts on them all (no open, new, rename, reveal)
		// the count after nesting (a folder and what is in it: one), as the confirmation says
		n := len(core.fs_delete_merge(multi))
		append(items, core.Menu_Item{label = n == 1 ? "Move to Trash…" : fmt.tprintf("Move %d items to Trash…", n), keys = "⌘⌫", cmd = core.Delete_Path{paths = multi}})
		sep(items)
		append(items, core.Menu_Item{label = "Copy paths", files = .Copy_Path})
		append(items, core.Menu_Item{label = "Copy relative paths", files = .Copy_Relative})
		return
	}
	if !is_dir {
		append(items, core.Menu_Item{label = "Open", keys = "↩", cmd = core.Open_File{path = path, session = files_session()}})
		append(items, core.Menu_Item{label = "Open in preview", keys = "Space", cmd = core.Open_File{path = path, session = files_session(), preview = true}})
		append(items, core.Menu_Item{label = "Open to the side", files = .Open_Side})
		if core.md_is_markdown_path(path) do append(items, core.Menu_Item{label = "Open Markdown preview", cmd = core.Markdown_Open{path = path, session = files_session()}})
		sep(items)
	}
	append(items, core.Menu_Item{label = "New file…", files = .New_File})
	append(items, core.Menu_Item{label = "New folder…", files = .New_Folder})
	if !is_root {
		sep(items)
		append(items, core.Menu_Item{label = "Rename…", keys = "F2", files = .Rename})
		append(items, core.Menu_Item{label = "Move to Trash…", keys = "⌘⌫", cmd = core.Delete_Path{path = path}})
	}
	sep(items)
	append(items, core.Menu_Item{label = "Reveal in Finder", cmd = core.Reveal_In_Finder{path = path}})
	append(items, core.Menu_Item{label = "Copy path", files = .Copy_Path})
	append(items, core.Menu_Item{label = "Copy relative path", files = .Copy_Relative})
	if s := files_session(); s != 0 {
		dir := is_dir ? path : filepath.dir(path)
		append(items, core.Menu_Item{label = "Open terminal here", cmd = core.New_Shell_Tab{session = s, cwd = dir}})
	}
}

// A menu step that is not a command, for path; copied: a path went on the clipboard.
files_step :: proc(path: string, step: core.Files_Step) -> (copied: bool) {
	root := core.files_root()
	switch step {
	case .None:
	case .New_File, .New_Folder:
		dir := core.path_kind(path) == .Dir ? path : filepath.dir(path)
		files_begin_edit(step == .New_File ? .New_File : .New_Folder, dir, "")
	case .Rename:
		files_begin_edit(.Rename, path, filepath.base(path))
		// the name without its extension is selected, as Finder does
		name := filepath.base(path)
		if dot := strings.last_index_byte(name, '.'); dot > 0 do files_name_field.cursor, files_name_field.anchor = dot, 0
	case .Copy_Path:
		if path == "" || win_os.set_clipboard == nil do return false
		if multi := files_menu_multi(path); multi != nil do win_os.set_clipboard(strings.join(multi, "\n", context.temp_allocator)) // one per line
		else do win_os.set_clipboard(path)
		return true
	case .Open_Side:
		// open_file, then that tab in a new pane on the right (a pane holding only it shows it already)
		r := ui_run(core.Open_File{path = path, session = files_session()})
		if !r.ok {
			toast_show(r.error, true)
			return false
		}
		if s, t, _ := find_tab(r.created_id); s != nil && core.pane_tab_count(s, t.pane) > 1 {
			ui_do_menu(core.Split_Pane{pane = t.pane, direction = .Right, tab_id = r.created_id}, "Open to the side")
		}
	case .Copy_Relative:
		relative :: proc(path, root: string) -> string {
			if strings.has_prefix(path, root) && len(path) > len(root) do return path[len(root) + 1:]
			return path
		}
		if multi := files_menu_multi(path); multi != nil {
			if win_os.set_clipboard == nil do return false
			b := strings.builder_make(context.temp_allocator)
			for p, k in multi {
				if k > 0 do strings.write_byte(&b, '\n')
				strings.write_string(&b, relative(p, root))
			}
			win_os.set_clipboard(strings.to_string(b))
			return true
		}
		rel := relative(path, root)
		if rel == "" || win_os.set_clipboard == nil do return false
		win_os.set_clipboard(rel)
		return true
	}
	return false
}

// The folder new files go in: the selected folder, the selected file's
// folder, else the root.
files_new_target :: proc() -> string {
	root := core.files_root()
	p := core.files_ui.cursor
	if p == "" || !strings.has_prefix(p, root) do return root
	return core.path_kind(p) == .Dir ? p : filepath.dir(p)
}

files_begin_edit :: proc(mode: Files_Edit_Mode, target, text: string, focus := true) {
	fu.edit = mode
	fu.input_at = {} // a new edit starts unarmed
	delete(fu.target)
	fu.target = strings.clone(target)
	delete(fu.edit_err)
	fu.edit_err = ""
	tf_set(&files_name_field, text)
	tf_select_all(&files_name_field)
	if mode == .Rename {
		core.files_select_in(core.tree_view(), target)
	} else {
		// the field is a row of the tree, the folder's first: the tree shows (not filter
		// results) with the folder open, scrolled to it
		if state.files.filter != "" do ui_do(core.Set_Files_Filter{text = ""})
		if target != core.files_root() do ui_do(core.Files_Expand{path = target, expanded = true})
		fu.reveal_new = true
	}
	if focus do ui_do(core.Set_Focus{"files_name"})
}

// Why a new name cannot be used ("" = it can): one path component.
files_name_error :: proc(name: string) -> string {
	n := strings.trim_space(name)
	switch {
	case n == "":                  return "a name is needed"
	case n == "." || n == "..":    return "not a usable name"
	case strings.contains(n, "/"): return "a name cannot hold /"
	}
	return ""
}

// Enter in the name field: create or rename; an error keeps the field. blur: the field lost
// the keyboard (a click elsewhere): a changed name is renamed all the same, an error is a toast
// and the edit ends, and the keyboard stays where it went.
files_commit_edit :: proc(blur := false) {
	name := strings.trim_space(tf_text(&files_name_field))
	if fu.edit == .None || (fu.edit == .Rename && name == "") {
		files_cancel_edit()
		return
	}
	failed :: proc(err: string, blur: bool) {
		if blur {
			toast_show(fmt.tprintf("%s: %s", fu.edit == .Rename ? "Not renamed" : "Not created", err), true)
			files_cancel_edit()
			return
		}
		delete(fu.edit_err)
		fu.edit_err = strings.clone(err)
		if fu.edit == .Rename do toast_show(err, true) // the row's field has no line under it: the ring turns red, the toast says why
		else do fu.reveal_new = true // the error row under the field shows
		app.redraw = true
	}
	if err := files_name_error(name); err != "" {
		failed(err, blur)
		return
	}
	r: core.Result
	path := ""
	switch fu.edit {
	case .None:
	case .Rename:
		if name == filepath.base(fu.target) {
			files_cancel_edit()
			return
		}
		path = strings.concatenate({filepath.dir(fu.target), "/", name}, context.temp_allocator)
		r = ui_run(core.Rename_Path{from = fu.target, to = path})
	case .New_File:
		path = strings.concatenate({fu.target, "/", name}, context.temp_allocator)
		r = ui_run(core.Create_File{path = path})
		if r.ok do ui_do(core.Open_File{path = path, session = files_session()})
	case .New_Folder:
		path = strings.concatenate({fu.target, "/", name}, context.temp_allocator)
		r = ui_run(core.Create_Dir{path = path})
	}
	if !r.ok {
		failed(r.error, blur)
		return
	}
	fu.edit = .None
	delete(fu.edit_err)
	fu.edit_err = ""
	if blur do return // the click elsewhere decides what is selected
	// selected where it now sits, scrolled only as far as needed (no jump)
	core.files_select_in(core.tree_view(), path)
	fu.reveal_near = true
	ui_do(core.Set_Focus{"files"})
}

files_cancel_edit :: proc() {
	fu.edit = .None
	fu.input_at = {}
	delete(fu.edit_err)
	fu.edit_err = ""
	if state.focus_widget == "files_name" do ui_do(core.Set_Focus{"files"})
}

// Set_Focus commands this window sent for anything but the name field (ui_do counts them).
ui_focus_away: u64

@(private = "file")
ev_in_field: bool
@(private = "file")
ev_away: u64

// Around each of this window's events (event(), main.odin): the edit is armed to commit on blur
// only by an event that moved the keyboard out of the name field here: one that sent a Set_Focus
// elsewhere (a click on a row, ⌘K, ⇧⌘E…), or a press outside the field (its command may move
// the keyboard another way). Keys typed into the field (⌘A, ⌘V, ⌃A…) never arm it, and a press
// that leaves the keyboard in the field is disarmed (files_edit_check). set_focus is anyone's: a
// focus change from a script, an agent or a browser cancels instead of renaming to a half-typed
// name with the user's authority.
files_event_begin :: proc(e: ^sapp.Event) {
	ev_in_field = fu.edit != .None && state.focus_widget == "files_name"
	ev_away = ui_focus_away
	if ev_in_field && e.type == .MOUSE_DOWN && !inside(clay.ID("files_name_box"), e.mouse_x, e.mouse_y) do fu.input_at = time.tick_now()
}

files_event_end :: proc() {
	if ev_in_field && fu.edit != .None && ui_focus_away != ev_away do fu.input_at = time.tick_now() // not an edit this event ended (Enter, Esc)
	ev_in_field = false
}

// A separate core answers a command within this (its 250 ms): until then a press that armed the
// edit is not taken back just because the keyboard has not moved yet.
FILES_FOCUS_ANSWER :: 400 * time.Millisecond
// An armed edit commits on a focus change at most this long after its event.
FILES_BLUR_OWN :: 2 * time.Second

// The name field lost the keyboard. After this window's own event moved it (files_event_begin):
// a changed name is renamed and a typed name is created (as Finder and VS Code do; an empty one
// cancels). A focus change from anywhere else cancels.
files_edit_check :: proc() {
	if client.focus_wait != "" do return // a Set_Focus on its way (machine_edit_begin): not lost yet
	if fu.edit == .None do return
	if state.focus_widget == "files_name" {
		// a frame that ends with the field still holding the keyboard: what armed it did not move it
		if fu.input_at != {} && (!client_separate() || time.tick_since(fu.input_at) >= FILES_FOCUS_ANSWER) do fu.input_at = {}
		return
	}
	own := fu.input_at != {} && time.tick_since(fu.input_at) < FILES_BLUR_OWN
	fu.input_at = {}
	if own && strings.trim_space(tf_text(&files_name_field)) != "" {
		files_commit_edit(blur = true)
		return
	}
	files_cancel_edit()
}

// Runs a command as the user now and returns its result (the inbox, as
// ui_do, but waiting for the answer: the field shows errors).
ui_run :: proc(cmd: core.Command) -> core.Result {
	r := client_run(cmd) // client.odin: after what was queued before it, its delta first
	return core.Result{ok = r.ok, error = r.error, created_id = r.created_id}
}

// Esc in the filter field clears it; Enter or ↓ moves into the tree.
files_filter_key :: proc(key: sapp.Keycode) -> bool {
	#partial switch key {
	case .ESCAPE:
		ui_do(core.Set_Files_Filter{text = ""})
		ui_do(core.Set_Focus{"files"})
		return true
	case .ENTER, .KP_ENTER, .DOWN:
		rows := core.tree_rows()
		if len(rows) > 0 && rows[0].more == 0 {
			core.files_select_in(core.tree_view(), rows[0].path)
			files_scroll_to(0, len(rows))
			// Enter while filtering opens the best match
			if key != .DOWN && rows[0].kind == .File && state.files.filter != "" do ui_do(core.Open_File{path = rows[0].path, session = files_session()})
		}
		ui_do(core.Set_Focus{"files"})
		return true
	}
	return false
}

Settings_Row_Op :: enum u8 {
	Button, // the row's own button (Turn on, Change…, Log in…, Install…, Create…)
	Remove, // an account's or a machine's Remove
	Default, // an account's Make default
	Reset, // a subfolder's Reset (back to the default)
	Reveal, // a folder's Reveal in Finder
}

// What a Settings row's buttons do (settings_file_rows' rows): the Settings page's and, before it,
// the left column's Settings tab's. path: the row's.
settings_row_op :: proc(path: string, op: Settings_Row_Op) {
	switch op {
	case .Button:
		if path == core.ATLAS_MODEL_ROW do action_run("agent_model") // the Atlas group's model: pi's selector
		else if path == core.CLAUDE_FLAGS_ROW do action_run("claude_skip_permissions") // the Claude Code group's default flags
		else if strings.has_prefix(path, core.PI_EXT_ROW) { 	// the pi extensions group
			name := path[len(core.PI_EXT_ROW):]
			ui_do(core.Set_Pi_Extension{name = name, on = !core.pi_extension_on(name)})
		}
		else if settings_folder_button(path) {} // the Folders group (folders.odin)
		else if harness_settings_button(path) {} // the Coding agents group (ui_harness.odin)
		else if path != "" do core.settings_create(path) // the explicit click: then it opens
	case .Reset:
		if k, ok := core.folder_row_kind(path); ok do ui_do(core.Set_Folder{kind = k, path = ""})
	case .Remove:
		if strings.has_prefix(path, core.CLAUDE_ACCOUNT_ROW) do ui_do(core.Remove_Claude_Account{account = path[len(core.CLAUDE_ACCOUNT_ROW):], harness = .Claude})
		else if strings.has_prefix(path, core.CODEX_ACCOUNT_ROW) do ui_do(core.Remove_Claude_Account{account = path[len(core.CODEX_ACCOUNT_ROW):], harness = .Codex})
		else if no, ok := core.machine_row_no(path); ok do ui_do_menu(core.Machine_Remove{no = no}, "Remove") // asks first
	case .Default:
		if strings.has_prefix(path, core.CLAUDE_ACCOUNT_ROW) do ui_do(core.Set_Claude_Account_Default{account = path[len(core.CLAUDE_ACCOUNT_ROW):], harness = .Claude})
		else if strings.has_prefix(path, core.CODEX_ACCOUNT_ROW) do ui_do(core.Set_Claude_Account_Default{account = path[len(core.CODEX_ACCOUNT_ROW):], harness = .Codex})
	case .Reveal:
		if path == core.FOLDER_MAIN_ROW do ui_do(core.Reveal_In_Finder{path = state.settings.home_dir})
		else if k, ok := core.folder_row_kind(path); ok do ui_do(core.Reveal_In_Finder{path = core.folder_of(k)})
	}
}

// A Folders row's main button (folders.odin): Change… (the folder picker),
// Set up… (the sheet), Reveal (the old main folder). False: not such a row.
settings_folder_button :: proc(path: string) -> bool {
	// a Claude account's Rename… (the row's name field), Add account… (a folder picker)
	if path == core.CLAUDE_ACCOUNT_ADD_ROW || path == core.CLAUDE_ACCOUNT_MORE_ROW {
		action_run("claude_account_add")
		return true
	}
	if path == core.CLAUDE_ACCOUNT_SCAN_ROW {
		ui_do(core.Rescan{}) // looks for config folders again, then their projects and sessions
		return true
	}
	if strings.has_prefix(path, core.CLAUDE_ACCOUNT_ROW) {
		settings_page_open(.Agents)
		sp_edit_begin(.Rename_Account, path, core.claude_account_label_now(path[len(core.CLAUDE_ACCOUNT_ROW):], .Claude))
		return true
	}
	// a Codex account's (the same, with harness .Codex)
	if path == core.CODEX_ACCOUNT_ADD_ROW {
		action_run("codex_account_add")
		return true
	}
	if strings.has_prefix(path, core.CODEX_ACCOUNT_ROW) {
		settings_page_open(.Agents)
		sp_edit_begin(.Rename_Account, path, core.claude_account_label_now(path[len(core.CODEX_ACCOUNT_ROW):], harness = .Codex))
		return true
	}
	// Machines (machines.odin): Add a machine… opens the add field; a machine's button does what
	// the sidebar's does (machine_run_action)
	if path == core.MACHINE_ADD_ROW {
		machine_edit_begin()
		return true
	}
	if no, ok := core.machine_row_no(path); ok {
		machine_run_action(no)
		return true
	}
	// another machine's coding agent: its command copied, to run in a shell tab there (read-only here)
	if no, id, ok := core.machine_check_row(path); ok {
		for m in state.machines do if m.no == no do for c in m.checklist do if c.id == id && c.command != "" {
			if win_os.set_clipboard != nil do win_os.set_clipboard(c.command)
			toast_show(fmt.tprintf("Copied: %s (run it in a shell tab on %s)", c.command, m.name))
		}
		return true
	}
	switch {
	case path == core.WEB_ACCESS_ROW:
		ui_do_menu(core.Set_Web_Access{on = !state.settings.web_access}, "Web access") // on: asks first
		return true
	case path == core.WEB_LISTEN_ROW:
		settings_page_web_listen_edit()
		return true
	case path == core.WEB_PAIR_ROW:
		web_pair_start()
		return true
	case strings.has_prefix(path, core.WEB_DEVICE_ROW):
		r := ui_run(core.Web_Revoke{id = path[len(core.WEB_DEVICE_ROW):]})
		toast_show(r.ok ? "Revoked: that browser is signed out" : r.error, !r.ok)
		return true
	}
	if path == core.MACHINE_REACH_ROW {
		ui_do_menu(core.Set_Machines_Reachable{on = !state.settings.machines_reachable}, "Allow other machines to connect") // on: asks first
		return true
	}
	if path == core.MACHINE_SSH_ROW {
		ui_do_menu(core.Set_Remote_Machines{on = true}, "Turn on Machines over SSH")
		return true
	}
	switch path {
	case core.FOLDER_MAIN_ROW:
		if state.settings.home_dir == "" do action_run("setup")
		else do action_run("home_dir")
		return true
	case core.FOLDER_PREV_ROW:
		ui_do(core.Reveal_In_Finder{path = state.home_dir_prev})
		return true
	case core.FOLDER_ENV_ROW:
		return true
	}
	if k, ok := core.folder_row_kind(path); ok {
		folder_pick_kind = k
		action_run("folder_change")
		return true
	}
	return false
}

// Where a keyboard move to row `to` lands: past folders' error rows (no file of their own), on in the
// direction of travel (back: upwards), else the other way; -1 = nowhere.
files_move_target :: proc(rows: []core.Files_Row, to: int, back: bool) -> int {
	if len(rows) == 0 do return -1
	skip :: proc(r: core.Files_Row) -> bool {return r.error != ""}
	j := clamp(to, 0, len(rows) - 1)
	if rows[j].more > 0 && j > 0 do j -= 1
	step := back ? -1 : 1
	for k := j; k >= 0 && k < len(rows); k += step do if !skip(rows[k]) do return k
	for k := j; k >= 0 && k < len(rows); k -= step do if !skip(rows[k]) do return k
	return -1
}
