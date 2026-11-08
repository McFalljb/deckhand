package main

// The top bar's toolbar and what hangs off it, so every action has a button
// as well as a shortcut:
//
//   - icon buttons (BUTTONS): each runs an action from actions.odin through
//     the inbox as the user (action_run), exactly like the palette; its
//     tooltip is that action's label and shortcut
//   - the search pill (opens the command palette)
//   - the settings popover (focus widget "settings"; a click on the gear):
//     appearance, look, reduce motion, Chats, rescan, keyboard shortcuts,
//     Edit settings files… (the left column's Settings tab, ⌘,: settings_files.odin)
//     and Set up pi-desk… (the first-run sheet, ui_setup.odin); every row runs an action
//   - the keyboard shortcuts sheet (focus widget "shortcuts"; ⌘/), listed
//     from the action table
//   - the one tooltip system: after the pointer rests TIP_DELAY on a control,
//     one redraw shows its label and shortcut (no redraws while waiting)

import "core:fmt"
import "core:strings"
import "core:time"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Button :: enum {
	Toggle_Left,
	New_Chat,
	Search,
	New_Tab, // the tab strip's "+": a new shell tab
	New_Menu, // the chevron beside it: New shell tab / New chat / New session in the project
	Bell, // the notification centre (ui_bell.odin)
	Settings,
	Toggle_Right,
	Empty_New_Chat, // the centre's empty state
	Empty_Close, // the centre when the session is gone
}

Button_Info :: struct {
	element: string, // Clay element id
	action:  string, // ACTIONS id: what a click runs, the tooltip, enabled or not ("" = a menu)
	icon:    Icon,
}

BUTTONS := [Button]Button_Info {
	.Toggle_Left    = {"toggleleft", "toggle_left", .Sidebar_Left},
	.New_Chat       = {"newchat", "new_chat", .Compose},
	.Search         = {"search", "palette", .Search},
	.New_Tab        = {"newshell", "new_shell_tab", .Plus},
	.New_Menu       = {"newmenu", "", .Chevron_Down},
	.Bell           = {"bell", "notifications", .Bell}, // drawn by bell_button (its unread count)
	.Settings       = {"settings", "quick_settings", .Sliders}, // the popover; ⌘, lists the settings files
	.Toggle_Right   = {"togglepanels", "toggle_right", .Sidebar_Right},
	.Empty_New_Chat = {"emptynew", "new_chat", .None},
	.Empty_Close    = {"emptyclose", "close_session", .None},
}

NEW_MENU_TIP :: "New tab, chat or session"

button_enabled :: proc(b: Button) -> bool {
	a := BUTTONS[b].action
	return a == "" || action_ok(a)
}

// A click on a toolbar button (main.odin).
button_click :: proc(b: Button) {
	switch b {
	case .New_Menu:
		if d := clay.GetElementData(clay.ID(BUTTONS[.New_Tab].element)); d.found {
			bb := d.boundingBox
			menu_open(Menu_New{}, {bb.x, bb.y + bb.height + px(SP_1)})
		}
	case .Settings:
		ui_do(Set_Focus{state.focus_widget == "settings" ? "" : "settings"})
	case .Bell:
		ui_do(Set_Focus{bell_open() ? "" : "notifications"})
	case .New_Chat, .Empty_New_Chat: // the harness picker under the button (harness.odin)
		c := chats_project()
		d := clay.GetElementData(clay.ID(BUTTONS[b].element))
		if c == nil || !d.found || job_sheet_open() {
			action_run(BUTTONS[b].action)
			return
		}
		bb := d.boundingBox
		new_session_ui(c.id, at = [2]f32{bb.x, bb.y + bb.height + px(SP_1)})
	case .Toggle_Left, .Search, .New_Tab, .Toggle_Right, .Empty_Close:
		action_run(BUTTONS[b].action)
	}
}

// A tab's × (and ⌘W on the current tab). A pi tab cannot close alone: it
// closes its whole session, which always asks first (repeated ⌘W on shell
// tabs must never close a session silently once the pi tab is current).
close_tab_click :: proc(tab_id: u64) {
	s, _, i := find_tab(tab_id)
	if s == nil do return
	if i == 0 do ui_do(Close_Session{session = s.id, ask = true})
	else do ui_do(Close_Tab{tab_id = tab_id})
}

