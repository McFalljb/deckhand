package main

// Markdown: our own CommonMark (0.31.2) parser with the GFM extensions the
// viewer needs (tables, task lists, strikethrough, autolinks). No
// dependencies. The Markdown tab (markdown_view.odin) lays the tree out and
// draws it; markdown_html.odin writes HTML for the tests.
//
// Two passes, as in the reference implementation (cmark):
//   1. blocks (this file): line by line, each line first continues the open
//      containers (block quotes, list items), then may open new blocks, and
//      its text goes to the deepest open block. Link reference definitions
//      are taken from paragraphs when they close.
//   2. inlines (markdown_inline.odin): the text of every paragraph, heading
//      and table cell, once every reference definition is known.
//
// Everything a document holds lives in its own arena: md_free drops it at
// once. Strings in the tree are slices of that arena (or of nothing else).
//
// Not handled (knowingly): the full HTML5 entity table (a common subset;
// unknown names stay literal), Unicode case folding beyond lower case for
// link labels, the GFM tagfilter, footnotes.

import "base:runtime"
import "core:mem"
import "core:strings"

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
	kind:            Md_Block_Kind,
	open:            bool,
	last_line_blank: bool,
	fenced:          bool, // code
	setext:          bool, // heading
	tight:           bool, // list
	ordered:         bool, // list, item
	header:          bool, // table row: the header
	level:           u8, // heading 1–6
	task:            u8, // item: 0 not a task, 1 open, 2 done
	html_type:       u8,
	fence_char:      u8,
	bullet:          u8, // list: '-', '+', '*'; ordered: the delimiter '.' or ')'
	align:           Md_Align, // table cell
	depth:           u16, // containers above it
	fence_len:       int,
	fence_offset:    int,
	marker_offset:   int, // item
	padding:         int, // item
	start:           int, // ordered list's first number
	line:            int, // first source line (1-based)
	end_line:        int, // last source line
	parent:          ^Md_Block,
	children:        [dynamic]^Md_Block,
	content:         strings.Builder, // raw text while parsing
	text:            string, // code and HTML blocks: the literal; others: inline source
	info:            string, // code: the info string
	inl:             ^Md_Inline, // paragraph, heading, cell: the inlines (a Root node)
	aligns:          []Md_Align, // table
	anchor:          string, // heading: its id for links (#section)
}

Md_Ref :: struct {
	url, title: string,
}

Md_Doc :: struct {
	arena:   Md_Arena,
	alloc:   runtime.Allocator,
	root:    ^Md_Block,
	refs:    map[string]Md_Ref,
	anchors: map[string]^Md_Block, // heading ids
	anchor_next: map[string]int, // the last -N given per id
	lines:   int,
	code:    map[^Md_Block]Md_Code, // code blocks highlighted for the preview (markdown_view.odin)
}

// Block quotes and lists nest at most this deep; a deeper marker is text.
// Keeps every walk over the tree shallow (no stack overflow on ">>>>…").
MD_MAX_DEPTH :: 48

@(private = "file")
TAB_STOP :: 4
@(private = "file")
CODE_INDENT :: 4

@(private = "file")
Md_Parser :: struct {
	doc:                    ^Md_Doc,
	line:                   string, // without its line ending
	line_no:                int,
	offset, column:         int,
	first_nonspace:         int,
	first_nonspace_column:  int,
	indent:                 int,
	blank:                  bool,
	partially_consumed_tab: bool,
	tip:                    ^Md_Block, // the deepest open block
	last_matched:           ^Md_Block, // the deepest block the line continued
	all_closed:             bool, // the blocks it did not continue are closed
}

