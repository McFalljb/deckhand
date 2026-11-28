package core

// Hand-written JSON decoding (docs/PROTOCOL.md). parse_command is the one
// command parser shared by the test mode, scripts and the control socket.
// Strings in the results are allocated with `allocator`.

import "base:runtime"
import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:unicode/utf8"

@(private = "file")
Rd :: struct {
	obj: json.Object,
	err: string,
	a:   runtime.Allocator,
	// the window's own commands (parse_command_ui, window_link.odin only): the UI-only fields
	// are read too. Never set for a socket, script or test-mode line.
	ui:  bool,
}

@(private = "file")
need :: proc(r: ^Rd, k: string) -> (json.Value, bool) {
	v, ok := r.obj[k]
	if !ok && r.err == "" do r.err = strings.concatenate({"missing field ", k}, context.temp_allocator)
	return v, ok
}

@(private = "file")
get_u64 :: proc(r: ^Rd, k: string) -> u64 {
	v, ok := need(r, k)
	if !ok do return 0
	#partial switch n in v {
	case json.Integer:
		if n >= 0 do return u64(n)
	case json.Float:
		if n >= 0 && n == f64(u64(n)) do return u64(n)
	}
	if r.err == "" do r.err = strings.concatenate({k, " must be a non-negative integer"}, context.temp_allocator)
	return 0
}

@(private = "file")
// An optional model word (pi.status's model, provider, thinking level): cleaned here, where it
// enters (claude_model_clean: at most CLAUDE_MODEL_MAX bytes of [A-Za-z0-9._:/@[\]-]), so the
// state, the events and the log all get the same value; anything else is "" (none said).
get_model_word :: proc(r: ^Rd, k: string) -> string {
	v, ok := r.obj[k]
	if !ok do return ""
	s, is := v.(json.String)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a string"}, context.temp_allocator)
		return ""
	}
	clean := claude_model_clean(s)
	return clean == "" ? "" : strings.clone(clean, r.a)
}

get_str :: proc(r: ^Rd, k: string, optional := false) -> string {
	v, ok := r.obj[k]
	if !ok {
		if !optional && r.err == "" do r.err = strings.concatenate({"missing field ", k}, context.temp_allocator)
		return ""
	}
	s, is := v.(json.String)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a string"}, context.temp_allocator)
		return ""
	}
	return strings.clone(s, r.a)
}

@(private = "file")
get_bool :: proc(r: ^Rd, k: string) -> bool {
	v, ok := need(r, k)
	if !ok do return false
	b, is := v.(json.Boolean)
	if !is && r.err == "" do r.err = strings.concatenate({k, " must be a boolean"}, context.temp_allocator)
	return bool(b)
}

@(private = "file")
opt_f32 :: proc(r: ^Rd, k: string) -> Maybe(f32) {
	v, ok := r.obj[k]
	if !ok do return nil
	#partial switch n in v {
	case json.Integer: return f32(n)
	case json.Float:   return f32(n)
	}
	if r.err == "" do r.err = strings.concatenate({k, " must be a number"}, context.temp_allocator)
	return nil
}

@(private = "file")
opt_f64 :: proc(r: ^Rd, k: string) -> Maybe(f64) {
	v, ok := r.obj[k]
	if !ok do return nil
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float:   return f64(n)
	}
	if r.err == "" do r.err = strings.concatenate({k, " must be a number"}, context.temp_allocator)
	return nil
}

@(private = "file")
opt_bool :: proc(r: ^Rd, k: string) -> Maybe(bool) {
	v, ok := r.obj[k]
	if !ok do return nil
	b, is := v.(json.Boolean)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a boolean"}, context.temp_allocator)
		return nil
	}
	return bool(b)
}

@(private = "file")
opt_index :: proc(r: ^Rd, k: string) -> Maybe(int) {
	if _, ok := r.obj[k]; !ok do return nil
	return int(min(get_u64(r, k), 1 << 30))
}

@(private = "file")
opt_u64 :: proc(r: ^Rd, k: string) -> u64 {
	if _, ok := r.obj[k]; !ok do return 0
	return get_u64(r, k)
}

// claude.todos' list (claude_panels.odin): at most CLAUDE_TODOS_IN_MAX, each with a content
// string; status and active_form optional strings.
@(private = "file")
get_todos :: proc(r: ^Rd, k: string) -> []Claude_Todo_In {
	v, ok := r.obj[k]
	if !ok {
		if r.err == "" do r.err = strings.concatenate({"missing field ", k}, context.temp_allocator)
		return nil
	}
	a, is := v.(json.Array)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a list"}, context.temp_allocator)
		return nil
	}
	if len(a) > CLAUDE_TODOS_IN_MAX {
		if r.err == "" do r.err = fmt.tprintf("at most %d todos", CLAUDE_TODOS_IN_MAX)
		return nil
	}
	out := make([]Claude_Todo_In, len(a), r.a)
	for x, i in a {
		o, oo := x.(json.Object)
		content, cs := o["content"].(json.String)
		if !oo || !cs {
			if r.err == "" do r.err = "each todo needs a content string"
			return out
		}
		out[i].content = strings.clone(content, r.a)
		if st, has := o["status"].(json.String); has do out[i].status = strings.clone(st, r.a)
		if af, has := o["active_form"].(json.String); has do out[i].active_form = strings.clone(af, r.a)
	}
	return out
}

// claude.background's snapshot lists (claude_panels.odin): absent = empty; at most
// CLAUDE_BG_IN_MAX tasks and CLAUDE_CRONS_IN_MAX crons, each with an id string.
// A list of ids (non-negative integers): at most max of them.
@(private = "file")
get_ids :: proc(r: ^Rd, k: string, max: int) -> []u64 {
	v, ok := need(r, k)
	if !ok do return nil
	a, is := v.(json.Array)
	if !is || len(a) > max {
		if r.err == "" do r.err = fmt.tprintf("%s must be a list of at most %d ids", k, max)
		return nil
	}
	out := make([]u64, len(a), r.a)
	for x, i in a {
		n, isn := x.(json.Integer)
		if !isn || n < 0 {
			if r.err == "" do r.err = strings.concatenate({k, " must be a list of ids"}, context.temp_allocator)
			return out
		}
		out[i] = u64(n)
	}
	return out
}

