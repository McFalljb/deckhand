package core

// The window's door over core.sock and its side of it (window_sock.odin; §10.3 M4-C), with fake
// identities: the "peers" are this test binary, over a socketpair.

import "base:runtime"
import "core:os"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import cw "../corewire"
import "../trust"

// A release build (-define:DECKHAND_TEST_HOOKS=false) compiles _test files too, and these tests
// use helpers that exist only with the test hooks: the whole file is behind them.
when TEST_HOOKS {

@(test)
window_hello_refusal_table :: proc(t: ^testing.T) {
	ok := Window_Hello{token_ok = true, same_user = true, still = true, code = .Allow, floor = .Allow}
	testing.expect_value(t, window_hello_refusal(ok), "")
	cases := []struct {
		h:    Window_Hello,
		want: string,
	} {
		{{same_user = true, still = true, code = .Allow}, "framed mode is only for Deckhand's window (with the core's window token)"},
		{{token_ok = true, still = true, code = .Allow}, "the window must run as this user"},
		{{token_ok = true, same_user = true, code = .Allow}, "the window's process changed since it connected"},
		{{token_ok = true, same_user = true, still = true, code = .Wrong_Signer}, "the window's code is not Deckhand's (Wrong_Signer)"},
		{{token_ok = true, same_user = true, still = true, code = .Allow, floor = .Below_Floor}, "This Deckhand is older than the one last used with these sessions"},
		{{token_ok = true, same_user = true, still = true, code = .Allow, holder_child = true}, "a program running in a Deckhand tab can't be its window"},
		// the order: a bad token says nothing about the rest
		{{code = .Wrong_Identity, holder_child = true}, "framed mode is only for Deckhand's window (with the core's window token)"},
	}
	for c in cases do testing.expect_value(t, window_hello_refusal(c.h), c.want)
}

@(test)
pid_descends_from_ancestors :: proc(t: ^testing.T) {
	me, parent := i32(posix.getpid()), i32(posix.getppid())
	testing.expect(t, pid_descends_from(me, {me}), "itself")
	testing.expect(t, pid_descends_from(me, {0, parent}), "its parent")
	testing.expect(t, !pid_descends_from(parent, {me}), "not its child")
	testing.expect(t, !pid_descends_from(me, {0, 0}), "none")
}

// The window checks the process on core.sock before it sends a byte: our own code passes when it is
// the core's identity, and a "core" signed as anything else is refused.
@(test)
core_peer_check_refuses_a_fake_core :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer {posix.close(fds[0]); posix.close(fds[1])}
	posix.write(fds[1], raw_data(string("x")), 1) // the token names the last process to use the socket: this one
	own := trust.own_signature().identifier
	when TEST_HOOKS {
		core_peer_ids = []string{own}
		defer core_peer_ids = trust.CORE_IDS
	}
	p, why := core_peer_check(fds[0])
	testing.expect_value(t, why, "")
	testing.expect_value(t, p.pid, i32(posix.getpid()))
	when TEST_HOOKS do core_peer_ids = []string{"dev.deckhand.core"}
	_, why = core_peer_check(fds[0])
	// Linux: no code signing, the same user is the whole check (background-core.md §8.3)
	when ODIN_OS == .Linux do testing.expect_value(t, why, "")
	else do testing.expect(t, strings.has_prefix(why, "the process on core.sock is not Deckhand's core"), why)
}

// window.token: 64 hex, 0600, this user's; anything else is no token.
@(test)
window_token_file_rules :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/dkwt-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory(dir)
	defer os.remove_all(dir)
	testing.expect_value(t, window_token_read(dir), "")
	testing.expect(t, window_token_publish(dir), "publish")
	tok := window_token_read(dir)
	testing.expect_value(t, len(tok), 64)
	path := fmt.tprintf("%s/%s", dir, WINDOW_TOKEN_FILE)
	posix.chmod(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	testing.expect_value(t, window_token_read(dir), "") // readable by others: not one a core wrote
	window_door_stop()
	testing.expect(t, !os.exists(path), "gone at stop")
	socket_framed_handler = nil
}

