package core

// Continue this conversation on <machine> (pi_handoff.odin, #115). This Mac's side: only the
// user's at this window, only to the row's machine and project as drawn, only to a core that says
// it takes one, at most PI_HANDOFF_MAX, one at a time, in parts that each wait for an answer. The
// other machine's: only a hub's on behalf of its user; the bytes untrusted (one copy at a time, in
// order, each part and the whole capped, a file of its own naming in its own folder, the header
// checked before pi starts, dropped on any failure or when it stops coming); a deterministic new id;
// pi started as `pi --fork <copy> --session-id <id>` (a fake pi), the copy gone once pi wrote its
// file or the tab exited. No ssh, no second process: the link is machines.odin's test hook.
// Shared global State, one thread (tests/unit.py).

import "base:runtime"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import cw "../corewire"

when TEST_HOOKS {

@(private = "file")
PH_RUN :: "0123456789abcdef"
@(private = "file")
PH_HUB :: Caller{kind = .UI, hub = true}

@(private = "file")
ph_finished: [dynamic]Result

@(private = "file")
Ph :: struct {
	root:   string, // heap: a temp folder (the data dir, the projects, pi's store)
	local:  u64, // this Mac's project "api"
	remote: u64, // machine 3's project "api" (packed)
	store:  string, // heap: this Mac's project's pi store
	file:   string, // heap: its session's transcript
}

@(private = "file")
ph_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/dh-ph-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	return strings.clone(real_path(d))
}

@(private = "file")
ph_header :: proc(id, cwd: string) -> string {
	return fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", id, cwd)
}

// This Mac with project api (one pi session, its transcript `body` after the header), machine 3
// ("nuc", online, run PH_RUN, pi_handoff as given) with a project api, its link up.
@(private = "file")
ph_begin :: proc(tag: string, body := "", handoff := true) -> Ph {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{}
	persist = {}
	pi_handoff_reset_for_test()
	f: Ph
	f.root = ph_dir(tag)
	home_root = f.root
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/pi-agent", f.root))
	cwd := fmt.aprintf("%s/work/api", f.root)
	os.make_directory_all(cwd)
	f.store = fmt.aprintf("%s/pi-agent/sessions/--work-api--", f.root) // in pi's store (the sender checks its real path)
	os.make_directory_all(f.store)
	f.local = new_id()
	append(&state.projects, Project{id = f.local, cwd = cwd, dir = f.store, group = .Projects, label = "api"})
	f.file = fmt.aprintf("%s/2026-11-01T10-00-00-000Z_src-1.jsonl", f.store)
	_ = os.write_entire_file(f.file, transmute([]u8)strings.concatenate({ph_header("src-1", cwd), body}, context.temp_allocator))
	f.remote, _ = id_pack(3, 21)
	append(&state.projects, Project{id = f.remote, machine = 3, cwd = "/home/me/api", group = .Projects, label = "api"})
	state.machines = make([]Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online, core_run = PH_RUN, pi_handoff = handoff}
	state.settings.remote_machines = true
	machine_test_links.on = true
	machine_test_links.up = make(map[u64]bool)
	machine_test_links.up[3] = true
	ph_finished = make([dynamic]Result)
	window.test_event = proc(ev: Event) {
		if f, ok := ev.(Finished_Event); ok do append(&ph_finished, result_clone(f.result, runtime.heap_allocator()))
	}
	return f
}

