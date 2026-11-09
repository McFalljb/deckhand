package main

// The window as a client of its core (docs/plans/background-core.md §10.2, M3-F). At init the
// window attaches through the in-memory transport (core.core_attach_window: the ui caller's one
// door), subscribes, and from then on `state` (state_view.odin) is its replica: state.full, then
// the deltas the core sends, applied as they arrive. The window's commands go over the same link:
// encoded (command_wire_json), parsed by the core (parse_command_ui) and run as `ui`. In process
// the core reads them at once and its frames come straight back (on_frames), so the wait for a
// result is nil; M4 carries the same messages over core.sock.
//
// - client_send: a ui command, no result (ui_do): queued in the core's inbox, run at its next drain.
// - client_run:  a ui command and its result after everything queued before it (ui_run).
// - client_call: a command and its result now (what a direct core.run_command did); a ui command,
//   or with .Internal one of core.WINDOW_COMMANDS (window.command).
// - client_internal: one of WINDOW_COMMANDS, no result; any thread.
// A command's state delta comes before its result (Q9), so a caller that reads `state` right after
// sees what the command did. Without an attached link (the window's unit tests) each runs as before,
// straight into the core.
//
// The replica's memory: a section the core replaces is freed, so nothing may keep a pointer into
// `state` across messages. To make a slip harmless the replica lives in a deferred-free allocator:
// what a delta replaces stays readable until two frames later (client_after_tick).
//
// Terminals (M3-H): the window's copies of the terminals it shows are streamed on channels ≥ 1
// and term.* messages (term_view_stream.odin); client_frame sends their input and requests.
//
// The core asks the window with window.request (window_requests.odin) and never reads the
// window's memory: what only the window knows (its buffers' unsaved changes, a page's facts, an
// app's frames, the first-run sheet, whether it has the keyboard) it sends as window.facts and
// window.tab_facts whenever they changed (client_facts): before each command it sends, at each
// frame's start and end, before each event, and after each call or request it answered. So the
// core's copy is never older than what the window last did before the core reads it.
//
// Dev builds: DECKHAND_PROTO_LOG=1 prints every frame on the link to stderr (first 300 bytes;
// a terminal channel's frames by kind and size).

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import "core:time"
import "core"
import cw "corewire"

Client :: struct {
	attached:  bool,
	end:       cw.Mem_End,
	replica:   core.State,
	next:      u64,
	results:   map[string]core.Result, // heap copies, until taken
	pending:   map[string]u64, // a separate core: the core's request id of a result that said pending, until taken (its finished: client_call_wait)
	receiving: bool,
	log:       bool,
	main:      int, // the main thread's id: other threads only queue (client_internal)
	deferred:  Deferred_Free,
	diverged:  int, // test mode: divergences found (autotest.odin)
	swept:     time.Tick, // the last sweep (client_after_tick)
	released:  time.Tick, // the last deferred_release
	busy:      int, // inside frame() or event() (main.odin): the window may hold pointers into the replica
	facts_sent: string, // window.facts as last sent (client_facts; heap)
	tab_facts_sent: map[u64]string, // each tab's window.tab_facts as last sent (heap)
	facting:   bool, // client_facts runs (it pumps the core, which may run a command)
	// the link carries all but state: the core's requests, the tab host, the window's facts (the
	// app's init until client_attach subscribes: client_connect; the window's unit tests:
	// client_attach_host)
	host:      bool,
	detached:  bool, // test mode's detach_window: the window plays gone until attach_window
	// a separate core (client_core.odin): the link is core.sock, `state` is core.state itself
	sock:      ^cw.Sock_Transport,
	core_pid:  i32,
	abandoned: map[string]bool, // results that came past CLIENT_WAIT: dropped when they come
	focus_wait: string, // a separate core: the last Set_Focus's id, waited for before the next event (client_before_event; heap)
	lost:      bool, // the core's connection ended
	gave_up:   bool, // ...and no reconnect will be tried (client_core_give_up)
	reconnects: int, // reconnects since reconnects_since (reconnect_allowed)
	reconnects_since: time.Tick,
	handing_over: bool, // a core handover at attach: its connection's end is expected (client_core.odin)
}

client: Client

