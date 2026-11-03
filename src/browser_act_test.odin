package main

// Agents act on pages (browser_act.odin; `./build.sh test`): who may act on which tab, the
// arguments, the key names, the pages actions are refused on, Take over and Hand back, the user's
// own click or key pausing agents, Stop, the upload bar's gate (nothing goes before Allow; Block,
// the timeout, a file gone by then), agent input never a user gesture, typed text never logged.
// No CEF here (the tabs have no page): the page itself (clicks, typing, the sensitive-field rule,
// downloads, uploads) is the scene tests/scripts/browser-act.txt; the isolated-world script's
// rule and key guard are tests/browser_act_js_test.mjs.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:time"

// Two sessions (alpha on screen, beta), each with its pi tab and a browser tab.
@(private = "file")
act_reset :: proc() -> (a, b, pa, pb, ta, tb: u64) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	browser_agent_reset()
	browser_act_reset()
	for id, _ in browsers do browser_drop(id)
	state = State{}
	platform = {}
	for name in ([]string{"alpha", "beta"}) {
		s := Open_Session{id = new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
	}
	a, b = state.open_sessions[0].id, state.open_sessions[1].id
	state.current_session = a
	pa, pb = state.open_sessions[0].tabs[0].id, state.open_sessions[1].tabs[0].id
	ta = run_command(Browser_Open{session = a, url = "https://a.example"}, {kind = .UI}).created_id
	tb = run_command(Browser_Open{session = b, url = "https://b.example"}, {kind = .UI}).created_id
	return
}

@(private = "file")
act_done :: proc() {
	browser_act_reset()
	browser_agent_reset()
	for id, _ in browsers do browser_drop(id)
	autotest.wait_request = 0
}

@(private = "file")
code_of :: proc(r: Result) -> string {
	i := strings.index(r.data, `"code":"`)
	if i < 0 do return ""
	rest := r.data[i + 8:]
	return rest[:strings.index_byte(rest, '"')]
}

@(private = "file")
tmp_file :: proc(name: string) -> string {
	dir := fmt.tprintf("build/test-data/act-%d", new_id())
	os.make_directory_all(dir)
	p := fmt.tprintf("%s/%s", dir, name)
	_ = os.write_entire_file(p, transmute([]u8)string("x"))
	abs, _ := os.get_absolute_path(p, context.temp_allocator)
	return abs
}

// A pi tab acts only on its own session's browser tabs; its own: accepted, pending.
@(test)
browser_act_session_scope :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, tb := act_reset()
	defer act_done()
	pi_a := Caller{kind = .Panel, tab_id = pa}
	OWN :: "a pi tab drives only its own session's browser tabs"
	f := tmp_file("a.txt")
	paths := []string{f}
	for tab in ([]u64{tb, ta}) {
		cmds := []Command {
			Browser_Click{tab_id = tab, target = {selector = "#buy"}},
			Browser_Type{tab_id = tab, selector = "#name", text = "hi"},
			Browser_Press{tab_id = tab, keys = "Tab"},
			Browser_Scroll{tab_id = tab, dy = 300},
			Browser_Select{tab_id = tab, selector = "#size", label = "Large", has_label = true},
			Browser_Hover{tab_id = tab, target = {x = 10, y = 10, has_xy = true}},
			Browser_Upload{tab_id = tab, selector = "#file", paths = paths},
		}
		for c in cmds {
			r := run_command(c, pi_a)
			if tab == tb do testing.expectf(t, !r.ok && r.error == OWN, "%s on another session's tab: %v", command_type(c), r)
			else do testing.expectf(t, r.ok && r.pending, "%s on its own tab: %v", command_type(c), r)
		}
	}
	testing.expect_value(t, len(act_ops), 7)
	testing.expect(t, browser_act_busy(ta), "acting on alpha's tab")
	testing.expect(t, !browser_act_busy(tb), "nothing on beta's")
}