@(private = "file")
ph_end :: proc(f: Ph) {
	core_detach_window()
	machine_route_down(3, gone = true)
	pi_handoff_reset_for_test()
	window.test_event = nil
	machine_test_links.on = false
	for x in machine_test_links.texts do delete(x)
	clear(&machine_test_links.texts)
	delete(machine_test_links.up)
	for r in ph_finished do result_free(r)
	delete(ph_finished)
	for _, t in terms {
		term_free(t) // its fake pi ends with it
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{}
	home_root = ""
	os.unset_env("PI_CODING_AGENT_DIR")
	os.remove_all(f.root)
}

// B's side: a hub link attached (a window link marked hub), as one machine viewing this one.
@(private = "file")
ph_end_win: cw.Mem_End
@(private = "file")
ph_hub_attach :: proc() {
	ok: bool
	ph_end_win, ok = core_attach_window(proc() {
		for {
			_, err := cw.mem_recv(ph_end_win, context.temp_allocator)
			if err != .None do return
		}
	})
	assert(ok)
	window_link_for_test().hub = true
}

@(private = "file")
ph_cmd :: proc(f: Ph, run := PH_RUN, folder := "/home/me/api") -> Pi_Handoff {
	return {project_id = f.local, pi_session_id = "src-1", to_project_id = f.remote, run = run, folder = folder}
}

@(private = "file")
ph_last :: proc() -> string {
	n := len(machine_test_links.texts)
	return n > 0 ? machine_test_links.texts[n - 1] : ""
}

// Machine 3 answers the last part sent.
@(private = "file")
ph_answer :: proc(ok := true, created: u64 = 0, error := "") {
	id := json_path(ph_last(), "id")
	if ok do machine_route_reply(3, fmt.tprintf(`{{"type":"result","id":"%s","result":{{"ok":true,"created_id":%d}}}}`, id, created))
	else do machine_route_reply(3, fmt.tprintf(`{{"type":"result","id":"%s","result":{{"ok":false,"error":"%s"}}}}`, id, error))
}

// Lines of text, n bytes or a little more.
@(private = "file")
ph_lines :: proc(n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; strings.builder_len(b) < n; i += 1 do fmt.sbprintf(&b, `{{"type":"message","n":%d,"pad":"%s"}}`+"\n", i, strings.repeat("x", 200, context.temp_allocator))
	return strings.to_string(b)
}

// ---- this Mac ----

// Who may start one, and to what: refused before anything is sent.
@(test)
pi_handoff_refuses_before_sending :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := ph_begin("refuse", body = ph_lines(100))
	defer ph_end(f)
	// only the user at this window: not Atlas, a script, a pi tab, nor a machine viewing this one
	for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .Panel, tab_id = 1}, {kind = .UI, hub = true}, {kind = .Internal}}) {
		r := run_command(ph_cmd(f), c, 1)
		testing.expectf(t, !r.ok && !r.pending, "%v: refused", c)
	}
	// the row as drawn: that machine's core restarted, or the project there has another folder
	r := run_command(ph_cmd(f, run = "fedcba9876543210"), {kind = .UI}, 1)
	testing.expect(t, !r.ok && r.error == PI_HANDOFF_GONE, r.error)
	r = run_command(ph_cmd(f, folder = "/home/me/other/api"), {kind = .UI}, 1)
	testing.expect(t, !r.ok && r.error == PI_HANDOFF_GONE, r.error)
	// a core that does not say it takes one
	state.machines[0].pi_handoff = false
	r = run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, !r.ok && strings.contains(r.error, "update Deckhand there"), r.error)
	state.machines[0].pi_handoff = true
	// another project's name there
	find_project(f.remote).cwd = "/home/me/web"
	r = run_command(ph_cmd(f, folder = "/home/me/web"), {kind = .UI}, 1)
	testing.expect(t, !r.ok && strings.contains(r.error, "not called api"), r.error)
	find_project(f.remote).cwd = "/home/me/api"
	// no transcript here (a Claude row's id, a gone file)
	c := ph_cmd(f)
	c.pi_session_id = "no-such"
	r = run_command(c, {kind = .UI}, 1)
	testing.expect(t, !r.ok && strings.contains(r.error, "no pi transcript"), r.error)
	// another machine's session is never sent on from here (only this Mac → another machine)
	c = ph_cmd(f)
	c.project_id = f.remote
	r = run_command(c, {kind = .UI}, 1)
	testing.expect(t, !r.ok && !r.pending, r.error)
	// nor is a part sent by anyone but pi_handoff itself
	r = run_command(Pi_Handoff_Part{project_id = f.remote, offset = 0, data = "eA==", last = true}, {kind = .UI}, 1)
	testing.expect(t, !r.ok && !r.pending, r.error)
	// larger than the cap (a sparse file: nothing is read)
	fd := posix.open(strings.clone_to_cstring(f.file, context.temp_allocator), {.WRONLY})
	testing.expect(t, posix.ftruncate(fd, posix.off_t(PI_HANDOFF_MAX + 1)) == .OK)
	posix.close(fd)
	r = run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, !r.ok && strings.contains(r.error, "at most 256 MB"), r.error)
	testing.expect_value(t, len(machine_test_links.texts), 0)
}

