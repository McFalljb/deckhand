package main

// The top bar's toolbar and what hangs off it, so every action has a button
// as well as a shortcut:
//
//   - icon buttons (BUTTONS): each runs an action from actions.odin through
//     the inbox as the user (action_run), exactly like the palette; its
//     tooltip is that action's label and shortcut
//   - the search pill (opens the command palette)
//   - the settings popover (focus widget "settings"; a click on the gear): its
//     rows in groups (POP_GROUPS: Display, Notifications, Sessions, Deckhand),
//     a list that scrolls in a short window; every row runs an action
//   - the keyboard shortcuts sheet (focus widget "shortcuts"; ⌘/), listed
//     from the action table
//   - the one tooltip system: after the pointer rests TIP_DELAY on a control,
//     one redraw shows its label and shortcut (no redraws while waiting)

import "core:fmt"
import "core:strings"
import "core:time"
import "core"
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
	Empty_Add_Project, // the centre's empty state: the Projects header's "+"
	Fleet, // the fleet pill: what needs you and what works, on every machine (ui_fleet.odin)
	Empty_Next, // the centre's empty state while something needs you: Go to next (⌥⌘A)
	Deck, // the Deck view: every open session as a card (ui_deck.odin)
}

Button_Info :: struct {
	element: string, // Clay element id
	action:  string, // ACTIONS id: what a click runs, the tooltip, enabled or not ("" = a menu)
	icon:    core.Icon,
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
	.Empty_Add_Project = {"emptyadd", "add_project", .None},
	.Fleet          = {"fleetpill", "next_needing_you", .None}, // drawn by fleet_pill; its tooltip in words (fleet_tip)
	.Empty_Next     = {"emptynext", "next_needing_you", .None},
	.Deck           = {"deckbtn", "deck_view", .Deck}, // selected while the deck shows
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
		ui_do(core.Set_Focus{state.focus_widget == "settings" ? "" : "settings"})
	case .Bell:
		ui_do(core.Set_Focus{bell_open() ? "" : "notifications"})
	case .New_Chat, .Empty_New_Chat: // the harness picker under the button (harness.odin)
		c := core.chats_project()
		d := clay.GetElementData(clay.ID(BUTTONS[b].element))
		if c == nil || !d.found || job_sheet_open() {
			action_run(BUTTONS[b].action)
			return
		}
		bb := d.boundingBox
		new_session_ui(c.id, at = [2]f32{bb.x, bb.y + bb.height + px(SP_1)})
	case .Empty_Add_Project:
		add_project_dialog() // as the Projects header's "+" (ui_sidebar.odin)
	case .Fleet:
		fleet_click()
	case .Toggle_Left, .Search, .New_Tab, .Toggle_Right, .Empty_Close, .Empty_Next, .Deck:
		action_run(BUTTONS[b].action)
	}
}

