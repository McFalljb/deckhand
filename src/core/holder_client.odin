package core

// The app's side of the session holder (src/holder; docs/plans/background-core.md §3, §5.7,
// §7.2). With the setting keep_sessions on, tab processes are spawned by the holder, which
// owns their PTYs and keeps them running while Deckhand is closed; this file is the one
// connection to it. A held Pty (pty.odin: held != 0) routes every pty_* call here.
//
//   holder_client_start() -> bool   connect (launching a holder if keep_sessions is on), WELCOME
//   holder_spawn(...) -> (Pty, ok)  SPAWN, wait for SPAWNED (≤ 5 s)
//   holder_pull(id, reader)         OUTPUT received for a terminal into its Term's inbox
//   holder_handover() / holder_shutdown()   at quit (GOODBYE)
//   holder_upgrade(path) -> Holder_Upgrade_Result   the holder re-execs into another binary in place
//                                   (§7.3): sessions, pids and terminal ids stay; blocks ≤ 50 s
//   holder_upgrade_wanted() -> bool  the attached holder is older than the bundled one and can
//                                   upgrade (not rev 1, not an upgrade's keeper)
//   holder_upgrade_unavailable() -> string  why an older holder can't upgrade ("" if it can or
//                                   is not older): plain, to say once
//
// Trust: the peer is read at connect (trust.peer_allowed) and again before every read is
// acted on (trust.peer_still); the WELCOME must come from that pid (trust.welcome_peer_ok).
// Everything from the holder is checked before use: frames by holderwire (sizes, JSON shape),
// the key's length, ids (non-zero, unique), TAIL starts against the WELCOME offsets. A failure
// at the handshake closes the connection and the app runs without a holder; one later is
// "holder lost": every held terminal ends (unknown exit) and its tab says the holder stopped.
//
// Threads: the main thread connects, spawns and writes; a reader thread decodes frames into
// the Held entries (hc.mu) and pings every 5 s (so a paused frame loop never gets us dropped).
// Writes take hc.wmu and are whole frames; a write that fails or blocks 5 s (SO_SNDTIMEO) shuts
// the socket (half a frame may be out), which loses the holder.

import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import hw "../holderwire"
import "../trust"

HOLDER_WAIT :: 5 * time.Second // the socket after a launch, WELCOME + TAILs, SPAWNED, GOODBYE_ACK
HOLDER_MAX_TERMS :: 4096
HOLDER_FG_EVERY :: 250 * time.Millisecond // FOREGROUND at most this often per terminal
// A refused connect is tried again after each of these (macOS refuses on a full listen backlog
// too: a busy live holder); 750 ms in all before its socket is taken for a dead one's.
HOLDER_RECHECKS := [?]time.Duration{50 * time.Millisecond, 100 * time.Millisecond, 200 * time.Millisecond, 400 * time.Millisecond}
HOLDER_RESCAN :: 300 * time.Millisecond // the sockets are looked at again after a silent holder

// One holder terminal as the app knows it. hc.mu guards every field after the reader started.
Held :: struct {
	id:          u32,
	pid, pgid:   i32,
	buf:         [dynamic]u8, // received, not pulled yet (at the front, after a WELCOME: the TAIL)
	next:        u64, // the stream offset after the last byte received
	tail_start:  u64, // WELCOME: the TAIL's start offset
	tail_len:    int, // WELCOME: the TAIL bytes at the front of buf, until adopted
	cols, rows:  u16, // WELCOME: its size
	exit:        Exit_Info, // known once it ended (EXITED, or `exit` in WELCOME)
	eof:         bool, // no more output: it exited, or the holder is lost
	lost:        bool, // the holder went away (or listed it with a bad size)
	gap:         bool, // OUTPUT did not continue where the last one ended (a holder bug): inexact
	fg:          i32, // FOREGROUND_IS (0 unknown)
	fg_asked:    time.Tick,
	spawn:       enum u8 {Waiting, Spawned, Failed},
	welcomed:    bool, // listed in this connection's WELCOME (the adopt candidates)
	claimed:     bool, // a restored tab adopted it
	kept:        bool, // listed, no tab took it, not safe to hang up: runs on unseen, its output dropped
	degraded:    bool, // not the holder's child: a keeper serves it after a failed upgrade (§7.3 step 6)
}

// What holder_upgrade did. Neither ok nor adopted: the holder refused or could not start the
// new binary and carries on as it was, the same connection, sessions and wire (the fallback
// drain, §7.3 step 7: in M1 the old holder also keeps taking new tabs; a second holder for them
// waits for a holder whose wire is too old for this app, which none is yet).
Holder_Upgrade_Result :: struct {
	ok:         bool, // the holder runs the new binary: same pid, same instance, every session kept
	adopted:    bool, // the new image did not take over (it crashed, failed verification or never
	                  // connected): the upgrade's keeper serves the sessions, degraded
	lost:       bool, // the holder is gone (its sessions end as "the session holder stopped")
	timed_out:  bool, // no outcome within HOLDER_UPGRADE_WAIT: it may still succeed or be adopted
	error:      string, // why not ok (UPGRADE_FAILED's error, or the keeper's); heap
	holder_rev: i64, // what answered after it
	pid:        i32,
}

Holder_Client :: struct {
	mu:        sync.Mutex,
	cond:      sync.Cond, // SPAWNED, SPAWN_FAILED, GOODBYE_ACK or loss
	wmu:       sync.Mutex, // whole frames to fd
	fd:        Sock_Fd,
	peer:      trust.Peer, // at connect
	on:        bool, // WELCOMEd and serving
	lost:      bool,
	tried:     bool, // a start was tried this run (no retry: no automatic relaunch in M1)
	handed:    bool, // GOODBYE sent: nothing more goes to the holder
	handover:  bool, // that GOODBYE was a handover: the held tabs are saved for the next launch
	instance:  string,
	previous:  string, // WELCOME.previous: none | handover | crash | upgrade
	pid:       i32,
	key:       [MACFILE_KEY_LEN]u8,
	held:      map[u32]^Held,
	next_id:   u32,
	rx:        hw.Stream,
	reader:    ^thread.Thread,
	stop:      bool,
	acked:     bool,
	ack:       map[u32]u64, // GOODBYE_ACK: id -> offset
	successor: [64]u8, // GOODBYE_ACK's successor secret (hex), until it goes to the relaunch helper
	successor_len: int,
	refused_secret: bool, // a HELLO was refused for want of the successor secret: an update is relaunching another Deckhand
	successor_retry: time.Tick, // after REFUSED{secret}: when the reservation has lapsed and the attach is tried again (zero: none)
	successor_retries: int,
	dying:     [dynamic]i32, // pids of released terminals, until they are gone (pty_dying)
	tokens_loaded: bool, // tokens.json verified at attach (socket_tokens_enable)
	tokens_why:    string, // why not
	adopt_done:    bool, // the launch's adopt ran: terminals a later WELCOME lists are kept unseen
	unreachable:   bool, // a holder answered but did not attach (Warn_Running): it may run kept sessions
	path:      string, // the socket connected to (an upgrade reconnects to it)
	holder_rev: i64, // WELCOME.holder_rev
	upgrading: bool, // UPGRADE sent, no outcome yet: frames wait in pending (wmu)
	upgrade_told: bool, // the user was told a tab opened meanwhile is not kept (holder_wanted)
	pending:   [dynamic]u8, // whole frames held back during an upgrade (wmu), sent after it
	up_done:   bool, // the outcome is in up_result (mu)
	up_result: Holder_Upgrade_Result,
	upgrade_error_seen: string, // the last WELCOME's upgrade_error (a keeper serves)
	refused_pid:  i32, // a holder whose code is not ours answered (Refused_Code): the user is asked (state.holder_ask)
	refused_path: string, // its socket
	hung_since:   time.Tick, // a holder answered but never WELCOMEd (Warn_Running): its held_away tabs wait at most PONG_TIMEOUT
	rollback_told: bool, // SUPERVISE_STATUS said rolled_back: said once
}

hc := Holder_Client{fd = -1}
holder_send_timeout := HOLDER_WAIT // a send blocked this long fails (SO_SNDTIMEO; tests lower it)
holder_test_allowed: bool // unit tests: a test that wants a holder says so
// The identifiers a holder's code may have (P9, holder_peer_code_ok). The unit tests' fake holder
// runs in the test binary itself and sets the test binary's own; a constant in release builds.
when TEST_HOOKS {
	holder_peer_ids: []string = trust.CORE_IDS
} else {
	holder_peer_ids :: trust.CORE_IDS
}

