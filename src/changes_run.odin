package main

// Runs a program for the Changes tab (changes.odin) in its own process
// group, so a timeout stops it and everything it started (git, a hook, the
// hook's children): SIGTERM to the group, changes_kill_grace, then SIGKILL
// to the group. Output comes through a pipe and is read while it runs; past
// `cap` bytes the reading stops and the group is stopped (Too_Big). Any
// thread; output in the temp allocator.

import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

when ODIN_OS == .Darwin {
	foreign import spawnlib "system:System.framework"
} else {
	foreign import spawnlib "system:c"
}

@(default_calling_convention = "c")
foreign spawnlib {
	posix_spawnattr_init :: proc(attr: rawptr) -> posix.Errno ---
	posix_spawnattr_destroy :: proc(attr: rawptr) -> posix.Errno ---
	posix_spawnattr_setflags :: proc(attr: rawptr, flags: i16) -> posix.Errno ---
	posix_spawnattr_setpgroup :: proc(attr: rawptr, pgroup: posix.pid_t) -> posix.Errno ---
	posix_spawn_file_actions_init :: proc(fa: rawptr) -> posix.Errno ---
	posix_spawn_file_actions_destroy :: proc(fa: rawptr) -> posix.Errno ---
	posix_spawn_file_actions_adddup2 :: proc(fa: rawptr, fd, newfd: i32) -> posix.Errno ---
}

POSIX_SPAWN_SETPGROUP :: 0x02 // macOS and glibc
// macOS: the child gets only the descriptors the file actions give it (0, 1, 2)
when ODIN_OS == .Darwin {
	POSIX_SPAWN_CLOEXEC_DEFAULT :: 0x4000
} else {
	POSIX_SPAWN_CLOEXEC_DEFAULT :: 0
}

@(private = "file")
cloexec :: proc(fd: posix.FD) {if fd >= 0 do posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC))}

Run_Status :: enum u8 {
	Ok, // exit 0
	Failed, // another exit status (or a signal)
	Timed_Out,
	Too_Big, // output past cap
	Start_Failed,
}

// Grace between SIGTERM and SIGKILL to a timed-out group (tests shorten it).
changes_kill_grace := 2 * time.Second

// argv[0] is looked up on PATH. stderr goes to the output with
// merge_stderr, else nowhere.
run_group :: proc(argv: []string, timeout: time.Duration, input := "", cap := 64 << 20, merge_stderr := false) -> (out: string, status: Run_Status) {
	// everything the child needs, before it starts
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	pipe_out: [2]posix.FD
	if posix.pipe(&pipe_out) != .OK do return "", .Start_Failed
	defer posix.close(pipe_out[0])
	// stdin: the input from a pipe (written below; small) or /dev/null
	pipe_in: [2]posix.FD = {-1, -1}
	null_fd := posix.open("/dev/null", {.RDWR, .CLOEXEC})
	defer if null_fd >= 0 do posix.close(null_fd)
	if input != "" && posix.pipe(&pipe_in) != .OK {
		posix.close(pipe_out[1])
		return "", .Start_Failed
	}
	// our ends never reach the child: it must see EOF on stdin when we close ours
	for fd in ([4]posix.FD{pipe_out[0], pipe_out[1], pipe_in[0], pipe_in[1]}) do cloexec(fd)
	attr, fa: [512]u8 // opaque (a pointer on macOS, a struct elsewhere)
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawnattr_setpgroup(&attr, 0) // its own group, led by itself
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(input != "" ? pipe_in[0] : null_fd), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(pipe_out[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(merge_stderr ? pipe_out[1] : null_fd), 2)
	pid: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock) // fork_lock, pty.odin
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(pipe_out[1])
	if input != "" do posix.close(pipe_in[0])
	if err != .NONE {
		if input != "" do posix.close(pipe_in[1])
		return "", .Start_Failed
	}
	if input != "" {
		// a commit message: far below a pipe's buffer
		_ = posix.write(pipe_in[1], raw_data(input), uint(len(input)))
		posix.close(pipe_in[1])
	}
	b := strings.builder_make(context.temp_allocator)
	deadline := time.tick_now()._nsec + i64(timeout)
	buf: [16 << 10]u8
	open := true
	exited := false
	wstatus: i32
	status = .Ok
	for {
		if open {
			pfd := [1]posix.pollfd{{fd = pipe_out[0], events = {.IN}}}
			if posix.poll(&pfd[0], 1, 50) > 0 {
				n := posix.read(pipe_out[0], &buf[0], len(buf))
				if n <= 0 {
					open = false
				} else {
					room := cap - strings.builder_len(b)
					strings.write_bytes(&b, buf[:min(int(n), max(room, 0))])
					if int(n) > room {
						status = .Too_Big
						break
					}
				}
			}
		} else {
			time.sleep(20 * time.Millisecond)
		}
		if !exited && posix.waitpid(pid, &wstatus, {.NOHANG}) == pid do exited = true
		if exited && !open do break
		if time.tick_now()._nsec > deadline {
			status = .Timed_Out
			break
		}
	}
	if status == .Too_Big || status == .Timed_Out {
		// the group: git and whatever it started
		posix.killpg(pid, .SIGTERM)
		grace_end := time.tick_now()._nsec + i64(changes_kill_grace)
		for !exited && time.tick_now()._nsec < grace_end {
			if posix.waitpid(pid, &wstatus, {.NOHANG}) == pid do exited = true
			else do time.sleep(20 * time.Millisecond)
		}
		posix.killpg(pid, .SIGKILL) // the rest of the group (hooks that ignore TERM)
		if !exited do posix.waitpid(pid, &wstatus, {})
		return strings.to_string(b), status
	}
	if !(posix.WIFEXITED(wstatus) && posix.WEXITSTATUS(wstatus) == 0) do status = .Failed
	return strings.to_string(b), status
}

// git with pi-desk's read flags (GIT_FLAGS: no hooks, no fsmonitor, no
// optional locks) in dir, through run_group.
git_group :: proc(dir: string, timeout: time.Duration, cap: int, args: ..string) -> (out: string, status: Run_Status) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_group(cmd[:], timeout, cap = cap)
}
