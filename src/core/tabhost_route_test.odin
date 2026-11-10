package core

// Tab host routing (tabhost_route.odin; design §10.2, M3-G), with a fake window: the core sends
// tab_host.call and takes the window's finished; records change in the core from the answer; no
// window answers no_window at once; a late answer completes the request, a missing one times out;
// the tab_host caller sends its reports and nothing else.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:time"
import cw "../corewire"
import jg "../jsonguard"

@(private = "file")
Fake_Host :: struct {
	end:      cw.Mem_End,
	calls:    [dynamic]string, // the calls' command types, in order
	silent:   bool, // answers nothing (M4: the answer comes later, or never)
	refuse:   bool, // answers ok false
	pending:  bool, // answers pending (an agent's read)
	wait:     time.Duration, // with pending: the window's own wait (wait_ms)
	data:     string, // the answer's data
	end_first: bool, // ends the request (its finished) before it answers the call pending
	last_id:  string, // the last call's id (heap)
	last_rid: u64,
	last_tab: u64,
	events:   [dynamic]Finished_Event, // the finished events the core emitted (results heap)
	opened:   [dynamic]string, // the links it was asked to open (window.request open_url; temp)
	requests: int, // window.requests of any op
}

@(private = "file")
fh: Fake_Host

@(private = "file")
fh_on_frames :: proc() {
	heap := runtime.heap_allocator()
	for {
		f, err := cw.mem_recv(fh.end, context.temp_allocator)
		if err != .None do return
		text := string(f.payload)
		if json_path(text, "type") == "window.request" {
			fh.requests += 1
			id, q, _ := window_request_parse(text)
			if q.op != .Open_Url do continue
			append(&fh.opened, strings.clone(q.text, context.temp_allocator))
			rep := Window_Reply{ok = true}
			if id != "" do fh_send(window_msg_reply(id, &rep))
			continue
		}
		if json_path(text, "type") != "tab_host.call" do continue
		c, perr := tab_host_call_parse(text)
		if perr != "" do panic(perr)
		append(&fh.calls, strings.clone(command_type(c.cmd), heap))
		delete(fh.last_id, heap)
		fh.last_id, fh.last_rid, fh.last_tab = strings.clone(c.id, heap), c.request_id, c.tab_id
		if fh.silent do continue
		if fh.end_first do fh_send(tab_host_msg_done(c.request_id, {ok = true, data = `{"early":true}`}))
		r := Result{ok = !fh.refuse, error = fh.refuse ? "the window says no" : "", created_id = c.tab_id, pending = fh.pending && !fh.refuse, data = fh.data}
		fh_send(tab_host_msg_finished(c.id, r, !fh.refuse, wait = fh.wait))
	}
}

@(private = "file")
fh_send :: proc(text: string) {
	assert(cw.mem_send(fh.end, cw.JSON_CHANNEL, .Data, transmute([]u8)text) == .None)
}

// Two sessions: alpha (a pi tab, a browser tab, an app tab, an editor and a Markdown tab), on
// screen, and beta (a pi tab, a browser tab).
@(private = "file")
fh_begin :: proc(attach := true) -> (a, b, pa, ta, app, ed, md, pb, tb: u64) {
	state = State{}
	heap := runtime.heap_allocator()
	fh = {calls = make([dynamic]string, heap), events = make([dynamic]Finished_Event, heap), opened = make([dynamic]string, context.temp_allocator)}
	window.test_event = proc(ev: Event) {
		if f, is := ev.(Finished_Event); is {
			x := f
			x.result = result_clone(f.result, runtime.heap_allocator())
			append(&fh.events, x)
		}
	}
	mk :: proc(name: string) -> ^Open_Session {
		s := Open_Session{id = new_id(), pi_session_id = strings.clone(name), cwd = strings.clone("/tmp")}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = strings.clone("pi"), status = .Running})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
		return &state.open_sessions[len(state.open_sessions) - 1]
	}
	add :: proc(s: ^Open_Session, kind: Tab_Kind) -> u64 {
		id := new_id()
		append(&s.tabs, Tab{id = id, kind = kind, title = strings.clone("t"), status = .Running})
		return id
	}
	sa := mk("alpha")
	a, pa = sa.id, sa.tabs[0].id
	ta = add(sa, Browser_Tab{url = strings.clone("https://a.example/")})
	app = add(sa, App_Tab{argv = []string{strings.clone("/bin/true")}, cwd = strings.clone("/tmp"), exit_code = -1})
	ed = add(sa, Editor_Tab{path = strings.clone("/tmp/x.txt")})
	md = add(sa, Markdown_Tab{path = strings.clone("/tmp/x.md")})
	sb := mk("beta")
	b, pb = sb.id, sb.tabs[0].id
	tb = add(sb, Browser_Tab{url = strings.clone("https://b.example/")})
	state.current_session = a
	// files no tab shows yet (open_file and markdown_open resolve them in the core)
	fh_dir = fmt.aprintf("%s/deckhand-th-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec, allocator = heap)
	os.make_directory_all(fh_dir)
	_ = os.write_entire_file(fmt.tprintf("%s/new.txt", fh_dir), transmute([]u8)string("x\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/new.md", fh_dir), transmute([]u8)string("# x\n"))
	if attach do fh.end, _ = core_attach_window(fh_on_frames)
	return
}