@(test)
browser_act_args :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	check :: proc(t: ^testing.T, c: Command, pi: Caller, code: string, loc := #caller_location) {
		r := run_command(c, pi)
		testing.expectf(t, !r.ok && code_of(r) == code, "%s: want %s, got %v", command_type(c), code, r, loc = loc)
	}
	// a target: a selector or x,y, not both, not neither (click, hover)
	check(t, Browser_Click{tab_id = ta}, pi, "bad_args")
	check(t, Browser_Click{tab_id = ta, target = {selector = "#a", x = 1, y = 1, has_xy = true}}, pi, "bad_args")
	check(t, Browser_Hover{tab_id = ta}, pi, "bad_args")
	check(t, Browser_Click{tab_id = ta, target = {x = -1, y = 5, has_xy = true}}, pi, "bad_args")
	// selectors: step 7's grammar only (no attributes: no way to pick a field by its state)
	check(t, Browser_Click{tab_id = ta, target = {selector = "input[type=password]"}}, pi, "selector_unsupported")
	check(t, Browser_Type{tab_id = ta, selector = "#pw:focus", text = "x"}, pi, "selector_unsupported")
	check(t, Browser_Select{tab_id = ta, selector = "select option:checked", label = "x", has_label = true}, pi, "selector_unsupported")
	check(t, Browser_Upload{tab_id = ta, selector = "input[type=file]", paths = []string{"/etc/hosts"}}, pi, "selector_unsupported")
	// type: text needed (or a submit); no huge texts
	check(t, Browser_Type{tab_id = ta, selector = "#name"}, pi, "bad_args")
	check(t, Browser_Type{tab_id = ta, text = strings.repeat("x", ACT_TEXT_MAX + 1, context.temp_allocator)}, pi, "bad_args")
	// select: a label or a value, one of them
	check(t, Browser_Select{tab_id = ta, selector = "#size"}, pi, "bad_args")
	check(t, Browser_Select{tab_id = ta, selector = "#size", label = "a", has_label = true, value = "b", has_value = true}, pi, "bad_args")
	check(t, Browser_Select{tab_id = ta, label = "a", has_label = true}, pi, "bad_args")
	// press: known keys only; the clipboard's chords are the user's
	check(t, Browser_Press{tab_id = ta, keys = ""}, pi, "bad_keys")
	check(t, Browser_Press{tab_id = ta, keys = "Hyper+X"}, pi, "bad_keys")
	check(t, Browser_Press{tab_id = ta, keys = "Meta+V"}, pi, "bad_keys")
	check(t, Browser_Press{tab_id = ta, keys = "Tab Meta+C"}, pi, "bad_keys")
	// scroll: something to do
	check(t, Browser_Scroll{tab_id = ta}, pi, "bad_args")
	// upload: absolute paths of regular files, at least one; a directory never
	dir, _ := os.get_absolute_path("build", context.temp_allocator)
	check(t, Browser_Upload{tab_id = ta, selector = "#file"}, pi, "bad_file")
	check(t, Browser_Upload{tab_id = ta, selector = "#file", paths = []string{"relative.txt"}}, pi, "bad_file")
	check(t, Browser_Upload{tab_id = ta, selector = "#file", paths = []string{"/nonexistent/x.txt"}}, pi, "bad_file")
	check(t, Browser_Upload{tab_id = ta, selector = "#file", paths = []string{dir}}, pi, "bad_file")
	check(t, Browser_Upload{tab_id = ta, selector = "#file", paths = []string{"/dev/null"}}, pi, "bad_file")
	check(t, Browser_Upload{tab_id = ta, paths = []string{tmp_file("x.txt")}}, pi, "bad_args")
	testing.expect_value(t, len(act_ops), 0)
}

@(test)
browser_act_keys_parse :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ks, err := act_keys_parse("Shift+Tab ArrowDown ArrowDown Enter")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(ks), 4)
	testing.expect_value(t, ks[0].key, "Tab")
	testing.expect_value(t, ks[0].vk, 9)
	testing.expect_value(t, ks[0].mods, ACT_MOD_SHIFT)
	testing.expect_value(t, ks[1].code, "ArrowDown")
	testing.expect_value(t, ks[3].text, "\r")
	ks, err = act_keys_parse("Meta+A")
	testing.expect_value(t, err, "")
	testing.expect_value(t, ks[0].command, "selectAll")
	testing.expect_value(t, ks[0].text, "")
	ks, err = act_keys_parse("Shift+a")
	testing.expect_value(t, ks[0].text, "A")
	testing.expect_value(t, ks[0].code, "KeyA")
	ks, err = act_keys_parse("Control+Shift+k")
	testing.expect_value(t, ks[0].mods, ACT_MOD_CONTROL | ACT_MOD_SHIFT)
	testing.expect_value(t, ks[0].text, "") // a chord with Control types nothing
	ks, err = act_keys_parse("Space Escape Backspace F5 PageDown 7 /")
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(ks), 7)
	testing.expect_value(t, ks[0].text, " ")
	testing.expect_value(t, ks[3].vk, 116)
	testing.expect_value(t, ks[5].text, "7")
	for bad in ([]string{"", "Hyper+X", "Meta+V", "Cmd+c", "Command+x", "Shift+", "+", "Entr", "é"}) {
		_, e := act_keys_parse(bad)
		testing.expectf(t, e != "", "%q parsed", bad)
	}
	many := strings.repeat("Tab ", ACT_KEYS_MAX + 1, context.temp_allocator)
	_, err = act_keys_parse(many)
	testing.expect(t, err != "", "too many keys")
}

