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

// A field that holds a string and whose tag says nothing of the log (log=, red=, -, codec=,
// ui), and a parsed field whose tag says nothing of its parse (noparse, -, ui), are listed:
// a new one (a password, or a field the core sets) fails here until someone decides.
@(test)
command_codec_decisions :: proc(t: ^testing.T) {
	logged := make([dynamic]string, context.temp_allocator)
	parsed := make([dynamic]string, context.temp_allocator)
	for &info in command_infos {
		type_name := info.ti.variant.(runtime.Type_Info_Named).name
		for &f in info.fields {
			seen := make(map[typeid]bool, context.temp_allocator)
			if cc_holds_string(f.ti, &seen) && !cc_tag_has(&f, "log", "red", "-", "codec", "ui") do append(&logged, fmt.tprintf("%s.%s", type_name, f.name))
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
