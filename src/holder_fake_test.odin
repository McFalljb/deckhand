package main

// A fake session holder for the app side's tests (holder_client_test.odin): one listening
// socket in a temp runtime dir, served by a thread that answers HELLO as told (WELCOME with
// the given terminals and TAILs, REFUSED, or nothing), then records every frame the app sends
// and answers SPAWN, PING and GOODBYE. It runs in this process, so the peer checks pass (same
// pid at both ends). Never the real holder, never launchd (PI_DESK_HOLDER_DIRECT=1 in case a
// start falls through to a launch).

import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import hw "holderwire"

Fake_Mode :: enum {
	Welcome,
	Refuse,
	Silent, // accepts, never answers
	Hangup, // accepts one connection, closes it unanswered and goes away (a holder shutting down)
}

Fake_Got :: struct {
	kind:     hw.Kind,
	terminal: u32,
	mode:     string, // GOODBYE's
}

Fake_Holder :: struct {
	mode:      Fake_Mode,
	refuse_code: string, // .Refuse's code ("wire" when empty)
	no_read:   bool, // after the WELCOME, never read again (the app's sends block)
	no_listen: bool, // only the dirs: no socket, no thread
	instance:  string,
	previous:  string,
	terms:     []hw.Welcome_Terminal,
	tails:     [][]u8, // one per terminal (its offset - len = the TAIL's start)
	output:    []u8, // sent as OUTPUT of the first terminal right after the TAILs (while the app attaches)
	// UPGRADE: the fake closes the connection, as the exec does, and answers the reattach with
	// WELCOME{previous: upgrade}, the TAILs and then, in the same write, this as OUTPUT of the
	// first terminal and its EXITED (code 7). After that it sends nothing more, PONG included.
	upgrade_output: []u8,
	upgraded:  bool,
	key:       [32]u8,
	dir:       string, // the runtime dir (also home_root/..)
	path:      string,
	lfd, cfd:  Sock_Fd,
	th:        ^thread.Thread,
	mu:        sync.Mutex,
	got:       [dynamic]Fake_Got,
	stop:      bool,
	saved_root: string,
}

