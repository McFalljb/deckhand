// Syntax highlighting for the browser client's code views (Code.tsx): a small line-by-line lexer,
// no dependency. The window highlights with tree-sitter (src/editor_syntax.odin), which the core
// does not link; this lexer gives the same token kinds (Syntax_Token in src/theme.odin), painted
// with the same colours (--syn-* in theme.gen.css, from EDITOR_COLORS), so both clients look alike.
//
// A line is lexed from the state the line before ended in ("" = nothing open; a block comment, a
// multi-line string, a Markdown fence, an HTML tag or a CSS block left open), so a view lexes only
// the lines it shows and the ones above them, and an edit relexes from the edited line down only
// while the states differ (Lines). It is a lexer, not a parser: keywords, strings, comments,
// numbers, calls, member names, capitalised names, tags; no scopes, no embedded languages.
//
// Limits (the caller falls back to plain text): HL_MAX_BYTES, HL_MAX_LINES; one line longer than
// HL_MAX_LINE is left plain (minified files).

export type Tok =
  | "comment" | "keyword" | "string" | "escape" | "number" | "constant" | "function" | "type"
  | "property" | "attribute" | "tag" | "operator" | "punctuation" | "heading" | "link";
export type Span = [from: number, to: number, tok: Tok];

export const HL_MAX_BYTES = 1 << 20;
export const HL_MAX_LINES = 30000;
export const HL_MAX_LINE = 3000;

// ---- languages ----

interface Code {
  line?: string[]; // line comments
  block?: [string, string]; // block comment
  quotes?: string; // one-line strings
  raw?: string; // of those, the ones without escapes
  multi?: [string, string, boolean][]; // multi-line strings: open, close, escapes
  kw: Set<string>;
  types?: Set<string>;
  consts?: Set<string>;
  ci?: boolean; // keywords in any case (SQL)
  caps?: boolean; // Capitalised names are types, ALL_CAPS constants
  ident?: RegExp; // sticky
  hash?: "preproc" | "attr"; // C's #include; Rust's #[attr]
  at?: Tok; // @name: decorators (attribute), Zig's builtins (function), Objective-C (keyword)
  sigil?: "shell" | "make"; // $name, ${…}; make's $(VAR) (a shell's $( is punctuation, its insides lexed)
  regex?: boolean; // JavaScript's /regex/ and JSX tags
  macro?: boolean; // Rust's name!
  lifetimes?: boolean; // Rust's 'a
  odin?: boolean; // name :: proc / struct
  lead?: Set<string>; // a line's first word is a keyword (Dockerfile)
  target?: boolean; // make's target:
  lineStr?: string; // Zig's \\ multi-line string lines
  strPrefix?: RegExp; // Python's f"…", r"…"
}

type Kind = Code | "markup" | "css" | "markdown" | "yaml" | "toml" | "json";

const words = (s: string) => new Set(s.split(" "));

const C_KW = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local alignas alignof static_assert thread_local typeof";
const C_TYPES = "char double float int long short signed unsigned void bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE";
const CPP_KW = " catch class concept consteval constexpr constinit co_await co_return co_yield decltype delete explicit export final friend mutable namespace new noexcept operator override private protected public requires template this throw try typeid typename using virtual";
const OBJC_KW = " self super id instancetype nonnull nullable _Nonnull _Nullable __weak __strong __block";
const JS_KW = "as async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield";
const TS_KW = " abstract declare enum implements infer interface is keyof module namespace override private protected public readonly satisfies type unique";
const TS_TYPES = "any boolean never number object string symbol unknown bigint void";
const JS_CONSTS = "true false null undefined NaN Infinity";

const C_LIKE = { line: ["//"], block: ["/*", "*/"] as [string, string], quotes: `"'` };

const c: Code = { ...C_LIKE, kw: words(C_KW), types: words(C_TYPES), consts: words("true false NULL nullptr"), caps: true, hash: "preproc" };
const cpp: Code = { ...c, kw: words(C_KW + CPP_KW + OBJC_KW), types: words(C_TYPES + " wchar_t char8_t char16_t char32_t std string"), at: "keyword" };
const js: Code = { ...C_LIKE, quotes: `"'`, multi: [["`", "`", true]], kw: words(JS_KW), consts: words(JS_CONSTS), caps: true, ident: /[\p{L}_$][\p{L}\p{N}_$]*/uy, regex: true, at: "attribute" };
const ts: Code = { ...js, kw: words(JS_KW + TS_KW), types: words(TS_TYPES) };

