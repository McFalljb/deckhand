package main

// The window with a separate core (docs/plans/background-core.md §10.3 M4-C; Settings ›
// Experimental › Run sessions in a background core, or DECKHAND_SEPARATE_CORE=1): the core is
// `deckhand-core serve`, another process, and the window's link is core.sock.
//
// - Dial: core.sock in the runtime dir; none answers with a window token: the window launches one
//   (launchd, or directly in test mode: core.core_launch) and tries again for up to 15 s.
// - Before a byte goes, the window checks the peer: this user, and the core's designated
//   requirement (core.core_peer_check). Then the framed hello with run/window.token; the reply's
//   generation and version go through the skew table (§7.5). Every read after re-checks the peer.
// - `state` is core.state itself: the replica the core streams is decoded straight into it, so the
//   core's helpers the window calls (core.cur() and the rest) read it unchanged. Those few that
//   read the core's runtime read each tab's Tab_Live instead (core.replica_process). This process
//   never runs the core's loop, holder, socket server or jobs (main.odin's separate branch).
// - A command's reply is waited for at most CLIENT_WAIT (design Q9: 250 ms); past it the call shows
//   as pending, and the late result is dropped.
// - The core's connection ending ends the window (Quit Deckhand and Stop All Sessions, or a
//   crash); M4-D/E bring a reconnect.

import "core:fmt"
import "core:os"
import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "core"
import cw "corewire"
import "trust"

CLIENT_WAIT :: 250 * time.Millisecond
CORE_START_WAIT :: 15 * time.Second

// The longest a command waited for its result over core.sock this run (the 250 ms bound: Q9), and
// how many gave up waiting (test mode logs them).
client_wait_max: time.Duration
client_wait_gave_up: int

@(private = "file")
client_peer: trust.Peer
@(private = "file")
got_full: bool

// The link is core.sock: the core is another process.
client_separate :: proc() -> bool {return client.sock != nil}

// What core.window_link_pump did for the window: in process the core reads what was sent now
// (true: it stopped at its cap); over core.sock, what is queued goes and what came is read.
client_pump :: proc() -> bool {
	if client.sock != nil {
		client_io(0)
		return false
	}
	return core.window_link_pump()
}

// The core's inbox runs (in process), or what the core sent is read (separate). Separate, the
// window's own inbox runs too: its workers' results for its caches (the Files tree's listing and
// git codes, the worktree switcher, the Changes tab: File_List_Done, Git_Status_Done,
// Worktrees_Done, Changes_*_Done; window_local_command).
client_drain :: proc() {
	if client.sock != nil {
		client_io(0)
		core.inbox_drain()
		return
	}
	core.inbox_drain()
}

// Over core.sock: writes what is queued, waits up to ms for the core, reads what came.
client_io :: proc(ms: int) {
	if client.sock == nil || client.lost do return
	cw.sock_flush(client.sock)
	if ms > 0 do cw.sock_wait(client.sock, ms)
	client_frames_read()
	if client.sock != nil do cw.sock_flush(client.sock)
}

// A command's result over core.sock, waited for at most CLIENT_WAIT; then it shows as pending.
client_wait :: proc(id: string) -> core.Result {
	start := time.tick_now()
	for !(id in client.results) && !client.lost {
		left := CLIENT_WAIT - time.tick_since(start)
		if left <= 0 do break
		client_io(max(1, int(time.duration_milliseconds(left))))
	}
	waited := time.tick_since(start)
	client_wait_max = max(client_wait_max, waited)
	if id in client.results do return client_take_result(id)
	client_wait_gave_up += 1
	client.abandoned[strings.clone(id, runtime.heap_allocator())] = true
	return {ok = true, pending = true}
}

// Whether this launch runs its core as another process: DECKHAND_SEPARATE_CORE (dev and test
// builds), else the saved setting (workspace.json's settings.separate_core, read before anything
// else is), else the default (core.separate_core_default_on).
separate_core_wanted :: proc(data: string) -> bool {
	switch core.hook_env(.Separate_Core) {
	case "1": return true
	case "0": return false
	}
	if data != "" {
		if b, err := os.read_entire_file(fmt.tprintf("%s/%s", data, core.WORKSPACE_FILE), context.temp_allocator); err == nil {
			switch core.json_path(string(b), "settings.separate_core") {
			case "true": return true
			case "false": return false
			}
		}
	}
	return core.separate_core_default_on
}

