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
  assert.equal(forgetTypingMode(s), true);
  assert.equal(s.m.has(OLD_TYPING_KEY), false);
  assert.equal(s.m.get("deckhand.termFont"), "14");
  assert.equal(forgetTypingMode(s), false, "once: nothing saved any more");
  const d = mem({ [OLD_TYPING_KEY]: "direct" });
  assert.equal(forgetTypingMode(d), false);
  assert.equal(d.m.has(OLD_TYPING_KEY), false, "the old key goes either way");
});

test("typing: the text box is a one-time compose in the session menu; its Send pastes once, Enter apart, and closes", () => {
  const calls: string[] = [];
  const f = (n: string) => () => void calls.push(n);
  const base = { smaller: f("s"), larger: f("l"), copy: f("c"), compose: f("compose"), closeTab: f("ct"), closeSession: f("cs") };
  const items = phoneSessionItems({ ...base, tab: tab(1, "shell_tab"), terminal: true });
  const labels = items.filter((i) => !i.sep).map((i) => i.label);
  assert.ok(labels.includes("Type in a text box"));
  assert.ok(!labels.some((l) => /straight into the terminal|text field/.test(l ?? "")), "no mode switch");
  items.find((i) => i.label === "Type in a text box")!.run!();
  assert.deepEqual(calls, ["compose"]);
  assert.ok(!phoneSessionItems({ ...base, tab: tab(2, "changes_tab"), terminal: false }).some((i) => i.label === "Type in a text box"), "only over a terminal");
  assert.ok(!phoneSessionItems({ ...base, tab: tab(3, "pi_tab"), terminal: true }).some((i) => i.label === "Close this tab"), "pi's tab closes with its session");
  assert.deepEqual(composeSend("fix the tests\nplease"), { paste: "fix the tests\nplease", enter: true, close: true });
  assert.deepEqual(composeSend(""), { paste: null, enter: true, close: true });
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

test("insert path: the quoted path goes to the tab on screen when it is a running terminal, never with a newline", () => {
  const tabs = [tab(1, "pi_tab"), tab(2, "shell_tab"), tab(3, "changes_tab"), tab(4, "claude_tab", "exited")];
  assert.deepEqual(insertPath(tabs, 2, "/p/my file's.ts"), { type: "send_text", tab_id: 2, text: "'/p/my file'\\''s.ts' " });
  assert.deepEqual(insertPath(tabs, 1, "/p/a.ts")?.tab_id, 1);
  assert.equal(insertPath(tabs, 3, "/p/a.ts"), null, "not a terminal");
  assert.equal(insertPath(tabs, 4, "/p/a.ts"), null, "exited");
  assert.equal(insertPath(tabs, 9, "/p/a.ts"), null, "no such tab");
  assert.ok(!/[\r\n]/.test(insertPath(tabs, 2, "/p/a\nb")!.text));
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

test("exit bar: after Restart the pane attaches to the new process once (its old terminal's close is not the end)", async () => {
  const { reopenAfterClose } = await import("../src/state.ts");
  assert.equal(reopenAfterClose({ status: "running", attachable: true, retried: false }), true);
  assert.equal(reopenAfterClose({ status: "exited", attachable: true, retried: false }), false, "still dead: its last output stays");
  assert.equal(reopenAfterClose({ status: "running", attachable: true, retried: true }), false, "once: never a loop");
  assert.equal(reopenAfterClose({ status: "running", attachable: false, retried: false }), false);
  assert.equal(reopenAfterClose({ status: undefined, attachable: true, retried: false }), false, "the tab is gone");
});
