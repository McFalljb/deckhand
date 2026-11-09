package main

// Browser tabs' navigation (browser_nav.odin; `./build.sh test`): the URL field's normalising,
// the session browser_open picks per caller, a pi tab driving only its own session's tabs, what
// the page reports going into State, and the commands over the wire. No CEF here (a build without
// it): the tabs have their runtime, no page. Same rules as core_test.odin: shared State, one thread.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"

@(test)
browser_url_normalizing :: proc(t: ^testing.T) {
	ok := [][2]string {
		{"https://example.com/a?b#c", "https://example.com/a?b#c"},
		{"  http://example.com  ", "http://example.com"},
		{"HTTPS://Example.com", "HTTPS://Example.com"},
		{"file:///tmp/x.html", "file:///tmp/x.html"},
		{"deckhand-test://web/nav-a.html", "deckhand-test://web/nav-a.html"},
		{"about:blank", "about:blank"},
		// a bare host gets https://
		{"example.com", "https://example.com"},
		{"docs.example.co.uk/path/x?q=1", "https://docs.example.co.uk/path/x?q=1"},
		{"example.com:8443/x", "https://example.com:8443/x"},
		{"10.0.0.5", "https://10.0.0.5"},
		{"bücher.de", "https://bücher.de"},
		// local ones http:// (a dev server rarely has TLS)
		{"localhost", "http://localhost"},
		{"localhost:3000/app", "http://localhost:3000/app"},
		{"127.0.0.1:8080", "http://127.0.0.1:8080"},
		{"[::1]:9000/x", "http://[::1]:9000/x"},
		{"app.localhost:5173", "http://app.localhost:5173"},
	}
	for c in ok {
		got, err := core.browser_url_normalize(c[0])
		testing.expectf(t, err == "" && got == c[1], "%q -> %q (%s), want %q", c[0], got, err, c[1])
	}
	// not addresses: search is not built in yet; schemes Deckhand does not open
	bad := []string{"", "   ", "how to bake bread", "foo", "example", "a.b1", "example.c", ".example.com", "example.com.", "host:port", "host:123456", "javascript:alert(1)", "data:text/html,x", "mailto:a@b.c", "chrome://settings", "ftp://x.org", "about:config", "https://", "ex ample.com", "under_score.com"}
	for b in bad {
		got, err := core.browser_url_normalize(b)
		testing.expectf(t, err != "" && got == "", "%q should be refused, got %q", b, got)
	}
	_, err := core.browser_url_normalize("how to bake bread")
	testing.expect(t, strings.contains(err, "search is not built in"), err)
}

// Two sessions (alpha on screen, beta), each with its pi tab; Home with its own.
@(private = "file")
bn_reset :: proc() -> (a, b, home: u64) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	for id, _ in browsers do browser_drop(id)
	state^ = core.State{}
	core.platform = {}
	for name in ([]string{"alpha", "beta"}) {
		s := core.Open_Session{id = core.new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
	}
	h := core.Open_Session{id = core.new_id(), home = true}
	append(&h.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "Home", status = .Running})
	h.active_tab = h.tabs[0].id
	append(&state.open_sessions, h)
	state.home = h.id
	state.current_session = state.open_sessions[0].id
	return state.open_sessions[0].id, state.open_sessions[1].id, h.id
}

// Fake user:password@ parts, built from pieces so no file holds a whole credential-shaped URL.
@(private = "file")
BN_USER_PW :: "user" + ":" + "pw@"
@(private = "file")
BN_ME_SECRET :: "me" + ":" + "secret@"
@(private = "file")
BN_ALICE :: "alice" + ":" + "hunter2@"

@(private = "file")
bn_session_of :: proc(tab_id: u64) -> u64 {
	s, _, _ := core.find_tab(tab_id)
	return s != nil ? s.id : 0
}

@(private = "file")
bn_pi :: proc(session: u64) -> u64 {return core.find_session(session).tabs[0].id}

