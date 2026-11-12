package core

// Working in another machine's sessions (docs/plans/background-core.md §8.3, §10.4 M6-C): the
// user's commands on its ids go to its core, and its terminals are relayed to the window.
//
// Commands. A command naming another machine's id (machine_mirror.odin's id fields: all of one
// machine, else refused) runs there, not here. run_command checks caller_may first; then only the
// user's (ui) and Atlas's (control, M6-F) are forwarded, and only when they are this machine's own
// (not Caller.hub: a machine viewing this one never drives a third through it), on that machine's
// link, with every id unpacked, a pi session id's "m<no>:" taken off, and "on_behalf":{"kind":
// "ui"|"control"} (the caller's own kind): its core applies that kind's rules again (window_link.
// odin's hub_on_behalf: never above ui, never internal). Any other caller's is refused here. A
// control command that machine wants confirmed is refused here, not asked in this Mac's bar (the
// user does it from the window). A wait (pi_wait_idle, claude_wait_idle) waits its own timeout
// there, plus ROUTE_WAIT_SLACK. The answer is "pending"; the command's
// state arrives through the mirror before its result (that core flushes its delta first, Q9), and
// the result finishes the request here (route_result): its created_id packed, its error this
// core's words for a known code (ROUTE_CODES) or "on <machine>: " and its text cleaned and cut
// short, its data only {code?, id? (a claude_prompt's held text), count? (a mark_all_read's)}, and Result.remote set (the
// reply's top-level "machine", which only this sets). A link
// that is down answers machine_offline. Its view stays this Mac's: focusing one of its sessions and
// selecting one of its projects run here (Focus_Session also goes there, so its restored tabs
// start), and Copy_Selection copies the window's own copy here (the user's ⌘C).
//
// Its confirmations (needs_confirmation, for the user) are asked here: the bar shows "On <machine>:
// <its summary, cleaned>" with a token of this core's, and confirming sends the user's command
// again with that machine's token; Cancel cancels it there too. Only an answer to one of the user's
// own commands parks one, never a message of its own (confirmation.parked is dropped, M6-A).
//
// Terminals: relayed, not parsed (§5.5; this core keeps no terminal for them). The window's
// term.attach on another machine's tab gets a channel of this core's at once, attached on that
// machine's link (its own channel there); SNAPSHOT, DATA, RESIZE and CLOSE come back on the
// window's channel, the window's DATA, CREDIT and FOCUS go there, and term.resize and term.detach
// follow. Credit passes through end to end. A link that goes down keeps the window's channels;
// up again, each is attached again and its fresh snapshot replaces the window's copy. Its bytes are
// untrusted: its snapshots are asked for as the VT replay ("snapshot":"vt") of at most
// RELAY_SNAP_MAX ("snapshot_max"; the window parses one in a go), so the window's own
// parser takes them as it takes its DATA and a local program's; a GHOSTSNP (whose decoder has no
// MAC against another machine), any other snapshot or a larger one, a RESIZE outside the grid limits, DATA past
// twice the credit, more than RELAY_SNAPS_PER_SEC snapshots, or a channel given twice ends that
// stream there, attached again RELAY_RETRY later.
// OSC 52 from its terminals is its core's window.request, which is dropped (machines.odin).

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"

import cw "../corewire"
import hw "../holderwire"
import jg "../jsonguard"

ROUTE_FORWARDS_MAX :: 256 // the user's commands waiting for other machines' answers
ROUTE_WAIT :: 30 * time.Second // ...each, at most
ROUTE_PROXIES_MAX :: 32 // their confirmations asked here
RELAYS_MAX :: 256 // terminals relayed
RELAY_IN_FLIGHT_MAX :: 2 * STREAM_CREDIT // DATA the window has not credited: past it, the stream is ended there
RELAY_SNAPS_PER_SEC :: 4
RELAY_SNAP_MAX :: 2 << 20 // a snapshot from another machine, at most (asked for as snapshot_max): parsed on the window's main thread
RELAY_RETRY :: 2 * time.Second
ROUTE_TEXT_MAX :: 300 // its errors and confirmation summaries (text_clean)
ROUTE_REMOTE_ERROR_MAX :: 160 // another machine's error text here, cut to this (bytes; after "on <machine>: ")
ROUTE_WAIT_SLACK :: 10 * time.Second // a forwarded wait: its own timeout, plus this
ROUTE_WAIT_MAX :: 130 * time.Second
ROUTE_COUNT_MAX :: 1 << 20 // a forwarded mark_all_read's count, at most (a larger one is clamped)
// The data codes a forwarded command's result keeps (data.code; everything else in its data is
// dropped): what the agents' tools read. Each comes with this core's own words, never that
// machine's (review round 1).
ROUTE_CODES := [?]string{"timeout", "tab_gone", "cancelled", "dropped", "browser_not_here", "no_window", "machine_offline"}
@(private = "file")
ROUTE_CODE_TEXTS := [?]string {
	"it did not finish in time",
	"that tab is gone",
	"it was cancelled",
	"the user dropped the prompt before it was sent",
	"browser tabs run only in that machine's own window",
	"that machine has no window",
	"it is not connected",
}

