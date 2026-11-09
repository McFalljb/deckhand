package main

// The harness checklist on screen (harness_manifest.odin, harness_install.odin):
//
//   - The setup sheet's first step, "Your coding agents": one card per harness. A harness that is
//     not installed is one collapsed line (Not installed, why, the exact install command, Install),
//     so a one-harness user sees no clutter for the other. An installed one lists Deckhand's own
//     integration ("built in") and the recommended third-party items (or "nothing else needed").
//     Every Install or Update shows its exact command before the click; a layout Deckhand does not
//     run (nix, mise, unknown, an npm folder that needs sudo) gets Copy instead. A run shows below
//     the cards in a terminal: its output live, how it ended, Close.
//   - The Settings tab's Coding agents group: the same states as rows; Install… and Update… open the
//     sheet at that step (one place runs installs).

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

// Terminal rows the run's output gets on the sheet.
HARNESS_TERM_ROWS :: 8

@(private = "file")
term_laid_out: bool // the sheet declared the run's terminal this frame

// The run's terminal rectangle in the last layout (framebuffer px).
harness_term_rect :: proc() -> (x, y, w, h: f32, ok: bool) {
	if !term_laid_out || !setup_open() do return
	d := clay.GetElementData(clay.ID("setup_term"))
	if !d.found || d.boundingBox.width < 1 || d.boundingBox.height < 1 do return
	b := d.boundingBox
	// only while the sheet's body shows all of it (it scrolls): never drawn over the header or footer
	body := clay.GetElementData(clay.ID("setup_body"))
	if !body.found || b.y < body.boundingBox.y - 0.5 || b.y + b.height > body.boundingBox.y + body.boundingBox.height + 0.5 do return
	return b.x, b.y, b.width, b.height, true
}

// Frame upkeep (main.odin, after the layout): the run's terminal follows its place on the sheet.
harness_term_layout :: proc() {
	if core.harness_run_term() == nil do return
	if x, y, w, h, ok := harness_term_rect(); ok do term_fit_rect(core.harness_run.term_id, x, y, w, h)
}

// Drawn above the sheet (main.odin, after the overlays).
harness_term_draw :: proc() {
	t := harness_view()
	if t == nil do return
	if _, _, _, _, ok := harness_term_rect(); ok do term_draw(t)
}

@(private = "file")
item_mark :: proc(it: core.Harness_Item) -> (string, core.Rgba) {
	th := theme()
	switch it.state {
	case .Ok, .Built_In:            return "✓", th.done
	case .Too_Old, .Not_Loaded:     return "!", th.waiting
	case .Missing, .Needs_Harness: return "○", th.text_muted
	case .Unchecked:               return "?", th.waiting
	}
	return "", th.text_muted
}

@(private = "file")
item_running :: proc(it: core.Harness_Item) -> bool {
	return core.harness_run.status == .Running && core.harness_run.item == core.HARNESS_MANIFEST[it.row].id
}

// Its button: Install, Update, Copy (shown only), or none.
@(private = "file")
item_button :: proc(it: core.Harness_Item) -> (label: string, what: Setup_Hit_Kind, ok: bool) {
	if it.action == .None do return "", .Agent_Action, false
	if !it.runnable do return it.command != "" ? "Copy" : "", .Agent_Copy, it.command != ""
	if item_running(it) do return "Running…", .Agent_Action, true
	return it.action == .Install ? "Install" : "Update", .Agent_Action, true
}