// Parses text into a new document (free it with md_free). Never fails.
md_parse :: proc(text: string) -> ^Md_Doc {
	doc := new(Md_Doc)
	doc.alloc = runtime.Allocator{procedure = md_arena_proc, data = &doc.arena}
	context.allocator = doc.alloc
	doc.refs = make(map[string]Md_Ref)
	doc.anchors = make(map[string]^Md_Block)
	doc.anchor_next = make(map[string]int)
	src := text
	if strings.index_byte(src, 0) >= 0 { 	// NUL is replaced by U+FFFD
		src, _ = strings.replace_all(src, "\x00", "�")
	}
	p := Md_Parser{doc = doc}
	doc.root = new_block(&p, .Document, 1)
	p.tip = doc.root
	at := 0
	for at < len(src) {
		end := line_end(src, at)
		p.line = src[at:end]
		process_line(&p)
		if end < len(src) && src[end] == '\r' do end += 1
		if end < len(src) && src[end] == '\n' do end += 1
		at = end
	}
	for p.tip != nil do p.tip = finalize(&p, p.tip)
	doc.lines = p.line_no
	md_inlines(doc)
	return doc
}

md_free :: proc(doc: ^Md_Doc) {
	if doc == nil do return
	md_arena_free_all(&doc.arena)
	free(doc)
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

// ---- lines ----

@(private = "file")
line_end :: proc(s: string, at: int) -> int #no_bounds_check {
	i := max(at, 0)
	for i < len(s) && s[i] != '\n' && s[i] != '\r' do i += 1
	return min(i, len(s))
}

@(private = "file")
peek :: #force_inline proc(p: ^Md_Parser, at: int) -> u8 #no_bounds_check {return at >= 0 && at < len(p.line) ? p.line[at] : 0}

@(private = "file")
space_or_tab :: #force_inline proc(c: u8) -> bool {return c == ' ' || c == '\t'}

@(private = "file")
find_first_nonspace :: proc(p: ^Md_Parser) #no_bounds_check {
	chars_to_tab := TAB_STOP - (p.column % TAB_STOP)
	if p.first_nonspace <= p.offset {
		p.first_nonspace = p.offset
		p.first_nonspace_column = p.column
		for p.first_nonspace < len(p.line) {
			c := p.line[p.first_nonspace]
			if c == ' ' {
				p.first_nonspace += 1
				p.first_nonspace_column += 1
				chars_to_tab -= 1
				if chars_to_tab == 0 do chars_to_tab = TAB_STOP
			} else if c == '\t' {
				p.first_nonspace += 1
				p.first_nonspace_column += chars_to_tab
				chars_to_tab = TAB_STOP
			} else do break
		}
	}
	p.indent = p.first_nonspace_column - p.column
	p.blank = p.first_nonspace >= len(p.line)
}

// Moves the offset by count bytes (columns: count is columns, and a tab may
// be consumed partly).
@(private = "file")
advance_offset :: proc(p: ^Md_Parser, count: int, columns: bool) {
	count := count
	for count > 0 && p.offset < len(p.line) {
		c := p.line[p.offset]
		if c == '\t' {
			chars_to_tab := TAB_STOP - (p.column % TAB_STOP)
			if columns {
				p.partially_consumed_tab = chars_to_tab > count
				n := min(count, chars_to_tab)
				p.column += n
				if !p.partially_consumed_tab do p.offset += 1
				count -= n
			} else {
				p.partially_consumed_tab = false
				p.column += chars_to_tab
				p.offset += 1
				count -= 1
			}
		} else {
			p.partially_consumed_tab = false
			p.offset += 1
			p.column += 1
			count -= 1
		}
	}
}

@(private = "file")
add_line :: proc(p: ^Md_Parser, b: ^Md_Block) {
	if p.partially_consumed_tab {
		p.offset += 1 // the rest of the tab, as spaces
		chars_to_tab := TAB_STOP - (p.column % TAB_STOP)
		for _ in 0 ..< chars_to_tab do strings.write_byte(&b.content, ' ')
	}
	if p.offset < len(p.line) do strings.write_string(&b.content, p.line[p.offset:])
	strings.write_byte(&b.content, '\n')
}

