#+build darwin
package holder

// Starting session processes on a PTY (as src/pty_posix.odin's pty_spawn does), the signal
// state the holder and its children start with, and the TCC disclaim at start.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"

// No fork while an fd that is not close-on-exec yet is open: the holder is single-threaded,
// but the unit tests run several holders (and their socketpairs) on threads of one process.
fork_lock: sync.Mutex

// Every signal back to its default and nothing blocked. Inherited SIG_IGN survives exec (a
// launcher that ignored SIGPIPE would hand that to every shell), so the holder resets itself at
// start and every child resets again before execve. Async-signal-safe: the child calls it
// after fork.
reset_signals :: proc "contextless" () {
	dfl := Sigaction{}
	for sig in c.int(1) ..< NSIG {
		if sig == SIGKILL || sig == SIGSTOP do continue
		sigaction(sig, &dfl, nil)
	}
	empty: u32
	sigprocmask(SIG_SETMASK, &empty, nil)
}

// argv[0] must be an absolute path (no PATH search); env entries are "K=V". The child gets the
// PTY's slave as 0, 1, 2 and is its session leader (forkpty: pgid == pid).
spawn_pty :: proc(argv, env: []string, cwd: string, ws: Winsize) -> (pid: c.int, master: c.int, err: string) {
	// Everything the child needs is prepared before fork: after fork only async-signal-safe
	// calls (sigaction, sigprocmask, chdir, execve, write, _exit).
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do c_argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	c_env := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env do c_env[i] = strings.clone_to_cstring(e, context.temp_allocator)
	c_cwd := strings.clone_to_cstring(cwd, context.temp_allocator)
	ws := ws

	// A close-on-exec pipe tells whether execve worked: a successful exec closes it (read gets
	// EOF), a failed one writes errno first.
	exec_pipe: [2]c.int
	sync.mutex_lock(&fork_lock)
	if pipe(&exec_pipe) != 0 {
		sync.mutex_unlock(&fork_lock)
		return 0, -1, fmt.tprintf("pipe: errno %d", errno())
	}
	set_cloexec(exec_pipe[0])
	set_cloexec(exec_pipe[1])
	pid = forkpty(&master, nil, nil, &ws)
	// The master is close-on-exec: another terminal's child must not hold it, or RELEASE
	// would not hang this one up.
	if pid > 0 do set_cloexec(master)
	if pid != 0 do sync.mutex_unlock(&fork_lock)
	if pid < 0 {
		e := errno()
		close(exec_pipe[0])
		close(exec_pipe[1])
		return 0, -1, fmt.tprintf("forkpty: errno %d", e)
	}
	if pid == 0 {
		close(exec_pipe[0])
		reset_signals()
		if cwd != "" do chdir(c_cwd)
		execve(c_argv[0], raw_data(c_argv), raw_data(c_env))
		e := errno()
		write(exec_pipe[1], &e, size_of(e))
		_exit(127)
	}
	close(exec_pipe[1])
	child_errno: c.int
	exec_failed := read(exec_pipe[0], &child_errno, size_of(child_errno)) == size_of(child_errno)
	close(exec_pipe[0])
	if exec_failed {
		close(master)
		st: c.int
		waitpid(pid, &st, 0)
		return 0, -1, fmt.tprintf("exec %s: errno %d", argv[0], child_errno)
	}
	set_nonblock(master)
	return pid, master, ""
}

// A waitpid status as an exit code or a signal (WIFEXITED / WIFSIGNALED).
exit_from_wait :: proc(status: c.int) -> (code, signal: i64, ended: bool) {
	low := int(status) & 0x7f
	if low == 0 do return i64((int(status) >> 8) & 0xff), 0, true
	if low != 0x7f do return 0, i64(low), true
	return 0, 0, false // stopped, not ended
}

RESPONSIBLE_ENV :: "_DECKHAND_RESPONSIBLE"

// §5.7, S2: the holder is TCC-responsible for itself (and so for its children), not Deckhand.app
// or launchd's job. Re-execs this binary in place (POSIX_SPAWN_SETEXEC keeps the pid) with the
// disclaim attribute, marking the environment with our pid so the new image knows it is done.
// Returns only when there is nothing to do or the re-exec failed (logged; the holder carries on).
disclaim_responsibility :: proc() {
	own := getpid()
	buf: [16]u8
	pid_str := strconv.write_int(buf[:], i64(own), 10)
	if os.get_env(RESPONSIBLE_ENV, context.temp_allocator) == pid_str {
		log_line("TCC: responsible for itself (disclaimed)")
		return
	}
	fnp := dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim")
	if fnp == nil {
		log_line("TCC disclaim unavailable (no responsibility_spawnattrs_setdisclaim): carrying on")
		return
	}
	setdisclaim := cast(proc "c" (attr: ^rawptr, disclaim: c.int) -> c.int)fnp
	path_buf: [4096]u8
	n := proc_pidpath(own, &path_buf, size_of(path_buf))
	if n <= 0 {
		log_line("TCC disclaim: no executable path: carrying on")
		return
	}
	path := strings.clone_to_cstring(string(path_buf[:n]), context.temp_allocator)
	setenv(RESPONSIBLE_ENV, strings.clone_to_cstring(pid_str, context.temp_allocator), 1)
	attr: rawptr
	posix_spawnattr_init(&attr)
	posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC)
	setdisclaim(&attr, 1)
	c_argv := make([]cstring, len(os.args) + 1, context.temp_allocator)
	for a, i in os.args do c_argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	r := posix_spawn(nil, path, nil, &attr, raw_data(c_argv), _NSGetEnviron()^)
	posix_spawnattr_destroy(&attr)
	log_line(fmt.tprintf("TCC disclaim: re-exec failed (%d): carrying on", r))
}
