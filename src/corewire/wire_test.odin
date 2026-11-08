package corewire

// Run from the repo root (./build.sh test does): the golden vectors are in
// tests/framed-wire/v1/. FRAMED_WIRE_REGOLD=1 writes vectors that do not exist
// yet; never use it to make a changed one pass (the header and the kind numbers
// are frozen). Payload formats per kind are M3-H's (§5.5): the vectors freeze
// the header and the numbers, so their payloads are empty except DATA's.

import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:testing"

GOLDEN_DIR :: "tests/framed-wire/v1"

Golden :: struct {
	name:  string,
	bytes: []u8,
}

golden_frames :: proc() -> []Golden {
	out := make([dynamic]Golden, context.temp_allocator)
	add :: proc(out: ^[dynamic]Golden, name: string, channel: u32, kind: Kind, payload: string) {
		b := make([dynamic]u8, context.temp_allocator)
		assert(encode(&b, channel, kind, transmute([]u8)payload))
		append(out, Golden{name, b[:]})
	}
	add(&out, "data-json", JSON_CHANNEL, .Data, `{"id":1,"method":"state.subscribe"}`)
	add(&out, "data-terminal", 7, .Data, "ls\r")
	add(&out, "snapshot", 0x01020304, .Snapshot, "")
	add(&out, "resize", 7, .Resize, "")
	add(&out, "credit", 7, .Credit, "")
	add(&out, "close", 7, .Close, "")
	add(&out, "focus", 0xffffffff, .Focus, "")
	return out[:]
}

@(test)
golden_vectors :: proc(t: ^testing.T) {
	regold := os.get_env("FRAMED_WIRE_REGOLD", context.temp_allocator) == "1"
	for g in golden_frames() {
		path := fmt.tprintf("%s/%s.bin", GOLDEN_DIR, g.name)
		if regold {
			os.make_directory_all(GOLDEN_DIR)
			if _, err := os.stat(path, context.temp_allocator); err != nil {
				testing.expect(t, os.write_entire_file(path, g.bytes) == nil)
			}
		}
		want, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s missing (a frozen vector; FRAMED_WIRE_REGOLD=1 writes new ones)", path) do continue
		testing.expectf(t, string(want) == string(g.bytes), "%s: a frozen encoding changed:\n  want %q\n  got  %q", path, string(want), string(g.bytes))
		f, used, ferr := next_frame(want)
		testing.expect_value(t, ferr, Frame_Error.None)
		testing.expect_value(t, used, len(want))
		testing.expect(t, is_known(f.kind))
	}
	// every kind has a vector, and every vector is of a kind
	covered: bit_set[Kind]
	for g in golden_frames() {
		f, _, _ := next_frame(g.bytes)
		testing.expect(t, is_known(f.kind))
		covered += {Kind(f.kind)}
	}
	testing.expect_value(t, covered, ~bit_set[Kind]{})
	free_all(context.temp_allocator)
}

@(test)
header_layout :: proc(t: ^testing.T) {
	b := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, encode(&b, 0x01020304, .Data, transmute([]u8)string("hi")))
	testing.expect_value(t, string(b[:]), "\x04\x03\x02\x01\x01\x02\x00\x00\x00hi")
	f, used, e := next_frame(b[:])
	testing.expect_value(t, e, Frame_Error.None)
	testing.expect_value(t, used, 11)
	testing.expect_value(t, f.channel, 0x01020304)
	testing.expect_value(t, f.kind, u8(Kind.Data))
	testing.expect_value(t, string(f.payload), "hi")
	// kind numbers, frozen
	testing.expect_value(t, u8(Kind.Data), 1)
	testing.expect_value(t, u8(Kind.Snapshot), 2)
	testing.expect_value(t, u8(Kind.Resize), 3)
	testing.expect_value(t, u8(Kind.Credit), 4)
	testing.expect_value(t, u8(Kind.Close), 5)
	testing.expect_value(t, u8(Kind.Focus), 6)
	testing.expect(t, !is_known(0) && !is_known(7) && !is_known(255))
	free_all(context.temp_allocator)
}