// ---- blocks ----

@(private = "file")
new_block :: proc(p: ^Md_Parser, kind: Md_Block_Kind, line: int) -> ^Md_Block {
	b := new(Md_Block, p.doc.alloc)
	b.kind = kind
	b.open = true
	b.line = line
	b.end_line = line
	b.children = make([dynamic]^Md_Block, p.doc.alloc)
	b.content = strings.builder_make_none(p.doc.alloc)
	return b
}

@(private = "file")
can_contain :: proc(parent: Md_Block_Kind, child: Md_Block_Kind) -> bool {
	#partial switch parent {
	case .Document, .Block_Quote, .Item:
		return child != .Item && child != .Table_Row && child != .Table_Cell
	case .List:
		return child == .Item
	}
	return false
}

@(private = "file")
accepts_lines :: proc(k: Md_Block_Kind) -> bool {return k == .Paragraph || k == .Heading || k == .Code_Block}

// Closes the open blocks the current line did not continue (once).
@(private = "file")
close_unmatched :: proc(p: ^Md_Parser) {
	if p.all_closed do return
	for p.tip != p.last_matched do p.tip = finalize(p, p.tip)
	p.all_closed = true
}

@(private = "file")
add_child :: proc(p: ^Md_Parser, parent: ^Md_Block, kind: Md_Block_Kind) -> ^Md_Block {
	close_unmatched(p)
	parent := parent
	for !can_contain(parent.kind, kind) do parent = finalize(p, parent)
	b := new_block(p, kind, p.line_no)
	b.parent = parent
	b.depth = parent.depth + 1
	append(&parent.children, b)
	return b
}

@(private = "file")
last_child :: #force_inline proc(b: ^Md_Block) -> ^Md_Block {return len(b.children) > 0 ? b.children[len(b.children) - 1] : nil}

@(private = "file")
last_child_open :: #force_inline proc(b: ^Md_Block) -> bool {
	c := last_child(b)
	return c != nil && c.open
}

// Closes b; returns its parent.
@(private = "file")
finalize :: proc(p: ^Md_Parser, b: ^Md_Block) -> ^Md_Block {
	parent := b.parent
	b.open = false
	b.end_line = max(b.end_line, p.line_no - (b.kind == .Document ? 0 : 1), b.line)
	#partial switch b.kind {
	case .Paragraph:
		if !resolve_refs(p, b) {
			// only reference definitions: the paragraph goes
			if parent != nil && len(parent.children) > 0 && last_child(parent) == b do pop(&parent.children)
		}
	case .Code_Block:
		s := strings.to_string(b.content)
		if !b.fenced {
			// trailing blank lines go
			end := len(s)
			last := 0 // end of the last line with text
			i := 0
			for i < len(s) {
				j := i
				for j < len(s) && s[j] != '\n' do j += 1
				blank := true
				for k in i ..< j do if s[k] != ' ' && s[k] != '\t' do blank = false
				if !blank do last = min(j + 1, end)
				i = j + 1
			}
			b.text = s[:last]
		} else {
			nl := strings.index_byte(s, '\n')
			if nl < 0 do nl = len(s)
			info := trim_ws(s[:nl])
			b.info = md_unescape(info, p.doc.alloc)
			b.text = nl < len(s) ? s[nl + 1:] : ""
		}
	case .Html_Block:
		s := strings.to_string(b.content)
		// the trailing line ending stays (cmark keeps it); a blank-line end leaves none extra
		b.text = s
	case .List:
		b.tight = list_tight(b)
	case .Heading:
		b.text = strings.to_string(b.content)
	}
	return parent
}

@(private = "file")
ends_with_blank_line :: proc(b: ^Md_Block) -> bool {
	b := b
	for b != nil {
		if b.last_line_blank do return true
		if b.kind != .List && b.kind != .Item do return false
		b = last_child(b)
	}
	return false
}