// A tab's × (and ⌘W on the current tab). A pi tab cannot close alone: it
// closes its whole session, which always asks first (repeated ⌘W on shell
// tabs must never close a session silently once the pi tab is current).
close_tab_click :: proc(tab_id: u64) {
	s, _, i := find_tab(tab_id)
	if s == nil do return
	if i == 0 do ui_do(core.Close_Session{session = s.id, ask = true})
	else {
		closed_tab_record(tab_id) // the user's own close: ⇧⌘T reopens it (closed_tabs.odin)
		ui_do(core.Close_Tab{tab_id = tab_id})
	}
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
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
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
search_wide :: proc(cs: ^core.Open_Session, bar_w: f32) -> bool {
	used := top_bar_fixed_w()
	if cs != nil && len(cs.panes) <= 1 { // split: the tabs are in the panes' strips
		max_tab, squeezed := tab_max_w(cs, bar_w - top_bar_fixed_w())
		for tab in cs.tabs {
			ic, label, extra := tab_label(cs, tab)
			close := !squeezed || tab.id == cs.active_tab
			fixed := tab_fixed_w(ic, tab_shows_mark(tab), false, extra, close)
			used += clamp(text_w(label) + fixed, px(TAB_MIN_W), max_tab + (close ? tab_close_w() : 0)) + px(SP_1)
		}
	}
	return bar_w - used >= px(SEARCH_W + SEARCH_MIN_ROOM)
}

// Top bar buttons under the pointer (enabled ones only).
toolbar_hit :: proc() -> Hit {
	for b in Button {
		if b == .Empty_New_Chat || b == .Empty_Close || b == .Empty_Add_Project || b == .Empty_Next do continue
		if clay.PointerOver(clay.ID(BUTTONS[b].element)) && button_enabled(b) do return Hit_Button(b)
	}
	return nil
}

// The centre's empty-state buttons.
empty_hit :: proc() -> Hit {
	for b in ([]Button{.Empty_New_Chat, .Empty_Close, .Empty_Add_Project, .Empty_Next}) {
		if clay.PointerOver(clay.ID(BUTTONS[b].element)) && button_enabled(b) do return Hit_Button(b)
	}
	return fleet_row_hit() // its rows (ui_fleet.odin)
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
	Update_Checks, // check for Deckhand updates about once a day (update.odin); last so earlier rows keep their ids
	Refresh_Env, // ask the login shell for its environment again (login_env.odin); drawn after Reload pi; last so earlier rows keep their ids
	Restart_Claude, // restart every running Claude tab (claude_reload.odin), only while one runs; drawn after Reload pi; last so earlier rows keep their ids
	Keep_Sessions, // keep sessions running when Deckhand quits (on by default); drawn after Update checks; last so earlier rows keep their ids
	Control_Token, // a control token for `deckhand --ctl` onto the clipboard; drawn after Settings files; last so earlier rows keep their ids
	Separate_Core, // run sessions in a background core (on by default; read at launch); last so earlier rows keep their ids
	Remote_Machines, // Machines over SSH (machines.odin; on by default); last so earlier rows keep their ids
	Bell_Dock, // the Dock icon's badge (win_os.odin); drawn after Also notify in macOS; last so earlier rows keep their ids
	// the Notifications grid's macOS and Sound columns (one per Bell_Group, in its order); last so
	// earlier rows keep their ids. Bell_OS (one switch for all) is no longer drawn
	Os_Finished,
	Os_Waiting,
	Os_Errors,
	Os_Jobs,
	Sound_Finished,
	Sound_Waiting,
	Sound_Errors,
	Sound_Jobs,
	Dim_Panes, // split panes: the ones without the keyboard dim (ui_pane_motion.odin); drawn after Reduce motion; last so earlier rows keep their ids
}

// The rows top to bottom, in their groups (POP_GROUPS): the keyboard walks them in this order.
POP_ORDER :: [len(Pop_Item)]Pop_Item {
	// Display
	.Appearance_System, .Appearance_Light, .Appearance_Dark,
	.Look_Graphite, .Look_Warm, .Look_Ghostty,
	.Text_Small, .Text_Medium, .Text_Default, .Text_Large,
	.Reduce_Motion, .Dim_Panes,
	// Notifications: the switch, then the grid row by row (Bell, macOS, Sound), the Dock
	.Notifications,
	.Bell_Waiting, .Os_Waiting, .Sound_Waiting,
	.Bell_Finished, .Os_Finished, .Sound_Finished,
	.Bell_Errors, .Os_Errors, .Sound_Errors,
	.Bell_Jobs, .Os_Jobs, .Sound_Jobs,
	.Bell_Dock, .Bell_OS,
	// Sessions: switches, then one-shot actions
	.Agent_Model, .Chats_Readonly, .Chats_Folder, .Chats_Folder_Default, .Tidy_Projects,
	.Keep_Sessions, .Separate_Core, .Remote_Machines,
	.Rescan, .Reload_Pi, .Restart_Claude, .Refresh_Env,
	// Deckhand
	.Update_Checks, .Settings_Files, .Shortcuts, .Setup, .Control_Token,
}

// The popover's group headers, top to bottom.
POP_GROUPS :: [?]string{"Display", "Notifications", "Sessions", "Deckhand"}

POP_ACTIONS := [Pop_Item]string {
	.Appearance_System = "appearance_system",
	.Appearance_Light  = "appearance_light",
	.Appearance_Dark   = "appearance_dark",
	.Look_Graphite     = "look_graphite",
	.Look_Warm         = "look_warm",
	.Look_Ghostty      = "look_ghostty",
	.Reduce_Motion     = "reduce_motion",
	.Dim_Panes         = "dim_panes",
	.Notifications     = "agent_notify",
	.Bell_Finished     = "bell_finished",
	.Bell_Waiting      = "bell_waiting",
	.Bell_Errors       = "bell_errors",
	.Bell_Jobs         = "bell_jobs",
	.Bell_OS           = "", // not drawn (the grid's macOS column)
	.Bell_Dock         = "bell_dock",
	.Os_Finished       = "bell_os_finished",
	.Os_Waiting        = "bell_os_waiting",
	.Os_Errors         = "bell_os_errors",
	.Os_Jobs           = "bell_os_jobs",
	.Sound_Finished    = "bell_sound_finished",
	.Sound_Waiting     = "bell_sound_waiting",
	.Sound_Errors      = "bell_sound_errors",
	.Sound_Jobs        = "bell_sound_jobs",
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
	.Control_Token     = "copy_control_token",
	.Separate_Core     = "separate_core",
	.Remote_Machines   = "remote_machines",
}

settings_open :: proc() -> bool {return state.focus_widget == "settings"}

// A gear row that may not apply now: Reload all pi tabs and Restart all Claude tabs only while
// such a tab runs (so someone with one harness never sees the other's); Atlas's model needs pi.
pop_item_shown :: proc(it: Pop_Item) -> bool {
	#partial switch it {
	case .Reload_Pi, .Restart_Claude: return action_ok(POP_ACTIONS[it])
	case .Agent_Model: return core.atlas_offered()
	case .Bell_OS: return false
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
		ui_do(core.Set_Focus{""})
	}
	if !action_ok(POP_ACTIONS[it]) do return // not now (no other folder to go back from)
	// a sound: the next one plays as it is chosen (a preview; none for "none")
	preview := it >= .Sound_Finished && it <= .Sound_Jobs ? core.bell_sound_next(core.bell_sound_of(state.settings, core.Bell_Group(int(it) - int(Pop_Item.Sound_Finished)))) : core.Bell_Sound.None
	action_run(POP_ACTIONS[it])
	if preview != .None do play_bell_sound(core.BELL_SOUND_LABELS[preview])
}

