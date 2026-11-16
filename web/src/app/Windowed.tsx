// A long list drawn only where it shows: its items have known heights, so the list keeps its
// whole height (spacers above and below) and renders the items in its scroll container's view,
// plus a margin. 400 projects cost what 20 do.

import type { ComponentChildren } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";

export interface WItem {
  key: string;
  h: number; // its height in px (rows: the row height; a divider: its own)
  draw: () => ComponentChildren;
}

const MARGIN = 400; // px drawn beyond the view, each way

export function Windowed({ items }: { items: WItem[] }) {
  const box = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ top: 0, h: 1200 });
  // the scroll container (the column's .nav) and where this list sits in it
  useLayoutEffect(() => {
    const el = box.current;
    const sc = el?.closest(".nav") as HTMLElement | null;
    if (!el || !sc) return;
    let queued = false;
    const measure = () => {
      queued = false;
      const top = sc.scrollTop - (el.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop);
      setView((v) => (Math.abs(v.top - top) < 40 && v.h === sc.clientHeight ? v : { top, h: sc.clientHeight }));
    };
    const onScroll = () => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(measure);
    };
    measure();
    sc.addEventListener("scroll", onScroll, { passive: true });
    const ro = new ResizeObserver(onScroll);
    ro.observe(sc);
    return () => {
      sc.removeEventListener("scroll", onScroll);
      ro.disconnect();
    };
  }, []);
  // the list above it changed height (Open rows, a fold): measure again after the paint
  useEffect(() => {
    const el = box.current;
    const sc = el?.closest(".nav") as HTMLElement | null;
    if (!el || !sc) return;
    const top = sc.scrollTop - (el.getBoundingClientRect().top - sc.getBoundingClientRect().top + sc.scrollTop);
    if (Math.abs(view.top - top) >= 40 || view.h !== sc.clientHeight) setView({ top, h: sc.clientHeight });
  });
  let y = 0;
  let before = 0;
  const shown: WItem[] = [];
  const lo = view.top - MARGIN;
  const hi = view.top + view.h + MARGIN;
  for (const it of items) {
    const end = y + it.h;
    if (end < lo) before = end;
    else if (y <= hi) shown.push(it);
    y = end;
  }
  const drawnH = shown.reduce((a, it) => a + it.h, 0);
  const after = Math.max(0, y - before - drawnH);
  return (
    <div ref={box} class="windowed">
      <div class="w-spacer" style={{ height: before + "px" }} />
      {shown.map((it) => (
        <div key={it.key} class="w-item" style={{ height: it.h + "px" }}>
          {it.draw()}
        </div>
      ))}
      <div class="w-spacer" style={{ height: after + "px" }} />
    </div>
  );
}
