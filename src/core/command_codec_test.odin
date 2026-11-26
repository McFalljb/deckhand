package core

// command_codec.odin's checks: its tags, the decisions they record, and that each redaction or
// clamp a tag asks for changes what is written or parsed (the samples: command_golden_test.odin).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

// Every command's `cmd` tags say something command_codec.odin knows.
@(test)
command_codec_tags :: proc(t: ^testing.T) {
	for p in command_tag_problems do testing.expectf(t, false, "%s", p)
}

// ---- what a tag would get wrong, refused ----

@(private = "file")
Zz_Codec_Typo :: struct {
	params: string `cmd:"codec=raww"`,
}
@(private = "file")
Zz_Codec_No_Sibling :: struct {
	rect: App_Rect `cmd:"codec=rect"`,
}
@(private = "file")
Zz_Codec_Half_Sibling :: struct {
	x: i32 `cmd:"codec=xy"`,
}
@(private = "file")
Zz_Codec_Wrong_Type :: struct {
	params: []string `cmd:"codec=raw"`,
}
@(private = "file")
Zz_Codec_Enum_No_Names :: struct {
	op: Browser_Edit_Op `cmd:"codec=enum_of"`,
}
@(private = "file")
Zz_Ui_Logged :: struct {
	text: string `cmd:"ui,log=len"`,
}
@(private = "file")
Zz_Red_Typo :: struct {
	text: string `cmd:"red=urll"`,
}
@(private = "file")
Zz_Log_Typo :: struct {
	text: string `cmd:"log=byts"`,
}
@(private = "file")
Zz_Pointer :: struct {
	run: ^Job_Run `cmd:"-"`,
}
@(private = "file")
Zz_Unknown :: struct {
	text: string `cmd:"redact"`,
}
@(private = "file")
Zz_Ui_Red :: struct {
	text: string `cmd:"ui,red=cut:4"`,
}
@(private = "file")
Zz_Skip_Red :: struct {
	text: string `cmd:"-,red=bytes"`,
}
@(private = "file")
Zz_Skip_Log :: struct {
	text: string `cmd:"-,log=len"`,
}
@(private = "file")
Zz_Url_On_Number :: struct {
	n: u64 `cmd:"red=url"`,
}
@(private = "file")
Zz_Cut_On_List :: struct {
	list: []string `cmd:"log=cut:4"`,
}
@(private = "file")
Zz_F3_On_String :: struct {
	text: string `cmd:"log=f3"`,
}
@(private = "file")
Zz_Blockers_On_String :: struct {
	text: string `cmd:"red=blockers"`,
}
@(private = "file")
Zz_Items_On_Int :: struct {
	n: int `cmd:"red=items:rows"`,
}
@(private = "file")
Zz_Fine_Transforms :: struct {
	url:      Maybe(string) `cmd:"red=url"`,
	text:     string `cmd:"red=cut:4"`,
	list:     []string `cmd:"log=len,red=items:rows"`,
	blockers: []string `cmd:"red=blockers"`,
	ratio:    f32 `cmd:"log=f3"`,
	n:        u64 `cmd:"log=-"`,
}
@(private = "file")
Zz_Fine :: struct {
	rect:     App_Rect `cmd:"codec=rect"`,
	has_rect: bool `cmd:"-"`,
	run:      ^Job_Run `cmd:"-,borrow"`,
}

// The problems cmd_info_of finds in T's tags (taken back out of command_tag_problems).
@(private = "file")
cc_problems :: proc($T: typeid) -> (Cmd_Info, []string) {
	context.allocator = context.temp_allocator
	n := len(command_tag_problems)
	info := cmd_info_of(type_info_of(T))
	out := slice.clone(command_tag_problems[n:], context.temp_allocator)
	resize(&command_tag_problems, n) // (their text is the temp allocator's)
	return info, out
}

