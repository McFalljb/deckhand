// The Files tree's filter (src/app/filefilter.ts) and its checkout switcher (src/app/checkouts.ts) as
// data: find_files' answer, only the latest query's, the keys over the results, the switcher's list,
// what the page remembers and when a write is offered.

import { test } from "node:test";
import assert from "node:assert/strict";
import { Latest, enterOpens, foundRows, foundNote, stepFound, parseFound, type Found } from "../src/app/filefilter.ts";
import { CHECKOUT_KEY, checkoutLabel, checkoutName, parseCheckouts, viewRoot, type Checkouts } from "../src/app/checkouts.ts";

test("filter: find_files' answer under the tree's own root (relative paths, more, a refusal)", () => {
  assert.deepEqual(parseFound("/p", "ma", { root: "/private/p", paths: ["src/main.ts", "main.md"], more: true }), { query: "ma", paths: ["/p/src/main.ts", "/p/main.md"], more: true, err: "" });
  assert.deepEqual(parseFound("/p", "x", { root: "/p", paths: [] }), { query: "x", paths: [], more: false, err: "" });
  // paths that try to leave the root are dropped (the core never sends them; text only)
  assert.deepEqual(parseFound("/p", "x", { paths: ["../etc/passwd", "/abs", "a/../../b", "ok.txt", 7] }).paths, ["/p/ok.txt"]);
});

test("filter: only the latest query's answer is shown", () => {
  const l = new Latest();
  const a = l.next();
  const b = l.next();
  assert.equal(l.is(a), false);
  assert.equal(l.is(b), true);
  l.next(); // cleared or retyped: b's answer is stale too
  assert.equal(l.is(b), false);
});

test("filter: rows are name and folder", () => {
  assert.deepEqual(foundRows("/p", ["/p/src/app/main.ts", "/p/README.md"]), [
    { path: "/p/src/app/main.ts", name: "main.ts", dir: "src/app" },
    { path: "/p/README.md", name: "README.md", dir: "" },
  ]);
});

test("filter: the keys over the results", () => {
  assert.equal(stepFound(-1, 3, "ArrowDown"), 0);
  assert.equal(stepFound(0, 3, "ArrowDown"), 1);
  assert.equal(stepFound(2, 3, "ArrowDown"), 2);
  assert.equal(stepFound(0, 3, "ArrowUp"), 0);
  assert.equal(stepFound(2, 3, "Home"), 0);
  assert.equal(stepFound(0, 3, "End"), 2);
  assert.equal(stepFound(5, 3, "ArrowUp"), 1); // fewer results now
  assert.equal(stepFound(0, 0, "ArrowDown"), -1);
});

test("filter: the note under the results", () => {
  const f = (paths: number, more: boolean, err = ""): Found => ({ query: "q", paths: Array.from({ length: paths }, (_, i) => "/p/" + i), more, err });
  assert.equal(foundNote(f(0, false)), "No files match");
  assert.equal(foundNote(f(3, false)), "");
  assert.equal(foundNote(f(100, true)), "100 shown, more match: type more to narrow");
  assert.equal(foundNote(f(0, false, "only inside a project folder")), "only inside a project folder");
});

const wt = (o: object) => ({ base: "/r/proj", loading: false, worktrees: [{ path: "/r/proj", branch: "main", main: true, head: "aaaaaaa1" }, { path: "/r/proj-wt", branch: "feature/x", head: "bbbbbbb2" }, { path: "/r/proj-det", detached: true, head: "ccccccc3" }, { path: "/r/gone", branch: "g", missing: true }, { path: "/r/pr", branch: "p", prunable: true }], ...o });

test("checkouts: the list (gone ones left out), names and branches", () => {
  const c = parseCheckouts(wt({}));
  assert.equal(c.base, "/r/proj");
  assert.deepEqual(c.list.map((x) => x.path), ["/r/proj", "/r/proj-wt", "/r/proj-det"]);
  assert.equal(checkoutLabel(c.list[1]), "feature/x");
  assert.equal(checkoutLabel(c.list[2]), "detached ccccccc");
  assert.equal(checkoutName(c.list[1]), "proj-wt");
  assert.equal(parseCheckouts({ loading: true }).loading, true);
  assert.deepEqual(parseCheckouts(null).list, []);
});

test("checkouts: the page's root: the remembered one while it is listed, else the tree's own", () => {
  const c: Checkouts = parseCheckouts(wt({}));
  assert.equal(viewRoot("/r/proj", "", c), "/r/proj");
  assert.equal(viewRoot("/r/proj", "/r/proj-wt", c), "/r/proj-wt");
  assert.equal(viewRoot("/r/proj", "/r/proj", c), "/r/proj"); // the project's own: no switch
  assert.equal(viewRoot("/r/proj", "/r/gone", c), "/r/proj"); // its folder went
  assert.equal(viewRoot("/r/proj", "/elsewhere", c), "/r/proj"); // not this repository's
  // the list not read yet: the remembered one (the core refuses what is not a listed checkout)
  assert.equal(viewRoot("/r/proj", "/r/proj-wt", null), "/r/proj-wt");
  assert.equal(viewRoot("/r/proj", "/r/proj-wt", parseCheckouts({ loading: true })), "/r/proj-wt");
  // a symlinked project folder: the core's base is the real path, the tree keeps its own
  assert.equal(viewRoot("/tmp/proj", "/r/proj", parseCheckouts(wt({}))), "/tmp/proj");
  assert.ok(CHECKOUT_KEY("/r/proj").startsWith("deckhand.files.checkout:"));
});

test("filter: Enter opens only the answer to what is typed now", () => {
  const f: Found = { query: "main", paths: ["/p/main.ts"], more: false, err: "" };
  assert.equal(enterOpens(f, "main", false), true);
  assert.equal(enterOpens(f, " main ", false), true);
  assert.equal(enterOpens(f, "mainx", false), false); // a newer query on its way
  assert.equal(enterOpens(f, "main", true), false); // asking again
  assert.equal(enterOpens(null, "main", false), false);
  assert.equal(enterOpens({ ...f, paths: [] }, "main", false), false);
});

test("checkouts: a project in a subfolder of its repository is offered none", () => {
  // list_worktrees from /r/mono/pkg: base is the package folder, not a checkout's top
  const c = parseCheckouts({ base: "/r/mono/pkg", loading: false, worktrees: [{ path: "/r/mono", branch: "main", main: true }, { path: "/r/mono-wt", branch: "x" }] });
  assert.deepEqual(c.list, []);
  assert.equal(viewRoot("/r/mono/pkg", "/r/mono-wt", c), "/r/mono/pkg");
  assert.equal(viewRoot("/r/mono/pkg", "/r/mono", c), "/r/mono/pkg");
});
