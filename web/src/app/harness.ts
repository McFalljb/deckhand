// The New session picker's choices for a project: what the native picker offers there, as the core
// computed it (web_view_new_choices in src/core/web_view.odin: installed here, or on that machine by
// its checklist; Claude Code and Codex in Chats here, never another machine's), the last used first.
import type { Store } from "../state.ts";

export interface NewSessionChoice {
  label: string;
  note?: boolean; // a line of text (why there is nothing to pick), not a choice
  cmd?: object;
}

export function newSessionChoices(store: Store, projectId: number): NewSessionChoice[] {
  const p = store.project(projectId);
  const machine = p?.machine ?? 0;
  const there = store.web?.new?.find((m) => m.machine === machine);
  const list = (p?.group === "chats" ? there?.chats : there?.projects) ?? [];
  const out: NewSessionChoice[] = list.map((c) => ({
    label: c.label,
    cmd: c.harness === "pi" ? { type: "new_chat", project_id: projectId } : c.harness === "codex" ? { type: "new_claude_session", project_id: projectId, harness: "codex" } : { type: "new_claude_session", project_id: projectId },
  }));
  if (out.length) return out;
  // none: another machine's opens a session anyway (its pi tab says how to install one), as the
  // native picker does; this one's only says how to install one
  if (there?.note) out.push({ label: there.note, note: true });
  if (machine) out.push({ label: "New session", cmd: { type: "new_chat", project_id: projectId } });
  return out;
}
