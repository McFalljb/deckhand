// The top bar (src/ui_toolbar.odin), the right column's panels (the focused tab's, published by
// its bridge), the Atlas drawer (the Home session's pi tab), and the left column's tabs a browser
// cannot show yet.

import { useApp, shownSession } from "./ctx.ts";
import { keysLabel, menuAt } from "./ctx.ts";
import { Icon, Logo } from "./icons.tsx";
import { IconButton, newSessionItems } from "./Sidebar.tsx";
import { newTabItems } from "./Panes.tsx";
import { TermPane } from "./Term.tsx";
import { unreadCount } from "./Bell.tsx";
import type { Panel } from "../state.ts";

export function agentName(app: ReturnType<typeof useApp>): string {
  return String(app.store.settings.agent_name || "Atlas");
}

export function TopBar() {
  const app = useApp();
  const { store } = app;
  const cs = store.session(shownSession(app));
  const fleet = store.web?.fleet;
  const unread = unreadCount(app);
  const left = !!store.layout.left_open;
  const name = agentName(app);
  const agentUnread = Number(store.agent?.unread ?? 0);
  return (
    <header class="topbar">
      {!left ? (
        <IconButton icon="sidebar-left" label={`Show the left column (${keysLabel({ k: "b" })})`} run={() => app.run({ type: "set_layout", left_open: true })} />
      ) : null}
      <IconButton
        icon="plus"
        label="New tab"
        run={(e) => {
          if (cs) menuAt(app, e, newTabItems(app, cs));
          else if (store.selectedProject) menuAt(app, e, newSessionItems(app, store.selectedProject));
        }}
      />
      <IconButton
        icon="chevron-down"
        small
        label="New session"
        run={(e) => store.selectedProject && menuAt(app, e, newSessionItems(app, store.selectedProject))}
      />
      <IconButton icon="deck" label="Deck" run={() => app.run({ type: "show_no_session" }).then(() => app.go({ screen: "deck" }))} />
      <span class="spacer" />
      <button type="button" class="search-pill" onClick={() => app.setOverlay({ palette: true })}>
        <Icon name="search" size={14} />
        <span>Search or run a command…</span>
        <span class="keys">{keysLabel({ k: "k" })}</span>
      </button>
      <span class="spacer" />
      {fleet && (fleet.waiting || fleet.errors) ? (
        <button type="button" class={"fleet-pill" + (fleet.errors ? " err" : "")} title="Next needing you" onClick={() => app.run({ type: "next_needing_you" })}>
          <span class={"chip-dot " + (fleet.errors ? "error" : "waiting")} />
          {fleet.waiting ? `${fleet.waiting} waiting` : ""}
          {fleet.waiting && fleet.errors ? " · " : ""}
          {fleet.errors ? `${fleet.errors} error${fleet.errors > 1 ? "s" : ""}` : ""}
        </button>
      ) : null}
      <IconButton icon="bell" label="Notifications" badge={unread} run={() => app.setOverlay({ bell: !app.overlay.bell })} />
      <IconButton icon="sidebar-right" label={`Right panels (${keysLabel({ k: "b", alt: true })})`} run={() => app.run({ type: "set_layout", right_open: !store.layout.right_open })} />
      {store.homeSession ? (
        <button type="button" class={"agent-btn" + (store.homeOpen ? " on" : "")} onClick={() => app.run({ type: "set_home", open: !store.homeOpen })} title={`${name} (${keysLabel({ k: "j" })})`}>
          <span class="agent-avatar">{name[0]?.toUpperCase()}</span>
          {name}
          {agentUnread ? <span class="badge">{agentUnread}</span> : null}
        </button>
      ) : null}
    </header>
  );
}

export function RightPanels() {
  const app = useApp();
  const { store } = app;
  const cs = store.session(shownSession(app));
  const panels: Panel[] = [];
  const seen = new Set<string>();
  // the session's pi tab first, then the tab on screen: what their bridges publish
  if (cs)
    for (const t of store.tabs(cs.id))
      for (const p of store.panels(t.id))
        if (!seen.has(p.id)) {
          seen.add(p.id);
          panels.push(p);
        }
  const collapsed: string[] = store.layout.collapsed ?? [];
  return (
    <aside class="right">
      <div class="right-head">
        <span class="pop-title">Panels</span>
        <span class="spacer" />
        <IconButton small icon="close" label="Hide the right panels" run={() => app.run({ type: "set_layout", right_open: false })} />
      </div>
      {panels.length === 0 ? <p class="empty small">The session's agent publishes its todos, subagents and shells here.</p> : null}
      {panels.map((p) => {
        const folded = collapsed.includes(p.id);
        // a bridge's first head row is the panel's title ("Todos 3/4"), as the window draws it
        const head = p.rows[0]?.head ? p.rows[0].text : p.title;
        const rows = p.rows[0]?.head ? p.rows.slice(1) : p.rows;
        return (
          <section class="panel">
            <button type="button" class="panel-head" onClick={() => app.run({ type: "set_panel_collapsed", panel: p.id, collapsed: !folded })}>
              <Icon name={folded ? "chevron-right" : "chevron-down"} size={12} />
              <span>{head}</span>
            </button>
            {folded
              ? null
              : rows.map((r) => (
                  <div class={"panel-row tone-" + (r.tone || "normal") + (r.head ? " head" : "")}>
                    <span>{r.text}</span>
                  </div>
                ))}
          </section>
        );
      })}
    </aside>
  );
}

export function AgentDrawer() {
  const app = useApp();
  const { store } = app;
  const home = store.session(store.homeSession);
  if (!home) return null;
  const tab = store.tabs(home.id)[0];
  const name = agentName(app);
  return (
    <aside class={"drawer" + (app.phone ? " phone" : "")}>
      <div class="drawer-head">
        <Logo name="pi" size={14} />
        <span class="pop-title">{name}</span>
        <span class="spacer" />
        <IconButton small icon="close" label={`Close ${name}`} run={() => app.run({ type: "set_home", open: false })} />
      </div>
      <div class="drawer-body">
        {tab ? <TermPane tabId={tab.id} attachable={tab.status !== "not_started"} focused keyboard={!app.phone} /> : <p class="empty">Starting {name}…</p>}
      </div>
    </aside>
  );
}

export function NotHere({ what }: { what: "files" | "settings" }) {
  const words =
    what === "files"
      ? { title: "Files are not in the browser yet", text: "The file tree, the editor and Changes stay in the Deckhand window for now. They need the core to send directory listings and file contents (list_dir, editor_state) to a browser." }
      : { title: "Settings are not in the browser yet", text: "Change settings in the Deckhand window. The palette here has the look, appearance and filters." };
  return (
    <div class="not-here">
      <Icon name={what === "files" ? "folder" : "sliders"} size={20} />
      <div>{words.title}</div>
      <p class="muted small">{words.text}</p>
    </div>
  );
}
