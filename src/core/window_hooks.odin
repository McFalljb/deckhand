package core

// What the core asks of the window, and what it knows of it (design §10.2; M3-F2). Every entry is
// a message on the window's link (window_link.odin), so nothing here calls into the window:
//   - window.request{op} (core -> window): what the core asks the window to do (the clipboard,
//     opening a link, Reveal in Finder, the appearance, a tab's view, the file watcher, the sheets).
//     Most want no answer; the few that do (window_request with a reply) get a window.reply, which
//     in process comes while the request is sent. No window, or no answer: the wrapper answers as
//     if there were no window, at once (the core never waits on it).
//   - window.facts and window.tab_facts (window -> core): what only the window knows (its buffers'
//     unsaved changes, a page's zoom and bars, an app's frames, the first-run sheet, whether it has
//     the keyboard). The window sends them whenever they changed (client.odin), so the core reads
//     its own copy and never asks.
// The table below keeps what is not a message: the redraw signal and test mode's hooks.
//
// The core owns state and records; the window owns views and buffers (design §4). So the core
// never touches an editor, a Markdown view, a browser page, an app's frames or a terminal's
// view: it says that a tab record appeared or went (view_open, view_drop) and reads what the
// window reported (tab_dirty, unsaved_files, job_sheet_holds_quit).

import "core:fmt"
import "core:strings"

Window_Hooks :: struct {
	state_changed: proc(), // something the window shows changed: draw a frame (was app.redraw = true)
	test_step:     proc(), // test mode's script step, after the inbox (autotest.odin, core_loop.odin)
	test_event:    proc(ev: Event), // test mode: every event, as it is emitted (autotest.odin)
	// the window's unit tests over the tab host's link (client_attach_host): it sends its facts
	// now, before each command (the app sends them whenever they change: client.odin)
	test_facts:    proc(),
}

window: Window_Hooks

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

// An app tab's window side, for State's JSON.
App_View :: struct {
	frames:   u64, // frames that became the shown one
	inspect:  bool, // Inspect is on (its boxes drawn)
	has_ring: bool, // the ring the app renders into now, its generation and size (px):
	ring_gen: u32,
	ring_w:   int,
	ring_h:   int,
}

// ---- window.request: what the core asks the window to do ----

Window_Op :: enum u8 {
	None,
	Clipboard_Set, // text onto the clipboard
	Clipboard_Secret, // text onto it marked concealed and transient; reply: ok (marked) and the change count after it
	Clipboard_Clear_If, // clear it if it still holds what count put there
	Open_Url, // a web or mail link in the user's default app; reply: ok (opened)
	Reveal, // path in Finder
	Appearance, // the window's own appearance (mode)
	Copy_Selection, // the window's copy of tab_id's terminal: its selection onto the clipboard; reply: ok (there was one)
	Term_Fit, // the grid tab_id's pane fits; reply: ok, cols, rows, cell
	View_Open, // tab_id's record appeared (kind): the window makes its view, then goes to line or anchor
	View_Goto, // tab_id's view goes to line (0 = stays) or anchor ("" = none)
	View_Drop, // tab_id closed: its view goes
	View_Moved, // tab_id's file moved to path: the buffer follows
	Files_Deleted, // files under path went to the Trash: buffers look at the disk
	Changes_Diff, // a Changes tab's diff area: text, or why there is none (message); of path
	Changes_Rewind, // another file selected: its diff from the top
	Commit_Message_Clear, // a commit made: the message field empties
	Watch_Folder, // watch this project folder (path) too
	Watch_Sync, // the set of folders to watch changed
	Setup_Sheet, // the first-run sheet: setup (and text: why)
	Job_Sheet, // the job_sheet command (job_sheet, caller); reply: result, changed
	Job_Sheet_Saved, // Job_Save's answer (path, message: its error); reply: ok (the sheet closed)
	Job_Sheet_Holds_Quit, // a quit: reply ok when the sheet has changes (it asks to discard them; the quit stops)
	Notify, // a separate core's OS notification (text: title, message: body), shown by the window's own
	Quit, // the core ends on purpose (a quit, Stop All) or let this window go for a newer one (text: why): the window quits too, never reconnects
	App_Boxes, // a separate core: tab_id's app sent new tab.boxes (text: {"boxes":[…]}), drawn while inspected
}

Window_Request :: struct {
	op:        Window_Op,
	tab_id:    u64,
	text:      string,
	path:      string,
	message:   string,
	count:     int,
	line:      int,
	anchor:    string,
	kind:      Tab_Kind,
	mode:      Appearance,
	setup:     Setup_Sheet_Op,
	job_sheet: Job_Sheet,
	caller:    Caller,
}

Window_Reply :: struct {
	ok:      bool,
	count:   int,
	cols:    u16,
	rows:    u16,
	cell:    [2]f32,
	changed: bool,
	result:  Result,
}

// ---- window.facts and window.tab_facts: what only the window knows ----

