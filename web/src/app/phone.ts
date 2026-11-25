// The phone's choices that need no DOM (Phone.tsx, Palette.tsx, Files.tsx use them; tests too).

import { tabKind, isTerminalTab, type Tab } from "../state.ts";
import { shellQuote } from "./filetree.ts";
import type { MenuItem, Overlay } from "./ctx.ts";

// ---- typing ----
// A phone types straight into the terminal (its hidden field: termfield.ts). The text box is a
// one-time compose from the session menu, never a saved mode. Before, the keyboard button switched
// to the box and saved that in this browser for good ("deckhand.phoneTyping" = "field"), so the
// terminal never took the keyboard again: that saved choice is dropped once, and never written.
export const OLD_TYPING_KEY = "deckhand.phoneTyping";

// True when this browser was left in the old text-box mode (it now types straight in again).
export function forgetTypingMode(store: { get(k: string): string | null; remove(k: string): void }): boolean {
  const was = store.get(OLD_TYPING_KEY);
  if (was !== null) store.remove(OLD_TYPING_KEY);
  return was === "field";
}

// The compose box's Send: its text goes once as a paste (bracketed when the program asked), then
// Enter apart; an empty box sends Enter alone. The box closes after either.
export function composeSend(text: string): { paste: string | null; enter: true; close: true } {
  return { paste: text ? text : null, enter: true, close: true };
}

// The session's ⋯ menu on a phone.
export function phoneSessionItems(o: {
  tab: Tab | undefined;
  terminal: boolean; // the tab on screen is a terminal (the text box types into it)
  smaller(): void;
  larger(): void;
  copy(): void;
  compose(): void;
  closeTab(): void;
  closeSession(): void;
}): MenuItem[] {
  const items: MenuItem[] = [
    { label: "Text smaller", run: o.smaller },
    { label: "Text larger", run: o.larger },
    { label: "Copy screen text", run: o.copy },
  ];
  if (o.terminal) items.push({ label: "Type in a text box", run: o.compose });
  items.push({ sep: true });
  if (o.tab && tabKind(o.tab) !== "pi_tab") items.push({ label: "Close this tab", run: o.closeTab });
  items.push({ label: "Close session", run: o.closeSession });
  return items;
}

// ---- an exited tab ----
// The bar over a terminal whose process exited, as the desktop's (Panes.tsx): Restart for an agent
// (pi, Claude, Codex: a Claude tab record), Close for any tab but pi's (it closes with its session).
export function exitBar(tab: Tab): { text: string; restart: string; close: boolean } | null {
  if (tab.status !== "exited") return null;
  const code = tab.exit?.known ? (tab.exit.signal ? `signal ${tab.exit.signal}` : `code ${tab.exit.code}`) : "";
  const k = tabKind(tab);
  return {
    text: `Exited${code ? ` (${code})` : ""}`,
    restart: k === "pi_tab" ? "pi_restart" : k === "claude_tab" ? "claude_restart" : "",
    close: k !== "pi_tab",
  };
}

// ---- the palette ----
// Entries that change the desktop window's layout: on a phone (one tab at a time, no columns) they
// would only rearrange the Mac's window or a desktop browser's, unseen from here.
const DESKTOP_ONLY = new Set([
  "toggle_left",
  "toggle_right",
  "split_right",
  "split_down",
  "close_pane",
  "equalize_panes",
  "zoom_pane",
  "focus_pane_left",
  "focus_pane_right",
  "focus_pane_up",
  "focus_pane_down",
  "dim_panes",
]);
export const paletteShows = (id: string, phone: boolean): boolean => !(phone && DESKTOP_ONLY.has(id));

// ---- Insert path ----
// A file's path typed into the session's terminal: the tab on screen (the focused pane's), quoted
// as the window's tree pastes it on a drop (filetree.ts shellQuote), no newline: it never runs.
// null: that tab is not a running terminal.
export function insertPath(tabs: Tab[], active: number, path: string): { type: "send_text"; tab_id: number; text: string } | null {
  const t = tabs.find((x) => x.id === active);
  if (!t || !isTerminalTab(t) || t.status !== "running") return null;
  return { type: "send_text", tab_id: t.id, text: shellQuote(path) + " " };
}

// ---- what covers a terminal ----
// A menu, sheet, the palette, another overlay or the agent drawer is over the page: nothing types
// into or scrolls a terminal's program under it. The drawer's own terminal (inDrawer) is not under
// it: it types and scrolls (a menu over it still covers it).
export function covering(o: Overlay, homeOpen: boolean, inDrawer = false): boolean {
  return !!(o.menu || o.sheet || o.palette || o.bell || o.link || o.copy || o.job || o.peek || (homeOpen && !inDrawer));
}

// Whether the Atlas drawer shows. The core's home_open is one flag for the Mac's window (an agent
// may set it too): a phone follows it no more, or a drawer opened at the Mac would cover the phone
// whole. A phone shows its own (Overlay.atlas), opened and closed from the phone.
export function drawerShown(phone: boolean, o: Overlay, homeOpen: boolean): boolean {
  return phone ? !!o.atlas : homeOpen;
}
