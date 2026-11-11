# Atlas: jobs and memory (design)

Status: step 1 (§9) is built (`src/core/jobs*.odin`, `src/ui_jobs.odin`, `src/ui_job_sheet.odin`);
"Step 1 as built" in §9 lists where it differs from this design. The rest is design. The user's
view is in [GUIDE.md](GUIDE.md#jobs); how Atlas runs is in
[PROTOCOL.md §8](PROTOCOL.md#8-the-built-in-agent) and `src/core/agent.odin`.

**Where it runs.** Atlas's pi tab, the scheduler and job runs all live in the core. Atlas is a pi
tab whose process the session holder keeps; job runs are the core's own children. So jobs run and
Atlas keeps working while the window is closed, for as long as the core runs (§5).

**Where Atlas runs.** Interactive Atlas starts in Deckhand's main folder (§2), or in the data
dir's `home/` while no main folder is set or it cannot be reached. It never starts in the user's
home folder (`~`), even when `~` is the main folder: Atlas runs as part of Deckhand, so a plain
`ls` or `grep -r` from `~` would walk into Desktop, Documents and Downloads and trigger macOS
privacy prompts. An Atlas conversation recorded in another folder is copied once into the new
folder with pi's `--fork` (`src/core/home.odin`; GUIDE.md "Where it works"). Job runs are separate:
each runs in its job's `folder` (§3.1).

Markers: **Decided** = a settled design decision (not reopened here) · **Proposal** = this doc's choice,
open to change · **Unverified** = depends on platform behaviour nobody has tested yet · ❓ = open
question (§10).

The idea, in the spirit of Hermes Agent and OpenClaw: in the end it is a cron job with its own
memory management. So: a clock that starts fresh pi runs, a folder of markdown memory every agent
can read, and a way for results to reach the user. On safety: jobs exist to finish while no one is
around, so stopping to ask on every run would defeat them. Runs never stop to ask; they finish and
report.

## 1. Goals and non-goals

**Goals**
- User-created jobs that start pi on a schedule, even when Deckhand's window is closed
  (**Decided**; built through the core, §5).
- Jobs may act while the user is away; no jobs by default (**Decided**). Jobs need no approval:
  any job note runs on its schedule, agents may create and edit jobs (**Decided** 2026-11-01, §10.3).
- One memory folder shared by pi, Claude Code, Atlas and jobs: Deckhand's main folder, which can
  be the user's existing notes folder (`PI_KIT_NOTES_DIR`) (**Decided**; §2).
- Results reach the user: the Jobs tab, the notification centre (`job.finished`), a macOS notification (§7).
- Cheap when idle: no-agent checks and a quiet heartbeat cost no model call when nothing changed.

**Non-goals (for now)**
- Slack, phone or email delivery (**Decided**: later; §7 names the hook point).
- A sandbox in v1. Guardrails are pattern rails, not a boundary; phase 2 is §4.7 (**Decided**).
- Embeddings over memory; plain text search first (§6).
- Atlas writing new skills on its own (pi's skills folder; new skills ask first).
- Linux and Windows (macOS first).

What we took from other systems, with links: §11.

**Atlas drives pi and Claude tabs alike.** The desk tools in Deckhand's bundled pi integration
(`integrations/pi`) (`desk_prompt`, `desk_wait`,
`desk_watch`) take a pi tab, a Claude tab, or an open session (its pi tab; a Claude-only
session's Claude tab). For a Claude tab they send `claude_prompt` (held until Claude is idle and
the user types nothing; the tool says "held: <why>"), wait with `claude_wait_idle` (idle per
Claude's hooks **and** its OSC 7501 status, nothing held, nobody typing; PROTOCOL.md) and watch
the tab's `claude.turn` and `program_status` events. Atlas itself still runs on pi.

## 2. Folder layout (notes root)

The notes root is Deckhand's main folder (setting `home_dir`; GUIDE.md
"Your folders"), chosen in the first-run sheet: it offers the user's `PI_KIT_NOTES_DIR` (Deckhand's
environment, else read once per start from the login shell) or a notes folder named in pi's
global AGENTS.md, or `~/Deckhand`. Each subfolder (`jobs/`, `atlas/`, `memory/`, `sessions/`,
`chats/`) may be overridden. Deckhand passes `PI_KIT_NOTES_DIR=<home_dir>` to every pi tab and
job run unless the user's own environment sets it (theirs wins).

```
<notes root>/                    (may already hold other notes: sessions/, projects/, …)
  atlas/
    ATLAS.md                     Atlas's prompt (moved from Deckhand's data dir, §8)
    HEARTBEAT.md                 the heartbeat checklist (§3.4)
  memory/
    USER.md                      who the user is, preferences      cap 1,500 chars
    MEMORY.md                    durable facts, lessons, pointers  cap 4,000 chars
    FORGOTTEN.md                 things the user asked to forget; never re-promoted
    changes.log                  append-only: one line per USER/MEMORY change
    daily/YYYY-MM-DD.md          append-only daily log
    .history/YYYY-MM-DD.md       copy of USER/MEMORY before any rewrite
  jobs/
    <slug>.md                    one note per job: definition + recent runs
```

**Frontmatter** follows the notes folder's conventions (pi-kit's, when it is a pi-kit notes
folder). Proposal: new `type` values `atlas`, `memory`, `daily`, `job`; `project: atlas`;
`updated_by` gains `atlas`. Deckhand never edits the folder's own README for that.

**Who writes what** (Proposal)

| File | Writers | Rule |
|---|---|---|
| `atlas/*`, `jobs/<slug>.md` definition | the user; interactive Atlas or Claude | protected from job runs (§4.1); a note runs as written, no approval (§3.6) |
| `jobs/<slug>.md` `## Recent runs` | Deckhand's scheduler only (code, not a model) | rewrites only that section, atomically |
| `memory/USER.md`, `MEMORY.md` | the user or the curation job directly; everyone else through the memory tools or `pi-kit memory` | single writer: lock, caps, scans, backup (§6) |
| `memory/daily/*.md` | memory tools (any agent, job runs included) | append-only, one tagged line per write |
| `sessions/*` | each main session its own (pi `-pi-`, Claude, Atlas `-atlas-`) | unchanged |

**Concurrent edits.** Writers are pi, Claude Code, Atlas, job runs, Deckhand and Obsidian. Every
programmatic write re-reads the file, changes only its own section or line, writes a temp file
in the same folder and renames it over the original, and retries once if the mtime changed in
between. Appends use `O_APPEND`, one short line per write. `memory/.lock` (exclusive create,
stale after 30 s) serialises USER/MEMORY changes across processes.

**"Only main sessions write notes"** stays. A job run is not a main session: its record is the
job note's run lines, written by the scheduler. Interactive Atlas is a main session and keeps
`sessions/YYYY-MM-DD-atlas-<slug>.md`.

**Git** (**Decided**): no commit per run. If the notes folder is a git repository, whatever
commits it (a hook, the user) may refuse a staged secret-shaped string. So the scheduler redacts every summary with pi-kit's patterns
(`extensions/guardrails/core.ts`) before writing it, and memory writes are scanned (§6).

## 3. Jobs

### 3.1 The job note

`jobs/<slug>.md`. Definition fields live in frontmatter so Obsidian shows them as properties.
Deckhand reads a strict flat YAML subset (`key: value`, quoted strings, `[a, b]` lists); anything
else is an error on the job's row and the job does not run.

```markdown
---
type: job
project: atlas                 # notes frontmatter field, as in every note; not the job's scope
date: 2026-11-01
status: active
summary: Morning triage of open PRs across my repos
tags: [job]
updated_by: claude
id: 7f3a2c                     # stable; history follows the id, so renaming the file is safe
enabled: true
schedule: "0 7 * * 1-5"        # cron (local) | "every 30m" | "at 2026-11-03 09:00" | "manual"
hours: "07-22"                 # optional: only start inside these local hours
model: anthropic/claude-sonnet-4-5   # optional; else Atlas's agent_model, else pi's default
folder: ~/code                 # the run's cwd and scope; default the home folder
for_project: ~/code/pi-kit     # optional: who it belongs to (a project's folder or name, atlas, chats, none); else its folder decides
access: read                   # read | workspace | full (§4.1)
worktree: false                # true: run in a fresh git worktree of `folder` (§3.7)
touches: [outside, private]    # optional: outside content / private data / act (§4.3)
notify: always                 # always | attention | never (§7)
# optional limits, off unless set (§4.4): max_cost: 0.50, timeout: 20m, max_turns: 40
---
# Morning PR triage

## Prompt
List open PRs in ~/code repos that wait on me, oldest first, with one line each.

## Check
(optional shell command; see §3.3)

## Recent runs
<!-- written by Deckhand; edits here are overwritten -->
- 2026-11-01 07:00 ✅ 1m12s $0.08 — 3 PRs wait on you (oldest: pi-kit#9) · [run](file:///…/summary.md)
```

**Scope.** `folder` is the scope link; `for_project` only groups the job in the Jobs tab (its
owner: a project, Atlas, Chats or Other; without it the folder decides; GUIDE.md "The Jobs tab",
`src/core/jobs_owner.odin`). Removing a project from Deckhand never deletes or edits its jobs; they are
grouped by their folder then.

**Schedules.** Cron is local time (a DST-skipped time is skipped, a repeated hour runs once).
`every` counts from the end of the previous run. `at` runs once, then the scheduler sets
`enabled: false`. A job with a prompt scheduled more often than every 30 minutes
gets a warning on its row (cost), not a refusal.

### 3.2 The clock and missed runs

**Wall-clock deadlines.** The scheduler stores each job's next due time as a wall-clock instant
and checks every 30 s and on wake. It never sleeps for an interval: monotonic clocks pause while
the Mac sleeps, so "fire in 30 min" drifts by the sleep time.

**Missed runs** (**Decided**). A run that is late (Mac asleep, Deckhand's core not running,
previous run still going) starts only within a **grace window** of half the job's interval,
clamped to 2 min–2 h (cron: the gap to the next fire time; `at`: 2 h). Past the window the tick is
**skipped** and recorded with its reason: `skipped (asleep)`, `skipped (closed)`,
`skipped (previous run still going)`, `skipped (outside hours)`, `skipped (paused)`,
`skipped (limit reached)`. Several missed ticks make one skipped line, not a burst of runs. This
is why we run our own clock: launchd's `StartCalendarInterval` coalesces missed fire times into
one run on wake, with no grace window and no record of what was skipped.

**Scheduled time.** Each run gets `DECKHAND_SCHEDULED_AT=<ISO time>` (the tick it serves, not the
start time), and the preamble says it, so "since yesterday 07:00" means the right thing on a late
start.

### 3.3 No-agent check mode

A job may have a `## Check` section with one fenced shell command. Each due tick the scheduler
runs it (cwd = `folder`, environment as §3.7, timeout 60 s) and hashes stdout:
- same hash as last time → `unchanged`, no model call, no delivery;
- changed and the job has a prompt → pi runs with the prompt plus the old and new output;
- changed and no prompt → the diff (capped at 4 KB) is delivered as is; no model at all;
- exit code ≠ 0 → `check_failed`, delivered per `notify`.
The last output is kept in the data dir, never in the vault.

### 3.4 Heartbeat

An ordinary user-created job, not a built-in: `jobs/heartbeat.md`, `schedule: "every 30m"`,
`hours`, a cheap `model`, `notify: attention`, prompt: *"Read atlas/HEARTBEAT.md and work through
it. If nothing needs the user's attention, reply HEARTBEAT_OK."* A reply that starts or ends
with `HEARTBEAT_OK` (case-insensitive, ignoring whitespace and punctuation around it) is
`quiet`: one run line, no delivery. "New heartbeat" in the Jobs tab writes this template
disabled. `HEARTBEAT.md` is the user's checklist ("CI red on main?").

### 3.5 Run history

| In the job note (`## Recent runs`) | In `<data dir>/jobs/<id>/` |
|---|---|
| last 10 runs, one line each: time, status (with skip reason), duration, cost, headline, link | `runs/<UTC stamp>-<n>/`: `events.jsonl`, `stderr.log`, `check.out`, `summary.md` (redacted), `meta.json` (status, scheduled time, exit, cost, tokens, needs-you items, blocked actions, delivered, read) |
| | `sessions/` (pi `--session-dir`), `state.json` (next due, last check hash, action allowlist, failure streak), `run.lock` |

Statuses: `ok`, `quiet`, `unchanged`, `needs_you`, `failed`, `check_failed`, `timeout`,
`over_limit`, `looping`, `stalled`, `folder_missing`, `skipped (<reason>)`. Retention: runs older
than 30 days or beyond the newest 100 per job are deleted; skipped ticks keep only their line.

**Folder gone.** If `folder` (or the project behind it) no longer exists at start, the run is
`folder_missing`, the job pauses, the user is notified, and the note and history are kept.
Nothing is ever deleted automatically.

### 3.6 Creating, editing, deleting

- **The user in the GUI:** Jobs tab → New job (the job sheet) writes the note (`enabled: true`).
  **By editing the note** in any editor: the file watcher picks it up.
- **Interactive Atlas or Claude:** `job_create` from `control`, or a file write. A note runs on
  its schedule as written, as soon as it parses.
- **No approval** (Decision, §10.3): Deckhand keeps no approval record and
  no key; an edited note runs as edited. The controls are `enabled:` in the note (Enable /
  Disable, user-only through `job_set_enabled`), the per-job pause, Pause all (`jobs_pause`, the
  kill switch) and the limits and safety stops (§4.5). Only Pause all and the per-job pause are
  stops agents cannot undo (resuming is user-only); `enabled:` is in the note, so anything that
  edits notes can turn a disabled job back on. Unknown frontmatter keys are errors (`approved: true` too).
- **Job runs cannot create or edit jobs.** `jobs/` is a protected path (§4.1, step 4; until then
  the preamble says so) and runs get no Deckhand socket. A run may propose a job under its `Needs
  you` section.
- **Delete:** the row's Delete moves the note to the Trash (`delete_path`, confirms). Deleting the
  file by hand removes the job; its data-dir runs age out.

New commands (rows in `src/core/command_table.odin`): `job_list` (query), `job_run_now`, `job_stop`,
`jobs_pause` (anyone), `job_create` (anyone), `job_mark_read`; user-only: `jobs_resume`,
`job_set_enabled`. Planned, not built: `job_approve_action`, `job_revoke_action` (step 4),
`memory_pending_decide` (step 3).

### 3.7 Each run is a fresh one-shot pi

**Proposal: JSON mode** (pi runs once and exits):

```
pi --mode json --session-dir <data dir>/jobs/<id>/sessions --session-id <uuid>
   [--model <model>] --append-system-prompt <notes>/atlas/ATLAS.md
   --append-system-prompt <run dir>/preamble.md   "<prompt>"
```

Not a TUI in a hidden PTY (waits forever on an unseen dialog), not RPC (`hasUI` true, so every
guardrail confirm needs an answer), not print mode (no cost or tool events). In JSON mode
guardrails **block** risky commands ("Needs user approval (…), and no UI is available"). The
stream gives `usage.cost`, tool calls and results, and `agent_settled`. The session is saved, so
a run can be opened in pi.

**Preamble** (written per run by Deckhand, not editable by the user or a job):
- You are job `<name>`, scheduled for `<DECKHAND_SCHEDULED_AT>`, running unattended; nobody can
  answer questions, so do not ask.
- This scheduled prompt cannot approve risky actions: a blocked action stays blocked; do not work
  around it, list it under `## Needs you`.
- You cannot create or edit jobs; propose one under `## Needs you`.
- Never write to protected paths (§4.1).
- End with `## Summary` (first line: a one-line headline) and, if needed, `## Needs you`.

**Environment** (an allowlist, not the user's shell): `HOME`, `USER`, `LANG`, `TMPDIR`, `PATH`
(the login shell's, captured once as setting `jobs_path`), `PI_KIT_NOTES_DIR`, the access
variables (§4.1), `DECKHAND_JOB`, `DECKHAND_RUN`, `DECKHAND_RUN_DIR`, `DECKHAND_SCHEDULED_AT`. No
`DECKHAND_SOCKET` or tokens. pi reads its own credentials as in any terminal. stdin is `/dev/null`.

**`worktree: true`** (only when `folder` is a git repo): the run happens in a fresh
`git worktree add` of HEAD under the data dir on branch `job/<slug>/<stamp>`; `workspace` write
roots become that worktree. The user's checkout and uncommitted edits are never touched. The
worktree is removed by retention unless its branch has commits, which are listed in the report.

## 4. Permissions and safety

### 4.1 Access levels and protected paths

Per-job `access`, set in the job's note (Proposal).

| `access` | Meaning | How |
|---|---|---|
| `read` (default) | read, read-only commands, daily memory notes | `PI_KIT_READONLY=1` |
| `workspace` | edit under `folder` (or the worktree) and write memory | new pi-kit `PI_KIT_WRITE_ROOTS=<root>`: edit/write refused outside; mutating bash only with cwd inside. Best-effort (**Decided**) |
| `full` | what an interactive pi may do | normal guardrails |

At every level, including `full`: the guardrails' dangerous list (force push, push to main,
merges, deploys, `rm -rf`, infra changes, alert silencing, destructive SQL, publishing) is
blocked, and file writes (edit/write tools, shell redirects, `rm`/`mv`/`cp` targets) to
**protected paths** are refused: `.git` and the resolved gitdir (a worktree's `.git` is a file
pointing elsewhere), `.pi/`, `AGENTS.md`, `CLAUDE.md`, shell rc files (`~/.zshrc`, `~/.zprofile`,
`~/.bashrc`, `~/.bash_profile`, `~/.profile`), and the notes folder's `jobs/` and `atlas/`. Git
commands themselves stay under the guardrails' git rules. These are pattern rails: aliases,
scripts and `eval` get past them until §4.7.

### 4.2 Blocked actions: approve exactly that action

Runs never stop for approval. The scheduler records each blocked tool call from the event stream
as `{tool, command, cwd, sha256}` in `meta.json`; the run ends `needs_you` and the item shows on
the job's row and in the delivery. The user can:
- **Approve once:** Deckhand re-checks the hash and runs that stored command in that cwd with the
  job's environment, appends the output to the run and delivers it. No model re-plans it.
- **Always for this job:** the hash goes into the job's allowlist in `state.json`; later runs get
  `PI_KIT_ALLOW_FILE=<file>` and guardrails let exactly that command + cwd through. Revocable on
  the job's row (`job_revoke_action`); the list is shown with the job.
- **Open in pi** (separate, clearly labelled): resumes the run's session in a pi tab, where the
  user talks to a model and guardrails ask as usual. Not an approval of anything by itself.

### 4.3 The "Rule of Two" note

An agent that reads untrusted content, sees private data and can act or send is the risky
combination. **Decided:** it never stops a run. The job note's optional `touches` list (GUI
checkboxes: reads outside content / private data / can act or send) is informational. Approving
a job with all three shows a one-time, non-blocking note naming the risk and suggesting dropping
one; it is not shown again for that job.

### 4.4 Limits (off unless set)

**Decided:** no default limits. Settings → Jobs → Limits, each off until set:
- per run: `max_cost` (USD from `usage.cost`), `timeout`, `max_turns` (global defaults, per-job
  override in the note); hitting one stops that run (SIGTERM, SIGKILL after 5 s) → `over_limit`;
- per day / per week / per month (USD across all jobs): when reached, no new model runs start
  (ticks are `skipped (limit reached)`) until the period ends; a run already in progress finishes
  (GitHub's model);
- concurrency: max runs at once; extra due runs queue in due order.
One run per job at a time is not a limit; it is the run lock (§5). Subscription providers may
report cost 0, so cost limits do not bind there.

### 4.5 Safety stops (always on)

Separate from limits; they catch a broken run, not an expensive one.
- **Loop detector:** the same tool call (tool + arguments hash) 5 times in a row → stopped,
  `looping`.
- **No-events watchdog:** no event from pi for 10 minutes → stopped, `stalled`.
- **Auto-pause:** 3 failures in a row (`failed`, `timeout`, `looping`, `stalled`, `check_failed`)
  → the job pauses. `folder_missing` pauses at once (§3.5).
- **Notify each time** a safety stop fires (§7 failure alerts apply).
Thresholds are settings; the stops cannot be turned off.

### 4.6 Secrets, kill switch, logging

**Secrets:** the environment allowlist; tools use their own credential stores; summaries are
redacted; run dirs are mode `0700`. **Kill switch:** `jobs_pause` (Jobs tab, palette,
`deckhand --ctl`) stops new runs; Stop all ends running ones; resuming is user-only. **Logging:**
the run folder; scheduler decisions (due, started, skipped + reason, stopped + reason) in `<data dir>/jobs/scheduler.log`, rotated like the command log.

### 4.7 Phase 2: a real boundary (Proposal)

Wrap pi's bash tool in Anthropic's **sandbox-runtime** (`srt`): Seatbelt profile on macOS with
write access only to the write roots, credential paths unreadable, network only through srt's
proxy with a per-job domain allowlist. Known gaps to document when it ships: the proxy filters by
domain with no TLS inspection (an allowed domain can carry data out); Go-built tools that verify
certificates through `trustd` can fail inside the profile; `open` and `osascript` hand work to
processes outside the sandbox and must stay blocked; Seatbelt cannot nest, so tools that sandbox
themselves fail inside it, and we wrap bash, not pi. Apple's `container` or Lima VMs come later.

## 5. Jobs while the window is closed

**Built: the core.** The scheduler runs in the core (`deckhand-core-serve`, `src/coremain`), not
in the window, so jobs run whether or not a window is open. The design's separate scheduler
helper (`deckhand --scheduler`, `scheduler.lock`, `jobs.sock`) was never built: the core replaced
it.
- **Staying up.** The core does not exit while an enabled, scheduled job could run, while a run
  goes, while a window is attached or while a tab's process lives (`core_idle_due`,
  `src/core/core_loop.odin`). With none of those for 10 minutes it saves and exits.
- **Quitting.** ⌘Q closes only the window. **Quit Deckhand and Stop All Sessions…** stops the
  core: running runs get SIGTERM, then SIGKILL, and are recorded `stopped (quit)` (no
  notifications).
- **Updates.** A core handing over to a new one (`src/core/core_handover.odin`) starts no new run
  and waits up to 2 minutes (`JOBS_HANDOVER_WAIT`) for running ones; any still going are stopped
  as `stopped (update)`. A job due meanwhile stays due for the successor (its next due time moves
  on only once its run starts or is skipped).
- **Not yet: logout and reboot.** Nothing starts the core at login, so after a logout or reboot
  jobs wait until Deckhand is opened (ROADMAP M5, a login agent through `SMAppService`, which needs
  the user's approval in Login Items). Until then, ticks missed meanwhile are `skipped (closed)`
  (§3.2).

**Per-job run lock.** Before starting a run the scheduler takes `<data dir>/jobs/<id>/run.lock`
(`flock`, non-blocking) and passes the open descriptor to pi, so the lock lives exactly as long
as the run. If it is held, the tick is `skipped (previous run still going)`.

**Power** (design, not built). During a run, hold an IOKit `PreventUserIdleSystemSleep` assertion
so the Mac does not idle-sleep mid-run, and start only on a full wake, not a dark wake or Power
Nap (**Unverified** how reliably a process can tell). What is built: an `NSProcessInfo` activity
while a run goes, so App Nap does not delay it.

## 6. Memory (pi-kit `memory` extension)

Works in every pi with pi-kit and `PI_KIT_NOTES_DIR`. Paths are confined to the notes root;
credential-looking files are never read; output is redacted like any tool result.

| Tool | Does |
|---|---|
| `memory_search {terms[], since?, until?, folder?, limit?}` | notes containing all terms (case-insensitive, ripgrep), newest first, filtered by note date; `path:line` + snippet, at most 20 hits |
| `memory_read {path, offset?, limit?}` | read a note under the notes root |
| `memory_note {text, source}` | append `HH:MMZ <writer> [<source>] <text>` to `daily/<today>.md`; source = `user-said`, `agent-observed` or `job:<slug>` (forced in jobs) |
| `memory_update {file: user\|memory, ops: [{op: add\|replace\|remove, text?, old?}]}` | a batch, all or nothing; `old` is a unique substring of one entry; the cap is checked on the final result |

**Entries** in USER.md and MEMORY.md are bullet lines with provenance:
`- Prefers worktrees for changes (2026-11-01, user-said, [[sessions/2026-11-01-pi-kit-x]])`.
A replaced fact is marked `(superseded 2026-11-02)` rather than silently dropped; curation may
drop superseded entries later (they stay in `.history/`).

**Single writer.** Only the user and the curation job rewrite USER/MEMORY as files. Everyone else
goes through `memory_update` (pi) or the `pi-kit memory` CLI (Claude Code: `search`, `note`,
`update`), so the lock, caps, scans and log always apply. Before any rewrite the current files are
copied to `.history/<date>.md`; each change appends one line to `changes.log` (time, writer,
file, op, short text). A curation that would drop more than ~25% of entries is refused.

**Job writes queue** (**Decided**). In a job (`DECKHAND_JOB` set), `memory_update` does not touch
the files: the batch goes to `<DECKHAND_RUN_DIR>/memory-pending.json`, the tool reports "queued
for the user's approval", and the run carries on. The Jobs tab shows pending changes as a diff
with Approve / Reject (`memory_pending_decide`); Approve applies them via `pi-kit memory apply`
under the lock and caps. Daily notes are written directly at any access level. Atlas and
interactive sessions update directly, through the same checks.

**Write scans** (every write, and job prompts at approval): secret-shaped strings (guardrails'
redaction patterns) → refused; invisible Unicode (zero-width, bidi controls, tag characters) →
refused; instruction-like text ("ignore previous instructions", "always run …", tool-call
syntax) → refused for USER/MEMORY with the reason, so the agent rewrites it as a fact.

**Curation** is a user-created job (template "New memory curation": nightly, `access: workspace`,
`folder` = notes root). It reads recent daily and session notes and folds what lasts into
USER/MEMORY within the caps. It promotes a `job:<slug>` item only when two separate sources
support it or the user approved it, and never re-promotes anything matching `FORGOTTEN.md`
(where "forget X" requests go).

**Prompt** (**Decided**: Atlas and jobs only). At session start the extension adds a frozen
snapshot of USER.md and MEMORY.md under a header with usage (`USER.md 1,120/1,500 ·
MEMORY.md 3,410/4,000`) and a short guide: search before asking something the user may have said;
durable facts via `memory_update`, passing events via `memory_note`; never store secrets or
personal identifiers. Other sessions have the tools without the injection. When Slack/phone
delivery arrives, MEMORY.md loads only in private contexts, never in a session answering a shared
channel.

**Misses.** Zero-hit searches are logged locally (outside the vault). Embeddings are considered
only if that log shows misses growing.

## 7. Delivery

**Decided (2026-11-01, overrides draft 2):** job results are **not** pushed into Atlas's
context; Atlas would only bloat its context with them. A run reaches the user through the Jobs
tab, a macOS notification and the `job.finished` event, which Deckhand's notification centre (the
bell in the top bar) consumes. Atlas reads job state on demand, when the user asks, through the
read-only `job_list` / `job_runs` commands (any caller; results redacted).

When a run ends, the scheduler writes its record, then delivers it in one place
(`jobs_deliver`, `src/core/jobs.odin`). `notify`: `always`; `attention` (`needs_you`, failures and
safety stops, `folder_missing`, a changed no-agent check); `never`. `quiet`, `unchanged` and
skipped runs are never pushed, only listed.

**The report** is the run's `## Summary` and `## Needs you` sections, taken from the final
answer; if they are missing, the last message is used and the run is flagged "no summary".

**Failure alerts.** One alert per distinct error (status + normalised first error line), then a
6 h cooldown for the same error; a separate nudge when the third failure in a row auto-pauses the
job. If a run fails on a network error within 2 minutes of wake, it is retried once before
counting as a failure. (Step 1 has the nudge; the dedupe, cooldown and wake retry are step 6.)

Delivery:
1. **Event** `job.finished` (PROTOCOL.md §3), always emitted: `job`, `title`, `status`,
   `headline` (the one-line summary), `run`, `run_dir`, `summary_path`, `scheduled_at`,
   `needs_you[]`, `unread`. The bell consumes it; a later sink can run a user command with it on
   stdin (the Slack/phone hook point).
2. **Unread markers per run**, rolled up as a count on the Jobs tab (and a dot on its segment).
   A run is read once its report is opened (Last report) or `job_mark_read` is called.
3. **The bell** (notify.odin): every run with `notify` other than `never` goes to
   `notify_job_finished` (job id, title, status finished/needs_you/failed, the one-line summary,
   the run folder). The bell sends the macOS notification for runs that need the user or
   failed, paced by its own rules, while Deckhand is in the background.
4. **Deckhand's own macOS notification** only for what the bell does not notify: a finished run
   with `notify: always` (at most one per 5 s), the auto-pause nudge, and every pushed run while
   the bell's Jobs group is off. One run, one OS notification.
5. **On demand for Atlas:** `job_list {unread?}` and `job_runs {job, limit?}`: anyone may call
   them, a pi tab's bridge too, so a desk tool can fetch them when the user asks. No notice is
   sent to Atlas's terminal.

macOS notifications come from the window while one is open, else from the core itself (as
"Deckhand Core", `src/coremain/serve.odin`).

Optional (setting, off unless set): after N delivered runs of a job in a row go unread, its row
suggests pausing it.

**Jobs tab** (**Decided**: left column, next to Sessions and Files: the fourth segment, Sessions
| Files | Settings | Jobs, icons when the column is too narrow for the labels). Rows: name,
project (or global), status dot, next run, last result, unread dot, warnings (runs more
often than 30 min, pending memory changes, blocked actions). A row expands to its last runs,
skipped ticks included with their reason, and what needs the user. Row buttons: Run now, Stop,
Edit, Open note, Last report, Mark read; its "…" (and a right click): Run now / Stop, Pause /
Resume, Enable / Disable, Edit,
Open note, Open last report, Open run folder, Mark read, Delete (confirmed; the note goes to the
Trash, the history stays). Header: New job, Pause all / Resume all, Limits, unread count. New
heartbeat and New memory curation come with steps 5 and 3.

### 7.1 Other machines (decided 2026-11-08, design background-core.md §8.6; M6-F)

Every machine's core runs its own jobs and its own Atlas; the window shows them all. **The local
Atlas is the hub:** it sees the other machines' projects, sessions and jobs in `get_state` (under
each machine's name; desk_state fences each machine's part as data) and acts on their ids as
`control` there (`on_behalf`, PROTOCOL.md §5a "Working on another machine"): that machine applies
`control`'s rules again, so user-only settings and every `machine_*` command stay refused, and a
command it wants confirmed is refused here, not asked. Only this machine's own Atlas and user go
through: a machine viewing this one never reaches a third through it, and **remote Atlases stay
on their machine** (a remote core can send this one nothing but answers). There is no
Atlas-to-Atlas channel. That gate is about direct forwarding only: a machine this one lets connect
(*Allow other machines to connect*) acts as the user here, so it can prompt this Atlas, and through
it, or a shell here, reach the machines this one reaches. Let only machines you trust as yourself
connect.

