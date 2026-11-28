// The page: pairing, the link's status, then the desktop window (left column, top bar, the
// session's panes or the Deck, right panels, the Atlas drawer) or the phone's screens. One Preact
// tree; state renders at most once a frame.

import { render } from "preact";
import { useEffect, useMemo, useReducer, useRef, useState } from "preact/hooks";
import { pairKey, unpair, whoami } from "../api.ts";
import { Link, type LinkStatus, type Result, type WindowRequest } from "../link.ts";
import { AppCtx, useApp, wishes, type App, type Overlay, type ToastAction, shownSession } from "./ctx.ts";
import { Sidebar } from "./Sidebar.tsx";
import { SessionPanes } from "./Panes.tsx";
import { Deck } from "./Deck.tsx";
import { AgentDrawer, RightPanels, TopBar } from "./Bars.tsx";
import { Palette, useShortcuts } from "./Palette.tsx";
import { Bell } from "./Bell.tsx";
import { ConfirmBar, CopySheet, LinkSheet, Menu, Sheet, Toasts, type ToastItem } from "./Overlays.tsx";
import { PanelsSheet, PhoneHome, PhoneSession, SelectSheet } from "./Phone.tsx";
import { fitFor, focusedFit } from "./Term.tsx";
import { pairScreen } from "../ui/pair.ts";
import { SettingsPage } from "./Settings.tsx";
import { JobSheet } from "./JobSheet.tsx";
import { Peek } from "./Peek.tsx";
import { forgetTypingMode } from "./phone.ts";
import { storageGet, storageRemove } from "../ui/dom.ts";

const PHONE = "(max-width: 760px)";
const NO_OVERLAY: Overlay = { menu: null, palette: false, bell: false, sheet: null, link: null, copy: null, job: null, peek: null, atlas: false, panels: null, select: null };

type Screen = { kind: "pair" } | { kind: "away"; title: string; text: string; button: string; act: () => void } | { kind: "main" };

export function start(root: HTMLElement) {
  render(<Root />, root);
}

