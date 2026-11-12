package main

// The window with a separate core (docs/plans/background-core.md §10.3 M4-C): the default, unless
// Settings › Sessions in a background core is off (or, in test and development builds,
// DECKHAND_SEPARATE_CORE=0, which wins over the setting); the core is
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
// - The core's connection ending (a crash, a SIGTERM, a handover's predecessor going) is not the
//   window's end: it dials again, launching a core if none answers (≤ 15 s), and restores from a
//   fresh state.full; its terminal copies attach again (client_core_reconnect). Only a core that
//   said window.request quit first (a Quit, Stop All, another window took over) ends the window.
// - Skew (§7.5, M4-E): at attach (client_core_connect, never a reconnect), a core that is not this
//   app's (older, below CORE_MIN, an older generation) is handed over to the app's own core at
//   once, before the window subscribes: the bundled Core.app is installed and made current,
//   core_handover{current} goes, and once that connection ends the window dials the new core. A
//   newer generation asks: Use this app's core (the same handover) or quit to update.

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
CORE_RELAUNCH_EVERY :: time.Second // while no core answers (client_core_dial)
RECONNECTS_MAX :: 3 // reconnects in RECONNECTS_PER: past it the window gives up (client_core_tick)
RECONNECTS_PER :: 60 * time.Second

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

// A separate core still runs for data's runtime dir (its window.token is there and core.sock
// answers): the setting was turned off while its sessions run on, and core.lock is its, so this
// launch attaches to it all the same (main.odin) until Quit and Stop All Sessions ends it.
separate_core_running :: proc(data: string) -> bool {
	if core.hook_env(.Separate_Core) == "0" do return false // a test's or a developer's explicit choice
	run := core.hook_env(.Runtime_Dir)
	if run == "" do run = fmt.tprintf("%s/run", strings.trim_right(data, "/"))
	if !os.exists(fmt.tprintf("%s/%s", run, core.WINDOW_TOKEN_FILE)) do return false
	fd, ok := core.sock_connect(fmt.tprintf("%s/%s", run, core.CORE_SOCK))
	if !ok do return false
	core.sock_close(fd)
	return true
}

// Connects to the separate core (launching it if none runs), says the framed hello and subscribes:
// from here `state` is the replica. "" = attached, else why not. Main thread, at init.
client_core_connect :: proc(data: string) -> string {
	heap := runtime.heap_allocator()
	client.log = core.hook_env(.Proto_Log) == "1"
	client.main = sync.current_thread_id()
	client.results = make(map[string]core.Result, heap)
	client.abandoned = make(map[string]bool, heap)
	client.tab_facts_sent = make(map[u64]string, heap)
	hello, why := client_core_dial(data)
	if why != "" do return why
	to: string
	if to, why = client_core_handover_to(hello, data); why != "" do return why
	if to != "" {
		// the old core hands over; its connection ends; the new core is dialled (never launched
		// here: the old core starts it, with the holder's secret)
		if why = client_core_handover(to); why != "" {
			if hello.skew != .Core_Older && hello.skew != .Ok do return why
			// it works as it is: stay with it
		} else if _, why = client_core_dial(data, launch = false); why != "" {
			return why
		}
	}
	deferred_init(&client.deferred)
	client.attached = true
	core.replica_process = true
	core.claude_typed_send = proc(tab_id: u64) {client_internal(core.Claude_Typed{tab_id = tab_id})}
	core.claude_status_dismiss_send = proc(tab_id: u64) {client_internal(core.Claude_Status_Dismiss{tab_id = tab_id})}
	core.files_root_reset_send = proc(base: string) {client_send(core.Files_Set_Root{base = base})}
	core.replica_ui_send = proc(cmd: core.Command, menu: string) {client_send(cmd, menu)}
	core.replica_request = window_request_run // what this process's core package asks of the window (window_requests.odin)
	core.replica_facts_text = proc() -> string {return client.facts_sent} // its own snapshot's facts (window_link.odin)
	core.replica_tab_facts_text = proc(tab_id: u64) -> string {return client.tab_facts_sent[tab_id] or_else ""}
	return client_core_subscribe()
}

