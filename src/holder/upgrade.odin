#+build darwin
package holder

// UPGRADE{path} (docs/plans/background-core.md §7.3): the holder re-execs into a new binary in
// place. The pid stays, so every session stays its child; the masters never close, so nothing
// gets SIGHUP and no output is lost (it waits in the kernel's PTY buffers during the gap).
//
// The old image, when the attached core sends UPGRADE (upgrade_run; the loop is not running, so
// the pumps are paused and INPUT is whole frames or nothing; INPUT the masters have not taken
// yet is part of the state, P2):
//   1. checks the file: an absolute path to a regular file whose static code is signed with our
//      own identifier (trust.image_allowed). Only catches mistakes early: the file can change.
//   2. sends the core everything queued, so the core has every byte up to the state's offsets.
//   3. serialises the state (state.odin).
//   4. the dry run (P3): runs `path hold --dry-run-resume FD` as a child, gated like the real
//      exec (the child's own audit token must pass image_allowed before it gets anything), hands
//      it the state and dup'd masters, and wants back "DRY rev wire_min wire" with a wire range
//      that holds the core's, and exit 0. It proves the new binary reads this state.
//   5. forks the keeper (keeper.odin), which alone holds the fds through the exec.
//   6. execve(path, hold --resume FD). Its own copies of the masters, listener, lock and the
//      core's connection are close-on-exec (checked just before), so the kernel closes them in
//      the same step that starts the new image: the new image starts holding none of them.
//      (The doc's version closes them before execve and has the keeper give them back if execve
//      fails; keeping close-on-exec copies gives the new image exactly as little, and a failed
//      execve then simply carries on, with no round trip that could lose the sessions.)
// Any failure before the exec: UPGRADE_FAILED{error} and the holder carries on as it was, the
// core's connection included (the fallback drain, §7.3 step 7).
//
// The new image (holder_resume, from hold_main): signals and mask back to default before
// anything (P1, hold_main), takes the state from the keeper, reaps exits from the gap (the
// loop's waitpid), replays pending input, serves on the same listener, tells the keeper DONE.
// The core's old connection closed at the exec: it reconnects to the same socket and gets
// WELCOME{previous: upgrade} from the same pid and instance.

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

DRY_RUN_WAIT :: 5 * time.Second
UPGRADE_BUSY :: "busy: a spawn is in flight; retry" // UPGRADE_FAILED's error when it may work in a moment
CORE_FLUSH_WAIT :: 3 * time.Second

// What the dry run reports, and whether it can serve the attached core (pure).
Dry_Result :: struct {
	rev, wire_min, wire: i64,
}

dry_run_ok :: proc(r: Dry_Result, core_wire: i64) -> bool {
	return r.rev >= 1 && r.wire_min >= 1 && r.wire_min <= r.wire && core_wire >= r.wire_min && core_wire <= r.wire
}

// UPGRADE from the attached core. Returns only if the upgrade did not happen (UPGRADE_FAILED is
// sent); a successful one never returns (this image is replaced).
handle_upgrade :: proc(h: ^Holder, cn: ^Conn, f: holderwire.Frame) {
	m: holderwire.Upgrade
	why: string
	if e := holderwire.decode(f, .Upgrade, &m, context.temp_allocator); e != .None {
		why = fmt.tprintf("bad UPGRADE: %v", e)
	} else if !h.can_upgrade {
		why = "this holder cannot upgrade (it is not the holder binary)"
	} else {
		why = upgrade_run(h, cn, m.path)
	}
	hlog(h, "upgrade refused: %s", why)
	send_msg(cn, .Upgrade_Failed, 0, holderwire.Upgrade_Failed{error = why})
}

