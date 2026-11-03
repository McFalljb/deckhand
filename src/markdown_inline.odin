package main

// Markdown inlines (markdown.odin has the overview): code spans, emphasis
// and strong (the delimiter-run algorithm of the CommonMark spec, appendix
// "An algorithm for parsing nested emphasis and links"), links and images
// (inline and reference), autolinks, raw HTML, entities, escapes and line
// breaks; GFM strikethrough (~ and ~~) and extended autolinks (www., http(s)://,
// ftp://, e-mail addresses). Inlines are a tree of linked nodes in the document's
// arena.

import "base:runtime"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Md_Inline_Kind :: enum u8 {
	Root, // a paragraph's, heading's or cell's inlines
	Text,
	Softbreak,
	Linebreak,
	Code,
	Html,
	Emph,
	Strong,
	Strike,
	Link,
	Image,
}

Md_Inline :: struct {
	kind:     Md_Inline_Kind,
	autolink: bool, // a link written as <url> or a bare URL
	text:     string, // Text, Code, Html: the literal
	url:      string, // Link, Image
	title:    string, // Link, Image
	parent:   ^Md_Inline,
	prev:     ^Md_Inline,
	next:     ^Md_Inline,
	first:    ^Md_Inline,
	last:     ^Md_Inline,
}

@(private = "file")
MAX_BACKTICKS :: 1000
@(private = "file")
MAX_LABEL :: 999

@(private = "file")
Delim :: struct {
	prev, next:          ^Delim,
	inl:                 ^Md_Inline,
	length:              int,
	orig:                int,
	c:                   u8,
	can_open, can_close: bool,
	pos:                 int,
}

@(private = "file")
Bracket :: struct {
	prev:          ^Bracket,
	inl:           ^Md_Inline,
	pos:           int, // after the [
	image:         bool,
	bracket_after: bool,
}

@(private = "file")
Inline_Memo :: struct {
	backticks: [MAX_BACKTICKS + 1]int,
	bt_gen:    [MAX_BACKTICKS + 1]u32,
	gen:       u32,
}

@(private = "file")
Subj :: struct {
	s:               string,
	pos:             int,
	doc:             ^Md_Doc,
	alloc:           runtime.Allocator,
	root:            ^Md_Inline,
	last_delim:      ^Delim,
	last_bracket:    ^Bracket,
	no_link_openers: bool,
	memo:            ^Inline_Memo,
	scanned_bt:      bool,
}

// ---- the tree ----

// A walk over inlines without recursion (emphasis can nest thousands deep):
// every node is entered; containers are also exited.
Md_Walk :: struct {
	root:     ^Md_Inline,
	cur:      ^Md_Inline,
	entering: bool,
	started:  bool,
}

md_is_container :: #force_inline proc(n: ^Md_Inline) -> bool {
	#partial switch n.kind {
	case .Root, .Emph, .Strong, .Strike, .Link, .Image:
		return true
	}
	return false
}

md_walk :: proc(root: ^Md_Inline) -> Md_Walk {return Md_Walk{root = root}}

md_walk_next :: proc(w: ^Md_Walk) -> (n: ^Md_Inline, entering: bool, ok: bool) {
	if w.root == nil do return
	if !w.started {
		w.started = true
		w.cur = w.root.first
		w.entering = true
	} else if w.entering && md_is_container(w.cur) {
		if w.cur.first != nil do w.cur = w.cur.first
		else do w.entering = false
	} else if w.cur.next != nil {
		w.cur = w.cur.next
		w.entering = true
	} else {
		w.cur = w.cur.parent
		w.entering = false
		if w.cur == w.root || w.cur == nil do w.cur = nil
	}
	if w.cur == nil do return
	return w.cur, w.entering, true
}

// After entering a container: go straight to its exit (its children unseen).
md_walk_skip :: proc(w: ^Md_Walk) {
	if w.cur != nil && w.entering && md_is_container(w.cur) do w.entering = false
}

md_append :: proc(parent, child: ^Md_Inline) {
	child.parent = parent
	child.next = nil
	child.prev = parent.last
	if parent.last != nil do parent.last.next = child
	else do parent.first = child
	parent.last = child
}

md_unlink :: proc(n: ^Md_Inline) {
	if n.prev != nil do n.prev.next = n.next
	else if n.parent != nil do n.parent.first = n.next
	if n.next != nil do n.next.prev = n.prev
	else if n.parent != nil do n.parent.last = n.prev
	n.prev, n.next, n.parent = nil, nil, nil
}

@(private = "file")
insert_after :: proc(at, n: ^Md_Inline) {
	n.parent = at.parent
	n.prev = at
	n.next = at.next
	if at.next != nil do at.next.prev = n
	else if at.parent != nil do at.parent.last = n
	at.next = n
}

@(private = "file")
insert_before :: proc(at, n: ^Md_Inline) {
	n.parent = at.parent
	n.next = at
	n.prev = at.prev
	if at.prev != nil do at.prev.next = n
	else if at.parent != nil do at.parent.first = n
	at.prev = n
}

@(private = "file")
mk :: proc(sj: ^Subj, kind: Md_Inline_Kind, text := "") -> ^Md_Inline {
	n := new(Md_Inline, sj.alloc)
	n.kind = kind
	n.text = text
	return n
}

// ---- the pass over the document ----

