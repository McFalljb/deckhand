// A phone's typing straight into its terminal: the hidden text field the terminal owns (the model
// is phoneinput.ts). xterm.js's own textarea reads keydown, which phone keyboards hardly send
// (Android: 229 "Unidentified"; autocorrect and dictation replace words), so on a phone this field
// takes the keyboard instead: kept at the terminal's cursor (the keyboard's suggestions and the
// browser's scrolling follow it), 16 px text (iOS does not zoom), invisible, never display:none.
//
// What it types goes out through `send` (the pane's input: its sticky Ctrl/Alt), a paste through
// `paste` (bracketed when the program asked), exactly as the desktop's typing and paste do. It
// only types while it has the focus: the pane blurs it when the tab changes, a sheet opens, or
// the keyboard is handed back (setKeyboard(false)).

import { FieldModel, keyBytes, SENTINEL } from "./phoneinput.ts";

export interface FieldOps {
  send(text: string): void;
  paste(text: string): void;
  appCursor(): boolean;
  // where the cursor is in the host (px), null: not on screen
  cursorAt(): { left: number; top: number; height: number } | null;
}

export interface TermField {
  el: HTMLTextAreaElement;
  focus(): void;
  blur(): void;
  focused(): boolean;
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

  const model = new FieldModel();
  let composing = false;
  const reset = () => {
    model.reset();
    el.value = SENTINEL;
    el.setSelectionRange(el.value.length, el.value.length);
  };
  reset();

  const took = (composingNow: boolean) => {
    const out = model.input(el.value, composingNow);
    if (out) ops.send(out);
    if (!composingNow && model.needsReset(el.value)) reset();
  };

  const keydown = (e: KeyboardEvent) => {
    if (e.isComposing || composing || e.keyCode === 229) return; // the input events tell
    const b = keyBytes(e.key, { ctrl: e.ctrlKey, alt: e.altKey, shift: e.shiftKey, meta: e.metaKey }, ops.appCursor());
    if (b === null) return;
    e.preventDefault();
    took(false); // anything the field still holds goes first
    ops.send(b);
    reset(); // the terminal's cursor moved: no correction reaches back past it
  };
  const beforeinput = (e: InputEvent) => {
    switch (e.inputType) {
      case "insertLineBreak":
      case "insertParagraph":
        // a phone keyboard's Return (no keydown for it on some): Enter
        e.preventDefault();
        took(false);
        ops.send("\r");
        reset();
        return;
      case "insertFromDrop":
        e.preventDefault(); // a drop is not typing
        return;
      // insertFromPaste: the paste event below takes it first
    }
  };
  const input = (e: Event) => took((e as InputEvent).isComposing || composing);
  const compStart = () => {
    composing = true;
  };
  const compEnd = () => {
    composing = false;
    took(false); // the committed text, once (a later input event finds nothing new)
  };
  const paste = (e: ClipboardEvent) => {
    const text = e.clipboardData?.getData("text/plain") ?? "";
    e.preventDefault();
    took(false);
    if (text) ops.paste(text);
    reset();
  };
  // the caret stays at the end (a correction is always of what was typed last)
  const focus = () => {
    reset();
    place();
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

  return {
    el,
    focus() {
      if (document.activeElement !== el) el.focus({ preventScroll: true });
    },
    blur() {
      composing = false;
      if (document.activeElement === el) el.blur();
      reset();
    },
    focused: () => document.activeElement === el,
    place,
    dispose() {
      el.removeEventListener("keydown", keydown);
      el.removeEventListener("beforeinput", beforeinput as EventListener);
      el.removeEventListener("input", input);
      el.removeEventListener("compositionstart", compStart);
      el.removeEventListener("compositionend", compEnd);
      el.removeEventListener("paste", paste);
      el.removeEventListener("focus", focus);
      el.remove();
    },
  };
}
