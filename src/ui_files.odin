package main

// The left column's tab switch (Sessions | Files | Settings) and the two
// trees: the Files tab and the Settings tab (settings_files.odin builds its
// rows; the same rows, keys, filter and menus here). The header (the
// project's name, or the Settings tab's title, and their buttons), the filter field,
// then the tree (files.odin) as a virtualised list: only the rows in view
// are laid out.
// Every action is a command (ui_do) or an action from actions.odin, and has
// a button: the header's, the row's "…" and the right-click menu.
//
// Mouse: a click selects; on release a folder opens or closes and a file
// opens in a preview tab (a double-click or Enter keeps it). Dragging a row
// onto a terminal pastes its quoted path. Keyboard (focus widget "files"):
// ↑/↓ move, ←/→ close/open or go to the parent/child, Enter opens, Space
// previews, F2 renames, ⌘⌫ deletes (it asks first), Esc gives the keyboard
// back. Renaming is inline (focus widget "files_name"); new files and folders
// get a name field above the list.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Files_Hit_Kind :: enum u8 {
	Tab_Sessions,
	Tab_Files,
	Tab_Settings,
	Tab_Jobs,
	Tool, // index: Files_Tool, or Settings_Tool on the Settings tab
	Filter,
	Filter_Clear,
	Row,
	More,
	List, // empty space in the list
	Name, // the inline name field
	Create, // a missing settings file's Create button (index: the drawn slot)
	Folder_Reset, // a Folders row's Reset (folders.odin)
	Folder_Reveal, // a Folders row's Reveal in Finder
	Account_Remove, // a Claude account's Remove (claude_accounts.odin)
	Account_Default, // a Claude account's Make default
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

// The Settings tab's header buttons.
Settings_Tool :: enum {
	Collapse_All,
	Refresh,
	Reveal,
}

SETTINGS_TOOLS := [Settings_Tool]struct {
	action: string,
	icon:   core.Icon,
}{
	.Collapse_All = {"settings_collapse_all", .Collapse_All},
	.Refresh      = {"settings_refresh", .Refresh},
	.Reveal       = {"settings_reveal_finder", .Reveal},
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
	first:      int, // row index of slot 0
	view_h:     f32, // the list's height at the last layout (logical px)
	// a press on a row: acts on release unless it became a drag
	press:      bool,
	press_path: string, // owned: what was pressed (the rows may change before the release)
	press_dir:  bool,
	press_at:   [2]f32,
	press_clicks: int,
	dragging:   bool,
	drag_path:  string, // owned
}

@(private = "file")
fu: Files_Ui

// The Files tab shows now.
files_shown :: proc() -> bool {return state.layout.left_open && state.layout.left_tab == .Files}

// The Settings tab shows now.
settings_shown :: proc() -> bool {return state.layout.left_open && state.layout.left_tab == .Settings}

@(private = "file")
on_settings :: proc() -> bool {return state.layout.left_tab == .Settings}

// ---- layout ----

