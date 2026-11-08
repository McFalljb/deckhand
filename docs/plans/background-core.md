# Deckhand background core and remote machines: design

Issues [#4](https://github.com/McFalljb/deckhand/issues/4) (sessions keep running after the
window closes) and [#5](https://github.com/McFalljb/deckhand/issues/5) (every machine in one
sidebar). Design only: no app code has changed. Investigated at `main` 6ee5586. Modelled on
Herdr 2 (herdr-core cd12ddd, herdr-app 7fe7ac3, Apache-2.0).

Status (2026-11-07): draft for review. The four product questions in §2 were answered by the
user (every recommended default accepted). Gating first task: the VT snapshot spike (§10, S1).

Contents: 1 Goal · 2 Decisions · 3 Process model · 4 What moves where · 5 Protocol ·
6 Lifecycle · 7 Updates and version skew · 8 Remote · 9 Alternatives · 10 Order of work ·
11 Risks · 12 Testing · 13 Open questions · 14 Credits and licence

---

## 1. Goal and non-goals

**Goal**
- pi, Claude Code, shells and job runs keep running when the window closes, crashes or the app
  updates. Reopening the window reattaches to them, with the screens as they are now.
- Updating Deckhand, or its core, does not stop sessions.
- A window shows sessions from cores on several machines (#5), reached over SSH, without new
  ports or logins.
- Releases stay one artifact, one version number and one signing key.

**Non-goals (v1)**
- Surviving logout or reboot. After those, today's restore runs (pi and Claude resume from disk,
  shells restart fresh: [PERSISTENCE.md](../PERSISTENCE.md) "Restore").
- Several windows on one core. v1 has one window per core (§4, "View state"); more windows come later
  (§10, M7).
- Browser pages or app tabs that outlive the window. The page record survives and reloads when
  the window comes back. App tabs may die with the window (§2, decision 3).
- Headless CEF in the core, so agents can browse with no window open.
- Linux or Windows *windows*. A headless Linux *core* is in scope for #5 (§8).

---

## 2. Decisions

**Made by the user (2026-11-07):**

| # | Question | Decision |
|---|---|---|
| 1 | Closing the last window | The core keeps running while any session process or job run is alive, and exits after a quiet period (default 10 min) once nothing is running and no window is attached. |
| 2 | ⌘Q | Closes the window only, and sessions keep running. A separate menu item, **Quit Deckhand and Stop All Sessions…**, stops everything (confirmation class `app_quit`). |
| 3 | App tabs (e.g. forge) | May die with the window in v1. |
| 4 | Remote core updates | One-click offer when connecting to an older remote core (§8.4). |

**Taken in this design (open to review):**

