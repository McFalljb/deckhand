// The replica: state.full then state.delta (src/core/state_wire.odin), and the status dots read
// from it.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Store } from "../src/state.ts";
import { attentionTier, sessionDot, tabDot } from "../src/status.ts";

const tab = (id: number, extra: object = {}) => ({
  id,
  machine: 0,
  kind: { shell_tab: {} },
  title: "zsh",
  status: "running",
  agent: "unknown",
  waiting: false,
  question: false,
  unseen: false,
  prog: { state: "none", kind: "none" },
  ...extra,
});

function full() {
  return {
    v: 1,
    type: "state.full",
    version: 10,
    state: {
      projects: { projects: [{ id: 1, machine: 0, group: "none", name: "App", cwd: "/w/app", label: "~/w/app" }], selected_project: 1 },
      sessions: { open_sessions: [{ id: 3, machine: 0, project_id: 1, active_tab: 4, title: "fix link" }], current_session: 3 },
      confirmations: { pending_confirmations: [] },
      "tabs:3": [tab(4, { kind: { pi_tab: { readonly: false } }, agent: "idle" }), tab(5)],
      "panes:3": { panes: [], focused_pane: 1 },
      "panels:4": [],
    },
  };
}

test("state.full replaces everything; state.delta changes and removes sections", () => {
  const s = new Store();
  assert.equal(s.applyDelta({ version: 1, sections: {} }), false, "no delta before a full");
  let calls = 0;
  s.subscribe(() => calls++);
  assert.ok(s.applyFull(full()));
  assert.equal(s.version, 10);
  assert.equal(s.tabs(3).length, 2);
  assert.equal(s.session(3)?.title, "fix link");

  // a tab closed: its section goes, its session's tabs change
  assert.ok(s.applyDelta({ version: 11, sections: { "tabs:3": [tab(4, { kind: { pi_tab: {} }, agent: "working" })], "panels:5": null } }));
  assert.equal(s.version, 11);
  assert.equal(s.tabs(3).length, 1);
  assert.equal(s.sections.has("panels:5"), false);
  assert.equal(s.project(1)?.name, "App", "untouched sections stay");

  // the session closed
  assert.ok(s.applyDelta({ version: 12, sections: { sessions: { open_sessions: [], current_session: 0 }, "tabs:3": null, "panes:3": null, "panels:4": null } }));
  assert.equal(s.openSessions.length, 0);
  assert.deepEqual(s.tabs(3), []);
  assert.equal(calls, 3);

  // a fresh full (a reconnect) drops what the old one had
  const f = full();
  delete (f.state as any)["tabs:3"];
  assert.ok(s.applyFull(f));
  assert.deepEqual(s.tabs(3), []);
  assert.equal(s.applyDelta({ version: 13 }), false, "malformed");
});

test("status dots follow the core's rules", () => {
  assert.equal(tabDot(tab(1, { kind: { pi_tab: {} }, agent: "working" }) as any), "working");
  assert.equal(tabDot(tab(1, { kind: { pi_tab: {} }, agent: "idle", waiting: true }) as any), "waiting");
  assert.equal(tabDot(tab(1, { kind: { pi_tab: {} }, agent: "idle", question: true }) as any), "question");
  assert.equal(tabDot(tab(1, { kind: { pi_tab: {} }, agent: "idle", unseen: true }) as any), "unseen");
  assert.equal(tabDot(tab(1, { prog: { state: "blocked", kind: "permission" } }) as any), "waiting");
  assert.equal(tabDot(tab(1, { kind: { claude_tab: { turn: "working", ended: "none" } } }) as any), "working");
  assert.equal(tabDot(tab(1, { kind: { claude_tab: { turn: "idle", ended: "question" } } }) as any), "question");
  assert.equal(tabDot(tab(1) as any), "none");

  const s = new Store();
  const f = full();
  (f.state as any)["tabs:3"] = [tab(4, { kind: { pi_tab: {} }, agent: "working" }), tab(5, { prog: { state: "error", kind: "none" } })];
  s.applyFull(f);
  const dot = sessionDot(s, s.session(3)!);
  assert.equal(dot, "error", "the strongest tab wins");
  assert.equal(attentionTier(dot), 3);
});
