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
import "core:strings"
import "core:time"
import "core:unicode/utf8"
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
	t := harness_run_term()
	if t == nil do return
	if x, y, w, h, ok := harness_term_rect(); ok do term_set_rect(t, x, y, w, h)
}

// Drawn above the sheet (main.odin, after the overlays).
harness_term_draw :: proc() {
	t := harness_run_term()
	if t == nil do return
	if _, _, _, _, ok := harness_term_rect(); ok do term_draw(t)
}

// What an item says about itself on the sheet and in Settings.
harness_item_text :: proc(it: Harness_Item) -> string {
	r := HARNESS_MANIFEST[it.row]
	switch it.state {
	case .Missing:       return "Not installed"
	case .Needs_Harness: return fmt.tprintf("Needs %s first", HARNESS_MANIFEST[harness_first_row(r.harness)].name)
	case .Built_In:      return "Built in"
	case .Unchecked:     return "Found, version not checked"
	case .Not_Loaded:    return it.note
	case .Too_Old:       return fmt.tprintf("%s, older than %s", it.version != "" ? it.version : "an old version", r.min_version)
	case .Ok:
		v := it.version != "" ? it.version : "version unknown"
		if r.kind == .Harness && it.where_ != "" do return fmt.tprintf("%s · %s", v, INSTALL_LAYOUT_NAMES[it.layout])
		return v
	}
	return ""
}

@(private = "file")
item_mark :: proc(it: Harness_Item) -> (string, Rgba) {
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
item_running :: proc(it: Harness_Item) -> bool {
	return harness_run.status == .Running && harness_run.item == HARNESS_MANIFEST[it.row].id
}

// Its button: Install, Update, Copy (shown only), or none.
@(private = "file")
item_button :: proc(it: Harness_Item) -> (label: string, what: Setup_Hit_Kind, ok: bool) {
	if it.action == .None do return "", .Agent_Action, false
	if !it.runnable do return it.command != "" ? "Copy" : "", .Agent_Copy, it.command != ""
	if item_running(it) do return "Running…", .Agent_Action, true
	return it.action == .Install ? "Install" : "Update", .Agent_Action, true
}

// One line of a card: a mark, the name, what it is now, a button; under it the reason or the note,
// and the command an action runs.
@(private = "file")
item_line :: proc(it: Harness_Item, w: f32, head: bool) {
	th := theme()
	r := HARNESS_MANIFEST[it.row]
	mark, mcol := item_mark(it)
	label, what, has := item_button(it)
	bw := has ? text_w(label, head ? WEIGHT_BOLD : WEIGHT_REGULAR) + px(2 * SP_3 + SP_2) : 0
	room := w - px(SP_3 + SP_1 + SP_2) - bw
	if clay.UI(clay.ID("agent_item_row", u32(it.row)))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Top}}}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_3 + SP_1)), clay.SizingFit()}, padding = {0, 0, 2, 0}}}) {
			if head do icon(harness_icon(r.harness), th.text, HARNESS_ICON_SIZE)
			else do clay.TextDynamic(mark, txt(mcol))
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = 2}}) {
			status := harness_item_text(it)
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
harness_card :: proc(h: Harness, w: f32) {
	th := theme()
	head: Harness_Item
	found := false
	for it in harness_items do if HARNESS_MANIFEST[it.row].harness == h && HARNESS_MANIFEST[it.row].kind == .Harness {
		head, found = it, true
	}
	if !found do return
	if clay.UI(clay.ID("agent_item_card", u32(h)))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = {pu(SP_2), pu(SP_2), pu(SP_2), pu(SP_2)}, childGap = pu(SP_2)},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(head.state == .Too_Old ? th.waiting : th.border), width = clay.BorderOutside(pu(BORDER_W))},
	}) {
		inner := w - px(2 * SP_2)
		item_line(head, inner, true)
		if head.state == .Missing do return // collapsed: a harness the user may not use
		rec := 0
		for it in harness_items {
			r := HARNESS_MANIFEST[it.row]
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
	t := harness_run_term()
	if harness_run.status == .None || t == nil do return
	r, _ := harness_row(harness_run.item)
	verb := harness_run.action == .Update ? "Updating" : "Installing"
	head: string
	col := th.text_secondary
	switch harness_run.status {
	case .Running: head = fmt.tprintf("%s %s… (⌃C stops it)", verb, r.name)
	case .Done:
		head = fmt.tprintf("%s %s: finished, checked again", verb, r.name)
		col = th.done
	case .Failed:
		how := exit_text(harness_run.exit)
		head = fmt.tprintf("%s %s failed%s", verb, r.name, how != "" ? fmt.tprintf(" (%s)", how) : "")
		col = th.error
	case .None:
	}
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		cw := harness_run.status != .Running ? text_w("Close", WEIGHT_REGULAR) + px(2 * SP_3 + SP_2) : 0
		clay.TextDynamic(clip(head, w - cw, WEIGHT_BOLD), txt(col, WEIGHT_BOLD))
		spacer()
		if harness_run.status != .Running do button(clay.ID("setupbtn", u32(Setup_Hit_Kind.Agent_Close)), "Close", false, ui_hover == Hit(Hit_Setup{what = .Agent_Close}))
	}
	hgt := f32(HARNESS_TERM_ROWS) * font.cell_h + 2 * term_pad()
	if clay.UI(clay.ID("setup_term"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(hgt)}},
		backgroundColor = cc(th.term_bg),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {}
	term_laid_out = true
}

