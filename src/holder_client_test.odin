package main

// The session holder's pure parts on the app side (holder_client.odin, holder_adopt.odin): the
// socket name, OUTPUT and TAIL offset arithmetic, handover.json's checks, the query-reply drop
// for replayed bytes, and held ids in workspace.json. No holder runs here (holder_test_allowed
// stays false: holder_client_start never connects or launches under odin test).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import gh "ghostty"

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
	socket_tokens_bind(101, 1)
	path := fmt.tprintf("%s/tokens.json", home_root)
	_, ok, why := macfile_read(path, TOKENS_KIND, f.key[:], context.temp_allocator)
	testing.expect(t, ok, why)
}
