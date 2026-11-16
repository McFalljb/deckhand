// The command palette (src/ui_palette.odin, actions from src/actions.odin in its order): open
// sessions and projects to jump to, then the actions a browser can run. The same table gives the
// page's shortcuts (keysMatch).

import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { OpenSession } from "../state.ts";
import { sessionView } from "../status.ts";
import { keysLabel, keysMatch, useApp, type App, type Keys } from "./ctx.ts";
import { score } from "./match.ts";
import { HarnessIcon, Icon, StatusMark } from "./icons.tsx";
import { codexAvailable, focusSession, newChat, newSessionItems, openHarness } from "./Sidebar.tsx";
import { newTabItems } from "./Panes.tsx";
import { setTermFont, termFontSize } from "./Term.tsx";

export interface Action {
  id: string;
  label: string | ((app: App) => string);
  keys?: Keys;
  when?: (app: App) => boolean;
  detail?: (app: App) => string;
  run: (app: App) => void;
}

const cur = (app: App): OpenSession | undefined => app.store.session(app.store.currentSession);
const curTab = (app: App) => {
  const s = cur(app);
  return s ? app.store.tabs(s.id).find((t) => t.id === s.active_tab) : undefined;
};
const panes = (app: App) => {
  const s = cur(app);
  return s ? app.store.panes(s.id) : null;
};
const current = (on: boolean) => (on ? "current" : "");
const onOff = (on: boolean) => (on ? "on" : "off");

function sessionStep(app: App, d: number) {
  const ids = app.store.web?.open ?? [];
  if (!ids.length) return;
  const at = ids.indexOf(app.store.currentSession);
  const next = ids[(at + d + ids.length) % ids.length];
  focusSession(app, next);
}

function tabStep(app: App, d: number) {
  const s = cur(app);
  if (!s) return;
  const p = app.store.panes(s.id);
  const tabs = app.store.tabs(s.id).filter((t) => !p || !p.focused_pane || t.pane === p.focused_pane);
  const at = tabs.findIndex((t) => t.id === s.active_tab);
  const t = tabs[(at + d + tabs.length) % tabs.length];
  if (t) app.run({ type: "focus_tab", tab_id: t.id });
}

const SORTS = ["recent", "name", "created", "attention"];
function nextSort(app: App, section: string) {
  const now = app.store.sidebar.sort?.[section] ?? "recent";
  app.run({ type: "set_sort", section, by: SORTS[(SORTS.indexOf(now) + 1) % SORTS.length] });
}

