// A phone keyboard typing straight into a terminal (src/phoneinput.ts): the hidden field's text as
// the bytes the terminal gets (typing, autocorrect and dictation replacing a word, Backspace with
// nothing typed, IME composition), the keys a keyboard sends as keys, and sticky Ctrl/Alt.

import { test } from "node:test";
import assert from "node:assert/strict";
import { applyMods, FieldModel, keyBytes, SENTINEL } from "../src/phoneinput.ts";

const typed = (m: FieldModel, after: string, composing = false) => m.input(SENTINEL + after, composing);

test("typed letters go as they are typed", () => {
  const m = new FieldModel();
  assert.equal(typed(m, "l"), "l");
  assert.equal(typed(m, "ls"), "s");
  assert.equal(typed(m, "ls -"), " -");
});

test("Backspace in the field is DEL; with nothing typed (the sentinel deleted) still DEL", () => {
  const m = new FieldModel();
  typed(m, "ab");
  assert.equal(typed(m, "a"), "\x7f");
  assert.equal(typed(m, ""), "\x7f");
  assert.equal(m.input("", false), "\x7f"); // the sentinel itself went: one more Backspace
  assert.equal(m.needsReset(""), true);
  m.reset();
  assert.equal(m.input("", false), "\x7f"); // and again, every time
});

test("a word replaced (autocorrect, dictation, a suggestion) is deleted and typed again, never doubled", () => {
  const m = new FieldModel();
  typed(m, "git sttaus");
  assert.equal(typed(m, "git status"), "\x7f\x7f\x7f\x7f" + "atus");
  // dictation replacing its own first guess
  const d = new FieldModel();
  assert.equal(typed(d, "hello word"), "hello word");
  assert.equal(typed(d, "hello world"), "\x7fld");
});

test("a line break in the field is Enter (CR)", () => {
  const m = new FieldModel();
  assert.equal(typed(m, "a\n"), "a\r");
});

test("composition: Latin text goes live; other scripts wait for the composition's end", () => {
  const m = new FieldModel();
  assert.equal(typed(m, "h", true), "h");
  assert.equal(typed(m, "he", true), "e");
  assert.equal(typed(m, "hey", false), "y");
  const j = new FieldModel();
  assert.equal(typed(j, "に", true), "");
  assert.equal(typed(j, "にほ", true), "");
  assert.equal(typed(j, "日本", false), "日本"); // compositionend: the committed text, once
  assert.equal(typed(j, "日本", false), "");
});

test("the field is emptied when long or when the sentinel goes, never mid-composition", () => {
  const m = new FieldModel();
  typed(m, "x".repeat(40));
  assert.equal(m.needsReset(SENTINEL + "x".repeat(40)), true);
  m.reset();
  assert.equal(typed(m, "y"), "y");
  assert.equal(m.needsReset(SENTINEL + "y"), false);
});

test("keys that are keys: Enter, Tab, Esc, arrows (application cursor mode too), Ctrl-letter", () => {
  const k = (key: string, mods: Partial<{ ctrl: boolean; alt: boolean; shift: boolean; meta: boolean }> = {}, app = false) =>
    keyBytes(key, { ctrl: false, alt: false, shift: false, meta: false, ...mods }, app);
  assert.equal(k("Enter"), "\r");
  assert.equal(k("Tab"), "\t");
  assert.equal(k("Tab", { shift: true }), "\x1b[Z");
  assert.equal(k("Escape"), "\x1b");
  assert.equal(k("ArrowUp"), "\x1b[A");
  assert.equal(k("ArrowUp", {}, true), "\x1bOA");
  assert.equal(k("ArrowLeft", { ctrl: true }), "\x1b[1;5D");
  assert.equal(k("c", { ctrl: true }), "\x03");
  assert.equal(k("Delete"), "\x1b[3~");
  // left to the input events: letters, Backspace (the field's diff), anything with Cmd, IME keys
  assert.equal(k("a"), null);
  assert.equal(k("Backspace"), null);
  assert.equal(k("v", { meta: true }), null);
  assert.equal(k("Unidentified"), null);
  assert.equal(k("Process"), null);
});

test("sticky Ctrl and Alt apply to the next typed character only", () => {
  const b = (s: string) => new TextEncoder().encode(s);
  assert.deepEqual(applyMods(b("c"), { ctrl: true, alt: false }), b("\x03"));
  assert.deepEqual(applyMods(b("C"), { ctrl: true, alt: false }), b("\x03"));
  assert.deepEqual(applyMods(b(" "), { ctrl: true, alt: false }), new Uint8Array([0]));
  assert.deepEqual(applyMods(b("f"), { ctrl: false, alt: true }), b("\x1bf"));
  assert.deepEqual(applyMods(b("x"), { ctrl: true, alt: true }), b("\x1b\x18"));
  assert.deepEqual(applyMods(b("ab"), { ctrl: true, alt: false }), b("ab")); // not one character: as is
  assert.deepEqual(applyMods(b("\x7f"), { ctrl: true, alt: false }), b("\x7f"));
});
