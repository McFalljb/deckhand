// A phone keyboard typing straight into a terminal (src/phoneinput.ts). The hidden field never
// holds text the terminal already took: committed typing is taken in beforeinput (cancelled, sent,
// the field stays empty); only the word being composed lives in the field, and only it can be
// corrected. Keys come from keydown, the key bar ends a composition, sticky Ctrl/Alt go to one
// typed character, Enter is one CR, and text that is not typing goes as a paste.

import { test } from "node:test";
import assert from "node:assert/strict";
import { applyMods, keyBytes, PhoneTyping, PLACEHOLDER } from "../src/phoneinput.ts";

const P = PLACEHOLDER;
const noMods = { ctrl: false, alt: false, shift: false, meta: false };

test("a typed character is taken in beforeinput: cancelled, sent as typed (sticky mods apply), field stays empty", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.beforeInput("insertText", "l", P, 0), { cancel: true, typed: "l" });
  assert.deepEqual(m.beforeInput("insertText", "é", P, 1), { cancel: true, typed: "é" });
  assert.deepEqual(m.beforeInput("insertText", "😀", P, 2), { cancel: true, typed: "😀" });
});

test("a short chunk (a suggestion) goes as it is, not as one typed character (mods stay armed)", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.beforeInput("insertText", "hello ", P, 0), { cancel: true, send: "hello " });
});

test("text that is not typing (a line break in it, or long) goes as a paste, never run line by line", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.beforeInput("insertText", "ls\nrm -rf x", P, 0), { cancel: true, paste: "ls\nrm -rf x" });
  assert.deepEqual(m.beforeInput("insertText", "a\r", P, 0), { cancel: true, paste: "a\r" });
  const long = "x".repeat(33);
  assert.deepEqual(m.beforeInput("insertText", long, P, 0), { cancel: true, paste: long });
  for (const t of ["insertReplacementText", "insertFromPaste", "insertFromDrop", "insertFromYank"]) {
    assert.deepEqual(m.beforeInput(t, "a\nb", P, 0), { cancel: true, paste: "a\nb" }, t);
  }
});

test("a replacement outside a composition never re-sends: what it would correct is already sent", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.beforeInput("insertReplacementText", "the", P, 0), { cancel: true });
  assert.deepEqual(m.beforeInput("insertFromDrop", null, P, 0), { cancel: true });
  assert.deepEqual(m.beforeInput("insertFromDrop", "x", P, 0), { cancel: true });
  // a short paste from the keyboard's clipboard: still a paste
  assert.deepEqual(m.beforeInput("insertFromPaste", "ls", P, 0), { cancel: true, paste: "ls" });
});

test("Backspace with an empty field is DEL", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.beforeInput("deleteContentBackward", null, P, 0), { cancel: true, send: "\x7f" });
  assert.deepEqual(m.beforeInput("deleteContentBackward", null, P, 5), { cancel: true, send: "\x7f" });
});

test("Enter is one CR whether keydown, insertLineBreak, a bare newline input, or several of them", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.keydown("Enter", noMods, 13, false, false, 100), { cancel: true, send: "\r", reset: true });
  assert.deepEqual(m.beforeInput("insertLineBreak", null, P, 103), { cancel: true });
  assert.deepEqual(m.input("insertText", P + "\n", false, false, 104), { reset: true });
  assert.deepEqual(m.beforeInput("insertParagraph", null, P, 500), { cancel: true, send: "\r", reset: true });
  assert.deepEqual(m.input("insertLineBreak", P + "\n", false, false, 1000), { send: "\r", reset: true });
});

test("a browser that does not cancel: what reached the field is sent once, and the field emptied", () => {
  const m = new PhoneTyping();
  assert.deepEqual(m.input("insertText", P + "ab", false, false, 0), { send: "ab", reset: true });
  assert.deepEqual(m.input("insertText", "a" + P + "b", false, false, 0), { send: "ab", reset: true }); // the placeholder anywhere
  assert.deepEqual(m.input("insertText", P + "a\nb", false, false, 0), { paste: "a\nb", reset: true });
  assert.deepEqual(m.input("deleteContentBackward", "", false, false, 0), { send: "\x7f", reset: true });
  assert.deepEqual(m.input("insertText", P, false, false, 0), {});
});

test("composition (Latin): live inside its own word only; the end empties the field; nothing re-sent", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  assert.deepEqual(m.input("insertCompositionText", P + "g", true, false, 0), { send: "g" });
  assert.deepEqual(m.input("insertCompositionText", P + "gt", true, false, 1), { send: "t" });
  assert.deepEqual(m.input("insertCompositionText", P + "gti", true, false, 2), { send: "i" });
  // the keyboard corrects its own word
  assert.deepEqual(m.compositionEnd(P + "git", 3), { send: "\x7f\x7fit", reset: true });
  // a later input or a Safari insertFromComposition of the same word: nothing
  assert.deepEqual(m.input("insertCompositionText", P, false, false, 4), {});
  assert.deepEqual(m.beforeInput("insertFromComposition", "git", P, 5), { cancel: true });
  assert.deepEqual(m.beforeInput("insertText", " ", P, 6), { cancel: true, typed: " " });
});

test("a cancelled composition nets to nothing", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  m.input("insertCompositionText", P + "ab", true, false, 0);
  assert.deepEqual(m.compositionEnd(P, 1), { send: "\x7f\x7f", reset: true });
});

