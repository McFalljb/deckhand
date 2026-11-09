package core

// Tab host routing (docs/plans/background-core.md §4, §10.2 M3-G). Browser, app, Markdown and
// editor commands reach the core like any other; the core keeps their tabs' records (State: a
// browser tab's URL and title, an app's status, which tabs exist and where), and the window that
// hosts the tab does what only it can (CEF, an app's process and frames, an editor's buffer, a
// Markdown view). So each routed command runs in three steps:
//   1. the core checks the caller and the records (the target tab, its session, the URL);
//   2. it sends tab_host.call to the window and takes its `finished`;
//   3. the core changes the records the window's answer says (tab_host_after).
// No window attached (a headless core, test mode's detach_window, M4 with the window closed):
// {"ok":false,"code":"no_window"} (in data), at once, never a hang.
//
// Core -> window:
//   {"v":1,"type":"tab_host.call","id":"h7","request_id":N,"tab_id":T,"caller":{…},"command":{"<type>":{…}}}
//       tab_id: the tab the call makes (the core picks its id; the record follows the answer), or 0
// Window -> core:
//   {"v":1,"type":"finished","id":"h7","changed":true,"private":false,"wait_ms":0,"result":{…}}
//       answers a call; private: its data is a web page's content (the requester's only);
//       wait_ms, with a pending result: how long the window itself may take to end it (an
//       upload's bar waits for the user), so the core's backstop comes after that
//   {"v":1,"type":"finished","request_id":N,"private":false,"result":{…}} ends a request the
//       window answered pending (an agent's read, action, wait, screenshot, app call)
//   {"v":1,"type":"tab_host.event","id":"e1","now":true,"command":{"<type>":{…}}}
//       what a page, an app or the window's workers report: one of TAB_HOST_COMMANDS, run with
//       the tab_host caller (window_link.odin)
//
// In process the window runs a call while it is sent (on_frames), so its answer is there when
// the core pumps the link: the wait is nil, and agents see the same results as before. A call not
// answered then (M4 over core.sock) answers the agent `pending`; its `finished` completes it, or
// TAB_HOST_CALL_WAIT passes and the agent hears `timeout`. A request the window answered pending
// gets the same backstop past its own timeout (tab_host_deadline).
//
// The tab_host caller (Caller_Kind.Tab_Host) is what web content and app programs drive: popups,
// titles, address changes, an app's exit. It runs TAB_HOST_COMMANDS only (caller_may) and is never
// `ui`, so a page can never confirm a parked confirmation, change a setting or open a tab in a
// session other than its own tab's (Browser_Popup_Open takes the opener's).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"
import "core:time"
import jg "../jsonguard"

// What the tab_host caller may send (tab_host.event): reports and answers, records only.
TAB_HOST_COMMANDS := [?]typeid {
	Browser_Update, // what CEF reported: URL, title, loading and history, a refused popup
	Browser_Popup_Open, // a page's popup with a user gesture: a tab in the opener's session
	App_Update, // an app tab's process started or exited
	App_Call_Done, // an app screenshot worker's answer
}

TAB_HOST_CALL_WAIT :: 10 * time.Second // a call the window has not answered by then: timeout
TAB_HOST_GRACE :: 10 * time.Second // past a pending request's own timeout: the core gives up on it
TAB_HOST_PENDING_DEFAULT :: 60 * time.Second // a pending request with no timeout of its own

NO_WINDOW_ERROR :: "no window: this tab's page, app or file view lives in Deckhand's window, and none is attached"

no_window :: proc() -> Result {return {error = NO_WINDOW_ERROR, data = `{"code":"no_window"}`}}

// Whether a window hosts tabs now.
tab_host_up :: proc() -> bool {return window_attached()}

// May the tab_host caller send cmd?
tab_host_may :: proc(cmd: Command) -> bool {
	id := reflect.union_variant_typeid(cmd)
	for t in TAB_HOST_COMMANDS do if t == id do return true
	return false
}

// ---- the calls ----

@(private = "file")
Host_Wait :: struct {
	id:         string, // the call's, while unanswered (heap); "" once answered pending
	request_id: u64,
	deadline:   time.Tick,
	cmd:        Command, // heap copy: what a late answer completes (tab_host_after)
	caller:     Caller,
	tab_id:     u64,
	ended:      bool, // the window ended the request already (its finished came before the call's answer)
}

@(private = "file")
Host_Calling :: struct {
	id:         string, // the call's (temp)
	request_id: u64,
	ended:      bool, // the window ended the request while its call ran: no wait after a pending answer
}

@(private = "file")
Host_Answer :: struct {
	result:  Result, // heap
	changed: bool,
	wait:    time.Duration, // the window's own wait for a pending result (wait_ms)
}

@(private = "file")
host: struct {
	next:    u64,
	answers: map[string]Host_Answer, // answers to the calls being run now (host.calling), until taken (heap keys)
	waits:   [dynamic]^Host_Wait,
	calling: [dynamic]Host_Calling, // the calls being run now (nested: a link inside a Markdown tab)
}

// The most a window's own wait_ms may ask for (a backstop, not a promise).
TAB_HOST_WAIT_MAX :: 15 * time.Minute

// Sends cmd to the window that hosts its tab and takes the answer. answered false: none yet (M4);
// the agent gets pending and tab_host_finished completes it.
@(private = "file")
tab_host_call :: proc(cmd: Command, caller: Caller, request_id: u64, tab_id: u64 = 0) -> (r: Result, changed: bool, answered: bool) {
	heap := runtime.heap_allocator()
	if host.answers == nil do host.answers = make(map[string]Host_Answer, heap)
	if host.waits == nil do host.waits = make([dynamic]^Host_Wait, heap)
	if host.calling == nil do host.calling = make([dynamic]Host_Calling, heap)
	host.next += 1
	id := fmt.tprintf("h%d", host.next)
	append(&host.calling, Host_Calling{id = id, request_id = request_id})
	window_link_flush() // what earlier commands changed reaches the replica first: the window's part reads it
	sent := window_link_send(tab_host_msg_call(id, cmd, caller, request_id, tab_id))
	if sent do window_link_pump() // in process the window answered while it was sent
	me := pop(&host.calling)
	if !sent {
		if id in host.answers do host_answer_drop(id) // cannot be: nothing was sent
		return no_window(), false, true
	}
	if a, ok := host.answers[id]; ok {
		r = result_clone(a.result, context.temp_allocator)
		changed = a.changed
		host_answer_drop(id)
		// answered pending: its finished comes later (nobody to tell without a request id), unless
		// the window ended it already while the call ran
		if r.pending && request_id != 0 && !me.ended do host_wait(cmd, caller, request_id, tab_id, "", tab_host_deadline(cmd, a.wait))
		return r, changed, true
	}
	host_wait(cmd, caller, request_id, tab_id, id, TAB_HOST_CALL_WAIT, ended = me.ended)
	return {ok = true, pending = true}, false, false
}

