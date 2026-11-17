// The Files tab's tree as data (src/app/filetree.ts): rows, the name field's place, the keys, the
// window's git letters.

import { test } from "node:test";
import assert from "node:assert/strict";
import { gitLetter, gitTone, isEditRow, moveSel, newTarget, parentsOf, relPath, rowKey, stemEnd, treeRows, type Listing, type Row } from "../src/app/filetree.ts";

const R = "/p";
const listed = new Map<string, Listing>([
  [R, { entries: [{ name: "src", kind: "dir" }, { name: "docs", kind: "dir" }, { name: "a.txt", kind: "file", git: "??" }], err: "" }],
  [R + "/src", { entries: [{ name: "main.ts", kind: "file", git: " M" }], err: "" }],
  [R + "/docs", { entries: [], err: "permission denied" }],
]);
const shape = (rows: Row[]) => rows.map((r) => "  ".repeat(r.depth) + (r.t === "entry" ? r.e.name : r.t === "new" ? "[new " + r.kind + "]" : r.t === "err" ? "! " + r.text : "…"));

test("tree rows: open folders' children under them, errors and listing in place", () => {
  assert.deepEqual(shape(treeRows(R, listed, new Set(), null)), ["src", "docs", "a.txt"]);
  assert.deepEqual(shape(treeRows(R, listed, new Set([R + "/src", R + "/docs"]), null)), ["src", "  main.ts", "docs", "  ! permission denied", "a.txt"]);
  assert.deepEqual(shape(treeRows(R, new Map(), new Set(), null)), ["…"]);
});

test("the new-name field: first child of its folder at its depth, its error under it", () => {
  const open = new Set([R + "/src"]);
  assert.deepEqual(shape(treeRows(R, listed, open, { kind: "file", dir: R + "/src", err: "" })), ["src", "  [new file]", "  main.ts", "docs", "a.txt"]);
  assert.deepEqual(shape(treeRows(R, listed, open, { kind: "dir", dir: R, err: "already exists" })), ["[new dir]", "! already exists", "src", "  main.ts", "docs", "a.txt"]);
  // a rename's error under its row
  assert.deepEqual(shape(treeRows(R, listed, new Set(), { kind: "rename", path: R + "/a.txt", err: "no" })), ["src", "docs", "a.txt", "! no"]);
  // the target of New file / New folder: a folder itself, a file's folder, else the root
  assert.equal(newTarget(R, R + "/src", true), R + "/src");
  assert.equal(newTarget(R, R + "/src/main.ts", false), R + "/src");
  assert.equal(newTarget(R, "", false), R);
  assert.equal(newTarget(R, "/elsewhere/x", false), R);
});

test("keys move the selection: arrows, Home/End, left to the parent, right into an open folder", () => {
  const open = new Set([R + "/src"]);
  const rows = treeRows(R, listed, open, null);
  assert.equal(moveSel(rows, "", "ArrowDown", open), R + "/src");
  assert.equal(moveSel(rows, R + "/src", "ArrowDown", open), R + "/src/main.ts");
  assert.equal(moveSel(rows, R + "/a.txt", "ArrowDown", open), R + "/a.txt");
  assert.equal(moveSel(rows, R + "/src", "ArrowUp", open), R + "/src");
  assert.equal(moveSel(rows, R + "/src", "End", open), R + "/a.txt");
  assert.equal(moveSel(rows, R + "/a.txt", "Home", open), R + "/src");
  assert.equal(moveSel(rows, R + "/src/main.ts", "ArrowLeft", open), R + "/src");
  assert.equal(moveSel(rows, R + "/src", "ArrowLeft", open), R + "/src"); // the root is not a row
  assert.equal(moveSel(rows, R + "/src", "ArrowRight", open), R + "/src/main.ts");
  assert.equal(moveSel(rows, R + "/docs", "ArrowRight", open), R + "/docs"); // closed
});

test("paths: the folders to open, relative, the stem a rename selects", () => {
  assert.deepEqual(parentsOf(R, R + "/a/b/c.txt"), [R + "/a", R + "/a/b"]);
  assert.deepEqual(parentsOf(R, R + "/c.txt"), []);
  assert.deepEqual(parentsOf(R, "/q/c.txt"), []);
  assert.equal(relPath(R, R + "/a/b.txt"), "a/b.txt");
  assert.equal(stemEnd("main.test.ts", false), 9);
  assert.equal(stemEnd(".env", false), 4);
  assert.equal(stemEnd("Makefile", false), 8);
  assert.equal(stemEnd("v1.2", true), 4);
});

