package holder

// The session holder (docs/plans/background-core.md §3, §5.6, §5.7, §7.2): one poll() loop
// that owns PTY masters and their children, counts every byte each terminal prints (its
// offset), keeps the last TAIL_CAP of them, and relays them to at most one attached core.
//
// What a core can rely on:
// - WELCOME, then one TAIL{start} per terminal WELCOME lists (in that order; possibly empty
//   bytes; start = offset - len(tail)), then live OUTPUT from that offset on, contiguous per
//   terminal.
// - EXITED{offset} follows every OUTPUT up to offset, once the master hit EOF and the child
//   was reaped (or exit_grace after the reap if the master stays open). A terminal that ended
//   while no core was attached is listed with `exit` in the next WELCOME instead and gets no
//   EXITED. Ended terminals stay until RELEASE.
// - GOODBYE_ACK follows every OUTPUT up to each acked offset; nothing is sent after it. The
//   connection then stays open until the core closes it (at most LINGER): a peer that closed its
//   end can no longer be read (LOCAL_PEERTOKEN fails), and the core checks it on the ack.
// - On Linux (M6-L3, sys_linux.odin) the same, with SO_PEERCRED: the peer is the same user only
//   (§8.3), read at accept; there is no live token to read again, so peer_still holds by
//   construction.
// - The HMAC key is in WELCOME and nowhere else.

import "core:c"
import "core:encoding/hex"
import "core:fmt"
import "core:crypto"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "../holderwire"
import "../trust"

// The holder's revision, in WELCOME. Bump it (by hand) whenever the holder's code changes: src/holder,
// src/holderwire or src/trust outside tests. scripts/check-holder-rev.sh fails CI otherwise, and
// checks src/core/holder_install.odin's HOLDER_REV (the app's copy) matches. A core upgrades a holder
// whose holder_rev is older than its own (UPGRADE, §7.3).
HOLDER_REV :: 6
TAIL_CAP :: 1024 * 1024 // per terminal (§3)
QUEUE_CAP :: 8 * 1024 * 1024 // per core: past this, masters are not read (§5.6)
QUEUE_CAP_INPUT :: 8 * 1024 * 1024 // per terminal: INPUT the program has not taken
INPUT_STALL :: 2 * time.Second // the app's writes time out after 5 s (holder_client.odin)
IDLE_EXIT :: 10 * time.Second
MAX_COLS :: holderwire.MAX_COLS // the grid limits (PR A); SPAWN/RESIZE outside 1..max are refused
MAX_ROWS :: holderwire.MAX_ROWS
READ_CHUNK :: 64 * 1024
MAX_PENDING :: 8 // connections that have not said HELLO yet
SPAWN_TIMEOUT :: 10 * time.Second // the app gives up (and RELEASEs) sooner; this is the backstop
HELLO_TIMEOUT :: 5 * time.Second // from accept: a connection that has not said HELLO is dropped
LINGER :: 5 * time.Second // after GOODBYE_ACK: how long the core may take to close
ACCEPT_BACKOFF :: 100 * time.Millisecond // out of fds: the listener is left out of poll this long

Config :: struct {
	run_dir:       string, // "": no listening socket (tests hand fds to holder_attach)
	data_dir:      string, // "": no instance.lock (tests)
	pong_timeout:  time.Duration, // a core silent this long is dropped
	idle_exit:     time.Duration, // no core and no running terminal this long: exit
	exit_grace:    time.Duration, // EXITED this long after the reap even if the master stays open
	reap_interval: time.Duration, // how often to try waitpid while a child runs (SIGCHLD wakes us sooner)
	shutdown_wait: time.Duration, // GOODBYE{shutdown}: how long to reap before exiting
	successor_ttl: time.Duration, // GOODBYE{handover, successor}: how long its secret is valid
	tail_cap:      int,
	queue_cap:     int,
	quiet:         bool, // no log lines (tests)
	spawn_timeout: time.Duration, // a SPAWN whose child has not exec'd by then fails
	input_cap:     int, // INPUT queued for one terminal past this: the core's connection is not read
	input_stall:   time.Duration, // ... for at most this long; then that queue is dropped
	hello_timeout: time.Duration, // a connection that has not said HELLO by then is dropped
	test_accept_errno: c.int, // tests: != 0, accept() fails with it
	test_spawn_gate: c.int, // tests: > 0, a child reads one byte from it before its exec
	window_ids:    []string, // who may send SUPERVISE as a window (trust.WINDOW_IDS; tests their own)
}

@(private = "file")
window_ids_default := trust.WINDOW_IDS

default_config :: proc() -> Config {
	return Config {
		pong_timeout = holderwire.PONG_TIMEOUT,
		idle_exit = IDLE_EXIT,
		window_ids = window_ids_default[:],
		exit_grace = 500 * time.Millisecond,
		reap_interval = time.Second,
		shutdown_wait = time.Second,
		successor_ttl = holderwire.SUCCESSOR_TTL,
		tail_cap = TAIL_CAP,
		queue_cap = QUEUE_CAP,
		spawn_timeout = SPAWN_TIMEOUT,
		hello_timeout = HELLO_TIMEOUT,
		input_cap = QUEUE_CAP_INPUT,
		input_stall = INPUT_STALL,
	}
}

Term :: struct {
	id:                         u32,
	master:                     c.int, // -1 once closed (RELEASE, shutdown)
	pid:                        c.int, // the child; stays set after the reap (reaped says so)
	pgid:                       c.int,
	cols, rows, xpixel, ypixel: u16,
	offset:                     u64, // bytes read from the master so far
	tail:                       Ring,
	input:                      [dynamic]u8, // INPUT the master has not taken yet
	eof:                        bool, // the master read EOF or EIO
	reaped:                     bool,
	exit:                       holderwire.Exit_Status,
	reaped_at:                  time.Tick,
	final:                      bool, // the exit is reported (EXITED, or `exit` in WELCOME)
	released:                   bool, // forgotten once reaped
	// forked but not exec'd yet (spawn_pty): exec_fd says when. Not listed in WELCOME nor acked,
	// its master not read, until SPAWNED (sent only to the core that asked, `requester`).
	pending:                    bool,
	exec_fd:                    c.int,
	spawned_at:                 time.Tick,
	requester:                  u64, // the asking connection's serial
	orphan:                     bool, // not our child (adopted by an upgrade's keeper): its exit comes from orphans_read
	polled:                     bool, // Linux: an orphan with no pidfd: orphans_poll checks it is still that process
	start_time:                 u64, // Linux: its start time (/proc/<pid>/stat), against pid reuse
}

