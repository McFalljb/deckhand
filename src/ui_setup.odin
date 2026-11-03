package main

// The first-run sheet (focus widget "setup"; folders.odin): three steps over
// the window.
//
//   1. The main folder: use the notes folder found (PI_KIT_NOTES_DIR, else
//      a folder named in pi's global AGENTS.md that has sessions/ or a
//      README.md), create ~/pi-desk, or choose another folder.
//   2. Chats: inside the main folder (chats/) or a separate folder.
//   3. The layout as a small tree, then Done.
//
// It opens by itself once when no main folder is set (setup_due; test mode
// only with PI_DESK_FIRST_RUN=1), and from "Set up pi-desk…" (the palette,
// the Jobs tab, Atlas's drawer, the Settings tab's Folders group). Skip for
// now and Done both close it for good (Setup_Sheet{open = false}); Done
// sends Set_Folder (chats), then Set_Home_Dir{setup = true}, which closes it
// only when it worked (else the sheet shows why). Enter: Next / Done; Esc:
// Back, or Skip on step 1; ↑↓: the choice.

import "core:fmt"
import "core:os"
import "core:strings"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

Setup_Main :: enum u8 {
	Detected, // the notes folder found
	Create, // ~/pi-desk
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
}
setup_ui: Setup_UI

Setup_Hit_Kind :: enum u8 {
	Option, // index: the option
	Skip,
	Back,
	Next, // Next, or Done on the last step
	Choose_Chats, // the separate folder's Choose…
}
Hit_Setup :: struct {
	what:  Setup_Hit_Kind,
	index: int,
}

SETUP_STEPS :: 3

setup_open :: proc() -> bool {return state.focus_widget == "setup"}

@(private = "file")
set_str :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

// The sheet starts over: step 1, the detected folder (or ~/pi-desk), chats
// pre-selected from what is there.
setup_begin :: proc() {
	u := &setup_ui
	u.step = 0
	u.touched = false
	set_str(&u.err, "")
	p, why := setup_detect()
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
		c := chats_project()
		if c != nil && c.cwd == real_path(home_chats) && len(state.chats) > 0 do u.separate = true
	}
}

// PI_KIT_NOTES_DIR arrived from the login shell (jobs.odin): found again,
// unless the user chose already.
setup_detect_again :: proc() {
	if !setup_open() || setup_ui.touched do return
	p, why := setup_detect()
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
	case .Create:   return fmt.tprintf("%s/pi-desk", os.get_env("HOME", context.temp_allocator))
	case .Other:    return setup_ui.other
	}
	return ""
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
	switch setup_ui.step {
	case 0: return len(setup_options())
	case 1: return 2
	}
	return 0
}

@(private = "file")
option_selected :: proc(i: int) -> bool {
	switch setup_ui.step {
	case 0: return setup_options()[i] == setup_ui.main
	case 1: return (i == 1) == setup_ui.separate
	}
	return false
}

@(private = "file")
option_pick :: proc(i: int) {
	u := &setup_ui
	u.touched = true
	switch u.step {
	case 0:
		opts := setup_options()
		if i < 0 || i >= len(opts) do return
		u.main = opts[i]
		if u.main == .Other && u.other == "" do action_run("setup_pick_main")
	case 1:
		u.separate = i == 1
	}
}

// Next, or Done on the last step.
@(private = "file")
setup_next :: proc() {
	u := &setup_ui
	if u.step == 0 && setup_main_path() == "" {
		action_run("setup_pick_main") // Choose another folder… with nothing picked yet
		return
	}
	if u.step < SETUP_STEPS - 1 {
		u.step += 1
		return
	}
	main := setup_main_path()
	set_str(&u.err, "")
	// chats first: the main folder then makes chats/ only when chats live there
	if u.separate {
		if !os.is_dir(u.chats) do os.make_directory_all(u.chats) // setup is the user's explicit choice
		ui_do(Set_Folder{kind = .Chats, path = u.chats})
	} else do ui_do(Set_Folder{kind = .Chats, path = ""})
	ui_do(Set_Home_Dir{path = main, create = u.main == .Create, setup = true}) // closes the sheet only if it worked
}

// Done's Set_Home_Dir failed (folders.odin): the sheet stays open and says why.
setup_failed :: proc(why: string) {
	set_str(&setup_ui.err, fmt.tprintf("Could not use %s: %s. Choose another folder.", fs_display(setup_main_path()), why))
}

@(private = "file")
setup_back :: proc() {
	if setup_ui.step > 0 do setup_ui.step -= 1
	set_str(&setup_ui.err, "")
}

// ---- layout ----

