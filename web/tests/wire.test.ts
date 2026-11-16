// The frame codec against the core's golden frames (tests/framed-wire/v1/, frozen forever).

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { decodeFrame, decodeSnapshot, encodeFrame, HEADER_SIZE, Kind, MAX_PAYLOAD, text } from "../src/wire.ts";

const dir = join(import.meta.dirname, "../../tests/framed-wire/v1");
const golden = (name: string) => new Uint8Array(readFileSync(join(dir, name)));

const CASES: [string, number, number, string][] = [
  ["data-json.bin", 0, Kind.Data, '{"id":1,"method":"state.subscribe"}'],
  ["data-terminal.bin", 7, Kind.Data, "ls\r"],
  ["snapshot.bin", 0x01020304, Kind.Snapshot, ""],
  ["resize.bin", 7, Kind.Resize, ""],
  ["credit.bin", 7, Kind.Credit, ""],
  ["close.bin", 7, Kind.Close, ""],
  ["focus.bin", 0xffffffff, Kind.Focus, ""],
];

test("golden frames decode and encode to the same bytes", () => {
  for (const [name, channel, kind, payload] of CASES) {
    const bytes = golden(name);
    const f = decodeFrame(bytes);
    assert.ok(f, name);
    assert.equal(f.channel, channel, name);
    assert.equal(f.kind, kind, name);
    assert.equal(text(f.payload), payload, name);
    assert.deepEqual(encodeFrame(f.channel, f.kind, f.payload), bytes, name);
  }
});

test("a message that is not exactly one frame is refused", () => {
  const bytes = golden("data-terminal.bin");
  assert.equal(decodeFrame(bytes.subarray(0, HEADER_SIZE - 1)), null); // short header
  assert.equal(decodeFrame(bytes.subarray(0, bytes.length - 1)), null); // short payload
  const extra = new Uint8Array(bytes.length + 1);
  extra.set(bytes);
  assert.equal(decodeFrame(extra), null); // bytes after it
  const big = new Uint8Array(HEADER_SIZE);
  new DataView(big.buffer).setUint32(5, MAX_PAYLOAD + 1, true);
  assert.equal(decodeFrame(big), null); // over the limit, known from the header
  assert.throws(() => encodeFrame(1, Kind.Data, new Uint8Array(MAX_PAYLOAD + 1)));
});

test("a frame inside a larger buffer decodes from its own offset", () => {
  const bytes = golden("data-json.bin");
  const backing = new Uint8Array(bytes.length + 5);
  backing.set(bytes, 5);
  const f = decodeFrame(backing.subarray(5));
  assert.ok(f);
  assert.equal(text(f.payload), '{"id":1,"method":"state.subscribe"}');
});

test("a snapshot payload splits into meta and body", () => {
  const meta = new TextEncoder().encode('{"format":"vt","offset":42,"cols":80,"rows":24,"inexact":true}');
  const body = new TextEncoder().encode("\x1b[Hhello");
  const p = new Uint8Array(4 + meta.length + body.length);
  new DataView(p.buffer).setUint32(0, meta.length, true);
  p.set(meta, 4);
  p.set(body, 4 + meta.length);
  const s = decodeSnapshot(p);
  assert.ok(s);
  assert.equal(s.meta.format, "vt");
  assert.equal(s.meta.cols, 80);
  assert.equal(text(s.body), "\x1b[Hhello");
  assert.equal(decodeSnapshot(p.subarray(0, 10)), null); // meta cut short
});
