// The job sheet (src/ui_job_sheet.odin): New job and Edit job as a form that writes the job's
// note. The core reads the note into the form, writes the form into the note and checks it
// (job_draft: src/core/web_jobs.odin, the window's own procs), so the preview, the next run and
// every message are the window's. Create and Save are job_save, as the window's sheet sends them.
//
//   desktop: the form on the left, the note it will write on the right (read-only, live)
//   phone:   one column, with a Form | Note toggle
//
// "Edit as note" turns the sheet into the note's text, editable; "Back to form" reads it into the
// form again (it stays a note while the text does not read). Esc or Cancel closes it and changes
// nothing; with changes it asks first ("Discard your changes?").

import { useEffect, useRef, useState } from "preact/hooks";
import { useApp } from "./ctx.ts";
import { Icon } from "./icons.tsx";

interface Form {
  name: string;
  for_project: string;
  folder: string;
  preset: string;
  every_n: string;
  at: string;
  custom: string;
  prompt: string;
  access: string;
  notify: string;
  model: string;
  hours: string;
  max_cost: string;
  timeout: string;
  max_turns: string;
}
interface Owner {
  label: string;
  value: string;
  folder: string;
}
interface Opened {
  path: string;
  shown: string; // the path as the window shows it (~/…)
  text: string;
  based_on: string;
  id: string;
  date: string;
}

const PRESETS: [string, string][] = [
  ["manual", "Manual"],
  ["hourly", "Hourly"],
  ["every_hours", "Every N hours"],
  ["daily", "Daily"],
  ["weekdays", "Weekdays"],
  ["custom", "Custom"],
];
const ACCESS: [string, string][] = [
  ["read", "Read (look only)"],
  ["full", "Full (pi's tools)"],
];
const NOTIFY = ["always", "attention", "never"];
const HINTS: Record<string, string> = {
  name: "Morning PR triage",
  every_n: "2",
  at: "07:00",
  custom: `cron "0 7 * * 1-5", "every 30m" or "at 2026-11-03 09:00"`,
  prompt: "What should pi do, and what should its summary say?",
  model: "provider/id (default: Atlas's model)",
  hours: `"07-22": only start in these hours`,
  max_cost: "0.50 (USD per run)",
  timeout: "20m",
  max_turns: "40",
};
const ADVANCED: [keyof Form, string][] = [
  ["model", "Model"],
  ["hours", "Hours"],
  ["max_cost", "Max cost"],
  ["timeout", "Timeout"],
  ["max_turns", "Max turns"],
];
const STALE = "the note changed on disk since you opened it";

