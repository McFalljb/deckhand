package main

// A cover's contract (ui_cover.odin), whatever covers: opening it lets go of what can hold input;
// every input path goes to it; right after it opens or closes, the quiet gate drops keys,
// characters, input-method text, pastes and mouse buttons until all are up and COVER_QUIET has
// passed, and never sticks; what had the keyboard gets it back. Driven through event() with the
// event sequences sokol sends (a held ⌘V: a KEY_DOWN repeat and a CLIPBOARD_PASTED each time). A
// test cover records what it gets; the window copies (Term_View) have no core behind them (pk_*
// helpers: peek_test.odin).

import "base:runtime"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
got: [dynamic]sapp.Event_Type // what the test cover's event got
@(private = "file")
target: u64 // its target tab (0: none)
@(private = "file")
pasted: [dynamic]u64 // tab_paste's tabs, in order

@(private = "file")
TEST_COVER :: Cover_Hooks {
	event = proc(e: ^sapp.Event) -> bool {
		// ⌘W or a right click closes it (taken); ⌘K closes it and goes on below; the rest is its own
		if e.type == .KEY_DOWN && e.modifiers & sapp.MODIFIER_SUPER != 0 {
			if e.key_code == .W {
				cover_close()
				return true
			}
			if e.key_code == .K {
				cover_close()
				return false
			}
		}
		if e.type == .MOUSE_DOWN && e.mouse_button == .RIGHT {
			cover_close()
			return true
		}
		#partial switch e.type {
		case .FOCUSED, .UNFOCUSED, .RESIZED: return false
		}
		append(&got, e.type)
		return true
	},
	hit = proc() -> Hit {return Hit_Peek(.Close)},
	action = proc(id: string) -> bool {return id == "close_tab"},
	target = proc() -> u64 {return target},
}

@(private = "file")
setup :: proc() -> (under, over: ^Term_View) {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	clear(&got)
	clear(&pasted)
	target = 0
	pk_session(100, "Here", pk_tab(101), pk_tab(102))
	pk_session(200, "There", pk_tab(201))
	state.current_session = 100
	under = pk_view(101, 80, 24)
	over = pk_view(201, 80, 24)
	tab_paste_hook = proc(tab: u64, text: string) {append(&pasted, tab)}
	return
}

@(private = "file")
send :: proc(type: sapp.Event_Type, k: sapp.Keycode = .INVALID, mods: u32 = 0, repeat := false, ch: rune = 0, button := sapp.Mousebutton.LEFT) {
	e := sapp.Event{type = type, key_code = k, modifiers = mods, key_repeat = repeat, char_code = u32(ch), mouse_button = button}
	event(&e)
}

// A held ⌘V as sokol sends it: each KEY_DOWN (repeats too) with exactly ⌘ is followed by a paste.
@(private = "file")
cmd_v :: proc(repeat := false) {
	send(.KEY_DOWN, .V, sapp.MODIFIER_SUPER, repeat)
	send(.CLIPBOARD_PASTED)
}

@(private = "file")
vt :: proc(v: ^Term_View, s: string) {gh.terminal_vt_write(v.gt, raw_data(s), len(s))}

// Open: every terminal gets the releases of the keys pressed in it (Atlas's too: whichever got
// them) and its mouse press's release; Atlas's drawer lets go of its capture; the terminal with
// the keys loses focus; menus close; a palette with the keyboard closes and stays closed.
@(test)
cover_open_lets_go_of_what_was_held :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	under, over := setup()
	defer pk_reset()
	testing.expect(t, key_view() == under, "the tab on screen has the keyboard")
	vt(under, "\x1b[>11u\x1b[?1000h\x1b[?1006h") // releases reported, mouse tracked
	vt(over, "\x1b[>11u")
	term_focus(under, true)
	send(.KEY_DOWN, .LEFT) // held, in the pane
	testing.expect(t, pk_take(101) != "", "the press reached it")
	// a key held in another terminal (Atlas's, with agent_input: whichever got the press)
	held := sapp.Event{type = .KEY_DOWN, key_code = .RIGHT}
	term_key_down(over, &held)
	_ = pk_take(201)
	under.mouse_down, under.mouse_button = true, .Left
	drawer_release_input(set = true) // a press in Atlas's terminal owns the pointer
	menu.open = true

	cover_open(TEST_COVER)
	sent := pk_take(101)
	testing.expectf(t, strings.contains(sent, ":3D"), "the held ← is released: %q", sent)
	testing.expectf(t, strings.contains(sent, "\x1b[<0;"), "the mouse press is released: %q", sent)
	testing.expectf(t, strings.contains(pk_take(201), ":3C"), "the other terminal's held → is released too")
	testing.expect(t, !under.focused, "and it loses focus")
	testing.expect(t, !under.mouse_down && !drawer_mouse_held() && !menu.open, "no press, no capture, no menu")

	// the real release comes during the gate: nowhere
	send(.KEY_UP, .LEFT)
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, len(got), 0)
	cover_close()
	testing.expect(t, under.focused, "the keyboard's terminal has its focus again")

	// a palette with the keyboard closes under it, and stays closed
	ui_do(core.Set_Focus{"palette"})
	core.inbox_drain()
	cover_open(TEST_COVER)
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "")
	cover_close()
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "")
}

