// The Files tree's undo: the last 20 operations done from this page's tree (new file or folder,
// rename, move, copy and duplicate, move to the Trash), newest first, kept in the page only (gone
// on a reload, and cleared when the tree's folder changes). No redo.
//
// Each undo looks first and refuses what changed since (undoCheck): a new file only while it is
// as it was made (file_read's size and modification time: list_dir's entries carry neither), a new
// folder only while it is empty, a move or rename back only while the item is where it went and
// nothing is where it was, a copy only while each copy is there (a copied file as it was copied).
// Then: a new item or a copy goes to the Trash (delete_path: the confirmation bar asks, as for any
// delete); a move or rename goes back (rename_path; the core refuses a taken name); a delete is put
// back by restore_path with the ids the core returned to this page for that delete (the core
// checks the place is free and the item is the one it put in the Trash). The bar's answer comes
// back by its token (confirmed): the tree's own delete then gets its undo; an undo waiting there
// leaves the stack. Files.tsx runs it; no DOM.

import type { Result } from "../link.ts";
import { parentOf } from "./filetree.ts";

export interface Stat {
  size: number;
  mtime: number;
}

export type UndoOp =
  | { kind: "create"; path: string; dir: boolean; stat?: Stat }
  | { kind: "move"; moves: { from: string; to: string }[]; rename?: boolean }
  | { kind: "copy"; items: { path: string; dir: boolean; stat?: Stat }[]; dup?: boolean }
  | { kind: "delete"; restore: { path: string; id: string }[] };

export interface UndoRec {
  op: UndoOp;
  root: string;
  n: number;
}

export type Run = (command: object) => Promise<Result>;

export const UNDO_MAX = 20;
const baseName = (path: string): string => path.slice(path.lastIndexOf("/") + 1);
const itemsWord = (paths: string[]): string => (paths.length === 1 ? baseName(paths[0]) : `${paths.length} items`);
const json = (d: unknown): any => {
  try {
    return typeof d === "string" ? JSON.parse(d) : (d ?? {});
  } catch {
    return {};
  }
};

// The confirmation bar's answer to a command this tree sent (by its token).
export type Confirmed = { kind: "pushed"; rec: UndoRec } | { kind: "none" } | { kind: "undone"; rec: UndoRec } | { kind: "failed"; rec: UndoRec; error: string };

export class UndoStack {
  private recs: UndoRec[] = [];
  private asked = new Map<string, { kind: "delete"; root: string; paths: string[] } | { kind: "undo"; rec: UndoRec }>();
  private n = 0;

  push(root: string, op: UndoOp): UndoRec {
    const rec = { op, root, n: ++this.n };
    this.recs.push(rec);
    if (this.recs.length > UNDO_MAX) this.recs.shift();
    return rec;
  }
  top(): UndoRec | undefined {
    return this.recs[this.recs.length - 1];
  }
  has(rec: UndoRec): boolean {
    return this.recs.includes(rec);
  }
  remove(rec: UndoRec): void {
    this.recs = this.recs.filter((r) => r !== rec);
  }
  clear(): void {
    this.recs = [];
    this.asked.clear();
  }
  get size(): number {
    return this.recs.length;
  }
  // The tree's delete waits in the confirmation bar (paths: as the tree sent them).
  askedDelete(token: string, root: string, paths: string[]): void {
    this.asked.set(token, { kind: "delete", root, paths });
  }
  // An undo (a Trash) waits there.
  askedUndo(token: string, rec: UndoRec): void {
    this.asked.set(token, { kind: "undo", rec });
  }
  // The token an undo waits on in the confirmation bar ("" none).
  waitingFor(rec: UndoRec): string {
    for (const [tok, a] of this.asked) if (a.kind === "undo" && a.rec === rec) return tok;
    return "";
  }
  // A token the bar no longer holds (cancelled there): forgotten.
  forget(token: string): void {
    this.asked.delete(token);
  }
  // The bar's confirmed command answered (this page sent it): null when it was none of this tree's.
  confirmed(token: string, r: Result): Confirmed | null {
    const a = this.asked.get(token);
    if (!a) return null;
    this.asked.delete(token);
    if (a.kind === "undo") {
      if (!r.ok) return { kind: "failed", rec: a.rec, error: r.error || "refused" };
      this.remove(a.rec);
      return { kind: "undone", rec: a.rec };
    }
    const got: { path: string; id: string }[] = Array.isArray(json(r.data).restore) ? json(r.data).restore : [];
    const restore = got.filter((x) => typeof x?.id === "string" && typeof x?.path === "string").map((x) => ({ path: treePath(a.root, a.paths, x.path), id: x.id }));
    if (!restore.length) return { kind: "none" };
    return { kind: "pushed", rec: this.push(a.root, { kind: "delete", restore }) };
  }
}

