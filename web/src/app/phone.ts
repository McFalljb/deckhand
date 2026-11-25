// The phone's choices that need no DOM (Phone.tsx, Palette.tsx, Files.tsx use them; tests too).

import { tabKind, isTerminalTab, type Panel, type Tab, type WebView } from "../state.ts";
import type { MenuItem, Overlay } from "./ctx.ts";

// ---- typing ----
// A phone types straight into the terminal (its hidden field: termfield.ts). The text box is a
// one-time compose from the session menu, never a saved mode. Before, the keyboard button switched
// to the box and saved that in this browser for good ("deckhand.phoneTyping" = "field"), so the
// terminal never took the keyboard again: that saved choice is dropped once, and never written.
export const OLD_TYPING_KEY = "deckhand.phoneTyping";

// True when this browser was left in the old text-box mode and is now switched back (the caller
// says so once). At most once per page load; a storage that throws, or keeps the key after the
// remove (removeItem failing quietly), counts as done: no toast on every load.
const pageOnce = { done: false };
export function forgetTypingMode(store: { get(k: string): string | null; remove(k: string): void }, once = pageOnce): boolean {
  if (once.done) return false;
  once.done = true;
  try {
    const was = store.get(OLD_TYPING_KEY);
    if (was === null) return false;
    store.remove(OLD_TYPING_KEY);
    return was === "field" && store.get(OLD_TYPING_KEY) === null;
  } catch {
    return false;
  }
}

// The compose box's Send: its text goes once as a paste (bracketed when the program asked), then
// Enter apart; an empty box sends Enter alone. The box closes after either. While the terminal is
// not attached (a reconnect, a tab starting) nothing goes: the box stays open with its text.
export type ComposePlan = { paste: string | null; enter: true; close: true } | { keep: true; error: string };
export function composeSend(text: string, attached: boolean): ComposePlan {
  if (!attached) return { keep: true, error: "Not sent: this tab's terminal is not connected. Your text is still in the box." };
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
  select(): void; // the terminal's text in a sheet to select from (Phone.tsx SelectSheet)
  closeTab(): void;
  closeSession(): void;
}): MenuItem[] {
  const items: MenuItem[] = [
    { label: "Text smaller", run: o.smaller },
    { label: "Text larger", run: o.larger },
    { label: "Copy screen text", run: o.copy },
  ];
  if (o.terminal) items.push({ label: "Select text", run: o.select }, { label: "Type in a text box", run: o.compose });
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
// Entries that change the desktop window's layout or view: on a phone (one tab at a time, no
// columns) they would only rearrange the Mac's window or a desktop browser's, unseen from here.
// Show the Deck, Show jobs, Filter and New shell tab stay, phone-local there (Palette.tsx).
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
  // a Changes tab placed in the Mac's panes; the left column's sorts and Show hidden (the Mac's
  // sidebar; the filter and its chips are each browser's own)
  "show_changes",
  "show_hidden",
  "sort_projects",
  "sort_sessions",
  "sort_chats",
]);
export const paletteShows = (id: string, phone: boolean): boolean => !(phone && DESKTOP_ONLY.has(id));

