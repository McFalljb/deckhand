# Deckhand roadmap

The living plan for Deckhand: what it is for, the rules it follows, how it is built, what is done
and what comes next. Update it when a decision is made or a phase moves; keep finished detail in
commits and [DEVELOPING.md](DEVELOPING.md), not here.

Status key: ✅ done · 🔨 in progress · ⬜ not started · ❓ open question

## 1. What Deckhand is

A native desktop app for working with coding agents ([pi](https://pi.dev) and
Claude Code) across projects, with the feel of the Codex desktop app (smooth, mouse-friendly,
calm) while keeping each agent itself, unchanged, as the engine. The conversation happens in a
real terminal running the agent's own TUI; everything around it is native UI.

- **Native on macOS, Linux and Windows.** No Electron, no browser engine for the app shell.
- **Agents stay themselves.** pi and Claude Code keep working in any plain terminal. Deckhand adds
  a frame around them and brings its own integration for each (loaded at start, nothing written
  into their config); it never forks them. [pi-kit](https://github.com/McFalljb/pi-kit) is
  optional ([HARNESSES.md](HARNESSES.md)).
- **UI/UX is the product.** Every screen should feel deliberate and fast.

## 2. Principles

1. **Everything is an interface.** Every action is a named command with typed arguments that goes
   through one command layer. Buttons, keys, the command palette, the Home agent and outside
   scripts all call the same commands. The whole app state is readable and every change emits an
   event. Nothing in the UI can do something the interface cannot.
2. **Destructive commands confirm**, whoever calls them (you, the Home agent, a script).
3. **Extensions work in both places.** A pi extension is written once: it shows its data in the
   terminal when pi runs alone, and sends the same data to Deckhand panels when pi runs inside it.
4. **The terminal is bare inside Deckhand.** Sidebar content (workers, todos, shells, …) lives in the
   GUI; the terminal shows only pi's conversation and input.
5. **Keyboard first, mouse everywhere.** Every command has a shortcut or a palette entry; every
   command is also reachable by mouse.
6. **Plain procedural code.** Odin, small files, no framework; platform-specific code behind small
   interfaces.
7. **Pin and test what we depend on**, as pi-kit does: pinned versions, ABI tests for
   libghostty-vt, deliberate upgrades.

## 3. Goals

| # | Goal | Phase |
|---|---|---|
| G1 | Projects → sessions → tabs. A session has exactly one pi tab plus any number of shell, browser, markdown and app tabs. | 0–1, 3–4 |
| G2 | In Deckhand the terminal is bare; all sidebar content lives in the GUI sidebar. | 1 |
| G3 | Left column: projects you set up, with their sessions, plus project-less **Chats** for non-coding conversations. | 1 |
| G4 | A native markdown renderer as a tab. | 2 |
| G5 | Browser tabs where you select parts of a page and annotate them for pi (as in Codex). | 3 |
| G6 | Games: the agent interacts with the engine itself through an engine bridge built into the engine; showing the game inside a tab is optional. | 4 |
| G7 | The Codex desktop app's feel as the UX reference (adapted, not cloned). | all |
| G8 | Settings are first class: a native Settings tab, outside any project, to edit pi itself and reload every running pi. | 2 |
| G9 | A **Home** pi session that starts with the app and controls Deckhand: find, create and edit projects, sessions, settings — everything. | 2 |
| G10 | Everything is an interface (principle 1). | 0 onward |
| G11 | Hot reload: `/reload` every pi tab when extensions/settings change; restart pi tabs with `pi --session` when pi itself updates (idle tabs only; warn about background work). | 2 |
| G12 | Safe agent updates: a tested minimum version per harness, nightly canary against latest, Deckhand tests in CI, one-click install and update from setup and Settings. | 1–2 |

## 4. Architecture

```
┌──────────────┬───────────────────────────────┬────────────────┐
│ Home         │ [pi] [shell 1] [browser] [+]  │ Workers        │
│ Settings     │                               │ Todos          │
│ ▾ Projects   │   tab content                 │ Shells         │
│   ▾ pi-kit   │   (pi's TUI in a Ghostty       │ Changes / diff │
│     ● sess A │    terminal, a shell, a        │ …panels from   │
│     ○ sess B │    browser, markdown, a game)  │  pi extensions │
│ ▾ Chats      │                               │                │
└──────────────┴───────────────────────────────┴────────────────┘
```

- **Stack:** Odin + [Clay](https://github.com/nicbarker/clay) (layout) +
  [sokol](https://github.com/floooh/sokol-odin) (window, input, Metal/D3D/GL) + Ghostty's
  **libghostty-vt** (terminal emulation, drawn by us from its render state). Versions are pinned in
  [DEVELOPING.md](DEVELOPING.md#pinned-versions).
- **libghostty-vt** is built once per pinned Ghostty version for every target with
  `scripts/build-ghostty.sh` (Zig 0.17 in `toolchain/`); app builds need only Odin.
- **Process model (decided 2026-10-30):** Deckhand grows its own small tmux-like **core** that
  owns the PTYs, pi processes, State and the socket; windows are clients of it, and more windows
  are separate window processes. Not tmux itself (no native Windows, a second terminal emulation in
  front of Ghostty, two copies of the state). Today it is one process; the rule that keeps the
  split cheap is already enforced: no sokol/window calls in state, commands or services (they go
  through `platform`, `src/platform.odin`). The split itself comes later.
- **Data model:** Project → Session → Tabs (`Tab_Kind` union). One plain, serialisable app-state
  struct; every change is a command with a typed target id, submitted to one inbox and run by
  `run_command` on the main thread. Focus, layout and pending confirmations are State too.
- **Sessions** come from pi's store (`~/.pi/agent/sessions/--<cwd>--/*.jsonl`). A session's
  identity is pi's session id (UUID) + cwd (+ session dir); new chats start
  `pi --session-id <uuid>` with an id Deckhand picks. Saved workspace: [PERSISTENCE.md](PERSISTENCE.md).
- **Tabs** follow the [Deckhand tab protocol](TAB-PROTOCOL.md): display preferably as a shared GPU
  texture drawn under Deckhand's overlays (native child view as the fallback), input forwarded by
  Deckhand, and a control channel on the same envelope as the socket. Terminals and markdown are
  drawn by Deckhand; game engines and browsers implement it.
- **Bridges** (one message style for all of them):
  - **pi ↔ Deckhand:** the bridge extension in Deckhand's bundled pi integration
    (`integrations/pi`, loaded into every pi tab with `pi -e`) connects to Deckhand's local socket;
    extensions publish panels (list, table, diff, markdown, buttons) and receive actions.
  - **Claude Code ↔ Deckhand:** a bundled plugin (`integrations/claude-code`, loaded with
    `--plugin-dir`) with the `deckhand` CLI and hooks. Design: [CLAUDE.md](CLAUDE.md).
  - **Deckhand control:** the command layer and state over the same socket, for the Home agent and
    scripts. Schema: [PROTOCOL.md](PROTOCOL.md).
  - **engine ↔ pi** (later): the engine implements the tab protocol's control channel through a
    small Odin package (this is the engine bridge), exposed to pi as tools.
- **Deckhand ships its own integrations.** No feature needs pi-kit or anything installed into
  `~/.pi` or `~/.claude`; an installed pi-kit's desk extensions step back inside Deckhand
  ([HARNESSES.md](HARNESSES.md)). The protocol is written down and versioned
  ([PROTOCOL.md](PROTOCOL.md)).

## 5. Phases

### Phase 0 — Proof of concept 🔨
- ✅ Native window (Clay + sokol); projects and sessions from pi's store; click to resume, "New
  chat".
- ✅ pi's fullscreen TUI in our libghostty-vt terminal: rendering, typing, Shift/Alt keys, wheel,
  bracketed paste, Shift+drag selection + copy, resize; ~1% CPU idle, ~5% streaming.
- ✅ Tabs per session: one pi tab + shell tabs (Cmd+T/W/1–9); background sessions keep running.
- ✅ libghostty-vt prebuilt for macOS arm64/x86_64, Linux x86_64/aarch64, Windows x86_64; ABI tests.
- ✅ Command layer + single app-state struct (G10): `run_command` is the only state writer; `state_json()` snapshot; `emit_event` hook for the future socket. Terminal keystrokes go straight to the focused terminal; agents use `Send_Text`.
- ⬜ A real streamed model reply checked end to end.

### Phase 0.5 — Foundations ✅
Groundwork for the command layer and state.
- ✅ Commands by stable id; `Result{ok, error, created_id, pending, confirmation}`.
- ✅ Session identity = pi UUID via `--session-id`; reopening focuses; [PERSISTENCE.md](PERSISTENCE.md) (schema only).
- ✅ Command inbox (any thread → main thread), GCD main-queue wake, long commands finish via events.
- ✅ No sokol calls in state/commands (`platform` interface).
- ✅ `focus` in State, one text-field widget (rename project), keys routed by focus.
- ✅ Layout in State; redacted command log from `emit_event`.
- ✅ [PROTOCOL.md](PROTOCOL.md); hand-written JSON for commands, results, events, state.
- ✅ Tab-host contract → [TAB-PROTOCOL.md](TAB-PROTOCOL.md) + `Tab_Host` sketch.
- ✅ One JSON command parser for test mode/scripts/socket; `assert_state`; platform split for test bits.
- ✅ Failed launches return errors; queries don't bump `version`; two-phase confirm for closing a
  running tab and quitting, with per-caller permission modes and close rules.

### Phase 1 — Daily-usable shell (macOS first)
- ✅ Minimum macOS 14.0 (Sonoma), checked by `build.sh` for every linked object and the app bundle.
- ✅ Control socket (moved from phase 2; the bridge is its client): listener, `hello` + tokens,
  commands, state, event subscription with filters, pi-tab status/prompt routing, `--ctl`
  client ([PROTOCOL.md](PROTOCOL.md)). Not yet: Windows pipes.
- ✅ GUI sidebar (G2): the bridge's panels (subagents, shells, todos) in the right column, foldable,
  toggled with ⌥⌘B; the terminal sidebar hides when Deckhand advertises `panels`.
- ✅ Text: CoreText on macOS behind a text-backend interface (font.odin): system fallback, colour
  emoji, grapheme clusters (mode 2027), bold/italic, underline styles, box-drawing sprites,
  proportional UI font, growing atlas. Ligatures supported but off for the terminal. Later per-OS (FreeType+HarfBuzz, DirectWrite).
- ✅ Input methods and dead keys: NSTextInputClient added to sokol's view at run time
  (`src/native/platform_macos.m`, vendor untouched); composition shown at the caret / terminal
  cursor; emoji picker. Real IMEs and dead keys verified only through the protocol methods in test
  mode (no synthetic OS input).
- 🔨 Selection: plain drag (Shift when the program tracks the mouse), double-click word,
  triple-click line, theme selection colour ✅; text fields: click, drag, double/triple click,
  ⌥/⌘ arrows ✅. Menus and full shortcuts ⬜.
- ✅ Blended title bar (macOS): transparent full-size title bar, traffic lights centred in the
  top bar over the left column, empty top bar drags the window, double-click zooms. Title hidden;
  the window title (Mission Control, Window menu) is the current session's.
- ✅ Workspace save/restore ([PERSISTENCE.md](PERSISTENCE.md)): projects, open sessions and tabs,
  layout and settings in `workspace.json`; restored sessions start lazily (only the focused one at
  launch); `--fresh`. `close_session` (row button, palette, socket) closes an open session.
- ✅ Left column management (2026-10-31): add a project from the GUI ("+" with a folder picker
  that can make a new folder, or drop folders on the window), even with no pi sessions yet; "+"
  on a project row and "+ New session" start a session there (2026-11-01: was "New chat"); an **Open** group on top with every open
  session of every project (current first; browsing projects never moves the centre); pin
  projects and sessions (Pinned group, Move up/down), sort each section (Recent activity, Name,
  Created), one filter field (⌘⇧F, fuzzy, Esc clears) plus Running / Waiting / Pinned quick
  filters, hide (never delete) with Show hidden, context menus (Pin, New session, Rename,
  Reveal in Finder, Copy path, Hide, Close session); resizable left and right columns (drag the
  divider, double-click resets). All through commands (`set_pinned`, `set_hidden`, `set_sort`,
  `set_sidebar_folded`, `set_filter`, `reveal`, `copy_path`) and saved in `workspace.json`.
  Tidy project list (2026-11-01, `set_tidy_projects`, gear "Tidy project list", on by default;
  rules in `src/project_tidy.odin`): projects in temp folders and ones whose folder is gone are
  hidden unless pinned or open (Show hidden shows them tagged "temp" / "folder missing"; filter
  text finds them). Rows nest, sessions never move (2026-11-01): git roots and
  worktrees are top-level; 2+ sibling folders in a folder that is no project share a group row (under its parent project);
  other subfolders nest under the nearest listed project (never home or `/`); collapsed by
  default, open rows saved (`set_row_expanded`).
  Not yet: removing a project for good, drag to reorder pins, "/" to filter (the column never
  holds the keyboard).
- ✅ Chats (2026-10-31): project-less sessions run as full pi in a visible folder (the main
  folder's `chats/`, or `~/Chats` without a main folder, or a folder you choose), with pi's normal
  store, so `pi --resume` in that folder finds them; their own section with "+". Settings (user-only, palette, saved): `chats_dir`,
  `chats_readonly` (`PI_KIT_READONLY=1`). Not yet: listing chats from an earlier Chats folder in
  the Chats section (that folder shows as an ordinary project).

- ✅ Buttons for every action (2026-10-31): a top bar toolbar (left column toggle and New chat by
  the traffic lights, "+" and a New menu on the tab strip, a search pill for the palette,
  Settings, the right column toggle), a close button on every tab (the pi tab's closes its
  session), "…" on hovered rows for their context menu, a search icon in the filter, buttons in
  the centre's empty states. A settings popover (the gear; appearance, look, reduce motion, Chats,
  rescan), settings as files (⌘,: pi's and extensions' settings files open in editor tabs; credential
  files never; pi's JSON settings saved only when pi can read them; Reload pi sessions after a save), and a keyboard shortcuts sheet (⌘/). Labels and
  shortcuts come from the action table; tooltips (500 ms, one frame, no idle redraws). Icons are
  a small vector set drawn with sokol_gl (`src/icons.odin`). `set_layout {left_open}` hides the
  left column (⌘B).

- ✅ Session status dots from `pi.status` (working pulse, waiting for you, question, error);
  the bell for notifications.
- ✅ Agent status for every terminal tab (2026-11-03, `src/agent_status.odin`): any program that
  speaks OSC 7501 (Claude Code ≥ 2.1.295) gets the same dots, roll-up and bell as pi (the bridge
  wins on a pi tab); "done, not seen yet" with Mark as unread; the Needs attention sort; a
  tooltip naming the status's source and age. Next: a per-program icon from `app`.
- ✅ Bridge extension (first in pi-kit, now in Deckhand's bundled pi integration,
  `integrations/pi/extensions/bridge`): session id, status, panels; bare terminal in Deckhand (G2).
- ✅ First-run setup and the main folder (GUIDE.md "The first run"): one folder for notes, jobs,
  memory, Atlas's prompt and chats (your existing notes folder, `~/pi-desk`, or any folder).
- ✅ Harness setup ([HARNESSES.md](HARNESSES.md)): each harness (pi, Claude Code) lists what it
  needs and what is recommended; installs and updates run on click, never with `sudo`.
- ✅ Command palette (⌘K): actions (one table, `src/actions.odin`), open tabs, sessions (the
  selected project's + open ones), projects; fuzzy ranking, recents first; runs through the
  inbox as the user, so confirmations apply. Recents are not saved yet.
- 🔨 Codex-style look and motion (G7). Done: design tokens (`src/theme.odin`), three looks (`set_theme`), each dark and light (`set_appearance` system/light/dark, follows macOS live, pi re-themes via mode 2031), restyled sidebar/tabs/bar/field/empty states, hover and selection fades, reduce-motion, proportional UI font (system font; terminals and the editor monospaced) in two type sizes (body, secondary), and a text size setting for the chrome (`set_text_size`, the gear's "Text size": small/medium/default/large, 12/11 to 15/13 pt; saved).
- ✅ Nightly canary CI (pi-kit PR #7): install latest pi + packages, run unit/contract/smoke tests, open an issue on failure; pins unchanged (G12).
- ⬜ Deckhand CI on a macOS runner: build, ABI tests, scripted pi run checked via libghostty-vt render state; session-file format contract test (G12).
- ⬜ Linux compile job in CI, so platform assumptions don't rot until phase 5.

### Native editor (in steps)
- ✅ Step 1 (2026-10-31): editor tabs (`open_file`, deduped by real path; title = file name, dot
  when unsaved). Piece-table buffer with grouped undo, UTF-8 and CRLF/LF kept, tabs vs spaces
  detected, binary and >20 MB files refused. Mouse (click, drag, double/triple click), the usual
  keys (⌥/⌘ moves, Shift, PgUp/PgDn, ⌘Z/⇧⌘Z, ⌘A, Tab/⇧Tab, auto-indent, ⌘/), IME, smooth
  scrolling, line numbers, current line, soft wrap. Tree-sitter highlighting (13 grammars,
  vendored at pinned tags, incremental; slow reparses wait for a typing pause). ⌘S atomic save;
  the file is watched (FSEvents + 2 s stat poll): clean → silent reload, unsaved → banner
  (Compare / Keep mine / Reload); closing unsaved asks. Find/replace (⌘F, ⌘G, ⌥⌘F, case, regex),
  go to line (⌃G), git gutter vs HEAD and a "Diff with HEAD" view, ⌘P file finder. Every action
  has a button: toolbar with shortcut tooltips, right-click menu. File-system model and commands
  (`list_dir`, `create_file`, `create_dir`, `rename_path`, `delete_path` → Trash with
  confirmation, `reveal_in_finder`); editor tabs restored on relaunch.
  Known limits: saving replaces the file (hard links keep the old text; extended attributes and
  ACLs are not copied); files outside every project, or in the home folder itself, are followed
  by a 2 s poll rather than the watcher.
  Not yet: multi-cursor, LSP, project search, split view, `$1` groups in regex
  replace, Markdown inline highlighting, unsaved edits kept across restarts.
- ✅ Left column clarity and spacing (2026-11-01): Sessions tab as Open / Projects (a tree: the
  selected project expands inline with its sessions, "Show N more" past 8, "+ New session"; a
  click on it folds it; rename and the sessions' sort in its "…" menu) / Chats (bubble rows,
  "+ New chat"). Folder vs bubble on Open rows, the pi tab, the palette and the window title;
  "session" in projects, "chat" in Chats (⌘N = New chat, ⇧⌘N = New session). Spacing roles
  in theme.odin (GAP_*, PAD_*, TREE_*, TAB_MIN/MAX_W); tabs between min and max width; editor
  toolbar groups with separators (groups left out when they do not fit); menus sized to their
  rows, shadows under menus and the settings popover; window minimum 800×480. A layout audit
  test checks text and icons never overlap or leave their containers. Not yet: several
  projects expanded at once (only the selected one expands).
- ✅ Files tab (2026-10-31): the left column switches Sessions | Files (⌘⇧E, saved). The tree of
  the folder on screen (session, else selected project; Chats → its folder): lazy listings,
  folders first in natural order, git letters/colours, ignored files dimmed, dotfiles muted,
  `.git` hidden; virtualised (10k rows: ~0.3 ms layout per frame); header buttons (new file,
  new folder, collapse all, refresh, reveal); fuzzy filter over paths; a single click opens a
  preview tab (italic; replaced by the next; editing, a double-click or Enter keeps it); the
  active editor file is revealed; keyboard (arrows, Enter, Space, F2, ⌘⌫, Esc); inline rename;
  row menu (open, new, rename, Trash with confirmation, reveal, copy path / relative path,
  terminal here); drag a file onto a terminal to paste its path; live updates from the
  watcher; open folders saved per project. Commands: `set_left_tab`, `files_expand`,
  `files_collapse_all`, `files_reveal`, `set_files_filter`, `keep_tab`, `open_file preview`,
  `new_shell_tab cwd`, `list_dir ignored`. Not yet: drag within the tree to move, multi-select,
  open to the side (no split view yet).
- ⬜ Step 2: LSP, multi-cursor, split view, project-wide search, a fuller diff view.

### Phase 2 — Home, Settings, markdown, annotations
- 🔨 Home session + Deckhand control tools (G9): a Home pi in its own session dir
  (`<data dir>/home`), working in the main folder (else the data dir's `home/`, never `~`; see
  Decisions, 2026-11-04), started on the first ⌘J and resumed across restarts, with a single-use `control` token bound to its tab; the Home
  pane (⌘J, slides over the right side), a Home button with its status dot, palette actions;
  `list_commands` from one command table; bound callers never act on or hear about their own
  tab or session; `send_text` from control refused into pi tabs and waiting sessions. The desk
  tools: `integrations/pi/extensions/desk`. Not yet: Home creating/editing projects beyond
  `add_project`/`rename_project`.
- 🔨 The built-in agent ("Atlas", 2026-10-31; terminal since 2026-11-01): Home's pi in its own
  terminal UI in a drawer (⌘J; slides over the panels column, 📌 pins it as a column,
  resizable), with a bridge (status) and the desk tools. Unread badge, "needs you" tint and OS
  notifications from its bridge status. Its model: setting `agent_model` (`--model`), shown in
  the drawer; the Model button opens pi's own model selector. Its prompt: `ATLAS.md` in the main
  folder's `atlas/` (else the data dir; `--append-system-prompt`), edited from the Settings tab. Starts on first open, or
  at launch if the drawer was open at quit (docs/PROTOCOL.md §8).
  Jobs and memory: design in [ATLAS.md](ATLAS.md) (draft, 2026-11-01). Decided: jobs
  run even when Deckhand is closed (a small background helper, login item); jobs may act while
  the user is away, none by default; one folder for everything, the main folder (which can be
  an existing notes folder, `PI_KIT_NOTES_DIR`): session notes as episodic memory, capped
  `memory/USER.md` + `memory/MEMORY.md`, `atlas/` (ATLAS.md moves here, HEARTBEAT.md), `jobs/`
  (one note per job with recent runs; full output in the data dir); Slack/phone delivery later.
  Later still: editing Deckhand.
- 🔨 Settings (G8): decided 2026-11-01 — no forms; a Settings tab in the left column lists pi's
  settings files (global, project `.pi/`, extensions) as a tree that opens them in the editor.
  Credential files never shown; JSON checked the way pi reads it; reload bar after saving.
- ✅ Hot reload (G11): pi's config files watched (agent dir, local packages, a tab's `.pi/`, context files up the tree; FSEvents + 2 s poll, 1 s debounce) → a bar "pi settings changed — Reload N idle tabs" (Details, Later; replaces the editor's saved-settings bar); busy or blocked tabs queued until idle, background work named in the one confirmation; a pi version change on disk → "Restart N idle tabs" (`pi --session`); `pi_reload_all` (gear, palette; Atlas only with the user's confirmation), `pi_restart_updated`, `pi_reload_later` (PROTOCOL.md "Hot reload").
- ⬜ Updates from Settings: show the tested pin, run `install.sh --update` and the printed pi upgrade, then hot reload (G12).
- ✅ Markdown tab, step 1 (G4): our own CommonMark + GFM parser (`src/markdown*.odin`, no
  dependencies; md4c dropped), preview/source, find, live reload, links. Step 2: diagrams through
  the fenced-language renderer table (`MD_FENCE_RENDERERS`), local images.
- ⬜ Universal annotation: freeze any tab, drag a box, add a note → crop + note to the session's pi.
- 🔨 Per-session changes view (2026-11-01): a Changes tab per session and checkout (the top
  bar's "±" with the changed-file count, the palette's Show changes, a worktree row's menu):
  uncommitted files (staged, unstaged, untracked) and the branch's commits not on the default
  branch (`git diff <merge-base> HEAD`), grouped by status with +/- counts; the selected file's
  diff (red/green; 5,000-line steps; binary and credentials files never shown); Open at the
  hunk, Stage, Unstage, Discard (confirmed; files git does not have go to the Trash after a
  second confirmation), Commit (the user's hooks run), Ask pi to review. Commands
  `changes_open`, `changes_list` (paths and counts only), `changes_stage`, `changes_unstage`,
  `changes_discard`, `changes_commit` (the user's). Refresh debounced on file-watch events and
  on focus. Not yet: merge (disabled until its semantics are settled), push, per-hunk
  staging, syntax colours in diffs, keeping the tab across restarts.
- 🔨 Worktrees: display decided 2026-11-01. Done (2026-11-01): the Files tab's checkout switcher
  under the project name (main checkout and worktrees with branch, path, ahead/behind, changed
  files, merged, missing/prunable, detached, locked; branches without a worktree with age,
  ahead/behind the default branch, merged); picking one shows it in the tree (kept per project);
  row actions: terminal and pi session there (the session is kept with the project's), Reveal,
  copy path/branch, Clean up for merged clean worktrees (`git worktree remove`, `git branch -d`,
  never forced; the user only, confirmed). Commands `list_worktrees`, `files_set_root`,
  `worktree_cleanup`, `worktree_session`. Not yet: worktree projects nested under their main
  project in the Sessions tab; creating worktrees waits on rules for where they go
  and when sessions use them (open question).
- ⬜ Voice dictation with Hex (anomalyco/hex, MIT, on-device; added 2026-11-01), in steps:
  1. Check Hex's paste into Deckhand (pi tabs, Atlas field, editor) works; accept its insertion
     path if it uses accessibility rather than ⌘V.
  2. pi-kit tool/skill reading `hex history --json` / `hex meetings list --json` so pi can pull
     dictated notes and meetings into a session; "send to pi session" if Hex allows targets.
  3. Built-in mic button (Atlas drawer, pi sessions) via Hex's engine (`@kitlangton/hex` SDK +
     Hex helper), once the helper is published separately. macOS needs Apple silicon, 15+.

### Phase 3 — Browser tabs
- Design (draft): [BROWSER.md](BROWSER.md): engine CEF (decided), packaging, tab model, annotation, agent tools, build plan.
- ✅ Engine: CEF, rendered off-screen into the tab texture (BROWSER.md §1).
- ✅ Browser tabs tied to sessions: navigation, toolbar, popups, saved tabs (step 2); tab polish:
  context menu, page dialogs, find, zoom, downloads, permission and crash bars (step 3).
- ✅ Comment mode: element picking and annotations sent to pi (steps 4–6).
- ✅ Agents read pages: the pi integration's browser tools and the `deckhand` CLI for Claude
  tabs (step 7).
- ✅ Agents act on pages: click, type, press, scroll, select, hover, upload; Take over; password,
  card and one-time-code fields refused (step 8).

### Claude Code tabs
- Design: [CLAUDE.md](CLAUDE.md).
- ✅ Claude tabs in sessions with a bundled plugin (`--plugin-dir`): the `deckhand` CLI for the
  session's browser and app tabs (same rules as pi tabs), a per-tab token usable only from the
  tab's own processes, resume from the project menu and restore on relaunch, comments with the
  next message, agents' text held until Claude is idle and nothing is typed.
- ✅ Claude-only sessions (a session whose main tab is Claude, no pi tab): **New Claude session**
  in a project; its Claude sessions as rows of its session list (Deckhand's own history, marked
  Claude: pin, hide, rename, filters, attention sort; a click resumes); saved and restored.
- ✅ Without Claude Code installed nothing breaks: the buttons say so and how to install it.
- ✅ Claude chats (**+ New Claude chat**; Claude tabs in chats), read-only with Deckhand's profile (plan mode, deny rules, a fail-closed guard on Bash) while chats are read-only.
- ✅ Comments' Send now to a Claude tab.
- ✅ Program status (OSC 7501) with the hooks as the turn source, and a status dot.
- ✅ Atlas and scripts drive Claude tabs: `claude_prompt` (held until idle), `claude_wait_idle`.
- ✅ A session's agent shows the user a file in a tab of its own session (`deckhand show`,
  `desk_show`; Markdown renders), without moving the user's view; secrets and devices refused.
- ✅ Runtime operations: the Claude settings and update bars (Restart resumes each conversation),
  Restart with model…, Claude Code's files in the Settings tab; palette entries for them and
  **Restart all Claude tabs**; ⌥⌘T and ⌥⌘N for a Claude tab and a Claude chat.
- ✅ Rows at parity with pi's: transcript path and model, session info, Reveal and Copy path,
  question and error dots, a rename pushed to Claude Code, Todos and Subagents panels.
- ⬜ Claude Code sessions started outside Deckhand in a project's rows; more than one Claude account.
- ⬜ Subagents' durations and current tool; "hooks not running" and minimum-version hints.
- ⬜ Deckhand without pi (a default agent, Atlas and jobs on Claude).
- ⬜ The token's process check on Linux and Windows.

### Phase 4 — Games and the engine bridge
- Design (draft): [ENGINE-BRIDGE.md](ENGINE-BRIDGE.md): app tab, Mach-channel IOSurface ring, `tab.*` additions, `desk-app` tools, annotation, fake app, build plan.
- ⬜ Engine bridge = the tab protocol's control channel, as a small Odin package in the engine:
  inspect/set state, pause/step, capture, inject input, hit test — as pi tools via a pi
  extension; works with or without Deckhand (G6).
- ✅ App tabs: a program's frames shown in a tab (a Mach channel and an IOSurface ring), its input
  forwarded, and the general `app_call` / `app_screenshot` / `app_input` / `app_events` pipe
  (ENGINE-BRIDGE.md steps 1–2; tested with a fake app, `tests/fake-app/`).
- ⬜ Game annotations using the engine's hit test.

### Phase 5 — Linux and Windows
- ⬜ ConPTY on Windows; Windows linking (Zig's compiler_rt clash).
- ⬜ Text rendering and input methods per OS.
- ⬜ CI builds for all three platforms; packaging.

## 6. Decisions

| Date | Decision | Why |
|---|---|---|
| 2026-10-30 | Native app, no Electron (Tauri also dropped) | Native feel on every OS. |
| 2026-10-30 | Odin + Clay + sokol | Plain code, direct C interop, small and fast. |
| 2026-10-30 | Terminal = libghostty-vt, drawn by us | Ghostty's emulation on all OSes; Ghostty's full embedding API is macOS/iOS only. |
| 2026-10-30 | Pin Ghostty v1.4.0; Zig 0.17 only in `toolchain/`; prebuilt libs committed | Build once per Ghostty version; app builds need only Odin. |
| 2026-10-30 | (superseded 2026-11-04) pi-kit and Deckhand separate; bridge extension lives in pi-kit | Terminal setup stays independent; extensions work in both. |
| 2026-10-30 | Everything is an interface (one command layer) | Parity for the Home agent and scripts; cheap now, expensive later. |
| 2026-10-30 | Games: engine bridge first, in-tab viewport optional | The point is the agent interacting with the engine. |
| 2026-10-30 | Process model: our own small tmux-like core (PTYs, pi, State, socket); windows are clients, more windows = more window processes. Not tmux. Now: only "no sokol in state/commands/services" + socket in phase 1; split later | Reattach after a window crash, several windows; tmux has no native Windows and would double terminal emulation and state. |
| 2026-10-30 | Tabs follow the Deckhand tab protocol ([TAB-PROTOCOL.md](TAB-PROTOCOL.md)): shared GPU texture by default, native view as fallback, input via Deckhand, control on the socket envelope; engine bridge = its control channel | Overlays, annotations and shortcuts work over every tab; one contract for engines, browsers and apps. |
| 2026-10-30 | Accessibility out of scope for now; Clay element ids stay stable | Keeps the door open (ids are what an a11y tree would hang on) without the cost now. |
| 2026-10-30 | Commands address ids, never positions; session identity = pi session UUID; destructive commands confirm in two phases | Needed before the control socket: a position or a runtime index can name something else by the time a command runs. |
| 2026-10-30 | Permission modes per caller and command class (`ask` default: only the user confirms in the UI; `trusted`: caller confirms its own tokens for listed classes; `auto`), user-only to change | An agent must never approve its own destructive actions or raise its own permissions. |
| 2026-10-30 | Close confirmation is a setting per tab kind, default `auto`: shells ask only while a program runs in the foreground; pi tabs always ask until the bridge reports busy/idle | The common terminal behaviour; no prompt for idle shells. |
| 2026-10-30 | Command log rotates at 10 MB, three files | Bounded disk use. |
| 2026-10-31 | Home: a slide-over pane (⌘J); its pi in `<data dir>/home` with cwd = the user's home folder (cwd superseded 2026-11-04); starts on first open; one `control` token bound to its tab | Home works across projects (paths resolve as the user types them) while its sessions stay out of pi's project store; lazy start costs nothing until used; binding the token to the tab lets Deckhand refuse self-actions server-side. |
| 2026-10-31 | One command table (`src/command_table.odin`) for permissions and `list_commands` | A new command is listed for the agents that may send it, and its permission is decided in one place. |
| 2026-11-04 | Deckhand ships its own pi integration (`integrations/pi`: bridge, Atlas's desk tools, browser and app tools, panels), loaded into every pi tab with `pi -e`, as its Claude plugin with `--plugin-dir`; pi tabs get `DECKHAND_*` variables instead of `PI_DESK_SOCKET`/`PI_DESK_TOKEN`/`PI_DESK_CONTROL_TOKEN`; pi 1.4.0 minimum | No feature needs a pi-kit change or install any more, nothing is written to `~/.pi`, and an installed pi-kit's desk extensions go inert without being edited (docs/HARNESSES.md). Replaces the 2026-10-30 decision that the bridge lives in pi-kit. |
| 2026-11-04 | Read-only pi chats are enforced by pi itself: every start of a chat's pi (new, resume, restore, restart, reload, any caller) ends with `--tools read,grep,find,ls --exclude-tools 'mcp__*' --no-mcp` (`PI_READONLY_ARGS`, shared with read-only jobs), plus `PI_KIT_READONLY=1`; no bash; refused (chats and read jobs) on a known pi older than 1.0.4; follows the setting at each start, unlike Claude tabs | pi-kit is optional, so `PI_KIT_READONLY` alone left a chat that says read-only able to write without it; pi's plain-name `--tools` is an allowlist for every tool (an unnamed extension tool is never registered), and pi keeps the last `--tools`, so the flags go last. Bash is left out as in jobs: pi has no read-only bash of its own. It limits the model's tools only: installed extensions' own code still runs. 1.0.4 brought `--no-mcp` and `*` patterns. |
| 2026-11-03 | Claude-only sessions: an open session's `agent` is `pi` or `claude`; a Claude session's main tab is its Claude tab and its key (pins, hide, rows, bell) is Claude's session id; its rows come from Deckhand's own history (100), never Claude Code's files; "Resume Claude: …" menu rows replaced by the rows; no Claude chats yet | Claude as a peer of pi with the least new machinery: every key-based path (pins, status, Open group, bell) works unchanged; privacy (no transcripts read); a chat's read-only setting cannot bind Claude, so Claude stays in projects until that is designed. |
| 2026-11-03 | Claude in chats: a Claude chat is a Claude-only session of the Chats entry; while chats are read-only every start of a Claude tab in a chat (any caller) gets Deckhand's read-only profile last in argv (plan mode, `--setting-sources user`, `--settings` with deny rules, no bypass/auto mode and a sync PreToolUse guard `Deckhand hook readonly` with `onFailure: block` and `\|\| exit 2`, `--disallowedTools` for the tools that write, spawn, schedule or use MCP); Bash allowed behind the guard (pi-kit's MUTATING, shared vectors); the profile is the tab's (saved, kept by restore and an agent's resume); the user's flags from an allowlist | Parity with pi's read-only chats, which allow read-only bash; a hook that cannot run is a non-blocking error in Claude Code unless it sets `onFailure: block`, so the guard is named by absolute path and fails closed; a deny rule cannot be allowed back by any mode, allow rule or flag; an allowlist of flags cannot miss a new one that undoes read-only. |
| 2026-11-03 | Claude Code tabs: the user's own `claude` with a bundled plugin via `--plugin-dir`; a multi-use per-tab token (caller `panel` + `claude`) accepted only from the tab's descendant processes | Nothing installed in the user's Claude config; plugin and app versions always match; the CLI is a process per call so it cannot swap tokens like pi's bridge, and the process check keeps a leaked token useless outside the tab; it never grants more than the session's pi tab. |
| 2026-10-31 | Chats = one project-like entry (group `chats`) for the folder `~/Chats` (setting `chats_dir`): pi runs there with its normal store (no `--session-dir`); full pi unless `chats_readonly` | Chats are visible and resumable from a plain terminal (`cd ~/Chats && pi --resume`); reuses projects' open/new/restore paths; that folder is never also a project. |
| 2026-10-31 | Left-column pins and hidden items are kept by identity (project cwd, pi session id), not runtime ids; the filter is State but not saved | Survive rescans and restarts; agents see and set the same filter the user sees. |
| 2026-10-31 | (superseded 2026-11-01) The Home agent runs `pi --mode rpc` behind a native chat drawer (not a terminal pane); no bridge in it, status from the RPC stream; its chat is State through quiet internal commands | A calm, always-there assistant (dots / Grok-style) with buttons, cards and inline questions a TUI cannot draw; one writer of State stays true. |
| 2026-10-31 | (superseded 2026-11-01: no offers) Offered buttons run their command as the user who clicks (confirmations apply); user-only settings, `agent_*` commands and buttons from an earlier run never run | The agent proposes, the user decides; ids from an earlier run may name other things now. |
| 2026-10-31 | Native editor in steps: step 1 here (editing, highlighting, save and file sync, find, git gutter, file-system model); step 2: LSP, multi-cursor, split view, project-wide search, diff view | A usable editor now; the rest on the same buffer and command layer. |
| 2026-10-31 | Editor buffer = piece table (original + add buffers, per-piece newline counts, lazy prefix sums); tree-sitter v0.27.1 + 13 grammars vendored as C sources at pinned tags, compiled once by build.sh; git through the `git` CLI (HEAD text, status, check-ignore, ls-files) | Piece table: cheap inserts anywhere, zero-copy reads for tree-sitter, undo stores only the edited text; simpler than a rope at our sizes. Vendored C: no network or toolchain at build time. git CLI: no libgit2 to vendor; calls are rare and debounced. |
| 2026-10-31 | File commands resolve paths for the caller (a tab-bound caller's own session), park the absolute path in confirmations, and a `control` caller creating or renaming outside its own project confirms under a new class `fs_write` (deleting is always class `delete`) | A confirmation must act on the file it showed; Atlas may work across projects, but not silently. |
| 2026-10-31 | Agents never edit through the editor (no `editor_edit`); editor tabs follow the disk | Agents already edit files with their own tools; one writer per file, and the buffer of a user with unsaved changes is never touched. |
| 2026-10-31 | Every action reachable by mouse too: buttons or menu rows, with the shortcut in a tooltip or beside the row | Rule: no keyboard-only features. |
| 2026-10-31 | Atlas = a built-in Hermes: an agent that controls all pi and Deckhand settings, timed jobs and monitors through the command layer. Settings become commands, under a `settings_write` confirmation class | One interface for people, scripts and agents; changing settings is as reviewable and confirmable as any other destructive action. |
| 2026-11-01 | Atlas runs pi's terminal UI in the drawer (bridge + desk tools); the native RPC chat, desk_offer/desk_report rendering and `offerable` are gone. Its model is a setting passed as `--model` only for a new session or a changed setting; the Model button opens pi's own selector (Ctrl+L). Its prompt is `<data dir>/atlas/ATLAS.md`, appended | One pi UI everywhere (pi's own dialogs, model selector, keys); a pick in pi survives a resume; the prompt is a file the user edits |
| 2026-11-01 | Atlas jobs and memory: jobs run when Deckhand is closed via a background helper; jobs may act while away, none by default; memory, Atlas's prompt and job notes live in the user's notes folder; Slack/phone later. Design: [ATLAS.md](ATLAS.md) | In the end a cron job with its own memory management (as in Hermes Agent and OpenClaw); one folder every agent (pi, Claude Code, Atlas) reads |
| 2026-11-01 | Browser engine = CEF: Chromium off-screen into the tab texture, Deckhand becomes a .app bundle, CEF binaries pinned and downloaded at build time, agent control over DevTools in-process. Design: [BROWSER.md](BROWSER.md) | Chrome inside the tab with full agent control and Deckhand overlays on top; heavier (~250 MB) accepted |
| 2026-11-01 | Jobs need no approval: any job note runs on its schedule, agents may create and edit jobs; controls are the per-job enable toggle, pause / Pause all and the limits. The HMAC approval key (macOS Keychain), Approve UI and `job_approve` are removed ([ATLAS.md](ATLAS.md) §10.3) | Ad-hoc signed rebuilds made macOS prompt for Keychain access after every build; the prompts cost more than the protection was worth |
| 2026-11-04 | Atlas starts in the main folder, else the data dir's `home/`; never in `~`, even when `~` is the main folder. A conversation recorded in another folder is copied once into the new one (`pi --fork`, a derived id) | Atlas runs as part of Deckhand, so macOS counts its file access as Deckhand's: an `ls` or `grep -r` from `~` walks into Desktop, Documents and Downloads and raises privacy prompts. pi resumes a conversation in the folder it recorded, hence the fork (GUIDE.md "Where it works"). |
| 2026-11-02 | Minimum macOS 14. Every native object targets 14 or older: Clay is compiled from `clay.h` by `build.sh` (the submodule's prebuilt macOS `clay.a` targets 15), and `build.sh` fails on any linked object or bundled Mach-O file newer than `MACOS_MIN` (`scripts/check-minos.sh`) | The prebuilt Clay made 15 the real floor while the bundle claimed 14; not yet tried on a real macOS 14 machine |

## 7. Open questions

- ✅ **Browser engine:** CEF, Chromium rendered off-screen into the tab texture (decided
  2026-11-01; design and go/no-go spike in [BROWSER.md](BROWSER.md)).
- ✅ **Home session:** a slide-over pane in the main window (decided 2026-10-31). A second window
  can come with the core/window split.
- ❓ **Game engine:** which engine/language the games use, to shape the engine bridge.
- ✅ **Chats folder and preset:** `~/Chats` as cwd with pi's normal store, full pi; both settings (decided 2026-10-31).
- 💡 **Idea (2026-10-31): Hermes Agent alongside pi.** Nous Research's Hermes (memory, scheduled jobs,
  chat gateways) as a client of the control socket: an always-on "chief of staff" that can open
  sessions, prompt pi tabs and message the user, within the permission modes. pi stays the coding
  agent; Deckhand stays agent-neutral. Could later be the Home agent. Not planned; revisit after the
  control socket ships.
- ❓ **Worktree rules:** where Deckhand creates worktrees (sibling `<repo>-worktrees/`, inside the
  repo, or one global folder) and whether new sessions use one by default. Not decided yet.

## 8. Risks

- libghostty-vt's C ABI will change once more before 1.0; bindings are hand-written (ABI tests
  guard them).
- sokol: one window per process, no input-method support.
- Text rendering is our job on every OS (emoji, fallbacks, shaping).
- Windows ConPTY quirks with fullscreen TUIs.
- Scope: every goal above is real work; phases keep it shippable.

## 9. Related

- [GUIDE.md](GUIDE.md) (the user guide), [HARNESSES.md](HARNESSES.md) (pi and Claude Code setup),
  [CLAUDE.md](CLAUDE.md) (Claude Code tabs).
- [DEVELOPING.md](DEVELOPING.md) (build, pinned versions, architecture detail, tests, releases),
  [TESTING.md](TESTING.md).
- pi-kit: `GUIDE.md` (sidebar, extensions, updating), `AGENTS.md`.
- [PROTOCOL.md](PROTOCOL.md) (socket, commands, state, events, bridge, panels), [TAB-PROTOCOL.md](TAB-PROTOCOL.md), [PERSISTENCE.md](PERSISTENCE.md).
- [ATLAS.md](ATLAS.md) (Atlas jobs and memory), [BROWSER.md](BROWSER.md) (browser tabs),
  [ENGINE-BRIDGE.md](ENGINE-BRIDGE.md) (app tabs and game engines).
