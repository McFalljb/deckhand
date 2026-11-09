#+build darwin
package holder

// The supervisor (docs/plans/background-core.md §6 "Core crashes", §7.7): the holder relaunches
// a separate core that crashed, so the sessions get a core back with no window open. Rollback is
// decided here, never by the core that is crashing.
//
// - A separate core says SUPERVISE{core, path} after its WELCOME. Only such a core is watched:
//   an in-process core (the window's) never is.
// - It goes without GOODBYE (a crash: EOF, an error, the pong timeout), or a launch never comes
//   back within SUP_LAUNCH_WAIT: the holder launches one again, after a backoff (1 s, 2 s, 4 s ...
//   30 s), through `<serve> launch` (src/coremain): that runs the launchd launcher, so the core
//   never descends from the holder. Any GOODBYE (a handover, a shutdown, an idle exit) ends the
//   watch: nothing is relaunched.
// - Two crashes within SUP_CRASH_WINDOW: the previous installed core (<data>/core/previous) is
//   launched instead (the update rolled back; its SUPERVISE_STATUS says so, and the core shows it).
// - SUP_HEALTHY attached without a crash: healthy, the counts start over.
// - SUP_MAX_FAILURES launches in a row that never got healthy: it gives up (the window's
//   SUPERVISE{use_previous} starts again).
// - A window (its designated requirement checked) may send SUPERVISE{status} or {use_previous}
//   as its first frame: when its core never comes up it offers Use previous core (P6).
//
// The binary launched is checked first (trust.image_allowed on the file, as UPGRADE's path), and
// again by the launcher on the live process (its ready check, P8).

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../holderwire"
import "../trust"

SUP_CRASH_WINDOW :: 5 * time.Minute
SUP_HEALTHY :: 60 * time.Second
SUP_LAUNCH_WAIT :: 20 * time.Second // a launched core that has not said SUPERVISE by then failed
SUP_BACKOFF_MAX :: 30 * time.Second
SUP_MAX_FAILURES :: 6
SUP_SERVE_BIN :: "deckhand-core-serve"
SUP_O_WRONLY :: 0x0001
SUP_O_APPEND :: 0x0008
SUP_PREVIOUS :: "core/previous/Deckhand Core.app/Contents/MacOS/" + SUP_SERVE_BIN // under the data dir

Supervisor :: struct {
	path:         string, // the serve binary the last separate core named (heap); "" = none watched
	attached:     bool, // that core is attached now
	attached_at:  time.Tick,
	healthy:      bool, // it stayed SUP_HEALTHY
	crashes:      [dynamic]time.Tick, // within SUP_CRASH_WINDOW
	failures:     int, // launches since the last healthy core
	next_launch:  time.Tick, // zero: none planned
	launched_at:  time.Tick, // zero: no launch waiting for its SUPERVISE
	rolled_back:  bool,
	use_previous: bool, // the next launch is the previous core's
	gave_up:      bool,
}

// What the supervisor wants now (pure; supervisor_test.odin drives it on a fake clock).
Sup_Action :: enum {
	None,
	Launch, // launch sup_launch_path's core now
}

sup_backoff :: proc(failures: int) -> time.Duration {
	d := time.Second
	for _ in 1 ..< max(failures, 1) {
		d *= 2
		if d >= SUP_BACKOFF_MAX do return SUP_BACKOFF_MAX
	}
	return d
}

// A separate core said SUPERVISE{core, path}.
sup_core_said :: proc(s: ^Supervisor, path: string, now: time.Tick) {
	if s.path != path {
		delete(s.path)
		s.path = strings.clone(path)
	}
	s.attached, s.attached_at, s.healthy = true, now, false
	s.next_launch, s.launched_at = {}, {}
}

// The watched core said GOODBYE{handover, successor}: its successor must say SUPERVISE within
// SUP_LAUNCH_WAIT, or it counts as a crash (relaunch, then rollback), as a launch of ours does.
sup_successor_named :: proc(s: ^Supervisor, now: time.Tick) {
	if !s.attached do return
	s.attached = false
	s.next_launch, s.launched_at = {}, now
}

