package core

// Characterisation of every command's JSON (issue #195): what the encoders write, what the
// parser reads back and what the inbox's copy keeps, pinned in tests/command-codec/golden.txt.
// For each Command variant, three samples (all zero; filled "a": small numbers, enums' second
// value, strings with escapes, every Maybe set; filled "b": large and negative numbers, enums'
// last value, bools false, strings shaped like URLs with a password and like bridge blockers):
//
//   log    command_json(cmd)                the events' and the log's encoding, unredacted
//   red    command_json(cmd, redact = true) what events and the log keep
//   wire   command_wire_json(cmd)           the window's to its core
//   var    command_variant_write(cmd)       window.command, tab_host.call and tab_host.event
//   p.wire, p.log, ui.wire                   parse_command (or parse_command_ui) of those
//   clone                                    command_clone then command_free: the same value?
//
// and, per wire name in COMMAND_SPECS, a digest of the parser's answers to its object with each
// field taken out and each field set to each of `"x"`, -1, 1.5, true, null, 5000000000, [] and
// {} (required and optional fields, type checks, clamps, the first error), written out in full
// to build/command-golden-parse.txt.
//
// The test writes what the code does to build/command-golden.txt; a difference is a behaviour
// change. Refreshing (only for a deliberate wire change): copy that file over the golden.

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

@(private = "file")
GOLDEN :: "tests/command-codec/golden.txt"
@(private = "file")
ACTUAL :: "build/command-golden.txt"
@(private = "file")
ACTUAL_PARSE :: "build/command-golden-parse.txt"

