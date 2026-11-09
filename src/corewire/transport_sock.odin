package corewire

// The socket transport (docs/plans/background-core.md §10.3 M4-B): the framed wire over a
// non-blocking Unix socket, with the in-memory transport's header, 16 MiB limit, kinds and cap.
// It is what core.sock carries after a hello with framed:true, and what M4-C's window link uses
// in place of Mem_Transport. Nothing in the app uses it yet.
//
// Sending queues; sock_flush writes what the socket takes now and never blocks:
// - Three queues, written in this order whenever no frame is part-written: channel 0 (JSON, so it
//   never waits behind terminal data), then snapshots, then everything else.
// - A SNAPSHOT is exempt from the cap (§5.6) and keeps one slot per channel: a newer one replaces
//   one still queued (not one already being written). It also drops the DATA and RESIZE frames
//   queued for its channel before it: the snapshot carries their effect, and it is written ahead
//   of them, so they would otherwise arrive after it and be applied twice.
// - Other frames are refused (Full) once `cap` bytes are queued, as mem_send refuses them.
// - Channel 0 and snapshots stop at the ceiling, cap + 2 largest frames: past it the transport
//   closes (Overflow), as the in-memory one does: a reader that stops is capped, then cut off.
//
// Reading: sock_recv returns whole frames, refusing a header over MAX_PAYLOAD (Too_Large, then
// closed). At most one frame plus a read's worth is buffered: a peer that sends faster than the
// owner takes frames waits in the kernel, not in our memory. After every read() that returned
// bytes, and before those bytes are fed to the decoder, the owner's peer_check runs (the core
// passes trust.peer_still over the token read at accept, §5.3): false closes the transport
// (Peer_Changed) and the bytes are dropped.
//
// Any thread may send; one mutex guards everything (the syscalls are non-blocking, so it is never
// held for long). The fd is the transport's from sock_open: sock_destroy closes it.

import "base:runtime"
import "core:c"
import "core:sync"
import "core:sys/posix"

@(private)
SOCK_READ_CHUNK :: 64 * 1024

// Whether the socket's peer is still the process that was checked at accept (trust.peer_still
// over trust.peer_read(fd) in the core). Called with the transport's lock held: it must not call
// back into the transport.
Peer_Check :: #type proc(fd: posix.FD, data: rawptr) -> bool

Close_Reason :: enum {
	None,
	Local, // sock_close
	Peer_Closed, // EOF (every frame before it was returned)
	Too_Large, // a header over MAX_PAYLOAD
	Truncated, // EOF in the middle of a frame
	Peer_Changed, // peer_check refused the process behind the bytes
	Overflow, // exempt sends past the ceiling
	Io_Error, // read or write failed
}

@(private)
Sock_Out :: struct {
	channel: u32,
	kind:    u8,
	bytes:   []u8, // header + payload, in t.allocator
}

Sock_Transport :: struct {
	mu:            sync.Mutex,
	fd:            posix.FD,
	allocator:     runtime.Allocator,
	cap:           int,
	peer_check:    Peer_Check,
	peer_data:     rawptr,
	// out
	ctl:           [dynamic]Sock_Out, // channel 0
	snaps:         [dynamic]Sock_Out, // at most one per channel
	data:          [dynamic]Sock_Out,
	cur:           Sock_Out, // part-written (cur_off of it), or bytes == nil
	cur_off:       int,
	queued:        int, // bytes not written yet, cur's remainder included
	// in
	inq:           Stream,
	eof:           bool,
	// state
	closed:        bool, // no more sends; reads still return what was decoded before an EOF
	reason:        Close_Reason,
}

// The most one direction may hold queued (mem_ceiling's rule).
SOCK_BUFFER :: 2 * 1024 * 1024 // the kernel buffers asked for each way (sock_open)

sock_ceiling :: proc(t: ^Sock_Transport) -> int {return t.cap + 2 * (HEADER_SIZE + MAX_PAYLOAD)}

