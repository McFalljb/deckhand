// A strict Markdown parser for the browser's Markdown tabs: text in, a small tree out, which
// Markdown.tsx turns into elements (never innerHTML). Written for Deckhand (no dependency): the
// CommonMark blocks people write (ATX and setext headings, paragraphs, fenced and indented code,
// block quotes, nested bullet and ordered lists with task boxes, thematic breaks, GFM tables) and
// inlines (code spans, emphasis, strong, strikethrough, links, autolinks, bare URLs, images as
// their alt text, hard breaks, backslash escapes). Raw HTML is never HTML: an HTML block shows as
// its source text, inline tags as text. A link's target is kept only when it is http(s), mailto,
// an anchor (#…) or a relative path; anything else (javascript:, data:, file:, …) is plain text.

export type Inline =
  | { t: "text"; s: string }
  | { t: "code"; s: string }
  | { t: "em" | "strong" | "del"; c: Inline[] }
  | { t: "link"; href: string; c: Inline[] }
  | { t: "img"; alt: string }
  | { t: "br" };

export type Block =
  | { t: "h"; level: number; id: string; c: Inline[] }
  | { t: "p"; c: Inline[] }
  | { t: "code"; lang: string; s: string }
  | { t: "html"; s: string }
  | { t: "quote"; c: Block[] }
  | { t: "list"; ordered: boolean; start: number; items: { task: boolean | null; c: Block[] }[] }
  | { t: "hr" }
  | { t: "table"; align: ("" | "left" | "center" | "right")[]; head: Inline[][]; rows: Inline[][][] };

const MAX_DEPTH = 24;
const SCAN = 4000; // how far a code span looks for its closing backticks
const EM_SCAN = 500; // how far an emphasis looks for its closing run

// The length of the run of c at s[i] (no slicing: linear).
function runAt(s: string, i: number, c: string): number {
  let k = i;
  while (s[k] === c) k++;
  return k - i;
}

// Each "[" 's matching "]" (balanced, escapes skipped), in one pass.
function brackets(s: string): Map<number, number> {
  const out = new Map<number, number>();
  const stack: number[] = [];
  for (let k = 0; k < s.length; k++) {
    if (s[k] === "\\") k++;
    else if (s[k] === "[") stack.push(k);
    else if (s[k] === "]" && stack.length) out.set(stack.pop()!, k);
  }
  return out;
} // nesting kept (deeper: plain text), as a hostile file cannot recurse forever

export function parseMarkdown(src: string): Block[] {
  const ids = new Map<string, number>();
  return blocks(src.replace(/\r\n?/g, "\n").replace(/\t/g, "    ").split("\n"), ids, 0);
}

// ---- blocks ----

