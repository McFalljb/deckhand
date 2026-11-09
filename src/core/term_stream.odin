package core

// Terminal streams, the core's side (docs/plans/background-core.md §5.5, option a; §5.6; M3-H).
// The window keeps its own ghostty terminal for each terminal tab it shows (term_view.odin) and
// the core streams it what its own terminal parses, byte for byte, so the two stay equal (test
// mode checks it after every script step by screen hash, autotest.odin):
//
//   window: {"type":"term.attach","id":"w3","tab_id":N,"history_lines":0}
//   core:   {"type":"term.attached","id":"w3","tab_id":N,"channel":C,"offset":O}   (or "error")
//   core:   [C][SNAPSHOT] meta JSON + GHOSTSNP at offset O (snapshot.odin), screen first
//   core:   [C][DATA] the bytes from O on, at most 64 KiB a frame, sent at the end of each core
//           tick (or sooner once 64 KiB wait), so never held more than one tick (≤ 8 ms of work)
//   core:   [C][RESIZE] {"offset","cols","rows","xpixel","ypixel"}: applied after exactly the
//           bytes before offset; the core is the only resize authority
//   core:   {"type":"term.scroll","channel":C}: the core typed or pasted into it (scroll down)
//   core:   [C][CLOSE] the terminal went
//   window: [C][DATA] input, as the window's encoders made it (the core writes it to the PTY)
//   window: [C][CREDIT] u32 LE: DATA bytes it took (it starts with STREAM_CREDIT)
//   window: [C][FOCUS] one byte, 1 gained, 0 lost: reported to the program if it asked (1004)
//   window: {"type":"term.resize","tab_id":N,"cols","rows","cell_w","cell_h"}: what its pane fits
//   window: {"type":"term.detach","channel":C}
//
// Flow control (§5.6): DATA waits for credit; more than STREAM_BEHIND_MAX waiting, and the window
// gets a fresh snapshot instead (snapshots are exempt from credit). A terminal replaced under a
// stream (term_start's new terminal, a holder adopt) is sent as a snapshot too.
//
// The window's copy gets no callbacks: it never answers queries (the core does, from its own
// terminal) and never writes to the PTY itself; its input comes here as DATA.

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import cw "../corewire"
import gh "../ghostty"

STREAM_CREDIT :: 256 * 1024 // DATA a window may have unread (credit at attach, §5.6)
STREAM_BEHIND_MAX :: 4 * 1024 * 1024 // more than this waiting for credit: a fresh snapshot
STREAM_DATA_MAX :: 64 * 1024 // one DATA frame at most (the coalescing size)

@(private = "file")
Stream_Resize :: struct {
	offset:         u64,
	cols, rows:     u16,
	xpixel, ypixel: u32,
}

Term_Stream :: struct {
	channel:   u32,
	tab_id:    u64,
	t:         ^Term,
	pending:   [dynamic]u8, // bytes from `from` on, not sent yet (pending[head:])
	head:      int,
	from:      u64, // the stream offset pending[head] is at
	resizes:   [dynamic]Stream_Resize, // not sent yet, in offset order
	sent:      u64, // DATA bytes sent
	credited:  u64, // DATA bytes the window took (CREDIT)
	need_snap: bool, // send a snapshot at the next flush (attach, a new terminal, too far behind)
	history:   int, // history_lines asked at attach (0: all)
	// stats (tests, the scenes' log)
	snapshots: int,
	snap_retries: int, // a snapshot that could not be made yet (an unfinished sequence over the limit)
}

@(private = "file")
streams: [dynamic]^Term_Stream
@(private = "file")
next_channel: u32 = 1
@(private = "file")
flushing: bool

// The streams (tests).
term_streams :: proc() -> []^Term_Stream {return streams[:]}

// ---- what the core's terminals report ----

// Bytes t just parsed (term_vt_write): queued for each window streaming t.
term_stream_bytes :: proc(t: ^Term, bytes: []u8) {
	for s in streams do if s.t == t && !s.need_snap {
		append(&s.pending, ..bytes)
		if pending_len(s) > STREAM_BEHIND_MAX do stream_behind(s)
		else if pending_len(s) >= STREAM_DATA_MAX && !flushing do stream_flush(s)
	}
}

// t's terminal was replaced (or changed outside the byte stream): its windows get a snapshot.
term_stream_reset :: proc(t: ^Term) {
	for s in streams do if s.t == t do stream_drop_pending(s, snap = true)
}

// t was resized (term_resize): its windows' copies follow at this byte offset.
term_stream_resized :: proc(t: ^Term) {
	for s in streams do if s.t == t && !s.need_snap {
		append(&s.resizes, Stream_Resize{offset = t.offset, cols = t.cols, rows = t.rows, xpixel = u32(f32(t.cols) * t.cell.x), ypixel = u32(f32(t.rows) * t.cell.y)})
	}
}

