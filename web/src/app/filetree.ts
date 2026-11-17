// The Files tab's tree as data (Files.tsx draws it): its rows from the folders listed and opened,
// the inline name field's place, moving the selection with the keys, the git letter and colour (the
// window's: files_git_letter, src/core/files.odin; files_git_color, src/ui_files.odin). No DOM.

export interface Entry {
  name: string;
  kind: "file" | "dir" | "symlink";
  git?: string;
  ignored?: boolean;
}

export interface Listing {
  entries: Entry[];
  err: string;
  hash?: string;
}

// The inline name field: a new file or folder in dir (its first child), or a rename of path.
export type Edit = { kind: "file" | "dir"; dir: string; err: string } | { kind: "rename"; path: string; err: string };

export type Row =
  | { t: "entry"; path: string; e: Entry; depth: number }
  | { t: "new"; dir: string; kind: "file" | "dir"; depth: number }
  | { t: "err"; at: string; text: string; depth: number; edit?: boolean } // a folder (at) that cannot be listed, or the field's error (at: its folder or path)
  | { t: "wait"; at: string; depth: number }; // listing the folder at…

// The rows: folders first as listed, an open folder's children under it; the new-name field as
// the first child of its folder (the folder open), its error under it.
export function treeRows(root: string, listed: Map<string, Listing>, open: Set<string>, edit: Edit | null): Row[] {
  const rows: Row[] = [];
  const walk = (dir: string, depth: number) => {
    if (edit && edit.kind !== "rename" && edit.dir === dir) {
      rows.push({ t: "new", dir, kind: edit.kind, depth });
      if (edit.err) rows.push({ t: "err", at: dir, text: edit.err, depth, edit: true });
    }
    const l = listed.get(dir);
    if (!l) return void rows.push({ t: "wait", at: dir, depth });
    if (l.err) return void rows.push({ t: "err", at: dir, text: l.err, depth });
    for (const e of l.entries) {
      const path = dir + "/" + e.name;
      rows.push({ t: "entry", path, e, depth });
      if (edit && edit.kind === "rename" && edit.path === path && edit.err) rows.push({ t: "err", at: path, text: edit.err, depth, edit: true });
      if (e.kind === "dir" && open.has(path)) walk(path, depth + 1);
    }
  };
  walk(root, 0);
  return rows;
}

export const isDir = (r: Row | undefined): boolean => r?.t === "entry" && r.e.kind === "dir";

// A row's key in the windowed list: unique in the tree.
export function rowKey(r: Row): string {
  switch (r.t) {
    case "entry": return r.path;
    case "new": return "new:" + r.dir;
    case "err": return (r.edit ? "edit-err:" : "err:") + r.at;
    case "wait": return "wait:" + r.at;
  }
}

// The name field's row (a new name, or the row being renamed): always drawn (Windowed keep).
export function isEditRow(r: Row, edit: Edit | null = null): boolean {
  return r.t === "new" || (r.t === "entry" && edit?.kind === "rename" && edit.path === r.path);
}

// The folders between root and path (not path itself), outermost first: what to open to show it.
export function parentsOf(root: string, path: string): string[] {
  if (!path.startsWith(root + "/")) return [];
  const out: string[] = [];
  let at = root;
  for (const part of path.slice(root.length + 1).split("/").slice(0, -1)) {
    at += "/" + part;
    out.push(at);
  }
  return out;
}

export const parentOf = (path: string): string => path.slice(0, path.lastIndexOf("/"));

export function relPath(root: string, path: string): string {
  return path.startsWith(root + "/") ? path.slice(root.length + 1) : path;
}

// Where New file / New folder go from the selection: a folder itself, a file's folder, else root.
export function newTarget(root: string, sel: string, selIsDir: boolean): string {
  if (!sel || !(sel === root || sel.startsWith(root + "/"))) return root;
  return selIsDir ? sel : parentOf(sel);
}

// The part of a name a rename selects: the stem (up to the last dot, not a leading one).
export function stemEnd(name: string, dir: boolean): number {
  if (dir) return name.length;
  const dot = name.lastIndexOf(".");
  return dot > 0 ? dot : name.length;
}

// The selection after a key, by row index among the entries (-1: none). Keys: ArrowUp, ArrowDown,
// Home, End, ArrowLeft (a folder's parent), ArrowRight (an open folder's first child).
export function moveSel(rows: Row[], sel: string, key: string, open: Set<string>): string {
  const entries = rows.flatMap((r) => (r.t === "entry" ? [r] : []));
  if (!entries.length) return "";
  const i = entries.findIndex((r) => r.path === sel);
  switch (key) {
    case "Home": return entries[0].path;
    case "End": return entries[entries.length - 1].path;
    case "ArrowDown": return i < 0 ? entries[0].path : entries[Math.min(i + 1, entries.length - 1)].path;
    case "ArrowUp": return i < 0 ? entries[entries.length - 1].path : entries[Math.max(i - 1, 0)].path;
    case "ArrowLeft": {
      if (i < 0) return entries[0].path;
      const up = parentOf(sel);
      return entries.some((r) => r.path === up) ? up : sel;
    }
    case "ArrowRight": {
      if (i < 0) return entries[0].path;
      const next = entries[i + 1];
      return entries[i].e.kind === "dir" && open.has(sel) && next && parentOf(next.path) === sel ? next.path : sel;
    }
  }
  return sel;
}

