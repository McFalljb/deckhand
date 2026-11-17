import { test } from "node:test";
import assert from "node:assert/strict";
import { score } from "../src/app/match.ts";
import { tabView } from "../src/status.ts";

test("palette score: prefix, word start, anywhere, in order, none", () => {
  assert.equal(score("Split pane right", ""), 1);
  assert.equal(score("Split pane right", "split"), 100);
  assert.ok(score("Split pane right", "pane") > score("Unpaned", "pane"));
  assert.ok(score("Split pane right", "pane") > score("Split pane right", "spr"));
  assert.equal(score("Split pane right", "spr"), 10);
  assert.equal(score("Split pane right", "zz"), 0);
});

test("tab marks: waiting kinds, progress, finished", () => {
  const base = { id: 1, machine: 0, kind: { pi_tab: {} }, title: "", status: "running", agent: "idle", waiting: false, question: false, unseen: false };
  assert.equal(tabView({ ...base, waiting: true, prog: { state: "waiting", kind: "permission", msg: "Run rm?" } }).mark, "permission");
  const w = tabView({ ...base, agent: "working", prog: { state: "working", kind: "", progress: 40 } });
  assert.equal(w.mark, "progress");
  assert.equal(w.progress, 0.4);
  assert.equal(tabView({ ...base, unseen: true }).mark, "done");
  assert.equal(tabView(base).mark, "idle");
});

import { Store } from "../src/state.ts";
import { fold } from "../src/app/fold.ts";

test("web tree: keyed rows, a key alone is a top-level row, a delta changes one row", () => {
  const s = new Store();
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 9, group: "projects", machine: 0 }] },
    webtree: ["7", ["9", 1, 0, 1]],
    "webp:7": { id: 7, name: "alpha", path: "/a", pin: 0, hidden: false },
    "webp:9": { id: 9, name: "beta", path: "/a/b", pin: -1, hidden: false },
    "websl:7": ["s1"], "webs:7:s1": { label: "first", open: 0, pin: -1, hidden: false, dot: "none", claude: false, codex: false, modified: 0 },
  } });
  const t = s.webTree;
  assert.deepEqual(t.map((r) => [r.key, r.name, r.depth, r.forced]), [["7", "alpha", 0, false], ["9", "beta", 1, true]]);
  assert.equal(s.webSessions(7)?.[0].label, "first");
  assert.equal(s.webSessions(9), null); // not listed: the page shows "Loading…"
  assert.equal(s.webTree, t, "the same rows while nothing changed");
  s.applyDelta({ version: 2, sections: { "webp:9": { id: 9, name: "beta2", path: "/a/b", pin: -1, hidden: false } } });
  assert.equal(s.webTree[1].name, "beta2");
});

test("fold: a project opened before folds and unfolds with no command; a new one asks the core once", () => {
  const s = new Store();
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 9, group: "projects", machine: 0 }] },
    web: { watch: [7] },
  } });
  const sent: object[] = [];
  const link = { run: (c: object) => (sent.push(c), Promise.resolve({ ok: true })) } as any;
  fold.open.clear();
  fold.toggleOpen("7");
  fold.syncWatch(s, link);
  fold.toggleOpen("7");
  fold.syncWatch(s, link);
  assert.equal(sent.length, 0);
  fold.toggleOpen("9");
  fold.syncWatch(s, link);
  fold.syncWatch(s, link); // the same ask is not sent twice
  assert.deepEqual(sent, [{ type: "web_watch", projects: [9] }]);
});

import { reviewPrompt } from "../src/app/review.ts";

test("changes: the review prompt is the window's (src/ui_changes.odin changes_review_prompt)", () => {
  const l = { root: "/r", loading: false, branch: "feat", default_branch: "main", ahead: 2, files: [] };
  assert.equal(reviewPrompt(l), "Review the uncommitted changes in this checkout (/r): git status and git diff HEAD, and the 2 commits on feat that are not on main (git diff main...HEAD). Point out bugs, risks and unfinished work.");
  assert.equal(reviewPrompt({ ...l, ahead: 0 }), "Review the uncommitted changes in this checkout (/r): git status and git diff HEAD. Point out bugs, risks and unfinished work.");
});