// Takes over fd (a connected stream socket) and makes it non-blocking. initial: bytes already
// read from it by whoever handed it over (the hello's reader read past its line); they are
// checked with peer_check now, like any read. peer_check nil: no check (tests, a socketpair of
// our own).
sock_open :: proc(t: ^Sock_Transport, fd: posix.FD, cap := OUT_CAP, peer_check: Peer_Check = nil, peer_data: rawptr = nil, initial: []u8 = nil, allocator := context.allocator) {
	t^ = {}
	t.fd = fd
	t.allocator = allocator
	t.cap = cap
	t.peer_check = peer_check
	t.peer_data = peer_data
	t.ctl = make([dynamic]Sock_Out, allocator)
	t.snaps = make([dynamic]Sock_Out, allocator)
	t.data = make([dynamic]Sock_Out, allocator)
	stream_init(&t.inq, allocator)
	flags := posix.fcntl(fd, .GETFL)
	if flags >= 0 do posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK)
	// macOS gives a Unix stream socket 8 KiB each way (net.local.stream.*space): a terminal's
	// stream would move 8 KiB per wakeup of the reader. Best effort: the kernel caps it.
	for opt in ([]posix.Sock_Option{.SNDBUF, .RCVBUF}) {
		size := c.int(SOCK_BUFFER)
		posix.setsockopt(fd, posix.SOL_SOCKET, opt, &size, size_of(size))
	}
	if len(initial) > 0 {
		if t.peer_check != nil && !t.peer_check(t.fd, t.peer_data) {
			sock_fail(t, .Peer_Changed)
			return
		}
		stream_feed(&t.inq, initial)
	}
}

// Lock held. Closes for `why` (the first reason sticks) and frees what was queued to send.
@(private)
sock_fail :: proc(t: ^Sock_Transport, why: Close_Reason) {
	if !t.closed {
		t.closed = true
		t.reason = why
		posix.shutdown(t.fd, .RDWR) // the peer sees the end; the fd is closed by sock_destroy
	}
	sock_free_out(t)
}

@(private)
sock_free_out :: proc(t: ^Sock_Transport) {
	for q in ([]^[dynamic]Sock_Out{&t.ctl, &t.snaps, &t.data}) {
		for o in q do delete(o.bytes, t.allocator)
		clear(q)
	}
	if t.cur.bytes != nil do delete(t.cur.bytes, t.allocator)
	t.cur, t.cur_off, t.queued = {}, 0, 0
}

sock_send :: proc(t: ^Sock_Transport, channel: u32, kind: Kind, payload: []u8) -> Send_Error {
	sync.guard(&t.mu)
	if t.closed do return .Closed
	if len(payload) > MAX_PAYLOAD do return .Too_Large
	n := HEADER_SIZE + len(payload)
	exempt := channel == JSON_CHANNEL || kind == .Snapshot
	freed := 0 // what a snapshot replaces
	if kind == .Snapshot {
		for o in t.snaps do if o.channel == channel do freed += len(o.bytes)
		for o in t.data do if o.channel == channel && (o.kind == u8(Kind.Data) || o.kind == u8(Kind.Resize)) do freed += len(o.bytes)
	}
	after := t.queued - freed + n
	if !exempt && after > t.cap do return .Full
	if after > sock_ceiling(t) {
		sock_fail(t, .Overflow)
		return .Overflow
	}
	b := make([]u8, n, t.allocator)
	h := header_bytes(channel, u8(kind), len(payload))
	copy(b, h[:])
	copy(b[HEADER_SIZE:], payload)
	o := Sock_Out{channel, u8(kind), b}
	switch {
	case channel == JSON_CHANNEL:
		append(&t.ctl, o)
	case kind == .Snapshot:
		keep := 0
		for x in t.data {
			if x.channel == channel && (x.kind == u8(Kind.Data) || x.kind == u8(Kind.Resize)) {
				t.queued -= len(x.bytes)
				delete(x.bytes, t.allocator)
				continue
			}
			t.data[keep] = x
			keep += 1
		}
		resize(&t.data, keep)
		replaced := false
		for &x in t.snaps do if x.channel == channel {
			t.queued -= len(x.bytes)
			delete(x.bytes, t.allocator)
			x = o
			replaced = true
		}
		if !replaced do append(&t.snaps, o)
	case:
		append(&t.data, o)
	}
	t.queued += n
	return .None
}

