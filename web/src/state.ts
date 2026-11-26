// The replica of the core's State (src/core/state_wire.odin): state.full{version, state} gives
// every section, state.delta{version, sections} the sections that changed (null: it went). A
// section is plain JSON in State's own shape: field names as in the Odin structs, enums as
// lowercased names, unions as {"<variant>": value}.
//
// Fixed sections: projects, sessions, view, settings, jobs, confirmations, notifications, reload,
// claude, live, machines; per open session "tabs:<id>" and "panes:<id>"; per tab "panels:<id>".

export type Json = any;

export interface Project {
  id: number;
  machine: number;
  group: string;
  name: string;
  cwd: string;
  label: string;
  missing?: boolean;
  temp?: boolean;
  repo?: boolean;
  parent?: number;
}

export interface SessionRow {
  id: string;
  path: string;
  when_: string;
  title: string;
  untitled?: string;
  claude?: boolean;
  codex?: boolean;
}

export interface ProgSummary {
  state: string;
  kind: string;
  progress?: number;
  title?: string;
  msg?: string;
  at?: number;
}

export interface Tab {
  id: number;
  machine: number;
  kind: Record<string, Json> | null;
  title: string;
  pane?: number;
  exit?: { known: boolean; code: number; signal: number };
  live?: Json;
  reload?: Json;
  status: string; // running | exited | not_started
  agent: string; // unknown | idle | working | error
  waiting: boolean;
  question: boolean;
  unseen: boolean;
  prog?: ProgSummary;
  status_since?: number;
  has_term?: boolean;
  output_recent?: boolean;
}

export interface OpenSession {
  id: number;
  machine: number;
  agent: string; // pi | claude | files (a project's open files, no agent)
  pi_session_id: string;
  project_id: number;
  cwd: string;
  active_tab: number;
  missing?: boolean;
  home?: boolean;
  title: string;
  shown_at?: number;
}

export interface PendingConfirmation {
  token: string;
  summary: string;
  command: Json;
  class: string;
  caller: Json;
}

export interface MachineView {
  no: number;
  name: string;
  status: string;
  error?: string;
  version?: string;
  os?: string;
}

// The browser's sections (src/core/web_view.odin): the views the core computes for a browser,
// keyed so a delta carries only the rows that changed.
//   web: the small part; webo:<id> an open session's row; webm other machines; webtree the
//   Projects tree's order [[key, depth, kids, forced]]; webp:<key> a tree row; websl:<p> a
//   project's session ids in order, webs:<p>:<id> its rows; webcl / webc:<id> the Chats;
//   webbars the tabs' bars as text (app/bars.ts); webst:<id> an open session's status marks
//   {from, tabs {<tab>: [dot, mark, progress %]}} (status.ts).
export interface WebProjectRow {
  key: string;
  id: number; // 0: a group row (its folder in path)
  name: string;
  path: string;
  depth: number;
  kids: number; // nested folders shown
  forced: boolean; // open whatever the page folded (the filter, waiting work)
  pin: number;
  hidden: boolean;
}
export interface WebSessionRow {
  id: string;
  label: string;
  open: number;
  pin: number;
  hidden: boolean;
  dot: string;
  claude: boolean;
  codex: boolean;
  modified: number;
}
export interface WebAttention {
  session: number;
  group: "needs_you" | "finished" | "working" | "idle";
  tab: number;
}
export interface WebTitle {
  title: string;
  place: string;
  chat: boolean;
  at: number; // Unix ns, 0 "new"
}
export interface WebMachine {
  no: number;
  open: number[];
  projects: { id: number; depth: number; name: string }[];
}
export interface WebView {
  fleet: { waiting: number; errors: number; unseen: number; working: number };
  next: number;
  open: number[];
  attention: WebAttention[];
  deck: WebAttention[];
  filtered: number;
  here: { name: string; label: string };
  watch: number[];
  new?: WebNewChoices[]; // the New session picker's harnesses, per machine (web_view_new_choices)
  atlas?: boolean; // Atlas is offered (pi installed, or Atlas open or running): its button before its first start
  filter?: WebFilter; // this browser's own filter and quick filters (web_filters), never the Mac's
}
export interface WebFilter {
  text: string;
  running: boolean;
  waiting: boolean;
  pinned: boolean;
}
export interface WebNewChoice {
  harness: "pi" | "claude" | "codex";
  label: string;
  account?: string; // "" = the core's pick
}
export interface WebNewTab {
  account: string; // "" = the core's pick
  name: string; // the account's label while there are several, else ""
}
export interface WebNewChoices {
  machine: number; // 0 = this machine
  projects: WebNewChoice[];
  chats: WebNewChoice[];
  claude_tab?: WebNewTab[]; // New Claude tab there ([] = not installed)
  codex_tab?: WebNewTab[];
  note: string; // why a list is empty
  project_rows?: { project: number; rows: WebNewChoice[] }[]; // a project whose picker is not its kind's list (its last used account first)
}