// ---- the Notifications grid: per group, Bell (on/off), macOS (never, background, always), Sound ----

// Its rows top to bottom, and what each is called.
BELL_GRID_ORDER :: [4]core.Bell_Group{.Waiting, .Finished, .Errors, .Jobs}
BELL_GRID_LABELS := [core.Bell_Group]string{.Waiting = "Needs you", .Finished = "Finished", .Errors = "Errors", .Jobs = "Jobs"}
// What the rule is, in the tooltips.
BELL_SOUND_RULE :: "A sound plays while Deckhand is in the background, or also in front when macOS says always"

// The grid's actions (actions.odin): the next choice for a group.
bell_os_step :: proc(g: core.Bell_Group) -> core.Set_Bell {
	c: core.Set_Bell
	c.macos[g] = core.os_when_next(core.bell_os_when(state.settings, g))
	return c
}
bell_os_detail :: proc(g: core.Bell_Group) -> string {return core.OS_WHEN_NAMES[core.bell_os_when(state.settings, g)]}
bell_sound_step :: proc(g: core.Bell_Group) -> core.Set_Bell {
	c: core.Set_Bell
	c.sound[g] = core.bell_sound_next(core.bell_sound_of(state.settings, g))
	return c
}
bell_sound_detail :: proc(g: core.Bell_Group) -> string {return core.BELL_SOUND_LABELS[core.bell_sound_of(state.settings, g)]}

// The columns' widths: each fits its widest choice, so the columns line up.
@(private = "file")
bell_grid_cols :: proc() -> (bell, mac, sound: f32) {
	pad := px(2 * (SP_1 + 2))
	bell = max(px(SWITCH_W + 2 * SP_1), text_w("Bell", FONT_UI_SMALL))
	mac = text_w("macOS", FONT_UI_SMALL)
	for n in core.OS_WHEN_NAMES do mac = max(mac, text_w(n, FONT_UI_SMALL) + pad)
	sound = text_w("Sound", FONT_UI_SMALL)
	for n in core.BELL_SOUND_LABELS do sound = max(sound, text_w(n, FONT_UI_SMALL) + pad)
	return
}