import { parseMarkdown, inlines, safeHref, TABLE_CELLS_MAX } from "../src/app/markdown.ts";

test("markdown: blocks", () => {
  const b = parseMarkdown("# Title\n\nSome *em* and **strong** and `code`.\n\n```ts\nlet a = 1;\n```\n\n- [x] done\n- todo\n  - nested\n\n1. one\n2. two\n\n> quoted\n\n| a | b |\n|:--|--:|\n| 1 | 2 |\n\n---\nSetext\n===\n");
  assert.deepEqual(b.map((x) => x.t), ["h", "p", "code", "list", "list", "quote", "table", "hr", "h"]);
  const h = b[0] as any;
  assert.equal(h.id, "title");
  const l = b[3] as any;
  assert.equal(l.items[0].task, true);
  assert.equal(l.items[1].task, null);
  assert.equal(l.items[1].c[1].t, "list");
  assert.equal((b[4] as any).ordered, true);
  assert.deepEqual((b[6] as any).align, ["left", "right"]);
  assert.equal((b[8] as any).level, 1);
});

test("markdown: strict: no raw HTML, no script links", () => {
  const b = parseMarkdown("<script>alert(1)</script>\n\n[x](javascript:alert(1)) [y](data:text/html,hi) [z](https://ok.example/a) [r](docs/a.md) <img src=x onerror=alert(1)>");
  assert.equal(b[0].t, "html"); // shown as its source text
  const p = (b[1] as any).c;
  const links = p.filter((x: any) => x.t === "link").map((x: any) => x.href);
  assert.deepEqual(links, ["https://ok.example/a", "docs/a.md"]);
  assert.ok(p.some((x: any) => x.t === "text" && x.s.includes("<img src=x onerror=alert(1)>")), "inline tags stay text");
  assert.equal(safeHref("JaVaScRiPt:alert(1)"), null);
  assert.equal(safeHref("//evil.example"), null);
  assert.equal(safeHref("#section"), "#section");
});

test("markdown: hostile input stays bounded", () => {
  const t0 = Date.now();
  parseMarkdown(">".repeat(20000) + " deep");
  parseMarkdown("- ".repeat(5000) + "x");
  inlines("*".repeat(20000) + "a");
  inlines("[".repeat(20000));
  inlines("`".repeat(5000) + "a");
  parseMarkdown("word ".repeat(200000));
  assert.ok(Date.now() - t0 < 5000, `took ${Date.now() - t0} ms`);
});

test("markdown: a 4 MB file of openers parses in linear time", () => {
  const t0 = Date.now();
  for (const c of ["[", "*", "`", "_", "~~", "![", "<", "h", "*a "]) inlines(c.repeat((1 << 20) / c.length) + "x");
  assert.ok(Date.now() - t0 < 8000, `took ${Date.now() - t0} ms`);
});

test("markdown: review: fences, tables and images stay linear and bounded", () => {
  let t0 = Date.now();
  parseMarkdown("~~~" + "a".repeat(1 << 16) + "`"); // an info string the fence regex backtracked over
  assert.ok(Date.now() - t0 < 500, `fence: ${Date.now() - t0} ms`);
  const fenced = parseMarkdown("~~~ js `x`\nlet a\n~~~\n\n```ts\nb\n```");
  assert.deepEqual(fenced.map((x: any) => [x.t, x.lang, x.s]), [["code", "js", "let a"], ["code", "ts", "b"]]);
  // a wide header with many short rows: each row is not widened past the cap
  const w = 20000;
  t0 = Date.now();
  const b = parseMarkdown("|" + "a|".repeat(w) + "\n|" + "-|".repeat(w) + "\n" + "|x\n".repeat(20000));
  const cellsOf = (bs: any[]) => bs.filter((x) => x.t === "table").reduce((n, x) => n + x.head.length + x.rows.length * x.head.length, 0);
  assert.ok(cellsOf(b) <= TABLE_CELLS_MAX, `${cellsOf(b)} cells`);
  assert.ok(Date.now() - t0 < 2000, `table: ${Date.now() - t0} ms`);
  // images nested deep: no deeper than links (no stack overflow)
  const n = 20000;
  assert.doesNotThrow(() => inlines("![".repeat(n) + "x" + "]()".repeat(n)));
  assert.deepEqual(inlines("![a *b*](u.png)"), [{ t: "img", alt: "a b" }]);
});

