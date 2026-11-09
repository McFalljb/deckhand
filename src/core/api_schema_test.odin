package core

// The grow-only API (design §7.5): schema/released-v1.json is what a released Deckhand speaks
// on core.sock and the framed wire: the commands and their args (required or optional), the
// result's and the events' fields, the window's state stream (sections and types), the frame
// header and kinds, and the hello's features. This test builds the same document from the
// code (command_table.odin, the encoders, State's types) and fails on any change that is not
// additive. The frame part is src/corewire's (its test checks it against the code); here it
// is carried over from the released file as it is.
//
// Refreshing at a release: the test writes the code's schema to build/api-schema-v1.json;
// copy it over schema/released-v1.json at the tag (as build/holder-schema.json for the
// holder's). Compatible changes may be refreshed any time; a failing one is a protocol break.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import jg "../jsonguard"

@(private = "file")
RELEASED_V1 :: "schema/released-v1.json"
@(private = "file")
CURRENT_V1 :: "build/api-schema-v1.json"

@(private = "file")
repo_root :: proc() -> string {
	return strings.trim_suffix(strings.trim_right(#directory, "/"), "/src/core")
}

// ---- the code's schema ----

// The API as the code has it; frame: the released file's "frame" member, as raw JSON.
@(private = "file")
api_schema_json :: proc(frame: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n  \"protocol\": %d,\n  \"features\": [],\n  \"frame\": %s,\n", PROTOCOL_VERSION, frame)
	// commands: the table's rows a caller can send (internal ones never come off the wire)
	strings.write_string(&b, "  \"commands\": [\n")
	n := 0
	for s in COMMAND_SPECS {
		if s.who == .Internal do continue
		if n > 0 do strings.write_string(&b, ",\n")
		n += 1
		strings.write_string(&b, "    {\"type\": ")
		json_quote(&b, s.type)
		fmt.sbprintf(&b, ", \"long_running\": %v, \"args\": [", s.long_running)
		for a, i in spec_args(s.args) {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, "{\"name\": ")
			json_quote(&b, a.name)
			fmt.sbprintf(&b, ", \"required\": %v}}", a.required)
		}
		strings.write_string(&b, "]}")
	}
	strings.write_string(&b, "\n  ],\n")
	// the result and the events: their fields, from the encoders' output for full samples
	full := Result{ok = true, error = "e", created_id = 1, pending = true, confirm_token = "t", confirm_summary = "s", confirm_by_user = true, data = `{"x":1}`}
	strings.write_string(&b, "  \"result\": ")
	write_fields_of(&b, result_json(full))
	strings.write_string(&b, ",\n  \"events\": [\n")
	events := [?]struct {
		name: string,
		ev:   Event,
	} {
		{"command", Command_Event{request_id = 1, caller = {kind = .Panel, tab_id = 2}, version = 3, changed = true, command = Close_Tab{tab_id = 4}, result = full}},
		{"finished", Finished_Event{request_id = 1, result = full, private = true}},
		{"job.finished", Job_Event{job = "j", title = "t", status = "ok", headline = "h", run = "r", run_dir = "d", summary_path = "p", scheduled_at = 1_790_000_000, needs_you = {"n"}, unread = true}},
	}
	for e, i in events {
		if i > 0 do strings.write_string(&b, ",\n")
		strings.write_string(&b, "    {\"event\": ")
		json_quote(&b, e.name)
		strings.write_string(&b, ", \"fields\": ")
		write_fields_of(&b, event_json(e.ev, full = true))
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "\n  ],\n")
	// the window's state stream (state_wire.odin)
	strings.write_string(&b, "  \"state\": {\n    \"messages\": [\"" + STATE_FULL + "\", \"" + STATE_DELTA + "\"],\n    \"sections\": [\n")
	st := runtime.type_info_base(type_info_of(State)).variant.(runtime.Type_Info_Struct)
	field_type :: proc(st: runtime.Type_Info_Struct, name: string) -> string {
		for k in 0 ..< int(st.field_count) do if st.names[k] == name do return type_ref(st.types[k])
		return "?"
	}
	for sec, i in STATE_SECTIONS {
		if i > 0 do strings.write_string(&b, ",\n")
		strings.write_string(&b, "      {\"name\": ")
		json_quote(&b, sec.name)
		strings.write_string(&b, ", \"fields\": [")
		for f, j in sec.fields {
			if j > 0 do strings.write_string(&b, ", ")
			fmt.sbprintf(&b, "{{\"name\": \"%s\", \"type\": \"%s\"}}", f, field_type(st, f))
		}
		strings.write_string(&b, "]}")
	}
	os_st := runtime.type_info_base(type_info_of(Open_Session)).variant.(runtime.Type_Info_Struct)
	fmt.sbprintf(&b, ",\n      {{\"name\": \"%s<session>\", \"type\": \"%s\"}}", SECTION_TABS, field_type(os_st, "tabs"))
	fmt.sbprintf(&b, ",\n      {{\"name\": \"%s<session>\", \"fields\": [", SECTION_PANES)
	for f, j in SESSION_PANE_FIELDS {
		if j > 0 do strings.write_string(&b, ", ")
		fmt.sbprintf(&b, "{{\"name\": \"%s\", \"type\": \"%s\"}}", f, field_type(os_st, f))
	}
	tab_st := runtime.type_info_base(type_info_of(Tab)).variant.(runtime.Type_Info_Struct)
	fmt.sbprintf(&b, "]}},\n      {{\"name\": \"%s<tab>\", \"type\": \"%s\"}}\n    ],\n    \"types\": {{\n", SECTION_PANELS, field_type(tab_st, "panels"))
	types := make(map[string]string, context.temp_allocator)
	collect_types(type_info_of(State), &types)
	names := make([dynamic]string, context.temp_allocator)
	for k in types do append(&names, k)
	slice.sort(names[:])
	for name, i in names {
		if i > 0 do strings.write_string(&b, ",\n")
		fmt.sbprintf(&b, "      \"%s\": %s", name, types[name])
	}
	strings.write_string(&b, "\n    }\n  }\n}\n")
	return strings.to_string(b)
}

