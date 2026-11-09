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
	receiving: bool,
	log:       bool,
	main:      int, // the main thread's id: other threads only queue (client_internal)
	deferred:  Deferred_Free,
	diverged:  int, // test mode: divergences found (autotest.odin)
	swept:     time.Tick, // the last sweep (client_after_tick)
	released:  time.Tick, // the last deferred_release
	busy:      int, // inside frame() or event() (main.odin): the window may hold pointers into the replica
	facts_sent: map[u64]string, // each browser tab's facts as last sent (client_pull)
	host:      bool, // the link carries the tab host only (the window's unit tests: client_attach_host)
	detached:  bool, // test mode's detach_window: the window plays gone until attach_window
}

client: Client

// Attaches the window to its core and makes `state` the replica (end of init, main.odin).
client_attach :: proc() {
	if client.attached do return
	heap := runtime.heap_allocator()
	client.log = core.hook_env(.Proto_Log) == "1" // dev and test builds only (test_hooks.odin)
	client.main = sync.current_thread_id()
	client.results = make(map[string]core.Result, heap)
	deferred_init(&client.deferred)
	client.facts_sent = make(map[u64]string, heap)
	end, ok := core.core_attach_window(client_on_frames, client_pull, client_on_drain)
	if !ok do return // one window per core (it said why)
	client.end = end
	client.attached = true
	client_raw(core.window_msg_subscribe())
	core.window_link_pump() // the core answers with state.full (client_on_frames applied it)
	state = &client.replica
}

// The window's unit tests: the link for the tab host only (tabhost_link.odin), so the core reaches
// the window's tabs by message as in the app; `state` stays the core's and commands go straight in.
client_attach_host :: proc() {
	if client.attached || client.host do return
	heap := runtime.heap_allocator()
	client.main = sync.current_thread_id()
	client.results = make(map[string]core.Result, heap)
	client.facts_sent = make(map[u64]string, heap)
	end, ok := core.core_attach_window(client_on_frames, client_pull)
	if !ok do return
	client.end = end
	client.host = true
}

// The window's unit tests: the tab host's link off (what the core does with no window), or on again.
client_host_set :: proc(on: bool) {
	if on == client.host || client.attached do return
	if on {
		end, ok := core.core_attach_window(client_on_frames, client_pull)
		if !ok do return
		client.end = end
	} else do core.core_detach_window()
	client.host = on
}

// Test mode's detach_window: the window plays gone (M4's no-window cases, now). The core ends what
// the window owed and answers no_window for its tabs; the replica stays as it was. Main thread.
client_detach :: proc() {
	if !client.attached do return
	core.core_detach_window()
	client.attached, client.detached = false, true
	// TODO(M3-H): term_views_drop_all() here: the window's terminal views go with it (M3-H adds it)
	heap := runtime.heap_allocator()
	for _, v in client.facts_sent do delete(v, heap)
	clear(&client.facts_sent)
}

// Test mode's attach_window: the window comes back; the replica gets the whole state again.
client_reattach :: proc() {
	if !client.detached do return
	end, ok := core.core_attach_window(client_on_frames, client_pull, client_on_drain)
	if !ok do return
	client.detached = false
	client.end = end
	client.attached = true
	client_raw(core.window_msg_subscribe())
	core.window_link_pump()
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
	client_raw(core.window_msg_command(cmd, "", menu = menu))
	core.window_link_pump()
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
	id := client_id()
	client_raw(core.window_msg_command(cmd, id))
	core.window_link_pump()
	core.inbox_drain()
	return client_take(id)
}

// A command's result now, as a direct core.run_command gave it: a ui command, or (kind .Internal)
// one of core.WINDOW_COMMANDS. Main thread. Temp-allocated strings.
client_call :: proc(cmd: core.Command, kind: core.Caller_Kind = .UI) -> core.Result {
	assert(kind == .UI || kind == .Internal)
	if !client.attached do return core.run_command(cmd, {kind = kind})
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
	core.window_link_pump()
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
	client_raw(text)
	if sync.current_thread_id() == client.main do core.window_link_pump()
	else if core.platform.wake != nil do core.platform.wake()
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
	core.window_link_flush(sweep)
}

SWEEP_MS :: 100
DEFERRED_MAX :: 1024 // retired blocks a drain outside a frame lets wait (client_on_drain)
SWEEP_IDLE_MS :: 1000

// A top-level drain starts (core.inbox_drain). Outside a frame or an event (the window hidden:
// no frames, while timers and agents still drain) nothing of the window's reads the replica, so
// what deltas retired is freed here too, every SWEEP_MS or past DEFERRED_MAX blocks: it does not
// pile up until the window shows again.
client_on_drain :: proc() {
	if client.busy > 0 do return
	now := time.tick_now()
	if time.tick_diff(client.released, now) < SWEEP_MS * time.Millisecond && deferred_count(&client.deferred) <= DEFERRED_MAX do return
	deferred_release(&client.deferred)
	client.released = now
}

// Before handling an event: the replica holds what timers and other threads' commands did.
client_before_event :: proc() {
	if client.attached do core.window_link_flush()
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

// The core asks for a browser tab's facts (get_state): sent when they changed since the last time.
client_pull :: proc(tab_id: u64) {
	f := browser_facts_of(tab_id)
	text := core.window_msg_browser_facts(tab_id, &f)
	if last, ok := client.facts_sent[tab_id]; ok && last == text do return
	if !client_raw(text) do return // refused: not sent, the next pull tries again
	heap := runtime.heap_allocator()
	if old, ok := client.facts_sent[tab_id]; ok do delete(old, heap)
	client.facts_sent[tab_id] = strings.clone(text, heap)
}

// The tab closed (tab_view_drop): what was sent of it goes (the core drops its copy itself).
client_facts_forget :: proc(tab_id: u64) {
	if old, ok := client.facts_sent[tab_id]; ok {
		delete(old, runtime.heap_allocator())
		delete_key(&client.facts_sent, tab_id)
	}
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
	out := result_temp(r)
	core.result_free(r)
	return out
}

@(private = "file")
result_temp :: proc(r: core.Result) -> core.Result {
	return core.result_clone(r, context.temp_allocator)
}

// Everything the core sent: state into the replica, results kept for their caller, toasts shown.
@(private = "file")
client_on_frames :: proc() {
	if client.receiving do return // the outer loop reads it
	client.receiving = true
	defer client.receiving = false
	heap := runtime.heap_allocator()
	for {
		f, err := cw.mem_recv(client.end, context.temp_allocator)
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
			if e := core.replica_apply(&client.replica, text, deferred_allocator(&client.deferred)); e != "" {
				fmt.eprintln("Deckhand: the window's state did not apply:", e, "(asking for all of it)")
				core.window_link_resync()
			}
			app.redraw = true
		case .Result:
			r := core.result_clone(m.result, heap)
			if old, had := client.results[m.id]; had {
				core.result_free(old)
				client.results[m.id] = r
			} else do client.results[strings.clone(m.id, heap)] = r
		case .Toast:
			toast_show(m.text, m.err)
		case .Tab_Host_Call:
			// the window's part may call the core, which answers on this link: read by the inner loop
			client.receiving = false
			client.busy += 1 // window code runs (it may hold replica pointers): no release mid-call
			tab_host_on_call(text) // tabhost_link.odin
			client.busy -= 1
			client.receiving = true
		case .Term:
			term_view_json(text) // term.attached, term.scroll (term_view_stream.odin)
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
