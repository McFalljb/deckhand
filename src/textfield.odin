package main

// A single-line text field: an edit buffer with a cursor and a selection
// (anchor..cursor, byte offsets on rune boundaries). Plain data and procs, no
// window calls: main.odin routes keys here when State.focus_widget names the
// field, ui.odin draws it. The buffer is UI state, like a terminal's screen;
// committing it is a command (e.g. Rename_Project).

import "core:strings"
import "core:unicode/utf8"
import "core"

Text_Field :: struct {
	multiline: bool, // keeps line breaks (the agent's message field)
	buf:    [dynamic]u8,
	cursor: int,
	anchor: int, // == cursor: no selection
	// mouse: what a drag extends by (1 char, 2 word, 3 all) and the
	// word or text the press selected
	unit:   int,
	unit_lo, unit_hi: int,
}

tf_text :: proc(f: ^Text_Field) -> string {return string(f.buf[:])}

tf_set :: proc(f: ^Text_Field, s: string) {
	clear(&f.buf)
	f.cursor, f.anchor = 0, 0
	tf_insert(f, s)
	f.anchor = 0 // whole text selected: typing replaces it
}

tf_selection :: proc(f: ^Text_Field) -> (lo, hi: int) {
	return min(f.cursor, f.anchor), max(f.cursor, f.anchor)
}

tf_selected_text :: proc(f: ^Text_Field) -> string {
	lo, hi := tf_selection(f)
	return string(f.buf[lo:hi])
}

@(private = "file")
delete_selection :: proc(f: ^Text_Field) -> bool {
	lo, hi := tf_selection(f)
	if lo == hi do return false
	remove_range(&f.buf, lo, hi)
	f.cursor, f.anchor = lo, lo
	return true
}

// Inserts s at the cursor, replacing the selection. Control characters are
// dropped, line breaks too unless the field is multi-line (tabs become a
// space there).
tf_insert :: proc(f: ^Text_Field, s: string) {
	delete_selection(f)
	for c in s {
		r := c
		if f.multiline && r == '\t' do r = ' '
		if f.multiline && r == '\r' do continue
		if (r < 0x20 && !(f.multiline && r == '\n')) || r == 0x7f || r == utf8.RUNE_ERROR do continue
		b, n := utf8.encode_rune(r)
		inject_at(&f.buf, f.cursor, ..b[:n])
		f.cursor += n
	}
	f.anchor = f.cursor
}

tf_backspace :: proc(f: ^Text_Field) {
	if delete_selection(f) || f.cursor == 0 do return
	_, n := utf8.decode_last_rune(f.buf[:f.cursor])
	remove_range(&f.buf, f.cursor - n, f.cursor)
	f.cursor -= n
	f.anchor = f.cursor
}

tf_delete :: proc(f: ^Text_Field) {
	if delete_selection(f) || f.cursor >= len(f.buf) do return
	_, n := utf8.decode_rune(f.buf[f.cursor:])
	remove_range(&f.buf, f.cursor, f.cursor + n)
}

// Moves one rune left (dir < 0) or right; extend keeps the anchor (Shift).
// Without extend, an existing selection collapses to its edge.
tf_move :: proc(f: ^Text_Field, dir: int, extend: bool) {
	lo, hi := tf_selection(f)
	if !extend && lo != hi {
		f.cursor = dir < 0 ? lo : hi
		f.anchor = f.cursor
		return
	}
	if dir < 0 && f.cursor > 0 {
		_, n := utf8.decode_last_rune(f.buf[:f.cursor])
		f.cursor -= n
	} else if dir > 0 && f.cursor < len(f.buf) {
		_, n := utf8.decode_rune(f.buf[f.cursor:])
		f.cursor += n
	}
	if !extend do f.anchor = f.cursor
}

tf_home :: proc(f: ^Text_Field, extend: bool) {
	f.cursor = 0
	if !extend do f.anchor = 0
}

tf_end :: proc(f: ^Text_Field, extend: bool) {
	f.cursor = len(f.buf)
	if !extend do f.anchor = f.cursor
}

tf_select_all :: proc(f: ^Text_Field) {
	f.anchor, f.cursor = 0, len(f.buf)
}

// ---- words (⌥ arrows, ⌥⌫, double-click) ----

// Start of the word at or before off (skips separators first), as ⌥← does.
word_left :: proc(s: string, off: int) -> int {
	i := off
	for i > 0 {
		r, n := utf8.decode_last_rune(s[:i])
		if core.is_word_rune(r) do break
		i -= n
	}
	for i > 0 {
		r, n := utf8.decode_last_rune(s[:i])
		if !core.is_word_rune(r) do break
		i -= n
	}
	return i
}

