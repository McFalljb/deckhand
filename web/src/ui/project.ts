// A project: its open sessions, New session, and its past sessions to resume.

import { sessionTitle, type SessionRow, type Store } from "../state.ts";
import { sessionDot } from "../status.ts";
import type { Ctx } from "./ctx.ts";
import { h, replace } from "./dom.ts";
import { mark } from "./home.ts";

const PAST_MAX = 40;

const FOUND = new Set(["ok", "too_old", "unchecked"]);

// Codex can start there: this machine's checklist (state.live) lists it, or another machine's
// core starts Codex tabs (its hello's codex_tabs) and has it (src/core/harness.odin machine_harnesses).
function codexAvailable(store: Store, machine: number): boolean {
  const has = (list: any[] | undefined) => (list ?? []).some((c) => c.id === "codex" && FOUND.has(c.state));
  if (!machine) return has(store.sections.get("live")?.live?.checklist);
  const m: any = store.machines.find((x) => x.no === machine);
  return !!m?.codex && has(m.checklist);
}

export class ProjectScreen {
  readonly el: HTMLElement;
  private title: HTMLElement;
  private list: HTMLElement;
  projectId = 0;

  constructor(private ctx: Ctx) {
    this.title = h("div", { class: "bar-title" });
    this.list = h("div", { class: "scroll" });
    this.el = h(
      "div",
      { class: "screen project" },
      h("header", { class: "bar" }, h("button", { class: "icon-btn", type: "button", "aria-label": "Back", on: { click: () => ctx.showHome() } }, "‹"), this.title),
      this.list,
    );
  }

  show(projectId: number): void {
    this.projectId = projectId;
    this.select();
    this.update();
  }

  // The link is up again: its sessions list may be another project's by now.
  relinked(): void {
    if (this.projectId) this.select();
  }

  // The project's past sessions come with it selected (Chats lists its own).
  private select(): void {
    const p = this.ctx.store.project(this.projectId);
    if (p && p.group !== "chats" && this.ctx.link.up) this.ctx.run({ type: "select_project", project_id: this.projectId });
  }

  update(): void {
    const { store } = this.ctx;
    const p = store.project(this.projectId);
    if (!p) {
      this.title.textContent = "Project";
      replace(this.list, h("p", { class: "empty" }, "This project is gone."));
      return;
    }
    const isChats = p.group === "chats";
    this.title.textContent = isChats ? "Chats" : p.name || p.label;
    const out: Node[] = [];

    const actions = h("div", { class: "actions" });
    if (isChats) {
      actions.append(this.button("New chat", true, { type: "new_chat", project_id: p.id }));
    } else {
      actions.append(this.button("New pi session", true, { type: "new_chat", project_id: p.id }));
      actions.append(this.button("New Claude session", false, { type: "new_claude_session", project_id: p.id }));
      if (codexAvailable(store, p.machine)) actions.append(this.button("New Codex session", false, { type: "new_claude_session", project_id: p.id, harness: "codex" }));
    }
    out.push(actions);
    if (p.machine) out.push(h("p", { class: "muted small" }, "On " + store.machineName(p.machine) + " · " + p.label));
    else if (!isChats) out.push(h("p", { class: "muted small" }, p.label));

    const open = store.openSessions.filter((s) => s.project_id === p.id && !s.home);
    if (open.length) {
      out.push(h("h2", { class: "section" }, "Open"));
      for (const s of open)
        out.push(
          h(
            "button",
            { class: "row", type: "button", on: { click: () => this.ctx.showSession(s.id) } },
            mark(sessionDot(store, s)),
            h("span", { class: "row-main" }, h("span", { class: "row-title" }, sessionTitle(store, s))),
          ),
        );
    }

    const openIds = new Set(open.map((s) => s.pi_session_id));
    const past: SessionRow[] = (isChats ? store.chats : store.selectedProject === p.id ? store.sessions : []).filter((r) => !openIds.has(r.id));
    out.push(h("h2", { class: "section" }, "Recent"));
    if (!isChats && store.selectedProject !== p.id) out.push(h("p", { class: "empty small" }, "Loading…"));
    else if (!past.length) out.push(h("p", { class: "empty small" }, "No other sessions."));
    for (const r of past.slice(0, PAST_MAX))
      out.push(
        h(
          "button",
          { class: "row", type: "button", on: { click: () => this.resume(r) } },
          h("span", { class: "row-icon", "aria-hidden": "true" }, r.claude ? (r.codex ? "◆" : "✳") : "π"),
          h("span", { class: "row-main" }, h("span", { class: "row-title" }, r.title || r.untitled || "Untitled session"), h("span", { class: "row-sub" }, r.when_ ?? "")),
        ),
      );
    replace(this.list, ...out);
  }

  private button(label: string, primary: boolean, command: object): HTMLElement {
    return h(
      "button",
      {
        class: primary ? "btn primary" : "btn",
        type: "button",
        on: {
          click: async () => {
            const r = await this.ctx.run(command);
            if (r.ok && r.created_id) this.ctx.showSession(r.created_id);
          },
        },
      },
      label,
    );
  }

  private async resume(r: SessionRow): Promise<void> {
    const res = await this.ctx.run({ type: "open_session", project_id: this.projectId, pi_session_id: r.id });
    if (res.ok && res.created_id) {
      // Chats answer with the Chats entry's id: find the session that opened
      const s = this.ctx.store.openSessions.find((x) => x.id === res.created_id) ?? this.ctx.store.openSessions.find((x) => x.pi_session_id === r.id);
      if (s) this.ctx.showSession(s.id);
    }
  }
}