@(private = "file")
Spec_Arg :: struct {
	name:     string,
	required: bool,
}

// "tab_id, confirm?" and "cwd? | project_id?, pinned": each name, and whether it is required
// (no `?`, not one of alternatives).
@(private = "file")
spec_args :: proc(args: string) -> []Spec_Arg {
	out := make([dynamic]Spec_Arg, context.temp_allocator)
	if strings.trim_space(args) == "" do return out[:]
	for part in strings.split(args, ",", context.temp_allocator) {
		alts := strings.split(part, "|", context.temp_allocator)
		for a in alts {
			name := strings.trim_space(a)
			opt := strings.has_suffix(name, "?")
			append(&out, Spec_Arg{name = strings.trim_suffix(name, "?"), required = !opt && len(alts) == 1})
		}
	}
	return out[:]
}

// The fields of the JSON object text, as [{"name", "type", "fields"?}] (types: bool, int,
// float, string, array, object; "data" is raw JSON and "command" a command: their types).
@(private = "file")
write_fields_of :: proc(b: ^strings.Builder, text: string) {
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	assert(err == nil, text)
	write_object_fields(b, v.(json.Object))
}

@(private = "file")
write_object_fields :: proc(b: ^strings.Builder, obj: json.Object) {
	keys := make([dynamic]string, context.temp_allocator)
	for k in obj do append(&keys, k)
	slice.sort(keys[:])
	strings.write_byte(b, '[')
	for k, i in keys {
		if i > 0 do strings.write_string(b, ", ")
		strings.write_string(b, "{\"name\": ")
		json_quote(b, k)
		strings.write_string(b, ", \"type\": ")
		x := obj[k]
		switch {
		case k == "data": strings.write_string(b, `"json"`)
		case k == "command": strings.write_string(b, `"command"`)
		case:
			#partial switch y in x {
			case json.Boolean: strings.write_string(b, `"bool"`)
			case json.Integer: strings.write_string(b, `"int"`)
			case json.Float: strings.write_string(b, `"float"`)
			case json.String: strings.write_string(b, `"string"`)
			case json.Array: strings.write_string(b, `"array"`)
			case json.Object:
				strings.write_string(b, `"object", "fields": `)
				write_object_fields(b, y)
			case: strings.write_string(b, `"null"`)
			}
		}
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}

