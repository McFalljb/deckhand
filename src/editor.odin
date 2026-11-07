package main

// Editor tabs: one Editor per open file, keyed by tab id (runtime, like
// terminals; State holds the tab and its path). This file is the editing
// model: cursor and selection, edits through one primitive (ed_replace) that
// feeds undo, the syntax tree and the git gutter, and the moves the keys
// and mouse use. No window calls: editor_view.odin turns input into these
// and draws; editor_file.odin loads, saves and follows the file on disk.
//
// Positions are byte offsets on UTF-8 boundaries. A '\r\n' line end is one
// step for the cursor. Agents see lines and columns 1-based, columns in
// characters (code points).

import "core:strings"
import "core:time"
import "core:unicode"
import "core:unicode/utf8"

Edit_Kind :: enum u8 {
	Other, // paste, cut, indent, reload: never merged
	Typing,
	Delete_Back,
	Delete_Fwd,
}

Edit_Op :: struct {
	at:       int,
	removed:  string, // owned
	inserted: string, // owned
}

Undo_Group :: struct {
	id:     u64,
	kind:   Edit_Kind,
	ops:    [dynamic]Edit_Op,
	before: [2]int, // anchor, cursor
	after:  [2]int,
	last:   time.Tick,
}

UNDO_MAX :: 1000 // groups kept

// What a tab shows: the file, or a read-only diff of it.
Editor_View :: enum u8 {
	File,
	Diff_Disk, // buffer vs the file on disk ("Compare" on the changed-on-disk banner)
	Diff_Head, // buffer vs git HEAD
	Changes, // a Changes tab's diff (changes.odin)
}

Editor :: struct {
	tab_id:      u64,
	path:        string, // absolute (owned)
	view:        Editor_View,
	buf:         Text_Buffer,
	cursor:      int,
	anchor:      int, // == cursor: no selection
	goal_col:    int, // display column kept by up/down (-1 = none)
	// mouse: unit of the press (1 char, 2 word, 3 line) and what it selected
	unit:        int,
	unit_lo:     int,
	unit_hi:     int,
	dragging:    bool,
	// undo
	undo:        [dynamic]Undo_Group,
	redo:        [dynamic]Undo_Group,
	next_group:  u64,
	saved_group: u64, // top undo group id when the buffer matched the file
	break_group: bool, // the next edit starts a new undo group
	gen:         u64, // bumped by every change of the text
	// file format, detected at load and kept on save
	eol:         string, // "\n" or "\r\n" for new lines
	indent_tabs: bool,
	indent_w:    int, // spaces per indent level (tab files: EDITOR_TAB_WIDTH)
	readonly:    bool,
	always_readonly: bool, // never editable (a Markdown tab's source): editor_reopen keeps readonly
	refused:     string, // not shown: why (binary, too large, unreadable)
	// the file on disk (editor_file.odin)
	disk:        Disk_Stamp,
	disk_hash:   u64, // hash of the text on disk, as last read or written
	disk_text:   string, // the disk version while the banner shows (Compare)
	disk_refused: string, // the changed file cannot be shown (binary, huge, not a file): Reload says why
	disk_changed: bool, // changed on disk while the buffer was dirty: the banner shows
	missing:     bool, // deleted on disk (the buffer is kept)
	sx:          Syntax,
	git:         Git_Gutter,
	// view (editor_view.odin)
	top:         int, // first shown line
	top_sub:     int, // its first shown row (soft wrap)
	frac:        f32, // px of that row scrolled off the top
	scroll_x:    f32, // px (no wrap)
	wrap:        bool,
	follow:      bool, // scroll so the cursor is visible at the next draw
	view_rows:   int, // text rows that fit (last draw)
	area:        Layout_Metrics, // where it was last drawn (mouse hits; editor_view.odin)
	area_drawn:  bool, // area is set
	find:        Find,
	bar:         Editor_Bar,
	last_edit:   time.Tick,
	notice:      string, // shown in the status line (a failed save); owned
	scratch:     [dynamic]u8,
	scratch_draw: [dynamic]u8,
	breaks:      [dynamic]int, // soft-wrap row starts of one line (drawing)
	scratch2:    [dynamic]u8,
}

