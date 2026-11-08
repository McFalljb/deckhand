package main

// The app commands' wire layer and the records an app sends over its socket (design §4: the
// core owns the command layer, its JSON and the socket): the commands' copy and free for the
// inbox (inbox.odin), an app's results and events as sent (socket.odin's reader threads), the
// events kept per tab and topic (app_events), the boxes it last listed (tab.boxes: state, and
// what Inspect draws), and where app_screenshot writes. The app's process, frames and drawing
// are the window's (app_tab.odin).

import "base:runtime"
import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

APP_STATUS_NAMES := [App_Status]string {
	.Starting       = "starting",
	.Running        = "running",
	.Stalled        = "stalled",
	.Not_Responding = "not_responding",
	.Exited         = "exited",
}

app_command_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	s :: proc(x: string, a := context.allocator) -> string {return strings.clone(x, a)}
	ss :: proc(x: []string, a := context.allocator) -> []string {
		out := make([]string, len(x), a)
		for v, i in x do out[i] = strings.clone(v, a)
		return out
	}
	#partial switch c in cmd {
	case New_App_Tab:   return New_App_Tab{session = c.session, name = s(c.name, allocator), argv = ss(c.argv, allocator), command = s(c.command, allocator), cwd = s(c.cwd, allocator), title = s(c.title, allocator)}
	case App_Close:     return App_Close{tab_id = c.tab_id, confirm = s(c.confirm, allocator), comments = c.comments}
	case App_Input:     return App_Input{tab_id = c.tab_id, events = ss(c.events, allocator)}
	case App_Events:    return App_Events{tab_id = c.tab_id, topic = s(c.topic, allocator), since = c.since, limit = c.limit}
	case App_Call:      return App_Call{tab_id = c.tab_id, method = s(c.method, allocator), params = s(c.params, allocator), timeout_ms = c.timeout_ms}
	case App_Call_Done: return App_Call_Done{tab_id = c.tab_id, wire = s(c.wire, allocator), ok = c.ok, error = s(c.error, allocator), code = s(c.code, allocator), data = s(c.data, allocator), from_worker = c.from_worker, file = s(c.file, allocator)}
	}
	return cmd
}

app_command_free :: proc(cmd: Command, allocator := context.allocator) {
	ss :: proc(x: []string, a := context.allocator) {
		for v in x do delete(v, a)
		delete(x, a)
	}
	#partial switch c in cmd {
	case New_App_Tab:
		ss(c.argv, allocator)
		delete(c.name, allocator)
		delete(c.command, allocator)
		delete(c.cwd, allocator)
		delete(c.title, allocator)
	case App_Close:  delete(c.confirm, allocator)
	case App_Input:  ss(c.events, allocator)
	case App_Events: delete(c.topic, allocator)
	case App_Call:
		delete(c.method, allocator)
		delete(c.params, allocator)
	case App_Call_Done:
		delete(c.wire, allocator)
		delete(c.error, allocator)
		delete(c.code, allocator)
		delete(c.file, allocator)
		delete(c.data, allocator)
	}
}

// An app's answer, from its line as sent (socket.odin): data verbatim (no
// re-marshal); an error's code and its other fields (traceback, path…) go in data.
App_Result :: struct {
	id:    string,
	ok:    bool,
	error: string,
	code:  string,
	data:  string, // one JSON value
}

app_result_of :: proc(line: string) -> (r: App_Result, valid: bool) {
	if !json_valid(line) do return // strict: what is passed on as sent must be JSON
	top, ok := json_members_raw(strings.trim_space(line))
	if !ok do return
	res := ""
	for m in top {
		switch m.key {
		case "id":     r.id, _ = json_string_of(m.raw)
		case "result": res = m.raw
		}
	}
	members, rok := json_members_raw(res)
	if !rok do return
	r.data = "{}"
	for m in members {
		switch m.key {
		case "ok":    r.ok = m.raw == "true"
		case "error": r.error, _ = json_string_of(m.raw)
		case "code":  r.code, _ = json_string_of(m.raw)
		case "data":  r.data = m.raw
		}
	}
	if r.ok do return r, true
	// an error: everything but ok and error, in the app's order (code, traceback, data…)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	n := 0
	for m in members {
		if m.key == "ok" || m.key == "error" do continue
		if n > 0 do strings.write_byte(&b, ',')
		json_quote(&b, m.key)
		strings.write_byte(&b, ':')
		strings.write_string(&b, m.raw)
		n += 1
	}
	strings.write_byte(&b, '}')
	r.data = strings.to_string(b)
	return r, true
}

