# Deckhand roadmap

The living plan for Deckhand: what it is for, the rules it follows, how it is built, what is done
and what comes next. Update it when a decision is made or a phase moves. Finished detail belongs
in commits, [GUIDE.md](GUIDE.md) and [DEVELOPING.md](DEVELOPING.md), not here.

Status key: ✅ done · 🔨 in progress · ⬜ not started · ❓ open question

## 1. What Deckhand is

A native desktop app for working with coding agents ([pi](https://pi.dev) and Claude Code)
across projects, with the feel of the Codex desktop app (smooth, mouse-friendly, calm). Each agent
stays itself, unchanged, as the engine: the conversation happens in a real terminal running the
agent's own TUI, and everything around it is native UI.

- **Native.** No Electron, no browser engine for the app shell. macOS today; Linux and Windows
  are planned (phase 5).
- **Agents stay themselves.** pi and Claude Code keep working in any plain terminal. Deckhand adds
  a frame around them and brings its own integration for each (loaded at start, nothing written
  into their config); it never forks them. [pi-kit](https://github.com/McFalljb/pi-kit) is
  optional ([HARNESSES.md](HARNESSES.md)).
- **UI/UX is the product.** Every screen should feel deliberate and fast.

## 2. Principles

1. **Everything is an interface.** Every action is a named command with typed arguments that goes
   through one command layer. Buttons, keys, the palette, Atlas and outside scripts all call the
   same commands. The whole app state is readable and every change emits an event. Nothing in the
   UI can do something the interface cannot.
2. **Destructive commands confirm**, whoever calls them (you, Atlas, a script).
3. **Extensions work in both places.** A pi extension is written once: it shows its data in the
   terminal when pi runs alone, and sends the same data to Deckhand panels when pi runs inside it.
4. **The terminal is bare inside Deckhand.** Sidebar content (workers, todos, shells, …) lives in
   the GUI; the terminal shows only the agent's conversation and input.
5. **Keyboard first, mouse everywhere.** Every command has a shortcut or a palette entry, and a
   button or menu row.
6. **Plain procedural code.** Odin, small files, no framework; platform code behind small
   interfaces.
7. **Pin and test what we depend on:** pinned versions, ABI tests for libghostty-vt, deliberate
   upgrades.

## 3. Goals

| # | Goal | Phase |
|---|---|---|
| G1 | Projects → sessions → tabs: an agent tab plus any number of shell, editor, browser, Markdown and app tabs. | 0–1, 3–4 |
| G2 | In Deckhand the terminal is bare; all sidebar content lives in the GUI. | 1 |
| G3 | Left column: projects with their sessions, plus project-less **Chats**. | 1 |
| G4 | A native Markdown renderer as a tab. | 2 |
| G5 | Browser tabs where you select parts of a page and comment on them for the agent. | 3 |
| G6 | Games: the agent works with the engine through an engine bridge; showing the game in a tab is optional. | 4 |
| G7 | The Codex desktop app's feel as the UX reference (adapted, not cloned). | all |
| G8 | Settings are first class: a Settings tab to edit pi's and Claude Code's files and reload running agents. | 2 |
| G9 | **Atlas**, a built-in agent that drives Deckhand: projects, sessions, settings, jobs. | 2 |
| G10 | Everything is an interface (principle 1). | all |
| G11 | Hot reload: reload agent tabs when extensions or settings change; restart them when the agent itself updates. | 2 |
| G12 | Safe agent updates: a tested minimum version per harness, a nightly canary, one-click install and update. | 1–2 |
| G13 | Sessions outlive the window: closing, crashing or updating Deckhand never stops an agent. | 6 |
| G14 | Every machine in one sidebar: sessions on remote hosts over SSH ([#5](https://github.com/McFalljb/deckhand/issues/5)). | 6 |

## 4. Architecture

```
┌──────────────┬───────────────────────────────┬────────────────┐
│ Sessions     │ [pi] [shell 1] [browser] [+]  │ Todos          │
│ Files        │                               │ Subagents      │
│ ▾ Projects   │   tab content                 │ Shells         │
│   ▾ pi-kit   │   (the agent's TUI in a        │ …panels from   │
│     ● sess A │    terminal, a shell, an       │  extensions    │
│     ○ sess B │    editor, a browser, an app)  │                │
│ ▾ Chats      │                               │                │
└──────────────┴───────────────────────────────┴────────────────┘
```

- **Stack:** Odin + [Clay](https://github.com/nicbarker/clay) (layout) +
  [sokol](https://github.com/floooh/sokol-odin) (window, input, Metal) + Ghostty's
  **libghostty-vt** (terminal emulation, drawn by us). CEF for browser tabs. Versions are pinned
  in [DEVELOPING.md](DEVELOPING.md#pinned-versions).
- **Three processes.** The **window** (`Deckhand.app`) draws, takes input, and hosts browser and
  app tabs. The **core** (`deckhand-core-serve` in `Deckhand Core.app`) owns the state, the
  commands, the control socket, agents' logic, jobs and Atlas; the window is a client over
  `core.sock` with a replica of the state. The **session holder** (`deckhand-core hold`) owns the
  PTYs, so terminals survive a core restart or update. What survives what is in
  [GUIDE.md](GUIDE.md#how-deckhand-runs); the code map is in
  [DEVELOPING.md](DEVELOPING.md#architecture); the design is
  [plans/background-core.md](plans/background-core.md).
- **Data model:** Project → Session → Tabs, in one plain, serialisable state struct. Every change
  is a command with a typed target id, run by `run_command` in the core. Focus, layout and pending
  confirmations are state too. Saved workspace: [PERSISTENCE.md](PERSISTENCE.md).
- **Tabs** follow the [Deckhand tab protocol](TAB-PROTOCOL.md): display as a shared GPU texture
  under Deckhand's overlays, input forwarded by Deckhand, control on the socket's envelope.
- **Bridges**, one message style for all:
  - **pi:** Deckhand's bundled integration (`integrations/pi`, loaded with `pi -e`) connects to
    the socket; extensions publish panels and receive actions.
  - **Claude Code:** a bundled plugin (`integrations/claude-code`, loaded with `--plugin-dir`)
    with the `deckhand` CLI and hooks ([CLAUDE.md](CLAUDE.md)).
  - **Control:** commands, state and events over the same socket, for Atlas and scripts
    ([PROTOCOL.md](PROTOCOL.md)).
  - **Engines** (later): the tab protocol's control channel, exposed to agents as tools
    ([ENGINE-BRIDGE.md](ENGINE-BRIDGE.md)).

## 5. Phases

### Phases 0–1: the shell ✅

The window, pi's TUI in libghostty-vt, tabs per session, the command layer and state, the control
socket, panels, text and input methods, workspace save and restore, the left column (projects,
sessions, chats, pins, filters, a tidy project list), status dots for pi and any OSC 7501 program,
first-run setup and the main folder, harness setup, the palette, buttons for every action,
nightly canary and CI on macOS.

- 🔨 Codex-style look and motion (G7): themes, appearance, text size and motion are in; polish goes on.
- ⬜ Selection: menus for every shortcut.
- ⬜ A Linux compile job in CI, so platform assumptions don't rot until phase 5.

### Editor and panes

- ✅ Editor tabs, step 1: piece-table buffer, tree-sitter highlighting, find and replace, git
  gutter, file sync, the ⌘P finder. The Files tab and worktree switcher.
- ✅ Split panes ([plans/split-panes.md](plans/split-panes.md)): nested splits, a tab strip per
  pane, drag tabs to move and split, saved per session.
- ⬜ Step 2: LSP, multi-cursor, one file in two panes, project-wide search, a fuller diff view.
- ⬜ A maximize-pane toggle; agents opening tabs beside themselves.

### Phase 2: Atlas, settings, Markdown, changes

- ✅ Atlas: pi's TUI in a drawer (⌘J), the desk tools, its own model and prompt.
- ✅ Jobs and memory ([ATLAS.md](ATLAS.md)): job notes in the main folder, run by the core on
  their schedule, also with the window closed.
- ✅ Settings tab (pi's and Claude Code's files), hot reload (G11), the Markdown tab (G4).
- 🔨 Changes tab: stage, discard, commit, review. Not yet: merge, push, per-hunk staging.
- 🔨 Worktrees: the switcher and clean-up are in. Creating worktrees waits on a rule (§7).
- ⬜ Updating pi's packages from Settings (G12).
- ⬜ Universal annotation: freeze any tab, drag a box, send the crop and a note to the agent.
- ⬜ Voice dictation with Hex (on-device): check its paste into Deckhand, then tools to pull
  dictated notes, then a mic button.

### Phase 3: browser tabs ✅

CEF rendered off-screen into the tab texture; navigation and polish; comment mode; agents read
and act on pages ([BROWSER.md](BROWSER.md)).

### Claude Code tabs ✅

Claude tabs and Claude-only sessions, Claude chats (read-only with chats), several accounts,
sessions found on disk, comments, status, Atlas driving Claude tabs, the settings and update bars,
rows at parity with pi's ([CLAUDE.md](CLAUDE.md)).

- ⬜ Deckhand without pi: Atlas and jobs on Claude.

### Phase 4: games and the engine bridge

- ✅ App tabs: a program's frames in a tab, input forwarded, `app_call` and friends
  ([ENGINE-BRIDGE.md](ENGINE-BRIDGE.md)).
- ⬜ The engine bridge in an engine: inspect and set state, pause and step, capture, hit test (G6).
- ⬜ Game annotations through the engine's hit test.

### Phase 5: Linux and Windows

- ⬜ ConPTY on Windows; Windows linking.
- ⬜ Text rendering and input methods per OS.
- ⬜ CI builds and packaging for all three.

### Phase 6: the background core and remote machines

Design: [plans/background-core.md](plans/background-core.md) (G13, G14).

- ✅ **M1** The session holder: terminals keep running while Deckhand quits, crashes or updates.
- ✅ **M2** The boundary: `src/core` builds with no window code.
- ✅ **M3** The window as a client of the core, in process, over the real protocol.
- ✅ **M4** The separate core: `Deckhand Core.app`, ⌘Q closes only the window, **Quit Deckhand
  and Stop All Sessions…**, reconnect and relaunch, updates hand the core over while sessions run.
  Builds are self-signed with "Deckhand Self-Signed". On by default, with an opt-out in Settings.
- ⬜ **M5** Jobs while closed: a login agent, so schedules run after Stop All and after a restart
  of the Mac.
- ⬜ **M6** Remote machines: sessions on other hosts in the same sidebar, over SSH, with a headless
  Linux core ([#5](https://github.com/McFalljb/deckhand/issues/5)). Planned as six Mac→Mac PRs,
  then four Linux PRs: [plans/background-core.md §10.4](plans/background-core.md#104-m6-in-prs).
- ⬜ **M7** Several windows on one core.
- ⬜ **D0** An Apple Developer ID: notarized builds and the hardened runtime. One line in
  `scripts/sign.sh` switches the identity; the trust checks follow by themselves.

## 6. Decisions

Decisions that still shape the code. Superseded ones are gone; their history is in git.

| Date | Decision | Why |
|---|---|---|
| 2026-10-30 | Native app, no Electron or Tauri; Odin + Clay + sokol | Native feel, plain code, direct C interop. |
| 2026-10-30 | Terminal = libghostty-vt, drawn by us; Ghostty pinned, prebuilt libs committed, Zig only in `toolchain/` | Ghostty's emulation on every OS; app builds need only Odin. |
| 2026-10-30 | Everything is an interface (one command layer) | Parity for Atlas and scripts; cheap now, expensive later. |
| 2026-10-30 | Commands address ids, never positions; destructive commands confirm in two phases | A position can name something else by the time a command runs. |
| 2026-10-30 | Permission modes per caller and command class (`ask` default, `trusted`, `auto`), user-only to change | An agent must never approve its own destructive actions or raise its own permissions. |
| 2026-10-30 | Tabs follow the tab protocol ([TAB-PROTOCOL.md](TAB-PROTOCOL.md)); the engine bridge is its control channel | Overlays, comments and shortcuts work over every tab; one contract for engines, browsers and apps. |
| 2026-10-30 | Games: engine bridge first, in-tab view optional | The point is the agent working with the engine. |
| 2026-10-30 | Accessibility out of scope for now; Clay element ids stay stable | Keeps the door open without the cost now. |
| 2026-10-31 | One command table (`src/core/command_table.odin`) for permissions and `list_commands` | A new command's permission is decided in one place. |
| 2026-10-31 | Chats run in one visible folder with pi's normal store | `cd <chats folder> && pi --resume` finds them; reuses projects' paths. |
| 2026-10-31 | Agents never edit through the editor; editor tabs follow the disk | One writer per file; unsaved user edits are never touched. |
| 2026-10-31 | File commands from a tab-bound caller resolve in its own session; writing outside its project confirms (`fs_write`) | Atlas may work across projects, but not silently. |
| 2026-11-01 | Atlas runs pi's own TUI in the drawer; its prompt is a file the user edits | One pi UI everywhere. |
| 2026-11-01 | Browser engine = CEF, off-screen into the tab texture, pinned and downloaded at build time ([BROWSER.md](BROWSER.md)) | Chrome inside the tab with full agent control and overlays; ~250 MB accepted. |
| 2026-11-01 | Jobs need no approval step; controls are the per-job toggle, pause and limits ([ATLAS.md](ATLAS.md)) | Keychain prompts after every rebuild cost more than they protected. |
| 2026-11-03 | Claude Code tabs: the user's own `claude` with a bundled plugin; a per-tab token accepted only from the tab's own processes | Nothing installed in the user's Claude config; a leaked token is useless outside the tab. |
| 2026-11-03 | Read-only Claude chats: Deckhand's profile last in argv (plan mode, deny rules, a fail-closed command guard) | Parity with read-only pi chats; no flag or mode can undo a deny rule. |
| 2026-11-04 | Deckhand ships its own pi integration, loaded with `pi -e`; pi 1.4.0 minimum | No feature needs pi-kit; nothing is written to `~/.pi`. |
| 2026-11-04 | Read-only pi chats are enforced by pi's own `--tools` allowlist, at every start | pi-kit is optional; the model gets read tools only. |
| 2026-11-04 | Atlas works in the main folder, never in `~` | macOS counts Atlas's file access as Deckhand's; `~` walks into privacy-protected folders. |
| 2026-11-02 | Minimum macOS 14, checked for every linked object (`scripts/check-minos.sh`) | Keeps the stated floor real. |
| 2026-11-07 | Split panes: free splits, a tab strip per pane, saved per session; agent tabs stay in their pane in v1 | The user's answers in [plans/split-panes.md](plans/split-panes.md) §8. |
| 2026-11-07 | Sessions outlive the window: a core process plus a session holder (not tmux); ⌘Q closes only the window; **Quit Deckhand and Stop All Sessions…** stops everything | Reattach after a window crash or an update; tmux has no native Windows and would double the emulation. [plans/background-core.md](plans/background-core.md) §2. |
| 2026-11-08 | Every core is fully featured (sessions, jobs, Atlas), with or without a window; remotes are cores too | Nothing local-only that remote machines must undo. |
| 2026-11-08 | Builds are signed with "Deckhand Self-Signed" until a Developer ID; the trust checks pick their mode from the process's own signature | The split didn't wait for a Developer ID; switching later is one line. |

## 7. Open questions

- ❓ **Game engine:** which engine the games use, to shape the engine bridge.
- ❓ **Worktree rules:** where Deckhand creates worktrees (beside the repo, inside it, or one
  global folder) and whether new sessions use one by default.
- 💡 **Hermes Agent alongside pi:** an always-on assistant as a client of the control socket,
  within the permission modes. Not planned.

## 8. Risks

- libghostty-vt's C ABI will change again before 1.0; the hand-written bindings have ABI tests.
- sokol: one window per process (M7 runs more window processes).
- Text rendering is our job on every OS (emoji, fallbacks, shaping).
- Windows ConPTY quirks with fullscreen TUIs.
- Self-signed builds: other programs running as you can pass the trust checks until the
  Developer ID ([plans/background-core.md](plans/background-core.md) §5.4).

## 9. Related

- [GUIDE.md](GUIDE.md) (the user guide), [HARNESSES.md](HARNESSES.md), [CLAUDE.md](CLAUDE.md).
- [DEVELOPING.md](DEVELOPING.md) (build, architecture, releases), [TESTING.md](TESTING.md).
- [PROTOCOL.md](PROTOCOL.md), [TAB-PROTOCOL.md](TAB-PROTOCOL.md), [PERSISTENCE.md](PERSISTENCE.md).
- [ATLAS.md](ATLAS.md), [BROWSER.md](BROWSER.md), [ENGINE-BRIDGE.md](ENGINE-BRIDGE.md).
- Design records: [plans/background-core.md](plans/background-core.md),
  [plans/split-panes.md](plans/split-panes.md).