// A path the core answered (resolved: a symlinked root differs) as the tree named it: the sent path
// it ends with.
function treePath(root: string, sent: string[], core: string): string {
  if (core.startsWith(root + "/")) return core;
  let best = "";
  for (const p of sent) {
    const rel = p.slice(root.length);
    if (core.endsWith(rel) && rel.length > best.length - root.length) best = p;
  }
  return best || core;
}

export function undoLabel(op: UndoOp): string {
  switch (op.kind) {
    case "create": return `Undo new ${op.dir ? "folder" : "file"} ${baseName(op.path)}`;
    case "move": return op.rename ? `Undo rename of ${baseName(op.moves[0].from)}` : `Undo move of ${itemsWord(op.moves.map((m) => m.from))}`;
    case "copy": return `Undo ${op.dup ? "duplicate" : "copy"} ${itemsWord(op.items.map((i) => i.path))}`;
    case "delete": return `Undo move of ${itemsWord(op.restore.map((x) => x.path))} to the Trash`;
  }
}

// What is there now: each path's kind (null: nothing there), a file's stat, a folder's emptiness.
export interface Look {
  kinds: Map<string, string | null>;
  stats: Map<string, Stat | null>;
  empty: Map<string, boolean>;
}

export async function statOf(run: Run, path: string): Promise<Stat | null> {
  const r = await run({ type: "file_read", path });
  if (!r.ok) return null;
  const d = json(r.data);
  return typeof d.size === "number" && typeof d.mtime === "number" ? { size: d.size, mtime: d.mtime } : null;
}

// Looks before an undo: each folder holding a path listed (ignored names too), files read for their
// stat, a new folder listed for its emptiness.
export async function lookFor(run: Run, op: UndoOp): Promise<Look> {
  const look: Look = { kinds: new Map(), stats: new Map(), empty: new Map() };
  const paths: string[] = [];
  const stat: string[] = [];
  if (op.kind === "create") {
    paths.push(op.path);
    if (!op.dir) stat.push(op.path);
  } else if (op.kind === "move") for (const m of op.moves) paths.push(m.to, m.from);
  else if (op.kind === "copy") for (const i of op.items) {
    paths.push(i.path);
    if (i.stat) stat.push(i.path);
  }
  const dirs = [...new Set(paths.map(parentOf))];
  for (const d of dirs) {
    const r = await run({ type: "list_dir", path: d, ignored: true });
    const names = new Map<string, string>();
    if (r.ok) for (const e of json(r.data).entries ?? []) names.set(e.name, e.kind);
    for (const p of paths) if (parentOf(p) === d) look.kinds.set(p, names.get(baseName(p)) ?? null);
  }
  for (const p of stat) if (look.kinds.get(p) === "file") look.stats.set(p, await statOf(run, p));
  if (op.kind === "create" && op.dir && look.kinds.get(op.path) === "dir") {
    const r = await run({ type: "list_dir", path: op.path, ignored: true });
    look.empty.set(op.path, r.ok && (json(r.data).entries ?? []).length === 0);
  }
  return look;
}