// Parses the inlines of every paragraph, heading and table cell; marks GFM
// task items; gives headings their ids.
md_inlines :: proc(doc: ^Md_Doc) {
	memo := new(Inline_Memo, doc.alloc)
	walk :: proc(doc: ^Md_Doc, b: ^Md_Block, memo: ^Inline_Memo) {
		#partial switch b.kind {
		case .Paragraph, .Heading, .Table_Cell:
			src := b.text
			if b.kind == .Paragraph && b.parent != nil && b.parent.kind == .Item && len(b.parent.children) > 0 && b.parent.children[0] == b {
				// GFM task item: "[ ] " or "[x] " first in the item's first paragraph
				if len(src) >= 4 && src[0] == '[' && (src[1] == ' ' || src[1] == 'x' || src[1] == 'X') && src[2] == ']' && (src[3] == ' ' || src[3] == '\t' || src[3] == '\n') {
					b.parent.task = src[1] == ' ' ? 1 : 2
					src = src[3:]
					for len(src) > 0 && (src[0] == ' ' || src[0] == '\t') do src = src[1:]
				}
			}
			b.inl = parse_inlines(doc, memo, trim_ws_right(src))
			if b.kind == .Heading do heading_anchor(doc, b)
		}
		for c in b.children do walk(doc, c, memo)
	}
	walk(doc, doc.root, memo)
}

// GitHub's heading ids: lower case, spaces to '-', other punctuation
// dropped; repeats get -1, -2, …
@(private = "file")
heading_anchor :: proc(doc: ^Md_Doc, b: ^Md_Block) {
	text := md_plain_text(b.inl, context.temp_allocator)
	sb := strings.builder_make(doc.alloc)
	for r in text {
		if r < 128 {
			c := ascii_lower(u8(r))
			if c == ' ' do strings.write_byte(&sb, '-')
			else if c == '-' || c == '_' || is_ascii_alnum(c) do strings.write_byte(&sb, c)
		} else {
			l := unicode.to_lower(r)
			if unicode.is_letter(l) || unicode.is_digit(l) do strings.write_rune(&sb, l)
		}
	}
	base := strings.to_string(sb)
	id := base
	// repeats: the next free -N (counted per base, so many equal headings stay linear)
	for n := doc.anchor_next[base]; (id in doc.anchors); {
		n += 1
		id = strings.concatenate({base, "-", int_text(n, context.temp_allocator)}, doc.alloc)
		doc.anchor_next[base] = n
	}
	b.anchor = id
	doc.anchors[id] = b
}

int_text :: proc(n: int, alloc: runtime.Allocator) -> string {
	buf: [24]u8
	i := len(buf)
	v := n < 0 ? -n : n
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 do break
	}
	if n < 0 {
		i -= 1
		buf[i] = '-'
	}
	return strings.clone(string(buf[i:]), alloc)
}

// The text of inlines without markup (image alt text, heading ids, find).
md_plain_text :: proc(n: ^Md_Inline, alloc := context.allocator) -> string {
	sb := strings.builder_make(alloc)
	w := md_walk(n)
	for c, entering in md_walk_next(&w) {
		if !entering do continue
		#partial switch c.kind {
		case .Text, .Code, .Html: strings.write_string(&sb, c.text)
		case .Softbreak, .Linebreak: strings.write_byte(&sb, ' ')
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
parse_inlines :: proc(doc: ^Md_Doc, memo: ^Inline_Memo, s: string) -> ^Md_Inline {
	sj := Subj{s = s, doc = doc, alloc = doc.alloc, memo = memo}
	memo.gen += 1
	sj.root = mk(&sj, .Root)
	for sj.pos < len(sj.s) do parse_inline(&sj)
	process_emphasis(&sj, 0)
	for sj.last_bracket != nil do sj.last_bracket = sj.last_bracket.prev
	merge_texts(&sj, sj.root)
	gfm_autolinks(&sj, sj.root)
	return sj.root
}

// Joins neighbouring text nodes (the parser leaves brackets, delimiters
// and escapes as separate ones).
@(private = "file")
merge_texts :: proc(sj: ^Subj, root: ^Md_Inline) {
	w := md_walk(root)
	for c, entering in md_walk_next(&w) {
		if !entering || c.kind != .Text || c.next == nil || c.next.kind != .Text do continue
		total := len(c.text)
		for d := c.next; d != nil && d.kind == .Text; d = d.next do total += len(d.text)
		buf := make([]u8, total, sj.alloc)
		at := copy(buf, c.text)
		for c.next != nil && c.next.kind == .Text {
			d := c.next
			at += copy(buf[at:], d.text)
			md_unlink(d)
		}
		c.text = string(buf)
	}
}

// ---- characters ----

@(private = "file")
peek_c :: #force_inline proc(sj: ^Subj) -> u8 #no_bounds_check {return sj.pos >= 0 && sj.pos < len(sj.s) ? sj.s[sj.pos] : 0}

@(private = "file")
peek_at :: #force_inline proc(sj: ^Subj, at: int) -> u8 #no_bounds_check {return at >= 0 && at < len(sj.s) ? sj.s[at] : 0}

is_ascii_punct :: #force_inline proc(c: u8) -> bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

// The characters that may start something other than plain text.
@(private = "file", rodata)
MD_SPECIAL := [256]bool {
	'\n' = true, '\r' = true, '`' = true, '\\' = true, '&' = true, '<' = true, '*' = true, '_' = true, '[' = true, ']' = true, '!' = true, '~' = true,
}

// The end of plain text from `at`: the next special character.
@(private = "file")
text_run_end :: proc(s: string, at: int) -> int #no_bounds_check {
	i := max(at, 0)
	for i < len(s) && !MD_SPECIAL[s[i]] do i += 1
	return min(i, len(s))
}

// s without trailing spaces, tabs and line endings.
trim_ws_right :: proc(s: string) -> string #no_bounds_check {
	k := len(s)
	for k > 0 && (s[k - 1] == ' ' || s[k - 1] == '\t' || s[k - 1] == '\n' || s[k - 1] == '\r') do k -= 1
	return s[:k]
}