// The window's git letter for a porcelain code: "M", "A", "U" (untracked), "D", "R", "!"
// (conflict), and "•" on a folder with changes inside.
export function gitLetter(code: string | undefined, dir: boolean): string {
  if (!code) return "";
  if (dir) return code === "??" ? "U" : "•";
  if (code === "??") return "U";
  const x = code[0], y = code.length > 1 ? code[1] : " ";
  if (x === "U" || y === "U" || (x === "A" && y === "A") || (x === "D" && y === "D")) return "!";
  if (x === "D" || y === "D") return "D";
  if (x === "R") return "R";
  if (x === "A") return "A";
  return "M";
}

// Its colour, as the window's: added and untracked green (done), modified amber (waiting), deleted
// and conflicted red (error). A class: g-add, g-mod, g-del; "" none.
export function gitTone(letter: string): string {
  switch (letter) {
    case "A": case "U": return "g-add";
    case "M": case "R": case "•": return "g-mod";
    case "D": case "!": return "g-del";
  }
  return "";
}

// ---- the selection (several rows) ----
// The rows picked (paths), and the anchor a shift-range runs from. The focused row (Files.tsx sel)
// is where the keys act; it is in the picked rows unless nothing is picked. order: the entry rows'
// paths as drawn, top to bottom.
export interface Pick {
  paths: Set<string>;
  anchor: string;
}

export const entryPaths = (rows: Row[]): string[] => rows.flatMap((r) => (r.t === "entry" ? [r.path] : []));

export const pickOne = (path: string): Pick => ({ paths: new Set(path ? [path] : []), anchor: path });

// The rows from a to b, inclusive, in either direction; a not drawn: b alone.
export function rangeOf(order: string[], a: string, b: string): string[] {
  const j = order.indexOf(b);
  if (j < 0) return [];
  const i = order.indexOf(a);
  if (i < 0) return [b];
  return order.slice(Math.min(i, j), Math.max(i, j) + 1);
}

// A click: plain picks the row alone; toggle (⌘/Ctrl) adds or removes it, and it becomes the
// anchor; range (shift) picks anchor..row (with toggle too: added to what is picked); the anchor
// stays.
export function clickPick(order: string[], p: Pick, path: string, mods: { toggle: boolean; range: boolean }): Pick {
  if (mods.range && p.anchor && order.includes(p.anchor)) {
    const span = rangeOf(order, p.anchor, path);
    return { paths: new Set(mods.toggle ? [...p.paths, ...span] : span), anchor: p.anchor };
  }
  if (mods.toggle) {
    const paths = new Set(p.paths);
    if (paths.has(path)) paths.delete(path);
    else paths.add(path);
    return { paths, anchor: path };
  }
  return pickOne(path);
}

// Shift and an arrow (or Home, End): the focus moved to `to`, the picked rows anchor..to.
export function extendPick(order: string[], p: Pick, from: string, to: string): Pick {
  const anchor = p.anchor && order.includes(p.anchor) ? p.anchor : from || to;
  return { paths: new Set(rangeOf(order, anchor, to)), anchor };
}

// What is still drawn (the tree listed again; a folder closed): rows that went drop out.
export function prunePick(order: string[], p: Pick): Pick {
  const drawn = new Set(order);
  if ([...p.paths].every((x) => drawn.has(x))) return p;
  return { paths: new Set([...p.paths].filter((x) => drawn.has(x))), anchor: drawn.has(p.anchor) ? p.anchor : "" };
}

// The picked rows in drawn order, a row inside another picked folder left out (trashing the folder
// trashes it).
export function outermost(order: string[], paths: Set<string>): string[] {
  const out: string[] = [];
  for (const x of order) {
    if (!paths.has(x)) continue;
    if (out.some((o) => x.startsWith(o + "/"))) continue;
    out.push(x);
  }
  return out;
}

// Type-to-select: the next row whose name starts with the typed prefix (any case), from the
// focused row (one letter: from the row after it, so typing it again cycles), wrapping; "" none.
export function typeMatch(rows: Row[], from: string, prefix: string): string {
  const entries = rows.flatMap((r) => (r.t === "entry" ? [r] : []));
  if (!entries.length || !prefix) return "";
  const want = prefix.toLowerCase();
  // the same letter typed again ("ss"): cycle through the rows starting with it
  const cycle = [...want].every((c) => c === want[0]);
  const key = cycle ? want[0] : want;
  const at = entries.findIndex((r) => r.path === from);
  const start = at < 0 ? 0 : cycle ? at + 1 : at;
  for (let k = 0; k < entries.length; k++) {
    const r = entries[(start + k) % entries.length];
    if (r.e.name.toLowerCase().startsWith(key)) return r.path;
  }
  return "";
}

// The letters typed for type-to-select: a pause (ms) starts a new prefix.
export const TYPE_PAUSE = 1000;
export function typed(buf: { text: string; at: number }, ch: string, now: number): { text: string; at: number } {
  return { text: (now - buf.at > TYPE_PAUSE ? "" : buf.text) + ch, at: now };
}

