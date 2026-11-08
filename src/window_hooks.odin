package main

// What the core asks of the window (design §10.2, M2-A): a proc table beside `platform`
// (platform.odin), filled in by main.odin (window_hooks_app). Core files never set app.redraw
// or show a toast themselves; they call these. M3 turns each entry into a message, so the
// table's shape is the message list. Nil entries do nothing (a headless core), and a query
// answers as if there were no window: no buffers, nothing unsaved, no sheet open.
//
// The core owns state and records; the window owns views and buffers (design §4). So the core
// never touches an editor, a Markdown view, a browser page, an app's frames or a terminal's
// view: it reports that a tab record appeared or went (view_open, view_drop) and asks what it
// needs to know (tab_dirty, unsaved_files, job_sheet_holds_quit).

import "core:strings"

Window_Hooks :: struct {
	state_changed:  proc(), // something the window shows changed: draw a frame (was app.redraw = true)
	toast:          proc(text: string, err: bool), // a short line at the bottom of the window (toast.odin)
	// an app tab's frame channel, for its hello (socket.odin): the service name, the channel's
	// key and the GPU's id; ok false = no channel
	frames_info:    proc(tab_id: u64) -> (service: string, key: [32]u8, device: u64, ok: bool),
	// the screen the window is on, for an app tab's hello (socket.odin; any thread): its maximum
	// frames per second and backing scale; ok false = unknown
	display:        proc() -> (fps: int, scale: f32, ok: bool),
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
	test_event:     proc(ev: Event), // test mode: every event, as it is emitted (autotest.odin)

	// ---- tab views: the core keeps the tab records, the window their views ----
	// A tab record appeared (show_file, a restored tab shown, a Changes tab): the window makes its
	// view if it has none (an editor's buffer, a Markdown view, a Changes tab's diff, a browser
	// page that loads when shown), then goes to line or anchor as view_goto.
	view_open:      proc(tab_id: u64, kind: Tab_Kind, line: int, anchor: string),
	// The tab's view goes to a 1-based line (0 = stays) or a Markdown heading id ("" = none).
	view_goto:      proc(tab_id: u64, line: int, anchor: string),
	view_drop:      proc(tab_id: u64), // the tab closed: its view goes (drop_term)
	view_moved:     proc(tab_id: u64, path: string), // its file moved to path (a rename): the buffer follows
	files_deleted:  proc(under: string), // files under this path went to the Trash: buffers check the disk
	// A Changes tab's diff area: the text, or why there is none (message != ""; the text stays);
	// path is what it is of. False: no such view.
	changes_diff:   proc(tab_id: u64, path, text, message: string) -> bool,
	changes_rewind: proc(tab_id: u64), // another file selected: its diff shows from the top
	commit_message_clear: proc(), // a commit made from a Changes tab: its message field empties
	unsaved_files:  proc(under: string) -> int, // buffers with unsaved changes ("" = all; else in that folder)
	tab_dirty:      proc(tab_id: u64) -> bool, // the tab's buffer has unsaved changes
	// The file watcher (editor_watch.odin: FSEvents through the window's shim; its events reach
	// the editors and the file-system model in editor_tick). No window: nothing is watched.
	watch_folder:   proc(folder: string), // watch this project folder too
	watch_sync:     proc(), // the set of folders to watch changed (open files, reload's folders)

	// ---- terminals: the core's Term, the window's Term_View (term_view.odin) ----
	term_view_new:  proc(t: ^Term), // a terminal was made: its view's render state and encoders
	term_view_free: proc(t: ^Term), // before the terminal goes
	term_drag_cancel: proc(t: ^Term), // its terminal is replaced: a drag's tracked ends go
	term_fit:       proc(t: ^Term, tab_id: u64), // size a new terminal to its tab's pane (before its child starts)

	// ---- sheets and the window's own state ----
	job_sheet:      proc(c: Job_Sheet, caller: Caller) -> (Result, bool), // the job_sheet command (ui_job_sheet.odin)
	job_sheet_open: proc() -> bool,
	// the sheet has changes: true, and it asks (the next quit discards them)
	job_sheet_holds_quit: proc() -> bool,
	job_sheet_saved: proc(path, err: string) -> bool, // Job_Save's answer: true = the sheet closed
	setup_sheet:    proc(op: Setup_Sheet_Op, why: string), // the first-run sheet (ui_setup.odin)
	setup_state:    proc() -> (Setup_State, bool), // the sheet as get_state's focus shows it (temp allocated)
	dpi:            proc() -> f32, // framebuffer px per logical px (0 = none)
}

