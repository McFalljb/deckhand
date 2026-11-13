# Testing Deckhand

Every test layer and scene, what it protects and when it must run. The scene list itself (tiers,
tags, typical times, the files each covers) is one data file, [`tests/scenes.txt`](../tests/scenes.txt),
which the runner reads. How test mode works: [DEVELOPING.md](DEVELOPING.md#test-mode-and-scenes).

## Contents

1. [What to run](#what-to-run)
2. [Test layers](#test-layers)
3. [Scenes](#scenes)
4. [Running scenes in parallel](#running-scenes-in-parallel)
5. [Waits](#waits)
6. [Timing tests](#timing-tests)
7. [Flakes](#flakes)
8. [Open clean-ups](#open-clean-ups)

## What to run

No test run should take more than 3 minutes. Run the smallest set that covers the change. Run the
focused scenes locally; CI runs the required set on every pull request and the rest after the
merge, so don't run the whole suite locally to stand in for CI.

| When | Command | Time (dev Mac) |
|---|---|---|
| Every change | `./build.sh test`, and `./build.sh scenes --changed` if it touches the app or a scene | test ~1 min; scenes ~0.5–2 min |
| A scene failed | that scene by name: `./build.sh scenes NAME` (the log says the script line it stopped at) | its own time |
| A change to an `@all` file (the build, `vendor/`, the runner) or a large refactor | `./build.sh scenes --all` | ~3 min + the build |
| Release | `./build.sh test`, `./build.sh scenes --all`, then [Releases](DEVELOPING.md#releases) | ~4–5 min |
| By hand, never in CI | the [paid scenes](#paid-real-pi-never-from-the-runner) and the [by-hand checks](#by-hand-no-scene) | |

**What `--changed` selects** (`--list` prints it with a reason per scene): the scenes whose areas
hold a changed file, plus the smoke set. A change to an `@core` file (the main loop, commands,
state, the terminal and its stream, the socket, persistence) adds the required scenes and every
scene whose name its changed lines (or the `case` and proc around them) mention: an edit in
`commands.odin`'s `case Worktree_Remove:` runs `worktrees`. A core change over 300 lines, or any
`@all` file, runs everything. `tests/scenes_test.py` checks the selection.

**`./build.sh scenes`** builds first when needed (`./build.sh`, `./build.sh fake-app`; each only
when an input is newer than its output or the input list changed: `build/<output>.inputs`;
`--build` forces it), then runs `tests/scenes.py` with the same arguments. Selections: scene names,
`--area src/native` (scenes covering a path), `--required`, `--changed`, `--all`, `--list`.
`--no-build` skips the build, but each scene still refuses a stale `build/deckhand`
(`tests/scripts/fresh-build.sh`).

**Core mode.** Scenes run with the app's default, a separate core (`deckhand-core-serve`).
`--in-process` runs them with the core in the window's process (`DECKHAND_SEPARATE_CORE=0`, the
setting's opt-out). `--separate-core` forces a separate core and leaves out scenes tagged `inproc`
(those that test the window process's own core loop, such as `hidden-window`).

**CI.** `ci.yml` (every pull request and push to main; docs-only changes skip it, except
`docs/GUIDE.md` and `docs/PROTOCOL.md`, which the build reads):
- `holder-rev`: the holder's code changed only with a `HOLDER_REV` bump;
- `core-boundary`: the core and holder link no window code;
- `unit`: `./build.sh test`;
- `linux`: the core and the session holder built on Ubuntu, their wire, trust, holder and core unit
  tests, then `tests/linux-core-smoke.py` (also `--default-dirs`), `tests/linux-holder-smoke.py`
  (also `--systemd`) and `tests/linux-systemd-check.sh --real`
  ([the Linux core](DEVELOPING.md#building-the-linux-core));
- `scenes`: the required scenes, separate core, in four shards, two at a time per runner.

`release-linux.yml` builds the Linux release tarball and installs it once
(`tests/linux-release-check.sh`).

`scenes-full.yml` (nightly and on demand, **Actions › Scenes (full) › Run workflow**): required +
full in four shards, where a full-tier failure is only a warning; the required scenes
`--in-process` in two shards (also on every push to main); and the strict time budgets as a report.
Neither runs paid scenes, manual tools, or scenes tagged `noci`. A scene moves to the required
tier once it has passed in the nightly run a few times.

## Test layers

All of these run in `./build.sh test`.

| Layer | What it protects | Time |
|---|---|---|
| `tests/abi_sizes.c` + `tests/ghostty_test.odin` | the hand-written libghostty-vt bindings: sizes, offsets, enum values, one pass through the calls | <1 s + compile |
| `tests/cef_popup_slots_test.c`, `tests/cef_polish_pure_test.c` | the CEF shim's popup slot matcher and the tab polish helpers | <1 s |
| `tests/browser_act_js_test.mjs`, `tests/browser_read_js_test.mjs` (node) | the page scripts on a fake DOM: the sensitive-field rule, frames, shadow slots | <1 s |
| `integrations/pi` tests (`node --test`) | the bundled pi integration, without running pi | ~1 s |
| `src/holderwire`, `src/corewire`, `src/trust` | the holder wire and the window/core wire (golden vectors, fuzz, transports); who may talk to whom | seconds |
| `src/holder` | the holder in process with a fake core, and the upgrade with real processes (`build/deckhand-core-hooks`: re-execs under load, refusals, the keeper adopting) | seconds |
| `scripts/check-core-boundary.sh` and its test | the core and holder link no window code | <1 s |
| `src/*_test.odin`, `src/core/*_test.odin` (`tests/unit.py`) | the command layer: every command, callers, confirmations, persistence, the socket, the replica, quit routes, idle exit, Claude and pi launches, jobs, the editor, the layout audit, the docs listing every action and command; other machines (`machines*_test`, `machine_install_test`, `machine_page_test`, `machine_route_test`, `machine_mirror_test`, `remote_view_test`, `machine_rows_test`, `machine_header_test`); what needs you and the views over it (`needing_you_test`, `attention_view_test`, `fleet_test`, `deck_view_test`, `deck_modal_test`, `peek_test`, `status_marks_test`, `flash_test`); `keyboard_pack_test`, `pane_motion_test`, `border_draw_test`, `handoff_test` | ~30–40 s on 6 processes |
| `tests/scenes_test.py`, `scripts/check-env-reads.py` | the `--changed` selection; every environment read names a known variable | <1 s |
| `tools/deckhand-cli` tests | the `deckhand` CLI: arguments, hooks, the MCP server | <1 s |
| the fake app (`tests/fake-app`) | builds the app-tab stand-in the scenes need | ~5 s |

The unit tests share the global `State`, so each process runs one thread. `tests/unit.py` runs one
process per source file, at most half the CPUs (max 6; `UNIT_JOBS=1` for one at a time), each with
its own short `TMPDIR`. It fails when a test fails, and when the number of tests that ran differs
from the number of `@(test)` procs, so a test can't silently drop out. Logs: `build/unit/`. Every
test process makes and removes its own temp folder (`src/core/tmpdir_test.odin`).

## Scenes

Tiers: **required** = every pull request; **full** = `--all` and nightly; **manual** = run by name
only; **paid** = real pi, never from the runner. Tag **smoke** = also in every `--changed` run.
Typical times and tags are in `tests/scenes.txt`; each script's header says what it checks.

### Required

| Scene | Protects |
|---|---|
| `menus` | every right-click menu row's effect or refusal |
| `menu` (smoke) | the menu bar: items, key equivalents, enable and check rules, the shortcuts sheet |
| `jobs` | Atlas's jobs: every run outcome, limits, redaction, the run environment (no socket or tokens), no Keychain code |
| `setup` | the first-run sheet: vault detection, folders made, `PI_KIT_NOTES_DIR`, the Claude accounts step |
| `markdown` | the Markdown tab: preview and source, find, live reload, links (external never opened), the built-in guide |
| `settings` | Settings as files: the allowlist, credential files never shown, a dummy secret never drawn or logged |
| `projects` | the Projects tree: repos, `_scratch` groups, nesting, hidden temp and missing folders, restore |
| `restore` (smoke) | workspace save and restore through quit, lazy session start, a 20-session launch |
| `term-links` (smoke) | terminal links: ⌘-hover and click, OSC 8, wrapped URLs, `javascript:` refused |
| `panes`, `panes-capture`, `panes-drag`, `panes-restore` | split panes: splits, focus, dividers, pointer capture, dragging tabs, restore |
| `no-window` | the core with no window: commands a window hosts answer `no_window`, the rest still answer |
| `fail-fast-test` | a failed script line fails its scene, with and without fail-fast |
| `fetch-cef-test` | `scripts/fetch-cef.sh`: a bad archive deleted, concurrent fetches |

### Full (nightly, `--all`)

| Scene | Protects |
|---|---|
| `two-process` | a separate core: the window launches it, attaches, closes; the core and a shell run on; a second window shows the same terminal |
| `window-attach` | the window killed during a pi turn (the turn runs on); the core killed (the window relaunches one, which adopts from the holder) |
| `holder-stall` | the core stopped (SIGSTOP) past the holder's 30 s pong timeout, as a sleep or a long stall would (#108): once continued it attaches to the same holder again; its pi tab still runs, same process, input and output through it, nothing started twice |
| `handover` | a core handed over to another: same holder and session pids, terminals exact from the snapshot, a job run finished, no secret in any log; the supervisor relaunches a killed core |
| `keep-sessions` | the holder through a quit, a kill -9 of the app and of the holder; Stop All; *Restart session holder* in place |
| `hidden-window` (`inproc`) | the core loop while the window is hidden: output, the bell and exits still land; a quit while hidden |
| `reload-separate` | pi hot reload with a separate core: the window's watcher feeds the core |
| `sign-dr` | the DR checks with real signatures (skipped without the identity) |
| `browser-a` … `browser-g` | browser tabs (rendering, input, focus, popups, comment mode, agents reading and acting, navigation, restore, split panes); every socket loopback only |
| `browser-rlz` | Chromium never touches Google Chrome's files during a 100 s idle |
| `browser-netpolicy` (`noci`) | which hosts Chromium's own services try: Safe Browsing only |
| `app-tab`, `app-calls`, `app-open` | app tabs: frames, input, resize, crash, restart; `app_call` under load; an agent opens only its project's declared app |
| `comments` | pending comments from a page and the fake app reaching the agent |
| `claude`, `claude-accounts`, `claude-feeds`, `claude-runtime`, `claude-sessions`, `claude-wait` | Claude Code tabs with a fake claude running the plugin's hooks and CLI ([CLAUDE.md](CLAUDE.md)) |
| `codex` | Codex tabs with a fake codex that checks Deckhand's command line (`--no-daemon`, the hooks' TOML and trust hashes) and runs its hooks at the first prompt; signed out, too old ([CODEX.md](CODEX.md)) |
| `agent`, `run-home`, `agent-show`, `agent-status`, `panels`, `bell` | Atlas's drawer, show a file, OSC 7501 status, right-column panels, the bell |
| `pi-chat-start` (smoke) | every start of a chat's pi is full pi with the bundled integration and `DECKHAND_*` |
| `reload`, `dead-tab` | pi hot reload; a pi tab that exited |
| `changes`, `files`, `files-nested`, `worktrees`, `editor`, `sidebar` | the Changes tab, the Files tab, worktrees, the editor, the left column |
| `polish`, `polish-beep`, `buttons` | palette, title bar, text input; no AppKit beep; every button |
| `login-path`, `fish-shell`, `pi-login-lookup`, `harness-setup` | the GUI launch environment, non-POSIX shells, finding pi, the coding agents checklist |
| `update`, `release-checks` | self-update from local fixtures; `release.sh`'s and `update-sign`'s refusals |
| `remote-link`, `remote-sidebar`, `remote-terms`, `remote-page`, `remote-install`, `remote-atlas` | other machines, with a second core on this Mac reached through `--via` (no ssh or sshd: `DECKHAND_HUB_WITHOUT_SSHD=1`): the link, online and offline; its sessions in the sidebar; its terminals relayed; a machine's web page in a local tab; install and one-click update; Atlas and jobs across machines. Real `ssh` is not covered |

### Manual (tools, not tests: run by name)

They take screenshots or print numbers for a person to read. They never run in CI and don't count
as coverage.

| Scene | What it is for |
|---|---|
| `looks`, `font`, `shots`, `text-shots`, `readme-shot` | screenshots (`readme-shot` makes the README's clip and `docs/images/deckhand.png` from demo data: check them by eye; it needs Screen Recording for the app that runs it) |
| `persist-cpu`, `panels-cpu`, `text-flood`, `run-frame-pause`, `term-bench` | CPU, frame and terminal-stream numbers to read |
| `update-from-release` | the current release's updater installs a new zip (`release.sh` runs it) |

### By hand (no scene)

Checked by a person before a release that touches them:

- **The minimised window:** minimise during a pi turn, restore: the output is there, and a toast
  raised meanwhile shows after.
- **Dock › Quit** and `osascript -e 'quit app "Deckhand"'`: as ⌘Q; `pgrep -fl deckhand-core-serve`
  still shows the core.
- **Logout** and restart: everything saves and exits; the next launch restores.
- **Force Quit** (⌥⌘⎋) of the window and of Deckhand Core; macOS 14 and 15.

### Paid (real pi, never from the runner)

| Scene | Protects |
|---|---|
| `bridge-e2e` | real pi with the bundled integration publishes panels (a tool for now: its shells-panel check needs pi-kit) |
| `home-e2e` | Atlas as a real pi with the desk tools |
| `text-pi` | text rendering of a real pi screen (shots) |
| `looks-real` (`LOOKS_PI=real looks.sh`) | real pi re-themes on a look switch |

## Running scenes in parallel

Each scene has its own work folder (`build/<scene>/`), fake HOME, data dir and runtime dir, so most
run side by side. What they share, and how the runner keeps them apart (tags in `tests/scenes.txt`):

- **`test-data`**: scenes with no `DECKHAND_DATA_DIR` share `build/test-data`: one at a time.
- **`test-trash`**: test mode's Trash, `build/test-trash`: one at a time.
- **`cef`**: each Chromium scene holds 0.6–1.1 GB: at most `--cef-jobs` at a time (3 on a Mac with
  10+ CPUs, else 1).
- **`idle`**: `browser-rlz` and `browser-netpolicy` sit idle on purpose; they take no `-j` slot (at
  most two at a time), but still a Chromium slot.
- **`alone`**: benchmarks run with nothing beside them.
- **The clipboard**: a script's copies and pastes use the app's own pasteboard. Only a page in
  Chromium writes the system one.

Concurrency: `-j 8` on a Mac with 10+ CPUs, 4 with 8+, 2 otherwise (`SCENE_JOBS`, `SCENE_CEF_JOBS`).
A memory budget (`--mem-gb`, `SCENE_MEM_GB`, default 3.5 GB of total RSS) holds a scene back while
it would pass the budget. All scenes are in the runner's process group, so a timeout on the runner
reaches them.

The runner retries a failed scene once and reports one that then passes as **FLAKY** (first log
kept as `build/scenes/<scene>.1.log`); it doesn't fail the run unless `--strict`. Logs:
`build/scenes/<scene>.log`, summary `build/scenes/summary.txt`, last times
`build/scene-times.json` (longest first).

**Failing fast.** A scene stops at its first failed check, wait or missing element: the app logs
`ASSERT FAILED (stopped at line N of SCRIPT…)` (or `TIMEOUT` for a wait) and exits 1
(`DECKHAND_SCRIPT_FAIL_FAST=1`, set by the runner and `fresh-build.sh`; `--no-fail-fast` runs every
line, to see all of a new script's failures at once). The runner kills a scene after 3× its typical
time, at least 120 s (`--timeout` for all), and doesn't retry it. `--max-minutes`
(`SCENE_MAX_MINUTES`) is the whole run's budget: past it no scene starts (**NOT RUN**, a failure),
so the summary always prints. Each script line goes to `build/scenes/<scene>.step` as it starts, so
a killed scene's row says where it was.

## Waits

A scene script waits in three ways (commands: the top of `src/autotest.odin`):

- **Until something happens:** `waitfor TEXT`, `waitstate MS PATH VALUE`, `waitresult MS PATH
  VALUE` (runs the read-only `command` before it again until it matches), and `eventually [MS]`
  (the checks right after it are retried every frame, up to 10 s). They cost what the app takes.
- **Element lines wait for the layout:** `clickid`, `rclickid`, `hover`, `clickmenu`… wait for a
  frame drawn after the last input, and up to 5 s for an element not laid out yet.
- **`wait MS`**, a fixed sleep, only where time itself is tested: something must *stay* as it was,
  a script's first line, CPU and frame windows, idle periods, and the input guards that refuse a
  click too soon (`BAR_GUARD` 300 ms, `BARS_GUARD` 500 ms, `TIP_DELAY` 500 ms).

To turn fixed waits into `eventually` in a new script: run its scene with `DECKHAND_WAIT_AUDIT=1`,
then `tests/wait_audit.py --apply build/<scene>/*.log` and review the diff. It converts a wait only
when every check after it failed before the wait and passed after it in every run seen; it never
converts a script's first wait, a wait before an action, or one before a negative check.

## Timing tests

Time budgets report; they rarely gate. They are there to catch an accidentally quadratic change,
not a few percent: under load single runs are 2–3× slower, CPU time too.

Every budget goes through `perf_expect` (`src/core/cpu_clock_test.odin`). It prints
`PERF label: took X (budget Y)`; over the budget it prints `PERF OVER BUDGET …`, which
`tests/unit.py` lists as a warning. The test fails only past **10×** the budget, or **3×**
(`PERF_GATE_USER`) for what a user waits on: a key typed and a 50k-line file opened
(`editor_perf_50k`), a 1 MB Markdown file parsed. `tests/unit.py --perf-strict`
(`DECKHAND_PERF_STRICT=1`) fails at the budget itself, for a quiet machine. The nightly `perf` job
and `release.sh` run `--timing-only --perf-strict` as a report.

| Test | Measures | Budget |
|---|---|---|
| `markdown_parse_1mb` | CPU time, best of 5 | 50 ms (150 on CI); gate 3× |
| `markdown_layout_pathological` | CPU time | 50 ms per 16 KB case, 1 s per 200 KB |
| `markdown_html_pathological`, `markdown_pathological` | CPU time | 1 s; 2 s per case |
| `reload_burst` | CPU time | 20 ms (20k events), 5 ms (the report) |
| `editor_perf_50k` | CPU time | 2 s open, 50 ms a key; gate 3× |
| `syntax_large_parse` | CPU time | 50 ms reparse |
| `buffer_large_file` | CPU time | 200 ms index, 500 ms edits |

Waits on fake processes are deadlines, not budgets: generous (20 s), and no slower when they pass.

## Flakes

The causes seen so far, and the rule each one taught:

- **Wall-clock limits under load.** Measure CPU time, run timing tests alone, gate only at 10×.
- **Fixed waits on a fake process** (a fake app's start, a fake shell, a commit landing). Wait for
  the condition with a generous deadline, or for the last line the fake prints, not the first.
- **State left by the previous test** (late git results landing on the next test's editor). Wait
  for in-flight work in setup, and keep ids increasing across tests.
- **Shared system state** (the system pasteboard, a `$TMPDIR` sweep). Keep it per scene.
- **Order that depends on the clock** (commits in the same second). Give fixtures fixed dates.
- **Rows found by position.** Use `clickid`/`rclickid NAME @PATH`, so a new row above can't move it.
- **A fake's writes in the wrong order** (argv before env). Write what the test reads last.
- **A file watcher's backlog.** A scene that makes 10,000 files just before the app starts queues
  their FSEvents ahead of everything after; under load they took over 10 s to drain, and the Files
  tab of a separate core's window waited behind them for Deckhand's own New file, rename and
  delete (`files`, `menus`). Deckhand's own changes now reach the window at once
  (`window.request` `path_changed`); a script waits for a condition, never a fixed time.
- **A file written while another test thread forks** (the holder tests): a child that never
  execs keeps the write fd, and on Linux an execve of that file fails with ETXTBSY. Write
  executables under `fork_lock`.

A failure seen once and not reproduced (`browser-slots`' stray UDP socket, `browser-rlz`'s access
times) is left to the runner's **FLAKY** report.

## Open clean-ups

1. The screenshot tools `shots`, `font` and `looks` overlap; one before/after tool would do.
2. `bridge-e2e`: fix or rewrite. Its shells-panel check needs pi-kit's shell extension, which is
   not bundled.
3. `app-calls`' default-scale check repeats `test_scale_test.odin` (harmless, a few seconds).
4. Stale pi-kit wording in test comments (`fake-bridge.sh`, `home_test.odin`, `reload_test.odin`,
   `buttons_test.odin`).
