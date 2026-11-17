// A session's panes (src/ui_panes.odin): the layout tree from its panes:<id> section, each leaf a
// pane with its own tab strip and the tab it shows. Terminal tabs stream into xterm.js, Changes
// and file tabs have their own views; browser and app tabs say they are at the Mac only.

import { useRef } from "preact/hooks";
import { isTerminalTab, tabKind, type LayoutNode, type OpenSession, type Panes, type Tab } from "../state.ts";
import { stripView } from "../status.ts";
import { keysLabel, menuAt, useApp, wished, type App, type MenuItem } from "./ctx.ts";
import { HarnessIcon, Icon, StatusMark } from "./icons.tsx";
import { TermPane } from "./Term.tsx";
import { ChangesView } from "./Changes.tsx";
import { FileTab } from "./Files.tsx";

// An editor tab's (its file view) or a Markdown tab's file ("" = another kind or view).
export function fileTabPath(t: Tab): string {
  const k = t.kind ?? {};
  if (k.markdown_tab) return String(k.markdown_tab.path ?? "");
  if (k.editor_tab && (k.editor_tab.view ?? "file") === "file") return String(k.editor_tab.path ?? "");
  return "";
}
import { newTabChoices } from "./harness.ts";
import { TabBars } from "./TabBars.tsx";

const KIND_WORDS: Record<string, string> = {
  editor_tab: "an editor",
  markdown_tab: "a Markdown",
  browser_tab: "a browser",
  app_tab: "an app",
  changes_tab: "a Changes",
};

export function tabHarness(t: Tab): "pi" | "claude" | "codex" | "shell" | "" {
  const k = tabKind(t);
  if (k === "pi_tab") return "pi";
  if (k === "claude_tab") return t.kind?.claude_tab?.codex ? "codex" : "claude";
  if (k === "shell_tab") return "shell";
  return "";
}

const KIND_ICON: Record<string, Parameters<typeof Icon>[0]["name"]> = {
  editor_tab: "file",
  markdown_tab: "file",
  browser_tab: "atlas",
  app_tab: "deck",
  changes_tab: "branch",
};

export function tabTitle(t: Tab): string {
  return t.title || tabKind(t).replace(/_tab$/, "") || "Tab";
}

export function SessionPanes({ s }: { s: OpenSession }) {
  const app = useApp();
  const p = app.store.panes(s.id);
  const tabs = app.store.tabs(s.id);
  if (!p || !p.nodes?.length) {
    // an older core, or not laid out yet: one pane with every tab
    return <PaneView s={s} paneId={0} tabs={tabs} active={s.active_tab} focused only />;
  }
  if (p.zoomed_pane) return <Leaf s={s} p={p} paneId={p.zoomed_pane} tabs={tabs} />;
  return <NodeView s={s} p={p} index={p.root} tabs={tabs} />;
}

function NodeView({ s, p, index, tabs }: { s: OpenSession; p: Panes; index: number; tabs: Tab[] }) {
  const n = p.nodes[index];
  if (!n) return null;
  if (n.leaf) return <Leaf s={s} p={p} paneId={n.pane} tabs={tabs} />;
  return <Split s={s} p={p} n={n} tabs={tabs} />;
}

function Leaf({ s, p, paneId, tabs }: { s: OpenSession; p: Panes; paneId: number; tabs: Tab[] }) {
  const pane = p.panes.find((x) => x.id === paneId);
  const mine = tabs.filter((t) => t.pane === paneId || (!t.pane && p.panes.length === 1));
  return <PaneView s={s} paneId={paneId} tabs={mine} active={pane?.active ?? 0} focused={p.focused_pane === paneId} only={p.panes.length === 1} />;
}