// browser_open's session per caller kind: never "whatever is on screen" for an agent.
@(test)
browser_open_session_per_caller :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, home := bn_reset()
	defer for id, _ in browsers do browser_drop(id)
	open :: proc(caller: core.Caller, session: u64, url := "https://example.com") -> core.Result {
		return core.run_command(core.Browser_Open{session = session, url = url}, caller)
	}
	// the user and scripts: the session on screen, or the one named
	r := open({kind = .UI}, 0)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == a, r.error)
	r = open({kind = .UI}, b)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == b, r.error)
	testing.expect_value(t, state.current_session, a) // the view stays
	testing.expect_value(t, core.find_session(b).active_tab, r.created_id) // focused in its session
	r = open({kind = .Script}, 0)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == a, r.error)
	// a pi tab: its own session, even while another is on screen; never another one
	r = open({kind = .Panel, tab_id = bn_pi(b)}, 0)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == b, r.error)
	r = open({kind = .Panel, tab_id = bn_pi(b)}, b)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == b, r.error)
	r = open({kind = .Panel, tab_id = bn_pi(b)}, a)
	testing.expect(t, !r.ok && strings.contains(r.error, "own session"), r.error)
	// a control caller names the session; Atlas (bound to Home's tab) has none of its own
	r = open({kind = .Control}, 0)
	testing.expect(t, !r.ok && strings.contains(r.error, "session is needed"), r.error)
	r = open({kind = .Control}, b)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == b, r.error)
	r = open({kind = .Control, tab_id = bn_pi(home)}, 0)
	testing.expect(t, !r.ok && strings.contains(r.error, "Home"), r.error)
	r = open({kind = .Control, tab_id = bn_pi(home)}, a)
	testing.expect(t, r.ok && bn_session_of(r.created_id) == a, r.error)
	// Deckhand itself names it; an app's program sends no commands
	r = open({kind = .Internal}, 0)
	testing.expect(t, !r.ok, "internal: the session is needed")
	r = open({kind = .App, tab_id = 1}, a)
	testing.expect(t, !r.ok && r.error == "not allowed for this caller", r.error)
	// Home and unknown sessions are refused; the URL is checked
	testing.expect(t, !open({kind = .UI}, home).ok, "Home has no browser tabs")
	testing.expect(t, !open({kind = .UI}, 999999).ok, "no such session")
	r = open({kind = .UI}, a, "two words")
	testing.expect(t, !r.ok && strings.contains(r.error, "not a web address"), r.error)
	// a blank tab is the user's (New browser tab): the URL field gets the keyboard
	r = open({kind = .Script}, a, "")
	testing.expect(t, !r.ok && r.error == "url is needed", r.error)
	r = open({kind = .UI}, a, "")
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.focus_widget, "browser_url")
	_, tab, _ := core.find_tab(r.created_id)
	testing.expect_value(t, tab.kind.(core.Browser_Tab).url, "about:blank")
	testing.expect_value(t, tab.title, "New tab")
	// normalised
	r = open({kind = .UI}, a, "example.org/x")
	_, tab, _ = core.find_tab(r.created_id)
	testing.expect_value(t, tab.kind.(core.Browser_Tab).url, "https://example.org/x")
}