test("git letters and colours are the window's (files_git_letter, files_git_color)", () => {
  const cases: [string, boolean, string, string][] = [
    ["", false, "", ""],
    [" M", false, "M", "g-mod"],
    ["MM", false, "M", "g-mod"],
    ["M ", false, "M", "g-mod"],
    ["AM", false, "A", "g-add"],
    ["A ", false, "A", "g-add"],
    ["??", false, "U", "g-add"],
    [" D", false, "D", "g-del"],
    ["D ", false, "D", "g-del"],
    ["R ", false, "R", "g-mod"],
    ["RM", false, "R", "g-mod"],
    ["UU", false, "!", "g-del"],
    ["AA", false, "!", "g-del"],
    ["DD", false, "!", "g-del"],
    ["AU", false, "!", "g-del"],
    ["??", true, "U", "g-add"],
    [" M", true, "•", "g-mod"],
  ];
  for (const [code, dir, letter, tone] of cases) {
    assert.equal(gitLetter(code, dir), letter, code + (dir ? " (folder)" : ""));
    assert.equal(gitTone(letter), tone, letter);
  }
});

test("row keys: unique per folder (not by depth), stable for the edit rows", () => {
  const open = new Set([R + "/src", R + "/docs"]);
  const two = new Map(listed);
  two.delete(R + "/src"); // listing… under src, and an error under docs, at the same depth
  const rows = treeRows(R, two, open, { kind: "file", dir: R, err: "bad" });
  const keys = rows.map(rowKey);
  assert.equal(new Set(keys).size, keys.length, keys.join(" "));
  assert.ok(keys.includes("new:" + R));
  assert.ok(keys.includes("wait:" + R + "/src") && keys.includes("err:" + R + "/docs"));
  assert.ok(isEditRow(rows.find((r) => r.t === "new")!));
  const ren = treeRows(R, listed, new Set(), { kind: "rename", path: R + "/a.txt", err: "" });
  assert.ok(isEditRow(ren.find((r) => r.t === "entry" && r.path === R + "/a.txt")!, { kind: "rename", path: R + "/a.txt", err: "" }));
});

// ---- several rows picked (phase 3) ----
import { clickPick, entryPaths, extendPick, outermost, pickOne, prunePick, rangeOf, typeMatch, typed, TYPE_PAUSE } from "../src/app/filetree.ts";

const big = new Map<string, Listing>([
  [R, { entries: [{ name: "src", kind: "dir" }, { name: "Alpha.md", kind: "file" }, { name: "apple.ts", kind: "file" }, { name: "beta", kind: "file" }], err: "" }],
  [R + "/src", { entries: [{ name: "a.ts", kind: "file" }, { name: "b.ts", kind: "file" }], err: "" }],
]);
const bigRows = treeRows(R, big, new Set([R + "/src"]), null);
const order = entryPaths(bigRows); // src, src/a.ts, src/b.ts, Alpha.md, apple.ts, beta
const P = (...xs: string[]) => xs.map((x) => R + "/" + x);
const picked = (p: { paths: Set<string> }) => order.filter((x) => p.paths.has(x)).map((x) => x.slice(R.length + 1));

test("click picks one; ⌘ toggles and moves the anchor; shift picks the range from the anchor", () => {
  let p = clickPick(order, pickOne(""), R + "/src/a.ts", { toggle: false, range: false });
  assert.deepEqual(picked(p), ["src/a.ts"]);
  p = clickPick(order, p, R + "/apple.ts", { toggle: true, range: false });
  assert.deepEqual(picked(p), ["src/a.ts", "apple.ts"]);
  assert.equal(p.anchor, R + "/apple.ts");
  p = clickPick(order, p, R + "/src/a.ts", { toggle: true, range: false }); // off again (still the anchor)
  assert.deepEqual(picked(p), ["apple.ts"]);
  assert.equal(p.anchor, R + "/src/a.ts");
  // shift: anchor..row, either direction, what was picked replaced
  p = clickPick(order, pickOne(R + "/apple.ts"), R + "/src/b.ts", { toggle: false, range: true });
  assert.deepEqual(picked(p), ["src/b.ts", "Alpha.md", "apple.ts"]);
  assert.equal(p.anchor, R + "/apple.ts");
  p = clickPick(order, p, R + "/beta", { toggle: false, range: true });
  assert.deepEqual(picked(p), ["apple.ts", "beta"]);
  // ⌘-shift: the range added
  p = clickPick(order, pickOne(R + "/src"), R + "/beta", { toggle: true, range: false });
  p = clickPick(order, { ...p, anchor: R + "/Alpha.md" }, R + "/apple.ts", { toggle: true, range: true });
  assert.deepEqual(picked(p), ["src", "Alpha.md", "apple.ts", "beta"]);
  // no anchor drawn: shift-click is a plain click
  assert.deepEqual(picked(clickPick(order, pickOne(R + "/gone"), R + "/beta", { toggle: false, range: true })), ["beta"]);
  assert.deepEqual(rangeOf(order, R + "/gone", R + "/beta"), [R + "/beta"]);
  assert.deepEqual(rangeOf(order, R + "/beta", R + "/gone"), []);
});

