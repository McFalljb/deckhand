#+build linux
package holder

// The libc calls the holder makes on Linux (glibc), under the names and plain C types
// sys_darwin.odin gives them, and the Linux constants they take (docs/plans/background-core.md
// §10.4 M6-L3). The rest of the package is the same on both: a poll(2) loop with a SIGCHLD
// self-pipe, forkpty, waitpid, the upgrade's keeper. What differs is here:
// - sigaction and the signal masks: the shared code passes macOS's shapes (a 32-bit mask), and
//   the wrappers below turn them into glibc's (a 1024-bit sigset_t), so no caller reads past a u32;
// - every fd the holder inherited is made close-on-exec with close_range (fallback /proc/self/fd);
// - no TCC disclaim (a macOS notion);
// - orphans (the sessions a keeper adopts after a failed upgrade, not its children) are watched
//   with pidfds in an epoll set: their exits are seen, but a non-child's wait status cannot be
//   read on Linux, so their codes are unknown (-1; macOS reads them with NOTE_EXITSTATUS);
// - SO_PEERCRED is fixed when a socket is made, not live as LOCAL_PEERTOKEN is: the upgrade's
//   handoff reads its peer with SCM_CREDENTIALS on the hello instead (handoff_hello_peer), and a
//   keeper that adopts listens again (relisten), so a core's SO_PEERCRED names the keeper.

import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../trust"

foreign import libc {"system:c", "system:util"} // forkpty: libutil before glibc 2.34

TIOCSWINSZ :: 0x5414
TIOCGWINSZ :: 0x5413
EAGAIN :: 11
EINTR :: 4
EMFILE :: 24
ENFILE :: 23
ENOSYS :: 38
O_NONBLOCK :: 0o4000
O_RDONLY :: 0
O_RDWR :: 0o2
O_CREAT :: 0o100
O_CLOEXEC :: 0o2000000
when ODIN_ARCH == .arm64 {
	O_NOFOLLOW :: 0o100000
} else {
	O_NOFOLLOW :: 0o400000
}
F_GETFL :: 3
F_SETFL :: 4
F_GETFD :: 1
F_SETFD :: 2
FD_CLOEXEC :: 1
WNOHANG :: 1
LOCK_SH :: 1
LOCK_EX :: 2
LOCK_NB :: 4

SIGHUP :: 1
SIGKILL :: 9
SIGUSR2 :: 12
SIGPIPE :: 13
SIGCHLD :: 17
SIGSTOP :: 19
NSIG :: 65 // glibc's _NSIG: 1..64 (32 and 33 are glibc's own: sigaction refuses them)
SIG_BLOCK :: 0
SIG_SETMASK :: 2
SA_RESTART :: 0x10000000

AF_UNIX :: 1
SOCK_STREAM :: 1
SOL_SOCKET :: 1
SO_PASSCRED :: 16
SCM_RIGHTS :: 1
SCM_CREDENTIALS :: 2
MSG_NOSIGNAL :: 0x4000
SHUT_WR :: 1

POLLIN :: 0x0001
POLLOUT :: 0x0004
POLLERR :: 0x0008
POLLHUP :: 0x0010
POLLNVAL :: 0x0020

ESRCH :: 3
ECHILD :: 10

RLIMIT_NOFILE :: 7
OPEN_MAX :: 1 << 16 // the soft limit raise_fd_limit raises to at most (the hard one may be far higher)

SYS_pidfd_open :: 434 // x86_64 and aarch64 (asm-generic)
SYS_close_range :: 436
CLOSE_RANGE_CLOEXEC :: 1 << 2
EPOLL_CLOEXEC :: 0o2000000
EPOLL_CTL_ADD :: 1
EPOLLIN :: 0x001

// what the supervisor opens the core's log with (supervisor.odin)
SUP_O_WRONLY :: 0o1
SUP_O_APPEND :: 0o2000

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
	sun_family: u16,
	sun_path:   [108]u8,
}

Iovec :: struct {
	base: rawptr,
	len:  c.size_t,
}

