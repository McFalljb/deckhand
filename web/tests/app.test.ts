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

import { Store } from "../src/state.ts";
import { fold } from "../src/app/fold.ts";

test("web tree: keyed rows, a key alone is a top-level row, a delta changes one row", () => {
  const s = new Store();
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 9, group: "projects", machine: 0 }] },
    webtree: ["7", ["9", 1, 0, 1]],
    "webp:7": { id: 7, name: "alpha", path: "/a", pin: 0, hidden: false },
    "webp:9": { id: 9, name: "beta", path: "/a/b", pin: -1, hidden: false },
    "websl:7": ["s1"], "webs:7:s1": { label: "first", open: 0, pin: -1, hidden: false, dot: "none", claude: false, codex: false, modified: 0 },
  } });
  const t = s.webTree;
  assert.deepEqual(t.map((r) => [r.key, r.name, r.depth, r.forced]), [["7", "alpha", 0, false], ["9", "beta", 1, true]]);
  assert.equal(s.webSessions(7)?.[0].label, "first");
  assert.equal(s.webSessions(9), null); // not listed: the page shows "Loading…"
  assert.equal(s.webTree, t, "the same rows while nothing changed");
  s.applyDelta({ version: 2, sections: { "webp:9": { id: 9, name: "beta2", path: "/a/b", pin: -1, hidden: false } } });
  assert.equal(s.webTree[1].name, "beta2");
});

test("fold: a project opened before folds and unfolds with no command; a new one asks the core once", () => {
  const s = new Store();
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 9, group: "projects", machine: 0 }] },
    web: { watch: [7] },
  } });
  const sent: object[] = [];
  const link = { run: (c: object) => (sent.push(c), Promise.resolve({ ok: true })) } as any;
  fold.open.clear();
  fold.toggleOpen("7");
  fold.syncWatch(s, link);
  fold.toggleOpen("7");
  fold.syncWatch(s, link);
  assert.equal(sent.length, 0);
  fold.toggleOpen("9");
  fold.syncWatch(s, link);
  fold.syncWatch(s, link); // the same ask is not sent twice
  assert.deepEqual(sent, [{ type: "web_watch", projects: [9] }]);
});

import { reviewPrompt } from "../src/app/review.ts";

test("changes: the review prompt is the window's (src/ui_changes.odin changes_review_prompt)", () => {
  const l = { root: "/r", loading: false, branch: "feat", default_branch: "main", ahead: 2, files: [] };
  assert.equal(reviewPrompt(l), "Review the uncommitted changes in this checkout (/r): git status and git diff HEAD, and the 2 commits on feat that are not on main (git diff main...HEAD). Point out bugs, risks and unfinished work.");
  assert.equal(reviewPrompt({ ...l, ahead: 0 }), "Review the uncommitted changes in this checkout (/r): git status and git diff HEAD. Point out bugs, risks and unfinished work.");
});