@(private = "file")
get_bg_tasks :: proc(r: ^Rd, k: string) -> []Claude_Bg_In {
	v, ok := r.obj[k]
	if !ok || v == nil do return nil
	a, is := v.(json.Array)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a list"}, context.temp_allocator)
		return nil
	}
	if len(a) > CLAUDE_BG_IN_MAX {
		if r.err == "" do r.err = fmt.tprintf("at most %d background tasks", CLAUDE_BG_IN_MAX)
		return nil
	}
	out := make([]Claude_Bg_In, len(a), r.a)
	for x, i in a {
		o, oo := x.(json.Object)
		id, is_id := o["id"].(json.String)
		if !oo || !is_id {
			if r.err == "" do r.err = "each background task needs an id string"
			return out
		}
		out[i].id = strings.clone(id, r.a)
		if v, has := o["kind"].(json.String); has do out[i].kind = strings.clone(v, r.a)
		if v, has := o["status"].(json.String); has do out[i].status = strings.clone(v, r.a)
		if v, has := o["description"].(json.String); has do out[i].description = strings.clone(v, r.a)
		if v, has := o["command"].(json.String); has do out[i].command = strings.clone(v, r.a)
	}
	return out
}

@(private = "file")
get_bg_crons :: proc(r: ^Rd, k: string) -> []Claude_Cron_In {
	v, ok := r.obj[k]
	if !ok || v == nil do return nil
	a, is := v.(json.Array)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a list"}, context.temp_allocator)
		return nil
	}
	if len(a) > CLAUDE_CRONS_IN_MAX {
		if r.err == "" do r.err = fmt.tprintf("at most %d crons", CLAUDE_CRONS_IN_MAX)
		return nil
	}
	out := make([]Claude_Cron_In, len(a), r.a)
	for x, i in a {
		o, oo := x.(json.Object)
		id, is_id := o["id"].(json.String)
		if !oo || !is_id {
			if r.err == "" do r.err = "each cron needs an id string"
			return out
		}
		out[i].id = strings.clone(id, r.a)
		if v, has := o["schedule"].(json.String); has do out[i].schedule = strings.clone(v, r.a)
		if v, has := o["recurring"].(json.Boolean); has do out[i].recurring = bool(v)
		if v, has := o["prompt"].(json.String); has do out[i].prompt = strings.clone(v, r.a)
	}
	return out
}

@(private = "file")
get_strings :: proc(r: ^Rd, k: string) -> []string {
	v, ok := r.obj[k]
	if !ok do return nil
	a, is := v.(json.Array)
	out := make([]string, is ? len(a) : 0, r.a)
	for x, i in a {
		s, sok := x.(json.String)
		if !sok {
			if r.err == "" do r.err = strings.concatenate({k, " must be a list of strings"}, context.temp_allocator)
			return out
		}
		out[i] = strings.clone(s, r.a)
	}
	if !is && r.err == "" do r.err = strings.concatenate({k, " must be a list of strings"}, context.temp_allocator)
	return out
}

// A field's JSON object, as text (app_call's call).
@(private = "file")
get_raw :: proc(r: ^Rd, k: string) -> string {
	v, ok := need(r, k)
	if !ok do return ""
	if _, is := v.(json.Object); !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be an object"}, context.temp_allocator)
		return ""
	}
	out, err := json.marshal(v, {}, context.temp_allocator)
	if err != nil {
		if r.err == "" do r.err = strings.concatenate({k, " cannot be encoded"}, context.temp_allocator)
		return ""
	}
	return strings.clone(string(out), r.a)
}

// A JSON number as f32, or nil.
@(private = "file")
num_of :: proc(v: json.Value) -> Maybe(f32) {
	#partial switch n in v {
	case json.Integer: return f32(n)
	case json.Float:   return f32(n)
	}
	return nil
}

// The members of one JSON object as their source text, in order (an app's
// reply, passed on as sent: no re-marshal). ok=false unless `s` is exactly
// one object with nothing after it. Keys are decoded; values are slices of s.
Json_Member :: struct {
	key, raw: string,
}
json_members_raw :: proc(s: string, allocator := context.temp_allocator) -> (out: []Json_Member, ok: bool) {
	if !jg.shape_ok(s, spec = .JSON) do return nil, false
	context.allocator = context.temp_allocator // the parser's values: thrown away
	p := json.make_parser(s, .JSON, false, context.temp_allocator)
	if p.curr_token.kind != .Open_Brace do return nil, false
	json.advance_token(&p)
	list := make([dynamic]Json_Member, allocator)
	for p.curr_token.kind != .Close_Brace {
		if len(list) > 0 && json.expect_token(&p, .Comma) != nil do return nil, false
		k, kerr := json.parse_object_key(&p, context.temp_allocator)
		if kerr != nil || json.expect_token(&p, .Colon) != nil do return nil, false
		start := p.curr_token.pos.offset
		if _, verr := json.parse_value(&p); verr != nil do return nil, false
		end := p.prev_token.pos.offset + len(p.prev_token.text)
		append(&list, Json_Member{key = k, raw = s[start:end]})
	}
	json.advance_token(&p)
	if p.curr_token.kind != .EOF do return nil, false
	return list[:], true
}

// A field's list of JSON objects, each as text (app_input's events).
@(private = "file")
get_raw_list :: proc(r: ^Rd, k: string) -> []string {
	v, ok := need(r, k)
	if !ok do return nil
	a, is := v.(json.Array)
	if !is {
		if r.err == "" do r.err = strings.concatenate({k, " must be a list of objects"}, context.temp_allocator)
		return nil
	}
	out := make([]string, len(a), r.a)
	for x, i in a {
		if _, obj := x.(json.Object); !obj {
			if r.err == "" do r.err = strings.concatenate({k, " must be a list of objects"}, context.temp_allocator)
			return out
		}
		b, err := json.marshal(x, {}, context.temp_allocator)
		if err == nil do out[i] = strings.clone(string(b), r.a)
	}
	return out
}