@(test)
command_codec_refuses :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, $T: typeid, want: string) -> Cmd_Info {
		info, ps := cc_problems(T)
		joined := strings.join(ps, "; ", context.temp_allocator)
		testing.expectf(t, want == "" ? len(ps) == 0 : strings.contains(joined, want), "%v: want %q, got %q", typeid_of(T), want, joined)
		return info
	}
	check(t, Zz_Codec_Typo, "no such codec")
	check(t, Zz_Codec_No_Sibling, "no sibling field has_rect")
	check(t, Zz_Codec_Half_Sibling, "no sibling field y")
	check(t, Zz_Codec_Wrong_Type, "wants another field type")
	check(t, Zz_Codec_Enum_No_Names, "wants an enum with names=")
	check(t, Zz_Ui_Logged, "ui with log=")
	check(t, Zz_Pointer, "holds a pointer")
	check(t, Zz_Unknown, "redact")
	// a mistyped transform leaves the field out, never in as it is
	red := check(t, Zz_Red_Typo, "red=urll")
	testing.expect_value(t, red.fields[0].red.tx, Cmd_Tx.Drop)
	lg := check(t, Zz_Log_Typo, "log=byts")
	testing.expect_value(t, lg.fields[0].log.tx, Cmd_Tx.Drop)
	check(t, Zz_Fine, "")
	// ui and - fields are never in the log: a red= or log= on one is a mistake, and is left out
	ui := check(t, Zz_Ui_Red, "ui with red=")
	testing.expect_value(t, ui.fields[0].red.tx, Cmd_Tx.Drop)
	sk := check(t, Zz_Skip_Red, "- with red=")
	testing.expect_value(t, sk.fields[0].red.tx, Cmd_Tx.Drop)
	check(t, Zz_Skip_Log, "- with log=")
	// a transform on a field of a type it cannot read: refused, and left out
	nu := check(t, Zz_Url_On_Number, "red=url wants")
	testing.expect_value(t, nu.fields[0].red.tx, Cmd_Tx.Drop)
	cl := check(t, Zz_Cut_On_List, "log=cut:4 wants")
	testing.expect_value(t, cl.fields[0].log.tx, Cmd_Tx.Drop)
	check(t, Zz_F3_On_String, "log=f3 wants")
	check(t, Zz_Blockers_On_String, "red=blockers wants")
	check(t, Zz_Items_On_Int, "red=items:rows wants")
	check(t, Zz_Fine_Transforms, "")
	free_all(context.temp_allocator)
}

// ---- decisions, not defaults ----

// Whether a value of type ti holds a string.
@(private = "file")
cc_holds_string :: proc(ti: ^runtime.Type_Info, seen: ^map[typeid]bool) -> bool {
	if ti.id in seen^ do return false
	seen[ti.id] = true
	#partial switch t in ti.variant {
	case runtime.Type_Info_Named:            return cc_holds_string(t.base, seen)
	case runtime.Type_Info_String:           return true
	case runtime.Type_Info_Struct:
		for k in 0 ..< int(t.field_count) do if cc_holds_string(t.types[k], seen) do return true
	case runtime.Type_Info_Union:
		for v in t.variants do if cc_holds_string(v, seen) do return true
	case runtime.Type_Info_Slice:            return cc_holds_string(t.elem, seen)
	case runtime.Type_Info_Dynamic_Array:    return cc_holds_string(t.elem, seen)
	case runtime.Type_Info_Array:            return cc_holds_string(t.elem, seen)
	case runtime.Type_Info_Enumerated_Array: return cc_holds_string(t.elem, seen)
	case runtime.Type_Info_Map:              return cc_holds_string(t.key, seen) || cc_holds_string(t.value, seen)
	}
	return false
}

// Whether a field's tag names one of words (an option's name: "log" for log=len).
@(private = "file")
cc_tag_has :: proc(f: ^Cmd_Field, words: ..string) -> bool {
	for opt in strings.split(f.tag, ",", context.temp_allocator) {
		k, _, _ := strings.partition(opt, "=")
		for w in words do if k == w do return true
	}
	return false
}