// A window.request that wants a reply waits at most WINDOW_REPLY_WAIT over core.sock (Q9): a
// window that never answers costs the core 250 ms, then it answers as if there were no window; a
// window that answers in time is heard.
@(test)
window_request_bound_over_the_socket :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	peer := trust.peer_read(fds[0])
	testing.expect(t, core_attach_window_sock(fds[0], nil, peer))
	defer core_detach_window()
	win: cw.Sock_Transport
	cw.sock_open(&win, fds[1])
	defer cw.sock_destroy(&win)
	start := time.tick_now()
	slow0 := window_link_slow_replies
	ok := window_open_url("https://example.com")
	took := time.tick_since(start)
	testing.expect(t, !ok, "no answer: not opened")
	testing.expectf(t, took >= WINDOW_REPLY_WAIT && took < WINDOW_REPLY_WAIT + 200 * time.Millisecond, "waited %v", took)
	testing.expect_value(t, window_link_slow_replies, slow0 + 1)
	// a window that answers: read its requests, reply ok (on another thread, as the window process;
	// the first, late one is dropped by the core)
	th := thread_start_answer(&win)
	ok = window_open_url("https://example.com")
	thread_join_answer(th)
	testing.expect(t, ok, "answered in time: opened")
}

// A browser that connects on its own (a page load, a reconnect: its hello has no "take") while
// this Mac's window is attached does not take the view from it: the window stays attached, and
// the browser gets its hello's result and web.taken by the window (View here). With "take" (its
// user's View here) it takes the view as before; with no window attached it attaches as before.
@(test)
web_hello_without_take_leaves_the_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // the hello's data reads the build once (core_build)
	win: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &win) == .OK)
	testing.expect(t, core_attach_window_sock(win[0], nil, trust.peer_read(win[0])))
	defer core_detach_window()
	ws: cw.Sock_Transport
	cw.sock_open(&ws, win[1])
	defer cw.sock_destroy(&ws)
	web: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &web) == .OK)
	attached := core_attach_window_sock(web[0], nil, {}, from = "Phone", web = true, web_device = "dev1", web_hello_id = "hello")
	if !attached do posix.close(web[0])
	testing.expect(t, !attached, "not attached")
	testing.expect(t, window_link_is_window(), "the window stays attached")
	got := read_json_frames(web[1])
	posix.close(web[1])
	testing.expectf(t, len(got) == 2, "the hello's result and web.taken: %v", got)
	if len(got) == 2 {
		testing.expect_value(t, json_path(got[0], "type"), "result")
		testing.expect_value(t, json_path(got[0], "id"), "hello")
		testing.expect(t, strings.contains(got[0], `"ok":true`) && strings.contains(got[0], `"web":true`), got[0])
		testing.expect_value(t, json_path(got[1], "type"), "web.taken")
		testing.expect_value(t, json_path(got[1], "by"), "window")
	}
	// the window heard nothing of it
	testing.expect(t, !window_heard(&ws, "viewed_from"), "no Viewed in a browser")

	// its user's View here: "take" takes the view, the window is told (Viewed in a browser)
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &web) == .OK)
	defer posix.close(web[1])
	testing.expect(t, core_attach_window_sock(web[0], nil, {}, from = "Phone", web = true, web_device = "dev1", web_take = true, web_hello_id = "hello"), "take: attached")
	testing.expect(t, window_link_web(), "the browser's link")
	testing.expect(t, window_heard(&ws, "viewed_from"), "the window: Viewed in a browser")

	// another browser's own reconnect still replaces a browser (its own link the core has not seen go)
	web2: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &web2) == .OK)
	defer posix.close(web2[1])
	testing.expect(t, core_attach_window_sock(web2[0], nil, {}, from = "Phone", web = true, web_device = "dev1", web_hello_id = "hello"), "browser over browser: attached")
	testing.expect_value(t, window_link_web_device(), "dev1")

	// no window attached: a browser's own connect attaches
	core_detach_window()
	web3: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &web3) == .OK)
	defer posix.close(web3[1])
	testing.expect(t, core_attach_window_sock(web3[0], nil, {}, from = "Phone", web = true, web_device = "dev1", web_hello_id = "hello"), "no window: attached")
	testing.expect(t, window_link_web(), "the browser's link")
}