editors: map[u64]^Editor

editor_of :: proc(tab_id: u64) -> ^Editor {return editors[tab_id] or_else nil}

// The current tab's editor (nil for other tabs).
tab_editor :: proc() -> ^Editor {
	if tab := active_tab(); tab != nil do return editor_of(tab.id)
	return nil
}

// The editor on screen (the current tab's); the agent's drawer may slide
// over part of it, but the tab stays shown.
active_editor :: proc() -> ^Editor {
	return tab_editor()
}

editor_dirty :: proc(e: ^Editor) -> bool {
	if e == nil || e.view != .File do return false
	return top_group(e) != e.saved_group
}

@(private = "file")
top_group :: proc(e: ^Editor) -> u64 {return len(e.undo) > 0 ? e.undo[len(e.undo) - 1].id : 0}

editor_free :: proc(e: ^Editor) {
	tb_destroy(&e.buf)
	syntax_close(&e.sx)
	clear_groups(&e.undo)
	clear_groups(&e.redo)
	delete(e.undo)
	delete(e.redo)
	delete(e.path)
	delete(e.refused)
	delete(e.disk_text)
	delete(e.disk_refused)
	delete(e.scratch)
	delete(e.scratch2)
	delete(e.scratch_draw)
	delete(e.breaks)
	delete(e.notice)
	git_gutter_free(&e.git)
	find_free(&e.find)
	free(e)
}

@(private = "file")
group_free :: proc(g: ^Undo_Group) {
	for op in g.ops {
		delete(op.removed)
		delete(op.inserted)
	}
	delete(g.ops)
}

@(private = "file")
clear_groups :: proc(list: ^[dynamic]Undo_Group) {
	for &g in list do group_free(&g)
	clear(list)
}

// ---- positions ----

ed_line_of :: proc(e: ^Editor, off: int) -> int {return tb_line_of(&e.buf, off)}

// (line, byte column) of off, 0-based: tree-sitter points.
ed_point :: proc(e: ^Editor, off: int) -> [2]int {
	l := tb_line_of(&e.buf, off)
	return {l, off - tb_line_start(&e.buf, l)}
}

// 1-based line and character column of off (agents, the status line).
ed_line_col :: proc(e: ^Editor, off: int) -> (line, col: int) {
	l := tb_line_of(&e.buf, off)
	s := tb_line_start(&e.buf, l)
	return l + 1, strings.rune_count(tb_slice(&e.buf, s, off - s, &e.scratch)) + 1
}

// The offset of a 1-based line and character column (clamped).
ed_offset_of :: proc(e: ^Editor, line, col: int) -> int {
	l := clamp(line - 1, 0, tb_line_count(&e.buf) - 1)
	s := tb_line_start(&e.buf, l)
	text := tb_line(&e.buf, l, &e.scratch)
	n := 0
	for _, i in text {
		if n >= col - 1 do return s + i
		n += 1
	}
	return s + len(text)
}

ed_selection :: proc(e: ^Editor) -> (lo, hi: int) {return min(e.cursor, e.anchor), max(e.cursor, e.anchor)}

ed_selected_text :: proc(e: ^Editor, allocator := context.temp_allocator) -> string {
	lo, hi := ed_selection(e)
	return tb_copy(&e.buf, lo, hi - lo, allocator)
}

