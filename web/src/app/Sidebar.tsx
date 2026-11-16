// The left column (src/ui_sidebar.odin): Sessions | Files | Settings | Jobs, the filter and quick
// chips, then Open, Projects (a tree, the selected project's sessions under it) and Chats, and each
// other machine under its name. Rows and their order come from the core's "web" section
// (src/core/web_view.odin), so they match the window's exactly.

import { useEffect, useRef, useState } from "preact/hooks";
import type { OpenSession, Store, WebProjectRow, WebSessionRow } from "../state.ts";
import { sessionView, tabView, type Dot } from "../status.ts";
import { ago, keysLabel, menuAt, useApp, type App, type MenuItem, shownSession } from "./ctx.ts";
import { HarnessIcon, Icon, StatusMark, dotMark } from "./icons.tsx";
import { JobsPanel } from "./Jobs.tsx";
import { NotHere } from "./Bars.tsx";
import { fold } from "./fold.ts";
import { FilesPanel } from "./Files.tsx";
import { Windowed, type WItem } from "./Windowed.tsx";
import { infoItems, infoMenu, peekItem, renameItem } from "./SessionExtras.tsx";
import { peekProps } from "./Peek.tsx";

const SORTS = [
  ["recent", "Recent activity", "Sessions by recent activity"],
  ["name", "Name", "Sessions by name"],
  ["created", "Created", "Sessions by created"],
  ["attention", "Needs attention", "Sessions by attention"],
] as const;

export function openHarness(store: Store, s: OpenSession): "pi" | "claude" | "codex" {
  if (s.agent !== "claude") return "pi";
  const t = store.tabs(s.id)[0];
  return t?.kind?.claude_tab?.codex ? "codex" : "claude";
}