// No core came up and the window runs the core in its own process instead (main.odin's fallback):
// whatever client_core_connect set up goes, so the in-process link starts clean.
client_core_abandon :: proc() {
	if client.sock != nil {
		cw.sock_destroy(client.sock)
		free(client.sock, runtime.heap_allocator())
		client.sock = nil
	}
	client.attached, client.lost = false, false
	core.replica_process = false
	core.claude_typed_send, core.claude_status_dismiss_send, core.files_root_reset_send = nil, nil, nil
	core.replica_ui_send, core.replica_request, core.replica_facts_text, core.replica_tab_facts_text = nil, nil, nil, nil
}

// The connection to the core ended (client_core_lost), and the window is not quitting: the old
// link goes, the window dials again (or launches a core), and the replica, its terminal copies
// and the facts it sent start over from a fresh state.full. Blocks the main thread while it dials
// (a core that just died is usually back within a second; 15 s at most). "" = attached again.
// Main thread, outside the frame reader (the frame and the hidden window's timer call it).
client_core_reconnect :: proc() -> string {
	if !client.lost || core.app_quitting do return ""
	heap := runtime.heap_allocator()
	for k, r in client.results {
		core.result_free(r)
		delete(k, heap)
	}
	clear(&client.results)
	for k in client.abandoned do delete(k, heap)
	clear(&client.abandoned)
	for k in client.pending do delete(k, heap)
	clear(&client.pending)
	term_views_drop_all() // their channels were the old connection's (term_view_stream.odin)
	client_facts_forget_all()
	got_full = false
	old := client.sock // the dead link stays client.sock until a new one is up (client_separate holds)
	// never a handover here: the core that answers is the supervisor's or a successor's
	if _, why := client_core_dial(core.home_root); why != "" do return why
	cw.sock_destroy(old)
	free(old, heap)
	client.lost = false
	why := client_core_subscribe()
	if why == "" && core.autotest_active do fmt.printfln("[autotest] core: reattached to pid %d", client.core_pid)
	app.redraw = true
	return why
}

// The link is up: subscribe, wait for state.full (≤ 15 s), send the window's facts.
@(private = "file")
client_core_subscribe :: proc() -> string {
	client_send_raw(core.window_msg_subscribe())
	deadline := time.tick_add(time.tick_now(), CORE_START_WAIT)
	for !got_full && !client.lost && time.tick_diff(time.tick_now(), deadline) > 0 do client_io(50)
	if !got_full do return "Deckhand's background core sent no state"
	client_facts()
	flash_quiet() // the statuses that came with it are not news (ui.odin status_flash)
	return ""
}

// Dials core.sock until a core with a window token answers its hello, for up to CORE_START_WAIT,
// launching one every CORE_RELAUNCH_EVERY while none does (unless !launch: a handover's successor
// is the old core's to start): a core that is still stopping (its handover and save, under
// core.lock) makes the first launch exit at once. why == "": client.sock is the link.
@(private = "file")
client_core_dial :: proc(data: string, launch := true) -> (hello: Core_Hello, why: string) {
	run, rwhy := core.sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" do return {}, rwhy
	path := fmt.tprintf("%s/%s", run, core.CORE_SOCK)
	deadline := time.tick_add(time.tick_now(), CORE_START_WAIT)
	last_launch: time.Tick
	core.core_refused_take(run) // an earlier core's: not this start's
	refused: string // why the last core launched refused to start (instance_guard), for the timeout's message
	for {
		if fd, ok := core.sock_connect(path); ok {
			if core.window_token_read(run) != "" {
				hello, why = client_core_hello(fd, run)
				if why == "" do return
				core.sock_close(fd)
				return
			}
			core.sock_close(fd) // not a core's (yet): no window token
		}
		// a core refused to start (instance_guard) says why. Not final: one launched a second ago
		// may still be starting and hold the lock; told only if no core comes up
		if r := core.core_refused_take(run); r != "" do refused = r
		if launch && (last_launch == {} || time.tick_since(last_launch) >= CORE_RELAUNCH_EVERY) {
			last_launch = time.tick_now()
			if why = client_core_launch(run, data); why != "" do return
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			why = launch ? "Deckhand's background core did not start within 15 s" : "Deckhand's new background core did not start within 15 s"
			if refused != "" do why = fmt.tprintf("%s. It said: %s", why, strings.trim_right(refused, "."))
			return {}, why
		}
		time.sleep(20 * time.Millisecond)
	}
}

