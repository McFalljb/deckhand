// The Files tab (the left column) and the session's editor and Markdown tabs in a browser.
// The tree is the session's folder (else the selected project's), listed with list_dir (inside a
// project, git status codes, .git left out; gitignored entries shown dimmed, or hidden by the
// header's eye, remembered per browser; asked again every few seconds with the listing's hash, so
// an unchanged folder sends nothing; an open folder inside an ignored one every 30 s; not while the
// page is hidden), folders opened in the page itself. Each row has an icon for its kind of file
// (filetree.ts fileIcon). One row has focus (sel); the keys move it (arrows, Home, End), Enter
// opens a file (show_file: a Markdown tab for .md, an editor tab otherwise; credentials and binaries
// refused) or opens and closes a folder, F2 renames, Delete or ⌘⌫ moves to the Trash (delete_path:
// the confirmation bar asks), Esc clears it. Several rows can be picked (pick): ⌘/Ctrl-click,
// shift-click, shift-arrows, ⌘/Ctrl-A in the tree; on a phone, Select in a row's sheet (taps then
// pick, a bar acts on them). Delete then trashes them all with one confirmation (delete_path paths);
// typing a name's first letters goes to it. Rows move (rename_path, one per item, no confirmation)
// by dragging them onto a folder with a mouse, or with Move to… (a folder picker: a phone, the
// keys); where they may go is filetree.ts planMove. Right-click, the row's "…" or a long press (a phone:
// a sheet) shows its menu. New file, New folder and Rename are typed in the tree, where the name
// goes (filetree.ts); the core refuses what it refuses, shown under the field. The active file tab
// is shown (its folders opened). The tabs read and save the file with file_read / file_save
// (src/core/web_files.odin): line numbers, editing, ⌘S, a file changed on disk is followed when
// nothing is edited and asked about when it is. Markdown renders with markdown.ts (no raw HTML).

import type { ComponentChildren } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import type { OpenSession, Tab } from "../state.ts";
import { IS_MAC, shownSession, useApp, wished, type App, type MenuItem } from "./ctx.ts";
import { insertPath } from "./phone.ts";
import { Icon } from "./icons.tsx";
import { parseMarkdown, safeHref, type Block, type Inline } from "./markdown.ts";
import { Windowed, type WItem } from "./Windowed.tsx";
import { FileReads, knowFile, knownFile } from "./filecache.ts";
import { CodeBlock, CodeEdit } from "./Code.tsx";
import { longPressProps } from "./Peek.tsx";
import { fileTabPath } from "./Panes.tsx";
import { cancelCut, clipItems, dropHidden, confirmed as fsConfirmed, copyInto, created, deleting, hasClip, isCut, moved, resetFor, rootClipItems, take, treeKey, type Tree } from "./fileops.ts";
import { planCopy } from "./fileclip.ts";
import { ClipBar } from "./FileClipBar.tsx";
import { storageGet, storageSet } from "../ui/dom.ts";
import { clickPick, dragText, dropDir, entryPaths, fileIcon, inIgnored, extendPick, folderRows, gitLetter, gitTone, isEditRow, movedPath, moveResult, moveSel, newTarget, outermost, parentOf, parentsOf, pickOne, planMove, prunePick, relPath, rowKey, stemEnd, trashTargets, treeRows, typeMatch, typed, type Edit, type Listing, type Pick, type Row } from "./filetree.ts";
import { CheckoutButton, FilterBox, FilterList, useCheckout, useFind } from "./FilesFind.tsx";
import { ImageTab, SvgPreview } from "./ImageView.tsx";
import { isImagePath, isSvgPath } from "./image.ts";

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
let after: { paths: string[]; until: number } | null = null; // rows to select once drawn (moved items in their new place)
let mover: { sources: string[] } | null = null; // the Move to… picker, for these paths
const pickerOpen = new Set<string>(); // folders opened in the picker
let moving = false;
// A drag in this tree (a desktop's mouse; a phone has Move to…): the paths dragged, taken at
// dragstart (the tree is listed again meanwhile), the row it started on (kept drawn: a removed
// source never ends its drag), and the folder a drop goes into now (highlighted). nonce: this
// drag's own (in the DataTransfer too: a drop must carry it); root: the tree it began in. Cleared
// on dragend, drop, Esc, a root change, and when its sources leave the tree (a re-list).
const DRAG_TYPE = "application/x-deckhand-files";
let drag: { sources: string[]; from: string; nonce: string; root: string } | null = null;
// The last press on a row: a mouse or pen drags; a touch (a touch laptop, an iPad) never does, its
// long press is the menu.
let lastPointer = "mouse";
let dropAt = "";
let dropFx = "none"; // what the last dragover showed (copy with Option/Alt): the drop does that
let hover = { path: "", timer: 0 }; // a closed folder hovered: opened after HOVER_OPEN_MS
let edge = { dir: 0, timer: 0 }; // scrolling while the pointer is near the top or bottom edge
const HOVER_OPEN_MS = 600;
// Ignored files (gitignored): shown dimmed unless hidden (the header's eye; per browser). Hidden rows
// are not drawn, so never selected, dragged, moved or trashed.
const HIDE_KEY = "deckhand.files.hideIgnored";
let hideIgnored = storageGet(HIDE_KEY) === "1";
// The page shows another checkout of the project (FilesFind.tsx useCheckout): the core reads there but
// refuses every write, so no write is offered (new, rename, move, Trash, drag).
let readOnly = false;
// The poll: an open folder inside an ignored one (node_modules, build: big, rarely edited by hand)
// every SLOW_EVERY-th time (30 s); the rest every time (5 s).
const SLOW_EVERY = 6;
let polls = 0;
const baseName = (path: string) => path.slice(path.lastIndexOf("/") + 1);

