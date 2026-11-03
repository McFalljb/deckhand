package main

// Syntax highlighting with tree-sitter (vendor/tree-sitter, built into
// build/ts.a by build.sh). One parser and tree per editor; edits go into the
// tree with ts_tree_edit and it is reparsed incrementally before the next
// draw. Highlights come from each grammar's own queries/highlights.scm; the
// capture names map onto the look's syntax colours (theme.odin,
// Syntax_Token). Only the visible bytes are queried, and the result is
// cached until the tree or the visible range changes.
//
// Capture precedence: for the same bytes, the later capture wins (patterns
// are painted in the order tree-sitter reports them), except the catch-all
// `@variable`, which never paints (identifiers stay plain text). That reads
// both query styles the grammars use (catch-all first: C, JS, Python; last:
// Go). Predicates: #eq?, #not-eq?, #match?, #not-match?, #any-of?,
// #not-any-of? (others, like #lua-match? and #set!, are ignored).
//
// Not yet: injections (markdown code blocks, inline markdown, JS in HTML),
// locals (scope-aware variable colours).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:text/regex"
import "core:time"

foreign import tslib "../build/ts.a"

TS_Parser :: distinct rawptr
TS_Tree :: distinct rawptr
TS_Query :: distinct rawptr
TS_Query_Cursor :: distinct rawptr
TS_Language :: distinct rawptr

TS_Parse_State :: struct {
	payload:             rawptr,
	current_byte_offset: u32,
	has_error:           bool,
}
TS_Parse_Options :: struct {
	payload:           rawptr,
	progress_callback: proc "c" (state: ^TS_Parse_State) -> bool, // true: stop
}
TS_Point :: struct {
	row, column: u32,
}
TS_Node :: struct {
	ctx:  [4]u32,
	id:   rawptr,
	tree: rawptr,
}
TS_Input_Edit :: struct {
	start_byte, old_end_byte, new_end_byte:     u32,
	start_point, old_end_point, new_end_point: TS_Point,
}
TS_Input :: struct {
	payload:  rawptr,
	read:     proc "c" (payload: rawptr, byte_index: u32, position: TS_Point, bytes_read: ^u32) -> [^]u8,
	encoding: c.int, // 0 = UTF-8
	decode:   rawptr,
}
TS_Query_Capture :: struct {
	node:  TS_Node,
	index: u32,
}
TS_Query_Match :: struct {
	id:            u32,
	pattern_index: u16,
	capture_count: u16,
	captures:      [^]TS_Query_Capture,
}
TS_Predicate_Step :: struct {
	type:     c.int, // 0 done, 1 capture, 2 string
	value_id: u32,
}

@(default_calling_convention = "c")
foreign tslib {
	ts_parser_new :: proc() -> TS_Parser ---
	ts_parser_delete :: proc(p: TS_Parser) ---
	ts_parser_set_language :: proc(p: TS_Parser, l: TS_Language) -> bool ---
	ts_parser_parse :: proc(p: TS_Parser, old: TS_Tree, input: TS_Input) -> TS_Tree ---
	ts_parser_parse_with_options :: proc(p: TS_Parser, old: TS_Tree, input: TS_Input, options: TS_Parse_Options) -> TS_Tree ---
	ts_tree_delete :: proc(t: TS_Tree) ---
	ts_tree_edit :: proc(t: TS_Tree, edit: ^TS_Input_Edit) ---
	ts_tree_root_node :: proc(t: TS_Tree) -> TS_Node ---
	ts_node_start_byte :: proc(n: TS_Node) -> u32 ---
	ts_node_end_byte :: proc(n: TS_Node) -> u32 ---
	ts_node_has_error :: proc(n: TS_Node) -> bool ---
	ts_query_new :: proc(l: TS_Language, source: [^]u8, len: u32, error_offset: ^u32, error_type: ^c.int) -> TS_Query ---
	ts_query_delete :: proc(q: TS_Query) ---
	ts_query_pattern_count :: proc(q: TS_Query) -> u32 ---
	ts_query_capture_count :: proc(q: TS_Query) -> u32 ---
	ts_query_capture_name_for_id :: proc(q: TS_Query, id: u32, len: ^u32) -> [^]u8 ---
	ts_query_string_value_for_id :: proc(q: TS_Query, id: u32, len: ^u32) -> [^]u8 ---
	ts_query_predicates_for_pattern :: proc(q: TS_Query, pattern: u32, step_count: ^u32) -> [^]TS_Predicate_Step ---
	ts_query_cursor_new :: proc() -> TS_Query_Cursor ---
	ts_query_cursor_delete :: proc(qc: TS_Query_Cursor) ---
	ts_query_cursor_exec :: proc(qc: TS_Query_Cursor, q: TS_Query, node: TS_Node) ---
	ts_query_cursor_set_byte_range :: proc(qc: TS_Query_Cursor, start, end: u32) -> bool ---
	ts_query_cursor_next_capture :: proc(qc: TS_Query_Cursor, m: ^TS_Query_Match, capture_index: ^u32) -> bool ---

	tree_sitter_c :: proc() -> TS_Language ---
	tree_sitter_odin :: proc() -> TS_Language ---
	tree_sitter_javascript :: proc() -> TS_Language ---
	tree_sitter_typescript :: proc() -> TS_Language ---
	tree_sitter_tsx :: proc() -> TS_Language ---
	tree_sitter_json :: proc() -> TS_Language ---
	tree_sitter_markdown :: proc() -> TS_Language ---
	tree_sitter_python :: proc() -> TS_Language ---
	tree_sitter_go :: proc() -> TS_Language ---
	tree_sitter_rust :: proc() -> TS_Language ---
	tree_sitter_bash :: proc() -> TS_Language ---
	tree_sitter_yaml :: proc() -> TS_Language ---
	tree_sitter_toml :: proc() -> TS_Language ---
}