@(private = "file")
Forward :: struct {
	id:         u64, // "h<id>" on the link
	machine:    u64,
	request_id: u64, // this core's (the window's command)
	remote_rid: u64, // that core's, once its result said pending
	cmd:        Command, // the user's, ids packed (heap): a confirmation asked here holds it
	kind:       Caller_Kind, // .UI or .Control
	sent:       time.Tick,
	wait:       time.Duration, // its answer, at most this late
	fan:        u64, // one machine's part of a Mark_All_Read fan (its id; 0: none)
}

// The user's Mark all sessions as read (⌥⇧⌘U) at this Mac: this Mac's sessions marked here, then
// the same command sent to every online machine (each marks its own); its one toast and its
// finished come once every machine answered (or failed, went offline, timed out).
@(private = "file")
Fan :: struct {
	id:         u64,
	request_id: u64,
	count:      int, // sessions marked: here, and by each machine that answered
	waiting:    int, // machines not answered yet
	notes:      [dynamic]string, // what did not work, or was skipped, per machine (heap)
	failed:     bool, // a machine refused or could not get it (the toast is an error's)
}

@(private = "file")
Confirm_Proxy :: struct {
	token:   string, // this core's (heap; the bar's Pending_Confirmation has its own copy)
	machine: u64,
	remote:  string, // that core's token (heap)
}

Term_Relay :: struct {
	channel:   u32, // the window's
	machine:   u64,
	tab_id:    u64, // packed
	remote:    u32, // its channel on the link (0: not attached there)
	asking:    bool, // term.attach sent, no term.attached yet
	history:   int,
	in_flight: int, // DATA sent the window has not credited
	snaps:     int, // snapshots since snaps_at
	snaps_at:  time.Tick,
	retry_at:  time.Tick, // ended there for misbehaving: attached again then ({}: not waiting)
}

@(private = "file")
route: struct {
	forwards: [dynamic]^Forward,
	proxies:  [dynamic]Confirm_Proxy,
	relays:   [dynamic]^Term_Relay,
	fans:     [dynamic]^Fan,
	next:     u64,
}

// The relays (tests).
machine_relays :: proc() -> []^Term_Relay {return route.relays[:]}
@(private)
route_relays_for_test :: proc() -> ^[dynamic]^Term_Relay {return &route.relays}

// ---- commands ----

// The one machine a command's ids name (0: this Mac's, or none); mixed: ids of two machines.
command_machine :: proc(cmd: Command) -> (no: u64, mixed: bool) {
	cmd := cmd
	v := reflect.get_union_variant(cmd)
	if v.data == nil do return 0, false
	st, ok := runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Struct)
	if !ok do return 0, false
	seen := false
	for k in 0 ..< int(st.field_count) {
		if st.types[k].id != typeid_of(u64) || !machine_id_field(st.names[k]) do continue
		id := (^u64)(uintptr(v.data) + st.offsets[k])^
		if id == 0 do continue
		m := id_machine(id)
		if seen && m != no do return 0, true
		no, seen = m, true
	}
	return no, false
}

// cmd as machine no runs it: its ids unpacked, a pi session id's "m<no>:" off, and a confirm token
// of this core's (a confirmation asked here) made that machine's own (its entry here goes). Strings
// are cmd's (temp).
@(private = "file")
command_for_machine :: proc(cmd: Command, no: u64) -> Command {
	out := cmd
	v := reflect.get_union_variant(out)
	if v.data == nil do return out
	st, ok := runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Struct)
	if !ok do return out
	prefix := fmt.tprintf("m%d:", no)
	for k in 0 ..< int(st.field_count) {
		at := rawptr(uintptr(v.data) + st.offsets[k])
		switch {
		case st.types[k].id == typeid_of(u64) && machine_id_field(st.names[k]):
			p := (^u64)(at)
			p^ = id_local(p^)
		case st.types[k].id == typeid_of(string) && st.names[k] == "pi_session_id":
			p := (^string)(at)
			p^ = strings.trim_prefix(p^, prefix)
		case st.types[k].id == typeid_of(string) && st.names[k] == "confirm":
			p := (^string)(at)
			if i := proxy_find(p^, no); i >= 0 {
				p^ = strings.clone(route.proxies[i].remote, context.temp_allocator)
				proxy_drop(i)
			}
		}
	}
	return out
}

