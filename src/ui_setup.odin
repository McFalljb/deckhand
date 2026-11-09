package main

// The first-run sheet (focus widget "setup"; folders.odin): four steps over
// the window.
//
//   0. Your coding agents: the harness checklist (ui_harness.odin): each harness installed or not,
//      its version against the minimum, Deckhand's own integration (built in), the recommended
//      third-party items, Install and Update on a click in a terminal on the sheet.
//   1. The main folder: use the notes folder found (PI_KIT_NOTES_DIR, else
//      a folder named in pi's global AGENTS.md that has sessions/ or a
//      README.md), create ~/Deckhand, or choose another folder.
//   2. Chats: inside the main folder (chats/) or a separate folder.
//   3. Claude Code accounts, only when two or more are found (claude_accounts.odin: config
//      folders, by stat): tick the ones to use, edit their labels, add folders anywhere (a
//      picker or a typed path; one without Claude Code's files is added with a warning), choose
//      the default. Done writes the same setting Settings → Claude accounts edits. One account
//      or none: no step; the last step's line says which.
//   4. The layout as a small tree, then Done.
//
// It opens by itself once when no main folder is set (setup_due; test mode
// only with DECKHAND_FIRST_RUN=1), and from "Set up Deckhand…" (the palette,
// the Jobs tab, Atlas's drawer, the Settings tab's Folders group). Skip for
// now and Done both close it for good (Setup_Sheet{open = false}); Done
// sends Set_Folder (chats), then Set_Home_Dir{setup = true}, which closes it
// only when it worked (else the sheet shows why). Enter: Next / Done; Esc:
// Back, or Skip on step 1; ↑↓: the choice.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

Setup_Main :: enum u8 {
	Detected, // the notes folder found
	Create, // ~/Deckhand
	Other, // picked
}

Setup_UI :: struct {
	step:     int, // 0, 1, 2
	main:     Setup_Main,
	other:    string, // heap: the picked main folder
	detected: string, // heap: the notes folder found ("" = none)
	why:      string, // heap: how it was found
	separate: bool, // chats in their own folder
	chats:    string, // heap: that folder
	touched:  bool, // the user chose: a later detection does not change the choice
	err:      string, // heap: why Done failed ("" = none)
	// the Claude accounts step (shown when two or more were found at the start)
	acct_show:    bool,
	accounts:     [dynamic]core.Setup_Account,
	acct_default: int, // index into accounts
	acct_msg:     string, // heap: the last add's warning or error ("" = none)
	acct_msg_err: bool,
	edit:         int, // the field being typed in: SETUP_EDIT_NONE, SETUP_EDIT_PATH, or an account's label
	field:        Text_Field,
}
setup_ui: Setup_UI = {edit = SETUP_EDIT_NONE}

SETUP_EDIT_NONE :: -1
SETUP_EDIT_PATH :: -2

Setup_Hit_Kind :: enum u8 {
	Option, // index: the option
	Skip,
	Back,
	Next, // Next, or Done on the last step
	Choose_Chats, // the separate folder's Choose…
	// the accounts step (index: the account)
	Acct_Keep, // its checkbox
	Acct_Label, // its label: click to edit
	Acct_Default, // its Default radio
	Acct_Path, // the typed path field
	Acct_Add, // Add (the typed path)
	Acct_Pick, // Add folder… (a picker)
	// the coding agents step (index: the manifest row)
	Agent_Action, // Install or Update
	Agent_Copy, // a command Deckhand does not run: copied
	Agent_Close, // the run's output goes
}

Hit_Setup :: struct {
	what:  Setup_Hit_Kind,
	index: int,
}

// The sheet's steps now: 4, or 5 with the accounts step.
setup_steps :: proc() -> int {return setup_ui.acct_show ? 5 : 4}

setup_step_kind :: proc() -> core.Setup_Step {
	switch setup_ui.step {
	case 0: return .Agents
	case 1: return .Main
	case 2: return .Chats
	case 3: return setup_ui.acct_show ? .Accounts : .Folders
	}
	return .Folders
}

// A run on the coding agents step keeps the sheet where it is (its terminal shows there).
@(private = "file")
run_holds :: proc() -> bool {
	if core.harness_run.status != .Running do return false
	set_str(&setup_ui.err, "An install is running: wait for it to finish (⌃C in its terminal stops it)")
	return true
}

setup_open :: proc() -> bool {return state.focus_widget == "setup"}

@(private = "file")
set_str :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