@(private = "file")
fh_dir: string

@(private = "file")
fh_done :: proc() {
	heap := runtime.heap_allocator()
	core_detach_window()
	window.test_event = nil
	for c in fh.calls do delete(c, heap)
	delete(fh.calls)
	for e in fh.events do result_free(e.result)
	delete(fh.events)
	delete(fh.last_id, heap)
	fh = {}
	inbox_drain()
	state = State{}
	os.remove_all(fh_dir)
	delete(fh_dir, heap)
	fh_dir = ""
}

@(private = "file")
fh_argv := [?]string{"/bin/true"}
@(private = "file")
fh_events := [?]string{`{"event":"x"}`}

// The commands a window hosts, one of each, aimed at alpha's tabs (as a script: the user's rights).
@(private = "file")
fh_routed :: proc(a, ta, app, ed, md, pa: u64) -> []Command {
	list := [?]Command {
		Browser_Open{session = a, url = "https://x.example/"},
		Browser_Navigate{tab_id = ta, url = "https://y.example/"},
		Browser_Reload{tab_id = ta},
		Browser_Stop{tab_id = ta},
		Browser_Zoom{tab_id = ta},
		Browser_Find{tab_id = ta, text = "x"},
		Browser_Tabs{session = a},
		Browser_Read{tab_id = ta},
		Browser_Screenshot{tab_id = ta},
		Browser_Page_Wait{tab_id = ta},
		Browser_Console{tab_id = ta},
		Browser_Click{tab_id = ta, target = {selector = "#b"}},
		Browser_Type{tab_id = ta, text = "hi"},
		Browser_Agent_Stop{tab_id = ta},
		New_App_Tab{session = a, argv = fh_argv[:]},
		App_Restart{tab_id = app},
		App_Input{tab_id = app, events = fh_events[:]},
		App_Call{tab_id = app, method = "tab.describe"},
		App_Screenshot{tab_id = app},
		App_Inspect{tab_id = app, on = true},
		Open_File{path = fmt.tprintf("%s/new.txt", fh_dir), session = a},
		Editor_State{tab_id = ed},
		Save_File{tab_id = ed},
		Goto_Line{tab_id = ed, line = 1},
		Set_Wrap{tab_id = ed, on = true},
		Markdown_Open{path = fmt.tprintf("%s/new.md", fh_dir), session = a},
		Markdown_Set_View{tab_id = md, source = true},
		Markdown_Scroll{tab_id = md, line = 2},
		Terminal_Link{tab_id = pa, url = "https://z.example/"},
	}
	return slice_clone_temp(list[:])
}

@(private = "file")
slice_clone_temp :: proc(x: []Command) -> []Command {
	out := make([]Command, len(x), context.temp_allocator)
	copy(out, x)
	return out
}