@(private = "file")
bell_grid :: proc() {
	th := theme()
	bw, mw, sw := bell_grid_cols()
	row :: proc() -> clay.ElementDeclaration {
		return {layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}
	}
	head :: proc(text: string, w: f32) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(w), clay.SizingFit()}, childAlignment = {x = .Center}}}) {
			clay.TextDynamic(text, txt(theme().text_muted, FONT_UI_SMALL))
		}
	}
	// the header: what the columns are
	if clay.UI(clay.ID("bell_grid_head"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POP_HEAD_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
		pop_label("Notify me about")
		spacer()
		head("Bell", bw)
		head("macOS", mw)
		head("Sound", sw)
	}
	for g in BELL_GRID_ORDER {
		if clay.UI(clay.ID("bell_grid_row", u32(g)))(row()) {
			clay.TextDynamic(BELL_GRID_LABELS[g], txt(th.text_secondary))
			spacer()
			// Bell: a switch in a cell the size of the column
			it := Pop_Item(int(Pop_Item.Bell_Finished) + int(g))
			id := pop_id(it)
			bg, _ := overlay(id, false, pop_hovered(it))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFixed(bw), clay.SizingFixed(px(CHIP_SMALL_H))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				switch_control(g not_in state.settings.bell_off)
			}
			w := core.bell_os_when(state.settings, g)
			grid_chip(Pop_Item(int(Pop_Item.Os_Finished) + int(g)), core.OS_WHEN_NAMES[w], w != .Never, mw)
			s := core.bell_sound_of(state.settings, g)
			grid_chip(Pop_Item(int(Pop_Item.Sound_Finished) + int(g)), core.BELL_SOUND_LABELS[s], s != .None, sw)
		}
	}
}

// One of the grid's choices: a chip that steps to the next choice (accent-tinted unless off).
@(private = "file")
grid_chip :: proc(it: Pop_Item, text: string, on: bool, w: f32) {
	th := theme()
	id := pop_id(it)
	bg, em := overlay(id, false, pop_hovered(it))
	if on do bg = cc(mix(th.bg_elevated, th.accent, 0.22 + 0.14 * em))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(px(CHIP_SMALL_H))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(on ? with_alpha(th.accent, 0.6) : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
	}) {
		clay.TextDynamic(text, txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
	}
}