Conn :: struct {
	fd:            c.int,
	peer:          trust.Peer, // as read at accept
	rx:            holderwire.Stream,
	out:           [dynamic]u8,
	out_head:      int,
	last_rx:       time.Tick,
	accepted_at:   time.Tick,
	welcomed:      bool,
	wire:          i64, // the wire WELCOME agreed on
	closing:       bool, // send what is queued, then close (REFUSED, GOODBYE_ACK)
	linger:        bool, // closing after GOODBYE_ACK: once sent, wait for the core's EOF (or LINGER)
	closing_since: time.Tick,
	dead:          bool,
	serial:        u64, // this connection's number (a freed Conn's address may come back)
	secret_out:    bool, // out held a successor secret (GOODBYE_ACK): zeroed when freed
	supervised:    bool, // this core said SUPERVISE{core}: a separate core the supervisor watches
}

Holder :: struct {
	cfg:               Config,
	instance:          string, // random id of this run (hex)
	key:               [32]u8, // the HMAC key (§5.3 B3): memory only, sent in WELCOME only
	listen_fd:         c.int,
	sock_path:         string,
	lock_fd:           c.int,
	wake_fd:           c.int, // SIGCHLD self-pipe's read end, or -1
	kq:                c.int, // watching orphans' exits (macOS: a kqueue, NOTE_EXITSTATUS; Linux: an epoll set of pidfds), or -1
	upgrade_error:     string, // the keeper adopted the terminals: why the new image did not get them (WELCOME)
	can_upgrade:       bool, // the holder binary (never an in-process test holder): UPGRADE may exec
	keeper_pid:        c.int, // after an upgrade: the keeper (our child) until it is reaped, else 0
	terms:             [dynamic]^Term,
	conns:             [dynamic]^Conn,
	core:              ^Conn, // the attached (WELCOMEd) core, or nil
	previous:          string, // none | handover | crash, for the next WELCOME
	successor:         string, // the named successor's secret (hex; "" = none): only its HELLO is welcomed
	successor_until:   time.Tick, // ...until then (or until it is used)
	idle:              bool,
	idle_since:        time.Tick,
	shutting_down:     bool,
	shutdown_deadline: time.Tick,
	done:              bool, // the loop should end; exit_code says how
	exit_code:         int,
	buf:               []u8,
	serials:           u64,
	input_paused:      bool, // a terminal has input_cap of INPUT queued: the core is not read
	input_paused_at:   time.Tick,
	logged:            int, // log lines so far (tests)
	listen_paused:     bool, // accept failed for want of fds (EMFILE, ENFILE): back off
	accept_logged:     bool, // that was logged; again only after an accept worked
	listen_paused_at:  time.Tick,
	owns_dirs:         bool, // cfg.run_dir and data_dir are ours to free (state_decode)
	sup:               Supervisor, // a separate core's crashes and relaunches (supervisor.odin)
	sup_launchers:     [dynamic]c.int, // supervisor launches' `<serve> launch` until reaped
	forked:            bool, // a keeper serving (a fork that never exec'd): no Security.framework, so no supervisor
}

Start_Error :: enum {
	None,
	Run_Dir, // missing, not a real directory, not ours or not 0700
	Listen, // the socket could not be made
	Lock, // instance.lock could not be opened
	Lock_Busy, // an older Deckhand holds instance.lock exclusively
}

log_line :: proc(msg: string) {
	fmt.eprintf("deckhand-core[%d]: %s\n", getpid(), msg)
}

hlog :: proc(h: ^Holder, format: string, args: ..any) {
	h.logged += 1 // tests count them (quiet or not)
	if h.cfg.quiet do return
	log_line(fmt.tprintf(format, ..args))
}

// A holder. With cfg.run_dir it listens on <run>/holder-<rand8>.sock; with cfg.data_dir it holds
// <data>/instance.lock shared. On an error nothing is left open (and the result is nil).
holder_new :: proc(cfg: Config) -> (h: ^Holder, err: Start_Error) {
	h = holder_alloc(cfg)

	if cfg.data_dir != "" {
		path := strings.clone_to_cstring(fmt.tprintf("%s/instance.lock", cfg.data_dir), context.temp_allocator)
		h.lock_fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, c.uint(0o600))
		if h.lock_fd < 0 {
			hlog(h, "cannot open %s: errno %d", path, errno())
			holder_free(h)
			return nil, .Lock
		}
		if flock(h.lock_fd, LOCK_SH | LOCK_NB) != 0 {
			hlog(h, "instance.lock is held exclusively (an older Deckhand is running)")
			holder_free(h)
			return nil, .Lock_Busy
		}
	}
	if cfg.run_dir != "" {
		if why := run_dir_problem(cfg.run_dir); why != "" {
			hlog(h, "refusing run dir %s: %s", cfg.run_dir, why)
			holder_free(h)
			return nil, .Run_Dir
		}
		if !holder_listen(h) {
			holder_free(h)
			return nil, .Listen
		}
	}
	return h, .None
}

// A holder with nothing open: a fresh key and instance id (state_decode replaces both).
holder_alloc :: proc(cfg: Config) -> ^Holder {
	h := new(Holder)
	h.cfg = cfg
	h.cfg.tail_cap = min(cfg.tail_cap, holderwire.MAX_OUTPUT_CHUNK) // one TAIL frame per terminal
	h.listen_fd, h.lock_fd, h.wake_fd, h.kq = -1, -1, -1, -1
	h.previous = "none"
	h.buf = make([]u8, READ_CHUNK)
	crypto.rand_bytes(h.key[:])
	id: [8]u8
	crypto.rand_bytes(id[:])
	h.instance = string(hex.encode(id[:]))
	h.idle, h.idle_since = true, time.tick_now()
	return h
}

// Why the run dir is not safe to put the socket in ("" if it is): it must be a real directory
// (not a link), owned by us, 0700.
run_dir_problem :: proc(dir: string) -> string {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(dir, context.temp_allocator), &st) != .OK do return "missing"
	if !posix.S_ISDIR(st.st_mode) do return "not a directory"
	if u32(st.st_uid) != trust.own_uid() do return "not owned by us"
	if st.st_mode & {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH} != posix.S_IRWXU do return "not mode 0700"
	return ""
}

