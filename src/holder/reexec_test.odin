#+build darwin
package holder

// UPGRADE with real processes (docs/plans/background-core.md §7.3, §12 "Holder re-exec"): the
// holder binary built with test hooks (build/deckhand-core-hooks, ./build.sh test), started
// directly (no launchd) in a per-test dir under /tmp, with this test as its core over the real
// socket. Every test kills what it started (the sessions, the holder, a keeper) and removes its dir.
//
//   reexec_under_load         5 upgrades while 5 terminals count and one takes 400 KB of input:
//                             same pid, same parent of every session, no output gap, every
//                             input byte once and in order, a spawn after them starts with
//                             default signals and an empty mask
//   reexec_refusals           UPGRADE_FAILED and the holder carries on (the same connection):
//                             a relative or missing path, a binary with the wrong identifier, a
//                             failed dry run, a failed execve
//   reexec_swapped_binary     the binary is swapped after every check, before execve: the swapped
//                             image gets the pid but not the terminals; the keeper serves them
//                             (degraded) and reports their exit codes
//   reexec_new_image_killed   the new image dies after taking the state, before DONE: the keeper
//                             keeps the terminals, exit codes included

import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "../holderwire"

HOOKS_BIN :: "build/deckhand-core-hooks"
SWAPPED_BIN :: "build/deckhand-core-swapped" // the same, signed as dev.deckhand.swapped

Rig :: struct {
	dir, run, data, hooks: string,
	bin:                   string, // absolute
	pid:                   c.int, // the holder we started
	sock:                  string,
	f:                     ^Fake,
	done:                  int, // frames of f handled by rig_absorb
	next:                  map[u32]u64,
	out:                   map[u32][dynamic]u8,
	gaps:                  int,
	instance:              string,
	extra:                 [dynamic]c.int, // more pids to kill at the end (a keeper)
	pids:                  [dynamic]c.int, // the sessions (their process groups are killed)
}

abs_path :: proc(p: string) -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	return fmt.tprintf("%s/%s", cwd, p)
}

