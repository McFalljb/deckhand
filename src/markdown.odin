package main

// Markdown: md4c (vendor/md4c, built into build/md4c.a by build.sh) parses CommonMark 0.31.2 with
// the GFM extensions the viewer needs (tables, task lists, strikethrough); this file builds the
// tree the Markdown tab lays out and draws (markdown_view.odin) from md4c's callbacks, finds GFM's
// bare autolinks in its text (gfm_autolinks: md4c's own permissive autolinks take trailing
// punctuation and miss some), and gives headings their ids. markdown_html_test.odin writes the
// tree as HTML for the tests; tests/markdown/corpus/md4c.md pins where md4c parses differently
// from GFM or from the parser before it.
//
// md4c sees raw HTML (blocks and inline) and reports it; the tree keeps it as text, and the preview
// never renders it (markdown_view.odin: an HTML block shows its text without tags, inline tags are
// dropped but <br>). Link and image URLs are kept as written (escapes and entities resolved); the
// preview decides what a click may do (md_follow) and never fetches an image.
//
// md4c reports no source positions, so a block's line (the preview's scroll sync) comes from where
// its text lies in the source: md4c hands over pointers into the text it parses. A block without
// text (a thematic break, an empty item or code block) takes the first non-blank line after the
// text before it.
//
// Everything a document holds lives in its own arena: md_free drops it at once.

import "base:runtime"
import "core:c"
import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

foreign import md4c_lib "../build/md4c.a"

Md_Block_Kind :: enum u8 {
	Document,
	Block_Quote,
	List,
	Item,
	Paragraph,
	Heading,
	Thematic_Break,
	Code_Block,
	Html_Block,
	Table,
	Table_Row,
	Table_Cell,
}

Md_Align :: enum u8 {
	None,
	Left,
	Center,
	Right,
}

Md_Block :: struct {
	kind:     Md_Block_Kind,
	tight:    bool, // list
	ordered:  bool, // list
	header:   bool, // table row: the header
	level:    u8, // heading 1–6
	task:     u8, // item: 0 not a task, 1 open, 2 done
	bullet:   u8, // list: '-', '+', '*'; ordered: the delimiter '.' or ')'
	align:    Md_Align, // table cell
	start:    int, // ordered list's first number
	line:     int, // first source line (1-based)
	parent:   ^Md_Block,
	children: [dynamic]^Md_Block,
	text:     string, // code and HTML blocks: the literal
	info:     string, // code: the info string
	inl:      ^Md_Inline, // paragraph, heading, cell: the inlines (a Root node)
	aligns:   []Md_Align, // table
	anchor:   string, // heading: its id for links (#section)
}

Md_Doc :: struct {
	arena:       Md_Arena,
	alloc:       runtime.Allocator,
	root:        ^Md_Block,
	anchors:     map[string]^Md_Block, // heading ids
	anchor_next: map[string]int, // the last -N given per id
	code:        map[^Md_Block]Md_Code, // code blocks highlighted for the preview (markdown_view.odin)
}

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

// Block quotes and lists nest at most this deep; deeper ones add no level (their contents go to
// the deepest one kept). Keeps every walk over the tree shallow (no stack overflow on ">>>>…").
MD_MAX_DEPTH :: 48

// Parses text into a new document (free it with md_free). Never fails: on an md4c error the
// document holds what was parsed.
md_parse :: proc(text: string) -> ^Md_Doc {
	doc := new(Md_Doc)
	doc.alloc = runtime.Allocator{procedure = md_arena_proc, data = &doc.arena}
	context.allocator = doc.alloc
	doc.anchors = make(map[string]^Md_Block)
	doc.anchor_next = make(map[string]int)
	src := text
	if strings.index_byte(src, 0) >= 0 { 	// NUL is replaced by U+FFFD
		src, _ = strings.replace_all(src, "\x00", "�")
	}
	doc.root = new(Md_Block)
	doc.root.line = 1
	b := Builder{doc = doc, src = src, ctx = context}
	heap := runtime.heap_allocator()
	b.blocks = make([dynamic]Open_Block, heap)
	b.inls = make([dynamic]^Md_Inline, heap)
	b.line_starts = make([dynamic]int, heap)
	defer {
		delete(b.blocks)
		delete(b.inls)
		delete(b.line_starts)
	}
	append(&b.line_starts, 0)
	for i := 0; i < len(src); i += 1 {
		#no_bounds_check if src[i] == '\n' || src[i] == '\r' {
			if src[i] == '\r' && i + 1 < len(src) && src[i + 1] == '\n' do i += 1
			append(&b.line_starts, i + 1)
		}
	}
	append(&b.blocks, Open_Block{block = doc.root, owner = doc.root, first = -1})
	parser := MD_PARSER {
		// bare URLs and e-mail addresses: gfm_autolinks below (md4c's permissive autolinks differ from GFM's)
		flags       = MD_FLAG_TABLES | MD_FLAG_TASKLISTS | MD_FLAG_STRIKETHROUGH,
		enter_block = on_enter_block,
		leave_block = on_leave_block,
		enter_span  = on_enter_span,
		leave_span  = on_leave_span,
		text        = on_text,
	}
	// md4c's sizes are 32-bit (the editor opens far smaller files: EDITOR_MAX_BYTES)
	if len(src) > 0 do _ = md4c_parse(raw_data(src), u32(min(len(src), int(max(u32)))), &parser, &b)
	// after an error, what is still open
	for len(b.blocks) > 1 do leave_block(&b)
	return doc
}

