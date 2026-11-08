#+build darwin
package holder

// An in-process holder and a fake core over a socketpair, with /bin/sh children. Every test
// pumps holder_step on its own thread; none takes more than a fraction of a second.

import "core:bytes"
import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "../holderwire"

Got :: struct {
	kind:    holderwire.Kind,
	term:    u32,
	payload: []u8,
}

Fake :: struct {
	fd:     c.int,
	rx:     holderwire.Stream,
	frames: [dynamic]Got,
	seen:   int, // frames wait_for has looked at
	eof:    bool,
}

test_cfg :: proc() -> Config {
	cfg := default_config()
	cfg.quiet = true
	cfg.idle_exit = time.Hour // tests that want it lower say so
	cfg.reap_interval = 5 * time.Millisecond
	cfg.exit_grace = 300 * time.Millisecond
	cfg.shutdown_wait = 500 * time.Millisecond
	return cfg
}

new_test_holder :: proc(t: ^testing.T, cfg := Config{}) -> ^Holder {
	cfg := cfg
	if cfg.pong_timeout == 0 do cfg = test_cfg()
	h, err := holder_new(cfg)
	testing.expect_value(t, err, Start_Error.None)
	return h
}

// A socketpair: one end to the holder as an accepted core, the other the fake core's.
fake_connect :: proc(t: ^testing.T, h: ^Holder) -> ^Fake {
	sv: [2]c.int
	sync.mutex_lock(&fork_lock)
	ok := socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0
	if ok do for fd in sv do set_cloexec(fd)
	sync.mutex_unlock(&fork_lock)
	testing.expect(t, ok)
	set_nonblock(sv[0])
	set_nosigpipe(sv[0])
	testing.expect(t, holder_attach(h, sv[1]))
	f := new(Fake)
	f.fd = sv[0]
	return f
}

fake_free :: proc(f: ^Fake) {
	if f.fd >= 0 do close(f.fd)
	for g in f.frames do delete(g.payload)
	delete(f.frames)
	holderwire.stream_destroy(&f.rx)
	free(f)
}

fake_write :: proc(f: ^Fake, b: []u8) {
	b := b
	for len(b) > 0 {
		n := send(f.fd, raw_data(b), len(b), MSG_NOSIGNAL)
		if n <= 0 do return
		b = b[n:]
	}
}

fake_send :: proc(f: ^Fake, kind: holderwire.Kind, term: u32, msg: $T) {
	out := make([dynamic]u8, context.temp_allocator)
	holderwire.encode(&out, kind, term, msg)
	fake_write(f, out[:])
}

fake_input :: proc(f: ^Fake, term: u32, s: string) {
	out := make([dynamic]u8, context.temp_allocator)
	holderwire.encode_input(&out, term, transmute([]u8)s)
	fake_write(f, out[:])
}

fake_read :: proc(f: ^Fake) {
	buf: [64 * 1024]u8
	for {
		n := recv(f.fd, &buf, len(buf), 0)
		if n == 0 do f.eof = true
		if n <= 0 do break
		holderwire.stream_feed(&f.rx, buf[:n])
	}
	for {
		fr, err := holderwire.stream_next(&f.rx)
		if err != .None do break
		append(&f.frames, Got{holderwire.Kind(fr.kind), fr.terminal, bytes.clone(fr.payload)})
	}
}

// Steps the holder (and reads the fake core) until a frame of `kind` for `term` arrives after
// the ones already seen; frames before it count as seen.
wait_for :: proc(h: ^Holder, f: ^Fake, kind: holderwire.Kind, term: u32 = 0, timeout := 3 * time.Second) -> (Got, bool) {
	start := time.tick_now()
	for {
		for f.seen < len(f.frames) {
			g := f.frames[f.seen]
			f.seen += 1
			if g.kind == kind && g.term == term do return g, true
		}
		if time.tick_since(start) > timeout do return {}, false
		holder_step(h, 2)
		fake_read(f)
	}
}

// The fake core is done sending (shutdown of its write half): the holder sees EOF.
fake_hangup :: proc(f: ^Fake) {sock_shutdown(f.fd, SHUT_WR)}

// Steps until the fake core's end reads EOF (the holder closed it).
wait_eof :: proc(h: ^Holder, f: ^Fake, timeout := 3 * time.Second) -> bool {
	start := time.tick_now()
	for !f.eof {
		if time.tick_since(start) > timeout do return false
		holder_step(h, 2)
		fake_read(f)
	}
	return true
}

pump :: proc(h: ^Holder, d: time.Duration, f: ^Fake = nil) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		holder_step(h, 2)
		if f != nil do fake_read(f)
	}
}

hello :: proc(t: ^testing.T, h: ^Holder, f: ^Fake) -> holderwire.Welcome {
	fake_send(f, .Hello, 0, holderwire.Hello{wire = holderwire.WIRE})
	g, ok := wait_for(h, f, .Welcome)
	testing.expect(t, ok, "no WELCOME")
	w: holderwire.Welcome
	fr := holderwire.Frame{u8(g.kind), g.term, g.payload}
	testing.expect_value(t, holderwire.decode(fr, .Welcome, &w, context.temp_allocator), holderwire.Msg_Error.None)
	return w
}

decode_got :: proc(g: Got, kind: holderwire.Kind, msg: ^$T) -> bool {
	return holderwire.decode(holderwire.Frame{u8(g.kind), g.term, g.payload}, kind, msg, context.temp_allocator) == .None
}

sh_spawn :: proc(f: ^Fake, id: u32, script: string, cols := i64(80), rows := i64(24), xpixel := i64(640), ypixel := i64(384)) {
	fake_send(f, .Spawn, id, holderwire.Spawn {
		argv = {"/bin/sh", "-c", script}, env = {"PATH=/usr/bin:/bin", "LANG=C"}, cwd = "/",
		cols = cols, rows = rows, xpixel = xpixel, ypixel = ypixel,
	})
}

spawn_ok :: proc(t: ^testing.T, h: ^Holder, f: ^Fake, id: u32, script: string) -> holderwire.Spawned {
	sh_spawn(f, id, script)
	g, ok := wait_for(h, f, .Spawned, id)
	testing.expectf(t, ok, "terminal %d: no SPAWNED", id)
	s: holderwire.Spawned
	decode_got(g, .Spawned, &s)
	return s
}