// Display columns of a character: tabs are handled by the caller; wide
// (East Asian, emoji) 2, combining marks and joiners 0.
rune_cols :: proc(r: rune) -> int {
	switch {
	case r < 0x300:                                        return 1
	case r >= 0x300 && r <= 0x36f, r >= 0x1ab0 && r <= 0x1aff, r >= 0x1dc0 && r <= 0x1dff, r >= 0x20d0 && r <= 0x20ff, r >= 0xfe20 && r <= 0xfe2f, r == 0x200d, r >= 0xfe00 && r <= 0xfe0f, r >= 0xe0100 && r <= 0xe01ef:
		return 0
	case r >= 0x1100 && r <= 0x115f, r >= 0x2e80 && r <= 0xa4cf, r >= 0xac00 && r <= 0xd7a3, r >= 0xf900 && r <= 0xfaff, r >= 0xfe30 && r <= 0xfe4f, r >= 0xff00 && r <= 0xff60, r >= 0xffe0 && r <= 0xffe6, r >= 0x1f300 && r <= 0x1f64f, r >= 0x1f900 && r <= 0x1f9ff, r >= 0x20000 && r <= 0x3fffd:
		return 2
	}
	return 1
}

// Display column of byte offset `at` in a line's text (tabs to the next stop).
disp_col :: proc(line: string, at: int) -> int {
	col := 0
	for r, i in line {
		if i >= at do break
		col = r == '\t' ? (col / EDITOR_TAB_WIDTH + 1) * EDITOR_TAB_WIDTH : col + rune_cols(r)
	}
	return col
}

// Byte offset in a line's text nearest to display column `want` (a click,
// up/down): the boundary whose column is closest, left on ties.
byte_at_col :: proc(line: string, want: int) -> int {
	col := 0
	for r, i in line {
		next := r == '\t' ? (col / EDITOR_TAB_WIDTH + 1) * EDITOR_TAB_WIDTH : col + rune_cols(r)
		if next > want do return want - col <= next - want ? i : i + utf8.rune_size(r)
		col = next
	}
	return len(line)
}

// The next cursor stop after off: one character with its combining marks;
// '\r\n' is one step.
ed_next :: proc(e: ^Editor, off: int) -> int {
	if off >= tb_len(&e.buf) do return tb_len(&e.buf)
	if tb_byte(&e.buf, off) == '\r' && tb_byte(&e.buf, off + 1) == '\n' do return off + 2
	i := off
	for {
		s := tb_slice(&e.buf, i, 4, &e.scratch2)
		r, n := utf8.decode_rune(s)
		if n == 0 do return i
		if i > off && rune_cols(r) != 0 do return i
		i += n
		if i >= tb_len(&e.buf) do return i
		if r == '\n' do return i
	}
}

ed_prev :: proc(e: ^Editor, off: int) -> int {
	if off <= 0 do return 0
	if tb_byte(&e.buf, off - 1) == '\n' && off >= 2 && tb_byte(&e.buf, off - 2) == '\r' do return off - 2
	i := off
	for i > 0 {
		lo := max(0, i - 4)
		s := tb_slice(&e.buf, lo, i - lo, &e.scratch2)
		r, n := utf8.decode_last_rune(s)
		if n == 0 do n = 1
		i -= n
		if rune_cols(r) != 0 || r == '\n' do break
	}
	return i
}

// ---- edits ----

// The one way the text changes: replaces [lo, hi) with text, records undo,
// tells the syntax tree. kind decides undo merging.
ed_replace :: proc(e: ^Editor, lo, hi: int, text: string, kind := Edit_Kind.Other) {
	if e.readonly do return
	lo, hi := clamp(lo, 0, tb_len(&e.buf)), clamp(hi, 0, tb_len(&e.buf))
	if lo > hi do lo, hi = hi, lo
	if lo == hi && text == "" do return
	before := [2]int{e.anchor, e.cursor}
	removed := tb_copy(&e.buf, lo, hi - lo)
	apply_raw(e, lo, hi, text)
	e.cursor = lo + len(text)
	e.anchor = e.cursor
	record(e, Edit_Op{at = lo, removed = removed, inserted = strings.clone(text)}, kind, before)
}

