#+build darwin
package holder

// The upgrade's handoff and its keeper (docs/plans/background-core.md §7.3 steps 3–6).
//
// The handoff: how an image that was just exec'd gets the holder's state and open files. The
// giver (the keeper, or the old image during the dry run) and the taker share a socketpair; the
// taker inherited its end across execve (the one fd that is not close-on-exec). It goes:
//
//   taker → giver   "DHK1" pid u32                         (8 bytes)
//   giver           reads the peer's LIVE audit token now (the bytes are in hand, so the token
//                   is the process that wrote them: what the kernel actually ran), and decides
//                   (trust.successor_image_allowed or dry_run_peer_allowed, then
//                   trust.image_allowed on its code). Refused: it closes the socket, nothing sent.
//   giver → taker   "DHK1" nfds u32 len u64                 (16 bytes)
//                   ceil(nfds / 64) messages of 1 byte, each with up to 64 fds (SCM_RIGHTS)
//                   the state blob (len bytes, state.odin)
//   taker → giver   "DONE" (it took everything)  |  "DRY " rev u32 wire_min u32 wire u32 (a dry run)
//   giver → taker   "GO  " (a keeper whose header said "DHK2"): only now does the taker serve
//
// The GO closes a race (holder_rev 5): without it the taker served as soon as it sent DONE, so a
// keeper whose DONE wait ran out at that moment adopted (or killed) while the new image served the
// same masters. Now the taker waits for GO and exits without it; the keeper sends GO only for a
// DONE that came in time. A keeper of holder_rev 4 or older sends "DHK1" and no GO: the taker
// then serves on DONE, as before.
//
// The keeper: forked by the old image just before execve, it is the only process holding the
// masters, the listener and instance.lock while the exec happens (the old image's copies are
// close-on-exec, so the kernel drops them at a successful exec; see upgrade.odin). It waits up
// to KEEPER_WAIT for the new image's hello, then hands everything over only to the holder's own
// pid with a new pidversion whose code passes image_allowed. A swapped binary gets the pid, and
// so parenthood of the sessions, but never their terminals or the key.
//
// If the new image never says hello, fails the check, or ends before "DONE", the keeper keeps
// the terminals itself: it already runs the old image's code (it is a fork of it), so it becomes
// the holder in place (keeper_adopt) instead of exec'ing the old binary, whose file could have
// been swapped as well. The sessions are not its children (they stay the new image's, or
// launchd's once it is gone), so their exits come from kqueue EVFILT_PROC NOTE_EXITSTATUS, which
// reports the wait status for non-children (S2): orphans, `degraded` in WELCOME.

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../holderwire"
import "../trust"

HANDOFF_MAGIC :: "DHK1"
HANDOFF_MAGIC_GO :: "DHK2" // the giver's header from a keeper that sends GO after DONE
HANDOFF_GO :: "GO  "
HANDOFF_FDS_PER_MSG :: 64
KEEPER_WAIT :: 10 * time.Second // the new image's hello (§7.3 step 6)
HANDOFF_WAIT :: 10 * time.Second // each later step of a handoff
KEEPER_DONE_WAIT :: 10 * time.Second // the new image's DONE after it took the state (it hangs: killed)
HANDOFF_MAX_FDS :: 2 + STATE_MAX_TERMS
HANDOFF_MAX_BLOB :: 1 << 34

// ---- blocking I/O with a deadline (the loop is not running while these do) ----

@(private)
wait_fd :: proc(fd: c.int, events: c.short, deadline: time.Tick) -> bool {
	for {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return false
		pfd := Pollfd{fd = fd, events = events}
		n := poll(&pfd, 1, c.int(max(time.duration_milliseconds(left), 1)))
		if n > 0 do return true
		if n < 0 && errno() != EINTR do return false
	}
}

@(private)
send_all_by :: proc(fd: c.int, b: []u8, deadline: time.Tick) -> bool {
	rest := b
	for len(rest) > 0 {
		if !wait_fd(fd, POLLOUT, deadline) do return false
		n := send(fd, raw_data(rest), c.size_t(len(rest)), MSG_NOSIGNAL)
		if n < 0 && (errno() == EINTR || errno() == EAGAIN) do continue
		if n <= 0 do return false
		rest = rest[n:]
	}
	return true
}

