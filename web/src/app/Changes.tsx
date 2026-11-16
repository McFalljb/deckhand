// The Changes tab (src/ui_changes.odin): a header (the branch against the default branch,
// Refresh, Ask pi to review), the commit row, the last action's outcome; below, the file list
// (scope and status headers, rows with the status letter, the name, +/- counts and a staged
// dot) and the selected file's bar (↑ ↓, its path, Stage, Unstage, Discard…) over its diff.
// The core keeps the tab's view for a browser (src/core/web_changes.odin): the list and the
// selection in webchg:<tab>, the diff in webdiff:<tab>. Selecting is changes_select; the actions
// are the window's own commands (Discard asks in the confirmation bar).

import { useEffect, useRef, useState } from "preact/hooks";
import type { OpenSession, Tab } from "../state.ts";
import { useApp, wished, type App } from "./ctx.ts";
import { Icon } from "./icons.tsx";
import { reviewPrompt } from "./review.ts";

interface ChangeFile {
  path: string;
  old_path?: string;
  status: string; // M A D R U untracked
  scope: "uncommitted" | "committed";
  staged?: "none" | "partly" | "all";
  added?: number;
  removed?: number;
  binary?: boolean;
  credential?: boolean;
}
interface ChangesList {
  root: string;
  loading: boolean;
  branch: string;
  default_branch: string;
  ahead: number;
  truncated?: boolean;
  error?: string;
  files: ChangeFile[];
}
interface ChangesSec {
  list: ChangesList | null;
  sel: { path: string; scope: string; status: string };
  busy: string;
  notice: string;
  notice_err: boolean;
}
interface DiffSec {
  path: string;
  text: string;
  lines: number;
  shown: number;
  cut: boolean;
  loading: boolean;
  msg: string;
}

const STATUS_NAME: Record<string, string> = { M: "Modified", A: "Added", D: "Deleted", R: "Renamed", U: "Conflicted", untracked: "Untracked" };
const ORDER = ["M", "A", "D", "R", "U", "untracked"];
const letter = (s: string) => (s === "untracked" ? "?" : s);

type Row = { head: string; scope?: boolean } | { file: ChangeFile };

function rows(l: ChangesList): Row[] {
  const out: Row[] = [];
  for (const scope of ["uncommitted", "committed"] as const) {
    const fs = l.files.filter((f) => f.scope === scope);
    if (!fs.length) continue;
    const on = l.branch || "this commit";
    out.push({ head: scope === "uncommitted" ? `Uncommitted · ${fs.length}` : `On ${on}, not on ${l.default_branch} · ${l.ahead} ${l.ahead === 1 ? "commit" : "commits"}`, scope: true });
    for (const st of ORDER) {
      const g = fs.filter((f) => f.status === st);
      if (!g.length) continue;
      out.push({ head: `${STATUS_NAME[st]} · ${g.length}` });
      for (const f of g) out.push({ file: f });
    }
  }
  return out;
}

const same = (f: ChangeFile, sel: { path: string; scope: string; status: string }) => f.path === sel.path && f.scope === sel.scope && f.status === sel.status;