| Topic | Decision | Where |
|---|---|---|
| Processes | Three roles: window, core and PTY holder (herdr's model), not exec-in-place | §3, §9 |
| Terminal output | Option (a): the core streams PTY bytes, the window runs its own ghostty-vt, and a VT snapshot resyncs it | §5.4 |
| Browser and app tabs | Stay in the window. The core keeps their records and routes `browser_*`/`app_*` to the window, or returns `no_window` | §4 |
| First step | **The holder goes in front of today's single-process app first (M1)**, before the core split. That alone makes quitting, crashing or updating Deckhand stop no sessions. | §10 |
| Windows in v1 | One window per core, and view state (focus, current session, panes) stays in the core | §4 |
| Lifecycle | The core starts on demand as a **one-shot launchd job** (herdr's), not as a child the window spawns. A login agent comes later, for jobs while closed. | §6 |
| Core packaging | A nested, signed `Deckhand Core.app` holds the core, holder, CLI and integrations. It is installed into a versioned folder outside the app bundle. | §7.1 |
| Auth | Stricter than herdr's: the holder and core check their peer, not only the file mode | §5.3 |
| Editor buffers | Stay in the window in v1. Closing a window with unsaved buffers asks first. | §4 |

---

## 3. Process model

```
 local Mac                                                     remote host (#5)
┌──────────────────────────┐
│ Window (Deckhand.app)    │  UI, fonts, Clay, sokol, CEF, app-tab frames,
│ ghostty-vt copy per      │  selection, IME, key encoding, State replica
│ shown terminal           │
└───────────┬──────────────┘
            │ core.sock: hello (window token + peer check), framed mode:
            │ ch 0 JSON control, ch N terminal streams, state deltas
┌───────────▼──────────────┐   ssh host deckhand-core connect   ┌──────────────────┐
│ Core (deckhand-core      │◄──────────── stdio, framed ───────►│ remote Core      │
│ serve; one-shot launchd) │                                    │ (+ its holders)  │
│ State, commands, socket, │◄── agents: pi bridges, Claude CLI, └──────────────────┘
│ jobs, ghostty-vt per     │    Atlas, --ctl (NDJSON v1, as today)
│ terminal (status, 2004,  │
│ queries), persistence    │
└───────────┬──────────────┘
            │ holder-<build>-<id>.sock: frozen holder wire v1
┌───────────▼──────────────┐   ┌──────────────────────────┐
│ Holder (current build)   │   │ Holder (older build,     │
│ PTYs, children, reap,    │   │ DRAINing: no new spawns, │
│ 1 MiB tail per terminal  │   │ exits when empty)        │
└───┬──────────┬───────────┘   └──────────┬───────────────┘
   pi tab   claude tab, shells, job runs   kept sessions
```

| Role | Owns | Knows nothing about | Dies → |
|---|---|---|---|
| **Window** | drawing, input, CEF, app-tab processes and frames, a ghostty-vt per *shown* terminal, editor buffers (v1) | PTYs, children, policy | Nothing else. Pages and app tabs go; reopening reattaches. |
| **Core** | State, `run_command`, the socket and tokens, events, jobs, persistence, a ghostty-vt per terminal (status, mode 2004, DA/DSR replies, exit banners), remote connections | pixels, fonts, CEF | The holder restarts it. Screens are rebuilt from the tails, marked `inexact`. |
| **Holder** | PTY masters, every session process as its child, `waitpid`, the foreground pgid, a 1 MiB raw tail per terminal, backlog while the core is away | parsing, policy, State, tokens | Its terminals get SIGHUP. The core marks them `holder_lost`, and today's restore path follows. |

One holder per build per core, not one per terminal (herdr: `runtime.rs` `start_holder`). The
holder is the same binary as the core (`deckhand-core hold`), so its build id is the core's.

---

## 4. What moves where

Condensed from the map's §2 classification. C = core, W = window, H = holder.

| Subsystem (today's files) | v1 home | Change needed |
|---|---|---|
| PTYs, fork, reap (`pty.odin`, `pty_posix.odin`) | **H** | Core calls go through holder messages (`SPAWN`, `INPUT`, `RESIZE`, `SIGNAL`, `RELEASE`). `pty_foreground_busy` becomes `FOREGROUND`/`FOREGROUND_IS`. |
| Job runs (`jobs_run.odin`, fork+setpgid) | **H** (pipe kind) | Herdr has no jobs. The holder wire v1 needs a non-PTY `SPAWN` (stdout and stderr to files) from day one, because the wire never changes later. |
| ghostty `Terminal` per tab (`term.odin` 23-320) | **C** (+ a W copy for shown tabs) | Cols, rows and cell px come from the window's resize. `term_pad`/`font.cell_w` stay W. |
| `term_draw`, selection, links, IME, key/mouse encoding | **W** | Unchanged, on the window's copy. `map_key(sapp.Keycode)` stays W. The window copy's `Write_Pty` callback is dropped. |
| State model (`state.odin`) | **C**, with a W replica | v1 keeps view state (current session, focus, panes, sidebar filter) **in the core** as today, so agents keep steering the same view. Pixel fields (`Pane.rect`/`frame`) move to a W-only table. |
| `run_command`, inbox, command table | **C** | `app.redraw = true` (commands.odin:686 and 5 others) becomes a "state changed" hook. Toasts become an event. |
| Pane room and ratio checks (`panes_commands.odin` 141-194) | C, given W's size | The window sends its centre size with `split_pane`/`resize_pane`. Clay ids stay W. |
| Socket, tokens, events, log | **C** | Stable socket name. Framed mode for windows (§5). The hello's `pd_frames_*` (socket.odin:856-861) asks the window. |
| pi/Claude logic, waits, held prompts, hot reload, dead tabs | **C** | Ticked by a core loop, not `frame()`. The Clay part of `dead_tab.odin` moves to W. |
| Jobs scheduler, Atlas, notify model, bell | **C** | OS banners: the core posts them from `Deckhand Core.app` (a bundle can use UNUserNotificationCenter) when no window is active. |
| Persistence (`persist.odin`) | **C** | `persist_after_layout` is fed by W's layout messages. |
| Login env (`login_env.odin`) | **C** | A launchd core always probes. Env is computed per spawn and sent in `SPAWN`; the holder computes nothing. |
| Instance lock (`instance.odin`) | **C** | Becomes the core lock, per data dir. A second window launch focuses the open window. |
| Browser tabs (CEF) | **W**, with the record in C | The core keeps `Browser_Tab{url,title,…}` and routes `browser_*` to the window as a tab host (`socket_bridge_send` pattern). No window: `{"ok":false,"code":"no_window","error":"no Deckhand window is open; browser tabs need one"}`. `on_cef_popup` becomes a command. |
| App tabs, frames | **W** (process too, in v1) | The record lives in C. When the window closes, the tab shows as exited (`window_closed`) with Restart. |
| Editor buffers | **W** (v1) | The record (path) lives in C. Closing a window with unsaved buffers asks first. Moving buffers to C is later. |
| Updater | **W** checks and swaps; **C** handover | §7 |
| Platform table (`platform.odin`) | split | Core-side: wake, run_later, activity, notify. Window-forwarded as `window.request`: clipboard get/set, open_url, reveal, pick_folder, toast, appearance, `window_active`. |
| Fonts, Clay UI, menus, sidebar, drawer, autotest UI | **W** | Scenes drive the window; the core runs headless in tests (§12). |

**Why one window in v1:** the map's top risk is splitting State into per-window views, because agents set
focus and the filter the user sees (ROADMAP decisions 2026-10-31). With one window per core,
view state stays in State, agent semantics don't change, and #4 and #5 need nothing more. The
`window_id` field is reserved in the protocol for M7.

---

## 5. Protocol

### 5.1 Transport and framing

| Link | Transport | Framing |
|---|---|---|
| Agents, CLI ↔ core | `core.sock` (renamed from `pi-desk-<pid>.sock`) in today's 0700 runtime dir, mode 0600 | NDJSON v1, unchanged (PROTOCOL.md §1) |
| Window ↔ core | the same `core.sock` | starts as NDJSON; `hello {framed:true}` switches it to frames |
| Local core ↔ remote core | `ssh host deckhand-core connect` stdio (relays to the remote `core.sock`) | framed, from the first byte after hello |
| Core ↔ holder | `holder-<build8>-<rand8>.sock` beside `core.sock` | holder wire v1 (§5.6) |

**Framed mode** (herdr's layout): `[channel u32 LE][kind u8][len u32 LE][payload]`, payload ≤ 16 MiB.
Channel 0 carries one JSON envelope per frame (the same envelope as NDJSON, no line cap).
Channels ≥ 1 are terminal streams. Kinds: `DATA`, `SNAPSHOT`, `RESIZE`, `CREDIT`, `CLOSE`,
`FOCUS`. **Unknown kinds are ignored**, so kinds can be added inside a generation.

The socket name is `core.sock` per runtime dir. Tests already set `PI_DESK_RUNTIME_DIR` per
scene, which keeps parallel scenes apart.

### 5.2 Handshake

The `hello` reply grows (additive, PROTOCOL.md §1 rules):

```json
{"ok":true,"data":{"v":1,"generation":1,"app":"deckhand","version":"0.9.0","build":"<cdhash8>",
 "caller":"ui","machine":"local","features":["framed","term_stream","state_deltas","tab_host",
 "machines"],"methods":["…"],"holder_wire":1}}
```

- `generation` is today's `v`. A different `v` keeps today's error ("unsupported protocol version").
- `features` gate optional behaviour (§7.3). `methods` lists the command types (from
  `command_table.odin`).
- A window hello carries `{"window": {"version", "generation", "pid"}, "token": <window token>}`.

### 5.3 Auth: who becomes `ui`

Minting `ui` over a socket is the critical boundary. `ui` confirms for agents, sets permission
modes and replays a Claude session's saved flags (docs/CLAUDE.md §3). The existing threat model
holds: same-user code can do what the user can. The goal is that **no agent token, child process
or naive client ever becomes `ui` or holder-owner by accident**, and that doing so on purpose
takes a deliberate attack on files or signed binaries.

| Link | Checks | Why |
|---|---|---|
| Window → core | (1) **Window token**: 256-bit, in `<runtime>/window.token` (0600, created by the core). It is never in any environment, and `child_env` drops `DECKHAND_WINDOW_TOKEN` as well, defensively. (2) **Peer process** via `LOCAL_PEERTOKEN` (an audit token, not a pid, so pid reuse can't fool it). The peer must not descend from any holder, so nothing an agent runs inside a tab qualifies. (3) **Peer code**: a valid signature with hardened runtime, and either the same Developer ID team and identifier or (ad-hoc builds) a CDHash in the core's `trusted_windows` list. The core writes that list when it installs from a bundle it has verified (`codesign --verify --deep --strict`). (4) A window in test mode says so in its hello, and a non-test core refuses it. | (1) stops naive clients. (2) stops agents, which all descend from a holder (the same idea as the Claude peer-pid walk, socket.odin:247). (3) stops a script posing as a window. Hardened runtime ignores `DYLD_*`, so the genuine window can't be injected into. |
| Core → holder | Herdr's holder accepts any `HELLO` ("the newest Hello owns", `holder_proto.rs` L1-3; `holder.rs` `serve`), protected only by the 0700 dir. **Deckhand must not copy that.** The holder socket grants `SPAWN` and `INPUT` to every terminal, which bypasses `caller_may`. The holder checks: the peer is not its own descendant, and the peer's CDHash is named in a **core statement** signed with the release key (`version`, `cdhash`, Ed25519; §7.1) that the core presents in `HELLO`. The holder has the public key compiled in. | A frozen holder must accept future cores, so it trusts a signature, not a list. During a key rotation the statement carries both signatures. |
| Agents → core | Unchanged (PROTOCOL.md §2). | — |
| Local core → remote core | SSH is the auth: the remote core gets the connection on `connect`'s stdio. The remote core grants the relay `ui` only if the relay is the core's own binary and is **not a descendant of any holder** on that host. | Remote agents run inside the remote holders. |
| Development builds (no release key) | Token + not-a-holder-descendant + same user only. Settings shows "development build: window auth is same-user only". | Ad-hoc dev builds have no identity to check. |

Permissions follow herdr (core `docs/security.md`) and today's rules: dirs 0700 and refused if
not owned or not a real directory, sockets 0600, token and handover files 0600.

### 5.4 Terminal streams (option a)

```
window: term.attach {tab_id, history_lines: 10000}         → {ok, channel: 7, seq: 81234}
core:   [7][SNAPSHOT] {meta JSON} + VT bytes (screen + scrollback + modes)
core:   [7][DATA] bytes from seq 81234 on, coalesced ≤ 8 ms or 64 KiB
core:   [7][RESIZE] {seq, cols, rows}   ← at the exact byte offset the core applied it
window: [7][DATA] input bytes (already encoded: keys, paste with 2004 brackets, mouse)
window: [7][CREDIT] n  ·  [7][FOCUS] in|out  ·  term.detach {channel}
```

- **The core is the only resize authority.** The window sends `term.resize{tab, cols, rows,
  cell_w, cell_h}`. The core applies it to its own emulator and to the holder (`RESIZE`), then
  emits a `RESIZE` frame at that byte offset. Both emulators then reflow at the same point.
- **Only the core answers terminal queries** (DA, DSR, OSC 10/11 colours from the theme in
  State, XTWINOPS pixel sizes from `cell_w/h`).
- **Input** on the stream is unlogged and high-rate, as today (DEVELOPING.md "Data flow per
  terminal"). `send_text` stays a logged, policy-checked command for agents.
- **Snapshot** = VT bytes plus meta: cursor, modes (kitty flags, mouse, 2004, 1004, 2026, 2031),
  title, colours, OSC 7501 status, exit state. VT bytes are a version-independent format, so the
  same snapshot serves window attach, handover between core versions and downgrades. **Spike S1
  gates this** (§10).
- **Hidden tabs aren't streamed.** The core keeps parsing them for status. A window attaches when
  a tab becomes visible in any pane, and detaches 2 s after it is hidden, so quick tab switches
  don't flap.

### 5.5 Flow control

| Where | Rule |
|---|---|
| Core → window, per stream | Credit-based, starting at 256 KiB. More than 4 MiB behind: drop the queue and send a fresh `SNAPSHOT`, never the backlog (herdr). A stalled stream never blocks channel 0. |
| Core → window, state | Deltas coalesce at ≤ 60/s. Overflow sends a full state (today's `dropped` rule, then resync). |
| Holder → core | Herdr queues 8 MiB, then stops reading the PTY, so programs wait (`holder.rs` `BACKLOG_BYTES`). **Deckhand keeps that while a core is attached.** While no core is attached for longer than the grace period, the holder keeps reading into the tail only, so programs never stall (the screen is then rebuilt `inexact`). |
| Core → holder input | One writer thread per terminal, so a program that stops reading blocks only itself (herdr). |

### 5.6 Holder wire v1 (frozen)

Herdr's layout: `[kind u8][terminal u32 LE][len u32 LE][payload]`. Control payloads are JSON,
terminal bytes are raw, and the payload is at most 16 MiB.

| core → holder | holder → core |
|---|---|
| `HELLO{version, statement}` · `SPAWN{kind: pty\|pipe, argv, env, cwd, cols, rows, stdout?, stderr?, pgroup}` · `INPUT` · `RESIZE{cols,rows}` · `SIGNAL{signal, target: pid\|pgroup}` · `RELEASE` (close the master: SIGHUP) · `GOODBYE{handover\|shutdown}` · `FOREGROUND` · `DRAIN` | `WELCOME{version, instance, pid, build, previous: none\|handover\|crash, terminals[{id,pid,pgid,cols,rows,exit}]}` · `TAIL` · `OUTPUT` · `SPAWNED{pid}` · `SPAWN_FAILED{error}` · `EXITED{code, signal}` · `BYE` · `FOREGROUND_IS{pgid}` |

Additions over herdr: a `pipe` spawn kind (job runs, and app tabs if they move later), pgroup
signalling, `pgid` in `WELCOME`, and the core statement in `HELLO`. The rule: **every core
speaks holder wire v1 for as long as any v1 holder may be alive.** Unknown JSON fields are
ignored. A v2 wire would only ever be added beside v1, never replace it.

The holder also disclaims TCC responsibility at start (herdr's `macos_responsibility.rs`
re-exec), so privacy prompts belong to `Deckhand Core`, not to whatever started it.

### 5.7 State replication

- After hello the window sends `state.subscribe`. It gets `state.full{version, state}` (today's
  `get_state` encoder for `ui`, plus the runtime fields the UI draws from), then
  `state.delta{version, sections:{…}}`. A delta carries whole sections, with the sections
  `projects`, `sessions`, `tabs:<session>`, `panes:<session>`, `settings`, `jobs`,
  `confirmations`, `notifications`, `update`, `panels:<tab>` and `machines`.
- The window decodes into a replica with today's `State` shape, so most UI code keeps reading
  `state.*`. That JSON → State decoder doesn't exist yet (map §2) and is part of M3.
- New core → window messages: `toast`, `confirmation.parked` (the bar appears without polling),
  `window.request{op, id}` (clipboard, open_url, reveal, pick_folder; the window answers with
  `window.reply`), `tab_host.call` (browser and app ops; answered with `finished`).
- Agents keep today's `command` events and `get_state`.

---

## 6. Lifecycle

| Event | What happens |
|---|---|
| Window, `deckhand DIR` or `deckhand --ctl` needs a core | Connect to `core.sock`. If it's absent, bootstrap the one-shot launchd job and wait up to 15 s. A stale socket file is removed by the core once it holds the lock. |
| Core starts | Take the core lock. Adopt every holder socket (`attach_all`). Restore State from the handover file if one is present and fresh, else from `workspace.json`. Open `core.sock`. |
| Window closes, ⌘Q | The window process exits; the core and its sessions carry on. The first time, a one-line notice says so. |
| Last window gone | When no window is attached, no tab process lives and no job runs, the core waits 10 min, then saves and exits. Holders with no terminals exit on their own. |
| Quit Deckhand and Stop All Sessions… | `quit` (class `app_quit`): persist, `GOODBYE{shutdown}` to every holder, exit. |
| Window crashes | Nothing else changes. The next launch reattaches. |
| Core crashes | The holder restarts it after a 3 s grace period, with exponential backoff (2ⁿ, capped at 60 s, over 5 min; herdr `supervise`). The window shows "Reconnecting…" and reattaches. |
| Logout or reboot | Everything stops. The next start restores as today. |

**How the core starts: options**

| | Window spawns it (`posix_spawn` SETSID) | One-shot launchd job (herdr) | SMAppService login agent |
|---|---|---|---|
| Survives app quit | **No guarantee**: the core stays in the app's coalition, "which macOS can kill when the app quits" (herdr `macos_launchd.rs` L1-2; the reason for herdr 0.1.17) | Yes | Yes |
| Environment | the window's (quarantine, odd PATH) | clean, then probe the login env | clean |
| User prompt | none | none | a Login Items approval |
| Dev and test loop | easy | easy (tests run `deckhand-core serve --foreground`) | hard; test mode must never register |
| Start at login, jobs while closed | no | no | yes |

**Recommendation: the one-shot launchd job** in `gui/<uid>`: label
`dev.deckhand.core.<datadir-hash8>`, `RunAtLoad=true`, `KeepAlive=false`,
`AbandonProcessGroup=true`, `ProcessType=Interactive` (so App Nap leaves it alone; spike S2
confirms this). The plist is written 0600 into the runtime dir and removed right after
`launchctl bootstrap`. The core also keeps `beginActivity` while jobs run, as now. The login
agent waits for M5, where "jobs while closed" (ATLAS.md) needs it. The map recommended the
window spawning the core; herdr's coalition finding argues against that.

---

## 7. Updates and version skew

### 7.1 What a release contains

```
Deckhand.app/
  Contents/MacOS/Deckhand                    window
  Contents/Frameworks/…CEF…
  Contents/Helpers/Deckhand Core.app/        bundle id dev.deckhand.core, hardened runtime
      Contents/MacOS/deckhand-core           serve | hold | connect | check | install | version
      Contents/MacOS/deckhand                the CLI (today's pi-desk-cli)
      Contents/Resources/integrations/{pi,claude-code}
  Contents/Helpers/core.statement            "deckhand-core-statement v1", version, cdhash, Ed25519 sig
```

- **Why a nested `.app` and not a bare binary:** TCC grants and notifications belong to a bundle
  identity, which herdr moved to in 0.1.18 (`macos_bundle.rs`). With a Developer ID they also
  survive updates.
- **Why the integrations move into it:** running pi and Claude tabs load `integrations/pi` and the
  plugin from bundle-relative paths, and hot reload rereads them. Once the app bundle is swapped
  (and `Deckhand.app.old-<v>` deleted at the second start), those paths would vanish under live
  sessions.
- **Signing order** in `scripts/release.sh`: sign Core.app → read its CDHash → sign the core
  statement → place it in `Helpers/` → sign Deckhand.app → today's v2 manifest and `.sig`
  (unchanged, so old updaters still verify). The app's CDHash covers the nested bundle and the
  statement through the resource seal.
- **Remote targets:** `deckhand-core-<v>-<os>-<arch>.tar.gz`, each with a `.sig` over today's
  manifest format (`cdhash none` on Linux). That is a real Ed25519 signature, **never a
  checksum-only manifest** (herdr's is checksum-only: core `docs/security.md`).

**Install location:** `~/Library/Application Support/pi-desk/core/<version>/Deckhand Core.app`,
with `current` and `previous` symlinks (switched with an atomic rename). Holders and live tabs run
from their own version's folder. Garbage collection removes a version only when it is neither
`current` nor `previous`, no holder of that build answers, and no tab was started from it.

### 7.2 App update, step by step

1. **Check, download, verify:** as today (Ed25519 `.sig` over version, size, sha256 and CDHash;
   `codesign --verify --deep --strict`; CDHash rechecked at each step).
2. **Confirm:** the "Running sessions, shells and jobs will be stopped" prompt (update.odin:317-332)
   becomes "Browser pages will reload and app tabs will restart". Sessions are no longer at risk.
3. **Swap and relaunch the window:** as today (`renamex_np` swap, detached `open`). The core keeps
   running.
4. **The new window connects to the old core.** Its hello shows `core.version < app.version`. The
   window runs the bundled `deckhand-core install`: copy `Helpers/Deckhand Core.app` to
   `core/<v>/`, verify the codesign and the statement's CDHash, and run `deckhand-core check`
   (it prints version, generation and holder wire, and exits 0).
5. **Handover request:** the window sends `core.handover{to:"<v>"}` (caller `ui`). The old core:
   1. stops taking commands (it queues them) and flushes `workspace.json`;
   2. writes `handover.json` (0600): runtime ids, tab ↔ holder terminal map, pending
      confirmations, held Claude texts, waits, running job records, and **SHA-256 hashes** of live
      tokens and reconnect tokens, never the tokens themselves;
   3. writes an exact snapshot per terminal (§5.4);
   4. sends `GOODBYE{handover}` to every holder (they clear their tails and keep buffering);
   5. points `current` at `<v>` (keeping `previous`), bootstraps the new core's launchd job, and
      releases the lock and socket.
6. **New core adopts:** it takes the lock, sends `HELLO` to each holder and gets `WELCOME` and
   `TAIL`s. It restores each exact snapshot, replays the tail, and answers queries asked during
   the gap. It **DRAIN**s holders of another build, and new terminals go to a new holder.
7. **Windows and agents reconnect:** the window sees `lost`, reconnects, gets `state.full` and
   reattaches its shown tabs (`SNAPSHOT`). pi bridges reconnect with their reconnect tokens, and
   Claude CLIs with their env tokens. Both are checked against the hashes.
8. The new core marks `<v>` healthy after 60 s without a crash. Old versions are collected later.

The updater keeps today's backup and rollback of the *app* bundle.

### 7.3 Version skew rules

The app and core share one version number. Skew still arises: in the gap between the swap and
the handover, after a manual downgrade, and with remote cores.

| Seen at hello | Result |
|---|---|
| Same generation, core ≥ `CORE_MIN` (pinned in the app's source) | Works. Optional behaviour is gated on `features`. If core < app, a local core is handed over at once (§7.2); a remote core gets the one-click offer (§8.4). |
| Same generation, core < `CORE_MIN` | Locally, hand over to the bundled core automatically. Only if that fails does a **"Deckhand's background core is out of date"** block appear, with Retry and Details. Remote: the machine shows `needs_update` with the one-click update. |
| Core generation > app generation | Block: **"Update Deckhand: its background core is newer than this app"**, with Update and a second choice, "Replace the core with this version". Sessions keep running either way, because the holder wire is the same. |
| Core generation < app generation | Locally, hand over to the bundled core (sessions keep running). Remote: `needs_update`. |
| Holder wire unknown to the core | Can't happen while v1 is frozen. Defensively, the core leaves that holder alone and marks its tabs `holder_unknown`. |

**Grow-only API.** `schema/released-v1.json` lists, for the last release: commands with their args
(required or optional) and result fields, event types and fields, state snapshot fields, frame
kinds and features. It is generated from `command_table.odin` and the encoders. A unit test
(< 1 s) fails on any breaking change: a removed command, field or kind, an optional arg made
required, or a type change. `scripts/release.sh` refreshes the file at the tag. A real break needs
`v` 2, decided on purpose.

### 7.4 Failure modes

| Failure | What happens | Sessions |
|---|---|---|
| `check` of the new core fails (step 4) | No handover. The window shows "Couldn't finish updating the background core" and keeps using the old one (same generation, so it works). | Kept |
| The new core crashes during adoption | The holder restarts `current`. Every core start records the attempt in `core/<v>/attempts`. Two failures within 5 min make the starting core point `current` back at `previous`, mark `<v>` bad, and start the old one. Screens are `inexact`. The window says "Update rolled back". | Kept |
| The old core crashes mid-handover (before `GOODBYE`) | The holders see a crash, and the supervisor starts `current`, old or new depending on whether step 5.5 ran. There's no snapshot, so screens come from the tails (`inexact`) and no query replies are sent. | Kept |
| `handover.json` is missing or stale (> 3 min, another boot) | Restore from `workspace.json` and adopt the holders: tabs reattach by terminal id, and runtime-only state (held texts, parked confirmations) is lost. | Kept |
| The core crashes during normal use | As above: holder restart, tails, `inexact`. | Kept |
| A holder crashes | Its masters close and its children get SIGHUP. The core marks those tabs `holder_lost`; pi and Claude resume from disk, shells restart fresh (today's restore). Job runs are marked `failed (holder lost)`. | Lost for that holder's tabs only |
| Manual downgrade, same generation | The older window works with the newer core (grow-only). The core is never downgraded automatically. Settings › About offers "Use this app's core". | Kept |
| Manual downgrade to an older generation | The "Update Deckhand" block above. "Replace the core" hands over to the older core: the snapshot format is VT and `handover.json` is grow-only JSON, so the older core ignores what it doesn't know. | Kept |
| Disk full during the handover write | Abort before `GOODBYE` and keep the old core. | Kept |

---

## 8. Remote (#5)

### 8.1 Connection

- **Only the local core talks to remote cores**, not the window (herdr: core `docs/machines.md`
  "What runs where"). The window keeps one connection. Ids are `{machine, id}`, and the sidebar
  groups sessions by machine.
- It dials `ssh -S <control> -o ControlMaster=auto -o ControlPersist=600 host
  ~/.local/share/deckhand/core/current/deckhand-core connect`, using the user's own `ssh` and
  `~/.ssh/config`. There's no remote PTY, banner lines before the hello reply are skipped, and
  `--via '<cmd>'` allows custom transports (all herdr). Passwords, OTPs and host-key prompts mark
  the machine `needs_login`, with a Log in button that opens a shell tab running `ssh host true`.
- `connect` starts the remote core if it isn't running: a systemd user service on Linux (herdr
  `systemd.rs`), the launchd one-shot on a Mac.
- **Requests carry the local caller.** The local core checks `caller_may` itself before
  forwarding. A local agent's request travels as `on_behalf:{kind, …}`, and the remote core
  applies its own rules to that kind, which can only lower `ui`. Agents on the remote host use
  the remote core's own socket, as they would locally.
- **Reconnect:** retries with backoff. When the link returns, the remote core's terminals arrive
  as `created` or `removed`, the window gets fresh section deltas and reattaches with snapshots.
  An offline machine shows its last-known sessions, greyed out, with the time it was last seen.

### 8.2 What stays local

| Kind | Remote session |
|---|---|
| pi, Claude, shell tabs; jobs | Run on the remote host |
| Browser tabs | Run in the local window's CEF. A remote agent's `browser_*` goes remote core → local core → window. Optional automatic `-L` forward for `localhost:<port>` URLs (open question). |
| App tabs | Left out in v1 (an IOSurface can't cross machines) |
| Screenshots and comment crops | Fetched over the protocol (`file.read` on the remote core) |

### 8.3 Install

`machine add user@host` runs `uname -sm`. If the remote core is missing or below `CORE_MIN`, it
asks first, then installs:
- **OS and arch match:** copy the local `core/current`.
- **Otherwise:** download that *same version's* tarball for the target, **verify its Ed25519 `.sig`
  locally**, then copy it over the SSH channel. The remote host needs no internet access and no
  trust in GitHub.
- It installs into `~/.local/share/deckhand/core/<v>/` with `current` and `previous`, then runs the
  harness setup ([HARNESSES.md](../HARNESSES.md)) for pi and Claude Code on that host.
- A Linux target needs a **headless Linux core build**: the core links no sokol or CEF, so it's
  feasible before Phase 5's Linux window. It is its own work item (§10, M6).

### 8.4 Remote updates (decided: one-click offer)

When the local core connects to an older remote core of the same generation, the machine's
sidebar row shows **Update** ("box runs Deckhand core 0.8.2; this Mac runs 0.9.0"). One click
copies the build over, as in §8.3, and runs `deckhand-core handover` there, so the remote sessions keep
running. A remote core below `CORE_MIN`, or of an older generation, is `needs_update`: it still
lists its sessions read-only if the API allows, with the same button.

**Why not herdr's manual `hc machine update`:** herdr leaves remote cores to the user, likely
because `hc` may be installed by a package manager or shared on a box (`installed_by`). Deckhand
installs its own core into its own folder and controls both ends of the wire. An update is a
handover that keeps sessions alive. A lagging core silently lacks features the local window
expects, which grow-only makes *safe* but not *visible*. One click (not automatic) still lets
the user pick the moment, because a remote handover briefly pauses that host's sessions. If the
remote core is not in Deckhand's own folder, Deckhand shows the command instead and doesn't
touch it. It never offers a downgrade.

---

## 9. Alternatives considered

| | **Holder (chosen)** | **Exec-in-place** (map §6) | fd passing (SCM_RIGHTS) | One holder per terminal (dtach/abduco) | tmux underneath |
|---|---|---|---|---|---|
| Who calls `waitpid` | The holder: always the parent | The core: the pid survives `execve` | The old core. Children reparent to launchd after it exits, so exit codes are lost. | Each holder | tmux |
| Core crash | Holder restarts the core; sessions kept, screens `inexact` | **All sessions die** (the masters close) | All die | Kept | Kept |
| Bad new build crashes after start | Rollback to `previous`; sessions kept | All die (preflight `--check` only catches startup failures) | All die | Kept | — |
| New code reaches old sessions | No: drained holders keep old pump code until those tabs close | Yes, at once | Yes | No | No (tmux can't upgrade a server in place) |
| Extra contract to freeze | Holder wire v1 | None, but the in-memory handover format must stay compatible | fd + state handoff | One per-terminal wire | tmux's |
| fd hygiene | Masters live only in the holder | Masters must survive exec but be CLOEXEC for children. Hard to get right. | Same | Simple | — |
| Processes | +1 per build | 0 | 0 | +1 per terminal (100+) | +1, and a second emulator in front of ghostty (rejected, ROADMAP 2026-10-30) |
| Size | ~1.5k lines (holder plus adoption) | ~1k lines, all on the riskiest path | ~1.2k | ~1.5k | n/a |

**Why the holder:** the crash rows. With exec-in-place, one core bug that crashes kills every
pi and Claude session mid-turn, which is the problem #4 exists to fix. The holder makes a core
crash a reconnect. Its costs are a frozen wire, and holder bugs that stay until the old sessions
end. Both are contained by keeping the holder tiny and policy-free.

---

## 10. Order of work

Each step ships on its own. Sizes are for one experienced person on this codebase.

| # | Step | Ships | Size |
|---|---|---|---|
| Q0 | **Quick win: PTY master fds CLOEXEC** (`pty_posix.odin:111`: only `O_NONBLOCK` today, so each later child inherits every earlier master). Set `FD_CLOEXEC` on the master in the parent, plus a test that a new shell's `/dev/fd` holds no other master. | A shell no longer holds other tabs' terminals open, so closing a tab reliably hangs it up. | ½ day |
| S1 | **Gating spike: VT snapshot from libghostty-vt v1.4.0.** The bindings wrap only the selection formatter (`Selection_Format_Options`, `Formatter_Format.VT`, ghostty.odin). Try a whole-screen-plus-scrollback selection with VT emit, and add modes, cursor, title and colours from `terminal_get`. Pass test: a corpus of recorded streams (pi, vim, htop, Claude, `ls --color`, OSC 8 links, wide or emoji graphemes) fed to emulator A, snapshot into B, render states compared cell by cell plus modes. Fallback: synthesise CUP+SGR+text from render-state rows (~200 lines). | Go or no-go for option (a) and for exact handover. If both routes fail: option (b) diffs (map §3b). | 1 week |
| S2 | **Spike: launchd one-shot + nested Core.app + hardened runtime + CEF entitlements + TCC disclaim** on macOS 14 and 15. Confirm that a core survives the app's quit and coalition, and which entitlements CEF needs without `allow-dyld-environment-variables`. | Facts for §5.3 and §6 | 2–3 days |
| M1 | **Holder in front of today's single-process app.** `deckhand-core hold` (a small Odin package, no ghostty or sokol), holder wire v1 frozen with golden vectors, installed into `core/<v>/`, started by the app via launchd. The app adopts holders at start. A planned quit means exact snapshots plus `GOODBYE{handover}`; a crash means tails. Token hashes are kept for reconnects. Job runs spawn through the holder. The update prompt shrinks (§7.2 step 2). | **Quitting, crashing or updating Deckhand no longer stops pi, Claude, shells or job runs**, and reopening shows their screens. Status, bell and Claude hooks pause while it's closed (§11, R5). | 3–4 weeks |
| M2 | **Boundary** (map M0): core code into `src/core` with no sokol or Clay. Fix the leaks (`app.redraw`, toasts, `font.cell_w`, pane room, `Copy_Selection`, `pd_frames_*`, direct `state.*` writes from UI files) and drive ticks from a core loop. | Compiler-checked split. Hidden windows no longer stall parsing. | 2–3 weeks |
| M3 | **In-process client and server** (map M1): a window replica fed by `state.full`/`delta`, terminal streams (§5.4) over an in-memory channel, the `ui` path through the protocol, the JSON → State decoder, tab host routing. | Nothing visible, but every test and scene exercises the real protocol. Double-parse cost is measured. | 4–6 weeks |
| M4 | **Separate core process** (map M2, less the parts done in M1): `deckhand-core serve` via launchd, `core.sock`, window auth (§5.3, two security review rounds), lifecycle (§6), ⌘Q and the stop-all item, `no_window` errors, the skew handshake, `CORE_MIN`, core install and handover on update (§7), and `released-v1.json` with its CI test. | **#4 done:** status dots, bell, Claude hooks, Atlas and jobs keep working with the window closed. Reattach is instant. | 4–6 weeks |
| M5 | **Login agent; jobs while closed** (map M4; replaces ATLAS.md's helper) | Atlas jobs run on schedule with Deckhand closed | 1–2 weeks |
| M6 | **Remote** (map M5): `connect`, machine add, install, update, `{machine,id}`, sidebar groups, offline states, `on_behalf`, remote file fetch, browser tabs local, per-machine harness setup. **Plus a headless Linux core build and release target.** | **#5 done** | 6–10 weeks + 2–3 for Linux |
| M7 | Several windows (per-window view state, a "primary window" for agents) | More windows | 2–4 weeks |

Map M3 (exec-in-place handoff) is dropped: M1 and M4 replace it.

---

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | VT snapshot fidelity (graphemes, OSC 8, modes) and two-emulator determinism (resize ordering) | S1 gates it. Resize is a sequenced frame (§5.4), and a randomised determinism test runs in the unit layer (§12). Resync by snapshot is always available. |
| R2 | `ui` over a socket, and holder ownership | §5.3 checks, two `opus-reviewer` security rounds on M1 (holder auth) and M4 (window auth). Code-signature checks are only real with hardened runtime: S2. |
| R3 | The frozen holder wire is wrong in a way found later | Spec it in M1 with golden vectors. Keep the holder tiny. A v2 can only be added beside v1, and old holders drain. |
| R4 | Ad-hoc signing: TCC grants keyed by CDHash reset at every update, and the code-identity checks are weaker | Recommend Developer ID for the core bundle (open question Q1). Until then, prompts after each update are a known cost (the app has it today). |
| R5 | In M1, with the app closed, nothing serves the socket: Claude hooks and the `deckhand` CLI fail, pi bridges retry, OSC status is missed, held prompts wait | Check that every hook fails *open for work, closed for read-only* (the read-only guard must never need the socket). Status recomputes on adopt. M4 removes the gap. |
| R6 | Bundle-relative paths under live sessions (integrations, `claude-code`, `pi`, the plugin dir) | Everything sessions use lives in `core/<v>/` (§7.1). Collection only removes a version once nothing uses it. |
| R7 | Moving ticks off `frame()` changes timing that scenes rely on (map risk 6) | M2 keeps a `core_tick()` called from `frame()` until M4. |
| R8 | Token continuity across a handover | Hashes in `handover.json`, and a test that a bridge reconnects after a handover. Claude env tokens survive because the tab's process is unchanged. |
| R9 | macOS socket path limit (104 bytes) with long `$TMPDIR` | Short names (`core.sock`, `holder-<8>-<8>.sock`); refuse a runtime dir path that is too long, with a clear error. |
| R10 | Remote: Linux core build, remote harness setup and SSH quirks (login banners, ControlMaster) | `--via` for tests, `needs_login`, banner skipping. Linux is its own work item. |
| R11 | Scope (25–40 weeks in total) | M1 alone delivers most of #4's value. Each step ships on its own. |

---

## 12. Testing (every new layer runs in seconds; no new test exceeds 3 min)

| What | How | Time | Layer |
|---|---|---|---|
| Holder wire codec | Golden vectors `tests/holder-wire/v1/*.bin`. The test fails if a vector *changes*, and a fuzz pass covers the decoder. | < 1 s | unit, every change |
| Holder behaviour | In-process holder plus a fake core over a socketpair, with `/bin/sh -c` children: spawn, input, resize, signal, exit codes, tail cap, backlog, DRAIN, pipe kind, peer refusal | ~3 s | unit |
| Grow-only API | Generate the schema from the command table and encoders, then diff it against `schema/released-v1.json` | < 1 s | unit |
| Skew decisions | A pure `skew_check(app, hello)` table test covering every row of §7.3 | < 1 s | unit |
| Snapshot round-trip and determinism | The S1 corpus, plus random chunking and resizes at random offsets: compare emulators A and B | ~5 s | unit |
| Flow control | Credit and overflow logic against a fake slow window | < 1 s | unit |
| Handover | Scene `core-handover.sh`: a test-mode core (`serve --foreground`, its own runtime dir) runs 6 fake terminals printing known output. It hands over 5 times under load, then checks that pids are unchanged, screens equal and tokens reconnect. Variants: kill -9 the core (crash, `inexact`), kill -9 the holder (`holder_lost`, fake-pi resume), a new core failing its health check (rollback). | ~40 s | scene, area `src/core` |
| Version skew end to end | The same scene with a core started under `PI_DESK_FAKE_VERSION`/`GENERATION` overrides (test builds only), so no old tag needs building. Nightly: one scene against the previous release's core tarball, cached. | ~20 s, nightly ~60 s | scene, nightly |
| Window attach and reattach | Scene: window ↔ core, close the window, the session keeps printing, reopen, compare screen | ~30 s | scene |
| Auth | Unit: token missing or wrong, peer is a holder descendant, test-mode window against a non-test core, unsigned peer (macOS) | ~2 s | unit |
| Remote | A second core with its own data and runtime dirs, connected through `--via 'deckhand-core connect'` (no sshd), covering install, `{machine,id}`, reconnect and offline. Real ssh to localhost: manual. | ~30 s | scene |
| launchd path | Test mode never bootstraps launchd. One manual or nightly scene covers the real bootstrap and survival after app quit. | — | manual/nightly |

All new scenes follow TESTING.md's parallel rules (their own `PI_DESK_RUNTIME_DIR` and data dir;
no `test-data` tag).

---

## 13. Open questions

| # | Question | Proposed default |
|---|---|---|
| Q1 | Sign releases with a Developer ID (keeps TCC grants across updates, makes the signature checks real)? | Yes, before M4 |
| Q2 | Should enabled job schedules keep the core alive, or start it at login (M5 login agent, a Login Items prompt)? | Yes from M5. Until then, jobs run only while the core runs. |
| Q3 | Quiet period before an idle core exits | 10 min, not a setting in v1 |
| Q4 | A shortcut for "Quit Deckhand and Stop All Sessions…" | Menu only (mouse-reachable; no new key) |
| Q5 | Auto `-L` forward for `localhost` URLs in remote sessions' browser tabs | Ask per port the first time |
| Q6 | Which remote targets first | macOS arm64 (copy) and Linux x86_64 |
| Q7 | Several windows (M7): which window do agents steer? | The most recently focused |
| Q8 | Holder with no core for a long time: drop to tail (chosen, programs never stall) or block? | Drop to tail |

---

## 14. Credits and licence

The process roles, the holder handover (snapshot, `GOODBYE`, adopt, `DRAIN`), the generation plus
grow-only API plus released-schema test, credit flow control, the one-shot launchd job and the
remote model all follow **Herdr 2** ([herdr-core](https://github.com/herdrdev/herdr-core),
[herdr-app](https://github.com/herdrdev/herdr-app), Apache-2.0).

- **No code is copied.** Herdr is Rust, and Deckhand is Odin. Deckhand reuses designs and two
  wire layouts: the holder frame `[kind u8][id u32 LE][len u32 LE]` and framed mode
  `[channel u32 LE][kind u8][len u32 LE]`. Message names follow herdr's. A wire format or protocol
  design is not code, and Apache-2.0 asks nothing for it. Credit herdr in this doc and in
  PROTOCOL.md's framed-mode section as a courtesy.
- **If any herdr source is ever translated line by line,** that Deckhand file keeps herdr's
  copyright notice and a "modified from herdr-core <path> at <commit>" line. Add an entry with the
  Apache-2.0 text to `THIRD_PARTY_NOTICES.md` and carry any upstream `NOTICE` content (there is
  none at cd12ddd or 7fe7ac3; check again at copy time). Apache §3: the patent grant ends for
  anyone who sues over the work.
- **Where Deckhand deliberately differs:** an authenticated holder and window (§5.3),
  Ed25519-signed core artifacts rather than a checksum manifest (§7.1), the core bundled in the
  app (herdr installs it separately), one-click remote updates (§8.4), a pipe spawn kind for jobs,
  and never stalling programs while no core is attached.
