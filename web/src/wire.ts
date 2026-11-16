// The framed wire (src/corewire/wire.odin): [channel u32 LE][kind u8][len u32 LE][payload ≤ 16 MiB].
// Over the WebSocket each binary message is exactly one frame. Channel 0 carries JSON; channels ≥ 1
// are terminal streams. A receiver ignores kinds it does not know.

export const HEADER_SIZE = 9;
export const MAX_PAYLOAD = 16 * 1024 * 1024;
export const JSON_CHANNEL = 0;

export const Kind = {
  Data: 1,
  Snapshot: 2,
  Resize: 3,
  Credit: 4,
  Close: 5,
  Focus: 6,
} as const;

export interface Frame {
  channel: number;
  kind: number;
  payload: Uint8Array;
}

export function encodeFrame(channel: number, kind: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array {
  if (payload.length > MAX_PAYLOAD) throw new RangeError("frame payload over 16 MiB");
  const out = new Uint8Array(HEADER_SIZE + payload.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, channel >>> 0, true);
  dv.setUint8(4, kind);
  dv.setUint32(5, payload.length, true);
  out.set(payload, HEADER_SIZE);
  return out;
}

// One whole frame from one WebSocket message. null: not exactly one frame (short, over the limit,
// or bytes after it), which the link treats as a broken stream.
export function decodeFrame(msg: Uint8Array): Frame | null {
  if (msg.length < HEADER_SIZE) return null;
  const dv = new DataView(msg.buffer, msg.byteOffset, msg.byteLength);
  const channel = dv.getUint32(0, true);
  const kind = dv.getUint8(4);
  const len = dv.getUint32(5, true);
  if (len > MAX_PAYLOAD || HEADER_SIZE + len !== msg.length) return null;
  return { channel, kind, payload: msg.subarray(HEADER_SIZE, HEADER_SIZE + len) };
}

const enc = new TextEncoder();
const dec = new TextDecoder();

export function jsonFrame(msg: object): Uint8Array {
  return encodeFrame(JSON_CHANNEL, Kind.Data, enc.encode(JSON.stringify(msg)));
}

export function u32le(n: number): Uint8Array {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n >>> 0, true);
  return b;
}

export function utf8(s: string): Uint8Array {
  return enc.encode(s);
}

export function text(b: Uint8Array): string {
  return dec.decode(b);
}

// A SNAPSHOT payload: [meta_len u32 LE][meta JSON][body] (src/core/snapshot.odin).
export interface SnapshotMeta {
  format?: string;
  offset?: number;
  cols?: number;
  rows?: number;
  exited?: number;
  exit_code?: number;
  exit_signal?: number;
  inexact?: boolean;
}

export const SNAPSHOT_META_MAX = 64 * 1024;

export function decodeSnapshot(p: Uint8Array): { meta: SnapshotMeta; body: Uint8Array } | null {
  if (p.length < 4) return null;
  const n = new DataView(p.buffer, p.byteOffset, p.byteLength).getUint32(0, true);
  if (n > SNAPSHOT_META_MAX || 4 + n > p.length) return null;
  let meta: SnapshotMeta;
  try {
    meta = JSON.parse(dec.decode(p.subarray(4, 4 + n)));
  } catch {
    return null;
  }
  if (typeof meta !== "object" || meta === null) return null;
  return { meta, body: p.subarray(4 + n) };
}