@(private)
holder_listen :: proc(h: ^Holder) -> bool {
	r: [4]u8
	crypto.rand_bytes(r[:])
	h.sock_path = fmt.aprintf("%s/holder-%s.sock", h.cfg.run_dir, string(hex.encode(r[:], context.temp_allocator)))
	addr := Sockaddr_Un{sun_family = AF_UNIX}
	if len(h.sock_path) >= len(addr.sun_path) {
		hlog(h, "socket path too long (%d bytes): %s", len(h.sock_path), h.sock_path)
		return false
	}
	copy(addr.sun_path[:], h.sock_path)
	when ODIN_OS == .Darwin do addr.sun_len = size_of(addr)
	sync_lock()
	h.listen_fd = socket(AF_UNIX, SOCK_STREAM, 0)
	if h.listen_fd >= 0 do set_cloexec(h.listen_fd)
	sync_unlock()
	if h.listen_fd < 0 {
		hlog(h, "socket: errno %d", errno())
		return false
	}
	set_nonblock(h.listen_fd)
	old := umask(0o177)
	ok := bind(h.listen_fd, &addr, size_of(addr)) == 0
	umask(old)
	if !ok {
		hlog(h, "bind %s: errno %d", h.sock_path, errno())
		delete(h.sock_path)
		h.sock_path = ""
		return false
	}
	chmod(strings.clone_to_cstring(h.sock_path, context.temp_allocator), 0o600)
	if listen(h.listen_fd, 16) != 0 {
		hlog(h, "listen: errno %d", errno())
		return false
	}
	hlog(h, "listening on %s (instance %s)", h.sock_path, h.instance)
	return true
}

// The socket goes as soon as the holder is on its way out (a shutdown that reaps, an idle exit):
// a core that connects then is refused at once rather than left waiting in an unpolled backlog.
@(private)
stop_listening :: proc(h: ^Holder) {
	if h.listen_fd >= 0 do close(h.listen_fd)
	h.listen_fd = -1
	if h.sock_path != "" {
		unlink(strings.clone_to_cstring(h.sock_path, context.temp_allocator))
		delete(h.sock_path)
		h.sock_path = ""
	}
}

@(private)
sync_lock :: proc() {sync.mutex_lock(&fork_lock)}
@(private)
sync_unlock :: proc() {sync.mutex_unlock(&fork_lock)}

// Ends the holder's resources. kill_children (tests): SIGKILL and reap every child still
// running, so no test leaves processes behind. The holder binary leaves them (they were hung up).
holder_free :: proc(h: ^Holder, kill_children := false) {
	if h == nil do return
	successor_clear(h)
	for cn in h.conns do conn_free(cn)
	delete(h.conns)
	for t in h.terms {
		if t.master >= 0 do close(t.master)
		if kill_children && !t.reaped && t.pid > 0 {
			kill(-t.pgid, SIGKILL)
			kill(t.pid, SIGKILL)
			st: c.int
			if !t.orphan do waitpid(t.pid, &st, 0)
		}
		term_free(t)
	}
	delete(h.terms)
	stop_listening(h)
	if h.lock_fd >= 0 do close(h.lock_fd)
	if h.kq >= 0 do close(h.kq)
	if h.owns_dirs {
		delete(h.cfg.run_dir)
		delete(h.cfg.data_dir)
	}
	delete(h.upgrade_error)
	delete(h.instance)
	delete(h.buf)
	delete(h.sup.path)
	delete(h.sup_launchers)
	free(h)
}

@(private)
conn_free :: proc(cn: ^Conn) {
	if cn.fd >= 0 do close(cn.fd)
	if cn.secret_out do trust.wipe(raw_data(cn.out)[:cap(cn.out)])
	holderwire.stream_destroy(&cn.rx)
	delete(cn.out)
	free(cn)
}

@(private)
term_free :: proc(t: ^Term) {
	if t.pending && t.exec_fd >= 0 do close(t.exec_fd)
	ring_destroy(&t.tail)
	delete(t.input)
	free(t)
}

// Treat fd as an accepted connection from a core (the listener calls this; tests pass one end
// of a socketpair). The peer is read before any byte is: refused, fd is closed without a byte.
holder_attach :: proc(h: ^Holder, fd: c.int) -> bool {
	peer := trust.peer_read(posix.FD(fd))
	if d := trust.peer_allowed(.Adhoc, trust.own_uid(), peer); d != .Allow {
		hlog(h, "refused a connection: %v", d)
		close(fd)
		return false
	}
	pending := 0
	for cn in h.conns do if !cn.welcomed && !cn.closing do pending += 1
	if pending >= MAX_PENDING || h.shutting_down {
		hlog(h, "refused a connection: too many pending or shutting down")
		close(fd)
		return false
	}
	set_nonblock(fd)
	set_nosigpipe(fd)
	cn := new(Conn)
	cn.fd, cn.peer, cn.last_rx, cn.accepted_at = fd, peer, time.tick_now(), time.tick_now()
	h.serials += 1
	cn.serial = h.serials
	append(&h.conns, cn)
	return true
}

// ---- the loop ----

@(private)
Poll_Who :: enum {
	Listen,
	Wake,
	Orphans,
	Conn,
	Term,
	Spawn, // a pending terminal's exec_fd
}

// One iteration: wait up to timeout_ms (less when a timer is due) for sockets, masters or a
// SIGCHLD, handle what is ready, then the timers (pings, reaping, EXITED, idle exit).
holder_step :: proc(h: ^Holder, timeout_ms: int) {
	if h.done do return
	fds := make([dynamic]Pollfd, 0, 4 + len(h.conns) + len(h.terms), context.temp_allocator)
	who := make([dynamic]Poll_Who, 0, cap(fds), context.temp_allocator)
	idx := make([dynamic]int, 0, cap(fds), context.temp_allocator)
	add :: proc(fds: ^[dynamic]Pollfd, who: ^[dynamic]Poll_Who, idx: ^[dynamic]int, fd: c.int, ev: c.short, w: Poll_Who, i: int) {
		append(fds, Pollfd{fd = fd, events = ev})
		append(who, w)
		append(idx, i)
	}
	if h.listen_paused && time.tick_since(h.listen_paused_at) >= ACCEPT_BACKOFF do h.listen_paused = false
	if h.listen_fd >= 0 && !h.shutting_down && !h.listen_paused do add(&fds, &who, &idx, h.listen_fd, POLLIN, .Listen, 0)
	if h.wake_fd >= 0 do add(&fds, &who, &idx, h.wake_fd, POLLIN, .Wake, 0)
	input_pause(h)
	if h.kq >= 0 do add(&fds, &who, &idx, h.kq, POLLIN, .Orphans, 0)
	for cn, i in h.conns {
		ev: c.short
		if (!cn.closing || cn.linger) && !(cn == h.core && h.input_paused) do ev |= POLLIN
		if queued(cn) > 0 do ev |= POLLOUT
		add(&fds, &who, &idx, cn.fd, ev, .Conn, i)
	}
	reading := reading_allowed(h)
	for t, i in h.terms {
		if t.pending && t.exec_fd >= 0 do add(&fds, &who, &idx, t.exec_fd, POLLIN, .Spawn, i)
		if t.master < 0 || t.eof || t.pending do continue
		ev: c.short
		if reading do ev |= POLLIN
		if len(t.input) > 0 do ev |= POLLOUT
		if ev != 0 do add(&fds, &who, &idx, t.master, ev, .Term, i)
	}

	timeout := min(timeout_ms, next_timer_ms(h))
	n := poll(raw_data(fds), auto_cast len(fds), c.int(max(timeout, 0)))
	if n > 0 {
		for pfd, k in fds {
			if pfd.revents == 0 do continue
			switch who[k] {
			case .Listen: accept_all(h)
			case .Wake:
				drain: [64]u8
				for read(h.wake_fd, &drain, size_of(drain)) > 0 {}
				reap_strays(h) // Linux: children that are neither sessions nor tracked (sys_linux.odin)
			case .Orphans:
				orphans_read(h)
			case .Conn:
				cn := h.conns[idx[k]]
				if pfd.revents & POLLOUT != 0 do conn_flush(h, cn)
				if pfd.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 && !cn.dead {
					if !cn.closing do conn_read(h, cn)
					else if cn.linger do conn_linger_read(h, cn)
				}
			case .Term:
				t := h.terms[idx[k]]
				if pfd.revents & POLLOUT != 0 do term_flush(t)
				if pfd.revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 do term_read(h, t)
			case .Spawn:
				spawn_resolve(h, h.terms[idx[k]], false)
			}
		}
	}
	// flush what handling queued (replies, OUTPUT) right away
	for cn in h.conns do if !cn.dead && queued(cn) > 0 do conn_flush(h, cn)
	timers(h)
	sweep_conns(h)
}