// A square icon button (the chevron is narrow).
tool_button :: proc(b: Button, selected := false) {
	th := theme()
	info := BUTTONS[b]
	id := clay.ID(info.element)
	enabled := button_enabled(b)
	bg, em := overlay(id, selected, enabled && ui_hover == Hit(Hit_Button(b)))
	ic := info.icon
	if b == .Toggle_Left && state.layout.left_open do ic = .Sidebar_Left_On
	if b == .Toggle_Right && state.layout.right_open do ic = .Sidebar_Right_On
	col := enabled ? mix(th.text_muted, th.text, em) : with_alpha(th.text_muted, DISABLED_ALPHA)
	narrow := b == .New_Menu
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(px(narrow ? NEW_MENU_W : TOOL_BUTTON)), clay.SizingFixed(px(TOOL_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		icon(ic, col, narrow ? ICON_SIZE_SM : ICON_SIZE)
	}
}

// A text button for an action (empty states), labelled from the table.
action_button :: proc(b: Button, primary: bool) {
	a := action_by_id(BUTTONS[b].action)
	if a == nil do return
	button(clay.ID(BUTTONS[b].element), action_label(a), primary, ui_hover == Hit(Hit_Button(b)))
}

// The search pill: magnifier, "Search or run a command…", ⌘K. An icon
// button when the bar has no room for it.
search_pill :: proc(wide: bool) {
	if !wide {
		tool_button(.Search)
		return
	}
	th := theme()
	a := action_by_id("palette")
	id := clay.ID(BUTTONS[.Search].element)
	h := fade(id, 0, ui_hover == Hit(Hit_Button(.Search)) ? 1 : 0, DUR_HOVER)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(px(SEARCH_W)), clay.SizingFixed(px(TOOL_BUTTON))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(mix(th.bg_app, th.text, TINT_BUTTON + h * (TINT_BUTTON_HOVER - TINT_BUTTON))),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
	}) {
		col := mix(th.text_muted, th.text_secondary, h)
		icon(.Search, col, ICON_SIZE_SM)
		label := strings.concatenate({a.label, "…"}, context.temp_allocator)
		room := px(SEARCH_W - 2 * SP_2 - ICON_SIZE_SM - 2 * SP_2) - text_w(a.keys)
		clay.TextDynamic(clip(label, room), txt(col))
		spacer()
		clay.TextDynamic(a.keys, txt(th.text_muted, FONT_UI_SMALL))
	}
}

// Toggle left column and New chat (Chats), right of the traffic lights: over the
// left column, or at the start of the top bar while it is hidden (the same
// place either way; `trail` keeps the tabs off them).
lights_buttons :: proc(lead: f32, trail: f32 = 0) {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(max(lead, 0)), clay.SizingFit()}}}) {}
	tool_button(.Toggle_Left)
	tool_button(.New_Chat)
	if trail > 0 do if clay.UI()({layout = {sizing = {clay.SizingFixed(trail), clay.SizingFit()}}}) {}
}

// Room in the top bar for the wide search pill (the tabs' width estimated
// from their titles).
search_wide :: proc(cs: ^Open_Session, bar_w: f32) -> bool {
	used := top_bar_fixed_w()
	if cs != nil && len(cs.panes) <= 1 { // split: the tabs are in the panes' strips
		max_tab, squeezed := tab_max_w(cs, bar_w - top_bar_fixed_w())
		for tab in cs.tabs {
			ic, label, extra := tab_label(cs, tab)
			close := !squeezed || tab.id == cs.active_tab
			fixed := tab_fixed_w(ic, true, false, extra, close)
			used += clamp(text_w(label) + fixed, px(TAB_MIN_W), max_tab + (close ? tab_close_w() : 0)) + px(SP_1)
		}
	}
	return bar_w - used >= px(SEARCH_W + SEARCH_MIN_ROOM)
}

// Top bar buttons under the pointer (enabled ones only).
toolbar_hit :: proc() -> Hit {
	for b in Button {
		if b == .Empty_New_Chat || b == .Empty_Close do continue
		if clay.PointerOver(clay.ID(BUTTONS[b].element)) && button_enabled(b) do return Hit_Button(b)
	}
	return nil
}

// The centre's empty-state buttons.
empty_hit :: proc() -> Hit {
	for b in ([]Button{.Empty_New_Chat, .Empty_Close}) {
		if clay.PointerOver(clay.ID(BUTTONS[b].element)) && button_enabled(b) do return Hit_Button(b)
	}
	return nil
}

// ---- settings popover ----

