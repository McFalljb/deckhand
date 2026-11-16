// The palette's match score for a label against a lowercased query: 0 no match, higher better (a
// prefix, then a word start, then anywhere, then the letters in order).
export function score(label: string, q: string): number {
  if (!q) return 1;
  const l = label.toLowerCase();
  const at = l.indexOf(q);
  if (at === 0) return 100;
  if (at > 0) return 60 - Math.min(at, 50) / 10 + (/[\s\-_/·:]/.test(l[at - 1]) ? 20 : 0);
  let i = 0;
  for (const c of q) {
    i = l.indexOf(c, i);
    if (i < 0) return 0;
    i++;
  }
  return 10;
}
