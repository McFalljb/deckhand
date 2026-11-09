package main

// The Markdown tab: a .md file drawn as a document (the preview), or its
// source. One tab kind (Markdown_Tab) whose runtime side is two things keyed
// by the tab id: a read-only Editor in `editors` (the source view, the find
// bar, the toolbar and following the file on disk all come from the editor)
// and an Md_View here (the parsed document, its layout, the scroll).
//
// The preview parses the editor's text (markdown.odin) whenever it changes,
// so a change on disk shows at once. Layout turns blocks and inlines into
// pieces (text runs, fills, task boxes) in document coordinates, once per
// width, text size and document; drawing touches only the visible ones.
// Code blocks are coloured by the editor's tree-sitter highlighting; a
// fenced block whose language has a renderer (MD_FENCE_RENDERERS) is drawn
// by it, or labelled while it has none (mermaid: "diagram (coming soon)").
// Images are never fetched: their alt text shows. Links: http(s) and mailto
// open in the browser, relative .md files in a Markdown tab (other files in
// the editor), #anchors scroll to the heading.

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"
import sgl "../vendor/sokol-odin/sokol/gl"


// ---- fenced code renderers ----

// A fenced block's language with a renderer of its own (diagrams). render
// draws the block into the layout and returns where it ends; nil (or false)
// shows it as a code block labelled `label`.
Md_Fence_Renderer :: struct {
	lang:   string, // the info string's first word, lower case
	label:  string,
	render: proc(L: ^Md_Layout, code: string, x, w, y: f32) -> (y_end: f32, ok: bool),
}

MD_FENCE_RENDERERS := [?]Md_Fence_Renderer {
	{lang = "mermaid", label = "diagram (coming soon)"}, // step 2: flowcharts and sequence diagrams
}

md_fence_renderer :: proc(info: string) -> ^Md_Fence_Renderer {
	word := info
	for i in 0 ..< len(word) do if word[i] == ' ' || word[i] == '\t' {
		word = word[:i]
		break
	}
	for &r in MD_FENCE_RENDERERS do if len(r.lang) == len(word) && has_prefix_lower(word, r.lang) do return &r
	return nil
}

@(private = "file")
has_prefix_lower :: proc(s, lower: string) -> bool {
	if len(s) < len(lower) do return false
	for i in 0 ..< len(lower) do if ascii_lower(s[i]) != lower[i] do return false
	return true
}

// The highlighting language for a fence's info string (a name or an
// extension: go, js, ts, py, sh…), nil = plain.
md_code_language :: proc(info: string) -> ^Language {
	word := info
	for i in 0 ..< len(word) do if word[i] == ' ' || word[i] == '\t' || word[i] == '{' || word[i] == ',' {
		word = word[:i]
		break
	}
	if word == "" do return nil
	name := strings.to_lower(word, context.temp_allocator)
	switch name {
	case "golang":                          name = "go"
	case "js", "jsx", "mjs", "cjs", "node": name = "javascript"
	case "ts":                              name = "typescript"
	case "py", "python3":                   name = "python"
	case "sh", "bash", "zsh", "console", "shell-session", "shellscript": name = "shell"
	case "rs":                              name = "rust"
	case "md":                              name = "markdown"
	case "yml":                             name = "yaml"
	case "h":                               name = "c"
	}
	if l := language_by_name(name); l != nil do return l
	return language_for_path(strings.concatenate({"x.", name}, context.temp_allocator))
}

// ---- layout model ----

Md_Ink :: enum u8 {
	Text,
	Secondary, // block quotes
	Muted, // list markers, labels, image alt text
	Link,
	Syntax, // a code block's token colour (tok)
	Rule, // borders and rules
	Code_Bg,
	Head_Bg, // a table's header row
	Quote_Bar,
}

Md_Piece_Kind :: enum u8 {
	Text,
	Fill,
	Check, // a task item's box (checked: done)
}

Md_Piece :: struct {
	kind:    Md_Piece_Kind,
	ink:     Md_Ink,
	tok:     Syntax_Token,
	font:    Font_Kind,
	bold:    bool,
	italic:  bool,
	strike:  bool,
	code:    bool, // a code span: a fill goes under it
	checked: bool,
	scale:   f32,
	x, y:    f32, // document px; text: its line box
	w, h:    f32,
	base:    f32, // text: the baseline, from y
	text:    string,
	link:    i32, // into links (-1 = none)
	find:    i32, // text: where it starts in plain (-1 = not searchable: markers, labels)
}


Md_Layout :: struct {
	arena:   Md_Arena,
	alloc:   runtime.Allocator,
	pieces:  [dynamic]Md_Piece, // by y (stable)
	bottom:  [dynamic]f32, // the largest piece bottom up to each index
	texts:   [dynamic]i32, // searchable text pieces, by their offset in plain
	links:   [dynamic]string,
	plain:   strings.Builder, // the text as shown, for find
	anchors: map[string]f32, // heading ids
	blocks:  [dynamic][2]f32, // (source line, y) of every block, in document order
	height:  f32,
}

Md_View :: struct {
	tab_id:   u64,
	doc:      ^Md_Doc,
	doc_gen:  u64, // the editor text's generation it was parsed from
	parsed:   bool,
	lay:      Md_Layout,
	laid:     bool,
	lay_key:  [4]f32, // width, UI and mono px, dpi
	lay_doc:  u64, // doc_gen laid out
	serial:   u64, // bumped by every layout (find keys on it)
	scroll:   f32, // document px at the top of the pane
	area:     [4]f32, // the pane at the last draw (framebuffer px)
	hover:    i32, // the link under the pointer (-1)
	pressed:  i32, // the link the button went down on (-1): it follows if the button comes up on it
	want:     string, // a heading id to scroll to once laid out (owned)
	want_line: int, // or a source line
	notice:   string, // a link that could not be followed (owned)
}

md_views: map[u64]^Md_View

md_view_of :: proc(tab_id: u64) -> ^Md_View {return md_views[tab_id] or_else nil}

// The view of a Markdown tab showing its preview (nil: not one, or showing the source).
md_preview :: proc(tab_id: u64) -> ^Md_View {
	v := md_view_of(tab_id)
	if v == nil do return nil
	_, tab, _ := find_tab(tab_id)
	if tab == nil do return nil
	mt, is := tab.kind.(core.Markdown_Tab)
	if !is || mt.source do return nil
	if e := editor_of(tab_id); e == nil || e.refused != "" do return nil
	return v
}

// The current tab's Markdown view and editor (nil: another kind of tab).
md_active :: proc() -> (^Md_View, ^Editor, ^core.Tab) {return md_of_pane(core.focused_pane())}

// The Markdown tab pane p shows: its view, editor and tab (all nil for another kind).
md_of_pane :: proc(p: ^core.Pane) -> (^Md_View, ^Editor, ^core.Tab) {
	tab := core.pane_shown(p)
	if tab == nil do return nil, nil, nil
	if _, is := tab.kind.(core.Markdown_Tab); !is do return nil, nil, nil
	v := md_view_of(tab.id)
	e := editor_of(tab.id)
	if v == nil || e == nil do return nil, nil, nil
	return v, e, tab
}

// The runtime side of a Markdown tab: its read-only editor and its view.
md_view_new :: proc(tab_id: u64, path: string) -> ^Md_View {
	e := editor_new(tab_id, path)
	e.readonly = true
	e.always_readonly = true
	e.wrap = true
	v := new(Md_View)
	v.tab_id = tab_id
	v.hover = -1
	v.pressed = -1
	md_views[tab_id] = v
	return v
}

// Frees a tab's Markdown view (the tab closed); its editor goes with editor_drop.
md_drop :: proc(tab_id: u64) {
	v := md_view_of(tab_id)
	if v == nil do return
	md_free(v.doc)
	lay_free(&v.lay)
	delete(v.want)
	delete(v.notice)
	free(v)
	delete_key(&md_views, tab_id)
}

@(private = "file")
set_notice :: proc(v: ^Md_View, s: string) {
	delete(v.notice)
	v.notice = strings.clone(s)
	app.redraw = true
}

