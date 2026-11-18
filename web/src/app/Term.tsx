// A terminal in a pane: one xterm.js copy (term.ts) and its stream (termstream.ts), attached to the
// tab the pane shows. Only shown tabs are attached; the core alone answers queries and sizes it.

import { useEffect, useRef, useState } from "preact/hooks";
import { createTerm, type Fit, type TermView } from "../term.ts";
import { TermStream } from "../termstream.ts";
import { useApp, type Overlay } from "./ctx.ts";
import { storageGet, storageSet } from "../ui/dom.ts";
import { barsFor } from "./bars.ts";

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

// A menu, sheet, the palette or another overlay is over the page: nothing types into or scrolls a
// terminal's program under it.
export function covering(o: Overlay): boolean {
  return !!(o.menu || o.sheet || o.palette || o.bell || o.link || o.copy || o.job || o.peek);
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
  const h = useRef<Held | null>(null);
  const [note, setNote] = useState("");
  const latest = useRef(props);
  latest.current = props;
  const light = document.documentElement.dataset.light === "1";
  const look = document.documentElement.dataset.look ?? "";

  // into this pane: a kept one (no snapshot: what it had is still there), else a new copy
  const show = (held: Held) => {
    h.current = held;
    held.input = (b) => {
      const f = latest.current.onInput;
      held.stream.input(f ? f(b) : b);
    };
    held.onNote = setNote;
    setNote(held.note);
    box.current!.appendChild(held.el);
    if (!held.mounted) {
      held.view.mount(held.el); // xterm.js measures its cells in the page
      held.mounted = true;
    }
    held.view.setLight(document.documentElement.dataset.light === "1");
    props.handleRef?.(held);
  };
  // out of this pane: kept attached while it fits the few kept, else let go
  const hide = (keep: boolean) => {
    const held = h.current;
    if (!held) return;
    h.current = null;
    for (const [k, v] of byTab) if (v === held) byTab.delete(k);
    if (focusedHandle === held) focusedHandle = null;
    held.onNote = () => {};
    held.input = () => {};
    held.el.remove();
    props.handleRef?.(null);
    if (keep && held.stream.attached && held.stream.tabId) keepTerm(held, app.phone);
    else dropTerm(held);
  };

  useEffect(() => {
    const ro = new ResizeObserver(() => h.current?.stream.refit());
    ro.observe(box.current!);
    const vis = () => h.current?.stream.focus(document.visibilityState === "visible");
    document.addEventListener("visibilitychange", vis);
    return () => {
      ro.disconnect();
      document.removeEventListener("visibilitychange", vis);
      hide(true); // Deck, Settings, another session: kept for coming back
    };
  }, []);

  // the tab it shows; again after the link came back (a fresh channel and snapshot)
  const linkUp = app.link.up;
  useEffect(() => {
    if (!linkUp) dropKept(); // their channels went with the link
    let t = h.current;
    if (t && t.stream.tabId !== props.tabId && t.stream.tabId) {
      hide(true);
      t = null;
    }
    if (!t) {
      const kept = takeKept(props.tabId);
      show(kept ?? newHeld(app, app.phone));
      t = h.current!;
      if (kept) {
        // shown again as it was: its grid is this pane's, it has the keyboard back
        if (document.visibilityState === "visible") t.stream.focus(true);
        t.stream.refit(true);
      }
    }
    for (const [k, v] of byTab) if (v === t) byTab.delete(k);
    byTab.set(props.tabId, t);
    if (!props.attachable || !linkUp) {
      t.stream.detach();
      return;
    }
    if (t.stream.tabId === props.tabId && t.stream.attached) return;
    if (t.stream.tabId === props.tabId) t.stream.reattach();
    else t.stream.attach(props.tabId);
  }, [props.tabId, props.attachable, linkUp]);

  useEffect(() => {
    const t = h.current;
    if (!t) return;
    if (props.focused) focusedHandle = t;
    // a phone types through the terminal's own field (termfield.ts), the desktop through xterm.js
    t.view.setKeyboard(props.focused && props.keyboard, app.phone);
  }, [props.focused, props.keyboard, props.tabId, app.phone]);

  // a touch scroll in a TUI sends what the wheel would only into the pane typed into (the phone's
  // one tab takes its text field's typing even when its keys do not go straight in), and not while
  // a menu, sheet or the palette is over it (a coast stops)
  const reports = props.focused && !covering(app.overlay);
  useEffect(() => {
    h.current?.view.setScrollReports(reports);
  }, [reports, props.tabId]);
  // a bar that asks something (a permission) comes up over the tab: a coast stops there
  const found = app.store.tab(props.tabId);
  const bars = found ? barsFor(app.store, found.tab).length : 0;
  useEffect(() => {
    if (bars) h.current?.view.stopScroll();
  }, [bars]);

  // a touch scroll in a TUI sends what the wheel would only into the pane typed into (the phone's
  // one tab takes its text field's typing even when its keys do not go straight in), and not while
  // a menu, sheet or the palette is over it (a coast stops)
  const o = app.overlay;
  const covered = !!(o.menu || o.sheet || o.palette || o.bell || o.link || o.copy || o.job || o.peek);
  const reports = props.focused && !covered;
  useEffect(() => {
    h.current?.view.setScrollReports(reports);
  }, [reports, props.tabId]);
  // a bar that asks something (a permission) comes up over the tab: a coast stops there
  const found = app.store.tab(props.tabId);
  const bars = found ? barsFor(app.store, found.tab).length : 0;
  useEffect(() => {
    if (bars) h.current?.view.stopScroll();
  }, [bars]);

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

// ---- kept terminals ----
// A pane that shows another tab, or goes (Deck, Settings, another session), keeps its terminal
// attached here, the last few only: showing that tab again needs no snapshot, and its scrollback
// is all there. Kept ones still take their tab's output (credit as on screen), never the keyboard;
// past the few, the oldest is detached and dropped (shown again: a fresh snapshot, as before).
interface Held extends TermHandle {
  el: HTMLDivElement;
  mounted: boolean;
  note: string;
  onNote: (s: string) => void;
  input: (b: Uint8Array) => void;
}

const KEEP_DESKTOP = 6;
const KEEP_PHONE = 3;
const kept = new Map<number, Held>(); // tab id → its terminal, oldest first

function newHeld(app: ReturnType<typeof useApp>, phone: boolean): Held {
  const el = document.createElement("div");
  el.className = "term-fill";
  const view = createTerm({ light: document.documentElement.dataset.light === "1", fontSize: termFontSize(phone) });
  const stream = new TermStream(app.link, view);
  const held: Held = { view, stream, el, mounted: false, note: "", onNote: () => {}, input: () => {} };
  view.onInput((b) => held.input(b));
  view.onScrollInput((b) => held.stream.input(b)); // only while shown: kept ones have reports off
  view.onLink((url) => app.setOverlay({ link: url }));
  stream.events((e) => {
    held.note = e.kind === "error" ? "No terminal for this tab yet." : e.kind === "closed" ? "This tab's terminal closed." : "";
    held.onNote(held.note);
  });
  allViews.add(held);
  return held;
}

function keepTerm(held: Held, phone: boolean): void {
  held.view.setKeyboard(false);
  held.view.setScrollReports(false);
  held.stream.focus(false);
  const tab = held.stream.tabId;
  const old = kept.get(tab);
  if (old && old !== held) dropTerm(old);
  kept.delete(tab);
  kept.set(tab, held);
  const max = phone ? KEEP_PHONE : KEEP_DESKTOP;
  for (const [k, v] of kept) {
    if (kept.size <= max) break;
    kept.delete(k);
    dropTerm(v);
  }
}

function takeKept(tab: number): Held | null {
  const held = kept.get(tab) ?? null;
  kept.delete(tab);
  return held;
}

function dropTerm(held: Held): void {
  allViews.delete(held);
  held.stream.dispose();
  held.view.dispose();
  held.el.remove();
}

function dropKept(): void {
  for (const v of kept.values()) dropTerm(v);
  kept.clear();
}

// How many are kept, and for which tabs (tests and the perf runs).
export const keptTabs = (): number[] => [...kept.keys()];