// Every OUTPUT (and TAIL) byte for `term`, checking each frame starts where the last ended.
output_of :: proc(t: ^testing.T, f: ^Fake, term: u32, from: u64 = 0) -> string {
	sb := strings.builder_make(context.temp_allocator)
	at := from
	for g in f.frames {
		if g.term != term || (g.kind != .Output && g.kind != .Tail) do continue
		start, b, _ := holderwire.decode_output(holderwire.Frame{u8(g.kind), g.term, g.payload})
		if g.kind == .Tail {
			at = start
		} else {
			testing.expectf(t, start == at, "terminal %d: OUTPUT starts at %d, expected %d", term, start, at)
		}
		strings.write_bytes(&sb, b)
		at = start + u64(len(b))
	}
	return strings.to_string(sb)
}

wait_output :: proc(t: ^testing.T, h: ^Holder, f: ^Fake, term: u32, want: string, timeout := 3 * time.Second) -> bool {
	start := time.tick_now()
	for !strings.contains(output_of(t, f, term), want) {
		if time.tick_since(start) > timeout do return false
		holder_step(h, 2)
		fake_read(f)
	}
	return true
}

exited_of :: proc(t: ^testing.T, h: ^Holder, f: ^Fake, term: u32) -> (holderwire.Exited, bool) {
	g, ok := wait_for(h, f, .Exited, term)
	e: holderwire.Exited
	if ok do decode_got(g, .Exited, &e)
	return e, ok
}

@(test)
ring_keeps_the_last_bytes :: proc(t: ^testing.T) {
	r: Ring
	defer ring_destroy(&r)
	ring_push(&r, 8, transmute([]u8)string("abc"))
	testing.expect_value(t, string(ring_bytes(&r)), "abc")
	ring_push(&r, 8, transmute([]u8)string("defgh"))
	testing.expect_value(t, string(ring_bytes(&r)), "abcdefgh")
	ring_push(&r, 8, transmute([]u8)string("ij"))
	testing.expect_value(t, string(ring_bytes(&r)), "cdefghij")
	ring_push(&r, 8, transmute([]u8)string("klmnopq"))
	testing.expect_value(t, string(ring_bytes(&r)), "jklmnopq")
	ring_push(&r, 8, transmute([]u8)string("0123456789"))
	testing.expect_value(t, string(ring_bytes(&r)), "23456789")
	ring_push(&r, 8, transmute([]u8)string("x"))
	testing.expect_value(t, string(ring_bytes(&r)), "3456789x")
}

// SPAWN, INPUT, OUTPUT offsets, FOREGROUND, then EXITED after the last byte.
@(test)
spawn_input_exit :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	w := hello(t, h, f)
	testing.expect_value(t, w.previous, "none")
	testing.expect_value(t, w.holder_rev, i64(HOLDER_REV))
	testing.expect_value(t, len(w.terminals), 0)
	s := spawn_ok(t, h, f, 7, `printf 'ready\n'; read x; printf 'got:%s\n' "$x"; exit 3`)
	testing.expect(t, s.pid > 0)
	testing.expect_value(t, s.pgid, s.pid) // the session leader
	testing.expect(t, wait_output(t, h, f, 7, "ready"))
	fake_send(f, .Foreground, 7, holderwire.Empty{})
	g, ok := wait_for(h, f, .Foreground_Is, 7)
	fg: holderwire.Foreground_Is
	testing.expect(t, ok && decode_got(g, .Foreground_Is, &fg))
	testing.expect_value(t, fg.pgid, s.pid)
	fake_input(f, 7, "hello\n")
	e, eok := exited_of(t, h, f, 7)
	testing.expect(t, eok, "no EXITED")
	testing.expect_value(t, e.code, 3)
	testing.expect_value(t, e.signal, 0)
	out := output_of(t, f, 7)
	testing.expect(t, strings.contains(out, "got:hello"), out)
	testing.expect_value(t, e.offset, u64(len(out))) // EXITED after every byte
	last_output := -1
	exited_at := -1
	for g, i in f.frames {
		if g.term == 7 && g.kind == .Output do last_output = i
		if g.term == 7 && g.kind == .Exited do exited_at = i
	}
	testing.expect(t, last_output < exited_at, "OUTPUT after EXITED")
	// the ended terminal stays (and is listed) until RELEASE; signals after the reap do nothing
	fake_send(f, .Signal, 7, holderwire.Signal{signal = 15, target = "pid"})
	pump(h, 20 * time.Millisecond, f)
	testing.expect_value(t, len(h.terms), 1)
	fake_send(f, .Release, 7, holderwire.Empty{})
	pump(h, 20 * time.Millisecond, f)
	testing.expect_value(t, len(h.terms), 0)
}

// A background process that had the slave open does not hold EXITED back. (On macOS the
// session leader's exit revokes the terminal, so the master reads EOF at once; the exit_grace
// path covers systems that leave a held slave open.)
@(test)
exited_while_grandchild_holds_pty :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	start := time.tick_now()
	// The grandchild ignores the revoke's SIGHUP (else it is gone with the terminal, and nothing
	// is left to wait for) and outlives the bound by seconds, so a busy machine cannot blur the two.
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	pidf := fmt.tprintf("%s/grandchild-%d.pid", tmp, posix.getpid())
	defer os.remove(pidf)
	defer {
		b, _ := os.read_entire_file(pidf, context.temp_allocator)
		if pid, pok := strconv.parse_int(strings.trim_space(string(b))); pok && pid > 1 do kill(c.int(pid), SIGKILL)
	}
	spawn_ok(t, h, f, 1, fmt.tprintf(`(trap '' HUP; exec /bin/sleep 30) & echo $! > %s; printf bye; exit 2`, pidf))
	e, ok := exited_of(t, h, f, 1)
	testing.expect(t, ok, "no EXITED while the grandchild runs")
	testing.expectf(t, time.tick_since(start) < 10 * time.Second, "EXITED waited for the grandchild (%v)", time.tick_since(start))
	testing.expect_value(t, e.code, 2)
	out := output_of(t, f, 1)
	testing.expect_value(t, out, "bye")
	testing.expect_value(t, e.offset, u64(len(out)))
}

