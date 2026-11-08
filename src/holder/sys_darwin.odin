#+build darwin
package holder

// The libc calls the holder makes, with plain C types (as src/pty_posix.odin declares them),
// and the macOS constants they take.

import "core:c"

foreign import libc "system:System"

TIOCSWINSZ :: 0x80087467
TIOCGWINSZ :: 0x40087468
EAGAIN :: 35
EINTR :: 4
O_NONBLOCK :: 0x0004
O_RDWR :: 0x0002
O_CREAT :: 0x0200
O_NOFOLLOW :: 0x0100
O_CLOEXEC :: 0x01000000
F_GETFL :: 3
F_SETFL :: 4
F_SETFD :: 2
FD_CLOEXEC :: 1
WNOHANG :: 1
LOCK_SH :: 1
LOCK_EX :: 2
LOCK_NB :: 4

SIGHUP :: 1
SIGKILL :: 9
SIGPIPE :: 13
SIGSTOP :: 17
SIGCHLD :: 20
NSIG :: 32
SIG_SETMASK :: 3
SIG_BLOCK :: 1
SA_RESTART :: 0x0002

AF_UNIX :: 1
SOCK_STREAM :: 1
SOL_SOCKET :: 0xffff
SO_NOSIGPIPE :: 0x1022
MSG_NOSIGNAL :: 0x80000
SHUT_WR :: 1

POLLIN :: 0x0001
POLLOUT :: 0x0004
POLLERR :: 0x0008
POLLHUP :: 0x0010
POLLNVAL :: 0x0020

POSIX_SPAWN_SETEXEC :: 0x0040
RTLD_DEFAULT :: rawptr(~uintptr(1)) // (void *)-2

Pollfd :: struct {
	fd:      c.int,
	events:  c.short,
	revents: c.short,
}

Winsize :: struct {
	ws_row, ws_col, ws_xpixel, ws_ypixel: u16,
}

Sockaddr_Un :: struct {
	sun_len:    u8,
	sun_family: u8,
	sun_path:   [104]u8,
}

// struct sigaction (the user-side one: handler, mask, flags)
Sigaction :: struct {
	handler: uintptr, // SIG_DFL 0, SIG_IGN 1, or a proc "c" (c.int)
	mask:    u32,
	flags:   c.int,
}

@(default_calling_convention = "c")
foreign libc {
	forkpty :: proc(amaster: ^c.int, name: [^]u8, termp: rawptr, winp: ^Winsize) -> c.int ---
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	fcntl :: proc(fd: c.int, cmd: c.int, #c_vararg args: ..any) -> c.int ---
	open :: proc(path: cstring, flags: c.int, #c_vararg mode: ..any) -> c.int ---
	read :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	write :: proc(fd: c.int, buf: rawptr, n: c.size_t) -> c.ssize_t ---
	close :: proc(fd: c.int) -> c.int ---
	kill :: proc(pid: c.int, sig: c.int) -> c.int ---
	waitpid :: proc(pid: c.int, status: ^c.int, options: c.int) -> c.int ---
	getpid :: proc() -> c.int ---
	getpgid :: proc(pid: c.int) -> c.int ---
	chdir :: proc(path: cstring) -> c.int ---
	execve :: proc(path: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int ---
	_exit :: proc(status: c.int) -> ! ---
	poll :: proc(fds: [^]Pollfd, nfds: c.uint, timeout: c.int) -> c.int ---
	pipe :: proc(fds: ^[2]c.int) -> c.int ---
	tcgetpgrp :: proc(fd: c.int) -> c.int ---
	flock :: proc(fd: c.int, op: c.int) -> c.int ---
	socket :: proc(domain, type, protocol: c.int) -> c.int ---
	socketpair :: proc(domain, type, protocol: c.int, sv: ^[2]c.int) -> c.int ---
	bind :: proc(fd: c.int, addr: rawptr, len: u32) -> c.int ---
	listen :: proc(fd: c.int, backlog: c.int) -> c.int ---
	accept :: proc(fd: c.int, addr: rawptr, len: ^u32) -> c.int ---
	setsockopt :: proc(fd: c.int, level, name: c.int, value: rawptr, len: u32) -> c.int ---
	send :: proc(fd: c.int, buf: rawptr, n: c.size_t, flags: c.int) -> c.ssize_t ---
	recv :: proc(fd: c.int, buf: rawptr, n: c.size_t, flags: c.int) -> c.ssize_t ---
	@(link_name = "shutdown")
	sock_shutdown :: proc(fd: c.int, how: c.int) -> c.int ---
	unlink :: proc(path: cstring) -> c.int ---
	chmod :: proc(path: cstring, mode: u16) -> c.int ---
	umask :: proc(mask: u16) -> u16 ---
	setenv :: proc(name, value: cstring, overwrite: c.int) -> c.int ---
	sigaction :: proc(sig: c.int, act: ^Sigaction, old: ^Sigaction) -> c.int ---
	sigprocmask :: proc(how: c.int, set: ^u32, old: ^u32) -> c.int ---
	pthread_sigmask :: proc(how: c.int, set: ^u32, old: ^u32) -> c.int ---
	dlsym :: proc(handle: rawptr, name: cstring) -> rawptr ---
	posix_spawn :: proc(pid: ^c.int, path: cstring, file_actions: rawptr, attr: ^rawptr, argv: [^]cstring, envp: [^]cstring) -> c.int ---
	posix_spawnattr_init :: proc(attr: ^rawptr) -> c.int ---
	posix_spawnattr_setflags :: proc(attr: ^rawptr, flags: c.short) -> c.int ---
	posix_spawnattr_destroy :: proc(attr: ^rawptr) -> c.int ---
	_NSGetEnviron :: proc() -> ^[^]cstring ---
	__error :: proc() -> ^c.int ---
}

foreign import libproc "system:proc"
@(default_calling_convention = "c")
foreign libproc {
	proc_pidpath :: proc(pid: c.int, buffer: rawptr, size: u32) -> c.int ---
}

errno :: proc "contextless" () -> c.int {return __error()^}

set_cloexec :: proc(fd: c.int) {fcntl(fd, F_SETFD, c.int(FD_CLOEXEC))}

set_nonblock :: proc(fd: c.int) {
	flags := fcntl(fd, F_GETFL)
	fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

set_nosigpipe :: proc(fd: c.int) {
	one: c.int = 1
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size_of(one))
}