Pop_Item :: enum {
	Appearance_System,
	Appearance_Light,
	Appearance_Dark,
	Look_Graphite,
	Look_Warm,
	Look_Ghostty,
	Reduce_Motion,
	Notifications, // the agent's OS notifications
	// the bell (notify.odin): "Notify me about" toggles, then OS notifications
	Bell_Finished,
	Bell_Waiting,
	Bell_Errors,
	Bell_Jobs,
	Bell_OS,
	Agent_Model, // the agent's model: pi's selector in its terminal
	Chats_Readonly,
	Chats_Folder,
	Chats_Folder_Default, // only while another folder is set
	Rescan,
	Shortcuts,
	Settings_Files, // the left column's Settings tab (settings_files.odin)
	// Text size (shown under Look; last here so the rows above keep their ids)
	Text_Small,
	Text_Medium,
	Text_Default,
	Text_Large,
	Tidy_Projects, // the tidy project list (project_tidy.odin); last, so earlier rows keep their ids
	Reload_Pi, // reload every pi tab (reload.odin); drawn after Rescan, last so earlier rows keep their ids
	Setup, // "Set up Deckhand…": the first-run sheet (ui_setup.odin), its button once a main folder is set; last so earlier rows keep their ids
	Update_Checks, // check for pi-desk updates about once a day (update.odin); last so earlier rows keep their ids
	Refresh_Env, // ask the login shell for its environment again (login_env.odin); drawn after Reload pi; last so earlier rows keep their ids
	Restart_Claude, // restart every running Claude tab (claude_reload.odin), only while one runs; drawn after Reload pi; last so earlier rows keep their ids
	Keep_Sessions, // Experimental: keep sessions running when Deckhand quits; last so earlier rows keep their ids
}

// The rows top to bottom: the keyboard walks them in this order.
POP_ORDER :: [len(Pop_Item)]Pop_Item {
	.Appearance_System, .Appearance_Light, .Appearance_Dark,
	.Look_Graphite, .Look_Warm, .Look_Ghostty,
	.Text_Small, .Text_Medium, .Text_Default, .Text_Large,
	.Reduce_Motion, .Notifications, .Agent_Model,
	.Bell_Finished, .Bell_Waiting, .Bell_Errors, .Bell_Jobs, .Bell_OS,
	.Chats_Readonly, .Chats_Folder, .Chats_Folder_Default,
	.Rescan, .Reload_Pi, .Restart_Claude, .Refresh_Env, .Shortcuts, .Settings_Files, .Setup, .Tidy_Projects, .Update_Checks,
	.Keep_Sessions,
}

POP_ACTIONS := [Pop_Item]string {
	.Appearance_System = "appearance_system",
	.Appearance_Light  = "appearance_light",
	.Appearance_Dark   = "appearance_dark",
	.Look_Graphite     = "look_graphite",
	.Look_Warm         = "look_warm",
	.Look_Ghostty      = "look_ghostty",
	.Reduce_Motion     = "reduce_motion",
	.Notifications     = "agent_notify",
	.Bell_Finished     = "bell_finished",
	.Bell_Waiting      = "bell_waiting",
	.Bell_Errors       = "bell_errors",
	.Bell_Jobs         = "bell_jobs",
	.Bell_OS           = "bell_os",
	.Agent_Model       = "agent_model_pop",
	.Chats_Readonly    = "chats_readonly",
	.Chats_Folder      = "chats_dir",
	.Chats_Folder_Default = "chats_dir_default",
	.Rescan            = "rescan",
	.Tidy_Projects     = "tidy_projects",
	.Shortcuts         = "shortcuts",
	.Settings_Files    = "settings",
	.Text_Small        = "text_small",
	.Text_Medium       = "text_medium",
	.Text_Default      = "text_default",
	.Text_Large        = "text_large",
	.Reload_Pi         = "reload_all_pi",
	.Setup             = "setup",
	.Update_Checks     = "update_checks",
	.Refresh_Env       = "refresh_shell_env",
	.Restart_Claude    = "restart_all_claude",
	.Keep_Sessions     = "keep_sessions",
}

settings_open :: proc() -> bool {return state.focus_widget == "settings"}

// A gear row that may not apply now: Reload all pi tabs and Restart all Claude tabs only while
// such a tab runs (so someone with one harness never sees the other's); Atlas's model needs pi.
pop_item_shown :: proc(it: Pop_Item) -> bool {
	#partial switch it {
	case .Reload_Pi, .Restart_Claude: return action_ok(POP_ACTIONS[it])
	case .Agent_Model: return atlas_offered()
	}
	return true
}

popover: struct {
	selected: int, // keyboard selection (Pop_Item), -1 = none
	opened:   bool, // the popover was open in the last layout (selection resets on open)
}

// Runs a popover row. Toggles and choices keep it open (their effect shows
// at once); the others close it first.
pop_run :: proc(it: Pop_Item) {
	#partial switch it {
	case .Chats_Folder, .Rescan, .Reload_Pi, .Restart_Claude, .Refresh_Env, .Setup:
		ui_do(Set_Focus{""})
	}
	if !action_ok(POP_ACTIONS[it]) do return // not now (no other folder to go back from)
	action_run(POP_ACTIONS[it])
}

// The part of a table label after "Appearance: " or "Look: ".
@(private = "file")
label_tail :: proc(id: string) -> string {
	a := action_by_id(id)
	if a == nil do return ""
	_, _, tail := strings.partition(a.label, ": ")
	return tail != "" ? tail : a.label
}

