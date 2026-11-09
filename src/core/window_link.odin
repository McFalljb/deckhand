package core

// The window's connection to its core (docs/plans/background-core.md §10.2, M3-F; §5.8): the
// in-memory transport (src/corewire) carrying the framed wire's JSON channel, in process. M4
// carries the same messages over core.sock.
//
// The `ui` caller has one door, this one: core_attach_window(), which no socket line, token or
// `--ctl` path reaches (socket.odin never mints a ui or internal token, and its request parser
// has no state.subscribe). What only the window may do rides on it:
//   - its commands run as `ui`, parsed with parse_command_ui (the UI-only fields: Close_Session.ask,
//     Focus_Session.reopen, Set_Home_Dir.setup), so it confirms for agents and replays Claude's flags;
//   - state.subscribe: the state stream (state_wire.odin) carries what get_state keeps from agents
//     (confirmation tokens, transcript paths, account folders);
//   - window.command: the few internal commands the window reports (an app's status, a comment,
//     the keyboard taken or let go, a git HEAD read, the OS appearance...), from a closed list.
//
// Window -> core (each a JSON object, "v":1):
//   {"type":"state.subscribe"}                      the core answers with state.full, then deltas
//   {"type":"command","id":"7","command":{...},"menu":"…","now":true}
//       a ui command (command_wire_json). id "": no reply. now: run at once (as a direct call
//       did), else queued in the inbox (as ui_do / ui_run did). menu: a menu row's label
//       (menu_result shows its outcome).
//   {"type":"window.command","id":"8","now":true,"command":{"focus_take":{"widget":"…"}}}
//       one of WINDOW_COMMANDS, encoded by its fields (state_wire.odin's encoding), run as internal
//   finished, tab_host.event: the tab host's (tabhost_route.odin)
//   {"type":"window.reply","id":"q3","reply":{...}}  the answer to a window.request that asked for one
//   {"type":"window.facts","facts":{...}}             what only the window knows (Window_Facts)
//   {"type":"window.tab_facts","tab_id":T,"facts":{...}|null}   ...of one tab (Tab_Facts)
// Core -> window:
//   state.full / state.delta (state_wire.odin)
//   {"type":"result","id":"7","request_id":N,"result":{...}}   the socket's reply (reply_json)
//   {"type":"toast","text":"…","err":false}
//   {"type":"window.request","id":"q3","request":{"op":"open_url",...}}   id "": no reply wanted
//   {"type":"confirmation.parked","summary":"…","by_user":true}   one waits in the confirmation bar
//   tab_host.call: a browser, app, Markdown or editor command for the window's part (tabhost_route.odin)
// The window's messages are read with a decode budget far below state's (wire_read_budget_window),
// and at most WINDOW_COMMANDS_PER_PUMP of its commands run per pump.
// Terminal streams (channels ≥ 1, term.* messages): term_stream.odin.
//
// Order (design Q9): a command's state.delta is sent before its result, so the window, which waits
// for its own result, has the new state when it reads it. In process the wait is nil: the window
// sends, then calls window_link_pump (and inbox_drain for a queued one), and the core's frames are
// read at once (on_frames).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:time"
import cw "../corewire"
import jg "../jsonguard"

// The internal commands the window may send (window.command), run with the internal caller.
// Nothing else is decoded from window.command; a socket never sees this list.
// (A tab's page, app and workers report as tab_host.event instead: TAB_HOST_COMMANDS, tabhost_route.odin.)
WINDOW_COMMANDS := [?]typeid {
	Comment_Add, // a comment the user made on a page or an app (ui_comments.odin, browser_annotate.odin)
	Focus_Take, // a window widget took the keyboard (sheets, browser fields)
	Focus_Release, // ...and let it go
	Git_Head_Done, // an editor's git HEAD read (editor_git.odin's worker)
	System_Appearance, // the OS switched light or dark
	Notifications_Mark_Read, // the window came to the front: the session on screen is seen
	Set_Unread, // ...and its tabs' finished marks
}

// What a frame from the core is (window_msg_parse).
Window_Msg_Kind :: enum u8 {
	Unknown, // a newer core's: ignored
	State, // state.full or state.delta: replica_apply takes the text
	Result,
	Toast,
	Tab_Host_Call, // tab_host_call_parse takes the text (tabhost_route.odin)
	Term, // term.attached, term.scroll: the window's terminal streams take the text (term_view.odin)
	Window_Request, // window_request_parse takes the text
	Confirmation_Parked, // text (its summary), by_user (err)
}

Window_Msg :: struct {
	kind:   Window_Msg_Kind,
	id:     string, // Result: the command's id
	result: Result, // Result (temp allocator)
	text:   string, // Toast; Confirmation_Parked: its summary
	err:    bool, // Toast; Confirmation_Parked: only the user can confirm it
}