// Panel rows: [{text, tone?, head?, id?}] (pi-kit's Line). An unknown tone
// reads as plain text (a newer bridge may send more); `id` is not used yet.
@(private = "file")
get_rows :: proc(r: ^Rd, k: string) -> []Panel_Row {
	v, ok := r.obj[k]
	if !ok {
		if r.err == "" do r.err = "kind" in r.obj ? "panel kinds other than rows are not supported yet" : "missing field rows"
		return nil
	}
	a, is := v.(json.Array)
	if !is {
		if r.err == "" do r.err = "rows must be a list"
		return nil
	}
	out := make([]Panel_Row, len(a), r.a)
	for x, i in a {
		o, oo := x.(json.Object)
		text, ts := o["text"].(json.String)
		if !oo || !ts {
			if r.err == "" do r.err = "each row needs a text string"
			return out
		}
		out[i].text = strings.clone(text, r.a)
		if tone, has := o["tone"].(json.String); has do for name, t in TONE_NAMES do if name != "" && name == tone do out[i].tone = t
		if h, has := o["head"].(json.Boolean); has do out[i].head = bool(h)
	}
	return out
}

// close_tab's and close_session's `comments`: "send", "drop" (absent or "ask": ask).
@(private = "file")
opt_comments :: proc(r: ^Rd) -> Comments_Choice {
	v, has := r.obj["comments"]
	if !has do return .Ask
	s, _ := v.(json.String)
	if s == "ask" do return .Ask
	for name, c in COMMENTS_CHOICE_NAMES do if name != "" && name == s do return c
	if r.err == "" do r.err = `comments must be "send" or "drop"`
	return .Ask
}

// pi_prompt's `images`: [{mime, data}] (absent: none). Checked by prompt_images_check.
@(private = "file")
get_images :: proc(r: ^Rd, k: string) -> []Prompt_Image {
	v, has := r.obj[k]
	if !has do return nil
	a, is := v.(json.Array)
	if !is {
		if r.err == "" do r.err = "images must be a list"
		return nil
	}
	out := make([]Prompt_Image, len(a), r.a)
	for x, i in a {
		o, _ := x.(json.Object)
		mime, mok := o["mime"].(json.String)
		data, dok := o["data"].(json.String)
		if !mok || !dok {
			if r.err == "" do r.err = "each image needs mime and data strings"
			return out
		}
		out[i] = {mime = strings.clone(mime, r.a), data = strings.clone(data, r.a)}
	}
	return out
}

// set_notifications' "macos" and "sound": {"<group>": "<choice>"} for the groups it sets
// ("default": the group's default). A missing object sets none; anything else is an error.
@(private = "file")
bell_choices :: proc(r: ^Rd, k: string, names: [$E]string) -> (out: [Bell_Group]Maybe(E)) {
	v, has := r.obj[k]
	if !has do return
	o, ok := v.(json.Object)
	if !ok {
		if r.err == "" do r.err = strings.concatenate({k, " must be an object"}, context.temp_allocator)
		return
	}
	for key, x in o {
		g, gok := enum_by_name(key, BELL_GROUP_NAMES)
		s, sok := x.(json.String)
		e, eok := enum_by_name(string(s), names)
		if string(s) == "default" do e, eok = {}, true
		if !gok || !sok || !eok {
			if r.err == "" do r.err = strings.concatenate({"unknown ", k, " ", key}, context.temp_allocator)
			return
		}
		out[g] = e
	}
	return
}

@(private = "file")
enum_by_name :: proc(s: string, names: [$E]string) -> (E, bool) {
	if s == "" do return {}, false
	for name, e in names do if name == s do return e, true
	return {}, false
}

// set_harness_flags's harness: one of HARNESS_KEYS (required).
harness_key :: proc(r: ^Rd) -> Harness {
	s := get_str(r, "harness")
	defer delete(s, r.a)
	for k, h in HARNESS_KEYS do if k == s do return h
	if r.err == "" do r.err = "harness must be pi, claude or codex"
	return .Pi
}

// A Claude tab's (or Claude command's) harness: "claude" (or none) is .Claude, "codex" .Codex
// (codex.odin); never .Pi.
@(private = "file")
harness_claude_tab :: proc(r: ^Rd) -> Harness {
	v, has := r.obj["harness"]
	if !has do return .Claude
	s, _ := v.(json.String)
	switch string(s) {
	case "claude": return .Claude
	case "codex":  return .Codex
	}
	if r.err == "" do r.err = "harness must be claude or codex"
	return .Claude
}

// An enum from its wire name (json_write.odin tables).
@(private = "file")
get_enum :: proc(r: ^Rd, k: string, names: [$E]string) -> E {
	v, ok := need(r, k)
	if !ok do return {}
	s, _ := v.(json.String)
	for name, e in names do if name == s do return e
	if r.err == "" do r.err = strings.concatenate({"unknown ", k, " ", s}, context.temp_allocator)
	return {}
}

JSON_MAX_DEPTH :: jg.MAX_DEPTH // 64

// Whether s is exactly one RFC 8259 JSON value (whitespace around it only),
// valid UTF-8, nested at most JSON_MAX_DEPTH. core:encoding/json's .JSON mode
// accepts more (\' and bad \u escapes, trailing commas, 01, \v as space):
// lines from apps are checked with this before anything is passed on as sent.
json_valid :: proc(s: string) -> bool {
	if !utf8.valid_string(s) do return false
	i := 0
	jv_ws(s, &i)
	if !jv_value(s, &i, 1) do return false
	jv_ws(s, &i)
	return i == len(s)
}

@(private = "file")
jv_ws :: proc(s: string, i: ^int) {
	for i^ < len(s) && (s[i^] == ' ' || s[i^] == '\t' || s[i^] == '\n' || s[i^] == '\r') do i^ += 1
}

@(private = "file")
jv_digits :: proc(s: string, i: ^int) -> bool {
	start := i^
	for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' do i^ += 1
	return i^ > start
}

@(private = "file")
jv_string :: proc(s: string, i: ^int) -> bool {
	if i^ >= len(s) || s[i^] != '"' do return false
	i^ += 1
	for i^ < len(s) {
		c := s[i^]
		switch {
		case c == '"':
			i^ += 1
			return true
		case c < 0x20:
			return false
		case c == '\\':
			if i^ + 1 >= len(s) do return false
			e := s[i^ + 1]
			if e == 'u' {
				if i^ + 6 > len(s) do return false
				for h in s[i^ + 2:i^ + 6] do if !(h >= '0' && h <= '9' || h >= 'a' && h <= 'f' || h >= 'A' && h <= 'F') do return false
				i^ += 6
			} else if strings.index_byte(`"\/bfnrt`, e) >= 0 {
				i^ += 2
			} else do return false
		case:
			i^ += 1
		}
	}
	return false
}