// While open: keys, characters, mouse, scroll, drops, an input method's composition and text, a
// paste, the Edit menu, hits and menu bar actions go to the cover (text and pastes to its
// target, if it has one still, or nowhere); the field and the terminal under it get nothing.
@(test)
cover_takes_every_input_path :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _ = setup()
	defer pk_reset()
	state.sidebar.view = .Attention
	filter_focus()
	core.inbox_drain()
	target = 201
	cover_open(TEST_COVER)
	pk_key(.X, 0, 'x')
	cover_wait(COVER_QUIET)
	send(.MOUSE_DOWN)
	send(.MOUSE_UP)
	send(.MOUSE_MOVE)
	send(.MOUSE_SCROLL)
	send(.FILES_DROPPED)
	testing.expect_value(t, len(got), 8)
	testing.expect_value(t, tf_text(&filter_field), "")
	testing.expect_value(t, pk_take(101), "")
	// an input method: its composition is the cover's (no field under it draws it), its text the target's
	ime_set_marked("か", 1)
	testing.expect_value(t, ime.marked, "")
	m, _ := cover_marked()
	testing.expect_value(t, m, "か")
	testing.expect(t, !ime_option_composes(), "Option is the target's")
	ime_commit("か")
	testing.expect_value(t, pk_take(201), "か")
	testing.expect_value(t, tf_text(&filter_field), "")
	// a paste: the target's
	cover_wait(COVER_QUIET)
	cmd_v()
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	testing.expect(t, len(pasted) == 1 && pasted[0] == 201, "pasted into the target")
	testing.expect_value(t, tf_text(&filter_field), "")
	testing.expect_value(t, edit_target(), Edit_Target.Terminal)
	h, covered := cover_hit()
	testing.expect(t, covered && h == Hit(Hit_Peek(.Close)), "the cover's hits only")
	testing.expect(t, cover_action("close_tab") && cover_is_open(), "its own action")
	testing.expect_value(t, len(find_session(100).tabs), 2)
	// no target: text and a paste go nowhere
	target = 0
	cover_wait(COVER_QUIET)
	ime_commit("y")
	cmd_v()
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	testing.expect_value(t, len(pasted), 1)
	testing.expect_value(t, edit_target(), Edit_Target.None)
	testing.expect_value(t, tf_text(&filter_field), "")
	testing.expect_value(t, pk_take(101), "")
	// an action not its own closes it first
	testing.expect(t, !cover_action("new_tab") && !cover_is_open(), "closed, the action goes on")
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
}

// Round 2's six: a held ⌘V through a close by the mouse; ⌘V with a button down (no paste comes);
// a key held through an input method's composition; Atlas's capture (cover_open_lets_go...);
// Atlas's held key (cover_open_lets_go...); ⌘'s release after a chord that closes and goes on.
@(test)
cover_quiet_gate_after_close :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _ = setup()
	defer pk_reset()
	target = 201

	// 1. ⌘V held in it, closed by a click: the repeats' pastes go nowhere, not to the tab under it
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	cmd_v()
	testing.expect(t, len(pasted) == 1 && pasted[0] == 201, "pasted into the target")
	send(.MOUSE_DOWN, button = .RIGHT) // closes it
	send(.MOUSE_UP, button = .RIGHT)
	testing.expect(t, !cover_is_open(), "closed")
	for _ in 0 ..< 4 {
		cover_wait(40 * time.Millisecond)
		cmd_v(repeat = true)
	}
	testing.expect_value(t, len(pasted), 1)
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	cover_wait(COVER_QUIET)
	cmd_v() // a paste now: the tab on screen's
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	testing.expect(t, len(pasted) == 2 && pasted[1] == 101, "a paste after the gate works")
	clear(&pasted)

	// 2. ⌘V with a button down (sokol sends no paste then), closed, a paste later: the tab on screen's
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.MOUSE_DOWN)
	send(.KEY_DOWN, .V, sapp.MODIFIER_SUPER | sapp.MODIFIER_LMB)
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER | sapp.MODIFIER_LMB)
	send(.MOUSE_UP)
	cover_dismiss()
	cover_wait(COVER_QUIET)
	cmd_v()
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	testing.expect(t, len(pasted) == 1 && pasted[0] == 101, "the later paste is the tab on screen's, not the old target's")

	// 3. a key held through an input method (its key events never come), closed by a click: its
	// repeated text goes nowhere while it keeps coming; then typing works
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	ime_commit("a")
	testing.expect_value(t, pk_take(201), "a")
	send(.MOUSE_DOWN, button = .RIGHT)
	send(.MOUSE_UP, button = .RIGHT)
	for _ in 0 ..< 4 {
		cover_wait(100 * time.Millisecond)
		ime_commit("a")
	}
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, pk_take(201), "")
	cover_wait(COVER_QUIET)
	ime_commit("b")
	testing.expect_value(t, pk_take(101), "b")

	// 6. ⌘K closes it and goes on (the palette opens); ⌘'s release still reaches the link tracking
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.KEY_DOWN, .LEFT_SUPER, sapp.MODIFIER_SUPER)
	send(.KEY_DOWN, .K, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect(t, !cover_is_open(), "closed")
	testing.expect_value(t, state.focus_widget, "palette")
	testing.expect(t, link_cmd_held, "⌘ is down")
	send(.KEY_UP, .K, sapp.MODIFIER_SUPER)
	send(.KEY_UP, .LEFT_SUPER)
	testing.expect(t, !link_cmd_held, "⌘'s release was seen: nothing latched")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()

	// holding ⌘W: the first closes it, the repeats do not close the tab under it
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.KEY_DOWN, .W, sapp.MODIFIER_SUPER)
	testing.expect(t, !cover_is_open(), "⌘W closed it")
	for _ in 0 ..< 3 {
		cover_wait(40 * time.Millisecond)
		send(.KEY_DOWN, .W, sapp.MODIFIER_SUPER, repeat = true)
	}
	send(.KEY_UP, .W, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect_value(t, len(find_session(100).tabs), 2)
	testing.expect_value(t, len(state.pending_confirmations), 0)

	// holding Enter while it closes: nothing types under it; pressed again later, it does
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.KEY_DOWN, .ENTER)
	cover_dismiss()
	cover_wait(40 * time.Millisecond)
	send(.KEY_DOWN, .ENTER, repeat = true)
	send(.CHAR, ch = '\r')
	send(.KEY_UP, .ENTER)
	testing.expect_value(t, pk_take(101), "")
	pk_key(.ENTER)
	testing.expect_value(t, pk_take(101), "\r")
}

