# Testing Deckhand

Every test layer and every test-mode scene, what it protects, what it costs and when it must
run. The scene list itself (areas, tiers, tags, typical times) lives in one data file,
[`tests/scenes.txt`](../tests/scenes.txt), which the runner reads; this page explains it. How
test mode works and what each scene's fixtures look like: [DEVELOPING.md](DEVELOPING.md#test-mode-and-scenes).

## Contents

1. [What to run](#what-to-run)
2. [Test layers](#test-layers)
3. [Scenes](#scenes)
4. [Running scenes in parallel](#running-scenes-in-parallel)
5. [Waits](#waits)
6. [Timing tests](#timing-tests)
7. [Flakes](#flakes)
8. [Candidates to delete or rework](#candidates-to-delete-or-rework)
9. [Measurements](#measurements)

## What to run

| When | Command | Time (dev Mac) |
|---|---|---|
| Every change | `./build.sh test` (all unit layers) | ~1 min |
| Every change that touches the app | `./build.sh scenes --changed` (the scenes whose areas hold a changed file, plus the smoke set) | 1–10 min, by what changed |
| Before merging something broad, or an `@all` file | `./build.sh scenes --all` | ~3 min + the build (~25 min one scene at a time) |
| Release | `./build.sh test`, `./build.sh scenes --all`, the release steps in [DEVELOPING.md](DEVELOPING.md#releases) | |
| By hand, never in CI | the paid scenes (real pi, billed): `bridge-e2e.sh`, `home-e2e.sh`, `text-pi.sh`, `LOOKS_PI=real looks.sh` | |

`./build.sh scenes` builds once (`./build.sh`, `./build.sh fake-app`) and then runs
`tests/scenes.py` with the same arguments. Other selections: scene names
(`./build.sh scenes menus jobs`), `--area src/native` (the scenes covering a file or folder),
`--required` (what CI gates pull requests on), `--list` (what would run and why, without
running). `--no-build` skips the build; each scene still refuses a stale `build/deckhand`
(`tests/scripts/fresh-build.sh`: any source, CLI or bundled-integration file newer than the
binary; `*_test.odin` files are not in the binary and do not count).

CI: `ci.yml` (every pull request and push to main) runs `./build.sh test` and the required
scenes in two shards; `scenes-full.yml` (nightly, on demand) runs required + full in four
shards, where a full-tier failure is a warning. Neither ever runs a paid scene, a manual
tool, or a scene tagged `noci`.

## Test layers

| Layer | What it protects | Time | When |
|---|---|---|---|
| `tests/abi_sizes.c` + `tests/ghostty_test.odin` (`odin test tests`, 4 tests) | the hand-written libghostty-vt bindings: struct sizes, offsets and enum values against the C compiler, and one pass through the calls Deckhand makes | <1 s (+ compile ~5 s) | every change (binding or vendor/ghostty changes above all) |
| `tests/cef_popup_slots_test.c` | the CEF shim's popup slot matcher: a popup lands in its opener's tab whatever order CEF creates or aborts them | <1 s | every change |
| `tests/cef_polish_pure_test.c` | the tab polish shim's pure helpers (`src/native/cef_polish_pure.h`) | <1 s | every change |
| `tests/browser_act_js_test.mjs` (node) | `browser_act.js` on a fake DOM: the sensitive-field rule, which targets text keys may go to, iframes, file inputs | <1 s | every change (needs node) |
| `tests/browser_read_js_test.mjs` (node) | `browser_read.js`'s page walk: frames, boxless containers, shadow slots | <1 s | every change |
| `integrations/pi` tests (`node --test`) | the bundled pi integration (bridge, panels, desk tools) without running pi | ~1 s | every change |
| `src/*_test.odin` (`tests/unit.py`, ~800 tests in ~70 processes) | the command layer: every command, caller rules, confirmations, persistence, the socket, Claude and pi launch arguments and environment, jobs, the editor, the layout audit (no overlapping text at 4 widths × every look × light/dark), the docs listing every action and command | ~30–40 s on 6 processes incl. the build (~2 min 15 s on one) | every change |
| `tools/pi-desk-cli` tests | the `deckhand` CLI the Claude Code plugin runs: argument parsing, the read-only guard (`tests/readonly-vectors.json`) | <1 s | every change |
| `odin build` of the fake app (`tests/fake-app`) | builds the app-tab stand-in the scenes need | ~5 s | every change |
| Scenes (`tests/scenes.py`, below) | the real app end to end, in quiet test mode, with fakes | see below | by area; `--all` before broad merges |

`src/*_test.odin` share the global `State`, so each process runs one thread. `tests/unit.py`
gets its speed from processes: one per source file (the four `layout_no_overlap_N` parts get
one each), at most `-j` at a time (half the CPUs, at most 6; `UNIT_JOBS=1` for one at a time),
each with its own `TMPDIR` under `/tmp` (short enough for the control socket's path). It
fails when a test fails and when the number of tests that ran differs from the number of
`@(test)` procs in `src/*.odin`, so a test cannot silently drop out. Logs: `build/unit/`.

Temp folders: under `odin test` (`src/tmpdir_test.odin`) every test process makes one folder
(`dkt-XXXXXX`, in `$TMPDIR` when its path is short, else `/tmp`), points `TMPDIR` at it and
removes it at exit, so running `odin test` by hand leaves nothing behind either. The
`integrations/pi` tests keep theirs in one `deckhand-test-XXXXXX` folder each, removed at exit.
Scenes make their folders under `build/<scene>/`; their runtime dirs (`mktemp`) are removed by
the scripts' traps. A crash can still leave one folder.

## Scenes

Columns: what the scene protects; its serial time on a dev Mac (measured under load, see
[Measurements](#measurements)); flags: **dup** (largely repeats another scene or unit test),
**leftover** (tests renamed or moved behaviour), **shots** (screenshots, little or nothing
asserted). The tier (when it must run) is the section the scene is in. Areas and tags are in
`tests/scenes.txt`.

Tiers: **required** = every pull request; **full** = `--all` and nightly; **manual** = run by
name only; **paid** = real pi, never from the runner. Tag **smoke** = also part of every
`--changed` run.

### Required

| Scene | Protects | Secs | Flags |
|---|---|---|---|
| `menus` | every right-click menu row's effect or its refusal toast (session rows, sort, projects, "+", Files, editor, worktrees, Settings, jobs) | 106 (35 in parallel) | |
| `jobs` | Atlas's scheduled jobs: every run outcome, limits, redaction, the run environment (no socket or tokens), no Keychain code, ATLAS.md move | 78 | |
| `setup` | the first-run sheet: vault detection, folders made, `PI_KIT_NOTES_DIR`, the Claude accounts step | 41 | |
| `markdown` | the Markdown tab: preview/source, find, live reload, links (external never opened), the built-in guide | 30 | |
| `settings` | Settings as files: the allowlist, credential files never shown or opened, a dummy secret never drawn or logged | 21 | |
| `projects` | the Projects tree: repos, `_scratch` groups, nesting, hidden temp/missing folders, restore | 19 | |
| `restore` | workspace save/restore through quit, lazy session start, a 20-session launch | 13 | smoke |
| `menu` | the menu bar: items, key equivalents, enable/check rules, text size, the shortcuts sheet | 11 | smoke |
| `term-links` | terminal links: ⌘-hover/click, OSC 8, wrapped URLs, `javascript:` refused, opening only logged | 7 | smoke |
| `panes` | split panes: ⌘D and ⇧⌘D with a new shell, typing per pane, ⌃⌘arrows and click focus, a pane divider's drag and its minimum (the shells' columns follow), ⇧⌃⌘arrows, a pane's last tab closing, ⇧⌘W | 9 | |
| `panes-capture` | pointer capture: a selection pressed in one pane's terminal (and editor) and released over another stays in the first; that pane has the keyboard | 6 | |
| `panes-restore` | split panes across a quit and relaunch: the tree, its ratios, each pane's tabs and shown tab, the focused pane, every shell sized to its pane | 6 | |
| `fetch-cef-test` | `scripts/fetch-cef.sh`: a bad archive deleted, concurrent fetches, a stale tree not reused | 13 | not an app scene |

### Full (nightly, `--all`)

| Scene | Protects | Secs | Flags |
|---|---|---|---|
| `browser-a` … `-f` | the browser tab (24 scripts in six groups of ~35–45 s): rendering, input, polish (downloads quarantined, zoom, guards), focus, keys, popup slots, close/release, the frame ring on both paint paths and a slow GPU, comment mode, agents reading and acting on pages, navigation, popups, restore; every socket of every run is loopback only; the profile is 0700 | ~230 | |
| `browser-g` | pages and apps live in every pane (split panes P4): a page beside the pi tab's pane paints, is not hidden, gets no keys, its view is its pane's (a divider drag resizes it), a click gives its pane the keyboard, an agent's screenshot says on screen; the fake app beside a page frames on, is never told hidden, takes clicks at its own coordinates and keys once focused, and gets a ring of its new pane size | ~30 | |
| `browser-rlz` | Chromium never reads or writes the Google Chrome files in the home folder (RLZ, brand, enrollment, Skia, Local State) during a 100 s idle | 105 | idle by design (an RLZ ping was once seen at ~80 s) |
| `reload` | pi hot reload: settings/extension edits, queued reloads, version bump restart offer | 62 | |
| `changes` | the Changes tab: list, diffs, stage/unstage, discard to the (test) Trash, commit with the user's hook | 49 | |
| `polish` | command palette, blended title bar, text input | 45 | |
| `claude-sessions` | Claude-only sessions: picker, rows, menu, resume, model in tooltip, no Claude Code installed | 40 | |
| `bell` | the notification centre: entries, OS notification stub, read marks, toggles, narrow widths | 38 | |
| `buttons` | every button clicked, tooltips from the action table, idle CPU with a tooltip | 38 | partial dup: `buttons_test.odin` |
| `claude-feeds` | Claude status from hooks, background work, subagent tools, the old-version and no-hooks bars | 38 | |
| `claude-runtime` | Claude bars: CLAUDE.md edited → restart, update → restart, Settings groups, Restart with model | 37 | |
| `files` | the Files tab end to end, a 10k-file folder, the (test) Trash, restore | 37 | |
| `files-nested` | a project's tree with folders that are their own repositories and projects, a symlinked folder and an unlistable one (says why, with Retry) | ~20 | |
| `harness-setup` | the coding agents checklist (setup sheet and Settings): installed, missing (Install runs a stand-in; sudo refused), too old (Update), nix/mise (shown only) | ~40 | |
| `editor` | the editor in a git project: typing, undo, save, the right-click menu, outside changes (reload or banner), a dirty close, a 50k-line file, restore | 21 | |
| `claude-readonly` | read-only Claude chats: the profile, the guard's denials, Deckhand refusing act verbs, restore | 36 | |
| `claude` | Claude Code tabs with a fake claude running the plugin's hooks and CLI: browser and app tabs, tokens, held text, comments, resume, restart; no Claude session markers leak into tabs | 36 | |
| `worktrees` | the checkout switcher: worktrees and branches, Clean up, restore | 35 | |
| `sidebar` | the left column: add project, pin, sort, filter, hide, dividers, restore | 35 | |
| `agent-status` | OSC 7501 agent status for any terminal tab: handshake, dots, malformed input, unread/seen | 33 | |
| `app-tab` | app tabs: frames over IOSurface, input, resize, stall, crash, restart | 28 | |
| `login-path` | the GUI-launch environment: bare PATH, failing shell, no pi, Nix-like PATH, Claude markers | 26 | |
| `app-calls` | app_call under load at app start: every call finishes, hello reply first, default scale | 24 | its scale check repeats `test_scale_test.odin` |
| `update` | self-update from local fixtures: bar, skip, download, signature check, swap, old bundle kept/removed | 24 | |
| `pi-login-lookup` | pi on a login-shell-only PATH with a hanging interactive shell still counts as installed | 23 | |
| `browser-netpolicy` | which hosts Chromium's own services try: Safe Browsing only | 25 | `noci` (depends on the machine's network setup) |
| `comments` | pending comments from a page and the fake app's Inspect boxes reaching the agent | 19 | |
| `agent` | Atlas in its drawer: model, prompt, the integration's `-e` paths and `DECKHAND_*` variables, pin, Settings group | 18 | |
| `panels` | right-column panels and status dots from a fake bridge | 18 | |
| `claude-accounts` | Claude Code accounts found on disk, the per-account picker, resume under the right `CLAUDE_CONFIG_DIR` | 15 | |
| `run-home` | the agent drawer's keys, buttons, palette and closing sessions (`run.sh home.txt`) | 15 | partial dup: `agent`, `home_test.odin` |
| `dead-tab` | a pi tab that exited: the bar, Restart, Restart with model, every way of reopening | 13 | partial dup: `dead_tab_test.odin` |
| `claude-wait` | Atlas's wait on a Claude tab whose status lags its Stop hook | 8 | |
| `polish-beep` | no AppKit beep for keys Deckhand handles; the macOS line-editing keys reaching a shell through AppKit's `keyDown:` (`polish.sh beep.txt`) | ~8 | |
| `pi-chat-readonly` | read-only pi chats get pi's allowlist and `PI_KIT_READONLY=1`; every start gets the bundled integration and `DECKHAND_*`, never pi-kit's `PI_DESK_*` | 6 | smoke |
| `fish-shell` | a fish login shell never gets an sh script; pi, Claude and shell tabs still start | 6 | |
| `agent-show` | a session's pi (fake bridge) and Claude (fake, `deckhand show`) show the user a .md (Markdown tab) and a .txt (editor tab) in their own session, after their tab, behind the view; other sessions and binary files refused | 6 | |
| `app-open` | a session's agent opens its project's declared app, and only its own | 3 | |
| `release-checks` | `release.sh`'s and `update-sign`'s refusals (dirty tree, wrong tag, wrong key, rotation) | 2 | not an app scene |

### Manual (tools, not tests: run by name)

These are kept as tools: they take screenshots or print numbers for a person to read, and
assert little or nothing. They never run in CI and do not count as coverage.

| Scene | What it is for | Flags |
|---|---|---|
| `looks`, `font`, `shots`, `text-shots`, `readme-shot` | screenshots of the looks, the UI font, the chrome (before/after pairs), text rendering, the README image | shots: nothing (or almost nothing) asserted; `looks`, `font` and `shots` overlap |
| `persist-cpu`, `panels-cpu`, `text-flood`, `run-frame-pause` | CPU and frame numbers to read by eye (`run-frame-pause` needs the window shown) | benchmarks: nothing asserted |

### Paid (real pi, never from the runner)

`bridge-e2e` is kept as a tool, not a test, until it is fixed (below); the others check real
pi by hand before a release.

| Scene | Protects | Flags |
|---|---|---|
| `bridge-e2e` | real pi with the bundled integration connects and publishes panels | tool, not a test; leftover: its shells-panel assert needs pi-kit's `bash_bg`/`shell_stop`, which stayed in pi-kit (HARNESSES.md §8); likely fails without pi-kit |
| `home-e2e` | Atlas as a real pi with the desk tools (`desk_state`) | |
| `text-pi` | text rendering of a real pi screen | shots only |
| `looks-real` (`LOOKS_PI=real looks.sh`) | real pi re-themes on a look switch | mostly shots |

## Running scenes in parallel

Each scene has its own work folder (`build/<scene>/`), fake HOME and data dir, so most can run
side by side. What they share, and how the runner keeps them apart:

- **`build/test-data`**: scenes that set no `PI_DESK_DATA_DIR` use it as their data dir, so
  they would take each other's single-instance lock (`instance.lock`) and several
  `rm -rf` it. Tag `test-data`: one at a time.
- **`build/test-trash`**: test mode's Trash (`fs_model.odin`); `jobs.sh` empties it and
  `files`/`changes`/`jobs` check it. Tag `test-trash`: one at a time.
- **Chromium** (`cef`): each CEF scene uses its own profile under its data dir (no shared
  singleton or port), but each holds 0.6–1.1 GB (the renderer up to 600 MB, the GPU and other
  helpers ~280 MB, Deckhand ~200 MB; a non-Chromium scene ~170 MB): `--cef-jobs` at a time
  (default 3 on a Mac with 10+ CPUs, else 1). `browser.sh --group a…f` splits the browser
  scripts into six groups of ~35 s, each in its own folder (`build/browser-<g>/`).
- **`idle`**: `browser-rlz` (100 s) and `browser-netpolicy` (20 s) sit idle on purpose. They
  take no `-j` slot (at most two at a time), but still a Chromium slot.
- **The control socket**: per process (`pi-desk-<pid>.sock`) in the runtime dir; scenes that
  look at the runtime dir set their own `PI_DESK_RUNTIME_DIR`. No ports are opened.
- **Screenshots**: `build/shots/<scene>/`, one folder per scene.
- **The clipboard**: under a script the app's copies and pastes use a pasteboard of its own
  (`autotest.pasteboard`), never the system's: one scene's copy cannot replace another's, nor the
  user's own clipboard. Only a page (Chromium) writes the system pasteboard: `browser-act`, which
  checks what its page wrote, so another run's page copy at that moment could still collide.
- **`alone`**: CPU and frame benchmarks run with nothing beside them.

The runner retries a failed scene once and reports one that then passes as **FLAKY**, with
the first log kept as `build/scenes/<scene>.1.log`; it does not fail the run (`--strict` makes
it). Logs: `build/scenes/<scene>.log`, summary: `build/scenes/summary.txt`, last times:
`build/scene-times.json` (used to start the longest first).

Concurrency: `-j 8` on a Mac with 10+ CPUs, 4 with 8+, 2 otherwise (`SCENE_JOBS`, `SCENE_CEF_JOBS`
to change; CI sets 2 and, with fewer than 10 CPUs, gets one Chromium at a time). A memory budget
(`--mem-gb`, `SCENE_MEM_GB`, default 3.5 GB of total RSS, as a memory guard counts it) holds a
scene back while what runs, plus what the scenes started in the last 20 s may still grow to, plus
the new one (busy Chromium 1.0 GB, idle 0.6, other 0.2) would pass it: three Chromium scenes at
their peak (0.6–1.1 GB each) beside five others once passed 4 GB without it. All scenes of a
run are in the runner's process group, so a memory guard or CI timeout on the runner reaches
them. Measured peak: see [Measurements](#measurements).

## Waits

A scene script waits in three ways (commands: the top of `src/autotest.odin`):

- **Until something happens**: `waitfor TEXT`, `waitstate MS PATH VALUE`, `waitresult MS PATH
  VALUE` (runs the read-only `command` before it again, e.g. `changes_list` until a commit
  shows), `eventually [MS]` (the checks right after it are tried again every frame until each
  passes, up to 10 s, then fail as before). They cost what the app takes, no more.
- **Element lines wait for the layout**: `clickid`, `rclickid`, `hover`, `clickmenu`… read where
  the last layout put the element, so they wait for a frame drawn after the last input, and up
  to 5 s for an element (or menu row) not laid out yet. The same `clickid` line twice in a row
  is still a double-click.
- **`wait MS`**, a fixed sleep, only where time itself is what is tested or needed: a check that
  something *stays* as it was (nothing may happen within the wait), a script's first line (the
  app settling after its start), CPU and frame windows, idle periods (`browser-rlz`), and the
  input guards that refuse a click too soon after a change: `BAR_GUARD` (300 ms, the
  confirmation bar), `BARS_GUARD` (500 ms, the browser tab's bars), `TIP_DELAY` (500 ms).

`shot` takes the screenshot once the raised window has drawn 3 frames (at least 150 ms; it was a
fixed second).

**How fixed waits are converted.** `PI_DESK_WAIT_AUDIT=1` makes the app log,
for every `wait` followed by checks, whether each check already held before the line ahead of
the wait ran (A), when the wait began (B) and after it (C). `tests/wait_audit.py LOG...` reads
those logs and turns a `wait` into `eventually` only when every check after it failed at A and
passed at C in every run seen: the wait was needed for those checks to *become* true, so
polling for them cannot pass before the change happened. Kept as fixed waits: a check that
already held at A (it may check that something stays), a check that something is not there
(`assert_not_*`, `-`, an empty `assert_tip`), a check `eventually` does not retry (`web_*`,
`act_assert`, `app_*`…), a script's first wait, and every wait followed by an action. Also
dropped: the wait between `rclickid` and `clickmenu` (the menu opens in the click's own event).
Result: 476 waits became `eventually`, 77 were dropped, 184 kept. To convert waits in a new
script the same way: run its scene with `PI_DESK_WAIT_AUDIT=1`, then `tests/wait_audit.py
--apply build/<scene>/*.log` and review the diff.

Hidden timings this surfaced (each fixed in the script, with the guard named): `browser-act`'s
Hand back came within `BARS_GUARD` once `shot` stopped taking a second; `menus`' and `buttons`'
second confirmation came within `BAR_GUARD`; `jobs`' idle window (no frames drawn) had passed
only because slow starts kept the scheduler's 30 s due check out of it: it now runs a due check
before the window and one inside it.

## Timing tests

Five unit tests assert time budgets: `markdown_parse_1mb` (50 ms; 150 ms on CI),
`markdown_layout_pathological`, `markdown_html_pathological`, `reload_burst` and
`editor_perf_50k`. They catch an accidentally quadratic change, not a few percent. They
measure the calling thread's CPU time (`thread_cpu_now`, `src/cpu_clock_test.odin`), so a busy
machine no longer fails them, and `tests/unit.py` runs them last, alone. The limits are the
same as before.

## Flakes

| Where | Cause | Fix |
|---|---|---|
| `markdown_parse_1mb`, `reload_burst`, `editor_perf_50k` | wall-clock limits under load (e.g. 238 ms vs 50 ms with load 16) | CPU time, run alone, best of 5 for the parse; the parse budget in `editor_perf_50k` is wall time inside the app, 3 s in the test everywhere |
| `editor_git_gutter` | each test reset `State`, so tab ids and git load generations started again, and the previous test's late `Git_Head_Done` landed on this test's editor (9 of 32 runs under parallel load) | setup waits for in-flight git reads and keeps the ids going (0 of 64) |
| `ch_default_flags` | the fake claude wrote argv before its env file; a start's late env write was read as the next start's | env first, argv last |
| `pi_lookup_unanswered_is_there` | a 300 ms lookup cap for every case: a slow `/bin/sh` start read as a timeout | the short cap only for the hanging shell |
| `app-tab` | the fake app's start, first frames and exit were 5 s condition waits; at load 25 a start took longer, and the rest of the script failed after it | 20 s (no slower when it passes) |
| `app-tab` (Restart of a hung app ends "exited") | `socket_forget_tab` shut the old connection but it counted as the tab's until its reader thread saw the end; the frame loop saw it open after the Restart, then gone before the new process connected, and stopped the new process ("the app closed its connection") | forgotten connections are closing at once (`socket_forget_tab_ends_the_connection_at_once`: 20 of 20 still open before) |
| `browser-act` (`browser-e`): "written by the page" read session info | the app's copies went to the system pasteboard: another scene's (here another worktree's `menus`) replaced what the page had just written | a script's copies and pastes stay in the app (`autotest_clipboard_stays_in_the_app`) |
| `worktrees` | the branch list sorts by commit date, then name; the fixture's commits got whatever second they fell in, so under load the order flipped | every fixture commit has one fixed date |
| `menus` (on main d08482b) | not a flake: the Settings tab's new "pi extensions" group (c6753bb, merged in d08482b) moved the rows down four; `settings.txt` was updated, `menus.txt` was not, so its right-click on row 7 hit the `shell` toggle (no menu) | harness-setup sets row 11; `clickid`/`rclickid NAME @PATH` (picks a Files/Settings row by the end of its path) lets the scene write `rclickid frow @code/alpha/AGENTS.md` so the next group added cannot move it |
| `login_env_ask_fake_shell`, `login_env_fix_applies`, `login_env_probe_background_job` | a real `/bin/sh` takes seconds to start under load: 5 s answer timeouts and a 1 s "answered at exit" bound (48 of 48 failed at 12 processes at a time) | answers get 15 s; hang/kill/background checks must be done within 5 s, still far below what they are told apart from (0 of 48) |
| `browser-slots` (a stray UDP socket in the netpolicy check) | seen once; not reproduced | the runner reports it as **FLAKY** if it comes back |
| `browser-act` at `-j 6 --cef-jobs 2` (load 44, before the no-sudo sweep fix) | typing into the page failed at extreme load | not seen since: the load came mostly from every launch stat-ing all of `$TMPDIR` (below) |
| `changes` | `data.ahead` 1 vs 2: the commit had not finished 3 s after the click (load 11); then, waiting on `ahead`, a listing that ran while the commit landed (`git status` before `rev-list`) had the old files with the new `ahead` | `waitresult` runs `changes_list` again until the committed files show (up to 30 s), then checks `ahead` |
| `browser-rlz` | every sentinel file's access time moved at quit; seen once at load 11, not reproduced in 6 runs since | the runner reports it as **FLAKY** if it comes back |
| `browser-read` (`browser-e`) at `-j 9` | a load wait right after `browser_open` passed on the new tab's blank first document (also "complete"), and the read got nothing | `browser_open` marks the navigation as `browser_navigate` does (`browser_agent_open_marks_navigation`) |
| `bell` (count 2, not 3) | the bell coalesces a session's entries within `NOTICE_COALESCE` (10 s); with the waits gone, aaaa-1's second run could end within 10 s of its first entry and replace it (load 22) | an explicit `wait 10000` before that run |
| `browser-agent` (`browser-f`), while converting waits | a script's first `wait` became `eventually`; the app had not settled and a read returned an empty title | a script's first wait is never converted |

## Candidates to delete or rework

### Deleted

Four scenes repeated unit tests. Before each was deleted, its checks were compared with the
unit tests; the few that were its own moved first:

| Deleted | Covered by | Moved first |
|---|---|---|
| `instance.sh` (`instance`) | `instance_test.odin`: the lock excludes, is not inherited, a pi-desk 0.1.x is found | `instance_guard_whole`: `instance_guard` as `main.odin` calls it, with the real liveness and executable lookups, a compiled stand-in `pi-desk.app` and its socket, its leftover socket after it quits, a second take refused. Not moved: `main.odin`'s three-line test-mode `exit(3)` on a refusal |
| `run.sh phase05.txt` (`run-phase05`) | `core_test.odin` (`new_chat_and_reopen_dedupe`, `confirmation_flow`, `close_rules`, `layout_and_panels`, the redacted `send_text` log, `rescan` pending), `pi_integration_test.odin` (`--session-id`) | `rename_field_keys` (`buttons_test.odin`): the rename field's keys through `widget_event`: typing over the selected name, Backspace, Enter renames and gives focus back, ⌘A then typing, Escape keeps the name. Paste is not unit-tested (it reads the system pasteboard); `polish` and `beep` still type into the field |
| `run.sh term.txt` (`run-term`) | `term_input_test.odin` (selection mid-drag, ⇧-click, reported drags with their button, ⇧+drag, line-editing keys) | `render_selected_cells` in `selection_updates_during_drag` (what `term_draw` counts as drawn selection); `terminal_through_the_app`: ⌘ chords without a mapping send nothing and ⌘← does, through `event()`; a tab switch and the window going to the background end a drag. The AppKit `keyDown:` part (real NSEvents) cannot be a unit test: it moved to `beep.txt` (`polish-beep`) |
| `agent.sh drawer-resize.txt` (`agent-drawer`) | `buttons_test.odin` (`drawer_edge_resizes_not_terminal`: the edge over the terminal, live width, saved, double-click reset; `divider_bare_click_and_pinned_panels`: the pinned limit and the panels beside it) | the clamps in `drawer_edge_resizes_not_terminal`: the minimum (320), and the room there is (sliding over 910, pinned 620) |

Each moved check was seen to fail with its feature broken (Escape renaming, no drag cancel on a
tab switch or on the window going to the background), then the break was reverted.

### Still open

1. **Screenshot and benchmark tools** (`shots`, `font`, `looks`, `text-shots`, `text-flood`,
   `persist-cpu`, `panels-cpu`, `run-frame-pause`): kept as tools, not tests (above). `shots`,
   `font` and `looks` overlap; one before/after tool would do.
2. **`bridge-e2e`**: kept as a tool; fix or rewrite: its shells-panel assertion needs pi-kit's
   shell extension, which is not bundled.
3. **`app-calls`' default-scale check** repeats `test_scale_test.odin`; harmless, a few seconds.
4. **Stale pi-kit wording** in comments only: `fake-bridge.sh` ("pi-kit's row format", the
   same format the bundled `integrations/pi/lib/rows.ts` uses), `home_test.odin`,
   `reload_test.odin`, `buttons_test.odin`, `chat_readonly_test.odin`.

Done: the `jobs.sh` "no socket/tokens" check looks for `DECKHAND_(SOCKET|TOKEN|CONTROL_TOKEN)`
as well as the old `PI_DESK_*` names.

No helper file in `tests/` is unreferenced; nothing was removed as dead code.

## Measurements

Dev Mac (Apple silicon, 12 cores, 18 GB), 2026-11-04, under varying load from other builds:
load averages are noted with every number, and only runs at similar load are compared. "Before"
is one scene at a time and one unit-test process; "after" is the parallel runners.

| What | Before | After |
|---|---|---|
| `./build.sh test` (all unit layers) | 170 s, load 6.8 (`odin test src`: 2 min 17 s on one thread; `markdown_parse_1mb` failed at 52.6 ms) | 59–60 s, load 10–16 (`tests/unit.py`: 753 tests, 6 processes, 29 s + 12 s build) |
| Every scene, one at a time vs `--all` | 1553 s = 25.9 min for 46 scenes (`for s in …; do tests/scripts/$s.sh; done`), load 6–28 | 7.0–7.3 min for 51 scenes (`-j 4 --cef-jobs 1`, plus a ~50 s build), load 10–20, peak memory 1.8 GB, no failures; 26 min of scene time |
| A typical change (`browser_read.js`, as in eab4c1c): the browser scene plus the smoke set | `browser.sh` 258 s + the smoke scenes 37 s, one at a time: ~4.9 min | 4.0 min (`browser-a/-b/-c` one at a time beside the smoke set), load 15–22; 2.7 min would need `--cef-jobs 2` |
| Narrower change (`src/markdown_view.odin`) | `markdown.sh` 30 s alone (or nothing: no map said which scene) | `markdown` + the 4 smoke scenes side by side: 31 s plus the build, load 12–15 |

After the four duplicate scenes were deleted (3857e9f):
`./build.sh test` 48.5 s at load 3.8–7.2 (784/784 unit tests, 34 s of it the unit runner);
`./build.sh scenes --all` 49 scenes in 9.1 min, 36 min of scene time, load 5.9–8.0, peak
memory 2.3 GB, all passed, none FLAKY. Scene time grew since the first measurement because
main added scenes and checks (`harness-setup`, `files-nested`, a longer `setup` and `claude-sessions`).

Other runs, for the record: `-j 4 --cef-jobs 2`: 7.0 min, load 15, no flakes; `-j 6 --cef-jobs 2`:
5.7 min but load 44 and two failures (`browser-act` typing, `worktrees`' fixture, since fixed), so
the defaults stay at 4 and 1. The critical path at `-j 4` is total scene time / 4; at higher
`-j` it is Chromium (`browser-a/-b/-c`, `browser-rlz` 105 s idle by design, `claude`, `comments`).

After the condition waits, the Chromium lanes and the memory budget (c3e93a2):
`./build.sh scenes --all` 52 scenes in **2.9 and 3.1 min** at `-j 8`, three Chromium, a 3.5 GB
budget (21–23 min of scene time, load 7–14, peak memory 2.7 and 3.1 GB; one FLAKY `bell`). The
same day the old scripts at `-j 4` took 22.1 min, but most of that was every launch reading all of
a large `$TMPDIR` (the no-sudo sweep, fixed on main in bfb3472: launch and quit 37 s → 1.4 s).
Without the memory budget, `-j 8`/`-j 9` with three Chromium scenes took 2.5–3.0 min and peaked at
3.6–3.7 GB, once past 4 GB. The critical path is now `browser-rlz` (105 s, idle by design) and the
Chromium lanes. `./build.sh test`: 51 s (794 unit tests, 141 node tests).

### What was tried and left out

- **Test-mode time knobs** (shorter `BAR_GUARD`, `TIP_DELAY`, scheduler periods in test mode):
  not needed once the waits stopped being fixed; the guards are part of what the scenes test,
  and the few waits on them now name them.
- **Converting every fixed wait**: 184 stay (see [Waits](#waits)); each is either the point of
  the check or one the audit could not prove safe to poll.
- **Per-test TMPDIR for scenes**: the control socket's path must fit `sun_path` (104 bytes);
  scenes keep the default runtime dir (sockets are per process) and the ones that inspect it
  set their own.
- **Faster unit tests by removing sleeps**: the claude and socket tests wait for fake
  processes (100–600 ms each); parallel processes cut the wall time more for less risk. The
  slowest chunks now are `changes_test` (17 s) and `worktrees_test` (14 s), which run real git.
- **Shorter `browser-rlz`**: its 100 s idle is the point (an RLZ ping was once seen ~80 s in).
- **More CI parallelism**: CI runs two scenes at a time per shard. `SCENE_JOBS: "1"` in the
  workflow returns to one scene at a time if the hosted runner (3 vCPUs) struggles.
