package main

// What goes on under an overlay that opens or closes (ui_bell.odin popover_repeat_event, #113): a
// key held down stops repeating into the terminal once a popover, a peek, a menu or the palette
// opened over it, also after it closed, until a fresh press; the key that closed one (Esc) does
// not repeat into the terminal under it; a key pressed in an overlay repeats there; a Files drag
// in progress ends when one opens, so its release drops nothing. Window copies (Term_View) with
// no core behind them (peek_test.odin's helpers).

import "base:runtime"
import "core:testing"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
press :: proc(k: sapp.Keycode, ch: rune, repeat := false) {
	e := sapp.Event{type = .KEY_DOWN, key_code = k, key_repeat = repeat}
	event(&e)
	if ch != 0 {
		c := sapp.Event{type = .CHAR, char_code = u32(ch)}
		event(&c)
	}
}

@(private = "file")
release :: proc(k: sapp.Keycode) {
	e := sapp.Event{type = .KEY_UP, key_code = k}
	event(&e)
}

@(private = "file")
focus :: proc(w: string) {
	ui_do(core.Set_Focus{w})
	core.inbox_drain()
}

@(test)
overlay_ends_key_repeat :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "There", pk_tab(201, "waiting", 3 * time.Minute))
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	_ = pk_view(201, 80, 24)

	// j held in the terminal: it repeats there
	press(.J, 'j')
	press(.J, 'j', repeat = true)
	testing.expect_value(t, pk_take(101), "jj")

	// an overlay opens mid-repeat (the bell's popover, the gear's, the palette, a menu, a peek):
	// the repeats go nowhere while it shows, and after it closed, until a fresh press
	open_close := [?]string{"notifications", "settings", "palette", "menu", "peek"}
	for what in open_close {
		switch what {
		case "menu": menu_open(Menu_New{}, {200, 40})
		case "peek": testing.expect(t, peek_open_session(200), "peeks")
		case:        focus(what)
		}
		press(.J, 'j', repeat = true)
		testing.expectf(t, pk_take(101) == "", "%s open: no repeat under it", what)
		testing.expectf(t, pk_take(201) == "", "%s open: nothing to the peeked terminal", what)
		switch what {
		case "menu": menu_close()
		case "peek": peek_close()
		case:        focus("")
		}
		press(.J, 'j', repeat = true)
		press(.J, 'j', repeat = true)
		testing.expectf(t, pk_take(101) == "", "%s closed, j still held: no repeat", what)
		release(.J)
		press(.J, 'j')
		press(.J, 'j', repeat = true)
		testing.expectf(t, pk_take(101) == "jj", "%s: pressed afresh, j repeats again", what)
	}
	release(.J)

	// Esc closes an overlay: its repeats do not reach the terminal under it
	for what in open_close {
		switch what {
		case "menu": menu_open(Menu_New{}, {200, 40})
		case "peek": testing.expect(t, peek_open_session(200), "peeks")
		case:        focus(what)
		}
		press(.ESCAPE, 0)
		core.inbox_drain()
		testing.expectf(t, overlays_shown() == {}, "%s: Esc closed it", what)
		press(.ESCAPE, 0, repeat = true)
		press(.ESCAPE, 0, repeat = true)
		testing.expectf(t, pk_take(101) == "", "%s: Esc's repeats go nowhere", what)
		release(.ESCAPE)
	}

	// a key pressed in an overlay repeats there (the palette's field)
	focus("palette")
	palette_reset()
	press(.A, 'a')
	press(.A, 'a', repeat = true)
	testing.expect_value(t, tf_text(&palette.field), "aa")
	release(.A)
	focus("")
	testing.expect_value(t, pk_take(101), "")
}

// A Files drag in progress when an overlay opens (here the palette, from ⌘K, and the bell's
// popover) ends: its release, and the next click, drop nothing into the terminal.
@(test)
overlay_cancels_files_drag :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101))
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	when core.TEST_HOOKS do for what in ([?]string{"palette", "notifications"}) {
		files_drag_for_test("/tmp/pk-proj/a.txt")
		move := sapp.Event{type = .MOUSE_MOVE, mouse_x = 700, mouse_y = 400, modifiers = sapp.MODIFIER_LMB}
		event(&move)
		testing.expect(t, files_dragging(), "dragging")
		if what == "palette" {
			e := sapp.Event{type = .KEY_DOWN, key_code = .K, modifiers = sapp.MODIFIER_SUPER}
			event(&e)
			core.inbox_drain()
			testing.expect(t, palette_is_open(), "⌘K opened the palette")
		} else do focus(what)
		event(&move)
		testing.expectf(t, !files_dragging(), "%s opened: the drag ended", what)
		focus("")
		pk_mouse(.MOUSE_UP, 700, 400)
		pk_mouse(.MOUSE_DOWN, 700, 400)
		pk_mouse(.MOUSE_UP, 700, 400)
		testing.expectf(t, pk_take(101) == "", "%s: nothing dropped into the terminal", what)
	}
}

// An app tab on screen lets go of its keys while a peek shows, as under a popover (a key held in
// it would stay down there).
@(test)
overlay_peek_app_lets_go :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101))
	pk_session(200, "There", pk_tab(201, "waiting", 3 * time.Minute))
	state.current_session = 100
	_ = pk_view(201, 80, 24)
	a := App_Proc{tab_id = 101, pid = 1}
	testing.expect(t, app_wants_keys(&a), "the app on screen has the keys")
	testing.expect(t, peek_open_session(200), "peeks")
	testing.expect(t, !app_wants_keys(&a), "not while a peek shows")
	peek_close()
	testing.expect(t, app_wants_keys(&a), "back after it")
}

// The Deck view's Enter opens a session: Enter's repeats do not go on into the terminal it shows.
@(test)
overlay_deck_enter_does_not_repeat :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	pk_reset()
	defer pk_reset()
	pk_session(100, "Here", pk_tab(101, "waiting", 4 * time.Minute))
	pk_session(200, "There", pk_tab(201, "waiting", 3 * time.Minute))
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	_ = pk_view(201, 80, 24)
	deck_toggle()
	core.inbox_drain()
	testing.expect(t, deck_shown(), "the deck shows")
	_ = ui_layout(1300, 800)
	press(.DOWN, 0)
	release(.DOWN)
	press(.ENTER, '\r')
	core.inbox_drain()
	testing.expect(t, !deck_shown() && state.current_session != 0, "Enter opened a session")
	_ = ui_layout(1300, 800)
	press(.ENTER, '\r', repeat = true)
	press(.ENTER, '\r', repeat = true)
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, pk_take(201), "")
	release(.ENTER)
	press(.X, 'x')
	release(.X)
	testing.expect_value(t, pk_take(state.current_session + 1), "x")
}
