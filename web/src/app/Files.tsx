// The Files tab (the left column) and the session's editor and Markdown tabs in a browser.
// The tree is the session's folder (else the selected project's), listed with list_dir (inside a
// project, git status codes, .git and ignored left out; asked again every few seconds with the
// listing's hash, so an unchanged folder sends nothing; not while the page is hidden), folders
// opened in the page itself. One row has focus (sel); the keys move it (arrows, Home, End), Enter
// opens a file (show_file: a Markdown tab for .md, an editor tab otherwise; credentials and binaries
// refused) or opens and closes a folder, F2 renames, Delete or ⌘⌫ moves to the Trash (delete_path:
// the confirmation bar asks), Esc clears it. Several rows can be picked (pick): ⌘/Ctrl-click,
// shift-click, shift-arrows, ⌘/Ctrl-A in the tree; on a phone, Select in a row's sheet (taps then
// pick, a bar acts on them). Delete then trashes them all with one confirmation (delete_path paths);
// typing a name's first letters goes to it. Right-click, the row's "…" or a long press (a phone:
// a sheet) shows its menu. New file, New folder and Rename are typed in the tree, where the name
// goes (filetree.ts); the core refuses what it refuses, shown under the field. The active file tab
// is shown (its folders opened). The tabs read and save the file with file_read / file_save
// (src/core/web_files.odin): line numbers, editing, ⌘S, a file changed on disk is followed when
// nothing is edited and asked about when it is. Markdown renders with markdown.ts (no raw HTML).

import type { ComponentChildren } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { OpenSession, Tab } from "../state.ts";
import { IS_MAC, shownSession, useApp, type App, type MenuItem } from "./ctx.ts";
import { Icon } from "./icons.tsx";
import { parseMarkdown, safeHref, type Block, type Inline } from "./markdown.ts";
import { Windowed, type WItem } from "./Windowed.tsx";
import { FileReads, knowFile, knownFile } from "./filecache.ts";
import { CodeBlock, CodeEdit } from "./Code.tsx";
import { longPressProps } from "./Peek.tsx";
import { fileTabPath } from "./Panes.tsx";
import { clickPick, entryPaths, extendPick, gitLetter, gitTone, isEditRow, moveSel, newTarget, outermost, parentOf, parentsOf, pickOne, prunePick, relPath, rowKey, stemEnd, TRASH_MAX, treeRows, typeMatch, typed, type Edit, type Listing, type Pick, type Row } from "./filetree.ts";

// A result's data: the link gives it parsed (an object) or as text.
const json = (d: unknown): any => (typeof d === "string" ? JSON.parse(d) : (d ?? {}));

// ---- the tree ----

const open = new Set<string>(); // folders opened (the page's own)
const listed = new Map<string, Listing>();
const asking = new Set<string>(); // folders being listed now
const again = new Set<string>(); // ... and to list once more when that answer comes
let bump = () => {};
let sel = ""; // the focused row's path (the keys act on it, or on the picked rows holding it)
let pick: Pick = pickOne(""); // the rows picked (shown selected); none: sel alone shows selected
let order: string[] = []; // the entry rows' paths as drawn
let picking = false; // a phone's selection mode: taps pick rows, a bar acts on them
let typeBuf = { text: "", at: 0 }; // type-to-select's letters
let edit: Edit | null = null; // the name field (new file or folder, rename)
let focusWanted = ""; // a row to focus once it is drawn
let scrollWanted: { key: string; center: boolean } | null = null; // a row to bring into view once listed

async function list(app: App, path: string) {
  if (asking.has(path)) return void again.add(path);
  asking.add(path);
  const had = listed.get(path);
  try {
    const r = await app.link.run({ type: "list_dir", path, ...(had?.hash && !had.err ? { since: had.hash } : {}) });
    if (r.ok) {
      const d = json(r.data);
      if (d.same) return; // unchanged since the last listing
      listed.set(path, { entries: d.entries ?? [], err: "", hash: d.hash });
    } else {
      if (had && r.error === "not connected") return;
      listed.set(path, { entries: [], err: r.error || "cannot list it" });
    }
    bump();
  } finally {
    asking.delete(path);
    if (again.delete(path)) list(app, path);
  }
}

function refresh(app: App, root: string) {
  if (!root) return;
  list(app, root);
  for (const d of open) if (d.startsWith(root + "/")) list(app, d);
}

function toggle(app: App, path: string) {
  if (open.has(path)) open.delete(path);
  else {
    open.add(path);
    list(app, path);
  }
  bump();
}


let opened = () => {}; // a phone: back from the Files view to the tab

function openFile(app: App, path: string, quiet = false) {
  (quiet ? app.link.run({ type: "show_file", path }) : app.run({ type: "show_file", path })).then((r) => r.ok && opened());
}