// Parses the editor's text again when it changed (a reload from disk).
@(private = "file")
md_sync :: proc(v: ^Md_View, e: ^Editor) {
	if v.parsed && v.doc_gen == e.gen do return
	// the source view's highlighting follows too (editor_tick redraws while it is stale)
	if e.sx.stale do syntax_reparse(&e.sx, &e.buf)
	md_free(v.doc)
	v.doc = md_parse(tb_text(&e.buf, context.temp_allocator))
	v.doc_gen = e.gen
	v.parsed = true
}

// ---- layout ----

lay_free :: proc(L: ^Md_Layout) {
	md_arena_free_all(&L.arena)
	L^ = {}
}

@(private = "file")
lay_reset :: proc(L: ^Md_Layout) {
	lay_free(L)
	L.alloc = runtime.Allocator{procedure = md_arena_proc, data = &L.arena}
	L.pieces = make([dynamic]Md_Piece, L.alloc)
	L.bottom = make([dynamic]f32, L.alloc)
	L.texts = make([dynamic]i32, L.alloc)
	L.links = make([dynamic]string, L.alloc)
	L.plain = strings.builder_make(L.alloc)
	L.anchors = make(map[string]f32, L.alloc)
	L.blocks = make([dynamic][2]f32, L.alloc)
}

Md_Style :: struct {
	font:   Font_Kind,
	bold:   bool,
	italic: bool,
	strike: bool,
	code:   bool,
	scale:  f32,
	ink:    Md_Ink,
	link:   i32,
}

@(private = "file")
body_style :: proc(ink: Md_Ink) -> Md_Style {return {font = .UI, scale = MD_BODY_SCALE, ink = ink, link = -1}}

// The width of s in a style (framebuffer px).
md_measure :: proc(s: string, st: Md_Style) -> f32 {
	if s == "" do return 0
	ri := text_run_scaled(s, st.font, st.bold, st.italic, st.scale) // before indexing: it may append
	return font.runs[ri].width
}

// A style's line: its height and the baseline within it.
@(private = "file")
style_line :: proc(st: Md_Style) -> (asc, h: f32) {
	set := &font.sets[st.font]
	h0 := set.line_h * st.scale
	h = math.round(h0 * MD_LINE)
	asc = math.round(set.baseline * st.scale + (h - h0) / 2)
	return
}

// Inline text into lines: words are placed greedily; a word wider than the
// line is cut between characters. Consecutive words of one text node on one
// line share a piece.
@(private = "file")
Lines :: struct {
	L:          ^Md_Layout,
	dry:        bool, // measure only (table columns): no pieces
	x0, w:      f32,
	y:          f32, // the current line's top
	cx:         f32, // pen, from x0
	first:      int, // the current line's first piece
	asc, below: f32, // the tallest ascent on the line and the deepest part below the baseline
	align:      Md_Align,
	space:      bool, // whitespace before the next word
	brk:        bool, // a break opportunity before the next word (whitespace, also when already added to cx)
	unit:       int, // the piece where the unbreakable run being placed starts (-1: none)
	unit_off:   int, // where in that piece's text
	sep:        bool, // plain text needs a separator before the next piece
	last:       int, // the piece the next word may extend (-1)
	node:       ^Md_Inline,
	last_start: int, // where that piece starts in node.text
	last_end:   int, // where it ends
	last_style: Md_Style,
	empty:      Md_Style, // the style of an empty line's height
	widest:     f32, // widest line
	word_max:   f32, // widest unbreakable run (dry: a table column's least width)
	run_w:      f32, // the width of the run being placed
}

@(private = "file")
end_line :: proc(lb: ^Lines) {
	settle(lb)
	asc, below := lb.asc, lb.below
	if asc == 0 && below == 0 {
		a, h := style_line(lb.empty)
		asc, below = a, h - a
	}
	lh := asc + below
	if !lb.dry {
		shift: f32 = 0
		switch lb.align {
		case .Center: shift = math.round(max(lb.w - lb.cx, 0) / 2)
		case .Right:  shift = math.round(max(lb.w - lb.cx, 0))
		case .None, .Left:
		}
		n := len(lb.L.pieces)
		for i in lb.first ..< n {
			p := &lb.L.pieces[i]
			p.y = lb.y
			p.h = lh
			p.base = asc
			p.x += shift
			if p.code {
				// the span's box: its font's line around the shared baseline
				ca, ch := style_line({font = .Mono, scale = 1})
				ch0 := font.sets[.Mono].line_h
				pad := px(MD_CODE_INLINE_PAD)
				append(&lb.L.pieces, Md_Piece{kind = .Fill, ink = .Code_Bg, x = p.x - pad, y = lb.y + asc - (ca - (ch - ch0) / 2) - 1, w = p.w + 2 * pad, h = ch0 + 2, link = -1, find = -1})
			}
		}
	}
	lb.widest = max(lb.widest, lb.cx)
	lb.y += lh
	lb.cx = 0
	lb.first = len(lb.L.pieces)
	lb.asc, lb.below = 0, 0
	lb.last = -1
	lb.space = false
	lb.brk = false
	lb.unit = -1
	lb.unit_off = 0
}

// The piece being extended, measured whole: words measured one by one can
// add up to more than the shaped run (at 2x they do), so the pen moves back.
@(private = "file")
settle :: proc(lb: ^Lines) {
	if lb.dry || lb.last < 0 || lb.last != len(lb.L.pieces) - 1 do return
	p := &lb.L.pieces[lb.last]
	real := md_measure(p.text, {font = p.font, bold = p.bold, italic = p.italic, scale = p.scale})
	lb.cx += real - p.w
	p.w = real
}

// A word glued to the run before it (no space: "**Atlas**,", "(`x`)") does
// not fit: the whole run moves to a new line, splitting the piece it starts in.
@(private = "file")
carry_run :: proc(lb: ^Lines) -> bool {
	L := lb.L
	u, off := lb.unit, lb.unit_off
	if lb.dry || u < lb.first || (u == lb.first && off == 0) || u >= len(L.pieces) do return false
	moved := make([dynamic]Md_Piece, context.temp_allocator)
	append(&moved, ..L.pieces[u:])
	last := lb.last
	resize(&L.pieces, u)
	if off > 0 {
		// the piece keeps its words before the run; the run's part moves
		p := moved[0]
		head := strings.trim_right(p.text[:off], " \t")
		st := Md_Style{font = p.font, bold = p.bold, italic = p.italic, scale = p.scale}
		h := p
		h.text = head
		h.w = md_measure(head, st)
		append(&L.pieces, h)
		moved[0].text = p.text[off:]
		moved[0].x = p.x + md_measure(p.text[:off], st)
		moved[0].w = md_measure(moved[0].text, st)
		if p.find >= 0 do moved[0].find = p.find + i32(off)
		if last == u do lb.last_start += off
		u += 1 // indices of moved pieces after the split
		if last >= u - 1 do last += 1
	}
	end := lb.x0
	for p in L.pieces[lb.first:] do if p.kind == .Text do end = max(end, p.x + p.w)
	lb.cx = end - lb.x0
	lb.last = -1
	end_line(lb)
	dx := lb.x0 - moved[0].x
	for &p in moved {
		p.x += dx
		asc, h := style_line({font = p.font, bold = p.bold, italic = p.italic, scale = p.scale})
		lb.asc = max(lb.asc, asc)
		lb.below = max(lb.below, h - asc)
		lb.cx = max(lb.cx, p.x + p.w - lb.x0)
		append(&L.pieces, p)
	}
	lb.unit, lb.unit_off = lb.first, 0
	if last >= u do lb.last = lb.first + last - u
	return true
}

@(private = "file")
same_style :: proc(a, b: Md_Style) -> bool {return a == b}