// The door's batch (window_door_tick): a window and a browser that connected on its own arrive in
// the same turn, the browser last. The window wins, and the browser gets its hello's result (with
// its hello's id, passed through web_arrived) and web.taken by the window, not a bare close. A
// browser with "take" in such a batch takes the view (its "take" passed through too).
@(test)
window_door_batch_prefers_the_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	web_reset_for_test()
	defer web_reset_for_test()
	now := time.to_unix_seconds(time.now())
	code, _ := web_code_open(now)
	_, tok, _ := web_pair_try(code, "Phone", now)
	dev, _, ok := web_token_device(tok, now)
	testing.expect(t, ok, "a paired browser")
	window_door_on_for_test(true)
	defer window_door_on_for_test(false)
	defer core_detach_window()

	win: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &win) == .OK)
	ws: cw.Sock_Transport
	cw.sock_open(&ws, win[1])
	defer cw.sock_destroy(&ws)
	web: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &web) == .OK)
	window_arrived_for_test(win[0], trust.peer_read(win[0]))
	web_arrived(web[0], dev, "Phone", false, "h7")
	window_door_tick()
	testing.expect(t, window_link_is_window(), "the window wins the batch")
	got := read_json_frames(web[1])
	posix.close(web[1])
	testing.expectf(t, len(got) == 2, "the hello's result and web.taken: %v", got)
	if len(got) == 2 {
		testing.expect_value(t, json_path(got[0], "id"), "h7")
		testing.expect_value(t, json_path(got[1], "type"), "web.taken")
		testing.expect_value(t, json_path(got[1], "by"), "window")
	}

	// its user's View here: take passes through the door and takes the view
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &web) == .OK)
	defer posix.close(web[1])
	web_arrived(web[0], dev, "Phone", true, "h8")
	window_door_tick()
	testing.expect(t, window_link_web(), "take: the browser's link")
	testing.expect(t, window_heard(&ws, "viewed_from"), "the window: Viewed in a browser")
}

// The JSON frames waiting on fd (its writer already wrote them), as text.
@(private = "file")
read_json_frames :: proc(fd: posix.FD) -> []string {
	buf: [64 << 10]u8
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | posix.O_NONBLOCK)
	n := posix.read(fd, &buf[0], len(buf))
	out := make([dynamic]string, context.temp_allocator)
	rest := buf[:max(n, 0)]
	for len(rest) > 0 {
		f, used, err := cw.next_frame(rest)
		if err != .None || used == 0 do break
		append(&out, strings.clone(string(f.payload), context.temp_allocator))
		rest = rest[used:]
	}
	return out[:]
}

// The window's end got a message with this text within a short wait.
@(private = "file")
window_heard :: proc(ws: ^cw.Sock_Transport, what: string) -> bool {
	deadline := time.tick_add(time.tick_now(), 300 * time.Millisecond)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		cw.sock_wait(ws, 10)
		f, e := cw.sock_recv(ws, context.temp_allocator)
		if e != .None do continue
		if strings.contains(string(f.payload), what) do return true
	}
	return false
}

@(private = "file")
thread_start_answer :: proc(a: rawptr) -> ^thread.Thread {
	return thread.create_and_start_with_data(a, proc(data: rawptr) {
		win := (^cw.Sock_Transport)(data)
		deadline := time.tick_add(time.tick_now(), 2 * time.Second)
		for time.tick_diff(time.tick_now(), deadline) > 0 {
			cw.sock_wait(win, 10)
			f, e := cw.sock_recv(win, context.temp_allocator)
			if e != .None do continue
			text := string(f.payload)
			if !strings.contains(text, `"open_url"`) do continue
			id := json_path(text, "id")
			r := Window_Reply{ok = true}
			cw.sock_send(win, cw.JSON_CHANNEL, .Data, transmute([]u8)window_msg_reply(id, &r))
			cw.sock_flush(win)
			if id == "q2" do return
		}
	})
}

@(private = "file")
thread_join_answer :: proc(th: ^thread.Thread) {
	thread.join(th)
	thread.destroy(th)
}

// The hub door (§10.4 M6-A): another machine's core is a second way to `ui`, so its hello gets the
// window's checks in the same order with the core's identifier, and no window floor.
@(test)
hub_hello_refusal_table :: proc(t: ^testing.T) {
	ok := Window_Hello{hub = true, allowed = true, via_sshd = true, token_ok = true, same_user = true, still = true, code = .Allow, floor = .Below_Floor}
	testing.expect_value(t, window_hello_refusal(ok), "") // the floor is the window's only
	bad := ok
	bad.holder_child = true
	testing.expect_value(t, window_hello_refusal(bad), "a program running in a Deckhand tab can't be its hub")
	bad = ok
	bad.code = .Wrong_Identity
	testing.expect_value(t, window_hello_refusal(bad), "the hub's code is not Deckhand's core (Wrong_Identity)")
}