Window_Link :: struct {
	t:          ^cw.Mem_Transport, // heap: a window closed for overflowing keeps its end (link_close_overflowed)
	core_end:   cw.Mem_End,
	win_end:    cw.Mem_End,
	on_frames:  proc(), // in process: the window reads what the core just sent
	on_drain:   proc(), // in process: a top-level inbox drain starts (the window frees what its replica retired)
	subscribed: bool,
	sent:       State_Sent, // what the window's replica holds
	dirty:      bool, // window_state_changed since the last delta
	replies:    [dynamic]^Link_Reply, // queued commands' replies, freed once delivered
	pumping:    int,
	need_full:  bool, // a state message was refused: the next flush sends state.full
	too_large_said: bool,
	too_large:  bool, // the last state.full was over the frame limit, at State.version too_large_version
	too_large_version: u64,
	full_builds: int, // state.full texts built (tests)
	untracked:  [dynamic]string, // test mode: writes no trigger announced (window_link_check; heap)
	// what the window sent while the core sent it a terminal's frames (link_send reads its CREDITs
	// at once, in process): the rest waits here, in order, for the next pump. Capped as the
	// transport is (cw.Backlog): past it the window is closed (overflowed)
	backlog:    cw.Backlog,
	overflowed: bool, // the backlog was full: the link closes at the next pump or flush (not mid-stream)
	// what the window last reported (window.facts, window.tab_facts; heap): has_facts false until
	// it first did
	facts:      Window_Facts,
	has_facts:  bool,
	tab_facts:  map[u64]Tab_Facts,
	next_ask:   u64,
	asking:     [dynamic]Link_Ask, // requests waiting for their reply (nested: one inside another's answer)
}

@(private = "file")
Link_Ask :: struct {
	id:    string, // temp
	got:   bool,
	reply: Window_Reply, // temp allocator
}

@(private = "file")
Link_Reply :: struct {
	using reply: Reply,
	id:          string, // heap
	delivered:   bool,
}

@(private = "file")
link: ^Window_Link

// The window is attached (in process).
window_attached :: proc() -> bool {return link != nil}

// Attaches the window: the only way to get the ui caller (main.odin's client, at init). Returns
// the window's end of the transport. on_frames is called after the core sends it anything.
// Main thread.
core_attach_window :: proc(on_frames: proc(), on_drain: proc() = nil) -> (end: cw.Mem_End, ok: bool) {
	if link != nil {
		fmt.eprintln("Deckhand: a second window may not attach while one is attached")
		return {}, false // one window at a time, in a release build too
	}
	heap := runtime.heap_allocator()
	link = new(Window_Link, heap)
	link.t = new(cw.Mem_Transport, heap)
	link.core_end, link.win_end = cw.mem_open(link.t, allocator = heap)
	link.on_frames = on_frames
	link.on_drain = on_drain
	link.replies = make([dynamic]^Link_Reply, heap)
	link.untracked = make([dynamic]string, heap)
	cw.backlog_init(&link.backlog, allocator = heap)
	link.sent.sections = make(map[string]string, heap)
	link.tab_facts = make(map[u64]Tab_Facts, heap)
	link.asking = make([dynamic]Link_Ask, heap)
	return link.win_end, true
}

// Replies of a window that went while the inbox still held them (core_detach_window): they live
// until the inbox answered (delivered), then go at the next pump. Main thread.
@(private = "file")
link_orphans: [dynamic]^Link_Reply

@(private = "file")
link_orphan_deliver :: proc(r: ^Reply, request_id: u64) {(^Link_Reply)(r).delivered = true}

@(private = "file")
link_orphans_free :: proc() {
	heap := runtime.heap_allocator()
	keep := 0
	for r in link_orphans {
		if r.delivered {
			result_free(r.result)
			delete(r.id, heap)
			free(r, heap)
			continue
		}
		link_orphans[keep] = r
		keep += 1
	}
	resize(&link_orphans, keep)
}

window_link_orphans_for_test :: proc() -> int {return len(link_orphans)}

// The window went (tests; M3-G's detach). Main thread. keep_transport: the window still holds its
// end (link_close_overflowed): the transport is closed, not freed, so its sends fail instead.
core_detach_window :: proc(keep_transport := false) {
	if link == nil do return
	heap := runtime.heap_allocator()
	term_streams_window_gone() // its terminal streams end (term_stream.odin)
	link_free_replies() // the delivered ones; the inbox may still hold the others
	if len(link.replies) > 0 && link_orphans == nil do link_orphans = make([dynamic]^Link_Reply, heap)
	for r in link.replies {
		r.deliver = link_orphan_deliver
		append(&link_orphans, r)
	}
	delete(link.replies)
	for u in link.untracked do delete(u, heap)
	delete(link.untracked)
	cw.backlog_destroy(&link.backlog)
	link_facts_free()
	delete(link.asking)
	state_sent_free(&link.sent)
	cw.mem_close(link.core_end)
	if !keep_transport {
		cw.mem_destroy(link.t)
		free(link.t, heap)
	}
	free(link, heap)
	link = nil
	tab_host_detached() // what the window owed ends: no_window (tabhost_route.odin)
}

// A top-level inbox drain starts (inbox_drain): the window's hook, if it set one.
window_link_drain_starts :: proc() {if link != nil && link.on_drain != nil do link.on_drain()}

// Something the window shows changed (window_state_changed): the next flush looks.
window_link_dirty :: proc() {if link != nil do link.dirty = true}