// A command for machine no's core, as the hub sends it (id "": no reply).
hub_command_json :: proc(cmd: Command, id: string, kind: Caller_Kind) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"command","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	fmt.sbprintf(&b, `,"now":true,"on_behalf":{{"kind":"%s"}},"command":`, caller_kind_name(kind))
	strings.write_string(&b, command_wire_json(cmd))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// run_command's routing: routed, with its result, when cmd is another machine's (forwarded or
// refused); else it runs here.
machine_route :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, routed: bool) {
	if c, is := cmd.(Cancel_Confirmation); is {
		for p, i in route.proxies do if p.token == c.token { 	// asked here for another machine
			// there too, as the user's (another caller's cancel drops it here only: it expires there)
			if caller.kind == .UI && !caller.hub do machine_link_send_text(p.machine, hub_command_json(Cancel_Confirmation{token = p.remote}, "", .UI))
			proxy_drop(i)
			return {ok = true}, true
		}
		return {}, false
	}
	// a hub's Codex tab, even with this machine's own ids: never (codex.odin, CODEX_REMOTE)
	if caller.hub {
		#partial switch c in cmd {
		case New_Claude_Session: if c.codex do return fail(CODEX_REMOTE), true
		case New_Claude_Tab:     if c.codex do return fail(CODEX_REMOTE), true
		}
	}
	no, mixed := command_machine(cmd)
	if mixed do return fail("this names ids on two machines"), true
	if su, is := cmd.(Set_Unread); is && su.tab_id == 0 do no = unread_session_machine(su.pi_session_id)
	if no == 0 do return {}, false
	#partial switch c in cmd {
	case Select_Project, Copy_Selection:
		return {}, false // this Mac's view; the window's own copy's selection
	case Terminal_Link:
		// the user's click at this window opens here (tabhost_route.odin: the default browser, never
		// a browser tab): never sent there, and nobody else's (a hub's, Atlas's) opens anything here
		if caller.kind == .UI && !caller_from_hub(caller) do return {}, false
		return fail("a link in another machine's terminal opens only from your click in this window"), true
	case New_Claude_Session:
		if c.codex do return fail(CODEX_REMOTE), true // codex.odin: this Mac only (an older core there would start claude)
	case New_Claude_Tab:
		if c.codex do return fail(CODEX_REMOTE), true
	case Focus_Session:
		// this Mac's view; the user's goes there too, so its restored tabs start
		if caller.kind == .UI && !caller.hub do machine_link_send_text(no, hub_command_json(Focus_Session{session = id_local(c.session), reopen = c.reopen}, "", .UI))
		return {}, false
	}
	// the user's and Atlas's, from this machine only: never a hub's (no reaching a third machine)
	if (caller.kind != .UI && caller.kind != .Control) || caller.hub do return fail("this is on another machine: only you and Atlas on this machine can work in it from here"), true
	r = forward_send(cmd, no, caller.kind, request_id)
	if !r.ok && caller.kind == .UI do route_toast(cmd, r)
	return r, true
}

// cmd (ids packed) sent to machine no's core as kind's: pending, or why it could not go.
@(private = "file")
forward_send :: proc(cmd: Command, no: u64, kind: Caller_Kind, request_id: u64, fan: u64 = 0) -> Result {
	if !machine_link_up(no) do return machine_offline(no)
	if len(route.forwards) >= ROUTE_FORWARDS_MAX do return fail("too many commands are waiting for other machines")
	heap := runtime.heap_allocator()
	route.next += 1
	f := new(Forward, heap)
	f^ = {id = route.next, machine = no, request_id = request_id, cmd = command_clone(cmd, heap), kind = kind, sent = time.tick_now(), wait = route_wait(cmd), fan = fan}
	if !machine_link_send_text(no, hub_command_json(command_for_machine(cmd, no), fmt.tprintf("h%d", f.id), kind)) {
		forward_free(f)
		return machine_offline(no)
	}
	append(&route.forwards, f)
	if autotest_active do fmt.printfln("[autotest] machine %s: forwarded %s", machine_name(no), command_type(cmd))
	return {ok = true, pending = true}
}

