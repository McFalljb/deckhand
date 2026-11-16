// What every component reaches: the link, the replica, running a command, and the app-wide
// overlays (menus, sheets, the palette, the bell, toasts). One context, no store library.

import { createContext } from "preact";
import { useContext } from "preact/hooks";
import type { Link, Result } from "../link.ts";
import type { Store } from "../state.ts";

export interface MenuItem {
  label?: string;
  sep?: boolean;
  check?: boolean;
  danger?: boolean;
  note?: boolean; // a line of text, not an action
  keys?: string;
  run?: () => void;
}

export interface Overlay {
  menu: { items: MenuItem[]; x: number; y: number } | null;
  palette: boolean;
  bell: boolean;
  sheet: { title: string; body?: string; items: MenuItem[] } | null;
  link: string | null; // a URL waiting for a tap
  copy: string | null; // text to copy by hand (no async clipboard here)
}

export interface App {
  link: Link;
  store: Store;
  phone: boolean;
  run(command: object): Promise<Result>;
  toast(text: string, err?: boolean): void;
  overlay: Overlay;
  setOverlay(o: Partial<Overlay>): void;
  // the session and tab the phone shows (the desktop follows the core's current session)
  route: { screen: "home" | "session" | "deck" | "jobs"; session: number; project: number };
  go(r: Partial<App["route"]>): void;
  // the terminal pane that has the keyboard (desktop), for window.request term_fit and keys
  fit(): { cols: number; rows: number; cellW: number; cellH: number } | null;
  unpair(): void;
  // Draws what a click asked for at once, before the core's state says it (wished).
  wish(key: string, value: unknown): void;
}

export const AppCtx = createContext<App>(null as unknown as App);
export const useApp = () => useContext(AppCtx);

export function menuAt(app: App, e: { clientX: number; clientY: number }, items: MenuItem[]): void {
  if (app.phone) app.setOverlay({ sheet: { title: "", items } });
  else app.setOverlay({ menu: { items, x: e.clientX, y: e.clientY } });
}

// The page's shortcut modifier: ⌘ on a Mac (terminals never see it), Ctrl+Shift elsewhere (Ctrl
// alone belongs to the terminal). The browser keeps ⌘T, ⌘W, ⌘N and ⌘1-9, so those actions have
// no key here.
export const IS_MAC = /Mac|iPhone|iPad/.test(typeof navigator === "undefined" ? "" : navigator.platform);
export const MOD = IS_MAC ? "⌘" : "Ctrl+Shift+";

export interface Keys {
  k: string; // KeyboardEvent.key, lowercased ("k", "arrowdown", ",")
  shift?: boolean;
  alt?: boolean;
}

export function keysLabel(x: Keys): string {
  const names: Record<string, string> = { arrowdown: "↓", arrowup: "↑", arrowleft: "←", arrowright: "→", enter: "↩" };
  const k = names[x.k] ?? x.k.toUpperCase();
  if (IS_MAC) return (x.alt ? "⌥" : "") + (x.shift ? "⇧" : "") + "⌘" + k;
  return "Ctrl+Shift+" + (x.alt ? "Alt+" : "") + k;
}

export function keysMatch(x: Keys, e: KeyboardEvent): boolean {
  const mod = IS_MAC ? e.metaKey && !e.ctrlKey : e.ctrlKey && e.shiftKey && !e.metaKey;
  if (!mod || !!x.alt !== e.altKey) return false;
  if (IS_MAC && !!x.shift !== e.shiftKey) return false;
  if (!IS_MAC && x.shift) return false; // Shift is the modifier there
  const key = e.key.length === 1 ? e.key.toLowerCase() : e.key.toLowerCase();
  if (key === x.k) return true;
  // ⌥ changes the character on a Mac: compare the physical key
  return e.code === "Key" + x.k.toUpperCase() || (x.k === "," && e.code === "Comma");
}

// "2m", "3h", "4d" since a time in ns (State's time.Time); "" unknown.
export function ago(ns: number | undefined, now = Date.now()): string {
  if (!ns || ns <= 0) return "";
  const s = Math.max(0, Math.floor((now - ns / 1e6) / 1000));
  if (s < 60) return "now";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  return Math.floor(s / 86400) + "d";
}

// A click's effect drawn before the core confirms it: the wished value until the core's state
// equals it, or for WISH_MS at most (a refused command: the state's value comes back).
const WISH_MS = 3000;
export const wishes = new Map<string, { v: unknown; at: number }>();
export function wished<T>(key: string, actual: T): T {
  const w = wishes.get(key);
  if (!w) return actual;
  if (w.v === actual || performance.now() - w.at > WISH_MS) {
    wishes.delete(key);
    return actual;
  }
  return w.v as T;
}

// The session the page shows: the core's current one, or the one just clicked (focusSession).
export function shownSession(app: App): number {
  return wished("session", app.store.currentSession);
}