const LANGS: Record<string, Kind> = {
  c,
  cpp,
  javascript: js,
  typescript: ts,
  json: "json",
  python: {
    line: ["#"], quotes: `"'`, multi: [[`"""`, `"""`, true], [`'''`, `'''`, true]], strPrefix: /[rRbBuUfF]{1,2}(?=["'])/y,
    kw: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield"),
    types: words("int float str bool bytes list dict set tuple object complex frozenset bytearray"),
    consts: words("True False None self cls Ellipsis NotImplemented __name__ __file__"), caps: true, at: "attribute",
  },
  go: {
    ...C_LIKE, multi: [["`", "`", false]],
    kw: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
    types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable"),
    consts: words("true false nil iota"),
  },
  rust: {
    ...C_LIKE, quotes: `"`, kw: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type union unsafe use where while yield Self self"),
    types: words("bool char str i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 String Vec Option Result Box"),
    consts: words("true false None Some Ok Err"), caps: true, hash: "attr", macro: true, lifetimes: true,
  },
  odin: {
    ...C_LIKE, multi: [["`", "`", false]],
    kw: words("asm auto_cast bit_set break case cast context continue defer distinct do dynamic else enum fallthrough for foreign if import in map matrix not_in or_break or_continue or_else or_return package proc return struct switch transmute typeid union using when where"),
    types: words("bool b8 b16 b32 b64 int i8 i16 i32 i64 i128 uint u8 u16 u32 u64 u128 uintptr f16 f32 f64 complex64 complex128 quaternion256 rune string cstring rawptr any byte i16le i32le i64le u16le u32le u64le i16be i32be i64be u16be u32be u64be"),
    consts: words("true false nil"), caps: true, hash: "preproc", at: "attribute", odin: true,
  },
  zig: {
    line: ["//"], quotes: `"'`, lineStr: "\\\\",
    kw: words("addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while"),
    types: words("bool void noreturn type anyerror anyopaque comptime_int comptime_float isize usize c_int c_uint c_long c_ulong c_char f16 f32 f64 f80 f128 i8 i16 i32 i64 i128 u8 u16 u32 u64 u128"),
    consts: words("true false null undefined"), caps: true, at: "function",
  },
  lua: {
    line: ["--"], block: ["--[[", "]]"], quotes: `"'`, multi: [["[[", "]]", false]],
    kw: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
    consts: words("true false nil self"),
  },
  shell: {
    line: ["#"], quotes: `"'`, raw: "'",
    kw: words("if then else elif fi case esac for while until do done in function select time return exit local export readonly declare unset source alias shift break continue eval exec set trap"),
    consts: words("true false"), sigil: "shell",
  },
  sql: {
    line: ["--"], block: ["/*", "*/"], quotes: `'"`, ci: true,
    kw: words("add all alter and as asc begin between by cascade case check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references returning right rollback select set table then transaction trigger union unique update using values view when where with"),
    types: words("int integer bigint smallint text varchar char boolean bool real float double numeric decimal date time timestamp timestamptz blob json jsonb uuid serial"),
    consts: words("true false"),
  },
  make: {
    line: ["#"], quotes: `"'`, sigil: "make", target: true,
    kw: words("ifeq ifneq ifdef ifndef else endif include -include sinclude define endef export unexport override private vpath"),
  },
  dockerfile: {
    line: ["#"], quotes: `"'`, sigil: "shell", kw: words("as"), ci: true,
    lead: words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell"),
  },
  markup: "markup",
  css: "css",
  markdown: "markdown",
  yaml: "yaml",
  toml: "toml",
};
LANGS.objc = LANGS.cpp;

// Extensions (lower case, with the dot) and whole file names onto languages.
const BY_EXT: Record<string, string> = {};
const add = (lang: string, names: string) => names.split(" ").forEach((n) => (BY_EXT[n] = lang));
add("c", ".c");
add("cpp", ".cc .cpp .cxx .c++ .hh .hpp .hxx .h++ .ipp .inl .h .m .mm");
add("javascript", ".js .mjs .cjs .jsx");
add("typescript", ".ts .mts .cts .tsx");
add("json", ".json .jsonc .json5 .webmanifest .code-workspace");
add("python", ".py .pyi .pyw");
add("go", ".go");
add("rust", ".rs");
add("odin", ".odin");
add("zig", ".zig .zon");
add("lua", ".lua");
add("shell", ".sh .bash .zsh .ksh .fish .bashrc .zshrc .zshenv .profile .zprofile .bash_profile .envrc");
add("sql", ".sql");
add("make", "makefile gnumakefile .mk .mak");
add("dockerfile", "dockerfile containerfile .dockerfile");
add("markup", ".html .htm .xhtml .xml .svg .plist .xib .storyboard .vue .svelte");
add("css", ".css .scss .less");
add("markdown", ".md .markdown .mdx");
add("yaml", ".yml .yaml");
add("toml", ".toml .ini .cfg .conf .editorconfig .gitconfig");

// Code-fence names that are not an extension.
const ALIAS: Record<string, string> = {
  js: "javascript", jsx: "javascript", node: "javascript", ts: "typescript", tsx: "typescript",
  py: "python", python3: "python", golang: "go", rs: "rust", sh: "shell", bash: "shell", zsh: "shell",
  console: "shell", "shell-session": "shell", shellscript: "shell", fish: "shell",
  "c++": "cpp", cxx: "cpp", "objective-c": "objc", objectivec: "objc", "objective-c++": "objc",
  html: "markup", xml: "markup", svg: "markup", vue: "markup", md: "markdown", yml: "yaml", ini: "toml",
  makefile: "make", mk: "make", docker: "dockerfile", postgres: "sql", postgresql: "sql", sqlite: "sql",
  scss: "css", less: "css", jsonc: "json", json5: "json", h: "cpp",
};

// The language for a file's path (by extension or name), or "" = plain text.
export function langForPath(path: string): string {
  const base = path.slice(path.lastIndexOf("/") + 1).toLowerCase();
  if (BY_EXT[base]) return BY_EXT[base];
  if (base.startsWith("dockerfile.") || base.startsWith("containerfile.")) return "dockerfile";
  if (base.startsWith("makefile.")) return "make";
  const dot = base.lastIndexOf(".");
  return dot >= 0 ? (BY_EXT[base.slice(dot)] ?? "") : "";
}

// The language for a Markdown code fence's info string ("ts", "python title=x"), or "".
export function langForFence(info: string): string {
  const name = info.trim().split(/[\s{,]/)[0].toLowerCase();
  if (!name) return "";
  if (LANGS[name]) return name;
  return ALIAS[name] ?? BY_EXT["." + name] ?? BY_EXT[name] ?? "";
}

// ---- lexing one line ----

const NUM = /(0[xX][\da-fA-F_]+|0[bBoO][\d_]+|(\d[\d_]*(\.\d[\d_]*)?|\.\d[\d_]*)([eE][+-]?\d+)?)[\w]*/y;
const IDENT = /[\p{L}_][\p{L}\p{N}_]*/uy;
const OPS = /[-+*/%=<>!&|^~?:]+/y;
const PUNCT = "(){}[],;.";
const FN_INTRO = words("def fn func function proc");
const TYPE_INTRO = words("class struct enum interface type union trait impl namespace extends implements new");
const REGEX = /\/(?![*/])(\\.|\[(\\.|[^\]\\])*\]|[^/\\[])+\/[a-z]*/y;
const SIGIL = /\$(\{[^}]*\}?|[A-Za-z_]\w*|[\d@?#*!$<^%+-])/y;
const MAKE_VAR = /\$\([^)]*\)?/y;

const at = (re: RegExp, s: string, i: number): string => {
  re.lastIndex = i;
  const m = re.exec(s);
  return m ? m[0] : "";
};

class Out {
  spans: Span[] = [];
  put(a: number, b: number, t: Tok) {
    if (b <= a) return;
    const l = this.spans[this.spans.length - 1];
    if (l && l[1] === a && l[2] === t) l[1] = b;
    else this.spans.push([a, b, t]);
  }
}

// A string's body from i up to its close: escapes painted apart. Returns the index after the
// close, or -1 when the line ends first.
function strBody(s: string, i: number, close: string, esc: boolean, o: Out): number {
  let from = i;
  while (i < s.length) {
    if (esc && s[i] === "\\") {
      o.put(from, i, "string");
      const e = Math.min(i + 2, s.length);
      o.put(i, e, "escape");
      i = from = e;
      continue;
    }
    if (s.startsWith(close, i)) {
      o.put(from, i + close.length, "string");
      return i + close.length;
    }
    i++;
  }
  o.put(from, s.length, "string");
  return -1;
}

function nextChar(s: string, i: number): string {
  while (i < s.length && (s[i] === " " || s[i] === "\t")) i++;
  return s[i] ?? "";
}

function lexCode(L: Code, s: string, st: string, o: Out): string {
  let i = 0;
  const n = s.length;
  if (st === "b") {
    const e = s.indexOf(L.block![1]);
    if (e < 0) return o.put(0, n, "comment"), "b";
    o.put(0, e + L.block![1].length, "comment");
    i = e + L.block![1].length;
  } else if (st[0] === "m") {
    const [, close, esc] = L.multi![+st.slice(1)];
    i = strBody(s, 0, close, esc, o);
    if (i < 0) return st;
  }
  // the last thing lexed: "" (line start), "op", "(" (an opening or separating punctuation),
  // ")" (a closing one), "word", "kw", "." (a member access)
  let prev = "";
  let prevWord = "";
  if (L.lead) {
    const w = at(/\s*([A-Za-z]+)/y, s, i);
    if (w && L.lead.has(w.trim().toLowerCase())) {
      o.put(i + w.length - w.trim().length, i + w.length, "keyword");
      i += w.length;
      prev = "kw";
    }
  }
  if (L.target && i === 0 && s[0] !== "\t") {
    const m = /^([^\s:=#][^:=#]*?)\s*::?(?!=)/.exec(s);
    if (m && !L.kw.has(m[1].split(/\s/)[0])) {
      o.put(0, m[1].length, "function");
      i = m[1].length;
    }
  }
  while (i < n) {
    const ch = s[i];
    if (ch === " " || ch === "\t") { i++; continue; }
    if (L.block && s.startsWith(L.block[0], i)) {
      const e = s.indexOf(L.block[1], i + L.block[0].length);
      if (e < 0) return o.put(i, n, "comment"), "b";
      o.put(i, e + L.block[1].length, "comment");
      i = e + L.block[1].length;
      continue;
    }
    if (L.line?.some((p) => s.startsWith(p, i)) && !(ch === "#" && i > 0 && /[\w$]/.test(s[i - 1]))) {
      o.put(i, n, "comment");
      break;
    }
    if (L.lineStr && s.startsWith(L.lineStr, i)) {
      o.put(i, n, "string");
      break;
    }
    let mi = -1;
    if (L.multi) mi = L.multi.findIndex(([open]) => s.startsWith(open, i));
    if (mi >= 0) {
      const [open, close, esc] = L.multi![mi];
      o.put(i, i + open.length, "string");
      const e = strBody(s, i + open.length, close, esc, o);
      if (e < 0) return "m" + mi;
      i = e;
      prev = "word";
      continue;
    }
    if (L.lifetimes && ch === "'") {
      const ch1 = at(/'(\\.[^']*|[^\\'])'/y, s, i);
      if (ch1) {
        o.put(i, i + 1, "string");
        const e = strBody(s, i + 1, "'", true, o);
        i = e < 0 ? n : e;
        prev = "word";
        continue;
      } else {
        const lt = at(/'[\p{L}_][\p{L}\p{N}_]*/uy, s, i);
        o.put(i, i + Math.max(1, lt.length), "constant");
        i += Math.max(1, lt.length);
        continue;
      }
    }
    if (L.quotes?.includes(ch)) {
      o.put(i, i + 1, "string");
      const e = strBody(s, i + 1, ch, !L.raw?.includes(ch), o);
      i = e < 0 ? n : e;
      prev = "word";
      continue;
    }
    if (L.hash && ch === "#") {
      if (L.hash === "preproc" && s.slice(0, i).trim() === "") {
        const d = at(/#\s*[A-Za-z_]+/y, s, i);
        if (d) {
          o.put(i, i + d.length, "keyword");
          i += d.length;
          const inc = /^\s*<[^>]*>/.exec(s.slice(i));
          if (inc && /include|import/.test(d)) {
            o.put(i, i + inc[0].length, "string");
            i += inc[0].length;
          }
          continue;
        }
      } else if (L.hash === "preproc") {
        const d = at(/#[A-Za-z_]+/y, s, i); // Odin's #directives
        if (d) { o.put(i, i + d.length, "keyword"); i += d.length; continue; }
      } else {
        const a = at(/#!?\[[^\]]*\]?/y, s, i);
        if (a) { o.put(i, i + a.length, "attribute"); i += a.length; continue; }
      }
    }
    if (L.at && ch === "@") {
      const a = at(/@[\p{L}_][\p{L}\p{N}_.]*/uy, s, i);
      if (a) {
        o.put(i, i + a.length, L.at);
        i += a.length;
        prev = "word";
        continue;
      }
      if (L.at === "keyword" && s[i + 1] === '"') { // Objective-C's @"string"
        o.put(i, i + 2, "string");
        const e = strBody(s, i + 2, '"', true, o);
        i = e < 0 ? n : e;
        continue;
      }
    }
    if (L.sigil && ch === "$") {
      const v = at(L.sigil === "make" ? MAKE_VAR : SIGIL, s, i) || at(SIGIL, s, i);
      if (v) { o.put(i, i + v.length, "property"); i += v.length; prev = "word"; continue; }
      if (s[i + 1] === "(") { // $( and $(( : what is inside is lexed as the line is
        const k = s[i + 2] === "(" ? 3 : 2;
        o.put(i, i + k, "punctuation");
        i += k;
        prev = "(";
        continue;
      }
    }
    if (L.regex && (prev === "" || prev === "op" || prev === "(" || prev === "kw")) {
      if (ch === "/") {
        const r = at(REGEX, s, i);
        if (r) { o.put(i, i + r.length, "escape"); i += r.length; prev = "word"; continue; }
      } else if (ch === "<") {
        const t = at(/<\/?[A-Za-z][\w.:-]*/y, s, i);
        if (t) {
          const k = t[1] === "/" ? 2 : 1;
          o.put(i, i + k, "punctuation");
          o.put(i + k, i + t.length, "tag");
          i += t.length;
          prev = "word";
          continue;
        }
      }
    }
    if (ch >= "0" && ch <= "9" || (ch === "." && s[i + 1] >= "0" && s[i + 1] <= "9")) {
      const num = at(NUM, s, i);
      o.put(i, i + num.length, "number");
      i += num.length;
      prev = "word";
      continue;
    }
    if (L.strPrefix) {
      const p = at(L.strPrefix, s, i);
      if (p) { o.put(i, i + p.length, "string"); i += p.length; continue; }
    }
    const w = at(L.ident ?? IDENT, s, i);
    if (w) {
      const e = i + w.length;
      const key = L.ci ? w.toLowerCase() : w;
      const next = nextChar(s, e);
      let t: Tok | null = null;
      if (prev === "." && !L.sigil) t = next === "(" ? "function" : "property";
      else if (L.sigil && s[e] === "=") t = "property"; // NAME=value
      else if (L.kw.has(key)) t = "keyword";
      else if (L.consts?.has(w)) t = "constant";
      else if (L.types?.has(key)) t = "type";
      else if (FN_INTRO.has(prevWord)) t = "function";
      else if (TYPE_INTRO.has(prevWord) && !L.sigil) t = "type";
      else if (L.macro && next === "!" && s[e] === "!" && s[e + 1] !== "=") t = "keyword";
      else if (next === "(") t = "function";
      else if (L.odin && /^\s*::\s*(#\w+\s*)?(proc|struct|enum|union|distinct|bit_set)\b/.test(s.slice(e)))
        t = /^\s*::\s*(#\w+\s*)?proc\b/.test(s.slice(e)) ? "function" : "type";
      else if (L.caps && /^[A-Z]/.test(w)) t = w.length > 1 && /^[A-Z][A-Z\d_]+$/.test(w) ? "constant" : "type";
      if (t) o.put(i, e, t);
      prev = t === "keyword" ? "kw" : "word";
      prevWord = key;
      i = e;
      continue;
    }
    prevWord = "";
    if (PUNCT.includes(ch)) {
      o.put(i, i + 1, "punctuation");
      prev = ch === "." && s[i + 1] !== "." && s[i - 1] !== "." ? "." : ")]}".includes(ch) ? ")" : "(";
      i++;
      continue;
    }
    const op = at(OPS, s, i);
    if (op) {
      o.put(i, i + op.length, "operator");
      prev = "op";
      i += op.length;
      continue;
    }
    i++; // anything else stays plain
  }
  return "";
}

// JSON: keys as properties, the rest as values.
function lexJson(s: string, st: string, o: Out): string {
  let i = 0;
  if (st === "b") {
    const e = s.indexOf("*/");
    if (e < 0) return o.put(0, s.length, "comment"), "b";
    o.put(0, e + 2, "comment");
    i = e + 2;
  }
  while (i < s.length) {
    const ch = s[i];
    if (ch === '"') {
      const start = o.spans.length;
      o.put(i, i + 1, "string");
      const e = strBody(s, i + 1, '"', true, o);
      const end = e < 0 ? s.length : e;
      if (nextChar(s, end) === ":") {
        // a key: the whole string, escapes and all, as one property
        o.spans.length = start;
        o.put(i, end, "property");
      }
      i = end;
    } else if (s.startsWith("//", i)) {
      o.put(i, s.length, "comment");
      break;
    } else if (s.startsWith("/*", i)) {
      const e = s.indexOf("*/", i + 2);
      if (e < 0) return o.put(i, s.length, "comment"), "b";
      o.put(i, e + 2, "comment");
      i = e + 2;
    } else if (/[-\d]/.test(ch)) {
      const m = at(/-?[\d.eE+-]+/y, s, i);
      o.put(i, i + m.length, "number");
      i += m.length;
    } else if (/[a-z]/.test(ch)) {
      const m = at(/[a-z]+/y, s, i);
      if (m === "true" || m === "false" || m === "null") o.put(i, i + m.length, "constant");
      i += m.length;
    } else {
      if ("{}[],:".includes(ch)) o.put(i, i + 1, "punctuation");
      i++;
    }
  }
  return "";
}

// An Out that writes into o at an offset (lexing the rest of a line after a closed comment).
function shifted(o: Out, by: number): Out {
  const sub = new Out();
  sub.put = (a, b, t) => o.put(a + by, b + by, t);
  return sub;
}

// HTML and XML: tags, attributes, their values, comments, entities. State: "c" in a comment,
// "t" inside a tag.
function lexMarkup(s: string, st: string, o: Out): string {
  let i = 0;
  const n = s.length;
  let inTag = st === "t";
  if (st === "c") {
    const e = s.indexOf("-->");
    if (e < 0) return o.put(0, n, "comment"), "c";
    o.put(0, e + 3, "comment");
    i = e + 3;
  }
  while (i < n) {
    if (inTag) {
      const ch = s[i];
      if (ch === ">" || s.startsWith("/>", i) || s.startsWith("?>", i)) {
        const k = ch === ">" ? 1 : 2;
        o.put(i, i + k, "punctuation");
        i += k;
        inTag = false;
      } else if (ch === '"' || ch === "'") {
        const e = s.indexOf(ch, i + 1);
        const end = e < 0 ? n : e + 1;
        o.put(i, end, "string");
        i = end;
      } else if (ch === "=") {
        o.put(i, i + 1, "operator");
        i++;
      } else {
        const a = at(/[^\s"'=<>/]+/y, s, i);
        if (a) { o.put(i, i + a.length, "attribute"); i += a.length; } else i++;
      }
      continue;
    }
    const lt = s.indexOf("<", i);
    const amp = s.indexOf("&", i);
    const next = Math.min(lt < 0 ? n : lt, amp < 0 ? n : amp);
    i = next;
    if (i >= n) break;
    if (s[i] === "&") {
      const ent = at(/&(#\d+|#x[\da-fA-F]+|\w+);/y, s, i);
      if (ent) o.put(i, i + ent.length, "escape");
      i += Math.max(1, ent.length);
    } else if (s.startsWith("<!--", i)) {
      const e = s.indexOf("-->", i + 4);
      if (e < 0) return o.put(i, n, "comment"), "c";
      o.put(i, e + 3, "comment");
      i = e + 3;
    } else if (s.startsWith("<!", i) || s.startsWith("<?", i)) {
      const d = at(/<[!?][\w-]*/y, s, i);
      o.put(i, i + d.length, "keyword");
      i += d.length;
      inTag = true;
    } else {
      const t = at(/<\/?[A-Za-z][\w.:-]*/y, s, i);
      if (!t) { i++; continue; }
      const k = t[1] === "/" ? 2 : 1;
      o.put(i, i + k, "punctuation");
      o.put(i + k, i + t.length, "tag");
      i += t.length;
      inTag = true;
    }
  }
  return inTag ? "t" : "";
}

// CSS, SCSS, Less. State: the brace depth, with "c" while a comment is open.
function lexCss(s: string, st: string, o: Out): string {
  let depth = parseInt(st, 10) || 0;
  let i = 0;
  const n = s.length;
  if (st.endsWith("c")) {
    const e = s.indexOf("*/");
    if (e < 0) return o.put(0, n, "comment"), st;
    o.put(0, e + 2, "comment");
    i = e + 2;
  }
  while (i < n) {
    const ch = s[i];
    if (s.startsWith("/*", i)) {
      const e = s.indexOf("*/", i + 2);
      if (e < 0) return o.put(i, n, "comment"), depth + "c";
      o.put(i, e + 2, "comment");
      i = e + 2;
    } else if (s.startsWith("//", i) && (i === 0 || s[i - 1] !== ":")) {
      o.put(i, n, "comment");
      break;
    } else if (ch === '"' || ch === "'") {
      o.put(i, i + 1, "string");
      const e = strBody(s, i + 1, ch, true, o);
      i = e < 0 ? n : e;
    } else if (ch === "@") {
      const a = at(/@[\w-]+/y, s, i);
      o.put(i, i + a.length, "keyword");
      i += Math.max(1, a.length);
    } else if (ch === "{" || ch === "}") {
      depth = Math.max(0, depth + (ch === "{" ? 1 : -1));
      o.put(i, i + 1, "punctuation");
      i++;
    } else if (ch === "$" || (ch === "-" && s[i + 1] === "-")) {
      const v = at(/(\$|--)[\w-]+/y, s, i);
      o.put(i, i + v.length, "property");
      i += Math.max(1, v.length);
    } else if (/[\d]/.test(ch) || (ch === "." && /\d/.test(s[i + 1] ?? "")) || (ch === "-" && /[\d.]/.test(s[i + 1] ?? ""))) {
      const m = at(/-?[\d.]+(%|[a-zA-Z]+)?/y, s, i);
      o.put(i, i + m.length, "number");
      i += m.length;
    } else if (ch === "#" && depth > 0 && /^#[\da-fA-F]{3,8}\b/.test(s.slice(i))) {
      const m = at(/#[\da-fA-F]+/y, s, i);
      o.put(i, i + m.length, "number");
      i += m.length;
    } else if (/[\w-]/.test(ch)) {
      const w = at(/[\w-]+/y, s, i);
      const e = i + w.length;
      const next = nextChar(s, e);
      // a declaration's property; a value's function; a selector's tag (outside a block, or a
      // nested rule's)
      if (next === "(") o.put(i, e, "function");
      else if (depth > 0 && next === ":" && !/[{]/.test(s.slice(e))) o.put(i, e, "property");
      else if (depth === 0 || /\{\s*$/.test(s)) o.put(i, e, "tag");
      else if (w === "important" && s[i - 1] === "!") o.put(i - 1, e, "keyword");
      i = e;
    } else if ((ch === "." || ch === "#") && (depth === 0 || /\{\s*$/.test(s))) {
      const w = at(/[.#][\w-]+/y, s, i);
      o.put(i, i + w.length, ch === "." ? "type" : "constant");
      i += Math.max(1, w.length);
    } else if (ch === ":" && (depth === 0 || /\{\s*$/.test(s))) {
      const w = at(/::?[\w-]+/y, s, i);
      o.put(i, i + Math.max(1, w.length), w ? "attribute" : "punctuation");
      i += Math.max(1, w.length);
    } else if (ch === "[" && (depth === 0 || /\{\s*$/.test(s))) {
      const e = s.indexOf("]", i);
      const end = e < 0 ? n : e + 1;
      o.put(i, end, "attribute");
      i = end;
    } else {
      if (";:,()".includes(ch)) o.put(i, i + 1, "punctuation");
      else if (">+~*=".includes(ch)) o.put(i, i + 1, "operator");
      i++;
    }
  }
  return String(depth);
}

// Markdown: as the window's tree-sitter grammar shows it (headings, fences and their code, quotes,
// list markers), with code spans and links. State: "f" + the fence inside a fenced block.
function lexMarkdown(s: string, st: string, o: Out): string {
  const n = s.length;
  if (st[0] === "f") {
    const fence = st.slice(1);
    const close = new RegExp(`^ {0,3}${fence[0] === "`" ? "`" : "~"}{${fence.length},}\\s*$`);
    if (close.test(s)) { o.put(0, n, "punctuation"); return ""; }
    o.put(0, n, "string");
    return st;
  }
  const f = /^ {0,3}(`{3,}|~{3,})/.exec(s);
  if (f && !(f[1][0] === "`" && s.slice(f[0].length).includes("`"))) {
    o.put(0, f[0].length, "punctuation");
    o.put(f[0].length, n, "attribute");
    return "f" + f[1];
  }
  const h = /^ {0,3}#{1,6}(\s|$)/.exec(s);
  if (h) { o.put(0, n, "heading"); return ""; }
  if (/^ {4,}\S/.test(s)) { o.put(0, n, "string"); return ""; }
  if (/^ {0,3}([-*_])(\s*\1){2,}\s*$/.test(s)) { o.put(0, n, "punctuation"); return ""; }
  let i = 0;
  const lead = /^(\s*(>\s*)*)([-*+]|\d+[.)])?(\s+\[[ xX]\])?(?=\s|$)/.exec(s);
  if (lead && lead[0].trim()) {
    o.put(lead[0].length - lead[0].trimStart().length, lead[0].length, "punctuation");
    i = lead[0].length;
  }
  if (/^ {0,3}\[[^\]]+\]:\s/.test(s)) { o.put(0, n, "link"); return ""; }
  while (i < n) {
    const ch = s[i];
    if (ch === "\\" && i + 1 < n) { o.put(i, i + 2, "escape"); i += 2; continue; }
    if (ch === "`") {
      const ticks = at(/`+/y, s, i);
      const e = s.indexOf(ticks, i + ticks.length);
      if (e >= 0) { o.put(i, e + ticks.length, "string"); i = e + ticks.length; continue; }
      i += ticks.length;
      continue;
    }
    if (ch === "[" || (ch === "!" && s[i + 1] === "[")) {
      const m = at(/!?\[[^\]]*\](\([^)\s]*(\s+"[^"]*")?\)|\[[^\]]*\])?/y, s, i);
      if (m && m.length > 2 && /\]\S/.test(m)) { o.put(i, i + m.length, "link"); i += m.length; continue; }
    }
    if (ch === "<") {
      const m = at(/<(https?:|mailto:)[^>\s]*>/y, s, i);
      if (m) { o.put(i, i + m.length, "link"); i += m.length; continue; }
    }
    if ((ch === "*" || ch === "_") && s[i + 1] === ch) {
      const e = s.indexOf(ch + ch, i + 2);
      if (e > i + 2) { o.put(i, e + 2, "heading"); i = e + 2; continue; }
    }
    i++;
  }
  return "";
}

// YAML: keys, values, comments, anchors. Block scalars' text stays plain.
const YAML_CONSTS = words("true false null yes no on off True False Null TRUE FALSE NULL ~");
function lexYaml(s: string, o: Out): string {
  const n = s.length;
  if (/^(---|\.\.\.)(\s|$)/.test(s)) { o.put(0, 3, "punctuation"); return ""; }
  let i = 0;
  const lead = at(/\s*(-\s+)*/y, s, 0);
  if (lead.includes("-")) o.put(lead.indexOf("-"), lead.length, "punctuation");
  i = lead.length;
  const k = at(/("[^"]*"|'[^']*'|[^\s#:"'][^#:]*?)\s*:(?=\s|$)/y, s, i);
  if (k) {
    const colon = i + k.lastIndexOf(":");
    o.put(i, i + k.slice(0, k.lastIndexOf(":")).trimEnd().length, "property");
    o.put(colon, colon + 1, "punctuation");
    i = colon + 1;
  }
  while (i < n) {
    const ch = s[i];
    if (ch === " " || ch === "\t") { i++; continue; }
    if (ch === "#" && (i === 0 || /\s/.test(s[i - 1]))) { o.put(i, n, "comment"); break; }
    if (ch === '"' || ch === "'") {
      o.put(i, i + 1, "string");
      const e = strBody(s, i + 1, ch, ch === '"', o);
      i = e < 0 ? n : e;
      continue;
    }
    if (ch === "&" || ch === "*") {
      const a = at(/[&*][^\s,\]}]+/y, s, i);
      if (a.length > 1) { o.put(i, i + a.length, "constant"); i += a.length; continue; }
    }
    if (ch === "!") {
      const a = at(/!+[^\s]*/y, s, i);
      o.put(i, i + a.length, "type");
      i += a.length;
      continue;
    }
    if ("[]{},".includes(ch)) { o.put(i, i + 1, "punctuation"); i++; continue; }
    if ((ch === "|" || ch === ">") && /^[|>][-+\d]*\s*(#.*)?$/.test(s.slice(i))) { o.put(i, i + 1, "operator"); i++; continue; }
    // a plain scalar up to a comment or a flow punctuation
    const w = at(/[^\s,\]}#][^,\]}#]*?(?=\s*(,|\]|\}|\s#|$))/y, s, i);
    if (!w) { i++; continue; }
    if (YAML_CONSTS.has(w)) o.put(i, i + w.length, "constant");
    else if (/^[-+]?(\d[\d_]*(\.\d*)?([eE][-+]?\d+)?|0x[\da-fA-F]+|\.inf|\.nan)$/.test(w)) o.put(i, i + w.length, "number");
    i += w.length;
  }
  return "";
}

// TOML and INI: [tables], keys, values (TOML's multi-line strings carry on).
const TOML: Code = { line: ["#", ";"], quotes: `"'`, raw: "'", multi: [[`"""`, `"""`, true], [`'''`, `'''`, false]], kw: new Set(), consts: words("true false inf nan") };
function lexToml(s: string, st: string, o: Out): string {
  if (st) return lexCode(TOML, s, st, o);
  const t = /^\s*\[\[?([^\]]*)\]\]?/.exec(s);
  if (t) {
    o.put(0, t[0].length, "type");
    return lexCode(TOML, s.slice(t[0].length), "", shifted(o, t[0].length));
  }
  const k = /^\s*([^=#;\s"'][^=#;]*?|"[^"]*"|'[^']*')\s*(=|:)/.exec(s);
  if (!k) return lexCode(TOML, s, "", o);
  const ks = k[0].length - k[0].trimStart().length;
  o.put(ks, ks + k[1].length, "property");
  o.put(k[0].length - 1, k[0].length, "operator");
  return lexCode(TOML, s.slice(k[0].length), "", shifted(o, k[0].length));
}

// One line's spans (sorted, not overlapping) and the state the next line starts in.
export function lexLine(lang: string, s: string, state: string): { spans: Span[]; state: string } {
  const L = LANGS[lang];
  const o = new Out();
  if (!L || s.length > HL_MAX_LINE) return { spans: [], state };
  let next: string;
  if (L === "json") next = lexJson(s, state, o);
  else if (L === "markup") next = lexMarkup(s, state, o);
  else if (L === "css") next = lexCss(s, state, o);
  else if (L === "markdown") next = lexMarkdown(s, state, o);
  else if (L === "yaml") next = lexYaml(s, o);
  else if (L === "toml") next = lexToml(s, state, o);
  else next = lexCode(L, s, state, o);
  return { spans: o.spans, state: next };
}

// The lines of one text, lexed on demand and kept: get(lines, upTo) lexes lines 0..upTo of the
// current text, again only where a line's text or the state it starts in changed.
export class Lines {
  private text: string[] = [];
  private from: string[] = []; // the state each kept line started in
  private out: { spans: Span[]; state: string }[] = [];
  readonly lang: string;
  constructor(lang: string) {
    this.lang = lang;
  }
  get(lines: string[], upTo: number): Span[][] {
    const last = Math.min(upTo, lines.length - 1);
    const res: Span[][] = [];
    let st = "";
    for (let k = 0; k <= last; k++) {
      if (this.text[k] !== lines[k] || this.from[k] !== st || !this.out[k]) {
        this.text[k] = lines[k];
        this.from[k] = st;
        this.out[k] = lexLine(this.lang, lines[k], st);
      }
      res.push(this.out[k].spans);
      st = this.out[k].state;
    }
    if (this.text.length > lines.length) {
      this.text.length = this.from.length = this.out.length = lines.length;
    }
    return res;
  }
}

// Whether a text is small enough to highlight.
export function highlightable(text: string, lineCount: number): boolean {
  return text.length <= HL_MAX_BYTES && lineCount <= HL_MAX_LINES;
}