@(private)
recv_all_by :: proc(fd: c.int, b: []u8, deadline: time.Tick) -> bool {
	got := 0
	for got < len(b) {
		if !wait_fd(fd, POLLIN, deadline) do return false
		left := len(b) - got
		n := recv(fd, &b[got], c.size_t(left), 0)
		if n < 0 && (errno() == EINTR || errno() == EAGAIN) do continue
		if n <= 0 do return false
		got += int(n)
	}
	return true
}

// ---- the giver's side ----

// Waits for the taker's hello; the peer as it is now (the hello's writer) and its full token.
handoff_await_hello :: proc(fd: c.int, deadline: time.Tick) -> (peer: trust.Peer, tok: trust.Audit_Token, ok: bool) {
	b: [8]u8
	if !recv_all_by(fd, b[:], deadline) || string(b[:4]) != HANDOFF_MAGIC do return {}, {}, false
	peer, tok = trust.peer_read_token(posix.FD(fd))
	return peer, tok, peer.ok
}

// The state and its fds to the taker (the fds are copied: the giver keeps its own).
handoff_give :: proc(fd: c.int, blob: []u8, fds: []c.int, deadline: time.Tick, magic := HANDOFF_MAGIC) -> bool {
	hdr: [16]u8
	copy(hdr[:4], magic)
	endian.put_u32(hdr[4:8], .Little, u32(len(fds)))
	endian.put_u64(hdr[8:16], .Little, u64(len(blob)))
	if !send_all_by(fd, hdr[:], deadline) do return false
	for i := 0; i < len(fds); i += HANDOFF_FDS_PER_MSG {
		batch := fds[i:min(i + HANDOFF_FDS_PER_MSG, len(fds))]
		ctl: [size_of(Cmsghdr) + 4 * HANDOFF_FDS_PER_MSG]u8
		cm := (^Cmsghdr)(&ctl[0])
		cm.len = u32(size_of(Cmsghdr) + 4 * len(batch))
		cm.level, cm.type = SOL_SOCKET, SCM_RIGHTS
		for f, k in batch do endian.put_u32(ctl[size_of(Cmsghdr) + 4 * k:][:4], .Little, u32(f))
		one: u8 = 'F'
		iov := Iovec{&one, 1}
		msg := Msghdr{iov = &iov, iovlen = 1, control = &ctl[0], controllen = cm.len}
		if !wait_fd(fd, POLLOUT, deadline) || sendmsg(fd, &msg, MSG_NOSIGNAL) != 1 do return false
	}
	return send_all_by(fd, blob, deadline)
}

// ---- the taker's side ----