// The sheet starts over: step 1, the detected folder (or ~/Deckhand), chats
// pre-selected from what is there.
setup_begin :: proc() {
	u := &setup_ui
	u.step = 0
	u.touched = false
	set_str(&u.err, "")
	p, why := core.setup_detect()
	set_str(&u.detected, p)
	set_str(&u.why, why)
	u.main = p != "" ? .Detected : .Create
	if h := state.settings.home_dir; h != "" && h != p {
		u.main = .Other
		set_str(&u.other, h)
	}
	// chats: a separate folder when one is set, or ~/Chats has chats already
	home_chats := fmt.tprintf("%s/Chats", os.get_env("HOME", context.temp_allocator))
	u.separate = false
	set_str(&u.chats, home_chats)
	if o := state.settings.folders[.Chats]; o != "" {
		u.separate = true
		set_str(&u.chats, o)
	} else if state.settings.home_dir == "" {
		c := core.chats_project()
		if c != nil && c.cwd == core.real_path(home_chats) && len(state.chats) > 0 do u.separate = true
	}
	setup_accounts_begin()
	core.harness_checklist_refresh() // looked at again each time the sheet opens
}

// ---- the accounts step ----

@(private = "file")
account_free :: proc(a: ^core.Setup_Account) {
	delete(a.dir)
	delete(a.label)
	delete(a.orig_label)
}

// The accounts found now (a fresh look, stat only), and the ones the user removed before
// (unticked); the default chosen before is pre-selected.
setup_accounts_begin :: proc() {
	u := &setup_ui
	for &a in u.accounts do account_free(&a)
	clear(&u.accounts)
	set_str(&u.acct_msg, "")
	u.edit = SETUP_EDIT_NONE
	tf_set(&u.field, "")
	core.claude_accounts_refresh()
	for a in core.claude_accounts() {
		append(&u.accounts, core.Setup_Account{dir = strings.clone(a.dir), label = strings.clone(a.label), orig_label = strings.clone(a.label), keep = true, was_kept = true, fixed = a.default, marked = core.claude_account_marked(a.dir)})
		if a.chosen do u.acct_default = len(u.accounts) - 1
	}
	if len(u.accounts) == 0 do u.acct_default = 0
	for st in state.settings.claude_accounts {
		if !st.removed || core.path_kind(st.dir) != .Dir do continue
		label := st.label != "" ? st.label : core.claude_account_label_of(st.dir)
		append(&u.accounts, core.Setup_Account{dir = strings.clone(st.dir), label = strings.clone(label), orig_label = strings.clone(label), marked = core.claude_account_marked(st.dir)})
	}
	u.acct_show = len(u.accounts) >= 2
}

// A folder for the list (typed, or from the picker): absolute (or ~/…), there, a folder, not
// HOME or above it, not listed yet. ok with a warning when it has none of Claude Code's files.
setup_account_add :: proc(path: string) -> (ok: bool, msg: string) {
	u := &setup_ui
	d, err := core.folder_arg(path)
	if err != "" || d == "" do return false, d == "" && err == "" ? "Type a folder's path" : "Type a full path (/… or ~/…)"
	if core.path_kind(d) != .Dir do return false, fmt.tprintf("%s: no such folder", core.fs_display(d))
	if why := core.claude_account_dir_refused(d); why != "" {
		if strings.has_prefix(why, "a Claude Code config folder is not your home") do return false, "Not your home folder or above it: pick the Claude Code config folder itself"
		return false, fmt.tprintf("%s%s", strings.to_upper(why[:1], context.temp_allocator), why[1:])
	}
	for &a, i in u.accounts do if a.dir == d || core.fs_real(a.dir) == core.fs_real(d) {
		if !a.keep do setup_account_toggle(i)
		return false, fmt.tprintf("%s is already listed (%s)", core.fs_display(d), a.label)
	}
	marked := core.claude_account_marked(d)
	append(&u.accounts, core.Setup_Account{dir = strings.clone(d), label = strings.clone(core.claude_account_label_of(d)), orig_label = strings.clone(""), keep = true, hand = true, marked = marked})
	if !marked do return true, "It has no Claude Code files yet (.claude.json, .credentials.json): added anyway; Claude Code makes them when you sign in there."
	return true, ""
}

// Adds what the path field holds; the field empties when it worked.
@(private = "file")
add_typed :: proc() {
	u := &setup_ui
	ok, msg := setup_account_add(tf_text(&u.field))
	set_str(&u.acct_msg, msg)
	u.acct_msg_err = !ok
	if ok do tf_set(&u.field, "")
	u.touched = true
}

// A folder from the picker (actions.odin: setup_pick_account).
setup_account_picked :: proc(path: string) {
	ok, msg := setup_account_add(path)
	set_str(&setup_ui.acct_msg, msg)
	setup_ui.acct_msg_err = !ok
	setup_ui.touched = true
}