// Its whole lines go in parts of PI_HANDOFF_PART, each after the last one's answer, as the user's,
// the project id unpacked; the last answer's session finishes it; one at a time.
@(test)
pi_handoff_sends_in_parts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	body := ph_lines(PI_HANDOFF_PART * 2 + 1000)
	f := ph_begin("parts", body = strings.concatenate({body, `{"type":"mess`}, context.temp_allocator)) // pi writing its next line
	defer ph_end(f)
	want, _ := os.read_entire_file(f.file, context.temp_allocator)
	want = want[:len(want) - len(`{"type":"mess`)]
	r := run_command(ph_cmd(f), {kind = .UI}, 42)
	testing.expect(t, r.ok && r.pending, r.error)
	r2 := run_command(ph_cmd(f), {kind = .UI}, 43)
	testing.expect(t, !r2.ok && strings.contains(r2.error, "already"), "one at a time")
	got := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 3 {
		sent := ph_last()
		testing.expect_value(t, len(machine_test_links.texts), i + 1) // one at a time: the next after the answer
		testing.expect_value(t, json_path(sent, "command.type"), "pi_handoff_part")
		testing.expect_value(t, json_path(sent, "command.project_id"), "21")
		testing.expect(t, strings.contains(sent, `"on_behalf":{"kind":"ui"}`), "as the user's")
		testing.expect_value(t, json_path(sent, "command.offset"), fmt.tprint(strings.builder_len(got)))
		testing.expect_value(t, json_path(sent, "command.last"), i == 2 ? "true" : "<missing>")
		part, err := base64.decode(json_path(sent, "command.data"), allocator = context.temp_allocator)
		testing.expect(t, err == nil && len(part) <= PI_HANDOFF_PART)
		strings.write_bytes(&got, part)
		if i < 2 do ph_answer()
	}
	testing.expect(t, strings.to_string(got) == string(want), "the whole lines, in order")
	testing.expect_value(t, len(ph_finished), 0)
	ph_answer(created = 9)
	if testing.expect_value(t, len(ph_finished), 1) {
		want_id, _ := id_pack(3, 9)
		testing.expect(t, ph_finished[0].ok && ph_finished[0].created_id == want_id, ph_finished[0].error)
	}
	// the original stays as it was
	after, _ := os.read_entire_file(f.file, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(after), string(want)), "untouched")
	// a refusal there ends it, with its words; then another may start
	r = run_command(ph_cmd(f), {kind = .UI}, 44)
	testing.expect(t, r.pending, r.error)
	ph_answer(ok = false, error = "pi here is 1.0.0")
	if testing.expect_value(t, len(ph_finished), 2) do testing.expect(t, !ph_finished[1].ok && strings.contains(ph_finished[1].error, "on nuc: pi here is 1.0.0"), ph_finished[1].error)
	// the link going down mid-copy ends it
	r = run_command(ph_cmd(f), {kind = .UI}, 45)
	testing.expect(t, r.pending, r.error)
	ph_answer()
	machine_route_down(3)
	if testing.expect_value(t, len(ph_finished), 3) do testing.expect(t, !ph_finished[2].ok, "offline")
	machine_test_links.up[3] = true
	r = run_command(ph_cmd(f), {kind = .UI}, 46)
	testing.expect(t, r.pending, "free again")
}

// ---- the other machine ----

@(private = "file")
ph_part :: proc(f: Ph, offset: int, data: string, last := false, caller := PH_HUB) -> Result {
	enc, _ := base64.encode(transmute([]u8)data, allocator = context.temp_allocator)
	return run_command(Pi_Handoff_Part{project_id = f.local, offset = u64(offset), data = enc, last = last}, caller)
}

// Files in the folder of copies.
@(private = "file")
ph_copies :: proc(f: Ph) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	files, err := os.read_all_directory_by_path(fmt.tprintf("%s/%s", f.root, PI_HANDOFF_DIR), context.temp_allocator)
	if err != nil do return out[:]
	for x in files do append(&out, x.fullpath)
	return out[:]
}

