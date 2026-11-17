import { test } from "node:test";
import assert from "node:assert/strict";
import { HL_MAX_LINE, langForFence, langForPath, lexLine, Lines, type Tok } from "../src/app/highlight.ts";

// The tokens of a text as "tok:text" pairs, lines lexed in order (states carried).
function toks(lang: string, text: string): string[] {
  const out: string[] = [];
  let st = "";
  for (const line of text.split("\n")) {
    const r = lexLine(lang, line, st);
    let at = 0;
    for (const [a, b, t] of r.spans) {
      assert.ok(a >= at && b > a && b <= line.length, `spans sorted, apart, in the line: ${line}`);
      out.push(`${t}:${line.slice(a, b)}`);
      at = b;
    }
    st = r.state;
  }
  return out;
}
const has = (lang: string, text: string, ...want: string[]) => {
  const got = toks(lang, text);
  for (const w of want) assert.ok(got.includes(w), `${lang}: ${w} in ${JSON.stringify(got)}`);
};
const kind = (lang: string, text: string, word: string): Tok | "" => {
  const hit = toks(lang, text).find((x) => x.slice(x.indexOf(":") + 1) === word);
  return hit ? (hit.slice(0, hit.indexOf(":")) as Tok) : "";
};

test("highlight: languages by path and fence", () => {
  assert.equal(langForPath("/a/b/main.odin"), "odin");
  assert.equal(langForPath("/a/App.TSX"), "typescript");
  assert.equal(langForPath("/a/Makefile"), "make");
  assert.equal(langForPath("/a/Dockerfile"), "dockerfile");
  assert.equal(langForPath("/a/Dockerfile.dev"), "dockerfile");
  assert.equal(langForPath("/a/shim.m"), "cpp");
  assert.equal(langForPath("/a/.zshrc"), "shell");
  assert.equal(langForPath("/a/README"), "");
  assert.equal(langForPath("/a/x.bin"), "");
  assert.equal(langForFence("ts"), "typescript");
  assert.equal(langForFence("python title=x"), "python");
  assert.equal(langForFence("objective-c"), "objc");
  assert.equal(langForFence("html"), "markup");
  assert.equal(langForFence(""), "");
  assert.equal(langForFence("klingon"), "");
});

test("highlight: C-like code", () => {
  has("typescript", `const x: number = foo(1.5e3, "a\\n", obj.prop); // done`,
    "keyword:const", "type:number", "function:foo", "number:1.5e3", 'string:"a', "escape:\\n", 'string:"', "property:prop", "comment:// done");
  has("javascript", "let r = /a\"b/g; return <Tag x={1} />", "escape:/a\"b/g", "tag:Tag");
  assert.equal(kind("javascript", "a / b / c", "b"), "");
  assert.equal(kind("javascript", "class Foo extends Bar {}", "Foo"), "type");
  assert.equal(kind("javascript", "const MAX_N = 3", "MAX_N"), "constant");
  assert.equal(kind("javascript", "function go(a) {}", "go"), "function");
  assert.equal(kind("javascript", "function (a) {}", "a"), "");
  assert.equal(kind("javascript", "f(...args)", "args"), "");
  has("c", '#include <stdio.h>\nint main(void) { return NULL; }', "keyword:#include", "string: <stdio.h>", "type:int", "function:main", "constant:NULL");
  has("cpp", '@interface Foo : NSObject\nNSString *s = @"hi";', "keyword:@interface", 'string:@"hi"');
  has("rust", "fn main() { println!(\"x\"); let c = 'a'; fn f<'a>() {} }", "keyword:fn", "function:main", "keyword:println", "string:'a'", "constant:'a");
  has("rust", "#[derive(Debug)]", "attribute:#[derive(Debug)]");
  has("go", "func (s *S) Run() error { return nil }", "keyword:func", "function:Run", "type:error", "constant:nil");
  has("odin", 'main :: proc() {\n\tfmt.println("hi")\n}\nPoint :: struct { x: f32 }', "function:main", "keyword:proc", "function:println", "type:Point", "type:f32");
  has("odin", "#partial switch x {}", "keyword:#partial");
  has("zig", 'const std = @import("std");\nconst s =\n    \\\\ raw', "function:@import", "string:\\\\ raw");
  has("python", '@decorator\ndef run(self, x=None):\n    return f"x{x}"  # note', "attribute:@decorator", "function:run", "constant:self", "constant:None", "string:f\"x{x}\"", "comment:# note");
  assert.equal(kind("python", "match = 1", "match"), "");
  has("lua", "local t = {} -- c\n--[[ block\n]] print(t)", "keyword:local", "comment:-- c", "comment:--[[ block", "comment:]]", "function:print");
  has("sql", "SELECT id FROM t WHERE x = 'a' -- c", "keyword:SELECT", "keyword:FROM", "string:'a'", "comment:-- c");
});

