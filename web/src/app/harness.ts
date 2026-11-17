// The New session picker's choices for a project, and the New Claude tab / New Codex tab rows: what
// the native window offers there, as the core computed it (web_view_new_choices in
// src/core/web_view.odin: installed here, or on that machine by its checklist; Claude Code and
// Codex in Chats here, never another machine's; once per account while there are several), the
// last used first. The core records the harness a browser starts as the last used.
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
  const list = (p?.group === "chats" ? m?.chats : m?.projects) ?? [];
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
