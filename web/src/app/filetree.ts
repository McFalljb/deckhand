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

// At most this many rows trashed at once (the core's own limit).
export const TRASH_MAX = 500;
