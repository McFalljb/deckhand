package main

// The control socket (docs/PROTOCOL.md): NDJSON over a local socket
// (socket_posix.odin). One accept thread; per connection a reader thread
// (parses lines, submits commands to the inbox and waits for each reply, so a
// connection's requests run in order) and a writer thread (drains a bounded
// outbound queue, so the main thread never blocks on a slow client).
//
// Tokens are routing + capability: pi-desk mints one per pi tab it starts
// (caller panel, that tab) and passes it as PI_DESK_TOKEN; `--print-token`
// mints a script or control token for local use. The first line on a
// connection must be `hello` with a known token, or the connection closes.
//
// Events (emit_event -> socket_publish, main thread) go to subscribed
// connections, never to connections with the token that caused them. A
// subscriber whose queue is full is unsubscribed with a `dropped` event.
// pi_prompt / pi_reload / pi_wait_idle are sent to the target tab's bridge
// connection; its result line comes back as Bridge_Done -> `finished`.

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

socket_line_max := 1 << 20 // a longer request line is an error and closes the connection
SOCKET_HELLO_MAX :: 4096 // the same, before hello
socket_hello_ms := 5000 // a connection must say hello within this (tests lower it)
socket_max_conns := 64 // connections beyond this are refused (tests lower it)
socket_out_cap := 4 << 20 // bytes queued for one connection before its subscription drops (tests lower it)

@(private = "file")
Token_Entry :: struct {
	caller:     Caller,
	ref:        u64, // identity: a caller never receives events caused by its own token
	single_use: bool, // a child's env token: its first hello swaps it for a reconnect token
}

Conn :: struct {
	id:          u64,
	fd:          Sock_Fd,
	caller:      Caller,
	ref:         u64, // token identity; 0 until hello
	// srv.mu:
	subscribed:  bool,
	sub_session: u64,
	sub_tab:     u64,
	// mu:
	mu:          sync.Mutex,
	cond:        sync.Cond,
	out:         [dynamic]string,
	out_bytes:   int,
	closing:     bool,
	writer:      ^thread.Thread, // nil if it could not start
	opened:      time.Tick, // for the hello deadline
}

@(private = "file")
Origin :: struct {
	conn: u64,
	ref:  u64,
}

@(private = "file")
Bridge_Call :: struct {
	request_id: u64,
	conn:       u64,
}

@(private = "file")
Server :: struct {
	mu:           sync.Mutex,
	running:      bool,
	stopping:     bool,
	path:         string,
	listen_fd:    Sock_Fd,
	accept:       ^thread.Thread,
	conns:        [dynamic]^Conn,
	tokens:       map[string]Token_Entry,
	origins:      map[u64]Origin, // request id -> the connection that sent it
	bridge_calls: map[string]Bridge_Call, // our request id on a bridge -> the command waiting for it
	tab_session:  map[u64]u64, // tab -> open session, kept from State (ids are never reused)
	next_ref:     u64,
	next_conn:    u64,
	next_bridge:  u64,
}

@(private = "file")
srv: Server

// Starts listening in `dir` (default: sock_runtime_dir). Main thread.
socket_start :: proc(dir := "") -> bool {
	if srv.running do return true
	d := dir
	if d == "" {
		ok: bool
		d, ok = sock_runtime_dir(context.temp_allocator)
		if !ok {
			fmt.eprintln("pi-desk: control socket: unsafe or missing runtime dir", d)
			return false
		}
	}
	path := fmt.aprintf("%s/pi-desk-%d.sock", d, os.get_pid())
	fd, ok := sock_listen(path)
	if !ok {
		fmt.eprintln("pi-desk: control socket: cannot listen on", path)
		delete(path)
		return false
	}
	srv.path = path
	srv.listen_fd = fd
	srv.stopping = false
	srv.running = true
	srv.accept = thread.create_and_start(accept_loop)
	if srv.accept == nil {
		fmt.eprintln("pi-desk: control socket: cannot start the accept thread")
		sock_close(fd)
		sock_unlink(path)
		delete(path)
		srv.path = ""
		srv.running = false
		return false
	}
	return true
}

socket_path :: proc() -> string {return srv.path}

