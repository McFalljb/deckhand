package core

// The window's state stream (docs/plans/background-core.md §5.8): `state.full{version, state}`,
// then `state.delta{version, sections}`, sent on the framed wire's JSON channel. The window
// decodes them into a replica with State's shape (state_read.odin).
//
// This is not get_state's snapshot (json_write.odin's write_state). That one is the agents'
// view: redacted (no confirmation tokens), with derived fields (hidden_reason, agent_status,
// on_screen, light) and window facts (Window_Hooks), and without about 30 of State's fields.
// A replica needs State itself, so this encoder writes State's fields as they are, split into
// get_state's top-level sections plus one per open session's tabs and panes and one per tab's
// panels:
//
//   projects, sessions, view, settings, jobs, confirmations, notifications, reload, claude,
//   tabs:<session id>, panes:<session id>, panels:<tab id>
//
// (`update` in §5.8 is not State: Deckhand's updates live in update.odin. Its name is kept.)
// `machines` (machines.odin) is the other machines over SSH and their links' status.
//
// The encoding follows the types, so a field added to State is on the wire at once, and the
// completeness test (state_wire_test.odin) fails on a field that is neither carried nor listed
// below as core-only or window-only:
// - a struct is an object of its fields, keyed by field name (or a `json:"name"` tag);
// - an enum is its value's name, lowercased ("not_started"); an unknown value is its number;
// - a union is null or {"<variant, lowercased>": value}; Maybe(T) is T or null;
// - an enumerated array is an object keyed by the enum's names; a bit_set an array of names;
// - arrays, slices and dynamic arrays are arrays; time.Time and time.Tick are nanoseconds;
// - a Command (a pending confirmation's) is the command's own JSON (write_command, not redacted:
//   the window resends it with the token, main.odin confirm_pending).
//
// The stream carries confirmation tokens and other things get_state keeps from agents. It is
// for the window (the ui caller) only; M3-F must never offer state.subscribe to another caller.

import "base:runtime"
import "core:math"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:time"

// Why a field is not in the stream's encoding of its struct.
Wire_Skip_Why :: enum u8 {
	Core_Only, // the core's bookkeeping, or meaningless outside its process
	Window_Only, // the window's own (pixels)
	Section, // carried by its own section (tabs:, panes:, panels:)
	Envelope, // carried by the message itself (version)
}

Wire_Skip :: struct {
	type, field: string, // the struct's type name and the field's
	why:         Wire_Skip_Why,
	note:        string,
}

// Every field of a type reachable from State that the stream's struct encoding leaves out.
STATE_WIRE_SKIPS := [?]Wire_Skip {
	{"State", "version", .Envelope, "the message's version"},
	{"State", "next_id", .Core_Only, "ids are the core's to make; a window never makes one"},
	{"State", "home_model", .Core_Only, "agent.odin's memory of the model Atlas last started with (whether --model goes again)"},
	{"State", "home_fork_from", .Core_Only, "home.odin's old session file while Atlas's fork is not on disk yet"},
	{"Open_Session", "checked", .Core_Only, "the session-file poll's last tick (a monotonic clock of the core's process)"},
	{"Open_Session", "title_size", .Core_Only, "the title cache: session_file's size when the title was read"},
	{"Open_Session", "mtime", .Core_Only, "the title cache: session_file's modification time then"},
	{"Tab_Reload", "inflight", .Core_Only, "the request id of what went to the bridge"},
	{"Tab_Reload", "pid", .Core_Only, "the old pi's process while a restart waits for it to exit"},
	{"Tab_Reload", "stopped", .Core_Only, "when it was hung up on (a monotonic clock of the core's process)"},
	{"Tab_Reload", "sent_gen", .Core_Only, "State.reload.gen when the reload was sent"},
	{"Notices", "os_recent", .Core_Only, "OS notification pacing (not in the snapshot either)"},
	{"Notices", "burst_start", .Core_Only, "OS notification pacing"},
	{"Notices", "burst_n", .Core_Only, "OS notification pacing"},
	{"Pane", "rect", .Window_Only, "framebuffer pixels the window lays out (§10.2)"},
	{"Pane", "frame", .Window_Only, "framebuffer pixels the window lays out (§10.2)"},
	{"Open_Session", "tabs", .Section, "tabs:<session id>"},
	{"Open_Session", "panes", .Section, "panes:<session id>"},
	{"Open_Session", "nodes", .Section, "panes:<session id>"},
	{"Open_Session", "root", .Section, "panes:<session id>"},
	{"Open_Session", "focused_pane", .Section, "panes:<session id>"},
	{"Open_Session", "pane_mru", .Section, "panes:<session id>"},
	{"Tab", "panels", .Section, "panels:<tab id>"},
}

