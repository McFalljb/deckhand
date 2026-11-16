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
  send() {}
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
const { jsonFrame } = await import("../src/wire.ts");

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