// ---- languages ----

@(private = "file")
Q_JS :: #load("../vendor/tree-sitter/grammars/javascript/queries/highlights.scm", string)
@(private = "file")
Q_JSX :: #load("../vendor/tree-sitter/grammars/javascript/queries/highlights-jsx.scm", string)
@(private = "file")
Q_TS :: #load("../vendor/tree-sitter/grammars/typescript/queries/highlights.scm", string)

Predicate_Op :: enum u8 {
	Eq,
	Match,
	Any_Of,
}
Predicate :: struct {
	op:      Predicate_Op,
	negate:  bool,
	capture: u32,
	other:   i32, // #eq? against another capture (-1 = against text)
	text:    string, // #eq? / #match? argument (owned by the query)
	any:     []string,
	re:      regex.Regular_Expression,
	re_ok:   bool,
}

Language :: struct {
	name:    string, // as in editor_state
	exts:    []string, // ".c" (lower case); file names ("Makefile") too
	ts:      proc "c" () -> TS_Language,
	queries: []string, // concatenated in order (later patterns win)
	comment: string, // line comment ("" = none)
	block:   [2]string, // block comment when there is no line comment
	// loaded on first use
	loaded:  bool,
	query:   TS_Query,
	preds:   [][]Predicate, // per pattern
	tokens:  []Syntax_Token, // per capture id
	error:   string,
}