import { narrowTree } from "../src/app/treefilter.ts";

test("filter at once: the tree the page holds, narrowed the core's way, parents kept", () => {
  const row = (key: string, depth: number, id: number, name: string, path: string) => ({ key, depth, kids: 0, forced: false, id, name, path, pin: -1, hidden: false });
  const tree = [
    row("a", 0, 1, "recipe-box", "/h/code/recipe-box"),
    row("g", 0, 0, "big", "/h/big"), // a group row (a folder)
    row("b", 1, 2, "p120-fix", "/h/big/p120-fix"),
    row("c", 1, 3, "p200-cache", "/h/big/p200-cache"),
    row("d", 0, 4, "garden", "/h/garden-planner"),
  ];
  assert.deepEqual(narrowTree(tree, "").map((r) => r.key), ["a", "g", "b", "c", "d"]);
  assert.deepEqual(narrowTree(tree, "p12").map((r) => r.key), ["g", "b"]); // the group row kept as its parent
  assert.deepEqual(narrowTree(tree, "planner").map((r) => r.key), ["d"]); // the path, as a substring
  assert.deepEqual(narrowTree(tree, "rcp bx").map((r) => r.key), ["a"]); // each word, the name fuzzily
  assert.deepEqual(narrowTree(tree, "zzz").map((r) => r.key), []);
  const big = Array.from({ length: 5000 }, (_, i) => row("k" + i, 0, i + 1, `p${i}-name`, `/h/big/p${i}-name`));
  const t0 = performance.now();
  narrowTree(big, "p12");
  assert.ok(performance.now() - t0 < 250, "5,000 rows in well under a keystroke (about 5 ms here; loose for a busy machine)");
});

import { knowFile, knownFile } from "../src/app/filecache.ts";

test("file tabs: the files read last are kept by path, at most 8 and 16 MB of text", () => {
  const f = (path: string, n: number) => ({ path, size: n, mtime: 0, hash: path, markdown: false, text: "x".repeat(n) });
  for (let i = 0; i < 10; i++) knowFile("/p/" + i, f("/p/" + i, 10));
  assert.equal(knownFile("/p/0"), undefined); // the oldest went
  assert.equal(knownFile("/p/9")?.hash, "/p/9");
  knowFile("/p/big1", f("/p/big1", 9 << 20));
  knowFile("/p/big2", f("/p/big2", 9 << 20)); // over 16 MB: the older big one goes, not the newest
  assert.equal(knownFile("/p/big1"), undefined);
  assert.equal(knownFile("/p/big2")?.hash, "/p/big2");
});

import { FileReads } from "../src/app/filecache.ts";

test("file tabs: a read belongs to the path it was made for (#148 review)", () => {
  const reads = new FileReads();
  reads.show(); // file A
  const a = reads.begin(false);
  assert.notEqual(a, null);
  assert.equal(reads.begin(false), null, "A's poll waits for A's read");
  reads.show(); // file B (known: its first read is not forced)
  const b = reads.begin(false);
  assert.notEqual(b, null, "B's read is not held up by A's");
  assert.equal(reads.end(a!), false, "A's reply is dropped under B");
  assert.equal(reads.begin(false), null, "B's poll waits for B's read");
  assert.equal(reads.end(b!), true);
  assert.notEqual(reads.begin(false), null);
  assert.equal(reads.current(a!), false);
});

