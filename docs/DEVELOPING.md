# Developing pi-desk

This is the developer's companion to the [README](../README.md) and the [user guide](GUIDE.md):
how to build pi-desk, how the code is laid out, how the test scenes work and how a release is
made. The wire protocol has its own document, [PROTOCOL.md](PROTOCOL.md).

## Contents

1. [Requirements](#requirements)
2. [Building and running](#building-and-running)
3. [Rebuilding libghostty-vt](#rebuilding-libghostty-vt)
4. [Pinned versions](#pinned-versions)
5. [Releases](#releases) (and [update signing](#update-signing))
6. [Contributing](#contributing)
7. [Architecture](#architecture)
8. [Looks](#looks)
9. [Test mode and scenes](#test-mode-and-scenes)

## Requirements

You need macOS 14 or later on Apple silicon (arm64), [Odin](https://odin-lang.org/) `dev-2026-09`,
and `clang` from the Xcode command line tools. Intel Macs can build pi-desk too, but without the
browser tab, because CEF is wired up for arm64 only. To run what you build you need
[pi](https://github.com/earendil-works) on your login shell's `PATH`, and optionally
[pi-kit](https://github.com/McFalljb/pi-kit) for the bridge and the agent tools (see the README).

The build does **not** need Zig: libghostty-vt comes prebuilt from `vendor/libghostty-vt/`. Zig is
only needed to [rebuild that library](#rebuilding-libghostty-vt).

## Building and running

```sh
git clone --recursive https://github.com/McFalljb/pi-desk.git
cd pi-desk
./build.sh            # release build -> build/pi-desk (first build downloads CEF, ~135 MB)
./build.sh run        # build and run
./build.sh test       # binding tests (ABI sizes vs C, encoders, render state) + command-layer tests
build/pi-desk [DIR]   # optional DIR: open a new pi chat there on start
```

In a clone made without `--recursive`, run `git submodule update --init` (`build.sh` does this
itself when sokol-odin is missing).

`./build.sh` fetches the pinned [CEF](https://bitbucket.org/chromiumembedded/cef) build
(`vendor/cef/VERSION`) with `scripts/fetch-cef.sh`, checks its checksum, keeps it in
`~/Library/Caches/pi-desk/cef`, and lays out `build/pi-desk.app` around it. `build/pi-desk` is a
small wrapper that runs the bundle's binary directly, so arguments, the environment and stdio pass
through. `PI_DESK_NO_CEF=1 ./build.sh` builds without the browser tab and without the download.

On its first run `build.sh` also compiles the sokol C libraries (into the sokol-odin submodule
tree), Clay, the CoreText text backend and stb_truetype (into `build/`). Clay is compiled from the
pinned `vendor/clay/clay.h` into `build/clay-odin/clay.a`, next to a copy of the submodule's Odin
bindings whose macOS `foreign import` points at it. `src/` imports `build/clay-odin`, so
`odin test src` and the editor's Odin tooling need one `./build.sh` first. The submodule's own
prebuilt macOS `clay.a` targets macOS 15, which is why it is not used.

The minimum macOS is 14.0 (Sonoma). `build.sh` sets `MACOS_MIN` and enforces it twice. Before
linking, `scripts/check-minos.sh` reads the minimum macOS of every native library Odin links (each
archive member, from `otool -l`); after bundling it checks every Mach-O file in `pi-desk.app`,
including the CEF framework and the helpers. Anything newer than `MACOS_MIN` fails the build.
pi-desk has not yet been run on a real macOS 14 machine.

## Rebuilding libghostty-vt

```sh
# needs Zig 0.17.0 in toolchain/ (gitignored), checksum from ziglang.org/download/index.json
scripts/build-ghostty.sh                # all targets
scripts/build-ghostty.sh aarch64-macos  # one target
```

The script builds static libraries for macOS arm64 and x86_64, Linux x86_64 and aarch64 (gnu) and
Windows x86_64 (gnu), then repacks each archive. The repack strips debug info (12–22 MB down to
about 3 MB), reduces member names to basenames, and makes Zig's bundled compiler_rt weak so it
links next to the Odin runtime (otherwise `__udivti3` and others are defined twice). It uses
LLVM's objcopy and ar, found next to `clang`. COFF symbols can't be weakened with llvm-objcopy, so
the Windows library still has strong compiler_rt symbols; Windows linking is untested.

## Pinned versions

| Dependency | Version |
|---|---|
| Ghostty (libghostty-vt) | `v1.4.0`, commit `83fb95624b0439ee660c2679b43b38c8b63769cd` (see `vendor/libghostty-vt/VERSION`) |
| Zig (to build libghostty-vt only) | 0.17.0 (Ghostty 1.4.0 requires exactly 0.17.x; 0.16 fails) |
| sokol-odin | `cdef8e58162cd657c453e65cb087b9cb5888adb9` (2026-10-29) |
| Clay | `e6cc36941ab2af5d81107617039d6f527a1c660b` (2026-05-20); `clay.h` compiled by `build.sh` (macOS), its Odin bindings |
| Odin | dev-2026-09 |
| CEF | `vendor/cef/VERSION` |
| tree-sitter + 13 grammars (editor highlighting) | lib `v0.27.1`; grammars at pinned tags, sources and licences in `vendor/tree-sitter/` (`VERSIONS`; refresh with `scripts/vendor-tree-sitter.sh`); compiled once into `build/ts.a` |

libghostty-vt's C ABI is not stable yet, and `src/ghostty/ghostty.odin` is hand-written for
v1.4.0. `./build.sh test` checks struct sizes, offsets and key-enum values against the C headers,
so rerun it after bumping the tag.

## Releases

Releases are built and signed on the release signer's Mac, in one command:
`scripts/release.sh --version X.Y.Z`. CI (`ci.yml`, `scenes-full.yml`) tests every push but
builds no releases. The script refuses, before it builds anything, unless the worktree is clean
(no changes, no untracked files), HEAD is exactly the tag `vX.Y.Z`, `UPDATE_PUBLIC_KEY` is a
real key and the key file's public half is that key. Then it runs `./build.sh test` and
`./build.sh` (with CEF), checks that the app holds `UPDATE_PUBLIC_KEY` and not the test key,
writes the version into every `Info.plist`, code-signs (ad hoc, or Developer ID and notarized
when `MACOS_CERT_P12` and the rest are set), zips, unpacks the zip again to check its signature
and CDHash against the built app, writes the `.sha256` and the updater's `.sig` from that
bundle, and drafts the GitHub Release with `gh` (`--verify-tag`: the tag must already be pushed;
a re-run replaces a draft's files but never a published release's). Last, it downloads the
draft's `.sig` again and verifies it against the local zip. You check the draft and publish it.

Each release:

1. Commit everything, then `git tag vX.Y.Z` at that commit and `git push origin vX.Y.Z`.
2. `scripts/release.sh --version X.Y.Z` (or first `--no-upload`, a dry run into `dist/` with no
   GitHub calls, then `--upload-only` to draft what it left there, checked again).
3. Open the draft on GitHub, check the notes and the three files, publish it.

A release carries `pi-desk-<version>-macos-arm64.zip`, its `.sha256` and its `.sig` (below). Unless a release says
it is notarized, the app is signed ad hoc rather than with an Apple Developer ID, so Gatekeeper
refuses the first open (the README says how to get past that). The app is about 340 MB, mostly
Chromium for the browser tab. The bundle carries the third-party licences in
`Contents/Resources/licenses/`.

### Update signing

pi-desk updates itself from GitHub releases (GUIDE.md, "Updates"; `src/update.odin`). The trust
anchor is an Ed25519 key of its own, not GitHub or the TLS connection: an update installs only
when its `.sig` verifies under the public key compiled into the app (`UPDATE_PUBLIC_KEY` in
`src/update_key.odin`). **The private key lives only on the release signer's Mac**, never in
GitHub (no secret, no CI step), and `scripts/release.sh` signs only the bundle it has just
built there, never anything downloaded.

- **What is signed.** Not the zip's bytes directly but a short manifest
  (`src/updatesig/updatesig.odin`):
  `pi-desk update v2\nversion X.Y.Z\nfile pi-desk-X.Y.Z-macos-arm64.zip\nsize N\nsha256 HEX\ncdhash HEX\n`.
  The CDHash is the app's main executable code directory hash (`codesign -dvvv`'s `CDHash=`),
  which covers `Info.plist` and the resource seal and so every file in the bundle. A signature
  is thus bound to one version (an old signed zip cannot be served as a newer release) and to
  the exact app inside: pi-desk checks the CDHash again on the unpacked copy, on the staged copy
  next to the running app, and right before it renames that copy into place. The `.sig` is
  three lines: `pi-desk-update-sig v2`, `cdhash HEX`, `signature BASE64`. Pre-releases
  (`X.Y.Z-suffix`) are never offered and are not signed.
- **The tool.** `odin build tools/update-sign -out:build/update-sign`, then
  `update-sign keygen FILE` (a new key: the base64 32-byte seed into FILE, created `0600`,
  never overwritten; prints only the public key), `pubkey KEYFILE`,
  `sign KEYFILE VERSION ZIP CDHASH SIG`, `verify PUBKEY VERSION ZIP SIG` and
  `manifest VERSION ZIP CDHASH`. It reads the private key only from KEYFILE, never from the
  environment, and never prints it. KEYFILE is opened without following a link and must be a
  regular file you own with mode `600` or `400`, in a folder that neither group nor others can
  write. `scripts/release.sh` takes it from `--key FILE`, `$PI_DESK_UPDATE_KEY_FILE` or, by
  default, `~/.config/pi-desk/update.key`.
- **Signing a release** is part of `scripts/release.sh` ("Releases" above): the CDHash comes
  from the app it has just built and zipped, and the `.sig` goes up with the zip.
- **Setting it up** (once): `mkdir -p ~/.config/pi-desk && chmod 700 ~/.config/pi-desk`,
  `build/update-sign keygen ~/.config/pi-desk/update.key`, put the printed public key into
  `UPDATE_PUBLIC_KEY` and commit. Back the key file up offline (an encrypted USB stick or a
  password manager's secure file), not in iCloud Drive or a repository. Copies of pi-desk built
  before this key exist cannot update themselves (install the first keyed release by hand).
- **Backups.** An update keeps the replaced app next to it as `pi-desk.app.old-<version>` (rolled
  back to if the swap fails) and removes it at the second start after the update, whatever
  version is running then (also after a downgrade by hand).
- **Losing the key** means installed copies can no longer be updated automatically: ship a new
  key in a release that users install by hand. Keep the backup.
- **Rotating it.** Generate a new key, ship a release whose `UPDATE_PUBLIC_KEY` is the new
  public key **signed with the old key** (installed copies only trust the old one), then sign
  the releases after it with the new key. `scripts/release.sh` refuses a key that does not
  match the checkout's `UPDATE_PUBLIC_KEY`; for the bridge release say so:
  `scripts/release.sh --version X.Y.Z --key OLDFILE --rotating-from OLDPUB`. If the
  old key leaked, that bridge release is the risk window: publish it quickly and tell users of
  older copies to update by hand from the releases page.
- **Tests** use a throwaway key, `tests/update/test-key.txt`, public on purpose. Its public half
  (`UPDATE_TEST_PUBLIC_KEY`) and test mode's update fixtures (`PI_DESK_UPDATE_URL` and the rest)
  are compiled in only with `-define:PI_DESK_UPDATE_TEST=true` (`./build.sh test`'s unit tests
  and the update scene's own binary). `tests/scripts/update.sh` plays the whole flow from
  `file://` fixtures into a fake install folder; `tests/scripts/release-checks.sh` checks the
  key-file rules and `release.sh`'s refusals against a fake `gh`.

## Contributing

Every user-visible change updates [GUIDE.md](GUIDE.md) in the same branch. `./build.sh test`
checks part of this in `src/docs_test.odin`: every action in `src/actions.odin` (its label and
shortcut) must appear in GUIDE.md, and every command in `src/command_table.odin` that the user or
agents may send (`who = .User` or `.Anyone`) must appear in GUIDE.md or
[PROTOCOL.md](PROTOCOL.md).

GUIDE.md is built into the binary and copied to `<data dir>/atlas/GUIDE.md` for Atlas
(`src/agent.odin`). If you change Atlas's starter prompt (`ATLAS_PROMPT_STARTER`), add the
previous one to `ATLAS_PROMPT_OLD_STARTERS` so that unedited copies are replaced at startup.

## Architecture

pi-desk is written in **Odin** with **Clay** for layout, **sokol** for the window and the GPU
(Metal, GL or D3D), **libghostty-vt** for terminal emulation and **CEF** for browser tabs. It
targets macOS for now, but the platform-specific pieces (the PTY, fonts, test hooks) sit behind
small files so that Linux and Windows can follow.

### Source map

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
ui_setup.odin  the first-run sheet (main folder); folders.odin: the main folder's subfolders and their overrides
tabhost.odin   tab protocol sketch (docs/TAB-PROTOCOL.md)
update*.odin   pi-desk's own updates: the check (curl to GitHub's API), the offer, download and checks (update_core: versions, release JSON, where it may install, the unpacked bundle; updatesig/: the Ed25519 manifest signatures), the swap and relaunch; ui_update.odin the bar; update_key.odin the public key
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

Atlas's prompt is `ATLAS.md` in the main folder's `atlas/` (setting `home_dir`, chosen in the
first-run sheet). It is copied there from the data dir once, and the data dir's copy stays as the
fallback. Each subfolder of the main folder may be overridden (`src/folders.odin`, the Settings
tab's Folders group). The drawer's Model button opens pi's model selector and saves the choice as
the setting `agent_model`.

### Data flow per terminal

```
child (pi / shell) <-> PTY master
   output: reader thread (poll+read) -> inbox -> frame: ghostty_terminal_vt_write
   replies (DA, DSR, kitty query): write_pty callback -> PTY
   draw:   ghostty_render_state_update -> rows/cells -> sokol_gl quads
   input:  sokol events -> ghostty key/mouse/paste/focus encoders -> PTY
```

### Commands and state

Clicks, shortcuts, test scripts and the control socket all build a `Command` that names its target
by id (a project, an open session or a tab) and submit it to the inbox. The main thread drains the
inbox at the start of each frame, after each UI event, and whenever a background thread wakes it
(through the GCD main queue on macOS). It runs `run_command`, which returns a
`Result{ok, error, created_id, pending, confirmation}`, bumps `state.version` only if State
changed, and calls `emit_event`. Events go to the command log, `<data dir>/commands.log`, which is
redacted and rotated at 10 MB. The wire format is in [PROTOCOL.md](PROTOCOL.md).

Closing a busy tab or quitting with running sessions asks for confirmation in a bar in the window.
By default only the user confirms, but the user can let a caller confirm with its own token
(`trusted`) or skip confirmation (`auto`) per command class.

Runtime resources such as PTYs and terminals live outside `State`, in `terms`, keyed by tab id.
Raw keystrokes and mouse bytes for the focused terminal are forwarded directly, while agents use
`Send_Text`. The state and command code never calls sokol; clipboard and quit go through
`platform`.

### The control socket

pi-desk listens on a Unix socket in a per-user `0700` directory and gives each pi tab
`PI_DESK_SOCKET` and its own `PI_DESK_TOKEN` (caller `panel`). With these the pi-kit bridge reports
`pi.session` and `pi.status`, publishes panels with `panel.set` (drawn in the right column, which
⌥⌘B toggles) and receives `pi.prompt`, `pi.reload` and `pi.wait_idle`. Atlas drives the app through
the same socket with pi-kit's `desk` tools (PROTOCOL.md §8).

For local scripts, `build/pi-desk --print-token script DIR` prints one
`export PI_DESK_SOCKET=… PI_DESK_TOKEN=…` line, after which `build/pi-desk --ctl '{"type":"get_state"}'`
talks to the running app. See PROTOCOL.md §9.

### Sessions

A session's cwd comes from the header line of its session file, because pi's directory names are
lossy. Its title follows `pi --resume`: the latest `session_info` name anywhere in the file,
otherwise the first user message with text, then a `/goal` objective, and otherwise
"Untitled session · <created>". Each file is read once, and after that only what pi appended
(`titles.odin`).

Clicking a session runs `pi --session <file>` in its cwd, or focuses it if it is already open
(sessions are identified by pi's session id). "+ New session" and "+ New chat" run
`pi --session-id <uuid>` with a UUID that pi-desk picks. Both go through `$SHELL -l -c`, so pi is
found on the user's `PATH`.

### Tabs

`Tab_Kind` is a union (`Pi_Tab`, `Shell_Tab`, `Editor_Tab`, `Markdown_Tab`, browser and app tabs,
and so on). Each open session has one pi tab at index 0 plus any other tabs. Every terminal tab
owns its own PTY and libghostty-vt instance. Sessions you switch away from keep running, and their
output is still read in the background. A Markdown tab is a read-only editor (source, find, disk
reload) plus a preview laid out by `src/markdown_view.odin` from pi-desk's own parser
(`src/markdown.odin`, `src/markdown_inline.odin`). Browser tabs are described in
[BROWSER.md](BROWSER.md), and the tab protocol sketch in [TAB-PROTOCOL.md](TAB-PROTOCOL.md).

### Terminals

The child process gets `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=pi-desk`,
and the identity variables of whatever terminal launched pi-desk are removed.

Printable keys travel as text from the CHAR event, which is correct for any keyboard layout.
Ctrl and Alt combinations and special keys are encoded from KEY_DOWN. Option acts as Alt (for pi's
Alt+Enter), so Option+letter sends ESC+letter rather than a special character. The macOS
line-editing keys are Ghostty's defaults (`mac_key_text` in `term.odin`): ⌘⌫ sends Ctrl-U, ⌘←
Ctrl-A, ⌘→ Ctrl-E, ⌥← ESC b and ⌥→ ESC f. ⌥⌦ (ESC d) is pi-desk's own addition, and ⌥⌫ is ESC DEL
from the encoder. ⌘K stays the palette, so Ghostty's clear-screen binding is not used.

When the program in the terminal tracks the mouse (pi does), clicks, drags (with their button) and
the wheel are reported to it, and Shift+drag selects text instead. Otherwise a drag selects, drawn
as it moves, and scrolls back past the top or bottom edge. Double-click selects a word, triple-click
a line, Shift+click extends the selection, a click clears it, and ⌘C copies.

## Looks

`set_theme {"name": "graphite" | "warm" | "ghostty"}` switches the look live, and
`set_reduce_motion {"on": true}` turns off fades and the running pulse. Every size, colour and
timing the chrome uses is a token in `src/theme.odin`, so `ui.odin` has no raw numbers or colours.
A look also sets the terminals' default foreground, background, cursor and palette through
libghostty-vt, so pi's TUI blends with the chrome; `ghostty` is Ghostty 1.4.0's defaults (the
sources are cited in `theme.odin`). Motion redraws only while something moves, so an idle app
stays idle.

Each look has a dark and a light variant. `set_appearance {"mode": "system" | "light" | "dark"}`
picks one independently of the look (palette: "Appearance: …"; saved). The default, `system`,
follows macOS live: the platform layer observes `NSApp.effectiveAppearance` through KVO, without
polling. The window's own appearance (title bar, traffic lights, folder picker) follows the
setting.

Whenever the terminals' default colours change, a program that enabled mode 2031 gets the
colour-scheme report `CSI ? 997 ; 1|2 n` (as Ghostty sends it), and `CSI ? 996 n` is answered. pi
enables 2031 when its theme follows the terminal (`system` or a `light/dark` pair, for example
`pi --use-theme system`) and then queries the colours again (OSC 10/11/4). With a fixed pi theme
(`"theme": "dark"`) pi keeps its colours. Light terminals derive the 256-colour cube and grey ramp
from the look's colours (Ghostty's `palette-generate`), so a program's bright 256-colour green is
still readable on white.

## Test mode and scenes

> **Scenes that run real pi cost money.** `tests/scripts/bridge-e2e.sh`, `tests/scripts/home-e2e.sh`,
> `tests/scripts/text-pi.sh` and `LOOKS_PI=real tests/scripts/looks.sh` start your real pi with your
> own model credentials and send it prompts (short ones, on a cheap model, but billed). Every other
> scene uses a fake HOME and a fake pi, never touches your data and needs no network. CI runs only
> the fake ones.

CI runs in two workflows. `ci.yml` runs on every push to main and every pull request (not for
changes to Markdown and docs alone): the unit tests in one job and the required scenes split
across three parallel jobs, so a run takes a few minutes. `scenes-full.yml` runs every scene,
including those not required yet, nightly and on demand (**Actions › Scenes (full) › Run
workflow**). A scene moves into `ci.yml` once it has passed there a few times.

### How test mode works

`PI_DESK_SCRIPT=file build/pi-desk DIR` plays a script of synthetic events through the normal event
handler; the script commands are listed at the top of `src/autotest.odin`. Scripts submit JSON
commands through the inbox (`command {"type":"close_tab","tab_id":$tab}`) and check results with
`assert_state PATH VALUE` and `assert_result PATH VALUE`. The app exits with status 1 if an assert
failed. While a script runs, real keyboard and mouse input is ignored.

Test mode is quiet by default, so scenes can run while someone uses the Mac. The app never
activates (no Dock icon, never frontmost or key), and its window sits behind the desktop picture
and ignores the mouse. It is still on a display, so frames, idle-CPU numbers and screenshots work
as usual, with the traffic lights drawn inactive. `PI_DESK_QUIET=0` shows the window so you can
watch a run; in that mode test mode hands focus back at its first step. `frame-pause.txt`
(minimize and restore) needs it, because otherwise the window animates into the Dock.

The `shot NAME` command raises the window without taking focus and captures only this window into
`build/shots/NAME.png` (not committed). Test mode logs to `build/test-data/`. The agent's sessions
in test mode live in `build/test-data/home` and its prompt in `build/test-data/atlas/ATLAS.md`.
Test mode saves and restores the workspace only when `PI_DESK_DATA_DIR` is set explicitly.

Other environment variables help with tests and benchmarks. `PI_DESK_LOG_COMMANDS=1` prints every
event as it happens. `PI_DESK_CMD="..."` replaces pi with any command, which gets pi's arguments as
`"$@"`. `PI_DESK_DATA_DIR` moves the data dir. `pi-desk --fresh` starts without restoring the
saved workspace (`<data dir>/workspace.json`, see [PERSISTENCE.md](PERSISTENCE.md)) and keeps the
old file as `workspace.json.bak-<time>`.

### The scenes

`tests/scripts/run.sh SCRIPT` runs any script against a fake HOME and a fake pi. The other scenes
have their own shell scripts in `tests/scripts/`, each setting up a fake HOME shaped for what it
tests. Unless noted, they use a fake pi and write their screenshots to `build/shots/<scene>/`.

- **`run.sh phase05.txt`**: a new chat, reopen, rename, confirmations, layout.
- **`run.sh term.txt`**: the selection mid-drag, drags reported to an app, the macOS line-editing
  keys (`build/shots/term/`).
- **`run.sh frame-pause.txt`**: the frame rate while minimised and waking from a thread.
- **`run.sh home.txt`**: the agent's drawer (⌘J, ⌘W, Esc, its button, the palette, the Model key)
  and closing sessions from their row and the palette.
- **`panels.sh`**: a fake pi-kit bridge per tab (`fake-bridge.sh`, over `pi-desk --ctl`) for
  panels, folding, the toggle and status dots.
- **`bridge-e2e.sh`** (real pi, billed): the same with real pi and the pi-kit bridge it loads,
  using two short prompts (a background shell and todos).
- **`agent.sh`**: the drawer with a fake Atlas pi (`fake-atlas.py`, a pi-like screen and a
  bridge): the model and prompt it got, the Model key, unread, a dialog's tint, pin, the Settings
  tab's Atlas group and "edit prompt". `agent.sh tests/scripts/drawer-resize.txt` drags the
  drawer's left edge, both sliding over and pinned.
- **`home-e2e.sh`** (real pi, billed): the agent as a real pi with the setting's model and its
  prompt, using two short prompts (its name, then the projects with `desk_state`).
- **`sidebar.sh`**: the left column (adding a project with "+" and by drop, a new session in it,
  Chats, ⌘N and ⇧⌘N, the project tree, the Open group, pin, sort, filter, hide, context menus,
  column dividers, idle CPU), then a relaunch that checks pins, sort, hidden items and widths came
  back (fake store and pi).
- **`projects.sh`**: the Projects tree against a fake home shaped like a real one (repositories,
  an `_scratch` group row, nested rows, sessions resumed in their own folder, temp and missing
  folders hidden), then a relaunch that checks the opened rows came back.
- **`settings.sh`**: ⌘, and the gear list the settings files with credential files absent;
  settings.json opens in an editor tab, invalid JSON is not saved, a valid save offers to reload pi,
  auth.json never opens, and a dummy secret is never drawn or logged.
- **`bell.sh`**: the bell with a fake bridge per session (`fake-bridge-bell.py`: working → idle,
  working → waiting). It checks entries only for sessions not on screen, the OS notification stub,
  that focus and a click read them, the gear's "Notify me about" toggles, narrow widths, light and
  dark, and idle CPU. `window back|front` plays the window going behind and coming back.
- **`buttons.sh`**: every button clicked (toolbar, "+" menu, tab close, settings popover rows,
  shortcuts sheet, row "…"), tooltips from the action table, and idle CPU with a tooltip showing.
- **`shots.sh`** (`OUT=name`): screenshots of the chrome (left column, editor and Files tabs,
  settings popover, narrow window; dark and light) into `build/shots/$OUT/`. It uses only commands
  and keys, so the same scene runs against an older build for before/after pairs.
- **`looks.sh`**: the three looks in dark and light (fake store, fake pi).
  `LOOKS_PI=real tests/scripts/looks.sh` (real pi, billed) checks that real pi re-themes on a
  switch, with one short prompt on a cheap model.
- **`readme-shot.sh`**: the README's screenshot, `docs/images/pi-desk.png`, from demo data only (a
  made-up store and a demo pi, `demo-pi.py`, that draws a made-up conversation and a todos panel;
  a Markdown, a browser and a shell tab). It needs a CEF build and writes
  `build/shots/readme/pi-desk.png`; check it by eye before copying it to `docs/images/`.
- **`restore.sh`**: open sessions and shells, quit through the confirm flow, relaunch with the
  same temp data dir and check the workspace came back; also a 20-session launch.
- **`persist-cpu.sh`**: CPU and save checks while a fake bridge reports status every second.
- **`setup.sh`**: the first-run sheet (`PI_DESK_FIRST_RUN=1`) against a fake HOME whose
  `~/.pi/agent/AGENTS.md` names a fake vault. The vault is found, chats are kept separate, Done
  makes only the missing subfolders, a job draft lands in its `jobs/`, a new chat gets
  `PI_KIT_NOTES_DIR`, and the gear and the menu bar reopen the sheet. A second start shows no
  sheet, and the user's own `PI_KIT_NOTES_DIR` wins.
- **`editor.sh`**: the editor in a git project: open, type, undo, save by key and toolbar, the
  right-click menu, a shell changing the file (clean → reloaded, unsaved → banner → Reload), a
  dirty close, a 50k-line file and idle CPU, then a relaunch that checks the editor tabs came back.
  For timings, run `odin test src -o:speed -define:ODIN_TEST_NAMES=main.editor_perf_50k`.
- **`files.sh`**: the Files tab in a git project with modified, untracked and ignored files and a
  10k-file folder: expand, preview then keep, keyboard, new file, inline rename, delete through the
  confirmation bar (test mode trashes into `build/test-trash`), the row menu, a terminal opened in
  a folder, an outside change, drag onto a terminal, reveal of the active file, filter,
  light/dark, layout time while scrolling the 10k folder and idle CPU, then a relaunch that checks
  the tab and its open folders came back.
- **`markdown.sh`**: the Markdown tab in a project of `.md` files: open, a second open focusing
  the same tab, the preview/source toggle (toolbar and ⇧⌘V), find, a live reload after the file
  changes, a relative link and an anchor, an external link (test mode logs it and opens nothing),
  the mermaid placeholder, the guide, light/dark at four widths and idle CPU. Parser tests and the
  1 MB timing are in `src/markdown_test.odin`.
- **`jobs.sh`**: Atlas's jobs ([ATLAS.md](ATLAS.md) §9 step 1) with a fake `pi --mode json`
  (`fake-pi-json.py`) and a fake notes folder: the Jobs tab, Run now and every outcome (ok,
  needs_you with the blocked action, over_limit, looping, stalled, failed ×3 → paused,
  folder_missing), late, overlapping and `at` ticks, a daily limit, an edited note running as
  edited, a script's job running on its schedule without approval, no Keychain code, Delete, Pause
  all, limits, redaction, the run environment, the ATLAS.md copy and idle CPU.
- **`worktrees.sh`**: the Files tab's checkout switcher in a git project with worktrees (merged
  and clean, dirty and ahead, detached, folder gone) and branches without one: the menu and its
  state, picking a worktree, a terminal and a pi session in one, Clean up through the
  confirmation bar, light and dark and idle CPU, then a relaunch that checks the worktree session
  and the tree's checkout came back.
- **`update.sh`**: pi-desk's own updates, in a test build of its own, from local `file://`
  fixtures (fake bundles signed ad hoc, the throwaway test key) into a fake install folder in
  `build/update/`: the bar, Skip, Check for Updates…, Later, agents refused, Update, a staged
  copy changed after its check refused at install, Try again, the confirmation while a pi tab
  runs, the swap and the logged relaunch; then a second start that keeps the old bundle and
  refuses a release whose signature does not match.
- **`release-checks.sh`**: `build/update-sign`'s key-file rules and `scripts/release.sh`'s
  refusals (dirty tree, HEAD not the tag, wrong or placeholder key, rotation), in a temp
  repository with a fake `gh` and the test key; it builds no release.
- **`browser.sh`**: the browser tab scenes ([BROWSER.md](BROWSER.md) §6), on local test pages
  only.

The layout audit (`src/layout_audit_test.odin`, part of `./build.sh test`) checks that no text or
icon overlaps another or leaves its row, bar or column, at 800–2000 px, in every look, light and
dark.

To see the project tree your own session store would give, without running the app, use the
dry run. It prints paths only and reads just the `cwd` of each folder's newest session header:

```sh
python3 -I scripts/tree-dryrun.py > /tmp/store.tsv
PI_DESK_TREE_DRYRUN=/tmp/store.tsv odin test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.tree_dryrun
```