export interface PaneLeaf {
  id: number;
  active: number;
  slot: number;
}
export interface LayoutNode {
  id: number;
  leaf: boolean;
  pane: number;
  dir: string; // right | down
  ratio: number;
  a: number;
  b: number;
  parent: number;
}
export interface Panes {
  panes: PaneLeaf[];
  nodes: LayoutNode[];
  root: number;
  focused_pane: number;
  zoomed_pane: number;
}
export interface Panel {
  id: string;
  title: string;
  rows: { text: string; tone: string; head: boolean }[];
}

export class Store {
  version = 0;
  sections = new Map<string, Json>();
  private listeners = new Set<() => void>();

  // state.full: every section, replacing what was there.
  applyFull(msg: Json): boolean {
    if (!msg || typeof msg.state !== "object" || msg.state === null) return false;
    this.sections = new Map(Object.entries(msg.state));
    this.rowsStamp++;
    this.marksStamp++;
    this.version = Number(msg.version) || 0;
    this.changed();
    return true;
  }

  // state.delta: the changed sections, null for one that went. False: not taken (no state.full yet,
  // or a malformed message), and the caller asks for state.full again.
  applyDelta(msg: Json): boolean {
    if (!msg || typeof msg.sections !== "object" || msg.sections === null) return false;
    if (this.sections.size === 0) return false;
    for (const [k, v] of Object.entries(msg.sections)) {
      if (k.startsWith("webp:")) this.rowsStamp++;
      if (k.startsWith("webst:")) this.marksStamp++;
      if (v === null) this.sections.delete(k);
      else this.sections.set(k, v);
    }
    this.version = Number(msg.version) || this.version;
    this.changed();
    return true;
  }

  clear(): void {
    this.sections.clear();
    this.marksStamp++;
    this.version = 0;
    this.changed();
  }

  get ready(): boolean {
    return this.sections.size > 0;
  }