// A short line at the bottom of the window. False: no window attached.
window_link_toast :: proc(text: string, err: bool) -> bool {
	if link == nil do return false
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"toast","text":`, PROTOCOL_VERSION)
	json_quote(&b, text)
	fmt.sbprintf(&b, `,"err":%v}}`, err)
	link_send(strings.to_string(b))
	return true
}

// The state delta, if anything changed since the window's replica was sent: a command bumped
// State.version, or window_state_changed was called. Main thread; at every inbox_drain's end
// and before each of the window's results. sweep: compare every section whatever the triggers
// said (before each of the window's results, after a drain that ran a ui command, and a few
// times a second from the window's frames), so the replica never stays behind a write that
// signalled nothing. Test mode records each such write (link.untracked), and
// window_link_check fails the scene on one that UNTRACKED_OK does not list.
window_link_flush :: proc(sweep := false) {
	if link != nil && link.overflowed do link_close_overflowed()
	if link == nil || !link.subscribed do return
	tab_term_facts_tick(time.tick_now()) // a terminal made or gone this tick goes with this delta
	link_free_replies()
	// an over-limit state.full is built again only once State changed (not on every frame's sweep)
	if link.need_full && link.too_large && !link.dirty && state.version == link.too_large_version do return
	triggered := link.dirty || link.sent.version != state.version
	if !triggered && !sweep && !link.need_full do return
	when TEST_HOOKS {
		if !triggered do link_note_untracked()
	}
	link.dirty = false
	if link.need_full {
		link.full_builds += 1
		link_send_state(state_full_json(&state, &link.sent))
		return
	}
	text, ok := state_delta_json(&state, &link.sent)
	if !ok do return
	link_send_state(text)
}

// Sends a state message. A refused one (too large, or the link failed) leaves the replica behind
// what link.sent says it holds, so the next flush sends state.full instead. A state.full over the
// frame limit is not retried until State changes: it is said once, and the window keeps the last
// state it got (test mode: the check fails).
@(private = "file")
link_send_state :: proc(text: string) {
	if len(text) > link_max_payload {
		if !link.too_large_said {
			fmt.eprintfln("Deckhand: the window's state message is %d bytes, over the link's %d: the window keeps the state it has until State shrinks", len(text), link_max_payload)
			link.too_large_said = true
		}
		link.need_full = true
		link.too_large, link.too_large_version = true, state.version
		when TEST_HOOKS do if len(link.untracked) < 64 do append(&link.untracked, strings.clone("<state over the frame limit>", runtime.heap_allocator()))
		return
	}
	link.too_large = false
	if !link_send(text) {
		link.need_full = true
		return
	}
	link.need_full, link.too_large_said = false, false
}

// The largest state message the link sends (tests lower it).
link_max_payload := cw.MAX_PAYLOAD

// ---- test mode: writes to State that no trigger announced ----

// Writes the core makes outside commands with no version bump and no window_state_changed,
// that the check lets through: each a path (section with "*" for ids, "[*]" for list positions)
// and the site that makes it. This list is meant to shrink: give such a write a trigger instead.
// The check is best-effort: triggers are not per section, so an untracked write that shares a
// flush with any trigger is sent along with it and not flagged (per-section triggers: a follow-up).
UNTRACKED_OK := [?]struct {
	path, site: string,
}{}

// Each section that differs from what the window was sent, as the first differing path in it
// ("tabs:*[*].reload.started"), recorded in link.untracked.
@(private = "file")
link_note_untracked :: proc() {
	heap := runtime.heap_allocator()
	secs := state_sections(&state)
	now := make(map[string]bool, len(secs), context.temp_allocator)
	for x in secs {
		now[x[0]] = true
		old, had := link.sent.sections[x[0]]
		if had && old == x[1] do continue
		path := had ? json_diff_path(old, x[1]) : " (new)"
		if len(link.untracked) < 64 do append(&link.untracked, strings.concatenate({section_pattern(x[0]), path}, heap))
	}
	for k in link.sent.sections do if !now[k] && len(link.untracked) < 64 do append(&link.untracked, strings.concatenate({section_pattern(k), " (gone)"}, heap))
}

// "tabs:12" -> "tabs:*"
@(private = "file")
section_pattern :: proc(name: string) -> string {
	if c := strings.index_byte(name, ':'); c >= 0 do return strings.concatenate({name[:c + 1], "*"}, context.temp_allocator)
	return name
}

// The first path where two JSON texts differ: ".a.b", "[*].c", "" if equal (temp allocator).
json_diff_path :: proc(a, b: string) -> string {
	va, ea := jg.parse_string(a, .JSON, true, context.temp_allocator)
	vb, eb := jg.parse_string(b, .JSON, true, context.temp_allocator)
	if ea != nil || eb != nil do return " (unparsed)"
	return json_value_diff(va, vb, "")
}

@(private = "file")
json_value_diff :: proc(a, b: json.Value, path: string) -> string {
	#partial switch x in a {
	case json.Object:
		y, ok := b.(json.Object)
		if !ok do return path
		for k, v in x {
			w, has := y[k]
			if !has do return strings.concatenate({path, ".", k}, context.temp_allocator)
			if d := json_value_diff(v, w, strings.concatenate({path, ".", k}, context.temp_allocator)); d != "" do return d
		}
		for k in y do if k not_in x do return strings.concatenate({path, ".", k}, context.temp_allocator)
		return ""
	case json.Array:
		y, ok := b.(json.Array)
		if !ok do return path
		if len(x) != len(y) do return strings.concatenate({path, "[#]"}, context.temp_allocator)
		for i in 0 ..< len(x) do if d := json_value_diff(x[i], y[i], strings.concatenate({path, "[*]"}, context.temp_allocator)); d != "" do return d
		return ""
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y ? "" : path
	case json.Integer:
		y, ok := b.(json.Integer)
		return ok && x == y ? "" : path
	case json.Float:
		y, ok := b.(json.Float)
		return ok && x == y ? "" : path
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y ? "" : path
	case json.Null:
		_, ok := b.(json.Null)
		return ok ? "" : path
	}
	return path
}

// Test mode, after every script step (autotest.odin through client.odin): "" or why the scene
// fails. First a flush that only the triggers drive: what still differs from what the window was
// sent is a write that signalled nothing, as are those the sweeps since the last check recorded;
// each fails unless UNTRACKED_OK lists it. Then a sweep, and the replica must equal State: a
// difference left is a write by the window into its replica (one that bypassed commands), and
// the window gets the whole state again.
window_link_check :: proc(replica: ^State) -> string {
	if link == nil || !link.subscribed do return ""
	window_link_flush()
	when TEST_HOOKS do link_note_untracked()
	b := strings.builder_make(context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for u in link.untracked {
		if seen[u] || untracked_ok(u) do continue
		seen[u] = true
		if len(seen) == 1 do strings.write_string(&b, "a write to State with no version bump and no window_state_changed (give it a trigger, or list it in UNTRACKED_OK): ")
		else do strings.write_string(&b, ", ")
		strings.write_string(&b, u)
	}
	for u in link.untracked do delete(u, runtime.heap_allocator())
	clear(&link.untracked)
	window_link_flush(sweep = true)
	clear(&link.untracked) // what that sweep found is in the report already
	if d := window_link_diverged(replica); d != "" {
		if len(seen) > 0 do strings.write_string(&b, "; ")
		strings.write_string(&b, "the window's replica differs from State (a write that bypassed commands): ")
		strings.write_string(&b, d)
		window_link_resync()
	}
	return strings.to_string(b)
}

@(private = "file")
untracked_ok :: proc(u: string) -> bool {
	for ok in UNTRACKED_OK do if u == ok.path do return true
	return false
}

// The most of the window's commands (command, window.command, tab_host.event) one pump takes: the
// rest wait in the transport for the next (inbox_drain pumps once a tick when one stops here), so
// a burst cannot hold the core loop.
WINDOW_COMMANDS_PER_PUMP := 512

// Reads the frames the window sent and acts on them: a queued command goes into the inbox (it
// runs at the next inbox_drain, in order), a "now" one runs here. capped: it stopped after
// WINDOW_COMMANDS_PER_PUMP commands, and more may wait. Main thread.
window_link_pump :: proc() -> (capped: bool) {
	if len(link_orphans) > 0 do link_orphans_free()
	if link != nil && link.overflowed do link_close_overflowed()
	if link == nil do return
	link.pumping += 1
	defer if link != nil do link.pumping -= 1
	ran := 0
	for link != nil {
		if ran >= WINDOW_COMMANDS_PER_PUMP do return true
		f: cw.Frame
		if bf, ok := cw.backlog_pop(&link.backlog); ok { // read early by link_send: before anything still in the transport
			f = bf
			f.payload = make([]u8, len(bf.payload), context.temp_allocator)
			copy(f.payload, bf.payload)
			delete(bf.payload, runtime.heap_allocator())
		} else {
			err: cw.Recv_Error
			f, err = cw.mem_recv(link.core_end, context.temp_allocator)
			if err != .None do break
		}
		if f.channel != cw.JSON_CHANNEL {
			term_stream_frame(f) // a terminal stream's input, credit or focus (term_stream.odin)
			continue
		}
		if f.kind != u8(cw.Kind.Data) do continue
		if link_message(string(f.payload)) do ran += 1
	}
	return false
}

// A JSON message for the window (term_stream.odin). False: no window.
window_link_send_text :: proc(text: string) -> bool {
	if link == nil do return false
	link_send(text)
	return true
}

// A frame on a terminal channel (term_stream.odin). In process the window takes it at once; the
// CREDIT it sends back is read here, so the stream can go on in the same tick.
window_link_send_frame :: proc(channel: u32, kind: cw.Kind, payload: []u8) -> cw.Send_Error {
	if link == nil || link.overflowed do return .Closed
	if e := cw.mem_send(link.core_end, channel, kind, payload); e != .None do return e
	if link.on_frames != nil do link.on_frames()
	link_take_credits()
	return .None
}

// Everything the window has sent: its CREDITs count now, the rest waits in the backlog, in order.
@(private = "file")
link_take_credits :: proc() {
	heap := runtime.heap_allocator()
	for link != nil {
		f, err := cw.mem_recv(link.core_end, heap)
		if err != .None do return
		if f.channel != cw.JSON_CHANNEL && f.kind == u8(cw.Kind.Credit) && len(link.backlog.frames) == 0 {
			term_stream_frame(f)
			delete(f.payload, heap)
			continue
		}
		if !cw.backlog_push(&link.backlog, f) { // over its cap (the payload is freed): the window goes
			link.overflowed = true
			return
		}
	}
}

// The window sent more than the backlog holds (link_take_credits): it is closed, as the socket
// transport closes a peer past its cap. Called where nothing iterates the streams (pump, flush).
@(private = "file")
link_close_overflowed :: proc() {
	fmt.eprintln("Deckhand: the window sent more than its link holds: it is closed")
	core_detach_window(keep_transport = true) // in process the window keeps its end: its sends now fail (a few KiB kept)
}

// Whether the replica equals the core's State (test mode, after every script step, autotest.odin):
// "" or which sections differ. Run window_link_flush(sweep = true) first: a section that still
// differs is a write by the window into its replica (one that bypassed commands), or a section
// the replica decodes differently from how the core encodes it.
window_link_diverged :: proc(replica: ^State) -> string {
	if link == nil || !link.subscribed do return ""
	mine := state_sections(&state)
	theirs := state_sections(replica)
	b := strings.builder_make(context.temp_allocator)
	n := 0
	note :: proc(b: ^strings.Builder, n: ^int, name, a, c: string) {
		if n^ >= 4 do return
		if n^ > 0 do strings.write_string(b, "; ")
		n^ += 1
		at := 0
		for at < len(a) && at < len(c) && a[at] == c[at] do at += 1
		from := max(at - 40, 0)
		fmt.sbprintf(b, "%s: core %q, window %q", name, a[from:min(at + 60, len(a))], c[from:min(at + 60, len(c))])
	}
	seen := make(map[string]bool, context.temp_allocator)
	for x in theirs do seen[x[0]] = true
	for x in mine {
		found := false
		for y in theirs do if y[0] == x[0] {
			found = true
			if y[1] != x[1] do note(&b, &n, x[0], x[1], y[1])
		}
		if !found do note(&b, &n, x[0], x[1], "<missing>")
		delete_key(&seen, x[0])
	}
	for k in seen do note(&b, &n, k, "<missing>", "…")
	if n == 0 do return ""
	return strings.to_string(b)
}

// Sends the window a fresh state.full (after a divergence, so one failure does not repeat).
window_link_resync :: proc() {
	if link == nil || !link.subscribed do return
	link_send_state(state_full_json(&state, &link.sent))
}

// ---- the window's side of the encoding (client.odin calls these; the window has no codec) ----

// A ui command as the window sends it. id "": no reply.
window_msg_command :: proc(cmd: Command, id: string, now := false, menu := "") -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"command","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	if now do strings.write_string(&b, `,"now":true`)
	if menu != "" {
		strings.write_string(&b, `,"menu":`)
		json_quote(&b, menu)
	}
	strings.write_string(&b, `,"command":`)
	strings.write_string(&b, command_wire_json(cmd))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// One of WINDOW_COMMANDS as the window sends it; ok false: not one of them.
window_msg_internal :: proc(cmd: Command, id: string, now := false) -> (text: string, ok: bool) {
	vt := reflect.union_variant_typeid(cmd)
	if !window_command_ok(vt) do return "", false
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"window.command","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	if now do strings.write_string(&b, `,"now":true`)
	strings.write_string(&b, `,"command":{`)
	c := cmd
	ti := type_info_of(vt)
	wire_write_lower(&b, wire_variant_name(ti))
	strings.write_byte(&b, ':')
	wire_write(&b, &c, ti) // a union's variant sits at its start
	strings.write_string(&b, "}}")
	return strings.to_string(b), true
}

// What only the window knows, as it sends it (client.odin, whenever it changed).
window_msg_facts :: proc(f: ^Window_Facts) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"window.facts","facts":`, PROTOCOL_VERSION)
	wire_write(&b, f, type_info_of(Window_Facts))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// ...of one tab (nil: it has none any more).
