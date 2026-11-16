// Deckhand in the browser (issue #148, phase 1): pairing, the attention list and projects, and a
// session's terminals, over the core's own framed wire on a WebSocket.

import "@xterm/xterm/css/xterm.css";
import "./theme.gen.css";
import "./app.css";

import { unpair, whoami } from "./api.ts";
import { Link, type LinkStatus, type Result, type WindowRequest } from "./link.ts";
import type { Ctx } from "./ui/ctx.ts";
import { h, replace } from "./ui/dom.ts";
import { HomeScreen } from "./ui/home.ts";
import { closeSheet, offerCopy, offerLink, overlayInit, toast } from "./ui/overlay.ts";
import { pairScreen } from "./ui/pair.ts";
import { ProjectScreen } from "./ui/project.ts";
import { SessionScreen } from "./ui/session.ts";

const root = document.getElementById("app")!;
const statusLine = h("div", { class: "status-line", role: "status", hidden: true });
const main = h("main", { class: "main" });
const confirmBar = h("div", { class: "confirm-bar", hidden: true });
root.append(statusLine, main, confirmBar);
overlayInit(root);

const link = new Link({
  status: onStatus,
  toast: (text, err) => toast(text, err),
  request: onRequest,
  up: () => {
    if (screen === "session") session?.relinked();
    if (screen === "project") project?.relinked();
    schedule();
  },
});
const store = link.store;

const ctx: Ctx = {
  link,
  store,
  async run(command: object): Promise<Result> {
    const r = await link.run(command);
    // needs_confirmation by the user: it waits in the confirmation bar, from state
    // (not connected: the status line already says so)
    if (!r.ok && r.error !== "needs_confirmation" && r.error !== "not connected") toast(r.error || "That did not work", true);
    return r;
  },
  showHome: () => go(""),
  showProject: (id) => go(`p/${id}`),
  showSession: (id, tab) => go(tab ? `s/${id}/${tab}` : `s/${id}`),
  async unpair() {
    await unpair();
    location.hash = "";
    location.reload();
  },
};

let home: HomeScreen | null = null;
let project: ProjectScreen | null = null;
let session: SessionScreen | null = null;
let screen: "pair" | "home" | "project" | "session" | "away" = "home";

// ---- routing: #p/<project>, #s/<session>[/<tab>], else home (the phone's Back works) ----

function go(hash: string): void {
  if (location.hash.slice(1) === hash) route();
  else location.hash = hash;
}

function route(): void {
  if (screen === "pair" || screen === "away") return;
  closeSheet();
  const [kind, a, b] = location.hash.slice(1).split("/");
  if (kind === "s" && Number(a)) {
    session ??= new SessionScreen(ctx);
    if (screen !== "session") replace(main, session.el);
    screen = "session";
    session.show(Number(a), Number(b) || undefined);
    return;
  }
  session?.hide();
  if (kind === "p" && Number(a)) {
    project ??= new ProjectScreen(ctx);
    replace(main, project.el);
    screen = "project";
    project.show(Number(a));
    return;
  }
  home ??= new HomeScreen(ctx);
  replace(main, home.el);
  screen = "home";
  home.update();
}

window.addEventListener("hashchange", route);

// ---- state → screens, at most once a frame ----

let queued = false;
function schedule(): void {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    appearance();
    renderConfirm();
    if (screen === "home") home?.update();
    else if (screen === "project") project?.update();
    else if (screen === "session") session?.update();
  });
}
store.subscribe(schedule);

// The look's light or dark variant: the user's setting, "system" following this browser.
const prefersLight = window.matchMedia("(prefers-color-scheme: light)");
prefersLight.addEventListener("change", () => schedule());
function appearance(): void {
  const mode = String(store.settings.appearance ?? "system");
  const el = document.documentElement;
  if (mode === "light" || mode === "dark") el.dataset.appearance = mode;
  else delete el.dataset.appearance;
  const light = mode === "light" || (mode !== "dark" && prefersLight.matches) ? "1" : "0";
  if (el.dataset.light !== light) {
    el.dataset.light = light;
    session?.setLight(light === "1");
  }
}