// The segmented switch under the title bar: Sessions | Files | Settings | Jobs.
left_tabs_switch :: proc() {
	th := theme()
	if clay.UI(clay.ID("lefttabs"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(LEFT_TABS_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		// labels while each fits its segment, else icons (tooltips name them)
		left, _ := column_widths()
		seg := (left - 2 * SP_2 - 4 - 2 * f32(len(core.Left_Tab) - 1)) / f32(len(core.Left_Tab))
		icons_only := false
		for tab in core.Left_Tab {
			extra := tab == .Jobs && state.jobs_unread > 0 ? f32(DOT + SP_1) : 0
			if text_w(LEFT_TAB_LABELS[tab], FONT_UI_SMALL) / app.dpi + extra + 2 * SP_1 > seg do icons_only = true
		}
		for tab in core.Left_Tab {
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

// The Files or Settings tab: header, filter, the tree. Below the switch in the column.
files_panel :: proc(row_w_: f32) {
	row_w := row_w_
	th := theme()
	virtual.arena_destroy(&fu.arena)
	_ = virtual.arena_init_growing(&fu.arena)
	a := virtual.arena_allocator(&fu.arena)
	fu.drawn = make([dynamic]string, a)
	fu.drawn_dir = make([dynamic]bool, a)
	settings := on_settings()
	v := core.tree_view()
	root := settings ? "" : core.files_root()
	if !settings do files_follow_active(root)

	// header: the folder's name, then its buttons
	if settings {
		settings_head(row_w)
	} else if clay.UI(clay.ID("files_head"))({
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
	if !settings && root != "" {
		wt_switcher(row_w) // which checkout the tree shows (ui_worktrees.odin)
		gap(SP_1)
	}
	files_filter_row(row_w)
	gap(SP_1)
	if settings && core.sf_error != "" {
		if clay.UI(clay.ID("sf_error"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_1), 0, pu(SP_1)}}}) {
			clay.TextDynamic(core.sf_error, txt(th.error, FONT_UI_SMALL))
		}
	}
	if fu.edit == .New_File || fu.edit == .New_Folder do files_new_row(root)

	if !settings && root == "" {
		empty_state("No project", "Pick a project or open a session", row_w)
		return
	}
	rows := core.tree_rows()
	if d := clay.GetElementData(clay.ID("files_list")); d.found do fu.view_h = d.boundingBox.height / app.dpi
	if fu.view_h <= 0 do fu.view_h = 600
	if v.reveal {
		v.reveal = false
		if i := core.files_row_of(rows, v.cursor); i >= 0 do files_scroll_to(i, len(rows), center = true)
	}
	first, last, sc := core.files_visible(len(rows), v.scroll, fu.view_h, FILES_ROW_H)
	v.scroll = sc
	fu.first = first
	offset := sc - f32(first) * FILES_ROW_H
	total := f32(len(rows)) * FILES_ROW_H
	overflow := total > fu.view_h
	if overflow do row_w -= px(FILES_SCROLL_THUMB + 2)
	if clay.UI(clay.ID("files_list"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childGap = pu(2)}}) {
		if clay.UI(clay.ID("files_rows"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = {0, -px(offset)}},
		}) {
			if len(rows) == 0 && settings {
				if state.files.filter != "" do empty_state("No matching settings files", "Esc in the filter clears it", row_w)
				else do empty_state("No settings files", settings_empty_hint(), row_w)
			} else if len(rows) == 0 {
				d := core.files_dir(root, false)
				if state.files.filter != "" do empty_state("No matching files", "Esc in the filter clears it", row_w)
				else if d.err != "" do empty_state("Cannot list this folder", d.err, row_w)
				else do empty_state("Empty folder", "New file (the first button) starts one", row_w)
			}
			for i in first ..< last do files_row(rows[i], len(fu.drawn), row_w, a)
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

// The Settings tab's header, its tooltip and its empty state: they name the harness installed, or
// neither when both are (or none).
settings_title :: proc() -> string {
	pi, cl := core.pi_installed(), core.claude_installed()
	if pi && !cl do return "pi settings"
	if cl && !pi do return "Claude Code settings"
	return "Settings"
}
settings_tip :: proc() -> string {
	pi, cl := core.pi_installed(), core.claude_installed()
	if pi && !cl do return "pi's settings files"
	if cl && !pi do return "Claude Code's settings files"
	return "Settings files"
}
settings_empty_hint :: proc() -> string {
	pi, cl := core.pi_installed(), core.claude_installed()
	if pi && !cl do return "pi makes them as you use it"
	if cl && !pi do return "Claude Code makes them as you use it"
	if pi && cl do return "pi and Claude Code make them as you use them"
	return "Your agents make them as you use them"
}

// The Settings tab's header: its title, then its buttons.
@(private = "file")
settings_head :: proc(row_w: f32) {
	th := theme()
	if clay.UI(clay.ID("files_head"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), 0, 0, 0}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}},
	}) {
		room := row_w - px(PAD_ROW + KIND_ICON + GAP_INLINE + GAP_GROUP) - f32(len(Settings_Tool)) * px(FILES_TOOL + GAP_BUTTONS)
		icon(.Sliders, th.text_muted, KIND_ICON)
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_INLINE - GAP_BUTTONS)), clay.SizingFit()}}}) {}
		clay.TextDynamic(clip(settings_title(), room, WEIGHT_BOLD), txt(th.text_secondary, WEIGHT_BOLD))
		if clay.UI()({layout = {sizing = {clay.SizingGrow({min = px(GAP_GROUP - 2 * GAP_BUTTONS)}), clay.SizingFit()}}}) {}
		for tool in Settings_Tool {
			id := clay.ID("settool", u32(tool))
			enabled := action_ok(SETTINGS_TOOLS[tool].action)
			hovered := enabled && ui_hover == Hit(Hit_Files{what = .Tool, index = int(tool)})
			bg, em := overlay(id, false, hovered)
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFixed(px(FILES_TOOL)), clay.SizingFixed(px(FILES_TOOL))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				col := enabled ? mix(th.text_muted, th.text, em) : with_alpha(th.text_muted, DISABLED_ALPHA)
				icon(SETTINGS_TOOLS[tool].icon, col, ICON_SIZE_SM)
			}
		}
	}
}

