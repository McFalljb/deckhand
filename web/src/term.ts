// The terminal emulator behind a small interface, so xterm.js (or its key encoder) can be swapped
// later (the plan's escape hatch: libghostty-vt's WASM key encoder, then its parser).
//
// The copy here only draws: it never answers a program's queries (the core does, from its own
// terminal: docs/PROTOCOL.md §5a "Terminal streams") and never sizes itself (the core sends
// RESIZE). Input leaves through onInput as bytes for the terminal's channel.

import { Terminal, type IDisposable, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { TERM_LOOKS, type TermColors } from "./theme.gen.ts";
import { installTouchScroll, type TouchScrolling } from "./termtouch.ts";
import { routeCoasts, touchRoute, WheelWindow } from "./touchroute.ts";
import { createTermField, type TermField } from "./termfield.ts";

// The terminal colours of the page's look (data-look on <html>, set from the user's setting).
function colors(light: boolean): TermColors {
  const look = TERM_LOOKS[document.documentElement.dataset.look ?? ""] ?? TERM_LOOKS.graphite;
  return light ? look.light : look.dark;
}

export interface Fit {
  cols: number;
  rows: number;
  cellW: number;
  cellH: number;
}

export interface TermView {
  mount(el: HTMLElement): void;
  reset(): void;
  resize(cols: number, rows: number): void;
  write(data: Uint8Array, done?: () => void): void;
  // the grid the element fits now (the core is asked for it; the copy does not change)
  fit(): Fit | null;
  scrollToBottom(): void;
  focus(): void;
  blur(): void;
  // raw keys: the terminal takes the keyboard itself (else the text field under it does); field: a
  // phone's keyboard, through the terminal's own hidden field (termfield.ts), not xterm.js's
  setKeyboard(on: boolean, field?: boolean): void;
  // a touch scroll may send what the wheel would (mouse reports, arrows): this pane is the one typed into
  setScrollReports(on: boolean): void;
  // a touch scroll's coast ends now
  stopScroll(): void;
  // the rows on screen as text (Copy, where selecting is awkward)
  screenText(): string;
  // pasted text, bracketed when the program asked for it, out through onInput
  paste(text: string): void;
  appCursor(): boolean;
  setLight(light: boolean): void;
  setFontSize(px: number): void;
  onInput(fn: (bytes: Uint8Array) => void): void;
  // a touch scroll's wheel reports (not typing: no sticky modifiers)
  onScrollInput(fn: (bytes: Uint8Array) => void): void;
  // a phone field's bytes that are not one typed character (keys, a word's correction, a paste):
  // no sticky modifiers
  onPlainInput(fn: (bytes: Uint8Array) => void): void;
  // the key bar's Ctrl or Alt is down for the next typed character
  onArmed(fn: () => boolean): void;
  // the key bar is about to send a key: the phone field's composition ends, the field empties
  resetField(): void;
  onLink(fn: (url: string) => void): void;
  dispose(): void;
}

const enc = new TextEncoder();

function xtermTheme(c: TermColors): ITheme {
  const names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"] as const;
  const t: ITheme = { foreground: c.fg, background: c.bg, cursor: c.cursor, cursorAccent: c.bg, selectionBackground: c.selection };
  names.forEach((n, i) => {
    (t as any)[n] = c.ansi[i];
    (t as any)["bright" + n[0].toUpperCase() + n.slice(1)] = c.ansi[i + 8];
  });
  return t;
}

// The OSCs whose payload may be a colour query ("?"): 4 (palette), 10-19 (dynamic colours).
const COLOUR_OSCS = [4, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19];

export function createTerm(opts: { light: boolean; fontSize: number }): TermView {
  installCspStyleShim();
  const term = new Terminal({
    allowProposedApi: true,
    convertEol: false,
    cursorBlink: false,
    disableStdin: true,
    fontFamily: 'Menlo, "SF Mono", ui-monospace, "JetBrains Mono", Consolas, monospace',
    fontSize: opts.fontSize,
    scrollback: 5000,
    theme: xtermTheme(colors(opts.light)),
    windowOptions: {},
    linkHandler: {
      activate: (_e, uri) => linkFn?.(uri),
      allowNonHttpProtocols: false,
    },
  });
  const fit = new FitAddon();
  term.loadAddon(fit);

  let inputFn: ((b: Uint8Array) => void) | null = null;
  let scrollFn: ((b: Uint8Array) => void) | null = null;
  let plainFn: ((b: Uint8Array) => void) | null = null;
  let armedFn: () => boolean = () => false;
  let plainOut = false; // a phone field's paste is being written (its output: plainFn)
  let scrollReports = false;
  const touchWheel = new WheelWindow(); // a touch scroll's wheel events being handled: output to scrollFn
  let touch: TouchScrolling | null = null;
  let linkFn: ((url: string) => void) | null = null;
  const subs: IDisposable[] = [];

  // ---- never answer: the core does ----
  const swallow = () => true;
  const P = term.parser;
  subs.push(
    P.registerCsiHandler({ final: "c" }, swallow), // DA1
    P.registerCsiHandler({ prefix: ">", final: "c" }, swallow), // DA2
    P.registerCsiHandler({ prefix: "=", final: "c" }, swallow), // DA3
    P.registerCsiHandler({ final: "n" }, swallow), // DSR: status, cursor position
    P.registerCsiHandler({ prefix: "?", final: "n" }, swallow), // DEC DSR, colour scheme (996)
    P.registerCsiHandler({ intermediates: "$", final: "p" }, swallow), // DECRQM
    P.registerCsiHandler({ prefix: "?", intermediates: "$", final: "p" }, swallow),
    P.registerCsiHandler({ final: "t" }, swallow), // window reports (and title stack)
    P.registerCsiHandler({ prefix: ">", final: "q" }, swallow), // XTVERSION
    P.registerCsiHandler({ prefix: "?", final: "u" }, swallow), // kitty keyboard flags query
    P.registerCsiHandler({ final: "x" }, swallow), // DECREQTPARM
    P.registerDcsHandler({ intermediates: "$", final: "q" }, swallow), // DECRQSS
    P.registerDcsHandler({ intermediates: "+", final: "q" }, swallow), // XTGETTCAP
    P.registerEscHandler({ final: "Z" }, swallow), // DECID
    P.registerOscHandler(52, swallow), // clipboard: never from a program
  );
  for (const n of COLOUR_OSCS) subs.push(P.registerOscHandler(n, (data) => data.includes("?")));

  subs.push(
    term.onData((d) => {
      // focus reports go as FOCUS frames (the core reports them if the program asked)
      if (d === "\x1b[I" || d === "\x1b[O") return;
      (touchWheel.active ? scrollFn : plainOut ? plainFn : inputFn)?.(enc.encode(d));
    }),
    term.onBinary((d) => {
      const b = new Uint8Array(d.length);
      for (let i = 0; i < d.length; i++) b[i] = d.charCodeAt(i) & 0xff;
      (touchWheel.active ? scrollFn : plainOut ? plainFn : inputFn)?.(b);
    }),
  );

  // plain URLs in the output: a tap shows the address first (no web-links addon)
  subs.push(
    term.registerLinkProvider({
      provideLinks(y, cb) {
        const line = term.buffer.active.getLine(y - 1)?.translateToString(true) ?? "";
        const out: any[] = [];
        const re = /https?:\/\/[^\s"'<>`\u0000-\u001f]+/g;
        for (let m = re.exec(line); m; m = re.exec(line)) {
          const url = m[0].replace(/[.,;:!?)\]]+$/, "");
          out.push({
            range: { start: { x: m.index + 1, y }, end: { x: m.index + url.length, y } },
            text: url,
            activate: () => linkFn?.(url),
          });
        }
        cb(out.length ? out : undefined);
      },
    }),
  );

  const cellH = () => {
    const h = (term as any)._core?._renderService?.dimensions?.css?.cell?.height;
    return h || (term.element ? term.element.clientHeight / term.rows : 0);
  };
  // A touch scroll's lines, as the wheel does them here (touchroute.ts): the scrollback, or
  // xterm.js's own wheel handling (a mouse report at the cell under the finger, or arrow keys on the
  // alternate screen), one line-wheel event a line, sent only from the pane typed into (the wheel's
  // own rule: xterm.js drops them without stdin). False: nothing moved or was sent.
  const route = () => touchRoute(term.modes.mouseTrackingMode, term.buffer.active.type, scrollReports);
  const touchLines = (lines: number, x: number, y: number): boolean => {
    const r0 = route();
    if (r0 === "scrollback") {
      const before = term.buffer.active.viewportY;
      term.scrollLines(lines);
      return term.buffer.active.viewportY !== before;
    }
    const el = term.element;
    const screen = el?.querySelector(".xterm-screen");
    if (r0 === "none" || !el || !screen) return false;
    const r = screen.getBoundingClientRect();
    const cx = Math.min(Math.max(x, r.left + 1), r.right - 1);
    const cy = Math.min(Math.max(y, r.top + 1), r.bottom - 1);
    const stdin = { disabled: () => !!term.options.disableStdin, setDisabled: (v: boolean) => void (term.options.disableStdin = v) };
    touchWheel.run(stdin, () => {
      const n = Math.min(Math.abs(lines), term.rows);
      for (let i = 0; i < n; i++) {
        el.dispatchEvent(new WheelEvent("wheel", { deltaY: Math.sign(lines), deltaMode: WheelEvent.DOM_DELTA_LINE, clientX: cx, clientY: cy, cancelable: true }));
      }
    });
    return true;
  };

  // ---- a phone's typing: the hidden field (termfield.ts), at the cursor in the mount element ----
  let host: HTMLElement | null = null;
  let field: TermField | null = null;
  let fieldOn = false; // the field has the keyboard (else nothing types through it)
  const cursorAt = () => {
    const screen = term.element?.querySelector(".xterm-screen");
    if (!host || !screen) return null;
    const b = term.buffer.active;
    const row = b.baseY + b.cursorY - b.viewportY;
    if (row < 0 || row >= term.rows) return null;
    const hr = host.getBoundingClientRect();
    const sr = screen.getBoundingClientRect();
    const h = cellH();
    const w = sr.width / term.cols;
    return { left: sr.left - hr.left + b.cursorX * w, top: sr.top - hr.top + row * h, height: h };
  };
  // the keyboard opened or closed (the visible height changed by a keyboard's worth, not a pinch
  // or a scroll): the cursor's line back in view
  let vvH = window.visualViewport?.height ?? 0;
  const keepInView = (e?: Event) => {
    const h = window.visualViewport?.height ?? 0;
    const opened = e?.type === "focus";
    if (!opened && Math.abs(h - vvH) < 120) return;
    vvH = h;
    if (!field?.focused()) return;
    term.scrollToBottom();
    field.place();
  };
  const pastePlain = (text: string) => {
    const was = term.options.disableStdin;
    term.options.disableStdin = false;
    plainOut = true;
    try {
      term.paste(text); // bracketed when the program asked
    } finally {
      plainOut = false;
      term.options.disableStdin = was;
    }
  };
  const ensureField = (): TermField | null => {
    if (field || !host) return field;
    field = createTermField(host, {
      typed: (ch) => fieldOn && inputFn?.(enc.encode(ch)),
      send: (text) => fieldOn && plainFn?.(enc.encode(text)),
      paste: (text) => fieldOn && pastePlain(text),
      armed: () => armedFn(),
      appCursor: () => term.modes.applicationCursorKeysMode,
      cursorAt,
    });
    field.el.addEventListener("focus", keepInView);
    // a tap on the terminal: xterm.js focuses its own textarea on mousedown; the field takes it
    // back at once (still the tap's own handler: a phone brings its keyboard up)
    host.addEventListener("focusin", redirect, true);
    host.addEventListener("click", tapped);
    window.visualViewport?.addEventListener("resize", keepInView);
    subs.push(term.onRender(() => field?.focused() && field.place()));
    return field;
  };
  const redirect = (e: FocusEvent) => {
    if (fieldOn && field && e.target === term.textarea) field.focus();
  };
  const tapped = () => {
    if (fieldOn && field && !field.focused()) field.focus();
  };

  const view: TermView = {
    mount(el) {
      host = el;
      term.open(el);
      if (term.textarea && term.options.disableStdin) term.textarea.inputMode = "none";
      if (term.element && !touch) touch = installTouchScroll(term.element, { cellH, scroll: touchLines, coasts: () => routeCoasts(route()) });
    },
    reset() {
      term.reset();
    },
    resize(cols, rows) {
      if (cols >= 2 && rows >= 2 && (cols !== term.cols || rows !== term.rows)) term.resize(cols, rows);
    },
    write(data, done) {
      term.write(data, done);
    },
    fit() {
      const d = fit.proposeDimensions();
      if (!d || !isFinite(d.cols) || !isFinite(d.rows) || d.cols < 2 || d.rows < 2) return null;
      const el = term.element;
      const dims = (term as any)._core?._renderService?.dimensions?.css?.cell;
      const cellW = dims?.width || (el ? el.clientWidth / d.cols : 8);
      const cellH = dims?.height || (el ? el.clientHeight / d.rows : 16);
      return { cols: Math.min(d.cols, 500), rows: Math.min(d.rows, 500), cellW, cellH };
    },
    scrollToBottom() {
      term.scrollToBottom();
    },
    focus() {
      term.focus();
    },
    blur() {
      term.blur();
    },
    setKeyboard(on, viaField) {
      touch?.stop();
      if (viaField) {
        // the field types; xterm.js's textarea takes nothing and never brings a keyboard up
        term.options.disableStdin = true;
        if (term.textarea) term.textarea.inputMode = "none";
        // never focused from here: only a tap on this terminal does (redirect), so a tab shown, a
        // sheet closed or a mode switched types nowhere until the user taps where they type
        fieldOn = on;
        const f = ensureField();
        if (!on) {
          f?.blur();
          term.blur();
        }
        return;
      }
      fieldOn = false;
      field?.blur();
      term.options.disableStdin = !on;
      // off: a tap on the terminal must not bring up a phone's keyboard for input it drops
      if (term.textarea) term.textarea.inputMode = on ? "text" : "none";
      if (on) term.focus();
      else term.blur();
    },
    stopScroll() {
      touch?.stop();
    },
    setScrollReports(on) {
      if (!on) touch?.stop();
      scrollReports = on;
    },
    screenText() {
      const b = term.buffer.active;
      const lines: string[] = [];
      for (let y = b.viewportY; y < b.viewportY + term.rows; y++) lines.push(b.getLine(y)?.translateToString(true) ?? "");
      return lines.join("\n").replace(/\s+$/, "");
    },
    paste(text) {
      // xterm wraps it in ESC[200~ … ESC[201~ when the program turned bracketed paste on
      const was = term.options.disableStdin;
      term.options.disableStdin = false;
      term.paste(text);
      term.options.disableStdin = was;
    },
    appCursor() {
      return term.modes.applicationCursorKeysMode;
    },
    setLight(light) {
      term.options.theme = xtermTheme(colors(light));
    },
    setFontSize(px) {
      term.options.fontSize = px;
    },
    onInput(fn) {
      inputFn = fn;
    },
    onScrollInput(fn) {
      scrollFn = fn;
    },
    onPlainInput(fn) {
      plainFn = fn;
    },
    onArmed(fn) {
      armedFn = fn;
    },
    resetField() {
      field?.resetField();
    },
    onLink(fn) {
      linkFn = fn;
    },
    dispose() {
      touch?.dispose();
      fieldOn = false;
      host?.removeEventListener("focusin", redirect, true);
      host?.removeEventListener("click", tapped);
      window.visualViewport?.removeEventListener("resize", keepInView);
      field?.dispose();
      for (const s of subs) s.dispose();
      term.dispose();
    },
  };
  return view;
}