@(test)
browser_act_pages_refused :: proc(t: ^testing.T) {
	for u in ([]string{"https://a.example/x", "http://localhost:3000/", "pidesk-test://web/act.html", "about:blank"}) do testing.expectf(t, act_page_allowed(u), "%s refused", u)
	for u in ([]string{"file:///etc/hosts", "FILE:///x", "chrome://settings", "devtools://devtools/x", "view-source:https://a.example", "chrome-extension://abc/x", "data:text/html,x", "javascript:alert(1)", "about:settings", ""}) do testing.expectf(t, !act_page_allowed(u), "%s allowed", u)
	// a tab on a file: page refuses actions at once
	context.allocator = runtime.heap_allocator()
	a, _, pa, _, _, _ := act_reset()
	defer act_done()
	tf := run_command(Browser_Open{session = a, url = "file:///tmp/x.html"}, {kind = .UI}).created_id
	r := run_command(Browser_Click{tab_id = tf, target = {x = 5, y = 5, has_xy = true}}, {kind = .Panel, tab_id = pa})
	testing.expectf(t, !r.ok && code_of(r) == "page_not_allowed", "%v", r)
}

// Take over: every agent call on the tab returns user_has_control at once (acts, reads,
// navigation), what was running or queued ends with that code; Hand back lets agents in again.
// Only the user's UI may take over or hand back.
@(test)
browser_act_take_over :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	r := run_command(Browser_Agent_Take_Over{tab_id = ta, on = true}, pi)
	testing.expect(t, !r.ok, "a pi tab took over")
	r = run_command(Browser_Agent_Take_Over{tab_id = ta, on = true}, {kind = .Control})
	testing.expect(t, !r.ok, "a control caller took over")
	// a click and a read in flight, a second click queued
	run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi, 101)
	run_command(Browser_Click{tab_id = ta, target = {selector = "#b"}}, pi, 102)
	run_command(Browser_Read{tab_id = ta}, pi, 103)
	ends := make(map[u64]string)
	defer delete(ends)
	act_test_finished = &ends
	defer act_test_finished = nil
	r = run_command(Browser_Agent_Take_Over{tab_id = ta, on = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	for rid in ([]u64{101, 102, 103}) do testing.expectf(t, strings.contains(ends[rid], `"code":"user_has_control"`), "request %d: %q", rid, ends[rid])
	testing.expect_value(t, len(act_ops), 0)
	testing.expect_value(t, len(agent_ops), 0)
	testing.expect(t, agent_tab_of(ta).user_control, "the user has control")
	cmds := []Command {
		Browser_Click{tab_id = ta, target = {selector = "#a"}},
		Browser_Type{tab_id = ta, text = "x"},
		Browser_Press{tab_id = ta, keys = "Tab"},
		Browser_Scroll{tab_id = ta, dy = 10},
		Browser_Read{tab_id = ta},
		Browser_Screenshot{tab_id = ta},
		Browser_Page_Wait{tab_id = ta, what = "load"},
		Browser_Console{tab_id = ta},
		Browser_Network{tab_id = ta},
		Browser_Navigate{tab_id = ta, url = "https://a.example/next"},
		Browser_Reload{tab_id = ta},
	}
	for c in cmds {
		r = run_command(c, pi)
		testing.expectf(t, !r.ok && code_of(r) == "user_has_control", "%s while the user has control: %v", command_type(c), r)
	}
	// the user's own commands still work, and a script's (not an agent)
	r = run_command(Browser_Navigate{tab_id = ta, url = "https://a.example/mine"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	r = run_command(Browser_Read{tab_id = ta}, {kind = .Script})
	testing.expect(t, r.ok && r.pending, r.error)
	// the state and the strip say so
	b := strings.builder_make(context.temp_allocator)
	browser_agent_tab_json(&b, ta)
	testing.expect(t, strings.contains(strings.to_string(b), `"control":"user"`), strings.to_string(b))
	// Hand back
	r = run_command(Browser_Agent_Take_Over{tab_id = ta, on = false}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	r = run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi)
	testing.expect(t, r.ok && r.pending, r.error)
}

// The user's own click or key in the tab while an agent acts there: the agent pauses (as Take
// over); with no action running it does not.
@(test)
browser_act_user_input_pauses :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, tb := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	browser_act_user_input(ta)
	testing.expect(t, agent_tab_of(ta) == nil || !agent_tab_of(ta).user_control, "no action ran: no pause")
	ends := make(map[u64]string)
	defer delete(ends)
	act_test_finished = &ends
	defer act_test_finished = nil
	run_command(Browser_Type{tab_id = ta, selector = "#name", text = "hello"}, pi, 201)
	browser_act_user_input(tb) // another tab: nothing
	testing.expect_value(t, len(act_ops), 1)
	browser_act_user_input(ta)
	testing.expect_value(t, len(act_ops), 0)
	testing.expect(t, strings.contains(ends[201], `"code":"user_has_control"`), ends[201])
	testing.expect(t, agent_tab_of(ta).user_control, "paused until Hand back")
	r := run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi)
	testing.expect_value(t, code_of(r), "user_has_control")
}

// Stop ends the tab's running and queued actions (code stopped), an upload's ask included.
@(test)
browser_act_stop :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	ends := make(map[u64]string)
	defer delete(ends)
	act_test_finished = &ends
	defer act_test_finished = nil
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{tmp_file("u.txt")}}, pi, 301)
	run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi, 302)
	testing.expect(t, act_test_to_bar(ta), "the upload asks")
	testing.expect(t, act_upload_asking(ta) != nil, "the bar shows")
	run_command(Browser_Agent_Stop{tab_id = ta}, {kind = .UI})
	testing.expect(t, strings.contains(ends[301], `"code":"stopped"`), ends[301])
	testing.expect(t, strings.contains(ends[302], `"code":"stopped"`), ends[302])
	testing.expect_value(t, len(act_ops), 0)
	testing.expect(t, act_upload_asking(ta) == nil, "the bar went")
	// Stop does not take control: the agent may act again
	r := run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi)
	testing.expect(t, r.ok, r.error)
}