test("highlight: shell, make, Dockerfile", () => {
  has("shell", 'if [ -n "$HOME" ]; then echo ${x#y} $1; fi # end', "keyword:if", 'string:"$HOME"', "property:${x#y}", "property:$1", "comment:# end");
  assert.ok(!toks("shell", "echo a#b").some((t) => t.startsWith("comment")), "a # inside a word is not a comment");
  has("make", "all: build\n\t$(CC) -o $@ main.c\nCC := gcc\nifeq ($(OS),x)", "function:all", "property:$(CC)", "property:$@", "keyword:ifeq");
  assert.equal(kind("make", "CC := gcc", "CC"), "");
  has("dockerfile", "FROM node:22 AS build\nRUN echo $HOME # x", "keyword:FROM", "keyword:AS", "keyword:RUN", "property:$HOME", "comment:# x");
});

test("highlight: states carry over lines", () => {
  has("c", "/* one\n two */ int x;", "comment:/* one", "comment: two */", "type:int");
  has("python", 's = """a\nb "quoted"\n"""\nx = 1', 'string:"""a', 'string:b "quoted"', 'string:"""', "number:1");
  has("typescript", "const t = `a\n${b}\n`; let y", "string:${b}", "keyword:let");
  has("markup", '<a\n  href="x">t &amp; <!-- c\n--> </a>', "tag:a", "attribute:href", 'string:"x"', "escape:&amp;", "comment:<!-- c", "comment:-->");
  has("markdown", "# Title\n```ts\nconst x\n```\nsome `code` and [a link](http://x)", "heading:# Title", "punctuation:```", "attribute:ts", "string:const x", "string:`code`", "link:[a link](http://x)");
  has("css", ".btn:hover, a { color: #fff; margin: 0 4px; }\n@media (x) {\n  .a { --v: 1; }\n}", "type:.btn", "attribute::hover", "tag:a", "property:color", "number:#fff", "number:4px", "keyword:@media", "property:--v");
  has("json", '{"key": "va\\"l", "n": -1.5, "b": true, "z": null}', 'property:"key"', 'string:"va', "escape:\\\"", "number:-1.5", "constant:true", "constant:null");
  has("yaml", "# c\nkey: value\n- name: \"x\" # y\n  on: true\n  n: 3\n  a: &anchor\n---", "comment:# c", "property:key", "property:name", 'string:"x"', "comment:# y", "constant:true", "number:3", "constant:&anchor", "punctuation:---");
  has("toml", '[tool.x]\nname = "a"\ns = """\nmulti\n"""\nok = true # c', "type:[tool.x]", "property:name", 'string:"a"', "string:multi", "constant:true", "comment:# c");
});

test("highlight: Lines relexes only what changed, follows states, plain past the limits", () => {
  const L = new Lines("c");
  const a = L.get(["int a;", "/* x", "y */", "int b;"], 3);
  assert.equal(a.length, 4);
  assert.deepEqual(a[2], [[0, 4, "comment"]]);
  assert.deepEqual(a[3][0], [0, 3, "type"]);
  const kept = a[3];
  // closing the comment earlier changes how the line below it reads; the last line is kept
  const b = L.get(["int a;", "/* x */", "y */", "int b;"], 3);
  assert.notEqual(b[2][0][2], "comment");
  assert.equal(b[3], kept);
  // asked for fewer lines than there are: only those
  assert.equal(L.get(["int a;", "int b;", "int c;"], 1).length, 2);
  // a line over the limit is plain; an unknown language is plain
  assert.deepEqual(lexLine("c", "int x;".repeat(HL_MAX_LINE), "").spans, []);
  assert.deepEqual(lexLine("nope", "int x;", "").spans, []);
});

test("highlight: never loops on odd input", () => {
  const odd = ["'", '"', "`", "/*", "\\", "$", "${", "#", "#[", "<", "<!--", "@", "@\"", "'a", "r\"", "--[[", "[[", "&", "*", "!", "```", "0x", ".5", "a.", "...", "::"];
  for (const lang of ["c", "cpp", "javascript", "typescript", "json", "python", "go", "rust", "odin", "zig", "lua", "shell", "sql", "make", "dockerfile", "markup", "css", "markdown", "yaml", "toml"]) {
    let st = "";
    for (const s of odd) st = lexLine(lang, s, st).state;
    for (const s of odd) lexLine(lang, s, "");
  }
});
