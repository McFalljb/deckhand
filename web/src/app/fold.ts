// The left column's folding: this browser's own view state, never a command and never the
// core's (the native window keeps its own). A project row's sessions open and close here at once;
// the core lists a project's sessions once the page has opened it (web_watch), and from then on
// sends only the rows that change. Kept per browser in localStorage (when it can be).

import type { Link } from "../link.ts";
import type { Store } from "../state.ts";

const KEY = "deckhand.fold.v1";
const WATCH_MAX = 48; // as the core keeps (WEB_WATCH_MAX)

interface Saved {
  open: string[]; // project keys whose sessions show (most recent last)
  kids: string[]; // project or group keys whose nested folders show
  all: string[]; // projects showing all their sessions, not the first few
  machines: number[]; // other machines folded
}

function load(): Saved | null {
  try {
    const s = JSON.parse(localStorage.getItem(KEY) ?? "null");
    if (s && Array.isArray(s.open) && Array.isArray(s.kids)) return { all: [], machines: [], ...s };
  } catch {
    /* private window, blocked storage: start fresh */
  }
  return null;
}

class Fold {
  open = new Set<string>();
  kids = new Set<string>();
  all = new Set<string>();
  machines = new Set<number>();
  seeded = false;
  version = 0;
  private listeners = new Set<() => void>();
  private watchSent = "";

  constructor() {
    const s = load();
    if (s) {
      this.open = new Set(s.open);
      this.kids = new Set(s.kids);
      this.all = new Set(s.all);
      this.machines = new Set(s.machines);
      this.seeded = true;
    }
  }

  // A browser with nothing saved starts as the window looks: the selected project open, and the
  // nested folders the window has open.
  seed(store: Store): void {
    if (this.seeded || !store.ready) return;
    this.seeded = true;
    if (store.selectedProject) this.open.add(String(store.selectedProject));
    const exp: string[] = store.sidebar.expanded ?? [];
    for (const r of store.webTree) if (r.kids > 0 && exp.includes(r.path)) this.kids.add(r.key);
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private changed(): void {
    this.version++;
    try {
      localStorage.setItem(KEY, JSON.stringify({ open: [...this.open], kids: [...this.kids], all: [...this.all], machines: [...this.machines] } satisfies Saved));
    } catch {
      /* not kept: fine */
    }
    for (const fn of this.listeners) fn();
  }

  toggleOpen(key: string): void {
    if (this.open.has(key)) this.open.delete(key);
    else {
      this.open.add(key);
      // most recent last: the watch keeps the newest WATCH_MAX
      if (this.open.size > 200) this.open.delete(this.open.values().next().value!);
    }
    this.changed();
  }
  toggleKids(key: string): void {
    if (this.kids.has(key)) this.kids.delete(key);
    else this.kids.add(key);
    this.changed();
  }
  showAll(key: string): void {
    this.all.add(key);
    this.changed();
  }
  toggleMachine(no: number): void {
    if (this.machines.has(no)) this.machines.delete(no);
    else this.machines.add(no);
    this.changed();
  }

  // The projects whose sessions the page shows, for the core to list (web_watch): sent when it
  // changes and the core's list does not have them all yet. Folding a project sends nothing.
  syncWatch(store: Store, link: Link): void {
    const web = store.web;
    if (!web) return;
    const want = [...this.open].filter((k) => /^\d+$/.test(k)).map(Number);
    const local = want.filter((id) => {
      const p = store.project(id);
      return p && p.group === "projects" && !p.machine;
    });
    const ids = local.slice(-WATCH_MAX);
    const have = new Set(web.watch ?? []);
    if (ids.every((id) => have.has(id))) {
      this.watchSent = "";
      return;
    }
    // the core's list grows to the page's: what is open now (the order the page opened them)
    const keep = [...new Set([...(web.watch ?? []).filter((id) => this.open.has(String(id))), ...ids])].slice(-WATCH_MAX);
    const text = keep.join(",");
    if (text === this.watchSent) return;
    this.watchSent = text;
    link.run({ type: "web_watch", projects: keep }).then((r) => {
      if (!r.ok) this.watchSent = "";
    });
  }
}

export const fold = new Fold();
