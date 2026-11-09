package core

// Another machine's browser tabs (docs/plans/background-core.md §8.2, §8.3, §10.4 M6-D). Its pages
// live in this Mac's CEF, in the window: its core keeps their records and, its window being this
// core (the hub), sends this core the tab_host.call a window would get. This core routes it to the
// window, capped:
//   - only the browser commands an agent drives (REMOTE_TAB_HOST_COMMANDS); anything else (an app
//     tab, a Markdown or editor view, an upload, a download, a permission, the clipboard's Edit,
//     an external browser, DevTools) answers not_on_remote;
//   - every id it names is its own, packed with its number (§10.4 M6-B), so it can only name that
//     machine's tabs and sessions; an id that does not pack is refused;
//   - its caller is never more than a pi tab's: panel, bound to its (packed) tab, or script with
//     no tab; browser_tabs without a tab names a session;
//   - its text is bounded (REMOTE_TEXT_MAX each) and an address it opens is http or https, never
//     this Mac's loopback (a port the user forwarded aside: machine_forward_*), LAN or link-local:
//     the classifier in netcap.odin. The window's CEF checks every request of its pages again,
//     redirects included, in a request context of that machine's own (cef_polish.inc), so a page
//     never reaches them either.
// The window's answer goes back as a finished, its ids unpacked; a screenshot's PNG comes back as
// bytes in it (png_base64, at most REMOTE_SHOT_MAX), never as a path here (no file.read): the other
// core writes it to its own shots dir (tabhost_route.odin's hub_shot_keep). What the window
// reports of a page (Browser_Update) goes to that machine as a tab_host.event (machine_route.odin).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import jg "../jsonguard"

// What another machine's core may ask this Mac's window to do with its browser tabs.
REMOTE_TAB_HOST_COMMANDS := [?]typeid {
	Browser_Open,
	Browser_Navigate,
	Browser_Back,
	Browser_Forward,
	Browser_Reload,
	Browser_Stop,
	Browser_Zoom,
	Browser_Find,
	Browser_Find_Close,
	Browser_Dialog,
	Browser_Tabs,
	Browser_Read,
	Browser_Screenshot,
	Browser_Page_Wait,
	Browser_Console,
	Browser_Network,
	Browser_Agent_Stop,
	Browser_Agent_Take_Over,
	Browser_Click,
	Browser_Type,
	Browser_Press,
	Browser_Scroll,
	Browser_Select,
	Browser_Hover,
	Request_Cancel,
}

REMOTE_CALLS_MAX :: 256 // its calls waiting for the window, all machines
REMOTE_TEXT_MAX :: 16 << 10 // each string it sends (a URL, a selector, typed text)
REMOTE_ID_MAX :: 64 // its call ids
REMOTE_SHOT_MAX :: 8 << 20 // a screenshot's PNG for it
REMOTE_DATA_MAX :: REMOTE_SHOT_MAX / 3 * 4 + 64 << 10 // an answer's data for it: the PNG in base64, and the rest
REMOTE_RID_BASE :: u64(1) << 50 // this core's request ids for its requests (none of this core's own get there)

NOT_ON_REMOTE :: `{"code":"not_on_remote"}`

@(private = "file")
Remote_Call :: struct {
	n:        u64, // "x<n>" to the window
	machine:  u64,
	id:       string, // its call's id (heap)
	rrid:     u64, // its request id (0: none)
	hrid:     u64, // ours for it, to the window (0: none)
	kind:     typeid, // its command's
	base:     time.Duration, // how long its request may run (tab_host_deadline)
	deadline: time.Tick,
	answered: bool, // the window answered the call
	ended:    bool, // the window ended the request
}

@(private = "file")
rb: struct {
	calls: [dynamic]^Remote_Call,
	next:  u64,
}

// Calls waiting (tests).
machine_browser_waiting :: proc() -> int {return len(rb.calls)}

