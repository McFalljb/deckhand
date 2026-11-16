// The Files tab (the left column) and the session's editor and Markdown tabs in a browser.
// The tree is the session's folder (else the selected project's), listed with list_dir (inside a
// project, git status codes, .git and ignored left out), folders opened in the page itself. A click
// opens the file as the window does (show_file: a Markdown tab for .md, an editor tab otherwise;
// credentials and binaries refused). The tabs read and save the file with file_read / file_save
// (src/core/web_files.odin): line numbers, editing, ⌘S, a file changed on disk is followed when
// nothing is edited and asked about when it is. Markdown renders with markdown.ts (no raw HTML).

import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { OpenSession, Tab } from "../state.ts";
import { IS_MAC, shownSession, useApp, type App } from "./ctx.ts";
import { Icon } from "./icons.tsx";
import { parseMarkdown, safeHref, type Block, type Inline } from "./markdown.ts";
import { Windowed, type WItem } from "./Windowed.tsx";

// A result's data: the link gives it parsed (an object) or as text.
const json = (d: unknown): any => (typeof d === "string" ? JSON.parse(d) : (d ?? {}));

// ---- the tree ----

interface Entry {
  name: string;
  kind: "file" | "dir" | "symlink";
  git?: string;
}

const open = new Set<string>(); // folders opened (the page's own)
const listed = new Map<string, { entries: Entry[]; err: string }>();
let bump = () => {};

async function list(app: App, path: string) {
  const r = await app.link.run({ type: "list_dir", path });
  listed.set(path, r.ok ? { entries: json(r.data).entries ?? [], err: "" } : { entries: [], err: r.error || "cannot list it" });
  bump();
}

export function FilesPanel() {
  const app = useApp();
  const { store } = app;
  const [, set] = useState(0);
  bump = () => set((x) => x + 1);
  const s = store.session(shownSession(app));
  const p = store.project(store.selectedProject);
  const root = s && !s.home && !s.machine ? s.cwd : p && !p.machine ? p.cwd : "";
  // listed when shown, and again every few seconds while it shows (the files change)
  useEffect(() => {
    if (!root) return;
    const again = () => {
      list(app, root);
      for (const d of open) if (d.startsWith(root + "/")) list(app, d);
    };
    again();
    const t = window.setInterval(again, 5000);
    return () => window.clearInterval(t);
  }, [root]);
  if (!root) return <div class="files"><div class="empty-state"><div>No folder</div><div class="muted small">Open a session of this machine</div></div></div>;
  const rowH = app.phone ? 40 : 26;
  const items: WItem[] = [];
  const walk = (dir: string, depth: number) => {
    const l = listed.get(dir);
    if (!l) return void items.push({ key: "l:" + dir, h: rowH, draw: () => <div class="row file-row muted-text" style={{ paddingLeft: 8 + depth * 16 + "px" }}>Listing…</div> });
    if (l.err) return void items.push({ key: "e:" + dir, h: rowH, draw: () => <div class="row file-row error-ink" style={{ paddingLeft: 8 + depth * 16 + "px" }}>{l.err}</div> });
    for (const e of l.entries) {
      const path = dir + "/" + e.name;
      const isDir = e.kind === "dir";
      items.push({ key: path, h: rowH, draw: () => <FileRow app={app} e={e} path={path} depth={depth} /> });
      if (isDir && open.has(path)) walk(path, depth + 1);
    }
  };
  walk(root, 0);
  return (
    <div class="files">
      <div class="files-head">
        <Icon name="folder" size={14} class="muted" />
        <span class="files-root" title={root}>{root.slice(root.lastIndexOf("/") + 1)}</span>
        <span class="spacer" />
        <button type="button" class="icon-btn small" title="Collapse all" aria-label="Collapse all" onClick={() => { for (const d of [...open]) if (d.startsWith(root + "/")) open.delete(d); bump(); }}>
          <Icon name="chevron-down" size={12} />
        </button>
      </div>
      <div class="nav"><Windowed items={items} /></div>
    </div>
  );
}

const GIT_CLASS: Record<string, string> = { M: "st-M", A: "st-A", D: "st-D", R: "st-R", U: "st-U", "?": "st-q", "??": "st-q" };

function FileRow({ app, e, path, depth }: { app: App; e: Entry; path: string; depth: number }) {
  const isDir = e.kind === "dir";
  const on = isDir && open.has(path);
  const git = (e.git ?? "").trim();
  return (
    <div
      class="row file-row"
      style={{ paddingLeft: 8 + depth * 16 + "px" }}
      role="button"
      tabIndex={0}
      title={path}
      onClick={() => {
        if (isDir) {
          if (on) open.delete(path);
          else {
            open.add(path);
            if (!listed.has(path)) list(app, path);
          }
          bump();
        } else app.run({ type: "show_file", path });
      }}
    >
      {isDir ? <Icon name={on ? "chevron-down" : "chevron-right"} size={12} class="chev" /> : <span class="chev-gap" />}
      <Icon name={isDir ? "folder" : "file"} size={14} class="muted" />
      <span class={"title " + (GIT_CLASS[git] ?? "")}>{e.name}</span>
      <span class="spacer" />
      {git ? <span class={"ch-letter " + (GIT_CLASS[git] ?? "")}>{git === "??" ? "?" : git}</span> : null}
    </div>
  );
}

