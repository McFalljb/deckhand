package core

// Runs a program for the Changes tab (changes.odin) in its own process
// group, so a timeout stops it and everything it started (git, a hook, the
// hook's children): SIGTERM to the group, changes_kill_grace, then SIGKILL
// to the group. Output comes through a pipe and is read while it runs; past
// `cap` bytes the reading stops and the group is stopped (Too_Big). Any
// thread; output in the temp allocator.

import "core:fmt"
import "core:os"
import "core:path/filepath"
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

// More of posix_spawn (app tabs, app_tab.odin; the updater's relaunch, update.odin).
when ODIN_OS == .Darwin {
	foreign import applib "system:System"
	@(default_calling_convention = "c")
	foreign applib {
		posix_spawn_file_actions_addchdir_np :: proc(fa: rawptr, path: cstring) -> posix.Errno ---
		posix_spawn_file_actions_addopen :: proc(fa: rawptr, fd: i32, path: cstring, oflag: i32, mode: u16) -> posix.Errno ---
	}
	POSIX_SPAWN_SETSID :: 0x0400
} else {
	foreign import applib "system:c"
	@(default_calling_convention = "c")
	foreign applib {
		posix_spawn_file_actions_addchdir_np :: proc(fa: rawptr, path: cstring) -> posix.Errno ---
		posix_spawn_file_actions_addopen :: proc(fa: rawptr, fd: i32, path: cstring, oflag: i32, mode: u16) -> posix.Errno ---
	}
	POSIX_SPAWN_SETSID :: 0x0080 // glibc
}

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

// git with Deckhand's read flags (GIT_FLAGS: no hooks, no fsmonitor, no
// optional locks) in dir, through run_group.
git_group :: proc(dir: string, timeout: time.Duration, cap: int, args: ..string) -> (out: string, status: Run_Status) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_group(cmd[:], timeout, cap = cap)
}

GIT_TIMEOUT :: 5 * time.Second

// Every git run: no optional locks, no fsmonitor program, no hooks (a
// repository's hooks are programs we would otherwise start, e.g.
// reference-transaction on git branch -d).
GIT_FLAGS :: [?]string{"git", "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"}

// Runs git in dir (bounded; see the top); stdout on success (temp allocator).
git_run :: proc(dir: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_bounded("", cmd[:], GIT_TIMEOUT)
}

@(private = "file")
run_seq: int // unique output file names (atomic)

// Git with input on stdin (git_run otherwise).
git_run_input :: proc(dir, input: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_bounded("", cmd[:], GIT_TIMEOUT, input)
}

// Runs cmd in dir (""= ours); stdout on exit 0 (temp allocator). Killed at
// the timeout (then not ok). Output (and input, if any) goes through
// temporary files, so a large one never blocks the child on a full pipe.
run_bounded :: proc(dir: string, cmd: []string, timeout: time.Duration, input := "") -> (out: string, ok: bool) {
	o, code, ran := run_bounded_exit(dir, cmd, timeout, input)
	if !ran || code != 0 do return "", false
	return o, true
}

// run_bounded with the exit code: ran = it started, ended within timeout and its output was read
// (code: its exit status, or the signal that ended it); out is read whatever the code.
run_bounded_exit :: proc(dir: string, cmd: []string, timeout: time.Duration, input := "") -> (out: string, code: int, ran: bool) {
	tmpdir := os.get_env("TMPDIR", context.temp_allocator)
	if tmpdir == "" do tmpdir = "/tmp"
	path := fmt.tprintf("%s/deckhand-run-%d-%d.out", strings.trim_right(tmpdir, "/"), os.get_pid(), sync.atomic_add(&run_seq, 1))
	f, ferr := os.open(path, {.Read, .Write, .Create, .Excl}, os.perm_number(0o600))
	if ferr != nil do return "", 0, false
	defer {
		os.close(f)
		os.remove(path)
	}
	stdin: ^os.File
	defer if stdin != nil do os.close(stdin)
	if input != "" {
		ipath := fmt.tprintf("%s.in", path)
		ierr: os.Error
		stdin, ierr = os.open(ipath, {.Read, .Write, .Create, .Excl}, os.perm_number(0o600))
		if ierr != nil do return "", 0, false
		os.remove(ipath) // the open handle keeps it until closed
		if _, werr := os.write_string(stdin, input); werr != nil do return "", 0, false
		if _, serr := os.seek(stdin, 0, .Start); serr != nil do return "", 0, false
	}
	sync.rw_mutex_shared_lock(&fork_lock) // a plain fork (fork_lock, pty.odin)
	p, perr := os.process_start({command = cmd, working_dir = dir, stdout = f, stdin = stdin})
	sync.rw_mutex_shared_unlock(&fork_lock)
	if perr != nil do return "", 0, false
	st, werr := os.process_wait(p, timeout)
	if werr != nil || !st.exited {
		_ = os.process_kill(p)
		_, _ = os.process_wait(p)
		return "", 0, false
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return "", 0, false
	return string(data), st.exit_code, true
}

// The repository root holding path ("" = not in a repository).
git_toplevel :: proc(path: string) -> string {
	out, ok := git_run(filepath.dir(path), "rev-parse", "--show-toplevel")
	if !ok do return ""
	return strings.trim_space(out)
}