Window_Facts :: struct {
	active:               bool, // the window has the keyboard
	dpi:                  f32, // framebuffer px per logical px (0 = not known)
	fps:                  int, // the screen it is on: its maximum frames per second (0 = not known)
	scale:                f32, // and its backing scale
	frames_service:       string, // app tabs' frame channels: the service ("" = none) and the GPU's id
	frames_device:        u64,
	job_sheet_open:       bool,
	setup:                Maybe(Setup_State), // the first-run sheet as get_state's focus shows it
	unsaved:              []string, // each buffer with unsaved changes: its file's path ("" = none yet)
	// a window in another process (separate core): what its layout wrote into the core's State in
	// process: the panes' area (w, h px, scale: the room checks) and the shown session's pane rects
	centre:               [3]f32,
	panes:                []Pane_Fact,
	exe:                  string, // a separate core's window: its own executable (the app bundle Deckhand's updates replace)
}

Pane_Fact :: struct {
	session, pane: u64,
	rect, frame:   [4]f32, // Pane.rect and Pane.frame (framebuffer px; not on the state wire)
}

Md_Facts :: struct {
	line, links, headings: int,
	matches:               int, // -1: no find bar on the preview
}

Tab_Facts :: struct {
	browser:    Maybe(Browser_Facts), // a browser tab's page facts (browser_facts.odin)
	page:       string, // a browser tab's page: open | waiting | unloaded | closed | opening ("" = none)
	app:        Maybe(App_View), // an app tab's live frames and Inspect (none: no process)
	frames_key: string, // an app tab's frame channel key, hex ("" = none); only its hello carries it
	md:         Maybe(Md_Facts), // a Markdown tab's preview, once laid out
	dirty:      bool, // an editor tab's buffer has unsaved changes
}

// Something the window shows changed: it draws a frame soon.
window_state_changed :: proc() {
	window_link_dirty() // the window's replica gets it at the next flush (window_link.odin)
	if window.state_changed != nil do window.state_changed()
}

// A short line at the bottom of the window (what a menu choice did, or why not). No window: none.
window_toast :: proc(text: string, err := false) {
	_ = window_link_toast(text, err)
}

window_test_event :: proc(ev: Event) {if window.test_event != nil do window.test_event(ev)}

// ---- requests: with no window, nothing happens and a query answers as if none ----

@(private = "file")
ask :: proc(r: Window_Request) {_, _ = window_link_request(r, false)}

// A window whose core is another process (replica_process): what its own core package asks of the
// window is done there at once (the window sets it: its caches' views, the Changes tab's diff,
// the folders its own models watch). nil: dropped, as with no window.
replica_request: proc(r: Window_Request) -> Window_Reply

window_clipboard_set :: proc(text: string) {ask({op = .Clipboard_Set, text = text})}
// A secret onto the clipboard; ok false: put there plainly (or no window), nothing to clear.
window_clipboard_secret :: proc(text: string) -> (count: int, ok: bool) {
	r, answered := window_link_request({op = .Clipboard_Secret, text = text}, true)
	return r.count, answered && r.ok
}
window_clipboard_clear_if :: proc(count: int) {ask({op = .Clipboard_Clear_If, count = count})}
// False: not opened (or no window).
window_open_url :: proc(url: string) -> bool {
	r, answered := window_link_request({op = .Open_Url, text = url}, true)
	return answered && r.ok
}
window_reveal :: proc(path: string) {ask({op = .Reveal, path = path})}
// A separate core's OS notification goes through the window (none attached: serve shows its own).
window_notify :: proc(title, body: string) {ask({op = .Notify, text = title, message = body})}
// A separate core: the window goes too (it must not reconnect). why: for its log.
window_quit :: proc(why: string) {ask({op = .Quit, text = why})}
// A separate core: an app tab's new tab.boxes for the window to draw (text: {"boxes":[…]}).
window_app_boxes :: proc(tab_id: u64, text: string) {ask({op = .App_Boxes, tab_id = tab_id, text = text})}
window_set_appearance :: proc(mode: Appearance) {ask({op = .Appearance, mode = mode})}
// The window's copy of the tab's terminal: its selection onto the clipboard. False: none (or no window).
window_copy_selection :: proc(tab_id: u64) -> bool {
	r, answered := window_link_request({op = .Copy_Selection, tab_id = tab_id}, true)
	return answered && r.ok
}

