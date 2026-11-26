// Status dots and marks (#195 item 4): the core computes them (tab_status_view, status_mark,
// session_row_status) and sends them as webst:<session>; the page reads them. Which tab shows
// which dot and mark is the core's table, src/core/web_view_test.odin web_view_status_table (it
// was this file's, the page's own reading, before the page stopped computing them).

import { test } from "node:test";
import assert from "node:assert/strict";
import { Store } from "../src/state.ts";
import { sessionView, stripView, tabView } from "../src/status.ts";

const base = { id: 1, machine: 0, title: "", status: "running", agent: "unknown", waiting: false, question: false, unseen: false, prog: { state: "none", kind: "" } };
const pi = (x: object) => ({ ...base, kind: { pi_tab: {} }, ...x });
const shell = (x: object) => ({ ...base, kind: { shell_tab: {} }, ...x });

// A store with session 3 open, these tabs and the core's marks for them.
function store(tabs: any[], marks: Record<number, [string, string, number]>, from = 0) {
  const s = new Store();
  s.applyFull({
    version: 1,
    state: {
      sessions: { open_sessions: [{ id: 3, machine: 0, project_id: 1, active_tab: tabs[0]?.id ?? 0, title: "" }], current_session: 3 },
      "tabs:3": tabs,
      "webst:3": { from, tabs: marks },
    },
  });
  return s;
}

test("status: a tab's dot, mark and progress are the core's (progress: its percent, as 0..1)", () => {
  const t = shell({ id: 4 });
  for (const [m, want] of [
    [["working", "progress", 40], ["working", "progress", 0.4]],
    [["working", "working", -1], ["working", "working", -1]],
    [["waiting", "permission", -1], ["waiting", "permission", -1]],
    [["unseen", "done", -1], ["unseen", "done", -1]],
    [["none", "idle", -1], ["none", "idle", -1]],
  ] as [[string, string, number], [string, string, number]][]) {
    const v = tabView(store([t], { 4: m }), t as any);
    assert.deepEqual([v.dot, v.mark, v.progress], want, m.join(" "));
  }
});

test("status: what it waits for is OSC 7501's message, only while waiting; since is the tab's", () => {
  const t = shell({ id: 4, status_since: 7, prog: { state: "blocked", kind: "question", msg: "Deploy?" } });
  const w = tabView(store([t], { 4: ["waiting", "question", -1] }), t as any);
  assert.equal(w.msg, "Deploy?");
  assert.equal(w.since, 7);
  const b = shell({ id: 4, prog: { state: "working", kind: "", msg: "Building" } });
  assert.equal(tabView(store([b], { 4: ["working", "working", -1] }), b as any).msg, "");
});

test("status: a tab the core sent nothing for shows none", () => {
  const t = pi({ id: 9, agent: "working", status_since: 5 });
  assert.deepEqual(tabView(store([], {}), t as any), { dot: "none", mark: "idle", progress: -1, msg: "", since: 5 });
});

test("status: a session shows the tab the core names (from); none: idle", () => {
  const tabs = [pi({ id: 4, agent: "working" }), shell({ id: 5, status_since: 3 }), shell({ id: 6, status_since: 9 })];
  const marks: Record<number, [string, string, number]> = { 4: ["working", "working", -1], 5: ["error", "error", -1], 6: ["error", "error", -1] };
  const s = store(tabs, marks, 5);
  const v = sessionView(s, s.session(3)!);
  assert.deepEqual([v.dot, v.mark, v.since], ["error", "error", 3]);
  const q = store([shell({ id: 4 })], { 4: ["none", "idle", -1] }, 0);
  assert.deepEqual(sessionView(q, q.session(3)!), { dot: "none", mark: "idle", progress: -1, msg: "", since: 0 });
});

test("status: a tab strip shows a quiet terminal that printed just now as working (not a pi tab)", () => {
  const strip = (t: any, m: [string, string, number]) => stripView(store([t], { [t.id]: m }), t);
  assert.equal(strip(shell({ id: 4, output_recent: true }), ["none", "idle", -1]).mark, "working");
  assert.equal(strip(shell({ id: 4, output_recent: true, status: "exited" }), ["none", "idle", -1]).dot, "none");
  assert.equal(strip(pi({ id: 4, agent: "idle", output_recent: true }), ["none", "idle", -1]).dot, "none");
  assert.equal(strip(shell({ id: 4, output_recent: true, unseen: true }), ["unseen", "done", -1]).dot, "unseen");
});
