# Deckhand background core and remote machines: design

Issues [#4](https://github.com/McFalljb/deckhand/issues/4) (sessions keep running after the
window closes) and [#5](https://github.com/McFalljb/deckhand/issues/5) (every machine in one
sidebar). Design only: no app code has changed. Investigated at `main` 6ee5586. Modelled on
Herdr 2 (herdr-core cd12ddd, herdr-app 7fe7ac3, Apache-2.0).

Status (2026-11-07): revision 4. Both spikes are done and folded in here. Q0 is merged (#18).
M1 is broken into PRs in §10.1. The user's decisions are in §2.

- **S1 (VT snapshot): GO,** via libghostty-vt's binary snapshot (GHOSTSNP v1). It was exact in
  360/360 runs. Branch `spike/vt-snapshot` 6bf748e, `tools/vt-snapshot-spike/`.
- **S2 (platform), on macOS 26.6.2 only:**
  - Audit tokens are *live*.
  - launchd detach works.
  - Holder re-exec works, but `execve("/dev/fd/N")` doesn't.
  - Ad-hoc builds can't load ad-hoc CEF under library validation.
  - Quarantine SIGKILLs a launchd-started binary.

Revision 4: §5.3 (live audit tokens), §5.5 and §7.2 (GHOSTSNP), §6 (launchd facts), §7.3 (the
keeper-gated handover replaces `/dev/fd/N`), §9, §10.1, §11, §12.

Revision 3:
- Identity is a **Developer ID designated requirement** checked by audit token, with library
  validation on everywhere. The ad-hoc mitigations are removed; §5.4 says what ad-hoc builds
  trust until the Developer ID arrives.
- Kept and added: test-only config overrides, a real successor secret, HMAC'd state files,
  mutual window ↔ core auth, and the round-2 polish (P1–P9) as implementation notes.

Contents: 1 Goal · 2 Decisions · 3 Process model · 4 What moves where · 5 Protocol and auth ·
6 Lifecycle · 7 Updates and version skew · 8 Remote · 9 Alternatives · 10 Order of work ·
11 Risks · 12 Testing · 13 Open questions · 14 Credits and licence

---

## 1. Goal and non-goals

**Goal**
- pi, Claude Code and shells keep running when the window closes, crashes or the app updates.
  Reopening reattaches to them with the screens as they are.
- Updating Deckhand, its core or its PTY holder does not stop sessions.
- A window shows sessions from cores on several machines (#5), over SSH, with no new ports or
  logins.
- One version number. The artifacts are the Mac app zip (core inside) plus a signed core tarball
  per remote target (§7.1).

**Non-goals (v1)**
- Surviving logout or reboot. Today's restore runs after those
  ([PERSISTENCE.md](../PERSISTENCE.md) "Restore").
- Several windows per core (M7).
- Browser pages or app tabs that outlive the window (decision 3).
- Agents browsing with no window open.
- Job runs that survive a core restart.
- Linux or Windows windows. A headless Linux core is in scope for #5.

---

## 2. Decisions

**By the user (2026-11-07):**

| # | Question | Decision |
|---|---|---|
| 1 | Closing the last window | The core keeps running while any session process or job run is alive, and exits after a quiet period (default 10 min) once nothing runs and no window is attached. |
| 2 | ⌘Q | Closes the window only, and sessions keep running. **Quit Deckhand and Stop All Sessions…** stops everything (class `app_quit`). |
| 3 | App tabs | May die with the window in v1. |
| 4 | Remote core updates | One-click offer when connecting to an older remote core (§8.5). |
| 5 | Apple Developer ID | **Deckhand will get one, though not now.** The design assumes it. Ad-hoc builds get no special safeguards; §5.4 states what they trust. |

**In this design (open to review):**

| Topic | Decision | Where |
|---|---|---|
| Processes | Window, core and PTY holder (herdr), not exec-in-place of the core | §3, §9 |
| Holder upgrades | The holder **re-execs itself** (its pid survives, so it stays the children's parent). Drain is only the fallback. | §7.3, §9 |
| Terminal output | Option (a): bytes plus the window's own ghostty-vt, resynced by a **GHOSTSNP** snapshot (S1). The VT formatter is only an `inexact` fallback. | §5.5 |
| Identity | A designated requirement (identifier + Team ID, Developer ID, hardened runtime), checked by audit token, **in both directions** | §5.3 |
| Sequencing | **M1 may ship ad-hoc** with a same-user residual. **The M4 window/core split (`ui` over a socket) waits for the Developer ID.** | §5.4, §10 |
| First step | M1: the holder in front of today's single-process app | §10 |
| Windows | One per core in v1; view state stays in the core | §4 |
| Lifecycle | herdr's launchd detach (unique label, fork, setsid, bootout) | §6 |
| Job runs | Stay children of the app (M1) or core (M4), not the holder | §4 |
| Editor buffers | Stay in the window. Closing a window with unsaved buffers asks first. | §4 |

---

## 3. Process model

```
 local Mac                                                     remote host (#5)
┌──────────────────────────┐
│ Window (Deckhand.app)    │  UI, CEF, app-tab frames, selection, IME,
│ ghostty-vt per shown tab │  key encoding, State replica, editor buffers
└───────────┬──────────────┘
            │ core.sock (framed), mutual designated-requirement check
┌───────────▼──────────────┐  ssh host deckhand-core connect   ┌──────────────────┐
│ Core (Deckhand Core.app) │◄──────── stdio, framed ──────────►│ remote Core      │
│ State, commands, socket, │                                   │ + its holder     │
│ jobs, ghostty-vt per     │◄── agents: pi bridges, Claude CLI, └──────────────────┘
│ terminal, persistence    │    Atlas, --ctl (NDJSON v1)
└───────────┬──────────────┘
            │ holder.sock: holder wire (grow-only; frozen bootstrap subset)
┌───────────▼──────────────┐
│ Holder (deckhand-core    │  PTY masters, every session process as its child,
│ hold; re-execs to update)│  waitpid, foreground pgid, byte offsets, 1 MiB tails,
└───┬──────────┬───────────┘  the in-memory HMAC key
   pi tab   Claude tab, shells
```

| Role | Owns | Dies → |
|---|---|---|
| **Window** | drawing, input, CEF, app-tab processes, ghostty-vt of shown terminals, editor buffers | Pages and app tabs go; reopening reattaches. |
| **Core** | State, `run_command`, socket and tokens, events, jobs, persistence, ghostty-vt per terminal (OSC 7501/133, mode 2004, DA/DSR, exit banners), remote links | The holder relaunches it through launchd (§6). Screens come from the tails, marked `inexact`. |
| **Holder** | PTYs, children, reaping, offsets, tails, the HMAC key. No parsing or policy. | Its terminals get SIGHUP and are marked `holder_lost`; today's restore follows. |

In M1 the "core" is today's single-process app. There is one holder per core. A second one
exists only while an upgrade fallback drains (§7.3).

---

## 4. What moves where

From the map's §2. C = core, W = window, H = holder.

| Subsystem (today's files) | v1 home | Change needed |
|---|---|---|
| PTYs, fork, reap (`pty.odin`, `pty_posix.odin`) | **H** | Calls become holder messages. `pty_foreground_busy` becomes `FOREGROUND`. Resize carries pixels (pty_posix.odin:147). |
| Job runs (`jobs_run.odin`) | **C** (the app in M1), **not H** | The reader thread's loop detector, cost and turn limits, `needs_you`, stall and timeout kills and `events.jsonl` cap, plus the inherited run-lock fd (jobs_run.odin:1-26, :149). Revisit after M4. |
| ghostty `Terminal` (`term.odin`) | **C** (+ a W copy for shown tabs) | Sizes come from the window. |
| Drawing, selection, links, IME, key/mouse encoding | **W** | On the window's copy. That copy's `Write_Pty` is dropped. |
| State (`state.odin`) | **C**, with a W replica | View state stays in C (one window). Pixel fields are W-only. |
| `run_command`, inbox, command table | **C** | `app.redraw` (commands.odin:686 and 5 others) becomes a "state changed" hook. Toasts become an event. |
| Pane room and ratio checks (panes_commands.odin 141-194) | C, given W's size | The window sends its centre size. |
| Socket, tokens, events | **C** | A stable `core.sock` from M1. Framed mode for windows. `pd_frames_*` (socket.odin:856-861) asks the window. |
| pi/Claude logic, waits, held prompts, hot reload | **C** | A core loop, not `frame()`. |
| Jobs scheduler, Atlas, bell | **C** | OS banners from `Deckhand Core.app` when no window is active. |
| Persistence | **C** | `tokens.json` and `handover.json`, both HMAC'd (§5.3). |
| Login env | **C** | Computed per spawn and sent in `SPAWN`. |
| Instance lock (`instance.odin`) | **C + H** | `instance.lock` is held `LOCK_SH` by holders and the core. `core.lock` (`LOCK_EX`) keeps one core (§7.6). |
| Browser tabs (CEF) | **W**, record in C | `browser_*` is routed to the window as tab host. No window: `{"ok":false,"code":"no_window",…}`. |
| App tabs | **W** (process too) | Exited (`window_closed`) after the window closes. |
| Editor buffers | **W** | Record in C. Closing with unsaved buffers asks first. |
| Platform table | split | Core: wake, run_later, activity, notify. Window, via `window.request`: clipboard, open_url, reveal, pick_folder, toast, appearance, `window_active`. |
| UI, fonts, menus, autotest UI | **W** | — |

---

## 5. Protocol and auth

### 5.1 Transport and framing

| Link | Transport | Framing |
|---|---|---|
| Agents, CLI ↔ core | `core.sock` | NDJSON v1, unchanged |
| Window ↔ core | `core.sock` | NDJSON hello with `framed:true`, then frames |
| Local core ↔ remote core | `ssh … deckhand-core connect` stdio | frames |
| Core ↔ holder | `holder-<rand8>.sock` | holder wire (§5.7) |
| Window ↔ holder (crash loop only) | `holder-<rand8>.sock` | `SUPERVISE` (§7.7, P6) |

- **Runtime dir:** `~/Library/Application Support/pi-desk/run/` (0700), replacing `$TMPDIR/pi-desk-<uid>`.
  macOS cleans `/var/folders` under long-lived processes. The dir is refused if a socket path
  would pass 104 bytes.
- **Stable `core.sock`** from M1, replacing `pi-desk-<pid>.sock` (socket.odin:108), so adopted
  tabs keep `DECKHAND_SOCKET`/`PI_DESK_SOCKET`. PROTOCOL.md §1 changes.
- **Framed mode** (herdr's layout): `[channel u32 LE][kind u8][len u32 LE][payload ≤ 16 MiB]`.
  Channel 0 is JSON; channels ≥ 1 are terminal streams. Kinds: `DATA`, `SNAPSHOT`, `RESIZE`,
  `CREDIT`, `CLOSE`, `FOCUS`. Unknown kinds are ignored.

### 5.2 Handshake

The hello reply gains `generation` (today's `v`), `version`, `features`, `methods`, `machine`,
`holder_wire` and `snapshot` (the formats this side can decode, best first:
`["ghostsnp/1", "vt"]`). Today no socket token maps to `ui` (socket.odin:850; `.UI` is in-process only).
M4 adds the first one, which makes §5.3 the critical boundary.

### 5.3 Auth (Developer ID model)

**Identity = a designated requirement (DR)**, checked against the peer's **audit token**.

**The token is live (S2, Q1).** `LOCAL_PEERTOKEN` and `LOCAL_PEERPID` report the process that
*last did I/O* on the peer socket, re-resolved on every call, not the process that connected:
- after an exec, they report the new image (same pid, new pidversion);
- after an fd handed to a forked child, they report that child;
- after the peer exits, they fail with `EINVAL`.

So the rule is:
- **Read the token at accept, before reading any byte**, and run the DR check (steps 1–4) on it.
- **On every read**, call `getsockopt` again. Drop the connection if `pid` or `pidversion`
  differs, or on `EINVAL`.
- Deckhand's own binaries open their own connections with `SOCK_CLOEXEC` and never share the fd.
- **Residual:** bytes written by another process X that land in the same `read()` as a later
  write by the genuine G are attributed to G. This needs X to share G's fd, which hardened
  runtime (no task-port injection) and CLOEXEC rule out.
- **Today's Claude token check has the same weakness** (`socket_claude_peer_ok`,
  socket.odin:247-258). It reads `LOCAL_PEERPID` once, at hello, and gets the last writer. The
  check is same-user anyway, so this is a residual; PROTOCOL.md gets a line.

The DR check:
1. Get the peer's code with `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)` on the
   saved token. A token whose process exec'd since gives `errSecCSNoSuchCode` (-67065).
2. Check it with `SecCodeCheckValidity(kSecCSStrictValidate)` against the requirement:

```
anchor apple generic and certificate leaf[subject.OU] = "<TEAM_ID>"
  and identifier "dev.deckhand.app"      (window)  /  "dev.deckhand.core"  (core, holder)
```

3. Read the code flags, and require `CS_RUNTIME` (hardened runtime) and no `get-task-allow`.
   **From D0 only**: S2 showed an ad-hoc binary under hardened runtime and library validation
   refuses ad-hoc libraries ("different Team IDs"), so ad-hoc builds can't turn the runtime on with
   CEF.
4. Read the **version from the signed `Info.plist`** (`kSecCodeInfoPList`), which serves as the
   `seq` for floors (P5).

XPC's `xpc_connection_set_peer_code_signing_requirement` does the same check. Use it if a link
moves to XPC; the Unix socket stays for agents and remote.

**Library validation stays on** in the window, the M1 app and `Deckhand Core.app`. CEF and its
helpers are signed under the same Team ID. Entitlements stay as in `app.plist` today:
`allow-jit` and `allow-unsigned-executable-memory`. **Never** `disable-library-validation`,
`get-task-allow` or `allow-dyld-environment-variables`. A copy of the app with any modified
binary or library can't carry the team's signature, so it fails the DR or won't load (this closes
review round 2's B1).

| Link | Check | Anti-accident only |
|---|---|---|
| Window → core | The window's DR. Its version ≥ the core's **window floor**: the highest window version seen attached, lowered only by a `ui` request from an attached window (P5). | The window token in `run/window.token` (0600, never in any environment). The peer must not descend from a holder. |
| **Core → window (B4)** | The window checks the core's DR on `core.sock` before sending anything. A genuine window pointed at a fake core refuses it. | — |
| Core → holder | The core's DR. The holder **refuses `HELLO` while a core is attached**, and a ping timeout frees a hung one. After a crash, any core with the DR and `version ≥ floor` may connect; the floor is the highest version that stayed attached and healthy for 60 s. After a planned handover, only the successor holding the **successor secret** may connect (§7.2). | — |
| **Holder → core (P9)** | The core checks the holder's DR before any `SPAWN`, because `SPAWN` carries the environment and its tokens. It checks again after every re-exec. | — |
| `ready` socket (§6, P8) | The launcher checks the peer is its launched child (pid) **and** has the DR before sending the environment or a secret. | — |
| Agents → core | Unchanged (PROTOCOL.md §2). Claude tokens still require the peer to *descend from* its tab (socket.odin:247-258), the opposite polarity of the holder rule; both hold. **At M4, bridges switch to a challenge-response hello** (an HMAC over a nonce), so a fake core can't harvest their reconnect tokens. | — |
| Remote | §8.3 | — |

**A genuine binary under attacker config (B2).** A signed binary passes the DR whatever its
environment or arguments, so release builds must not be steerable that way:

| Knob | Release builds |
|---|---|
| `PI_DESK_SCRIPT`, scene hooks, `PI_DESK_QUIET`, update fixtures (main.odin:1154-1156) | compiled out (`-define:DECKHAND_TEST_HOOKS`) |
| `PI_DESK_RUNTIME_DIR`, `PI_DESK_DATA_DIR` overrides (main.odin:89-126, socket.odin) | compiled out; fixed paths |
| `--print-token script` and `--print-token control` (main.odin:1100) | compiled out. A control token is minted only by the user, from Settings › Copy a control token (`ui`). |

`scripts/release.sh` builds without hooks and fails if hook strings remain in the binary. Test
and dev builds keep the hooks; they never carry the release DR's identifier.

**State files are authenticated (B3).**
- The holder generates a 256-bit **HMAC key** at start and keeps it in memory only. It survives
  re-exec through the state fd and is sent in `WELCOME`, only to a DR-checked core.
- The core MACs `tokens.json` and `handover.json` (HMAC-SHA256 over the whole file).
- **A bad or missing MAC fails closed:** handover state is discarded (a crash-style restore), and
  every token in the file is treated as unknown. Bridges and Claude tabs then show "Reconnect
  needed: restart this tab", which is offered, not automatic. A read-only Claude tab with no
  trusted ack state is stopped (docs/CLAUDE.md §1a).
- If the holder is gone, its key is gone too. Its sessions are gone as well, so nothing is lost
  by the files becoming unverifiable.

`tokens.json` (0600) is rewritten atomically on every mint and revoke. It holds hashes only, never
tokens:
- pi env tokens, with a used flag;
- pi reconnect tokens;
- Claude tokens, with the tab's root pid (`claude_pids`);
- the read-only ack state and nonce.

**Residual risk (with a Developer ID):**
- Same-user code with Accessibility or other TCC grants (synthesised input).
- Root, or SIP turned off.
- A user tricked into running a modified app and approving it.
- Killing everything: SIGKILL of the holder, which is visible.
- **Data-dir tampering outside the MAC'd files:** `workspace.json`, Claude's and pi's own settings,
  `apps.json`, job notes. Today a same-user process can already set `claude_skip_permissions`
  in `workspace.json` (written at persist.odin:529, restored at :669), or edit
  `~/.claude/settings.json`.
- The re-exec TOCTOU (§11, R3).

Permissions as in herdr and today: dirs 0700 and refused if not owned or not real; sockets,
token and handover files 0600.

### 5.4 Until the Developer ID

Ad-hoc builds have no team identity, so **every check above degrades to "same user"**. S2
showed the token yields a CDHash even for ad-hoc code, so the core and holder *could* pin each
other's CDHash. Per decision 5 that isn't planned: a pin doesn't stop a same-user process running
the genuine binary, and the Developer ID replaces it. The DR
checks are skipped, with a single banner in Settings: "This copy isn't signed with Deckhand's
Developer ID: other programs running as you can control its sessions". The holder still keeps
its HMAC key and its successor secret. Those raise the bar against accidents, not against a
determined same-user process.

This is close to today's position. A same-user process can already flip
`claude_skip_permissions` (persist.odin:529/669), edit Claude's settings, or relaunch a modified
copy that restores the workspace. What ad-hoc M1 adds is that such a process can connect to the
holder and type into any terminal.

**Rule:**
- **M1 (holder, no socket `ui`) may ship ad-hoc** with that residual, stated in GUIDE.md.
- **M4 (window/core split, `ui` over a socket) ships only with the Developer ID** in place:
  `release.sh`'s Developer ID and notarization path, CEF signed under the team, and library
  validation on.

### 5.5 Terminal streams (option a)

```
window: term.attach {tab_id, history_lines}       → {channel, offset}
core:   [ch][SNAPSHOT] meta JSON + GHOSTSNP bytes at that offset (screen first, then history)
core:   [ch][DATA] bytes from offset, coalesced ≤ 8 ms or 64 KiB
core:   [ch][RESIZE] {offset, cols, rows, xpixel, ypixel}   (applied at that byte offset)
window: [ch][DATA] encoded input · [ch][CREDIT] n · [ch][FOCUS] · term.detach
```

- The core is the only resize authority, and the only one that answers terminal queries.
- **Snapshot = meta JSON + GHOSTSNP** (libghostty-vt v1.4.0 `snapshot.h`). S1 measured it
  **exact in 360/360 runs**, including snapshots taken mid-escape and mid-UTF-8. It carries
  everything:
  - both screens and their scrollback, cursor, pen and saved cursor;
  - modes, margins, tab stops, charsets, palette, title and pwd;
  - kitty keyboard flags, hyperlinks, DECSCA protection, OSC 133 marks;
  - the unfinished parser input.

  Meta holds what Deckhand keeps beside the terminal: the `format` used, `offset`, cols/rows/
  pixels, OSC 7501 status and exit state.
- **Fallback: the VT formatter** (`ghostty_formatter_terminal_new`), marked **`inexact`**, used
  only when the two sides share no `ghostsnp/N`. S1 found it loses:
  - the primary screen while the alt screen is up (everything behind vim, htop or Claude Code);
  - the DECSC saved cursor;
  - per-cell DECSCA;
  - OSC 133 marks.
- **Versions:** GHOSTSNP v1 makes no compatibility promise, and a decoder rejects other
  versions. Both sides list `snapshot` formats in hello (§5.2). **Every libghostty bump** runs an
  old-encode/new-decode round trip before shipping; this goes on DEVELOPING.md's checklist for
  rebuilding libghostty-vt.
- **Size:** 10k lines of styled scrollback at 200×60 is 9.6 MB, 1.7 MB with zstd, against the
  50 KB screen alone. Encoding takes 2.5–4.9 ms and decoding 6–11 ms, so speed is no issue.
  Snapshots are therefore:
  - **compressed**: the codec's `OPT_COMPRESS_HISTORY` locally; zstd on streams and over remote
    links;
  - **exempt from credit**, sent on their own queue, which a newer snapshot replaces;
  - **streamed screen-first**: the window renders at the codec's `READY` marker (about 50 KB),
    and history pages follow newest→oldest.

  The codec has no "N history lines" option, so `history_lines` is enforced by the decoder
  stopping early.
- **Every terminal sets `OPT_CONTINUATION_MAX_BYTES` at creation**, in the core and in the
  window. Encoding fails with `Invalid_Value` if the parser is mid-sequence without it, and also
  while an unfinished sequence is over the limit (a 2 MiB OSC 52 against a 1 MiB limit). **Such a
  terminal can't be snapshotted until the sequence ends.** Retry after the next ground state, and
  set the limit to the largest sequence Deckhand accepts.
- **Decoded terminals keep no callbacks** (write_pty, title, bell, OSC 7501/133, colour scheme)
  and no continuation tracking unless `DECODER_OPT_RETAIN_CONTINUATION` is set. The window and a
  new core re-register them through one helper shared with `term_start`, and re-apply the theme if
  theirs differs.
- Hidden tabs aren't streamed; detach 2 s after a tab is hidden.

### 5.6 Flow control

| Where | Rule |
|---|---|
| Core → window | Credit for `DATA`, starting at 256 KiB. More than 4 MiB behind: a fresh `SNAPSHOT`. Snapshots are exempt from credit and sent compressed, screen first (§5.5). Channel 0 never blocks. |
| State | Deltas at ≤ 60/s. Overflow sends a full state. |
| Holder → core, core attached | Queue 8 MiB, then stop reading the PTY (as herdr does). |
| Holder, no core for more than 3 s | Read into the 1 MiB tail only, so programs never stall. Offsets keep counting. |

### 5.7 Holder wire

Layout (herdr's): `[kind u8][terminal u32 LE][len u32 LE][payload ≤ 16 MiB]`. Control payloads are
JSON; terminal bytes are raw.

- **Frozen forever:** the header, `HELLO`, `WELCOME`, `REFUSED`, `UPGRADE` and `UPGRADE_FAILED`,
  with their required fields.
- **The rest is grow-only**, versioned by `wire`. Unknown fields are ignored; an unknown kind gets
  `UNKNOWN{kind}`.

| core → holder | holder → core |
|---|---|
| `HELLO{wire, successor_secret?}` | `WELCOME{wire, instance, pid, holder_rev, previous: none\|handover\|crash\|upgrade, hmac_key, terminals[{id, pid, pgid, cols, rows, xpixel, ypixel, offset, exit}]}` |
| `SPAWN{argv, env, cwd, cols, rows, xpixel, ypixel}` | `TAIL{start u64}` + bytes |
| `INPUT` | `OUTPUT`: `start u64` + bytes |
| `RESIZE{cols, rows, xpixel, ypixel}` | `SPAWNED{pid, pgid}` · `SPAWN_FAILED{error}` |
| `SIGNAL{signal, target: pid\|pgroup}` · `RELEASE` | `EXITED{code, signal, offset}` (after output up to `offset`) |
| `GOODBYE{mode: handover\|shutdown}` | `GOODBYE_ACK{terminals[{id, offset}], successor_secret}` |
| `FOREGROUND` | `FOREGROUND_IS{pgid}` |
| `UPGRADE{path}` | `UPGRADE_FAILED{error}` |
| `PING` (every 5 s) | `PONG`. A core that misses pongs for 30 s is dropped. |
| — | `REFUSED{code: wire\|identity\|floor\|attached\|secret, error}`, then close |

The holder disclaims TCC responsibility at start (herdr's `macos_responsibility.rs`).

### 5.8 State replication

- `state.subscribe` returns `state.full{version, state}`, then `state.delta{version, sections}`.
  The sections are `projects`, `sessions`, `tabs:<s>`, `panes:<s>`, `settings`, `jobs`,
  `confirmations`, `notifications`, `update`, `panels:<tab>` and `machines`.
- The window decodes into a replica with `State`'s shape (a new decoder, M3).
- Core → window messages: `toast`, `confirmation.parked`, `window.request{op}`/`window.reply`, and
  `tab_host.call` (answered by `finished`).

---

## 6. Lifecycle

**Starting a process outside the app** follows herdr's launchd model (macos_launchd.rs:176-262):
1. The launcher makes a 0700 temp dir with `job.plist` (0600) and a `ready` socket. The label is
   unique per launch: `dev.deckhand.<core|hold>.<pid>.<ns>`.
2. It runs `launchctl bootstrap gui/<uid>` and removes the plist. The plist sets
   `RunAtLoad=true`, `KeepAlive=false`, `AbandonProcessGroup=true` and
   **`ProcessType=Interactive`**.
3. The job runs `deckhand-core __detach <ready>`. It forks; the parent exits; the child calls
   `setsid`, execs, and waits until its ppid is 1.
4. The child connects to `ready`. The launcher **checks the peer (pid + DR, P8)**, boots the job
   out, then sends the inherited environment and, for a handover, the successor secret. The child
   acks and serves.

A failed bootstrap falls back to a direct spawn, with a logged warning.

S2 facts (macOS 26.6.2):

| Fact | Consequence |
|---|---|
| Bootstrap takes 7–25 ms and the handshake 33–70 ms; the environment arrives intact (74 vars) | Fine for on-demand start |
| `ProcessType` sticks through fork, exec and bootout: Background = pri 4, Standard = 20, Interactive = 31 | Set `Interactive` explicitly |
| **Bootout kills the job's own process.** Only a forked, setsid child survives. | The fork in step 3 is required |
| A launcher killed between bootstrap and bootout **leaks the job** (loaded, not running), and the waiting child dies of SIGPIPE | A stale-job sweep at every launch (herdr's `remove_stale`). Launcher and child ignore SIGPIPE and log a failed handshake. |
| A fixed label fails while loaded (`Bootstrap failed: 5: Input/output error`) | Unique labels |
| `launchctl submit` makes a **KeepAlive** job that respawns | Never use it |
| A quarantined binary is **SIGKILLed at exec**, from launchd too (`OS_REASON_EXEC`) | Strip quarantine after verifying (§7.1) |
| `responsibility_spawnattrs_setdisclaim` works | The holder and core are TCC-responsible for themselves |

| Event | What happens |
|---|---|
| A core is needed (window, `deckhand DIR`, `--ctl`) | Connect to `core.sock`; else launch as above and wait up to 15 s. |
| Core starts | Take `core.lock` (EX) and `instance.lock` (SH). Adopt the holder (`HELLO`, `WELCOME`/`TAIL`). Restore from `handover.json` if fresh and its MAC verifies, else from `workspace.json` + `tokens.json`. Serve. |
| ⌘Q, window closes | The window exits and sessions run on. A notice the first time. |
| Idle | No window, no live tab process and no job run for 10 min: save, exit. A holder with no terminals exits. |
| Quit Deckhand and Stop All Sessions… | `quit` (class `app_quit`): persist, `GOODBYE{shutdown}`, exit. |
| Core crashes (M4+) | The holder relaunches it **through the launchd launcher** (backoff as holder.rs:423-447), so the core never descends from the holder. |
| App crashes (M1) | Nothing restarts it. Sessions run on, and the next launch adopts them. |
| Logout or reboot | Everything stops; today's restore follows. |

Rejected:
- **The window spawning the core** (fork + setsid). Herdr's reason, "macOS kills the app's
  coalition on quit" (0.1.17), **did not reproduce on 26.6.2**: a plain fork + setsid child
  survived an AppleScript quit, SIGTERM and SIGKILL of the app. Force Quit (⌥⌘⎋), logout and
  macOS 14/15 are still untested. The launchd path is kept because a direct child:
  - **stays in the app's coalition** (jetsam and energy accounting, and any RunningBoard
    coalition termination);
  - **is TCC-attributed to Deckhand.app** while the app lives;
  - only S2's launchd child had its own coalition and its own responsibility from the start.

  The disclaim fixes TCC attribution on its own; the coalition is the remaining reason.
- **An SMAppService login agent:** it needs a Login Items prompt; deferred to M5.

---

## 7. Updates and version skew

### 7.1 Artifacts

```
Deckhand.app/                                  Developer ID, notarized (from M4; M1 may be ad hoc)
  Contents/MacOS/Deckhand                      window, dev.deckhand.app
  Contents/Frameworks/…CEF…                    same Team ID, library validation on
  Contents/Helpers/Deckhand Core.app/          dev.deckhand.core: deckhand-core (serve | hold |
      Contents/MacOS/{deckhand-core,deckhand}  connect | check | install | __detach), the CLI,
      Contents/Resources/integrations/…        pi and Claude integrations
```

- **App updates stay as today:** the Ed25519 `.sig` (v2 manifest) plus codesign and CDHash
  checks. Release step: **test the new zip with the current release's updater**
  (`tests/scripts/update.sh` driven by the previous release's binary) before publishing.
- **Remote targets:** `deckhand-core-<v>-<os>-<arch>.tar.gz` plus `.sig`, in today's manifest
  format (`cdhash none` on Linux). That is Ed25519, never checksum-only.
- **Install:**
  - Copy the nested Core.app from the verified bundle to
    `~/Library/Application Support/pi-desk/core/<v>/`, strip `com.apple.quarantine` **after verifying** (S2: a
    quarantined binary is SIGKILLed at exec, launchd included), and check the DR. Data files go in
    `Contents/Resources` only: S2 showed a data file in `Helpers`, `MacOS` or `Frameworks` fails
    signing and `--verify --deep --strict`; a signed Mach-O in `Helpers` is fine.
  - `current` and `previous` are symlinks switched by rename.
  - A version is collected when it is neither of those, nothing runs from it, and no tab was
    started from it. The integrations live there, so live tabs keep their paths across an app
    swap.
- **TCC:** with the Developer ID, grants follow the DR and survive updates. Ad-hoc builds
  re-prompt at every core version, and Full Disk Access silently stops applying (§5.4).

### 7.2 Core handover (byte-exact)

1. Old core → holder: `GOODBYE{handover}`.
2. Holder: stops `OUTPUT` and replies `GOODBYE_ACK{terminals[{id, offset}], successor_secret}`.
   The secret is a fresh 256-bit random value, valid for 60 s and for one `HELLO`. The holder
   keeps reading into the tail from there.
3. Old core:
   1. feeds bytes up to each acked offset into its emulator;
   2. snapshots each terminal **at exactly that offset**, in GHOSTSNP if the successor lists the
      same `ghostsnp/N` (from `deckhand-core check`), else in VT (`inexact`):
      - a terminal whose unfinished sequence is over the continuation limit can't be encoded
        (§5.5). It is written as VT, marked `inexact`, and the holder's tail carries on from the
        offset;
      - snapshots go to `handover/<id>.snap` (0600, codec history compression), named in
        `handover.json`;
   3. writes `handover.json` (0600, HMAC'd) with `min_reader`, runtime ids, the tab ↔ terminal
      map, pending confirmations, held Claude texts and waits, and the snapshot offsets;
   4. flushes `workspace.json` and points `current` at the successor;
   5. launches the successor, passing the secret over the peer-checked `ready` socket (§6);
   6. releases its locks.
4. New core: `HELLO{successor_secret}` (and the DR). It decodes each snapshot, then
   re-registers the callbacks and the theme (§5.5). Then `WELCOME` and `TAIL{start}` per terminal:
   - `start == snapshot offset`: exact;
   - `start < snapshot offset`: skip the overlap;
   - `start > snapshot offset`: **`inexact`**.
5. **Query replies in the replayed tail are dropped, all of them (P4).** A program that asked
   during the gap times out, which TUIs handle; a stale `^[[?1;2c` never lands in vim.
6. Requests in flight (a pending browser action, `claude_wait_idle`) are lost. Their callers see
   a reconnect. This is documented in PROTOCOL.md.
7. **How tests check exactness: a screen hash, not snapshot bytes.** That is a hash of the
   cell-by-cell dump of both screens, cursor and modes, which S1's comparator already produces.
   Re-encoding a decoded terminal gives different bytes with an identical dump (S1: 40/180
   alt-screen runs, from internal style and page order).

### 7.3 Holder upgrade (re-exec)

Only when `WELCOME.holder_rev` is older than the new core's. `holder_rev` is bumped by hand, and
CI fails if holder source changed without a bump.

S2 confirmed the mechanism on 26.6.2:
- after `execve`, the pid is unchanged, the masters are open and the children are still children
  (`waitpid` works);
- there is no SIGHUP and no output gap;
- the new image is up about 2 ms after the call.

It also showed that `execve("/dev/fd/N")` **fails on macOS** (`EACCES`: the fdesc node has no x
bit), and that a path swapped between the check and `execve` runs. A check on the *file* can
therefore never be trusted, so the terminals now pass through a **keeper-gated handover**,
checked against what actually ran.

1. The core sends `UPGRADE{path}`. The holder checks the file's DR (static code). This only
   catches mistakes early; the real check is the keeper's, in step 4.
2. **Preflight (P3):**
   - The holder serialises its state to a 0600 unlinked file:
     - terminals: id, pid, pgid, master fd, sizes, offsets, unreported exits;
     - tails and backlog;
     - **pending input queues** (P2);
     - the listener, the `instance.lock` fd and the HMAC key.
   - It runs `path hold --dry-run-resume <fd>` as a **child**, with **dup'd** masters. The child
     resumes everything except reading and writing: it parses the state, fstats the fds, and
     builds its tables. Then it prints `holder_rev` and `wire` and exits 0.
3. **Keeper and re-exec:**
   - The writer threads pause **between whole `INPUT` frames** (P2), and the pumps pause; output
     waits in the kernel PTY buffer.
   - The holder forks a **keeper**. The keeper holds the masters, the state fd, the listener and
     the HMAC key. It is the only process that has them.
   - The holder closes its own copies of all of these. It then calls
     `execve(path, hold --resume <keeper-socket>)` while holding **none of them**. Only the pid,
     and with it the children's parenthood, carries over.
   - If `execve` fails, the keeper hands everything back to the old image (same pid, same
     pidversion), which resumes and sends `UPGRADE_FAILED`.
4. **The keeper gates the handover:**
   1. The new image connects to the keeper.
   2. The keeper reads the peer's **live audit token** and requires the holder's pid with a **new
      pidversion**.
   3. It checks the DR on that token. The token reflects what the kernel actually ran: a swapped
      file fails here.
   4. Only then does it send the masters, state fd, listener and key over `SCM_RIGHTS`. S2 showed
      this costs one socket round trip in the gap.
   5. A swapped image gets the pid, and so parenthood, but **never the terminals or the key**.
      The keeper adopts them itself (step 6), and the core reports "the session holder failed
      verification".
   6. Under ad hoc (§5.4) the keeper's check is identifier-only, so it guards against accidents,
      not attackers.
5. **The new image** (after it receives the fds):
   1. **resets every signal disposition and the signal mask (P1)**. S2: an inherited `SIG_IGN`
      and blocked mask **leak into every child spawned later** (a shell whose SIGPIPE is ignored
      at entry can't trap it), and exec clears `SA_NOCLDWAIT`;
   2. sets CLOEXEC again;
   3. reaps exits from the gap (`waitpid(-1, WNOHANG)`);
   4. replays the pending input;
   5. resumes the pumps;
   6. binds a fresh socket;
   7. tells the keeper to exit.

   The core reconnects, re-checks the holder's DR (P9), and sees `previous: upgrade`.
6. **Keeper fallback, if the new image dies, fails the check, or doesn't connect within 10 s:** the masters are still
   open in the keeper, so there is no SIGHUP (S2: sessions got ppid 1 with no gap). The keeper
   re-execs the *old* holder binary in **adopt-orphans mode**:
   - It serves the same terminals.
   - The children are now launchd's, so it watches them with `kqueue EVFILT_PROC
     NOTE_EXIT|NOTE_EXITSTATUS`. **That returns the wait status for non-children** (S2 saw
     SIGTERM; M1 checks `exit(n)` too).
   - The core marks those tabs **`degraded`**: they're not the holder's children (no `waitpid`,
     no parent-based job control), but they keep output, input and exit codes, and work until
     closed.
7. **Fallback drain:** after a failed preflight, the old holder keeps its terminals, the core
   speaks its older wire, and new terminals go to a new holder.

### 7.4 App update, step by step

1. **Download and verify** as today.
2. **Confirm:** "Browser pages will reload and app tabs will restart". Sessions are no longer
   mentioned.
3. **Swap the bundle** as today.
   - **M1:** the old app performs §7.2 and quits, then `open` relaunches it. The new app, as the
     successor, gets the secret through a `ready`-style socket the relaunch helper holds. (Its DR
     is checked from M4; ad-hoc M1 checks only that it is the same user, §5.4.)
   - **M4+:** the window relaunches, runs the bundled `deckhand-core install`, and sends
     `core.handover{to}`. The core performs §7.2, then §7.3 if `holder_rev` changed.
4. **Reconnect:** windows and agents reconnect, checked against `tokens.json` (whose MAC must
   verify).
5. **Health:** a core is healthy after 60 s attached without a crash. Only then does the holder's
   floor rise to its version.

### 7.5 Version skew

| Seen at hello | Result |
|---|---|
| Same generation, core ≥ `CORE_MIN` | Works. Optional behaviour is gated on `features`. A local core older than the app is handed over at once. |
| Same generation, core < `CORE_MIN` | Locally: automatic handover to the bundled core. If that fails: **"Deckhand's background core is out of date"** (Retry, Details). |
| Core generation > app generation | **"Update Deckhand: its background core is newer than this app"**, with Update or Use this app's core (a named handover, §7.7). |
| Core generation < app generation | Locally: hand over to the bundled core. |
| Window version < the core's window floor | **"This Deckhand is older than the one last used with these sessions"**, with Open the newer version or Use this version (asked in the newer window) (P5). |
| Holder wire older than the core's | Speak the older wire (grow-only), then `UPGRADE`. |

**Grow-only API:** `schema/released-v1.json` is generated from `command_table.odin` and the
encoders: commands and args (required or optional), result, event and state fields, frame kinds,
features. A unit test (< 1 s) fails on any non-additive change. `scripts/release.sh` refreshes it
at the tag. The holder wire has its own `released-holder.json`, plus golden vectors for the frozen
subset.

### 7.6 Locks and downgrades

- Holders and the core hold `instance.lock` **SH**. A **pre-M1 app** wants it EX, so it refuses to
  start ("Deckhand is already running"), and never resumes conversations still running in holders.
- `core.lock` (EX) is the one-core rule.
- `handover.json` carries `min_reader`. An older reader fails closed and does a crash-style
  restore.
- **An older M1+ app** falls below the floor. The holder refuses it unless the running newer core
  names it in a handover (Use this app's core).

### 7.7 Failure modes and rollback

**Rollback is decided by the supervisor (the holder) or the window, never by the core that is
crashing.**

| Failure | What happens | Sessions |
|---|---|---|
| A new core fails `check` | No handover; "Couldn't finish updating the background core". | Kept |
| A new core crashes twice within 5 min | The holder's supervisor relaunches the **last healthy** core (`previous`) and does not raise the floor. The window says "Update rolled back". | Kept, `inexact` |
| A crash loop, seen by the window (P6) | The window connects to the holder directly with `SUPERVISE{status}` / `SUPERVISE{use: previous}` (window DR checked) and shows **Use previous core**. It doesn't wait for a core that never comes up. | Kept |
| Use previous core, normal case (Settings › About) | A named handover to `previous` through the running core | Kept |
| `current` swapped by same-user code | Every launch checks the DR: refused, "the background core failed verification" (a denial of service). The supervisor uses the last healthy core. | Kept |
| Old core crashes before `GOODBYE` | A crash restart: tails, `inexact`, no query replies | Kept |
| `handover.json` missing, stale (> 3 min, another boot), bad MAC or `min_reader` too high | Fail closed: restore from `workspace.json` + `tokens.json` (whose MAC must also verify, §5.3). Parked confirmations and held texts are dropped. | Kept |
| Holder upgrade preflight or `execve` fails | Fallback drain | Kept |
| The new holder image crashes, fails the keeper's check, or doesn't connect within 10 s | The keeper adopts the orphans (§7.3 step 6) | Kept, `degraded` (exit codes kept) |
| The new holder image crashes after the keeper has exited, or a holder crashes | `holder_lost`: pi and Claude resume from disk, shells restart fresh | Lost |
| Disk full while writing the handover | Abort before `GOODBYE` | Kept |

---

## 8. Remote (#5)

### 8.1 Connection

- Only the local core dials: `ssh -S <run>/ssh-<host>.ctl -o ControlMaster=auto
  -o ControlPersist=600 host …/core/current/deckhand-core connect`, using the user's `ssh` and
  `~/.ssh/config`. Banners are skipped; prompts mark the machine `needs_login`.
- Ids are `{machine, id}`, and the sidebar groups by machine. Reconnect uses backoff; an offline
  machine is shown greyed out with its last-known sessions.
- `machine add`, `machine update` and `--via` are **`ui`-only**.

### 8.2 What stays local

| Kind | Remote session |
|---|---|
| pi, Claude, shells, jobs | On the remote host |
| Browser tabs | In the local CEF, capped (§8.3) |
| App tabs | Left out in v1 |
| Screenshots, crops | `file.read` |

### 8.3 Trust in both directions

| Direction | Rule |
|---|---|
| Local → remote | SSH is the auth. The remote relay gets `ui` if it is that core's own binary and doesn't descend from a remote holder (anti-accident). **On Linux, remote `ui` = the same remote user**: there are no code-signing checks there. Requests carry `on_behalf:{kind}`. The local core checks `caller_may` first, and the remote core applies the kind's rules again (it can only lower `ui`). |
| **Remote → local** | A remote core (perhaps a compromised host) is capped at **`panel` scope for its own machine's sessions**: no `window.request` (clipboard, open_url, notify, reveal, pick_folder); OSC 52 from remote terminals is ignored; it can't confirm anything. **Its browser tabs can't reach local loopback, link-local or private (RFC 1918) addresses unless the user forwarded that port. This is enforced in CEF's resource request handler for every request, redirects included, checking the resolved address (P7).** |
| ControlMaster | Residual: while `ControlPersist` lasts, local same-user processes (local agents too) can use the control socket. They can already use the user's SSH keys and agent. The socket is in the 0700 runtime dir. |

### 8.4 Install

`machine add` runs `uname -sm`.
- **OS and arch match:** copy `core/current`, **after re-checking its DR**.
- **Otherwise:** download the same version's tarball, verify the `.sig` locally, and copy it over
  SSH.
- It installs to `~/.local/share/deckhand/core/<v>/`, then runs harness setup (HARNESSES.md).
- **Linux:** systemd user services need **`loginctl enable-linger`** (setup asks, and shows the
  command if polkit refuses). `XDG_RUNTIME_DIR` is removed at logout, so remote sockets live in
  `~/.local/state/deckhand/run/` (0700). A headless Linux core build and release target is its own
  work item.

### 8.5 Remote updates (decided: one-click offer)

An older remote core of the same generation shows an **Update** button on its machine row. A click
copies the build as in §8.4 and runs §7.2 and §7.3 there, so its sessions keep running.
`needs_update` (below `CORE_MIN` or an older generation) offers the same button. There are no
downgrades. A core not in Deckhand's folder gets the command shown instead and is left alone.

**Why not herdr's manual update:** Deckhand owns its install folder and both ends of the wire, so
an update is a session-keeping handover. Lag is safe under grow-only but invisible. One click (not
automatic) lets the user pick the moment, because the remote sessions pause briefly.

---

## 9. Alternatives

**Core restart: holder vs exec-in-place of the core** (map §6)

| | Holder (chosen) | Core exec-in-place |
|---|---|---|
| Core crash | Relaunched; sessions kept | **All sessions die** |
| Bad new core | Rollback to last healthy | All die |
| Processes | +1 | 0 |

**Holder upgrade: re-exec (chosen) vs drain (herdr)**

| | Re-exec | Drain |
|---|---|---|
| Old sessions get holder fixes | at once | only when those tabs close (weeks for a pi session) |
| Frozen wire | the bootstrap subset; the rest grows | **the whole wire, forever**. Round 1 found it too narrow before it shipped. |
| Holders alive | one | one per build still holding tabs |
| A bad or swapped holder build | preflight dry run; the keeper gates the fds on the live audit token and adopts orphans if the new image fails | hurts only new terminals |
| Code | state, fd and signal handling, preflight, keeper (~600 lines, in the holder) | none extra, but the core must speak every old wire |

Re-exec wins: a frozen full wire costs something on every future change, and with the dry run plus
the keeper, a bad or swapped holder build that fails to start never gets the terminals. Drain remains the
fallback. Also rejected: fd passing to a new process (children reparent to launchd; `NOTE_EXITSTATUS` keeps their exit codes, S2, but there's no `waitpid` or parent job control, and a core crash still needs a holder), one holder per terminal (100+ processes),
and tmux (ROADMAP 2026-10-30).

---

## 10. Order of work

Every step ships on its own.

| # | Step | Ships | Size |
|---|---|---|---|
| Q0 | ✅ **PTY master fds CLOEXEC** (merged, #18) | Closing a tab reliably hangs it up | done |
| S1 | ✅ **VT snapshot spike: GO** via GHOSTSNP (exact in 360/360; the formatter is the fallback). Branch `spike/vt-snapshot` 6bf748e. | §5.5, §7.2 | done |
| S2 | ✅ **Platform spike** on macOS 26.6.2: live audit tokens, launchd detach, re-exec and keeper confirmed; `/dev/fd/N` exec fails; ad-hoc runtime can't load CEF; quarantine kills. **Still owed:** macOS 14/15, Force Quit, logout (manual, before M1 ships). | §5.3, §6, §7.3 | done (14/15 owed) |
| M1 | **Holder in front of today's single-process app**, ad hoc allowed (§5.4). It covers: the holder (Odin, no ghostty or sokol); its wire and golden vectors; re-exec with dry run and keeper; the successor secret; the HMAC key; MAC'd `tokens.json`/`handover.json`; launchd detach; stable `core.sock` and the runtime dir move; offsets and exact handover on quit and update; the `instance.lock` SH rule; release hooks and env overrides compiled out; the updater test against the current release. **Broken into four PRs in §10.1.** **Doc changes:** PROTOCOL.md §1, CLAUDE.md §4a (an updated plugin reaches kept Claude tabs only after a restart, which the bar offers), PERSISTENCE.md, DEVELOPING.md "Releases", GUIDE.md. | **Quitting, crashing or updating Deckhand no longer stops pi, Claude or shells**, and the screens come back. **While the app is closed:** no status or bell; the `deckhand` CLI and Claude hooks fail (a `/clear` id goes unrecorded, so restore may resume the old conversation); held prompts wait; Atlas jobs don't run; **job runs stop when the app exits** (as today); in-flight requests are lost. | 7–9 weeks |
| D0 | **Developer ID** (the user's timing): certificate; `release.sh`'s existing Developer ID and notarization path as the default; CEF signed under the team; library validation on; DR checks switched on | M4 may start | ~1 week |
| M2 | **Boundary** (map M0): `src/core` with no sokol or Clay; the leaks fixed; a core loop | Compiler-checked split; hidden windows stop stalling parsing | 2–3 weeks |
| M3 | **In-process client and server** (map M1): replica and decoder, in-memory streams, the `ui` path, tab host routing | The real protocol under every test | 4–6 weeks |
| M4 | **Separate core** (`Deckhand Core.app`), **after D0**. It covers: mutual window ↔ core DR checks and the window floor; challenge-response bridge hellos; lifecycle; ⌘Q and stop-all; `no_window`; the skew handshake and `CORE_MIN`; install and core handover; supervisor rollback and `SUPERVISE`; `released-v1.json`. Job runs become core children; a handover waits ≤ 2 min for them, then stops them as `stopped_by_update`. Two security review rounds. | **#4 done:** status, bell, CLI, hooks, held prompts and jobs work with the window closed | 5–7 weeks |
| M5 | Login agent; jobs while closed | Scheduled jobs with Deckhand closed | 1–2 weeks |
| M6 | **Remote:** connect, install, update, caps (§8.3, the CEF request handler), sidebar, offline states, file fetch, harness setup, plus a **headless Linux core and release target** | **#5 done** | 7–11 weeks + 2–3 for Linux |
| M7 | Several windows | More windows | 2–4 weeks |

Remaining: about 31–46 weeks, now that Q0, S1 and S2 are done. M1 grew by 2 weeks, for the snapshot bindings and the keeper gate.

### 10.1 M1 in four PRs

The split-panes lesson: fewer, larger PRs, and one combined review where that's safe. Each PR
merges on its own, keeps `main` releasable, and runs its tests in under 3 minutes.

- **The holder path stays off by default** behind the setting `keep_sessions` until PR D turns
  it on. It appears under Settings › Experimental: *Keep sessions running when Deckhand quits*.
  Like every setting, it is user-only.
- **Ad hoc throughout** (§5.4). DR checks run as same-user until D0.

| PR | Contents | Files (main ones) | Tests (time) | Review | What the user can try |
|---|---|---|---|---|---|
| **A. Snapshot and holder wire libraries** (no behaviour change) | GHOSTSNP, continuation, terminal formatter and data-enum bindings, ported from `tools/vt-snapshot-spike/ffi.odin` (6bf748e). Every terminal sets `OPT_CONTINUATION_MAX_BYTES` at creation. One callback-and-theme registration helper, used by `term_start` and by decoded terminals. `snapshot_encode`/`decode` (meta JSON + GHOSTSNP, VT fallback, screen hash). The holder wire codec as its own package, with golden vectors and `released-holder.json`. | `src/ghostty/ghostty.odin`, `tests/abi_sizes.c`, `tests/ghostty_test.odin`, `src/term.odin`, new `src/snapshot.odin` (+ `_test`), new `src/holderwire/` (+ tests), `tests/holder-wire/v1/*.bin`, `tests/vt-corpus/`, `schema/released-holder.json`, DEVELOPING.md (libghostty bump checklist) | ABI sizes; snapshot round trip and determinism by screen hash; continuation-limit failure and retry; wire golden vectors, fuzz pass and grow-only diff. All in `./build.sh test` (+~10 s). | One round | Nothing visible. Terminals behave as before (a regression check on the continuation limit: big OSC 52 pastes, kitty images). |
| **B. Holder, launch and adopt** (behind `keep_sessions`) | `deckhand-core hold`: spawn, pump, reap, tails, offsets, `FOREGROUND`, ping, refusal while a core is attached, the HMAC key, the TCC disclaim. The launchd detach (`ProcessType=Interactive`, stale sweep, SIGPIPE, peer-checked `ready`). Install to `core/<v>/`, stripping quarantine after verifying. **Unconditional:** the stable `core.sock` and the runtime dir move to Application Support (PROTOCOL.md §1). With the setting on, PTYs go through the holder. On quit: `GOODBYE{handover}`, snapshots and MAC'd `handover.json`. On launch: adopt, or crash-restore from the tails. Also MAC'd `tokens.json` written on every mint and revoke, the read-only ack failing closed, the `instance.lock` SH rule, and the pre-M1 refusal message. | new `src/holder/`, new `src/launchd_darwin.odin`, `src/pty.odin`/`pty_posix.odin` (a holder-backed `Pty`), `src/socket.odin`/`socket_posix.odin`, `src/instance.odin`, `src/persist.odin`, `src/claude.odin` (`claude_pids`, ack state), `src/main.odin`, `build.sh`, `scripts/bundle-app.sh` (`Contents/Helpers/deckhand-core`), new `tests/scripts/keep-sessions.sh`, PROTOCOL.md, PERSISTENCE.md | Holder unit tests over a socketpair (~3 s); MAC tamper tests (<1 s); downgrade lock (<1 s). Scene `keep-sessions.sh` (~40 s): 6 fake terminals, quit, relaunch, screen hash equal; kill -9 the app, then `inexact`; kill -9 the holder, then `holder_lost`; pi reconnect and Claude ancestry. Test mode spawns the holder directly and never bootstraps launchd. S2's programs re-run on macOS 14/15 by hand. | **Two security rounds** | Turn the setting on, start a pi turn and a `top` in a shell, then ⌘Q. Reopen: both are still running, with their screens. |
| **C. Holder re-exec and keeper** | `UPGRADE`, the dry-run preflight on dup'd masters, the keeper-gated fd handover (live audit token), signal and mask reset, adopt-orphans with `NOTE_EXITSTATUS`, fallback drain, `holder_rev` and its CI check. | `src/holder/upgrade.odin`, `src/holder/keeper.odin`, `src/holder/state.odin` (+ tests), `scripts/check-holder-rev.sh`, `ci.yml` | Re-exec under load (~15 s, a unit test running real processes): 5 upgrades, no gaps, no split input, swapped binary refused, killed image adopted with exit codes | **Combined with D:** one two-round security review of C+D | Dev builds only: the palette's *Restart session holder* runs an upgrade to the same build; sessions don't notice. |
| **D. Updates keep sessions; release hardening** (turns `keep_sessions` on) | The updater does a §7.2 handover before relaunch, with the successor secret passed through the relaunch helper's `ready` socket. The update prompt is reworded. Release builds compile out the test hooks, the env overrides and `--print-token` (with Settings › Copy a control token added). `release.sh` checks for hook strings. The new zip is installed by **the current release's updater**. The default flips to on. Docs: CLAUDE.md §4a, GUIDE.md (ad-hoc residual, Full Disk Access after updates), DEVELOPING.md "Releases". | `src/update.odin`, `src/update_core.odin`, `src/main.odin`, `build.sh`, `scripts/release.sh`, `tests/scripts/update.sh`, `tests/scripts/release-checks.sh`, docs | `update.sh` extended (~60 s): update from `file://` fixtures with 3 live fake sessions, then screen hashes equal and pids unchanged. `release-checks.sh` (<10 s). The previous-release updater test is release-only (~1 min). | (with C) | Update Deckhand with a pi turn running: the turn carries on through the update. |

Sizes: A 1.5 weeks, B 3–3.5, C 1.5–2, D 1–1.5, so **7–9 weeks** for M1, reviews included. Order:
A → B → C+D, with C and D on stacked branches and merged together after their combined review. M1 alone delivers most of #4's value.

---

## 11. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Snapshot fidelity, two-emulator determinism, **GHOSTSNP v1 has no compatibility promise** | S1 measured it exact. Resize is sequenced by offset. Formats are listed in hello, with a VT `inexact` fallback, and a round-trip test runs on every libghostty bump (§5.5). |
| R2 | `ui` and holder ownership over sockets | §5.3. M4 only after the Developer ID (§5.4). Security review rounds. |
| R3 | TOCTOU between checking the `UPGRADE` file and `execve`. S2: `execve("/dev/fd/N")` fails on macOS, and a path swap runs. | **The keeper-gated handover** (§7.3 step 4): the masters and key go only to an image whose live audit token passes the DR, so a swapped image gets the pid but no terminals. The core re-checks the holder's DR (P9). |
| R4 | A new holder image crashing | Dry-run resume on dup'd masters; the keeper adopts orphans with exit codes (`NOTE_EXITSTATUS`, S2); rare `holder_rev` bumps; upgrade-under-load tests |
| R5 | Ad-hoc M1: same-user code can drive the holder | Stated (§5.4); the Developer ID before M4 |
| R6 | Ad-hoc TCC re-prompts and silent Full Disk Access loss | Ends with the Developer ID. Documented until then. |
| R7 | M1's closed-app gap | Hooks must fail safe; the read-only guard never needs the socket (checked in M1); M4 closes the gap |
| R8 | Bundle-relative paths under live sessions | Everything lives in `core/<v>/`, collected only when unused |
| R9 | Moving ticks off `frame()` changes scene timing | M2 keeps `core_tick()` from `frame()` until M4 |
| R10 | Remote: Linux build, linger, SSH quirks, CEF address checks (DNS rebinding) | Its own work item; the handler checks the resolved address on every request |
| R11 | Scope | Every step ships on its own |
| R12 | S2 ran only on macOS 26.6.2 (the minimum is 14) | Run S2's programs on 14 and 15, plus Force Quit and logout, before M1's PR B ships (§10.1) |
| R13 | An unfinished over-limit sequence (a large OSC 52) blocks snapshots | A limit sized to the largest accepted sequence, retry after ground, VT `inexact` at a handover |

---

## 12. Testing (every new test runs in seconds; no run exceeds 3 min)

| What | How | Time | Layer |
|---|---|---|---|
| Holder wire | Golden vectors for the frozen subset (fail if one changes), a fuzz pass over the decoder, the `released-holder.json` diff | < 1 s | unit |
| Holder behaviour | An in-process holder and a fake core over a socketpair, with `/bin/sh` children: spawn, input, pixel resize, signals, exit-after-output, offsets, tail cap, backlog, `REFUSED` cases (attached, floor, secret), ping timeout, the HMAC key only after a check | ~3 s | unit |
| Holder re-exec | A real holder with 6 children printing counters, upgraded 5 times under load and mid-input. Checks: pid and parent unchanged, offsets continuous, no lost or split input; signal dispositions and mask reset (a child's `sigreport`); a failed dry run leads to drain; `execve` failure; the new image killed at once, or a swapped binary (wrong identifier) → the keeper refuses the fds and adopts (`degraded`, `exit(3)` reported as 3) | ~15 s | unit |
| Grow-only API | Generated schema against `released-v1.json` | < 1 s | unit |
| Skew, floors, auth decisions | Pure table tests: `skew_check`, `peer_allowed` (DR, floor, successor secret, dev or ad-hoc mode), window floor | < 1 s | unit |
| MAC'd files | A tampered or truncated `tokens.json`/`handover.json` fails closed; a read-only tab is stopped | < 1 s | unit |
| Release build | `release.sh` checks: no hook strings, no env-override strings, entitlements as listed, library validation on (D0+); the current release's updater installs the new zip | ~1 min | release only |
| Snapshot and determinism | S1's harness (`tools/vt-snapshot-spike`) as a unit test: 9 cases × random snapshot points, mid-escape and mid-UTF-8, resizes at the same offset, **compared by screen hash**; the formatter fallback's known gaps asserted as `inexact`; an encode failing over the continuation limit, then succeeding after ground. ~11 s in the spike; the unit run uses 10 points per case. | ~3 s | unit |
| libghostty bump | Old-encode/new-decode round trip of the corpus (snapshots from the previous version kept in `tests/vt-corpus/`) | ~2 s | unit, on bump |
| Handover | Scene: a test-mode core, 6 fake terminals, 5 handovers under load. Checks: screens `exact`, no replayed query replies, tokens reconnect (pi reconnect, Claude ancestry). Variants: kill -9 the core (`inexact`); kill -9 the holder; a new core crashing twice (rollback, `SUPERVISE`) | ~40 s | scene |
| Downgrade lock | A pre-M1-style `instance.lock` EX taker fails while a holder lives | < 1 s | unit |
| Window attach | Close the window, output continues, reopen, compare | ~30 s | scene |
| Remote | A second core with its own dirs via `--via 'deckhand-core connect'` (no sshd): install, caps (`window.request` refused, OSC 52 ignored, a loopback URL blocked), reconnect | ~30 s | scene |
| launchd, real signing | S2's manual checks; one nightly scene on a Developer ID build | — | nightly |

Test builds keep the hooks and use per-test dirs; they skip DR checks as ad-hoc builds do (§5.4).

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
| Q7 | Holder upgrades: automatic on a `holder_rev` change, or ask first? | Automatic, named in the release notes |
| Q8 | When D0 happens (it gates M4) | Before M3 ends |

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
- **If herdr source is ever translated line by line:** keep herdr's copyright notice in that file,
  add a "modified from herdr-core <path> at <commit>" line, and add the Apache-2.0 text to
  `THIRD_PARTY_NOTICES.md` with any upstream `NOTICE` (none at cd12ddd or 7fe7ac3; check again at
  copy time).
- **Where Deckhand deliberately differs:**
  - designated-requirement checks in both directions (herdr trusts any same-user `HELLO`);
  - holder re-exec with a keeper, instead of drain;
  - byte offsets;
  - HMAC'd state files;
  - Ed25519-signed core artifacts (herdr's manifest is checksum-only);
  - the core bundled in the app;
  - one-click remote updates;
  - programs never stall while no core is attached.