// INPUT a program does not take is queued up to input_cap; past it the core's connection is not
// read (its writes wait, as a paste into a direct PTY would), and after input_stall that queue is
// dropped (logged), before the app's own write timeout would give up on the holder.
@(private)
input_pause :: proc(h: ^Holder) {
	over := false
	for t in h.terms do if len(t.input) >= h.cfg.input_cap do over = true
	if !over {
		h.input_paused = false
		return
	}
	if !h.input_paused {
		h.input_paused, h.input_paused_at = true, time.tick_now()
		return
	}
	if time.tick_since(h.input_paused_at) < h.cfg.input_stall do return
	for t in h.terms do if len(t.input) >= h.cfg.input_cap {
		hlog(h, "terminal %d: its program took no INPUT for %v: dropping %d queued bytes", t.id, h.cfg.input_stall, len(t.input))
		clear(&t.input)
	}
	h.input_paused = false
}

// Masters are read unless the attached core has queue_cap bytes it has not taken (§5.6). With no
// core they are always read, into the tails only, so programs never stall.
@(private)
reading_allowed :: proc(h: ^Holder) -> bool {return h.core == nil || queued(h.core) < h.cfg.queue_cap}

@(private)
queued :: proc(cn: ^Conn) -> int {return len(cn.out) - cn.out_head}

@(private)
ms_until :: proc(since: time.Tick, d: time.Duration) -> int {
	left := d - time.tick_since(since)
	return max(int(time.duration_milliseconds(left)) + 1, 0)
}

@(private)
next_timer_ms :: proc(h: ^Holder) -> int {
	t := max(int)
	if h.shutting_down do return 10
	for cn in h.conns {
		if cn.closing do t = min(t, ms_until(cn.closing_since, cn.linger ? LINGER : h.cfg.pong_timeout))
		else do t = min(t, ms_until(cn.last_rx, h.cfg.pong_timeout))
		if !cn.welcomed && !cn.closing do t = min(t, ms_until(cn.accepted_at, h.cfg.hello_timeout))
	}
	for term in h.terms {
		if term.pending do t = min(t, ms_until(term.spawned_at, h.cfg.spawn_timeout))
		if !term.reaped && !term.orphan do t = min(t, int(time.duration_milliseconds(h.cfg.reap_interval)) + 1)
		else if !term.reaped && term.polled do t = min(t, int(time.duration_milliseconds(h.cfg.reap_interval)) + 1)
		else if !term.final do t = min(t, ms_until(term.reaped_at, h.cfg.exit_grace))
	}
	if h.idle do t = min(t, ms_until(h.idle_since, h.cfg.idle_exit))
	if h.input_paused do t = min(t, ms_until(h.input_paused_at, h.cfg.input_stall))
	if h.listen_paused do t = min(t, ms_until(h.listen_paused_at, ACCEPT_BACKOFF))
	return t
}

@(private)
accept_all :: proc(h: ^Holder) {
	for {
		fd: c.int = -1
		sync_lock()
		if h.cfg.test_accept_errno != 0 do __error()^ = h.cfg.test_accept_errno
		else do fd = accept(h.listen_fd, nil, nil)
		if fd >= 0 do set_cloexec(fd)
		sync_unlock()
		if fd < 0 {
			// the listener stays readable while the connection waits: polling it again at once
			// would spin
			if e := errno(); e == EMFILE || e == ENFILE {
				if !h.accept_logged do hlog(h, "accept: out of file descriptors (errno %d): backing off", e)
				h.accept_logged = true
				h.listen_paused, h.listen_paused_at = true, time.tick_now()
			}
			return
		}
		h.accept_logged = false
		holder_attach(h, fd)
	}
}

@(private)
conn_read :: proc(h: ^Holder, cn: ^Conn) {
	n := recv(cn.fd, raw_data(h.buf), len(h.buf), 0)
	if n < 0 {
		e := errno()
		if e == EAGAIN || e == EINTR do return
		conn_drop(h, cn, fmt.tprintf("read failed: errno %d", e))
		return
	}
	if n == 0 {
		conn_drop(h, cn, "closed the connection")
		return
	}
	// Bytes in hand: act on them only if the peer is still the process (and image) we checked.
	if d := trust.peer_still(cn.peer, trust.peer_read(posix.FD(cn.fd))); d != .Allow {
		conn_drop(h, cn, fmt.tprintf("peer changed since accept: %v", d))
		return
	}
	cn.last_rx = time.tick_now()
	holderwire.stream_feed(&cn.rx, h.buf[:n])
	if !cn.welcomed do trust.wipe(h.buf[:n]) // a HELLO may carry the successor secret (its frame is wiped once decoded)
	// before HELLO only a HELLO, judged by its header (nothing of a big payload is buffered)
	if hd, whole := holderwire.parse_header(cn.rx.buf[cn.rx.head:]); whole && !cn.welcomed {
		if (hd.kind != u8(holderwire.Kind.Hello) && hd.kind != u8(holderwire.Kind.Supervise)) || hd.len > holderwire.MAX_CONTROL {
			conn_drop(h, cn, fmt.tprintf("frame kind %d (%d bytes) before HELLO", hd.kind, hd.len))
			return
		}
	}
	for !cn.dead && !cn.closing {
		f, ferr := holderwire.stream_next(&cn.rx)
		if ferr == .Need_More do break
		if ferr == .Too_Large {
			conn_drop(h, cn, "frame too large")
			return
		}
		handle_frame(h, cn, f)
	}
}

