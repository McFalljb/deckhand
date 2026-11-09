package core

// An update keeps the sessions (docs/plans/background-core.md §7.2, §7.4 step 3): the successor
// secret's path from the session holder to the new app. It is never in argv, the environment, a
// file or a log, and no Deckhand structure that is logged or saved holds it.
//
//   old app   update_swap (update.odin) starts the relaunch helper, `deckhand-core relaunch`
//             (src/holder/relaunch.odin), with a pipe on its stdin, once the new bundle is in
//             place: relaunch_helper_start. At quit, holder_handover says
//             GOODBYE{handover, successor} and writes the GOODBYE_ACK's secret into that pipe
//             (relaunch_helper_send), "\n" when there is none.
//   helper    waits for the old app to exit, opens the new bundle, and hands the secret to the
//             first peer of <run>/successor.sock that is this user's, the pid it says, and runs
//             the new bundle's executable.
//   new app   at launch, before it connects to the holder: successor_secret_take() asks
//             successor.sock (if it is there) and says HELLO{successor_secret} with it. The
//             holder welcomes only that HELLO for 60 s; another Deckhand gets REFUSED{secret}
//             and does not start a holder of its own (holder_client.odin).

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "../trust"

SUCCESSOR_SOCK :: "successor.sock" // src/holder/relaunch.odin's
RELAUNCH_READY_WAIT :: 5 * time.Second
// How long the new app waits for the helper's secret: it answers once it is serving (after it
// started `open`, which it no longer waits for), so this only covers a slow machine. Only after
// an update (successor.sock is there); the launch waits meanwhile.
SUCCESSOR_TAKE_WAIT :: 15 * time.Second

// The old app's helper: its pid and the write end of its stdin (-1 = none started).
relaunch_helper := struct {
	pid: posix.pid_t,
	fd:  posix.FD,
}{fd = -1}

// Starts `bin relaunch` for the swapped-in bundle and waits for its "ready". exe: the new app's
// executable, the only one the helper gives the secret to. no_open: test mode (the scene starts
// the new app). False: no helper (the caller falls back to the plain relaunch, no successor).
relaunch_helper_start :: proc(bin, bundle, exe, run: string, no_open: bool) -> (ok: bool, why: string) {
	if relaunch_helper.fd >= 0 do return true, ""
	args := make([dynamic]cstring, context.temp_allocator)
	c :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}
	append(&args, c(bin), "relaunch", "--pid", c(fmt.tprintf("%d", posix.getpid())), "--app", c(bundle), "--exe", c(exe), "--run", c(run))
	if no_open do append(&args, "--no-open")
	append(&args, nil)
	// the pipes: close-on-exec before any other fork sees them (fork_lock, pty.odin)
	inp, outp: [2]posix.FD
	sync.rw_mutex_lock(&fork_lock)
	pok := posix.pipe(&inp) == .OK
	if pok && posix.pipe(&outp) != .OK {
		posix.close(inp[0])
		posix.close(inp[1])
		pok = false
	}
	if pok do for fd in ([]posix.FD{inp[0], inp[1], outp[0], outp[1]}) do posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	sync.rw_mutex_unlock(&fork_lock)
	if !pok do return false, "cannot make a pipe"
	defer posix.close(inp[0])
	defer posix.close(outp[1])
	log := c(fmt.tprintf("%s/%s", run, HOLDER_LOG))
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(HOLDER_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(inp[0]), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(outp[1]), 1)
	holder_spawn_addopen(&fa, 2, log, transmute(i32)posix.O_Flags{.WRONLY, .CREAT, .APPEND}, 0o600)
	env := []cstring{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", nil}
	pid: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock)
	err := posix.posix_spawn(&pid, args[0], &fa, &attr, raw_data(args), raw_data(env))
	sync.rw_mutex_shared_unlock(&fork_lock)
	if err != .NONE {
		posix.close(inp[1])
		posix.close(outp[0])
		return false, fmt.tprintf("cannot start %s: %s", bin, posix.strerror(err))
	}
	// its "ready": it listens on successor.sock
	buf: [16]u8
	n := 0
	deadline := time.tick_add(time.tick_now(), RELAUNCH_READY_WAIT)
	for n < len(buf) && (n == 0 || buf[n - 1] != '\n') {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 || !sock_wait_readable(outp[0], max(int(time.duration_milliseconds(left)), 1)) do break
		r := posix.read(outp[0], &buf[n], uint(len(buf) - n))
		if r <= 0 do break
		n += int(r)
	}
	posix.close(outp[0])
	if string(buf[:n]) != "ready\n" {
		posix.close(inp[1]) // it reads EOF: no secret
		posix.kill(pid, .SIGKILL)
		relaunch_reap(pid)
		return false, "the relaunch helper did not get ready"
	}
	relaunch_reap(pid)
	relaunch_helper.pid, relaunch_helper.fd = pid, inp[1]
	return true, ""
}