// One line of a card: a mark, the name, what it is now, a button; under it the reason or the note,
// and the command an action runs.
@(private = "file")
item_line :: proc(it: core.Harness_Item, w: f32, head: bool) {
	th := theme()
	r := core.HARNESS_MANIFEST[it.row]
	mark, mcol := item_mark(it)
	label, what, has := item_button(it)
	bw := has ? text_w(label, head ? WEIGHT_BOLD : WEIGHT_REGULAR) + px(2 * SP_3 + SP_2) : 0
	room := w - px(SP_3 + SP_1 + SP_2) - bw
	if clay.UI(clay.ID("agent_item_row", u32(it.row)))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Top}}}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_3 + SP_1)), clay.SizingFit()}, padding = {0, 0, 2, 0}}}) {
			if head do icon(core.harness_icon(r.harness), th.text, HARNESS_ICON_SIZE)
			else do clay.TextDynamic(mark, txt(mcol))
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = 2}}) {
			status := core.harness_item_text(it)
			if head && it.state == .Ok do status = fmt.tprintf("%s %s", mark, status)
			name_w := min(text_w(r.name, head ? WEIGHT_BOLD : WEIGHT_REGULAR), room * 0.55)
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2)}}) {
				clay.TextDynamic(clip(r.name, name_w, head ? WEIGHT_BOLD : WEIGHT_REGULAR), txt(th.text, head ? WEIGHT_BOLD : WEIGHT_REGULAR))
				scol := th.text_secondary
				#partial switch it.state {
				case .Too_Old, .Not_Loaded, .Unchecked: scol = th.waiting
				case .Missing, .Needs_Harness: scol = th.text_muted
				case .Ok, .Built_In: if head do scol = th.done
				}
				clay.TextDynamic(clip(status, room - name_w - px(SP_2), FONT_UI_SMALL), txt(scol, FONT_UI_SMALL))
			}
			sub := r.why
			if it.note != "" && it.state != .Not_Loaded do sub = it.note
			if sub != "" {
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {
					cfg := txt(th.text_muted, FONT_UI_SMALL)
					cfg.wrapMode = .Words
					clay.TextDynamic(sub, cfg)
				}
			}
			if it.action != .None {
				// the exact command, whole (wrapped, never cut: it is what the click runs)
				cmd := it.command != "" ? fmt.tprintf("$ %s", it.command) : "with the package manager that installed it"
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {
					cfg := txt(it.runnable ? th.text_secondary : th.text_muted, FONT_MONO)
					cfg.wrapMode = .Words
					clay.TextDynamic(break_long_words(cmd, room, .Mono), cfg)
				}
			}
		}
		if has {
			hov := ui_hover == Hit(Hit_Setup{what = what, index = it.row})
			button(clay.ID(what == .Agent_Copy ? "agent_item_copy" : "agent_item_btn", u32(it.row)), label, what == .Agent_Action && head && !item_running(it), hov)
		}
	}
}

// Text as shown in room: a word wider than room (an absolute path) breaks after a "/" (or anywhere,
// if it must) onto the next line, so it wraps inside the card instead of widening it. Display only:
// Copy, the tooltip and the run get the command whole.
break_long_words :: proc(s: string, room: f32, kind: Font_Kind) -> string {
	if room <= 0 do return s
	b := strings.builder_make(context.temp_allocator)
	for word, i in strings.split(s, " ", context.temp_allocator) {
		if i > 0 do strings.write_byte(&b, ' ')
		if text_width(word, kind) <= room {
			strings.write_string(&b, word)
			continue
		}
		line := 0 // where the current line starts in word
		cut := -1 // the last place it may break (after a "/")
		for j := 0; j < len(word); {
			_, n := utf8.decode_rune_in_string(word[j:])
			if text_width(word[line:j + n], kind) > room && j > line {
				at := cut > line ? cut : j
				strings.write_string(&b, word[line:at])
				strings.write_byte(&b, '\n')
				line, cut = at, -1
				continue
			}
			if word[j] == '/' do cut = j + 1
			j += n
		}
		strings.write_string(&b, word[line:])
	}
	return strings.to_string(b)
}