// Ticks or unticks an account (never the environment's default). Unticking the default moves
// it to the environment's.
setup_account_toggle :: proc(i: int) {
	u := &setup_ui
	if i < 0 || i >= len(u.accounts) || u.accounts[i].fixed do return
	u.accounts[i].keep = !u.accounts[i].keep
	if !u.accounts[i].keep && u.acct_default == i do u.acct_default = 0
	u.touched = true
}

// The default for new Claude sessions (ticks it).
setup_account_set_default :: proc(i: int) {
	u := &setup_ui
	if i < 0 || i >= len(u.accounts) do return
	u.accounts[i].keep = true
	u.acct_default = i
	u.touched = true
}

// A new label ("" = from the folder's name again).
setup_account_set_label :: proc(i: int, label: string) {
	u := &setup_ui
	if i < 0 || i >= len(u.accounts) do return
	l := core.cut_utf8(strings.trim_space(core.one_line(label, context.temp_allocator)), core.CLAUDE_ACCOUNT_LABEL_MAX)
	if l == "" do l = u.accounts[i].fixed ? "Claude" : core.claude_account_label_of(u.accounts[i].dir)
	set_str(&u.accounts[i].label, l)
	u.touched = true
}

// Done: the same commands Settings → Claude accounts sends (claude_accounts.odin).
setup_accounts_done :: proc() {
	u := &setup_ui
	if !u.acct_show do return
	// renames in two steps (to the folder's name, then the new one): labels swapped between two
	// accounts would clash one at a time
	for a, i in u.accounts do if a.keep && !a.hand && a.was_kept && a.label != a.orig_label do ui_do(core.Rename_Claude_Account{account = a.dir, label = fmt.tprintf("(renaming %d)", i)})
	for a in u.accounts {
		if a.hand {
			if a.keep do ui_do(core.Add_Claude_Account{dir = a.dir, label = a.label != core.claude_account_label_of(a.dir) ? a.label : ""})
			continue
		}
		if !a.keep {
			if a.was_kept && !a.fixed do ui_do(core.Remove_Claude_Account{account = a.dir})
			continue
		}
		if !a.was_kept do ui_do(core.Add_Claude_Account{dir = a.dir})
		if a.label != a.orig_label do ui_do(core.Rename_Claude_Account{account = a.dir, label = a.label != core.claude_account_label_of(a.dir) ? a.label : ""})
	}
	if u.acct_default >= 0 && u.acct_default < len(u.accounts) && u.accounts[u.acct_default].keep {
		ui_do(core.Set_Claude_Account_Default{account = u.accounts[u.acct_default].dir})
	}
}

// Starts typing in a label (i >= 0) or the path field; what was being typed is kept first.
@(private = "file")
edit_begin :: proc(which: int) {
	u := &setup_ui
	edit_end(true)
	u.edit = which
	if which >= 0 && which < len(u.accounts) do tf_set(&u.field, u.accounts[which].label)
	else if which == SETUP_EDIT_PATH do tf_end(&u.field, false)
}

// Stops typing: a label is kept (or not), the path stays in its field.
@(private = "file")
edit_end :: proc(keep: bool) {
	u := &setup_ui
	if u.edit >= 0 {
		if keep do setup_account_set_label(u.edit, tf_text(&u.field))
		tf_set(&u.field, "")
	}
	u.edit = SETUP_EDIT_NONE
}

// PI_KIT_NOTES_DIR arrived from the login shell (jobs.odin): found again,
// unless the user chose already.
setup_detect_again :: proc() {
	if !setup_open() || setup_ui.touched do return
	p, why := core.setup_detect()
	set_str(&setup_ui.detected, p)
	set_str(&setup_ui.why, why)
	if p != "" && setup_ui.main == .Create do setup_ui.main = .Detected
}

// A folder picker's answer (actions.odin: setup_pick_main, setup_pick_chats).
setup_picked :: proc(chats: bool, path: string) {
	if chats {
		set_str(&setup_ui.chats, path)
		setup_ui.separate = true
	} else {
		set_str(&setup_ui.other, path)
		setup_ui.main = .Other
	}
	setup_ui.touched = true
}

// The main folder the sheet would set ("" = not picked yet; temp).
setup_main_path :: proc() -> string {
	switch setup_ui.main {
	case .Detected: return setup_ui.detected
	case .Create:   return setup_create_path()
	case .Other:    return setup_ui.other
	}
	return ""
}

// The folder "Create ~/Deckhand" makes (temp): ~/Deckhand, or ~/pi-desk when only that one is there
// (made by pi-desk, before the rename: its files stay where they are).
setup_create_path :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	p := fmt.tprintf("%s/Deckhand", home)
	if old := fmt.tprintf("%s/pi-desk", home); !os.is_dir(p) && os.is_dir(old) do return old
	return p
}

