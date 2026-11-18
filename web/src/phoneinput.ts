// A phone keyboard typing straight into a terminal (pure: no DOM; termfield.ts feeds it events and
// does what it answers).
//
// The hidden field never holds text the terminal already took. Committed typing is taken in
// beforeinput: cancelled, sent, the field left with its placeholder only, so a keyboard can never
// "correct" what was sent. The one exception is the word being composed (IME composition:
// Android's keyboards compose every word): it lives in the field, and a correction of it is
// Backspaces and the new text, within that word only; the composition's end empties the field and
// forgets the word. Latin words go live as composed (a shell sees each letter); other scripts go
// once, at the end. A key-bar key or a line break ends the composition first: what the keyboard
// still says about that word afterwards is ignored. A browser that does not cancel: what reached
// the field is sent once and the field emptied.
//
// Typed: one character the user typed (the key bar's sticky Ctrl/Alt apply to it); send: bytes as
// they are (a suggestion's chunk, a key, a correction); paste: text that is not typing (a line
// break in it, or long), bracketed when the program asked, never run line by line.

export const PLACEHOLDER = " "; // a no-break space: Backspace on an "empty" field still fires
const MAX_TYPED = 32; // longer than any typed chunk: a paste
const ENTER_DEDUPE_MS = 50; // keydown Enter and the keyboard's own line break: one Enter
const LIVE = /^[\x20-\x7eÀ-ɏ]*$/; // composition that goes as it is composed

export interface Act {
  cancel?: true; // preventDefault the event
  typed?: string;
  send?: string;
  paste?: string;
  reset?: true; // the field back to the placeholder alone
  endComposition?: true; // and the IME's composition dropped (the field re-focused)
}

export interface KeyMods {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
}

const LINE = /[\r\n]/;
const strip = (v: string) => v.split(PLACEHOLDER).join("");
const cps = (s: string) => Array.from(s); // code points: a pair of UTF-16 units never split

export class PhoneTyping {
  private composing = false;
  private sent: string[] = []; // the composed word as the terminal has it
  private dead = false; // a composition ended by us: ignore the keyboard's rest of it
  private lastEnter = -Infinity;

  focus(): void {
    this.clear();
  }
  blur(): void {
    this.clear();
  }

  // The key bar is about to send a key: any composition ends, the field empties.
  resetField(): Act {
    const was = this.composing;
    this.clear();
    this.dead = was;
    return was ? { reset: true, endComposition: true } : { reset: true };
  }

  compositionStart(): void {
    this.composing = true;
    this.dead = false;
    this.sent = [];
  }

  compositionEnd(value: string, _t: number): Act {
    if (this.dead || !this.composing) {
      this.clear();
      return { reset: true };
    }
    const out = this.diff(cps(strip(value)));
    this.clear();
    return out ? { send: out, reset: true } : { reset: true };
  }

  beforeInput(type: string, data: string | null, value: string, t: number): Act {
    if (type === "insertLineBreak" || type === "insertParagraph") {
      if (t - this.lastEnter < ENTER_DEDUPE_MS) return { cancel: true };
      this.lastEnter = t;
      let pre = "";
      const was = this.composing;
      if (was && !this.dead) pre = this.diff(cps(strip(value)));
      this.clear();
      this.dead = was;
      return was ? { cancel: true, send: pre + "\r", reset: true, endComposition: true } : { cancel: true, send: "\r", reset: true };
    }
    if (this.composing) return {}; // the composition's own events: input decides
    switch (type) {
      case "insertText":
      case "insertReplacementText":
      case "insertFromPaste":
      case "insertFromDrop":
      case "insertFromYank": {
        const text = data ?? "";
        if (text && (LINE.test(text) || cps(text).length > MAX_TYPED)) return { cancel: true, paste: text };
        if (text && (type === "insertFromPaste" || type === "insertFromYank")) return { cancel: true, paste: text };
        // a replacement or a drop would change what was already sent: never re-sent
        if (type !== "insertText") return { cancel: true };
        if (!text) return {};
        return cps(text).length === 1 ? { cancel: true, typed: text } : { cancel: true, send: text };
      }
      case "deleteContentBackward":
        return { cancel: true, send: "\x7f" };
      case "insertFromComposition":
      case "deleteByComposition":
      case "deleteCompositionText":
        return { cancel: true }; // a composition already handled (Safari's after its end)
    }
    return {};
  }