@(test)
spawn_failures_and_bad_sizes :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	fails :: proc(t: ^testing.T, h: ^Holder, f: ^Fake, id: u32, what: string) {
		g, ok := wait_for(h, f, .Spawn_Failed, id)
		m: holderwire.Spawn_Failed
		testing.expectf(t, ok && decode_got(g, .Spawn_Failed, &m) && m.error != "", "%s: no SPAWN_FAILED", what)
	}
	sh_spawn(f, 0, "exit 0")
	fails(t, h, f, 0, "id 0")
	fake_send(f, .Spawn, 1, holderwire.Spawn{argv = {"/nonexistent/prog"}, env = {}, cwd = "/", cols = 80, rows = 24})
	fails(t, h, f, 1, "missing program")
	fake_send(f, .Spawn, 2, holderwire.Spawn{argv = {"sh"}, env = {}, cwd = "/", cols = 80, rows = 24})
	fails(t, h, f, 2, "relative argv[0]")
	sh_spawn(f, 3, "exit 0", cols = 0)
	fails(t, h, f, 3, "0 cols")
	sh_spawn(f, 4, "exit 0", cols = MAX_COLS + 1)
	fails(t, h, f, 4, "too many cols")
	sh_spawn(f, 5, "exit 0", rows = MAX_ROWS + 1)
	fails(t, h, f, 5, "too many rows")
	sh_spawn(f, 6, "exit 0", cols = 70000)
	fails(t, h, f, 6, "cols past u16")
	spawn_ok(t, h, f, 8, "sleep 5")
	sh_spawn(f, 8, "exit 0")
	fails(t, h, f, 8, "id in use")
	// a RESIZE out of range is ignored
	fake_send(f, .Resize, 8, holderwire.Resize{cols = 100000, rows = 30, xpixel = 1, ypixel = 1})
	fake_send(f, .Resize, 8, holderwire.Resize{cols = 100, rows = 0, xpixel = 1, ypixel = 1})
	pump(h, 20 * time.Millisecond, f)
	ws: Winsize
	ioctl(h.terms[0].master, TIOCGWINSZ, &ws)
	testing.expect_value(t, ws, Winsize{ws_row = 24, ws_col = 80, ws_xpixel = 640, ws_ypixel = 384})
	testing.expect_value(t, len(h.terms), 1)
}

// Pixel sizes at SPAWN and RESIZE reach the PTY; the child sees the new size.
@(test)
resize_with_pixels :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, `stty size; read x; stty size; exit 0`)
	testing.expect(t, wait_output(t, h, f, 1, "24 80"))
	ws: Winsize
	ioctl(h.terms[0].master, TIOCGWINSZ, &ws)
	testing.expect_value(t, ws, Winsize{ws_row = 24, ws_col = 80, ws_xpixel = 640, ws_ypixel = 384})
	// pixels past u16 are out of range (holderwire.decode): ignored, the size stays
	fake_send(f, .Resize, 1, holderwire.Resize{cols = 100, rows = 30, xpixel = 900, ypixel = 70000})
	fake_send(f, .Resize, 1, holderwire.Resize{cols = 100, rows = 30, xpixel = 900, ypixel = 65535})
	fake_input(f, 1, "\n")
	testing.expect(t, wait_output(t, h, f, 1, "30 100"))
	ioctl(h.terms[0].master, TIOCGWINSZ, &ws)
	testing.expect_value(t, ws, Winsize{ws_row = 30, ws_col = 100, ws_xpixel = 900, ws_ypixel = 65535})
}

@(test)
signals_pid_and_pgroup :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, "exec /bin/sleep 5")
	fake_send(f, .Signal, 1, holderwire.Signal{signal = 15, target = "pid"})
	e, ok := exited_of(t, h, f, 1)
	testing.expect(t, ok)
	testing.expect_value(t, e.signal, 15)
	// pgroup: the shell's background sleep (same group, no job control) dies too
	spawn_ok(t, h, f, 2, `/bin/sleep 5 & echo "bg=$!"; wait`)
	testing.expect(t, wait_output(t, h, f, 2, "\n"))
	out := output_of(t, f, 2)
	i := strings.index(out, "bg=")
	testing.expect(t, i >= 0, out)
	bg := 0
	for ch in out[i + 3:] {
		if ch < '0' || ch > '9' do break
		bg = bg * 10 + int(ch - '0')
	}
	testing.expect(t, bg > 0)
	fake_send(f, .Signal, 2, holderwire.Signal{signal = 15, target = "pgroup"})
	e2, ok2 := exited_of(t, h, f, 2)
	testing.expect(t, ok2)
	testing.expect_value(t, e2.signal, 15)
	gone := false
	for _ in 0 ..< 100 {
		if kill(c.int(bg), 0) != 0 {gone = true; break}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, gone, "the background sleep survived a pgroup signal")
}

// The child starts with SIGPIPE at its default and nothing blocked, whatever the holder had.
@(test)
child_signal_state :: proc(t: ^testing.T) {
	ign := Sigaction{handler = 1} // SIG_IGN
	old_act: Sigaction
	sigaction(SIGPIPE, &ign, &old_act)
	defer sigaction(SIGPIPE, &old_act, nil)
	block: u32 = 1 << (31 - 1) // SIGUSR2
	old_mask: u32
	pthread_sigmask(SIG_BLOCK, &block, &old_mask)
	defer pthread_sigmask(SIG_SETMASK, &old_mask, nil)

	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, `(yes; echo "st=$?" >&2) | head -c 1 >/dev/null; exec /bin/ps -o sigmask= -p $$`)
	_, ok := exited_of(t, h, f, 1)
	testing.expect(t, ok)
	out := output_of(t, f, 1)
	testing.expectf(t, strings.contains(out, "st=141"), "SIGPIPE not default in the child: %q", out)
	lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	testing.expectf(t, strings.trim_space(lines[len(lines) - 1]) == "0", "the child's mask is not empty: %q", out)
}

