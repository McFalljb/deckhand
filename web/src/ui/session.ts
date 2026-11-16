// A session: its tab strip, the tab on screen (a terminal, or "open at the Mac"), a key bar and a
// real text field under it. Only the tab on screen is attached; the core sizes its terminal to
// what this page fits.

import { isTerminalTab, sessionTitle, tabKind, type Tab } from "../state.ts";
import { tabDot } from "../status.ts";
import { createTerm, type TermView } from "../term.ts";
import { TermStream } from "../termstream.ts";
import type { Ctx } from "./ctx.ts";
import { h, replace, storageGet, storageSet } from "./dom.ts";
import { mark } from "./home.ts";
import { offerCopy, offerLink, openSheet } from "./overlay.ts";

const enc = new TextEncoder();
const CR = enc.encode("\r");
const KIND_NAMES: Record<string, string> = {
  editor_tab: "an editor",
  markdown_tab: "a Markdown",
  browser_tab: "a browser",
  app_tab: "an app",
  changes_tab: "a Changes",
};

function fontSizeDefault(): number {
  const saved = Number(storageGet("deckhand.termFont"));
  if (saved >= 8 && saved <= 24) return saved;
  return window.matchMedia("(max-width: 600px)").matches ? 12 : 13;
}

export class SessionScreen {
  readonly el: HTMLElement;
  sessionId = 0;
  private tabId = 0;
  private title: HTMLElement;
  private sub: HTMLElement;
  private strip: HTMLElement;
  private termBox: HTMLElement;
  private note: HTMLElement;
  private keybar: HTMLElement;
  private input: HTMLTextAreaElement;
  private rawBtn: HTMLButtonElement;
  private view: TermView;
  private stream: TermStream;
  private fontSize = fontSizeDefault();
  private raw: boolean;
  private ctrl = false;
  private alt = false;
  private waitingKeys = false;
  private failed = 0; // the tab whose attach failed (tried again when its record changes)
  private failedKey = "";
  private visible = false;

