// The Files tree's header extras in a browser: the filter (find_files over the project's files, a flat
// list of matches in place of the tree; filefilter.ts) and the checkout switcher (the root's name opens
// the project's checkouts; the PAGE's tree shows the one chosen, read-only; checkouts.ts). Files.tsx
// holds the tree and calls these.

import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { type App, type MenuItem } from "./ctx.ts";
import { Icon } from "./icons.tsx";
import { storageGet, storageSet } from "../ui/dom.ts";
import { fileIcon } from "./filetree.ts";
import { FIND_DEBOUNCE_MS, FIND_LIMIT, Latest, enterOpens, foundNote, foundRows, parseFound, stepFound, type Found } from "./filefilter.ts";
import { CHECKOUT_KEY, checkoutLabel, checkoutName, parseCheckouts, viewRoot, type Checkout, type Checkouts } from "./checkouts.ts";

const json = (d: unknown): any => (typeof d === "string" ? JSON.parse(d) : (d ?? {}));

// ---- the checkout switcher ----

export interface CheckoutView {
  root: string; // the root the page's tree shows
  readOnly: boolean; // another checkout: the core refuses writes there
  current?: Checkout;
  list: Checkouts | null;
  choose(path: string): void;
  menu(at: { clientX: number; clientY: number }): void;
}

// home: the folder the tree follows (the session's, else the project's). The choice is kept per home
// in this browser (localStorage, wrapped: private mode loses it).
export function useCheckout(app: App, home: string): CheckoutView {
  const [saved, setSaved] = useState({ home: "", path: "" });
  const [got, setGot] = useState<{ home: string; c: Checkouts } | null>(null);
  const homeNow = useRef(home);
  homeNow.current = home;
  const timer = useRef(0);
  const path = saved.home === home ? saved.path : storageGet(CHECKOUT_KEY(home)) ?? "";
  const list = got?.home === home ? got.c : null;
  const load = async (tries = 0): Promise<Checkouts | null> => {
    const h = home;
    if (!h) return null;
    const r = await app.link.run({ type: "list_worktrees", path: h });
    if (homeNow.current !== h) return null;
    const c: Checkouts = r.ok ? parseCheckouts(json(r.data)) : { base: "", list: [], loading: false, err: r.error || "" };
    setGot({ home: h, c });
    window.clearTimeout(timer.current);
    if (c.loading && tries < 10) timer.current = window.setTimeout(() => load(tries + 1), 600); // the scan is running
    return c;
  };
  useEffect(() => {
    setSaved({ home, path: storageGet(CHECKOUT_KEY(home)) ?? "" });
    load();
    return () => window.clearTimeout(timer.current);
  }, [home]);
  const root = home ? viewRoot(home, path, list) : "";
  // a remembered checkout that is gone (or not this repository's): forgotten
  useEffect(() => {
    if (path && list && !list.loading && root === home) storageSet(CHECKOUT_KEY(home), "");
  }, [root, list]);
  const choose = (p: string) => {
    const v = p === home || p === list?.base ? "" : p;
    storageSet(CHECKOUT_KEY(home), v);
    setSaved({ home, path: v });
  };
  const current = list?.list.find((c) => c.path === root || (root === home && c.path === list.base));
  const menu = async (at: { clientX: number; clientY: number }) => {
    const c = (await load()) ?? list;
    if (!c || homeNow.current !== home) return;
    const now = c.list.find((x) => x.path === root || (root === home && x.path === c.base));
    const items: MenuItem[] = c.list.map((x) => ({
      label: `${checkoutName(x)} · ${checkoutLabel(x)}${x.main ? " (main)" : ""}`,
      check: x === now,
      run: () => choose(x.path),
    }));
    if (!items.length) items.push({ label: c.loading ? "Reading the worktrees…" : c.err || "Not in a git repository", note: true });
    items.push({ sep: true }, { label: "Shows another checkout in this page only. Files there are read-only here.", note: true });
    if (app.phone) app.setOverlay({ menu: null, sheet: { title: "Checkouts", items } });
    else app.setOverlay({ menu: { items, x: at.clientX, y: at.clientY } });
  };
  return { root, readOnly: !!home && root !== home, current, list, choose, menu };
}