export const ACTIONS: Action[] = [
  { id: "new_chat", label: "New chat", keys: { k: "n", alt: true }, run: (app) => newChat(app) },
  {
    id: "new_session",
    label: "New session",
    when: (app) => !!app.store.selectedProject,
    run: (app) => app.setOverlay({ sheet: { title: "New session", items: newSessionItems(app, app.store.selectedProject) } }),
  },
  { id: "new_shell_tab", label: "New shell tab", keys: { k: "t", alt: true }, when: (app) => !!cur(app), run: (app) => app.run({ type: "new_shell_tab", session: cur(app)!.id, pane: panes(app)?.focused_pane || undefined }) },
  { id: "new_claude_tab", label: "New Claude tab", when: (app) => !!cur(app), run: (app) => app.run({ type: "new_claude_tab", session: cur(app)!.id }) },
  { id: "new_codex_tab", label: "New Codex tab", when: (app) => !!cur(app) && codexAvailable(app.store, cur(app)!.machine), run: (app) => app.run({ type: "new_claude_tab", session: cur(app)!.id, harness: "codex" }) },
  { id: "close_tab", label: "Close tab", when: (app) => !!curTab(app), run: (app) => app.run({ type: "close_tab", tab_id: curTab(app)!.id }) },
  { id: "close_session", label: "Close session", when: (app) => !!cur(app), run: (app) => app.run({ type: "close_session", session: cur(app)!.id }) },
  {
    id: "toggle_agent",
    label: (app) => `Toggle ${app.store.settings.agent_name || "Atlas"}`,
    keys: { k: "j" },
    when: (app) => !!app.store.homeSession,
    run: (app) => app.run({ type: "set_home", open: !app.store.homeOpen }),
  },
  { id: "notifications", label: "Notifications", run: (app) => app.setOverlay({ bell: true, palette: false }) },
  { id: "notifications_read", label: "Notifications: mark all read", run: (app) => app.run({ type: "notifications_mark_read", all: true }) },
  { id: "notifications_clear", label: "Notifications: clear", run: (app) => app.run({ type: "notifications_clear" }) },
  { id: "toggle_left", label: "Toggle left column", keys: { k: "b" }, when: (app) => !app.phone, run: (app) => app.run({ type: "set_layout", left_open: !app.store.layout.left_open }) },
  { id: "toggle_right", label: "Toggle right panels", keys: { k: "b", alt: true }, when: (app) => !app.phone, run: (app) => app.run({ type: "set_layout", right_open: !app.store.layout.right_open }) },
  { id: "show_jobs", label: "Show jobs", run: (app) => app.run({ type: "set_left_tab", tab: "jobs" }) },
  { id: "jobs_pause_all", label: "Pause all jobs", run: (app) => app.run({ type: "jobs_pause" }) },
  { id: "jobs_resume_all", label: "Resume all jobs", run: (app) => app.run({ type: "jobs_resume" }) },
  { id: "jobs_stop_all", label: "Stop all running jobs", run: (app) => app.run({ type: "job_stop" }) },
  { id: "look_graphite", label: "Look: Graphite", detail: (app) => current(app.store.settings.theme === "graphite"), run: (app) => app.run({ type: "set_theme", name: "graphite" }) },
  { id: "look_warm", label: "Look: Warm", detail: (app) => current(app.store.settings.theme === "warm"), run: (app) => app.run({ type: "set_theme", name: "warm" }) },
  { id: "look_ghostty", label: "Look: Ghostty", detail: (app) => current(app.store.settings.theme === "ghostty"), run: (app) => app.run({ type: "set_theme", name: "ghostty" }) },
  { id: "appearance_system", label: "Appearance: System", detail: (app) => current(app.store.settings.appearance === "system"), run: (app) => app.run({ type: "set_appearance", mode: "system" }) },
  { id: "appearance_light", label: "Appearance: Light", detail: (app) => current(app.store.settings.appearance === "light"), run: (app) => app.run({ type: "set_appearance", mode: "light" }) },
  { id: "appearance_dark", label: "Appearance: Dark", detail: (app) => current(app.store.settings.appearance === "dark"), run: (app) => app.run({ type: "set_appearance", mode: "dark" }) },
  { id: "reduce_motion", label: "Reduce motion", detail: (app) => onOff(!!app.store.settings.reduce_motion), run: (app) => app.run({ type: "set_reduce_motion", on: !app.store.settings.reduce_motion }) },
  { id: "dim_panes", label: "Dim unfocused panes", detail: (app) => onOff(!!app.store.settings.dim_panes), run: (app) => app.run({ type: "set_dim_panes", on: !app.store.settings.dim_panes }) },
  { id: "rescan", label: "Rescan sessions", run: (app) => app.run({ type: "rescan" }).then((r) => r.ok && app.toast("Rescanning sessions…")) },
  { id: "add_project", label: "Add project…", run: (app) => app.setOverlay({ sheet: { title: "Add project", body: "A folder on this machine, as a full path or ~/…", items: [{ label: "prompt:add_project" }] } }) },
  {
    id: "rename_project",
    label: "Rename project",
    when: (app) => !!app.store.project(app.store.selectedProject),
    run: (app) => {
      const p = app.store.project(app.store.selectedProject)!;
      app.setOverlay({ sheet: { title: "Rename project", body: p.name || "", items: [{ label: "prompt:rename_project:" + p.id }] } });
    },
  },
  { id: "filter", label: "Filter projects and sessions", keys: { k: "f", shift: true }, run: (app) => focusFilter(app) },
  { id: "clear_filter", label: "Clear filter", run: (app) => app.run({ type: "set_filter", text: "", running: false, waiting: false, pinned: false }) },
  { id: "quick_running", label: "Filter: running", detail: (app) => onOff(!!app.store.sidebar.only_running), run: (app) => app.run({ type: "set_filter", running: !app.store.sidebar.only_running }) },
  { id: "quick_waiting", label: "Filter: waiting for you", detail: (app) => onOff(!!app.store.sidebar.only_waiting), run: (app) => app.run({ type: "set_filter", waiting: !app.store.sidebar.only_waiting }) },
  { id: "quick_pinned", label: "Filter: pinned", detail: (app) => onOff(!!app.store.sidebar.only_pinned), run: (app) => app.run({ type: "set_filter", pinned: !app.store.sidebar.only_pinned }) },
  { id: "show_hidden", label: "Show hidden projects and sessions", detail: (app) => onOff(!!app.store.sidebar.show_hidden), run: (app) => app.run({ type: "set_filter", show_hidden: !app.store.sidebar.show_hidden }) },
  { id: "sort_projects", label: "Sort projects (next order)", detail: (app) => app.store.sidebar.sort?.projects ?? "", run: (app) => nextSort(app, "projects") },
  { id: "sort_sessions", label: "Sort sessions (next order)", detail: (app) => app.store.sidebar.sort?.sessions ?? "", run: (app) => nextSort(app, "sessions") },
  { id: "sort_chats", label: "Sort chats (next order)", detail: (app) => app.store.sidebar.sort?.chats ?? "", run: (app) => nextSort(app, "chats") },
  { id: "text_bigger", label: "Bigger terminal text", keys: { k: "=" }, run: (app) => setTermFont(termFontSize(app.phone) + 1) },
  { id: "text_smaller", label: "Smaller terminal text", keys: { k: "-" }, run: (app) => setTermFont(termFontSize(app.phone) - 1) },
  { id: "text_reset", label: "Actual terminal text size", keys: { k: "0" }, run: (app) => setTermFont(0) },
  { id: "split_right", label: "Split pane right", keys: { k: "d" }, when: (app) => !!panes(app)?.focused_pane, run: (app) => app.run({ type: "split_pane", pane: panes(app)!.focused_pane, direction: "right" }) },
  { id: "split_down", label: "Split pane down", keys: { k: "d", shift: true }, when: (app) => !!panes(app)?.focused_pane, run: (app) => app.run({ type: "split_pane", pane: panes(app)!.focused_pane, direction: "down" }) },
  { id: "close_pane", label: "Close pane (its tabs stay)", when: (app) => (panes(app)?.panes.length ?? 0) > 1, run: (app) => app.run({ type: "close_pane", pane: panes(app)!.focused_pane }) },
  { id: "equalize_panes", label: "Even out panes", when: (app) => (panes(app)?.panes.length ?? 0) > 1, run: (app) => app.run({ type: "equalize_panes", session: cur(app)!.id }) },
  {
    id: "zoom_pane",
    label: (app) => (panes(app)?.zoomed_pane ? "Restore panes" : "Zoom pane"),
    keys: { k: "enter", shift: true },
    when: (app) => (panes(app)?.panes.length ?? 0) > 1,
    run: (app) => app.run({ type: "zoom_pane", pane: panes(app)!.focused_pane }),
  },
  { id: "focus_pane_left", label: "Focus pane left", when: (app) => (panes(app)?.panes.length ?? 0) > 1, run: (app) => app.run({ type: "focus_pane", direction: "left" }) },
  { id: "focus_pane_right", label: "Focus pane right", when: (app) => (panes(app)?.panes.length ?? 0) > 1, run: (app) => app.run({ type: "focus_pane", direction: "right" }) },
  { id: "focus_pane_up", label: "Focus pane up", when: (app) => (panes(app)?.panes.length ?? 0) > 1, run: (app) => app.run({ type: "focus_pane", direction: "up" }) },
  { id: "focus_pane_down", label: "Focus pane down", when: (app) => (panes(app)?.panes.length ?? 0) > 1, run: (app) => app.run({ type: "focus_pane", direction: "down" }) },
  { id: "next_tab", label: "Next tab", keys: { k: "]", shift: true }, when: (app) => !!cur(app), run: (app) => tabStep(app, 1) },
  { id: "prev_tab", label: "Previous tab", keys: { k: "[", shift: true }, when: (app) => !!cur(app), run: (app) => tabStep(app, -1) },
  { id: "next_session", label: "Next session", keys: { k: "arrowdown", alt: true }, run: (app) => sessionStep(app, 1) },
  { id: "prev_session", label: "Previous session", keys: { k: "arrowup", alt: true }, run: (app) => sessionStep(app, -1) },
  {
    id: "next_needing_you",
    label: "Next needing you",
    keys: { k: "a", alt: true },
    run: (app) =>
      app.run({ type: "next_needing_you" }).then((r) => {
        if (r.ok) app.go({ screen: "session", session: app.store.currentSession });
      }),
  },
  { id: "prev_needing_you", label: "Previous needing you", run: (app) => app.run({ type: "next_needing_you", back: true }) },
  {
    id: "mark_unread",
    label: "Mark as unread",
    when: (app) => !!curTab(app),
    run: (app) => app.run({ type: "set_unread", tab_id: curTab(app)!.id, unread: true }),
  },
  { id: "mark_all_read", label: "Mark all sessions as read", run: (app) => app.run({ type: "mark_all_read" }) },
  { id: "show_deck", label: "Show the Deck", run: (app) => app.run({ type: "show_no_session" }).then(() => app.go({ screen: "deck" })) },
  { id: "unpair", label: "Unpair this browser", run: (app) => app.unpair() },
];

