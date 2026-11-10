#+build darwin
package holder

// The libc calls the holder makes, with plain C types (as src/core/pty_posix.odin declares them),
// and the macOS constants they take.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../trust"

foreign import libc "system:System"

TIOCSWINSZ :: 0x80087467
TIOCGWINSZ :: 0x40087468
EAGAIN :: 35
EINTR :: 4
EMFILE :: 24
ENFILE :: 23
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

ESRCH :: 3
ECHILD :: 10
SCM_RIGHTS :: 1
F_GETFD :: 1
EVFILT_PROC :: -5
EV_ADD :: 0x0001
EV_ONESHOT :: 0x0010
EV_ERROR :: 0x4000
NOTE_EXIT :: 0x80000000
NOTE_EXITSTATUS :: 0x04000000
SIGUSR2 :: 31

POSIX_SPAWN_SETEXEC :: 0x0040
RTLD_DEFAULT :: rawptr(~uintptr(1)) // (void *)-2

RLIMIT_NOFILE :: 8
OPEN_MAX :: 10240

Rlimit :: struct {
	cur, max: u64,
}

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

Iovec :: struct {
	base: rawptr,
	len:  c.size_t,
}

Msghdr :: struct {
	name:       rawptr,
	namelen:    u32,
	iov:        ^Iovec,
	iovlen:     c.int,
	control:    rawptr,
	controllen: u32,
	flags:      c.int,
}

// struct cmsghdr; its data starts 4-aligned right after it (12 bytes) on Darwin
Cmsghdr :: struct {
	len:   u32,
	level: c.int,
	type:  c.int,
}

// struct kevent (64-bit Darwin)
Kevent :: struct {
	ident:  uintptr,
	filter: i16,
	flags:  u16,
	fflags: u32,
	data:   int,
	udata:  rawptr,
}

Timespec :: struct {
	sec:  int,
	nsec: int,
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
	dup :: proc(fd: c.int) -> c.int ---
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
	sendmsg :: proc(fd: c.int, msg: ^Msghdr, flags: c.int) -> c.ssize_t ---
	recvmsg :: proc(fd: c.int, msg: ^Msghdr, flags: c.int) -> c.ssize_t ---
	kqueue :: proc() -> c.int ---
	kevent :: proc(kq: c.int, changes: [^]Kevent, nchanges: c.int, events: [^]Kevent, nevents: c.int, timeout: ^Timespec) -> c.int ---

	__error :: proc() -> ^c.int ---
	getrlimit :: proc(resource: c.int, rlp: ^Rlimit) -> c.int ---
	setrlimit :: proc(resource: c.int, rlp: ^Rlimit) -> c.int ---
}

foreign import libproc "system:proc"
@(default_calling_convention = "c")
foreign libproc {
	proc_pidpath :: proc(pid: c.int, buffer: rawptr, size: u32) -> c.int ---
	proc_pidinfo :: proc(pid: c.int, flavor: c.int, arg: u64, buffer: rawptr, size: c.int) -> c.int ---
}

errno :: proc "contextless" () -> c.int {return __error()^}

set_cloexec :: proc(fd: c.int) {fcntl(fd, F_SETFD, c.int(FD_CLOEXEC))}

// The one fd an exec'd image is meant to inherit (an upgrade's socketpair end).
clear_cloexec :: proc "contextless" (fd: c.int) {fcntl(fd, F_SETFD, c.int(0))}

is_cloexec :: proc(fd: c.int) -> bool {return fcntl(fd, F_GETFD) & FD_CLOEXEC != 0}

set_nonblock :: proc(fd: c.int) {
	flags := fcntl(fd, F_GETFL)
	fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

set_nosigpipe :: proc(fd: c.int) {
	one: c.int = 1
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size_of(one))
}

SUP_O_WRONLY :: 0x0001 // what the supervisor opens the core's log with (supervisor.odin)
SUP_O_APPEND :: 0x0008