// ---- the confirmation bar: the oldest waiting confirmation ----

function renderConfirm(): void {
  const c = store.confirmations[0];
  if (!c || screen === "pair" || screen === "away") {
    confirmBar.hidden = true;
    return;
  }
  const more = store.confirmations.length > 1 ? ` (+${store.confirmations.length - 1})` : "";
  const shown = c.token;
  replace(
    confirmBar,
    h("div", { class: "confirm-text" }, c.summary + more),
    h("div", { class: "confirm-actions" },
      h("button", { class: "btn", type: "button", on: { click: () => ctx.run({ type: "cancel_confirmation", token: c.token }) } }, "Cancel"),
      h("button", {
        class: "btn primary",
        type: "button",
        on: {
          click: () => {
            // never confirm what replaced the one the user read
            if (store.confirmations[0]?.token !== shown) return;
            if (!c.command || typeof c.command !== "object") {
              toast("This needs a newer page to confirm: cancel it, or confirm it at the Mac", true);
              return;
            }
            ctx.run({ ...c.command, confirm: c.token });
          },
        },
      }, "Confirm"),
    ),
  );
  confirmBar.hidden = false;
}

// ---- the link's status ----

function onStatus(s: LinkStatus): void {
  statusLine.hidden = true;
  switch (s.kind) {
    case "connecting":
      break;
    case "up":
      if (screen === "away") {
        screen = "home";
        route();
      }
      break;
    case "reconnecting":
      statusLine.textContent = "Reconnecting…";
      statusLine.hidden = false;
      break;
    case "displaced":
      away(
        s.by ? "Viewed from " + s.by : "Viewed at the Mac",
        "Your sessions keep running. Take them back to show them here (the other window lets go).",
        "Take back",
        () => link.takeBack(),
      );
      break;
    case "unpaired":
      showPair();
      break;
    case "stopped":
      away("Deckhand stopped this browser", s.why, "Try again", () => link.takeBack());
      break;
  }
}

function away(title: string, text: string, button: string, act: () => void): void {
  session?.hide();
  screen = "away";
  confirmBar.hidden = true;
  replace(
    main,
    h("div", { class: "screen away" },
      h("div", { class: "away-box" },
        h("h1", null, title),
        h("p", { class: "muted" }, text),
        h("button", {
          class: "btn primary wide",
          type: "button",
          on: {
            click: () => {
              // stays "away" until the link is up again (onStatus routes then)
              replace(main, h("p", { class: "empty" }, "Connecting…"));
              act();
            },
          },
        }, button),
      ),
    ),
  );
}

function showPair(): void {
  session?.hide();
  screen = "pair";
  confirmBar.hidden = true;
  replace(
    main,
    pairScreen(() => {
      screen = "home";
      route();
      link.start();
    }),
  );
}

// ---- what the core asks of this page (window.request) ----

function onRequest(req: WindowRequest): Record<string, unknown> | null {
  switch (req.op) {
    case "term_fit":
      return session?.fitReply() ?? null;
    case "clipboard_set":
      if (typeof req.text === "string") offerCopy(req.text);
      return { ok: true };
    case "open_url":
      if (typeof req.text === "string") offerLink(req.text);
      return { ok: true };
    case "notify":
      toast([req.text, req.message].filter(Boolean).join(": "));
      return { ok: true };
  }
  return null; // not a browser's: answered {ok:false}
}

// ---- the phone's visible height (the keyboard takes part of it) ----

function viewport(): void {
  const vv = window.visualViewport;
  document.documentElement.style.setProperty("--vvh", `${vv ? vv.height : window.innerHeight}px`);
}
window.visualViewport?.addEventListener("resize", viewport);
window.addEventListener("resize", viewport);
viewport();

// ---- start ----

(async () => {
  route();
  const w = await whoami();
  if (w && !w.paired) {
    showPair();
    return;
  }
  link.start(); // unreachable: the link keeps trying and says so
})();
