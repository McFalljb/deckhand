// The New session picker's choices for a project, and the New Claude tab / New Codex tab rows: what
// the native window offers there, as the core computed it (web_view_new_choices in
// src/core/web_view.odin: installed here, or on that machine by its checklist; Claude Code and
// Codex in Chats here, never another machine's; once per account while there are several), the
// last used first, and the project's own account first as the native picker has it. The core records the harness a browser starts as the last used.
import type { Store, WebNewChoices } from "../state.ts";

export interface NewSessionChoice {
  label: string;
  note?: boolean; // a line of text (why there is nothing to pick), not a choice
  cmd?: object;
}

function there(store: Store, machine: number): WebNewChoices | undefined {
  return store.web?.new?.find((m) => m.machine === machine);
}

export function newSessionChoices(store: Store, projectId: number): NewSessionChoice[] {
  const p = store.project(projectId);
  const machine = p?.machine ?? 0;
  const m = there(store, machine);
  // its own rows where they differ (with several accounts, its last used one first), else its kind's
  const own = m?.project_rows?.find((x) => x.project === projectId)?.rows;
  const list = own ?? (p?.group === "chats" ? m?.chats : m?.projects) ?? [];
  const out: NewSessionChoice[] = list.map((c) => {
    const account = c.account ? { account: c.account } : {};
    return {
      label: c.label,
      cmd: c.harness === "pi" ? { type: "new_chat", project_id: projectId } : c.harness === "codex" ? { type: "new_claude_session", project_id: projectId, harness: "codex", ...account } : { type: "new_claude_session", project_id: projectId, ...account },
    };
  });
  if (out.length) return out;
  // none: another machine's opens a session anyway (its pi tab says how to install one), as the
  // native picker does; this one's only says how to install one
  if (m?.note) out.push({ label: m.note, note: true });
  if (machine) out.push({ label: "New session", cmd: { type: "new_chat", project_id: projectId } });
  return out;
}

// What New session does in a project: start the one choice at once (or, with none, say why and
// on another machine open a session anyway), else ask with the picker. As new_session_ui.
export type NewSessionPlan = { run: object; toast?: string; err?: boolean } | { toast: string; err: boolean } | { pick: NewSessionChoice[] };

export function newSessionPlan(store: Store, projectId: number): NewSessionPlan {
  const all = newSessionChoices(store, projectId);
  const runs = all.filter((c) => c.cmd);
  const note = all.find((c) => c.note)?.label ?? "";
  if (runs.length === 1 && !note) return { run: runs[0].cmd! };
  if (runs.length === 1) return { run: runs[0].cmd!, toast: note, err: false }; // another machine with none
  if (runs.length === 0) return { toast: note || "No coding agent is installed", err: true };
  return { pick: all };
}

export interface NewTabChoice {
  label: string;
  cmd: object;
}

// New Claude tab (codex: New Codex tab) rows for a session or a project on machine, once per
// account while there are several; [] while that harness is not there.
export function newTabChoices(store: Store, machine: number, target: { session: number } | { project_id: number }, codex: boolean, label: string): NewTabChoice[] {
  const m = there(store, machine);
  const list = (codex ? m?.codex_tab : m?.claude_tab) ?? [];
  return list.map((t) => ({
    label: t.name ? `${label} · ${t.name}` : label,
    cmd: { type: "new_claude_tab", ...target, ...(codex ? { harness: "codex" } : {}), ...(t.account ? { account: t.account } : {}) },
  }));
}

// A Claude or Codex tab's permission mode as its tab shows it (src/core/claude_mode.odin's
// claude_mode_label): nothing for the default; warn: anything not known to ask before it acts
// (auto, bypass, Codex's full access, never asks, approves for you, a word this page does not know).
const MODE_LABELS: Record<string, [string, boolean]> = {
  plan: ["plan", false],
  acceptEdits: ["accept edits", false],
  dontAsk: ["don't ask", false],
  auto: ["auto", true],
  bypassPermissions: ["bypass", true],
  "codex-bypass": ["bypass", true],
  "codex-full-access": ["full access", true],
  "codex-never-asks": ["never asks", true],
  "codex-approves": ["approves for you", true],
};
export function modeBadge(kind: Record<string, unknown> | null | undefined): { label: string; warn: boolean } | null {
  const ct = kind?.claude_tab as { permission_mode?: unknown } | undefined;
  const m = typeof ct?.permission_mode === "string" ? ct.permission_mode : "";
  if (!m || m === "default") return null;
  const known = Object.prototype.hasOwnProperty.call(MODE_LABELS, m) ? MODE_LABELS[m] : undefined;
  if (known) return { label: known[0], warn: known[1] };
  // a newer Claude Code's mode: its own word (the core lets only letters through), in the warning colour
  return /^[A-Za-z]{1,32}$/.test(m) ? { label: m, warn: true } : null;
}