@(private = "file")
add_word :: proc(lb: ^Lines, node: ^Md_Inline, a, b: int, st: Md_Style, searchable := true) {
	word := node.text[a:b]
	ww := md_measure(word, st)
	lb.run_w = lb.brk || lb.space || lb.cx == 0 ? ww : lb.run_w + ww
	lb.word_max = max(lb.word_max, lb.run_w)
	sp: f32 = 0
	if lb.space && lb.cx > 0 do sp = md_measure(" ", st)
	if lb.cx > 0 && lb.cx + sp + ww > lb.w {
		settle(lb)
		if lb.cx + sp + ww > lb.w && !(!lb.brk && carry_run(lb) && lb.cx + ww <= lb.w) {
			end_line(lb)
			lb.sep = true
			sp = 0
		}
	}
	if lb.cx == 0 && ww > lb.w && len(word) > 1 {
		// longer than a line: cut between characters, at the clusters of the
		// word's one shaped run (shaping each rest again is quadratic)
		cuts := word_cuts(word, lb.w, st)
		at := a
		for c, i in cuts {
			if i > 0 do end_line(lb)
			place(lb, node, at, a + c, st, 0, md_measure(node.text[at:a + c], st), searchable)
			at = a + c
		}
		return
	}
	place(lb, node, a, b, st, sp, ww, searchable)
}

// Where a word wider than a line ends each line (byte offsets, the last is
// len(word)): one walk over the clusters of its shaped run; a line holds at
// least one character.
@(private = "file")
word_cuts :: proc(word: string, w: f32, st: Md_Style) -> []int {
	ri := text_run_scaled(word, st.font, st.bold, st.italic, st.scale)
	r := font.runs[ri]
	cuts := make([dynamic]int, context.temp_allocator)
	start_x: f32 = 0
	start_b := 0
	for g in font.run_glyphs[r.first:][:r.count] {
		c := int(g.cluster)
		if c > start_b && g.x + g.advance - start_x > w {
			append(&cuts, c)
			start_b, start_x = c, g.x
		}
	}
	append(&cuts, len(word))
	return cuts[:]
}

@(private = "file")
place :: proc(lb: ^Lines, node: ^Md_Inline, a, b: int, st: Md_Style, sp, ww: f32, searchable: bool) {
	asc, h := style_line(st)
	lb.asc = max(lb.asc, asc)
	lb.below = max(lb.below, h - asc)
	if lb.dry {
		lb.cx += sp + ww
		lb.space = false
		lb.brk = false
		return
	}
	L := lb.L
	if lb.last >= 0 && lb.node == node && same_style(lb.last_style, st) && searchable {
		if lb.brk {
			// a new run inside the piece
			lb.unit = lb.last
			lb.unit_off = a - lb.last_start
		}
		p := &L.pieces[lb.last]
		p.text = node.text[lb.last_start:b]
		p.w = lb.x0 + lb.cx + sp + ww - p.x
		strings.write_string(&L.plain, node.text[lb.last_end:b])
	} else {
		settle(lb)
		if lb.brk || lb.cx == 0 do lb.unit, lb.unit_off = len(L.pieces), 0
		find: i32 = -1
		if searchable {
			if (lb.sep || sp > 0) && strings.builder_len(L.plain) > 0 {
				last := L.plain.buf[strings.builder_len(L.plain) - 1]
				if last != ' ' && last != '\n' do strings.write_byte(&L.plain, ' ')
			}
			find = i32(strings.builder_len(L.plain))
			strings.write_string(&L.plain, node.text[a:b])
			lb.sep = false
		}
		append(&L.pieces, Md_Piece{kind = .Text, ink = st.ink, font = st.font, bold = st.bold, italic = st.italic, strike = st.strike, code = st.code, scale = st.scale, x = lb.x0 + lb.cx + sp, w = ww, text = node.text[a:b], link = st.link, find = find})
		lb.last = searchable ? len(L.pieces) - 1 : -1
		lb.last_start = a
		lb.last_style = st
	}
	lb.node = node
	lb.last_end = b
	lb.cx += sp + ww
	lb.space = false
	lb.brk = false
}

// The words of a text node.
@(private = "file")
add_text :: proc(lb: ^Lines, node: ^Md_Inline, st: Md_Style) {
	s := node.text
	i := 0
	for i < len(s) {
		if s[i] == ' ' || s[i] == '\t' || s[i] == '\n' {
			lb.space = true
			lb.brk = true
			lb.sep = true
			i += 1
			continue
		}
		j := i
		for j < len(s) && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' do j += 1
		add_word(lb, node, i, j, st)
		i = j
	}
}

// Lays out inlines from y in [x, x + w): returns the bottom.
@(private = "file")
lay_inlines :: proc(L: ^Md_Layout, root: ^Md_Inline, x, w, y: f32, st0: Md_Style, align: Md_Align = .None, dry := false) -> (bottom: f32, lb: Lines) {
	lb = Lines{L = L, dry = dry, x0 = x, w = max(w, px(40)), y = y, first = len(L.pieces), align = align, last = -1, unit = -1, empty = st0}
	if root == nil do return y, lb
	stack := make([dynamic]Md_Style, context.temp_allocator)
	st := st0
	w := md_walk(root)
	for n, entering in md_walk_next(&w) {
		if !entering {
			if len(stack) > 0 do st = pop(&stack)
			continue
		}
		switch n.kind {
		case .Root:
		case .Text:
			add_text(&lb, n, st)
		case .Softbreak:
			lb.space = true
			lb.brk = true
			lb.sep = true
		case .Linebreak:
			end_line(&lb)
			lb.sep = true
		case .Code:
			c := st
			c.font, c.scale, c.code, c.bold = .Mono, 1, true, false
			if lb.space && lb.cx > 0 do lb.cx += md_measure(" ", st)
			lb.space = false
			add_text(&lb, n, c)
		case .Html:
			// <br> breaks the line; other tags are not shown
			if has_prefix_lower(n.text, "<br") do end_line(&lb)
		case .Emph, .Strong, .Strike, .Link, .Image:
			append(&stack, st)
			#partial switch n.kind {
			case .Emph:   st.italic = true
			case .Strong: st.bold = true
			case .Strike: st.strike = true
			case .Link:
				st.ink = .Link
				if !dry {
					append(&L.links, n.url)
					st.link = i32(len(L.links) - 1)
				}
			case .Image:
				// never fetched: its alt text, marked as an image
				st.ink, st.italic = .Muted, true
				icon := Md_Inline{kind = .Text, text = "🖼"}
				if lb.space && lb.cx > 0 do lb.cx += md_measure(" ", st)
				lb.space = false
				add_word(&lb, &icon, 0, len(icon.text), st, searchable = false)
				lb.space = true
			}
		}
	}
	if lb.cx > 0 || lb.asc > 0 do end_line(&lb)
	return lb.y, lb
}

@(private = "file")
Ctx :: struct {
	ink:   Md_Ink,
	tight: bool, // in a tight list's item
	depth: int, // lists around
}

@(private = "file")
fill :: proc(L: ^Md_Layout, ink: Md_Ink, x, y, w, h: f32) -> int {
	append(&L.pieces, Md_Piece{kind = .Fill, ink = ink, x = x, y = y, w = w, h = h, link = -1, find = -1})
	return len(L.pieces) - 1
}

@(private = "file")
label :: proc(L: ^Md_Layout, text: string, x, y: f32, st: Md_Style) -> f32 {
	asc, h := style_line(st)
	append(&L.pieces, Md_Piece{kind = .Text, ink = st.ink, font = st.font, bold = st.bold, scale = st.scale, x = x, y = y, w = md_measure(text, st), h = h, base = asc, text = text, link = -1, find = -1})
	return h
}

@(private = "file")
end_block_text :: proc(L: ^Md_Layout) {
	n := strings.builder_len(L.plain)
	if n > 0 && L.plain.buf[n - 1] != '\n' do strings.write_byte(&L.plain, '\n')
}

