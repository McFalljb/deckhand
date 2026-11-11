#+build darwin, linux
package core

// #78: children are started with posix_spawn (no atfork handlers in a child that shares our
// flocks), and a refused lock names its holder (lock_holder.odin), which is only ever signalled
// when it is a leftover Deckhand process and still the same process.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

// A job's pi keeps the run lock (spawned with it), the lookup names pi as its holder, and the
// alert's text says so; nothing else signals it.
@(test)
lock_holder_names_spawned_child :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "lockholder-*", context.temp_allocator)
	defer os.remove_all(dir)
	path := filepath.join({dir, INSTANCE_LOCK_FILE}, context.temp_allocator) or_else ""
	r := Job_Run{dir = dir, lock_fd = run_lock(path)}
	if !testing.expect(t, r.lock_fd >= 0, "the lock") do return
	ok := run_spawn(&r, {"/bin/sleep", "30"}, []string{"PATH=/usr/bin:/bin"}, dir, filepath.join({dir, "stderr.log"}, context.temp_allocator) or_else "")
	posix.close(posix.FD(r.lock_fd))
	if !testing.expect(t, ok, "run_spawn") do return
	defer {
		posix.kill(-r.pid, .SIGKILL)
		thread.join(r.th)
		thread.destroy(r.th)
	}
	testing.expect(t, run_lock(path) < 0, "pi keeps the run lock after ours is closed")

	h := lock_holder_find(path)
	testing.expect_value(t, h.pid, i32(r.pid))
	testing.expect_value(t, h.ppid, i32(posix.getpid()))
	testing.expect_value(t, h.others, 0)
	testing.expectf(t, strings.has_suffix(h.exe, "sleep"), "its program: %q", h.exe)
	testing.expect(t, h.start != 0, "its start time")
	_, _, refused := instance_locks_take(dir)
	testing.expect_value(t, refused, Instance_Refusal.Older)
	msg := instance_message(0, refused, instance_holder_of(dir, refused))
	testing.expectf(t, strings.contains(msg, fmt.tprintf("process %d (", r.pid)) && strings.contains(msg, "sleep"), "the alert: %q", msg)
	testing.expect_value(t, lock_holder_find(filepath.join({dir, "none"}, context.temp_allocator) or_else "").pid, i32(0))

	// not a Deckhand executable, and its parent lives: never offered, never signalled
	testing.expect(t, !lock_holder_endable(h), "sleep is not endable")
	testing.expect(t, !lock_holder_end(h, 10 * time.Millisecond), "nor ended")
	// a record that claims a Deckhand leftover at that pid: the re-check finds another process
	fake := h
	fake.ppid, fake.threads, fake.exe = 1, 1, "/Users/me/.Trash/Deckhand.app/Contents/MacOS/Deckhand"
	testing.expect(t, !lock_holder_same(fake), "not the same process")
	_ = lock_holder_end(fake, 10 * time.Millisecond)
	for bad in ([]i32{0, 1, -1, -i32(r.pid)}) {
		b := fake
		b.pid = bad
		testing.expectf(t, !lock_holder_endable(b), "pid %d", bad)
		testing.expectf(t, !lock_holder_end(b, 10 * time.Millisecond), "pid %d", bad)
	}
	st: i32
	testing.expect_value(t, posix.waitpid(r.pid, &st, {.NOHANG}), posix.pid_t(0)) // still running
	testing.expect(t, posix.kill(r.pid, posix.Signal(0)) == .OK, "still running")
}

@(test)
lock_exe_deckhand_paths :: proc(t: ^testing.T) {
	yes := []string{
		"/Applications/Deckhand.app/Contents/MacOS/Deckhand",
		"/Users/me/.Trash/Deckhand 10.41.22.app/Contents/MacOS/Deckhand",
		"/Applications/pi-desk.app/Contents/MacOS/pi-desk",
		"/Applications/Deckhand.app/Contents/Helpers/Deckhand Core.app/Contents/MacOS/deckhand-core-serve",
	}
	no := []string{
		"/bin/sleep",
		"/Applications/Deckhand.app/Contents/Helpers/Deckhand Core.app/Contents/MacOS/deckhand-core", // the session holder
		"/Applications/Other.app/Contents/MacOS/Deckhand",
		"/tmp/Deckhand.app/Deckhand",
		"/tmp/Deckhand",
		"",
	}
	for p in yes do testing.expectf(t, lock_exe_deckhand(p), "%q", p)
	for p in no do testing.expectf(t, !lock_exe_deckhand(p), "%q", p)
}

// Changes' and git's runs (run_bounded_exit, posix_spawn): its folder, its input on stdin, its
// output and exit code; killed at the timeout.
@(test)
run_bounded_exit_spawns :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "runbounded-*", context.temp_allocator)
	defer os.remove_all(dir)
	real, _ := filepath.abs(dir, context.temp_allocator)
	out, code, ran := run_bounded_exit(dir, {"sh", "-c", "pwd -P; cat; echo err >&2; exit 3"}, 5 * time.Second, "the input\n")
	testing.expect(t, ran, "ran")
	testing.expect_value(t, code, 3)
	lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	testing.expectf(t, len(lines) == 2 && strings.has_suffix(lines[0], filepath.base(real)) && lines[1] == "the input", "out: %q", out)
	start := time.tick_now()
	_, _, ran = run_bounded_exit("", {"sleep", "5"}, 100 * time.Millisecond)
	testing.expect(t, !ran, "timed out")
	testing.expect(t, time.tick_since(start) < 2 * time.Second, "killed at the timeout")
	_, _, ran = run_bounded_exit("", {"/nonexistent/deckhand-test"}, time.Second)
	testing.expect(t, !ran, "a missing program does not run")
}
