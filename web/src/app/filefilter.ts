// The Files tree's filter as data (Files.tsx's FilterBox and FilterList draw it): the core's
// find_files answers a query with the project's files that match every word, best first, relative to
// the root, at most a limit (`more` past it); git's ignored files and credentials are never in it.
// Only the latest query's answer is shown (Latest); the rows are a file's name and its folder.

export interface Found {
  query: string;
  paths: string[]; // absolute, as the tree names them (its root + the relative path)
  more: boolean;
  err: string;
}

export const FIND_LIMIT = 100;
export const FIND_DEBOUNCE_MS = 150;

// Requests in order: an answer is shown only if no newer request (or a clear) came after it.
export class Latest {
  private n = 0;
  next(): number {
    return ++this.n;
  }
  is(n: number): boolean {
    return n === this.n;
  }
}

// find_files' data under the tree's root (the core answers with its real path; the tree keeps the
// path it shows, so a symlinked root's rows still match it). A path that is not a plain relative one
// is dropped.
export function parseFound(root: string, query: string, d: any): Found {
  const paths: string[] = [];
  for (const p of Array.isArray(d?.paths) ? d.paths : []) {
    if (typeof p !== "string" || !p || p.startsWith("/") || p.split("/").some((x) => x === ".." || x === "." || x === "")) continue;
    paths.push(root + "/" + p);
  }
  return { query, paths, more: !!d?.more, err: "" };
}

export interface FoundRow {
  path: string;
  name: string;
  dir: string; // its folder, relative to the root ("" = the root)
}

export function foundRows(root: string, paths: string[]): FoundRow[] {
  return paths.map((path) => {
    const rel = path.startsWith(root + "/") ? path.slice(root.length + 1) : path;
    const i = rel.lastIndexOf("/");
    return { path, name: rel.slice(i + 1), dir: i < 0 ? "" : rel.slice(0, i) };
  });
}

// The highlighted result after a key (-1 = none: no results).
export function stepFound(at: number, n: number, key: string): number {
  if (n <= 0) return -1;
  const i = Math.min(at, n - 1);
  switch (key) {
    case "ArrowDown": return Math.min(i + 1, n - 1);
    case "ArrowUp": return Math.max(i - 1, 0);
    case "Home": return 0;
    case "End": return n - 1;
  }
  return i;
}

// The line under the results ("" = none).
export function foundNote(f: Found): string {
  if (f.err) return f.err;
  if (!f.paths.length) return "No files match";
  if (f.more) return `${f.paths.length} shown, more match: type more to narrow`;
  return "";
}

// Whether Enter opens a result now: the answer is to what is typed (not an older query while a
// newer one is on its way) and there is one.
export function enterOpens(f: Found | null, text: string, busy: boolean): boolean {
  return !busy && !!f && f.query === text.trim() && f.paths.length > 0;
}