@(private = "file")
lay_children :: proc(L: ^Md_Layout, b: ^Md_Block, x, w, y: f32, ctx: Ctx) -> f32 {
	y := y
	shown := 0
	for c in b.children {
		if shown > 0 {
			if c.kind == .Heading do y += px(MD_HEADING_GAP)
			else do y += ctx.tight ? px(MD_GAP_TIGHT) : px(MD_GAP)
		}
		y0 := y
		y = lay_block(L, c, x, w, y, ctx)
		if y > y0 do shown += 1
	}
	return y
}

@(private = "file")
lay_block :: proc(L: ^Md_Layout, b: ^Md_Block, x, w, y: f32, ctx: Ctx) -> f32 {
	append(&L.blocks, [2]f32{f32(b.line), y})
	y := y
	switch b.kind {
	case .Document, .Item, .Table_Row, .Table_Cell:
		y = lay_children(L, b, x, w, y, ctx)
	case .Paragraph:
		y, _ = lay_inlines(L, b.inl, x, w, y, body_style(ctx.ink))
		end_block_text(L)
	case .Heading:
		st := body_style(b.level == 6 ? .Muted : ctx.ink)
		st.bold = true
		st.scale = MD_BODY_SCALE * MD_HEADING_SCALE[clamp(int(b.level), 1, 6)]
		if b.anchor != "" do L.anchors[b.anchor] = y
		y, _ = lay_inlines(L, b.inl, x, w, y, st)
		end_block_text(L)
		if b.level <= 2 {
			y += px(SP_1)
			fill(L, .Rule, x, y, w, max(1, px(core.BORDER_W)))
			y += max(1, px(core.BORDER_W))
		}
	case .Thematic_Break:
		y += px(SP_2)
		fill(L, .Rule, x, y, w, max(1, px(2)))
		y += max(1, px(2)) + px(SP_2)
	case .Code_Block:
		y = lay_code(L, b, x, w, y)
	case .Html_Block:
		text := strip_html(b.text, L.alloc)
		if text != "" {
			root := new(Md_Inline, L.alloc)
			root.kind = .Root
			t := new(Md_Inline, L.alloc)
			t.kind = .Text
			t.text = text
			md_append(root, t)
			y, _ = lay_inlines(L, root, x, w, y, body_style(.Muted))
			end_block_text(L)
		}
	case .Block_Quote:
		indent := px(MD_QUOTE_INDENT)
		bar := fill(L, .Quote_Bar, x, y, max(1, px(MD_QUOTE_BAR)), 0)
		c := ctx
		c.ink = .Secondary
		c.tight = false
		y = lay_children(L, b, x + indent, w - indent, y, c)
		L.pieces[bar].h = y - L.pieces[bar].y
	case .List:
		y = lay_list(L, b, x, w, y, ctx)
	case .Table:
		y = lay_table(L, b, x, w, y, ctx)
	}
	return y
}

@(private = "file")
lay_list :: proc(L: ^Md_Layout, b: ^Md_Block, x, w, y: f32, ctx: Ctx) -> f32 {
	y := y
	st := body_style(.Muted)
	marker_w := px(MD_INDENT)
	if b.ordered {
		last := b.start + len(b.children) - 1
		marker_w = max(marker_w, md_measure(fmt.tprintf("%d%c", last, rune(b.bullet)), st) + px(SP_2))
	}
	c := ctx
	c.tight = b.tight
	c.depth = ctx.depth + 1
	bullets := [3]string{"•", "◦", "▪"}
	for item, i in b.children {
		if i > 0 do y += b.tight ? px(MD_GAP_TIGHT) : px(MD_GAP)
		first := len(L.pieces)
		y0 := y
		append(&L.blocks, [2]f32{f32(item.line), y})
		y = lay_children(L, item, x + marker_w, w - marker_w, y, c)
		// the marker sits on the item's first line
		line_y, line_h, base := y0, f32(0), f32(0)
		found := false
		for k in first ..< len(L.pieces) do if L.pieces[k].kind == .Text {
			p := L.pieces[k]
			line_y, line_h, base = p.y, p.h, p.base
			found = true
			break
		}
		if !found {
			asc, h := style_line(body_style(ctx.ink))
			line_h, base = h, asc
			if y == y0 do y += h
		}
		if item.task != 0 {
			s := px(MD_CHECK)
			append(&L.pieces, Md_Piece{kind = .Check, checked = item.task == 2, x = x + marker_w - s - px(SP_2), y = line_y + math.round((line_h - s) / 2), w = s, h = s, link = -1, find = -1})
		} else {
			text := b.ordered ? fmt.aprintf("%d%c", b.start + i, rune(b.bullet), allocator = L.alloc) : bullets[ctx.depth % 3]
			mw := md_measure(text, st)
			asc, h := style_line(st)
			append(&L.pieces, Md_Piece{kind = .Text, ink = .Muted, font = st.font, scale = st.scale, x = x + marker_w - px(SP_2) - mw, y = line_y, w = mw, h = max(h, line_h), base = base > 0 ? base : asc, text = text, link = -1, find = -1})
		}
	}
	return y
}

@(private = "file")
lay_code :: proc(L: ^Md_Layout, b: ^Md_Block, x, w, y: f32) -> f32 {
	r := md_fence_renderer(b.info)
	if r != nil && r.render != nil {
		if y2, ok := r.render(L, b.text, x, w, y); ok do return y2
	}
	pad := px(MD_CODE_PAD)
	bg := fill(L, .Code_Bg, x, y, w, 0)
	cy := y + pad
	if r != nil {
		// no renderer yet: a labelled code block
		cy += label(L, r.label, x + pad, cy, {font = .UI_Small, scale = 1, ink = .Muted, link = -1}) + px(SP_1)
	}
	code, toks := code_of(b)
	lh := math.round(font.cell_h + px(EDITOR_LINE_PAD))
	base := math.round((lh - font.cell_h) / 2) + font.baseline
	cols := max(int((w - 2 * pad) / font.cell_w), 8)
	at := 0
	for at < len(code) {
		e := strings.index_byte(code[at:], '\n')
		le := e < 0 ? len(code) : at + e
		// rows of at most cols columns
		rs := at
		for {
			col := 0
			re := rs
			for re < le {
				r, n := utf8.decode_rune_in_string(code[re:le])
				cw := rune_cols(r)
				if col + cw > cols && re > rs do break
				col += cw
				re += n
			}
			// runs of one token
			k := rs
			cx := x + pad
			for k < re {
				t := toks != nil ? toks[k] : Syntax_Token.Plain
				j := k + 1
				for j < re && (toks == nil || toks[j] == t) do j += 1
				seg := code[k:j]
				find := i32(strings.builder_len(L.plain))
				strings.write_string(&L.plain, seg)
				sw := f32(utf8.rune_count_in_string(seg)) * font.cell_w
				for r in seg do if rune_cols(r) == 2 do sw += font.cell_w
				if strings.trim_space(seg) != "" do append(&L.pieces, Md_Piece{kind = .Text, ink = .Syntax, tok = t, font = .Mono, scale = 1, x = cx, y = cy, w = sw, h = lh, base = base, text = seg, link = -1, find = find})
				cx += sw
				k = j
			}
			cy += lh
			if re >= le do break
			rs = re
		}
		strings.write_byte(&L.plain, '\n')
		at = le + 1
	}
	cy += pad
	L.pieces[bg].h = cy - y
	return cy
}

// Code blocks highlighted with tree-sitter so far (tests).
md_highlights: int

// A code block's text (tabs expanded) and tokens, made once per document
// (in its arena): a layout per resize does not run tree-sitter again.
Md_Code :: struct {
	code: string,
	toks: []Syntax_Token,
}

// The document md_layout lays out (code_of keeps its blocks' highlighting).
@(private = "file")
lay_doc: ^Md_Doc

@(private = "file")
code_of :: proc(b: ^Md_Block) -> (string, []Syntax_Token) {
	d := lay_doc
	if d == nil do return b.text, nil
	if d.code == nil do d.code = make(map[^Md_Block]Md_Code, d.alloc)
	if c, ok := d.code[b]; ok do return c.code, c.toks
	code := b.text
	if strings.index_byte(code, '\t') >= 0 do code = expand_tabs(code, d.alloc)
	toks := highlight(md_code_language(b.info), code, d.alloc)
	d.code[b] = {code, toks}
	return code, toks
}