// The root's name in the header: the checkout's folder and branch, a caret when there is another to
// switch to (names are text, never HTML).
export function CheckoutButton({ view }: { view: CheckoutView }) {
  const name = view.root.slice(view.root.lastIndexOf("/") + 1);
  const branch = view.current ? checkoutLabel(view.current) : "";
  const many = (view.list?.list.length ?? 0) > 1 || view.readOnly;
  const body = (
    <>
      <span class="files-root-name">{name}</span>
      {branch ? <span class="files-branch"><Icon name="branch" size={11} />{branch}</span> : null}
    </>
  );
  if (!many) return <span class="files-root" title={view.root}>{body}</span>;
  return (
    <button
      type="button"
      class="files-root files-switch"
      title={view.root + " — switch checkout"}
      aria-haspopup="menu"
      aria-label={`Checkout: ${name}${branch ? ", " + branch : ""}. Switch checkout`}
      onClick={(e) => {
        const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
        view.menu({ clientX: r.left, clientY: r.bottom + 2 });
      }}
    >
      {body}
      <Icon name="chevron-down" size={11} class="muted" />
    </button>
  );
}

// ---- the filter ----

export interface FindState {
  text: string;
  found: Found | null; // the latest query's answer (null: none yet)
  busy: boolean;
  at: number; // the highlighted result
  shown: boolean; // a phone: the field is out
  set(text: string): void;
  move(key: string): void;
  pick(i: number): void;
  clear(): void;
  show(on: boolean): void;
}

// The filter over root: debounced, only the latest answer shown, cleared when the root changes.
// open: a result chosen; done: the filter cleared (the tree shows again, that file revealed).
export function useFind(app: App, root: string, open: (path: string) => void, done: (path: string) => void): FindState {
  const [, bump] = useState(0);
  const st = useRef({ text: "", found: null as Found | null, busy: false, at: -1, shown: false, last: "", root }).current;
  const latest = useRef(new Latest()).current;
  const timer = useRef(0);
  const redraw = () => bump((x) => x + 1);
  const ask = (text: string) => {
    window.clearTimeout(timer.current);
    const n = latest.next();
    const q = text.trim();
    if (!q) {
      st.found = null;
      st.busy = false;
      return redraw();
    }
    st.busy = true;
    redraw();
    const r0 = st.root;
    timer.current = window.setTimeout(async () => {
      const r = await app.link.run({ type: "find_files", root: r0, query: q, limit: FIND_LIMIT });
      if (!latest.is(n) || st.root !== r0) return; // a newer query, a clear or another root: stale
      st.found = r.ok ? parseFound(r0, q, json(r.data)) : { query: q, paths: [], more: false, err: r.error || "Could not search" };
      st.busy = false;
      st.at = st.found.paths.length ? 0 : -1;
      redraw();
    }, FIND_DEBOUNCE_MS);
  };
  useEffect(() => {
    st.root = root;
    st.found = null; // another root: the old answer is not this tree's
    st.at = -1;
    st.last = "";
    if (st.text) ask(st.text);
    else redraw();
  }, [root]);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const set = (text: string) => {
    st.text = text;
    ask(text);
  };
  const clear = () => {
    const back = st.last; // the file opened from the results
    st.text = "";
    st.last = "";
    st.at = -1;
    st.shown = false;
    ask("");
    done(back);
  };
  return {
    get text() { return st.text; },
    get found() { return st.found; },
    get busy() { return st.busy; },
    get at() { return st.at; },
    get shown() { return st.shown; },
    set,
    move: (key) => {
      st.at = stepFound(st.at, st.found?.paths.length ?? 0, key);
      redraw();
    },
    pick: (i) => {
      const p = st.found?.paths[i];
      if (!p) return;
      st.at = i;
      st.last = p;
      redraw();
      open(p);
    },
    clear,
    show: (on) => {
      st.shown = on;
      if (!on && st.text) return clear();
      redraw();
    },
  };
}