// Stops listening and hangs up every connection. With `pump` (tests), waits
// up to 3 s for the connection threads to finish, calling pump (e.g.
// inbox_drain) so readers waiting for a reply can finish too.
socket_stop :: proc(pump: proc() = nil) {
	if !srv.running do return
	sync.atomic_store(&srv.stopping, true)
	if srv.accept != nil {
		thread.join(srv.accept)
		thread.destroy(srv.accept)
		srv.accept = nil
	}
	sock_close(srv.listen_fd)
	sock_unlink(srv.path)
	sync.lock(&srv.mu)
	for c in srv.conns do sock_shutdown(c.fd)
	for k in srv.tokens do delete(k)
	clear(&srv.tokens)
	for k in srv.bridge_calls do delete(k)
	clear(&srv.bridge_calls)
	clear(&srv.origins)
	sync.unlock(&srv.mu)
	if pump != nil {
		deadline := time.tick_now()
		for time.tick_since(deadline) < 3 * time.Second {
			sync.lock(&srv.mu)
			n := len(srv.conns)
			sync.unlock(&srv.mu)
			if n == 0 do break
			pump()
			time.sleep(time.Millisecond)
		}
	}
	delete(srv.path)
	srv.path = ""
	srv.running = false
}

// A fresh random token for `caller` (64 hex chars). Never logged or put in
// State. single_use: for a child's environment (anyone of the same user can
// read it there, e.g. `ps eww`), so it works for one hello only. Any thread.
socket_mint_token :: proc(caller: Caller, allocator := context.allocator, single_use := false) -> string {
	tok := random_token(allocator)
	sync.lock(&srv.mu)
	srv.next_ref += 1
	srv.tokens[strings.clone(tok)] = {caller = caller, ref = srv.next_ref, single_use = single_use}
	sync.unlock(&srv.mu)
	return tok
}

@(private = "file")
random_token :: proc(allocator := context.allocator) -> string {
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:], allocator))
}

// PI_DESK_SOCKET and a new PI_DESK_TOKEN for a child (temp allocator), or
// nil when the socket is not running.
socket_child_env :: proc(caller: Caller) -> []string {
	if !srv.running do return nil
	tok := socket_mint_token(caller, context.temp_allocator, single_use = true)
	env := make([dynamic]string, 0, 3, context.temp_allocator)
	append(&env, fmt.tprintf("PI_DESK_SOCKET=%s", srv.path), fmt.tprintf("PI_DESK_TOKEN=%s", tok))
	// a pi session (a pi tab, Atlas) learns where app screenshots go: pi-kit
	// checks app_screenshot's files are directly in it. Never PI_DESK_DATA_DIR:
	// pi-desk reads that, so a test-mode pi-desk an agent starts would use the
	// user's real data dir. App programs need neither.
	if caller.kind != .App do append(&env, fmt.tprintf("PI_DESK_SHOTS_DIR=%s", app_shots_dir(context.temp_allocator)))
	return env[:]
}

// The tab is gone (closed, exited, failed to start): revoke its tokens and
// hang up its connections.
socket_forget_tab :: proc(tab_id: u64) {
	if tab_id == 0 do return
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	gone := make([dynamic]string, context.temp_allocator)
	for k, e in srv.tokens do if e.caller.tab_id == tab_id do append(&gone, k)
	for k in gone {
		delete_key(&srv.tokens, k)
		delete(k)
	}
	for c in srv.conns do if c.caller.tab_id == tab_id do sock_shutdown(c.fd)
}

// ---- events (main thread) ----

socket_publish :: proc(ev: Event) {
	if !srv.running do return
	line := event_json(ev)
	request_id: u64
	fin, private := false, false
	switch e in ev {
	case Command_Event:  request_id = e.request_id
	case Finished_Event: request_id, fin, private = e.request_id, true, e.private
	case Job_Event:
	}
	if private do line = event_json(ev, full = true) // its requester's only (below)
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	for s in state.open_sessions do for t in s.tabs do srv.tab_session[t.id] = s.id
	origin, has_origin := srv.origins[request_id]
	for c in srv.conns {
		if c.ref == 0 do continue
		if fin && has_origin && c.id == origin.conn {
			conn_push(c, line, force = true) // completes this connection's own pending request
			continue
		}
		if !c.subscribed || private do continue // a web page's content goes to its requester only
		if has_origin && c.ref == origin.ref do continue // its own event
		if !event_visible_to(ev, c.caller) || !event_matches(c, ev) do continue
		if !conn_push(c, line) {
			c.subscribed = false
			conn_push(c, `{"v":1,"type":"event","event":"dropped","error":"subscriber too slow: events dropped and subscription ended; subscribe again"}`, force = true)
		}
	}
	if fin && has_origin do delete_key(&srv.origins, request_id)
}

