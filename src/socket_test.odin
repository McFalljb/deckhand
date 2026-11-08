package main

// Control socket tests (`./build.sh test`). The test thread plays the main
// thread: test clients pump the inbox while they wait for lines. Processes
// are harmless (/bin/sh, `sleep`); the socket lives in a temp dir.

import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
Tc :: struct {
	fd:     Sock_Fd,
	buf:    [dynamic]u8,
	closed: bool,
	events: [dynamic]string, // lines read while looking for a reply
}

@(private = "file")
sk_ui :: Caller{kind = .UI}

@(private = "file")
sk_start :: proc(t: ^testing.T) -> string {
	context.allocator = runtime.heap_allocator()
	for _, x in terms {
		term_free(x)
		free(x)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	dir := fmt.aprintf("%s/pd-sock-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.set_env("PI_DESK_RUNTIME_DIR", dir)
	rdir, ok := sock_runtime_dir(context.temp_allocator)
	testing.expect(t, ok, "runtime dir")
	testing.expect(t, socket_start(rdir), "socket_start")
	sk_pin = pi_integration_for_test(t) // pi tabs load the integration, so they get DECKHAND_*
	return dir
}

@(private = "file")
sk_pin: string

@(private = "file")
sk_stop :: proc() {
	socket_stop(proc() {inbox_drain()})
	socket_line_max = 1 << 20
	socket_out_cap = 4 << 20
	socket_hello_ms = 5000
	socket_max_conns = 64
	if sk_pin != "" do pi_integration_test_done(sk_pin)
	sk_pin = ""
}

@(private = "file")
tc_connect :: proc() -> ^Tc {
	fd, ok := sock_connect(socket_path())
	if !ok do return nil
	c := new(Tc)
	c.fd = fd
	return c
}

@(private = "file")
tc_close :: proc(c: ^Tc) {
	sock_close(c.fd)
	delete(c.buf)
	delete(c.events)
	free(c)
}

@(private = "file")
tc_send :: proc(c: ^Tc, line: string) {
	sock_write_all(c.fd, transmute([]u8)strings.concatenate({line, "\n"}, context.temp_allocator))
}

// Next line from the socket, pumping the inbox while waiting. "" on
// timeout or close.
@(private = "file")
tc_recv :: proc(c: ^Tc, ms := 3000) -> string {
	start := time.tick_now()
	for {
		if i := strings.index_byte(string(c.buf[:]), '\n'); i >= 0 {
			line := strings.clone(string(c.buf[:i]))
			remove_range(&c.buf, 0, i + 1)
			return line
		}
		if c.closed || time.tick_since(start) > time.Duration(ms) * time.Millisecond do return ""
		inbox_drain()
		if sock_wait_readable(c.fd, 5) {
			chunk: [16 * 1024]u8
			n := sock_read(c.fd, chunk[:])
			if n <= 0 do c.closed = true
			else do append(&c.buf, ..chunk[:n])
		}
	}
}

// Sends a request and returns the line answering `id`; other lines are
// kept in c.events.
@(private = "file")
tc_req :: proc(c: ^Tc, id, line: string) -> string {
	tc_send(c, line)
	for {
		l := tc_recv(c)
		if l == "" do return ""
		if json_path(l, "id") == id do return l
		append(&c.events, l)
	}
}

@(private = "file")
tc_cmd :: proc(c: ^Tc, cmd: string) -> string {
	return tc_req(c, "q", fmt.tprintf(`{{"id":"q","v":1,"type":"command","command":%s}}`, cmd))
}

// Next event: one kept by tc_req, else from the socket.
@(private = "file")
tc_event :: proc(c: ^Tc, ms := 3000) -> string {
	if len(c.events) > 0 do return pop_front(&c.events)
	return tc_recv(c, ms)
}

@(private = "file")
tc_hello :: proc(token: string) -> (^Tc, string) {
	c := tc_connect()
	if c == nil do return nil, ""
	return c, tc_req(c, "h", fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"}}`, token))
}

// The connection was closed by pi-desk.
@(private = "file")
tc_closed :: proc(c: ^Tc) -> bool {
	for !c.closed {
		if tc_recv(c, 2000) == "" do break
	}
	return c.closed
}

@(test)
socket_handshake :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()

	st, err := os.stat(dir, context.temp_allocator)
	testing.expect(t, err == nil && transmute(u32)st.mode & 0o077 == 0, "socket dir is 0700")
	testing.expect(t, strings.has_prefix(socket_path(), dir))

	tok := socket_mint_token({kind = .Script})
	c, r := tc_hello(tok)
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	testing.expect_value(t, json_path(r, "result.data.caller"), "script")
	testing.expect_value(t, json_path(r, "result.data.v"), "1")
	testing.expect_value(t, json_path(r, "result.data.capabilities.0"), "commands")
	// malformed lines after hello: an error, the connection stays
	testing.expect_value(t, json_path(tc_req(c, "", "not json"), "result.error"), "invalid JSON")
	testing.expect_value(t, json_path(tc_req(c, "x", `{"id":"x","v":1,"type":"nope"}`), "result.error"), "unknown request type")
	testing.expect_value(t, json_path(tc_req(c, "x", `{"id":"x","v":1,"type":"command","command":{"type":"close_tab"}}`), "result.error"), "missing field tab_id")
	testing.expect_value(t, json_path(tc_req(c, "h", `{"id":"h","v":1,"type":"hello","token":"x"}`), "result.error"), "already said hello")
	g := tc_cmd(c, `{"type":"get_state"}`)
	testing.expect_value(t, json_path(g, "result.data.version"), "0")
	testing.expect(t, !strings.contains(g, tok), "no token in replies")
	tc_close(c)

	// bad version, unknown token, no hello first: an error, then closed
	bad := [?][2]string {
		{fmt.tprintf(`{{"id":"h","v":2,"type":"hello","token":"%s"}}`, tok), "unsupported protocol version 2 (Deckhand speaks 1)"},
		{`{"id":"h","v":1,"type":"hello","token":"nope"}`, "unknown token"},
		{`{"id":"h","v":1,"type":"hello"}`, "missing field token"},
		{`{"id":"h","v":1,"type":"command","command":{"type":"get_state"}}`, "the first message must be hello"},
		{`garbage`, "invalid JSON"},
	}
	for b in bad {
		c2 := tc_connect()
		l := tc_req(c2, b[0][:1] == "{" ? "h" : "", b[0])
		testing.expectf(t, json_path(l, "result.error") == b[1], "%s: got %s", b[0], l)
		testing.expect(t, tc_closed(c2), "closed after a failed hello")
		tc_close(c2)
	}

	// an overlong line closes the connection
	socket_line_max = 1000
	c3, _ := tc_hello(tok)
	tc_send(c3, strings.repeat("x", 3000, context.temp_allocator))
	testing.expect_value(t, json_path(tc_recv(c3), "result.error"), "line too long")
	testing.expect(t, tc_closed(c3))
	tc_close(c3)
}

// The pi tab's token reaches the child; a bridge reports status with it.
@(test)
socket_bridge_and_capabilities :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	tokfile := fmt.tprintf("%s/tab-token", dir)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf %%s "$DECKHAND_TOKEN" > %s; exec sleep 30`, tokfile))
	run_command(Add_Project{cwd = "/tmp"}, sk_ui)
	sess := run_command(New_Chat{project_id = state.selected_project}, sk_ui).created_id
	pitab := find_session(sess).tabs[0].id
	tab_tok: string
	for i in 0 ..< 200 {
		data, err := os.read_entire_file(tokfile, context.temp_allocator)
		if err == nil && len(data) == 64 {
			tab_tok = string(data)
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, len(tab_tok), 64)
	testing.expect(t, !strings.contains(state_json(), tab_tok), "tokens stay out of State")

	bridge, r := tc_hello(tab_tok)
	re_tok := strings.clone(json_path(r, "result.data.reconnect_token"))
	// "panels": the bridge publishes its sections here and hides its terminal sidebar
	testing.expect_value(t, json_path(r, "result.data.capabilities.#"), "4")
	testing.expect_value(t, json_path(r, "result.data.capabilities.1"), "panels")
	testing.expect_value(t, json_path(r, "result.data.caller"), "panel")
	testing.expect_value(t, json_path(r, "result.data.tab_id"), fmt.tprint(pitab))
	// panel capability: no control commands, own tab only
	testing.expect_value(t, json_path(tc_cmd(bridge, `{"type":"add_project","cwd":"/"}`), "result.error"), "not allowed for this caller")
	testing.expect_value(t, json_path(tc_cmd(bridge, fmt.tprintf(`{{"type":"pi.status","tab_id":%d,"agent":"idle","waiting":false}}`, pitab + 100)), "result.error"), "not allowed for this caller")
	testing.expect_value(t, json_path(tc_cmd(bridge, `{"type":"get_state"}`), "result.ok"), "true")
	// panels: top-level requests for the bridge's own tab
	testing.expect_value(t, json_path(tc_req(bridge, "p", `{"id":"p","v":1,"type":"panel.set","panel":"todos","title":"Todos","rows":[{"text":"Todos 0/1","head":true},{"text":"○ a"}]}`), "result.ok"), "true")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.0.rows.1.text"), "○ a")
	testing.expect_value(t, json_path(tc_req(bridge, "p", fmt.tprintf(`{{"id":"p","v":1,"type":"panel.set","tab_id":%d,"panel":"x","rows":[]}}`, pitab + 100)), "result.error"), "not allowed for this caller")
	testing.expect_value(t, json_path(tc_req(bridge, "p", `{"id":"p","v":1,"type":"panel.set","panel":"x"}`), "result.error"), "missing field rows")
	testing.expect_value(t, json_path(tc_req(bridge, "p", `{"id":"p","v":1,"type":"panel.remove","panel":"todos"}`), "result.ok"), "true")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "0")
	tc_req(bridge, "p", `{"id":"p","v":1,"type":"panel.set","panel":"todos","rows":[{"text":"kept"}]}`)

	// pi.session and pi.status land in State
	_, pt, _ := find_tab(pitab)
	testing.expect(t, close_needs_confirm(pt^), "unknown status: asks")
	l := tc_req(bridge, "s", `{"id":"s","v":1,"type":"pi.session","pi_session_id":"abc-1","session_file":"/x/abc-1.jsonl","cwd":"/tmp"}`)
	testing.expect_value(t, json_path(l, "result.ok"), "true")
	l = tc_req(bridge, "b", `{"id":"b","v":1,"type":"pi.status","agent":"working","waiting":false,"blockers":["CI red"]}`)
	testing.expect_value(t, json_path(l, "result.ok"), "true")
	s := state_json()
	testing.expect_value(t, json_path(s, "open_sessions.0.pi_session_id"), "abc-1")
	testing.expect_value(t, json_path(s, "open_sessions.0.session_file"), "/x/abc-1.jsonl")
	testing.expect_value(t, json_path(s, "open_sessions.0.tabs.0.agent"), "working")
	testing.expect_value(t, json_path(s, "open_sessions.0.tabs.0.blockers.0"), "CI red")
	_, pt, _ = find_tab(pitab)
	testing.expect(t, close_needs_confirm(pt^), "working: asks")
	tc_req(bridge, "b", `{"id":"b","v":1,"type":"pi.status","agent":"idle","waiting":false,"blockers":[]}`)
	_, pt, _ = find_tab(pitab)
	testing.expect(t, !close_needs_confirm(pt^), "idle: closes without asking")
	testing.expect_value(t, json_path(tc_req(bridge, "b", `{"id":"b","v":1,"type":"pi.status","agent":"busy","waiting":false}`), "result.error"), "unknown agent busy")

	// control drives the pi tab through the bridge
	ctl, _ := tc_hello(socket_mint_token({kind = .Control}))
	testing.expect_value(t, json_path(tc_req(ctl, "b", `{"id":"b","v":1,"type":"pi.status","agent":"idle","waiting":false}`), "result.error"), "not allowed for this caller")
	testing.expect_value(t, json_path(tc_cmd(ctl, fmt.tprintf(`{{"type":"panel.set","tab_id":%d,"panel":"x","rows":[]}}`, pitab)), "result.error"), "not allowed for this caller")
	tc_send(ctl, fmt.tprintf(`{{"id":"p1","v":1,"type":"command","command":{{"type":"pi_prompt","tab_id":%d,"text":"hello pi"}}}}`, pitab))
	req := tc_recv(bridge)
	testing.expect_value(t, json_path(req, "type"), "pi.prompt")
	testing.expect_value(t, json_path(req, "text"), "hello pi")
	bid := json_path(req, "id")
	reply := tc_recv(ctl)
	testing.expect_value(t, json_path(reply, "result.pending"), "true")
	rid := json_path(reply, "request_id")
	tc_send(bridge, fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":true}}}}`, bid))
	fin := tc_recv(ctl)
	testing.expect_value(t, json_path(fin, "event"), "finished")
	testing.expect_value(t, json_path(fin, "request_id"), rid)
	testing.expect_value(t, json_path(fin, "result.ok"), "true")
	// refused while pi waits for the user
	tc_req(bridge, "b", `{"id":"b","v":1,"type":"pi.status","agent":"working","waiting":true,"blockers":[]}`)
	testing.expect_value(t, json_path(tc_cmd(ctl, fmt.tprintf(`{{"type":"pi_prompt","tab_id":%d,"text":"x"}}`, pitab)), "result.error"), "pi is waiting for the user")
	// pi_reload: session_restart confirmation (ask: only the user)
	testing.expect_value(t, json_path(tc_cmd(ctl, fmt.tprintf(`{{"type":"pi_reload","tab_id":%d}}`, pitab)), "result.needs_confirmation.by"), "user")
	// a bridge that goes away fails what it owed
	tc_send(ctl, fmt.tprintf(`{{"id":"w","v":1,"type":"command","command":{{"type":"pi_wait_idle","tab_id":%d,"timeout_ms":5000}}}}`, pitab))
	testing.expect_value(t, json_path(tc_recv(bridge), "type"), "pi.wait_idle")
	testing.expect_value(t, json_path(tc_recv(ctl), "result.pending"), "true")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "1")
	tc_close(bridge)
	fin = tc_recv(ctl)
	testing.expect_value(t, json_path(fin, "result.error"), "the pi tab's bridge disconnected")
	testing.expect(t, sk_agent_is("unknown"), "no bridge: unknown")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "0") // the bridge re-sends on reconnect
	testing.expect_value(t, json_path(tc_cmd(ctl, fmt.tprintf(`{{"type":"pi_wait_idle","tab_id":%d}}`, pitab)), "result.error"), "no bridge connected for this tab")

	// the tab's process exits: its token is revoked
	b2, _ := tc_hello(re_tok)
	run_command(Tab_Exited{tab_id = pitab})
	testing.expect(t, tc_closed(b2), "bridge hung up")
	tc_close(b2)
	b3, r3 := tc_hello(re_tok)
	testing.expect_value(t, json_path(r3, "result.error"), "unknown token")
	tc_close(b3)
	tc_close(ctl)
}

