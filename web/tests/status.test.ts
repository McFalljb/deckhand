// Status dots and marks (#195 item 4): what the browser shows for each kind of tab today, pinned
// before the page stops computing them itself. The same table, row for row, is in
// src/core/web_view_test.odin (web_view_status_table): the core's tab_status_view and status_mark.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Store } from "../src/state.ts";
import { sessionView, stripView, tabView } from "../src/status.ts";

const base = { id: 1, machine: 0, title: "", status: "running", agent: "unknown", waiting: false, question: false, unseen: false, prog: { state: "none", kind: "" } };
const pi = (x: object) => ({ ...base, kind: { pi_tab: {} }, ...x });
const shell = (x: object) => ({ ...base, kind: { shell_tab: {} }, ...x });
const claude = (ct: object, x: object = {}) => ({ ...base, kind: { claude_tab: { turn: "unknown", ended: "none", ...ct } }, ...x });

// [row, tab, dot, mark, progress]
export const STATUS_TABLE: [string, object, string, string, number][] = [
  ["shell, nothing reported", shell({}), "none", "idle", -1],
  ["pi idle", pi({ agent: "idle" }), "none", "idle", -1],
  ["pi working", pi({ agent: "working" }), "working", "working", -1],
  ["pi waiting", pi({ agent: "idle", waiting: true }), "waiting", "waiting", -1],
  ["pi asked a question", pi({ agent: "idle", question: true }), "question", "question", -1],
  ["pi error", pi({ agent: "error" }), "error", "error", -1],
  ["pi exited", pi({ status: "exited", agent: "idle" }), "exited", "exited", -1],
  ["pi finished, not seen", pi({ agent: "idle", unseen: true }), "unseen", "done", -1],
  ["pi not reporting yet", pi({}), "none", "idle", -1],
  ["shell blocked: permission", shell({ prog: { state: "blocked", kind: "permission" } }), "waiting", "permission", -1],
  ["shell blocked: question", shell({ prog: { state: "blocked", kind: "question" } }), "waiting", "question", -1],
  ["shell blocked: auth", shell({ prog: { state: "blocked", kind: "auth" } }), "waiting", "auth", -1],
  ["shell blocked", shell({ prog: { state: "blocked", kind: "" } }), "waiting", "waiting", -1],
  ["shell working at 40%", shell({ prog: { state: "working", kind: "", progress: 40 } }), "working", "progress", 0.4],
  ["shell working", shell({ prog: { state: "working", kind: "", progress: -1 } }), "working", "working", -1],
  ["shell error", shell({ prog: { state: "error", kind: "" } }), "error", "error", -1],
  ["shell done", shell({ prog: { state: "done", kind: "" } }), "none", "idle", -1],
  ["pi exited, OSC 7501 done", pi({ status: "exited", prog: { state: "done", kind: "" } }), "exited", "exited", -1],
  ["claude turn working", claude({ turn: "working" }), "working", "working", -1],
  ["claude turn waiting", claude({ turn: "waiting" }), "waiting", "waiting", -1],
  ["claude ended on a question", claude({ turn: "idle", ended: "question" }), "question", "question", -1],
  ["claude ended on an error", claude({ turn: "idle", ended: "error" }), "error", "error", -1],
  ["claude exited mid-turn", claude({ turn: "working" }, { status: "exited" }), "none", "idle", -1],
  ["claude: OSC 7501 over the hooks", claude({ turn: "waiting" }, { prog: { state: "working", kind: "", progress: -1 } }), "working", "working", -1],
  ["shell unseen under working", shell({ unseen: true, prog: { state: "working", kind: "", progress: -1 } }), "working", "working", -1],
  ["shell unseen", shell({ unseen: true }), "unseen", "done", -1],
];

test("status table: each kind of tab's dot, mark and progress", () => {
  for (const [row, tab, dot, mark, progress] of STATUS_TABLE) {
    const v = tabView(tab as any);
    assert.deepEqual([v.dot, v.mark, v.progress], [dot, mark, progress], row);
  }
});

test("status: what it waits for is OSC 7501's message, only while waiting; since is the tab's", () => {
  const w = tabView(shell({ status_since: 7, prog: { state: "blocked", kind: "question", msg: "Deploy?" } }) as any);
  assert.equal(w.msg, "Deploy?");
  assert.equal(w.since, 7);
  assert.equal(tabView(shell({ prog: { state: "working", kind: "", msg: "Building" } }) as any).msg, "");
});

test("status: a session shows its strongest tab (the first of equals); none: idle", () => {
  const s = new Store();
  const open = (tabs: object[]) =>
    s.applyFull({ version: 1, state: { sessions: { open_sessions: [{ id: 3, machine: 0, project_id: 1, active_tab: 4, title: "" }], current_session: 3 }, "tabs:3": tabs } });
  open([pi({ id: 4, agent: "working" }), shell({ id: 5, prog: { state: "error", kind: "" } }), shell({ id: 6, prog: { state: "error", kind: "" }, status_since: 9 })]);
  const v = sessionView(s, s.session(3)!);
  assert.deepEqual([v.dot, v.mark], ["error", "error"]);
  assert.equal(v.since, 0, "tab 5, the first of the two errors");
  open([shell({ id: 4 }), pi({ id: 5, agent: "idle" })]);
  assert.deepEqual(sessionView(s, s.session(3)!), { dot: "none", mark: "idle", progress: -1, msg: "", since: 0 });
});

test("status: a tab strip shows a quiet terminal that printed just now as working (not a pi tab)", () => {
  assert.equal(stripView(shell({ output_recent: true }) as any).mark, "working");
  assert.equal(stripView(shell({ output_recent: true, status: "exited" }) as any).dot, "none");
  assert.equal(stripView(pi({ agent: "idle", output_recent: true }) as any).dot, "none");
  assert.equal(stripView(shell({ output_recent: true, unseen: true }) as any).dot, "unseen");
});

// Where the page differs from the Mac's window today: a pi tab whose bridge reports and whose
// program also sent OSC 7501. The page took OSC 7501's kind and progress for the mark; the core
// (tab_status_view: the bridge speaks for a pi tab) shows the bridge's dot alone.
export const STATUS_DIFFERS: [string, object, [string, string, number], [string, string, number]][] = [
  ["pi waiting, OSC 7501 permission", pi({ agent: "idle", waiting: true, prog: { state: "blocked", kind: "permission" } }), ["waiting", "permission", -1], ["waiting", "waiting", -1]],
  ["pi working, OSC 7501 at 40%", pi({ agent: "working", prog: { state: "working", kind: "", progress: 40 } }), ["working", "progress", 0.4], ["working", "working", -1]],
];

test("status: a pi tab with both the bridge and OSC 7501 (the page's own reading)", () => {
  for (const [row, tab, page] of STATUS_DIFFERS) {
    const v = tabView(tab as any);
    assert.deepEqual([v.dot, v.mark, v.progress], page, row);
  }
});
