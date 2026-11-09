package core

// The control socket (docs/PROTOCOL.md): NDJSON over a local socket
// (socket_posix.odin). One accept thread; per connection a reader thread
// (parses lines, submits commands to the inbox and waits for each reply, so a
// connection's requests run in order) and a writer thread (drains a bounded
// outbound queue, so the main thread never blocks on a slow client).
//
// Tokens are routing + capability: Deckhand mints one per pi tab it starts
// (caller panel, that tab) and passes it as DECKHAND_TOKEN; `--print-token`
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
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "base:runtime"
import cw "../corewire"
import hw "../holderwire"
import jg "../jsonguard"
import "../trust"

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
	hello:      Hello_Kind, // how a hello shows it (tokens.json keeps it)
	hid:        [32]u8, // .Challenge: its token id (hello_token_id)
}

// How a hello shows a token. Plain: sent as `token` (every token but the reconnect tokens the
// challenge hello's clients get, and those minted before M4-B, which kept pi sessions' bridges
// still send that way). Challenge: proved, never sent (hello_proof.odin); a plain hello with it
// is refused.
Hello_Kind :: enum u8 {
	Plain,
	Challenge,
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
	// a challenge hello between its two lines (reader thread only)
	ch_open:     bool,
	ch_key:      [32]u8,
	ch_id:       [64]u8,
	ch_cnonce:   [64]u8,
	ch_snonce:   [64]u8,
	handoff:     bool, // a framed hello was answered: the reader hands the fd to socket_framed_handler
	peer:        trust.Peer, // the peer read at accept, before any byte was read (the window's checks)
	peer_tok:    trust.Audit_Token,
	version:     string, // a framed hello's window version (temp: until the handoff)
	hub:         bool, // a framed hello from another machine's core (window_sock.odin)
	from:        string, // ...that machine's name (temp: until the handoff)
}

// Who takes a connection after its framed hello (docs/PROTOCOL.md §5a): the fd, the caller (the
// window's, ui), the bytes the reader read past the hello line (valid during the call), the peer
// read at accept and the window's version. Nil: a framed hello is refused. A separate core sets it
// (window_sock.odin: window_token_publish); only the window's hello gets that far.
socket_framed_handler: proc(fd: Sock_Fd, caller: Caller, leftover: []u8, peer: trust.Peer, version: string, hub: bool, from: string)

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
	claude_pids:  map[u64]i32, // a Claude tab -> its process (the login shell that execs claude): its token's hellos must come from below it
	// tokens.json (keep_sessions; socket_tokens_enable): tabs whose process lives in the holder
	tok_on:       bool,
	tok_path:     string,
	tok_key:      [MACFILE_KEY_LEN]u8,
	tok_body:     string, // the newest tokens.json body (tokens_save), written by tokens_flush
	tok_gen:      u64, // bumped by each tokens_save
	tok_written:  u64, // the gen tokens_flush last wrote
	tok_wmu:      sync.Mutex, // one tokens.json writer at a time (never held with mu while writing)
	tab_term:     map[u64]u32, // a tab -> the holder terminal its process runs in
	tab_ro:       map[u64]Ro_Saved, // a read-only Claude tab's ack state (claude.odin)
	tab_start:    map[u64]Held_Start, // what a held tab's process was started as
	hashed:       map[[32]u8]Hashed_Token, // tokens from tokens.json: known by their hash until a hello shows them
	held_root:    map[u32]i32, // loaded, not adopted yet: a term's claude_pids root
	held_ro:      map[u32]Ro_Saved, // loaded, not adopted yet: a term's read-only ack state
	held_start:   map[u32]Held_Start, // loaded, not adopted yet: what a term was started as
	next_ref:     u64,
	next_conn:    u64,
	next_bridge:  u64,
}

@(private = "file")
srv: Server

socket_running :: proc() -> bool {return srv.running}

