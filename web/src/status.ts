// Status dots and marks, as the core computes them (src/core/agent_status.odin tab_status_view,
// status_mark, session_row_status) and sends a browser (webst:<session>, src/core/web_view.odin):
// the page reads them, never works them out. Its own: a tab strip's recent output (stripView).

import { tabKind, type OpenSession, type Store, type Tab } from "./state.ts";

export type Dot = "none" | "working" | "waiting" | "question" | "error" | "exited" | "unseen";

// The mark a status draws (status_mark): its dot, and while waiting what it waits for (OSC 7501's
// kind).
export type Mark = "idle" | "exited" | "working" | "progress" | "waiting" | "permission" | "question" | "auth" | "done" | "error";

export interface TabView {
  dot: Dot;
  mark: Mark;
  progress: number; // 0..1 while working with a reported progress, else -1
  msg: string; // what it asks (OSC 7501's message), untrusted text
  since: number; // ns when this status began (0: not known)
}

const NONE: TabView = { dot: "none", mark: "idle", progress: -1, msg: "", since: 0 };

export function tabView(store: Store, t: Tab): TabView {
  const m = store.tabMark(t.id);
  if (!m) return { ...NONE, since: t.status_since ?? 0 };
  const dot = m[0] as Dot;
  return { dot, mark: m[1] as Mark, progress: m[2] < 0 ? -1 : m[2] / 100, msg: dot === "waiting" ? (t.prog?.msg ?? "") : "", since: t.status_since ?? 0 };
}

// A tab strip's status: a quiet tab that printed in the last moment shows working (src/ui.odin
// tab_strip_view).
export function stripView(store: Store, t: Tab): TabView {
  const v = tabView(store, t);
  if (v.dot === "none" && tabKind(t) !== "pi_tab" && t.status === "running" && t.output_recent) return { ...v, dot: "working", mark: "working" };
  return v;
}

// The tab that gives an open session its dot: the strongest (session_row_status).
export function sessionView(store: Store, s: OpenSession): TabView {
  const from = store.markFrom(s.id);
  const t = from ? store.tabs(s.id).find((x) => x.id === from) : undefined;
  return t ? tabView(store, t) : NONE;
}
