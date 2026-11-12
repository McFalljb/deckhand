package main

// A cover: something drawn over the centre that owns the input while it shows (a peek,
// ui_peek.odin). One place says what that means, so nothing typed, clicked, composed or pasted
// leaks to what is under it, before, during or after:
//
// Open (cover_open): what had the input lets go of it. The terminal with the keyboard gets the
// releases of the keys held before the opening event and loses focus; every terminal's mouse
// press is released; tab, column and pane drags end; menus close; a palette or popover that had
// the keyboard closes. What had the keyboard is remembered as it was when the opening event
// began (a click that ended a field's editing on the way still counts as the field's), and
// nothing else under the cover is changed.
//
// While open: every input path asks the cover first: sokol's keys, characters, mouse, scroll,
// pastes and dropped files (cover_event, before anything else in event()), an input method's
// composition and commits, dictation and the emoji picker (ime_*: they go to its target, or
// nowhere; the composition is the cover's, never drawn in a field under it), the menu bar's
// actions (cover_action) and its Edit items (edit_target), browsers and apps (they do not want
// keys while one shows), hits (ui_hit: the cover's own only).
//
// Close (cover_close): keys held at that moment are the cover's: their repeats, characters and
// releases go nowhere (holding ⌘W or Enter does not go on into what is under it); a paste asked
// for while it showed reaches the tab it was asked for, or nowhere. What had the keyboard gets
// it back (unless the cover went somewhere else: restore = false).
//
// Keys held through an open are swallowed the same way (the Space or the chord that opened it).

import "core:strings"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

Cover_Hooks :: struct {
	event:       proc(e: ^sapp.Event) -> bool, // its input; false: not taken (it may have closed: the event goes on below)
	hit:         proc() -> Hit, // what the pointer is over in it (ui_hit: nothing under it is hit)
	action:      proc(id: string) -> bool, // a menu bar action while open; true: its own (nil: none are)
	close:       proc(), // its owner closes it (its own state too; it calls cover_close)
	target:      proc() -> u64, // the terminal tab that typed text, a composition and a paste go to (nil or 0: none)
	hides_under: bool, // what is under it is not on screen (cover_hides_under); a peek: false
}

@(private = "file")
KEYS :: 512 // sapp.Keycode's range

@(private = "file")
Cover :: struct {
	open:         bool,
	hooks:        Cover_Hooks,
	focus:        [64]u8, // what had the keyboard when it opened (state.focus_widget)
	focus_n:      int,
	// keys
	held:         [KEYS]bool, // down now (as the window saw them)
	swallow:      [KEYS]bool, // held through an open or a close: repeats and the release go nowhere
	swallow_char: bool, // the last key down was swallowed (or closed the cover): its CHAR goes nowhere
	mods:         u32, // the last event's modifiers
	// the event being handled (cover_track .. cover_event_end)
	in_event:     bool,
	now_key:      sapp.Keycode, // its key, a KEY_DOWN's
	event_focus:  [64]u8, // what had the keyboard when it began
	event_focus_n: int,
	// a paste asked for while open (⌘V): where it goes when it arrives
	paste_armed:  bool,
	paste_to:     u64,
	// an input method's composition while open (ime.marked stays empty: no field under it draws one)
	marked:       string,
	caret:        int,
}
@(private = "file")
cv: Cover

cover_is_open :: proc() -> bool {return cv.open}

// Nothing open, held or swallowed (tests).
cover_reset :: proc() {
	delete(cv.marked)
	cv = {}
	tab_paste_hook = nil
}

// For the Deck view: what is under it is hidden (its owner keeps it off screen); a peek leaves it.
cover_hides_under :: proc() -> bool {return cv.open && cv.hooks.hides_under}

// The terminal tab typed text goes to while a cover shows (0: none, or no cover).
cover_target_tab :: proc() -> u64 {return cv.open && cv.hooks.target != nil ? cv.hooks.target() : 0}
cover_target_view :: proc() -> ^Term_View {
	id := cover_target_tab()
	return id != 0 ? term_view_peek(id) : nil
}

