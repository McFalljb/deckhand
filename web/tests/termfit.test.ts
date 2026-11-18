// Who sizes a shared terminal (src/termfit.ts): the client the user is using asks again; never
// because another resized, never on a scroll, never without the keyboard, never twice in flight.

import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldReclaim, RECLAIM_IN_FLIGHT, type Interaction } from "../src/termfit.ts";

const phone = { cols: 44, rows: 30 };
const mac = { cols: 140, rows: 40 };

test("a key, a tap, focus or the page shown again: asked again when the grid is another's", () => {
  for (const k of ["key", "tap", "focus", "visible"] as Interaction[]) {
    assert.equal(shouldReclaim(phone, mac, k, true), true, k);
  }
});

test("its own grid already: nothing sent (no request equal to the current size)", () => {
  for (const k of ["key", "tap", "focus", "visible"] as Interaction[]) {
    assert.equal(shouldReclaim(phone, { ...phone }, k, true), false, k);
  }
  assert.equal(shouldReclaim(phone, { cols: 44, rows: 29 }, "key", true), true, "rows count too");
});

test("a scroll alone never takes the size: reading back does not reflow the other screen", () => {
  assert.equal(shouldReclaim(phone, mac, "scroll", true), false);
});

test("not where the user cannot type: a peek, a kept terminal, one under a sheet", () => {
  for (const k of ["key", "tap", "focus", "visible"] as Interaction[]) {
    assert.equal(shouldReclaim(phone, mac, k, false), false, k);
  }
});

test("not measurable yet, or no grid yet: nothing", () => {
  assert.equal(shouldReclaim(null, mac, "key", true), false);
  assert.equal(shouldReclaim(phone, null, "key", true), false);
});

test("its own ask on its way: the next key does not ask again; once it is old, it does", () => {
  const now = 50_000;
  assert.equal(shouldReclaim(phone, mac, "key", true, phone, now - 10, now), false);
  assert.equal(shouldReclaim(phone, mac, "key", true, phone, now - RECLAIM_IN_FLIGHT, now), true);
  // it asked another grid (its pane changed since): this one is asked
  assert.equal(shouldReclaim(phone, mac, "key", true, { cols: 50, rows: 30 }, now - 10, now), true);
});