@(test)
frame_limits :: proc(t: ^testing.T) {
	b := make([]u8, HEADER_SIZE, context.temp_allocator)
	b[4] = u8(Kind.Snapshot)
	b[5], b[6], b[7], b[8] = 0, 0, 0, 1 // exactly 16 MiB: allowed, needs more bytes
	_, _, e := next_frame(b)
	testing.expect_value(t, e, Frame_Error.Need_More)
	b[5] = 1 // 16 MiB + 1: fatal at the header
	_, _, e = next_frame(b)
	testing.expect_value(t, e, Frame_Error.Too_Large)
	b[5], b[6], b[7], b[8] = 0xff, 0xff, 0xff, 0xff
	_, _, e = next_frame(b)
	testing.expect_value(t, e, Frame_Error.Too_Large)
	for n in 0 ..< HEADER_SIZE {
		_, _, e = next_frame(b[:n])
		testing.expect_value(t, e, Frame_Error.Need_More)
	}
	big := make([]u8, MAX_PAYLOAD + 1, context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, !encode(&out, 1, .Data, big))
	testing.expect_value(t, len(out), 0)
	testing.expect(t, encode(&out, 1, .Data, big[:MAX_PAYLOAD]))
	f, used, fe := next_frame(out[:])
	testing.expect_value(t, fe, Frame_Error.None)
	testing.expect_value(t, used, HEADER_SIZE + MAX_PAYLOAD)
	testing.expect_value(t, len(f.payload), MAX_PAYLOAD)
	// a failed stream stays failed
	s: Stream
	defer stream_destroy(&s)
	stream_feed(&s, b)
	_, e = stream_next(&s)
	testing.expect_value(t, e, Frame_Error.Too_Large)
	stream_feed(&s, out[:])
	_, e = stream_next(&s)
	testing.expect_value(t, e, Frame_Error.Too_Large)
	free_all(context.temp_allocator)
}

// Compaction keeps a partial frame whole: a frame over 64 KiB is read (so head passes the
// threshold), then part of the next arrives, then the rest.
@(test)
stream_compaction :: proc(t: ^testing.T) {
	big := make([]u8, 100_000, context.temp_allocator)
	for i in 0 ..< len(big) do big[i] = u8(i * 13)
	small := make([]u8, 30_000, context.temp_allocator)
	for i in 0 ..< len(small) do small[i] = u8(i * 7 + 1)
	b := make([dynamic]u8, context.temp_allocator)
	encode(&b, 1, .Snapshot, big)
	first := len(b)
	encode(&b, 2, .Data, small)
	s: Stream
	stream_init(&s)
	defer stream_destroy(&s)
	cut := first + 10_000
	stream_feed(&s, b[:cut])
	f, e := stream_next(&s)
	testing.expect(t, e == .None && f.channel == 1 && string(f.payload) == string(big))
	_, e = stream_next(&s)
	testing.expect_value(t, e, Frame_Error.Need_More)
	stream_feed(&s, b[cut:]) // compacts: head > 64 KiB and more than half the buffer
	testing.expect_value(t, s.head, 0)
	f, e = stream_next(&s)
	testing.expect(t, e == .None && f.channel == 2 && string(f.payload) == string(small))
	testing.expect_value(t, stream_pending(&s), 0)
	free_all(context.temp_allocator)
}

// Random chunking: the stream decoder yields the same frames however the bytes arrive.
@(test)
stream_chunking :: proc(t: ^testing.T) {
	all := make([dynamic]u8, context.temp_allocator)
	for g in golden_frames() do append(&all, ..g.bytes)
	big := make([]u8, 200_000, context.temp_allocator)
	for i in 0 ..< len(big) do big[i] = u8(i * 7)
	encode(&all, 9, .Snapshot, big)
	put_header(&all, 9, 200, 3) // an unknown kind: decoded, then ignored by its receiver
	append(&all, "abc")
	want := len(golden_frames()) + 2
	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)
	for _ in 0 ..< 50 {
		s: Stream
		got, unknown := 0, 0
		i := 0
		for i < len(all) {
			n := min(1 + rand.int_max(rand.int_max(2, gen) == 0 ? 7 : 70_000, gen), len(all) - i)
			stream_feed(&s, all[i:i + n])
			i += n
			for {
				f, e := stream_next(&s)
				if e != .None {
					testing.expect_value(t, e, Frame_Error.Need_More)
					break
				}
				got += 1
				if !is_known(f.kind) do unknown += 1
				if f.kind == u8(Kind.Snapshot) && f.channel == 9 do testing.expect(t, string(f.payload) == string(big))
			}
		}
		testing.expect_value(t, got, want)
		testing.expect_value(t, unknown, 1)
		testing.expect_value(t, stream_pending(&s), 0)
		stream_destroy(&s)
	}
	free_all(context.temp_allocator)
}