// What the pointer is over while one shows (ui_hit, first). covered: one shows.
cover_hit :: proc() -> (h: Hit, covered: bool) {
	if !cv.open do return nil, false
	return cv.hooks.hit != nil ? cv.hooks.hit() : nil, true
}

// Its input method's composition (drawn at its target only).
cover_marked :: proc() -> (string, int) {return cv.marked, cv.caret}

// Opens a cover (or replaces the one showing: nothing is released or remembered again).
cover_open :: proc(h: Cover_Hooks) {
	if cv.open {
		cv.hooks = h
		return
	}
	ime_cancel() // a composition belongs to what had the keyboard
	focus := cv.in_event ? string(cv.event_focus[:cv.event_focus_n]) : state.focus_widget
	cover_release_under(terminal_keys = focus == "")
	if cover_transient(focus) {
		if state.focus_widget == focus do ui_do(core.Set_Focus{""}) // a palette or popover closes under it
		focus = ""
	}
	cv.focus_n = copy(cv.focus[:], focus)
	cv.open, cv.hooks = true, h
	cv.paste_armed = false
	for k in 0 ..< KEYS do if cv.held[k] do cv.swallow[k] = true // the opening key's too: its release is not the cover's
	if cv.in_event && cv.now_key != .INVALID do cv.swallow_char = true
	app.redraw = true
}

// Closes it: keys held now are swallowed until released; what had the keyboard has it again
// (restore), else the keyboard stays where it is now.
cover_close :: proc(restore := true) {
	if !cv.open do return
	ime_cancel()
	cv.open, cv.hooks = false, {}
	for k in 0 ..< KEYS do if cv.held[k] do cv.swallow[k] = true
	if cv.in_event && cv.now_key != .INVALID do cv.swallow_char = true
	focus := string(cv.focus[:cv.focus_n])
	if restore && state.focus_widget != focus do ui_do(core.Set_Focus{strings.clone(focus, context.temp_allocator)})
	if kv := key_view(); kv != nil && !kv.focused && app.window_active do term_focus(kv, true) // as the window's focus gives it (main.odin .FOCUSED)
	app.redraw = true
}

// Closes it through its owner (a menu bar action not its own, a test).
cover_dismiss :: proc() {
	if !cv.open do return
	if cv.hooks.close != nil do cv.hooks.close()
	cover_close()
}

// A palette, popover or sheet: closed when a cover opens over it, never given the keyboard back.
@(private = "file")
cover_transient :: proc(w: string) -> bool {
	switch w {
	case "palette", "settings", "shortcuts", "notifications", "setup": return true
	}
	return false
}

// What had the input lets go: key releases to the terminal with the keyboard (keys pressed before
// this event: the opening key's own press went to whatever opened the cover), its focus, every
// terminal's mouse press, drags, menus.
@(private = "file")
cover_release_under :: proc(terminal_keys: bool) {
	if kv := key_view(); kv != nil {
		// (⌘ never reaches a terminal: main.odin's key path)
		if terminal_keys do for k in 0 ..< KEYS do if cv.held[k] && sapp.Keycode(k) != cv.now_key && sapp.Keycode(k) != .LEFT_SUPER && sapp.Keycode(k) != .RIGHT_SUPER {
			up := sapp.Event{type = .KEY_UP, key_code = sapp.Keycode(k), modifiers = cv.mods &~ sapp.MODIFIER_SUPER}
			term_key_up(kv, &up)
		}
		if kv.focused do term_focus(kv, false)
	}
	for _, v in term_views do cover_release_mouse(v)
	tab_drag_cancel()
	if divider.active do divider_release()
	pane_divider_release()
	pane_release()
	if menu.open do menu_close()
	wt_menu_close()
}

// A terminal's mouse press ends: its program gets the release (as for a release in its pane),
// a selection drag stops where it is.
cover_release_mouse :: proc(v: ^Term_View) {
	if v == nil || !v.mouse_down do return
	b: sapp.Mousebutton = .LEFT
	#partial switch v.mouse_button {
	case .Right:  b = .RIGHT
	case .Middle: b = .MIDDLE
	}
	up := sapp.Event{type = .MOUSE_UP, mouse_button = b, mouse_x = app.pointer.x, mouse_y = app.pointer.y, modifiers = cv.mods}
	term_mouse_up(v, &up)
	term_cancel_drag(v)
}