// The text change itself, with the syntax edit; no undo, no cursor.
@(private = "file")
apply_raw :: proc(e: ^Editor, lo, hi: int, text: string) {
	sp, op := ed_point(e, lo), ed_point(e, hi)
	tb_delete(&e.buf, lo, hi - lo)
	tb_insert(&e.buf, lo, text)
	np := ed_point(e, lo + len(text))
	syntax_edit(&e.sx, lo, hi, lo + len(text), sp, op, np)
	e.gen += 1
	e.last_edit = time.tick_now()
	e.git.stale = true
	e.follow = true
	app.redraw = true
}

@(private = "file")
record :: proc(e: ^Editor, op: Edit_Op, kind: Edit_Kind, before: [2]int) {
	clear_groups(&e.redo)
	now := time.tick_now()
	if !e.break_group && len(e.undo) > 0 && kind != .Other {
		g := &e.undo[len(e.undo) - 1]
		last := g.ops[len(g.ops) - 1]
		joins := g.kind == kind && time.tick_diff(g.last, now) < EDITOR_UNDO_BURST
		switch kind {
		case .Typing:      joins = joins && op.at == last.at + len(last.inserted) && len(op.removed) == 0 && !strings.contains(op.inserted, "\n")
		case .Delete_Back: joins = joins && op.at + len(op.removed) == last.at && op.inserted == ""
		case .Delete_Fwd:  joins = joins && op.at == last.at && op.inserted == ""
		case .Other:       joins = false
		}
		if joins {
			append(&g.ops, op)
			g.after = {e.anchor, e.cursor}
			g.last = now
			return
		}
	}
	e.break_group = false
	e.next_group += 1
	g := Undo_Group{id = e.next_group, kind = kind, before = before, after = {e.anchor, e.cursor}, last = now}
	append(&g.ops, op)
	append(&e.undo, g)
	if len(e.undo) > UNDO_MAX {
		group_free(&e.undo[0])
		ordered_remove(&e.undo, 0)
	}
}

ed_undo :: proc(e: ^Editor) -> bool {
	if len(e.undo) == 0 || e.readonly do return false
	g := pop(&e.undo)
	#reverse for op in g.ops do apply_raw(e, op.at, op.at + len(op.inserted), op.removed)
	e.anchor, e.cursor = g.before[0], g.before[1]
	append(&e.redo, g)
	e.break_group = true
	return true
}

ed_redo :: proc(e: ^Editor) -> bool {
	if len(e.redo) == 0 || e.readonly do return false
	g := pop(&e.redo)
	for op in g.ops do apply_raw(e, op.at, op.at + len(op.removed), op.inserted)
	e.anchor, e.cursor = g.after[0], g.after[1]
	append(&e.undo, g)
	e.break_group = true
	return true
}

// Forgets undo history (reload of a huge file, a fresh load).
ed_clear_history :: proc(e: ^Editor) {
	clear_groups(&e.undo)
	clear_groups(&e.redo)
	e.saved_group = 0
	e.break_group = true
}

// Line breaks in text become the file's own line ending.
ed_normalize_eol :: proc(e: ^Editor, text: string) -> string {
	if !strings.contains_any(text, "\r\n") do return text
	t, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	t, _ = strings.replace_all(t, "\r", "\n", context.temp_allocator)
	if e.eol != "\n" do t, _ = strings.replace_all(t, "\n", e.eol, context.temp_allocator)
	return t
}

// Typed or pasted text over the selection.
ed_insert :: proc(e: ^Editor, text: string, kind := Edit_Kind.Typing) {
	lo, hi := ed_selection(e)
	k := kind
	if lo != hi do k = .Other
	ed_replace(e, lo, hi, ed_normalize_eol(e, text), k)
	e.goal_col = -1
}