// Open to the side: the file's tab, then split right with it (split_pane moves that tab).
async function openSide(app: App, path: string) {
  const r = await app.run({ type: "show_file", path });
  if (r.ok && r.created_id) app.run({ type: "split_pane", direction: "right", tab_id: r.created_id });
}

function copyText(app: App, text: string) {
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(() => app.toast("Copied"), () => app.setOverlay({ copy: text }));
  else app.setOverlay({ copy: text }); // no async clipboard off a secure context: the copy sheet
}

// Delete: the core always asks (the confirmation bar); the tree looks again when it is answered.
function trash(app: App, path: string) {
  app.run({ type: "delete_path", path });
}

// Several rows: one delete_path with paths, one confirmation (the core checks every path first and
// refuses the lot naming the first it refuses). One row: path, as an older core knows it. An older
// core reads only path (empty here) and says so: never deleted one by one.
async function trashMany(app: App, paths: string[]) {
  if (paths.length === 1) return trash(app, paths[0]);
  if (!paths.length) return;
  if (paths.length > TRASH_MAX) return app.toast(`At most ${TRASH_MAX} items can go to the Trash at once`, true);
  const r = await app.link.run({ type: "delete_path", path: "", paths });
  if (r.ok || r.error === "needs_confirmation" || r.error === "not connected") return;
  if ((r.error ?? "").startsWith("path is empty")) app.toast("Deckhand on that machine is too old to move several items to the Trash at once. Update it, or move them one at a time.", true);
  else app.toast(r.error || "Could not move them to the Trash", true);
}

// The rows a command acts on: the picked rows when they hold the focused one, else that row.
function chosen(): string[] {
  return pick.paths.size > 1 && pick.paths.has(sel) ? order.filter((p) => pick.paths.has(p)) : sel ? [sel] : [];
}

function focusOne(path: string) {
  sel = path;
  pick = pickOne(path);
}

function startPicking(path: string) {
  picking = true;
  focusOne(path);
  bump();
}

function copyPaths(app: App, root: string, paths: string[], rel: boolean) {
  copyText(app, paths.map((p) => (rel ? relPath(root, p) : p)).join("\n"));
}

function startNew(app: App, root: string, dir: string, kind: "file" | "dir") {
  if (dir !== root && !open.has(dir)) {
    open.add(dir);
    list(app, dir);
  }
  edit = { kind, dir, err: "" };
  scrollWanted = { key: "new:" + dir, center: false };
  bump();
}

function startRename(path: string) {
  edit = { kind: "rename", path, err: "" };
  focusOne(path);
  scrollWanted = { key: path, center: false };
  bump();
}

function endEdit(back: string) {
  edit = null;
  if (back) focusWanted = back;
  bump();
}

// The name typed: created or renamed by the core (its rules: inside the project, never .git…);
// refused: the field stays, the reason under it.
async function commitEdit(app: App, root: string, text: string) {
  const e = edit;
  if (!e) return;
  const name = text.trim();
  if (e.kind === "rename") {
    const from = e.path;
    if (!name || name === from.slice(from.lastIndexOf("/") + 1)) return endEdit(from);
    const to = parentOf(from) + "/" + name;
    const r = await app.link.run({ type: "rename_path", from, to });
    if (edit !== e) return;
    if (!r.ok && r.error !== "needs_confirmation") {
      edit = { ...e, err: r.error || "Could not rename it" };
      return bump();
    }
    // what was open under it follows it
    for (const d of [...open]) if (d === from || d.startsWith(from + "/")) {
      open.delete(d);
      if (r.ok) open.add(to + d.slice(from.length));
    }
    for (const k of [...listed.keys()]) if (k === from || k.startsWith(from + "/")) listed.delete(k);
    const now = r.ok ? to : from;
    focusOne(now);
    scrollWanted = { key: now, center: false };
    endEdit(now);
    refresh(app, root);
    return;
  }
  if (!name) return endEdit(sel);
  const r = await app.link.run({ type: e.kind === "dir" ? "create_dir" : "create_file", path: e.dir + "/" + name });
  if (edit !== e) return;
  if (!r.ok && r.error !== "needs_confirmation") {
    edit = { ...e, err: r.error || "Could not create it" };
    return bump();
  }
  const made = e.dir + "/" + name; // as the tree names it (the core's answer is resolved: a symlinked root differs)
  for (const d of parentsOf(root, made)) open.add(d); // a/b/c.txt: its folders open
  focusOne(made);
  scrollWanted = { key: made, center: false };
  endEdit(made);
  refresh(app, root);
  if (r.ok && e.kind === "file") openFile(app, made, true); // its tab, quietly (no session on screen: none)
}

