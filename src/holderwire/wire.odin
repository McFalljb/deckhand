// The holder wire (docs/plans/background-core.md §5.7): what the core and the
// session holder say to each other over holder-<rand8>.sock. Pure: no sockets,
// no ghostty, no app state, so the holder (PR B) can link it alone.
//
// A frame is [kind u8][terminal u32 LE][len u32 LE][payload ≤ 16 MiB].
// `terminal` is 0 for messages about the holder itself. Control payloads are
// JSON objects; INPUT is raw bytes; OUTPUT and TAIL are a u64 LE start offset
// followed by raw bytes.
//
// Compatibility rules (checked by the tests against schema/released-holder.json):
// - frozen forever: the header and HELLO, WELCOME, REFUSED, UPGRADE,
//   UPGRADE_FAILED with their required fields (golden vectors in tests/holder-wire/v1/);
// - everything else is grow-only, versioned by `wire`: new kinds and new
//   optional fields only. Unknown fields are ignored; an unknown kind gets UNKNOWN{kind}.
package holderwire

import "core:encoding/endian"
import "core:encoding/json"
import "core:time"
import jg "../jsonguard"

HEADER_SIZE :: 9
MAX_PAYLOAD :: 16 * 1024 * 1024 // INPUT, OUTPUT, TAIL and unknown kinds
MAX_CONTROL :: 1024 * 1024 // a JSON control payload of a known kind

// core:encoding/json parses recursively with no depth limit and unmarshal's
// stack grows per object key, so a hostile payload (100 KB of "[", or MBs of
// keys) overflows the stack. json_shape_ok refuses those before anything
// parses them.
JSON_MAX_DEPTH :: 32
JSON_MAX_KEYS :: 4096 // per object: unmarshal's stack grows per key of one object

// Terminal sizes the wire accepts (Deckhand's largest grid has room to spare);
// checked on decode, before anyone converts them to u16.
MAX_COLS :: 2000
MAX_ROWS :: 1000
MAX_PIXELS :: 65535 // winsize's ws_xpixel/ws_ypixel are unsigned short

WIRE :: 1 // the newest wire this code speaks
WIRE_MIN :: 1 // the oldest it accepts

PING_INTERVAL :: 5 * time.Second // the core pings this often
PONG_TIMEOUT :: 30 * time.Second // a core that misses pongs this long is dropped
SUCCESSOR_TTL :: 60 * time.Second // a successor secret (GOODBYE{successor}): valid this long, for one HELLO (§7.2)

// Kind numbers never change or get reused.
Kind :: enum u8 {
	// frozen forever (the bootstrap: enough to refuse or upgrade any peer)
	Hello          = 1,
	Welcome        = 2,
	Refused        = 3,
	Upgrade        = 4,
	Upgrade_Failed = 5,
	// grow-only
	Spawn          = 16,
	Spawned        = 17,
	Spawn_Failed   = 18,
	Input          = 19, // raw bytes for the terminal's PTY
	Output         = 20, // u64 start + bytes
	Tail           = 21, // u64 start + bytes (what was kept while no core read)
	Resize         = 22,
	Signal         = 23,
	Release        = 24,
	Exited         = 25,
	Goodbye        = 26,
	Goodbye_Ack    = 27,
	Foreground     = 28,
	Foreground_Is  = 29,
	Ping           = 30,
	Pong           = 31,
	Unknown        = 32,
}

Header :: struct {
	kind:     u8, // raw, so an unknown kind survives decoding
	terminal: u32,
	len:      u32,
}

Frame :: struct {
	kind:     u8,
	terminal: u32,
	payload:  []u8, // borrowed from the input
}

Frame_Error :: enum {
	None,
	Need_More, // not a whole frame yet
	Too_Large, // len > MAX_PAYLOAD: the stream is unusable, close it
}

