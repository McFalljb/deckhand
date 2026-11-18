// A phone keyboard typing straight into a terminal (pure: no DOM; termfield.ts feeds it).
//
// The terminal owns a hidden text field. Phone keyboards report typing as input events on it, not
// keys (Android: keydown 229 "Unidentified"; autocorrect, suggestions and dictation replace whole
// words), so the field's text is the truth: after each input event the field is compared with what
// the terminal was sent since the field was last emptied (its mirror), and the difference goes as
// DELs (0x7f) for the characters gone and then the new text, so a replaced word is erased and typed
// again, never doubled. A sentinel character stays in front of the text so that Backspace with
// nothing typed still has something to delete (and fires); deleting it is one more DEL. The field
// is emptied (only between compositions) when the sentinel goes, when it gets long, and after a key
// that moves the terminal's cursor (Enter, arrows, Tab...): a correction never reaches past that.
//
// IME composition: text in the Latin range (Android's keyboards compose every word) goes live as
// it is composed, so a shell sees each letter; any other script (Japanese, Chinese...) waits for
// the composition to end and goes once, committed.

export const SENTINEL = " "; // a no-break space: not a word character, nothing to correct
const MAX_MIRROR = 32;
const LIVE = /^[\x20-\x7e\n]*$/;

export class FieldModel {
  private mirror = ""; // what the terminal was sent since the field was emptied

  // The field's whole value after an input event: the bytes for the terminal ("" for none).
  input(value: string, composing: boolean): string {
    let now: string;
    let gone = 0;
    if (value.startsWith(SENTINEL)) now = value.slice(SENTINEL.length);
    else {
      // the sentinel was deleted: one Backspace past what the field holds
      now = value;
      gone = 1;
    }
    if (composing && !LIVE.test(now)) return ""; // sent at the composition's end
    return this.send(now, gone);
  }

  // After an input event outside a composition: empty the field now (call reset, set its value)?
  needsReset(value: string): boolean {
    return !value.startsWith(SENTINEL) || this.mirror.length > MAX_MIRROR;
  }

  reset(): void {
    this.mirror = "";
  }

  // the difference from the mirror: DELs for what went, then what came (a line break is Enter)
  private send(now: string, extra: number): string {
    let p = 0;
    const old = this.mirror;
    while (p < old.length && p < now.length && old[p] === now[p]) p++;
    const dels = [...old.slice(p)].length + extra;
    this.mirror = now;
    return "\x7f".repeat(dels) + now.slice(p).replace(/\r?\n/g, "\r");
  }
}

export interface KeyMods {
  ctrl: boolean;
  alt: boolean;
  shift: boolean;
  meta: boolean;
}

// A keydown that is a key for the terminal (a hardware keyboard, or a phone keyboard's Enter):
// its bytes, or null to leave it to the field's input events (text, Backspace, Cmd shortcuts,
// IME keys). The caller empties the field after one (the terminal's cursor moved).
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

// The key bar's sticky Ctrl and Alt on the next typed character (one byte for Ctrl; Alt is ESC first).
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