@(private = "file")
list_tight :: proc(list: ^Md_Block) -> bool {
	for item, i in list.children {
		has_next := i + 1 < len(list.children)
		if item.last_line_blank && has_next do return false
		for sub, j in item.children {
			if (has_next || j + 1 < len(item.children)) && ends_with_blank_line(sub) do return false
		}
	}
	return true
}

// Takes link reference definitions off the start of a paragraph. False
// when nothing but definitions (and blanks) was in it.
@(private = "file")
resolve_refs :: proc(p: ^Md_Parser, b: ^Md_Block) -> bool {
	s := strings.to_string(b.content)
	for len(s) > 0 && s[0] == '[' {
		n := md_parse_reference(s, p.doc)
		if n == 0 do break
		s = s[n:]
	}
	b.text = s
	for i in 0 ..< len(s) do if s[i] != ' ' && s[i] != '\t' && s[i] != '\n' && s[i] != '\r' do return true
	return false
}

@(private = "file")
process_line :: proc(p: ^Md_Parser) {
	p.offset, p.column, p.first_nonspace, p.first_nonspace_column, p.indent = 0, 0, 0, 0, 0
	p.blank, p.partially_consumed_tab = false, false
	p.line_no += 1

	// 1. which open blocks does the line continue?
	all_matched := false
	should_continue := true
	container := p.doc.root
	matching: {
	for last_child_open(container) {
		container = last_child(container)
		find_first_nonspace(p)
		#partial switch container.kind {
		case .Block_Quote:
			if !(p.indent <= 3 && peek(p, p.first_nonspace) == '>') do break matching
			advance_offset(p, p.indent + 1, true)
			if space_or_tab(peek(p, p.offset)) do advance_offset(p, 1, true)
		case .Item:
			if p.indent >= container.marker_offset + container.padding {
				advance_offset(p, container.marker_offset + container.padding, true)
			} else if p.blank && len(container.children) > 0 {
				advance_offset(p, p.first_nonspace - p.offset, false)
			} else do break matching
		case .Code_Block:
			if !container.fenced {
				if p.indent >= CODE_INDENT do advance_offset(p, CODE_INDENT, true)
				else if p.blank do advance_offset(p, p.first_nonspace - p.offset, false)
				else do break matching
			} else {
				n := 0
				if p.indent <= 3 && peek(p, p.first_nonspace) == container.fence_char do n = close_fence_len(p.line, p.first_nonspace, container.fence_char)
				if n >= container.fence_len {
					should_continue = false // the closing fence: the line is done
					container.end_line = p.line_no
					p.tip = finalize(p, container)
					break matching
				}
				i := container.fence_offset
				for i > 0 && space_or_tab(peek(p, p.offset)) {
					advance_offset(p, 1, true)
					i -= 1
				}
			}
		case .Heading, .Thematic_Break:
			break matching
		case .Html_Block:
			if (container.html_type == 6 || container.html_type == 7) && p.blank do break matching
		case .Paragraph, .Table:
			if p.blank do break matching
		}
	}
	all_matched = true
	}
	if !all_matched && should_continue do container = container.parent
	if !should_continue do return
	last_matched := container
	p.last_matched = container
	p.all_closed = container == p.tip

	// 2. new blocks
	maybe_lazy := p.tip.kind == .Paragraph
	for container.kind != .Code_Block && container.kind != .Html_Block {
		find_first_nonspace(p)
		indented := p.indent >= CODE_INDENT
		c := peek(p, p.first_nonspace)
		ok := true
		if !indented && c == '>' && container.depth < MD_MAX_DEPTH {
			advance_offset(p, p.first_nonspace + 1 - p.offset, false)
			if space_or_tab(peek(p, p.offset)) do advance_offset(p, 1, true)
			container = add_child(p, container, .Block_Quote)
		} else if n := atx_start(p.line, p.first_nonspace); !indented && n > 0 {
			level := 0
			for peek(p, p.first_nonspace + level) == '#' do level += 1
			advance_offset(p, p.first_nonspace + n - p.offset, false)
			container = add_child(p, container, .Heading)
			container.level = u8(level)
		} else if n := open_fence_len(p.line, p.first_nonspace); !indented && n > 0 {
			container = add_child(p, container, .Code_Block)
			container.fenced = true
			container.fence_char = c
			container.fence_len = n
			container.fence_offset = p.first_nonspace - p.offset
			advance_offset(p, p.first_nonspace + n - p.offset, false)
		} else if t := html_block_start(p.line, p.first_nonspace, container.kind == .Paragraph); !indented && t > 0 {
			container = add_child(p, container, .Html_Block)
			container.html_type = u8(t)
		} else if lev := setext_level(p.line, p.first_nonspace); !indented && container.kind == .Paragraph && lev > 0 {
			if resolve_refs(p, container) {
				container.kind = .Heading
				container.level = u8(lev)
				container.setext = true
				// the heading's text: what is left of the paragraph
				s := container.text
				strings.builder_reset(&container.content)
				strings.write_string(&container.content, s)
				advance_offset(p, len(p.line) - p.offset, false)
			} else do ok = false
		} else if !indented && container.kind == .Paragraph && table_start(p, &container) {
			// the paragraph's last line was a table's header (table_start)
		} else if !indented && !(container.kind == .Paragraph && !all_matched) && thematic_break(p.line, p.first_nonspace) {
			container = add_child(p, container, .Thematic_Break)
			advance_offset(p, len(p.line) - p.offset, false)
		} else if (!indented || container.kind == .List) && p.indent < 4 && container.depth < MD_MAX_DEPTH - 1 && list_marker(p, container) {
			container = p.tip // list_marker added the item (and its list)
		} else if indented && !maybe_lazy && !p.blank {
			advance_offset(p, CODE_INDENT, true)
			container = add_child(p, container, .Code_Block)
		} else do ok = false
		if !ok do break
		p.tip = container
		if accepts_lines(container.kind) || container.kind == .Table do break
		maybe_lazy = false
	}

	// 3. the line's text
	find_first_nonspace(p)
	if p.blank && last_child(container) != nil do last_child(container).last_line_blank = true
	k := container.kind
	container.last_line_blank = p.blank && k != .Block_Quote && k != .Heading && k != .Thematic_Break && k != .Table && !(k == .Code_Block && container.fenced) && !(k == .Item && len(container.children) == 0 && container.line == p.line_no)
	for t := container; t.parent != nil; t = t.parent do t.parent.last_line_blank = false

	if p.tip != last_matched && container == last_matched && !p.blank && p.tip.kind == .Paragraph {
		add_line(p, p.tip) // a lazy continuation line
		return
	}
	close_unmatched(p)
	#partial switch container.kind {
	case .Code_Block:
		add_line(p, container)
	case .Html_Block:
		add_line(p, container)
		if html_block_ends(container.html_type, p.line[min(p.first_nonspace, len(p.line)):]) {
			container.end_line = p.line_no
			container = finalize(p, container)
		}
	case .Table:
		if !p.blank do table_row(p, container, p.line[p.first_nonspace:], false)
	case:
		if p.blank {
			// nothing
		} else if accepts_lines(container.kind) {
			line := p.line
			if container.kind == .Heading && !container.setext {
				p.line = chop_closing_hashes(p.line)
				p.first_nonspace = min(p.first_nonspace, len(p.line))
			}
			advance_offset(p, p.first_nonspace - p.offset, false)
			add_line(p, container)
			p.line = line
		} else {
			container = add_child(p, container, .Paragraph)
			advance_offset(p, p.first_nonspace - p.offset, false)
			add_line(p, container)
		}
	}
	p.tip = container
}