Msg_Error :: enum {
	None,
	Unknown_Kind, // reply UNKNOWN{kind}
	Wrong_Kind, // decoded as the wrong message type (a caller bug)
	Bad_Json, // not a JSON object
	Missing_Field, // a required field is absent or null
	Wrong_Type, // a known field has the wrong JSON type
	Short_Payload, // OUTPUT/TAIL shorter than its offset
	Out_Of_Range, // a size outside MAX_COLS/MAX_ROWS/MAX_PIXELS
}

// ---- messages ----
// Numbers are i64 (every number on this wire fits one). Duplicate keys are
// rejected by json.parse, which decode runs before unmarshal.

Refuse_Code :: enum {
	Wire, // no common wire version
	Identity, // the peer's code identity failed the check
	Floor, // the peer is older than this side's floor
	Attached, // another core is attached
	Secret, // a wrong, used or expired successor secret
}

REFUSE_CODE_NAMES := [Refuse_Code]string {
	.Wire     = "wire",
	.Identity = "identity",
	.Floor    = "floor",
	.Attached = "attached",
	.Secret   = "secret",
}

Hello :: struct {
	wire:             i64, // the newest wire the core speaks
	successor_secret: string `json:"successor_secret,omitempty"`, // hex, after a §7.2 handover
}

Exit_Status :: struct {
	code:   i64,
	signal: i64, // 0 if it exited on its own
}

Welcome_Terminal :: struct {
	id:     i64,
	pid:    i64,
	pgid:   i64,
	cols:   i64,
	rows:   i64,
	xpixel: i64,
	ypixel: i64,
	offset: u64, // output bytes produced so far
	exit:   Maybe(Exit_Status), // null while running; code -1: it ended unseen (unknown)
	// not the holder's child: a keeper adopted it after a failed upgrade (§7.3 step 6). Output,
	// input, signals and exit codes work; no waitpid or parent-based job control.
	degraded: Maybe(bool) `json:"degraded,omitempty"`, // omitted (nil) unless true
	bad:    bool `json:"-"`, // set by decode: a size out of range (never on the wire)
}

Welcome :: struct {
	wire:       i64, // the version both now speak
	instance:   string,
	pid:        i64,
	holder_rev: i64,
	previous:   string, // none | handover | crash | upgrade
	hmac_key:   string, // hex
	terminals:  []Welcome_Terminal,
	// set when an upgrade's new image did not take the terminals and its keeper serves them
	// (previous = upgrade): why ("the new holder image failed verification ...")
	upgrade_error: string `json:"upgrade_error,omitempty"`,
}

Refused :: struct {
	code:  string, // Refuse_Code names; unknown codes are kept as text
	error: string,
}

Upgrade :: struct {
	path: string,
}

Upgrade_Failed :: struct {
	error: string,
}

Spawn :: struct {
	argv:   []string,
	env:    []string,
	cwd:    string,
	cols:   i64,
	rows:   i64,
	xpixel: i64,
	ypixel: i64,
}

Spawned :: struct {
	pid:  i64,
	pgid: i64,
}

Spawn_Failed :: struct {
	error: string,
}

Resize :: struct {
	cols:   i64,
	rows:   i64,
	xpixel: i64,
	ypixel: i64,
}

Signal :: struct {
	signal: i64,
	target: string, // pid | pgroup
}

Exited :: struct {
	code:   i64,
	signal: i64,
	offset: u64, // sent after all output up to here
}

Goodbye :: struct {
	mode:      string, // handover | shutdown
	// handover only: a successor is named (the updater's relaunch, §7.2): GOODBYE_ACK carries a
	// fresh successor secret, and for SUCCESSOR_TTL only a HELLO with it is welcomed
	successor: bool `json:"successor,omitempty"`,
}

Ack_Terminal :: struct {
	id:     i64,
	offset: u64,
}

Goodbye_Ack :: struct {
	terminals:        []Ack_Terminal,
	successor_secret: string,
}

Foreground_Is :: struct {
	pgid: i64,
}

Unknown :: struct {
	kind: i64,
}

Empty :: struct {} // RELEASE, FOREGROUND, PING, PONG

// ---- header and frames ----