// "" if the code of the process a holder socket's token names (read at connect, before any byte)
// has the holder's designated requirement as our own signature gives it (trust.peer_dr_check:
// dev.deckhand.core, and under the self-signed identity our certificate), else why not.
holder_peer_code_ok :: proc(tok: trust.Audit_Token) -> string {
	d, got := trust.peer_dr_check(tok, holder_peer_ids)
	if d == .Allow do return ""
	return fmt.tprintf("its code: %v (identifier %q, status %d)", d, got.identifier, got.status)
}

// ---- pure helpers (holder_client_test.odin) ----

// "holder-<8 lowercase hex>.sock": the holder's socket name (src/holder holder_listen).
holder_sock_name_ok :: proc(name: string) -> bool {
	if len(name) != len("holder-xxxxxxxx.sock") || !strings.has_prefix(name, "holder-") || !strings.has_suffix(name, ".sock") do return false
	for ch in name[7:15] do if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') do return false
	return true
}

// Where OUTPUT{start} of n bytes goes, the stream being at next: skip the first `skip` bytes
// (already received: an overlap), and gap if bytes between next and start never came.
held_output_place :: proc(next, start: u64, n: int) -> (skip: int, gap: bool) {
	if start > next do return 0, true
	over := next - start
	if over >= u64(n) do return n, false
	return int(over), false
}

// Adopting a terminal whose snapshot is at snap_offset, the holder's TAIL covering
// [tail_start, tail_end): skip the overlap. exact when the tail starts at or before the
// snapshot; ok false when the snapshot is ahead of everything the holder printed (not this
// terminal's: fall back to a fresh terminal fed the whole tail).
held_tail_skip :: proc(snap_offset, tail_start, tail_end: u64) -> (skip: int, exact, ok: bool) {
	if tail_start > tail_end || snap_offset > tail_end do return 0, false, false
	if tail_start > snap_offset do return 0, false, true // bytes between the two are gone: inexact
	return int(snap_offset - tail_start), true, true
}

// Whether a launch hangs up a holder terminal that no restored tab took (holder_adopt_all):
// only when nothing can be lost: it already ended, or the saved workspace restored cleanly (not
// missing, --fresh or moved aside), was saved with this holder, and listed this terminal (so a
// tab knew it and could not take it). Otherwise it is kept running, unseen: a pi or Claude the
// launch knows nothing about is never hung up.
held_release_unclaimed :: proc(ended, clean, same_holder, listed: bool) -> bool {
	return ended || (clean && same_holder && listed)
}

holder_kept_text :: proc(n: int) -> string {
	return fmt.tprintf("%d kept session%s restored: %s running in the session holder. Quit Deckhand and Stop All Sessions ends %s.", n, n == 1 ? " wasn't" : "s weren't", n == 1 ? "it keeps" : "they keep", n == 1 ? "it" : "them")
}

// The first holder_rev that takes UPGRADE (rev 1 answers "this holder does not upgrade yet").
HOLDER_UPGRADE_MIN_REV :: 2

// Whether a holder of holder_rev `running` should be upgraded to the bundled one (§7.3: only when
// it is older; a newer holder is never downgraded) and can be: not rev 1, not an upgrade's keeper
// (a fork that never exec'd: it refuses, and ends once its sessions do).
holder_upgradable :: proc(running, bundled: i64, keeper: bool) -> bool {
	return running >= HOLDER_UPGRADE_MIN_REV && running < bundled && !keeper
}

// An exit as the holder reports it; code -1: it ended unseen (an orphan adopted after a failed
// upgrade, gone before its keeper watched it), unknown.
exit_of_wire :: proc(code, signal: i64) -> Exit_Info {
	if code < 0 && signal == 0 do return {}
	return {known = true, code = int(clamp(code, 0, 255)), signal = int(clamp(signal, 0, 127))}
}

// ---- connecting ----

// The holder serving this data dir, connected and WELCOMEd. Tried once per run: with
// keep_sessions on (a holder is launched when none answers), or off when a holder socket is
// there (sessions from an earlier run are adopted even after the setting went off).
holder_client_start :: proc() -> bool {
	if hc.on do return true
	if hc.tried || home_root == "" do return false
	when ODIN_TEST {
		if !holder_test_allowed do return false // unit tests never find, launch or adopt a holder
	}
	run, why := sock_runtime_dir_why(context.temp_allocator)
	if why != "" do return false
	socks := holder_socks(run)
	if len(socks) == 0 && !state.settings.keep_sessions do return false // nothing to adopt; tried again once the setting is on
	// relaunched by an update (holder_successor.odin), or a handover's successor core
	// (core_handover.odin): the secret the holder waits for
	secret: string
	if successor_given[0] != 0 {
		secret = strings.clone(string(successor_given[:]), context.temp_allocator)
		trust.wipe(successor_given[:])
	} else do secret = successor_secret_take(run)
	defer for &b in transmute([]u8)secret do b = 0
	answered := false
	// a holder that took the connection and closed it (or never answered) without a byte may have
	// been shutting down: looked for again once, a moment later (gone by then: none runs)
	// (a socket that is still there then is not tried again: a hung holder would cost 5 s more)
	silent := make([dynamic]string, context.temp_allocator)
	for pass in 0 ..< 2 {
		quiet := false
		next: for path in socks {
			for q in silent do if q == path {
				answered = true
				continue next
			}
			r := holder_connect(path, secret)
			// macOS also refuses when the listen backlog is full: a busy live holder. Tried again,
			// with backoff, before its socket is taken for a dead one's (only a refusal: .Stale)
			for wait in HOLDER_RECHECKS {
				if r != .Stale do break
				time.sleep(wait)
				r = holder_connect(path, secret)
			}
			switch r {
			case .Welcomed:
				hc.tried = true
				return true
			case .Answered:
				answered = true
			case .Refused_Code:
				answered = true
				if hc.refused_pid == 0 {
					hc.refused_pid = refused_code_pid
					delete(hc.refused_path)
					hc.refused_path = strings.clone(path)
				}
			case .Quiet:
				if pass == 0 {
					quiet = true
					append(&silent, path)
				} else do answered = true
			case .Stale:
				fmt.eprintln("Deckhand: session holder: removing a dead holder's socket", path)
				sock_unlink(path)
			}
		}
		if !quiet do break
		time.sleep(HOLDER_RESCAN)
		socks = holder_socks(run)
	}
	if hc.refused_secret {
		// the holder waits (at most SUCCESSOR_TTL) for the Deckhand an update relaunches with its
		// secret, and this HELLO had none that fits (another copy, or the successor whose secret
		// never came): never a second holder beside it, and the tabs it keeps wait for it
		// (held_away, as for any holder that answers without a WELCOME: holder_adopt_all). The
		// attach is tried again once the reservation has lapsed (holder_successor_retry_tick).
		hc.tried, hc.unreachable = true, true
		if hc.successor_retries < SUCCESSOR_RETRIES do hc.successor_retry = time.tick_add(time.tick_now(), hw.SUCCESSOR_TTL + 2 * time.Second)
		fmt.eprintln("Deckhand: session holder: it is reserved for the Deckhand an update relaunches; trying again once that lapses")
		window_toast("The session holder is reserved for the Deckhand an update is starting. Its sessions come back here in about a minute if that Deckhand doesn't take them; tabs opened now stop when Deckhand quits.", err = true)
		return false
	}
	switch trust.holder_start(answered, state.settings.keep_sessions) {
	case .Without:
		return false // only dead holders' sockets (removed): tried again once the setting is on
	case .Warn_Running:
		hc.tried, hc.unreachable = true, true
		if hc.refused_pid != 0 {
			// another build's holder: never a silent second one, and nothing of ours goes to it. The
			// user is asked once whether to stop it (Holder_Replace; the window shows state.holder_ask)
			n := holder_children(hc.refused_pid)
			fmt.eprintln("Deckhand: session holder: one from another build runs (pid", hc.refused_pid, ",", n, "sessions): asking whether to replace it")
			state.holder_ask = {pid = hc.refused_pid, sessions = n}
			window_state_changed()
			return false
		}
		hc.hung_since = time.tick_now()
		fmt.eprintln("Deckhand: session holder: one runs but does not answer; no second one is started, new tabs stop at quit")
		window_toast("The session holder isn't answering: tabs opened now stop when Deckhand quits. Sessions it keeps aren't shown.", err = true)
		return false
	case .Launch:
	}
	hc.tried = true
	bin := holder_bin_find(context.temp_allocator)
	if bin == "" {
		fmt.eprintln("Deckhand: session holder: deckhand-core not found; sessions stop at quit")
		return false
	}
	exe, iok, iwhy := holder_install(bin, home_root)
	if !iok {
		fmt.eprintln("Deckhand: session holder: install failed:", iwhy)
		return false
	}
	defer delete(exe)
	before := holder_socks(run)
	if _, lok, lwhy := holder_launch(exe, run, home_root, nil); !lok {
		fmt.eprintln("Deckhand: session holder: cannot start it:", lwhy)
		return false
	}
	deadline := time.tick_now()
	for time.tick_since(deadline) < HOLDER_WAIT {
		outer: for path in holder_socks(run) {
			for b in before do if b == path do continue outer
			if holder_connect(path, "") == .Welcomed do return true
		}
		time.sleep(20 * time.Millisecond)
	}
	fmt.eprintln("Deckhand: session holder: it did not answer within 5 s")
	return false
}

