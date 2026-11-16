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


// A file tab's reads, tied to the file it shows: show() starts a new file (a generation); begin()
// gives a read its ticket (null: a poll while this file's read is on its way); end() and current()
// say whether a reply or a save's answer is still for the file shown (another file's: dropped).
export class FileReads {
  private gen = 0;
  private busy = 0; // this generation's reads on their way
  show(): void {
    this.gen++;
    this.busy = 0;
  }
  begin(force: boolean): number | null {
    if (this.busy && !force) return null;
    this.busy++;
    return this.gen;
  }
  end(ticket: number): boolean {
    if (ticket !== this.gen) return false;
    this.busy = Math.max(0, this.busy - 1);
    return true;
  }
  current(ticket: number): boolean {
    return ticket === this.gen;
  }
  get ticket(): number {
    return this.gen;
  }
}
