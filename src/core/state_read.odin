package core

// The window's replica of the core's State (docs/plans/background-core.md §5.8): state.full
// and state.delta (state_wire.odin) decoded into a value with State's shape. The core-only and
// window-only fields (STATE_WIRE_SKIPS) stay as they are: zero in a replica the window has
// not touched.
//
// A message is applied whole or not at all: every section is decoded first, and the replica
// changes only if all of them decode and every tabs:/panes:/panels: section names a session
// or tab the replica will have. An error leaves it as it was; the window then asks for a
// state.full again.
//
// Forward-compatible, as a newer core may add things (grow-only, schema/released-v1.json):
// unknown keys and sections are ignored; an unknown enum name, an enum number outside the
// enum's values, or an unknown union variant reads as the zero value (so a names table indexed
// by it never goes out of range: Tab_Status reads Running, Caller_Kind Internal, Command_Class
// Tab_Close, a Tab_Kind nil); a command of an unknown type reads as a nil Command, a
// confirmation the window cannot confirm. A type mismatch is an error.
//
// Bounded: a message is refused when what it decodes to passes 64x its length (at least
// 1 MiB, at most 512 MiB), before that memory is taken; the layout tree's indices (root, a,
// b, parent) must point into its nodes.
//
// Memory: everything a replica holds is allocated with the allocator given to
// replica_apply; replica_free frees it. A section that is replaced is freed then, so a
// window must not keep pointers into a replica across messages.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"
import jg "../jsonguard"

// What a message may still decode to, in bytes (replica_apply sets it; wire_read spends it).
@(thread_local, private = "file")
read_budget: int

READ_BUDGET_PER_BYTE :: 64
READ_BUDGET_MIN :: 1 << 20
READ_BUDGET_MAX :: 512 << 20
@(private = "file")
TOO_LARGE :: ": too large (the message decodes to more than its limit)"

// Takes n bytes from the budget; false: refused.
@(private = "file")
budget_take :: proc(n: int) -> bool {
	if n < 0 || n > read_budget do return false
	read_budget -= n
	return true
}

// Applies one state.full or state.delta message to r. "" = applied.
replica_apply :: proc(r: ^State, text: string, allocator := context.allocator) -> string {
	read_budget = clamp(READ_BUDGET_PER_BYTE * len(text), READ_BUDGET_MIN, READ_BUDGET_MAX)
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return "invalid JSON"
	msg, ok := v.(json.Object)
	if !ok do return "a state message must be an object"
	type, _ := msg["type"].(json.String)
	version, vok := msg["version"].(json.Integer)
	if !vok || version < 0 do return "missing version"
	full := false
	sections: json.Object
	switch type {
	case STATE_FULL:
		full = true
		sections, ok = msg["state"].(json.Object)
		if !ok do return "state.full: missing state"
	case STATE_DELTA:
		sections, ok = msg["sections"].(json.Object)
		if !ok do return "state.delta: missing sections"
	case:
		return "not a state message"
	}
	context.allocator = allocator
	return replica_commit(r, sections, full, u64(version), allocator)
}

// Frees everything r holds and zeroes it.
replica_free :: proc(r: ^State, allocator := context.allocator) {
	wire_free(r, type_info_of(State), allocator)
}

// ---- applying ----

// STATE_SECTIONS' index of "sessions" (the open sessions the other sections name)
@(private = "file")
SESSIONS_SECTION :: 1

@(private = "file")
Pending_Tabs :: struct {
	session: u64,
	tabs:    [dynamic]Tab,
	gone:    bool, // null: the session went
}

@(private = "file")
Pending_Panes :: struct {
	session: u64,
	os:      Open_Session, // only its pane fields
	gone:    bool,
}

@(private = "file")
Pending_Panels :: struct {
	tab:    u64,
	panels: [dynamic]Panel,
	gone:   bool,
}