// s without leading and trailing spaces, tabs and line endings.
trim_ws :: proc(s: string) -> string #no_bounds_check {
	t := trim_ws_right(s)
	i := 0
	for i < len(t) && (t[i] == ' ' || t[i] == '\t' || t[i] == '\n' || t[i] == '\r') do i += 1
	return t[i:]
}

// Whether text may hold a GFM autolink: '@', "://" or "www." (any case).
@(private = "file")
may_autolink :: proc(s: string) -> bool #no_bounds_check {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '@':
			return true
		case ':':
			if i + 2 < len(s) && s[i + 1] == '/' && s[i + 2] == '/' do return true
		case '.':
			if i >= 3 && (s[i - 1] | 32) == 'w' && (s[i - 2] | 32) == 'w' && (s[i - 3] | 32) == 'w' do return true
		}
	}
	return false
}

@(private = "file")
skip_spaces :: proc(sj: ^Subj) {
	for sj.pos < len(sj.s) && (sj.s[sj.pos] == ' ' || sj.s[sj.pos] == '\t') do sj.pos += 1
}

// spaces, tabs and line endings
@(private = "file")
spacechars :: proc(s: string, at: int) -> int {
	i := at
	for i < len(s) {
		switch s[i] {
		case ' ', '\t', '\n', '\r', '\v', '\f': i += 1
		case: return i - at
		}
	}
	return i - at
}

@(private = "file")
skip_line_end :: proc(sj: ^Subj) -> bool {
	seen := false
	if peek_c(sj) == '\r' {
		sj.pos += 1
		seen = true
	}
	if peek_c(sj) == '\n' {
		sj.pos += 1
		seen = true
	}
	return seen || sj.pos >= len(sj.s)
}

// spaces, then at most one line ending, then spaces
@(private = "file")
spnl :: proc(sj: ^Subj) {
	skip_spaces(sj)
	if skip_line_end(sj) do skip_spaces(sj)
}

// The rune before byte `at` and the one at it ('\n' at either end).
@(private = "file")
rune_before :: proc(s: string, at: int) -> rune {
	if at <= 0 do return '\n'
	r, _ := utf8.decode_last_rune_in_string(s[:at])
	return r
}

@(private = "file")
rune_at :: proc(s: string, at: int) -> rune {
	if at >= len(s) do return '\n'
	r, _ := utf8.decode_rune_in_string(s[at:])
	return r
}

@(private = "file")
uni_space :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\n', '\f', '\r', ' ': return true
	}
	return r > 127 && unicode.is_space(r)
}

@(private = "file")
uni_punct :: proc(r: rune) -> bool {
	if r < 128 do return is_ascii_punct(u8(r))
	return unicode.is_punct(r) || unicode.is_symbol(r)
}

// ---- one inline ----

@(private = "file")
parse_inline :: proc(sj: ^Subj) {
	c := sj.s[sj.pos]
	n: ^Md_Inline
	switch c {
	case '\n', '\r':
		n = handle_newline(sj)
	case '`':
		n = handle_backticks(sj)
	case '\\':
		n = handle_backslash(sj)
	case '&':
		n = handle_entity(sj)
	case '<':
		n = handle_pointy(sj)
	case '*', '_', '~':
		n = handle_delim(sj, c)
	case '[':
		sj.pos += 1
		n = mk(sj, .Text, "[")
		push_bracket(sj, false, n)
	case ']':
		n = handle_close_bracket(sj)
	case '!':
		sj.pos += 1
		if peek_c(sj) == '[' {
			sj.pos += 1
			n = mk(sj, .Text, "![")
			push_bracket(sj, true, n)
		} else do n = mk(sj, .Text, "!")
	case:
		start := sj.pos
		end := text_run_end(sj.s, start + 1)
		sj.pos = end
		text := sj.s[start:end]
		if end < len(sj.s) && (sj.s[end] == '\n' || sj.s[end] == '\r') {
			k := len(text)
			for k > 0 && (text[k - 1] == ' ' || text[k - 1] == '\t') do k -= 1
			text = text[:k]
		}
		n = mk(sj, .Text, text)
	}
	if n != nil do md_append(sj.root, n)
}

@(private = "file")
handle_newline :: proc(sj: ^Subj) -> ^Md_Inline {
	nl := sj.pos
	if peek_c(sj) == '\r' do sj.pos += 1
	if peek_c(sj) == '\n' do sj.pos += 1
	skip_spaces(sj)
	if nl > 1 && sj.s[nl - 1] == ' ' && sj.s[nl - 2] == ' ' do return mk(sj, .Linebreak)
	return mk(sj, .Softbreak)
}

@(private = "file")
handle_backslash :: proc(sj: ^Subj) -> ^Md_Inline {
	sj.pos += 1
	c := peek_c(sj)
	if is_ascii_punct(c) {
		sj.pos += 1
		return mk(sj, .Text, sj.s[sj.pos - 1:sj.pos])
	}
	if sj.pos < len(sj.s) && skip_line_end(sj) do return mk(sj, .Linebreak)
	return mk(sj, .Text, "\\")
}

