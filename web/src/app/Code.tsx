// Code with syntax colours (highlight.ts) for the file tabs (CodeEdit) and Markdown's code blocks
// (CodeBlock). File text is untrusted: it goes into the page only as text nodes, never as markup.
//
// CodeEdit is a textarea (the browser's own editing, selection, undo, input methods and phone
// keyboards) over a layer that paints the same text in colour: the textarea's text is transparent,
// its caret and selection show, and the layer follows its scrolling. The layer holds only the lines
// in view and some either side (OVERSCAN), so a long file costs what a screenful does; a file over
// the limits (HL_MAX_BYTES, HL_MAX_LINES), of no known language, with line breaks other than \n and
// \r\n (paintable), or that the lexer fails on is the plain textarea as before.

import type { ComponentChildren } from "preact";
import { useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import { highlightable, langForFence, langForPath, Lines, paintable, type Span } from "./highlight.ts";
import { codeMetrics } from "./phone.ts";

// The lexer's spans, or null (plain text) should it ever throw: a lexer bug never blanks the page.
function lexed(lexer: Lines, lines: string[], upTo: number): Span[][] | null {
  try {
    return lexer.get(lines, upTo);
  } catch (e) {
    console.error("highlight:", e);
    return null;
  }
}

const PAD_T = 8; // .code-text's top padding
const OVERSCAN = 60; // lines painted above and below the ones in view
const BLOCK_MAX_LINES = 2000; // a Markdown code block longer than this stays plain

// One line's text with its spans as coloured runs (text nodes and spans; never markup).
export function paint(line: string, spans: Span[] | undefined): ComponentChildren {
  if (!spans || !spans.length) return line;
  const out: ComponentChildren[] = [];
  let at = 0;
  for (const [a, b, t] of spans) {
    if (a > at) out.push(line.slice(at, a));
    out.push(<span class={"sy-" + t}>{line.slice(a, b)}</span>);
    at = b;
  }
  if (at < line.length) out.push(line.slice(at));
  return out;
}

// Text with line numbers: a gutter beside a textarea, scrolled together, coloured by path's language.
export function CodeEdit({ text, path, onEdit, phone = false }: { text: string; path: string; onEdit: (t: string) => void; phone?: boolean }) {
  const { cls, lineH: LINE_H } = codeMetrics(phone); // .code-edit's line-height
  const gutter = useRef<HTMLDivElement>(null);
  const area = useRef<HTMLTextAreaElement>(null);
  const layer = useRef<HTMLPreElement>(null);
  const lines = text.split("\n");
  const nums = useRef("");
  if (nums.current.split("\n").length !== lines.length) nums.current = Array.from({ length: lines.length }, (_, i) => i + 1).join("\n");
  const lang = langForPath(path);
  const on = lang !== "" && highlightable(text, lines.length) && paintable(text);
  const lexer = useRef<Lines | null>(null);
  if (on && lexer.current?.lang !== lang) lexer.current = new Lines(lang);
  // the lines painted: those in view (scroll top and height, from the textarea) and OVERSCAN either side
  const [view, setView] = useState({ top: 0, h: 1000 });
  const first = Math.max(0, Math.floor((view.top - PAD_T) / LINE_H) - OVERSCAN);
  const last = Math.min(lines.length - 1, Math.ceil((view.top + view.h) / LINE_H) + OVERSCAN);
  const spans = on ? lexed(lexer.current!, lines, last) : null;
  const follow = () => {
    const t = area.current;
    if (!t) return;
    if (gutter.current) gutter.current.scrollTop = t.scrollTop;
    if (layer.current) layer.current.style.transform = `translate(${-t.scrollLeft}px, ${-t.scrollTop}px)`;
    // past what is painted (less a margin): paint around the new view
    const top = Math.floor((t.scrollTop - PAD_T) / LINE_H);
    const bottom = Math.ceil((t.scrollTop + t.clientHeight) / LINE_H);
    if ((top < first + OVERSCAN / 3 && first > 0) || (bottom > last - OVERSCAN / 3 && last < lines.length - 1) || t.clientHeight !== view.h) {
      setView({ top: t.scrollTop, h: t.clientHeight });
    }
  };
  useLayoutEffect(follow);
  useLayoutEffect(() => {
    const t = area.current;
    // no autocorrect (iOS): as an attribute, since a browser with an autocorrect property reads
    // Preact's "off" as true
    t?.setAttribute("autocorrect", "off");
    if (!t || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(() => setView({ top: t.scrollTop, h: t.clientHeight }));
    ro.observe(t);
    return () => ro.disconnect();
  }, []);
  return (
    <div class={cls}>
      <div class="code-gutter" ref={gutter} aria-hidden="true">{nums.current}</div>
      <div class="code-main">
        {spans ? (
          <div class="code-layer" aria-hidden="true">
            <pre class="code-paint" ref={layer}>
              <div style={{ height: first * LINE_H }} />
              {spans.slice(first).map((sp, k) => <div class="code-line">{paint(lines[first + k], sp)}</div>)}
            </pre>
          </div>
        ) : null}
        <textarea
          ref={area}
          class={"code-text" + (spans ? " painted" : "")}
          value={text}
          spellcheck={false}
          autocomplete="off"
          autocapitalize="off"
          wrap="off"
          onInput={(e) => onEdit((e.target as HTMLTextAreaElement).value)}
          onScroll={follow}
          onKeyDown={(e) => {
            if (e.key === "Tab" && !e.metaKey && !e.ctrlKey) {
              e.preventDefault();
              const t = e.target as HTMLTextAreaElement;
              t.setRangeText("\t", t.selectionStart, t.selectionEnd, "end");
              onEdit(t.value);
            }
          }}
        />
      </div>
    </div>
  );
}

// A Markdown code block, coloured by its fence's language ("" or unknown: plain).
export function CodeBlock({ text, lang }: { text: string; lang: string }) {
  const body = useMemo(() => {
    const l = langForFence(lang);
    const lines = text.split("\n");
    if (!l || lines.length > BLOCK_MAX_LINES || !highlightable(text, lines.length) || !paintable(text)) return text;
    const spans = lexed(new Lines(l), lines, lines.length - 1);
    if (!spans) return text;
    return lines.map((ln, k) => [paint(ln, spans[k]), k < lines.length - 1 ? "\n" : ""]);
  }, [text, lang]);
  return <pre class="md-code"><code>{body}</code></pre>;
}
