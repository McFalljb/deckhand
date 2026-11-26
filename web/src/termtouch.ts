// One-finger scrolling on a terminal (phones, tablets, touch screens): xterm.js 6 scrolls with the
// wheel only (its viewport has no touch handling), so a drag did nothing. The drag becomes wheel
// lines (touchscroll.ts) handed to `scroll`, which does what the wheel does there (term.ts).
//
// Only one finger, and only once it has gone a few px mostly up or down: a tap still focuses (and
// brings up the keyboard), a sideways swipe and a pinch are left to the page. Once it scrolls the
// touch is the scroll's alone: no page scroll or pull-to-refresh, no mouse events, no click. A flick
// coasts only where the terminal says it may (the scrollback, wheel reports; never arrow keys), and
// stops at the scrollback's end, when the page hides, and on stop() (the pane lost the keyboard, a
// sheet opened). A new touch stops a coast; while the coast was still moving, that touch's tap is
// not a tap. Mouse, trackpad and wheel are untouched.

import { TouchScroll } from "./touchscroll.ts";

export interface TouchScrollOps {
  cellH(): number;
  // wheel lines (+: toward the newest output) at the point the finger is (client px); false:
  // nothing moved (the scrollback's end, nothing sent)
  scroll(lines: number, x: number, y: number): boolean;
  // a flick may coast on from here (not when the lines are keystrokes)
  coasts(): boolean;
}

export interface TouchScrolling {
  stop(): void; // any coast ends now
  dispose(): void;
}

export function installTouchScroll(el: HTMLElement, ops: TouchScrollOps): TouchScrolling {
  const s = new TouchScroll();
  let id = -1; // the finger followed
  let at = { x: 0, y: 0 };
  let frame = 0;
  let swallow = false; // this touch stopped a coast: its tap goes nowhere

  const stopCoast = () => {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
  };
  const coast = (t: number) => {
    frame = 0;
    const n = s.step(t, ops.cellH());
    if (n && !ops.scroll(n, at.x, at.y)) s.stop(); // at the end: over, not coasting on unseen
    if (s.coasting) frame = requestAnimationFrame(coast);
  };
  const find = (list: TouchList) => {
    for (let i = 0; i < list.length; i++) if (list[i].identifier === id) return list[i];
    return null;
  };

  const start = (e: TouchEvent) => {
    stopCoast();
    if (e.touches.length !== 1) {
      // a second finger (a pinch): not a scroll any more
      s.stop();
      id = -1;
      return;
    }
    const t = e.touches[0];
    id = t.identifier;
    at = { x: t.clientX, y: t.clientY };
    swallow = s.start(t.clientX, t.clientY, performance.now());
  };
  const move = (e: TouchEvent) => {
    const t = id < 0 || e.touches.length !== 1 ? null : find(e.changedTouches);
    if (!t) return;
    at = { x: t.clientX, y: t.clientY };
    const r = s.move(t.clientX, t.clientY, performance.now(), ops.cellH());
    if (r.state !== "scroll") return;
    if (e.cancelable) e.preventDefault();
    if (r.lines) ops.scroll(r.lines, at.x, at.y);
  };
  const end = (e: TouchEvent) => {
    if (id < 0 || !find(e.changedTouches)) return;
    id = -1;
    const scrolled = s.scrolling;
    if ((scrolled || swallow) && e.cancelable) e.preventDefault(); // no mouse events, no click
    swallow = false;
    if (s.end(performance.now())) {
      if (ops.coasts()) frame = requestAnimationFrame(coast); // rAF's time is performance.now's
      else s.stop(); // keystrokes: only while the finger moves
    }
  };
  const cancel = (e: TouchEvent) => {
    if (id < 0 || !find(e.changedTouches)) return;
    id = -1;
    swallow = false;
    s.stop();
  };

  const stop = () => {
    stopCoast();
    s.stop();
    id = -1;
    swallow = false;
  };
  const hidden = () => {
    if (document.visibilityState !== "visible") stop();
  };
  document.addEventListener("visibilitychange", hidden);
  el.addEventListener("touchstart", start, { passive: true });
  el.addEventListener("touchmove", move, { passive: false });
  el.addEventListener("touchend", end, { passive: false });
  el.addEventListener("touchcancel", cancel, { passive: true });
  return {
    stop,
    dispose() {
      stop();
      document.removeEventListener("visibilitychange", hidden);
      el.removeEventListener("touchstart", start);
      el.removeEventListener("touchmove", move);
      el.removeEventListener("touchend", end);
      el.removeEventListener("touchcancel", cancel);
    },
  };
}