// End of the word at or after off (skips separators first), as ⌥→ does.
word_right :: proc(s: string, off: int) -> int {
	i := off
	for i < len(s) {
		r, n := utf8.decode_rune(s[i:])
		if core.is_word_rune(r) do break
		i += n
	}
	for i < len(s) {
		r, n := utf8.decode_rune(s[i:])
		if !core.is_word_rune(r) do break
		i += n
	}
	return i
}

// The word (or run of separators) a double-click at off selects.
word_at :: proc(s: string, off: int) -> (lo, hi: int) {
	if len(s) == 0 do return 0, 0
	at := min(off, len(s))
	if at == len(s) {
		_, n := utf8.decode_last_rune(s)
		at -= n
	}
	r0, _ := utf8.decode_rune(s[at:])
	word := core.is_word_rune(r0)
	lo, hi = at, at
	for lo > 0 {
		r, n := utf8.decode_last_rune(s[:lo])
		if core.is_word_rune(r) != word do break
		lo -= n
	}
	for hi < len(s) {
		r, n := utf8.decode_rune(s[hi:])
		if core.is_word_rune(r) != word do break
		hi += n
	}
	return
}

tf_word_left :: proc(f: ^Text_Field, extend: bool) {
	lo, hi := tf_selection(f)
	f.cursor = word_left(tf_text(f), !extend && lo != hi ? lo : f.cursor)
	if !extend do f.anchor = f.cursor
}

tf_word_right :: proc(f: ^Text_Field, extend: bool) {
	lo, hi := tf_selection(f)
	f.cursor = word_right(tf_text(f), !extend && lo != hi ? hi : f.cursor)
	if !extend do f.anchor = f.cursor
}

// ⌥⌫: deletes back to the start of the word (or the selection).
tf_delete_word_left :: proc(f: ^Text_Field) {
	if f.cursor != f.anchor {
		tf_backspace(f)
		return
	}
	f.anchor = word_left(tf_text(f), f.cursor)
	tf_backspace(f)
}

// ⌘⌫: deletes back to the start of the line (or the selection).
tf_delete_to_start :: proc(f: ^Text_Field) {
	if f.cursor == f.anchor do f.anchor = 0
	tf_backspace(f)
}

// ---- mouse ----

// A press at byte offset off (on a rune boundary). clicks: 1 places the caret
// (extend: Shift keeps the anchor), 2 selects the word, 3 everything.
tf_click :: proc(f: ^Text_Field, off: int, clicks: int, extend: bool) {
	o := clamp(off, 0, len(f.buf))
	f.unit = clamp(clicks, 1, 3)
	switch f.unit {
	case 1:
		f.cursor = o
		if !extend do f.anchor = o
		f.unit_lo, f.unit_hi = f.anchor, f.anchor
	case 2:
		f.unit_lo, f.unit_hi = word_at(tf_text(f), o)
		f.anchor, f.cursor = f.unit_lo, f.unit_hi
	case 3:
		f.unit_lo, f.unit_hi = 0, len(f.buf)
		f.anchor, f.cursor = 0, len(f.buf)
	}
}

// The pointer dragged to byte offset off: the selection grows by the unit of
// the press (characters, words; a triple-click keeps everything).
tf_drag :: proc(f: ^Text_Field, off: int) {
	o := clamp(off, 0, len(f.buf))
	switch f.unit {
	case 1:
		f.cursor = o
	case 2:
		lo, hi := word_at(tf_text(f), o)
		if o < f.unit_lo {
			f.anchor, f.cursor = f.unit_hi, lo
		} else {
			f.anchor, f.cursor = f.unit_lo, max(hi, f.unit_hi)
		}
	}
}

// What a field shows while an input method composes: the composition at the
// cursor (replacing the selection), and where it sits in the shown text.
tf_display :: proc(f: ^Text_Field, marked: string) -> (shown: string, marked_lo, marked_hi: int) {
	if marked == "" do return tf_text(f), f.cursor, f.cursor
	lo, hi := tf_selection(f)
	s := strings.concatenate({string(f.buf[:lo]), marked, string(f.buf[hi:])}, context.temp_allocator)
	return s, lo, lo + len(marked)
}

// Cursor and selection as rune columns, for drawing with a monospace font.
tf_columns :: proc(f: ^Text_Field) -> (cursor, sel_lo, sel_hi: int) {
	lo, hi := tf_selection(f)
	return strings.rune_count(string(f.buf[:f.cursor])), strings.rune_count(string(f.buf[:lo])), strings.rune_count(string(f.buf[:hi]))
}
