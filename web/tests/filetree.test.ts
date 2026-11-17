// The Files tab's tree as data (src/app/filetree.ts): rows, the name field's place, the keys, the
// window's git letters.

import { test } from "node:test";
import assert from "node:assert/strict";
import { dragText, dropDir, fileIcon, inIgnored, folderLabel, shellQuote, folderRows, gitLetter, gitTone, isEditRow, moveResult, movedPath, moveSel, newTarget, parentsOf, planMove, relPath, rowKey, stemEnd, treeRows, type Listing, type Row } from "../src/app/filetree.ts";

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
import { clickPick, entryPaths, extendPick, outermost, pickOne, prunePick, rangeOf, trashTargets, typeMatch, typed, TYPE_PAUSE } from "../src/app/filetree.ts";

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

test("Delete trashes the picked rows (as the window's tree), else the focused row", () => {
  const p = { paths: new Set(P("src", "src/a.ts", "beta")), anchor: R + "/beta" };
  // several picked, the focus on one: them (outermost)
  assert.deepEqual(trashTargets(order, p, R + "/beta"), P("src", "beta"));
  // the focus ⌘-clicked off them: still what shows selected, never the focused row
  assert.deepEqual(trashTargets(order, p, R + "/apple.ts"), P("src", "beta"));
  assert.deepEqual(trashTargets(order, pickOne(R + "/beta"), R + "/apple.ts"), P("beta"));
  // one picked, focused: it; nothing picked: the focused row; nothing at all: none
  assert.deepEqual(trashTargets(order, pickOne(R + "/beta"), R + "/beta"), P("beta"));
  assert.deepEqual(trashTargets(order, pickOne(""), R + "/beta"), P("beta"));
  assert.deepEqual(trashTargets(order, pickOne(""), ""), []);
});

test("move: where a drop goes (a folder row, a file row's folder, empty space the root)", () => {
  assert.equal(dropDir(R, { path: R + "/src", dir: true }), R + "/src");
  assert.equal(dropDir(R, { path: R + "/src/main.ts", dir: false }), R + "/src");
  assert.equal(dropDir(R, { path: R + "/a.txt", dir: false }), R);
  assert.equal(dropDir(R, null), R);
});

test("move: not into itself, nor where it already is, nor onto a name already there", () => {
  const src = listed.get(R + "/src");
  // into a folder
  assert.deepEqual(planMove(R, [R + "/a.txt"], R + "/src", src), { moves: [{ from: R + "/a.txt", to: R + "/src/a.txt" }], why: "", noop: false });
  // a folder into itself or anything inside it
  assert.equal(planMove(R, [R + "/src"], R + "/src").why, "Can't move src into itself");
  assert.equal(planMove(R, [R + "/src"], R + "/src/deep/er").why, "Can't move src into itself");
  // a sibling whose name starts the same is not inside it
  assert.equal(planMove(R, [R + "/src"], R + "/src2").why, "");
  // its own folder
  assert.equal(planMove(R, [R + "/src/main.ts"], R + "/src").why, "main.ts is already there");
  // a name already in the folder (known from its listing; not known: the core says so)
  assert.equal(planMove(R, [R + "/docs/main.ts"], R + "/src", src).why, "main.ts already exists in src/");
  assert.equal(planMove(R, [R + "/docs/main.ts"], R + "/src").why, "");
  assert.equal(planMove(R, [R + "/x/a.txt"], R, listed.get(R)).why, "a.txt already exists in p/");
  // outside the project
  assert.equal(planMove(R, [R + "/a.txt"], "/q").why, "That folder is outside the project");
  assert.equal(planMove(R, [R + "/a.txt"], R + "x/y").why, "That folder is outside the project");
  assert.equal(planMove(R, [], R).why, "Nothing to move");
});

test("move: several at once", () => {
  // one already there stays; the rest move
  assert.deepEqual(planMove(R, [R + "/a.txt", R + "/src/main.ts"], R).moves, [{ from: R + "/src/main.ts", to: R + "/main.ts" }]);
  // all already there: not a target
  assert.equal(planMove(R, [R + "/a.txt", R + "/b.txt"], R).why, "They are already there");
  // one inside another picked folder goes with it
  assert.deepEqual(planMove(R, [R + "/src/main.ts", R + "/src", R + "/a.txt"], R + "/docs").moves.map((m) => m.from), [R + "/src", R + "/a.txt"]);
  // the same name twice
  assert.equal(planMove(R, [R + "/src/x.ts", R + "/docs/x.ts"], R).why, "Two of them are named x.ts");
  // any one into itself refuses the lot
  assert.equal(planMove(R, [R + "/a.txt", R + "/src"], R + "/src/deep").why, "Can't move src into itself");
});

