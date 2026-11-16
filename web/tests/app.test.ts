import { test } from "node:test";
import assert from "node:assert/strict";
import { score } from "../src/app/match.ts";
import { tabView } from "../src/status.ts";

test("palette score: prefix, word start, anywhere, in order, none", () => {
  assert.equal(score("Split pane right", ""), 1);
  assert.equal(score("Split pane right", "split"), 100);
  assert.ok(score("Split pane right", "pane") > score("Unpaned", "pane"));
  assert.ok(score("Split pane right", "pane") > score("Split pane right", "spr"));
  assert.equal(score("Split pane right", "spr"), 10);
  assert.equal(score("Split pane right", "zz"), 0);
});

test("tab marks: waiting kinds, progress, finished", () => {
  const base = { id: 1, machine: 0, kind: { pi_tab: {} }, title: "", status: "running", agent: "idle", waiting: false, question: false, unseen: false };
  assert.equal(tabView({ ...base, waiting: true, prog: { state: "waiting", kind: "permission", msg: "Run rm?" } }).mark, "permission");
  const w = tabView({ ...base, agent: "working", prog: { state: "working", kind: "", progress: 40 } });
  assert.equal(w.mark, "progress");
  assert.equal(w.progress, 0.4);
  assert.equal(tabView({ ...base, unseen: true }).mark, "done");
  assert.equal(tabView(base).mark, "idle");
});