window_msg_tab_facts :: proc(tab_id: u64, f: ^Tab_Facts) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"window.tab_facts","tab_id":%d,"facts":`, PROTOCOL_VERSION, tab_id)
	if f == nil do strings.write_string(&b, "null")
	else do wire_write(&b, f, type_info_of(Tab_Facts))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// The window's answer to a window.request.
window_msg_reply :: proc(id: string, r: ^Window_Reply) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"window.reply","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	strings.write_string(&b, `,"reply":`)
	wire_write(&b, r, type_info_of(Window_Reply))
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// A window.request, for the window (temp allocator). id "": it wants no reply.
window_request_parse :: proc(text: string) -> (id: string, r: Window_Request, err: string) {
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return "", {}, "invalid JSON"
	obj, ok := v.(json.Object)
	if !ok do return "", {}, "not an object"
	id = string(obj["id"].(json.String) or_else "")
	wire_read_budget(text) // from the core: the window trusts it
	if e := wire_read(obj["request"], &r, type_info_of(Window_Request), context.temp_allocator); e != "" do return id, {}, fmt.tprintf("window.request%s", e)
	return id, r, ""
}

window_msg_subscribe :: proc() -> string {
	return fmt.tprintf(`{{"v":%d,"type":"state.subscribe"}}`, PROTOCOL_VERSION)
}

// A frame from the core, for the window (temp allocator).
window_msg_parse :: proc(text: string) -> (m: Window_Msg, err: string) {
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return {}, "invalid JSON"
	obj, ok := v.(json.Object)
	if !ok do return {}, "not an object"
	type, _ := obj["type"].(json.String)
	switch type {
	case STATE_FULL, STATE_DELTA:
		m.kind = .State
	case "term.attached", "term.scroll":
		m.kind = .Term
	case "result":
		m.kind = .Result
		m.id, _ = obj["id"].(json.String)
		ro, rok := obj["result"].(json.Object)
		if !rok do return m, "result: missing result"
		m.result.ok = bool(ro["ok"].(json.Boolean) or_else false)
		m.result.error = string(ro["error"].(json.String) or_else "")
		m.result.pending = bool(ro["pending"].(json.Boolean) or_else false)
		if n, is := ro["created_id"].(json.Integer); is && n >= 0 do m.result.created_id = u64(n)
		if nc, is := ro["needs_confirmation"].(json.Object); is {
			m.result.confirm_token = string(nc["token"].(json.String) or_else "")
			m.result.confirm_summary = string(nc["summary"].(json.String) or_else "")
			m.result.confirm_by_user = string(nc["by"].(json.String) or_else "") == "user"
		}
		if _, has := ro["data"]; has {
			// the data as the core wrote it (raw JSON), not re-marshalled
			members, mok := json_members_raw(strings.trim_space(text))
			if mok do for mm in members do if mm.key == "result" {
				inner, iok := json_members_raw(mm.raw)
				if iok do for im in inner do if im.key == "data" do m.result.data = im.raw
			}
		}
	case "tab_host.call":
		m.kind = .Tab_Host_Call
	case "toast":
		m.kind = .Toast
		m.text = string(obj["text"].(json.String) or_else "")
		m.err = bool(obj["err"].(json.Boolean) or_else false)
	case "window.request":
		m.kind = .Window_Request
	case "confirmation.parked":
		m.kind = .Confirmation_Parked
		m.text = string(obj["summary"].(json.String) or_else "")
		m.err = bool(obj["by_user"].(json.Boolean) or_else false)
	}
	return m, ""
}

// ---- the core's side ----

@(private = "file")
window_command_ok :: proc(id: typeid) -> bool {
	for w in WINDOW_COMMANDS do if w == id do return true
	return false
}

// Asks the window (window_hooks.odin's wrappers). want_reply: its window.reply, which in process
// comes while the request is sent (the pump reads it). answered false: no window, the link refused
// it, or no reply came (M4 over core.sock: the core never waits for one; a late reply is dropped).
// Main thread.
window_link_request :: proc(r: Window_Request, want_reply: bool) -> (reply: Window_Reply, answered: bool) {
	if link == nil do return
	id := ""
	if want_reply {
		link.next_ask += 1
		id = fmt.tprintf("q%d", link.next_ask)
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"window.request","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	strings.write_string(&b, `,"request":`)
	req := r
	wire_write(&b, &req, type_info_of(Window_Request))
	strings.write_byte(&b, '}')
	if !want_reply do return {}, link_send(strings.to_string(b))
	append(&link.asking, Link_Ask{id = id})
	at := len(link.asking) - 1
	sent := link_send(strings.to_string(b))
	// in process the window answered while it was sent: pump past the per-pump cap until its reply
	if sent do for window_link_pump() && link != nil && !link.asking[at].got {}
	if link == nil do return // it went meanwhile
	a := link.asking[at]
	resize(&link.asking, at)
	return a.reply, sent && a.got
}

// A window.reply: for the request waiting on it, else dropped.
@(private = "file")
link_reply_in :: proc(obj: json.Object) {
	id := string(obj["id"].(json.String) or_else "")
	for &a in link.asking do if a.id == id && !a.got {
		if e := wire_read(obj["reply"], &a.reply, type_info_of(Window_Reply), context.temp_allocator); e != "" {
			fmt.eprintln("Deckhand: a window.reply refused:", e)
			a.reply = {}
		}
		a.got = true
		return
	}
}

// What the window last reported (nil: no window, or it has not said yet).
window_facts :: proc() -> ^Window_Facts {
	if link == nil || !link.has_facts do return nil
	return &link.facts
}

// ...of one tab (nil: nothing, or no window).
window_tab_facts :: proc(tab_id: u64) -> ^Tab_Facts {
	if link == nil do return nil
	return &link.tab_facts[tab_id] or_else nil
}

// The tab closed (drop_term): what the window said of it goes.
window_tab_facts_drop :: proc(tab_id: u64) {
	hello_key_set(tab_id, "")
	if link == nil do return
	if old, had := link.tab_facts[tab_id]; had {
		o := old
		wire_free(&o, type_info_of(Tab_Facts), runtime.heap_allocator())
		delete_key(&link.tab_facts, tab_id)
	}
}

@(private = "file")
link_facts_free :: proc() {
	hello_set(nil)
	heap := runtime.heap_allocator()
	wire_free(&link.facts, type_info_of(Window_Facts), heap)
	for id in link.tab_facts {
		f := link.tab_facts[id]
		wire_free(&f, type_info_of(Tab_Facts), heap)
	}
	delete(link.tab_facts)
}

// A confirmation was parked (confirm_gate): the window hears it at once; its record comes with
// the next delta (window_state_changed).
window_confirmation_parked :: proc(summary: string, by_user: bool) {
	window_state_changed()
	if link == nil do return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"confirmation.parked","summary":`, PROTOCOL_VERSION)
	json_quote(&b, summary)
	fmt.sbprintf(&b, `,"by_user":%v}}`, by_user)
	link_send(strings.to_string(b))
}

