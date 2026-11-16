// The Jobs tab (src/ui_jobs.odin), from state.jobs: each job's schedule, its last run and what it
// does now, with Run now and Stop; New job (+), and each job's menu (Edit…: the job sheet,
// JobSheet.tsx; Delete…).

import { menuAt, useApp, type App, type MenuItem } from "./ctx.ts";
import { Icon, StatusMark } from "./icons.tsx";
import { IconButton } from "./Sidebar.tsx";
import { openJobSheet } from "./JobSheet.tsx";
import type { Mark } from "../status.ts";

function rel(sec: number): string {
  if (!sec) return "";
  const d = sec - Date.now() / 1000;
  const a = Math.abs(d);
  const n = a < 60 ? "now" : a < 3600 ? Math.round(a / 60) + "m" : a < 86400 ? Math.round(a / 3600) + "h" : Math.round(a / 86400) + "d";
  if (n === "now") return "now";
  return d > 0 ? "in " + n : n + " ago";
}

function jobMark(j: any): Mark {
  if (j.err) return "error";
  if (j.running) return "working";
  if (j.needs_you?.length) return "waiting";
  if (j.last_status === "failed" || j.last_status === "error") return "error";
  if (j.last_status === "finished" || j.last_status === "ok") return "done";
  return "idle";
}

export function JobsPanel() {
  const app = useApp();
  const { store } = app;
  const jobs = store.jobs;
  const others = store.machineJobs;
  return (
    <div class="jobs">
      <div class="nav-header">
        <span class="nav-title static">JOBS</span>
        <span class="spacer" />
        <IconButton small icon="plus" label="New job" run={() => openJobSheet(app, "")} />
        <IconButton small icon="pause" label="Pause all jobs" run={() => app.run({ type: "jobs_pause" })} />
        <IconButton small icon="play" label="Resume all jobs" run={() => app.run({ type: "jobs_resume" })} />
      </div>
      <div class="nav">
        {jobs.length === 0 && others.length === 0 ? (
          <div class="empty-state">
            <div>No jobs yet</div>
            <div class="muted small">New job (+) writes a job note</div>
          </div>
        ) : null}
        {jobs.map((j: any) => (
          <JobRow j={j} />
        ))}
        {others.length ? <div class="nav-header"><span class="nav-title static">OTHER MACHINES</span></div> : null}
        {others.map((j: any) => (
          <JobRow j={j} remote />
        ))}
      </div>
    </div>
  );
}

function JobRow({ j, remote }: { j: any; remote?: boolean }) {
  const app = useApp();
  const state = j.err
    ? "Does not parse: " + j.err
    : j.running
      ? "Running"
      : j.queued
        ? "Queued"
        : j.paused
          ? "Paused" + (j.paused_why ? ": " + j.paused_why : "")
          : !j.enabled
            ? "Off"
            : j.next_due
              ? "Next " + rel(j.next_due)
              : "";
  const last = j.last_at ? `${j.last_status || "ran"} ${rel(j.last_at)}${j.last_headline ? " · " + j.last_headline : ""}` : "Never ran";
  return (
    <div
      class="job-row"
      onContextMenu={(e) => {
        if (remote) return;
        e.preventDefault();
        menuAt(app, e, jobItems(app, j));
      }}
    >
      <div class="job-top">
        <StatusMark mark={jobMark(j)} />
        <span class="title">{j.name || j.id}</span>
        {j.unread ? <span class="badge inline">{j.unread}</span> : null}
        <span class="spacer" />
        {remote ? null : <span class="job-more"><IconButton small icon="more" label="More" run={(e) => menuAt(app, e, jobItems(app, j))} /></span>}
        {remote ? (
          <span class="when">{app.store.machineName(j.machine)}</span>
        ) : j.running ? (
          <button type="button" class="btn small" onClick={() => app.run({ type: "job_stop", job: j.id })}>
            <Icon name="stop" size={12} /> Stop
          </button>
        ) : (
          <button type="button" class="btn small" disabled={!!j.err} onClick={() => app.run({ type: "job_run_now", job: j.id })}>
            <Icon name="play" size={12} /> Run now
          </button>
        )}
      </div>
      <div class="job-sub">
        <span>{j.schedule}</span>
        {state ? <span> · {state}</span> : null}
      </div>
      <div class="job-sub muted">{last}</div>
      {j.needs_you?.length ? <div class="job-sub waiting-ink">Needs you: {j.needs_you[0]}</div> : null}
    </div>
  );
}

// A job's menu, as the window's (src/ui_jobs.odin): what it runs now, then Edit… and Delete….
function jobItems(app: App, j: any): MenuItem[] {
  const items: MenuItem[] = [];
  if (j.running) items.push({ label: "Stop", run: () => app.run({ type: "job_stop", job: j.id }) });
  else if (!j.err) items.push({ label: "Run now", run: () => app.run({ type: "job_run_now", job: j.id }) });
  items.push(j.paused ? { label: "Resume", run: () => app.run({ type: "jobs_resume", job: j.id }) } : { label: "Pause", run: () => app.run({ type: "jobs_pause", job: j.id }) });
  if (!j.err) items.push({ label: j.enabled ? "Disable" : "Enable", run: () => app.run({ type: "job_set_enabled", job: j.id, on: !j.enabled }) });
  items.push({ sep: true });
  items.push({ label: "Edit…", run: () => openJobSheet(app, j.id) });
  if (j.unread > 0) items.push({ label: "Mark read", run: () => app.run({ type: "job_mark_read", job: j.id }) });
  items.push({ sep: true });
  items.push({ label: "Delete…", danger: true, run: () => app.run({ type: "job_delete", job: j.id }) });
  return items;
}