@(private = "file")
pop_id :: proc(it: Pop_Item) -> clay.ElementId {return clay.ID("pop", u32(it))}

@(private = "file")
pop_hovered :: proc(it: Pop_Item) -> bool {
	return ui_hover == Hit(Hit_Pop(it)) || popover.selected == int(it)
}

@(private = "file")
pop_label :: proc(text: string) {
	clay.TextDynamic(text, txt(theme().text_secondary))
}

@(private = "file")
pop_sep :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_SEP_H))}, childAlignment = {y = .Center}}}) {
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BORDER_W))}}, backgroundColor = cc(theme().border)}) {}
	}
}

// A row that is one control: label, then a switch or a detail and shortcut.
@(private = "file")
pop_row :: proc(it: Pop_Item, toggle: Maybe(bool)) {
	th := theme()
	a := action_by_id(POP_ACTIONS[it])
	if a == nil do return
	id := pop_id(it)
	bg, em := overlay(id, false, pop_hovered(it))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		label := action_label(a)
		if it == .Keep_Sessions do label = "Keep sessions when quitting" // the full label is too wide for the gear at Large text
		clay.TextDynamic(label, txt(mix(th.text_secondary, th.text, em)))
		spacer()
		if on, ok := toggle.?; ok {
			switch_control(on)
		} else {
			if (it == .Chats_Folder || it == .Agent_Model || it == .Refresh_Env) && a.detail != nil {
				clay.TextDynamic(clip(a.detail(), px(POPOVER_W / 3)), txt(th.text_muted, FONT_UI_SMALL))
			}
			if a.keys != "" do clay.TextDynamic(a.keys, txt(th.text_muted, FONT_UI_SMALL))
		}
	}
}

// An on/off switch: a pill track, the knob at its end.
@(private = "file")
switch_control :: proc(on: bool) {
	th := theme()
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(px(SWITCH_W)), clay.SizingFixed(px(SWITCH_H))}, padding = clay.PaddingAll(pu(2)), childAlignment = {x = on ? .Right : .Left, y = .Center}},
		backgroundColor = cc(on ? th.accent : th.text_muted),
		cornerRadius = clay.CornerRadiusAll(px(SWITCH_H / 2)),
	}) {
		k := px(SWITCH_H - 4)
		if clay.UI()({
			layout = {sizing = {clay.SizingFixed(k), clay.SizingFixed(k)}},
			backgroundColor = cc(on ? th.text_on_accent : th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(k / 2),
		}) {}
	}
}