// Subscription filters: all, one open session, or one tab. Panel callers
// only ever see their own session.
@(private = "file")
event_matches :: proc(c: ^Conn, ev: Event) -> bool {
	session, tab := c.sub_session, c.sub_tab
	if c.caller.kind == .Panel do session, tab = srv.tab_session[c.caller.tab_id] or_else 0, 0
	if session == 0 && tab == 0 do return true
	e, ok := ev.(Command_Event)
	if !ok do return false // finished events only go to unfiltered subscribers
	tabs := [3]u64{command_tab(e.command), e.caller.tab_id, 0}
	sessions := [2]u64{command_session(e.command), 0}
	#partial switch _ in e.command {
	case New_Shell_Tab, Browser_Open:   tabs[2] = e.result.created_id
	case New_Chat, Open_Session_Cmd:    sessions[1] = e.result.created_id
	}
	for t in tabs do if t != 0 {
		if tab != 0 && t == tab do return true
		if session != 0 && srv.tab_session[t] == session do return true
	}
	if session != 0 do for s in sessions do if s == session do return true
	return false
}

// The tab or open session a command targets (0 = none).
command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Close_Tab:         return c.tab_id
	case Focus_Tab:         return c.tab_id
	case Copy_Selection:    return c.tab_id
	case Terminal_Link:     return c.tab_id
	case Send_Text:         return c.tab_id
	case Tab_Exited:        return c.tab_id
	case Pi_Session_Update: return c.tab_id
	case Pi_Status_Update:  return c.tab_id
	case Pi_Prompt:         return c.tab_id
	case Pi_Reload:         return c.tab_id
	case Pi_Wait_Idle:      return c.tab_id
	case Panel_Set:         return c.tab_id
	case Panel_Remove:      return c.tab_id
	case Pi_Attached:       return c.tab_id
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update:
		return browser_command_tab(cmd)
	case Browser_Tabs, Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Comments, Browser_Agent_Stop:
		return browser_agent_command_tab(cmd)
	case Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Upload_Answer, Browser_Agent_Take_Over, Request_Cancel:
		return browser_act_command_tab(cmd)
	}
	return 0
}

command_session :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Focus_Session: return c.session
	case Close_Session: return c.session
	case New_Shell_Tab: return c.session
	case Browser_Open:  return c.session
	}
	return 0
}

// ---- pi tab bridge (main thread) ----

// Sends a pi_prompt/pi_reload/pi_wait_idle to the tab's bridge connection
// (the newest one with that tab's token). The bridge's result line finishes
// `request_id`. False if no bridge is connected or it is not reading.
socket_bridge_send :: proc(tab_id: u64, request_id: u64, cmd: Command) -> bool {
	if !srv.running do return false
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	// the newest open connection of the tab (one already closing would only fail later)
	target: ^Conn
	for c in srv.conns {
		if c.ref == 0 || c.caller.kind != .Panel || c.caller.tab_id != tab_id do continue
		sync.lock(&c.mu)
		closing := c.closing
		sync.unlock(&c.mu)
		if !closing do target = c
	}
	if target == nil do return false
	srv.next_bridge += 1
	id := fmt.aprintf("d%d", srv.next_bridge)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":"%s","v":%d,"type":`, id, PROTOCOL_VERSION)
	#partial switch c in cmd {
	case Pi_Prompt:
		strings.write_string(&b, `"pi.prompt","text":`)
		json_quote(&b, c.text)
		write_prompt_images(&b, c.images) // Send now's crops (comments.odin)
	case Pi_Reload:
		strings.write_string(&b, `"pi.reload"`)
	case Pi_Wait_Idle:
		strings.write_string(&b, `"pi.wait_idle"`)
		if c.timeout_ms > 0 do fmt.sbprintf(&b, `,"timeout_ms":%d`, c.timeout_ms) // none = no timeout
	case:
		delete(id)
		return false
	}
	strings.write_byte(&b, '}')
	if !conn_push(target, strings.to_string(b)) {
		delete(id)
		return false
	}
	srv.bridge_calls[id] = {request_id = request_id, conn = target.id}
	return true
}

