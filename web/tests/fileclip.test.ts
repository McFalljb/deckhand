// The Files tree's page-local clipboard (src/app/fileclip.ts): where a paste goes, what a copy or
// duplicate sends, what is dimmed, what the bar and the toasts say.

import { test } from "node:test";
import assert from "node:assert/strict";
import { clipCut, clipLabel, clipOf, copyingText, copyResult, pasteTarget, planCopy } from "../src/app/fileclip.ts";

const R = "/p";

test("paste target: the selected folder, else the selected file's folder, else the root", () => {
  assert.equal(pasteTarget(R, R + "/src", true), R + "/src");
  assert.equal(pasteTarget(R, R + "/src/a.ts", false), R + "/src");
  assert.equal(pasteTarget(R, "", false), R);
  assert.equal(pasteTarget(R, "/elsewhere/x", false), R);
});

test("clip: paths captured at the gesture, outermost only; empty is none", () => {
  assert.equal(clipOf("copy", R, []), null);
  const c = clipOf("cut", R, [R + "/src", R + "/src/a.ts", R + "/b.txt"]);
  assert.deepEqual(c, { mode: "cut", root: R, paths: [R + "/src", R + "/b.txt"] });
});

test("cut rows dimmed: a cut item and what is under it, never for a copy or another tree", () => {
  const c = clipOf("cut", R, [R + "/src"]);
  assert.equal(clipCut(c, R, R + "/src"), true);
  assert.equal(clipCut(c, R, R + "/src/a.ts"), true);
  assert.equal(clipCut(c, R, R + "/srcx"), false);
  assert.equal(clipCut(clipOf("copy", R, [R + "/src"]), R, R + "/src"), false);
  assert.equal(clipCut(c, "/q", R + "/src"), false);
  assert.equal(clipCut(null, R, R + "/src"), false);
});

test("clip bar label", () => {
  assert.equal(clipLabel(clipOf("copy", R, [R + "/a.txt"])), "a.txt copied");
  assert.equal(clipLabel(clipOf("cut", R, [R + "/a", R + "/b"])), "2 items cut");
  assert.equal(clipLabel(null), "");
});

test("plan a copy into a folder: to = dir/name (the core makes it unique); into its own folder allowed", () => {
  assert.deepEqual(planCopy(R, [R + "/a.txt", R + "/src"], R + "/docs"), { copies: [{ from: R + "/a.txt", to: R + "/docs/a.txt" }, { from: R + "/src", to: R + "/docs/src" }], why: "" });
  assert.deepEqual(planCopy(R, [R + "/a.txt"], R).copies, [{ from: R + "/a.txt", to: R + "/a.txt" }]);
  // a source inside another goes with it
  assert.deepEqual(planCopy(R, [R + "/src", R + "/src/a.ts"], R + "/docs").copies.map((c) => c.from), [R + "/src"]);
});

test("plan a copy: refused into itself, outside the tree, nothing", () => {
  assert.equal(planCopy(R, [R + "/src"], R + "/src").why, "Can't copy src into itself");
  assert.equal(planCopy(R, [R + "/src"], R + "/src/deep").why, "Can't copy src into itself");
  assert.equal(planCopy(R, ["/q/x"], R).why, "That item is outside the project");
  assert.equal(planCopy(R, [R + "/x"], "/q").why, "That folder is outside the project");
  assert.equal(planCopy(R, [], R).why, "Nothing to copy");
});

test("plan a duplicate (no folder): each beside itself", () => {
  assert.deepEqual(planCopy(R, [R + "/a.txt", R + "/src/b.ts"], null).copies, [
    { from: R + "/a.txt", to: R + "/a.txt" },
    { from: R + "/src/b.ts", to: R + "/src/b.ts" },
  ]);
  assert.equal(planCopy(R, [R + "/src"], null).why, "");
});