// Connects to the separate core (launching it if none runs), says the framed hello and subscribes:
// from here `state` is the replica. "" = attached, else why not. Main thread, at init.
client_core_connect :: proc(data: string) -> string {
	run, rwhy := core.sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" do return rwhy
	path := fmt.tprintf("%s/%s", run, core.CORE_SOCK)
	deadline := time.tick_add(time.tick_now(), CORE_START_WAIT)
	launched := false
	for {
		if fd, ok := core.sock_connect(path); ok {
			if core.window_token_read(run) != "" {
				why := client_core_hello(fd, run)
				if why == "" do break
				core.sock_close(fd)
				return why
			}
			core.sock_close(fd) // not a core's (yet): no window token
		}
		if !launched {
			launched = true
			if why := client_core_launch(run, data); why != "" do return why
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 do return "Deckhand's background core did not start within 15 s"
		time.sleep(20 * time.Millisecond)
	}
	heap := runtime.heap_allocator()
	client.log = core.hook_env(.Proto_Log) == "1"
	client.main = sync.current_thread_id()
	client.results = make(map[string]core.Result, heap)
	client.abandoned = make(map[string]bool, heap)
	client.tab_facts_sent = make(map[u64]string, heap)
	deferred_init(&client.deferred)
	client.attached = true
	core.replica_process = true
	core.claude_typed_send = proc(tab_id: u64) {client_internal(core.Claude_Typed{tab_id = tab_id})}
	core.claude_status_dismiss_send = proc(tab_id: u64) {client_internal(core.Claude_Status_Dismiss{tab_id = tab_id})}
	core.files_root_reset_send = proc(base: string) {client_send(core.Files_Set_Root{base = base})}
	client_send_raw(core.window_msg_subscribe())
	for !got_full && !client.lost && time.tick_diff(time.tick_now(), deadline) > 0 do client_io(50)
	if !got_full do return "Deckhand's background core sent no state"
	client_facts()
	return ""
}

// The state.full came (client_on_frames).
client_got_state :: proc() {got_full = true}

// Launches a core for this data dir (the bundled deckhand-core, installed as the holder is).
@(private = "file")
client_core_launch :: proc(run, data: string) -> string {
	bin := core.core_serve_bin_find(context.temp_allocator)
	if bin == "" do return "Deckhand Core.app (its deckhand-core-serve) is missing from this copy of Deckhand"
	exe, ok, why := core.core_install(bin, data)
	if !ok do return why
	if core.autotest_active do fmt.println("[autotest] core: launching", exe)
	_, lok, lwhy := core.core_launch(exe, run, data)
	if !lok do return lwhy
	return ""
}

// The window's half of the framed hello on fd (connected to core.sock). "" = the link is up.
@(private = "file")
client_core_hello :: proc(fd: core.Sock_Fd, run: string) -> string {
	peer, why := core.core_peer_check(fd) // before a byte is sent (B4)
	if why != "" do return why
	token := core.window_token_read(run)
	line := fmt.tprintf("{{\"id\":\"w\",\"v\":%d,\"type\":\"hello\",\"framed\":true,\"token\":\"%s\"}}\n", core.PROTOCOL_VERSION, token)
	if !core.sock_write_all(fd, transmute([]u8)line) do return "the background core closed the connection"
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	nl := -1
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for nl < 0 {
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		if left <= 0 || !core.sock_wait_readable(fd, left) do return "the background core did not answer the hello"
		n := core.sock_read(fd, chunk[:])
		if n <= 0 do return "the background core closed the connection"
		if trust.peer_still(peer, trust.peer_read(fd)) != .Allow do return "the process on core.sock changed"
		append(&buf, ..chunk[:n])
		nl = strings.index_byte(string(buf[:]), '\n')
		if len(buf) > 1 << 20 do return "the background core's hello reply is too long"
	}
	reply := string(buf[:nl])
	if core.json_path(reply, "result.ok") != "true" do return fmt.tprintf("the background core refused this window: %s", core.json_path(reply, "result.error"))
	if core.json_path(reply, "result.data.framed") != "true" do return "the background core did not take a framed connection"
	gen, _ := strconv.parse_i64(core.json_path(reply, "result.data.generation"))
	if msg := core.core_skew_message(cw.skew_check(cw.GENERATION, gen, core.core_version(), core.json_path(reply, "result.data.version"))); msg != "" do return msg
	client_peer = peer
	client.core_pid = peer.pid
	client.sock = new(cw.Sock_Transport, runtime.heap_allocator())
	cw.sock_open(client.sock, fd, peer_check = proc(fd: core.Sock_Fd, data: rawptr) -> bool {
		return trust.peer_still((^trust.Peer)(data)^, trust.peer_read(fd)) == .Allow
	}, peer_data = &client_peer, initial = buf[nl + 1:], allocator = runtime.heap_allocator())
	return ""
}

// The core's connection ended: the window ends too (the core quit, or crashed).
client_core_lost :: proc() {
	if client.lost do return
	client.lost = true
	fmt.eprintln("Deckhand: the background core's connection ended:", cw.sock_reason(client.sock))
	if core.autotest_active do fmt.println("[autotest] core: connection ended")
	core.app_quitting = true
	app_request_quit()
}

// The window's layout facts the core wrote into its State itself in process (separate only):
// the panes' area and the shown session's pane rects.
client_layout_facts :: proc(f: ^core.Window_Facts) {
	if client.sock == nil do return
	f.centre = {app.centre.z, app.centre.w, app.dpi}
	cs := core.cur()
	if cs == nil do return
	panes := make([]core.Pane_Fact, len(cs.panes), context.temp_allocator)
	for p, i in cs.panes do panes[i] = {session = cs.id, pane = p.id, rect = p.rect, frame = p.frame}
	f.panes = panes
}

// Test mode's script commands over core.sock: a ui command, its result waited for up to wait.
SCRIPT_CORE_WAIT :: 10 * time.Second

client_call_wait :: proc(cmd: core.Command, wait: time.Duration) -> core.Result {
	client_facts()
	id := client_next_id()
	client_send_raw(core.window_msg_command(cmd, id, now = true))
	start := time.tick_now()
	for !(id in client.results) && !client.lost && time.tick_since(start) < wait do client_io(20)
	if id in client.results do return client_take_result(id)
	return core.fail("the background core did not answer in time")
}