// ---- block starts ----

@(private = "file")
atx_start :: proc(line: string, at: int) -> int {
	i := at
	for i < len(line) && line[i] == '#' && i - at < 7 do i += 1
	n := i - at
	if n < 1 || n > 6 do return 0
	if i < len(line) && !space_or_tab(line[i]) do return 0
	for i < len(line) && space_or_tab(line[i]) do i += 1
	return i - at
}

// An ATX heading line without its closing sequence of #s.
@(private = "file")
chop_closing_hashes :: proc(line: string) -> string {
	s := trim_ws_right(line)
	n := len(s) - 1
	orig := n
	for n >= 0 && s[n] == '#' do n -= 1
	if n != orig && n >= 0 && space_or_tab(s[n]) do return trim_ws_right(s[:n])
	return s
}

@(private = "file")
open_fence_len :: proc(line: string, at: int) -> int {
	if at >= len(line) do return 0
	c := line[at]
	if c != '`' && c != '~' do return 0
	i := at
	for i < len(line) && line[i] == c do i += 1
	n := i - at
	if n < 3 do return 0
	if c == '`' && strings.index_byte(line[i:], '`') >= 0 do return 0 // a backtick fence's info has no backticks
	return n
}

@(private = "file")
close_fence_len :: proc(line: string, at: int, c: u8) -> int {
	i := at
	for i < len(line) && line[i] == c do i += 1
	n := i - at
	if n < 3 do return 0
	for i < len(line) && space_or_tab(line[i]) do i += 1
	return i == len(line) ? n : 0
}