import { newSessionChoices } from "../src/app/harness.ts";

test("new session: the core's choices per machine and kind, Chats too; none says why", () => {
  const s = new Store();
  const pi = { harness: "pi", label: "pi" }, cc = { harness: "claude", label: "Claude Code" }, cx = { harness: "codex", label: "Codex" };
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 8, group: "chats", machine: 0 }, { id: 9, group: "projects", machine: 2 }, { id: 10, group: "projects", machine: 3 }] },
    web: { watch: [], new: [
      { machine: 0, projects: [cc, pi, cx], chats: [cc, cx], note: "install one" },
      { machine: 2, projects: [cx], chats: [], note: "nothing on m2" },
      { machine: 3, projects: [], chats: [], note: "nothing on m3" },
    ] },
  } });
  const view = (id: number) => newSessionChoices(s, id).map((c) => [c.label, JSON.stringify(c.cmd ?? null)]);
  assert.deepEqual(view(7), [
    ["Claude Code", '{"type":"new_claude_session","project_id":7}'],
    ["pi", '{"type":"new_chat","project_id":7}'],
    ["Codex", '{"type":"new_claude_session","project_id":7,"harness":"codex"}'],
  ]);
  assert.deepEqual(view(8).map((x) => x[0]), ["Claude Code", "Codex"], "Claude Code and Codex in Chats, no pi when it is not there");
  assert.deepEqual(view(9).map((x) => x[0]), ["Codex"]);
  // another machine with nothing: why, and a session anyway (its pi tab says how to install one)
  assert.deepEqual(view(10), [["nothing on m3", "null"], ["New session", '{"type":"new_chat","project_id":10}']]);
  assert.equal(newSessionChoices(s, 10)[0].note, true);
  // this machine with nothing: only why
  s.applyDelta({ version: 2, sections: { web: { watch: [], new: [{ machine: 0, projects: [], chats: [], note: "install one" }] } } });
  assert.deepEqual(view(7), [["install one", "null"]]);
});

import { newSessionPlan, newTabChoices } from "../src/app/harness.ts";

test("new session: one row per account, one choice starts at once, none says why; tab rows only where installed", () => {
  const s = new Store();
  const pi = { harness: "pi", label: "pi", account: "" };
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 8, group: "chats", machine: 0 }, { id: 9, group: "projects", machine: 2 }, { id: 10, group: "projects", machine: 3 }] },
    web: { watch: [], new: [
      { machine: 0, projects: [{ harness: "claude", label: "Claude Code · work", account: "/h/.claude-work" }, { harness: "claude", label: "Claude Code · home", account: "/h/.claude" }, pi], chats: [pi], note: "install one",
        claude_tab: [{ account: "/h/.claude-work", name: "work" }, { account: "/h/.claude", name: "home" }], codex_tab: [] },
      { machine: 2, projects: [], chats: [], claude_tab: [{ account: "", name: "" }], codex_tab: [{ account: "", name: "" }], note: "nothing on m2" },
      { machine: 3, projects: [], chats: [], claude_tab: [], codex_tab: [], note: "nothing on m3" },
    ] },
  } });
  assert.deepEqual(newSessionChoices(s, 7)[0].cmd, { type: "new_claude_session", project_id: 7, account: "/h/.claude-work" });
  assert.equal("pick" in newSessionPlan(s, 7), true);
  assert.deepEqual(newSessionPlan(s, 8), { run: { type: "new_chat", project_id: 8 } }, "one choice: at once");
  assert.deepEqual(newSessionPlan(s, 9), { run: { type: "new_chat", project_id: 9 }, toast: "nothing on m2", err: false }, "another machine with none: a session anyway");
  s.applyDelta({ version: 2, sections: { web: { watch: [], new: [{ machine: 0, projects: [], chats: [], note: "install one" }] } } });
  assert.deepEqual(newSessionPlan(s, 7), { toast: "install one", err: true }, "this machine with none: why");
  s.applyDelta({ version: 3, sections: { web: { watch: [], new: [
    { machine: 0, projects: [], chats: [], note: "", claude_tab: [{ account: "/h/.claude-work", name: "work" }, { account: "/h/.claude", name: "home" }], codex_tab: [] },
    { machine: 2, projects: [], chats: [], note: "", claude_tab: [{ account: "", name: "" }], codex_tab: [{ account: "", name: "" }] },
  ] } } });
  assert.deepEqual(newTabChoices(s, 0, { session: 5 }, false, "New Claude tab").map((c) => [c.label, JSON.stringify(c.cmd)]), [
    ["New Claude tab · work", '{"type":"new_claude_tab","session":5,"account":"/h/.claude-work"}'],
    ["New Claude tab · home", '{"type":"new_claude_tab","session":5,"account":"/h/.claude"}'],
  ]);
  assert.deepEqual(newTabChoices(s, 0, { session: 5 }, true, "New Codex tab"), [], "no Codex here");
  assert.deepEqual(newTabChoices(s, 2, { project_id: 9 }, true, "New Codex tab").map((c) => c.cmd), [{ type: "new_claude_tab", project_id: 9, harness: "codex" }]);
  assert.deepEqual(newTabChoices(s, 3, { project_id: 10 }, false, "x"), [], "an unknown machine: none");
});

