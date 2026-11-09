package main

// Agents read pages (browser_agent.odin; `./build.sh test`): a pi tab reads only its own session's
// browser tabs, the caps, console and network recording off until asked for, a read's text kept
// out of the log and other subscribers, the strip's state. No CEF here (the tabs have no page):
// the page itself (text, outline, hidden values, waits, screenshots, recording) is the scene
// tests/scripts/browser-agent.txt.

import "base:runtime"
import "core:fmt"
import "core:c"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

// Two sessions (alpha on screen, beta), each with its pi tab and a browser tab.
@(private = "file")
ba_reset :: proc() -> (a, b, pa, pb, ta, tb: u64) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	ba_clear()
	for id, _ in browsers do browser_drop(id)
	state^ = core.State{}
	core.platform = {}
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

// The ops and per-tab state the tests left (no page ever answers them here).
@(private = "file")
ba_clear :: proc() {browser_agent_reset()}

@(test)
browser_agent_session_scope :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, pa, pb, ta, tb := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	OWN :: "a pi tab drives only its own session's browser tabs"
	// another session's tab: every reading command is refused for a pi tab
	cmds := []core.Command {
		core.Browser_Read{tab_id = tb},
		core.Browser_Screenshot{tab_id = tb},
		core.Browser_Page_Wait{tab_id = tb, what = "load"},
		core.Browser_Console{tab_id = tb},
		core.Browser_Network{tab_id = tb},
	}
	for c in cmds {
		r := core.run_command(c, pi_a)
		testing.expectf(t, !r.ok && r.error == OWN, "%s on another session's tab: %v", core.command_type(c), r)
	}
	testing.expect_value(t, len(agent_ops), 0)
	testing.expect(t, agent_tab_of(tb) == nil || !(agent_tab_of(tb).want_console || agent_tab_of(tb).want_net), "no recording started on beta's tab")
	r := core.run_command(core.Browser_Comments{tab_id = tb}, pi_a)
	testing.expect(t, !r.ok, "comments of another session's tab")
	r = core.run_command(core.Browser_Comments{session = b}, pi_a)
	testing.expect(t, !r.ok, "comments of another session")
	r = core.run_command(core.Browser_Tabs{session = b}, pi_a)
	testing.expect(t, !r.ok, "another session's tab list")
	// its own: accepted (pending until the page answers)
	r = core.run_command(core.Browser_Read{tab_id = ta, mode = "outline"}, pi_a)
	testing.expect(t, r.ok && r.pending, r.error)
	r = core.run_command(core.Browser_Screenshot{tab_id = ta}, pi_a)
	testing.expect(t, r.ok && r.pending, r.error)
	r = core.run_command(core.Browser_Page_Wait{tab_id = ta, what = "selector", value = "#x"}, pi_a)
	testing.expect(t, r.ok && r.pending, r.error)
	testing.expect_value(t, len(agent_ops), 3)
	// its tab list: alpha's browser tab only, even with beta's around
	r = core.run_command(core.Browser_Tabs{}, pi_a)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.json_path(r.data, "tabs.#"), "1")
	testing.expect_value(t, core.json_path(r.data, "tabs.0.tab_id"), fmt.tprint(ta))
	testing.expect_value(t, core.json_path(r.data, "tabs.0.session"), fmt.tprint(a))
	// beta's pi sees beta's
	r = core.run_command(core.Browser_Tabs{}, {kind = .Panel, tab_id = pb})
	testing.expect_value(t, core.json_path(r.data, "tabs.0.tab_id"), fmt.tprint(tb))
	// a control caller (Atlas) names any session, or sees them all
	r = core.run_command(core.Browser_Tabs{}, {kind = .Control, tab_id = 999})
	testing.expect_value(t, core.json_path(r.data, "tabs.#"), "2")
	r = core.run_command(core.Browser_Tabs{session = b}, {kind = .Control})
	testing.expect_value(t, core.json_path(r.data, "tabs.#"), "1")
	r = core.run_command(core.Browser_Read{tab_id = tb}, {kind = .Control})
	testing.expect(t, r.ok && r.pending, r.error)
	// not a browser tab; an app's program sends nothing
	r = core.run_command(core.Browser_Read{tab_id = pa}, pi_a)
	testing.expect_value(t, r.error, "not a browser tab")
	r = core.run_command(core.Browser_Read{tab_id = ta}, {kind = .App, tab_id = 5})
	testing.expect_value(t, r.error, "not allowed for this caller")
	// Stop is the user's
	r = core.run_command(core.Browser_Agent_Stop{tab_id = ta}, pi_a)
	testing.expect_value(t, r.error, "not allowed for this caller")
	r = core.run_command(core.Browser_Agent_Stop{tab_id = ta}, {kind = .Control})
	testing.expect_value(t, r.error, "not allowed for this caller")
}

