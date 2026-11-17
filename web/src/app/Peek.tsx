// Peek (src/ui_peek.odin, docs/GUIDE.md "Peek"): a look at another open session's terminal
// without leaving the one on screen. Hover a Deck card or an Attention row on the desktop (a
// popover by it), long-press one on a phone (a sheet). It shows ONE terminal tab, live, as its
// last lines: the tab the card's Attention row names, else the session's active one. Peek only
// looks: its stream never sends a key, never says it has the keyboard and never asks for a size
// (TermStream's look), so the session on screen and the peeked program are left as they are. To
// answer, Open it.

import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { isTerminalTab, sessionTitle, type Tab } from "../state.ts";
import { tabView } from "../status.ts";
import { createTerm } from "../term.ts";
import { TermStream } from "../termstream.ts";
import { shownSession, useApp, type App } from "./ctx.ts";
import { Icon, StatusMark } from "./icons.tsx";
import { focusSession } from "./Sidebar.tsx";

const HOVER_OPEN_MS = 450;
const HOVER_CLOSE_MS = 220;
const LONG_PRESS_MS = 480;
const SWALLOW_MS = 600; // the click that ends a long press comes within this of the touch ending
const PEEK_W = 640;
const PEEK_H = 300;

// The tab a peek shows: the one named (an Attention row's), else the session's active one; a
// running terminal only.
export function peekTab(app: App, session: number, tab?: number): Tab | null {
  const tabs = app.store.tabs(session);
  const t = (tab && tabs.find((x) => x.id === tab)) || tabs.find((x) => x.id === app.store.session(session)?.active_tab) || tabs[0];
  if (!t || !isTerminalTab(t) || t.status !== "running") return null;
  return t;
}

// What can be peeked: an open session that is not the one on screen (a phone shows one only on
// its session screen), with a running terminal.
export function canPeek(app: App, session: number, tab?: number): boolean {
  return !onScreen(app, session) && !!peekTab(app, session, tab);
}

function onScreen(app: App, session: number): boolean {
  if (app.phone) return app.route.screen === "session" && app.route.session === session;
  return shownSession(app) === session;
}

let hoverTimer = 0;
let closeTimer = 0;
let pressTimer = 0;
let pressAt: { x: number; y: number } | null = null;
let swallowClick = false;
let swallowTimer = 0;
let openedAt = 0;

export function openPeek(app: App, session: number, tab: number | undefined, at: { x: number; y: number }) {
  const t = peekTab(app, session, tab);
  if (!t) return;
  window.clearTimeout(closeTimer);
  app.setOverlay({ peek: { session, tab: t.id, x: at.x, y: at.y } });
}

function keepPeek() {
  window.clearTimeout(closeTimer);
}
function leavePeek(app: App) {
  window.clearTimeout(hoverTimer);
  window.clearTimeout(closeTimer);
  closeTimer = window.setTimeout(() => app.setOverlay({ peek: null }), HOVER_CLOSE_MS);
}

// The touch ended: a long press's own click is swallowed if it comes soon; later taps are not.
function endPress() {
  window.clearTimeout(pressTimer);
  if (!swallowClick) return;
  window.clearTimeout(swallowTimer);
  swallowTimer = window.setTimeout(() => (swallowClick = false), SWALLOW_MS);
}

// A touch held still for LONG_PRESS_MS (a phone's long press): fire, and the tap that ends it goes
// nowhere (no click, no mouse events). The Files tab's rows use it for their sheet.
export function longPressProps(can: () => boolean, fire: (at: { x: number; y: number }) => void) {
  return {
    onPointerDown: (e: PointerEvent) => {
      swallowClick = false; // a new touch: the last long press's tap is over
      if (e.pointerType !== "touch" || !can()) return;
      pressAt = { x: e.clientX, y: e.clientY };
      window.clearTimeout(pressTimer);
      pressTimer = window.setTimeout(() => {
        swallowClick = true;
        navigator.vibrate?.(10);
        fire(pressAt ?? { x: 0, y: 0 });
      }, LONG_PRESS_MS);
    },
    onPointerMove: (e: PointerEvent) => {
      if (pressAt && Math.hypot(e.clientX - pressAt.x, e.clientY - pressAt.y) > 8) window.clearTimeout(pressTimer);
    },
    onPointerUp: () => endPress(),
    onPointerCancel: () => endPress(),
    // the long press fired: the touch's own mouse events and click go nowhere
    onTouchEnd: (e: TouchEvent) => {
      if (swallowClick) e.preventDefault();
    },
    onClickCapture: (e: MouseEvent) => {
      if (!swallowClick) return;
      swallowClick = false;
      e.stopImmediatePropagation();
      e.preventDefault();
    },
  };
}