settings_layout :: proc(w, h: f32) {
	if !settings_open() {
		popover.opened = false
		return
	}
	if !popover.opened do popover.selected = -1
	popover.opened = true
	th := theme()
	box_w := px(POPOVER_W)
	x, y := w - box_w - px(SP_2), px(TAB_STRIP_H)
	if d := clay.GetElementData(clay.ID(BUTTONS[.Settings].element)); d.found {
		b := d.boundingBox
		x, y = b.x + b.width - box_w, b.y + b.height + px(SP_1)
	}
	// over the right column it covers the column's width (inside its padding),
	// so nothing in the column shows half-covered beside it
	if d := clay.GetElementData(clay.ID("right")); d.found && state.layout.right_open && x + box_w > d.boundingBox.x {
		b := d.boundingBox
		box_w = max(box_w, b.width - px(2 * SP_2))
		x = b.x + b.width - px(SP_2) - box_w
	}
	x = clamp(x, 0, max(w - box_w, 0))
	if clay.UI(clay.ID("settings_pop"))({
		layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(PAD_OVERLAY)), childGap = pu(2)},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 8},
	}) {
		overlay_shadow("settings_shadow", 8)
		// Appearance: a segmented control
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childAlignment = {y = .Center}}}) {
			pop_label("Appearance")
			spacer()
			if clay.UI()({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SEGMENT_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_field),
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
			}) {
				modes := [3]Appearance{.System, .Light, .Dark}
				for i in 0 ..< 3 {
					it := Pop_Item(int(Pop_Item.Appearance_System) + i)
					on := state.settings.appearance == modes[i]
					id := pop_id(it)
					bg, em := overlay(id, false, pop_hovered(it))
					if on do bg = cc(mix(th.bg_elevated, th.text, TINT_SEGMENT)) // the chosen one stands out of the track
					if clay.UI(id)({
						layout = {sizing = {clay.SizingFit(), clay.SizingGrow()}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
						backgroundColor = bg,
						cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
					}) {
						clay.TextDynamic(label_tail(POP_ACTIONS[it]), txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
					}
				}
			}
		}
		// Look: one swatch per look (its background, its accent), the current ringed
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
			pop_label("Look")
			spacer()
			light := theme_is_light()
			for look in Theme_Id {
				it := Pop_Item(int(Pop_Item.Look_Graphite) + int(look))
				lt := light ? &THEMES_LIGHT[look] : &THEMES[look]
				on := state.settings.theme == look
				ring := on ? th.accent : (pop_hovered(it) ? th.text_muted : th.border)
				if clay.UI(pop_id(it))({
					layout = {sizing = {clay.SizingFixed(px(SWATCH + 4)), clay.SizingFixed(px(SWATCH + 4))}, padding = clay.PaddingAll(pu(2)), childAlignment = {x = .Center, y = .Center}},
					backgroundColor = cc(ring),
					cornerRadius = clay.CornerRadiusAll(px(SWATCH / 2 + 2)),
				}) {
					if clay.UI()({
						layout = {sizing = {clay.SizingFixed(px(SWATCH)), clay.SizingFixed(px(SWATCH))}, childAlignment = {x = .Center, y = .Center}},
						backgroundColor = cc(lt.bg_app),
						cornerRadius = clay.CornerRadiusAll(px(SWATCH / 2)),
					}) {
						if clay.UI()({
							layout = {sizing = {clay.SizingFixed(px(SWATCH / 2 - 2)), clay.SizingFixed(px(SWATCH / 2 - 2))}},
							backgroundColor = cc(lt.accent),
							cornerRadius = clay.CornerRadiusAll(px(SWATCH / 4 - 1)),
						}) {}
					}
				}
			}
		}
		// Text size: a segmented control, smallest to largest
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childAlignment = {y = .Center}}}) {
			pop_label("Text size")
			spacer()
			if clay.UI()({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SEGMENT_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_field),
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
			}) {
				for size, i in TEXT_SIZE_ORDER {
					it := Pop_Item(int(Pop_Item.Text_Small) + i)
					on := state.settings.text_size == size
					id := pop_id(it)
					bg, em := overlay(id, false, pop_hovered(it))
					if on do bg = cc(mix(th.bg_elevated, th.text, TINT_SEGMENT))
					if clay.UI(id)({
						layout = {sizing = {clay.SizingFit(), clay.SizingGrow()}, padding = {pu(SEGMENT_PAD), pu(SEGMENT_PAD), 0, 0}, childAlignment = {y = .Center}},
						backgroundColor = bg,
						cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
					}) {
						clay.TextDynamic(label_tail(POP_ACTIONS[it]), txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
					}
				}
			}
		}
		pop_row(.Reduce_Motion, state.settings.reduce_motion)
		pop_row(.Notifications, !state.settings.notify_off)
		if pop_item_shown(.Agent_Model) do pop_row(.Agent_Model, nil)
		pop_sep()
		// the bell: what it collects (one chip per group), and macOS notifications
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childAlignment = {y = .Center}}}) {
			pop_label("Notify me about")
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
			for g in Bell_Group {
				it := Pop_Item(int(Pop_Item.Bell_Finished) + int(g))
				on := g not_in state.settings.bell_off
				id := pop_id(it)
				bg, em := overlay(id, false, pop_hovered(it))
				if on do bg = cc(mix(th.bg_elevated, th.accent, 0.22))
				if clay.UI(id)({
					layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(CHIP_SMALL_H))}, padding = {pu(SP_1 + 2), pu(SP_1 + 2), 0, 0}, childAlignment = {y = .Center}},
					backgroundColor = bg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
					border = {color = cc(on ? with_alpha(th.accent, 0.6) : th.border), width = clay.BorderOutside(pu(BORDER_W))},
				}) {
					clay.TextDynamic(label_tail(POP_ACTIONS[it]), txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
				}
			}
		}
		pop_row(.Bell_OS, !state.settings.bell_os_off)
		pop_sep()
		pop_row(.Chats_Readonly, state.settings.chats_readonly)
		pop_row(.Chats_Folder, nil)
		if action_ok(POP_ACTIONS[.Chats_Folder_Default]) do pop_row(.Chats_Folder_Default, nil)
		pop_sep()
		pop_row(.Rescan, nil)
		if pop_item_shown(.Reload_Pi) do pop_row(.Reload_Pi, nil)
		if pop_item_shown(.Restart_Claude) do pop_row(.Restart_Claude, nil)
		pop_row(.Refresh_Env, nil)
		pop_row(.Shortcuts, nil)
		pop_row(.Settings_Files, nil)
		pop_row(.Setup, nil)
		pop_row(.Tidy_Projects, !state.settings.tidy_off)
		pop_row(.Update_Checks, !upd.checks_off)
		pop_sep()
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childAlignment = {y = .Center}}}) {
			pop_label("Experimental")
		}
		pop_row(.Keep_Sessions, state.settings.keep_sessions)
	}
}