function Root() {
  const [, tick] = useReducer((x: number) => x + 1, 0);
  const [screen, setScreen] = useState<Screen>({ kind: "main" });
  const [reconnecting, setReconnecting] = useState(false);
  const [overlay, setOverlayState] = useState<Overlay>(NO_OVERLAY);
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const [phone, setPhone] = useState(() => window.matchMedia(PHONE).matches);
  const [route, setRoute] = useState<App["route"]>(() => parseHash());
  const toastId = useRef(0);
  // a browser left in the old saved text-box mode types straight in again, once (phone.ts)
  useEffect(() => {
    if (forgetTypingMode({ get: storageGet, remove: storageRemove }))
      toast("Typing goes straight into the terminal again. The text box is in the session menu (⋯).");
  }, []);

  const toast = (text: string, err = false, action?: ToastAction) => {
    const id = ++toastId.current;
    const drop = () => setToasts((t) => t.filter((x) => x.id !== id));
    // an action (Undo) runs once and takes its toast away; it stays a while longer
    const act = action && { label: action.label, run: () => (drop(), action.run()) };
    setToasts((t) => [...t.slice(-2), { id, text, err, action: act }]);
    window.setTimeout(drop, act ? 8000 : err ? 6000 : 3000);
  };

  const link = useMemo(
    () =>
      new Link({
        status: (s: LinkStatus) => onStatus(s),
        toast: (text, err) => toast(text, err),
        request: (req) => onRequest(req),
        up: () => tick(0),
      }),
    [],
  );

  function onStatus(s: LinkStatus) {
    setReconnecting(s.kind === "reconnecting");
    switch (s.kind) {
      case "up":
        setScreen((x) => (x.kind === "away" ? { kind: "main" } : x));
        break;
      case "displaced":
        // by "": this Mac's window has the view (it took it back, or it was there when this page
        // connected on its own: a connect never takes it from the Mac without the user)
        setScreen(
          s.by
            ? {
                kind: "away",
                title: s.by,
                text: "Your sessions keep running. Take them back to show them here (the other window lets go).",
                button: "Take back",
                act: () => link.takeBack(),
              }
            : {
                kind: "away",
                title: "Your Mac is showing these sessions",
                text: "Your sessions keep running. View them here to show them in this browser (the Mac window lets go).",
                button: "View here",
                act: () => link.takeBack(),
              },
        );
        break;
      case "unpaired":
        setScreen({ kind: "pair" });
        break;
      case "stopped":
        setScreen({ kind: "away", title: "Disconnected", text: s.why, button: "Try again", act: () => link.takeBack() });
        break;
    }
    tick(0);
  }

  function onRequest(req: WindowRequest): Record<string, unknown> | null {
    switch (req.op) {
      case "term_fit": {
        const f = typeof req.tab_id === "number" ? fitFor(req.tab_id) : focusedFit();
        return f ? { ok: true, cols: f.cols, rows: f.rows, cell: [f.cellW, f.cellH] } : null;
      }
      case "clipboard_set":
        if (typeof req.text === "string") setOverlayState((o) => ({ ...o, copy: req.text }));
        return { ok: true };
      case "open_url":
        if (typeof req.text === "string") setOverlayState((o) => ({ ...o, link: req.text }));
        return { ok: true };
      case "notify":
        toast([req.text, req.message].filter(Boolean).join(": "));
        return { ok: true };
    }
    return null; // not a browser's: answered {ok:false}
  }

  // state → a render at most once a frame
  useEffect(() => {
    let queued = false;
    return link.store.subscribe(() => {
      if (queued) return;
      queued = true;
      requestAnimationFrame(() => {
        queued = false;
        tick(0);
      });
    });
  }, []);

  // the phone's width, its visible height (the keyboard takes part of it), the hash route
  useEffect(() => {
    const mq = window.matchMedia(PHONE);
    const onMq = () => setPhone(mq.matches);
    mq.addEventListener("change", onMq);
    const vv = () => {
      const v = window.visualViewport;
      document.documentElement.style.setProperty("--vvh", `${v ? v.height : window.innerHeight}px`);
      document.documentElement.style.setProperty("--vvtop", `${v ? Math.max(0, v.offsetTop) : 0}px`);
    };
    window.visualViewport?.addEventListener("resize", vv);
    window.visualViewport?.addEventListener("scroll", vv);
    window.addEventListener("resize", vv);
    vv();
    const onHash = () => setRoute(parseHash());
    window.addEventListener("hashchange", onHash);
    return () => {
      mq.removeEventListener("change", onMq);
      window.removeEventListener("hashchange", onHash);
    };
  }, []);

  // start: a page with its key opens the link at once (whoami alongside: it renews the cookie, and
  // the link's refused hello asks it again); one without asks first (paired? else the pair screen)
  useEffect(() => {
    const keyed = !!pairKey();
    if (keyed) link.start();
    (async () => {
      const w = await whoami();
      if (w && !w.paired) setScreen({ kind: "pair" });
      else if (!keyed) link.start(); // unreachable: the link keeps trying and says so
    })();
  }, []);

  useAppearance(link.store.settings.appearance, link.store.settings.theme);

  const app: App = {
    link,
    store: link.store,
    phone,
    async run(command: object): Promise<Result> {
      const r = await link.run(command);
      // needs_confirmation by the user: it waits in the confirmation bar, from state
      if (!r.ok && r.error !== "needs_confirmation" && r.error !== "not connected") toast(r.error || "That did not work", true);
      return r;
    },
    toast,
    overlay,
    setOverlay: (o) => setOverlayState((x) => ({ ...x, ...o })),
    route,
    go: (r) => {
      const next = { ...route, ...r };
      const hash = next.screen === "session" && next.session ? `s/${next.session}` : next.screen === "deck" || next.screen === "jobs" || next.screen === "settings" ? next.screen : "";
      if (location.hash.slice(1) !== hash) location.hash = hash;
      setRoute(next);
    },
    fit: focusedFit,
    wish(key, value) {
      wishes.set(key, { v: value, at: performance.now() });
      tick(0);
      window.setTimeout(() => tick(0), 3100); // the wish lapses: draw the state's value
    },
    async unpair() {
      await unpair();
      location.hash = "";
      location.reload();
    },
  };

  return (
    <AppCtx.Provider value={app}>
      {screen.kind === "pair" ? (
        <PairHost
          onPaired={() => {
            setScreen({ kind: "main" });
            link.start(true); // just paired: the user wants the sessions here
          }}
        />
      ) : screen.kind === "away" ? (
        <Away s={screen} />
      ) : (
        <Main />
      )}
      {reconnecting ? <div class="status-line" role="status">Reconnecting…</div> : null}
      {screen.kind === "main" ? (
        <>
          <ConfirmBar />
          {overlay.palette ? <Palette /> : null}
          {overlay.bell ? <Bell /> : null}
          <Menu />
          <Sheet />
          <LinkSheet />
          <CopySheet />
          <PanelsSheet />
          <SelectSheet />
          {overlay.job ? <JobSheet /> : null}
          {overlay.peek ? <Peek /> : null}
        </>
      ) : null}
      <Toasts items={toasts} />
    </AppCtx.Provider>
  );
}