@(private = "file")
relaunch_reap :: proc(pid: posix.pid_t) {
	thread.create_and_start_with_poly_data(pid, proc(p: posix.pid_t) {
		st: i32
		for posix.waitpid(p, &st, {}) < 0 && posix.errno() == .EINTR {}
	}, self_cleanup = true)
}

// Whether the quit's handover names a successor (a relaunch helper waits for its secret).
relaunch_helper_waiting :: proc() -> bool {return relaunch_helper.fd >= 0}

// The secret to the helper, once ("" = none: the helper then only relaunches), and the pipe closed.
relaunch_helper_send :: proc(secret: string) {
	if relaunch_helper.fd < 0 do return
	line := len(secret) == 64 ? fmt.tprintf("%s\n", secret) : "\n"
	rest := transmute([]u8)line
	defer if len(secret) == 64 do trust.wipe(transmute([]u8)line)
	for len(rest) > 0 {
		n := posix.write(relaunch_helper.fd, raw_data(rest), uint(len(rest)))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do break
		rest = rest[n:]
	}
	posix.close(relaunch_helper.fd)
	relaunch_helper.fd = -1
}

// ---- a core launched as a handover's successor (core_handover.odin) ----

// The secret its launcher gave it (deckhand-core-serve serve: over the ready socket or on stdin),
// for its first HELLO; zeroed once used. All zeros: none.
successor_given: [64]u8

trust_wipe :: proc(b: []u8) {trust.wipe(b)}

// ---- the new app ----

// The successor secret from a relaunch helper waiting in the runtime dir, or "" (none there, not
// ours, or it would not give it to us). Temp allocator; the caller uses it for one HELLO.
successor_secret_take :: proc(run: string) -> string {
	path := fmt.tprintf("%s/%s", strings.trim_right(run, "/"), SUCCESSOR_SOCK)
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK || !posix.S_ISSOCK(st.st_mode) || st.st_uid != posix.getuid() do return ""
	fd, ok := sock_connect(path)
	if !ok do return "" // stale: the helper is gone
	defer sock_close(fd)
	peer, tok := trust.peer_read_token(fd)
	if !peer.ok || peer.euid != u32(posix.geteuid()) do return ""
	// it is a relaunch helper: Deckhand's holder binary, signed as we are
	if exe := holder_pid_exe(peer.pid); !strings.has_suffix(exe, "/" + HOLDER_BIN) {
		fmt.eprintln("Deckhand: successor.sock is not a relaunch helper's: not used")
		return ""
	}
	if why := holder_peer_code_ok(tok); why != "" {
		fmt.eprintln("Deckhand: successor.sock's relaunch helper is refused:", why)
		return ""
	}
	if !sock_write_all(fd, transmute([]u8)fmt.tprintf("%d\n", posix.getpid())) do return ""
	buf: [80]u8
	defer trust.wipe(buf[:]) // the caller's copy is the one kept (and it wipes that)
	n := 0
	deadline := time.tick_add(time.tick_now(), SUCCESSOR_TAKE_WAIT)
	for n < len(buf) && (n == 0 || buf[n - 1] != '\n') {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 || !sock_wait_readable(fd, max(int(time.duration_milliseconds(left)), 1)) do return ""
		r := sock_read(fd, buf[n:])
		if r <= 0 do return ""
		n += r
	}
	line := string(buf[:n])
	if len(line) != 65 || line[64] != '\n' do return ""
	for ch in transmute([]u8)line[:64] do if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') do return ""
	sock_write_all(fd, transmute([]u8)string("ok\n"))
	return strings.clone(line[:64], context.temp_allocator)
}