  subscribe(fn: () => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private changed(): void {
    for (const fn of this.listeners) fn();
  }

  // ---- readers ----

  private sec(name: string): Json {
    return this.sections.get(name) ?? {};
  }

  get projects(): Project[] {
    return this.sec("projects").projects ?? [];
  }
  get selectedProject(): number {
    return this.sec("projects").selected_project ?? 0;
  }
  get sessions(): SessionRow[] {
    return this.sec("sessions").sessions ?? [];
  }
  get chats(): SessionRow[] {
    return this.sec("sessions").chats ?? [];
  }
  get openSessions(): OpenSession[] {
    return this.sec("sessions").open_sessions ?? [];
  }
  get currentSession(): number {
    return this.sec("sessions").current_session ?? 0;
  }
  get confirmations(): PendingConfirmation[] {
    return this.sec("confirmations").pending_confirmations ?? [];
  }
  get machines(): MachineView[] {
    const m = this.sections.get("machines");
    return (m && m.machines) ?? [];
  }
  get settings(): Json {
    return this.sec("settings").settings ?? {};
  }
  get sidebar(): Json {
    return this.sec("view").sidebar ?? {};
  }

  get web(): WebView | null {
    return this.sections.get("web") ?? null;
  }
  webTitle(id: number): WebTitle | undefined {
    return this.sections.get("webo:" + id);
  }
  get webMachines(): WebMachine[] {
    return this.sections.get("webm") ?? [];
  }
  // The Projects tree in the core's order, every row that passes the filter (folding is the page's).
  get webTree(): WebProjectRow[] {
    const t = this.sections.get("webtree");
    if (t !== this.treeOf) {
      this.treeOf = t;
      this.treeRowsAt = -1;
    }
    if (this.treeRowsAt !== this.rowsStamp) {
      // the order or a row changed: the rows again from their sections (a key alone: depth 0)
      this.treeRows = (Array.isArray(t) ? t : []).map((e: string | [string, number, number, number]) => {
        const [key, depth, kids, forced] = typeof e === "string" ? [e, 0, 0, 0] : e;
        return { key, depth, kids, forced: !!forced, id: 0, name: "", path: "", pin: -1, hidden: false, ...(this.sections.get("webp:" + key) ?? {}) };
      });
      this.treeRowsAt = this.rowsStamp;
    }
    return this.treeRows;
  }
  private treeOf: Json = undefined;
  private treeRows: WebProjectRow[] = [];
  private treeRowsAt = -1;
  private rowsStamp = 0;
  // A project's listed sessions (the ones the page opened: web_watch, and the selected one's).
  webSessions(pid: number): WebSessionRow[] | null {
    const ids = this.sections.get("websl:" + pid);
    if (!Array.isArray(ids)) return null;
    return ids.map((id: string) => ({ id, ...(this.sections.get(`webs:${pid}:${id}`) ?? {}) }));
  }
  get webChats(): WebSessionRow[] {
    const ids = this.sections.get("webcl");
    if (!Array.isArray(ids)) return [];
    return ids.map((id: string) => ({ id, ...(this.sections.get("webc:" + id) ?? {}) }));
  }
  get layout(): Json {
    return this.sec("view").layout ?? {};
  }
  get homeSession(): number {
    return this.sec("sessions").home ?? 0;
  }
  get homeOpen(): boolean {
    return !!this.sec("view").home_open;
  }
  get jobs(): Json[] {
    return this.sec("jobs").jobs ?? [];
  }
  get machineJobs(): Json[] {
    return this.sec("jobs").machine_jobs ?? [];
  }
  get notices(): Json {
    return this.sec("notifications").notices ?? {};
  }
  get agent(): Json {
    return this.sec("notifications").agent ?? {};
  }
  get live(): Json {
    return this.sections.get("live")?.live ?? {};
  }
  get reload(): Json {
    return this.sections.get("reload")?.reload ?? {};
  }
  get holderAsk(): Json {
    return this.sec("confirmations").holder_ask ?? {};
  }

  panes(sessionId: number): Panes | null {
    return this.sections.get("panes:" + sessionId) ?? null;
  }
  panels(tabId: number): Panel[] {
    return this.sections.get("panels:" + tabId) ?? [];
  }

  tabs(sessionId: number): Tab[] {
    return this.sections.get("tabs:" + sessionId) ?? [];
  }

  // A tab's status mark as the core computed it (webst:<session>: [dot, mark, progress %]).
  tabMark(tabId: number): [string, string, number] | undefined {
    if (this.marksAt !== this.marksStamp) {
      this.marks.clear();
      for (const [k, v] of this.sections) if (k.startsWith("webst:") && v?.tabs) for (const [id, m] of Object.entries(v.tabs)) this.marks.set(Number(id), m as [string, string, number]);
      this.marksAt = this.marksStamp;
    }
    return this.marks.get(tabId);
  }
  // The tab an open session's row shows the mark of (0: none).
  markFrom(sessionId: number): number {
    return this.sections.get("webst:" + sessionId)?.from ?? 0;
  }
  private marks = new Map<number, [string, string, number]>();
  private marksAt = -1;
  private marksStamp = 0;

  session(id: number): OpenSession | undefined {
    return this.openSessions.find((s) => s.id === id);
  }

  project(id: number): Project | undefined {
    const ps = this.projects;
    if (ps !== this.byIdOf) {
      this.byIdOf = ps;
      this.byId = new Map(ps.map((p) => [p.id, p]));
    }
    return this.byId.get(id);
  }
  private byIdOf: Project[] | null = null;
  private byId = new Map<number, Project>();

  tab(id: number): { session: OpenSession; tab: Tab } | undefined {
    for (const s of this.openSessions) {
      const t = this.tabs(s.id).find((x) => x.id === id);
      if (t) return { session: s, tab: t };
    }
    return undefined;
  }

  // The Chats entry (projects' last, group "chats"): new_chat with its id starts a chat.
  get chatsEntry(): Project | undefined {
    return this.projects.find((p) => p.group === "chats" && !p.machine);
  }

  machineName(no: number): string {
    if (!no) return "";
    return this.machines.find((m) => m.no === no)?.name ?? "machine " + no;
  }
}

// The variant name of a tab's kind union: "pi_tab", "shell_tab", "claude_tab", "editor_tab", …
export function tabKind(t: Tab): string {
  if (!t.kind || typeof t.kind !== "object") return "";
  return Object.keys(t.kind)[0] ?? "";
}

// A tab whose program runs in a terminal the core can stream.
export function isTerminalTab(t: Tab): boolean {
  const k = tabKind(t);
  return k === "pi_tab" || k === "shell_tab" || k === "claude_tab" || !!t.has_term;
}

export function sessionTitle(store: Store, s: OpenSession): string {
  const w = store.webTitle(s.id);
  if (w?.title) return w.title;
  if (s.title) return s.title;
  const p = store.project(s.project_id);
  if (p) return p.name || p.label;
  return "Session " + s.id;
}

// A pane's stream the core closed (Kind.Close: its tab's process went). When the tab runs again
// (Restart: a new process, a new terminal) the pane attaches to it. Bounded: a stream attached and
// closed again with no bytes (another machine's terminal that is not there) is tried at most
// REOPEN_TRIES times; bytes on the new channel (live) or the tab leaving running (a new process
// to come) start the count again, so a reattach that failed never blocks the next Restart. A tab
// still exited keeps its last output under the exit bar.
export const REOPEN_TRIES = 3;
export class ReopenGuard {
  private tries = 0;
  // the tab's status now (and on each change): not running gives the next process its tries
  status(s: string | undefined): void {
    if (s !== "running") this.tries = 0;
  }
  // bytes came on the attached channel: the stream works
  live(): void {
    this.tries = 0;
  }
  // after a close or a status change: attach again now?
  want(status: string | undefined, attachable: boolean): boolean {
    this.status(status);
    if (status !== "running" || !attachable || this.tries >= REOPEN_TRIES) return false;
    this.tries++;
    return true;
  }
}
