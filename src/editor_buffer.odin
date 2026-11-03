package main

// The editor's text: a piece table. The file's bytes are read once into
// `orig` and never change; inserted text is appended to `add`; the document
// is the list of pieces (ranges of either buffer). Why a piece table and not a
// rope: opening a file is one read plus one newline scan (no copy, no tree to
// build), the original bytes stay valid for tree-sitter's reader and for
// undo, and typing appends to the last piece instead of growing the list.
//
// Line index: both buffers keep the offsets of their '\n' bytes (orig: one
// scan at load; add: appended as text arrives). Pieces carry their newline
// count, and prefix sums of piece lengths and newline counts are rebuilt
// lazily from the first piece an edit touched. Offset <-> line lookups are
// binary searches; an edit costs O(pieces) at worst (the prefix rebuild),
// and pieces stay few (one per edit location, not per keystroke).
//
// Text is bytes (UTF-8, not validated). Lines end at '\n'; a '\r' before it
// is part of the line ending (CRLF files keep their endings as they are).

import "core:slice"
import "core:strings"

Piece :: struct {
	add:   bool, // which buffer: orig or add
	start: int,
	len:   int,
	nl:    int, // newlines in the range
}

Text_Buffer :: struct {
	orig:      []u8,
	add:       [dynamic]u8,
	orig_nl:   [dynamic]int, // offsets of '\n' in orig
	add_nl:    [dynamic]int,
	pieces:    [dynamic]Piece,
	pre_len:   [dynamic]int, // bytes before piece i
	pre_nl:    [dynamic]int, // newlines before piece i
	prefix_ok: int, // pre_* valid for pieces [0, prefix_ok)
	length:    int,
	newlines:  int,
}

// Takes ownership of data (heap, may be nil).
tb_init :: proc(b: ^Text_Buffer, data: []u8) {
	b^ = {}
	b.orig = data
	scan_newlines(&b.orig_nl, data, 0)
	if len(data) > 0 do append(&b.pieces, Piece{start = 0, len = len(data), nl = len(b.orig_nl)})
	b.length = len(data)
	b.newlines = len(b.orig_nl)
}

tb_destroy :: proc(b: ^Text_Buffer) {
	delete(b.orig)
	delete(b.add)
	delete(b.orig_nl)
	delete(b.add_nl)
	delete(b.pieces)
	delete(b.pre_len)
	delete(b.pre_nl)
	b^ = {}
}

@(private = "file")
scan_newlines :: proc(out: ^[dynamic]int, data: []u8, base: int) {
	rest := data
	off := 0
	for {
		i := slice.linear_search(rest, '\n') or_break
		append(out, base + off + i)
		off += i + 1
		rest = rest[i + 1:]
	}
}

tb_len :: proc(b: ^Text_Buffer) -> int {return b.length}
tb_line_count :: proc(b: ^Text_Buffer) -> int {return b.newlines + 1}

@(private = "file")
piece_bytes :: proc(b: ^Text_Buffer, p: Piece) -> []u8 {
	return p.add ? b.add[p.start:][:p.len] : b.orig[p.start:][:p.len]
}

@(private = "file")
nl_of :: proc(b: ^Text_Buffer, add: bool) -> []int {return add ? b.add_nl[:] : b.orig_nl[:]}

// Newlines in [lo, hi) of one buffer.
@(private = "file")
count_nl :: proc(nl: []int, lo, hi: int) -> int {
	a, _ := slice.binary_search(nl, lo)
	z, _ := slice.binary_search(nl, hi)
	return z - a
}

@(private = "file")
ensure_prefix :: proc(b: ^Text_Buffer) {
	n := len(b.pieces)
	if b.prefix_ok >= n && len(b.pre_len) == n do return
	resize(&b.pre_len, n)
	resize(&b.pre_nl, n)
	i := min(b.prefix_ok, n)
	l, k := 0, 0
	if i > 0 {
		l = b.pre_len[i - 1] + b.pieces[i - 1].len
		k = b.pre_nl[i - 1] + b.pieces[i - 1].nl
	}
	for ; i < n; i += 1 {
		b.pre_len[i], b.pre_nl[i] = l, k
		l += b.pieces[i].len
		k += b.pieces[i].nl
	}
	b.prefix_ok = n
}

