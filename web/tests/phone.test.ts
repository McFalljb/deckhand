// The phone's choices (src/app/phone.ts): typing straight in by default (the text box a one-time
// compose, never a saved mode), the exit bar, desktop-only palette entries, Insert path.

import { test } from "node:test";
import assert from "node:assert/strict";
import { composeSend, exitBar, forgetTypingMode, insertPath, OLD_TYPING_KEY, paletteShows, phoneSessionItems } from "../src/app/phone.ts";
import type { Tab } from "../src/state.ts";

const tab = (id: number, kind: string, status = "running", extra: Partial<Tab> = {}): Tab => ({
  id,
  machine: 0,
  kind: { [kind]: {} },
  title: "",
  status,
  agent: "idle",
  waiting: false,
  question: false,
  unseen: false,
  ...extra,
});

function mem(init: Record<string, string>) {
  const m = new Map(Object.entries(init));
  return { m, get: (k: string) => m.get(k) ?? null, remove: (k: string) => void m.delete(k) };
}

test("typing: a browser left in the saved text-box mode types straight in again, once; nothing else is touched", () => {
  const s = mem({ [OLD_TYPING_KEY]: "field", "deckhand.termFont": "14" });
  assert.equal(forgetTypingMode(s, { done: false }), true);
  assert.equal(s.m.has(OLD_TYPING_KEY), false);
  assert.equal(s.m.get("deckhand.termFont"), "14");
  assert.equal(forgetTypingMode(s, { done: false }), false, "once: nothing saved any more");
  const d = mem({ [OLD_TYPING_KEY]: "direct" });
  assert.equal(forgetTypingMode(d, { done: false }), false);
  assert.equal(d.m.has(OLD_TYPING_KEY), false, "the old key goes either way");
});

test("typing: the text box is a one-time compose in the session menu; its Send pastes once, Enter apart, and closes", () => {
  const calls: string[] = [];
  const f = (n: string) => () => void calls.push(n);
  const base = { smaller: f("s"), larger: f("l"), copy: f("c"), compose: f("compose"), select: f("select"), closeTab: f("ct"), closeSession: f("cs") };
  const items = phoneSessionItems({ ...base, tab: tab(1, "shell_tab"), terminal: true });
  const labels = items.filter((i) => !i.sep).map((i) => i.label);
  assert.ok(labels.includes("Type in a text box"));
  assert.ok(!labels.some((l) => /straight into the terminal|text field/.test(l ?? "")), "no mode switch");
  items.find((i) => i.label === "Type in a text box")!.run!();
  assert.deepEqual(calls, ["compose"]);
  assert.ok(!phoneSessionItems({ ...base, tab: tab(2, "changes_tab"), terminal: false }).some((i) => i.label === "Type in a text box"), "only over a terminal");
  assert.ok(!phoneSessionItems({ ...base, tab: tab(3, "pi_tab"), terminal: true }).some((i) => i.label === "Close this tab"), "pi's tab closes with its session");
  assert.deepEqual(composeSend("fix the tests\nplease", true), { paste: "fix the tests\nplease", enter: true, close: true });
  assert.deepEqual(composeSend("", true), { paste: null, enter: true, close: true });
});

test("exit bar: an exited agent tab offers Restart (and Close but for pi), as the desktop's; a running tab has none", () => {
  assert.equal(exitBar(tab(1, "pi_tab")), null);
  assert.deepEqual(exitBar(tab(1, "pi_tab", "exited", { exit: { known: true, code: 1, signal: 0 } })), { text: "Exited (code 1)", restart: "pi_restart", close: false });
  assert.deepEqual(exitBar(tab(2, "claude_tab", "exited", { exit: { known: true, code: 0, signal: 9 } })), { text: "Exited (signal 9)", restart: "claude_restart", close: true });
  assert.deepEqual(exitBar(tab(3, "shell_tab", "exited")), { text: "Exited", restart: "", close: true });
});

test("palette: layout entries that change the desktop's window are not on a phone", () => {
  for (const id of ["split_right", "split_down", "close_pane", "equalize_panes", "zoom_pane", "focus_pane_left", "focus_pane_down", "toggle_left", "toggle_right", "dim_panes"]) {
    assert.equal(paletteShows(id, true), false, id);
    assert.equal(paletteShows(id, false), true, id);
  }
  for (const id of ["new_shell_tab", "close_tab", "next_tab", "text_bigger", "settings"]) assert.equal(paletteShows(id, true), true, id);
});

