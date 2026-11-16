// The Settings page (src/ui_settings_page.odin): every setting by section, with a search box, in
// the centre (desktop: the section list on its left) or as the phone's screens (the sections, then
// one section). Sections, rows, values and what a browser may change come from the core's
// "webset" section (src/core/web_settings.odin), sent while this page shows (web_settings). Each
// control sends the setting's own command; the ones a browser may not send (this Mac's user's
// only, or the window's own sheets) show their value and "Change this at the Mac".

import { useEffect, useRef, useState } from "preact/hooks";
import { useApp, wished, type App } from "./ctx.ts";
import { Icon } from "./icons.tsx";
import { IconButton } from "./Sidebar.tsx";

export interface WebSetItem {
  label: string;
  detail: string;
  button: string;
  acts: string[];
  arg: string;
  codex: boolean;
}
export interface WebSetting {
  id: string;
  section: string;
  card: string;
  label: string;
  hint: string;
  keywords: string;
  kind: "switch" | "choice" | "stepper" | "grid" | "button" | "status" | "list";
  web: boolean;
  here: boolean;
  applies: string;
  choices: { name: string; arg: string }[];
  value: any;
  show: boolean;
  button: string;
  items: WebSetItem[];
}
export interface WebSet {
  sections: { id: string; name: string; note: string; empty: string }[];
  settings: WebSetting[];
}

const AT_MAC = "Change this at the Mac";
const THIS_MAC_BADGE = "Only you, at this Mac";

// The window's lines under each section's title (ui_settings_page.odin SP_SECTION_WHY).
const WHY: Record<string, string> = {
  appearance: "Applies at once, to this window.",
  notifications: "What reaches you from sessions you are not looking at.",
  agents: "What is installed, and how Deckhand starts each one. Deckhand never edits these agents' own config: it opens their files for you.",
  machines: "Other machines' sessions, over your own ssh.",
  folders: "Where Deckhand keeps its own files.",
};

// The notifications grid's rows (ui_toolbar.odin BELL_GRID_LABELS).
const BELL_LABELS: Record<string, string> = { waiting: "Needs you", finished: "Finished", errors: "Errors", jobs: "Jobs" };

// A setting's command and its argument (command_table.odin), for the ones a browser may change.
const CHOICE_ARG: Record<string, [string, string]> = { appearance: ["set_appearance", "mode"], look: ["set_theme", "name"], text_size: ["set_text_size", "size"] };
const SWITCH_CMD: Record<string, (on: boolean) => object> = {
  reduce_motion: (on) => ({ type: "set_reduce_motion", on }),
  dim_panes: (on) => ({ type: "set_dim_panes", on }),
  agent_notify: (on) => ({ type: "set_notify", on }),
  keep_sessions: (on) => ({ type: "set_keep_sessions", on }),
  separate_core: (on) => ({ type: "set_separate_core", on }),
  tidy_projects: (on) => ({ type: "set_tidy_projects", on }),
  update_checks: (on) => ({ type: "set_update_check", on }),
};
const BUTTON_CMD: Record<string, object> = {
  rescan: { type: "rescan" },
  refresh_shell_env: { type: "refresh_shell_env" },
  reload_all_pi: { type: "pi_reload_all" },
  restart_all_claude: { type: "claude_restart_changed", all: true },
  atlas_model: { type: "agent_model_picker" },
};

export function webSet(app: App): WebSet | null {
  const s = app.store.sections.get("webset");
  return s && Array.isArray(s.settings) ? s : null;
}

// While the page shows, the core sends it webset (and again after the link came back).
function useWebSettings(app: App) {
  const up = app.link.up;
  useEffect(() => {
    if (!up) return;
    app.link.run({ type: "web_settings", open: true });
    return () => {
      if (app.link.up) app.link.run({ type: "web_settings", open: false });
    };
  }, [up]);
}

// ---- search: every word in one of the fields (settings_registry.odin settings_match) ----