// The window's link, early in init (main.odin): what the core asks of the window while it restores
// the workspace (a restored tab's view, the first-run sheet) reaches it. `state` stays the core's
// until client_attach subscribes.
client_connect :: proc() {
	if client.attached || client.host do return
	heap := runtime.heap_allocator()
	client.log = core.hook_env(.Proto_Log) == "1" // dev and test builds only (test_hooks.odin)
	client.main = sync.current_thread_id()
	client.results = make(map[string]core.Result, heap)
	client.tab_facts_sent = make(map[u64]string, heap)
	end, ok := core.core_attach_window(client_on_frames, client_on_drain)
	if !ok do return // one window per core (it said why)
	client.end = end
	client.host = true
}

// Attaches the window to its core and makes `state` the replica (end of init, main.odin).
client_attach :: proc() {
	if client.attached do return
	if !client.host do client_connect()
	if !client.host do return
	client.host = false
	deferred_init(&client.deferred)
	client.attached = true
	client_raw(core.window_msg_subscribe())
	core.window_link_pump() // the core answers with state.full (client_on_frames applied it)
	state = &client.replica
	client_facts()
}

// The window's unit tests: the link for the tab host only (tabhost_link.odin), so the core reaches
// the window's tabs by message as in the app; `state` stays the core's and commands go straight in.
client_attach_host :: proc() {
	if client.attached || client.host do return
	heap := runtime.heap_allocator()
	client.main = sync.current_thread_id()
	client.results = make(map[string]core.Result, heap)
	client.tab_facts_sent = make(map[u64]string, heap)
	end, ok := core.core_attach_window(client_on_frames)
	if !ok do return
	client.end = end
	client.host = true
	core.window.test_facts = client_test_facts // the tests run commands straight in: the facts go first
}

// The unit tests' facts before each command (core.window.test_facts): on the test's own thread.
client_test_facts :: proc() {
	client.main = sync.current_thread_id()
	client_facts()
}

// The window's unit tests: the tab host's link off (what the core does with no window), or on again.
client_host_set :: proc(on: bool) {
	if on == client.host || client.attached do return
	client_facts_forget_all() // a new link: its core has none of them
	if on {
		end, ok := core.core_attach_window(client_on_frames)
		if !ok do return
		client.end = end
	} else do core.core_detach_window()
	client.host = on
	core.window.test_facts = on ? client_test_facts : nil
}

// Test mode's detach_window: the window plays gone (M4's no-window cases, now). The core ends what
// the window owed and answers no_window for its tabs; the replica stays as it was. Main thread.
client_detach :: proc() {
	if !client.attached do return
	core.core_detach_window()
	client.attached, client.detached = false, true
	term_views_drop_all() // the window.s terminal copies go with it: their channels are gone (term_view_stream.odin)
	client_facts_forget_all()
}

// Test mode's attach_window: the window comes back; the replica gets the whole state again.
client_reattach :: proc() {
	if !client.detached do return
	end, ok := core.core_attach_window(client_on_frames, client_on_drain)
	if !ok do return
	client.detached = false
	client.end = end
	client.attached = true
	client_raw(core.window_msg_subscribe())
	core.window_link_pump()
	client_facts()
}

// The link is up (tabhost_link.odin sends on it).
client_link_up :: proc() -> bool {return client.attached || client.host}
client_send_raw :: proc(text: string) {client_raw(text)}
client_next_id :: proc() -> string {return client_id()}
client_take_result :: proc(id: string) -> core.Result {return client_take(id)}

// A ui command; its outcome comes back as state (ui_do). menu: a menu row's label, whose
// failure is shown (core.menu_result).
client_send :: proc(cmd: core.Command, menu := "") {
	if !client.attached {
		core.inbox_submit(cmd, {kind = .UI}, menu = menu)
		return
	}
	client_facts()
	client_raw(core.window_msg_command(cmd, "", menu = menu))
	client_pump()
}

// A separate core: a Set_Focus (ui_do), whose answer the next event waits for (client_before_event).
client_send_focus :: proc(cmd: core.Command) {
	client_facts()
	id := client_id()
	client_raw(core.window_msg_command(cmd, id))
	if old := client.focus_wait; old != "" { // the newer one decides
		if old in client.results {
			client_take_result(old)
			delete(old, runtime.heap_allocator())
		} else do client.abandoned[old] = true // (the map owns the key)
	}
	client.focus_wait = strings.clone(id, runtime.heap_allocator())
}

