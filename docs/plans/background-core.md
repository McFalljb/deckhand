# Deckhand background core and remote machines: design

Issues [#4](https://github.com/McFalljb/deckhand/issues/4) (sessions keep running after the
window closes) and [#5](https://github.com/McFalljb/deckhand/issues/5) (every machine in one
sidebar). Design only: no app code has changed. Investigated at `main` 6ee5586. Modelled on
Herdr 2 (herdr-core cd12ddd, herdr-app 7fe7ac3, Apache-2.0).

Status (2026-11-07): revision 2, after review round 1. The user's decisions are in §2. Gating
first tasks: the VT snapshot spike (S1) and the signing/runtime spike (S2), §10.

Revision 2 changes:
- Window and holder auth now rest on **release-signed CDHashes read from audit tokens**. The
  token file and the "not a holder descendant" check remain, but only as anti-accident checks.
- Ad-hoc builds ship with hardened runtime, and release builds carry no test hooks.
- **The holder upgrades itself by re-exec.** It no longer drains forever, and only a small
  bootstrap subset of its wire is frozen.
- Per-terminal byte offsets make handover exact.
- launchd use copies herdr's real detach model.
- Job runs stay out of the holder for now, and the stable socket and token persistence move
  into M1.
- New: a downgrade lock, remote caps, honest M1 limits and resized steps.

Contents: 1 Goal · 2 Decisions · 3 Process model · 4 What moves where · 5 Protocol ·
6 Lifecycle · 7 Updates and version skew · 8 Remote · 9 Alternatives · 10 Order of work ·
11 Risks · 12 Testing · 13 Open questions · 14 Credits and licence

---

## 1. Goal and non-goals

**Goal**
- pi, Claude Code and shells keep running when the window closes, crashes or the app updates.
  Reopening the window reattaches to them, with the screens as they are.
- Updating Deckhand, its core or its PTY holder does not stop sessions.
- A window shows sessions from cores on several machines (#5), over SSH, without new ports or
  logins.
- One version number and one signing key. The artifacts are the Mac app zip (core inside) plus
  a signed core tarball per remote target (§7.1).

**Non-goals (v1)**
- Surviving logout or reboot. After those, today's restore runs ([PERSISTENCE.md](../PERSISTENCE.md)
  "Restore").
- Several windows per core (M7).
- Browser pages or app tabs that outlive the window (decision 3). Their records survive and
  reload when the window returns.
- Agents browsing with no window (no headless CEF).
- Job runs that survive a core restart. In M1 they stop when the app exits, as today (§10).
- Linux or Windows *windows*. A headless Linux *core* is in scope for #5.

---

## 2. Decisions

**Made by the user (2026-11-07):**

| # | Question | Decision |
|---|---|---|
| 1 | Closing the last window | The core keeps running while any session process or job run is alive, and exits after a quiet period (default 10 min) once nothing is running and no window is attached. |
| 2 | ⌘Q | Closes the window only, and sessions keep running. A separate item, **Quit Deckhand and Stop All Sessions…**, stops everything (class `app_quit`). |
| 3 | App tabs | May die with the window in v1. |
| 4 | Remote core updates | A one-click offer when connecting to an older remote core (§8.5). |
| 5 | Apple Developer ID | **None.** Build the full split with ad-hoc signing, as strong as it can be without one, and state the residual risk plainly (§5.3). |

**Taken in this design (open to review):**