import { barPrimary, barsFor } from "../src/app/bars.ts";

test("status strip: a tab's own bars, then its harness's hot-reload bars; none for other tabs", () => {
  const s = new Store();
  const bar = (tab: number, harness: string, kind: string) => ({ tab, harness, kind, tone: "waiting", text: kind, actions: [] });
  s.applyFull({ version: 1, state: { webbars: [bar(5, "claude", "held"), bar(6, "codex", "status"), bar(0, "pi", "reload"), bar(0, "claude", "claude_reload")] } });
  const tab = (id: number, kind: object) => ({ id, machine: 0, kind, title: "", status: "running", agent: "idle", waiting: false, question: false }) as any;
  assert.deepEqual(barsFor(s, tab(5, { claude_tab: {} })).map((b) => b.kind), ["held", "claude_reload"]);
  assert.deepEqual(barsFor(s, tab(6, { claude_tab: { codex: true } })).map((b) => b.kind), ["status"], "a Codex tab: not Claude Code's reload bar");
  assert.deepEqual(barsFor(s, tab(7, { pi_tab: {} })).map((b) => b.kind), ["reload"]);
  assert.deepEqual(barsFor(s, tab(8, { shell_tab: {} })), []);
  s.applyDelta({ version: 2, sections: { webbars: null } });
  assert.deepEqual(barsFor(s, tab(5, { claude_tab: {} })), []);
});

test("new session: a project whose picker differs (its last used account) gets its own rows, first as the native picker's", () => {
  const s = new Store();
  const work = { harness: "claude", label: "Claude Code · work", account: "/h/.claude-work" };
  const home = { harness: "claude", label: "Claude Code · home", account: "/h/.claude" };
  s.applyFull({ version: 1, state: {
    projects: { projects: [{ id: 7, group: "projects", machine: 0 }, { id: 8, group: "projects", machine: 0 }] },
    web: { watch: [], new: [{ machine: 0, projects: [work, home], chats: [work, home], note: "", claude_tab: [], codex_tab: [], project_rows: [{ project: 7, rows: [home, work] }] }] },
  } });
  assert.deepEqual(newSessionChoices(s, 7).map((c) => c.label), ["Claude Code · home", "Claude Code · work"], "project 7: its last used first");
  assert.deepEqual(newSessionChoices(s, 7)[0].cmd, { type: "new_claude_session", project_id: 7, account: "/h/.claude" });
  assert.deepEqual(newSessionChoices(s, 8).map((c) => c.label), ["Claude Code · work", "Claude Code · home"], "another project: its kind's list");
});