// The state.full came (client_on_frames).
client_got_state :: proc() {got_full = true}

// Launches a core for this data dir (the bundled deckhand-core, installed as the holder is).
@(private = "file")
client_core_launch :: proc(run, data: string, from_tab := false) -> string {
	bin := core.core_serve_bin_find(context.temp_allocator)
	if bin == "" do return "Deckhand Core.app (its deckhand-core-serve) is missing from this copy of Deckhand"
	exe, ok, why := core.core_install(bin, data)
	if !ok do return why
	if prev := core.core_use_previous_serve(data); prev != "" do exe = prev // the user's Use previous core
	if core.autotest_active do fmt.println("[autotest] core: launching", exe)
	// after an update the relaunch helper gives the holder's successor secret to the new window's
	// executable only (holder_successor.odin): its core says the holder's HELLO with it
	secret := core.successor_secret_take(run)
	defer core.trust_wipe(transmute([]u8)secret)
	if core.autotest_active && secret != "" do fmt.println("[autotest] core: launching with the successor secret")
	_, lok, lwhy := core.core_launch(exe, run, data, from_tab, secret = secret)
	if !lok do return lwhy
	return ""
}

// What the core's hello reply said (client_core_handover_to decides on it).
Core_Hello :: struct {
	skew:  cw.Skew,
	build: string, // the core's two binaries' hash (core.core_build_of)
}

// The window's half of the framed hello on fd (connected to core.sock). "" = the link is up.
@(private = "file")
client_core_hello :: proc(fd: core.Sock_Fd, run: string) -> (hello: Core_Hello, why: string) {
	peer: trust.Peer
	peer, why = core.core_peer_check(fd) // before a byte is sent (B4)
	if why != "" do return
	token := core.window_token_read(run)
	line := fmt.tprintf("{{\"id\":\"w\",\"v\":%d,\"type\":\"hello\",\"framed\":true,\"token\":\"%s\"}}\n", core.PROTOCOL_VERSION, token)
	if !core.sock_write_all(fd, transmute([]u8)line) do return {}, "the background core closed the connection"
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	nl := -1
	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for nl < 0 {
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		if left <= 0 || !core.sock_wait_readable(fd, left) do return {}, "the background core did not answer the hello"
		n := core.sock_read(fd, chunk[:])
		if n <= 0 do return {}, "the background core closed the connection"
		if trust.peer_still(peer, trust.peer_read(fd)) != .Allow do return {}, "the process on core.sock changed"
		append(&buf, ..chunk[:n])
		nl = strings.index_byte(string(buf[:]), '\n')
		if len(buf) > 1 << 20 do return {}, "the background core's hello reply is too long"
	}
	reply := string(buf[:nl])
	if core.json_path(reply, "result.ok") != "true" do return {}, fmt.tprintf("the background core refused this window: %s", core.json_path(reply, "result.error"))
	if core.json_path(reply, "result.data.framed") != "true" do return {}, "the background core did not take a framed connection"
	gen, _ := strconv.parse_i64(core.json_path(reply, "result.data.generation"))
	hello.skew = cw.skew_check(cw.GENERATION, gen, core.core_version(), core.json_path(reply, "result.data.version"))
	hello.build = strings.clone(core.json_path(reply, "result.data.build"), context.temp_allocator)
	client_peer = peer
	client.core_pid = peer.pid
	client.sock = new(cw.Sock_Transport, runtime.heap_allocator())
	cw.sock_open(client.sock, fd, peer_check = proc(fd: core.Sock_Fd, data: rawptr) -> bool {
		return trust.peer_still((^trust.Peer)(data)^, trust.peer_read(fd)) == .Allow
	}, peer_data = &client_peer, initial = buf[nl + 1:], allocator = runtime.heap_allocator())
	return hello, ""
}

