package main

// What the core asks of the window (design §10.2, M2-A): a proc table beside `platform`
// (platform.odin), filled in by main.odin (window_hooks_app). Core files never set app.redraw
// or show a toast themselves; they call these. M3 turns each entry into a message, so the
// table's shape is the message list. Nil entries do nothing (a headless core).

Window_Hooks :: struct {
	state_changed:  proc(), // something the window shows changed: draw a frame (was app.redraw = true)
	toast:          proc(text: string, err: bool), // a short line at the bottom of the window (toast.odin)
	// an app tab's frame channel, for its hello (socket.odin): the service name, the channel's
	// key and the GPU's id; ok false = no channel
	frames_info:    proc(tab_id: u64) -> (service: string, key: [32]u8, device: u64, ok: bool),
	// BGRA pixels of a region of an app tab's frame slot (comments.odin's crops); false = none
	frames_read:    proc(tab_id: u64, gen: u32, slot: int, x, y, w, h: int, dst: []u8) -> bool,
	// browser, app, Markdown and editor commands: the tab's host runs them (commands.odin)
	tab_host_apply: proc(cmd: Command, caller: Caller, request_id: u64) -> (Result, bool),
	test_step:      proc(), // test mode's script step, after the inbox (autotest.odin, core_loop.odin)
}

window: Window_Hooks

// Something the window shows changed: it draws a frame soon.
window_state_changed :: proc() {
	if window.state_changed != nil do window.state_changed()
}

// A short line at the bottom of the window (what a menu choice did, or why not).
window_toast :: proc(text: string, err := false) {
	if window.toast != nil do window.toast(text, err)
}

// A browser, app, Markdown or editor command: its tab's host runs it (the window's, today in
// process; M3-G routes it). No window: refused.
window_tab_host_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (Result, bool) {
	if window.tab_host_apply == nil do return fail("no window"), false
	return window.tab_host_apply(cmd, caller, request_id)
}
