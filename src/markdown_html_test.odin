package main

// A Markdown document as HTML, in the reference implementation's format
// (cmark with --unsafe, plus cmark-gfm's tables, task items and <del>): the
// tests compare it with the CommonMark and GFM spec examples. Raw HTML is
// passed through as written.

import "core:strings"

md_html :: proc(doc: ^Md_Doc, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for b in doc.root.children do html_block(&sb, b, false)
	return strings.to_string(sb)
}

@(private = "file")
cr :: proc(sb: ^strings.Builder) {
	n := strings.builder_len(sb^)
	if n > 0 && sb.buf[n - 1] != '\n' do strings.write_byte(sb, '\n')
}

@(private = "file")
esc :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(sb, "&amp;")
		case '<': strings.write_string(sb, "&lt;")
		case '>': strings.write_string(sb, "&gt;")
		case '"': strings.write_string(sb, "&quot;")
		case:     strings.write_byte(sb, s[i])
		}
	}
}

// A URL for href/src: characters outside the safe set percent-encoded.
@(private = "file")
esc_href :: proc(sb: ^strings.Builder, s: string) {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case is_ascii_alnum(c), strings.index_byte("-_.+!*(),%#@?=;:/$~", c) >= 0:
			strings.write_byte(sb, c)
		case c == '&':
			strings.write_string(sb, "&amp;")
		case c == '\'':
			strings.write_string(sb, "&#x27;")
		case:
			strings.write_byte(sb, '%')
			strings.write_byte(sb, HEX[c >> 4])
			strings.write_byte(sb, HEX[c & 15])
		}
	}
}

@(private = "file")
html_block :: proc(sb: ^strings.Builder, b: ^Md_Block, tight: bool) {
	switch b.kind {
	case .Document:
		for c in b.children do html_block(sb, c, false)
	case .Block_Quote:
		cr(sb)
		strings.write_string(sb, "<blockquote>\n")
		for c in b.children do html_block(sb, c, false)
		cr(sb)
		strings.write_string(sb, "</blockquote>\n")
	case .List:
		cr(sb)
		if !b.ordered do strings.write_string(sb, "<ul>\n")
		else if b.start == 1 do strings.write_string(sb, "<ol>\n")
		else {
			strings.write_string(sb, "<ol start=\"")
			strings.write_int(sb, b.start)
			strings.write_string(sb, "\">\n")
		}
		for c in b.children do html_block(sb, c, b.tight)
		strings.write_string(sb, b.ordered ? "</ol>\n" : "</ul>\n")
	case .Item:
		cr(sb)
		strings.write_string(sb, "<li>")
		for c, i in b.children {
			if i == 0 && b.task != 0 && c.kind == .Paragraph {
				// the checkbox goes inside the first paragraph (loose) or first in the item (tight)
				if !tight {
					cr(sb)
					strings.write_string(sb, "<p>")
				}
				strings.write_string(sb, b.task == 2 ? "<input checked=\"\" disabled=\"\" type=\"checkbox\"> " : "<input disabled=\"\" type=\"checkbox\"> ")
				html_inlines(sb, c.inl)
				if !tight do strings.write_string(sb, "</p>\n")
				continue
			}
			html_block(sb, c, tight)
		}
		if b.task != 0 && len(b.children) == 0 do strings.write_string(sb, "<input disabled=\"\" type=\"checkbox\">")
		strings.write_string(sb, "</li>\n")
	case .Paragraph:
		if tight {
			html_inlines(sb, b.inl)
		} else {
			cr(sb)
			strings.write_string(sb, "<p>")
			html_inlines(sb, b.inl)
			strings.write_string(sb, "</p>\n")
		}
	case .Heading:
		cr(sb)
		strings.write_string(sb, "<h")
		strings.write_byte(sb, '0' + b.level)
		strings.write_byte(sb, '>')
		html_inlines(sb, b.inl)
		strings.write_string(sb, "</h")
		strings.write_byte(sb, '0' + b.level)
		strings.write_string(sb, ">\n")
	case .Thematic_Break:
		cr(sb)
		strings.write_string(sb, "<hr />\n")
	case .Code_Block:
		cr(sb)
		if b.info == "" {
			strings.write_string(sb, "<pre><code>")
		} else {
			lang := b.info
			for i in 0 ..< len(lang) do if lang[i] == ' ' || lang[i] == '\t' {
				lang = lang[:i]
				break
			}
			strings.write_string(sb, "<pre><code class=\"language-")
			esc(sb, lang)
			strings.write_string(sb, "\">")
		}
		esc(sb, b.text)
		strings.write_string(sb, "</code></pre>\n")
	case .Html_Block:
		cr(sb)
		strings.write_string(sb, b.text)
		cr(sb)
	case .Table:
		cr(sb)
		strings.write_string(sb, "<table>\n")
		body := false
		for row, i in b.children {
			if i == 0 do strings.write_string(sb, "<thead>\n")
			if i == 1 {
				strings.write_string(sb, "<tbody>\n")
				body = true
			}
			strings.write_string(sb, "<tr>\n")
			for cell in row.children {
				tag := row.header ? "th" : "td"
				strings.write_byte(sb, '<')
				strings.write_string(sb, tag)
				switch cell.align {
				case .None:
				case .Left:   strings.write_string(sb, " align=\"left\"")
				case .Center: strings.write_string(sb, " align=\"center\"")
				case .Right:  strings.write_string(sb, " align=\"right\"")
				}
				strings.write_byte(sb, '>')
				html_inlines(sb, cell.inl)
				strings.write_string(sb, "</")
				strings.write_string(sb, tag)
				strings.write_string(sb, ">\n")
			}
			strings.write_string(sb, "</tr>\n")
			if i == 0 do strings.write_string(sb, "</thead>\n")
		}
		if body do strings.write_string(sb, "</tbody>\n")
		strings.write_string(sb, "</table>\n")
	case .Table_Row, .Table_Cell:
	}
}

@(private = "file")
html_inlines :: proc(sb: ^strings.Builder, root: ^Md_Inline) {
	if root == nil do return
	w := md_walk(root)
	for n, entering in md_walk_next(&w) {
		switch n.kind {
		case .Root:
		case .Text:
			esc(sb, n.text)
		case .Softbreak:
			strings.write_byte(sb, '\n')
		case .Linebreak:
			strings.write_string(sb, "<br />\n")
		case .Code:
			strings.write_string(sb, "<code>")
			esc(sb, n.text)
			strings.write_string(sb, "</code>")
		case .Html:
			strings.write_string(sb, n.text)
		case .Emph:
			strings.write_string(sb, entering ? "<em>" : "</em>")
		case .Strong:
			strings.write_string(sb, entering ? "<strong>" : "</strong>")
		case .Strike:
			strings.write_string(sb, entering ? "<del>" : "</del>")
		case .Link:
			if !entering {
				strings.write_string(sb, "</a>")
				continue
			}
			strings.write_string(sb, "<a href=\"")
			esc_href(sb, n.url)
			if n.title != "" {
				strings.write_string(sb, "\" title=\"")
				esc(sb, n.title)
			}
			strings.write_string(sb, "\">")
		case .Image:
			if !entering do continue
			strings.write_string(sb, "<img src=\"")
			esc_href(sb, n.url)
			strings.write_string(sb, "\" alt=\"")
			esc(sb, md_plain_text(n, context.temp_allocator))
			if n.title != "" {
				strings.write_string(sb, "\" title=\"")
				esc(sb, n.title)
			}
			strings.write_string(sb, "\" />")
			md_walk_skip(&w) // the alt text is written
		}
	}
}