// The grid's tooltips: what the cell is now, what a click does, and the rule.
@(private = "file")
bell_grid_tip :: proc(it: Pop_Item) -> string {
	switch {
	case it >= .Bell_Finished && it <= .Bell_Jobs:
		g := core.Bell_Group(int(it) - int(Pop_Item.Bell_Finished))
		what := [core.Bell_Group]string{.Finished = "Finished runs", .Waiting = "Questions and dialogs", .Errors = "Errors and exits", .Jobs = "Jobs"}
		off := g in state.settings.bell_off
		return fmt.tprintf("%s in the bell: %s (click to turn %s)", what[g], off ? "off" : "on", off ? "on" : "off")
	case it >= .Os_Finished && it <= .Os_Jobs:
		g := core.Bell_Group(int(it) - int(Pop_Item.Os_Finished))
		w := core.bell_os_when(state.settings, g)
		now := [core.Os_When]string{.Default = "", .Never = "never", .Background = "while Deckhand is in the background", .Always = "always, also while Deckhand is in front"}
		return fmt.tprintf("%s: a macOS notification %s (click: %s)", BELL_GRID_LABELS[g], now[w], core.OS_WHEN_NAMES[core.os_when_next(w)])
	case it >= .Sound_Finished && it <= .Sound_Jobs:
		g := core.Bell_Group(int(it) - int(Pop_Item.Sound_Finished))
		s := core.bell_sound_of(state.settings, g)
		return fmt.tprintf("%s: sound %s (click: %s, played). %s.", BELL_GRID_LABELS[g], core.BELL_SOUND_LABELS[s], core.BELL_SOUND_LABELS[core.bell_sound_next(s)], BELL_SOUND_RULE)
	}
	return ""
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

POP_HEAD_H :: SP_4 + SP_1 + 2 // a group's header (pop_head)

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
		if it == .Separate_Core do label = "Sessions in a background core" // the full label is too wide too
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
	pop_scroll_to()
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
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 8},
	}) {
		overlay_shadow("settings_shadow", 8)
		// taller than the window: the rows scroll (the selected one is kept in view: pop_scroll_to)
		if clay.UI(clay.ID("settings_list"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFit({max = max(h - y - px(SP_4 + 2 * PAD_OVERLAY + core.BORDER_W), px(POPOVER_ROW_H))})}, layoutDirection = .TopToBottom, childGap = pu(2)},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) { // (its rows, down to the close of the list, keep their old indent)
		pop_head(0)
		// Appearance: a segmented control
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childAlignment = {y = .Center}}}) {
			pop_label("Appearance")
			spacer()
			if clay.UI()({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SEGMENT_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_field),
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
			}) {
				modes := [3]core.Appearance{.System, .Light, .Dark}
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
			light := core.theme_is_light()
			for look in core.Theme_Id {
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
		pop_row(.Dim_Panes, !state.settings.dim_panes_off)
		pop_head(1)
		pop_row(.Notifications, !state.settings.notify_off)
		bell_grid() // per kind: Bell, macOS, Sound
		pop_row(.Bell_Dock, !state.settings.bell_dock_off)
		pop_head(2)
		if pop_item_shown(.Agent_Model) do pop_row(.Agent_Model, nil)
		pop_row(.Chats_Readonly, state.settings.chats_readonly)
		pop_row(.Chats_Folder, nil)
		if action_ok(POP_ACTIONS[.Chats_Folder_Default]) do pop_row(.Chats_Folder_Default, nil)
		pop_row(.Tidy_Projects, !state.settings.tidy_off)
		pop_row(.Keep_Sessions, state.settings.keep_sessions)
		pop_row(.Separate_Core, state.settings.separate_core)
		pop_row(.Remote_Machines, state.settings.remote_machines)
		pop_row(.Rescan, nil)
		if pop_item_shown(.Reload_Pi) do pop_row(.Reload_Pi, nil)
		if pop_item_shown(.Restart_Claude) do pop_row(.Restart_Claude, nil)
		pop_row(.Refresh_Env, nil)
		pop_head(3)
		pop_row(.Update_Checks, !core.update_view().checks_off)
		pop_row(.Settings_Files, nil)
		pop_row(.Shortcuts, nil)
		pop_row(.Setup, nil)
		pop_row(.Control_Token, nil)
		}
	}
}

// The keyboard's row in view: the list scrolls by what it is out (its box from the last layout).
@(private = "file")
pop_scroll_to :: proc() {
	if popover.selected < 0 do return
	sc := clay.GetScrollContainerData(clay.ID("settings_list"))
	list, row := clay.GetElementData(clay.ID("settings_list")), clay.GetElementData(pop_id(Pop_Item(popover.selected)))
	if !sc.found || !list.found || !row.found do return
	l, r := list.boundingBox, row.boundingBox
	if r.y < l.y do sc.scrollPosition.y += l.y - r.y
	else if r.y + r.height > l.y + l.height do sc.scrollPosition.y -= r.y + r.height - l.y - l.height
}