test("insert path: the Mac's drop rule: a shell's path shell-quoted, an agent's plain unless it must be; marked generated (the core's Codex check)", () => {
  const tabs = [tab(1, "pi_tab"), tab(2, "shell_tab"), tab(3, "changes_tab"), tab(4, "claude_tab", "exited"), tab(5, "claude_tab")];
  assert.deepEqual(insertPath(tabs, 2, "/p/my file's.ts"), { cmd: { type: "send_text", tab_id: 2, text: "'/p/my file'\\''s.ts' ", generated: true } });
  // an agent's prompt: plain, but quoted when a word starts / ! $ @ (a command or a picker) or has a space or quote
  assert.deepEqual(insertPath(tabs, 1, "rel/a.ts"), { cmd: { type: "send_text", tab_id: 1, text: "rel/a.ts ", generated: true } });
  assert.equal((insertPath(tabs, 5, "/p/a.ts") as any).cmd.text, "'/p/a.ts' ");
  assert.equal((insertPath(tabs, 5, "notes @x.md") as any).cmd.text, "'notes @x.md' ");
  assert.equal((insertPath(tabs, 5, "@x.md") as any).cmd.text, "'@x.md' ");
  assert.equal((insertPath(tabs, 5, "/p/a.ts") as any).cmd.generated, true, "the core refuses it into a Codex that waits, as the Mac's drop");
  assert.equal(insertPath(tabs, 3, "/p/a.ts"), null, "not a terminal");
  assert.equal(insertPath(tabs, 4, "/p/a.ts"), null, "exited");
  assert.equal(insertPath(tabs, 9, "/p/a.ts"), null, "no such tab");
});

test("insert path: a name with a control character (C0, DEL, C1) is refused with why, never typed", () => {
  const tabs = [tab(2, "shell_tab"), tab(1, "pi_tab")];
  for (const p of ["/p/a\nb", "/p/a\x1bb", "/p/a\x7fb", "/p/a\u0085b", "/p/a\u009bb"]) {
    assert.deepEqual(insertPath(tabs, 2, p), { error: "a name has a control character" }, JSON.stringify(p));
    assert.deepEqual(insertPath(tabs, 1, p), { error: "a name has a control character" }, JSON.stringify(p));
  }
  assert.ok("cmd" in (insertPath(tabs, 2, "/p/é ü.ts") as any), "other non-ASCII goes");
});

test("Atlas drawer: its own terminal is not covered by the drawer (typing, touch scroll); a menu over it still covers it", async () => {
  const { covering } = await import("../src/app/phone.ts");
  const none = { menu: null, sheet: null, palette: false, bell: false, link: null, copy: null, job: null, peek: null } as any;
  assert.equal(covering(none, true), true, "the session under the drawer: covered");
  assert.equal(covering(none, true, true), false, "the drawer's own terminal");
  assert.equal(covering({ ...none, sheet: { title: "", items: [] } }, true, true), true);
  assert.equal(covering(none, false), false);
});

test("Atlas drawer: on a phone it shows only when this phone opened it (the core's home_open is the Mac window's, or an agent's set_home)", async () => {
  const { drawerShown } = await import("../src/app/phone.ts");
  const none = { menu: null, sheet: null, palette: false, bell: false, link: null, copy: null, job: null, peek: null, atlas: false } as any;
  assert.equal(drawerShown(true, none, true), false, "the Mac's drawer does not cover the phone");
  assert.equal(drawerShown(true, { ...none, atlas: true }, false), true);
  assert.equal(drawerShown(false, none, true), true, "the desktop follows the core");
  assert.equal(drawerShown(false, { ...none, atlas: true }, false), false);
});

test("exit bar: after Restart the pane attaches to the new process (its old terminal's close is not the end)", async () => {
  const { ReopenGuard } = await import("../src/state.ts");
  const g = new ReopenGuard();
  assert.equal(g.want("running", true), true, "the new process: attach");
  g.live(); // its bytes came: it worked
  assert.equal(g.want("exited", true), false, "still dead: its last output stays");
  assert.equal(g.want("running", true), true, "the next Restart attaches again");
  assert.equal(g.want("running", false), false, "not attachable");
  assert.equal(g.want(undefined, true), false, "the tab is gone");
});

