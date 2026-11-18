// A one-finger drag on a terminal as wheel lines (src/touchscroll.ts): a slop before it counts, the
// distance in cells with the remainder kept, and a coast after the finger lifts that decays.

import { test } from "node:test";
import assert from "node:assert/strict";
import { TouchScroll, SCROLL_SLOP } from "../src/touchscroll.ts";

const CELL = 16;

test("a tap or a small wobble never scrolls", () => {
  const s = new TouchScroll();
  s.start(100, 100, 0);
  assert.deepEqual(s.move(103, 104, 10, CELL), { state: "pending", lines: 0 });
  assert.deepEqual(s.move(100, 100 + SCROLL_SLOP - 1, 20, CELL), { state: "pending", lines: 0 });
  assert.equal(s.scrolling, false);
  assert.equal(s.end(30), false);
});

test("past the slop it scrolls; finger down is back in history (negative lines, like wheel up)", () => {
  const s = new TouchScroll();
  s.start(100, 100, 0);
  const r = s.move(100, 100 + SCROLL_SLOP + 1, 10, CELL);
  assert.equal(r.state, "scroll");
  assert.equal(r.lines, 0); // the slop itself does not count as distance
  assert.equal(s.move(100, 109 + 2 * CELL, 20, CELL).lines, -2);
  assert.equal(s.move(100, 109 + 2 * CELL - 3 * CELL, 30, CELL).lines, 3);
});

test("the remainder is kept across moves, no line lost or gained", () => {
  const s = new TouchScroll();
  s.start(0, 0, 0);
  s.move(0, -SCROLL_SLOP - 1, 1, CELL); // starts scrolling at y = -9
  let total = 0;
  let y = -SCROLL_SLOP - 1;
  for (let i = 0; i < 40; i++) {
    y -= 5; // 5 px a move: 200 px in all
    total += s.move(0, y, 2 + i, CELL).lines;
  }
  assert.equal(total, Math.trunc(200 / CELL)); // 12, and 8 px still held
  assert.equal(s.move(0, y - 8, 50, CELL).lines, 1);
});

test("a mostly sideways drag is left alone for the whole gesture", () => {
  const s = new TouchScroll();
  s.start(100, 100, 0);
  assert.equal(s.move(120, 105, 10, CELL).state, "ignored");
  assert.deepEqual(s.move(120, 200, 20, CELL), { state: "ignored", lines: 0 });
  assert.equal(s.end(30), false);
});

test("a flick coasts, slows down and stops; a new touch stops it", () => {
  const s = new TouchScroll();
  s.start(0, 500, 0);
  let y = 500;
  for (let t = 16; t <= 96; t += 16) {
    y -= 32; // 2 px/ms upward
    s.move(0, y, t, CELL);
  }
  assert.equal(s.end(100), true);
  assert.ok(s.coasting);
  let lines = 0;
  let last = Infinity;
  let t = 100;
  for (let i = 0; i < 400 && s.coasting; i++) {
    t += 16;
    const l = s.step(t, CELL);
    assert.ok(l >= 0, "coasts the same way as the flick");
    assert.ok(l <= Math.max(last, 3), "never speeds up");
    last = l;
    lines += l;
  }
  assert.equal(s.coasting, false, "stops by itself");
  assert.ok(lines > 5, `coasted ${lines} lines`);

  s.start(0, 0, 0);
  y = 0;
  for (let tt = 16; tt <= 96; tt += 16) s.move(0, (y += 32), tt, CELL);
  assert.equal(s.end(100), true);
  assert.ok(s.step(116, CELL) <= 0);
  s.start(0, 0, 120); // a finger lands
  assert.equal(s.coasting, false);
  assert.equal(s.step(140, CELL), 0);
});

test("a finger that stopped before lifting does not coast", () => {
  const s = new TouchScroll();
  s.start(0, 500, 0);
  s.move(0, 400, 50, CELL);
  s.move(0, 300, 100, CELL);
  assert.equal(s.end(400), false); // held still for 300 ms
  assert.equal(s.coasting, false);
});

test("a slow drag does not coast", () => {
  const s = new TouchScroll();
  s.start(0, 500, 0);
  for (let t = 50; t <= 1000; t += 50) s.move(0, 500 - t * 0.1, t, CELL);
  assert.equal(s.end(1000), false);
});

test("an unusable cell height scrolls nothing", () => {
  const s = new TouchScroll();
  s.start(0, 0, 0);
  s.move(0, 50, 10, 0);
  assert.equal(s.move(0, 200, 20, 0).lines, 0);
  assert.equal(s.move(0, 300, 30, NaN).lines, 0);
});

test("a touch that stops a coast is swallowed only if the coast moved a line in the last 100 ms", () => {
  const flick = (s: TouchScroll) => {
    s.start(0, 500, 0);
    let y = 500;
    for (let t = 16; t <= 96; t += 16) s.move(0, (y -= 32), t, CELL);
    assert.equal(s.end(100), true);
  };
  const s = new TouchScroll();
  flick(s);
  let t = 100;
  while (s.step((t += 16), CELL) === 0 && t < 400);
  assert.equal(s.start(0, 0, t + 50), true, "moving: the tap stops it, and is not a tap");

  flick(s);
  t = 100;
  s.step((t += 16), CELL);
  s.stop(); // the scrollback's end: nothing moves any more
  assert.equal(s.coasting, false);
  assert.equal(s.start(0, 0, t + 20), false, "stopped at the end: the next tap is a tap");

  flick(s);
  // still coasting, but its last line went long ago (slowing to a stop)
  assert.equal(s.start(0, 0, 100 + 500), false);
});