| Topic | Decision | Where |
|---|---|---|
| Processes | Window, core and PTY holder (herdr's model), not exec-in-place of the core | §3, §9 |
| Holder upgrades | **The holder re-execs itself** into the new build (its pid stays, so it remains the children's parent). Drain is only the fallback when an upgrade fails its preflight. | §7.3, §9 |
| Terminal output | Option (a): bytes are streamed, the window runs ghostty-vt, and a VT snapshot resyncs it | §5.4 |
| Identity anchor | The release Ed25519 key: a peer is trusted only if its **CDHash, read from its audit token**, is named in a release-signed record | §5.3 |
| Fresh copy without a verified record | **Fail closed.** It runs exactly as today's single process (no holder, no external core) until it has fetched and verified its own version's `.sig` | §5.3 |
| First step | M1 puts the holder in front of today's single-process app | §10 |
| Windows | One window per core in v1. View state stays in the core, so agents keep steering it as today. | §4 |
| Lifecycle | herdr's launchd detach (a unique label per launch, then fork, setsid and bootout) | §6 |
| Job runs | Stay children of the app (M1) or the core (M4). The holder gets no pipe kind in v1. | §4, §10 |
| Editor buffers | Stay in the window in v1. Closing a window with unsaved buffers asks first. | §4 |

---

## 3. Process model

```
 local Mac                                                     remote host (#5)
┌──────────────────────────┐
│ Window (Deckhand.app)    │  UI, CEF, app-tab frames, selection, IME,
│ ghostty-vt per shown tab │  key encoding, State replica, editor buffers
└───────────┬──────────────┘
            │ core.sock (framed): peer CDHash must be release-signed
┌───────────▼──────────────┐  ssh host deckhand-core connect   ┌──────────────────┐
│ Core (Deckhand Core.app) │◄──────── stdio, framed ──────────►│ remote Core      │
│ State, commands, socket, │                                   │ + its holder     │
│ jobs, ghostty-vt per     │◄── agents: pi bridges, Claude CLI, └──────────────────┘
│ terminal, persistence    │    Atlas, --ctl (NDJSON v1, as today)
└───────────┬──────────────┘
            │ holder.sock: holder wire (grow-only; frozen bootstrap subset)
┌───────────▼──────────────┐
│ Holder (deckhand-core    │  PTY masters, every session process as its child,
│ hold; re-execs to update)│  waitpid, foreground pgid, byte offsets, 1 MiB tails
└───┬──────────┬───────────┘
   pi tab   Claude tab, shells
```

| Role | Owns | Dies → |
|---|---|---|
| **Window** | drawing, input, CEF, app-tab processes, the ghostty-vt of shown terminals, editor buffers | Pages and app tabs go; reopening reattaches. |
| **Core** | State, `run_command`, the socket and tokens, events, jobs, persistence, the ghostty-vt per terminal (OSC 7501/133, mode 2004, DA/DSR, exit banners), remote links | The holder restarts it through launchd (§6). Screens come from the tails, marked `inexact`. |
| **Holder** | PTYs, children, reaping, byte offsets, tails; no parsing or policy | Its terminals get SIGHUP and are marked `holder_lost`; today's restore path follows. |

In M1 the "core" is today's single-process app (§10). Normally there is one holder per core. A
second one exists only while an upgrade fallback drains (§7.3).

---

## 4. What moves where

From the map's §2. C = core, W = window, H = holder.

| Subsystem (today's files) | v1 home | Change needed |
|---|---|---|
| PTYs, fork, reap (`pty.odin`, `pty_posix.odin`) | **H** | Calls become holder messages. `pty_foreground_busy` becomes `FOREGROUND`. `pty_resize` sends pixel sizes too (pty_posix.odin:147). |
| Job runs (`jobs_run.odin`) | **C** (the app in M1), **not H** | The reader thread enforces the loop detector, cost and turn limits, `needs_you`, the stall and timeout kills and the `events.jsonl` cap. The run lock is an inherited fd (jobs_run.odin:1-26, :149). Moving runs to the holder means carrying all of that across; revisit after M4. |
| ghostty `Terminal` per tab (`term.odin`) | **C** (+ a W copy for shown tabs) | Cols, rows and pixel sizes come from the window. |
| Drawing, selection, links, IME, key/mouse encoding | **W** | Unchanged, on the window's copy. That copy's `Write_Pty` is dropped. |
| State (`state.odin`) | **C**, with a W replica | View state stays in the core (one window). Pixel fields (`Pane.rect`/`frame`) are W-only. |
| `run_command`, inbox, command table | **C** | `app.redraw` (commands.odin:686 and 5 others) becomes a "state changed" hook. Toasts become an event. |
| Pane room and ratio checks (`panes_commands.odin` 141-194) | C, given W's size | The window sends its centre size with split and resize. |
| Socket, tokens, events | **C** | A stable `core.sock` (from M1). Framed mode for windows. `pd_frames_*` in the hello (socket.odin:856-861) asks the window. |
| pi/Claude logic, waits, held prompts, hot reload | **C** | A core loop, not `frame()`. |
| Jobs scheduler, Atlas, bell, notify model | **C** | OS banners come from `Deckhand Core.app` when no window is active. |
| Persistence | **C** | Adds a token file, written on every mint and revoke (§5.3). |
| Login env | **C** | Computed per spawn and sent in `SPAWN`. |
| Instance lock (`instance.odin`) | **C + H** | `instance.lock` is held `LOCK_SH` by holders and the core. `core.lock` (`LOCK_EX`) is the one-core rule (§7.5). |
| Browser tabs (CEF) | **W**, record in C | The core routes `browser_*` to the window as a tab host. No window: `{"ok":false,"code":"no_window",…}`. |
| App tabs | **W** (process too) | Shown as exited (`window_closed`) after the window closes. |
| Editor buffers | **W** | The record lives in C. Closing a window with unsaved buffers asks first. |
| Platform table | split | Core: wake, run_later, activity, notify. Window: clipboard, open_url, reveal, pick_folder, toast, appearance, `window_active`, via `window.request`. |
| UI, fonts, menus, autotest UI | **W** | — |

---

## 5. Protocol

### 5.1 Transport and framing

| Link | Transport | Framing |
|---|---|---|
| Agents, CLI ↔ core | `core.sock` in the runtime dir (below) | NDJSON v1, unchanged |
| Window ↔ core | `core.sock` | NDJSON hello with `framed:true`, then frames |
| Local core ↔ remote core | `ssh … deckhand-core connect` stdio | frames |
| Core ↔ holder | `holder-<rand8>.sock` | holder wire (§5.6) |

- **Runtime dir:** `~/Library/Application Support/pi-desk/run/` (0700), replacing `$TMPDIR/pi-desk-<uid>`.
  macOS cleans `/var/folders` under long-lived processes, and a core lives for weeks.
  `PI_DESK_RUNTIME_DIR` still overrides. Paths must fit 104 bytes: the dir is refused with a clear error
  when `holder-xxxxxxxx.sock` would not fit.
- **Stable name `core.sock`** from M1, replacing `pi-desk-<pid>.sock` (socket.odin:108). Adopted
  tabs keep `DECKHAND_SOCKET`/`PI_DESK_SOCKET` across app restarts. PROTOCOL.md §1 changes.
- **Framed mode** (herdr's layout): `[channel u32 LE][kind u8][len u32 LE][payload ≤ 16 MiB]`.
  Channel 0 carries JSON envelopes; channels ≥ 1 carry terminal streams. The kinds are `DATA`,
  `SNAPSHOT`, `RESIZE`, `CREDIT`, `CLOSE` and `FOCUS`. Unknown kinds are ignored.

### 5.2 Handshake

The hello reply gains `generation` (today's `v`), `version`, `build` (CDHash prefix), `features`,
`methods`, `machine` and `holder_wire`. A window's hello adds `{"window":{"version","generation"}}`
and the window token. Today no socket token maps to `ui` (socket.odin:850; only in-process callers
use `.UI`). **This design adds the first one**, so §5.3 is the critical boundary.

### 5.3 Auth

`ui` confirms for agents, sets permission modes and replays a Claude session's saved flags
(docs/CLAUDE.md §3). The holder can `SPAWN` and `INPUT` into every terminal. Both are guarded as
follows.

**The trust anchor.** A **release record** is a statement signed with the release Ed25519 key
(`UPDATE_PUBLIC_KEY`), naming a CDHash. There are two kinds:
- the app's existing v2 `.sig` manifest, which already names the CDHash of `Contents/MacOS/Deckhand`;
- a new **core statement** (`deckhand-core-statement v1`, fields `version`, `seq`, `cdhash`,
  `holder_rev`, signed), naming the CDHash of `Deckhand Core.app`'s executable.

Records are kept in `<data>/trust/`. Every use re-verifies the signature, so the folder is only a
cache, and tampering with it is a denial of service, nothing more. **A CDHash is never trusted
because `codesign --verify` passed**: an ad-hoc re-signed copy verifies too.

**Reading the peer's CDHash.** Take the peer's audit token from `LOCAL_PEERTOKEN`; the token
includes pidversion, so a process that execs after connecting fails. Get its code with
`SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`. Require `SecCodeCheckValidity` with
`kSecCSStrictValidate`, and read the CDHash from `kSecCodeInfoUnique`.

| Link | Real check | Anti-accident only (stops mistakes, not a deliberate agent) |
|---|---|---|
| Window → core | The peer's CDHash is in a verified app `.sig`. Hardened-runtime flags are present (`CS_RUNTIME`), with no `get-task-allow`. The window binary is a release build: test hooks are compiled out (below). | The window token in `run/window.token` (0600; never in any environment; `child_env` drops its name too). The peer must not descend from a holder: a deliberate agent gets around this with double fork, `setsid`, `launchctl submit`, `open`, `osascript`, `at` or a LaunchAgent. |
| Core → holder | The peer's CDHash is in a verified core statement (M1: an app `.sig`, because the app is the core). The holder **refuses `HELLO` while a core is attached**. A planned handover names its successor: `GOODBYE{handover, successor_cdhash, handover_id}`, and for 60 s only that CDHash may say hello. Otherwise, after a crash, any signed core with `seq ≥ floor` may. **The floor** is the highest `seq` that stayed attached and healthy for 60 s; it only rises, so an unsolicited downgrade to an older signed core is refused. Deliberate downgrades go through a named successor (§7.6). | `handover_id` must match `handover.json`. It's a consistency check, not a secret. |
| Holder → core (reverse) | When the core connects, it reads the holder's audit-token CDHash and requires a core statement for it. A swapped holder binary is detected and reported (§11, R3). | — |
| Agents → core | Unchanged (PROTOCOL.md §2). Claude tokens still need the peer to **descend from** its tab (socket.odin:247-258). That is the opposite polarity of the holder rule above, and both hold. | — |
| Remote | §8.3 | — |

**Hardened runtime on ad-hoc builds.** Today ad-hoc release signing passes no `--options runtime`
(release.sh:214-219; only the Developer ID path at :200 does). Change it to
`codesign --force --sign - --options runtime --entitlements …` for the app, the core and the CEF
helpers:
- **Allowed:** `allow-jit` and `allow-unsigned-executable-memory` (already in `app.plist`), and
  `disable-library-validation` only on the binaries that need it to load the ad-hoc CEF framework.
- **Never:** `get-task-allow` or `allow-dyld-environment-variables`.

This blocks `DYLD_INSERT_LIBRARIES` and same-user debugger attach. **S2 checks** whether ad-hoc
library validation lets the window load ad-hoc CEF. If the window needs
`disable-library-validation`, a copy of the app with a modified *library* (the main executable
unchanged, so its CDHash is unchanged) would pass the check. In that case the core also requires
the peer's bundle path to be the installed app's, and runs `codesign --verify --deep --strict` on
that bundle at connect. That narrows the gap but doesn't close it: the check races the load.

**Test hooks out of release builds.** `PI_DESK_SCRIPT` and the scene hooks, `PI_DESK_QUIET`,
the update fixtures, `--print-token script` and any env-driven input are compiled behind
`-define:DECKHAND_TEST_HOOKS` (main.odin:1100, :1154-1156). `scripts/release.sh` builds without it
and checks the binary has no hook strings. `--print-token control` stays: it is never `ui`.

**Fresh copies (no verified record).** At first start, a release build fetches its own version's
`.sig` from `UPDATE_REPO` and verifies it. The updater stores the `.sig` it downloads. **Until a
record verifies, the copy fails closed:** it runs as today's single process, with no holder
use and no external core, and Settings says why. Development builds (no release key) compile in
a **dev allowance**: same-user trust, and windows started inside Deckhand tabs allowed, which
agent-run scenes need. It is compiled out of releases.

**Compared with today's barrier (ad-hoc, no hardened runtime, `ui` in-process only):**

| Attack by same-user code | Today | This design |
|---|---|---|
| An agent's token becomes `ui` | impossible | impossible |
| A script connects as a window | n/a (no socket `ui`) | refused: CDHash not release-signed |
| A modified, re-signed copy installs or connects | n/a | refused: its CDHash has no record (closes the copy-swap-resign-install path) |
| Injecting into the running window | possible at a launch the attacker controls (`DYLD_*`); debugger attach where DevToolsSecurity is on | blocked by hardened runtime (subject to the library-validation question in S2) |
| Synthesised input into the window (CGEvent, `osascript`) | needs Accessibility (TCC) | same |
| Killing Deckhand and starting a modified copy that restores with the user's flags | possible, visible | running sessions: refused (the holder only accepts signed cores). `workspace.json` can still be read by anyone, as today. |
| Killing every session | `kill` | same: SIGKILL the holder (visible) |

**Residual risk, stated plainly:**
- Same-user code with Accessibility or other TCC grants.
- Root, or SIP turned off.
- A user tricked into running a modified app.
- The library-validation gap, if S2 confirms it.
- An upgrade-time binary swap (R3).

Without a Developer ID there is also no team identity to pin, so trust rests entirely on the
release key and the records.

Permissions, as in herdr and today: dirs 0700 and refused if not owned or not a real
directory; sockets, tokens and handover files 0600.

**Token persistence (from M1).** `<data>/tokens.json` (0600) is rewritten atomically on every
mint and revoke. It holds only SHA-256 hashes, never tokens:
- pi env tokens, with a used flag;
- pi reconnect tokens;
- Claude tokens, with the tab's root pid (`claude_pids`);
- the read-only profile's ack state and nonce.

After adoption, a read-only Claude tab whose ack state is unknown **fails closed**: it is
stopped and revoked, as the existing no-ack rule does (docs/CLAUDE.md §1a).

### 5.4 Terminal streams (option a)

```
window: term.attach {tab_id, history_lines}       → {channel, offset}
core:   [ch][SNAPSHOT] meta JSON + VT bytes at that offset
core:   [ch][DATA] bytes from offset, coalesced ≤ 8 ms or 64 KiB
core:   [ch][RESIZE] {offset, cols, rows, xpixel, ypixel}   (applied at that byte offset)
window: [ch][DATA] encoded input · [ch][CREDIT] n · [ch][FOCUS] · term.detach
```

- The core is the only resize authority, and the only one that answers terminal queries.
- Snapshot = VT bytes plus meta (cursor, modes, title, colours, OSC 7501 status, exit state).
  It is version-independent, so window attach, core handover and downgrades all use it. **S1
  gates it.**
- Hidden tabs aren't streamed. Detach happens 2 s after a tab is hidden.

### 5.5 Flow control

| Where | Rule |
|---|---|
| Core → window | Credit, starting at 256 KiB. More than 4 MiB behind: a fresh `SNAPSHOT`. Channel 0 never blocks. |
| State | Deltas at ≤ 60/s. Overflow sends a full state. |
| Holder → core, core attached | Queue 8 MiB, then stop reading the PTY (the program waits), as herdr does. |
| Holder, no core for longer than 3 s | Keep reading into the 1 MiB tail only, so programs never stall. The offset keeps counting; a gap means `inexact` (§7.2). |

### 5.6 Holder wire

Layout (herdr's): `[kind u8][terminal u32 LE][len u32 LE][payload ≤ 16 MiB]`. Control payloads
are JSON and terminal bytes are raw.

- **Frozen forever** (the bootstrap subset): the header, `HELLO`, `WELCOME`, `REFUSED`, `UPGRADE`
  and `UPGRADE_FAILED`, with their required fields. Any future core can therefore authenticate
  to, and upgrade, any old holder.
- **Everything else is grow-only**, versioned by `wire` in `HELLO`/`WELCOME`: kinds and optional
  fields are added, and nothing is removed. Unknown fields are ignored. An unknown kind gets
  `UNKNOWN{kind}` and is otherwise ignored, so a core can tell.

| core → holder | holder → core |
|---|---|
| `HELLO{wire, record, handover_id?}` | `WELCOME{wire, instance, pid, holder_rev, cdhash, previous: none\|handover\|crash\|upgrade, terminals[{id, pid, pgid, cols, rows, xpixel, ypixel, offset, exit}]}` |
| `SPAWN{argv, env, cwd, cols, rows, xpixel, ypixel}` | `TAIL{start u64}` + bytes (one per terminal, after `WELCOME`) |
| `INPUT` | `OUTPUT`: `start u64` + bytes |
| `RESIZE{cols, rows, xpixel, ypixel}` | `SPAWNED{pid, pgid}` · `SPAWN_FAILED{error}` |
| `SIGNAL{signal, target: pid\|pgroup}` | `EXITED{code, signal, offset}` (sent after the output up to `offset`) |
| `RELEASE` (close the master) | `GOODBYE_ACK{terminals[{id, offset}]}` |
| `GOODBYE{mode: handover\|shutdown, successor_cdhash?, handover_id?}` | `FOREGROUND_IS{pgid}` |
| `FOREGROUND` | `REFUSED{code: wire\|record\|signature\|floor\|attached\|successor, error}`, then the holder closes |
| `UPGRADE{path, record}` | `UPGRADE_FAILED{error}` |
| `PING` (every 5 s) | `PONG`. The holder drops a core that misses pongs for 30 s, so a hung core can't block its successor. |

Herdr has none of these: pixel sizes, offsets, `GOODBYE_ACK`, `REFUSED`, `UPGRADE`, liveness and
pgroup signals. The holder also disclaims TCC responsibility at start (herdr's
`macos_responsibility.rs` re-exec), so privacy prompts belong to it rather than to its launcher.

### 5.7 State replication

- `state.subscribe` returns `state.full{version, state}`, followed by `state.delta{version, sections}`.
  The sections are `projects`, `sessions`, `tabs:<s>`, `panes:<s>`, `settings`, `jobs`,
  `confirmations`, `notifications`, `update`, `panels:<tab>` and `machines`.
- The window decodes into a replica with `State`'s shape. That decoder is new (M3).
- Core → window messages: `toast`, `confirmation.parked`, `window.request{op}` (answered by
  `window.reply`) and `tab_host.call` (answered by `finished`).

---

## 6. Lifecycle

**Starting a process outside the app: herdr's launchd model** (macos_launchd.rs:176-262):
1. The launcher makes a 0700 temp dir holding `job.plist` (0600) and a `ready` socket. The
   label is unique per launch: `dev.deckhand.<core|hold>.<pid>.<ns>`.
2. It runs `launchctl bootstrap gui/<uid>` and removes the plist.
3. The job runs `deckhand-core __detach <ready>`, which forks. The parent exits, and the child
   calls `setsid` and execs (fresh libdispatch state), then waits until its ppid is 1.
4. The child connects to `ready`. The launcher **boots the job out**, then sends the inherited
   environment (and, for a handover, the `handover_id`). The child acks and starts serving.

The result belongs to no launchd job and none of the app's coalition, and a fixed label never
blocks the next launch. A failed bootstrap falls back to a direct spawn, with a logged warning
that it may end with the app.

| Event | What happens |
|---|---|
| A core is needed (window, `deckhand DIR`, `--ctl`) | Connect to `core.sock`; otherwise launch the core as above and wait up to 15 s. |
| Core starts | Take `core.lock` (EX) and `instance.lock` (SH). Verify its own record. Adopt the holder: `HELLO`, then `WELCOME`/`TAIL`. Restore from `handover.json` if it is fresh and readable, else from `workspace.json` + `tokens.json`. Serve. |
| ⌘Q, window closes | The window exits and the sessions run on. The first time, a notice says so. |
| Idle | No window, no live tab process and no job run for 10 min: save, exit. A holder with no terminals exits. |
| Quit Deckhand and Stop All Sessions… | `quit` (class `app_quit`): persist, `GOODBYE{shutdown}`, exit. |
| Core crashes (M4+) | The holder relaunches it **through the same launchd launcher** (holder.rs:423-447 backoff: 3 s grace, 2ⁿ, capped at 60 s). That also keeps the core from descending from the holder. |
| App crashes (M1) | Nothing restarts it. The sessions run on, and the next launch adopts them. |
| Logout or reboot | Everything stops; today's restore follows. |

Rejected alternatives: the window spawning the core. It stays in the app's coalition, which
macOS may kill on quit, as herdr found in 0.1.17. An SMAppService login agent needs a Login Items
prompt and makes the dev loop harder; it is deferred to M5, for jobs while closed.

---

## 7. Updates and version skew

### 7.1 Artifacts

```
Deckhand.app/
  Contents/MacOS/Deckhand                      window (hardened runtime, ad hoc)
  Contents/Helpers/Deckhand Core.app/          dev.deckhand.core: deckhand-core (serve | hold |
      Contents/MacOS/{deckhand-core,deckhand}  connect | check | install | __detach), the CLI,
      Contents/Resources/integrations/…        pi and Claude integrations
  Contents/Resources/core.statement            signed core statement (a data file, so in Resources)
```

- `core.statement` sits in `Contents/Resources`. A data file in `Contents/Helpers` would likely
  fail the `codesign --verify --deep --strict` that **existing updaters run** (update.odin:641).
  Release step: **test the new zip with the current release's updater** (`tests/scripts/update.sh`
  driven by the previous release's binary) before publishing.
- **Signing order:** Core.app → its CDHash → sign the statement → copy it into Resources →
  sign Deckhand.app → today's v2 manifest and `.sig` (unchanged).
- **Remote targets:** `deckhand-core-<v>-<os>-<arch>.tar.gz` and `.sig`, in today's manifest
  format (`cdhash none` on Linux). That is Ed25519, never checksum-only.
- **Install:** copy from the *verified* bundle to
  `~/Library/Application Support/pi-desk/core/<v>/`, strip `com.apple.quarantine`, and re-verify
  against the statement. `current` and `previous` are symlinks switched by rename. A version is
  collected when it is neither of those, no live process runs from it, and no tab was started
  from it. The integrations live there, so live tabs keep their paths across an app swap.
- **TCC cost of ad-hoc signing:** grants are keyed by CDHash, so each new core version re-prompts.
  **Full Disk Access silently stops applying**: programs just get `EPERM`. GUIDE.md must say so.
  This is a direct cost of decision 5.

### 7.2 Core handover (byte-exact)

1. **Old core → holder:** `GOODBYE{handover, successor_cdhash, handover_id}`.
2. **Holder:** stops sending `OUTPUT` and replies `GOODBYE_ACK{terminals[{id, offset}]}`, where
   `offset` is the last byte it sent. It keeps reading into the tail from there.
3. **Old core:** feeds every byte up to each acked offset into its emulator, then snapshots each
   terminal **at exactly that offset**. It writes `handover.json` (0600):
   - `min_reader`;
   - the runtime ids and the tab ↔ terminal map;
   - pending confirmations, held Claude texts and waits;
   - the snapshot offsets.

   Token hashes are already in `tokens.json`. It flushes `workspace.json`, points `current` at the
   successor, launches it (passing `handover_id` over `ready`) and releases its locks.
4. **New core:** `HELLO` (accepted only from `successor_cdhash`), then gets `WELCOME` and
   `TAIL{start}` per terminal:
   - `start == snapshot offset`: exact;
   - `start < snapshot offset`: skip the overlap, still exact;
   - `start > snapshot offset` (the tail was trimmed): **`inexact`**.
5. **Query replies** found in the replayed tail are answered only after an exact handover, and
   only if they are less than 2 s old (by `handover.json`'s time). Older ones are dropped, so
   `^[[?1;2c` never lands in vim.
6. **Lost at a handover:** requests in flight (a pending browser action, a long-running
   `claude_wait_idle`). Their connections close, and callers see a reconnect. This is documented
   in PROTOCOL.md.

### 7.3 Holder upgrade (re-exec)

Only when `WELCOME.holder_rev` is older than the new core's. `holder_rev` is bumped by hand, and CI
fails if holder source changed without a bump. That keeps holder upgrades rare.

1. The core sends `UPGRADE{path, record}`. The holder verifies the record, and that the file at
   `path` has that CDHash.
2. **Preflight:** the holder writes its state to a 0600 unlinked file:
   - the terminals: id, pid, pgid, master fd, sizes, offsets, exits not yet reported;
   - its tails and backlog;
   - the listening fd and the `instance.lock` fd.

   It then runs `path hold --check-state <fd>` **as a child**. The child must parse the state,
   print its `holder_rev` and `wire`, and exit 0.
3. **Re-exec:** the holder pauses its pumps (output waits in the kernel PTY buffer), clears
   `FD_CLOEXEC` on the masters, the listener, the lock and the state fd, and calls
   `execve(path, hold --resume-fd N)`. **The pid is unchanged, so it stays the parent of every
   child.** If `execve` fails, the old image restores CLOEXEC, resumes and sends
   `UPGRADE_FAILED`.
4. **The new image:**
   1. reads the state and sets CLOEXEC again;
   2. reaps exits that happened during the gap (`waitpid(-1, WNOHANG)`);
   3. resumes the pumps;
   4. binds a fresh socket, so its peer credentials are post-exec (the listener's credentials
      were captured at `listen`);
   5. lets the core reconnect, with `previous: upgrade`.
5. **Fallback:** on `UPGRADE_FAILED`, or a preflight failure, the old holder keeps its terminals.
   The core speaks its older wire (grow-only), and new terminals go to a new holder. This drain is
   the only case where two holders exist.

### 7.4 App update, step by step

1. **Download and verify** as today. The updater also stores the `.sig` in `trust/`.
2. **Confirm:** the prompt says "Browser pages will reload and app tabs will restart". It no
   longer says sessions will stop.
3. **Swap the bundle** as today.
   - **M1** (the app is the core): the old app performs §7.2 with
     `successor_cdhash` = the new app's CDHash (from the verified `.sig`), then quits; `open`
     relaunches it.
   - **M4+:** the window relaunches, runs the bundled `deckhand-core install`, and sends
     `core.handover{to}`. The core performs §7.2, then §7.3 if `holder_rev` changed.
4. **Reconnect:** windows and agents reconnect (pi with its reconnect token, Claude with its env
   token, both checked against `tokens.json`).
5. **Health:** a core is healthy after 60 s attached without a crash. Only then does the holder's
   floor rise to its `seq`.

### 7.5 Version skew

| Seen at hello | Result |
|---|---|
| Same generation, core ≥ `CORE_MIN` | Works. Optional behaviour is gated on `features`. A local core older than the app is handed over at once. |
| Same generation, core < `CORE_MIN` | Locally: an automatic handover to the bundled core. If that fails: **"Deckhand's background core is out of date"** (Retry, Details). |
| Core generation > app generation | **"Update Deckhand: its background core is newer than this app"**, with Update or Use this app's core (a handover to an older core, §7.6). |
| Core generation < app generation | Locally: hand over to the bundled core. |
| Holder wire older than the core's | Speak the older wire (grow-only), then `UPGRADE`. |

**Grow-only API:** `schema/released-v1.json` is generated from `command_table.odin` and the
encoders. It lists commands and args (required or optional), result, event and state fields,
frame kinds and features. A unit test (< 1 s) fails on any non-additive change.
`scripts/release.sh` refreshes the file at the tag. The holder wire has its own
`released-holder.json`, plus golden vectors for the frozen subset.

### 7.6 Failure modes and rollback

**Rollback is decided by the supervisor or the window, never by the core that is crashing.**

| Failure | What happens | Sessions |
|---|---|---|
| `check` of a new core fails | No handover. "Couldn't finish updating the background core"; the old core carries on. | Kept |
| A new core crashes twice within 5 min of a handover | The holder's supervisor relaunches the last core that was **healthy** (which `previous` names), not `current`, and the window says "Update rolled back". The floor never rose (step 5), so the holder accepts it. | Kept, `inexact` |
| Use previous core (Settings › About, and in the rollback banner) | The window asks the running core to hand over to `previous` as a named successor. That is allowed under the floor. | Kept |
| `current` swapped by same-user code | Every launch and every `HELLO` re-verifies the record: refused, "the background core failed verification". This is a denial of service. | Kept (supervisor uses last healthy) |
| Old core crashes before `GOODBYE` | A crash restart. No snapshot: screens from tails, `inexact`, no query replies. | Kept |
| `handover.json` missing, stale (> 3 min, another boot) or `min_reader` above the reader | Fail closed: restore from `workspace.json` + `tokens.json` as after a crash, and drop parked confirmations and held texts. | Kept |
| Holder upgrade preflight or `execve` fails | Fallback drain (§7.3 step 5). | Kept |
| The new holder image crashes after `execve` | **Every session dies** (the masters close); `holder_lost`, then today's restore. Mitigated by the preflight, a tiny holder, upgrade tests under load and rare `holder_rev` bumps. | **Lost** |
| A holder crashes | `holder_lost`: pi and Claude resume from disk, shells restart fresh. | Lost |
| Downgrade to a pre-M1 app | It wants `instance.lock` EX, and holders hold it SH, so it refuses to start ("Deckhand is already running"). It never resumes conversations still running in holders. The notice says: open the newer Deckhand, or use Quit and Stop All Sessions there first. | Kept |
| Downgrade to an older M1+ app | Its CDHash's `seq` is below the floor: the holder refuses it unless the running newer core names it as successor (Use this app's core). Otherwise: "These sessions are held by a newer Deckhand". | Kept |
| Disk full while writing the handover | Abort before `GOODBYE`; the old core carries on. | Kept |

---

## 8. Remote (#5)

### 8.1 Connection

- Only the local core dials remote cores: `ssh -S <run>/ssh-<host>.ctl -o ControlMaster=auto
  -o ControlPersist=600 host …/core/current/deckhand-core connect`, using the user's `ssh` and
  `~/.ssh/config`. Banner lines are skipped; prompts mark the machine `needs_login`.
- Ids are `{machine, id}`, and the sidebar groups by machine. Reconnects use backoff, and an
  offline machine shows its last-known sessions greyed out.
- **`machine add`, `machine update` and `--via` are `ui`-only.** An agent can't name a transport
  command.

### 8.2 What stays local

| Kind | Remote session |
|---|---|
| pi, Claude, shells, jobs | On the remote host |
| Browser tabs | In the local CEF (capped, §8.3) |
| App tabs | Left out in v1 |
| Screenshots and crops | Fetched with `file.read` |

### 8.3 Trust in both directions

| Direction | Rule |
|---|---|
| Local → remote | SSH is the auth. The remote relay gets `ui` if it is that core's own binary and doesn't descend from a remote holder (anti-accident, as locally). **On Linux, remote `ui` means "same remote user"**: there are no audit-token CDHashes or hardened runtime there. Local callers' requests carry `on_behalf:{kind}`. The local core checks `caller_may` first, and the remote core applies the kind's rules again (it can only lower `ui`). |
| **Remote → local** | The remote core (perhaps a compromised host) is capped at **`panel` scope for that machine's own sessions**: no `window.request` (clipboard, open_url, notify, reveal, pick_folder), no OSC 52 to the local clipboard (it is ignored for remote terminals), and no `browser_*` to local loopback or LAN addresses unless the user forwarded that port. It cannot confirm anything. |
| ControlMaster | Residual: for `ControlPersist`, any local same-user process can use the control socket, so local agents could too. They can already use the user's SSH keys and agent, so this adds little. The control socket lives in the 0700 runtime dir. |

### 8.4 Install

`machine add` runs `uname -sm`.
- **OS and arch match:** copy `core/current`, **re-verifying its statement first**, so a tampered
  local copy is never pushed.
- **Otherwise:** download the same version's tarball, verify its `.sig` locally, and copy it over
  SSH.
- It installs to `~/.local/share/deckhand/core/<v>/`, then runs harness setup (HARNESSES.md).
- **Linux:** the core runs as systemd user services, which need **`loginctl enable-linger`**:
  without it they die when the last SSH login ends. Setup asks for it, and shows the command
  when polkit refuses. `XDG_RUNTIME_DIR` is removed at logout, so remote sockets live in
  `~/.local/state/deckhand/run/` (0700). A headless Linux core build and release target is its
  own work item.

### 8.5 Remote updates (decided: one-click offer)

An older remote core of the same generation shows an **Update** button on its machine row. A
click copies the build as in §8.4 and runs §7.2 and §7.3 there, so the remote sessions keep
running. `needs_update` (below `CORE_MIN` or an older generation) offers the same button. There
are no downgrades. A remote core not in Deckhand's folder shows the command instead and is left
alone.

**Why not herdr's manual update:** Deckhand installs its own core into its own folder and owns
both ends of the wire, so an update is a session-keeping handover. Lag is safe under grow-only
but invisible. One click (not automatic) lets the user pick the moment, because the remote
sessions pause briefly.

---

## 9. Alternatives

**Core restart: holder vs exec-in-place of the core** (map §6)

| | Holder (chosen) | Core exec-in-place |
|---|---|---|
| Core crash | Holder relaunches it; sessions kept | **All sessions die** |
| Bad new core | Rollback to last healthy; kept | All die |
| Contract | holder wire | the in-memory handover format |
| Processes | +1 | 0 |

**Holder upgrade: re-exec (chosen) vs drain (herdr)**

| | Re-exec | Drain |
|---|---|---|
| Old sessions get holder fixes | at once | only when those tabs close (weeks for a pi session) |
| Frozen wire | the bootstrap subset only; the rest grows | **the whole wire, forever**. Review round 1 already found it too narrow (pixel sizes, pipe options, liveness) before it shipped. |
| Holders alive | one | one per build still holding tabs |
| A bad holder build | can kill every session (crash after `execve`) | hurts only new terminals |
| Code | state serialise and restore, fd CLOEXEC handling, preflight (~400 lines, all in the holder) | none extra, but the core must speak every old wire |

Re-exec wins because freezing the full wire forever costs more, and costs it on every future
change. A bad holder is a rare event with several guards (preflight, tiny code, upgrade tests,
rare `holder_rev` bumps). Drain stays as the fallback, which keeps the blast radius small
whenever the preflight catches a problem.

Also rejected: fd passing (children reparent to launchd and exit codes are lost), one holder
per terminal (100+ processes), and tmux (a second emulator, no native Windows; ROADMAP
2026-10-30).

---

## 10. Order of work

Every step ships on its own.

| # | Step | Ships | Size |
|---|---|---|---|
| Q0 | **PTY master fds CLOEXEC.** pty_posix.odin:111 sets only `O_NONBLOCK`, so every later child inherits every earlier master. Add a test that a new shell holds no other master. | Closing a tab reliably hangs it up | ½ day |
| S1 | **VT snapshot spike** (gating): whole-screen VT from libghostty-vt v1.4.0's selection formatter, plus modes. Pass test: recorded streams through emulator A, snapshot into B, compared cell by cell. Fallback: synthesised CUP+SGR+text (~200 lines). | Go/no-go for option (a) and exact handover | 1 week |
| S2 | **Signing and runtime spike** (gating): hardened runtime on ad-hoc builds with CEF (does library validation load ad-hoc CEF?); audit-token CDHash reads; herdr-style launchd detach on macOS 14 and 15; a survivor of app quit; holder re-exec with live PTYs; the TCC disclaim. | Facts for §5.3, §6, §7.3 | 1 week |
| M1 | **Holder in front of today's single-process app.** The holder (Odin, no ghostty or sokol), its wire and golden vectors, re-exec upgrade, release-record auth (the app's `.sig`, fetching it for fresh copies), launchd detach, stable `core.sock` and the runtime dir move, `tokens.json`, offsets and exact handover on quit and update, the `instance.lock` SH rule, hardened runtime and test hooks compiled out in `release.sh`, the updater test against the current release. Two security review rounds. **Doc changes:** PROTOCOL.md §1, CLAUDE.md §4a (an updated plugin applies to kept Claude tabs only after a restart, which the bar offers), PERSISTENCE.md, DEVELOPING.md "Releases", GUIDE.md. | **Quitting, crashing or updating Deckhand no longer stops pi, Claude or shells**, and reopening shows their screens. **While the app is closed:** no status dots or bell; the `deckhand` CLI and Claude hooks fail (a Claude `/clear` id isn't recorded, so restore may resume the old conversation); held prompts wait; Atlas jobs don't run, and **job runs stop when the app exits** (as today); in-flight requests are lost. | **6–8 weeks** |
| M2 | **Boundary** (map M0): `src/core` with no sokol or Clay; fix the leaks; a core loop | Compiler-checked split; hidden windows stop stalling parsing | 2–3 weeks |
| M3 | **In-process client and server** (map M1): the replica and decoder, streams over an in-memory channel, the `ui` path, tab host routing | The real protocol under every test | 4–6 weeks |
| M4 | **Separate core** (`Deckhand Core.app`): window auth (§5.3), lifecycle, ⌘Q and stop-all, `no_window`, skew handshake, `CORE_MIN`, install and core handover, supervisor rollback, Use previous core, `released-v1.json`. Job runs become core children; a handover waits ≤ 2 min for them, then stops them as `stopped_by_update`. Two security review rounds. | **#4 done:** status, bell, CLI, hooks, held prompts and jobs work with the window closed | 5–7 weeks |
| M5 | Login agent; jobs while closed | Scheduled jobs with Deckhand closed | 1–2 weeks |
| M6 | **Remote:** connect, install, update, caps (§8.3), sidebar, offline states, file fetch, browser tabs local, harness setup, plus a **headless Linux core and release target** | **#5 done** | 7–11 weeks + 2–3 for Linux |
| M7 | Several windows | More windows | 2–4 weeks |

Total: about 30–45 weeks. M1 alone delivers most of #4's value.

---

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Snapshot fidelity and two-emulator determinism | S1. Resize is sequenced by offset. Randomised determinism tests. |
| R2 | Minting `ui` and the holder owner over sockets, without a Developer ID | §5.3. Two security review rounds each in M1 and M4. The residual risk is stated. |
| R3 | TOCTOU between the holder verifying `UPGRADE`'s file and `execve` (macOS has no `fexecve`): same-user code that swaps the file gets the holder | The core checks the re-exec'd holder's audit-token CDHash on reconnect, and warns and refuses on a mismatch. Same-user residual. |
| R4 | A new holder image crashing after `execve` kills every session | Preflight `--check-state`, a tiny holder, upgrade-under-load scenes, rare `holder_rev` bumps |
| R5 | `disable-library-validation` needed by ad-hoc CEF | S2. If needed: a bundle path check and a deep verify at connect (narrows, doesn't close). |
| R6 | TCC re-prompts and Full Disk Access silently lost on every core version (decision 5) | Document it in GUIDE.md. The window shows a hint when a tab gets `EPERM` under a protected folder. |
| R7 | M1's closed-app gap (§10) | Hooks must fail safe. The read-only guard never needs the socket (check in M1). M4 closes the gap. |
| R8 | Bundle-relative paths under live sessions | Everything lives in `core/<v>/`, which is collected only when nothing uses it |
| R9 | Moving ticks off `frame()` changes scene timing | M2 keeps a `core_tick()` called from `frame()` until M4 |
| R10 | Remote: Linux build, linger, SSH quirks | Its own work item; `--via` in tests; linger in setup |
| R11 | Scope | Every step ships on its own |

---

## 12. Testing (every new test runs in seconds; no run exceeds 3 min)

| What | How | Time | Layer |
|---|---|---|---|
| Holder wire | Golden vectors for the frozen subset (a test fails if one *changes*); a fuzz pass over the decoder; `released-holder.json` grow-only diff | < 1 s | unit |
| Holder behaviour | An in-process holder and a fake core over a socketpair, with `/bin/sh` children: spawn, input, resize with pixels, signals, exits after output, offsets, tail cap, backlog, `REFUSED` cases (attached, floor, successor, bad signature), ping timeout | ~3 s | unit |
| Holder re-exec | A real holder process with 6 children printing a counter: `UPGRADE` 5 times under load. Checks: pids and parent unchanged, offsets continuous, no lost bytes; a failed preflight leads to drain; a failed `execve` restores the old image | ~10 s | unit |
| Grow-only API | Generated schema against `released-v1.json` | < 1 s | unit |
| Skew and auth decisions | Pure `skew_check` and `peer_allowed` table tests (records, floor, successor, dev allowance) | < 1 s | unit |
| Release build | `release.sh` checks: no hook strings, `CS_RUNTIME` set, no `get-task-allow`; the current release's updater installs the new zip | ~1 min | release only |
| Snapshot and determinism | The S1 corpus, plus random chunking and resizes | ~5 s | unit |
| Handover | Scene: a test-mode core (`serve --foreground`), 6 fake terminals, 5 handovers under load. Checks: screens equal and `exact`, tokens reconnect (pi reconnect, Claude ancestry), a read-only tab with an unknown ack is stopped. Variants: kill -9 core (`inexact`), kill -9 holder, a new core crashing twice (supervisor rollback). | ~40 s | scene |
| Downgrade lock | A stand-in for a pre-M1 instance-lock taker fails while a holder lives | < 1 s | unit |
| Window attach | Close the window, output continues, reopen, compare | ~30 s | scene |
| Remote | A second core with its own dirs over `--via 'deckhand-core connect'` (no sshd): install, caps (`window.request` refused, OSC 52 ignored), reconnect | ~30 s | scene |
| launchd and real signing | Test mode never bootstraps launchd and uses the dev allowance; this is covered by S2's manual checks and one nightly scene | — | nightly |

---

## 13. Open questions

| # | Question | Proposed default |
|---|---|---|
| Q1 | Should enabled job schedules keep the core alive, or start it at login (M5)? | Yes, from M5 |
| Q2 | Quiet period before an idle core exits | 10 min, not a setting |
| Q3 | A shortcut for Quit Deckhand and Stop All Sessions | Menu only |
| Q4 | Automatic `-L` forwards for remote `localhost` URLs | Ask per port |
| Q5 | First remote targets | macOS arm64, Linux x86_64 |
| Q6 | Several windows (M7): which window do agents steer? | The most recently focused |
| Q7 | Holder upgrades: automatic on `holder_rev` change, or ask first? | Automatic, named in the release notes |

---

## 14. Credits and licence

The process roles, holder handover and adoption, generation plus grow-only API plus
released-schema test, credit flow control, the launchd detach and the remote model follow
**Herdr 2** ([herdr-core](https://github.com/herdrdev/herdr-core),
[herdr-app](https://github.com/herdrdev/herdr-app), Apache-2.0).

- **No code is copied.** Herdr is Rust; Deckhand is Odin. Deckhand reuses designs and two wire
  layouts: the holder frame `[kind u8][id u32 LE][len u32 LE]` and framed mode
  `[channel u32 LE][kind u8][len u32 LE]`. Message names follow herdr's. A wire format isn't code,
  and Apache-2.0 asks nothing for it. Credit herdr here and in PROTOCOL.md's framed-mode section.
- **If herdr source is ever translated line by line:** keep herdr's copyright notice in that
  file, add a "modified from herdr-core <path> at <commit>" line, and add the Apache-2.0 text to
  `THIRD_PARTY_NOTICES.md` with any upstream `NOTICE` (none at cd12ddd or 7fe7ac3; check again at
  copy time).
- **Where Deckhand deliberately differs:**
  - a signed-CDHash-authenticated holder and window (herdr trusts any same-user `HELLO`);
  - holder re-exec rather than drain;
  - byte offsets;
  - Ed25519-signed core artifacts (herdr's manifest is checksum-only);
  - the core bundled in the app;
  - one-click remote updates;
  - programs never stall while no core is attached.