// The step's body (ui_setup.odin).
harness_step_body :: proc(w: f32) {
	th := theme()
	term_laid_out = false
	if len(harness_items) == 0 do harness_checklist_refresh()
	harness_checklist_tick()
	installed := 0
	for h in Harness do if harness_item_installed(h) do installed += 1
	intro := "Deckhand runs pi and Claude Code: you need at least one. Its own parts ship inside the app. Install and Update run the command shown, in a terminal here, only when you click; nothing already there is installed again."
	if installed == 0 do intro = "No coding agent is installed yet: install pi, Claude Code, or both. Deckhand's own parts ship inside the app. Install runs the command shown, in a terminal here, only when you click."
	cfg := txt(th.text_secondary, FONT_UI_SMALL)
	cfg.wrapMode = .Words
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_1), pu(SP_1), 2, 2}}}) do clay.TextDynamic(intro, cfg)
	// installed harnesses first: the one the user has is what matters
	for pass in 0 ..< 2 do for h in Harness do if harness_item_installed(h) == (pass == 0) do harness_card(h, w)
	run_block(w)
}

// The step's hits (setup_hit).
harness_step_hit :: proc() -> Hit {
	for it in harness_items {
		if clay.PointerOver(clay.ID("agent_item_btn", u32(it.row))) do return Hit_Setup{what = .Agent_Action, index = it.row}
		if clay.PointerOver(clay.ID("agent_item_copy", u32(it.row))) do return Hit_Setup{what = .Agent_Copy, index = it.row}
	}
	return nil
}

harness_step_tip :: proc(h: Hit_Setup) -> string {
	if h.index < 0 || h.index >= len(HARNESS_MANIFEST) do return ""
	it := harness_item(HARNESS_MANIFEST[h.index].id)
	if it == nil do return ""
	#partial switch h.what {
	case .Agent_Action:
		if item_running(it^) do return "Running in the terminal below"
		return fmt.tprintf("Run `%s` in a terminal here", it.command)
	case .Agent_Copy:
		return fmt.tprintf("Copy `%s`: Deckhand does not run updates for %s installs", it.command, INSTALL_LAYOUT_NAMES[it.layout])
	}
	return ""
}

// A click on the step (setup_event): Install/Update runs, Copy copies, Close drops the output.
// "" = done; else what to say.
harness_step_click :: proc(h: Hit_Setup) -> string {
	#partial switch h.what {
	case .Agent_Action:
		if h.index < 0 || h.index >= len(HARNESS_MANIFEST) do return ""
		if harness_run.status == .Running && harness_run.item == HARNESS_MANIFEST[h.index].id do return ""
		return harness_run_start(HARNESS_MANIFEST[h.index].id)
	case .Agent_Copy:
		if h.index < 0 || h.index >= len(HARNESS_MANIFEST) do return ""
		if it := harness_item(HARNESS_MANIFEST[h.index].id); it != nil && it.command != "" {
			if platform.set_clipboard != nil do platform.set_clipboard(it.command)
			toast_show(fmt.tprintf("Copied: %s", it.command))
		}
	case .Agent_Close:
		harness_run_dismiss()
	}
	return ""
}

// Keys and the wheel while a run's terminal shows on the sheet: the keyboard is the terminal's
// while it runs (⌃C stops it; ⌘Q still quits). True if taken.
harness_step_event :: proc(e: ^sapp.Event) -> bool {
	t := harness_run_term()
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
		held := harness_run.status == .Running && e.modifiers & sapp.MODIFIER_SUPER == 0
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

HARNESS_SETTINGS_ROW :: "pi-desk:harness:"

// The group's rows (settings_file_rows): per harness, its row; once installed, its integration and
// recommended items. Install… and Update… open the sheet's checklist.
harness_settings_rows :: proc() -> []Settings_File_Row {
	out := make([dynamic]Settings_File_Row, context.temp_allocator)
	if len(harness_items) == 0 do harness_checklist_refresh(bump = false)
	for h in Harness {
		installed := harness_item_installed(h)
		for it in harness_items {
			r := HARNESS_MANIFEST[it.row]
			if r.harness != h || (!installed && r.kind != .Harness) do continue
			button := ""
			if it.action != .None do button = it.runnable ? (it.action == .Install ? "Install…" : "Update…") : "Show…"
			label := r.name
			switch r.kind {
			case .Harness:
			case .Built_In:    label = "  Deckhand integration"
			case .Third_Party: label = fmt.tprintf("  %s", r.name)
			}
			append(&out, Settings_File_Row{group = "agents", label = label, detail = harness_item_text(it), path = strings.concatenate({HARNESS_SETTINGS_ROW, r.id}, context.temp_allocator), button = button})
		}
	}
	return out[:]
}

// A Coding agents row's button: the sheet's checklist. False: not such a row.
harness_settings_button :: proc(path: string) -> bool {
	if !strings.has_prefix(path, HARNESS_SETTINGS_ROW) do return false
	ui_do(Setup_Sheet{open = true})
	return true
}

// A Coding agents row's tooltip ("" = not such a row).
harness_settings_tip :: proc(path: string, on_button: bool) -> string {
	if !strings.has_prefix(path, HARNESS_SETTINGS_ROW) do return ""
	it := harness_item(path[len(HARNESS_SETTINGS_ROW):])
	if it == nil do return ""
	r := HARNESS_MANIFEST[it.row]
	if on_button do return fmt.tprintf("Open the coding agents checklist: `%s`", it.command)
	return fmt.tprintf("%s: %s. %s", r.name, harness_item_text(it^), r.why)
}