// No window: every routed command answers no_window at once (never a hang), and nothing changes.
@(test)
tab_host_no_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, pa, ta, app, ed, md, _, _ := fh_begin(attach = false)
	defer fh_done()
	for c in fh_routed(a, ta, app, ed, md, pa) {
		before := len(find_session(a).tabs)
		v := state.version
		r := run_command(c, {kind = .UI}, 77)
		want := "no_window"
		when ODIN_OS != .Darwin do if strings.has_prefix(command_type(c), "browser_") do want = "browser_not_here" // no window ever runs there
		testing.expectf(t, !r.ok && json_path(r.data, "code") == want, "%s: %v, want %s", command_type(c), r, want)
		testing.expectf(t, !r.pending, "%s: never pending without a window", command_type(c))
		testing.expectf(t, len(find_session(a).tabs) == before && state.version == v, "%s: nothing changed", command_type(c))
	}
	testing.expect_value(t, tab_host_waiting(), 0)
	// what the core keeps itself still works without a window: records and the project's files
	r := run_command(App_Update{tab_id = app, status = .Running}, {kind = .Internal})
	testing.expect(t, r.ok)
	_, tab, _ := find_tab(app)
	testing.expect_value(t, tab.kind.(App_Tab).app_status, App_Status.Running)
	r = run_command(App_Events{tab_id = app}, {kind = .Script})
	testing.expectf(t, r.ok, "app_events without a window: %v", r)
	r = run_command(Keep_Tab{tab_id = ed}, {kind = .Script})
	testing.expectf(t, r.ok, "keep_tab is the record's: %v", r)
}

// Another machine's window (a hub: this core's sessions are viewed from there) hosts none of this
// core's tabs (§8.2): nothing goes to it as a tab_host.call. Browser commands answer
// browser_not_here (this machine has no Deckhand browser now), the rest no_window; never pending,
// nothing changes. (A core with no window on this Mac still answers no_window: one may come back.)
@(test)
tab_host_hub_hosts_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, pa, ta, app, ed, md, _, _ := fh_begin()
	defer fh_done()
	window_link_for_test().hub = true
	defer window_link_for_test().hub = false
	for c in fh_routed(a, ta, app, ed, md, pa) {
		before := len(find_session(a).tabs)
		v := state.version
		r := run_command(c, {kind = .UI}, 77)
		want := strings.has_prefix(command_type(c), "browser_") ? "browser_not_here" : "no_window"
		testing.expectf(t, !r.ok && json_path(r.data, "code") == want, "%s: %v, want %s", command_type(c), r, want)
		if want == "browser_not_here" do testing.expectf(t, strings.contains(r.error, "only on the machine"), "%s: %q", command_type(c), r.error)
		testing.expectf(t, !r.pending, "%s: never pending", command_type(c))
		testing.expectf(t, len(find_session(a).tabs) == before && state.version == v, "%s: nothing changed", command_type(c))
	}
	testing.expectf(t, len(fh.calls) == 0, "nothing went to the hub: %v", fh.calls)
	testing.expect_value(t, tab_host_waiting(), 0)
	// nor any view of this core's tabs (their paths and addresses stay here), nor a link to open
	window_view_open(ta, Browser_Tab{url = "https://a.example/"})
	window_view_open(ed, Editor_Tab{path = "/tmp/x.txt"})
	window_view_goto(ed, 3, "")
	window_view_moved(ed, "/tmp/y.txt")
	window_view_drop(ed)
	testing.expectf(t, fh.requests == 0, "no window.request went to the hub: %d", fh.requests)
}

// With a window: each routed command goes to it as one tab_host.call, and its answer comes back.
@(test)
tab_host_routes_every_command :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, pa, ta, app, ed, md, _, _ := fh_begin()
	defer fh_done()
	cmds := fh_routed(a, ta, app, ed, md, pa)
	for c in cmds {
		n := len(fh.calls)
		r := run_command(c, {kind = .UI}, 88)
		testing.expectf(t, len(fh.calls) == n + 1 && fh.calls[n] == command_type(c), "%s: one call: %v", command_type(c), fh.calls[n:])
		testing.expectf(t, r.ok, "%s: %v", command_type(c), r)
	}
	testing.expect_value(t, tab_host_waiting(), 0)
}