export function Sidebar({ width, onResize, forceSessions }: { width: number; onResize: (w: number, done: boolean) => void; forceSessions?: boolean }) {
  const app = useApp();
  const { store } = app;
  const tab = forceSessions ? "sessions" : String(store.layout.left_tab ?? "sessions");
  return (
    <aside class="sidebar">
      <div class="side-top">
        <IconButton icon="sidebar-left" label={`Hide the left column (${keysLabel({ k: "b" })})`} on run={() => app.run({ type: "set_layout", left_open: false })} />
        <IconButton icon="compose" label={`New chat (${keysLabel({ k: "n", alt: true })})`} run={() => newChat(app)} />
      </div>
      <div class="segmented left-tabs">
        {(["sessions", "files", "settings", "jobs"] as const).map((t) => (
          <button type="button" class={(t === "settings" ? app.route.screen === "settings" : t === tab && app.route.screen !== "settings") ? "on" : ""} onClick={() => (t === "settings" ? app.go({ screen: "settings" }) : (app.route.screen === "settings" && app.go({ screen: "home" }), app.run({ type: "set_left_tab", tab: t })))}>
            {t[0].toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>
      {tab === "jobs" ? <JobsPanel /> : tab === "files" ? <FilesPanel /> : tab === "settings" ? <NotHere what="settings" /> : <SessionsTab />}
      <Divider width={width} onResize={onResize} />
    </aside>
  );
}

function Divider({ width, onResize }: { width: number; onResize: (w: number, done: boolean) => void }) {
  const start = useRef<{ x: number; w: number } | null>(null);
  return (
    <div
      class="col-divider"
      onPointerDown={(e) => {
        start.current = { x: e.clientX, w: width };
        (e.target as HTMLElement).setPointerCapture(e.pointerId);
      }}
      onPointerMove={(e) => {
        if (start.current) onResize(Math.max(220, Math.min(560, start.current.w + e.clientX - start.current.x)), false);
      }}
      onPointerUp={(e) => {
        if (start.current) onResize(Math.max(220, Math.min(560, start.current.w + e.clientX - start.current.x)), true);
        start.current = null;
      }}
      onDblClick={() => onResize(300, true)}
    />
  );
}

export function IconButton(props: { icon: Parameters<typeof Icon>[0]["name"]; label: string; run: (e: MouseEvent) => void; on?: boolean; small?: boolean; badge?: number }) {
  return (
    <button type="button" class={"icon-btn" + (props.small ? " small" : "")} title={props.label} aria-label={props.label} onClick={(e) => { e.stopPropagation(); props.run(e as MouseEvent); }}>
      <Icon name={props.icon} size={props.small ? 14 : 16} />
      {props.badge ? <span class="badge">{props.badge}</span> : null}
    </button>
  );
}

export async function newChat(app: App) {
  const c = app.store.chatsEntry;
  if (!c) return;
  const r = await app.run({ type: "new_chat", project_id: c.id });
  if (r.ok && r.created_id) app.go({ screen: "session", session: r.created_id });
}

// ---- the Sessions tab ----

function SessionsTab() {
  const app = useApp();
  const { store } = app;
  const sb = store.sidebar;
  const web = store.web;
  const attention = sb.view === "attention";
  return (
    <div class="sessions-tab">
      <div class="view-switch segmented small">
        <button type="button" class={!attention ? "on" : ""} onClick={() => app.run({ type: "set_sidebar_view", view: "projects" })}>By project</button>
        <button type="button" class={attention ? "on" : ""} onClick={() => app.run({ type: "set_sidebar_view", view: "attention" })}>Needs you</button>
      </div>
      <FilterField />
      <div class="chips">
        <Chip label="Running" dot="running" on={!!sb.only_running} run={() => app.run({ type: "set_filter", running: !sb.only_running })} />
        <Chip label="Waiting" dot="waiting" on={!!sb.only_waiting} run={() => app.run({ type: "set_filter", waiting: !sb.only_waiting })} />
        <Chip label="Pinned" on={!!sb.only_pinned} run={() => app.run({ type: "set_filter", pinned: !sb.only_pinned })} />
      </div>
      {web && web.filtered > 0 && !attention ? (
        <button type="button" class="filtered-note" onClick={() => app.run({ type: "set_filter", text: "", running: false, waiting: false, pinned: false })}>
          {web.filtered} waiting (filtered)
        </button>
      ) : null}
      <div class="nav">{!web ? <p class="empty">Loading…</p> : attention ? <AttentionList /> : <TreeList />}</div>
    </div>
  );
}

function FilterField() {
  const app = useApp();
  const text = String(app.store.sidebar.filter ?? "");
  const [v, setV] = useState(text);
  const timer = useRef(0);
  const focused = useRef(false);
  useEffect(() => {
    if (!focused.current) setV(text);
  }, [text]);
  return (
    <label class="filter">
      <Icon name="search" size={14} />
      <input
        id="sidebar-filter"
        type="text"
        placeholder="Filter"
        value={v}
        spellcheck={false}
        autocomplete="off"
        onFocus={() => (focused.current = true)}
        onBlur={() => (focused.current = false)}
        onInput={(e) => {
          const t = (e.target as HTMLInputElement).value;
          setV(t);
          window.clearTimeout(timer.current);
          timer.current = window.setTimeout(() => app.run({ type: "set_filter", text: t }), 120);
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            setV("");
            app.run({ type: "set_filter", text: "" });
            (e.target as HTMLInputElement).blur();
          }
        }}
      />
      {v ? (
        <button type="button" class="icon-btn small" aria-label="Clear the filter" onClick={() => { setV(""); app.run({ type: "set_filter", text: "" }); }}>
          <Icon name="close" size={12} />
        </button>
      ) : (
        <span class="keys">{keysLabel({ k: "f", shift: true })}</span>
      )}
    </label>
  );
}

function Chip({ label, dot, on, run }: { label: string; dot?: "running" | "waiting"; on: boolean; run: () => void }) {
  return (
    <button type="button" class={"chip" + (on ? " on" : "")} aria-pressed={on ? "true" : "false"} onClick={run}>
      {dot ? <span class={"chip-dot " + dot} /> : null}
      {label}
    </button>
  );
}

function SectionHeader(props: { name: string; fold?: string; count?: number; sort?: string; plus?: { label: string; run: () => void } }) {
  const app = useApp();
  const folded = props.fold ? !!app.store.sidebar.folded?.[props.fold] : false;
  return (
    <div class="nav-header">
      <button type="button" class="nav-title" onClick={() => props.fold && app.run({ type: "set_sidebar_folded", section: props.fold, folded: !folded })}>
        <Icon name={folded ? "chevron-right" : "chevron-down"} size={12} class="fold" />
        {props.name}
        {props.count ? <span class="count">{props.count}</span> : null}
      </button>
      <span class="spacer" />
      {props.sort ? <IconButton small icon="sort" label="Sort" run={(e) => menuAt(app, e, sortItems(app, props.sort!))} /> : null}
      {props.plus ? <IconButton small icon="plus" label={props.plus.label} run={props.plus.run} /> : null}
    </div>
  );
}

function sortItems(app: App, section: string): MenuItem[] {
  const sb = app.store.sidebar;
  const now = sb.sort?.[section];
  return [
    ...SORTS.map(([by, label]) => ({ label, check: now === by, run: () => app.run({ type: "set_sort", section, by }) })),
    { sep: true },
    { label: "Show hidden", check: !!sb.show_hidden, run: () => app.run({ type: "set_filter", show_hidden: !sb.show_hidden }) },
  ];
}

// ---- By project ----

function TreeList() {
  const app = useApp();
  const { store } = app;
  const web = store.web!;
  const sb = store.sidebar;
  useFold();
  fold.seed(store);
  useEffect(() => fold.syncWatch(store, app.link));
  const multi = store.machines.length > 0 && !!store.settings.remote_machines;
  const hereFolded = multi && !!sb.folded?.this_mac;
  const openFolded = !!sb.folded?.open;
  const projFolded = !!sb.folded?.projects;
  const chatsFolded = !!sb.folded?.chats;
  const chats = store.chatsEntry;
  const tree = store.webTree;
  const localProjects = tree.length || store.projects.some((p) => p.group === "projects" && !p.machine);
  const rowH = app.phone ? 44 : 30;
  return (
    <>
      {multi ? <MachineHeader no={0} /> : null}
      {hereFolded ? (
        web.open.map((id) => store.session(id)).filter((s) => s && sessionView(store, s).dot === "waiting").map((s) => <OpenRow key={s!.id} s={s!} />)
      ) : (
        <>
          {web.open.length ? (
            <>
              <SectionHeader name="OPEN" fold="open" count={web.open.length} />
              {openFolded ? null : web.open.map((id) => store.session(id)).map((s) => (s ? <OpenRow key={s.id} s={s} /> : null))}
            </>
          ) : null}
          <SectionHeader name="PROJECTS" fold="projects" sort="projects" plus={{ label: "Add project…", run: () => addProject(app) }} />
          {projFolded ? null : !localProjects ? (
            <Empty title="No projects yet" text="+ adds a folder" />
          ) : tree.length === 0 ? (
            <Empty title="No matching projects" text="Clear the filter to see them all" />
          ) : (
            <Windowed items={treeItems(app, tree, rowH)} />
          )}
          <div class="section-gap" />
          <SectionHeader name="CHATS" fold="chats" sort="chats" plus={{ label: `New chat (${keysLabel({ k: "n", alt: true })})`, run: () => newChat(app) }} />
          {chatsFolded || !chats ? null : <Windowed items={chatItems(app, chats.id, rowH)} />}
        </>
      )}
      {store.machines.map((m) => (
        <MachineSection key={m.no} no={m.no} />
      ))}
    </>
  );
}

const DIVIDER_H = 13;

// The Projects tree as the list draws it: the rows the page has not folded away, a project's
// sessions under it when open, the pinned line.
function treeItems(app: App, tree: WebProjectRow[], rowH: number): WItem[] {
  const { store } = app;
  const out: WItem[] = [];
  const marks = projectMarks(store);
  let hideBelow = Infinity;
  let lastTop: WebProjectRow | null = null;
  for (const r of tree) {
    if (r.depth > hideBelow) continue;
    hideBelow = Infinity;
    if (r.depth === 0) {
      if (lastTop && lastTop.pin >= 0 && r.pin < 0) out.push({ key: "div:" + r.key, h: DIVIDER_H, draw: () => <div class="pinned-divider" /> });
      lastTop = r;
    }
    const kidsOpen = r.kids > 0 && (r.forced || fold.kids.has(r.key));
    if (r.kids > 0 && !kidsOpen) hideBelow = r.depth;
    if (!r.id) {
      out.push({ key: r.key, h: rowH, draw: () => <GroupRow r={r} open={kidsOpen} /> });
      continue;
    }
    const open = fold.open.has(r.key);
    out.push({ key: r.key, h: rowH, draw: () => <ProjectRow r={r} expanded={open} kidsOpen={kidsOpen} mark={marks.get(r.id)} onToggle={() => fold.toggleOpen(r.key)} /> });
    if (open) projectSessionItems(app, r.id, r.key, r.depth + 1, rowH, out);
  }
  return out;
}

// A project's session rows under it: the first few, "Show N more", "New session"; "Loading…"
// until the core lists them (the first time the page opens it).
const TREE_SHOW = 8;
function projectSessionItems(app: App, pid: number, key: string, depth: number, rowH: number, out: WItem[]) {
  const rows = app.store.webSessions(pid);
  if (!rows) {
    out.push({ key: "load:" + key, h: rowH, draw: () => <div class="row action-row muted-text" style={{ paddingLeft: 8 + depth * 20 + "px" }}><span class="title">Loading…</span></div> });
    return;
  }
  const all = fold.all.has(key);
  const shown = all ? rows : rows.slice(0, TREE_SHOW);
  shown.forEach((r, i) => {
    if (i > 0 && shown[i - 1].pin >= 0 && r.pin < 0) out.push({ key: `sdiv:${key}`, h: DIVIDER_H, draw: () => <div class="pinned-divider" /> });
    out.push({ key: `s:${key}:${r.id}`, h: rowH, draw: () => <SessionRow r={r} projectId={pid} depth={depth} /> });
  });
  if (rows.length > shown.length) out.push({ key: "more:" + key, h: rowH, draw: () => <ActionRow icon="more" label={`Show ${rows.length - shown.length} more`} depth={depth} run={() => fold.showAll(key)} /> });
  out.push({ key: "new:" + key, h: rowH, draw: () => <ActionRow icon="plus" label="New session" depth={depth} run={(e) => menuAt(app, e, newSessionItems(app, pid))} /> });
}

function chatItems(app: App, chatsId: number, rowH: number): WItem[] {
  const rows = app.store.webChats;
  const out: WItem[] = [];
  rows.forEach((r, i) => {
    if (i > 0 && rows[i - 1].pin >= 0 && r.pin < 0) out.push({ key: "cdiv", h: DIVIDER_H, draw: () => <div class="pinned-divider" /> });
    out.push({ key: "c:" + r.id, h: rowH, draw: () => <SessionRow r={r} projectId={chatsId} chat depth={0} /> });
  });
  out.push({ key: "c:new", h: rowH, draw: () => <ActionRow icon="plus" label="New chat" run={() => newChat(app)} depth={0} /> });
  return out;
}

// Each project's open sessions' strongest mark (once per render, not per row).
function projectMarks(store: Store): Map<number, { n: number; v: ReturnType<typeof sessionView> | null }> {
  const m = new Map<number, { n: number; v: ReturnType<typeof sessionView> | null }>();
  for (const s of store.openSessions) {
    if (s.home) continue;
    const v = sessionView(store, s);
    const e = m.get(s.project_id) ?? { n: 0, v: null };
    e.n++;
    if (!e.v || RANKS[v.dot] > RANKS[e.v.dot]) e.v = v;
    m.set(s.project_id, e);
  }
  return m;
}

// Re-renders on a fold (the page's own: at once, no round trip).
function useFold() {
  const [, set] = useState(0);
  useEffect(() => fold.subscribe(() => set((x) => x + 1)), []);
}

function Empty({ title, text }: { title: string; text: string }) {
  return (
    <div class="empty-state">
      <div>{title}</div>
      <div class="muted small">{text}</div>
    </div>
  );
}

function addProject(app: App) {
  app.setOverlay({
    sheet: {
      title: "Add project",
      body: "A folder on this machine, as a full path or ~/…",
      items: [{ label: "prompt:add_project" }],
    },
  });
}

// An open session's row: [project ·] harness, title; its age or "Waiting for you"; its mark.
export function OpenRow({ s, from, mach, peek }: { s: OpenSession; from?: number; mach?: string; peek?: boolean }) {
  const app = useApp();
  const { store } = app;
  const w = store.webTitle(s.id);
  const fromTab = from ? store.tabs(s.id).find((t) => t.id === from) : undefined;
  const v = fromTab ? tabView(fromTab) : sessionView(store, s);
  const current = shownSession(app) === s.id;
  const age = v.dot !== "none" && v.dot !== "exited" ? ago(v.since) : "";
  let when = age || (w ? (w.at ? ago(w.at) : "new") : "");
  if (v.dot === "waiting") when = v.msg || "Waiting for you";
  const elsewhere = current && !w?.chat && s.project_id !== store.selectedProject;
  return (
    <div
      class={"row open-row" + (current ? " current" : "")}
      role="button"
      tabIndex={0}
      {...(peek ? peekProps(app, s.id, from) : {})}
      onClick={() => focusSession(app, s.id, from)}
      onContextMenu={(e) => {
        e.preventDefault();
        menuAt(app, e, sessionItems(app, s));
      }}
    >
      <Icon name={w?.chat ? "chat" : "folder"} size={14} class={elsewhere ? "accent" : "muted"} />
      {!w?.chat ? <span class={"place" + (elsewhere ? " accent" : "")}>{(w?.place ?? "") + " ·"}</span> : null}
      <HarnessIcon harness={openHarness(store, s)} />
      <span class="title">{w?.title ?? s.title}</span>
      <span class="spacer" />
      {mach ? <span class="mach">{mach}</span> : null}
      <span class={"when" + (v.dot === "waiting" ? " waiting" : "")}>{when}</span>
      <StatusMark mark={v.mark} progress={v.progress} />
      <span class="row-btns">
        <IconButton small icon="more" label="More" run={(e) => menuAt(app, e, sessionItems(app, s))} />
        <IconButton small icon="close" label="Close session" run={() => app.run({ type: "close_session", session: s.id })} />
      </span>
    </div>
  );
}

export function focusSession(app: App, id: number, tab?: number) {
  app.wish("session", id);
  app.run({ type: "focus_session", session: id }).then(() => {
    if (tab) app.run({ type: "focus_tab", tab_id: tab });
  });
  app.go({ screen: "session", session: id });
}

export function sessionItems(app: App, s: OpenSession): MenuItem[] {
  const { store } = app;
  const pin = (store.sidebar.pinned_sessions ?? []).indexOf(s.pi_session_id);
  const hidden = (store.sidebar.hidden_sessions ?? []).includes(s.pi_session_id);
  const items: MenuItem[] = [];
  if (!s.machine) {
    items.push({ label: pin >= 0 ? "Unpin" : "Pin", run: () => app.run({ type: "set_pinned", pi_session_id: s.pi_session_id, pinned: pin < 0 }) });
    items.push({ label: "New shell tab here", run: () => app.run({ type: "new_shell_tab", session: s.id }) });
    items.push({ label: "New Claude tab here", run: () => app.run({ type: "new_claude_tab", session: s.id }) });
    items.push({ sep: true });
    if (s.agent === "claude") items.push(renameItem(app, s.pi_session_id, store.webTitle(s.id)?.title ?? s.title));
    items.push(...infoItems(app, s.project_id, s.pi_session_id));
    items.push({ sep: true });
  }
  items.push(...peekItem(app, s.id));
  items.push({ label: "Mark as unread", run: () => app.run({ type: "set_unread", pi_session_id: s.pi_session_id, unread: true }) });
  if (!s.machine) items.push({ label: hidden ? "Show again" : "Hide", run: () => app.run({ type: "set_hidden", pi_session_id: s.pi_session_id, hidden: !hidden }) });
  items.push({ label: "Close session", run: () => app.run({ type: "close_session", session: s.id }) });
  return items;
}

function ProjectRow({ r, expanded, kidsOpen, mark, onToggle, remote }: { r: WebProjectRow; expanded: boolean; kidsOpen: boolean; mark?: { n: number; v: ReturnType<typeof sessionView> | null }; onToggle: () => void; remote?: boolean }) {
  const app = useApp();
  const { store } = app;
  const p = store.project(r.id);
  if (!p) return null;
  const cs = store.session(shownSession(app));
  const current = !!cs && cs.project_id === p.id && !expanded && !store.webTitle(cs.id)?.chat;
  const n = mark?.n ?? 0;
  return (
    <div
      class={"row project-row" + (current ? " current" : "") + (r.hidden || p.missing ? " dim" : "")}
      style={{ paddingLeft: 8 + r.depth * 20 + "px" }}
      role="button"
      tabIndex={0}
      aria-expanded={expanded ? "true" : "false"}
      onClick={onToggle}
      onContextMenu={(e) => {
        e.preventDefault();
        if (!remote) menuAt(app, e, projectItems(app, p.id));
      }}
    >
      <Icon name={expanded ? "chevron-down" : "chevron-right"} size={12} class="chev" />
      <Icon name="folder" size={14} class={expanded ? "secondary" : "muted"} />
      <span class={"title" + (expanded ? " bold" : "")}>{r.name}</span>
      <span class="spacer" />
      {r.kids > 0 ? (
        <button
          type="button"
          class="kids"
          onClick={(e) => {
            e.stopPropagation();
            if (!r.forced) fold.toggleKids(r.key);
          }}
        >
          <Icon name={kidsOpen ? "chevron-down" : "chevron-right"} size={12} />
          {r.kids} folder{r.kids === 1 ? "" : "s"}
        </button>
      ) : null}
      <span class="when">{r.hidden ? "hidden" : n ? String(n) : ""}</span>
      {mark?.v && (n || mark.v.dot !== "none") ? <StatusMark mark={mark.v.mark} progress={mark.v.progress} /> : null}
      {!remote ? (
        <span class="row-btns">
          <button type="button" class="icon-btn small star" title={r.pin >= 0 ? "Unpin" : "Pin"} onClick={(e) => { e.stopPropagation(); app.run({ type: "set_pinned", project_id: p.id, pinned: r.pin < 0 }); }}>
            {r.pin >= 0 ? "★" : "☆"}
          </button>
          <IconButton small icon="plus" label="New session" run={(e) => menuAt(app, e, newSessionItems(app, p.id))} />
          <IconButton small icon="more" label="More" run={(e) => menuAt(app, e, projectItems(app, p.id))} />
        </span>
      ) : null}
    </div>
  );
}

const RANKS: Record<Dot, number> = { none: 0, exited: 1, working: 2, question: 3, unseen: 4, error: 5, waiting: 6 };

function GroupRow({ r, open }: { r: WebProjectRow; open: boolean }) {
  return (
    <div class="row group-row" style={{ paddingLeft: 8 + r.depth * 20 + "px" }} role="button" tabIndex={0} aria-expanded={open ? "true" : "false"} onClick={() => !r.forced && fold.toggleKids(r.key)}>
      <Icon name={open ? "chevron-down" : "chevron-right"} size={12} class="chev" />
      <Icon name="folder" size={14} class="muted" />
      <span class="title muted-text">{r.name}</span>
      <span class="spacer" />
      <span class="when">{r.kids}</span>
    </div>
  );
}

export function newSessionItems(app: App, projectId: number): MenuItem[] {
  const p = app.store.project(projectId);
  const chats = p?.group === "chats";
  const go = async (cmd: object) => {
    const r = await app.run(cmd);
    if (r.ok && r.created_id) app.go({ screen: "session", session: r.created_id });
  };
  const items: MenuItem[] = [{ label: "pi", run: () => go({ type: "new_chat", project_id: projectId }) }];
  if (!chats) {
    items.push({ label: "Claude Code", run: () => go({ type: "new_claude_session", project_id: projectId }) });
    if (codexAvailable(app.store, p?.machine ?? 0)) items.push({ label: "Codex", run: () => go({ type: "new_claude_session", project_id: projectId, harness: "codex" }) });
  }
  return items;
}

const FOUND = new Set(["ok", "too_old", "unchecked"]);
export function codexAvailable(store: Store, machine: number): boolean {
  const has = (list: any[] | undefined) => (list ?? []).some((c) => c.id === "codex" && FOUND.has(c.state));
  if (!machine) return has(store.live.checklist);
  const m: any = store.machines.find((x) => x.no === machine);
  return !!m?.codex && has(m.checklist);
}

function projectItems(app: App, id: number): MenuItem[] {
  const { store } = app;
  const p = store.project(id)!;
  const pin = (store.sidebar.pinned_projects ?? []).indexOf(p.cwd);
  const hidden = (store.sidebar.hidden_projects ?? []).includes(p.cwd);
  const now = store.sidebar.sort?.sessions;
  return [
    { label: pin >= 0 ? "Unpin" : "Pin", run: () => app.run({ type: "set_pinned", project_id: id, pinned: pin < 0 }) },
    { label: "New session", run: () => app.setOverlay({ menu: null, sheet: { title: "New session in " + (p.name || p.label), items: newSessionItems(app, id) } }) },
    { label: "New Claude tab", run: () => app.run({ type: "new_claude_tab", project_id: id }) },
    { label: "Rename…", run: () => app.setOverlay({ sheet: { title: "Rename project", body: p.name || "", items: [{ label: "prompt:rename_project:" + id }] } }) },
    { sep: true },
    ...SORTS.map(([by, , label]) => ({ label, check: now === by, run: () => app.run({ type: "set_sort", section: "sessions", by }) })),
    { sep: true },
    { label: "Copy path", run: () => app.setOverlay({ copy: p.cwd }) },
    { sep: true },
    { label: hidden ? "Show again" : "Hide", run: () => app.run({ type: "set_hidden", project_id: id, hidden: !hidden }) },
  ];
}

const opening = new Set<string>(); // sessions the page asked to open, not open yet

function SessionRow({ r, projectId, chat, depth }: { r: WebSessionRow; projectId: number; chat?: boolean; depth: number }) {
  const app = useApp();
  const { store } = app;
  const open = r.open ? store.session(r.open) : undefined;
  const v = open ? sessionView(store, open) : null;
  const dot = (v?.dot ?? r.dot) as Dot;
  const mark = v?.mark ?? dotMark(dot);
  const current = (!!open && open.id === shownSession(app)) || opening.has(r.id);
  const when = dot === "waiting" ? "Waiting for you" : r.hidden ? "hidden" : ago(r.modified) || "new";
  const marked = !!open || dot !== "none";
  const harness = r.codex ? "codex" : r.claude ? "claude" : "pi";
  return (
    <div
      class={"row session-row" + (current ? " current" : "") + (r.hidden ? " dim" : "")}
      style={{ paddingLeft: 8 + depth * 20 + "px" }}
      role="button"
      tabIndex={0}
      onClick={async () => {
        if (open) return focusSession(app, open.id);
        // drawn as the current row at once; the core opens it
        opening.add(r.id);
        app.wish("opening", r.id);
        const res = await app.run({ type: "open_session", project_id: projectId, pi_session_id: r.id });
        opening.delete(r.id);
        if (res.ok) {
          const s = store.openSessions.find((x) => x.pi_session_id === r.id);
          if (s) app.go({ screen: "session", session: s.id });
        }
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        menuAt(app, e, sessionRowItems(app, r, projectId, open));
      }}
    >
      <HarnessIcon harness={harness} />
      <span class="title">{r.label}</span>
      <span class="spacer" />
      <span class={"when" + (dot === "waiting" ? " waiting" : "")}>{when}</span>
      {marked ? <StatusMark mark={mark} progress={v?.progress} /> : null}
      <span class="row-btns">
        <button type="button" class="icon-btn small star" title={r.pin >= 0 ? "Unpin" : "Pin"} onClick={(e) => { e.stopPropagation(); app.run({ type: "set_pinned", pi_session_id: r.id, pinned: r.pin < 0 }); }}>
          {r.pin >= 0 ? "★" : "☆"}
        </button>
        <IconButton small icon="info" label="Session info" run={(e) => infoMenu(app, e, projectId, r.id)} />
        <IconButton small icon="more" label="More" run={(e) => menuAt(app, e, sessionRowItems(app, r, projectId, open))} />
        {open ? <IconButton small icon="close" label="Close session" run={() => app.run({ type: "close_session", session: open.id })} /> : null}
      </span>
      {chat ? null : null}
    </div>
  );
}

function sessionRowItems(app: App, r: WebSessionRow, projectId: number, open?: OpenSession): MenuItem[] {
  const items: MenuItem[] = [
    { label: r.pin >= 0 ? "Unpin" : "Pin", run: () => app.run({ type: "set_pinned", pi_session_id: r.id, pinned: r.pin < 0 }) },
  ];
  if (open) items.push({ label: "New Claude tab here", run: () => app.run({ type: "new_claude_tab", session: open.id }) });
  items.push({ sep: true });
  if (r.claude) items.push(renameItem(app, r.id, r.label));
  items.push(...infoItems(app, projectId, r.id));
  items.push({ sep: true });
  if (open) items.push(...peekItem(app, open.id));
  if (open) items.push({ label: "Mark as unread", run: () => app.run({ type: "set_unread", pi_session_id: r.id, unread: true }) });
  items.push({ label: r.hidden ? "Show again" : "Hide", run: () => app.run({ type: "set_hidden", pi_session_id: r.id, hidden: !r.hidden }) });
  if (open) items.push({ label: "Close session", run: () => app.run({ type: "close_session", session: open.id }) });
  return items;
}

function ActionRow({ icon, label, run, depth }: { icon: "plus" | "more"; label: string; run: (e: MouseEvent) => void; depth: number }) {
  return (
    <div class="row action-row" style={{ paddingLeft: 8 + depth * 20 + "px" }} role="button" tabIndex={0} onClick={(e) => run(e as unknown as MouseEvent)}>
      <Icon name={icon} size={14} />
      <span class="title">{label}</span>
    </div>
  );
}

// ---- machines ----

const MACHINE_WORDS: Record<string, string> = {
  connecting: "connecting…",
  online: "",
  offline: "offline",
  needs_login: "needs login",
  needs_update: "needs an update",
  not_installed: "not installed",
  taken: "viewed there",
  refused: "does not allow connections",
  unsupported: "not supported",
};

function MachineHeader({ no }: { no: number }) {
  const app = useApp();
  const { store } = app;
  useFold();
  const m = no ? store.machines.find((x) => x.no === no) : null;
  const folded = no ? fold.machines.has(no) : !!store.sidebar.folded?.this_mac;
  const status = m ? m.status : "online";
  const act = m && (status === "taken" ? "Take back" : status !== "online" && status !== "connecting" ? "Connect" : "");
  // the window's words: this machine's name, "this Mac" beside it (src/ui_sidebar.odin machine_header)
  const here = store.web?.here;
  const label = no ? m!.name : here?.name || "This machine";
  const n = no ? (store.webMachines.find((x) => x.no === no)?.open.length ?? 0) : 0;
  return (
    <div class="machine-header">
      <button
        type="button"
        class="nav-title"
        onClick={() => {
          if (!no) app.run({ type: "set_sidebar_folded", section: "this_mac", folded: !folded });
          else fold.toggleMachine(no);
        }}
      >
        <Icon name={folded ? "chevron-right" : "chevron-down"} size={12} class="fold" />
        <span class={"machine-dot " + (status === "online" ? "on" : status === "connecting" ? "wait" : "off")} />
        <span class="machine-name">{label}</span>
        {!no && here?.label ? <span class="count">{here.label}</span> : MACHINE_WORDS[status] ? <span class="count">{MACHINE_WORDS[status]}</span> : n ? <span class="count">{n}</span> : null}
      </button>
      <span class="spacer" />
      {act ? (
        <button type="button" class="link-btn" onClick={() => app.run({ type: "machine_connect", no })}>
          {act}
        </button>
      ) : null}
    </div>
  );
}

// Another machine: its open sessions and projects. A project's sessions live on that machine, so
// opening one selects it (the core asks that machine); the fold is still the page's.
function MachineSection({ no }: { no: number }) {
  const app = useApp();
  const { store } = app;
  useFold();
  const mv = store.webMachines.find((x) => x.no === no);
  const m = store.machines.find((x) => x.no === no);
  if (!m) return null;
  const rowH = app.phone ? 44 : 30;
  const marks = projectMarks(store);
  return (
    <>
      <MachineHeader no={no} />
      {fold.machines.has(no) || !mv ? null : (
        <>
          {mv.open.map((id) => store.session(id)).map((s) => (s ? <OpenRow key={s.id} s={s} /> : null))}
          {mv.projects.map((x) => {
            const key = String(x.id);
            const r: WebProjectRow = { key, id: x.id, name: x.name, path: "", depth: x.depth, kids: 0, forced: false, pin: -1, hidden: false };
            const open = fold.open.has(key);
            const items: WItem[] = [];
            if (open && store.selectedProject === x.id) projectSessionItems(app, x.id, key, x.depth + 1, rowH, items);
            return (
              <>
                <ProjectRow
                  key={key}
                  r={r}
                  remote
                  expanded={open}
                  kidsOpen={false}
                  mark={marks.get(x.id)}
                  onToggle={() => {
                    if (!open && store.selectedProject !== x.id) app.run({ type: "select_project", project_id: x.id });
                    fold.toggleOpen(key);
                  }}
                />
                {items.map((it) => (
                  <div key={it.key} class="w-item" style={{ height: it.h + "px" }}>{it.draw()}</div>
                ))}
              </>
            );
          })}
          {m.error && m.status !== "online" ? <p class="note small">{m.error}</p> : null}
        </>
      )}
    </>
  );
}

// ---- the Attention view ----

const GROUP_TITLE = { needs_you: "Needs you", finished: "Finished", working: "Working", idle: "Idle" } as const;

function AttentionList() {
  const app = useApp();
  const { store } = app;
  const rows = store.web!.attention;
  if (!rows.length) return <Empty title="Nothing open" text="Open a session from a project" />;
  const out = [];
  let last = "";
  for (const r of rows) {
    const s = store.session(r.session);
    if (!s) continue;
    if (r.group !== last) {
      last = r.group;
      out.push(<div class="nav-header"><span class="nav-title static">{GROUP_TITLE[r.group].toUpperCase()}</span></div>);
    }
    out.push(<OpenRow s={s} from={r.tab || undefined} mach={s.machine ? store.machineName(s.machine) : ""} peek />);
  }
  return <>{out}</>;
}