// A runtime dir and data dir of the test's own, the fake listening in it. keep_sessions as given.
fake_holder_start :: proc(t: ^testing.T, f: ^Fake_Holder, keep := true) {
	context.allocator = runtime.heap_allocator()
	for i in 0 ..< 32 do f.key[i] = u8(i * 13 + 1)
	if f.instance == "" do f.instance = "fake-instance-1"
	if f.previous == "" do f.previous = "handover"
	f.dir = fmt.aprintf("%s/dkf-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.set_env("PI_DESK_RUNTIME_DIR", f.dir)
	os.set_env("PI_DESK_HOLDER_DIRECT", "1") // never launchd, whatever a start falls through to
	testing.expect_value(t, runtime_dir_prepare(f.dir, RUNTIME_HOLDER_NEED), "")
	f.saved_root = home_root
	home_root = fmt.aprintf("%s/data", f.dir)
	os.make_directory_all(home_root)
	f.path = fmt.aprintf("%s/holder-0000fa01.sock", f.dir)
	f.cfd, f.lfd = -1, -1
	holder_client_forget()
	holder_test_allowed = true
	state.settings.keep_sessions = keep
	if f.no_listen do return
	ok: bool
	f.lfd, ok = sock_listen(f.path)
	testing.expect(t, ok, "fake holder listens")
	f.th = thread.create_and_start_with_data(f, fake_holder_main)
}

fake_holder_stop :: proc(f: ^Fake_Holder) {
	if hc.on do holder_shutdown() // whatever it attached to stops (a real holder, if a test went wrong)
	holder_client_forget()
	holder_test_allowed = false
	sync.atomic_store(&f.stop, true)
	if f.cfd >= 0 do sock_shutdown(f.cfd)
	if f.th != nil {
		thread.join(f.th)
		thread.destroy(f.th)
	}
	if f.lfd >= 0 {
		sock_close(f.lfd)
		sock_unlink(f.path)
	}
	socket_tokens_disable(false)
	home_root = f.saved_root
	os.unset_env("PI_DESK_HOLDER_DIRECT")
	state.settings.keep_sessions = false
	delete(f.got)
}

// The frames the app sent so far (after HELLO), copied.
fake_holder_got :: proc(f: ^Fake_Holder) -> []Fake_Got {
	sync.lock(&f.mu)
	defer sync.unlock(&f.mu)
	return strings_clone_got(f.got[:])
}

@(private = "file")
strings_clone_got :: proc(g: []Fake_Got) -> []Fake_Got {
	out := make([]Fake_Got, len(g), context.temp_allocator)
	copy(out, g)
	return out
}

fake_holder_count :: proc(f: ^Fake_Holder, kind: hw.Kind, terminal: u32 = 0) -> int {
	n := 0
	for g in fake_holder_got(f) do if g.kind == kind && (terminal == 0 || g.terminal == terminal) do n += 1
	return n
}

// Waits up to ms for cond (polled every 10 ms).
wait_until :: proc(ms: int, cond: proc() -> bool) -> bool {
	for _ in 0 ..< ms / 10 {
		if cond() do return true
		time.sleep(10 * time.Millisecond)
	}
	return cond()
}

@(private = "file")
fake_send :: proc(f: ^Fake_Holder, kind: hw.Kind, id: u32, msg: $T) {
	out := make([dynamic]u8, context.temp_allocator)
	hw.encode(&out, kind, id, msg)
	sock_write_all(f.cfd, out[:])
}

@(private = "file")
fake_holder_main :: proc(data: rawptr) {
	f := (^Fake_Holder)(data)
	context.allocator = runtime.heap_allocator()
	for !sync.atomic_load(&f.stop) {
		fd, ok := sock_accept(f.lfd, 50)
		if !ok do continue
		if f.mode == .Hangup {
			sock_close(f.lfd)
			sock_unlink(f.path)
			f.lfd = -1
			time.sleep(20 * time.Millisecond) // the app has sent HELLO: EOF, not a refusal
			sock_close(fd)
			return
		}
		f.cfd = fd
		fake_serve(f)
		sock_close(fd)
		f.cfd = -1
		free_all(context.temp_allocator)
	}
}

@(private = "file")
fake_serve :: proc(f: ^Fake_Holder) {
	rx: hw.Stream
	defer hw.stream_destroy(&rx)
	buf := make([]u8, 64 * 1024)
	defer delete(buf)
	hello := false
	for !sync.atomic_load(&f.stop) {
		if hello && f.no_read {
			time.sleep(10 * time.Millisecond)
			continue
		}
		if !sock_wait_readable(f.cfd, 50) do continue
		n := sock_read(f.cfd, buf)
		if n <= 0 do return
		hw.stream_feed(&rx, buf[:n])
		for {
			fr, err := hw.stream_next(&rx)
			if err != .None do break
			kind := hw.Kind(fr.kind)
			if !hello {
				if kind != .Hello do return
				hello = true
				switch f.mode {
				case .Refuse:
					fake_send(f, .Refused, 0, hw.Refused{code = f.refuse_code != "" ? f.refuse_code : "wire", error = "fake: refused"})
					// open until the app closes, as the holder lingers: the app checks its peer
					// before it acts on the REFUSED (a closed peer can't be read)
					for _ in 0 ..< 100 {
						if sync.atomic_load(&f.stop) do break
						if sock_wait_readable(f.cfd, 10) && sock_read(f.cfd, buf) <= 0 do break
					}
					return
				case .Silent, .Hangup:
				case .Welcome:
					w := hw.Welcome{wire = hw.WIRE, instance = f.instance, pid = i64(posix.getpid()), holder_rev = 1, previous = f.upgraded ? "upgrade" : f.previous, hmac_key = string(hex.encode(f.key[:], context.temp_allocator)), terminals = f.terms}
					out := make([dynamic]u8, context.temp_allocator)
					hw.encode(&out, .Welcome, 0, w)
					for wt, i in f.terms {
						tail := i < len(f.tails) ? f.tails[i] : nil
						hw.encode_output(&out, .Tail, u32(wt.id), wt.offset - u64(len(tail)), tail)
					}
					if len(f.output) > 0 && len(f.terms) > 0 && !f.upgraded {
						hw.encode_output(&out, .Output, u32(f.terms[0].id), f.terms[0].offset, f.output)
					}
					if f.upgraded && len(f.upgrade_output) > 0 && len(f.terms) > 0 {
						t0 := f.terms[0]
						hw.encode_output(&out, .Output, u32(t0.id), t0.offset, f.upgrade_output)
						hw.encode(&out, .Exited, u32(t0.id), hw.Exited{code = 7, offset = t0.offset + u64(len(f.upgrade_output))})
					}
					sock_write_all(f.cfd, out[:]) // one write: what follows the TAILs arrives with them
				}
				continue
			}
			g := Fake_Got{kind = kind, terminal = fr.terminal}
			#partial switch kind {
			case .Spawn:
				fake_send(f, .Spawned, fr.terminal, hw.Spawned{pid = i64(posix.getpid()), pgid = i64(posix.getpid())})
			case .Ping:
				if !f.upgraded do fake_send(f, .Pong, 0, hw.Empty{})
			case .Upgrade:
				f.upgraded = true
				sync.lock(&f.mu)
				append(&f.got, g)
				sync.unlock(&f.mu)
				return // the exec: this connection closes; the next one is the new image's
			case .Goodbye:
				m: hw.Goodbye
				hw.decode(fr, .Goodbye, &m, context.temp_allocator)
				g.mode = m.mode == "handover" ? "handover" : "shutdown"
				if m.mode == "handover" {
					acks := make([dynamic]hw.Ack_Terminal, context.temp_allocator)
					for wt in f.terms do append(&acks, hw.Ack_Terminal{id = wt.id, offset = wt.offset})
					fake_send(f, .Goodbye_Ack, 0, hw.Goodbye_Ack{terminals = acks[:]})
				}
			}
			sync.lock(&f.mu)
			append(&f.got, g)
			sync.unlock(&f.mu)
		}
	}
}