@(private = "file")
handle_backticks :: proc(sj: ^Subj) -> ^Md_Inline {
	start := sj.pos
	for peek_c(sj) == '`' do sj.pos += 1
	n := sj.pos - start
	after := sj.pos
	end := closing_backticks(sj, n)
	if end == 0 {
		sj.pos = after
		return mk(sj, .Text, sj.s[start:after])
	}
	raw := sj.s[after:end - n]
	// line endings become spaces; one space each side goes when both have one
	code := raw
	if strings.index_byte(raw, '\n') >= 0 || strings.index_byte(raw, '\r') >= 0 {
		buf := make([dynamic]u8, 0, len(raw), sj.alloc)
		for i := 0; i < len(raw); i += 1 {
			c := raw[i]
			if c == '\r' {
				if i + 1 < len(raw) && raw[i + 1] == '\n' do i += 1
				append(&buf, ' ')
			} else if c == '\n' do append(&buf, ' ')
			else do append(&buf, c)
		}
		code = string(buf[:])
	}
	if len(code) >= 2 && code[0] == ' ' && code[len(code) - 1] == ' ' {
		all := true
		for i in 0 ..< len(code) do if code[i] != ' ' do all = false
		if !all do code = code[1:len(code) - 1]
	}
	return mk(sj, .Code, code)
}

// The end of the closing run of exactly n backticks, 0 if there is none.
@(private = "file")
closing_backticks :: proc(sj: ^Subj, n: int) -> int {
	if n > MAX_BACKTICKS do return 0
	m := sj.memo
	if sj.scanned_bt && (m.bt_gen[n] != m.gen || m.backticks[n] <= sj.pos) do return 0
	for {
		for sj.pos < len(sj.s) && sj.s[sj.pos] != '`' do sj.pos += 1
		if sj.pos >= len(sj.s) do break
		k := 0
		for peek_c(sj) == '`' {
			sj.pos += 1
			k += 1
		}
		if k <= MAX_BACKTICKS {
			m.backticks[k] = sj.pos - k
			m.bt_gen[k] = m.gen
		}
		if k == n do return sj.pos
	}
	sj.scanned_bt = true
	return 0
}

@(private = "file")
handle_entity :: proc(sj: ^Subj) -> ^Md_Inline {
	sj.pos += 1
	if r, n, ok := md_entity(sj.s[sj.pos:], sj.alloc); ok {
		sj.pos += n
		return mk(sj, .Text, r)
	}
	return mk(sj, .Text, "&")
}

// One entity or numeric character reference after the '&': its text, its
// length (with the ';').
md_entity :: proc(s: string, alloc: runtime.Allocator) -> (text: string, n: int, ok: bool) {
	if len(s) > 1 && s[0] == '#' {
		i := 1
		hex := false
		if i < len(s) && (s[i] == 'x' || s[i] == 'X') {
			hex = true
			i += 1
		}
		start := i
		v := 0
		for i < len(s) && i - start < (hex ? 6 : 7) {
			c := s[i]
			d := -1
			if c >= '0' && c <= '9' do d = int(c - '0')
			else if hex && c >= 'a' && c <= 'f' do d = int(c - 'a' + 10)
			else if hex && c >= 'A' && c <= 'F' do d = int(c - 'A' + 10)
			if d < 0 do break
			v = v * (hex ? 16 : 10) + d
			i += 1
		}
		if i == start || i >= len(s) || s[i] != ';' do return
		r := rune(v)
		if v == 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) do r = 0xFFFD
		b, l := utf8.encode_rune(r)
		return strings.clone(string(b[:l]), alloc), i + 1, true
	}
	i := 0
	for i < len(s) && i < 32 && is_ascii_alnum(s[i]) do i += 1
	if i == 0 || i >= len(s) || s[i] != ';' do return
	if t, found := md_entity_lookup(s[:i]); found do return t, i + 1, true
	return
}

// ---- autolinks and raw HTML ----

@(private = "file")
handle_pointy :: proc(sj: ^Subj) -> ^Md_Inline {
	s := sj.s
	at := sj.pos
	if n := uri_autolink(s, at); n > 0 {
		url := s[at + 1:at + n - 1]
		sj.pos = at + n
		return make_autolink(sj, url, false)
	}
	if n := email_autolink(s, at); n > 0 {
		url := s[at + 1:at + n - 1]
		sj.pos = at + n
		return make_autolink(sj, url, true)
	}
	if n := md_scan_raw_html(s, at); n > 0 {
		sj.pos = at + n
		return mk(sj, .Html, s[at:at + n])
	}
	sj.pos += 1
	return mk(sj, .Text, "<")
}

@(private = "file")
make_autolink :: proc(sj: ^Subj, url: string, email: bool) -> ^Md_Inline {
	l := mk(sj, .Link)
	l.autolink = true
	u := md_decode_entities(url, sj.alloc)
	l.url = email ? strings.concatenate({"mailto:", u}, sj.alloc) : u
	md_append(l, mk(sj, .Text, u))
	return l
}

@(private = "file")
uri_autolink :: proc(s: string, at: int) -> int {
	i := at + 1
	if i >= len(s) || !is_ascii_letter(s[i]) do return 0
	j := i
	for j < len(s) && (is_ascii_alnum(s[j]) || s[j] == '+' || s[j] == '.' || s[j] == '-') do j += 1
	if j - i < 2 || j - i > 32 || j >= len(s) || s[j] != ':' do return 0
	j += 1
	for j < len(s) {
		c := s[j]
		if c == '>' do return j + 1 - at
		if c == '<' || c <= ' ' do return 0
		j += 1
	}
	return 0
}

@(private = "file")
email_autolink :: proc(s: string, at: int) -> int {
	i := at + 1
	start := i
	for i < len(s) && (is_ascii_alnum(s[i]) || strings.index_byte(".!#$%&'*+/=?^_`{|}~-", s[i]) >= 0) do i += 1
	if i == start || i >= len(s) || s[i] != '@' do return 0
	i += 1
	for {
		// a label: alnum, then up to 61 alnum or '-', ending alnum
		ls := i
		for i < len(s) && (is_ascii_alnum(s[i]) || s[i] == '-') && i - ls < 63 do i += 1
		if i == ls || s[ls] == '-' || s[i - 1] == '-' do return 0
		if i < len(s) && s[i] == '.' {
			i += 1
			continue
		}
		break
	}
	if i < len(s) && s[i] == '>' do return i + 1 - at
	return 0
}

