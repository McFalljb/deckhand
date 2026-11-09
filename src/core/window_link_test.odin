package core

// The window's link (window_link.odin; design §10.2, M3-F): the ui caller's one door, the
// state delta before the result (Q9), window.command's closed list, toasts as messages, the
// divergence check. And the other side: no socket hello, token or request reaches ui or the
// state stream.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import cw "../corewire"

// What the window received, in order (the test plays the window).
@(private = "file")
wl_frames: [dynamic]string
@(private = "file")
wl_end: cw.Mem_End

@(private = "file")
wl_on_frames :: proc() {
	for {
		f, err := cw.mem_recv(wl_end, context.temp_allocator)
		if err != .None do return
		append(&wl_frames, strings.clone(string(f.payload), runtime.heap_allocator()))
	}
}

@(private = "file")
wl_begin :: proc() -> ^State {
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	wl_frames = make([dynamic]string, runtime.heap_allocator())
	wl_end = core_attach_window(wl_on_frames)
	return &state
}

@(private = "file")
wl_end_test :: proc(replica: ^State = nil) {
	core_detach_window()
	for f in wl_frames do delete(f, runtime.heap_allocator())
	delete(wl_frames)
	if replica != nil do replica_free(replica, runtime.heap_allocator())
	inbox_drain()
	state = State{}
}

@(private = "file")
wl_send :: proc(text: string) {
	testing_expect_send(cw.mem_send(wl_end, cw.JSON_CHANNEL, .Data, transmute([]u8)text))
	window_link_pump()
}

@(private = "file")
testing_expect_send :: proc(e: cw.Send_Error) {assert(e == .None)}

@(private = "file")
wl_type :: proc(f: string) -> string {return json_path(f, "type")}

// A queued command and a "now" one: its state.delta, then its result (Q9); the replica that
// applied the delta already holds the change.
@(test)
window_link_delta_before_reply :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	replica: State
	defer wl_end_test(&replica)

	wl_send(window_msg_subscribe())
	if !testing.expect_value(t, len(wl_frames), 1) do return
	testing.expect_value(t, wl_type(wl_frames[0]), STATE_FULL)
	testing.expect_value(t, replica_apply(&replica, wl_frames[0]), "")

	for now in ([]bool{false, true}) {
		clear(&wl_frames)
		by := now ? Sort_By.Name : Sort_By.Created
		wl_send(window_msg_command(Set_Sort{section = .Projects, by = by}, "c1", now = now))
		if !now do inbox_drain()
		if !testing.expectf(t, len(wl_frames) >= 2, "now=%v: %v", now, wl_frames[:]) do continue
		testing.expect_value(t, wl_type(wl_frames[0]), STATE_DELTA)
		last := wl_frames[len(wl_frames) - 1]
		testing.expect_value(t, wl_type(last), "result")
		testing.expect_value(t, json_path(last, "id"), "c1")
		testing.expect_value(t, json_path(last, "result.ok"), "true")
		for f in wl_frames[:len(wl_frames) - 1] do testing.expect_value(t, replica_apply(&replica, f), "")
		testing.expect_value(t, replica.sidebar.sort[.Projects], by)
		testing.expect_value(t, window_link_diverged(&replica), "")
	}
	// a command with no id: no result, its delta at the drain's end
	clear(&wl_frames)
	wl_send(window_msg_command(Set_Sort{section = .Projects, by = .Recent}, ""))
	testing.expect_value(t, len(wl_frames), 0)
	inbox_drain()
	testing.expect_value(t, len(wl_frames), 1)
	if len(wl_frames) == 1 do testing.expect_value(t, wl_type(wl_frames[0]), STATE_DELTA)
	// nothing changed: no delta
	clear(&wl_frames)
	window_link_flush()
	testing.expect_value(t, len(wl_frames), 0)
}