@(private = "file")
host_wait :: proc(cmd: Command, caller: Caller, request_id, tab_id: u64, id: string, wait: time.Duration, ended := false) {
	heap := runtime.heap_allocator()
	w := new(Host_Wait, heap)
	w^ = {id = strings.clone(id, heap), request_id = request_id, deadline = time.tick_add(time.tick_now(), wait), cmd = command_clone(cmd, heap), caller = caller, tab_id = tab_id, ended = ended}
	append(&host.waits, w)
}

@(private = "file")
host_answer_drop :: proc(id: string) {
	key, a := delete_key(&host.answers, id)
	result_free(a.result)
	delete(key, runtime.heap_allocator())
}

@(private = "file")
host_wait_free :: proc(w: ^Host_Wait) {
	heap := runtime.heap_allocator()
	delete(w.id, heap)
	command_free(w.cmd, heap)
	free(w, heap)
}

// How long a request the window answered pending may take before the core gives up on it: its
// own timeout (the window ends it first), or what the window said it may take (window_wait: an
// upload's bar waits for the user), and TAB_HOST_GRACE more.
tab_host_deadline :: proc(cmd: Command, window_wait: time.Duration = 0) -> time.Duration {
	d := TAB_HOST_PENDING_DEFAULT
	#partial switch c in cmd {
	case App_Call:          if c.timeout_ms > 0 do d = time.Duration(c.timeout_ms) * time.Millisecond
	case Browser_Page_Wait: if c.timeout_ms > 0 do d = max(d, time.Duration(c.timeout_ms) * time.Millisecond)
	}
	d = max(d, min(window_wait, TAB_HOST_WAIT_MAX))
	return d + TAB_HOST_GRACE
}

// Whether a command's result data is a web page's content (only its requester gets it): the
// window marks its answers with it, and the core marks them too.
tab_host_data_private :: proc(cmd: Command) -> bool {
	#partial switch _ in cmd {
	case Browser_Read, Browser_Console, Browser_Network: return true
	}
	return false
}

// What the window sent: a call's answer (id), or the end of a request it answered pending
// (request_id). Main thread (window_link.odin).
tab_host_finished_msg :: proc(obj: json.Object, text: string) {
	heap := runtime.heap_allocator()
	r, rerr := tab_host_result_read(obj, text)
	if rerr != "" {
		fmt.eprintln("Deckhand: a finished from the window refused:", rerr)
		return
	}
	private := bool(obj["private"].(json.Boolean) or_else false)
	id := string(obj["id"].(json.String) or_else "")
	if id != "" {
		changed := bool(obj["changed"].(json.Boolean) or_else false)
		wait: time.Duration
		if n, is := obj["wait_ms"].(json.Integer); is && n > 0 do wait = time.Duration(min(n, i64(TAB_HOST_WAIT_MAX / time.Millisecond))) * time.Millisecond
		for w, i in host.waits do if w.id == id {
			// a late answer (M4): it completes the agent's request now
			ordered_remove(&host.waits, i)
			defer host_wait_free(w)
			ach := tab_host_after(w.cmd, w.caller, w.tab_id, &r, changed)
			if changed || ach {
				state.version += 1
				window_state_changed()
			}
			if w.ended do return // the window's finished ended the request already
			if r.pending {
				host_wait(w.cmd, w.caller, w.request_id, w.tab_id, "", tab_host_deadline(w.cmd, wait))
				return
			}
			if w.request_id != 0 do emit_event(Finished_Event{request_id = w.request_id, result = r, private = private || tab_host_data_private(w.cmd)})
			return
		}
		// only the calls being run now wait for an answer here: any other (a call that timed out,
		// one the core never sent) is dropped, so the map never grows
		running := false
		for c in host.calling do if c.id == id do running = true
		if !running {
			when TEST_HOOKS do fmt.eprintln("[tab_host] an answer to a call nobody waits for:", id)
			return
		}
		if old, had := host.answers[id]; had {
			result_free(old.result)
			host.answers[id] = {result_clone(r, heap), changed, wait}
		} else do host.answers[strings.clone(id, heap)] = {result_clone(r, heap), changed, wait}
		return
	}
	n, nok := obj["request_id"].(json.Integer)
	if !nok || n <= 0 {
		fmt.eprintln("Deckhand: a finished from the window with neither id nor request_id")
		return
	}
	rid := u64(n)
	for w, i in host.waits do if w.id == "" && w.request_id == rid {
		private ||= tab_host_data_private(w.cmd)
		ordered_remove(&host.waits, i)
		host_wait_free(w)
		emit_event(Finished_Event{request_id = rid, result = r, private = private})
		return
	}
	// one the window ends while its call still runs (it answers pending right after): no wait
	// after that answer, so no second finished
	for i := len(host.calling) - 1; i >= 0; i -= 1 do if c := &host.calling[i]; c.request_id == rid && !c.ended {
		c.ended = true
		emit_event(Finished_Event{request_id = rid, result = r, private = private})
		return
	}
	// one the window ended before the core read its call's answer (M4: the finished came first):
	// it ends the request now; the answer still updates the records when it comes
	for w in host.waits do if w.id != "" && w.request_id == rid && !w.ended {
		w.ended = true
		emit_event(Finished_Event{request_id = rid, result = r, private = private || tab_host_data_private(w.cmd)})
		return
	}
	when TEST_HOOKS do fmt.eprintln("[tab_host] a finished for a request nobody waits for:", rid)
}

// Ends the calls and requests past their deadline (core_tick).
tab_host_tick :: proc() {
	if len(host.waits) == 0 do return
	now := time.tick_now()
	for i := len(host.waits) - 1; i >= 0; i -= 1 {
		w := host.waits[i]
		if time.tick_diff(w.deadline, now) <= 0 do continue
		ordered_remove(&host.waits, i)
		if w.request_id != 0 && !w.ended do emit_event(Finished_Event{request_id = w.request_id, result = {error = "the window did not answer in time", data = `{"code":"timeout"}`}})
		host_wait_free(w)
	}
}

// The window went (window_link.odin's core_detach_window): what it still owed ends with no_window.
tab_host_detached :: proc() {
	heap := runtime.heap_allocator()
	for w in host.waits {
		if w.request_id != 0 && !w.ended do emit_event(Finished_Event{request_id = w.request_id, result = {error = "the window went away before it answered", data = `{"code":"no_window"}`}})
		host_wait_free(w)
	}
	clear(&host.waits)
	for k, a in host.answers {
		result_free(a.result)
		delete(k, heap)
	}
	clear(&host.answers)
}

// The requester went or cancelled (Request_Cancel): nothing waits for its answer any more.
@(private = "file")
tab_host_forget :: proc(request_id: u64) {
	for i := len(host.waits) - 1; i >= 0; i -= 1 {
		w := host.waits[i]
		if w.request_id != request_id do continue
		ordered_remove(&host.waits, i)
		host_wait_free(w)
	}
}