  constructor(private ctx: Ctx) {
    const saved = storageGet("deckhand.rawKeys");
    this.raw = saved !== null ? saved === "1" : window.matchMedia("(pointer: fine)").matches;
    this.title = h("div", { class: "bar-title" });
    this.sub = h("div", { class: "bar-sub" });
    this.strip = h("div", { class: "tabstrip", role: "tablist" });
    this.termBox = h("div", { class: "term" });
    this.note = h("div", { class: "term-note", hidden: true });
    this.keybar = h("div", { class: "keybar" });
    this.input = h("textarea", {
      class: "field input",
      rows: 1,
      placeholder: "Type or dictate…",
      autocomplete: "off",
      autocapitalize: "sentences",
      enterKeyHint: "send",
      "aria-label": "Text for the terminal",
    });
    this.rawBtn = h("button", { class: "icon-btn", type: "button", "aria-pressed": "false", title: "Raw keys", "aria-label": "Raw keys", on: { click: () => this.setRaw(!this.raw) } }, "⌨");
    const send = h("button", { class: "btn primary", type: "button", on: { click: () => this.send() } }, "Send");

    this.el = h(
      "div",
      { class: "screen session" },
      h(
        "header",
        { class: "bar" },
        h("button", { class: "icon-btn", type: "button", "aria-label": "Back", on: { click: () => ctx.showHome() } }, "‹"),
        h("div", { class: "bar-text" }, this.title, this.sub),
        h("button", { class: "icon-btn", type: "button", "aria-label": "Session menu", on: { click: () => this.menu() } }, "⋯"),
      ),
      this.strip,
      h("div", { class: "term-wrap" }, this.termBox, this.note),
      this.keybar,
      h("div", { class: "inputrow" }, this.rawBtn, this.input, send),
    );

    this.view = createTerm({ light: this.light(), fontSize: this.fontSize });
    this.view.mount(this.termBox);
    this.view.onLink((url) => offerLink(url));
    this.view.onInput((b) => this.stream.input(this.withMods(b)));
    this.stream = new TermStream(ctx.link, this.view);
    this.stream.events((e) => {
      if (e.kind === "error") {
        this.failed = this.tabId;
        this.failedKey = this.tabKey();
        this.showNote("No terminal for this tab yet.");
      } else if (e.kind === "closed") {
        this.showNote("This tab's terminal closed.");
      } else this.showNote("");
    });
    new ResizeObserver(() => {
      if (this.visible) this.stream.refit();
    }).observe(this.termBox);
    document.addEventListener("visibilitychange", () => {
      if (this.visible) this.stream.focus(document.visibilityState === "visible");
    });

    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault();
        this.send();
      }
    });
    // sticky Ctrl or Alt, then a letter typed in the field: that key goes at once
    this.input.addEventListener("beforeinput", (e) => {
      if ((this.ctrl || this.alt) && e.inputType === "insertText" && e.data && [...e.data].length === 1) {
        e.preventDefault();
        this.stream.input(this.withMods(enc.encode(e.data)));
      }
    });
    this.setRaw(this.raw);
    this.renderKeys();
  }

  show(sessionId: number, tabId?: number): void {
    const changed = sessionId !== this.sessionId;
    this.sessionId = sessionId;
    this.visible = true;
    if (changed) {
      this.tabId = 0;
      this.stream.detach();
    }
    if (tabId) this.tabId = tabId;
    // makes it current at the core, which starts its restored tabs (again once the link is up)
    if (this.ctx.link.up) this.ctx.run({ type: "focus_session", session: sessionId });
    this.update();
  }

  hide(): void {
    this.visible = false;
    this.stream.detach();
    this.view.blur();
  }

  // The link is up again (a fresh state.full): attach afresh.
  relinked(): void {
    if (!this.visible) return;
    this.failed = 0;
    this.ctx.run({ type: "focus_session", session: this.sessionId });
    if (this.stream.tabId) this.stream.reattach();
    this.update();
  }

  // window.request term_fit: a new terminal's grid, from what this page fits
  fitReply(): Record<string, unknown> | null {
    if (!this.visible) return null;
    const f = this.stream.currentFit();
    return f ? { ok: true, cols: f.cols, rows: f.rows, cell: [f.cellW, f.cellH] } : null;
  }

  setLight(light: boolean): void {
    this.view.setLight(light);
  }

  update(): void {
    if (!this.visible) return;
    const { store } = this.ctx;
    if (!store.ready) {
      this.showNote("Connecting…");
      return;
    }
    const s = store.session(this.sessionId);
    if (!s) {
      this.title.textContent = "Session closed";
      this.sub.textContent = "";
      replace(this.strip);
      this.stream.detach();
      this.showNote("This session is closed.");
      return;
    }
    const tabs = store.tabs(s.id);
    if (!tabs.some((t) => t.id === this.tabId)) this.tabId = tabs.some((t) => t.id === s.active_tab) ? s.active_tab : (tabs[0]?.id ?? 0);
    const p = store.project(s.project_id);
    this.title.textContent = sessionTitle(store, s);
    this.sub.textContent = [p ? p.name || p.label : "", store.machineName(s.machine)].filter(Boolean).join(" · ");

    // ---- the strip ----
    const items: Node[] = tabs.map((t) =>
      h(
        "button",
        {
          class: "tab" + (t.id === this.tabId ? " on" : ""),
          type: "button",
          role: "tab",
          "aria-selected": t.id === this.tabId ? "true" : "false",
          on: { click: () => this.pickTab(t.id) },
        },
        mark(tabDot(t)),
        h("span", { class: "tab-title" }, t.title || tabKind(t).replace(/_tab$/, "")),
      ),
    );
    items.push(h("button", { class: "tab add", type: "button", "aria-label": "New tab", on: { click: () => this.newTab() } }, "+"));
    replace(this.strip, ...items);
    this.strip.querySelector(".tab.on")?.scrollIntoView({ block: "nearest", inline: "nearest" });

    // ---- the body ----
    const tab = tabs.find((t) => t.id === this.tabId);
    this.showTab(tab);
    const waiting = !!tab && tabDot(tab) === "waiting";
    if (waiting !== this.waitingKeys) {
      this.waitingKeys = waiting;
      this.renderKeys();
    }
  }

  private tabKey(): string {
    const t = this.ctx.store.tab(this.tabId)?.tab;
    return t ? `${t.status}/${t.has_term}` : "";
  }

  private showTab(tab: Tab | undefined): void {
    if (!tab) {
      this.stream.detach();
      this.showNote("No tabs.");
      return;
    }
    if (!isTerminalTab(tab)) {
      this.stream.detach();
      const what = KIND_NAMES[tabKind(tab)] ?? "a";
      this.showNote(`This is ${what} tab: open it at the Mac.`);
      return;
    }
    if (tab.status === "not_started") {
      this.stream.detach();
      this.showNote("Starting…");
      return;
    }
    if (this.failed === tab.id) {
      if (this.failedKey === this.tabKey()) return; // tried; again once its record changes
      this.failed = 0;
    }
    if (this.stream.tabId !== tab.id) {
      this.showNote("");
      this.stream.attach(tab.id);
    }
  }

  private showNote(text: string): void {
    this.note.textContent = text;
    this.note.hidden = !text;
    this.termBox.classList.toggle("dim", !!text);
  }

  private pickTab(id: number): void {
    if (id === this.tabId) return;
    this.tabId = id;
    this.ctx.run({ type: "focus_tab", tab_id: id });
    this.update();
  }

  private newTab(): void {
    const sid = this.sessionId;
    const open = async (command: object) => {
      const r = await this.ctx.run(command);
      if (r.ok && r.created_id && this.sessionId === sid) {
        this.tabId = r.created_id;
        this.update();
      }
    };
    openSheet("New tab", [], [
      { label: "Shell", primary: true, run: () => open({ type: "new_shell_tab", session: sid }) },
      { label: "Claude Code", run: () => open({ type: "new_claude_tab", session: sid }) },
    ]);
  }

  private menu(): void {
    const tab = this.ctx.store.tab(this.tabId)?.tab;
    const actions = [
      { label: "Text smaller", run: () => this.setFont(this.fontSize - 1) },
      { label: "Text larger", run: () => this.setFont(this.fontSize + 1) },
      { label: "Copy screen text", run: () => offerCopy(this.view.screenText()) },
    ];
    if (tab && tabKind(tab) !== "pi_tab") actions.push({ label: "Close this tab", run: () => this.ctx.run({ type: "close_tab", tab_id: tab.id }) });
    openSheet(tab ? tab.title || "Tab" : "Session", [], actions);
  }

  private setFont(px: number): void {
    this.fontSize = Math.max(8, Math.min(24, px));
    storageSet("deckhand.termFont", String(this.fontSize));
    this.view.setFontSize(this.fontSize);
    this.stream.refit();
  }

  private setRaw(on: boolean): void {
    this.raw = on;
    storageSet("deckhand.rawKeys", on ? "1" : "0");
    this.rawBtn.setAttribute("aria-pressed", on ? "true" : "false");
    this.rawBtn.classList.toggle("on", on);
    this.input.hidden = on;
    this.view.setKeyboard(on && this.visible);
    if (!on && this.visible) this.input.focus();
  }

  // ---- input ----

  private send(): void {
    const text = this.input.value;
    this.input.value = "";
    this.ctrl = this.alt = false;
    this.renderKeys();
    if (!this.stream.attached) return;
    if (text) {
      this.view.paste(text); // bracketed when the program asked; out through onInput
      window.setTimeout(() => this.stream.input(CR), 30); // Enter after the paste, apart
    } else this.stream.input(CR);
  }

  // A key with the sticky modifiers, which then let go.
  private withMods(b: Uint8Array): Uint8Array {
    if (!this.ctrl && !this.alt) return b;
    let out = b;
    if (this.ctrl && b.length === 1) {
      const c = b[0];
      if (c >= 0x61 && c <= 0x7a) out = new Uint8Array([c - 0x60]);
      else if (c >= 0x40 && c <= 0x5f) out = new Uint8Array([c - 0x40]);
      else if (c === 0x20) out = new Uint8Array([0]);
      else if (c === 0x3f) out = new Uint8Array([0x7f]);
    }
    if (this.alt) {
      const x = new Uint8Array(out.length + 1);
      x[0] = 0x1b;
      x.set(out, 1);
      out = x;
    }
    this.ctrl = this.alt = false;
    this.renderKeys();
    return out;
  }

  private key(seq: string): void {
    this.stream.input(this.withMods(enc.encode(seq)));
  }

  private arrow(dir: "A" | "B" | "C" | "D"): void {
    const mod = this.ctrl ? 5 : this.alt ? 3 : 0;
    this.ctrl = this.alt = false;
    this.renderKeys();
    const seq = mod ? `\x1b[1;${mod}${dir}` : this.view.appCursor() ? `\x1bO${dir}` : `\x1b[${dir}`;
    this.stream.input(enc.encode(seq));
  }

  private renderKeys(): void {
    const b = (label: string, fn: () => void, cls = "", aria?: string) =>
      h(
        "button",
        {
          class: "key " + cls,
          type: "button",
          "aria-label": aria ?? label,
          on: {
            // keep the text field (and a phone's keyboard) where it is
            pointerdown: (e: Event) => e.preventDefault(),
            click: fn,
          },
        },
        label,
      );
    const keys: Node[] = [];
    if (this.waitingKeys) {
      for (const k of ["1", "2", "3", "y", "n"]) keys.push(b(k, () => this.key(k), "wide"));
      keys.push(b("Enter", () => this.key("\r"), "wide"));
      keys.push(b("Esc", () => this.key("\x1b")));
    } else {
      keys.push(b("Esc", () => this.key("\x1b")));
      keys.push(b("Tab", () => this.key("\t")));
      keys.push(
        b("Ctrl", () => {
          this.ctrl = !this.ctrl;
          this.renderKeys();
        }, this.ctrl ? "on" : ""),
      );
      keys.push(
        b("Alt", () => {
          this.alt = !this.alt;
          this.renderKeys();
        }, this.alt ? "on" : ""),
      );
      keys.push(b("←", () => this.arrow("D"), "", "Left"));
      keys.push(b("↓", () => this.arrow("B"), "", "Down"));
      keys.push(b("↑", () => this.arrow("A"), "", "Up"));
      keys.push(b("→", () => this.arrow("C"), "", "Right"));
      keys.push(b("^C", () => this.stream.input(new Uint8Array([3])), "", "Control C"));
    }
    replace(this.keybar, ...keys);
  }

  private light(): boolean {
    return document.documentElement.dataset.light === "1";
  }
}