function rowItems(app: App, root: string, path: string, dir: boolean): MenuItem[] {
  const keys = (k: string) => (app.phone ? undefined : k);
  const items: MenuItem[] = [];
  const many = chosen();
  if (many.length > 1) {
    // several rows: what acts on them all (no open, rename or new here)
    const out = outermost(order, new Set(many));
    items.push({ label: out.length > 1 ? `Move ${out.length} items to Trash` : "Move to Trash", keys: keys(IS_MAC ? "⌘⌫" : "Delete"), danger: true, run: () => trashMany(app, out) });
    items.push({ sep: true });
    items.push({ label: "Copy paths", run: () => copyPaths(app, root, many, false) });
    items.push({ label: "Copy relative paths", run: () => copyPaths(app, root, many, true) });
    return items;
  }
  if (app.phone) items.push({ label: "Select", run: () => startPicking(path) });
  if (dir) items.push({ label: open.has(path) ? "Collapse" : "Expand", keys: keys("↩"), run: () => toggle(app, path) });
  else {
    items.push({ label: "Open", keys: keys("↩"), run: () => openFile(app, path) });
    if (!app.phone) items.push({ label: "Open to the side", run: () => openSide(app, path) });
  }
  items.push({ sep: true });
  const into = dir ? path : parentOf(path);
  items.push({ label: "New file…", run: () => startNew(app, root, into, "file") });
  items.push({ label: "New folder…", run: () => startNew(app, root, into, "dir") });
  items.push({ sep: true });
  items.push({ label: "Rename…", keys: keys("F2"), run: () => startRename(path) });
  items.push({ label: "Move to Trash", keys: keys(IS_MAC ? "⌘⌫" : "Delete"), danger: true, run: () => trash(app, path) });
  items.push({ sep: true });
  items.push({ label: "Copy path", run: () => copyText(app, path) });
  items.push({ label: "Copy relative path", run: () => copyText(app, relPath(root, path)) });
  return items;
}

function rootItems(app: App, root: string): MenuItem[] {
  return [
    { label: "New file…", run: () => startNew(app, root, root, "file") },
    { label: "New folder…", run: () => startNew(app, root, root, "dir") },
    { sep: true },
    { label: "Collapse all", run: () => collapseAll(root) },
    { label: "Refresh", run: () => refresh(app, root) },
    { sep: true },
    { label: "Copy path", run: () => copyText(app, root) },
  ];
}

function collapseAll(root: string) {
  for (const d of [...open]) if (d.startsWith(root + "/")) open.delete(d);
  bump();
}

// A menu at the pointer on a desktop; a bottom sheet titled with the name on a phone.
function showMenu(app: App, title: string, items: MenuItem[], at: { clientX: number; clientY: number }) {
  if (app.phone) app.setOverlay({ menu: null, sheet: { title, items } });
  else app.setOverlay({ menu: { items, x: at.clientX, y: at.clientY } });
}