// What Delete trashes (as the window's tree, src/ui_files.odin files_key): the picked rows when
// several are picked, or when the focus is off them (⌘-clicked out: what shows selected goes, and
// the confirmation names it); else the focused row. Outermost only.
export function trashTargets(order: string[], p: Pick, focus: string): string[] {
  const loose = p.paths.size > 0 && !!focus && !p.paths.has(focus);
  if (p.paths.size > 1 || loose) return outermost(order, p.paths);
  return focus ? [focus] : [];
}

// ---- moving (rename_path into another folder; the core refuses what it refuses) ----

const baseName = (path: string): string => path.slice(path.lastIndexOf("/") + 1);

// The folder a drop goes into: a folder row itself, a file row's folder, empty space the root.
export function dropDir(root: string, row: { path: string; dir: boolean } | null): string {
  if (!row) return root;
  return row.dir ? row.path : parentOf(row.path);
}

// A move into dir: the renames to make, or why not (why: one line naming the item). Sources inside
// another source go with it; a source already in dir is left where it is (all of them: not a
// target). listing: dir's entries when known (a name already there refuses the lot, before
// anything moves; not known: the core refuses it when it gets there).
export interface MovePlan {
  moves: { from: string; to: string }[];
  why: string;
}

export function planMove(root: string, sources: string[], dir: string, listing?: Listing): MovePlan {
  const no = (why: string): MovePlan => ({ moves: [], why });
  if (!sources.length) return no("Nothing to move");
  if (dir !== root && !dir.startsWith(root + "/")) return no("That folder is outside the project");
  const outer = [...new Set(sources)].sort((a, b) => a.length - b.length).filter((s, i, all) => !all.slice(0, i).some((o) => s.startsWith(o + "/")));
  const have = listing && !listing.err ? new Set(listing.entries.map((e) => e.name)) : null;
  const names = new Set<string>();
  const moves: MovePlan["moves"] = [];
  for (const s of sources.filter((x, i) => outer.includes(x) && sources.indexOf(x) === i)) {
    const n = baseName(s);
    if (dir === s || dir.startsWith(s + "/")) return no(`Can't move ${n} into itself`);
    if (parentOf(s) === dir) continue;
    if (names.has(n)) return no(`Two of them are named ${n}`);
    names.add(n);
    if (have?.has(n)) return no(`${n} already exists in ${folderLabel(root, dir)}`);
    moves.push({ from: s, to: dir + "/" + n });
  }
  if (!moves.length) return no(sources.length > 1 ? "They are already there" : `${baseName(sources[0])} is already there`);
  return { moves, why: "" };
}

// A folder as a move names it: "src/deep/", the root by its name ("proj/").
export function folderLabel(root: string, dir: string): string {
  return (dir === root ? baseName(root) : relPath(root, dir)) + "/";
}

// What a move says when it is done: "Moved a.txt to src/", "Moved 3 items to src/"; stopped at a
// refusal: what moved, then the item refused and the core's words.
export function moveResult(root: string, dir: string, done: string[], failed?: { from: string; error: string }): string {
  const to = folderLabel(root, dir);
  const moved = done.length === 1 ? `Moved ${baseName(done[0])} to ${to}` : `Moved ${done.length} items to ${to}`;
  if (!failed) return moved;
  const why = `Could not move ${baseName(failed.from)}: ${failed.error}`;
  return done.length ? `${moved}. ${why}` : why;
}

// A path after from moved to to (at or under from: follows it; else unchanged).
export function movedPath(path: string, from: string, to: string): string {
  return path === from || path.startsWith(from + "/") ? to + path.slice(from.length) : path;
}

// The Move to… picker's rows: the root first, then folders only (symlinks left out), an open
// folder's folders under it. wait: opened, not listed yet; err: cannot be listed.
export interface FolderRow {
  path: string;
  name: string;
  depth: number;
  open: boolean;
  state: "listed" | "wait" | "err";
  kids: boolean; // has folders inside (when listed), or not known yet
}

export function folderRows(root: string, listed: Map<string, Listing>, open: Set<string>): FolderRow[] {
  const rows: FolderRow[] = [];
  const state = (d: string): FolderRow["state"] => {
    const l = listed.get(d);
    return !l ? "wait" : l.err ? "err" : "listed";
  };
  const kids = (d: string): boolean => {
    const l = listed.get(d);
    return !l || (!l.err && l.entries.some((e) => e.kind === "dir"));
  };
  const walk = (dir: string, depth: number) => {
    const l = listed.get(dir);
    if (!l || l.err) return;
    for (const e of l.entries) {
      if (e.kind !== "dir") continue;
      const path = dir + "/" + e.name;
      const on = open.has(path);
      rows.push({ path, name: e.name, depth, open: on, state: state(path), kids: kids(path) });
      if (on) walk(path, depth + 1);
    }
  };
  rows.push({ path: root, name: baseName(root), depth: 0, open: true, state: state(root), kids: true });
  walk(root, 1);
  return rows;
}