@(private = "file")
para :: proc(text: string, col: Rgba, font: u16 = FONT_UI_SMALL) {
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
		border = {color = cc(sel ? th.accent : th.border), width = clay.BorderOutside(pu(BORDER_W))},
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
			border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
		}) {
			titles := [SETUP_STEPS]string{"Where should pi-desk keep your files?", "Where should chats run?", "Your folders"}
			step := fmt.tprintf("Step %d of %d", u.step + 1, SETUP_STEPS)
			if clay.UI(clay.ID("setup_head"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_1), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				sw := text_w(step, FONT_UI_SMALL)
				clay.TextDynamic(clip(titles[u.step], box_w - px(2 * SP_3 + 2 * SP_1 + SP_2) - sw, WEIGHT_BOLD), txt(th.text, WEIGHT_BOLD))
				spacer()
				clay.TextDynamic(step, txt(th.text_muted, FONT_UI_SMALL))
			}
			if clay.UI(clay.ID("setup_body"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = pu(SP_2)},
			}) {
				switch u.step {
				case 0:
					para("One main folder holds your session notes, jobs, memory, Atlas's prompt and chats. You can move any of them later (Settings tab, Folders).", th.text_secondary)
					for o, i in setup_options() {
						switch o {
						case .Detected:
							option_row(i, "Use your notes folder", {fs_display(u.detected), fmt.tprintf("Found: %s", u.why)}, room)
						case .Create:
							p := setup_main_path()
							if u.main != .Create do p = fmt.tprintf("%s/pi-desk", os.get_env("HOME", context.temp_allocator))
							option_row(i, os.is_dir(p) ? "Use ~/pi-desk" : "Create ~/pi-desk", {os.is_dir(p) ? "It is there already: missing subfolders are added" : "A new folder in your home folder"}, room)
						case .Other:
							option_row(i, "Choose another folder…", {u.other != "" ? fs_display(u.other) : "Any folder: missing subfolders are added, nothing else is touched"}, room)
						}
					}
				case 1:
					para("Chats run pi in a folder outside any project: files pi creates in chats land in that folder.", th.text_secondary)
					main := setup_main_path()
					option_row(0, "Inside the main folder (chats/)", {fmt.tprintf("%s/chats", fs_display(main))}, room)
					option_row(1, "Separate folder", {fs_display(u.chats)}, room)
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), 0, 0, 0}}}) {
						button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Choose_Chats)), "Choose separate folder…", false, ui_hover == Hit(Hit_Setup{what = .Choose_Chats}))
					}
				case 2:
					main := setup_main_path()
					tree_line(0, fmt.tprintf("%s/", fs_display(main)), "the main folder", box_w - px(2 * SP_3))
					for k in Folder_Kind {
						if k == .Chats && u.separate {
							tree_line(1, "chats →", fmt.tprintf("%s (separate)", fs_display(u.chats)), box_w - px(2 * SP_3))
						} else do tree_line(1, fmt.tprintf("%s/", FOLDER_NAMES[k]), FOLDER_DOES[k], box_w - px(2 * SP_3))
						if k == .Chats do tree_line(2, "AGENTS.md", "chat instructions: talk, explain, look things up", box_w - px(2 * SP_3))
					}
					para("Missing folders are made, empty. Nothing already there is moved or changed.", th.text_secondary)
					if v := notes_env_user(); v != "" do para(fmt.tprintf("Your PI_KIT_NOTES_DIR (%s) stays as it is: pi-kit's notes go there.", fs_display(v)), th.text_secondary)
				}
				if u.err != "" do para(u.err, th.error)
			}
			if clay.UI(clay.ID("setup_foot"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {0, 0, pu(SP_1), 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
				button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Skip)), "Skip for now", false, ui_hover == Hit(Hit_Setup{what = .Skip}))
				spacer()
				if u.step > 0 do button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Back)), "Back", false, ui_hover == Hit(Hit_Setup{what = .Back}))
				button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Next)), u.step == SETUP_STEPS - 1 ? "Done" : "Next", true, ui_hover == Hit(Hit_Setup{what = .Next}))
			}
		}
	}
}

setup_hit :: proc() -> Hit {
	for k in Setup_Hit_Kind do if k != .Option && clay.PointerOver(clay.ID("setupbtn", u32(k))) do return Hit_Setup{what = k}
	for i in 0 ..< option_count() do if clay.PointerOver(clay.ID("setupopt", u32(i))) do return Hit_Setup{what = .Option, index = i}
	return nil
}

setup_tip :: proc(h: Hit_Setup) -> (string, string) {
	switch h.what {
	case .Skip:         return "Jobs stay off until a main folder is set (Set up pi-desk…, in the palette or the Settings tab)", "Esc"
	case .Back:         return "The previous step", "Esc"
	case .Next:         return setup_ui.step == SETUP_STEPS - 1 ? "Make the folders and close" : "The next step", "Enter"
	case .Choose_Chats: return "Pick the folder chats run in", ""
	case .Option:       return "", "↑↓"
	}
	return "", ""
}

// Input while the sheet shows: it takes everything but ⌘Q.
setup_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .KEY_DOWN:
		if e.modifiers & sapp.MODIFIER_SUPER != 0 && e.key_code == .Q do return false
		#partial switch e.key_code {
		case .ENTER, .KP_ENTER: setup_next()
		case .ESCAPE:
			if setup_ui.step > 0 do setup_back()
			else do ui_do(Setup_Sheet{open = false})
		case .UP, .DOWN:
			n := option_count()
			if n > 0 {
				cur := 0
				for i in 0 ..< n do if option_selected(i) do cur = i
				nxt := clamp(cur + (e.key_code == .DOWN ? 1 : -1), 0, n - 1)
				if setup_ui.step == 0 && setup_options()[nxt] == .Other && setup_ui.other == "" {
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
		if ok && e.mouse_button == .LEFT {
			switch h.what {
			case .Option:       option_pick(h.index)
			case .Skip:         ui_do(Setup_Sheet{open = false})
			case .Back:         setup_back()
			case .Next:         setup_next()
			case .Choose_Chats: action_run("setup_pick_chats")
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