@(private = "file")
replica_commit :: proc(r: ^State, sections: json.Object, full: bool, version: u64, a: runtime.Allocator) -> string {
	assert(STATE_SECTIONS[SESSIONS_SECTION].name == "sessions")
	ti := type_info_of(State)
	fixed: State // the fixed sections' fields, decoded
	has_fixed: [len(STATE_SECTIONS)]bool
	tabs := make([dynamic]Pending_Tabs, context.temp_allocator)
	panes := make([dynamic]Pending_Panes, context.temp_allocator)
	panels := make([dynamic]Pending_Panels, context.temp_allocator)
	err := ""
	defer if err != "" {
		wire_free(&fixed, ti, a)
		for &p in tabs do wire_free(&p.tabs, type_info_of(type_of(p.tabs)), a)
		for &p in panes do wire_free(&p.os, type_info_of(Open_Session), a)
		for &p in panels do wire_free(&p.panels, type_info_of(type_of(p.panels)), a)
	}

	// 1. decode every section
	for name, value in sections {
		fixed_i := -1
		for sec, i in STATE_SECTIONS do if sec.name == name do fixed_i = i
		if fixed_i >= 0 {
			obj, is := value.(json.Object)
			if !is {
				err = fmt.tprintf("%s: not an object", name)
				return err
			}
			for f in STATE_SECTIONS[fixed_i].fields {
				if e := wire_read_field(obj, &fixed, ti, f, a); e != "" {
					err = fmt.tprintf("%s.%s", name, e)
					return err
				}
			}
			has_fixed[fixed_i] = true
			continue
		}
		prefix, id, per := section_id(name)
		if !per do continue // a section this window does not know (a newer core's)
		_, null := value.(json.Null)
		switch prefix {
		// each is listed before it is decoded, so the defer frees a half-decoded one
		case SECTION_TABS:
			append(&tabs, Pending_Tabs{session = id, gone = null})
			p := &tabs[len(tabs) - 1]
			if !null do if e := wire_read(value, &p.tabs, type_info_of(type_of(p.tabs)), a); e != "" {
				err = fmt.tprintf("%s%s", name, e)
				return err
			}
		case SECTION_PANES:
			append(&panes, Pending_Panes{session = id, gone = null})
			p := &panes[len(panes) - 1]
			if !null {
				obj, is := value.(json.Object)
				if !is {
					err = fmt.tprintf("%s: not an object", name)
					return err
				}
				for f in SESSION_PANE_FIELDS do if e := wire_read_field(obj, &p.os, type_info_of(Open_Session), f, a); e != "" {
					err = fmt.tprintf("%s.%s", name, e)
					return err
				}
			}
		case SECTION_PANELS:
			append(&panels, Pending_Panels{tab = id, gone = null})
			p := &panels[len(panels) - 1]
			if !null do if e := wire_read(value, &p.panels, type_info_of(type_of(p.panels)), a); e != "" {
				err = fmt.tprintf("%s%s", name, e)
				return err
			}
		}
	}
	if full && !has_fixed[SESSIONS_SECTION] {
		err = "state.full: no sessions section"
		return err
	}
	for &p in panes do if !p.gone {
		if e := layout_problem(&p.os); e != "" {
			err = fmt.tprintf("panes:%d: %s", p.session, e)
			return err
		}
	}

	// 2. check every per-session and per-tab section names one the replica will have
	sessions := has_fixed[SESSIONS_SECTION] ? fixed.open_sessions[:] : r.open_sessions[:]
	session_known :: proc(list: []Open_Session, id: u64) -> bool {
		for os in list do if os.id == id do return true
		return false
	}
	for p in tabs do if !p.gone && !session_known(sessions, p.session) {
		err = fmt.tprintf("tabs:%d: no such open session", p.session)
		return err
	}
	for p in panes do if !p.gone && !session_known(sessions, p.session) {
		err = fmt.tprintf("panes:%d: no such open session", p.session)
		return err
	}
	// the tabs as they will be: a session's tabs: section in this message, else the replica's
	// (a session that stays keeps them)
	will_be := make(map[u64]bool, context.temp_allocator)
	pending_of := make(map[u64]^Pending_Tabs, len(tabs), context.temp_allocator)
	for &pt in tabs do if !pt.gone do pending_of[pt.session] = &pt
	for os in sessions {
		list: []Tab
		if pt, has := pending_of[os.id]; has do list = pt.tabs[:]
		else if !full do if old := replica_session(r, os.id); old != nil do list = old.tabs[:]
		for t in list do will_be[t.id] = true
	}
	for p in panels {
		if p.gone do continue
		if !will_be[p.tab] {
			err = fmt.tprintf("panels:%d: no such tab", p.tab)
			return err
		}
	}

	// 3. commit (nothing below fails)
	if full do replica_free(r, a)
	// tabs that stay keep their panels (panels:<tab> carries them), in whichever session they
	// are now: each old tab by id, before what is replaced is freed
	old_tabs := make(map[u64]^Tab, context.temp_allocator)
	for &os in r.open_sessions do for &t in os.tabs do old_tabs[t.id] = &t
	for sec, i in STATE_SECTIONS {
		if !has_fixed[i] do continue
		if sec.name == "sessions" {
			// open sessions that stay keep their tabs and panes (their own sections carry them)
			for &ns in fixed.open_sessions do for &old in r.open_sessions do if old.id == ns.id {
				ns.tabs, old.tabs = old.tabs, {}
				for f in SESSION_PANE_FIELDS do field_swap(&ns, &old, type_info_of(Open_Session), f)
			}
		}
		for f in sec.fields do field_swap(r, &fixed, ti, f)
	}
	for &p in tabs do if !p.gone do for &nt in p.tabs {
		if old, has := old_tabs[nt.id]; has do nt.panels, old.panels = old.panels, {}
	}
	wire_free(&fixed, ti, a) // what was replaced
	// (checked above: every session and tab named here is in the replica now)
	for &p in tabs {
		if p.gone do continue
		os := replica_session(r, p.session)
		if os == nil {
			wire_free(&p.tabs, type_info_of(type_of(p.tabs)), a)
			continue
		}
		wire_free(&os.tabs, type_info_of(type_of(os.tabs)), a)
		os.tabs, p.tabs = p.tabs, {}
	}
	for &p in panes {
		if p.gone do continue
		os := replica_session(r, p.session)
		if os == nil {
			wire_free(&p.os, type_info_of(Open_Session), a)
			continue
		}
		for f in SESSION_PANE_FIELDS do field_swap(os, &p.os, type_info_of(Open_Session), f)
		wire_free(&p.os, type_info_of(Open_Session), a)
	}
	tab_of := make(map[u64]^Tab, context.temp_allocator)
	if len(panels) > 0 do for &os in r.open_sessions do for &t in os.tabs do tab_of[t.id] = &t
	for &p in panels {
		if p.gone do continue
		t := tab_of[p.tab]
		if t == nil {
			wire_free(&p.panels, type_info_of(type_of(p.panels)), a)
			continue
		}
		wire_free(&t.panels, type_info_of(type_of(t.panels)), a)
		t.panels, p.panels = p.panels, {}
	}
	r.version = version
	return ""
}