// A ui command's result, after everything queued before it ran (ui_run). Temp-allocated strings.
client_run :: proc(cmd: core.Command) -> core.Result {
	if !client.attached {
		reply: core.Reply
		core.inbox_submit(cmd, {kind = .UI}, &reply)
		core.inbox_drain()
		out := result_temp(reply.result)
		core.result_free(reply.result)
		return out
	}
	client_facts()
	id := client_id()
	client_raw(core.window_msg_command(cmd, id))
	if client.sock != nil do return client_wait(id) // over core.sock: a bounded wait (client_core.odin)
	for core.window_link_pump() {} // past the pump's cap too: this caller waits for its result
	core.inbox_drain()
	return client_take(id)
}

// A command's result now, as a direct core.run_command gave it: a ui command, or (kind .Internal)
// one of core.WINDOW_COMMANDS. Main thread. Temp-allocated strings.
client_call :: proc(cmd: core.Command, kind: core.Caller_Kind = .UI) -> core.Result {
	assert(kind == .UI || kind == .Internal)
	if !client.attached do return core.run_command(cmd, {kind = kind})
	client_facts()
	id := client_id()
	if kind == .UI {
		client_raw(core.window_msg_command(cmd, id, now = true))
	} else {
		text, ok := core.window_msg_internal(cmd, id, now = true)
		if !ok {
			fmt.eprintln("Deckhand: not a window command:", core.command_type(cmd))
			return core.fail("not a window command")
		}
		client_raw(text)
	}
	if client.sock != nil do return client_wait(id) // over core.sock: a bounded wait (client_core.odin)
	for core.window_link_pump() && !(id in client.results) {} // past the pump's cap too: it waits for its result
	return client_take(id)
}

// One of core.WINDOW_COMMANDS, no result. Any thread: off the main thread it is queued on the
// link and the core reads it at its next drain (platform.wake).
client_internal :: proc(cmd: core.Command) {
	if !client.attached {
		core.inbox_submit(cmd, {kind = .Internal})
		return
	}
	text, ok := core.window_msg_internal(cmd, "")
	if !ok {
		fmt.eprintln("Deckhand: not a window command:", core.command_type(cmd))
		return
	}
	on_main := sync.current_thread_id() == client.main
	if on_main do client_facts()
	client_raw(text)
	if on_main do client_pump()
	else if client.sock == nil && core.platform.wake != nil do core.platform.wake() // (a socket: sent already)
}

// After the core's tick (frame): what the core changed since (terminals, timers, the test step)
// reaches the replica. A sweep compares every section at most every SWEEP_MS while frames draw
// (SWEEP_IDLE_MS while none do), for what the core changes with no trigger. Frees what deltas
// replaced two frames ago.
client_after_tick :: proc() {
	if !client.attached do return
	now := time.tick_now()
	if client.busy <= 1 { // frame() on its own: not a frame a modal loop runs under an event or a menu
		deferred_release(&client.deferred)
		client.released = now
	}
	every := app.redraw ? SWEEP_MS : SWEEP_IDLE_MS
	sweep := time.tick_diff(client.swept, now) >= time.Duration(every) * time.Millisecond
	if sweep do client.swept = now
	if client.sock != nil do client_io(0)
	else do core.window_link_flush(sweep)
	client_facts()
}

SWEEP_MS :: 100
DEFERRED_MAX :: 1024 // retired blocks a drain outside a frame lets wait (client_on_drain)
SWEEP_IDLE_MS :: 1000

// A top-level drain starts (core.inbox_drain). Outside a frame or an event (the window hidden:
// no frames, while timers and agents still drain) nothing of the window's reads the replica, so
// what deltas retired is freed here too, every SWEEP_MS or past DEFERRED_MAX blocks: it does not
// pile up until the window shows again.
client_on_drain :: proc() {
	// an event's edits reach the core before the commands queued meanwhile run (a close_tab, a reload)
	client_facts()
	if client.busy > 0 do return
	now := time.tick_now()
	if time.tick_diff(client.released, now) < SWEEP_MS * time.Millisecond && deferred_count(&client.deferred) <= DEFERRED_MAX do return
	deferred_release(&client.deferred)
	client.released = now
}