Msghdr :: struct {
	name:       rawptr,
	namelen:    u32,
	iov:        ^Iovec,
	iovlen:     c.size_t,
	control:    rawptr,
	controllen: c.size_t,
	flags:      c.int,
}

// struct cmsghdr; its data starts 8-aligned right after it (16 bytes) on 64-bit Linux
Cmsghdr :: struct {
	len:   c.size_t,
	level: c.int,
	type:  c.int,
}

// The shape the shared code fills (sys_darwin.odin's): a handler, a 32-bit mask and the flags.
// sigaction below turns it into glibc's.
Sigaction :: struct {
	handler: uintptr, // SIG_DFL 0, SIG_IGN 1, or a proc "c" (c.int)
	mask:    u32,
	flags:   c.int,
}

@(private = "file")
Sigset :: struct {
	val: [16]u64, // glibc's sigset_t: 1024 bits
}

@(private = "file")
Glibc_Sigaction :: struct {
	handler:  uintptr,
	mask:     Sigset,
	flags:    c.int,
	restorer: rawptr,
}

when ODIN_ARCH == .amd64 {
	@(private = "file")
	Epoll_Event :: struct #packed {
		events: u32,
		data:   u64,
	}
} else {
	@(private = "file")
	Epoll_Event :: struct {
		events: u32,
		data:   u64,
	}
}