// Whether the core the window found is handed over to this app's own, and to what ("" = keep
// it), or why the window can't start. Installs this app's Core.app first (current: core_install).
client_core_handover_to :: proc(hello: Core_Hello, data: string) -> (to, why: string) {
	when core.TEST_HOOKS {
		if core.autotest_active && core.hook_env(.Core_Handover) == "self" do return "self", "" // installs nothing in test mode
	}
	bundled := core.core_serve_bin_find(context.temp_allocator)
	switch hello.skew {
	case .Ok:
		return "", "" // a development build (no version) never hands over to another of its kind
	case .Core_Older, .Core_Below_Min, .Core_Older_Generation:
		// the user's Use previous core holds (core_use_previous_serve): keep the core it chose
		if core.core_use_previous_serve(data) != "" {
			fmt.eprintln("Deckhand: background core: keeping the previous core (Use previous core)")
			return "", hello.skew == .Core_Older ? "" : core.core_skew_message(hello.skew)
		}
	case .Core_Newer_Generation:
		msg := core.core_skew_message(hello.skew)
		if core.autotest_active || !platform_ask("Update Deckhand", fmt.tprintf("%s. Update Deckhand, or hand your sessions to this older app's core (they keep running).", msg), "Use This App's Core", "Quit") do return "", msg
	}
	if bundled == "" do return "", core.core_skew_message(hello.skew)
	if _, ok, iwhy := core.core_install(bundled, data); !ok {
		fmt.eprintln("Deckhand: background core: cannot install this app's core:", iwhy)
		return "", hello.skew == .Ok || hello.skew == .Core_Older ? "" : core.core_skew_message(hello.skew)
	}
	return "current", ""
}

CORE_HANDOVER_WAIT :: 3 * time.Minute // its job runs get 2 min, then the handover itself

// core_handover{to} on the link that is up (not subscribed yet), then the wait for the old core
// to go: its connection ends. "" = handed over (the link is gone), else why not (the link stays).
client_core_handover :: proc(to: string) -> string {
	fmt.eprintln("Deckhand: handing the background core over to this app's (", to, ")")
	if core.autotest_active do fmt.println("[autotest] core: handing over to", to)
	client.handing_over = true
	defer client.handing_over = false
	r, _ := client_call_wait(core.Core_Handover{to = to}, 15 * time.Second)
	if !r.ok && !client.lost { // gone already: it went ahead
		fmt.eprintln("Deckhand: background core: the handover was refused:", r.error)
		return fmt.tprintf("Deckhand's background core could not be updated: %s", r.error)
	}
	start := time.tick_now()
	for !client.lost && time.tick_since(start) < CORE_HANDOVER_WAIT do client_io(100)
	if !client.lost do return "Deckhand's background core did not finish its handover"
	cw.sock_destroy(client.sock)
	free(client.sock, runtime.heap_allocator())
	client.sock, client.lost = nil, false
	return ""
}

// The core's connection ended. A core that said quit first (client_core_quit) takes the window with
// it; otherwise (a crash, a SIGTERM, a handover) the window reconnects at its next frame or timer
// turn (client_core_reconnect).
client_core_lost :: proc() {
	if client.lost do return
	client.lost = true
	if client.handing_over do return // client_core_handover dials the new core
	fmt.eprintln("Deckhand: the background core's connection ended:", cw.sock_reason(client.sock))
	if core.autotest_active do fmt.println("[autotest] core: connection ended")
	if core.app_quitting do app_request_quit()
}

// window.request quit: the core ends on purpose, or let this window go for another; the window
// quits too and never reconnects.
client_core_quit :: proc(why: string) {
	fmt.eprintln("Deckhand: the background core asked the window to quit:", why)
	if core.autotest_active do fmt.println("[autotest] core: quit:", why)
	core.app_quitting = true
	app_request_quit()
}

// window.request viewed_from: another machine's Deckhand (its hub link) took this core, the newest
// connection winning (docs/plans/background-core.md §10.4). The connection ends next; the window
// does not dial again until its user takes it back (client_core_tick asks).
client_core_viewed :: proc(machine: string) {
	fmt.eprintln("Deckhand: the background core is viewed from", machine)
	if core.autotest_active do fmt.println("[autotest] core: viewed from", machine)
	delete(client.viewed_from, runtime.heap_allocator())
	client.viewed_from = strings.clone(machine != "" ? machine : "another machine", runtime.heap_allocator())
}