export function FilesPanel({ onOpen }: { onOpen?: () => void } = {}) {
  const app = useApp();
  opened = onOpen ?? (() => {});
  const { store } = app;
  const [, set] = useState(0);
  bump = () => set((x) => x + 1);
  const nav = useRef<HTMLDivElement>(null);
  const s = store.session(shownSession(app));
  const p = store.project(store.selectedProject);
  const root = s && !s.home && !s.machine ? s.cwd : p && !p.machine ? p.cwd : "";
  // listed when shown, and again every few seconds while it shows and the page is seen (the files
  // change; an unchanged folder answers "same")
  useEffect(() => {
    if (!root) return;
    const under = (x: string) => x === root || x.startsWith(root + "/");
    if (edit && !under(edit.kind === "rename" ? edit.path : edit.dir)) edit = null;
    refresh(app, root);
    picking = false;
    const t = window.setInterval(() => !document.hidden && refresh(app, root), 5000);
    const seen = () => !document.hidden && refresh(app, root);
    document.addEventListener("visibilitychange", seen);
    return () => {
      window.clearInterval(t);
      document.removeEventListener("visibilitychange", seen);
    };
  }, [root]);
  // a confirmation answered (a delete): look again, now and once it has run
  const asks = store.confirmations.length;
  const hadAsks = useRef(asks);
  useEffect(() => {
    if (asks < hadAsks.current) {
      refresh(app, root);
      const t = window.setTimeout(() => refresh(app, root), 800);
      hadAsks.current = asks;
      return () => window.clearTimeout(t);
    }
    hadAsks.current = asks;
  }, [asks]);
  // the active file tab: its folders opened, its row selected and brought into view
  const at = s ? store.tabs(s.id).find((t) => t.id === s.active_tab) : undefined;
  const active = at ? fileTabPath(at) : "";
  useEffect(() => {
    if (!root || !active.startsWith(root + "/")) return;
    for (const d of parentsOf(root, active)) if (!open.has(d)) {
      open.add(d);
      list(app, d);
    }
    // the keys act on the focused row: while focus is in the tree the selection stays where it is
    if (!nav.current?.contains(document.activeElement) && !picking) {
      focusOne(active);
      scrollWanted = { key: active, center: true };
    }
    bump();
  }, [active, root]);

  const rowH = app.phone ? 44 : 26;
  const rows = root ? treeRows(root, listed, open, edit) : [];
  // the picked rows still drawn (listed again: what went drops out; a closed folder's rows too)
  order = entryPaths(rows);
  pick = prunePick(order, pick);
  // a row wanted in view: scrolled to once it is listed (the windowed list then draws it)
  useLayoutEffect(() => {
    const el = nav.current;
    if (!scrollWanted || !el) return;
    const i = rows.findIndex((r) => rowKey(r) === scrollWanted!.key);
    if (i < 0) return;
    const top = i * rowH;
    if (top < el.scrollTop || top + rowH > el.scrollTop + el.clientHeight) el.scrollTop = scrollWanted.center ? top - (el.clientHeight - rowH) / 2 : top < el.scrollTop ? top : top + rowH - el.clientHeight;
    scrollWanted = null;
  });

  if (!root) return <div class="files"><div class="empty-state"><div>No folder</div><div class="muted small">Open a session of this machine</div></div></div>;

  const selRow = rows.find((r) => r.t === "entry" && r.path === sel);
  // the focus to path: it alone picked, or (keep) the picking already done
  const go = (path: string, keep = false) => {
    if (!path) return;
    if (keep) sel = path;
    else focusOne(path);
    // drawn: focused now, so a key pressed before the next render acts here (keys come faster
    // than renders: a held arrow, type-to-select's letters); else once it is drawn
    const el = nav.current?.querySelector<HTMLElement>(`.file-row[data-path="${CSS.escape(path)}"]`);
    if (el) el.focus({ preventScroll: true });
    else focusWanted = path;
    scrollWanted = { key: path, center: false };
    bump();
  };
  const onKey = (e: KeyboardEvent) => {
    if ((e.target as HTMLElement).tagName === "INPUT" || e.altKey) return;
    // the row with focus is the one the keys act on (sel can have moved meanwhile)
    const focused = (e.target as HTMLElement).closest<HTMLElement>(".file-row")?.dataset.path;
    if (focused && focused !== sel) sel = focused;
    const target = rows.find((r) => r.t === "entry" && r.path === sel);
    const cur = target?.t === "entry" ? target : undefined;
    const dir = cur?.e.kind === "dir";
    const mod = IS_MAC ? e.metaKey : e.ctrlKey;
    // ⌘/Ctrl-A: every row drawn (only here: the tree has focus, not a field)
    if (mod && !e.shiftKey && e.key.toLowerCase() === "a") {
      if (!order.length) return;
      if (!sel || !order.includes(sel)) go(order[0]);
      pick = { paths: new Set(order), anchor: pick.anchor && order.includes(pick.anchor) ? pick.anchor : sel };
      bump();
      e.preventDefault();
      e.stopPropagation();
      return;
    }
    if (mod && e.key !== "Backspace") return;
    // the focus outside what is picked (⌘-clicked off): the keys never act on rows it is not on
    const loose = pick.paths.size > 0 && !!sel && !pick.paths.has(sel);
    switch (e.key) {
      case "ArrowDown": case "ArrowUp": case "Home": case "End": {
        const to = moveSel(rows, sel, e.key, open);
        if (e.shiftKey && to) {
          pick = extendPick(order, loose ? pickOne(sel) : pick, sel, to);
          go(to, true);
        } else go(to);
        break;
      }
      case "ArrowRight":
        if (cur && dir && !open.has(cur.path)) toggle(app, cur.path);
        else go(moveSel(rows, sel, e.key, open));
        break;
      case "ArrowLeft":
        if (cur && dir && open.has(cur.path)) toggle(app, cur.path);
        else go(moveSel(rows, sel, e.key, open));
        break;
      case "Enter":
        if (!cur) return;
        if (dir) toggle(app, cur.path);
        else openFile(app, cur.path);
        break;
      case "F2":
        if (!cur) return;
        startRename(cur.path); // several picked: the focused row alone
        break;
      case "Delete": case "Backspace":
        if (!cur || e.repeat || (e.key === "Backspace" && !mod)) return;
        if (loose) {
          // shown first, trashed on the next press
          focusOne(cur.path);
          bump();
          break;
        }
        trashMany(app, outermost(order, new Set(chosen())));
        break;
      case "ContextMenu": {
        if (!cur) return;
        if (loose) focusOne(cur.path);
        const r = (e.target as HTMLElement).getBoundingClientRect();
        showMenu(app, cur.e.name, rowItems(app, root, cur.path, dir), { clientX: r.left + 24, clientY: r.bottom });
        break;
      }
      case "Escape":
        if (pick.paths.size > 1 || loose) focusOne(sel); // several: back to the focused row
        else if (sel) focusOne("");
        else return;
        bump();
        break;
      default: {
        // type-to-select: letters go to the next row whose name starts with them
        if (e.key.length !== 1 || e.ctrlKey || e.metaKey || (e.key === " " && !typeBuf.text)) return;
        typeBuf = typed(typeBuf, e.key, performance.now());
        const to = typeMatch(rows, sel, typeBuf.text);
        if (to) go(to);
        break;
      }
    }
    e.preventDefault();
    e.stopPropagation();
  };

  // the row Tab reaches (one in the tree): the selected one, else the first
  const first = rows.find((r) => r.t === "entry");
  const stop = selRow ? sel : first ? rowKey(first) : "";
  // the name field's row is always drawn: out of view it would be removed, and a removed field blurs
  const items: WItem[] = rows.map((r) => ({ key: rowKey(r), h: rowH, keep: isEditRow(r, edit), draw: () => drawRow(app, root, r, active, rowKey(r) === stop) }));
  const target = () => newTarget(root, sel, selRow?.t === "entry" && selRow.e.kind === "dir");
  const name = root.slice(root.lastIndexOf("/") + 1);
  return (
    <div class="files">
      <div class="files-head">
        <Icon name="folder" size={14} class="muted" />
        <span class="files-root" title={root}>{name}</span>
        <span class="spacer" />
        <button type="button" class="icon-btn small" title="New file" aria-label="New file" onClick={() => startNew(app, root, target(), "file")}>
          <Icon name="new-file" size={13} />
        </button>
        <button type="button" class="icon-btn small" title="New folder" aria-label="New folder" onClick={() => startNew(app, root, target(), "dir")}>
          <Icon name="new-folder" size={13} />
        </button>
        <button type="button" class="icon-btn small" title="Collapse all" aria-label="Collapse all" onClick={() => collapseAll(root)}>
          <Icon name="collapse-all" size={13} />
        </button>
        <button type="button" class="icon-btn small" title="Refresh" aria-label="Refresh" onClick={() => refresh(app, root)}>
          <Icon name="refresh" size={13} />
        </button>
      </div>
      <div
        class="nav files-tree"
        ref={nav}
        role="tree"
        aria-multiselectable="true"
        aria-label={"Files in " + name}
        onKeyDown={onKey}
        onContextMenu={(e) => {
          if ((e.target as HTMLElement).closest(".file-row")) return;
          e.preventDefault();
          showMenu(app, name, rootItems(app, root), e);
        }}
      >
        <Windowed items={items} />
      </div>
      {picking ? <PickBar app={app} root={root} /> : null}
    </div>
  );
}

