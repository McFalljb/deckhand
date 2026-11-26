package core

// Command inbox: the one path into run_command. Any thread submits; the main
// thread drains at the top of every frame, after each UI event, and when
// platform.wake fires (so commands run even while frames are paused). Each
// entry has a request id; a caller that wants the Result passes a Reply and
// waits on it. Long-running commands return `pending` at once and finish with
// a Finished_Event carrying the same request id.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:sync"

Reply :: struct {
	done:    sync.One_Shot_Event,
	result:  Result, // heap copies; release with result_free
	// optional, main thread, before `done` fires: lets the socket queue the
	// reply line in order with the events that follow it
	deliver: proc(reply: ^Reply, request_id: u64),
}

Request :: struct {
	id:     u64,
	caller: Caller,
	cmd:    Command, // heap copy owned by the inbox
	reply:  ^Reply,
	menu:   string, // a menu row's label (heap): its outcome is shown (menu_result)
}

@(private = "file")
inbox_mu: sync.Mutex
@(private = "file")
inbox_queue: [dynamic]Request
@(private = "file")
inbox_next: u64

// Queues cmd (copied) and returns its request id. Any thread.
inbox_submit :: proc(cmd: Command, caller: Caller, reply: ^Reply = nil, menu := "") -> u64 {
	heap := runtime.heap_allocator()
	c := command_clone(cmd, heap)
	label := strings.clone(menu, heap)
	sync.lock(&inbox_mu)
	inbox_next += 1
	id := inbox_next
	if inbox_queue.allocator.procedure == nil do inbox_queue.allocator = heap
	append(&inbox_queue, Request{id = id, caller = caller, cmd = c, reply = reply, menu = label})
	sync.unlock(&inbox_mu)
	if platform.wake != nil do platform.wake()
	return id
}

// Runs everything queued, in order. Main thread only. The window's frames are read first
// (window_link.odin: its queued commands join the queue), and its state delta goes at the end.
inbox_drain :: proc() {
	if inbox_depth == 0 do window_link_drain_starts() // nothing of an outer drain is on the stack
	inbox_depth += 1
	defer inbox_depth -= 1
	heap := runtime.heap_allocator()
	ui_ran := false // the user's commands: their delta compares every section (window_link_flush)
	capped := false // the window's frames stopped at the pump's cap: the rest wait for the next drain
	for {
		if !capped do capped = window_link_pump()
		sync.lock(&inbox_mu)
		batch := inbox_queue
		inbox_queue = make([dynamic]Request, heap)
		sync.unlock(&inbox_mu)
		if len(batch) == 0 {
			delete(batch)
			window_link_flush(sweep = ui_ran)
			return
		}
		for r in batch {
			if r.caller.kind == .UI do ui_ran = true
			res := run_command(r.cmd, r.caller, r.id)
			if r.reply != nil {
				r.reply.result = result_clone(res, heap)
				if r.reply.deliver != nil do r.reply.deliver(r.reply, r.id)
				sync.one_shot_event_signal(&r.reply.done)
			}
			if r.menu != "" do menu_result(r.menu, r.cmd, res)
			delete(r.menu, heap)
			command_free(r.cmd, heap)
		}
		delete(batch)
	}
}

@(private = "file")
inbox_depth: int // inbox_drain's nesting (main thread)

// Runs cmd now, with a request id of its own, outside the queue (what a direct run_command did):
// the window's calls that need their result at once (window_link.odin). Main thread.
inbox_run_now :: proc(cmd: Command, caller: Caller, menu := "") -> (Result, u64) {
	sync.lock(&inbox_mu)
	inbox_next += 1
	id := inbox_next
	sync.unlock(&inbox_mu)
	res := run_command(cmd, caller, id)
	if menu != "" do menu_result(menu, cmd, res)
	return res, id
}

result_clone :: proc(r: Result, allocator: runtime.Allocator) -> Result {
	out := r
	out.error = strings.clone(r.error, allocator)
	out.confirm_token = strings.clone(r.confirm_token, allocator)
	out.confirm_summary = strings.clone(r.confirm_summary, allocator)
	out.data = strings.clone(r.data, allocator)
	return out
}

result_free :: proc(r: Result) {
	allocator := runtime.heap_allocator()
	delete(r.error, allocator)
	delete(r.confirm_token, allocator)
	delete(r.confirm_summary, allocator)
	delete(r.data, allocator)
}

// Deep copy of a command: its strings and lists allocated with allocator (but its `borrow`
// fields, command_codec.odin).
command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	info := command_info(cmd)
	if info == nil do return nil
	src, out := cmd, Command{}
	reflect.set_union_variant_typeid(any{&out, typeid_of(Command)}, info.id)
	for &f in info.fields {
		s, d := rawptr(uintptr(&src) + f.offset), rawptr(uintptr(&out) + f.offset)
		if f.borrow do mem.copy(d, s, f.ti.size)
		else do wire_clone_unlimited(s, d, f.ti, allocator)
	}
	return out
}

// Frees what command_clone (or the parser, with the same allocator) allocated.
command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	info := command_info(cmd)
	if info == nil do return
	c := cmd
	for &f in info.fields do if !f.borrow do wire_free(rawptr(uintptr(&c) + f.offset), f.ti, allocator)
}

// What a menu row's command did, where nothing else on screen shows it: a
// failure always (else a click seems to do nothing), a copy when it worked.
// Not a command that finishes later or asks first (the confirmation bar).
menu_result :: proc(label: string, cmd: Command, r: Result) {
	if r.pending || r.error == "needs_confirmation" do return
	if r.error == CLAUDE_MISSING do return // the command said how to install it already (claude.odin)
	if !r.ok {
		why := r.error != "" ? r.error : "it did not work"
		window_toast(fmt.tprintf("%s: %s", strings.trim_suffix(label, "…"), why), err = true)
		return
	}
	#partial switch c in cmd {
	case Session_Info: if c.to == "clipboard" do window_toast("Session info copied")
	case Copy_Path:    window_toast("Path copied")
	}
}