// The list in tests/command-codec/<file> is the list the code has; a difference is listed.
@(private = "file")
cc_list_check :: proc(t: ^testing.T, file, about: string, got: []string) {
	root := strings.trim_suffix(strings.trim_right(#directory, "/"), "/src/core")
	text := strings.concatenate({strings.join(got, "\n", context.temp_allocator), "\n"}, context.temp_allocator)
	_ = os.write_entire_file(fmt.tprintf("%s/build/%s", root, file), transmute([]u8)text)
	data, err := os.read_entire_file(fmt.tprintf("%s/tests/command-codec/%s", root, file), context.temp_allocator)
	if !testing.expectf(t, err == nil, "tests/command-codec/%s missing (build/%s has the code's)", file, file) do return
	want := make(map[string]bool, context.temp_allocator)
	for l in strings.split_lines(string(data), context.temp_allocator) do if l != "" && !strings.has_prefix(l, "#") do want[l] = true
	have := make(map[string]bool, context.temp_allocator)
	for g in got {
		have[g] = true
		testing.expectf(t, g in want, "%s: %s (decide: a tag, or add it to tests/command-codec/%s)", about, g, file)
	}
	for w in want do testing.expectf(t, w in have, "tests/command-codec/%s lists %s, which no longer needs it", file, w)
}

// Whether a field's codec= is one that redacts (a codec that writes the text as it is decides
// nothing about the log).
@(private = "file")
cc_codec_redacts :: proc(f: ^Cmd_Field) -> bool {
	for c in CMD_CODECS do if c.name == f.codec do return c.redacts
	return false
}

// A field that holds a string and whose tag says nothing of the log (log=, red=, -, ui, or a
// codec= that redacts), and a parsed field whose tag says nothing of its parse (noparse, -, ui), are listed:
// a new one (a password, or a field the core sets) fails here until someone decides.
@(test)
command_codec_decisions :: proc(t: ^testing.T) {
	logged := make([dynamic]string, context.temp_allocator)
	parsed := make([dynamic]string, context.temp_allocator)
	for &info in command_infos {
		type_name := info.ti.variant.(runtime.Type_Info_Named).name
		for &f in info.fields {
			seen := make(map[typeid]bool, context.temp_allocator)
			if cc_holds_string(f.ti, &seen) && !cc_tag_has(&f, "log", "red", "-", "ui") && !cc_codec_redacts(&f) do append(&logged, fmt.tprintf("%s.%s", type_name, f.name))
			if info.parsed && !cc_tag_has(&f, "noparse", "-", "ui") do append(&parsed, fmt.tprintf("%s.%s", type_name, f.name))
		}
	}
	slice.sort(logged[:])
	slice.sort(parsed[:])
	cc_list_check(t, "logged-as-is.txt", "a string logged as it is", logged[:])
	cc_list_check(t, "parsed-from-callers.txt", "a field callers set", parsed[:])
	free_all(context.temp_allocator)
}

// ---- each redaction and clamp does something ----

// A command's log, redacted log and wire for samples a, b and c.
@(private = "file")
cc_written :: proc(i: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for seed in 1 ..= 3 {
		cmd := cg_sample(i, seed)
		fmt.sbprintf(&b, "%s\n%s\n%s\n", command_json(cmd), command_json(cmd, redact = true), command_wire_json(cmd))
	}
	return strings.to_string(b)
}

// What the parser makes of each sample's wire with field f set to numbers past any max.
@(private = "file")
cc_parsed :: proc(i: int, f: ^Cmd_Field) -> string {
	b := strings.builder_make(context.temp_allocator)
	leaks := 0
	for seed in 1 ..= 3 {
		members, ok := json_members_raw(command_wire_json(cg_sample(i, seed)))
		if !ok do continue
		has := false
		for m in members do if m.key == f.key do has = true
		if !has {
			grown := make([dynamic]Json_Member, context.temp_allocator)
			append(&grown, ..members)
			append(&grown, Json_Member{key = f.key, raw = "0"})
			members = grown[:]
		}
		for raw in ([]string{"5000000000", "2199023255552", "9007199254740991"}) {
			fmt.sbprintf(&b, "%s\n", cg_parse(cg_mutate(members, f.key, raw), false, &leaks))
		}
	}
	return strings.to_string(b)
}

// The commands whose log json_write.odin's write_command_hook writes by hand: their log= and
// red= tags say the decision, the hook carries it out.
@(private = "file")
CC_HOOKED := [?]typeid{New_Claude_Session, Browser_Update, Restore_Session}

// Taking out any log=, red= or max= tag changes what some sample writes or parses: each one is
// pinned by the golden (command_golden), not decoration.
@(test)
command_codec_tags_matter :: proc(t: ^testing.T) {
	checked := 0
	for &info, i in command_infos {
		if slice.contains(CC_HOOKED[:], info.id) do continue
		for &f in info.fields {
			if f.log.tx != .None && cc_tag_has(&f, "log") {
				before := cc_written(i)
				saved := f.log
				f.log = {}
				after := cc_written(i)
				f.log = saved
				testing.expectf(t, before != after, "%s.%s: log=%v changes nothing any sample writes", info.name, f.name, f.log.tx)
				checked += 1
			}
			if f.red.tx != .None {
				before := cc_written(i)
				saved := f.red
				f.red = {}
				after := cc_written(i)
				f.red = saved
				testing.expectf(t, before != after, "%s.%s: red=%v changes nothing any sample writes", info.name, f.name, f.red.tx)
				checked += 1
			}
			if _, set := f.max.?; set {
				testing.expectf(t, info.parsed, "%s.%s: max= on a command the parser never reads", info.name, f.name)
				before := cc_parsed(i, &f)
				saved := f.max
				f.max = nil
				after := cc_parsed(i, &f)
				f.max = saved
				testing.expectf(t, before != after, "%s.%s: max= changes nothing the parser reads", info.name, f.name)
				checked += 1
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, checked > 50, "the tags were found")
}

// ---- what the redacted log never holds ----

// Events and the command log (the redacted encoding) hold no user:pass@ of an address and no
// confirmation token; a browser page's title and a path stay (PROTOCOL.md §6).
@(test)
command_redacted_leaks :: proc(t: ^testing.T) {
	CRED :: "https://user:pass@host.example/p?q=1#f"
	PUBLIC :: "https://host.example/p?q=<redacted>" // the query's values and the fragment not kept either
	TOKEN :: "tok-5f0c2e9a"
	red :: proc(cmd: Command) -> string {return command_json(cmd, redact = true)}
	lacks :: proc(t: ^testing.T, js, what: string, loc := #caller_location) {
		testing.expectf(t, !strings.contains(js, what), "%s holds %q", js, what, loc = loc)
	}
	holds :: proc(t: ^testing.T, js, what: string, loc := #caller_location) {
		testing.expectf(t, strings.contains(js, what), "%s lacks %q", js, what, loc = loc)
	}

	js := red(Markdown_Follow{tab_id = 1, url = CRED, confirm = TOKEN})
	lacks(t, js, "user:pass")
	lacks(t, js, TOKEN)
	holds(t, js, `"url":"` + PUBLIC + `"`)
	holds(t, js, `"confirm":"<redacted>"`)
	holds(t, command_json(Markdown_Follow{tab_id = 1, url = CRED, confirm = TOKEN}), TOKEN) // the unredacted log keeps it (a test's)
	holds(t, command_json(Markdown_Follow{tab_id = 1, url = CRED, confirm = TOKEN}), CRED) // and the address whole

	js = red(Browser_Update{tab_id = 1, what = {.Url, .Title, .Blocked}, url = CRED, title = "Inbox (3)", blocked = "user:pass@popup.example/x"})
	lacks(t, js, "user:pass")
	holds(t, js, `"blocked_popup":"popup.example/x"`)
	holds(t, js, `"title":"Inbox (3)"`)

	tabs := []Restore_Tab{{kind = .Browser, title = "Docs", cwd = CRED}, {kind = .Shell, title = "zsh", cwd = "/Users/u/p"}}
	js = red(Restore_Session{project_id = 1, pi_session_id = "s", tabs = tabs})
	lacks(t, js, "user:pass")
	holds(t, js, `"cwd":"` + PUBLIC + `"`)
	holds(t, js, `"cwd":"/Users/u/p"`)
	holds(t, js, `"title":"Docs"`)

	for cmd in ([]Command{Set_Machines_Reachable{on = true, confirm = TOKEN}, Machine_Remove{no = 1, confirm = TOKEN}}) {
		js = red(cmd)
		lacks(t, js, TOKEN)
		holds(t, js, `"confirm":"<redacted>"`)
	}
	free_all(context.temp_allocator)
}

// A command field named confirm (a confirmation token) is a token in the redacted log, and one
// named url (or Browser_Update's blocked popup's) loses its user:pass@: what the tag says (a
// hooked command's hook carries it out, command_redacted_leaks).
@(test)
command_codec_secret_names :: proc(t: ^testing.T) {
	for &info in command_infos {
		for &f in info.fields {
			if f.skip || f.ui do continue
			r := f.red.tx != .None ? f.red.tx : f.log.tx
			switch {
			case f.name == "confirm":
				testing.expectf(t, r == .Token || r == .Drop, "%s.confirm: in the redacted log as %v (red=token)", info.name, r)
			case f.name == "url" || (info.id == Browser_Update && f.name == "blocked"):
				testing.expectf(t, r == .Url || r == .Token || r == .Drop || r == .Bytes, "%s.%s: in the redacted log as %v (red=url)", info.name, f.name, r)
			}
		}
	}
}

// A codec whose CMD_CODECS row says it redacts keeps its field's text out of the redacted log:
// each such field set to a marker, in every sample.
@(test)
command_codec_redacting_codecs :: proc(t: ^testing.T) {
	MARK :: "mark-7d1e"
	checked := 0
	for &info, i in command_infos {
		for &f in info.fields {
			if f.codec == "" || !cc_codec_redacts(&f) do continue
			for seed in 0 ..= 3 {
				cmd := cg_sample(i, seed)
				data := rawptr(uintptr(&cmd) + f.offset)
				switch f.ti.id {
				case string:   (^string)(data)^ = MARK
				case []string: (^[]string)(data)^ = []string{MARK, MARK}
				case:          testing.expectf(t, false, "%s.%s: codec=%s on a %v (the test sets strings and lists of them)", info.name, f.name, f.codec, f.ti.id)
				}
				js := command_json(cmd, redact = true)
				testing.expectf(t, !strings.contains(js, MARK), "%s.%s: codec=%s says it redacts, but %s", info.name, f.name, f.codec, js)
				checked += 1
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expect(t, checked > 0, "the codecs that redact were found")
}
