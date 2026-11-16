// The phone's screens (below 760 px): home is the left column full width (or the Deck), a session
// is one tab at a time with a key bar and a real text field (dictation, autocorrect), raw keys on
// request. The same components as the desktop underneath.

import { useEffect, useRef, useState } from "preact/hooks";
import { isTerminalTab, tabKind, type OpenSession } from "../state.ts";
import { stripView, tabView } from "../status.ts";
import { menuAt, useApp } from "./ctx.ts";
import { HarnessIcon, Icon, StatusMark } from "./icons.tsx";
import { IconButton, Sidebar } from "./Sidebar.tsx";
import { Deck } from "./Deck.tsx";
import { JobsPanel } from "./Jobs.tsx";
import { newTabItems, tabHarness, tabTitle } from "./Panes.tsx";
import { setTermFont, termFontSize, TermPane, type TermHandle } from "./Term.tsx";
import { agentName, AgentDrawer } from "./Bars.tsx";
import { unreadCount } from "./Bell.tsx";
import { storageGet, storageSet } from "../ui/dom.ts";

const enc = new TextEncoder();

export function PhoneHome() {
  const app = useApp();
  const deck = app.route.screen === "deck";
  const jobs = app.route.screen === "jobs";
  const fleet = app.store.web?.fleet;
  return (
    <div class="phone-screen">
      <header class="phone-bar">
        <span class="brand">Deckhand</span>
        <span class="spacer" />
        <IconButton icon="search" label="Search or run a command" run={() => app.setOverlay({ palette: true })} />
        <IconButton icon="bell" label="Notifications" badge={unreadCount(app)} run={() => app.setOverlay({ bell: true })} />
        {app.store.homeSession ? (
          <button type="button" class="agent-btn" onClick={() => app.run({ type: "set_home", open: !app.store.homeOpen })}>
            <span class="agent-avatar">{agentName(app)[0]}</span>
          </button>
        ) : null}
      </header>
      <div class="segmented phone-switch">
        <button type="button" class={!deck && !jobs ? "on" : ""} onClick={() => app.go({ screen: "home" })}>
          Sessions
        </button>
        <button type="button" class={deck ? "on" : ""} onClick={() => app.go({ screen: "deck" })}>
          Deck{fleet?.waiting ? ` · ${fleet.waiting}` : ""}
          {fleet?.waiting ? <span class="chip-dot waiting inline-dot" /> : null}
        </button>
        <button type="button" class={jobs ? "on" : ""} onClick={() => app.go({ screen: "jobs" })}>
          Jobs
        </button>
      </div>
      <div class="phone-body">{deck ? <Deck /> : jobs ? <div class="sidebar"><JobsPanel /></div> : <Sidebar width={0} onResize={() => {}} forceSessions />}</div>
      {app.store.homeOpen ? <AgentDrawer /> : null}
    </div>
  );
}

