#+build darwin, linux
package main

// The fds a new PTY child inherits: only its terminal (0, 1, 2). Another
// terminal's master, or a job's run lock, held by a later child keeps that
// terminal from hanging up (or the lock from freeing) after Deckhand closes
// its own copy. Real /bin/sh children, no State.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
PT_ENV :: []string{"PATH=/usr/bin:/bin", "LC_ALL=C"}

// Reads p's output until it holds want (or timeout); all of it, temp-allocated.
@(private = "file")
pt_read_until :: proc(p: ^Pty, want: string, timeout: time.Duration) -> string {
	b := strings.builder_make(context.temp_allocator)
	buf: [1024]u8
	deadline := time.tick_now()
	for time.tick_since(deadline) < timeout {
		if pty_wait_readable(p, 50) {
			n := pty_read(p, buf[:])
			if n < 0 do break
			strings.write_bytes(&b, buf[:n])
			if strings.contains(strings.to_string(b), want) do break
		}
	}
	return strings.to_string(b)
}

@(private = "file")
pt_spawn :: proc(t: ^testing.T, script: string) -> Pty {
	p, ok := pty_spawn({"/bin/sh", "-c", script}, "/", PT_ENV, 80, 24)
	testing.expect(t, ok, "pty_spawn")
	return p
}

@(private = "file")
pt_end :: proc(p: ^Pty) {
	pid := p.pid
	if pid > 0 do kill(pid, SIGKILL)
	pty_close(p)
	for _ in 0 ..< 100 {
		pty_reap()
		if !pty_dying(pid) do break
		time.sleep(10 * time.Millisecond)
	}
}

// A shell started after another terminal holds neither that terminal's
// master nor a job's run lock: /dev/fd/N is open in the child only for fds
// it inherited (the shell's -c script opens none of its own).
@(test)
pty_child_holds_no_other_master :: proc(t: ^testing.T) {
	first := pt_spawn(t, "sleep 30")
	defer pt_end(&first)
	dir, _ := os.make_directory_temp("", "ptyfd-*", context.temp_allocator)
	defer os.remove_all(dir)
	lock := run_lock(filepath.join({dir, "run.lock"}, context.temp_allocator) or_else "")
	testing.expect(t, lock >= 0, "run lock")
	defer if lock >= 0 do close(lock)

	script := fmt.tprintf(
		"for n in %d %d; do if [ -e /dev/fd/$n ]; then echo held:$n; else echo free:$n; fi; done; echo done.",
		first.fd, lock,
	)
	second := pt_spawn(t, script)
	defer pt_end(&second)
	out := pt_read_until(&second, "done.", 5 * time.Second)
	testing.expectf(t, strings.contains(out, fmt.tprintf("free:%d", first.fd)), "the first terminal's master (fd %d) leaked into the second shell: %q", first.fd, out)
	testing.expectf(t, strings.contains(out, fmt.tprintf("free:%d", lock)), "a job's run lock (fd %d) leaked into the shell: %q", lock, out)
}

// Closing a tab hangs up its terminal even while a later tab's child is
// alive: a child ignoring SIGHUP still sees its terminal end (read gets EOF
// or EIO once the last master is closed).
@(test)
pty_close_hangs_up_while_another_lives :: proc(t: ^testing.T) {
	dir, _ := os.make_directory_temp("", "ptyhup-*", context.temp_allocator)
	defer os.remove_all(dir)
	marker := filepath.join({dir, "gone"}, context.temp_allocator) or_else ""
	first := pt_spawn(t, fmt.tprintf("trap '' HUP; echo ready; while read x; do :; done; echo gone > '%s'", marker))
	defer pt_end(&first)
	testing.expect(t, strings.contains(pt_read_until(&first, "ready", 5 * time.Second), "ready"), "first shell up")
	second := pt_spawn(t, "sleep 30")
	defer pt_end(&second)

	pid := first.pid
	pty_close(&first) // what closing the tab does: close the master, SIGHUP
	hung_up := false
	for _ in 0 ..< 200 {
		if os.exists(marker) {
			hung_up = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, hung_up, "the closed tab's terminal hung up while the second shell lives")
	if !hung_up do kill(pid, SIGKILL)
}