function matchScore(words: string[], fields: string[]): number {
  const low = fields.map((f) => f.toLowerCase());
  let score = 0;
  for (const w of words) {
    const lw = w.toLowerCase();
    let best = -1;
    low.forEach((f, i) => {
      const at = f.indexOf(lw);
      if (at < 0) return;
      const s = (i === 0 ? 40 : i === 1 ? 20 : 10) + (at === 0 || !/[a-z0-9\u0080-￿]/.test(f[at - 1]) ? 10 : 0);
      best = Math.max(best, s);
    });
    if (best < 0) return -1;
    score += best;
  }
  return score;
}

export interface Hit {
  s: WebSetting;
  item?: WebSetItem; // a list's row (its whole setting is not a hit)
  score: number;
  order: number;
}

export function searchSettings(set: WebSet, query: string): Hit[] {
  const words = query.split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const secName = (id: string) => set.sections.find((x) => x.id === id)?.name ?? "";
  const out: Hit[] = [];
  set.settings.forEach((s, i) => {
    if (!s.show) return;
    const sc = matchScore(words, [s.label, s.keywords, s.hint, s.choices.map((c) => c.name).join(" "), s.card, secName(s.section)]);
    if (sc >= 0) {
      out.push({ s, score: sc, order: i });
      return;
    }
    s.items.forEach((it, k) => {
      const r = matchScore(words, [it.label, it.detail, s.label + " " + s.keywords]);
      if (r >= 0) out.push({ s, item: it, score: r, order: set.settings.length + i * 100 + k });
    });
  });
  return out.sort((a, b) => b.score - a.score || a.order - b.order);
}

// ---- the page ----

export function SettingsPage({ onClose }: { onClose: () => void }) {
  const app = useApp();
  useWebSettings(app);
  const set = webSet(app);
  const [section, setSection] = useState("appearance");
  const [query, setQuery] = useState("");
  const [phoneSection, setPhoneSection] = useState<string | null>(null);
  const body = useRef<HTMLDivElement>(null);
  const search = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (!app.phone) search.current?.focus();
  }, []);
  useEffect(() => {
    body.current?.scrollTo(0, 0);
  }, [section, phoneSection]);
  const onKey = (e: KeyboardEvent) => {
    if (e.key !== "Escape") return;
    if (query) setQuery("");
    else if (app.phone && phoneSection) setPhoneSection(null);
    else onClose();
    e.preventDefault();
  };
  const searchBox = (
    <label class="set-search">
      <Icon name="search" size={14} class="muted" />
      <input ref={search} type="search" placeholder="Search settings" value={query} spellcheck={false} autocomplete="off" onInput={(e) => setQuery((e.target as HTMLInputElement).value)} onKeyDown={onKey} />
    </label>
  );
  const q = query.trim();
  if (app.phone) {
    const sec = phoneSection ? set?.sections.find((s) => s.id === phoneSection) : null;
    return (
      <div class="phone-screen settings-phone" onKeyDown={onKey}>
        <header class="phone-bar">
          <IconButton icon="back" label="Back" run={() => (sec && !q ? setPhoneSection(null) : onClose())} />
          <span class="bar-title">{sec && !q ? sec.name : "Settings"}</span>
        </header>
        <div class="set-body" ref={body}>
          {searchBox}
          {!set ? (
            <p class="empty">Loading…</p>
          ) : q ? (
            <Results set={set} query={q} />
          ) : sec ? (
            <Section set={set} id={sec.id} />
          ) : (
            <div class="set-card set-nav-list">
              {set.sections.map((s) => (
                <button type="button" class="set-row set-nav-row" onClick={() => setPhoneSection(s.id)}>
                  <span class="set-label">{s.name}</span>
                  <span class="spacer" />
                  {s.note ? <span class="set-note">{s.note}</span> : null}
                  <Icon name="chevron-right" size={14} class="muted" />
                </button>
              ))}
            </div>
          )}
        </div>
      </div>
    );
  }
  return (
    <div class="settings-page" onKeyDown={onKey}>
      <nav class="set-nav" aria-label="Settings sections">
        {(set?.sections ?? []).map((s) => (
          <button type="button" class={"set-nav-item" + (s.id === section && !q ? " on" : "")} onClick={() => { setSection(s.id); setQuery(""); }}>
            <span class="set-nav-name">{s.name}</span>
            {s.note ? <span class="set-note">{s.note}</span> : null}
          </button>
        ))}
      </nav>
      <div class="set-body" ref={body}>
        <div class="set-col">
          <div class="set-top">
            {searchBox}
            <IconButton icon="close" label="Close Settings (Esc)" run={onClose} />
          </div>
          {!set ? <p class="empty">Loading…</p> : q ? <Results set={set} query={q} /> : <Section set={set} id={section} />}
        </div>
      </div>
    </div>
  );
}

