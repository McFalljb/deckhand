#+build darwin, linux
package core

// Control socket, OS side: a Unix domain socket in a per-user 0700
// directory. socket.odin only uses these procs; Windows (named pipes) would
// implement the same set in socket_windows.odin.
//
//   sock_runtime_dir() -> (dir, ok)        the private directory for the sockets (<data>/run)
//   sock_listen(path) -> (fd, ok)          bind + listen (socket file 0600)
//   sock_accept(fd, ms) -> (fd, ok)        waits up to ms for a connection
//   sock_connect(path) -> (fd, ok)
//   sock_wait_readable(fd, ms) -> bool
//   sock_read(fd, buf) -> n                blocking; 0 = closed, -1 = error
//   sock_write_all(fd, data) -> bool       blocking until all is written
//   sock_shutdown(fd)                      wakes a blocked reader/writer
//   sock_close(fd) / sock_unlink(path)

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

Sock_Fd :: posix.FD

// sun_path is 104 bytes, its NUL included
SUN_PATH_MAX :: 103
CORE_SOCK :: "core.sock" // the control socket's name in the runtime dir (stable, docs/PROTOCOL.md §1)
// what the runtime dir must have room for after its path: "/core.sock", and
// "/holder-<rand8>.sock" (a session holder's, src/holder), which the holder's launch checks
RUNTIME_CORE_NEED :: len("/" + CORE_SOCK)
RUNTIME_HOLDER_NEED :: len("/holder-xxxxxxxx.sock")

// The runtime dir (docs/plans/background-core.md §5.1): <data root>/run, the data root being
// home_root (data_dir(), or test mode's build/test-data); not $TMPDIR, which macOS cleans under
// long-lived processes. DECKHAND_RUNTIME_DIR overrides (tests). It must be ours, a real
// directory (no symlink) and 0700 (group/other bits are removed if set), and core.sock's path
// in it must fit in sun_path. why: what is wrong ("" = fine).
sock_runtime_dir :: proc(allocator := context.allocator) -> (dir: string, ok: bool) {
	why: string
	dir, why = sock_runtime_dir_why(allocator)
	return dir, why == ""
}

sock_runtime_dir_why :: proc(allocator := context.allocator) -> (dir, why: string) {
	if d := hook_env(.Runtime_Dir); d != "" {
		dir = strings.clone(d, allocator)
	} else {
		if home_root == "" do return "", "no data dir to keep the runtime dir in"
		os.make_directory_all(home_root, {.Read_User, .Write_User, .Execute_User})
		dir = fmt.aprintf("%s/run", strings.trim_right(home_root, "/"), allocator = allocator)
	}
	return dir, runtime_dir_prepare(dir, RUNTIME_CORE_NEED)
}

// Makes dir (its parent must exist) and checks it as above; need: the longest "/name" that
// goes in it. "" = fine, else why not (temp allocator).
runtime_dir_prepare :: proc(dir: string, need: int) -> string {
	if len(dir) + need > SUN_PATH_MAX {
		return fmt.tprintf("the runtime dir %s is too long: a socket in it would pass %d bytes (sun_path); use a shorter data dir", dir, SUN_PATH_MAX)
	}
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	posix.mkdir(cdir, posix.S_IRWXU) // EEXIST is fine: checked below
	st: posix.stat_t
	if posix.lstat(cdir, &st) != .OK do return fmt.tprintf("the runtime dir %s cannot be made", dir)
	if !posix.S_ISDIR(st.st_mode) do return fmt.tprintf("the runtime dir %s is not a directory (a symlink is refused)", dir)
	if st.st_uid != posix.getuid() do return fmt.tprintf("the runtime dir %s belongs to another user", dir)
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
		if posix.chmod(cdir, posix.S_IRWXU) != .OK do return fmt.tprintf("the runtime dir %s cannot be made private (0700)", dir)
	}
	return ""
}

// The runtime dir of pi-desk 0.1.x and of Deckhand before M1, where instance_guard looks for a
// running pi-desk: DECKHAND_RUNTIME_DIR, else macOS $TMPDIR/pi-desk-<uid> ($TMPDIR is already
// per user), Linux $XDG_RUNTIME_DIR/pi-desk, else /tmp/pi-desk-<uid>. Never made; "" unless it
// is a real directory of ours.
sock_legacy_runtime_dir :: proc(allocator := context.allocator) -> string {
	uid := posix.getuid()
	dir: string
	if d := hook_env(.Runtime_Dir); d != "" {
		dir = strings.clone(d, allocator)
	} else {
		when ODIN_OS == .Darwin {
			base := os.get_env("TMPDIR", context.temp_allocator)
			if base == "" do base = "/tmp"
			dir = fmt.aprintf("%s/pi-desk-%d", strings.trim_right(base, "/"), uid, allocator = allocator)
		} else {
			if x := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); x != "" {
				dir = fmt.aprintf("%s/pi-desk", x, allocator = allocator)
			} else {
				dir = fmt.aprintf("/tmp/pi-desk-%d", uid, allocator = allocator)
			}
		}
	}
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(dir, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) || st.st_uid != uid do return ""
	return dir
}

@(private = "file")
sock_addr :: proc(path: string) -> (addr: posix.sockaddr_un, ok: bool) {
	if len(path) >= len(addr.sun_path) do return {}, false
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) do addr.sun_path[i] = c.char(path[i])
	when ODIN_OS == .Darwin do addr.sun_len = u8(size_of(addr))
	return addr, true
}

@(private = "file")
sock_new :: proc() -> Sock_Fd {
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 do return fd
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC) // never leak into children
	when ODIN_OS == .Darwin {
		one: c.int = 1
		SO_NOSIGPIPE :: 0x1022
		posix.setsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
	return fd
}