// One harness's card.
@(private = "file")
harness_card :: proc(h: core.Harness, w: f32) {
	th := theme()
	head: core.Harness_Item
	found := false
	for it in core.harness_items do if core.HARNESS_MANIFEST[it.row].harness == h && core.HARNESS_MANIFEST[it.row].kind == .Harness {
		head, found = it, true
	}
	if !found do return
	if clay.UI(clay.ID("agent_item_card", u32(h)))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = {pu(SP_2), pu(SP_2), pu(SP_2), pu(SP_2)}, childGap = pu(SP_2)},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(head.state == .Too_Old ? th.waiting : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
	}) {
		inner := w - px(2 * SP_2)
		item_line(head, inner, true)
		if head.state == .Missing do return // collapsed: a harness the user may not use
		rec := 0
		for it in core.harness_items {
			r := core.HARNESS_MANIFEST[it.row]
			if r.harness != h || r.kind == .Harness do continue
			if r.need == .Recommended {
				if rec == 0 do sub_head("Recommended")
				rec += 1
			}
			item_line(it, inner, false)
		}
		if rec == 0 do sub_head("Recommended: nothing else needed")
	}
}

@(private = "file")
sub_head :: proc(text: string) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_3 + SP_1 + SP_2), 0, 2, 0}}}) {
		clay.TextDynamic(text, txt(th.text_muted, FONT_UI_SMALL))
	}
}

// The run: what runs, how it ended, Close; then its terminal.
@(private = "file")
run_block :: proc(w: f32) {
	th := theme()
	t := core.harness_run_term()
	if core.harness_run.status == .None || t == nil do return
	r, _ := core.harness_row(core.harness_run.item)
	verb := core.harness_run.action == .Update ? "Updating" : "Installing"
	head: string
	col := th.text_secondary
	switch core.harness_run.status {
	case .Running: head = fmt.tprintf("%s %s… (⌃C stops it)", verb, r.name)
	case .Done:
		head = fmt.tprintf("%s %s: finished, checked again", verb, r.name)
		col = th.done
	case .Failed:
		how := core.exit_text(core.harness_run.exit)
		head = fmt.tprintf("%s %s failed%s", verb, r.name, how != "" ? fmt.tprintf(" (%s)", how) : "")
		col = th.error
	case .None:
	}
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		cw := core.harness_run.status != .Running ? text_w("Close", WEIGHT_REGULAR) + px(2 * SP_3 + SP_2) : 0
		clay.TextDynamic(clip(head, w - cw, WEIGHT_BOLD), txt(col, WEIGHT_BOLD))
		spacer()
		if core.harness_run.status != .Running do button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Agent_Close)), "Close", false, ui_hover == Hit(Hit_Setup{what = .Agent_Close}))
	}
	hgt := f32(HARNESS_TERM_ROWS) * font.cell_h + 2 * term_pad()
	if clay.UI(clay.ID("setup_term"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(hgt)}},
		backgroundColor = cc(core.term_colors().bg),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {}
	term_laid_out = true
}

// The step's body (ui_setup.odin).
harness_step_body :: proc(w: f32) {
	th := theme()
	term_laid_out = false
	if len(core.harness_items) == 0 do core.harness_checklist_refresh()
	core.harness_checklist_tick()
	installed := 0
	for h in core.Harness do if core.harness_item_installed(h) do installed += 1
	intro := "Deckhand runs pi and Claude Code: you need at least one. Its own parts ship inside the app. Install and Update run the command shown, in a terminal here, only when you click; nothing already there is installed again."
	if installed == 0 do intro = "No coding agent is installed yet: install pi, Claude Code, or both. Deckhand's own parts ship inside the app. Install runs the command shown, in a terminal here, only when you click."
	cfg := txt(th.text_secondary, FONT_UI_SMALL)
	cfg.wrapMode = .Words
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_1), pu(SP_1), 2, 2}}}) do clay.TextDynamic(intro, cfg)
	// installed harnesses first: the one the user has is what matters
	for pass in 0 ..< 2 do for h in core.Harness do if core.harness_item_installed(h) == (pass == 0) do harness_card(h, w)
	run_block(w)
}

// The step's hits (setup_hit).
harness_step_hit :: proc() -> Hit {
	for it in core.harness_items {
		if clay.PointerOver(clay.ID("agent_item_btn", u32(it.row))) do return Hit_Setup{what = .Agent_Action, index = it.row}
		if clay.PointerOver(clay.ID("agent_item_copy", u32(it.row))) do return Hit_Setup{what = .Agent_Copy, index = it.row}
	}
	return nil
}