// The holder sockets in the runtime dir (temp): sockets of ours with the holder's name.
@(private = "file")
holder_socks :: proc(run: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	files, err := os.read_all_directory_by_path(run, context.temp_allocator)
	if err != nil do return nil
	for f in files {
		if !holder_sock_name_ok(f.name) do continue
		st: posix.stat_t
		if posix.lstat(strings.clone_to_cstring(f.fullpath, context.temp_allocator), &st) != .OK do continue
		if !posix.S_ISSOCK(st.st_mode) || st.st_uid != posix.getuid() do continue
		append(&out, f.fullpath)
	}
	return out[:]
}

@(private = "file")
set_timeouts :: proc(fd: Sock_Fd) {
	us := i64(time.duration_microseconds(holder_send_timeout))
	tv := posix.timeval{tv_sec = posix.time_t(us / 1_000_000), tv_usec = posix.suseconds_t(us % 1_000_000)}
	posix.setsockopt(fd, posix.SOL_SOCKET, .SNDTIMEO, &tv, size_of(tv))
}

Connect_Result :: enum {
	Welcomed, // attached
	Answered, // something listens there but gave no usable WELCOME: a holder runs (trust.holder_start)
	Stale, // nobody listens (a holder killed with -9: the holder unlinks only its own socket at exit)
	Quiet, // took the connection but closed it, or never answered, without a byte (shutting down?)
	Refused_Code, // a holder of this user whose code is not ours (another build): nothing was sent to it
}

@(private = "file")
handshake_got: int // bytes the handshake read so far (Quiet: none)
@(private = "file")
refused_code_pid: i32 // holder_connect's Refused_Code: the peer's pid

// Connect, check the peer, HELLO, WELCOME and its TAILs; then the reader thread. Anything but
// Welcomed keeps nothing: refused, a stale socket, a bad or lying WELCOME.
@(private = "file")
holder_connect :: proc(path: string, secret: string) -> Connect_Result {
	fd, ok, refused := sock_connect_why(path)
	if !ok do return refused ? .Stale : .Answered // not refused (EACCES, a race): not known dead
	peer, tok := trust.peer_read_token(fd)
	if d := trust.peer_allowed(.Adhoc, trust.own_uid(), peer); d != .Allow {
		fmt.eprintln("Deckhand: session holder: refused its peer:", d)
		sock_close(fd)
		return .Answered
	}
	// its code, before HELLO: SPAWN carries the environment and its tokens (§5.3, P9), HELLO the
	// successor secret. Another build's holder (an older one signed otherwise): the user decides
	if why := holder_peer_code_ok(tok); why != "" {
		fmt.eprintln("Deckhand: session holder: refused its peer:", why)
		sock_close(fd)
		refused_code_pid = peer.pid
		return .Refused_Code
	}
	set_timeouts(fd)
	hc.fd, hc.peer = fd, peer
	rx_reset()
	handshake_got = 0
	fail :: proc(why: string) -> Connect_Result {
		fmt.eprintln("Deckhand: session holder:", why)
		sock_close(hc.fd)
		hc.fd = -1
		for _, h in hc.held do held_free(h)
		clear(&hc.held)
		hw.stream_destroy(&hc.rx)
		hc.rx = {}
		return handshake_got == 0 ? .Quiet : .Answered
	}
	out := make([dynamic]u8, context.temp_allocator)
	hw.encode(&out, .Hello, 0, hw.Hello{wire = hw.WIRE, successor_secret = secret}, secret = secret != "")
	sent := sock_write_all(fd, out[:])
	if secret != "" do trust.wipe(out[:]) // the HELLO held the successor secret
	if !sent do return fail("cannot send HELLO")
	deadline := time.tick_add(time.tick_now(), HOLDER_WAIT)

	f, fok := handshake_frame(deadline)
	if !fok do return fail("no WELCOME")
	if f.kind == u8(hw.Kind.Refused) {
		r: hw.Refused
		hw.decode(f, .Refused, &r, context.temp_allocator)
		if r.code == hw.REFUSE_CODE_NAMES[.Secret] do hc.refused_secret = true
		return fail(fmt.tprintf("refused: %s %s", r.code, r.error))
	}
	w: hw.Welcome
	if e := hw.decode(f, .Welcome, &w, context.temp_allocator); e != .None do return fail(fmt.tprintf("bad WELCOME: %v", e))
	if d := trust.welcome_peer_ok(peer, w.pid); d != .Allow do return fail(fmt.tprintf("WELCOME pid %d is not the socket's peer (%d)", w.pid, peer.pid))
	if w.wire < hw.WIRE_MIN || w.wire > hw.WIRE do return fail(fmt.tprintf("WELCOME wire %d", w.wire))
	if len(w.instance) == 0 || len(w.instance) > 64 do return fail("WELCOME instance")
	key, kok := hex.decode(transmute([]u8)w.hmac_key, context.temp_allocator)
	if !kok || len(key) != MACFILE_KEY_LEN do return fail("WELCOME key is not 32 bytes")
	if len(w.terminals) > HOLDER_MAX_TERMS do return fail("WELCOME lists too many terminals")
	max_id: u32
	for wt in w.terminals {
		if wt.id <= 0 || wt.id > i64(max(u32)) do return fail(fmt.tprintf("WELCOME terminal id %d", wt.id))
		id := u32(wt.id)
		if id in hc.held do return fail(fmt.tprintf("WELCOME lists terminal %d twice", id))
		h := new(Held)
		h.id, h.welcomed, h.next = id, true, wt.offset
		h.lost = wt.bad || wt.pid <= 0 || wt.pid > i64(max(i32)) // a bad size: not adopted (released)
		if !h.lost {
			h.pid, h.pgid = i32(wt.pid), i32(clamp(wt.pgid, 0, i64(max(i32))))
			h.cols, h.rows = u16(wt.cols), u16(wt.rows) // range-checked by holderwire.decode (bad)
		}
		if ex, has := wt.exit.?; has {
			h.exit = exit_of_wire(ex.code, ex.signal)
			h.eof = true
		}
		h.degraded = wt.degraded.? or_else false
		hc.held[id] = h
		max_id = max(max_id, id)
	}
	// one TAIL per listed terminal, in WELCOME's order (src/holder: welcome)
	for wt in w.terminals {
		tf, tok := handshake_frame(deadline)
		if !tok || tf.kind != u8(hw.Kind.Tail) || tf.terminal != u32(wt.id) do return fail("missing TAIL")
		start, bytes, e := hw.decode_output(tf)
		h := hc.held[tf.terminal]
		if e != .None || start + u64(len(bytes)) != h.next || start > h.next do return fail(fmt.tprintf("TAIL of terminal %d does not end at its offset", tf.terminal))
		append(&h.buf, ..bytes)
		h.tail_start, h.tail_len = start, len(bytes)
	}
	hc.instance = strings.clone(w.instance)
	hc.previous = strings.clone(w.previous)
	hc.path = strings.clone(path)
	hc.holder_rev = w.holder_rev
	hc.upgrade_error_seen = strings.clone(w.upgrade_error)
	hc.pid = peer.pid
	copy(hc.key[:], key)
	hc.next_id = max_id + 1
	hc.on, hc.lost, hc.handed, hc.stop = true, false, false, false
	// tokens.json from now on, whenever the holder was attached (at launch or mid-run): its
	// processes keep their tokens across a quit. A new holder's key verifies no older file.
	tpath := fmt.tprintf("%s/tokens.json", strings.trim_right(home_root, "/"))
	if hc.previous == "none" && len(w.terminals) == 0 do os.remove(tpath)
	loaded, twhy := socket_tokens_enable(tpath, hc.key[:])
	delete(hc.tokens_why)
	hc.tokens_loaded, hc.tokens_why = loaded, strings.clone(twhy)
	if hc.adopt_done && len(w.terminals) > 0 {
		// attached after the launch's adopt (a holder that appeared since): nothing claims these.
		// Before the reader starts: from then on hc.mu guards every Held field
		for _, h in hc.held do if h.welcomed {
			h.kept, h.tail_len = true, 0
			clear(&h.buf)
		}
		window_toast(holder_kept_text(len(w.terminals)), err = true)
	}
	hc.reader = thread.create_and_start(holder_reader)
	holder_supervise_me()
	if autotest_active do fmt.printfln("[autotest] holder attached: previous %s, %d terminals%s", hc.previous, len(w.terminals), secret != "" ? ", as the named successor" : "")
	return .Welcomed
}