@(private = "file")
replica_session :: proc(r: ^State, id: u64) -> ^Open_Session {
	for &os in r.open_sessions do if os.id == id do return &os
	return nil
}

// Why an open session's layout tree cannot be walked ("" = it can): root and every node's
// a, b and parent point into nodes (parent -1: the root).
@(private = "file")
layout_problem :: proc(os: ^Open_Session) -> string {
	n := len(os.nodes)
	if n == 0 {
		if os.root != 0 do return "root with no nodes"
		return ""
	}
	if os.root < 0 || os.root >= n do return "root out of range"
	for nd, i in os.nodes {
		if nd.a < 0 || nd.a >= n || nd.b < 0 || nd.b >= n do return fmt.tprintf("nodes[%d]: a child out of range", i)
		if nd.parent < -1 || nd.parent >= n do return fmt.tprintf("nodes[%d]: parent out of range", i)
	}
	return ""
}

// "tabs:5" -> (SECTION_TABS, 5, true).
@(private = "file")
section_id :: proc(name: string) -> (prefix: string, id: u64, ok: bool) {
	for p in ([]string{SECTION_TABS, SECTION_PANES, SECTION_PANELS}) {
		if !strings.has_prefix(name, p) do continue
		n, nok := strconv.parse_u64_of_base(name[len(p):], 10)
		if !nok do return "", 0, false
		return p, n, true
	}
	return "", 0, false
}

// Swaps the named field of two values of struct type ti.
@(private = "file")
field_swap :: proc(x, y: rawptr, ti: ^runtime.Type_Info, name: string) {
	st := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	for k in 0 ..< int(st.field_count) do if st.names[k] == name {
		size := st.types[k].size
		tmp := make([]u8, size, context.temp_allocator)
		px, py := rawptr(uintptr(x) + st.offsets[k]), rawptr(uintptr(y) + st.offsets[k])
		mem.copy(raw_data(tmp), px, size)
		mem.copy(px, py, size)
		mem.copy(py, raw_data(tmp), size)
	}
}