// Tabs to spaces (every 4 columns), for a code block's text.
@(private = "file")
expand_tabs :: proc(s: string, alloc: runtime.Allocator) -> string {
	sb := strings.builder_make(alloc)
	col := 0
	for r in s {
		switch r {
		case '\t':
			n := EDITOR_TAB_WIDTH - col % EDITOR_TAB_WIDTH
			for _ in 0 ..< n do strings.write_byte(&sb, ' ')
			col += n
		case '\n':
			strings.write_byte(&sb, '\n')
			col = 0
		case:
			strings.write_rune(&sb, r)
			col += 1
		}
	}
	return strings.to_string(sb)
}

// Token per byte of code (the editor's tree-sitter highlighting), nil = plain.
@(private = "file")
highlight :: proc(lang: ^Language, code: string, alloc: runtime.Allocator) -> []Syntax_Token {
	if lang == nil || code == "" || len(code) > SYNTAX_MAX_BYTES do return nil
	md_highlights += 1
	buf: Text_Buffer
	data := make([]u8, len(code))
	copy(data, code)
	tb_init(&buf, data)
	defer tb_destroy(&buf)
	sx: Syntax
	syntax_open(&sx, lang, &buf)
	defer syntax_close(&sx)
	scratch: [dynamic]u8
	defer delete(scratch)
	toks := syntax_tokens(&sx, &buf, 0, len(code), &scratch)
	if toks == nil do return nil
	out := make([]Syntax_Token, len(code), alloc)
	copy(out, toks)
	return out
}

// An HTML block's text without its tags (comments and all), entities
// decoded, runs of whitespace as one space.
@(private = "file")
strip_html :: proc(s: string, alloc: runtime.Allocator) -> string {
	sb := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if strings.has_prefix(s[i:], "<!--") {
			e := strings.index(s[i + 4:], "-->")
			i = e < 0 ? len(s) : i + 4 + e + 3
			continue
		}
		if s[i] == '<' {
			e := strings.index_byte(s[i:], '>')
			if e < 0 {
				// no '>' after this one: no tag in the rest either (scanning again per '<' is quadratic)
				strings.write_string(&sb, s[i:])
				break
			}
			if e > 0 {
				if has_prefix_lower(s[i:], "<br") || has_prefix_lower(s[i:], "<p") || has_prefix_lower(s[i:], "</p") do strings.write_byte(&sb, ' ')
				i += e + 1
				continue
			}
		}
		strings.write_byte(&sb, s[i])
		i += 1
	}
	text := md_decode_entities(strings.to_string(sb), context.temp_allocator)
	out := strings.builder_make(alloc)
	space := false
	for r in text {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			space = strings.builder_len(out) > 0
			continue
		}
		if space do strings.write_byte(&out, ' ')
		space = false
		strings.write_rune(&out, r)
	}
	return strings.to_string(out)
}

@(private = "file")
lay_table :: proc(L: ^Md_Layout, b: ^Md_Block, x, w, y: f32, ctx: Ctx) -> f32 {
	n := len(b.aligns)
	if n == 0 do return y
	pad := px(MD_CELL_PAD)
	line := max(1, px(core.BORDER_W))
	nat := make([]f32, n, context.temp_allocator)
	mins := make([]f32, n, context.temp_allocator)
	for row in b.children {
		for cell, ci in row.children {
			st := body_style(ctx.ink)
			st.bold = row.header
			_, lb := lay_inlines(L, cell.inl, 0, 1 << 20, 0, st, .None, dry = true)
			nat[ci] = max(nat[ci], lb.widest)
			mins[ci] = max(mins[ci], min(lb.word_max, px(160)))
		}
	}
	cols := make([]f32, n, context.temp_allocator)
	total, total_min: f32
	for i in 0 ..< n {
		total += nat[i] + 2 * pad
		total_min += mins[i] + 2 * pad
	}
	avail := w - line
	if total <= avail {
		for i in 0 ..< n do cols[i] = nat[i] + 2 * pad
	} else if total_min >= avail {
		for i in 0 ..< n do cols[i] = max((mins[i] + 2 * pad) * avail / total_min, 2 * pad + px(8))
	} else {
		extra := avail - total_min
		want := total - total_min
		for i in 0 ..< n do cols[i] = mins[i] + 2 * pad + (want > 0 ? (nat[i] - mins[i]) * extra / want : 0)
	}
	table_w: f32 = line
	for c in cols do table_w += c
	y := y
	top := y
	for row in b.children {
		append(&L.blocks, [2]f32{f32(row.line), y})
		row_h: f32 = 0
		head_bg := -1
		if row.header do head_bg = fill(L, .Head_Bg, x, y, table_w, 0)
		fill(L, .Rule, x, y, table_w, line)
		cx := x + line
		for cell, ci in row.children {
			st := body_style(ctx.ink)
			st.bold = row.header
			bottom, _ := lay_inlines(L, cell.inl, cx + pad, cols[ci] - 2 * pad, y + line + pad, st, cell.align)
			end_block_text(L)
			row_h = max(row_h, bottom - y + pad)
			cx += cols[ci]
		}
		if row_h == 0 do row_h = 2 * pad + line
		if head_bg >= 0 do L.pieces[head_bg].h = row_h
		y += row_h
	}
	fill(L, .Rule, x, y, table_w, line)
	y += line
	// the column lines
	cx := x
	for i in 0 ..= n {
		fill(L, .Rule, cx, top, line, y - top)
		if i < n do cx += cols[i]
	}
	return y
}

// Lays the document out for a pane `width` px wide.
md_layout :: proc(v: ^Md_View, width: f32) {
	L := &v.lay
	lay_reset(L)
	lay_doc = v.doc
	defer lay_doc = nil
	pad := width < px(600) ? px(SP_4) : px(MD_PAD_X)
	col := min(width - 2 * pad, px(MD_MAX_W))
	x := math.round(max(pad, (width - col) / 2))
	y := px(MD_PAD_Y)
	if v.doc != nil do y = lay_children(L, v.doc.root, x, col, y, {})
	L.height = y + px(MD_PAD_Y)
	slice.stable_sort_by(L.pieces[:], proc(a, b: Md_Piece) -> bool {return a.y < b.y})
	resize(&L.bottom, len(L.pieces))
	bot: f32 = 0
	for p, i in L.pieces {
		bot = max(bot, p.y + p.h)
		L.bottom[i] = bot
		if p.kind == .Text && p.find >= 0 do append(&L.texts, i32(i))
	}
	slice.sort_by(L.texts[:], proc(a, b: i32) -> bool {return a < b}) // indices first (stable base)
	pieces := L.pieces[:]
	context.user_ptr = &pieces
	slice.sort_by(L.texts[:], proc(a, b: i32) -> bool {
		ps := (^[]Md_Piece)(context.user_ptr)^
		return ps[a].find < ps[b].find
	})
	v.serial += 1
	v.laid = true
}

// ---- drawing ----

markdown_host := Tab_View {
	display = .Drawn,
	draw = proc(tab_id: u64, x, y, w, h: f32) {
		e := editor_of(tab_id)
		if e == nil do return
		v := md_preview(tab_id)
		if v == nil {
			editor_draw(e, x, y, w, h) // the source, or why the file cannot be shown
			return
		}
		md_draw(v, e, x, y, w, h)
	},
}

@(private = "file")
ink_color :: proc(p: Md_Piece, hovered: bool) -> core.Rgba {
	th := theme()
	switch p.ink {
	case .Text:      return th.text
	case .Secondary: return th.text_secondary
	case .Muted:     return th.text_muted
	case .Link:      return th.accent
	case .Syntax:    return p.tok == .Plain ? th.text : editor_colors().syntax[p.tok]
	case .Rule:      return th.border
	case .Code_Bg:   return mix(th.bg_app, th.text, 0.07)
	case .Head_Bg:   return mix(th.bg_app, th.text, 0.04)
	case .Quote_Bar: return mix(th.bg_app, th.text, 0.22)
	}
	return th.text
}