test("status strip: Restart anyway is carried as the core wrote it, never the strip's primary button", () => {
  const s = new Store();
  const actions = [
    { label: "Restart anyway", command: { type: "claude_restart_anyway", tab_id: 5 } },
    { label: "Later", command: { type: "claude_reload_later" } },
  ];
  s.applyFull({ version: 1, state: { webbars: [{ tab: 0, harness: "claude", kind: "claude_reload", tone: "info", text: "Restarting Claude — 1 tab waits until idle · Claude: a subagent silent for 2h 05m", actions }] } });
  const tab = (id: number, kind: object) => ({ id, machine: 0, kind, title: "", status: "running", agent: "idle", waiting: false, question: false }) as any;
  const bars = barsFor(s, tab(5, { claude_tab: {} }));
  assert.deepEqual(bars.map((b) => b.actions.map((a) => a.label)), [["Restart anyway", "Later"]]);
  assert.deepEqual(bars[0].actions[0].command, { type: "claude_restart_anyway", tab_id: 5 });
  assert.equal(barPrimary(bars[0]), 1, "the last command (Later) is the strip's primary, not Restart anyway");
  assert.deepEqual(barsFor(s, tab(6, { claude_tab: { codex: true } })), [], "a Codex tab: not Claude Code's bar");
});

test("status strip: another machine's tab shows none of this machine's bars (#152 review)", () => {
  const s = new Store();
  s.applyFull({ version: 1, state: { webbars: [{ tab: 0, harness: "pi", kind: "reload", tone: "info", text: "pi settings changed", actions: [{ label: "Reload", command: { type: "pi_reload_all", only_changed: true } }] }] } });
  const remote = { id: 9, machine: 2, kind: { pi_tab: {} }, title: "", status: "running", agent: "idle", waiting: false, question: false } as any;
  assert.deepEqual(barsFor(s, remote), [], "a remote pi tab: its own core's bars, not this one's Reload");
  assert.equal(barsFor(s, { ...remote, machine: 0 }).length, 1);
});

import { modeBadge } from "../src/app/harness.ts";

test("tab badge: a Claude or Codex tab's permission mode, quiet unless it acts without asking (src/core/claude_mode.odin)", () => {
  assert.equal(modeBadge(null), null);
  assert.equal(modeBadge({ shell_tab: {} }), null);
  assert.equal(modeBadge({ claude_tab: {} }), null); // an older core: no field
  assert.equal(modeBadge({ claude_tab: { permission_mode: "" } }), null);
  assert.equal(modeBadge({ claude_tab: { permission_mode: "default" } }), null);
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "plan" } }), { label: "plan", warn: false });
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "acceptEdits" } }), { label: "accept edits", warn: false });
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "bypassPermissions" } }), { label: "bypass", warn: true });
  assert.deepEqual(modeBadge({ claude_tab: { codex: true, permission_mode: "codex-full-access" } }), { label: "full access", warn: true });
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "newMode" } }), { label: "newMode", warn: true });
  assert.equal(modeBadge({ claude_tab: { permission_mode: "<b>x</b>" } }), null);
  assert.equal(modeBadge({ claude_tab: { permission_mode: 3 } }), null);
});

test("tab badge: auto and an unknown mode get the warning colour; Codex's other ways of not asking too", () => {
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "auto" } }), { label: "auto", warn: true });
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "someNewMode" } }), { label: "someNewMode", warn: true });
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "codex-never-asks" } }), { label: "never asks", warn: true });
  assert.deepEqual(modeBadge({ claude_tab: { permission_mode: "codex-approves" } }), { label: "approves for you", warn: true });
  assert.equal(modeBadge({ claude_tab: { permission_mode: "codex-read-only" } }), null); // never a safer-sounding Codex badge
});