@(private = "file")
Ucred :: struct {
	pid:      i32,
	uid, gid: u32,
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
	getppid :: proc() -> c.int ---
	getpgid :: proc(pid: c.int) -> c.int ---
	chdir :: proc(path: cstring) -> c.int ---
	execve :: proc(path: cstring, argv: [^]cstring, envp: [^]cstring) -> c.int ---
	_exit :: proc(status: c.int) -> ! ---
	poll :: proc(fds: [^]Pollfd, nfds: c.ulong, timeout: c.int) -> c.int ---
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
	chmod :: proc(path: cstring, mode: u32) -> c.int ---
	umask :: proc(mask: u32) -> u32 ---
	setenv :: proc(name, value: cstring, overwrite: c.int) -> c.int ---
	sendmsg :: proc(fd: c.int, msg: ^Msghdr, flags: c.int) -> c.ssize_t ---
	recvmsg :: proc(fd: c.int, msg: ^Msghdr, flags: c.int) -> c.ssize_t ---
	__errno_location :: proc() -> ^c.int ---
	getrlimit :: proc(resource: c.int, rlp: ^Rlimit) -> c.int ---
	setrlimit :: proc(resource: c.int, rlp: ^Rlimit) -> c.int ---
	syscall :: proc(number: c.long, #c_vararg args: ..any) -> c.long ---
	epoll_create1 :: proc(flags: c.int) -> c.int ---
	epoll_ctl :: proc(epfd: c.int, op: c.int, fd: c.int, event: ^Epoll_Event) -> c.int ---
	epoll_wait :: proc(epfd: c.int, events: [^]Epoll_Event, maxevents: c.int, timeout: c.int) -> c.int ---
	@(link_name = "sigaction")
	glibc_sigaction :: proc(sig: c.int, act: ^Glibc_Sigaction, old: ^Glibc_Sigaction) -> c.int ---
	@(link_name = "sigprocmask")
	glibc_sigprocmask :: proc(how: c.int, set: ^Sigset, old: ^Sigset) -> c.int ---
	@(link_name = "pthread_sigmask")
	glibc_pthread_sigmask :: proc(how: c.int, set: ^Sigset, old: ^Sigset) -> c.int ---
}

__error :: proc "contextless" () -> ^c.int {return __errno_location()}

errno :: proc "contextless" () -> c.int {return __errno_location()^}

// The environment execve passes on (macOS's _NSGetEnviron, by its name there).
_NSGetEnviron :: proc "contextless" () -> ^[^]cstring {return &posix.environ}

// ---- signals: macOS's shapes in, glibc's out (async-signal-safe: the child calls them) ----

// The 32-bit mask's signals (bit n-1 = signal n) as a sigset_t, and back.
@(private = "file")
sigset_of :: proc "contextless" (m: u32) -> Sigset {
	s: Sigset
	s.val[0] = u64(m)
	return s
}

sigaction :: proc "contextless" (sig: c.int, act: ^Sigaction, old: ^Sigaction) -> c.int {
	g, o: Glibc_Sigaction
	gp: ^Glibc_Sigaction
	if act != nil {
		g = {handler = act.handler, mask = sigset_of(act.mask), flags = act.flags}
		gp = &g
	}
	r := glibc_sigaction(sig, gp, old != nil ? &o : nil)
	if r == 0 && old != nil do old^ = {handler = o.handler, mask = u32(o.mask.val[0]), flags = o.flags}
	return r
}

// SIG_SETMASK with a u32 sets every signal above 32 unblocked: the masks the holder sets are
// empty (reset_signals) or saved ones put back.
sigprocmask :: proc "contextless" (how: c.int, set: ^u32, old: ^u32) -> c.int {
	s, o: Sigset
	sp: ^Sigset
	if set != nil {
		s = sigset_of(set^)
		sp = &s
	}
	r := glibc_sigprocmask(how, sp, old != nil ? &o : nil)
	if r == 0 && old != nil do old^ = u32(o.val[0])
	return r
}

pthread_sigmask :: proc "contextless" (how: c.int, set: ^u32, old: ^u32) -> c.int {
	s, o: Sigset
	sp: ^Sigset
	if set != nil {
		s = sigset_of(set^)
		sp = &s
	}
	r := glibc_pthread_sigmask(how, sp, old != nil ? &o : nil)
	if r == 0 && old != nil do old^ = u32(o.val[0])
	return r
}

// ---- fds ----

set_cloexec :: proc(fd: c.int) {fcntl(fd, F_SETFD, c.int(FD_CLOEXEC))}

// The one fd an exec'd image is meant to inherit (an upgrade's socketpair end).
clear_cloexec :: proc "contextless" (fd: c.int) {fcntl(fd, F_SETFD, c.int(0))}

is_cloexec :: proc(fd: c.int) -> bool {return fcntl(fd, F_GETFD) & FD_CLOEXEC != 0}

set_nonblock :: proc(fd: c.int) {
	flags := fcntl(fd, F_GETFL)
	fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}

// Linux has no SO_NOSIGPIPE: every send passes MSG_NOSIGNAL, and the holder's own writes to a
// socket go through send.
set_nosigpipe :: proc(fd: c.int) {}

// Every fd above 2 this process has made close-on-exec (as spawn.odin's macOS loop does): one a
// launcher leaked to us never reaches a session. close_range (Linux 5.11); before it, the fds
// /proc/self/fd lists.
cloexec_inherited :: proc() {
	if syscall(SYS_close_range, c.uint(3), ~c.uint(0), c.uint(CLOSE_RANGE_CLOEXEC)) == 0 do return
	dir := posix.opendir("/proc/self/fd")
	if dir == nil do return
	defer posix.closedir(dir)
	own := c.int(posix.dirfd(dir))
	for {
		e := posix.readdir(dir)
		if e == nil do break
		name := string(cstring(&e.d_name[0]))
		n, ok := strconv.parse_int(name, 10)
		if !ok || n < 3 || c.int(n) == own do continue
		fd := c.int(n)
		flags := fcntl(fd, F_GETFD)
		if flags >= 0 && flags & FD_CLOEXEC == 0 do fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
	}
}

// TCC is macOS's: nothing to disclaim.
disclaim_responsibility :: proc() {}

// ---- the upgrade's handoff (keeper.odin) ----

// The giver's end of a handoff socketpair: every message the taker writes carries its live
// credentials (SCM_CREDENTIALS), so the hello names the process that wrote it, as LOCAL_PEERTOKEN
// does on macOS. Before the fork, so the taker can never write without them.
handoff_giver_prepare :: proc(fd: c.int) -> bool {
	one: c.int = 1
	return setsockopt(fd, SOL_SOCKET, SO_PASSCRED, &one, size_of(one)) == 0
}

// The taker's 8-byte hello into b, and the process that wrote it, from the kernel's credentials
// on each message (every part must carry the same ones). tok carries its pid, for
// trust.code_identity_of_token. ok false: short, no credentials, or two writers.
handoff_hello_peer :: proc(fd: c.int, b: []u8, deadline: time.Tick) -> (peer: trust.Peer, tok: trust.Audit_Token, ok: bool) {
	got := 0
	for got < len(b) {
		if !wait_fd(fd, POLLIN, deadline) do return {}, {}, false
		ctl: [8]u64 // a cmsghdr and a ucred, 8-aligned
		rest := len(b) - got
		iov := Iovec{&b[got], c.size_t(rest)}
		msg := Msghdr{iov = &iov, iovlen = 1, control = &ctl[0], controllen = size_of(ctl)}
		n := recvmsg(fd, &msg, 0)
		if n < 0 && (errno() == EINTR || errno() == EAGAIN) do continue
		if n <= 0 || msg.flags != 0 do return {}, {}, false
		cm := (^Cmsghdr)(&ctl[0])
		if msg.controllen < size_of(Cmsghdr) + size_of(Ucred) || cm.level != SOL_SOCKET || cm.type != SCM_CREDENTIALS || cm.len < size_of(Cmsghdr) + size_of(Ucred) {
			return {}, {}, false
		}
		cr := (^Ucred)(uintptr(&ctl[0]) + size_of(Cmsghdr))^
		if cr.pid <= 0 || (got > 0 && (cr.pid != peer.pid || cr.uid != peer.euid)) do return {}, {}, false
		peer = trust.Peer{ok = true, pid = cr.pid, euid = cr.uid}
		got += int(n)
	}
	tok.val[5] = u32(peer.pid)
	return peer, tok, true
}

// SO_PEERCRED names whoever last called listen() on a socket: a keeper that serves the old
// holder's listener listens again, so a core that connects reads the keeper's pid, the one its
// WELCOME says (trust.welcome_peer_ok).
relisten :: proc(h: ^Holder) {
	if h.listen_fd >= 0 && listen(h.listen_fd, 16) != 0 do hlog(h, "listen again: errno %d", errno())
}

// The keeper may SIGKILL the holder's pid only while it is still the image it checked. Linux has
// no pidversion: it is still our parent (the keeper is the old image's fork) and so not a reused pid.
keeper_parent_is :: proc(holder_pid: i32) -> bool {return getppid() == c.int(holder_pid)}

// The keeper, for the new image to reap (upgrade.odin's resume). SO_PEERCRED on a socketpair
// names its maker (the old image: this pid), never the keeper, so the old image puts the pid it
// forked on our argv (`--keeper`, resume_keeper). 0: none given.
handoff_keeper_pid :: proc(h: ^Holder, fd: c.int) -> c.int {return resume_keeper}

// Reaps every child of ours that has ended and is untracked: one the old image left before an
// upgrade's exec (a launcher of its supervisor). Sessions (the loop reads their status for
// EXITED), the keeper (keeper_pid) and the supervisor's launchers (sup_launchers) are reaped by
// their own paths, which clear their tracking: never here, so no stale tracker can later take a
// reused pid's status. WNOHANG: a child still running is left alone. /proc unreadable: nothing.
reap_strays :: proc(h: ^Holder) {
	// this thread's children (the holder forks from its one thread; Linux 3.17+)
	b, err := os.read_entire_file("/proc/thread-self/children", context.temp_allocator)
	if err != nil do return
	outer: for f in strings.fields(string(b), context.temp_allocator) {
		n, ok := strconv.parse_int(f, 10)
		if !ok || n <= 0 do continue
		for t in h.terms do if c.int(n) == t.pid do continue outer
		if c.int(n) == h.keeper_pid do continue
		for l in h.sup_launchers do if c.int(n) == l do continue outer
		st: c.int
		waitpid(c.int(n), &st, WNOHANG)
	}
}

// ---- orphans (keeper.odin) ----

// Tests make pidfd_open fail with this errno (an old kernel, seccomp); 0 otherwise, always.
test_pidfd_errno: c.int

@(private = "file")
pidfd_open :: proc(pid: c.int) -> c.int {
	if test_pidfd_errno != 0 {
		__errno_location()^ = test_pidfd_errno
		return -1
	}
	return c.int(syscall(SYS_pidfd_open, pid, c.uint(0)))
}

// The orphans with no pidfd (orphans_watch), on the loop's timers: ended once the pid is gone, a
// zombie (dead, its new parent has not reaped it), or another process (a different start time).
// A /proc it can't read leaves it running: a live orphan is never marked ended.
orphans_poll :: proc(h: ^Holder) {
	for t in h.terms {
		if !t.orphan || !t.polled || t.reaped do continue
		if kill(t.pid, 0) != 0 && errno() == ESRCH {
			orphan_ended(t, -1, false)
			continue
		}
		state, start, ok := proc_stat(t.pid)
		if !ok do continue
		if state == "Z" || state == "X" || (t.start_time != 0 && start != t.start_time) do orphan_ended(t, -1, false)
	}
}

// /proc/<pid>/stat's state (field 3) and start time (field 22), read after the last ')' (comm may
// hold one). ok false: unreadable.
@(private = "file")
proc_stat :: proc(pid: c.int) -> (state: string, start: u64, ok: bool) {
	b, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil do return "", 0, false
	s := string(b)
	i := strings.last_index_byte(s, ')')
	if i < 0 do return "", 0, false
	f := strings.fields(s[i + 1:], context.temp_allocator)
	if len(f) < 20 do return "", 0, false
	start, ok = strconv.parse_u64(f[19], 10)
	return f[0], start, ok
}

@(private = "file")
proc_start_time :: proc(pid: c.int) -> u64 {
	_, start, ok := proc_stat(pid)
	return ok ? start : 0
}

// Watches every orphan that still runs: a pidfd each, in an epoll set (h.kq; made on first use)
// whose events carry the pidfd and the pid. One that is gone already ended unseen.
orphans_watch :: proc(h: ^Holder) {
	for t in h.terms {
		if !t.orphan || t.reaped do continue
		if h.kq < 0 {
			h.kq = epoll_create1(EPOLL_CLOEXEC)
			if h.kq < 0 {
				hlog(h, "epoll: errno %d: orphans' exits are unknown", errno())
				return
			}
		}
		pfd := pidfd_open(t.pid)
		if pfd < 0 {
			if e := errno(); e != ESRCH {
				// no pidfd (ENOSYS: before Linux 5.3; EPERM: seccomp; EMFILE): never taken for gone,
				// its liveness is polled instead (orphans_poll)
				t.polled, t.start_time = true, proc_start_time(t.pid)
				hlog(h, "terminal %d: no pidfd for pid %d (errno %d): its exit is polled", t.id, t.pid, e)
				continue
			}
			hlog(h, "terminal %d: pid %d is gone already: exit unknown", t.id, t.pid)
			orphan_ended(t, -1, false)
			continue
		}
		set_cloexec(pfd)
		ev := Epoll_Event{events = EPOLLIN, data = u64(u32(pfd)) | u64(u32(t.pid)) << 32}
		if epoll_ctl(h.kq, EPOLL_CTL_ADD, pfd, &ev) != 0 {
			hlog(h, "terminal %d: cannot watch pid %d (errno %d): exit unknown", t.id, t.pid, errno())
			close(pfd)
			orphan_ended(t, -1, false)
		}
	}
}

// The epoll set is readable: the orphans that exited. Their wait status is not ours to read (they
// are not our children): unknown.
orphans_read :: proc(h: ^Holder) {
	evs: [32]Epoll_Event
	for {
		n := epoll_wait(h.kq, &evs[0], len(evs), 0)
		if n <= 0 do return
		for ev in evs[:n] {
			pfd, pid := c.int(u32(ev.data)), c.int(u32(ev.data >> 32))
			for t in h.terms do if t.orphan && !t.reaped && t.pid == pid do orphan_ended(t, -1, false)
			close(pfd) // leaves the set with it
		}
		if int(n) < len(evs) do return
	}
}