export function actionLabel(a: Action, app: App): string {
  return typeof a.label === "function" ? a.label(app) : a.label;
}

export function focusFilter(app: App) {
  if (app.store.layout.left_tab !== "sessions") app.run({ type: "set_left_tab", tab: "sessions" });
  if (!app.store.layout.left_open && !app.phone) app.run({ type: "set_layout", left_open: true });
  app.go({ screen: "home" });
  window.setTimeout(() => (document.getElementById("sidebar-filter") as HTMLInputElement | null)?.focus(), 60);
}

// The page's shortcuts: capture, before the terminal sees the key.
export function useShortcuts(app: App) {
  const latest = useRef(app);
  latest.current = app;
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      const a = latest.current;
      if (keysMatch({ k: "k" }, e)) {
        e.preventDefault();
        e.stopPropagation();
        a.setOverlay({ palette: !a.overlay.palette, bell: false, menu: null });
        return;
      }
      if (a.overlay.palette || a.overlay.sheet) return;
      for (const x of ACTIONS) {
        if (x.keys && keysMatch(x.keys, e) && (!x.when || x.when(a))) {
          e.preventDefault();
          e.stopPropagation();
          x.run(a);
          return;
        }
      }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, []);
}

// ---- the palette ----

interface Row {
  key: string;
  label: string;
  place?: string;
  detail?: string;
  keys?: string;
  icon?: preact.ComponentChildren;
  run: () => void;
}