  // After an input event: the field's whole value.
  input(_type: string, value: string, composing: boolean, armed: boolean, t: number): Act {
    if (composing && !this.composing) {
      // composing without a compositionstart seen: a word we ended stays ended until a new one starts
      const d = this.dead;
      this.compositionStart();
      this.dead = d;
    }
    if (this.composing) {
      if (this.dead) return {};
      const now = cps(strip(value));
      if (armed) {
        // sticky Ctrl/Alt: the first character added, alone, with the modifier; the word ends
        const p = this.prefix(now);
        const added = now.slice(p);
        if (!added.length) return {};
        const dels = "\x7f".repeat(this.sent.length - p);
        this.clear();
        this.dead = true;
        return { ...(dels ? { send: dels } : {}), typed: added[0], reset: true, endComposition: true };
      }
      if (!LIVE.test(now.join(""))) return {};
      const out = this.diff(now);
      return out ? { send: out } : {};
    }
    // not composing: the field should hold the placeholder alone (beforeinput was cancelled);
    // anything else got through uncancelled: sent once, the field emptied
    const text = strip(value);
    if (!value.includes(PLACEHOLDER) && !text) return { send: "\x7f", reset: true };
    if (!text) return {};
    if (text === "\n" || text === "\r" || text === "\r\n") {
      if (t - this.lastEnter < ENTER_DEDUPE_MS) return { reset: true };
      this.lastEnter = t;
      return { send: "\r", reset: true };
    }
    if (LINE.test(text) || cps(text).length > MAX_TYPED) return { paste: text, reset: true };
    return cps(text).length === 1 ? { typed: text, reset: true } : { send: text, reset: true };
  }

  // A keydown: a key for the terminal (Enter, Tab, Esc, arrows, Ctrl-letter), or {} to leave it to
  // the input events (text, Backspace, Cmd shortcuts, IME keys).
  keydown(key: string, m: KeyMods, keyCode: number, isComposing: boolean, appCursor: boolean, t: number): Act {
    if (isComposing || this.composing || keyCode === 229) return {};
    const b = keyBytes(key, m, appCursor);
    if (b === null) return {};
    if (key === "Enter") {
      if (t - this.lastEnter < ENTER_DEDUPE_MS) return { cancel: true };
      this.lastEnter = t;
    }
    return { cancel: true, send: b, reset: true };
  }

  private clear(): void {
    this.composing = false;
    this.sent = [];
    this.dead = false;
  }

  private prefix(now: string[]): number {
    let p = 0;
    while (p < this.sent.length && p < now.length && this.sent[p] === now[p]) p++;
    return p;
  }

  // Backspaces for what of the word went, then what came; the word as sent is now `now`
  private diff(now: string[]): string {
    const p = this.prefix(now);
    const out = "\x7f".repeat(this.sent.length - p) + now.slice(p).join("");
    this.sent = now;
    return out;
  }
}

// A keydown that is a key for the terminal (a hardware keyboard, or a phone keyboard's Enter):
// its bytes, or null.
export function keyBytes(key: string, m: KeyMods, appCursor: boolean): string | null {
  if (m.meta) return null;
  const mod = 1 + (m.shift ? 1 : 0) + (m.alt ? 2 : 0) + (m.ctrl ? 4 : 0);
  const arrow: Record<string, string> = { ArrowUp: "A", ArrowDown: "B", ArrowRight: "C", ArrowLeft: "D", Home: "H", End: "F" };
  if (arrow[key]) {
    const c = arrow[key];
    if (mod > 1) return `\x1b[1;${mod}${c}`;
    return (appCursor ? "\x1bO" : "\x1b[") + c;
  }
  const tilde: Record<string, number> = { Insert: 2, Delete: 3, PageUp: 5, PageDown: 6 };
  if (tilde[key]) return mod > 1 ? `\x1b[${tilde[key]};${mod}~` : `\x1b[${tilde[key]}~`;
  switch (key) {
    case "Enter":
      return m.alt ? "\x1b\r" : "\r";
    case "Tab":
      return m.shift ? "\x1b[Z" : "\t";
    case "Escape":
      return "\x1b";
  }
  if (m.ctrl && key.length === 1) {
    const b = ctrlByte(key.charCodeAt(0));
    if (b !== null) return (m.alt ? "\x1b" : "") + String.fromCharCode(b);
  }
  return null;
}

function ctrlByte(c: number): number | null {
  if (c >= 0x61 && c <= 0x7a) return c - 0x60;
  if (c >= 0x40 && c <= 0x5f) return c - 0x40;
  if (c === 0x20) return 0;
  if (c === 0x3f) return 0x7f;
  return null;
}

// The key bar's sticky Ctrl and Alt on one typed character (one byte for Ctrl; Alt is ESC first).
export function applyMods(b: Uint8Array, m: { ctrl: boolean; alt: boolean }): Uint8Array {
  if (!m.ctrl && !m.alt) return b;
  let out = b;
  if (m.ctrl && b.length === 1) {
    const c = ctrlByte(b[0]);
    if (c !== null) out = new Uint8Array([c]);
  }
  if (m.alt) {
    const x = new Uint8Array(out.length + 1);
    x[0] = 0x1b;
    x.set(out, 1);
    out = x;
  }
  return out;
}