// The machine of the open session a Set_Unread names by its pi session id (0: this Mac's, or none
// open): another machine's row reads "m<no>:<its id>", and the mirror's session says whose it is.
@(private = "file")
unread_session_machine :: proc(pi_session_id: string) -> u64 {
	if pi_session_id == "" do return 0
	for s in state.open_sessions do if !s.home && s.machine != 0 && s.pi_session_id == pi_session_id do return s.machine
	return 0
}

// The user's command another machine refused (or could not get): said in a toast where nothing
// else would say it (a key's, or one that finished later; a menu row's failure says it too, in
// the same words: inbox.odin's menu_result).
@(private = "file")
route_toast :: proc(cmd: Command, r: Result) {
	if r.ok || r.pending || r.error == "needs_confirmation" do return
	#partial switch c in cmd {
	case Set_Unread:
		window_toast(fmt.tprintf("%s: %s", c.unread ? "Mark as unread" : "Mark as read", r.error != "" ? r.error : "it did not work"), err = true)
	}
}

// Mark all sessions as read, the user's at this Mac (mark_read.odin; here already: `here`
// sessions marked): sent to every online machine as the user's, each marking its own; an offline
// one is skipped (the toast says so). fanned: the toast and the finished come when they answer.
machine_mark_all_read :: proc(caller: Caller, request_id: u64, here: int) -> (r: Result, fanned: bool) {
	if caller.kind != .UI || caller_from_hub(caller) do return {}, false // a hub's: that machine's own only (no third machine)
	heap := runtime.heap_allocator()
	fan := new(Fan, heap)
	route.next += 1
	fan^ = {id = route.next, request_id = request_id, count = here, notes = make([dynamic]string, heap)}
	for m in state.machines {
		if m.no == 0 do continue
		if !machine_link_up(m.no) {
			if m.status != .Online && m.status != .Connecting do append(&fan.notes, fmt.aprintf("%s is not connected", machine_name(m.no), allocator = heap))
			continue
		}
		fr := forward_send(Mark_All_Read{}, m.no, .UI, 0, fan.id)
		if fr.pending do fan.waiting += 1
		else {
			append(&fan.notes, strings.clone(fr.error, heap))
			fan.failed = true
		}
	}
	if fan.waiting > 0 {
		append(&route.fans, fan)
		return {ok = true, pending = true}, true
	}
	r = fan_result(fan)
	fan_free(fan)
	return r, true
}

// A fan's toast ("Marked N as read", "Nothing unread", then what did not work) and its result.
@(private = "file")
fan_result :: proc(fan: ^Fan) -> Result {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, fan.count == 0 ? "Nothing unread" : fmt.tprintf("Marked %d as read", fan.count))
	for n in fan.notes do fmt.sbprintf(&b, " · %s", n)
	window_toast(strings.to_string(b), err = fan.failed)
	return {ok = true, data = fmt.tprintf(`{{"count":%d}}`, fan.count)}
}

@(private = "file")
fan_free :: proc(fan: ^Fan) {
	heap := runtime.heap_allocator()
	for n in fan.notes do delete(n, heap)
	delete(fan.notes)
	free(fan, heap)
}

// Machine f's answer to its part of a fan (r: as route_result made it); the last one ends the fan.
@(private = "file")
fan_answer :: proc(f: ^Forward, r: Result) {
	at := -1
	for x, i in route.fans do if x.id == f.fan do at = i
	if at < 0 do return
	fan := route.fans[at]
	if r.ok {
		if n, ok := strconv.parse_int(json_path(r.data, "count")); ok && n > 0 do fan.count += n
	} else {
		append(&fan.notes, strings.clone(r.error != "" ? r.error : fmt.tprintf("on %s: it did not work", machine_name(f.machine)), runtime.heap_allocator()))
		fan.failed = true
	}
	fan.waiting -= 1
	if fan.waiting > 0 do return
	ordered_remove(&route.fans, at)
	defer fan_free(fan)
	emit_event(Finished_Event{request_id = fan.request_id, result = fan_result(fan)})
}

// How long a forwarded command's answer may take: a wait's own timeout there, plus slack.
@(private = "file")
route_wait :: proc(cmd: Command) -> time.Duration {
	ms: u64
	#partial switch c in cmd {
	case Pi_Wait_Idle:     ms = c.timeout_ms
	case Claude_Wait_Idle: ms = c.timeout_ms
	case:                  return ROUTE_WAIT
	}
	if ms == 0 || ms > u64(ROUTE_WAIT_MAX / time.Millisecond) do return ROUTE_WAIT_MAX
	return clamp(time.Duration(ms) * time.Millisecond + ROUTE_WAIT_SLACK, ROUTE_WAIT, ROUTE_WAIT_MAX)
}