function Heading({ title, why }: { title: string; why?: string }) {
  return (
    <div class="set-heading">
      <h2>{title}</h2>
      {why ? <p class="muted small">{why}</p> : null}
    </div>
  );
}

// The section's cards, as the window lays them out: its settings by card in the registry's
// order; a grid is a card of its own under its label; Machines puts "Allow other machines…"
// before Web access, as the window does.
function cardsOf(set: WebSet, id: string): { title: string; badge: string; list: WebSetting[] }[] {
  const mine = set.settings.filter((s) => s.section === id && s.show);
  const cards: { title: string; badge: string; list: WebSetting[] }[] = [];
  let last: string | null = null;
  for (const s of mine) {
    if (s.kind === "grid") {
      cards.push({ title: s.label, badge: s.here ? THIS_MAC_BADGE : "", list: [s] });
      last = null;
      continue;
    }
    if (s.card !== last || !cards.length) cards.push({ title: s.card, badge: "", list: [] });
    cards[cards.length - 1].list.push(s);
    last = s.card;
  }
  if (id === "machines") {
    const reach = cards.findIndex((c) => c.list.some((s) => s.id === "machines_reachable"));
    const web = cards.findIndex((c) => c.title === "Web access");
    if (reach > web && web >= 0) cards.splice(web, 0, cards.splice(reach, 1)[0]);
  }
  return cards;
}

function Section({ set, id }: { set: WebSet; id: string }) {
  const sec = set.sections.find((s) => s.id === id) ?? set.sections[0];
  if (!sec) return null;
  return (
    <>
      <Heading title={sec.name} why={WHY[sec.id]} />
      {sec.empty ? <p class="muted">{sec.empty}</p> : null}
      {cardsOf(set, sec.id).map((c) => (
        <Card title={c.title} badge={c.badge}>
          {c.list.map((s) => (s.kind === "grid" ? <Grid s={s} /> : <SettingRows s={s} />))}
        </Card>
      ))}
      {sec.id === "agents" || sec.id === "sessions" || sec.id === "atlas" ? <p class="muted small set-foot">Their files open in editor tabs in the Deckhand window.</p> : null}
    </>
  );
}

function Results({ set, query }: { set: WebSet; query: string }) {
  const hits = searchSettings(set, query);
  if (!hits.length) return <p class="muted">No setting matches. Esc clears the search.</p>;
  return (
    <>
      {set.sections.map((sec) => {
        const mine = hits.filter((h) => h.s.section === sec.id && (!h.item || !hits.some((x) => !x.item && x.s === h.s)));
        if (!mine.length) return null;
        return (
          <>
            <Heading title={sec.name} />
            <Card title="">
              {mine.map((h) => (h.item ? <ItemRow s={h.s} it={h.item} /> : h.s.kind === "grid" ? <Grid s={h.s} /> : <SettingRows s={h.s} />))}
            </Card>
          </>
        );
      })}
    </>
  );
}

function Card({ title, badge, children }: { title: string; badge?: string; children: any }) {
  return (
    <section class="set-card">
      {title ? (
        <div class="set-card-title">
          <span>{title.toUpperCase()}</span>
          {badge ? <Badge text={badge} /> : null}
        </div>
      ) : null}
      {children}
    </section>
  );
}

function Badge({ text }: { text: string }) {
  return <span class={"set-badge" + (text === THIS_MAC_BADGE ? " lock" : "")}>{text}</span>;
}

