// The Files tree's own clipboard (this page only; the system clipboard is never read): Copy or Cut
// takes the paths picked at that moment, Paste puts them in a folder (fs_copy with unique: the core
// names a clash "name copy"; a cut: rename_path, a clash refused, never renamed), Duplicate copies
// each beside itself. Pure: Files.tsx runs the commands. No DOM.

import { folderLabel, newTarget, parentOf } from "./filetree.ts";

export interface Clip {
  mode: "copy" | "cut";
  root: string; // the tree it was taken in (another root: the clip is dropped)
  paths: string[]; // outermost, in the tree's order
}

const baseName = (path: string): string => path.slice(path.lastIndexOf("/") + 1);
const under = (path: string, dir: string): boolean => path === dir || path.startsWith(dir + "/");

// Where a paste goes: the selected folder, else the selected file's folder, else the root.
export const pasteTarget = (root: string, sel: string, selIsDir: boolean): string => newTarget(root, sel, selIsDir);

// The paths a copy or cut keeps: one inside another goes with it. None: no clip.
export function clipOf(mode: Clip["mode"], root: string, paths: string[]): Clip | null {
  const out: string[] = [];
  for (const p of paths) if (!out.includes(p) && !paths.some((o) => o !== p && p.startsWith(o + "/"))) out.push(p);
  return out.length ? { mode, root, paths: out } : null;
}

// A row shown dimmed: cut (or inside a cut folder), in this tree.
export function clipCut(c: Clip | null, root: string, path: string): boolean {
  return !!c && c.mode === "cut" && c.root === root && c.paths.some((p) => under(path, p));
}

// The phone's bar: "a.txt copied", "3 items cut".
export function clipLabel(c: Clip | null): string {
  if (!c) return "";
  return (c.paths.length === 1 ? baseName(c.paths[0]) : `${c.paths.length} items`) + (c.mode === "cut" ? " cut" : " copied");
}

// The fs_copy calls a paste (dir) or a duplicate (dir null: each beside itself) makes, in order; or
// why not. to: the copy's path as asked; the core makes it unique and says which.
export interface CopyPlan {
  copies: { from: string; to: string }[];
  why: string;
}

export function planCopy(root: string, sources: string[], dir: string | null): CopyPlan {
  const no = (why: string): CopyPlan => ({ copies: [], why });
  if (!sources.length) return no("Nothing to copy");
  if (sources.some((x) => !x.startsWith(root + "/"))) return no("That item is outside the project");
  if (dir !== null && !under(dir, root)) return no("That folder is outside the project");
  const copies: CopyPlan["copies"] = [];
  for (const s of clipOf("copy", root, sources)!.paths) {
    if (dir === null) {
      copies.push({ from: s, to: s });
      continue;
    }
    if (under(dir, s)) return no(`Can't copy ${baseName(s)} into itself`);
    copies.push({ from: s, to: dir + "/" + baseName(s) });
  }
  return { copies, why: "" };
}

const itemsWord = (paths: string[]): string => (paths.length === 1 ? baseName(paths[0]) : `${paths.length} items`);

// "Copying 3 items…" while it runs (one at a time).
export const copyingText = (sources: string[], dup: boolean): string => `${dup ? "Duplicating" : "Copying"} ${itemsWord(sources)}…`;

// When it is done: "Copied 3 items to src/" (dir null: "Duplicated 3 items"), then what the core
// left out (its relative paths, a few named); stopped: what was copied, the item and the core's
// words, how many were not tried.
export function copyResult(root: string, dir: string | null, total: number, done: string[], skipped: string[], failed?: { from: string; error: string }): string {
  let s = "";
  if (done.length) s = dir === null ? `Duplicated ${itemsWord(done)}` : `Copied ${itemsWord(done)} to ${folderLabel(root, dir)}`;
  if (skipped.length) s += "; left out: " + (skipped.length <= 4 ? skipped.join(", ") : skipped.slice(0, 3).join(", ") + ` and ${skipped.length - 3} more`);
  if (!failed) return s;
  const left = total - done.length - 1;
  const why = `Could not copy ${baseName(failed.from)}: ${failed.error}` + (left > 0 ? `; ${left} not copied` : "");
  return s ? `${s}. ${why}` : why;
}

// The copy's path as the tree names it: the core answers the resolved path (a symlinked root
// differs), so its name in the folder asked.
export const copiedPath = (asked: string, answered: string): string => parentOf(asked) + "/" + baseName(answered || asked);

// A paste or duplicate run: one fs_copy at a time (the core runs one copy at a time), in order,
// stopping at the first it refuses or that fails midway (its words). waiting: the confirmation
// bar asks about one (it runs when answered; the rest are not copied).
export interface CopyRun {
  done: { from: string; path: string }[];
  skipped: string[];
  failed?: { from: string; error: string };
  waiting?: boolean;
}

export async function runCopies(run: (c: object) => Promise<{ ok: boolean; error?: string; data?: any }>, copies: CopyPlan["copies"]): Promise<CopyRun> {
  const out: CopyRun = { done: [], skipped: [] };
  for (const c of copies) {
    const r = await run({ type: "fs_copy", from: c.from, to: c.to, unique: true });
    if (r.error === "needs_confirmation") {
      out.waiting = true;
      break;
    }
    const d = typeof r.data === "string" ? JSON.parse(r.data) : (r.data ?? {});
    if (!r.ok) {
      out.failed = { from: c.from, error: r.error || "refused" };
      break;
    }
    out.done.push({ from: c.from, path: copiedPath(c.to, String(d.path ?? "")) });
    // a credential left out is named as one, never by its path (as the window says it)
    for (const s of d.skipped ?? []) if (typeof s?.path === "string") out.skipped.push(String(s.why ?? "").startsWith("a credential") ? "a credential" : s.path);
  }
  return out;
}