@(private = "file")
jv_value :: proc(s: string, i: ^int, depth: int) -> bool {
	if i^ >= len(s) do return false
	switch s[i^] {
	case '{', '[':
		if depth > JSON_MAX_DEPTH do return false
		obj := s[i^] == '{'
		close: u8 = obj ? '}' : ']'
		i^ += 1
		jv_ws(s, i)
		if i^ < len(s) && s[i^] == close {
			i^ += 1
			return true
		}
		for {
			if obj {
				if !jv_string(s, i) do return false
				jv_ws(s, i)
				if i^ >= len(s) || s[i^] != ':' do return false
				i^ += 1
				jv_ws(s, i)
			}
			if !jv_value(s, i, depth + 1) do return false
			jv_ws(s, i)
			if i^ >= len(s) do return false
			if s[i^] == close {
				i^ += 1
				return true
			}
			if s[i^] != ',' do return false
			i^ += 1
			jv_ws(s, i)
		}
	case '"':
		return jv_string(s, i)
	case 't', 'f', 'n':
		for lit in ([]string{"true", "false", "null"}) do if strings.has_prefix(s[i^:], lit) {
			i^ += len(lit)
			return true
		}
		return false
	case '-', '0' ..= '9':
		if s[i^] == '-' do i^ += 1
		if i^ >= len(s) do return false
		if s[i^] == '0' do i^ += 1
		else if !jv_digits(s, i) do return false
		if i^ < len(s) && s[i^] == '.' {
			i^ += 1
			if !jv_digits(s, i) do return false
		}
		if i^ < len(s) && (s[i^] == 'e' || s[i^] == 'E') {
			i^ += 1
			if i^ < len(s) && (s[i^] == '+' || s[i^] == '-') do i^ += 1
			if !jv_digits(s, i) do return false
		}
		return true
	}
	return false
}

// False if arrays/objects nest deeper than JSON_MAX_DEPTH (brackets inside
// strings do not count): so callers can say "nested too deeply". The rest of
// what the parser must not see (invalid UTF-8, raw control bytes in strings)
// jg.parse refuses after it (src/jsonguard).
json_depth_ok :: proc(text: string) -> bool {
	return jg.check(text, JSON_MAX_DEPTH, spec = .JSON) != .Too_Deep
}

// One command from its JSON text: {"type": "close_tab", "tab_id": 3, ...}.
parse_command :: proc(text: string, allocator := context.allocator) -> (Command, string) {
	return parse_command_as(text, false, allocator)
}

// The window's commands (window_link.odin, the in-process attach; never a socket line): as
// parse_command, plus the UI-only fields (Close_Session.ask, Focus_Session.reopen,
// Set_Home_Dir.setup). Their text is command_wire_json's.
@(private)
parse_command_ui :: proc(text: string, allocator := context.allocator) -> (Command, string) {
	return parse_command_as(text, true, allocator)
}

@(private = "file")
parse_command_as :: proc(text: string, ui: bool, allocator: runtime.Allocator) -> (Command, string) {
	if !json_depth_ok(text) do return nil, "JSON nested too deeply"
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if err != nil do return nil, "invalid JSON"
	cmd, cerr := command_from_value_as(v, ui, allocator)
	if cerr == "" do cerr = app_call_raw_params(&cmd, text, allocator)
	return cmd, cerr
}

// app_call's params as the caller wrote them (a slice of the command's
// text, strict JSON), not re-marshalled: big integers, 1e400 and the key
// order reach the app unchanged. A raw CR or LF anywhere in the request is
// refused: outside strings it can only be whitespace, and a lone CR is a
// line end to Node's readline or Python's text mode.
@(private = "file")
app_call_raw_params :: proc(cmd: ^Command, text: string, allocator: runtime.Allocator) -> string {
	ac, is := &cmd.(App_Call)
	if !is do return ""
	if strings.contains_any(strings.trim_space(text), "\r\n") do return "app_call cannot contain a raw line break (CR or LF)"
	if ac.params == "" do return ""
	members, ok := json_members_raw(strings.trim_space(text))
	raw := ""
	if ok do for m in members do if m.key == "params" do raw = m.raw // keys are unique: the parser refuses duplicates
	if raw == "" || !json_valid(raw) do return "params must be a strict JSON object"
	delete(ac.params, allocator)
	ac.params = strings.clone(raw, allocator)
	return ""
}

command_from_value :: proc(v: json.Value, allocator := context.allocator) -> (cmd: Command, err: string) {
	return command_from_value_as(v, false, allocator)
}

@(private = "file")
command_from_value_as :: proc(v: json.Value, ui: bool, allocator: runtime.Allocator) -> (cmd: Command, err: string) {
	obj, ok := v.(json.Object)
	if !ok do return nil, "a command must be a JSON object"
	r := Rd{obj = obj, a = allocator, ui = ui}
	t, _ := obj["type"].(json.String)
	switch t {
	case "":              return nil, "missing field type"
	case "set_chats_dir": cmd = Set_Folder{kind = .Chats, path = get_str(&r, "path", optional = true)} // the old name
	case "set_notes_dir": cmd = Set_Home_Dir{path = get_str(&r, "path", optional = true)} // the old name
	case "job_approve":   return nil, JOB_APPROVE_REMOVED
	case:
		i, known := command_by_name[t]
		if !known do return nil, strings.concatenate({"unknown command ", t}, context.temp_allocator)
		info := &command_infos[i]
		reflect.set_union_variant_typeid(any{&cmd, typeid_of(Command)}, info.id)
		for first in ([2]bool{true, false}) do for &f in info.fields do if f.first == first do cmd_read_field(&r, info, &f, &cmd)
	}
	if r.err != "" {
		command_free(cmd, allocator)
		return nil, r.err
	}
	return cmd, ""
}

