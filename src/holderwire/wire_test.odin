package holderwire

// Run from the repo root (./build.sh test does): the golden vectors are in
// tests/holder-wire/v1/, the released schema in schema/released-holder.json.
// HOLDER_WIRE_REGOLD=1 rewrites the golden vectors; do that only for a NEW
// frozen vector, never to make a changed one pass.

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:testing"

GOLDEN_DIR :: "tests/holder-wire/v1"
RELEASED :: "schema/released-holder.json"

Golden :: struct {
	name:  string,
	bytes: []u8,
}

// The frozen bootstrap subset, as the canonical frames the vectors hold.
golden_frames :: proc() -> []Golden {
	out := make([dynamic]Golden, context.temp_allocator)
	add :: proc(out: ^[dynamic]Golden, name: string, kind: Kind, terminal: u32, msg: $T) {
		b := make([dynamic]u8, context.temp_allocator)
		assert(encode(&b, kind, terminal, msg))
		append(out, Golden{name, b[:]})
	}
	add(&out, "hello", .Hello, 0, Hello{wire = 1})
	add(&out, "hello-successor", .Hello, 0, Hello{wire = 1, successor_secret = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"})
	exit := Exit_Status{code = 3, signal = 0}
	terms := []Welcome_Terminal {
		{id = 1, pid = 4242, pgid = 4242, cols = 80, rows = 24, xpixel = 640, ypixel = 384, offset = 123456},
		{id = 2, pid = 4300, pgid = 4300, cols = 120, rows = 40, xpixel = 960, ypixel = 640, offset = 7, exit = exit},
	}
	add(&out, "welcome", .Welcome, 0, Welcome{wire = 1, instance = "8f3a0c1e", pid = 4100, holder_rev = 1, previous = "handover", hmac_key = "a1b2c3d4", terminals = terms})
	add(&out, "welcome-empty", .Welcome, 0, Welcome{wire = 1, instance = "8f3a0c1e", pid = 4100, holder_rev = 1, previous = "none", hmac_key = "a1b2c3d4", terminals = {}})
	for code in Refuse_Code {
		add(&out, fmt.tprintf("refused-%s", REFUSE_CODE_NAMES[code]), .Refused, 0, Refused{code = REFUSE_CODE_NAMES[code], error = "refused"})
	}
	add(&out, "upgrade", .Upgrade, 0, Upgrade{path = "/Applications/Deckhand.app/Contents/Helpers/deckhand-core"})
	add(&out, "upgrade-failed", .Upgrade_Failed, 0, Upgrade_Failed{error = "dry run failed: exit 2"})
	return out[:]
}

@(test)
golden_vectors :: proc(t: ^testing.T) {
	regold := os.get_env("HOLDER_WIRE_REGOLD", context.temp_allocator) == "1"
	for g in golden_frames() {
		path := fmt.tprintf("%s/%s.bin", GOLDEN_DIR, g.name)
		if regold {
			os.make_directory_all(GOLDEN_DIR)
			if _, err := os.stat(path, context.temp_allocator); err == nil do continue // never overwrite one that exists
			testing.expect(t, os.write_entire_file(path, g.bytes) == nil)
		}
		want, err := os.read_entire_file(path, context.temp_allocator)
		if !testing.expectf(t, err == nil, "%s missing (a frozen vector; HOLDER_WIRE_REGOLD=1 writes new ones)", path) do continue
		testing.expectf(t, string(want) == string(g.bytes), "%s: the encoding of a frozen message changed:\n  want %q\n  got  %q", path, string(want), string(g.bytes))
		// and the stored bytes decode
		f, used, ferr := next_frame(want)
		testing.expect_value(t, ferr, Frame_Error.None)
		testing.expect_value(t, used, len(want))
		spec, ok := spec_of(f.kind)
		testing.expect(t, ok && spec.frozen)
	}
	free_all(context.temp_allocator)
}

@(test)
golden_decode :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(GOLDEN_DIR + "/welcome.bin", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	f, _, _ := next_frame(data)
	w: Welcome
	testing.expect_value(t, decode(f, .Welcome, &w, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, w.previous, "handover")
	testing.expect_value(t, len(w.terminals), 2)
	if len(w.terminals) == 2 {
		testing.expect_value(t, w.terminals[0].offset, 123456)
		testing.expect(t, w.terminals[0].exit == nil)
		ex, has := w.terminals[1].exit.?
		testing.expect(t, has && ex.code == 3)
		testing.expect_value(t, w.terminals[1].xpixel, 960)
	}
	free_all(context.temp_allocator)
}

@(test)
header_layout :: proc(t: ^testing.T) {
	b := make([dynamic]u8, context.temp_allocator)
	encode_input(&b, 0x01020304, transmute([]u8)string("hi"))
	testing.expect_value(t, string(b[:]), "\x13\x04\x03\x02\x01\x02\x00\x00\x00hi")
	clear(&b)
	encode_output(&b, .Output, 7, 0x1122334455667788, transmute([]u8)string("x"))
	testing.expect_value(t, string(b[:]), "\x14\x07\x00\x00\x00\x09\x00\x00\x00\x88\x77\x66\x55\x44\x33\x22\x11x")
	f, _, _ := next_frame(b[:])
	start, bytes, e := decode_output(f)
	testing.expect_value(t, e, Msg_Error.None)
	testing.expect_value(t, start, 0x1122334455667788)
	testing.expect_value(t, string(bytes), "x")
	free_all(context.temp_allocator)
}

@(test)
frame_limits :: proc(t: ^testing.T) {
	h := []u8{u8(Kind.Input), 0, 0, 0, 0, 0, 0, 0, 0}
	// exactly MAX_PAYLOAD is allowed (needs more bytes), one more is fatal
	b := make([]u8, HEADER_SIZE, context.temp_allocator)
	copy(b, h)
	b[5], b[6], b[7], b[8] = 0, 0, 0, 1 // 16 MiB
	_, _, e := next_frame(b)
	testing.expect_value(t, e, Frame_Error.Need_More)
	b[5] = 1 // 16 MiB + 1
	_, _, e = next_frame(b)
	testing.expect_value(t, e, Frame_Error.Too_Large)
	_, _, e = next_frame(b[:4])
	testing.expect_value(t, e, Frame_Error.Need_More)
	big := make([]u8, MAX_PAYLOAD + 1, context.temp_allocator)
	out := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, !encode_input(&out, 1, big))
	testing.expect(t, !encode_output(&out, .Output, 1, 0, big[:MAX_OUTPUT_CHUNK + 1]))
	testing.expect(t, encode_output(&out, .Output, 1, 0, big[:MAX_OUTPUT_CHUNK]))
	free_all(context.temp_allocator)
}

// Every message the doc defines, round-tripped, and checked against its spec.
@(test)
all_messages_roundtrip :: proc(t: ^testing.T) {
	b := make([dynamic]u8, context.temp_allocator)
	encode(&b, .Spawn, 3, Spawn{argv = {"/bin/zsh", "-l"}, env = {"TERM=xterm-256color"}, cwd = "/tmp", cols = 80, rows = 24, xpixel = 640, ypixel = 384})
	encode(&b, .Spawned, 3, Spawned{pid = 10, pgid = 10})
	encode(&b, .Spawn_Failed, 4, Spawn_Failed{error = "no such file"})
	encode(&b, .Resize, 3, Resize{cols = 100, rows = 30, xpixel = 800, ypixel = 480})
	encode(&b, .Signal, 3, Signal{signal = 2, target = "pgroup"})
	encode(&b, .Release, 3, Empty{})
	encode(&b, .Exited, 3, Exited{code = 0, signal = 15, offset = 99})
	encode(&b, .Goodbye, 0, Goodbye{mode = "handover"})
	encode(&b, .Goodbye_Ack, 0, Goodbye_Ack{terminals = {{id = 3, offset = 99}}, successor_secret = "ff"})
	encode(&b, .Foreground, 3, Empty{})
	encode(&b, .Foreground_Is, 3, Foreground_Is{pgid = 11})
	encode(&b, .Ping, 0, Empty{})
	encode(&b, .Pong, 0, Empty{})
	encode(&b, .Unknown, 0, Unknown{kind = 200})
	encode_output(&b, .Tail, 3, 50, transmute([]u8)string("tail"))
	// every JSON message's keys are exactly its spec's (struct and schema agree)
	rest := b[:]
	n := 0
	for len(rest) > 0 {
		f, used, e := next_frame(rest)
		if !testing.expect_value(t, e, Frame_Error.None) do break
		rest = rest[used:]
		n += 1
		spec, ok := spec_of(f.kind)
		testing.expect(t, ok)
		if spec.payload != .Json do continue
		v, _ := json.parse(f.payload, .JSON, true, context.temp_allocator)
		obj := v.(json.Object)
		for k in obj {
			found := false
			for fs in spec.fields do if fs.name == k do found = true
			testing.expectf(t, found, "%s: field %q not in the schema", spec.name, k)
		}
		testing.expectf(t, check_fields(obj, spec.fields) == .None, "%s fails its own schema", spec.name)
	}
	testing.expect_value(t, n, 15)
	f, _, _ := next_frame(b[:])
	s: Spawn
	testing.expect_value(t, decode(f, .Spawn, &s, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, s.ypixel, 384)
	testing.expect_value(t, len(s.argv), 2)
	testing.expect_value(t, f.terminal, 3)
	free_all(context.temp_allocator)
}

@(test)
unknown_fields_and_kinds :: proc(t: ^testing.T) {
	frame :: proc(kind: u8, payload: string) -> Frame {return Frame{kind, 0, transmute([]u8)payload}}
	h: Hello
	// a newer core's extra fields are ignored
	testing.expect_value(t, decode(frame(1, `{"wire": 3, "future": {"x": [1, 2]}, "z": null}`), .Hello, &h, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, h.wire, 3)
	// required fields are required; known fields are typed
	testing.expect_value(t, decode(frame(1, `{"successor_secret": "ab"}`), .Hello, &h, context.temp_allocator), Msg_Error.Missing_Field)
	testing.expect_value(t, decode(frame(1, `{"wire": null}`), .Hello, &h, context.temp_allocator), Msg_Error.Missing_Field)
	testing.expect_value(t, decode(frame(1, `{"wire": "1"}`), .Hello, &h, context.temp_allocator), Msg_Error.Wrong_Type)
	testing.expect_value(t, decode(frame(1, `{"wire": 1.5}`), .Hello, &h, context.temp_allocator), Msg_Error.Wrong_Type)
	testing.expect_value(t, decode(frame(1, `{"wire": 1, "successor_secret": 5}`), .Hello, &h, context.temp_allocator), Msg_Error.Wrong_Type)
	testing.expect_value(t, decode(frame(1, `[1]`), .Hello, &h, context.temp_allocator), Msg_Error.Bad_Json)
	testing.expect_value(t, decode(frame(1, `{"wire": 1`), .Hello, &h, context.temp_allocator), Msg_Error.Bad_Json)
	testing.expect_value(t, decode(frame(2, `{}`), .Hello, &h, context.temp_allocator), Msg_Error.Wrong_Kind)
	// nested: a WELCOME terminal without an offset
	w: Welcome
	testing.expect_value(t, decode(frame(2, `{"wire":1,"instance":"i","pid":1,"holder_rev":1,"previous":"none","hmac_key":"k","terminals":[{"id":1,"pid":2,"pgid":2,"cols":80,"rows":24,"xpixel":0,"ypixel":0}]}`), .Welcome, &w, context.temp_allocator), Msg_Error.Missing_Field)
	// an unknown code in REFUSED is kept as text (grow-only)
	r: Refused
	testing.expect_value(t, decode(frame(3, `{"code": "quota", "error": "x"}`), .Refused, &r, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, r.code, "quota")
	// unknown kinds: the receiver answers UNKNOWN{kind}
	testing.expect(t, !is_known(200))
	testing.expect(t, !is_known(0))
	testing.expect_value(t, decode(frame(200, `{}`), .Hello, &h, context.temp_allocator), Msg_Error.Wrong_Kind)
	free_all(context.temp_allocator)
}

@(test)
negotiation :: proc(t: ^testing.T) {
	w, ok := negotiate(1)
	testing.expect(t, ok && w == 1)
	w, ok = negotiate(5) // a newer core: speak ours
	testing.expect(t, ok && w == WIRE)
	_, ok = negotiate(0) // older than our floor: REFUSED{wire}
	testing.expect(t, !ok)
	w, ok = negotiate(2, 2, 4)
	testing.expect(t, ok && w == 2)
	testing.expect(t, PONG_TIMEOUT == 6 * PING_INTERVAL)
}

// Random chunking: the stream decoder yields the same frames however the bytes arrive.
@(test)
stream_chunking :: proc(t: ^testing.T) {
	all := make([dynamic]u8, context.temp_allocator)
	for g in golden_frames() do append(&all, ..g.bytes)
	big := make([]u8, 200_000, context.temp_allocator)
	for i in 0 ..< len(big) do big[i] = u8(i * 7)
	encode_output(&all, .Output, 9, 1 << 40, big)
	encode_input(&all, 9, nil)
	want := len(golden_frames()) + 2
	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)
	for _ in 0 ..< 50 {
		s: Stream
		got := 0
		i := 0
		for i < len(all) {
			n := min(1 + rand.int_max(rand.int_max(2, gen) == 0 ? 7 : 70_000, gen), len(all) - i)
			stream_feed(&s, all[i:i + n])
			i += n
			for {
				f, e := stream_next(&s)
				if e != .None do break
				got += 1
				if f.kind == u8(Kind.Output) {
					start, bytes, _ := decode_output(f)
					testing.expect_value(t, start, 1 << 40)
					testing.expect(t, string(bytes) == string(big))
				}
			}
		}
		testing.expect_value(t, got, want)
		stream_destroy(&s)
	}
	free_all(context.temp_allocator)
}

// A bounded fuzz pass: random and mutated frames never crash the decoder,
// and a decoder answer is always one of the documented ones.
@(test)
decoder_fuzz :: proc(t: ^testing.T) {
	// the seeds outlive the temp allocator, which is reset as the pass runs
	seeds := make([dynamic][]u8)
	defer {for s in seeds do delete(s); delete(seeds)}
	for g in golden_frames() do append(&seeds, clone(g.bytes))
	extra := make([dynamic]u8, context.temp_allocator)
	encode(&extra, .Spawn, 1, Spawn{argv = {"a"}, env = {}, cwd = "/", cols = 1, rows = 1})
	append(&seeds, clone(extra[:]))
	clear(&extra)
	encode(&extra, .Goodbye_Ack, 0, Goodbye_Ack{terminals = {{id = 1, offset = 2}}, successor_secret = "s"})
	append(&seeds, clone(extra[:]))
	free_all(context.temp_allocator)
	buf := make([dynamic]u8)
	defer delete(buf)
	state := rand.create(t.seed)
	gen := rand.default_random_generator(&state)
	// built once with the heap allocator: the temp one is reset as the pass runs
	h := context.allocator
	deep300 := strings.concatenate({`{"a":`, strings.repeat("[", 300, context.temp_allocator)}, h)
	deep100k := strings.concatenate({`{"wire":1,"x":`, strings.repeat("[", 100_000, context.temp_allocator)}, h)
	objects := strings.repeat(`{"a":`, 50_000, h)
	many_keys := strings.concatenate({`{"wire":1,`, strings.repeat(`"k":0,`, 20_000, context.temp_allocator), `"z":0}`}, h)
	newline := strings.concatenate({"{\"wire\":[\"\n,", strings.repeat("[", 65_000, context.temp_allocator)}, h)
	defer {delete(deep300); delete(deep100k); delete(objects); delete(many_keys); delete(newline)}
	shapes := []string{`{"wire": {}}`, `{"terminals": [1, 2]}`, `{"terminals": [{"exit": 5}]}`, `{"argv": [1]}`, `null`, `"x"`, `{"wire": 1e400}`, `{"wire": -9223372036854775809}`, deep300, deep100k, objects, many_keys, newline, `{"s":"\\\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[","wire":1}`}
	free_all(context.temp_allocator)
	for iter in 0 ..< 40_000 {
		clear(&buf)
		switch rand.int_max(3, gen) {
		case 0: // random bytes behind a plausible header
			n := rand.int_max(200, gen)
			put_header(&buf, u8(rand.int_max(40, gen)), rand.uint32(gen), n)
			for _ in 0 ..< n do append(&buf, u8(rand.int_max(256, gen)))
		case 1: // a golden frame with bytes flipped, inserted or cut
			g := seeds[rand.int_max(len(seeds), gen)]
			append(&buf, ..g)
			for _ in 0 ..< 1 + rand.int_max(4, gen) {
				at := rand.int_max(len(buf), gen)
				switch rand.int_max(3, gen) {
				case 0: buf[at] ~= u8(1 << uint(rand.int_max(8, gen)))
				case 1: junk := "{}[]\",:0n\\"; buf[at] = junk[rand.int_max(len(junk), gen)]
				case 2: resize(&buf, at)
				}
				if len(buf) == 0 do break
			}
		case 2: // valid JSON of the wrong shape under a known kind
			s := shapes[rand.int_max(len(shapes), gen)]
			put_header(&buf, u8(1 + rand.int_max(32, gen)), 0, len(s))
			append(&buf, s)
		}
		f, used, e := next_frame(buf[:])
		testing.expect(t, used <= len(buf))
		if e != .None do continue
		spec, known := spec_of(f.kind)
		if !known do continue
		switch spec.payload {
		case .Offset_Raw: _, _, _ = decode_output(f)
		case .Raw:
		case .Json: fuzz_decode(t, f, spec.kind)
		}
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

@(private)
fuzz_decode :: proc(t: ^testing.T, f: Frame, kind: Kind) {
	a := context.temp_allocator
	e: Msg_Error
	#partial switch kind {
	case .Hello: m: Hello; e = decode(f, kind, &m, a)
	case .Welcome: m: Welcome; e = decode(f, kind, &m, a)
	case .Refused: m: Refused; e = decode(f, kind, &m, a)
	case .Upgrade: m: Upgrade; e = decode(f, kind, &m, a)
	case .Upgrade_Failed: m: Upgrade_Failed; e = decode(f, kind, &m, a)
	case .Spawn: m: Spawn; e = decode(f, kind, &m, a)
	case .Goodbye_Ack: m: Goodbye_Ack; e = decode(f, kind, &m, a)
	case .Exited: m: Exited; e = decode(f, kind, &m, a)
	case: m: Empty; e = decode(f, kind, &m, a)
	}
	testing.expect(t, e != .Unknown_Kind && e != .Wrong_Kind)
}

// Grow-only: the code's schema against the last released one.
@(test)
released_schema :: proc(t: ^testing.T) {
	current := schema_json(context.temp_allocator)
	os.make_directory_all("build")
	_ = os.write_entire_file("build/holder-schema.json", transmute([]u8)current) // to refresh the released file at a release
	released, err := os.read_entire_file(RELEASED, context.temp_allocator)
	if !testing.expectf(t, err == nil, "%s missing", RELEASED) do return
	for p in schema_problems(string(released), current, context.temp_allocator) do testing.expectf(t, false, "holder wire not grow-only: %s", p)
	free_all(context.temp_allocator)
}

// The diff check itself catches what it should.
@(test)
schema_diff_rules :: proc(t: ^testing.T) {
	base := schema_json(context.temp_allocator)
	expect_problem :: proc(t: ^testing.T, base, from, to, what: string) {
		changed, replaced := strings.replace(base, from, to, 1, context.temp_allocator)
		testing.expectf(t, replaced, "fixture %q not found", from)
		probs := schema_problems(base, changed, context.temp_allocator)
		found := false
		for p in probs do if strings.contains(p, what) do found = true
		testing.expectf(t, found, "%q -> %q: expected a %q problem, got %v", from, to, what, probs)
	}
	expect_problem(t, base, "control len <= 1048576", "control len <= 2097152", "header changed")
	expect_problem(t, base, `"name": "PING", "kind": 30`, `"name": "PING", "kind": 33`, "renumbered")
	expect_problem(t, base, `{"name": "path", "type": "string", "required": true}`, `{"name": "path", "type": "int", "required": true}`, "type changed")
	expect_problem(t, base, `{"name": "error", "type": "string", "required": true}]}`, `{"name": "error", "type": "string", "required": true}, {"name": "new", "type": "int", "required": true}]}`, "must be optional")
	expect_problem(t, base, `{"name": "successor_secret", "type": "string", "required": false}`, `{"name": "successor_secret", "type": "string", "required": true}`, "required changed")
	expect_problem(t, base, `{"name": "TAIL", "kind": 21`, `{"name": "TALE", "kind": 21`, "removed")
	expect_problem(t, base, `{"name": "pgid", "type": "int", "required": true}]}`, `]}`, "pgid: removed")
	expect_problem(t, base, `{"name": "exit", "type": "object", "required": false, "nullable": true, "items": [{"name": "code", "type": "int", "required": true}, {"name": "signal", "type": "int", "required": true}]}`, `{"name": "exit", "type": "object", "required": false, "nullable": true}`, "items removed")
	// adding an optional field or a new kind is fine
	ok_changed, _ := strings.replace(base, `{"name": "pgid", "type": "int", "required": true}]}`, `{"name": "pgid", "type": "int", "required": true}, {"name": "tty", "type": "string", "required": false}]}`, 1, context.temp_allocator)
	testing.expect_value(t, len(schema_problems(base, ok_changed, context.temp_allocator)), 0)
	testing.expect_value(t, len(schema_problems(base, base, context.temp_allocator)), 0)
	free_all(context.temp_allocator)
}

// Review finding 1: core:encoding/json recurses without a depth limit, so a
// deeply nested or key-heavy control payload must be refused before parsing.
@(test)
hostile_json :: proc(t: ^testing.T) {
	deep := strings.concatenate({`{"wire":1,"x":`, strings.repeat("[", 100_000, context.temp_allocator)}, context.temp_allocator)
	h: Hello
	testing.expect_value(t, decode(Frame{u8(Kind.Hello), 0, transmute([]u8)deep}, .Hello, &h, context.temp_allocator), Msg_Error.Bad_Json)
	keys := strings.builder_make(context.temp_allocator)
	strings.write_string(&keys, `{"wire":1`)
	for i in 0 ..< 60_000 do fmt.sbprintf(&keys, `,"k%d":0`, i)
	strings.write_byte(&keys, '}')
	testing.expect_value(t, decode(Frame{u8(Kind.Hello), 0, keys.buf[:]}, .Hello, &h, context.temp_allocator), Msg_Error.Bad_Json)
	// a raw newline ends a string for Odin's tokenizer, which the parser then ignores (round 2)
	nl := strings.concatenate({"{\"wire\":[\"\n,", strings.repeat("[", 65_000, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, decode(Frame{u8(Kind.Hello), 0, transmute([]u8)nl}, .Hello, &h, context.temp_allocator), Msg_Error.Bad_Json)
	testing.expect(t, !json_shape_ok(transmute([]u8)string(`{"a":"x	y"}`)))
	testing.expect(t, !json_shape_ok(transmute([]u8)string(`]]{"a":1}`)))
	testing.expect(t, json_shape_ok(transmute([]u8)string(`{"a":"x\ny \" [[["}`)))
	// invalid UTF-8 in a string overruns core:encoding/json's unquote buffer (found by the fuzz pass)
	bad_utf8 := strings.concatenate({`{"wire":1,"s":"`, strings.repeat("\xff", 12, context.temp_allocator), `"}`}, context.temp_allocator)
	testing.expect_value(t, decode(Frame{u8(Kind.Hello), 0, transmute([]u8)bad_utf8}, .Hello, &h, context.temp_allocator), Msg_Error.Bad_Json)
	// a control frame over the control cap is refused at the frame layer
	b := make([]u8, HEADER_SIZE, context.temp_allocator)
	b[0] = u8(Kind.Hello)
	b[5], b[6], b[7] = 1, 0, 0x10 // 1 MiB + 1
	_, _, e := next_frame(b)
	testing.expect_value(t, e, Frame_Error.Too_Large)
	b[0] = u8(Kind.Input) // raw kinds keep the 16 MiB cap
	_, _, e = next_frame(b)
	testing.expect_value(t, e, Frame_Error.Need_More)
	free_all(context.temp_allocator)
}

// Review finding 2: sizes are range-checked before anyone converts them to u16.
@(test)
size_ranges :: proc(t: ^testing.T) {
	frame :: proc(kind: Kind, payload: string) -> Frame {return Frame{u8(kind), 1, transmute([]u8)payload}}
	r: Resize
	testing.expect_value(t, decode(frame(.Resize, `{"cols":65535,"rows":24,"xpixel":0,"ypixel":0}`), .Resize, &r, context.temp_allocator), Msg_Error.Out_Of_Range)
	testing.expect_value(t, decode(frame(.Resize, `{"cols":0,"rows":24,"xpixel":0,"ypixel":0}`), .Resize, &r, context.temp_allocator), Msg_Error.Out_Of_Range)
	testing.expect_value(t, decode(frame(.Resize, `{"cols":80,"rows":24,"xpixel":-1,"ypixel":0}`), .Resize, &r, context.temp_allocator), Msg_Error.Out_Of_Range)
	testing.expect_value(t, decode(frame(.Resize, `{"cols":80,"rows":24,"xpixel":640,"ypixel":384}`), .Resize, &r, context.temp_allocator), Msg_Error.None)
	s: Spawn
	testing.expect_value(t, decode(frame(.Spawn, `{"argv":["sh"],"env":[],"cwd":"/","cols":80,"rows":100000,"xpixel":0,"ypixel":0}`), .Spawn, &s, context.temp_allocator), Msg_Error.Out_Of_Range)
	testing.expect_value(t, decode(frame(.Resize, `{"cols":2000,"rows":1000,"xpixel":0,"ypixel":0}`), .Resize, &r, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, decode(frame(.Resize, `{"cols":2001,"rows":10,"xpixel":0,"ypixel":0}`), .Resize, &r, context.temp_allocator), Msg_Error.Out_Of_Range)
	// WELCOME is the bootstrap: one bad terminal is flagged, the rest decode
	w: Welcome
	testing.expect_value(t, decode(frame(.Welcome, `{"wire":1,"instance":"i","pid":1,"holder_rev":1,"previous":"none","hmac_key":"k","terminals":[{"id":1,"pid":2,"pgid":2,"cols":5000,"rows":24,"xpixel":0,"ypixel":0,"offset":0,"exit":null},{"id":2,"pid":3,"pgid":3,"cols":80,"rows":24,"xpixel":0,"ypixel":0,"offset":9,"exit":null}]}`), .Welcome, &w, context.temp_allocator), Msg_Error.None)
	if testing.expect_value(t, len(w.terminals), 2) {
		testing.expect(t, w.terminals[0].bad)
		testing.expect(t, !w.terminals[1].bad)
		testing.expect_value(t, w.terminals[1].offset, 9)
	}
	// the key limit is per object: a WELCOME with 1000 terminals decodes
	ws := make([dynamic]Welcome_Terminal, context.temp_allocator)
	for i in 0 ..< 1000 do append(&ws, Welcome_Terminal{id = i64(i), pid = 1, pgid = 1, cols = 80, rows = 24})
	b := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, encode(&b, .Welcome, 0, Welcome{wire = 1, instance = "i", pid = 1, holder_rev = 1, previous = "none", hmac_key = "k", terminals = ws[:]}))
	f, _, _ := next_frame(b[:])
	w2: Welcome
	testing.expect_value(t, decode(f, .Welcome, &w2, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, len(w2.terminals), 1000)
	testing.expect(t, !strings.contains(string(b[:]), "bad")) // the flag never goes on the wire
	free_all(context.temp_allocator)
}

// Every message struct survives encode then decode unchanged (review finding 5).
@(test)
every_message_unmarshals :: proc(t: ^testing.T) {
	a := context.temp_allocator
	check :: proc(t: ^testing.T, kind: Kind, msg: $T) {
		b := make([dynamic]u8, context.temp_allocator)
		testing.expect(t, encode(&b, kind, 7, msg))
		f, _, _ := next_frame(b[:])
		got: T
		if !testing.expect_value(t, decode(f, kind, &got, context.temp_allocator), Msg_Error.None) do return
		again := make([dynamic]u8, context.temp_allocator)
		encode(&again, kind, 7, got)
		testing.expectf(t, string(b[:]) == string(again[:]), "%v: %q != %q", kind, string(b[:]), string(again[:]))
	}
	exit := Exit_Status{code = 1, signal = 9}
	check(t, .Hello, Hello{wire = 1, successor_secret = "ab"})
	check(t, .Welcome, Welcome{wire = 1, instance = "i", pid = 2, holder_rev = 3, previous = "crash", hmac_key = "k", terminals = {{id = 1, pid = 2, pgid = 3, cols = 80, rows = 24, xpixel = 1, ypixel = 2, offset = 1 << 40, exit = exit}, {id = 2, pid = 2, pgid = 3, cols = 1, rows = 1}}})
	check(t, .Refused, Refused{code = "floor", error = "too old"})
	check(t, .Upgrade, Upgrade{path = "/x"})
	check(t, .Upgrade_Failed, Upgrade_Failed{error = "e"})
	check(t, .Spawn, Spawn{argv = {"a", "b"}, env = {"X=1"}, cwd = "/", cols = 80, rows = 24, xpixel = 640, ypixel = 480})
	check(t, .Spawned, Spawned{pid = 5, pgid = 6})
	check(t, .Spawn_Failed, Spawn_Failed{error = "e"})
	check(t, .Resize, Resize{cols = 100, rows = 50, xpixel = 1000, ypixel = 1000})
	check(t, .Signal, Signal{signal = 15, target = "pid"})
	check(t, .Release, Empty{})
	check(t, .Exited, Exited{code = 2, signal = 0, offset = 77})
	check(t, .Goodbye, Goodbye{mode = "shutdown"})
	check(t, .Goodbye_Ack, Goodbye_Ack{terminals = {{id = 1, offset = 5}, {id = 2, offset = 6}}, successor_secret = "s"})
	check(t, .Foreground, Empty{})
	check(t, .Foreground_Is, Foreground_Is{pgid = 9})
	check(t, .Ping, Empty{})
	check(t, .Pong, Empty{})
	check(t, .Unknown, Unknown{kind = 99})
	// the nested exit status is checked against the schema too
	w: Welcome
	bad := `{"wire":1,"instance":"i","pid":1,"holder_rev":1,"previous":"none","hmac_key":"k","terminals":[{"id":1,"pid":2,"pgid":2,"cols":80,"rows":24,"xpixel":0,"ypixel":0,"offset":0,"exit":{"code":"x","signal":0}}]}`
	testing.expect_value(t, decode(Frame{u8(Kind.Welcome), 0, transmute([]u8)string(bad)}, .Welcome, &w, a), Msg_Error.Wrong_Type)
	free_all(a)
}

// The upgrade's optional WELCOME fields (§7.3 step 6): a keeper's degraded terminals and why it
// serves them; absent, they leave the frozen encoding as it was (golden_vectors).
@(test)
welcome_upgrade_fields :: proc(t: ^testing.T) {
	out := make([dynamic]u8, context.temp_allocator)
	encode(&out, .Welcome, 0, Welcome {
		wire = 1, instance = "ab", pid = 7, holder_rev = 2, previous = "upgrade", hmac_key = "00",
		terminals = {{id = 1, pid = 9, pgid = 9, cols = 80, rows = 24, offset = 3, degraded = true}, {id = 2, pid = 10, pgid = 10, cols = 80, rows = 24}},
		upgrade_error = "the new holder image failed verification",
	})
	f, _, _ := next_frame(out[:])
	w: Welcome
	testing.expect_value(t, decode(f, .Welcome, &w, context.temp_allocator), Msg_Error.None)
	testing.expect_value(t, w.upgrade_error, "the new holder image failed verification")
	testing.expect(t, w.terminals[0].degraded.? or_else false)
	testing.expect(t, w.terminals[1].degraded == nil)
	testing.expect(t, !strings.contains(string(f.payload), `"degraded":false`))
	// a wrong type is refused like any other field's
	bad := `{"wire":1,"instance":"ab","pid":7,"holder_rev":2,"previous":"none","hmac_key":"00","terminals":[{"id":1,"pid":9,"pgid":9,"cols":80,"rows":24,"xpixel":0,"ypixel":0,"offset":0,"degraded":1}]}`
	testing.expect_value(t, decode(Frame{u8(Kind.Welcome), 0, transmute([]u8)string(bad)}, .Welcome, &w, context.temp_allocator), Msg_Error.Wrong_Type)
}
