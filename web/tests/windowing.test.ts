// The windowed list's slice (src/app/windowing.ts): the rows in view plus a margin, and rows that
// must stay drawn wherever they are (the Files tab's name field: removing it would blur it).

import { test } from "node:test";
import assert from "node:assert/strict";
import { windowSlice } from "../src/app/windowing.ts";

const rows = (n: number, keep: number[] = []) => Array.from({ length: n }, (_, i) => ({ h: 10, keep: keep.includes(i) }));

test("only the rows in range, spacers for the rest", () => {
  const s = windowSlice(rows(100), 200, 300);
  assert.deepEqual(s.map((p) => p.i), Array.from({ length: 12 }, (_, k) => 19 + k));
  assert.equal(s[0].before, 190);
  assert.equal(s.at(-1)!.after, 100 * 10 - 310);
});

test("a kept row far out of range is drawn, its place kept", () => {
  const s = windowSlice(rows(100, [2, 90]), 400, 500);
  const idx = s.map((p) => p.i);
  assert.ok(idx.includes(2) && idx.includes(90), idx.join(","));
  // every row's height is accounted for exactly once
  const total = s.reduce((a, p) => a + p.before + 10, 0) + s.at(-1)!.after;
  assert.equal(total, 1000);
});