// One field as its tag says (command_codec.odin).
@(private = "file")
cmd_read_field :: proc(r: ^Rd, info: ^Cmd_Info, f: ^Cmd_Field, cmd: ^Command) {
	if f.no_parse || (f.ui && !r.ui) do return
	data := rawptr(uintptr(cmd) + f.offset)
	if f.codec != "" && cmd_read_codec(r, info, f, data, cmd) do return
	ti := f.ti
	_, has := r.obj[f.key]
	if u, is := runtime.type_info_base(ti).variant.(runtime.Type_Info_Union); is && len(u.variants) == 1 && !u.no_nil { // Maybe(T): absent is unset
		if !has do return
		ti = u.variants[0]
		reflect.set_union_variant_typeid(any{data, f.ti.id}, ti.id)
	} else if !has && f.opt {
		if d, set := f.def.?; set do cmd_put_number(data, ti, d)
		return
	}
	#partial switch t in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer:
		n := get_u64(r, f.key)
		if m, set := f.max.?; set do n = min(n, m)
		wire_put_int(data, ti.size, i64(n))
	case runtime.Type_Info_Float:
		x: Maybe(f64)
		if ti.size == 4 {
			if y, set := opt_f32(r, f.key).?; set do x = f64(y)
		} else do x = opt_f64(r, f.key)
		if y, set := x.?; set do cmd_put_number(data, ti, y)
		else if d, set := f.def.?; set do cmd_put_number(data, ti, d)
	case runtime.Type_Info_Boolean:
		wire_put_int(data, ti.size, get_bool(r, f.key) ? 1 : 0)
	case runtime.Type_Info_String:
		(^string)(data)^ = get_str(r, f.key)
	case runtime.Type_Info_Enum:
		x, set := need(r, f.key)
		if !set do return
		s, _ := x.(json.String)
		for val, i in t.values {
			name := f.names == nil ? strings.to_lower(t.names[i], context.temp_allocator) : f.names[i64(val) - f.names_min]
			if name == s {
				wire_put_int(data, ti.size, i64(val))
				return
			}
		}
		if r.err == "" do r.err = strings.concatenate({"unknown ", f.key, " ", s}, context.temp_allocator)
	case runtime.Type_Info_Slice:
		if t.elem.id == typeid_of(string) {
			(^[]string)(data)^ = get_strings(r, f.key)
			return
		}
		if r.err == "" do r.err = strings.concatenate({f.key, ": no parser"}, context.temp_allocator)
	case:
		if r.err == "" do r.err = strings.concatenate({f.key, ": no parser"}, context.temp_allocator)
	}
}

@(private = "file")
cmd_put_number :: proc(data: rawptr, ti: ^runtime.Type_Info, x: f64) {
	#partial switch t in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Float:
		if ti.size == 4 do (^f32)(data)^ = f32(x)
		else do (^f64)(data)^ = x
	case runtime.Type_Info_Integer:
		wire_put_int(data, ti.size, i64(x))
	}
}

// A field read by hand (its tag's codec=); false: as any other.
@(private = "file")
cmd_read_codec :: proc(r: ^Rd, info: ^Cmd_Info, f: ^Cmd_Field, data: rawptr, cmd: ^Command) -> bool {
	put :: proc(data: rawptr, v: $T) {(^T)(data)^ = v}
	k := f.key
	_, has := r.obj[k]
	switch f.codec {
	case "comments":    put(data, opt_comments(r))
	case "inverse":     put(data, !(opt_bool(r, k).? or_else true))
	case "harness_ct":  put(data, harness_claude_tab(r))
	case "harness_key": put(data, harness_key(r))
	case "model_word":  put(data, get_model_word(r, k))
	case "web_ids":     put(data, get_ids(r, k, WEB_WATCH_IN_MAX))
	case "todos":       put(data, get_todos(r, k))
	case "bg_tasks":    put(data, get_bg_tasks(r, k))
	case "bg_crons":    put(data, get_bg_crons(r, k))
	case "images":      put(data, get_images(r, k))
	case "rows":        put(data, get_rows(r, k))
	case "raw_list":    put(data, get_raw_list(r, k))
	case "raw":         if has do put(data, get_raw(r, k))
	case "act_target":  put(data, act_target_of(r))
	case "mods":        put(data, act_mods_of(r))
	case "bell_macos":  put(data, bell_choices(r, k, OS_WHEN_NAMES))
	case "bell_sound":  put(data, bell_choices(r, k, BELL_SOUND_NAMES))
	case "has":
		put(data, get_str(r, k, optional = true))
		put(cmd_sibling(info, cmd, strings.concatenate({"has_", f.name}, context.temp_allocator)), has)
	case "pane_dir":
		name := get_str(r, k)
		d, ok := pane_dir_parse(name)
		delete(name, r.a)
		if !ok && r.err == "" do r.err = "direction: right, down, left or up"
		put(data, d)
	case "rect":
		if !has do return true
		o, is := r.obj[k].(json.Object)
		x, y, w, h := num_of(o["x"]), num_of(o["y"]), num_of(o["w"]), num_of(o["h"])
		if !is || x == nil || y == nil || w == nil || h == nil {
			if r.err == "" do r.err = "rect must be {x, y, w, h} (numbers)"
		} else {
			put(data, App_Rect{x.?, y.?, w.?, h.?})
			put(cmd_sibling(info, cmd, "has_rect"), true)
		}
	case "enum_of": // an enum by its names, its error not get_enum's
		if !has && f.opt do return true
		v, set := need(r, k)
		if !set do return true
		s, is := v.(json.String)
		if is do for name, i in f.names do if name == s {
			wire_put_int(data, f.ti.size, i64(i) + f.names_min)
			return true
		}
		if r.err == "" do r.err = strings.concatenate({k, " must be one of its names"}, context.temp_allocator)
	case: return false
	}
	return true
}