const FENCE = /^ {0,3}(`{3,}|~{3,})\s*([^`\s]*)[^`]*$/;
const ATX = /^ {0,3}(#{1,6})(?:[ ]+(.*?))?(?:[ ]+#+)?[ ]*$/;
const HR = /^ {0,3}([-*_])(?:[ ]*\1){2,}[ ]*$/;
const QUOTE = /^ {0,3}> ?/;
const ITEM = /^( {0,3})([-*+]|\d{1,9}[.)])(?:([ ]+)(.*)|$)/;
const HTML_START = /^ {0,3}<(?:\/?[a-zA-Z][a-zA-Z0-9-]*[\s/>]|\/?[a-zA-Z][a-zA-Z0-9-]*$|!--|!\[CDATA\[|\?|![A-Z])/;
const DELIM_ROW = /^ {0,3}\|?(?:\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$|^ {0,3}\|?\s*:?-+:?\s*\|\s*$/;
const blank = (l: string) => /^\s*$/.test(l);

function interrupts(l: string): boolean {
  if (FENCE.test(l) || ATX.test(l) || HR.test(l) || QUOTE.test(l) || HTML_START.test(l)) return true;
  const m = ITEM.exec(l);
  return !!m && !!m[4] && (!/^\d/.test(m[2]) || m[2].startsWith("1"));
}

function blocks(lines: string[], ids: Map<string, number>, depth: number): Block[] {
  const out: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (blank(l)) {
      i++;
      continue;
    }
    let m: RegExpExecArray | null;
    if ((m = FENCE.exec(l))) {
      const fence = m[1];
      const indent = l.length - l.trimStart().length;
      const body: string[] = [];
      i++;
      while (i < lines.length && !new RegExp(`^ {0,3}${fence[0] === "`" ? "`" : "~"}{${fence.length},}\\s*$`).test(lines[i])) body.push(lines[i++].replace(new RegExp(`^ {0,${indent}}`), ""));
      i++;
      out.push({ t: "code", lang: m[2] ?? "", s: body.join("\n") });
      continue;
    }
    if ((m = ATX.exec(l))) {
      out.push(heading(m[1].length, m[2] ?? "", ids, depth));
      i++;
      continue;
    }
    if (HR.test(l)) {
      out.push({ t: "hr" });
      i++;
      continue;
    }
    if (QUOTE.test(l)) {
      const body: string[] = [];
      while (i < lines.length && !blank(lines[i]) && (QUOTE.test(lines[i]) || !interrupts(lines[i]))) body.push(lines[i++].replace(QUOTE, ""));
      out.push(depth < MAX_DEPTH ? { t: "quote", c: blocks(body, ids, depth + 1) } : { t: "p", c: [{ t: "text", s: body.join(" ") }] });
      continue;
    }
    if ((m = ITEM.exec(l))) {
      const r = list(lines, i, ids, depth);
      out.push(r.block);
      i = r.next;
      continue;
    }
    if (HTML_START.test(l)) {
      const body: string[] = [];
      while (i < lines.length && !blank(lines[i])) body.push(lines[i++]);
      out.push({ t: "html", s: body.join("\n") });
      continue;
    }
    if (/^ {4}/.test(l)) {
      const body: string[] = [];
      while (i < lines.length && (/^ {4}/.test(lines[i]) || blank(lines[i]))) body.push(lines[i++].slice(4));
      while (body.length && blank(body[body.length - 1])) body.pop();
      out.push({ t: "code", lang: "", s: body.join("\n") });
      continue;
    }
    if (l.includes("|") && i + 1 < lines.length && DELIM_ROW.test(lines[i + 1])) {
      const head = cells(l);
      const align = cells(lines[i + 1]).map((c) => (c.startsWith(":") && c.endsWith(":") ? "center" : c.endsWith(":") ? "right" : c.startsWith(":") ? "left" : "")) as ("" | "left" | "center" | "right")[];
      if (head.length === align.length) {
        i += 2;
        const rows: Inline[][][] = [];
        while (i < lines.length && !blank(lines[i]) && lines[i].includes("|") && !interrupts(lines[i])) {
          const r = cells(lines[i++]);
          rows.push(head.map((_, k) => inlines(r[k] ?? "", depth)));
        }
        out.push({ t: "table", align, head: head.map((h) => inlines(h, depth)), rows });
        continue;
      }
    }
    // a paragraph, or a setext heading
    const para: string[] = [l];
    i++;
    let setext = 0;
    while (i < lines.length && !blank(lines[i])) {
      if (/^ {0,3}=+\s*$/.test(lines[i])) (setext = 1), i++;
      else if (/^ {0,3}-+\s*$/.test(lines[i])) (setext = 2), i++;
      if (setext || interrupts(lines[i])) break;
      para.push(lines[i++]);
    }
    const text = para.map((x) => x.replace(/^ {1,3}/, "")).join("\n");
    out.push(setext ? heading(setext, text, ids, depth) : { t: "p", c: inlines(text, depth) });
  }
  return out;
}

function heading(level: number, text: string, ids: Map<string, number>, depth: number): Block {
  const c = inlines(text.trim(), depth);
  let id = slug(plain(c));
  const n = ids.get(id) ?? 0;
  ids.set(id, n + 1);
  if (n) id += "-" + n;
  return { t: "h", level, id, c };
}

// GitHub's heading ids: lowercase, punctuation dropped, spaces to hyphens.
export function slug(s: string): string {
  return s.toLowerCase().trim().replace(/[^\p{L}\p{N}\s_-]/gu, "").replace(/\s/g, "-");
}

export function plain(c: Inline[]): string {
  return c.map((x) => (x.t === "text" || x.t === "code" ? x.s : x.t === "img" ? x.alt : x.t === "br" ? " " : plain(x.c))).join("");
}

function cells(row: string): string[] {
  let r = row.trim();
  if (r.startsWith("|")) r = r.slice(1);
  if (r.endsWith("|") && !r.endsWith("\\|")) r = r.slice(0, -1);
  const out: string[] = [];
  let cur = "";
  for (let i = 0; i < r.length; i++) {
    if (r[i] === "\\" && r[i + 1] === "|") (cur += "|"), i++;
    else if (r[i] === "|") out.push(cur.trim()), (cur = "");
    else cur += r[i];
  }
  out.push(cur.trim());
  return out;
}

function list(lines: string[], start: number, ids: Map<string, number>, depth: number): { block: Block; next: number } {
  const first = ITEM.exec(lines[start])!;
  const ordered = /^\d/.test(first[2]);
  const marker = ordered ? first[2].slice(-1) : first[2];
  const items: { task: boolean | null; c: Block[] }[] = [];
  let i = start;
  let m: RegExpExecArray | null;
  while (i < lines.length && (m = ITEM.exec(lines[i])) && (ordered ? /^\d/.test(m[2]) && m[2].endsWith(marker) : m[2] === marker)) {
    const pad = m[3] ? Math.min(m[3].length, 4) : 1;
    const indent = m[1].length + m[2].length + pad;
    const body: string[] = [m[3] && m[3].length > 4 ? " ".repeat(m[3].length - 1) + m[4] : (m[4] ?? "")];
    i++;
    while (i < lines.length) {
      const l = lines[i];
      if (blank(l)) {
        // a blank line: the item goes on if what follows is indented under it
        let k = i;
        while (k < lines.length && blank(lines[k])) k++;
        if (k < lines.length && lines[k].length - lines[k].trimStart().length >= indent) {
          while (i < k) body.push(""), i++;
          continue;
        }
        break;
      }
      const ind = l.length - l.trimStart().length;
      if (ind >= indent) body.push(l.slice(indent));
      else if (!interrupts(l) && !ITEM.test(l)) body.push(l.trimStart()); // a lazy continuation
      else break;
      i++;
    }
    let task: boolean | null = null;
    const t = /^\[([ xX])\][ ]+/.exec(body[0]);
    if (t) {
      task = t[1] !== " ";
      body[0] = body[0].slice(t[0].length);
    }
    items.push({ task, c: depth < MAX_DEPTH ? blocks(body, ids, depth + 1) : [{ t: "p", c: [{ t: "text", s: body.join(" ") }] }] });
    // blank lines between items
    let k = i;
    while (k < lines.length && blank(lines[k])) k++;
    if (k > i && k < lines.length && ITEM.test(lines[k])) i = k;
  }
  return { block: { t: "list", ordered, start: ordered ? parseInt(first[2], 10) : 1, items }, next: i };
}

// ---- inlines ----

const PUNCT = /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/;

export function safeHref(url: string): string | null {
  const u = url.trim();
  if (/^(https?:|mailto:)/i.test(u)) return u;
  if (/^[a-z][a-z0-9+.-]*:/i.test(u)) return null; // javascript:, data:, file:, vbscript:, …
  if (u.startsWith("//")) return null; // another host, scheme-relative
  return u; // a relative path or an anchor
}

export function inlines(s: string, depth = 0): Inline[] {
  const out: Inline[] = [];
  const close = brackets(s);
  let text = "";
  const flush = () => {
    if (text) out.push({ t: "text", s: text });
    text = "";
  };
  let i = 0;
  while (i < s.length) {
    const ch = s[i];
    if (ch === "\\" && i + 1 < s.length) {
      if (s[i + 1] === "\n") {
        flush();
        out.push({ t: "br" });
        i += 2;
        continue;
      }
      if (PUNCT.test(s[i + 1])) {
        text += s[i + 1];
        i += 2;
        continue;
      }
    }
    if (ch === "\n") {
      if (text.endsWith("  ")) {
        text = text.replace(/ +$/, "");
        flush();
        out.push({ t: "br" });
      } else text = text.replace(/ +$/, "") + " ";
      i++;
      continue;
    }
    if (ch === "`") {
      const run = "`".repeat(runAt(s, i, "`"));
      const lim = i + run.length + SCAN;
      let end = s.indexOf(run, i + run.length);
      while (end >= 0 && end < lim && s[end + run.length] === "`") end = s.indexOf(run, end + runAt(s, end, "`"));
      if (end >= 0 && end < lim) {
        flush();
        let code = s.slice(i + run.length, end).replace(/\n/g, " ");
        if (/^ .* $/.test(code) && code.trim()) code = code.slice(1, -1);
        out.push({ t: "code", s: code });
        i = end + run.length;
        continue;
      }
      text += run;
      i += run.length;
      continue;
    }
    if (ch === "<") {
      const m = /^<((?:https?:\/\/|mailto:)[^\s<>]+)>/i.exec(s.slice(i, i + SCAN));
      if (m) {
        flush();
        out.push({ t: "link", href: m[1], c: [{ t: "text", s: m[1].replace(/^mailto:/i, "") }] });
        i += m[0].length;
        continue;
      }
    }
    if (ch === "!" && s[i + 1] === "[") {
      const r = linkAt(s, i + 1, close);
      if (r) {
        flush();
        out.push({ t: "img", alt: plain(inlines(r.label, depth + 1)) });
        i = r.end;
        continue;
      }
    }
    if (ch === "[") {
      const r = linkAt(s, i, close);
      if (r) {
        flush();
        const href = safeHref(r.url);
        const c = depth < MAX_DEPTH ? inlines(r.label, depth + 1) : [{ t: "text" as const, s: r.label }];
        if (href !== null) out.push({ t: "link", href, c });
        else out.push(...c);
        i = r.end;
        continue;
      }
    }
    if ((ch === "*" || ch === "_" || ch === "~") && depth < MAX_DEPTH) {
      const r = emphasisAt(s, i, depth);
      if (r) {
        flush();
        out.push(r.node);
        i = r.end;
        continue;
      }
      const n = runAt(s, i, ch); // not an emphasis: the whole run is text
      text += ch.repeat(n);
      i += n;
      continue;
    }
    if (ch === "h" && (i === 0 || /[\s(]/.test(s[i - 1]))) {
      const m = /^https?:\/\/[^\s<>]*[^\s<>.,:;"')\]!?*_~]/.exec(s.slice(i, i + SCAN));
      if (m) {
        flush();
        out.push({ t: "link", href: m[0], c: [{ t: "text", s: m[0] }] });
        i += m[0].length;
        continue;
      }
    }
    text += ch;
    i++;
  }
  flush();
  return out;
}