// The view's pane height that scrolls (the notice line takes the bottom).
@(private = "file")
md_scroll_max :: proc(v: ^Md_View, h: f32) -> f32 {return max(v.lay.height - h, 0)}

// The first piece whose bottom reaches y (pieces by y; bottoms rise).
@(private = "file")
first_piece_from :: proc(L: ^Md_Layout, y: f32) -> int {
	lo, hi := 0, len(L.bottom)
	for lo < hi {
		mid := (lo + hi) / 2
		if L.bottom[mid] < y do lo = mid + 1
		else do hi = mid
	}
	return lo
}

md_ensure_layout :: proc(v: ^Md_View, e: ^Editor, w: f32) {
	md_sync(v, e)
	key := [4]f32{w, font.sets[.UI].px, font.sets[.Mono].px, app.dpi}
	if !v.laid || key != v.lay_key || v.lay_doc != v.doc_gen {
		// keep the same text at the top across a relayout
		line := v.laid && v.scroll > 0 ? md_line_at(v, v.scroll + px(SP_2)) : -1
		md_layout(v, w)
		v.lay_key = key
		v.lay_doc = v.doc_gen
		if line > 0 && v.want == "" && v.want_line == 0 do v.scroll = md_y_of_line(v, line)
	}
	if v.want != "" {
		if y, ok := v.lay.anchors[v.want]; ok do v.scroll = max(y - px(SP_2), 0)
		else do set_notice(v, fmt.tprintf("No heading #%s", v.want))
		delete(v.want)
		v.want = ""
	}
	if v.want_line > 0 {
		v.scroll = md_y_of_line(v, v.want_line)
		v.want_line = 0
	}
}

// The source line of the block at document y (the last block starting at or above it).
md_line_at :: proc(v: ^Md_View, y: f32) -> int {
	line := 1
	for b in v.lay.blocks {
		if b[1] > y + 1 do break
		line = int(b[0])
	}
	return line
}

// Where the block at (or last before) a source line starts.
md_y_of_line :: proc(v: ^Md_View, line: int) -> f32 {
	y: f32 = 0
	best := -1
	for b in v.lay.blocks do if int(b[0]) <= line && int(b[0]) >= best {
		best = int(b[0])
		y = b[1]
	}
	return max(y - px(SP_2), 0)
}

md_draw :: proc(v: ^Md_View, e: ^Editor, x, y, w, h: f32) {
	th := theme()
	draw_rect(x, y, w, h, th.bg_app)
	md_ensure_layout(v, e, w)
	v.area = {x, y, w, h}
	L := &v.lay
	v.scroll = clamp(v.scroll, 0, md_scroll_max(v, h))
	if e.bar == .Find || e.bar == .Replace do md_find_update(v, e)
	top := v.scroll
	bottom := top + h
	ox, oy := x, y - top
	md_scissor(x, y, w, h)
	i0 := first_piece_from(L, top)
	// fills, task boxes, find matches, then text
	for i := i0; i < len(L.pieces); i += 1 {
		p := L.pieces[i]
		if p.y > bottom do break
		if p.y + p.h < top do continue
		#partial switch p.kind {
		case .Fill:
			draw_rect(ox + p.x, oy + p.y, p.w, p.h, ink_color(p, false))
		case .Check:
			bx, by := ox + p.x, oy + p.y
			b := max(1, px(1))
			if p.checked {
				draw_rect(bx, by, p.w, p.h, th.accent)
				draw_text(bx + (p.w - text_width("✓", .UI_Small, bold = true)) / 2, by + (p.h - text_line_height(.UI_Small)) / 2, "✓", th.text_on_accent, .UI_Small, bold = true)
			} else {
				col := th.text_muted
				draw_rect(bx, by, p.w, b, col)
				draw_rect(bx, by + p.h - b, p.w, b, col)
				draw_rect(bx, by, b, p.h, col)
				draw_rect(bx + p.w - b, by, b, p.h, col)
			}
		}
	}
	md_draw_matches(v, e, i0, ox, oy, bottom)
	for i := i0; i < len(L.pieces); i += 1 {
		p := L.pieces[i]
		if p.y > bottom do break
		if p.kind != .Text || p.y + p.h < top do continue
		hovered := p.link >= 0 && p.link == v.hover
		col := ink_color(p, hovered)
		ri := text_run_scaled(p.text, p.font, p.bold, p.italic, p.scale)
		bx := ox + p.x
		base := oy + p.y + p.base
		draw_run(ri, bx, base, col)
		if p.strike {
			m := font.sets[p.font].metrics
			draw_rect(bx, math.round(base - m.x_height * p.scale / 2), p.w, max(1, px(1)), col)
		}
		if hovered do draw_rect(bx, math.round(base + px(2)), p.w, max(1, px(1)), col)
	}
	// where the view is in the document
	if L.height > h {
		bar_h := max(h * h / L.height, px(24))
		bar_y := y + (h - bar_h) * (top / max(L.height - h, 1))
		draw_rect(x + w - px(5), bar_y, px(3), bar_h, with_alpha(th.text_muted, 0.5))
	}
	if n := v.notice != "" ? v.notice : md_disk_notice(e); n != "" {
		lh := text_line_height(.UI_Small) + px(SP_2)
		draw_rect(x, y + h - lh, w, lh, th.bg_elevated)
		draw_text(x + px(SP_3), y + h - lh + px(SP_1), n, v.notice != "" ? th.text_secondary : th.waiting, .UI_Small)
	}
	md_scissor(0, 0, 1 << 15, 1 << 15)
}

@(private = "file")
md_scissor :: proc(x, y, w, h: f32) {
	sgl.end()
	sgl.scissor_rect(i32(x), i32(y), i32(w), i32(h), true)
	sgl.begin_quads()
}

// ---- find (the editor's find bar, over the text as shown) ----

// The find bar's matches as offsets into the preview's text.
md_find_update :: proc(v: ^Md_View, e: ^Editor) {
	f := &e.find
	q := tf_text(&f.query)
	key := fmt.tprintf("md %v%v%s", f.case_sensitive, f.regex, q)
	if key == f.key && f.gen == v.serial do return
	delete(f.key)
	f.key = strings.clone(key)
	f.gen = v.serial
	keep := f.current
	find_matches(f, strings.to_string(v.lay.plain), q)
	// the current match: the first at or below the top of the view
	f.current = -1
	if len(f.matches) == 0 do return
	if keep >= 0 && keep < len(f.matches) {
		f.current = keep
		return
	}
	for m, i in f.matches {
		if pi := md_piece_of(v, m[0]); pi >= 0 && v.lay.pieces[pi].y >= v.scroll {
			f.current = i
			break
		}
	}
	if f.current < 0 do f.current = 0
}

// The next (dir > 0) or previous match, scrolled into view.
md_find_step :: proc(v: ^Md_View, e: ^Editor, dir: int) {
	if tf_text(&e.find.query) == "" do return
	md_find_update(v, e)
	f := &e.find
	if len(f.matches) == 0 do return
	n := len(f.matches)
	f.current = f.current < 0 ? (dir > 0 ? 0 : n - 1) : (f.current + dir + n) % n
	md_reveal_offset(v, f.matches[f.current][0])
	app.redraw = true
}

@(private = "file")
md_reveal_offset :: proc(v: ^Md_View, off: int) {
	pi := md_piece_of(v, off)
	if pi < 0 do return
	p := v.lay.pieces[pi]
	h := v.area[3]
	if p.y < v.scroll || p.y + p.h > v.scroll + h do v.scroll = max(p.y - h / 3, 0)
}

// The text piece holding plain offset off (-1 = none).
@(private = "file")
md_piece_of :: proc(v: ^Md_View, off: int) -> int {
	L := &v.lay
	lo, hi := 0, len(L.texts)
	for lo < hi {
		mid := (lo + hi) / 2
		if int(L.pieces[L.texts[mid]].find) <= off do lo = mid + 1
		else do hi = mid
	}
	if lo == 0 do return -1
	pi := int(L.texts[lo - 1])
	p := L.pieces[pi]
	if off > int(p.find) + len(p.text) do return -1
	return pi
}