@(private = "file")
setup_options :: proc() -> []Setup_Main {
	out := make([dynamic]Setup_Main, context.temp_allocator)
	if setup_ui.detected != "" do append(&out, Setup_Main.Detected)
	append(&out, Setup_Main.Create, Setup_Main.Other)
	return out[:]
}

@(private = "file")
option_count :: proc() -> int {
	#partial switch setup_step_kind() {
	case .Main:  return len(setup_options())
	case .Chats: return 2
	}
	return 0
}

@(private = "file")
option_selected :: proc(i: int) -> bool {
	#partial switch setup_step_kind() {
	case .Main:  return setup_options()[i] == setup_ui.main
	case .Chats: return (i == 1) == setup_ui.separate
	}
	return false
}

@(private = "file")
option_pick :: proc(i: int) {
	u := &setup_ui
	u.touched = true
	#partial switch setup_step_kind() {
	case .Main:
		opts := setup_options()
		if i < 0 || i >= len(opts) do return
		u.main = opts[i]
		if u.main == .Other && u.other == "" do action_run("setup_pick_main")
	case .Chats:
		u.separate = i == 1
	}
}

// Next, or Done on the last step.
@(private = "file")
setup_next :: proc() {
	u := &setup_ui
	edit_end(true)
	if run_holds() do return
	set_str(&u.err, "")
	if setup_step_kind() == .Main && setup_main_path() == "" {
		action_run("setup_pick_main") // Choose another folder… with nothing picked yet
		return
	}
	if u.step < setup_steps() - 1 {
		u.step += 1
		return
	}
	main := setup_main_path()
	set_str(&u.err, "")
	setup_accounts_done()
	// chats first: the main folder then makes chats/ only when chats live there
	if u.separate {
		if !os.is_dir(u.chats) do os.make_directory_all(u.chats) // setup is the user's explicit choice
		ui_do(core.Set_Folder{kind = .Chats, path = u.chats})
	} else do ui_do(core.Set_Folder{kind = .Chats, path = ""})
	ui_do(core.Set_Home_Dir{path = main, create = u.main == .Create, setup = true}) // closes the sheet only if it worked
}

// A run on the coding agents step ended (harness_install.odin): what the sheet said about it goes.
setup_clear_error :: proc() {set_str(&setup_ui.err, "")}

// Done's Set_Home_Dir failed (folders.odin): the sheet stays open and says why.
setup_failed :: proc(why: string) {
	set_str(&setup_ui.err, fmt.tprintf("Could not use %s: %s. Choose another folder.", core.fs_display(setup_main_path()), why))
}

// What the core tells the sheet (window.setup_sheet, window_hooks.odin).
setup_sheet_op :: proc(op: core.Setup_Sheet_Op, why: string) {
	switch op {
	case .Begin:        setup_begin()
	case .Clear_Error:  setup_clear_error()
	case .Detect_Again: setup_detect_again()
	case .Failed:       setup_failed(why)
	}
}

// The sheet as get_state shows it (window.setup_state).
setup_state_now :: proc() -> (core.Setup_State, bool) {
	u := &setup_ui
	return {step = setup_step_kind(), steps = setup_steps(), err = u.err, acct_show = u.acct_show, accounts = u.accounts[:], acct_default = u.acct_default, acct_msg = u.acct_msg}, true
}

@(private = "file")
setup_back :: proc() {
	edit_end(true)
	if run_holds() do return
	if setup_ui.step > 0 do setup_ui.step -= 1
	set_str(&setup_ui.err, "")
}

// ---- layout ----

@(private = "file")
para :: proc(text: string, col: core.Rgba, font: u16 = FONT_UI_SMALL) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_1), pu(SP_1), 2, 2}}}) {
		cfg := txt(col, font)
		cfg.wrapMode = .Words
		clay.TextDynamic(text, cfg)
	}
}

// One choice: a radio mark, its title, muted lines under it (each one
// line, cut to fit: paths have no spaces to wrap at).
@(private = "file")
option_row :: proc(i: int, title: string, details: []string, room: f32) {
	th := theme()
	id := clay.ID("setupopt", u32(i))
	sel := option_selected(i)
	hov := ui_hover == Hit(Hit_Setup{what = .Option, index = i})
	bg, em := overlay(id, sel, hov)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_2), pu(SP_1), pu(SP_1)}, childGap = pu(SP_2), childAlignment = {y = .Top}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(sel ? th.accent : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
	}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_3)), clay.SizingFit()}}}) {
			clay.TextDynamic(sel ? "●" : "○", txt(sel ? th.accent : th.text_muted))
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = 2}}) {
			clay.TextDynamic(clip(title, room, WEIGHT_BOLD), txt(mix(th.text_secondary, th.text, max(em, sel ? 1 : 0)), WEIGHT_BOLD))
			for d in details do if d != "" do clay.TextDynamic(clip(d, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		}
	}
}