@(private = "file")
invalidate :: proc(b: ^Text_Buffer, from: int) {b.prefix_ok = min(b.prefix_ok, max(from, 0))}

// The piece holding byte off and the offset inside it. off == length gives
// (len(pieces), 0).
@(private = "file")
find_piece :: proc(b: ^Text_Buffer, off: int) -> (i, inner: int) {
	ensure_prefix(b)
	if off >= b.length do return len(b.pieces), 0
	// last piece whose start <= off
	lo, hi := 0, len(b.pieces) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if b.pre_len[mid] <= off do lo = mid
		else do hi = mid - 1
	}
	return lo, off - b.pre_len[lo]
}

// Splits the piece at off so that a piece boundary lies there; returns the
// index of the piece starting at off (len(pieces) at the end).
@(private = "file")
split_at :: proc(b: ^Text_Buffer, off: int) -> int {
	i, inner := find_piece(b, off)
	if i >= len(b.pieces) || inner == 0 do return i
	p := b.pieces[i]
	nl := nl_of(b, p.add)
	left := Piece{add = p.add, start = p.start, len = inner, nl = count_nl(nl, p.start, p.start + inner)}
	right := Piece{add = p.add, start = p.start + inner, len = p.len - inner, nl = p.nl - left.nl}
	b.pieces[i] = left
	inject_at(&b.pieces, i + 1, right)
	invalidate(b, i)
	return i + 1
}

tb_insert :: proc(b: ^Text_Buffer, off: int, text: string) {
	if len(text) == 0 do return
	at := clamp(off, 0, b.length)
	start := len(b.add)
	append(&b.add, text)
	before := len(b.add_nl)
	scan_newlines(&b.add_nl, transmute([]u8)text, start)
	nl := len(b.add_nl) - before
	defer {
		b.length += len(text)
		b.newlines += nl
	}
	// typing: extend the add piece that ends right here
	if at > 0 {
		i, inner := find_piece(b, at - 1)
		if i < len(b.pieces) {
			p := &b.pieces[i]
			if p.add && inner == p.len - 1 && p.start + p.len == start {
				p.len += len(text)
				p.nl += nl
				invalidate(b, i + 1)
				return
			}
		}
	}
	i := split_at(b, at)
	inject_at(&b.pieces, i, Piece{add = true, start = start, len = len(text), nl = nl})
	invalidate(b, i)
}

tb_delete :: proc(b: ^Text_Buffer, off, n: int) {
	lo := clamp(off, 0, b.length)
	hi := clamp(off + n, lo, b.length)
	if hi == lo do return
	first := split_at(b, lo)
	last := split_at(b, hi) // index of the piece starting at hi
	removed_nl := 0
	for p in b.pieces[first:last] do removed_nl += p.nl
	remove_range(&b.pieces, first, last)
	b.length -= hi - lo
	b.newlines -= removed_nl
	invalidate(b, first)
}

// Byte at off (0 past the end).
tb_byte :: proc(b: ^Text_Buffer, off: int) -> u8 {
	if off < 0 || off >= b.length do return 0
	i, inner := find_piece(b, off)
	p := b.pieces[i]
	return p.add ? b.add[p.start + inner] : b.orig[p.start + inner]
}

// The rest of the piece holding off: a zero-copy chunk (tree-sitter's
// reader, search). Empty at the end.
tb_chunk :: proc(b: ^Text_Buffer, off: int) -> []u8 {
	i, inner := find_piece(b, off)
	if i >= len(b.pieces) do return nil
	return piece_bytes(b, b.pieces[i])[inner:]
}