ed_backspace :: proc(e: ^Editor) {
	lo, hi := ed_selection(e)
	if lo != hi {
		ed_replace(e, lo, hi, "", .Other)
		return
	}
	if lo == 0 do return
	from := ed_prev(e, lo)
	// soft tabs: inside leading spaces, back to the previous indent stop
	if !e.indent_tabs {
		l := tb_line_of(&e.buf, lo)
		s := tb_line_start(&e.buf, l)
		head := tb_slice(&e.buf, s, lo - s, &e.scratch)
		if len(head) > 0 && strings.trim_left(head, " ") == "" {
			n := (len(head) - 1) % e.indent_w + 1
			from = lo - n
		}
	}
	ed_replace(e, from, lo, "", .Delete_Back)
	e.goal_col = -1
}

ed_delete_forward :: proc(e: ^Editor) {
	lo, hi := ed_selection(e)
	if lo != hi {
		ed_replace(e, lo, hi, "", .Other)
		return
	}
	ed_replace(e, lo, ed_next(e, lo), "", .Delete_Fwd)
	e.goal_col = -1
}

// Deletes from the cursor to `to` (word or line start/end), or the selection.
ed_delete_to :: proc(e: ^Editor, to: int) {
	lo, hi := ed_selection(e)
	if lo == hi do lo, hi = min(e.cursor, to), max(e.cursor, to)
	ed_replace(e, lo, hi, "", .Other)
	e.goal_col = -1
}

// Enter: a line break plus the current line's indentation, one level more
// after an opening bracket (or ':' in Python and YAML); between a bracket
// pair the closer moves to its own line.
ed_newline :: proc(e: ^Editor) {
	lo, hi := ed_selection(e)
	l := tb_line_of(&e.buf, lo)
	s := tb_line_start(&e.buf, l)
	head := tb_slice(&e.buf, s, lo - s, &e.scratch)
	indent := head[:len(head) - len(strings.trim_left(head, " \t"))]
	indent = strings.clone(indent, context.temp_allocator)
	trimmed := strings.trim_right(head, " \t")
	last := len(trimmed) > 0 ? trimmed[len(trimmed) - 1] : 0
	opens := last == '{' || last == '(' || last == '['
	if last == ':' && e.sx.lang != nil && (e.sx.lang.name == "python" || e.sx.lang.name == "yaml") do opens = true
	next := tb_byte(&e.buf, hi)
	unit := ed_indent_unit(e)
	if opens && ((last == '{' && next == '}') || (last == '(' && next == ')') || (last == '[' && next == ']')) {
		inner := strings.concatenate({e.eol, indent, unit}, context.temp_allocator)
		text := strings.concatenate({inner, e.eol, indent}, context.temp_allocator)
		ed_replace(e, lo, hi, text, .Other)
		e.cursor = lo + len(inner)
		e.anchor = e.cursor
	} else {
		ed_replace(e, lo, hi, strings.concatenate({e.eol, indent, opens ? unit : ""}, context.temp_allocator), .Other)
	}
	e.goal_col = -1
}

ed_indent_unit :: proc(e: ^Editor) -> string {
	if e.indent_tabs do return "\t"
	return strings.repeat(" ", e.indent_w, context.temp_allocator)
}

// The lines a line-wise command (indent, comment) applies to: the
// selection's lines, not counting a last line the selection only touches at
// its start.
ed_selected_lines :: proc(e: ^Editor) -> (first, last: int) {
	lo, hi := ed_selection(e)
	first = tb_line_of(&e.buf, lo)
	last = tb_line_of(&e.buf, hi)
	if last > first && tb_line_start(&e.buf, last) == hi do last -= 1
	return
}

