package core

// Hand-written JSON decoding (docs/PROTOCOL.md). parse_command is the one
// command parser shared by the test mode, scripts and the control socket.
// Strings in the results are allocated with `allocator`.

import "base:runtime"
import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
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

// A UI-only flag: read only from the window's own commands (Rd.ui); anyone else's is ignored.
@(private = "file")
ui_flag :: proc(r: ^Rd, k: string) -> bool {
	if !r.ui do return false
	return opt_bool(r, k).? or_else false
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
opt_string :: proc(r: ^Rd, k: string) -> Maybe(string) {
	if _, ok := r.obj[k]; !ok do return nil
	return get_str(r, k)
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
	case "add_project":         cmd = Add_Project{cwd = get_str(&r, "cwd")}
	case "select_project":      cmd = Select_Project{project_id = get_u64(&r, "project_id")}
	case "rename_project":      cmd = Rename_Project{project_id = get_u64(&r, "project_id"), name = get_str(&r, "name")}
	case "open_session":        cmd = Open_Session_Cmd{project_id = get_u64(&r, "project_id"), pi_session_id = get_str(&r, "pi_session_id")}
	case "new_chat":            cmd = New_Chat{project_id = get_u64(&r, "project_id")}
	case "focus_session":       cmd = Focus_Session{session = get_u64(&r, "session"), reopen = ui_flag(&r, "reopen")}
	case "show_no_session":     cmd = Show_No_Session{}
	case "next_needing_you":    cmd = Next_Needing_You{back = opt_bool(&r, "back").? or_else false}
	case "close_session":       cmd = Close_Session{session = get_u64(&r, "session"), confirm = get_str(&r, "confirm", optional = true), ask = ui_flag(&r, "ask"), comments = opt_comments(&r)}
	case "new_shell_tab":       cmd = New_Shell_Tab{session = get_u64(&r, "session"), cwd = get_str(&r, "cwd", optional = true), pane = opt_u64(&r, "pane")}
	case "split_pane":
		d, ok := pane_dir_parse(get_str(&r, "direction"))
		if !ok && r.err == "" do r.err = "direction: right, down, left or up"
		cmd = Split_Pane{pane = opt_u64(&r, "pane"), direction = d, tab_id = opt_u64(&r, "tab_id"), no_focus = !(opt_bool(&r, "focus").? or_else true)}
	case "close_pane":          cmd = Close_Pane{pane = get_u64(&r, "pane")}
	case "focus_pane":          cmd = Focus_Pane{pane = opt_u64(&r, "pane"), direction = get_str(&r, "direction", optional = true)}
	case "move_tab":            cmd = Move_Tab{tab_id = get_u64(&r, "tab_id"), pane = get_u64(&r, "pane"), index = opt_index(&r, "index").? or_else -1}
	case "set_split":           cmd = Set_Split{split = get_u64(&r, "split"), ratio = opt_f32(&r, "ratio").? or_else -1}
	case "equalize_panes":      cmd = Equalize_Panes{session = opt_u64(&r, "session")}
	case "zoom_pane":           cmd = Zoom_Pane{pane = opt_u64(&r, "pane"), zoom = opt_bool(&r, "zoom")}
	case "close_tab":           cmd = Close_Tab{tab_id = get_u64(&r, "tab_id"), confirm = get_str(&r, "confirm", optional = true), comments = opt_comments(&r)}
	case "focus_tab":           cmd = Focus_Tab{tab_id = get_u64(&r, "tab_id")}
	case "copy_selection":      cmd = Copy_Selection{tab_id = get_u64(&r, "tab_id")}
	case "terminal_link":       cmd = Terminal_Link{tab_id = get_u64(&r, "tab_id"), url = get_str(&r, "url"), external = opt_bool(&r, "external").? or_else false}
	case "send_text":           cmd = Send_Text{tab_id = get_u64(&r, "tab_id"), text = get_str(&r, "text")}
	case "set_focus":           cmd = Set_Focus{widget = get_str(&r, "widget", optional = true)}
	case "set_layout":          cmd = Set_Layout{left_width = opt_f32(&r, "left_width"), right_width = opt_f32(&r, "right_width"), left_open = opt_bool(&r, "left_open"), right_open = opt_bool(&r, "right_open"), drawer_width = opt_f32(&r, "drawer_width"), drawer_pinned = opt_bool(&r, "drawer_pinned")}
	case "set_panel":           cmd = Set_Panel{panel = get_str(&r, "panel"), open = get_bool(&r, "open")}
	case "cancel_confirmation": cmd = Cancel_Confirmation{token = get_str(&r, "token")}
	case "rescan":              cmd = Rescan{}
	case "refresh_shell_env":   cmd = Refresh_Shell_Env{}
	case "quit":                cmd = Quit{confirm = get_str(&r, "confirm", optional = true), stop_sessions = opt_bool(&r, "stop_sessions").? or_else false}
	case "get_state":           cmd = Get_State{}
	case "list_commands":       cmd = List_Commands{}
	case "set_home":            cmd = Set_Home{open = get_bool(&r, "open")}
	case "set_chats_dir":       cmd = Set_Folder{kind = .Chats, path = get_str(&r, "path", optional = true)} // the old name
	case "set_home_dir":        cmd = Set_Home_Dir{path = get_str(&r, "path", optional = true), create = opt_bool(&r, "create").? or_else false, setup = ui_flag(&r, "setup")}
	case "set_folder":          cmd = Set_Folder{kind = get_enum(&r, "kind", FOLDER_NAMES), path = get_str(&r, "path", optional = true)}
	case "setup_sheet":         cmd = Setup_Sheet{open = get_bool(&r, "open")}
	case "set_chats_readonly":  cmd = Set_Chats_Readonly{on = get_bool(&r, "on")}
	case "set_pi_extension":    cmd = Set_Pi_Extension{name = get_str(&r, "name"), on = get_bool(&r, "on")}
	case "set_claude_default_flags": cmd = Set_Claude_Default_Flags{skip_permissions = get_bool(&r, "skip_permissions"), confirm = get_str(&r, "confirm", optional = true)}
	case "set_pinned":          cmd = Set_Pinned{cwd = get_str(&r, "cwd", optional = true), project_id = opt_u64(&r, "project_id"), pi_session_id = get_str(&r, "pi_session_id", optional = true), pinned = get_bool(&r, "pinned"), index = opt_index(&r, "index")}
	case "set_hidden":          cmd = Set_Hidden{cwd = get_str(&r, "cwd", optional = true), project_id = opt_u64(&r, "project_id"), pi_session_id = get_str(&r, "pi_session_id", optional = true), hidden = get_bool(&r, "hidden")}
	case "set_sort":            cmd = Set_Sort{section = get_enum(&r, "section", SORT_SECTION_NAMES), by = get_enum(&r, "by", SORT_BY_NAMES)}
	case "set_row_expanded":    cmd = Set_Row_Expanded{path = get_str(&r, "path"), expanded = get_bool(&r, "expanded")}
	case "set_sidebar_view":    cmd = Set_Sidebar_View{view = get_enum(&r, "view", SIDEBAR_VIEW_NAMES)}
	case "set_sidebar_folded":  cmd = Set_Sidebar_Folded{section = get_enum(&r, "section", FOLD_NAMES), folded = get_bool(&r, "folded")}
	case "set_filter":          cmd = Set_Filter{text = opt_string(&r, "text"), running = opt_bool(&r, "running"), waiting = opt_bool(&r, "waiting"), pinned = opt_bool(&r, "pinned"), show_hidden = opt_bool(&r, "show_hidden")}
	case "reveal":              cmd = Reveal_Path{project_id = get_u64(&r, "project_id"), pi_session_id = get_str(&r, "pi_session_id", optional = true)}
	case "session_info":        cmd = Session_Info{project_id = get_u64(&r, "project_id"), pi_session_id = get_str(&r, "pi_session_id"), to = get_str(&r, "to", optional = true)}
	case "copy_path":           cmd = Copy_Path{project_id = get_u64(&r, "project_id"), pi_session_id = get_str(&r, "pi_session_id", optional = true)}
	case "set_agent_name":      cmd = Set_Agent_Name{name = get_str(&r, "name")}
	case "set_agent_model":     cmd = Set_Agent_Model{model = get_str(&r, "model", optional = true)}
	case "agent_model_picker":  cmd = Agent_Model_Picker{}
	case "set_notify":          cmd = Set_Notify{on = get_bool(&r, "on")}
	case "set_tidy_projects":   cmd = Set_Tidy_Projects{on = get_bool(&r, "on")}
	case "set_keep_sessions":   cmd = Set_Keep_Sessions{on = get_bool(&r, "on")}
	case "set_separate_core":   cmd = Set_Separate_Core{on = get_bool(&r, "on")}
	case "set_remote_machines": cmd = Set_Remote_Machines{on = get_bool(&r, "on")}
	case "set_machines_reachable": cmd = Set_Machines_Reachable{on = get_bool(&r, "on"), confirm = get_str(&r, "confirm", optional = true)}
	case "machine_add":         cmd = Machine_Add{name = get_str(&r, "name", optional = true), target = get_str(&r, "target", optional = true), via = get_str(&r, "via", optional = true)}
	case "machine_remove":      cmd = Machine_Remove{no = get_u64(&r, "no"), confirm = get_str(&r, "confirm", optional = true)}
	case "machine_rename":      cmd = Machine_Rename{no = get_u64(&r, "no"), name = get_str(&r, "name")}
	case "machine_connect":     cmd = Machine_Connect{no = get_u64(&r, "no")}
	case "machine_login":       cmd = Machine_Login{no = get_u64(&r, "no")}
	case "machine_install":     cmd = Machine_Install{no = get_u64(&r, "no"), cancel = opt_bool(&r, "cancel").? or_else false}
	case "machine_linger":      cmd = Machine_Linger{no = get_u64(&r, "no")}
	case "machine_open_page":   cmd = Machine_Open_Page{no = get_u64(&r, "no"), port = get_u64(&r, "port"), path = get_str(&r, "path", optional = true)}
	case "holder_replace":      cmd = Holder_Replace{stop = get_bool(&r, "stop")}
	case "core_handover":       cmd = Core_Handover{to = get_str(&r, "to")}
	case "copy_control_token":  cmd = Copy_Control_Token{}
	case "update_check":        cmd = Update_Check{}
	case "update_skip":         cmd = Update_Skip{}
	case "update_later":        cmd = Update_Later{}
	case "update_download":     cmd = Update_Download{}
	case "update_install":      cmd = Update_Install{confirm = get_str(&r, "confirm", optional = true)}
	case "set_update_check":    cmd = Set_Update_Check{on = get_bool(&r, "on")}
	case "set_confirm_policy":  cmd = Set_Confirm_Policy{caller = get_enum(&r, "caller", CALLER_NAMES), class = get_enum(&r, "class", CLASS_NAMES), mode = get_enum(&r, "mode", MODE_NAMES)}
	case "set_close_confirm":   cmd = Set_Close_Confirm{tab_kind = get_enum(&r, "tab_kind", TAB_KIND_NAMES), rule = get_enum(&r, "rule", CLOSE_NAMES)}
	case "set_theme":           cmd = Set_Theme{name = get_enum(&r, "name", THEME_NAMES)}
	case "set_reduce_motion":   cmd = Set_Reduce_Motion{on = get_bool(&r, "on")}
	case "set_dim_panes":       cmd = Set_Dim_Panes{on = get_bool(&r, "on")}
	case "set_terminal_text_size": cmd = Set_Terminal_Text_Size{pt = int(min(get_u64(&r, "pt"), 1000))}
	case "set_appearance":      cmd = Set_Appearance{mode = get_enum(&r, "mode", APPEARANCE_NAMES)}
	case "set_text_size":       cmd = Set_Text_Size{size = get_enum(&r, "size", TEXT_SIZE_NAMES)}
	// bridge reports: tab_id optional (0 = the caller's own pi tab)
	case "pi.session":          cmd = Pi_Session_Update{tab_id = opt_u64(&r, "tab_id"), pi_session_id = get_str(&r, "pi_session_id"), session_file = get_str(&r, "session_file", optional = true), cwd = get_str(&r, "cwd", optional = true)}
	case "pi.status":           cmd = Pi_Status_Update{tab_id = opt_u64(&r, "tab_id"), agent = get_enum(&r, "agent", AGENT_NAMES), waiting = get_bool(&r, "waiting"), question = opt_bool(&r, "question").? or_else false, blockers = get_strings(&r, "blockers")}
	case "panel.set":           cmd = Panel_Set{tab_id = opt_u64(&r, "tab_id"), panel = get_str(&r, "panel"), title = get_str(&r, "title", optional = true), rows = get_rows(&r, "rows")}
	case "panel.remove":        cmd = Panel_Remove{tab_id = opt_u64(&r, "tab_id"), panel = get_str(&r, "panel")}
	case "set_panel_collapsed": cmd = Set_Panel_Collapsed{panel = get_str(&r, "panel"), collapsed = get_bool(&r, "collapsed")}
	case "pi_prompt":           cmd = Pi_Prompt{tab_id = get_u64(&r, "tab_id"), text = get_str(&r, "text"), images = get_images(&r, "images")}
	case "pi_restart":          cmd = Pi_Restart{tab_id = get_u64(&r, "tab_id"), pick_model = opt_bool(&r, "pick_model").? or_else false}
	case "pi_reload":           cmd = Pi_Reload{tab_id = get_u64(&r, "tab_id"), confirm = get_str(&r, "confirm", optional = true)}
	case "pi_reload_all":       cmd = Pi_Reload_All{only_changed = opt_bool(&r, "only_changed").? or_else false, confirm = get_str(&r, "confirm", optional = true)}
	case "pi_restart_updated":  cmd = Pi_Restart_Updated{confirm = get_str(&r, "confirm", optional = true)}
	case "pi_reload_later":     cmd = Pi_Reload_Later{restart = opt_bool(&r, "restart").? or_else false}
	case "pi_wait_idle":        cmd = Pi_Wait_Idle{tab_id = get_u64(&r, "tab_id"), timeout_ms = opt_u64(&r, "timeout_ms")}
	case "open_file":           cmd = Open_File{path = get_str(&r, "path"), line = int(opt_u64(&r, "line")), col = int(opt_u64(&r, "col")), session = opt_u64(&r, "session"), preview = opt_bool(&r, "preview").? or_else false}
	case "keep_tab":            cmd = Keep_Tab{tab_id = get_u64(&r, "tab_id")}
	case "editor_state":        cmd = Editor_State{tab_id = get_u64(&r, "tab_id")}
	case "save_file":           cmd = Save_File{tab_id = get_u64(&r, "tab_id")}
	case "goto":                cmd = Goto_Line{tab_id = get_u64(&r, "tab_id"), line = int(get_u64(&r, "line")), col = int(opt_u64(&r, "col"))}
	case "reload_file":         cmd = Reload_File{tab_id = get_u64(&r, "tab_id"), confirm = get_str(&r, "confirm", optional = true)}
	case "keep_buffer":         cmd = Keep_Buffer{tab_id = get_u64(&r, "tab_id")}
	case "diff_file":           cmd = Diff_File{tab_id = get_u64(&r, "tab_id"), against = get_enum(&r, "against", EDITOR_VIEW_NAMES)}
	case "set_wrap":            cmd = Set_Wrap{tab_id = get_u64(&r, "tab_id"), on = get_bool(&r, "on")}
	case "list_dir":            cmd = List_Dir{path = get_str(&r, "path"), ignored = opt_bool(&r, "ignored").? or_else false}
	case "create_file":         cmd = Create_File{path = get_str(&r, "path"), confirm = get_str(&r, "confirm", optional = true)}
	case "create_dir":          cmd = Create_Dir{path = get_str(&r, "path"), confirm = get_str(&r, "confirm", optional = true)}
	case "rename_path":         cmd = Rename_Path{from = get_str(&r, "from"), to = get_str(&r, "to"), confirm = get_str(&r, "confirm", optional = true)}
	case "delete_path":         cmd = Delete_Path{path = get_str(&r, "path"), confirm = get_str(&r, "confirm", optional = true)}
	case "reveal_in_finder":    cmd = Reveal_In_Finder{path = get_str(&r, "path")}
	case "set_left_tab":        cmd = Set_Left_Tab{tab = get_enum(&r, "tab", LEFT_TAB_NAMES)}
	case "files_expand":        cmd = Files_Expand{path = get_str(&r, "path"), expanded = get_bool(&r, "expanded")}
	case "files_collapse_all":  cmd = Files_Collapse_All{root = get_str(&r, "root")}
	case "files_reveal":        cmd = Files_Reveal{path = get_str(&r, "path")}
	case "set_files_filter":    cmd = Set_Files_Filter{text = get_str(&r, "text", optional = true)}
	case "list_worktrees":      cmd = List_Worktrees{path = get_str(&r, "path", optional = true)}
	case "files_set_root":      cmd = Files_Set_Root{base = get_str(&r, "base", optional = true), path = get_str(&r, "path", optional = true)}
	case "worktree_cleanup":    cmd = Worktree_Cleanup{path = get_str(&r, "path"), confirm = get_str(&r, "confirm", optional = true)}
	case "worktree_session":    cmd = Worktree_Session{project_id = get_u64(&r, "project_id"), path = get_str(&r, "path")}
	case "changes_open":        cmd = Changes_Open{session = opt_u64(&r, "session"), path = get_str(&r, "path", optional = true)}
	case "changes_list":        cmd = Changes_List{tab_id = opt_u64(&r, "tab_id"), path = get_str(&r, "path", optional = true)}
	case "changes_stage":       cmd = Changes_Stage{tab_id = get_u64(&r, "tab_id"), path = get_str(&r, "path"), status = get_str(&r, "status", optional = true)}
	case "changes_unstage":     cmd = Changes_Unstage{tab_id = get_u64(&r, "tab_id"), path = get_str(&r, "path"), status = get_str(&r, "status", optional = true)}
	case "changes_discard":     cmd = Changes_Discard{tab_id = get_u64(&r, "tab_id"), path = get_str(&r, "path"), status = get_str(&r, "status", optional = true), confirm = get_str(&r, "confirm", optional = true), second = opt_bool(&r, "second").? or_else false}
	case "changes_commit":      cmd = Changes_Commit{tab_id = get_u64(&r, "tab_id"), message = get_str(&r, "message")}
	case "show_file":           cmd = Show_File{path = get_str(&r, "path"), line = int(min(opt_u64(&r, "line"), 1 << 30)), anchor = get_str(&r, "anchor", optional = true), session = opt_u64(&r, "session")}
	case "markdown_open":       cmd = Markdown_Open{path = get_str(&r, "path"), session = opt_u64(&r, "session"), anchor = get_str(&r, "anchor", optional = true)}
	case "markdown_view":       cmd = Markdown_Set_View{tab_id = get_u64(&r, "tab_id"), source = opt_bool(&r, "source").? or_else false}
	case "markdown_scroll":     cmd = Markdown_Scroll{tab_id = get_u64(&r, "tab_id"), anchor = get_str(&r, "anchor", optional = true), line = int(opt_u64(&r, "line"))}
	case "markdown_link":       cmd = Markdown_Follow{tab_id = get_u64(&r, "tab_id"), url = get_str(&r, "url"), confirm = get_str(&r, "confirm", optional = true)}
	case "new_app_tab":         cmd = New_App_Tab{session = opt_u64(&r, "session"), name = get_str(&r, "name", optional = true), argv = get_strings(&r, "argv"), command = get_str(&r, "command", optional = true), cwd = get_str(&r, "cwd", optional = true), title = get_str(&r, "title", optional = true)}
	case "app_restart":         cmd = App_Restart{tab_id = get_u64(&r, "tab_id")}
	case "app_close":           cmd = App_Close{tab_id = get_u64(&r, "tab_id"), confirm = get_str(&r, "confirm", optional = true), comments = opt_comments(&r)}
	case "app_declared":        cmd = App_Declared{session = opt_u64(&r, "session")}
	case "app_input":           cmd = App_Input{tab_id = get_u64(&r, "tab_id"), events = get_raw_list(&r, "events")}
	case "app_events":          cmd = App_Events{tab_id = get_u64(&r, "tab_id"), topic = get_str(&r, "topic"), since = opt_u64(&r, "since"), limit = int(min(opt_u64(&r, "limit"), 500))}
	case "app_call":            cmd = App_Call{tab_id = get_u64(&r, "tab_id"), method = get_str(&r, "method"), params = "params" in r.obj ? get_raw(&r, "params") : "", timeout_ms = int(min(opt_u64(&r, "timeout_ms"), 600000))}
	case "app_screenshot":
		sc := App_Screenshot{tab_id = get_u64(&r, "tab_id")}
		if rv, has := r.obj["rect"]; has {
			o, is := rv.(json.Object)
			x, y, w, h := num_of(o["x"]), num_of(o["y"]), num_of(o["w"]), num_of(o["h"])
			if !is || x == nil || y == nil || w == nil || h == nil {
				if r.err == "" do r.err = "rect must be {x, y, w, h} (numbers)"
			} else do sc.rect, sc.has_rect = {x.?, y.?, w.?, h.?}, true
		}
		cmd = sc
	case "app_inspect":         cmd = App_Inspect{tab_id = get_u64(&r, "tab_id"), on = get_bool(&r, "on")}
	case "notifications_list":  cmd = Notifications_List{limit = int(min(opt_u64(&r, "limit"), NOTICES_MAX))}
	case "mark_all_read":       cmd = Mark_All_Read{}
	case "set_unread":          cmd = Set_Unread{tab_id = opt_u64(&r, "tab_id"), pi_session_id = get_str(&r, "pi_session_id", optional = true), unread = get_bool(&r, "unread")}
	case "notifications_mark_read": cmd = Notifications_Mark_Read{id = opt_u64(&r, "id"), session = opt_u64(&r, "session"), all = opt_bool(&r, "all").? or_else false}
	case "notifications_clear": cmd = Notifications_Clear{}
	case "set_notifications":
		sb := Set_Bell{finished = opt_bool(&r, "finished"), waiting = opt_bool(&r, "waiting"), errors = opt_bool(&r, "errors"), jobs = opt_bool(&r, "jobs"), os = opt_bool(&r, "os"), dock = opt_bool(&r, "dock")}
		sb.macos = bell_choices(&r, "macos", OS_WHEN_NAMES)
		sb.sound = bell_choices(&r, "sound", BELL_SOUND_NAMES)
		cmd = sb
	case "job_list":            cmd = Job_List{unread = opt_bool(&r, "unread").? or_else false}
	case "job_runs":            cmd = Job_Runs{job = get_str(&r, "job"), limit = int(min(opt_u64(&r, "limit"), 1000))}
	case "job_run_now":         cmd = Job_Run_Now{job = get_str(&r, "job")}
	case "job_stop":            cmd = Job_Stop{job = get_str(&r, "job", optional = true)}
	case "jobs_pause":          cmd = Jobs_Pause{job = get_str(&r, "job", optional = true)}
	case "jobs_resume":         cmd = Jobs_Resume{job = get_str(&r, "job", optional = true)}
	case "job_save":            cmd = Job_Save{path = get_str(&r, "path", optional = true), text = get_str(&r, "text"), based_on = get_str(&r, "based_on", optional = true)}
	case "job_sheet":           cmd = Job_Sheet{open = get_bool(&r, "open"), job = get_str(&r, "job", optional = true), for_project = get_str(&r, "for_project", optional = true)}
	case "job_create":          cmd = Job_Create{name = get_str(&r, "name", optional = true), schedule = get_str(&r, "schedule", optional = true), prompt = get_str(&r, "prompt", optional = true), folder = get_str(&r, "folder", optional = true), for_project = get_str(&r, "for_project", optional = true)}
	case "job_mark_read":       cmd = Job_Mark_Read{job = get_str(&r, "job", optional = true), run = get_str(&r, "run", optional = true)}
	case "job_approve":         return nil, JOB_APPROVE_REMOVED
	case "job_set_enabled":     cmd = Job_Set_Enabled{job = get_str(&r, "job"), on = get_bool(&r, "on")}
	case "job_delete":          cmd = Job_Delete{job = get_str(&r, "job"), confirm = get_str(&r, "confirm", optional = true)}
	case "job_open":            cmd = Job_Open{job = get_str(&r, "job"), what = get_str(&r, "what")}
	case "set_notes_dir":       cmd = Set_Home_Dir{path = get_str(&r, "path", optional = true)} // the old name
	case "set_pi_path":         cmd = Set_Pi_Path{path = get_str(&r, "path")}
	case "set_job_limits":
		f :: opt_f64
		n :: proc(r: ^Rd, k: string) -> Maybe(int) {if _, ok := r.obj[k]; !ok do return nil; return int(min(get_u64(r, k), 1 << 30))}
		t :: proc(r: ^Rd, k: string) -> Maybe(i64) {if _, ok := r.obj[k]; !ok do return nil; return i64(min(get_u64(r, k), 1 << 40))}
		cmd = Set_Job_Limits{max_cost = f(&r, "max_cost"), day = f(&r, "day"), week = f(&r, "week"), month = f(&r, "month"), timeout = t(&r, "timeout"), stall = t(&r, "stall"), max_turns = n(&r, "max_turns"), concurrency = n(&r, "concurrency"), loop_calls = n(&r, "loop_calls"), fail_pause = n(&r, "fail_pause")}
	// pending comments (comments.odin); comment_add is internal only
	case "comment_edit":        cmd = Comment_Edit{comment_id = get_u64(&r, "comment_id"), text = get_str(&r, "text")}
	case "comment_delete":      cmd = Comment_Delete{comment_id = get_u64(&r, "comment_id")}
	case "comments_clear":      cmd = Comments_Clear{session = get_u64(&r, "session")}
	case "comments_send_now":   cmd = Comments_Send_Now{session = get_u64(&r, "session"), tab_id = opt_u64(&r, "tab_id")}
	case "comments_ask_cancel": cmd = Comments_Ask_Cancel{}
	case "pi.attached":         cmd = Pi_Attached{tab_id = opt_u64(&r, "tab_id"), attachment_id = get_u64(&r, "attachment_id")}
	// Claude Code tabs (claude.odin)
	case "new_claude_tab":      cmd = New_Claude_Tab{session = opt_u64(&r, "session"), project_id = opt_u64(&r, "project_id"), cwd = get_str(&r, "cwd", optional = true), resume = get_str(&r, "resume", optional = true), args = get_strings(&r, "args"), account = get_str(&r, "account", optional = true)}
	case "add_claude_account":  cmd = Add_Claude_Account{dir = get_str(&r, "dir"), label = get_str(&r, "label", optional = true)}
	case "rename_claude_account": cmd = Rename_Claude_Account{account = get_str(&r, "account"), label = get_str(&r, "label", optional = true)}
	case "remove_claude_account": cmd = Remove_Claude_Account{account = get_str(&r, "account")}
	case "set_claude_account_default": cmd = Set_Claude_Account_Default{account = get_str(&r, "account", optional = true)}
	case "claude_resume":       cmd = Claude_Resume{claude_session_id = get_str(&r, "claude_session_id")}
	case "new_claude_session":  cmd = New_Claude_Session{project_id = get_u64(&r, "project_id"), cwd = get_str(&r, "cwd", optional = true), args = get_strings(&r, "args"), account = get_str(&r, "account", optional = true)}
	case "claude_rename":       cmd = Claude_Rename{claude_session_id = get_str(&r, "claude_session_id"), title = get_str(&r, "title")}
	case "claude_wait_idle":    cmd = Claude_Wait_Idle{tab_id = get_u64(&r, "tab_id"), timeout_ms = opt_u64(&r, "timeout_ms"), prompt_id = opt_u64(&r, "prompt_id")}
	case "claude_prompt":       cmd = Claude_Prompt{tab_id = get_u64(&r, "tab_id"), text = get_str(&r, "text")}
	case "claude_held":         cmd = Claude_Held_Op{tab_id = get_u64(&r, "tab_id"), op = get_str(&r, "op")}
	case "claude.session":      cmd = Claude_Session_Report{tab_id = opt_u64(&r, "tab_id"), session_id = get_str(&r, "session_id"), cwd = get_str(&r, "cwd", optional = true), source = get_str(&r, "source", optional = true), transcript_path = get_str(&r, "transcript_path", optional = true), model = get_str(&r, "model", optional = true)}
	case "claude.readonly_ack": cmd = Claude_Readonly_Ack{tab_id = opt_u64(&r, "tab_id"), nonce = get_str(&r, "nonce")}
	case "claude.turn":         cmd = Claude_Turn_Report{tab_id = opt_u64(&r, "tab_id"), state = get_str(&r, "state"), title = get_str(&r, "title", optional = true), question = opt_bool(&r, "question").? or_else false, idle_prompt = opt_bool(&r, "idle_prompt").? or_else false}
	case "claude.comments":     cmd = Claude_Comments{tab_id = opt_u64(&r, "tab_id"), max = int(min(opt_u64(&r, "max"), 1 << 20))}
	case "claude.attached":     cmd = Claude_Attached{tab_id = opt_u64(&r, "tab_id"), attachment_id = get_u64(&r, "attachment_id")}
	case "claude_restart":      cmd = Claude_Restart{tab_id = get_u64(&r, "tab_id"), pick_model = opt_bool(&r, "pick_model").? or_else false}
	case "claude_restart_changed": cmd = Claude_Restart_Changed{update = opt_bool(&r, "update").? or_else false, all = opt_bool(&r, "all").? or_else false, confirm = get_str(&r, "confirm", optional = true)}
	case "claude_reload_later": cmd = Claude_Reload_Later{update = opt_bool(&r, "update").? or_else false}
	case "claude.todos":        cmd = Claude_Todos{tab_id = opt_u64(&r, "tab_id"), todos = get_todos(&r, "todos"), agent_id = get_str(&r, "agent_id", optional = true), seq = opt_u64(&r, "seq")}
	case "claude.task":         cmd = Claude_Task{tab_id = opt_u64(&r, "tab_id"), event = get_str(&r, "event"), task_id = get_str(&r, "task_id"), subject = get_str(&r, "subject", optional = true), active_form = get_str(&r, "active_form", optional = true), status = get_str(&r, "status", optional = true), seq = opt_u64(&r, "seq")}
	case "claude.model":        cmd = Claude_Model_Report{tab_id = opt_u64(&r, "tab_id"), model = get_str(&r, "model")}
	case "claude.subagent":     cmd = Claude_Subagent{tab_id = opt_u64(&r, "tab_id"), event = get_str(&r, "event"), agent_id = get_str(&r, "agent_id", optional = true), agent_type = get_str(&r, "agent_type", optional = true), description = get_str(&r, "description", optional = true), tool_name = get_str(&r, "tool_name", optional = true), seq = opt_u64(&r, "seq")}
	case "claude.background":   cmd = Claude_Background{tab_id = opt_u64(&r, "tab_id"), event = get_str(&r, "event"), task_id = get_str(&r, "task_id", optional = true), kind = get_str(&r, "kind", optional = true), description = get_str(&r, "description", optional = true), command = get_str(&r, "command", optional = true), tasks = get_bg_tasks(&r, "tasks"), crons = get_bg_crons(&r, "crons"), seq = opt_u64(&r, "seq")}
	case "":                    return nil, "missing field type"
	case:
		bc, ok := browser_command_parse(t, &r) // below
		if !ok do return nil, strings.concatenate({"unknown command ", t}, context.temp_allocator)
		cmd = bc
	}
	if r.err != "" {
		command_free(cmd, allocator)
		return nil, r.err
	}
	return cmd, ""
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
				tab.kind = Claude_Tab{session_id = get_str(&t, "claude_session_id", optional = true)}
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
		s.settings.chats_readonly = opt_bool(&sr, "chats_readonly").? or_else false
		s.settings.claude_skip_permissions = opt_bool(&sr, "claude_skip_permissions").? or_else false
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

// browser tabs' commands (browser_nav.odin)
@(private = "file")
browser_command_parse :: proc(t: string, r: ^Rd) -> (cmd: Command, ok: bool) {
	switch t {
	case "browser_open":     return Browser_Open{session = opt_u64(r, "session"), url = get_str(r, "url", optional = true)}, true
	case "browser_navigate": return Browser_Navigate{tab_id = get_u64(r, "tab_id"), url = get_str(r, "url")}, true
	case "browser_back":     return Browser_Back{tab_id = get_u64(r, "tab_id")}, true
	case "browser_forward":  return Browser_Forward{tab_id = get_u64(r, "tab_id")}, true
	case "browser_reload":   return Browser_Reload{tab_id = get_u64(r, "tab_id")}, true
	case "browser_stop":     return Browser_Stop{tab_id = get_u64(r, "tab_id")}, true
	// browser_polish.odin
	case "browser_zoom":
		step, _ := enum_of(r, "step", BROWSER_ZOOM_STEP_NAMES)
		return Browser_Zoom{tab_id = get_u64(r, "tab_id"), step = step}, true
	case "browser_find":       return Browser_Find{tab_id = get_u64(r, "tab_id"), text = get_str(r, "text"), back = opt_bool(r, "back").? or_else false}, true
	case "browser_find_close": return Browser_Find_Close{tab_id = get_u64(r, "tab_id")}, true
	case "browser_dialog":     return Browser_Dialog{tab_id = get_u64(r, "tab_id"), ok = get_bool(r, "ok"), text = get_str(r, "text", optional = true)}, true
	case "browser_permission": return Browser_Permission{tab_id = get_u64(r, "tab_id"), allow = get_bool(r, "allow")}, true
	case "browser_popup":      return Browser_Popup{tab_id = get_u64(r, "tab_id"), open = get_bool(r, "open")}, true
	case "browser_edit":
		op, _ := enum_of(r, "op", BROWSER_EDIT_OP_NAMES)
		return Browser_Edit{tab_id = get_u64(r, "tab_id"), op = op}, true
	case "browser_devtools":
		x, y := i32(-1), i32(-1)
		if _, has := r.obj["x"]; has do x = i32(min(get_u64(r, "x"), 1 << 20))
		if _, has := r.obj["y"]; has do y = i32(min(get_u64(r, "y"), 1 << 20))
		return Browser_Devtools{tab_id = get_u64(r, "tab_id"), x = x, y = y, close = opt_bool(r, "close").? or_else false}, true
	case "browser_external":   return Browser_External{tab_id = get_u64(r, "tab_id")}, true
	case "browser_download":
		op, _ := enum_of(r, "op", BROWSER_DOWNLOAD_OP_NAMES)
		return Browser_Download{download_id = get_u64(r, "download_id"), op = op}, true
	// agents read pages (browser_agent.odin)
	case "browser_tabs":     return Browser_Tabs{session = opt_u64(r, "session")}, true
	case "browser_read":     return Browser_Read{tab_id = get_u64(r, "tab_id"), mode = get_str(r, "mode", optional = true), selector = get_str(r, "selector", optional = true), max = int(min(opt_u64(r, "max"), 1 << 30))}, true
	case "browser_screenshot":
		sc := Browser_Screenshot{tab_id = get_u64(r, "tab_id")}
		if rv, has := r.obj["rect"]; has {
			o, is := rv.(json.Object)
			x, y, w, h := num_of(o["x"]), num_of(o["y"]), num_of(o["w"]), num_of(o["h"])
			if !is || x == nil || y == nil || w == nil || h == nil {
				if r.err == "" do r.err = "rect must be {x, y, w, h} (numbers)"
			} else do sc.rect, sc.has_rect = {x.?, y.?, w.?, h.?}, true
		}
		return sc, true
	case "browser_wait":     return Browser_Page_Wait{tab_id = get_u64(r, "tab_id"), what = get_str(r, "for"), value = get_str(r, "value", optional = true), timeout_ms = int(min(opt_u64(r, "timeout_ms"), 600000))}, true
	case "browser_console":  return Browser_Console{tab_id = get_u64(r, "tab_id"), since = opt_u64(r, "since"), limit = int(min(opt_u64(r, "limit"), 1000))}, true
	case "browser_network":  return Browser_Network{tab_id = get_u64(r, "tab_id"), since = opt_u64(r, "since"), limit = int(min(opt_u64(r, "limit"), 1000))}, true
	case "browser_comments": return Browser_Comments{tab_id = opt_u64(r, "tab_id"), session = opt_u64(r, "session")}, true
	case "browser_agent_stop": return Browser_Agent_Stop{tab_id = get_u64(r, "tab_id")}, true
	// agents act on pages (browser_act.odin)
	case "browser_click":
		c := Browser_Click{tab_id = get_u64(r, "tab_id"), target = act_target_of(r), double = opt_bool(r, "double").? or_else false, modifiers = act_mods_of(r)}
		if _, has := r.obj["button"]; has do c.button, _ = enum_of(r, "button", ACT_BUTTON_NAMES)
		return c, true
	case "browser_hover":  return Browser_Hover{tab_id = get_u64(r, "tab_id"), target = act_target_of(r)}, true
	case "browser_scroll": return Browser_Scroll{tab_id = get_u64(r, "tab_id"), target = act_target_of(r), dx = opt_f32(r, "dx").? or_else 0, dy = opt_f32(r, "dy").? or_else 0}, true
	case "browser_type":
		return Browser_Type{tab_id = get_u64(r, "tab_id"), selector = get_str(r, "selector", optional = true), text = get_str(r, "text", optional = true), clear = opt_bool(r, "clear").? or_else false, submit = opt_bool(r, "submit").? or_else false}, true
	case "browser_press":  return Browser_Press{tab_id = get_u64(r, "tab_id"), selector = get_str(r, "selector", optional = true), keys = get_str(r, "keys")}, true
	case "browser_select":
		_, has_label := r.obj["label"]
		_, has_value := r.obj["value"]
		return Browser_Select{tab_id = get_u64(r, "tab_id"), selector = get_str(r, "selector", optional = true), label = get_str(r, "label", optional = true), value = get_str(r, "value", optional = true), has_label = has_label, has_value = has_value}, true
	case "browser_upload": return Browser_Upload{tab_id = get_u64(r, "tab_id"), selector = get_str(r, "selector", optional = true), paths = get_strings(r, "paths")}, true
	case "browser_upload_answer": return Browser_Upload_Answer{tab_id = get_u64(r, "tab_id"), allow = get_bool(r, "allow")}, true
	case "browser_agent_take_over": return Browser_Agent_Take_Over{tab_id = get_u64(r, "tab_id"), on = get_bool(r, "on")}, true
	}
	return nil, false
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
	for name in get_strings(r, "modifiers") {
		found := false
		for n, i in ACT_MOD_NAMES do if n == name {
			m |= 1 << uint(i)
			found = true
		}
		if !found && r.err == "" do r.err = "modifiers are alt, control, meta, shift"
	}
	return m
}

// A string field naming one of an enum's values (names: its wire names). The string is not kept.
@(private = "file")
enum_of :: proc(r: ^Rd, k: string, names: [$E]string) -> (E, bool) {
	v, has := need(r, k)
	if !has do return {}, false
	s, is := v.(json.String)
	if is do for name, e in names do if name == s do return e, true
	if r.err == "" do r.err = strings.concatenate({k, " must be one of its names"}, context.temp_allocator)
	return {}, false
}