// Sends the window a message (tabhost_route.odin's calls). False: no window attached, or the
// link refused it (closed, over its limit): the caller answers no_window at once.
window_link_send :: proc(text: string) -> bool {
	return link_send(text)
}

@(private = "file")
link_send :: proc(text: string) -> bool {
	if link == nil do return false
	if e := cw.mem_send(link.core_end, cw.JSON_CHANNEL, .Data, transmute([]u8)text); e != .None {
		// a window that does not read (in process it always does): its state starts again from a full
		fmt.eprintln("Deckhand: the window's link refused a message:", e)
		return false
	}
	if link.on_frames != nil do link.on_frames()
	return true
}

// Frees the replies the inbox has delivered (and signalled: it signals right after deliver).
@(private = "file")
link_free_replies :: proc(all := false) {
	heap := runtime.heap_allocator()
	keep := 0
	for r in link.replies {
		if r.delivered || all {
			result_free(r.result)
			delete(r.id, heap)
			free(r, heap)
			continue
		}
		link.replies[keep] = r
		keep += 1
	}
	resize(&link.replies, keep)
}

// A queued command's reply: its delta first, then the result (Q9).
// The flush before a result compares every section: a command may change State without a
// version bump (one that parks a confirmation answers "not changed").
@(private = "file")
link_deliver :: proc(r: ^Reply, request_id: u64) {
	lr := (^Link_Reply)(r)
	window_link_flush(sweep = true)
	link_send(reply_json(lr.id, r.result, request_id))
	lr.delivered = true
}