settings_hit :: proc() -> Hit {
	for it in Pop_Item do if clay.PointerOver(pop_id(it)) do return Hit_Pop(it)
	if clay.PointerOver(clay.ID(BUTTONS[.Settings].element)) do return Hit_Button(.Settings)
	return nil
}

// Input while the popover is open: it takes everything but shortcuts. Arrows
// move, Enter or Space runs, Esc or a click outside closes.
settings_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		if e.modifiers & sapp.MODIFIER_SUPER != 0 {
			ui_do(Set_Focus{""}) // a shortcut (⌘N, ⌘Q, ...) closes it and runs as usual
			return false
		}
		n := len(Pop_Item)
		#partial switch e.key_code {
		case .ESCAPE:                   ui_do(Set_Focus{""})
		case .UP, .LEFT, .DOWN, .RIGHT, .TAB:
			order := POP_ORDER
			at := -1
			for o, k in order do if int(o) == popover.selected do at = k
			d := (e.key_code == .UP || e.key_code == .LEFT) ? n - 1 : 1
			i := at < 0 && d != 1 ? 0 : at
			for _ in 0 ..< n {
				i = (i + d) %% n
				if action_ok(POP_ACTIONS[order[i]]) && pop_item_shown(order[i]) do break // a row that shows
			}
			popover.selected = int(order[i])
		case .ENTER, .KP_ENTER, .SPACE: if popover.selected >= 0 do pop_run(Pop_Item(popover.selected))
		}
		return true
	case .MOUSE_MOVE:
		set_hover(chrome_hit({e.mouse_x, e.mouse_y}), false)
		return true
	case .MOUSE_DOWN:
		h := chrome_hit({e.mouse_x, e.mouse_y})
		if it, ok := h.(Hit_Pop); ok do pop_run(Pop_Item(it))
		else do ui_do(Set_Focus{""}) // outside (or the settings button again): closes
		app.redraw = true
		return true
	case .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_SCROLL, .MOUSE_UP:
		return true
	}
	return false
}

// ---- keyboard shortcuts sheet ----

Shortcut_Row :: struct {
	label, keys: string,
	head:        bool, // a group's heading
}

// Every shortcut, grouped like the menu bar (menubar.odin), then the extra
// ones under their groups (temp allocator).
shortcut_rows :: proc() -> []Shortcut_Row {
	rows := make([dynamic]Shortcut_Row, context.temp_allocator)
	add :: proc(rows: ^[dynamic]Shortcut_Row, it: ^Bar_Item) {
		if it.sep do return
		for &s in it.sub do add(rows, &s)
		keys := menubar_keys(it)
		if it.sub != nil || keys == "" do return
		if it.action == "tab_1" do append(rows, Shortcut_Row{"Go to tab 1–9", "⌘1–⌘9", false})
		if strings.has_prefix(it.action, "tab_") do return // one row for the nine
		append(rows, Shortcut_Row{menubar_item_title(it), keys, false})
	}
	for &top in MENUBAR {
		append(&rows, Shortcut_Row{top.title, "", true})
		add(&rows, &top)
	}
	group := ""
	for x in SHORTCUTS_EXTRA {
		if x.group != group do append(&rows, Shortcut_Row{x.group, "", true})
		group = x.group
		append(&rows, Shortcut_Row{x.label, x.keys, false})
	}
	return rows[:]
}

shortcuts_open :: proc() -> bool {return state.focus_widget == "shortcuts"}

shortcuts_layout :: proc(w, h: f32) {
	if !shortcuts_open() do return
	th := theme()
	box_w := min(px(SHEET_W), w - px(2 * SP_4))
	if clay.UI(clay.ID("sheet_scrim"))({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = {0, 0, pu(SHEET_TOP), pu(SP_4)}, childAlignment = {x = .Center}},
		backgroundColor = cc(th.scrim),
		floating = {attachTo = .Root, zIndex = 10},
	}) {
		if clay.UI(clay.ID("sheet_box"))({
			layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit({max = h - px(SHEET_TOP + SP_4)})}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_3)), childGap = pu(SP_1)},
			backgroundColor = cc(th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
			border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		}) {
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_1), 0, 0, 0}, childAlignment = {y = .Center}}}) {
				clay.TextDynamic(action_by_id("shortcuts").label, txt(th.text, WEIGHT_BOLD))
				spacer()
				id := clay.ID("sheet_close")
				bg, em := overlay(id, false, ui_hover == Hit(Hit_Sheet_Close{}))
				if clay.UI(id)({
					layout = {sizing = {clay.SizingFixed(px(TOOL_BUTTON)), clay.SizingFixed(px(TOOL_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
					backgroundColor = bg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
				}) {
					icon(.Close, mix(th.text_muted, th.text, em), ICON_SIZE_SM)
				}
			}
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BORDER_W))}}, backgroundColor = cc(th.border)}) {}
			if clay.UI(clay.ID("sheet_rows"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			}) {
				for r in shortcut_rows() {
					if r.head {
						if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(SHEET_ROW_H))}, padding = {pu(SP_1), pu(SP_1), pu(SP_1), 0}, childAlignment = {y = .Bottom}}}) {
							clay.TextDynamic(r.label, txt(th.text, WEIGHT_BOLD))
						}
						continue
					}
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(SHEET_ROW_H))}, padding = {pu(SP_1), pu(SP_1), 0, 0}, childAlignment = {y = .Center}}}) {
						clay.TextDynamic(r.label, txt(th.text_secondary))
						spacer()
						if clay.UI()({
							layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SHEET_ROW_H - SP_2))}, padding = {pu(KEYCAP_PAD), pu(KEYCAP_PAD), 0, 0}, childAlignment = {y = .Center}},
							backgroundColor = cc(th.bg_field),
							cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
						}) {
							clay.TextDynamic(r.keys, txt(th.text, FONT_UI_SMALL))
						}
					}
				}
			}
		}
	}
}