window_view_open :: proc(tab_id: u64, kind: Tab_Kind, line := 0, anchor := "") {
	ask({op = .View_Open, tab_id = tab_id, kind = kind, line = line, anchor = anchor})
}
window_view_goto :: proc(tab_id: u64, line: int, anchor: string) {
	_, t, _ := find_tab(tab_id)
	if t == nil do return
	ask({op = .View_Goto, tab_id = tab_id, kind = t.kind, line = line, anchor = anchor})
}
window_view_drop :: proc(tab_id: u64) {ask({op = .View_Drop, tab_id = tab_id})}
window_view_moved :: proc(tab_id: u64, path: string) {ask({op = .View_Moved, tab_id = tab_id, path = path})}
window_files_deleted :: proc(under: string) {ask({op = .Files_Deleted, path = under})}
window_changes_diff :: proc(tab_id: u64, path, text: string, message := "") {
	ask({op = .Changes_Diff, tab_id = tab_id, path = path, text = text, message = message})
}
window_changes_rewind :: proc(tab_id: u64) {ask({op = .Changes_Rewind, tab_id = tab_id})}
window_commit_message_clear :: proc() {ask({op = .Commit_Message_Clear})}
window_watch_folder :: proc(folder: string) {ask({op = .Watch_Folder, path = folder})}
window_watch_sync :: proc() {ask({op = .Watch_Sync})}
window_setup_sheet :: proc(op: Setup_Sheet_Op, why := "") {ask({op = .Setup_Sheet, setup = op, text = why})}

// The grid a new terminal gets from its tab's pane, before its child starts (no window, or no
// pane yet: it keeps its own).
window_term_fit :: proc(t: ^Term, tab_id: u64) {
	r, answered := window_link_request({op = .Term_Fit, tab_id = tab_id}, true)
	if answered && r.ok do term_resize(t, r.cols, r.rows, r.cell.x, r.cell.y)
}

// The job_sheet command: the sheet is the window's (ui_job_sheet.odin).
window_job_sheet :: proc(c: Job_Sheet, caller: Caller) -> (Result, bool) {
	r, answered := window_link_request({op = .Job_Sheet, job_sheet = c, caller = caller}, true)
	if !answered do return fail("no window"), false
	return r.result, r.changed
}
// Job_Save's answer for the sheet: true = it closed.
window_job_sheet_saved :: proc(path, err: string) -> bool {
	r, answered := window_link_request({op = .Job_Sheet_Saved, path = path, message = err}, true)
	return answered && r.ok
}

// ---- facts: what the window last reported (none with no window) ----

// A browser tab's page facts, into its object in State (none without a window).
window_browser_json :: proc(b: ^strings.Builder, tab_id: u64) {
	if f := window_tab_facts(tab_id); f != nil {
		if bf, ok := &f.browser.?; ok do browser_facts_write(b, bf)
	}
}

// A browser tab's page state ("" = no page, or no window).
window_browser_page :: proc(tab_id: u64) -> string {
	if f := window_tab_facts(tab_id); f != nil do return f.page
	return ""
}

// An app tab's frames and Inspect (ok false: no process, or no window).
window_app_view :: proc(tab_id: u64) -> (App_View, bool) {
	if f := window_tab_facts(tab_id); f != nil do if a, ok := f.app.?; ok do return a, true
	return {}, false
}

// A Markdown tab's preview numbers (ok false: not laid out, or no window).
window_md_view :: proc(tab_id: u64) -> (line, links, headings, matches: int, ok: bool) {
	if f := window_tab_facts(tab_id); f != nil do if m, has := f.md.?; has do return m.line, m.links, m.headings, m.matches, true
	return
}

// Buffers with unsaved changes ("" = all; else in that folder). known false: no window to ask
// (a detached or headless core, M4), so it cannot say: a caller asks or refuses, never takes 0.
window_unsaved_files :: proc(under := "") -> (n: int, known: bool) {
	f := window_facts()
	if f == nil do return 0, false
	for p in f.unsaved do if under == "" || (p != "" && wt_within(fs_real(p), under)) do n += 1
	return n, true
}

// What a quit or update prompt says about unsaved files ("" = none to mention).
unsaved_files_note :: proc(n: int, known: bool) -> string {
	if !known do return "No window can say whether open files have unsaved changes; any are lost."
	if n > 0 do return fmt.tprintf("%d file%s with unsaved changes will be lost.", n, n == 1 ? "" : "s")
	return ""
}

// Whether an editor tab's buffer has unsaved changes; not known with no window to ask (callers
// that could lose them ask instead).
window_tab_dirty :: proc(tab_id: u64) -> (dirty, known: bool) {
	if window_facts() == nil do return false, false
	if f := window_tab_facts(tab_id); f != nil do return f.dirty, true
	return false, true
}

window_job_sheet_open :: proc() -> bool {
	f := window_facts()
	return f != nil && f.job_sheet_open
}
// The sheet has changes: it asks to discard them, and the quit stops. No window: nothing holds it.
window_job_sheet_holds_quit :: proc() -> bool {
	r, answered := window_link_request({op = .Job_Sheet_Holds_Quit}, true)
	return answered && r.ok
}
// The first-run sheet as get_state's focus shows it; ok false: none (or no window).
window_setup_state :: proc() -> (Setup_State, bool) {
	if f := window_facts(); f != nil do if s, ok := f.setup.?; ok do return s, true
	return {}, false
}
window_dpi :: proc() -> f32 {
	f := window_facts()
	return f != nil ? f.dpi : 0
}
// The window has the keyboard. No window attached: true, as nobody can say otherwise
// (M4-D: notifications with the window closed).
window_is_active :: proc() -> bool {
	f := window_facts()
	return f == nil || f.active
}