async function list(app: App, path: string) {
  if (asking.has(path)) return void again.add(path);
  asking.add(path);
  const had = listed.get(path);
  try {
    const r = await app.link.run({ type: "list_dir", path, ignored: true, ...(had?.hash && !had.err ? { since: had.hash } : {}) });
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

// poll: the timer's (an ignored folder only every SLOW_EVERY-th time); else all of them now.
function refresh(app: App, root: string, poll = false) {
  if (!root) return;
  const slow = poll && polls++ % SLOW_EVERY !== 0;
  list(app, root);
  for (const d of open) if (d.startsWith(root + "/") && !(slow && inIgnored(root, d, listed))) list(app, d);
}

// The eye: hide or show ignored files. Hiding: what goes is unselected, and a rename, Move to… or
// drag of it ends.
function setHideIgnored(root: string, hide: boolean, app?: App) {
  hideIgnored = hide;
  storageSet(HIDE_KEY, hide ? "1" : "0");
  if (hide) {
    const shown = new Set(entryPaths(treeRows(root, listed, open, null, true)));
    const gone = (p: string) => p !== root && p.startsWith(root + "/") && !shown.has(p);
    if (sel && gone(sel)) focusOne("");
    if (edit && gone(edit.kind === "rename" ? edit.path : edit.dir)) edit = null;
    if (mover?.sources.some(gone)) mover = null;
    if (drag?.sources.some(gone)) endDrag();
    if (app) dropHidden(treeOf(app, root)); // hidden rows leave the clipboard too
  }
  bump();
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

// Insert path (phone.ts insertPath): the quoted path typed into the session's terminal on screen,
// as a drop on it does at the desktop; a phone goes back from Files to that tab. null: none to type into.
function insertItem(app: App, path: string): MenuItem | null {
  const s = app.store.session(shownSession(app));
  const cmd = s ? insertPath(app.store.tabs(s.id), app.phone ? wished(`ptab:${s.id}`, s.active_tab) : s.active_tab, path) : null;
  return cmd ? { label: "Insert path", run: () => app.run(cmd).then((r) => r.ok && opened()) } : null;
}

function copyText(app: App, text: string) {
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(() => app.toast("Copied"), () => app.setOverlay({ copy: text }));
  else app.setOverlay({ copy: text }); // no async clipboard off a secure context: the copy sheet
}

// Delete: the core always asks (the confirmation bar); the tree looks again when it is answered.
function trash(app: App, path: string) {
  app.run({ type: "delete_path", path }).then((r) => deleting(r, [path]));
}

// Several rows: one delete_path with paths, one confirmation (the core checks every path first and
// refuses the lot naming the first it refuses; at most 500: its words, shown as they come). One
// row: path, as an older core knows it. An older core reads only path (empty here) and says so:
// never deleted one by one.
async function trashMany(app: App, paths: string[]) {
  if (readOnly) return;
  if (paths.length === 1) return trash(app, paths[0]);
  if (!paths.length) return;
  const r = await app.link.run({ type: "delete_path", path: "", paths });
  deleting(r, paths);
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
  if (readOnly) return;
  if (dir !== root && !open.has(dir)) {
    open.add(dir);
    list(app, dir);
  }
  edit = { kind, dir, err: "" };
  scrollWanted = { key: "new:" + dir, center: false };
  bump();
}

function startRename(path: string) {
  if (readOnly) return;
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
    follow(from, r.ok ? to : "");
    if (r.ok) app.toast(`Renamed ${baseName(from)} to ${name}`, false, moved(treeOf(app, root), [{ from, to }], true));
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
  if (r.ok) created(treeOf(app, root), made, e.kind === "dir");
}

// What was open under a moved or renamed folder follows it (to "": closed); its listings go.
function follow(from: string, to: string) {
  for (const d of [...open]) if (d === from || d.startsWith(from + "/")) {
    open.delete(d);
    if (to) open.add(movedPath(d, from, to));
  }
  for (const k of [...listed.keys()]) if (k === from || k.startsWith(from + "/")) listed.delete(k);
}

// Move into dir (no confirmation): one rename_path per item (the core's rules), in order, stopping
// at the first it refuses (the toast names it; what moved stays moved). First dir is listed again
// with its ignored names: a name already there refuses the lot, nothing moved, never renamed to
// make room. Then the folder shows open, the moved items selected in it.
async function moveTo(app: App, root: string, sources: string[], dir: string) {
  if (readOnly) return;
  if (moving) return void app.toast("A move is still running; try again when it is done", true);
  moving = true;
  try {
    const l = await app.link.run({ type: "list_dir", path: dir, ignored: true });
    if (!l.ok) return void app.toast(l.error || "Could not look in that folder", true);
    const plan = planMove(root, sources, dir, { entries: json(l.data).entries ?? [], err: "" });
    if (plan.why) return void app.toast(plan.why, true);
    const done: typeof plan.moves = [];
    let failed: { from: string; error: string } | undefined;
    let waiting: number | undefined;
    for (const m of plan.moves) {
      const r = await app.link.run({ type: "rename_path", from: m.from, to: m.to });
      if (r.ok) {
        done.push(m);
        follow(m.from, m.to);
        continue;
      }
      // the confirmation bar asks about this one (it moves when answered); the rest are not moved
      if (r.error === "needs_confirmation") waiting = plan.moves.length - done.length - 1;
      else failed = { from: m.from, error: r.error || "refused" };
      break;
    }
    if (done.length) {
      for (const d of parentsOf(root, dir + "/x")) if (!open.has(d)) open.add(d);
      after = { paths: sources.map((s) => done.reduce((p, m) => movedPath(p, m.from, m.to), s)), until: performance.now() + 8000 };
    }
    if (done.length || failed || waiting !== undefined) app.toast(moveResult(root, dir, done.map((m) => m.from), failed, waiting), !!failed, moved(treeOf(app, root), done));
    refresh(app, root);
    return done.length;
  } finally {
    moving = false;
    bump();
  }
}

function openMover(sources: string[]) {
  if (!sources.length || readOnly) return;
  mover = { sources };
  pickerOpen.clear();
  bump();
}

// The paths a drag takes: the picked rows when it starts on one of several, else that row (then
// selected alone).
function startDrag(ev: DragEvent, root: string, path: string) {
  const dt = ev.dataTransfer;
  if (!dt || lastPointer === "touch") return void ev.preventDefault();
  if (pick.paths.size > 1 && pick.paths.has(path)) sel = path;
  else focusOne(path);
  const sources = pick.paths.size > 1 ? outermost(order, pick.paths) : [path];
  const nonce = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
  drag = { sources, from: path, nonce, root };
  dt.effectAllowed = "copyMove"; // Option/Alt at the drop copies
  dt.setData(DRAG_TYPE, nonce); // ours: only a drop carrying this drag's nonce moves (and only what is in memory)
  // paths shell-quoted a space apart, never contents, never a newline (dropped on a terminal: typed, not run)
  dt.setData("text/plain", dragText(sources));
  // the image: the name, or "N items" (text only)
  const img = document.createElement("div");
  img.className = "files-drag";
  img.textContent = (ev.altKey ? "Copy " : "") + (sources.length === 1 ? baseName(sources[0]) : `${sources.length} items`);
  document.body.appendChild(img);
  dt.setDragImage(img, 12, 12);
  window.setTimeout(() => img.remove(), 0);
  bump();
}

function stopEdge() {
  window.clearInterval(edge.timer);
  edge = { dir: 0, timer: 0 };
}

function clearHover() {
  window.clearTimeout(hover.timer);
  hover = { path: "", timer: 0 };
}

function hoverOver(app: App, path: string) {
  if (path === hover.path) return;
  clearHover();
  hover.path = path;
  const inSource = drag?.sources.some((s) => path === s || path.startsWith(s + "/"));
  if (!path || open.has(path) || inSource) return;
  hover.timer = window.setTimeout(() => {
    if (!drag || hover.path !== path || open.has(path)) return;
    open.add(path); // stays open after the drag
    list(app, path);
    bump();
  }, HOVER_OPEN_MS);
}

function endDrag() {
  drag = null;
  dropAt = "";
  dropFx = "none";
  clearHover();
  stopEdge();
  bump();
}

// The tree as fileops.ts (copy, cut, paste, duplicate, undo) sees it.
function treeOf(app: App, root: string): Tree {
  return {
    app,
    root,
    kindOf: (p) => listed.get(parentOf(p))?.entries.find((x) => x.name === baseName(p))?.kind ?? "",
    select: (paths) => {
      for (const p of paths) for (const d of parentsOf(root, p)) open.add(d);
      after = { paths, until: performance.now() + 8000 };
      bump();
    },
    follow,
    refresh: () => refresh(app, root),
    bump: () => bump(),
    moveTo: (s, d) => moveTo(app, root, s, d),
    hidden: (p) => hideIgnored && inIgnored(root, p, listed),
  };
}

function rowItems(app: App, root: string, path: string, dir: boolean): MenuItem[] {
  const keys = (k: string) => (app.phone ? undefined : k);
  const items: MenuItem[] = [];
  const many = chosen();
  if (many.length > 1) {
    // several rows: what acts on them all (no open, rename or new here)
    const out = outermost(order, new Set(many));
    if (!readOnly) {
      items.push({ label: "Move to…", run: () => openMover(out) });
      items.push(...clipItems(treeOf(app, root), out, "", false));
      items.push({ label: out.length > 1 ? `Move ${out.length} items to Trash` : "Move to Trash", keys: keys(IS_MAC ? "⌘⌫" : "Delete"), danger: true, run: () => trashMany(app, out) });
      items.push({ sep: true });
    }
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
  if (!readOnly) {
    items.push({ label: "New file…", run: () => startNew(app, root, into, "file") });
    items.push({ label: "New folder…", run: () => startNew(app, root, into, "dir") });
    items.push({ sep: true });
    items.push({ label: "Rename…", keys: keys("F2"), run: () => startRename(path) });
    items.push({ label: "Move to…", run: () => openMover([path]) });
    items.push(...clipItems(treeOf(app, root), [path], into, dir));
    items.push({ label: "Move to Trash", keys: keys(IS_MAC ? "⌘⌫" : "Delete"), danger: true, run: () => trash(app, path) });
    items.push({ sep: true });
  }
  const ins = insertItem(app, path);
  if (ins) items.push(ins);
  items.push({ label: "Copy path", run: () => copyText(app, path) });
  items.push({ label: "Copy relative path", run: () => copyText(app, relPath(root, path)) });
  return items;
}

function rootItems(app: App, root: string): MenuItem[] {
  return [
    ...(readOnly ? [] : [{ label: "New file…", run: () => startNew(app, root, root, "file") }, { label: "New folder…", run: () => startNew(app, root, root, "dir") }, { sep: true }]),
    { label: "Collapse all", run: () => collapseAll(root) },
    { label: "Refresh", run: () => refresh(app, root) },
    { sep: true },
    ...(readOnly ? [] : rootClipItems(treeOf(app, root))),
    { label: "Copy path", run: () => copyText(app, root) },
  ];
}

// The tree again after the filter: the file opened from it shown (its folders opened, its row
// focused and centred).
function reveal(app: App, root: string, path: string) {
  if (path.startsWith(root + "/")) {
    for (const d of parentsOf(root, path)) if (!open.has(d)) {
      open.add(d);
      list(app, d);
    }
    focusOne(path);
    focusWanted = path;
    scrollWanted = { key: path, center: true };
  }
  bump();
}

// A filter result's menu: one file, nothing that changes files.
function foundItems(app: App, root: string, path: string, clear: () => void): MenuItem[] {
  const items: MenuItem[] = [{ label: "Open", keys: app.phone ? undefined : "↩", run: () => openFile(app, path) }];
  if (!app.phone) items.push({ label: "Open to the side", run: () => openSide(app, path) });
  items.push({ label: "Show in the tree", run: () => { clear(); reveal(app, root, path); } });
  items.push({ sep: true });
  const ins = insertItem(app, path);
  if (ins) items.push(ins);
  items.push({ label: "Copy path", run: () => copyText(app, path) }, { label: "Copy relative path", run: () => copyText(app, relPath(root, path)) });
  return items;
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
  const home = s && !s.home && !s.machine ? s.cwd : p && !p.machine ? p.cwd : "";
  // the checkout the page shows (the switcher; read-only when it is not home), and the filter over it
  const co = useCheckout(app, home);
  const root = co.root;
  readOnly = co.readOnly;
  const find = useFind(app, root, (path) => openFile(app, path), (path) => reveal(app, root, path));
  resetFor(`${s?.id ?? ""}|${store.selectedProject}|${root}`, root); // another tree: the clip and Undo cleared
  // listed when shown, and again every few seconds while it shows and the page is seen (the files
  // change; an unchanged folder answers "same")
  useEffect(() => {
    if (!root) return;
    const under = (x: string) => x === root || x.startsWith(root + "/");
    if (edit && !under(edit.kind === "rename" ? edit.path : edit.dir)) edit = null;
    refresh(app, root);
    picking = false;
    if (drag && drag.root !== root) endDrag();
    mover = null;
    const t = window.setInterval(() => !document.hidden && refresh(app, root, true), 5000);
    const seen = () => !document.hidden && refresh(app, root);
    document.addEventListener("visibilitychange", seen);
    return () => {
      window.clearInterval(t);
      document.removeEventListener("visibilitychange", seen);
    };
  }, [root]);
  // Esc ends a drag here (the browser cancels its own too: dragend)
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === "Escape" && drag && endDrag();
    window.addEventListener("keydown", esc, true);
    return () => window.removeEventListener("keydown", esc, true);
  }, []);
  // a confirmation answered (a delete): look again, now and once it has run
  // a confirmed delete or rename has finished (ConfirmBar): look again (a batch that failed midway
  // moved some)
  useEffect(() => {
    const again = (e: Event) => {
      refresh(app, root);
      fsConfirmed(treeOf(app, root), (e as CustomEvent).detail); // the tree's own delete: its Undo
    };
    window.addEventListener("deckhand:fs-changed", again);
    return () => window.removeEventListener("deckhand:fs-changed", again);
  }, [root]);
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
  const rows = root ? treeRows(root, listed, open, edit, hideIgnored) : [];
  // the picked rows still drawn (listed again: what went drops out; a closed folder's rows too)
  order = entryPaths(rows);
  // a move's items selected in their new place once they are listed there (or as many as are, a
  // while later)
  if (after) {
    const drawn = new Set(order);
    const there = after.paths.filter((x) => drawn.has(x));
    if (there.length === after.paths.length || performance.now() > after.until) {
      if (there.length) {
        pick = { paths: new Set(there), anchor: there[0] };
        sel = there[0];
        scrollWanted = { key: there[0], center: false };
        if (!app.phone) focusWanted = there[0];
      }
      after = null;
    }
  }
  pick = prunePick(order, pick);
  // a drag whose rows went (listed again: moved or deleted elsewhere) or another tree's: over
  if (drag && (drag.root !== root || drag.sources.some((x) => !order.includes(x)))) {
    drag = null;
    dropAt = "";
    clearHover();
    stopEdge();
  }
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
    // ⌘/Ctrl-C, X, V, D, Z with a row focused (fileops.ts); never in the name field (above) nor
    // outside the tree (the editor's own undo stays its own)
    if (mod && !e.shiftKey && focused && !readOnly && treeKey(treeOf(app, root), e.key.toLowerCase(), chosen(), newTarget(root, sel, dir))) {
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
        if (!cur || readOnly) return;
        startRename(cur.path); // several picked: the focused row alone
        break;
      case "Delete": case "Backspace":
        if (!cur || e.repeat || readOnly || (e.key === "Backspace" && !mod)) return;
        trashMany(app, trashTargets(order, pick, sel));
        break;
      case "ContextMenu": {
        if (!cur) return;
        if (loose) focusOne(cur.path);
        const r = (e.target as HTMLElement).getBoundingClientRect();
        showMenu(app, cur.e.name, rowItems(app, root, cur.path, dir), { clientX: r.left + 24, clientY: r.bottom });
        break;
      }
      case "Escape":
        if (cancelCut(treeOf(app, root))) break; // a cut called off first
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
  // ... and so is the row a drag started on (a source removed from the page never ends its drag)
  const items: WItem[] = rows.map((r) => ({ key: rowKey(r), h: rowH, keep: isEditRow(r, edit) || drag?.from === rowKey(r), draw: () => drawRow(app, root, r, active, rowKey(r) === stop) }));
  // A drag over the tree: ours only (a file from the desktop or text from elsewhere is never
  // dropped, nor opened by the page). Its folder: a folder row, a file row's folder, empty space
  // the root; refused (planMove): no highlight, no drop.
  const ours = (e: DragEvent) => !!drag && Array.from(e.dataTransfer?.types ?? []).includes(DRAG_TYPE);
  const dropFolder = (e: DragEvent): string => {
    const row = (e.target as HTMLElement).closest?.<HTMLElement>(".file-row");
    if (!row) return root;
    return row.dataset.path ? dropDir(root, { path: row.dataset.path, dir: row.dataset.dir === "1" }) : "";
  };
  const onDragOver = (e: DragEvent) => {
    e.preventDefault();
    const dt = e.dataTransfer;
    if (!dt) return;
    if (!ours(e)) return void (dt.dropEffect = "none");
    const el = nav.current!;
    const box = el.getBoundingClientRect();
    const d = e.clientY < box.top + 28 ? -1 : e.clientY > box.bottom - 28 ? 1 : 0;
    if (d !== edge.dir) {
      stopEdge();
      // (a drag that never ended, its source gone: it stops)
      if (d) edge = { dir: d, timer: window.setInterval(() => (drag ? (el.scrollTop += d * 8) : stopEdge()), 16) };
    }
    const row = (e.target as HTMLElement).closest?.<HTMLElement>(".file-row");
    hoverOver(app, row?.dataset.dir === "1" ? row.dataset.path ?? "" : "");
    const dir = dropFolder(e);
    const copy = e.altKey; // Option/Alt held: a copy (into the items' own folder too: duplicates)
    const at = dir && !(copy ? planCopy(root, drag!.sources, dir) : planMove(root, drag!.sources, dir, listed.get(dir))).why ? dir : "";
    dt.dropEffect = dropFx = at ? (copy ? "copy" : "move") : "none";
    if (at !== dropAt) {
      dropAt = at;
      bump();
    }
  };
  const onDragLeave = (e: DragEvent) => {
    if (!drag || nav.current?.contains(e.relatedTarget as Node | null)) return;
    dropAt = "";
    clearHover();
    stopEdge();
    bump();
  };
  // the drop: this drag's nonce in it, or nothing (what moves is the memory's sources, never the
  // DataTransfer's); onto its own row, or where they all already are: a slipped click, nothing
  const onDrop = (e: DragEvent) => {
    e.preventDefault();
    const d = drag;
    if (!d || !ours(e) || e.dataTransfer?.getData(DRAG_TYPE) !== d.nonce || d.root !== root) return void (d && endDrag());
    const dir = dropFolder(e);
    const onRow = (e.target as HTMLElement).closest?.<HTMLElement>(".file-row")?.dataset.path;
    const fx = dropFx;
    endDrag();
    if (fx === "copy") return void (dir && onRow !== d.from && copyInto(treeOf(app, root), d.sources, dir)); // as the cursor showed
    if (!dir || onRow === d.from || planMove(root, d.sources, dir, listed.get(dir)).noop) return;
    moveTo(app, root, d.sources, dir);
  };
  const target = () => newTarget(root, sel, selRow?.t === "entry" && selRow.e.kind === "dir");
  const name = root.slice(root.lastIndexOf("/") + 1);
  return (
    <div class="files">
      <div class="files-head">
        <Icon name="folder" size={14} class="muted" />
        <CheckoutButton view={co} />
        <span class="spacer" />
        {app.phone ? (
          <button type="button" class="icon-btn small" title="Filter files" aria-label="Filter files" aria-pressed={find.shown || find.text ? "true" : "false"} onClick={() => find.show(!(find.shown || find.text))}>
            <Icon name="search" size={13} />
          </button>
        ) : null}
        {readOnly ? null : (
          <>
            <button type="button" class="icon-btn small" title="New file" aria-label="New file" onClick={() => startNew(app, root, target(), "file")}>
              <Icon name="new-file" size={13} />
            </button>
            <button type="button" class="icon-btn small" title="New folder" aria-label="New folder" onClick={() => startNew(app, root, target(), "dir")}>
              <Icon name="new-folder" size={13} />
            </button>
          </>
        )}
        <button
          type="button"
          class="icon-btn small"
          title={hideIgnored ? "Show ignored files" : "Hide ignored files"}
          aria-label={hideIgnored ? "Show ignored files" : "Hide ignored files"}
          aria-pressed={hideIgnored ? "true" : "false"}
          onClick={() => setHideIgnored(root, !hideIgnored, app)}
        >
          <Icon name={hideIgnored ? "eye-off" : "eye"} size={13} />
        </button>
        <button type="button" class="icon-btn small" title="Collapse all" aria-label="Collapse all" onClick={() => collapseAll(root)}>
          <Icon name="collapse-all" size={13} />
        </button>
        <button type="button" class="icon-btn small" title="Refresh" aria-label="Refresh" onClick={() => refresh(app, root)}>
          <Icon name="refresh" size={13} />
        </button>
        <button type="button" class="icon-btn small" title="More" aria-label={"More for " + name} onClick={(e) => showMenu(app, name, rootItems(app, root), e)}>
          <Icon name="more" size={13} />
        </button>
      </div>
      {readOnly ? <div class="files-ro-note" role="note">Read-only here: open a session in this checkout to change files</div> : null}
      {!app.phone || find.shown || find.text ? <FilterBox find={find} phone={app.phone} listId="files-find" /> : null}
      {find.text ? (
        <FilterList find={find} root={root} listId="files-find" active={active} ignoredShown={!hideIgnored} menu={(path, at) => showMenu(app, baseName(path), foundItems(app, root, path, find.clear), at)} />
      ) : (
      <div
        class={"nav files-tree" + (drag && dropAt === root ? " drop-root" : "")}
        ref={nav}
        role="tree"
        aria-multiselectable="true"
        aria-label={"Files in " + name}
        onKeyDown={onKey}
        onDragOver={onDragOver}
        onDragLeave={onDragLeave}
        onDrop={onDrop}
        onContextMenu={(e) => {
          if ((e.target as HTMLElement).closest(".file-row")) return;
          e.preventDefault();
          showMenu(app, name, rootItems(app, root), e);
        }}
      >
        <Windowed items={items} />
      </div>
      )}
      {picking ? <PickBar app={app} root={root} /> : null}
      {app.phone && !picking && !readOnly && hasClip() ? <ClipBar t={treeOf(app, root)} target={target()} /> : null}
      {mover ? <MovePicker key={mover.sources.join("\n")} app={app} root={root} sources={mover.sources} /> : null}
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
      {readOnly ? null : (
        <>
          <button type="button" class="btn small" disabled={!out.length} onClick={() => openMover(out)}>Move to…</button>
          <button type="button" class="btn small danger" disabled={!out.length} onClick={() => trashMany(app, out)}>Move to Trash</button>
          <button type="button" class="btn small" disabled={!out.length} onClick={() => ((picking = false), take(treeOf(app, root), "copy", out))}>Copy</button>
          <button type="button" class="btn small" disabled={!out.length} onClick={() => ((picking = false), take(treeOf(app, root), "cut", out))}>Cut</button>
          <button type="button" class="btn small" disabled={!out.length} onClick={() => void copyInto(treeOf(app, root), out, null)}>Duplicate</button>
        </>
      )}
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

// Move to… (a phone's sheet and selection bar; the desktop's menu): the tree's folders, the root at
// the top, opened here; folders the items cannot go to (planMove) disabled; Move here moves them.
function MovePicker({ app, root, sources }: { app: App; root: string; sources: string[] }) {
  const [chosen, setChosen] = useState("");
  const list0 = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => list0.current?.querySelector<HTMLElement>(".move-pick:not([disabled])")?.focus({ preventScroll: true }), []);
  const close = () => {
    mover = null;
    bump();
  };
  const why = (dir: string) => planMove(root, sources, dir, listed.get(dir)).why;
  const ok = !!chosen && !why(chosen);
  const title = sources.length === 1 ? `Move ${baseName(sources[0])} to…` : `Move ${sources.length} items to…`;
  const flip = (path: string) => {
    if (pickerOpen.has(path)) pickerOpen.delete(path);
    else {
      pickerOpen.add(path);
      if (!listed.has(path)) list(app, path);
    }
    bump();
  };
  return (
    <div class="scrim" onMouseDown={close}>
      <div
        class={"sheet move-picker" + (app.phone ? " bottom" : "")}
        role="dialog"
        aria-label={title}
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          if (e.key !== "Escape") return;
          e.preventDefault();
          e.stopPropagation();
          close();
        }}
      >
        <div class="sheet-title">{title}</div>
        <div class="move-list" ref={list0}>
          {folderRows(root, listed, pickerOpen, hideIgnored).map((r) => {
            const bad = why(r.path);
            return (
              <div key={r.path} class={"row move-row" + (chosen === r.path ? " sel" : "")} style={{ paddingLeft: 4 + r.depth * 16 + "px" }}>
                {r.depth && r.kids ? (
                  <button type="button" class="move-chev" aria-label={(r.open ? "Collapse " : "Expand ") + r.name} aria-expanded={r.open ? "true" : "false"} onClick={() => flip(r.path)}>
                    <Icon name={r.open ? "chevron-down" : "chevron-right"} size={12} />
                  </button>
                ) : (
                  <span class="move-chev" />
                )}
                <button type="button" class="move-pick" disabled={!!bad} title={bad || r.path} aria-pressed={chosen === r.path ? "true" : "false"} onClick={() => setChosen(r.path)}>
                  <Icon name={r.open && r.depth ? "folder-open" : "folder"} size={14} class="muted" />
                  <span class="title">{r.depth ? r.name : r.name + "/"}</span>
                  {r.open && r.state === "wait" ? <span class="muted small">Listing…</span> : r.open && r.state === "err" ? <span class="error-ink small">cannot list it</span> : null}
                </button>
              </div>
            );
          })}
        </div>
        <div class="prompt-actions">
          <button type="button" class="btn" onClick={close}>Cancel</button>
          <button
            type="button"
            class="btn primary"
            disabled={!ok}
            onClick={() => {
              close();
              moveTo(app, root, sources, chosen);
            }}
          >
            Move here
          </button>
        </div>
      </div>
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
  const { e, depth, ign } = r;
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
  // a drop's folder shaded with its rows under it (the folder's own row may be out of view; the
  // root: the tree's outline)
  const inDrop = !!drag && !!dropAt && dropAt !== root && (path === dropAt || path.startsWith(dropAt + "/"));
  // a drag only from a mouse or pen press: a touch's long press is the menu (a touch laptop, an iPad)
  const canDrag = !app.phone && !renaming && !picking && !readOnly;
  const press = longPressProps(() => !renaming && !picking, (at) => menu({ clientX: at.x, clientY: at.y }));
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
      class={"row file-row" + (selected ? " sel" : "") + (inDrop ? " drop" : "") + (ign ? " ign" : "") + (isCut(root, path) ? " cut" : "")}
      style={{ paddingLeft: 8 + depth * 16 + "px" }}
      role="treeitem"
      aria-level={depth + 1}
      aria-selected={selected ? "true" : "false"}
      aria-expanded={isDir ? (on ? "true" : "false") : undefined}
      tabIndex={stop ? 0 : -1}
      title={path}
      data-path={path}
      data-dir={isDir ? "1" : undefined}
      draggable={canDrag && lastPointer !== "touch"}
      onDragStart={(ev) => startDrag(ev, root, path)}
      onDragEnd={endDrag}
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
      {...press}
      onPointerDown={(ev: PointerEvent) => {
        lastPointer = ev.pointerType || "mouse";
        if (me.current) me.current.draggable = canDrag && lastPointer !== "touch";
        press.onPointerDown(ev);
      }}
    >
      {isDir ? <Icon name={on ? "chevron-down" : "chevron-right"} size={12} class="chev" /> : <span class="chev-gap" />}
      <Icon name={fileIcon(e.name, e.kind, on)} size={14} class="muted kind" />
      {renaming ? (
        <NameField app={app} root={root} initial={e.name} dir={isDir} label={"Rename " + e.name} />
      ) : (
        <span class={"title " + (e.name.startsWith(".") || ign ? "dot" : tone) + (active ? " active" : "")}>{e.name}</span>
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

// A PNG, JPEG… shows its picture (ImageView.tsx); any other file its text, and so does one named
// .png that is text after all.
export function FileTab(props: { s: OpenSession; tab: Tab; path: string; markdown: boolean }) {
  const [textPath, setTextPath] = useState("");
  const image = isImagePath(props.path) && textPath !== props.path;
  return image ? <ImageTab key={props.path} path={props.path} onText={() => setTextPath(props.path)} /> : <TextFileTab {...props} />;
}

function TextFileTab({ tab, path, markdown }: { s: OpenSession; tab: Tab; path: string; markdown: boolean }) {
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
  const svg = isSvgPath(path); // its text, previewed as an image (an <img>, never markup)
  return (
    <div class="file-tab">
      <div class="ch-file-bar">
        <Icon name="file" size={14} class="muted" />
        <span class="ch-path" title={path}>{name}{dirty ? " •" : ""}</span>
        <span class="spacer" />
        {markdown || svg ? (
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
      ) : svg && !source ? (
        <SvgPreview text={text} name={name} />
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
