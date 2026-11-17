// The Files tree's copy, cut, paste, duplicate and undo, run against the core (Files.tsx hands in
// its tree as a Tree; the rules are fileclip.ts and fileundo.ts). Page-local state: the clip, the
// undo stack, a copy running. Cleared when the tree's session, project or folder changes; gone on a
// reload.

import { dragText } from "./filetree.ts";
import { clipCut, clipLabel, clipOf, copyingText, copyResult, planCopy, runCopies, type Clip } from "./fileclip.ts";
import { lookFor, runUndo, statOf, undoCheck, undoLabel, UndoStack, type UndoOp, type UndoRec } from "./fileundo.ts";
import { IS_MAC, type App, type MenuItem, type ToastAction } from "./ctx.ts";
import type { Result } from "../link.ts";

// What the tree gives these: its folder, a path's kind as listed, rows to select once drawn (their
// folders opened), what was open under a moved folder follows it, a re-list, a redraw, its move.
export interface Tree {
  app: App;
  root: string;
  kindOf(path: string): string;
  select(paths: string[]): void;
  follow(from: string, to: string): void;
  refresh(): void;
  bump(): void;
  moveTo(sources: string[], dir: string): Promise<number | void>;
}

let clip: Clip | null = null;
const undos = new UndoStack();
let copying = false;
let undoing = false;
let scope = ""; // the session, project and folder the clip and the stack belong to
let scopeRoot = "";

// A new session, project or folder: the clip and the undo stack are another tree's.
export function resetFor(key: string, root: string): void {
  if (key === scope) return;
  scope = key;
  scopeRoot = root;
  clip = null;
  undos.clear();
}

export const hasClip = (): boolean => !!clip;
export const isCut = (root: string, path: string): boolean => clipCut(clip, root, path);
export const clipText = (): string => clipLabel(clip);
export const undoTop = (): string => (undos.top() ? undoLabel(undos.top()!.op) : "");

export function clearClip(t: Tree): void {
  clip = null;
  t.bump();
}

// Esc in the tree: a cut is called off (its rows undimmed). true: it was one.
export function cancelCut(t: Tree): boolean {
  if (clip?.mode !== "cut") return false;
  clearClip(t);
  return true;
}

// Copy or Cut: the paths picked now. A copy also puts them, shell-quoted, on the system clipboard
// as text (a secure context only; never read back).
export function take(t: Tree, mode: Clip["mode"], paths: string[]): void {
  clip = clipOf(mode, t.root, paths);
  if (!clip) return;
  if (mode === "copy" && systemClip()) navigator.clipboard.writeText(dragText(clip.paths)).catch(() => {});
  // the tree's own paste (a phone: its bar says it); never a word about the system clipboard
  if (!t.app.phone) t.app.toast(clipLabel(clip) + ` · paste in the tree with ${IS_MAC ? "⌘V" : "Ctrl+V"}`);
  t.bump();
}

// The system clipboard can be written (a secure page): else ⌘C is left to the browser too.
const systemClip = (): boolean => !!navigator.clipboard && window.isSecureContext;

// Paste into dir: a copy copies (a clash named "name copy" by the core); a cut moves (a name
// already there refuses it, never renamed) and is done once anything moved.
export async function paste(t: Tree, dir: string): Promise<void> {
  const c = clip;
  if (!c || c.root !== t.root) return void t.app.toast("Nothing to paste", true);
  if (c.mode === "copy") return copyInto(t, c.paths, dir);
  const moved = await t.moveTo(c.paths, dir);
  if (moved && clip === c) clearClip(t);
}

export const duplicate = (t: Tree, paths: string[]): Promise<void> => copyInto(t, paths, null);

// Copies into dir (null: each beside itself), one fs_copy at a time, then selects the copies; the
// toast names what the core left out and offers Undo.
export async function copyInto(t: Tree, sources: string[], dir: string | null): Promise<void> {
  const { app, root } = t;
  if (copying) return void app.toast("A copy is still running; paste again when it is done", true);
  const plan = planCopy(root, sources, dir);
  if (plan.why) return void app.toast(plan.why, true);
  copying = true;
  try {
    app.toast(copyingText(plan.copies.map((c) => c.from), dir === null));
    const out = await runCopies((cmd) => app.link.run(cmd), plan.copies);
    let action: ToastAction | undefined;
    if (out.done.length) {
      const items: Extract<UndoOp, { kind: "copy" }>["items"] = [];
      for (const d of out.done) {
        const isDir = t.kindOf(d.from) === "dir";
        const stat = isDir ? null : await statOf((cmd) => app.link.run(cmd), d.path);
        items.push({ path: d.path, dir: isDir, ...(stat ? { stat } : {}) });
      }
      action = undoAction(t, push(t, { kind: "copy", items, ...(dir === null ? { dup: true } : {}) }));
      t.select(out.done.map((d) => d.path));
    }
    const text = out.waiting && !out.failed ? copyResult(root, dir, plan.copies.length, out.done.map((d) => d.from), out.skipped) + (out.done.length ? ". " : "") + "Waiting for confirmation" : copyResult(root, dir, plan.copies.length, out.done.map((d) => d.from), out.skipped, out.failed);
    app.toast(text, !!out.failed, action);
    t.refresh();
  } finally {
    copying = false;
  }
}

function push(t: Tree, op: UndoOp): UndoRec {
  return undos.push(t.root, op);
}

function undoAction(t: Tree, rec: UndoRec): ToastAction {
  return { label: "Undo", run: () => void undo(t, rec) };
}

// A rename or move done by the tree: its undo, the toast's action.
export function moved(t: Tree, moves: { from: string; to: string }[], rename = false): ToastAction | undefined {
  if (!moves.length) return undefined;
  return undoAction(t, push(t, { kind: "move", moves: moves.map((m) => ({ from: m.from, to: m.to })), ...(rename ? { rename: true } : {}) }));
}