// The frame's and the hidden window's turn: a lost connection is dialled again. One that cannot be
// (no core within 15 s, or more than RECONNECTS_MAX in RECONNECTS_PER) gives up, once. One that
// another machine took (viewed_from) asks first: Take Back dials again (and the other machine's
// link is let go), Quit closes the window.
client_core_tick :: proc() {
	if !client.lost || core.app_quitting || client.gave_up do return
	if client.viewed_from != "" {
		if core.autotest_active do return // test mode never shows the modal: the scene's log says it
		take := platform_ask(fmt.tprintf("Viewed from %s", client.viewed_from), fmt.tprintf("Deckhand on %s is showing this Mac's sessions now. They keep running. Take them back to show them here (%s's view lets go).", client.viewed_from, client.viewed_from), "Take Back", "Quit")
		delete(client.viewed_from, runtime.heap_allocator())
		client.viewed_from = ""
		if !take {
			client.gave_up = true
			app_request_quit()
			return
		}
		client.reconnects_since, client.reconnects = {}, 0
	}
	if !reconnect_allowed(&client.reconnects_since, &client.reconnects, time.tick_now()) {
		client_core_give_up(fmt.tprintf("its background core stopped more than %d times in a minute", RECONNECTS_MAX))
		return
	}
	if why := client_core_reconnect(); why != "" do client_core_give_up(why)
}

// At most RECONNECTS_MAX reconnects in any RECONNECTS_PER window that starts at the first one.
reconnect_allowed :: proc(since: ^time.Tick, count: ^int, now: time.Tick) -> bool {
	if since^ == {} || time.tick_diff(since^, now) >= RECONNECTS_PER {
		since^, count^ = now, 0
	}
	count^ += 1
	return count^ <= RECONNECTS_MAX
}

// No core to reconnect to: said once (gave_up first, so the timer's turns inside the alert's modal
// loop do nothing), then the window closes as ⌘Q closes it. Never with app_quitting: a buffer with
// unsaved changes keeps the window open (QUIT_REQUESTED), and ⌘S still saves it (ui_do).
@(private = "file")
client_core_give_up :: proc(why: string) {
	client.gave_up = true
	fmt.eprintln("Deckhand: cannot reconnect to the background core:", why)
	if core.autotest_active do fmt.println("[autotest] core: gave up:", why)
	else do platform_alert("Deckhand lost its background core", fmt.tprintf("Deckhand can't reach its background core: %s. Files with unsaved changes stay open so you can save them; then quit and open Deckhand again.", why), "OK")
	app_request_quit()
}

// The window's layout facts the core wrote into its State itself in process (separate only):
// the panes' area and the shown session's pane rects.
client_layout_facts :: proc(f: ^core.Window_Facts) {
	if client.sock == nil do return
	f.centre = {app.centre.z, app.centre.w, app.dpi}
	@(static) exe: string
	if exe == "" do exe = strings.clone(core.executable_path(), runtime.heap_allocator())
	f.exe = exe // the bundle the core's updates replace (update.odin's update_window_exe)
	cs := core.cur()
	if cs == nil do return
	panes := make([]core.Pane_Fact, len(cs.panes), context.temp_allocator)
	for p, i in cs.panes do panes[i] = {session = cs.id, pane = p.id, rect = p.rect, frame = p.frame}
	f.panes = panes
}

// Test mode's script commands over core.sock: a ui command, its result waited for up to wait.
SCRIPT_CORE_WAIT :: 10 * time.Second

// Test mode over core.sock: until the core ran everything the window sent so far and its delta
// came back: a no-op command queued behind them, whose result comes after that delta (Q9).
// Bounded (SCRIPT_CORE_WAIT).
client_barrier :: proc() {
	client_facts()
	id := client_next_id()
	text, _ := core.window_msg_internal(core.Focus_Release{}, id) // widget "": changes nothing
	client_send_raw(text)
	start := time.tick_now()
	for !(id in client.results) && !client.lost && time.tick_since(start) < SCRIPT_CORE_WAIT do client_io(20)
	if id in client.results do client_take_result(id)
	else do client.abandoned[strings.clone(id, runtime.heap_allocator())] = true
}