// Every fd above 2 this process has made close-on-exec: one a launcher leaked to us (a shell, a
// CI runner, a direct start that did not use POSIX_SPAWN_CLOEXEC_DEFAULT) never reaches a
// session. At start, before any fd of the holder's own is open (theirs are close-on-exec).
cloexec_inherited :: proc() {
	F_GETFD :: 1
	rl: Rlimit
	top := c.int(OPEN_MAX)
	if getrlimit(RLIMIT_NOFILE, &rl) == 0 do top = c.int(min(max(rl.cur, rl.max), OPEN_MAX)) // above the soft limit too
	for fd in c.int(3) ..< top {
		flags := fcntl(fd, F_GETFD)
		if flags >= 0 && flags & FD_CLOEXEC == 0 do fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
	}
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
	if os.get_env(RESPONSIBLE_ENV, context.temp_allocator) == pid_str { // env-read-ok: a constant: the TCC re-exec marker
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

// ---- the upgrade's handoff (keeper.odin) ----

// The giver's end of a handoff socketpair: nothing to set (LOCAL_PEERTOKEN is live).
handoff_giver_prepare :: proc(fd: c.int) -> bool {return true}

// The taker's 8-byte hello into b, and the process that wrote it: the peer's live audit token,
// read with the bytes in hand (the token is the process that wrote them).
handoff_hello_peer :: proc(fd: c.int, b: []u8, deadline: time.Tick) -> (peer: trust.Peer, tok: trust.Audit_Token, ok: bool) {
	if !recv_all_by(fd, b, deadline) do return {}, {}, false
	peer, tok = trust.peer_read_token(posix.FD(fd))
	return peer, tok, peer.ok
}

// LOCAL_PEERTOKEN is live: a core reads the keeper's pid without it.
relisten :: proc(h: ^Holder) {}

// ---- orphans (keeper.odin) ----

// Linux's fallback for an orphan with no pidfd: never needed here (kqueue).
orphans_poll :: proc(h: ^Holder) {}

// Registers every orphan that still runs with the kqueue (made on first use). One that is gone
// already ended unseen: its exit is unknown (code -1).
orphans_watch :: proc(h: ^Holder) {
	for t in h.terms {
		if !t.orphan || t.reaped do continue
		if h.kq < 0 {
			sync_lock()
			h.kq = kqueue()
			if h.kq >= 0 do set_cloexec(h.kq)
			sync_unlock()
			if h.kq < 0 {
				hlog(h, "kqueue: errno %d: orphans' exits are unknown", errno())
				return
			}
		}
		ev := Kevent{ident = uintptr(t.pid), filter = EVFILT_PROC, flags = EV_ADD | EV_ONESHOT, fflags = NOTE_EXIT | NOTE_EXITSTATUS}
		if kevent(h.kq, &ev, 1, nil, 0, nil) != 0 {
			hlog(h, "terminal %d: pid %d is gone already (errno %d): exit unknown", t.id, t.pid, errno())
			orphan_ended(t, -1, false)
		}
	}
}

// The kqueue is readable: the orphans that exited, with their wait status.
orphans_read :: proc(h: ^Holder) {
	evs: [32]Kevent
	zero := Timespec{}
	for {
		n := kevent(h.kq, nil, 0, &evs[0], len(evs), &zero)
		if n <= 0 do return
		for ev in evs[:n] {
			if ev.filter != EVFILT_PROC || ev.fflags & NOTE_EXIT == 0 do continue
			for t in h.terms do if t.orphan && !t.reaped && uintptr(t.pid) == ev.ident {
				orphan_ended(t, ev.data, ev.fflags & NOTE_EXITSTATUS != 0)
			}
		}
		if int(n) < len(evs) do return
	}
}

// The keeper at the other end of the new image's handoff socket (upgrade.odin's resume): its live
// token's pid. 0 = unknown.
handoff_keeper_pid :: proc(h: ^Holder, fd: c.int) -> c.int {
	kp := trust.peer_read(posix.FD(fd))
	return kp.ok ? c.int(kp.pid) : 0
}