// Calls and requests in flight (tests).
tab_host_waiting :: proc() -> int {return len(host.waits)}

// Every deadline passed (tests).
@(private)
tab_host_expire_for_test :: proc() {
	for w in host.waits do w.deadline = time.tick_add(time.tick_now(), -time.Second)
}

// As if d had passed (tests).
@(private)
tab_host_age_for_test :: proc(d: time.Duration) {
	for w in host.waits do w.deadline = time.tick_add(w.deadline, -d)
}

// Answers kept for calls (tests).
@(private)
tab_host_answers_for_test :: proc() -> int {return len(host.answers)}

@(private)
tab_host_result_read_for_test :: proc(obj: json.Object, text: string) -> (Result, string) {return tab_host_result_read(obj, text)}

// ---- the messages ----

@(private)
tab_host_msg_call :: proc(id: string, cmd: Command, caller: Caller, request_id, tab_id: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"tab_host.call","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	fmt.sbprintf(&b, `,"request_id":%d,"tab_id":%d,"caller":{{"kind":`, request_id, tab_id)
	json_quote(&b, caller_kind_name(caller.kind))
	fmt.sbprintf(&b, `,"tab_id":%d,"claude":%v}},"command":`, caller.tab_id, caller.claude)
	command_variant_write(&b, cmd)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// A call as the window reads it (temp allocator).
Tab_Host_Call :: struct {
	id:         string,
	request_id: u64,
	tab_id:     u64,
	caller:     Caller,
	cmd:        Command,
}

tab_host_call_parse :: proc(text: string) -> (c: Tab_Host_Call, err: string) {
	if !json_depth_ok(text) do return {}, "nested too deeply"
	wire_read_budget(text) // wire_read's limit for this message (state_read.odin)
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	if jerr != nil || !ok do return {}, "not a JSON object"
	c.id = string(obj["id"].(json.String) or_else "")
	if n, is := obj["request_id"].(json.Integer); is && n > 0 do c.request_id = u64(n)
	if n, is := obj["tab_id"].(json.Integer); is && n > 0 do c.tab_id = u64(n)
	co, cok := obj["caller"].(json.Object)
	if !cok do return c, "no caller"
	kind := string(co["kind"].(json.String) or_else "")
	found := false
	for k in Caller_Kind do if k != .None && caller_kind_name(k) == kind {
		c.caller.kind = k
		found = true
	}
	if !found do return c, "an unknown caller"
	if n, is := co["tab_id"].(json.Integer); is && n > 0 do c.caller.tab_id = u64(n)
	c.caller.claude = bool(co["claude"].(json.Boolean) or_else false)
	c.cmd, err = command_variant_read(obj["command"], nil)
	return
}

// The window's answer to a call. private: its data is a web page's content; wait: with a pending
// result, how long the window itself may take to end it (0: the command's own timeout).
tab_host_msg_finished :: proc(id: string, r: Result, changed: bool, private := false, wait: time.Duration = 0) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"finished","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	fmt.sbprintf(&b, `,"changed":%v,"private":%v,"wait_ms":%d,"result":`, changed, private, i64(max(wait, 0) / time.Millisecond))
	write_result(&b, r)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// The end of a request the window answered pending.
tab_host_msg_done :: proc(request_id: u64, r: Result, private := false) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"finished","request_id":%d,"private":%v,"result":`, PROTOCOL_VERSION, request_id, private)
	write_result(&b, r)
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// A report from a page, an app or a window worker; ok false: not one of TAB_HOST_COMMANDS.
tab_host_msg_event :: proc(cmd: Command, id: string, now := false) -> (text: string, ok: bool) {
	if !tab_host_may(cmd) do return "", false
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"v":%d,"type":"tab_host.event","id":`, PROTOCOL_VERSION)
	json_quote(&b, id)
	if now do strings.write_string(&b, `,"now":true`)
	strings.write_string(&b, `,"command":`)
	command_variant_write(&b, cmd)
	strings.write_byte(&b, '}')
	return strings.to_string(b), true
}

// A command as {"<type, lowercased>": {every field}} (the window's link: window.command,
// tab_host.call, tab_host.event).
command_variant_write :: proc(b: ^strings.Builder, cmd: Command) {
	strings.write_byte(b, '{')
	c := cmd
	ti := type_info_of(reflect.union_variant_typeid(cmd))
	wire_write_lower(b, wire_variant_name(ti))
	strings.write_byte(b, ':')
	wire_write(b, &c, ti) // a union's variant sits at its start
	strings.write_byte(b, '}')
}

// {"<type>": {fields}} into the command (temp allocator): only the types in `only` (nil: any).
command_variant_read :: proc(v: json.Value, only: []typeid) -> (cmd: Command, err: string) {
	obj, ok := v.(json.Object)
	if !ok || len(obj) != 1 do return nil, "wants {\"<command>\": {...}}"
	for name, fields in obj {
		variants := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union).variants
		for vti in variants {
			if only != nil {
				listed := false
				for t in only do if t == vti.id do listed = true
				if !listed do continue
			}
			b := strings.builder_make(context.temp_allocator)
			wire_write_lower(&b, wire_variant_name(vti))
			if strings.trim(strings.to_string(b), `"`) != name do continue
			reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, vti.id)
			if e := wire_read(fields, &cmd, vti, context.temp_allocator); e != "" do return nil, fmt.tprintf("%s%s", name, e)
			return cmd, ""
		}
		return nil, fmt.tprintf("%s is not one this link carries", name)
	}
	return nil, "empty"
}

@(private = "file")
tab_host_result_read :: proc(obj: json.Object, text: string) -> (r: Result, err: string) {
	ro, ok := obj["result"].(json.Object)
	if !ok do return {}, "no result"
	r.ok = bool(ro["ok"].(json.Boolean) or_else false)
	r.error = string(ro["error"].(json.String) or_else "")
	r.pending = bool(ro["pending"].(json.Boolean) or_else false)
	if n, is := ro["created_id"].(json.Integer); is && n > 0 do r.created_id = u64(n)
	if nc, is := ro["needs_confirmation"].(json.Object); is {
		r.confirm_token = string(nc["token"].(json.String) or_else "")
		r.confirm_summary = string(nc["summary"].(json.String) or_else "")
		r.confirm_by_user = string(nc["by"].(json.String) or_else "") == "user"
	}
	if _, has := ro["data"]; has {
		// the data as the window wrote it (raw JSON), not re-marshalled
		members, mok := json_members_raw(strings.trim_space(text))
		if mok do for m in members do if m.key == "result" {
			inner, iok := json_members_raw(m.raw)
			if iok do for im in inner do if im.key == "data" do r.data = im.raw
		}
	}
	return r, ""
}

// ---- the commands ----