// A row: its label and hint on the left, its controls on the right (under them on a phone).
function Row(props: { label: string; hint?: string; badges?: string[]; mono?: boolean; atMac?: boolean; stack?: boolean; children?: any }) {
  return (
    <div class={"set-row" + (props.stack ? " stack" : "")}>
      <div class="set-text">
        <div class="set-label">{props.label}</div>
        {props.hint ? <div class={"set-hint" + (props.mono ? " mono" : "")}>{props.hint}</div> : null}
        {props.atMac ? <div class="set-hint at-mac">{AT_MAC}</div> : null}
      </div>
      <div class="set-controls">
        {(props.badges ?? []).filter(Boolean).map((b) => (
          <Badge text={b} />
        ))}
        {props.children}
      </div>
    </div>
  );
}

function badgesOf(s: WebSetting): string[] {
  return [s.applies, s.here ? THIS_MAC_BADGE : ""];
}

function Switch({ on, disabled, label, run }: { on: boolean; disabled?: boolean; label: string; run?: () => void }) {
  return <button type="button" role="switch" aria-checked={on} aria-label={label} class={"switch" + (on ? " on" : "")} disabled={disabled} onClick={run} />;
}

// What a field row asks for (Change…, Rename…, Add…): its title and placeholder, and what Save sends.
interface Edit {
  key: string;
  title: string;
  placeholder: string;
  text: string;
  save: (text: string) => object | null;
}

function useEdit() {
  const [edit, setEdit] = useState<Edit | null>(null);
  return { edit, setEdit };
}

function EditRow({ e, done }: { e: Edit; done: () => void }) {
  const app = useApp();
  const [v, setV] = useState(e.text);
  const [err, setErr] = useState("");
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => {
    field.current?.focus();
    field.current?.select();
  }, []);
  const save = async () => {
    const cmd = e.save(v.trim());
    if (!cmd) return done();
    const r = await app.link.run(cmd);
    if (r.ok) done();
    else setErr(r.error || "That did not work");
  };
  return (
    <form
      class="set-row stack set-edit"
      onSubmit={(ev) => {
        ev.preventDefault();
        save();
      }}
    >
      <div class="set-text">
        <div class="set-label">{e.title}</div>
        {err ? <div class="set-hint error-ink">{err}</div> : null}
      </div>
      <div class="set-controls">
        <input
          ref={field}
          class="field set-field"
          type="text"
          value={v}
          placeholder={e.placeholder}
          spellcheck={false}
          autocomplete="off"
          autocapitalize="off"
          onInput={(ev) => setV((ev.target as HTMLInputElement).value)}
          onKeyDown={(ev) => {
            if (ev.key === "Escape") {
              ev.stopPropagation();
              done();
            }
          }}
        />
        <button type="submit" class="btn small primary">
          Save
        </button>
        <button type="button" class="btn small" onClick={done}>
          Cancel
        </button>
      </div>
    </form>
  );
}