@(test)
browser_agent_args_and_caps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	// read: at most 200000 characters, at least 100, 20000 by default
	testing.expect_value(t, agent_read_max(0), AGENT_READ_MAX)
	testing.expect_value(t, agent_read_max(5), 100)
	testing.expect_value(t, agent_read_max(1 << 30), AGENT_READ_LIMIT)
	testing.expect_value(t, agent_read_max(5000), 5000)
	r := core.run_command(core.Browser_Read{tab_id = ta, max = 1 << 30}, pi_a)
	testing.expect(t, r.pending)
	testing.expect_value(t, agent_ops[len(agent_ops) - 1].max, AGENT_READ_LIMIT)
	r = core.run_command(core.Browser_Read{tab_id = ta, mode = "screenshot"}, pi_a)
	testing.expect_value(t, r.error, "mode is text, outline or html")
	// wait: 10 s by default, at most 120 s; a selector or text needs its value
	testing.expect_value(t, agent_wait_timeout(0), AGENT_WAIT_DEFAULT)
	testing.expect_value(t, agent_wait_timeout(10_000_000), AGENT_WAIT_LIMIT)
	r = core.run_command(core.Browser_Page_Wait{tab_id = ta, what = "selector"}, pi_a)
	testing.expect(t, !r.ok)
	r = core.run_command(core.Browser_Page_Wait{tab_id = ta, what = "soon"}, pi_a)
	testing.expect(t, !r.ok)
	r = core.run_command(core.Browser_Screenshot{tab_id = ta, has_rect = true, rect = {0, 0, 0, 10}}, pi_a)
	testing.expect(t, !r.ok)
	// the wire: browser_wait's "for"
	c, err := core.parse_command(`{"type":"browser_wait","tab_id":7,"for":"text","value":"Done","timeout_ms":500}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	w := c.(core.Browser_Page_Wait)
	testing.expect(t, w.what == "text" && w.value == "Done" && w.timeout_ms == 500)
	// a waited-for text (it may be what the user typed) is never in events or the log
	ev := core.command_json(c, redact = true)
	testing.expect(t, !strings.contains(ev, "Done") && strings.contains(ev, `"value_bytes":4`), ev)
	c, err = core.parse_command(`{"type":"browser_screenshot","tab_id":7,"rect":{"x":1,"y":2,"w":30,"h":40}}`, context.temp_allocator)
	testing.expect(t, err == "" && c.(core.Browser_Screenshot).has_rect && c.(core.Browser_Screenshot).rect.w == 30)
}

// Runtime, Log and Network stay off until an agent asks for console or network on that tab; Stop,
// expiry and another origin turn them off again.
@(test)
browser_agent_recording_off_by_default :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	// nothing to send while nothing is wanted
	calls, con, net := agent_capture_calls(false, false, false, false)
	testing.expect(t, len(calls) == 0 && !con && !net)
	// reading, waiting, screenshots and the tab list never start it
	core.run_command(core.Browser_Read{tab_id = ta}, pi_a)
	core.run_command(core.Browser_Page_Wait{tab_id = ta, what = "load"}, pi_a)
	core.run_command(core.Browser_Screenshot{tab_id = ta}, pi_a)
	core.run_command(core.Browser_Tabs{}, pi_a)
	core.run_command(core.Browser_Comments{}, pi_a)
	at := agent_tab_of(ta)
	testing.expect(t, at != nil && !at.want_console && !at.want_net)
	// browser_console: Runtime and Log only
	r := core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.json_path(r.data, "recording.started_now"), "true")
	testing.expect_value(t, core.json_path(r.data, "entries.#"), "0")
	testing.expect(t, at.want_console && !at.want_net)
	calls, con, net = agent_capture_calls(at.want_console, at.want_net, false, false)
	testing.expect_value(t, strings.join(calls[:], ",", context.temp_allocator), "Runtime.enable,Log.enable")
	testing.expect(t, con && !net)
	r = core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	testing.expect_value(t, core.json_path(r.data, "recording.started_now"), "false")
	// browser_network: Network too
	core.run_command(core.Browser_Network{tab_id = ta}, pi_a)
	calls, _, _ = agent_capture_calls(at.want_console, at.want_net, true, false)
	testing.expect_value(t, strings.join(calls[:], ",", context.temp_allocator), "Network.enable")
	// the strip says so
	testing.expect_value(t, core.json_path(core.state_json(), "open_sessions.0.tabs.1.agent.recording"), "console,network")
	// Stop (the user's): off, and the calls turn the domains off
	core.run_command(core.Browser_Agent_Stop{tab_id = ta}, {kind = .UI})
	testing.expect(t, !at.want_console && !at.want_net)
	calls, con, net = agent_capture_calls(at.want_console, at.want_net, true, true)
	testing.expect_value(t, strings.join(calls[:], ",", context.temp_allocator), "Runtime.disable,Log.disable,Network.disable")
	testing.expect(t, !con && !net)
	testing.expect_value(t, len(agent_ops), 0) // Stop ended the read, the wait and the screenshot
	// another origin ends it (the page's origin is where it started)
	testing.expect_value(t, agent_origin("https://Example.com:8443/a?b"), "https://example.com:8443")
	testing.expect_value(t, agent_origin("https://u:p@example.com/x"), "https://example.com")
	testing.expect_value(t, agent_origin("file:///tmp/a.html"), "file://")
	testing.expect_value(t, agent_origin("about:blank"), "about:")
}

// A read's text is the page's: its requester gets it, the log and other subscribers its size.
@(test)
browser_agent_page_text_stays_private :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	ev := core.Finished_Event{request_id = 9, result = {ok = true, data = `{"text":"secret page text"}`}, private = true}
	logged := core.event_json(ev)
	testing.expect(t, !strings.contains(logged, "secret") && strings.contains(logged, `"private_bytes":`), logged)
	testing.expect(t, strings.contains(core.event_json(ev, full = true), "secret page text"))
	plain := core.Finished_Event{request_id = 9, result = {ok = true, data = `{"path":"/x.png"}`}}
	testing.expect(t, strings.contains(core.event_json(plain), "/x.png"))
	_, _ = pa, ta
}

// The strip: an agent's command shows it on the tab (who, what), the user's and a script's do not.
@(test)
browser_agent_strip_state :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, pa, _, ta, tb := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	_ = a
	tab_json :: proc(tab_id: u64) -> string {
		b := strings.builder_make(context.temp_allocator)
		browser_agent_tab_json(&b, tab_id)
		return strings.to_string(b)
	}
	core.run_command(core.Browser_Reload{tab_id = ta}, {kind = .UI})
	testing.expect_value(t, tab_json(ta), "")
	core.run_command(core.Browser_Read{tab_id = ta}, {kind = .Script})
	testing.expect_value(t, tab_json(ta), "")
	ba_clear()
	core.run_command(core.Browser_Read{tab_id = ta}, {kind = .Panel, tab_id = pa})
	testing.expect_value(t, tab_json(ta), `,"agent":{"who":"pi","doing":"reading","busy":true,"recording":""}`)
	core.run_command(core.Browser_Navigate{tab_id = tb, url = "https://b.example/2"}, {kind = .Control})
	testing.expect(t, strings.contains(tab_json(tb), `"doing":"driving"`), tab_json(tb))
	testing.expect(t, strings.contains(tab_json(tb), core.agent_name()), tab_json(tb))
	// Stop: the strip goes, the read ends
	core.run_command(core.Browser_Agent_Stop{tab_id = ta}, {kind = .UI})
	testing.expect_value(t, tab_json(ta), "")
	testing.expect_value(t, agent_tab_of(ta).stops, 1)
}

// Selectors are a small allowlisted grammar (tags, #ids, .classes, joined by spaces or >; or an
// outline's ref=eN): nothing that matches on attributes, state or anything else gets through, so
// no comment, escape or whitespace trick can ask about a field's value.
@(test)
browser_agent_selector_grammar :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	accepted := []string{"div.card > a#buy", "main article p", "ref=e12", "#form", "a#x.y-z_1", "div>p", "h1", "my-el .a-b", " #a ", ".-a", "#_x", "div#a.b.c > p.d"}
	for sel in accepted {
		r := core.run_command(core.Browser_Read{tab_id = ta, selector = sel}, pi_a)
		testing.expectf(t, r.ok && r.pending, "read %q: %v", sel, r)
		r = core.run_command(core.Browser_Page_Wait{tab_id = ta, what = "selector", value = sel}, pi_a)
		testing.expectf(t, r.ok && r.pending, "wait %q: %v", sel, r)
	}
	refused := []string {
		// round 1
		"#card option:checked",
		"#agree:checked",
		`input[type=password][value^="a"]`,
		`[ VALUE = "x" ]`,
		"input:placeholder-shown",
		"form:has(input:checked)",
		`#agree:\63 hecked`,
		`#agree:\:checked`,
		// round 2
		`input[/**/value^="a"]`,
		"input:/**/checked",
		"div/**/p",
		"input\f:checked",
		"div\fp",
		"div\rp",
		"div\tp",
		"div\np",
		`body:has(#ed a[href^="https://x"])`,
		`a[href^="x"]`,
		"a, b",
		"*",
		"div > *",
		"ns|a",
		"a + b",
		"a ~ b",
		"p::before",
		`#a\62`,
		// not an identifier
		".1a",
		"#--x",
		"#-1",
		"1div",
		"div..a",
		"#",
		".",
		"div >",
		"> div",
		"div > > p",
		"   ",
		"ref=e",
		"ref=e1x",
		"ref=e1 p",
		"café",
	}
	for sel in refused {
		r := core.run_command(core.Browser_Read{tab_id = ta, selector = sel}, pi_a)
		testing.expectf(t, !r.ok && core.json_path(r.data, "code") == "selector_unsupported", "read %q: %v", sel, r)
		r = core.run_command(core.Browser_Page_Wait{tab_id = ta, what = "selector", value = sel}, pi_a)
		testing.expectf(t, !r.ok && core.json_path(r.data, "code") == "selector_unsupported", "wait %q: %v", sel, r)
	}
	r := core.run_command(core.Browser_Read{tab_id = ta, selector = "a[x]"}, pi_a)
	testing.expectf(t, strings.contains(r.error, "tag names, #ids and .classes") && strings.contains(r.error, "ref=e"), "the refusal says what is allowed: %q", r.error)
}