// A browser, app, Markdown or editor command (commands.odin's apply): the records here, the
// window's part through tab_host_call.
tab_host_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (Result, bool) {
	#partial switch c in cmd {
	// ---- records only: no window needed ----
	case Browser_Update:
		return browser_update_apply(c)
	case Browser_Popup_Open:
		return browser_popup_open(c)
	case App_Update:
		_, tab, at := app_tab_of(c.tab_id)
		if tab == nil do return {ok = true}, false
		if at.app_status == c.status && (c.status != .Exited || at.exit_code == c.exit_code) do return {ok = true}, false
		at.app_status = c.status
		if c.status == .Exited {
			at.exit_code = c.exit_code
			tab.status = .Exited
		} else do tab.status = .Running
		return {ok = true}, true
	case App_Close:
		// close_tab's close (its confirmation rule, comments, tab.quit then SIGTERM), app tabs only
		if r, bad := app_target(caller, c.tab_id, readonly_check = true); bad do return r, false
		return close_tab_apply(Close_Tab{tab_id = c.tab_id, confirm = c.confirm, comments = c.comments}, caller, request_id)
	case App_Events:
		if r, bad := app_target(caller, c.tab_id); bad do return r, false
		return {ok = true, data = app_events_json(c.tab_id, c.topic, c.since, c.limit)}, false
	case App_Declared:
		s, serr := app_session(caller, c.session)
		if s == nil do return fail(serr), false
		return {ok = true, data = app_declared_json(s)}, false
	case Keep_Tab:
		_, tab, _ := find_tab(c.tab_id)
		if tab == nil do return fail("no such editor tab"), false
		if _, is := tab.kind.(Editor_Tab); !is do return fail("no such editor tab"), false
		return keep_tab(tab)
	case List_Dir, Create_File, Create_Dir, Rename_Path, Delete_Path, Reveal_In_Finder, Git_Status_Done, File_List_Done:
		return files_cmd_apply(cmd, caller) // the project's files: the core's own
	case Request_Cancel:
		// the requester cancelled, or its connection closed: the window's action or read ends,
		// or a claude_wait_idle
		r, ch := Result{}, false
		if tab_host_up() do r, ch, _ = tab_host_call(cmd, caller, request_id) // its finished came meanwhile
		tab_host_forget(c.request_id) // what is left: nobody waits for it
		if r.ok do return r, ch
		if claude_wait_cancel(c.request_id, c.closed ? "the requester's connection closed" : "cancelled by the requester") do return {ok = true}, true
		return fail("no running request with that id"), false

	// ---- the window's: records checked first, changed after ----
	case Browser_Open:
		s, err := browser_open_session(caller, c.session)
		if s == nil do return fail(err), false
		if s.home do return fail("Home has only its pi tab"), false
		if c.url == "" {
			if caller.kind != .UI do return fail("url is needed"), false
		} else {
			url, uerr := browser_url_normalize(c.url)
			if uerr != "" do return fail(uerr), false
			if ferr := browser_file_check(caller, url); ferr != "" do return fail(ferr), false
		}
		return routed(cmd, caller, request_id, new_id())
	case Browser_Navigate:
		_, _, _, err := browser_target(caller, c.tab_id)
		if err != "" do return fail(err), false
		url, uerr := browser_url_normalize(c.url)
		if uerr != "" do return fail(uerr), false
		if ferr := browser_file_check(caller, url); ferr != "" do return fail(ferr), false
		return routed(cmd, caller, request_id)
	case Browser_Back, Browser_Forward:
		tab_id := browser_command_tab(cmd)
		_, _, bt, err := browser_target(caller, tab_id)
		if err != "" do return fail(err), false
		_, back := cmd.(Browser_Back)
		if back && !bt.can_back do return fail("nothing to go back to"), false
		if !back && !bt.can_forward do return fail("nothing to go forward to"), false
		return routed(cmd, caller, request_id)
	case Browser_Popup:
		_, _, bt, err := browser_target(caller, c.tab_id)
		if err != "" do return fail(err), false
		if bt.blocked_popup == "" do return fail("no popup was blocked"), false
		if c.open {
			// the page's own address for it: an address Deckhand opens (http, https, file, deckhand-test)
			nurl, why := browser_url_normalize(bt.blocked_popup)
			if why == "" && !browser_file_link_ok(bt.url, nurl) do why = "a file: address opens from a file: page only"
			if why != "" {
				r, ch := routed(Browser_Popup{tab_id = c.tab_id}, caller, request_id) // only the bar goes
				if !r.ok do return r, ch
				return fail(why), true
			}
		}
		return routed(cmd, caller, request_id, c.open ? new_id() : 0)
	case Browser_Tabs, Browser_Comments:
		return routed(cmd, caller, request_id) // the caller's session's (checked by the window's list)
	case Browser_Download:
		return routed(cmd, caller, request_id) // a download is the window's, by its id
	case Browser_Upload_Answer:
		if tab := browser_act_command_tab(cmd); tab != 0 {
			if _, _, _, err := browser_target(caller, tab); err != "" do return fail(err), false
		}
		return routed(cmd, caller, request_id)
	case Browser_Reload, Browser_Stop, Browser_Zoom, Browser_Find, Browser_Find_Close, Browser_Dialog, Browser_Permission, Browser_Edit, Browser_Devtools, Browser_External,
	     Browser_Read, Browser_Screenshot, Browser_Page_Wait, Browser_Console, Browser_Network, Browser_Agent_Stop,
	     Browser_Click, Browser_Type, Browser_Press, Browser_Scroll, Browser_Select, Browser_Hover, Browser_Upload, Browser_Agent_Take_Over:
		_, _, _, err := browser_target(caller, browser_any_command_tab(cmd))
		if err != "" do return fail(err), false
		return routed(cmd, caller, request_id)
	case New_App_Tab:
		x, r, bad := app_new_resolve(c, caller)
		if bad do return r, false
		return routed(x, caller, request_id, new_id())
	case App_Restart:
		if r, bad := app_target(caller, c.tab_id, readonly_check = true); bad do return r, false
		return routed(cmd, caller, request_id)
	case App_Input:
		if r, bad := app_target(caller, c.tab_id); bad do return r, false
		return routed(cmd, caller, request_id)
	case App_Call:
		if r, bad := app_target(caller, c.tab_id); bad do return r, false
		return routed(cmd, caller, request_id)
	case App_Screenshot:
		if r, bad := app_target(caller, c.tab_id); bad do return r, false
		return routed(cmd, caller, request_id)
	case App_Inspect:
		if r, bad := app_target(caller, c.tab_id); bad do return r, false
		return routed(cmd, caller, request_id)
	case App_Call_Done:
		if !tab_host_up() do return {ok = true}, false // nobody waits: the window's requests went with it
		return routed(cmd, caller, request_id)
	case Terminal_Link:
		// a ⌘-click on a terminal's link (the user's only): http and https in a browser tab of the
		// terminal's session, in front; mailto, an external one, Home's or no browser: the default one
		s, tab, _ := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		#partial switch _ in tab.kind {
		case Pi_Tab, Shell_Tab, Claude_Tab:
		case:
			return fail("not a terminal tab"), false
		}
		if !term_url_allowed(c.url) do return fail("only http, https and mailto links open from a terminal"), false
		if !ascii_prefix(c.url, "mailto:") && !c.external && !s.home && tab_host_up() {
			if r, ch := routed(cmd, caller, request_id, new_id()); r.ok do return r, ch
		}
		if !window_attached() do return no_window(), false // the user's ⌘-click: there is a window
		if !window_open_url(c.url) do return fail("the link could not be opened"), false
		return {ok = true}, false
	case Open_File:
		s, p, err := file_open_target(caller, c.session, c.path)
		if err != "" do return fail(err), false
		// the file's tab, if one is open: in front (a preview's single click keeps it a preview)
		if tab := session_file_tab(s, p, true); tab != nil {
			if !tab_host_up() do return no_window(), false
			session_show_tab(s, tab.id)
			if et := &tab.kind.(Editor_Tab); !c.preview do et.preview = false // opened for good (double-click, Enter)
			focus_session(s.id, caller)
			if c.line > 0 do routed(Goto_Line{tab_id = tab.id, line = c.line, col = c.col}, caller, request_id)
			return {ok = true, created_id = tab.id}, true
		}
		return routed(Open_File{path = p, line = c.line, col = c.col, session = s.id, preview = c.preview}, caller, request_id, new_id())
	case Markdown_Open:
		s, p, err := file_open_target(caller, c.session, c.path)
		if err != "" do return fail(err), false
		if tab := session_file_tab(s, p, false); tab != nil {
			if !tab_host_up() do return no_window(), false
			session_show_tab(s, tab.id)
			focus_session(s.id, caller)
			if c.anchor != "" do routed(Markdown_Scroll{tab_id = tab.id, anchor = c.anchor}, caller, request_id)
			return {ok = true, created_id = tab.id}, true
		}
		return routed(Markdown_Open{path = p, session = s.id, anchor = c.anchor}, caller, request_id, new_id())
	case Diff_File:
		s, _, et := editor_tab_of(c.tab_id)
		if et == nil || et.view != .File do return fail("no such file tab"), false
		if c.against != .Diff_Head && c.against != .Diff_Disk do return fail("against: head or disk"), false
		// one diff tab per file and kind: refreshed when asked again (the window makes its text)
		id: u64
		for t in s.tabs do if x, is := t.kind.(Editor_Tab); is && x.view == c.against && x.path == et.path do id = t.id
		return routed(cmd, caller, request_id, id != 0 ? id : new_id())
	case Reload_File:
		s, tab, et := editor_tab_of(c.tab_id)
		if et == nil do return fail("no such editor tab"), false
		if et.view != .File do return fail("nothing to reload"), false
		if !tab_host_up() do return no_window(), false
		// unsaved changes are the user's: another caller confirms first
		ch := false
		// not known (no window to ask): ask, as if there were
		if dirty, known := window_tab_dirty(c.tab_id); caller.kind != .UI && (dirty || !known) {
			gr, go_on, gch := confirm_gate(cmd, .Tab_Close, caller, c.confirm, fmt.tprintf("discard the unsaved changes to %q in %s?", tab.title, session_where(s)))
			if !go_on do return gr, gch
			ch = gch
		}
		r, rch := routed(cmd, caller, request_id)
		return r, rch || ch
	case Editor_State, Save_File, Goto_Line, Keep_Buffer, Set_Wrap:
		if _, _, et := editor_tab_of(editor_command_tab(cmd)); et == nil do return fail("no such editor tab"), false
		return routed(cmd, caller, request_id)
	case Markdown_Set_View:
		_, _, mt := markdown_tab_of(c.tab_id)
		if mt == nil do return fail("no such Markdown tab"), false
		if mt.source == c.source do return {ok = true}, false
		return routed(cmd, caller, request_id)
	case Markdown_Scroll:
		if _, _, mt := markdown_tab_of(c.tab_id); mt == nil do return fail("no such Markdown tab"), false
		return routed(cmd, caller, request_id)
	case Markdown_Follow:
		s, _, mt := markdown_tab_of(c.tab_id)
		if mt == nil do return fail("no such Markdown tab"), false
		// the window says what the link is (one of the document's, as laid out); the core acts on it
		r, ch := routed(cmd, caller, request_id)
		if !r.ok || r.data == "" do return r, ch
		r2, ch2 := markdown_follow_act(c, s, caller, request_id, r.data)
		return r2, ch || ch2
	case Git_Head_Done:
		if !tab_host_up() do return {ok = true}, false // the editor went with the window
		return routed(cmd, caller, request_id)
	}
	return fail("not a tab host command"), false
}