@(private)
conn_flush :: proc(h: ^Holder, cn: ^Conn) {
	for queued(cn) > 0 {
		n := send(cn.fd, &cn.out[cn.out_head], c.size_t(queued(cn)), MSG_NOSIGNAL)
		if n < 0 {
			e := errno()
			if e == EAGAIN || e == EINTR do break
			conn_drop(h, cn, fmt.tprintf("write failed: errno %d", e))
			return
		}
		cn.out_head += int(n)
	}
	if cn.out_head == len(cn.out) {
		clear(&cn.out)
		cn.out_head = 0
	} else if cn.out_head > 1024 * 1024 && cn.out_head * 2 > len(cn.out) {
		copy(cn.out[:], cn.out[cn.out_head:])
		resize(&cn.out, len(cn.out) - cn.out_head)
		cn.out_head = 0
	}
	if cn.closing && queued(cn) == 0 && !cn.linger do cn.dead = true
}

// After GOODBYE_ACK: whatever the core still sends is not acted on; its EOF (or an error) ends
// the connection.
@(private)
conn_linger_read :: proc(h: ^Holder, cn: ^Conn) {
	n := recv(cn.fd, raw_data(h.buf), len(h.buf), 0)
	if n < 0 && (errno() == EAGAIN || errno() == EINTR) do return
	if n <= 0 do cn.dead = true
}

// A core gone without GOODBYE (EOF, error, silence, changed peer): its slot is free and the
// next WELCOME says previous = crash.
@(private)
conn_drop :: proc(h: ^Holder, cn: ^Conn, why: string) {
	if cn.dead do return
	hlog(h, "dropping %s: %s", cn == h.core ? "the core" : "a connection", why)
	cn.dead = true
	if cn == h.core {
		h.core = nil
		h.previous = "crash"
		if cn.supervised do sup_core_gone(&h.sup, true, time.tick_now())
	}
}

@(private)
sweep_conns :: proc(h: ^Holder) {
	for i := len(h.conns) - 1; i >= 0; i -= 1 {
		cn := h.conns[i]
		if !cn.dead do continue
		if cn == h.core do h.core = nil
		conn_free(cn)
		ordered_remove(&h.conns, i)
	}
}

@(private)
conn_close_after :: proc(cn: ^Conn) {
	cn.closing = true
	cn.closing_since = time.tick_now()
}

// ---- frames from the core ----

@(private)
send_msg :: proc(cn: ^Conn, kind: holderwire.Kind, terminal: u32, msg: $T) {
	holderwire.encode(&cn.out, kind, terminal, msg)
}

@(private)
handle_frame :: proc(h: ^Holder, cn: ^Conn, f: holderwire.Frame) {
	if !cn.welcomed && f.kind == u8(holderwire.Kind.Supervise) {
		supervise_window(h, cn, f) // a window asks (supervisor.odin)
		return
	}
	if !cn.welcomed {
		if f.kind != u8(holderwire.Kind.Hello) {
			conn_drop(h, cn, fmt.tprintf("frame kind %d before HELLO", f.kind))
			return
		}
		hello: holderwire.Hello
		if e := holderwire.decode(f, .Hello, &hello, context.temp_allocator); e != .None {
			conn_drop(h, cn, fmt.tprintf("bad HELLO: %v", e))
			return
		}
		defer if hello.successor_secret != "" {
			trust.wipe(transmute([]u8)hello.successor_secret) // the decoded copy and the frame's bytes
			trust.wipe(f.payload)
		}
		wire, wire_ok := holderwire.negotiate(hello.wire)
		successor_expire(h)
		switch trust.hello_answer(h.core != nil, wire_ok, h.successor != "", trust.successor_secret_ok(h.successor, hello.successor_secret)) {
		case .Welcome:
			welcome(h, cn, wire)
		case .Welcome_Successor:
			successor_clear(h) // one HELLO
			hlog(h, "the named successor said HELLO")
			welcome(h, cn, wire)
		case .Refuse_Secret:
			hlog(h, "refused HELLO: a successor is named and this core is not it")
			send_msg(cn, .Refused, 0, holderwire.Refused{code = holderwire.REFUSE_CODE_NAMES[.Secret], error = "the session holder is waiting for the Deckhand that is updating (at most a minute)"})
			conn_close_after(cn)
			cn.linger = true // as after GOODBYE_ACK: a closed peer can't be checked, so the core couldn't read why
		case .Refuse_Wire:
			hlog(h, "refused HELLO: wire %d", hello.wire)
			send_msg(cn, .Refused, 0, holderwire.Refused{code = holderwire.REFUSE_CODE_NAMES[.Wire], error = fmt.tprintf("this holder speaks wire %d..%d", holderwire.WIRE_MIN, holderwire.WIRE)})
			conn_close_after(cn)
		case .Refuse_Attached:
			hlog(h, "refused HELLO: a core is attached")
			send_msg(cn, .Refused, 0, holderwire.Refused{code = holderwire.REFUSE_CODE_NAMES[.Attached], error = "another core is attached"})
			conn_close_after(cn)
		}
		return
	}
	id := f.terminal
	if !holderwire.is_known(f.kind) {
		send_msg(cn, .Unknown, id, holderwire.Unknown{kind = i64(f.kind)})
		return
	}
	#partial switch holderwire.Kind(f.kind) {
	case .Ping:
		send_msg(cn, .Pong, 0, holderwire.Empty{})
	case .Spawn:
		handle_spawn(h, cn, f)
	case .Input:
		t := live_term(h, id)
		if t == nil || t.master < 0 || t.eof do return
		append(&t.input, ..f.payload)
		term_flush(t)
	case .Resize:
		t := live_term(h, id)
		m: holderwire.Resize
		if t == nil || holderwire.decode(f, .Resize, &m, context.temp_allocator) != .None do return
		if !size_ok(m.cols, m.rows) {
			hlog(h, "terminal %d: RESIZE %dx%d out of range, ignored", id, m.cols, m.rows)
			return
		}
		t.cols, t.rows, t.xpixel, t.ypixel = u16(m.cols), u16(m.rows), clamp_px(m.xpixel), clamp_px(m.ypixel)
		if t.master >= 0 {
			ws := Winsize{ws_row = t.rows, ws_col = t.cols, ws_xpixel = t.xpixel, ws_ypixel = t.ypixel}
			ioctl(t.master, TIOCSWINSZ, &ws)
		}
	case .Signal:
		t := live_term(h, id)
		m: holderwire.Signal
		if t == nil || holderwire.decode(f, .Signal, &m, context.temp_allocator) != .None do return
		// never after the reap: the pid may belong to someone else by now
		if t.reaped || m.signal <= 0 || m.signal >= NSIG do return
		switch m.target {
		case "pid": kill(t.pid, c.int(m.signal))
		case "pgroup": kill(-t.pgid, c.int(m.signal))
		case: hlog(h, "terminal %d: SIGNAL target %q unknown", id, m.target)
		}
	case .Release:
		t := live_term(h, id)
		if t == nil do return
		t.released = true
		term_forget(t)
	case .Foreground:
		t := live_term(h, id)
		pg: i64
		if t != nil && t.master >= 0 do pg = i64(max(tcgetpgrp(t.master), 0))
		send_msg(cn, .Foreground_Is, id, holderwire.Foreground_Is{pgid = pg})
	case .Goodbye:
		m: holderwire.Goodbye
		if holderwire.decode(f, .Goodbye, &m, context.temp_allocator) != .None do return
		// a goodbye: nothing to relaunch, unless it names a successor (a core's handover): that one
		// must say SUPERVISE in time, or it counts as a crash (supervisor.odin)
		if cn.supervised {
			if m.mode == "handover" && m.successor do sup_successor_named(&h.sup, time.tick_now())
			else do sup_core_gone(&h.sup, false, time.tick_now())
		}
		switch m.mode {
		case "handover": goodbye_handover(h, cn, m.successor)
		case "shutdown": shutdown(h)
		case: hlog(h, "GOODBYE mode %q unknown", m.mode)
		}
	case .Supervise:
		m: holderwire.Supervise
		if holderwire.decode(f, .Supervise, &m, context.temp_allocator) != .None || m.op != "core" do return
		if !strings.has_prefix(m.path, "/") || !strings.has_suffix(m.path, "/" + SUP_SERVE_BIN) || len(m.path) > 1024 {
			hlog(h, "SUPERVISE: not a deckhand-core-serve path: %q", m.path)
			return
		}
		cn.supervised = true
		sup_core_said(&h.sup, m.path, time.tick_now())
		send_msg(cn, .Supervise_Status, 0, sup_status(h))
	case .Upgrade:
		handle_upgrade(h, cn, f) // returns only if it did not happen (upgrade.odin)
	case:
		hlog(h, "ignoring a %d frame from the core", f.kind)
	}
}