// Test mode (autotest's `@PATH` row index): the slot of the drawn Files/Settings row whose path
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
files_row :: proc(r: core.Files_Row, slot: int, row_w: f32, a: runtime.Allocator) {
	th := theme()
	append(&fu.drawn, r.more > 0 || r.error != "" ? "" : strings.clone(r.path, a))
	append(&fu.drawn_dir, r.kind == .Dir)
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
	if r.head {
		// a group of the Settings tab
		if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2), pu(SP_1), pu(SP_1), 0}, childAlignment = {y = .Center}}}) {
			clay.TextDynamic(clip(r.name, row_w - px(SP_2 + SP_1), WEIGHT_HEADER), txt(th.text_muted, WEIGHT_HEADER))
		}
		return
	}
	v := core.tree_view()
	more_hover := ui_hover == Hit(Hit_Files{what = .More, index = slot})
	hovered := ui_hover == Hit(Hit_Files{what = .Row, index = slot}) || more_hover
	selected := r.path == v.cursor
	active := r.path == v.active_file
	if on_settings() {
		e := tab_editor()
		active = e != nil && e.view == .File && e.path == r.path
	}
	bg, em := overlay(id, selected, hovered)
	focused := state.focus_widget == "files" && selected
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H))}, padding = {pu(SP_2 + FILES_INDENT * f32(r.depth)), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(focused ? th.accent : {}), width = clay.BorderOutside(pu(focused ? core.BORDER_W : 0))},
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
		if r.missing do col = with_alpha(th.text_muted, 0.8) // not there yet
		weight: u16 = active ? WEIGHT_BOLD : WEIGHT_REGULAR
		blabel := r.button != "" ? r.button : "Create" // a missing file's Create, or a setting row's button
		create_w := r.missing || r.button != "" ? text_w(blabel, FONT_UI_SMALL) + px(2 * SP_2) : 0
		// a Folders row's icon buttons (Reset, Reveal in Finder) before its Change…
		icons_w := f32(int(r.reset) + int(r.reveal) + int(r.remove) + int(r.make_default)) * px(ROW_BUTTON - SP_1 + SP_1)
		room := row_w - px(2 * SP_2 + FILES_INDENT * f32(r.depth) + SP_3 + SP_1) - max(px(ROW_BUTTON + SP_1), create_w + icons_w + px(SP_1))
		if fu.edit == .Rename && fu.target == r.path && state.focus_widget == "files_name" {
			files_name_box(room)
		} else if r.rel != "" {
			// filter results: the name, then its folder
			dir := filepath.dir(r.rel)
			nw := min(text_w(r.name, weight), room)
			clay.TextDynamic(clip(r.name, nw, weight), txt(col, weight))
			if dir != "." do clay.TextDynamic(clip(dir, room - nw - px(SP_1), FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		} else if r.note != "" {
			// a settings file: its name, then what it is
			nw := min(text_w(r.name, weight), room)
			clay.TextDynamic(clip(r.name, nw, weight), txt(col, weight))
			if nr := room - nw - px(SP_1); nr > px(SP_6) do clay.TextDynamic(clip(r.note, nr, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		} else {
			clay.TextDynamic(clip(r.name, room, weight), txt(col, weight))
		}
		spacer()
		for b in ([]struct {
				on:   bool,
				what: Files_Hit_Kind,
				name: string,
				ic:   core.Icon,
			}{{r.reset, .Folder_Reset, "freset", .Refresh}, {r.reveal, .Folder_Reveal, "freveal", .Reveal}, {r.make_default, .Account_Default, "fdefault", .Check}, {r.remove, .Account_Remove, "fremove", .Close}}) {
			if !b.on do continue
			bid := clay.ID(b.name, u32(slot))
			bh := ui_hover == Hit(Hit_Files{what = b.what, index = slot})
			bbg, bem := overlay(bid, false, bh)
			if clay.UI(bid)({
				layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON - SP_1)), clay.SizingFixed(px(ROW_BUTTON - SP_1))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				icon(b.ic, mix(th.text_muted, th.text, bem), ICON_SIZE_SM)
			}
		}
		if r.missing || r.button != "" {
			cid := clay.ID("fcreate", u32(slot))
			ch := ui_hover == Hit(Hit_Files{what = .Create, index = slot})
			cbg, cem := overlay(cid, false, ch)
			if ch == false do cbg = cc(mix(th.bg_elevated, th.text, TINT_BUTTON))
			if clay.UI(cid)({
				layout = {sizing = {clay.SizingFixed(create_w), clay.SizingFixed(px(FILES_ROW_H - 4))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = cbg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				clay.TextDynamic(blabel, txt(mix(th.text_secondary, th.text, cem), FONT_UI_SMALL))
			}
		} else if hovered && !(on_settings() && core.settings_setting_row(r.path)) {
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
				field_text(clay.ID("files_filter_text"), &files_filter_field, on_settings() ? "Filter settings" : "Filter files")
			} else {
				room := row_w - px(3 * SP_2 + SP_6 + ICON_SIZE_SM)
				text := state.files.filter
				if text != "" do clay.TextDynamic(clip(text, room), txt(th.text))
				else do clay.TextDynamic(clip(on_settings() ? "Filter settings" : "Filter files", room), txt(th.text_muted))
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

// "New file in <folder>": the name field above the list.
@(private = "file")
files_new_row :: proc(root: string) {
	th := theme()
	if clay.UI(clay.ID("files_new"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = {pu(SP_2), pu(SP_1), 0, pu(SP_1)}, childGap = pu(2)},
	}) {
		in_dir := fu.target == root ? filepath.base(root) : (root != "" && strings.has_prefix(fu.target, root) && len(fu.target) > len(root) ? fu.target[len(root) + 1:] : core.fs_display(fu.target))
		clay.TextDynamic(fmt.tprintf("%s in %s", fu.edit == .New_File ? "New file" : "New folder", in_dir), txt(th.text_muted, FONT_UI_SMALL))
		if state.focus_widget == "files_name" do files_name_box(0)
		if fu.edit_err != "" do clay.TextDynamic(fu.edit_err, txt(th.error, FONT_UI_SMALL))
	}
}

// The name field (rename in a row, or new file/folder): accent ring.
@(private = "file")
files_name_box :: proc(w: f32) {
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
			field_text(clay.ID("files_name_text"), &files_name_field, "")
		}
	}
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
	for tab in core.Left_Tab do if clay.PointerOver(clay.ID("lefttab", u32(tab))) do return Hit_Files{what = LEFT_TAB_HITS[tab]}
	if state.layout.left_tab == .Sessions || state.layout.left_tab == .Jobs do return nil
	if on_settings() {
		for tool in Settings_Tool do if clay.PointerOver(clay.ID("settool", u32(tool))) && action_ok(SETTINGS_TOOLS[tool].action) do return Hit_Files{what = .Tool, index = int(tool)}
	} else {
		for tool in Files_Tool do if clay.PointerOver(clay.ID("filestool", u32(tool))) && action_ok(FILES_TOOLS[tool].action) do return Hit_Files{what = .Tool, index = int(tool)}
	}
	if !on_settings() && clay.PointerOver(clay.ID("wt_switch")) do return Hit_Files{what = .Switcher}
	if clay.PointerOver(clay.ID("files_filter_clear")) do return Hit_Files{what = .Filter_Clear}
	if clay.PointerOver(clay.ID("files_filter_box")) do return Hit_Files{what = .Filter}
	if clay.PointerOver(clay.ID("files_name_box")) do return Hit_Files{what = .Name}
	if !clay.PointerOver(clay.ID("files_list")) do return nil
	for p, i in fu.drawn {
		if clay.PointerOver(clay.ID("fretry", u32(i))) do return Hit_Files{what = .Retry, index = i} // an error row (drawn "")
		if p == "" do continue
		if clay.PointerOver(clay.ID("fcreate", u32(i))) do return Hit_Files{what = .Create, index = i}
		if clay.PointerOver(clay.ID("freset", u32(i))) do return Hit_Files{what = .Folder_Reset, index = i}
		if clay.PointerOver(clay.ID("freveal", u32(i))) do return Hit_Files{what = .Folder_Reveal, index = i}
		if clay.PointerOver(clay.ID("fremove", u32(i))) do return Hit_Files{what = .Account_Remove, index = i}
		if clay.PointerOver(clay.ID("fdefault", u32(i))) do return Hit_Files{what = .Account_Default, index = i}
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
	case .Tab_Settings:
		if a := action_by_id("settings"); a != nil do return settings_tip(), a.keys
	case .Tab_Jobs:
		return state.jobs_unread > 0 ? fmt.tprintf("%s's jobs: %d unread", core.agent_name(), state.jobs_unread) : fmt.tprintf("%s's jobs", core.agent_name()), ""
	case .Tool:
		id := on_settings() ? SETTINGS_TOOLS[Settings_Tool(h.index)].action : FILES_TOOLS[Files_Tool(h.index)].action
		if a := action_by_id(id); a != nil do return action_label(a), a.keys
	case .Create:
		if h.index >= 0 && h.index < len(fu.drawn) && fu.drawn[h.index] == core.ATLAS_MODEL_ROW do return "Open pi's model selector in Atlas", "⌃L"
		if h.index >= 0 && h.index < len(fu.drawn) && strings.has_prefix(fu.drawn[h.index], core.PI_EXT_ROW) {
			name := fu.drawn[h.index][len(core.PI_EXT_ROW):]
			return fmt.tprintf("%s %s in the pi tabs started from now on (running tabs: the restart bar)", core.pi_extension_on(name) ? "Turn off" : "Turn on", name), ""
		}
		if h.index >= 0 && h.index < len(fu.drawn) && fu.drawn[h.index] == core.CLAUDE_FLAGS_ROW {
			if a := action_by_id("claude_skip_permissions"); a != nil do return state.settings.claude_skip_permissions ? "New Claude tabs you start ask before tools again (open tabs keep their flags)" : "Start the Claude tabs you start with --dangerously-skip-permissions (never agents' tabs or read-only chats)", a.keys
		}
		if h.index >= 0 && h.index < len(fu.drawn) {
			p := fu.drawn[h.index]
			if tip := harness_settings_tip(p, true); tip != "" do return tip, ""
			if p == core.FOLDER_MAIN_ROW do return state.settings.home_dir != "" ? "Pick another main folder (nothing is moved; the old one is offered in Finder)" : "Set up Deckhand: choose the main folder", ""
			if p == core.FOLDER_PREV_ROW do return "Show the old main folder in Finder", ""
			if p == core.CLAUDE_ACCOUNT_SCAN_ROW do return "Look for Claude Code config folders again (by their account files; nothing is read)", ""
			if p == core.CLAUDE_ACCOUNT_MORE_ROW do return "Add another Claude Code account: pick its config folder (what CLAUDE_CONFIG_DIR names). Rescan sessions finds new ones in ~/.claude*", ""
			if p == core.CLAUDE_ACCOUNT_ADD_ROW do return "Add a Claude Code account: pick its config folder (what CLAUDE_CONFIG_DIR names; hidden folders: ⌘⇧.)", ""
			if strings.has_prefix(p, core.CLAUDE_ACCOUNT_ROW) do return "Rename this account (its name in Deckhand only)", ""
			if k, ok := core.folder_row_kind(p); ok do return fmt.tprintf("Pick the %s folder (%s)", core.FOLDER_NAMES[k], core.FOLDER_DOES[k]), ""
		}
		return "Create this file, then open it", ""
	case .Row:
		// the Settings tab's rows: where the file is and what it is
		if !on_settings() || h.index < 0 || h.index >= len(fu.drawn) || fu.drawn[h.index] == "" do break
		p := fu.drawn[h.index]
		if tip := harness_settings_tip(p, false); tip != "" do return tip, ""
		if p == core.ATLAS_MODEL_ROW do return fmt.tprintf("%s's model: %s", core.agent_name(), core.sf_model_note()), ""
		if p == core.CLAUDE_FLAGS_HEAD_ROW || p == core.CLAUDE_FLAGS_ROW || p == core.CLAUDE_FLAGS_WARN_ROW do return fmt.tprintf("Default Claude Code flags for new tabs: %s. Only the tabs you start (new tab, session, chat, your resume); never agents', panels' or apps', nor a read-only chat. With it, Claude edits files and runs commands without asking.", state.settings.claude_skip_permissions ? "--dangerously-skip-permissions" : "none"), ""
		if strings.has_prefix(p, core.PI_EXT_ROW) {
			name := p[len(core.PI_EXT_ROW):]
			for e in core.pi_integration_optional() do if e.name == name do return fmt.tprintf("%s: %s. %s; default %s. Deckhand ships it and loads it into pi tabs, not jobs (pi -e); a change applies at a tab's next start.", e.name, e.does, e.on ? "On" : "Off", e.default_on ? "on" : "off"), ""
		}
		if p == core.FOLDER_MAIN_ROW do return fmt.tprintf("Main folder: %s", state.settings.home_dir != "" ? core.fs_display(state.settings.home_dir) : "not set"), ""
		if p == core.FOLDER_ENV_ROW do return "Your environment sets PI_KIT_NOTES_DIR: Deckhand passes it on as it is", ""
		if p == core.FOLDER_PREV_ROW do return fmt.tprintf("The main folder before: %s", core.fs_display(state.home_dir_prev)), ""
		if k, ok := core.folder_row_kind(p); ok {
			f := core.folder_of(k)
			return fmt.tprintf("%s: %s (%s)", core.FOLDER_DOES[k], f != "" ? core.fs_display(f) : "no main folder", core.folder_custom(k) ? "custom" : "default"), ""
		}
		for r in core.settings_tree_rows() do if r.path == p && r.note != "" do return fmt.tprintf("%s: %s", core.fs_display(p), r.note), ""
		return core.fs_display(p), ""
	case .Folder_Reset:
		if h.index >= 0 && h.index < len(fu.drawn) {
			if k, ok := core.folder_row_kind(fu.drawn[h.index]); ok {
				st := state.settings
				st.folders[k] = ""
				d := core.folder_path(st, k)
				return fmt.tprintf("Reset to the default (%s)", d != "" ? core.fs_display(d) : "none"), ""
			}
		}
	case .Folder_Reveal: return "Reveal in Finder", ""
	case .Retry:
		if r, ok := files_error_row(h.index); ok do return fmt.tprintf("%s. Retry lists the folder again", r.error), ""
	case .Account_Remove: return "Remove this account from Deckhand's list (its folder is not touched)", ""
	case .Account_Default: return "Make this the default account: new Claude sessions start in it unless their project last used another", ""
	case .Filter:       return on_settings() ? "Filter settings files" : "Filter files", ""
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
			if (h.what == .Row || h.what == .More) && fu.drawn[h.index] != "" && !core.settings_setting_row(fu.drawn[h.index]) do files_menu_at(fu.drawn[h.index], app.pointer)
			else if h.what == .List && !on_settings() do files_menu_at(core.files_root(), app.pointer)
			return true
		}
		if e.mouse_button != .LEFT do return true
		switch h.what {
		case .Tab_Sessions: ui_do(core.Set_Left_Tab{tab = .Sessions})
		case .Tab_Files:    ui_do(core.Set_Left_Tab{tab = .Files})
		case .Tab_Settings: ui_do(core.Set_Left_Tab{tab = .Settings})
		case .Tab_Jobs:     ui_do(core.Set_Left_Tab{tab = .Jobs})
		case .Tool:         action_run(on_settings() ? SETTINGS_TOOLS[Settings_Tool(h.index)].action : FILES_TOOLS[Files_Tool(h.index)].action)
		case .Create:
			if fu.drawn[h.index] == core.ATLAS_MODEL_ROW do action_run("agent_model") // the Atlas group's model: pi's selector
			else if fu.drawn[h.index] == core.CLAUDE_FLAGS_ROW do action_run("claude_skip_permissions") // the Claude Code group's default flags
			else if p := fu.drawn[h.index]; strings.has_prefix(p, core.PI_EXT_ROW) { 	// the pi extensions group
				name := p[len(core.PI_EXT_ROW):]
				ui_do(core.Set_Pi_Extension{name = name, on = !core.pi_extension_on(name)})
			}
			else if settings_folder_button(fu.drawn[h.index]) {} // the Folders group (folders.odin)
			else if harness_settings_button(fu.drawn[h.index]) {} // the Coding agents group (ui_harness.odin)
			else if fu.drawn[h.index] != "" do core.settings_create(fu.drawn[h.index]) // the explicit click: then it opens
		case .Folder_Reset:
			if k, ok := core.folder_row_kind(fu.drawn[h.index]); ok do ui_do(core.Set_Folder{kind = k, path = ""})
		case .Account_Remove:
			if p := fu.drawn[h.index]; strings.has_prefix(p, core.CLAUDE_ACCOUNT_ROW) do ui_do(core.Remove_Claude_Account{account = p[len(core.CLAUDE_ACCOUNT_ROW):]})
		case .Account_Default:
			if p := fu.drawn[h.index]; strings.has_prefix(p, core.CLAUDE_ACCOUNT_ROW) do ui_do(core.Set_Claude_Account_Default{account = p[len(core.CLAUDE_ACCOUNT_ROW):]})
		case .Folder_Reveal:
			p := fu.drawn[h.index]
			if p == core.FOLDER_MAIN_ROW do ui_do(core.Reveal_In_Finder{path = state.settings.home_dir})
			else if k, ok := core.folder_row_kind(p); ok do ui_do(core.Reveal_In_Finder{path = core.folder_of(k)})
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
				b := d.boundingBox
				files_menu_at(fu.drawn[h.index], {b.x, b.y + b.height})
			}
		case .Row:
			p := fu.drawn[h.index]
			if p == "" do return true
			core.files_select_in(core.tree_view(), p)
			core.tree_view().reveal = false
			if state.focus_widget != "files" do ui_do(core.Set_Focus{"files"})
			if core.settings_setting_row(p) do return true // a setting, not a file: nothing to open or drag
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
		{
			p := fu.press_path
			if fu.press_dir {
				if fu.press_clicks == 1 do files_toggle(p)
			} else {
				if core.path_kind(p) == .File do ui_do(core.Open_File{path = p, session = files_session(), preview = fu.press_clicks < 2}) // a missing settings file: its Create button
			}
		}
		return true
	case .MOUSE_LEAVE:
		// a press that leaves the window is dropped (its release may never come)
		if fu.press || fu.dragging do app.redraw = true
		fu.press, fu.dragging = false, false
		return false
	case .MOUSE_SCROLL:
		if !(files_shown() || settings_shown()) || !inside(clay.ID("files_list"), e.mouse_x, e.mouse_y) do return false
		v := core.tree_view()
		v.scroll -= e.scroll_y * SCROLL_STEP
		_, _, v.scroll = core.files_visible(len(v.rows), v.scroll, fu.view_h, FILES_ROW_H)
		app.redraw = true
		return true
	case .KEY_DOWN, .CHAR, .KEY_UP:
		if state.focus_widget != "files" do return false
		if e.type != .KEY_DOWN do return e.modifiers & sapp.MODIFIER_SUPER == 0
		return files_key(e)
	}
	return false
}

// A key while the tree has the keyboard. ⌘ shortcuts other than ⌘⌫ pass.
@(private = "file")
files_key :: proc(e: ^sapp.Event) -> bool {
	cmd := e.modifiers & sapp.MODIFIER_SUPER != 0
	if cmd && e.key_code != .BACKSPACE && e.key_code != .UP && e.key_code != .DOWN do return false
	if cmd && e.modifiers & sapp.MODIFIER_ALT != 0 do return false // ⌥⌘↑ ⌥⌘↓: sessions (menubar.odin)
	app.redraw = true
	rows := core.tree_rows()
	i := core.files_row_of(rows, core.tree_view().cursor)
	move :: proc(rows: []core.Files_Row, to: int, back := false) {
		k := files_move_target(rows, to, back)
		if k < 0 do return
		core.files_select_in(core.tree_view(), rows[k].path)
		core.tree_view().reveal = false
		files_scroll_to(k, len(rows))
	}
	page := max(int(fu.view_h / FILES_ROW_H) - 1, 1)
	#partial switch e.key_code {
	case .ESCAPE: ui_do(core.Set_Focus{""})
	case .UP:
		// up past a heading: the row above it
		move(rows, cmd ? 0 : (i < 0 ? 0 : i - 1), back = true)
	case .DOWN:   move(rows, cmd ? len(rows) - 1 : i + 1)
	case .HOME:   move(rows, 0)
	case .END:    move(rows, len(rows) - 1)
	case .PAGE_UP: move(rows, i - page, back = true)
	case .PAGE_DOWN: move(rows, i + page)
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
		else if rows[i].button != "" && !settings_folder_button(rows[i].path) do action_run("agent_model")
		else if !rows[i].missing do ui_do(core.Open_File{path = rows[i].path, session = files_session(), preview = e.key_code == .SPACE})
	case .F2:
		if i >= 0 && files_may_change(rows[i].path) do files_step(rows[i].path, .Rename)
	case .BACKSPACE, .DELETE:
		if i >= 0 && (cmd || e.key_code == .DELETE) && files_may_change(rows[i].path) do ui_do(core.Delete_Path{path = rows[i].path})
	}
	return true
}

// Opens or closes a folder; a failure shows (never a click that does nothing).
files_toggle :: proc(path: string) {
	ui_do_menu(core.Files_Expand{path = path, expanded = !core.files_is_open(path)}, "Open folder")
}

// The error row drawn at slot (files_row: rows [fu.first, ...) are drawn).
@(private = "file")
files_error_row :: proc(slot: int) -> (core.Files_Row, bool) {
	rows := core.tree_rows()
	i := fu.first + slot
	if slot < 0 || i >= len(rows) || rows[i].error == "" do return {}, false
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

// Whether rename and delete may be offered for path: always in the Files
// tab; in the Settings tab only inside prompts/, skills/, extensions/ and a
// project's .pi/ (settings_row_editable), never pi's own config files.
files_may_change :: proc(path: string) -> bool {return !on_settings() || core.settings_row_editable(path)}

// The Settings tab's row menu: Open, New file/folder in prompts/ and
// skills/, Rename and Move to Trash where files_may_change, Reveal, Copy path.
@(private = "file")
settings_menu_items :: proc(path: string, items: ^[dynamic]core.Menu_Item) {
	kind := core.path_kind(path)
	is_dir := kind == .Dir
	sep :: proc(items: ^[dynamic]core.Menu_Item) {append(items, core.Menu_Item{sep = true})}
	if kind == .File {
		append(items, core.Menu_Item{label = "Open", keys = "↩", cmd = core.Open_File{path = path, session = files_session()}})
		append(items, core.Menu_Item{label = "Open in preview", keys = "Space", cmd = core.Open_File{path = path, session = files_session(), preview = true}})
		if core.md_is_markdown_path(path) do append(items, core.Menu_Item{label = "Open Markdown preview", cmd = core.Markdown_Open{path = path, session = files_session()}})
		sep(items)
	}
	if core.settings_new_ok(is_dir ? path : filepath.dir(path)) {
		append(items, core.Menu_Item{label = "New file…", files = .New_File})
		append(items, core.Menu_Item{label = "New folder…", files = .New_Folder})
		sep(items)
	}
	if files_may_change(path) {
		append(items, core.Menu_Item{label = "Rename…", keys = "F2", files = .Rename})
		append(items, core.Menu_Item{label = "Move to Trash…", keys = "⌘⌫", cmd = core.Delete_Path{path = path}})
		sep(items)
	}
	if kind != .Missing do append(items, core.Menu_Item{label = "Reveal in Finder", cmd = core.Reveal_In_Finder{path = path}})
	append(items, core.Menu_Item{label = "Copy path", files = .Copy_Path})
}

// The row menu's items for path (ui_sidebar.odin's menu draws and runs them).
files_menu_items :: proc(path: string, items: ^[dynamic]core.Menu_Item) {
	if on_settings() {
		settings_menu_items(path, items)
		return
	}
	root := core.files_root()
	is_dir := core.path_kind(path) == .Dir
	is_root := path == root
	sep :: proc(items: ^[dynamic]core.Menu_Item) {append(items, core.Menu_Item{sep = true})}
	if !is_dir {
		append(items, core.Menu_Item{label = "Open", keys = "↩", cmd = core.Open_File{path = path, session = files_session()}})
		append(items, core.Menu_Item{label = "Open in preview", keys = "Space", cmd = core.Open_File{path = path, session = files_session(), preview = true}})
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
		win_os.set_clipboard(path)
		return true
	case .Copy_Relative:
		rel := path
		if strings.has_prefix(path, root) && len(path) > len(root) do rel = path[len(root) + 1:]
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
	if on_settings() {
		// the Settings tab: the selected prompts/ or skills/ folder (else none)
		p = core.settings_ui.cursor
		dir := core.path_kind(p) == .Dir ? p : filepath.dir(p)
		return p != "" && core.settings_new_ok(dir) ? dir : ""
	}
	if p == "" || !strings.has_prefix(p, root) do return root
	return core.path_kind(p) == .Dir ? p : filepath.dir(p)
}

files_begin_edit :: proc(mode: Files_Edit_Mode, target, text: string, focus := true) {
	fu.edit = mode
	delete(fu.target)
	fu.target = strings.clone(target)
	delete(fu.edit_err)
	fu.edit_err = ""
	tf_set(&files_name_field, text)
	tf_select_all(&files_name_field)
	if mode == .Rename {
		core.files_select_in(core.tree_view(), target)
	} else if target != core.files_root() {
		ui_do(core.Files_Expand{path = target, expanded = true})
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

// Enter in the name field: create or rename; an error keeps the field.
files_commit_edit :: proc() {
	name := strings.trim_space(tf_text(&files_name_field))
	if fu.edit == .None || (fu.edit == .Rename && name == "") {
		files_cancel_edit()
		return
	}
	if err := files_name_error(name); err != "" {
		delete(fu.edit_err)
		fu.edit_err = strings.clone(err)
		app.redraw = true
		return
	}
	// a Claude account's name (Settings → Claude accounts): no file is renamed
	if fu.edit == .Rename && strings.has_prefix(fu.target, core.CLAUDE_ACCOUNT_ROW) {
		ar := ui_run(core.Rename_Claude_Account{account = fu.target[len(core.CLAUDE_ACCOUNT_ROW):], label = name})
		if !ar.ok {
			delete(fu.edit_err)
			fu.edit_err = strings.clone(ar.error)
			app.redraw = true
			return
		}
		fu.edit = .None
		ui_do(core.Set_Focus{"files"})
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
		delete(fu.edit_err)
		fu.edit_err = strings.clone(r.error)
		app.redraw = true
		return
	}
	core.files_select_in(core.tree_view(), path)
	fu.edit = .None
	ui_do(core.Set_Focus{"files"})
}

files_cancel_edit :: proc() {
	fu.edit = .None
	delete(fu.edit_err)
	fu.edit_err = ""
	if state.focus_widget == "files_name" do ui_do(core.Set_Focus{"files"})
}

// The name field lost the keyboard (a click elsewhere): the edit ends.
files_edit_check :: proc() {
	if fu.edit != .None && state.focus_widget != "files_name" {
		fu.edit = .None
		delete(fu.edit_err)
		fu.edit_err = ""
	}
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
		first := 0
		for first < len(rows) && rows[first].head do first += 1 // the Settings tab's headings
		if first > 0 && first < len(rows) {
			core.files_select_in(core.tree_view(), rows[first].path)
			files_scroll_to(first, len(rows))
			if key != .DOWN && rows[first].kind == .File && state.files.filter != "" do ui_do(core.Open_File{path = rows[first].path, session = files_session()})
		} else if len(rows) > 0 && rows[0].more == 0 {
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
		label := core.claude_account_label_now(path[len(core.CLAUDE_ACCOUNT_ROW):])
		files_begin_edit(.Rename, path, label)
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

// Where a keyboard move to row `to` lands: past the Settings tab's group
// headings and folders' error rows (no file of their own), on in the
// direction of travel (back: upwards), else the other way; -1 = nowhere.
files_move_target :: proc(rows: []core.Files_Row, to: int, back: bool) -> int {
	if len(rows) == 0 do return -1
	skip :: proc(r: core.Files_Row) -> bool {return r.head || r.error != ""}
	j := clamp(to, 0, len(rows) - 1)
	if rows[j].more > 0 && j > 0 do j -= 1
	step := back ? -1 : 1
	for k := j; k >= 0 && k < len(rows); k += step do if !skip(rows[k]) do return k
	for k := j; k >= 0 && k < len(rows); k -= step do if !skip(rows[k]) do return k
	return -1
}