// Step 2 and 3: the window's part, then the records its answer says.
@(private = "file")
routed :: proc(cmd: Command, caller: Caller, request_id: u64, tab_id: u64 = 0) -> (Result, bool) {
	if !tab_host_up() do return no_window(), false
	r, ch, answered := tab_host_call(cmd, caller, request_id, tab_id)
	if !answered do return r, false // pending: its finished completes it (tab_host_finished_msg)
	ach := tab_host_after(cmd, caller, tab_id, &r, ch)
	return r, ch || ach
}

// The records a command changes once the window did its part (r: the window's answer, which this
// may adjust). tab_id: the tab the call made. True: State changed.
@(private = "file")
tab_host_after :: proc(cmd: Command, caller: Caller, tab_id: u64, r: ^Result, window_changed: bool) -> bool {
	#partial switch c in cmd {
	case Browser_Open:
		if !r.ok do return false
		s, _ := browser_open_session(caller, c.session)
		if s == nil do return false
		url := c.url != "" ? c.url : BROWSER_BLANK
		if c.url != "" do url, _ = browser_url_normalize(c.url)
		// an agent (a pi tab, a control caller) never changes what the user sees: its tab opens
		// behind, in the pane of its own tab (open_pane)
		agent := caller.kind == .Panel || caller.kind == .Control
		browser_record_add(s, tab_id, url, background = agent, pane = open_pane(s, caller))
		r.created_id = tab_id
		return true
	case Browser_Navigate:
		if !r.ok do return false
		_, _, bt, _ := browser_target(caller, c.tab_id)
		if bt == nil do return false
		url, _ := browser_url_normalize(c.url)
		set_owned_str(&bt.url, browser_url_public(url))
		set_owned_str(&bt.blocked_popup, "")
		return true
	case Browser_Popup:
		_, _, bt, _ := browser_target(caller, c.tab_id)
		if bt == nil do return false
		url := strings.clone(bt.blocked_popup, context.temp_allocator)
		set_owned_str(&bt.blocked_popup, "")
		if !c.open || !r.ok do return true
		// a new tab in the opener's session (never another), on screen there
		s, _, _ := find_tab(c.tab_id)
		nurl, _ := browser_url_normalize(url)
		browser_record_add(s, tab_id, nurl)
		r.created_id = tab_id
		return true
	case Terminal_Link:
		if !r.ok || r.created_id != tab_id do return false
		s, _, _ := find_tab(c.tab_id)
		if s == nil do return false
		browser_record_add(s, tab_id, c.url)
		return true
	case New_App_Tab:
		if !r.ok do return false
		s := find_session(c.session)
		if s == nil do return false
		started := !strings.contains(r.data, `"started":false`)
		owned := make([]string, len(c.argv))
		for a, i in c.argv do owned[i] = strings.clone(a)
		by_agent := caller.kind == .Panel
		tab := Tab{id = tab_id, kind = App_Tab{argv = owned, cwd = strings.clone(c.cwd), exit_code = started ? -1 : 127, app_status = started ? .Starting : .Exited}, title = strings.clone(c.title), status = started ? .Running : .Exited}
		pane_add_tab(s, tab, pane = open_pane(s, caller)) // an agent's: in its own tab's pane
		if !by_agent {
			// an agent's (a pi or Claude tab's) opens behind the user's view, as its browser tabs;
			// the user's, a script's and Home's come to the front
			session_show_tab(s, tab_id)
			focus_session(s.id, caller)
		}
		r.created_id = tab_id
		return true
	case Open_File:
		if !r.ok do return false
		s := find_session(c.session)
		if s == nil do return false
		tab := Tab{id = tab_id, kind = Editor_Tab{path = strings.clone(c.path), preview = c.preview}, title = title_for(c.path, .File), status = .Running}
		// a preview takes the place of the session's preview tab, unless that one has unsaved changes
		at := -1
		if c.preview {
			for t, i in s.tabs {
				et, is := t.kind.(Editor_Tab)
				if dirty, known := window_tab_dirty(t.id); is && et.preview && known && !dirty do at = i
			}
		}
		if at >= 0 {
			old := &s.tabs[at]
			// as close_tab cleans up a tab
			drop_term(old.id)
			forget_confirmations_for(old.id)
			socket_forget_tab(old.id)
			tab_clear_panels(old)
			delete(old.panels)
			if et, is := old.kind.(Editor_Tab); is do delete(et.path)
			delete(old.title)
			tab.pane = old.pane // in its place: its pane, and shown where it was shown
			for &pn in s.panes do if pn.active == old.id do pn.active = tab.id
			old^ = tab
		} else {
			pane_add_tab(s, tab)
		}
		session_show_tab(s, tab_id)
		focus_session(s.id, caller)
		r.created_id = tab_id
		return true
	case Markdown_Open:
		if !r.ok do return false
		s := find_session(c.session)
		if s == nil do return false
		pane_add_tab(s, Tab{id = tab_id, kind = Markdown_Tab{path = strings.clone(c.path)}, title = strings.clone(filepath.base(c.path)), status = .Running})
		session_show_tab(s, tab_id)
		focus_session(s.id, caller)
		r.created_id = tab_id
		return true
	case Diff_File:
		if !r.ok do return false
		s, _, et := editor_tab_of(c.tab_id)
		if et == nil do return false
		if _, t, _ := find_tab(tab_id); t == nil {
			path := strings.clone(et.path)
			pane_add_tab(s, Tab{id = tab_id, kind = Editor_Tab{path = path, view = c.against}, title = title_for(path, c.against), status = .Running})
		}
		session_show_tab(s, tab_id)
		r.created_id = tab_id
		return true
	case Markdown_Set_View:
		if !r.ok do return false
		_, _, mt := markdown_tab_of(c.tab_id)
		if mt == nil do return false
		mt.source = c.source
		return true
	case Save_File:
		if !r.ok do return false
		if _, _, et := editor_tab_of(c.tab_id); et != nil do settings_after_save(c.tab_id, et.path) // pi reads it at start: offer a reload
		return false
	case App_Restart:
		if !window_changed do return false // refused before anything ran
		_, tab, at := app_tab_of(c.tab_id)
		if tab == nil do return false
		at.app_status = r.ok ? .Starting : .Exited
		tab.status = r.ok ? .Running : .Exited
		return true
	}
	return false
}