put_header :: proc(out: ^[dynamic]u8, kind: u8, terminal: u32, n: int) {
	h: [HEADER_SIZE]u8
	h[0] = kind
	endian.put_u32(h[1:5], .Little, terminal)
	endian.put_u32(h[5:9], .Little, u32(n))
	append(out, ..h[:])
}

parse_header :: proc(b: []u8) -> (h: Header, ok: bool) {
	if len(b) < HEADER_SIZE do return
	h.kind = b[0]
	h.terminal, _ = endian.get_u32(b[1:5], .Little)
	h.len, _ = endian.get_u32(b[5:9], .Little)
	return h, true
}

// The first whole frame in b and how many bytes it took.
next_frame :: proc(b: []u8) -> (f: Frame, used: int, err: Frame_Error) {
	h, ok := parse_header(b)
	if !ok do return {}, 0, .Need_More
	if h.len > MAX_PAYLOAD do return {}, 0, .Too_Large
	if spec, known := spec_of(h.kind); known && spec.payload == .Json && h.len > MAX_CONTROL do return {}, 0, .Too_Large
	end := HEADER_SIZE + int(h.len)
	if len(b) < end do return {}, 0, .Need_More
	return Frame{h.kind, h.terminal, b[HEADER_SIZE:end]}, end, .None
}

// A byte stream in, whole frames out. Frames returned by next are valid until
// the next feed or next call.
Stream :: struct {
	buf:  [dynamic]u8,
	head: int,
}

stream_feed :: proc(s: ^Stream, b: []u8) {
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
	used: int
	f, used, err = next_frame(s.buf[s.head:])
	if err == .None do s.head += used
	return
}

stream_destroy :: proc(s: ^Stream) {delete(s.buf)}

// ---- encoding ----

is_known :: proc(kind: u8) -> bool {
	_, ok := spec_of(kind)
	return ok
}

// Appends a control frame. False if the payload would be too large.
encode :: proc(out: ^[dynamic]u8, kind: Kind, terminal: u32, msg: $T) -> bool {
	spec, _ := spec_of(u8(kind))
	assert(spec.payload == .Json, "encode: not a JSON kind")
	data, err := json.marshal(msg, {}, context.temp_allocator)
	if err != nil || len(data) > MAX_CONTROL do return false
	put_header(out, u8(kind), terminal, len(data))
	append(out, ..data)
	return true
}

// INPUT: raw bytes.
encode_input :: proc(out: ^[dynamic]u8, terminal: u32, bytes: []u8) -> bool {
	if len(bytes) > MAX_PAYLOAD do return false
	put_header(out, u8(Kind.Input), terminal, len(bytes))
	append(out, ..bytes)
	return true
}

// OUTPUT or TAIL: the stream offset of bytes[0], then the bytes.
encode_output :: proc(out: ^[dynamic]u8, kind: Kind, terminal: u32, start: u64, bytes: []u8) -> bool {
	assert(kind == .Output || kind == .Tail)
	if len(bytes) + 8 > MAX_PAYLOAD do return false
	put_header(out, u8(kind), terminal, len(bytes) + 8)
	o: [8]u8
	endian.put_u64(o[:], .Little, start)
	append(out, ..o[:])
	append(out, ..bytes)
	return true
}

// The largest chunk of PTY bytes one OUTPUT/TAIL frame carries.
MAX_OUTPUT_CHUNK :: MAX_PAYLOAD - 8

// ---- decoding ----

