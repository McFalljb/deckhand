// Windowed.tsx's slice: which items to draw for a view [lo, hi] (px, margin included), each with
// the gap above it (the heights of the items not drawn since the previous one); the last also has
// the gap below. A kept item is drawn wherever it is (the Files tab's name field: removing a
// focused field blurs it, and a blur commits).

export interface Part {
  i: number;
  before: number;
  after: number;
}

export function windowSlice(items: { h: number; keep?: boolean }[], lo: number, hi: number): Part[] {
  const out: Part[] = [];
  let y = 0;
  let gap = 0;
  items.forEach((it, i) => {
    const end = y + it.h;
    if (it.keep || (end >= lo && y <= hi)) {
      out.push({ i, before: gap, after: 0 });
      gap = 0;
    } else gap += it.h;
    y = end;
  });
  if (out.length) out[out.length - 1].after = gap;
  return out;
}