// The length of an open or closing HTML tag at `at` (0 if there is none).
// Line endings are allowed inside unless one_line.
md_scan_tag :: proc(s: string, at: int, one_line := false) -> int {
	ws :: proc(s: string, i: int) -> int {
		j := i
		for j < len(s) && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r' || s[j] == '\f' || s[j] == '\v') do j += 1
		return j
	}
	if at >= len(s) || s[at] != '<' do return 0
	i := at + 1
	closing := i < len(s) && s[i] == '/'
	if closing do i += 1
	if i >= len(s) || !is_ascii_letter(s[i]) do return 0
	for i < len(s) && (is_ascii_alnum(s[i]) || s[i] == '-') do i += 1
	if closing {
		i = ws(s, i)
		return i < len(s) && s[i] == '>' ? i + 1 - at : 0
	}
	for {
		j := ws(s, i)
		if j < len(s) && s[j] == '>' do return j + 1 - at
		if j + 1 < len(s) && s[j] == '/' && s[j + 1] == '>' do return j + 2 - at
		if j == i do return 0 // an attribute needs whitespace before it
		// attribute name
		if j >= len(s) || !(is_ascii_letter(s[j]) || s[j] == '_' || s[j] == ':') do return 0
		k := j + 1
		for k < len(s) && (is_ascii_alnum(s[k]) || s[k] == '_' || s[k] == '.' || s[k] == ':' || s[k] == '-') do k += 1
		i = k
		// value
		v := ws(s, k)
		if v < len(s) && s[v] == '=' {
			v = ws(s, v + 1)
			if v >= len(s) do return 0
			q := s[v]
			if q == '"' || q == '\'' {
				e := strings.index_byte(s[v + 1:], q)
				if e < 0 do return 0
				i = v + 1 + e + 1
			} else {
				e := v
				for e < len(s) && strings.index_byte(" \t\n\r\f\v\"'=<>`", s[e]) < 0 do e += 1
				if e == v do return 0
				i = e
			}
		}
	}
}

// Raw inline HTML at `at`: a tag, comment, processing instruction,
// declaration or CDATA section; its length or 0.
md_scan_raw_html :: proc(s: string, at: int) -> int {
	if n := md_scan_tag(s, at); n > 0 do return n
	r := s[at:]
	if strings.has_prefix(r, "<!--") {
		if strings.has_prefix(r, "<!-->") do return 5
		if strings.has_prefix(r, "<!--->") do return 6
		e := strings.index(r[4:], "-->")
		return e < 0 ? 0 : 4 + e + 3
	}
	if strings.has_prefix(r, "<?") {
		e := strings.index(r[2:], "?>")
		return e < 0 ? 0 : 2 + e + 2
	}
	if strings.has_prefix(r, "<![CDATA[") {
		e := strings.index(r[9:], "]]>")
		return e < 0 ? 0 : 9 + e + 3
	}
	if len(r) > 2 && r[1] == '!' && is_ascii_letter(r[2]) {
		e := strings.index_byte(r, '>')
		return e < 0 ? 0 : e + 1
	}
	return 0
}

// ---- emphasis, strong, strikethrough ----

@(private = "file")
handle_delim :: proc(sj: ^Subj, c: u8) -> ^Md_Inline {
	start := sj.pos
	for peek_c(sj) == c do sj.pos += 1
	n := sj.pos - start
	before := rune_before(sj.s, start)
	after := rune_at(sj.s, sj.pos)
	left := !uni_space(after) && (!uni_punct(after) || uni_space(before) || uni_punct(before))
	right := !uni_space(before) && (!uni_punct(before) || uni_space(after) || uni_punct(after))
	can_open, can_close: bool
	switch c {
	case '_':
		can_open = left && (!right || uni_punct(before))
		can_close = right && (!left || uni_punct(after))
	case '~':
		can_open, can_close = left, right
		if n > 2 do can_open, can_close = false, false // ~~~ is text
	case:
		can_open, can_close = left, right
	}
	inl := mk(sj, .Text, sj.s[start:sj.pos])
	if can_open || can_close {
		d := new(Delim, sj.alloc)
		d^ = {prev = sj.last_delim, inl = inl, length = n, orig = n, c = c, can_open = can_open, can_close = can_close, pos = sj.pos}
		if sj.last_delim != nil do sj.last_delim.next = d
		sj.last_delim = d
	}
	return inl
}

@(private = "file")
remove_delim :: proc(sj: ^Subj, d: ^Delim) {
	if d.next == nil do sj.last_delim = d.prev
	else do d.next.prev = d.prev
	if d.prev != nil do d.prev.next = d.next
}

@(private = "file")
bottom_index :: proc(d: ^Delim) -> int {
	k := 0
	switch d.c {
	case '_': k = 1
	case '~': k = 2
	}
	return k * 6 + (d.can_open ? 3 : 0) + d.orig % 3
}

@(private = "file")
process_emphasis :: proc(sj: ^Subj, stack_bottom: int) {
	bottoms: [18]int
	for &b in bottoms do b = stack_bottom
	closer: ^Delim
	for cand := sj.last_delim; cand != nil && cand.pos >= stack_bottom; cand = cand.prev do closer = cand
	for closer != nil {
		if !closer.can_close {
			closer = closer.next
			continue
		}
		bi := bottom_index(closer)
		opener := closer.prev
		found := false
		for opener != nil && opener.pos >= stack_bottom && opener.pos >= bottoms[bi] {
			if opener.can_open && opener.c == closer.c {
				if closer.c == '~' {
					if opener.length == closer.length {
						found = true
						break
					}
				} else if !(closer.can_open || opener.can_close) || closer.orig % 3 == 0 || (opener.orig + closer.orig) % 3 != 0 {
					found = true
					break
				}
			}
			opener = opener.prev
		}
		old := closer
		if found {
			closer = closer.c == '~' ? insert_strike(sj, opener, closer) : insert_emph(sj, opener, closer)
		} else {
			closer = closer.next
			bottoms[bi] = old.pos
			if !old.can_open do remove_delim(sj, old)
		}
	}
	for sj.last_delim != nil && sj.last_delim.pos >= stack_bottom do remove_delim(sj, sj.last_delim)
}

