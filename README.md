# pi-desk

A native macOS desktop app for the [pi](https://github.com/earendil-works) coding agent: your
projects and sessions on the left, pi's own fullscreen terminal UI in the centre, and more tabs per
session beside it (shell, editor, Markdown, browser and app tabs). An agent of its own ("Atlas")
can drive the app through a control socket and run scheduled jobs.

**Status: early.** pi-desk is a personal project in active development. Expect rough edges,
breaking changes to its files and protocol, and macOS only for now (the platform pieces sit behind
small files so Linux and Windows can follow, but nothing else is wired up).

**Using pi-desk:** see the [user guide](docs/GUIDE.md): the window, sessions and chats, tabs,
the editor, the Files and Settings tabs, Atlas, the bell, shortcuts, your data and
troubleshooting. The rest of this README is for developers.

## Requirements

- macOS on Apple silicon (arm64). Intel Macs build without the browser tab (CEF is wired up for
  arm64 only).
- macOS 14 or later.
- [Odin](https://odin-lang.org/) `dev-2026-09` and `clang` (Xcode command line tools).
- [pi](https://github.com/earendil-works) installed and on your login shell's `PATH`: pi-desk runs it
  in its tabs.
- Optional: [pi-kit](https://github.com/McFalljb/pi-kit), a set of pi extensions. Its `desk-bridge`
  extension lets pi talk to pi-desk (status dots, panels, comments) and its `desk` tools let an agent
  drive the app. pi-desk works without it, with less to show.

## Setting up pi and pi-kit

pi-desk runs the pi you already have; it adds no accounts or keys of its own.

1. Install pi ([`@earendil-works/pi-coding-agent`](https://www.npmjs.com/package/@earendil-works/pi-coding-agent),
   Node 22.19+), run `pi` once in a terminal and `/login` to your providers. Check that a login
   shell finds it: `$SHELL -l -c 'command -v pi'`.
2. Optional, for status dots, panels, comments and agent tools: install
   [pi-kit](https://github.com/McFalljb/pi-kit) as its README says
   (`git clone https://github.com/McFalljb/pi-kit ~/pi-kit && ~/pi-kit/scripts/install.sh`).
3. Start pi-desk. The first-run sheet asks for a main folder (sessions, jobs, Atlas's prompt);
   see the [user guide](docs/GUIDE.md).

## Install a release

Releases on GitHub carry `pi-desk-<version>-macos-arm64.zip` and its `.sha256`. Unless a release
says it is notarized, the app is signed ad hoc (not with an Apple Developer ID), so macOS
Gatekeeper refuses the first open. Unzip it, move `pi-desk.app` to `/Applications`, then either
right-click it and choose **Open** (macOS 14), or open it once and click **Open Anyway** in System
Settings › Privacy & Security (macOS 15 and later), or clear the download flag:

```sh
shasum -a 256 -c pi-desk-<version>-macos-arm64.zip.sha256
xattr -dr com.apple.quarantine /Applications/pi-desk.app
```

The app is about 340 MB, mostly Chromium (the browser tab).

## Build from source

```sh
git clone --recursive https://github.com/McFalljb/pi-desk.git
cd pi-desk
./build.sh        # first build downloads CEF (~135 MB, checksummed) into ~/Library/Caches/pi-desk/cef
./build.sh run    # or: build/pi-desk [DIR]
./build.sh test   # unit and binding tests
```

`./build.sh` fetches the pinned [CEF](https://bitbucket.org/chromiumembedded/cef) build
(`vendor/cef/VERSION`) with `scripts/fetch-cef.sh` and lays out `build/pi-desk.app` around it.
`PI_DESK_NO_CEF=1 ./build.sh` builds without the browser tab and without the download.

Releases are packaged by `scripts/release.sh` (build, tests, version in `Info.plist`, signing,
zip and checksum); `.github/workflows/release.yml` runs it on a `v*` tag and drafts the GitHub
Release. Locally: `scripts/release.sh --version 0.1.0 --no-upload` writes `dist/`.

**What works today:** pi tabs, shell tabs, the editor, Markdown, Files, Settings, Changes, Jobs,
Atlas, browser tabs with comment mode, and agents reading and acting on browser pages (pi-kit's
`desk-browser`: clicking, typing, uploads behind a bar, Take over; [docs/BROWSER.md](docs/BROWSER.md)
§6 step 8).

## Licence

MIT, see [LICENSE](LICENSE). Third-party components and their licences are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the app bundle carries them in
`Contents/Resources/licenses/`.

## Overview for developers

Stack: **Odin** + **Clay** (layout) + **sokol** (window, Metal/GL/D3D) + **libghostty-vt**
(terminal emulation) + **CEF** (browser tabs). It targets macOS for now. Platform-specific pieces (PTY, fonts, test
hooks) sit behind small files so Linux and Windows can follow.

## Build and run

```sh
./build.sh            # release build -> build/pi-desk
./build.sh run        # build and run
./build.sh test       # binding tests (ABI sizes vs C, encoders, render state) + command-layer tests
build/pi-desk [DIR]   # optional DIR: open a new pi chat there on start
```

**Minimum macOS: 14.0** (Sonoma). The browser needs Apple silicon (CEF is wired up for arm64 only;
elsewhere `build.sh` builds without it). `build.sh` sets `MACOS_MIN` and checks it: before linking,
`scripts/check-minos.sh` reads the minimum macOS of every native library Odin links (each archive
member, from `otool -l`), and after bundling every Mach-O file in `pi-desk.app` (the CEF framework,
the helpers); any newer than `MACOS_MIN` fails the build. Not yet run on a real macOS 14 machine.

⌘J shows the agent's drawer ("Atlas"): pi-desk's own pi in its terminal UI, which drives the app
through the control socket (pi-kit's `desk` tools; docs/PROTOCOL.md §8). 📌 pins the drawer as a
column; its Model button opens pi's model selector (setting `agent_model`); its prompt is
`ATLAS.md` in the main folder's `atlas/` (setting `home_dir`, set up in the first-run sheet,
src/ui_setup.odin; each subfolder may be overridden, src/folders.odin; copied there from the data
dir once, the data dir's copy stays as the fallback; Settings tab, Folders group). Every action has a button as well as a
shortcut: the top bar (left column ⌘B, New chat ⌘N, "+" ⌘T, search ⌘K, the notification bell, quick settings on the gear, right
column ⌥⌘B, the agent ⌘J at the far right), hover buttons and "…" menus on rows; ⌘/ lists every
shortcut. The Sessions tab of the left column has three sections: **Open** (every open session;
a folder and the project's name, or a bubble for a chat), **Projects** as a tree (the selected
project expanded with its sessions and "+ New session", ⇧⌘N) and **Chats** (conversations
outside any project, "+ New chat", ⌘N). Projects have sessions, Chats has chats.
The left column switches between Sessions, **Files** (⌘⇧E): the file tree of the
project on screen, with git status, a filter, preview tabs on a single click, a row menu (new,
rename, Trash, reveal, copy path, terminal here) and drag onto a terminal to paste a path, and
**Settings** (⌘, or the gear's "Edit settings files…"): pi's settings files as a tree in three
groups (pi (global), This project, Extensions), opening in editor tabs; credential files never
show; and **Jobs**: Atlas's scheduled jobs (docs/ATLAS.md), notes in the main folder's `jobs/` that
start a fresh `pi --mode json` on a schedule while pi-desk is open. Each row shows its status, next
run, last result and unread runs; a note runs as written (no approval step); Run now, Stop, Pause,
Open note, Last report, Open run folder and Delete are on the row and its "…". No jobs exist until
you make one (New job writes a note).

`./build.sh` needs `odin` and `clang` (Xcode command line tools). It does **not** need Zig:
libghostty-vt comes prebuilt from `vendor/libghostty-vt/`. On first run it compiles the sokol
C libraries (into the sokol-odin submodule tree), Clay, the CoreText text backend and stb_truetype (into `build/`).
Clay is compiled from the pinned `vendor/clay/clay.h` into `build/clay-odin/clay.a`, next to a copy
of the submodule's Odin bindings with the macOS `foreign import` pointed at it; `src/` imports
`build/clay-odin` (so `odin test src` and the editor's Odin tooling need one `./build.sh` first).
The submodule's prebuilt macOS `clay.a` targets macOS 15, so it is not used.

Fresh clone: `git submodule update --init` (build.sh does this if sokol-odin is missing).

### Rebuilding libghostty-vt

```sh
# needs Zig 0.17.0 in toolchain/ (gitignored), checksum from ziglang.org/download/index.json
scripts/build-ghostty.sh                # all targets
scripts/build-ghostty.sh aarch64-macos  # one target
```

It builds macOS arm64/x86_64, Linux x86_64/aarch64 (gnu) and Windows x86_64 (gnu) static
libraries, then repacks each archive: debug info stripped (12–22 MB → ~3 MB), member names
reduced to basenames, and Zig's bundled compiler_rt made weak so it links next to the Odin
runtime (otherwise `__udivti3` and others are defined twice). The repack uses LLVM's
objcopy/ar, found next to `clang`. COFF can't be weakened with llvm-objcopy, so the Windows
lib still has strong compiler_rt symbols; Windows linking is untested.

## Contributing

Every user-visible change updates [docs/GUIDE.md](docs/GUIDE.md) in the same branch. `./build.sh
test` checks part of this (`src/docs_test.odin`): every action in `src/actions.odin` (its label
and shortcut) is in GUIDE.md, and every command in `src/command_table.odin` that the user or
agents may send (`who = .User` or `.Anyone`) is in GUIDE.md or [PROTOCOL.md](docs/PROTOCOL.md).
GUIDE.md is built into the binary and copied to `<data dir>/atlas/GUIDE.md` for Atlas
(`src/agent.odin`). If you change Atlas's starter prompt (`ATLAS_PROMPT_STARTER`), add the
previous one to `ATLAS_PROMPT_OLD_STARTERS` so unedited copies are replaced at startup.

## Pinned versions

| Dependency | Version |
|---|---|
| Ghostty (libghostty-vt) | `v1.4.0`, commit `83fb95624b0439ee660c2679b43b38c8b63769cd` (see `vendor/libghostty-vt/VERSION`) |
| Zig (to build libghostty-vt only) | 0.17.0 (Ghostty 1.4.0 requires exactly 0.17.x; 0.16 fails) |
| sokol-odin | `cdef8e58162cd657c453e65cb087b9cb5888adb9` (2026-10-29) |
| Clay | `e6cc36941ab2af5d81107617039d6f527a1c660b` (2026-05-20); `clay.h` compiled by `build.sh` (macOS), its Odin bindings |
| Odin | dev-2026-09 |
| tree-sitter + 13 grammars (editor highlighting) | lib `v0.27.1`; grammars at pinned tags, sources and licences in `vendor/tree-sitter/` (`VERSIONS`; refresh with `scripts/vendor-tree-sitter.sh`); compiled once into `build/ts.a` |

libghostty-vt's C ABI is not stable yet. `src/ghostty/ghostty.odin` is hand-written for v1.4.0.
`./build.sh test` checks struct sizes, offsets and key-enum values against the C headers; rerun it
after bumping the tag.

## Architecture

```
main.odin      sokol app: init / frame / event. Events become commands, keys routed by focus. Redraws only when something changed.
state.odin     State: the one plain, serialisable app state struct (ids, no pointers)
commands.odin  Command union + run_command: the only code that changes State; callers, confirmations
command_table.odin  every command: args, description, who may send it, confirm class, long-running (caller_may, list_commands)
home.odin      the Home session: data dir, cwd
agent.odin     the built-in agent: Home's pi in a terminal (its args: --model, ATLAS.md prompt; unread and notifications from its bridge status; the model it runs)
drawer.odin    the agent's drawer: frame, header (name, status, model, Model, pin, close), resize, its terminal's mouse
inbox.odin     command inbox: any thread submits, the main thread drains; reply slots
events.odin    events (command run, long command finished), command log, own-event filter
socket.odin    control socket: listener, hello + tokens, subscriptions, pi-tab bridge routing
socket_posix.odin  Unix socket + per-user 0700 dir (the OS side of socket.odin)
ctl.odin       `pi-desk --ctl`: tiny socket client for scripts and tests
json_*.odin    hand-written JSON: command parser, encoders for commands/results/events/state (docs/PROTOCOL.md)
platform*.odin what commands may ask of the window layer (clipboard, quit, wake, folder picker); macOS hooks
native/platform_macos.m  macOS: blended title bar, input methods (NSTextInputClient on sokol's view), window drag, appearance (OS light/dark, window)
textfield.odin single-line text field (edit buffer, cursor, selection, word moves, mouse)
actions.odin   user-facing actions (label, shortcut, command builder): what the palette offers, and the labels and shortcuts of buttons
palette.odin   command palette (⌘K): items, fuzzy search and ranking, recents; runs items through the inbox
sidebar.odin   left column model: which projects, chats and sessions show and in what order (pins, sort, filter, hidden, the Open group)
ui_sidebar.odin left column layout and input: filter field, quick filters, sections, context and sort menus, column dividers (and the drawer's left edge)
tabhost.odin   tab protocol sketch (docs/TAB-PROTOCOL.md)
notify.odin    the bell's entries: what happened in sessions the user was not looking at (finished, waiting, error, exited) and jobs' results (notify_post); bounded, coalesced, not saved; notifications_* commands
ui_bell.odin   the bell in the top bar (unread count) and its popover (Today/Earlier, mark all read, clear; an entry focuses its session)
ui_toolbar.odin top bar buttons (each runs an action), search pill, settings popover (the gear), shortcuts sheet (⌘/), tooltips
settings_files.odin settings as files: the left column's Settings tab (⌘,): pi's settings files by an allowlist (settings.json, models.json, AGENTS.md…, prompts/, skills/, extensions/), the project's .pi/ and instructions file (Create when missing), extensions' config files and folders, as a tree drawn by ui_files.odin; credential files never shown or opened; pi's JSON settings saved only when pi can read them; Reload pi sessions after a save
icons.odin     a small vector icon set (lines, rings, dots) drawn with sokol_gl, crisp at any scale
editor*.odin   editor tabs: piece-table buffer (editor_buffer), edits and undo (editor), tree-sitter highlighting (editor_syntax), load/save/disk sync (editor_file), git gutter and diffs (editor_git), watching (editor_watch), drawing, input, toolbar, find bars (editor_view), ⌘P finder (editor_finder), commands (editor_commands)
fs_model.odin  file-system model: listing (gitignore, git status), project files, file commands inside projects
files.odin     the Files tab's model: expanded folders per tree (State), cached listings, flat rows, its commands
jobs*.odin     Atlas's jobs: note parser and report extraction (jobs_note), cron and local time (jobs_cron), the scheduler, records, delivery and commands (jobs), running pi --mode json (jobs_run)
ui_jobs.odin   the Jobs tab: rows, row buttons and "…" menu, limits, the notes-folder prompt
changes.odin   the Changes tab's model: a checkout's uncommitted files and branch commits (git on a worker, debounced), diffs, stage/unstage/discard/commit, changes_* commands; ui_changes.odin its bars, list, "±" button
ui_files.odin  the Files and Settings tabs: Sessions | Files | Settings | Jobs switch, header buttons, filter, virtualised tree, row menu, drag to a terminal
native/editor_macos.m  macOS: FSEvents watcher, Trash, Finder reveal
ui.odin        Clay layout (sidebar, top bar = title bar, confirmation bar, terminal pane, right panel, palette overlay) + drawing, hover/fade motion
theme.odin     design tokens (spacing, type, radii, sizes, motion) and the three looks (graphite, warm, ghostty), dark and light; appearance (system/light/dark)
font.odin      text: font sets (UI, UI small, mono), shaped-run + glyph caches, growing atlas, sokol_gl quads
text_*.odin    text backends: CoreText (macOS, src/native/text_coretext.c), stb_truetype (others); box-drawing sprites
sessions.odin  projects + sessions from ~/.pi/agent/sessions (header cwd); the Chats entry (<data dir>/chats)
titles.odin    session titles by pi's rule: files streamed once, cached by offset (a worker for big ones), saved as <data dir>/session-titles.tsv
term.odin      one terminal: PTY + reader thread + libghostty-vt, drawing, input encoding
pty.odin       PTY interface;  pty_posix.odin = forkpty (macOS, Linux); ConPTY later
ghostty/       Odin bindings for the libghostty-vt calls used
autotest.odin  PI_DESK_SCRIPT test mode
*_test.odin    command-layer tests (odin test src, single-threaded)
```

Data flow per terminal:

```
child (pi / shell) <-> PTY master
   output: reader thread (poll+read) -> inbox -> frame: ghostty_terminal_vt_write
   replies (DA, DSR, kitty query): write_pty callback -> PTY
   draw:   ghostty_render_state_update -> rows/cells -> sokol_gl quads
   input:  sokol events -> ghostty key/mouse/paste/focus encoders -> PTY
```

- **Commands and state.** Clicks, shortcuts, test scripts (and later the control socket) build a
  `Command` that names its target by id (project, open session, tab) and submit it to the inbox.
  The main thread drains the inbox at the start of each frame, after each UI event and when a
  background thread wakes it (GCD main queue on macOS), and runs `run_command`, which returns a
  `Result{ok, error, created_id, pending, confirmation}`, bumps `state.version` only if State
  changed, and calls `emit_event` (command log `<data dir>/commands.log`, redacted, rotated at
  10 MB). Closing a busy tab or quitting with running sessions asks for confirmation (a bar in the
  window). By default only the user confirms; the user can let a caller confirm its own token
  (`trusted`) or skip confirmation (`auto`) per command class. Runtime resources (PTYs, terminals) live outside `State`, in
  `terms`, keyed by tab id. Raw keystrokes and mouse bytes for the focused terminal are forwarded
  directly; agents use `Send_Text`. state/commands never call sokol: clipboard and quit go through
  `platform`. Wire format: [docs/PROTOCOL.md](docs/PROTOCOL.md).
- **Control socket.** pi-desk listens on a Unix socket in a per-user `0700` dir and gives each pi
  tab `PI_DESK_SOCKET` and its own `PI_DESK_TOKEN` (caller `panel`), so the pi-kit bridge can
  report `pi.session`/`pi.status`, publish panels (`panel.set`, drawn in the right column,
  ⌥⌘B toggles it) and receive `pi.prompt`/`pi.reload`/`pi.wait_idle`. For local
  scripts: `build/pi-desk --print-token script DIR` prints one `export PI_DESK_SOCKET=… PI_DESK_TOKEN=…`
  line; then `build/pi-desk --ctl '{"type":"get_state"}'`. See PROTOCOL.md §9.
- **Sessions.** The cwd comes from each session file's header line (directory names are
  lossy). The title follows `pi --resume`: the latest `session_info` name anywhere in the file,
  otherwise the first user message with text; then a `/goal` objective, else "Untitled session ·
  <created>". Each file is read once and then only what pi appended (titles.odin). Clicking a session runs `pi --session <file>` in that cwd (or focuses
  it if it is already open: sessions are identified by pi's session id); "+ New session" (and "+ New chat") runs
  `pi --session-id <uuid>` with a UUID pi-desk picks. Both go through `$SHELL -l -c` so pi is found on the user's PATH.
- **Tabs.** `Tab_Kind` is a union (`Pi_Tab`, `Shell_Tab`, `Editor_Tab`, `Markdown_Tab`, browser and app tabs, …).
  A Markdown tab is a read-only editor (source, find, disk reload) plus a preview laid out by
  `src/markdown_view.odin` from our own parser (`src/markdown.odin`, `src/markdown_inline.odin`).
  Each open session has one pi tab (index 0) plus shell tabs (`+ shell`, Cmd+T,
  Cmd+W, Cmd+1..9). Every tab owns its own PTY and libghostty-vt instance. Sessions you switch
  away from keep running, and their output is still read in the background.
- **Child environment.** The child gets `TERM=xterm-256color`, `COLORTERM=truecolor` and
  `TERM_PROGRAM=pi-desk`. The identity variables of whatever terminal launched pi-desk are
  removed.
- **Keys.** Printable keys travel as text from the CHAR event (correct for any layout).
  Ctrl/Alt combinations and special keys are encoded from KEY_DOWN. Option acts as Alt
  (pi's Alt+Enter), so Option+letter sends ESC+letter, not a special character. The macOS
  line-editing keys are Ghostty's defaults (`mac_key_text` in term.odin): ⌘⌫ Ctrl-U, ⌘← Ctrl-A,
  ⌘→ Ctrl-E, ⌥← ESC b, ⌥→ ESC f; ⌥⌦ ESC d is ours; ⌥⌫ is ESC DEL from the encoder. ⌘K stays
  the palette (Ghostty's clear screen is not bound).
- **Mouse.** When the app tracks the mouse (pi does), clicks, drags (with their button) and
  the wheel are reported to it. Shift+drag selects text instead. Otherwise a drag selects,
  drawn as it moves, and scrolls back past the top or bottom edge; double-click a word,
  triple-click a line, Shift+click extends, a click clears; Cmd+C copies.

## Test mode

> **Scenes that run real pi cost money.** `tests/scripts/bridge-e2e.sh`, `tests/scripts/home-e2e.sh`,
> `tests/scripts/text-pi.sh` and `LOOKS_PI=real tests/scripts/looks.sh` start your real pi with your
> own model credentials and send it prompts (short ones, on a cheap model, but billed). Every other
> scene uses a fake HOME and a fake pi, never touches your data and needs no network. CI runs only
> the fake ones.

`PI_DESK_SCRIPT=file build/pi-desk DIR` plays a script of synthetic events through the normal
event handler. The commands are listed at the top of `src/autotest.odin`. While a script runs,
real keyboard and mouse input is ignored. Test mode is quiet by default, so scenes can run while
someone uses the Mac: the app never activates (no Dock icon, never frontmost or key) and its window
sits behind the desktop picture, ignoring the mouse. It is still on a display, so frames, idle-CPU
numbers and screenshots work as usual (the traffic lights are drawn inactive). `PI_DESK_QUIET=0`
shows the window to watch a run; `frame-pause.txt` (minimize/restore) needs it, and the window
animates into the Dock otherwise. The `shot` command raises the window without taking
focus and captures only this window into `build/shots/` (not committed). Scripts submit JSON commands through the inbox
(`command {"type":"close_tab","tab_id":$tab}`) and check `assert_state PATH VALUE` /
`assert_result PATH VALUE`; the app exits 1 if an assert failed. `tests/scripts/run.sh SCRIPT` runs
a script against a fake HOME and a fake pi (`tests/scripts/phase05.txt`: new chat, reopen,
rename, confirmations, layout; `term.txt`: the selection mid-drag, drags reported to an app, the macOS line-editing keys (`build/shots/term/`); `frame-pause.txt`: frame rate while minimised, wake from a thread).
`tests/scripts/panels.sh` plays a fake pi-kit bridge (`fake-bridge.sh`, over `pi-desk --ctl`) per tab:
panels, folding, the toggle and status dots; `tests/scripts/bridge-e2e.sh`
does the same with real pi and the pi-kit bridge it loads (two short prompts: a background shell and todos).
`tests/scripts/run.sh tests/scripts/home.txt`: the agent's drawer (⌘J, ⌘W, Esc, button, palette, the
Model key), and closing sessions from their row and the palette; `tests/scripts/agent.sh` drives the
drawer with a fake Atlas pi (`fake-atlas.py`: a pi-like screen and a bridge; the model and prompt it
got, the Model key, unread, a dialog's tint, pin, the Settings tab's Atlas group, "edit prompt"), and
`agent.sh tests/scripts/drawer-resize.txt` drags the drawer's left edge sliding over and pinned;
`tests/scripts/home-e2e.sh` runs the agent as a real pi with the setting's model and its prompt
(two short prompts: its name, then the projects with desk_state). The agent's sessions in test mode
live in `build/test-data/home`, its prompt in `build/test-data/atlas/ATLAS.md`.
With `PI_DESK_QUIET=0` test mode hands focus back at its first step; it logs to `build/test-data/`.
`tests/scripts/sidebar.sh`: the left column (add a project with "+" and by drop, a new session in it, Chats, ⌘N and ⇧⌘N, the project tree,
the Open group, pin, sort, filter, hide, context menus, column dividers, idle CPU), then a relaunch
that checks pins, sort, hidden items and widths came back (fake store and pi; shots in `build/shots/sidebar/`).
`tests/scripts/projects.sh`: the Projects tree (a fake home shaped like a real one: repositories,
an `_scratch` group row, nested rows, sessions resumed in their own folder, temp and missing
folders hidden), then a relaunch that checks the opened rows came back (`build/shots/projects/`).
To see the tree your own store would give (paths only; reads just the `cwd` of each folder's
newest session header): `python3 -I scripts/tree-dryrun.py > /tmp/store.tsv`, then
`PI_DESK_TREE_DRYRUN=/tmp/store.tsv odin test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.tree_dryrun`.
`tests/scripts/settings.sh`: ⌘, and the gear list the settings files (credential files absent), settings.json opens in an editor tab, invalid JSON is not saved, a valid save offers to reload pi, auth.json never opens; a dummy secret never drawn or logged.
`tests/scripts/bell.sh`: the bell with a fake bridge per session (`fake-bridge-bell.py`: working → idle,
working → waiting): entries only for sessions not on screen, the OS notification stub, focus and
a click read them, the gear's "Notify me about" toggles, narrow widths, light and dark, idle CPU
(shots in `build/shots/bell/`; `window back|front` plays the window going behind and coming back).
`tests/scripts/buttons.sh`: every button clicked (toolbar, "+" menu, tab close, settings popover
rows, shortcuts sheet, row "…"), tooltips from the action table, idle CPU with a tooltip showing.
`tests/scripts/shots.sh` (`OUT=name`): screenshots of the chrome (left column, editor and Files
tabs, settings popover, narrow window; dark and light) into `build/shots/$OUT/`, using only commands
and keys, so the same scene runs against an older build for before/after pairs. The layout audit
(`src/layout_audit_test.odin`, in `./build.sh test`) checks that no text or icon overlaps another or
leaves its row, bar or column, at 800–2000 px, every look, light and dark.
`tests/scripts/restore.sh`: open sessions and shells, quit through the confirm flow, relaunch with
the same temp data dir and check the workspace came back (fake pi; also a 20-session launch).
Test mode saves and restores the workspace only with an explicit `PI_DESK_DATA_DIR`.
`tests/scripts/persist-cpu.sh`: CPU and save checks while a fake bridge reports status every second.
`tests/scripts/setup.sh`: the first-run sheet (`PI_DESK_FIRST_RUN=1`) against a fake HOME whose
`~/.pi/agent/AGENTS.md` names a fake vault: the vault is found, separate chats, Done makes only the
missing subfolders, a job draft lands in its `jobs/`, a new chat gets `PI_KIT_NOTES_DIR`, the gear and
the menu bar reopen it; a second start shows no sheet and the user's own `PI_KIT_NOTES_DIR` wins.
`tests/scripts/editor.sh`: the editor (fake HOME with a git project): open, type, undo, save by
key and toolbar, the right-click menu, a shell changing the file (clean → reloaded, unsaved →
banner → Reload), a dirty close, a 50k-line file and idle CPU; then a relaunch that checks the
editor tabs came back. Timings: `odin test src -o:speed -define:ODIN_TEST_NAMES=main.editor_perf_50k`.
`tests/scripts/files.sh`: the Files tab (fake HOME with a git project: modified, untracked and
ignored files, a 10k-file folder): expand, preview then keep, keyboard, new file, inline rename,
delete through the confirmation bar (test mode trashes into `build/test-trash`), the row menu, a
terminal opened in a folder, an outside change, drag onto a terminal, reveal of the active file,
filter, light/dark, layout time while scrolling the 10k folder, idle CPU; then a relaunch that
checks the tab and its open folders came back.
`tests/scripts/markdown.sh`: the Markdown tab (fake HOME with a project of `.md` files): open, a second open
focusing the same tab, preview/source toggle (toolbar and ⇧⌘V), find, a live reload after the file changes, a relative link
and an anchor, an external link (test mode logs it, opens nothing), the mermaid placeholder, the
guide, light/dark at four widths and idle CPU. Parser tests and the 1 MB timing: `src/markdown_test.odin`.
`tests/scripts/jobs.sh`: Atlas's jobs (docs/ATLAS.md §9 step 1) with a fake `pi --mode json`
(`tests/scripts/fake-pi-json.py`), a fake HOME and notes folder: the Jobs tab, Run now and every
outcome (ok, needs_you with the blocked action, over_limit, looping, stalled, failed ×3 → paused,
folder_missing), late, overlapping and `at` ticks, a daily limit, an edited note running as
edited, a script's job running on its schedule (no approval), no Keychain code, Delete, Pause all, limits, redaction, the run environment, the
ATLAS.md copy, idle CPU (shots in `build/shots/jobs/`).
`tests/scripts/worktrees.sh`: the Files tab's checkout switcher (fake HOME with a git project and
its worktrees: merged and clean, dirty and ahead, detached, folder gone; branches without one): the
menu and its state, picking a worktree, a terminal and a pi session in one, Clean up through the
confirmation bar, light and dark, idle CPU; then a relaunch that checks the worktree session and
the tree's checkout came back (shots in `build/shots/worktrees/`).
`PI_DESK_LOG_COMMANDS=1` prints every event as it happens. `PI_DESK_CMD="..."` replaces pi with any
command (it gets pi's arguments as `"$@"`), for benchmarks and tests. `PI_DESK_DATA_DIR` moves the
data dir. `pi-desk --fresh` starts without restoring the saved workspace
(`<data dir>/workspace.json`, [docs/PERSISTENCE.md](docs/PERSISTENCE.md)); the old file is kept as
`workspace.json.bak-<time>`.

Scripts that take screenshots (`shot NAME`) write them to `build/shots/` (not committed); the
three looks in dark and light: `tests/scripts/looks.sh` (fake store, fake pi);
`LOOKS_PI=real tests/scripts/looks.sh` checks that real pi re-themes on a switch (cheap model, one
short prompt).

## Looks

`set_theme {"name": "graphite" | "warm" | "ghostty"}` switches the look live; `set_reduce_motion
{"on": true}` turns off fades and the running pulse. Every size, colour and timing the chrome uses is
a token in `src/theme.odin`; `ui.odin` has no raw numbers or colours. A look also sets the terminals'
default foreground, background, cursor and palette through libghostty-vt, so pi's TUI blends with the
chrome; `ghostty` is Ghostty 1.4.0's defaults (sources cited in theme.odin). Motion redraws only while
something moves: idle stays idle.

Each look has a dark and a light variant. `set_appearance {"mode": "system" | "light" | "dark"}`
picks one, independent of the look (palette: "Appearance: …"; saved). `system`, the default,
follows macOS live: the platform layer observes `NSApp.effectiveAppearance` (KVO, no polling). The
window's own appearance (title bar, traffic lights, folder picker) follows the setting. On every
change of the terminals' default colours, a program that enabled mode 2031 gets the colour-scheme
report `CSI ? 997 ; 1|2 n` (as Ghostty sends it) and `CSI ? 996 n` is answered; pi enables 2031 when
its theme follows the terminal (`system` or a `light/dark` pair, e.g. `pi --use-theme system`) and
then queries the colours again (OSC 10/11/4). With a fixed pi theme (`"theme": "dark"`) pi keeps its
colours. Light terminals derive the 256-colour cube and grey ramp from the look's colours (Ghostty's
`palette-generate`), so a program's bright 256-colour green is still readable on white.