md_free :: proc(doc: ^Md_Doc) {
	if doc == nil do return
	md_arena_free_all(&doc.arena)
	free(doc)
}

// ---- md4c (vendor/md4c/md4c.h) ----

@(private = "file")
MD_FLAG_TABLES :: 0x100
@(private = "file")
MD_FLAG_STRIKETHROUGH :: 0x200
@(private = "file")
MD_FLAG_TASKLISTS :: 0x800

@(private = "file")
MD_BLOCKTYPE :: enum c.int {
	DOC,
	QUOTE,
	UL,
	OL,
	LI,
	HR,
	H,
	CODE,
	HTML,
	P,
	TABLE,
	THEAD,
	TBODY,
	TR,
	TH,
	TD,
}

@(private = "file")
MD_SPANTYPE :: enum c.int {
	EM,
	STRONG,
	A,
	IMG,
	CODE,
	INS,
	DEL,
}

@(private = "file")
MD_TEXTTYPE :: enum c.int {
	NORMAL,
	NULLCHAR,
	BR,
	SOFTBR,
	ENTITY,
	CODE,
	HTML,
	LATEXMATH,
}

@(private = "file")
MD_ATTRIBUTE :: struct {
	text:           [^]u8,
	size:           u32,
	substr_types:   [^]MD_TEXTTYPE,
	substr_offsets: [^]u32,
}

@(private = "file")
MD_BLOCK_UL_DETAIL :: struct {
	is_tight: c.int,
	mark:     u8,
}

@(private = "file")
MD_BLOCK_OL_DETAIL :: struct {
	start:          c.uint,
	is_tight:       c.int,
	mark_delimiter: u8,
}

@(private = "file")
MD_BLOCK_LI_DETAIL :: struct {
	is_task:          c.int,
	task_mark:        u8,
	task_mark_offset: u32,
}

@(private = "file")
MD_BLOCK_H_DETAIL :: struct {
	level: c.uint,
}

@(private = "file")
MD_BLOCK_CODE_DETAIL :: struct {
	info, lang: MD_ATTRIBUTE,
	fence_char: u8,
}

@(private = "file")
MD_BLOCK_TABLE_DETAIL :: struct {
	col_count, head_row_count, body_row_count: c.uint,
}

@(private = "file")
MD_BLOCK_TD_DETAIL :: struct {
	align: c.int, // MD_ALIGN: default, left, center, right
}

@(private = "file")
MD_SPAN_A_DETAIL :: struct {
	href, title: MD_ATTRIBUTE,
	is_autolink: c.int,
}

@(private = "file")
MD_SPAN_IMG_DETAIL :: struct {
	src, title: MD_ATTRIBUTE,
}

@(private = "file")
Block_Proc :: proc "c" (type: MD_BLOCKTYPE, detail: rawptr, userdata: rawptr) -> c.int
@(private = "file")
Span_Proc :: proc "c" (type: MD_SPANTYPE, detail: rawptr, userdata: rawptr) -> c.int

@(private = "file")
MD_PARSER :: struct {
	abi_version:              c.uint,
	flags:                    c.uint,
	enter_block, leave_block: Block_Proc,
	enter_span, leave_span:   Span_Proc,
	text:                     proc "c" (type: MD_TEXTTYPE, text: [^]u8, size: u32, userdata: rawptr) -> c.int,
	debug_log:                proc "c" (msg: cstring, userdata: rawptr),
	syntax:                   proc "c" (),
}