// One line of the summary tree: a name, then what it holds.
@(private = "file")
tree_line :: proc(depth: int, name, does: string, room: f32) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(SHEET_ROW_H))}, padding = {pu(SP_2 + SP_3 * f32(depth)), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		nw := min(text_w(name, FONT_MONO), room * 0.6)
		clay.TextDynamic(clip(name, nw, FONT_MONO), txt(th.text, FONT_MONO))
		if does != "" do clay.TextDynamic(clip(does, room - nw - px(SP_2 + SP_3 * f32(depth)), FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
	}
}

// The accounts step: what an account is, one row per account (a checkbox, its label, its
// folder, Default), then a path field with Add and Add folder…, then the last add's warning.
@(private = "file")
accounts_body :: proc(w: f32) {
	th := theme()
	u := &setup_ui
	para("An account is a Claude Code config folder (what CLAUDE_CONFIG_DIR names). API-key, Bedrock or Vertex sign-ins come from your environment and need no folder.", th.text_secondary)
	para("Tick the ones Deckhand should offer; click a name to change it. New Claude sessions start in the default.", th.text_muted)
	def_w := text_w("○ Default", FONT_UI_SMALL) + px(SP_2)
	for a, i in u.accounts {
		hov_row := false
		if h, ok := ui_hover.(Hit_Setup); ok && h.index == i && (h.what == .Acct_Keep || h.what == .Acct_Label || h.what == .Acct_Default) do hov_row = true
		sel := i == u.acct_default && a.keep
		if clay.UI(clay.ID("setupacct", u32(i)))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_2), pu(SP_1), pu(SP_1)}, childGap = pu(SP_2), childAlignment = {y = .Top}},
			backgroundColor = cc(hov_row ? mix(th.bg_elevated, th.text, TINT_BUTTON) : th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
			border = {color = cc(sel ? th.accent : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		}) {
			// the checkbox (the environment's default: always ticked, muted)
			if clay.UI(clay.ID("setupkeep", u32(i)))({layout = {sizing = {clay.SizingFixed(px(SP_3 + SP_1)), clay.SizingFit()}}}) {
				col := a.fixed ? th.text_muted : a.keep ? th.accent : th.text_secondary
				clay.TextDynamic(a.keep ? "☑" : "☐", txt(col))
			}
			room := w - px(4 * SP_2 + SP_3 + SP_1) - def_w
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = 2}}) {
				if u.edit == i {
					if clay.UI(clay.ID("setup_field_box"))({
						layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_1), pu(SP_1), 0, 0}, childAlignment = {y = .Center}},
						backgroundColor = cc(th.bg_field),
						cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
						border = {color = cc(th.accent), width = clay.BorderOutside(pu(FOCUS_RING_W))},
					}) {
						field_text(clay.ID("setup_field_text"), &u.field, "")
					}
				} else if clay.UI(clay.ID("setuplabel", u32(i)))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
					clay.TextDynamic(clip(a.label, room, WEIGHT_BOLD), txt(a.keep ? th.text : th.text_muted, WEIGHT_BOLD))
				}
				at := core.fs_display(a.dir)
				if !a.marked do at = fmt.tprintf("%s · no Claude Code files yet", at)
				else if a.fixed do at = fmt.tprintf("%s · what `claude` uses in your shell", at)
				clay.TextDynamic(clip(at, room, FONT_UI_SMALL), txt(a.marked ? th.text_muted : th.waiting, FONT_UI_SMALL))
			}
			// Default (a radio)
			if clay.UI(clay.ID("setupdef", u32(i)))({layout = {sizing = {clay.SizingFixed(def_w), clay.SizingFit()}, childAlignment = {x = .Right}}}) {
				clay.TextDynamic(sel ? "● Default" : "○ Default", txt(sel ? th.accent : th.text_muted, FONT_UI_SMALL))
			}
		}
	}
	// a folder anywhere: typed, or picked
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		editing := u.edit == SETUP_EDIT_PATH
		if clay.UI(editing ? clay.ID("setup_field_box") : clay.ID("setuppath"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			border = {color = cc(editing ? th.accent : th.border), width = clay.BorderOutside(pu(editing ? FOCUS_RING_W : core.BORDER_W))},
			clip = {horizontal = true},
		}) {
			if editing do field_text(clay.ID("setup_field_text"), &u.field, "")
			else {
				t := tf_text(&u.field)
				clay.TextDynamic(t != "" ? t : "Type a folder path (~/… or /…)", txt(t != "" ? th.text : th.text_muted))
			}
		}
		button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Acct_Add)), "Add", false, ui_hover == Hit(Hit_Setup{what = .Acct_Add}))
		button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Acct_Pick)), "Add folder…", false, ui_hover == Hit(Hit_Setup{what = .Acct_Pick}))
	}
	if u.acct_msg != "" do para(u.acct_msg, u.acct_msg_err ? th.error : th.waiting)
}