@(private = "file")
md_draw_matches :: proc(v: ^Md_View, e: ^Editor, i0: int, ox, oy, bottom: f32) {
	f := &e.find
	if (e.bar != .Find && e.bar != .Replace) || len(f.matches) == 0 do return
	th := theme()
	ec := editor_colors()
	L := &v.lay
	for i := i0; i < len(L.pieces); i += 1 {
		p := L.pieces[i]
		if p.y > bottom do break
		if p.kind != .Text || p.find < 0 do continue
		ps, pe := int(p.find), int(p.find) + len(p.text)
		// the first match ending after the piece's start
		lo, hi := 0, len(f.matches)
		for lo < hi {
			mid := (lo + hi) / 2
			if f.matches[mid][1] <= ps do lo = mid + 1
			else do hi = mid
		}
		for k := lo; k < len(f.matches) && f.matches[k][0] < pe; k += 1 {
			a, b := max(f.matches[k][0], ps) - ps, min(f.matches[k][1], pe) - ps
			if b <= a do continue
			x0, x1 := md_piece_x(p, a), md_piece_x(p, b)
			draw_rect(ox + p.x + x0, oy + p.y, max(x1 - x0, 1), p.h, k == f.current ? th.selection : ec.find_match)
		}
	}
}

// Where byte n of a text piece is drawn, from its left edge.
// A code block's piece sits on the cell grid (wide characters: two cells);
// other text is shaped.
md_piece_x :: proc(p: Md_Piece, n: int) -> f32 {
	if p.ink == .Syntax {
		cols := 0
		for r in p.text[:n] do cols += rune_cols(r)
		return f32(cols) * font.cell_w
	}
	return md_measure(p.text[:n], {font = p.font, bold = p.bold, italic = p.italic, scale = p.scale})
}

// Whether the keyboard is the Markdown tab's now: no field has it (Atlas's
// terminal included), or its own find and go-to bar does.
md_takes_keys :: proc() -> bool {
	switch state.focus_widget {
	case "", "editor_find", "editor_replace", "editor_goto": return true
	}
	return false
}

// ---- input ----

// The link under a point (framebuffer px), -1 = none.
@(private = "file")
md_link_at :: proc(v: ^Md_View, mx, my: f32) -> i32 {
	a := v.area
	if mx < a[0] || mx >= a[0] + a[2] || my < a[1] || my >= a[1] + a[3] do return -1
	dx, dy := mx - a[0], my - a[1] + v.scroll
	L := &v.lay
	for i := first_piece_from(L, dy); i < len(L.pieces); i += 1 {
		p := L.pieces[i]
		if p.y > dy do break
		if p.link >= 0 && dx >= p.x && dx < p.x + p.w && dy >= p.y && dy < p.y + p.h do return p.link
	}
	return -1
}

@(private = "file")
over_pane :: proc(v: ^Md_View, mx, my: f32) -> bool {
	a := v.area
	if mx < a[0] || mx >= a[0] + a[2] || my < a[1] || my >= a[1] + a[3] do return false
	if state.home_open && inside(clay.ID("drawer"), mx, my) do return false
	return !palette_is_open() && !menu.open
}

// The preview's input: wheel and keys scroll, links follow, ⌘F/⌘G find,
// ⇧⌘V shows the source. True if consumed. In the source view only ⇧⌘V is
// taken here (the editor has the rest).
markdown_event :: proc(p: ^core.Pane, ev: ^sapp.Event) -> bool {
	v, e, tab := md_of_pane(p)
	if v == nil do return false
	mt := tab.kind.(core.Markdown_Tab)
	cmd := ev.modifiers & sapp.MODIFIER_SUPER != 0
	shift := ev.modifiers & sapp.MODIFIER_SHIFT != 0
	if ev.type == .KEY_DOWN && cmd && shift && ev.key_code == .V {
		if !md_takes_keys() do return false
		action_run("markdown_preview")
		return true
	}
	if mt.source || md_preview(tab.id) == nil do return false
	h := v.area[3]
	#partial switch ev.type {
	case .MOUSE_SCROLL:
		if !over_pane(v, ev.mouse_x, ev.mouse_y) do return false
		v.scroll = clamp(v.scroll - ev.scroll_y * px(MD_SCROLL_LINE), 0, md_scroll_max(v, h))
		app.redraw = true
		return true
	case .MOUSE_DOWN:
		v.pressed = -1
		if !over_pane(v, ev.mouse_x, ev.mouse_y) do return false
		if ev.mouse_button != .LEFT do return true
		if state.focus_widget != "" do ui_do(core.Set_Focus{""})
		if state.home_open && !state.layout.drawer_pinned do ui_do(core.Set_Home{open = false})
		// a link follows when the button comes up on it; ⌃-click is a right click
		v.pressed = ev.modifiers & sapp.MODIFIER_CTRL != 0 ? -1 : md_link_at(v, ev.mouse_x, ev.mouse_y)
		return true
	case .MOUSE_UP:
		l := v.pressed
		v.pressed = -1
		if l < 0 || ev.mouse_button != .LEFT do return false
		if ev.modifiers & sapp.MODIFIER_CTRL == 0 && md_link_at(v, ev.mouse_x, ev.mouse_y) == l do ui_do(core.Markdown_Follow{tab_id = tab.id, url = v.lay.links[l]})
		return true
	case .KEY_DOWN:
		if state.focus_widget != "" || menu.open do return false
		step := px(MD_SCROLL_LINE)
		page := max(h - step, step)
		#partial switch ev.key_code {
		case .F:
			if !cmd do return true
			open_bar(e, .Find)
		case .G:
			if !cmd do return true
			md_find_step(v, e, shift ? -1 : 1)
		case .ESCAPE:
			if e.bar != .None do close_bar(e)
			if v.notice != "" do set_notice(v, "")
		case .UP:        v.scroll -= cmd ? v.lay.height : step
		case .DOWN:      v.scroll += cmd ? v.lay.height : step
		case .PAGE_UP:   v.scroll -= page
		case .PAGE_DOWN: v.scroll += page
		case .SPACE:     v.scroll += shift ? -page : page
		case .HOME:      v.scroll = 0
		case .END:       v.scroll = v.lay.height
		case:
			return !cmd // other keys do nothing here; ⌘ shortcuts go on
		}
		v.scroll = clamp(v.scroll, 0, md_scroll_max(v, h))
		app.redraw = true
		return true
	case .CHAR, .KEY_UP:
		return state.focus_widget == "" && !cmd
	}
	return false
}

// The pointer moved: a link under it is underlined and the pointer becomes a hand.
markdown_hover :: proc(mx, my: f32) {
	v, _, tab := md_active()
	if v == nil || md_preview(tab.id) == nil do return
	l: i32 = -1
	if over_pane(v, mx, my) do l = md_link_at(v, mx, my)
	if l != v.hover {
		v.hover = l
		app.redraw = true
	}
	if l >= 0 && sapp.get_mouse_cursor() != .POINTING_HAND do sapp.set_mouse_cursor(.POINTING_HAND)
}

// Whether the shown tab is a Markdown preview (the editor stays out of its input).
md_preview_shown :: proc(p: ^core.Pane) -> bool {
	tab := core.pane_shown(p)
	return tab != nil && md_preview(tab.id) != nil
}

// ---- commands ----

@(private = "file")
md_tab :: proc(id: u64) -> (^core.Open_Session, ^core.Tab, ^Md_View) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	if _, is := tab.kind.(core.Markdown_Tab); !is do return nil, nil, nil
	return s, tab, md_view_of(id)
}