// The layouts md4c.h has (sizeof and offsetof from clang, 64-bit macOS): a binding that drifts
// from them reads the wrong bytes out of md4c's details.
#assert(size_of(MD_ATTRIBUTE) == 32 && offset_of(MD_ATTRIBUTE, size) == 8 && offset_of(MD_ATTRIBUTE, substr_offsets) == 24)
#assert(size_of(MD_BLOCK_UL_DETAIL) == 8 && offset_of(MD_BLOCK_UL_DETAIL, mark) == 4)
#assert(size_of(MD_BLOCK_OL_DETAIL) == 12 && offset_of(MD_BLOCK_OL_DETAIL, mark_delimiter) == 8)
#assert(size_of(MD_BLOCK_LI_DETAIL) == 12 && offset_of(MD_BLOCK_LI_DETAIL, task_mark) == 4 && offset_of(MD_BLOCK_LI_DETAIL, task_mark_offset) == 8)
#assert(size_of(MD_BLOCK_H_DETAIL) == 4 && size_of(MD_BLOCK_TABLE_DETAIL) == 12 && size_of(MD_BLOCK_TD_DETAIL) == 4)
#assert(size_of(MD_BLOCK_CODE_DETAIL) == 72 && offset_of(MD_BLOCK_CODE_DETAIL, fence_char) == 64)
#assert(size_of(MD_SPAN_A_DETAIL) == 72 && offset_of(MD_SPAN_A_DETAIL, is_autolink) == 64)
#assert(size_of(MD_SPAN_IMG_DETAIL) == 64 && offset_of(MD_SPAN_IMG_DETAIL, title) == 32)
#assert(size_of(MD_PARSER) == 64 && offset_of(MD_PARSER, text) == 40 && offset_of(MD_PARSER, syntax) == 56)
#assert(int(MD_BLOCKTYPE.TD) == 15 && int(MD_SPANTYPE.DEL) == 6 && int(MD_TEXTTYPE.HTML) == 6)

@(private = "file")
@(default_calling_convention = "c")
foreign md4c_lib {
	@(link_name = "md_parse")
	md4c_parse :: proc(text: [^]u8, size: u32, parser: ^MD_PARSER, userdata: rawptr) -> c.int ---
}

// ---- the tree from md4c's callbacks ----

@(private = "file")
Open_Block :: struct {
	block:     ^Md_Block, // nil: a container past MD_MAX_DEPTH, not made
	owner:     ^Md_Block, // the block its contents go to: itself, or the deepest one made above it
	first:     int, // source offset of its first text (-1: none yet)
	first_line: int, // its line
	scan_from: int, // the line of the text before it (0: none)
	from_info: bool, // code: first is its info string (on the fence line), not its first line of code
	made:      bool, // a paragraph md4c does not report (a tight list's item): closed with its inlines
	marker:    int, // item, block quote: the line of its marker (0: not found)
	indent:    int, // code and HTML blocks: md4c's indentation of the line, not written yet
	empty:     int, // code: the empty lines before its first text (md4c reports none for them)
	fence:     u8, // code: its fence character (0: indented)
	text:      strings.Builder, // code and HTML blocks
}

@(private = "file")
Builder :: struct {
	doc:         ^Md_Doc,
	src:         string,
	ctx:         runtime.Context,
	blocks:      [dynamic]Open_Block, // open blocks, the document first
	inls:        [dynamic]^Md_Inline, // open inline containers, the block's Root first
	code_span:   ^Md_Inline, // the open code span
	text:        strings.Builder, // the open Text, Code or Html node's text
	text_node:   ^Md_Inline,
	depth:       int, // block quotes and lists made
	quotes:      int, // block quotes made
	in_head:     bool, // in a table's header
	line_starts: [dynamic]int, // the offset of every source line
	last_line:   int, // the line of the latest text (0: none)
	line_hint:   int, // line_of's last answer (0-based)
	marker_at:   int, // where the next container's marker may start (find_marker)
}