// ---- browser records ----

// The session a caller's browser_open goes to (session: what it named, 0 = none), or why not.
// Sessions (docs/BROWSER.md §2.1): a pi tab's own (it may not name another), the session on
// screen for the user and scripts, the named one for a control caller (Atlas, bound to Home, has
// no browser tabs of its own: it names the session). Never "whatever is focused" for an agent.
browser_open_session :: proc(caller: Caller, session: u64) -> (^Open_Session, string) {
	switch caller.kind {
	case .Panel:
		own := caller_session(caller)
		if own == nil do return nil, "the calling pi tab has no session"
		if session != 0 && session != own.id do return nil, "a pi tab opens browser tabs in its own session only"
		return own, ""
	case .UI, .Script:
		s := session != 0 ? find_session(session) : cur()
		if s == nil do return nil, session != 0 ? "no such session" : "no session on screen"
		return s, ""
	case .Control:
		if session != 0 {
			s := find_session(session)
			if s == nil do return nil, "no such session"
			return s, ""
		}
		if caller.tab_id != 0 {
			s := caller_session(caller)
			if s == nil do return nil, "no such session"
			return s, ""
		}
		return nil, "session is needed (which session the browser tab belongs to)"
	case .Internal:
		s := find_session(session)
		if s == nil do return nil, "no such session"
		return s, ""
	case .App, .Tab_Host, .None:
	}
	return nil, "not allowed for this caller"
}

// A browser tab a caller may drive: a pi tab only its own session's (an explicit exception to
// PROTOCOL.md §2's self-reference rule; closing them is still close_tab, which it may not send).
browser_target :: proc(caller: Caller, tab_id: u64) -> (s: ^Open_Session, tab: ^Tab, bt: ^Browser_Tab, err: string) {
	s, tab, _ = find_tab(tab_id)
	if tab == nil do return nil, nil, nil, "no such tab"
	is: bool
	bt, is = &tab.kind.(Browser_Tab)
	if !is do return nil, nil, nil, "not a browser tab"
	if caller.kind == .Panel {
		own := caller_session(caller)
		if own == nil || own != s do return nil, nil, nil, "a pi tab drives only its own session's browser tabs"
	}
	return s, tab, bt, ""
}

// file: addresses (local files) are the user's own: no agent or script opens them.
browser_file_check :: proc(caller: Caller, url: string) -> string {
	if caller.kind == .UI || caller.kind == .Internal do return ""
	if strings.has_prefix(strings.to_lower(url, context.temp_allocator), "file:") do return "file: addresses are opened by the user only"
	return ""
}