// The field (under the header; on a phone once the search button shows it). Keys: arrows move the
// highlight, Enter opens it, Esc clears and goes back to the tree.
export function FilterBox({ find, phone, listId }: { find: FindState; phone: boolean; listId: string }) {
  const field = useRef<HTMLInputElement>(null);
  useLayoutEffect(() => {
    if (phone && find.shown) field.current?.focus({ preventScroll: true });
  }, [find.shown]);
  const active = find.found && find.at >= 0 ? `${listId}-${find.at}` : undefined;
  return (
    <label class="filter files-filter">
      <Icon name="search" size={13} />
      <input
        ref={field}
        type="text"
        placeholder="Filter files"
        value={find.text}
        spellcheck={false}
        autocomplete="off"
        autocapitalize="off"
        role="combobox"
        aria-label="Filter files"
        aria-expanded={find.text ? "true" : "false"}
        aria-controls={listId}
        aria-activedescendant={active}
        onInput={(e) => find.set((e.target as HTMLInputElement).value)}
        onKeyDown={(e) => {
          if (e.key === "ArrowDown" || e.key === "ArrowUp") {
            e.preventDefault();
            e.stopPropagation();
            find.move(e.key);
          } else if (e.key === "Enter") {
            e.preventDefault();
            e.stopPropagation();
            // only the answer to what is typed now (not the last query's while a newer one is on its way)
            if (enterOpens(find.found, find.text, find.busy)) find.pick(Math.max(find.at, 0));
          } else if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            if (find.text || find.shown) find.clear();
            else (e.target as HTMLInputElement).blur();
          }
        }}
      />
      {find.text || (phone && find.shown) ? (
        <button type="button" class="icon-btn small" aria-label="Clear the filter" onClick={() => find.clear()}>
          <Icon name="close" size={12} />
        </button>
      ) : null}
    </label>
  );
}

// The matches in place of the tree: name bold, its folder muted; one opens at a time (no picking,
// moving or deleting here). hidden: ignored files are hidden in the tree (they are never searched).
export function FilterList({ find, root, listId, active, ignoredShown, menu }: { find: FindState; root: string; listId: string; active: string; ignoredShown: boolean; menu: (path: string, at: { clientX: number; clientY: number }) => void }) {
  const box = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    box.current?.querySelector<HTMLElement>(".find-row.sel")?.scrollIntoView({ block: "nearest" });
  }, [find.at, find.found]);
  const f = find.found;
  const rows = f ? foundRows(root, f.paths) : [];
  const note = f ? foundNote(f) : "";
  return (
    <div class="nav files-find" ref={box} id={listId} role="listbox" aria-label="Matching files" aria-busy={find.busy ? "true" : "false"}>
      {!f ? <div class="row muted-text find-msg">{find.busy ? "Searching…" : ""}</div> : null}
      {rows.map((r, i) => (
        <div
          key={r.path}
          id={`${listId}-${i}`}
          class={"row find-row" + (i === find.at ? " sel" : "") + (r.path === active ? " active" : "")}
          role="option"
          aria-selected={i === find.at ? "true" : "false"}
          title={r.path}
          onMouseDown={(e) => e.preventDefault()} // the field keeps focus
          onClick={() => find.pick(i)}
          onContextMenu={(e) => {
            e.preventDefault();
            menu(r.path, e);
          }}
        >
          <Icon name={fileIcon(r.name, "file", false)} size={14} class="muted kind" />
          <span class="find-name">{r.name}</span>
          {r.dir ? <span class="find-dir">{r.dir}</span> : null}
        </div>
      ))}
      {note ? <div class={"row find-msg " + (f?.err ? "error-ink" : "muted-text")} role={f?.err ? "alert" : undefined}>{note}</div> : null}
      {f && ignoredShown && !f.err ? <div class="row find-msg muted-text small">Ignored files are not searched</div> : null}
    </div>
  );
}