// Sends one request to the tab's bridge that nothing waits for (pending comments: pi.attach,
// pi.attach_clear; comments.odin): `body` follows `"type":`. Its result line is ignored. False
// if no bridge is connected or its queue is full.
// Whether a tab's bridge has an open connection (comments.odin: a line it did not take was a full
// queue, not a missing bridge).
socket_bridge_connected :: proc(tab_id: u64) -> bool {
	if !srv.running do return false
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	for c in srv.conns {
		if c.ref == 0 || c.caller.kind != .Panel || c.caller.tab_id != tab_id do continue
		sync.lock(&c.mu)
		closing := c.closing
		sync.unlock(&c.mu)
		if !closing do return true
	}
	return false
}

socket_bridge_notify :: proc(tab_id: u64, body: string) -> bool {
	if !srv.running do return false
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	target: ^Conn
	for c in srv.conns {
		if c.ref == 0 || c.caller.kind != .Panel || c.caller.tab_id != tab_id do continue
		sync.lock(&c.mu)
		closing := c.closing
		sync.unlock(&c.mu)
		if !closing do target = c
	}
	if target == nil do return false
	srv.next_bridge += 1
	return conn_push(target, fmt.tprintf(`{{"id":"d%d","v":%d,"type":%s}}`, srv.next_bridge, PROTOCOL_VERSION, body))
}

// ---- app tabs (app_tab.odin; main thread) ----

// Whether a line may go to an app: no raw CR or LF in it (Node's readline
// and Python's text mode end a line at a lone CR), so one line stays one
// message. The backstop under app_call's and app_input's own checks.
app_line_ok :: proc(line: string) -> bool {
	return !strings.contains_any(line, "\r\n")
}

// Sends one line to the newest open connection of an app tab's program.
// False if it is not connected, its queue is full (never blocks) or the line
// is not one line (app_line_ok).
socket_app_send :: proc(tab_id: u64, line: string) -> bool {
	if !srv.running || !app_line_ok(line) do return false
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	target: ^Conn
	for c in srv.conns do if c.ref != 0 && c.caller.kind == .App && c.caller.tab_id == tab_id do target = c
	return target != nil && conn_push(target, line)
}

// Whether an app tab's program has an open connection (after its hello).
socket_app_connected :: proc(tab_id: u64) -> bool {
	if !srv.running do return false
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	for c in srv.conns {
		if c.ref == 0 || c.caller.kind != .App || c.caller.tab_id != tab_id do continue
		sync.lock(&c.mu)
		closing := c.closing
		sync.unlock(&c.mu)
		if !closing do return true
	}
	return false
}

// A line from an app's connection (reader thread): a reply to one of
// pi-desk's tab.* requests, or an event. Apps send no commands.
@(private = "file")
app_conn_line :: proc(c: ^Conn, line: string) {
	// strict RFC 8259 and at most JSON_MAX_DEPTH deep (the parser recurses per
	// level): replies and events are passed on as sent
	if !json_valid(line) {
		conn_push(c, reply_json("", fail("invalid JSON (strict RFC 8259, nested at most 64 deep)")), force = true)
		return
	}
	v, err := json.parse_string(line, .JSON, true, context.temp_allocator)
	obj, is := v.(json.Object)
	if err != nil || !is {
		conn_push(c, reply_json("", fail("invalid JSON")), force = true)
		return
	}
	type, _ := obj["type"].(json.String)
	id, _ := obj["id"].(json.String)
	switch type {
	case "result":
		// passed on as sent (app_call is a passthrough): data verbatim, an error's fields kept
		r, valid := app_result_of(line)
		if !valid {
			conn_push(c, reply_json(id, fail("a result must be one JSON object with an object `result`")), force = true)
			return
		}
		inbox_submit(App_Call_Done{tab_id = c.caller.tab_id, wire = r.id, ok = r.ok, error = r.error, code = r.code, data = r.data}, {kind = .Internal})
	case "event":
		ev, _ := obj["event"].(json.String)
		app_event_in(c.caller.tab_id, ev, line)
	case:
		conn_push(c, reply_json(id, fail("an app sends results and events only")), force = true)
	}
}