// An empty hc.rx whose buffer is the heap's. A [dynamic] adopts context.allocator at its first
// append, and the handshake's is on the caller's thread with the caller's allocator (the app
// switches it to temp in places): the reader thread would then append into memory the next
// free_all takes back.
@(private = "file")
rx_reset :: proc() {
	hw.stream_destroy(&hc.rx)
	hc.rx = {buf = make([dynamic]u8, runtime.heap_allocator())}
}

// The next whole frame during the handshake (main thread, before the reader runs).
@(private = "file")
handshake_frame :: proc(deadline: time.Tick) -> (f: hw.Frame, ok: bool) {
	buf: [64 * 1024]u8
	for {
		fr, err := hw.stream_next(&hc.rx)
		if err == .None do return fr, true
		if err == .Too_Large do return {}, false
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 || !sock_wait_readable(hc.fd, max(int(time.duration_milliseconds(left)), 1)) do return {}, false
		n := sock_read(hc.fd, buf[:])
		if n <= 0 do return {}, false
		handshake_got += n
		if trust.peer_still(hc.peer, trust.peer_read(hc.fd)) != .Allow do return {}, false
		hw.stream_feed(&hc.rx, buf[:n])
	}
}

@(private = "file")
held_free :: proc(h: ^Held) {
	delete(h.buf)
	free(h)
}

// ---- the reader thread ----

@(private = "file")
holder_reader :: proc() {
	buf := make([]u8, 256 * 1024)
	defer delete(buf)
	last_ping := time.tick_now()
	// frames that came behind the TAILs are in hc.rx already (handshake_frame read them)
	if !holder_frames() do return
	for !sync.atomic_load(&hc.stop) {
		if time.tick_since(last_ping) >= hw.PING_INTERVAL {
			last_ping = time.tick_now()
			holder_send(.Ping, 0, hw.Empty{})
		}
		// the app is behind (its frame loop paused): stop reading, so the holder stops reading
		// the PTYs (§5.6) and the programs wait, as a direct PTY's reader does (INBOX_CAP)
		sync.lock(&hc.mu)
		backlog := 0
		for _, h in hc.held do backlog = max(backlog, len(h.buf))
		sync.unlock(&hc.mu)
		if backlog > INBOX_CAP {
			time.sleep(time.Millisecond)
			continue
		}
		if !sock_wait_readable(hc.fd, 100) do continue
		n := sock_read(hc.fd, buf)
		why := ""
		if n <= 0 do why = n == 0 ? "the holder closed the connection" : "read failed"
		else if d := trust.peer_still(hc.peer, trust.peer_read(hc.fd)); d != .Allow do why = fmt.tprintf("its peer changed since connect: %v", d)
		if why != "" {
			// mid-upgrade, the old image's connection closes at its exec: the new image (or the
			// keeper) serves the same socket
			if sync.atomic_load(&hc.upgrading) && holder_reattach() {
				// frames that came behind the new image's TAILs are in hc.rx already (a quiet
				// session sends nothing more), as after a first attach
				if !holder_frames() do return
				continue
			}
			holder_lose(why)
			return
		}
		hw.stream_feed(&hc.rx, buf[:n])
		if sync.atomic_load(&hc.handed) do trust.wipe(buf[:n]) // after GOODBYE: the ack may carry the successor secret
		if !holder_frames() do return
		if sync.atomic_load(&hc.upgrading) do upgrade_release() // after UPGRADE_FAILED: what waited goes out
		free_all(context.temp_allocator)
	}
}

// Every whole frame in hc.rx (reader thread); false once the holder is lost.
@(private = "file")
holder_frames :: proc() -> bool {
	for {
		f, err := hw.stream_next(&hc.rx)
		if err == .Need_More do return true
		if err == .Too_Large {
			holder_lose("a frame too large")
			return false
		}
		holder_frame(f)
	}
}

// GOODBYE_ACK's offsets into hc.ack and its successor secret into hc.successor (the one copy, until
// it goes to the relaunch helper); the frame's bytes and the decoded copy are wiped. False: bad.
goodbye_ack_take :: proc(f: hw.Frame) -> bool {
	m: hw.Goodbye_Ack
	e := hw.decode(f, .Goodbye_Ack, &m, context.temp_allocator)
	defer {
		trust.wipe(transmute([]u8)m.successor_secret)
		trust.wipe(f.payload)
	}
	if e != .None do return false
	for a in m.terminals do if a.id > 0 && a.id <= i64(max(u32)) do hc.ack[u32(a.id)] = a.offset
	if len(m.successor_secret) == len(hc.successor) {
		copy(hc.successor[:], m.successor_secret)
		hc.successor_len = len(hc.successor)
	}
	return true
}

// One frame from the holder (reader thread).
@(private = "file")
holder_frame :: proc(f: hw.Frame) {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	h := hc.held[f.terminal] // nil for 0 and unknown ids
	#partial switch hw.Kind(f.kind) {
	case .Output:
		start, bytes, e := hw.decode_output(f)
		if h == nil || e != .None || h.eof do return
		if h.kept {
			h.next = max(h.next, start + u64(len(bytes))) // nobody shows it: the holder keeps its tail
			return
		}
		skip, gap := held_output_place(h.next, start, len(bytes))
		if gap {
			h.gap = true // the bytes in between never came: what follows is still shown
			h.next = start
		}
		if len(h.buf) == 0 && skip < len(bytes) do output_wake() // the main thread took it all: it may sleep (term.odin)
		append(&h.buf, ..bytes[skip:])
		h.next += u64(len(bytes) - skip)
	case .Exited:
		m: hw.Exited
		if h == nil || hw.decode(f, .Exited, &m, context.temp_allocator) != .None do return
		h.exit = exit_of_wire(m.code, m.signal)
		h.eof = true
	case .Spawned:
		m: hw.Spawned
		if h == nil || h.spawn != .Waiting do return
		if hw.decode(f, .Spawned, &m, context.temp_allocator) != .None || m.pid <= 0 || m.pid > i64(max(i32)) {
			h.spawn = .Failed
		} else {
			h.pid, h.pgid, h.spawn = i32(m.pid), i32(clamp(m.pgid, 0, i64(max(i32)))), .Spawned
		}
		sync.cond_broadcast(&hc.cond)
	case .Spawn_Failed:
		m: hw.Spawn_Failed
		if h == nil || h.spawn != .Waiting do return
		if hw.decode(f, .Spawn_Failed, &m, context.temp_allocator) == .None do fmt.eprintln("Deckhand: session holder: spawn failed:", m.error)
		h.spawn = .Failed
		sync.cond_broadcast(&hc.cond)
	case .Foreground_Is:
		m: hw.Foreground_Is
		if h == nil || hw.decode(f, .Foreground_Is, &m, context.temp_allocator) != .None do return
		h.fg = i32(clamp(m.pgid, 0, i64(max(i32))))
	case .Goodbye_Ack:
		if !hc.handed || hc.acked {
			trust.wipe(f.payload)
			return
		}
		if !goodbye_ack_take(f) do return
		hc.acked = true
		sync.cond_broadcast(&hc.cond)
	case .Upgrade_Failed:
		m: hw.Upgrade_Failed
		if !hc.upgrading || hc.up_done do return
		why := "the holder refused the upgrade"
		if hw.decode(f, .Upgrade_Failed, &m, context.temp_allocator) == .None do why = m.error
		upgrade_finish_locked({error = strings.clone(why), holder_rev = hc.holder_rev, pid = hc.pid})
	case .Supervise_Status:
		m: hw.Supervise_Status
		if hw.decode(f, .Supervise_Status, &m, context.temp_allocator) == .None && m.rolled_back && !hc.rollback_told {
			hc.rollback_told = true
			fmt.eprintln("Deckhand: background core: the session holder's supervisor rolled the update back (the new core crashed twice)")
			if autotest_active do fmt.println("[autotest] core: rolled back")
			window_toast("Update rolled back: the updated background core stopped twice, so the previous one runs your sessions.", err = true)
		}
	case .Pong, .Unknown:
	case:
		fmt.eprintln("Deckhand: session holder: ignoring a frame of kind", f.kind)
	}
}

