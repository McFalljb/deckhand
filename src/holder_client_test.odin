package main

// The session holder's pure parts on the app side (holder_client.odin, holder_adopt.odin): the
// socket name, OUTPUT and TAIL offset arithmetic, handover.json's checks, the query-reply drop
// for replayed bytes, and held ids in workspace.json. No holder runs here (holder_test_allowed
// stays false: holder_client_start never connects or launches under odin test).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import gh "ghostty"
import hw "holderwire"

@(test)
holder_sock_names :: proc(t: ^testing.T) {
	testing.expect(t, holder_sock_name_ok("holder-0123abcd.sock"))
	for bad in ([]string{"holder-0123ABCD.sock", "holder-0123abc.sock", "holder-0123abcde.sock", "holder-0123abcd.sock.x", "core.sock", "holder-../ab.sock", "xholder-0123abcd.sock", ""}) {
		testing.expectf(t, !holder_sock_name_ok(bad), "%q accepted", bad)
	}
}

@(test)
held_output_offsets :: proc(t: ^testing.T) {
	cases := []struct {
		next, start: u64,
		n:           int,
		skip:        int,
		gap:         bool,
	} {
		{100, 100, 10, 0, false}, // contiguous
		{100, 95, 10, 5, false}, // overlap: the first 5 were received
		{100, 90, 10, 10, false}, // all of it was received
		{100, 50, 10, 10, false},
		{100, 101, 10, 0, true}, // a byte never came
		{0, 0, 0, 0, false},
		{max(u64), 0, 10, 10, false}, // no overflow
	}
	for c, i in cases {
		skip, gap := held_output_place(c.next, c.start, c.n)
		testing.expectf(t, skip == c.skip && gap == c.gap, "case %d: skip %d gap %v", i, skip, gap)
	}
}

@(test)
held_tail_offsets :: proc(t: ^testing.T) {
	cases := []struct {
		snap, start, end: u64,
		skip:             int,
		exact, ok:        bool,
	} {
		{100, 100, 150, 0, true, true}, // the tail starts at the snapshot: exact
		{100, 60, 150, 40, true, true}, // skip the overlap
		{150, 60, 150, 90, true, true}, // nothing printed since
		{100, 120, 150, 0, false, true}, // 20 bytes lost (the tail's cap): inexact, the whole tail
		{200, 60, 150, 0, false, false}, // a snapshot ahead of the holder: not this terminal's
		{100, 160, 150, 0, false, false}, // a tail ending before it starts
		{0, 0, 0, 0, true, true},
	}
	for c, i in cases {
		skip, exact, ok := held_tail_skip(c.snap, c.start, c.end)
		testing.expectf(t, skip == c.skip && exact == c.exact && ok == c.ok, "case %d: %d %v %v", i, skip, exact, ok)
	}
}

@(test)
handover_parse_rules :: proc(t: ^testing.T) {
	SHA :: "abababababababababababababababababababababababababababababababab"
	sha := SHA
	good := fmt.tprintf(`{{"v":1,"min_reader":1,"holder":"aa","boot":5,"written":9,"terminals":[{{"term":3,"offset":10,"sha256":"%s","format":"ghostsnp/1","inexact":false}}]}}`, sha)
	f, ok, why := handover_parse(good)
	testing.expect(t, ok, why)
	testing.expect(t, len(f.terminals) == 1 && f.terminals[0].term == 3 && f.terminals[0].offset == 10)
	testing.expect_value(t, f.holder, "aa")
	bad := []string {
		"",
		"[1]",
		"{not json",
		strings.repeat("[", 10000, context.temp_allocator), // a depth bomb
		`{"v":1,"terminals":[{"term":0,"offset":1,"sha256":"` + SHA + `"}]}`, // id 0
		`{"v":1,"terminals":[{"term":4294967296,"offset":1,"sha256":"` + SHA + `"}]}`, // past u32
		`{"v":1,"terminals":[{"term":-1,"offset":1,"sha256":"` + SHA + `"}]}`,
		`{"v":1,"terminals":[{"term":3,"offset":1,"sha256":"` + SHA + `"},{"term":3,"offset":1,"sha256":"` + SHA + `"}]}`, // twice
		`{"v":1,"terminals":[{"term":3,"offset":1,"sha256":"abc"}]}`, // short hash
		`{"v":1,"terminals":[{"term":3,"offset":1,"sha256":"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}]}`, // not hex
		`{"v":1,"terminals":[{"term":"3","offset":1,"sha256":"` + SHA + `"}]}`, // wrong type
		"{\"v\":1,\"holder\":\"\xff\"}", // invalid UTF-8
	}
	for b, i in bad {
		_, bok, _ := handover_parse(b)
		testing.expectf(t, !bok, "bad case %d accepted", i)
	}
}