// ---- decoding ----

// The named field of the struct at data (type ti) from obj (zero when absent).
@(private = "file")
wire_read_field :: proc(obj: json.Object, data: rawptr, ti: ^runtime.Type_Info, name: string, a: runtime.Allocator) -> string {
	st := runtime.type_info_base(ti).variant.(runtime.Type_Info_Struct)
	for k in 0 ..< int(st.field_count) do if st.names[k] == name {
		v, has := obj[wire_key(name, st.tags[k])]
		if !has do return ""
		if e := wire_read(v, rawptr(uintptr(data) + st.offsets[k]), st.types[k], a); e != "" do return strings.concatenate({name, e}, context.temp_allocator)
		return ""
	}
	return strings.concatenate({name, ": not a field"}, context.temp_allocator)
}

// One value from JSON into data (zeroed, of type ti), allocating with a. "" = read; else
// where and why (": wants a string", "[3].id: wants an integer").
wire_read :: proc(v: json.Value, data: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) -> string {
	if wire_is_time(ti) {
		n, ok := v.(json.Integer)
		if !ok do return ": wants an integer (ns)"
		(^i64)(data)^ = n
		return ""
	}
	if ti.id == typeid_of(Command) {
		if _, null := v.(json.Null); null do return ""
		// parsed into temp memory, then copied whole into a (the parser's own frees on a
		// failure do not cover every command; this way nothing of it stays behind)
		cmd, err := command_from_value(v, context.temp_allocator)
		if err != "" {
			// a type this window does not know (a newer core's): a nil command
			if o, is := v.(json.Object); is {
				if type, has := o["type"].(json.String); has && type != "" && strings.has_prefix(err, "unknown command ") do return ""
			}
			return strings.concatenate({": ", err}, context.temp_allocator)
		}
		if !wire_clone(&cmd, data, ti, a) do return TOO_LARGE
		return ""
	}
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		if st, is := t.base.variant.(runtime.Type_Info_Struct); is do return wire_read_struct(v, data, t.name, st, a)
		return wire_read(v, data, t.base, a)
	case runtime.Type_Info_Struct:
		return wire_read_struct(v, data, "", t, a)
	case runtime.Type_Info_Integer:
		n, ok := v.(json.Integer)
		if !ok do return ": wants an integer"
		wire_put_int(data, ti.size, n)
	case runtime.Type_Info_Float:
		f: f64
		#partial switch x in v {
		case json.Float: f = x
		case json.Integer: f = f64(x)
		case json.Null: f = 0 // NaN and infinities are written as null
		case: return ": wants a number"
		}
		switch ti.size {
		case 4: (^f32)(data)^ = f32(f)
		case 8: (^f64)(data)^ = f
		}
	case runtime.Type_Info_Boolean:
		x, ok := v.(json.Boolean)
		if !ok do return ": wants true or false"
		wire_put_int(data, ti.size, x ? 1 : 0)
	case runtime.Type_Info_String:
		s, ok := v.(json.String)
		if !ok do return ": wants a string"
		if t.is_cstring do return ""
		if !budget_take(len(s)) do return TOO_LARGE
		(^string)(data)^ = strings.clone(s, a)
	case runtime.Type_Info_Enum:
		#partial switch x in v {
		case json.String:
			for name, i in t.names do if strings.equal_fold(name, x) {
				wire_put_int(data, ti.size, i64(t.values[i]))
				return ""
			}
			// a value this window does not know: the zero value
		case json.Integer:
			for val in t.values do if i64(val) == x {
				wire_put_int(data, ti.size, x)
				return ""
			}
			// outside the enum: the zero value
		case:
			return ": wants an enum name"
		}
	case runtime.Type_Info_Array:
		arr, ok := v.(json.Array)
		if !ok do return ": wants an array"
		for i in 0 ..< min(len(arr), t.count) do if e := wire_read(arr[i], rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, a); e != "" do return elem_err(i, e)
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
		arr, ok := v.(json.Array)
		if !ok do return ": wants an array"
		elem := t.(runtime.Type_Info_Slice).elem if is_slice(ti) else t.(runtime.Type_Info_Dynamic_Array).elem
		size := elem.size
		buf: rawptr
		if !budget_take(len(arr) * size) do return TOO_LARGE
		if len(arr) > 0 {
			b, aerr := mem.alloc(len(arr) * size, elem.align, a)
			if aerr != nil do return ": out of memory"
			buf = b
		}
		if is_slice(ti) {
			raw := (^runtime.Raw_Slice)(data)
			raw.data, raw.len = buf, len(arr)
		} else {
			raw := (^runtime.Raw_Dynamic_Array)(data)
			raw.data, raw.len, raw.cap, raw.allocator = buf, len(arr), len(arr), a
		}
		for x, i in arr do if e := wire_read(x, rawptr(uintptr(buf) + uintptr(i * size)), elem, a); e != "" do return elem_err(i, e)
	case runtime.Type_Info_Enumerated_Array:
		obj, ok := v.(json.Object)
		if !ok do return ": wants an object"
		en := runtime.type_info_base(t.index).variant.(runtime.Type_Info_Enum)
		for val, i in en.values {
			k := int(i64(val) - i64(t.min_value))
			if k < 0 || k >= t.count do continue
			for key, x in obj do if strings.equal_fold(key, en.names[i]) {
				if e := wire_read(x, rawptr(uintptr(data) + uintptr(k * t.elem_size)), t.elem, a); e != "" do return strings.concatenate({".", key, e}, context.temp_allocator)
			}
		}
	case runtime.Type_Info_Bit_Set:
		arr, ok := v.(json.Array)
		if !ok do return ": wants an array of names"
		en, is_enum := runtime.type_info_base(t.elem).variant.(runtime.Type_Info_Enum)
		if !is_enum do return ""
		bits: u64
		for x in arr {
			name, sok := x.(json.String)
			if !sok do return ": wants an array of names"
			for n, i in en.names do if strings.equal_fold(n, name) {
				bit := i64(en.values[i]) - t.lower
				if bit >= 0 && bit < 64 do bits |= u64(1) << u64(bit)
			}
		}
		wire_put_int(data, ti.size, i64(bits))
	case runtime.Type_Info_Union:
		if _, null := v.(json.Null); null do return ""
		// the tag first: a variant that fails halfway is freed with the union
		if len(t.variants) == 1 && !t.no_nil { // Maybe(T)
			reflect.set_union_variant_typeid(any{data, ti.id}, t.variants[0].id)
			return wire_read(v, data, t.variants[0], a)
		}
		obj, ok := v.(json.Object)
		if !ok || len(obj) != 1 do return ": wants {\"variant\": value}"
		for key, x in obj {
			for vt in t.variants do if strings.equal_fold(wire_variant_name(vt), key) {
				reflect.set_union_variant_typeid(any{data, ti.id}, vt.id)
				if e := wire_read(x, data, vt, a); e != "" do return strings.concatenate({".", key, e}, context.temp_allocator)
				return ""
			}
			// a variant this window does not know: nil (or, no_nil, the first variant's zero)
		}
	}
	return ""
}

