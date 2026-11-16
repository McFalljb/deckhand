// The browser's link to its core: one WebSocket at /ws, one corewire frame per binary message.
// Channel 0 is JSON (the window's link, docs/PROTOCOL.md §5a); channels ≥ 1 are terminal streams
// (term.ts). The link says hello, subscribes to the state stream, runs commands, answers the few
// window.requests a browser can, and reconnects when the socket goes.

import { decodeFrame, encodeFrame, JSON_CHANNEL, jsonFrame, Kind, text, type Frame } from "./wire.ts";
import { Store } from "./state.ts";
import { whoami } from "./api.ts";

export const PROTOCOL_VERSION = 1;

// The hello a browser says on the socket (docs/PROTOCOL.md §5c). The cookie already proved the
// browser (a bad one is refused at the upgrade, 401 or 403), so it carries no token. The reply is a
// `result` with this id: data {core, version, generation, features, methods, name, machine,
// snapshot, build, web, framed}.
function helloMessage(): object {
  return { v: PROTOCOL_VERSION, id: "hello", type: "hello", framed: true, peer: "web", snapshot: ["vt"] };
}

export interface Result {
  ok: boolean;
  error?: string;
  data?: any;
  created_id?: number;
  pending?: boolean;
  needs_confirmation?: { summary: string; by: string; token?: string };
}

export type LinkStatus =
  | { kind: "connecting" }
  | { kind: "up" }
  | { kind: "reconnecting"; why: string }
  | { kind: "displaced"; by: string } // another window, machine or browser took the core: Take back ("" = this machine's window)
  | { kind: "unpaired" }
  | { kind: "stopped"; why: string }; // the core ended on purpose

export interface WindowRequest {
  op: string;
  [k: string]: any;
}

export interface LinkHooks {
  status(s: LinkStatus): void;
  toast(text: string, err: boolean): void;
  // a window.request other than the ones the link handles; returns the reply's fields, or null
  request(req: WindowRequest): Record<string, any> | null;
  // the link came up again (after a state.full): re-attach what is shown
  up(): void;
}

const RECONNECT_MIN = 1000;
const RECONNECT_MAX = 15000;
const HIDDEN_STALE = 30000; // hidden longer than this: the socket is suspect (phones drop them silently)
const COMMAND_TIMEOUT = 30000;

export class Link {
  readonly store = new Store();
  private ws: WebSocket | null = null;
  private helloDone = false;
  private core = ""; // the hello's core id this page was loaded against
  private nextId = 1;
  private waiting = new Map<string, { resolve: (r: Result) => void; timer: number }>();
  private finishing = new Map<number, (r: Result) => void>();
  private channels = new Map<number, (f: Frame) => void>();
  private jsonHandlers = new Map<string, (m: any) => void>();
  private retryMs = RECONNECT_MIN;
  private retryTimer = 0;
  private hiddenAt = 0;
  private hold = false; // displaced, unpaired or stopped: no reconnect until asked
  private statusNow: LinkStatus = { kind: "connecting" };

  constructor(private hooks: LinkHooks) {
    document.addEventListener("visibilitychange", () => this.onVisibility());
    window.addEventListener("online", () => this.kick());
  }

  get status(): LinkStatus {
    return this.statusNow;
  }

  get up(): boolean {
    return this.helloDone && this.ws?.readyState === WebSocket.OPEN;
  }

  start(): void {
    this.hold = false;
    this.connect();
  }

  // Take back: the newest link wins at the core, so dialling again takes the view.
  takeBack(): void {
    this.hold = false;
    this.retryMs = RECONNECT_MIN;
    this.connect();
  }

  // ---- sending ----

  sendJson(msg: object): boolean {
    return this.sendRaw(jsonFrame({ v: PROTOCOL_VERSION, ...msg }));
  }

  sendFrame(channel: number, kind: number, payload?: Uint8Array): boolean {
    return this.sendRaw(encodeFrame(channel, kind, payload));
  }