@(private = "file")
on_enter_block :: proc "c" (type: MD_BLOCKTYPE, detail: rawptr, userdata: rawptr) -> c.int {
	b := (^Builder)(userdata)
	context = b.ctx
	end_inlines(b)
	kind: Md_Block_Kind
	switch type {
	case .DOC: return 0
	case .THEAD:
		b.in_head = true
		return 0
	case .TBODY: return 0
	case .QUOTE: kind = .Block_Quote
	case .UL, .OL: kind = .List
	case .LI: kind = .Item
	case .HR: kind = .Thematic_Break
	case .H: kind = .Heading
	case .CODE: kind = .Code_Block
	case .HTML: kind = .Html_Block
	case .P: kind = .Paragraph
	case .TABLE: kind = .Table
	case .TR: kind = .Table_Row
	case .TH, .TD: kind = .Table_Cell
	}
	parent := top_block(b)
	ob := Open_Block{owner = parent, first = -1, scan_from = b.last_line}
	container := kind == .Block_Quote || kind == .List
	if (container && b.depth >= MD_MAX_DEPTH) || (kind == .Item && (parent == nil || parent.kind != .List)) {
		append(&b.blocks, ob) // not made: its contents go to the deepest block kept
		return 0
	}
	if container do b.depth += 1
	if kind == .Block_Quote do b.quotes += 1
	blk := new(Md_Block)
	blk.kind = kind
	blk.parent = parent
	append(&parent.children, blk)
	ob.block, ob.owner = blk, blk
	mark := -1
	if kind == .Item || kind == .Block_Quote {
		from := b.last_line < len(b.line_starts) ? b.line_starts[b.last_line] : len(b.src) // the line after the text before
		ob.marker, b.marker_at = find_marker(b, max(b.marker_at, from), kind == .Item, b.quotes - (kind == .Block_Quote ? 1 : 0))
	}
	#partial switch type {
	case .UL:
		d := (^MD_BLOCK_UL_DETAIL)(detail)
		blk.tight, blk.bullet = d.is_tight != 0, d.mark
	case .OL:
		d := (^MD_BLOCK_OL_DETAIL)(detail)
		blk.ordered, blk.tight, blk.bullet, blk.start = true, d.is_tight != 0, d.mark_delimiter, int(d.start)
	case .LI:
		d := (^MD_BLOCK_LI_DETAIL)(detail)
		if d.is_task != 0 {
			blk.task = d.task_mark == ' ' ? 1 : 2
			mark = int(d.task_mark_offset)
		}
	case .H:
		blk.level = u8(clamp((^MD_BLOCK_H_DETAIL)(detail).level, 1, 6))
		blk.inl = new_inline(.Root)
	case .CODE:
		d := (^MD_BLOCK_CODE_DETAIL)(detail)
		ob.fence = d.fence_char
		blk.info = attribute(d.info)
		if off := src_offset(b, d.info.text, d.info.size); off >= 0 {
			mark = off
			ob.from_info = true
		}
		ob.text = strings.builder_make()
	case .HTML:
		ob.text = strings.builder_make()
	case .P:
		blk.inl = new_inline(.Root)
	case .TABLE:
		blk.aligns = make([]Md_Align, (^MD_BLOCK_TABLE_DETAIL)(detail).col_count)
	case .TR:
		blk.header = b.in_head
	case .TH, .TD:
		blk.align = Md_Align(clamp((^MD_BLOCK_TD_DETAIL)(detail).align, 0, 3))
		blk.inl = new_inline(.Root)
		if row := blk.parent; row.kind == .Table_Row && row.header && row.parent != nil && row.parent.kind == .Table {
			if i := len(row.children) - 1; i < len(row.parent.aligns) do row.parent.aligns[i] = blk.align
		}
	}
	append(&b.blocks, ob)
	if mark >= 0 do saw_source(b, mark, 0) // the task's "[ ]", the info string: on the block's first line
	return 0
}

@(private = "file")
on_leave_block :: proc "c" (type: MD_BLOCKTYPE, detail: rawptr, userdata: rawptr) -> c.int {
	b := (^Builder)(userdata)
	context = b.ctx
	#partial switch type {
	case .DOC, .TBODY: return 0
	case .THEAD:
		b.in_head = false
		return 0
	}
	leave_block(b)
	return 0
}

@(private = "file")
leave_block :: proc(b: ^Builder) {
	end_inlines(b)
	ob := pop(&b.blocks)
	blk := ob.block
	if blk == nil do return
	if blk.kind == .Block_Quote || blk.kind == .List do b.depth -= 1
	if blk.kind == .Block_Quote do b.quotes -= 1
	if blk.kind == .Code_Block || blk.kind == .Html_Block do blk.text = strings.to_string(ob.text)
	// its line: its first text's, the fence line above the first line of code, its first child's
	// when that is earlier; without any, the first line with something on it after the text before
	line := ob.first >= 0 ? ob.first_line : 0
	if line > 0 && blk.kind == .Code_Block && ob.fence != 0 && !ob.from_info do line -= 1 + ob.empty
	for ch in blk.children do if ch.line > 0 && (line == 0 || ch.line < line) do line = ch.line
	if ob.marker > 0 && (line == 0 || ob.marker < line) do line = ob.marker // a reference definition first in it
	if line == 0 && blk.kind != .Table_Cell do line = first_line_after(b, ob.scan_from) // an empty cell: its row's line
	blk.line = line
	b.last_line = max(b.last_line, line) // what follows starts below it
	if blk.inl != nil do gfm_autolinks(blk.inl)
	#partial switch blk.kind {
	case .Code_Block:
		// the closing fence: the next line after the last of code (or the opening one) with
		// something on it (md4c reports no text for an empty line of code)
		if ob.fence != 0 {
			next := max(b.last_line, line) + 1
			for next <= len(b.line_starts) && stripped_line(b, next) == "" do next += 1
			if s := stripped_line(b, next); len(s) >= 3 && s[0] == ob.fence && s[1] == ob.fence && s[2] == ob.fence do b.last_line = next
		}
	case .Heading:
		// a setext heading's underline (an ATX heading has a '#' before its text)
		if ob.first >= 0 && strings.index_byte(b.src[b.line_starts[line - 1]:ob.first], '#') < 0 {
			u := strings.trim_right(stripped_line(b, b.last_line + 1), " \t")
			if len(u) > 0 && (u[0] == '=' || u[0] == '-') && strings.count(u, u[:1]) == len(u) do b.last_line += 1
		}
		heading_anchor(b.doc, blk)
	case .Table_Cell:
		// GFM takes "\|" out of a cell before its inlines, so out of code spans too (md4c keeps it there)
		w := md_walk(blk.inl)
		for n, entering in md_walk_next(&w) do if entering && n.kind == .Code && strings.contains(n.text, "\\|") {
			n.text, _ = strings.replace_all(n.text, "\\|", "|")
		}
	case .Table_Row:
		for ch in blk.children do if ch.line == 0 do ch.line = line
		if blk.header do b.last_line = max(b.last_line, line + 1) // the delimiter row
	}
}