export function JobSheet() {
  const app = useApp();
  const want = app.overlay.job!;
  const [opened, setOpened] = useState<Opened | null>(null);
  const [form, setForm] = useState<Form | null>(null);
  const [owners, setOwners] = useState<Owner[]>([]);
  const [noteMode, setNoteMode] = useState(false);
  const [noteText, setNoteText] = useState("");
  const [showNote, setShowNote] = useState(false);
  const [advanced, setAdvanced] = useState(false);
  const [preview, setPreview] = useState({ text: "", err: "", next: "", next_ok: true });
  const [noteErr, setNoteErr] = useState("");
  const [err, setErr] = useState("");
  const [discard, setDiscard] = useState(false);
  const [stale, setStale] = useState(false);
  const [reloadArmed, setReloadArmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const start = useRef<string | null>(null); // the note as the sheet showed it when opened
  const seq = useRef(0);
  const nameField = useRef<HTMLInputElement>(null);
  const close = () => app.setOverlay({ job: null });

  // open: the job's note read into the form, or a new one
  async function load() {
    const r = await app.link.run({ type: "job_draft", op: "open", job: want.job, for_project: want.for_project });
    if (!r.ok) {
      app.toast(r.error || "Could not open the job", true);
      close();
      return;
    }
    const d = r.data;
    setOpened({ path: d.path, shown: d.shown, text: d.text, based_on: d.based_on, id: d.id, date: d.date });
    setForm(d.form);
    setOwners(d.owners ?? []);
    setAdvanced(!!(d.form.model || d.form.hours || d.form.max_cost || d.form.timeout || d.form.max_turns));
    setNoteMode(!!d.note);
    setNoteText(d.note ? d.text : "");
    setErr(d.err || "");
    setStale(false);
    setReloadArmed(false);
    setDiscard(false);
    start.current = null;
  }
  useEffect(() => {
    load();
  }, [want.job, want.for_project]);

  // the form → the note (preview, what Save would refuse, the next run), after each change
  useEffect(() => {
    if (!opened || !form || noteMode) return;
    const n = ++seq.current;
    const t = window.setTimeout(async () => {
      const r = await app.link.run({ type: "job_draft", op: "write", ...form, base: opened.text, id: opened.id, date: opened.date, path: opened.path });
      if (n !== seq.current || !r.ok) return;
      setPreview(r.data);
      if (start.current === null) start.current = r.data.text;
    }, 80);
    return () => window.clearTimeout(t);
  }, [opened, form, noteMode]);

  // note mode: what the parser says about the text
  useEffect(() => {
    if (!opened || !noteMode) return;
    const n = ++seq.current;
    const t = window.setTimeout(async () => {
      const r = await app.link.run({ type: "job_draft", op: "read", text: noteText, path: opened.path });
      if (n !== seq.current || !r.ok) return;
      setNoteErr(r.data.err || "");
      if (start.current === null) start.current = noteText;
    }, 120);
    return () => window.clearTimeout(t);
  }, [opened, noteMode, noteText]);

  useEffect(() => {
    if (form && !noteMode && !app.phone) nameField.current?.focus();
  }, [!!form]);

  const nowText = noteMode ? noteText : preview.text;
  const changed = start.current !== null && nowText !== start.current;

  function cancel() {
    if (!discard && changed) {
      setDiscard(true);
      return;
    }
    close();
  }

  async function save() {
    if (!opened || busy) return;
    let text = noteText;
    if (!noteMode) {
      const r = await app.link.run({ type: "job_draft", op: "write", ...form, base: opened.text, id: opened.id, date: opened.date, path: opened.path });
      if (!r.ok) return setErr(r.error || "");
      if (r.data.err) return setErr(r.data.err);
      text = r.data.text;
    }
    setBusy(true);
    setErr("");
    const r = await app.link.run({ type: "job_save", path: opened.path || undefined, text, based_on: opened.path ? opened.based_on : undefined });
    setBusy(false);
    if (r.ok) {
      app.toast(opened.path ? "Job saved" : "Job created");
      close();
      return;
    }
    if (r.error === STALE) setStale(true);
    else setErr(r.error || "That did not work");
  }

  async function mode() {
    if (!noteMode) {
      setNoteText(preview.text || opened?.text || "");
      setNoteMode(true);
      setErr("");
      return;
    }
    const r = await app.link.run({ type: "job_draft", op: "read", text: noteText, path: opened?.path ?? "" });
    if (!r.ok) return setErr(r.error || "");
    if (!r.data.form) return setErr(r.data.form_err);
    setOpened({ ...opened!, text: noteText });
    setForm(r.data.form);
    if (r.data.owners) setOwners(r.data.owners);
    setNoteMode(false);
    setErr("");
  }

  async function reload() {
    if (!reloadArmed && changed) {
      setReloadArmed(true);
      return;
    }
    await load();
  }

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        cancel();
      } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        save();
      }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
  });

  const set = (k: keyof Form, v: string) => {
    setForm((f) => (f ? { ...f, [k]: v } : f));
    setDiscard(false);
  };
  const edit = !!opened?.path;
  const msg = discard
    ? "Discard your changes? Cancel or Esc again discards them"
    : reloadArmed
      ? "Discard your changes and load the new version? Reload again loads it"
      : stale
        ? "This job's note changed on disk since you opened it. Reload reads it again (your changes here go)"
        : err || (noteMode ? noteErr : preview.err);
  const foot = msg || (edit ? "Save rewrites the note's settings, title and prompt; the rest stays" : "Create writes the job's note in the jobs folder");
  const narrow = app.phone;

  return (
    <div class="scrim job-scrim">
      <div class={"job-sheet" + (narrow ? " phone" : "")} role="dialog" aria-label={edit ? "Edit job" : "New job"}>
        <div class="job-head">
          <span class="job-title">{edit ? "Edit job" : "New job"}</span>
          {edit ? <span class="muted small job-path">{opened!.shown}</span> : null}
          <span class="spacer" />
          {narrow && !noteMode ? (
            <div class="segmented small">
              <button type="button" class={!showNote ? "on" : ""} onClick={() => setShowNote(false)}>
                Form
              </button>
              <button type="button" class={showNote ? "on" : ""} onClick={() => setShowNote(true)}>
                Note
              </button>
            </div>
          ) : null}
        </div>
        <div class="job-body">
          {!form ? (
            <p class="empty">Reading the job…</p>
          ) : noteMode ? (
            <textarea class="field job-note-edit" spellcheck={false} value={noteText} onInput={(e) => { setNoteText((e.target as HTMLTextAreaElement).value); setDiscard(false); }} aria-label="Note" />
          ) : (
            <>
              {!narrow || !showNote ? (
                <div class="job-form">
                  <Field label="Name">
                    <input ref={nameField} class="field" type="text" value={form.name} placeholder={HINTS.name} onInput={(e) => set("name", (e.target as HTMLInputElement).value)} />
                  </Field>
                  <Field label="Project">
                    <div class="job-owners" role="radiogroup" aria-label="Project">
                      {owners.map((o) => (
                        <button type="button" role="radio" aria-checked={o.value === form.for_project} class={"job-owner" + (o.value === form.for_project ? " on" : "")} onClick={() => setForm({ ...form, for_project: o.value, folder: o.folder })}>
                          <span class="job-radio">{o.value === form.for_project ? "●" : "○"}</span>
                          <span class="job-owner-name">{o.label}</span>
                          <span class="spacer" />
                          <span class="muted small job-owner-folder">{o.folder}</span>
                        </button>
                      ))}
                    </div>
                  </Field>
                  <Field label="Schedule">
                    <div class="job-col">
                      <Chips list={PRESETS} on={form.preset} pick={(v) => set("preset", v)} />
                      {form.preset === "every_hours" ? (
                        <div class="job-inline">
                          <input class="field job-short" type="text" inputMode="numeric" value={form.every_n} placeholder={HINTS.every_n} onInput={(e) => set("every_n", (e.target as HTMLInputElement).value)} aria-label="Every" />
                          <span class="muted small">hours</span>
                        </div>
                      ) : form.preset === "daily" || form.preset === "weekdays" ? (
                        <div class="job-inline">
                          <span class="muted small">at</span>
                          <input class="field job-short" type="text" value={form.at} placeholder={HINTS.at} onInput={(e) => set("at", (e.target as HTMLInputElement).value)} aria-label="At" />
                        </div>
                      ) : form.preset === "custom" ? (
                        <input class="field mono" type="text" value={form.custom} placeholder={HINTS.custom} spellcheck={false} onInput={(e) => set("custom", (e.target as HTMLInputElement).value)} aria-label="Schedule" />
                      ) : null}
                      <div class={"small" + (preview.next_ok ? " muted" : " error-ink")}>{preview.next}</div>
                    </div>
                  </Field>
                  <Field label="Prompt">
                    <textarea class="field job-prompt" value={form.prompt} placeholder={HINTS.prompt} onInput={(e) => set("prompt", (e.target as HTMLTextAreaElement).value)} />
                  </Field>
                  <Field label="Access">
                    <Chips list={ACCESS} on={form.access} pick={(v) => set("access", v)} />
                  </Field>
                  <Field label="Notify">
                    <Chips list={NOTIFY.map((n) => [n, n])} on={form.notify} pick={(v) => set("notify", v)} />
                  </Field>
                  <button type="button" class="job-advanced" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}>
                    <Icon name={advanced ? "chevron-down" : "chevron-right"} size={12} />
                    Advanced: model, hours, limits
                  </button>
                  {advanced
                    ? ADVANCED.map(([k, label]) => (
                        <Field label={label}>
                          <input class="field" type="text" value={form[k]} placeholder={HINTS[k]} spellcheck={false} onInput={(e) => set(k, (e.target as HTMLInputElement).value)} />
                        </Field>
                      ))
                    : null}
                </div>
              ) : null}
              {!narrow || showNote ? <pre class="job-preview" aria-label="The note">{preview.text}</pre> : null}
            </>
          )}
        </div>
        <div class="job-foot">
          <button type="button" class="btn" onClick={mode} disabled={!form}>
            {noteMode ? "Back to form" : "Edit as note"}
          </button>
          <div class={"job-msg small" + (msg ? " error-ink" : " muted")}>{foot}</div>
          <div class="job-btns">
            {stale ? (
              <button type="button" class="btn" onClick={reload}>
                Reload
              </button>
            ) : null}
            <button type="button" class="btn" onClick={cancel}>
              {discard ? "Discard" : "Cancel"}
            </button>
            <button type="button" class="btn primary" onClick={save} disabled={!form || busy}>
              {edit ? "Save" : "Create"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: any }) {
  return (
    <div class="job-field">
      <div class="job-label">{label}</div>
      <div class="job-ctl">{children}</div>
    </div>
  );
}

function Chips({ list, on, pick }: { list: [string, string][]; on: string; pick: (v: string) => void }) {
  return (
    <div class="job-chips" role="radiogroup">
      {list.map(([v, label]) => (
        <button type="button" role="radio" aria-checked={v === on} class={"chip" + (v === on ? " on" : "")} onClick={() => pick(v)}>
          {label}
        </button>
      ))}
    </div>
  );
}