// A JSON string literal's value (temp), or ok=false.
@(private = "file")
json_string_of :: proc(raw: string) -> (string, bool) {
	v, err := jg.parse_string(raw, .JSON, true, context.temp_allocator)
	s, is := v.(json.String)
	return s, err == nil && is
}

// Events from apps (tab.log, ...), kept per tab and topic; written by the
// socket's reader threads, read by app_events.
@(private = "file")
App_Event_Row :: struct {
	seq:  u64,
	line: string,
}

@(private = "file")
events_mu: sync.Mutex

@(private = "file")
events: map[u64]map[string][dynamic]App_Event_Row

@(private = "file")
events_seq: u64

// One event line from an app ({"type":"event","event":"tab.log",…}), kept
// as sent: app_events pastes it into its reply, so it must be exactly one
// JSON object with nothing after it (json.parse_string ignores what follows;
// a re-marshal would change the app's numbers and keys).
app_event_in :: proc(tab_id: u64, event, line: string) {
	if event == "tab.boxes" {
		app_boxes_in(tab_id, line) // state, not history: replaces the last list, not kept as an event
		return
	}
	topic := strings.trim_prefix(event, "tab.")
	if topic == "" || len(topic) > 64 do return
	out := strings.trim_space(line)
	if !json_valid(out) do return // strict: it is passed on as sent
	{
		context.allocator = context.temp_allocator
		p := json.make_parser(out, .JSON, false, context.temp_allocator)
		v, err := json.parse_value(&p)
		if _, is := v.(json.Object); err != nil || !is || p.curr_token.kind != .EOF do return
	}
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	m := events[tab_id]
	if !(topic in m) && len(m) >= APP_EVENT_TOPICS do return // a flood of topic names
	rows := m[topic] if topic in m else nil
	events_seq += 1
	append(&rows, App_Event_Row{seq = events_seq, line = strings.clone(out)})
	if len(rows) > APP_EVENTS_MAX {
		delete(rows[0].line)
		ordered_remove(&rows, 0)
	}
	if topic in m do m[topic] = rows
	else do m[strings.clone(topic)] = rows
	events[tab_id] = m
}