// Secret-looking address parameters are masked wherever an agent sees an address: requests, log
// sources, console text, a read's page URL.
@(test)
browser_agent_url_masking :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	b := browser_of(ta)
	a := new(Annot)
	a.tab_id, a.cef, a.ctx = ta, 7, 5
	annots[ta] = a
	defer {
		b.cef = 0
		delete_key(&annots, ta)
		free(a)
		autotest.bg_request, autotest.bg_done = 0, false
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	core.run_command(core.Browser_Network{tab_id = ta}, pi_a)
	core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	at := agent_tab_of(ta)
	b.cef = 7
	at.cap_cef, at.on_console, at.on_net = 7, true, true
	cases := [][2]string {
		{"https://a.example/x?accessToken=abc&page=2", "https://a.example/x?accessToken=***&page=2"},
		{"https://a.example/x?auth_token=abc", "https://a.example/x?auth_token=***"},
		{"https://a.example/#/cb?code=x&y=1", "https://a.example/#/cb?code=***&y=1"},
		{"https://a.example/x?a=1;token=x", "https://a.example/x?a=1;token=***"},
		{"https://a.example/x?acc%65ss_token=x", "https://a.example/x?acc%65ss_token=***"},
		{"https://a.example/x?SAMLResponse=PHN&RelayState=r&ticket=t&jwt=j&session_id=s&x-goog-signature=g&X-Amz-Credential=c&pass=p&q=hello", "https://a.example/x?SAMLResponse=***&RelayState=***&ticket=***&jwt=***&session_id=***&x-goog-signature=***&X-Amz-Credential=***&pass=***&q=hello"},
		{"https://a.example/doc#section-2", "https://a.example/doc#section-2"},
		{"https://a.example/x?q=a&page=3#top", "https://a.example/x?q=a&page=3#top"},
	}
	for cs, i in cases {
		req := fmt.tprintf(`{{"requestId":"m%d","type":"XHR","request":{{"method":"GET","url":"%s"}}}}`, i, cs[0])
		browser_agent_devtools(7, 0, 1, "Network.requestWillBeSent", raw_data(req), c.size_t(len(req)))
		got := len(at.net) > 0 ? at.net[len(at.net) - 1].url : ""
		testing.expectf(t, got == cs[1], "%s -> %s, want %s", cs[0], got, cs[1])
	}
	// console text: addresses in it too
	msg := `{"type":"log","args":[{"type":"string","value":"redirect to https://a.example/cb?code=abc&ok=1 done"}]}`
	browser_agent_devtools(7, 0, 1, "Runtime.consoleAPICalled", raw_data(msg), c.size_t(len(msg)))
	got := len(at.logs) > 0 ? at.logs[len(at.logs) - 1].text : ""
	testing.expect_value(t, got, "redirect to https://a.example/cb?code=***&ok=1 done")
	// a read's page URL
	r := core.run_command(core.Browser_Read{tab_id = ta}, pi_a)
	testing.expect(t, r.pending)
	op := agent_ops[len(agent_ops) - 1]
	op.request_id = 4242 // (run_command gives none here)
	autotest.bg_request = op.request_id
	op.reply = strings.clone(`{"result":{"type":"string","value":"{\"mode\":\"text\",\"text\":\"hi\",\"chars\":2,\"truncated\":false,\"url\":\"https://a.example/cb?state=s1&id_token=t1\",\"title\":\"T\",\"frames\":0}"}}`)
	op.reply_ok = true
	browser_agent_tick()
	testing.expectf(t, core.json_path(autotest.last_finished, "data.url") == "https://a.example/cb?state=***&id_token=***", "read result: %s", autotest.last_finished)
	testing.expect_value(t, core.json_path(autotest.last_finished, "data.text"), "hi")
}