@(private = "file")
top_block :: proc(b: ^Builder) -> ^Md_Block {
	return b.blocks[len(b.blocks) - 1].owner
}

// The node inlines go into: the open container, else the block's Root; a tight list's item
// (md4c reports no paragraph in it) gets a paragraph of its own.
@(private = "file")
inline_parent :: proc(b: ^Builder) -> ^Md_Inline {
	if len(b.inls) > 0 do return b.inls[len(b.inls) - 1]
	blk := top_block(b)
	if blk.inl == nil {
		if blk.kind != .Item && blk.kind != .Block_Quote && blk.kind != .Document do return nil
		p := new(Md_Block)
		p.kind = .Paragraph
		p.parent = blk
		p.inl = new_inline(.Root)
		append(&blk.children, p)
		append(&b.blocks, Open_Block{block = p, owner = p, first = -1, scan_from = b.last_line, made = true})
		blk = p
	}
	append(&b.inls, blk.inl)
	return blk.inl
}

// Closes the open inlines (a block starts or ends), and the paragraph made for a tight item.
@(private = "file")
end_inlines :: proc(b: ^Builder) {
	end_text(b)
	clear(&b.inls)
	b.code_span = nil
	if top := &b.blocks[len(b.blocks) - 1]; top.made {
		top.made = false
		leave_block(b)
	}
}

@(private = "file")
end_text :: proc(b: ^Builder) {
	if b.text_node == nil do return
	b.text_node.text = strings.to_string(b.text)
	b.text_node = nil
}

// Text into node kind (Text, Code, Html) under parent: the open one of that kind grows.
@(private = "file")
add_text :: proc(b: ^Builder, parent: ^Md_Inline, kind: Md_Inline_Kind, s: string, joins := true) {
	if b.text_node == nil || b.text_node.kind != kind || b.text_node.parent != parent || parent.last != b.text_node || !joins {
		end_text(b)
		b.text_node = new_inline(kind)
		md_append(parent, b.text_node)
		b.text = strings.builder_make()
	}
	strings.write_string(&b.text, s)
}

@(private = "file")
on_enter_span :: proc "c" (type: MD_SPANTYPE, detail: rawptr, userdata: rawptr) -> c.int {
	b := (^Builder)(userdata)
	context = b.ctx
	parent := inline_parent(b)
	if parent == nil do return 0
	end_text(b)
	kind: Md_Inline_Kind
	#partial switch type {
	case .EM: kind = .Emph
	case .STRONG: kind = .Strong
	case .DEL: kind = .Strike
	case .A: kind = .Link
	case .IMG: kind = .Image
	case .CODE:
		b.code_span = new_inline(.Code)
		md_append(parent, b.code_span)
		return 0
	case: return 0
	}
	n := new_inline(kind)
	md_append(parent, n)
	#partial switch type {
	case .A:
		d := (^MD_SPAN_A_DETAIL)(detail)
		n.url, n.title, n.autolink = attribute(d.href), attribute(d.title), d.is_autolink != 0
	case .IMG:
		d := (^MD_SPAN_IMG_DETAIL)(detail)
		n.url, n.title = attribute(d.src), attribute(d.title)
	}
	append(&b.inls, n)
	return 0
}

@(private = "file")
on_leave_span :: proc "c" (type: MD_SPANTYPE, detail: rawptr, userdata: rawptr) -> c.int {
	b := (^Builder)(userdata)
	context = b.ctx
	end_text(b)
	#partial switch type {
	case .CODE:
		b.code_span = nil
	case .EM, .STRONG, .DEL, .A, .IMG:
		if len(b.inls) > 1 do pop(&b.inls)
	}
	return 0
}