sock_listen :: proc(path: string) -> (Sock_Fd, bool) {
	addr, ok := sock_addr(path)
	if !ok do return -1, false
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	posix.unlink(cpath) // a stale socket of ours (core.sock: the core lock makes it ours)
	fd := sock_new()
	if fd < 0 do return -1, false
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 64) != .OK {
		posix.close(fd)
		return -1, false
	}
	posix.chmod(cpath, {.IRUSR, .IWUSR})
	return fd, true
}

sock_accept :: proc(fd: Sock_Fd, timeout_ms: int) -> (Sock_Fd, bool) {
	if !sock_wait_readable(fd, timeout_ms) do return -1, false
	cfd := posix.accept(fd, nil, nil)
	if cfd < 0 do return -1, false
	posix.fcntl(cfd, .SETFD, posix.FD_CLOEXEC)
	when ODIN_OS == .Darwin {
		one: c.int = 1
		SO_NOSIGPIPE :: 0x1022
		posix.setsockopt(cfd, posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
	return cfd, true
}

sock_connect :: proc(path: string) -> (Sock_Fd, bool) {
	fd, ok, _ := sock_connect_why(path)
	return fd, ok
}

// sock_connect, and whether it failed because nobody listens there (ECONNREFUSED: a stale
// socket; ENOENT: gone already).
sock_connect_why :: proc(path: string) -> (fd: Sock_Fd, ok, refused: bool) {
	addr, aok := sock_addr(path)
	if !aok do return -1, false, false
	fd = sock_new()
	if fd < 0 do return -1, false, false
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		e := posix.errno()
		refused = e == .ECONNREFUSED || e == .ENOENT
		posix.close(fd)
		return -1, false, refused
	}
	return fd, true, false
}

sock_wait_readable :: proc(fd: Sock_Fd, timeout_ms: int) -> bool {
	pfd := posix.pollfd{fd = fd, events = {.IN}}
	return posix.poll(&pfd, 1, c.int(timeout_ms)) > 0
}

sock_read :: proc(fd: Sock_Fd, buf: []u8) -> int {
	for {
		n := posix.read(fd, raw_data(buf), len(buf))
		if n < 0 && posix.errno() == .EINTR do continue
		return int(n)
	}
}

sock_write_all :: proc(fd: Sock_Fd, data: []u8) -> bool {
	flags: posix.Msg_Flags
	when ODIN_OS == .Linux do flags = {.NOSIGNAL}
	rest := data
	for len(rest) > 0 {
		n := posix.send(fd, raw_data(rest), len(rest), flags)
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return false
		rest = rest[n:]
	}
	return true
}

sock_shutdown :: proc(fd: Sock_Fd) {posix.shutdown(fd, .RDWR)}
sock_close :: proc(fd: Sock_Fd) {posix.close(fd)}
sock_unlink :: proc(path: string) {posix.unlink(strings.clone_to_cstring(path, context.temp_allocator))}

// The process at the other end of a connected Unix socket (its pid when it connected), and a
// process's parent: what tells Deckhand that a Claude tab's token comes from that tab's own
// processes (socket.odin, socket_claude_peer_ok). 0 = unknown.
when ODIN_OS == .Darwin {
	foreign import sockpeer "system:System"
	@(default_calling_convention = "c")
	foreign sockpeer {
		@(link_name = "getsockopt")
		peer_getsockopt :: proc(fd: c.int, level: c.int, name: c.int, value: rawptr, len: ^u32) -> c.int ---
	}
	SOL_LOCAL :: 0
	LOCAL_PEERPID :: 0x002
	PROC_PIDTBSDINFO :: 3
	PROC_BSDINFO_SIZE :: 136 // struct proc_bsdinfo; pbi_ppid at offset 16

	sock_peer_pid :: proc(fd: Sock_Fd) -> i32 {
		pid: c.int
		n := u32(size_of(pid))
		if peer_getsockopt(c.int(fd), SOL_LOCAL, LOCAL_PEERPID, &pid, &n) != 0 do return 0
		return i32(pid)
	}

	pid_parent :: proc(pid: i32) -> i32 {
		if pid <= 0 do return 0
		buf: [PROC_BSDINFO_SIZE]u8
		if proc_pidinfo(c.int(pid), PROC_PIDTBSDINFO, 0, &buf, size_of(buf)) != size_of(buf) do return 0
		return (^i32)(&buf[16])^
	}

	// window_sock.odin's Proc_Look: pbi_ppid and pbi_uid (offset 20), and proc_pidpath's base name.
	proc_look :: proc(pid: i32) -> (parent: i32, uid: u32, name: string) {
		if pid <= 0 do return 0, 0, ""
		buf: [PROC_BSDINFO_SIZE]u8
		if proc_pidinfo(c.int(pid), PROC_PIDTBSDINFO, 0, &buf, size_of(buf)) != size_of(buf) do return 0, 0, ""
		path: [4096]u8
		n := proc_pidpath(c.int(pid), &path[0], u32(len(path)))
		if n <= 0 do return 0, 0, ""
		full := string(path[:n])
		if i := strings.last_index_byte(full, '/'); i >= 0 do full = full[i + 1:]
		return (^i32)(&buf[16])^, (^u32)(&buf[20])^, strings.clone(full, context.temp_allocator)
	}
} else {
	sock_peer_pid :: proc(fd: Sock_Fd) -> i32 {return 0} // Linux: SO_PEERCRED (later)
	pid_parent :: proc(pid: i32) -> i32 {return 0}
	proc_look :: proc(pid: i32) -> (parent: i32, uid: u32, name: string) {return 0, 0, ""} // Linux: /proc (M6-E); until then no hub gets in
}
