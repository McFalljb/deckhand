export interface KnownFile {
  path: string;
  size: number;
  mtime: number;
  hash: string;
  markdown: boolean;
  text?: string;
  same?: boolean;
}

// File tabs' memory (Files.tsx): the files the page read last, by path (their text and hash): a tab shown again starts from it and
// asks with its hash, so an unchanged file is not sent again (a 4 MB file was, each time). The
// last KNOWN_MAX files, KNOWN_BYTES of text at most.
const KNOWN_MAX = 8;
const KNOWN_BYTES = 16 << 20;
const known = new Map<string, KnownFile>();
export function knowFile(path: string, d: KnownFile) {
  known.delete(path);
  known.set(path, d);
  let bytes = 0;
  for (const f of known.values()) bytes += f.text?.length ?? 0;
  for (const [k, f] of known) {
    if (known.size <= KNOWN_MAX && bytes <= KNOWN_BYTES) break;
    if (k === path) continue;
    known.delete(k);
    bytes -= f.text?.length ?? 0;
  }
}
export function knownFile(path: string): KnownFile | undefined {
  return known.get(path);
}