// No core: output goes to the 1 MiB tail and the program never stalls; the next core's
// WELCOME lists the exit and its TAIL is the last 1 MiB with the right start.
@(test)
tail_cap_without_core :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	a := fake_connect(t, h)
	defer fake_free(a)
	hello(t, h, a)
	spawn_ok(t, h, a, 1, `read x; yes 0123456789abcde | head -c 1500000; printf END; exit 5`)
	fake_input(a, 1, "go\n")
	fake_send(a, .Goodbye, 0, holderwire.Goodbye{mode = "handover"})
	g, ok := wait_for(h, a, .Goodbye_Ack)
	testing.expect(t, ok)
	ack: holderwire.Goodbye_Ack
	decode_got(g, .Goodbye_Ack, &ack)
	fake_hangup(a)
	testing.expect(t, wait_eof(h, a))
	// no core: let it run to the end
	start := time.tick_now()
	for !h.terms[0].final && time.tick_since(start) < 3 * time.Second do holder_step(h, 2)
	testing.expect(t, h.terms[0].final, "the program stalled with no core")
	total := h.terms[0].offset
	testing.expect(t, total > TAIL_CAP + 400000, "less output than expected")

	b := fake_connect(t, h)
	defer fake_free(b)
	w := hello(t, h, b)
	testing.expect_value(t, w.previous, "handover")
	testing.expect_value(t, len(w.terminals), 1)
	wt := w.terminals[0]
	testing.expect_value(t, wt.offset, total)
	ex, has_exit := wt.exit.?
	testing.expect(t, has_exit)
	testing.expect_value(t, ex.code, 5)
	tg, tok := wait_for(h, b, .Tail, 1)
	testing.expect(t, tok)
	tstart, tbytes, _ := holderwire.decode_output(holderwire.Frame{u8(tg.kind), tg.term, tg.payload})
	testing.expect_value(t, len(tbytes), TAIL_CAP)
	testing.expect_value(t, tstart, total - TAIL_CAP)
	testing.expect(t, strings.has_suffix(string(tbytes), "END"))
	// listed in WELCOME: no EXITED follows
	pump(h, 30 * time.Millisecond, b)
	for fr in b.frames do testing.expect(t, fr.kind != .Exited, "EXITED for a terminal WELCOME listed as ended")
}

// GOODBYE{handover}: the ack offsets match what the core got; nothing comes after; the next core
// gets previous=handover, a TAIL from the right start, then OUTPUT from the offset. The HMAC
// key is in WELCOME and nowhere else.
@(test)
handover_then_second_core :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	a := fake_connect(t, h)
	defer fake_free(a)
	wa := hello(t, h, a)
	spawn_ok(t, h, a, 1, `read x; echo "line $x"; read y; echo "second $y"; exit 0`)
	fake_input(a, 1, "1\n")
	testing.expect(t, wait_output(t, h, a, 1, "line 1"))
	pump(h, 20 * time.Millisecond, a)
	fake_send(a, .Goodbye, 0, holderwire.Goodbye{mode = "handover"})
	g, ok := wait_for(h, a, .Goodbye_Ack)
	testing.expect(t, ok)
	ack: holderwire.Goodbye_Ack
	testing.expect(t, decode_got(g, .Goodbye_Ack, &ack))
	testing.expect_value(t, len(ack.terminals), 1)
	got_a := output_of(t, a, 1)
	testing.expect_value(t, ack.terminals[0].offset, u64(len(got_a)))
	pump(h, 100 * time.Millisecond, a)
	testing.expect(t, !a.eof, "the holder closed right after GOODBYE_ACK (the core can't check its peer on the ack then)")
	fake_hangup(a)
	testing.expect(t, wait_eof(h, a))
	testing.expect_value(t, a.frames[len(a.frames) - 1].kind, holderwire.Kind.Goodbye_Ack)

	b := fake_connect(t, h)
	defer fake_free(b)
	wb := hello(t, h, b)
	testing.expect_value(t, wb.previous, "handover")
	testing.expect_value(t, wb.terminals[0].offset, ack.terminals[0].offset)
	testing.expect(t, wb.terminals[0].exit == nil)
	testing.expect_value(t, wb.hmac_key, wa.hmac_key)
	testing.expect_value(t, wb.instance, wa.instance)
	tg, _ := wait_for(h, b, .Tail, 1)
	tstart, tbytes, _ := holderwire.decode_output(holderwire.Frame{u8(tg.kind), tg.term, tg.payload})
	testing.expect_value(t, tstart, 0)
	testing.expect_value(t, string(tbytes), got_a)
	fake_input(b, 1, "2\n")
	e, eok := exited_of(t, h, b, 1)
	testing.expect(t, eok)
	all := output_of(t, b, 1)
	testing.expect(t, strings.has_prefix(all, got_a) && strings.contains(all[len(got_a):], "second 2"), all)
	testing.expect_value(t, e.offset, u64(len(all)))

	key := wa.hmac_key
	testing.expect_value(t, len(key), 64)
	for fk in ([]^Fake{a, b}) {
		for fr in fk.frames {
			has := strings.contains(string(fr.payload), key)
			testing.expectf(t, has == (fr.kind == .Welcome), "HMAC key in a %v frame: %v", fr.kind, has)
		}
	}
}

// One core at a time: a second HELLO is refused (then closed); pings keep the first; silence
// past the pong timeout drops it and frees the slot (previous = crash).
@(test)
refused_and_ping_timeout :: proc(t: ^testing.T) {
	cfg := test_cfg()
	// pings every 40 ms keep a for twice the timeout; b and c2 then take milliseconds of it. The
	// timeout is long enough that a loaded runner's stall between two steps cannot pass it.
	cfg.pong_timeout = time.Second
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	a := fake_connect(t, h)
	defer fake_free(a)
	hello(t, h, a)
	start := time.tick_now()
	for time.tick_since(start) < 2 * cfg.pong_timeout {
		fake_send(a, .Ping, 0, holderwire.Empty{})
		_, ok := wait_for(h, a, .Pong)
		testing.expect(t, ok)
		pump(h, 40 * time.Millisecond, a)
	}
	testing.expect(t, !a.eof && h.core != nil, "a pinging core was dropped")

	b := fake_connect(t, h)
	defer fake_free(b)
	fake_send(b, .Hello, 0, holderwire.Hello{wire = holderwire.WIRE})
	g, ok := wait_for(h, b, .Refused)
	r: holderwire.Refused
	testing.expect(t, ok && decode_got(g, .Refused, &r))
	testing.expect_value(t, r.code, "attached")
	testing.expect(t, wait_eof(h, b))

	c2 := fake_connect(t, h)
	defer fake_free(c2)
	fake_send(c2, .Hello, 0, holderwire.Hello{wire = 0})
	g, ok = wait_for(h, c2, .Refused)
	testing.expect(t, ok && decode_got(g, .Refused, &r))
	testing.expect_value(t, r.code, "wire")
	testing.expect(t, wait_eof(h, c2))

	// a falls silent
	testing.expect(t, wait_eof(h, a, 10 * time.Second), "a silent core was not dropped")
	testing.expect(t, h.core == nil)
	d := fake_connect(t, h)
	defer fake_free(d)
	w := hello(t, h, d)
	testing.expect_value(t, w.previous, "crash")
}

