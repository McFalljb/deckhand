package core

// The window's commands over the wire (design §10.2, M3-E and M3-F: the window's commands are
// encoded, sent, parsed by the core's socket code and run as `ui`): every command the ui caller
// may send, with every field set, survives command_wire_json -> parse_command_ui, and the parsed
// command is still one the ui caller may send. Pure: the global `state` is not used.
//
// command_json is the log's and the events' encoding (it redacts, writes counts for lists and
// leaves out limits); command_wire_json writes everything. The UI-only fields are read only by
// parse_command_ui (the window's in-process attach, window_link.odin): the same text through
// parse_command (a socket's, a script's) leaves exactly those at their zero value.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:time"

// The fields only the window may set. parse_command (every socket, script and test-mode line)
// never reads them; parse_command_ui does.
@(private = "file")
UI_ONLY := [?]string{"Close_Session.ask", "Focus_Session.reopen", "Set_Home_Dir.setup"}

@(private = "file")
ui_command_fill :: proc(i, round: int) -> Command {
	f := Sw_Fill{n = round * 7, a = context.temp_allocator}
	cmd: Command
	sw_fill_variant(&cmd, type_info_of(Command), i, &f)
	// fields whose text must itself be JSON
	#partial switch &c in cmd {
	case App_Call:
		c.params = `{"k":[1,"two"]}`
	case App_Input:
		// one key each: the parser re-marshals each event, and a JSON object's keys have no order
		ev := make([]string, 2, context.temp_allocator) // not a literal: it outlives this frame
		ev[0], ev[1] = `{"kind":"key"}`, `{"x":1}`
		c.events = ev
	case Browser_Click:
		c.modifiers &= 1 << len(ACT_MOD_NAMES) - 1 // only the bits that have a name
	}
	return cmd
}

@(test)
command_wire_ui_round_trip :: proc(t: ^testing.T) {
	start := time.tick_now()
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	checked := 0
	for vt, i in u.variants {
		probe: Command
		reflect.set_union_variant_typeid(any{&probe, typeid_of(Command)}, vt.id)
		type := command_type(probe)
		spec := command_spec(type)
		if !testing.expectf(t, spec != nil, "%v: no row in the command table", vt.id) do continue
		if !who_allows(.UI, spec.who) do continue
		// a few fills, so unions and enums inside commands take different values
		for round in 0 ..< 3 {
			cmd := ui_command_fill(i, round)
			text := command_wire_json(cmd)
			back, err := parse_command_ui(text, context.temp_allocator)
			if !testing.expectf(t, err == "", "%s: %s does not parse: %s", type, text, err) do break
			out := make([dynamic][2]string, context.temp_allocator)
			sw_diff(&cmd, &back, type_info_of(Command), type, type, &out)
			for d in out do testing.expectf(t, false, "%s: not carried by command_wire_json: %s (%s)", type, d[1], text)
			if len(out) == 0 do testing.expectf(t, command_wire_json(back) == text, "%s: re-encoded differs: %s -> %s", type, text, command_wire_json(back))
			testing.expectf(t, who_allows(.UI, command_spec(command_type(back)).who), "%s: parsed into a command ui may not send", type)
		}
		checked += 1
	}
	testing.expectf(t, checked > 100, "%d ui commands checked", checked)
	elapsed := time.tick_since(start)
	testing.expectf(t, elapsed < time.Second, "took %v (budget 1 s)", elapsed)
	fmt.printf("command_wire_ui_round_trip: %d ui commands in %v\n", checked, elapsed)
}

// The same wire text from anyone but the window: everything comes through except the UI-only
// fields, which stay zero (an agent cannot make a close always ask, restart a dead pi by opening
// its session, or finish the setup sheet).
@(test)
command_wire_ui_only_fields_stay_ui :: proc(t: ^testing.T) {
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	seen := make(map[string]bool, context.temp_allocator)
	for vt, i in u.variants {
		probe: Command
		reflect.set_union_variant_typeid(any{&probe, typeid_of(Command)}, vt.id)
		type := command_type(probe)
		spec := command_spec(type)
		if spec == nil || !who_allows(.UI, spec.who) do continue
		cmd := ui_command_fill(i, 1)
		text := command_wire_json(cmd)
		back, err := parse_command(text, context.temp_allocator)
		if !testing.expectf(t, err == "", "%s: the socket's parse refuses the window's text: %s", type, err) do continue
		out := make([dynamic][2]string, context.temp_allocator)
		sw_diff(&cmd, &back, type_info_of(Command), type, type, &out)
		for d in out {
			ui_only := false
			for f in UI_ONLY do if d[0] == f do ui_only = true
			testing.expectf(t, ui_only, "%s: %s (%s) differs through the socket's parse, and it is not UI-only", type, d[0], d[1])
			seen[d[0]] = true
		}
	}
	for f in UI_ONLY do testing.expectf(t, seen[f], "%s: the socket's parse read it (it must stay UI-only)", f)
	// and by hand, each set
	for text in ([]string{
		`{"type":"close_session","session":3,"ask":true}`,
		`{"type":"focus_session","session":3,"reopen":true}`,
		`{"type":"set_home_dir","path":"/tmp/x","setup":true}`,
	}) {
		a, aerr := parse_command(text, context.temp_allocator)
		w, werr := parse_command_ui(text, context.temp_allocator)
		testing.expect(t, aerr == "" && werr == "")
		#partial switch c in a {
		case Close_Session: testing.expect(t, !c.ask && w.(Close_Session).ask)
		case Focus_Session: testing.expect(t, !c.reopen && w.(Focus_Session).reopen)
		case Set_Home_Dir:  testing.expect(t, !c.setup && w.(Set_Home_Dir).setup)
		case: testing.expectf(t, false, "%s: parsed as %v", text, a)
		}
	}
}

// The UI-only parse has one door: the window's attach (window_link.odin). A socket, the test
// mode's script and ctl all use parse_command / parse_request, which never set Rd.ui.
@(test)
command_wire_ui_parse_one_door :: proc(t: ^testing.T) {
	dir := #directory
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	callers := make([dynamic]string, context.temp_allocator)
	for f in files {
		if !strings.has_suffix(f.name, ".odin") || strings.has_suffix(f.name, "_test.odin") do continue
		data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator)
		if rerr != nil do continue
		text := string(data)
		for {
			i := strings.index(text, "parse_command_ui(")
			if i < 0 do break
			append(&callers, f.name)
			text = text[i + 1:]
		}
	}
	// json_read.odin declares it (and parse_command_as is file-private); window_link.odin calls it
	ok := true
	for c in callers do if c != "json_read.odin" && c != "window_link.odin" do ok = false
	testing.expectf(t, ok, "parse_command_ui is called from %v: only window_link.odin may", callers[:])
}
