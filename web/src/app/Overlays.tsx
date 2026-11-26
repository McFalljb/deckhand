// What floats over the page: a context menu (desktop) or bottom sheet (phone), toasts, the
// confirmation bar, a link waiting for a tap, text to copy, and the small text prompts (add a
// project, rename). The palette and the bell are their own files.

import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { useApp, type MenuItem, type ToastAction } from "./ctx.ts";
import { Icon } from "./icons.tsx";

export function Menu() {
  const app = useApp();
  const m = app.overlay.menu;
  const box = useRef<HTMLDivElement>(null);
  const [sel, setSel] = useState(-1);
  useLayoutEffect(() => {
    if (!m || !box.current) return;
    const r = box.current.getBoundingClientRect();
    const x = Math.min(m.x, window.innerWidth - r.width - 8);
    const y = m.y + r.height > window.innerHeight - 8 ? Math.max(8, m.y - r.height) : m.y;
    box.current.style.left = Math.max(8, x) + "px";
    box.current.style.top = y + "px";
    setSel(-1);
  }, [m]);
  useEffect(() => {
    if (!m) return;
    const runnable = m.items.map((it, i) => (it.run && !it.sep ? i : -1)).filter((i) => i >= 0);
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") app.setOverlay({ menu: null });
      else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        const at = runnable.indexOf(sel);
        const next = e.key === "ArrowDown" ? runnable[(at + 1) % runnable.length] : runnable[(at - 1 + runnable.length) % runnable.length];
        setSel(next ?? -1);
      } else if (e.key === "Enter" && sel >= 0) {
        app.setOverlay({ menu: null });
        m.items[sel].run?.();
      } else return;
      e.preventDefault();
      e.stopPropagation();
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  }, [m, sel]);
  if (!m) return null;
  return (
    <div class="scrim clear" onMouseDown={() => app.setOverlay({ menu: null })} onContextMenu={(e) => { e.preventDefault(); app.setOverlay({ menu: null }); }}>
      <div class="menu" ref={box} role="menu" onMouseDown={(e) => e.stopPropagation()}>
        <MenuRows items={m.items} sel={sel} done={() => app.setOverlay({ menu: null })} />
      </div>
    </div>
  );
}

function MenuRows({ items, sel, done }: { items: MenuItem[]; sel?: number; done: () => void }) {
  return (
    <>
      {items.map((it, i) =>
        it.sep ? (
          <div class="menu-sep" />
        ) : it.note ? (
          <div class="menu-note">{it.label}</div>
        ) : (
          <button
            type="button"
            role="menuitem"
            class={"menu-item" + (i === sel ? " sel" : "") + (it.danger ? " danger" : "")}
            onClick={() => {
              done();
              it.run?.();
            }}
          >
            <span class="menu-check">{it.check ? <Icon name="check" size={14} /> : null}</span>
            <span class="menu-label">{it.label}</span>
            {it.keys ? <span class="keys">{it.keys}</span> : null}
          </button>
        ),
      )}
    </>
  );
}

export function Sheet() {
  const app = useApp();
  const s = app.overlay.sheet;
  if (!s) return null;
  const close = () => app.setOverlay({ sheet: null });
  const prompt = s.items[0]?.label?.startsWith("prompt:") ? s.items[0].label.slice(7) : "";
  return (
    <div class="scrim" onMouseDown={close}>
      <div class={"sheet" + (app.phone ? " bottom" : "")} role="dialog" aria-label={s.title || "Menu"} onMouseDown={(e) => e.stopPropagation()}>
        {s.title ? <div class="sheet-title">{s.title}</div> : null}
        {prompt ? <Prompt what={prompt} body={s.body ?? ""} done={close} /> : (
          <>
            {s.body ? <p class="muted small sheet-body">{s.body}</p> : null}
            <div class="sheet-items">
              <MenuRows items={s.items} done={close} />
            </div>
          </>
        )}
        {!prompt ? (
          <button type="button" class="btn wide sheet-cancel" onClick={close}>
            Cancel
          </button>
        ) : null}
      </div>
    </div>
  );
}

// add_project: a path; rename_project:<id>: a name; claude_rename:<session id>: a Claude session's title.
function Prompt({ what, body, done }: { what: string; body: string; done: () => void }) {
  const app = useApp();
  const [kind, id] = what.split(":");
  const [v, setV] = useState(kind === "rename_project" || kind === "claude_rename" ? body : "");
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => field.current?.focus(), []);
  const go = async () => {
    const text = v.trim();
    if (kind === "add_project") {
      if (!text) return;
      const r = await app.run({ type: "add_project", cwd: text });
      if (r.ok) done();
    } else if (kind === "rename_project") {
      const r = await app.run({ type: "rename_project", project_id: Number(id), name: text });
      if (r.ok) done();
    } else if (kind === "claude_rename") {
      const r = await app.run({ type: "claude_rename", claude_session_id: id, title: text });
      if (r.ok) done();
    }
  };
  return (
    <form
      class="prompt"
      onSubmit={(e) => {
        e.preventDefault();
        go();
      }}
    >
      {kind === "add_project" ? <p class="muted small">{body}</p> : null}
      <input
        ref={field}
        class="field"
        type="text"
        value={v}
        spellcheck={false}
        autocomplete="off"
        autocapitalize="off"
        placeholder={kind === "add_project" ? "~/code/my-project" : kind === "claude_rename" ? "Title (empty: Claude's own)" : "Name (empty: the folder's)"}
        onInput={(e) => setV((e.target as HTMLInputElement).value)}
        onKeyDown={(e) => e.key === "Escape" && done()}
      />
      <div class="prompt-actions">
        <button type="button" class="btn" onClick={done}>
          Cancel
        </button>
        <button type="submit" class="btn primary">
          {kind === "add_project" ? "Add" : "Rename"}
        </button>
      </div>
    </form>
  );
}

