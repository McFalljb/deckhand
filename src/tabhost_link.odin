package main

// The window's side of tab host routing (src/core/tabhost_route.odin; docs/plans/background-core.md
// §10.2, M3-G). The core keeps the tabs' records and sends `tab_host.call` for what only the window
// can do (CEF, an app's process and frames, an editor's buffer, a Markdown view); the window does
// its part (tab_host_apply_app, tabhost.odin) and answers `finished`. It never changes the core's
// records itself: the core changes them from the answer.
//
// What a page, an app or a window worker reports (an address, a title, a popup, an app's exit, a
// screenshot worker's answer) goes back as `tab_host.event`, which the core runs with the tab_host
// caller: answers and records only, never `ui`, so web content cannot confirm anything, change a
// setting or act in another session. A request the window answered pending (an agent's read,
// action, wait or screenshot, an app call) ends with tab_host_finished.
//
// The link is client.odin's: the app's attached window, or the window's unit tests' host link
// (client_attach_host). With neither (test mode's detach_window) nothing is sent: the core already
// answers no_window for the window's tabs.

import "core:fmt"
import "core:sync"
import "core"

// A call from the core (client.odin's client_on_frames, on the main thread).
tab_host_on_call :: proc(text: string) {
	// the thread the core runs on (the app's main thread; the unit tests' own): reports from it
	// are read at once (tab_host_pump)
	if client.host do client.main = sync.current_thread_id()
	c, err := core.tab_host_call_parse(text)
	if err != "" {
		fmt.eprintln("Deckhand: a tab_host.call the window cannot read:", err)
		if c.id != "" do tab_host_raw(core.tab_host_msg_finished(c.id, core.fail(fmt.tprintf("the window cannot read the call: %s", err)), false))
		return
	}
	r, changed := tab_host_apply_app(c.cmd, c.caller, c.request_id, c.tab_id)
	tab_host_raw(core.tab_host_msg_finished(c.id, r, changed))
}

// A request the window answered pending ends (its result goes to the requester). Main thread.
tab_host_finished :: proc(request_id: u64, r: core.Result, private := false) {
	if request_id == 0 do return
	if tab_host_raw(core.tab_host_msg_done(request_id, r, private)) do tab_host_pump()
}

// What a page, an app or a worker reported, queued for the core's next drain. Any thread.
tab_host_report :: proc(cmd: core.Command) {
	text, ok := core.tab_host_msg_event(cmd, "")
	if !ok {
		fmt.eprintln("Deckhand: not a tab host report:", core.command_type(cmd))
		return
	}
	if tab_host_raw(text) do tab_host_pump()
}

// The same, run now, with its result (a popup's tab id). Main thread.
tab_host_report_now :: proc(cmd: core.Command) -> core.Result {
	id := client_next_id()
	text, ok := core.tab_host_msg_event(cmd, id, now = true)
	if !ok do return core.fail("not a tab host report")
	if !tab_host_raw(text) do return core.no_window()
	core.window_link_pump()
	return client_take_result(id)
}

// Sends a message on the window's link. False: no link (nothing is sent).
@(private = "file")
tab_host_raw :: proc(text: string) -> bool {
	if !client_link_up() {
		when core.TEST_HOOKS do fmt.eprintln("[tab_host] no link; not sent:", text[:min(len(text), 120)])
		return false
	}
	client_send_raw(text)
	return true
}

// The core reads what was sent: now on the main thread, else at its next drain.
@(private = "file")
tab_host_pump :: proc() {
	if sync.current_thread_id() == client.main do core.window_link_pump()
	else if core.platform.wake != nil do core.platform.wake()
}