// A file: address opens from a file: page only (the popup bar, Open link in new tab).
browser_file_link_ok :: proc(page_url, link: string) -> bool {
	is_file :: proc(u: string) -> bool {return strings.has_prefix(strings.to_lower(u, context.temp_allocator), "file:")}
	return !is_file(link) || is_file(page_url)
}

// The tab's title from the page's (none: its address without the scheme).
browser_tab_title :: proc(title, url: string) -> string {
	if title != "" do return title
	if url == "" || url == BROWSER_BLANK do return "New tab"
	if i := strings.index(url, "://"); i >= 0 do return url[i + 3:]
	return url
}

// A browser tab's record (its page the window opened with this id). State never holds a user name
// or password (browser_url_public); the page gets the URL as given.
@(private = "file")
browser_record_add :: proc(s: ^Open_Session, tab_id: u64, url: string, background := false, pane: u64 = 0) {
	title := url == BROWSER_BLANK ? "New tab" : "Browser"
	tab := Tab{id = tab_id, kind = Browser_Tab{url = strings.clone(browser_url_public(url))}, title = strings.clone(title), status = .Running}
	pane_add_tab(s, tab, pane = pane)
	if !background do session_show_tab(s, tab_id)
}

// What CEF reported, into the tab's record (the tab_host caller's, or Deckhand's own). title: the
// page's title as the window has it now (sent with every address change too).
@(private = "file")
browser_update_apply :: proc(c: Browser_Update) -> (Result, bool) {
	_, tab, _ := find_tab(c.tab_id)
	if tab == nil do return fail("no such tab"), false
	bt, is := &tab.kind.(Browser_Tab)
	if !is do return fail("not a browser tab"), false
	if .Url in c.what do set_owned_str(&bt.url, browser_url_public(c.url))
	if .Nav in c.what do bt.loading, bt.can_back, bt.can_forward = c.loading, c.can_back, c.can_forward
	if .Blocked in c.what do set_owned_str(&bt.blocked_popup, c.blocked)
	if .Title in c.what || .Url in c.what do set_owned_str(&tab.title, browser_tab_title(c.title, bt.url))
	return {ok = true}, true
}

// A page's popup (target=_blank, window.open, ⌘-click; docs/BROWSER.md §2.5) with a user gesture:
// a new tab in the opener's session, never another (the window refuses one without a gesture).
// The window's id for it comes back (created_id) at once: CEF's browser lands in its slot.
@(private = "file")
browser_popup_open :: proc(c: Browser_Popup_Open) -> (Result, bool) {
	s, tab, _ := find_tab(c.opener)
	if tab == nil do return fail("no such tab"), false
	if _, is := tab.kind.(Browser_Tab); !is do return fail("not a browser tab"), false
	if s.home do return fail("Home has only its pi tab"), false
	// a file: address opens from a file: page only (the window checks it too)
	if bt, _ := tab.kind.(Browser_Tab); !browser_file_link_ok(bt.url, c.url) do return fail("file: addresses open from a file: page only"), false
	pane := c.pane
	if session_pane(s, pane) == nil do pane = 0
	id := new_id()
	browser_record_add(s, id, c.url, background = c.background, pane = pane)
	return {ok = true, created_id = id}, true
}

@(private = "file")
set_owned_str :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	old := dst^
	dst^ = strings.clone(v)
	delete(old)
}

// ---- app records ----

@(private = "file")
app_tab_of :: proc(id: u64) -> (^Open_Session, ^Tab, ^App_Tab) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	at, is := &tab.kind.(App_Tab)
	if !is do return nil, nil, nil
	return s, tab, at
}

// An app tab a caller may reach: a pi or Claude tab (panel) only its own session's, as its browser
// tabs; a read-only chat's pi reads apps but runs none (readonly_check: restart, close).
@(private = "file")
app_target :: proc(caller: Caller, tab_id: u64, readonly_check := false) -> (Result, bool) {
	ts, tab, _ := app_tab_of(tab_id)
	if tab == nil do return fail("no such app tab"), true
	if caller.kind == .Panel {
		own := caller_session(caller)
		if own == nil || ts != own do return fail("a pi or Claude tab reaches only its own session's app tabs"), true
		if readonly_check && !caller.claude && pi_chat_readonly(caller) do return fail("a read-only chat's pi may read apps, not open, restart or close them (it was started under Chats: read-only)"), true
	}
	return {}, false
}

// new_app_tab's checks and what it runs: the session, the argv (an apps.json entry by name, an
// argv, or a command line), its folder and title. The window then starts it under that tab id.
@(private = "file")
app_new_resolve :: proc(c: New_App_Tab, caller: Caller) -> (x: New_App_Tab, r: Result, bad: bool) {
	s, serr := app_session(caller, c.session)
	if s == nil do return {}, fail(serr), true
	if s.home do return {}, fail("Home has only its pi tab"), true
	agent := caller.kind == .Panel
	if agent && !caller.claude && pi_chat_readonly(caller) do return {}, fail("a read-only chat's pi may read apps, not open, restart or close them (it was started under Chats: read-only)"), true
	argv: []string
	cwd_arg, title := c.cwd, c.title
	if c.name != "" {
		// what the project declares, as the palette's "New app tab…" runs it
		if len(c.argv) > 0 || c.command != "" do return {}, fail("name, or argv or command: not both"), true
		if agent && c.cwd != "" do return {}, fail("cwd comes from .deckhand/apps.json for a pi or Claude tab"), true
		e, found := app_entry(s.cwd, c.name)
		if !found do return {}, fail(app_not_declared(s.cwd, c.name)), true
		argv = e.argv
		if cwd_arg == "" do cwd_arg = e.cwd
		if title == "" do title = e.name
	} else if agent {
		// a session's own agent runs only what its project declares (apps.json: the agent's own
		// authority, as its shell; docs/ENGINE-BRIDGE.md, trust model)
		return {}, fail("a pi or Claude tab opens only the apps its project declares in .deckhand/apps.json, by name (app_declared lists them)"), true
	} else if len(c.argv) > 0 do argv = c.argv
	else if strings.trim_space(c.command) != "" do argv = []string{"/bin/sh", "-c", c.command}
	else do return {}, fail("argv or command is needed"), true
	cwd := s.cwd
	if cwd_arg != "" {
		p := cwd_arg
		if !filepath.is_abs(p) do p, _ = filepath.join({s.cwd, p}, context.temp_allocator)
		p, _ = filepath.clean(p, context.temp_allocator)
		base := fs_real(s.cwd)
		rp := fs_real(p)
		if rp != base && !strings.has_prefix(rp, strings.concatenate({base, "/"}, context.temp_allocator)) do return {}, fail("cwd must be inside the session's folder"), true
		if !os.is_dir(rp) do return {}, fail("cwd is not a folder"), true
		cwd = rp
	}
	if title == "" {
		// the program's name (a command line's first word)
		prog := argv[0]
		if len(argv) > 2 && argv[0] == "/bin/sh" {
			words := strings.fields(argv[2], context.temp_allocator)
			prog = len(words) > 0 ? words[0] : "app"
		}
		title = filepath.base(prog)
	}
	if agent {
		// the agent's text (its title, or an apps.json name it may have written) in the chrome
		title = strings.trim_space(one_line(title, context.temp_allocator))
		if n := strings.rune_count(title); n > APP_TITLE_MAX {
			i, k := 0, 0
			for _, j in title {
				if k == APP_TITLE_MAX {
					i = j
					break
				}
				k += 1
			}
			title = title[:i]
		}
		if title == "" do title = "app"
	}
	return New_App_Tab{session = s.id, argv = argv, cwd = cwd, title = title}, {}, false
}

