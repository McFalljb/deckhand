// A terminal's text to select on a phone (src/termtext.ts): the scrollback and the screen, a
// wrapped row joined to the one before it (a long command or URL copies whole), capped.

import { test } from "node:test";
import assert from "node:assert/strict";
import { bufferText } from "../src/termtext.ts";

// rows as the terminal holds them: [text with its trailing blanks, wrapped onto from the row before,
// starts with a wide character, its last cell is empty]
function src(rows: [string, boolean, boolean?, boolean?][]) {
  return {
    length: rows.length,
    text: (y: number, trim: boolean) => (trim ? rows[y][0].replace(/\s+$/, "") : rows[y][0]),
    wrapped: (y: number) => rows[y][1],
    wideStart: (y: number) => !!rows[y][2],
    lastEmpty: (y: number) => !!rows[y][3],
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

test("select text: a wide character (CJK, emoji) that did not fit at the row's end wraps whole: the blank cell it left is not text", () => {
  // 5 columns: "abcd" then a wide 漢 that needs two cells: the last cell stays empty, 漢 starts the next row
  assert.equal(bufferText(src([["abcd ", false, false, true], ["漢字", true, true]]), 100), "abcd漢字");
  // a real space at the wrap, before an ordinary character, stays
  assert.equal(bufferText(src([["abcd ", false, false, false], ["x", true]]), 100), "abcd x");
});