// The window's part of the Markdown commands: the preview (the core checked the caller, the file
// and the tab, and keeps the tabs' records: tabhost_route.odin). tab_id: the tab markdown_open makes.
markdown_apply :: proc(cmd: core.Command, caller: core.Caller, tab_id: u64 = 0) -> (r: core.Result, changed: bool) {
	#partial switch c in cmd {
	case core.Markdown_Open:
		// the core resolved the path and the session; its record follows
		if tab_id == 0 do return core.fail("no tab for the file"), false
		v := md_view_of(tab_id)
		if v == nil do v = md_view_new(tab_id, c.path)
		if c.anchor != "" {
			delete(v.want)
			v.want = strings.clone(c.anchor)
		}
		app.redraw = true
		return {ok = true, created_id = tab_id}, true
	case core.Markdown_Set_View:
		_, tab, v := md_tab(c.tab_id)
		if tab == nil || v == nil do return core.fail("no such Markdown tab"), false
		mt := &tab.kind.(core.Markdown_Tab)
		if mt.source == c.source do return {ok = true}, false
		e := editor_of(tab.id)
		if e != nil {
			// the same place in the other view
			if c.source {
				if v.laid do ed_goto(e, md_line_at(v, v.scroll + px(SP_2)), 1)
				e.top = max(tb_line_of(&e.buf, e.cursor) - 1, 0)
				e.top_sub, e.frac = 0, 0
				e.follow = false
			} else {
				v.want_line = e.top + 1
			}
			// the find bar's matches are for the other view's text
			delete(e.find.key)
			e.find.key = ""
		}
		app.redraw = true
		return {ok = true}, true // the core sets the record's view
	case core.Markdown_Scroll:
		_, tab, v := md_tab(c.tab_id)
		if tab == nil || v == nil do return core.fail("no such Markdown tab"), false
		if c.anchor != "" {
			a := strings.trim_prefix(c.anchor, "#")
			if v.laid {
				if _, ok := v.lay.anchors[a]; !ok do return core.fail("no such heading"), false
			}
			delete(v.want)
			v.want = strings.clone(a)
		} else if c.line > 0 {
			v.want_line = c.line
		} else do return core.fail("anchor or line is needed"), false
		app.redraw = true
		return {ok = true}, false
	case core.Markdown_Follow:
		s, tab, v := md_tab(c.tab_id)
		if tab == nil || v == nil do return core.fail("no such Markdown tab"), false
		known := false
		for l in v.lay.links do if l == c.url do known = true
		if !known && v.doc != nil && strings.has_prefix(c.url, "#") do known = strings.trim_prefix(c.url, "#") in v.doc.anchors
		if !known do return core.fail("not a link of this document"), false
		mt := tab.kind.(core.Markdown_Tab)
		return md_follow(v, s, mt.path, c, caller)
	}
	return core.fail("unknown command"), false
}

// A link: #anchor scrolls here; for the rest the window says what the link is and the core acts
// (tabhost_route.odin's markdown_follow_act): http(s) and mailto open in the browser (the user's
// click, or a call the user confirms), a relative or absolute path opens (.md in a Markdown tab,
// other files in the editor), a folder shows in Finder. Other schemes are not followed.
@(private = "file")
md_follow :: proc(v: ^Md_View, s: ^core.Open_Session, doc_path: string, c: core.Markdown_Follow, caller: core.Caller) -> (core.Result, bool) {
	url := c.url
	if strings.has_prefix(url, "#") {
		a := percent_decode(url[1:])
		if v.laid {
			if _, ok := v.lay.anchors[a]; !ok {
				set_notice(v, fmt.tprintf("No heading #%s", a))
				return core.fail("no such heading"), false
			}
		}
		delete(v.want)
		v.want = strings.clone(a)
		app.redraw = true
		return {ok = true}, false
	}
	if scheme, has := url_scheme(url); has {
		switch scheme {
		case "http", "https", "mailto":
			return {ok = true, data = `{"follow":"external"}`}, false // it leaves Deckhand: the core decides
		}
		set_notice(v, fmt.tprintf("Not opened: %s: links", scheme))
		return core.fail("only http, https and mailto links open"), false
	}
	p := url
	frag := ""
	if i := strings.index_byte(p, '#'); i >= 0 {
		frag = percent_decode(p[i + 1:])
		p = p[:i]
	}
	if i := strings.index_byte(p, '?'); i >= 0 do p = p[:i]
	p = percent_decode(p)
	if p == "" do return core.fail("empty link"), false
	if !filepath.is_abs(p) do p, _ = filepath.join({filepath.dir(doc_path), p}, context.temp_allocator)
	p, _ = filepath.clean(p, context.temp_allocator)
	kind := core.path_kind(p)
	if kind == .Missing {
		set_notice(v, fmt.tprintf("No such file: %s", url))
		return core.fail("no such file"), false
	}
	if kind == .Dir {
		fs_reveal(p)
		return {ok = true}, false
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"follow":"open","path":`)
	core.json_quote(&b, p)
	strings.write_string(&b, `,"anchor":`)
	core.json_quote(&b, frag)
	strings.write_byte(&b, '}')
	return {ok = true, data = strings.to_string(b)}, false
}

@(private = "file")
url_scheme :: proc(url: string) -> (string, bool) {
	for i in 0 ..< len(url) {
		c := url[i]
		if c == ':' do return i > 1 ? strings.to_lower(url[:i], context.temp_allocator) : "", i > 1
		if !(is_ascii_alnum(c) || c == '+' || c == '-' || c == '.') do return "", false
	}
	return "", false
}

@(private = "file")
percent_decode :: proc(s: string) -> string {
	if strings.index_byte(s, '%') < 0 do return s
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a' + 10)
		case 'A' ..= 'F': return int(c - 'A' + 10)
		}
		return -1
	}
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) && hex(s[i + 1]) >= 0 && hex(s[i + 2]) >= 0 {
			append(&out, u8(hex(s[i + 1]) * 16 + hex(s[i + 2])))
			i += 3
			continue
		}
		append(&out, s[i])
		i += 1
	}
	return string(out[:])
}

// A Markdown tab's own state for get_state (json_write.odin): the source
// line at the top of the preview, its links and headings, find matches
// (-1: the find bar is not open on the preview).
md_state_numbers :: proc(v: ^Md_View, tab_id: u64, source: bool) -> (line, links, headings, matches: int) {
	line = md_line_at(v, v.scroll + px(SP_2))
	links, headings, matches = len(v.lay.links), len(v.lay.anchors), -1
	if e := editor_of(tab_id); e != nil && !source && (e.bar == .Find || e.bar == .Replace) do matches = len(e.find.matches)
	return
}

// The file is gone or cannot be shown any more: the preview keeps the last
// text and says so ("" = the file is fine).
md_disk_notice :: proc(e: ^Editor) -> string {
	if e == nil do return ""
	if e.missing do return "Deleted on disk: this is the last version read"
	if e.disk_refused != "" do return fmt.tprintf("Changed on disk and cannot be shown (%s): this is the last version read", e.disk_refused)
	return ""
}

// What the preview shows (test scripts): its text, then labels, markers and the notices.
md_shown_text :: proc() -> string {
	v, e, _ := md_active()
	if v == nil || !v.laid do return ""
	sb := strings.builder_make(context.temp_allocator)
	if n := md_disk_notice(e); n != "" {
		strings.write_string(&sb, n)
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, strings.to_string(v.lay.plain))
	for p in v.lay.pieces do if p.kind == .Text && p.find < 0 {
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, p.text)
	}
	return strings.to_string(sb)
}

// The centre of the first piece showing text (framebuffer px), scrolled
// into view first (test scripts click links this way).
md_piece_point :: proc(text: string) -> (x, y: f32, ok: bool) {
	v, _, _ := md_active()
	if v == nil || !v.laid do return
	for p in v.lay.pieces do if p.kind == .Text && strings.contains(p.text, text) {
		h := v.area[3]
		if p.y < v.scroll || p.y + p.h > v.scroll + h do v.scroll = clamp(p.y - h / 3, 0, md_scroll_max(v, h))
		return v.area[0] + p.x + p.w / 2, v.area[1] + p.y - v.scroll + p.h / 2, true
	}
	return
}