test("reopen: a stream that is attached then closed at once (another machine's missing terminal) stops after a few tries", async () => {
  const { ReopenGuard, REOPEN_TRIES } = await import("../src/state.ts");
  const g = new ReopenGuard();
  let n = 0;
  for (let i = 0; i < 50; i++) if (g.want("running", true)) n++; // attached, no bytes, Close, again…
  assert.equal(n, REOPEN_TRIES, "capped: no loop");
  g.status("exited"); // the process went again: a new Restart is a new chance
  assert.equal(g.want("running", true), true);
});

test("reopen: a reattach that got an error does not block the next real Restart", async () => {
  const { ReopenGuard } = await import("../src/state.ts");
  const g = new ReopenGuard();
  assert.equal(g.want("running", true), true); // reattach … error (no bytes ever came)
  g.status("exited"); // the user's next Restart: the tab leaves running…
  assert.equal(g.want("running", true), true, "…and attaches again");
});
test("text box: Send while the terminal is not attached keeps the box open with its text, and says why", () => {
  assert.deepEqual(composeSend("a long message", false), { keep: true, error: "Not sent: this tab's terminal is not connected. Your text is still in the box." });
  assert.deepEqual(composeSend("", false), { keep: true, error: "Not sent: this tab's terminal is not connected. Your text is still in the box." });
});

test("typing: the switch back shows its toast at most once per page, and a storage that cannot remove is treated as done", () => {
  const once = { done: false };
  const stuck = { get: (_k: string) => "field", remove: (_k: string) => {} }; // removeItem failed (swallowed)
  assert.equal(forgetTypingMode(stuck, once), false, "the key is still there after remove: no toast, every load");
  const s = mem({ [OLD_TYPING_KEY]: "field" });
  const once2 = { done: false };
  assert.equal(forgetTypingMode(s, once2), true);
  s.m.set(OLD_TYPING_KEY, "field");
  assert.equal(forgetTypingMode(s, once2), false, "once per page load");
  const throwing = { get: (_k: string): string | null => { throw new Error("SecurityError"); }, remove: (_k: string) => { throw new Error("SecurityError"); } };
  assert.equal(forgetTypingMode(throwing, { done: false }), false, "no storage: nothing to switch");
});

test("Atlas on a phone: opening and closing it never opens or closes the Mac's drawer; starting it is its own, labelled button", async () => {
  const { atlasToggle, atlasNeedsStart } = await import("../src/app/phone.ts");
  assert.deepEqual(atlasToggle(true, false, false), { atlas: true, cmd: null }, "open: the phone's own, no set_home");
  assert.deepEqual(atlasToggle(true, true, true), { atlas: false, cmd: null }, "close: the Mac's drawer stays as it is");
  assert.deepEqual(atlasToggle(true, true, false), { atlas: false, cmd: null });
  assert.deepEqual(atlasToggle(false, false, false), { atlas: false, cmd: { type: "set_home", open: true } }, "the desktop follows the core");
  assert.deepEqual(atlasToggle(false, false, true), { atlas: false, cmd: { type: "set_home", open: false } });
  assert.equal(atlasNeedsStart(undefined), true, "never started: no tab");
  assert.equal(atlasNeedsStart("not_started"), true, "restored, not started");
  assert.equal(atlasNeedsStart("running"), false);
  assert.equal(atlasNeedsStart("exited"), false, "the exit bar's Restart");
});

test("Atlas on a phone: Start Atlas starts its pi without the Mac's drawer (start_home, never set_home)", async () => {
  const { ATLAS_START } = await import("../src/app/phone.ts");
  assert.deepEqual(ATLAS_START, { type: "start_home" });
});

test("palette: on a phone, nothing that changes the Mac's view: Changes into its panes, the sidebar's sorts and Show hidden", () => {
  for (const id of ["show_changes", "show_hidden", "sort_projects", "sort_sessions", "sort_chats"]) {
    assert.equal(paletteShows(id, true), false, id);
    assert.equal(paletteShows(id, false), true, id);
  }
  for (const id of ["filter", "clear_filter", "quick_running", "quick_waiting", "quick_pinned", "show_deck", "show_jobs", "new_shell_tab"]) assert.equal(paletteShows(id, true), true, id + " (phone-local on a phone)");
});

