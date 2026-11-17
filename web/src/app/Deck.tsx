// The Deck (src/ui_deck.odin): every open session as a card in the Attention order (the core's
// "web" deck rows), grouped Needs you, Finished, Working, Idle. Shown when no session is current,
// and as the phone's home.

import type { WebAttention } from "../state.ts";
import { sessionView, tabView, type TabView } from "../status.ts";
import { ago, menuAt, useApp, shownSession } from "./ctx.ts";
import { HarnessIcon, Icon, StatusMark } from "./icons.tsx";
import { focusSession, newChat, openHarness, sessionItems } from "./Sidebar.tsx";
import { peekProps } from "./Peek.tsx";

const GROUPS = [
  ["needs_you", "Needs you"],
  ["finished", "Finished"],
  ["working", "Working"],
  ["idle", "Idle"],
] as const;

function words(v: TabView): string {
  if (v.msg.trim()) return v.msg.trim();
  switch (v.dot) {
    case "waiting":
      return "Waiting for you";
    case "question":
      return "Asked you a question";
    case "error":
      return "Stopped with an error";
    case "unseen":
      return "Finished";
    case "working": {
      const a = ago(v.since);
      return a && a !== "now" ? `Working for ${a}` : "Working";
    }
    case "exited":
      return "Exited";
  }
  return "Idle";
}

export function Deck() {
  const app = useApp();
  const rows = app.store.web?.deck ?? [];
  if (!app.store.web) return <div class="deck"><p class="empty">Loading…</p></div>;
  if (!rows.length)
    return (
      <div class="deck empty-deck">
        <Icon name="deck" size={28} />
        <h2>Nothing open</h2>
        <p class="muted">Open a session from a project, or start a chat.</p>
        <button type="button" class="btn primary" onClick={() => newChat(app)}>
          New chat
        </button>
      </div>
    );
  return (
    <div class="deck">
      {GROUPS.map(([g, title]) => {
        const mine = rows.filter((r) => r.group === g);
        if (!mine.length) return null;
        return (
          <section class="deck-group">
            <h3 class="deck-title">
              {title} <span class="count">{mine.length}</span>
            </h3>
            <div class="deck-grid">
              {mine.map((r) => (
                <Card r={r} />
              ))}
            </div>
          </section>
        );
      })}
    </div>
  );
}

function Card({ r }: { r: WebAttention }) {
  const app = useApp();
  const { store } = app;
  const s = store.session(r.session);
  if (!s) return null;
  const tabs = store.tabs(s.id);
  const from = r.tab ? tabs.find((t) => t.id === r.tab) : undefined;
  const v = from ? tabView(from) : sessionView(store, s);
  const w = store.webTitle(s.id);
  const need = r.group === "needs_you";
  const lines = r.group === "idle" ? 0 : need ? 3 : 1;
  const harness = openHarness(store, s);
  const age = v.dot !== "none" ? ago(v.since) : w ? (w.at ? ago(w.at) : "new") : "";
  const others = tabs.length > 1 ? tabs.filter((t) => t !== from).map((t) => tabView(t).dot) : [];
  const dots = (["waiting", "error", "unseen", "working"] as const).filter((d) => others.includes(d));
  return (
    <div
      class={"card g-" + r.group + (v.dot === "error" ? " err" : "") + (shownSession(app) === s.id ? " current" : "")}
      role="button"
      tabIndex={0}
      {...peekProps(app, s.id, r.tab || undefined)}
      onClick={() => focusSession(app, s.id, r.tab || undefined)}
      onKeyDown={(e) => e.key === "Enter" && focusSession(app, s.id, r.tab || undefined)}
      onContextMenu={(e) => {
        e.preventDefault();
        menuAt(app, e, sessionItems(app, s));
      }}
    >
      <div class="card-top">
        <StatusMark mark={v.mark} progress={v.progress} />
        {!w?.chat ? <span class="place">{(w?.place ?? "") + " ·"}</span> : null}
        <span class={"card-title" + (r.group === "idle" ? " idle" : "")}>{w?.title ?? s.title}</span>
        <span class="spacer" />
        <span class={"when" + (v.dot === "error" ? " error-ink" : need ? " waiting" : "")}>{age}</span>
        <button
          type="button"
          class="icon-btn small card-more"
          aria-label="More"
          onClick={(e) => {
            e.stopPropagation();
            menuAt(app, e as unknown as MouseEvent, sessionItems(app, s));
          }}
        >
          <Icon name="more" size={14} />
        </button>
      </div>
      {lines ? <div class={"card-body l" + lines + (need ? "" : " quiet")}>{words(v)}</div> : null}
      <div class="card-meta">
        {s.agent === "files" ? <Icon name="folder" size={12} /> : <HarnessIcon harness={harness} size={12} />}
        <span>{s.agent === "files" ? "Files" : harness === "pi" ? "pi" : harness === "claude" ? "Claude Code" : "Codex"}</span>
        {s.machine ? <span class="mach">{store.machineName(s.machine)}</span> : null}
        <span class="spacer" />
        {tabs.length > 1 ? (
          <>
            {dots.length ? dots.map((d) => <span class={"chip-dot " + (d === "unseen" ? "done" : d === "working" ? "running" : d)} />) : <span class="chip-dot quiet" />}
            <span>{tabs.length} tabs</span>
          </>
        ) : null}
      </div>
    </div>
  );
}
