package main

// The window's side of tab host routing (tabhost_link.odin, src/core/tabhost_route.odin): in the
// window's unit tests the core reaches the window's tabs over the same link as in the app
// (client_attach_host: the tab host only; `state` stays the core's).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"

// (This file is in every build of the package: only a test build attaches here.)
@(init)
tab_host_unit_attach :: proc "contextless" () {
	when ODIN_TEST {
		context = runtime.default_context()
		client_attach_host()
		app.window_active = true // what the window reports (client_facts): in front, as an app at rest
	}
}

// The window's link off (what the core does with no window), and back on.
tl_host_off :: proc() {client_host_set(false)}
tl_host_on :: proc() {client_host_set(true)}

// Two sessions (alpha on screen, beta), each with its pi tab and a browser tab the user opened.
@(private = "file")
tl_reset :: proc() -> (a, b, pa, pb, ta, tb: u64) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	for id, _ in browsers do browser_drop(id)
	state^ = core.State{}
	core.platform, win_os = {}, {}
	for name in ([]string{"alpha", "beta"}) {
		s := core.Open_Session{id = core.new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
	}
	a, b = state.open_sessions[0].id, state.open_sessions[1].id
	state.current_session = a
	pa, pb = state.open_sessions[0].tabs[0].id, state.open_sessions[1].tabs[0].id
	ta = core.run_command(core.Browser_Open{session = a, url = "https://a.example"}, {kind = .UI}).created_id
	tb = core.run_command(core.Browser_Open{session = b, url = "https://b.example"}, {kind = .UI}).created_id
	return
}

@(private = "file")
tl_done :: proc() {
	browser_agent_reset()
	for id, _ in browsers do browser_drop(id)
}

// A browser_open from an agent reaches the window as tab_host.call: the window makes the page,
// the core its record (in the agent's own session, behind the user's view).
@(test)
tab_host_browser_open_goes_by_message :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, pa, _, _, _ := tl_reset()
	defer tl_done()
	state.current_session = b
	r := core.run_command(core.Browser_Open{url = "https://example.com/x"}, {kind = .Panel, tab_id = pa})
	testing.expectf(t, r.ok, "%v", r)
	s, tab, _ := core.find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == a, "in the agent's own session")
	bt, is := tab.kind.(core.Browser_Tab)
	testing.expect(t, is && bt.url == "https://example.com/x", "the record (the core's)")
	testing.expect(t, browser_of(r.created_id) != nil, "the page (the window's)")
	testing.expect_value(t, state.current_session, b) // the user's view stays
	testing.expect_value(t, core.tab_host_waiting(), 0)
}

// What CEF reports goes to the core as a tab_host.event (the tab_host caller): the record follows,
// the title from the page's.
@(test)
tab_host_page_report_is_the_tab_hosts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, _, _, ta, _ := tl_reset()
	defer tl_done()
	b := browser_of(ta)
	testing.expect(t, b != nil)
	delete(b.title)
	b.title = strings.clone("Page title")
	browser_report({tab_id = ta, what = {.Url}, url = "https://user:pw@example.com/moved"})
	core.inbox_drain()
	_, tab, _ := core.find_tab(ta)
	bt := tab.kind.(core.Browser_Tab)
	testing.expect_value(t, bt.url, "https://example.com/moved") // never a user name or password
	testing.expect_value(t, tab.title, "Page title")
	testing.expect_value(t, b.url, "https://user:pw@example.com/moved") // a reopened page loads this
}
