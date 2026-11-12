package main

// A cover: something drawn over the centre that owns the input while it shows (a peek,
// ui_peek.odin). One place says what that means, so nothing typed, clicked, composed or pasted
// leaks to what is under it, before, during or after:
//
// Open (cover_open): everything that can hold input lets go of it (INPUT_HOLDERS: terminals,
// Atlas's drawer, pages, apps, drags, menus); a palette or popover with the keyboard closes; what
// had the keyboard is remembered as it was when the opening event began (a click that ended a
// field's editing on the way still counts as the field's).
//
// While open: every input path asks the cover first: sokol's keys, characters, mouse, scroll and
// dropped files (cover_event, before anything else in event()), a paste (to its target if it has
// one and that tab still exists, else nowhere), an input method's composition and commits,
// dictation and the emoji picker (ime_*: its target, or nowhere; the composition is the cover's,
// never drawn in a field under it), the menu bar's actions (cover_action) and its Edit items
// (edit_target), browsers and apps (they do not want keys while one shows), hits (ui_hit).
//
// The quiet gate, right after a cover opens or closes: key presses, repeats, releases,
// characters, pastes, input-method text and mouse buttons go nowhere until no key or button is
// down (a key with no event for COVER_QUIET counts as up: an input method may eat its events)
// and COVER_QUIET has passed (a paste trails its ⌘V). Holding ⌘W or Enter through a close does
// nothing more, and nothing held through an open types into the cover. State hooks still see
// every event (term_links_event's ⌘).
//
// Close (cover_close): what had the keyboard gets it back (unless the cover went somewhere else:
// restore = false).

import "core:strings"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

COVER_QUIET :: 150 * time.Millisecond

Cover_Hooks :: struct {
	event:       proc(e: ^sapp.Event) -> bool, // its input; false: not taken (it may have closed: the event goes on below)
	hit:         proc() -> Hit, // what the pointer is over in it (ui_hit: nothing under it is hit)
	action:      proc(id: string) -> bool, // a menu bar action while open; true: its own (nil: none are)
	close:       proc(), // its owner closes it (its own state too; it calls cover_close)
	target:      proc() -> u64, // the terminal tab that typed text, a composition and a paste go to (nil or 0: none)
	hides_under: bool, // what is under it is not on screen (cover_hides_under); a peek: false
}

// What can hold input (a key or a button down, a capture, a drag): each lets go when a cover opens.
// A new surface that captures input is one more entry.
@(private = "file")
INPUT_HOLDERS := [?]proc() {
	proc() {for _, v in term_views do term_release_input(v)}, // pane terminals, Atlas's, any copy
	proc() {drawer_release_input()}, // Atlas's drawer: its press's capture (its terminal: above)
	browsers_release_input,
	apps_release_input,
	proc() {
		tab_drag_cancel()
		if divider.active do divider_release()
		pane_divider_release()
		pane_release()
	},
	proc() {
		if menu.open do menu_close()
		wt_menu_close()
	},
}

@(private = "file")
Cover :: struct {
	open:          bool,
	hooks:         Cover_Hooks,
	focus:         [64]u8, // what had the keyboard when it opened (state.focus_widget)
	focus_n:       int,
	in_event:      bool, // an event is being handled (cover_track .. cover_event_end)
	event_focus:   [64]u8, // what had the keyboard when it began
	event_focus_n: int,
	marked:        string, // an input method's composition while open (ime.marked stays empty)
	caret:         int,
	// the quiet gate
	quiet:         bool,
	quiet_from:    time.Tick, // it opened or closed
	keys:          int, // keys down (raw KEY_DOWN / KEY_UP)
	last_key:      time.Tick, // the last key event (an input method's commit too)
	ime_key:       bool, // the last was an input method's commit: a key may be down that sokol never saw
	buttons:       int, // mouse buttons down
}
@(private = "file")
cv: Cover

// tests: the clock runs this far ahead (cover_wait)
@(private = "file")
skew: time.Duration

@(private = "file")
now :: proc() -> time.Tick {return time.tick_add(time.tick_now(), skew)}

// tests: time passes.
cover_wait :: proc(d: time.Duration) {skew += d}

// Nothing open, held or gated (tests).
cover_reset :: proc() {
	delete(cv.marked)
	cv = {}
	tab_paste_hook = nil
}

cover_is_open :: proc() -> bool {return cv.open}

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
	for release in INPUT_HOLDERS do release()
	if kv := key_view(); kv != nil && kv.focused do term_focus(kv, false) // the terminal with the keys (main.odin's too: a pane's, or Atlas's with agent_input)
	if cover_transient(focus) {
		if state.focus_widget == focus do ui_do(core.Set_Focus{""}) // a palette or popover closes under it
		focus = ""
	}
	cv.focus_n = copy(cv.focus[:], focus)
	cv.open, cv.hooks = true, h
	quiet_start()
	app.redraw = true
}

