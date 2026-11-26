package core

// Every command's JSON from its struct (issue #195): json_write.odin's write_command and
// json_read.odin's parser walk a command's fields in order, as the field's `cmd` tag says; the
// inbox copies and frees each field with state_read.odin's wire_clone and wire_free. A new
// command is its struct, its place in the Command union and its row in COMMAND_SPECS; its wire
// name is its type's name lowercased unless COMMAND_NAMES says otherwise.
//
// A field with no tag is written always (log, redacted log and wire alike) under its own name
// and is required when parsed. The tag `cmd:"a,b,..."` changes that:
//
//   key=K      its key on the wire is K
//   omit       written only when not zero; optional when parsed (absent: zero)
//   opt        optional when parsed (absent: zero, or def), written always
//   req        required when parsed (with omit)
//   last       written after the fields without it
//   first      parsed before the fields without it (whose errors then come second)
//   def=N      parsed: absent is N (a number)
//   max=N      parsed: a number above N is N
//   signed     a signed number is written as one (else as its bits unsigned: -1 is 2^64-1)
//   pos        a signed number is written as 0 when negative
//   nonneg     a signed number is left out when negative
//   -          never written nor parsed
//   noparse    never parsed (stays zero)
//   ui         parsed only from the window's own commands (parse_command_ui); written only on
//              the wire (command_wire_json), never in the log
//   log=T      in the log and the redacted log (and on the wire, unless `full`) as T
//   red=T      in the redacted log as T
//   full       on the wire as it is, whatever log= says
//   names=N    an enum's wire names from the table N (cmd_enum_names), not its lowercased names
//   codec=C    written and parsed by json_write.odin's and json_read.odin's codec C
//   borrow     the inbox's copy shares it with the original, and command_free leaves it: a
//              value handed over to the command's handler, or borrowed for a command that is
//              never queued
//
// where T (cmd_transform) is one of
//
//   -          left out
//   bytes      "<redacted N bytes>" (N: the string's length)
//   len        its length (a string's bytes, a list's items) as a number, under its own key
//   len:K      the same under key K
//   token      "<redacted>"
//   url        the address without user:pass@ (browser_url_redacted)
//   path       "<path>"
//   blockers   each of a pi tab's blockers as blocker_redacted keeps it
//   items:W    "<redacted N W>" (N: the list's length)
//   cut:N      the string's first N bytes (whole UTF-8 characters)
//   f3         a number with 3 decimals
//
// The few commands whose log no tag can say are written by hand (json_write.odin's
// write_command_hook). tests/command-codec/golden.txt pins every command's JSON
// (command_golden_test.odin).

import "base:runtime"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

// Wire names that are not the type's name lowercased.
COMMAND_NAMES := [?]struct {
	id:   typeid,
	name: string,
} {
	{Open_Session_Cmd, "open_session"},
	{Reveal_Path, "reveal"},
	{Pi_Session_Update, "pi.session"},
	{Pi_Status_Update, "pi.status"},
	{Panel_Set, "panel.set"},
	{Panel_Remove, "panel.remove"},
	{Goto_Line, "goto"},
	{Set_Bell, "set_notifications"},
	{Markdown_Set_View, "markdown_view"},
	{Markdown_Follow, "markdown_link"},
	{Pi_Attached, "pi.attached"},
	{Browser_Page_Wait, "browser_wait"},
	{Claude_Session_Report, "claude.session"},
	{Claude_Turn_Report, "claude.turn"},
	{Claude_Comments, "claude.comments"},
	{Claude_Attached, "claude.attached"},
	{Claude_Held_Op, "claude_held"},
	{Claude_Readonly_Ack, "claude.readonly_ack"},
	{Claude_Todos, "claude.todos"},
	{Claude_Task, "claude.task"},
	{Claude_Subagent, "claude.subagent"},
	{Claude_Background, "claude.background"},
	{Claude_Model_Report, "claude.model"},
}

Cmd_Tx :: enum u8 {
	None,
	Drop,
	Bytes,
	Len,
	Token,
	Url,
	Path,
	Blockers,
	Items,
	Cut,
	F3,
}

Cmd_Transform :: struct {
	tx:  Cmd_Tx,
	arg: string, // len:K's key, items:W's word
	n:   int, // cut:N's N
}