@(test)
socket_confirmation_modes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	run_command(Add_Project{cwd = "/tmp"}, sk_ui)
	sess := run_command(New_Chat{project_id = state.selected_project}, sk_ui).created_id
	state.settings.confirm_close[.Shell] = .Always
	c, _ := tc_hello(socket_mint_token({kind = .Control}))
	tab := json_path(tc_cmd(c, fmt.tprintf(`{{"type":"new_shell_tab","session":%d}}`, sess)), "result.created_id")
	close := fmt.tprintf(`{{"type":"close_tab","tab_id":%s}}`, tab)

	// ask: no token for the caller; a self-made token is refused
	r := tc_cmd(c, close)
	testing.expect_value(t, json_path(r, "result.error"), "needs_confirmation")
	testing.expect_value(t, json_path(r, "result.needs_confirmation.by"), "user")
	testing.expect_value(t, json_path(r, "result.needs_confirmation.token"), "<missing>")
	user_token := strings.clone(state.pending_confirmations[0].token)
	r = tc_cmd(c, fmt.tprintf(`{{"type":"close_tab","tab_id":%s,"confirm":"%s"}}`, tab, user_token))
	testing.expect_value(t, json_path(r, "result.error"), "only the user can confirm this, in Deckhand")
	// the socket cannot raise its own mode
	r = tc_cmd(c, `{"type":"set_confirm_policy","caller":"control","class":"tab_close","mode":"auto"}`)
	testing.expect_value(t, json_path(r, "result.error"), "not allowed for this caller")
	run_command(Cancel_Confirmation{token = user_token}, sk_ui)

	// trusted (set by the user): the caller confirms its own token
	run_command(Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Trusted}, sk_ui)
	r = tc_cmd(c, close)
	testing.expect_value(t, json_path(r, "result.needs_confirmation.by"), "caller")
	tok := json_path(r, "result.needs_confirmation.token")
	testing.expect(t, len(tok) > 10)
	// a different caller (another token) cannot use it
	other, _ := tc_hello(socket_mint_token({kind = .Script}))
	run_command(Set_Confirm_Policy{caller = .Script, class = .Tab_Close, mode = .Trusted}, sk_ui)
	r = tc_cmd(other, fmt.tprintf(`{{"type":"close_tab","tab_id":%s,"confirm":"%s"}}`, tab, tok))
	testing.expect_value(t, json_path(r, "result.error"), "only the user can confirm this, in Deckhand")
	r = tc_cmd(c, fmt.tprintf(`{{"type":"close_tab","tab_id":%s,"confirm":"%s"}}`, tab, tok))
	testing.expect_value(t, json_path(r, "result.ok"), "true")

	// auto: no confirmation
	run_command(Set_Confirm_Policy{caller = .Control, class = .Tab_Close, mode = .Auto}, sk_ui)
	tab = json_path(tc_cmd(c, fmt.tprintf(`{{"type":"new_shell_tab","session":%d}}`, sess)), "result.created_id")
	r = tc_cmd(c, fmt.tprintf(`{{"type":"close_tab","tab_id":%s}}`, tab))
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	testing.expect_value(t, len(state.pending_confirmations), 0)
	tc_close(c)
	tc_close(other)
}