// A tab_host.call from machine no's core (machines.odin's pump). Its answer goes back on its link.
machine_tab_host_call :: proc(no: u64, text: string) {
	c, err := tab_host_call_parse(text)
	id := c.id
	if len(id) > REMOTE_ID_MAX || !utf8.valid_string(id) do id = "" // nothing to answer to
	if err != "" {
		if id != "" do remote_answer(no, id, fail(fmt.tprintf("this Mac's window cannot read the call: %s", err)))
		return
	}
	cmd, caller, tab_id, r, refused := remote_call_check(no, c)
	if refused {
		if id != "" do remote_answer(no, id, r)
		return
	}
	if !tab_host_up() {
		if id != "" do remote_answer(no, id, no_window())
		return
	}
	if len(rb.calls) >= REMOTE_CALLS_MAX {
		if id != "" do remote_answer(no, id, {error = "this Mac's window is busy with other machines' pages", data = `{"code":"busy"}`})
		return
	}
	heap := runtime.heap_allocator()
	rb.next += 1
	e := new(Remote_Call, heap)
	e^ = {n = rb.next, machine = no, id = strings.clone(id, heap), rrid = c.request_id, kind = reflect.union_variant_typeid(cmd), base = tab_host_deadline(cmd)}
	if c.request_id != 0 do e.hrid = REMOTE_RID_BASE + e.n
	e.deadline = time.tick_add(time.tick_now(), TAB_HOST_CALL_WAIT + e.base)
	append(&rb.calls, e)
	window_link_flush() // its records (the mirror) reach the window first: the window's part reads them
	if !window_link_send(tab_host_msg_call(fmt.tprintf("x%d", e.n), cmd, caller, e.hrid, tab_id)) {
		remote_drop(len(rb.calls) - 1)
		if id != "" do remote_answer(no, id, no_window())
	}
}

// The checks, and the call as the window gets it: ids packed, its caller capped, its address
// checked (and a forwarded port's put in). refused: r is the answer.
@(private)
remote_call_check :: proc(no: u64, c: Tab_Host_Call) -> (cmd: Command, caller: Caller, tab_id: u64, r: Result, refused: bool) {
	t := reflect.union_variant_typeid(c.cmd)
	listed := false
	for x in REMOTE_TAB_HOST_COMMANDS do if x == t do listed = true
	if !listed do return nil, {}, 0, {error = fmt.tprintf("%s is not available for another machine's sessions", command_type(c.cmd)), data = NOT_ON_REMOTE}, true
	if !remote_strings_ok(c.cmd) do return nil, {}, 0, fail("a text in the call is too long or not UTF-8"), true
	ok: bool
	if cmd, ok = command_packed(c.cmd, no); !ok do return nil, {}, 0, fail("the call names an id that is not that machine's"), true
	if c.tab_id != 0 {
		if tab_id, ok = id_pack(no, c.tab_id); !ok do return nil, {}, 0, fail("the call names an id that is not that machine's"), true
	}
	// a pi tab's at most: panel bound to its own tab (the window checks it drives only that
	// session's tabs), else script with no tab
	caller = {kind = .Script, claude = c.caller.claude}
	if c.caller.tab_id != 0 {
		ct, cok := id_pack(no, c.caller.tab_id)
		if !cok do return nil, {}, 0, fail("the call names an id that is not that machine's"), true
		if c.caller.kind != .UI do caller = {kind = .Panel, tab_id = ct, claude = c.caller.claude}
	}
	#partial switch &x in cmd {
	case Browser_Open:
		if x.url != "" {
			u, why, code := remote_url(no, x.url)
			if why != "" do return nil, {}, 0, {error = why, data = code}, true
			x.url = u
		}
	case Browser_Navigate:
		u, why, code := remote_url(no, x.url)
		if why != "" do return nil, {}, 0, {error = why, data = code}, true
		x.url = u
	case Browser_Tabs:
		if caller.kind != .Panel && x.session == 0 do return nil, {}, 0, fail("session is needed"), true
	case Request_Cancel:
		// its request, as this core asked the window for it
		hrid: u64
		for e in rb.calls do if e.machine == no && e.rrid != 0 && e.rrid == x.request_id do hrid = e.hrid
		if hrid == 0 do return nil, {}, 0, fail("no running request with that id"), true
		x.request_id = hrid
	}
	return cmd, caller, tab_id, {}, false
}

