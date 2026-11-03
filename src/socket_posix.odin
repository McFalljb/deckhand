#+build darwin, linux
package main

// Control socket, OS side: a Unix domain socket in a per-user 0700
// directory. socket.odin only uses these procs; Windows (named pipes) would
// implement the same set in socket_windows.odin.
//
//   sock_runtime_dir() -> (dir, ok)        the private directory for the socket
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

// PI_DESK_RUNTIME_DIR overrides (tests). macOS: $TMPDIR/pi-desk-<uid> ($TMPDIR
// is already per user). Linux: $XDG_RUNTIME_DIR/pi-desk, else
// /tmp/pi-desk-<uid>. The directory must be ours, a real directory (no
// symlink) and 0700; group/other bits are removed if set.
sock_runtime_dir :: proc(allocator := context.allocator) -> (dir: string, ok: bool) {
	uid := posix.getuid()
	if d := os.get_env("PI_DESK_RUNTIME_DIR", context.temp_allocator); d != "" {
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
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	posix.mkdir(cdir, posix.S_IRWXU) // EEXIST is fine: checked below
	st: posix.stat_t
	if posix.lstat(cdir, &st) != .OK do return dir, false
	if !posix.S_ISDIR(st.st_mode) || st.st_uid != uid do return dir, false
	if st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} {
		if posix.chmod(cdir, posix.S_IRWXU) != .OK do return dir, false
	}
	return dir, true
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
	posix.unlink(cpath) // a stale socket of ours (the name has our pid)
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
	addr, ok := sock_addr(path)
	if !ok do return -1, false
	fd := sock_new()
	if fd < 0 do return -1, false
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
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