@(test)
socket_events_and_filters :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	run_command(Add_Project{cwd = "/tmp"}, sk_ui)
	s1 := run_command(New_Chat{project_id = state.selected_project}, sk_ui).created_id
	s2 := run_command(New_Chat{project_id = state.selected_project}, sk_ui).created_id
	tab1 := find_session(s1).tabs[0].id
	tab2 := find_session(s2).tabs[0].id

	a_tok := socket_mint_token({kind = .Control})
	a, _ := tc_hello(a_tok)
	a2, _ := tc_hello(a_tok) // same caller, second connection
	b, _ := tc_hello(socket_mint_token({kind = .Script}))
	by_tab, _ := tc_hello(socket_mint_token({kind = .Script}))
	by_sess, _ := tc_hello(socket_mint_token({kind = .Script}))
	for c in ([]^Tc{a, a2, b}) do testing.expect_value(t, json_path(tc_req(c, "s", `{"id":"s","v":1,"type":"subscribe"}`), "result.ok"), "true")
	tc_req(by_tab, "s", fmt.tprintf(`{{"id":"s","v":1,"type":"subscribe","tab_id":%d}}`, tab2))
	tc_req(by_sess, "s", fmt.tprintf(`{{"id":"s","v":1,"type":"subscribe","session":%d}}`, s1))

	// a's command: b sees it (redacted), a and a2 do not
	tc_cmd(a, fmt.tprintf(`{{"type":"send_text","tab_id":%d,"text":"secret-pw"}}`, tab1))
	ev := tc_event(b)
	testing.expect_value(t, json_path(ev, "event"), "command")
	testing.expect_value(t, json_path(ev, "caller"), "control")
	testing.expect_value(t, json_path(ev, "command.text"), "<redacted 9 bytes>")
	testing.expect(t, !strings.contains(ev, "secret-pw"))
	// session filter: s1's tab
	testing.expect_value(t, json_path(tc_event(by_sess), "command.tab_id"), fmt.tprint(tab1))
	// tab filter: tab1 is skipped, tab2 arrives first
	tc_cmd(b, fmt.tprintf(`{{"type":"focus_tab","tab_id":%d}}`, tab2))
	ev = tc_event(by_tab)
	testing.expect_value(t, json_path(ev, "command.type"), "focus_tab")
	testing.expect_value(t, json_path(ev, "command.tab_id"), fmt.tprint(tab2))
	testing.expect_value(t, json_path(tc_event(a), "caller"), "script") // a sees b's
	// user events reach everyone subscribed
	run_command(Set_Layout{left_width = 200}, sk_ui)
	testing.expect_value(t, json_path(tc_event(a), "command.type"), "set_layout")
	testing.expect_value(t, json_path(tc_event(a2), "command.type"), "focus_tab") // a2: b's, then the ui's
	testing.expect_value(t, json_path(tc_event(a2), "command.type"), "set_layout")
	// filtered subscribers get only events tied to their session/tab
	testing.expect_value(t, tc_recv(by_sess, 200), "")
	// nothing of a's own ever arrived at a or a2: the next lines are replies
	testing.expect_value(t, len(a.events), 0)
	testing.expect_value(t, json_path(tc_cmd(a, `{"type":"get_state"}`), "type"), "result")
	testing.expect_value(t, len(a.events), 0)
	testing.expect_value(t, json_path(tc_req(a2, "u", `{"id":"u","v":1,"type":"unsubscribe"}`), "type"), "result")
	testing.expect_value(t, len(a2.events), 0)
	// after unsubscribe: no more events
	run_command(Set_Layout{left_width = 210}, sk_ui)
	testing.expect_value(t, tc_recv(a2, 200), "")
	for c in ([]^Tc{a, a2, b, by_tab, by_sess}) do tc_close(c)
}

@(test)
socket_slow_subscriber_is_dropped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	socket_out_cap = 16 * 1024
	slow, _ := tc_hello(socket_mint_token({kind = .Script}))
	tc_req(slow, "s", `{"id":"s","v":1,"type":"subscribe"}`)
	// the main thread keeps going while nobody reads: ~2 MB of events
	name := strings.repeat("p", 400, context.temp_allocator)
	start := time.tick_now()
	for i in 0 ..< 5000 do run_command(Set_Panel{panel = name, open = i % 2 == 0}, sk_ui)
	testing.expectf(t, time.tick_since(start) < 5 * time.Second, "main thread blocked: %v", time.tick_since(start))
	// the subscriber eventually reads a `dropped` event, and the connection still works
	dropped := false
	for i in 0 ..< 10000 {
		l := tc_recv(slow, 2000)
		if l == "" do break
		if json_path(l, "event") == "dropped" {
			dropped = true
			break
		}
	}
	testing.expect(t, dropped, "dropped event")
	testing.expect_value(t, json_path(tc_cmd(slow, `{"type":"get_state"}`), "result.ok"), "true")
	tc_close(slow)
}