sheet_hit :: proc() -> Hit {
	if clay.PointerOver(clay.ID("sheet_close")) do return Hit_Sheet_Close{}
	return nil
}

// Input while the sheet shows: Esc, the close button or a click outside
// closes it; the wheel scrolls it.
shortcuts_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .KEY_DOWN:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 {
			ui_do(Set_Focus{""}) // a shortcut closes the sheet and runs as usual
			return false
		}
		if e.key_code == .ESCAPE || e.key_code == .ENTER do ui_do(Set_Focus{""})
		return true
	case .MOUSE_MOVE:
		set_hover(chrome_hit({e.mouse_x, e.mouse_y}), false)
		return true
	case .MOUSE_DOWN:
		_, close := chrome_hit({e.mouse_x, e.mouse_y}).(Hit_Sheet_Close)
		if close || !inside(clay.ID("sheet_box"), e.mouse_x, e.mouse_y) do ui_do(Set_Focus{""})
		app.redraw = true
		return true
	case .MOUSE_SCROLL:
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
		app.redraw = true
		return true
	case .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_UP:
		return true
	}
	return false
}

// ---- tooltips ----

Tip :: struct {
	since: time.Tick, // the pointer came to rest on ui_hover
	shown: bool,
	off:   bool, // clicked or typed since: no tooltip until the pointer moves to another control
	at:    [2]f32, // pointer when it showed (framebuffer px)
}
tip: Tip

// ui_hover changed (set_hover): start waiting again.
tip_hover_changed :: proc() {
	tip = {since = time.tick_now()}
}

// A click or a key: the tooltip goes away.
tip_dismiss :: proc() {
	if tip.shown do app.redraw = true
	tip.shown, tip.off = false, true
}

// True once, when the tooltip of the resting pointer is due: the frame loop
// draws one frame for it. Cheap enough for every frame callback.
tip_due :: proc() -> bool {
	if tip.shown || tip.off || ui_hover == nil do return false
	if time.tick_since(tip.since) < TIP_DELAY do return false
	if label, _ := hit_tip(ui_hover); label == "" {
		tip.off = true
		return false
	}
	tip.shown, tip.at = true, app.pointer
	return true
}

