package corewire

// The socket transport over a socketpair (§10.3 M4-B's tests). Run from the repo root (the golden
// vectors are read from tests/framed-wire/v1/). The forked-child check is in the core's tests
// (src/core/transport_sock_peer_test.odin), which may use src/trust.

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
pair :: proc(t: ^testing.T) -> (a, b: posix.FD) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK, "socketpair")
	when ODIN_OS == .Darwin {
		one: i32 = 1
		SO_NOSIGPIPE :: 0x1022
		for fd in fds do posix.setsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
	return fds[0], fds[1]
}

// Reads everything there is on a raw (blocking) fd for up to ms.
@(private = "file")
raw_read :: proc(fd: posix.FD, ms: int, want := -1) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	start := time.tick_now()
	for want < 0 || len(out) < want {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 5) <= 0 {
			if time.tick_since(start) > time.Duration(ms) * time.Millisecond do break
			continue
		}
		chunk: [65536]u8
		n := posix.read(fd, raw_data(chunk[:]), len(chunk))
		if n <= 0 do break
		append(&out, ..chunk[:n])
	}
	return out[:]
}

@(private = "file")
raw_write :: proc(fd: posix.FD, b: []u8) {
	rest := b
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n <= 0 do return
		rest = rest[n:]
	}
}

// Flushes until nothing is queued (the peer reads in another way, or has room).
@(private = "file")
flush_all :: proc(tr: ^Sock_Transport, ms := 2000) -> bool {
	start := time.tick_now()
	for {
		left, err := sock_flush(tr)
		if err != .None do return false
		if left == 0 do return true
		if time.tick_since(start) > time.Duration(ms) * time.Millisecond do return false
		sock_wait(tr, 5)
	}
}

// Waits for the next frame.
@(private = "file")
next :: proc(tr: ^Sock_Transport, ms := 2000) -> (Frame, Recv_Error) {
	start := time.tick_now()
	for {
		f, e := sock_recv(tr)
		if e != .Empty do return f, e
		if time.tick_since(start) > time.Duration(ms) * time.Millisecond do return {}, .Empty
		sock_wait(tr, 5)
	}
}