@(test)
socket_concurrent_connections :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	pid := run_command(Add_Project{cwd = "/tmp"}, sk_ui).created_id
	N :: 8
	Worker :: struct {
		token: string,
		pid:   u64,
		oks:   int,
		done:  bool,
	}
	workers: [N]Worker
	threads: [N]^thread.Thread
	for i in 0 ..< N {
		workers[i] = {token = socket_mint_token({kind = .Script}), pid = pid}
		threads[i] = thread.create_and_start_with_poly_data(&workers[i], proc(w: ^Worker) {
			fd, ok := sock_connect(socket_path())
			if !ok do return
			defer sock_close(fd)
			buf: [dynamic]u8
			defer delete(buf)
			next :: proc(fd: Sock_Fd, buf: ^[dynamic]u8) -> string {
				for {
					if i := strings.index_byte(string(buf[:]), '\n'); i >= 0 {
						l := strings.clone(string(buf[:i]), context.temp_allocator)
						remove_range(buf, 0, i + 1)
						return l
					}
					chunk: [4096]u8
					n := sock_read(fd, chunk[:])
					if n <= 0 do return ""
					append(buf, ..chunk[:n])
				}
			}
			send :: proc(fd: Sock_Fd, s: string) {sock_write_all(fd, transmute([]u8)strings.concatenate({s, "\n"}, context.temp_allocator))}
			send(fd, fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"}}`, w.token))
			if json_path(next(fd, &buf), "result.ok") != "true" do return
			for j in 0 ..< 25 {
				send(fd, fmt.tprintf(`{{"id":"%d","v":1,"type":"command","command":{{"type":"rename_project","project_id":%d,"name":"w%d"}}}}`, j, w.pid, j))
				l := next(fd, &buf)
				if json_path(l, "id") == fmt.tprint(j) && json_path(l, "result.ok") == "true" do w.oks += 1
			}
			sync.atomic_store(&w.done, true)
		})
	}
	start := time.tick_now()
	for time.tick_since(start) < 10 * time.Second {
		all := true
		for &w in workers do if !sync.atomic_load(&w.done) do all = false
		if all do break
		inbox_drain()
		time.sleep(time.Millisecond)
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	for w, i in workers do testing.expectf(t, w.oks == 25, "worker %d: %d of 25", i, w.oks)
}

// Hostile lines get an error reply, never a crash (deep nesting used to
// overflow the reader thread's stack inside the JSON parser).
@(test)
socket_hostile_lines :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	tok := socket_mint_token({kind = .Script})
	// before hello: deep nesting and an oversized line
	pre := tc_connect()
	tc_send(pre, strings.repeat("[", 3000, context.temp_allocator))
	testing.expect_value(t, json_path(tc_recv(pre), "result.ok"), "false")
	testing.expect(t, tc_closed(pre))
	tc_close(pre)
	pre = tc_connect()
	tc_send(pre, fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s","pad":"%s"}}`, tok, strings.repeat("x", 8000, context.temp_allocator)))
	testing.expect_value(t, json_path(tc_recv(pre), "result.error"), "line too long")
	testing.expect(t, tc_closed(pre))
	tc_close(pre)

	c, _ := tc_hello(tok)
	hostile := [?]string {
		strings.repeat("[", 200000, context.temp_allocator),
		strings.concatenate({`{"id":"d","v":1,"type":"command","command":`, strings.repeat(`{"a":`, 100000, context.temp_allocator), "1", strings.repeat("}", 100000, context.temp_allocator), "}"}, context.temp_allocator),
		`{"id":"u","v":1,"type":"command","command":{"type":"add_project","cwd":"` + "\xff\xfe\xc3" + `"}}`,
		`{"id":"n","v":1,"type":"command","command":{"type":"add_project","cwd":"a` + "\x00" + `b"}}`,
		`{"id":"g","v":1,"type":"command","command":{"type":"close_tab","tab_id":99999999999999999999999999}}`,
		`{"id":"g","v":1,"type":"command","command":{"type":"close_tab","tab_id":1e999999}}`,
		`{"id":"g","v":1e400,"type":"subscribe"}`,
		"\x00\x00\x00",
		`{"id":"s","v":1,"type":"command","command":{"type":"add_project","cwd":"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[["}}`,
	}
	for h in hostile {
		tc_send(c, h)
		l := tc_recv(c)
		testing.expectf(t, json_path(l, "type") == "result", "%.60s: got %.200s", h, l)
	}
	// still alive and answering
	testing.expect_value(t, json_path(tc_cmd(c, `{"type":"get_state"}`), "result.ok"), "true")
	tc_close(c)
}

// A new pi tab (fake pi that saves its env token); returns the session, the
// pi tab and the token pi-desk passed in PI_DESK_TOKEN.
@(private = "file")
sk_pi_tab :: proc(t: ^testing.T, dir: string) -> (sess, pitab: u64, env_tok: string) {
	tokfile := fmt.tprintf("%s/tab-token-%d", dir, time.now()._nsec)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf %%s "$DECKHAND_TOKEN" > %s; exec sleep 30`, tokfile))
	if state.selected_project == 0 do run_command(Add_Project{cwd = "/tmp"}, sk_ui)
	sess = run_command(New_Chat{project_id = state.selected_project}, sk_ui).created_id
	pitab = find_session(sess).tabs[0].id
	for _ in 0 ..< 200 {
		data, err := os.read_entire_file(tokfile, context.temp_allocator)
		if err == nil && len(data) == 64 do return sess, pitab, strings.clone(string(data))
		time.sleep(20 * time.Millisecond)
	}
	testing.fail_now(t, "no token from the pi tab")
}

// The env token works once: its hello revokes it and hands back a
// reconnect token (same tab), usable for any number of later connections.
@(test)
socket_env_token_single_use :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	_, pitab, env_tok := sk_pi_tab(t, dir)
	b1, r := tc_hello(env_tok)
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	re := json_path(r, "result.data.reconnect_token")
	testing.expect_value(t, len(re), 64)
	testing.expect(t, re != env_tok)
	b2, r2 := tc_hello(env_tok)
	testing.expect_value(t, json_path(r2, "result.error"), "unknown token")
	tc_close(b2)
	// reconnect token: several connections at once, same tab, no new token
	c1, r3 := tc_hello(re)
	c2, r4 := tc_hello(re)
	for x in ([]string{r3, r4}) {
		testing.expect_value(t, json_path(x, "result.data.caller"), "panel")
		testing.expect_value(t, json_path(x, "result.data.tab_id"), fmt.tprint(pitab))
		testing.expect_value(t, json_path(x, "result.data.reconnect_token"), "<missing>")
	}
	// tokens minted for scripts stay reusable
	st := socket_mint_token({kind = .Script})
	s1, q1 := tc_hello(st)
	s2, q2 := tc_hello(st)
	testing.expect(t, json_path(q1, "result.ok") == "true" && json_path(q2, "result.ok") == "true")
	testing.expect_value(t, json_path(q1, "result.data.reconnect_token"), "<missing>")
	// the reconnect token dies with the tab
	run_command(Tab_Exited{tab_id = pitab})
	c3, r5 := tc_hello(re)
	testing.expect_value(t, json_path(r5, "result.error"), "unknown token")
	for c in ([]^Tc{b1, c1, c2, c3, s1, s2}) do tc_close(c)
}

// question (pi's last answer ended with a question) is shown, but only
// waiting (a pi dialog is open) blocks prompts.
@(test)
socket_question_does_not_block :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	_, pitab, env_tok := sk_pi_tab(t, dir)
	bridge, _ := tc_hello(env_tok)
	l := tc_req(bridge, "b", `{"id":"b","v":1,"type":"pi.status","agent":"idle","waiting":false,"question":true,"blockers":[]}`)
	testing.expect_value(t, json_path(l, "result.ok"), "true")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.question"), "true")
	_, pt, _ := find_tab(pitab)
	testing.expect(t, !close_needs_confirm(pt^), "idle with a question: no confirmation")
	ctl, _ := tc_hello(socket_mint_token({kind = .Control}))
	tc_send(ctl, fmt.tprintf(`{{"id":"p","v":1,"type":"command","command":{{"type":"pi_prompt","tab_id":%d,"text":"yes"}}}}`, pitab))
	testing.expect_value(t, json_path(tc_recv(bridge), "type"), "pi.prompt")
	testing.expect_value(t, json_path(tc_recv(ctl), "result.pending"), "true")
	tc_req(bridge, "b", `{"id":"b","v":1,"type":"pi.status","agent":"idle","waiting":true,"question":false,"blockers":[]}`)
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.question"), "false")
	testing.expect_value(t, json_path(tc_cmd(ctl, fmt.tprintf(`{{"type":"pi_prompt","tab_id":%d,"text":"x"}}`, pitab)), "result.error"), "pi is waiting for the user")
	tc_close(bridge)
	tc_close(ctl)
}

// A pi tab's get_state shows only its own session (and that session's project).
@(test)
socket_panel_snapshot_is_own_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	s1, _, tok1 := sk_pi_tab(t, dir)
	run_command(Add_Project{cwd = "/"}, sk_ui)
	s2, _, _ := sk_pi_tab(t, dir)
	run_command(Quit{}, sk_ui) // parks a confirmation (processes run)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	b, _ := tc_hello(tok1)
	d := tc_cmd(b, `{"type":"get_state"}`)
	testing.expect_value(t, json_path(d, "result.data.open_sessions.#"), "1")
	testing.expect_value(t, json_path(d, "result.data.open_sessions.0.id"), fmt.tprint(s1))
	testing.expect_value(t, json_path(d, "result.data.projects.#"), "1")
	testing.expect_value(t, json_path(d, "result.data.projects.0.cwd"), resolved("/tmp"))
	testing.expect_value(t, json_path(d, "result.data.sessions.#"), "0")
	testing.expect_value(t, json_path(d, "result.data.pending_confirmations.#"), "0")
	full, _ := tc_hello(socket_mint_token({kind = .Control}))
	f := tc_cmd(full, `{"type":"get_state"}`)
	testing.expect_value(t, json_path(f, "result.data.open_sessions.#"), "2")
	testing.expect_value(t, json_path(f, "result.data.open_sessions.1.id"), fmt.tprint(s2))
	tc_close(b)
	tc_close(full)
}

// A silent connection is dropped after the hello deadline; past the
// connection cap new connections get an error and are closed.
@(test)
socket_hello_deadline_and_conn_cap :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	socket_hello_ms = 300
	silent := tc_connect()
	start := time.tick_now()
	testing.expect_value(t, json_path(tc_recv(silent, 2000), "result.error"), "no hello in time")
	testing.expect(t, tc_closed(silent))
	testing.expect(t, time.tick_since(start) < 1500 * time.Millisecond)
	tc_close(silent)

	socket_hello_ms = 5000
	socket_max_conns = 3
	tok := socket_mint_token({kind = .Script})
	a, _ := tc_hello(tok)
	b, _ := tc_hello(tok)
	c, _ := tc_hello(tok)
	extra := tc_connect()
	testing.expect_value(t, json_path(tc_recv(extra), "result.error"), "too many connections")
	testing.expect(t, tc_closed(extra))
	tc_close(extra)
	tc_close(a)
	// a slot frees once pi-desk has seen the close
	ok := false
	for _ in 0 ..< 50 {
		d, r := tc_hello(tok)
		ok = json_path(r, "result.ok") == "true"
		tc_close(d)
		if ok do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, ok, "a new connection after one closed")
	tc_close(b)
	tc_close(c)
}

// Wait (pumping the inbox) until the pi tab's agent reads `want`.
@(private = "file")
sk_agent_is :: proc(want: string) -> bool {
	for _ in 0 ..< 200 {
		inbox_drain()
		if json_path(state_json(), "open_sessions.0.tabs.0.agent") == want do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
socket_bridge_lifecycle :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	_, pitab, env_tok := sk_pi_tab(t, dir)
	run_command(Add_Project{cwd = "/"}, sk_ui)
	s2, _, _ := sk_pi_tab(t, dir)
	other_id := strings.clone(find_session(s2).pi_session_id)

	old, r := tc_hello(env_tok)
	re := strings.clone(json_path(r, "result.data.reconnect_token"))
	tc_req(old, "b", `{"id":"b","v":1,"type":"pi.status","agent":"working","waiting":false,"blockers":[]}`)
	tc_req(old, "p", `{"id":"p","v":1,"type":"panel.set","panel":"shells","rows":[{"text":"sh1 running"}]}`)
	// a pi.session naming another open tab's session is refused
	l := tc_req(old, "s", fmt.tprintf(`{{"id":"s","v":1,"type":"pi.session","pi_session_id":"%s","session_file":"","cwd":"/"}}`, other_id))
	testing.expect_value(t, json_path(l, "result.error"), "this pi session is open in another tab")
	testing.expect_value(t, json_path(tc_req(old, "s", `{"id":"s","v":1,"type":"pi.session","pi_session_id":"mine-1","session_file":"/a","cwd":"/"}`), "result.ok"), "true")
	testing.expect_value(t, json_path(tc_req(old, "s", `{"id":"s","v":1,"type":"pi.session","pi_session_id":"mine-2","session_file":"/b","cwd":"/"}`), "result.ok"), "true")

	// a request on the old connection; the runtime reconnects, then the old
	// connection goes: the request fails at once as "reconnecting"
	ctl, _ := tc_hello(socket_mint_token({kind = .Control}))
	tc_send(ctl, fmt.tprintf(`{{"id":"w","v":1,"type":"command","command":{{"type":"pi_wait_idle","tab_id":%d}}}}`, pitab))
	testing.expect_value(t, json_path(tc_recv(old), "type"), "pi.wait_idle")
	testing.expect_value(t, json_path(tc_recv(ctl), "result.pending"), "true")
	new, _ := tc_hello(re)
	tc_close(old)
	fin := tc_recv(ctl)
	testing.expect_value(t, json_path(fin, "result.error"), "the pi tab's bridge is reconnecting")
	// status stays while a bridge connection remains, and is unknown once none does
	testing.expect(t, !sk_agent_is("unknown"), "still known while the new connection is open")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "1") // kept while reconnecting
	tc_close(new)
	testing.expect(t, sk_agent_is("unknown"), "unknown after the last bridge connection closed")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.panels.#"), "0")
	_, pt, _ := find_tab(pitab)
	testing.expect(t, close_needs_confirm(pt^), "unknown: asks again")
	tc_close(ctl)
}

// A pi session (a pi tab, Atlas) learns where app screenshots go in
// DECKHAND_SHOTS_DIR (the pi integration checks app_screenshot files are directly in it);
// app tabs do not. PI_DESK_DATA_DIR is never passed on, nor inherited: it
// would point a test-mode pi-desk an agent starts at the user's real data dir.
@(test)
socket_child_env_has_the_shots_dir :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	old := home_root
	home_root = "/tmp/pd-data-dir-test"
	defer home_root = old
	defer socket_forget_tab(4242)
	has :: proc(env: []string, want: string) -> bool {
		for e in env do if e == want do return true
		return false
	}
	count :: proc(env: []string, prefix: string) -> (n: int) {
		for e in env do if strings.has_prefix(e, prefix) do n += 1
		return
	}
	want := "DECKHAND_SHOTS_DIR=/tmp/pd-data-dir-test/apps/shots"
	os.set_env("PI_DESK_DATA_DIR", "/inherited")
	defer os.unset_env("PI_DESK_DATA_DIR")
	os.set_env("DECKHAND_SHOTS_DIR", "/inherited/apps/shots")
	defer os.unset_env("DECKHAND_SHOTS_DIR")
	pi_tab := child_env(socket_pi_env({kind = .Panel, tab_id = 4242}))
	testing.expect(t, has(pi_tab, want), "a session's pi tab")
	testing.expect_value(t, count(pi_tab, "DECKHAND_SHOTS_DIR="), 1)
	testing.expect_value(t, count(pi_tab, "PI_DESK_DATA_DIR="), 0)
	atlas := child_env(agent_env(4242))
	testing.expect(t, has(atlas, want), "Atlas")
	testing.expect_value(t, count(atlas, "DECKHAND_SHOTS_DIR="), 1)
	testing.expect_value(t, count(atlas, "PI_DESK_DATA_DIR="), 0)
	app := socket_child_env({kind = .App, tab_id = 4242})
	testing.expect_value(t, count(app, "DECKHAND_SHOTS_DIR=") + count(app, "PI_DESK_SHOTS_DIR="), 0)
	testing.expect_value(t, count(app, "PI_DESK_DATA_DIR="), 0)
	shell := child_env()
	testing.expect_value(t, count(shell, "DECKHAND_SHOTS_DIR="), 0)
	testing.expect_value(t, count(shell, "PI_DESK_DATA_DIR="), 0)
	// test mode without a data dir: still absolute, where the shots are written
	home_root = ""
	seen := false
	for e in socket_pi_env({kind = .Panel, tab_id = 4242}) do if strings.has_prefix(e, "DECKHAND_SHOTS_DIR=") {
		v := e[len("DECKHAND_SHOTS_DIR="):]
		seen = true
		testing.expectf(t, strings.has_prefix(v, "/") && strings.has_suffix(v, "/build/test-data/apps/shots"), "%s", v)
	}
	testing.expect(t, seen, "set in test mode too")
}

// A requester cancels its own long-running request (the cancel line): that action ends; another
// connection cannot cancel it; a connection that closes ends every request it still has running.
@(test)
socket_request_cancel :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	browser_act_reset()
	browser_agent_reset()
	defer {
		browser_act_reset()
		browser_agent_reset()
		for id, _ in browsers do browser_drop(id)
	}
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("pi-s"), cwd = strings.clone("/tmp/s")}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = strings.clone("pi"), status = .Running, agent = .Idle})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	pt := s.tabs[0].id
	bt := run_command(Browser_Open{session = s.id, url = "https://a.example"}, {kind = .UI}).created_id
	tok := socket_mint_token({kind = .Panel, tab_id = pt})
	c, _ := tc_hello(tok)
	other, _ := tc_hello(tok)
	click := fmt.tprintf(`{{"type":"browser_click","tab_id":%d,"selector":"#a"}}`, bt)
	r := tc_cmd(c, click)
	testing.expect_value(t, json_path(r, "result.pending"), "true")
	rid := json_path(r, "request_id")
	testing.expect(t, rid != "", "a request id")
	testing.expect_value(t, len(act_ops), 1)
	// another connection (even the same pi tab's): refused
	x := tc_req(other, "k", fmt.tprintf(`{{"id":"k","v":1,"type":"cancel","request_id":%s}}`, rid))
	testing.expect_value(t, json_path(x, "result.ok"), "false")
	testing.expect_value(t, len(act_ops), 1)
	// its own: the action ends, its Finished event says cancelled
	x = tc_req(c, "k", fmt.tprintf(`{{"id":"k","v":1,"type":"cancel","request_id":%s}}`, rid))
	testing.expectf(t, json_path(x, "result.ok") == "true", "%s", x)
	inbox_drain()
	testing.expect_value(t, len(act_ops), 0)
	fin := ""
	for _ in 0 ..< 5 {
		e := tc_event(c, 500)
		if e == "" do break
		if strings.contains(e, `"cancelled"`) do fin = e
	}
	testing.expectf(t, fin != "", "a Finished event with cancelled")
	// a connection closing ends what it still runs
	r = tc_cmd(other, click)
	testing.expect_value(t, json_path(r, "result.pending"), "true")
	testing.expect_value(t, len(act_ops), 1)
	tc_close(other)
	deadline := time.tick_now()
	for len(act_ops) > 0 && time.tick_since(deadline) < 3 * time.Second {
		inbox_drain()
		time.sleep(5 * time.Millisecond)
	}
	testing.expect_value(t, len(act_ops), 0)
	tc_close(c)
}

// A Claude tab's token (claude.odin, socket_claude_env): minted at its start, multi-use, valid only
// from the tab's own processes, scoped like its session's pi tab (minus the bridge's reports, plus
// its own claude.* reports), and dead once the tab closes.
@(test)
socket_claude_token_scope :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("PI_DESK_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	sess, pitab, pi_tok := sk_pi_tab(t, dir)
	run_command(Add_Project{cwd = "/"}, sk_ui)
	other, _, _ := sk_pi_tab(t, dir)
	run_command(Focus_Session{session = sess}, sk_ui)
	tokfile := fmt.tprintf("%s/claude-token-%d", dir, time.now()._nsec)
	os.set_env("PI_DESK_CLAUDE_CMD", fmt.tprintf(`printf %%s "$PI_DESK_CLAUDE_TOKEN" > %s; exec sleep 30`, tokfile))
	claude_found = .Yes // the stand-in for claude (claude.odin: claude_installed)
	r := run_command(New_Claude_Tab{session = sess}, sk_ui)
	testing.expect(t, r.ok, r.error)
	ctab := r.created_id
	tok := ""
	for _ in 0 ..< 200 {
		data, err := os.read_entire_file(tokfile, context.temp_allocator)
		if err == nil && len(data) == 64 {
			tok = strings.clone(string(data))
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, len(tok), 64)
	// a process outside the tab (this test) holding the token: refused
	x, rx := tc_hello(tok)
	testing.expect_value(t, json_path(rx, "result.error"), "this token works only from its Claude tab's own processes")
	tc_close(x)
	// as if this test were the tab's process: accepted, and again (multi-use)
	socket_claude_pid(ctab, i32(os.get_pid()))
	c, rc := tc_hello(tok)
	testing.expect_value(t, json_path(rc, "result.ok"), "true")
	testing.expect_value(t, json_path(rc, "result.data.caller"), "claude")
	testing.expect_value(t, json_path(rc, "result.data.tab_id"), fmt.tprint(ctab))
	testing.expect(t, len(json_path(rc, "result.data.reconnect_token")) != 64, "no reconnect token: the env token is the one")
	c2, rc2 := tc_hello(tok)
	testing.expect_value(t, json_path(rc2, "result.ok"), "true")
	tc_close(c2)
	sid := "11111111-2222-3333-4444-555555555555"
	// its own reports: the tab id is its own
	d := tc_cmd(c, fmt.tprintf(`{{"type":"claude.session","session_id":"%s","source":"startup"}}`, sid))
	testing.expect_value(t, json_path(d, "result.ok"), "true")
	_, _, ct := claude_tab_of(ctab)
	testing.expect_value(t, ct.session_id, sid)
	d = tc_cmd(c, fmt.tprintf(`{{"type":"claude.session","tab_id":%d,"session_id":"%s"}}`, pitab, sid))
	testing.expect_value(t, json_path(d, "result.ok"), "false")
	d = tc_cmd(c, `{"type":"claude.turn","state":"idle"}`)
	testing.expect_value(t, json_path(d, "result.ok"), "true")
	// no pi bridge, no control set, no reaching another session
	for cmd in ([]string {
		`{"type":"pi.status","agent":"idle","waiting":false}`,
		`{"type":"panel.set","panel":"x","rows":[]}`,
		`{"type":"pi.attached","attachment_id":1}`,
		fmt.tprintf(`{{"type":"send_text","tab_id":%d,"text":"x"}}`, pitab),
		fmt.tprintf(`{{"type":"pi_prompt","tab_id":%d,"text":"x"}}`, pitab),
		fmt.tprintf(`{{"type":"close_tab","tab_id":%d}}`, pitab),
		fmt.tprintf(`{{"type":"new_claude_tab","session":%d}}`, sess),
		fmt.tprintf(`{{"type":"claude_prompt","tab_id":%d,"text":"x"}}`, ctab),
		fmt.tprintf(`{{"type":"claude_held","tab_id":%d,"op":"drop"}}`, ctab),
		`{"type":"set_home","open":true}`,
		fmt.tprintf(`{{"type":"browser_tabs","session":%d}}`, other),
		fmt.tprintf(`{{"type":"browser_comments","session":%d}}`, other),
	}) {
		d = tc_cmd(c, cmd)
		e := json_path(d, "result.error")
		testing.expectf(t, json_path(d, "result.ok") == "false" && (e == "not allowed for this caller" || strings.contains(e, "own session")), "refused: %s -> %s", cmd, d)
	}
	// its snapshot: its own session, and no Claude history
	d = tc_cmd(c, `{"type":"get_state"}`)
	testing.expect_value(t, json_path(d, "result.data.open_sessions.#"), "1")
	testing.expect_value(t, json_path(d, "result.data.open_sessions.0.id"), fmt.tprint(sess))
	testing.expect(t, !strings.contains(d, `"claude_sessions":[{`), "the history is the user's")
	testing.expect(t, strings.contains(state_json(), `"claude_sessions":[{`), "the full snapshot has it")
	// a pi tab never reports for a Claude tab
	p, rp := tc_hello(pi_tok)
	testing.expect_value(t, json_path(rp, "result.data.caller"), "panel")
	d = tc_cmd(p, fmt.tprintf(`{{"type":"claude.session","tab_id":%d,"session_id":"%s"}}`, ctab, sid))
	testing.expect_value(t, json_path(d, "result.ok"), "false")
	tc_close(p)
	// closed: the token dies with the tab, and its connections with it
	run_command(Close_Tab{tab_id = ctab}, sk_ui)
	testing.expect(t, tc_closed(c), "its open connections are shut")
	tc_close(c)
	c3, rc3 := tc_hello(tok)
	testing.expect_value(t, json_path(rc3, "result.error"), "unknown token")
	tc_close(c3)
}

// The process check with real processes: a grandchild of the tab's process (sh -c 'sh -c client')
// is accepted; the same client re-parented to launchd (double fork) is refused.
@(test)
socket_claude_token_process_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("PI_DESK_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	os.make_directory_all(dir)
	client := fmt.tprintf("%s/client.py", dir)
	src := `import json, os, socket, sys, time
out, orphan = sys.argv[1], sys.argv[2] == "orphan"
if orphan:
    if os.fork() != 0:
        os._exit(0)
    for _ in range(100):
        if os.getppid() == 1:
            break
        time.sleep(0.02)
time.sleep(0.3)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(os.environ["PI_DESK_SOCKET"])
s.sendall((json.dumps({"id": "h", "v": 1, "type": "hello", "token": os.environ["PI_DESK_CLAUDE_TOKEN"]}) + "\n").encode())
line = s.makefile().readline()
with open(out + ".tmp", "w") as f:
    f.write(json.dumps({"ppid": os.getppid(), "reply": json.loads(line)}))
os.rename(out + ".tmp", out)
`
	_ = os.write_entire_file(client, transmute([]u8)src)
	ok_out, orphan_out := fmt.tprintf("%s/grandchild.json", dir), fmt.tprintf("%s/orphan.json", dir)
	os.set_env("PI_DESK_CLAUDE_CMD", fmt.tprintf(`sh -c "sh -c 'python3 -I %s %s child'"; python3 -I %s %s orphan; exec sleep 30`, client, ok_out, client, orphan_out))
	sess, _, _ := sk_pi_tab(t, dir)
	claude_found = .Yes // the stand-in for claude (claude.odin: claude_installed)
	r := run_command(New_Claude_Tab{session = sess}, sk_ui)
	testing.expect(t, r.ok, r.error)
	read :: proc(path: string) -> string {
		for _ in 0 ..< 300 {
			inbox_drain()
			if data, err := os.read_entire_file(path, context.temp_allocator); err == nil do return string(data)
			time.sleep(20 * time.Millisecond)
		}
		return ""
	}
	g := read(ok_out)
	testing.expectf(t, json_path(g, "reply.result.ok") == "true" && json_path(g, "reply.result.data.caller") == "claude", "grandchild: %s", g)
	o := read(orphan_out)
	testing.expect_value(t, json_path(o, "ppid"), "1")
	testing.expect_value(t, json_path(o, "reply.result.error"), "this token works only from its Claude tab's own processes")
	run_command(Close_Tab{tab_id = r.created_id}, sk_ui)
}

// A panel caller whose tab pi-desk does not know (yet: before it is in its session) sees no events.
@(test)
socket_panel_events_fail_closed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	c, _ := tc_hello(socket_mint_token({kind = .Panel, tab_id = 987654}))
	testing.expect_value(t, json_path(tc_req(c, "s", `{"id":"s","v":1,"type":"subscribe"}`), "result.ok"), "true")
	run_command(Add_Project{cwd = "/tmp"}, sk_ui)
	testing.expect_value(t, tc_event(c, 500), "")
	tc_close(c)
}

// An app hears nothing before its hello reply (docs/TAB-PROTOCOL.md §3): pi-desk's main thread
// sends tab.visible or an agent's app_call as soon as the connection counts as the app's, so that
// must not happen before the reply is queued. A thread sends to the tab without pause while the
// app says hello; the first line the app reads is the reply, every time.
@(test)
socket_app_hears_nothing_before_its_hello_reply :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	Spam :: struct {
		tab:  u64,
		stop: bool,
	}
	TAB :: 777001
	early, sent := 0, 0
	for i in 0 ..< 40 {
		sp := Spam{tab = TAB}
		th := thread.create_and_start_with_poly_data(&sp, proc(sp: ^Spam) {
			for !sync.atomic_load(&sp.stop) {
				socket_app_send(sp.tab, `{"id":"a0","v":1,"type":"tab.visible","visible":true}`)
			}
		})
		c := tc_connect()
		tc_send(c, fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"}}`, socket_mint_token({kind = .App, tab_id = TAB}, context.temp_allocator)))
		first := tc_recv(c)
		sync.atomic_store(&sp.stop, true)
		thread.join(th)
		thread.destroy(th)
		if json_path(first, "id") != "h" do early += 1
		testing.expectf(t, first != "", "round %d: no line at all", i)
		// the thread's lines do arrive, right after the reply
		if tc_recv(c, 1000) != "" do sent += 1
		tc_close(c)
		// the connection is gone before the next round (the newest open one gets the lines)
		for _ in 0 ..< 200 {
			if !socket_app_connected(TAB) do break
			time.sleep(time.Millisecond)
		}
	}
	testing.expectf(t, early == 0, "%d of 40 apps read a request before their hello reply", early)
	testing.expectf(t, sent > 0, "the sending thread never reached an app (%d)", sent)
}

// An app tab's process is gone (Restart of a hung app, its exit): its connection no longer counts as
// the tab's at once, not only once its reader thread has seen the end. Otherwise the frame loop saw
// the old connection still open right after a Restart, then gone before the new process connected,
// and stopped the new process ("the app closed its connection"): app-tab's Restart once ended
// "exited" under load.
@(test)
socket_forget_tab_ends_the_connection_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	still := 0
	for i in 0 ..< 20 {
		tab, c := sk_app_tab(t)
		testing.expectf(t, socket_app_connected(tab), "round %d: connected after its hello", i)
		socket_forget_tab(tab)
		if socket_app_connected(tab) do still += 1
		tc_close(c)
	}
	testing.expectf(t, still == 0, "%d of 20 forgotten tabs still had an open connection", still)
}

// ---- test-script mode and a fast app (docs/DEVELOPING.md "Test mode") ----

@(private = "file")
fast_app: ^Tc
@(private = "file")
fast_tab: u64

// A session with an app tab whose program is the test: its hello is said, it answers nothing yet.
@(private = "file")
sk_app_tab :: proc(t: ^testing.T) -> (tab: u64, c: ^Tc) {
	run_command(Add_Project{cwd = "/tmp"}, sk_ui)
	sess := run_command(New_Chat{project_id = state.selected_project}, sk_ui).created_id
	s := find_session(sess)
	testing.expect(t, s != nil, "a session")
	tab = new_id()
	pane_add_tab(s, Tab{id = tab, kind = App_Tab{exit_code = -1}, title = strings.clone("app"), status = .Running}) // in its pane (panes.odin)
	r: string
	c, r = tc_hello(socket_mint_token({kind = .App, tab_id = tab}))
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	return
}

// A script's app_call whose reply comes while pi-desk is still draining the inbox (a fast app; the
// script runs the command and drains in one step) finishes the call: the finished result is kept,
// never lost with the script then waiting for it forever.
@(test)
script_keeps_a_reply_that_comes_inside_the_drain :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	fast_tab, fast_app = sk_app_tab(t)
	defer tc_close(fast_app)
	script_drain = proc() {
		inbox_drain() // app_call sends its line
		req := tc_recv(fast_app)
		tc_send(fast_app, fmt.tprintf(`{{"id":"%s","v":1,"type":"result","result":{{"ok":true,"data":{{"x":7}}}}}}`, json_path(req, "id")))
		// the reply is read and run before this drain returns
		for _ in 0 ..< 1000 {
			inbox_drain()
			left := false
			for _, p in pending do if p.tab_id == fast_tab do left = true
			if !left do break
			time.sleep(time.Millisecond)
		}
	}
	defer script_drain = inbox_drain
	// only what this test changes (last_finished: the finished result it gets)
	was_finished := autotest.last_finished
	autotest.last_finished = ""
	defer {
		delete(autotest.last_finished)
		autotest.last_finished = was_finished
	}
	_, r, finished := script_command(App_Call{tab_id = fast_tab, method = strings.clone("game.get")}, {kind = .Script})
	testing.expect(t, r.ok && r.pending, "app_call is long-running")
	testing.expect(t, finished, "its finished result already came")
	testing.expect_value(t, json_path(autotest.last_finished, "data.x"), "7")
	result_free(r)
}