// §7.2 P4: a query in bytes replayed at adopt gets no reply; one in live output does.
@(test)
replayed_queries_dropped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	term := new(Term)
	defer free(term)
	testing.expect(t, term_init(term, 40, 4))
	defer term_free(term)
	term_feed_replayed(term, transmute([]u8)string("hi\x1b[c\x1b[6n\x1b]11;?\x07"))
	testing.expect_value(t, term.replies_dropped, 3)
	testing.expect(t, !term.mute_replies)
	before := term.replies_dropped
	q := "\x1b[c"
	gh.terminal_vt_write(term.gt, raw_data(q), len(q)) // live: answered (to a closed pty here)
	testing.expect_value(t, term.replies_dropped, before)
}

// Held ids in workspace.json: written for a running held tab while the holder keeps sessions,
// read back into the restored tabs (pi tab, shells, Home), and refused when out of range.
@(test)
held_ids_persist :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	for _, x in terms {
		term_free(x)
		free(x)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	persist = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	proj := fmt.aprintf("%s/pi-desk-held-%d", strings.trim_right(tmp, "/"), os.get_pid())
	os.make_directory_all(proj)
	defer os.remove(proj)

	text := fmt.tprintf(`{{"v":1,"projects":[{{"cwd":"%s","added":true}}],"open_sessions":[{{"pi_session_id":"hhhh-1","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi","held":7,"readonly":true}},{{"kind":"shell","title":"a","cwd":"%s","held":8}},{{"kind":"shell","title":"b","cwd":"%s","held":4294967296}},{{"kind":"shell","title":"c","cwd":"%s","held":0}}],"active_tab":1}}]}}`, proj, proj, proj, proj, proj, proj)
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	if len(state.open_sessions) != 1 do return
	s := &state.open_sessions[0]
	testing.expect_value(t, len(s.tabs), 4)
	if len(s.tabs) != 4 do return
	testing.expect_value(t, s.tabs[0].held, u32(7))
	testing.expect(t, s.tabs[0].kind.(Pi_Tab).readonly) // as it was started
	testing.expect_value(t, s.tabs[1].held, u32(8))
	testing.expect_value(t, s.tabs[2].held, u32(0)) // past u32: refused
	testing.expect_value(t, s.tabs[3].held, u32(0))

	// written only while the holder keeps sessions, and only for running held terminals
	x := new_term(s.tabs[1].id)
	x.running = true
	x.pty.held = 8
	testing.expect(t, !strings.contains(workspace_json(), `"held"`))
	hc.handover = true
	saved := workspace_json()
	hc.handover = false
	testing.expect(t, strings.contains(saved, `"held":8`), saved)
	testing.expect(t, !strings.contains(saved, `"held":7`), saved) // the pi tab did not start here
	x.pty.held = 0 // never a RELEASE from a test
	x.running = false
}

// A holder socket that answers but gives no WELCOME (refused, another wire after an update, too
// slow, a bad TAIL) means a holder runs there with its sessions: no second holder is launched
// (restored tabs would start duplicates of what it runs); the app runs without one, and says so.
@(test)
holder_answered_no_second_launch :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Refuse}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	toast_clear()
	testing.expect(t, !holder_client_start(), "attached to something")
	files, _ := os.read_all_directory_by_path(f.dir, context.temp_allocator)
	for x in files do testing.expectf(t, !holder_sock_name_ok(x.name) || x.name == "holder-0000fa01.sock", "a second holder: %s", x.name)
	testing.expect(t, os.exists(f.path), "the answering holder's socket is kept")
	testing.expect(t, strings.contains(toast.text, "session holder"), toast.text)
	testing.expect(t, !holder_wanted(), "new tabs run on their own PTYs")
}

