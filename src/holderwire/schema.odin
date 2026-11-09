package holderwire

// The wire's schema, the single source for decode checks and for the
// released-holder.json comparison. Grow-only: add kinds and optional fields;
// never renumber, retype, remove, or add a required field to a kind that shipped.

import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
import "core:strings"

Field_Type :: enum {
	Int,
	String,
	Strings, // array of strings
	Objects, // array of objects (items lists their fields)
	Object,
	Bool,
}

FIELD_TYPE_NAMES := [Field_Type]string {
	.Int     = "int",
	.String  = "string",
	.Strings = "strings",
	.Objects = "objects",
	.Object  = "object",
	.Bool    = "bool",
}

Payload :: enum {
	Json,
	Raw, // INPUT
	Offset_Raw, // OUTPUT, TAIL: u64 LE start + bytes
}

PAYLOAD_NAMES := [Payload]string {
	.Json       = "json",
	.Raw        = "raw",
	.Offset_Raw = "offset+raw",
}

Field_Spec :: struct {
	name:     string,
	type:     Field_Type,
	required: bool,
	nullable: bool, // null allowed (and means absent)
	items:    []Field_Spec, // .Objects: each element's fields; .Object: its fields
}

Kind_Spec :: struct {
	name:    string,
	kind:    Kind,
	frozen:  bool,
	payload: Payload,
	fields:  []Field_Spec,
}

@(private)
EXIT_STATUS := []Field_Spec{{name = "code", type = .Int, required = true}, {name = "signal", type = .Int, required = true}}

@(private)
WELCOME_TERMINAL := []Field_Spec {
	{name = "id", type = .Int, required = true},
	{name = "pid", type = .Int, required = true},
	{name = "pgid", type = .Int, required = true},
	{name = "cols", type = .Int, required = true},
	{name = "rows", type = .Int, required = true},
	{name = "xpixel", type = .Int, required = true},
	{name = "ypixel", type = .Int, required = true},
	{name = "offset", type = .Int, required = true},
	{name = "exit", type = .Object, nullable = true, items = EXIT_STATUS},
	{name = "degraded", type = .Bool},
}

@(private)
ACK_TERMINAL := []Field_Spec{{name = "id", type = .Int, required = true}, {name = "offset", type = .Int, required = true}}