// The watched core's connection ended: crashed (no GOODBYE), or said GOODBYE (nothing to relaunch).
sup_core_gone :: proc(s: ^Supervisor, crashed: bool, now: time.Tick) {
	if !s.attached && s.launched_at == {} do return // not a watched core's
	s.attached = false
	s.launched_at = {}
	if !crashed {
		s.next_launch = {}
		return
	}
	sup_failed(s, now)
}

@(private = "file")
sup_failed :: proc(s: ^Supervisor, now: time.Tick) {
	for len(s.crashes) > 0 && time.tick_diff(s.crashes[0], now) > SUP_CRASH_WINDOW do ordered_remove(&s.crashes, 0)
	append(&s.crashes, now)
	s.failures += 1
	if len(s.crashes) >= 2 && !s.rolled_back {
		s.rolled_back, s.use_previous = true, true
	}
	if s.failures >= SUP_MAX_FAILURES {
		s.gave_up = true
		s.next_launch = {}
		return
	}
	s.next_launch = time.tick_add(now, sup_backoff(s.failures))
}

// Every holder turn. core_attached: a core is attached now (any core: never two).
sup_tick :: proc(s: ^Supervisor, now: time.Tick, core_attached: bool) -> Sup_Action {
	if s.attached && !s.healthy && time.tick_diff(s.attached_at, now) >= SUP_HEALTHY {
		s.healthy, s.failures = true, 0
		s.rolled_back, s.use_previous = false, false // a core that stays up: the next crash starts over
		clear(&s.crashes)
	}
	if s.launched_at != {} && time.tick_diff(s.launched_at, now) >= SUP_LAUNCH_WAIT {
		s.launched_at = {}
		sup_failed(s, now) // it never came back
	}
	if s.next_launch == {} || core_attached || s.gave_up || (s.path == "" && !s.use_previous) do return .None
	if time.tick_diff(s.next_launch, now) < 0 do return .None
	s.next_launch = {}
	s.launched_at = now
	return .Launch
}

// The window's Use previous core: the previous core is launched at once (when no core is attached).
sup_use_previous :: proc(s: ^Supervisor, now: time.Tick) {
	s.use_previous, s.gave_up, s.failures = true, false, 0
	s.next_launch = now
}

// The serve binary the next launch runs: the previous installed core's after a rollback (or when
// the window asked), else the one the core named.
sup_launch_path :: proc(s: ^Supervisor, data_dir: string) -> string {
	if s.use_previous do return fmt.tprintf("%s/%s", strings.trim_right(data_dir, "/"), SUP_PREVIOUS)
	return s.path
}

sup_status :: proc(h: ^Holder) -> holderwire.Supervise_Status {
	s := &h.sup
	prev := h.cfg.data_dir != "" && sup_is_file(fmt.tprintf("%s/%s", strings.trim_right(h.cfg.data_dir, "/"), SUP_PREVIOUS))
	return {core = h.core != nil, crashes = i64(len(s.crashes)), rolled_back = s.rolled_back, gave_up = s.gave_up, previous = prev}
}

// The loop's part (timers): launch when due. The launcher (`<serve> launch`) is our child only
// for the launch itself; it is reaped here.
sup_run :: proc(h: ^Holder) {
	for i := len(h.sup_launchers) - 1; i >= 0; i -= 1 {
		st: c.int
		p := h.sup_launchers[i]
		if r := waitpid(p, &st, WNOHANG); r == p || (r < 0 && errno() == ECHILD) do unordered_remove(&h.sup_launchers, i)
	}
	if h.forked do return // a keeper: Security.framework is not safe after fork (keeper.odin)
	if sup_tick(&h.sup, time.tick_now(), h.core != nil) != .Launch do return
	path := sup_launch_path(&h.sup, h.cfg.data_dir)
	if why := sup_launch(h, path); why != "" {
		hlog(h, "supervisor: cannot launch the core %s: %s", path, why)
		h.sup.launched_at = {}
		sup_failed(&h.sup, time.tick_now())
		return
	}
	hlog(h, "supervisor: launched the core %s%s", path, h.sup.use_previous ? " (the previous one)" : "")
}

