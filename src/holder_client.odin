package main

// The app's side of the session holder (src/holder; docs/plans/background-core.md §3, §5.7,
// §7.2). With the setting keep_sessions on, tab processes are spawned by the holder, which
// owns their PTYs and keeps them running while Deckhand is closed; this file is the one
// connection to it. A held Pty (pty.odin: held != 0) routes every pty_* call here.
//
//   holder_client_start() -> bool   connect (launching a holder if keep_sessions is on), WELCOME
//   holder_spawn(...) -> (Pty, ok)  SPAWN, wait for SPAWNED (≤ 5 s)
//   holder_pull(id, reader)         OUTPUT received for a terminal into its Term's inbox
//   holder_handover() / holder_shutdown()   at quit (GOODBYE)
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

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import hw "holderwire"
import "trust"

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
	dying:     [dynamic]i32, // pids of released terminals, until they are gone (pty_dying)
	tokens_loaded: bool, // tokens.json verified at attach (socket_tokens_enable)
	tokens_why:    string, // why not
	adopt_done:    bool, // the launch's adopt ran: terminals a later WELCOME lists are kept unseen
	unreachable:   bool, // a holder answered but did not attach (Warn_Running): it may run kept sessions
}

hc := Holder_Client{fd = -1}
holder_send_timeout := HOLDER_WAIT // a send blocked this long fails (SO_SNDTIMEO; tests lower it)
holder_test_allowed: bool // unit tests: a test that wants a holder says so

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
			r := holder_connect(path)
			// macOS also refuses when the listen backlog is full: a busy live holder. Tried again,
			// with backoff, before its socket is taken for a dead one's (only a refusal: .Stale)
			for wait in HOLDER_RECHECKS {
				if r != .Stale do break
				time.sleep(wait)
				r = holder_connect(path)
			}
			switch r {
			case .Welcomed:
				hc.tried = true
				return true
			case .Answered:
				answered = true
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
	switch trust.holder_start(answered, state.settings.keep_sessions) {
	case .Without:
		return false // only dead holders' sockets (removed): tried again once the setting is on
	case .Warn_Running:
		hc.tried, hc.unreachable = true, true
		fmt.eprintln("Deckhand: session holder: one runs but does not answer; no second one is started, new tabs stop at quit")
		toast_show("The session holder isn't answering: tabs opened now stop when Deckhand quits. Sessions it keeps aren't shown.", err = true)
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
			if holder_connect(path) == .Welcomed do return true
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
}

@(private = "file")
handshake_got: int // bytes the handshake read so far (Quiet: none)

// Connect, check the peer, HELLO, WELCOME and its TAILs; then the reader thread. Anything but
// Welcomed keeps nothing: refused, a stale socket, a bad or lying WELCOME.
@(private = "file")
holder_connect :: proc(path: string) -> Connect_Result {
	fd, ok, refused := sock_connect_why(path)
	if !ok do return refused ? .Stale : .Answered // not refused (EACCES, a race): not known dead
	peer := trust.peer_read(fd)
	if d := trust.peer_allowed(.Adhoc, trust.own_uid(), peer); d != .Allow {
		fmt.eprintln("Deckhand: session holder: refused its peer:", d)
		sock_close(fd)
		return .Answered
	}
	set_timeouts(fd)
	hc.fd, hc.peer = fd, peer
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
	hw.encode(&out, .Hello, 0, hw.Hello{wire = hw.WIRE})
	if !sock_write_all(fd, out[:]) do return fail("cannot send HELLO")
	deadline := time.tick_add(time.tick_now(), HOLDER_WAIT)

	f, fok := handshake_frame(deadline)
	if !fok do return fail("no WELCOME")
	if f.kind == u8(hw.Kind.Refused) {
		r: hw.Refused
		hw.decode(f, .Refused, &r, context.temp_allocator)
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
			h.exit = {known = true, code = int(clamp(ex.code, 0, 255)), signal = int(clamp(ex.signal, 0, 127))}
			h.eof = true
		}
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
		toast_show(holder_kept_text(len(w.terminals)), err = true)
	}
	hc.reader = thread.create_and_start(holder_reader)
	if autotest.active do fmt.printfln("[autotest] holder attached: previous %s, %d terminals", hc.previous, len(w.terminals))
	return .Welcomed
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
		if n <= 0 {
			holder_lose(n == 0 ? "the holder closed the connection" : "read failed")
			return
		}
		if d := trust.peer_still(hc.peer, trust.peer_read(hc.fd)); d != .Allow {
			holder_lose(fmt.tprintf("its peer changed since connect: %v", d))
			return
		}
		hw.stream_feed(&hc.rx, buf[:n])
		if !holder_frames() do return
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
		append(&h.buf, ..bytes[skip:])
		h.next += u64(len(bytes) - skip)
	case .Exited:
		m: hw.Exited
		if h == nil || hw.decode(f, .Exited, &m, context.temp_allocator) != .None do return
		h.exit = {known = true, code = int(clamp(m.code, 0, 255)), signal = int(clamp(m.signal, 0, 127))}
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
		m: hw.Goodbye_Ack
		e := hw.decode(f, .Goodbye_Ack, &m, context.temp_allocator)
		if !hc.handed || hc.acked || e != .None do return
		for a in m.terminals do if a.id > 0 && a.id <= i64(max(u32)) do hc.ack[u32(a.id)] = a.offset
		hc.acked = true
		sync.cond_broadcast(&hc.cond)
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
	if hc.fd < 0 || sync.atomic_load(&hc.lost) || sync.atomic_load(&hc.handed) do return false
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
holder_goodbye :: proc(mode: string) -> bool {
	out := make([dynamic]u8, context.temp_allocator)
	hw.encode(&out, .Goodbye, 0, hw.Goodbye{mode = mode})
	sync.lock(&hc.wmu)
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
	hw.stream_destroy(&hc.rx)
	hc = Holder_Client{fd = -1}
}

// Some tab waits for an unreachable holder that kept its process at launch (Tab.held_away).
held_away_any :: proc() -> bool {
	for s in state.open_sessions do for t in s.tabs do if t.held_away != 0 do return true
	return false
}