@(private)
size_ok :: proc(cols, rows: i64) -> bool {return cols >= 1 && cols <= MAX_COLS && rows >= 1 && rows <= MAX_ROWS}

@(private)
clamp_px :: proc(v: i64) -> u16 {return u16(clamp(v, 0, 65535))}

// A terminal the core may still address (not released).
@(private)
live_term :: proc(h: ^Holder, id: u32) -> ^Term {
	for t in h.terms do if t.id == id && !t.released do return t
	return nil
}

@(private)
find_term :: proc(h: ^Holder, id: u32) -> ^Term {
	for t in h.terms do if t.id == id do return t
	return nil
}

@(private)
welcome :: proc(h: ^Holder, cn: ^Conn, wire: i64) {
	terms := make([dynamic]holderwire.Welcome_Terminal, context.temp_allocator)
	for t in h.terms {
		if t.released || t.pending do continue
		wt := holderwire.Welcome_Terminal {
			id = i64(t.id), pid = i64(t.pid), pgid = i64(t.pgid),
			cols = i64(t.cols), rows = i64(t.rows), xpixel = i64(t.xpixel), ypixel = i64(t.ypixel),
			offset = t.offset,
		}
		if t.final do wt.exit = t.exit
		if t.orphan do wt.degraded = true
		append(&terms, wt)
	}
	send_msg(cn, .Welcome, 0, holderwire.Welcome {
		wire = wire, instance = h.instance, pid = i64(getpid()), holder_rev = HOLDER_REV,
		previous = h.previous, hmac_key = string(hex.encode(h.key[:], context.temp_allocator)),
		terminals = terms[:], upgrade_error = h.upgrade_error,
	})
	for t in h.terms {
		if t.released || t.pending do continue
		tail := ring_bytes(&t.tail)
		holderwire.encode_output(&cn.out, .Tail, t.id, t.offset - u64(len(tail)), tail)
	}
	cn.welcomed, cn.wire = true, wire
	h.core = cn
	hlog(h, "a core attached (previous %s, %d terminals)", h.previous, len(terms))
}

@(private)
handle_spawn :: proc(h: ^Holder, cn: ^Conn, f: holderwire.Frame) {
	id := f.terminal
	fail :: proc(h: ^Holder, cn: ^Conn, id: u32, why: string) {
		hlog(h, "terminal %d: SPAWN failed: %s", id, why)
		send_msg(cn, .Spawn_Failed, id, holderwire.Spawn_Failed{error = why})
	}
	if id == 0 || find_term(h, id) != nil {
		fail(h, cn, id, id == 0 ? "terminal id 0 is reserved" : "terminal id in use")
		return
	}
	m: holderwire.Spawn
	if e := holderwire.decode(f, .Spawn, &m, context.temp_allocator); e != .None {
		fail(h, cn, id, fmt.tprintf("bad SPAWN: %v", e))
		return
	}
	if len(m.argv) == 0 || !strings.has_prefix(m.argv[0], "/") {
		fail(h, cn, id, "argv[0] must be an absolute path")
		return
	}
	if !size_ok(m.cols, m.rows) {
		fail(h, cn, id, fmt.tprintf("size %dx%d out of range (1..%d x 1..%d)", m.cols, m.rows, MAX_COLS, MAX_ROWS))
		return
	}
	ws := Winsize{ws_col = u16(m.cols), ws_row = u16(m.rows), ws_xpixel = clamp_px(m.xpixel), ws_ypixel = clamp_px(m.ypixel)}
	pid, master, exec_fd, why := spawn_pty(m.argv, m.env, m.cwd, ws, h.cfg.test_spawn_gate)
	if why != "" {
		fail(h, cn, id, why)
		return
	}
	t := new(Term)
	t.id, t.master, t.pid, t.pgid = id, master, pid, pid // forkpty makes it a session leader
	t.cols, t.rows, t.xpixel, t.ypixel = ws.ws_col, ws.ws_row, ws.ws_xpixel, ws.ws_ypixel
	t.pending, t.exec_fd, t.spawned_at, t.requester = true, exec_fd, time.tick_now(), cn.serial
	append(&h.terms, t)
	spawn_resolve(h, t, false) // a fast exec (or failure) is answered in this step
}