// The holder is gone (reader thread): every held terminal ends, its exit unknown.
@(private = "file")
holder_lose :: proc(why: string) {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	if !hc.handed do fmt.eprintln("Deckhand: session holder lost:", why)
	hc.lost = true
	hc.on = false
	for _, h in hc.held do if !h.eof {
		h.eof, h.lost = true, true
		h.exit = {}
	}
	for _, h in hc.held do if h.spawn == .Waiting do h.spawn = .Failed
	if hc.upgrading && !hc.up_done do upgrade_finish_locked({lost = true, error = strings.clone(why)})
	sock_shutdown(hc.fd) // writers fail at once; the fd is closed by holder_client_stop
	sync.cond_broadcast(&hc.cond)
}

// ---- writing ----

@(private = "file")
holder_send :: proc(kind: hw.Kind, id: u32, msg: $T) -> bool {
	out := make([dynamic]u8, context.temp_allocator)
	if !hw.encode(&out, kind, id, msg) do return false
	return holder_write(out[:])
}

@(private = "file")
holder_write :: proc(frame: []u8) -> bool {
	sync.lock(&hc.wmu)
	defer sync.unlock(&hc.wmu)
	if sync.atomic_load(&hc.lost) || sync.atomic_load(&hc.handed) do return false
	if hc.upgrading {
		// whole frames wait for the new image (INPUT is never split across the exec); a PING or
		// FOREGROUND is only worth sending now. A SPAWN fails at once: queued, holder_spawn would
		// block the main thread for its whole wait, and the holder run it after the tab started
		// directly instead.
		if len(frame) > 0 && frame[0] == u8(hw.Kind.Spawn) do return false
		if len(frame) > 0 && (frame[0] == u8(hw.Kind.Ping) || frame[0] == u8(hw.Kind.Foreground)) do return true
		append(&hc.pending, ..frame)
		return true
	}
	if hc.fd < 0 do return false
	if sock_write_all(hc.fd, frame) do return true
	// a 5 s block (SO_SNDTIMEO) or an error, maybe part-way through the frame: nothing more can
	// follow it on the wire. Shut the socket: the reader sees the end and loses the holder.
	sock_shutdown(hc.fd)
	return false
}

// ---- the Pty side (pty_posix.odin routes held ptys here) ----

// Whether new tab processes go to the holder: keep_sessions on and a holder attached (one is
// connected or launched on first use).
holder_wanted :: proc() -> bool {
	if !state.settings.keep_sessions || hc.lost || hc.handed do return false
	// mid-upgrade a SPAWN would wait for the new image (seconds; holder_spawn gives up after
	// HOLDER_WAIT): a tab opened then runs directly and stops at quit
	if holder_upgrading() {
		if !hc.upgrade_told {
			hc.upgrade_told = true // once per upgrade (holder_upgrade clears it)
			window_toast("The session holder is upgrading: tabs opened in the next few seconds stop when Deckhand quits")
		}
		return false
	}
	return holder_client_start()
}

// Whether held tabs are saved with their terminal ids (workspace.json "held"): while the
// holder keeps sessions at quit, after a handover, and after the holder was lost while it still
// runs (a send timed out, it stopped answering): it keeps them (crash-style) for the next launch,
// whatever the setting says now.
holder_keeps_sessions :: proc() -> bool {
	if hc.handover do return true
	if hc.handed do return false
	if hc.lost do return holder_alive()
	return hc.on && state.settings.keep_sessions
}

// The holder this run attached to still runs (it may be lost: not answering, not gone). Not after
// a GOODBYE: a shutdown hangs everything up.
holder_alive :: proc() -> bool {
	if hc.pid <= 0 || hc.handed do return false
	return posix.kill(posix.pid_t(hc.pid), posix.Signal(0)) == .OK
}

// The holder terminal a tab's process still runs in although this run cannot reach it (held_away
// at launch, or its holder lost mid-run while alive), else 0. Such a tab is never started or
// restarted here: that would be a second pi or Claude on its session file.
tab_held_away :: proc(tab: ^Tab) -> u32 {
	if tab == nil do return 0
	if tab.held_away != 0 do return tab.held_away
	if replica_process do return tab.live.away // the core's (Tab_Live)
	if t := term_of(tab.id); t != nil do return t.holder_away
	return 0
}

HELD_AWAY_TEXT :: "This session still runs in the session holder, which isn't answering. It isn't started here, so it never runs twice: quit and reopen Deckhand to get it back."

// SPAWN through the holder; waits up to HOLDER_WAIT for SPAWNED. The terminal id is picked
// here (max + 1, never reused within this connection).
holder_spawn :: proc(argv: []string, cwd: string, env: []string, cols, rows: u16, xpixel, ypixel: u32) -> (p: Pty, ok: bool) {
	sync.lock(&hc.mu)
	if !hc.on || hc.next_id == 0 {
		sync.unlock(&hc.mu)
		return {}, false
	}
	id := hc.next_id
	hc.next_id += 1
	h := new(Held)
	h.id = id
	hc.held[id] = h // before SPAWN: its first OUTPUT may come right after SPAWNED
	sync.unlock(&hc.mu)
	msg := hw.Spawn{argv = argv, env = env, cwd = cwd, cols = i64(max(cols, 1)), rows = i64(max(rows, 1)), xpixel = i64(min(xpixel, hw.MAX_PIXELS)), ypixel = i64(min(ypixel, hw.MAX_PIXELS))}
	sent := holder_send(.Spawn, id, msg)
	sync.lock(&hc.mu)
	deadline := time.tick_add(time.tick_now(), HOLDER_WAIT)
	for sent && h.spawn == .Waiting {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do break
		sync.cond_wait_with_timeout(&hc.cond, &hc.mu, left)
	}
	ok = sent && h.spawn == .Spawned
	if ok do p = Pty{fd = -1, held = id, pid = h.pid}
	else {
		delete_key(&hc.held, id)
		held_free(h)
	}
	sync.unlock(&hc.mu)
	if sent && !ok do holder_send(.Release, id, hw.Empty{}) // a late SPAWNED: nothing keeps it
	return
}

// Moves what the holder sent for terminal id into a Term's reader inbox (main thread, as
// reader_main does for a direct PTY); eof once nothing more will come.
holder_pull :: proc(id: u32, r: ^Reader) {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	h := hc.held[id]
	sync.lock(&r.mu)
	defer sync.unlock(&r.mu)
	if h == nil {
		r.eof = true
		return
	}
	// at most INBOX_CAP waiting in the Term: past it the reader thread stops reading, the holder
	// stops reading the PTY (§5.6) and the program waits, as with a direct PTY
	if len(h.buf) > 0 && len(r.inbox) < INBOX_CAP {
		append(&r.inbox, ..h.buf[:])
		clear(&h.buf)
	}
	r.eof = h.eof && len(h.buf) == 0
}

// Whether the holder sent output the main thread has not taken yet (output_backlog). Main thread.
holder_output_waiting :: proc() -> bool {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	for _, h in hc.held do if len(h.buf) > 0 && !h.kept do return true
	return false
}

holder_input :: proc(id: u32, data: []u8) {
	for rest := data; len(rest) > 0; {
		n := min(len(rest), hw.MAX_PAYLOAD)
		out := make([dynamic]u8, 0, n + hw.HEADER_SIZE, context.temp_allocator)
		hw.encode_input(&out, id, rest[:n])
		if !holder_write(out[:]) do return
		rest = rest[n:]
	}
}