setup_layout :: proc(w, h: f32) {
	if !setup_open() do return
	th := theme()
	u := &setup_ui
	box_w := min(px(SHEET_W), w - px(2 * SP_4))
	room := box_w - px(2 * SP_3 + 2 * SP_2 + SP_3 + SP_2) // an option's text
	if clay.UI(clay.ID("setup_scrim"))({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = {0, 0, pu(SHEET_TOP), pu(SP_4)}, childAlignment = {x = .Center}},
		backgroundColor = cc(th.scrim),
		floating = {attachTo = .Root, zIndex = 10},
	}) {
		if clay.UI(clay.ID("setup_box"))({
			layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit({max = h - px(SHEET_TOP + SP_4)})}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_3)), childGap = pu(SP_2)},
			backgroundColor = cc(th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
			border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		}) {
			titles := [core.Setup_Step]string{.Agents = "Your coding agents", .Main = "Where should Deckhand keep your files?", .Chats = "Where should chats run?", .Accounts = "Claude Code accounts", .Folders = "Your folders"}
			kind := setup_step_kind()
			step := fmt.tprintf("Step %d of %d", u.step + 1, setup_steps())
			if clay.UI(clay.ID("setup_head"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_1), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				sw := text_w(step, FONT_UI_SMALL)
				clay.TextDynamic(clip(titles[kind], box_w - px(2 * SP_3 + 2 * SP_1 + SP_2) - sw, WEIGHT_BOLD), txt(th.text, WEIGHT_BOLD))
				spacer()
				clay.TextDynamic(step, txt(th.text_muted, FONT_UI_SMALL))
			}
			// scrolls when a step is taller than the window allows (the coding agents with a run's output)
			if clay.UI(clay.ID("setup_body"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = pu(SP_2)},
				clip = {vertical = true, childOffset = clay.GetScrollOffset()},
			}) {
				switch kind {
				case .Agents:
					harness_step_body(box_w - px(2 * SP_3))
				case .Main:
					para("One main folder holds your session notes, jobs, memory, Atlas's prompt and chats. You can move any of them later (Settings tab, Folders).", th.text_secondary)
					for o, i in setup_options() {
						switch o {
						case .Detected:
							option_row(i, "Use your notes folder", {core.fs_display(u.detected), fmt.tprintf("Found: %s", u.why)}, room)
						case .Create:
							p := setup_create_path()
							shown := fmt.tprintf("~/%s", filepath.base(p))
							option_row(i, os.is_dir(p) ? fmt.tprintf("Use %s", shown) : fmt.tprintf("Create %s", shown), {os.is_dir(p) ? "It is there already: missing subfolders are added" : "A new folder in your home folder"}, room)
						case .Other:
							option_row(i, "Choose another folder…", {u.other != "" ? core.fs_display(u.other) : "Any folder: missing subfolders are added, nothing else is touched"}, room)
						}
					}
				case .Chats:
					para("Chats run in one folder outside any project (pi and Claude Code alike): files they create in chats land in that folder.", th.text_secondary)
					main := setup_main_path()
					option_row(0, "Inside the main folder (chats/)", {fmt.tprintf("%s/chats", core.fs_display(main))}, room)
					option_row(1, "Separate folder", {core.fs_display(u.chats)}, room)
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), 0, 0, 0}}}) {
						button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Choose_Chats)), "Choose separate folder…", false, ui_hover == Hit(Hit_Setup{what = .Choose_Chats}))
					}
				case .Accounts:
					accounts_body(box_w - px(2 * SP_3))
				case .Folders:
					main := setup_main_path()
					tree_line(0, fmt.tprintf("%s/", core.fs_display(main)), "the main folder", box_w - px(2 * SP_3))
					for k in core.Folder_Kind {
						if k == .Chats && u.separate {
							tree_line(1, "chats →", fmt.tprintf("%s (separate)", core.fs_display(u.chats)), box_w - px(2 * SP_3))
						} else do tree_line(1, fmt.tprintf("%s/", core.FOLDER_NAMES[k]), core.FOLDER_DOES[k], box_w - px(2 * SP_3))
						if k == .Chats do tree_line(2, "AGENTS.md", "chat instructions: talk, explain, look things up", box_w - px(2 * SP_3))
					}
					para("Missing folders are made, empty. Nothing already there is moved or changed.", th.text_secondary)
					para(core.setup_claude_line(), th.text_secondary)
					if v := core.notes_env_user(); v != "" do para(fmt.tprintf("Your PI_KIT_NOTES_DIR (%s) stays as it is: pi-kit's notes go there.", core.fs_display(v)), th.text_secondary)
				}
				if u.err != "" do para(u.err, th.error)
			}
			if clay.UI(clay.ID("setup_foot"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {0, 0, pu(SP_1), 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Skip)), "Skip for now", false, ui_hover == Hit(Hit_Setup{what = .Skip}))
				spacer()
				if u.step > 0 do button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Back)), "Back", false, ui_hover == Hit(Hit_Setup{what = .Back}))
				button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Next)), u.step == setup_steps() - 1 ? "Done" : "Next", true, ui_hover == Hit(Hit_Setup{what = .Next}))
			}
		}
	}
}

