// Home: what needs you first (the Attention view), then the projects, as the state gives them.

import { sessionTitle, type OpenSession, type Project } from "../state.ts";
import { attentionTier, DOT_LABEL, sessionDot, tabDot, type Dot } from "../status.ts";
import type { Ctx } from "./ctx.ts";
import { ago, h, replace } from "./dom.ts";
import { openSheet } from "./overlay.ts";

export function mark(dot: Dot): HTMLElement {
  return h("span", { class: "mark mark-" + dot, role: "img", "aria-label": DOT_LABEL[dot], title: DOT_LABEL[dot] });
}

const GROUPS: { tier: number; title: string }[] = [
  { tier: 3, title: "Needs you" },
  { tier: 2, title: "Finished" },
  { tier: 1, title: "Working" },
  { tier: 0, title: "Open" },
];

export class HomeScreen {
  readonly el: HTMLElement;
  private list: HTMLElement;

  constructor(private ctx: Ctx) {
    this.list = h("div", { class: "scroll" });
    const menu = h("button", { class: "icon-btn", type: "button", "aria-label": "Menu", on: { click: () => this.menu() } }, "⋯");
    const plus = h("button", { class: "btn primary", type: "button", on: { click: () => this.newMenu() } }, "+ New");
    this.el = h(
      "div",
      { class: "screen home" },
      h("header", { class: "bar" }, h("div", { class: "bar-title" }, "Deckhand"), menu),
      this.list,
      h("footer", { class: "bottom-bar" }, plus),
    );
  }

  update(): void {
    const { store } = this.ctx;
    const out: Node[] = [];
    if (!store.ready) {
      replace(this.list, h("p", { class: "empty" }, "Connecting to Deckhand…"));
      return;
    }

    // ---- open sessions by what they need ----
    const rows = store.openSessions
      .filter((s) => !s.home)
      .map((s) => ({ s, dot: sessionDot(store, s), since: this.since(s) }));
    for (const g of GROUPS) {
      const these = rows.filter((r) => attentionTier(r.dot) === g.tier).sort((a, b) => (b.since || 0) - (a.since || 0));
      if (!these.length) continue;
      out.push(h("h2", { class: "section" }, g.title));
      for (const r of these) out.push(this.sessionRow(r.s, r.dot, r.since));
    }
    if (!rows.length) out.push(h("p", { class: "empty" }, "No open sessions."));

    // ---- projects, this Mac's then each machine's ----
    const hidden = new Set<string>(store.sidebar.hidden_projects ?? []);
    const pinned: string[] = store.sidebar.pinned_projects ?? [];
    const openProjects = new Set(store.openSessions.map((s) => s.project_id));
    const shown = store.projects.filter(
      (p) => p.group !== "chats" && !hidden.has(p.cwd) && (openProjects.has(p.id) || (!p.temp && !p.missing)),
    );
    const byMachine = new Map<number, Project[]>();
    for (const p of shown) {
      const list = byMachine.get(p.machine || 0) ?? [];
      list.push(p);
      byMachine.set(p.machine || 0, list);
    }
    const machines = [0, ...store.machines.map((m) => m.no).filter((n) => n !== 0)];
    const multi = store.machines.length > 0;
    for (const no of machines) {
      const list = byMachine.get(no) ?? [];
      const m = store.machines.find((x) => x.no === no);
      if (no !== 0 && !m) continue;
      const title = no === 0 ? (multi ? "This machine" : "Projects") : m!.name;
      const head = h("h2", { class: "section" }, title);
      if (m && m.status !== "online") head.append(h("span", { class: "section-note" }, " · " + m.status.replace(/_/g, " ")));
      out.push(head);
      if (no === 0) {
        const chats = store.chatsEntry;
        if (chats) out.push(this.projectRow(chats, "Chats"));
      }
      list.sort((a, b) => {
        const pa = pinned.indexOf(a.cwd), pb = pinned.indexOf(b.cwd);
        return (pa < 0 ? 1e9 : pa) - (pb < 0 ? 1e9 : pb);
      });
      for (const p of list) out.push(this.projectRow(p));
      if (!list.length && no !== 0) out.push(h("p", { class: "empty small" }, m!.error || "No projects there yet."));
    }
    replace(this.list, ...out);
  }

  private since(s: OpenSession): number {
    let t = 0;
    for (const tab of this.ctx.store.tabs(s.id)) if (tabDot(tab) !== "none" && (tab.status_since ?? 0) > t) t = tab.status_since ?? 0;
    return t;
  }

  private sessionRow(s: OpenSession, dot: Dot, since: number): HTMLElement {
    const { store } = this.ctx;
    const p = store.project(s.project_id);
    const where = [p ? p.name || p.label : "", store.machineName(s.machine)].filter(Boolean).join(" · ");
    return h(
      "button",
      { class: "row", type: "button", on: { click: () => this.ctx.showSession(s.id) } },
      mark(dot),
      h("span", { class: "row-main" }, h("span", { class: "row-title" }, sessionTitle(store, s)), h("span", { class: "row-sub" }, where)),
      h("span", { class: "row-time" }, ago(since)),
    );
  }

  private projectRow(p: Project, label?: string): HTMLElement {
    const open = this.ctx.store.openSessions.filter((s) => s.project_id === p.id && !s.home).length;
    return h(
      "button",
      { class: "row", type: "button", on: { click: () => this.ctx.showProject(p.id) } },
      h("span", { class: "row-icon", "aria-hidden": "true" }, label ? "◇" : "▸"),
      h("span", { class: "row-main" }, h("span", { class: "row-title" }, label ?? (p.name || p.label)), label ? null : h("span", { class: "row-sub" }, p.label)),
      h("span", { class: "row-time" }, open ? String(open) + " open" : ""),
    );
  }

  private newMenu(): void {
    const { store } = this.ctx;
    const chats = store.chatsEntry;
    const actions = [];
    if (chats)
      actions.push({
        label: "New chat",
        primary: true,
        run: async () => {
          const r = await this.ctx.run({ type: "new_chat", project_id: chats.id });
          if (r.ok && r.created_id) this.ctx.showSession(r.created_id);
        },
      });
    openSheet("New", [h("p", { class: "muted" }, "For a session in a project, open the project below.")], actions);
  }

  private menu(): void {
    openSheet("Deckhand", [h("p", { class: "muted" }, "This browser stays paired until you unpair it here or revoke it at the Mac.")], [
      { label: "Unpair this browser", danger: true, run: () => this.ctx.unpair() },
    ]);
  }
}