// The recording's calls are retried after a failed send without asking for frames meanwhile.
@(test)
browser_agent_retry_no_redraw :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	b := browser_of(ta)
	defer {
		b.cef = 0
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	core.run_command(core.Browser_Console{tab_id = ta}, {kind = .Panel, tab_id = pa})
	at := agent_tab_of(ta)
	at.last = {}
	b.cef = 7
	at.cap_cef = 7
	at.cap_next = time.tick_add(time.tick_now(), time.Hour)
	testing.expect(t, !browser_agent_tick(), "no send was due: no redraw")
}

// Console and network entries go when recording ends (Stop, expiry, another origin): a later call
// from since 0 finds none. What arrives after the cutoff is not kept; addresses lose their secrets.
@(test)
browser_agent_recording_forgets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	b := browser_of(ta)
	defer {
		b.cef = 0
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	at := agent_tab_of(ta)
	fill :: proc(at: ^Agent_Tab) {
		at.seq += 1
		append(&at.logs, Agent_Log{seq = at.seq, level = strings.clone("log"), text = strings.clone("old-secret"), source = strings.clone("")})
		at.seq += 1
		append(&at.net, Agent_Net{seq = at.seq, id = strings.clone("r1"), method = strings.clone("GET"), url = strings.clone("https://bank.example/old"), kind = strings.clone("Document"), mime = strings.clone(""), failed = strings.clone("")})
	}
	count :: proc(pa, ta: u64) -> (string, string) {
		pi_a := core.Caller{kind = .Panel, tab_id = pa}
		con := core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
		net := core.run_command(core.Browser_Network{tab_id = ta}, pi_a)
		return core.json_path(con.data, "entries.#"), core.json_path(net.data, "entries.#")
	}
	// Stop
	core.run_command(core.Browser_Network{tab_id = ta}, pi_a)
	fill(at)
	core.run_command(core.Browser_Agent_Stop{tab_id = ta}, {kind = .UI})
	c1, n1 := count(pa, ta)
	testing.expectf(t, c1 == "0" && n1 == "0", "after Stop: console %s, network %s", c1, n1)
	// expiry
	fill(at)
	at.capture_until = time.tick_add(time.tick_now(), -time.Second)
	browser_agent_tick()
	testing.expect(t, !at.want_console && !at.want_net)
	c1, n1 = count(pa, ta)
	testing.expectf(t, c1 == "0" && n1 == "0", "after expiry: console %s, network %s", c1, n1)
	// another origin (recording started on https://a.example)
	testing.expect_value(t, at.capture_origin, "https://a.example")
	fill(at)
	b.cef = 7
	at.cap_cef, at.on_console, at.on_net = 7, true, true
	nav := `{"frame":{"id":"f","url":"https://bank.example/login"}}`
	browser_agent_devtools(7, 0, 1, "Page.frameNavigated", raw_data(nav), c.size_t(len(nav)))
	testing.expect(t, !at.want_console && !at.want_net)
	testing.expect_value(t, len(at.logs), 0)
	testing.expect_value(t, len(at.net), 0)
	// the domains are still on until the tick turns them off: nothing more is kept
	req := `{"requestId":"r9","type":"Document","request":{"method":"GET","url":"https://bank.example/after"}}`
	browser_agent_devtools(7, 0, 1, "Network.requestWillBeSent", raw_data(req), c.size_t(len(req)))
	testing.expect_value(t, len(at.net), 0)
	// recording again: secret query and fragment values are masked, their names kept
	core.run_command(core.Browser_Network{tab_id = ta}, pi_a)
	core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	at.cap_cef, at.on_console, at.on_net = 7, true, true
	req = `{"requestId":"r10","type":"XHR","request":{"method":"GET","url":"https://a.example/cb?code=abc123&state=xyz&page=2&X-Amz-Signature=deadbeef#access_token=tok999&x=1"}}`
	browser_agent_devtools(7, 0, 1, "Network.requestWillBeSent", raw_data(req), c.size_t(len(req)))
	testing.expect_value(t, len(at.net), 1)
	if len(at.net) == 1 do testing.expect_value(t, at.net[0].url, "https://a.example/cb?code=***&state=***&page=2&X-Amz-Signature=***#access_token=***&x=1")
	lg := `{"entry":{"level":"error","text":"failed","source":"network","url":"https://a.example/x?api_key=k1&Token=t2"}}`
	browser_agent_devtools(7, 0, 1, "Log.entryAdded", raw_data(lg), c.size_t(len(lg)))
	if len(at.logs) == 1 do testing.expect_value(t, at.logs[0].source, "https://a.example/x?api_key=***&Token=***")
}