LANGUAGES := [?]Language {
	{name = "c", exts = {".c", ".h"}, ts = tree_sitter_c, queries = {#load("../vendor/tree-sitter/grammars/c/queries/highlights.scm", string)}, comment = "//"},
	{name = "odin", exts = {".odin"}, ts = tree_sitter_odin, queries = {#load("../vendor/tree-sitter/grammars/odin/queries/highlights.scm", string)}, comment = "//"},
	{name = "javascript", exts = {".js", ".mjs", ".cjs", ".jsx"}, ts = tree_sitter_javascript, queries = {Q_JS, Q_JSX}, comment = "//"},
	{name = "typescript", exts = {".ts", ".mts", ".cts"}, ts = tree_sitter_typescript, queries = {Q_JS, Q_TS}, comment = "//"},
	{name = "tsx", exts = {".tsx"}, ts = tree_sitter_tsx, queries = {Q_JS, Q_JSX, Q_TS}, comment = "//"},
	{name = "json", exts = {".json", ".jsonc", ".json5"}, ts = tree_sitter_json, queries = {#load("../vendor/tree-sitter/grammars/json/queries/highlights.scm", string)}, comment = "//"},
	{name = "markdown", exts = {".md", ".markdown", ".mdx"}, ts = tree_sitter_markdown, queries = {#load("../vendor/tree-sitter/grammars/markdown/queries/highlights.scm", string)}, block = {"<!-- ", " -->"}},
	{name = "python", exts = {".py", ".pyi", ".pyw"}, ts = tree_sitter_python, queries = {#load("../vendor/tree-sitter/grammars/python/queries/highlights.scm", string)}, comment = "#"},
	{name = "go", exts = {".go"}, ts = tree_sitter_go, queries = {#load("../vendor/tree-sitter/grammars/go/queries/highlights.scm", string)}, comment = "//"},
	{name = "rust", exts = {".rs"}, ts = tree_sitter_rust, queries = {#load("../vendor/tree-sitter/grammars/rust/queries/highlights.scm", string)}, comment = "//"},
	{name = "shell", exts = {".sh", ".bash", ".zsh", ".bashrc", ".zshrc", ".profile", ".zprofile", ".envrc"}, ts = tree_sitter_bash, queries = {#load("../vendor/tree-sitter/grammars/bash/queries/highlights.scm", string)}, comment = "#"},
	{name = "yaml", exts = {".yml", ".yaml"}, ts = tree_sitter_yaml, queries = {#load("../vendor/tree-sitter/grammars/yaml/queries/highlights.scm", string)}, comment = "#"},
	{name = "toml", exts = {".toml"}, ts = tree_sitter_toml, queries = {#load("../vendor/tree-sitter/grammars/toml/queries/highlights.scm", string)}, comment = "#"},
}

// The language for a path (by extension or file name), or nil = plain text.
language_for_path :: proc(path: string) -> ^Language {
	base := filepath.base(path)
	ext := strings.to_lower(filepath.ext(base), context.temp_allocator)
	name := strings.to_lower(base, context.temp_allocator)
	for &l in LANGUAGES do for e in l.exts {
		if e == ext || e == name do return &l
	}
	return nil
}

language_by_name :: proc(name: string) -> ^Language {
	for &l in LANGUAGES do if l.name == name do return &l
	return nil
}

// Compiles the language's query once. False (and l.error) if it does not
// compile against the grammar: the editor shows plain text then.
language_load :: proc(l: ^Language) -> bool {
	if l.loaded do return l.query != nil
	l.loaded = true
	context.allocator = runtime.heap_allocator() // kept for the app's lifetime
	src := strings.concatenate(l.queries)
	err_off: u32
	err_type: c.int
	l.query = ts_query_new(l.ts(), raw_data(src), u32(len(src)), &err_off, &err_type)
	if l.query == nil {
		l.error = fmt.aprintf("highlight query error %d at byte %d", err_type, err_off)
		delete(src)
		return false
	}
	delete(src) // the query keeps its own copies of names and strings
	ncap := ts_query_capture_count(l.query)
	l.tokens = make([]Syntax_Token, ncap)
	for i in 0 ..< ncap {
		n: u32
		p := ts_query_capture_name_for_id(l.query, i, &n)
		l.tokens[i] = syntax_token_for(string(p[:n]))
	}
	npat := ts_query_pattern_count(l.query)
	l.preds = make([][]Predicate, npat)
	for pi in 0 ..< npat {
		count: u32
		steps := ts_query_predicates_for_pattern(l.query, pi, &count)
		list := make([dynamic]Predicate)
		i := u32(0)
		for i < count {
			j := i
			for j < count && steps[j].type != 0 do j += 1
			if p, ok := parse_predicate(l.query, steps[i:j]); ok do append(&list, p)
			i = j + 1
		}
		l.preds[pi] = list[:]
	}
	return true
}

@(private = "file")
query_string :: proc(q: TS_Query, id: u32) -> string {
	n: u32
	p := ts_query_string_value_for_id(q, id, &n)
	return string(p[:n])
}

@(private = "file")
parse_predicate :: proc(q: TS_Query, steps: []TS_Predicate_Step) -> (p: Predicate, ok: bool) {
	if len(steps) < 3 || steps[0].type != 2 || steps[1].type != 1 do return
	name := query_string(q, steps[0].value_id)
	p.capture = steps[1].value_id
	p.other = -1
	switch name {
	case "eq?", "not-eq?":
		p.op, p.negate = .Eq, name == "not-eq?"
		if steps[2].type == 1 do p.other = i32(steps[2].value_id)
		else do p.text = query_string(q, steps[2].value_id)
	case "match?", "not-match?":
		p.op, p.negate = .Match, name == "not-match?"
		p.text = query_string(q, steps[2].value_id)
		re, err := regex.create(p.text, permanent_allocator = runtime.heap_allocator())
		p.re, p.re_ok = re, err == nil
	case "any-of?", "not-any-of?":
		p.op, p.negate = .Any_Of, name == "not-any-of?"
		any := make([]string, len(steps) - 2)
		for s, i in steps[2:] do any[i] = query_string(q, s.value_id)
		p.any = any
	case:
		return {}, false
	}
	return p, true
}

// Capture names (nvim and tree-sitter CLI styles) onto syntax tokens.
syntax_token_for :: proc(name: string) -> Syntax_Token {
	head := name
	if i := strings.index_byte(name, '.'); i >= 0 do head = name[:i]
	switch name {
	case "variable", "variable.parameter", "variable.member", "embedded", "none", "spell", "nospell", "text":
		return .Plain
	case "variable.builtin", "constant.builtin", "boolean", "label":
		return .Constant
	case "string.escape", "escape", "string.regexp", "string.special", "string.special.symbol", "character.special":
		return .Escape
	case "constructor":
		return .Type
	case "function.macro", "preproc", "keyword.directive":
		return .Keyword
	case "text.title", "markup.heading", "text.strong", "markup.strong":
		return .Heading
	case "text.uri", "text.reference", "markup.link", "markup.link.url", "markup.link.label", "string.special.url":
		return .Link
	case "text.literal", "markup.raw", "markup.raw.block":
		return .String
	}
	switch head {
	case "comment":   return .Comment
	case "keyword", "conditional", "repeat", "include", "exception", "storageclass", "define", "import", "export":
		return .Keyword
	case "string", "character":
		return .String
	case "number", "float":
		return .Number
	case "constant":  return .Constant
	case "function", "method":
		return .Function
	case "type", "namespace", "module":
		return .Type
	case "property", "field":
		return .Property
	case "attribute", "tag.attribute":
		return .Attribute
	case "tag":       return .Tag
	case "operator":  return .Operator
	case "punctuation", "delimiter":
		return .Punctuation
	case "markup":    return .Heading
	}
	return .Plain
}

// ---- per editor ----

Syntax :: struct {
	lang:   ^Language,
	parser: TS_Parser,
	tree:   TS_Tree,
	stale:  bool, // edited since the last parse
	gen:    u64, // bumped by every parse and edit
	// A reparse costs about 0.25 µs per top-level item (tree-sitter walks the
	// root's children), so a file with ~100k of them takes ~25 ms. When the
	// last parse was that slow, typing does not wait for it: the edited old
	// tree (positions shifted by ts_tree_edit) colours the screen until the
	// typing pauses for SYNTAX_IDLE, then one reparse.
	parse_cost: time.Duration,
	edited_at:  time.Tick,
	cursor: TS_Query_Cursor,
	// highlight cache: one token per byte of [hl_lo, hl_hi)
	hl:     [dynamic]Syntax_Token,
	hl_lo:  int,
	hl_hi:  int,
	hl_gen: u64,
	hl_ok:  bool,
}

@(private = "file")
ts_read :: proc "c" (payload: rawptr, byte_index: u32, position: TS_Point, bytes_read: ^u32) -> [^]u8 {
	context = runtime.default_context()
	b := (^Text_Buffer)(payload)
	ch := tb_chunk(b, int(byte_index))
	bytes_read^ = u32(len(ch))
	return raw_data(ch)
}

// Starts highlighting for lang (nil: plain text) and parses b once.
syntax_open :: proc(sx: ^Syntax, lang: ^Language, b: ^Text_Buffer) {
	syntax_close(sx)
	if lang == nil || !language_load(lang) do return
	sx.lang = lang
	sx.parser = ts_parser_new()
	if !ts_parser_set_language(sx.parser, lang.ts()) {
		ts_parser_delete(sx.parser)
		sx^ = {}
		return
	}
	sx.cursor = ts_query_cursor_new()
	sx.stale = true
	syntax_reparse(sx, b)
}

syntax_close :: proc(sx: ^Syntax) {
	if sx.tree != nil do ts_tree_delete(sx.tree)
	if sx.parser != nil do ts_parser_delete(sx.parser)
	if sx.cursor != nil do ts_query_cursor_delete(sx.cursor)
	delete(sx.hl)
	sx^ = {}
}

// Tells the tree about an edit (before the reparse). Points are (line,
// byte column).
syntax_edit :: proc(sx: ^Syntax, start, old_end, new_end: int, start_pt, old_pt, new_pt: [2]int) {
	if sx.parser == nil do return
	sx.stale = true
	sx.gen += 1
	sx.edited_at = time.tick_now()
	if sx.tree == nil do return
	e := TS_Input_Edit {
		start_byte    = u32(start),
		old_end_byte  = u32(old_end),
		new_end_byte  = u32(new_end),
		start_point   = {u32(start_pt[0]), u32(start_pt[1])},
		old_end_point = {u32(old_pt[0]), u32(old_pt[1])},
		new_end_point = {u32(new_pt[0]), u32(new_pt[1])},
	}
	ts_tree_edit(sx.tree, &e)
}

// The whole text changed (reload): parse from scratch.
syntax_reset :: proc(sx: ^Syntax) {
	if sx.tree != nil do ts_tree_delete(sx.tree)
	sx.tree = nil
	sx.stale = sx.parser != nil
}

// Reparses if edited (incremental: reuses the edited old tree).
syntax_reparse :: proc(sx: ^Syntax, b: ^Text_Buffer) {
	if sx.parser == nil || !sx.stale do return
	input := TS_Input{payload = b, read = ts_read}
	t0 := time.tick_now()
	// within syntax_budget, or no highlighting for this file (plain text)
	deadline := time.tick_add(time.tick_now(), syntax_budget)
	opts := TS_Parse_Options{payload = &deadline, progress_callback = proc "c" (st: ^TS_Parse_State) -> bool {
		return time.tick_diff((^time.Tick)(st.payload)^, time.tick_now()) > 0
	}}
	t := ts_parser_parse_with_options(sx.parser, sx.tree, input, opts)
	if t == nil {
		syntax_close(sx) // over budget: plain text from now on
		return
	}
	sx.parse_cost = time.tick_since(t0)
	if sx.tree != nil do ts_tree_delete(sx.tree)
	sx.tree = t
	sx.stale = false
	sx.gen += 1
}

SYNTAX_MAX_BYTES :: 2 << 20 // larger files are plain text
syntax_budget := 500 * time.Millisecond // one parse; over it: plain text

SYNTAX_SLOW :: 8 * time.Millisecond // a reparse slower than this waits for a pause
SYNTAX_IDLE :: 150 * time.Millisecond // the pause

// Whether the reparse waits (slow parses while typing). The caller redraws
// once the pause is over (editor_tick).
syntax_deferring :: proc(sx: ^Syntax) -> bool {
	return sx.stale && sx.tree != nil && sx.parse_cost > SYNTAX_SLOW && time.tick_since(sx.edited_at) < SYNTAX_IDLE
}

// Tokens for bytes [lo, hi) of b (cached; valid until the next call).
// nil when there is no highlighting.
syntax_tokens :: proc(sx: ^Syntax, b: ^Text_Buffer, lo, hi: int, scratch: ^[dynamic]u8) -> []Syntax_Token {
	if sx.parser == nil do return nil
	if !syntax_deferring(sx) do syntax_reparse(sx, b)
	if sx.tree == nil do return nil
	if sx.hl_ok && sx.hl_gen == sx.gen && sx.hl_lo == lo && sx.hl_hi == hi do return sx.hl[:]
	resize(&sx.hl, hi - lo)
	for &t in sx.hl do t = .Plain
	sx.hl_lo, sx.hl_hi, sx.hl_gen, sx.hl_ok = lo, hi, sx.gen, true
	l := sx.lang
	ts_query_cursor_set_byte_range(sx.cursor, u32(lo), u32(hi))
	ts_query_cursor_exec(sx.cursor, l.query, ts_tree_root_node(sx.tree))
	m: TS_Query_Match
	ci: u32
	for ts_query_cursor_next_capture(sx.cursor, &m, &ci) {
		cap := m.captures[ci]
		tok := l.tokens[cap.index]
		if tok == .Plain do continue
		if !predicates_pass(l, &m, b, scratch) do continue
		s := max(int(ts_node_start_byte(cap.node)), lo)
		e := min(int(ts_node_end_byte(cap.node)), hi)
		for i in s ..< e do sx.hl[i - lo] = tok
	}
	return sx.hl[:]
}

@(private = "file")
capture_text :: proc(m: ^TS_Query_Match, id: u32, b: ^Text_Buffer, scratch: ^[dynamic]u8) -> (string, bool) {
	for i in 0 ..< int(m.capture_count) {
		cap := m.captures[i]
		if cap.index != id do continue
		s, e := int(ts_node_start_byte(cap.node)), int(ts_node_end_byte(cap.node))
		if e - s > 4096 do return "", false // predicates are for names, not bodies
		return strings.clone(tb_slice(b, s, e - s, scratch), context.temp_allocator), true
	}
	return "", false
}

@(private = "file")
predicates_pass :: proc(l: ^Language, m: ^TS_Query_Match, b: ^Text_Buffer, scratch: ^[dynamic]u8) -> bool {
	for &p in l.preds[m.pattern_index] {
		text, ok := capture_text(m, p.capture, b, scratch)
		if !ok do continue
		pass := false
		switch p.op {
		case .Eq:
			if p.other >= 0 {
				o, ook := capture_text(m, u32(p.other), b, scratch)
				pass = ook && o == text
			} else do pass = text == p.text
		case .Match:
			if !p.re_ok do return false
			_, pass = regex.match_and_allocate_capture(p.re, text, context.temp_allocator)
		case .Any_Of:
			for a in p.any do if a == text do pass = true
		}
		if pass == p.negate do return false
	}
	return true
}