// Records change in the core, from the window's answer: a new tab only when the window made its
// view, under the id the core gave it; a refused navigation leaves the URL.
@(test)
tab_host_records_follow_the_answer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, pa, ta, _, _, _, _, _ := fh_begin()
	defer fh_done()
	state.current_session = b // on screen: beta
	agent := Caller{kind = .Panel, tab_id = pa}
	r := run_command(Browser_Open{url = "https://user:pw@x.example/p"}, agent)
	testing.expectf(t, r.ok && r.created_id == fh.last_tab && r.created_id != 0, "%v (call tab %d)", r, fh.last_tab)
	s, tab, _ := find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == a, "in the agent's own session")
	testing.expect_value(t, tab.kind.(Browser_Tab).url, "https://x.example/p") // no user name or password
	testing.expect_value(t, state.current_session, b) // an agent never changes what the user sees
	// the window refuses: no record
	fh.refuse = true
	n := len(find_session(a).tabs)
	r = run_command(Browser_Open{url = "https://x.example/q"}, agent)
	testing.expect(t, !r.ok)
	testing.expect_value(t, len(find_session(a).tabs), n)
	r = run_command(Browser_Navigate{tab_id = ta, url = "https://moved.example/"}, agent)
	testing.expect(t, !r.ok)
	_, tab, _ = find_tab(ta)
	testing.expect_value(t, tab.kind.(Browser_Tab).url, "https://a.example/")
	fh.refuse = false
	r = run_command(Browser_Navigate{tab_id = ta, url = "https://moved.example/"}, agent)
	testing.expect(t, r.ok)
	_, tab, _ = find_tab(ta)
	testing.expect_value(t, tab.kind.(Browser_Tab).url, "https://moved.example/")
	// the checks are the core's, before any call: another session's tab, a file: address
	calls := len(fh.calls)
	r = run_command(Browser_Read{tab_id = state.open_sessions[1].tabs[1].id}, agent)
	testing.expect_value(t, r.error, "a pi tab drives only its own session's browser tabs")
	r = run_command(Browser_Navigate{tab_id = ta, url = "file:///etc/passwd"}, agent)
	testing.expect_value(t, r.error, "file: addresses are opened by the user only")
	testing.expect_value(t, len(fh.calls), calls)
	// an app the window started: its record (status) in the core
	r = run_command(New_App_Tab{session = a, argv = []string{"/bin/true"}, title = "t"}, {kind = .UI})
	testing.expect(t, r.ok && r.created_id != 0)
	_, tab, _ = find_tab(r.created_id)
	at, is := tab.kind.(App_Tab)
	testing.expect(t, is && at.exit_code == -1 && len(at.argv) == 1 && at.argv[0] == "/bin/true", "the app tab's record")
}

// The window does not answer at once (M4): the agent hears pending, then finished when the answer
// comes (with the record), or timeout at the deadline; a request answered pending ends with the
// window's finished, and only one the core waits for.
@(test)
tab_host_late_answers_and_timeouts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, ta, _, _, _, _, _ := fh_begin()
	defer fh_done()
	fh.silent = true
	r := run_command(Browser_Open{session = a, url = "https://late.example/"}, {kind = .Script}, 501)
	testing.expect(t, r.ok && r.pending, "pending until the window answers")
	tab_id := fh.last_tab
	_, tab, _ := find_tab(tab_id)
	testing.expect(t, tab == nil, "no record yet")
	fh_send(tab_host_msg_finished(fh.last_id, {ok = true, created_id = tab_id}, true))
	window_link_pump()
	if testing.expect_value(t, len(fh.events), 1) {
		testing.expect_value(t, fh.events[0].request_id, 501)
		testing.expect(t, fh.events[0].result.ok && fh.events[0].result.created_id == tab_id)
	}
	_, tab, _ = find_tab(tab_id)
	testing.expect(t, tab != nil, "the record, once the window answered")
	// never answered: timeout
	r = run_command(Browser_Reload{tab_id = ta}, {kind = .Script}, 502)
	testing.expect(t, r.pending)
	tab_host_tick()
	testing.expect_value(t, len(fh.events), 1) // not yet
	tab_host_expire_for_test()
	tab_host_tick()
	if testing.expect_value(t, len(fh.events), 2) {
		testing.expect_value(t, fh.events[1].request_id, 502)
		testing.expect_value(t, json_path(fh.events[1].result.data, "code"), "timeout")
	}
	testing.expect_value(t, tab_host_waiting(), 0)
	// answered pending: the window's finished ends it; one for a request nobody waits for is dropped
	fh.silent, fh.pending = false, true
	r = run_command(Browser_Read{tab_id = ta}, {kind = .Script}, 503)
	testing.expect(t, r.ok && r.pending)
	testing.expect_value(t, tab_host_waiting(), 1)
	fh_send(tab_host_msg_done(999, {ok = true, data = `{"text":"stolen"}`}))
	fh_send(tab_host_msg_done(503, {ok = true, data = `{"text":"hi"}`}, private = true))
	window_link_pump()
	if testing.expect_value(t, len(fh.events), 3) {
		testing.expect_value(t, fh.events[2].request_id, 503)
		testing.expect(t, fh.events[2].private)
		testing.expect_value(t, json_path(fh.events[2].result.data, "text"), "hi")
	}
	// the window goes with a request in flight: it ends with no_window
	r = run_command(Browser_Read{tab_id = ta}, {kind = .Script}, 504)
	testing.expect(t, r.pending)
	core_detach_window()
	if testing.expect_value(t, len(fh.events), 4) {
		testing.expect_value(t, fh.events[3].request_id, 504)
		testing.expect_value(t, json_path(fh.events[3].result.data, "code"), "no_window")
	}
	r = run_command(Browser_Read{tab_id = ta}, {kind = .Script}, 505)
	testing.expect_value(t, json_path(r.data, "code"), ODIN_OS == .Darwin ? "no_window" : "browser_not_here") // no window ever runs on Linux
}