holder_resize :: proc(id: u32, cols, rows: u16, w_px, h_px: u32) {
	holder_send(.Resize, id, hw.Resize{cols = i64(max(cols, 1)), rows = i64(max(rows, 1)), xpixel = i64(min(w_px, hw.MAX_PIXELS)), ypixel = i64(min(h_px, hw.MAX_PIXELS))})
}

holder_signal_group :: proc(id: u32, sig: i32) {
	holder_send(.Signal, id, hw.Signal{signal = i64(sig), target = "pgroup"})
}

// The tab closed (or its process ended): RELEASE hangs it up in the holder, which forgets it
// once reaped. Not after a GOODBYE: the holder keeps it for the next launch.
holder_release :: proc(id: u32) {
	sync.lock(&hc.mu)
	h := hc.held[id]
	handed := hc.handed
	if h != nil {
		if !handed && !h.eof && h.pid > 0 do append(&hc.dying, h.pid)
		delete_key(&hc.held, id)
		held_free(h)
	}
	sync.unlock(&hc.mu)
	if !handed do holder_send(.Release, id, hw.Empty{})
}

// The cached foreground process group (0 unknown); asks again at most every HOLDER_FG_EVERY.
holder_foreground :: proc(id: u32) -> i32 {
	sync.lock(&hc.mu)
	h := hc.held[id]
	if h == nil || h.eof {
		sync.unlock(&hc.mu)
		return 0
	}
	fg := h.fg
	ask := time.tick_since(h.fg_asked) >= HOLDER_FG_EVERY
	if ask do h.fg_asked = time.tick_now()
	sync.unlock(&hc.mu)
	if ask do holder_send(.Foreground, id, hw.Empty{})
	return fg
}

// How it ended once it did: reaped = no more process (exit unknown when the holder was lost).
holder_exit :: proc(id: u32) -> (e: Exit_Info, ended: bool) {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	h := hc.held[id]
	if h == nil do return {}, true
	return h.exit, h.eof && (h.exit.known || h.lost)
}

holder_term_lost :: proc(id: u32) -> bool {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	h := hc.held[id]
	return h == nil || h.lost
}

// A released terminal's process is still there (a restart of pi waits for it, as for
// pty_dying). Same-user kill(0): true until the holder reaped it.
holder_dying :: proc(pid: i32) -> bool {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	for i := len(hc.dying) - 1; i >= 0; i -= 1 {
		if posix.kill(posix.pid_t(hc.dying[i]), posix.Signal(0)) != .OK && posix.errno() == .ESRCH do unordered_remove(&hc.dying, i)
	}
	for d in hc.dying do if d == pid do return true
	return false
}

// ---- quit ----

// GOODBYE{shutdown} ("Quit Deckhand and Stop All Sessions"): the holder hangs up everything.
holder_shutdown :: proc() {
	if !hc.on || hc.handed do return
	holder_goodbye("shutdown")
}

// The last frame this connection sends: after it nothing goes out (no RELEASE at close_all).
// Never into an upgrade: it waits until the upgrade is over and the frames held back during it
// went out (a queued RELEASE first), at most holder_quit_upgrade_wait, calling pump (output into
// the terminals: the reader must not stall at its backlog cap before it sees the exec) or, for
// none, dropping what came. Still upgrading then: no GOODBYE, the app leaves crash-style
// (holder_leave: the holder keeps every terminal for the next launch, restored from its tails).
holder_goodbye :: proc(mode: string, pump: proc(data: rawptr) = nil, data: rawptr = nil, successor := false) -> bool {
	out := make([dynamic]u8, context.temp_allocator)
	hw.encode(&out, .Goodbye, 0, hw.Goodbye{mode = mode, successor = successor})
	deadline := time.tick_add(time.tick_now(), holder_quit_upgrade_wait)
	sync.lock(&hc.wmu)
	for hc.upgrading && !sync.atomic_load(&hc.lost) && !sync.atomic_load(&hc.handed) {
		sync.unlock(&hc.wmu)
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			fmt.eprintln("Deckhand: session holder: still upgrading at quit: leaving it the sessions (no GOODBYE)")
			holder_leave()
			return false
		}
		if pump != nil {
			pump(data)
		} else {
			sync.lock(&hc.mu)
			for _, h in hc.held do clear(&h.buf)
			sync.unlock(&hc.mu)
		}
		time.sleep(10 * time.Millisecond)
		sync.lock(&hc.wmu)
	}
	defer sync.unlock(&hc.wmu)
	if sync.atomic_load(&hc.handed) do return false
	sync.lock(&hc.mu)
	hc.handed = true // before it goes: the reader takes a GOODBYE_ACK only after a GOODBYE
	sync.unlock(&hc.mu)
	if hc.fd < 0 || sync.atomic_load(&hc.lost) do return false
	if sock_write_all(hc.fd, out[:]) do return true
	sock_shutdown(hc.fd) // part of it may be out (holder_write)
	return false
}

// Quit without a GOODBYE, the sessions kept (holder_handover could not write the handover):
// nothing more goes to the holder (no RELEASE at close_all), and the socket is shut, so the
// holder sees a crash and keeps every terminal for the next launch.
holder_leave :: proc() {
	sync.lock(&hc.wmu)
	defer sync.unlock(&hc.wmu)
	sync.lock(&hc.mu)
	hc.handed, hc.handover = true, true
	sync.unlock(&hc.mu)
	if hc.fd >= 0 do sock_shutdown(hc.fd)
}

// ---- upgrade (§7.3) ----

// The holder's worst case (src/holder upgrade.odin, keeper.odin): before the exec, the core's
// flush (3 s) and the dry run (5 s to report, 5 s to exit); after it, until anything answers on
// the socket, the keeper's waits for the new image's hello (10 s), its taking the state (10 s)
// and its DONE (10 s, then it is killed and the keeper adopts). The reattach covers the latter,
// the whole wait both.
HOLDER_REATTACH_WAIT :: 35 * time.Second
HOLDER_UPGRADE_WAIT :: 13 * time.Second + HOLDER_REATTACH_WAIT + 2 * time.Second
// At quit, an upgrade in flight is waited for this long, then the app leaves crash-style.
holder_quit_upgrade_wait := 10 * time.Second

// Whether the attached holder should and can be upgraded to the one this app bundles:
// holder_upgrade_tick (holder_restart.odin) then upgrades it once, after the launch's adopt.
holder_upgrade_wanted :: proc() -> bool {
	bundled := holder_rev_bundled()
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	return hc.on && !hc.lost && !hc.handed && holder_upgradable(hc.holder_rev, bundled, hc.upgrade_error_seen != "")
}

// Why the attached holder, older than the bundled one, cannot be upgraded in place ("" when it
// can, or is not older): plain words to say once, never an error.
holder_upgrade_unavailable :: proc() -> string {
	bundled := holder_rev_bundled()
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	if !hc.on || hc.lost || hc.handed || hc.holder_rev < 1 || hc.holder_rev >= bundled do return ""
	if hc.upgrade_error_seen != "" do return "Your kept sessions are running in a backup session holder after an update didn't take; it's replaced once those sessions end."
	if hc.holder_rev < HOLDER_UPGRADE_MIN_REV do return "Your kept sessions are running in an older session holder that can't be updated in place; it's replaced once those sessions end."
	return ""
}

// HOLDER_REV, or in a test build DECKHAND_HOLDER_REV (a scene makes the running holder look old).
@(private = "file")
holder_rev_bundled :: proc() -> i64 {
	if v := hook_env(.Holder_Rev); v != "" {
		if n, ok := strconv.parse_i64(v); ok do return n
	}
	return HOLDER_REV
}

// An upgrade is in flight (UPGRADE sent, no outcome yet).
holder_upgrading :: proc() -> bool {
	return sync.atomic_load(&hc.upgrading) // cleared once what waited has gone out (upgrade_release)
}

