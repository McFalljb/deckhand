// One terminal stream: the tab on screen, attached on its own channel (src/core/term_stream.odin).
//
//   browser: {"type":"term.attach","id","tab_id","history_lines":0,"snapshot":"vt","snapshot_max"}
//   core:    {"type":"term.attached","id","tab_id","channel","offset"}  (or "error")
//   core:    [C][SNAPSHOT] meta + the VT replay; [C][DATA] bytes; [C][RESIZE] {offset,cols,rows};
//            [C][CLOSE]; {"type":"term.scroll","channel"}
//   browser: [C][DATA] input; [C][CREDIT] u32 LE bytes taken; [C][FOCUS] 1|0;
//            {"type":"term.resize","tab_id","cols","rows","cell_w","cell_h"}; {"type":"term.detach"}
//
// DATA waits for credit at the core (256 KiB in flight); this side credits each DATA frame once
// the emulator has parsed it, so a slow phone slows the stream instead of queueing it. Only the
// tab on screen is attached; a phone asks for small snapshots.

import { decodeSnapshot, Kind, text, u32le, type Frame } from "./wire.ts";
import type { Link } from "./link.ts";
import type { Fit, TermView } from "./term.ts";

const SNAPSHOT_MAX = 256 * 1024;
const CREDIT_BATCH = 32 * 1024;
const CREDIT_DELAY = 25; // ms: small credits go together
const FIT_DELAY = 150; // ms: a keyboard sliding in resizes once, not every frame

export type StreamEvent = { kind: "attached" } | { kind: "live" } | { kind: "error"; text: string } | { kind: "closed" };

export class TermStream {
  tabId = 0;
  private channel = 0;
  private attachId = "";
  private seq = 0;
  private credit = 0;
  private creditTimer = 0;
  private fitTimer = 0;
  private sentFit: Fit | null = null;
  private fitRetries = 0;
  private serial = 0; // the link's socket the channel is on (link.ts)
  private live = false; // bytes came on this channel
  private onEvent: (e: StreamEvent) => void = () => {};
  private off: (() => void)[];

  constructor(
    private link: Link,
    private view: TermView,
    // a peek (Peek.tsx): only looks: never says it has the keyboard, never asks for a size
    private look = false,
  ) {
    this.off = [
      link.onJson("term.attached", (m) => this.onAttached(m)),
      link.onJson("term.scroll", (m) => {
        if (this.channel && Number(m.channel) === this.channel) view.scrollToBottom();
      }),
    ];
  }

  // Detached and deaf: the pane went.
  dispose(): void {
    this.detach();
    for (const f of this.off) f();
  }

  events(fn: (e: StreamEvent) => void): void {
    this.onEvent = fn;
  }

  attach(tabId: number): void {
    if (this.tabId === tabId && (this.attached || this.attachId)) return;
    this.detach();
    this.tabId = tabId;
    this.view.reset();
    this.sendAttach();
  }

  // The link came up again: a fresh channel and snapshot.
  reattach(): void {
    if (!this.tabId) return;
    this.dropChannel();
    this.sentFit = null;
    this.sendAttach();
  }

  detach(): void {
    if (this.attached) this.link.sendJson({ type: "term.detach", channel: this.channel });
    if (this.attached) this.focus(false);
    this.dropChannel();
    this.tabId = 0;
    this.sentFit = null;
  }

  // on the link's socket now: a channel from before a reconnect (a Take back while the pane was
  // not shown, its terminal kept) is gone, and its number may be another stream's now
  get attached(): boolean {
    return this.channel !== 0 && this.serial === this.link.serial;
  }

  input(b: Uint8Array): void {
    if (this.look) return;
    if (!this.attached || b.length === 0) return;
    this.link.sendFrame(this.channel, Kind.Data, b);
  }

  focus(gained: boolean): void {
    if (this.look) return;
    if (this.attached) this.link.sendFrame(this.channel, Kind.Focus, new Uint8Array([gained ? 1 : 0]));
  }

  // The element's size changed: ask the core for the grid it fits (the core alone resizes).
  refit(now = false): void {
    if (this.look) return;
    window.clearTimeout(this.fitTimer);
    if (now) this.sendFit();
    else this.fitTimer = window.setTimeout(() => this.sendFit(), FIT_DELAY);
  }