// The tab_host caller (a page's or an app's reports): TAB_HOST_COMMANDS and nothing else, so it
// can never confirm a parked confirmation, change a setting or open a tab in another session.
@(test)
tab_host_caller_is_reports_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, pa, ta, _, _, _, _, tb := fh_begin()
	defer fh_done()
	page := Caller{kind = .Tab_Host}
	// every command type but the reports: refused
	variants := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union).variants
	allowed := 0
	for v in variants {
		cmd: Command
		reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, v.id)
		ok := caller_may(page, cmd)
		listed := false
		for x in TAB_HOST_COMMANDS do if x == v.id do listed = true
		testing.expectf(t, ok == listed, "%v: tab_host may %v", v, ok)
		if ok do allowed += 1
		spec := command_spec(command_type(cmd))
		if spec != nil do testing.expectf(t, !who_allows(.Tab_Host, spec.who), "%s: listed for tab_host", spec.type)
	}
	testing.expect_value(t, allowed, len(TAB_HOST_COMMANDS))
	// a parked confirmation stays parked
	state.settings.confirm_close[.Browser] = .Always
	r := run_command(Close_Tab{tab_id = ta}, {kind = .Control})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	tok := state.pending_confirmations[0].token
	r = run_command(Close_Tab{tab_id = ta, confirm = tok}, page)
	testing.expect_value(t, r.error, "not allowed for this caller")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	_, tab, _ := find_tab(ta)
	testing.expect(t, tab != nil, "the tab is still open")
	// settings: none, and its policy is fixed
	r = run_command(Set_Theme{name = .Warm}, page)
	testing.expect_value(t, r.error, "not allowed for this caller")
	r = run_command(Set_Confirm_Policy{caller = .Tab_Host, class = .Tab_Close, mode = .Auto}, {kind = .UI})
	testing.expect(t, !r.ok, "tab_host's policy is fixed")
	testing.expect_value(t, confirm_mode(page, .Tab_Close), Confirm_Mode.Ask)
	// a popup opens in its opener's session (beta's page, alpha on screen), never another
	r = run_command(Browser_Popup_Open{opener = tb, url = "https://pop.example/"}, page)
	testing.expect(t, r.ok && r.created_id != 0)
	s, _, _ := find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == b, "in the opener's session")
	testing.expect_value(t, state.current_session, a)
	r = run_command(Browser_Popup_Open{opener = pa, url = "https://pop.example/"}, page)
	testing.expect_value(t, r.error, "not a browser tab")
	// over the link: a report runs as tab_host; anything else is refused before it runs
	fh_send(`{"v":1,"type":"tab_host.event","id":"e1","now":true,"command":{"set_theme":{"name":"warm"}}}`)
	window_link_pump()
	testing.expect(t, state.settings.theme != .Warm)
	text, ok := tab_host_msg_event(Browser_Update{tab_id = ta, what = {.Title}, title = "From the page"}, "e2", now = true)
	testing.expect(t, ok)
	fh_send(text)
	window_link_pump()
	_, tab, _ = find_tab(ta)
	testing.expect_value(t, tab.title, "From the page")
	_, ok = tab_host_msg_event(Close_Tab{tab_id = ta}, "e3")
	testing.expect(t, !ok, "the window cannot even encode another command as a report")
	// and no socket token stands for it
	testing.expect(t, !token_caller_ok({kind = .Tab_Host}))
}