// Before handling an event: the replica holds what timers and other threads' commands did.
client_before_event :: proc() {
	if !client.attached do return
	if client.sock != nil do client_io(0)
	else do core.window_link_flush()
	if client.focus_wait != "" { // which widget has the keyboard, before this event is routed (ui_do)
		id := client.focus_wait
		client.focus_wait = ""
		if client.sock != nil && !client.lost do client_wait(id)
		delete(id, runtime.heap_allocator())
	}
	client_facts()
}

// Test mode (autotest.odin, after each script step): "" while every write to State signalled the
// stream and the replica equals the core's State; else what did not (core.window_link_check).
client_check :: proc() -> string {
	if !client.attached do return ""
	d := core.window_link_check(&client.replica) // window_link.odin: missed deltas, then window writes
	if d != "" do client.diverged += 1
	return d
}

// What only the window knows of a browser tab's page, typed (core.Browser_Facts; temp allocator).
browser_facts_of :: proc(tab_id: u64) -> (f: core.Browser_Facts) {
	annot_tab_facts(&f, tab_id) // comment mode, markers (browser_annotate.odin)
	browser_polish_tab_facts(&f, tab_id) // zoom, bars, downloads (browser_polish.odin)
	browser_agent_tab_facts(&f, tab_id) // the agent strip (browser_agent.odin)
	browser_act_tab_facts(&f, tab_id) // an upload's ask (browser_act.odin)
	return
}

// What the window knows of one tab's view (temp allocator); ok false: it has no view of it.
tab_facts_of :: proc(tab_id: u64) -> (f: core.Tab_Facts, ok: bool) {
	if b := browser_of(tab_id); b != nil {
		f.browser = browser_facts_of(tab_id)
		f.page = b.cef != 0 ? "open" : b.waiting ? "waiting" : b.lazy ? "unloaded" : b.message != "" ? "closed" : "opening"
		ok = true
	}
	if a := app_of(tab_id); a != nil {
		v := core.App_View{frames = a.ring.shown, inspect = a.inspect}
		if g := ring_gen(&a.ring, a.ring.cur_gen); g != nil do v.has_ring, v.ring_gen, v.ring_w, v.ring_h = true, g.gen, g.w, g.h
		f.app, ok = v, true
	}
	if key, has := frames_chan_key(tab_id); has do f.frames_key, ok = key, true
	if v := md_view_of(tab_id); v != nil {
		ok = true
		if v.laid {
			source := false
			if _, tab, _ := find_tab(tab_id); tab != nil do if mt, is := tab.kind.(core.Markdown_Tab); is do source = mt.source
			m: core.Md_Facts
			m.line, m.links, m.headings, m.matches = md_state_numbers(v, tab_id, source) // markdown_view.odin
			f.md = m
		}
	}
	if e := editor_of(tab_id); e != nil {
		f.dirty, ok = editor_dirty(e), true
	}
	return
}

// Sends the core what only the window knows, where it changed since it was last sent (window.facts,
// window.tab_facts), and has the core read it. Main thread; a no-op without a link.
client_facts :: proc() {
	if !client_link_up() || client.facting || sync.current_thread_id() != client.main do return
	client.facting = true
	defer client.facting = false
	heap := runtime.heap_allocator()
	sent := false
	f := core.Window_Facts{active = app.window_active, dpi = app.dpi, job_sheet_open = job_sheet_open(), unsaved = tab_views_unsaved_paths()}
	f.fps, f.scale = platform_display()
	f.frames_service, f.frames_device = frames_service()
	if s, ok := setup_state_now(); ok do f.setup = s // ui_setup.odin
	client_layout_facts(&f) // a separate core: the panes' rects (client_core.odin)
	if text := core.window_msg_facts(&f); text != client.facts_sent && client_raw(text) {
		delete(client.facts_sent, heap)
		client.facts_sent = strings.clone(text, heap)
		sent = true
	}
	ids := make(map[u64]bool, context.temp_allocator)
	for id in browsers do ids[id] = true
	for id in apps do ids[id] = true
	for id in md_views do ids[id] = true
	for id in editors do ids[id] = true
	for id in ids {
		tf, ok := tab_facts_of(id)
		text := core.window_msg_tab_facts(id, ok ? &tf : nil)
		if last, had := client.tab_facts_sent[id]; had && last == text do continue
		if !client_raw(text) do continue // refused: not sent, the next push tries again
		if old, had := client.tab_facts_sent[id]; had {
			delete(old, heap)
			client.tab_facts_sent[id] = strings.clone(text, heap)
		} else do client.tab_facts_sent[id] = strings.clone(text, heap)
		sent = true
	}
	if sent do client_pump()
}

