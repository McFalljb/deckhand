// The Files tree's undo (src/app/fileundo.ts): the stack, what an undo checks first ("changed
// since"), the commands it sends, the confirmation bar's answer matched by token.

import { test } from "node:test";
import assert from "node:assert/strict";
import { runUndo, undoCheck, undoLabel, UndoStack, lookFor, type Look, type UndoOp } from "../src/app/fileundo.ts";

const R = "/p";
const look = (kinds: Record<string, string | null>, stats: Record<string, { size: number; mtime: number } | null> = {}, empty: Record<string, boolean> = {}): Look => ({
  kinds: new Map(Object.entries(kinds)) as Look["kinds"],
  stats: new Map(Object.entries(stats)),
  empty: new Map(Object.entries(empty)),
});

test("stack: last 20, newest on top, remove, clear (with what it waits for)", () => {
  const s = new UndoStack();
  for (let i = 0; i < 25; i++) s.push(R, { kind: "create", path: R + "/f" + i, dir: true });
  assert.equal(s.size, 20);
  const top = s.top()!;
  assert.equal((top.op as any).path, R + "/f24");
  s.remove(top);
  assert.equal((s.top()!.op as any).path, R + "/f23");
  s.askedDelete("tok", R, [R + "/a"]);
  s.clear();
  assert.equal(s.size, 0);
  assert.equal(s.confirmed("tok", { ok: true, data: { restore: [{ path: R + "/a", id: "1" }] } }), null);
});

test("labels", () => {
  assert.equal(undoLabel({ kind: "create", path: R + "/a.txt", dir: false }), "Undo new file a.txt");
  assert.equal(undoLabel({ kind: "create", path: R + "/d", dir: true }), "Undo new folder d");
  assert.equal(undoLabel({ kind: "move", moves: [{ from: R + "/a", to: R + "/b" }], rename: true }), "Undo rename of a");
  assert.equal(undoLabel({ kind: "move", moves: [{ from: R + "/a", to: R + "/s/a" }, { from: R + "/b", to: R + "/s/b" }] }), "Undo move of 2 items");
  assert.equal(undoLabel({ kind: "copy", items: [{ path: R + "/a copy", dir: false }] }), "Undo copy a copy");
  assert.equal(undoLabel({ kind: "delete", restore: [{ path: R + "/a", id: "1" }, { path: R + "/b", id: "2" }] }), "Undo move of 2 items to the Trash");
});

test("changed since: a new file is undone only while it is as it was made", () => {
  const op: UndoOp = { kind: "create", path: R + "/a.txt", dir: false, stat: { size: 0, mtime: 5 } };
  assert.equal(undoCheck(op, look({ [R + "/a.txt"]: "file" }, { [R + "/a.txt"]: { size: 0, mtime: 5 } })), "");
  assert.equal(undoCheck(op, look({ [R + "/a.txt"]: "file" }, { [R + "/a.txt"]: { size: 3, mtime: 9 } })), "a.txt changed since");
  assert.equal(undoCheck(op, look({ [R + "/a.txt"]: null })), "a.txt is gone");
  assert.equal(undoCheck(op, look({ [R + "/a.txt"]: "dir" })), "a.txt changed since");
  // no stat taken when it was made (could not read it): never undone
  assert.equal(undoCheck({ kind: "create", path: R + "/a.txt", dir: false }, look({ [R + "/a.txt"]: "file" }, { [R + "/a.txt"]: { size: 0, mtime: 5 } })), "a.txt changed since");
});

test("changed since: a new folder only while it is empty", () => {
  const op: UndoOp = { kind: "create", path: R + "/d", dir: true };
  assert.equal(undoCheck(op, look({ [R + "/d"]: "dir" }, {}, { [R + "/d"]: true })), "");
  assert.equal(undoCheck(op, look({ [R + "/d"]: "dir" }, {}, { [R + "/d"]: false })), "d is not empty now");
  assert.equal(undoCheck(op, look({ [R + "/d"]: null })), "d is gone");
});