// Says hello and takes the state and fds (heap). ok false: the giver refused (closed) or broke
// off; any fds already received are closed. go: the giver sends GO after our DONE (a keeper of
// holder_rev 5 or newer): serve only once it came.
handoff_take :: proc(fd: c.int, deadline: time.Tick) -> (blob: []u8, fds: [dynamic]c.int, go: bool, ok: bool) {
	hello: [8]u8
	copy(hello[:4], HANDOFF_MAGIC)
	endian.put_u32(hello[4:8], .Little, u32(getpid()))
	if !send_all_by(fd, hello[:], deadline) do return nil, nil, false, false
	hdr: [16]u8
	if !recv_all_by(fd, hdr[:], deadline) do return nil, nil, false, false
	switch string(hdr[:4]) {
	case HANDOFF_MAGIC:
	case HANDOFF_MAGIC_GO: go = true
	case: return nil, nil, false, false
	}
	nfds, _ := endian.get_u32(hdr[4:8], .Little)
	n, _ := endian.get_u64(hdr[8:16], .Little)
	if nfds > HANDOFF_MAX_FDS || n > HANDOFF_MAX_BLOB do return nil, nil, false, false
	fds = make([dynamic]c.int)
	fail :: proc(fds: ^[dynamic]c.int) -> ([]u8, [dynamic]c.int, bool, bool) {
		for f in fds do close(f)
		delete(fds^)
		return nil, nil, false, false
	}
	for len(fds) < int(nfds) {
		want := min(int(nfds) - len(fds), HANDOFF_FDS_PER_MSG)
		ctl: [size_of(Cmsghdr) + 4 * HANDOFF_FDS_PER_MSG]u8
		one: u8
		iov := Iovec{&one, 1}
		msg := Msghdr{iov = &iov, iovlen = 1, control = &ctl[0], controllen = u32(len(ctl))}
		if !wait_fd(fd, POLLIN, deadline) do return fail(&fds)
		sync_lock() // received fds are not close-on-exec until we say so
		r := recvmsg(fd, &msg, 0)
		got := 0
		if r == 1 && msg.controllen >= size_of(Cmsghdr) {
			cm := (^Cmsghdr)(&ctl[0])
			if cm.level == SOL_SOCKET && cm.type == SCM_RIGHTS && cm.len >= size_of(Cmsghdr) {
				got = (int(cm.len) - size_of(Cmsghdr)) / 4
				for k in 0 ..< got {
					v, _ := endian.get_u32(ctl[size_of(Cmsghdr) + 4 * k:][:4], .Little)
					set_cloexec(c.int(v))
					append(&fds, c.int(v))
				}
			}
		}
		sync_unlock()
		if r != 1 || got != want || msg.flags != 0 do return fail(&fds) // MSG_CTRUNC: fds lost
	}
	blob = make([]u8, int(n))
	if !recv_all_by(fd, blob, deadline) {
		delete(blob)
		return fail(&fds)
	}
	return blob, fds, go, true
}

// ---- the keeper ----

// The keeper's whole life (it is the forked child of the old image; never returns). k: its end
// of the socketpair; holder_pid and old_pv: the image that forked it; own: its code identity.
keeper_run :: proc(h: ^Holder, k: c.int, holder_pid, old_pv: i32, blob: []u8, fds: []c.int, own: trust.Code_Identity) -> ! {
	// only the terminals, the listener and the lock: no core connection, no SIGCHLD pipe
	for cn in h.conns do conn_free(cn)
	clear(&h.conns)
	h.core = nil
	if h.wake_fd >= 0 do close(h.wake_fd)
	if wake_write_fd >= 0 do close(wake_write_fd)
	h.wake_fd, wake_write_fd = -1, -1
	h.kq = -1 // a kqueue is not inherited by fork
	hlog(h, "keeper: holding %d terminals for the new image", len(h.terms))

	why: string
	peer, tok, ok := handoff_await_hello(k, time.tick_add(time.tick_now(), KEEPER_WAIT))
	if !ok {
		why = "the new holder image did not connect to its keeper (it exited, or 10 s passed)"
	} else {
		d := trust.successor_image_allowed(.Adhoc, trust.own_uid(), holder_pid, old_pv, peer)
		code: trust.Code_Identity
		if d == .Allow {
			code = trust.code_identity_of_token(tok)
			d = trust.image_allowed(.Adhoc, own, code)
		}
		if d != .Allow {
			why = fmt.aprintf("the new holder image failed verification (%v; identifier %q)", d, code.identifier)
		} else if !handoff_give(k, blob, fds, time.tick_add(time.tick_now(), HANDOFF_WAIT), HANDOFF_MAGIC_GO) {
			why = "the new holder image stopped while taking over"
		} else {
			// it has everything: it serves once it said DONE and got our GO; its end closing first
			// means it died. One that hangs holds the listener and never serves: after the wait it
			// is killed (if it is still that image) and the keeper's copies of the masters keep the
			// sessions. Without our GO it never serves, so a DONE that comes too late is harmless.
			wait := KEEPER_DONE_WAIT
			if ms, on := hook("done-wait", true); on {
				if v, vok := strconv.parse_int(ms); vok do wait = time.Duration(v) * time.Millisecond
			}
			done: [4]u8
			got := recv_all_by(k, done[:], time.tick_add(time.tick_now(), wait))
			if got && string(done[:]) == "DONE" {
				if _, on := hook("no-go", true); !on && send_all_by(k, transmute([]u8)string(HANDOFF_GO), time.tick_add(time.tick_now(), HANDOFF_WAIT)) {
					hlog(h, "keeper: the new image took over; exiting")
					_exit(0)
				}
				why = "the new holder image went away before it could serve"
			} else do why = "the new holder image stopped before it took over"
			if !got && keeper_kill_successor(h, k, holder_pid, peer) {
				why = "the new holder image did not take over in time (it was stopped)"
			}
		}
	}
	close(k)
	keeper_adopt(h, why)
}