// [label](url "title") at s[i] === "[": the label (balanced brackets), the url.
function linkAt(s: string, i: number, close: Map<number, number>): { label: string; url: string; end: number } | null {
  const k = close.get(i);
  if (k === undefined || s[k + 1] !== "(") return null;
  const m = /^\(\s*(<[^<>\n]*>|[^\s()]*(?:\([^\s()]*\)[^\s()]*)*)(?:\s+("[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/.exec(s.slice(k + 1, k + 1 + SCAN));
  if (!m) return null;
  const url = m[1].startsWith("<") ? m[1].slice(1, -1) : m[1];
  return { label: s.slice(i + 1, k), url, end: k + 1 + m[0].length };
}

// *em*, **strong**, ~~del~~ (and with _): the closing run of the same kind, not after a space;
// _ not inside a word.
function emphasisAt(s: string, i: number, depth: number): { node: Inline; end: number } | null {
  const ch = s[i];
  const runLen = runAt(s, i, ch);
  if (ch === "~" && runLen !== 2) return null;
  const n = ch === "~" ? 2 : Math.min(runLen, 3);
  const next = s[i + runLen];
  if (!next || /\s/.test(next)) return null;
  if (ch === "_" && i > 0 && /[\p{L}\p{N}]/u.test(s[i - 1])) return null;
  const want = n === 3 ? 2 : n; // ***x***: strong around em (the inner run is parsed again)
  const tok = ch.repeat(want);
  let k = i + want;
  const lim = Math.min(s.length, i + EM_SCAN);
  while (k < lim) {
    if (s[k] === "\\") {
      k += 2;
      continue;
    }
    if (s[k] === "`") {
      k += runAt(s, k, "`");
      continue;
    }
    if (s.startsWith(tok, k) && !/\s/.test(s[k - 1]) && (ch !== "_" || !/[\p{L}\p{N}]/u.test(s[k + want] ?? ""))) {
      // a longer run here closes an inner emphasis first (**a *b***): take its last `want`
      let e = k;
      while (s[e + want] === ch && want < 3) e++;
      const inner = s.slice(i + want, e);
      if (!inner) return null;
      const c = inlines(inner, depth + 1);
      const t = ch === "~" ? "del" : want === 2 ? "strong" : "em";
      return { node: { t, c }, end: e + want };
    }
    k++;
  }
  return null;
}