@(private = "file")
is_slice :: proc(ti: ^runtime.Type_Info) -> bool {
	_, is := ti.variant.(runtime.Type_Info_Slice)
	return is
}

@(private = "file")
elem_err :: proc(i: int, e: string) -> string {
	return fmt.tprintf("[%d]%s", i, e)
}

@(private = "file")
wire_read_struct :: proc(v: json.Value, data: rawptr, name: string, st: runtime.Type_Info_Struct, a: runtime.Allocator) -> string {
	obj, ok := v.(json.Object)
	if !ok do return ": wants an object"
	for k in 0 ..< int(st.field_count) {
		if wire_skip(name, st.names[k]) != nil do continue
		x, has := obj[wire_key(st.names[k], st.tags[k])]
		if !has do continue
		if e := wire_read(x, rawptr(uintptr(data) + st.offsets[k]), st.types[k], a); e != "" do return strings.concatenate({".", st.names[k], e}, context.temp_allocator)
	}
	return ""
}

@(private = "file")
wire_put_int :: proc(data: rawptr, size: int, n: i64) {
	switch size {
	case 1: (^u8)(data)^ = u8(n)
	case 2: (^u16)(data)^ = u16(n)
	case 4: (^u32)(data)^ = u32(n)
	case 8: (^i64)(data)^ = n
	}
}