@(private = "file")
machine_offline :: proc(no: u64) -> Result {
	return {error = fmt.tprintf("%s is not connected", machine_name(no)), data = `{"code":"machine_offline"}`}
}

@(private = "file")
forward_free :: proc(f: ^Forward) {
	heap := runtime.heap_allocator()
	command_free(f.cmd, heap)
	free(f, heap)
}

// Forward i ends: its request finishes with r.
@(private = "file")
forward_finish :: proc(i: int, r: Result) {
	f := route.forwards[i]
	ordered_remove(&route.forwards, i)
	defer forward_free(f)
	if f.fan != 0 {
		fan_answer(f, r)
		return
	}
	if f.kind == .UI do route_toast(f.cmd, r)
	r := r
	if r.ok && r.created_id != 0 && f.kind == .UI {
		// it opened or made one of its sessions: shown here, as a local one would be
		if s := find_session(r.created_id); s != nil && s.machine == f.machine && state.current_session != s.id {
			run_command(Focus_Session{session = s.id}, {kind = .Internal})
		}
	}
	emit_event(Finished_Event{request_id = f.request_id, result = r})
}

// A result or finished from machine no's core (its text; machines.odin's pump).
machine_route_reply :: proc(no: u64, text: string) {
	m, err := window_msg_parse(text)
	if err != "" do return
	idx := -1
	if m.kind == .Result {
		n, ok := strconv.parse_u64(strings.trim_prefix(m.id, "h"))
		if !ok || !strings.has_prefix(m.id, "h") do return
		for f, i in route.forwards do if f.machine == no && f.id == n && f.remote_rid == 0 do idx = i
		if idx < 0 do return
		if m.result.pending && m.request_id != 0 { 	// its finished comes later
			route.forwards[idx].remote_rid = m.request_id
			return
		}
	} else if m.kind == .Finished {
		if m.request_id == 0 do return
		for f, i in route.forwards do if f.machine == no && f.remote_rid == m.request_id do idx = i
		if idx < 0 do return
	} else do return
	rr := m.result
	r := route_result(no, route.forwards[idx], rr)
	if !rr.ok && rr.error == "needs_confirmation" {
		f := route.forwards[idx]
		if f.kind != .UI { 	// Atlas's: never asked in this Mac's bar
			r = fail(fmt.tprintf("on %s this needs the user's confirmation: ask the user to do it from Deckhand's window", machine_name(no)))
		} else if rr.confirm_token != "" {
			r = proxy_park(f, rr)
		}
	}
	forward_finish(idx, r)
}

// A forwarded command's result as this core answers it (review round 1): ok and created_id
// (packed); the error in this core's words for a known code, else "on <machine>: " and that
// machine's text, one line, cleaned and cut short (the agents' tools mark it as that machine's
// data); data {"code"?: a known code, "id"?: a claude_prompt's held text's id (an integer, 1 to
// 2^53-1), "count"?: a mark_all_read's sessions marked there (0 up, clamped to ROUTE_COUNT_MAX)}, nothing
// else of what it sent; remote = no (round 2: the reply's top-level "machine",
// beside data, which only this sets: a local app's error data may hold any field).
@(private = "file")
route_result :: proc(no: u64, f: ^Forward, rr: Result) -> Result {
	r := Result{ok = rr.ok, remote = no}
	if rr.created_id != 0 do r.created_id, _ = id_pack(no, rr.created_id)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	known := -1
	if code := json_path(rr.data, "code"); code != "" do for c, i in ROUTE_CODES do if c == code do known = i
	if known >= 0 do fmt.sbprintf(&b, `"code":"%s"`, ROUTE_CODES[known])
	// a claude_prompt's held text's id; a mark_all_read's count of sessions marked there (bounded)
	_, prompt := f.cmd.(Claude_Prompt)
	_, all_read := f.cmd.(Mark_All_Read)
	if (prompt || all_read) && rr.data != "" {
		if v, err := jg.parse_string(rr.data, .JSON, true, context.temp_allocator); err == nil {
			if o, ok := v.(json.Object); ok {
				if id, iok := o["id"].(json.Integer); prompt && iok && id > 0 && id < 1 << 53 do fmt.sbprintf(&b, `%s"id":%d`, known >= 0 ? "," : "", id)
				// a machine may have marked more sessions than this Mac mirrors of it: clamped, never dropped
				if n, nok := o["count"].(json.Integer); all_read && rr.ok && nok && n >= 0 do fmt.sbprintf(&b, `%s"count":%d`, known >= 0 ? "," : "", min(n, ROUTE_COUNT_MAX))
			}
		}
	}
	strings.write_byte(&b, '}')
	if strings.builder_len(b) > 2 do r.data = strings.to_string(b)
	switch {
	case known >= 0:
		r.error = rr.ok ? "" : fmt.tprintf("on %s: %s", machine_name(no), ROUTE_CODE_TEXTS[known])
	case rr.error != "":
		r.error = fmt.tprintf("on %s: %s", machine_name(no), text_clean_remote(rr.error, ROUTE_REMOTE_ERROR_MAX))
	}
	return r
}

