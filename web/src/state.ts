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
  agent: string; // pi | claude
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

export class Store {
  version = 0;
  sections = new Map<string, Json>();
  private listeners = new Set<() => void>();

  // state.full: every section, replacing what was there.
  applyFull(msg: Json): boolean {
    if (!msg || typeof msg.state !== "object" || msg.state === null) return false;
    this.sections = new Map(Object.entries(msg.state));
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
      if (v === null) this.sections.delete(k);
      else this.sections.set(k, v);
    }
    this.version = Number(msg.version) || this.version;
    this.changed();
    return true;
  }

  clear(): void {
    this.sections.clear();
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

  tabs(sessionId: number): Tab[] {
    return this.sections.get("tabs:" + sessionId) ?? [];
  }

  session(id: number): OpenSession | undefined {
    return this.openSessions.find((s) => s.id === id);
  }

  project(id: number): Project | undefined {
    return this.projects.find((p) => p.id === id);
  }

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
  if (s.title) return s.title;
  const p = store.project(s.project_id);
  if (p) return p.name || p.label;
  return "Session " + s.id;
}