// The tooltip text for a hit: label and shortcut, from the action table where
// the control runs an action.
hit_tip :: proc(h: Hit) -> (label, keys: string) {
	act :: proc(id: string) -> (string, string) {
		if a := action_by_id(id); a != nil do return action_label(a), a.keys
		return "", ""
	}
	#partial switch x in h {
	case Hit_Button:
		if Button(x) == .New_Menu do return NEW_MENU_TIP, ""
		return act(BUTTONS[Button(x)].action)
	case Hit_Agent:
		return drawer_tip(x)
	case Hit_Home: // the agent's button (far right)
		return act("toggle_agent")
	case Hit_Close_Tab:
		if _, _, i := find_tab(u64(x)); i == 0 do return act("close_session") // the pi tab closes its session
		return act("close_tab")
	case Hit_Pin_Project:
		p := find_project(u64(x))
		return p != nil && project_pinned(p^) >= 0 ? "Unpin" : "Pin", ""
	case Hit_Pin_Session:
		return session_pinned(string(x)) >= 0 ? "Unpin" : "Pin", ""
	case Hit_New_In:
		if c := chats_project(); c != nil && c.id == u64(x) do return act("new_chat")
		return "New session in this project", ""
	case Hit_Add_Project:
		return act("add_project")
	case Hit_Close_Session:
		return act("close_session")
	case Hit_More_Project, Hit_More_Session, Hit_More_Open:
		return "More actions", ""
	case Hit_Info_Session:
		return fmt.tprintf("Session info: copy it, or send it to %s", agent_name()), ""
	case Hit_New_Job_In:
		return "New job for this project: a form that writes the job's note", ""
	case Hit_Sort:
		return strings.concatenate({"Sorted by ", strings.to_lower(SORT_LABELS[state.sidebar.sort[Sort_Section(x)]], context.temp_allocator), " (sort, show hidden)"}, context.temp_allocator), ""
	case Hit_Filter:
		return act("filter")
	case Hit_Filter_Clear:
		return act("clear_filter")
	case Hit_Show_More:
		return "Show all", ""
	case Hit_Divider:
		return "Drag to resize, double-click to reset", ""
	case Hit_Pop:
		if Pop_Item(x) == .Reload_Pi do return "Reload every idle pi tab now (/reload); busy ones once idle", ""
		if Pop_Item(x) == .Restart_Claude do return "Restart every idle Claude tab now (each resumes its conversation; background work stops); busy ones once idle", ""
		if Pop_Item(x) >= .Look_Graphite && Pop_Item(x) <= .Look_Ghostty do return act(POP_ACTIONS[Pop_Item(x)])
		if Pop_Item(x) >= .Text_Small && Pop_Item(x) <= .Text_Large do return act(POP_ACTIONS[Pop_Item(x)])
		if Pop_Item(x) >= .Bell_Finished && Pop_Item(x) <= .Bell_Jobs {
			g := Bell_Group(int(x) - int(Pop_Item.Bell_Finished))
			what := [Bell_Group]string{.Finished = "Finished runs", .Waiting = "Questions and dialogs", .Errors = "Errors and exits", .Jobs = "Jobs"}
			return fmt.tprintf("%s: %s (click to turn %s)", what[g], g in state.settings.bell_off ? "off" : "on", g in state.settings.bell_off ? "on" : "off"), ""
		}
	case Hit_Bell:
		return bell_tip(x)
	case Hit_Sheet_Close:
		return "Close", "Esc"
	case Hit_Setup:
		return setup_tip(x)
	case Hit_Job_Sheet:
		return job_sheet_tip(x)
	case Hit_Editor_Tool:
		return editor_tool_tip(int(x))
	case Hit_Files:
		return files_tip(x)
	case Hit_Reload:
		return reload_tip(x)
	case Hit_Claude_Reload:
		return claude_reload_tip(x)
	case Hit_Dead_Tab:
		return dead_tab_tip_for(x)
	case Hit_Tab:
		// a dead pi tab: how it ended; else its status dot's source and age (agent_status.odin)
		_, tab, _ := find_tab(u64(x))
		if tip := dead_tab_hover_tip(tab); tip != "" do return tip, ""
		if tab != nil {
			// a Claude tab: its model too (claude_rows.odin)
			st, model := status_explain(tab^), claude_tab_tip(tab^)
			if st != "" && model != "" do return fmt.tprintf("%s — %s", model, st), ""
			return model != "" ? model : st, ""
		}
	case Hit_Open_Row:
		s := find_session(u64(x))
		if tip := dead_tab_hover_tip(session_pi_tab(s)); tip != "" do return tip, ""
		return session_explain(s), ""
	case Hit_Update:
		return update_tip(x)
	case Hit_Comments:
		return comments_tip(x)
	case Hit_Claude:
		return claude_tip(x)
	case Hit_Jobs:
		return jobs_tip(x)
	case Hit_Changes:
		return changes_tip(x)
	case Hit_Group, Hit_Kids:
		return tree_tip(h), ""
	// a status dot's source and age (agent_status.odin); none without a dot
	case Hit_Session:
		if id := open_session_any(string(x)); id != 0 do return session_explain(find_session(id)), ""
	case Hit_Chat:
		if id := open_session_any(string(x)); id != 0 do return session_explain(find_session(id)), ""
	}
	return "", ""
}

// The tooltip: a small box under the pointer (above it near the bottom
// edge), clamped to the window.
tooltip_layout :: proc(w, h: f32) {
	if !tip.shown || tip.off do return
	label, keys := hit_tip(ui_hover)
	if label == "" do return
	th := theme()
	tw := text_w(label) + px(2 * SP_2) + (keys != "" ? text_w(keys) + px(SP_2) : 0)
	x := clamp(tip.at.x - px(SP_2), px(SP_1), max(w - tw - px(SP_1), 0))
	y := tip.at.y + px(TIP_OFFSET)
	if y + px(TIP_H) > h do y = tip.at.y - px(TIP_OFFSET) - px(TIP_H)
	if clay.UI(clay.ID("tooltip"))({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TIP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 30},
	}) {
		clay.TextDynamic(label, txt(th.text, FONT_UI_SMALL))
		if keys != "" do clay.TextDynamic(keys, txt(th.text_muted, FONT_UI_SMALL))
	}
}