test("changed since: a move back needs the item where it went and nothing where it was", () => {
  const op: UndoOp = { kind: "move", moves: [{ from: R + "/a", to: R + "/s/a" }] };
  assert.equal(undoCheck(op, look({ [R + "/s/a"]: "file", [R + "/a"]: null })), "");
  assert.equal(undoCheck(op, look({ [R + "/s/a"]: null, [R + "/a"]: null })), "a is no longer in s/");
  assert.equal(undoCheck(op, look({ [R + "/s/a"]: "file", [R + "/a"]: "file" })), "something is at a now");
});

test("changed since: a copy is trashed only while each copy is there (a file as copied)", () => {
  const op: UndoOp = { kind: "copy", items: [{ path: R + "/a copy.txt", dir: false, stat: { size: 2, mtime: 7 } }, { path: R + "/d copy", dir: true }] };
  assert.equal(undoCheck(op, look({ [R + "/a copy.txt"]: "file", [R + "/d copy"]: "dir" }, { [R + "/a copy.txt"]: { size: 2, mtime: 7 } })), "");
  assert.equal(undoCheck(op, look({ [R + "/a copy.txt"]: "file", [R + "/d copy"]: "dir" }, { [R + "/a copy.txt"]: { size: 2, mtime: 8 } })), "a copy.txt changed since");
  assert.equal(undoCheck(op, look({ [R + "/a copy.txt"]: "file", [R + "/d copy"]: null }, { [R + "/a copy.txt"]: { size: 2, mtime: 7 } })), "d copy is gone");
});

// A fake core: answers by command type.
function fake(answers: (c: any) => any) {
  const sent: any[] = [];
  const run = async (c: any) => {
    sent.push(c);
    return answers(c);
  };
  return { run, sent };
}

test("look: parents listed with ignored names, files read for their stat, folders listed for emptiness", async () => {
  const f = fake((c) => {
    if (c.type === "list_dir" && c.path === R) return { ok: true, data: { entries: [{ name: "d", kind: "dir" }, { name: "a.txt", kind: "file" }] } };
    if (c.type === "list_dir" && c.path === R + "/d") return { ok: true, data: { entries: [] } };
    if (c.type === "file_read") return { ok: true, data: { size: 0, mtime: 5, text: "" } };
    return { ok: false, error: "no" };
  });
  const l = await lookFor(f.run, { kind: "copy", items: [{ path: R + "/a.txt", dir: false, stat: { size: 0, mtime: 5 } }, { path: R + "/d", dir: true }, { path: R + "/gone", dir: false }] });
  assert.equal(l.kinds.get(R + "/a.txt"), "file");
  assert.equal(l.kinds.get(R + "/gone"), null);
  assert.deepEqual(l.stats.get(R + "/a.txt"), { size: 0, mtime: 5 });
  assert.ok(f.sent.some((c) => c.type === "list_dir" && c.path === R && c.ignored === true));
  // a folder's emptiness is asked only for a new folder
  assert.equal(f.sent.filter((c) => c.type === "list_dir" && c.path === R + "/d").length, 0);
  const l2 = await lookFor(f.run, { kind: "create", path: R + "/d", dir: true });
  assert.equal(l2.empty.get(R + "/d"), true);
});

test("undo a move: renames back, newest first; stops at a refusal", async () => {
  const f = fake((c) => (c.type === "rename_path" ? { ok: true } : { ok: false }));
  const out = await runUndo(f.run, { kind: "move", moves: [{ from: R + "/a", to: R + "/s/a" }, { from: R + "/b", to: R + "/s/b" }] });
  assert.deepEqual(f.sent.map((c) => [c.from, c.to]), [[R + "/s/b", R + "/b"], [R + "/s/a", R + "/a"]]);
  assert.deepEqual(out, { text: "Moved 2 items back", err: false, done: true, select: [R + "/b", R + "/a"], moved: [[R + "/s/b", R + "/b"], [R + "/s/a", R + "/a"]] });
  const g = fake(() => ({ ok: false, error: "the target already exists" }));
  const o2 = await runUndo(g.run, { kind: "move", moves: [{ from: R + "/a", to: R + "/b" }], rename: true });
  assert.equal(o2.text, "Could not rename b back: the target already exists");
  assert.equal(o2.err, true);
});