SPECS := []Kind_Spec {
	{"HELLO", .Hello, true, .Json, {{name = "wire", type = .Int, required = true}, {name = "successor_secret", type = .String}}},
	{"WELCOME", .Welcome, true, .Json, {
		{name = "wire", type = .Int, required = true},
		{name = "instance", type = .String, required = true},
		{name = "pid", type = .Int, required = true},
		{name = "holder_rev", type = .Int, required = true},
		{name = "previous", type = .String, required = true},
		{name = "hmac_key", type = .String, required = true},
		{name = "terminals", type = .Objects, required = true, items = WELCOME_TERMINAL},
		{name = "upgrade_error", type = .String},
	}},
	{"REFUSED", .Refused, true, .Json, {{name = "code", type = .String, required = true}, {name = "error", type = .String, required = true}}},
	{"UPGRADE", .Upgrade, true, .Json, {{name = "path", type = .String, required = true}}},
	{"UPGRADE_FAILED", .Upgrade_Failed, true, .Json, {{name = "error", type = .String, required = true}}},
	{"SPAWN", .Spawn, false, .Json, {
		{name = "argv", type = .Strings, required = true},
		{name = "env", type = .Strings, required = true},
		{name = "cwd", type = .String, required = true},
		{name = "cols", type = .Int, required = true},
		{name = "rows", type = .Int, required = true},
		{name = "xpixel", type = .Int, required = true},
		{name = "ypixel", type = .Int, required = true},
	}},
	{"SPAWNED", .Spawned, false, .Json, {{name = "pid", type = .Int, required = true}, {name = "pgid", type = .Int, required = true}}},
	{"SPAWN_FAILED", .Spawn_Failed, false, .Json, {{name = "error", type = .String, required = true}}},
	{"INPUT", .Input, false, .Raw, nil},
	{"OUTPUT", .Output, false, .Offset_Raw, nil},
	{"TAIL", .Tail, false, .Offset_Raw, nil},
	{"RESIZE", .Resize, false, .Json, {
		{name = "cols", type = .Int, required = true},
		{name = "rows", type = .Int, required = true},
		{name = "xpixel", type = .Int, required = true},
		{name = "ypixel", type = .Int, required = true},
	}},
	{"SIGNAL", .Signal, false, .Json, {{name = "signal", type = .Int, required = true}, {name = "target", type = .String, required = true}}},
	{"RELEASE", .Release, false, .Json, nil},
	{"EXITED", .Exited, false, .Json, {
		{name = "code", type = .Int, required = true},
		{name = "signal", type = .Int, required = true},
		{name = "offset", type = .Int, required = true},
	}},
	{"GOODBYE", .Goodbye, false, .Json, {{name = "mode", type = .String, required = true}, {name = "successor", type = .Bool}}},
	{"GOODBYE_ACK", .Goodbye_Ack, false, .Json, {
		{name = "terminals", type = .Objects, required = true, items = ACK_TERMINAL},
		{name = "successor_secret", type = .String, required = true},
	}},
	{"FOREGROUND", .Foreground, false, .Json, nil},
	{"FOREGROUND_IS", .Foreground_Is, false, .Json, {{name = "pgid", type = .Int, required = true}}},
	{"PING", .Ping, false, .Json, nil},
	{"PONG", .Pong, false, .Json, nil},
	{"UNKNOWN", .Unknown, false, .Json, {{name = "kind", type = .Int, required = true}}},
	{"SUPERVISE", .Supervise, false, .Json, {{name = "op", type = .String, required = true}, {name = "path", type = .String}}},
	{"SUPERVISE_STATUS", .Supervise_Status, false, .Json, {
		{name = "core", type = .Bool, required = true},
		{name = "crashes", type = .Int, required = true},
		{name = "rolled_back", type = .Bool, required = true},
		{name = "gave_up", type = .Bool, required = true},
		{name = "previous", type = .Bool, required = true},
	}},
}

spec_of :: proc(kind: u8) -> (Kind_Spec, bool) {
	for s in SPECS do if u8(s.kind) == kind do return s, true
	return {}, false
}

// The schema as JSON, in the layout of schema/released-holder.json.
schema_json :: proc(allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	fmt.sbprintf(&sb, "{{\n  \"wire\": %d,\n  \"header\": \"kind u8, terminal u32 LE, len u32 LE; len <= %d; control len <= %d\",\n  \"kinds\": [\n", WIRE, MAX_PAYLOAD, MAX_CONTROL)
	for s, i in SPECS {
		fmt.sbprintf(&sb, "    {{\"name\": %q, \"kind\": %d, \"frozen\": %v, \"payload\": %q, \"fields\": ", s.name, u8(s.kind), s.frozen, PAYLOAD_NAMES[s.payload])
		write_fields(&sb, s.fields)
		strings.write_string(&sb, i + 1 < len(SPECS) ? "},\n" : "}\n")
	}
	strings.write_string(&sb, "  ]\n}\n")
	return strings.to_string(sb)
}

@(private)
write_fields :: proc(sb: ^strings.Builder, fields: []Field_Spec) {
	strings.write_byte(sb, '[')
	for f, i in fields {
		if i > 0 do strings.write_string(sb, ", ")
		fmt.sbprintf(sb, "{{\"name\": %q, \"type\": %q, \"required\": %v", f.name, FIELD_TYPE_NAMES[f.type], f.required)
		if f.nullable do strings.write_string(sb, ", \"nullable\": true")
		if f.items != nil {
			strings.write_string(sb, ", \"items\": ")
			write_fields(sb, f.items)
		}
		strings.write_byte(sb, '}')
	}
	strings.write_byte(sb, ']')
}

