package main

// Tree-sitter: every grammar's highlight query compiles, and a few spans
// come out as the expected tokens; incremental edits keep them right.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
syntax_queries_compile :: proc(t: ^testing.T) {
	for &l in LANGUAGES {
		testing.expectf(t, language_load(&l), "%s: %s", l.name, l.error)
	}
}

// The token at the first byte of `needle` (the n-th occurrence) in src.
@(private = "file")
token_at :: proc(sx: ^Syntax, b: ^Text_Buffer, src, needle: string, nth := 0) -> Syntax_Token {
	at := -1
	from := 0
	for _ in 0 ..= nth {
		i := strings.index(src[from:], needle)
		if i < 0 do return .Plain
		at = from + i
		from = at + 1
	}
	scratch: [dynamic]u8
	defer delete(scratch)
	toks := syntax_tokens(sx, b, 0, tb_len(b), &scratch)
	if toks == nil do return .Plain
	return toks[at]
}

@(private = "file")
Case :: struct {
	needle: string,
	nth:    int,
	want:   Syntax_Token,
}

@(private = "file")
check_lang :: proc(t: ^testing.T, lang, src: string, cases: []Case, loc := #caller_location) {
	b: Text_Buffer
	tb_init(&b, transmute([]u8)strings.clone(src))
	defer tb_destroy(&b)
	sx: Syntax
	syntax_open(&sx, language_by_name(lang), &b)
	defer syntax_close(&sx)
	testing.expectf(t, sx.tree != nil, "%s: no tree", lang, loc = loc)
	for c in cases {
		got := token_at(&sx, &b, src, c.needle, c.nth)
		testing.expectf(t, got == c.want, "%s: %q -> %v, want %v", lang, c.needle, got, c.want, loc = loc)
	}
}

@(test)
syntax_spans :: proc(t: ^testing.T) {
	check_lang(t, "c", "#include <stdio.h>\n// hi\nint main(void) { return 42; }\n", {{"#include", 0, .Keyword}, {"// hi", 0, .Comment}, {"int", 0, .Type}, {"main", 0, .Function}, {"return", 0, .Keyword}, {"42", 0, .Number}})
	check_lang(t, "odin", "package main\n\nimport \"core:fmt\"\n\nmain :: proc() {\n\tfmt.println(\"hi\") // say\n\tx := 3\n}\n", {{"package", 0, .Keyword}, {"\"core:fmt\"", 0, .String}, {"proc", 0, .Keyword}, {"// say", 0, .Comment}, {"3", 0, .Number}})
	check_lang(t, "python", "def f(x):\n    return 'a' # c\n", {{"def", 0, .Keyword}, {"f(x", 0, .Function}, {"'a'", 0, .String}, {"# c", 0, .Comment}})
	check_lang(t, "typescript", "const n: number = 1;\nfunction g(): string { return `x` }\n", {{"const", 0, .Keyword}, {"number", 0, .Type}, {"g", 0, .Function}, {"`x`", 0, .String}})
	check_lang(t, "tsx", "const a = <div className=\"x\">hi</div>;\n", {{"div", 0, .Tag}, {"\"x\"", 0, .String}})
	check_lang(t, "json", "{\"a\": [1, true, \"s\"]}\n", {{"1", 0, .Number}, {"true", 0, .Constant}, {"\"s\"", 0, .String}})
	check_lang(t, "go", "package main\n\nfunc main() {\n\tprintln(\"x\")\n}\n", {{"package", 0, .Keyword}, {"func", 0, .Keyword}, {"main", 1, .Function}, {"\"x\"", 0, .String}})
	check_lang(t, "rust", "fn main() { let s = \"x\"; }\n", {{"fn", 0, .Keyword}, {"main", 0, .Function}, {"\"x\"", 0, .String}})
	check_lang(t, "shell", "# c\necho \"hi\" $HOME\n", {{"# c", 0, .Comment}, {"\"hi\"", 0, .String}})
	check_lang(t, "yaml", "key: value # c\nn: 3\n", {{"key", 0, .Property}, {"# c", 0, .Comment}, {"3", 0, .Number}})
	check_lang(t, "toml", "[table]\nkey = \"v\" # c\n", {{"key", 0, .Property}, {"\"v\"", 0, .String}, {"# c", 0, .Comment}})
	check_lang(t, "markdown", "# Title\n\ntext\n", {{"Title", 0, .Heading}})
}

// Edits go into the tree incrementally; a new token after an edit is seen.
@(test)
syntax_incremental :: proc(t: ^testing.T) {
	src := "int x = 1;\n"
	b: Text_Buffer
	tb_init(&b, transmute([]u8)strings.clone(src))
	defer tb_destroy(&b)
	sx: Syntax
	syntax_open(&sx, language_by_name("c"), &b)
	defer syntax_close(&sx)
	// insert a comment line at the start
	ins := "// note\n"
	tb_insert(&b, 0, ins)
	syntax_edit(&sx, 0, 0, len(ins), {0, 0}, {0, 0}, {1, 0})
	scratch: [dynamic]u8
	defer delete(scratch)
	toks := syntax_tokens(&sx, &b, 0, tb_len(&b), &scratch)
	testing.expect_value(t, toks[0], Syntax_Token.Comment)
	testing.expect_value(t, toks[len(ins)], Syntax_Token.Type) // "int"
	testing.expect(t, !sx.stale) // reparsed (a small file never defers)
}

// A 50k-line C file: first parse and an incremental reparse.
@(test)
syntax_large_parse :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	for i in 0 ..< 50_000 / 5 do fmt.sbprintf(&sb, "static int f%d(int a) {{\n\t// comment %d\n\tint b = a * %d;\n\treturn b + 1;\n}}\n", i, i, i)
	b: Text_Buffer
	tb_init(&b, sb.buf[:])
	defer tb_destroy(&b)
	t0 := time.tick_now()
	sx: Syntax
	syntax_open(&sx, language_by_name("c"), &b)
	defer syntax_close(&sx)
	first := time.tick_since(t0)
	at := tb_line_start(&b, 25_000)
	tb_insert(&b, at, "x")
	syntax_edit(&sx, at, at, at + 1, {25_000, 0}, {25_000, 0}, {25_000, 1})
	t1 := time.tick_now()
	syntax_reparse(&sx, &b)
	again := time.tick_since(t1)
	fmt.printf("syntax: 50k-line C file parsed in %v, reparsed after one edit in %v\n", first, again)
	testing.expectf(t, again < 50 * time.Millisecond, "incremental reparse took %v", again)
}