// First thing in event(), cover or not: keys are tracked, and a key held through a cover's open
// or close has its repeats, its character and its release swallowed. True: swallowed.
cover_track :: proc(e: ^sapp.Event) -> bool {
	cv.in_event = true
	cv.now_key = .INVALID
	cv.event_focus_n = copy(cv.event_focus[:], state.focus_widget)
	cv.mods = e.modifiers
	k := int(e.key_code)
	ok := k > 0 && k < KEYS
	#partial switch e.type {
	case .KEY_DOWN:
		cv.swallow_char = false
		if ok && cv.swallow[k] {
			if e.key_repeat {
				cv.swallow_char = true
				app.key_taken = true
				return true
			}
			cv.swallow[k] = false // pressed again (its release was missed): a new press
		}
		if ok do cv.held[k] = true
		cv.now_key = e.key_code
	case .KEY_UP:
		if ok do cv.held[k] = false
		if ok && cv.swallow[k] {
			cv.swallow[k] = false
			return true
		}
	case .CHAR:
		if cv.swallow_char do return true
	case .UNFOCUSED:
		// releases while another app is in front never come
		cv.held, cv.swallow = {}, {}
		cv.swallow_char = false
	}
	return false
}

// The event is done (event()'s defer).
cover_event_end :: proc() {
	cv.in_event = false
	cv.now_key = .INVALID
}

// The cover's turn (event(), before any shortcut or widget). True: taken.
cover_event :: proc(e: ^sapp.Event) -> bool {
	if e.type == .CLIPBOARD_PASTED && cv.paste_armed {
		cv.paste_armed = false
		tab_paste(cv.paste_to)
		return true
	}
	if !cv.open do return false
	if e.type == .KEY_DOWN {
		cv.paste_armed = false
		if e.key_code == .V && e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL) == sapp.MODIFIER_SUPER {
			cv.paste_armed, cv.paste_to = true, cover_target_tab() // its paste follows (CLIPBOARD_PASTED)
		}
	}
	if e.type == .CLIPBOARD_PASTED {
		tab_paste(cover_target_tab())
		return true
	}
	taken := cv.hooks.event != nil && cv.hooks.event(e)
	if !taken && !cv.open && e.type == .KEY_DOWN {
		// a chord that closed it and goes on below: that key and its character are its, not the cover's
		if k := int(e.key_code); k > 0 && k < KEYS do cv.swallow[k] = false
		cv.swallow_char = false
		cv.paste_armed = false
	}
	return taken
}

// tests: where tab_paste's text goes instead of the core
tab_paste_hook: proc(tab_id: u64, text: string)

// The user's paste (the clipboard) into a terminal tab (0 or gone: nowhere): a pane's (main.odin)
// and a cover's.
tab_paste :: proc(tab_id: u64) {
	if tab_id == 0 do return
	_, tab, _ := find_tab(tab_id)
	if tab == nil do return
	core.claude_note_typed(tab)
	if tab_paste_hook != nil do tab_paste_hook(tab_id, clipboard_text())
	else do ui_do(core.Send_Text{tab_id, clipboard_text()})
}

// A menu bar action while open (action_run): the cover's own, else it closes first. True: taken.
cover_action :: proc(id: string) -> bool {
	if !cv.open do return false
	if cv.hooks.action != nil && cv.hooks.action(id) do return true
	cover_dismiss()
	return false
}

// ---- input methods ----

// Text an input method, dictation or the emoji picker committed while open: to its target, or
// nowhere.
cover_ime_commit :: proc(text: string) {
	id := cover_target_tab()
	v := id != 0 ? term_view_peek(id) : nil
	if v == nil do return
	_, tab, _ := find_tab(id)
	core.claude_note_typed(tab)
	term_text_input(v, text)
}

// Its composition (ime_set_marked while open).
cover_set_marked :: proc(text: string, caret: int) -> bool {
	if !cv.open do return false
	if text == cv.marked do return true
	delete(cv.marked)
	cv.marked = strings.clone(text)
	cv.caret = caret
	if v := cover_target_view(); v != nil do v.changed = true
	app.redraw = true
	return true
}