// Replaces whole lines [first, last] with new text, keeping the selection
// on the same characters as far as it can (one undo step).
@(private = "file")
replace_lines :: proc(e: ^Editor, first, last: int, lines: []string) {
	s := tb_line_start(&e.buf, first)
	end := tb_line_end(&e.buf, last)
	// keep the old line ends: join with the file's ending, the last line's own stays
	text := strings.join(lines, e.eol, context.temp_allocator)
	a, c := e.anchor, e.cursor
	al, ac := ed_line_of(e, a), a - tb_line_start(&e.buf, ed_line_of(e, a))
	cl, ccol := ed_line_of(e, c), c - tb_line_start(&e.buf, ed_line_of(e, c))
	old_lens := make([]int, last - first + 1, context.temp_allocator)
	for i in first ..= last do old_lens[i - first] = tb_line_end(&e.buf, i) - tb_line_start(&e.buf, i)
	ed_replace(e, s, end, text, .Other)
	moved := len(text) - (end - s) // what a position after the lines moves by
	// map (line, col) through the change: the column shifts with the line's change at its start
	remap :: proc(e: ^Editor, line, col, first: int, old_lens: []int, lines: []string) -> int {
		if line < first || line - first >= len(lines) do return -1
		i := line - first
		delta := len(lines[i]) - old_lens[i]
		return tb_line_start(&e.buf, line) + clamp(col + delta, 0, len(lines[i]))
	}
	if na := remap(e, al, ac, first, old_lens, lines); na >= 0 do e.anchor = na
	else if a > end do e.anchor = a + moved // after the lines (Select all's end): moves with the text
	if nc := remap(e, cl, ccol, first, old_lens, lines); nc >= 0 do e.cursor = nc
	else if c > end do e.cursor = c + moved
	// a selection that started at a line start keeps starting there
	if ac == 0 && al >= first do e.anchor = tb_line_start(&e.buf, al)
	e.goal_col = -1
}

// Tab with a multi-line selection (or shift: always) indents/outdents lines.
ed_indent_lines :: proc(e: ^Editor, outdent: bool) {
	first, last := ed_selected_lines(e)
	lines := make([]string, last - first + 1, context.temp_allocator)
	unit := ed_indent_unit(e)
	for i in first ..= last {
		t := strings.clone(tb_line(&e.buf, i, &e.scratch), context.temp_allocator)
		if outdent {
			switch {
			case strings.has_prefix(t, "\t"): t = t[1:]
			case:
				n := 0
				for n < len(t) && n < e.indent_w && t[n] == ' ' do n += 1
				t = t[n:]
			}
		} else if t != "" {
			t = strings.concatenate({unit, t}, context.temp_allocator)
		}
		lines[i - first] = t
	}
	replace_lines(e, first, last, lines)
}

// Tab: indents the selected lines, or inserts one indent at the cursor
// (spaces up to the next stop in space-indented files).
ed_tab :: proc(e: ^Editor) {
	lo, hi := ed_selection(e)
	if lo != hi && tb_line_of(&e.buf, lo) != tb_line_of(&e.buf, hi) {
		ed_indent_lines(e, false)
		return
	}
	if e.indent_tabs {
		ed_insert(e, "\t", .Other)
		return
	}
	l := tb_line_of(&e.buf, lo)
	col := disp_col(tb_line(&e.buf, l, &e.scratch), lo - tb_line_start(&e.buf, l))
	n := e.indent_w - col % e.indent_w
	ed_insert(e, strings.repeat(" ", n, context.temp_allocator), .Other)
}