@(private = "file")
on_text :: proc "c" (type: MD_TEXTTYPE, text: [^]u8, size: u32, userdata: rawptr) -> c.int {
	b := (^Builder)(userdata)
	context = b.ctx
	s := string(text[:size]) if text != nil else ""
	off := src_offset(b, text, size)
	defer if off >= 0 do saw_source(b, off, int(size)) // after inline_parent: a paragraph it makes has this text first
	ob := &b.blocks[len(b.blocks) - 1]
	if ob.block != nil && (ob.block.kind == .Code_Block || ob.block.kind == .Html_Block) {
		verbatim_text(b, ob, s, off)
		return 0
	}
	if b.code_span != nil {
		// md4c hands a code span's text in pieces; it is one node
		if b.text_node != b.code_span {
			end_text(b)
			b.text_node = b.code_span
			b.text = strings.builder_make()
		}
		strings.write_string(&b.text, type == .NULLCHAR ? "�" : s)
		return 0
	}
	parent := inline_parent(b)
	if parent == nil do return 0
	switch type {
	case .NORMAL, .CODE, .LATEXMATH:
		add_text(b, parent, .Text, s)
	case .NULLCHAR:
		add_text(b, parent, .Text, "�")
	case .ENTITY:
		t, n, ok := md_entity(s[1:], context.allocator)
		add_text(b, parent, .Text, ok && n == len(s) - 1 ? t : s)
	case .BR, .SOFTBR:
		end_text(b)
		md_append(parent, new_inline(type == .BR ? .Linebreak : .Softbreak))
	case .HTML:
		// one tag is one node: a tag over several lines comes as its lines, each after a "\n"
		open := b.text_node != nil && b.text_node.kind == .Html && parent.last == b.text_node
		cont := open && (len(s) > 0 && (s[0] == '\n' || s[0] == ' ' || s[0] == '\t') || strings.has_suffix(strings.to_string(b.text), "\n"))
		add_text(b, parent, .Html, s, joins = cont)
	}
	return 0
}

// A code or HTML block's line comes as its indentation (md4c's spaces), its text (from the source)
// and "\n": the indentation is taken from the source, so tabs stay tabs.
@(private = "file")
verbatim_text :: proc(b: ^Builder, ob: ^Open_Block, s: string, off: int) {
	if off < 0 && s == "\n" && ob.first < 0 do ob.empty += 1
	if off < 0 && s != "\n" && strings.count(s, " ") == len(s) {
		ob.indent += len(s)
		return
	}
	if ob.indent > 0 {
		ws := strings.repeat(" ", ob.indent, context.temp_allocator)
		if off >= 0 {
			// the columns (tab stops of 4) of the line up to the text, back to where the indentation starts
			ls := b.line_starts[line_of(b, off) - 1]
			cols := make([]int, off - ls + 1, context.temp_allocator)
			for i in ls ..< off do cols[i - ls + 1] = b.src[i] == '\t' ? cols[i - ls] + 4 - cols[i - ls] % 4 : cols[i - ls] + 1
			want := cols[off - ls] - ob.indent
			q := off
			for q > ls && (b.src[q - 1] == ' ' || b.src[q - 1] == '\t') && cols[q - 1 - ls] >= want do q -= 1
			qcol := cols[q - ls]
			// a tab partly taken by the containers or the fence's indentation: its rest as spaces
			if qcol >= want && qcol - want <= 4 do ws = strings.concatenate({strings.repeat(" ", qcol - want, context.temp_allocator), b.src[q:off]}, context.temp_allocator)
		}
		strings.write_string(&ob.text, ws)
		ob.indent = 0
	}
	strings.write_string(&ob.text, s)
}

@(private = "file")
new_inline :: proc(kind: Md_Inline_Kind) -> ^Md_Inline {
	n := new(Md_Inline)
	n.kind = kind
	return n
}

// An attribute's text: entities decoded (escapes md4c resolved).
@(private = "file")
attribute :: proc(a: MD_ATTRIBUTE) -> string {
	if a.size == 0 || a.text == nil do return ""
	all := string(a.text[:a.size])
	sb := strings.builder_make()
	for i := 0; a.substr_offsets[i] < a.size; i += 1 {
		part := all[a.substr_offsets[i]:a.substr_offsets[i + 1]]
		switch a.substr_types[i] {
		case .ENTITY:
			if t, n, ok := md_entity(part[1:], context.temp_allocator); ok && n == len(part) - 1 do strings.write_string(&sb, t)
			else do strings.write_string(&sb, part)
		case .NULLCHAR:
			strings.write_string(&sb, "�")
		case .NORMAL, .BR, .SOFTBR, .CODE, .HTML, .LATEXMATH:
			strings.write_string(&sb, part)
		}
	}
	return strings.to_string(sb)
}

