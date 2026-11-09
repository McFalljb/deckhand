package core

// The window's commands over the wire (design §10.2, M3-E; used from M3-F, where the window's
// commands are encoded, sent, parsed by the core's socket code and run as `ui`): every command
// the ui caller may send, with every field set, survives command_json -> parse_command, and
// the parsed command is still one the ui caller may send. Pure: the global `state` is not used.

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:testing"
import "core:time"

// command_json is the log's and events' encoding (write_command): it redacts, and writes
// counts for lists. The window's commands need one that is not. These are the fields of ui
// commands it does not carry today, or that the parser does not take: over the wire they
// would arrive as their zero value. M3-F must close each (a wire mode for write_command; ui-only
// fields parsed only for the in-process ui connection) before the window's commands go over
// the wire. Until then this list says exactly where they are, and the test fails on a new one
// (and on an entry that no longer applies).
@(private = "file")
NOT_ON_WIRE := [?]struct {
	field, note: string,
} {
	// ui-only fields: parse_command never reads them (an agent must not set them)
	{"Close_Session.ask", "UI only: the pi tab's × and ⌘W always confirm"},
	{"Focus_Session.reopen", "UI only: the user opened it, so its pi starts again if it exited"},
	{"Set_Home_Dir.setup", "UI only: the setup sheet's Done"},
	// write_command leaves them out or redacts them
	{"New_Claude_Tab.args", "written as argc only (the user's Claude flags)"},
	{"New_Claude_Session.args", "written as argc only"},
	{"Claude_Rename.title", `written as "<redacted N bytes>"`},
	{"Pi_Reload_All.confirm", "confirmation tokens never written (reload_write)"},
	{"Pi_Restart_Updated.confirm", "confirmation tokens never written (reload_write)"},
	{"Claude_Restart_Changed.confirm", "confirmation tokens never written (claude_reload_write)"},
	{"App_Call.timeout_ms", "not written"},
	{"App_Events.limit", "not written"},
	{"Browser_Console.limit", "not written"},
	{"Browser_Network.limit", "not written"},
	// the parser narrows them
	{"Set_Job_Limits.max_cost", "parsed as f32 (opt_f32), written as f64"},
	{"Set_Job_Limits.day", "parsed as f32"},
	{"Set_Job_Limits.week", "parsed as f32"},
	{"Set_Job_Limits.month", "parsed as f32"},
}

// ui commands whose command_json does not parse back at all (same reason, same owner: M3-F).
@(private = "file")
NOT_PARSEABLE := [?]struct {
	type, note: string,
} {
	{"app_input", "events written as a count; the parser wants the list of objects"},
	{"browser_click", "modifiers written as CDP's bits (a number); the parser wants a list of names"},
}

@(test)
command_wire_ui_round_trip :: proc(t: ^testing.T) {
	start := time.tick_now()
	u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
	ui := Caller{kind = .UI}
	checked := 0
	used := make([]bool, len(NOT_ON_WIRE), context.temp_allocator)
	used_parse := make([]bool, len(NOT_PARSEABLE), context.temp_allocator)
	for vt, i in u.variants {
		probe: Command
		reflect.set_union_variant_typeid(any{&probe, typeid_of(Command)}, vt.id)
		type := command_type(probe)
		spec := command_spec(type)
		if !testing.expectf(t, spec != nil, "%v: no row in the command table", vt.id) do continue
		if !who_allows(.UI, spec.who) do continue
		// a few fills, so unions and enums inside commands take different values
		for round in 0 ..< 3 {
			f := Sw_Fill{n = round * 7, a = context.temp_allocator}
			cmd: Command
			sw_fill_variant(&cmd, type_info_of(Command), i, &f)
			// fields whose text must itself be JSON
			#partial switch &c in cmd {
			case App_Call:
				c.params = `{"k":[1,"two"]}`
			case App_Input:
				c.events = []string{`{"kind":"key","key":"a"}`, `{"kind":"mouse","x":1}`}
			}
			text := command_json(cmd)
			back, err := parse_command(text, context.temp_allocator)
			if err != "" {
				known := false
				for n, k in NOT_PARSEABLE do if n.type == type {known = true; used_parse[k] = true}
				testing.expectf(t, known, "%s: %s does not parse: %s", type, text, err)
				break
			}
			out := make([dynamic][2]string, context.temp_allocator)
			sw_diff(&cmd, &back, type_info_of(Command), type, type, &out)
			if len(out) == 0 do testing.expectf(t, command_json(back) == text, "%s: re-encoded differs: %s -> %s", type, text, command_json(back))
			for d in out {
				known := false
				for n, k in NOT_ON_WIRE do if n.field == d[0] {known = true; used[k] = true}
				testing.expectf(t, known, "%s: not carried by command_json: %s (%s)", type, d[1], text)
			}
			testing.expectf(t, who_allows(.UI, command_spec(command_type(back)).who), "%s: parsed into a command ui may not send", type)
		}
		checked += 1
	}
	for n, k in NOT_ON_WIRE do testing.expectf(t, used[k], "NOT_ON_WIRE lists %s, which now round-trips (or is gone): drop it", n.field)
	for n, k in NOT_PARSEABLE do testing.expectf(t, used_parse[k], "NOT_PARSEABLE lists %s, which now parses (or is gone): drop it", n.type)
	testing.expectf(t, checked > 100, "%d ui commands checked", checked)
	elapsed := time.tick_since(start)
	testing.expectf(t, elapsed < time.Second, "took %v (budget 1 s)", elapsed)
	fmt.printf("command_wire_ui_round_trip: %d ui commands in %v\n", checked, elapsed)
}