export function Palette() {
  const app = useApp();
  const [q, setQ] = useState("");
  const [sel, setSel] = useState(0);
  const field = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  useEffect(() => field.current?.focus(), []);
  const close = () => app.setOverlay({ palette: false });

  const rows = useMemo(() => {
    const { store } = app;
    const query = q.trim().toLowerCase();
    const out: { r: Row; s: number; g: number }[] = [];
    // open sessions, then projects, then actions
    for (const id of store.web?.open ?? []) {
      const s = store.session(id);
      if (!s) continue;
      const w = store.web?.titles[String(id)];
      const label = w?.title || s.title;
      const place = w?.chat ? "Chats" : (w?.place ?? "");
      const sc = Math.max(score(label, query), score(place, query) * 0.8);
      if (sc <= 0) continue;
      const v = sessionView(store, s);
      out.push({
        g: 0,
        s: sc,
        r: {
          key: "s" + id,
          label,
          place,
          detail: v.dot === "waiting" ? "Waiting for you" : "",
          icon: <><StatusMark mark={v.mark} progress={v.progress} /><HarnessIcon harness={openHarness(store, s)} /></>,
          run: () => focusSession(app, id),
        },
      });
    }
    if (query) {
      for (const p of store.projects) {
        if (p.group !== "projects") continue;
        const label = p.name || p.cwd.split("/").filter(Boolean).pop() || p.label;
        const sc = Math.max(score(label, query), score(p.label, query) * 0.8);
        if (sc <= 0) continue;
        out.push({
          g: 1,
          s: sc,
          r: {
            key: "p" + p.id,
            label,
            place: p.machine ? store.machineName(p.machine) : "Project",
            icon: <Icon name="folder" size={14} />,
            run: () => {
              app.run({ type: "select_project", project_id: p.id });
              app.go({ screen: "home" });
              if (!store.layout.left_open) app.run({ type: "set_layout", left_open: true });
            },
          },
        });
      }
    }
    for (const a of ACTIONS) {
      if (a.when && !a.when(app)) continue;
      const label = actionLabel(a, app);
      const sc = score(label, query);
      if (sc <= 0) continue;
      out.push({ g: 2, s: sc, r: { key: "a" + a.id, label, detail: a.detail?.(app) ?? "", keys: a.keys ? keysLabel(a.keys) : "", run: () => a.run(app) } });
    }
    if (query) out.sort((a, b) => b.s - a.s || a.g - b.g);
    return out.map((x) => x.r);
  }, [q, app.store.web, app.store.currentSession]);

  useEffect(() => setSel(0), [q]);
  useEffect(() => {
    list.current?.querySelector(".pal-row.sel")?.scrollIntoView({ block: "nearest" });
  }, [sel]);

  const pick = (r: Row | undefined) => {
    if (!r) return;
    close();
    r.run();
  };

  return (
    <div class="scrim" onMouseDown={close}>
      <div class={"palette" + (app.phone ? " phone" : "")} role="dialog" aria-label="Search or run a command" onMouseDown={(e) => e.stopPropagation()}>
        <label class="pal-field">
          <Icon name="search" size={16} />
          <input
            ref={field}
            type="text"
            value={q}
            placeholder="Search or run a command…"
            spellcheck={false}
            autocomplete="off"
            autocapitalize="off"
            onInput={(e) => setQ((e.target as HTMLInputElement).value)}
            onKeyDown={(e) => {
              if (e.key === "ArrowDown") setSel((x) => Math.min(rows.length - 1, x + 1));
              else if (e.key === "ArrowUp") setSel((x) => Math.max(0, x - 1));
              else if (e.key === "Enter") pick(rows[sel]);
              else if (e.key === "Escape") close();
              else return;
              e.preventDefault();
            }}
          />
          <span class="keys">esc</span>
        </label>
        <div class="pal-list" ref={list} role="listbox">
          {rows.length === 0 ? <div class="pal-empty">Nothing matches</div> : null}
          {rows.map((r, i) => (
            <div class={"pal-row" + (i === sel ? " sel" : "")} role="option" aria-selected={i === sel ? "true" : "false"} key={r.key} onMouseMove={() => i !== sel && setSel(i)} onClick={() => pick(r)}>
              <span class="pal-icon">{r.icon ?? <Icon name="chevron-right" size={14} />}</span>
              {r.place ? <span class="place">{r.place} ·</span> : null}
              <span class="pal-label">{r.label}</span>
              <span class="spacer" />
              {r.detail ? <span class={"pal-detail" + (r.detail === "Waiting for you" ? " waiting" : "")}>{r.detail}</span> : null}
              {r.keys ? <span class="keys">{r.keys}</span> : null}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

export { newTabItems };