// The upload bar: nothing is sent before Allow; only the user's UI answers; Block, the timeout and
// a file gone by Allow each end the call without sending anything.
@(test)
browser_act_upload_gate :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	ends := make(map[u64]string)
	defer delete(ends)
	act_test_finished = &ends
	defer act_test_finished = nil
	f := tmp_file("report.pdf")
	// Block
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}, pi, 401)
	testing.expect(t, act_test_to_bar(ta), "asking")
	ask := act_upload_asking(ta)
	testing.expect(t, ask != nil && ask.stage == .Bar, "at the bar")
	b := strings.builder_make(context.temp_allocator)
	browser_act_tab_json(&b, ta)
	testing.expectf(t, strings.contains(strings.to_string(b), `"upload_ask":{"files":["report.pdf"]`), "%s", strings.to_string(b))
	testing.expect(t, !strings.contains(strings.to_string(b), f), "the full path is not in State")
	for _ in 0 ..< 3 do browser_act_tick()
	testing.expect(t, act_upload_asking(ta) != nil && act_upload_asking(ta).stage == .Bar, "still asking: nothing sent")
	r := run_command(Browser_Upload_Answer{tab_id = ta, allow = true}, pi)
	testing.expect(t, !r.ok, "the agent answered its own upload")
	r = run_command(Browser_Upload_Answer{tab_id = ta, allow = true}, {kind = .Control})
	testing.expect(t, !r.ok, "a control caller answered")
	r = run_command(Browser_Upload_Answer{tab_id = ta, allow = false}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	browser_act_tick()
	testing.expect(t, strings.contains(ends[401], `"code":"upload_blocked"`), ends[401])
	testing.expect(t, act_upload_asking(ta) == nil, "no bar")
	// the timeout: waiting_for_user
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}, pi, 402)
	testing.expect(t, act_test_to_bar(ta), "asking")
	act_upload_asking(ta).deadline = time.tick_add(time.tick_now(), -time.Second)
	browser_act_tick()
	testing.expect(t, strings.contains(ends[402], `"code":"waiting_for_user"`), ends[402])
	testing.expect(t, act_upload_asking(ta) == nil, "no bar")
	// Allow, but the file became a directory meanwhile: bad_file, nothing sent
	g := tmp_file("gone.txt")
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{g}}, pi, 403)
	testing.expect(t, act_test_to_bar(ta), "asking")
	os.remove(g)
	os.make_directory(g)
	defer os.remove(g)
	r = run_command(Browser_Upload_Answer{tab_id = ta, allow = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	browser_act_tick()
	testing.expect(t, strings.contains(ends[403], `"code":"bad_file"`), ends[403])
	// Allow with the file there: on to sending (the page's file input; no page here)
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}, pi, 404)
	testing.expect(t, act_test_to_bar(ta), "asking")
	r = run_command(Browser_Upload_Answer{tab_id = ta, allow = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, len(act_ops) == 1 && act_ops[0].stage == .File_El, "allowed: the files go next")
	// no bar, no answer: refused
	act_done()
}