// ---- connections ----

@(private = "file")
accept_loop :: proc() {
	for !sync.atomic_load(&srv.stopping) {
		fd, ok := sock_accept(srv.listen_fd, 100)
		if !ok do continue
		sync.lock(&srv.mu)
		full := len(srv.conns) >= socket_max_conns
		sync.unlock(&srv.mu)
		if full {
			sock_write_all(fd, transmute([]u8)strings.concatenate({reply_json("", fail("too many connections")), "\n"}, context.temp_allocator))
			sock_close(fd)
			free_all(context.temp_allocator)
			continue
		}
		c := new(Conn)
		c.fd = fd
		c.opened = time.tick_now()
		sync.lock(&srv.mu)
		srv.next_conn += 1
		c.id = srv.next_conn
		append(&srv.conns, c)
		sync.unlock(&srv.mu)
		c.writer = thread.create_and_start_with_poly_data(c, conn_writer)
		if c.writer == nil || thread.create_and_start_with_poly_data(c, conn_reader, self_cleanup = true) == nil {
			conn_finish(c) // no reader will: hang up now
		}
	}
}

// Queues one line (copied). Without force, refuses once the queue holds
// socket_out_cap bytes. Any thread; never blocks on the client.
@(private = "file")
conn_push :: proc(c: ^Conn, line: string, force := false) -> bool {
	sync.lock(&c.mu)
	defer sync.unlock(&c.mu)
	if c.closing do return false
	if !force && c.out_bytes + len(line) > socket_out_cap do return false
	append(&c.out, strings.concatenate({line, "\n"}))
	c.out_bytes += len(line) + 1
	sync.cond_broadcast(&c.cond)
	return true
}

// Reader thread: waits while the client is not reading its replies, so a
// client that only sends cannot grow the queue without bound.
@(private = "file")
conn_wait_room :: proc(c: ^Conn) {
	sync.lock(&c.mu)
	for c.out_bytes > socket_out_cap && !c.closing do sync.cond_wait(&c.cond, &c.mu)
	sync.unlock(&c.mu)
}

@(private = "file")
conn_writer :: proc(c: ^Conn) {
	for {
		sync.lock(&c.mu)
		for len(c.out) == 0 && !c.closing do sync.cond_wait(&c.cond, &c.mu)
		if len(c.out) == 0 {
			sync.unlock(&c.mu)
			return
		}
		line := pop_front(&c.out)
		c.out_bytes -= len(line)
		sync.cond_broadcast(&c.cond) // a reader may wait for room
		sync.unlock(&c.mu)
		ok := sock_write_all(c.fd, transmute([]u8)line)
		delete(line)
		if !ok {
			sock_shutdown(c.fd) // the reader sees the end and cleans up
			sync.lock(&c.mu)
			for l in c.out do delete(l)
			clear(&c.out)
			c.out_bytes = 0
			c.closing = true
			sync.cond_broadcast(&c.cond)
			sync.unlock(&c.mu)
			return
		}
	}
}