// A type as the schema names it: bool, int, uint, float, string, time (ns), command, a named
// type's name, []T, [N]T, [Enum]T, bit_set[Enum], ?T.
@(private = "file")
type_ref :: proc(ti: ^runtime.Type_Info) -> string {
	if wire_is_time(ti) do return "time"
	if ti.id == typeid_of(Command) do return "command"
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		#partial switch _ in v.base.variant {
		case runtime.Type_Info_Struct, runtime.Type_Info_Enum, runtime.Type_Info_Union: return v.name
		}
		return type_ref(v.base)
	case runtime.Type_Info_Boolean: return "bool"
	case runtime.Type_Info_Integer: return v.signed ? "int" : "uint"
	case runtime.Type_Info_Float: return "float"
	case runtime.Type_Info_String: return "string"
	case runtime.Type_Info_Array: return fmt.tprintf("[%d]%s", v.count, type_ref(v.elem))
	case runtime.Type_Info_Slice: return strings.concatenate({"[]", type_ref(v.elem)}, context.temp_allocator)
	case runtime.Type_Info_Dynamic_Array: return strings.concatenate({"[]", type_ref(v.elem)}, context.temp_allocator)
	case runtime.Type_Info_Enumerated_Array: return fmt.tprintf("[%s]%s", type_ref(v.index), type_ref(v.elem))
	case runtime.Type_Info_Bit_Set: return fmt.tprintf("bit_set[%s]", type_ref(v.elem))
	case runtime.Type_Info_Union:
		if len(v.variants) == 1 && !v.no_nil do return strings.concatenate({"?", type_ref(v.variants[0])}, context.temp_allocator)
	}
	return "?"
}

// Every named struct, enum and union reachable from ti, as its schema entry.
@(private = "file")
collect_types :: proc(ti: ^runtime.Type_Info, out: ^map[string]string) {
	if wire_is_time(ti) || ti.id == typeid_of(Command) do return
	#partial switch v in ti.variant {
	case runtime.Type_Info_Named:
		if v.name in out do return
		b := strings.builder_make(context.temp_allocator)
		#partial switch x in v.base.variant {
		case runtime.Type_Info_Struct:
			out[v.name] = "" // seen (recursive types)
			strings.write_string(&b, `{"kind": "struct", "fields": [`)
			n := 0
			for k in 0 ..< int(x.field_count) {
				sk := wire_skip(v.name, x.names[k])
				if sk == nil || sk.why == .Section do collect_types(x.types[k], out)
				if sk != nil do continue
				if n > 0 do strings.write_string(&b, ", ")
				n += 1
				fmt.sbprintf(&b, `{{"name": "%s", "type": "%s"}}`, wire_key(x.names[k], x.tags[k]), type_ref(x.types[k]))
			}
			strings.write_string(&b, "]}")
		case runtime.Type_Info_Enum:
			strings.write_string(&b, `{"kind": "enum", "values": [`)
			for name, i in x.names {
				if i > 0 do strings.write_string(&b, ", ")
				wire_write_lower(&b, name)
			}
			strings.write_string(&b, "]}")
		case runtime.Type_Info_Union:
			out[v.name] = ""
			strings.write_string(&b, `{"kind": "union", "variants": [`)
			for vt, i in x.variants {
				if i > 0 do strings.write_string(&b, ", ")
				wire_write_lower(&b, wire_variant_name(vt))
				collect_types(vt, out)
			}
			strings.write_string(&b, "]}")
		case:
			collect_types(v.base, out)
			return
		}
		out[v.name] = strings.to_string(b)
	case runtime.Type_Info_Array: collect_types(v.elem, out)
	case runtime.Type_Info_Slice: collect_types(v.elem, out)
	case runtime.Type_Info_Dynamic_Array: collect_types(v.elem, out)
	case runtime.Type_Info_Enumerated_Array:
		collect_types(v.index, out)
		collect_types(v.elem, out)
	case runtime.Type_Info_Bit_Set: collect_types(v.elem, out)
	case runtime.Type_Info_Union: for vt in v.variants do collect_types(vt, out)
	}
}

// ---- grow-only ----