// ---- source lines ----

// Where p lies in the source (-1: md4c's own text, not the source's).
@(private = "file")
src_offset :: proc(b: ^Builder, p: [^]u8, size: u32) -> int {
	if p == nil || len(b.src) == 0 do return -1
	base := uintptr(raw_data(b.src))
	at := uintptr(p)
	if at < base || at + uintptr(size) > base + uintptr(len(b.src)) do return -1
	return int(at - base)
}

// Text at offset off: the open blocks without a first text have it; the latest line moves on.
@(private = "file")
saw_source :: proc(b: ^Builder, off, size: int) {
	l := line_of(b, off)
	#reverse for &ob in b.blocks {
		if ob.first >= 0 do break
		ob.first, ob.first_line = off, l
	}
	b.last_line = max(b.last_line, size > 1 ? line_of(b, off + size - 1) : l)
}

// The 1-based line of a source offset. Text comes in source order: the last answer or the next
// line, most times.
@(private = "file")
line_of :: proc(b: ^Builder, off: int) -> int #no_bounds_check {
	n := len(b.line_starts)
	for h in b.line_hint ..< min(b.line_hint + 2, n) {
		if b.line_starts[h] <= off && (h + 1 == n || off < b.line_starts[h + 1]) {
			b.line_hint = h
			return h + 1
		}
	}
	lo, hi := 0, n
	defer if lo > b.line_hint do b.line_hint = lo // a look back (a block's first line) leaves it
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if b.line_starts[mid] <= off do lo = mid
		else do hi = mid
	}
	return lo + 1
}

// A line without its line ending and the block quote markers and spaces it starts with ("" past
// the end).
@(private = "file")
stripped_line :: proc(b: ^Builder, line: int) -> string {
	if line < 1 || line > len(b.line_starts) do return ""
	s := b.src[b.line_starts[line - 1]:line < len(b.line_starts) ? b.line_starts[line] : len(b.src)]
	s = strings.trim_right(s, "\r\n")
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t' || s[0] == '>') do s = s[1:]
	return s
}

// Where the next list item's bullet or number (item) or block quote's '>' starts, from offset `at`
// on: the first line from there whose markers include one (an empty item, or one whose first
// content is not text, has no other line). Its line (0: none in the next lines), and the offset
// after the marker (a container nested on the same line looks from there). A quote inside
// `quotes` others: on a line of its own its '>' comes after theirs.
@(private = "file")
find_marker :: proc(b: ^Builder, at: int, item: bool, quotes: int) -> (line, after: int) #no_bounds_check {
	i := at
	for tries := 0; i < len(b.src) && tries < 64 && i - at < 1 << 16; tries += 1 {
		line_start := i == 0 || b.src[i - 1] == '\n' || b.src[i - 1] == '\r'
		outer := !item && line_start ? quotes : 0
		for i < len(b.src) && (b.src[i] == ' ' || b.src[i] == '\t' || ((item || outer > 0) && b.src[i] == '>')) {
			if b.src[i] == '>' do outer -= 1
			i += 1
		}
		if i >= len(b.src) do break
		c := b.src[i]
		if !item && c == '>' do return line_of(b, i), i + 1
		if item {
			n := 0
			for i + n < len(b.src) && n < 9 && b.src[i + n] >= '0' && b.src[i + n] <= '9' do n += 1
			if n > 0 && i + n < len(b.src) && (b.src[i + n] == '.' || b.src[i + n] == ')') do n += 1
			else if n == 0 && (c == '-' || c == '+' || c == '*') do n = 1
			else do n = 0
			if n > 0 && (i + n == len(b.src) || b.src[i + n] == ' ' || b.src[i + n] == '\t' || b.src[i + n] == '\n' || b.src[i + n] == '\r') do return line_of(b, i), i + n
		}
		// not here: the next line
		for i < len(b.src) && b.src[i] != '\n' && b.src[i] != '\r' do i += 1
		for i < len(b.src) && (b.src[i] == '\n' || b.src[i] == '\r') do i += 1
	}
	return 0, at
}

// The first line after `after` with something on it that is not a link reference definition
// (else the first with one; `after` itself when there is none).
@(private = "file")
first_line_after :: proc(b: ^Builder, after: int) -> int {
	def := 0
	for l in after + 1 ..= len(b.line_starts) {
		s := stripped_line(b, l)
		if s == "" do continue
		if s[0] == '[' && strings.contains(s, "]:") {
			if def == 0 do def = l
			continue
		}
		return l
	}
	return def > 0 ? def : max(after, 1)
}