// A script waiting for a long-running command's finished result gives up with a TIMEOUT failure
// after script_finish_timeout, or after the command's own timeout_ms + 10 s when that is longer:
// a scene ends, it never hangs, and never gives up before the command's own timeout could fire.
@(test)
script_wait_for_a_finished_result_times_out :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	tab, c := sk_app_tab(t)
	defer tc_close(c)
	// only what this test changes
	was_active, was_started, was_next, was_failures, was_lines := autotest.active, autotest.started, autotest.next, autotest.failures, autotest.lines
	was_wait, was_until, was_deadline := autotest.wait_request, autotest.wait_until, autotest.wait_request_deadline
	was_timeout := script_finish_timeout
	defer {
		autotest.active, autotest.started, autotest.next, autotest.failures, autotest.lines = was_active, was_started, was_next, was_failures, was_lines
		autotest.wait_request, autotest.wait_until, autotest.wait_request_deadline = was_wait, was_until, was_deadline
		script_finish_timeout = was_timeout
	}
	script_finish_timeout = 200 * time.Millisecond
	run :: proc(lines: []string, ms: time.Duration) {
		autotest.active, autotest.started, autotest.next, autotest.failures = true, true, 0, 0
		autotest.wait_request, autotest.wait_until = 0, {}
		autotest.lines = lines
		autotest_step()
		start := time.tick_now()
		for autotest.failures == 0 && time.tick_since(start) < ms {
			inbox_drain()
			autotest_step()
			time.sleep(10 * time.Millisecond)
		}
	}
	// no timeout_ms of its own (app_call's default is 10 s): the script's ceiling
	run({fmt.tprintf(`command {{"type":"app_call","tab_id":%d,"method":"game.never"}}`, tab)}, 3 * time.Second)
	testing.expect_value(t, autotest.failures, 1)
	testing.expect_value(t, autotest.wait_request, 0)
	app_fail_pending(tab, "the test ended", "tab_gone")
	inbox_drain()
	// timeout_ms 600 s: the script still waits after its own 200 ms (until 610 s)
	run({fmt.tprintf(`command {{"type":"app_call","tab_id":%d,"method":"game.never","timeout_ms":600000}}`, tab)}, 800 * time.Millisecond)
	testing.expect_value(t, autotest.failures, 0)
	testing.expect(t, autotest.wait_request != 0, "still waiting for the call")
	d := time.tick_diff(time.tick_now(), autotest.wait_request_deadline)
	testing.expectf(t, d > 600 * time.Second && d <= 610 * time.Second, "deadline in %v", d)
	app_fail_pending(tab, "the test ended", "tab_gone")
	inbox_drain()
	testing.expect_value(t, autotest.wait_request, 0)
}