// ---- a file in a tab ----

interface FileData {
  path: string;
  size: number;
  mtime: number;
  hash: string;
  markdown: boolean;
  text?: string;
  same?: boolean;
}

// The tab's file: read, followed on disk while it is not edited, saved.
function useFile(app: App, path: string) {
  const [file, setFile] = useState<FileData | null>(null);
  const [err, setErr] = useState("");
  const [draft, setDraft] = useState<string | null>(null); // the edit (null: none)
  const [changed, setChanged] = useState(false); // on disk since it was read, while edited
  const cur = useRef<FileData | null>(null);
  const editing = useRef(false);
  editing.current = draft !== null;
  const reading = useRef(0); // reads on their way: a poll waits for them (a big file on a slow link: no second copy)
  const read = async (force = false) => {
    if (reading.current && !force) return;
    reading.current++;
    const r = await app.link.run({ type: "file_read", path, since: force ? "" : cur.current?.hash ?? "" }).finally(() => reading.current--);
    if (!r.ok) {
      setErr(r.error || "cannot read it");
      return;
    }
    setErr("");
    const d: FileData = json(r.data);
    if (d.same) return;
    if (editing.current && cur.current && !force) return setChanged(true);
    cur.current = d;
    setFile(d);
    setChanged(false);
  };
  useEffect(() => {
    cur.current = null;
    setFile(null);
    setDraft(null);
    read(true);
    const t = window.setInterval(() => read(), 2500);
    return () => window.clearInterval(t);
  }, [path]);
  const save = async (force = false) => {
    if (draft === null || !cur.current) return;
    const r = await app.link.run({ type: "file_save", path, text: draft, base: cur.current.hash, force });
    if (!r.ok) {
      if (json(r.data)?.code === "changed") setChanged(true);
      else app.toast(r.error || "Could not save it", true);
      return;
    }
    const d: FileData = json(r.data);
    cur.current = { ...d, text: draft };
    setFile(cur.current);
    setDraft(null);
    setChanged(false);
  };
  const reload = () => {
    setDraft(null);
    setChanged(false);
    read(true);
  };
  return { file, err, draft, setDraft, changed, save, reload };
}

export function FileTab({ tab, path, markdown }: { s: OpenSession; tab: Tab; path: string; markdown: boolean }) {
  const app = useApp();
  const f = useFile(app, path);
  const [source, setSource] = useState(false);
  const dirty = f.draft !== null && f.draft !== f.file?.text;
  const text = f.draft ?? f.file?.text ?? "";
  // ⌘S saves (the page keeps ⌘S from the browser while a file tab shows)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((IS_MAC ? e.metaKey : e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        f.save();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const name = path.slice(path.lastIndexOf("/") + 1);
  return (
    <div class="file-tab">
      <div class="ch-file-bar">
        <Icon name="file" size={14} class="muted" />
        <span class="ch-path" title={path}>{name}{dirty ? " •" : ""}</span>
        <span class="spacer" />
        {markdown ? (
          <button type="button" class="btn small" onClick={() => setSource(!source)}>{source ? "Preview" : "Source"}</button>
        ) : null}
        {dirty ? <button type="button" class="btn small" onClick={() => f.setDraft(null)}>Revert</button> : null}
        <button type="button" class="btn small primary" disabled={!dirty} title={`Save (${IS_MAC ? "⌘S" : "Ctrl+S"})`} onClick={() => f.save()}>Save</button>
      </div>
      {f.changed ? (
        <div class="ch-notice err">
          <span>The file changed on disk{dirty ? " while you edited it" : ""}.</span>
          <span class="spacer" />
          <button type="button" class="btn small" onClick={f.reload}>Reload</button>
          {dirty ? <button type="button" class="btn small danger" onClick={() => f.save(true)}>Save anyway</button> : null}
        </div>
      ) : null}
      {f.err && !f.file ? (
        <div class="ch-msg"><div>{f.err}</div><div class="muted-text small">{path}</div></div>
      ) : !f.file ? (
        <div class="ch-msg muted-text">Reading…</div>
      ) : markdown && !source ? (
        <MarkdownView app={app} text={text} path={path} />
      ) : (
        <CodeEdit key={tab.id + ":" + path} text={text} onEdit={(t) => f.setDraft(t)} />
      )}
    </div>
  );
}