@(private = "file")
insert_emph :: proc(sj: ^Subj, opener, closer: ^Delim) -> ^Delim {
	use := closer.length >= 2 && opener.length >= 2 ? 2 : 1
	opener.length -= use
	closer.length -= use
	opener.inl.text = opener.inl.text[:opener.length]
	closer.inl.text = closer.inl.text[:closer.length]
	for d := closer.prev; d != nil && d != opener; {
		p := d.prev
		remove_delim(sj, d)
		d = p
	}
	emph := mk(sj, use == 1 ? .Emph : .Strong)
	wrap_between(opener.inl, closer.inl, emph)
	if opener.length == 0 {
		md_unlink(opener.inl)
		remove_delim(sj, opener)
	}
	if closer.length == 0 {
		md_unlink(closer.inl)
		next := closer.next
		remove_delim(sj, closer)
		return next
	}
	return closer
}

@(private = "file")
insert_strike :: proc(sj: ^Subj, opener, closer: ^Delim) -> ^Delim {
	for d := closer.prev; d != nil && d != opener; {
		p := d.prev
		remove_delim(sj, d)
		d = p
	}
	st := mk(sj, .Strike)
	wrap_between(opener.inl, closer.inl, st)
	md_unlink(opener.inl)
	remove_delim(sj, opener)
	md_unlink(closer.inl)
	next := closer.next
	remove_delim(sj, closer)
	return next
}

// Moves the nodes between a and b into wrap, which goes after a.
@(private = "file")
wrap_between :: proc(a, b: ^Md_Inline, wrap: ^Md_Inline) {
	t := a.next
	for t != nil && t != b {
		nx := t.next
		md_unlink(t)
		md_append(wrap, t)
		t = nx
	}
	insert_after(a, wrap)
}

// ---- links and images ----

@(private = "file")
push_bracket :: proc(sj: ^Subj, image: bool, inl: ^Md_Inline) {
	if sj.last_bracket != nil do sj.last_bracket.bracket_after = true
	b := new(Bracket, sj.alloc)
	b^ = {prev = sj.last_bracket, inl = inl, pos = sj.pos, image = image}
	sj.last_bracket = b
	if !image do sj.no_link_openers = false
}

@(private = "file")
handle_close_bracket :: proc(sj: ^Subj) -> ^Md_Inline {
	sj.pos += 1
	initial := sj.pos
	opener := sj.last_bracket
	if opener == nil do return mk(sj, .Text, "]")
	if !opener.image && sj.no_link_openers {
		sj.last_bracket = opener.prev
		return mk(sj, .Text, "]")
	}
	url, title: string
	matched := false
	// inline: (destination "title")
	if peek_c(sj) == '(' {
		sps := spacechars(sj.s, sj.pos + 1)
		if dest, n, ok := scan_link_dest(sj.s, sj.pos + 1 + sps); ok {
			end_url := sj.pos + 1 + sps + n
			start_title := end_url + spacechars(sj.s, end_url)
			end_title := start_title
			tn := 0
			if start_title != end_url do tn = scan_link_title(sj.s, start_title)
			end_title = start_title + tn
			if tn == 0 do end_title = start_title
			end_all := end_title + spacechars(sj.s, end_title)
			if peek_at(sj, end_all) == ')' {
				sj.pos = end_all + 1
				url = clean_url(dest, sj.alloc)
				title = tn > 0 ? clean_title(sj.s[start_title:end_title], sj.alloc) : ""
				matched = true
			}
		}
	}
	if !matched {
		// reference: [text][label], [text][], [text]
		label, found := link_label(sj)
		if !found do sj.pos = initial
		if (!found || len(label) == 0) && !opener.bracket_after {
			label = sj.s[opener.pos:initial - 1]
			found = true
		}
		if found {
			if ref, ok := sj.doc.refs[md_normalize_label(label, context.temp_allocator)]; ok {
				url, title = ref.url, ref.title
				matched = true
			}
		}
		if !matched {
			sj.last_bracket = opener.prev
			sj.pos = initial
			return mk(sj, .Text, "]")
		}
	}
	l := mk(sj, opener.image ? .Image : .Link)
	l.url = url
	l.title = title
	insert_before(opener.inl, l)
	t := opener.inl.next
	for t != nil {
		nx := t.next
		md_unlink(t)
		md_append(l, t)
		t = nx
	}
	md_unlink(opener.inl)
	process_emphasis(sj, opener.pos)
	sj.last_bracket = opener.prev
	if !opener.image do sj.no_link_openers = true
	return nil
}

// A link label at pos ("[...]"): its raw text (trimmed). The position moves
// past it when found.
@(private = "file")
link_label :: proc(sj: ^Subj) -> (string, bool) {
	start := sj.pos
	if peek_c(sj) != '[' do return "", false
	sj.pos += 1
	length := 0
	for sj.pos < len(sj.s) {
		c := sj.s[sj.pos]
		if c == '[' || c == ']' do break
		if c == '\\' {
			sj.pos += 1
			length += 1
			if is_ascii_punct(peek_c(sj)) {
				sj.pos += 1
				length += 1
			}
		} else {
			sj.pos += 1
			length += 1
		}
		if length > MAX_LABEL {
			sj.pos = start
			return "", false
		}
	}
	if peek_c(sj) == ']' {
		raw := trim_ws(sj.s[start + 1:sj.pos])
		sj.pos += 1
		return raw, true
	}
	sj.pos = start
	return "", false
}