export function ChangesView({ s, tab }: { s: OpenSession; tab: Tab }) {
  const app = useApp();
  const { store } = app;
  const sec: ChangesSec | undefined = store.sections.get("webchg:" + tab.id);
  const diff: DiffSec | undefined = store.sections.get("webdiff:" + tab.id);
  const l = sec?.list;
  // the selection drawn at once, the core's confirms it
  const selKey = `chsel:${tab.id}`;
  const coreSel = sec?.sel ?? { path: "", scope: "uncommitted", status: "" };
  const sel = wished(selKey, coreSel, (a, b) => a.path === b.path && a.scope === b.scope && a.status === b.status);
  const all = l ? rows(l) : [];
  const files = all.filter((r): r is { file: ChangeFile } => "file" in r).map((r) => r.file);
  const f = files.find((x) => same(x, sel));
  const select = (x: ChangeFile) => {
    app.wish(selKey, { path: x.path, scope: x.scope, status: x.status });
    app.run({ type: "changes_select", tab_id: tab.id, path: x.path, scope: x.scope, status: x.status });
  };
  const step = (d: number) => {
    const i = files.findIndex((x) => same(x, sel));
    const n = files[Math.max(0, Math.min(files.length - 1, (i < 0 ? -1 : i) + d))];
    if (n && !same(n, sel)) select(n);
  };
  const busy = sec?.busy ?? "";
  const notice = busy || sec?.notice || "";
  const list = useRef<HTMLDivElement>(null);
  // j/k and ↑/↓ in the list
  const onKey = (e: KeyboardEvent) => {
    if (e.key === "j" || e.key === "ArrowDown") (step(1), e.preventDefault());
    else if (e.key === "k" || e.key === "ArrowUp") (step(-1), e.preventDefault());
  };
  return (
    <div class="changes">
      <div class="ch-bar">
        <Icon name="branch" size={14} class="muted" />
        <span class="ch-branch">{l ? branchText(l) : "…"}</span>
        <span class="ch-root muted-text">{l ? shortRoot(app, l.root) : ""}</span>
        <span class="spacer" />
        {l?.loading ? <span class="muted-text small">Refreshing…</span> : null}
        <button type="button" class="btn small" onClick={() => app.run({ type: "changes_select", tab_id: tab.id, refresh: true })}>Refresh</button>
        <ReviewButton s={s} list={l} />
      </div>
      <CommitRow tab={tab} busy={!!busy} />
      {notice ? (
        <div class={"ch-notice" + (sec?.notice_err && !busy ? " err" : "")}>
          <span class={"chip-dot " + (sec?.notice_err && !busy ? "error" : busy ? "running" : "done")} />
          <span>{notice}</span>
        </div>
      ) : null}
      <div class="ch-body">
        <div class="ch-list" ref={list} tabIndex={0} onKeyDown={onKey}>
          {!l || (l.loading && !l.files.length) ? (
            <Empty title="Reading the changes…" text="git status runs" />
          ) : l.error ? (
            <Empty title="Could not read the changes" text={l.error} />
          ) : !all.length ? (
            <Empty title="No changes" text={l.default_branch && l.branch !== l.default_branch ? `Nothing uncommitted, nothing ahead of ${l.default_branch}` : "Nothing uncommitted"} />
          ) : (
            all.map((r) =>
              "head" in r ? (
                <div class={"ch-head" + (r.scope ? " scope" : "")}>{r.head}</div>
              ) : (
                <FileRow f={r.file} on={same(r.file, sel)} pick={() => select(r.file)} />
              ),
            )
          )}
          {l?.truncated ? <div class="ch-head">More files than shown</div> : null}
        </div>
        <div class="ch-right">
          <div class="ch-file-bar">
            <button type="button" class="icon-btn small" title="Previous file (K)" onClick={() => step(-1)}><Icon name="arrow-up" size={14} /></button>
            <button type="button" class="icon-btn small" title="Next file (J)" onClick={() => step(1)}><Icon name="arrow-down" size={14} /></button>
            <span class="ch-path">{f ? f.path + (f.old_path ? ` ← ${f.old_path}` : "") : ""}</span>
            <span class="spacer" />
            {f && f.scope === "uncommitted" ? (
              <>
                <button type="button" class="btn small" disabled={!!busy || f.staged === "all"} title="Stage this file (git add)" onClick={() => app.run({ type: "changes_stage", tab_id: tab.id, path: f.path, status: f.status })}>Stage</button>
                <button type="button" class="btn small" disabled={!!busy || !f.staged || f.staged === "none"} title="Unstage this file" onClick={() => app.run({ type: "changes_unstage", tab_id: tab.id, path: f.path, status: f.status })}>Unstage</button>
                <button type="button" class="btn small danger" disabled={!!busy} title="Discard this file's uncommitted changes (asks first)" onClick={() => app.run({ type: "changes_discard", tab_id: tab.id, path: f.path, status: f.status })}>Discard…</button>
              </>
            ) : null}
          </div>
          <DiffView tab={tab} d={diff} sel={sel} />
        </div>
      </div>
    </div>
  );
}

function FileRow({ f, on, pick }: { f: ChangeFile; on: boolean; pick: () => void }) {
  const name = f.path.slice(f.path.lastIndexOf("/") + 1);
  const dir = f.path.slice(0, f.path.length - name.length).replace(/\/$/, "");
  return (
    <div class={"row ch-row" + (on ? " current" : "")} role="button" tabIndex={-1} onClick={pick}>
      <span class={"ch-letter st-" + (f.status === "untracked" ? "q" : f.status)}>{letter(f.status)}</span>
      <span class="title">{name}</span>
      {dir ? <span class="ch-dir">{dir}</span> : null}
      <span class="spacer" />
      {f.binary ? <span class="ch-count">bin</span> : f.added !== undefined ? <span class="ch-count add">+{f.added}</span> : null}
      {!f.binary && f.removed ? <span class="ch-count del">−{f.removed}</span> : null}
      {f.staged && f.staged !== "none" ? <span class={"ch-staged" + (f.staged === "partly" ? " partly" : "")} title={f.staged === "all" ? "Staged" : "Partly staged"} /> : null}
    </div>
  );
}