// Problems that make `current` (schema_json) incompatible with `released`
// (a shipped schema/released-holder.json). Empty: compatible.
schema_problems :: proc(released, current: string, allocator := context.allocator) -> [dynamic]string {
	out := make([dynamic]string, allocator)
	rv, e1 := jg.parse_string(released, .JSON, true, context.temp_allocator)
	cv, e2 := jg.parse_string(current, .JSON, true, context.temp_allocator)
	if e1 != nil || e2 != nil {
		append(&out, fmt.aprintf("unreadable schema (released %v, current %v)", e1, e2, allocator = allocator))
		return out
	}
	ro, co := rv.(json.Object), cv.(json.Object)
	if num(co["wire"]) < num(ro["wire"]) do append(&out, fmt.aprintf("wire went down: %v -> %v", num(ro["wire"]), num(co["wire"]), allocator = allocator))
	if str(co["header"]) != str(ro["header"]) do append(&out, strings.clone("the frame header changed (frozen)", allocator))
	ck := co["kinds"].(json.Array)
	for rk in ro["kinds"].(json.Array) {
		r := rk.(json.Object)
		name := str(r["name"])
		found := false
		for kk in ck {
			k := kk.(json.Object)
			if str(k["name"]) != name do continue
			found = true
			if num(k["kind"]) != num(r["kind"]) do append(&out, fmt.aprintf("%s: renumbered %v -> %v", name, num(r["kind"]), num(k["kind"]), allocator = allocator))
			if str(k["payload"]) != str(r["payload"]) do append(&out, fmt.aprintf("%s: payload changed", name, allocator = allocator))
			frozen := boolean(r["frozen"])
			if frozen != boolean(k["frozen"]) do append(&out, fmt.aprintf("%s: frozen flag changed", name, allocator = allocator))
			field_problems(&out, name, r["fields"].(json.Array), k["fields"].(json.Array), allocator)
		}
		if !found do append(&out, fmt.aprintf("%s: removed", name, allocator = allocator))
	}
	// a new kind may not take a released number
	for kk in ck {
		k := kk.(json.Object)
		for rk in ro["kinds"].(json.Array) {
			r := rk.(json.Object)
			if num(k["kind"]) == num(r["kind"]) && str(k["name"]) != str(r["name"]) do append(&out, fmt.aprintf("%s reuses number %v of %s", str(k["name"]), num(k["kind"]), str(r["name"]), allocator = allocator))
		}
	}
	return out
}

@(private)
field_problems :: proc(out: ^[dynamic]string, where_: string, rf, cf: json.Array, allocator := context.allocator) {
	for rx in rf {
		r := rx.(json.Object)
		name := str(r["name"])
		c, found := find_field(cf, name)
		if !found {append(out, fmt.aprintf("%s.%s: removed", where_, name, allocator = allocator)); continue}
		if str(c["type"]) != str(r["type"]) do append(out, fmt.aprintf("%s.%s: type changed", where_, name, allocator = allocator))
		if boolean(c["required"]) != boolean(r["required"]) do append(out, fmt.aprintf("%s.%s: required changed", where_, name, allocator = allocator))
		if boolean(c["nullable"]) != boolean(r["nullable"]) do append(out, fmt.aprintf("%s.%s: nullable changed", where_, name, allocator = allocator))
		ri, rhas := r["items"].(json.Array)
		ci, chas := c["items"].(json.Array)
		if rhas && !chas do append(out, fmt.aprintf("%s.%s: items removed", where_, name, allocator = allocator))
		if rhas && chas do field_problems(out, fmt.tprintf("%s.%s[]", where_, name), ri, ci, allocator)
	}
	for cx in cf {
		c := cx.(json.Object)
		name := str(c["name"])
		if _, found := find_field(rf, name); found do continue
		// frozen kinds too: their required fields are fixed, optional ones may be added
		if boolean(c["required"]) do append(out, fmt.aprintf("%s.%s: a new field must be optional", where_, name, allocator = allocator))
	}
}

@(private)
find_field :: proc(fields: json.Array, name: string) -> (json.Object, bool) {
	for x in fields {
		o := x.(json.Object)
		if str(o["name"]) == name do return o, true
	}
	return nil, false
}

@(private)
num :: proc(v: json.Value) -> i64 {
	#partial switch x in v {
	case json.Integer: return x
	case json.Float: return i64(x)
	}
	return -1
}

@(private)
str :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

@(private)
boolean :: proc(v: json.Value) -> bool {
	b, _ := v.(json.Boolean)
	return b
}