test("filter: a browser's filter and chips are its own (\"web\".filter), never the Mac's sidebar filter", async () => {
  const { ownFilter } = await import("../src/app/treefilter.ts");
  assert.deepEqual(ownFilter(null), { text: "", running: false, waiting: false, pinned: false }, "before the core's first answer");
  const web = { filter: { text: "api", running: true, waiting: false, pinned: false } } as any;
  assert.deepEqual(ownFilter(web), { text: "api", running: true, waiting: false, pinned: false });
  assert.deepEqual(ownFilter({} as any), { text: "", running: false, waiting: false, pinned: false }, "none set yet");
});

test("panels on a phone: the session's panels (pi's, a Claude tab's subagents, background and todos) once each, in tab order", async () => {
  const { sessionPanels, panelView } = await import("../src/app/phone.ts");
  const P = (id: string, title: string, rows: { text: string; tone?: string; head?: boolean }[] = []) => ({ id, title, rows: rows.map((r) => ({ text: r.text, tone: r.tone ?? "normal", head: !!r.head })) });
  const of: Record<number, any[]> = {
    1: [P("todos", "Todos", [{ text: "Todos 1/2", head: true }, { text: "✓ a" }, { text: "○ b" }])],
    2: [P("subagents", "Subagents", [{ text: "explore: running" }]), P("background", "Background", [{ text: "npm test" }])],
    3: [P("todos", "Todos (another tab)")],
  };
  const got = sessionPanels([tab(1, "pi_tab"), tab(2, "claude_tab"), tab(3, "shell_tab")], (id) => of[id] ?? []);
  assert.deepEqual(got.map((p) => p.id), ["todos", "subagents", "background"], "one per id, the first tab's");
  assert.deepEqual(sessionPanels([], () => []), []);
  // a bridge's first head row is the panel's title, as the window draws it
  const v = panelView(got[0]);
  assert.equal(v.head, "Todos 1/2");
  assert.deepEqual(v.rows.map((r) => r.text), ["✓ a", "○ b"]);
  assert.deepEqual(panelView(got[1]), { head: "Subagents", rows: got[1].rows });
});

test("panels on a phone: the sheet stops the terminal's typing, as any sheet", async () => {
  const { covering } = await import("../src/app/phone.ts");
  const none = { menu: null, sheet: null, palette: false, bell: false, link: null, copy: null, job: null, peek: null, atlas: false, panels: null } as any;
  assert.equal(covering(none, false), false);
  assert.equal(covering({ ...none, panels: 3 }, false), true);
});

test("select text: over a terminal the session menu has Select text (the scrollback and screen in a sheet to select from); its sheet stops the typing", async () => {
  const { covering } = await import("../src/app/phone.ts");
  const calls: string[] = [];
  const f = (n: string) => () => void calls.push(n);
  const base = { smaller: f("s"), larger: f("l"), copy: f("copy"), compose: f("compose"), select: f("select"), closeTab: f("ct"), closeSession: f("cs") };
  const items = phoneSessionItems({ ...base, tab: tab(1, "shell_tab"), terminal: true });
  items.find((i) => i.label === "Select text")!.run!();
  assert.deepEqual(calls, ["select"]);
  assert.ok(!phoneSessionItems({ ...base, tab: tab(2, "changes_tab"), terminal: false }).some((i) => i.label === "Select text"), "only over a terminal");
  const none = { menu: null, sheet: null, palette: false, bell: false, link: null, copy: null, job: null, peek: null, atlas: false, panels: null, select: null } as any;
  assert.equal(covering({ ...none, select: "text" }, false), true);
});

test("Atlas's button: shown once Atlas has a session, or before its first start when the core offers it (pi installed)", async () => {
  const { atlasShown } = await import("../src/app/phone.ts");
  assert.equal(atlasShown(7, null), true, "a Home session");
  assert.equal(atlasShown(0, { atlas: true } as any), true, "never started: Start Atlas starts it");
  assert.equal(atlasShown(0, { atlas: false } as any), false, "no pi: no button");
  assert.equal(atlasShown(0, null), false);
});

test("file editing on a phone: the editor's text is 16 px (iOS zooms the page into a field under 16 px) with its own line height", async () => {
  const { codeMetrics } = await import("../src/app/phone.ts");
  assert.deepEqual(codeMetrics(true), { cls: "code-edit phone", lineH: 22 });
  assert.deepEqual(codeMetrics(false), { cls: "code-edit", lineH: 18 });
});