// Past queue_cap queued for a core that does not read, the masters are not read (the program
// blocks); once the core reads, everything arrives in order.
@(test)
backpressure :: proc(t: ^testing.T) {
	cfg := test_cfg()
	cfg.queue_cap = 256 * 1024
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, `yes 0123456789abcdef | head -c 3000000; printf END`)
	// the fake core stops reading
	start := time.tick_now()
	for time.tick_since(start) < 250 * time.Millisecond do holder_step(h, 2)
	stuck := h.terms[0].offset
	testing.expectf(t, stuck < u64(cfg.queue_cap + 1024 * 1024), "read %d bytes past a full queue", stuck)
	testing.expect(t, queued(h.core) >= cfg.queue_cap)
	testing.expect(t, !h.terms[0].reaped, "the program did not block")
	for time.tick_since(start) < 350 * time.Millisecond do holder_step(h, 2)
	testing.expect_value(t, h.terms[0].offset, stuck)
	// now it reads
	e, ok := exited_of(t, h, f, 1)
	testing.expect(t, ok)
	out := output_of(t, f, 1)
	testing.expect(t, strings.has_suffix(out, "END"))
	testing.expect_value(t, e.offset, u64(len(out)))
}

@(test)
release_hangs_up :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	s := spawn_ok(t, h, f, 1, "exec /bin/sleep 5")
	fake_send(f, .Release, 1, holderwire.Empty{})
	start := time.tick_now()
	for len(h.terms) > 0 && time.tick_since(start) < 2 * time.Second {
		holder_step(h, 2)
		fake_read(f)
	}
	testing.expect_value(t, len(h.terms), 0)
	testing.expect(t, kill(c.int(s.pid), 0) != 0, "the child outlived RELEASE")
	for fr in f.frames do testing.expect(t, fr.kind != .Exited, "EXITED after RELEASE")
}

@(test)
goodbye_shutdown :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	s := spawn_ok(t, h, f, 1, "exec /bin/sleep 5")
	fake_send(f, .Goodbye, 0, holderwire.Goodbye{mode = "shutdown"})
	start := time.tick_now()
	for !h.done && time.tick_since(start) < 2 * time.Second do holder_step(h, 2)
	testing.expect(t, h.done)
	testing.expect_value(t, h.exit_code, 0)
	testing.expect(t, h.terms[0].reaped)
	testing.expect(t, kill(c.int(s.pid), 0) != 0)
	// closed by now; read until the EOF shows (a process another test forks at that moment can
	// hold a copy of the fd for a while: not one read, on a busy machine)
	start = time.tick_now()
	for !f.eof && time.tick_since(start) < 5 * time.Second {
		fake_read(f)
		if !f.eof do time.sleep(time.Millisecond)
	}
	testing.expect(t, f.eof, "the core's connection is still open after shutdown")
}

// A run dir of the test's own (0700), for a holder that listens. Removed by the caller (rmdir).
test_run_dir :: proc(t: ^testing.T, name: string) -> (run: string, crun: cstring) {
	r: [4]u8
	crypto.rand_bytes(r[:])
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	run = fmt.tprintf("%s/dh-%s-%s", tmp, name, string(hex.encode(r[:], context.temp_allocator)))
	crun = strings.clone_to_cstring(run, context.temp_allocator)
	testing.expect_value(t, mkdir(crun, 0o700), 0)
	return
}

// Once a shutdown starts (and while it reaps, up to shutdown_wait) or an idle exit is decided,
// the socket is gone: a launch right after "Quit and Stop All Sessions" finds no holder that
// accepts and never answers (its HELLO would time out: "a holder runs but does not answer").
@(test)
shutdown_stops_listening :: proc(t: ^testing.T) {
	run, crun := test_run_dir(t, "shut")
	defer rmdir(crun)
	cfg := test_cfg()
	cfg.run_dir = run
	cfg.shutdown_wait = 2 * time.Second
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	if h == nil do return
	path := strings.clone(h.sock_path, context.temp_allocator)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, `trap "" HUP; echo ready; exec /bin/sleep 5`) // outlives the hangup: the shutdown waits
	testing.expect(t, wait_output(t, h, f, 1, "ready"))
	fake_send(f, .Goodbye, 0, holderwire.Goodbye{mode = "shutdown"})
	start := time.tick_now()
	for !h.shutting_down && time.tick_since(start) < time.Second do holder_step(h, 10)
	testing.expect(t, h.shutting_down && !h.done, "not reaping")
	testing.expect(t, !os.exists(path), "the socket is still there while it shuts down")
	testing.expect_value(t, h.listen_fd, c.int(-1))

	icfg := test_cfg()
	icfg.run_dir = run
	icfg.idle_exit = 50 * time.Millisecond
	h2 := new_test_holder(t, icfg)
	defer holder_free(h2, true)
	if h2 == nil do return
	path2 := strings.clone(h2.sock_path, context.temp_allocator)
	start = time.tick_now()
	for !h2.done && time.tick_since(start) < time.Second do holder_step(h2, 20)
	testing.expect(t, h2.done)
	testing.expect(t, !os.exists(path2), "the socket is still there after the idle exit was decided")
}

@(test)
idle_exit :: proc(t: ^testing.T) {
	cfg := test_cfg()
	cfg.idle_exit = 100 * time.Millisecond
	// none ever spawned, no core
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	start := time.tick_now()
	for !h.done && time.tick_since(start) < time.Second do holder_step(h, 50)
	testing.expect(t, h.done)
	testing.expect(t, time.tick_since(start) >= 90 * time.Millisecond)

	// the last terminal ended with no core
	h2 := new_test_holder(t, cfg)
	defer holder_free(h2, true)
	f := fake_connect(t, h2)
	defer fake_free(f)
	hello(t, h2, f)
	spawn_ok(t, h2, f, 1, "read x; exit 0")
	fake_send(f, .Goodbye, 0, holderwire.Goodbye{mode = "handover"})
	_, gok := wait_for(h2, f, .Goodbye_Ack)
	testing.expect(t, gok)
	fake_hangup(f)
	testing.expect(t, wait_eof(h2, f))
	pump(h2, 200 * time.Millisecond)
	testing.expect(t, !h2.done, "exited with a terminal running")
	close(h2.terms[0].master) // hang it up from here
	h2.terms[0].master = -1
	start = time.tick_now()
	for !h2.done && time.tick_since(start) < time.Second do holder_step(h2, 10)
	testing.expect(t, h2.done)
}