// A phone's selection mode: how many are picked and what to do with them, at the thumb.
function PickBar({ app, root }: { app: App; root: string }) {
  const many = order.filter((p) => pick.paths.has(p));
  const out = outermost(order, pick.paths);
  return (
    <div class="files-pick" role="toolbar" aria-label="Selected files">
      <span class="files-pick-n">{many.length} selected</span>
      <span class="spacer" />
      <button type="button" class="btn small danger" disabled={!out.length} onClick={() => trashMany(app, out)}>Move to Trash</button>
      <button type="button" class="btn small" disabled={!many.length} onClick={() => copyPaths(app, root, many, false)}>Copy paths</button>
      <button
        type="button"
        class="btn small primary"
        onClick={() => {
          picking = false;
          pick = pickOne(sel);
          bump();
        }}
      >
        Done
      </button>
    </div>
  );
}

function drawRow(app: App, root: string, r: Row, active: string, stop: boolean): ComponentChildren {
  const pad = { paddingLeft: 8 + r.depth * 16 + "px" };
  switch (r.t) {
    case "wait":
      return <div class="row file-row muted-text" style={pad}>Listing…</div>;
    case "err":
      return <div class={"row file-row error-ink" + (r.edit ? " file-err" : "")} style={r.edit ? { paddingLeft: 8 + r.depth * 16 + 32 + "px" } : pad} role={r.edit ? "alert" : undefined}>{r.text}</div>;
    case "new":
      return (
        <div class="row file-row file-edit" style={pad}>
          <span class="chev-gap" />
          <Icon name={r.kind === "dir" ? "folder" : "file"} size={14} class="muted" />
          <NameField app={app} root={root} initial="" dir={r.kind === "dir"} label={r.kind === "dir" ? "New folder name" : "New file name"} />
        </div>
      );
    case "entry":
      return <FileRow app={app} root={root} path={r.path} r={r} active={active === r.path} stop={stop} />;
  }
}