// Only the hub's user; one copy at a time, in order; parts and the whole capped; bad base64, a
// stop, or a first line that is not a pi header drop it (the file goes); nothing in pi's store.
@(test)
pi_handoff_part_checks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := ph_begin("in")
	defer ph_end(f)
	ph_hub_attach()
	hdr := ph_header("abc", "/Users/me/api")
	// never this machine's own window, Atlas, a script, nor a hub's Atlas
	for c in ([]Caller{{kind = .UI}, {kind = .Control}, {kind = .Script}, {kind = .Control, hub = true}, {kind = .Internal}}) {
		r := ph_part(f, 0, hdr, caller = c)
		testing.expectf(t, !r.ok, "%v: refused", c)
	}
	testing.expect_value(t, len(ph_copies(f)), 0)
	// a project that is not this machine's, a pi too old to fork
	r := run_command(Pi_Handoff_Part{project_id = 999, offset = 0, data = "eA=="}, PH_HUB)
	testing.expect(t, !r.ok && r.error == "no such project here", r.error)
	state.reload.pi_version = "1.3.9"
	r = ph_part(f, 0, hdr)
	testing.expect(t, !r.ok && strings.contains(r.error, "1.4.0"), r.error)
	state.reload.pi_version = "1.5.1"
	// not from the start
	r = ph_part(f, 5, hdr)
	testing.expect(t, !r.ok && strings.contains(r.error, "out of order"), r.error)
	// the copy's file: named here, in the data dir's folder, 0600 (the folder 0700)
	r = ph_part(f, 0, hdr)
	testing.expect(t, r.ok, r.error)
	path, n := pi_handoff_in_for_test()
	testing.expect_value(t, n, u64(len(hdr)))
	base := path[strings.last_index_byte(path, '/') + 1:]
	testing.expect(t, strings.has_prefix(path, fmt.tprintf("%s/%s/", f.root, PI_HANDOFF_DIR)) && len(base) == 32 + len(".jsonl"), path)
	st: posix.stat_t
	posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	testing.expect_value(t, u32(transmute(posix._mode_t)st.st_mode) & 0o777, u32(0o600))
	posix.stat(strings.clone_to_cstring(fmt.tprintf("%s/%s", f.root, PI_HANDOFF_DIR), context.temp_allocator), &st)
	testing.expect_value(t, u32(transmute(posix._mode_t)st.st_mode) & 0o777, u32(0o700))
	// a second copy while one comes: refused, the first kept
	r = ph_part(f, 0, hdr)
	testing.expect(t, !r.ok && strings.contains(r.error, "another conversation"), r.error)
	testing.expect(t, os.exists(path), "the first is kept")
	// out of order: dropped
	r = ph_part(f, 1, "x")
	testing.expect(t, !r.ok && !os.exists(path), "dropped")
	// bad base64, a part over PI_HANDOFF_PART: dropped
	testing.expect(t, ph_part(f, 0, hdr).ok)
	path, _ = pi_handoff_in_for_test()
	r = run_command(Pi_Handoff_Part{project_id = f.local, offset = u64(len(hdr)), data = "!!!!"}, PH_HUB)
	testing.expect(t, !r.ok && !os.exists(path), r.error)
	testing.expect(t, ph_part(f, 0, hdr).ok)
	path, _ = pi_handoff_in_for_test()
	r = ph_part(f, len(hdr), strings.repeat("y", PI_HANDOFF_PART + 1, context.temp_allocator))
	testing.expect(t, !r.ok && !os.exists(path), r.error)
	// the whole over the cap (a smaller cap here)
	pi_handoff_cap_for_test(u64(len(hdr)) + 10)
	defer pi_handoff_cap_for_test(PI_HANDOFF_MAX)
	testing.expect(t, ph_part(f, 0, hdr).ok)
	path, _ = pi_handoff_in_for_test()
	testing.expect(t, ph_part(f, len(hdr), "0123456789").ok, "up to the cap")
	r = ph_part(f, len(hdr) + 10, "z")
	testing.expect(t, !r.ok && strings.contains(r.error, "larger than") && !os.exists(path), r.error)
	pi_handoff_cap_for_test(PI_HANDOFF_MAX)
	// a copy that stops coming goes
	testing.expect(t, ph_part(f, 0, hdr).ok)
	path, _ = pi_handoff_in_for_test()
	pi_handoff_tick(time.tick_add(time.tick_now(), PI_HANDOFF_IDLE + time.Second))
	testing.expect(t, !os.exists(path), "stopped: dropped")
	testing.expect(t, ph_part(f, 0, hdr).ok, "and another may come")
	pi_handoff_reset_for_test()
	// the first line must be a pi session header, before pi starts
	for bad in ([]string{"not json\n", `{"type":"message","id":"x","cwd":"/a"}` + "\n", `{"type":"session","cwd":"/a"}` + "\n", `{"type":"session","id":"x"}` + "\n", `{"type":"session","id":"x","cwd":"/a"}`, "\n"}) {
		r = ph_part(f, 0, bad, last = true)
		testing.expectf(t, !r.ok && strings.contains(r.error, "not a pi conversation"), "%q: %s", bad, r.error)
	}
	testing.expect_value(t, len(ph_copies(f)), 0)
	testing.expect_value(t, len(state.open_sessions), 0)
	// the hub never names the file: what an earlier run left goes at the first turn
	_ = os.write_entire_file(fmt.tprintf("%s/%s/leftover.jsonl", f.root, PI_HANDOFF_DIR), transmute([]u8)string("x"))
	pi_handoff_tick(time.tick_now())
	testing.expect_value(t, len(ph_copies(f)), 0)
	store, _ := os.read_all_directory_by_path(f.store, context.temp_allocator)
	testing.expect_value(t, len(store), 1) // only this machine's own session: nothing written in pi's store
}