// Closes it; what had the keyboard has it again (restore), else the keyboard stays where it is.
cover_close :: proc(restore := true) {
	if !cv.open do return
	ime_cancel()
	cv.open, cv.hooks = false, {}
	quiet_start()
	focus := string(cv.focus[:cv.focus_n])
	if restore && state.focus_widget != focus do ui_do(core.Set_Focus{strings.clone(focus, context.temp_allocator)})
	if kv := key_view(); kv != nil && !kv.focused && app.window_active do term_focus(kv, true) // as the window's focus gives it (main.odin .FOCUSED)
	app.redraw = true
}

// Closes it through its owner (a menu bar action not its own).
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

// ---- the quiet gate ----

@(private = "file")
quiet_start :: proc() {
	cv.quiet = true
	cv.quiet_from = now()
}

// Whether the gate is on (it ends here, once nothing is down and COVER_QUIET has passed).
cover_quiet :: proc() -> bool {
	if !cv.quiet do return false
	t := now()
	keys_up := (cv.keys <= 0 && !cv.ime_key) || time.tick_diff(cv.last_key, t) >= COVER_QUIET
	if cv.buttons <= 0 && keys_up && time.tick_diff(cv.quiet_from, t) >= COVER_QUIET do cv.quiet = false
	return cv.quiet
}

// In event(), after the state hooks and before anything else, cover or not: keys and buttons are
// counted, and while the gate is on input goes nowhere. A press is judged by what was down before
// it, a release after it. True: dropped.
cover_track :: proc(e: ^sapp.Event) -> bool {
	cv.in_event = true
	cv.event_focus_n = copy(cv.event_focus[:], state.focus_widget)
	quiet := cover_quiet()
	#partial switch e.type {
	case .KEY_DOWN:
		cv.last_key = now()
		if !e.key_repeat do cv.keys += 1
	case .KEY_UP:
		cv.last_key = now()
		cv.keys = max(cv.keys - 1, 0)
		cv.ime_key = false
	case .MOUSE_DOWN:
		cv.buttons += 1
	case .MOUSE_UP:
		cv.buttons = max(cv.buttons - 1, 0)
	case .MOUSE_MOVE:
		// the buttons the system says are down
		b := 0
		for m in ([]u32{sapp.MODIFIER_LMB, sapp.MODIFIER_RMB, sapp.MODIFIER_MMB}) do if e.modifiers & m != 0 do b += 1
		cv.buttons = b
	case .UNFOCUSED:
		cv.keys, cv.buttons = 0, 0 // releases while another app is in front never come
		cv.ime_key = false
	}
	if e.type != .KEY_DOWN && e.type != .MOUSE_DOWN do quiet = cover_quiet()
	if !quiet do return false
	#partial switch e.type {
	case .KEY_DOWN, .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_DOWN, .MOUSE_UP:
		if e.type == .KEY_DOWN do app.key_taken = true
		return true
	}
	return false
}

// The event is done (event()'s defer).
cover_event_end :: proc() {cv.in_event = false}

// The cover's turn (event(), before any shortcut or widget). True: taken.
cover_event :: proc(e: ^sapp.Event) -> bool {
	if !cv.open do return false
	if e.type == .CLIPBOARD_PASTED {
		tab_paste(cover_target_tab()) // its target's, if it has one still; else nowhere
		return true
	}
	return cv.hooks.event != nil && cv.hooks.event(e)
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

// Text an input method, dictation or the emoji picker committed (ime_commit). True: the cover's
// (its target got it, or nothing did: the gate is on, or it has no target).
cover_ime_commit :: proc(text: string) -> bool {
	quiet := cover_quiet() // (judged by what was down before it, as a press)
	cv.last_key, cv.ime_key = now(), true // a key behind it is down (its key events may never come)
	if quiet do return true
	if !cv.open do return false
	id := cover_target_tab()
	v := id != 0 ? term_view_peek(id) : nil
	if v == nil do return true
	_, tab, _ := find_tab(id)
	core.claude_note_typed(tab)
	term_text_input(v, text)
	return true
}

// Its composition (ime_set_marked while open, or during the gate: none). True: taken.
cover_set_marked :: proc(text: string, caret: int) -> bool {
	if text != "" && cover_quiet() do return true
	if !cv.open do return false
	if text == cv.marked do return true
	delete(cv.marked)
	cv.marked = strings.clone(text)
	cv.caret = caret
	if v := cover_target_view(); v != nil do v.changed = true
	app.redraw = true
	return true
}