// A pi tab drives its own session's browser tabs only; what the page reports lands in State.
@(test)
browser_tabs_driven_and_reported :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _ := bn_reset()
	defer for id, _ in browsers do browser_drop(id)
	ra := core.run_command(core.Browser_Open{session = a, url = "https://a.example"}, {kind = .UI})
	rb := core.run_command(core.Browser_Open{session = b, url = "https://b.example"}, {kind = .UI})
	testing.expect(t, ra.ok && rb.ok)
	ta, tb := ra.created_id, rb.created_id
	pa := core.Caller{kind = .Panel, tab_id = bn_pi(a)}
	r := core.run_command(core.Browser_Navigate{tab_id = ta, url = "a.example/next"}, pa)
	testing.expect(t, r.ok, r.error)
	_, tab, _ := core.find_tab(ta)
	testing.expect_value(t, tab.kind.(core.Browser_Tab).url, "https://a.example/next")
	for cmd in ([]core.Command{core.Browser_Navigate{tab_id = tb, url = "x.example"}, core.Browser_Back{tb}, core.Browser_Forward{tb}, core.Browser_Reload{tb}, core.Browser_Stop{tb}}) {
		r = core.run_command(cmd, pa)
		testing.expectf(t, !r.ok && strings.contains(r.error, "own session"), "%s on another session's tab: %s", core.command_type(cmd), r.error)
	}
	// not a browser tab
	r = core.run_command(core.Browser_Back{bn_pi(a)}, {kind = .UI})
	testing.expect(t, !r.ok && r.error == "not a browser tab", r.error)
	// no page (no CEF in tests): history is refused, not faked
	r = core.run_command(core.Browser_Back{ta}, pa)
	testing.expect(t, !r.ok, "nothing loaded")
	// what CEF reports: address, title, history
	v := state.version
	core.run_command(core.Browser_Update{tab_id = ta, what = {.Url}, url = "https://a.example/landed"}, {kind = .Internal})
	core.run_command(core.Browser_Update{tab_id = ta, what = {.Nav}, loading = true, can_back = true}, {kind = .Internal})
	if b := browser_of(ta); b != nil do b.title = strings.clone("Landed") // as on_cef_title keeps it
	core.run_command(core.Browser_Update{tab_id = ta, what = {.Title}, title = "Landed"}, {kind = .Internal})
	testing.expect(t, state.version > v)
	_, tab, _ = core.find_tab(ta)
	bt := tab.kind.(core.Browser_Tab)
	testing.expect_value(t, bt.url, "https://a.example/landed")
	testing.expect(t, bt.loading && bt.can_back && !bt.can_forward)
	testing.expect_value(t, tab.title, "Landed")
	sj := core.state_json()
	testing.expect(t, strings.contains(sj, `"url":"https://a.example/landed","loading":true,"can_back":true,"can_forward":false`), sj)
	// a refused popup is shown to agents
	core.run_command(core.Browser_Update{tab_id = ta, what = {.Blocked}, blocked = "https://ads.example/"}, {kind = .Internal})
	testing.expect(t, strings.contains(core.state_json(), `"blocked_popup":"https://ads.example/"`))
	// only Deckhand reports
	r = core.run_command(core.Browser_Update{tab_id = ta, what = {.Url}, url = "https://evil.example"}, {kind = .Script})
	testing.expect(t, !r.ok)
	// over the wire: parsed by name, written back the same
	cmd, err := core.parse_command(`{"type":"browser_open","session":5,"url":"example.com"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, cmd.(core.Browser_Open).url, "example.com")
	_, err = core.parse_command(`{"type":"browser_navigate","tab_id":5}`, context.temp_allocator)
	testing.expect(t, err != "", "url is required")
	_, err = core.parse_command(`{"type":"browser_update","tab_id":5}`, context.temp_allocator)
	testing.expect(t, strings.has_prefix(err, "unknown command"), "internal: not parsed")
	sb := strings.builder_make(context.temp_allocator)
	core.write_command(&sb, core.Browser_Navigate{tab_id = 7, url = "https://x.example"})
	testing.expect_value(t, strings.to_string(sb), `{"type":"browser_navigate","tab_id":7,"url":"https://x.example"}`)
}

// Round 1: a host part with "@" is never local (127.0.0.1@evil.com is evil.com); user:pass@ never
// reaches State or the workspace; file: addresses are the user's only.
@(test)
browser_url_userinfo_and_file :: proc(t: ^testing.T) {
	for b in ([]string{"127.0.0.1@evil.com", "localhost:3000@evil.com/x", BN_USER_PW + "example.com", "a@b.c"}) {
		got, err := core.browser_url_normalize(b)
		testing.expectf(t, err != "" && got == "", "%q should be refused, got %q", b, got)
	}
	cases := [][2]string {
		{"https://" + BN_USER_PW + "example.com/a?q=1#f", "https://example.com/a?q=1#f"},
		{"http://user@localhost:3000/", "http://localhost:3000/"},
		{"https://example.com/p@th?x=a@b", "https://example.com/p@th?x=a@b"}, // not userinfo
		{"https://example.com", "https://example.com"},
		{"about:blank", "about:blank"},
	}
	for c in cases do testing.expectf(t, core.browser_url_public(c[0]) == c[1], "%q -> %q, want %q", c[0], core.browser_url_public(c[0]), c[1])
	a, b, home := bn_reset()
	defer for id, _ in browsers do browser_drop(id)
	r := core.run_command(core.Browser_Open{session = a, url = "file:///etc/hosts"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	ta := r.created_id
	for caller in ([]core.Caller{{kind = .Panel, tab_id = bn_pi(a)}, {kind = .Control}, {kind = .Control, tab_id = bn_pi(home)}, {kind = .Script}}) {
		r = core.run_command(core.Browser_Open{session = a, url = "file:///etc/hosts"}, caller)
		testing.expectf(t, !r.ok && strings.contains(r.error, "file:"), "%v opens a file: address: %s", caller.kind, r.error)
		r = core.run_command(core.Browser_Navigate{tab_id = ta, url = "FILE:///etc/passwd"}, caller)
		testing.expectf(t, !r.ok && strings.contains(r.error, "file:"), "%v navigates to a file: address: %s", caller.kind, r.error)
	}
	_ = b
	// userinfo never lands in State (what the page reports, what a command opens)
	r = core.run_command(core.Browser_Open{session = a, url = "https://" + BN_ME_SECRET + "example.com/x"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Browser_Update{tab_id = ta, what = {.Url}, url = "https://" + BN_ME_SECRET + "example.org/y"}, {kind = .Internal})
	testing.expect(t, !strings.contains(core.state_json(), "secret"), "userinfo in State")
}

// Round 2: which pages get one of CEF's 8 slots (browser_page_plan). Only the user unloads: the
// tab on screen (the user put it there) takes the least recently shown hidden page, its own
// session's first, when no slot is free. Any other tab that wants a page (an agent's, a background
// popup's) loads if a slot is free, else waits; it never unloads anything. No per-session cap.
@(test)
browser_page_planning :: proc(t: ^testing.T) {
	P :: Page_Info
	has :: proc(l: []int, i: int) -> bool {for x in l do if x == i do return true; return false}
	// 1. the visible tab, no slot free: the least recently shown hidden page of its own session goes,
	// though another session's is older
	{
		pages := []P {
			{session = 1, live = true, shown = 10},
			{session = 2, live = true, shown = 5}, // oldest, but another session's
			{session = 1, live = true, shown = 8},
			{session = 1, wants = true, visible = true, shown = 30},
		}
		p := browser_page_plan(pages, 0, context.temp_allocator)
		testing.expect(t, has(p.load[:], 3), "the visible tab loads")
		testing.expect(t, has(p.unload[:], 2) && len(p.unload) == 1, "its own session's oldest hidden page goes")
		testing.expect_value(t, len(p.wait), 0)
	}
	// 2. its own session has no hidden page: the least recently shown anywhere goes
	{
		pages := []P {
			{session = 2, live = true, shown = 10},
			{session = 3, live = true, shown = 5},
			{session = 1, wants = true, visible = true, shown = 30},
		}
		p := browser_page_plan(pages, 0, context.temp_allocator)
		testing.expect(t, has(p.unload[:], 1) && len(p.unload) == 1 && has(p.load[:], 2), "the oldest anywhere goes")
	}
	// 3. no cap: one session with 7 live pages and a free slot unloads nothing
	{
		pages := make([dynamic]P, context.temp_allocator)
		for k in 0 ..< 7 do append(&pages, P{session = 1, live = true, shown = i64(k)})
		pages[6].visible = true
		p := browser_page_plan(pages[:], 1, context.temp_allocator)
		testing.expect(t, len(p.unload) == 0 && len(p.load) == 0 && len(p.wait) == 0, "nothing changes")
	}
	// 4. an agent's browser_open (a hidden tab that wants a page) with free slots: it loads and
	// nothing is unloaded, however many pages its session has
	{
		pages := []P {
			{session = 1, live = true, visible = true, shown = 9},
			{session = 1, live = true, shown = 1},
			{session = 1, live = true, shown = 2},
			{session = 1, live = true, shown = 3},
			{session = 1, live = true, shown = 4},
			{session = 1, wants = true, shown = 10},
		}
		p := browser_page_plan(pages, 3, context.temp_allocator)
		testing.expect(t, has(p.load[:], 5) && len(p.unload) == 0, "loads, nothing goes")
	}
	// 5. an agent's tab with no slot free: it waits and never unloads another page, in its own
	// session or the one on screen; it loads once a slot frees
	{
		pages := []P {
			{session = 1, live = true, visible = true, shown = 9},
			{session = 1, live = true, shown = 1},
			{session = 2, live = true, shown = 0},
			{session = 1, wants = true, shown = 10},
			{session = 2, wants = true, shown = 11},
		}
		p := browser_page_plan(pages, 0, context.temp_allocator)
		testing.expect(t, has(p.wait[:], 3) && has(p.wait[:], 4), "both wait")
		testing.expect(t, len(p.unload) == 0 && len(p.load) == 0, "nothing unloaded")
		p = browser_page_plan(pages, 1, context.temp_allocator)
		testing.expect(t, has(p.load[:], 3) && has(p.wait[:], 4) && len(p.unload) == 0, "the first to ask loads first")
	}
	// 6. the visible tab first: one free slot and an agent's tab also waiting: the visible one gets it
	{
		pages := []P {
			{session = 2, wants = true, shown = 1},
			{session = 1, wants = true, visible = true, shown = 5},
		}
		p := browser_page_plan(pages, 1, context.temp_allocator)
		testing.expect(t, has(p.load[:], 1) && has(p.wait[:], 0) && len(p.unload) == 0, "visible first")
	}
	// 7. pinned (a popup whose browser is on its way) never goes, even when oldest
	{
		pages := []P {
			{session = 1, live = true, pinned = true, shown = 0},
			{session = 1, live = true, shown = 5},
			{session = 1, wants = true, visible = true, shown = 9},
		}
		p := browser_page_plan(pages, 0, context.temp_allocator)
		testing.expect(t, has(p.unload[:], 1) && !has(p.unload[:], 0) && has(p.load[:], 2), "the popup's slot stays")
	}
	// 8. nothing to give (every slot pinned): the visible tab waits
	{
		pages := []P {{session = 1, live = true, pinned = true}, {session = 2, wants = true, visible = true}}
		p := browser_page_plan(pages, 0, context.temp_allocator)
		testing.expect(t, has(p.wait[:], 1) && len(p.unload) == 0)
	}
	// 9. a visible tab that already has its page: nothing happens, whatever is waiting
	{
		pages := []P {{session = 1, live = true, visible = true}, {session = 2, wants = true}}
		p := browser_page_plan(pages, 0, context.temp_allocator)
		testing.expect(t, has(p.wait[:], 1) && len(p.unload) == 0 && len(p.load) == 0)
	}
}

// Round 2: an agent never changes what the user sees: browser_open from a pi tab or a control
// caller leaves its session's active tab (and the session on screen) alone; the user's and a
// script's make the new tab active.
@(test)
browser_agent_open_keeps_view :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _ := bn_reset()
	defer for id, _ in browsers do browser_drop(id)
	pi_a := bn_pi(a)
	r := core.run_command(core.Browser_Open{url = "https://example.com"}, {kind = .Panel, tab_id = pi_a})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.find_session(a).active_tab, pi_a)
	testing.expect_value(t, state.current_session, a)
	r = core.run_command(core.Browser_Open{session = a, url = "https://example.com"}, {kind = .Control})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.find_session(a).active_tab, pi_a)
	r = core.run_command(core.Browser_Open{session = b, url = "https://example.com"}, {kind = .Control})
	testing.expect_value(t, core.find_session(b).active_tab, bn_pi(b))
	testing.expect_value(t, state.current_session, a)
	r = core.run_command(core.Browser_Open{session = a, url = "https://example.com"}, {kind = .UI})
	testing.expect_value(t, core.find_session(a).active_tab, r.created_id)
	r = core.run_command(core.Browser_Open{session = a, url = "https://example.com"}, {kind = .Script})
	testing.expect_value(t, core.find_session(a).active_tab, r.created_id)
}

// Round 2: a typed address's user:pass@ never reaches events (the event log and socket events
// are event_json) nor redacted command JSON.
@(test)
browser_credentials_not_in_events :: proc(t: ^testing.T) {
	U :: "https://" + BN_ALICE + "example.com/x?q=1"
	cmds := []core.Command {
		core.Browser_Open{session = 1, url = U},
		core.Browser_Open{session = 1, url = BN_ALICE + "example.com/x?q=1"}, // typed without a scheme
		core.Browser_Navigate{tab_id = 1, url = U},
		core.Browser_Update{tab_id = 1, what = {.Url}, url = U},
	}
	for c in cmds {
		red := core.command_json(c, redact = true)
		testing.expectf(t, !strings.contains(red, "hunter2") && !strings.contains(red, "alice"), "redacted: %s", red)
		testing.expectf(t, strings.contains(red, "example.com/x?q=1"), "the address stays: %s", red)
		line := core.event_json(core.Command_Event{caller = {kind = .UI}, command = c})
		testing.expectf(t, !strings.contains(line, "hunter2"), "event: %s", line)
		testing.expect(t, strings.contains(core.command_json(c), "hunter2"), "unredacted keeps it (the command itself)")
	}
}