app_events_json :: proc(tab_id: u64, topic: string, since: u64, limit: int) -> string {
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"events":[`)
	n, last := 0, since
	lim := limit > 0 ? min(limit, APP_EVENTS_MAX) : 100
	if m, ok := events[tab_id]; ok do if rows, ok2 := m[topic]; ok2 {
		for r in rows {
			if r.seq <= since do continue
			if n >= lim do break
			if n > 0 do strings.write_byte(&b, ',')
			fmt.sbprintf(&b, `{{"seq":%d,"event":%s}}`, r.seq, r.line)
			last = r.seq
			n += 1
		}
	}
	fmt.sbprintf(&b, `],"next":%d}}`, last)
	return strings.to_string(b)
}

app_event_topic_count :: proc(tab_id: u64) -> int {
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	return len(events[tab_id])
}

// A closed tab's events go.
app_events_forget :: proc(tab_id: u64) {
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	if m, ok := events[tab_id]; ok {
		for k, rows in m {
			for r in rows do delete(r.line)
			delete(rows)
			delete(k)
		}
		delete(m)
		delete_key(&events, tab_id)
	}
}

// Inspect boxes: written by the socket's readers, read under boxes_mu by app_tab.odin's hover
// and drawing.
boxes_mu: sync.Mutex
boxes: map[u64][]App_Box // per tab, the app's last tab.boxes (written by the socket's readers)
boxes_dirty: bool // atomic: new boxes arrived (redraw an inspected tab)

// A tab.boxes event's list: {"boxes":[{id, label?, rect:{x,y,w,h}}]}, at
// most APP_BOXES_MAX, entries without an id or a rect skipped, labels
// capped (none: the id). ok=false if `boxes` is not a list. Heap-owned:
// app_boxes_free.
app_boxes_parse :: proc(line: string) -> (out: []App_Box, ok: bool) {
	v, err := jg.parse_string(line, .JSON, true, context.temp_allocator)
	obj, _ := v.(json.Object) // not an object (or refused: nil): no boxes, no panic
	list, is := obj["boxes"].(json.Array)
	if err != nil || !is do return nil, false
	ha := runtime.heap_allocator()
	res := make([dynamic]App_Box, 0, min(len(list), APP_BOXES_MAX), ha)
	num :: proc(o: json.Object, k: string) -> (f32, bool) {
		#partial switch n in o[k] {
		case json.Integer: return f32(n), true
		case json.Float:   return f32(n), true
		}
		return 0, false
	}
	for x in list {
		if len(res) >= APP_BOXES_MAX do break
		o, _ := x.(json.Object)
		id, has_id := o["id"].(json.String)
		r, has_r := o["rect"].(json.Object)
		if !has_id || id == "" || !has_r do continue
		rx, ok1 := num(r, "x")
		ry, ok2 := num(r, "y")
		rw, ok3 := num(r, "w")
		rh, ok4 := num(r, "h")
		if !(ok1 && ok2 && ok3 && ok4) || rw <= 0 || rh <= 0 do continue
		label, _ := o["label"].(json.String)
		if label == "" do label = id
		append(&res, App_Box{id = strings.clone(cap_utf8(id, APP_METHOD_MAX), ha), label = strings.clone(cap_utf8(label, APP_BOX_LABEL_MAX), ha), rect = {rx, ry, rw, rh}})
	}
	return res[:], true
}

// At most n bytes of s, cut at a character, with "…" when cut.
@(private = "file")
cap_utf8 :: proc(s: string, n: int) -> string {
	if len(s) <= n do return s
	i := n
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return strings.concatenate({s[:i], "…"}, context.temp_allocator)
}

app_boxes_free :: proc(list: []App_Box) {
	ha := runtime.heap_allocator()
	for b in list {
		delete(b.id, ha)
		delete(b.label, ha)
	}
	delete(list, ha)
}

// The box at (x, y) (logical tab px): the last listed that holds it (drawn
// on top), -1 = none.
app_box_at :: proc(list: []App_Box, x, y: f32) -> int {
	#reverse for b, i in list {
		if x >= b.rect.x && y >= b.rect.y && x < b.rect.x + b.rect.w && y < b.rect.y + b.rect.h do return i
	}
	return -1
}

// A tab.boxes event (a socket reader): the tab's boxes are replaced.
@(private = "file")
app_boxes_in :: proc(tab_id: u64, line: string) {
	context.allocator = runtime.heap_allocator() // the global map outlives the reader's line
	list, ok := app_boxes_parse(line)
	if !ok do return
	sync.lock(&boxes_mu)
	old := boxes[tab_id] or_else nil
	boxes[tab_id] = list
	sync.unlock(&boxes_mu)
	if old != nil do app_boxes_free(old)
	sync.atomic_store(&boxes_dirty, true)
}

app_boxes_forget :: proc(tab_id: u64) {
	sync.lock(&boxes_mu)
	old, had := boxes[tab_id]
	if had do delete_key(&boxes, tab_id)
	sync.unlock(&boxes_mu)
	if had do app_boxes_free(old)
}

// How many boxes the app sent last (state, tests).
app_box_count :: proc(tab_id: u64) -> int {
	sync.lock(&boxes_mu)
	defer sync.unlock(&boxes_mu)
	return len(boxes[tab_id] or_else nil)
}

// Where app_screenshot writes its PNGs: <data dir>/apps/shots (build/test-data
// in test mode without one), absolute.
app_shots_dir :: proc(allocator := context.allocator) -> string {
	root := home_root != "" ? home_root : "build/test-data"
	cwd := ""
	if !filepath.is_abs(root) do cwd, _ = os.get_working_directory(context.temp_allocator)
	dir, _ := filepath.join({cwd, root, "apps", "shots"}, allocator)
	return dir
}