@(private = "file")
link_reply_now :: proc(id: string, r: Result, request_id: u64) {
	window_link_flush(sweep = true)
	if id != "" do link_send(reply_json(id, r, request_id))
}

// One message from the window. True: it was a command (run or queued), for the pump's cap.
@(private = "file")
link_message :: proc(text: string) -> (command: bool) {
	if !json_depth_ok(text) {
		fmt.eprintln("Deckhand: a window message nested too deeply")
		return
	}
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	wire_read_budget_window(text) // wire_read's limit for this message, a window's (state_read.odin)
	if jerr != nil || !ok {
		fmt.eprintln("Deckhand: a window message that is not a JSON object")
		return
	}
	type, _ := obj["type"].(json.String)
	id := string(obj["id"].(json.String) or_else "")
	now := bool(obj["now"].(json.Boolean) or_else false)
	switch type {
	case "state.subscribe":
		link.subscribed = true
		link.dirty = false
		link_send_state(state_full_json(&state, &link.sent))
	case "command":
		command = true
		menu := string(obj["menu"].(json.String) or_else "")
		raw := ""
		if members, mok := json_members_raw(strings.trim_space(text)); mok {
			for m in members do if m.key == "command" do raw = m.raw
		}
		cmd, err := parse_command_ui(raw, context.temp_allocator)
		if err != "" {
			link_reply_now(id, fail(err), 0)
			return
		}
		link_run(cmd, {kind = .UI}, id, now, menu)
	case "window.reply":
		link_reply_in(obj)
	case "window.facts":
		heap := runtime.heap_allocator()
		f: Window_Facts
		if e := wire_read(obj["facts"], &f, type_info_of(Window_Facts), heap); e != "" {
			wire_free(&f, type_info_of(Window_Facts), heap)
			fmt.eprintln("Deckhand: window.facts refused:", e)
			return
		}
		wire_free(&link.facts, type_info_of(Window_Facts), heap)
		link.facts, link.has_facts = f, true
		hello_set(&f)
	case "window.tab_facts":
		n, nok := obj["tab_id"].(json.Integer)
		if !nok || n <= 0 {
			fmt.eprintln("Deckhand: window.tab_facts without a tab_id")
			return
		}
		window_tab_facts_drop(u64(n))
		fv := obj["facts"]
		if _, null := fv.(json.Null); null || fv == nil do return
		heap := runtime.heap_allocator()
		f: Tab_Facts
		if e := wire_read(fv, &f, type_info_of(Tab_Facts), heap); e != "" {
			wire_free(&f, type_info_of(Tab_Facts), heap)
			fmt.eprintln("Deckhand: window.tab_facts refused:", e)
			return
		}
		link.tab_facts[u64(n)] = f
		hello_key_set(u64(n), f.frames_key)
	case "term.attach", "term.detach", "term.resize":
		term_stream_message(type, obj, id) // term_stream.odin
	case "window.command":
		command = true
		cmd, err := window_command_decode(obj["command"])
		if err != "" {
			fmt.eprintln("Deckhand: a window.command refused:", err)
			link_reply_now(id, fail(err), 0)
			return
		}
		link_run(cmd, {kind = .Internal}, id, now, "")
	case "tab_host.event":
		command = true
		// a page's, an app's or a window worker's report: the tab_host caller, never ui
		cmd, err := command_variant_read(obj["command"], TAB_HOST_COMMANDS[:])
		if err != "" {
			fmt.eprintln("Deckhand: a tab_host.event refused:", err)
			link_reply_now(id, fail(fmt.tprintf("tab_host.event: %s", err)), 0)
			return
		}
		link_run(cmd, {kind = .Tab_Host}, id, now, "")
	case "finished":
		tab_host_finished_msg(obj, text) // a call's answer, or a pending request's end (tabhost_route.odin)
	case:
		fmt.eprintln("Deckhand: an unknown window message:", type)
	}
	return
}