// Starts listening on <dir>/core.sock (dir default: sock_runtime_dir). The name is stable, so
// tabs that outlive this process keep their DECKHAND_SOCKET (docs/plans/background-core.md
// §5.1); a stale one is replaced (main.odin holds core.lock first). Main thread.
socket_start :: proc(dir := "") -> bool {
	if srv.running do return true
	d := dir
	if d == "" {
		why: string
		d, why = sock_runtime_dir_why(context.temp_allocator)
		if why != "" {
			fmt.eprintln("Deckhand: control socket:", why)
			return false
		}
	}
	path := fmt.aprintf("%s/%s", d, CORE_SOCK)
	fd, ok := sock_listen(path)
	if !ok {
		fmt.eprintln("Deckhand: control socket: cannot listen on", path)
		delete(path)
		return false
	}
	srv.path = path
	srv.listen_fd = fd
	srv.stopping = false
	srv.running = true
	srv.accept = thread.create_and_start(accept_loop)
	if srv.accept == nil {
		fmt.eprintln("Deckhand: control socket: cannot start the accept thread")
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
	clear(&srv.claude_pids)
	tokens_reset() // tokens.json stays as it was last written: the holder's processes keep their tokens
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
	// the user's and Deckhand's own callers have no token: the window's one door is
	// core_attach_window (window_link.odin). A token this returns for them knows nothing.
	if !token_caller_ok(caller) {
		fmt.eprintln("Deckhand: no token is made for the", CALLER_NAMES[caller.kind], "caller")
		return tok
	}
	sync.lock(&srv.mu)
	srv.next_ref += 1
	srv.tokens[strings.clone(tok)] = {caller = caller, ref = srv.next_ref, single_use = single_use}
	tokens_save()
	sync.unlock(&srv.mu)
	tokens_flush()
	return tok
}

// Callers a token may stand for: never ui (only the window's attach is the user), internal or tab_host.
token_caller_ok :: proc(c: Caller) -> bool {return c.kind != .UI && c.kind != .Internal && c.kind != .Tab_Host}

@(private = "file")
random_token :: proc(allocator := context.allocator) -> string {
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	return string(hex.encode(raw[:], allocator))
}

// DECKHAND_SOCKET and a new DECKHAND_TOKEN for an app tab's program (temp allocator;
// docs/ENGINE-BRIDGE.md: a stable interface), or nil when the socket is not running.
socket_child_env :: proc(caller: Caller) -> []string {
	if !srv.running do return nil
	tok := socket_mint_token(caller, context.temp_allocator, single_use = true)
	env := make([dynamic]string, 0, 2, context.temp_allocator)
	append(&env, fmt.tprintf("DECKHAND_SOCKET=%s", srv.path), fmt.tprintf("DECKHAND_TOKEN=%s", tok))
	return env[:]
}

// A pi session's (a pi tab, Atlas) environment for Deckhand's pi integration (temp allocator;
// pi_integration.odin), or nil when the socket is not running: DECKHAND_SOCKET, a new
// single-use DECKHAND_TOKEN and DECKHAND_SHOTS_DIR, where app screenshots go (the integration
// checks app_screenshot's files are directly in it). Never pi-kit's DECKHAND_SOCKET and
// DECKHAND_TOKEN: its desk extensions switch on with those, and stay inert without them. Never
// DECKHAND_DATA_DIR: Deckhand reads that, so a test-mode Deckhand an agent starts would use the
// user's real data dir. Also nil when the pi will not load the integration (pi_integration_args:
// none in this build, or a pi too old): no token is minted that nothing would use, which its bash
// and ! commands would inherit.
socket_pi_env :: proc(caller: Caller) -> []string {
	if !srv.running || len(pi_integration_args()) == 0 do return nil
	tok := socket_mint_token(caller, context.temp_allocator, single_use = true)
	env := make([dynamic]string, 0, 3, context.temp_allocator)
	append(&env, fmt.tprintf("DECKHAND_SOCKET=%s", srv.path), fmt.tprintf("DECKHAND_TOKEN=%s", tok))
	append(&env, fmt.tprintf("DECKHAND_SHOTS_DIR=%s", app_shots_dir(context.temp_allocator)))
	return env[:]
}

// The environment a Claude tab's process gets (claude.odin; temp allocator): DECKHAND_SOCKET, a
// fresh MULTI-use token in DECKHAND_CLAUDE_TOKEN (the CLI and the hooks are a new process per call,
// so a single-use token cannot work; see docs/CLAUDE.md for what that costs and why the hello
// checks the caller's process), DECKHAND_CLI (the bundled CLI, so plugin and app match),
// DECKHAND_SHOTS_DIR and DECKHAND_CLAUDE_TAB. Tokens the tab had before are revoked first. Nil when
// the socket is not running.
socket_claude_env :: proc(tab_id: u64, cli: string) -> []string {
	if !srv.running do return nil
	socket_forget_tab(tab_id)
	tok := socket_mint_token({kind = .Panel, tab_id = tab_id, claude = true}, context.temp_allocator)
	env := make([dynamic]string, 0, 5, context.temp_allocator)
	append(&env, fmt.tprintf("DECKHAND_SOCKET=%s", srv.path), fmt.tprintf("DECKHAND_CLAUDE_TOKEN=%s", tok))
	if cli != "" do append(&env, fmt.tprintf("DECKHAND_CLI=%s", cli))
	append(&env, fmt.tprintf("DECKHAND_SHOTS_DIR=%s", app_shots_dir(context.temp_allocator)), fmt.tprintf("DECKHAND_CLAUDE_TAB=%d", tab_id))
	return env[:]
}

// The Claude tab's process started (its pid): its token's hellos must come from it or below it.
socket_claude_pid :: proc(tab_id: u64, pid: i32) {
	sync.lock(&srv.mu)
	srv.claude_pids[tab_id] = pid
	tokens_save()
	sync.unlock(&srv.mu)
	tokens_flush()
}

// Whether a hello with a Claude tab's token comes from that tab's own processes: the connecting
// process (its pid when it connected) is the tab's process or descends from it (at most 64
// parents up). A token read from the environment by any other process of the user is refused.
// srv.mu held.
@(private = "file")
socket_claude_peer_ok :: proc(c: ^Conn, tab_id: u64) -> bool {
	root, has := srv.claude_pids[tab_id]
	if !has || root <= 1 do return false
	pid := sock_peer_pid(c.fd)
	for _ in 0 ..< 64 {
		if pid <= 1 do return false
		if pid == root do return true
		pid = pid_parent(pid)
	}
	return false
}

// The tab is gone (closed, exited, failed to start): revoke its tokens and
// hang up its connections.
socket_forget_tab :: proc(tab_id: u64) {
	if tab_id == 0 do return
	defer tokens_flush() // after the unlock below (defers run last first)
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	gone := make([dynamic]string, context.temp_allocator)
	for k, e in srv.tokens do if e.caller.tab_id == tab_id do append(&gone, k)
	for k in gone {
		delete_key(&srv.tokens, k)
		delete(k)
	}
	for c in srv.conns {
		if c.caller.tab_id != tab_id do continue
		sock_shutdown(c.fd) // the reader sees the end and cleans up
		// no longer the tab's at once (socket_app_connected): its process is gone, and a new one
		// (Restart) must not be taken for having closed it
		sync.lock(&c.mu)
		c.closing = true
		sync.cond_broadcast(&c.cond)
		sync.unlock(&c.mu)
	}
	delete_key(&srv.claude_pids, tab_id)
	tokens_forget_tab(tab_id)
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
	if c.caller.kind == .Panel {
		// its own session only; a tab Deckhand does not know (yet) sees nothing
		own, known := srv.tab_session[c.caller.tab_id]
		if !known || own == 0 do return false
		session, tab = own, 0
	}
	if session == 0 && tab == 0 do return true
	e, ok := ev.(Command_Event)
	if !ok do return false // finished events only go to unfiltered subscribers
	tabs := [3]u64{command_tab(e.command), e.caller.tab_id, 0}
	sessions := [2]u64{command_session(e.command), 0}
	#partial switch _ in e.command {
	case New_Shell_Tab, Browser_Open, Show_File: tabs[2] = e.result.created_id
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
	case Move_Tab:          return c.tab_id
	case Split_Pane:        return c.tab_id
	case Copy_Selection:    return c.tab_id
	case Terminal_Link:     return c.tab_id
	case Send_Text:         return c.tab_id
	case Tab_Exited:        return c.tab_id
	case Program_Status:    return c.tab_id
	case Set_Unread:        return c.tab_id
	case Pi_Session_Update: return c.tab_id
	case Pi_Status_Update:  return c.tab_id
	case Pi_Prompt:         return c.tab_id
	case Pi_Reload:         return c.tab_id
	case Pi_Restart:        return c.tab_id
	case Pi_Wait_Idle:      return c.tab_id
	case Panel_Set:         return c.tab_id
	case Panel_Remove:      return c.tab_id
	case Pi_Attached:       return c.tab_id
	case Browser_Open, Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop, Browser_Update, Browser_Popup_Open:
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
	case Show_File:     return c.session
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
		if c.ref == 0 || c.caller.kind != .Panel || c.caller.claude || c.caller.tab_id != tab_id do continue
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
		if c.ref == 0 || c.caller.kind != .Panel || c.caller.claude || c.caller.tab_id != tab_id do continue
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
		if c.ref == 0 || c.caller.kind != .Panel || c.caller.claude || c.caller.tab_id != tab_id do continue
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
// Deckhand's tab.* requests, or an event. Apps send no commands.
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
		c.peer, c.peer_tok = trust.peer_read_token(fd) // before any byte is read (window_hello_check)
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
			if c.handoff {
				conn_handoff(c, buf[i + 1:])
				delete(buf)
				free_all(context.temp_allocator)
				return
			}
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
	bridge := c.ref != 0 && c.caller.kind == .Panel && !c.caller.claude // a Claude tab's CLI is no pi bridge
	others := false
	if bridge do for x in srv.conns do if x.ref != 0 && x.caller.kind == .Panel && !x.caller.claude && x.caller.tab_id == c.caller.tab_id do others = true
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
		if err == "" && m.type == "hello.proof" && !c.ch_open do err = "the first message must be hello"
		if err == "" && m.type == "hello" && c.ch_open do err = "the challenge wants hello.proof"
		if err == "" && m.type != "hello" && m.type != "hello.proof" do err = "the first message must be hello"
		if err == "" && m.framed && socket_framed_handler == nil do err = "framed mode is not available in this build"
		// the framed wire is the window's only: its own token and checks, never a line token's caller
		if err == "" && m.framed && (m.type != "hello" || m.token_id != "") do err = "framed mode is only for Deckhand's window"
		if err == "" && m.framed && m.peer != "" && m.peer != "hub" do err = "framed mode is only for Deckhand's window"
		if err == "" && m.framed {
			hub := m.peer == "hub"
			why, version := window_hello_check(c.fd, c.peer, c.peer_tok, m.token, hub, m.core)
			if why != "" {
				conn_push(c, reply_json(m.id, fail(why)), force = true)
				return false
			}
			c.caller, c.version, c.hub, c.from = {kind = .UI}, version, hub, hub_from_name(m.from)
			return conn_welcome(c, m.id, 0, "", false, true)
		}
		if err == "" && m.type == "hello" && m.token_id != "" do return conn_challenge(c, m)
		if err == "" && m.type == "hello.proof" do return conn_proof(c, m)
		reconnect: string
		ref: u64
		if err == "" {
			sync.lock(&srv.mu)
			e, known := token_find(m.token) // this run's, or one from tokens.json
			// a Claude tab's token works only from that tab's own processes
			if known && e.caller.claude && !socket_claude_peer_ok(c, e.caller.tab_id) {
				sync.unlock(&srv.mu)
				conn_push(c, reply_json(m.id, fail("this token works only from its Claude tab's own processes")), force = true)
				return false
			}
			// a challenge-only token is never accepted as sent: whoever sent it should not have it
			if known && e.hello == .Challenge {
				sync.unlock(&srv.mu)
				conn_push(c, reply_json(m.id, fail("this token needs the challenge hello")), force = true)
				return false
			}
			if known {
				c.caller = e.caller // socket_forget_tab finds it from here on
				ref = e.ref
				if e.single_use {
					// swap the env token for one only this bridge knows (same caller)
					k, _ := delete_key(&srv.tokens, m.token)
					delete(k)
					reconnect = random_token(context.temp_allocator)
					ne := Token_Entry{caller = e.caller, ref = e.ref}
					if m.challenge {
						// the client proves it from now on (hello_proof.odin); an older bridge,
						// which does not say challenge, keeps the plain hello
						ne.hello = .Challenge
						ne.hid = hello_token_id(token_hash(reconnect))
					}
					srv.tokens[strings.clone(reconnect)] = ne
					tokens_save()
				}
			}
			sync.unlock(&srv.mu)
			tokens_flush()
			if !known do err = "unknown token"
		}
		if err != "" {
			conn_push(c, reply_json(m.id, fail(err)), force = true)
			return false
		}
		return conn_welcome(c, m.id, ref, reconnect, reconnect != "" && m.challenge, m.framed)
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
		case Claude_Session_Report: if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Turn_Report:    if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Readonly_Ack:   if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Comments:       if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Attached:       if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Todos:          if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Task:           if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Subagent:       if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Background:     if x.tab_id == 0 do x.tab_id = c.caller.tab_id
		case Claude_Model_Report:   if x.tab_id == 0 do x.tab_id = c.caller.tab_id
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

// The hello's reply, and from then on the connection counts as its caller's. The reply is queued
// in the same step that makes it count (c.ref: socket_app_send, socket_bridge_send and events
// look for it), so nothing that Deckhand sends it can come before its hello reply
// (TAB-PROTOCOL.md §3). framed: the reply carries the framed fields and the reader hands the
// connection over (conn_handoff); it never counts as a line connection.
@(private = "file")
conn_welcome :: proc(c: ^Conn, id: string, ref: u64, reconnect: string, reconnect_challenge, framed: bool) -> bool {
	data := welcome_json(c.caller, reconnect, reconnect_challenge, framed)
	welcome := reply_json(id, {ok = true, data = data})
	if framed {
		conn_push(c, welcome, force = true)
		c.handoff = true
		return true
	}
	sync.lock(&srv.mu)
	c.ref = ref
	conn_push(c, welcome, force = true)
	sync.unlock(&srv.mu)
	return true
}

// A challenge-only token, by its id (srv.mu held): this run's, or one from tokens.json whose
// terminal was adopted. key: its SHA-256, the proofs' key.
@(private = "file")
token_find_challenge :: proc(id: [32]u8) -> (e: Token_Entry, key: [32]u8, ok: bool) {
	for tok, x in srv.tokens do if x.hello == .Challenge && x.hid == id {
		if !token_caller_ok(x.caller) do return {}, {}, false
		return x, token_hash(tok), true
	}
	for k, h in srv.hashed do if h.hello == .Challenge && h.hid == id && h.caller.tab_id != 0 {
		return h.entry, k, true
	}
	return {}, {}, false
}

// The challenge hello's first line: {"type":"hello","token_id","nonce"}. The core answers with its
// nonce and its proof (it knows the token's key), and waits for hello.proof. An unknown id ends
// the connection, as an unknown token does.
@(private = "file")
conn_challenge :: proc(c: ^Conn, m: Request_Msg) -> bool {
	if !hex64_ok(m.token_id) || !hex64_ok(m.nonce) {
		conn_push(c, reply_json(m.id, fail("token_id and nonce must be 64 lowercase hex digits")), force = true)
		return false
	}
	idb, _ := hex.decode(transmute([]u8)m.token_id, context.temp_allocator)
	id: [32]u8
	copy(id[:], idb)
	sync.lock(&srv.mu)
	_, key, known := token_find_challenge(id)
	sync.unlock(&srv.mu)
	if !known {
		conn_push(c, reply_json(m.id, fail("unknown token")), force = true)
		return false
	}
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	snonce := hex32(raw)
	c.ch_open, c.ch_key = true, key
	copy(c.ch_id[:], m.token_id)
	copy(c.ch_cnonce[:], m.nonce)
	copy(c.ch_snonce[:], snonce)
	p := hello_proof(key, "core", m.nonce, snonce)
	conn_push(c, reply_json(m.id, {ok = true, data = fmt.tprintf(`{{"challenge":"%s","proof":"%s"}}`, snonce, hex32(p))}), force = true)
	return true
}

// The challenge hello's second line: {"type":"hello.proof","proof"}. Checked against the key from
// the first line, and the token still known (revoked in
// between: unknown). Then the hello reply, as for a plain hello (no reconnect token: a challenge
// token is never single-use).
@(private = "file")
conn_proof :: proc(c: ^Conn, m: Request_Msg) -> bool {
	defer {
		trust.wipe(c.ch_key[:])
		c.ch_open = false
	}
	if !hex64_ok(m.proof) {
		conn_push(c, reply_json(m.id, fail("proof must be 64 lowercase hex digits")), force = true)
		return false
	}
	id_hex := string(c.ch_id[:])
	want := hello_proof(c.ch_key, "client", string(c.ch_cnonce[:]), string(c.ch_snonce[:]))
	if !hex64_equal(hex32(want), m.proof) {
		conn_push(c, reply_json(m.id, fail("the proof does not verify")), force = true)
		return false
	}
	idb, _ := hex.decode(transmute([]u8)id_hex, context.temp_allocator)
	id: [32]u8
	copy(id[:], idb)
	sync.lock(&srv.mu)
	e, key, known := token_find_challenge(id)
	if known && key == c.ch_key do c.caller = e.caller // socket_forget_tab finds it from here on
	sync.unlock(&srv.mu)
	if !known || key != c.ch_key {
		conn_push(c, reply_json(m.id, fail("unknown token")), force = true)
		return false
	}
	return conn_welcome(c, m.id, e.ref, "", false, m.framed)
}

// After a framed hello's reply: the writer sends what is queued (the reply) and stops, the
// connection leaves the line server, and socket_framed_handler owns the fd from here.
@(private = "file")
conn_handoff :: proc(c: ^Conn, leftover: []u8) {
	sync.lock(&c.mu)
	c.closing = true // the writer drains its queue, then returns
	sync.cond_broadcast(&c.cond)
	sync.unlock(&c.mu)
	if c.writer != nil {
		thread.join(c.writer)
		thread.destroy(c.writer)
		c.writer = nil
	}
	sync.lock(&srv.mu)
	for x, i in srv.conns do if x == c {ordered_remove(&srv.conns, i); break}
	sync.unlock(&srv.mu)
	h := socket_framed_handler
	if h == nil do sock_close(c.fd) // cleared since the hello: nobody takes it
	else do h(c.fd, c.caller, leftover, c.peer, c.version, c.hub, c.from)
	for l in c.out do delete(l)
	delete(c.out)
	free(c)
}

// §5.2's hello reply fields for a framed connection, after the usual ones.
@(private = "file")
framed_fields :: proc(b: ^strings.Builder, caller: Caller) {
	fmt.sbprintf(b, `,"framed":true,"generation":%d,"version":`, cw.GENERATION)
	json_quote(b, core_version())
	strings.write_string(b, `,"features":[`)
	for f, i in CORE_FEATURES {
		if i > 0 do strings.write_byte(b, ',')
		json_quote(b, f)
	}
	strings.write_string(b, `],"methods":[`)
	n := 0
	for spec in COMMAND_SPECS {
		if spec.who == .Internal || !who_allows(caller.kind, spec.who) do continue
		if n > 0 do strings.write_byte(b, ',')
		json_quote(b, spec.type)
		n += 1
	}
	linger := "" // Linux: false when jobs stop at logout (§8.4, launch_linux.odin); unknown: left out
	when ODIN_OS == .Linux do if linger_state != .Unknown do linger = linger_state == .On ? `,"linger":true` : `,"linger":false`
	fmt.sbprintf(b, `],"machine":{{"os":"%s","arch":"%s"%s}},"holder_wire":%d,"snapshot":["%s","vt"],"build":"%s"`, ODIN_OS_STRING, ODIN_ARCH_STRING, linger, hw.WIRE, SNAPSHOT_GHOSTSNP, core_build())
}

// What a core says it can do beyond its generation (the framed hello's `features`): optional
// behaviour is gated on these (§7.5).
CORE_FEATURES := [?]string{"challenge_hello"}

// This core's release version ("X.Y.Z" from its bundle's Info.plist), or "" for a development
// build. Read once.
@(private = "file")
core_version_once: sync.Once
@(private = "file")
core_version_value: string

core_version :: proc() -> string {
	sync.once_do(&core_version_once, proc() {
		v, _, _ := update_env_find(false, "", "")
		core_version_value = strings.clone(v, runtime.heap_allocator())
	})
	return core_version_value
}

@(private = "file")
welcome_json :: proc(caller: Caller, reconnect: string, reconnect_challenge := false, framed := false) -> string {
	caps: string
	switch caller.kind {
	case .Panel:                             caps = caller.claude ? `["claude_tab","state","events"]` : `["pi_tab","panels","state","events"]`
	case .Control, .Script, .UI, .Internal:  caps = `["commands","state","events"]`
	case .App:                               caps = `["app","frames","input"]`
	case .Tab_Host, .None:                   caps = `[]` // never a socket's (token_caller_ok)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"app":"deckhand","caller":"%s","tab_id":%d,"capabilities":%s`, PROTOCOL_VERSION, caller.claude ? "claude" : CALLER_NAMES[caller.kind], caller.tab_id, caps)
	if reconnect != "" do fmt.sbprintf(&b, `,"reconnect_token":"%s"`, reconnect)
	if reconnect != "" && reconnect_challenge do strings.write_string(&b, `,"reconnect_hello":"challenge"`)
	if framed do framed_fields(&b, caller)
	// an app tab: where its frames go (docs/ENGINE-BRIDGE.md §1); the key is never logged
	// (what the window reported: window.facts, window.tab_facts; this runs on the reader thread)
	if caller.kind == .App {
		service, key, device, fps, scale, known := window_app_hello(caller.tab_id)
		if service != "" && key != "" do fmt.sbprintf(&b, `,"frames":{{"service":"%s","key":"%s","device":%d}}`, service, key, device)
		// and the display it shows on: the rate to pace at and the backing scale (§2.1; tab.display
		// follows when they change)
		if known do fmt.sbprintf(&b, `,"display":%s`, app_display_json(fps, scale))
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// An app tab's display, as the hello reply's `display` and tab.display's fields carry it
// (docs/ENGINE-BRIDGE.md §2.1): the screen's maximum frames per second and its backing scale.
app_display_json :: proc(fps: int, scale: f32) -> string {
	return fmt.tprintf(`{{"fps":%d,"scale":%v}}`, fps, scale)
}

// The connection that sent request `request_id` (its Conn id), 0 if none (the user, a script, Deckhand).
socket_request_conn :: proc(request_id: u64) -> u64 {
	if request_id == 0 do return 0
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	if o, ok := srv.origins[request_id]; ok do return u64(o.conn)
	return 0
}

// ---- tokens.json: tokens that outlive Deckhand (keep_sessions) ----
//
// A process kept running by the session holder while Deckhand is closed keeps the token it was
// given. So with keep_sessions on, the tokens, claude_pids and read-only ack state of every tab
// whose process runs in the holder are written to <data>/tokens.json on every change, MAC'd with
// the holder's key (macfile.odin; docs/plans/background-core.md §5.3 B3). Hashes only, never a
// token. Tab ids are new each launch, so entries are keyed by the holder terminal (`term`).
//
// The integrator's calls (main thread):
// - socket_tokens_enable(path, key): the holder WELCOMEd and keep_sessions is on. Loads the old
//   file (a bad or missing MAC loads nothing: every old token is unknown) and writes from now on.
// - socket_tokens_bind(tab_id, term, start): the tab's process was SPAWNED in holder terminal
//   `term` (after its env was built: tokens minted before the bind are the tab's too), started
//   as `start` (the tab kind, pi's read-only flag and optional extensions): an adopt checks the
//   restored tab against it (socket_tokens_start_of).
// - socket_tokens_adopt(term, tab_id, start): a running terminal from the old run is the new
//   tab `tab_id`: its loaded tokens, claude root pid and read-only state are that tab's, and
//   `start` what it is now. False: the file had nothing for it (show "Reconnect needed: restart
//   this tab").
// - socket_tokens_release(term): a loaded terminal that will not be adopted.
// - socket_tokens_prune(terms): at adopt, drop what was loaded for terminals the holder no
//   longer lists (an id can come back for a new terminal).
// - socket_tokens_disable(remove): keep_sessions went off or the holder is gone.
// socket_forget_tab (the tab closed, exited or restarts) drops the tab's entries and binding.
// With keep_sessions off nothing here runs and no file is written.
//
// Body (JSON, after the macfile header):
//   {"v":1,"terms":[{"term":7,"kind":"pi","pi_ro":false,"extras":5,"claude_root":4242,
//     "ro":{"need":true,"acked":true,"nonce":"<sha256 hex>"},
//     "tokens":[{"sha256":"<hex>","caller":"panel","claude":false,"single_use":false}]}]}
// `kind` (shell, pi, claude) always; `pi_ro` and `extras` for pi; `claude_root` and `ro` only
// when set. A pi env token that was used is not listed (it was swapped
// for a reconnect token, which is): an unlisted token is unknown, as a used one must be.

TOKENS_KIND :: "tokens"
tokens_write_probe: proc() // tests: called right before tokens.json is written

// Tests (tokens_write_probe): whether the calling thread does not hold srv.mu. srv.mu has no
// owner, so this takes it: another thread (the accept loop, a connection) may hold it for a
// moment, so a failed try is tried again, and only a lock that stays taken for `within` (one the
// caller holds, which nothing can release while it waits here) counts as held.
socket_mu_free :: proc(within := 5 * time.Second) -> bool {
	start := time.tick_now()
	for !sync.mutex_try_lock(&srv.mu) {
		if time.tick_since(start) >= within do return false
		time.sleep(time.Millisecond)
	}
	sync.unlock(&srv.mu)
	return true
}
TOKENS_VERSION :: 1
TOKENS_MAX_TERMS :: 4096
TOKENS_MAX_DEPTH :: 8 // tokens.json nests 5 deep
TOKENS_MAX_PER_TERM :: 64

// What a held terminal's process was started as (tokens.json, MAC'd).
Held_Kind :: enum u8 {
	Unknown, // not a tab's (never bound)
	Shell,
	Pi,
	Claude,
}

HELD_KIND_NAMES := [Held_Kind]string {
	.Unknown = "",
	.Shell   = "shell",
	.Pi      = "pi",
	.Claude  = "claude",
}

Held_Start :: struct {
	kind:   Held_Kind,
	pi_ro:  bool, // pi: started read-only (a read-only chat)
	extras: u64, // pi: the optional extensions it loaded (Tab.reload.extras)
}

Ro_Saved :: struct {
	need, acked: bool,
	nonce:       [32]u8, // sha256 of the start's nonce
}

@(private = "file")
Hashed_Token :: struct {
	using entry: Token_Entry, // caller.tab_id 0 until its term is adopted (no hello until then)
	term:        u32,
}

// srv.mu held.
@(private = "file")
tokens_reset :: proc() {
	srv.tok_on = false
	delete(srv.tok_body)
	srv.tok_body = ""
	srv.tok_written = srv.tok_gen
	delete(srv.tok_path)
	srv.tok_path = ""
	srv.tok_key = {}
	clear(&srv.tab_term)
	clear(&srv.tab_ro)
	clear(&srv.tab_start)
	clear(&srv.hashed)
	clear(&srv.held_root)
	clear(&srv.held_ro)
	clear(&srv.held_start)
}

socket_tokens_enable :: proc(path: string, key: []u8) -> (loaded: bool, why: string) {
	if len(key) != MACFILE_KEY_LEN do return false, "no key"
	defer tokens_flush() // after the unlock
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	clear(&srv.hashed)
	clear(&srv.held_root)
	clear(&srv.held_ro)
	clear(&srv.held_start)
	delete(srv.tok_path)
	srv.tok_path = strings.clone(path)
	copy(srv.tok_key[:], key)
	loaded, why = tokens_load(path, key)
	if !loaded {
		// fail closed: whatever was there is unknown now (never logged: only why)
		clear(&srv.hashed)
		clear(&srv.held_root)
		clear(&srv.held_ro)
		clear(&srv.held_start)
		if why != "missing" do fmt.eprintln("Deckhand: tokens.json not trusted, old tokens are unknown:", why)
	}
	srv.tok_on = true
	tokens_save()
	return
}

socket_tokens_disable :: proc(remove: bool) {
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	if remove && srv.tok_path != "" do os.remove(srv.tok_path)
	tokens_reset() // this run's tokens and claude_pids stay
}

socket_tokens_bind :: proc(tab_id: u64, term: u32, start: Held_Start) {
	if tab_id == 0 || term == 0 do return
	defer tokens_flush() // after the unlock
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	srv.tab_term[tab_id] = term
	srv.tab_start[tab_id] = start
	tokens_save()
}

// What holder terminal `term` was started as (loaded and verified, or this run's).
socket_tokens_start_of :: proc(term: u32) -> (start: Held_Start, found: bool) {
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	if st, ok := srv.held_start[term]; ok do return st, true
	for tab, t in srv.tab_term do if t == term {
		st, ok := srv.tab_start[tab]
		return st, ok
	}
	return {}, false
}

// Drops what was loaded for terminals not in `keep` (the holder's WELCOME), not adopted yet.
socket_tokens_prune :: proc(keep: []u32) {
	defer tokens_flush() // after the unlock
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	kept :: proc(keep: []u32, term: u32) -> bool {
		for k in keep do if k == term do return true
		return false
	}
	gone := make([dynamic][32]u8, context.temp_allocator)
	for k, h in srv.hashed do if h.caller.tab_id == 0 && !kept(keep, h.term) do append(&gone, k)
	for k in gone do delete_key(&srv.hashed, k)
	terms := make([dynamic]u32, context.temp_allocator)
	for term in srv.held_root do if !kept(keep, term) do append(&terms, term)
	for term in srv.held_ro do if !kept(keep, term) do append(&terms, term)
	for term in srv.held_start do if !kept(keep, term) do append(&terms, term)
	for term in terms {
		delete_key(&srv.held_root, term)
		delete_key(&srv.held_ro, term)
		delete_key(&srv.held_start, term)
	}
	tokens_save()
}

socket_tokens_adopt :: proc(term: u32, tab_id: u64, start: Held_Start = {}) -> (trusted: bool) {
	if tab_id == 0 || term == 0 do return false
	defer tokens_flush() // after the unlock
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	for _, &h in srv.hashed do if h.term == term && h.caller.tab_id == 0 {
		h.caller.tab_id = tab_id
		trusted = true
	}
	if root, ok := srv.held_root[term]; ok {
		srv.claude_pids[tab_id] = root
		delete_key(&srv.held_root, term)
		trusted = true
	}
	if ro, ok := srv.held_ro[term]; ok {
		srv.tab_ro[tab_id] = ro
		delete_key(&srv.held_ro, term)
		trusted = true
	}
	if st, ok := srv.held_start[term]; ok {
		srv.tab_start[tab_id] = st
		delete_key(&srv.held_start, term)
	}
	if start.kind != .Unknown do srv.tab_start[tab_id] = start // what the adopted tab is now (never looser: holder_adopt_all)
	srv.tab_term[tab_id] = term
	tokens_save()
	return
}

socket_tokens_release :: proc(term: u32) {
	defer tokens_flush() // after the unlock
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	gone := make([dynamic][32]u8, context.temp_allocator)
	for k, h in srv.hashed do if h.term == term && h.caller.tab_id == 0 do append(&gone, k)
	for k in gone do delete_key(&srv.hashed, k)
	delete_key(&srv.held_root, term)
	delete_key(&srv.held_ro, term)
	delete_key(&srv.held_start, term)
	tokens_save()
}

// A read-only Claude tab's ack state changed (claude.odin): saved with its term.
socket_tokens_ro :: proc(tab_id: u64, need, acked: bool, nonce: string) {
	defer tokens_flush() // after the unlock
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	srv.tab_ro[tab_id] = {need = need, acked = acked, nonce = token_hash(nonce)}
	tokens_save()
}

// The read-only ack state saved for holder terminal `term` (loaded and verified, or this run's).
socket_tokens_ro_of :: proc(term: u32) -> (ro: Ro_Saved, found: bool) {
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	if r, ok := srv.held_ro[term]; ok do return r, true
	for tab, t in srv.tab_term do if t == term {
		r, ok := srv.tab_ro[tab]
		return r, ok
	}
	return {}, false
}

// A token from this run, or one loaded from tokens.json whose terminal was adopted (then it is
// this run's from now on: kept by the token itself). srv.mu held.
@(private = "file")
token_find :: proc(tok: string) -> (Token_Entry, bool) {
	if e, ok := srv.tokens[tok]; ok do return e, token_caller_ok(e.caller)
	if len(srv.hashed) == 0 do return {}, false
	h := token_hash(tok)
	he, ok := srv.hashed[h]
	if !ok || he.caller.tab_id == 0 do return {}, false
	delete_key(&srv.hashed, h)
	srv.tokens[strings.clone(tok)] = he.entry
	return he.entry, true
}

// srv.mu held.
@(private = "file")
tokens_forget_tab :: proc(tab_id: u64) {
	gone := make([dynamic][32]u8, context.temp_allocator)
	for k, h in srv.hashed do if h.caller.tab_id == tab_id do append(&gone, k)
	for k in gone do delete_key(&srv.hashed, k)
	delete_key(&srv.tab_ro, tab_id)
	delete_key(&srv.tab_start, tab_id)
	delete_key(&srv.tab_term, tab_id)
	tokens_save()
}

@(private = "file")
TOKEN_CALLERS := [Caller_Kind]string {
	.None     = "",
	.Internal = "",
	.UI       = "",
	.Script   = "",
	.Control  = "control",
	.Panel    = "panel",
	.App      = "app",
	.Tab_Host = "", // never a token: only the window's link reports for its tabs
}

// Builds tokens.json's body when enabled (srv.mu held); the caller writes it with tokens_flush
// once srv.mu is released.
@(private = "file")
tokens_save :: proc() {
	if !srv.tok_on do return
	Out :: struct {
		root:   i32,
		ro:     Ro_Saved,
		has_ro: bool,
		start:  Held_Start,
		toks:   [dynamic]string,
	}
	terms := make(map[u32]Out, context.temp_allocator)
	tok_json :: proc(hash: [32]u8, e: Token_Entry) -> string {
		h := hash
		hello := e.hello == .Challenge ? `,"hello":"challenge"` : "" // absent: plain (every file before M4-B)
		return fmt.tprintf(`{{"sha256":"%s","caller":"%s","claude":%v,"single_use":%v%s}}`, string(hex.encode(h[:], context.temp_allocator)), TOKEN_CALLERS[e.caller.kind], e.caller.claude, e.single_use, hello)
	}
	get :: proc(m: ^map[u32]Out, term: u32) -> ^Out {
		if term not_in m do m[term] = {toks = make([dynamic]string, context.temp_allocator)}
		return &m[term]
	}
	for tab, term in srv.tab_term {
		o := get(&terms, term)
		if root, ok := srv.claude_pids[tab]; ok do o.root = root
		if ro, ok := srv.tab_ro[tab]; ok do o.ro, o.has_ro = ro, true
		if st, ok := srv.tab_start[tab]; ok do o.start = st
	}
	for tok, e in srv.tokens {
		term, bound := srv.tab_term[e.caller.tab_id]
		if !bound || e.caller.tab_id == 0 || TOKEN_CALLERS[e.caller.kind] == "" do continue
		o := get(&terms, term)
		append(&o.toks, tok_json(token_hash(tok), e))
	}
	for h, he in srv.hashed {
		term := he.term
		if he.caller.tab_id != 0 {
			t, bound := srv.tab_term[he.caller.tab_id]
			if !bound do continue
			term = t
		}
		o := get(&terms, term)
		append(&o.toks, tok_json(h, he.entry))
	}
	for term, root in srv.held_root do get(&terms, term).root = root
	for term, ro in srv.held_ro {
		o := get(&terms, term)
		o.ro, o.has_ro = ro, true
	}
	for term, st in srv.held_start do get(&terms, term).start = st
	ids := make([dynamic]u32, 0, len(terms), context.temp_allocator)
	for k in terms do append(&ids, k)
	slice.sort(ids[:])
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"terms":[`, TOKENS_VERSION)
	first := true
	for id in ids {
		o := terms[id]
		if o.start.kind == .Unknown do continue // nothing says what it is: not kept (fails closed)
		if !first do strings.write_byte(&b, ',')
		first = false
		fmt.sbprintf(&b, `{{"term":%d,"kind":"%s"`, id, HELD_KIND_NAMES[o.start.kind])
		if o.start.kind == .Pi do fmt.sbprintf(&b, `,"pi_ro":%v,"extras":%d`, o.start.pi_ro, transmute(i64)o.start.extras)
		if o.root > 1 do fmt.sbprintf(&b, `,"claude_root":%d`, o.root)
		nonce := o.ro.nonce
		if o.has_ro do fmt.sbprintf(&b, `,"ro":{{"need":%v,"acked":%v,"nonce":"%s"}}`, o.ro.need, o.ro.acked, string(hex.encode(nonce[:], context.temp_allocator)))
		slice.sort(o.toks[:]) // stable output: the map's order is not
		strings.write_string(&b, `,"tokens":[`)
		for tj, k in o.toks {
			if k > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, tj)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "]}")
	delete(srv.tok_body)
	srv.tok_body = strings.clone(strings.to_string(b))
	srv.tok_gen += 1
}

// Writes the body tokens_save left, after srv.mu is released (every caller of tokens_save:
// a slow or hung disk then holds up only that caller, never the threads that need srv.mu).
// Writers queue on tok_wmu and the newest body wins: an older one is never written after it.
@(private = "file")
tokens_flush :: proc() {
	sync.lock(&srv.tok_wmu)
	defer sync.unlock(&srv.tok_wmu)
	sync.lock(&srv.mu)
	if srv.tok_written == srv.tok_gen || srv.tok_body == "" || srv.tok_path == "" {
		sync.unlock(&srv.mu)
		return
	}
	gen := srv.tok_gen
	path := strings.clone(srv.tok_path, context.temp_allocator)
	body := strings.clone(srv.tok_body, context.temp_allocator)
	key := srv.tok_key
	sync.unlock(&srv.mu)
	if tokens_write_probe != nil do tokens_write_probe()
	if ok, why := macfile_write(path, TOKENS_KIND, body, key[:]); !ok {
		fmt.eprintln("Deckhand: cannot save tokens.json:", why)
	}
	sync.lock(&srv.mu)
	srv.tok_written = gen
	sync.unlock(&srv.mu)
}

// Reads tokens.json into srv.hashed, held_root and held_ro (srv.mu held). All or nothing: any
// entry out of shape rejects the whole file.
@(private = "file")
tokens_load :: proc(path: string, key: []u8) -> (ok: bool, why: string) {
	body, rok, rwhy := macfile_read(path, TOKENS_KIND, key, context.temp_allocator)
	if !rok do return false, rwhy
	if !json_shape_ok(body, 200_000) do return false, "too large or too deep"
	// jg after the MAC and the item count: tokens_save writes 5 levels (root, terms, a term, its tokens, a token)
	v, jerr := jg.parse_string(body, .JSON, true, context.temp_allocator, max_depth = TOKENS_MAX_DEPTH)
	if jerr != nil do return false, "invalid JSON"
	root, is := v.(json.Object)
	if !is do return false, "not an object"
	if ver, vok := root["v"].(json.Integer); !vok || ver != TOKENS_VERSION do return false, "unknown version"
	list, lok := root["terms"].(json.Array)
	if !lok || len(list) > TOKENS_MAX_TERMS do return false, "bad terms"
	hashes := make(map[[32]u8]Hashed_Token, context.temp_allocator)
	roots := make(map[u32]i32, context.temp_allocator)
	ros := make(map[u32]Ro_Saved, context.temp_allocator)
	starts := make(map[u32]Held_Start, context.temp_allocator)
	seen := make(map[u32]bool, context.temp_allocator)
	hash32 :: proc(v: json.Value) -> (h: [32]u8, ok: bool) {
		s, sok := v.(json.String)
		if !sok || len(s) != 64 do return {}, false
		b, hok := hex.decode(transmute([]u8)s, context.temp_allocator)
		if !hok || len(b) != 32 do return {}, false
		copy(h[:], b)
		return h, true
	}
	for item in list {
		o, ook := item.(json.Object)
		if !ook do return false, "bad term"
		tn, tok := o["term"].(json.Integer)
		if !tok || tn <= 0 || tn > i64(max(u32)) do return false, "bad term id"
		term := u32(tn)
		if seen[term] do return false, "a term twice"
		seen[term] = true
		st: Held_Start
		kn, kok := o["kind"].(json.String)
		if !kok do return false, "bad kind"
		switch kn {
		case "shell":  st.kind = .Shell
		case "pi":     st.kind = .Pi
		case "claude": st.kind = .Claude
		case:          return false, "bad kind"
		}
		if r, has := o["pi_ro"]; has {
			b, bok := r.(json.Boolean)
			if !bok || st.kind != .Pi do return false, "bad pi_ro"
			st.pi_ro = bool(b)
		}
		if r, has := o["extras"]; has {
			n, nok := r.(json.Integer)
			if !nok || st.kind != .Pi do return false, "bad extras"
			st.extras = transmute(u64)i64(n)
		}
		starts[term] = st
		if r, has := o["claude_root"]; has {
			n, nok := r.(json.Integer)
			if !nok || n <= 1 || n > i64(max(i32)) do return false, "bad claude_root"
			roots[term] = i32(n)
		}
		if r, has := o["ro"]; has {
			ro, rook := r.(json.Object)
			if !rook do return false, "bad ro"
			need, nok := ro["need"].(json.Boolean)
			acked, aok := ro["acked"].(json.Boolean)
			nonce, hok := hash32(ro["nonce"])
			if !nok || !aok || !hok do return false, "bad ro"
			ros[term] = {need = bool(need), acked = bool(acked), nonce = nonce}
		}
		toks, took := o["tokens"].(json.Array)
		if !took || len(toks) > TOKENS_MAX_PER_TERM do return false, "bad tokens"
		for tv in toks {
			to, tok2 := tv.(json.Object)
			if !tok2 do return false, "bad token"
			h, hok := hash32(to["sha256"])
			cs, cok := to["caller"].(json.String)
			claude, clok := to["claude"].(json.Boolean)
			single, sok := to["single_use"].(json.Boolean)
			if !hok || !cok || !clok || !sok do return false, "bad token"
			kind: Caller_Kind
			switch cs {
			case "panel":   kind = .Panel
			case "app":     kind = .App
			case "control": kind = .Control
			case:           return false, "bad token caller"
			}
			if claude && kind != .Panel do return false, "bad token caller"
			if h in hashes do return false, "a token twice"
			he := Hashed_Token{entry = {caller = {kind = kind, claude = bool(claude)}, single_use = bool(single)}, term = term}
			if hv, has := to["hello"]; has {
				// only a reconnect token is challenge-only: never single-use, never a Claude tab's
				hs, hok := hv.(json.String)
				if !hok || hs != "challenge" || bool(single) || bool(claude) do return false, "bad token hello"
				he.hello = .Challenge
				he.hid = hello_token_id(h)
			}
			hashes[h] = he
		}
	}
	for h, he in hashes {
		e := he
		srv.next_ref += 1
		e.ref = srv.next_ref
		srv.hashed[h] = e
	}
	for k, r in roots do srv.held_root[k] = r
	for k, r in ros do srv.held_ro[k] = r
	for k, r in starts do srv.held_start[k] = r
	return true, ""
}