@(private = "file")
conn_reader :: proc(c: ^Conn) {
	buf: [dynamic]u8
	chunk: [16 * 1024]u8
	scanned := 0 // bytes of buf known to hold no newline
	loop: for {
		if c.ref == 0 { 	// before hello: a deadline, so silent connections do not pile up
			left := socket_hello_ms - int(time.duration_milliseconds(time.tick_since(c.opened)))
			if left <= 0 || !sock_wait_readable(c.fd, left) {
				conn_push(c, reply_json("", fail("no hello in time")), force = true)
				break
			}
		}
		n := sock_read(c.fd, chunk[:])
		if n <= 0 do break
		append(&buf, ..chunk[:n])
		for {
			i := strings.index_byte(string(buf[scanned:]), '\n')
			if i >= 0 do i += scanned
			if (i < 0 ? len(buf) : i) > (c.ref == 0 ? SOCKET_HELLO_MAX : socket_line_max) {
				conn_push(c, reply_json("", fail("line too long")), force = true)
				break loop
			}
			if i < 0 {
				scanned = len(buf)
				break
			}
			line := strings.trim_right(string(buf[:i]), "\r")
			conn_wait_room(c)
			keep := conn_line(c, line)
			remove_range(&buf, 0, i + 1)
			scanned = 0
			free_all(context.temp_allocator)
			if !keep do break loop
		}
	}
	delete(buf)
	conn_finish(c)
}

// Unregisters, fails the bridge calls it owed, flushes what is queued, closes.
@(private = "file")
conn_finish :: proc(c: ^Conn) {
	sync.lock(&srv.mu)
	for x, i in srv.conns do if x == c {ordered_remove(&srv.conns, i); break}
	// another connection of this pi tab still open: the bridge is reconnecting
	bridge := c.ref != 0 && c.caller.kind == .Panel
	others := false
	if bridge do for x in srv.conns do if x.ref != 0 && x.caller.kind == .Panel && x.caller.tab_id == c.caller.tab_id do others = true
	why := others ? "the pi tab's bridge is reconnecting" : "the pi tab's bridge disconnected"
	owed := make([dynamic]string, context.temp_allocator)
	for k, call in srv.bridge_calls do if call.conn == c.id do append(&owed, k)
	for k in owed {
		key, call := delete_key(&srv.bridge_calls, k)
		inbox_submit(Bridge_Done{request_id = call.request_id, error = why}, {kind = .Internal})
		delete(key)
	}
	// what it still runs ends (browser actions and reads): nobody is there for the answer
	gone := make([dynamic]u64, context.temp_allocator)
	for id, o in srv.origins do if o.conn == c.id do append(&gone, id)
	for id in gone do inbox_submit(Request_Cancel{request_id = id, closed = true}, {kind = .Internal})
	// no bridge left: nobody reports this tab's status any more
	if bridge && !others do inbox_submit(Pi_Status_Update{tab_id = c.caller.tab_id, agent = .Unknown}, {kind = .Internal})
	sync.unlock(&srv.mu)
	sync.lock(&c.mu)
	c.closing = true
	sync.cond_broadcast(&c.cond)
	sync.unlock(&c.mu)
	if c.writer != nil {
		thread.join(c.writer)
		thread.destroy(c.writer)
	}
	sock_close(c.fd)
	delete(c.out)
	free(c)
}

// A reply that the main thread queues itself (Reply.deliver), so it is on
// the wire before any event that follows the command.
@(private = "file")
Conn_Reply :: struct {
	using reply: Reply,
	conn:        ^Conn,
	id:          string,
}

@(private = "file")
deliver_reply :: proc(r: ^Reply, request_id: u64) {
	cr := (^Conn_Reply)(r)
	conn_push(cr.conn, reply_json(cr.id, r.result, request_id), force = true) // one per request: bounded
	if !r.result.pending {
		sync.lock(&srv.mu)
		delete_key(&srv.origins, request_id)
		sync.unlock(&srv.mu)
	}
}