// A pending terminal's exec happened, failed, or (timed_out) never came in spawn_timeout:
// SPAWNED or SPAWN_FAILED to the core that asked, if it is still the attached one and the
// terminal was not RELEASEd meanwhile. A child nobody waits for any more is hung up.
@(private)
spawn_resolve :: proc(h: ^Holder, t: ^Term, timed_out: bool) {
	if !t.pending do return
	r := Spawn_Result.Exec_Failed
	child_errno: c.int
	if !timed_out do r, child_errno = spawn_result(t.exec_fd)
	if r == .Waiting do return
	t.pending = false
	close(t.exec_fd)
	t.exec_fd = -1
	asker := h.core != nil && h.core.serial == t.requester ? h.core : nil
	if r == .Exec_Failed {
		why := timed_out ? fmt.tprintf("timed out: the child did not exec within %v", h.cfg.spawn_timeout) : fmt.tprintf("exec: errno %d", child_errno)
		if timed_out && !t.reaped do kill(t.pid, SIGKILL)
		term_forget(t)
		hlog(h, "terminal %d: SPAWN failed: %s", t.id, why)
		if asker != nil && !t.released do send_msg(asker, .Spawn_Failed, t.id, holderwire.Spawn_Failed{error = why})
		t.released = true // the reaper forgets it
		return
	}
	if t.released do return // RELEASEd while it waited (hung up then)
	if asker == nil {
		hlog(h, "terminal %d: exec'd after the core that asked for it left: hanging up", t.id)
		term_forget(t)
		t.released = true
		return
	}
	send_msg(asker, .Spawned, t.id, holderwire.Spawned{pid = i64(t.pid), pgid = i64(t.pgid)})
}

// Close the master and hang up the child (unless it was reaped): RELEASE, and spawns nobody
// waits for. The caller marks it released.
@(private)
term_forget :: proc(t: ^Term) {
	if t.master >= 0 do close(t.master)
	t.master = -1
	clear(&t.input)
	if !t.reaped do kill(t.pid, SIGHUP)
}

@(private)
goodbye_handover :: proc(h: ^Holder, cn: ^Conn, successor: bool) {
	acks := make([dynamic]holderwire.Ack_Terminal, context.temp_allocator)
	for t in h.terms do if !t.released && !t.pending do append(&acks, holderwire.Ack_Terminal{id = i64(t.id), offset = t.offset})
	// a named successor (the updater's relaunch): a fresh secret, the only HELLO welcomed until it
	// is used or successor_ttl passes; a plain handover (a quit): none, any core may follow
	successor_clear(h)
	if successor {
		raw: [32]u8
		crypto.rand_bytes(raw[:])
		h.successor = string(hex.encode(raw[:]))
		trust.wipe(raw[:])
		h.successor_until = time.tick_add(time.tick_now(), h.cfg.successor_ttl)
	}
	holderwire.encode(&cn.out, .Goodbye_Ack, 0, holderwire.Goodbye_Ack{terminals = acks[:], successor_secret = h.successor}, secret = h.successor != "")
	cn.secret_out = h.successor != ""
	conn_close_after(cn)
	cn.linger = true
	h.core = nil
	h.previous = "handover"
	hlog(h, "handover: the core said goodbye (%d terminals)", len(acks))
}

@(private)
successor_clear :: proc(h: ^Holder) {
	if h.successor == "" do return
	trust.wipe(transmute([]u8)h.successor)
	delete(h.successor)
	h.successor = ""
}

// The successor secret expires: a successor that never came is a crash-style restart for whoever
// connects next (its handover.json still verifies: the next launch uses it).
@(private)
successor_expire :: proc(h: ^Holder) {
	if h.successor != "" && time.tick_diff(time.tick_now(), h.successor_until) <= 0 {
		hlog(h, "the named successor did not come within %v: any core may connect", h.cfg.successor_ttl)
		successor_clear(h)
	}
}

// GOODBYE{shutdown}: hang up every terminal, reap for up to shutdown_wait, then exit 0.
@(private)
shutdown :: proc(h: ^Holder) {
	hlog(h, "shutdown: hanging up %d terminals", len(h.terms))
	for t in h.terms {
		if t.master >= 0 do close(t.master)
		t.master = -1
		if !t.reaped do kill(t.pid, SIGHUP)
	}
	for cn in h.conns do cn.dead = true
	h.core = nil
	h.shutting_down = true
	stop_listening(h)
	h.shutdown_deadline = time.tick_add(time.tick_now(), h.cfg.shutdown_wait)
}

// ---- terminals ----

@(private)
term_read :: proc(h: ^Holder, t: ^Term) {
	n := read(t.master, raw_data(h.buf), len(h.buf))
	if n > 0 {
		b := h.buf[:n]
		start := t.offset
		t.offset += u64(n)
		ring_push(&t.tail, h.cfg.tail_cap, b)
		if h.core != nil && !t.released do holderwire.encode_output(&h.core.out, .Output, t.id, start, b)
		return
	}
	if n < 0 && (errno() == EAGAIN || errno() == EINTR) do return
	t.eof = true // EOF, or EIO once no process holds the slave
	clear(&t.input)
}

@(private)
term_flush :: proc(t: ^Term) {
	for len(t.input) > 0 {
		n := write(t.master, raw_data(t.input), len(t.input))
		if n <= 0 do return // EAGAIN: when POLLOUT says so
		remove_range(&t.input, 0, int(n))
	}
}

@(private)
timers :: proc(h: ^Holder) {
	for cn in h.conns {
		if cn.dead do continue
		if cn.closing {
			if time.tick_since(cn.closing_since) >= (cn.linger ? LINGER : h.cfg.pong_timeout) do cn.dead = true
		} else if time.tick_since(cn.last_rx) >= h.cfg.pong_timeout {
			conn_drop(h, cn, "no frame within the pong timeout")
		} else if !cn.welcomed && time.tick_since(cn.accepted_at) >= h.cfg.hello_timeout {
			conn_drop(h, cn, "no HELLO in time")
		}
	}
	sup_run(h) // a separate core that crashed is launched again (supervisor.odin)
	if h.keeper_pid > 0 {
		st: c.int
		if r := waitpid(h.keeper_pid, &st, WNOHANG); r == h.keeper_pid || (r < 0 && errno() == ECHILD) do h.keeper_pid = 0
	}
	orphans_poll(h) // Linux: orphans with no pidfd (sys_linux.odin); nothing on macOS
	for i := len(h.terms) - 1; i >= 0; i -= 1 {
		t := h.terms[i]
		if t.pending && time.tick_since(t.spawned_at) >= h.cfg.spawn_timeout do spawn_resolve(h, t, true)
		if !t.reaped && !t.orphan {
			st: c.int
			if waitpid(t.pid, &st, WNOHANG) == t.pid {
				code, sig, ended := exit_from_wait(st)
				if ended {
					t.reaped, t.reaped_at = true, time.tick_now()
					t.exit = holderwire.Exit_Status{code = code, signal = sig}
				}
			}
		}
		if t.reaped && t.released {
			term_free(t)
			ordered_remove(&h.terms, i)
			continue
		}
		if !t.reaped || t.final || t.pending do continue
		// The master stays open past the grace (a grandchild holds the slave): EXITED anyway, after
		// what the PTY holds now; not while the core's queue is full (that output comes first).
		grace := !t.eof && t.master >= 0 && time.tick_since(t.reaped_at) >= h.cfg.exit_grace
		if grace {
			if !reading_allowed(h) do continue
			for _ in 0 ..< 64 {
				before := t.offset
				term_read(h, t)
				if t.offset == before do break
			}
		}
		if t.eof || t.master < 0 || grace {
			t.final = true
			if h.core != nil do send_msg(h.core, .Exited, t.id, holderwire.Exited{code = t.exit.code, signal = t.exit.signal, offset = t.offset})
		}
	}
	if h.shutting_down {
		all := true
		for t in h.terms do if !t.reaped do all = false
		if all || time.tick_diff(h.shutdown_deadline, time.tick_now()) >= 0 {
			h.done, h.exit_code = true, 0
		}
		return
	}
	running := false
	for t in h.terms do if !t.released && !t.reaped do running = true
	if len(h.conns) == 0 && !running {
		if !h.idle do h.idle, h.idle_since = true, time.tick_now()
		else if time.tick_since(h.idle_since) >= h.cfg.idle_exit {
			hlog(h, "no core and no running terminal for %v: exiting", h.cfg.idle_exit)
			stop_listening(h)
			h.done, h.exit_code = true, 0
		}
	} else {
		h.idle = false
	}
}