// A link destination at `at`: <...> or a run with balanced parentheses.
@(private = "file")
scan_link_dest :: proc(s: string, at: int) -> (dest: string, n: int, ok: bool) {
	i := at
	if i < len(s) && s[i] == '<' {
		i += 1
		for i < len(s) {
			c := s[i]
			if c == '>' {
				return s[at:i + 1], i + 1 - at, true
			} else if c == '\\' {
				i += 2
			} else if c == '\n' || c == '\r' || c == '<' {
				return
			} else do i += 1
		}
		return
	}
	depth := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' && i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
			i += 2
		} else if c == '(' {
			depth += 1
			i += 1
			if depth > 32 do return
		} else if c == ')' {
			if depth == 0 do break
			depth -= 1
			i += 1
		} else if c <= ' ' || c == 0x7f {
			if i == at do return
			break
		} else do i += 1
	}
	if i >= len(s) || depth != 0 do return
	return s[at:i], i - at, true
}

@(private = "file")
scan_link_title :: proc(s: string, at: int) -> int {
	if at >= len(s) do return 0
	open := s[at]
	close: u8
	switch open {
	case '"':  close = '"'
	case '\'': close = '\''
	case '(':  close = ')'
	case:      return 0
	}
	i := at + 1
	for i < len(s) {
		c := s[i]
		if c == '\\' && i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
			i += 2
			continue
		}
		if c == close do return i + 1 - at
		if open == '(' && c == '(' do return 0
		i += 1
	}
	return 0
}

@(private = "file")
clean_url :: proc(dest: string, alloc: runtime.Allocator) -> string {
	d := trim_ws(dest)
	if len(d) >= 2 && d[0] == '<' && d[len(d) - 1] == '>' do d = d[1:len(d) - 1]
	return md_unescape(d, alloc)
}

@(private = "file")
clean_title :: proc(t: string, alloc: runtime.Allocator) -> string {
	if len(t) < 2 do return ""
	return md_unescape(t[1:len(t) - 1], alloc)
}

// Backslash escapes and entities resolved.
md_unescape :: proc(s: string, alloc: runtime.Allocator) -> string {
	if strings.index_byte(s, '\\') < 0 && strings.index_byte(s, '&') < 0 do return s
	sb := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '\\' && i + 1 < len(s) && is_ascii_punct(s[i + 1]) {
			strings.write_byte(&sb, s[i + 1])
			i += 2
		} else if c == '&' {
			if t, n, ok := md_entity(s[i + 1:], context.temp_allocator); ok {
				strings.write_string(&sb, t)
				i += 1 + n
			} else {
				strings.write_byte(&sb, '&')
				i += 1
			}
		} else {
			strings.write_byte(&sb, c)
			i += 1
		}
	}
	return strings.to_string(sb)
}