// Unknown kinds get UNKNOWN; anything before HELLO drops the connection.
@(test)
unknown_and_early_frames :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	raw := make([dynamic]u8, context.temp_allocator)
	holderwire.put_header(&raw, 99, 0, 0)
	fake_write(f, raw[:])
	g, ok := wait_for(h, f, .Unknown)
	u: holderwire.Unknown
	testing.expect(t, ok && decode_got(g, .Unknown, &u))
	testing.expect_value(t, u.kind, 99)

	f2 := fake_connect(t, h)
	defer fake_free(f2)
	fake_send(f2, .Ping, 0, holderwire.Empty{})
	testing.expect(t, wait_eof(h, f2))
	testing.expect_value(t, len(f2.frames), 0)
}

// Bytes another process wrote on the core's socket (a forked child holding the fd) are not acted
// on: the peer changed since accept, so the core is dropped.
@(test)
changed_peer_is_dropped :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	ping := make([dynamic]u8, context.temp_allocator)
	holderwire.encode(&ping, .Ping, 0, holderwire.Empty{})
	sync.mutex_lock(&fork_lock)
	pid := fork()
	if pid == 0 {
		write(f.fd, raw_data(ping), len(ping))
		_exit(0)
	}
	sync.mutex_unlock(&fork_lock)
	st: c.int
	waitpid(pid, &st, 0)
	testing.expect(t, wait_eof(h, f))
	for fr in f.frames do testing.expect(t, fr.kind != .Pong, "acted on a changed peer's bytes")
	testing.expect(t, h.core == nil)
}

foreign import libc_test "system:System"
@(default_calling_convention = "c")
foreign libc_test {
	fork :: proc() -> c.int ---
	mkdir :: proc(path: cstring, mode: u16) -> c.int ---
	rmdir :: proc(path: cstring) -> c.int ---
}

// The run dir must be ours and 0700; instance.lock held exclusively → Lock_Busy.
@(test)
start_checks :: proc(t: ^testing.T) {
	r: [4]u8
	crypto.rand_bytes(r[:])
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	base := fmt.tprintf("%s/dh-holder-%s", tmp, string(hex.encode(r[:], context.temp_allocator)))
	run := fmt.tprintf("%s/run", base)
	cs :: proc(s: string) -> cstring {return strings.clone_to_cstring(s, context.temp_allocator)}
	testing.expect_value(t, mkdir(cs(base), 0o700), 0)
	defer rmdir(cs(base))
	testing.expect_value(t, mkdir(cs(run), 0o755), 0)
	defer rmdir(cs(run))

	cfg := test_cfg()
	cfg.run_dir = run
	h, err := holder_new(cfg)
	testing.expect_value(t, err, Start_Error.Run_Dir)
	testing.expect(t, h == nil)

	chmod(cs(run), 0o700)
	cfg.data_dir = base
	h, err = holder_new(cfg)
	testing.expect_value(t, err, Start_Error.None)
	if h != nil {
		testing.expect(t, strings.has_prefix(h.sock_path, run))
		testing.expect(t, os.exists(h.sock_path))
		// another holder beside it (shared lock) is fine
		h2, err2 := holder_new(cfg)
		testing.expect_value(t, err2, Start_Error.None)
		holder_free(h2)
		path := h.sock_path
		holder_free(h)
		testing.expect(t, !os.exists(path), "the socket outlived the holder")
	}
	lock := cs(fmt.tprintf("%s/instance.lock", base))
	defer unlink(lock)
	fd := open(lock, O_RDWR | O_CLOEXEC)
	testing.expectf(t, fd >= 0, "open: errno %d", errno())
	// a sibling test's child between fork and exec still shares the freed holders' lock for a
	// moment (close-on-exec closes it only at exec): retry briefly
	locked := false
	for _ in 0 ..< 100 {
		if flock(fd, LOCK_EX | LOCK_NB) == 0 {locked = true; break}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, locked, "could not take instance.lock exclusively")
	h, err = holder_new(cfg)
	testing.expect_value(t, err, Start_Error.Lock_Busy)
	holder_free(h)
	close(fd)
}

// A SPAWN whose child blocks before exec (a hung network cwd, a slow first-exec check) does not
// freeze the loop: PING still gets PONG, and SPAWNED comes once the exec happens; INPUT sent
// before it reaches the program. One that never gets to exec fails after spawn_timeout.
@(test)
spawn_blocked_before_exec :: proc(t: ^testing.T) {
	gate: [2]c.int
	sync.mutex_lock(&fork_lock)
	testing.expect(t, pipe(&gate) == 0)
	for fd in gate do set_cloexec(fd) // the gated child reads it before its exec
	sync.mutex_unlock(&fork_lock)
	defer close(gate[0])
	defer close(gate[1])
	cfg := test_cfg()
	// far past the PONG bound below while the first spawn waits (a loop that blocked until the
	// spawn timed out would miss it by seconds, however busy the machine); 400 ms for the second
	cfg.spawn_timeout = 10 * time.Second
	cfg.test_spawn_gate = gate[0]
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	sh_spawn(f, 1, `read x; printf 'got:%s\n' "$x"; exit 0`)
	fake_input(f, 1, "early\n")
	start := time.tick_now()
	fake_send(f, .Ping, 0, holderwire.Empty{})
	_, pong := wait_for(h, f, .Pong, 0, timeout = 5 * time.Second)
	testing.expect(t, pong, "no PONG while a SPAWN waits for its exec")
	testing.expectf(t, time.tick_since(start) < 5 * time.Second, "PONG after %v", time.tick_since(start))
	for g in f.frames do testing.expect(t, g.kind != .Spawned, "SPAWNED before the exec")
	// let it exec
	b: u8 = 1
	write(gate[1], &b, 1)
	_, spawned := wait_for(h, f, .Spawned, 1)
	testing.expect(t, spawned, "no SPAWNED after the exec")
	testing.expect(t, wait_output(t, h, f, 1, "got:early"), "INPUT before SPAWNED was lost")
	// never released: SPAWN_FAILED after spawn_timeout, the child is killed and reaped
	h.cfg.spawn_timeout = 400 * time.Millisecond
	sh_spawn(f, 2, "exit 0")
	g, failed := wait_for(h, f, .Spawn_Failed, 2, timeout = 10 * time.Second)
	m: holderwire.Spawn_Failed
	testing.expect(t, failed && decode_got(g, .Spawn_Failed, &m), "no SPAWN_FAILED for a spawn that never execs")
	testing.expectf(t, strings.contains(m.error, "timed out"), "error: %q", m.error)
	pump(h, 100 * time.Millisecond, f)
	testing.expect(t, live_term(h, 2) == nil)
}