// A call's message round trip: the window reads the command and the caller the core sent.
@(test)
tab_host_call_message_round_trip :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	cmd := Command(Browser_Click{tab_id = 9, target = {selector = "ref=e3"}, button = .Right, double = true})
	text := tab_host_msg_call("h1", cmd, {kind = .Panel, tab_id = 4, claude = true}, 12, 0)
	c, err := tab_host_call_parse(text)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.id, "h1")
	testing.expect_value(t, c.request_id, 12)
	testing.expect_value(t, c.caller, Caller{kind = .Panel, tab_id = 4, claude = true})
	got, is := c.cmd.(Browser_Click)
	testing.expect(t, is && got.tab_id == 9 && got.target.selector == "ref=e3" && got.button == .Right && got.double, "the command")
	// a finished's result, data as written
	ft := tab_host_msg_finished("h1", {ok = true, created_id = 5, data = `{"a":[1,2]}`}, true)
	v, _ := jg.parse_string(ft, .JSON, true, context.temp_allocator)
	r, rerr := tab_host_result_read_for_test(v.(json.Object), ft)
	testing.expect_value(t, rerr, "")
	testing.expect(t, r.ok && r.created_id == 5 && r.data == `{"a":[1,2]}`)
	_ = time.Second
}

// Round 1 of the G+H review: a window's own wait (an upload's bar) is the core's backstop too; a
// request the window ended during its own call, or before the core read the call's answer, ends
// once; a late answer keeps private; answers to calls nobody runs are dropped; a link that
// refuses the call answers no_window at once.
@(test)
tab_host_waits_and_ends_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, _, ta, _, _, _, _, _ := fh_begin()
	defer fh_done()
	// an upload's bar may wait 120 s for the user: 90 s on, the core still waits
	fh.pending, fh.wait = true, 180 * time.Second
	r := run_command(Browser_Click{tab_id = ta, target = {selector = "#b"}}, {kind = .Script}, 601)
	testing.expect(t, r.ok && r.pending)
	tab_host_age_for_test(90 * time.Second)
	tab_host_tick()
	testing.expect_value(t, len(fh.events), 0)
	fh_send(tab_host_msg_done(601, {ok = true}))
	window_link_pump()
	if testing.expect_value(t, len(fh.events), 1) do testing.expect(t, fh.events[0].result.ok, "the window's own end")
	// without a wait of its own: the command's (70 s) — 90 s on, timeout
	fh.wait = 0
	r = run_command(Browser_Click{tab_id = ta, target = {selector = "#b"}}, {kind = .Script}, 602)
	tab_host_age_for_test(90 * time.Second)
	tab_host_tick()
	if testing.expect_value(t, len(fh.events), 2) do testing.expect_value(t, json_path(fh.events[1].result.data, "code"), "timeout")
	// ended while its call ran, then answered pending: one finished, never a timeout after it
	fh.end_first = true
	r = run_command(Browser_Read{tab_id = ta}, {kind = .Script}, 603)
	testing.expect(t, r.pending)
	testing.expect_value(t, tab_host_waiting(), 0)
	tab_host_expire_for_test()
	tab_host_tick()
	if testing.expect_value(t, len(fh.events), 3) do testing.expect_value(t, json_path(fh.events[2].result.data, "early"), "true")
	fh.end_first = false
	// M4: the finished comes before the core read the call's answer; then the answer, pending
	fh.silent = true
	r = run_command(Browser_Read{tab_id = ta}, {kind = .Script}, 604)
	id := strings.clone(fh.last_id, context.temp_allocator)
	fh_send(tab_host_msg_done(604, {ok = true, data = `{"text":"hi"}`}))
	window_link_pump()
	if testing.expect_value(t, len(fh.events), 4) {
		testing.expect_value(t, fh.events[3].request_id, 604)
		testing.expect(t, fh.events[3].private, "a read's text is private")
	}
	fh_send(tab_host_msg_finished(id, {ok = true, pending = true}, false))
	window_link_pump()
	tab_host_expire_for_test()
	tab_host_tick()
	testing.expect_value(t, len(fh.events), 4)
	testing.expect_value(t, tab_host_waiting(), 0)
	// a late answer with a page's content: private (the window says so; the core knows it too)
	r = run_command(Browser_Console{tab_id = ta}, {kind = .Script}, 605)
	fh_send(tab_host_msg_finished(fh.last_id, {ok = true, data = `{"lines":["secret"]}`}, false, private = true))
	r = run_command(Browser_Network{tab_id = ta}, {kind = .Script}, 606)
	fh_send(tab_host_msg_finished(fh.last_id, {ok = true, data = `{"requests":["secret"]}`}, false))
	window_link_pump()
	if testing.expect_value(t, len(fh.events), 6) {
		testing.expect(t, fh.events[4].request_id == 605 && fh.events[4].private, "console: private")
		testing.expect(t, fh.events[5].request_id == 606 && fh.events[5].private, "network: private")
	}
	// answers to calls nobody runs (timed out, never sent) are not kept
	fh_send(tab_host_msg_finished("h99999", {ok = true, data = `{"x":1}`}, false))
	fh_send(tab_host_msg_finished(id, {ok = true}, false))
	window_link_pump()
	testing.expect_value(t, tab_host_answers_for_test(), 0)
	// the link refuses the call (closed): no_window at once, nothing waits
	fh.silent = false
	cw.mem_close(fh.end)
	r = run_command(Browser_Reload{tab_id = ta}, {kind = .Script}, 607)
	testing.expect(t, !r.pending, "not pending")
	testing.expect_value(t, json_path(r.data, "code"), "no_window")
	testing.expect_value(t, tab_host_waiting(), 0)
}