// Decodes a control frame into msg, after checking it against the schema:
// required fields present and non-null, known fields of the right JSON type.
// Unknown fields are ignored. Strings and slices are allocated with `allocator`.
decode :: proc(f: Frame, kind: Kind, msg: ^$T, allocator := context.allocator) -> Msg_Error {
	if f.kind != u8(kind) do return .Wrong_Kind
	spec, known := spec_of(f.kind)
	if !known do return .Unknown_Kind
	if spec.payload != .Json do return .Wrong_Kind
	if len(f.payload) > MAX_CONTROL || !json_shape_ok(f.payload) do return .Bad_Json
	v, perr := json.parse(f.payload, .JSON, true, context.temp_allocator)
	if perr != nil do return .Bad_Json
	obj, is_obj := v.(json.Object)
	if !is_obj do return .Bad_Json
	if e := check_fields(obj, spec.fields); e != .None do return e
	if json.unmarshal(f.payload, msg, .JSON, allocator) != nil do return .Wrong_Type
	when T == Resize || T == Spawn {
		if !size_ok(msg.cols, msg.rows, msg.xpixel, msg.ypixel) do return .Out_Of_Range
	} else when T == Welcome {
		// the bootstrap message: flag a bad terminal, keep the rest
		for &w in msg.terminals do w.bad = !size_ok(w.cols, w.rows, w.xpixel, w.ypixel)
	}
	return .None
}

size_ok :: proc(cols, rows, xpixel, ypixel: i64) -> bool {
	return cols >= 1 && cols <= MAX_COLS && rows >= 1 && rows <= MAX_ROWS && xpixel >= 0 && xpixel <= MAX_PIXELS && ypixel >= 0 && ypixel <= MAX_PIXELS
}

// A cheap scan of JSON text before json.parse (src/jsonguard: why, and
// what it refuses): nesting, keys per object, excess closers, raw control
// bytes in strings, invalid UTF-8.
json_shape_ok :: proc(b: []u8, max_depth := JSON_MAX_DEPTH, max_keys := JSON_MAX_KEYS) -> bool {
	return jg.shape_ok(b, max_depth, max_keys, .JSON)
}

// OUTPUT/TAIL: the start offset and the bytes (borrowed).
decode_output :: proc(f: Frame) -> (start: u64, bytes: []u8, err: Msg_Error) {
	if f.kind != u8(Kind.Output) && f.kind != u8(Kind.Tail) do return 0, nil, .Wrong_Kind
	if len(f.payload) < 8 do return 0, nil, .Short_Payload
	start, _ = endian.get_u64(f.payload[:8], .Little)
	return start, f.payload[8:], .None
}

check_fields :: proc(obj: json.Object, fields: []Field_Spec) -> Msg_Error {
	for fs in fields {
		val, present := obj[fs.name]
		_, is_null := val.(json.Null)
		if !present || is_null {
			if fs.required do return .Missing_Field
			if is_null && !fs.nullable && present do return .Wrong_Type
			continue
		}
		if !type_matches(val, fs.type) do return .Wrong_Type
		if fs.items == nil do continue
		#partial switch fs.type {
		case .Objects:
			for item in val.(json.Array) {
				o, ok := item.(json.Object)
				if !ok do return .Wrong_Type
				if e := check_fields(o, fs.items); e != .None do return e
			}
		case .Object:
			if e := check_fields(val.(json.Object), fs.items); e != .None do return e
		}
	}
	return .None
}

type_matches :: proc(v: json.Value, t: Field_Type) -> bool {
	switch t {
	case .Int:
		#partial switch n in v {
		case json.Integer: return true
		case json.Float: return n == f64(i64(n))
		}
		return false
	case .String:
		_, ok := v.(json.String)
		return ok
	case .Strings:
		arr, ok := v.(json.Array)
		if !ok do return false
		for x in arr do if _, s := x.(json.String); !s do return false
		return true
	case .Objects:
		_, ok := v.(json.Array)
		return ok
	case .Object:
		_, ok := v.(json.Object)
		return ok
	case .Bool:
		_, ok := v.(json.Boolean)
		return ok
	}
	return false
}

// Wire negotiation: the holder answers a HELLO{wire} with WELCOME{wire = the
// result}, or REFUSED{wire} when there is none.
negotiate :: proc(peer_wire: i64, ours_min := i64(WIRE_MIN), ours_max := i64(WIRE)) -> (wire: i64, ok: bool) {
	if peer_wire < ours_min do return 0, false
	return min(peer_wire, ours_max), true
}