// ⌘/: comments out the selected lines with the language's line comment, or
// uncomments them when every non-blank line already has it.
ed_toggle_comment :: proc(e: ^Editor) -> bool {
	lang := e.sx.lang
	if lang == nil do return false
	first, last := ed_selected_lines(e)
	lines := make([]string, last - first + 1, context.temp_allocator)
	for i in first ..= last do lines[i - first] = strings.clone(tb_line(&e.buf, i, &e.scratch), context.temp_allocator)
	if lang.comment == "" {
		// block comment around the lines (markdown)
		open, close := lang.block[0], lang.block[1]
		all := strings.has_prefix(strings.trim_left(lines[0], " \t"), strings.trim_space(open)) && strings.has_suffix(strings.trim_right(lines[len(lines) - 1], " \t"), strings.trim_space(close))
		if all {
			l0 := lines[0]
			i := strings.index(l0, strings.trim_space(open))
			rest := l0[i + len(strings.trim_space(open)):]
			lines[0] = strings.concatenate({l0[:i], strings.trim_prefix(rest, " ")}, context.temp_allocator)
			ln := lines[len(lines) - 1]
			j := strings.last_index(ln, strings.trim_space(close))
			lines[len(lines) - 1] = strings.trim_right(ln[:j], " ")
		} else {
			lines[0] = strings.concatenate({open, lines[0]}, context.temp_allocator)
			lines[len(lines) - 1] = strings.concatenate({lines[len(lines) - 1], close}, context.temp_allocator)
		}
		replace_lines(e, first, last, lines)
		return true
	}
	tok := lang.comment
	min_indent := max(int)
	all := true
	for t in lines {
		body := strings.trim_left(t, " \t")
		if body == "" do continue
		min_indent = min(min_indent, len(t) - len(body))
		if !strings.has_prefix(body, tok) do all = false
	}
	if min_indent == max(int) do return false // only blank lines
	for &t in lines {
		body := strings.trim_left(t, " \t")
		if body == "" do continue
		ind := len(t) - len(body)
		if all {
			rest := body[len(tok):]
			if strings.has_prefix(rest, " ") do rest = rest[1:]
			t = strings.concatenate({t[:ind], rest}, context.temp_allocator)
		} else {
			t = strings.concatenate({t[:min_indent], tok, " ", t[min_indent:]}, context.temp_allocator)
		}
	}
	replace_lines(e, first, last, lines)
	return true
}

// ---- moves ----

ed_set_cursor :: proc(e: ^Editor, off: int, extend: bool) {
	e.cursor = clamp(off, 0, tb_len(&e.buf))
	if !extend do e.anchor = e.cursor
	e.follow = true
	e.break_group = true
	app.redraw = true
}

// ← → (collapse a selection to its edge first, as text fields do).
ed_move_char :: proc(e: ^Editor, dir: int, extend: bool) {
	lo, hi := ed_selection(e)
	e.goal_col = -1
	if !extend && lo != hi {
		ed_set_cursor(e, dir < 0 ? lo : hi, false)
		return
	}
	ed_set_cursor(e, dir < 0 ? ed_prev(e, e.cursor) : ed_next(e, e.cursor), extend)
}

// ⌥← ⌥→: word starts/ends within the line, then across line ends.
ed_move_word :: proc(e: ^Editor, dir: int, extend: bool) {
	e.goal_col = -1
	ed_set_cursor(e, ed_word_from(e, e.cursor, dir), extend)
}

ed_word_from :: proc(e: ^Editor, off, dir: int) -> int {
	l := tb_line_of(&e.buf, off)
	s := tb_line_start(&e.buf, l)
	text := tb_line(&e.buf, l, &e.scratch)
	at := off - s
	if dir < 0 {
		if at == 0 do return l > 0 ? tb_line_end(&e.buf, l - 1) : 0
		return s + word_left(text, at)
	}
	if at >= len(text) do return l + 1 < tb_line_count(&e.buf) ? tb_line_start(&e.buf, l + 1) : tb_len(&e.buf)
	return s + word_right(text, at)
}

// ⌘← / Home: the first non-blank character, then the line start.
ed_line_home :: proc(e: ^Editor, extend: bool) {
	l := tb_line_of(&e.buf, e.cursor)
	s := tb_line_start(&e.buf, l)
	text := tb_line(&e.buf, l, &e.scratch)
	first := s + len(text) - len(strings.trim_left(text, " \t"))
	e.goal_col = -1
	ed_set_cursor(e, e.cursor == first ? s : first, extend)
}

ed_line_end_move :: proc(e: ^Editor, extend: bool) {
	e.goal_col = -1
	ed_set_cursor(e, tb_line_end(&e.buf, tb_line_of(&e.buf, e.cursor)), extend)
}