export interface ToastItem {
  id: number;
  text: string;
  err: boolean;
  action?: ToastAction;
}

export function Toasts({ items }: { items: ToastItem[] }) {
  return (
    <div class="toasts" role="status" aria-live="polite">
      {items.map((t) => (
        <div class={"toast" + (t.err ? " err" : "") + (t.action ? " has-act" : "")} key={t.id}>
          {t.action ? <span class="toast-text">{t.text}</span> : t.text}
          {t.action ? <button type="button" class="btn small toast-act" onClick={t.action.run}>{t.action.label}</button> : null}
        </div>
      ))}
    </div>
  );
}

// The oldest confirmation waiting for the user (another caller's command that asks first).
export function ConfirmBar() {
  const app = useApp();
  const list = app.store.confirmations;
  const c = list[0];
  if (!c) return null;
  const more = list.length > 1 ? ` (+${list.length - 1})` : "";
  const token = c.token;
  return (
    <div class="confirm-bar" role="alertdialog" aria-label="Confirm">
      <Icon name="alert" size={16} class="waiting-ink" />
      <div class="confirm-text">{c.summary + more}</div>
      <button type="button" class="btn" onClick={() => app.run({ type: "cancel_confirmation", token })}>
        Cancel
      </button>
      <button
        type="button"
        class="btn primary"
        onClick={() => {
          // never confirm what replaced the one the user read
          if (app.store.confirmations[0]?.token !== token) return;
          if (!c.command || typeof c.command !== "object") {
            app.toast("This needs a newer page to confirm: cancel it, or confirm it at the Mac", true);
            return;
          }
          const cmd = c.command as { type?: string };
          // its answer (errors as the core words them: app.run's toast); a file command done: the
          // Files tree looks again
          app.run({ ...c.command, confirm: token }).then((r) => {
            // detail: the token and answer (the Files tree's own delete gets its Undo: fileundo.ts)
            if (cmd.type === "delete_path" || cmd.type === "rename_path") window.dispatchEvent(new CustomEvent("deckhand:fs-changed", { detail: { token, result: r } }));
          });
        }}
      >
        Confirm
      </button>
    </div>
  );
}

// A link from a terminal: shown, opened only on a tap (a program printed it, not the user).
export function LinkSheet() {
  const app = useApp();
  const url = app.overlay.link;
  if (!url) return null;
  const close = () => app.setOverlay({ link: null });
  let safe = "";
  try {
    const u = new URL(url);
    if (u.protocol === "http:" || u.protocol === "https:") safe = u.href;
  } catch {
    /* not a URL */
  }
  return (
    <div class="scrim" onMouseDown={close}>
      <div class={"sheet" + (app.phone ? " bottom" : "")} onMouseDown={(e) => e.stopPropagation()}>
        <div class="sheet-title">Open this link?</div>
        <p class="sheet-url">{url}</p>
        <div class="prompt-actions">
          <button type="button" class="btn" onClick={() => { close(); app.setOverlay({ copy: url }); }}>
            Copy
          </button>
          {safe ? (
            <a class="btn primary" href={safe} target="_blank" rel="noopener noreferrer" onClick={close}>
              Open
            </a>
          ) : null}
        </div>
      </div>
    </div>
  );
}

// No async clipboard on a page that is not a secure context: the text, selected, with a Copy
// button (execCommand works on a tap); it can always be copied by hand.
export function CopySheet() {
  const app = useApp();
  const text = app.overlay.copy;
  const area = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    area.current?.select();
  }, [text]);
  if (text === null) return null;
  const close = () => app.setOverlay({ copy: null });
  return (
    <div class="scrim" onMouseDown={close}>
      <div class={"sheet" + (app.phone ? " bottom" : "")} onMouseDown={(e) => e.stopPropagation()}>
        <div class="sheet-title">Copy</div>
        <textarea ref={area} class="field copy-area" readOnly value={text} rows={6} />
        <div class="prompt-actions">
          <button type="button" class="btn" onClick={close}>
            Close
          </button>
          <button
            type="button"
            class="btn primary"
            onClick={() => {
              const done = () => {
                app.toast("Copied");
                close();
              };
              if (navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(text).then(done, () => app.toast("Select the text and copy it by hand", true));
                return;
              }
              area.current?.select();
              if (document.execCommand("copy")) done();
              else app.toast("Select the text and copy it by hand", true);
            }}
          >
            Copy
          </button>
        </div>
      </div>
    </div>
  );
}