// An agent's actions are never the user's gesture: a download they start asks first, and a
// gesture the user made just before does not carry over to the agent's click.
@(test)
browser_act_not_a_gesture :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	browser_page_input(ta) // the user clicked in the page just now
	cmds := []Command {
		Browser_Click{tab_id = ta, target = {selector = "#dl"}},
		Browser_Press{tab_id = ta, keys = "Enter"},
		Browser_Type{tab_id = ta, text = "x", submit = true},
		Browser_Hover{tab_id = ta, target = {selector = "#dl"}},
		Browser_Scroll{tab_id = ta, dy = 100},
		Browser_Select{tab_id = ta, selector = "#size", label = "Large", has_label = true},
	}
	for c in cmds {
		r := run_command(c, pi)
		testing.expectf(t, r.ok, "%s: %v", command_type(c), r)
	}
	testing.expect(t, page_extra(ta).input_at == {}, "the user's gesture was left for an agent's input")
	testing.expect_value(t, download_take(page_extra(ta), time.tick_now(), 0), Download_Decision.Ask)
}

// What an agent typed and which files it uploads never reach the command log or other
// subscribers (only their size and count); the strip says what it does.
@(test)
browser_act_log_and_strip :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	typed := Browser_Type{tab_id = ta, selector = "#name", text = "s3cret words"}
	b := strings.builder_make(context.temp_allocator)
	browser_act_write(&b, typed, true)
	testing.expect(t, !strings.contains(strings.to_string(b), "s3cret") && strings.contains(strings.to_string(b), `"text_bytes":12`), strings.to_string(b))
	up := Browser_Upload{tab_id = ta, selector = "#file", paths = []string{"/Users/someone/private/tax.pdf"}}
	strings.builder_reset(&b)
	browser_act_write(&b, up, true)
	testing.expect(t, !strings.contains(strings.to_string(b), "private") && strings.contains(strings.to_string(b), `"files":1`), strings.to_string(b))
	run_command(typed, pi)
	strings.builder_reset(&b)
	browser_agent_tab_json(&b, ta)
	testing.expectf(t, strings.contains(strings.to_string(b), `"doing":"typing into"`), "%s", strings.to_string(b))
	testing.expect(t, strings.contains(strings.to_string(b), `"acting":true`), strings.to_string(b))
}

// ---- security review round 1 ----

// The tab's page waits to open (no "Browser not built in" here): its action stays pending.
@(private = "file")
act_page_pending :: proc(tab_id: u64) {
	if b := browser_of(tab_id); b != nil {
		b.message = ""
		b.lazy = false
		b.waiting = false
	}
}

@(private = "file")
ends_new :: proc() -> ^map[u64]string {
	m := new(map[u64]string)
	act_test_finished = m
	return m
}