// Recording that starts on a blank page takes its origin from the first real page (not cut off at
// once); a failed CDP send leaves the domain's state as it was, so it is sent again.
@(test)
browser_agent_recording_edges :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	b := browser_of(ta)
	defer {
		b.cef = 0
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	pi_a := core.Caller{kind = .Panel, tab_id = pa}
	_, tab, _ := core.find_tab(ta)
	bt := &tab.kind.(core.Browser_Tab)
	old := bt.url
	bt.url = "about:blank"
	core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	bt.url = old
	at := agent_tab_of(ta)
	b.cef = 7
	at.cap_cef = 7
	nav := `{"frame":{"id":"f","url":"https://shop.example/"}}`
	browser_agent_devtools(7, 0, 1, "Page.frameNavigated", raw_data(nav), c.size_t(len(nav)))
	testing.expect(t, at.want_console, "a blank page's recording goes on with the first page")
	testing.expect_value(t, at.capture_origin, "https://shop.example")
	nav = `{"frame":{"id":"f","url":"https://other.example/"}}`
	browser_agent_devtools(7, 0, 1, "Page.frameNavigated", raw_data(nav), c.size_t(len(nav)))
	testing.expect(t, !at.want_console, "then another origin ends it")
	// sends fail here (no CEF in unit tests): Runtime.enable is not taken as done
	core.run_command(core.Browser_Console{tab_id = ta}, pi_a)
	at.capture_origin = ""
	browser_agent_tick()
	testing.expect(t, !at.on_console, "a failed Runtime.enable leaves the domain off (sent again)")
	// and a failed Runtime.disable leaves it on (sent again), not off
	at.want_console, at.on_console = false, true
	browser_agent_tick()
	testing.expect(t, at.on_console, "a failed Runtime.disable leaves the domain on (sent again)")
}