// ---- CSP ----
// The page's CSP has no 'unsafe-inline' for styles. xterm.js's DOM renderer writes its theme and
// cell sizes into <style> elements and true colours into style attributes; the browser drops
// both. This moves them to what CSP allows (CSSOM is not inline style):
// - a style attribute becomes el.style.cssText;
// - a <style> element (only xterm.js makes them: this page has none of its own) is never put in
//   the document (each insertion, and each change to one in it, is a CSP report: thousands an
//   hour); its text is mirrored into a constructed stylesheet in document.adoptedStyleSheets from
//   when xterm.js appends it until it removes it.

let shimmed = false;

function installCspStyleShim(): void {
  if (shimmed) return;
  shimmed = true;
  const setAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (this: Element, name: string, value: string) {
    if (name.toLowerCase() === "style" && (this as HTMLElement).style) {
      (this as HTMLElement).style.cssText = String(value);
      return;
    }
    return setAttr.call(this, name, value);
  };
  if (!("adoptedStyleSheets" in Document.prototype) || typeof CSSStyleSheet === "undefined") return;

  const mirrored = new WeakSet<Node>();
  const sheets = new Map<HTMLStyleElement, CSSStyleSheet>();
  const sync = (el: HTMLStyleElement) => {
    const sheet = sheets.get(el);
    if (!sheet) return; // not "in the document" (yet, or any more)
    try {
      sheet.replaceSync(el.textContent ?? "");
    } catch {
      /* a rule the browser does not take */
    }
  };
  const attach = (el: HTMLStyleElement) => {
    if (!sheets.has(el)) {
      const sheet = new CSSStyleSheet();
      sheets.set(el, sheet);
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    }
    sync(el);
  };
  const drop = (el: HTMLStyleElement) => {
    const sheet = sheets.get(el);
    if (!sheet) return;
    sheets.delete(el);
    document.adoptedStyleSheets = document.adoptedStyleSheets.filter((s) => s !== sheet);
  };

  const create = Document.prototype.createElement;
  Document.prototype.createElement = function (this: Document, tag: string, options?: ElementCreationOptions) {
    const el = create.call(this, tag, options);
    if (el instanceof HTMLStyleElement) {
      mirrored.add(el);
      el.remove = () => drop(el);
      new MutationObserver(() => sync(el)).observe(el, { childList: true, characterData: true, subtree: true });
    }
    return el;
  } as typeof Document.prototype.createElement;

  const appendChild = Node.prototype.appendChild;
  Node.prototype.appendChild = function <T extends Node>(this: Node, child: T): T {
    if (mirrored.has(child)) {
      attach(child as unknown as HTMLStyleElement);
      return child;
    }
    return appendChild.call(this, child) as T;
  };
}