test("move: what it says, and paths following it", () => {
  assert.equal(moveResult(R, R + "/src", [R + "/a.txt"]), "Moved a.txt to src/");
  assert.equal(moveResult(R, R + "/src/deep", [R + "/a", R + "/b", R + "/c"]), "Moved 3 items to src/deep/");
  assert.equal(moveResult(R, R, [R + "/src/a"]), "Moved a to p/");
  assert.equal(moveResult(R, R + "/src", [R + "/a"], { from: R + "/b", error: "the new name already exists" }), "Moved a to src/. Could not move b: the new name already exists");
  assert.equal(moveResult(R, R + "/src", [], { from: R + "/b", error: "no" }), "Could not move b: no");
  assert.equal(folderLabel(R, R + "/a/b"), "a/b/");
  assert.equal(movedPath(R + "/src/deep", R + "/src", R + "/lib/src"), R + "/lib/src/deep");
  assert.equal(movedPath(R + "/src", R + "/src", R + "/lib/src"), R + "/lib/src");
  assert.equal(movedPath(R + "/src2", R + "/src", R + "/lib/src"), R + "/src2");
});

test("move: the picker's folders (root first, folders only, open ones' folders under them)", () => {
  const l = new Map<string, Listing>([
    [R, { entries: [{ name: "src", kind: "dir" }, { name: "docs", kind: "dir" }, { name: "ln", kind: "symlink" }, { name: "a.txt", kind: "file" }], err: "" }],
    [R + "/src", { entries: [{ name: "deep", kind: "dir" }, { name: "main.ts", kind: "file" }], err: "" }],
    [R + "/docs", { entries: [{ name: "g.md", kind: "file" }], err: "" }],
  ]);
  const rows = folderRows(R, l, new Set([R + "/src", R + "/src/deep"]));
  assert.deepEqual(rows.map((r) => [r.name, r.depth, r.open, r.state, r.kids]), [
    ["p", 0, true, "listed", true],
    ["src", 1, true, "listed", true],
    ["deep", 2, true, "wait", true],
    ["docs", 1, false, "listed", false],
  ]);
});

test("drag text: shell-quoted paths, one space apart, never a newline", () => {
  assert.equal(shellQuote("/p/a b.txt"), "'/p/a b.txt'");
  assert.equal(shellQuote("/p/it's"), "'/p/it'\\''s'");
  assert.equal(shellQuote("/p/$HOME `id` \"x\""), "'/p/$HOME `id` \"x\"'");
  // control characters: ANSI-C quoting, escaped (a newline never reaches a terminal)
  assert.equal(shellQuote("/p/a\nrm -rf ~"), "$'/p/a\\nrm -rf ~'");
  assert.equal(shellQuote("/p/t\tq'\\\r\x1b"), "$'/p/t\\tq\\'\\\\\\r\\x1b'");
  // a leading -: never read as an option
  assert.equal(shellQuote("-rf"), "'./-rf'");
  const t = dragText(["/p/a b", "/p/x\ny", "/p/c"]);
  assert.equal(t, "'/p/a b' $'/p/x\\ny' '/p/c'");
  assert.ok(!/[\n\r]/.test(t));
});

test("move: sources outside the tree's root refuse the lot; already there is a no-op (a slipped click)", () => {
  assert.equal(planMove(R, ["/q/a.txt"], R + "/src").why, "That item is outside the project");
  assert.equal(planMove(R, [R + "/a.txt", "/elsewhere/b"], R + "/src").why, "That item is outside the project");
  assert.equal(planMove(R, [R], R + "/src").why, "That item is outside the project");
  assert.equal(planMove(R, [R + "/a.txt"], R).noop, true);
  assert.equal(planMove(R, [R + "/a.txt", R + "/b.txt"], R).noop, true);
  assert.equal(planMove(R, [R + "/a.txt"], R + "/src").noop, false);
  assert.equal(planMove(R, [R + "/src"], R + "/src").noop, false);
});

test("move: waiting for a confirmation says how many are not moved", () => {
  assert.equal(moveResult(R, R + "/src", [R + "/a"], undefined, 2), "Moved a to src/. Waiting for confirmation; 2 not moved");
  assert.equal(moveResult(R, R + "/src", [], undefined, 0), "Waiting for confirmation");
  assert.equal(moveResult(R, R + "/src", [], undefined, 1), "Waiting for confirmation; 1 not moved");
});