// Text with line numbers: a gutter beside a textarea, scrolled together.
function CodeEdit({ text, onEdit }: { text: string; onEdit: (t: string) => void }) {
  const gutter = useRef<HTMLDivElement>(null);
  const lines = text.split("\n").length;
  const nums = useRef("");
  if (nums.current.split("\n").length !== lines) nums.current = Array.from({ length: lines }, (_, i) => i + 1).join("\n");
  return (
    <div class="code-edit">
      <div class="code-gutter" ref={gutter} aria-hidden="true">{nums.current}</div>
      <textarea
        class="code-text"
        value={text}
        spellcheck={false}
        autocomplete="off"
        autocapitalize="off"
        wrap="off"
        onInput={(e) => onEdit((e.target as HTMLTextAreaElement).value)}
        onScroll={(e) => {
          if (gutter.current) gutter.current.scrollTop = (e.target as HTMLTextAreaElement).scrollTop;
        }}
        onKeyDown={(e) => {
          if (e.key === "Tab" && !e.metaKey && !e.ctrlKey) {
            e.preventDefault();
            const t = e.target as HTMLTextAreaElement;
            t.setRangeText("\t", t.selectionStart, t.selectionEnd, "end");
            onEdit(t.value);
          }
        }}
      />
    </div>
  );
}

// ---- Markdown ----

function MarkdownView({ app, text, path }: { app: App; text: string; path: string }) {
  const doc = useRef<{ text: string; blocks: Block[] }>({ text: "", blocks: [] });
  if (doc.current.text !== text || !doc.current.blocks.length) doc.current = { text, blocks: parseMarkdown(text) };
  const box = useRef<HTMLDivElement>(null);
  const dir = path.slice(0, path.lastIndexOf("/"));
  const follow = (href: string) => {
    if (href.startsWith("#")) {
      box.current?.querySelector(`[id="${CSS.escape(href.slice(1))}"]`)?.scrollIntoView({ block: "start" });
    } else if (/^(https?:|mailto:)/i.test(href)) {
      app.setOverlay({ link: href });
    } else {
      // a relative file: opened as the window does (inside a project; refusals as a toast)
      const [file, anchor] = href.split("#");
      const parts = (dir + "/" + decodeURIComponent(file)).split("/");
      const out: string[] = [];
      for (const p of parts) p === ".." ? out.pop() : p && p !== "." ? out.push(p) : null;
      app.run({ type: "show_file", path: "/" + out.join("/"), ...(anchor ? { anchor } : {}) });
    }
  };
  return (
    <div class="md-doc" ref={box}>
      <div class="md-body">{doc.current.blocks.map((b) => block(b, follow))}</div>
    </div>
  );
}

function block(b: Block, follow: (h: string) => void): ComponentChildren {
  const il = (c: Inline[]) => c.map((x) => inline(x, follow));
  switch (b.t) {
    case "h": {
      const H = `h${b.level}` as "h1";
      return <H id={b.id}>{il(b.c)}</H>;
    }
    case "p":
      return <p>{il(b.c)}</p>;
    case "code":
      return <pre class="md-code"><code>{b.s}</code></pre>;
    case "html":
      return <pre class="md-code md-html">{b.s}</pre>;
    case "quote":
      return <blockquote>{b.c.map((x) => block(x, follow))}</blockquote>;
    case "hr":
      return <hr />;
    case "list": {
      const items = b.items.map((it) => (
        <li class={it.task !== null ? "task" : ""}>
          {it.task !== null ? <input type="checkbox" checked={it.task} disabled /> : null}
          {it.c.length === 1 && it.c[0].t === "p" ? il(it.c[0].c) : it.c.map((x) => block(x, follow))}
        </li>
      ));
      return b.ordered ? <ol start={b.start}>{items}</ol> : <ul>{items}</ul>;
    }
    case "table":
      return (
        <div class="md-table">
          <table>
            <thead><tr>{b.head.map((h, k) => <th style={b.align[k] ? { textAlign: b.align[k] } : undefined}>{il(h)}</th>)}</tr></thead>
            <tbody>{b.rows.map((r) => <tr>{r.map((c, k) => <td style={b.align[k] ? { textAlign: b.align[k] } : undefined}>{il(c)}</td>)}</tr>)}</tbody>
          </table>
        </div>
      );
  }
}

function inline(x: Inline, follow: (h: string) => void): ComponentChildren {
  switch (x.t) {
    case "text": return x.s;
    case "code": return <code>{x.s}</code>;
    case "em": return <em>{x.c.map((y) => inline(y, follow))}</em>;
    case "strong": return <strong>{x.c.map((y) => inline(y, follow))}</strong>;
    case "del": return <del>{x.c.map((y) => inline(y, follow))}</del>;
    case "br": return <br />;
    case "img": return <span class="md-img">[{x.alt || "image"}]</span>;
    case "link": {
      const href = safeHref(x.href);
      if (href === null) return x.c.map((y) => inline(y, follow));
      return (
        <a href={href.startsWith("#") || /^(https?:|mailto:)/i.test(href) ? href : "#"} rel="noopener noreferrer" onClick={(e) => { e.preventDefault(); follow(href); }}>
          {x.c.map((y) => inline(y, follow))}
        </a>
      );
    }
  }
}
