package core

// The window's state stream (state_wire.odin, state_read.odin; design §5.8): replicas built
// from state.full and state.delta equal the State they came from, and every field of State
// is either carried or listed as core-only or window-only. Pure: no processes, no files, and
// the global `state` is not touched.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:time"

// ---- helpers: fill any value, compare two ----

// Fills every field of a value of type ti with something not zero (deterministic): strings
// with escapes and non-ASCII, two elements per list, a union's variant picked by the
// counter, every field of a struct, skipped ones too (so the test sees they stay behind).
@(private)
Sw_Fill :: struct {
	n: int,
	a: runtime.Allocator,
}

@(private)
sw_fill :: proc(data: rawptr, ti: ^runtime.Type_Info, f: ^Sw_Fill) {
	f.n += 1
	n := f.n
	if wire_is_time(ti) {
		(^i64)(data)^ = 1_790_000_000_000_000_000 + i64(n)
		return
	}
	if ti.id == typeid_of(Command) {
		(^Command)(data)^ = Close_Tab{tab_id = u64(n), confirm = fmt.aprintf("tok-%d", n, allocator = f.a), comments = .Drop}
		return
	}
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		sw_fill(data, t.base, f)
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(t.field_count) do sw_fill(rawptr(uintptr(data) + t.offsets[k]), t.types[k], f)
	case runtime.Type_Info_Integer:
		v := i64(n % 100 + 1) // small: inside every limit a parser clamps to
		switch ti.size {
		case 1: (^u8)(data)^ = u8(v)
		case 2: (^u16)(data)^ = u16(v)
		case 4: (^u32)(data)^ = u32(v)
		case 8: (^i64)(data)^ = v
		}
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4: (^f32)(data)^ = f32(n) + 0.25
		case 8: (^f64)(data)^ = f64(n) / 3
		}
	case runtime.Type_Info_Boolean:
		(^u8)(data)^ = 1
	case runtime.Type_Info_String:
		(^string)(data)^ = fmt.aprintf("s%d \"q\\\" \n\t ✓  ", n, allocator = f.a)
	case runtime.Type_Info_Enum:
		i := len(t.values) > 1 ? 1 + n % (len(t.values) - 1) : 0
		v := i64(t.values[i])
		switch ti.size {
		case 1: (^u8)(data)^ = u8(v)
		case 2: (^u16)(data)^ = u16(v)
		case 4: (^u32)(data)^ = u32(v)
		case 8: (^i64)(data)^ = v
		}
	case runtime.Type_Info_Array:
		for i in 0 ..< t.count do sw_fill(rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< t.count do sw_fill(rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)
		raw.data, _ = mem.alloc(2 * t.elem_size, t.elem.align, f.a)
		raw.len = 2
		for i in 0 ..< 2 do sw_fill(rawptr(uintptr(raw.data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)
		raw.data, _ = mem.alloc(2 * t.elem_size, t.elem.align, f.a)
		raw.len, raw.cap, raw.allocator = 2, 2, f.a
		for i in 0 ..< 2 do sw_fill(rawptr(uintptr(raw.data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Bit_Set:
		en := runtime.type_info_base(t.elem).variant.(runtime.Type_Info_Enum)
		bits: u64
		for val, i in en.values do if i % 2 == n % 2 do bits |= u64(1) << u64(i64(val) - t.lower)
		switch ti.size {
		case 1: (^u8)(data)^ = u8(bits)
		case 2: (^u16)(data)^ = u16(bits)
		case 4: (^u32)(data)^ = u32(bits)
		case 8: (^u64)(data)^ = bits
		}
	case runtime.Type_Info_Union:
		sw_fill_variant(data, ti, n % len(t.variants), f)
	}
}

// Sets a union (data, of type ti) to its variant i, filled.
@(private)
sw_fill_variant :: proc(data: rawptr, ti: ^runtime.Type_Info, i: int, f: ^Sw_Fill) {
	u := runtime.type_info_base(ti).variant.(runtime.Type_Info_Union)
	mem.zero(data, ti.size)
	sw_fill(data, u.variants[i], f)
	reflect.set_union_variant_typeid(any{data, ti.id}, u.variants[i].id)
}

// Where two values of type ti differ, as (the struct field "Type.field" that holds the
// difference, the full path).
@(private)
sw_diff :: proc(x, y: rawptr, ti: ^runtime.Type_Info, owner, path: string, out: ^[dynamic][2]string) {
	note :: proc(out: ^[dynamic][2]string, owner, path: string) {append(out, [2]string{owner, path})}
	if wire_is_time(ti) {
		if (^i64)(x)^ != (^i64)(y)^ do note(out, owner, path)
		return
	}
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		if st, is := t.base.variant.(runtime.Type_Info_Struct); is {
			for k in 0 ..< int(st.field_count) {
				sw_diff(rawptr(uintptr(x) + st.offsets[k]), rawptr(uintptr(y) + st.offsets[k]), st.types[k], fmt.tprintf("%s.%s", t.name, st.names[k]), fmt.tprintf("%s.%s", path, st.names[k]), out)
			}
			return
		}
		sw_diff(x, y, t.base, owner, path, out)
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(t.field_count) do sw_diff(rawptr(uintptr(x) + t.offsets[k]), rawptr(uintptr(y) + t.offsets[k]), t.types[k], owner, fmt.tprintf("%s.%s", path, t.names[k]), out)
	case runtime.Type_Info_String:
		if (^string)(x)^ != (^string)(y)^ do note(out, owner, path)
	case runtime.Type_Info_Float:
		same := ti.size == 4 ? (^f32)(x)^ == (^f32)(y)^ : (^f64)(x)^ == (^f64)(y)^
		if !same do note(out, owner, path)
	case runtime.Type_Info_Array:
		for i in 0 ..< t.count do sw_diff(rawptr(uintptr(x) + uintptr(i * t.elem_size)), rawptr(uintptr(y) + uintptr(i * t.elem_size)), t.elem, owner, fmt.tprintf("%s[%d]", path, i), out)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< t.count do sw_diff(rawptr(uintptr(x) + uintptr(i * t.elem_size)), rawptr(uintptr(y) + uintptr(i * t.elem_size)), t.elem, owner, fmt.tprintf("%s[%d]", path, i), out)
	case runtime.Type_Info_Slice:
		a, b := (^runtime.Raw_Slice)(x), (^runtime.Raw_Slice)(y)
		if a.len != b.len {
			note(out, owner, fmt.tprintf("%s: %d elements, %d", path, a.len, b.len))
			return
		}
		for i in 0 ..< a.len do sw_diff(rawptr(uintptr(a.data) + uintptr(i * t.elem_size)), rawptr(uintptr(b.data) + uintptr(i * t.elem_size)), t.elem, owner, fmt.tprintf("%s[%d]", path, i), out)
	case runtime.Type_Info_Dynamic_Array:
		a, b := (^runtime.Raw_Dynamic_Array)(x), (^runtime.Raw_Dynamic_Array)(y)
		if a.len != b.len {
			note(out, owner, fmt.tprintf("%s: %d elements, %d", path, a.len, b.len))
			return
		}
		for i in 0 ..< a.len do sw_diff(rawptr(uintptr(a.data) + uintptr(i * t.elem_size)), rawptr(uintptr(b.data) + uintptr(i * t.elem_size)), t.elem, owner, fmt.tprintf("%s[%d]", path, i), out)
	case runtime.Type_Info_Union:
		vx, vy := reflect.union_variant_typeid(any{x, ti.id}), reflect.union_variant_typeid(any{y, ti.id})
		if vx != vy {
			note(out, owner, fmt.tprintf("%s: variant %v, %v", path, vx, vy))
			return
		}
		if vx != nil do sw_diff(x, y, type_info_of(vx), owner, fmt.tprintf("%s(%v)", path, vx), out)
	case:
		if mem.compare_ptrs(x, y, ti.size) != 0 do note(out, owner, path)
	}
}

@(private)
sw_diffs_of :: proc(x, y: ^State) -> [dynamic][2]string {
	out := make([dynamic][2]string, context.temp_allocator)
	sw_diff(x, y, type_info_of(State), "State", "state", &out)
	return out
}

// The skip entry a sw_diff's owner ("Type.field") names, or nil.
@(private)
sw_skip_of :: proc(owner: string) -> ^Wire_Skip {
	dot := strings.index_byte(owner, '.')
	if dot < 0 do return nil
	return wire_skip(owner[:dot], owner[dot + 1:])
}

// ---- a realistic state: projects, chats, a split session, panels, jobs, confirmations ----

@(private = "file")
sample_state :: proc() -> State {
	context.allocator = context.temp_allocator
	s: State
	s.version = 41
	s.next_id = 99
	append(&s.projects, Project{id = 1, cwd = "/Users/x/proj", label = "proj", name = "Project ✓", dir = "/Users/x/.pi/agent/sessions/--proj--", repo = true, newest = time.from_nanoseconds(1_790_000_000_000_000_000)})
	append(&s.projects, Project{id = 2, cwd = "/tmp/t", label = "t", temp = true, parent = 1, group_dir = "/tmp"})
	append(&s.projects, Project{id = 3, group = .Chats, label = "Chats"})
	s.selected_project = 1
	append(&s.sessions, Session{id = "0b0c-uuid", path = "/s/a.jsonl", when_ = "2026-11-08 10:00", title = "fix \"it\"", modified = time.from_nanoseconds(5)})
	append(&s.chats, Session{id = "c1", claude = true, account = "/Users/x/.claude-work", found = true})
	append(&s.sidebar.pinned_projects, "/Users/x/proj")
	s.sidebar.sort[.Sessions] = .Attention
	s.sidebar.folded[.Chats] = true
	s.sidebar.filter = "fi"

	os := Open_Session{id = 10, pi_session_id = "0b0c-uuid", project_id = 1, cwd = "/Users/x/proj", active_tab = 12, title = "fix it", shown_at = 7}
	pi := Tab{id = 11, kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Working, waiting = true, pane = 20}
	append(&pi.blockers, "background shell")
	todos := Panel{id = "todos", title = "Todos"}
	append(&todos.rows, Panel_Row{text = "Todos 1/2", head = true}, Panel_Row{text = "✓ done", tone = .Dim}, Panel_Row{text = "next", tone = .Accent})
	append(&pi.panels, todos, Panel{id = "shells", title = "Shells"})
	pi.reload = Tab_Reload{started = true, version = "0.70.2", stale = true, queued = .Reload, note = "reloaded"}
	sh := Tab{id = 12, kind = Shell_Tab{}, title = "zsh", status = .Exited, exit = {known = true, code = 1}, cwd = "/Users/x/proj/sub", pane = 21, unseen = true}
	sh.prog = Prog_Summary{state = .Blocked, kind = .Permission, progress = 40, app = "make", msg = "allow?", records = 3}
	ed := Tab{id = 13, kind = Editor_Tab{path = "/Users/x/proj/main.odin", view = .Diff_Head, preview = true}, title = "main.odin", pane = 21}
	br := Tab{id = 14, kind = Browser_Tab{url = "https://example.com/?q=1", loading = true, can_back = true}, title = "Example", pane = 21}
	argv := make([]string, 2)
	argv[0], argv[1] = "/usr/bin/engine", "--tab"
	app := Tab{id = 15, kind = App_Tab{argv = argv, cwd = "/Users/x/proj", app_status = .Stalled, exit_code = -1}, title = "engine", pane = 20}
	cl := Claude_Tab{session_id = "cl-1", readonly = true, turn = .Waiting, model = "opus", ended = .Question, account = "/a"}
	append(&cl.held, Claude_Held{id = 3, text = "later", who = "Atlas"})
	claude := Tab{id = 16, kind = cl, title = "Claude", pane = 20}
	append(&os.tabs, pi, sh, ed, br, app, claude)
	// a split: pane 20 left, pane 21 right, the divider at 0.4
	append(&os.panes, Pane{id = 20, active = 11, slot = 0, rect = {1, 2, 3, 4}}, Pane{id = 21, active = 12, slot = 1, frame = {5, 6, 7, 8}})
	append(&os.nodes, Layout_Node{id = 22, dir = .Right, ratio = 0.4, a = 1, b = 2, parent = -1}, Layout_Node{id = 20, leaf = true, pane = 20, parent = 0}, Layout_Node{id = 21, leaf = true, pane = 21, parent = 0})
	os.focused_pane = 21
	append(&os.pane_mru, 20, 21)
	append(&os.comments, Pending_Comment{id = 30, source = .Browser, tab_id = 14, what = "a button", text = "make it blue", created = time.from_nanoseconds(9)})
	os.attach.sending = 5
	append(&s.open_sessions, os)
	home := Open_Session{id = 40, pi_session_id = "home", home = true, root = 0, focused_pane = 41}
	append(&home.tabs, Tab{id = 42, kind = Pi_Tab{readonly = true}, title = "Atlas", pane = 41})
	append(&home.panes, Pane{id = 41, active = 42})
	append(&home.nodes, Layout_Node{id = 41, leaf = true, pane = 41, parent = -1})
	append(&s.open_sessions, home)
	s.home = 40
	s.current_session = 10
	s.focus_widget = "sidebar_filter"
	s.layout = {left_width = 300, right_width = 320.5, left_open = true, drawer_width = 420, left_tab = .Jobs}
	append(&s.layout.panels, "todos", "workers")
	append(&s.layout.collapsed, "shells")
	append(&s.pending_confirmations, Pending_Confirmation{token = "secret-token", summary = "Close zsh?", command = Close_Tab{tab_id = 12}, class = .Tab_Close, caller = {kind = .Control}})
	append(&s.pending_confirmations, Pending_Confirmation{token = "t2", summary = "Quit?", command = Quit{stop_sessions = true}, class = .App_Quit, caller = {kind = .Panel, tab_id = 11, claude = true}})
	s.comments_ask = {tab_id = 14, session = 10}
	s.settings.confirm[.Control][.Tab_Close] = .Trusted
	s.settings.confirm_close[.Shell] = .Never
	s.settings.theme = .Warm
	s.settings.bell_off = {.Jobs, .Waiting}
	s.settings.folders[.Chats] = "/Users/x/Chats"
	s.settings.job_limits = {max_cost = 2.5, timeout = 600, day = 10}
	append(&s.settings.pi_extensions, Pi_Extension_Choice{name = "guardrails", on = true})
	job := Job_Row{id = "j1", name = "nightly", schedule = "0 3 * * *", enabled = true, running = true, next_due = 1_790_000_000, last_status = "ok"}
	append(&job.recent, "2026-11-07 ok", "2026-11-06 failed")
	append(&job.needs_you, "approve the deploy")
	append(&s.jobs, job, Job_Row{id = "j2", name = "weekly", err = "bad schedule"})
	s.jobs_unread = 1
	append(&s.notices.items, Notice{id = 1, kind = .Waiting, session = 10, title = "fix it", read = true})
	append(&s.notices.os_recent, Os_Recent{session = 10})
	s.reload.gen = 3
	append(&s.reload.changed, "~/.pi/agent/settings.json")
	append(&s.claude_history, Claude_Record{id = "cl-1", cwd = "/Users/x/proj", title = "hello", used = 12})
	s.home_model = "provider/model"
	return s
}

@(private = "file")
replica_of :: proc(t: ^testing.T, text: string) -> State {
	r: State
	err := replica_apply(&r, text, context.temp_allocator)
	testing.expectf(t, err == "", "replica_apply: %s", err)
	return r
}

// encode -> decode -> encode is the same, and the replica equals the state but for the
// core-only and window-only fields, which it never gets.
@(test)
state_wire_replica_round_trip :: proc(t: ^testing.T) {
	s := sample_state()
	text := state_full_json(&s)
	testing.expect(t, strings.contains(text, `"secret-token"`), "the window's stream carries tokens (it confirms with them)")
	testing.expect(t, !strings.contains(text, "provider/model"), "core-only fields stay in the core")
	r := replica_of(t, text)
	testing.expect(t, state_full_json(&r) == text, "encode -> decode -> encode is the same")
	for d in sw_diffs_of(&s, &r) {
		sk := sw_skip_of(d[0])
		testing.expectf(t, sk != nil && sk.why != .Section, "differs: %s (%s)", d[1], d[0])
	}
	testing.expect_value(t, r.version, 41)
	testing.expect_value(t, r.next_id, 0)
	testing.expect_value(t, len(r.open_sessions[0].tabs), 6)
	testing.expect_value(t, r.open_sessions[0].tabs[0].panels[0].rows[2].tone, Panel_Tone.Accent)
	testing.expect_value(t, r.open_sessions[0].nodes[0].ratio, 0.4)
	testing.expect_value(t, r.open_sessions[0].panes[0].rect, [4]f32{}) // window-only
	testing.expect_value(t, r.pending_confirmations[0].token, "secret-token")
	if c, is := r.pending_confirmations[1].command.(Quit); is do testing.expect(t, c.stop_sessions)
	else do testing.expect(t, false, "the confirmation's command came back")
	testing.expect_value(t, r.settings.bell_off, bit_set[Bell_Group]{.Jobs, .Waiting})
	testing.expect_value(t, r.open_sessions[0].tabs[4].kind.(App_Tab).exit_code, -1)
	// the replica owns what it holds: freed with the allocator it was built with
	h: State
	testing.expect_value(t, replica_apply(&h, text, context.allocator), "")
	replica_free(&h, context.allocator)
	testing.expect_value(t, len(h.open_sessions), 0)
}

// Every field of State, at any depth, is carried (a state with every field set comes back
// with it), or is listed in STATE_WIRE_SKIPS as core-only or window-only (and the replica
// never gets it). Every top-level field is in one section; every skip names a real field.
@(test)
state_wire_completeness :: proc(t: ^testing.T) {
	// a type the encoding has no form for (a pointer, a map) would be written as null
	problems := make([dynamic]string, context.temp_allocator)
	seen := make(map[typeid]bool, context.temp_allocator)
	wire_type_problems(type_info_of(State), "State", &problems, &seen)
	for p in problems do testing.expectf(t, false, "no wire form: %s", p)

	// every top-level field: in exactly one section, or skipped
	st := runtime.type_info_base(type_info_of(State)).variant.(runtime.Type_Info_Struct)
	for k in 0 ..< int(st.field_count) {
		name := st.names[k]
		n := 0
		for sec in STATE_SECTIONS do for f in sec.fields do if f == name do n += 1
		if wire_skip("State", name) != nil do n += 1
		testing.expectf(t, n == 1, "State.%s: in %d sections or skip entries (want 1)", name, n)
	}
	for sec in STATE_SECTIONS do for f in sec.fields {
		found := false
		for k in 0 ..< int(st.field_count) do if st.names[k] == f do found = true
		testing.expectf(t, found, "section %s: State has no field %s", sec.name, f)
	}
	// every skip entry names a field that exists (a renamed field is noticed)
	for sk in STATE_WIRE_SKIPS {
		found := false
		walk :: proc(ti: ^runtime.Type_Info, sk: Wire_Skip, found: ^bool, seen: ^map[typeid]bool) {
			if seen[ti.id] do return
			seen[ti.id] = true
			#partial switch v in ti.variant {
			case runtime.Type_Info_Named:
				if s, is := v.base.variant.(runtime.Type_Info_Struct); is {
					for k in 0 ..< int(s.field_count) {
						if v.name == sk.type && s.names[k] == sk.field do found^ = true
						walk(s.types[k], sk, found, seen)
					}
				} else do walk(v.base, sk, found, seen)
			case runtime.Type_Info_Dynamic_Array: walk(v.elem, sk, found, seen)
			case runtime.Type_Info_Slice: walk(v.elem, sk, found, seen)
			case runtime.Type_Info_Array: walk(v.elem, sk, found, seen)
			case runtime.Type_Info_Enumerated_Array: walk(v.elem, sk, found, seen)
			case runtime.Type_Info_Union: for x in v.variants do walk(x, sk, found, seen)
			}
		}
		seen2 := make(map[typeid]bool, context.temp_allocator)
		walk(type_info_of(State), sk, &found, &seen2)
		testing.expectf(t, found, "skip entry %s.%s: no such field under State", sk.type, sk.field)
	}

	// every field set, every tab kind: what comes back differs only in skipped fields, and
	// those the replica never has
	f := Sw_Fill{a = context.temp_allocator}
	s: State
	sw_fill(&s, type_info_of(State), &f)
	kinds := runtime.type_info_base(type_info_of(Tab_Kind)).variant.(runtime.Type_Info_Union)
	for &os, i in s.open_sessions {
		tabs := make([dynamic]Tab, len(kinds.variants), context.temp_allocator)
		for &tab, j in tabs {
			sw_fill(&tab, type_info_of(Tab), &f)
			tab.id = u64(1000 * (i + 1) + j)
			sw_fill_variant(&tab.kind, type_info_of(Tab_Kind), j, &f)
		}
		os.tabs = tabs
		os.id = u64(i + 1)
	}
	text := state_full_json(&s)
	r := replica_of(t, text)
	testing.expect(t, state_full_json(&r) == text, "encode -> decode -> encode is the same (every field set)")
	carried := 0
	for d in sw_diffs_of(&s, &r) {
		sk := sw_skip_of(d[0])
		if sk == nil || sk.why == .Section {
			testing.expectf(t, false, "not carried and not listed core-only: %s (field %s)", d[1], d[0])
			continue
		}
		carried += 1
	}
	testing.expect(t, carried > 0, "the skipped fields were set, and stayed behind")
	// the skipped fields are zero in the replica
	check_zero :: proc(t: ^testing.T, data: rawptr, ti: ^runtime.Type_Info, path: string, seen: int) {
		if seen > 8 do return
		#partial switch v in ti.variant {
		case runtime.Type_Info_Named:
			if s, is := v.base.variant.(runtime.Type_Info_Struct); is {
				for k in 0 ..< int(s.field_count) {
					p := rawptr(uintptr(data) + s.offsets[k])
					if sk := wire_skip(v.name, s.names[k]); sk != nil && sk.why != .Section && sk.why != .Envelope {
						testing.expectf(t, mem.check_zero_ptr(p, s.types[k].size), "%s.%s (%v) reached the replica", path, s.names[k], sk.why)
						continue
					}
					check_zero(t, p, s.types[k], fmt.tprintf("%s.%s", path, s.names[k]), seen + 1)
				}
			}
		case runtime.Type_Info_Dynamic_Array:
			raw := (^runtime.Raw_Dynamic_Array)(data)
			for i in 0 ..< raw.len do check_zero(t, rawptr(uintptr(raw.data) + uintptr(i * v.elem_size)), v.elem, fmt.tprintf("%s[%d]", path, i), seen + 1)
		}
	}
	check_zero(t, &r, type_info_of(State), "State", 0)
}

// Deltas: only what changed is sent, a closed session's sections go as null, and a replica
// kept up to date by deltas equals one built from a fresh state.full.
@(test)
state_wire_deltas :: proc(t: ^testing.T) {
	s := sample_state()
	sent: State_Sent
	defer state_sent_free(&sent)
	r := replica_of(t, state_full_json(&s, &sent))

	_, changed := state_delta_json(&s, &sent)
	testing.expect(t, !changed, "nothing changed: no delta")

	apply :: proc(t: ^testing.T, r: ^State, s: ^State, sent: ^State_Sent) -> string {
		text, ok := state_delta_json(s, sent)
		testing.expect(t, ok, "a delta")
		err := replica_apply(r, text, context.temp_allocator)
		testing.expectf(t, err == "", "delta: %s (%s)", err, text)
		testing.expect(t, state_full_json(r) == state_full_json(s), "the replica equals a fresh state.full")
		return text
	}

	// a panel row: only that tab's panels section
	s.version += 1
	s.open_sessions[0].tabs[0].panels[0].rows[0].text = "Todos 2/2"
	d := apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"panels:11"`) && !strings.contains(d, `"tabs:10"`) && !strings.contains(d, `"projects"`), d)

	// a tab's title: its tabs section, and its panels stay in the replica
	s.version += 1
	s.open_sessions[0].tabs[0].title = "pi ✓"
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"tabs:10"`) && !strings.contains(d, `"panels:`), d)
	testing.expect_value(t, len(r.open_sessions[0].tabs[0].panels), 2)

	// a divider: the session's panes section only
	s.version += 1
	s.open_sessions[0].nodes[0].ratio = 0.55
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"panes:10"`) && !strings.contains(d, `"sessions"`), d)

	// a session field: the sessions section; tabs and panes stay
	s.version += 1
	s.open_sessions[0].title = "renamed"
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"sessions"`) && !strings.contains(d, `"tabs:`), d)
	testing.expect_value(t, len(r.open_sessions[0].tabs), 6)
	testing.expect_value(t, len(r.open_sessions[0].nodes), 3)

	// a new session with its tabs and panes, in one delta
	s.version += 1
	ns := Open_Session{id = 50, pi_session_id = "new", project_id = 1}
	ns.tabs = make([dynamic]Tab, context.temp_allocator)
	ns.panes = make([dynamic]Pane, context.temp_allocator)
	append(&ns.tabs, Tab{id = 51, kind = Pi_Tab{}, title = "pi", pane = 52})
	append(&ns.panes, Pane{id = 52, active = 51})
	append(&s.open_sessions, ns)
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"tabs:50"`) && strings.contains(d, `"panes:50"`) && strings.contains(d, `"panels:51"`), d)

	// closing it: its sections go as null
	s.version += 1
	pop(&s.open_sessions)
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"tabs:50":null`) && strings.contains(d, `"panels:51":null`), d)

	// a confirmation, settings and jobs
	s.version += 1
	ordered_remove(&s.pending_confirmations, 0)
	s.settings.theme = .Ghostty
	s.jobs[0].running = false
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"confirmations"`) && strings.contains(d, `"settings"`) && strings.contains(d, `"jobs"`), d)

	// a version bump alone is still a message (the window waits on it, M3-F)
	s.version += 1
	d = apply(t, &r, &s, &sent)
	testing.expect(t, strings.contains(d, `"sections":{}`), d)
	testing.expect_value(t, r.version, s.version)
}

// A message that does not fit is refused whole: the replica stays as it was.
@(test)
state_wire_refusals :: proc(t: ^testing.T) {
	s := sample_state()
	text := state_full_json(&s)
	r := replica_of(t, text)
	bad := [?]string {
		``,
		`[]`,
		`{"type":"state.delta","sections":{}}`, // no version
		`{"type":"state.full","version":1}`,
		`{"type":"state.full","version":1,"state":{}}`, // no sessions
		`{"type":"state.delta","version":2,"sections":{"tabs:777":[]}}`, // no such session
		`{"type":"state.delta","version":2,"sections":{"panels:777":[]}}`, // no such tab
		`{"type":"state.delta","version":2,"sections":{"projects":{"projects":[{"id":"x"}]},"tabs:777":[]}}`,
		`{"type":"state.delta","version":2,"sections":{"settings":{"settings":{"theme":7.5}}}}`,
		`{"type":"state.delta","version":2,"sections":{"projects":{"projects":{}}}}`,
		`{"type":"state.delta","version":2,"sections":{"confirmations":{"pending_confirmations":[{"command":{"type":"no_such"}}]}}}`,
		`{"type":"other","version":2}`,
		strings.repeat("[", 100_000, context.temp_allocator),
		"{\"type\":\"state.delta\",\"version\":2,\"sections\":{\"view\":{\"focus_widget\":\"\xff\"}}}",
	}
	for b in bad {
		err := replica_apply(&r, b, context.temp_allocator)
		testing.expectf(t, err != "", "refused: %.80s", b)
		testing.expectf(t, state_full_json(&r) == text, "the replica is unchanged after: %.80s", b)
	}
	// a newer core's additions are ignored: an unknown section, key, enum name, union variant
	newer := `{"type":"state.delta","version":42,"sections":{"machines":[],"tabs:10":[{"id":11,"kind":{"quantum_tab":{}},"status":"teleported","colour":"red"}],"panels:11":[]}}`
	testing.expect_value(t, replica_apply(&r, newer, context.temp_allocator), "")
	testing.expect_value(t, len(r.open_sessions[0].tabs), 1)
	testing.expect_value(t, r.open_sessions[0].tabs[0].status, Tab_Status.Running)
	testing.expect(t, r.open_sessions[0].tabs[0].kind == nil)
}

// A replica frees what it replaces and what it held: a full, deltas of every kind, refused
// messages (half-decoded sections), then replica_free leave nothing allocated.
@(test)
state_wire_replica_frees_what_it_holds :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)

	s := sample_state()
	sent: State_Sent
	defer state_sent_free(&sent)
	r: State
	testing.expect_value(t, replica_apply(&r, state_full_json(&s, &sent), a), "")
	step :: proc(t: ^testing.T, r: ^State, s: ^State, sent: ^State_Sent, a: runtime.Allocator) {
		s.version += 1
		text, _ := state_delta_json(s, sent)
		testing.expect_value(t, replica_apply(r, text, a), "")
	}
	s.open_sessions[0].tabs[0].panels[0].rows[0].text = "changed"
	step(t, &r, &s, &sent, a)
	s.open_sessions[0].title = "renamed"
	s.open_sessions[0].tabs[1].title = "renamed too"
	s.open_sessions[0].nodes[0].ratio = 0.7
	step(t, &r, &s, &sent, a)
	ordered_remove(&s.open_sessions, 1) // a session goes, with its tabs, panes and panels
	step(t, &r, &s, &sent, a)
	ordered_remove(&s.pending_confirmations, 0)
	step(t, &r, &s, &sent, a)
	half := [?]string {
		`{"type":"state.delta","version":9,"sections":{"tabs:10":[{"id":1,"title":"x"},{"id":"bad"}]}}`,
		`{"type":"state.delta","version":9,"sections":{"panels:11":[{"id":"p","rows":[{"text":"x"},{"text":3}]}]}}`,
		`{"type":"state.delta","version":9,"sections":{"panes:10":{"panes":[{"id":1}],"nodes":"x"}}}`,
		`{"type":"state.delta","version":9,"sections":{"projects":{"projects":[{"cwd":"a"},{"cwd":1}]}}}`,
		`{"type":"state.delta","version":9,"sections":{"sessions":{"open_sessions":[{"id":10,"cwd":"x"}]},"tabs:999":[{"title":"leak?"}]}}`,
	}
	for h in half do testing.expect(t, replica_apply(&r, h, a) != "", h)
	testing.expect(t, state_full_json(&r) == state_full_json(&s), "the replica is still the state")
	testing.expectf(t, len(track.allocation_map) > 50, "the replica's memory is the allocator's (%d allocations)", len(track.allocation_map))
	replica_free(&r, a)
	testing.expectf(t, len(track.allocation_map) == 0, "%d allocations left after replica_free", len(track.allocation_map))
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees", len(track.bad_free_array))
}

// A pending confirmation's command travels as its own JSON (write_command, command_from_value).
// One that does not parse back would make every message with the confirmations section
// fail, so the window could never catch up: each command that can be parked (a confirm
// class in the table) must come back as itself.
@(test)
state_wire_every_parked_command_comes_back :: proc(t: ^testing.T) {
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	n := 0
	for vt, i in u.variants {
		f := Sw_Fill{a = context.temp_allocator}
		cmd: Command
		sw_fill_variant(&cmd, type_info_of(Command), i, &f)
		spec := command_spec(command_type(cmd))
		if spec == nil || spec.confirm == nil do continue
		n += 1
		s: State
		s.open_sessions = make([dynamic]Open_Session, context.temp_allocator)
		s.pending_confirmations = make([dynamic]Pending_Confirmation, context.temp_allocator)
		append(&s.pending_confirmations, Pending_Confirmation{token = "tok", summary = "sure?", command = cmd, class = spec.confirm.?, caller = {kind = .Control}})
		r: State
		err := replica_apply(&r, state_full_json(&s), context.temp_allocator)
		if !testing.expectf(t, err == "", "%s parked: the replica refuses it: %s", spec.type, err) do continue
		testing.expectf(t, len(r.pending_confirmations) == 1 && reflect.union_variant_typeid(r.pending_confirmations[0].command) == vt.id, "%s parked: came back as %v", spec.type, r.pending_confirmations[0].command)
	}
	testing.expectf(t, n >= 10, "%d commands with a confirm class", n)
}