// The fixed sections, in order, and the State fields each one carries.
State_Section :: struct {
	name:   string,
	fields: []string,
}

STATE_SECTIONS := [?]State_Section {
	{"projects", {"projects", "selected_project"}},
	{"sessions", {"sessions", "chats", "open_sessions", "current_session", "home"}},
	{"view", {"sidebar", "files", "focus_widget", "layout", "home_open", "system_light", "home_dir_prev"}},
	{"settings", {"settings"}},
	{"jobs", {"jobs", "jobs_unread", "jobs_notified", "machine_jobs"}},
	{"confirmations", {"pending_confirmations", "comments_ask", "holder_ask"}},
	{"notifications", {"notices", "agent"}},
	{"reload", {"reload"}},
	{"claude", {"claude_history", "claude_readonly_ids", "claude_disk", "claude_disk_chats"}},
	{"live", {"live"}}, // a separate core's runtime the window shows (core_live.odin)
	{"machines", {"machines"}}, // other machines over SSH and their links (machines.odin)
}

// Sections named in §5.8 that are not State (nothing sends them yet).
STATE_SECTIONS_RESERVED := [?]string{"update"}

// The per-session and per-tab sections: "tabs:5", "panes:5", "panels:12".
SECTION_TABS :: "tabs:"
SECTION_PANES :: "panes:"
SECTION_PANELS :: "panels:"

// An open session's fields in its panes:<id> section (an object of them).
SESSION_PANE_FIELDS := [?]string{"panes", "nodes", "root", "focused_pane", "pane_mru"}

STATE_FULL :: "state.full"
STATE_DELTA :: "state.delta"

// What the window was last sent: each section's JSON (owned). One per subscriber.
State_Sent :: struct {
	sections: map[string]string,
	version:  u64,
}

state_sent_free :: proc(s: ^State_Sent) {
	for k, v in s.sections {
		delete(k)
		delete(v)
	}
	delete(s.sections)
	s^ = {}
}

// Every section of s as (name, JSON), in order: the fixed ones, then each open session's tabs
// and panes, then each tab's panels (temp allocator).
state_sections :: proc(s: ^State) -> [dynamic][2]string {
	out := make([dynamic][2]string, context.temp_allocator)
	for sec in STATE_SECTIONS {
		b := strings.builder_make(context.temp_allocator)
		wire_write_fields(&b, s, type_info_of(State), sec.fields)
		append(&out, [2]string{sec.name, strings.to_string(b)})
	}
	for &os in s.open_sessions {
		b := strings.builder_make(context.temp_allocator)
		wire_write(&b, &os.tabs, type_info_of(type_of(os.tabs)))
		append(&out, [2]string{section_name(SECTION_TABS, os.id), strings.to_string(b)})
		p := strings.builder_make(context.temp_allocator)
		wire_write_fields(&p, &os, type_info_of(Open_Session), SESSION_PANE_FIELDS[:])
		append(&out, [2]string{section_name(SECTION_PANES, os.id), strings.to_string(p)})
	}
	for &os in s.open_sessions do for &t in os.tabs {
		b := strings.builder_make(context.temp_allocator)
		wire_write(&b, &t.panels, type_info_of(type_of(t.panels)))
		append(&out, [2]string{section_name(SECTION_PANELS, t.id), strings.to_string(b)})
	}
	return out
}

section_name :: proc(prefix: string, id: u64) -> string {
	buf: [24]u8
	return strings.concatenate({prefix, strconv.write_uint(buf[:], id, 10)}, context.temp_allocator)
}

