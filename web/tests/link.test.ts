// The link's redial timing (#148): a fake socket and timers, no page.
import { test } from "node:test";
import assert from "node:assert/strict";

const timers: { fn: () => void; ms: number }[] = [];
const sockets: FakeSocket[] = [];
class FakeSocket {
  static OPEN = 1;
  readyState = 0;
  binaryType = "";
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: ArrayBuffer }) => void) | null = null;
  onclose: ((ev: { code: number }) => void) | null = null;
  onerror: (() => void) | null = null;
  url: string;
  constructor(url: string) {
    this.url = url;
    sockets.push(this);
  }
  sent: Uint8Array[] = [];
  send(b: Uint8Array) {
    this.sent.push(b);
  }
  close() {}
}
const g = globalThis as any;
g.WebSocket = FakeSocket;
g.window = { setTimeout: (fn: () => void, ms: number) => (timers.push({ fn, ms }), timers.length), clearTimeout: () => {}, addEventListener: () => {} };
g.document = { addEventListener: () => {}, visibilityState: "visible" };
g.location = { protocol: "http:", host: "127.0.0.1:1", reload: () => {} };
g.localStorage = { getItem: () => "a".repeat(64), setItem: () => {}, removeItem: () => {} };
g.fetch = async () => ({ ok: true, status: 200, json: async () => ({ paired: true }) });

const { Link } = await import("../src/link.ts");
const { jsonFrame, encodeFrame, decodeFrame, text, Kind } = await import("../src/wire.ts");

function deliver(ws: FakeSocket, msg: object) {
  const f = jsonFrame(msg);
  ws.onmessage!({ data: f.buffer.slice(f.byteOffset, f.byteOffset + f.byteLength) as ArrayBuffer });
}
function helloOk(ws: FakeSocket) {
  ws.readyState = 1;
  ws.onopen!();
  deliver(ws, { type: "result", id: "hello", result: { ok: true, data: { core: "c1" } } });
}

test("redial: fast only after a link that got its state and stayed up; else the back-off", async () => {
  const realNow = Date.now;
  let now = 1_000_000;
  Date.now = () => now;
  try {
    const link = new Link({ up: () => {}, status: () => {} } as any);
    link.start();
    // up a while with its state: a drop is a blip, the first redial comes soon
    helloOk(sockets.at(-1)!);
    deliver(sockets.at(-1)!, { type: "state.full", version: 1, state: {} });
    now += 5000;
    sockets.at(-1)!.onclose!({ code: 1006 });
    assert.equal(timers.at(-1)!.ms, 100);
    // the next connection says hello but closes before its state.full (the last one's time is old):
    // backs off, again and again
    timers.at(-1)!.fn();
    helloOk(sockets.at(-1)!);
    now += 5000;
    sockets.at(-1)!.onclose!({ code: 1006 });
    assert.equal(timers.at(-1)!.ms, 1000);
    timers.at(-1)!.fn();
    helloOk(sockets.at(-1)!);
    now += 5000;
    sockets.at(-1)!.onclose!({ code: 1006 });
    assert.equal(timers.at(-1)!.ms, 2000);
  } finally {
    Date.now = realNow;
  }
});

// A Take back (or any redial) is a new socket: a terminal channel is the old socket's only. The
// link counts its sockets (termstream.ts: a stream attached on an older one is not attached, and
// attaches again: a fresh snapshot and this page's grid) and forgets the old socket's channels (a
// channel number on the new one is another stream's).
test("a new socket: the serial moves on and the old socket's channels are forgotten", () => {
  const link = new Link({ up: () => {}, status: () => {} } as any);
  link.start();
  helloOk(sockets.at(-1)!);
  deliver(sockets.at(-1)!, { type: "state.full", version: 1, state: {} });
  const first = link.serial;
  let old = 0;
  link.onChannel(3, () => old++);
  const frame = (ch: number) => {
    const f = encodeFrame(ch, Kind.Data, new Uint8Array([0x41]));
    sockets.at(-1)!.onmessage!({ data: f.buffer.slice(f.byteOffset, f.byteOffset + f.byteLength) as ArrayBuffer });
  };
  frame(3);
  assert.equal(old, 1);
  // displaced, then Take back
  link.takeBack();
  helloOk(sockets.at(-1)!);
  assert.ok(link.serial > first, "a new socket");
  frame(3); // channel 3 on the new socket: not the old stream's
  assert.equal(old, 1);
});

// The hello a socket said (its first message).
function helloOf(ws: FakeSocket): any {
  ws.readyState = 1;
  ws.onopen!();
  return JSON.parse(text(decodeFrame(ws.sent[0])!.payload));
}

// A browser's own connects (the page's start, a redial) never take the view from the Mac's window:
// their hello has no "take". Only its user's View here (or Take back), or the first connect after
// pairing, says "take": true; a redial after that says it again only until a hello was answered.
test("take: only on the user's action", async () => {
  timers.length = 0; // the earlier tests' links' redials
  const statuses: any[] = [];
  const link = new Link({ up: () => {}, status: (s: any) => statuses.push(s) } as any);
  link.start();
  let ws = sockets.at(-1)!;
  assert.equal(helloOf(ws).take, undefined, "the page's own connect");
  deliver(ws, { type: "result", id: "hello", result: { ok: true, data: { core: "c1" } } });
  // the Mac's window is attached: the core says the hello's result, then web.taken by the window
  deliver(ws, { type: "web.taken", by: "window", name: "" });
  assert.deepEqual(statuses.at(-1), { kind: "displaced", by: "" });
  const n = sockets.length;
  timers.splice(0).forEach((t) => t.fn());
  assert.equal(sockets.length, n, "displaced: no redial of its own");
  // View here
  link.takeBack();
  ws = sockets.at(-1)!;
  assert.equal(helloOf(ws).take, true, "View here takes");
  // it fails before its hello is answered: the redial still takes
  ws.onclose!({ code: 1006 });
  await new Promise((r) => setImmediate(r)); // refused before the hello: whoami, then the redial
  timers.at(-1)!.fn();
  ws = sockets.at(-1)!;
  assert.equal(helloOf(ws).take, true, "a redial of View here");
  deliver(ws, { type: "result", id: "hello", result: { ok: true, data: { core: "c1" } } });
  deliver(ws, { type: "state.full", version: 1, state: {} });
  // up: a later drop's redial is the browser's own again
  ws.onclose!({ code: 1006 });
  timers.at(-1)!.fn();
  assert.equal(helloOf(sockets.at(-1)!).take, undefined, "a redial after it was up");
  // the first connect after pairing is the user's own
  const paired = new Link({ up: () => {}, status: () => {} } as any);
  paired.start(true);
  assert.equal(helloOf(sockets.at(-1)!).take, true, "just paired");
});
