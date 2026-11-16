// A terminal in a pane: one xterm.js copy (term.ts) and its stream (termstream.ts), attached to the
// tab the pane shows. Only shown tabs are attached; the core alone answers queries and sizes it.

import { useEffect, useRef, useState } from "preact/hooks";
import { createTerm, type Fit, type TermView } from "../term.ts";
import { TermStream } from "../termstream.ts";
import { useApp } from "./ctx.ts";
import { storageGet, storageSet } from "../ui/dom.ts";

export interface TermHandle {
  view: TermView;
  stream: TermStream;
}

// The pane that has the keyboard registers here (window.request term_fit, the key bar).
let focusedHandle: TermHandle | null = null;
export const focusedTerm = () => focusedHandle;
export function focusedFit(): Fit | null {
  return focusedHandle?.view.fit() ?? null;
}
// Each shown terminal by its tab: a new terminal's grid is the one its pane fits (term_fit).
const byTab = new Map<number, TermHandle>();
export function fitFor(tabId: number): Fit | null {
  const h = byTab.get(tabId) ?? focusedHandle;
  return h?.view.fit() ?? null;
}

export function termFontSize(phone: boolean): number {
  const saved = Number(storageGet("deckhand.termFont"));
  if (saved >= 8 && saved <= 24) return saved;
  return phone ? 12 : 13;
}

// Every terminal's text size at once (this browser's choice; 0: back to the default).
const allViews = new Set<TermHandle>();
export function setTermFont(px: number): void {
  if (px) px = Math.max(8, Math.min(24, px));
  storageSet("deckhand.termFont", px ? String(px) : "");
  const size = termFontSize(window.matchMedia("(max-width: 760px)").matches);
  for (const t of allViews) {
    t.view.setFontSize(size);
    t.stream.refit();
  }
}

export function TermPane(props: {
  tabId: number;
  attachable: boolean; // the tab has a terminal the core can stream (running, has_term)
  focused: boolean;
  keyboard: boolean; // typing goes straight in (desktop, or the phone's raw keys)
  onFocus?: () => void;
  onInput?: (b: Uint8Array) => Uint8Array; // the phone's sticky modifiers
  handleRef?: (h: TermHandle | null) => void;
}) {
  const app = useApp();
  const box = useRef<HTMLDivElement>(null);
  const h = useRef<TermHandle | null>(null);
  const [note, setNote] = useState("");
  const latest = useRef(props);
  latest.current = props;
  const light = document.documentElement.dataset.light === "1";
  const look = document.documentElement.dataset.look ?? "";

  // one copy per pane, for its life
  useEffect(() => {
    const view = createTerm({ light, fontSize: termFontSize(app.phone) });
    view.mount(box.current!);
    const stream = new TermStream(app.link, view);
    view.onInput((b) => {
      const f = latest.current.onInput;
      stream.input(f ? f(b) : b);
    });
    view.onLink((url) => app.setOverlay({ link: url }));
    stream.events((e) => setNote(e.kind === "error" ? "No terminal for this tab yet." : e.kind === "closed" ? "This tab's terminal closed." : ""));
    h.current = { view, stream };
    allViews.add(h.current);
    props.handleRef?.(h.current);
    const ro = new ResizeObserver(() => stream.refit());
    ro.observe(box.current!);
    const vis = () => stream.focus(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", vis);
    return () => {
      ro.disconnect();
      document.removeEventListener("visibilitychange", vis);
      for (const [k, v] of byTab) if (v === h.current) byTab.delete(k);
      if (h.current) allViews.delete(h.current);
      stream.dispose();
      if (focusedHandle === h.current) focusedHandle = null;
      props.handleRef?.(null);
      view.dispose();
      h.current = null;
    };
  }, []);

  // the tab it shows; again after the link came back (a fresh channel and snapshot)
  const linkUp = app.link.up;
  useEffect(() => {
    const t = h.current;
    if (!t) return;
    for (const [k, v] of byTab) if (v === t) byTab.delete(k);
    byTab.set(props.tabId, t);
    if (!props.attachable || !linkUp) {
      t.stream.detach();
      return;
    }
    if (t.stream.tabId === props.tabId && !t.stream.attached) t.stream.reattach();
    else t.stream.attach(props.tabId);
  }, [props.tabId, props.attachable, linkUp]);

  useEffect(() => {
    const t = h.current;
    if (!t) return;
    if (props.focused) focusedHandle = t;
    t.view.setKeyboard(props.focused && props.keyboard);
  }, [props.focused, props.keyboard]);

  useEffect(() => {
    h.current?.view.setLight(light);
  }, [light, look]);

  return (
    <div class="term-host" onMouseDown={() => latest.current.onFocus?.()}>
      <div class="term" ref={box} />
      {note ? <div class="term-note">{note}</div> : null}
    </div>
  );
}