test("copying and copied words", () => {
  assert.equal(copyingText([R + "/a.txt"], false), "Copying a.txt…");
  assert.equal(copyingText([R + "/a", R + "/b", R + "/c"], false), "Copying 3 items…");
  assert.equal(copyingText([R + "/a"], true), "Duplicating a…");
  assert.equal(copyResult(R, R + "/src", 1, [R + "/a.txt"], []), "Copied a.txt to src/");
  assert.equal(copyResult(R, R + "/src", 3, [R + "/a", R + "/b", R + "/c"], []), "Copied 3 items to src/");
  assert.equal(copyResult(R, R, 1, [R + "/a"], []), "Copied a to p/");
  assert.equal(copyResult(R, null, 2, [R + "/a", R + "/b"], []), "Duplicated 2 items");
  // skipped entries named (the core's relative paths), a few then a count
  assert.equal(copyResult(R, R + "/src", 1, [R + "/cfg"], ["cfg/.env", "cfg/.git"]), "Copied cfg to src/; left out: cfg/.env, cfg/.git");
  assert.equal(copyResult(R, R + "/src", 1, [R + "/cfg"], ["a", "b", "c", "d", "e"]), "Copied cfg to src/; left out: a, b, c and 2 more");
  // stopped: the core's words as worded
  assert.equal(copyResult(R, R + "/src", 3, [R + "/a"], [], { from: R + "/b", error: "copied 2 of 5, then x: no space" }), "Copied a to src/. Could not copy b: copied 2 of 5, then x: no space; 1 not copied");
  assert.equal(copyResult(R, R + "/src", 1, [], [], { from: R + "/b", error: "the target already exists" }), "Could not copy b: the target already exists");
});

test("the copy's path as the tree names it (the core answers resolved paths)", async () => {
  const { copiedPath } = await import("../src/app/fileclip.ts");
  assert.equal(copiedPath(R + "/src/a.txt", "/private/p/src/a copy.txt"), R + "/src/a copy.txt");
  assert.equal(copiedPath(R + "/src/a.txt", ""), R + "/src/a.txt");
});

test("run a paste: fs_copy per item in order with unique; stops at a refusal; the copies named as the tree names them", async () => {
  const { runCopies } = await import("../src/app/fileclip.ts");
  const sent: any[] = [];
  const run = async (c: any) => {
    sent.push(c);
    if (c.from.endsWith("/bad")) return { ok: false, error: "copied 1 of 2, then x: no space" };
    return { ok: true, data: { path: "/private" + c.to.replace(/(\.txt)?$/, " copy$1"), copied: 1, ...(c.from.endsWith("/cfg") ? { skipped: [{ path: "cfg/.env", why: "a credential: not copied" }] } : {}) } };
  };
  const out = await runCopies(run, [{ from: R + "/a.txt", to: R + "/a.txt" }, { from: R + "/cfg", to: R + "/s/cfg" }, { from: R + "/bad", to: R + "/s/bad" }, { from: R + "/z", to: R + "/s/z" }]);
  assert.deepEqual(sent.map((c) => [c.type, c.from, c.to, c.unique]), [["fs_copy", R + "/a.txt", R + "/a.txt", true], ["fs_copy", R + "/cfg", R + "/s/cfg", true], ["fs_copy", R + "/bad", R + "/s/bad", true]]);
  assert.deepEqual(out.done, [{ from: R + "/a.txt", path: R + "/a copy.txt" }, { from: R + "/cfg", path: R + "/s/cfg copy" }]);
  assert.deepEqual(out.skipped, ["cfg/.env"]);
  assert.deepEqual(out.failed, { from: R + "/bad", error: "copied 1 of 2, then x: no space" });
  // a copy left midway is in the folder: it shows (and can be trashed by hand), never undone
  const w = await runCopies(async () => ({ ok: false, error: "needs_confirmation", needs_confirmation: { summary: "", by: "caller", token: "t" } }), [{ from: R + "/a", to: R + "/s/a" }]);
  assert.equal(w.waiting, true);
});