// `<path> launch --run R --data D`: its file checked first, as UPGRADE's is. "" = started.
@(private = "file")
sup_launch :: proc(h: ^Holder, path: string) -> string {
	if h.cfg.run_dir == "" || h.cfg.data_dir == "" do return "no run or data dir"
	if !strings.has_prefix(path, "/") || !strings.has_suffix(path, "/" + SUP_SERVE_BIN) do return "not a deckhand-core-serve"
	if !sup_is_file(path) do return "no such file"
	if d := trust.image_allowed(.Adhoc, trust.code_identity_self(), trust.code_identity_of_file(path)); d != .Allow do return fmt.tprintf("it failed verification: %v", d)
	tmp := context.temp_allocator
	argv := []cstring{strings.clone_to_cstring(path, tmp), "launch", "--run", strings.clone_to_cstring(h.cfg.run_dir, tmp), "--data", strings.clone_to_cstring(h.cfg.data_dir, tmp), nil}
	log := strings.clone_to_cstring(fmt.tprintf("%s/core.log", h.cfg.run_dir), tmp)
	pid, why := spawn_detached(argv, log)
	if why != "" do return why
	append(&h.sup_launchers, pid)
	return ""
}

// argv[0] started in a session of its own: stdin /dev/null, stdout and stderr appended to log,
// default signals; nothing else of ours (every fd of the holder is close-on-exec). Its pid.
@(private = "file")
spawn_detached :: proc(argv: []cstring, log: cstring) -> (pid: c.int, why: string) {
	sync_lock()
	p := posix.fork()
	if p == 0 {
		posix.setsid()
		null := open("/dev/null", O_RDWR)
		out := open(log, SUP_O_WRONLY | SUP_O_APPEND) // the core's log (its launcher made it); else /dev/null
		if null >= 0 do posix.dup2(posix.FD(null), 0)
		if out < 0 do out = null
		if out >= 0 {
			posix.dup2(posix.FD(out), 1)
			posix.dup2(posix.FD(out), 2)
		}
		reset_signals()
		posix.execv(argv[0], raw_data(argv))
		_exit(127)
	}
	sync_unlock()
	if p < 0 do return 0, fmt.tprintf("fork: errno %d", errno())
	return c.int(p), ""
}

// A window's SUPERVISE as its first frame (instead of HELLO): only a window's code (its designated
// requirement, read on the live connection now), then SUPERVISE_STATUS and the connection closes.
// use_previous launches the previous core now, unless a core is attached.
supervise_window :: proc(h: ^Holder, cn: ^Conn, f: holderwire.Frame) {
	m: holderwire.Supervise
	if holderwire.decode(f, .Supervise, &m, context.temp_allocator) != .None || (m.op != "status" && m.op != "use_previous") {
		conn_drop(h, cn, "a bad SUPERVISE")
		return
	}
	if h.forked {
		conn_drop(h, cn, "SUPERVISE: a keeper does not supervise")
		return
	}
	peer, tok := trust.peer_read_token(posix.FD(cn.fd))
	if trust.peer_still(cn.peer, peer) != .Allow {
		conn_drop(h, cn, "SUPERVISE: the peer changed")
		return
	}
	if d, got := trust.peer_dr_check(tok, h.cfg.window_ids); d != .Allow {
		hlog(h, "refused a SUPERVISE: not a window's code (%v, identifier %q)", d, got.identifier)
		conn_drop(h, cn, "SUPERVISE from a peer that is not a window")
		return
	}
	if m.op == "use_previous" && h.core == nil {
		hlog(h, "supervisor: a window asked for the previous core")
		sup_use_previous(&h.sup, time.tick_now())
	}
	send_msg(cn, .Supervise_Status, 0, sup_status(h))
	conn_close_after(cn)
}

// A regular file (posix.stat, as upgrade.odin: core:os's stat beside it trips the compiler at -o:speed).
@(private = "file")
sup_is_file :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK && posix.S_ISREG(st.st_mode)
}