function SettingRows({ s }: { s: WebSetting }) {
  const app = useApp();
  const { edit, setEdit } = useEdit();
  const label = s.label.replace(/…$/, "");
  const atMac = !s.web;
  switch (s.kind) {
    case "switch": {
      const on = !!wished("set:" + s.id, s.value);
      const make = SWITCH_CMD[s.id];
      const can = s.web && !!make;
      return (
        <Row label={label} hint={s.hint} badges={badgesOf(s)} atMac={!can}>
          {s.id === "update_checks" && s.web ? (
            <button type="button" class="btn small" onClick={() => app.run({ type: "update_check" })}>
              Check now
            </button>
          ) : null}
          <Switch
            on={on}
            disabled={!can}
            label={label}
            run={() => {
              app.wish("set:" + s.id, !on);
              app.run(make(!on));
            }}
          />
        </Row>
      );
    }
    case "choice": {
      const v = String(wished("set:" + s.id, s.value));
      const [type, arg] = CHOICE_ARG[s.id] ?? ["", ""];
      const name = s.choices.find((c) => c.arg === v)?.name ?? "";
      return (
        <Row label={label} hint={s.id === "look" && name ? `${name} · ${s.hint}` : s.hint} badges={badgesOf(s)} atMac={atMac || !type}>
          <div class="segmented set-seg" role="radiogroup" aria-label={label}>
            {s.choices.map((c) => (
              <button
                type="button"
                role="radio"
                aria-checked={c.arg === v}
                class={c.arg === v ? "on" : ""}
                disabled={atMac || !type}
                onClick={() => {
                  app.wish("set:" + s.id, c.arg);
                  app.run({ type, [arg]: c.arg });
                }}
              >
                {s.id === "look" ? <span class={"swatch look-" + c.arg} /> : null}
                {c.name}
              </button>
            ))}
          </div>
        </Row>
      );
    }
    case "stepper": {
      const pt = Number(wished("set:" + s.id, s.value)) || 0;
      const shown = pt || 14;
      const step = (to: number) => {
        app.wish("set:" + s.id, to);
        app.run({ type: "set_terminal_text_size", pt: to });
      };
      return (
        <Row label={label} hint={s.hint.replace(/^Also .*/, "Also ⌘+, ⌘− and ⌘0 in the window")} badges={badgesOf(s)} atMac={atMac}>
          <button type="button" class="btn small" aria-label="Smaller" disabled={atMac || shown <= 9} onClick={() => step(shown - 1)}>
            −
          </button>
          <span class="set-value mono">{shown} pt</span>
          <button type="button" class="btn small" aria-label="Bigger" disabled={atMac || shown >= 28} onClick={() => step(shown + 1)}>
            +
          </button>
          {pt ? (
            <button type="button" class="btn small" disabled={atMac} onClick={() => step(0)}>
              Actual size
            </button>
          ) : null}
        </Row>
      );
    }
    case "button":
      return <ButtonSetting s={s} edit={edit} setEdit={setEdit} />;
    case "status":
      return (
        <>
          {s.items.length ? s.items.map((it) => <ItemRow s={s} it={it} />) : <Row label={label} hint="Not checked yet" />}
        </>
      );
    case "list":
      if (s.id === "web_devices" && !s.items.length) return <Row label="No paired browsers" />;
      return (
        <>
          {s.id === "claude_accounts" || s.id === "codex_accounts" ? null : s.items.length || s.web ? null : <Row label={label} hint={s.hint} atMac />}
          {s.items.map((it) => (
            <ItemRow s={s} it={it} />
          ))}
        </>
      );
  }
  return null;
}

function ButtonSetting({ s, edit, setEdit }: { s: WebSetting; edit: Edit | null; setEdit: (e: Edit | null) => void }) {
  const app = useApp();
  const label = s.label.replace(/…$/, "");
  if (s.id === "main_folder") return <>{s.items.map((it) => <ItemRow s={s} it={it} />)}</>;
  let run: (() => void) | null = null;
  if (s.web) {
    if (BUTTON_CMD[s.id]) run = () => app.run(BUTTON_CMD[s.id]);
    else if (s.id === "jobs")
      run = () => {
        if (app.phone) app.go({ screen: "jobs" });
        else app.run({ type: "set_left_tab", tab: "jobs" }).then(() => app.run({ type: "set_layout", left_open: true }));
      };
    else if (s.id === "chats_dir") run = () => setEdit({ key: s.id, title: "Chats folder", placeholder: "~/Chats", text: s.value || "", save: (t) => (t ? { type: "set_folder", kind: "chats", path: t } : null) });
  }
  const sub = app.store.sections.get("webset")?.settings?.find((x: WebSetting) => x.id === "subfolders") as WebSetting | undefined;
  const chatsCustom = !!sub?.items.find((it) => it.arg === "chats" && it.acts.includes("reset"));
  return (
    <>
      <Row label={label} hint={s.hint} badges={s.id.startsWith("web_") ? [] : badgesOf(s)} mono={s.id === "chats_dir"} atMac={!run}>
        {run ? (
          <button type="button" class="btn small" onClick={run}>
            {s.button}
          </button>
        ) : (
          <button type="button" class="btn small" disabled>
            {s.button}
          </button>
        )}
        {s.id === "chats_dir" && run && chatsCustom ? (
          <button type="button" class="btn small" onClick={() => app.run({ type: "set_folder", kind: "chats", path: "" })}>
            Default
          </button>
        ) : null}
      </Row>
      {edit ? <EditRow e={edit} done={() => setEdit(null)} /> : null}
    </>
  );
}

const ACT_LABEL: Record<string, string> = { connect: "", rename: "Rename…", default: "Make default", remove: "Remove…", add: "Add…", scan: "Scan", change: "Change…", reset: "Reset" };