// The diff: hunks with their lines coloured; a message instead when there is none to show.
function DiffView({ tab, d, sel }: { tab: Tab; d?: DiffSec; sel: { path: string } }) {
  const app = useApp();
  const box = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (box.current) box.current.scrollTop = 0;
  }, [sel.path]);
  if (!d || d.path !== sel.path || (d.loading && !d.text)) return <div class="ch-diff"><div class="ch-msg muted-text">{sel.path ? "Reading the diff…" : "Pick a file on the left"}</div></div>;
  if (!d.text) return <div class="ch-diff"><div class="ch-msg"><div>{d.msg || "No content changes"}</div>{d.path ? <div class="muted-text small">{d.path}</div> : null}</div></div>;
  const lines = d.text.split("\n");
  if (lines[lines.length - 1] === "") lines.pop();
  const more = d.lines > d.shown && !d.cut;
  return (
    <div class="ch-diff" ref={box}>
      <pre class="diff-text">
        {lines.map((ln) => (
          <div class={"dl" + (ln.startsWith("@@") ? " hunk" : ln[0] === "+" ? " add" : ln[0] === "-" ? " del" : "")}>{ln || " "}</div>
        ))}
      </pre>
      {more ? (
        <button type="button" class="btn small ch-more" onClick={() => app.run({ type: "changes_select", tab_id: tab.id, more: true })}>
          Show more ({d.lines - d.shown} more lines)
        </button>
      ) : d.cut ? (
        <div class="ch-msg muted-text small">Cut here: the rest of this diff is too large to show in a browser</div>
      ) : null}
    </div>
  );
}

function CommitRow({ tab, busy }: { tab: Tab; busy: boolean }) {
  const app = useApp();
  const [msg, setMsg] = useState("");
  const commit = async () => {
    if (!msg.trim() || busy) return;
    const r = await app.run({ type: "changes_commit", tab_id: tab.id, message: msg });
    if (r.ok) setMsg("");
  };
  return (
    <div class="ch-commit">
      <input
        type="text"
        class="field"
        placeholder="Commit message for the staged files"
        value={msg}
        spellcheck={false}
        onInput={(e) => setMsg((e.target as HTMLInputElement).value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") (e.preventDefault(), commit());
          if (e.key === "Escape") (e.target as HTMLInputElement).blur();
        }}
      />
      <button type="button" class="btn small primary" disabled={busy || !msg.trim()} title="Commit the staged files (your git hooks run)" onClick={commit}>
        Commit
      </button>
    </div>
  );
}

// "Ask pi to review" (the session's pi, or its Claude): the window's prompt, as it sends it.
function ReviewButton({ s, list }: { s: OpenSession; list: ChangesList | null | undefined }) {
  const app = useApp();
  const tabs = app.store.tabs(s.id);
  const claude = s.agent === "claude";
  const main = claude ? tabs[0] : tabs.find((t) => t.kind && "pi_tab" in t.kind);
  const word = claude ? (main?.kind?.claude_tab?.codex ? "Codex" : "Claude") : "pi";
  let why = "";
  if (!main || main.status !== "running") why = `this session's ${word} is not running`;
  else if (!claude && main.waiting) why = "pi is waiting for you";
  return (
    <button
      type="button"
      class="btn small"
      disabled={!!why || !list}
      title={why || `Ask this session's ${word} to review these changes`}
      onClick={() => {
        if (!main || !list) return;
        app.run({ type: claude ? "claude_prompt" : "pi_prompt", tab_id: main.id, text: reviewPrompt(list) });
        app.toast(`Asked ${word} to review`);
      }}
    >
      Ask {word} to review
    </button>
  );
}

// src/ui_changes.odin branch_text
function branchText(l: ChangesList): string {
  const b = l.branch || "detached HEAD";
  if (!l.default_branch || l.branch === l.default_branch) return b;
  if (l.ahead > 0) return `${b} → ${l.default_branch} · ${l.ahead} ${l.ahead === 1 ? "commit" : "commits"} ahead`;
  return `${b} → ${l.default_branch}`;
}

// The checkout's folder as the window shows it (~/…): the home folder from a project's label.
function shortRoot(app: App, root: string): string {
  for (const p of app.store.projects) {
    if (!p.label?.startsWith("~/") || !p.cwd.endsWith(p.label.slice(1))) continue;
    const home = p.cwd.slice(0, p.cwd.length - p.label.length + 1);
    if (root.startsWith(home + "/")) return "~" + root.slice(home.length);
  }
  return root;
}

function Empty({ title, text }: { title: string; text: string }) {
  return (
    <div class="empty-state">
      <div>{title}</div>
      <div class="muted small">{text}</div>
    </div>
  );
}