rig_new :: proc(t: ^testing.T) -> (^Rig, bool) {
	r := new(Rig)
	b: [4]u8
	crypto.rand_bytes(b[:])
	r.dir = fmt.aprintf("/tmp/dhx-%s", string(hex.encode(b[:], context.temp_allocator)))
	r.run = fmt.aprintf("%s/r", r.dir)
	r.data = fmt.aprintf("%s/d", r.dir)
	r.hooks = fmt.aprintf("%s/h", r.dir)
	for d in ([]string{r.dir, r.run, r.data, r.hooks}) do posix.mkdir(strings.clone_to_cstring(d, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	r.bin = strings.clone(abs_path(HOOKS_BIN))
	if !os.is_file(r.bin) {
		testing.expect(t, false, "build/deckhand-core-hooks is missing: run ./build.sh test")
		return r, false
	}
	return r, true
}

rig_free :: proc(t: ^testing.T, r: ^Rig) {
	if t.error_count > 0 || os.get_env("DH_REEXEC_LOG", context.temp_allocator) != "" {
		b, _ := os.read_entire_file(fmt.tprintf("%s/holder.log", r.dir), context.temp_allocator)
		fmt.eprintf("---- %s/holder.log ----\n%s----\n", r.dir, string(b))
	}
	for p in r.pids do kill(-p, SIGKILL)
	for p in r.pids do kill(p, SIGKILL)
	for p in r.extra do kill(p, SIGKILL)
	if r.pid > 0 {
		kill(r.pid, SIGKILL)
		st: c.int
		waitpid(r.pid, &st, 0)
	}
	if r.f != nil do fake_free(r.f)
	os.remove_all(r.dir)
	for _, &o in r.out do delete(o)
	delete(r.out)
	delete(r.next)
	delete(r.extra)
	delete(r.pids)
	delete(r.dir); delete(r.run); delete(r.data); delete(r.hooks); delete(r.bin); delete(r.sock); delete(r.instance)
	free(r)
}

rig_hook :: proc(r: ^Rig, name: string, content := "") {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", r.hooks, name), transmute([]u8)content)
}

// The holder, started directly (its stderr in <dir>/holder.log), and its socket.
rig_start :: proc(t: ^testing.T, r: ^Rig) -> bool {
	argv := []cstring{strings.clone_to_cstring(r.bin, context.temp_allocator), "hold", "--run", strings.clone_to_cstring(r.run, context.temp_allocator), "--data", strings.clone_to_cstring(r.data, context.temp_allocator), nil}
	env := []cstring{"PATH=/usr/bin:/bin", strings.clone_to_cstring(fmt.tprintf("DECKHAND_HOLDER_HOOKS=%s", r.hooks), context.temp_allocator), nil}
	logp := strings.clone_to_cstring(fmt.tprintf("%s/holder.log", r.dir), context.temp_allocator)
	sync_lock()
	pid := posix.fork()
	if pid == 0 {
		fd := open(logp, O_RDWR | O_CREAT, c.uint(0o600))
		if fd >= 0 {
			posix.dup2(posix.FD(fd), 1)
			posix.dup2(posix.FD(fd), 2)
		}
		execve(argv[0], raw_data(argv), raw_data(env))
		_exit(127)
	}
	sync_unlock()
	r.pid = c.int(pid)
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		files, _ := os.read_all_directory_by_path(r.run, context.temp_allocator)
		for fi in files do if strings.has_prefix(fi.name, "holder-") && strings.has_suffix(fi.name, ".sock") {
			r.sock = strings.clone(fi.fullpath)
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, false, "the holder did not listen")
	return false
}

// Connects (retrying while the socket does not answer) and says HELLO; the WELCOME, its TAILs
// absorbed into the streams.
rig_attach :: proc(t: ^testing.T, r: ^Rig, timeout := 15 * time.Second) -> (w: holderwire.Welcome, ok: bool) {
	if r.f != nil do fake_free(r.f)
	r.f, r.done = nil, 0
	start := time.tick_now()
	for r.f == nil {
		if time.tick_since(start) > timeout {
			testing.expect(t, false, "cannot connect to the holder")
			return
		}
		fd := posix.socket(.UNIX, .STREAM)
		addr: posix.sockaddr_un
		addr.sun_family = .UNIX
		for ch, i in r.sock do addr.sun_path[i] = c.char(ch)
		addr.sun_len = u8(size_of(addr))
		if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK {
			set_cloexec(c.int(fd))
			set_nonblock(c.int(fd))
			set_nosigpipe(c.int(fd))
			r.f = new(Fake)
			r.f.fd = c.int(fd)
		} else {
			posix.close(fd)
			time.sleep(5 * time.Millisecond)
		}
	}
	rig_send(r, .Hello, 0, holderwire.Hello{wire = holderwire.WIRE})
	g, gok := rig_wait(r, .Welcome, 0, timeout)
	if !gok {
		testing.expect(t, false, "no WELCOME")
		return
	}
	testing.expect(t, decode_got(g, .Welcome, &w))
	// its TAILs follow, one per terminal
	for wt in w.terminals do rig_wait(r, .Tail, u32(wt.id))
	return w, true
}

rig_write :: proc(r: ^Rig, b: []u8) {
	rest := b
	for len(rest) > 0 {
		n := send(r.f.fd, raw_data(rest), c.size_t(len(rest)), MSG_NOSIGNAL)
		if n > 0 {
			rest = rest[n:]
			continue
		}
		if n < 0 && errno() != EAGAIN && errno() != EINTR do return
		rig_read(r, 2) // the holder may wait for us to read
	}
}

rig_send :: proc(r: ^Rig, kind: holderwire.Kind, term: u32, msg: $T) {
	out := make([dynamic]u8, context.temp_allocator)
	holderwire.encode(&out, kind, term, msg)
	rig_write(r, out[:])
}

rig_input :: proc(r: ^Rig, term: u32, b: []u8) {
	out := make([dynamic]u8, context.temp_allocator)
	holderwire.encode_input(&out, term, b)
	rig_write(r, out[:])
}

// Reads what is there (waiting up to ms), and puts OUTPUT and TAIL bytes in each terminal's
// stream: an overlap is skipped, a hole is a gap.
rig_read :: proc(r: ^Rig, ms: int) {
	pfd := Pollfd{fd = r.f.fd, events = POLLIN}
	poll(&pfd, 1, c.int(ms))
	fake_read(r.f)
	for ; r.done < len(r.f.frames); r.done += 1 {
		g := r.f.frames[r.done]
		if g.kind != .Output && g.kind != .Tail do continue
		start, b, _ := holderwire.decode_output(holderwire.Frame{u8(g.kind), g.term, g.payload})
		next := r.next[g.term]
		if start > next {
			r.gaps += 1
			fmt.eprintfln("terminal %d: a gap: %v starts at %d, the stream is at %d", g.term, g.kind, start, next)
			next = start
		}
		skip := int(min(next - start, u64(len(b))))
		if g.term not_in r.out do r.out[g.term] = make([dynamic]u8)
		append(&r.out[g.term], ..b[skip:])
		r.next[g.term] = max(next, start + u64(len(b)))
	}
}

rig_wait :: proc(r: ^Rig, kind: holderwire.Kind, term: u32 = 0, timeout := 5 * time.Second) -> (Got, bool) {
	start := time.tick_now()
	for {
		for r.f.seen < len(r.f.frames) {
			g := r.f.frames[r.f.seen]
			r.f.seen += 1
			if g.kind == kind && g.term == term do return g, true
		}
		if r.f.eof || time.tick_since(start) > timeout do return {}, false
		rig_read(r, 10)
	}
}

rig_pump :: proc(r: ^Rig, d: time.Duration) {
	start := time.tick_now()
	for time.tick_since(start) < d && !r.f.eof do rig_read(r, 5)
}

rig_spawn :: proc(t: ^testing.T, r: ^Rig, id: u32, script: string) -> c.int {
	rig_send(r, .Spawn, id, holderwire.Spawn {
		argv = {"/bin/sh", "-c", script}, env = {"PATH=/usr/bin:/bin", "LANG=C"}, cwd = "/",
		cols = 80, rows = 24, xpixel = 640, ypixel = 384,
	})
	g, ok := rig_wait(r, .Spawned, id)
	testing.expectf(t, ok, "terminal %d: no SPAWNED", id)
	s: holderwire.Spawned
	decode_got(g, .Spawned, &s)
	append(&r.pids, c.int(s.pid))
	return c.int(s.pid)
}

rig_text :: proc(r: ^Rig, id: u32) -> string {return string(r.out[id][:]) if id in r.out else ""}

rig_wait_text :: proc(r: ^Rig, id: u32, want: string, timeout := 5 * time.Second) -> bool {
	start := time.tick_now()
	for !strings.contains(rig_text(r, id), want) {
		if time.tick_since(start) > timeout || r.f.eof do return false
		rig_read(r, 5)
	}
	return true
}

// UPGRADE and wait for its outcome: the connection closes (it happened) or UPGRADE_FAILED.
rig_upgrade :: proc(r: ^Rig, path: string) -> (failed: string, closed: bool) {
	rig_send(r, .Upgrade, 0, holderwire.Upgrade{path = path})
	start := time.tick_now()
	for time.tick_since(start) < 20 * time.Second {
		for r.f.seen < len(r.f.frames) {
			g := r.f.frames[r.f.seen]
			r.f.seen += 1
			if g.kind == .Upgrade_Failed {
				m: holderwire.Upgrade_Failed
				decode_got(g, .Upgrade_Failed, &m)
				return m.error, false
			}
		}
		if r.f.eof do return "", true
		rig_read(r, 10)
	}
	return "timed out", false
}

COUNTER :: `i=0; while :; do echo "c$i"; i=$((i+1)); /bin/sleep 0.005; done`

// The counter lines "c0", "c1", ... with none missing, none twice (the last, partial line aside).
counters_ok :: proc(t: ^testing.T, text: string, id: u32) -> int {
	lines := strings.split(text, "\n", context.temp_allocator)
	want := 0
	for l in lines[:max(len(lines) - 1, 0)] {
		v := strings.trim_right(l, "\r")
		n, ok := strconv.parse_int(strings.trim_prefix(v, "c"), 10)
		if !ok || n != want {
			testing.expectf(t, false, "terminal %d: line %q after c%d", id, v, want - 1)
			return want
		}
		want += 1
	}
	return want
}

proc_ppid :: proc(pid: c.int) -> c.int {
	info: [136]u8 // struct proc_bsdinfo
	if proc_pidinfo(pid, 3, 0, &info, size_of(info)) != size_of(info) do return -1 // PROC_PIDTBSDINFO
	v := (^u32)(&info[16])^ // pbi_ppid
	return c.int(v)
}

@(test)
reexec_under_load :: proc(t: ^testing.T) {
	r, ok := rig_new(t)
	defer rig_free(t, r)
	if !ok || !rig_start(t, r) do return
	rig_hook(r, "dirty-signals") // every old image ignores SIGPIPE and blocks SIGUSR2 before execve
	w, _ := rig_attach(t, r)
	r.instance = strings.clone(w.instance)
	testing.expect_value(t, w.pid, i64(r.pid))
	kids: [6]c.int
	for id in u32(1) ..= 5 do kids[id - 1] = rig_spawn(t, r, id, COUNTER)
	sink := fmt.tprintf("%s/in6", r.dir)
	kids[5] = rig_spawn(t, r, 6, fmt.tprintf(`stty raw -echo; printf R; exec /bin/cat > %s`, sink))
	testing.expect(t, rig_wait_text(r, 6, "R"))
	sent := make([dynamic]u8, context.temp_allocator)
	for k in 0 ..< 5 {
		// input in flight: 40 frames of 2000 bytes, the last just before UPGRADE
		for j in 0 ..< 40 {
			chunk := make([]u8, 2000, context.temp_allocator)
			head := fmt.tprintf("<%d.%d>", k, j)
			for i in 0 ..< len(chunk) do chunk[i] = 'a' + u8((i + j) % 26)
			copy(chunk, head)
			rig_input(r, 6, chunk)
			append(&sent, ..chunk)
		}
		rig_pump(r, 30 * time.Millisecond)
		failed, closed := rig_upgrade(r, r.bin)
		testing.expectf(t, closed, "upgrade %d: %q", k, failed)
		if !closed do return
		w2, aok := rig_attach(t, r)
		if !aok do return
		testing.expect_value(t, w2.pid, i64(r.pid))
		testing.expect_value(t, w2.previous, "upgrade")
		testing.expect_value(t, w2.instance, r.instance)
		testing.expect_value(t, len(w2.terminals), 6)
		testing.expect_value(t, w2.upgrade_error, "")
		for wt in w2.terminals do testing.expectf(t, wt.degraded == nil && wt.exit == nil, "terminal %d after upgrade %d", wt.id, k)
		rig_pump(r, 150 * time.Millisecond)
	}
	testing.expect_value(t, r.gaps, 0)
	for id in u32(1) ..= 5 {
		n := counters_ok(t, rig_text(r, id), id)
		testing.expectf(t, n > 20, "terminal %d counted only %d", id, n)
	}
	// every input byte, once, in order
	start := time.tick_now()
	got: []u8
	for time.tick_since(start) < 5 * time.Second {
		got, _ = os.read_entire_file(sink, context.temp_allocator)
		if len(got) >= len(sent) do break
		rig_read(r, 20)
	}
	testing.expectf(t, string(got) == string(sent[:]), "input: %d bytes arrived of %d", len(got), len(sent))
	// the sessions are still the holder's children, and the holder never changed pid
	for k in kids do testing.expectf(t, proc_ppid(k) == r.pid, "session %d has parent %d, not %d", k, proc_ppid(k), r.pid)
	// P1: a session spawned now starts with default signals and an empty mask
	rig_spawn(t, r, 7, `(yes; echo "st=$?" >&2) | head -c 1 >/dev/null; exec /bin/ps -o sigmask= -p $$`)
	_, eok := rig_wait(r, .Exited, 7)
	testing.expect(t, eok)
	out := rig_text(r, 7)
	testing.expectf(t, strings.contains(out, "st=141"), "SIGPIPE not default after the upgrades: %q", out)
	ls := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	testing.expectf(t, strings.trim_space(ls[len(ls) - 1]) == "0", "a blocked mask leaked: %q", out)
}

@(test)
reexec_refusals :: proc(t: ^testing.T) {
	r, ok := rig_new(t)
	defer rig_free(t, r)
	if !ok || !rig_start(t, r) do return
	rig_attach(t, r)
	rig_spawn(t, r, 1, COUNTER)
	testing.expect(t, rig_wait_text(r, 1, "c3\r\n"))
	swapped := abs_path(SWAPPED_BIN)
	cases := []struct {
		path, hook, want: string,
	} {
		{"build/deckhand-core-hooks", "", "absolute"},
		{"/nonexistent/deckhand-core", "", "not a file"},
		{swapped, "", "Wrong_Identity"},
		{"/bin/sh", "", "Wrong_Identity"},
		{r.bin, "dry-run-fail", "dry run"},
		{r.bin, "exec-fail", "execve"},
	}
	for cs in cases {
		if cs.hook != "" do rig_hook(r, cs.hook)
		failed, closed := rig_upgrade(r, cs.path)
		testing.expectf(t, !closed && strings.contains(failed, cs.want), "%s (%s): %q", cs.path, cs.hook, failed)
		if closed do return
		// the same connection, the same holder, still counting
		rig_send(r, .Ping, 0, holderwire.Empty{})
		_, pok := rig_wait(r, .Pong)
		testing.expectf(t, pok, "%s (%s): no PONG", cs.path, cs.hook)
	}
	n := counters_ok(t, rig_text(r, 1), 1)
	rig_pump(r, 100 * time.Millisecond)
	testing.expect(t, counters_ok(t, rig_text(r, 1), 1) > n)
	testing.expect_value(t, r.gaps, 0)
}

// The keeper keeps the terminals (hook: how the new image fails): the next WELCOME comes from the
// keeper's pid, every terminal degraded, output without a gap, exit codes and signals reported.
adopt_case :: proc(t: ^testing.T, swap: bool) {
	r, ok := rig_new(t)
	defer rig_free(t, r)
	if !ok || !rig_start(t, r) do return
	w, _ := rig_attach(t, r)
	for id in u32(1) ..= 3 do rig_spawn(t, r, id, COUNTER)
	rig_spawn(t, r, 4, `printf 'ready\n'; read x; exit 3`)
	rig_spawn(t, r, 5, `printf 'ready\n'; exec /bin/sleep 600`)
	testing.expect(t, rig_wait_text(r, 4, "ready") && rig_wait_text(r, 5, "ready"))
	path := r.bin
	if swap {
		path = fmt.tprintf("%s/core-a", r.dir)
		evil := fmt.tprintf("%s/core-evil", r.dir)
		for pair in ([][2]string{{r.bin, path}, {abs_path(SWAPPED_BIN), evil}}) {
			b, _ := os.read_entire_file(pair[0], context.temp_allocator)
			_ = os.write_entire_file(pair[1], b)
			posix.chmod(strings.clone_to_cstring(pair[1], context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
		}
		rig_hook(r, "swap", evil)
	} else {
		rig_hook(r, "crash-resume")
	}
	failed, closed := rig_upgrade(r, path)
	testing.expectf(t, closed, "upgrade: %q", failed)
	if !closed do return
	w2, aok := rig_attach(t, r)
	if !aok do return
	if w2.pid > 0 && w2.pid != i64(r.pid) do append(&r.extra, c.int(w2.pid))
	testing.expectf(t, w2.pid != i64(r.pid), "the WELCOME is from the holder's pid %d, not a keeper", w2.pid)
	testing.expect_value(t, w2.previous, "upgrade")
	testing.expect_value(t, w2.instance, w.instance)
	testing.expectf(t, strings.contains(w2.upgrade_error, swap ? "failed verification" : "stopped"), "upgrade_error %q", w2.upgrade_error)
	testing.expect_value(t, len(w2.terminals), 5)
	for wt in w2.terminals do testing.expectf(t, wt.degraded.? or_else false, "terminal %d is not degraded", wt.id)
	// the image that ran (the holder's pid) ends with no terminals: it was refused or it crashed
	st: c.int
	deadline := time.tick_now()
	for waitpid(r.pid, &st, WNOHANG) != r.pid {
		if time.tick_since(deadline) > 5 * time.Second {
			testing.expect(t, false, "the new image is still running")
			return
		}
		rig_read(r, 10)
	}
	r.pid = -1
	code, _, _ := exit_from_wait(st)
	testing.expect_value(t, code, 1)
	// output goes on, without a gap, input works, exits are known (NOTE_EXITSTATUS)
	rig_pump(r, 200 * time.Millisecond)
	for id in u32(1) ..= 3 do testing.expect(t, counters_ok(t, rig_text(r, id), id) > 10)
	testing.expect_value(t, r.gaps, 0)
	rig_input(r, 4, transmute([]u8)string("x\n"))
	g, eok := rig_wait(r, .Exited, 4)
	e: holderwire.Exited
	testing.expect(t, eok && decode_got(g, .Exited, &e))
	testing.expect_value(t, e.code, 3)
	testing.expect_value(t, e.signal, 0)
	testing.expect_value(t, e.offset, r.next[4])
	rig_send(r, .Signal, 5, holderwire.Signal{signal = 15, target = "pid"})
	g, eok = rig_wait(r, .Exited, 5)
	testing.expect(t, eok && decode_got(g, .Exited, &e))
	testing.expect_value(t, e.signal, 15)
	// a new session is the keeper's own child, not degraded
	pid := rig_spawn(t, r, 9, `printf hi; exit 5`)
	testing.expect_value(t, proc_ppid(pid), c.int(w2.pid))
	g, eok = rig_wait(r, .Exited, 9)
	testing.expect(t, eok && decode_got(g, .Exited, &e) && e.code == 5)
}

@(test)
reexec_swapped_binary :: proc(t: ^testing.T) {adopt_case(t, swap = true)}

@(test)
reexec_new_image_killed :: proc(t: ^testing.T) {adopt_case(t, swap = false)}