// The handlers a peekable row or card spreads: hover (desktop) and long-press (phone). A long press
// also stops the tap that ends it from opening the session.
export function peekProps(app: App, session: number, tab?: number) {
  return {
    onMouseEnter: (e: MouseEvent) => {
      if (app.phone || !canPeek(app, session, tab)) return;
      const el = e.currentTarget as HTMLElement;
      window.clearTimeout(hoverTimer);
      window.clearTimeout(closeTimer);
      hoverTimer = window.setTimeout(() => {
        const r = el.getBoundingClientRect();
        openPeek(app, session, tab, { x: r.left, y: r.bottom });
      }, HOVER_OPEN_MS);
    },
    onMouseLeave: () => {
      if (!app.phone) leavePeek(app);
    },
    ...longPressProps(
      () => canPeek(app, session, tab),
      (at) => {
        openedAt = performance.now();
        openPeek(app, session, tab, at);
      },
    ),
  };
}

export function Peek() {
  const app = useApp();
  const { store } = app;
  const p = app.overlay.peek!;
  const s = store.session(p.session);
  const found = store.tab(p.tab);
  const box = useRef<HTMLDivElement>(null);
  const term = useRef<HTMLDivElement>(null);
  const [note, setNote] = useState("");
  const close = () => app.setOverlay({ peek: null });
  const gone = !s || !found || found.session.id !== p.session || onScreen(app, p.session);

  // it closes when its session or tab goes, or becomes the one on screen
  useEffect(() => {
    if (gone) close();
  }, [gone]);

  // the tab's terminal, looked at only
  useEffect(() => {
    if (!term.current) return;
    const view = createTerm({ light: document.documentElement.dataset.light === "1", fontSize: app.phone ? 10 : 11 });
    view.mount(term.current);
    view.setKeyboard(false);
    const stream = new TermStream(app.link, view, true);
    stream.events((e) => setNote(e.kind === "error" ? "No terminal for this tab yet." : e.kind === "closed" ? "This tab's terminal closed." : ""));
    stream.attach(p.tab);
    // its last lines: the grid moved up so the last row with text sits at the clip's bottom (an
    // agent's output and prompt; a terminal larger than the clip shows its bottom-left)
    const follow = window.setInterval(() => {
      const el = term.current, clip = el?.parentElement;
      const rows = el?.querySelector(".xterm-rows");
      if (!el || !clip || !rows || !rows.children.length) return;
      let last = rows.children.length - 1;
      while (last > 0 && !(rows.children[last].textContent ?? "").trim()) last--;
      const rowH = rows.getBoundingClientRect().height / rows.children.length;
      const total = el.getBoundingClientRect().height;
      const room = clip.clientHeight;
      const top = Math.min(0, Math.max(room - total, room - (last + 1) * rowH - 8));
      el.style.top = top + "px";
    }, 250);
    return () => {
      window.clearInterval(follow);
      stream.dispose();
      view.dispose();
    };
  }, [p.tab, app.link.up]);

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close();
      } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        open();
      }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  });

  // by its card: below it, or above when there is no room, inside the window
  useLayoutEffect(() => {
    if (app.phone || !box.current) return;
    const w = Math.min(PEEK_W, window.innerWidth - 32);
    const x = Math.max(16, Math.min(p.x, window.innerWidth - w - 16));
    const below = p.y + 8 + PEEK_H < window.innerHeight - 16;
    box.current.style.left = x + "px";
    box.current.style.width = w + "px";
    box.current.style.top = (below ? p.y + 8 : Math.max(16, p.y - PEEK_H - 56)) + "px";
  }, [p.x, p.y, app.phone]);

  if (gone) return null;
  const t = found!.tab;
  const v = tabView(t);
  const open = () => {
    close();
    focusSession(app, p.session, p.tab);
  };
  const panel = (
    <div
      ref={box}
      class={"peek" + (app.phone ? " sheet bottom" : "")}
      role="dialog"
      aria-label={"Peek: " + sessionTitle(store, s!)}
      onMouseEnter={keepPeek}
      onMouseLeave={() => !app.phone && leavePeek(app)}
      onMouseDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      <div class="peek-head">
        <StatusMark mark={v.mark} progress={v.progress} />
        <span class="peek-title">{sessionTitle(store, s!)}</span>
        <span class="muted small peek-tab">{t.title}</span>
        <span class="spacer" />
        <button type="button" class="btn small primary" onClick={open}>
          Open
        </button>
        <button type="button" class="icon-btn small" aria-label="Close peek" onClick={close}>
          <Icon name="close" size={14} />
        </button>
      </div>
      <div class="peek-clip">
        <div class="peek-term" ref={term} />
        {note ? <div class="term-note">{note}</div> : null}
      </div>
      <div class="muted small peek-foot">Peek only looks: Open it to answer.</div>
    </div>
  );
  if (app.phone)
    return (
      <div class="scrim" onClick={() => performance.now() - openedAt > 600 && close()}>
        {panel}
      </div>
    );
  return panel;
}
