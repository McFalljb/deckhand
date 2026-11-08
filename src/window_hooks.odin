package main

// What the core asks of the window (design §10.2, M2-A): a proc table beside `platform`
// (platform.odin), filled in by main.odin (window_hooks_app). Core files never set app.redraw
// or show a toast themselves; they call these. M3 turns each entry into a message, so the
// table's shape is the message list. Nil entries do nothing (a headless core).

import "core:strings"

Window_Hooks :: struct {
	state_changed:  proc(), // something the window shows changed: draw a frame (was app.redraw = true)
	toast:          proc(text: string, err: bool), // a short line at the bottom of the window (toast.odin)
	// an app tab's frame channel, for its hello (socket.odin): the service name, the channel's
	// key and the GPU's id; ok false = no channel
	frames_info:    proc(tab_id: u64) -> (service: string, key: [32]u8, device: u64, ok: bool),
	// BGRA pixels of a region of an app tab's frame slot (comments.odin's crops); false = none
	frames_read:    proc(tab_id: u64, gen: u32, slot: int, x, y, w, h: int, dst: []u8) -> bool,
	// what the window knows of a tab, for its object in State's JSON (json_write.odin); a
	// headless core writes none of it:
	// a browser tab's page as the window has it (comment mode and markers, zoom, bars and
	// downloads, the agent strip, an upload's ask), written as `,"key":value` members
	browser_json:   proc(b: ^strings.Builder, tab_id: u64),
	// a browser tab's page: open | waiting | unloaded | closed | opening; "" = no page
	browser_page:   proc(tab_id: u64) -> string,
	// an app tab's live frames and Inspect; ok false = no process
	app_view:       proc(tab_id: u64) -> (v: App_View, ok: bool),
	// a Markdown tab's preview: the source line at its top, its links and headings, find
	// matches (-1: no find bar on the preview); ok false = not laid out yet
	md_view:        proc(tab_id: u64, source: bool) -> (line, links, headings, matches: int, ok: bool),
	// browser, app, Markdown and editor commands: the tab's host runs them (commands.odin)
	tab_host_apply: proc(cmd: Command, caller: Caller, request_id: u64) -> (Result, bool),
	test_step:      proc(), // test mode's script step, after the inbox (autotest.odin, core_loop.odin)
}

window: Window_Hooks

// An app tab's window side, for State's JSON (Window_Hooks.app_view).
App_View :: struct {
	frames:   u64, // frames that became the shown one
	inspect:  bool, // Inspect is on (its boxes drawn)
	has_ring: bool, // the ring the app renders into now, its generation and size (px):
	ring_gen: u32,
	ring_w:   int,
	ring_h:   int,
}

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

// A browser tab's page facts the window has, into its object in State (none without a window).
window_browser_json :: proc(b: ^strings.Builder, tab_id: u64) {
	if window.browser_json != nil do window.browser_json(b, tab_id)
}

// A browser tab's page state ("" = no page, or no window).
window_browser_page :: proc(tab_id: u64) -> string {
	if window.browser_page == nil do return ""
	return window.browser_page(tab_id)
}

// An app tab's frames and Inspect (ok false: no process, or no window).
window_app_view :: proc(tab_id: u64) -> (App_View, bool) {
	if window.app_view == nil do return {}, false
	return window.app_view(tab_id)
}

// A Markdown tab's preview numbers (ok false: not laid out, or no window).
window_md_view :: proc(tab_id: u64, source: bool) -> (line, links, headings, matches: int, ok: bool) {
	if window.md_view == nil do return
	return window.md_view(tab_id, source)
}