// A dead holder's socket (nobody listening: kill -9) is removed, and with keep_sessions off it
// does not use up the one start of this run: turning the setting on later still starts one.
@(test)
holder_stale_socket_removed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{no_listen = true}
	fake_holder_start(t, &f, keep = false)
	defer fake_holder_stop(&f)
	stale := fmt.tprintf("%s/holder-0000dead.sock", f.dir)
	fd, ok := sock_listen(stale)
	testing.expect(t, ok)
	sock_close(fd) // the file stays; a connect is refused
	testing.expect(t, !holder_client_start())
	testing.expect(t, !os.exists(stale), "the dead holder's socket is removed")
	testing.expect(t, !hc.tried, "the start is not used up")
}

// A holder started mid-run (keep_sessions turned on, then the first new tab) writes tokens.json
// from then on, as one attached at launch does: else a quit and relaunch finds no tokens for
// the tabs it spawned (pi "can't reach Deckhand", every read-only Claude stopped).
@(test)
holder_midrun_writes_tokens :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, previous = "none"}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	testing.expect(t, holder_wanted(), "attached")
	socket_tokens_bind(101, 1, {kind = .Shell})
	path := fmt.tprintf("%s/tokens.json", home_root)
	_, ok, why := macfile_read(path, TOKENS_KIND, f.key[:], context.temp_allocator)
	testing.expect(t, ok, why)
}

// A send that times out part-way (the holder stopped reading) leaves half a frame on the wire:
// the connection is done for, the holder lost (never more frames after the half one).
@(test)
holder_partial_send_loses :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, previous = "none", no_read = true}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	was := holder_send_timeout
	holder_send_timeout = 200 * time.Millisecond
	defer holder_send_timeout = was
	testing.expect(t, holder_wanted(), "attached")
	big := make([]u8, 4 << 20)
	defer delete(big)
	holder_input(1, big) // fills the socket buffer, then times out
	testing.expect(t, wait_until(2000, proc() -> bool {return sync.atomic_load(&hc.lost)}), "the holder is lost after a partial send")
}

// §7.7 "disk full while writing the handover: abort before GOODBYE; sessions kept": when the
// handover folder can't be written, no GOODBYE goes out and neither does a RELEASE at close:
// the held tabs run on (the next launch restores them crash-style, from the tails).
@(test)
holder_handover_unwritable_keeps :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, previous = "none"}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	testing.expect(t, holder_wanted(), "attached")
	h := new(Held)
	h.id, h.spawn, h.pid = 5, .Spawned, i32(os.get_pid())
	hc.held[5] = h
	x := new_term(9101)
	x.running, x.pty = true, Pty{fd = -1, held = 5}
	defer {
		x.pty.held, x.running = 0, false
		drop_term(9101)
	}
	// the handover folder is a file: it cannot be made
	_ = os.write_entire_file(fmt.tprintf("%s/handover", home_root), transmute([]u8)string("x"))
	holder_handover()
	testing.expect(t, holder_keeps_sessions(), "the held tabs are saved as held")
	pty_close(&x.pty) // close_all
	time.sleep(150 * time.Millisecond)
	testing.expect_value(t, fake_holder_count(&f, .Goodbye), 0)
	testing.expect_value(t, fake_holder_count(&f, .Release), 0)
}

// ---- adopt at launch, against a fake holder ----

@(private = "file")
fake_term :: proc(id: i64, tail: string) -> hw.Welcome_Terminal {
	return {id = id, pid = i64(os.get_pid()), pgid = i64(os.get_pid()), cols = 80, rows = 24, offset = u64(len(tail))}
}

// A clean State, the fake's tokens.json written as an earlier run would have (binds: term ->
// what it was started as), then workspace `text` restored and holder_adopt_all run.
@(private = "file")
adopt_run :: proc(t: ^testing.T, f: ^Fake_Holder, text: string, binds: map[u32]Held_Start, clean := true) {
	for _, x in terms {
		x.pty.held, x.running = 0, false // never a RELEASE or kill from here
		term_free(x)
		free(x)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}, settings = {keep_sessions = true}}
	persist = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	path := fmt.tprintf("%s/tokens.json", home_root)
	socket_tokens_enable(path, f.key[:])
	tab := u64(900)
	for term, st in binds {
		tab += 1
		socket_tokens_bind(tab, term, st)
	}
	socket_tokens_disable(false)
	testing.expect_value(t, workspace_restore(text), "")
	persist.restored_clean = clean
	holder_adopt_all()
}