export function PhoneSession({ id }: { id: number }) {
  const app = useApp();
  const { store } = app;
  const s = store.session(id);
  const [raw, setRawState] = useState(() => storageGet("deckhand.rawKeys") === "1");
  const [mods, setMods] = useState({ ctrl: false, alt: false });
  const modsRef = useRef(mods);
  modsRef.current = mods;
  const term = useRef<TermHandle | null>(null);
  const field = useRef<HTMLTextAreaElement>(null);

  // makes it current at the core, which starts its restored tabs
  useEffect(() => {
    if (app.link.up && store.currentSession !== id) app.run({ type: "focus_session", session: id });
  }, [id, app.link.up]);

  if (!s) {
    return (
      <div class="phone-screen">
        <header class="phone-bar">
          <IconButton icon="back" label="Back" run={() => app.go({ screen: "home" })} />
          <span class="bar-title">Session closed</span>
        </header>
        <p class="empty">This session is closed.</p>
      </div>
    );
  }
  const tabs = store.tabs(s.id);
  const tab = tabs.find((t) => t.id === s.active_tab) ?? tabs[0];
  const w = store.web?.titles[String(s.id)];
  const waiting = !!tab && tabView(tab).dot === "waiting";

  const setRaw = (on: boolean) => {
    setRawState(on);
    storageSet("deckhand.rawKeys", on ? "1" : "0");
    if (!on) window.setTimeout(() => field.current?.focus(), 0);
  };
  const withMods = (b: Uint8Array): Uint8Array => {
    const m = modsRef.current;
    if (!m.ctrl && !m.alt) return b;
    let out = b;
    if (m.ctrl && b.length === 1) {
      const c = b[0];
      if (c >= 0x61 && c <= 0x7a) out = new Uint8Array([c - 0x60]);
      else if (c >= 0x40 && c <= 0x5f) out = new Uint8Array([c - 0x40]);
      else if (c === 0x20) out = new Uint8Array([0]);
      else if (c === 0x3f) out = new Uint8Array([0x7f]);
    }
    if (m.alt) {
      const x = new Uint8Array(out.length + 1);
      x[0] = 0x1b;
      x.set(out, 1);
      out = x;
    }
    setMods({ ctrl: false, alt: false });
    return out;
  };
  const input = (b: Uint8Array) => term.current?.stream.input(b);
  const key = (seq: string) => input(withMods(enc.encode(seq)));
  const arrow = (d: "A" | "B" | "C" | "D") => {
    const m = modsRef.current;
    const mod = m.ctrl ? 5 : m.alt ? 3 : 0;
    setMods({ ctrl: false, alt: false });
    input(enc.encode(mod ? `\x1b[1;${mod}${d}` : term.current?.view.appCursor() ? `\x1bO${d}` : `\x1b[${d}`));
  };
  const send = () => {
    const f = field.current;
    if (!f) return;
    const text = f.value;
    f.value = "";
    setMods({ ctrl: false, alt: false });
    if (!term.current?.stream.attached) return;
    if (text) {
      term.current.view.paste(text); // bracketed when the program asked; out through onInput
      window.setTimeout(() => input(enc.encode("\r")), 30); // Enter after the paste, apart
    } else input(enc.encode("\r"));
  };
  const K = (label: string, fn: () => void, cls = "", aria?: string) => (
    <button type="button" class={"key " + cls} aria-label={aria ?? label} onPointerDown={(e) => e.preventDefault()} onClick={fn}>
      {label}
    </button>
  );
  const menu = (e: MouseEvent) =>
    menuAt(app, e, [
      { label: "Text smaller", run: () => setTermFont(termFontSize(true) - 1) },
      { label: "Text larger", run: () => setTermFont(termFontSize(true) + 1) },
      { label: "Copy screen text", run: () => app.setOverlay({ copy: term.current?.view.screenText() ?? "" }) },
      { label: raw ? "Type in a text field" : "Raw keys (a keyboard)", run: () => setRaw(!raw) },
      { sep: true },
      ...(tab && tabKind(tab) !== "pi_tab" ? [{ label: "Close this tab", run: () => app.run({ type: "close_tab", tab_id: tab.id }) }] : []),
      { label: "Close session", run: () => app.run({ type: "close_session", session: s.id }).then((r) => r.ok && app.go({ screen: "home" })) },
    ]);

  return (
    <div class="phone-screen session">
      <header class="phone-bar">
        <IconButton icon="back" label="Back" run={() => app.go({ screen: "home" })} />
        <div class="bar-text">
          <div class="bar-title">{w?.title ?? s.title}</div>
          <div class="bar-sub">{[w?.chat ? "Chats" : w?.place, store.machineName(s.machine)].filter(Boolean).join(" · ")}</div>
        </div>
        <IconButton icon="more" label="Session menu" run={menu} />
      </header>
      <PhoneStrip s={s} active={tab?.id ?? 0} />
      <div class="phone-term">
        {!tab ? (
          <div class="pane-note">No tabs.</div>
        ) : isTerminalTab(tab) ? (
          <>
            <TermPane
              tabId={tab.id}
              attachable={tab.status !== "not_started"}
              focused
              keyboard={raw}
              onInput={withMods}
              handleRef={(h) => (term.current = h)}
            />
            {tab.status === "not_started" ? <div class="pane-note over">Starting…</div> : null}
          </>
        ) : (
          <div class="pane-note">This tab shows in the Deckhand window.</div>
        )}
      </div>
      <div class="keybar">
        {waiting ? (
          <>
            {["1", "2", "3", "y", "n"].map((k) => K(k, () => key(k), "wide"))}
            {K("Enter", () => key("\r"), "wide")}
            {K("Esc", () => key("\x1b"))}
          </>
        ) : (
          <>
            {K("Esc", () => key("\x1b"))}
            {K("Tab", () => key("\t"))}
            {K("Ctrl", () => setMods((m) => ({ ...m, ctrl: !m.ctrl })), mods.ctrl ? "on" : "")}
            {K("Alt", () => setMods((m) => ({ ...m, alt: !m.alt })), mods.alt ? "on" : "")}
            {K("←", () => arrow("D"), "", "Left")}
            {K("↓", () => arrow("B"), "", "Down")}
            {K("↑", () => arrow("A"), "", "Up")}
            {K("→", () => arrow("C"), "", "Right")}
            {K("^C", () => input(new Uint8Array([3])), "", "Control C")}
          </>
        )}
      </div>
      <div class="inputrow">
        <button type="button" class={"icon-btn" + (raw ? " on" : "")} aria-pressed={raw ? "true" : "false"} title="Raw keys" aria-label="Raw keys" onClick={() => setRaw(!raw)}>
          <Icon name="keyboard" size={18} />
        </button>
        {raw ? (
          <span class="raw-note muted small">Typing goes straight to the terminal</span>
        ) : (
          <textarea
            ref={field}
            class="field input"
            rows={1}
            placeholder="Type or dictate…"
            autocomplete="off"
            autocapitalize="sentences"
            enterkeyhint="send"
            aria-label="Text for the terminal"
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                e.preventDefault();
                send();
              }
            }}
            onBeforeInput={(e) => {
              // sticky Ctrl or Alt, then a letter typed in the field: that key goes at once
              const ie = e as InputEvent;
              const m = modsRef.current;
              if ((m.ctrl || m.alt) && ie.inputType === "insertText" && ie.data && [...ie.data].length === 1) {
                e.preventDefault();
                input(withMods(enc.encode(ie.data)));
              }
            }}
          />
        )}
        {!raw ? (
          <button type="button" class="btn primary send" aria-label="Send" onClick={send}>
            <Icon name="send" size={16} />
          </button>
        ) : null}
      </div>
      {app.store.homeOpen ? <AgentDrawer /> : null}
    </div>
  );
}

function PhoneStrip({ s, active }: { s: OpenSession; active: number }) {
  const app = useApp();
  const tabs = app.store.tabs(s.id);
  const strip = useRef<HTMLDivElement>(null);
  useEffect(() => {
    strip.current?.querySelector(".tab.on")?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }, [active]);
  return (
    <div class="tabstrip phone" role="tablist" ref={strip}>
      <div class="tabs-scroll">
        {tabs.map((t) => {
          const v = stripView(t);
          const h = tabHarness(t);
          return (
            <button type="button" role="tab" aria-selected={t.id === active ? "true" : "false"} class={"tab" + (t.id === active ? " on" : "")} onClick={() => app.run({ type: "focus_tab", tab_id: t.id })}>
              {v.dot !== "none" ? <StatusMark mark={v.mark} progress={v.progress} /> : null}
              {h && h !== "shell" ? <HarnessIcon harness={h} size={13} /> : null}
              <span class="tab-title">{tabTitle(t)}</span>
            </button>
          );
        })}
        <button type="button" class="icon-btn small strip-add" aria-label="New tab" onClick={(e) => menuAt(app, e as unknown as MouseEvent, newTabItems(app, s))}>
          <Icon name="plus" size={14} />
        </button>
      </div>
    </div>
  );
}