// state.full: every section (temp allocator). sent, if given, now holds them.
state_full_json :: proc(s: ^State, sent: ^State_Sent = nil) -> string {
	secs := state_sections(s)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"v":`)
	strings.write_int(&b, PROTOCOL_VERSION)
	strings.write_string(&b, `,"type":"` + STATE_FULL + `","version":`)
	strings.write_u64(&b, s.version)
	strings.write_string(&b, `,"state":{`)
	for x, i in secs {
		if i > 0 do strings.write_byte(&b, ',')
		json_quote(&b, x[0])
		strings.write_byte(&b, ':')
		strings.write_string(&b, x[1])
	}
	strings.write_string(&b, "}}")
	if sent != nil {
		state_sent_free(sent)
		for x in secs do sent.sections[strings.clone(x[0])] = strings.clone(x[1])
		sent.version = s.version
	}
	return strings.to_string(b)
}

// state.delta: the sections that differ from what sent holds, and null for each section that
// went (a closed session's, a closed tab's); sent is updated. ok false: nothing changed (no
// message). Temp allocator.
state_delta_json :: proc(s: ^State, sent: ^State_Sent) -> (text: string, ok: bool) {
	secs := state_sections(s)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"v":`)
	strings.write_int(&b, PROTOCOL_VERSION)
	strings.write_string(&b, `,"type":"` + STATE_DELTA + `","version":`)
	strings.write_u64(&b, s.version)
	strings.write_string(&b, `,"sections":{`)
	n := 0
	now := make(map[string]bool, len(secs), context.temp_allocator)
	for x in secs {
		now[x[0]] = true
		if old, has := sent.sections[x[0]]; has && old == x[1] do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		json_quote(&b, x[0])
		strings.write_byte(&b, ':')
		strings.write_string(&b, x[1])
		if old, has := sent.sections[x[0]]; has {
			delete(old)
			sent.sections[x[0]] = strings.clone(x[1])
		} else {
			sent.sections[strings.clone(x[0])] = strings.clone(x[1])
		}
	}
	gone := make([dynamic]string, context.temp_allocator)
	for k in sent.sections do if !now[k] do append(&gone, k)
	for k in gone {
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		json_quote(&b, k)
		strings.write_string(&b, ":null")
		key, v := delete_key(&sent.sections, k)
		delete(v)
		delete(key)
	}
	strings.write_string(&b, "}}")
	if n == 0 && sent.version == s.version do return "", false
	sent.version = s.version
	return strings.to_string(b), true
}

// ---- the encoding ----

// The skip entry for a struct's field, or nil.
wire_skip :: proc(type_name, field: string) -> ^Wire_Skip {
	if type_name == "" do return nil
	for &s in STATE_WIRE_SKIPS do if s.field == field && s.type == type_name do return &s
	return nil
}

// A field's key on the wire: its `json:"name"` tag, else its name.
wire_key :: proc(name: string, tag: string) -> string {
	if v, ok := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "json"); ok && v != "" {
		if c := strings.index_byte(v, ','); c >= 0 do return v[:c]
		return v
	}
	return name
}

// Writes a name lowercased (Odin's Ada_Case names on the wire: "Not_Started" -> "not_started").
wire_write_lower :: proc(b: ^strings.Builder, name: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(name) {
		c := name[i]
		strings.write_byte(b, 'A' <= c && c <= 'Z' ? c + 32 : c)
	}
	strings.write_byte(b, '"')
}

// The struct `data` (of type ti) as an object of only the named fields, in that order.
wire_write_fields :: proc(b: ^strings.Builder, data: rawptr, ti: ^runtime.Type_Info, fields: []string) {
	st := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	strings.write_byte(b, '{')
	for name, i in fields {
		if i > 0 do strings.write_byte(b, ',')
		for k in 0 ..< int(st.field_count) do if st.names[k] == name {
			json_quote(b, wire_key(name, st.tags[k]))
			strings.write_byte(b, ':')
			wire_write(b, rawptr(uintptr(data) + st.offsets[k]), st.types[k])
		}
	}
	strings.write_byte(b, '}')
}

// Whether ti is one of the types written as nanoseconds.
wire_is_time :: proc(ti: ^runtime.Type_Info) -> bool {
	return ti.id == typeid_of(time.Time) || ti.id == typeid_of(time.Tick)
}