  // What a new terminal's pane fits (window.request term_fit), null: not known.
  currentFit(): Fit | null {
    return this.view.fit();
  }

  private sendAttach(): void {
    this.attachId = `t${this.tabId}.${++this.seq}`;
    this.link.sendJson({
      type: "term.attach",
      id: this.attachId,
      tab_id: this.tabId,
      history_lines: 0,
      snapshot: "vt",
      snapshot_max: SNAPSHOT_MAX,
    });
  }

  private sendFit(): void {
    if (!this.tabId || !this.attached) return;
    const f = this.view.fit();
    if (!f) {
      // not measurable yet (the renderer has no cell size before its first paint): again shortly
      if (this.fitRetries++ < 20) this.fitTimer = window.setTimeout(() => this.sendFit(), 100);
      return;
    }
    this.fitRetries = 0;
    const s = this.sentFit;
    if (s && s.cols === f.cols && s.rows === f.rows) return;
    this.sentFit = f;
    this.link.sendJson({ type: "term.resize", tab_id: this.tabId, cols: f.cols, rows: f.rows, cell_w: f.cellW, cell_h: f.cellH });
  }

  private onAttached(m: any): void {
    if (String(m.id ?? "") !== this.attachId) return;
    this.attachId = "";
    if (m.error) {
      this.onEvent({ kind: "error", text: String(m.error) });
      return;
    }
    this.channel = Number(m.channel) || 0;
    if (!this.channel) return;
    this.live = false;
    this.serial = this.link.serial;
    this.link.onChannel(this.channel, (f) => this.onFrame(f));
    this.focus(true);
    this.refit(true);
    this.onEvent({ kind: "attached" });
  }

  private onFrame(f: Frame): void {
    // the first bytes of this channel (a snapshot or output): the stream works (Term.tsx's reopen)
    if (!this.live && (f.kind === Kind.Snapshot || f.kind === Kind.Data)) {
      this.live = true;
      this.onEvent({ kind: "live" });
    }
    switch (f.kind) {
      case Kind.Snapshot: {
        const s = decodeSnapshot(f.payload);
        if (!s) return;
        this.view.reset();
        if (s.meta.cols && s.meta.rows) this.view.resize(s.meta.cols, s.meta.rows);
        this.view.write(s.body);
        // the snapshot's grid is the terminal's as it was: this pane's, if it differs
        this.sentFit = null;
        this.refit();
        return;
      }
      case Kind.Data: {
        const n = f.payload.length, ch = this.channel;
        // the payload is a view into the message's buffer, which nothing else holds: no copy.
        // Credited once parsed, and only to the channel it came on (not one attached since).
        this.view.write(f.payload, () => {
          if (this.channel === ch) this.addCredit(n);
        });
        return;
      }
      case Kind.Resize: {
        let r: any;
        try {
          r = JSON.parse(text(f.payload));
        } catch {
          return;
        }
        const cols = Number(r.cols), rows = Number(r.rows);
        // after exactly the bytes before it: queued behind what was written
        this.view.write(new Uint8Array(0), () => this.view.resize(cols, rows));
        return;
      }
      case Kind.Close:
        this.dropChannel();
        this.onEvent({ kind: "closed" });
        return;
    }
  }

  private addCredit(n: number): void {
    if (!this.attached) return;
    this.credit += n;
    if (this.credit >= CREDIT_BATCH) {
      this.flushCredit();
      return;
    }
    if (!this.creditTimer) this.creditTimer = window.setTimeout(() => this.flushCredit(), CREDIT_DELAY);
  }

  private flushCredit(): void {
    window.clearTimeout(this.creditTimer);
    this.creditTimer = 0;
    if (this.attached && this.credit > 0) this.link.sendFrame(this.channel, Kind.Credit, u32le(this.credit));
    this.credit = 0;
  }

  private dropChannel(): void {
    if (this.channel && this.serial === this.link.serial) this.link.onChannel(this.channel, null);
    window.clearTimeout(this.creditTimer);
    this.creditTimer = 0;
    this.credit = 0;
    this.channel = 0;
    this.attachId = "";
  }
}
