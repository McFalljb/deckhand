#+build darwin, linux
package main

import "core:c"
import "core:strings"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
	TIOCSWINSZ :: 0x80087467
	EAGAIN :: 35
	O_NONBLOCK :: 0x0004
} else {
	foreign import libc {"system:c", "system:util"}
	TIOCSWINSZ :: 0x5414
	EAGAIN :: 11
	O_NONBLOCK :: 0o4000
}
F_GETFL :: 3
F_SETFL :: 4
F_SETFD :: 2
FD_CLOEXEC :: 1
SIGKILL :: 9
SIGHUP :: 1
WNOHANG :: 1

Pollfd :: struct {
	fd:      c.int,
	events:  c.short,
	revents: c.short,
}
POLLIN :: 0x1

Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

@(default_calling_convention = "c")
foreign libc {
	forkpty :: proc(amaster: ^c.int, name: [^]u8, termp: rawptr, winp: ^Winsize) -> c.int ---
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
	read :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	write :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	close :: proc(fd: c.int) -> c.int ---
	kill :: proc(pid: c.int, sig: c.int) -> c.int ---
	waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
	chdir :: proc(path: cstring) -> c.int ---
	execve :: proc(path: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int ---
	_exit :: proc(status: c.int) -> ! ---
	poll :: proc(fds: ^Pollfd, nfds: c.uint, timeout: c.int) -> c.int ---
	pipe :: proc(fds: ^[2]c.int) -> c.int ---
	tcgetpgrp :: proc(fd: c.int) -> c.int ---
	__error :: proc() -> ^c.int --- // darwin errno location
}

when ODIN_OS == .Linux {
	@(default_calling_convention = "c")
	foreign libc {
		__errno_location :: proc() -> ^c.int ---
	}
	errno :: proc() -> c.int {return __errno_location()^}
} else {
	errno :: proc() -> c.int {return __error()^}
}

// Children we hung up on but have not reaped yet.
@(private = "file")
dying: [dynamic]i32

// argv[0] must be an absolute path (no PATH search). env entries are "K=V".
pty_spawn :: proc(argv: []string, cwd: string, env: []string, cols, rows: u16) -> (p: Pty, ok: bool) {
	// Everything the child needs is prepared before fork: after fork only
	// async-signal-safe calls (chdir, execve, _exit) are allowed.
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do c_argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	c_env := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env do c_env[i] = strings.clone_to_cstring(e, context.temp_allocator)
	c_cwd := strings.clone_to_cstring(cwd, context.temp_allocator)

	// A close-on-exec pipe tells us whether execve worked: a successful exec
	// closes it (read gets EOF), a failed one writes a byte first.
	exec_pipe: [2]c.int
	if pipe(&exec_pipe) != 0 do return {}, false
	fcntl(exec_pipe[1], F_SETFD, c.int(FD_CLOEXEC))
	ws := Winsize{ws_row = rows, ws_col = cols}
	master: c.int
	pid := forkpty(&master, nil, nil, &ws)
	if pid < 0 {
		close(exec_pipe[0])
		close(exec_pipe[1])
		return {}, false
	}
	if pid == 0 {
		close(exec_pipe[0])
		chdir(c_cwd)
		execve(c_argv[0], raw_data(c_argv), raw_data(c_env))
		failed: u8 = 1
		write(exec_pipe[1], &failed, 1)
		_exit(127)
	}
	close(exec_pipe[1])
	status: u8
	exec_failed := read(exec_pipe[0], &status, 1) == 1
	close(exec_pipe[0])
	if exec_failed {
		close(master)
		st: c.int
		waitpid(pid, &st, 0)
		return {}, false
	}
	flags := fcntl(master, F_GETFL)
	fcntl(master, F_SETFL, flags | O_NONBLOCK)
	return Pty{fd = master, pid = pid}, true
}

// Blocks up to timeout_ms; true when a read will not block (data or hangup).
pty_wait_readable :: proc(p: ^Pty, timeout_ms: int) -> bool {
	pfd := Pollfd{fd = p.fd, events = POLLIN}
	return poll(&pfd, 1, c.int(timeout_ms)) > 0
}

pty_read :: proc(p: ^Pty, buf: []u8) -> int {
	if p.fd < 0 do return -1
	n := read(p.fd, raw_data(buf), len(buf))
	if n > 0 do return int(n)
	if n < 0 && errno() == EAGAIN do return 0
	return -1 // EOF, or EIO once the child side is gone
}

pty_write :: proc(p: ^Pty, data: []u8) {
	if p.fd < 0 do return
	append(&p.pending, ..data)
	pty_flush(p)
}

// Writes as much of the pending output as the pty accepts right now.
pty_flush :: proc(p: ^Pty) {
	for len(p.pending) > 0 {
		n := write(p.fd, raw_data(p.pending), len(p.pending))
		if n <= 0 do return // EAGAIN: retry next frame
		remove_range(&p.pending, 0, int(n))
	}
}

pty_resize :: proc(p: ^Pty, cols, rows: u16, w_px, h_px: u32) {
	if p.fd < 0 do return
	ws := Winsize{ws_row = rows, ws_col = cols, ws_xpixel = u16(min(w_px, 65535)), ws_ypixel = u16(min(h_px, 65535))}
	ioctl(p.fd, TIOCSWINSZ, &ws)
}

pty_close :: proc(p: ^Pty) {
	if p.fd >= 0 do close(p.fd)
	if p.pid > 0 {
		kill(p.pid, SIGHUP)
		append(&dying, p.pid)
	}
	delete(p.pending)
	p^ = Pty{fd = -1}
}

// Whether a child we hung up on is not reaped yet (hot reload waits for it
// before starting pi again on the same session).
pty_dying :: proc(pid: i32) -> bool {
	for d in dying do if d == pid do return true
	return false
}

pty_reap :: proc() {
	for i := len(dying) - 1; i >= 0; i -= 1 {
		status: c.int
		if waitpid(dying[i], &status, WNOHANG) != 0 do unordered_remove(&dying, i)
	}
}

// The terminal's foreground process group differs from the child's own (the
// child is a session leader, so its group id is its pid): a shell is running
// a command. False if unknown.
pty_foreground_busy :: proc(p: ^Pty) -> bool {
	if p.fd < 0 || p.pid <= 0 do return false
	pg := tcgetpgrp(p.fd)
	return pg > 0 && pg != p.pid
}

// The terminal's foreground process group, or 0 if unknown (agent_status.odin:
// a program that reported working leaves the foreground when it exits).
pty_foreground_pgrp :: proc(p: ^Pty) -> i32 {
	if p.fd < 0 || p.pid <= 0 do return 0
	return i32(max(tcgetpgrp(p.fd), 0))
}

// Reaps the child if it has exited (not blocking): how it ended. The pid
// is forgotten then, so closing the pty hangs up nobody.
pty_try_reap :: proc(p: ^Pty) -> (e: Exit_Info, reaped: bool) {
	if p.pid <= 0 do return {}, false
	status: c.int
	r := waitpid(p.pid, &status, WNOHANG)
	if r != p.pid do return {}, false
	p.pid = 0
	return exit_info_from_wait(status), true
}

// A waitpid status as an exit code or a signal (WIFEXITED / WIFSIGNALED;
// the same encoding on macOS and Linux).
exit_info_from_wait :: proc(status: c.int) -> Exit_Info {
	low := int(status) & 0x7f
	if low == 0 do return {known = true, code = (int(status) >> 8) & 0xff}
	if low != 0x7f do return {known = true, signal = low}
	return {} // stopped, not ended
}

// True once the child process has exited (reaps it).
pty_child_exited :: proc(p: ^Pty) -> bool {
	if p.pid <= 0 do return true
	status: c.int
	return waitpid(p.pid, &status, WNOHANG) == p.pid
}

// The child's current directory (a shell after `cd`), or "" if unknown.
// Temp-allocated.
when ODIN_OS == .Darwin {
	foreign import libproc "system:proc"
	@(default_calling_convention = "c")
	foreign libproc {
		proc_pidinfo :: proc(pid: c.int, flavor: c.int, arg: u64, buffer: rawptr, size: c.int) -> c.int ---
		proc_pidpath :: proc(pid: c.int, buffer: rawptr, size: u32) -> c.int ---
	}
	// The executable the child runs now (an `exec` changes it, not the pid), or "". Temp-allocated.
	pty_child_exe :: proc(p: ^Pty) -> string {
		if p.pid <= 0 do return ""
		buf: [4 * MAXPATHLEN]u8 // PROC_PIDPATHINFO_MAXSIZE
		n := proc_pidpath(p.pid, &buf, size_of(buf))
		if n <= 0 do return ""
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
	PROC_PIDVNODEPATHINFO :: 9
	VNODE_INFO_SIZE :: 152 // struct vnode_info; then char vip_path[MAXPATHLEN]
	MAXPATHLEN :: 1024

	pty_child_cwd :: proc(p: ^Pty) -> string {
		if p.pid <= 0 do return ""
		buf: [2 * (VNODE_INFO_SIZE + MAXPATHLEN)]u8 // struct proc_vnodepathinfo: cdir, rdir
		if proc_pidinfo(p.pid, PROC_PIDVNODEPATHINFO, 0, &buf, size_of(buf)) != size_of(buf) do return ""
		path := buf[VNODE_INFO_SIZE:][:MAXPATHLEN]
		n := 0
		for n < len(path) && path[n] != 0 do n += 1
		return strings.clone(string(path[:n]), context.temp_allocator)
	}
} else {
	pty_child_exe :: proc(p: ^Pty) -> string {
		if p.pid <= 0 do return ""
		buf: [4096]u8
		link := strings.clone_to_cstring(fmt_proc_path(p.pid, "exe"), context.temp_allocator)
		n := readlink(link, &buf[0], len(buf))
		if n <= 0 do return ""
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
	@(private = "file")
	fmt_proc_path :: proc(pid: i32, what: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "/proc/")
		strings.write_int(&b, int(pid))
		strings.write_string(&b, "/")
		strings.write_string(&b, what)
		return strings.to_string(b)
	}
	pty_child_cwd :: proc(p: ^Pty) -> string {
		if p.pid <= 0 do return ""
		buf: [4096]u8
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "/proc/")
		strings.write_int(&b, int(p.pid))
		strings.write_string(&b, "/cwd")
		link := strings.to_cstring(&b)
		n := readlink(link, &buf[0], len(buf))
		if n <= 0 do return ""
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
	@(default_calling_convention = "c")
	foreign libc {
		readlink :: proc(path: cstring, buf: [^]u8, size: c.size_t) -> c.ssize_t ---
	}
}