// ↑ ↓ PgUp PgDn: by lines, keeping the display column.
ed_move_lines :: proc(e: ^Editor, n: int, extend: bool) {
	lo, hi := ed_selection(e)
	from := e.cursor
	if !extend && lo != hi do from = n < 0 ? lo : hi
	l := tb_line_of(&e.buf, from)
	if e.goal_col < 0 do e.goal_col = disp_col(tb_line(&e.buf, l, &e.scratch), from - tb_line_start(&e.buf, l))
	target := l + n
	if target < 0 {
		ed_set_cursor(e, 0, extend)
		return
	}
	if target >= tb_line_count(&e.buf) {
		ed_set_cursor(e, tb_len(&e.buf), extend)
		return
	}
	text := tb_line(&e.buf, target, &e.scratch)
	ed_set_cursor(e, tb_line_start(&e.buf, target) + byte_at_col(text, e.goal_col), extend)
}

ed_select_all :: proc(e: ^Editor) {
	e.anchor, e.cursor = 0, tb_len(&e.buf)
	e.break_group = true
	app.redraw = true
}

// The word (or run of separators) around off, within its line.
ed_word_at :: proc(e: ^Editor, off: int) -> (lo, hi: int) {
	l := tb_line_of(&e.buf, off)
	s := tb_line_start(&e.buf, l)
	a, b := word_at(tb_line(&e.buf, l, &e.scratch), off - s)
	return s + a, s + b
}

// The line around off, with its line ending.
ed_line_at :: proc(e: ^Editor, off: int) -> (lo, hi: int) {
	l := tb_line_of(&e.buf, off)
	return tb_line_start(&e.buf, l), l + 1 < tb_line_count(&e.buf) ? tb_line_start(&e.buf, l + 1) : tb_len(&e.buf)
}

// A press at off: 1 places the caret (extend: Shift), 2 selects the word, 3 the line.
ed_click :: proc(e: ^Editor, off, clicks: int, extend: bool) {
	o := clamp(off, 0, tb_len(&e.buf))
	e.unit = clamp(clicks, 1, 3)
	e.goal_col = -1
	e.break_group = true
	switch e.unit {
	case 1:
		e.cursor = o
		if !extend do e.anchor = o
		e.unit_lo, e.unit_hi = e.anchor, e.anchor
	case 2:
		e.unit_lo, e.unit_hi = ed_word_at(e, o)
		e.anchor, e.cursor = e.unit_lo, e.unit_hi
	case 3:
		e.unit_lo, e.unit_hi = ed_line_at(e, o)
		e.anchor, e.cursor = e.unit_lo, e.unit_hi
	}
	app.redraw = true
}

// The pointer dragged to off: grow by the press's unit.
ed_drag :: proc(e: ^Editor, off: int) {
	o := clamp(off, 0, tb_len(&e.buf))
	switch e.unit {
	case 1:
		e.cursor = o
	case 2, 3:
		lo, hi: int
		if e.unit == 2 do lo, hi = ed_word_at(e, o)
		else do lo, hi = ed_line_at(e, o)
		if o < e.unit_lo do e.anchor, e.cursor = e.unit_hi, lo
		else do e.anchor, e.cursor = e.unit_lo, max(hi, e.unit_hi)
	}
	e.follow = true
	app.redraw = true
}

// Copy with no selection copies the whole line (with its ending).
ed_copy_range :: proc(e: ^Editor) -> (lo, hi: int) {
	lo, hi = ed_selection(e)
	if lo == hi do lo, hi = ed_line_at(e, e.cursor)
	return
}

// Goes to a 1-based line and column and shows it.
ed_goto :: proc(e: ^Editor, line, col: int) {
	ed_set_cursor(e, ed_offset_of(e, line, max(col, 1)), false)
	e.goal_col = -1
}

is_space_rune :: proc(r: rune) -> bool {return unicode.is_space(r)}

// Open files with unsaved changes (quit asks).
editors_unsaved :: proc() -> int {
	n := 0
	for _, e in editors do if editor_dirty(e) do n += 1
	return n
}