client_call_wait :: proc(cmd: core.Command, wait: time.Duration, as: core.Caller = {}) -> (r: core.Result, request_id: u64) {
	client_facts()
	id := client_next_id()
	client_send_raw(core.window_msg_command(cmd, id, now = true, as = as))
	start := time.tick_now()
	for !(id in client.results) && !client.lost && time.tick_since(start) < wait do client_io(20)
	if !(id in client.results) do return core.fail("the background core did not answer in time"), 0
	request_id = client.pending[id] or_else 0 // pending: the core sends its finished (window_link_finished)
	return client_take_result(id), request_id
}

// A separate core's runtime the window follows each frame (the replica's live section): its install
// run, into this process's core.harness_run (what the setup sheet reads), and pi's config folders
// for the file watcher (watch_sync reads core.reload_watch_dirs). The run's strings are the
// replica's; nothing here frees them (the core runs it: Harness_Install). When a run ends the
// checklist looks again, as the core's own does.
client_live_mirror :: proc() {
	l := state.live.harness
	h := &core.harness_run
	if h.term_id != l.term_id do h.started = time.tick_now() // the Enter grace from when this window saw it start
	was := h.status
	h.term_id, h.item, h.action, h.command, h.status, h.exit = l.term_id, l.item, l.action, l.command, l.status, l.exit
	if was == .Running && h.status != .Running do core.harness_checklist_refresh(full = true)
	watch_sync() // and pi's config folders the core wants watched (live.watch; a no-op when unchanged)
}

// `deckhand --ctl` with a separate core (main.odin, before core.ctl_main): when DECKHAND_SOCKET is
// this data dir's core.sock and nothing answers there, a core is launched as the window launches
// one, and waited for (≤ 15 s). So a call from a kept session finds a core after its core went
// (a crash, an idle exit); the tokens it holds come back with the held tabs (tokens.json). Any
// other socket, and the in-process mode, are left alone: there the window is the core.
ctl_core_ensure :: proc() {
	path := os.get_env("DECKHAND_SOCKET", context.temp_allocator) // as ctl_main reads it
	if path == "" do return
	data := core.data_dir(context.temp_allocator)
	if data == "" || !separate_core_wanted(data) do return
	core.home_root = data
	run, rwhy := core.sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" || path != fmt.tprintf("%s/%s", run, core.CORE_SOCK) do return
	if fd, ok := core.sock_connect(path); ok {
		core.sock_close(fd)
		return
	}
	if why := client_core_launch(run, data, from_tab = true); why != "" {
		fmt.eprintln("deckhand --ctl: cannot start Deckhand's background core:", why)
		return
	}
	deadline := time.tick_add(time.tick_now(), CORE_START_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if fd, ok := core.sock_connect(path); ok && core.window_token_read(run) != "" {
			core.sock_close(fd)
			return
		} else if ok do core.sock_close(fd)
		time.sleep(50 * time.Millisecond)
	}
	fmt.eprintln("deckhand --ctl: Deckhand's background core did not start within 15 s")
}

// No core came up (a crash loop, P6): the session holder's supervisor is asked directly. When a
// previous core is installed the user may pick Use Previous Core (the holder launches it). True:
// asked for it; dial again.
client_core_offer_previous :: proc() -> bool {
	run, rwhy := core.sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" do return false
	st, ok := core.holder_supervise_ask(run, "status")
	if !ok || !st.previous || st.core do return false
	text := fmt.tprintf("Deckhand's background core keeps stopping%s. Your sessions are still running. Use the background core from before the last update?", st.crashes > 0 ? fmt.tprintf(" (%d time%s in a row)", st.crashes, st.crashes == 1 ? "" : "s") : "")
	if core.autotest_active {
		fmt.println("[autotest] core: offer previous:", text)
		return false
	}
	if !platform_ask("Deckhand's background core isn't starting", text, "Use Previous Core", "Quit") do return false
	// sticky until another build is installed: the holder and this window launch previous
	if why := core.core_use_previous_set(core.home_root); why != "" {
		fmt.eprintln("Deckhand: background core: Use previous core:", why)
		return false
	}
	_, ok = core.holder_supervise_ask(run, "use_previous")
	return ok
}