// A request envelope: {"id": "7", "type": "command", "v": 1, "command": {...}},
// {"id": "1", "type": "hello", "v": 1, "token": "..."}, ...
Request_Msg :: struct {
	id:      string,
	type:    string, // hello | command | cancel | subscribe | unsubscribe | pi.session | pi.status | result | panel.*
	v:       int,
	token:   string, // hello: the token (the plain hello)
	token_id: string, // hello: a challenge hello's token id (hello_proof.odin), instead of token
	nonce:   string, // hello: a challenge hello's client nonce
	proof:   string, // hello.proof: the client's proof
	challenge: bool, // hello: the client speaks the challenge hello (its reconnect token is challenge-only)
	framed:  bool, // hello, hello.proof: after the reply, the connection carries frames (§5a)
	peer:    string, // a framed hello: "hub" for another machine's core (deckhand-core-serve connect), else the window
	from:    string, // a hub hello: that machine's name (Viewed from <machine>)
	core:    string, // a hub hello: its core's id (a core is not its own hub)
	op, arg: string, // a web-admin hello (`deckhand-core-serve web`): what to do, and its argument
	command: Command, // command, pi.session, pi.status
	session: u64, // subscribe filter: an open session id (0 = all)
	tab_id:  u64, // subscribe filter: a tab id (0 = all)
	result:  Result, // result (a bridge answering Deckhand): ok and error only
	request_id: u64, // cancel: the request (one of this connection's) to end
}

parse_request :: proc(line: string, allocator := context.allocator) -> (m: Request_Msg, err: string) {
	if !json_depth_ok(line) do return {}, "JSON nested too deeply"
	v, jerr := jg.parse_string(line, .JSON, true, context.temp_allocator)
	if jerr != nil do return {}, "invalid JSON"
	obj, ok := v.(json.Object)
	if !ok do return {}, "a request must be a JSON object"
	r := Rd{obj = obj, a = allocator}
	m.id = get_str(&r, "id")
	m.type = get_str(&r, "type")
	m.v = int(get_u64(&r, "v"))
	if r.err != "" do return m, r.err
	if m.v != PROTOCOL_VERSION do return m, fmt.tprintf("unsupported protocol version %d (Deckhand speaks %d)", m.v, PROTOCOL_VERSION)
	switch m.type {
	case "hello":
		if _, has := obj["token_id"]; has {
			m.token_id = get_str(&r, "token_id")
			m.nonce = get_str(&r, "nonce")
		} else do m.token = get_str(&r, "token")
		m.challenge = opt_bool(&r, "challenge").? or_else false
		m.framed = opt_bool(&r, "framed").? or_else false
		m.peer = get_str(&r, "peer", optional = true)
		m.from = get_str(&r, "from", optional = true)
		m.core = get_str(&r, "core", optional = true)
		m.op = get_str(&r, "op", optional = true)
		m.arg = get_str(&r, "arg", optional = true)
	case "hello.proof":
		m.proof = get_str(&r, "proof")
		m.framed = opt_bool(&r, "framed").? or_else false
	case "command":
		cv, has := obj["command"]
		if !has do return m, "missing field command"
		m.command, err = command_from_value(cv, allocator)
		if err == "" {
			if members, ok := json_members_raw(strings.trim_space(line)); ok {
				for mm in members do if mm.key == "command" do err = app_call_raw_params(&m.command, mm.raw, allocator)
			}
		}
		return m, err
	case "pi.session", "pi.status", "panel.set", "panel.remove", "pi.attached":
		// the envelope is the command: {"id","v","type":"pi.status","agent",...}
		m.command, err = command_from_value(v, allocator)
		return m, err
	case "subscribe":
		m.session = opt_u64(&r, "session")
		m.tab_id = opt_u64(&r, "tab_id")
	case "unsubscribe":
	case "cancel":
		m.request_id = get_u64(&r, "request_id")
	case "result":
		ro, ok := obj["result"].(json.Object)
		if !ok do return m, "missing field result"
		rr := Rd{obj = ro, a = allocator}
		m.result.ok = get_bool(&rr, "ok")
		m.result.error = get_str(&rr, "error", optional = true)
		if rr.err != "" do return m, rr.err
	case:
		return m, "unknown request type"
	}
	return m, r.err
}