@(private = "file")
setext_level :: proc(line: string, at: int) -> int {
	if at >= len(line) do return 0
	c := line[at]
	if c != '=' && c != '-' do return 0
	i := at
	for i < len(line) && line[i] == c do i += 1
	for i < len(line) && space_or_tab(line[i]) do i += 1
	if i != len(line) do return 0
	return c == '=' ? 1 : 2
}

@(private = "file")
thematic_break :: proc(line: string, at: int) -> bool {
	if at >= len(line) do return false
	c := line[at]
	if c != '*' && c != '-' && c != '_' do return false
	n := 0
	for i in at ..< len(line) {
		switch line[i] {
		case c:        n += 1
		case ' ', '\t':
		case:          return false
		}
	}
	return n >= 3
}

// A list marker at first_nonspace: adds the item (and a new list when the
// container is not a matching list). False when there is none.
@(private = "file")
list_marker :: proc(p: ^Md_Parser, container: ^Md_Block) -> bool {
	interrupts := container.kind == .Paragraph
	pos := p.first_nonspace
	c := peek(p, pos)
	ordered := false
	bullet: u8
	start := 0
	if c == '*' || c == '-' || c == '+' {
		pos += 1
		if !is_space_or_end(p, pos) do return false
		if interrupts {
			i := pos
			for space_or_tab(peek(p, i)) do i += 1
			if i >= len(p.line) do return false
		}
		bullet = c
	} else if c >= '0' && c <= '9' {
		digits := 0
		for digits < 9 && peek(p, pos) >= '0' && peek(p, pos) <= '9' {
			start = start * 10 + int(peek(p, pos) - '0')
			pos += 1
			digits += 1
		}
		if interrupts && start != 1 do return false
		d := peek(p, pos)
		if d != '.' && d != ')' do return false
		pos += 1
		if !is_space_or_end(p, pos) do return false
		if interrupts {
			i := pos
			for space_or_tab(peek(p, i)) do i += 1
			if i >= len(p.line) do return false
		}
		ordered = true
		bullet = d
	} else do return false
	matched := pos - p.first_nonspace

	// the item's content column
	advance_offset(p, p.first_nonspace + matched - p.offset, false)
	save_tab, save_offset, save_column := p.partially_consumed_tab, p.offset, p.column
	for p.column - save_column <= 5 && space_or_tab(peek(p, p.offset)) do advance_offset(p, 1, true)
	i := p.column - save_column
	padding: int
	if i >= 5 || i < 1 || p.offset >= len(p.line) {
		padding = matched + 1
		p.offset, p.column, p.partially_consumed_tab = save_offset, save_column, save_tab
		if i > 0 do advance_offset(p, 1, true)
	} else {
		padding = matched + i
	}
	marker_offset := p.indent

	list := container
	if container.kind != .List || container.ordered != ordered || container.bullet != bullet {
		list = add_child(p, container, .List)
		list.ordered = ordered
		list.bullet = bullet
		list.start = start
		list.marker_offset = marker_offset
		list.padding = padding
	}
	item := add_child(p, list, .Item)
	item.ordered = ordered
	item.bullet = bullet
	item.start = start
	item.marker_offset = marker_offset
	item.padding = padding
	p.tip = item
	return true
}