@(private = "file")
link_run :: proc(cmd: Command, caller: Caller, id: string, now: bool, menu: string) {
	if now {
		r, rid := inbox_run_now(cmd, caller, menu)
		link_reply_now(id, r, rid)
		return
	}
	if id == "" {
		inbox_submit(cmd, caller, menu = menu)
		return
	}
	heap := runtime.heap_allocator()
	lr := new(Link_Reply, heap)
	lr.id = strings.clone(id, heap)
	lr.deliver = link_deliver
	append(&link.replies, lr)
	inbox_submit(cmd, caller, &lr.reply, menu)
}

// window.command's {"<type, lowercased>": {fields}} into the command, only for WINDOW_COMMANDS.
@(private = "file")
window_command_decode :: proc(v: json.Value) -> (cmd: Command, err: string) {
	obj, ok := v.(json.Object)
	if !ok || len(obj) != 1 do return nil, "window.command: wants {\"<command>\": {...}}"
	for name, fields in obj {
		for id in WINDOW_COMMANDS {
			ti := type_info_of(id)
			b := strings.builder_make(context.temp_allocator)
			wire_write_lower(&b, wire_variant_name(ti))
			if strings.trim(strings.to_string(b), `"`) != name do continue
			reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, id)
			if e := wire_read(fields, &cmd, ti, context.temp_allocator); e != "" do return nil, fmt.tprintf("window.command %s%s", name, e)
			return cmd, ""
		}
		return nil, fmt.tprintf("window.command: %s is not one the window sends", name)
	}
	return nil, "window.command: empty"
}

