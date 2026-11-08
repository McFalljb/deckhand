package main

// JSON from outside Deckhand must never crash it. core:encoding/json recurses
// per nesting level (100 KB of "[" overflows the stack) and its unquote writes
// 3 bytes per invalid UTF-8 byte into a buffer sized for the input (a bounds
// trap). Each hostile input runs in a forked child, so a crash fails the test
// instead of killing the test runner.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// Runs body in a forked child. ok: the child returned normally (exit 0);
// otherwise why (a signal or an exit code).
@(private = "file")
survives :: proc(body: proc()) -> (ok: bool, why: string) {
	pid := posix.fork()
	if pid == 0 {
		// the test runner's crash handlers wait for a runner thread the child does not have
		for sig in ([]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGTRAP, .SIGABRT, .SIGFPE}) do posix.signal(sig, auto_cast posix.SIG_DFL)
		body()
		posix._exit(0)
	}
	if pid < 0 do return false, "fork failed"
	status: i32
	start := time.tick_now()
	for {
		r := posix.waitpid(pid, &status, {.NOHANG})
		if r == pid do break
		if r < 0 && posix.errno() != .EINTR do return false, "waitpid failed"
		if time.tick_since(start) > 30 * time.Second {
			posix.kill(pid, .SIGKILL)
			posix.waitpid(pid, &status, {})
			return false, "hung (killed after 30 s)"
		}
		time.sleep(5 * time.Millisecond)
	}
	if posix.WIFSIGNALED(status) do return false, fmt.tprintf("killed by signal %d", posix.WTERMSIG(status))
	if posix.WIFEXITED(status) && posix.WEXITSTATUS(status) != 0 do return false, fmt.tprintf("exit %d", posix.WEXITSTATUS(status))
	return true, ""
}

// Hostile lines: deep arrays, deep objects, and strings of invalid UTF-8
// (more than 4 bad bytes, enough to overrun unquote's slack).
HOSTILE_DEEP :: 100_000
@(private = "file")
hostile_deep_array :: proc() -> string {return strings.repeat("[", HOSTILE_DEEP, context.temp_allocator)}
@(private = "file")
hostile_deep_object :: proc() -> string {
	return strings.concatenate({strings.repeat(`{"a":`, HOSTILE_DEEP, context.temp_allocator), "1", strings.repeat("}", HOSTILE_DEEP, context.temp_allocator)}, context.temp_allocator)
}
HOSTILE_BAD_UTF8 :: "\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe"
@(private = "file")
hostile_hello_bad_utf8 :: proc() -> string {
	return strings.concatenate({`{"id":"h","v":1,"type":"hello","token":"`, strings.repeat(HOSTILE_BAD_UTF8, 64, context.temp_allocator), `"}`}, context.temp_allocator)
}

@(test)
json_guard_parse_request_survives_hostile_lines :: proc(t: ^testing.T) {
	ok, why := survives(proc() {
		_, err := parse_request(hostile_deep_array(), context.temp_allocator)
		if err == "" do posix._exit(3)
	})
	testing.expectf(t, ok, "deep array through parse_request: %s", why)
	ok, why = survives(proc() {
		_, err := parse_request(hostile_deep_object(), context.temp_allocator)
		if err == "" do posix._exit(3)
	})
	testing.expectf(t, ok, "deep object through parse_request: %s", why)
	ok, why = survives(proc() {
		_, err := parse_request(hostile_hello_bad_utf8(), context.temp_allocator)
		if err == "" do posix._exit(3)
	})
	testing.expectf(t, ok, "invalid UTF-8 through parse_request: %s", why)
}

// The real entry: a local process connects to the control socket and sends
// one line before hello. Deckhand must answer with an error, not crash.
@(test)
json_guard_socket_survives_hostile_hello :: proc(t: ^testing.T) {
	for line, i in ([]string{hostile_deep_array(), hostile_hello_bad_utf8()}) {
		hostile_line = line
		ok, why := survives(proc() {
			dir := fmt.aprintf("%s/pd-jg-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
			os.set_env("PI_DESK_RUNTIME_DIR", dir)
			rdir, rok := sock_runtime_dir(context.temp_allocator)
			if !rok || !socket_start(rdir) do posix._exit(4)
			fd, cok := sock_connect(socket_path())
			if !cok do posix._exit(5)
			sock_write_all(fd, transmute([]u8)strings.concatenate({hostile_line, "\n"}, context.temp_allocator))
			buf: [dynamic]u8
			start := time.tick_now()
			for strings.index_byte(string(buf[:]), '\n') < 0 {
				if time.tick_since(start) > 5 * time.Second do posix._exit(6)
				if sock_wait_readable(fd, 20) {
					chunk: [4096]u8
					n := sock_read(fd, chunk[:])
					if n <= 0 do posix._exit(7)
					append(&buf, ..chunk[:n])
				}
			}
			reply := string(buf[:strings.index_byte(string(buf[:]), '\n')])
			if json_path(reply, "result.ok") != "false" do posix._exit(8)
		})
		testing.expectf(t, ok, "hostile hello %d through the control socket: %s", i, why)
	}
}

@(private = "file")
hostile_line: string