// A list's row (a machine, an account, a folder, a coding agent's item): what it says, and the
// buttons a browser may use on it; the rest show what the window offers, at the Mac.
function ItemRow({ s, it }: { s: WebSetting; it: WebSetItem }) {
  const app = useApp();
  const [edit, setEdit] = useState<Edit | null>(null);
  const harness = it.codex ? { harness: "codex" } : {};
  const act = (a: string) => {
    switch (a) {
      case "connect":
        return app.run({ type: "machine_connect", no: Number(it.arg) });
      case "rename":
        return setEdit({ key: a, title: "Rename the account", placeholder: "", text: it.label, save: (t) => (t ? { type: "rename_claude_account", account: it.arg, label: t, ...harness } : null) });
      case "default":
        return app.run({ type: "set_claude_account_default", account: it.arg, ...harness });
      case "remove":
        return app.run({ type: "remove_claude_account", account: it.arg, ...harness });
      case "add":
        return setEdit({ key: a, title: it.codex ? "Add a Codex home" : "Add a Claude Code config folder", placeholder: it.codex ? "~/.codex-work" : "~/.claude-work", text: "", save: (t) => (t ? { type: "add_claude_account", dir: t, ...harness } : null) });
      case "scan":
        return app.run({ type: "rescan" });
      case "change":
        return setEdit({
          key: a,
          title: it.arg ? `Change ${it.label}` : "Main folder",
          placeholder: it.arg ? "a folder (empty: the default)" : "~/Notes",
          text: it.detail.replace(/^(custom|default) · /, ""),
          save: (t) => (it.arg ? { type: "set_folder", kind: it.arg, path: t } : t ? { type: "set_home_dir", path: t } : null),
        });
      case "reset":
        return app.run({ type: "set_folder", kind: it.arg, path: "" });
    }
  };
  const acts = s.web ? it.acts : it.acts.filter((a) => a === "connect");
  // the window's button that a browser cannot use here (Log in…, Install…, Revoke, Copy…)
  const shown = new Set(acts.map((a) => (a === "connect" ? it.button : ACT_LABEL[a])));
  const atMac = !!it.button && !shown.has(it.button) && !(it.button === "Rename…" && acts.includes("rename"));
  const mono = s.id === "subfolders" || s.id === "main_folder";
  return (
    <>
      <Row label={it.label} hint={it.detail} mono={mono} atMac={atMac} stack={acts.length >= 2}>
        {acts.map((a) => (
          <button type="button" class={"btn small" + (a === "connect" ? " primary" : "")} onClick={() => act(a)}>
            {a === "connect" ? it.button : ACT_LABEL[a]}
          </button>
        ))}
        {atMac ? (
          <button type="button" class="btn small" disabled title={AT_MAC}>
            {it.button}
          </button>
        ) : null}
      </Row>
      {edit ? <EditRow e={edit} done={() => setEdit(null)} /> : null}
    </>
  );
}

// The notifications grid (Bell, macOS, Sound per kind): this Mac's user's, so shown as it is.
function Grid({ s }: { s: WebSetting }) {
  const rows: { group: string; bell: boolean; macos: string; sound: string }[] = Array.isArray(s.value) ? s.value : [];
  return (
    <div class="set-grid" role="table" aria-label={s.label}>
      <div class="set-grid-row head" role="row">
        <span role="columnheader" />
        <span role="columnheader">Bell</span>
        <span role="columnheader">macOS</span>
        <span role="columnheader">Sound</span>
      </div>
      {rows.map((r) => (
        <div class="set-grid-row" role="row">
          <span role="cell" class="set-label">{BELL_LABELS[r.group] ?? r.group}</span>
          <span role="cell">
            <Switch on={r.bell} disabled label={`${BELL_LABELS[r.group] ?? r.group}: the bell`} />
          </span>
          <span role="cell" class={"set-chip" + (r.macos !== "never" ? " on" : "")}>{r.macos}</span>
          <span role="cell" class={"set-chip" + (r.sound !== "none" ? " on" : "")}>{r.sound}</span>
        </div>
      ))}
      {!s.web ? <div class="set-hint at-mac set-grid-note">{AT_MAC}</div> : null}
    </div>
  );
}