test("file icons: folders by open, files by name then last extension, any case", () => {
  const table: [string, "file" | "dir" | "symlink", boolean, string][] = [
    ["src", "dir", false, "folder"],
    ["src", "dir", true, "folder-open"],
    ["notes", "file", false, "file"],
    ["a.unknownext", "file", false, "file"],
    ["main.ts", "file", false, "file-code"],
    ["App.TSX", "file", false, "file-code"],
    ["core.odin", "file", false, "file-code"],
    ["index.html", "file", false, "file-code"],
    ["README.md", "file", false, "file-doc"],
    ["README", "file", false, "file-doc"],
    ["LICENSE", "file", false, "file-doc"],
    ["notes.txt", "file", false, "file-doc"],
    ["tsconfig.json", "file", false, "file-config"],
    ["ci.yml", "file", false, "file-config"],
    ["Makefile", "file", false, "file-config"],
    ["Dockerfile", "file", false, "file-config"],
    ["logo.svg", "file", false, "file-image"],
    ["shot.PNG", "file", false, "file-image"],
    ["build.sh", "file", false, "file-shell"],
    [".zshrc", "file", false, "file-shell"],
    ["package.json", "file", false, "file-lock"],
    ["package-lock.json", "file", false, "file-lock"],
    ["Cargo.toml", "file", false, "file-lock"],
    ["go.sum", "file", false, "file-lock"],
    ["something.lock", "file", false, "file-lock"],
    [".gitignore", "file", false, "file-git"],
    [".gitattributes", "file", false, "file-git"],
    [".env", "file", false, "file-env"],
    [".env.local", "file", false, "file-env"],
    ["prod.env", "file", false, "file-env"],
    ["dist.tar.gz", "file", false, "file-binary"],
    ["app.wasm", "file", false, "file-binary"],
    ["AGENTS.md", "file", false, "file-agent"],
    ["CLAUDE.md", "file", false, "file-agent"],
    ["link", "symlink", false, "file"],
    [".hidden", "file", false, "file"],
  ];
  for (const [name, kind, open, want] of table) assert.equal(fileIcon(name, kind, open), want, name);
});

test("ignored: dimmed (ign) with all under an ignored folder; hidden ones not drawn, nor picked, nor targets", () => {
  const l = new Map<string, Listing>([
    [R, { entries: [{ name: "node_modules", kind: "dir", ignored: true }, { name: "src", kind: "dir" }, { name: "out.log", kind: "file", ignored: true }, { name: "a.txt", kind: "file" }], err: "" }],
    [R + "/node_modules", { entries: [{ name: "left-pad", kind: "dir" }], err: "" }],
    [R + "/src", { entries: [{ name: "main.ts", kind: "file" }], err: "" }],
  ]);
  const open = new Set([R + "/node_modules", R + "/src"]);
  const ign = (rows: Row[]) => rows.flatMap((r) => (r.t === "entry" ? [r.e.name + (r.ign ? "*" : "")] : []));
  assert.deepEqual(ign(treeRows(R, l, open, null)), ["node_modules*", "left-pad*", "src", "main.ts", "out.log*", "a.txt"]);
  assert.deepEqual(ign(treeRows(R, l, open, null, true)), ["src", "main.ts", "a.txt"]);
  // the slow poll: a folder in or under an ignored one
  assert.equal(inIgnored(R, R + "/node_modules", l), true);
  assert.equal(inIgnored(R, R + "/node_modules/left-pad", l), true);
  assert.equal(inIgnored(R, R + "/src", l), false);
  assert.equal(inIgnored(R, R + "/gone", l), false);
  // Move to…: hidden folders are not targets
  assert.deepEqual(folderRows(R, l, new Set(), true).map((r) => r.name), ["p", "src"]);
  assert.deepEqual(folderRows(R, l, new Set(), false).map((r) => r.name), ["p", "node_modules", "src"]);
});

test("file icons: the window's rules (src/core/file_kinds.odin), and no Object members as kinds", () => {
  const table: [string, string][] = [
    ["x.constructor", "file"], ["x.__proto__", "file"], ["constructor", "file"], ["__proto__", "file"], ["toString", "file"], ["a.hasOwnProperty", "file"], ["trailing.", "file"],
    ["AGENTS.override.md", "file-agent"], ["agents.md", "file-agent"], ["agent.md", "file-doc"], ["GEMINI.md", "file-doc"],
    ["GNUmakefile", "file-config"], ["rules.mk", "file-config"], ["Dockerfile.dev", "file-config"], ["Containerfile", "file-config"], ["justfile", "file-config"], ["Procfile", "file-config"], ["flake.nix", "file-config"],
    ["poetry.lock", "file-lock"], ["pyproject.toml", "file-lock"], ["yarn.lock", "file-lock"], ["requirements.txt", "file-lock"],
    ["LICENSE.md", "file-doc"], ["license.json", "file-config"], ["CONTRIBUTING", "file-doc"], ["README.rst", "file-doc"], ["readme.ts", "file-code"], ["spec.docx", "file-doc"],
    ["CMakeLists.txt", "file-config"], ["build.gradle", "file-config"], ["Rakefile", "file-config"], ["x.cmake", "file-config"], ["notes.odt", "file-doc"], ["prod.ENV", "file-env"], ["Dockerfile", "file-config"], ["README.md.bak", "file"], ["app.whl", "file-binary"],
  ];
  for (const [name, want] of table) assert.equal(fileIcon(name, "file"), want, name);
});
