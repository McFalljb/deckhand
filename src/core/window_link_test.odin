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
wl_replica: ^State // set: frames are applied to it as they arrive, as the window's client does

@(private = "file")
wl_on_frames :: proc() {
	for {
		f, err := cw.mem_recv(wl_end, context.temp_allocator)
		if err != .None do return
		append(&wl_frames, strings.clone(string(f.payload), runtime.heap_allocator()))
		if wl_replica != nil && json_path(string(f.payload), "type") != "result" && json_path(string(f.payload), "type") != "toast" {
			assert(replica_apply(wl_replica, string(f.payload), runtime.heap_allocator()) == "")
		}
	}
}

@(private = "file")
wl_begin :: proc() -> ^State {
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	wl_frames = make([dynamic]string, runtime.heap_allocator())
	ok: bool
	wl_end, ok = core_attach_window(wl_on_frames)
	assert(ok)
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

// The test-mode check (window_link_check, what autotest runs): a core write with no version bump
// and no window_state_changed fails it, whether a sweep copied it already or not; so does a
// write by the window into its replica; a resync ends it.
@(test)
window_link_divergence :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	replica: State
	wl_replica = &replica
	defer {
		wl_replica = nil
		wl_end_test(&replica)
	}
	wl_send(window_msg_subscribe())
	testing.expect_value(t, window_link_check(&replica), "")
	// a core write that signalled nothing, caught before any sweep
	clear(&wl_frames)
	state.selected_project = 7
	d := window_link_check(&replica)
	testing.expectf(t, strings.contains(d, "projects.selected_project"), "%q", d)
	testing.expect_value(t, window_link_check(&replica), "")
	// ... and after a sweep (the window's frames) copied it in first
	clear(&wl_frames)
	state.selected_project = 8
	window_link_flush(sweep = true)
	d = window_link_check(&replica)
	testing.expectf(t, strings.contains(d, "projects.selected_project"), "%q", d)
	// a tracked write passes
	clear(&wl_frames)
	state.selected_project = 9
	state.version += 1
	testing.expect_value(t, window_link_check(&replica), "")
	// the window wrote State itself
	clear(&wl_frames)
	replica.layout.left_open = !replica.layout.left_open
	d = window_link_check(&replica)
	testing.expectf(t, strings.contains(d, "bypassed commands") && strings.contains(d, "view"), "%q", d)
	testing.expect_value(t, window_link_check(&replica), "")
}

// A state message the link refuses leaves the replica behind: the next flush sends state.full,
// never a delta against what never arrived. One over the frame limit is said once and not sent
// again until State shrinks (no loop).
@(test)
window_link_refused_send :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	replica: State
	saved := link_max_payload
	defer {
		link_max_payload = saved
		wl_end_test(&replica)
	}
	wl_send(window_msg_subscribe())
	for f in wl_frames do testing.expect_value(t, replica_apply(&replica, f), "")
	// too large: nothing sent, and nothing again on the next flushes
	clear(&wl_frames)
	link_max_payload = 10
	state.selected_project = 3
	state.version += 1
	window_link_flush()
	window_link_flush(sweep = true) // the full, too large as well
	builds := window_link_for_test().full_builds
	for _ in 0 ..< 100 do window_link_flush(sweep = true)
	testing.expect_value(t, len(wl_frames), 0)
	// round 2, finding 2: not built again on every flush while State is unchanged
	testing.expect_value(t, window_link_for_test().full_builds, builds)
	testing.expect(t, len(window_link_for_test().untracked) <= 64, "test mode's notes are capped")
	// it fits again (State changed): the whole state, not a delta
	link_max_payload = saved
	window_state_changed()
	window_link_flush()
	if testing.expect_value(t, len(wl_frames), 1) do testing.expect_value(t, json_path(wl_frames[0], "type"), STATE_FULL)
	for f in wl_frames do testing.expect_value(t, replica_apply(&replica, f), "")
	testing.expect_value(t, replica.selected_project, 3)
	// the link itself refuses (closed): a full again once it can
	clear(&wl_frames)
	state.selected_project = 4
	state.version += 1
	l := window_link_for_test()
	cw.mem_close(l.core_end)
	window_link_flush()
	testing.expect(t, l.need_full, "a refused delta asks for a full")
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
		testing.expectf(t, caller != "ui" && caller != "internal" && caller != "tab_host", "%v: hello says %q", kind, r)
		if kind == .UI || kind == .Internal || kind == .Tab_Host { // the window's link only

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
}