// The name field: Enter or leaving it commits (empty or unchanged: nothing), Esc cancels. A rename
// selects the stem.
function NameField({ app, root, initial, dir, label }: { app: App; root: string; initial: string; dir: boolean; label: string }) {
  const field = useRef<HTMLInputElement>(null);
  const busy = useRef(false);
  const tried = useRef<string | null>(null); // the text the core refused (leaving it then cancels)
  const mine = useRef(edit).current; // the edit this field is for
  useLayoutEffect(() => {
    const el = field.current;
    if (!el) return;
    el.focus({ preventScroll: true });
    if (initial) el.setSelectionRange(0, stemEnd(initial, dir));
  }, []);
  const back = () => (edit?.kind === "rename" ? edit.path : sel);
  const go = async (leaving: boolean) => {
    if (busy.current || !edit) return;
    const v = field.current?.value ?? "";
    if (leaving && (!v.trim() || v === tried.current)) return endEdit("");
    busy.current = true;
    tried.current = v;
    try {
      await commitEdit(app, root, v);
    } finally {
      busy.current = false;
    }
  };
  return (
    <input
      ref={field}
      class="field file-name"
      type="text"
      defaultValue={initial}
      aria-label={label}
      spellcheck={false}
      autocomplete="off"
      autocapitalize="off"
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          go(false);
        } else if (e.key === "Escape") {
          e.preventDefault();
          endEdit(back());
        }
      }}
      onBlur={() =>
        // after the event: a field removed from the page (its row gone) cancels, never commits
        window.setTimeout(() => {
          if (field.current?.isConnected) go(true);
          else if (edit === mine) endEdit("");
        }, 0)
      }
    />
  );
}

function FileRow({ app, root, path, r, active, stop }: { app: App; root: string; path: string; r: Extract<Row, { t: "entry" }>; active: boolean; stop: boolean }) {
  const { e, depth } = r;
  const isDir = e.kind === "dir";
  const on = isDir && open.has(path);
  const letter = gitLetter(e.git, isDir);
  const tone = gitTone(letter);
  const me = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (focusWanted === path && me.current) {
      focusWanted = "";
      me.current.focus({ preventScroll: true });
    }
  });
  const renaming = edit?.kind === "rename" && edit.path === path;
  const selected = picking || pick.paths.size ? pick.paths.has(path) : sel === path;
  const menu = (at: { clientX: number; clientY: number }) => {
    // on a picked row the picking stays (the menu acts on them all); elsewhere the row alone
    if (pick.paths.has(path)) sel = path;
    else focusOne(path);
    bump();
    showMenu(app, e.name, rowItems(app, root, path, isDir), at);
  };
  return (
    <div
      ref={me}
      class={"row file-row" + (selected ? " sel" : "")}
      style={{ paddingLeft: 8 + depth * 16 + "px" }}
      role="treeitem"
      aria-level={depth + 1}
      aria-selected={selected ? "true" : "false"}
      aria-expanded={isDir ? (on ? "true" : "false") : undefined}
      tabIndex={stop ? 0 : -1}
      title={path}
      data-path={path}
      onFocus={(ev) => {
        if (ev.target === me.current && sel !== path) {
          sel = path;
          bump();
        }
      }}
      onClick={(ev) => {
        if (renaming) return;
        const mod = IS_MAC ? ev.metaKey : ev.ctrlKey;
        if (picking) {
          // a phone picking: a tap picks or unpicks; the folder's arrow still opens it
          if (isDir && (ev.target as HTMLElement).closest(".chev")) return toggle(app, path);
          pick = clickPick(order, pick, path, { toggle: true, range: false });
          sel = path;
          return bump();
        }
        if (mod || ev.shiftKey) {
          pick = clickPick(order, pick, path, { toggle: mod, range: ev.shiftKey });
          sel = path;
          return bump();
        }
        focusOne(path);
        if (isDir) toggle(app, path);
        else {
          bump();
          openFile(app, path);
        }
      }}
      onContextMenu={(ev) => {
        ev.preventDefault();
        if (!renaming) menu(ev);
      }}
      {...longPressProps(() => !renaming && !picking, (at) => menu({ clientX: at.x, clientY: at.y }))}
    >
      {isDir ? <Icon name={on ? "chevron-down" : "chevron-right"} size={12} class="chev" /> : <span class="chev-gap" />}
      <Icon name={isDir ? "folder" : "file"} size={14} class="muted" />
      {renaming ? (
        <NameField app={app} root={root} initial={e.name} dir={isDir} label={"Rename " + e.name} />
      ) : (
        <span class={"title " + (e.name.startsWith(".") ? "dot" : tone) + (active ? " active" : "")}>{e.name}</span>
      )}
      <span class="spacer" />
      {letter && !renaming ? <span class={"ch-letter " + tone}>{letter}</span> : null}
      {picking ? (selected ? <Icon name="check" size={16} class="accent" /> : <span class="pick-gap" />) : null}
      {!renaming && !picking ? (
        <button
          type="button"
          class="icon-btn small file-more"
          tabIndex={-1}
          title="More"
          aria-label={"More for " + e.name}
          onClick={(ev) => {
            ev.stopPropagation();
            menu(ev);
          }}
        >
          <Icon name="more" size={14} />
        </button>
      ) : null}
    </div>
  );
}