@(private = "file")
ends_free :: proc(m: ^map[u64]string) {
	act_test_finished = nil
	for _, v in m do delete(v)
	delete(m^)
	free(m)
}

// An action's time counts from when pi-desk accepted it (queued ones too), not from its turn.
@(test)
browser_act_deadline_from_accept :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	ends := ends_new()
	defer ends_free(ends)
	pi := Caller{kind = .Panel, tab_id = pa}
	now := time.tick_now()
	run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi, 501)
	run_command(Browser_Click{tab_id = ta, target = {selector = "#b"}}, pi, 502)
	testing.expect_value(t, len(act_ops), 2)
	for op in act_ops {
		left := time.tick_diff(now, op.deadline)
		testing.expectf(t, left > ACT_TIMEOUT - 5 * time.Second && left <= ACT_TIMEOUT + time.Second, "deadline set at acceptance: %v", left)
	}
	act_ops[0].deadline = time.tick_add(now, -time.Second) // its time ran out before its turn
	browser_act_tick()
	testing.expectf(t, strings.contains(ends[501], `"code":"timeout"`), "%s", ends[501])
}

// While the upload bar asks the user on a tab, agents' new actions there are refused (busy).
@(test)
browser_act_busy_while_bar_asks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	f := tmp_file("a.txt")
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}, pi, 511)
	testing.expect(t, act_test_to_bar(ta), "asking")
	for c in ([]Command{Browser_Click{tab_id = ta, target = {selector = "#buy"}}, Browser_Type{tab_id = ta, selector = "#name", text = "x"}, Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}}) {
		r := run_command(c, pi)
		testing.expectf(t, !r.ok && code_of(r) == "busy", "%s while the bar asks: %v", command_type(c), r)
	}
	testing.expect_value(t, len(act_ops), 1)
}

// The requester's cancel (the socket's cancel line, or its connection closing) ends that request
// only: an action, queued or running, or an agent read.
@(test)
browser_act_request_cancel :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	ends := ends_new()
	defer ends_free(ends)
	pi := Caller{kind = .Panel, tab_id = pa}
	run_command(Browser_Click{tab_id = ta, target = {selector = "#a"}}, pi, 521)
	run_command(Browser_Click{tab_id = ta, target = {selector = "#b"}}, pi, 522)
	run_command(Browser_Read{tab_id = ta}, pi, 523)
	act_page_pending(ta)
	browser_act_tick()
	r := run_command(Request_Cancel{request_id = 522}, {kind = .Internal})
	testing.expect(t, r.ok, r.error)
	testing.expectf(t, strings.contains(ends[522], `"code":"cancelled"`), "the queued one: %s", ends[522])
	testing.expect_value(t, len(act_ops), 1)
	r = run_command(Request_Cancel{request_id = 521}, {kind = .Internal})
	testing.expectf(t, strings.contains(ends[521], `"code":"cancelled"`), "the running one: %s", ends[521])
	r = run_command(Request_Cancel{request_id = 523}, {kind = .Internal})
	testing.expectf(t, strings.contains(ends[523], `"code":"cancelled"`), "a read: %s", ends[523])
	testing.expect_value(t, len(act_ops), 0)
	testing.expect_value(t, len(agent_ops), 0)
	r = run_command(Request_Cancel{request_id = 999}, {kind = .Internal})
	testing.expect(t, !r.ok, "nothing running with that id")
	// not a command anyone else sends
	testing.expect(t, !caller_may(pi, Request_Cancel{request_id = 1}), "internal only")
}