// That machine wants the user to confirm f's command: asked here (the bar), with a token of this
// core's.
@(private = "file")
proxy_park :: proc(f: ^Forward, rr: Result) -> Result {
	heap := runtime.heap_allocator()
	remote := text_clean(rr.confirm_token, 64)
	for p in route.proxies do if p.machine == f.machine && p.remote == remote { 	// asked again: the same entry
		for pc in state.pending_confirmations do if pc.token == p.token do return {error = "needs_confirmation", confirm_token = p.token, confirm_summary = pc.summary}
	}
	if len(route.proxies) >= ROUTE_PROXIES_MAX do return fail(fmt.tprintf("%s wants a confirmation, and too many are waiting", machine_name(f.machine)))
	token := new_uuid()
	summary := fmt.aprintf("On %s: %s", machine_name(f.machine), text_clean(rr.confirm_summary, ROUTE_TEXT_MAX))
	append(&state.pending_confirmations, Pending_Confirmation{token = token, summary = summary, command = command_clone(f.cmd, heap), class = .Tab_Close, caller = {kind = .UI}})
	append(&route.proxies, Confirm_Proxy{token = strings.clone(token, heap), machine = f.machine, remote = strings.clone(remote, heap)})
	window_confirmation_parked(summary, false)
	window_state_changed()
	return {error = "needs_confirmation", confirm_token = token, confirm_summary = summary}
}

@(private = "file")
proxy_find :: proc(token: string, no: u64) -> int {
	if token == "" do return -1
	for p, i in route.proxies do if p.machine == no && p.token == token do return i
	return -1
}

// Proxy i goes, and its entry in the bar.
@(private = "file")
proxy_drop :: proc(i: int) {
	heap := runtime.heap_allocator()
	p := route.proxies[i]
	ordered_remove(&route.proxies, i)
	for pc, k in state.pending_confirmations do if pc.token == p.token {
		ordered_remove(&state.pending_confirmations, k)
		window_state_changed()
		break
	}
	delete(p.token, heap)
	delete(p.remote, heap)
}

// ---- terminals ----

@(private = "file")
relay_of :: proc(channel: u32) -> (^Term_Relay, int) {
	for r, i in route.relays do if r.channel == channel do return r, i
	return nil, -1
}

@(private = "file")
relay_free :: proc(i: int) {
	r := route.relays[i]
	ordered_remove(&route.relays, i)
	free(r, runtime.heap_allocator())
}

// The window's term.attach on another machine's tab: a channel here now (attached there once its
// link is up).
machine_term_attach :: proc(id: string, tab_id: u64, history: int) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"term.attached","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	fmt.sbprintf(&b, `,"tab_id":%d`, tab_id)
	_, tab, _ := find_tab(tab_id)
	if tab == nil || tab.machine == 0 || !tab.has_term || len(route.relays) >= RELAYS_MAX {
		if autotest_active do fmt.printfln("[autotest] machine terminal %d: no such terminal", tab_id)
		strings.write_string(&b, `,"error":"no such terminal"}`)
		window_link_send_text(strings.to_string(b))
		return
	}
	r := new(Term_Relay, runtime.heap_allocator())
	r^ = {channel = term_stream_channel_new(), machine = tab.machine, tab_id = tab_id, history = history}
	append(&route.relays, r)
	fmt.sbprintf(&b, `,"channel":%d,"offset":0}}`, r.channel)
	window_link_send_text(strings.to_string(b))
	relay_attach(r)
}