md_decode_entities :: proc(s: string, alloc: runtime.Allocator) -> string {
	if strings.index_byte(s, '&') < 0 do return s
	sb := strings.builder_make(alloc)
	i := 0
	for i < len(s) {
		if s[i] == '&' {
			if t, n, ok := md_entity(s[i + 1:], context.temp_allocator); ok {
				strings.write_string(&sb, t)
				i += 1 + n
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	return strings.to_string(sb)
}

// A label as the reference map keys it: whitespace runs as one space, lower case.
md_normalize_label :: proc(label: string, alloc: runtime.Allocator) -> string {
	sb := strings.builder_make(alloc)
	space := false
	for r in trim_ws(label) {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			space = true
			continue
		}
		if space do strings.write_byte(&sb, ' ')
		space = false
		if r == 'ẞ' || r == 'ß' {
			strings.write_string(&sb, "ss")
			continue
		}
		if r < 128 do strings.write_byte(&sb, ascii_lower(u8(r)))
		else do strings.write_rune(&sb, unicode.to_lower(r))
	}
	return strings.to_string(sb)
}

// A link reference definition at the start of s: its length (0 = none).
// The first definition of a label wins.
md_parse_reference :: proc(s: string, doc: ^Md_Doc) -> int {
	sj := Subj{s = s, doc = doc, alloc = doc.alloc}
	label, ok := link_label(&sj)
	if !ok || len(label) == 0 do return 0
	if trim_ws(label) == "" do return 0
	if peek_c(&sj) != ':' do return 0
	sj.pos += 1
	spnl(&sj)
	dest, n, dok := scan_link_dest(sj.s, sj.pos)
	if !dok do return 0
	if n == 0 && !(sj.pos < len(s) && s[sj.pos] == '<') do return 0
	sj.pos += n
	before_title := sj.pos
	spnl(&sj)
	tn := 0
	if sj.pos != before_title do tn = scan_link_title(sj.s, sj.pos)
	title := ""
	if tn > 0 {
		title = sj.s[sj.pos:sj.pos + tn]
		sj.pos += tn
	} else do sj.pos = before_title
	skip_spaces(&sj)
	if !skip_line_end(&sj) {
		if tn == 0 do return 0
		sj.pos = before_title
		title = ""
		skip_spaces(&sj)
		if !skip_line_end(&sj) do return 0
	}
	key := md_normalize_label(label, doc.alloc)
	if key == "" do return 0
	if key not_in doc.refs {
		doc.refs[key] = Md_Ref{url = clean_url(dest, doc.alloc), title = title != "" ? clean_title(title, doc.alloc) : ""}
	}
	return sj.pos
}

// ---- GFM autolinks (www., http://, https://, e-mail) in text ----

@(private = "file")
gfm_autolinks :: proc(sj: ^Subj, root: ^Md_Inline) {
	// the text nodes outside links first: linking changes the tree
	texts := make([dynamic]^Md_Inline, context.temp_allocator)
	w := md_walk(root)
	for c, entering in md_walk_next(&w) {
		if !entering do continue
		if c.kind == .Link || c.kind == .Image do md_walk_skip(&w)
		else if c.kind == .Text && may_autolink(c.text) do append(&texts, c)
	}
	for t in texts do autolink_text(sj, t)
}

@(private = "file")
autolink_text :: proc(sj: ^Subj, t: ^Md_Inline) {
	s := t.text
	// most text has no link: look for the markers first (fast searches)
	if !may_autolink(s) do return
	i := 0
	for i < len(s) {
		c := s[i]
		start, end := -1, -1
		url: string
		if (c == 'w' || c == 'h' || c == 'f' || c == 'W' || c == 'H' || c == 'F') && boundary_before(s, i) {
			rest := s[i:]
			prefix := ""
			if has_prefix_ascii_fold(rest, "www.") do prefix = "http://"
			else if has_prefix_ascii_fold(rest, "http://") || has_prefix_ascii_fold(rest, "https://") || has_prefix_ascii_fold(rest, "ftp://") do prefix = ""
			else {
				i += 1
				continue
			}
			dstart := i
			if prefix == "" do dstart = i + strings.index(rest, "://") + 3
			dlen := valid_domain(s, dstart, prefix == "")
			if dlen > 0 {
				e := link_end(s, dstart + dlen)
				start, end = i, e
				url = prefix == "" ? s[start:end] : strings.concatenate({prefix, s[start:end]}, sj.alloc)
			}
		} else if c == '@' {
			// local part backwards, domain forwards
			ls := i
			for ls > 0 && (is_ascii_alnum(s[ls - 1]) || s[ls - 1] == '.' || s[ls - 1] == '-' || s[ls - 1] == '_' || s[ls - 1] == '+') do ls -= 1
			if ls < i {
				j := i + 1
				dots := 0
				for j < len(s) && (is_ascii_alnum(s[j]) || s[j] == '-' || s[j] == '_' || (s[j] == '.' && j + 1 < len(s) && is_ascii_alnum(s[j + 1]))) {
					if s[j] == '.' do dots += 1
					j += 1
				}
				if dots > 0 && j > i + 1 && s[j - 1] != '-' && s[j - 1] != '_' {
					start, end = ls, j
					url = strings.concatenate({"mailto:", s[ls:j]}, sj.alloc)
				}
			}
		}
		if start < 0 {
			i += 1
			continue
		}
		// split: before | link | after
		if start > 0 {
			before := mk(sj, .Text, s[:start])
			insert_before(t, before)
		}
		l := mk(sj, .Link)
		l.autolink = true
		l.url = url
		md_append(l, mk(sj, .Text, s[start:end]))
		insert_before(t, l)
		s = s[end:]
		t.text = s
		i = 0
	}
	if len(t.text) == 0 do md_unlink(t)
}

@(private = "file")
has_prefix_ascii_fold :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) do return false
	for i in 0 ..< len(prefix) do if ascii_lower(s[i]) != prefix[i] do return false
	return true
}

// Start of text, whitespace, or one of *_~( before position i.
@(private = "file")
boundary_before :: proc(s: string, i: int) -> bool {
	if i == 0 do return true
	c := s[i - 1]
	return c == ' ' || c == '\t' || c == '\n' || c == '*' || c == '_' || c == '~' || c == '('
}

// A domain at `at`: alnum, '-', '_' segments joined by '.', at least one
// '.', no '_' in the last two segments. Its length, 0 if invalid.
@(private = "file")
valid_domain :: proc(s: string, at: int, allow_short: bool) -> int {
	i := at
	dots := 0
	last_us, prev_us, cur_us := false, false, false
	for i < len(s) {
		c := s[i]
		if c == '.' {
			if i + 1 >= len(s) || !(is_ascii_alnum(s[i + 1]) || s[i + 1] == '-' || s[i + 1] == '_' || s[i + 1] >= 0x80) do break
			dots += 1
			prev_us, last_us = last_us, cur_us
			cur_us = false
		} else if c == '_' {
			cur_us = true
		} else if !(is_ascii_alnum(c) || c == '-' || c >= 0x80) {
			break
		}
		i += 1
	}
	prev_us, last_us = last_us, cur_us
	if i == at || (dots == 0 && !allow_short) || last_us || prev_us do return 0
	return i - at
}

// Where an autolink's path ends: before whitespace or '<', without
// trailing punctuation, unmatched ')' or an entity-like "&x;".
@(private = "file")
link_end :: proc(s: string, at: int) -> int {
	e := at
	for e < len(s) && s[e] != ' ' && s[e] != '\t' && s[e] != '\n' && s[e] != '<' do e += 1
	for e > at {
		c := s[e - 1]
		if strings.index_byte("?!.,:*_~'\"", c) >= 0 {
			e -= 1
		} else if c == ')' {
			open, close := 0, 0
			for k in at ..< e {
				if s[k] == '(' do open += 1
				if s[k] == ')' do close += 1
			}
			if close > open do e -= 1
			else do break
		} else if c == ';' {
			k := e - 2
			for k >= at && is_ascii_alnum(s[k]) do k -= 1
			if k >= at && s[k] == '&' && k < e - 2 do e = k
			else do break
		} else do break
	}
	return e
}
