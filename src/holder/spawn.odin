package holder

// Starting session processes on a PTY (as src/core/pty_posix.odin's pty_spawn does) and the signal
// state the holder and its children start with. The fds inherited at start (cloexec_inherited) and
// the TCC disclaim (macOS) are the OS files' (sys_darwin.odin, sys_linux.odin).

import "core:c"
import "core:fmt"
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

// RLIMIT_NOFILE as the holder was started with (raise_fd_limit raises its own): set again in
// every child before execve.
child_nofile: Rlimit
child_nofile_set: bool

// argv[0] must be an absolute path (no PATH search); env entries are "K=V". The child gets the
// PTY's slave as 0, 1, 2 and is its session leader (forkpty: pgid == pid).
//
// Returns once the child is forked, not once it exec'd: its chdir or execve can block (a hung
// network cwd, a slow first-exec check) and the holder's loop must not. exec_fd (nonblocking,
// close-on-exec) tells how it went: EOF once the exec worked, or the child's errno (spawn_result).
// gate (tests, > 0): the child reads a byte from it before chdir, as if blocked there.
spawn_pty :: proc(argv, env: []string, cwd: string, ws: Winsize, gate: c.int = 0) -> (pid: c.int, master: c.int, exec_fd: c.int, err: string) {
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
		return 0, -1, -1, fmt.tprintf("pipe: errno %d", errno())
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
		return 0, -1, -1, fmt.tprintf("forkpty: errno %d", e)
	}
	if pid == 0 {
		close(exec_pipe[0])
		reset_signals()
		if child_nofile_set do setrlimit(RLIMIT_NOFILE, &child_nofile)
		if gate > 0 {
			b: u8
			read(gate, &b, 1)
		}
		if cwd != "" do chdir(c_cwd)
		execve(c_argv[0], raw_data(c_argv), raw_data(c_env))
		e := errno()
		write(exec_pipe[1], &e, size_of(e))
		_exit(127)
	}
	close(exec_pipe[1])
	set_nonblock(exec_pipe[0])
	set_nonblock(master)
	return pid, master, exec_pipe[0], ""
}

Spawn_Result :: enum {
	Waiting, // nothing yet: the child has not exec'd (or failed) so far
	Exec_Ok,
	Exec_Failed, // child_errno says why
}

// What spawn_pty's exec_fd says now (it is nonblocking).
spawn_result :: proc(exec_fd: c.int) -> (r: Spawn_Result, child_errno: c.int) {
	n := read(exec_fd, &child_errno, size_of(child_errno))
	if n == 0 do return .Exec_Ok, 0
	if n < 0 && (errno() == EAGAIN || errno() == EINTR) do return .Waiting, 0
	if n == size_of(child_errno) do return .Exec_Failed, child_errno
	return .Exec_Failed, n < 0 ? errno() : 0 // a short write: the child died writing it
}

// A waitpid status as an exit code or a signal (WIFEXITED / WIFSIGNALED).
exit_from_wait :: proc(status: c.int) -> (code, signal: i64, ended: bool) {
	low := int(status) & 0x7f
	if low == 0 do return i64((int(status) >> 8) & 0xff), 0, true
	if low != 0x7f do return 0, i64(low), true
	return 0, 0, false // stopped, not ended
}