// The window's commands run as ui: a user-only one works through the link, and the same
// command from a control token does not.
@(test)
window_link_runs_as_ui :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	defer wl_end_test()
	cmd := Set_Confirm_Policy{caller = .Script, class = .Delete, mode = .Auto}
	r := run_command(cmd, {kind = .Control})
	testing.expect(t, !r.ok, "a control caller may not")
	wl_send(window_msg_command(cmd, "u", now = true))
	last := wl_frames[len(wl_frames) - 1]
	testing.expect_value(t, json_path(last, "result.ok"), "true")
	testing.expect_value(t, state.settings.confirm[.Script][.Delete], Confirm_Mode.Auto)
	// a UI-only field arrives (parse_command_ui): Set_Home_Dir.setup would finish the setup
	// sheet; here only its parse is checked, through the link's own path
	m, err := parse_command_ui(command_wire_json(Set_Home_Dir{path = "/x", setup = true}))
	testing.expect(t, err == "" && m.(Set_Home_Dir).setup)
	command_free(m, context.allocator)
}

// window.command: the closed list runs as internal; anything else is refused.
@(test)
window_link_window_commands :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	defer wl_end_test()
	text, ok := window_msg_internal(Focus_Take{widget = "job_sheet"}, "f", now = true)
	testing.expect(t, ok)
	wl_send(text)
	testing.expect_value(t, state.focus_widget, "job_sheet")
	text, ok = window_msg_internal(Focus_Release{widget = "job_sheet"}, "")
	wl_send(text)
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "")
	// not on the list: not encoded, and not decoded when hand-made
	_, ok = window_msg_internal(Quit{}, "q")
	testing.expect(t, !ok, "quit is not a window command")
	clear(&wl_frames)
	wl_send(`{"v":1,"type":"window.command","id":"q","now":true,"command":{"quit":{}}}`)
	testing.expect(t, len(wl_frames) == 1 && json_path(wl_frames[0], "result.ok") == "false", "refused")
	wl_send(`{"v":1,"type":"window.command","id":"q","now":true,"command":{"set_confirm_policy":{"caller":"script","class":"delete","mode":"auto"}}}`)
	testing.expect_value(t, state.settings.confirm[.Script][.Delete], Confirm_Mode.Ask)
	// every listed command survives its encoding
	for id in WINDOW_COMMANDS {
		cmd: Command
		f := Sw_Fill{n = 3, a = context.temp_allocator}
		u := runtime.type_info_base(type_info_of(Command)).variant.(runtime.Type_Info_Union)
		for v, i in u.variants do if v.id == id do sw_fill_variant(&cmd, type_info_of(Command), i, &f)
		msg, mok := window_msg_internal(cmd, "x")
		if !testing.expectf(t, mok, "%v", id) do continue
		back, err := window_command_decode_for_test(msg)
		if !testing.expectf(t, err == "", "%v: %s", id, err) do continue
		out := make([dynamic][2]string, context.temp_allocator)
		sw_diff(&cmd, &back, type_info_of(Command), "", "", &out)
		testing.expectf(t, len(out) == 0, "%v: %v", id, out[:])
	}
}

// A toast is a message to an attached window.
@(test)
window_link_toast_message :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	defer wl_end_test()
	window_toast("Path copied")
	if !testing.expect_value(t, len(wl_frames), 1) do return
	m, err := window_msg_parse(wl_frames[0])
	testing.expect_value(t, err, "")
	testing.expect_value(t, m.kind, Window_Msg_Kind.Toast)
	testing.expect_value(t, m.text, "Path copied")
}

// A write to the replica that no command made is a divergence; a resync ends it.
@(test)
window_link_divergence :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	replica: State
	defer wl_end_test(&replica)
	wl_send(window_msg_subscribe())
	testing.expect_value(t, replica_apply(&replica, wl_frames[0]), "")
	testing.expect_value(t, window_link_diverged(&replica), "")
	replica.layout.left_open = !replica.layout.left_open // the window wrote State itself
	d := window_link_diverged(&replica)
	testing.expectf(t, strings.contains(d, "view"), "%q", d)
	// and a core change with no version bump and no window_state_changed: also caught
	replica.layout.left_open = state.layout.left_open
	state.selected_project = 7
	window_link_flush()
	testing.expect(t, strings.contains(window_link_diverged(&replica), "projects"))
	clear(&wl_frames)
	window_link_resync()
	for f in wl_frames do testing.expect_value(t, replica_apply(&replica, f), "")
	testing.expect_value(t, window_link_diverged(&replica), "")
}