@(private = "file")
is_space_or_end :: proc(p: ^Md_Parser, at: int) -> bool {
	c := peek(p, at)
	return at >= len(p.line) || c == ' ' || c == '\t' || c == '\v' || c == '\f'
}

// ---- HTML blocks ----

@(private = "file")
HTML_BLOCK_TAGS := [?]string{"address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul"}

@(private = "file")
has_prefix_fold :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) do return false
	for i in 0 ..< len(prefix) do if ascii_lower(s[i]) != prefix[i] do return false
	return true
}

ascii_lower :: #force_inline proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}

// The HTML block type (1–7) starting at `at`, 0 if none. Type 7 cannot
// interrupt a paragraph.
@(private = "file")
html_block_start :: proc(line: string, at: int, in_paragraph: bool) -> int {
	if at >= len(line) || line[at] != '<' do return 0
	s := line[at:]
	for name in ([]string{"<script", "<pre", "<style", "<textarea"}) {
		if has_prefix_fold(s, name) {
			if len(s) == len(name) do return 1
			c := s[len(name)]
			if c == ' ' || c == '\t' || c == '>' do return 1
		}
	}
	if strings.has_prefix(s, "<!--") do return 2
	if strings.has_prefix(s, "<?") do return 3
	if len(s) > 2 && s[1] == '!' && is_ascii_letter(s[2]) do return 4
	if strings.has_prefix(s, "<![CDATA[") do return 5
	{
		i := 1
		if i < len(s) && s[i] == '/' do i += 1
		j := i
		for j < len(s) && (is_ascii_letter(s[j]) || (j > i && s[j] >= '0' && s[j] <= '9')) do j += 1
		if j > i {
			name := s[i:j]
			for t in HTML_BLOCK_TAGS {
				if len(t) == len(name) && has_prefix_fold(name, t) {
					if j == len(s) do return 6
					c := s[j]
					if c == ' ' || c == '\t' || c == '>' || (c == '/' && j + 1 < len(s) && s[j + 1] == '>') do return 6
				}
			}
		}
	}
	if in_paragraph do return 0
	n := md_scan_tag(s, 0, false)
	if n == 0 do return 0
	for k in n ..< len(s) do if !space_or_tab(s[k]) do return 0
	return 7
}

@(private = "file")
contains_fold :: proc(s, needle: string) -> bool {
	if len(needle) > len(s) do return false
	for i in 0 ..= len(s) - len(needle) do if has_prefix_fold(s[i:], needle) do return true
	return false
}

@(private = "file")
html_block_ends :: proc(t: u8, s: string) -> bool {
	switch t {
	case 1: return contains_fold(s, "</script>") || contains_fold(s, "</pre>") || contains_fold(s, "</style>") || contains_fold(s, "</textarea>")
	case 2: return strings.contains(s, "-->")
	case 3: return strings.contains(s, "?>")
	case 4: return strings.contains(s, ">")
	case 5: return strings.contains(s, "]]>")
	}
	return false
}

is_ascii_letter :: #force_inline proc(c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')}
is_ascii_alnum :: #force_inline proc(c: u8) -> bool {return is_ascii_letter(c) || (c >= '0' && c <= '9')}