function parseHash(): App["route"] {
  const [kind, a] = location.hash.slice(1).split("/");
  if (kind === "s" && Number(a)) return { screen: "session", session: Number(a), project: 0 };
  if (kind === "deck" || kind === "jobs" || kind === "settings") return { screen: kind, session: 0, project: 0 };
  return { screen: "home", session: 0, project: 0 };
}

// The look's light or dark variant: the user's setting, "system" following this browser.
function useAppearance(mode: unknown, look: unknown) {
  const [, tick] = useReducer((x: number) => x + 1, 0);
  useEffect(() => {
    const mq = window.matchMedia("(prefers-color-scheme: light)");
    mq.addEventListener("change", tick);
    return () => mq.removeEventListener("change", tick);
  }, []);
  const m = String(mode ?? "system");
  const el = document.documentElement;
  el.dataset.look = String(look ?? "graphite");
  if (m === "light" || m === "dark") el.dataset.appearance = m;
  else delete el.dataset.appearance;
  el.dataset.light = m === "light" || (m !== "dark" && window.matchMedia("(prefers-color-scheme: light)").matches) ? "1" : "0";
}

function PairHost({ onPaired }: { onPaired: () => void }) {
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    box.current!.replaceChildren(pairScreen(onPaired));
  }, []);
  return <div class="pair-host" ref={box} />;
}

function Away({ s }: { s: Extract<Screen, { kind: "away" }> }) {
  const [busy, setBusy] = useState(false);
  return (
    <div class="away">
      <div class="away-box">
        <h1>{s.title}</h1>
        <p class="muted">{s.text}</p>
        <button
          type="button"
          class="btn primary wide"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            s.act();
          }}
        >
          {busy ? "Connecting…" : s.button}
        </button>
      </div>
    </div>
  );
}

function Main() {
  const app = useApp();
  useShortcuts(app);
  const { store } = app;
  const [leftW, setLeftW] = useState<number | null>(null);
  if (!store.ready) return <div class="loading">Connecting…</div>;
  if (app.phone) {
    if (app.route.screen === "settings") return <SettingsPage onClose={() => app.go({ screen: "home" })} />;
    if (app.route.screen === "session" && app.route.session) return <PhoneSession id={app.route.session} />;
    return <PhoneHome />;
  }
  const layout = store.layout;
  const width = leftW ?? Math.round(Number(layout.left_width) || 300);
  const cs = store.session(shownSession(app));
  const settings = app.route.screen === "settings";
  return (
    <div class={"window" + (layout.left_open ? "" : " no-left") + (layout.right_open ? "" : " no-right")} style={{ "--left-w": width + "px", "--right-w": Math.round(Number(layout.right_width) || 320) + "px" }}>
      {layout.left_open ? (
        <Sidebar
          width={width}
          onResize={(w, done) => {
            setLeftW(done ? null : w);
            if (done) app.run({ type: "set_layout", left_width: w });
          }}
        />
      ) : null}
      <div class="centre">
        <TopBar />
        <div class="centre-body">
          <div class="panes">{settings ? <SettingsPage onClose={() => app.go({ screen: "home" })} /> : cs && !cs.home ? <SessionPanes s={cs} key={cs.id} /> : <Deck />}</div>
          {layout.right_open && cs && !cs.home && !settings ? <RightPanels /> : null}
          {store.homeOpen ? <AgentDrawer /> : null}
        </div>
      </div>
    </div>
  );
}