// No socket hello, token or request yields ui or the state stream: tokens are never made for
// ui or internal, a hello's caller is the token's, and state.subscribe is not a request.
@(test)
window_link_socket_never_ui :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fmt.tprintf("%s/wl-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	saved := strings.clone(os.get_env("DECKHAND_RUNTIME_DIR", context.temp_allocator), context.temp_allocator)
	os.set_env("DECKHAND_RUNTIME_DIR", dir)
	defer {
		if saved != "" do os.set_env("DECKHAND_RUNTIME_DIR", saved)
		else do os.unset_env("DECKHAND_RUNTIME_DIR")
		os.remove_all(dir)
	}
	rdir, rok := sock_runtime_dir(context.temp_allocator)
	if !testing.expect(t, rok && socket_start(rdir), "socket_start") do return
	defer socket_stop(proc() {inbox_drain()})

	line :: proc(fd: Sock_Fd, text: string) -> string {
		sock_write_all(fd, transmute([]u8)strings.concatenate({text, "\n"}, context.temp_allocator))
		buf := make([dynamic]u8, context.temp_allocator)
		start := time.tick_now()
		for time.tick_since(start) < 3 * time.Second {
			if i := strings.index_byte(string(buf[:]), '\n'); i >= 0 do return string(buf[:i])
			inbox_drain()
			if sock_wait_readable(fd, 5) {
				chunk: [4096]u8
				n := sock_read(fd, chunk[:])
				if n <= 0 do break
				append(&buf, ..chunk[:n])
			}
		}
		return string(buf[:])
	}
	hello :: proc(tok: string) -> (Sock_Fd, string) {
		fd, ok := sock_connect(socket_path())
		if !ok do return fd, ""
		return fd, line(fd, fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"}}`, tok))
	}
	for kind in Caller_Kind {
		tok := socket_mint_token({kind = kind, tab_id = kind == .Panel || kind == .App ? 5 : 0}, context.temp_allocator)
		fd, r := hello(tok)
		defer sock_close(fd)
		caller := json_path(r, "result.data.caller")
		testing.expectf(t, caller != "ui" && caller != "internal", "%v: hello says %q", kind, r)
		if kind == .UI || kind == .Internal {
			testing.expectf(t, json_path(r, "result.error") == "unknown token", "%v: %q", kind, r)
			continue
		}
		if kind == .App do continue // an app's connection answers tab.* only
		// the state stream is not a socket request, whatever the caller
		s := line(fd, `{"id":"s","v":1,"type":"state.subscribe"}`)
		testing.expectf(t, json_path(s, "result.error") == "unknown request type", "%v: %q", kind, s)
		// and the UI-only fields are not read from a socket's command
		c := line(fd, `{"id":"c","v":1,"type":"command","command":{"type":"set_home_dir","path":"","setup":true}}`)
		testing.expectf(t, json_path(c, "id") == "c", "%v: %q", kind, c)
	}
	testing.expect(t, !state.settings.setup_seen, "setup never finished from a socket")
	// the attach itself is called by the window only: no core file but its own calls it
	files, err := os.read_all_directory_by_path(#directory, context.temp_allocator)
	testing.expect(t, err == nil)
	for f in files {
		if !strings.has_suffix(f.name, ".odin") || strings.has_suffix(f.name, "_test.odin") || f.name == "window_link.odin" do continue
		data, _ := os.read_entire_file(f.fullpath, context.temp_allocator)
		testing.expectf(t, !strings.contains(string(data), "core_attach_window("), "%s calls core_attach_window", f.name)
	}
}