// Before HELLO: a connection that trickles bytes is dropped hello_timeout after accept (not kept
// alive by them), and a header of any other kind, or a HELLO past MAX_CONTROL, is refused as
// soon as its 9 bytes are in (nothing of a big payload is buffered).
@(test)
hello_deadline_and_early_headers :: proc(t: ^testing.T) {
	cfg := test_cfg()
	cfg.hello_timeout = 300 * time.Millisecond
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	a := fake_connect(t, h)
	defer fake_free(a)
	hdr := make([dynamic]u8, context.temp_allocator)
	holderwire.put_header(&hdr, u8(holderwire.Kind.Hello), 0, 100)
	// One byte per 30 ms pump: the trickle lasts at least 109 * 30 ms (3.27 s), however busy the
	// machine, against a 300 ms deadline. Dropped while it still trickles is the deadline from
	// accept; a deadline that each byte pushed back would drop it only after the trickle stopped.
	// (No wall-clock bound: a loaded runner stretches every pump, not the order of the two.)
	TRICKLE :: 9 + 100
	start := time.tick_now()
	sent := 0
	for !a.eof && sent < TRICKLE && time.tick_since(start) < 30 * time.Second {
		if sent < len(hdr) do fake_write(a, hdr[sent:sent + 1])
		else do fake_write(a, transmute([]u8)string(" "))
		sent += 1
		pump(h, 30 * time.Millisecond, a)
	}
	testing.expectf(t, a.eof, "a trickling connection was kept open (%d bytes over %v)", sent, time.tick_since(start))
	testing.expectf(t, sent < TRICKLE, "dropped only once the trickle stopped (%v): each byte pushed the deadline back", time.tick_since(start))

	// Refused on the header alone, not at the deadline: with it an hour away, a drop at all is the
	// refusal (no time bound to miss on a busy machine).
	h.cfg.hello_timeout = time.Hour
	for kind in ([]u8{u8(holderwire.Kind.Input), u8(holderwire.Kind.Hello)}) {
		b := fake_connect(t, h)
		defer fake_free(b)
		raw := make([dynamic]u8, context.temp_allocator)
		size := kind == u8(holderwire.Kind.Hello) ? u32(holderwire.MAX_CONTROL + 1) : u32(holderwire.MAX_PAYLOAD)
		holderwire.put_header(&raw, kind, 1, int(size))
		append(&raw, ..make([]u8, 1000, context.temp_allocator))
		fake_write(b, raw[:])
		testing.expectf(t, wait_eof(h, b, 10 * time.Second), "kind %d: not dropped", kind)
	}
}

// INPUT for a program that does not read is queued up to input_cap: past it the core's
// connection is not read (the paste waits), and after input_stall (under the app's 5 s write
// timeout) the queue is dropped so the connection never stalls long. The core stays attached.
@(test)
input_queue_is_capped :: proc(t: ^testing.T) {
	cfg := test_cfg()
	cfg.input_stall = 100 * time.Millisecond
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	// raw: a canonical-mode tty drops input past its line limit, so the queue would stay empty
	spawn_ok(t, h, f, 1, "stty raw -echo; exec /bin/sleep 60")
	chunk := make([]u8, 1024 * 1024, context.temp_allocator)
	for &b in chunk do b = 'x'
	frame := make([dynamic]u8, context.temp_allocator)
	holderwire.encode_input(&frame, 1, chunk)
	TOTAL :: 64 * 1024 * 1024
	sent, at, most := 0, 0, 0
	start := time.tick_now()
	for sent < TOTAL && time.tick_since(start) < 5 * time.Second {
		left := len(frame) - at
		n := send(f.fd, &frame[at], c.size_t(left), MSG_NOSIGNAL)
		if n > 0 {
			at += int(n)
			if at == len(frame) {
				at = 0
				sent += len(chunk)
			}
		}
		holder_step(h, 0)
		if term := live_term(h, 1); term != nil do most = max(most, len(term.input))
		fake_read(f)
	}
	testing.expectf(t, sent == TOTAL, "only %d bytes went in %v", sent, time.tick_since(start))
	testing.expectf(t, most <= QUEUE_CAP_INPUT + len(frame) + READ_CHUNK, "INPUT queued up to %d bytes", most)
	fake_send(f, .Ping, 0, holderwire.Empty{})
	_, pong := wait_for(h, f, .Pong)
	testing.expect(t, pong && h.core != nil, "the core was dropped")
}

// accept() failing with EMFILE leaves the listener readable: it is left out of poll for a
// moment (no 100% CPU spin), and the waiting connection is accepted once fds are free again.
@(test)
accept_emfile_backs_off :: proc(t: ^testing.T) {
	r: [4]u8
	crypto.rand_bytes(r[:])
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	run := fmt.tprintf("%s/dh-emfile-%s", tmp, string(hex.encode(r[:], context.temp_allocator)))
	crun := strings.clone_to_cstring(run, context.temp_allocator)
	testing.expect_value(t, mkdir(crun, 0o700), 0)
	defer rmdir(crun)
	cfg := test_cfg()
	cfg.run_dir = run
	cfg.test_accept_errno = EMFILE
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	if h == nil do return

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX
	for i in 0 ..< len(h.sock_path) do addr.sun_path[i] = c.char(h.sock_path[i])
	addr.sun_len = u8(size_of(addr))
	sync.mutex_lock(&fork_lock)
	fd := posix.FD(socket(AF_UNIX, SOCK_STREAM, 0))
	set_cloexec(c.int(fd))
	sync.mutex_unlock(&fork_lock)
	defer posix.close(fd)
	testing.expect(t, posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK)

	steps := 0
	logged := h.logged
	start := time.tick_now()
	for time.tick_since(start) < 300 * time.Millisecond {
		holder_step(h, 50)
		steps += 1
	}
	testing.expectf(t, steps < 30, "%d loop iterations in 300 ms with accept failing", steps)
	testing.expectf(t, h.logged - logged == 1, "%d log lines in 300 ms out of fds (one until an accept works)", h.logged - logged)
	h.cfg.test_accept_errno = 0
	start = time.tick_now()
	for len(h.conns) == 0 && time.tick_since(start) < time.Second do holder_step(h, 20)
	testing.expect_value(t, len(h.conns), 1)
}