// UPGRADE{path}: the holder re-execs into the binary at path (an absolute path to an installed,
// verified deckhand-core: holder_install's result), keeping every session, its pid and its
// terminal id, and its instance id (held tabs saved with it still adopt). Blocks until the
// outcome (≤ HOLDER_UPGRADE_WAIT; any thread but the holder reader). Meanwhile frames for the
// holder (input, resizes, spawns, releases) wait and go to the new image whole, in order.
// result.error is heap (the caller deletes it).
holder_upgrade :: proc(path: string) -> Holder_Upgrade_Result {
	out := make([dynamic]u8, context.temp_allocator)
	hw.encode(&out, .Upgrade, 0, hw.Upgrade{path = path})
	sync.lock(&hc.wmu)
	sync.lock(&hc.mu)
	if !hc.on || hc.lost || hc.handed || hc.fd < 0 || hc.upgrading {
		busy := hc.upgrading
		sync.unlock(&hc.mu)
		sync.unlock(&hc.wmu)
		return {error = strings.clone(busy ? "an upgrade is already running" : "no session holder is attached")}
	}
	hc.upgrading, hc.up_done, hc.upgrade_told = true, false, false
	sync.unlock(&hc.mu)
	sent := sock_write_all(hc.fd, out[:])
	sync.unlock(&hc.wmu)
	if !sent {
		sync.lock(&hc.mu)
		if !hc.up_done do upgrade_finish_locked({error = strings.clone("cannot send UPGRADE")})
		sync.unlock(&hc.mu)
		upgrade_release()
	}
	upgrade_wait(HOLDER_UPGRADE_WAIT)
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	if !hc.up_done do return {timed_out = true, error = strings.clone("the holder did not finish the upgrade in time")} // the reader still settles it
	r := hc.up_result
	hc.up_result = {}
	return r
}

// Waits (≤ d) for an upgrade in flight to end.
@(private = "file")
upgrade_wait :: proc(d: time.Duration) {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	deadline := time.tick_add(time.tick_now(), d)
	for hc.upgrading && !hc.up_done {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return
		sync.cond_wait_with_timeout(&hc.cond, &hc.mu, left)
	}
}

// The outcome (hc.mu held); upgrade_release then sends what waited.
@(private = "file")
upgrade_finish_locked :: proc(r: Holder_Upgrade_Result) {
	delete(hc.up_result.error)
	hc.up_result, hc.up_done = r, true
	sync.cond_broadcast(&hc.cond)
}

// Once there is an outcome: the frames held back go out (unless the holder is lost) and frames
// flow again. Takes wmu, then mu (holder_upgrade's order).
upgrade_release :: proc() {
	sync.lock(&hc.wmu)
	defer sync.unlock(&hc.wmu)
	sync.lock(&hc.mu)
	done := hc.up_done
	sync.unlock(&hc.mu)
	if !hc.upgrading || !done do return
	hc.upgrading = false
	if len(hc.pending) > 0 && hc.fd >= 0 && !sync.atomic_load(&hc.lost) && !sock_write_all(hc.fd, hc.pending[:]) {
		sock_shutdown(hc.fd) // part of it may be out (holder_write): the reader loses the holder
	}
	clear(&hc.pending)
}

// The reader thread, mid-upgrade, saw the old connection end: connect to the same socket again
// (the new image, or the keeper, listens on it), HELLO, check the WELCOME is the same holder run
// (instance and key), then continue every terminal's stream from its TAIL. False: lost.
@(private = "file")
holder_reattach :: proc() -> bool {
	sync.lock(&hc.wmu)
	if hc.fd >= 0 do sock_close(hc.fd)
	hc.fd = -1
	sync.unlock(&hc.wmu)
	old_pid := hc.pid
	deadline := time.tick_add(time.tick_now(), HOLDER_REATTACH_WAIT)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		fd, ok := sock_connect(hc.path)
		if !ok {
			time.sleep(20 * time.Millisecond)
			continue
		}
		why, done := holder_reattach_on(fd, deadline)
		if done {
			sync.lock(&hc.mu)
			res := Holder_Upgrade_Result{holder_rev = hc.holder_rev, pid = hc.pid}
			switch {
			case hc.upgrade_error_seen != "":
				res.adopted = true
				res.error = strings.clone(hc.upgrade_error_seen)
			case hc.pid != old_pid:
				res.error = strings.clone("another process answered for the holder")
			case:
				res.ok = true
			}
			upgrade_finish_locked(res)
			sync.unlock(&hc.mu)
			upgrade_release()
			holder_supervise_me() // a new image starts with no supervisor state
			if autotest_active do fmt.printfln("[autotest] holder upgraded: ok %v, adopted %v, holder_rev %d", res.ok, res.adopted, res.holder_rev)
			return true
		}
		if !strings.has_prefix(why, "retry") {
			fmt.eprintln("Deckhand: session holder: after the upgrade:", why)
			return false
		}
		time.sleep(20 * time.Millisecond)
	}
	return false
}

// One reattach attempt on a connected fd. done: attached (hc.fd is fd). Otherwise fd is closed;
// why starts with "retry" when another attempt may work.
@(private = "file")
holder_reattach_on :: proc(fd: Sock_Fd, deadline: time.Tick) -> (why: string, done: bool) {
	peer, tok := trust.peer_read_token(fd)
	if d := trust.peer_allowed(.Adhoc, trust.own_uid(), peer); d != .Allow {
		sock_close(fd)
		return fmt.tprintf("refused its peer: %v", d), false
	}
	// the new image (or the keeper) is checked again, as at a first attach (P9): the keeper only
	// checked its identifier (trust.image_allowed)
	if w := holder_peer_code_ok(tok); w != "" {
		sock_close(fd)
		return fmt.tprintf("refused its peer: %s", w), false
	}
	set_timeouts(fd)
	rx_reset()
	sync.lock(&hc.wmu)
	hc.fd, hc.peer = fd, peer
	sync.unlock(&hc.wmu)
	fail :: proc(why: string) -> (string, bool) {
		sync.lock(&hc.wmu)
		sock_close(hc.fd)
		hc.fd = -1
		sync.unlock(&hc.wmu)
		return why, false
	}
	out := make([dynamic]u8, context.temp_allocator)
	hw.encode(&out, .Hello, 0, hw.Hello{wire = hw.WIRE})
	if !sock_write_all(fd, out[:]) do return fail("retry: cannot send HELLO")
	f, fok := handshake_frame(deadline)
	if !fok do return fail("retry: no WELCOME")
	if f.kind == u8(hw.Kind.Refused) do return fail("refused")
	w: hw.Welcome
	if e := hw.decode(f, .Welcome, &w, context.temp_allocator); e != .None do return fail(fmt.tprintf("bad WELCOME: %v", e))
	if d := trust.welcome_peer_ok(peer, w.pid); d != .Allow do return fail("WELCOME pid is not the socket's peer")
	if w.wire < hw.WIRE_MIN || w.wire > hw.WIRE do return fail("WELCOME wire")
	// the same holder run: an upgrade keeps its instance and its key
	key, kok := hex.decode(transmute([]u8)w.hmac_key, context.temp_allocator)
	if w.instance != hc.instance || !kok || len(key) != MACFILE_KEY_LEN || string(key) != string(hc.key[:]) do return fail("a different holder answered (instance or key)")
	if len(w.terminals) > HOLDER_MAX_TERMS do return fail("WELCOME lists too many terminals")
	listed := make(map[u32]bool, len(w.terminals), context.temp_allocator)
	for wt in w.terminals {
		if wt.id <= 0 || wt.id > i64(max(u32)) || u32(wt.id) in listed do return fail("WELCOME terminal ids")
		listed[u32(wt.id)] = true
	}
	tails := make([dynamic]hw.Frame, context.temp_allocator)
	for wt in w.terminals {
		tf, tok := handshake_frame(deadline)
		if !tok || tf.kind != u8(hw.Kind.Tail) || tf.terminal != u32(wt.id) do return fail("missing TAIL")
		tf.payload = slice_clone_tmp(tf.payload) // the stream's buffer moves on
		append(&tails, tf)
	}
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	for wt, i in w.terminals {
		h := hc.held[u32(wt.id)]
		if h == nil do continue // released while it upgraded: its RELEASE waits in pending
		start, bytes, e := hw.decode_output(tails[i])
		if e != .None || start + u64(len(bytes)) != wt.offset do continue
		if !h.eof {
			skip, gap := held_output_place(h.next, start, len(bytes))
			if gap {
				h.gap = true // bytes between the two never came: shown as inexact
				h.next = start
			}
			append(&h.buf, ..bytes[skip:])
			h.next += u64(len(bytes) - skip)
			if ex, has := wt.exit.?; has {
				h.exit = exit_of_wire(ex.code, ex.signal)
				h.eof = true
			}
		}
		h.degraded = wt.degraded.? or_else false
	}
	// a terminal we had that the holder no longer lists is gone
	for id, h in hc.held do if !listed[id] && !h.eof && (h.welcomed || h.spawn == .Spawned) {
		h.eof, h.lost = true, true
		h.exit = {}
	}
	delete(hc.previous)
	hc.previous = strings.clone(w.previous)
	delete(hc.upgrade_error_seen)
	hc.upgrade_error_seen = strings.clone(w.upgrade_error)
	hc.holder_rev = w.holder_rev
	hc.pid = peer.pid
	return "", true
}