// Attaches r on its machine's link (when up).
@(private = "file")
relay_attach :: proc(r: ^Term_Relay) {
	r.remote, r.asking, r.in_flight = 0, false, 0
	if !machine_link_up(r.machine) do return
	// its snapshots as the VT replay: the window's parser takes them as it takes their DATA, and the
	// GHOSTSNP decoder never sees another machine's bytes
	r.asking = machine_link_send_text(r.machine, fmt.tprintf(`{{"v":%d,"type":"term.attach","id":"r%d","tab_id":%d,"history_lines":%d,"snapshot":"vt","snapshot_max":%d}}`, PROTOCOL_VERSION, r.channel, id_local(r.tab_id), r.history, RELAY_SNAP_MAX))
	if autotest_active do fmt.printfln("[autotest] machine %s: terminal %d attaching (channel %d)", machine_name(r.machine), id_local(r.tab_id), r.channel)
}

// Ends r's stream there (it misbehaved): attached again RELAY_RETRY later.
@(private = "file")
relay_restart :: proc(r: ^Term_Relay, why: string) {
	log_fln("Deckhand: machine %s's terminal %d: %s (attached again in %v)", machine_name(r.machine), id_local(r.tab_id), why, RELAY_RETRY)
	if r.remote != 0 do machine_link_send_text(r.machine, fmt.tprintf(`{{"v":%d,"type":"term.detach","channel":%d}}`, PROTOCOL_VERSION, r.remote))
	r.remote, r.asking = 0, false
	r.retry_at = time.tick_add(time.tick_now(), RELAY_RETRY)
}

// The window's term.detach: true when channel was a relay's.
machine_term_detach :: proc(channel: u32) -> bool {
	r, i := relay_of(channel)
	if r == nil do return false
	if r.remote != 0 do machine_link_send_text(r.machine, fmt.tprintf(`{{"v":%d,"type":"term.detach","channel":%d}}`, PROTOCOL_VERSION, r.remote))
	relay_free(i)
	return true
}

// The window's term.resize of another machine's tab (checked by term_stream_message): there.
machine_term_resize :: proc(tab_id: u64, cols, rows: u64, cell_w, cell_h: f32) {
	no := id_machine(tab_id)
	if autotest_active do fmt.printfln("[autotest] machine %s: terminal %d resize %dx%d", machine_name(no), id_local(tab_id), cols, rows)
	if !machine_link_up(no) do return
	machine_link_send_text(no, fmt.tprintf(`{{"v":%d,"type":"term.resize","tab_id":%d,"cols":%d,"rows":%d,"cell_w":%v,"cell_h":%v}}`, PROTOCOL_VERSION, id_local(tab_id), cols, rows, cell_w, cell_h))
}

// The window's frame on a relay's channel: there. False: not a relay's.
machine_term_from_window :: proc(f: cw.Frame) -> bool {
	r, _ := relay_of(f.channel)
	if r == nil do return false
	#partial switch cw.Kind(f.kind) {
	case .Credit:
		if len(f.payload) >= 4 {
			n, _ := endian.get_u32(f.payload[:4], .Little)
			r.in_flight = max(r.in_flight - int(n), 0)
		}
		if r.remote != 0 do machine_link_send_frame(r.machine, r.remote, .Credit, f.payload)
	case .Data, .Focus:
		if r.remote != 0 do machine_link_send_frame(r.machine, r.remote, cw.Kind(f.kind), f.payload)
	}
	return true
}

// A frame on a terminal channel from machine no's core: to the window, checked.
machine_term_frame :: proc(no: u64, f: cw.Frame) {
	r: ^Term_Relay
	i := -1
	for x, k in route.relays do if x.machine == no && x.remote != 0 && x.remote == f.channel {
		r, i = x, k
		break
	}
	if r == nil do return // detached, or not one of ours
	#partial switch cw.Kind(f.kind) {
	case .Data:
		if r.in_flight + len(f.payload) > RELAY_IN_FLIGHT_MAX {
			relay_restart(r, "more output than the window took")
			return
		}
		r.in_flight += len(f.payload)
		window_link_send_frame(r.channel, .Data, f.payload)
	case .Snapshot:
		// only the VT replay we asked for: never a GHOSTSNP (libghostty's decoder, no MAC from
		// another machine) or anything else
		if len(f.payload) > RELAY_SNAP_MAX {
			relay_restart(r, "a snapshot past its limit")
			return
		}
		if meta, _, err := snapshot_unpack(f.payload); err != .None || meta.format != SNAPSHOT_VT {
			relay_restart(r, "a snapshot that is not the VT replay")
			return
		}
		now := time.tick_now()
		if r.snaps_at == {} || time.tick_diff(r.snaps_at, now) >= time.Second do r.snaps, r.snaps_at = 0, now
		r.snaps += 1
		if r.snaps > RELAY_SNAPS_PER_SEC {
			relay_restart(r, "too many snapshots")
			return
		}
		window_link_send_frame(r.channel, .Snapshot, f.payload)
	case .Resize:
		rz: struct {
			offset:         u64,
			cols, rows:     i64,
			xpixel, ypixel: i64,
		}
		if len(f.payload) > 512 || jg.unmarshal(f.payload, &rz, .JSON, context.temp_allocator) != nil || !hw.size_ok(rz.cols, rz.rows, rz.xpixel, rz.ypixel) || rz.cols < 2 || rz.rows < 2 {
			relay_restart(r, "a resize outside the limits")
			return
		}
		window_link_send_frame(r.channel, .Resize, f.payload)
	case .Close: // its terminal went
		window_link_send_frame(r.channel, .Close, nil)
		relay_free(i)
	}
}