// Uploads: protected folders and symlinks are refused (path_not_allowed; never opened); the bar
// shows full paths (~ for the home folder) on one line each.
@(test)
browser_act_upload_paths :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	home := os.get_env("HOME", context.temp_allocator)
	for sub in ([]string{".ssh/id_ed25519", ".gnupg/pubring.kbx", "Library/Keychains/login.keychain-db", ".aws/credentials", ".config/gh/hosts.yml", ".netrc", ".pi/agent/auth.json", ".ssh", ".git-credentials", ".docker/config.json", ".kube/config", ".npmrc", "Library/Application Support/Google/Chrome/Default/Cookies", "Library/Application Support/Firefox/Profiles/x/logins.json", ".mozilla/firefox/x", "Library/Safari/History.db", "Library/Containers/com.apple.Safari/Data/x"}) {
		p := fmt.tprintf("%s/%s", home, sub)
		code, _ := act_files_check([]string{p})
		testing.expectf(t, code == "path_not_allowed", "%s: %s", sub, code)
	}
	for d in ([]string{data_dir(context.temp_allocator), browser_profile_root(context.temp_allocator)}) {
		code, _ := act_files_check([]string{fmt.tprintf("%s/x.txt", d)})
		testing.expectf(t, code == "path_not_allowed", "pi-desk's own %s: %s", d, code)
	}
	f := tmp_file("real.txt")
	link := fmt.tprintf("%s/link.txt", filepath.dir(f))
	os.remove(link) // a run before left it (the folders' ids start again each run)
	sr := posix.symlink(strings.clone_to_cstring(f, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	testing.expectf(t, sr == .OK, "symlink %s -> %s: %v", link, f, posix.errno())
	code, _ := act_files_check([]string{link})
	testing.expectf(t, code == "path_not_allowed", "a symlink: %s", code)
	code, _ = act_files_check([]string{f})
	testing.expectf(t, code == "", "a plain file: %s", code)
	// a hard link (another name for a file that may be anywhere): refused
	hard := fmt.tprintf("%s/hard.txt", filepath.dir(f))
	os.remove(hard)
	testing.expect(t, posix.link(strings.clone_to_cstring(f, context.temp_allocator), strings.clone_to_cstring(hard, context.temp_allocator)) == .OK, "link")
	code, _ = act_files_check([]string{hard})
	testing.expectf(t, code == "path_not_allowed", "a hard link: %s", code)
	code, _ = act_files_check([]string{f})
	testing.expectf(t, code == "path_not_allowed", "its other name too (2 links): %s", code)
	os.remove(hard)
	// through a folder link: the bar shows the real path
	g := tmp_file("deep.txt")
	gdir := filepath.dir(g)
	ldir := fmt.tprintf("%s-link", gdir)
	os.remove(ldir)
	posix.symlink(strings.clone_to_cstring(gdir, context.temp_allocator), strings.clone_to_cstring(ldir, context.temp_allocator))
	via := fmt.tprintf("%s/deep.txt", ldir)
	pi := Caller{kind = .Panel, tab_id = pa}
	r := run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{link}}, pi)
	testing.expectf(t, code_of(r) == "path_not_allowed", "%v", r)
	odd := tmp_file("two\nlines.txt")
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f, odd, via}}, pi, 531)
	testing.expect(t, act_test_to_bar(ta), "asking")
	_, names, ok := browser_act_upload_words(ta)
	testing.expect(t, ok, "words")
	if strings.has_prefix(f, home) do testing.expectf(t, strings.contains(names, strings.concatenate({"~", f[len(home):]}, context.temp_allocator)), "the full path with ~: %s", names)
	testing.expectf(t, !strings.contains(names, "\n"), "one line: %q", names)
	testing.expectf(t, !strings.contains(names, "-link/"), "the real path, not the link's: %s", names)
	testing.expectf(t, strings.contains(names, "/deep.txt"), "%s", names)
}

// The upload bar's origin is checked again at Allow (the page moved to another origin: nothing goes).
@(test)
browser_act_upload_origin :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	ends := ends_new()
	defer ends_free(ends)
	pi := Caller{kind = .Panel, tab_id = pa}
	f := tmp_file("a.txt")
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}, pi, 541)
	testing.expect(t, act_test_to_bar(ta), "asking")
	run_command(Browser_Update{tab_id = ta, what = {.Url}, url = "https://evil.example/x"}, {kind = .Internal})
	r := run_command(Browser_Upload_Answer{tab_id = ta, allow = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expectf(t, strings.contains(ends[541], `"code":"page_changed"`), "%s", ends[541])
	testing.expect_value(t, len(act_ops), 0)
}

// A native file chooser opened while an agent acts on the tab is cancelled; the agent hears
// use_browser_upload. With no agent action there, the user's own click gets the panel.
@(test)
browser_act_file_chooser :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	ends := ends_new()
	defer ends_free(ends)
	testing.expect(t, !browser_act_file_dialog(ta), "no agent action: the user's panel")
	pi := Caller{kind = .Panel, tab_id = pa}
	run_command(Browser_Click{tab_id = ta, target = {selector = "#one"}}, pi, 551)
	act_page_pending(ta)
	browser_act_tick()
	testing.expect(t, browser_act_file_dialog(ta), "an agent's click: cancelled")
	browser_act_tick()
	testing.expectf(t, strings.contains(ends[551], `"code":"use_browser_upload"`), "%s", ends[551])
}