// Writes what the socket takes now. Returns the bytes still queued; err is the close reason if
// the transport is (or just got) closed. Call it when the fd is writable (sock_wants_write).
sock_flush :: proc(t: ^Sock_Transport) -> (pending: int, err: Close_Reason) {
	sync.guard(&t.mu)
	if t.closed do return 0, t.reason
	flags: posix.Msg_Flags
	when ODIN_OS == .Linux do flags = {.NOSIGNAL} // macOS: SO_NOSIGPIPE, set where the fd is made
	for {
		if t.cur.bytes == nil {
			q: ^[dynamic]Sock_Out
			switch {
			case len(t.ctl) > 0:   q = &t.ctl
			case len(t.snaps) > 0: q = &t.snaps
			case len(t.data) > 0:  q = &t.data
			}
			if q == nil do break
			t.cur = q[0]
			ordered_remove(q, 0)
			t.cur_off = 0
		}
		rest := t.cur.bytes[t.cur_off:]
		n := posix.send(t.fd, raw_data(rest), len(rest), flags)
		if n < 0 {
			e := posix.errno()
			if e == .EINTR do continue
			if e == .EAGAIN || e == .EWOULDBLOCK do break
			sock_fail(t, .Io_Error)
			return 0, t.reason
		}
		if n == 0 do break
		t.cur_off += int(n)
		t.queued -= int(n)
		if t.cur_off == len(t.cur.bytes) {
			delete(t.cur.bytes, t.allocator)
			t.cur, t.cur_off = {}, 0
		}
	}
	return t.queued, .None
}

// Whether bytes are queued (poll the fd for writing).
sock_wants_write :: proc(t: ^Sock_Transport) -> bool {
	sync.guard(&t.mu)
	return !t.closed && t.queued > 0
}

// Lock held. Reads what is there, while the decoder has room for it: at most one frame plus a
// chunk is buffered.
@(private)
sock_fill :: proc(t: ^Sock_Transport) {
	chunk: [SOCK_READ_CHUNK]u8
	for !t.closed && !t.eof && stream_pending(&t.inq) < HEADER_SIZE + MAX_PAYLOAD {
		n := posix.read(t.fd, raw_data(chunk[:]), len(chunk))
		if n < 0 {
			e := posix.errno()
			if e == .EINTR do continue
			if e == .EAGAIN || e == .EWOULDBLOCK do return
			sock_fail(t, .Io_Error)
			return
		}
		if n == 0 {
			t.eof = true
			return
		}
		// the bytes are acted on only if the process behind them is still the one checked (§5.3)
		if t.peer_check != nil && !t.peer_check(t.fd, t.peer_data) {
			sock_fail(t, .Peer_Changed)
			return
		}
		stream_feed(&t.inq, chunk[:n])
		if n < len(chunk) do return
	}
}

// The next frame from the peer, its payload copied with `allocator`. Empty: none yet (poll the fd
// for reading). Closed: the transport is closed (sock_reason says why); after an EOF every whole
// frame sent before it is returned first, but nothing after a refusal (Too_Large, Peer_Changed).
sock_recv :: proc(t: ^Sock_Transport, allocator := context.temp_allocator) -> (f: Frame, err: Recv_Error) {
	sync.guard(&t.mu)
	if t.closed && t.reason != .Peer_Closed && t.reason != .Local do return {}, .Closed
	for pass in 0 ..< 2 {
		raw, ferr := stream_next(&t.inq)
		switch ferr {
		case .None:
			f = raw
			f.payload = make([]u8, len(raw.payload), allocator)
			copy(f.payload, raw.payload)
			return f, .None
		case .Too_Large:
			sock_fail(t, .Too_Large)
			return {}, .Closed
		case .Need_More:
		}
		if pass == 0 do sock_fill(t)
		if t.closed && t.reason != .Peer_Closed && t.reason != .Local do return {}, .Closed
	}
	if t.eof {
		if !t.closed do sock_fail(t, stream_pending(&t.inq) > 0 ? .Truncated : .Peer_Closed)
		return {}, .Closed
	}
	if t.closed do return {}, .Closed
	return {}, .Empty
}