// The new image took the state and did not say DONE in time: SIGKILL it, only if the socket's
// peer is still that image (the pid and pidversion that passed the checks). True if killed.
@(private)
keeper_kill_successor :: proc(h: ^Holder, k: c.int, holder_pid: i32, verified: trust.Peer) -> bool {
	now := trust.peer_read(posix.FD(k))
	if !now.ok || now.pid != holder_pid || now.pid != verified.pid || now.pidversion != verified.pidversion {
		hlog(h, "keeper: the new image did not say DONE and is no longer the one checked: not killed")
		return false
	}
	hlog(h, "keeper: the new image (pid %d) did not say DONE in time: killing it", holder_pid)
	return kill(c.int(holder_pid), SIGKILL) == 0
}

// The keeper becomes the holder (§7.3 step 6): the same terminals, instance and key; the sessions
// it did not spawn are orphans. Never returns.
keeper_adopt :: proc(h: ^Holder, why: string) -> ! {
	hlog(h, "keeper: %s: keeping the terminals here (degraded)", why)
	h.previous = "upgrade"
	h.upgrade_error = strings.clone(why)
	for t in h.terms do if !t.reaped do t.orphan = true
	// never upgraded again: it is a fork that never exec'd, and upgrade_run's file check runs
	// Security.framework, unsafe after fork; with the only copies of the masters, a crash there
	// would hang up every session. It ends once its sessions do (handle_upgrade says so).
	h.can_upgrade = false
	h.forked = true // nor the supervisor's code checks (Security.framework)
	orphans_watch(h)
	install_sigchld(h)
	os.exit(holder_serve(h))
}

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

@(private)
orphan_ended :: proc(t: ^Term, status: int, known: bool) {
	t.reaped, t.reaped_at = true, time.tick_now()
	t.exit = {code = -1}
	if known {
		code, sig, ended := exit_from_wait(c.int(status))
		if ended do t.exit = holderwire.Exit_Status{code = code, signal = sig}
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

// ---- test hooks (build with -define:DECKHAND_TEST_HOOKS=true; never in a release holder) ----
//
// DECKHAND_HOLDER_HOOKS=DIR names a directory; a file there turns a hook on:
//   dirty-signals   the old image ignores SIGPIPE and blocks SIGUSR2 just before execve (as a
//                   careless launcher would): the new image must reset both before any spawn (P1)
//   swap            holds a path; renamed over the UPGRADE path just before execve (consumed):
//                   the R3 race, a binary swapped after every check on the file
//   exec-fail       execve fails (consumed)
//   dry-run-fail    the dry run's image exits 1 after taking the state (consumed)
//   crash-resume    the new image exits 1 after taking the state, before DONE (consumed)
//   hang-resume     the new image hangs after taking the state, before DONE (consumed)
//   no-go           the keeper got DONE but sends no GO, as if its wait had just run out (consumed)
//   done-wait       holds milliseconds: the keeper's wait for DONE (consumed; KEEPER_DONE_WAIT)

TEST_HOOKS :: #config(DECKHAND_TEST_HOOKS, false)

// A hook's file: present (and its content); consumed ones are removed.
hook :: proc(name: string, consume: bool) -> (content: string, on: bool) {
	when !TEST_HOOKS {
		return "", false
	} else {
		dir := os.get_env("DECKHAND_HOLDER_HOOKS", context.temp_allocator)
		if dir == "" do return "", false
		p := fmt.tprintf("%s/%s", dir, name)
		b, err := os.read_entire_file(p, context.temp_allocator)
		if err != nil do return "", false
		if consume do os.remove(p)
		return strings.trim_space(string(b)), true
	}
}