// ---- tokens.json (keep_sessions): tokens of processes kept by the holder survive a relaunch ----

@(private = "file")
sk_key :: proc(b: u8) -> (k: [32]u8) {
	for i in 0 ..< 32 do k[i] = b ~ u8(i * 7)
	return
}

// Quit and reopen as far as the control socket goes: every token in memory is gone.
@(private = "file")
sk_relaunch :: proc(t: ^testing.T) {
	rdir, _ := sock_runtime_dir(context.temp_allocator)
	socket_stop(proc() {inbox_drain()})
	testing.expect(t, socket_start(rdir), "socket_start again")
}

@(private = "file")
sk_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}

@(private = "file")
sk_hex :: proc(tok: string) -> string {
	h := token_hash(tok)
	return string(hex.encode(h[:], context.temp_allocator))
}

// keep_sessions off: binding and minting never write a file.
@(test)
socket_tokens_off_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	tok := socket_mint_token({kind = .Panel, tab_id = 101}, context.temp_allocator, single_use = true)
	socket_tokens_bind(101, 7, {kind = .Pi})
	c, r := tc_hello(tok)
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	tc_close(c)
	testing.expect(t, !os.exists(path), "no tokens.json while keep_sessions is off")
}

// A pi tab in the holder: its reconnect token works after a relaunch, for the adopted tab's new id.
// The file holds hashes only; a used env token stays used; the tab's end revokes everything.
@(test)
socket_tokens_pi_reconnect_across_relaunch :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	key := sk_key(3)
	loaded, why := socket_tokens_enable(path, key[:])
	testing.expect(t, !loaded && why == "missing", why)
	env := socket_mint_token({kind = .Panel, tab_id = 101}, context.temp_allocator, single_use = true)
	ctl := socket_mint_token({kind = .Control, tab_id = 101}, context.temp_allocator, single_use = true) // Home's
	other := socket_mint_token({kind = .Panel, tab_id = 102}, context.temp_allocator, single_use = true) // not in the holder
	script := socket_mint_token({kind = .Script}, context.temp_allocator)
	socket_tokens_bind(101, 7, {kind = .Pi})
	b, r := tc_hello(env)
	re := json_path(r, "result.data.reconnect_token")
	testing.expect_value(t, len(re), 64)
	tc_close(b)
	raw := sk_file(path)
	testing.expect(t, strings.has_prefix(raw, "deckhand-mac 1 tokens "), raw)
	for tok in ([]string{env, ctl, re, other, script}) do testing.expect(t, !strings.contains(raw, tok), "a token on disk")
	testing.expect(t, strings.contains(raw, sk_hex(re)) && strings.contains(raw, sk_hex(ctl)), raw)
	testing.expect(t, !strings.contains(raw, sk_hex(env)), "a used env token is not listed")
	testing.expect(t, !strings.contains(raw, sk_hex(other)) && !strings.contains(raw, sk_hex(script)), "only tabs in the holder")
	testing.expect(t, strings.contains(raw, `"term":7`), raw)

	sk_relaunch(t)
	x, rx := tc_hello(re)
	testing.expect_value(t, json_path(rx, "result.error"), "unknown token")
	tc_close(x)
	loaded, why = socket_tokens_enable(path, key[:])
	testing.expect(t, loaded, why)
	x, rx = tc_hello(re)
	testing.expect_value(t, json_path(rx, "result.error"), "unknown token") // not before its terminal is adopted
	tc_close(x)
	testing.expect(t, socket_tokens_adopt(7, 202), "adopted with saved state")
	testing.expect(t, !socket_tokens_adopt(8, 203), "nothing saved for term 8")
	c1, r1 := tc_hello(re)
	testing.expect_value(t, json_path(r1, "result.ok"), "true")
	testing.expect_value(t, json_path(r1, "result.data.caller"), "panel")
	testing.expect_value(t, json_path(r1, "result.data.tab_id"), "202")
	testing.expect_value(t, json_path(r1, "result.data.reconnect_token"), "<missing>")
	c2, r2 := tc_hello(re) // still multi-use
	testing.expect_value(t, json_path(r2, "result.ok"), "true")
	u, ru := tc_hello(env)
	testing.expect_value(t, json_path(ru, "result.error"), "unknown token")
	tc_close(u)
	// Home's control token: still single-use, swapped on its first hello
	h1, rh := tc_hello(ctl)
	testing.expect_value(t, json_path(rh, "result.data.caller"), "control")
	testing.expect_value(t, json_path(rh, "result.data.tab_id"), "202")
	testing.expect_value(t, len(json_path(rh, "result.data.reconnect_token")), 64)
	h2, rh2 := tc_hello(ctl)
	testing.expect_value(t, json_path(rh2, "result.error"), "unknown token")
	for c in ([]^Tc{c1, c2, h1, h2}) do tc_close(c)
	// a second relaunch still knows it (the adopted entries were written under the same term)
	sk_relaunch(t)
	loaded, why = socket_tokens_enable(path, key[:])
	testing.expect(t, loaded, why)
	socket_tokens_adopt(7, 303)
	c3, r3 := tc_hello(re)
	testing.expect_value(t, json_path(r3, "result.data.tab_id"), "303")
	tc_close(c3)
	// the tab ends: revoked, and gone from the file
	socket_forget_tab(303)
	c4, r4 := tc_hello(re)
	testing.expect_value(t, json_path(r4, "result.error"), "unknown token")
	tc_close(c4)
	testing.expect(t, !strings.contains(sk_file(path), `"term":7`), sk_file(path))
	socket_tokens_disable(true)
	testing.expect(t, !os.exists(path), "disable(remove) deletes the file")
}