harness_step_tip :: proc(h: Hit_Setup) -> string {
	if h.index < 0 || h.index >= len(core.HARNESS_MANIFEST) do return ""
	it := core.harness_item(core.HARNESS_MANIFEST[h.index].id)
	if it == nil do return ""
	#partial switch h.what {
	case .Agent_Action:
		if item_running(it^) do return "Running in the terminal below"
		return fmt.tprintf("Run `%s` in a terminal here", it.command)
	case .Agent_Copy:
		return fmt.tprintf("Copy `%s`: Deckhand does not run updates for %s installs", it.command, core.INSTALL_LAYOUT_NAMES[it.layout])
	}
	return ""
}

// A click on the step (setup_event): Install/Update runs, Copy copies, Close drops the output.
// "" = done; else what to say.
harness_step_click :: proc(h: Hit_Setup) -> string {
	#partial switch h.what {
	case .Agent_Action:
		if h.index < 0 || h.index >= len(core.HARNESS_MANIFEST) do return ""
		if core.harness_run.status == .Running && core.harness_run.item == core.HARNESS_MANIFEST[h.index].id do return ""
		return core.harness_run_start(core.HARNESS_MANIFEST[h.index].id)
	case .Agent_Copy:
		if h.index < 0 || h.index >= len(core.HARNESS_MANIFEST) do return ""
		if it := core.harness_item(core.HARNESS_MANIFEST[h.index].id); it != nil && it.command != "" {
			if core.platform.set_clipboard != nil do core.platform.set_clipboard(it.command)
			toast_show(fmt.tprintf("Copied: %s", it.command))
		}
	case .Agent_Close:
		core.harness_run_dismiss()
	}
	return ""
}

// Keys and the wheel while a run's terminal shows on the sheet: the keyboard is the terminal's
// while it runs (⌃C stops it; ⌘Q still quits). True if taken.
harness_step_event :: proc(e: ^sapp.Event) -> bool {
	t := harness_view()
	if t == nil do return false
	#partial switch e.type {
	case .MOUSE_SCROLL:
		if x, y, w, h, ok := harness_term_rect(); ok && e.mouse_x >= x && e.mouse_x < x + w && e.mouse_y >= y && e.mouse_y < y + h {
			term_scroll(t, e)
			app.redraw = true
			return true
		}
		return false
	}
	_, _, _, _, visible := harness_term_rect()
	#partial switch e.type {
	case .KEY_DOWN, .KEY_UP, .CHAR:
	case:
		return false
	}
	if !harness_run_takes_key(e, visible, time.tick_now()) {
		// the habitual Enter right after the click, or a hidden terminal: the run gets nothing,
		// and the sheet's own keys (Next, Back) stay held while it runs
		held := core.harness_run.status == .Running && e.modifiers & sapp.MODIFIER_SUPER == 0
		if held && e.type == .KEY_DOWN do app.key_taken = true
		return held
	}
	#partial switch e.type {
	case .KEY_DOWN:
		term_key_down(t, e)
		app.key_taken = true
	case .KEY_UP:
		term_key_up(t, e)
	case .CHAR:
		term_char(t, e)
	case:
		return false
	}
	app.redraw = true
	return true
}

// ---- the Settings tab's Coding agents group ----

// A Coding agents row's button: the sheet's checklist. False: not such a row.
harness_settings_button :: proc(path: string) -> bool {
	if !strings.has_prefix(path, core.HARNESS_SETTINGS_ROW) do return false
	ui_do(core.Setup_Sheet{open = true})
	return true
}

// A Coding agents row's tooltip ("" = not such a row).
harness_settings_tip :: proc(path: string, on_button: bool) -> string {
	if !strings.has_prefix(path, core.HARNESS_SETTINGS_ROW) do return ""
	it := core.harness_item(path[len(core.HARNESS_SETTINGS_ROW):])
	if it == nil do return ""
	r := core.HARNESS_MANIFEST[it.row]
	if on_button do return fmt.tprintf("Open the coding agents checklist: `%s`", it.command)
	return fmt.tprintf("%s: %s. %s", r.name, core.harness_item_text(it^), r.why)
}