// The core typed or pasted into t: the window's copy scrolls down, as for the user's typing.
term_stream_scroll_bottom :: proc(t: ^Term) {
	for s in streams do if s.t == t {
		stream_flush(s) // after what came before
		window_link_send_text(fmt.tprintf(`{{"v":%d,"type":"term.scroll","channel":%d}}`, PROTOCOL_VERSION, s.channel))
	}
}

// t goes (term_free): its channels close.
term_stream_term_gone :: proc(t: ^Term) {
	for i := len(streams) - 1; i >= 0; i -= 1 {
		s := streams[i]
		if s.t != t do continue
		window_link_send_frame(s.channel, .Close, nil)
		stream_free(i)
	}
}

// Every stream sends what waits (the end of core_tick; before a test's screen-hash check).
term_streams_flush :: proc() {
	for s in streams do stream_flush(s)
}

// The window went (core_detach_window): its streams end.
term_streams_window_gone :: proc() {
	for len(streams) > 0 do stream_free(len(streams) - 1)
}

// ---- from the window ----

// A JSON message about terminals (window_link.odin's link_message). Main thread.
term_stream_message :: proc(type: string, obj: json.Object, id: string) {
	switch type {
	case "term.attach":
		tab_id := json_u64(obj["tab_id"])
		history := int(json_u64(obj["history_lines"]))
		t := term_of(tab_id)
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"v":%d,"type":"term.attached","id":`, PROTOCOL_VERSION)
		json_quote(&b, id)
		fmt.sbprintf(&b, `,"tab_id":%d`, tab_id)
		if t == nil {
			strings.write_string(&b, `,"error":"no such terminal"}`)
			window_link_send_text(strings.to_string(b))
			return
		}
		heap := runtime.heap_allocator()
		s := new(Term_Stream, heap)
		s.channel, s.tab_id, s.t, s.history = next_channel, tab_id, t, history
		next_channel += 1
		s.pending = make([dynamic]u8, heap)
		s.resizes = make([dynamic]Stream_Resize, heap)
		s.need_snap = true
		append(&streams, s)
		fmt.sbprintf(&b, `,"channel":%d,"offset":%d}}`, s.channel, t.offset)
		window_link_send_text(strings.to_string(b))
		stream_flush(s) // the snapshot, at that offset
	case "term.detach":
		ch := u32(json_u64(obj["channel"]))
		for s, i in streams do if s.channel == ch {
			stream_free(i)
			break
		}
	case "term.resize":
		t := term_of(json_u64(obj["tab_id"]))
		cols, rows := json_u64(obj["cols"]), json_u64(obj["rows"])
		cw_, ch_ := json_f32(obj["cell_w"]), json_f32(obj["cell_h"])
		if t == nil || cols < 2 || rows < 2 || cols > u64(MAX_TERM_COLS) || rows > u64(MAX_TERM_ROWS) || cw_ <= 0 || ch_ <= 0 || cw_ > 1000 || ch_ > 1000 do return
		term_resize(t, u16(cols), u16(rows), cw_, ch_)
	}
}

// A frame on a terminal channel from the window (window_link_pump). Main thread.
term_stream_frame :: proc(f: cw.Frame) {
	s := stream_of(f.channel)
	if s == nil do return // detached, or its terminal went: dropped
	t := s.t
	switch cw.Kind(f.kind) {
	case .Data: // the user's input, encoded by the window
		if t.running && pty_open(&t.pty) do pty_write(&t.pty, f.payload)
	case .Credit:
		if len(f.payload) >= 4 {
			n, _ := endian.get_u32(f.payload[:4], .Little)
			s.credited = min(s.credited + u64(n), s.sent)
		}
		stream_flush(s)
	case .Focus:
		if len(f.payload) < 1 || !t.running || !mode_on(t, 1004) do return
		out: [16]u8
		n: uint
		if gh.focus_encode(f.payload[0] != 0 ? .Gained : .Lost, &out[0], len(out), &n) == .Success do pty_write(&t.pty, out[:n])
	case .Snapshot, .Resize, .Close: // the core's to send
	}
}

// ---- inside ----

@(private = "file")
stream_of :: proc(channel: u32) -> ^Term_Stream {
	for s in streams do if s.channel == channel do return s
	return nil
}

@(private = "file")
pending_len :: proc(s: ^Term_Stream) -> int {return len(s.pending) - s.head}

@(private = "file")
stream_drop_pending :: proc(s: ^Term_Stream, snap: bool) {
	clear(&s.pending)
	s.head = 0
	clear(&s.resizes)
	s.from = s.t.offset
	if snap do s.need_snap = true
}

// Too far behind (the window does not take its DATA): what waits goes; a snapshot replaces it.
@(private = "file")
stream_behind :: proc(s: ^Term_Stream) {
	stream_drop_pending(s, snap = true)
}

@(private = "file")
stream_free :: proc(i: int) {
	s := streams[i]
	ordered_remove(&streams, i)
	heap := runtime.heap_allocator()
	delete(s.pending)
	delete(s.resizes)
	free(s, heap)
}

// Sends what waits: a snapshot first if one is due, then DATA and RESIZEs in offset order while
// credit lasts.
@(private = "file")
stream_flush :: proc(s: ^Term_Stream) {
	if flushing do return // a frame sent below made the window act (in process): the outer flush goes on
	flushing = true
	defer flushing = false
	if s.need_snap && !stream_snapshot(s) do return
	for {
		next_resize := len(s.resizes) > 0 ? s.resizes[0].offset : max(u64)
		if len(s.resizes) > 0 && next_resize <= s.from {
			r := s.resizes[0]
			ordered_remove(&s.resizes, 0)
			body := fmt.tprintf(`{{"offset":%d,"cols":%d,"rows":%d,"xpixel":%d,"ypixel":%d}}`, r.offset, r.cols, r.rows, r.xpixel, r.ypixel)
			window_link_send_frame(s.channel, .Resize, transmute([]u8)body)
			continue
		}
		avail := u64(pending_len(s))
		if next_resize != max(u64) do avail = min(avail, next_resize - s.from)
		if avail == 0 do break
		in_flight := s.sent - s.credited
		if in_flight >= STREAM_CREDIT do break // waits for CREDIT (or, past STREAM_BEHIND_MAX, a snapshot)
		n := int(min(avail, u64(STREAM_DATA_MAX), u64(STREAM_CREDIT) - in_flight))
		if window_link_send_frame(s.channel, .Data, s.pending[s.head:s.head + n]) != .None do break
		s.sent += u64(n)
		s.head += n
		s.from += u64(n)
		if s.head == len(s.pending) {
			clear(&s.pending)
			s.head = 0
		} else if s.head > 1024 * 1024 && s.head * 2 > len(s.pending) {
			copy(s.pending[:], s.pending[s.head:])
			resize(&s.pending, len(s.pending) - s.head)
			s.head = 0
		}
	}
}

// The terminal as a snapshot at its current offset (meta + GHOSTSNP, screen first: the codec's
// READY comes before history, newest page first). Trimmed to fit one frame (§5.1, 16 MiB): older
// scrollback goes first. False: not yet (an unfinished sequence over the continuation limit:
// retried at the next flush, after the parser is back at ground).
@(private = "file")
stream_snapshot :: proc(s: ^Term_Stream) -> bool {
	t := s.t
	meta := Snapshot_Meta{offset = t.offset, xpixel = i64(min(f32(t.cols) * t.cell.x, 65535)), ypixel = i64(min(f32(t.rows) * t.cell.y, 65535))}
	if t.exit.known {
		meta.exited = 1
		meta.exit_code, meta.exit_signal = i64(t.exit.code), i64(t.exit.signal)
	}
	meta.inexact = t.inexact
	blob, err := snapshot_encode_fit(t.gt, meta, cw.MAX_PAYLOAD)
	if err != .None {
		s.snap_retries += 1
		return false
	}
	if window_link_send_frame(s.channel, .Snapshot, blob) != .None do return false
	s.need_snap = false
	s.snapshots += 1
	clear(&s.pending)
	s.head = 0
	clear(&s.resizes) // the snapshot is at the current size
	s.from = t.offset
	return true
}

// A GHOSTSNP snapshot of gt (only GHOSTSNP: a window always decodes it; the VT fallback is for
// a handover between versions) of at most limit bytes: over it, a copy with less scrollback is
// encoded instead, halving the limit each time, oldest lines first (temp allocator).
snapshot_encode_fit :: proc(gt: gh.Terminal, meta: Snapshot_Meta, limit: int) -> (blob: []u8, err: Snapshot_Error) {
	formats := [?]string{SNAPSHOT_GHOSTSNP}
	blob, _, err = snapshot_encode(gt, meta, formats[:], allocator = context.temp_allocator)
	if err != .None || len(blob) <= limit do return
	clone, ok := gt_clone(gt)
	if !ok do return nil, .Unfinished
	defer gh.terminal_free(clone)
	max_bytes := uint(TERM_SCROLLBACK_MAX)
	for max_bytes > 64 * 1024 {
		max_bytes /= 2
		gh.terminal_set(clone, .Scrollback_Max_Bytes, &max_bytes)
		blob, _, err = snapshot_encode(clone, meta, formats[:], allocator = context.temp_allocator)
		if err != .None || len(blob) <= limit do return
	}
	return nil, .Encode_Failed
}

@(private = "file")
json_u64 :: proc(v: json.Value) -> u64 {
	#partial switch x in v {
	case json.Integer: return x >= 0 ? u64(x) : 0
	case json.Float: return x >= 0 && x < 1e18 ? u64(x) : 0
	}
	return 0
}

@(private = "file")
json_f32 :: proc(v: json.Value) -> f32 {
	#partial switch x in v {
	case json.Integer: return f32(x)
	case json.Float: return f32(x)
	}
	return 0
}
