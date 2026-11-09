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
// Core -> window:
//   state.full / state.delta (state_wire.odin)
//   {"type":"result","id":"7","request_id":N,"result":{...}}   the socket's reply (reply_json)
//   {"type":"toast","text":"…","err":false}
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
import cw "../corewire"
import jg "../jsonguard"

// The internal commands the window may send (window.command), run with the internal caller.
// Nothing else is decoded from window.command; a socket never sees this list.
WINDOW_COMMANDS := [?]typeid {
	App_Update, // an app tab's process started or exited (app_tab.odin's frame loop)
	App_Call_Done, // an app screenshot worker's answer (app_tab.odin)
	Browser_Update, // what CEF reported: URL, title, loading (browser_nav.odin)
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
}

Window_Msg :: struct {
	kind:   Window_Msg_Kind,
	id:     string, // Result: the command's id
	result: Result, // Result (temp allocator)
	text:   string, // Toast
	err:    bool, // Toast
}

Window_Link :: struct {
	t:          cw.Mem_Transport,
	core_end:   cw.Mem_End,
	win_end:    cw.Mem_End,
	on_frames:  proc(), // in process: the window reads what the core just sent
	subscribed: bool,
	sent:       State_Sent, // what the window's replica holds
	dirty:      bool, // window_state_changed since the last delta
	replies:    [dynamic]^Link_Reply, // queued commands' replies, freed once delivered
	pumping:    int,
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
core_attach_window :: proc(on_frames: proc()) -> cw.Mem_End {
	assert(link == nil, "one window")
	heap := runtime.heap_allocator()
	link = new(Window_Link, heap)
	link.core_end, link.win_end = cw.mem_open(&link.t, allocator = heap)
	link.on_frames = on_frames
	link.replies = make([dynamic]^Link_Reply, heap)
	link.sent.sections = make(map[string]string, heap)
	return link.win_end
}

// The window went (tests; M3-G's detach). Main thread.
core_detach_window :: proc() {
	if link == nil do return
	heap := runtime.heap_allocator()
	link_sweep(all = true)
	delete(link.replies)
	state_sent_free(&link.sent)
	cw.mem_close(link.core_end)
	cw.mem_destroy(&link.t)
	free(link, heap)
	link = nil
}

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

// The state delta, if anything changed since the window's replica was sent (a command bumped
// State.version, or window_state_changed was called). Main thread; also from inbox_drain's end
// and before each of the window's results.
window_link_flush :: proc() {
	if link == nil || !link.subscribed do return
	link_sweep()
	if !link.dirty && link.sent.version == state.version do return
	link.dirty = false
	if text, ok := state_delta_json(&state, &link.sent); ok do link_send(text)
}

// Reads every frame the window sent and acts on it: a queued command goes into the inbox (it
// runs at the next inbox_drain, in order), a "now" one runs here. Main thread.
window_link_pump :: proc() {
	if link == nil do return
	link.pumping += 1
	defer link.pumping -= 1
	for {
		f, err := cw.mem_recv(link.core_end, context.temp_allocator)
		if err != .None do break
		if f.channel != cw.JSON_CHANNEL || f.kind != u8(cw.Kind.Data) do continue // M3-H: terminal streams
		link_message(string(f.payload))
	}
}

// Whether the replica equals the core's State (test mode, after every script step, autotest.odin):
// "" or which sections differ. Run window_link_flush first: a section that still differs is a
// change the stream missed (no version bump, no window_state_changed) or a write by the window.
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
	link_send(state_full_json(&state, &link.sent))
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
	case "toast":
		m.kind = .Toast
		m.text = string(obj["text"].(json.String) or_else "")
		m.err = bool(obj["err"].(json.Boolean) or_else false)
	}
	return m, ""
}

// ---- the core's side ----

@(private = "file")
window_command_ok :: proc(id: typeid) -> bool {
	for w in WINDOW_COMMANDS do if w == id do return true
	return false
}

@(private = "file")
link_send :: proc(text: string) {
	if link == nil do return
	if cw.mem_send(link.core_end, cw.JSON_CHANNEL, .Data, transmute([]u8)text) != .None {
		// a window that does not read (in process it always does): it starts again from a full
		fmt.eprintln("Deckhand: the window's link failed; it gets the whole state again")
		return
	}
	if link.on_frames != nil do link.on_frames()
}

// Frees the replies the inbox has delivered (and signalled: it signals right after deliver).
@(private = "file")
link_sweep :: proc(all := false) {
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
@(private = "file")
link_deliver :: proc(r: ^Reply, request_id: u64) {
	lr := (^Link_Reply)(r)
	window_link_flush()
	link_send(reply_json(lr.id, r.result, request_id))
	lr.delivered = true
}

@(private = "file")
link_reply_now :: proc(id: string, r: Result, request_id: u64) {
	window_link_flush()
	if id != "" do link_send(reply_json(id, r, request_id))
}

@(private = "file")
link_message :: proc(text: string) {
	if !json_depth_ok(text) {
		fmt.eprintln("Deckhand: a window message nested too deeply")
		return
	}
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
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
		link_send(state_full_json(&state, &link.sent))
	case "command":
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
	case "window.command":
		cmd, err := window_command_decode(obj["command"])
		if err != "" {
			fmt.eprintln("Deckhand: a window.command refused:", err)
			link_reply_now(id, fail(err), 0)
			return
		}
		link_run(cmd, {kind = .Internal}, id, now, "")
	case:
		fmt.eprintln("Deckhand: an unknown window message:", type)
	}
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
	return window_command_decode(obj["command"])
}
