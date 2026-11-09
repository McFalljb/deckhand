package holder

// The holder's half of the ready handshake (detach.odin) over a socketpair, the launcher's
// bytes written ahead. The launchd path itself is src/core/launchd_test.odin's.

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:sync"
import "core:testing"
import "core:time"

@(private = "file")
pair :: proc(t: ^testing.T) -> (holder, launcher: posix.FD) {
	fds: [2]posix.FD
	// close-on-exec before a sibling test's spawn can fork (child_holds_only_stdio)
	sync.mutex_lock(&fork_lock)
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, nil, &fds) == .OK, "socketpair")
	for fd in fds do set_cloexec(c.int(fd))
	sync.mutex_unlock(&fork_lock)
	ready_nosigpipe(fds[0]) // as ready_connect's socket: a gone launcher is EPIPE, not SIGPIPE
	return fds[0], fds[1]
}

@(private = "file")
read_all_now :: proc(fd: posix.FD) -> string {
	buf: [256]u8
	pfd := Pollfd{fd = c.int(fd), events = POLLIN}
	if poll(&pfd, 1, 1000) <= 0 do return ""
	n := read(c.int(fd), &buf[0], len(buf))
	return n > 0 ? strings.clone(string(buf[:n]), context.temp_allocator) : ""
}

@(test)
ready_exchange_env :: proc(t: ^testing.T) {
	h, l := pair(t)
	defer posix.close(h)
	defer posix.close(l)
	sent := "A=1\x00PATH=/usr/bin:/bin\x00EMPTY=\x00WITH=eq=uals\x00\x00"
	write(c.int(l), raw_data(sent), len(sent))
	env, ok := ready_exchange(h, time.Second)
	defer {
		for e in env do delete(e)
		delete(env)
	}
	testing.expect(t, ok)
	testing.expect_value(t, len(env), 4)
	if len(env) == 4 {
		testing.expect_value(t, env[0], "A=1")
		testing.expect_value(t, env[2], "EMPTY=")
		testing.expect_value(t, env[3], "WITH=eq=uals")
	}
	testing.expect_value(t, read_all_now(l), fmt.tprintf("%d\n", posix.getpid())) // our pid first
}

@(test)
ready_exchange_empty_env :: proc(t: ^testing.T) {
	h, l := pair(t)
	defer posix.close(h)
	defer posix.close(l)
	write(c.int(l), raw_data(string("\x00")), 1)
	env, ok := ready_exchange(h, time.Second)
	defer delete(env)
	testing.expect(t, ok)
	testing.expect_value(t, len(env), 0)
}

// A launcher that dies mid-environment, or never sends it: a failure, never a hang or SIGPIPE.
@(test)
ready_exchange_fails_closed :: proc(t: ^testing.T) {
	{
		h, l := pair(t)
		part := "A=1\x00B="
		write(c.int(l), raw_data(part), len(part))
		posix.close(l)
		_, ok := ready_exchange(h, time.Second)
		testing.expect(t, !ok, "closed mid-environment")
		posix.close(h)
	}
	{
		h, l := pair(t)
		t0 := time.tick_now()
		_, ok := ready_exchange(h, 100 * time.Millisecond)
		testing.expect(t, !ok, "nothing sent")
		testing.expect(t, time.tick_since(t0) < 2 * time.Second, "timed out promptly")
		posix.close(l)
		posix.close(h)
	}
	{
		h, l := pair(t)
		posix.close(l) // gone before our pid
		_, ok := ready_exchange(h, time.Second)
		testing.expect(t, !ok, "the launcher left before our pid")
		posix.close(h)
	}
}
