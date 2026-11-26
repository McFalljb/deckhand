package main

// Markdown characterisation: documents in tests/markdown/corpus/ parse to the tree pinned in the
// .golden file next to each (the HTML of markdown_html_test.odin, then every block with its source
// line and heading id, then every link and image). The tree is what the preview lays out, so a
// change here is a change the user sees. DECKHAND_MD_GOLDEN=write rewrites the files (then read
// the diff).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Corpus :: struct {
	name, md, golden: string,
}

@(private = "file")
CORPUS := [?]Corpus {
	{"blocks", #load("../tests/markdown/corpus/blocks.md", string), #load("../tests/markdown/corpus/blocks.golden", string)},
	{"inlines", #load("../tests/markdown/corpus/inlines.md", string), #load("../tests/markdown/corpus/inlines.golden", string)},
	{"safety", #load("../tests/markdown/corpus/safety.md", string), #load("../tests/markdown/corpus/safety.golden", string)},
}

// The tree as text: HTML, the blocks (depth, kind, line and what the preview reads off each), the links.
md_dump :: proc(doc: ^Md_Doc, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, md_html(doc, context.temp_allocator))
	strings.write_string(&sb, "---- blocks\n")
	dump_block :: proc(sb: ^strings.Builder, b: ^Md_Block, depth: int) {
		for _ in 0 ..< depth do strings.write_string(sb, "  ")
		fmt.sbprintf(sb, "%v line=%d", b.kind, b.line)
		#partial switch b.kind {
		case .Heading:    fmt.sbprintf(sb, " level=%d anchor=%q", b.level, b.anchor)
		case .List:       fmt.sbprintf(sb, " ordered=%v start=%d bullet=%q tight=%v", b.ordered, b.start, rune(b.bullet), b.tight)
		case .Item:       if b.task != 0 do fmt.sbprintf(sb, " task=%d", b.task)
		case .Code_Block: fmt.sbprintf(sb, " info=%q", b.info)
		case .Table:      fmt.sbprintf(sb, " aligns=%v", b.aligns)
		case .Table_Row:  if b.header do strings.write_string(sb, " header")
		case .Table_Cell: if b.align != .None do fmt.sbprintf(sb, " align=%v", b.align)
		}
		strings.write_byte(sb, '\n')
		for c in b.children do dump_block(sb, c, depth + 1)
	}
	dump_block(&sb, doc.root, 0)
	strings.write_string(&sb, "---- links\n")
	links :: proc(sb: ^strings.Builder, b: ^Md_Block) {
		if b.inl != nil {
			w := md_walk(b.inl)
			for n, entering in md_walk_next(&w) {
				if !entering || (n.kind != .Link && n.kind != .Image) do continue
				fmt.sbprintf(sb, "%v url=%q title=%q autolink=%v text=%q\n", n.kind, n.url, n.title, n.autolink, md_plain_text(n, context.temp_allocator))
			}
		}
		for c in b.children do links(sb, c)
	}
	links(&sb, doc.root)
	return strings.to_string(sb)
}

@(test)
markdown_corpus :: proc(t: ^testing.T) {
	write := os.get_env("DECKHAND_MD_GOLDEN", context.temp_allocator) == "write"
	for c in CORPUS {
		doc := md_parse(c.md)
		got := md_dump(doc, context.temp_allocator)
		md_free(doc)
		if write {
			_ = os.write_entire_file(fmt.tprintf("tests/markdown/corpus/%s.golden", c.name), transmute([]u8)got)
			continue
		}
		if got == c.golden do continue
		// the first line that differs, with a few around it
		a := strings.split_lines(c.golden, context.temp_allocator)
		b := strings.split_lines(got, context.temp_allocator)
		i := 0
		for i < len(a) && i < len(b) && a[i] == b[i] do i += 1
		lo, hi := max(i - 3, 0), i + 4
		testing.expectf(t, false, "%s.md: line %d of the dump differs\n--- want\n%s\n--- got\n%s", c.name, i + 1,
			strings.join(a[lo:min(hi, len(a))], "\n", context.temp_allocator), strings.join(b[lo:min(hi, len(b))], "\n", context.temp_allocator))
	}
}

// Source lines on other line endings and inputs: what the preview's scroll sync reads.
@(test)
markdown_block_lines :: proc(t: ^testing.T) {
	Case :: struct {
		md:    string,
		lines: []int, // the top-level blocks' lines
	}
	cases := []Case {
		{"# a\r\n\r\npara\r\n\r\n---\r\n", {1, 3, 5}},
		{"# a\rpara\r\r---\r", {1, 2, 4}},
		{"[r]: /u\n\n---\n\n- \n\n```\n```\n", {3, 5, 7}},
		{"x\n\n\n\n```\n\n\n```\n\n***\n", {1, 5, 10}},
		{"> ```\n> a\n> ```\n\n- - -\n", {1, 5}},
		{"text\x00nul\n\n# h\x00\n", {1, 3}},
		{"", {}},
		{"\n\n\n", {}},
	}
	for c in cases {
		doc := md_parse(c.md)
		got := make([dynamic]int, context.temp_allocator)
		for b in doc.root.children do append(&got, b.line)
		md_free(doc)
		testing.expectf(t, fmt.tprint(got[:]) == fmt.tprint(c.lines), "%q: lines %v, want %v", c.md, got[:], c.lines)
	}
}