// ---- Insert path ----
// A file's path typed into the session's terminal on screen (the focused pane's), by the Mac's drop
// rule (src/core/files_drops.odin pane_drop_text): a shell's path shell-quoted; an agent's prompt's
// plain, quoted only when it must be (a space or a quote, or a word starting / ! $ @, which an
// empty prompt may read as a command or a picker); a space after it, never Enter. Marked
// generated, as the Mac's drop: the core then applies a Codex composer's rule (no picker, not
// while it waits). A name with a control character (C0, DEL, C1) is refused: never typed.
// null: that tab is not a running terminal.
export type InsertPath = { cmd: { type: "send_text"; tab_id: number; text: string; generated: true } } | { error: string };
const CONTROL = /[\x00-\x1f\x7f-\x9f]/;
const MUST_QUOTE = /[ \t'"\\`$]/;
export function insertPath(tabs: Tab[], active: number, path: string): InsertPath | null {
  const t = tabs.find((x) => x.id === active);
  if (!t || !isTerminalTab(t) || t.status !== "running") return null;
  if (CONTROL.test(path)) return { error: "a name has a control character" };
  const shell = tabKind(t) !== "pi_tab" && tabKind(t) !== "claude_tab";
  const quote = shell || MUST_QUOTE.test(path) || "/!$@".includes(path[0] ?? "");
  const text = (quote ? "'" + path.replaceAll("'", "'\\''") + "'" : path) + " ";
  return { cmd: { type: "send_text", tab_id: t.id, text, generated: true } };
}

// ---- what covers a terminal ----
// A menu, sheet, the palette, another overlay or the agent drawer is over the page: nothing types
// into or scrolls a terminal's program under it. The drawer's own terminal (inDrawer) is not under
// it: it types and scrolls (a menu over it still covers it).
export function covering(o: Overlay, homeOpen: boolean, inDrawer = false): boolean {
  return !!(o.menu || o.sheet || o.palette || o.bell || o.link || o.copy || o.job || o.peek || o.panels || o.select !== null && o.select !== undefined || (homeOpen && !inDrawer));
}

// Whether the Atlas drawer shows. The core's home_open is one flag for the Mac's window (an agent
// may set it too): a phone follows it no more, or a drawer opened at the Mac would cover the phone
// whole. A phone shows its own (Overlay.atlas), opened and closed from the phone.
export function drawerShown(phone: boolean, o: Overlay, homeOpen: boolean): boolean {
  return phone ? !!o.atlas : homeOpen;
}

// Atlas shown or hidden from a button or the palette. A phone opens and closes its own (never the
// core's home_open: the Mac's drawer). The desktop follows the core (set_home).
export function atlasToggle(phone: boolean, localOpen: boolean, homeOpen: boolean): { atlas: boolean; cmd: { type: "set_home"; open: boolean } | null } {
  if (phone) return { atlas: !localOpen, cmd: null };
  return { atlas: false, cmd: { type: "set_home", open: !homeOpen } };
}

// Atlas's pi is not running yet (never started, or restored and not started): a phone shows Start
// Atlas, which sends ATLAS_START.
export const atlasNeedsStart = (status: string | undefined): boolean => !status || status === "not_started";

// Atlas's button (the phone's home bar, the desktop's top bar, the palette): once Atlas has a
// session, or before its first start when the core offers it ("web".atlas: pi installed). With no
// session yet the phone's Atlas screen shows Start Atlas, and the desktop's set_home makes it.
export const atlasShown = (homeSession: number, web: WebView | null): boolean => !!homeSession || !!web?.atlas;

// Start Atlas on a phone: the core's start_home starts Atlas's pi and leaves the Mac's drawer and
// keyboard as they are (set_home would open the drawer at the Mac and take its keyboard).
export const ATLAS_START = { type: "start_home" } as const;

// ---- the right column's panels ----
// What the session's agents publish (a pi bridge's panels; a Claude tab's Todos, Subagents and
// Background: claude_panels.odin), as the desktop's right column lists them (Bars.tsx RightPanels):
// each tab's in tab order, one per id (the first). A phone shows them in a sheet (Phone.tsx).
export function sessionPanels(tabs: Tab[], panelsOf: (tabId: number) => Panel[]): Panel[] {
  const out: Panel[] = [];
  const seen = new Set<string>();
  for (const t of tabs)
    for (const p of panelsOf(t.id))
      if (!seen.has(p.id)) {
        seen.add(p.id);
        out.push(p);
      }
  return out;
}

// A panel as drawn: a bridge's first head row is its title ("Todos 3/4"), as the window draws it.
export function panelView(p: Panel): { head: string; rows: Panel["rows"] } {
  return p.rows[0]?.head ? { head: p.rows[0].text, rows: p.rows.slice(1) } : { head: p.title, rows: p.rows };
}
