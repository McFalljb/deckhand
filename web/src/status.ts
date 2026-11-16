// Status dots, as the core computes them (src/core/agent_status.odin tab_status_view,
// session_row_status, attention_tier). A port, kept small: if the core later sends its own
// attention rows to web links, use those instead.

import { tabKind, type OpenSession, type Store, type Tab } from "./state.ts";

export type Dot = "none" | "working" | "waiting" | "question" | "error" | "exited" | "unseen";

function piStatus(t: Tab): Dot {
  if (t.status === "exited") return "exited";
  if (t.waiting) return "waiting";
  switch (t.agent) {
    case "error":
      return "error";
    case "working":
      return "working";
    case "idle":
      return t.question ? "question" : "none";
  }
  return "none";
}

export function tabDot(t: Tab): Dot {
  const kind = tabKind(t);
  const isPi = kind === "pi_tab";
  const prog = t.prog?.state ?? "none";
  let dot: Dot = "none";
  if (isPi && (t.agent !== "unknown" || t.waiting)) {
    dot = piStatus(t);
  } else if (prog !== "none") {
    if (prog === "blocked") dot = "waiting";
    else if (prog === "error") dot = "error";
    else if (prog === "working") dot = "working";
    if (dot === "none" && isPi && t.status === "exited") dot = "exited";
  } else if (isPi) {
    dot = piStatus(t);
  }
  if (kind === "claude_tab" && t.status === "running") {
    const ct = t.kind?.claude_tab ?? {};
    if (prog === "none" && dot === "none") {
      if (ct.turn === "working") dot = "working";
      else if (ct.turn === "waiting") dot = "waiting";
    }
    if (dot === "none") {
      if (ct.ended === "question") dot = "question";
      else if (ct.ended === "error") dot = "error";
    }
  }
  if (t.unseen && dot === "none") dot = "unseen";
  return dot;
}

const RANK: Record<Dot, number> = { none: 0, exited: 1, working: 2, question: 3, unseen: 4, error: 5, waiting: 6 };

export function sessionDot(store: Store, s: OpenSession): Dot {
  let best: Dot = "none";
  for (const t of store.tabs(s.id)) {
    const d = tabDot(t);
    if (RANK[d] > RANK[best]) best = d;
  }
  return best;
}

// 3: needs you, 2: finished (or asked), 1: working, 0: the rest.
export function attentionTier(d: Dot): number {
  switch (d) {
    case "waiting":
    case "error":
      return 3;
    case "unseen":
    case "question":
      return 2;
    case "working":
      return 1;
  }
  return 0;
}

export const DOT_LABEL: Record<Dot, string> = {
  none: "idle",
  working: "working",
  waiting: "needs you",
  question: "asked a question",
  error: "error",
  exited: "exited",
  unseen: "finished",
};