// app_declared's data: the session's apps.json entries.
@(private = "file")
app_declared_json :: proc(s: ^Open_Session) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"session":%d,"apps":[`, s.id)
	for e, i in app_entries(s.cwd) {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"name":`)
		json_quote(&b, e.name)
		strings.write_string(&b, `,"argv":[`)
		for x, j in e.argv {
			if j > 0 do strings.write_byte(&b, ',')
			json_quote(&b, x)
		}
		strings.write_byte(&b, ']')
		if e.cwd != "" {
			strings.write_string(&b, `,"cwd":`)
			json_quote(&b, e.cwd)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// ---- editor and Markdown records ----

@(private = "file")
editor_tab_of :: proc(id: u64) -> (^Open_Session, ^Tab, ^Editor_Tab) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	et, is := &tab.kind.(Editor_Tab)
	if !is do return nil, nil, nil
	return s, tab, et
}

@(private = "file")
markdown_tab_of :: proc(id: u64) -> (^Open_Session, ^Tab, ^Markdown_Tab) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	mt, is := &tab.kind.(Markdown_Tab)
	if !is do return nil, nil, nil
	return s, tab, mt
}

@(private = "file")
editor_command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Editor_State: return c.tab_id
	case Save_File:    return c.tab_id
	case Goto_Line:    return c.tab_id
	case Keep_Buffer:  return c.tab_id
	case Set_Wrap:     return c.tab_id
	}
	return 0
}

// Where open_file and markdown_open open: the caller's own session (a tab-bound caller), else the
// one on screen (Home has only its pi tab, so Home's control opens files in the one on screen),
// and the file, absolute (a relative path: from the named session's folder, else the caller's).
@(private = "file")
file_open_target :: proc(caller: Caller, session: u64, path: string) -> (s: ^Open_Session, p: string, err: string) {
	s = session != 0 ? find_session(session) : caller_session(caller)
	if s != nil && s.home && session == 0 do s = cur()
	if s == nil do return nil, "", "no open session to open the file in"
	if s.home do return nil, "", "Home has only its pi tab"
	if path == "" do return nil, "", "path is empty"
	p = path
	if strings.has_prefix(p, "~/") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
	if !filepath.is_abs(p) {
		base := session != 0 ? s.cwd : fs_base_for(caller)
		if base == "" do base = s.cwd
		p, _ = filepath.join({base, p}, context.temp_allocator)
	}
	p, _ = filepath.clean(p, context.temp_allocator)
	if settings_credential(p) do return nil, "", CREDENTIAL_REFUSED // sign-ins and .env files: never shown (settings_files.odin)
	switch path_kind(p) {
	case .Missing: return nil, "", "no such file"
	case .Dir:     return nil, "", "that is a folder"
	case .File, .Other: // other kinds open as a tab that says why
	}
	return s, p, ""
}

// The session's tab that shows file p: an editor's file view (editor) or a Markdown tab.
@(private = "file")
session_file_tab :: proc(s: ^Open_Session, p: string, editor: bool) -> ^Tab {
	rp := fs_real(p)
	for &tab in s.tabs {
		if editor {
			et, is := tab.kind.(Editor_Tab)
			if is && et.view == .File && fs_real(et.path) == rp do return &tab
		} else {
			mt, is := tab.kind.(Markdown_Tab)
			if is && fs_real(mt.path) == rp do return &tab
		}
	}
	return nil
}

// What a Markdown link is, as the window answered markdown_follow ({"follow":"external"} or
// {"follow":"open","path":…,"anchor":…}): the core opens it. A web or mail link leaves Deckhand
// (the user's browser or mail, signed in): only the user's click, or a call the user confirms.
@(private = "file")
markdown_follow_act :: proc(c: Markdown_Follow, s: ^Open_Session, caller: Caller, request_id: u64, data: string) -> (Result, bool) {
	switch json_path(data, "follow") {
	case "external":
		url := c.url
		scheme := strings.to_lower(url[:max(strings.index_byte(url, ':'), 0)], context.temp_allocator)
		// whatever the window says, only a web or mail link leaves Deckhand (never file:, a
		// script or an app's own scheme)
		switch scheme {
		case "http", "https", "mailto":
		case: return fail("only http, https and mailto links open outside Deckhand"), false
		}
		changed := false
		if (caller.kind != .UI && caller.kind != .Internal) || c.confirm != "" {
			what := fmt.tprintf("open %s?", scheme == "mailto" ? fmt.tprintf("a mail to %s", one_line(url[len("mailto:"):], context.temp_allocator)) : one_line(url, context.temp_allocator))
			gr, go_on, ch := confirm_gate(Markdown_Follow{tab_id = c.tab_id, url = url}, .Open_Link, caller, c.confirm, what)
			if !go_on do return gr, ch
			changed = ch
		}
		_ = window_open_url(url)
		return {ok = true}, changed
	case "open":
		p := json_path(data, "path")
		if p == "" do return fail("empty link"), false
		if path_kind(p) != .Dir && md_is_markdown_path(p) do return tab_host_apply(Markdown_Open{path = p, session = s.id, anchor = json_path(data, "anchor")}, caller, request_id)
		return run_command(Open_File{path = p, session = s.id}, caller), true
	}
	return {ok = true}, false
}

@(private = "file")
keep_tab :: proc(tab: ^Tab) -> (Result, bool) {
	et := &tab.kind.(Editor_Tab)
	if !et.preview do return {ok = true}, false
	et.preview = false
	return {ok = true}, true
}

// The tab a browser command (any of them) is for; 0 = none.
@(private = "file")
browser_any_command_tab :: proc(cmd: Command) -> u64 {
	#partial switch c in cmd {
	case Browser_Zoom:       return c.tab_id
	case Browser_Find:       return c.tab_id
	case Browser_Find_Close: return c.tab_id
	case Browser_Dialog:     return c.tab_id
	case Browser_Permission: return c.tab_id
	case Browser_Popup:      return c.tab_id
	case Browser_Edit:       return c.tab_id
	case Browser_Devtools:   return c.tab_id
	case Browser_External:   return c.tab_id
	}
	if t := browser_command_tab(cmd); t != 0 do return t
	if t := browser_agent_command_tab(cmd); t != 0 do return t
	return browser_act_command_tab(cmd)
}
