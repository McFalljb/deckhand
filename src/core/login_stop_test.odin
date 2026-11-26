#+build darwin
package core

// #204 review, items 1 and 4: a process from another login is stopped by pid and start time alone
// (its binary may be gone: an old version's folder removed), and "gone" is decided by the process
// itself, never by an unreadable path. A holder that outlives the stop keeps its socket.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// A process that ignores SIGTERM, reparented to launchd (a double fork) so it is never our
// zombie: its pid.
@(private = "file")
ls_orphan :: proc(t: ^testing.T) -> i32 {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return 0
	c := posix.fork()
	if c == 0 {
		g := posix.fork()
		if g == 0 {
			posix.close(fds[0])
			posix.close(fds[1])
			argv := []cstring{"/bin/sh", "-c", "trap '' TERM; while :; do sleep 1; done", nil}
			posix.execv("/bin/sh", raw_data(argv))
			posix._exit(127)
		}
		buf := transmute([4]u8)i32(g)
		posix.write(fds[1], &buf[0], 4)
		posix._exit(0)
	}
	posix.close(fds[1])
	buf: [4]u8
	n := posix.read(fds[0], &buf[0], 4)
	posix.close(fds[0])
	st: i32
	posix.waitpid(c, &st, {})
	if n != 4 do return 0
	pid := transmute(i32)buf
	for _ in 0 ..< 100 { // until it runs sh (so its start time is its own)
		if h, ok := lock_proc_ident(pid); ok && h.start != 0 do break
		time.sleep(10 * time.Millisecond)
	}
	return pid
}

@(test)
login_stop_pid_by_start_time :: proc(t: ^testing.T) {
	pid := ls_orphan(t)
	if !testing.expect(t, pid > 0, "the test process") do return
	defer posix.kill(posix.pid_t(pid), .SIGKILL)
	h, ok := lock_proc_ident(pid)
	if !testing.expect(t, ok && h.start != 0) do return
	// another start time: the process we meant is gone (its pid reused), so it counts as stopped
	// and the new process is never signalled
	testing.expect(t, login_stop_pid(pid, h.start + 1, 100 * time.Millisecond), "a reused pid: ours is gone")
	testing.expect(t, posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK, "and the pid's new process still runs")
	// no start time (the process had exited when it was read): gone, nothing signalled
	testing.expect(t, login_stop_pid(pid, 0, 100 * time.Millisecond), "no start time: gone")
	testing.expect(t, posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK, "and nothing was signalled")
	// its own: SIGTERM (ignored), then SIGKILL; gone
	testing.expect(t, login_stop_pid(pid, h.start, 200 * time.Millisecond), "stopped")
	gone := false
	for _ in 0 ..< 100 {
		if gone = posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK; gone do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, gone, "the process is gone")
	// a pid that runs nothing: gone already
	testing.expect(t, login_stop_pid(pid, h.start, 100 * time.Millisecond), "gone counts as stopped")
}

@(private = "file")
ls_stop_fails :: proc(pid: i32, start: i64, wait: time.Duration) -> bool {return false}
@(private = "file")
ls_stop_works :: proc(pid: i32, start: i64, wait: time.Duration) -> bool {return true}

// The holder from another login: its socket goes only once the process is gone.
@(test)
holder_replace_other_login_keeps_a_live_socket :: proc(t: ^testing.T) {
	d := fmt.tprintf("%s/lsr-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(d)
	defer os.remove_all(d)
	sock := fmt.tprintf("%s/holder-0123abcd.sock", d)
	pid := ls_orphan(t)
	if !testing.expect(t, pid > 0) do return
	defer posix.kill(posix.pid_t(pid), .SIGKILL)

	h, hok := lock_proc_ident(pid)
	if !testing.expect(t, hok && h.start != 0) do return
	_ = os.write_entire_file(sock, transmute([]u8)string("x"))
	testing.expect(t, !holder_replace_other_login(pid, h.start, sock, ls_stop_fails), "not replaced: it still runs")
	testing.expect(t, os.exists(sock), "a live holder's socket is never removed")

	testing.expect(t, holder_replace_other_login(pid, h.start, sock, ls_stop_works), "replaced")
	testing.expect(t, !os.exists(sock), "its socket goes with it")

	// the start time read at connect no longer matches (the holder exited and its pid was reused
	// before the signal): the process on that pid now is never signalled (#204 round 2)
	_ = os.write_entire_file(sock, transmute([]u8)string("x"))
	testing.expect(t, holder_replace_other_login(pid, h.start + 1, sock), "a reused pid: the holder is gone")
	testing.expect(t, posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK, "and the pid's new process was not signalled")
	testing.expect(t, !os.exists(sock), "a gone holder's socket is removed")

	// no start time at connect (it had exited): gone, its socket removed, nothing stopped
	_ = os.write_entire_file(sock, transmute([]u8)string("x"))
	testing.expect(t, holder_replace_other_login(pid, 0, sock, ls_stop_fails), "a gone holder counts as replaced")
	testing.expect(t, !os.exists(sock), "a gone holder's socket is removed")
	testing.expect(t, posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK, "nothing was signalled")
}