// A SPAWNed program holds only 0, 1 and 2: no master of another terminal, no socket, no lock.
// The fds this process inherited (a CI runner hands its shells some: GitHub's macOS one 131,
// 140, ...) are made close-on-exec first, as hold_main does at start (cloexec_inherited); every
// fd a holder opens after that is checked.
@(test)
child_holds_only_stdio :: proc(t: ^testing.T) {
	sync.mutex_lock(&fork_lock)
	cloexec_inherited()
	sync.mutex_unlock(&fork_lock)
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, "exec /bin/sleep 5") // another terminal's master is open meanwhile
	// ls lists what it inherited plus the two it opens to read the directory (3 and 4, the lowest
	// free ones, if none leaked; as from a clean shell)
	spawn_ok(t, h, f, 2, `exec /bin/ls /dev/fd`)
	_, ok := exited_of(t, h, f, 2)
	testing.expect(t, ok)
	out := strings.fields(output_of(t, f, 2), context.temp_allocator)
	testing.expectf(t, slice_eq(out, []string{"0", "1", "2", "3", "4"}), "the child holds more than 0-2: %v", out)
}

slice_eq :: proc(a, b: []string) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if x != b[i] do return false
	return true
}

// raise_fd_limit is the holder's own: a session starts with the soft limit the holder was
// started with (launchd's 256, a shell's), not the raised one.
@(test)
child_gets_original_fd_limit :: proc(t: ^testing.T) {
	orig: Rlimit
	testing.expect_value(t, getrlimit(RLIMIT_NOFILE, &orig), 0)
	defer setrlimit(RLIMIT_NOFILE, &orig)
	low := orig
	low.cur = min(orig.cur, 256)
	testing.expect_value(t, setrlimit(RLIMIT_NOFILE, &low), 0)
	raise_fd_limit()
	now: Rlimit
	getrlimit(RLIMIT_NOFILE, &now)
	testing.expect(t, now.cur > low.cur || low.cur >= min(orig.max, OPEN_MAX), "not raised")
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	hello(t, h, f)
	spawn_ok(t, h, f, 1, "ulimit -n")
	_, ok := exited_of(t, h, f, 1)
	testing.expect(t, ok)
	testing.expect_value(t, strings.trim_space(output_of(t, f, 1)), fmt.tprintf("%d", low.cur))
}

// At start the holder makes every fd above 2 it inherited close-on-exec: a launcher that
// leaked one (a shell, a CI runner) never hands it to the sessions.
@(test)
inherited_fds_made_cloexec :: proc(t: ^testing.T) {
	F_GETFD :: 1
	sync.mutex_lock(&fork_lock)
	fds: [2]c.int
	testing.expect_value(t, pipe(&fds), 0) // not close-on-exec, as inherited
	cloexec_inherited()
	sync.mutex_unlock(&fork_lock)
	defer close(fds[0])
	defer close(fds[1])
	for fd in fds do testing.expectf(t, fcntl(fd, F_GETFD) & FD_CLOEXEC != 0, "fd %d is not close-on-exec", fd)
	for fd in c.int(0) ..< 3 do testing.expectf(t, fcntl(fd, F_GETFD) & FD_CLOEXEC == 0, "stdio fd %d was made close-on-exec", fd)
}

// GOODBYE{handover, successor}: the ack carries a fresh 256-bit secret; until it is used or
// SUCCESSOR_TTL passes, only a HELLO with it is welcomed (REFUSED{secret} otherwise), and only
// once. A plain handover names no successor: no secret, any core may follow.
@(test)
successor_secret_reserves_the_holder :: proc(t: ^testing.T) {
	cfg := test_cfg()
	cfg.successor_ttl = 400 * time.Millisecond
	h := new_test_holder(t, cfg)
	defer holder_free(h, true)
	handover :: proc(t: ^testing.T, h: ^Holder, f: ^Fake, successor: bool) -> string {
		fake_send(f, .Goodbye, 0, holderwire.Goodbye{mode = "handover", successor = successor})
		g, ok := wait_for(h, f, .Goodbye_Ack)
		ack: holderwire.Goodbye_Ack
		testing.expect(t, ok && decode_got(g, .Goodbye_Ack, &ack))
		fake_hangup(f)
		testing.expect(t, wait_eof(h, f))
		return strings.clone(ack.successor_secret, context.temp_allocator)
	}
	refused :: proc(t: ^testing.T, h: ^Holder, secret: string) {
		f := fake_connect(t, h)
		defer fake_free(f)
		fake_send(f, .Hello, 0, holderwire.Hello{wire = holderwire.WIRE, successor_secret = secret})
		g, ok := wait_for(h, f, .Refused)
		r: holderwire.Refused
		testing.expect(t, ok && decode_got(g, .Refused, &r), "not refused")
		testing.expect_value(t, r.code, "secret")
		testing.expect(t, !strings.contains(r.error, secret) || secret == "", "the secret in a REFUSED")
		// it lingers until the core closes (the core must still read its peer on the REFUSED)
		pump(h, 30 * time.Millisecond, f)
		testing.expect(t, !f.eof, "closed right after REFUSED")
		fake_hangup(f)
		testing.expect(t, wait_eof(h, f))
	}
	a := fake_connect(t, h)
	defer fake_free(a)
	hello(t, h, a)
	secret := handover(t, h, a, true)
	testing.expect_value(t, len(secret), 64)
	refused(t, h, "") // a core that was not named
	refused(t, h, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
	refused(t, h, secret[:32])
	b := fake_connect(t, h)
	defer fake_free(b)
	fake_send(b, .Hello, 0, holderwire.Hello{wire = holderwire.WIRE, successor_secret = secret})
	_, ok := wait_for(h, b, .Welcome)
	testing.expect(t, ok, "the successor was not welcomed")
	// used: the next handover's secret is a new one, and the old one opens nothing
	secret2 := handover(t, h, b, true)
	testing.expect(t, len(secret2) == 64 && secret2 != secret)
	refused(t, h, secret)
	// expired: anyone may connect again (a crash-style restart: the successor never came)
	pump(h, cfg.successor_ttl + 50 * time.Millisecond)
	c2 := fake_connect(t, h)
	defer fake_free(c2)
	hello(t, h, c2)
	// a plain handover (a quit): no secret, any core follows
	testing.expect_value(t, handover(t, h, c2, false), "")
	d := fake_connect(t, h)
	defer fake_free(d)
	w := hello(t, h, d)
	testing.expect_value(t, w.previous, "handover")
	for fk in ([]^Fake{a, b}) do for fr in fk.frames {
		testing.expectf(t, !strings.contains(string(fr.payload), secret2) || fr.kind == .Goodbye_Ack, "the secret in a %v frame", fr.kind)
	}
}