// The real check on a socketpair (this test binary is the peer): a hub hello is refused with a
// window's identifier, from a descendant of this core or its holder, and with a wrong token; with
// the core's identifier, from outside, with the token, it is let in.
@(test)
hub_door_refusals :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/dkhub-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory(dir)
	defer os.remove_all(dir)
	testing.expect(t, window_token_publish(dir), "publish")
	defer {window_door_stop(); socket_framed_handler = nil}
	token := window_token_read(dir)
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer {posix.close(fds[0]); posix.close(fds[1])}
	posix.write(fds[1], raw_data(string("x")), 1) // the token names the last process to use the socket: this one
	peer, tok := trust.peer_read_token(fds[0])
	own := trust.own_signature().identifier
	me := i32(posix.getpid())
	window_door_pids_for_test(0, 0)
	window_door_hub_for_test(allowed = true, without_sshd = true) // round 1's checks: hub_door_round1
	defer window_door_hub_for_test(allowed = false, without_sshd = false)
	when TEST_HOOKS {
		window_peer_ids, hub_peer_ids = []string{own}, []string{"dev.deckhand.core"}
		defer {window_peer_ids, hub_peer_ids = trust.WINDOW_IDS, trust.CORE_IDS}
	}
	// a window's identifier: a window, not a hub (Linux has no window: refused there, PR #68 round 1)
	why, _ := window_hello_check(fds[0], peer, tok, token)
	when ODIN_OS == .Linux do testing.expect_value(t, why, NO_WINDOW_HERE)
	else do testing.expect_value(t, why, "")
	why, _ = window_hello_check(fds[0], peer, tok, token, hub = true)
	// Linux: no code signing, the same user is the whole check (background-core.md §8.3)
	when ODIN_OS == .Linux do testing.expect_value(t, why, "")
	else do testing.expect(t, strings.has_prefix(why, "the hub's code is not Deckhand's core"), why)
	when TEST_HOOKS do window_peer_ids, hub_peer_ids = []string{"dev.pi-desk.app"}, []string{own}
	why, _ = window_hello_check(fds[0], peer, tok, token, hub = true)
	testing.expect_value(t, why, "")
	// a wrong token
	wrong := strings.concatenate({token[:63], token[63] == '0' ? "1" : "0"}, context.temp_allocator)
	why, _ = window_hello_check(fds[0], peer, tok, wrong, hub = true)
	testing.expect_value(t, why, "framed mode is only for Deckhand's window (with the core's window token)")
	// a descendant of this core (here: the test process itself)
	window_door_pids_for_test(me, 0)
	why, _ = window_hello_check(fds[0], peer, tok, token, hub = true)
	testing.expect_value(t, why, "a program running in a Deckhand tab can't be its hub")
	window_door_pids_for_test(0, 0)
}

// Review round 1 (PR #69): the hub door is closed unless this machine allows other machines in
// (Settings › Machines), the hub must come through sshd, and a core can't be its own hub.
@(test)
hub_hello_refusal_round1 :: proc(t: ^testing.T) {
	ok := Window_Hello{hub = true, allowed = true, token_ok = true, same_user = true, still = true, code = .Allow, via_sshd = true}
	testing.expect_value(t, window_hello_refusal(ok), "")
	bad := ok
	bad.allowed = false
	testing.expect_value(t, window_hello_refusal(bad), HUB_NOT_ALLOWED)
	bad.token_ok = false // closed first: nothing else is said
	testing.expect_value(t, window_hello_refusal(bad), HUB_NOT_ALLOWED)
	bad = ok
	bad.via_sshd = false
	testing.expect_value(t, window_hello_refusal(bad), "the hub must come in through ssh")
	bad = ok
	bad.self = true
	testing.expect_value(t, window_hello_refusal(bad), "a core can't be its own hub")
	// a window needs neither
	win := Window_Hello{token_ok = true, same_user = true, still = true, code = .Allow, floor = .Allow}
	testing.expect_value(t, window_hello_refusal(win), "")
	// review round 1 (PR #68): an OS with no window (Linux) lets only a hub in, whatever else holds
	win.no_window = true
	testing.expect_value(t, window_hello_refusal(win), NO_WINDOW_HERE)
	ok.no_window = true
	testing.expect_value(t, window_hello_refusal(ok), "")
}