setup_hit :: proc() -> Hit {
	for k in Setup_Hit_Kind do if k != .Option && clay.PointerOver(clay.ID("setupbtn", u32(k))) do return Hit_Setup{what = k}
	if setup_step_kind() == .Agents do if h := harness_step_hit(); h != nil do return h
	if setup_step_kind() == .Accounts {
		if clay.PointerOver(clay.ID("setup_field_box")) do return Hit_Setup{what = setup_ui.edit == SETUP_EDIT_PATH ? .Acct_Path : .Acct_Label, index = setup_ui.edit}
		if clay.PointerOver(clay.ID("setuppath")) do return Hit_Setup{what = .Acct_Path, index = SETUP_EDIT_PATH}
		for _, i in setup_ui.accounts {
			if clay.PointerOver(clay.ID("setupkeep", u32(i))) do return Hit_Setup{what = .Acct_Keep, index = i}
			if clay.PointerOver(clay.ID("setuplabel", u32(i))) do return Hit_Setup{what = .Acct_Label, index = i}
			if clay.PointerOver(clay.ID("setupdef", u32(i))) do return Hit_Setup{what = .Acct_Default, index = i}
			if clay.PointerOver(clay.ID("setupacct", u32(i))) do return Hit_Setup{what = .Acct_Keep, index = i}
		}
	}
	for i in 0 ..< option_count() do if clay.PointerOver(clay.ID("setupopt", u32(i))) do return Hit_Setup{what = .Option, index = i}
	return nil
}

setup_tip :: proc(h: Hit_Setup) -> (string, string) {
	switch h.what {
	case .Skip:         return "Jobs stay off until a main folder is set (Set up Deckhand…, in the palette or the Settings tab)", "Esc"
	case .Back:         return "The previous step", "Esc"
	case .Next:         return setup_ui.step == setup_steps() - 1 ? "Make the folders and close" : "The next step", "Enter"
	case .Choose_Chats: return "Pick the folder chats run in", ""
	case .Option:       return "", "↑↓"
	case .Acct_Keep:
		if h.index >= 0 && h.index < len(setup_ui.accounts) && setup_ui.accounts[h.index].fixed do return "The account `claude` uses in your shell: always offered", ""
		return "Offer this account in Deckhand (unticked: left out; its folder is not touched)", ""
	case .Acct_Label:   return "Rename (its name in Deckhand only)", "Enter"
	case .Acct_Default: return "New Claude sessions start in this account unless their project last used another", ""
	case .Acct_Path:    return "A Claude Code config folder anywhere (what CLAUDE_CONFIG_DIR names)", "Enter"
	case .Acct_Add:     return "Add the folder typed here", "Enter"
	case .Acct_Pick:    return "Pick a Claude Code config folder (hidden folders: ⌘⇧.)", ""
	case .Agent_Action, .Agent_Copy: return harness_step_tip(h), ""
	case .Agent_Close:  return "Close the output (the checklist was checked again)", ""
	}
	return "", ""
}