// One value as JSON. A type the encoding has no form for (pointers, maps, procs) is null;
// the completeness test finds those first (wire_type_problems).
wire_write :: proc(b: ^strings.Builder, data: rawptr, ti: ^runtime.Type_Info) {
	if wire_is_time(ti) {
		strings.write_i64(b, (^i64)(data)^)
		return
	}
	if ti.id == typeid_of(Command) {
		write_command(b, (^Command)(data)^)
		return
	}
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		if st, is := v.base.variant.(runtime.Type_Info_Struct); is {
			wire_write_struct(b, data, v.name, st)
			return
		}
		wire_write(b, data, v.base)
	case runtime.Type_Info_Struct:
		wire_write_struct(b, data, "", v)
	case runtime.Type_Info_Integer:
		if v.signed do strings.write_i64(b, wire_int(data, ti.size))
		else do strings.write_u64(b, wire_uint(data, ti.size))
	case runtime.Type_Info_Float:
		f: f64
		switch ti.size {
		case 4: f = f64((^f32)(data)^)
		case 8: f = (^f64)(data)^
		case:
			strings.write_string(b, "null")
			return
		}
		if math.is_nan(f) || math.is_inf(f) {
			strings.write_string(b, "null")
			return
		}
		buf: [32]u8
		strings.write_string(b, strings.trim_prefix(strconv.write_float(buf[:], f, 'g', -1, ti.size * 8), "+"))
	case runtime.Type_Info_Boolean:
		strings.write_string(b, wire_uint(data, ti.size) != 0 ? "true" : "false")
	case runtime.Type_Info_String:
		if v.is_cstring {
			strings.write_string(b, "null")
			return
		}
		json_quote(b, (^string)(data)^)
	case runtime.Type_Info_Enum:
		x := wire_int(data, ti.size)
		for val, i in v.values do if i64(val) == x {
			wire_write_lower(b, v.names[i])
			return
		}
		strings.write_i64(b, x)
	case runtime.Type_Info_Array:
		wire_write_elems(b, data, v.count, v.elem_size, v.elem)
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)
		wire_write_elems(b, raw.data, raw.len, v.elem_size, v.elem)
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)
		wire_write_elems(b, raw.data, raw.len, v.elem_size, v.elem)
	case runtime.Type_Info_Enumerated_Array:
		en := runtime.type_info_base(v.index).variant.(runtime.Type_Info_Enum)
		strings.write_byte(b, '{')
		n := 0
		for val, i in en.values {
			k := int(i64(val) - i64(v.min_value))
			if k < 0 || k >= v.count do continue
			if n > 0 do strings.write_byte(b, ',')
			n += 1
			wire_write_lower(b, en.names[i])
			strings.write_byte(b, ':')
			wire_write(b, rawptr(uintptr(data) + uintptr(k * v.elem_size)), v.elem)
		}
		strings.write_byte(b, '}')
	case runtime.Type_Info_Bit_Set:
		en, is_enum := runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Enum)
		if !is_enum || ti.size > 8 {
			strings.write_string(b, "null")
			return
		}
		bits := wire_uint(data, ti.size)
		strings.write_byte(b, '[')
		n := 0
		for val, i in en.values {
			bit := i64(val) - v.lower
			if bit < 0 || bit >= 64 || bits & (u64(1) << u64(bit)) == 0 do continue
			if n > 0 do strings.write_byte(b, ',')
			n += 1
			wire_write_lower(b, en.names[i])
		}
		strings.write_byte(b, ']')
	case runtime.Type_Info_Union:
		tag := reflect.get_union_variant_raw_tag(any{data, ti.id})
		idx := v.no_nil ? tag : tag - 1
		if idx < 0 || idx >= i64(len(v.variants)) {
			strings.write_string(b, "null")
			return
		}
		vt := v.variants[idx]
		if len(v.variants) == 1 && !v.no_nil { // Maybe(T)
			wire_write(b, data, vt)
			return
		}
		strings.write_byte(b, '{')
		wire_write_lower(b, wire_variant_name(vt))
		strings.write_byte(b, ':')
		wire_write(b, data, vt)
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

// A union variant's name on the wire (before lowercasing): its type's name.
wire_variant_name :: proc(ti: ^runtime.Type_Info) -> string {
	if n, is := ti.variant.(runtime.Type_Info_Named); is do return n.name
	return ""
}

@(private = "file")
wire_write_elems :: proc(b: ^strings.Builder, data: rawptr, n, size: int, elem: ^runtime.Type_Info) {
	strings.write_byte(b, '[')
	for i in 0 ..< n {
		if i > 0 do strings.write_byte(b, ',')
		wire_write(b, rawptr(uintptr(data) + uintptr(i * size)), elem)
	}
	strings.write_byte(b, ']')
}