test("undo a create or copy: one delete_path of them all (the bar asks; its token kept)", async () => {
  const f = fake(() => ({ ok: false, error: "needs_confirmation", needs_confirmation: { summary: "…", by: "caller", token: "T1" } }));
  const out = await runUndo(f.run, { kind: "copy", items: [{ path: R + "/a copy", dir: false }, { path: R + "/d copy", dir: true }] });
  assert.deepEqual(f.sent, [{ type: "delete_path", path: "", paths: [R + "/a copy", R + "/d copy"] }]);
  assert.equal(out.token, "T1");
  assert.equal(out.done, false);
  const g = fake(() => ({ ok: true, data: { trashed: 1 } }));
  const o2 = await runUndo(g.run, { kind: "create", path: R + "/n.txt", dir: false, stat: { size: 0, mtime: 1 } });
  assert.deepEqual(g.sent, [{ type: "delete_path", path: R + "/n.txt" }]);
  assert.equal(o2.done, true);
  assert.equal(o2.text, "Moved n.txt to the Trash");
});

test("undo a delete: restore_path with each id the core returned, all of them", async () => {
  const f = fake((c) => (c.id === "2" ? { ok: false, error: "something is at /p/b now" } : { ok: true, data: { path: "/private" + (c.id === "1" ? "/p/a" : "/p/c") } }));
  const out = await runUndo(f.run, { kind: "delete", restore: [{ path: R + "/a", id: "1" }, { path: R + "/b", id: "2" }, { path: R + "/c", id: "3" }] });
  assert.deepEqual(f.sent.map((c) => [c.type, c.id]), [["restore_path", "1"], ["restore_path", "2"], ["restore_path", "3"]]);
  assert.equal(out.text, "Put 2 items back. Could not put b back: something is at /p/b now");
  assert.equal(out.err, true);
  assert.deepEqual(out.select, [R + "/a", R + "/c"]);
});

test("the bar's answer: the tree's own delete pushes an undo with the ids it returned; others nothing", () => {
  const s = new UndoStack();
  s.askedDelete("D1", R, [R + "/a"]);
  assert.equal(s.confirmed("other", { ok: true, data: { restore: [{ path: R + "/x", id: "9" }] } }), null);
  const got = s.confirmed("D1", { ok: true, data: { trashed: 1, restore: [{ path: "/private/p/a", id: "1" }] } })!;
  assert.equal(got.kind, "pushed");
  // the core's paths are resolved (a symlinked root): kept as the tree names them
  assert.deepEqual((got.rec.op as any).restore, [{ path: R + "/a", id: "1" }]);
  assert.equal(s.size, 1);
  // used once
  assert.equal(s.confirmed("D1", { ok: true, data: { restore: [{ path: R + "/a", id: "1" }] } }), null);
  // no ids back (an older core, nothing known): nothing to undo
  s.askedDelete("D2", R, [R + "/b"]);
  assert.deepEqual(s.confirmed("D2", { ok: true, data: { trashed: 1 } }), { kind: "none" });
  assert.equal(s.size, 1);
});

test("the bar's answer: an undo waiting there leaves the stack when it ran", () => {
  const s = new UndoStack();
  const rec = s.push(R, { kind: "create", path: R + "/a", dir: true });
  s.askedUndo("U1", rec);
  assert.equal(s.confirmed("U1", { ok: false, error: "refused" })!.kind, "failed");
  assert.equal(s.size, 1); // refused: still there (asked again, the bar asks again)
  s.askedUndo("U1", rec);
  assert.equal(s.confirmed("U1", { ok: true, data: { trashed: 1 } })!.kind, "undone");
  assert.equal(s.size, 0);
});