// A whole copy: pi started as `pi --fork <copy> --session-id <id>` in the project's folder, the id
// a name-based one (the same copy again: the same session); the copy goes once pi wrote its file;
// with the file there, resumed; a tab that exits without writing it says so and the copy goes.
@(test)
pi_handoff_part_forks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := ph_begin("fork")
	defer ph_end(f)
	ph_hub_attach()
	os.set_env("SHELL", "/bin/sh")
	args := fmt.tprintf("%s/args", f.root)
	os.set_env("DECKHAND_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s.tmp'; mv '%s.tmp' '%s'; exec sleep 30`, args, args, args))
	defer os.unset_env("DECKHAND_CMD")
	copy := strings.concatenate({ph_header("orig-7", "/Users/me/api"), ph_lines(3000)}, context.temp_allocator)
	sum: [32]u8
	hash.hash_string_to_buffer(.SHA256, copy, sum[:])
	want := pi_handoff_fork_id("orig-7", find_project(f.local).cwd, string(hex.encode(sum[:], context.temp_allocator)), context.temp_allocator)
	testing.expect(t, want != "orig-7", want)
	send :: proc(t: ^testing.T, f: Ph, copy: string) -> Result {
		testing.expect(t, ph_part(f, 0, copy[:1000]).ok)
		return ph_part(f, 1000, copy[1000:], last = true)
	}
	r := send(t, f, copy)
	testing.expect(t, r.ok && r.created_id != 0, r.error)
	s := find_session(r.created_id)
	if !testing.expect(t, s != nil) do return
	testing.expect_value(t, s.pi_session_id, want)
	testing.expect_value(t, s.project_id, f.local)
	forks := pi_handoff_forks_for_test()
	if !testing.expect_value(t, len(forks), 1) do return
	temp := strings.clone(forks[0], context.temp_allocator)
	testing.expect(t, strings.has_prefix(temp, fmt.tprintf("%s/%s/", f.root, PI_HANDOFF_DIR)), temp)
	got := ""
	for _ in 0 ..< 250 {
		if b, err := os.read_entire_file(args, context.temp_allocator); err == nil && len(b) > 0 {
			got = string(b)
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, strings.contains(got, fmt.tprintf("--fork\n%s\n--session-id\n%s\n", temp, want)), got)
	testing.expect(t, !strings.contains(got, "\n--session\n"), got)
	// the same copy again while pi starts: the same session, nothing new
	n := len(state.open_sessions)
	r2 := send(t, f, copy)
	testing.expect(t, r2.ok && r2.created_id == r.created_id, r2.error)
	testing.expect_value(t, len(state.open_sessions), n)
	testing.expect_value(t, len(ph_copies(f)), 1) // only the one pi forks
	// pi wrote the fork: the copy goes
	_ = os.write_entire_file(fmt.tprintf("%s/2026-11-15T10-00-00-000Z_%s.jsonl", f.store, want), transmute([]u8)ph_header(want, find_project(f.local).cwd))
	pi_handoff_tick(time.tick_add(time.tick_now(), 2 * time.Second))
	testing.expect(t, !os.exists(temp), "gone once pi wrote its file")
	testing.expect_value(t, len(pi_handoff_forks_for_test()), 0)
	// closed, then the same copy again: its file is resumed, never forked again
	run_command(Close_Session{session = r.created_id}, {kind = .Internal})
	os.remove(args)
	r3 := send(t, f, copy)
	testing.expect(t, r3.ok && r3.created_id != 0, r3.error)
	testing.expect_value(t, len(ph_copies(f)), 0)
	got = ""
	for _ in 0 ..< 250 {
		if b, err := os.read_entire_file(args, context.temp_allocator); err == nil && len(b) > 0 {
			got = string(b)
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, !strings.contains(got, "--fork") && strings.contains(got, fmt.tprintf("_%s.jsonl\n", want)), got)
	// more of the conversation: another id, forked; its pi exits without writing: the copy goes
	more := strings.concatenate({copy, ph_lines(10)}, context.temp_allocator)
	r4 := send(t, f, more)
	testing.expect(t, r4.ok && find_session(r4.created_id) != nil && find_session(r4.created_id).pi_session_id != want, r4.error)
	forks = pi_handoff_forks_for_test()
	if !testing.expect_value(t, len(forks), 1) do return
	temp = strings.clone(forks[0], context.temp_allocator)
	run_command(Tab_Exited{tab_id = find_session(r4.created_id).tabs[0].id, exit = {known = true, code = 1}})
	pi_handoff_tick(time.tick_add(time.tick_now(), 4 * time.Second))
	testing.expect(t, !os.exists(temp), "gone once its tab exited")
	testing.expect_value(t, len(pi_handoff_forks_for_test()), 0)
}

// Review 1 (P1): the sender opens the transcript itself, never a link to another file, inside pi's
// sessions folder (a session folder that is a link out of it is refused), and checks its first line
// is a pi session header before anything is sent. (P2) Its last newline is looked for in at most
// PI_HANDOFF_TAIL_MAX from the end.
@(test)
pi_handoff_sender_reads_only_a_pi_transcript :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := ph_begin("send", body = ph_lines(100))
	defer ph_end(f)
	other := fmt.tprintf("%s/secret.txt", f.store) // inside pi's sessions folder: only O_NOFOLLOW refuses it
	_ = os.write_entire_file(other, transmute([]u8)string("{\"type\":\"session\",\"id\":\"x\",\"cwd\":\"/\"}\nnot a transcript\n"))
	kept := fmt.tprintf("%s/kept.jsonl", f.root)
	os.rename(f.file, kept)
	posix.symlink(strings.clone_to_cstring(other, context.temp_allocator), strings.clone_to_cstring(f.file, context.temp_allocator))
	r := run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, !r.ok && !r.pending, "a link: refused")
	os.remove(f.file)
	// a first line that is not a pi session header
	_ = os.write_entire_file(f.file, transmute([]u8)string("hello\nworld\n"))
	r = run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, !r.ok && strings.contains(r.error, "not a pi conversation"), r.error)
	// no newline in the last PI_HANDOFF_TAIL_MAX: refused, without reading the rest
	big := strings.concatenate({ph_header("src-1", "/a"), strings.repeat("y", PI_HANDOFF_TAIL_MAX + 10, context.temp_allocator)}, context.temp_allocator)
	_ = os.write_entire_file(f.file, transmute([]u8)big)
	r = run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, !r.ok && !r.pending, r.error)
	// the session folder a link out of pi's sessions folder
	os.remove(f.file)
	os.rename(kept, f.file)
	outside := fmt.tprintf("%s/outside", f.root)
	os.rename(f.store, outside)
	posix.symlink(strings.clone_to_cstring(outside, context.temp_allocator), strings.clone_to_cstring(f.store, context.temp_allocator))
	r = run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, !r.ok && !r.pending, "out of pi's sessions folder: refused")
	testing.expect_value(t, len(machine_test_links.texts), 0)
	// back in place: it goes
	os.remove(f.store)
	os.rename(outside, f.store)
	r = run_command(ph_cmd(f), {kind = .UI}, 1)
	testing.expect(t, r.pending, r.error)
}