// sshd's ancestry: a root-owned sshd or sshd-session above the peer, within 64 steps.
@(test)
hub_via_sshd_walk :: proc(t: ^testing.T) {
	look :: proc(pid: i32) -> (parent: i32, uid: u32, name: string) {
		switch pid {
		case 100: return 90, 501, "deckhand-core-serve" // connect
		case 90:  return 80, 501, "zsh"
		case 80:  return 70, 501, "sshd-session" // the user's half
		case 70:  return 1, 0, "sshd-session" // root's
		case 200: return 1, 501, "deckhand-core-serve" // detached from a tab: launchd's
		case 300: return 310, 501, "deckhand-core-serve"
		case 310: return 1, 501, "sshd" // a user's own sshd
		case 400: return 400, 501, "loop" // its own parent
		}
		return 0, 0, ""
	}
	testing.expect(t, pid_via_sshd(100, look), "under root's sshd-session")
	testing.expect(t, !pid_via_sshd(200, look), "launchd's child")
	testing.expect(t, !pid_via_sshd(300, look), "a user-owned sshd is not sshd")
	testing.expect(t, !pid_via_sshd(400, look), "a loop ends")
	testing.expect(t, !pid_via_sshd(0, look), "no pid")
}

// The real check: closed by default, then sshd, then self.
@(test)
hub_door_round1 :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/dkhr1-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory(dir)
	defer os.remove_all(dir)
	testing.expect(t, window_token_publish(dir), "publish")
	defer {window_door_stop(); socket_framed_handler = nil}
	token := window_token_read(dir)
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer {posix.close(fds[0]); posix.close(fds[1])}
	posix.write(fds[1], raw_data(string("x")), 1)
	peer, tok := trust.peer_read_token(fds[0])
	own := trust.own_signature().identifier
	window_door_pids_for_test(0, 0)
	when TEST_HOOKS {
		window_peer_ids, hub_peer_ids = []string{"dev.pi-desk.app"}, []string{own}
		defer {window_peer_ids, hub_peer_ids = trust.WINDOW_IDS, trust.CORE_IDS}
	}
	other := strings.repeat("ab", 32, context.temp_allocator)
	// off by default
	window_door_hub_for_test(allowed = false, without_sshd = true)
	why, _ := window_hello_check(fds[0], peer, tok, token, hub = true, core_id = other)
	testing.expect_value(t, why, HUB_NOT_ALLOWED)
	// allowed, but this test binary is under no sshd
	if !pid_via_sshd(i32(posix.getpid())) {
		window_door_hub_for_test(allowed = true, without_sshd = false)
		why, _ = window_hello_check(fds[0], peer, tok, token, hub = true, core_id = other)
		testing.expect_value(t, why, "the hub must come in through ssh")
	}
	window_door_hub_for_test(allowed = true, without_sshd = true)
	why, _ = window_hello_check(fds[0], peer, tok, token, hub = true, core_id = other)
	testing.expect_value(t, why, "")
	// this core's own id: itself
	why, _ = window_hello_check(fds[0], peer, tok, token, hub = true, core_id = window_door_core_id())
	testing.expect_value(t, why, "a core can't be its own hub")
	testing.expect(t, hex64_ok(window_door_core_id()), "a core id")
	window_door_hub_for_test(allowed = false, without_sshd = false)
}

