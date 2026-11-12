package main

// A cover's contract (ui_cover.odin), whatever covers: opening it lets go of what was held under
// it; every input path goes to it; closing it swallows the keys held through it and delivers a
// paste only where it was asked for; what had the keyboard gets it back. A test cover records what
// it gets; the window copies (Term_View) have no core behind them (pk_* helpers: peek_test.odin).

import "base:runtime"
import "core:strings"
import "core:testing"
import "core"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
got: [dynamic]sapp.Event_Type // what the test cover's event got
@(private = "file")
got_keys: [dynamic]sapp.Keycode // its KEY_DOWNs
@(private = "file")
target: u64 // its target tab (0: none)
@(private = "file")
pasted: [dynamic]u64 // tab_paste's tabs, in order

@(private = "file")
TEST_COVER :: Cover_Hooks {
	event = proc(e: ^sapp.Event) -> bool {
		// ⌘W closes it (taken); ⌘K closes it and goes on below; everything else is its own
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
		#partial switch e.type {
		case .FOCUSED, .UNFOCUSED, .RESIZED: return false
		}
		append(&got, e.type)
		if e.type == .KEY_DOWN do append(&got_keys, e.key_code)
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
	clear(&got_keys)
	clear(&pasted)
	target = 0
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "There", pk_tab(201))
	state.current_session = 100
	under = pk_view(101, 80, 24)
	over = pk_view(201, 80, 24)
	tab_paste_hook = proc(tab: u64, text: string) {append(&pasted, tab)}
	return
}

@(private = "file")
send :: proc(type: sapp.Event_Type, k: sapp.Keycode = .INVALID, mods: u32 = 0, repeat := false, ch: rune = 0) {
	e := sapp.Event{type = type, key_code = k, modifiers = mods, key_repeat = repeat, char_code = u32(ch)}
	event(&e)
}

@(private = "file")
vt :: proc(v: ^Term_View, s: string) {gh.terminal_vt_write(v.gt, raw_data(s), len(s))}

// Open: the terminal under it gets the releases of the keys held before (kitty's release events),
// its mouse press's release and a focus-out; menus close; a palette that had the keyboard closes
// and is not given it back.
@(test)
cover_open_lets_go_of_what_was_held :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	under, over := setup()
	defer pk_reset()
	_ = over
	testing.expect(t, key_view() == under, "the tab on screen has the keyboard")
	vt(under, "\x1b[>11u\x1b[?1000h\x1b[?1006h") // releases reported, mouse tracked
	term_focus(under, true)
	_ = pk_take(101)
	send(.KEY_DOWN, .LEFT) // held
	testing.expect(t, pk_take(101) != "", "the press reached it")
	under.mouse_down, under.mouse_button = true, .Left
	menu.open = true

	cover_open(TEST_COVER)
	sent := pk_take(101)
	testing.expect(t, strings.contains(sent, ":3D"), "the held ← is released")
	testing.expect(t, strings.contains(sent, "\x1b[<0;"), "the mouse press is released")
	testing.expect(t, !under.focused, "and it loses focus")
	testing.expect(t, !under.mouse_down && !menu.open, "no press, no menu")

	// the held key's release is the cover's to swallow: neither under nor in it
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
// target, or nowhere); the field and the terminal under it get nothing.
@(test)
cover_takes_every_input_path :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	under, over := setup()
	defer pk_reset()
	_ = under
	state.sidebar.view = .Attention
	filter_focus()
	core.inbox_drain()
	target = 201
	cover_open(TEST_COVER)
	pk_key(.X, 0, 'x')
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
	m, _ = cover_marked()
	testing.expect_value(t, m, "")
	// a paste (⌘V, as sokol and the Edit menu send it): the target's
	send(.KEY_DOWN, .V, sapp.MODIFIER_SUPER)
	send(.CLIPBOARD_PASTED)
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	testing.expect_value(t, len(pasted), 1)
	testing.expect(t, len(pasted) == 1 && pasted[0] == 201, "pasted into the target")
	testing.expect_value(t, tf_text(&filter_field), "")
	testing.expect_value(t, edit_target(), Edit_Target.Terminal)
	h, covered := cover_hit()
	testing.expect(t, covered && h == Hit(Hit_Peek(.Close)), "the cover's hits only")
	testing.expect(t, cover_action("close_tab") && cover_is_open(), "its own action")
	testing.expect_value(t, len(find_session(100).tabs), 1)
	// no target: text, a composition's end and a paste go nowhere
	target = 0
	ime_commit("y")
	send(.CLIPBOARD_PASTED)
	testing.expect_value(t, len(pasted), 1)
	testing.expect_value(t, edit_target(), Edit_Target.None)
	testing.expect_value(t, tf_text(&filter_field), "")
	testing.expect_value(t, pk_take(101), "")
	// an action not its own closes it first
	testing.expect(t, !cover_action("new_tab") && !cover_is_open(), "closed, the action goes on")
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "sidebar_filter")
}