@(private = "file")
slice_clone_tmp :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b), context.temp_allocator)
	copy(out, b)
	return out
}

// Whether a held terminal is degraded (served by an upgrade's keeper, not its child).
holder_term_degraded :: proc(id: u32) -> bool {
	sync.lock(&hc.mu)
	defer sync.unlock(&hc.mu)
	h := hc.held[id]
	return h != nil && h.degraded
}

// Ends the reader thread and closes the connection (cleanup).
holder_client_stop :: proc() {
	if hc.reader != nil {
		sync.atomic_store(&hc.stop, true)
		thread.join(hc.reader)
		thread.destroy(hc.reader)
		hc.reader = nil
	}
	if hc.fd >= 0 do sock_close(hc.fd)
	hc.fd = -1
	hc.on = false
}

// Forgets the connection and everything held (unit tests, between fake holders).
holder_client_forget :: proc() {
	holder_client_stop()
	for _, h in hc.held do held_free(h)
	delete(hc.held)
	delete(hc.ack)
	delete(hc.dying)
	delete(hc.instance)
	delete(hc.previous)
	delete(hc.tokens_why)
	delete(hc.path)
	delete(hc.pending)
	delete(hc.upgrade_error_seen)
	hw.stream_destroy(&hc.rx)
	hc = Holder_Client{fd = -1}
}

SUCCESSOR_RETRIES :: 2 // tries after a REFUSED{secret}: a new reservation each time is another update

// Main thread, every frame: after REFUSED{secret}, once the holder's reservation has lapsed, the
// launch's attach and adopt again: the tabs that waited for it (held_away) get their terminals.
holder_successor_retry_tick :: proc() {
	if hc.successor_retry == {} || hc.on || hc.lost || hc.handed do return
	if time.tick_diff(hc.successor_retry, time.tick_now()) < 0 do return
	hc.successor_retry = {}
	hc.successor_retries += 1
	hc.tried, hc.unreachable, hc.refused_secret, hc.adopt_done = false, false, false, false
	for &s in state.open_sessions do for &t in s.tabs do if t.held_away != 0 {
		if t.status == .Not_Started do t.held = t.held_away
		t.held_away = 0
	}
	fmt.eprintln("Deckhand: session holder: the successor's reservation lapsed: attaching again")
	holder_adopt_all()
}

// Some tab waits for an unreachable holder that kept its process at launch (Tab.held_away).
held_away_any :: proc() -> bool {
	for s in state.open_sessions do for t in s.tabs do if t.held_away != 0 do return true
	return false
}

// ---- a holder from another build (Refused_Code) and a holder that never answers ----

// How many processes pid has as children (its sessions, for a holder): 0 when unknown.
holder_children :: proc(pid: i32) -> int {
	when ODIN_OS == .Darwin {
		buf: [1024]posix.pid_t
		n := proc_listchildpids(posix.pid_t(pid), &buf[0], i32(size_of(buf))) // jobs_run.odin's
		return max(0, int(n))
	} else {
		return 0
	}
}

HOLDER_STOP_WAIT :: 3 * time.Second // after SIGTERM, before SIGKILL

// Holder_Replace: the user's answer to state.holder_ask. stop: SIGTERM the refused holder (still
// that process: the same pid running a deckhand-core), SIGKILL after HOLDER_STOP_WAIT, remove its
// socket, and attach a new holder (its sessions are gone: the tabs that waited for them start
// fresh). Not stop: run on without one, as before. Main thread; asked once per run.
holder_replace :: proc(stop: bool) -> Result {
	pid := hc.refused_pid
	if state.holder_ask.pid == 0 || pid == 0 do return fail("no session holder from another build is waiting for an answer")
	state.holder_ask = {}
	if !stop {
		window_toast("Running without a session holder: tabs opened now stop when Deckhand quits. The other build's sessions keep running there.", err = true)
		return {ok = true}
	}
	if exe := holder_pid_exe(pid); !strings.has_suffix(exe, "/" + HOLDER_BIN) {
		return fail("that session holder is gone") // a reused pid is never signalled
	}
	fmt.eprintln("Deckhand: session holder: stopping the one from another build (pid", pid, ") as the user asked")
	posix.kill(posix.pid_t(pid), .SIGTERM)
	deadline := time.tick_add(time.tick_now(), HOLDER_STOP_WAIT)
	for posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK && time.tick_diff(time.tick_now(), deadline) > 0 do time.sleep(20 * time.Millisecond)
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK {
		posix.kill(posix.pid_t(pid), .SIGKILL)
		for _ in 0 ..< 50 {
			if posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK do break
			time.sleep(20 * time.Millisecond)
		}
	}
	if hc.refused_path != "" do sock_unlink(hc.refused_path)
	hc.refused_pid = 0
	hc.tried, hc.unreachable = false, false
	for &s in state.open_sessions do for &t in s.tabs do t.held_away = 0 // their processes went with it
	if !holder_client_start() do return fail("the old session holder is stopped, but a new one did not start (new tabs stop when Deckhand quits)")
	window_toast("A new session holder runs: tabs opened from now on keep running when Deckhand quits.")
	return {ok = true}
}

// Main thread, every tick: a holder that answered but never WELCOMEd (Warn_Running) for
// PONG_TIMEOUT is taken for hung for good: the tabs that waited for its sessions (held_away) start
// fresh here (the old processes, if they still run, are stuck in it).
holder_hung_tick :: proc() {
	if hc.hung_since == {} || hc.on || time.tick_since(hc.hung_since) < hw.PONG_TIMEOUT do return
	hc.hung_since = {}
	n := 0
	for &s in state.open_sessions do for &t in s.tabs do if t.held_away != 0 {
		t.held_away = 0
		n += 1
	}
	if n == 0 do return
	fmt.eprintln("Deckhand: session holder: still not answering after", hw.PONG_TIMEOUT, "-", n, "tab(s) that waited for it start fresh")
	window_toast(fmt.tprintf("The session holder still isn't answering: %d session%s that waited for it start fresh here.", n, n == 1 ? "" : "s"), err = true)
	window_state_changed()
}

// ---- the supervisor (src/holder supervisor.odin) ----

// A separate core tells its holder where it runs from, so a crash gets it relaunched (SUPERVISE{core}).
holder_supervise_me :: proc() {
	if !core_separate do return
	if exe := executable_path(); exe != "" do holder_send(.Supervise, 0, hw.Supervise{op = "core", path = exe})
}

// The window's question to the holder while its core never comes up (P6): op "status" or
// "use_previous". Any holder socket of ours in run whose code is the holder's; ok false: none answered.
holder_supervise_ask :: proc(run, op: string) -> (st: hw.Supervise_Status, ok: bool) {
	for path in holder_socks(run) {
		fd, cok := sock_connect(path)
		if !cok do continue
		defer sock_close(fd)
		peer, tok := trust.peer_read_token(fd)
		if trust.peer_allowed(.Adhoc, trust.own_uid(), peer) != .Allow || holder_peer_code_ok(tok) != "" do continue
		out := make([dynamic]u8, context.temp_allocator)
		hw.encode(&out, .Supervise, 0, hw.Supervise{op = op})
		if !sock_write_all(fd, out[:]) do continue
		rx: hw.Stream
		defer hw.stream_destroy(&rx)
		buf: [4096]u8
		deadline := time.tick_add(time.tick_now(), 2 * time.Second)
		for {
			if f, err := hw.stream_next(&rx); err == .None {
				if f.kind == u8(hw.Kind.Supervise_Status) && hw.decode(f, .Supervise_Status, &st, context.temp_allocator) == .None do return st, true
				break
			}
			left := time.tick_diff(time.tick_now(), deadline)
			if left <= 0 || !sock_wait_readable(fd, max(int(time.duration_milliseconds(left)), 1)) do break
			n := sock_read(fd, buf[:])
			if n <= 0 || trust.peer_still(peer, trust.peer_read(fd)) != .Allow do break
			hw.stream_feed(&rx, buf[:n])
		}
	}
	return {}, false
}