// The first-run sheet as get_state shows it (json_write.odin's setup_json).
Setup_State :: struct {
	step:         Setup_Step,
	steps:        int,
	err:          string, // why Done failed ("" = none)
	acct_show:    bool, // the Claude accounts step is shown
	accounts:     []Setup_Account,
	acct_default: int, // index into accounts
	acct_msg:     string, // the last add's warning or error ("" = none)
}

// What the core tells the first-run sheet.
Setup_Sheet_Op :: enum u8 {
	Begin, // it opens: back to step 1, the folder found again
	Clear_Error, // what held it no longer does
	Detect_Again, // the user's folders may have changed: found again unless they chose
	Failed, // Done's Set_Home_Dir failed: why
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

// ---- the wrappers: with no window, nothing happens and the queries answer as if none ----

window_test_event :: proc(ev: Event) {if window.test_event != nil do window.test_event(ev)}

window_view_open :: proc(tab_id: u64, kind: Tab_Kind, line := 0, anchor := "") {
	if window.view_open != nil do window.view_open(tab_id, kind, line, anchor)
}
window_view_goto :: proc(tab_id: u64, line: int, anchor: string) {
	if window.view_goto != nil do window.view_goto(tab_id, line, anchor)
}
window_view_drop :: proc(tab_id: u64) {if window.view_drop != nil do window.view_drop(tab_id)}
window_view_moved :: proc(tab_id: u64, path: string) {if window.view_moved != nil do window.view_moved(tab_id, path)}
window_files_deleted :: proc(under: string) {if window.files_deleted != nil do window.files_deleted(under)}
window_changes_diff :: proc(tab_id: u64, path, text: string, message := "") -> bool {
	return window.changes_diff != nil && window.changes_diff(tab_id, path, text, message)
}
window_changes_rewind :: proc(tab_id: u64) {if window.changes_rewind != nil do window.changes_rewind(tab_id)}
window_commit_message_clear :: proc() {if window.commit_message_clear != nil do window.commit_message_clear()}
// No window: no buffers, so nothing unsaved.
window_unsaved_files :: proc(under := "") -> int {return window.unsaved_files != nil ? window.unsaved_files(under) : 0}
window_tab_dirty :: proc(tab_id: u64) -> bool {return window.tab_dirty != nil && window.tab_dirty(tab_id)}
window_watch_folder :: proc(folder: string) {if window.watch_folder != nil do window.watch_folder(folder)}
window_watch_sync :: proc() {if window.watch_sync != nil do window.watch_sync()}

window_term_view_new :: proc(t: ^Term) {if window.term_view_new != nil do window.term_view_new(t)}
window_term_view_free :: proc(t: ^Term) {if window.term_view_free != nil do window.term_view_free(t)}
window_term_drag_cancel :: proc(t: ^Term) {if window.term_drag_cancel != nil do window.term_drag_cancel(t)}
window_term_fit :: proc(t: ^Term, tab_id: u64) {if window.term_fit != nil do window.term_fit(t, tab_id)}

window_job_sheet :: proc(c: Job_Sheet, caller: Caller) -> (Result, bool) {
	if window.job_sheet == nil do return fail("no window"), false
	return window.job_sheet(c, caller)
}
window_job_sheet_open :: proc() -> bool {return window.job_sheet_open != nil && window.job_sheet_open()}
// No window: no sheet, so nothing holds the quit.
window_job_sheet_holds_quit :: proc() -> bool {return window.job_sheet_holds_quit != nil && window.job_sheet_holds_quit()}
window_job_sheet_saved :: proc(path, err: string) -> bool {return window.job_sheet_saved != nil && window.job_sheet_saved(path, err)}
window_setup_sheet :: proc(op: Setup_Sheet_Op, why := "") {if window.setup_sheet != nil do window.setup_sheet(op, why)}
window_setup_state :: proc() -> (Setup_State, bool) {
	if window.setup_state == nil do return {}, false
	return window.setup_state()
}
window_dpi :: proc() -> f32 {return window.dpi != nil ? window.dpi() : 0}