// A group's header (POP_GROUPS), a line along the top of all but the first. Short, so the
// popover still fits a window of usual height without scrolling.
@(private = "file")
pop_head :: proc(g: int) {
	groups := POP_GROUPS
	if clay.UI(clay.ID("pop_head", u32(g)))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POP_HEAD_H))}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childAlignment = {y = .Bottom}},
		border = {color = cc(theme().border), width = {top = g > 0 ? pu(core.BORDER_W) : 0}},
	}) {
		clay.TextDynamic(groups[g], txt(theme().text_muted, FONT_UI_SMALL | WEIGHT_HEADER))
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
			ui_do(core.Set_Focus{""}) // a shortcut (⌘N, ⌘Q, ...) closes it and runs as usual
			return false
		}
		n := len(Pop_Item)
		#partial switch e.key_code {
		case .ESCAPE:                   ui_do(core.Set_Focus{""})
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
		else do ui_do(core.Set_Focus{""}) // outside (or the settings button again): closes
		app.redraw = true
		return true
	case .MOUSE_SCROLL: // the list, when taller than the window
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
		app.redraw = true
		return true
	case .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_UP:
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
		if it.action == "tab_1" do append(rows, Shortcut_Row{"Tab 1–9", "⌘1–⌘9", false})
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
			border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
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
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(th.border)}) {}
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
			ui_do(core.Set_Focus{""}) // a shortcut closes the sheet and runs as usual
			return false
		}
		if e.key_code == .ESCAPE || e.key_code == .ENTER do ui_do(core.Set_Focus{""})
		return true
	case .MOUSE_MOVE:
		set_hover(chrome_hit({e.mouse_x, e.mouse_y}), false)
		return true
	case .MOUSE_DOWN:
		_, close := chrome_hit({e.mouse_x, e.mouse_y}).(Hit_Sheet_Close)
		if close || !inside(clay.ID("sheet_box"), e.mouse_x, e.mouse_y) do ui_do(core.Set_Focus{""})
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
		if Button(x) == .Fleet do return fleet_tip()
		return act(BUTTONS[Button(x)].action)
	case Hit_Agent:
		return drawer_tip(x)
	case Hit_Home: // the agent's button (far right)
		return act("toggle_agent")
	case Hit_Close_Tab:
		if _, _, i := find_tab(u64(x)); i == 0 do return act("close_session") // the pi tab closes its session
		return act("close_tab")
	case Hit_Pin_Project:
		p := core.find_project(u64(x))
		return p != nil && core.project_pinned(p^) >= 0 ? "Unpin" : "Pin", ""
	case Hit_Pin_Session:
		return core.session_pinned(string(x)) >= 0 ? "Unpin" : "Pin", ""
	case Hit_New_In:
		if c := core.chats_project(); c != nil && c.id == u64(x) do return act("new_chat")
		return "New session in this project", ""
	case Hit_Add_Project:
		return act("add_project")
	case Hit_Machine_Add:
		return MACHINE_ADD_TIP, ""
	case Hit_Machine: // its button: what it does
		for m in state.machines do if m.no == u64(x) do return machine_action_tip(m), ""
	case Hit_Machine_More:
		return "More actions", ""
	case Hit_Machine_Head: // its header: why, in plain words, then ssh's own
		if x == 0 do return MACHINE_HERE_TIP, "" // this Mac's
		for m in state.machines do if m.no == u64(x) do return machine_tip(m), ""
	case Hit_Close_Session:
		return act("close_session")
	case Hit_Pane_Zoom: // the zoomed pane's marker
		return act("zoom_pane")
	case Hit_More_Project, Hit_More_Session, Hit_More_Open:
		return "More actions", ""
	case Hit_Info_Session:
		return fmt.tprintf("Session info: copy it, or send it to %s", core.agent_name()), ""
	case Hit_New_Job_In:
		return "New job for this project: a form that writes the job's note", ""
	case Hit_Sort:
		return strings.concatenate({"Sorted by ", strings.to_lower(SORT_LABELS[state.sidebar.sort[core.Sort_Section(x)]], context.temp_allocator), " (sort, show hidden)"}, context.temp_allocator), ""
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
		if tip := bell_grid_tip(Pop_Item(x)); tip != "" do return tip, ""
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
		ts, tab, _ := find_tab(u64(x))
		if tip := dead_tab_hover_tip(tab); tip != "" do return tip, ""
		if tab != nil {
			// a Claude tab: its model too (claude_rows.odin)
			st, model := core.status_explain(tab^), core.claude_tab_tip(tab^)
			tip := model != "" ? model : st
			if st != "" && model != "" do tip = fmt.tprintf("%s — %s", model, st)
			// another machine's tab: where it runs, first
			if ts != nil && ts.machine != 0 do tip = tip != "" ? fmt.tprintf("On %s · %s", core.machine_name(ts.machine), tip) : fmt.tprintf("On %s", core.machine_name(ts.machine))
			return tip, ""
		}
	case Hit_Fleet_Row:
		return fleet_row_tip(u64(x))
	case Hit_Peek:
		return peek_tip(x)
	case Hit_Peek_Row:
		return PEEK_ROW_TIP, ""
	case Hit_Deck_Card:
		return deck_tip(u64(x))
	case Hit_Deck_More:
		return "More", ""
	case Hit_Attention:
		switch int(x) {
		case ATTN_HIT_IDLE:   return attention_idle_open ? "Fold the idle sessions" : "Show the idle sessions", ""
		case ATTN_HIT_FOOTER: return "Back to the tree: each machine, its projects and sessions", ""
		case int(core.Sidebar_View.Attention): return "One list across every machine, by what needs you", "⌥⌘."
		}
		return "The tree: each machine, its projects and sessions", "⌥⌘."
	case Hit_Open_Row:
		s := core.find_session(u64(x))
		if tip := dead_tab_hover_tip(core.session_pi_tab(s)); tip != "" do return tip, ""
		return core.session_explain(s), ""
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
		if id := core.open_session_any(string(x)); id != 0 do return core.session_explain(core.find_session(id)), ""
	case Hit_Chat:
		if id := core.open_session_any(string(x)); id != 0 do return core.session_explain(core.find_session(id)), ""
	}
	return "", ""
}