// The state snapshot back into a State (for clients, tests and, later,
// restoring a saved workspace). Runtime-only parts are not in the snapshot.
state_from_json :: proc(text: string, allocator := context.allocator) -> (s: State, err: string) {
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return {}, "invalid JSON"
	obj, ok := v.(json.Object)
	if !ok do return {}, "state must be an object"
	context.allocator = allocator
	r := Rd{obj = obj, a = allocator}
	s.version = get_u64(&r, "version")
	s.next_id = get_u64(&r, "next_id")
	s.selected_project = get_u64(&r, "selected_project")
	s.current_session = get_u64(&r, "current_session")
	s.shown_before = get_u64(&r, "shown_before")
	for pv in arr(obj, "projects") {
		p := Rd{obj = pv.(json.Object) or_else nil, a = allocator}
		group := get_str(&p, "group", optional = true) == "chats" ? Sidebar_Group.Chats : .Projects
		append(&s.projects, Project{id = get_u64(&p, "id"), group = group, cwd = get_str(&p, "cwd"), label = get_str(&p, "label"), name = get_str(&p, "name"), dir = get_str(&p, "dir"), missing = opt_bool(&p, "missing").? or_else false, repo = opt_bool(&p, "repo").? or_else false, temp = opt_bool(&p, "temp").? or_else false, parent = opt_u64(&p, "parent"), group_dir = get_str(&p, "group_dir", optional = true), group_in = opt_u64(&p, "group_in"), group_up = get_str(&p, "group_up", optional = true)})
		if p.err != "" do return s, p.err
	}
	for list, li in ([2]string{"sessions", "chats"}) {
		for xv in arr(obj, list) {
			x := Rd{obj = xv.(json.Object) or_else nil, a = allocator}
			ses := Session{id = get_str(&x, "id"), path = get_str(&x, "path"), when_ = get_str(&x, "when"), title = get_str(&x, "title")}
			append(li == 0 ? &s.sessions : &s.chats, ses)
			if x.err != "" do return s, x.err
		}
	}
	if sbv, ok := obj["sidebar"].(json.Object); ok {
		sr := Rd{obj = sbv, a = allocator}
		sb := &s.sidebar
		for v in get_strings(&sr, "pinned_projects") do append(&sb.pinned_projects, v)
		for v in get_strings(&sr, "pinned_sessions") do append(&sb.pinned_sessions, v)
		for v in get_strings(&sr, "hidden_projects") do append(&sb.hidden_projects, v)
		for v in get_strings(&sr, "hidden_sessions") do append(&sb.hidden_sessions, v)
		if so, sok := sbv["sort"].(json.Object); sok {
			r2 := Rd{obj = so, a = allocator}
			for sec in Sort_Section do if _, has := so[SORT_SECTION_NAMES[sec]]; has do sb.sort[sec] = get_enum(&r2, SORT_SECTION_NAMES[sec], SORT_BY_NAMES)
			if r2.err != "" do return s, r2.err
		}
		if fo, fok := sbv["folded"].(json.Object); fok {
			for f in Sidebar_Fold do if b, has := fo[FOLD_NAMES[f]].(json.Boolean); has do sb.folded[f] = bool(b)
		}
		if _, has := sbv["view"]; has do sb.view = get_enum(&sr, "view", SIDEBAR_VIEW_NAMES)
		sb.show_hidden = opt_bool(&sr, "show_hidden").? or_else false
		for v in get_strings(&sr, "expanded") do append(&sb.expanded, v)
		if fl, flok := sbv["filter"].(json.Object); flok {
			fr := Rd{obj = fl, a = allocator}
			sb.filter = get_str(&fr, "text", optional = true)
			sb.only_running = opt_bool(&fr, "running").? or_else false
			sb.only_waiting = opt_bool(&fr, "waiting").? or_else false
			sb.only_pinned = opt_bool(&fr, "pinned").? or_else false
		}
		if sr.err != "" do return s, sr.err
	}
	for ov in arr(obj, "open_sessions") {
		oo := ov.(json.Object) or_else nil
		o := Rd{obj = oo, a = allocator}
		os := Open_Session {
			id            = get_u64(&o, "id"),
			pi_session_id = get_str(&o, "pi_session_id"),
			session_dir   = get_str(&o, "session_dir", optional = true),
			session_file  = get_str(&o, "session_file", optional = true),
			project_id    = get_u64(&o, "project_id"),
			cwd           = get_str(&o, "cwd"),
			active_tab    = get_u64(&o, "active_tab"),
			missing       = opt_bool(&o, "missing").? or_else false,
		}
		if a, has := oo["agent"].(json.String); has && a == "claude" do os.agent = .Claude
		for tv in arr(oo, "tabs") {
			t := Rd{obj = tv.(json.Object) or_else nil, a = allocator}
			tab := Tab{id = get_u64(&t, "id"), title = get_str(&t, "title"), cwd = get_str(&t, "cwd", optional = true)}
			kind, _ := t.obj["kind"].(json.String)
			switch kind {
			case "pi":    tab.kind = Pi_Tab{}
			case "shell": tab.kind = Shell_Tab{}
			case "editor":
				et := Editor_Tab{path = get_str(&t, "path")}
				if v, has := t.obj["view"].(json.String); has do for name, k in EDITOR_VIEW_NAMES do if name == v do et.view = k
				tab.kind = et
			case "markdown":
				tab.kind = Markdown_Tab{path = get_str(&t, "path"), source = opt_bool(&t, "source").? or_else false}
			case "browser":
				bt := Browser_Tab{url = get_str(&t, "url", optional = true), blocked_popup = get_str(&t, "blocked_popup", optional = true)}
				bt.loading = opt_bool(&t, "loading").? or_else false
				bt.can_back = opt_bool(&t, "can_back").? or_else false
				bt.can_forward = opt_bool(&t, "can_forward").? or_else false
				tab.kind = bt
			case "claude":
				tab.kind = Claude_Tab{session_id = get_str(&t, "claude_session_id", optional = true), harness = harness_claude_tab(&t)}
			case "app":
				at := App_Tab{argv = get_strings(&t, "argv"), cwd = get_str(&t, "app_cwd", optional = true), exit_code = -1}
				if s, has := t.obj["app_status"].(json.String); has do for name, k in APP_STATUS_NAMES do if name == s do at.app_status = k
				if _, has := t.obj["exit_code"]; has do at.exit_code = int(get_u64(&t, "exit_code"))
				tab.kind = at
			case:         return s, "unknown tab kind"
			}
			status, _ := t.obj["status"].(json.String)
			for name, st in TAB_STATUS_NAMES do if name == status do tab.status = st
			if _, has := t.obj["agent"]; has do tab.agent = get_enum(&t, "agent", AGENT_NAMES)
			if w, has := t.obj["waiting"].(json.Boolean); has do tab.waiting = bool(w)
			if q, has := t.obj["question"].(json.Boolean); has do tab.question = bool(q)
			for b in get_strings(&t, "blockers") do append(&tab.blockers, b)
			for pv in arr(t.obj, "panels") {
				pr := Rd{obj = pv.(json.Object) or_else nil, a = allocator}
				p := Panel{id = get_str(&pr, "panel"), title = get_str(&pr, "title", optional = true)}
				for row in get_rows(&pr, "rows") do append(&p.rows, row)
				append(&tab.panels, p)
				if pr.err != "" do return s, pr.err
			}
			append(&os.tabs, tab)
			if t.err != "" do return s, t.err
		}
		append(&s.open_sessions, os)
		if o.err != "" do return s, o.err
	}
	if f, fok := obj["focus"].(json.Object); fok {
		if k, _ := f["kind"].(json.String); k == "widget" {
			fr := Rd{obj = f, a = allocator}
			s.focus_widget = get_str(&fr, "id")
		}
	}
	if l, lok := obj["layout"].(json.Object); lok {
		lr := Rd{obj = l, a = allocator}
		s.layout.left_width = opt_f32(&lr, "left_width").? or_else LEFT_WIDTH_DEFAULT
		s.layout.right_width = opt_f32(&lr, "right_width").? or_else RIGHT_WIDTH_DEFAULT
		s.layout.left_open = opt_bool(&lr, "left_open").? or_else true
		s.layout.right_open = opt_bool(&lr, "right_open").? or_else false
		s.layout.drawer_width = opt_f32(&lr, "drawer_width").? or_else DRAWER_WIDTH_DEFAULT
		s.layout.drawer_pinned = opt_bool(&lr, "drawer_pinned").? or_else false
		for pv in arr(l, "panels") do if p, is := pv.(json.String); is do append(&s.layout.panels, strings.clone(p))
		for pv in arr(l, "collapsed") do if p, is := pv.(json.String); is do append(&s.layout.collapsed, strings.clone(p))
	}
	for pv in arr(obj, "pending_confirmations") {
		po := pv.(json.Object) or_else nil
		p := Rd{obj = po, a = allocator}
		pc := Pending_Confirmation{summary = get_str(&p, "summary")}
		ck, _ := po["caller"].(json.String)
		for k in Caller_Kind do if caller_kind_name(k) == ck do pc.caller.kind = k
		cerr: string
		pc.class = get_enum(&p, "class", CLASS_NAMES)
		pc.command, cerr = command_from_value(po["command"], allocator)
		if cerr != "" do return s, cerr
		if p.err != "" do return s, p.err
		append(&s.pending_confirmations, pc)
	}
	if st, sok := obj["settings"].(json.Object); sok {
		if cf, cok := st["confirm"].(json.Object); cok {
			for k in Caller_Kind {
				ko, kok := cf[CALLER_NAMES[k]].(json.Object)
				if !kok do continue
				kr := Rd{obj = ko, a = allocator}
				for cl in Command_Class do if _, has := ko[CLASS_NAMES[cl]]; has do s.settings.confirm[k][cl] = get_enum(&kr, CLASS_NAMES[cl], MODE_NAMES)
				if kr.err != "" do return s, kr.err
			}
		}
		if cc, cok := st["confirm_close"].(json.Object); cok {
			cr := Rd{obj = cc, a = allocator}
			for k in Tab_Kind_Id do if _, has := cc[TAB_KIND_NAMES[k]]; has do s.settings.confirm_close[k] = get_enum(&cr, TAB_KIND_NAMES[k], CLOSE_NAMES)
			if cr.err != "" do return s, cr.err
		}
		sr := Rd{obj = st, a = allocator}
		if _, has := st["theme"]; has do s.settings.theme = get_enum(&sr, "theme", THEME_NAMES)
		s.settings.reduce_motion = opt_bool(&sr, "reduce_motion").? or_else false
		s.settings.dim_panes_off = !(opt_bool(&sr, "dim_panes").? or_else true)
		s.settings.term_text_pt = opt_index(&sr, "terminal_text_size").? or_else 0
		if _, has := st["appearance"]; has do s.settings.appearance = get_enum(&sr, "appearance", APPEARANCE_NAMES)
		if s.settings.appearance == .System do s.system_light = opt_bool(&sr, "light").? or_else false
		if _, has := st["text_size"]; has do s.settings.text_size = get_enum(&sr, "text_size", TEXT_SIZE_NAMES)
		s.settings.home_dir = get_str(&sr, "home_dir", optional = true)
		s.settings.setup_seen = opt_bool(&sr, "setup_seen").? or_else false
		if fo, fok := st["folders"].(json.Object); fok {
			for f in Folder_Kind {
				fe, eok := fo[FOLDER_NAMES[f]].(json.Object)
				if !eok do continue
				er := Rd{obj = fe, a = allocator}
				if opt_bool(&er, "custom").? or_else false do s.settings.folders[f] = get_str(&er, "path", optional = true)
				if er.err != "" do return s, er.err
			}
		}
		s.settings.claude_skip_permissions = opt_bool(&sr, "claude_skip_permissions").? or_else false
		s.settings.codex_full_access = opt_bool(&sr, "codex_full_access").? or_else false
		s.settings.claude_usage_statusline_off = !(opt_bool(&sr, "claude_usage_statusline").? or_else true)
		s.settings.claude_usage_background_off = !(opt_bool(&sr, "claude_usage_background").? or_else true)
		s.settings.agent_name = get_str(&sr, "agent_name", optional = true)
		s.settings.agent_model = get_str(&sr, "agent_model", optional = true)
		s.settings.notify_off = !(opt_bool(&sr, "notify").? or_else true)
		s.settings.tidy_off = !(opt_bool(&sr, "tidy_projects").? or_else true)
		s.settings.keep_sessions = opt_bool(&sr, "keep_sessions").? or_else false
		if bo, bok := st["bell"].(json.Object); bok {
			br := Rd{obj = bo, a = allocator}
			for g in Bell_Group do if !(opt_bool(&br, BELL_GROUP_NAMES[g]).? or_else true) do s.settings.bell_off += {g}
			// what applies per group, kept as Default where it is the default (notify.odin)
			mac, sound := bell_choices(&br, "macos", OS_WHEN_NAMES), bell_choices(&br, "sound", BELL_SOUND_NAMES)
			for g in Bell_Group {
				if v, ok := mac[g].?; ok && v != BELL_OS_DEFAULT[g] do s.settings.bell_os[g] = v
				if v, ok := sound[g].?; ok && v != BELL_SOUND_DEFAULT[g] do s.settings.bell_sound[g] = v
			}
			s.settings.bell_dock_off = !(opt_bool(&br, "dock").? or_else true)
			if br.err != "" do return s, br.err
		}
		if sr.err != "" do return s, sr.err
	}
	return s, r.err
}

@(private = "file")
arr :: proc(obj: json.Object, k: string) -> json.Array {
	if obj == nil do return nil
	a, _ := obj[k].(json.Array)
	return a
}

// An action's target: selector, or x and y (browser_act.odin checks which).
@(private = "file")
act_target_of :: proc(r: ^Rd) -> Act_Target {
	t := Act_Target{selector = get_str(r, "selector", optional = true)}
	x, y := opt_f32(r, "x"), opt_f32(r, "y")
	if x != nil || y != nil {
		if x == nil || y == nil {
			if r.err == "" do r.err = "x and y go together"
		} else do t.x, t.y, t.has_xy = x.?, y.?, true
	}
	return t
}

// modifiers: a list of "alt", "control", "meta", "shift" -> CDP's bits.
@(private = "file")
act_mods_of :: proc(r: ^Rd) -> int {
	m := 0
	names := get_strings(r, "modifiers")
	defer {
		for n in names do delete(n, r.a)
		delete(names, r.a)
	}
	for name in names {
		found := false
		for n, i in ACT_MOD_NAMES do if n == name {
			m |= 1 << uint(i)
			found = true
		}
		if !found && r.err == "" do r.err = "modifiers are alt, control, meta, shift"
	}
	return m
}