test("composition in another script waits for its end and goes once", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  assert.deepEqual(m.input("insertCompositionText", P + "に", true, false, 0), {});
  assert.deepEqual(m.input("insertCompositionText", P + "にほ", true, false, 1), {});
  assert.deepEqual(m.compositionEnd(P + "日本", 2), { send: "日本", reset: true });
});

test("a key-bar key mid-composition: the composition ends, nothing of it is sent again (gti, Enter, space)", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  m.input("insertCompositionText", P + "g", true, false, 0);
  m.input("insertCompositionText", P + "gt", true, false, 1);
  m.input("insertCompositionText", P + "gti", true, false, 2);
  assert.deepEqual(m.resetField(), { reset: true, endComposition: true }); // then the key bar sends its Enter
  // the keyboard still finishing the word it thinks it has
  assert.deepEqual(m.input("insertCompositionText", P + "gti", true, false, 3), {});
  assert.deepEqual(m.compositionEnd(P + "gti", 4), { reset: true });
  assert.deepEqual(m.beforeInput("insertText", " ", P, 5), { cancel: true, typed: " " });
  // a new word composes normally again
  m.compositionStart();
  assert.deepEqual(m.input("insertCompositionText", P + "l", true, false, 6), { send: "l" });
});

test("a line break mid-composition: the word as it stands, then one CR", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  m.input("insertCompositionText", P + "ls", true, false, 0);
  assert.deepEqual(m.beforeInput("insertLineBreak", null, P + "ls", 1), { cancel: true, send: "\r", reset: true, endComposition: true });
  assert.deepEqual(m.compositionEnd(P + "ls", 2), { reset: true });
});

test("sticky Ctrl then a composing letter: that letter alone, with the modifier; the composition ends", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  assert.deepEqual(m.input("insertCompositionText", P + "c", true, true, 0), { typed: "c", reset: true, endComposition: true });
  assert.deepEqual(m.compositionEnd(P + "c", 1), { reset: true });
});

test("a pair of UTF-16 units is never split by a correction", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  m.input("insertCompositionText", P + "a😀", true, false, 0); // ASCII + emoji: not live
  const r = m.compositionEnd(P + "a😁", 1);
  assert.deepEqual(r, { send: "a😁", reset: true });
  const n = new PhoneTyping();
  n.compositionStart();
  n.input("insertCompositionText", P + "ab", true, false, 0);
  assert.deepEqual(n.compositionEnd(P + "a😁", 1), { send: "\x7f😁", reset: true });
});

test("focus and blur clear a stale composition", () => {
  const m = new PhoneTyping();
  m.compositionStart();
  m.input("insertCompositionText", P + "ab", true, false, 0);
  m.focus();
  assert.deepEqual(m.beforeInput("insertText", "x", P, 1), { cancel: true, typed: "x" });
  m.compositionStart();
  m.blur();
  assert.deepEqual(m.beforeInput("insertText", "y", P, 2), { cancel: true, typed: "y" });
});

test("keys that are keys: Enter, Tab, Esc, arrows (application cursor mode too), Ctrl-letter", () => {
  const k = (key: string, mods: Partial<typeof noMods> = {}, app = false) => keyBytes(key, { ...noMods, ...mods }, app);
  assert.equal(k("Enter"), "\r");
  assert.equal(k("Tab"), "\t");
  assert.equal(k("Tab", { shift: true }), "\x1b[Z");
  assert.equal(k("Escape"), "\x1b");
  assert.equal(k("ArrowUp"), "\x1b[A");
  assert.equal(k("ArrowUp", {}, true), "\x1bOA");
  assert.equal(k("ArrowLeft", { ctrl: true }), "\x1b[1;5D");
  assert.equal(k("c", { ctrl: true }), "\x03");
  assert.equal(k("Delete"), "\x1b[3~");
  assert.equal(k("a"), null);
  assert.equal(k("Backspace"), null);
  assert.equal(k("v", { meta: true }), null);
  assert.equal(k("Unidentified"), null);
  // keydown of a key: one send; a 229 or composing keydown: nothing (the input events tell)
  const m = new PhoneTyping();
  assert.deepEqual(m.keydown("ArrowUp", noMods, 38, false, false, 0), { cancel: true, send: "\x1b[A", reset: true });
  assert.deepEqual(m.keydown("Enter", noMods, 229, false, false, 0), {});
  assert.deepEqual(m.keydown("Enter", noMods, 13, true, false, 0), {});
  assert.deepEqual(m.keydown("a", noMods, 65, false, false, 0), {});
});

test("sticky Ctrl and Alt apply to one character only", () => {
  const b = (s: string) => new TextEncoder().encode(s);
  assert.deepEqual(applyMods(b("c"), { ctrl: true, alt: false }), b("\x03"));
  assert.deepEqual(applyMods(b("C"), { ctrl: true, alt: false }), b("\x03"));
  assert.deepEqual(applyMods(b(" "), { ctrl: true, alt: false }), new Uint8Array([0]));
  assert.deepEqual(applyMods(b("f"), { ctrl: false, alt: true }), b("\x1bf"));
  assert.deepEqual(applyMods(b("x"), { ctrl: true, alt: true }), b("\x1b\x18"));
  assert.deepEqual(applyMods(b("\x7f"), { ctrl: true, alt: false }), b("\x7f"));
});