// A page that failed to answer is asked again after the poll interval, not on every frame.
@(test)
browser_agent_retry_waits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := ba_reset()
	b := browser_of(ta)
	a := new(Annot)
	a.tab_id, a.cef, a.ctx = ta, 7, 5
	annots[ta] = a
	defer {
		b.cef = 0
		delete_key(&annots, ta)
		free(a)
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	r := core.run_command(core.Browser_Read{tab_id = ta}, {kind = .Panel, tab_id = pa})
	testing.expect(t, r.pending)
	b.cef = 7
	op := agent_ops[0]
	op.reply = strings.clone(`{"message":"Cannot find context with specified id"}`)
	op.reply_ok = false
	browser_agent_tick()
	testing.expect_value(t, len(agent_ops), 1)
	testing.expect(t, op.next_try != {} && time.tick_diff(time.tick_now(), op.next_try) > 0, "the next try waits")
}

// A load wait right after browser_open waits for the new page's document, not the blank one the
// tab starts with (its readyState is "complete" too): browser_open marks the navigation as the
// other navigation commands do. Seen as an empty read under load (browser-read, run at -j 9).
@(test)
browser_agent_open_marks_navigation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, pa, _, _, _ := ba_reset()
	defer {
		ba_clear()
		for id, _ in browsers do browser_drop(id)
	}
	r := core.run_command(core.Browser_Open{session = a, url = "https://c.example"}, {kind = .Panel, tab_id = pa})
	testing.expect(t, r.ok)
	at := agent_tab_of(r.created_id)
	testing.expect(t, at != nil && at.nav_at != {}, "browser_open: a load wait waits for its document")
	// the user's own: no agent state (no strip on a script's or the user's read of it)
	u := core.run_command(core.Browser_Open{session = a, url = "https://d.example"}, {kind = .UI})
	testing.expect(t, agent_tab_of(u.created_id) == nil, "the user's browser_open: no agent state")
}