// Defence in depth: whatever the window answers, a Markdown link leaves Deckhand only as http,
// https or mailto, and a page's popup opens a file: address only from a file: page.
@(test)
tab_host_links_checked_in_core :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, _, _, _, md, _, tb := fh_begin()
	defer fh_done()
	opened := &fh.opened // the window opens them (window.request open_url)
	fh.data = `{"follow":"external"}`
	for u in ([]string{"file:///etc/passwd", "javascript:alert(1)", "x-app://do", "/etc/hosts"}) {
		r := run_command(Markdown_Follow{tab_id = md, url = u}, {kind = .UI})
		testing.expectf(t, !r.ok, "%s: refused", u)
	}
	testing.expect_value(t, len(opened^), 0)
	r := run_command(Markdown_Follow{tab_id = md, url = "https://ok.example/"}, {kind = .UI})
	testing.expect(t, r.ok)
	r = run_command(Markdown_Follow{tab_id = md, url = "mailto:a@example.invalid"}, {kind = .UI})
	testing.expect(t, r.ok)
	testing.expect_value(t, len(opened^), 2)
	fh.data = ""
	page := Caller{kind = .Tab_Host}
	r = run_command(Browser_Popup_Open{opener = tb, url = "file:///etc/passwd"}, page)
	testing.expect(t, !r.ok, "a web page's popup to a file: address")
	r = run_command(Browser_Popup_Open{opener = tb, url = "https://pop.example/"}, page)
	testing.expect(t, r.ok)
	// a file: page may (the user opened it)
	s := &state.open_sessions[0]
	_ = a
	for &tab in s.tabs do if bt, is := &tab.kind.(Browser_Tab); is {
		delete(bt.url)
		bt.url = strings.clone("file:///tmp/a.html")
		r = run_command(Browser_Popup_Open{opener = tab.id, url = "file:///tmp/b.html"}, page)
		testing.expect(t, r.ok, "from a file: page")
		break
	}
}