// The golden vectors, as bytes on the socket: what sock_send writes is the frozen encoding, and
// what sock_recv reads back from those bytes is the frame.
@(test)
sock_golden_bytes :: proc(t: ^testing.T) {
	a, b := pair(t)
	tr: Sock_Transport
	sock_open(&tr, a)
	defer sock_destroy(&tr)
	rx: Sock_Transport
	sock_open(&rx, b)
	defer sock_destroy(&rx)
	for g in golden_frames() {
		want, err := os.read_entire_file(fmt.tprintf("%s/%s.bin", GOLDEN_DIR, g.name), context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s missing", g.name) do continue
		f, _, _ := next_frame(want)
		testing.expect_value(t, sock_send(&tr, f.channel, Kind(f.kind), f.payload), Send_Error.None)
		testing.expect(t, flush_all(&tr))
		got, e := next(&rx)
		testing.expect_value(t, e, Recv_Error.None)
		testing.expect(t, got.channel == f.channel && got.kind == f.kind && string(got.payload) == string(f.payload), g.name)
	}
	free_all(context.temp_allocator)
}

// A reader that stops: frames past the cap are refused (Full); channel 0 and snapshots go on to
// the ceiling, then the transport closes (Overflow).
@(test)
sock_stalled_reader :: proc(t: ^testing.T) {
	a, b := pair(t)
	tr: Sock_Transport
	sock_open(&tr, a, cap = 1 << 16)
	defer {sock_destroy(&tr); posix.close(b)}
	chunk := make([]u8, 1 << 20, context.temp_allocator)
	testing.expect_value(t, sock_send(&tr, 3, .Data, chunk), Send_Error.Full)
	sent := 0
	e: Send_Error
	for _ in 0 ..< 100 {
		e = sock_send(&tr, 0, .Data, chunk)
		if e != .None do break
		sock_flush(&tr) // the kernel takes a little, then nothing
		sent += 1
	}
	testing.expect_value(t, e, Send_Error.Overflow)
	testing.expect_value(t, sock_reason(&tr), Close_Reason.Overflow)
	testing.expect_value(t, sock_send(&tr, 0, .Data, nil), Send_Error.Closed)
	free_all(context.temp_allocator)
}

// A newer snapshot replaces one still queued, and drops the DATA and RESIZE queued before it on
// its channel; other channels' frames and CLOSE stay.
@(test)
sock_snapshot_replaces :: proc(t: ^testing.T) {
	a, b := pair(t)
	tr, rx: Sock_Transport
	sock_open(&tr, a)
	sock_open(&rx, b)
	defer {sock_destroy(&tr); sock_destroy(&rx)}
	s := proc(x: string) -> []u8 {return transmute([]u8)x}
	sock_send(&tr, 5, .Data, s("old-data"))
	sock_send(&tr, 5, .Resize, s("old-size"))
	sock_send(&tr, 6, .Data, s("other"))
	sock_send(&tr, 5, .Snapshot, s("snap-1"))
	sock_send(&tr, 5, .Data, s("after-1"))
	sock_send(&tr, 5, .Snapshot, s("snap-2"))
	sock_send(&tr, 5, .Data, s("after-2"))
	sock_send(&tr, 5, .Close, nil)
	testing.expect(t, flush_all(&tr))
	want := [?]string{"5/2/snap-2", "6/1/other", "5/1/after-2", "5/5/"}
	for w in want {
		f, e := next(&rx)
		testing.expect_value(t, e, Recv_Error.None)
		testing.expect_value(t, fmt.tprintf("%d/%d/%s", f.channel, f.kind, string(f.payload)), w)
	}
	free_all(context.temp_allocator)
}

// A fuzz pass over the reader (well under 1 s): random and mutated byte streams, written in random
// pieces, never crash it, and every frame it returns is one next_frame finds in the same bytes.
@(test)
sock_reader_fuzz :: proc(t: ^testing.T) {
	seeds := make([dynamic][]u8)
	defer {for x in seeds do delete(x); delete(seeds)}
	for g in golden_frames() do append(&seeds, clone(g.bytes))
	free_all(context.temp_allocator)
	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)
	start := time.tick_now()
	iters := 0
	for iters < 3000 && time.tick_since(start) < 800 * time.Millisecond {
		iters += 1
		buf := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< 1 + rand.int_max(4, gen) do append(&buf, ..seeds[rand.int_max(len(seeds), gen)])
		for _ in 0 ..< rand.int_max(4, gen) {
			if len(buf) == 0 do break
			at := rand.int_max(len(buf), gen)
			switch rand.int_max(3, gen) {
			case 0: buf[at] ~= u8(1 << uint(rand.int_max(8, gen)))
			case 1: inject_at(&buf, at, u8(rand.int_max(256, gen)))
			case 2: resize(&buf, at)
			}
		}
		// the frames one walk finds
		want := make([dynamic]string, context.temp_allocator)
		rest := buf[:]
		for {
			f, used, e := next_frame(rest)
			if e != .None do break
			append(&want, fmt.tprintf("%d/%d/%s", f.channel, f.kind, string(f.payload)))
			rest = rest[used:]
		}
		a, b := pair(t)
		rx: Sock_Transport
		sock_open(&rx, b)
		got := make([dynamic]string, context.temp_allocator)
		w := buf[:]
		for len(w) > 0 {
			k := min(len(w), 1 + rand.int_max(16, gen))
			raw_write(a, w[:k])
			w = w[k:]
			for {
				f, e := sock_recv(&rx)
				if e != .None do break
				append(&got, fmt.tprintf("%d/%d/%s", f.channel, f.kind, string(f.payload)))
			}
		}
		posix.close(a)
		for {
			f, e := next(&rx, 200)
			if e != .None do break
			append(&got, fmt.tprintf("%d/%d/%s", f.channel, f.kind, string(f.payload)))
		}
		testing.expectf(t, len(got) == len(want), "iteration %d: %d frames, want %d", iters, len(got), len(want))
		for g, i in got do if i < len(want) do testing.expect_value(t, g, want[i])
		sock_destroy(&rx)
		free_all(context.temp_allocator)
	}
	testing.expect(t, iters > 100, "the fuzz pass ran")
}

// The backlog's caps: frames and bytes.
@(test)
backlog_caps :: proc(t: ^testing.T) {
	b: Backlog
	backlog_init(&b, max_frames = 3, max_bytes = 3 * HEADER_SIZE + 10)
	defer backlog_destroy(&b)
	p :: proc(n: int) -> []u8 {return make([]u8, n)}
	testing.expect(t, backlog_push(&b, {channel = 1, payload = p(4)}))
	testing.expect(t, backlog_push(&b, {channel = 2, payload = p(6)}))
	testing.expect(t, !backlog_push(&b, {channel = 3, payload = p(1)}), "over the bytes")
	testing.expect(t, backlog_push(&b, {channel = 3, payload = p(0)}))
	testing.expect(t, !backlog_push(&b, {channel = 4, payload = p(0)}), "over the frames")
	f, ok := backlog_pop(&b)
	testing.expect(t, ok && f.channel == 1)
	delete(f.payload)
	testing.expect_value(t, b.bytes, 2 * HEADER_SIZE + 6)
	testing.expect(t, backlog_push(&b, {channel = 5, payload = p(4)}))
}