// ---- a file in a tab ----

interface FileData {
  path: string;
  size: number;
  mtime: number;
  hash: string;
  markdown: boolean;
  text?: string;
  same?: boolean;
}

// The tab's file: read, followed on disk while it is not edited, saved.
function useFile(app: App, path: string) {
  const [file, setFile] = useState<FileData | null>(null);
  const [err, setErr] = useState("");
  const [draft, setDraft] = useState<string | null>(null); // the edit (null: none)
  const [changed, setChanged] = useState(false); // on disk since it was read, while edited
  const cur = useRef<FileData | null>(null);
  const editing = useRef(false);
  editing.current = draft !== null;
  // reads on their way, by the file shown: a poll waits for this file's (a big file on a slow link:
  // no second copy); a reply for the file shown before is dropped
  const reads = useRef(new FileReads()).current;
  const read = async (force = false) => {
    const ticket = reads.begin(force);
    if (ticket === null) return;
    let mine = false;
    const r = await app.link.run({ type: "file_read", path, since: force ? "" : cur.current?.hash ?? "" }).finally(() => (mine = reads.end(ticket)));
    if (!mine) return;
    if (!r.ok) {
      setErr(r.error || "cannot read it");
      return;
    }
    setErr("");
    const d: FileData = json(r.data);
    if (d.same) return;
    if (editing.current && cur.current && !force) return setChanged(true);
    cur.current = d;
    knowFile(path, d);
    setFile(d);
    setChanged(false);
  };
  useEffect(() => {
    reads.show();
    const had = knownFile(path) ?? null;
    cur.current = had;
    setFile(had);
    setDraft(null);
    read(!had); // known: asked with its hash (unchanged: nothing sent)
    const t = window.setInterval(() => read(), 2500);
    return () => window.clearInterval(t);
  }, [path]);
  const save = async (force = false) => {
    if (draft === null || !cur.current) return;
    const ticket = reads.ticket;
    const r = await app.link.run({ type: "file_save", path, text: draft, base: cur.current.hash, force });
    if (!reads.current(ticket)) return; // another file shows now
    if (!r.ok) {
      if (json(r.data)?.code === "changed") setChanged(true);
      else app.toast(r.error || "Could not save it", true);
      return;
    }
    const d: FileData = json(r.data);
    cur.current = { ...d, text: draft };
    knowFile(path, cur.current);
    setFile(cur.current);
    setDraft(null);
    setChanged(false);
  };
  const reload = () => {
    setDraft(null);
    setChanged(false);
    read(true);
  };
  return { file, err, draft, setDraft, changed, save, reload };
}

export function FileTab({ tab, path, markdown }: { s: OpenSession; tab: Tab; path: string; markdown: boolean }) {
  const app = useApp();
  const f = useFile(app, path);
  const [source, setSource] = useState(false);
  const dirty = f.draft !== null && f.draft !== f.file?.text;
  const text = f.draft ?? f.file?.text ?? "";
  // ⌘S saves (the page keeps ⌘S from the browser while a file tab shows)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((IS_MAC ? e.metaKey : e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        f.save();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const name = path.slice(path.lastIndexOf("/") + 1);
  return (
    <div class="file-tab">
      <div class="ch-file-bar">
        <Icon name="file" size={14} class="muted" />
        <span class="ch-path" title={path}>{name}{dirty ? " •" : ""}</span>
        <span class="spacer" />
        {markdown ? (
          <button type="button" class="btn small" onClick={() => setSource(!source)}>{source ? "Preview" : "Source"}</button>
        ) : null}
        {dirty ? <button type="button" class="btn small" onClick={() => f.setDraft(null)}>Revert</button> : null}
        <button type="button" class="btn small primary" disabled={!dirty} title={`Save (${IS_MAC ? "⌘S" : "Ctrl+S"})`} onClick={() => f.save()}>Save</button>
      </div>
      {f.changed ? (
        <div class="ch-notice err">
          <span>The file changed on disk{dirty ? " while you edited it" : ""}.</span>
          <span class="spacer" />
          <button type="button" class="btn small" onClick={f.reload}>Reload</button>
          {dirty ? <button type="button" class="btn small danger" onClick={() => f.save(true)}>Save anyway</button> : null}
        </div>
      ) : null}
      {f.err && !f.file ? (
        <div class="ch-msg"><div>{f.err}</div><div class="muted-text small">{path}</div></div>
      ) : !f.file ? (
        <div class="ch-msg muted-text">Reading…</div>
      ) : markdown && !source ? (
        <MarkdownView app={app} text={text} path={path} />
      ) : (
        <CodeEdit key={tab.id + ":" + path} text={text} path={path} onEdit={(t) => f.setDraft(t)} />
      )}
    </div>
  );
}