test("shift-arrows extend from the anchor and shrink back past it", () => {
  let p = pickOne(R + "/Alpha.md");
  let at = R + "/Alpha.md";
  for (const key of ["ArrowDown", "ArrowDown"]) {
    const to = moveSel(bigRows, at, key, new Set([R + "/src"]));
    p = extendPick(order, p, at, to);
    at = to;
  }
  assert.deepEqual(picked(p), ["Alpha.md", "apple.ts", "beta"]);
  for (const key of ["ArrowUp", "ArrowUp", "ArrowUp"]) {
    const to = moveSel(bigRows, at, key, new Set([R + "/src"]));
    p = extendPick(order, p, at, to);
    at = to;
  }
  assert.deepEqual(picked(p), ["src/b.ts", "Alpha.md"]);
  // no anchor yet: from the focused row
  assert.deepEqual(picked(extendPick(order, pickOne(""), R + "/beta", R + "/apple.ts")), ["apple.ts", "beta"]);
});

test("listed again: picked rows that went drop out; the rest stay", () => {
  const p = { paths: new Set(P("src/a.ts", "beta")), anchor: R + "/beta" };
  assert.equal(prunePick(order, p), p); // all drawn: unchanged
  const after = prunePick(order.filter((x) => x !== R + "/beta"), p);
  assert.deepEqual([...after.paths], P("src/a.ts"));
  assert.equal(after.anchor, "");
  // a folder closed: its rows are no longer drawn, so no longer picked
  const closed = entryPaths(treeRows(R, big, new Set(), null));
  assert.deepEqual([...prunePick(closed, p).paths], P("beta"));
});

test("trashing several: a row inside a picked folder is left out (the folder takes it)", () => {
  assert.deepEqual(outermost(order, new Set(P("src/a.ts", "src", "beta"))), P("src", "beta"));
  assert.deepEqual(outermost(order, new Set(P("src/b.ts", "apple.ts"))), P("src/b.ts", "apple.ts"));
  // a sibling sharing a prefix is not inside
  const o = ["/p/a", "/p/ab"];
  assert.deepEqual(outermost(o, new Set(o)), o);
});

test("type-to-select: the next name starting with the letters, any case; one letter again cycles", () => {
  assert.equal(typeMatch(bigRows, "", "a"), R + "/src/a.ts");
  assert.equal(typeMatch(bigRows, R + "/src/a.ts", "a"), R + "/Alpha.md");
  assert.equal(typeMatch(bigRows, R + "/Alpha.md", "a"), R + "/apple.ts");
  assert.equal(typeMatch(bigRows, R + "/apple.ts", "a"), R + "/src/a.ts"); // wraps
  assert.equal(typeMatch(bigRows, R + "/Alpha.md", "aa"), R + "/apple.ts"); // "aa": cycling a
  assert.equal(typeMatch(bigRows, R + "/src/a.ts", "ap"), R + "/apple.ts");
  assert.equal(typeMatch(bigRows, R + "/Alpha.md", "al"), R + "/Alpha.md"); // stays while it matches
  assert.equal(typeMatch(bigRows, R + "/beta", "zz"), "");
  // the letters: a pause starts again
  let b = typed({ text: "", at: 0 }, "a", 5000);
  b = typed(b, "p", 5000 + TYPE_PAUSE - 1);
  assert.equal(b.text, "ap");
  assert.equal(typed(b, "b", b.at + TYPE_PAUSE + 1).text, "b");
});