// A number in a tag: digits, or one of the constants a tag may name.
@(private = "file")
cmd_number :: proc(s: string) -> (int, bool) {
	switch s {
	case "CLAUDE_KEY_MAX":   return CLAUDE_KEY_MAX, true
	case "FIND_FILES_MAX":   return FIND_FILES_MAX, true
	case "NOTICES_MAX":      return NOTICES_MAX, true
	}
	return strconv.parse_int(s)
}

Cmd_Field :: struct {
	name, key:   string,
	offset:      uintptr,
	ti:          ^runtime.Type_Info,
	omit, opt:   bool,
	skip:        bool, // `-`
	no_parse:    bool,
	ui, full:    bool,
	pos, nonneg: bool,
	signed:      bool,
	last, first: bool,
	borrow:      bool,
	log, red:    Cmd_Transform,
	def:         Maybe(f64),
	max:         Maybe(u64),
	names:       []string, // an enum's wire names, by value - names_min
	names_min:   i64,
	codec:       string,
}

Cmd_Info :: struct {
	id:     typeid,
	name:   string,
	ti:     ^runtime.Type_Info,
	fields: []Cmd_Field,
	parsed: bool, // the parser reads it (its COMMAND_SPECS row is not Internal)
}

// By the Command union's variant index (its tag - 1).
command_infos: []Cmd_Info
// Wire name -> index into command_infos, for the commands the parser reads.
command_by_name: map[string]int

// The enum tables a `names=` tag may name.
@(private = "file")
cmd_enum_names :: proc(name: string) -> (names: []string, min: i64, ok: bool) {
	t :: proc(x: ^[$E]string) -> ([]string, i64, bool) {return slice.enumerated_array(x), i64(min(E)), true}
	switch name {
	case "caller":     return t(&CALLER_NAMES)
	case "class":      return t(&CLASS_NAMES)
	case "mode":       return t(&MODE_NAMES)
	case "close":      return t(&CLOSE_NAMES)
	case "agent":      return t(&AGENT_NAMES)
	case "tab_kind":   return t(&TAB_KIND_NAMES)
	case "sort_section": return t(&SORT_SECTION_NAMES)
	case "sort_by":    return t(&SORT_BY_NAMES)
	case "sidebar_view": return t(&SIDEBAR_VIEW_NAMES)
	case "fold":       return t(&FOLD_NAMES)
	case "comments":   return t(&COMMENTS_CHOICE_NAMES)
	case "folder":     return t(&FOLDER_NAMES)
	case "harness":    return t(&HARNESS_KEYS)
	case "pane_dir":   return t(&PANE_DIR_NAMES)
	case "theme":      return t(&THEME_NAMES)
	case "appearance": return t(&APPEARANCE_NAMES)
	case "text_size":  return t(&TEXT_SIZE_NAMES)
	case "editor_view": return t(&EDITOR_VIEW_NAMES)
	case "left_tab":   return t(&LEFT_TAB_NAMES)
	case "app_status": return t(&APP_STATUS_NAMES)
	case "comment_source": return t(&COMMENT_SOURCE_NAMES)
	case "app_socket_op": return t(&APP_SOCKET_OP_NAMES)
	case "zoom_step":  return t(&BROWSER_ZOOM_STEP_NAMES)
	case "edit_op":    return t(&BROWSER_EDIT_OP_NAMES)
	case "download_op": return t(&BROWSER_DOWNLOAD_OP_NAMES)
	case "act_button": return t(&ACT_BUTTON_NAMES)
	}
	return nil, 0, false
}

@(private = "file")
cmd_transform :: proc(s: string) -> (t: Cmd_Transform, ok: bool) {
	head, _, arg := strings.partition(s, ":")
	t.arg = arg
	switch head {
	case "-":        t.tx = .Drop
	case "bytes":    t.tx = .Bytes
	case "len":      t.tx = .Len
	case "token":    t.tx = .Token
	case "url":      t.tx = .Url
	case "path":     t.tx = .Path
	case "blockers": t.tx = .Blockers
	case "items":    t.tx = .Items
	case "cut":
		t.tx = .Cut
		n, nok := cmd_number(arg)
		if !nok do return {}, false
		t.n = n
	case "f3":       t.tx = .F3
	case:            return {}, false
	}
	return t, true
}