// Review 1 (P2): a copy coming in belongs to the hub connection it came on: a part on another one
// is refused, and the copy goes when its connection does.
@(test)
pi_handoff_part_bound_to_its_link :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := ph_begin("conn")
	defer ph_end(f)
	hdr := ph_header("abc", "/Users/me/api")
	// no hub link at all: refused
	testing.expect(t, !ph_part(f, 0, hdr).ok, "no hub link")
	ph_hub_attach()
	testing.expect(t, ph_part(f, 0, hdr).ok)
	path, _ := pi_handoff_in_for_test()
	// that hub goes: the partial copy goes with it
	core_detach_window()
	testing.expect(t, !os.exists(path), "dropped with its connection")
	// another hub connection cannot finish it at the offset it expected
	ph_hub_attach()
	r := ph_part(f, len(hdr), "{}\n", last = true)
	testing.expect(t, !r.ok && len(state.open_sessions) == 0, r.error)
	// a part on another connection while one comes is refused, the first kept
	testing.expect(t, ph_part(f, 0, hdr).ok)
	path, _ = pi_handoff_in_for_test()
	core_detach_window()
	ph_hub_attach()
	window_link_for_test().hub = true
	testing.expect(t, !os.exists(path), "the first went with its link")
}

} // when TEST_HOOKS