// The gate never sticks: a key whose release never came ends it after COVER_QUIET without key
// events, and the window going to the background ends it; a button still down holds it.
@(test)
cover_quiet_gate_ends :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _ = setup()
	defer pk_reset()
	// a key down, its release lost: quiet for COVER_QUIET, the gate ends
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.KEY_DOWN, .J)
	cover_dismiss()
	testing.expect(t, cover_quiet(), "on after the close")
	cover_wait(COVER_QUIET)
	testing.expect(t, !cover_quiet(), "ended: no key event for COVER_QUIET")
	send(.KEY_DOWN, .X)
	send(.CHAR, ch = 'x')
	send(.KEY_UP, .X)
	testing.expect_value(t, pk_take(101), "x")

	// keys down when the window goes to the background: their releases never come; it ends
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.KEY_DOWN, .J)
	send(.KEY_DOWN, .K)
	cover_dismiss()
	send(.UNFOCUSED)
	send(.FOCUSED)
	cover_wait(COVER_QUIET / 2)
	send(.KEY_DOWN, .J, repeat = true) // a stray repeat keeps the key "down" by time, not the count
	cover_wait(COVER_QUIET)
	testing.expect(t, !cover_quiet(), "ended after the window lost focus")
	pk_key(.Y, 0, 'y')
	testing.expect_value(t, pk_take(101), "y")

	// a button down holds it until it is up
	cover_open(TEST_COVER)
	cover_wait(COVER_QUIET)
	send(.MOUSE_DOWN)
	cover_dismiss()
	cover_wait(2 * COVER_QUIET)
	testing.expect(t, cover_quiet(), "a button is down")
	send(.MOUSE_UP)
	testing.expect(t, !cover_quiet(), "up: ended")
}

// What had the keyboard when the opening event began has it after: a click that ended a field's
// editing on the way (widget_event: Set_Focus "") still gives the field back; Open (restore =
// false) leaves it where the cover put it. The window going to the background and back keeps
// the keyboard the cover's.
@(test)
cover_gives_the_keyboard_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	under, over := setup()
	defer pk_reset()
	filter_focus()
	core.inbox_drain()
	// a click outside the field opens it: the field's editing ended first
	e := sapp.Event{type = .MOUSE_DOWN}
	testing.expect(t, !cover_track(&e), "not dropped")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()
	target = 201
	cover_open(TEST_COVER)
	cover_event_end()
	e.type = .MOUSE_UP
	_ = cover_track(&e)
	cover_event_end()
	cover_close()
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
	// restore = false: where it is now
	cover_open(TEST_COVER)
	ui_do(core.Set_Focus{""})
	core.inbox_drain()
	cover_close(restore = false)
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "")

	// the window to the background and back (⌘H, ⌘M): the cover's target has the keyboard
	term_focus(under, true)
	cover_open(TEST_COVER)
	term_focus(over, true)
	send(.UNFOCUSED)
	send(.FOCUSED)
	testing.expect(t, over.focused && !under.focused, "the target's focus, not the one under it")
	pk_key(.X, 0, 'x')
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, pk_take(101), "")
	cover_close()
	testing.expect(t, under.focused, "the terminal under it has it again")
}
