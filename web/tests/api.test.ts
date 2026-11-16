// The pairing key (docs/PROTOCOL.md §5b): a cookie is a host name's, not a port's, so pairing
// also returns a key kept in this page's own storage; without it the browser is not paired.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

const store = new Map<string, string>();
(globalThis as any).localStorage = {
  getItem: (k: string) => (store.has(k) ? store.get(k)! : null),
  setItem: (k: string, v: string) => void store.set(k, String(v)),
  removeItem: (k: string) => void store.delete(k),
};

let calls: { url: string; init: any }[] = [];
let answer: (url: string) => { status: number; body: unknown } = () => ({ status: 500, body: {} });
(globalThis as any).fetch = async (url: string, init: any) => {
  calls.push({ url, init });
  const a = answer(url);
  return { status: a.status, ok: a.status >= 200 && a.status < 300, json: async () => a.body };
};

const { pair, whoami, unpair, pairKey } = await import("../src/api.ts");

const KEY = "ab".repeat(32);

beforeEach(() => {
  store.clear();
  calls = [];
});

test("pairing keeps the key the core returns", async () => {
  answer = () => ({ status: 200, body: { paired: true, key: KEY } });
  assert.equal(await pair("ABCDEFGH", "phone"), "ok");
  assert.equal(pairKey(), KEY);
});

test("a pairing answer without a well-formed key is not a pairing", async () => {
  answer = () => ({ status: 200, body: { paired: true } });
  assert.equal(await pair("ABCDEFGH", "phone"), "unreachable");
  assert.equal(pairKey(), null);
});

test("the cookie alone is not paired: no key here shows the pairing screen", async () => {
  answer = () => ({ status: 200, body: { paired: true, name: "phone" } });
  assert.deepEqual(await whoami(), { paired: false });
  store.set("deckhand.key", KEY);
  assert.equal((await whoami())?.paired, true);
});

test("unpair sends the key and forgets it", async () => {
  store.set("deckhand.key", KEY);
  answer = () => ({ status: 200, body: { paired: false } });
  assert.equal(await unpair(), true);
  assert.equal(calls[0].init.headers["X-Deckhand-Key"], KEY);
  assert.equal(pairKey(), null);
});