function Split({ s, p, n, tabs }: { s: OpenSession; p: Panes; n: LayoutNode; tabs: Tab[] }) {
  const app = useApp();
  const box = useRef<HTMLDivElement>(null);
  const drag = useRef(false);
  const right = n.dir === "right";
  const ratio = Math.max(0.1, Math.min(0.9, n.ratio || 0.5));
  const set = (e: PointerEvent, done: boolean) => {
    const r = box.current!.getBoundingClientRect();
    const v = right ? (e.clientX - r.left) / r.width : (e.clientY - r.top) / r.height;
    const x = Math.max(0.1, Math.min(0.9, v));
    box.current!.style.setProperty("--ratio", String(x));
    if (done) app.run({ type: "set_split", split: n.id, ratio: x });
  };
  return (
    <div class={"split " + (right ? "split-row" : "split-col")} ref={box} style={{ "--ratio": String(ratio) }}>
      <div class="split-a">
        <NodeView s={s} p={p} index={n.a} tabs={tabs} />
      </div>
      <div
        class="split-divider"
        onPointerDown={(e) => {
          drag.current = true;
          (e.target as HTMLElement).setPointerCapture(e.pointerId);
        }}
        onPointerMove={(e) => drag.current && set(e as PointerEvent, false)}
        onPointerUp={(e) => {
          if (drag.current) set(e as PointerEvent, true);
          drag.current = false;
        }}
        onDblClick={() => app.run({ type: "equalize_panes", session: s.id })}
      />
      <div class="split-b">
        <NodeView s={s} p={p} index={n.b} tabs={tabs} />
      </div>
    </div>
  );
}

function PaneView(props: { s: OpenSession; paneId: number; tabs: Tab[]; active: number; focused: boolean; only: boolean }) {
  const app = useApp();
  const { s, paneId, tabs } = props;
  // a clicked tab shows at once (wished), the core's focus_tab confirms it
  const active = wished(`tab:${s.id}:${paneId}`, props.active);
  const tab = tabs.find((t) => t.id === active) ?? tabs[0];
  const focusPane = () => {
    if (!props.focused && paneId) app.run({ type: "focus_pane", pane: paneId });
  };
  return (
    <section class={"pane" + (props.focused && !props.only ? " focused" : "")} onMouseDown={focusPane}>
      <TabStrip s={s} paneId={paneId} tabs={tabs} active={tab?.id ?? 0} only={props.only} />
      {tab ? <TabBars tab={tab} /> : null}
      <div class="pane-body">
        {!tab ? (
          <div class="pane-note">No tabs here.</div>
        ) : tabKind(tab) === "changes_tab" ? (
          <ChangesView s={s} tab={tab} />
        ) : fileTabPath(tab) ? (
          <FileTab s={s} tab={tab} path={fileTabPath(tab)} markdown={tabKind(tab) === "markdown_tab"} />
        ) : isTerminalTab(tab) ? (
          <>
            <TermPane tabId={tab.id} attachable={tab.status !== "not_started"} focused={props.focused} keyboard={!app.phone} onFocus={focusPane} />
            {tab.status === "not_started" ? <div class="pane-note over">Starting…</div> : null}
            {tab.status === "exited" ? <ExitedBar tab={tab} /> : null}
          </>
        ) : (
          <div class="pane-note">
            <Icon name={KIND_ICON[tabKind(tab)] ?? "file"} size={20} />
            <div>This is {KIND_WORDS[tabKind(tab)] ?? "a"} tab.</div>
            <div class="muted small">{tabKind(tab) === "browser_tab" || tabKind(tab) === "app_tab" ? "Browser and app tabs show only in the Deckhand window, at the Mac." : "It shows only in the Deckhand window, at the Mac."}</div>
          </div>
        )}
      </div>
    </section>
  );
}

function ExitedBar({ tab }: { tab: Tab }) {
  const app = useApp();
  const code = tab.exit?.known ? (tab.exit.signal ? `signal ${tab.exit.signal}` : `code ${tab.exit.code}`) : "";
  const k = tabKind(tab);
  const restart = k === "pi_tab" ? "pi_restart" : k === "claude_tab" ? "claude_restart" : "";
  return (
    <div class="exited-bar">
      <span>Exited{code ? ` (${code})` : ""}</span>
      <span class="spacer" />
      {restart ? (
        <button type="button" class="btn small" onClick={() => app.run({ type: restart, tab_id: tab.id })}>
          Restart
        </button>
      ) : null}
      {k !== "pi_tab" ? (
        <button type="button" class="btn small" onClick={() => app.run({ type: "close_tab", tab_id: tab.id })}>
          Close
        </button>
      ) : null}
    </div>
  );
}

