// Where a touch scroll goes in a terminal (src/touchroute.ts): the wheel's own rule, nothing sent
// from a pane not typed into, no coast of keystrokes, and xterm.js's stdin only for the dispatch.

import { test } from "node:test";
import assert from "node:assert/strict";
import { routeCoasts, touchRoute, WheelWindow } from "../src/touchroute.ts";

test("normal screen without wheel reports: the scrollback, typed into or not", () => {
  for (const m of ["none", "x10"]) {
    assert.equal(touchRoute(m, "normal", true), "scrollback");
    assert.equal(touchRoute(m, "normal", false), "scrollback");
  }
});

test("alternate screen or wheel reports: sent only from the pane typed into", () => {
  assert.equal(touchRoute("none", "alternate", true), "arrows");
  assert.equal(touchRoute("x10", "alternate", true), "arrows");
  for (const m of ["vt200", "drag", "any"]) {
    assert.equal(touchRoute(m, "normal", true), "reports");
    assert.equal(touchRoute(m, "alternate", true), "reports");
    assert.equal(touchRoute(m, "alternate", false), "none");
  }
  assert.equal(touchRoute("none", "alternate", false), "none"); // scroll reports off: nothing at all
});

test("a flick coasts the scrollback and wheel reports, never arrow keys", () => {
  assert.equal(routeCoasts("scrollback"), true);
  assert.equal(routeCoasts("reports"), true);
  assert.equal(routeCoasts("arrows"), false);
  assert.equal(routeCoasts("none"), false);
});

test("stdin on and the scroll's output path only during the dispatch, restored after a throw", () => {
  const w = new WheelWindow();
  let disabled = true;
  const stdin = { disabled: () => disabled, setDisabled: (v: boolean) => void (disabled = v) };
  let seen: [boolean, boolean] | null = null;
  w.run(stdin, () => (seen = [disabled, w.active]));
  assert.deepEqual(seen, [false, true]);
  assert.equal(disabled, true);
  assert.equal(w.active, false);
  assert.throws(() => w.run(stdin, () => { throw new Error("x"); }));
  assert.equal(disabled, true);
  assert.equal(w.active, false);
  disabled = false; // a pane with raw keys: stays on
  w.run(stdin, () => {});
  assert.equal(disabled, false);
});
