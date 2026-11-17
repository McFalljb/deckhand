// The Files tab's tree as data (src/app/filetree.ts): rows, the name field's place, the keys, the
// window's git letters.

import { test } from "node:test";
import assert from "node:assert/strict";
import { gitLetter, gitTone, moveSel, newTarget, parentsOf, relPath, stemEnd, treeRows, type Listing, type Row } from "../src/app/filetree.ts";

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