when TEST_HOOKS {
// The menu's rows: one per same-named project on an online machine that takes one, for a pi
// session with its transcript here; none for another session, another project or such a machine.
@(test)
pi_handoff_targets_filter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := ph_begin("rows")
	defer ph_end(f)
	got := pi_handoff_targets(f.local, "src-1")
	if testing.expect_value(t, len(got), 1) {
		testing.expect_value(t, got[0].label, "Continue this conversation on nuc in api")
		testing.expect_value(t, got[0].project_id, f.remote)
		testing.expect_value(t, got[0].run, PH_RUN)
	}
	testing.expect_value(t, len(pi_handoff_targets(f.local, "no-such")), 0)
	testing.expect_value(t, len(pi_handoff_targets(f.remote, "src-1")), 0)
	state.machines[0].pi_handoff = false
	testing.expect_value(t, len(pi_handoff_targets(f.local, "src-1")), 0)
	state.machines[0].pi_handoff, state.machines[0].status = true, .Offline
	testing.expect_value(t, len(pi_handoff_targets(f.local, "src-1")), 0)
}
}

// Review 2: fd_real_path is the opened file's own path (an ancestor link resolved, a rename
// followed), which pi_handoff checks against pi's sessions folder after opening.
@(test)
fd_real_path_is_the_opened_file :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	root := strings.clone(real_path(fmt.tprintf("%s/dh-fdp-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)))
	os.make_directory_all(fmt.tprintf("%s/real", root))
	defer os.remove_all(root)
	root = strings.clone(real_path(root))
	_ = os.write_entire_file(fmt.tprintf("%s/real/f.jsonl", root), transmute([]u8)string("x\n"))
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/real", root), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/link", root), context.temp_allocator))
	fd := posix.open(strings.clone_to_cstring(fmt.tprintf("%s/link/f.jsonl", root), context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
	testing.expect(t, fd >= 0)
	defer posix.close(fd)
	testing.expect_value(t, fd_real_path(fd), fmt.tprintf("%s/real/f.jsonl", root))
	os.rename(fmt.tprintf("%s/real", root), fmt.tprintf("%s/moved", root))
	testing.expect_value(t, fd_real_path(fd), fmt.tprintf("%s/moved/f.jsonl", root))
	testing.expect_value(t, fd_real_path(-1), "")
}