@(private)
upgrade_run :: proc(h: ^Holder, cn: ^Conn, path: string) -> string {
	// a SPAWN still waiting for its exec (spawn_pty's pending terminal) is not state yet: the
	// loop never blocks on it, so neither does an upgrade; the core retries (holder_upgrade)
	for t in h.terms do if t.pending do return UPGRADE_BUSY
		// 1. the file (an early check only)
	if !strings.has_prefix(path, "/") || len(path) > 1024 do return "the path must be absolute"
	st: posix.stat_t
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.stat(cpath, &st) != .OK || !posix.S_ISREG(st.st_mode) do return fmt.tprintf("%s is not a file", path)
	own := trust.code_identity_self()
	if d := trust.image_allowed(.Adhoc, own, trust.code_identity_of_file(path)); d != .Allow {
		return fmt.tprintf("%s failed verification: %v", path, d)
	}
	// 2. the core has every byte up to the offsets the state will carry
	if !conn_flush_by(h, cn, time.tick_add(time.tick_now(), CORE_FLUSH_WAIT)) do return "the core is not reading"
	// 3. the state
	blob, fds := state_encode(h, context.temp_allocator)
	// 4. the dry run
	if why := dry_run(h, path, blob[:], fds[:], own, cn.wire); why != "" do return fmt.tprintf("the dry run failed: %s", why)
	hlog(h, "upgrade: dry run passed; exec %s", path)

	// everything this image holds must close at the exec: the new image starts with no fd of ours
	for t in h.terms do if t.master >= 0 && !is_cloexec(t.master) do return "a master is not close-on-exec"
	for x in ([]c.int{h.listen_fd, h.lock_fd, h.wake_fd, wake_write_fd, h.kq}) do if x >= 0 && !is_cloexec(x) do return "an fd is not close-on-exec"
	for o in h.conns do if !is_cloexec(o.fd) do return "a connection is not close-on-exec"

	// 5. the keeper
	kp: [2]c.int
	sync_lock()
	if socketpair(AF_UNIX, SOCK_STREAM, 0, &kp) != 0 {
		sync_unlock()
		return fmt.tprintf("socketpair: errno %d", errno())
	}
	set_cloexec(kp[0])
	set_cloexec(kp[1])
	sync_unlock()
	set_nosigpipe(kp[0])
	me := trust.self_peer()
	if !me.ok {
		close(kp[0]); close(kp[1])
		return "cannot read our own audit token"
	}
	argv := resume_argv(h, cpath, "--resume", kp[1])
	keeper := posix.fork()
	if keeper < 0 {
		close(kp[0]); close(kp[1])
		return fmt.tprintf("fork: errno %d", errno())
	}
	if keeper == 0 {
		close(kp[1])
		keeper_run(h, kp[0], me.pid, me.pidversion, blob[:], fds[:], own)
	}
	close(kp[0])
	clear_cloexec(kp[1]) // the one fd the new image inherits

	// 6. exec
	dirty := false
	if _, on := hook("dirty-signals", false); on {
		ign := Sigaction{handler = 1}
		sigaction(SIGPIPE, &ign, nil)
		block: u32 = 1 << (SIGUSR2 - 1)
		sigprocmask(SIG_BLOCK, &block, nil)
		dirty = true
	}
	if to, on := hook("swap", true); on do posix.rename(strings.clone_to_cstring(to, context.temp_allocator), cpath)
	exec_path := cpath
	if _, on := hook("exec-fail", true); on do exec_path = "/nonexistent/deckhand-core"
	execve(exec_path, raw_data(argv[:]), _NSGetEnviron()^)

	// still here: the old image carries on with everything it had
	e := errno()
	kill(c.int(keeper), SIGKILL)
	ks: c.int
	waitpid(c.int(keeper), &ks, 0)
	close(kp[1])
	if dirty {
		reset_signals()
		install_sigchld_handler()
	}
	return fmt.tprintf("execve: errno %d", e)
}

// `path hold --run DIR --data DIR --resume FD`: the dirs are the state's (and checked against
// it), there so that ps and pgrep still tell which holder serves which run dir.
@(private)
resume_argv :: proc(h: ^Holder, path: cstring, flag: cstring, fd: c.int) -> [9]cstring {
	tmp := context.temp_allocator
	return {path, "hold", "--run", strings.clone_to_cstring(h.cfg.run_dir, tmp), "--data", strings.clone_to_cstring(h.cfg.data_dir, tmp), flag, strings.clone_to_cstring(fmt.tprintf("%d", fd), tmp), nil}
}

// Sends everything queued for cn, waiting up to the deadline (the loop is paused meanwhile).
@(private)
conn_flush_by :: proc(h: ^Holder, cn: ^Conn, deadline: time.Tick) -> bool {
	for queued(cn) > 0 && !cn.dead {
		if !wait_fd(cn.fd, POLLOUT, deadline) do return false
		conn_flush(h, cn)
	}
	return !cn.dead
}

// The dry run: "" if it passed, else why not. The child is gated like the real exec: it gets
// the state (and so the key) and dup'd masters only once its live code passes image_allowed.
@(private)
dry_run :: proc(h: ^Holder, path: string, blob: []u8, fds: []c.int, own: trust.Code_Identity, core_wire: i64) -> string {
	dp: [2]c.int
	sync_lock()
	if socketpair(AF_UNIX, SOCK_STREAM, 0, &dp) != 0 {
		sync_unlock()
		return fmt.tprintf("socketpair: errno %d", errno())
	}
	set_cloexec(dp[0])
	set_cloexec(dp[1])
	sync_unlock()
	set_nosigpipe(dp[0])
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	argv := resume_argv(h, cpath, "--dry-run-resume", dp[1])
	env := _NSGetEnviron()^
	sync_lock()
	child := posix.fork()
	if child == 0 {
		clear_cloexec(dp[1])
		execve(cpath, raw_data(argv[:]), env)
		_exit(127)
	}
	sync_unlock()
	close(dp[1])
	if child < 0 {
		close(dp[0])
		return fmt.tprintf("fork: errno %d", errno())
	}
	why := dry_run_talk(dp[0], i32(child), blob, fds, own, core_wire)
	close(dp[0])
	// its exit: 0, within the wait (else it is killed)
	deadline := time.tick_add(time.tick_now(), DRY_RUN_WAIT)
	st: c.int
	for {
		r := waitpid(c.int(child), &st, WNOHANG)
		if r == c.int(child) do break
		if r < 0 && errno() != EINTR {
			if why == "" do why = "lost the dry run's process"
			return why
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			kill(c.int(child), SIGKILL)
			waitpid(c.int(child), &st, 0)
			if why == "" do why = "it did not exit"
			return why
		}
		time.sleep(2 * time.Millisecond)
	}
	if why != "" do return why
	code, sig, _ := exit_from_wait(st)
	if code != 0 || sig != 0 do return fmt.tprintf("it exited with %d (signal %d)", code, sig)
	return ""
}