// Review round 1, finding 7: the one door, by name, across the whole tree (every package, any
// call form: `f := core_attach_window`, `core_attach_window (`, `core.core_attach_window(`).
// Only the window's client attaches; only the link parses as ui; the socket names nothing of
// the link's. Comments do not count.
@(test)
window_link_one_door_everywhere :: proc(t: ^testing.T) {
	root := strings.concatenate({#directory, "/../.."}, context.temp_allocator)
	allowed := make(map[string][]string, context.temp_allocator)
	allowed["core_attach_window"] = {"src/core/window_link.odin", "src/client.odin"}
	allowed["parse_command_ui"] = {"src/core/window_link.odin", "src/core/json_read.odin"}
	allowed["link_message"] = {"src/core/window_link.odin"}
	allowed["Window_Link"] = {"src/core/window_link.odin"}
	hits := wl_scan_tree(root, "", {"src", "tools", "tests"}, allowed)
	for h in hits do testing.expectf(t, false, "%s", h)
	// socket.odin: no window_link name at all (its comments aside)
	data, err := os.read_entire_file(strings.concatenate({root, "/src/core/socket.odin"}, context.temp_allocator), context.temp_allocator)
	if testing.expect(t, err == nil) {
		code := wl_code_only(string(data))
		for name in ([]string{"window_link", "core_attach_window", "parse_command_ui", "link_send", "link_message", "link."}) {
			testing.expectf(t, !strings.contains(code, name), "socket.odin names %q", name)
		}
	}
}

// The code of an Odin file without its // comments and string literals' contents left as they are.
@(private = "file")
wl_code_only :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for line in strings.split_lines(text, context.temp_allocator) {
		l := line
		in_str := false
		for i := 0; i < len(l); i += 1 {
			if l[i] == '"' && (i == 0 || l[i - 1] != '\\') do in_str = !in_str
			if !in_str && i + 1 < len(l) && l[i] == '/' && l[i + 1] == '/' {
				l = l[:i]
				break
			}
		}
		strings.write_string(&b, l)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Every non-test .odin file under root's dirs naming one of allowed's keys outside its list.
@(private = "file")
wl_scan_tree :: proc(root, rel: string, dirs: []string, allowed: map[string][]string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	walk :: proc(root, rel: string, allowed: map[string][]string, out: ^[dynamic]string) {
		full := rel == "" ? root : strings.concatenate({root, "/", rel}, context.temp_allocator)
		files, err := os.read_all_directory_by_path(full, context.temp_allocator)
		if err != nil do return
		for f in files {
			r := rel == "" ? f.name : strings.concatenate({rel, "/", f.name}, context.temp_allocator)
			if f.type == .Directory {
				if f.name == "build" || strings.has_prefix(f.name, ".") || f.name == "vendor" do continue
				walk(root, r, allowed, out)
				continue
			}
			if !strings.has_suffix(f.name, ".odin") || strings.has_suffix(f.name, "_test.odin") do continue
			data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator)
			if rerr != nil do continue
			code := wl_code_only(string(data))
			for name, ok_files in allowed {
				if !wl_names(code, name) do continue
				fine := false
				for o in ok_files do if o == r do fine = true
				if !fine do append(out, fmt.tprintf("%s names %s (only %v may)", r, name, ok_files))
			}
		}
	}
	for d in dirs do walk(root, d, allowed, &out)
	return out
}

// Whether code has name as a whole identifier.
@(private = "file")
wl_names :: proc(code, name: string) -> bool {
	ident :: proc(c: u8) -> bool {return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')}
	rest := code
	at := 0
	for {
		i := strings.index(rest, name)
		if i < 0 do return false
		j := at + i
		before := j == 0 || !ident(code[j - 1])
		after := j + len(name) >= len(code) || !ident(code[j + len(name)])
		if before && after do return true
		at = j + 1
		rest = code[at:]
	}
}

// Finding 7: one window at a time, at run time (an assert is gone in a release build): a
// second attach is refused and the first link goes on.
@(test)
window_link_second_attach_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	defer wl_end_test()
	_, ok := core_attach_window(proc() {})
	testing.expect(t, !ok, "a second window is refused")
	wl_send(window_msg_subscribe())
	testing.expect_value(t, len(wl_frames), 1)
}

// Finding 11: a window that goes while its queued command waits in the inbox: the reply the
// inbox holds stays alive until it is answered, then goes.
@(test)
window_link_detach_with_queued_reply :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	wl_send(window_msg_subscribe())
	wl_send(window_msg_command(Set_Sort{section = .Projects, by = .Name}, "q1"))
	testing.expect_value(t, window_link_orphans_for_test(), 0)
	core_detach_window() // the command is still queued
	testing.expect_value(t, window_link_orphans_for_test(), 1)
	inbox_drain() // answered into the orphan, which goes at the next pump
	window_link_pump()
	testing.expect_value(t, window_link_orphans_for_test(), 0)
	testing.expect_value(t, state.sidebar.sort[.Projects], Sort_By.Name)
	for f in wl_frames do delete(f, runtime.heap_allocator())
	delete(wl_frames)
	state = State{}
}

// A command that changes State without a version bump (one that parks or consumes a
// confirmation answers "not changed") still has its change in the replica when its result
// arrives: the flush before a result compares every section. after_command_check plays the
// untracked write, inside the command.
@(test)
window_link_untracked_change_before_reply :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	wl_begin()
	replica: State
	defer {
		after_command_check = nil
		wl_end_test(&replica)
	}
	wl_send(window_msg_subscribe())
	testing.expect_value(t, replica_apply(&replica, wl_frames[0]), "")
	for now, i in ([]bool{true, false}) {
		@(static) mark: u64
		mark = u64(40 + i)
		after_command_check = proc(cmd: Command) {state.selected_project = mark}
		clear(&wl_frames)
		before := state.version
		wl_send(window_msg_command(Get_State{}, "g", now = now)) // a query: changes nothing itself
		if !now do inbox_drain()
		testing.expect_value(t, state.version, before) // no bump: the case
		last := wl_frames[len(wl_frames) - 1]
		testing.expect_value(t, json_path(last, "type"), "result")
		for f in wl_frames[:len(wl_frames) - 1] do testing.expect_value(t, replica_apply(&replica, f), "")
		testing.expectf(t, replica.selected_project == mark, "now=%v: the replica has %d", now, replica.selected_project)
	}
}