// Bytes [off, off+n): a slice into a buffer when inside one piece, else a
// copy into scratch (reused: valid until the next call with it).
tb_slice :: proc(b: ^Text_Buffer, off, n: int, scratch: ^[dynamic]u8) -> string {
	lo := clamp(off, 0, b.length)
	hi := clamp(off + n, lo, b.length)
	if hi == lo do return ""
	c := tb_chunk(b, lo)
	if len(c) >= hi - lo do return string(c[:hi - lo])
	clear(scratch)
	at := lo
	for at < hi {
		c = tb_chunk(b, at)
		k := min(len(c), hi - at)
		append(scratch, ..c[:k])
		at += k
	}
	return string(scratch[:])
}

// A copy of [off, off+n).
tb_copy :: proc(b: ^Text_Buffer, off, n: int, allocator := context.allocator) -> string {
	lo := clamp(off, 0, b.length)
	hi := clamp(off + n, lo, b.length)
	out := make([]u8, hi - lo, allocator)
	at := lo
	for at < hi {
		c := tb_chunk(b, at)
		k := min(len(c), hi - at)
		copy(out[at - lo:], c[:k])
		at += k
	}
	return string(out)
}

tb_text :: proc(b: ^Text_Buffer, allocator := context.allocator) -> string {return tb_copy(b, 0, b.length, allocator)}

// Offset of the first byte of line (0-based); length past the last line.
tb_line_start :: proc(b: ^Text_Buffer, line: int) -> int {
	if line <= 0 do return 0
	if line > b.newlines do return b.length
	ensure_prefix(b)
	k := line // the k-th newline (1-based) ends the line before
	lo, hi := 0, len(b.pieces) - 1
	for lo < hi { 	// first piece with pre_nl + nl >= k
		mid := (lo + hi) / 2
		if b.pre_nl[mid] + b.pieces[mid].nl >= k do hi = mid
		else do lo = mid + 1
	}
	p := b.pieces[lo]
	nl := nl_of(b, p.add)
	first, _ := slice.binary_search(nl, p.start)
	pos := nl[first + (k - b.pre_nl[lo]) - 1]
	return b.pre_len[lo] + (pos - p.start) + 1
}

// End of a line's text: before its '\n' (and a '\r' before that).
tb_line_end :: proc(b: ^Text_Buffer, line: int) -> int {
	if line >= b.newlines do return b.length
	e := tb_line_start(b, line + 1) - 1
	if e > 0 && tb_byte(b, e - 1) == '\r' && e - 1 >= tb_line_start(b, line) do e -= 1
	return e
}

// The line holding byte off.
tb_line_of :: proc(b: ^Text_Buffer, off: int) -> int {
	if off <= 0 do return 0
	if off >= b.length do return b.newlines
	i, inner := find_piece(b, off)
	p := b.pieces[i]
	return b.pre_nl[i] + count_nl(nl_of(b, p.add), p.start, p.start + inner)
}

// A line's text without its ending (slice or scratch copy, as tb_slice).
tb_line :: proc(b: ^Text_Buffer, line: int, scratch: ^[dynamic]u8) -> string {
	s := tb_line_start(b, line)
	return tb_slice(b, s, tb_line_end(b, line) - s, scratch)
}

// Finds needle at or after `from` (exact bytes); -1 if none. Works across
// piece boundaries.
tb_find :: proc(b: ^Text_Buffer, needle: string, from: int, scratch: ^[dynamic]u8) -> int {
	if len(needle) == 0 || from >= b.length do return -1
	// windows of one piece plus enough of the next to catch a match that spans them
	at := max(from, 0)
	for at < b.length {
		c := tb_chunk(b, at)
		want := len(c) + len(needle) - 1
		w := tb_slice(b, at, want, scratch)
		if i := strings.index(w, needle); i >= 0 do return at + i
		at += len(c)
	}
	return -1
}

tb_equal :: proc(b: ^Text_Buffer, s: string) -> bool {
	if len(s) != b.length do return false
	at := 0
	for at < b.length {
		c := tb_chunk(b, at)
		if string(c) != s[at:][:len(c)] do return false
		at += len(c)
	}
	return true
}
