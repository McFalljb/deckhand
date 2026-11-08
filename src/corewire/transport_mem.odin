package corewire

// The in-memory transport (§10.2 M3-E, used by M3-F's in-process window): a
// pair of byte queues, one per direction, carrying the same frames and limits
// as core.sock in framed mode. A frame over MAX_PAYLOAD is refused; without
// `force`, a send is refused once the peer has `cap` bytes unread (the socket's
// socket_out_cap, after which a connection's subscription drops; channel 0
// replies and snapshots pass force, §5.6). Either end may run on any thread.

import "core:sync"

OUT_CAP :: 4 << 20 // socket.odin's socket_out_cap

Mem_Transport :: struct {
	mu:     sync.Mutex,
	q:      [2]Stream, // q[i]: bytes end i sent, not yet read by the other end
	closed: bool,
	cap:    int,
}

Mem_End :: struct {
	t:    ^Mem_Transport,
	side: int, // 0 or 1
}

Send_Error :: enum {
	None,
	Closed,
	Too_Large, // payload over MAX_PAYLOAD
	Full, // the peer has cap bytes unread (and force was not set)
}

Recv_Error :: enum {
	None,
	Empty, // nothing to read yet
	Closed, // closed and every frame sent before it was read
}

mem_open :: proc(t: ^Mem_Transport, cap := OUT_CAP) -> (a, b: Mem_End) {
	t.cap = cap
	return {t, 0}, {t, 1}
}

mem_send :: proc(e: Mem_End, channel: u32, kind: Kind, payload: []u8, force := false) -> Send_Error {
	t := e.t
	sync.guard(&t.mu)
	if t.closed do return .Closed
	if len(payload) > MAX_PAYLOAD do return .Too_Large
	q := &t.q[e.side]
	if !force && stream_pending(q) + HEADER_SIZE + len(payload) > t.cap do return .Full
	h := header_bytes(channel, u8(kind), len(payload))
	stream_feed(q, h[:])
	stream_feed(q, payload)
	return .None
}

// The next frame the peer sent. Its payload is a copy made with `allocator`, so
// it stays valid whatever either end does next.
mem_recv :: proc(e: Mem_End, allocator := context.temp_allocator) -> (f: Frame, err: Recv_Error) {
	t := e.t
	sync.guard(&t.mu)
	q := &t.q[1 - e.side]
	raw, ferr := stream_next(q)
	if ferr != .None do return {}, t.closed ? .Closed : .Empty // senders write whole frames: Need_More means none
	f = raw
	f.payload = make([]u8, len(raw.payload), allocator)
	copy(f.payload, raw.payload)
	return f, .None
}

// Bytes this end sent that the peer has not read.
mem_unread :: proc(e: Mem_End) -> int {
	sync.guard(&e.t.mu)
	return stream_pending(&e.t.q[e.side])
}

// Either end may close. Later sends fail; each end still reads what was sent
// before, then gets Closed.
mem_close :: proc(e: Mem_End) {
	sync.guard(&e.t.mu)
	e.t.closed = true
}

mem_destroy :: proc(t: ^Mem_Transport) {
	for &q in t.q do stream_destroy(&q)
}