// A tag's problem ("" = none), for the codec's test.
command_tag_problems: [dynamic]string

@(private = "file")
cmd_field :: proc(type_name: string, name: string, tag: string, offset: uintptr, ti: ^runtime.Type_Info) -> Cmd_Field {
	f := Cmd_Field{name = name, key = name, offset = offset, ti = ti}
	bad :: proc(type_name, name, what: string) {
		append(&command_tag_problems, strings.concatenate({type_name, ".", name, ": ", what}))
	}
	v, _ := reflect.struct_tag_lookup(reflect.Struct_Tag(tag), "cmd")
	for opt in strings.split(v, ",", context.temp_allocator) {
		k, _, arg := strings.partition(opt, "=")
		switch k {
		case "":
		case "key":     f.key = arg
		case "omit":    f.omit, f.opt = true, true
		case "opt":     f.opt = true
		case "-":       f.skip, f.no_parse = true, true
		case "noparse": f.no_parse = true
		case "ui":      f.ui, f.full, f.log = true, true, {tx = .Drop}
		case "full":    f.full = true
		case "pos":     f.pos = true
		case "signed":  f.signed = true
		case "last":    f.last = true
		case "first":   f.first = true
		case "borrow":  f.borrow = true
		case "req":     f.opt = false
		case "nonneg":  f.nonneg = true
		case "log", "red":
			t, ok := cmd_transform(arg)
			if !ok do bad(type_name, name, opt)
			if k == "log" do f.log = t
			else do f.red = t
		case "def":
			x, ok := strconv.parse_f64(arg)
			if !ok do bad(type_name, name, opt)
			f.def = x
		case "max":
			x, ok := cmd_number(arg)
			if !ok do bad(type_name, name, opt)
			f.max = u64(x)
		case "names":
			names, lo, ok := cmd_enum_names(arg)
			if !ok do bad(type_name, name, opt)
			f.names, f.names_min = names, lo
		case "codec":   f.codec = arg
		case:           bad(type_name, name, opt)
		}
	}
	return f
}

@(init, private = "file")
command_codec_init :: proc "contextless" () {
	context = runtime.default_context()
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	command_infos = make([]Cmd_Info, len(u.variants))
	for vt, i in u.variants {
		info := &command_infos[i]
		info.id, info.ti = vt.id, vt
		named := vt.variant.(runtime.Type_Info_Named)
		info.name = strings.to_lower(named.name)
		for x in COMMAND_NAMES do if x.id == vt.id do info.name = x.name
		st := runtime.type_info_base(vt).variant.(runtime.Type_Info_Struct)
		info.fields = make([]Cmd_Field, st.field_count)
		for k in 0 ..< int(st.field_count) do info.fields[k] = cmd_field(named.name, st.names[k], st.tags[k], st.offsets[k], st.types[k])
		if spec := command_spec(info.name); spec != nil && spec.who != .Internal {
			info.parsed = true
			command_by_name[info.name] = i
		}
	}
	free_all(context.temp_allocator)
}

// The info of a command's variant (nil for a nil command).
command_info :: proc(cmd: Command) -> ^Cmd_Info {
	tag := reflect.get_union_variant_raw_tag(cmd)
	if tag <= 0 || int(tag) > len(command_infos) do return nil
	return &command_infos[tag - 1]
}

// Whether a field's value (at data) is its type's zero: "", 0, false, an empty list, nil.
cmd_is_zero :: proc(data: rawptr, ti: ^runtime.Type_Info) -> bool {
	#partial switch t in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_String:
		return len((^string)(data)^) == 0
	case runtime.Type_Info_Slice:
		return (^runtime.Raw_Slice)(data).len == 0
	case runtime.Type_Info_Dynamic_Array:
		return (^runtime.Raw_Dynamic_Array)(data).len == 0
	}
	bytes := ([^]u8)(data)[:ti.size]
	for x in bytes do if x != 0 do return false
	return true
}

// Another field of the command at cmd, by name (a codec's: has_rect beside rect).
cmd_sibling :: proc(info: ^Cmd_Info, cmd: ^Command, name: string) -> rawptr {
	for &f in info.fields do if f.name == name do return rawptr(uintptr(cmd) + f.offset)
	panic("command_codec: no such field")
}