// Input while the sheet shows: it takes everything but ⌘Q.
setup_event :: proc(e: ^sapp.Event) -> bool {
	if setup_ui.edit != SETUP_EDIT_NONE && field_event(e) do return true
	if setup_step_kind() == .Agents && harness_step_event(e) do return true // a run's terminal (ui_harness.odin)
	#partial switch e.type {
	case .KEY_DOWN:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 && e.key_code == .Q do return false
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER: setup_next()
		case .ESCAPE:
			if setup_ui.step > 0 do setup_back()
			else if !run_holds() do ui_do(core.Setup_Sheet{open = false})
		case .UP, .DOWN:
			n := option_count()
			if n > 0 {
				cur := 0
				for i in 0 ..< n do if option_selected(i) do cur = i
				nxt := clamp(cur + (e.key_code == .DOWN ? 1 : -1), 0, n - 1)
				if setup_step_kind() == .Main && setup_options()[nxt] == .Other && setup_ui.other == "" {
					setup_ui.main = .Other // the picker opens on Enter (Next)
					setup_ui.touched = true
				} else do option_pick(nxt)
			}
		}
		app.key_taken = true
		app.redraw = true
		return true
	case .MOUSE_MOVE:
		set_hover(chrome_hit({e.mouse_x, e.mouse_y}), false)
		return true
	case .MOUSE_DOWN:
		h, ok := chrome_hit({e.mouse_x, e.mouse_y}).(Hit_Setup)
		if e.mouse_button == .LEFT && setup_ui.edit != SETUP_EDIT_NONE && !(ok && (h.what == .Acct_Path || h.what == .Acct_Label) && h.index == setup_ui.edit) do edit_end(true)
		if ok && e.mouse_button == .LEFT {
			switch h.what {
			case .Option:       option_pick(h.index)
			case .Skip:         if !run_holds() do ui_do(core.Setup_Sheet{open = false})
			case .Back:         setup_back()
			case .Next:         setup_next()
			case .Choose_Chats: action_run("setup_pick_chats")
			case .Acct_Keep:    setup_account_toggle(h.index)
			case .Acct_Default: setup_account_set_default(h.index)
			case .Acct_Label:   if setup_ui.edit != h.index do edit_begin(h.index)
			case .Acct_Path:    if setup_ui.edit != SETUP_EDIT_PATH do edit_begin(SETUP_EDIT_PATH)
			case .Acct_Add:     add_typed()
			case .Acct_Pick:    action_run("setup_pick_account")
			case .Agent_Action, .Agent_Copy, .Agent_Close:
				if msg := harness_step_click(h); msg != "" do set_str(&setup_ui.err, msg)
				else do set_str(&setup_ui.err, "")
			}
		}
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

// Typing in the accounts step's label or path field (the sheet holds the keyboard): Enter keeps
// it (the path: adds it), Esc drops a label's edit (the path: leaves the field), Tab leaves it.
@(private = "file")
field_event :: proc(e: ^sapp.Event) -> bool {
	u := &setup_ui
	f := &u.field
	shift := e.modifiers & sapp.MODIFIER_SHIFT != 0
	cmd := e.modifiers & sapp.MODIFIER_SUPER != 0
	alt := e.modifiers & sapp.MODIFIER_ALT != 0
	#partial switch e.type {
	case .KEY_DOWN:
		if cmd && e.key_code == .Q do return false
		app.redraw = true
		// keys that end the edit: their CHAR must not reach the field (a typed key's CHAR must)
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER, .ESCAPE, .TAB: app.key_taken = true
		}
		if cmd {
			#partial switch e.key_code {
			case .A: tf_select_all(f)
			case .C: if s := tf_selected_text(f); s != "" do core.platform.set_clipboard(s)
			case .X:
				if s := tf_selected_text(f); s != "" {
					core.platform.set_clipboard(s)
					tf_backspace(f)
				}
			case .LEFT:      tf_home(f, shift)
			case .RIGHT:     tf_end(f, shift)
			case .BACKSPACE: tf_delete_to_start(f)
			}
			return true
		}
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER:
			if u.edit == SETUP_EDIT_PATH do add_typed()
			else do edit_end(true)
		case .ESCAPE:     edit_end(false)
		case .TAB:        edit_end(true)
		case .BACKSPACE:  if alt do tf_delete_word_left(f); else do tf_backspace(f)
		case .DELETE:     tf_delete(f)
		case .LEFT:       if alt do tf_word_left(f, shift); else do tf_move(f, -1, shift)
		case .RIGHT:      if alt do tf_word_right(f, shift); else do tf_move(f, 1, shift)
		case .HOME, .UP:  tf_home(f, shift)
		case .END, .DOWN: tf_end(f, shift)
		}
		return true
	case .CHAR:
		if !cmd && e.char_code >= 0x20 && e.char_code != 0x7f {
			if r, ok := utf16_unit(&app_surrogate, e.char_code); ok {
				tf_insert(f, utf8_string(r))
				app.redraw = true
			}
		}
		return true
	case .CLIPBOARD_PASTED:
		tf_insert(f, core.one_line(core.clipboard_text(), context.temp_allocator))
		app.redraw = true
		return true
	case .KEY_UP:
		return true
	}
	return false
}

