// A terminal's text to select on a phone (src/termtext.ts): the scrollback and the screen, a
// wrapped row joined to the one before it (a long command or URL copies whole), capped.

import { test } from "node:test";
import assert from "node:assert/strict";
import { bufferText } from "../src/termtext.ts";

// rows as the terminal holds them: [text with its trailing blanks, wrapped onto from the row before]
function src(rows: [string, boolean][]) {
  return {
    length: rows.length,
    text: (y: number, trim: boolean) => (trim ? rows[y][0].replace(/\s+$/, "") : rows[y][0]),
    wrapped: (y: number) => rows[y][1],
  };
}

test("select text: every row, a wrapped one continuing the row before it, blank rows at the end dropped", () => {
  const s = src([
    ["$ echo hi   ", false],
    ["hi          ", false],
    ["$ curl https://exa", false],
    ["mple.com/a b ", true],
    ["            ", false],
    ["            ", false],
  ]);
  assert.equal(bufferText(s, 1000), "$ echo hi\nhi\n$ curl https://example.com/a b");
});

test("select text: a space at the wrap is kept (the row before is not trimmed)", () => {
  assert.equal(bufferText(src([["one two ", false], ["three", true]]), 1000), "one two three");
});

test("select text: at most the last N rows, starting at a whole line", () => {
  const rows: [string, boolean][] = [];
  for (let i = 0; i < 10; i++) rows.push([`line ${i}`, false]);
  assert.equal(bufferText(src(rows), 3), "line 7\nline 8\nline 9");
  // the cap lands inside a wrapped line: it starts at that line's first row
  const w = src([["a", false], ["bbbb", false], ["cccc", true], ["dd", true], ["e", false]]);
  assert.equal(bufferText(w, 2), "bbbbccccdd\ne");
  assert.equal(bufferText(src([]), 10), "");
});