@(private = "file")
adopt_proj :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	proj := fmt.aprintf("%s/pi-desk-adopt-%d", strings.trim_right(tmp, "/"), os.get_pid())
	os.make_directory_all(proj)
	return proj
}

// What a terminal was started as comes from the MAC'd tokens.json: a pi tab is read-only if it
// was started so (whatever workspace.json says), keeps the extensions it started with (no false
// restart offer), Atlas keeps its applied model; a terminal mapped to another kind of tab (a
// Claude into a shell tab) is not adopted; entries for terminals the holder no longer lists go.
@(test)
holder_adopt_checks_start :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, terms = {fake_term(3, "pi\r\n"), fake_term(4, "claude\r\n"), fake_term(5, "atlas\r\n")}, tails = {transmute([]u8)string("pi\r\n"), transmute([]u8)string("claude\r\n"), transmute([]u8)string("atlas\r\n")}}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	proj := adopt_proj()
	defer os.remove(proj)
	binds := make(map[u32]Held_Start, context.temp_allocator)
	binds[3] = {kind = .Pi, pi_ro = true, extras = 9}
	binds[4] = {kind = .Claude}
	binds[5] = {kind = .Pi}
	binds[6] = {kind = .Shell} // gone from the holder
	text := fmt.tprintf(`{{"v":1,"holder":"%s","projects":[{{"cwd":"%s","added":true}}],"open_sessions":[{{"pi_session_id":"aaaa-1","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi","held":3}},{{"kind":"shell","title":"a","cwd":"%s","held":4}}],"active_tab":0}}],"home":{{"pi_session_id":"hhhh-home","held":5,"model_applied":"m-applied"}}}}`, f.instance, proj, proj, proj, proj)
	delete(agent_model_starting)
	agent_model_starting = strings.clone("m-other")
	adopt_run(t, &f, text, binds)
	s: ^Open_Session
	for &x in state.open_sessions do if !x.home do s = &x
	testing.expect(t, s != nil && len(s.tabs) == 2, "restored")
	if s == nil || len(s.tabs) != 2 do return
	testing.expect_value(t, s.tabs[0].status, Tab_Status.Running)
	testing.expect(t, s.tabs[0].kind.(Pi_Tab).readonly, "read-only as started (tokens.json)")
	testing.expect_value(t, s.tabs[0].reload.extras, u64(9))
	testing.expect_value(t, s.tabs[1].status, Tab_Status.Not_Started) // a Claude is not a shell tab
	testing.expect(t, term_of(s.tabs[1].id) == nil, "not adopted")
	hs := home_session()
	testing.expect(t, hs != nil && hs.tabs[0].status == .Running, "Atlas adopted")
	testing.expect_value(t, agent_model_starting, "m-applied")
	_, f6 := socket_tokens_start_of(6)
	testing.expect(t, !f6, "term 6 is no longer listed: pruned")
}

// Terminals no restored tab claims are hung up only when that is known to be safe: the saved
// workspace restored cleanly and listed them (or they already ended). Otherwise (--fresh, a
// workspace moved aside, a crash before the first save) they keep running in the holder, their
// output not kept by the app, and a toast says so: a launch never hangs up a kept pi or Claude
// it knows nothing about.
@(test)
holder_unclaimed_kept :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ended := fake_term(7, "")
	ended.exit = hw.Exit_Status{code = 0}
	f := Fake_Holder{mode = .Welcome, terms = {fake_term(3, ""), ended}}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	toast_clear()
	adopt_run(t, &f, `{"v":1,"projects":[],"open_sessions":[]}`, nil, clean = false) // as --fresh
	wait_until(300, proc() -> bool {return false})
	testing.expect_value(t, fake_holder_count(&f, .Release, 3), 0)
	testing.expect_value(t, fake_holder_count(&f, .Release, 7), 1) // it ended: nothing to lose
	testing.expect(t, strings.contains(toast.text, "1 kept session wasn't restored"), toast.text)
	sync.lock(&hc.mu)
	h := hc.held[3]
	testing.expect(t, h != nil && h.kept, "kept, not shown")
	sync.unlock(&hc.mu)
}

