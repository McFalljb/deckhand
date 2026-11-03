package main

// Control socket tests (`./build.sh test`). The test thread plays the main
// thread: test clients pump the inbox while they wait for lines. Processes
// are harmless (/bin/sh, `sleep`); the socket lives in a temp dir.

import "base:runtime"
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
	return dir
}

@(private = "file")
sk_stop :: proc() {
	socket_stop(proc() {inbox_drain()})
	socket_line_max = 1 << 20
	socket_out_cap = 4 << 20
	socket_hello_ms = 5000
	socket_max_conns = 64
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
		{fmt.tprintf(`{{"id":"h","v":2,"type":"hello","token":"%s"}}`, tok), "unsupported protocol version 2 (pi-desk speaks 1)"},
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
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf %%s "$PI_DESK_TOKEN" > %s; exec sleep 30`, tokfile))
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
	testing.expect_value(t, json_path(r, "result.error"), "only the user can confirm this, in pi-desk")
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
	testing.expect_value(t, json_path(r, "result.error"), "only the user can confirm this, in pi-desk")
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
	os.set_env("PI_DESK_CMD", fmt.tprintf(`printf %%s "$PI_DESK_TOKEN" > %s; exec sleep 30`, tokfile))
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
// PI_DESK_SHOTS_DIR (pi-kit checks app_screenshot files are directly in it);
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
	want := "PI_DESK_SHOTS_DIR=/tmp/pd-data-dir-test/apps/shots"
	os.set_env("PI_DESK_DATA_DIR", "/inherited")
	defer os.unset_env("PI_DESK_DATA_DIR")
	os.set_env("PI_DESK_SHOTS_DIR", "/inherited/apps/shots")
	defer os.unset_env("PI_DESK_SHOTS_DIR")
	pi_tab := child_env(socket_child_env({kind = .Panel, tab_id = 4242}))
	testing.expect(t, has(pi_tab, want), "a session's pi tab")
	testing.expect_value(t, count(pi_tab, "PI_DESK_SHOTS_DIR="), 1)
	testing.expect_value(t, count(pi_tab, "PI_DESK_DATA_DIR="), 0)
	atlas := child_env(agent_env(4242))
	testing.expect(t, has(atlas, want), "Atlas")
	testing.expect_value(t, count(atlas, "PI_DESK_SHOTS_DIR="), 1)
	testing.expect_value(t, count(atlas, "PI_DESK_DATA_DIR="), 0)
	app := socket_child_env({kind = .App, tab_id = 4242})
	testing.expect_value(t, count(app, "PI_DESK_SHOTS_DIR="), 0)
	testing.expect_value(t, count(app, "PI_DESK_DATA_DIR="), 0)
	shell := child_env()
	testing.expect_value(t, count(shell, "PI_DESK_SHOTS_DIR="), 0)
	testing.expect_value(t, count(shell, "PI_DESK_DATA_DIR="), 0)
	// test mode without a data dir: still absolute, where the shots are written
	home_root = ""
	seen := false
	for e in socket_child_env({kind = .Panel, tab_id = 4242}) do if strings.has_prefix(e, "PI_DESK_SHOTS_DIR=") {
		v := e[len("PI_DESK_SHOTS_DIR="):]
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