// A file that does not verify (edited, another holder's key, the wrong kind, out of shape) loads
// nothing: the old tokens are unknown, the read-only state untrusted, and the file is rewritten.
@(test)
socket_tokens_fail_closed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	key, other := sk_key(3), sk_key(4)
	setup :: proc(t: ^testing.T, path: string, key: []u8) -> string {
		socket_tokens_enable(path, key)
		re := socket_mint_token({kind = .Panel, tab_id = 101}, context.temp_allocator)
		socket_tokens_bind(101, 7, {kind = .Claude})
		socket_tokens_ro(101, true, true, "nonce-1")
		return re
	}
	expect_refused :: proc(t: ^testing.T, path: string, key: []u8, tok: string, want: string, loc := #caller_location) {
		// a relaunch, for tab 101's token (cheaper than restarting the socket: keeps this < 1 s)
		socket_tokens_disable(false)
		socket_forget_tab(101)
		loaded, why := socket_tokens_enable(path, key)
		testing.expectf(t, !loaded && strings.contains(why, want), "loaded %v: %s", loaded, why, loc = loc)
		testing.expect(t, !socket_tokens_adopt(7, 202), "nothing to adopt", loc = loc)
		testing.expect(t, !claude_adopt_ro_ok(7), "read-only state untrusted", loc = loc)
		c, r := tc_hello(tok)
		testing.expect_value(t, json_path(r, "result.error"), "unknown token", loc = loc)
		tc_close(c)
		socket_forget_tab(202)
		if want != "too large" {
			_, rok, _ := macfile_read(path, TOKENS_KIND, key, context.temp_allocator)
			testing.expect(t, rok, "rewritten with the new key", loc = loc)
		}
	}
	// one byte of the body changed
	tok := setup(t, path, key[:])
	raw := sk_file(path)
	i := strings.index(raw, `"acked":true`)
	_ = os.write_entire_file(path, transmute([]u8)strings.concatenate({raw[:i], `"acked":fals`, raw[i + len(`"acked":true`) - 0:]}, context.temp_allocator))
	expect_refused(t, path, key[:], tok, "bad MAC")
	// another holder (it restarted: a new key)
	tok = setup(t, path, key[:])
	expect_refused(t, path, other[:], tok, "bad MAC")
	// a handover file put in its place
	tok = setup(t, path, key[:])
	body, _, _ := macfile_read(path, TOKENS_KIND, key[:], context.temp_allocator)
	macfile_write(path, "handover", body, key[:])
	expect_refused(t, path, key[:], tok, "not tokens")
	// MAC'd but out of shape: too deep, a zero term, pid 1, an unknown caller, unknown version
	for bad in ([]string {
		strings.concatenate({`{"v":1,"terms":`, strings.repeat("[", JSON_MAX_DEPTH + 2, context.temp_allocator), strings.repeat("]", JSON_MAX_DEPTH + 2, context.temp_allocator), "}"}, context.temp_allocator),
		`{"v":1,"terms":[{"term":0,"kind":"shell","tokens":[]}]}`,
		`{"v":1,"terms":[{"term":4294967296,"kind":"shell","tokens":[]}]}`,
		`{"v":1,"terms":[{"term":7,"kind":"claude","claude_root":1,"tokens":[]}]}`,
		fmt.tprintf(`{{"v":1,"terms":[{{"term":7,"kind":"pi","tokens":[{{"sha256":"%s","caller":"ui","claude":false,"single_use":false}}]}}]}}`, sk_hex(tok)),
		`{"v":1,"terms":[{"term":7,"kind":"app","tokens":[]}]}`, // an unknown kind
		`{"v":1,"terms":[{"term":7,"kind":"shell","pi_ro":true,"tokens":[]}]}`, // pi_ro on a shell
		`{"v":2,"terms":[]}`,
		"{\"v\":1,\"terms\":[],\"x\":\"\xff\xfe\"}", // invalid UTF-8: json.parse would trap
	}) {
		tok = setup(t, path, key[:])
		macfile_write(path, TOKENS_KIND, bad, key[:])
		expect_refused(t, path, key[:], tok, "")
	}
	// too large
	tok = setup(t, path, key[:])
	was := macfile_max
	macfile_max = 16
	expect_refused(t, path, key[:], tok, "too large")
	macfile_max = was
}