// A clean restore whose tab listed the terminal but could not take it (here: tokens.json says it
// was started as a pi, the tab is a shell): released, as before. One nobody listed: kept.
@(test)
holder_unclaimed_released_when_known :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, terms = {fake_term(3, ""), fake_term(8, "")}}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	proj := adopt_proj()
	defer os.remove(proj)
	binds := make(map[u32]Held_Start, context.temp_allocator)
	binds[3] = {kind = .Pi}
	binds[8] = {kind = .Shell}
	text := fmt.tprintf(`{{"v":1,"holder":"%s","projects":[{{"cwd":"%s","added":true}}],"open_sessions":[{{"pi_session_id":"bbbb-1","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi"}},{{"kind":"shell","title":"a","cwd":"%s","held":3}}],"active_tab":0}}]}}`, f.instance, proj, proj, proj, proj)
	adopt_run(t, &f, text, binds)
	wait_until(300, proc() -> bool {return false})
	testing.expect_value(t, fake_holder_count(&f, .Release, 3), 1)
	testing.expect_value(t, fake_holder_count(&f, .Release, 8), 0)
}

// workspace.json's held ids are for the holder they were saved with (its instance id): another
// holder's terminals with the same numbers are never adopted (two holders both count from 1).
@(test)
holder_adopt_needs_same_instance :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, terms = {fake_term(3, "")}}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	proj := adopt_proj()
	defer os.remove(proj)
	binds := make(map[u32]Held_Start, context.temp_allocator)
	binds[3] = {kind = .Shell}
	text := fmt.tprintf(`{{"v":1,"holder":"another-holder","projects":[{{"cwd":"%s","added":true}}],"open_sessions":[{{"pi_session_id":"cccc-1","cwd":"%s","session_dir":"","project":"%s","tabs":[{{"kind":"pi"}},{{"kind":"shell","title":"a","cwd":"%s","held":3}}],"active_tab":0}}]}}`, proj, proj, proj, proj)
	adopt_run(t, &f, text, binds)
	s := &state.open_sessions[len(state.open_sessions) - 1]
	testing.expect_value(t, s.tabs[1].status, Tab_Status.Not_Started)
	wait_until(300, proc() -> bool {return false})
	testing.expect_value(t, fake_holder_count(&f, .Release, 3), 0) // not this workspace's: kept
	// and the instance is saved with the held ids
	x := new_term(9201)
	x.running, x.pty = true, Pty{fd = -1, held = 3}
	defer {
		x.pty.held, x.running = 0, false
		drop_term(9201)
	}
	testing.expect(t, strings.contains(workspace_json(), fmt.tprintf(`"holder":"%s"`, f.instance)), workspace_json())
}

// A holder attached mid-run (after the launch's adopt) that lists terminals keeps them, not shown.
@(test)
holder_midrun_lists_kept :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f := Fake_Holder{mode = .Welcome, terms = {fake_term(3, "x")}, tails = {transmute([]u8)string("x")}}
	fake_holder_start(t, &f)
	defer fake_holder_stop(&f)
	hc.adopt_done = true
	testing.expect(t, holder_wanted(), "attached")
	sync.lock(&hc.mu)
	h := hc.held[3]
	testing.expect(t, h != nil && h.kept && len(h.buf) == 0, "kept, its output not kept")
	sync.unlock(&hc.mu)
}

@(test)
held_release_unclaimed_rule :: proc(t: ^testing.T) {
	cases := []struct {
		ended, clean, same, listed, want: bool,
	} {
		{true, false, false, false, true}, // ended: nothing to lose
		{false, true, true, true, true}, // a clean restore listed it, and no tab could take it
		{false, false, true, true, false}, // --fresh, moved aside, missing
		{false, true, false, true, false}, // saved with another holder
		{false, true, true, false, false}, // a crash before the save that would have listed it
	}
	for c, i in cases do testing.expectf(t, held_release_unclaimed(c.ended, c.clean, c.same, c.listed) == c.want, "case %d", i)
}