// ---- the New session picker and the install run's keys (moved from harness.odin and
// harness_install.odin: the window's) ----

// The picker's rows: a note saying what it starts, then the choices (temp).
new_session_menu_items :: proc(t: core.Menu_New_Session, items: ^[dynamic]core.Menu_Item) {
	p := core.find_project(t.project_id)
	if p == nil do return
	what := p.group == .Chats ? "New chat with…" : t.cwd != "" ? fmt.tprintf("New session in %s with…", filepath.base(t.cwd)) : fmt.tprintf("New session in %s with…", core.project_display(p^))
	append(items, core.Menu_Item{label = what, note = true})
	append(items, ..core.new_session_choices(p, t.cwd))
}

// Where the picker opens without a click (a shortcut, the palette, the menu bar): under the top
// bar, centred (framebuffer px).
new_session_anchor :: proc() -> [2]f32 {
	return {max((f32(sapp.width()) - px(MENU_W)) / 2, 0), px(TAB_STRIP_H + SP_4)}
}

// The user's "New session" in project pid (in cwd, a checkout of it; "" = its folder), see the top.
// at: where the picker opens (nil = new_session_anchor).
new_session_ui :: proc(pid: u64, cwd := "", at: Maybe([2]f32) = nil) {
	p := core.find_project(pid)
	if p == nil do return
	// looked up again (stat only): a harness installed since is offered
	core.pi_installed_now()
	core.claude_installed_now()
	items := core.new_session_choices(p, cwd)
	switch len(items) {
	case 0:
		toast_show(core.NO_HARNESS, err = true)
	case 1:
		core.harness_used(items[0].cmd)
		ui_do_menu(items[0].cmd, p.group == .Chats ? "New chat" : "New session")
	case:
		menu_open(core.Menu_New_Session{project_id = pid, cwd = cwd}, at.? or_else new_session_anchor())
		rows := menu_items()
		for it, i in rows do if !it.note && !it.sep {
			menu.selected = i // the first choice: the last used
			break
		}
	}
}

// A number key in the picker: its Nth choice (1-9). False: not the picker, or no such row.
new_session_number :: proc(key: sapp.Keycode, mods: u32) -> bool {
	if _, ok := menu.target.(core.Menu_New_Session); !ok do return false
	if mods & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT) != 0 do return false // ⌘1…: not a pick
	n := int(key) - int(sapp.Keycode._1)
	if key >= .KP_1 && key <= .KP_9 do n = int(key) - int(sapp.Keycode.KP_1)
	if n < 0 || n > 8 do return false
	k := 0
	for it, i in menu_items() {
		if it.note || it.sep do continue
		if k == n {
			menu_run(i)
			return true
		}
		k += 1
	}
	return false
}

// Whether a key reaches the run's terminal: only while it runs and shows on the sheet (visible),
// never ⌘ keys (⌘Q quits), and not Enter during HARNESS_ENTER_GRACE after the click.
harness_run_takes_key :: proc(e: ^sapp.Event, visible: bool, now: time.Tick) -> bool {
	if core.harness_run.status != .Running || !visible do return false
	if e.modifiers & sapp.MODIFIER_SUPER != 0 do return false
	enter := (e.type == .KEY_DOWN || e.type == .KEY_UP) && (e.key_code == .ENTER || e.key_code == .KP_ENTER) || e.type == .CHAR && (e.char_code == '\r' || e.char_code == '\n')
	if enter && time.tick_diff(core.harness_run.started, now) < core.HARNESS_ENTER_GRACE do return false
	return true
}

// While an install runs on the setup sheet the keyboard stays there (its terminal, ⌃C): whatever
// moved it (a menu, a command) is undone on the next frame, on the run's step.
harness_run_keep_sheet :: proc() {
	if core.harness_run.status != .Running do return
	if setup_ui.step != 0 do setup_ui.step = 0 // the Agents step, where the run shows
	if state.focus_widget == "setup" do return
	client_call(core.Focus_Take{widget = "setup"}, .Internal)
}