function TabStrip({ s, paneId, tabs, active, only }: { s: OpenSession; paneId: number; tabs: Tab[]; active: number; only: boolean }) {
  const app = useApp();
  return (
    <div class="tabstrip" role="tablist">
      <div class="tabs-scroll">
        {tabs.map((t) => {
          const v = stripView(t);
          const h = tabHarness(t);
          const on = t.id === active;
          return (
            <div
              class={"tab" + (on ? " on" : "")}
              role="tab"
              aria-selected={on ? "true" : "false"}
              tabIndex={0}
              title={tabTitle(t)}
              onClick={() => {
                app.wish(`tab:${s.id}:${paneId}`, t.id);
                app.run({ type: "focus_tab", tab_id: t.id });
              }}
              onAuxClick={(e) => {
                if ((e as MouseEvent).button === 1 && tabKind(t) !== "pi_tab") app.run({ type: "close_tab", tab_id: t.id });
              }}
              onContextMenu={(e) => {
                e.preventDefault();
                menuAt(app, e, tabItems(app, s, t, paneId, only));
              }}
            >
              {v.dot !== "none" ? <StatusMark mark={v.mark} progress={v.progress} /> : null}
              {h && h !== "shell" ? <HarnessIcon harness={h} size={13} /> : !h ? <Icon name={KIND_ICON[tabKind(t)] ?? "file"} size={13} /> : null}
              <span class="tab-title">{tabTitle(t)}</span>
              {tabKind(t) !== "pi_tab" || tabs.length > 1 ? (
                <button
                  type="button"
                  class="tab-close"
                  aria-label="Close tab"
                  onClick={(e) => {
                    e.stopPropagation();
                    app.run({ type: "close_tab", tab_id: t.id });
                  }}
                >
                  <Icon name="close" size={12} />
                </button>
              ) : null}
            </div>
          );
        })}
        <button type="button" class="icon-btn small strip-add" title="New tab" aria-label="New tab" onClick={(e) => menuAt(app, e, newTabItems(app, s, paneId))}>
          <Icon name="plus" size={14} />
        </button>
      </div>
    </div>
  );
}

export function newTabItems(app: App, s: OpenSession, paneId?: number): MenuItem[] {
  const pane = paneId ? { pane: paneId } : {};
  const items: MenuItem[] = [
    { label: "Shell", keys: keysLabel({ k: "t", alt: true }), run: () => app.run({ type: "new_shell_tab", session: s.id, ...pane }) },
  ];
  // Claude Code and Codex while they are there, once per account while there are several (harness.ts)
  for (const c of [...newTabChoices(app.store, s.machine, { session: s.id }, false, "Claude Code"), ...newTabChoices(app.store, s.machine, { session: s.id }, true, "Codex")]) items.push({ label: c.label, run: () => app.run(c.cmd) });
  if (!s.machine) items.push({ label: "Changes", run: () => app.run({ type: "changes_open", session: s.id }) });
  return items;
}

function tabItems(app: App, s: OpenSession, t: Tab, paneId: number, only: boolean): MenuItem[] {
  const k = tabKind(t);
  const items: MenuItem[] = [];
  if (paneId) {
    items.push({ label: "Split right", run: () => app.run({ type: "split_pane", pane: paneId, direction: "right", tab_id: t.id }) });
    items.push({ label: "Split down", run: () => app.run({ type: "split_pane", pane: paneId, direction: "down", tab_id: t.id }) });
    if (!only) {
      items.push({ label: "Zoom pane", run: () => app.run({ type: "zoom_pane", pane: paneId }) });
      items.push({ label: "Close pane", run: () => app.run({ type: "close_pane", pane: paneId }) });
    }
    items.push({ sep: true });
  }
  if (k === "pi_tab") items.push({ label: "Restart pi", run: () => app.run({ type: "pi_restart", tab_id: t.id }) });
  if (k === "claude_tab") items.push({ label: "Restart", run: () => app.run({ type: "claude_restart", tab_id: t.id }) });
  if (t.unseen) items.push({ label: "Mark as read", run: () => app.run({ type: "set_unread", tab_id: t.id, unread: false }) });
  else items.push({ label: "Mark as unread", run: () => app.run({ type: "set_unread", tab_id: t.id, unread: true }) });
  items.push({ sep: true });
  items.push({ label: "Close tab", run: () => app.run({ type: "close_tab", tab_id: t.id }) });
  items.push({ label: "Close session", run: () => app.run({ type: "close_session", session: s.id }) });
  return items;
}