// What makes current incompatible with released ("" each; none = compatible). Added
// commands, optional args, fields, sections, types, enum values, variants and features are
// fine; anything removed, retyped, or newly required is not. The frame part is corewire's.
@(private = "file")
api_schema_problems :: proc(released, current: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	rv, e1 := jg.parse_string(released, .JSON, true, context.temp_allocator)
	cv, e2 := jg.parse_string(current, .JSON, true, context.temp_allocator)
	if e1 != nil || e2 != nil {
		append(&out, fmt.tprintf("unreadable schema (released %v, current %v)", e1, e2))
		return out
	}
	r, c := rv.(json.Object) or_else nil, cv.(json.Object) or_else nil
	if num(r["protocol"]) != num(c["protocol"]) do append(&out, "protocol changed")
	for f in arr(r["features"]) do if !has_str(arr(c["features"]), str(f)) do append(&out, fmt.tprintf("feature %s: removed", str(f)))
	for rc in arr(r["commands"]) {
		ro := obj(rc)
		name := str(ro["type"])
		co, found := find_by(arr(c["commands"]), "type", name)
		if !found {
			append(&out, fmt.tprintf("command %s: removed", name))
			continue
		}
		if boolean(ro["long_running"]) != boolean(co["long_running"]) do append(&out, fmt.tprintf("command %s: long_running changed", name))
		for ra in arr(ro["args"]) {
			a := obj(ra)
			ca, has := find_by(arr(co["args"]), "name", str(a["name"]))
			if !has do append(&out, fmt.tprintf("command %s: arg %s removed", name, str(a["name"])))
			else if boolean(ca["required"]) && !boolean(a["required"]) do append(&out, fmt.tprintf("command %s: arg %s became required", name, str(a["name"])))
		}
		for ca in arr(co["args"]) {
			a := obj(ca)
			if _, has := find_by(arr(ro["args"]), "name", str(a["name"])); !has && boolean(a["required"]) do append(&out, fmt.tprintf("command %s: new arg %s must be optional", name, str(a["name"])))
		}
	}
	fields_problems(&out, "result", arr(r["result"]), arr(c["result"]))
	for re in arr(r["events"]) {
		ro := obj(re)
		name := str(ro["event"])
		co, found := find_by(arr(c["events"]), "event", name)
		if !found {
			append(&out, fmt.tprintf("event %s: removed", name))
			continue
		}
		fields_problems(&out, fmt.tprintf("event %s", name), arr(ro["fields"]), arr(co["fields"]))
	}
	rs, cs := obj(r["state"]), obj(c["state"])
	for m in arr(rs["messages"]) do if !has_str(arr(cs["messages"]), str(m)) do append(&out, fmt.tprintf("state message %s: removed", str(m)))
	for x in arr(rs["sections"]) {
		ro := obj(x)
		name := str(ro["name"])
		co, found := find_by(arr(cs["sections"]), "name", name)
		if !found {
			append(&out, fmt.tprintf("state section %s: removed", name))
			continue
		}
		if str(ro["type"]) != str(co["type"]) do append(&out, fmt.tprintf("state section %s: type changed", name))
		fields_problems(&out, fmt.tprintf("state section %s", name), arr(ro["fields"]), arr(co["fields"]))
	}
	rt, ct := obj(rs["types"]), obj(cs["types"])
	for name, x in rt {
		ro := obj(x)
		cx, found := ct[name]
		if !found {
			append(&out, fmt.tprintf("state type %s: removed", name))
			continue
		}
		co := obj(cx)
		if str(ro["kind"]) != str(co["kind"]) {
			append(&out, fmt.tprintf("state type %s: kind changed", name))
			continue
		}
		fields_problems(&out, fmt.tprintf("state type %s", name), arr(ro["fields"]), arr(co["fields"]))
		for list in ([]string{"values", "variants"}) do for v in arr(ro[list]) do if !has_str(arr(co[list]), str(v)) do append(&out, fmt.tprintf("state type %s: %s %s removed", name, list[:len(list) - 1], str(v)))
	}
	return out
}

// Released fields must stay, with the same type (and so on inside objects).
@(private = "file")
fields_problems :: proc(out: ^[dynamic]string, where_: string, released, current: json.Array) {
	for rf in released {
		ro := obj(rf)
		name := str(ro["name"])
		co, found := find_by(current, "name", name)
		if !found {
			append(out, fmt.tprintf("%s: field %s removed", where_, name))
			continue
		}
		if str(ro["type"]) != str(co["type"]) do append(out, fmt.tprintf("%s: field %s: type %s -> %s", where_, name, str(ro["type"]), str(co["type"])))
		fields_problems(out, fmt.tprintf("%s.%s", where_, name), arr(ro["fields"]), arr(co["fields"]))
	}
}

@(private = "file")
find_by :: proc(list: json.Array, key, value: string) -> (json.Object, bool) {
	for x in list do if o := obj(x); str(o[key]) == value do return o, true
	return nil, false
}

@(private = "file")
has_str :: proc(list: json.Array, s: string) -> bool {
	for x in list do if str(x) == s do return true
	return false
}