TIP_WRAP_W :: 320 // logical px: a longer tooltip wraps
TIP_LINES :: 6 // at most, per part (the last cut with an ellipsis)

// The tooltip: a small box under the pointer (above it near the bottom
// edge), clamped to the window. A long one wraps at TIP_WRAP_W; its shortcut
// stays on the right of its first line.
tooltip_layout :: proc(w, h: f32) {
	if !tip.shown || tip.off do return
	label, keys := hit_tip(ui_hover)
	if label == "" do return
	th := theme()
	// a second part (after "\n", muted): the raw text a plain first one came from (machine_tip)
	first, _, second := strings.partition(label, "\n")
	second = core.one_line(second, context.temp_allocator)
	keys_w := keys != "" ? text_w(keys, FONT_UI_SMALL) + px(SP_2) : 0
	wrap_w := max(min(px(TIP_WRAP_W), w - px(2 * SP_2 + 2 * SP_1) - keys_w), px(40))
	l1, n1 := wrap_clip(first, wrap_w, TIP_LINES, FONT_UI_SMALL)
	l2, n2 := wrap_clip(second, wrap_w, TIP_LINES, FONT_UI_SMALL)
	text_wd: f32
	for l in strings.split_lines(l1, context.temp_allocator) do text_wd = max(text_wd, text_w(l, FONT_UI_SMALL))
	for l in strings.split_lines(l2, context.temp_allocator) do text_wd = max(text_wd, text_w(l, FONT_UI_SMALL))
	tw := min(text_wd, wrap_w) + px(2 * SP_2) + keys_w
	kind, _ := font_id_split(FONT_UI_SMALL)
	lines := n1 + n2
	th_px := lines <= 1 ? px(TIP_H) : f32(lines) * text_line_height(kind) + px(2 * SP_1 + 2)
	x := clamp(tip.at.x - px(SP_2), px(SP_1), max(w - tw - px(SP_1), 0))
	y := tip.at.y + px(TIP_OFFSET)
	if y + th_px > h do y = tip.at.y - px(TIP_OFFSET) - th_px
	y = clamp(y, px(SP_1), max(h - th_px - px(SP_1), px(SP_1))) // on screen near the top and bottom edges
	wrapped :: proc(col: core.Rgba) -> clay.TextElementConfig {
		cfg := txt(col, FONT_UI_SMALL)
		cfg.wrapMode = .Newlines
		return cfg
	}
	if clay.UI(clay.ID("tooltip"))({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(th_px)}, padding = {pu(SP_2), pu(SP_2), lines > 1 ? pu(SP_1) : 0, 0}, childGap = pu(SP_2), childAlignment = {y = lines > 1 ? .Top : .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 30},
	}) {
		if n2 == 0 {
			clay.TextDynamic(l1, wrapped(th.text))
		} else if clay.UI()({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = pu(2)}}) {
			clay.TextDynamic(l1, wrapped(th.text))
			clay.TextDynamic(l2, wrapped(th.text_muted))
		}
		if keys != "" do clay.TextDynamic(keys, txt(th.text_muted, FONT_UI_SMALL))
	}
}
