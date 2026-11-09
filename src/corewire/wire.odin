// The framed wire between a window and its core, and between two cores
// (docs/plans/background-core.md §5.1): what core.sock carries after an NDJSON
// hello with framed:true, and what `deckhand-core connect` carries over stdio.
// This file is pure: no sockets, no app state, no JSON parsing (payloads are opaque here).
// The transports beside it carry these frames: transport_mem.odin in process, transport_sock.odin
// over a Unix socket; skew.odin has the hello's version tables.
//
// A frame is [channel u32 LE][kind u8][len u32 LE][payload ≤ 16 MiB] (herdr's
// layout). Channel 0 carries JSON messages as DATA; channels ≥ 1 are terminal
// streams. The header and the kind numbers are frozen forever (golden vectors in
// tests/framed-wire/v1/). New kinds may be added; a receiver ignores kinds it
// does not know.
//
// The holder wire (src/holderwire, §5.7) has the same size and limit but a
// different field order ([kind][terminal][len]), so the two do not share a codec:
// generalising holderwire's would change the holder's code (a HOLDER_REV bump,
// so every running holder re-execs) for no gain in either.
package corewire

import "core:encoding/endian"

HEADER_SIZE :: 9
MAX_PAYLOAD :: 16 * 1024 * 1024

JSON_CHANNEL :: u32(0)

// Kind numbers never change or get reused. 0 is never sent.
Kind :: enum u8 {
	Data     = 1, // channel 0: one JSON message; a terminal: output (core → window) or input
	Snapshot = 2, // meta JSON + GHOSTSNP bytes (§5.5)
	Resize   = 3, // {offset, cols, rows, xpixel, ypixel}, applied at that byte offset
	Credit   = 4, // more DATA bytes the window can take (§5.6)
	Close    = 5, // the channel ends
	Focus    = 6, // the terminal gained or lost focus
}

KIND_LAST :: Kind.Focus

Header :: struct {
	channel: u32,
	kind:    u8, // raw, so an unknown kind survives decoding
	len:     u32,
}

Frame :: struct {
	channel: u32,
	kind:    u8,
	payload: []u8, // borrowed from the input
}

Frame_Error :: enum {
	None,
	Need_More, // not a whole frame yet
	Too_Large, // len > MAX_PAYLOAD: the stream is unusable, close it
}

is_known :: proc(kind: u8) -> bool {
	return kind >= 1 && kind <= u8(KIND_LAST)
}

// ---- encoding ----

@(private)
header_bytes :: proc(channel: u32, kind: u8, n: int) -> (h: [HEADER_SIZE]u8) {
	endian.put_u32(h[0:4], .Little, channel)
	h[4] = kind
	endian.put_u32(h[5:9], .Little, u32(n))
	return
}

// Raw headers, for encode and the tests (an unknown kind, a header with no payload yet).
@(private)
put_header :: proc(out: ^[dynamic]u8, channel: u32, kind: u8, n: int) {
	assert(n >= 0 && n <= MAX_PAYLOAD)
	h := header_bytes(channel, kind, n)
	append(out, ..h[:])
}

// Appends one frame. False (and nothing appended) if the payload is over MAX_PAYLOAD.
encode :: proc(out: ^[dynamic]u8, channel: u32, kind: Kind, payload: []u8) -> bool {
	if len(payload) > MAX_PAYLOAD do return false
	put_header(out, channel, u8(kind), len(payload))
	append(out, ..payload)
	return true
}

// ---- decoding ----

parse_header :: proc(b: []u8) -> (h: Header, ok: bool) {
	if len(b) < HEADER_SIZE do return
	h.channel, _ = endian.get_u32(b[0:4], .Little)
	h.kind = b[4]
	h.len, _ = endian.get_u32(b[5:9], .Little)
	return h, true
}

// The first whole frame in b and how many bytes it took. Too_Large is known
// from the header alone, before the payload arrives.
next_frame :: proc(b: []u8) -> (f: Frame, used: int, err: Frame_Error) {
	h, ok := parse_header(b)
	if !ok do return {}, 0, .Need_More
	if h.len > MAX_PAYLOAD do return {}, 0, .Too_Large
	end := HEADER_SIZE + int(h.len)
	if len(b) < end do return {}, 0, .Need_More
	return Frame{h.channel, h.kind, b[HEADER_SIZE:end]}, end, .None
}

// A byte stream in, whole frames out. A frame returned by stream_next is valid
// until the next stream_feed or stream_next. After Too_Large the stream stays
// failed (its owner closes the connection).
Stream :: struct {
	buf:    [dynamic]u8,
	head:   int,
	failed: bool,
}

// Fixes the allocator the buffer lives in. Without it the buffer takes whatever
// context.allocator is current at the first feed, which may be a temp arena.
stream_init :: proc(s: ^Stream, allocator := context.allocator) {
	s^ = {buf = make([dynamic]u8, allocator)}
}

// Appends bytes. Drain with stream_next after every feed: the buffer holds
// whatever has not been taken out, so a feeder that never drains grows it
// without bound (next_frame refuses a frame over MAX_PAYLOAD at its header).
stream_feed :: proc(s: ^Stream, b: []u8) {
	if s.failed do return
	if s.head > 0 && s.head == len(s.buf) {
		clear(&s.buf)
		s.head = 0
	} else if s.head > 64 * 1024 && s.head * 2 > len(s.buf) {
		copy(s.buf[:], s.buf[s.head:])
		resize(&s.buf, len(s.buf) - s.head)
		s.head = 0
	}
	append(&s.buf, ..b)
}

stream_next :: proc(s: ^Stream) -> (f: Frame, err: Frame_Error) {
	if s.failed do return {}, .Too_Large
	used: int
	f, used, err = next_frame(s.buf[s.head:])
	switch err {
	case .None: s.head += used
	case .Too_Large: s.failed = true
	case .Need_More:
	}
	return
}

// Bytes fed but not yet returned as frames.
stream_pending :: proc(s: ^Stream) -> int {return len(s.buf) - s.head}

stream_destroy :: proc(s: ^Stream) {delete(s.buf); s^ = {}}
