// The Files tree's checkout switcher in a browser, as data (Files.tsx draws it): the project's
// checkouts from list_worktrees (main first; a gone or prunable one left out), and which one the
// PAGE's tree shows. The choice is this page's alone, remembered per project in this browser: it never
// calls files_set_root (shared State: it would switch the window's tree too). In another checkout the
// core lets the page read (list_dir, find_files, file_read: "reads in another checkout",
// docs/PROTOCOL.md) and refuses every write, so the tree offers none there.

export interface Checkout {
  path: string;
  branch: string; // "" = detached
  head: string;
  main: boolean;
}

export interface Checkouts {
  base: string; // the project's folder as the core resolved it (real path)
  list: Checkout[];
  loading: boolean; // the scan has not answered yet: ask again
  err: string;
}

export const CHECKOUT_KEY = (home: string) => "deckhand.files.checkout:" + home;

export function parseCheckouts(d: any): Checkouts {
  const list: Checkout[] = [];
  for (const w of Array.isArray(d?.worktrees) ? d.worktrees : []) {
    if (typeof w?.path !== "string" || !w.path.startsWith("/") || w.missing || w.prunable || w.bare) continue;
    list.push({ path: w.path, branch: typeof w.branch === "string" ? w.branch : "", head: typeof w.head === "string" ? w.head : "", main: !!w.main });
  }
  return { base: typeof d?.base === "string" ? d.base : "", list, loading: !!d?.loading, err: typeof d?.error === "string" ? d.error : "" };
}

// What a checkout has on: its branch, else "detached <short id>".
export function checkoutLabel(c: Checkout): string {
  return c.branch || "detached " + c.head.slice(0, 7);
}

export function checkoutName(c: Checkout | { path: string }): string {
  return c.path.slice(c.path.lastIndexOf("/") + 1);
}

// The root the page's tree shows: the remembered checkout while the list has it (or before the list
// came: the core refuses what is not a listed checkout), else the tree's own folder (home).
export function viewRoot(home: string, saved: string, c: Checkouts | null): string {
  if (!saved || saved === home) return home;
  if (!c || (c.loading && !c.list.length)) return saved;
  if (saved === c.base) return home; // the project's own folder (by its real path)
  return c.list.some((x) => x.path === saved) ? saved : home;
}