// ---- the document's memory ----

// A bump allocator over heap blocks: no locks, no frees one by one, and the
// latest allocation grows in place (the builders and arrays parsing grows).
// Blocks come zeroed and are never reused, so nothing needs zeroing.
Md_Arena :: struct {
	blocks: [dynamic][]u8, // heap
	cur:    []u8,
	used:   int,
	last:   int, // offset of the latest allocation in cur (-1 = none)
}

@(private = "file")
MD_ARENA_BLOCK :: 1 << 20

// The offset in block (from `used`) where an aligned allocation starts.
@(private = "file")
aligned_at :: proc(block: []u8, used, align: int) -> int {
	base := uintptr(raw_data(block))
	return int(mem.align_forward_uintptr(base + uintptr(used), uintptr(max(align, 1))) - base)
}

@(private = "file")
md_arena_alloc :: proc(a: ^Md_Arena, size, align: int) -> ([]u8, mem.Allocator_Error) {
	at := a.cur != nil ? aligned_at(a.cur, a.used, align) : 0
	if a.cur == nil || at + size > len(a.cur) {
		n := max(size + align, MD_ARENA_BLOCK)
		block := make([]u8, n, runtime.heap_allocator())
		if block == nil do return nil, .Out_Of_Memory
		if a.blocks.allocator.procedure == nil do a.blocks.allocator = runtime.heap_allocator()
		append(&a.blocks, block)
		p := aligned_at(block, 0, align)
		if size > MD_ARENA_BLOCK / 4 && a.cur != nil {
			// a big one keeps a block of its own; the current block stays current
			return block[p:p + size], nil
		}
		a.cur = block
		at = p
	}
	a.last = at
	a.used = at + size
	return a.cur[at:at + size], nil
}

md_arena_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	a := (^Md_Arena)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return md_arena_alloc(a, size, alignment)
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil do return md_arena_alloc(a, size, alignment)
		if size <= old_size do return mem.byte_slice(old_memory, size), nil
		// the latest allocation grows where it is when the block has room
		if a.cur != nil && a.last >= 0 && rawptr(&a.cur[a.last]) == old_memory && a.last + size <= len(a.cur) {
			a.used = a.last + size
			return a.cur[a.last:a.used], nil
		}
		b, err := md_arena_alloc(a, size, alignment)
		if err == nil do copy(b, mem.byte_slice(old_memory, old_size))
		return b, err
	case .Free:
		return nil, nil
	case .Free_All:
		md_arena_free_all(a)
		return nil, nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free_All, .Query_Features}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, .Mode_Not_Implemented
}

md_arena_free_all :: proc(a: ^Md_Arena) {
	for b in a.blocks do delete(b, runtime.heap_allocator())
	delete(a.blocks)
	a^ = {}
}

// ---- inlines ----

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
md_unlink :: proc(n: ^Md_Inline) {
	if n.prev != nil do n.prev.next = n.next
	else if n.parent != nil do n.parent.first = n.next
	if n.next != nil do n.next.prev = n.prev
	else if n.parent != nil do n.parent.last = n.prev
	n.prev, n.next, n.parent = nil, nil, nil
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

@(private = "file")
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

ascii_lower :: #force_inline proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
is_ascii_alnum :: #force_inline proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')}

// ---- entities ----

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

// ---- GFM autolinks (www., http://, https://, ftp://, e-mail) in text ----

@(private = "file")
gfm_autolinks :: proc(root: ^Md_Inline) {
	// the text nodes outside links first: linking changes the tree
	texts := make([dynamic]^Md_Inline, context.temp_allocator)
	w := md_walk(root)
	for c, entering in md_walk_next(&w) {
		if !entering do continue
		if c.kind == .Link || c.kind == .Image do md_walk_skip(&w)
		else if c.kind == .Text && may_autolink(c.text) do append(&texts, c)
	}
	for t in texts do autolink_text(t)
}

@(private = "file")
autolink_text :: proc(t: ^Md_Inline) {
	s := t.text
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
				url = prefix == "" ? s[start:end] : strings.concatenate({prefix, s[start:end]})
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
					url = strings.concatenate({"mailto:", s[ls:j]})
				}
			}
		}
		if start < 0 {
			i += 1
			continue
		}
		// split: before | link | after
		if start > 0 {
			before := new_inline(.Text)
			before.text = s[:start]
			insert_before(t, before)
		}
		l := new_inline(.Link)
		l.autolink = true
		l.url = url
		lt := new_inline(.Text)
		lt.text = s[start:end]
		md_append(l, lt)
		insert_before(t, l)
		s = s[end:]
		t.text = s
		i = 0
	}
	if len(t.text) == 0 do md_unlink(t)
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