// ---- Markdown ----

function MarkdownView({ app, text, path }: { app: App; text: string; path: string }) {
  const doc = useRef<{ text: string; blocks: Block[] }>({ text: "", blocks: [] });
  if (doc.current.text !== text || !doc.current.blocks.length) doc.current = { text, blocks: parseMarkdown(text) };
  const box = useRef<HTMLDivElement>(null);
  const dir = path.slice(0, path.lastIndexOf("/"));
  const follow = (href: string) => {
    if (href.startsWith("#")) {
      box.current?.querySelector(`[id="${CSS.escape(href.slice(1))}"]`)?.scrollIntoView({ block: "start" });
    } else if (/^(https?:|mailto:)/i.test(href)) {
      app.setOverlay({ link: href });
    } else {
      // a relative file: opened as the window does (inside a project; refusals as a toast)
      const [file, anchor] = href.split("#");
      const parts = (dir + "/" + decodeURIComponent(file)).split("/");
      const out: string[] = [];
      for (const p of parts) p === ".." ? out.pop() : p && p !== "." ? out.push(p) : null;
      app.run({ type: "show_file", path: "/" + out.join("/"), ...(anchor ? { anchor } : {}) });
    }
  };
  return (
    <div class="md-doc" ref={box}>
      <div class="md-body">{doc.current.blocks.map((b) => block(b, follow))}</div>
    </div>
  );
}

function block(b: Block, follow: (h: string) => void): ComponentChildren {
  const il = (c: Inline[]) => c.map((x) => inline(x, follow));
  switch (b.t) {
    case "h": {
      const H = `h${b.level}` as "h1";
      return <H id={b.id}>{il(b.c)}</H>;
    }
    case "p":
      return <p>{il(b.c)}</p>;
    case "code":
      return <CodeBlock text={b.s} lang={b.lang} />;
    case "html":
      return <pre class="md-code md-html">{b.s}</pre>;
    case "quote":
      return <blockquote>{b.c.map((x) => block(x, follow))}</blockquote>;
    case "hr":
      return <hr />;
    case "list": {
      const items = b.items.map((it) => (
        <li class={it.task !== null ? "task" : ""}>
          {it.task !== null ? <input type="checkbox" checked={it.task} disabled /> : null}
          {it.c.length === 1 && it.c[0].t === "p" ? il(it.c[0].c) : it.c.map((x) => block(x, follow))}
        </li>
      ));
      return b.ordered ? <ol start={b.start}>{items}</ol> : <ul>{items}</ul>;
    }
    case "table":
      return (
        <div class="md-table">
          <table>
            <thead><tr>{b.head.map((h, k) => <th style={b.align[k] ? { textAlign: b.align[k] } : undefined}>{il(h)}</th>)}</tr></thead>
            <tbody>{b.rows.map((r) => <tr>{r.map((c, k) => <td style={b.align[k] ? { textAlign: b.align[k] } : undefined}>{il(c)}</td>)}</tr>)}</tbody>
          </table>
        </div>
      );
  }
}

function inline(x: Inline, follow: (h: string) => void): ComponentChildren {
  switch (x.t) {
    case "text": return x.s;
    case "code": return <code>{x.s}</code>;
    case "em": return <em>{x.c.map((y) => inline(y, follow))}</em>;
    case "strong": return <strong>{x.c.map((y) => inline(y, follow))}</strong>;
    case "del": return <del>{x.c.map((y) => inline(y, follow))}</del>;
    case "br": return <br />;
    case "img": return <span class="md-img">[{x.alt || "image"}]</span>;
    case "link": {
      const href = safeHref(x.href);
      if (href === null) return x.c.map((y) => inline(y, follow));
      return (
        <a href={href.startsWith("#") || /^(https?:|mailto:)/i.test(href) ? href : "#"} rel="noopener noreferrer" onClick={(e) => { e.preventDefault(); follow(href); }}>
          {x.c.map((y) => inline(y, follow))}
        </a>
      );
    }
  }
}