@(private)
dry_run_talk :: proc(fd: c.int, child: i32, blob: []u8, fds: []c.int, own: trust.Code_Identity, core_wire: i64) -> string {
	deadline := time.tick_add(time.tick_now(), DRY_RUN_WAIT)
	peer, tok, ok := handoff_await_hello(fd, deadline)
	if !ok do return "the new image did not start"
	if d := trust.dry_run_peer_allowed(.Adhoc, trust.own_uid(), child, peer); d != .Allow do return fmt.tprintf("its peer: %v", d)
	code := trust.code_identity_of_token(tok)
	if d := trust.image_allowed(.Adhoc, own, code); d != .Allow do return fmt.tprintf("the new image failed verification: %v (identifier %q)", d, code.identifier)
	if !handoff_give(fd, blob, fds, deadline) do return "it did not take the state"
	res: [16]u8
	if !recv_all_by(fd, res[:], deadline) || string(res[:4]) != "DRY " do return "it did not report"
	r: Dry_Result
	v1, _ := endian.get_u32(res[4:8], .Little)
	v2, _ := endian.get_u32(res[8:12], .Little)
	v3, _ := endian.get_u32(res[12:16], .Little)
	r = {i64(v1), i64(v2), i64(v3)}
	if !dry_run_ok(r, core_wire) do return fmt.tprintf("holder_rev %d, wire %d..%d does not serve this core (wire %d)", r.rev, r.wire_min, r.wire, core_wire)
	return ""
}

// ---- the new image ----

// `hold --resume FD` and `hold --dry-run-resume FD` (hold_main, after reset_signals): take the
// state over FD. A dry run reports and exits; a resume returns the holder to serve (nil, with a
// log line, if the handoff failed: the caller exits 1 and the keeper keeps the terminals).
holder_resume :: proc(fd_arg: string, dry: bool, run_dir, data_dir: string) -> ^Holder {
	fdn, nok := strconv.parse_int(fd_arg, 10)
	if !nok || fdn < 3 || fdn > 1 << 20 {
		log_line(fmt.tprintf("resume: bad fd %q", fd_arg))
		return nil
	}
	fd := c.int(fdn)
	set_cloexec(fd)
	set_nosigpipe(fd)
	blob, fds, ok := handoff_take(fd, time.tick_add(time.tick_now(), HANDOFF_WAIT))
	if !ok {
		log_line("resume: the keeper refused us or went away: exiting")
		close(fd)
		return nil
	}
	h, why := state_decode(blob, fds[:], default_config())
	delete(blob)
	if h == nil {
		log_line(fmt.tprintf("resume: the state is unreadable (%s): exiting", why))
		for x in fds do close(x)
		close(fd)
		return nil
	}
	delete(fds)
	if h.cfg.run_dir != run_dir || h.cfg.data_dir != data_dir {
		log_line(fmt.tprintf("resume: the state is for %s and %s, not the dirs we were given: exiting", h.cfg.run_dir, h.cfg.data_dir))
		os.exit(1) // the fds go with us; the keeper keeps its copies
	}
	if dry {
		if _, on := hook("dry-run-fail", true); on do _exit(1)
		res: [16]u8
		copy(res[:4], "DRY ")
		endian.put_u32(res[4:8], .Little, u32(HOLDER_REV))
		endian.put_u32(res[8:12], .Little, u32(holderwire.WIRE_MIN))
		endian.put_u32(res[12:16], .Little, u32(holderwire.WIRE))
		send_all_by(fd, res[:], time.tick_add(time.tick_now(), HANDOFF_WAIT))
		_exit(0) // nothing else: the dry run never serves, reads or writes a master
	}
	if _, on := hook("crash-resume", true); on do _exit(1)
	h.previous = "upgrade"
	h.can_upgrade = true
	orphans_watch(h)
	done := transmute([]u8)string("DONE")
	if !send_all_by(fd, done, time.tick_add(time.tick_now(), HANDOFF_WAIT)) {
		// the keeper is gone (it can no longer adopt): we have the terminals, so we serve
		log_line("resume: could not tell the keeper we took over")
	}
	close(fd)
	hlog(h, "upgraded in place: holder_rev %d, %d terminals, instance %s", HOLDER_REV, len(h.terms), h.instance)
	return h
}
