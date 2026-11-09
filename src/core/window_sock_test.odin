package core

// The window's door over core.sock and its side of it (window_sock.odin; §10.3 M4-C), with fake
// identities: the "peers" are this test binary, over a socketpair.

import "core:os"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

import cw "../corewire"
import "../trust"

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
	testing.expect(t, strings.has_prefix(why, "the process on core.sock is not Deckhand's core"), why)
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