@(private = "file")
cg_root :: proc() -> string {
	return strings.trim_suffix(strings.trim_right(#directory, "/"), "/src/core")
}

// ---- samples ----

@(private = "file")
Cg_Fill :: struct {
	seed: int, // 1 = "a", 2 = "b"
	n:    int,
	a:    runtime.Allocator,
}

@(private = "file")
CG_B_STRINGS := [?]string{"shell sh%d: run it", "https://user:pw@host%d.example/p?q=1#f", "subagent", "timer wk%d: wait", "user:pw@bare%d.example/x"}

@(private = "file")
cg_put_int :: proc(data: rawptr, size: int, v: i64) {
	switch size {
	case 1: (^u8)(data)^ = u8(v)
	case 2: (^u16)(data)^ = u16(v)
	case 4: (^u32)(data)^ = u32(v)
	case 8: (^i64)(data)^ = v
	}
}

@(private = "file")
cg_fill :: proc(data: rawptr, ti: ^runtime.Type_Info, f: ^Cg_Fill) {
	f.n += 1
	n := f.n
	if wire_is_time(ti) {
		(^i64)(data)^ = 1_790_000_000_000_000_000 + i64(n)
		return
	}
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		cg_fill(data, t.base, f)
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(t.field_count) do cg_fill(rawptr(uintptr(data) + t.offsets[k]), t.types[k], f)
	case runtime.Type_Info_Integer:
		v: i64
		if f.seed == 1 do v = i64(n % 50 + 1)
		else if t.signed do v = ti.size >= 4 ? -3 : -1
		else do v = ti.size >= 8 ? 5_000_000_000 + i64(n) : (ti.size == 4 ? 3_000_000_000 : 200)
		cg_put_int(data, ti.size, v)
	case runtime.Type_Info_Float:
		x := f.seed == 1 ? f64(n) + 0.25 : 0.41234567 + f64(n)
		if ti.size == 4 do (^f32)(data)^ = f32(x)
		else do (^f64)(data)^ = x
	case runtime.Type_Info_Boolean:
		(^u8)(data)^ = f.seed == 1 ? 1 : 0
	case runtime.Type_Info_String:
		if t.is_cstring do return
		if f.seed == 1 do (^string)(data)^ = fmt.aprintf("s%d \"q\\\" \n\t ✓", n, allocator = f.a)
		else {
			pat := CG_B_STRINGS[n % len(CG_B_STRINGS)]
			(^string)(data)^ = strings.contains(pat, "%d") ? fmt.aprintf(pat, n, allocator = f.a) : strings.clone(pat, f.a)
		}
	case runtime.Type_Info_Enum:
		i := f.seed == 1 ? min(1, len(t.values) - 1) : len(t.values) - 1
		cg_put_int(data, ti.size, i64(t.values[i]))
	case runtime.Type_Info_Array:
		for i in 0 ..< t.count do cg_fill(rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< t.count do cg_fill(rawptr(uintptr(data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Slice:
		cnt := f.seed == 1 ? 2 : 1
		raw := (^runtime.Raw_Slice)(data)
		raw.data, _ = mem.alloc(cnt * t.elem_size, t.elem.align, f.a)
		raw.len = cnt
		for i in 0 ..< cnt do cg_fill(rawptr(uintptr(raw.data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Dynamic_Array:
		cnt := f.seed == 1 ? 2 : 1
		raw := (^runtime.Raw_Dynamic_Array)(data)
		raw.data, _ = mem.alloc(cnt * t.elem_size, t.elem.align, f.a)
		raw.len, raw.cap, raw.allocator = cnt, cnt, f.a
		for i in 0 ..< cnt do cg_fill(rawptr(uintptr(raw.data) + uintptr(i * t.elem_size)), t.elem, f)
	case runtime.Type_Info_Bit_Set:
		en, is := runtime.type_info_base(t.elem).variant.(runtime.Type_Info_Enum)
		if !is do return
		bits: u64
		for val, i in en.values do if i % 2 == f.seed % 2 do bits |= u64(1) << u64(i64(val) - t.lower)
		cg_put_int(data, ti.size, i64(bits))
	case runtime.Type_Info_Union:
		if len(t.variants) == 0 do return
		idx := f.seed == 1 ? 0 : len(t.variants) - 1
		vt := t.variants[idx]
		mem.zero(data, ti.size)
		cg_fill(data, vt, f)
		reflect.set_union_variant_typeid(any{data, ti.id}, vt.id)
	}
}

// Command variant i: seed 0 all zero, 1 and 2 filled.
@(private = "file")
cg_sample :: proc(i, seed: int) -> Command {
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	cmd: Command
	vt := u.variants[i]
	if seed > 0 {
		f := Cg_Fill{seed = seed, n = i * 3, a = context.temp_allocator}
		cg_fill(&cmd, vt, &f)
		reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, vt.id)
		// fields whose text is itself JSON (an app's)
		#partial switch &c in cmd {
		case App_Call:
			c.params = seed == 1 ? `{"k":[1,"two"]}` : `[5000000000,-1.5e3]`
		case App_Input:
			// one key each: the parser re-marshals each event, and an object's keys have no order
			ev := make([]string, 2, context.temp_allocator)
			ev[0], ev[1] = `{"kind":"key"}`, `{"x":[1,true,null]}`
			c.events = ev
		}
	}
	reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, vt.id)
	return cmd
}

// ---- a value as text, every field (pointers as nil or ptr) ----

@(private = "file")
cg_dump :: proc(b: ^strings.Builder, data: rawptr, ti: ^runtime.Type_Info) {
	if wire_is_time(ti) {
		fmt.sbprintf(b, "%d", (^i64)(data)^)
		return
	}
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:
		if st, is := t.base.variant.(runtime.Type_Info_Struct); is {
			strings.write_string(b, t.name)
			cg_dump_struct(b, data, st)
			return
		}
		cg_dump(b, data, t.base)
	case runtime.Type_Info_Struct:
		cg_dump_struct(b, data, t)
	case runtime.Type_Info_Integer:
		if t.signed do fmt.sbprintf(b, "%d", wire_int(data, ti.size))
		else do fmt.sbprintf(b, "%d", wire_uint(data, ti.size))
	case runtime.Type_Info_Float:
		if ti.size == 4 do fmt.sbprintf(b, "%v", (^f32)(data)^)
		else do fmt.sbprintf(b, "%v", (^f64)(data)^)
	case runtime.Type_Info_Boolean:
		strings.write_string(b, wire_uint(data, ti.size) != 0 ? "true" : "false")
	case runtime.Type_Info_String:
		if t.is_cstring {
			strings.write_string(b, (^cstring)(data)^ == nil ? "cnil" : "cstr")
			return
		}
		json_quote(b, (^string)(data)^)
	case runtime.Type_Info_Enum:
		x := wire_int(data, ti.size)
		for val, i in t.values do if i64(val) == x {
			strings.write_byte(b, '.')
			strings.write_string(b, t.names[i])
			return
		}
		fmt.sbprintf(b, "enum(%d)", x)
	case runtime.Type_Info_Array:
		cg_dump_elems(b, data, t.count, t.elem_size, t.elem)
	case runtime.Type_Info_Enumerated_Array:
		cg_dump_elems(b, data, t.count, t.elem_size, t.elem)
	case runtime.Type_Info_Slice:
		raw := (^runtime.Raw_Slice)(data)
		if raw.data == nil && raw.len == 0 do strings.write_string(b, "nil")
		else do cg_dump_elems(b, raw.data, raw.len, t.elem_size, t.elem)
	case runtime.Type_Info_Dynamic_Array:
		raw := (^runtime.Raw_Dynamic_Array)(data)
		cg_dump_elems(b, raw.data, raw.len, t.elem_size, t.elem)
	case runtime.Type_Info_Bit_Set:
		fmt.sbprintf(b, "bits(%d)", wire_uint(data, ti.size))
	case runtime.Type_Info_Union:
		vt := reflect.union_variant_type_info(any{data, ti.id})
		if vt == nil {
			strings.write_string(b, "nil")
			return
		}
		cg_dump(b, data, vt)
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer, runtime.Type_Info_Procedure:
		strings.write_string(b, (^rawptr)(data)^ == nil ? "nil" : "ptr")
	case runtime.Type_Info_Map:
		strings.write_string(b, "map")
	case:
		strings.write_string(b, "?")
	}
}

@(private = "file")
cg_dump_struct :: proc(b: ^strings.Builder, data: rawptr, st: runtime.Type_Info_Struct) {
	strings.write_byte(b, '{')
	for k in 0 ..< int(st.field_count) {
		if k > 0 do strings.write_string(b, ", ")
		strings.write_string(b, st.names[k])
		strings.write_byte(b, '=')
		cg_dump(b, rawptr(uintptr(data) + st.offsets[k]), st.types[k])
	}
	strings.write_byte(b, '}')
}

@(private = "file")
cg_dump_elems :: proc(b: ^strings.Builder, data: rawptr, n, size: int, elem: ^runtime.Type_Info) {
	strings.write_byte(b, '[')
	for i in 0 ..< n {
		if i > 0 do strings.write_string(b, ", ")
		cg_dump(b, rawptr(uintptr(data) + uintptr(i * size)), elem)
	}
	strings.write_byte(b, ']')
}

@(private = "file")
cg_dump_cmd :: proc(cmd: Command) -> string {
	b := strings.builder_make(context.temp_allocator)
	c := cmd
	cg_dump(&b, &c, type_info_of(Command))
	return strings.to_string(b)
}

// ---- the parser's answer ----

// "ok <dump>" or "err <message>"; leaks and bad frees of the parse and its free are counted in
// `leaks` (not pinned: see command_golden).
@(private = "file")
cg_parse :: proc(text: string, ui: bool, leaks: ^int) -> string {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	a := mem.tracking_allocator(&track)
	cmd: Command
	err: string
	if ui do cmd, err = parse_command_ui(text, a)
	else do cmd, err = parse_command(text, a)
	out: string
	if err != "" do out = fmt.tprintf("err %s", err)
	else do out = fmt.tprintf("ok %s", cg_dump_cmd(cmd))
	if err == "" do command_free(cmd, a)
	leaks^ += len(track.allocation_map) + len(track.bad_free_array)
	return out
}

// ---- the test ----

@(private = "file")
cg_line :: proc(b: ^strings.Builder, name, what, text: string) {
	fmt.sbprintf(b, "%s\t%s\t%s\n", name, what, text)
}

// The object `text` (a JSON object) with member `key` replaced by `raw` ("" = removed), or with
// every member but type set to raw (key "*").
@(private = "file")
cg_mutate :: proc(members: []Json_Member, key, raw: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	n := 0
	for m in members {
		v := m.raw
		if m.key != "type" && (m.key == key || key == "*") {
			if raw == "" do continue
			v = raw
		}
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		json_quote(&b, m.key)
		strings.write_byte(&b, ':')
		strings.write_string(&b, v)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

@(private = "file")
CG_VALUES := [?]string{`"x"`, `-1`, `1.5`, `true`, `null`, `5000000000`, `[]`, `{}`}

// Names the parser knows that are not in COMMAND_SPECS (old names, removed commands).
@(private = "file")
CG_EXTRA_NAMES := [?]string{"set_chats_dir", "set_notes_dir", "job_approve", "no_such_command", ""}

@(test)
command_golden :: proc(t: ^testing.T) {
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	parse_out := strings.builder_make()
	defer strings.builder_destroy(&parse_out)
	leaks := 0
	clone_leaks := make([dynamic]string)
	defer {
		for l in clone_leaks do delete(l)
		delete(clone_leaks)
	}
	// a sample's wire text per wire name: the base object of the parser's cases
	base := make(map[string]string)
	defer {
		for k, v in base {
			delete(k)
			delete(v)
		}
		delete(base)
	}
	SEEDS :: [3]string{"zero", "a", "b"}
	for vt, i in u.variants {
		name := wire_variant_name(vt)
		for seed_name, seed in SEEDS {
			cmd := cg_sample(i, seed)
			tag := fmt.tprintf("%s.%s", name, seed_name)
			log := command_json(cmd)
			red := command_json(cmd, redact = true)
			wire := command_wire_json(cmd)
			vb := strings.builder_make(context.temp_allocator)
			command_variant_write(&vb, cmd)
			cg_line(&out, tag, "log", log)
			cg_line(&out, tag, "red", red == log ? "=log" : red)
			cg_line(&out, tag, "wire", wire == log ? "=log" : wire)
			cg_line(&out, tag, "var", strings.to_string(vb))
			dump := cg_dump_cmd(cmd)
			cg_line(&out, tag, "dump", dump)
			pw := cg_parse(wire, false, &leaks)
			cg_line(&out, tag, "p.wire", pw == fmt.tprintf("ok %s", dump) ? "=dump" : pw)
			if log != wire do cg_line(&out, tag, "p.log", cg_parse(log, false, &leaks))
			uw := cg_parse(wire, true, &leaks)
			cg_line(&out, tag, "ui.wire", uw == pw ? "=p.wire" : uw)
			// the inbox's copy
			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, runtime.heap_allocator())
			ca := mem.tracking_allocator(&track)
			cl := command_clone(cmd, ca)
			cd := cg_dump_cmd(cl)
			cg_line(&out, tag, "clone", cd == dump ? "same" : cd)
			command_free(cl, ca)
			if len(track.bad_free_array) > 0 do cg_line(&out, tag, "clone.bad_frees", fmt.tprintf("%d", len(track.bad_free_array)))
			if len(track.allocation_map) > 0 do append(&clone_leaks, fmt.aprintf("%s: %d", tag, len(track.allocation_map)))
			mem.tracking_allocator_destroy(&track)
			if seed == 1 {
				ty := command_type(cmd)
				if ty != "" && ty not_in base do base[strings.clone(ty)] = strings.clone(wire)
			}
		}
		free_all(context.temp_allocator)
	}
	// the parser's answers per wire name
	names := make([dynamic]string)
	defer delete(names)
	for s in COMMAND_SPECS do append(&names, s.type)
	for s in CG_EXTRA_NAMES do append(&names, s)
	for name in names {
		pb := strings.builder_make(context.temp_allocator)
		obj := base[name] or_else ""
		if obj == "" {
			tb := strings.builder_make(context.temp_allocator)
			strings.write_string(&tb, `{"type":`)
			json_quote(&tb, name)
			strings.write_byte(&tb, '}')
			obj = strings.to_string(tb)
		}
		members, ok := json_members_raw(obj)
		testing.expectf(t, ok, "%s: %s is not an object", name, obj)
		cases := make([dynamic]string, context.temp_allocator)
		append(&cases, obj)
		append(&cases, fmt.tprintf(`{{"type":%s}}`, strings.trim_space(members[0].raw) if len(members) > 0 && members[0].key == "type" else `""`))
		for raw in CG_VALUES do append(&cases, cg_mutate(members, "*", raw))
		for m in members {
			if m.key == "type" do continue
			append(&cases, cg_mutate(members, m.key, ""))
			for raw in CG_VALUES do append(&cases, cg_mutate(members, m.key, raw))
		}
		for c in cases {
			fmt.sbprintf(&pb, "%s\t%s\n", c, cg_parse(c, false, &leaks))
			fmt.sbprintf(&pb, "ui\t%s\n", cg_parse(c, true, &leaks))
		}
		text := strings.to_string(pb)
		strings.write_string(&parse_out, text)
		cg_line(&out, name == "" ? `""` : name, "parse.digest", fmt.tprintf("%016x %d", hash.fnv64a(transmute([]u8)text), len(cases)))
		free_all(context.temp_allocator)
	}
	got := strings.to_string(out)
	root := cg_root()
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, ACTUAL), transmute([]u8)got)
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, ACTUAL_PARSE), transmute([]u8)strings.to_string(parse_out))
	fmt.printfln("command_golden: parse leaks %d; clone leaks in %d samples", leaks, len(clone_leaks))
	for l in clone_leaks do fmt.printfln("  clone leak %s", l)
	want, rerr := os.read_entire_file(fmt.tprintf("%s/%s", root, GOLDEN), context.temp_allocator)
	if !testing.expectf(t, rerr == nil, "%s missing: %s has what the code does", GOLDEN, ACTUAL) do return
	if string(want) == got do return
	wl := strings.split_lines(string(want), context.temp_allocator)
	gl := strings.split_lines(got, context.temp_allocator)
	shown := 0
	for i in 0 ..< max(len(wl), len(gl)) {
		w := i < len(wl) ? wl[i] : "<none>"
		g := i < len(gl) ? gl[i] : "<none>"
		if w == g do continue
		testing.expectf(t, false, "line %d\n  golden: %s\n  now:    %s", i + 1, w, g)
		shown += 1
		if shown >= 20 do break
	}
	testing.expectf(t, false, "%s differs from %s (diff them; the parser's cases in full: %s)", ACTUAL, GOLDEN, ACTUAL_PARSE)
}