// The tab closed (tab_view_drop): what was sent of it goes (the core drops its copy itself).
client_facts_forget :: proc(tab_id: u64) {
	if old, ok := client.tab_facts_sent[tab_id]; ok {
		delete(old, runtime.heap_allocator())
		delete_key(&client.tab_facts_sent, tab_id)
	}
}

// A new link (or none): the core has none of the window's facts; all are sent again.
client_facts_forget_all :: proc() {
	heap := runtime.heap_allocator()
	for _, v in client.tab_facts_sent do delete(v, heap)
	clear(&client.tab_facts_sent)
	delete(client.facts_sent, heap)
	client.facts_sent = ""
}

// ---- the link ----

@(private = "file")
client_id :: proc() -> string {
	client.next += 1
	return fmt.tprintf("w%d", client.next)
}

@(private = "file")
client_raw :: proc(text: string) -> bool {
	return client_frame(cw.JSON_CHANNEL, .Data, transmute([]u8)text)
}

// One frame to the core: a JSON message on channel 0, or a terminal stream's (term_view_stream.odin).
// The caller pumps the core (core.window_link_pump) when it wants it read now. False: refused.
client_frame :: proc(channel: u32, kind: cw.Kind, payload: []u8) -> bool {
	if client.log {
		if channel == cw.JSON_CHANNEL do fmt.eprintfln("[proto] window -> core %s", string(payload[:min(len(payload), 300)]))
		else do fmt.eprintfln("[proto] window -> core [%d] %v %d bytes", channel, kind, len(payload))
	}
	if client.sock != nil {
		if e := cw.sock_send(client.sock, channel, kind, payload); e != .None {
			if e != .Full do fmt.eprintln("Deckhand: the connection to the core refused a message:", e)
			return false
		}
		cw.sock_flush(client.sock) // never blocks: the rest goes at the next client_io
		return true
	}
	if e := cw.mem_send(client.end, channel, kind, payload); e != .None {
		fmt.eprintln("Deckhand: the window's link refused a message:", e)
		return false
	}
	return true
}

// The command's result, which the core sent (before returning from the pump or drain).
@(private = "file")
client_take :: proc(id: string) -> core.Result {
	r, ok := client.results[id]
	if !ok do return core.fail("the core sent no result")
	key, _ := delete_key(&client.results, id)
	delete(key, runtime.heap_allocator())
	if k, _ := delete_key(&client.pending, id); k != "" do delete(k, runtime.heap_allocator())
	out := result_temp(r)
	core.result_free(r)
	return out
}

@(private = "file")
result_temp :: proc(r: core.Result) -> core.Result {
	return core.result_clone(r, context.temp_allocator)
}

// What the core sent, read now (client_core.odin's socket turns).
client_frames_read :: proc() {client_on_frames()}