@(private = "file")
clip_count: int

// The page changed the clipboard while an action's input went in: the result says so
// (clipboard_changed), nothing is restored. Before the input (the upload bar's wait) does not count.
@(test)
browser_act_clipboard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	clip_count = 1
	platform.clipboard_count = proc() -> int {return clip_count}
	defer platform.clipboard_count = nil
	pi := Caller{kind = .Panel, tab_id = pa}
	f := tmp_file("a.txt")
	run_command(Browser_Upload{tab_id = ta, selector = "#file", paths = []string{f}}, pi, 561)
	testing.expect(t, act_test_to_bar(ta), "asking")
	op := act_ops[0]
	clip_count = 2 // the user copies while the bar asks
	testing.expect(t, !act_clip_changed(op), "the bar's wait is not the action's input")
	act_clip_note_input(op) // the files go
	testing.expect(t, !act_clip_changed(op), "nothing changed since")
	clip_count = 3 // the page writes
	testing.expect(t, act_clip_changed(op), "changed during the input")
	clip_count = 3
	testing.expect(t, clip_count == 3, "nothing restored (no restore exists)")
}

// Other keys (Backspace, Delete, shortcuts) on a "none" focus: only the page itself or an element
// focusable by nature (plain); text keys only to text; navigation keys anywhere.
@(test)
browser_act_key_refusals :: proc(t: ^testing.T) {
	c, _ := act_refusal("none", false, .Other)
	testing.expect_value(t, c, "not_a_field")
	c, _ = act_refusal("none", true, .Other)
	testing.expect_value(t, c, "")
	c, _ = act_refusal("none", true, .Text)
	testing.expect_value(t, c, "not_a_field")
	c, _ = act_refusal("frame", false, .Nav)
	testing.expect_value(t, c, "")
	c, _ = act_refusal("field", false, .Other)
	testing.expect_value(t, c, "")
	c, _ = act_refusal("sensitive", false, .Other)
	testing.expect_value(t, c, "sensitive_field")
}

// A file chooser opening shortly after an agent's action (ACT_LINGER) is the agent's: cancelled,
// unless the user clicked or typed in the page since.
@(test)
browser_act_file_chooser_after :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, pa, _, ta, _ := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pa}
	run_command(Browser_Click{tab_id = ta, target = {selector = "#one"}}, pi, 581)
	browser_act_cancel(ta, "done", "stopped") // the action ended
	testing.expect(t, browser_act_file_dialog(ta), "right after an agent's action: cancelled")
	page_extra(ta).input_at = time.tick_now() // the user clicked in the page since
	testing.expect(t, !browser_act_file_dialog(ta), "the user's own click: the panel")
	page_extra(ta).input_at = {}
	act_linger[ta] = time.tick_add(time.tick_now(), -ACT_LINGER - time.Second)
	testing.expect(t, !browser_act_file_dialog(ta), "long after: the user's")
}

// The sidebar's "pi is using a page" and the tab's dot linger a while after the last action.
@(test)
browser_act_activity_lingers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b, _, pb, _, tb := act_reset()
	defer act_done()
	pi := Caller{kind = .Panel, tab_id = pb}
	s := &state.open_sessions[1]
	testing.expect(t, s.id == b, "beta")
	run_command(Browser_Click{tab_id = tb, target = {selector = "#a"}}, pi, 571)
	testing.expect(t, browser_act_session_background(s), "acting")
	browser_act_cancel(tb, "stopped", "stopped")
	testing.expect(t, browser_act_session_background(s), "lingers after the last action")
	testing.expect(t, browser_act_recent(tb), "the tab's dot lingers")
	act_linger[tb] = time.tick_add(time.tick_now(), -ACT_LINGER - time.Second)
	testing.expect(t, !browser_act_session_background(s), "gone after the linger")
	testing.expect(t, !browser_act_recent(tb), "the dot too")
}
