// A phone's typing straight into its terminal: the hidden text field the terminal owns (the rules
// are phoneinput.ts). xterm.js's own textarea reads keydown, which phone keyboards hardly send
// (Android: 229 "Unidentified"; autocorrect, suggestions and dictation work on words), so on a
// touch device this field takes the keyboard instead: kept at the terminal's cursor (the
// keyboard's suggestions and the browser's scrolling follow it), 16 px text (iOS does not zoom),
// invisible, never display:none. It holds the placeholder and, at most, the word being composed.
//
// Out: `typed` (one character: the key bar's sticky Ctrl/Alt apply), `send` (bytes as they are),
// `paste` (bracketed when the program asked), through the same path as the desktop's typing. It
// only types while it has the focus: the pane blurs it when the tab changes, a sheet opens, or the
// keyboard is handed back (setKeyboard(false)).

import { PhoneTyping, PLACEHOLDER, type Act } from "./phoneinput.ts";

export interface FieldOps {
  typed(ch: string): void;
  send(text: string): void;
  paste(text: string): void;
  armed(): boolean; // the key bar's Ctrl or Alt is down for the next character
  appCursor(): boolean;
  // where the cursor is in the host (px), null: not on screen
  cursorAt(): { left: number; top: number; height: number } | null;
}

export interface TermField {
  el: HTMLTextAreaElement;
  focus(): void;
  blur(): void;
  focused(): boolean;
  // the key bar is about to send a key: any composition ends, the field empties
  resetField(): void;
  place(): void;
  dispose(): void;
}

export function createTermField(host: HTMLElement, ops: FieldOps): TermField {
  const el = document.createElement("textarea");
  el.className = "term-field";
  el.setAttribute("autocapitalize", "off");
  el.setAttribute("autocorrect", "off");
  el.setAttribute("autocomplete", "off");
  el.setAttribute("spellcheck", "false");
  el.setAttribute("inputmode", "text");
  el.setAttribute("enterkeyhint", "enter");
  el.setAttribute("aria-label", "Type into the terminal");
  el.rows = 1;
  host.appendChild(el);

  const model = new PhoneTyping();
  let refocusing = false; // our own blur and focus to drop a composition: the model keeps its state
  const empty = () => {
    el.value = PLACEHOLDER;
    el.setSelectionRange(el.value.length, el.value.length);
  };
  empty();

  const apply = (a: Act, e?: Event) => {
    if (a.cancel) e?.preventDefault();
    if (a.send) ops.send(a.send);
    if (a.typed) ops.typed(a.typed);
    if (a.paste) ops.paste(a.paste);
    if (a.endComposition) {
      empty();
      if (document.activeElement === el) {
        // the IME lets go of its word only when the field does
        refocusing = true;
        el.blur();
        el.focus({ preventScroll: true });
        refocusing = false;
      }
      empty();
    } else if (a.reset) empty();
  };

  const keydown = (e: KeyboardEvent) =>
    apply(model.keydown(e.key, { ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey }, e.keyCode, e.isComposing, ops.appCursor(), performance.now()), e);
  const beforeinput = (e: InputEvent) => {
    // a browser that will not cancel this one: the input event after it sends what got in
    if (!e.cancelable) return;
    apply(model.beforeInput(e.inputType, e.data, el.value, performance.now()), e);
  };
  const input = (e: Event) => {
    const ie = e as InputEvent;
    apply(model.input(ie.inputType ?? "", el.value, !!ie.isComposing, ops.armed(), performance.now()));
  };
  const compStart = () => model.compositionStart();
  const compEnd = () => apply(model.compositionEnd(el.value, performance.now()));
  const paste = (e: ClipboardEvent) => {
    const text = e.clipboardData?.getData("text/plain") ?? "";
    e.preventDefault();
    if (text) ops.paste(text);
    empty();
  };
  const focus = () => {
    if (refocusing) return;
    model.focus(); // a stale composition never outlives the focus
    empty();
    place();
  };
  const blur = () => {
    if (refocusing) return;
    model.blur();
    empty();
  };

  const place = () => {
    const at = ops.cursorAt();
    if (!at) return;
    el.style.left = `${Math.max(0, at.left)}px`;
    el.style.top = `${Math.max(0, at.top)}px`;
    el.style.height = `${Math.max(at.height, 18)}px`;
  };

  el.addEventListener("keydown", keydown);
  el.addEventListener("beforeinput", beforeinput as EventListener);
  el.addEventListener("input", input);
  el.addEventListener("compositionstart", compStart);
  el.addEventListener("compositionend", compEnd);
  el.addEventListener("paste", paste);
  el.addEventListener("focus", focus);
  el.addEventListener("blur", blur);

  return {
    el,
    focus() {
      if (document.activeElement !== el) el.focus({ preventScroll: true });
    },
    blur() {
      if (document.activeElement === el) el.blur();
      model.blur();
      empty();
    },
    focused: () => document.activeElement === el,
    resetField() {
      apply(model.resetField());
    },
    place,
    dispose() {
      el.removeEventListener("keydown", keydown);
      el.removeEventListener("beforeinput", beforeinput as EventListener);
      el.removeEventListener("input", input);
      el.removeEventListener("compositionstart", compStart);
      el.removeEventListener("compositionend", compEnd);
      el.removeEventListener("paste", paste);
      el.removeEventListener("focus", focus);
      el.removeEventListener("blur", blur);
      el.remove();
    },
  };
}