// ---- the binary ----

@(private)
wake_write_fd: c.int = -1

@(private)
on_sigchld :: proc "c" (sig: c.int) {
	saved := errno()
	b: u8 = 1
	write(wake_write_fd, &b, 1)
	__error()^ = saved
}

// `deckhand-core hold --run DIR --data DIR [--ready PATH]`, or after an UPGRADE's exec
// `hold --resume FD --run DIR --data DIR` (the new image) and `hold --dry-run-resume FD --run DIR
// --data DIR` (its dry run; upgrade.odin).
// Exit codes: 0 done (idle or GOODBYE{shutdown}), 1 a start failure, 2 usage, 3 instance.lock
// held exclusively.
// `--keeper PID` of a new image's argv (upgrade.odin resume_argv; Linux), else 0.
resume_keeper: c.int

hold_main :: proc(args: []string) -> int {
	run_dir, data_dir, ready, resume, dry: string
	for i := 0; i < len(args); i += 1 {
		if i + 1 >= len(args) do return usage()
		switch args[i] {
		case "--run": run_dir = args[i + 1]
		case "--data": data_dir = args[i + 1]
		case "--ready": ready = args[i + 1]
		case "--resume": resume = args[i + 1]
		case "--dry-run-resume": dry = args[i + 1]
		case "--keeper": // after an UPGRADE's exec (Linux): the keeper the old image forked
			n, ok := strconv.parse_int(args[i + 1], 10)
			if !ok || n <= 0 || n > int(max(i32)) do return usage()
			resume_keeper = c.int(n)
		case: return usage()
		}
		i += 1
	}
	// first, before any child: a launcher's leaked fds never reach the sessions; an exec keeps
	// ignored signals and the blocked mask (P1, S2). A new image after an UPGRADE inherits only
	// the keeper's socket, used by its number (holder_resume).
	cloexec_inherited()
	reset_signals()

	if resume != "" || dry != "" {
		if run_dir == "" || data_dir == "" || ready != "" || (resume != "" && dry != "") || (resume_keeper != 0 && resume == "") do return usage()
		raise_fd_limit() // before it takes every master; a resource limit survives exec, but not the raise
		h := holder_resume(dry != "" ? dry : resume, dry != "", run_dir, data_dir)
		if h == nil do return 1
		install_sigchld(h)
		return holder_serve(h)
	}
	if run_dir == "" || data_dir == "" || resume_keeper != 0 do return usage()

	disclaim_responsibility() // re-execs in place (same pid) unless already done
	raise_fd_limit() // after it: the re-exec'd holder would take the raised limit for the original

	if ready != "" {
		// the launcher's environment, applied by ready_handshake (detach.odin)
		if _, ok := ready_handshake(ready); !ok {
			log_line("the launcher's ready handshake failed")
			return 1
		}
	}

	// out of the launcher's cwd (the app's, when started directly; __detach did it already), so
	// the holder never keeps a directory or a volume busy. Relative paths would break: kept then.
	if strings.has_prefix(run_dir, "/") && strings.has_prefix(data_dir, "/") do chdir("/")

	cfg := default_config()
	cfg.run_dir, cfg.data_dir = run_dir, data_dir
	h, err := holder_new(cfg)
	switch err {
	case .None:
	case .Lock_Busy: return 3
	case .Run_Dir, .Listen, .Lock: return 1
	}
	h.can_upgrade = true
	install_sigchld(h)
	return holder_serve(h)
}

// The SIGCHLD self-pipe: a child's exit wakes poll at once (the loop's waitpid finds it).
install_sigchld :: proc(h: ^Holder) {
	wake: [2]c.int
	sync_lock()
	ok := pipe(&wake) == 0
	if ok do for fd in wake do set_cloexec(fd)
	sync_unlock()
	if !ok do return
	for fd in wake do set_nonblock(fd)
	h.wake_fd, wake_write_fd = wake[0], wake[1]
	install_sigchld_handler()
}

install_sigchld_handler :: proc() {
	act := Sigaction{handler = uintptr(rawptr(on_sigchld)), flags = SA_RESTART}
	sigaction(SIGCHLD, &act, nil)
}

// The loop, until the holder is done; its exit code.
holder_serve :: proc(h: ^Holder) -> int {
	for !h.done {
		holder_step(h, 60 * 1000)
		free_all(context.temp_allocator)
	}
	code := h.exit_code
	holder_free(h)
	return code
}

// Each session takes a master (and its pending spawn an exec pipe); launchd's soft limit of 256
// would run out long before the hard one: raise the soft limit to the hard one (capped at
// OPEN_MAX, what setrlimit takes on macOS).
@(private)
raise_fd_limit :: proc() {
	rl: Rlimit
	if getrlimit(RLIMIT_NOFILE, &rl) != 0 do return
	child_nofile, child_nofile_set = rl, true // the sessions get the limit we were started with (spawn_pty)
	want := min(rl.max, OPEN_MAX)
	if rl.cur >= want do return
	rl.cur = want
	if setrlimit(RLIMIT_NOFILE, &rl) != 0 do log_line(fmt.tprintf("setrlimit(NOFILE, %d): errno %d", want, errno()))
}

@(private)
usage :: proc() -> int {
	fmt.eprintln(USAGE)
	return 2
}