@(private = "file")
wire_write_struct :: proc(b: ^strings.Builder, data: rawptr, name: string, st: runtime.Type_Info_Struct) {
	strings.write_byte(b, '{')
	n := 0
	for k in 0 ..< int(st.field_count) {
		if wire_skip(name, st.names[k]) != nil do continue
		if n > 0 do strings.write_byte(b, ',')
		n += 1
		json_quote(b, wire_key(st.names[k], st.tags[k]))
		strings.write_byte(b, ':')
		wire_write(b, rawptr(uintptr(data) + st.offsets[k]), st.types[k])
	}
	strings.write_byte(b, '}')
}

wire_int :: proc(data: rawptr, size: int) -> i64 {
	switch size {
	case 1: return i64((^i8)(data)^)
	case 2: return i64((^i16)(data)^)
	case 4: return i64((^i32)(data)^)
	case 8: return (^i64)(data)^
	}
	return 0
}

wire_uint :: proc(data: rawptr, size: int) -> u64 {
	switch size {
	case 1: return u64((^u8)(data)^)
	case 2: return u64((^u16)(data)^)
	case 4: return u64((^u32)(data)^)
	case 8: return (^u64)(data)^
	}
	return 0
}

// Why a type reachable from ti has no form on the wire ("" each = none): pointers, maps,
// procs, any, cstrings, unnamed union variants, bit_sets of non-enums, odd sizes. Paths like
// "State.open_sessions[].tabs[].kind". The completeness test wants none.
wire_type_problems :: proc(ti: ^runtime.Type_Info, path: string, out: ^[dynamic]string, seen: ^map[typeid]bool) {
	if wire_is_time(ti) || ti.id == typeid_of(Command) do return
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		if seen[ti.id] do return
		seen[ti.id] = true
		if st, is := v.base.variant.(runtime.Type_Info_Struct); is {
			for k in 0 ..< int(st.field_count) {
				if s := wire_skip(v.name, st.names[k]); s != nil && s.why != .Section do continue
				wire_type_problems(st.types[k], strings.concatenate({v.name, ".", st.names[k]}, context.temp_allocator), out, seen)
			}
			return
		}
		wire_type_problems(v.base, path, out, seen)
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(v.field_count) do wire_type_problems(v.types[k], strings.concatenate({path, ".", v.names[k]}, context.temp_allocator), out, seen)
	case runtime.Type_Info_Integer, runtime.Type_Info_Boolean:
		if ti.size != 1 && ti.size != 2 && ti.size != 4 && ti.size != 8 do append(out, strings.concatenate({path, ": integer size"}, context.temp_allocator))
	case runtime.Type_Info_Enum:
	case runtime.Type_Info_Float:
		if ti.size != 4 && ti.size != 8 do append(out, strings.concatenate({path, ": float size"}, context.temp_allocator))
	case runtime.Type_Info_String:
		if v.is_cstring do append(out, strings.concatenate({path, ": cstring"}, context.temp_allocator))
	case runtime.Type_Info_Array: wire_type_problems(v.elem, strings.concatenate({path, "[]"}, context.temp_allocator), out, seen)
	case runtime.Type_Info_Slice: wire_type_problems(v.elem, strings.concatenate({path, "[]"}, context.temp_allocator), out, seen)
	case runtime.Type_Info_Dynamic_Array: wire_type_problems(v.elem, strings.concatenate({path, "[]"}, context.temp_allocator), out, seen)
	case runtime.Type_Info_Enumerated_Array: wire_type_problems(v.elem, strings.concatenate({path, "[]"}, context.temp_allocator), out, seen)
	case runtime.Type_Info_Bit_Set:
		if _, is := runtime.type_info_base(v.elem).variant.(runtime.Type_Info_Enum); !is || ti.size > 8 do append(out, strings.concatenate({path, ": bit_set of a non-enum"}, context.temp_allocator))
	case runtime.Type_Info_Union:
		for vt in v.variants {
			if len(v.variants) > 1 && wire_variant_name(vt) == "" do append(out, strings.concatenate({path, ": an unnamed union variant"}, context.temp_allocator))
			wire_type_problems(vt, path, out, seen)
		}
	case:
		append(out, strings.concatenate({path, ": no wire form (pointer, map, proc, any)"}, context.temp_allocator))
	}
}
