// A tab's status strip: the bars the native window draws over a Claude, Codex or pi tab (held
// messages, hooks silent, an old version, Codex signed out, the hot-reload bars), as the core wrote
// them (the "webbars" section: src/core/tab_bars.odin, web_bars_json). Text only, with the
// actions a browser may take: a command, copying text, or its Settings screen.
import { tabKind, type Store, type Tab } from "../state.ts";

export interface WebBarAction {
  label: string;
  command?: object; // sent as the user's (the core's gate decides)
  copy?: string; // text to copy (the copy sheet)
  settings?: string; // a Settings section to open
}
export interface WebBar {
  tab: number; // 0 = every tab of its harness (the hot-reload bars)
  harness: string; // pi | claude | codex
  kind: string;
  tone: string; // waiting | error | info
  text: string;
  actions: WebBarAction[];
}

export function tabHarnessKey(t: Tab): string {
  const k = tabKind(t);
  if (k === "pi_tab") return "pi";
  if (k === "claude_tab") return (t.kind as any).claude_tab?.codex ? "codex" : "claude";
  return "";
}

// The bars over tab t, its own first, then the ones for every tab of its harness.
export function barsFor(store: Store, t: Tab): WebBar[] {
  const all: WebBar[] = store.sections.get("webbars") ?? [];
  // another machine's tab: its own core's bars, never this one's (a Reload here would reload this
  // machine's tabs)
  if (t.machine) return [];
  const h = tabHarnessKey(t);
  if (!h || !Array.isArray(all)) return [];
  return [...all.filter((b) => b.tab === t.id), ...all.filter((b) => b.tab === 0 && b.harness === h)];
}