// ---- GFM tables ----

// Splits a table row into its cells' text: outer pipes optional, `\|` is a
// pipe inside a cell (temp allocator for the slice; cells are slices of
// row, or arena copies when they held `\|`).
@(private = "file")
split_row :: proc(row: string, alloc: runtime.Allocator) -> []string {
	s := trim_ws(row)
	if len(s) > 0 && s[0] == '|' do s = s[1:]
	if len(s) > 0 && s[len(s) - 1] == '|' && (len(s) < 2 || s[len(s) - 2] != '\\') do s = s[:len(s) - 1]
	cells := make([dynamic]string, context.temp_allocator)
	start := 0
	escaped := false
	i := 0
	for i <= len(s) {
		if i == len(s) || (s[i] == '|' && !escaped) {
			cell := trim_ws(s[start:i])
			if strings.contains(cell, "\\|") do cell, _ = strings.replace_all(cell, "\\|", "|", alloc)
			append(&cells, cell)
			start = i + 1
			escaped = false
		} else {
			escaped = s[i] == '\\' && !escaped
		}
		i += 1
	}
	return cells[:]
}

// The current line as a table's delimiter row under the paragraph's last
// line (its header): the paragraph's earlier lines stay a paragraph.
@(private = "file")
table_start :: proc(p: ^Md_Parser, container: ^^Md_Block) -> bool {
	line := p.line[p.first_nonspace:]
	if strings.index_byte(line, '|') < 0 do return false
	delims := split_row(line, context.temp_allocator)
	if len(delims) == 0 do return false
	aligns := make([]Md_Align, len(delims), p.doc.alloc)
	for d, i in delims {
		if len(d) == 0 do return false
		s := d
		left := s[0] == ':'
		right := s[len(s) - 1] == ':'
		if left do s = s[1:]
		if right && len(s) > 0 do s = s[:len(s) - 1]
		if len(s) == 0 do return false
		for k in 0 ..< len(s) do if s[k] != '-' do return false
		aligns[i] = left && right ? .Center : (left ? .Left : (right ? .Right : .None))
	}
	para := container^
	content := strings.to_string(para.content)
	body := strings.trim_right(content, "\n") // (a short paragraph: the cut-set walk is cheap)
	ls := strings.last_index_byte(body, '\n') + 1
	header := body[ls:]
	if len(split_row(header, context.temp_allocator)) != len(delims) do return false
	header = strings.clone(header, p.doc.alloc)

	table: ^Md_Block
	if ls == 0 {
		para.kind = .Table // the paragraph was the header alone
		strings.builder_reset(&para.content)
		table = para
	} else {
		// the earlier lines stay a paragraph (closed now), the table follows it
		before := strings.clone(body[:ls], p.doc.alloc)
		strings.builder_reset(&para.content)
		strings.write_string(&para.content, before)
		parent := finalize(p, para) // (it goes if it held only definitions)
		table = add_child(p, parent, .Table)
		table.line = p.line_no - 1
	}
	table.aligns = aligns
	table_row(p, table, header, true)
	advance_offset(p, len(p.line) - p.offset, false)
	container^ = table
	return true
}

@(private = "file")
table_row :: proc(p: ^Md_Parser, table: ^Md_Block, line: string, header: bool) {
	cells := split_row(strings.clone(line, p.doc.alloc), p.doc.alloc) // the document keeps no slice of the caller's text
	row := new_block(p, .Table_Row, p.line_no)
	row.open = false
	row.header = header
	row.parent = table
	if header do row.line = p.line_no - 1
	for i in 0 ..< len(table.aligns) {
		cell := new_block(p, .Table_Cell, row.line)
		cell.open = false
		cell.parent = row
		cell.align = table.aligns[i]
		if i < len(cells) do cell.text = cells[i]
		append(&row.children, cell)
	}
	append(&table.children, row)
	table.end_line = p.line_no
}
