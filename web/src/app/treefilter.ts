// The filter at once (#148 performance): while a typed filter is on its way to the core, the page
// narrows the Projects tree it holds by it, the core's way for what the page has (each word: a
// fuzzy match on the project's name, else a substring of its path), keeping a row's parents. The
// core's answer then replaces it (it also keeps projects whose sessions match, and orders by score).

import { score } from "./match.ts";
import type { WebProjectRow } from "../state.ts";

export function wordsOf(text: string): string[] {
  return text.toLowerCase().split(/\s+/).filter(Boolean);
}

export function rowMatches(r: WebProjectRow, words: string[]): boolean {
  const path = (r.path || "").toLowerCase();
  return words.every((w) => score(r.name || "", w) > 0 || path.includes(w));
}

// The rows that match (with their parents), in the tree's order. No words: the tree as it is.
export function narrowTree(rows: WebProjectRow[], text: string): WebProjectRow[] {
  const words = wordsOf(text);
  if (!words.length) return rows;
  const keep = new Array<boolean>(rows.length).fill(false);
  const parents: number[] = []; // the open chain of parents (by depth)
  rows.forEach((r, i) => {
    parents.length = Math.min(parents.length, r.depth);
    if (r.id && rowMatches(r, words)) {
      keep[i] = true;
      for (const p of parents) keep[p] = true;
    }
    parents[r.depth] = i;
  });
  return rows.filter((_, i) => keep[i]);
}