// An address another machine's page may open: http or https (and the test fixtures' scheme in test
// builds), never this Mac's loopback (but a port the user forwarded from that machine: the URL then
// names this Mac's end of it), LAN or link-local. why: the refusal; code: its data.
@(private)
remote_url :: proc(no: u64, url: string) -> (out, why, code: string) {
	if len(url) > REMOTE_TEXT_MAX do return "", "the address is too long", NOT_ON_REMOTE
	n, nerr := browser_url_normalize(url)
	if nerr != "" do return "", nerr, ""
	when TEST_HOOKS {
		if strings.has_prefix(strings.to_lower(n, context.temp_allocator), "deckhand-test:") do return n, "", ""
	}
	u, ok := netcap_url_parts(n)
	if !ok || !(strings.equal_fold(u.scheme, "http") || strings.equal_fold(u.scheme, "https")) {
		return "", "another machine's pages open http and https addresses only", `{"code":"refused_address"}`
	}
	switch netcap_host_class(u.host) {
	case .Public, .Name:
		return n, "", "" // a name: the window's CEF looks it up before every request
	case .Loopback:
		if !netcap_forward_host(u.host) do return "", "this Mac's own addresses are not for another machine's pages", `{"code":"refused_address"}`
		local, forwarded := machine_forward_local(no, u.port)
		if !forwarded {
			machine_forward_ask(no, u.port)
			return "", fmt.tprintf("port %d on %s is not forwarded to this Mac: the user is asked to forward it; open the page again once they have", u.port, machine_name(no)), fmt.tprintf(`{{"code":"needs_forward","port":%d}}`, u.port)
		}
		return fmt.tprintf("%s://127.0.0.1:%d%s", strings.to_lower(u.scheme, context.temp_allocator), local, u.rest), "", ""
	case .Private, .Bad:
	}
	return "", "this Mac's local network is not for another machine's pages", `{"code":"refused_address"}`
}

// cmd with every id field packed as machine no's (0 stays 0). False: one does not pack.
@(private = "file")
command_packed :: proc(cmd: Command, no: u64) -> (Command, bool) {
	out := cmd
	v := reflect.get_union_variant(out)
	if v.data == nil do return out, true
	st, ok := runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Struct)
	if !ok do return out, true
	for k in 0 ..< int(st.field_count) {
		if st.types[k].id != typeid_of(u64) || !machine_id_field(st.names[k]) do continue
		p := (^u64)(uintptr(v.data) + st.offsets[k])
		if p^ == 0 do continue
		packed, pok := id_pack(no, p^)
		if !pok do return out, false
		p^ = packed
	}
	return out, true
}

// Every string in cmd (its fields, nested structs, string lists) is UTF-8 and at most REMOTE_TEXT_MAX.
@(private = "file")
remote_strings_ok :: proc(cmd: Command) -> bool {
	c := cmd
	v := reflect.get_union_variant(c)
	if v.data == nil do return true
	return walk(v.data, type_info_of(v.id))

	walk :: proc(data: rawptr, ti: ^runtime.Type_Info) -> bool {
		#partial switch x in runtime.type_info_base(ti).variant {
		case runtime.Type_Info_String:
			s := (^string)(data)^
			return len(s) <= REMOTE_TEXT_MAX && utf8.valid_string(s)
		case runtime.Type_Info_Struct:
			for k in 0 ..< int(x.field_count) do if !walk(rawptr(uintptr(data) + x.offsets[k]), x.types[k]) do return false
		case runtime.Type_Info_Slice:
			sl := (^runtime.Raw_Slice)(data)
			if sl.len > 64 do return false
			for i in 0 ..< sl.len do if !walk(rawptr(uintptr(sl.data) + uintptr(i * x.elem_size)), x.elem) do return false
		}
		return true
	}
}

// The window's finished for one of another machine's calls (tabhost_route.odin's
// tab_host_finished_msg asks first). True: it was one (sent on, or dropped).
machine_tab_host_finished :: proc(obj: json.Object, text: string) -> bool {
	id := string(obj["id"].(json.String) or_else "")
	if id != "" {
		if !strings.has_prefix(id, "x") do return false
		n, nok := strconv.parse_u64(id[1:], 10)
		i := -1
		if nok do for e, k in rb.calls do if e.n == n && !e.answered do i = k
		if i < 0 do return true // one that timed out, or a link that went: dropped
		e := rb.calls[i]
		r, rerr := tab_host_result_read(obj, text)
		if rerr != "" do r = fail(fmt.tprintf("this Mac's window answered badly: %s", rerr))
		changed := bool(obj["changed"].(json.Boolean) or_else false)
		private := bool(obj["private"].(json.Boolean) or_else false)
		wait: time.Duration
		if w, is := obj["wait_ms"].(json.Integer); is && w > 0 do wait = time.Duration(min(w, i64(TAB_HOST_WAIT_MAX / time.Millisecond))) * time.Millisecond
		out := remote_result(e.machine, e.kind, r)
		remote_answer(e.machine, e.id, out, changed, private, wait)
		e.answered = true
		if r.pending && e.hrid != 0 && !e.ended {
			e.deadline = time.tick_add(time.tick_now(), e.base + wait)
			return true
		}
		remote_drop(i)
		return true
	}
	n, nok := obj["request_id"].(json.Integer)
	if !nok || n <= 0 || u64(n) <= REMOTE_RID_BASE do return false
	for e, i in rb.calls do if e.hrid == u64(n) && !e.ended {
		r, rerr := tab_host_result_read(obj, text)
		if rerr != "" do r = fail(fmt.tprintf("this Mac's window answered badly: %s", rerr))
		private := bool(obj["private"].(json.Boolean) or_else false)
		machine_link_send_text(e.machine, tab_host_msg_done(e.rrid, remote_result(e.machine, e.kind, r), private))
		e.ended = true
		if e.answered do remote_drop(i)
		return true
	}
	return true // ours, and nobody waits for it
}