// "" when the undo may go ahead, else why not (changed since).
export function undoCheck(op: UndoOp, look: Look): string {
  const changed = (p: string) => `${baseName(p)} changed since`;
  const sameStat = (a?: Stat, b?: Stat | null) => !!a && !!b && a.size === b.size && a.mtime === b.mtime;
  switch (op.kind) {
    case "create": {
      const k = look.kinds.get(op.path);
      if (!k) return `${baseName(op.path)} is gone`;
      if (op.dir) return k !== "dir" ? changed(op.path) : look.empty.get(op.path) ? "" : `${baseName(op.path)} is not empty now`;
      return k === "file" && sameStat(op.stat, look.stats.get(op.path)) ? "" : changed(op.path);
    }
    case "move":
      for (const m of op.moves) {
        if (!look.kinds.get(m.to)) return op.rename ? `${baseName(m.to)} is gone` : `${baseName(m.from)} is no longer in ${baseName(parentOf(m.to))}/`;
        if (look.kinds.get(m.from)) return `something is at ${baseName(m.from)} now`;
      }
      return "";
    case "copy":
      for (const i of op.items) {
        const k = look.kinds.get(i.path);
        if (!k) return `${baseName(i.path)} is gone`;
        if ((k === "dir") !== i.dir) return changed(i.path);
        if (i.stat && !sameStat(i.stat, look.stats.get(i.path))) return changed(i.path);
      }
      return "";
    case "delete":
      return ""; // the core checks (restore_path: the place free, the item the one it trashed)
  }
}

// What an undo did: its toast; done (the record leaves the stack); the rows to select; moves to
// follow (open folders); token: it waits in the confirmation bar.
export interface UndoOut {
  text: string;
  err: boolean;
  done: boolean;
  select: string[];
  moved?: [string, string][];
  token?: string;
}

export async function runUndo(run: Run, op: UndoOp): Promise<UndoOut> {
  switch (op.kind) {
    case "move": {
      const moved: [string, string][] = [];
      let fail = "";
      for (const m of [...op.moves].reverse()) {
        const r = await run({ type: "rename_path", from: m.to, to: m.from });
        if (r.ok) {
          moved.push([m.to, m.from]);
          continue;
        }
        if (r.error === "not connected" && !moved.length) return { text: "Not connected", err: true, done: false, select: [] };
        fail = `Could not ${op.rename ? "rename" : "move"} ${baseName(m.to)} back: ${r.error === "needs_confirmation" ? "waiting for confirmation" : r.error || "refused"}`;
        break;
      }
      const did = moved.map((x) => x[1]);
      const okText = op.rename ? `Renamed ${baseName(op.moves[0].to)} back to ${baseName(op.moves[0].from)}` : `Moved ${itemsWord(did)} back`;
      const text = moved.length && fail ? `${okText}. ${fail}` : moved.length ? okText : fail;
      return { text, err: !!fail, done: true, select: did, moved };
    }
    case "create": case "copy": {
      const paths = op.kind === "create" ? [op.path] : op.items.map((i) => i.path);
      const r = await run(paths.length === 1 ? { type: "delete_path", path: paths[0] } : { type: "delete_path", path: "", paths });
      if (r.ok) return { text: `Moved ${itemsWord(paths)} to the Trash`, err: false, done: true, select: [] };
      if (r.error === "needs_confirmation") return { text: "", err: false, done: false, select: [], token: r.needs_confirmation?.token };
      return { text: `Could not undo: ${r.error || "refused"}`, err: true, done: r.error !== "not connected", select: [] };
    }
    case "delete": {
      const back: string[] = [];
      let fail = "";
      for (const x of op.restore) {
        const r = await run({ type: "restore_path", id: x.id });
        if (r.ok) back.push(x.path);
        else if (!fail) fail = `Could not put ${baseName(x.path)} back: ${r.error || "refused"}`;
      }
      const okText = back.length ? `Put ${itemsWord(back)} back` : "";
      return { text: okText && fail ? `${okText}. ${fail}` : okText || fail, err: !!fail, done: true, select: back };
    }
  }
}