// Why the transport closed (.None while open).
sock_reason :: proc(t: ^Sock_Transport) -> Close_Reason {
	sync.guard(&t.mu)
	return t.reason
}

// Waits up to ms for the fd to be readable, or writable while bytes are queued (simple owners and
// the tests; the app polls the fd itself).
sock_wait :: proc(t: ^Sock_Transport, ms: int) -> bool {
	sync.lock(&t.mu)
	ev: posix.Poll_Event = {.IN}
	if t.queued > 0 do ev += {.OUT}
	if stream_pending(&t.inq) >= HEADER_SIZE {
		if _, _, e := next_frame(t.inq.buf[t.inq.head:]); e != .Need_More {
			sync.unlock(&t.mu)
			return true
		}
	}
	fd := t.fd
	sync.unlock(&t.mu)
	pfd := posix.pollfd{fd = fd, events = ev}
	return posix.poll(&pfd, 1, i32(ms)) > 0
}

// Ends the link: later sends fail, and what was queued is dropped.
sock_close :: proc(t: ^Sock_Transport) {
	sync.guard(&t.mu)
	sock_fail(t, .Local)
}

// Frees everything and closes the fd. No other thread may use t after this.
sock_destroy :: proc(t: ^Sock_Transport) {
	sync.lock(&t.mu)
	sock_free_out(t)
	if !t.closed {
		t.closed = true
		t.reason = .Local
	}
	posix.close(t.fd)
	t.fd = -1
	stream_destroy(&t.inq)
	delete(t.ctl)
	delete(t.snaps)
	delete(t.data)
	sync.unlock(&t.mu)
}

// ---- a capped backlog (frames an owner took off a transport but cannot act on yet) ----
//
// M3-H's window link moves the window's frames from the transport into a backlog while it reads
// the CREDITs among them (window_link.odin, link_take_credits). That list must not grow past what
// the transport itself would hold, or a window that keeps sending defeats the transport's ceiling:
// backlog_push refuses past either cap, and the owner then closes the link.

BACKLOG_MAX_FRAMES :: 4096
BACKLOG_MAX_BYTES :: OUT_CAP + 2 * (HEADER_SIZE + MAX_PAYLOAD) // the transport's ceiling

Backlog :: struct {
	frames:     [dynamic]Frame, // payloads in `allocator`
	bytes:      int, // headers counted, as the transport counts them
	max_frames: int,
	max_bytes:  int,
	allocator:  runtime.Allocator,
}

backlog_init :: proc(b: ^Backlog, max_frames := BACKLOG_MAX_FRAMES, max_bytes := BACKLOG_MAX_BYTES, allocator := context.allocator) {
	b^ = {frames = make([dynamic]Frame, allocator), max_frames = max_frames, max_bytes = max_bytes, allocator = allocator}
}

// Keeps f (its payload must be in b.allocator: the backlog owns it from here). False: over a cap,
// nothing kept and f's payload freed: close the link.
backlog_push :: proc(b: ^Backlog, f: Frame) -> bool {
	n := HEADER_SIZE + len(f.payload)
	if len(b.frames) >= b.max_frames || b.bytes + n > b.max_bytes {
		delete(f.payload, b.allocator)
		return false
	}
	append(&b.frames, f)
	b.bytes += n
	return true
}

// The oldest frame; its payload is the caller's (free it with b.allocator).
backlog_pop :: proc(b: ^Backlog) -> (f: Frame, ok: bool) {
	if len(b.frames) == 0 do return {}, false
	f = b.frames[0]
	ordered_remove(&b.frames, 0)
	b.bytes -= HEADER_SIZE + len(f.payload)
	return f, true
}

backlog_destroy :: proc(b: ^Backlog) {
	for f in b.frames do delete(f.payload, b.allocator)
	delete(b.frames)
	b^ = {}
}