// term.attached or term.scroll from machine no's core.
machine_term_json :: proc(no: u64, type: string, text: string) {
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if err != nil do return
	obj, ok := v.(json.Object)
	if !ok do return
	switch type {
	case "term.attached":
		id := string(obj["id"].(json.String) or_else "")
		n, nok := strconv.parse_u64(strings.trim_prefix(id, "r"))
		if !nok || !strings.has_prefix(id, "r") do return
		r, i := relay_of(u32(n))
		if r == nil || r.machine != no || !r.asking do return
		r.asking = false
		ch, cok := obj["channel"].(json.Integer)
		if _, bad := obj["error"]; bad || !cok || ch <= 0 || ch > i64(max(u32)) {
			window_link_send_frame(r.channel, .Close, nil) // no such terminal there (any more)
			relay_free(i)
			return
		}
		for x in route.relays do if x != r && x.machine == no && x.remote == u32(ch) { 	// a channel it gave twice
			relay_restart(r, "a channel it gave twice")
			return
		}
		r.remote = u32(ch)
		if autotest_active do fmt.printfln("[autotest] machine %s: terminal %d attached (channel %d there)", machine_name(no), id_local(r.tab_id), ch)
	case "term.scroll":
		ch, cok := obj["channel"].(json.Integer)
		if !cok do return
		for r in route.relays do if r.machine == no && r.remote != 0 && i64(r.remote) == ch {
			window_link_send_text(fmt.tprintf(`{{"v":%d,"type":"term.scroll","channel":%d}}`, PROTOCOL_VERSION, r.channel))
		}
	}
}

// The window went: its relays end there.
machine_relays_window_gone :: proc() {
	for len(route.relays) > 0 {
		r := route.relays[len(route.relays) - 1]
		if r.remote != 0 do machine_link_send_text(r.machine, fmt.tprintf(`{{"v":%d,"type":"term.detach","channel":%d}}`, PROTOCOL_VERSION, r.remote))
		relay_free(len(route.relays) - 1)
	}
}

// ---- the link's life (machines.odin) ----

// Machine no's link is up: its terminals attach again (each from a fresh snapshot).
machine_route_up :: proc(no: u64) {
	for r in route.relays do if r.machine == no do relay_attach(r)
}

// Machine no's link went down: what waited for it ends (machine_offline), its confirmations asked
// here go; its terminals' window channels stay, to attach again when it is up. gone: the machine
// itself went (removed, Machines over SSH off): its terminals close too.
machine_route_down :: proc(no: u64, gone := false) {
	for i := len(route.forwards) - 1; i >= 0; i -= 1 do if route.forwards[i].machine == no do forward_finish(i, machine_offline(no))
	for i := len(route.proxies) - 1; i >= 0; i -= 1 do if route.proxies[i].machine == no do proxy_drop(i)
	for i := len(route.relays) - 1; i >= 0; i -= 1 {
		r := route.relays[i]
		if r.machine != no do continue
		r.remote, r.asking, r.retry_at = 0, false, {}
		if gone {
			window_link_send_frame(r.channel, .Close, nil)
			relay_free(i)
		}
	}
}

// The core loop's turn (machines_tick): commands with no answer in time end; misbehaving streams
// attach again.
machine_route_tick :: proc(now: time.Tick) {
	for i := len(route.forwards) - 1; i >= 0; i -= 1 {
		f := route.forwards[i]
		if time.tick_diff(f.sent, now) > f.wait do forward_finish(i, fail(fmt.tprintf("%s did not answer in time", machine_name(f.machine))))
	}
	for r in route.relays do if r.retry_at != {} && time.tick_diff(r.retry_at, now) >= 0 {
		r.retry_at = {}
		relay_attach(r)
	}
}
