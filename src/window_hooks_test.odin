package main

// The core's window hooks (window_hooks.odin): redraws and toasts reach the window only through
// them, once per command that changed State, as app.redraw did.

import "base:runtime"
import "core:testing"
import "core"

@(private = "file")
wh_redraws: int
@(private = "file")
wh_toasts: [dynamic]string

@(private = "file")
wh_fake :: proc() -> core.Window_Hooks {
	h := window_hooks_app()
	h.state_changed = proc() {wh_redraws += 1}
	h.toast = proc(text: string, err: bool) {append(&wh_toasts, text)}
	return h
}

@(private = "file")
wh_reset :: proc() {
	core.inbox_drain()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	wh_redraws = 0
	clear(&wh_toasts)
}

@(test)
window_hooks_redraw_once_per_changed_command :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.window
	defer core.window = saved
	core.window = wh_fake()
	wh_reset()
	r := core.run_command(core.Set_Left_Tab{tab = .Files})
	testing.expect(t, r.ok)
	testing.expect_value(t, wh_redraws, 1)
	// nothing changed: no redraw
	r = core.run_command(core.Set_Left_Tab{tab = .Files})
	testing.expect(t, r.ok)
	testing.expect_value(t, wh_redraws, 1)
	r = core.run_command(core.Get_State{})
	testing.expect_value(t, wh_redraws, 1)
	// a refused command: none either
	r = core.run_command(core.Set_Focus{widget = "no such widget"})
	testing.expect(t, !r.ok)
	testing.expect_value(t, wh_redraws, 1)
	r = core.run_command(core.Set_Layout{left_open = false})
	testing.expect_value(t, wh_redraws, 2)
}

@(test)
window_hooks_toast_goes_through_the_hook :: proc(t: ^testing.T) {
	saved := core.window
	defer core.window = saved
	core.window = wh_fake()
	wh_reset()
	core.window_toast("hello")
	testing.expect_value(t, len(wh_toasts), 1)
	if len(wh_toasts) == 1 do testing.expect_value(t, wh_toasts[0], "hello")
	// no window: nothing shown, nothing breaks
	core.window = {}
	core.window_toast("nobody")
	core.window_state_changed()
	testing.expect_value(t, len(wh_toasts), 1)
	testing.expect_value(t, wh_redraws, 0)
}

@(test)
window_hooks_tab_host_commands_need_a_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.window
	defer core.window = saved
	wh_reset()
	core.window = {}
	r := core.run_command(core.Browser_Tabs{}, {kind = .Script})
	testing.expect(t, !r.ok)
	testing.expect_value(t, r.error, "no window")
	// with one, the window's host answers (no browser tabs: an empty list, not a refusal)
	core.window = window_hooks_app()
	r = core.run_command(core.Browser_Tabs{}, {kind = .Script})
	testing.expect(t, r.error != "no window")
}