**Their jobs and bells reach the user here**, because a remote core can't notify: this core
rings for a job there that needs the user (once per run) and for each new entry of that machine's
bell, naming the machine, at most 4 a minute per machine (PROTOCOL.md §5a "Other machines' jobs
and bells"). The Jobs tab lists their jobs after this Mac's, under each machine's name, read-only
(what each is up to, and the first thing it needs you for). Everything that comes from another
machine is untrusted: one line, no control, bidi or invisible characters, bounded, capped.

## 8. Migration: ATLAS.md

Today: `<data dir>/atlas/ATLAS.md`. New: `<atlas folder>/ATLAS.md` (`<home_dir>/atlas/`). At Atlas's start:
1. Notes copy exists → use it.
2. Else data-dir copy exists → copy it to the notes folder with exclusive create (never
   overwrite), add frontmatter (`type: atlas`), use the copy; the data-dir file stays as fallback.
3. Neither → write the starter into the notes folder.
4. no main folder, or the atlas folder unreachable → use the data-dir copy (or its starter) and show a one-line
   warning in the drawer.
Settings' Atlas group and "Atlas: edit prompt" open whichever copy is in use.

## 9. Build plan

Each step is its own PR with the repo's tests green. Steps 1, 3, 4 and 6 carry the most risk
(unattended execution, permissions, memory integrity).

**Step 1 — Scheduler, job notes, Jobs tab, Run now** (built). The note parser,
cron/every/at/manual, `hours`, wall-clock deadlines, the grace window and skip reasons,
`read`/`full` access, the run lock, limits, safety stops, auto-pause, JSON-mode runs with
preamble and environment, run folders, report extraction, the `## Recent runs` writer,
`folder_missing`, `job.finished`, the Jobs tab with unread markers, the job commands, the main
folder and §8. Tests: `src/core/jobs_test.odin`, `src/jobs_*_test.odin`, and the scene
`tests/scripts/jobs.sh` with a fake `pi` (setting `pi_path`).

**Step 1 as built** (where it differs from or adds to the design):
- **Commands** beyond §3.6's list: `job_delete {job, confirm?}` (the note to the Trash),
  `job_open {job, what: note|report|run_folder}`, `job_stop {job?}`, `jobs_pause` /
  `jobs_resume` with an optional `job` (one job, or all), `job_set_enabled`, `set_home_dir`,
  `set_pi_path`, `set_job_limits`. `jobs_resume`, `job_set_enabled` and the settings are the
  user's only. A job run has no Deckhand socket or token, so jobs cannot create jobs.
- **Not yet:** `access: workspace` and `worktree: true` are refused on the job's row (step 4);
  `## Check` is parsed but not run (a warning on the row; step 5). The heartbeat's
  `HEARTBEAT_OK` → `quiet` is built.
- **Environment:** runs also get `PI_CODING_AGENT_DIR` when it is set. pi is found on the jobs'
  `PATH` in absolute entries only.
- **The prompt** goes after `--`. pi still reads a leading `@…` there as a file to attach, so a
  prompt starting with `@` gets a leading newline.
- **`access: read`** also passes `--tools read,grep,find,ls --no-mcp`: pi's `--tools` allowlist
  covers extension tools too, and MCP tools stay unless `--no-mcp` is given.
- **Statuses:** over `timeout` → `timeout`; over cost or turns → `over_limit`. Skips of one reason
  in a row are one run line with a count (`⏭ skipped (asleep) ×3`).
- **Who may run what.** `job_run_now` from anyone but the user refuses a paused or disabled job.
  The limits hold for the user too. Limits in the Jobs tab step through presets; the safety stops
  have presets but no "off".
- **Stopping a run** signals pi's whole process tree (children by `proc_listchildpids`, then each
  one's process group): SIGTERM, then SIGKILL 5 s later. A stopped run's remembered tree gets
  SIGKILL when the run ends, so no child outlives it. Quit and handover: §5.
- **Ticks without frames.** A timer thread in the core posts a scheduler tick every second while a
  run goes (else every 30 s), so due checks and the watchdog never depend on the window.
- **Disk.** `sessions/` is pruned like `runs/`; `events.jsonl` moves to `events.jsonl.1` at 5 MB.
- **The note is the user's.** `## Recent runs` keeps the note's CRLF. The writer renames its temp
  file over the note only if the note did not change since it was read.
- **Test mode** never reads the login shell's `PATH` or `PI_KIT_NOTES_DIR`; the main folder is set
  explicitly (`set_home_dir`).

**Step 2 — Jobs while the window is closed.** Done by the core (§5); the helper design was
dropped. Left: starting at login (ROADMAP M5) and the power assertion and full-wake check.

**Step 3 — Memory extension (pi-kit).** The four tools, batch ops, caps, lock, provenance, source
tags, scans, `.history`, `changes.log`, the 25% guard, `FORGOTTEN.md`, job queueing, the
`pi-kit memory` CLI, the prompt snapshot, the miss log. Acceptance (pi-kit tests): paths outside
the root refused; a batch over the cap refused as a whole; concurrent updates both land; a job's
update queues; secret, invisible-Unicode and instruction text refused; backup before rewrite; a
curation dropping >25% refused.

**Step 4 — `workspace` access, protected paths, worktree, exact-action approval.**
`PI_KIT_WRITE_ROOTS`, protected paths at every level, `worktree: true`, `PI_KIT_ALLOW_FILE`,
Approve once / Always / Revoke. Acceptance: writes outside the roots and to each protected path
refused at `full`; a worktree run leaves the checkout's dirty files alone; Approve once runs
exactly the stored command (a changed hash is refused); a revoked action is blocked again.

**Step 5 — Heartbeat templates and no-agent checks.** `## Check`, the templates. Acceptance: the
same check output twice → pi never started; no prompt → the diff is delivered; a non-zero exit →
`check_failed`.

**Step 6 — Delivery polish.** Failure alert dedupe and cooldown, the wake retry, the unread-nudge
setting, the pending-memory review UI, the Rule of Two note. Acceptance: the same error twice
within 6 h alerts once.

**Phase 2 — srt sandbox** (§4.7), after the steps above are in use.

## 10. Decided after the first draft (2026-11-01)

1. ✅ **Curation applies directly.** The user-created curation job is the one job allowed to edit
   USER/MEMORY directly, relying on `.history`, `changes.log`, the 25% guard and FORGOTTEN.md.
   Every other job's USER/MEMORY changes still queue for approval.
2. ✅ **Safety-stop thresholds:** start with 5 identical tool calls, 10 minutes of silence, 3
   failures in a row; adjustable in settings; revisit after step 1 with real jobs (long builds can
   be silent longer).

3. ✅ **No job approvals** (2026-11-01). Any job note runs on its schedule; agents may create and
   edit jobs freely. The controls are the per-job enable toggle, pause and Pause all, and the
   limits and safety stops. Step 1 first shipped HMAC approvals with a Keychain key; macOS asked
   for Keychain access after every rebuild, which cost more than it protected, so they were
   removed. What this gives up: anything running as the user (an interactive agent, a
   full-access job run despite its preamble) can write a job note that then runs on its
   schedule.

## 11. Prior art

What we took from whom (research of 2026-11-01; details may have moved since).

| Source | Taken |
|---|---|
| OpenClaw: [cron](https://docs.openclaw.ai/automation/cron-jobs/how-it-works), [memory](https://docs.openclaw.ai/concepts/memory), [dreaming](https://docs.openclaw.ai/concepts/dreaming), [exec approvals](https://docs.openclaw.ai/tools/exec-approvals), [duplicate delivery](https://github.com/openclaw/openclaw/issues/15692) | heartbeat + `HEARTBEAT.md` + silent OK token; USER/MEMORY + daily notes; nightly curation; approve the exact command; per-job run lock |
| Hermes Agent: [cron](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron), [memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory), [delivery bug](https://github.com/NousResearch/hermes-agent/issues/58075) | bounded USER/MEMORY injected at start; no-agent watchdog checks; jobs can't create jobs; delivery from the summary |
| Letta: [sleep-time agents](https://docs.letta.com/guides/agents/architectures/sleeptime), [MemFS](https://docs.letta.com/letta-code/memfs), [benchmark](https://www.letta.com/blog/benchmarking-ai-agent-memory) | curation as a background job; memory as plain files; file search before embeddings |
| [mem0](https://arxiv.org/abs/2504.19413), [Zep](https://arxiv.org/abs/2501.13956) | batch add/update/delete ops; provenance; superseded facts marked, not deleted |
| Claude: [memory tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/memory-tool), [Claude Code memory](https://code.claude.com/docs/en/memory); ChatGPT memory | usage shown to the model; "forget" respected; memory only in private contexts |
| [LongMemEval](https://arxiv.org/abs/2410.10813) | search with time filters and multiple terms |
| [MINJA](https://arxiv.org/abs/2503.03704) | memory injection through ordinary interactions → write scans, source tags, two-source promotion |
| [Goose](https://github.com/aaif-goose/goose), Agent Zero, n8n | loop detection on repeated tool calls; error alerts and retries |
| Claude Code: [routines](https://code.claude.com/docs/en/routines), [desktop scheduled tasks](https://code.claude.com/docs/en/desktop-scheduled-tasks) | "a scheduled prompt cannot approve risky actions"; scheduled time passed to the run; skip-not-backfill |
| [Codex](https://github.com/openai/codex), [ChatGPT/Codex automations](https://learn.chatgpt.com/docs/automations.md?surface=app), [Gemini scheduled actions](https://support.google.com/gemini/answer/16316416), Grok/Perplexity tasks | one-off `at` jobs; frequency warnings; worktree runs |
| [Cursor automations](https://cursor.com/docs/cloud-agent/automations), [Devin scheduled sessions](https://docs.devin.ai/product-guides/scheduled-sessions), [GitHub Copilot automations](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/cloud-agent/create-automations) | isolation for unattended edits; a spending limit doesn't kill a run in progress |
| [The lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/), Meta's Agents Rule of Two | the `touches` note (informational only) |
| [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime), [Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing) | phase 2 boundary and its known gaps |
| Apple: [launchd scheduled jobs](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) | login item and approval state; `KeepAlive`; `StartCalendarInterval` coalescing |