// One request line. False: close the connection.
@(private = "file")
conn_line :: proc(c: ^Conn, line: string) -> bool {
	if strings.trim_space(line) == "" do return true
	m, err := parse_request(line, context.temp_allocator)
	if c.ref == 0 {
		if err == "" && m.type != "hello" do err = "the first message must be hello"
		reconnect: string
		if err == "" {
			sync.lock(&srv.mu)
			e, known := srv.tokens[m.token]
			if known {
				c.caller = e.caller
				c.ref = e.ref
				if e.single_use {
					// swap the env token for one only this bridge knows (same caller)
					k, _ := delete_key(&srv.tokens, m.token)
					delete(k)
					reconnect = random_token(context.temp_allocator)
					srv.tokens[strings.clone(reconnect)] = {caller = e.caller, ref = e.ref}
				}
			}
			sync.unlock(&srv.mu)
			if !known do err = "unknown token"
		}
		if err != "" {
			conn_push(c, reply_json(m.id, fail(err)), force = true)
			return false
		}
		conn_push(c, reply_json(m.id, {ok = true, data = welcome_json(c.caller, reconnect)}), force = true)
		return true
	}
	if c.caller.kind == .App {
		app_conn_line(c, line)
		return true
	}
	if err != "" {
		conn_push(c, reply_json(m.id, fail(err)), force = true)
		return true
	}
	switch m.type {
	case "hello":
		conn_push(c, reply_json(m.id, fail("already said hello")), force = true)
	case "subscribe":
		sync.lock(&srv.mu)
		c.subscribed, c.sub_session, c.sub_tab = true, m.session, m.tab_id
		sync.unlock(&srv.mu)
		conn_push(c, reply_json(m.id, {ok = true}), force = true)
	case "unsubscribe":
		sync.lock(&srv.mu)
		c.subscribed = false
		sync.unlock(&srv.mu)
		conn_push(c, reply_json(m.id, {ok = true}), force = true)
	case "cancel":
		// the requester ends one of its own long-running requests (a browser action or read)
		sync.lock(&srv.mu)
		o, has := srv.origins[m.request_id]
		mine := has && o.conn == c.id
		sync.unlock(&srv.mu)
		if !mine {
			conn_push(c, reply_json(m.id, fail("no running request with that id from this connection")), force = true)
			break
		}
		r := Conn_Reply{conn = c, id = m.id}
		r.deliver = deliver_reply
		inbox_submit(Request_Cancel{request_id = m.request_id}, {kind = .Internal}, &r.reply)
		sync.one_shot_event_wait(&r.done)
		result_free(r.result)
	case "result":
		// a bridge answering one of our pi.* requests; never replied to
		sync.lock(&srv.mu)
		if call, ok := srv.bridge_calls[m.id]; ok && call.conn == c.id {
			k, _ := delete_key(&srv.bridge_calls, m.id)
			delete(k)
			inbox_submit(Bridge_Done{request_id = call.request_id, ok = m.result.ok, error = m.result.error}, {kind = .Internal})
		}
		sync.unlock(&srv.mu)
	case "command", "pi.session", "pi.status", "panel.set", "panel.remove", "pi.attached":
		cmd := m.command
		// a bridge reports for its own tab
		#partial switch &x in cmd {
		case Pi_Session_Update: if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Pi_Status_Update:  if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Panel_Set:         if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Panel_Remove:      if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Pi_Attached:       if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		}
		r := Conn_Reply{conn = c, id = m.id}
		r.deliver = deliver_reply
		sync.lock(&srv.mu) // registered before the main thread can publish its events
		id := inbox_submit(cmd, c.caller, &r.reply)
		srv.origins[id] = {conn = c.id, ref = c.ref}
		sync.unlock(&srv.mu)
		sync.one_shot_event_wait(&r.done)
		result_free(r.result)
	}
	return true
}

@(private = "file")
welcome_json :: proc(caller: Caller, reconnect: string) -> string {
	caps: string
	switch caller.kind {
	case .Panel:                             caps = `["pi_tab","panels","state","events"]`
	case .Control, .Script, .UI, .Internal:  caps = `["commands","state","events"]`
	case .App:                               caps = `["app","frames","input"]`
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"app":"pi-desk","caller":"%s","tab_id":%d,"capabilities":%s`, PROTOCOL_VERSION, CALLER_NAMES[caller.kind], caller.tab_id, caps)
	if reconnect != "" do fmt.sbprintf(&b, `,"reconnect_token":"%s"`, reconnect)
	// an app tab: where its frames go (docs/ENGINE-BRIDGE.md §1); the key is never logged
	when ODIN_OS == .Darwin do if caller.kind == .App {
		key: [32]u8
		if pd_frames_chan_key(caller.tab_id, &key[0]) == 1 {
			fmt.sbprintf(&b, `,"frames":{{"service":"%s","key":"%s","device":%d}}`, string(pd_frames_service()), string(hex.encode(key[:], context.temp_allocator)), pd_frames_device_id())
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