// A bounded fuzz pass (~40k inputs, well under 1 s): random and mutated bytes
// never crash the decoder, a frame never reads past its input, and a stream fed
// the same bytes in random chunks gives the same frames as one next_frame walk.
@(test)
decoder_fuzz :: proc(t: ^testing.T) {
	seeds := make([dynamic][]u8)
	defer {for s in seeds do delete(s); delete(seeds)}
	for g in golden_frames() do append(&seeds, clone(g.bytes))
	free_all(context.temp_allocator)
	buf := make([dynamic]u8)
	defer delete(buf)
	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)
	for iter in 0 ..< 40_000 {
		clear(&buf)
		switch rand.int_max(3, gen) {
		case 0: // random bytes behind a plausible header
			n := rand.int_max(200, gen)
			put_header(&buf, rand.uint32(gen), u8(rand.int_max(256, gen)), n)
			for _ in 0 ..< n do append(&buf, u8(rand.int_max(256, gen)))
		case 1: // golden frames back to back, with bytes flipped, inserted or cut
			for _ in 0 ..< 1 + rand.int_max(3, gen) do append(&buf, ..seeds[rand.int_max(len(seeds), gen)])
			for _ in 0 ..< 1 + rand.int_max(4, gen) {
				at := rand.int_max(len(buf), gen)
				switch rand.int_max(3, gen) {
				case 0: buf[at] ~= u8(1 << uint(rand.int_max(8, gen)))
				case 1: inject_at(&buf, at, u8(rand.int_max(256, gen)))
				case 2: resize(&buf, at)
				}
				if len(buf) == 0 do break
			}
		case 2: // pure noise
			for _ in 0 ..< rand.int_max(64, gen) do append(&buf, u8(rand.int_max(256, gen)))
		}
		// one walk with next_frame
		walk := make([dynamic]Frame, context.temp_allocator)
		walk_err := Frame_Error.Need_More
		rest := buf[:]
		for {
			f, used, e := next_frame(rest)
			if e != .None {walk_err = e; break}
			testing.expect(t, used >= HEADER_SIZE && used <= len(rest))
			testing.expect_value(t, len(f.payload), used - HEADER_SIZE)
			append(&walk, f)
			rest = rest[used:]
		}
		// the same bytes through a stream, in random chunks
		s: Stream
		n_frames := 0
		stream_err := Frame_Error.None
		i := 0
		for i < len(buf) && stream_err != .Too_Large {
			n := min(1 + rand.int_max(32, gen), len(buf) - i)
			stream_feed(&s, buf[i:i + n])
			i += n
			for {
				f, e := stream_next(&s)
				if e != .None {stream_err = e; break}
				if n_frames < len(walk) {
					w := walk[n_frames]
					testing.expect(t, f.channel == w.channel && f.kind == w.kind && string(f.payload) == string(w.payload))
				}
				n_frames += 1
			}
		}
		testing.expect_value(t, n_frames, len(walk))
		if walk_err == .Too_Large do testing.expect_value(t, stream_err, Frame_Error.Too_Large)
		stream_destroy(&s)
		if iter % 256 == 0 do free_all(context.temp_allocator)
	}
	free_all(context.temp_allocator)
}

@(private)
clone :: proc(b: []u8) -> []u8 {
	out := make([]u8, len(b))
	copy(out, b)
	return out
}