// Frees what a value of type ti holds (strings, arrays, a union's variant, a Command's
// strings), all allocated with a (a dynamic array with its own allocator), and zeroes it.
wire_free :: proc(data: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) {
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		wire_free(data, t.base, a)
		return
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(t.field_count) do wire_free(rawptr(uintptr(data) + t.offsets[k]), t.types[k], a)
	case runtime.Type_Info_String:
		if !t.is_cstring do delete((^string)(data)^, a)
	case runtime.Type_Info_Array:
		for i in 0 ..< t.count do wire_free(rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, a)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< t.count do wire_free(rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, a)
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)
		for i in 0 ..< raw.len do wire_free(rawptr(uintptr(raw.data) + uintptr(i * t.elem_size)), t.elem, a)
		if raw.data != nil do mem.free(raw.data, a)
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)
		for i in 0 ..< raw.len do wire_free(rawptr(uintptr(raw.data) + uintptr(i * t.elem_size)), t.elem, a)
		if raw.data != nil do mem.free_with_size(raw.data, raw.cap * t.elem_size, raw.allocator.procedure != nil ? raw.allocator : a)
	case runtime.Type_Info_Union:
		if vt := reflect.union_variant_type_info(any{data, ti.id}); vt != nil do wire_free(data, vt, a)
	case:
		return // scalars: nothing held
	}
	mem.zero(data, ti.size)
}

// Copies the value at src (type ti) into dst (zeroed), its strings and arrays allocated with a
// (as wire_read's), within the read budget. False: over the budget (dst holds what was copied,
// freed with it).
wire_clone :: proc(src, dst: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) -> bool {
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		return wire_clone(src, dst, t.base, a)
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(t.field_count) do if !wire_clone(rawptr(uintptr(src) + t.offsets[k]), rawptr(uintptr(dst) + t.offsets[k]), t.types[k], a) do return false
	case runtime.Type_Info_String:
		if t.is_cstring do return true
		x := (^string)(src)^
		if !budget_take(len(x)) do return false
		(^string)(dst)^ = strings.clone(x, a)
	case runtime.Type_Info_Array:
		for i in 0 ..< t.count do if !wire_clone(rawptr(uintptr(src) + uintptr(i * t.elem_size)), rawptr(uintptr(dst) + uintptr(i * t.elem_size)), t.elem, a) do return false
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< t.count do if !wire_clone(rawptr(uintptr(src) + uintptr(i * t.elem_size)), rawptr(uintptr(dst) + uintptr(i * t.elem_size)), t.elem, a) do return false
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array:
		elem := t.(runtime.Type_Info_Slice).elem if is_slice(ti) else t.(runtime.Type_Info_Dynamic_Array).elem
		n := is_slice(ti) ? (^runtime.Raw_Slice)(src).len : (^runtime.Raw_Dynamic_Array)(src).len
		from := is_slice(ti) ? (^runtime.Raw_Slice)(src).data : (^runtime.Raw_Dynamic_Array)(src).data
		if !budget_take(n * elem.size) do return false
		buf: rawptr
		if n > 0 {
			b, aerr := mem.alloc(n * elem.size, elem.align, a)
			if aerr != nil do return false
			buf = b
		}
		if is_slice(ti) {
			raw := (^runtime.Raw_Slice)(dst)
			raw.data, raw.len = buf, n
		} else {
			raw := (^runtime.Raw_Dynamic_Array)(dst)
			raw.data, raw.len, raw.cap, raw.allocator = buf, n, n, a
		}
		for i in 0 ..< n do if !wire_clone(rawptr(uintptr(from) + uintptr(i * elem.size)), rawptr(uintptr(buf) + uintptr(i * elem.size)), elem, a) do return false
	case runtime.Type_Info_Union:
		vid := reflect.union_variant_typeid(any{src, ti.id})
		if vid == nil do return true
		reflect.set_union_variant_typeid(any{dst, ti.id}, vid)
		return wire_clone(src, dst, type_info_of(vid), a)
	case:
		mem.copy(dst, src, ti.size) // scalars
	}
	return true
}