// A new file or folder made by the tree: its stat taken now (a file), so an undo can tell it is
// still as it was made; the toast offers Undo.
export async function created(t: Tree, path: string, dir: boolean): Promise<void> {
  const stat = dir ? null : await statOf((cmd) => t.app.link.run(cmd), path);
  const rec = push(t, { kind: "create", path, dir, ...(stat ? { stat } : {}) });
  t.app.toast(`Created ${path.slice(path.lastIndexOf("/") + 1)}`, false, undoAction(t, rec));
}

// The tree's delete waits in the confirmation bar (the user always confirms there): its token,
// so the bar's answer can be matched to it (confirmed).
export function deleting(r: Result, paths: string[]): void {
  const tok = r.needs_confirmation?.token;
  if (!r.ok && r.error === "needs_confirmation" && tok && scopeRoot) undos.askedDelete(tok, scopeRoot, paths);
}

// The confirmation bar ran a command (deckhand:fs-changed's detail): the tree's own delete gets an
// Undo with the ids the core returned; an undo that waited there leaves the stack.
export function confirmed(t: Tree, detail: unknown): void {
  const d = detail as { token?: unknown; result?: Result } | null;
  if (!d || typeof d.token !== "string" || !d.result) return;
  const c = undos.confirmed(d.token, d.result);
  if (!c) return;
  if (c.kind === "pushed" && c.rec.op.kind === "delete") {
    const n = c.rec.op.restore.length;
    const name = c.rec.op.restore[0].path;
    t.app.toast(`Moved ${n === 1 ? name.slice(name.lastIndexOf("/") + 1) : n + " items"} to the Trash`, false, undoAction(t, c.rec));
  } else if (c.kind === "undone") t.app.toast("Undone: " + undoLabel(c.rec.op).replace(/^Undo /, ""));
}

// ⌘/Ctrl-Z, the toast's Undo, the menu's Undo: the newest (or that one), after looking that
// nothing changed since.
export async function undo(t: Tree, rec?: UndoRec): Promise<void> {
  const { app } = t;
  const r = rec ?? undos.top();
  if (!r) return void app.toast("Nothing to undo");
  if (!undos.has(r) || r.root !== t.root) return void app.toast("That can no longer be undone", true);
  if (undoing) return;
  // its Trash already waits in the confirmation bar: never a second one (cancelled there: asked again)
  const tok = undos.waitingFor(r);
  if (tok && app.store.confirmations.some((c: { token?: string }) => c.token === tok)) return void app.toast("Waiting for you to confirm it in the bar");
  if (tok) undos.forget(tok);
  undoing = true;
  try {
    const run = (cmd: object) => app.link.run(cmd);
    const why = undoCheck(r.op, await lookFor(run, r.op));
    if (why) {
      undos.remove(r);
      return void app.toast(`Can't undo: ${why}`, true);
    }
    const out = await runUndo(run, r.op);
    if (out.token) undos.askedUndo(out.token, r); // the confirmation bar asks (it may be cancelled: then it stays)
    if (out.done) undos.remove(r);
    for (const [from, to] of out.moved ?? []) t.follow(from, to);
    if (out.select.length) t.select(out.select);
    if (out.text) app.toast(out.text, out.err);
    t.refresh();
  } finally {
    undoing = false;
  }
}

// A key the Files tree takes before the page's shortcuts: ⌘D (Split pane right elsewhere) on a
// focused row.
export function treeTakes(e: KeyboardEvent): boolean {
  const row = (e.target as HTMLElement | null)?.closest?.(".files-tree .file-row");
  return !!row && (IS_MAC ? e.metaKey : e.ctrlKey) && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "d";
}

// The tree's keys with ⌘/Ctrl (no shift, no option) while a row has focus: C copies, X cuts, V
// pastes into target, D duplicates, Z undoes. true: taken (the browser's own then prevented).
export function treeKey(t: Tree, key: string, paths: string[], target: string): boolean {
  switch (key) {
    case "c": take(t, "copy", paths); return systemClip(); // not secure: the browser's own copy is not stopped
    case "x": take(t, "cut", paths); return true;
    case "v": void paste(t, target); return true;
    case "d": void duplicate(t, paths); return true;
    case "z": void undo(t); return true;
  }
  return false;
}

const K = IS_MAC ? "⌘" : "Ctrl+";

// A row's menu (or several rows'): Copy, Cut, Duplicate; Paste into into when something is held
// (a folder: "Paste here"; a file: its folder).
export function clipItems(t: Tree, paths: string[], into: string, intoRow: boolean): MenuItem[] {
  const keys = (k: string) => (t.app.phone ? undefined : K + k);
  const items: MenuItem[] = [
    { label: "Copy", keys: keys("C"), run: () => take(t, "copy", paths) },
    { label: "Cut", keys: keys("X"), run: () => take(t, "cut", paths) },
    { label: "Duplicate", keys: keys("D"), run: () => void duplicate(t, paths) },
  ];
  if (clip && into) items.push({ label: intoRow ? "Paste here" : "Paste", keys: keys("V"), run: () => void paste(t, into) });
  return items;
}

// The root's menu (the header's "…"): Paste here, and Undo of the newest; a separator after.
export function rootClipItems(t: Tree): MenuItem[] {
  const items: MenuItem[] = [];
  if (clip) items.push({ label: "Paste here", run: () => void paste(t, t.root) });
  if (undos.top()) items.push({ label: undoLabel(undos.top()!.op), keys: t.app.phone ? undefined : K + "Z", run: () => void undo(t) });
  return items.length ? [...items, { sep: true }] : [];
}
