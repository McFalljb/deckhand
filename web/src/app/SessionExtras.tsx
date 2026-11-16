// A session row's ⓘ, Rename… and Peek (src/ui_sidebar.odin session_info_menu, the row menu).
//
// ⓘ: a menu of the session's info as the window's (session_info: its header and file only, never
// its messages), then Copy session info and Send to Atlas. Rename…: a Claude session's Deckhand
// title (claude_rename; a pi session's title is its first message: no command renames it).

import { menuAt, type App, type MenuItem } from "./ctx.ts";
import { canPeek, openPeek } from "./Peek.tsx";
import { agentName } from "./Bars.tsx";

export async function infoMenu(app: App, e: MouseEvent, projectId: number, sid: string) {
  // under the ⓘ, as the window's (else where the click was)
  const r0 = (e.currentTarget as HTMLElement | null)?.getBoundingClientRect();
  const at = r0 ? { clientX: r0.left, clientY: r0.bottom } : { clientX: e.clientX, clientY: e.clientY };
  const r = await app.link.run({ type: "session_info", project_id: projectId, pi_session_id: sid });
  const text: string = r.ok ? String(r.data?.text ?? "") : `(${r.error || "no info"})`;
  const items: MenuItem[] = text
    .split("\n")
    .filter((l) => l && !l.startsWith("```"))
    .map((l) => ({ label: l, note: true }));
  items.push({ sep: true });
  items.push(...infoItems(app, projectId, sid));
  menuAt(app, at, items);
}

export function infoItems(app: App, projectId: number, sid: string): MenuItem[] {
  return [
    { label: "Copy session info", run: () => app.run({ type: "session_info", project_id: projectId, pi_session_id: sid, to: "clipboard" }) },
    { label: `Send to ${agentName(app)}`, run: () => app.run({ type: "session_info", project_id: projectId, pi_session_id: sid, to: "agent" }) },
  ];
}

export function renameItem(app: App, sid: string, title: string): MenuItem {
  return { label: "Rename…", run: () => app.setOverlay({ sheet: { title: "Rename session", body: title, items: [{ label: "prompt:claude_rename:" + sid }] } }) };
}

export function peekItem(app: App, session: number, tab?: number): MenuItem[] {
  if (!canPeek(app, session, tab)) return [];
  return [{ label: "Peek", run: () => openPeek(app, session, tab, { x: window.innerWidth / 2 - 320, y: 80 }) }];
}