// `deckhand-core-serve web …` (web_admin_check): the window token and this user are not enough. A
// tab's program can fork, let its parent exit (reparented: no longer a tab's descendant) and read
// window.token, so the terminal must come in from outside: a root-owned sshd above it. Not login:
// macOS's `/usr/bin/login -f $USER` is setuid root and asks the same user for no password.
@(test)
web_admin_from_outside :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/dkwa-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory(dir)
	defer os.remove_all(dir)
	testing.expect(t, window_token_publish(dir), "publish")
	defer {window_door_stop(); socket_framed_handler = nil}
	token := window_token_read(dir)
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer {posix.close(fds[0]); posix.close(fds[1])}
	peer := trust.peer_read(fds[0])
	window_door_pids_for_test(0, 0) // not a tab's descendant: the reparented case
	testing.expect_value(t, web_admin_check(fds[0], peer, "nope"), "web: not this core's window token")
	// this test binary has no root-owned sshd above it (as a reparented tab program)
	if !pid_from_outside(i32(posix.getpid())) {
		testing.expect_value(t, web_admin_check(fds[0], peer, token), WEB_ADMIN_NOT_OUTSIDE)
	}
	window_door_web_admin_anywhere_for_test(true)
	testing.expect_value(t, web_admin_check(fds[0], peer, token), "")
	window_door_web_admin_anywhere_for_test(false)
	// a tab's descendant: refused whatever is above it
	window_door_pids_for_test(i32(posix.getpid()), 0)
	window_door_web_admin_anywhere_for_test(true)
	testing.expect(t, strings.contains(web_admin_check(fds[0], peer, token), "a Deckhand tab"), "a tab's program")
	window_door_web_admin_anywhere_for_test(false)
	window_door_pids_for_test(0, 0)
	// the walk: root's sshd or sshd-session; not login (a tab can start one), not a user's, not launchd's child
	look :: proc(pid: i32) -> (parent: i32, uid: u32, name: string) {
		switch pid {
		case 100: return 101, 501, "zsh"
		case 101: return 102, 0, "login" // Terminal.app, iTerm2, a Linux console
		case 102: return 1, 0, "Terminal"
		case 200: return 1, 501, "sh" // reparented: launchd's (or init's) child
		case 300: return 301, 501, "sh"
		case 301: return 1, 501, "login" // a login the user started is not root's
		case 400: return 401, 501, "sh"
		case 401: return 1, 0, "sshd-session"
		case 500: return 501, 501, "sh"
		case 501: return 1, 0, "sudo" // root-owned, but not a way in
		}
		return 0, 0, ""
	}
	testing.expect(t, !pid_from_outside(100, look), "under root's login: `login -f $USER` needs no password")
	testing.expect(t, !pid_from_outside(200, look), "reparented")
	testing.expect(t, !pid_from_outside(300, look), "a user-owned login")
	testing.expect(t, pid_from_outside(400, look), "under root's sshd-session")
	testing.expect(t, !pid_from_outside(500, look), "sudo is not a way in")
	testing.expect(t, !pid_via_sshd(100, look), "the hub still needs sshd")
}

// Text from another machine is shown only cleaned: printable, no bidi controls, bounded.
@(test)
hub_text_cleaned :: proc(t: ^testing.T) {
	testing.expect_value(t, hub_from_name("NUC"), "NUC")
	testing.expect_value(t, hub_from_name("evil‮gnp.exe"), "another machine")
	testing.expect_value(t, hub_from_name("a⁦b"), "another machine")
	testing.expect_value(t, hub_from_name("a\u0085b"), "another machine") // C1
	testing.expect_value(t, text_clean("ok \x1b[31mred‮!", 128), "ok ?[31mred?!")
	testing.expect_value(t, text_clean("\xff\xfeab", 128), "??ab")
	long := strings.repeat("é", 100, context.temp_allocator) // 200 bytes
	c := text_clean(long, 64)
	testing.expect(t, len(c) <= 64 && len(c) == 64, "cut at a rune's edge")
	testing.expect_value(t, text_clean("1.2.3", 64), "1.2.3")
}

// A let-go link is drained at most LINGER_READS reads per turn (the main thread is not held).
@(test)
link_linger_bounded :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer posix.close(fds[1])
	for x in fds do posix.fcntl(x, .SETFL, posix.fcntl(x, .GETFL) | posix.O_NONBLOCK)
	buf: [4096]u8
	sent := 0
	for sent < 200 << 10 {
		n := posix.write(fds[1], &buf[0], len(buf))
		if n <= 0 do break
		sent += int(n)
	}
	link_linger_add_for_test(Sock_Fd(fds[0]))
	n0 := link_linger_count()
	testing.expect(t, sent >= 2 * 4096, "the socket holds two reads' worth")
	reads := link_linger_tick(max_reads = 2)
	testing.expect_value(t, reads, 2)
	testing.expect_value(t, link_linger_count(), n0) // more waits, no EOF: still lingering
	link_linger_tick(all = true)
	testing.expect_value(t, link_linger_count(), n0 - 1)
}
} // when TEST_HOOKS
