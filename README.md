# pi-desk

pi-desk is a native macOS app for the [pi](https://github.com/earendil-works) coding agent. It
keeps your projects and pi sessions in one window: the list of projects, sessions and chats sits
on the left, and pi's own fullscreen terminal UI runs in the middle, exactly as it would in a
terminal. Each session can open more tabs beside its pi tab, such as a shell, a code editor, a
Markdown preview or a browser, so the work an agent is doing and the things you check it against
stay together.

pi-desk also has an agent of its own, Atlas, which lives in a drawer on the right and runs
scheduled jobs for you. With [pi-kit](https://github.com/McFalljb/pi-kit) installed, Atlas can
drive the app through its control socket, opening sessions, sending prompts and watching them
finish. pi-kit also lets every pi tab report its status to the sidebar, publish panels such as its
todo list, and read and act on the pages in your browser tabs.

![pi-desk with a pi session open: the project list on the left, pi's terminal UI in the middle with Markdown, browser and shell tabs beside it, and pi's todo list in the right column](docs/images/pi-desk.png)

## Status

pi-desk is an early, personal project in active development. Expect rough edges and breaking
changes to its files and protocol. It runs on macOS 14 or later on Apple silicon (arm64) only,
and releases are signed ad hoc rather than notarized by Apple.

## Install

You need [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent) installed and on your
login shell's `PATH`, because pi-desk runs the pi you already have and adds no accounts or keys of
its own. Install pi (Node 22.19 or later), run `pi` once in a terminal and `/login` to your
providers, then check that a login shell finds it with `$SHELL -l -c 'command -v pi'`.

[pi-kit](https://github.com/McFalljb/pi-kit) is optional. It is a set of pi extensions that lets pi
talk to pi-desk (status dots, panels, comments, browser access) and gives Atlas its tools; pi-desk
works without it, with less to show. Its README describes the install, which comes down to
`git clone https://github.com/McFalljb/pi-kit ~/pi-kit && ~/pi-kit/scripts/install.sh`.

To install pi-desk itself:

1. Download `pi-desk-<version>-macos-arm64.zip` from
   [Releases](https://github.com/McFalljb/pi-desk/releases) and, if you like, check it against
   its `.sha256` with `shasum -a 256 -c pi-desk-<version>-macos-arm64.zip.sha256`.
2. Unzip it and move `pi-desk.app` to `/Applications`. The app is about 340 MB, mostly Chromium
   for the browser tab.
3. Because the app is signed ad hoc, Gatekeeper refuses the first open. On macOS 14, right-click
   the app and choose **Open**; on macOS 15 and later, open it once and then click **Open Anyway**
   in System Settings › Privacy & Security. Alternatively, clear the download flag:

   ```sh
   xattr -dr com.apple.quarantine /Applications/pi-desk.app
   ```

On the first start pi-desk asks for a main folder, where it keeps sessions, jobs and Atlas's
prompt.

## What you get

- **pi tabs** with pi's full terminal UI, plus shell, editor, Markdown, browser and app tabs per
  session.
- **A project list** with status dots, pins, filters, chats, a Files tab, a Changes tab for git
  and a Settings tab for pi's settings files.
- **Browser tabs** with a comment mode that sends your notes to pi, and pages that agents can read
  and act on.
- **Atlas**, an agent that drives the app, and **jobs** that run pi prompts on a schedule.

The [user guide](docs/GUIDE.md) covers all of it, including shortcuts, your data and
troubleshooting.

## Building from source

Building needs macOS 14 or later, [Odin](https://odin-lang.org/) `dev-2026-09` and `clang` from
the Xcode command line tools:

```sh
git clone --recursive https://github.com/McFalljb/pi-desk.git
cd pi-desk
./build.sh run    # the first build downloads CEF (~135 MB, checksummed)
```

[docs/DEVELOPING.md](docs/DEVELOPING.md) covers the build in detail, the architecture, the tests
and scenes, pinned versions and the release process.

## Documentation

- [GUIDE.md](docs/GUIDE.md): the user guide.
- [DEVELOPING.md](docs/DEVELOPING.md): building, architecture, tests and releases.
- [PROTOCOL.md](docs/PROTOCOL.md): the control socket, commands, state, events and the pi-kit bridge.
- [BROWSER.md](docs/BROWSER.md): the design of browser tabs, comment mode and agent access.
- [ATLAS.md](docs/ATLAS.md): the design of Atlas's jobs and memory.
- [PERSISTENCE.md](docs/PERSISTENCE.md): what pi-desk saves and restores between starts.
- [TAB-PROTOCOL.md](docs/TAB-PROTOCOL.md): how a program becomes a pi-desk tab (draft).
- [ENGINE-BRIDGE.md](docs/ENGINE-BRIDGE.md): a game engine in an app tab (design draft).
- [ROADMAP.md](docs/ROADMAP.md): goals, decisions and what comes next.

## Licence

pi-desk is MIT licensed; see [LICENSE](LICENSE). Third-party components and their licences are
listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and the app bundle carries them in
`Contents/Resources/licenses/`.