// The window's answer as another machine gets it: its ids unpacked, no confirmation, its data
// bounded.
@(private)
remote_result :: proc(no: u64, kind: typeid, r: Result) -> Result {
	out := r
	out.confirm_token, out.confirm_summary, out.confirm_by_user = "", "", false
	out.created_id = id_machine(r.created_id) == no ? id_local(r.created_id) : 0
	if len(r.data) > REMOTE_DATA_MAX do return {error = "the answer is too large to send to another machine", data = `{"code":"too_large"}`}
	if kind == Browser_Tabs && r.data != "" do out.data = remote_ids_unpacked(no, r.data)
	return out
}

// browser_tabs' list with its tab and session ids as that machine has them.
@(private = "file")
remote_ids_unpacked :: proc(no: u64, data: string) -> string {
	v, err := jg.parse_string(data, .JSON, true, context.temp_allocator)
	if err != nil do return `{"tabs":[]}`
	walk :: proc(v: ^json.Value, no: u64) {
		#partial switch &x in v^ {
		case json.Object:
			for k, &m in x {
				if k == "tab_id" || k == "session" {
					if n, is := m.(json.Integer); is do m = json.Integer(id_machine(u64(n)) == no ? i64(id_local(u64(n))) : 0)
				} else do walk(&m, no)
			}
		case json.Array:
			for &m in x do walk(&m, no)
		}
	}
	walk(&v, no)
	out, merr := json.marshal(v, allocator = context.temp_allocator)
	if merr != nil do return `{"tabs":[]}`
	return string(out)
}

@(private = "file")
remote_answer :: proc(no: u64, id: string, r: Result, changed := false, private := false, wait: time.Duration = 0) {
	machine_link_send_text(no, tab_host_msg_finished(id, r, changed, private, wait))
}

@(private = "file")
remote_drop :: proc(i: int) {
	heap := runtime.heap_allocator()
	e := rb.calls[i]
	ordered_remove(&rb.calls, i)
	delete(e.id, heap)
	free(e, heap)
}

// Past their deadline: dropped (that core's own backstop answers its agent). tab_host_tick.
machine_browser_tick :: proc() {
	now := time.tick_now()
	for i := len(rb.calls) - 1; i >= 0; i -= 1 do if time.tick_diff(rb.calls[i].deadline, now) > 0 do remote_drop(i)
}

// The window went: what it owed another machine ends with no_window. tab_host_detached.
machine_browser_detached :: proc() {
	for i := len(rb.calls) - 1; i >= 0; i -= 1 {
		e := rb.calls[i]
		if !e.answered do remote_answer(e.machine, e.id, no_window())
		else if e.hrid != 0 && !e.ended do machine_link_send_text(e.machine, tab_host_msg_done(e.rrid, no_window()))
		remote_drop(i)
	}
}

// Machine no's link went: its calls go (nothing can answer it).
machine_browser_down :: proc(no: u64) {
	for i := len(rb.calls) - 1; i >= 0; i -= 1 do if rb.calls[i].machine == no do remote_drop(i)
}

// What the window reported of one of machine no's pages (machine_route.odin): to that machine,
// as its window would report it, its tab id unpacked and its text bounded.
machine_browser_update :: proc(no: u64, c: Browser_Update) -> Result {
	u := c
	u.tab_id = id_local(c.tab_id)
	u.url = cut_utf8(c.url, REMOTE_TEXT_MAX)
	u.title = cut_utf8(c.title, 1024)
	u.blocked = "" // its pages open no popups (the window refuses them)
	u.what -= {.Blocked}
	text, _ := tab_host_msg_event(u, "")
	if !machine_link_send_text(no, text) do return machine_offline(no)
	return {ok = true}
}