@(private = "file")
obj :: proc(v: json.Value) -> json.Object {return v.(json.Object) or_else nil}
@(private = "file")
arr :: proc(v: json.Value) -> json.Array {return v.(json.Array) or_else nil}
@(private = "file")
str :: proc(v: json.Value) -> string {return v.(json.String) or_else ""}
@(private = "file")
boolean :: proc(v: json.Value) -> bool {return v.(json.Boolean) or_else false}
@(private = "file")
num :: proc(v: json.Value) -> i64 {return v.(json.Integer) or_else -1}

// The released file's "frame" member, raw.
@(private = "file")
released_frame :: proc(released: string) -> string {
	members, ok := json_members_raw(strings.trim_space(released))
	if ok do for m in members do if m.key == "frame" do return m.raw
	return "null"
}

// ---- tests ----

// The code's API against the last released one: only additions.
@(test)
api_schema_grow_only :: proc(t: ^testing.T) {
	root := repo_root()
	released, err := os.read_entire_file(fmt.tprintf("%s/%s", root, RELEASED_V1), context.temp_allocator)
	if !testing.expectf(t, err == nil, "%s: %v", RELEASED_V1, err) do return
	current := api_schema_json(released_frame(string(released)))
	_ = os.make_directory_all(fmt.tprintf("%s/build", root))
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, CURRENT_V1), transmute([]u8)current) // to refresh the released file
	for p in api_schema_problems(string(released), current) do testing.expectf(t, false, "API not grow-only: %s (%s)", p, RELEASED_V1)
	testing.expect(t, jg.shape_ok(current), "the schema is strict JSON")
}

// The rules themselves, on edited copies of the code's schema.
@(test)
api_schema_rules :: proc(t: ^testing.T) {
	base := api_schema_json(`{"header": "x"}`)
	testing.expect_value(t, len(api_schema_problems(base, base)), 0)
	breaks := [?][2]string {
		{`{"type": "close_tab", "long_running": false`, `{"type": "close_tab_x", "long_running": false`}, // a command removed (renamed)
		{`{"name": "tab_id", "required": true}, {"name": "confirm", "required": false}`, `{"name": "tab_id", "required": true}, {"name": "confirm", "required": true}`}, // an arg became required
		{`{"type": "close_tab", "long_running": false, "args": [`, `{"type": "close_tab", "long_running": false, "args": [{"name": "new", "required": true}, `}, // a new required arg
		{`{"type": "rescan", "long_running": true`, `{"type": "rescan", "long_running": false`},
		{`{"name": "created_id", "type": "int"}`, `{"name": "created_id", "type": "string"}`}, // a result field retyped
		{`"running", "exited", "not_started"`, `"running", "exited"`}, // an enum value removed
		{`{"name": "selected_project", "type": "uint"}`, `{"name": "selected", "type": "uint"}`}, // a section's field renamed
		{`"Pane": {"kind": "struct", "fields": [{"name": "id", "type": "uint"}`, `"Pane": {"kind": "struct", "fields": [{"name": "id", "type": "int"}`},
	}
	for x in breaks {
		testing.expectf(t, strings.contains(base, x[0]), "the schema has %s", x[0])
		changed, _ := strings.replace(base, x[0], x[1], 1, context.temp_allocator)
		testing.expectf(t, len(api_schema_problems(base, changed)) > 0, "not refused: %s -> %s", x[0], x[1])
	}
	// additions are fine: a command, an optional arg, a field, an enum value
	adds := [?][2]string {
		{`"commands": [`, `"commands": [{"type": "brand_new", "long_running": false, "args": [{"name": "x", "required": true}]}, `},
		{`{"name": "tab_id", "required": true}, {"name": "confirm", "required": false}`, `{"name": "tab_id", "required": true}, {"name": "confirm", "required": false}, {"name": "extra", "required": false}`},
		{`"running", "exited", "not_started"`, `"running", "exited", "not_started", "paused"`},
		{`"features": []`, `"features": ["state.delta.v2"]`},
	}
	for x in adds {
		testing.expectf(t, strings.contains(base, x[0]), "the schema has %s", x[0])
		changed, _ := strings.replace(base, x[0], x[1], 1, context.temp_allocator)
		for p in api_schema_problems(base, changed) do testing.expectf(t, false, "an addition refused: %s (%s)", p, x[1])
	}
}