// Close: a key held then (the closing ⌘W, an Enter) has its repeats, character and release
// swallowed; pressed again it is a new press. A paste asked for while open reaches the tab it was
// asked for, or nowhere, never what is under it. A chord that closes it and goes on is not
// swallowed.
@(test)
cover_close_swallows_held_keys_and_stale_pastes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	under, over := setup()
	defer pk_reset()
	_ = under
	_ = over
	// holding ⌘W: the first closes the cover, the repeats do not close the tab under it
	cover_open(TEST_COVER)
	send(.KEY_DOWN, .LEFT_SUPER, sapp.MODIFIER_SUPER)
	send(.KEY_DOWN, .W, sapp.MODIFIER_SUPER)
	testing.expect(t, !cover_is_open(), "⌘W closed it")
	for _ in 0 ..< 3 do send(.KEY_DOWN, .W, sapp.MODIFIER_SUPER, repeat = true)
	send(.KEY_UP, .W, sapp.MODIFIER_SUPER)
	send(.KEY_UP, .LEFT_SUPER)
	core.inbox_drain()
	testing.expect_value(t, len(find_session(100).tabs), 1)

	// holding Enter while it closes (its tab went: a frame closes it): nothing types under it
	cover_open(TEST_COVER)
	send(.KEY_DOWN, .ENTER)
	cover_dismiss()
	send(.KEY_DOWN, .ENTER, repeat = true)
	send(.CHAR, ch = '\r')
	send(.KEY_UP, .ENTER)
	testing.expect_value(t, pk_take(101), "")
	pk_key(.ENTER) // pressed again: the terminal's
	testing.expect_value(t, pk_take(101), "\r")

	// a paste asked for while open arrives after it closed: its tab's, not the one under it
	target = 201
	cover_open(TEST_COVER)
	send(.KEY_DOWN, .V, sapp.MODIFIER_SUPER)
	cover_dismiss()
	send(.CLIPBOARD_PASTED)
	testing.expect(t, len(pasted) == 1 && pasted[0] == 201, "the asked-for tab's")
	// and when that tab went: nowhere
	clear(&pasted)
	cover_open(TEST_COVER)
	send(.KEY_DOWN, .V, sapp.MODIFIER_SUPER)
	cover_dismiss()
	target = 0
	pop(&state.open_sessions)
	send(.CLIPBOARD_PASTED)
	testing.expect_value(t, len(pasted), 0)
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	// a paste later, asked for under it: the terminal's
	send(.KEY_DOWN, .V, sapp.MODIFIER_SUPER)
	send(.CLIPBOARD_PASTED)
	send(.KEY_UP, .V, sapp.MODIFIER_SUPER)
	testing.expect(t, len(pasted) == 1 && pasted[0] == 101, "the tab on screen's")

	// ⌘K closes it and goes on: the palette opens
	cover_open(TEST_COVER)
	send(.KEY_DOWN, .K, sapp.MODIFIER_SUPER)
	core.inbox_drain()
	testing.expect(t, !cover_is_open(), "closed")
	testing.expect_value(t, state.focus_widget, "palette")
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
	testing.expect(t, !cover_track(&e), "not swallowed")
	ui_do(core.Set_Focus{""})
	core.inbox_drain()
	target = 201
	cover_open(TEST_COVER)
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