// The command a window.command message carries (tests).
@(private)
window_command_decode_for_test :: proc(text: string) -> (Command, string) {
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return nil, "invalid JSON"
	obj, _ := v.(json.Object)
	wire_read_budget_window(text)
	return window_command_decode(obj["command"])
}

// The link itself (tests).
@(private)
window_link_for_test :: proc() -> ^Window_Link {return link}

// ---- what an app tab's hello says of the window (socket.odin's welcome_json, on a connection's
// reader thread): a copy of those facts under a lock, set on the main thread as they arrive ----

@(private = "file")
hello_mu: sync.Mutex
@(private = "file")
hello: struct {
	known:   bool, // the window reported its facts (display: fps, scale)
	service: string, // heap
	device:  u64,
	fps:     int,
	scale:   f32,
	keys:    map[u64]string, // each app tab's frame channel key, hex (heap)
}

@(private = "file")
hello_set :: proc(f: ^Window_Facts) {
	sync.guard(&hello_mu)
	heap := runtime.heap_allocator()
	delete(hello.service, heap)
	if f == nil {
		for _, k in hello.keys do delete(k, heap)
		delete(hello.keys)
		hello = {}
		return
	}
	hello.known, hello.service, hello.device, hello.fps, hello.scale = true, strings.clone(f.frames_service, heap), f.frames_device, f.fps, f.scale
}

@(private = "file")
hello_key_set :: proc(tab_id: u64, key: string) {
	sync.guard(&hello_mu)
	heap := runtime.heap_allocator()
	if old, had := hello.keys[tab_id]; had {
		delete(old, heap)
		delete_key(&hello.keys, tab_id)
	}
	if key == "" do return
	if hello.keys == nil do hello.keys = make(map[u64]string, heap)
	hello.keys[tab_id] = strings.clone(key, heap)
}

// An app tab's frame channel (service, its key and the GPU's id; key "": none) and the window's
// display (known false: no window has said). Any thread; strings in the temp allocator.
window_app_hello :: proc(tab_id: u64) -> (service, key: string, device: u64, fps: int, scale: f32, known: bool) {
	sync.guard(&hello_mu)
	key = strings.clone(hello.keys[tab_id] or_else "", context.temp_allocator)
	return strings.clone(hello.service, context.temp_allocator), key, hello.device, hello.fps, hello.scale, hello.known
}