  private sendRaw(b: Uint8Array): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return false;
    this.ws.send(b);
    return true;
  }

  // Runs a command as the user. Resolves with its result, or for one that answered `pending`
  // with its `finished`. Never rejects: a link that goes answers {ok:false}.
  run(command: object): Promise<Result> {
    if (!this.up) return Promise.resolve({ ok: false, error: "not connected" });
    const id = "c" + this.nextId++;
    return new Promise<Result>((resolve) => {
      const timer = window.setTimeout(() => {
        this.waiting.delete(id);
        resolve({ ok: false, error: "no answer from Deckhand" });
      }, COMMAND_TIMEOUT);
      this.waiting.set(id, { resolve, timer });
      this.sendJson({ type: "command", id, now: true, command });
    });
  }

  onChannel(channel: number, fn: ((f: Frame) => void) | null): void {
    if (fn) this.channels.set(channel, fn);
    else this.channels.delete(channel);
  }

  // A JSON message type the link does not handle itself (term.attached, term.scroll).
  onJson(type: string, fn: (m: any) => void): void {
    this.jsonHandlers.set(type, fn);
  }

  // ---- the socket ----

  private connect(): void {
    window.clearTimeout(this.retryTimer);
    this.retryTimer = 0;
    this.dropSocket();
    this.setStatus(this.store.ready ? { kind: "reconnecting", why: "" } : { kind: "connecting" });
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    let ws: WebSocket;
    try {
      ws = new WebSocket(`${proto}//${location.host}/ws`);
    } catch {
      this.retry("could not open the connection");
      return;
    }
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    this.helloDone = false;
    ws.onopen = () => {
      if (this.ws !== ws) return;
      ws.send(jsonFrame(helloMessage()));
    };
    ws.onmessage = (ev) => {
      if (this.ws !== ws || !(ev.data instanceof ArrayBuffer)) return;
      const f = decodeFrame(new Uint8Array(ev.data));
      if (!f) {
        this.retry("a broken frame from Deckhand");
        return;
      }
      if (f.channel === JSON_CHANNEL) {
        if (f.kind === Kind.Data) this.onJsonFrame(f.payload);
        return;
      }
      this.channels.get(f.channel)?.(f);
    };
    ws.onclose = () => {
      if (this.ws !== ws) return;
      const wasUp = this.helloDone;
      this.ws = null;
      this.helloDone = false;
      this.failWaiting();
      if (this.hold) return;
      if (!wasUp) {
        // refused before the hello: maybe this browser is not paired (any more)
        whoami().then((w) => {
          if (w && !w.paired) {
            this.hold = true;
            this.setStatus({ kind: "unpaired" });
          } else this.retry("Deckhand is not answering");
        });
        return;
      }
      this.retry("the connection dropped");
    };
  }

  private dropSocket(): void {
    const ws = this.ws;
    this.ws = null;
    this.helloDone = false;
    if (ws) {
      ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
      try {
        ws.close();
      } catch {
        /* already closed */
      }
    }
    this.failWaiting();
  }

  private retry(why: string): void {
    this.dropSocket();
    if (this.hold) return;
    this.setStatus({ kind: "reconnecting", why });
    window.clearTimeout(this.retryTimer);
    this.retryTimer = window.setTimeout(() => this.connect(), this.retryMs);
    this.retryMs = Math.min(this.retryMs * 2, RECONNECT_MAX);
  }

  // Back in front, or the network came back: dial now instead of waiting out the back-off.
  private kick(): void {
    if (this.hold) return;
    if (!this.ws || this.ws.readyState === WebSocket.CLOSED || this.ws.readyState === WebSocket.CLOSING) {
      this.retryMs = RECONNECT_MIN;
      this.connect();
    }
  }

  private onVisibility(): void {
    if (document.visibilityState === "hidden") {
      this.hiddenAt = Date.now();
      return;
    }
    const away = this.hiddenAt ? Date.now() - this.hiddenAt : 0;
    this.hiddenAt = 0;
    if (this.hold) return;
    if (away > HIDDEN_STALE && this.ws) {
      // a phone may have dropped the socket without telling: start again from a fresh state.full
      this.retryMs = RECONNECT_MIN;
      this.connect();
      return;
    }
    this.kick();
  }

  private failWaiting(): void {
    for (const [, w] of this.waiting) {
      window.clearTimeout(w.timer);
      w.resolve({ ok: false, error: "the connection to Deckhand dropped" });
    }
    this.waiting.clear();
    for (const [, fn] of this.finishing) fn({ ok: false, error: "the connection to Deckhand dropped" });
    this.finishing.clear();
  }

  private setStatus(s: LinkStatus): void {
    this.statusNow = s;
    this.hooks.status(s);
  }

  private displaced(by: string): void {
    this.hold = true;
    this.dropSocket();
    this.setStatus({ kind: "displaced", by });
  }

  // ---- channel 0 ----

  private onJsonFrame(payload: Uint8Array): void {
    let m: any;
    try {
      m = JSON.parse(text(payload));
    } catch {
      return;
    }
    if (!m || typeof m !== "object") return;
    switch (m.type) {
      case "result":
        if (m.id === "hello" && !this.helloDone) this.onHello(m.result ?? {});
        else this.onResult(m);
        return;
      case "finished": {
        const fn = this.finishing.get(Number(m.request_id));
        if (fn) {
          this.finishing.delete(Number(m.request_id));
          fn(m.result ?? { ok: false });
        }
        return;
      }
      case "state.full":
        if (this.store.applyFull(m)) {
          this.retryMs = RECONNECT_MIN;
          this.setStatus({ kind: "up" });
          this.hooks.up();
        }
        return;
      case "state.delta":
        if (!this.store.applyDelta(m)) this.sendJson({ type: "state.subscribe" }); // ask for state.full again
        return;
      case "toast":
        this.hooks.toast(String(m.text ?? ""), !!m.err);
        return;
      case "window.request":
        this.onWindowRequest(String(m.id ?? ""), m.request ?? {});
        return;
      case "web.taken": {
        // another window, machine or browser took the core: Take back dials again
        const by = String(m.by ?? ""), name = String(m.name ?? "");
        this.displaced(by === "machine" ? `Viewed from ${name || "another machine"}` : by === "browser" ? `Viewed in ${name || "another browser"}` : "");
        return;
      }
      case "web.revoked":
        // this browser was unpaired at the Mac: pair again
        this.hold = true;
        this.dropSocket();
        this.setStatus({ kind: "unpaired" });
        return;
      case "web.closed":
        this.hold = true;
        this.dropSocket();
        this.setStatus({ kind: "stopped", why: "Web access was turned off at the Mac." });
        return;
    }
    this.jsonHandlers.get(m.type)?.(m);
  }

  private onHello(r: any): void {
    if (!r.ok) {
      this.hold = true;
      this.dropSocket();
      this.setStatus({ kind: "stopped", why: String(r.error ?? "Deckhand refused this browser") });
      return;
    }
    const core = String(r.data?.core ?? "");
    if (this.core && core && core !== this.core) {
      // a new core (an update or a restart): its page may differ, so load it again
      location.reload();
      return;
    }
    if (core) this.core = core;
    this.helloDone = true;
    this.store.clear();
    this.sendJson({ type: "state.subscribe" });
  }

  private onResult(m: any): void {
    const id = String(m.id ?? "");
    const w = this.waiting.get(id);
    if (!w) return;
    this.waiting.delete(id);
    window.clearTimeout(w.timer);
    const r: Result = m.result ?? { ok: false };
    const rid = Number(m.request_id ?? 0);
    if (r.ok && r.pending && rid) {
      this.finishing.set(rid, w.resolve);
      return;
    }
    w.resolve(r);
  }

  private onWindowRequest(id: string, req: WindowRequest): void {
    const reply = this.hooks.request(req);
    if (id) this.sendJson({ type: "window.reply", id, reply: reply ?? { ok: false } });
  }
}