// A Claude token kept across a relaunch keeps its rule: hellos only from the tab's own processes
// (its saved root pid, now the adopted tab's). Its read-only ack state comes along.
@(test)
socket_tokens_claude_keeps_ancestry :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	key := sk_key(5)
	socket_tokens_enable(path, key[:])
	tok := socket_mint_token({kind = .Panel, tab_id = 301, claude = true}, context.temp_allocator)
	socket_claude_pid(301, i32(os.get_pid()))
	socket_tokens_bind(301, 9, {kind = .Claude})
	socket_tokens_ro(301, true, true, "n1")
	unacked := socket_mint_token({kind = .Panel, tab_id = 302, claude = true}, context.temp_allocator)
	socket_claude_pid(302, 99_999_999) // nothing of ours
	socket_tokens_bind(302, 10, {kind = .Claude})
	socket_tokens_ro(302, true, false, "n2")
	sk_relaunch(t)
	loaded, why := socket_tokens_enable(path, key[:])
	testing.expect(t, loaded, why)
	testing.expect(t, claude_adopt_ro_ok(9), "acked: trusted")
	testing.expect(t, !claude_adopt_ro_ok(10), "not acked: stopped")
	testing.expect(t, !claude_adopt_ro_ok(11), "no state: stopped")
	socket_tokens_adopt(9, 401)
	socket_tokens_adopt(10, 402)
	testing.expect(t, claude_adopt_ro_ok(9), "still trusted once adopted")
	c, r := tc_hello(tok)
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	testing.expect_value(t, json_path(r, "result.data.caller"), "claude")
	testing.expect_value(t, json_path(r, "result.data.tab_id"), "401")
	c2, r2 := tc_hello(tok) // multi-use, as before
	testing.expect_value(t, json_path(r2, "result.ok"), "true")
	x, rx := tc_hello(unacked)
	testing.expect_value(t, json_path(rx, "result.error"), "this token works only from its Claude tab's own processes")
	for k in ([]^Tc{c, c2, x}) do tc_close(k)
	raw := sk_file(path)
	testing.expect(t, strings.contains(raw, fmt.tprintf(`"claude_root":%d`, os.get_pid())) && strings.contains(raw, `"acked":true`), raw)
	testing.expect(t, !strings.contains(raw, "n1") || strings.contains(raw, sk_hex("n1")), "the nonce is hashed")
}

// What each held terminal was started as (the tab kind, pi's read-only flag, its optional pi
// extensions) is kept in the MAC'd tokens.json, so an adopt can refuse a workspace.json that maps
// a terminal to another kind of tab, and a pi tab's read-only flag never comes from that unMAC'd
// file alone.
@(test)
socket_tokens_start_kept :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	key := sk_key(6)
	socket_tokens_enable(path, key[:])
	socket_tokens_bind(101, 7, {kind = .Pi, pi_ro = true, extras = 5})
	socket_tokens_bind(102, 8, {kind = .Shell})
	socket_tokens_bind(103, 9, {kind = .Claude})
	sk_relaunch(t)
	loaded, why := socket_tokens_enable(path, key[:])
	testing.expect(t, loaded, why)
	s7, f7 := socket_tokens_start_of(7)
	testing.expect(t, f7 && s7 == Held_Start{kind = .Pi, pi_ro = true, extras = 5}, fmt.tprint(s7))
	s8, _ := socket_tokens_start_of(8)
	testing.expect_value(t, s8.kind, Held_Kind.Shell)
	s9, _ := socket_tokens_start_of(9)
	testing.expect_value(t, s9.kind, Held_Kind.Claude)
	_, f10 := socket_tokens_start_of(10)
	testing.expect(t, !f10, "nothing for term 10")
	socket_tokens_adopt(7, 202)
	s7, f7 = socket_tokens_start_of(7)
	testing.expect(t, f7 && s7.kind == .Pi && s7.pi_ro, "kept once adopted")
	// a term listed without a kind is out of shape: the whole file is refused
	macfile_write(path, TOKENS_KIND, `{"v":1,"terms":[{"term":7,"tokens":[]}]}`, key[:])
	socket_tokens_disable(false)
	loaded, why = socket_tokens_enable(path, key[:])
	testing.expect(t, !loaded, "no kind: refused")
}

// At adopt, entries for terminals the holder no longer lists are dropped (a later terminal with
// the same id must not get them).
@(test)
socket_tokens_prune_gone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	key := sk_key(7)
	socket_tokens_enable(path, key[:])
	gone := socket_mint_token({kind = .Panel, tab_id = 102}, context.temp_allocator)
	socket_tokens_bind(101, 7, {kind = .Shell})
	socket_tokens_bind(102, 8, {kind = .Pi})
	sk_relaunch(t)
	socket_tokens_enable(path, key[:])
	socket_tokens_prune({7})
	_, f8 := socket_tokens_start_of(8)
	testing.expect(t, !f8, "term 8 is gone")
	testing.expect(t, !socket_tokens_adopt(8, 300), "nothing left for a new term 8")
	c, r := tc_hello(gone)
	testing.expect_value(t, json_path(r, "result.error"), "unknown token")
	tc_close(c)
	testing.expect(t, !strings.contains(sk_file(path), `"term":8`), sk_file(path))
	_, f7 := socket_tokens_start_of(7)
	testing.expect(t, f7, "term 7 is kept")
}

// tokens.json is written (fsync'd) without holding srv.mu: a slow disk must not stall every
// thread that needs the socket's state (the main thread included) on each mint or hello.
@(test)
socket_tokens_write_unlocked :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := sk_start(t)
	defer sk_stop()
	@(static) calls, locked: int
	calls, locked = 0, 0
	tokens_write_probe = proc() {
		calls += 1
		if !socket_mu_free() do locked += 1
	}
	defer tokens_write_probe = nil
	key := sk_key(8)
	socket_tokens_enable(fmt.tprintf("%s/tokens.json", dir), key[:])
	env := socket_mint_token({kind = .Panel, tab_id = 101}, context.temp_allocator, single_use = true)
	socket_tokens_bind(101, 7, {kind = .Pi})
	c, r := tc_hello(env) // swaps it for a reconnect token: a write from the connection's thread
	testing.expect_value(t, json_path(r, "result.ok"), "true")
	tc_close(c)
	socket_claude_pid(101, 4242)
	socket_tokens_ro(101, true, true, "n")
	socket_forget_tab(101)
	testing.expect(t, calls >= 5, fmt.tprint(calls))
	testing.expect_value(t, locked, 0)
}

// Settings › Copy a control token (the one way a release build mints one, test_hooks.odin): the
// user's only; the exports land on the clipboard, the token in no result; it says hello as control.
@(test)
socket_copy_control_token :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sk_start(t)
	defer sk_stop()
	@(static) clip: string
	clip = ""
	platform.set_clipboard = proc(s: string) {clip = strings.clone(s, runtime.heap_allocator())}
	for k in ([]Caller_Kind{.Control, .Script, .Panel}) {
		r := run_command(Copy_Control_Token{}, {kind = k})
		testing.expectf(t, !r.ok, "%v may not mint a control token", k)
	}
	testing.expect_value(t, clip, "")
	r := run_command(Copy_Control_Token{}, sk_ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, r.data, "")
	testing.expect(t, strings.has_prefix(clip, fmt.tprintf("export PI_DESK_SOCKET='%s' PI_DESK_TOKEN='", socket_path())), clip)
	_, _, rest := strings.partition(clip, "PI_DESK_TOKEN='")
	tok, _, _ := strings.partition(rest, "'")
	testing.expect_value(t, len(tok), 64)
	testing.expect(t, !strings.contains(command_json(Copy_Control_Token{}), tok), "never in the log")
	c, hr := tc_hello(tok)
	testing.expect_value(t, json_path(hr, "result.data.caller"), "control")
	tc_close(c)
	// with the app's pasteboard: marked concealed and transient (clipboard managers skip it), and
	// cleared after CONTROL_TOKEN_CLIP_TTL if it still holds the token (its change count)
	@(static) secret: string
	@(static) cleared: [dynamic]int
	secret = ""
	clear(&cleared)
	platform.set_clipboard_secret = proc(s: string) -> int {secret = strings.clone(s, runtime.heap_allocator()); return 41}
	platform.clear_clipboard_if = proc(count: int) {append(&cleared, count)}
	defer platform.set_clipboard_secret, platform.clear_clipboard_if = nil, nil
	clip = ""
	testing.expect(t, run_command(Copy_Control_Token{}, sk_ui).ok)
	testing.expect(t, strings.contains(secret, "PI_DESK_TOKEN='"), secret)
	testing.expect_value(t, clip, "") // not through the plain copy
	control_token_clip_tick()
	testing.expect_value(t, len(cleared), 0) // not before the deadline
	control_token_clip.deadline = time.tick_now()
	control_token_clip_tick()
	control_token_clip_tick()
	testing.expect(t, len(cleared) == 1 && cleared[0] == 41, fmt.tprint(cleared[:]))
}