// Everything the core sent: state into the replica, results kept for their caller, toasts shown.
@(private = "file")
client_on_frames :: proc() {
	if client.receiving do return // the outer loop reads it
	client.receiving = true
	defer client.receiving = false
	heap := runtime.heap_allocator()
	for {
		f: cw.Frame
		err: cw.Recv_Error
		if client.sock != nil do f, err = cw.sock_recv(client.sock, context.temp_allocator)
		else do f, err = cw.mem_recv(client.end, context.temp_allocator)
		if err == .Closed && client.sock != nil do client_core_lost()
		if err != .None do return
		if f.channel != cw.JSON_CHANNEL {
			if client.log do fmt.eprintfln("[proto] core -> window [%d] %v %d bytes", f.channel, cw.Kind(f.kind), len(f.payload))
			term_view_frame(f) // a terminal's stream (term_view_stream.odin)
			continue
		}
		if f.kind != u8(cw.Kind.Data) do continue
		text := string(f.payload)
		if client.log do fmt.eprintfln("[proto] core -> window %s", text[:min(len(text), 300)])
		m, perr := core.window_msg_parse(text)
		if perr != "" {
			fmt.eprintln("Deckhand: a message from the core the window cannot read:", perr)
			continue
		}
		switch m.kind {
		case .State:
			if e := core.replica_apply(client.sock != nil ? &core.state : &client.replica, text, deferred_allocator(&client.deferred)); e != "" { // separate: core.state is the replica
				fmt.eprintln("Deckhand: the window's state did not apply:", e, "(asking for all of it)")
				if client.sock != nil do client_raw(core.window_msg_subscribe()) // the core sends state.full again
				else do core.window_link_resync()
			} else {
				client_got_state()
				// a separate core: the Files and Settings trees' open folders and filter came in
				// State, not through this process's commands (files.odin's cache key)
				if client.sock != nil do core.files_state_gen += 1
			}
			app.redraw = true
		case .Result:
			if m.id in client.abandoned { // its caller stopped waiting (CLIENT_WAIT): dropped
				k, _ := delete_key(&client.abandoned, m.id)
				delete(k, heap)
				continue
			}
			r := core.result_clone(m.result, heap)
			if old, had := client.results[m.id]; had {
				core.result_free(old)
				client.results[m.id] = r
			} else do client.results[strings.clone(m.id, heap)] = r
			if m.result.pending && m.request_id != 0 && client.sock != nil && !(m.id in client.pending) {
				if client.pending == nil do client.pending = make(map[string]u64, heap)
				client.pending[strings.clone(m.id, heap)] = m.request_id
			}
		case .Finished:
			core.window_test_event(core.Finished_Event{request_id = m.request_id, result = m.result}) // test mode's script waits for it (autotest_on_event)
		case .Toast:
			toast_show(m.text, m.err)
		case .Tab_Host_Call:
			// the window's part may call the core, which answers on this link: read by the inner loop
			client.receiving = false
			client.busy += 1 // window code runs (it may hold replica pointers): no release mid-call
			tab_host_on_call(text) // tabhost_link.odin
			client_facts() // what the call changed of the window's facts, before the core reads them
			client.busy -= 1
			client.receiving = true
		case .Term:
			term_view_json(text) // term.attached, term.scroll (term_view_stream.odin)
		case .Window_Request:
			// what the core asks (window_requests.odin); its answer is read by the core's pump, and the
			// window's part may send the core commands of its own: read by the inner loop
			client.receiving = false
			client.busy += 1
			window_on_request(text)
			client.busy -= 1
			client_facts() // what answering it changed (docs/PROTOCOL.md §5a)
			client.receiving = true
		case .Confirmation_Parked:
			app.redraw = true // the confirmation bar shows it from the replica, with the delta that follows
		case .Unknown:
		}
	}
}

// ---- the replica's allocator: frees wait two releases ----

Deferred_Free :: struct {
	retired: [2][dynamic]rawptr, // blocks freed since the last release, and the release before
	cur:     int,
	mu:      sync.Mutex,
}

deferred_init :: proc(d: ^Deferred_Free) {
	for &r in d.retired do r = make([dynamic]rawptr, runtime.heap_allocator())
}

deferred_allocator :: proc(d: ^Deferred_Free) -> runtime.Allocator {
	return {procedure = deferred_proc, data = d}
}

// Blocks retired and not yet freed (tests).
deferred_count :: proc(d: ^Deferred_Free) -> int {
	sync.guard(&d.mu)
	return len(d.retired[0]) + len(d.retired[1])
}

// Frees the blocks retired before the previous release; the newer ones wait for the next.
deferred_release :: proc(d: ^Deferred_Free) {
	sync.guard(&d.mu)
	heap := runtime.heap_allocator()
	old := 1 - d.cur
	for p in d.retired[old] do free(p, heap)
	clear(&d.retired[old])
	d.cur = old
}

@(private = "file")
deferred_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	d := (^Deferred_Free)(data)
	heap := runtime.heap_allocator()
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return heap.procedure(heap.data, mode, size, alignment, old_memory, old_size, loc)
	case .Free:
		if old_memory != nil {
			sync.guard(&d.mu)
			append(&d.retired[d.cur], old_memory)
		}
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		// a new block; the old one is retired, not freed (something may still read it)
		b, err := heap.procedure(heap.data, mode == .Resize ? .Alloc : .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if err != nil do return nil, err
		if old_memory != nil {
			mem.copy(raw_data(b), old_memory, min(old_size, size))
			sync.guard(&d.mu)
			append(&d.retired[d.cur], old_memory)
		}
		return b, nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}
