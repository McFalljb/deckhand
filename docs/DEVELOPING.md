# Developing Deckhand

How to build Deckhand, how the code is laid out, how test mode works and how a release is made.
Users start with the [README](../README.md) and the [user guide](GUIDE.md); the wire protocol is in
[PROTOCOL.md](PROTOCOL.md), the tests in [TESTING.md](TESTING.md).

## Contents

1. [Requirements](#requirements)
2. [Building and running](#building-and-running) ([the rename](#the-rename), [code signing](#code-signing), [the Linux core](#building-the-linux-core))
3. [Rebuilding libghostty-vt](#rebuilding-libghostty-vt)
4. [Pinned versions](#pinned-versions)
5. [Releases](#releases) ([update signing](#update-signing))
6. [Contributing](#contributing)
7. [Architecture](#architecture)
8. [Looks](#looks)
9. [Test mode and scenes](#test-mode-and-scenes)

## Requirements

macOS 14 or later on Apple silicon (arm64), [Odin](https://odin-lang.org/) `dev-2026-09`, and
`clang` from the Xcode command line tools. Intel Macs can build Deckhand, but without browser
tabs: CEF is wired up for arm64 only. Node 22.18 or later runs the pi integration's tests. To run
what you build you need [pi](https://pi.dev) 1.4.0 or newer, Claude Code, or both, on your login
shell's `PATH` (Atlas and jobs need pi). The pi and Claude Code integrations ship with Deckhand
(`integrations/`, [HARNESSES.md](HARNESSES.md)).

The build does **not** need Zig: libghostty-vt comes prebuilt from `vendor/libghostty-vt/`. Zig is
only needed to [rebuild that library](#rebuilding-libghostty-vt).

## Building and running

```sh
git clone --recursive https://github.com/McFalljb/deckhand.git
cd deckhand
./build.sh            # release build: build/Deckhand.app and build/deckhand (first build downloads CEF, ~135 MB)
./build.sh run        # build and run
./build.sh test       # every unit layer (TESTING.md)
build/deckhand [DIR]  # optional DIR: open a new pi chat there on start
```

In a clone made without `--recursive`, run `git submodule update --init` (`build.sh` does this
itself when sokol-odin is missing).

`./build.sh` fetches the pinned [CEF](https://bitbucket.org/chromiumembedded/cef) build
(`vendor/cef/VERSION`) with `scripts/fetch-cef.sh`, checks its checksum, keeps it in
`~/Library/Caches/deckhand/cef` and lays out `build/Deckhand.app` around it, with
`Contents/Helpers/Deckhand Core.app` inside ([Processes](#processes)). `build/deckhand` is a small
wrapper that runs the bundle's binary directly, so arguments, the environment and stdio pass
through (`build/pi-desk` is the same wrapper under the old name). `DECKHAND_NO_CEF=1 ./build.sh`
builds without browser tabs and without the download.

On its first run `build.sh` also compiles the sokol C libraries, Clay (from the pinned
`vendor/clay/clay.h` into `build/clay-odin/`, next to a copy of the submodule's Odin bindings), the
CoreText text backend and stb_truetype. `src/` imports `build/clay-odin`, so `odin test src` and
the editor's Odin tooling need one `./build.sh` first. (The submodule's prebuilt macOS `clay.a`
targets macOS 15, so it is not used.)

The minimum macOS is 14.0 (`MACOS_MIN` in `build.sh`). `scripts/check-minos.sh` checks it twice:
on every native library Odin links, and after bundling on every Mach-O in `Deckhand.app`, CEF
included. Anything newer fails the build. Deckhand has not yet run on a real macOS 14 machine.

### The rename

Deckhand was called pi-desk. Deckhand 0.1.6 and older update only to a bundle with the old bundle
id and the old signature format, so the rename takes two releases:

- **0.2.0, the bridge** (it also carries the core/window split). Every name is Deckhand's (`DECKHAND_*` variables and test hooks,
  `tools/deckhand-cli/`, `.deckhand/apps.json`, `~/Library/Caches/deckhand/cef`,
  `~/.config/deckhand/update.key`, `TERM_PROGRAM=Deckhand`), and the old ones still work
  (`src/core/env_names.odin` lists them):
  - Variables Deckhand sets in Claude tabs, app tabs and job runs are set under both names
    (`DECKHAND_SOCKET` and `PI_DESK_SOCKET`…), never in pi tabs, where pi-kit's desk extensions
    would switch on. Readers take the new name first, then the old.
  - Scrubs drop an explicit list of Deckhand's names, never every `DECKHAND_` variable, so your own
    `DECKHAND_SIGN_IDENTITY` reaches a shell tab.
  - The bundle keeps `Contents/MacOS/deckhand-cli` and a link `pi-desk-cli -> deckhand-cli`
    (older and held Claude tabs run it by that path; a read-only tab's guard fails closed without
    it), and the plugin keeps `bin/pi-desk`.
  - The data dir is `~/Library/Application Support/Deckhand` if it exists, else `…/pi-desk`, where
    every older install keeps its data. `.deckhand/apps.json` is read first, else
    `.pi-desk/apps.json`.
  - The bundle id stays `dev.pi-desk.app` and releases are signed in the v2 format
    (`pi-desk update v2`), but the updater also accepts `dev.deckhand.app` and v3
    (`deckhand update v3`, `UPDATE_BUNDLE_ID_NEXT` in `src/core/update_core.odin`), so 0.2.0 can
    take the flip.
  - `scripts/rename-pi-desk.py` did the mechanical part (re-runnable with
    `scripts/rename-pi-desk-rebase.sh`).
- **The flip (0.2.1).** The bundle id becomes `dev.deckhand.app`, releases are signed v3,
  and the data dir moves to `…/Deckhand` (with a link from the old place). The window's identifier
  list in `src/trust` gains `dev.deckhand.app`. The move must handle a running core and holder:
  the runtime dir, `core.sock` and `core/<v>/` live in the data dir, and kept tabs have
  `DECKHAND_SOCKET` set. Deckhand 0.1.6 and older can't take the flip: they update to 0.2.0 first,
  or are reinstalled by hand.
- **Three releases after 0.2.0:** the old names stop being set and
  shipped (`PI_DESK_*` in tabs, `pi-desk-cli`, `bin/pi-desk`, `build/pi-desk`). Reading them stays.

Some names keep the old product's name for good: the instance guard's look for a running
`pi-desk.app` (and its `$TMPDIR/pi-desk-<uid>` sockets), the old Atlas prompt starters it
recognises, the titles cache's format line and the user's own `~/pi-desk` main folder.

### Code signing

Every build is signed with one identity: `SIGN_IDENTITY_DEFAULT` in `scripts/sign.sh`, which
`build.sh`, `scripts/bundle-app.sh` and `scripts/release.sh` share. It is a self-signed
certificate, **"Deckhand Self-Signed"**, in your login keychain. Make it once per Mac:

```sh
scripts/make-signing-identity.sh   # RSA key + 10-year codeSigning certificate, imported for codesign
```

The key stays in the keychain. The certificate is not trusted and need not be: `codesign` signs
with it all the same, and nothing asks for an admin password. `DECKHAND_SIGN_IDENTITY=…` overrides
the identity for one build. The default lives in the script, not the environment, because shells
Deckhand starts drop `DECKHAND_*` from the login environment (`src/core/login_env.odin`).

**Why.** macOS keeps privacy grants (Desktop, Documents, Downloads, camera, microphone) per
*designated requirement* (DR). Ad hoc, the DR is the build's CDHash, so every rebuild and update
asks again. With the certificate it is the identifier plus the certificate's hash, the same for
every build:

```sh
codesign -dr - build/Deckhand.app
# designated => identifier "dev.pi-desk.app" and certificate leaf = H"<the certificate's SHA-1>"
```

Signing goes inside out, with no `--deep` and no hardened runtime: the CEF framework's libraries
and the framework (only when the pin or the identity changed: `build/.cef-signed-as`), the five
helpers, `deckhand-cli`, `Deckhand Core.app` (its binaries with identifier `dev.deckhand.core`,
then the bundle), then the app. No DR is written by hand.

- **Not in the keychain** (a CI runner, another Mac): `build.sh` signs ad hoc with a loud warning.
  `DECKHAND_SIGN_IDENTITY=-` signs ad hoc on purpose, without it.
- **A release** never falls back to ad hoc: `scripts/release.sh` stops if the identity is missing.
  `DECKHAND_SIGN_IDENTITY=- scripts/release.sh …` makes an ad-hoc release on purpose.
- **Another Mac** has its own certificate unless you export it from Keychain Access (`.p12`) and
  import it there. Never commit it.
- **A locked login keychain** (over ssh): `security unlock-keychain` first, or sign ad hoc.
- **An Apple Developer ID later** is one line: `SIGN_IDENTITY_DEFAULT="Developer ID Application:
  NAME (TEAMID)"`. `release.sh` then signs with the hardened runtime, a timestamp and
  `scripts/entitlements/`, and notarizes when `APPLE_ID` and the rest are set. The DR changes once,
  so macOS asks for grants once more at that update.

**Trust checks follow the signer** (`src/trust`, [design §5.4](plans/background-core.md#54-until-the-developer-id)).
Each process reads its own signature once (`trust.own_signature`) and picks a mode:

| Own signature | A peer must have |
|---|---|
| ad hoc (`DECKHAND_SIGN_IDENTITY=-`, CI) | the same user and the expected identifier |
| Deckhand Self-Signed | the expected identifier and the same certificate leaf hash |
| a Developer ID | the Apple anchor and Team ID, the hardened runtime, no `get-task-allow` |

A peer's code is read through the audit token saved at accept (`trust.peer_dr_check`). The window
and the core check each other, the core checks the holder at every attach, the launcher checks the
detached process before it sends the environment, and the holder's keeper checks a re-exec'd image.
Under the self-signed identity this stops other users, stale sockets, stray binaries and code
signed by anyone else, but not a program of yours: it can sign with the same key, and without the
hardened runtime it can load a library into Deckhand. The hardened runtime stays off until the
Developer ID, because library validation compares Team IDs and a self-signed certificate has none
(a self-signed program under it can't load the self-signed CEF framework). `sign-dr`
(`tests/scripts/sign-dr.sh`) checks the real signatures.

The updater checks a new bundle's signature (`codesign --verify --deep --strict`), bundle id,
version and the CDHash its Ed25519 `.sig` names, not who signed it. So an ad-hoc install updates to
a self-signed release like to any other.

### Building the Linux core

The core (`src/coremain`, the `core` package) also builds for Linux, so a Linux machine can run
sessions for a Mac's window ([design §10.4](plans/background-core.md#104-m6-in-prs), M6-L1). It
is a step in the build, behind no switch: nothing ships it yet. On Linux (Odin `dev-2026-09`,
clang):

```sh
mkdir -p build && odin build src/coremain -out:build/deckhand-core-serve -o:speed
mkdir -p -m 700 ~/.local/state/deckhand/run   # serve expects its runtime dir (a launcher makes it)
build/deckhand-core-serve serve --run ~/.local/state/deckhand/run --data ~/.local/share/deckhand
python3 tests/linux-core-smoke.py build/deckhand-core-serve   # test mode in a temp dir: hello, get_state, a shell tab
```

- **What differs** (`when ODIN_OS` blocks and `*_linux.odin` files): `/proc` in place of libproc
  (a tab's cwd, a process's parent and children; `src/core/proc_linux.odin`); `SO_PEERCRED` in place
  of `LOCAL_PEERTOKEN`, and trust is the same user only, as there is no code signing
  (`src/trust/peer_linux.odin`, [design §8.3](plans/background-core.md#83-trust-in-both-directions));
  no Obj-C shim, so no banners of its own, no App Nap and no Trash
  (`src/coremain/platform_linux.odin`); no updater and no quarantine; a core is started directly,
  in its own session (`src/core/launch_linux.odin`).
- **Dirs:** data in `~/.local/share/deckhand`, sockets in `~/.local/state/deckhand/run` (0700;
  never `$XDG_RUNTIME_DIR`, which logout removes). A data dir given with `DECKHAND_DATA_DIR` keeps
  its sockets in `<data>/run`.
- **No session holder yet** (M6-L3): `keep_sessions` is off and can't be turned on, so tab
  processes are the core's children and a core restart restarts them.
- **Checks:** `./build.sh test` type-checks `src/coremain` and the core's packages with
  `-target:linux_amd64` (about a second). CI's `linux` job builds the core, runs the wires', the trust
  rules' and the core's unit tests on Linux, and `tests/linux-core-smoke.py` (also with `--default-dirs`).
- **No window on Linux:** the window door refuses every framed hello but a hub's
  (`NO_WINDOW_HERE`): with no code signing, a window hello would be any same-user process's `ui`.

## Rebuilding libghostty-vt

```sh
# needs Zig 0.17.0 in toolchain/ (gitignored), checksum from ziglang.org/download/index.json
scripts/build-ghostty.sh                # all targets
scripts/build-ghostty.sh aarch64-macos  # one target
```

The script builds static libraries for macOS arm64 and x86_64, Linux x86_64 and aarch64 (gnu) and
Windows x86_64 (gnu), then repacks each one: it strips debug info (12–22 MB down to about 3 MB),
cuts member names to basenames, and makes Zig's bundled compiler_rt weak so it links next to the
Odin runtime. It uses LLVM's objcopy and ar, found next to `clang`. COFF symbols can't be weakened,
so the Windows library keeps strong compiler_rt symbols; Windows linking is untested.

## Pinned versions

| Dependency | Version |
|---|---|
| Ghostty (libghostty-vt) | `v1.4.0`, commit `83fb95624b0439ee660c2679b43b38c8b63769cd` (`vendor/libghostty-vt/VERSION`) |
| Zig (to build libghostty-vt only) | 0.17.0 (Ghostty 1.4.0 needs exactly 0.17.x) |
| sokol-odin | `cdef8e58162cd657c453e65cb087b9cb5888adb9` (2026-10-29) |
| Clay | `e6cc36941ab2af5d81107617039d6f527a1c660b` (2026-05-20) |
| Odin | dev-2026-09 |
| CEF | `vendor/cef/VERSION` |
| tree-sitter + 13 grammars | lib `v0.27.1`; grammars at pinned tags in `vendor/tree-sitter/` (`VERSIONS`; refresh with `scripts/vendor-tree-sitter.sh`) |

libghostty-vt's C ABI is not stable yet, and `src/ghostty/ghostty.odin` is hand-written for
v1.4.0. `./build.sh test` checks struct sizes, offsets and key-enum values against the C headers.

**Bumping libghostty-vt** also means checking terminal snapshots (`src/core/snapshot.odin`;
[design §5.5](plans/background-core.md#55-terminal-streams-option-a)):

1. `./build.sh test` must pass `snapshot_stored_corpus`, which decodes the GHOSTSNP snapshots the
   previous library wrote (`tests/vt-corpus/ghostsnp-1/`) and compares each with a live terminal
   fed the same bytes.
2. If the snapshot format version changed (bytes 8–9 of the body after `GHOSTSNP`), add
   `ghostsnp/N` to `SNAPSHOT_FORMATS` ahead of the old one. Keep the old one while a released core
   may still send it.
3. Rerun the full corpus (`tools/vt-snapshot-spike` on the `spike/vt-snapshot` branch) and check
   that `TERM_CONTINUATION_MAX` still covers the parser's longest kept sequence (`osc.zig`
   `MAX_ALLOCATING_BUF`).
4. Add the new version's snapshots under a new directory, keeping the old ones.

## Releases

Releases are built and signed on the release signer's Mac with one command,
`scripts/release.sh --version X.Y.Z`. CI tests every push but builds no releases.

1. Commit everything, `git tag vX.Y.Z`, `git push origin vX.Y.Z`.
2. `scripts/release.sh --version X.Y.Z` (or first `--no-upload`, a dry run into `dist/`, then
   `--upload-only` to draft what it left there).
3. Check the draft on GitHub (notes and the three files) and publish it.

What `release.sh` does:

- **Refuses** unless the worktree is clean, HEAD is exactly the tag `vX.Y.Z`, `UPDATE_PUBLIC_KEY`
  is a real key and the key file matches it, and the signing identity is in the keychain.
- **Builds** with `./build.sh test`, then `DECKHAND_RELEASE=1 ./build.sh` (CEF, no test hooks:
  below).
- **Checks** with `scripts/check-release-build.sh` that the window, `deckhand-cli`, and Core.app's
  `deckhand-core`, `deckhand-core-serve` and `deckhand` hold the real update key and no test hook.
- **Signs** every `Info.plist`'s version, then the code ([Code signing](#code-signing)), and
  verifies the app and the nested Core.app on its own (`--deep --strict`, identifier
  `dev.deckhand.core`).
- **Packs** the zip, unpacks it again to check its signature and CDHash, and writes the `.sha256`
  and the `.sig` ([Update signing](#update-signing)).
- **Tests the update path:** the current release's updater installs the new zip
  (`tests/scripts/update-from-release.sh`, 1–2 min). A published binary has no update fixtures,
  so the script builds the updater from the latest release's tag in a temporary worktree (as the
  update scene does), offers it the new zip from `file://` with that tag's throwaway test key, and
  checks the installed bundle. `--prev TAG` names the tag; `--skip-prev-updater` is only for a
  first release.
- **Drafts** the GitHub Release with `gh --verify-tag` (the tag must be pushed; a re-run replaces a
  draft's files, never a published release's), then downloads the `.sig` again and verifies it.

A release, "Deckhand X.Y.Z", carries `deckhand-<version>-macos-arm64.zip` (exactly
`Deckhand.app`), its `.sha256` and its `.sig`. Until the Developer ID it is self-signed and not
notarized, so Gatekeeper blocks the first open (the README says what to do); the notes say so. The
app is about 340 MB, mostly Chromium, and carries the third-party licences in
`Contents/Resources/licenses/`. The repository's name lives in one place, `UPDATE_REPO` in
`src/core/update_core.odin`; the app's and zip's names come from `UPDATE_APP` and
`ZIP_PREFIX`/`ZIP_SUFFIX` (`src/updatesig/updatesig.odin`).

**After an update, sessions stay.** The new window installs its bundled Core.app to
`<data dir>/core/<version>-<sha12>/`, makes it `current`, and asks the running core to hand over
(`core.handover`): the old core snapshots every terminal at an offset the holder acked, writes
`handover.json`, and starts the new core with the holder's one-time secret. If the holder's
revision changed, the holder then re-execs itself in place. What users see is in
[How Deckhand runs](GUIDE.md#how-deckhand-runs); the design is in
[§7](plans/background-core.md#7-updates-and-version-skew).

**No test hooks in a release** ([design §5.3](plans/background-core.md#53-auth-developer-id-model):
a genuine binary must not be steerable by its environment). Every test and development knob goes
through `hook_env()` in `src/core/test_hooks.odin`, whose `HOOK_ENV` table names them (test mode,
`DECKHAND_DATA_DIR`, `DECKHAND_RUNTIME_DIR`, the pi and Claude stand-ins, the updater's fixtures,
`DECKHAND_SEPARATE_CORE`…). `-define:DECKHAND_TEST_HOOKS=false` compiles the table out, so a release
uses the fixed data and runtime dirs, never enters test mode, and has no `--print-token`.
`scripts/check-env-reads.py` (in `./build.sh test` and `check-release-build.sh`) fails on any
environment read that is not a known literal name, so a new knob can't skip `hook_env()`.
After a release build, run `./build.sh` again before the scenes: they need the hooks.

### Update signing

Deckhand updates itself from GitHub releases (`src/core/update.odin`; for users,
[Updates](GUIDE.md#updates)). The trust anchor is Deckhand's own Ed25519 key, not GitHub or TLS:
an update installs only when its `.sig` verifies under the public key compiled into the app
(`UPDATE_PUBLIC_KEY` in `src/core/update_key.odin`). **The private key lives only on the release
signer's Mac**, never in GitHub, and `release.sh` signs only the bundle it has just built.

- **What is signed** is a short manifest (`src/updatesig/updatesig.odin`):
  `pi-desk update v2\nversion X.Y.Z\nfile deckhand-X.Y.Z-macos-arm64.zip\nsize N\nsha256 HEX\ncdhash HEX\n`
  (v3 after the flip). The CDHash is the main executable's code directory hash, which covers
  `Info.plist` and the resource seal, so every file in the bundle. A signature is bound to one
  version and to the exact app inside: Deckhand checks the CDHash on the unpacked copy, on the
  staged copy, and right before it renames that copy into place. The `.sig` is three lines:
  `pi-desk-update-sig v2`, `cdhash HEX`, `signature BASE64`. Pre-releases are never offered or
  signed.
- **The tool:** `odin build tools/update-sign -out:build/update-sign`, then `keygen FILE`,
  `pubkey KEYFILE`, `sign KEYFILE VERSION ZIP CDHASH SIG`, `verify PUBKEY VERSION ZIP SIG` and
  `manifest VERSION ZIP CDHASH`. It reads the private key only from KEYFILE, never prints it, and
  refuses a KEYFILE that is a link, not yours, not mode `600`/`400`, or in a folder others can
  write. `release.sh` takes it from `--key FILE`, `$DECKHAND_UPDATE_KEY_FILE` or
  `~/.config/deckhand/update.key`.
- **Setting it up** (once): `mkdir -p ~/.config/deckhand && chmod 700 ~/.config/deckhand`,
  `build/update-sign keygen ~/.config/deckhand/update.key`, put the printed public key into
  `UPDATE_PUBLIC_KEY` and commit. Back the key up offline (an encrypted USB stick or a password
  manager), not in iCloud Drive or a repository.
- **Backups of the app.** An update keeps the replaced app as `Deckhand.app.old-<version>` (rolled
  back to if the swap fails) and removes it at the second start after the update.
- **Losing the key** means installed copies can't update automatically: ship a new key in a
  release users install by hand.
- **Rotating it:** ship a release whose `UPDATE_PUBLIC_KEY` is the new key, **signed with the old
  one** (`scripts/release.sh --version X.Y.Z --key OLDFILE --rotating-from OLDPUB`), then sign later
  releases with the new key. If the old key leaked, publish that release quickly and tell users of
  older copies to update by hand.
- **Tests** use a throwaway key, `tests/update/test-key.txt`, public on purpose. It and the update
  fixtures (`DECKHAND_UPDATE_URL`…) are compiled in only with `-define:DECKHAND_UPDATE_TEST=true`.
  `tests/scripts/update.sh` plays the whole flow from `file://` fixtures into a fake install;
  `tests/scripts/release-checks.sh` checks the key-file rules and `release.sh`'s refusals against
  a fake `gh`.

## Contributing

Every user-visible change updates [GUIDE.md](GUIDE.md) in the same branch. `src/docs_test.odin`
(in `./build.sh test`) checks part of this: every action in `src/actions.odin` (label and
shortcut) and every menu item must appear in GUIDE.md, and every command in
`src/core/command_table.odin` that the user or agents may send (`who = .User` or `.Anyone`) must
appear in GUIDE.md or [PROTOCOL.md](PROTOCOL.md).

GUIDE.md is built into the binary and copied to `<data dir>/atlas/GUIDE.md` for Atlas
(`src/core/agent.odin`). If you change Atlas's starter prompt (`ATLAS_PROMPT_STARTER`), add the
previous one to `ATLAS_PROMPT_OLD_STARTERS` so unedited copies are replaced at startup.

Any change to `src/holder`, `src/holderwire` or `src/trust` (tests aside) needs a bump of
`HOLDER_REV` in `src/holder/holder.odin` and `src/core/holder_install.odin`;
`scripts/check-holder-rev.sh` fails CI otherwise ([The session holder](#the-session-holder)).
The window/core API is grow-only: `schema/released-v1.json` and `schema/released-holder.json`
fail a unit test on any change that is not an addition.

## Architecture

Deckhand is written in **Odin** with **Clay** for layout, **sokol** for the window and the GPU,
**libghostty-vt** for terminal emulation and **CEF** for browser tabs. It targets macOS for now;
the platform pieces (the PTY, fonts, launchd, signatures) sit behind small files so Linux and
Windows can follow. The design of the process split is
[docs/plans/background-core.md](plans/background-core.md); this section is how it is built.

### Processes

```
Deckhand.app            the window: drawing, input, CEF, app tabs, editor buffers,
  (src/*.odin)          a ghostty-vt copy per shown terminal, a replica of State
      │ core.sock: framed wire (src/corewire), both sides check each other's signature
Deckhand Core.app       the core: State, commands, the control socket, persistence, pi, Claude,
  deckhand-core-serve   jobs, Atlas, updates, a ghostty-vt per terminal
  (src/coremain + src/core)
      │ holder.sock: holder wire (src/holderwire)
  deckhand-core hold    the session holder: PTYs, every session process as its child, output
  (src/holder)          tails and offsets; re-execs itself to upgrade
```

- **The window** is a client. It dials `core.sock` in the runtime dir; when nothing answers it
  launches a core through launchd (`deckhand-core-serve __detach`, so the core never descends from
  the window) and waits up to 15 s. The core streams `state.full`, then `state.delta`s; the window
  decodes them straight into `core.state`, its replica, so the core's read-only helpers work
  unchanged (`core.replica_process`; runtime a window needs but State lacks goes in
  `State.live` and `Tab.live`, `src/core/core_live.odin`). Its commands go to the core and wait
  at most 250 ms for a result. If the connection ends, the window dials again and relaunches a
  core if needed (at most 3 times a minute); only a core that said `window.request quit` first
  ends the window. See `src/client_core.odin` and [PROTOCOL.md](PROTOCOL.md) §5a.
- **The core** runs headless in a `poll(2)` loop (`src/coremain/serve.odin`). It takes
  `core.lock` (one core per data dir) and `instance.lock` (shared), adopts the holder, restores and
  serves. It runs with or without a window, and exits after 10 idle minutes (no window, no live tab
  process, no job run or enabled scheduled job). Job runs are its children, not the holder's.
  Browser and app tabs live in the window; with no window their commands answer `no_window`.
- **The holder** owns the PTYs, so sessions survive the core and the window. It relaunches a core
  that crashes (backoff 1–30 s, giving up after 6 failures in a row). Its own code is in
  [The session holder](#the-session-holder).
- **In-process mode** is the opt-out (Settings › *Sessions in a background core* off, or
  `DECKHAND_SEPARATE_CORE=0` in test and development builds): the window runs the core in its own
  process over the in-memory transport (`src/core/window_link.odin`), with the same messages.
- **Quitting** goes through one table, `quit_route` in `src/main.odin`: ⌘Q, the Dock's Quit and
  closing the window close only the window; *Quit Deckhand and Stop All Sessions…* stops the core
  and the holder; logout ends everything. User-facing behaviour:
  [How Deckhand runs](GUIDE.md#how-deckhand-runs).
- **Core.app** (`dev.deckhand.core`, `LSUIElement`) holds `MacOS/deckhand-core` (the holder),
  `MacOS/deckhand-core-serve` (the core) and `MacOS/deckhand` (the CLI), and the integrations in
  `Resources/integrations/`. The core and the holder are two binaries because linking both into
  one trips an Odin LLVM assertion at `-o:speed`. The window installs the whole Core.app to
  `<data dir>/core/<version>-<sha12>/` (verified against our DR, then quarantine stripped;
  `current` and `previous` are symlinks), and runs it from there, so an app update never pulls a
  binary from under live sessions (`src/core/core_versions.odin`). *Use previous core* hands over
  to `previous`. `Deckhand.app` keeps `MacOS/deckhand-cli` and `Resources/pi`/`claude-code`,
  because older tabs run them by path.

**What links what.** `src/core` (package `core`) imports no window code: no sokol, Clay, CEF or
Obj-C shims. The holder imports only `holderwire`, `trust` and `jsonguard`; `src/coremain` may
import only `core` and `holder` and has its own Obj-C shim. `scripts/check-core-boundary.sh` (in
`./build.sh test` and CI) enforces this. The window (`src/`, package `main`) names the core's
declarations as `core.X`.

### The session holder

`src/holder`: the holder's wire (`src/holderwire`, frozen bootstrap subset, golden vectors), its
launchd detach (`detach.odin`), the supervisor that relaunches the core (`supervisor.odin`) and
the in-place upgrade (`upgrade.odin`, `keeper.odin`, `state.odin`;
[design §7.3](plans/background-core.md#73-holder-upgrade-re-exec)): same pid, every session kept,
with a keeper process that hands the PTYs only to an image that passes the signature check. The
core's side is `src/core/holder_*.odin`. A core upgrades an older attached holder to the one it
bundles, once per run. In a development build the palette's *Restart session holder* upgrades to
the one you just built. `DECKHAND_HOLDER_REV=N` (test builds) makes the app take its bundled holder
for rev N. The re-exec tests use `build/deckhand-core-hooks`, built with test hooks.

### Source map

Paths are relative to `src/`. `src/core/<file>_core.odin` holds the types the core needs from a
window file `src/<file>.odin`; `scripts/core-files.txt` lists the core's files.

```
main.odin           sokol app: init, frame, event; the quit routes; picks separate or in-process
client.odin, client_core.odin   the window as a client: dial, hello, replica, reconnect, handover at attach
coremain/           deckhand-core-serve: serve (the poll loop), __detach, check, install, launch
holder/             the session holder (above); holderwire/ its wire
corewire/           the window/core framed wire, the socket and in-memory transports (golden vectors in tests/framed-wire/v1/)
trust/              who may talk to whom: own signature, peer DR checks by audit token
updatesig/          the update manifest and its Ed25519 signature
jsonguard/          the check in front of every parse of input Deckhand does not control
core/state.odin     State: the one plain, serialisable app state (ids, no pointers)
state_view.odin     the window's `state: ^core.State` (the replica, or the core's own in process)
core/commands.odin  the Command union and run_command: the only code that changes State
core/command_table.odin  every command: args, who may send it, confirm class, long-running
core/state_wire.odin, state_read.odin  the state stream and its decoder; the API is grow-only (schema/)
core/window_link.odin  the window's door: commands as `ui`, state.subscribe, window.command
core/window_hooks.odin, window_requests.odin  what the core asks of the window (window.request) and the window's facts
core/tabhost_route.odin, tabhost_link.odin  browser, app, Markdown and editor tabs: records in the core, views in the window
core/core_loop.odin core_tick: inbox, terminals, persistence, jobs, Claude
core/core_live.odin runtime a separate window shows that is not State
core/core_handover.odin, core_versions.odin  handing a core over; installed cores, current and previous
core/holder_*.odin  the core's side of the holder: client, install, adopt, successor, restart
core/launchd_darwin.odin  launching the core or holder outside the app (launchd detach)
core/inbox.odin     command inbox: any thread submits, the main thread drains
core/events.odin    events, the command log, own-event filter
core/socket.odin    control socket: hello and tokens, subscriptions, pi-tab bridge routing
core/ctl.odin       `deckhand --ctl`: a tiny socket client for scripts and tests
core/json_*.odin    hand-written JSON (PROTOCOL.md)
core/term.odin      one terminal, the core's side: PTY (or the holder's), libghostty-vt, size
core/term_stream.odin, term_view_stream.odin  a terminal's bytes streamed to the window's copy
term_view.odin      the window's side of a terminal: drawing, selection, input encoding
core/snapshot.odin  terminal snapshots (GHOSTSNP, the VT fallback) and the screen hash
core/pty*.odin      the PTY: forkpty (macOS, Linux); ConPTY later
core/persist.odin   workspace.json (PERSISTENCE.md)
core/login_env.odin the login shell's environment (Launch environment, below)
core/sessions.odin, titles.odin  pi's sessions and their titles
core/claude*.odin   Claude Code tabs (CLAUDE.md); ../tools/deckhand-cli/ the CLI its plugin runs
core/pi_integration.odin  the bundled pi integration (HARNESSES.md)
core/agent.odin, drawer.odin  Atlas and its drawer (ATLAS.md)
core/jobs*.odin, ui_jobs.odin, ui_job_sheet.odin  jobs
core/update*.odin, ui_update.odin  Deckhand's own updates
core/agent_status.odin  each terminal tab's status (OSC 7501, the bridge), unread, roll-ups
core/notify.odin, ui_bell.odin  the bell
core/sidebar.odin, ui_sidebar.odin  the left column
core/files.odin, fs_model.odin, ui_files.odin  the Files and Settings tabs
core/changes.odin, ui_changes.odin  the Changes tab
core/settings_files.odin  the Settings tab: pi's settings files by an allowlist
editor*.odin, core/editor*_core.odin  editor tabs
markdown*.odin      the Markdown parser and preview
browser*.odin, core/browser*.odin  browser tabs (BROWSER.md); app_tab.odin, frames.odin app tabs (ENGINE-BRIDGE.md)
core/panes*.odin, panes_drag.odin, ui_panes.odin  split panes
actions.odin        user-facing actions (label, shortcut, command): the palette, buttons, menus
palette.odin, menubar.odin, ui_toolbar.odin, ui.odin  the palette, menu bar, top bar, Clay layout
theme.odin, font.odin, text_*.odin, icons.odin, logos.odin  looks, text, icons
native/             Obj-C and C shims: platform, CEF, frames, editor (FSEvents, Trash)
platform*.odin, win_os.odin  what the window asks of the OS
ghostty/            Odin bindings for libghostty-vt
autotest.odin       DECKHAND_SCRIPT test mode
*_test.odin         unit tests (TESTING.md)
```

### Data flow per terminal

```
child (pi, claude, shell) <-> PTY master, owned by the holder (or the core when Keep sessions is off)
  output: holder reads, keeps a 1 MiB tail -> holder.sock -> core's ghostty-vt
          -> term stream (snapshot, then bytes) -> the window's ghostty-vt for a shown tab -> draw
  replies to queries (DA, DSR, colours): only the core's terminal answers
  input:  window's key/mouse/paste encoders -> term stream -> core -> PTY
```

A shown tab is parsed twice, a hidden one once. The window's copy falls behind only by
snapshots: past a credit limit the core sends a fresh snapshot instead of bytes.

### Commands and state

Clicks, shortcuts, test scripts and the control socket all build a `Command` that names its
target by id and submit it to the core's inbox. The core's main thread drains it each tick, runs
`run_command` (which returns `Result{ok, error, created_id, pending, confirmation}`), bumps
`state.version` only if State changed, and emits an event. Events go to `<data dir>/commands.log`,
redacted and rotated at 10 MB. The window's commands arrive over its link as caller `ui`.

Closing a busy tab or stopping running sessions asks in a bar in the window. By default only the
user confirms, but the user can let a caller confirm with its own token (`trusted`) or skip
confirmation (`auto`) per command class.

Runtime resources such as PTYs and terminals live outside `State`, in `terms`, keyed by tab id.
Raw keystrokes for the focused terminal go straight to its stream; agents use `send_text`. State
and command code never calls sokol; what it needs from the window goes as `window.request`.

### The control socket

The core listens on `core.sock` in a per-user `0700` runtime dir and gives each pi tab
`DECKHAND_SOCKET` and its own `DECKHAND_TOKEN` (caller `panel`). The bridge of Deckhand's pi
integration ([HARNESSES.md](HARNESSES.md)) reports `pi.session` and `pi.status`, publishes panels
with `panel.set` and receives `pi.prompt`, `pi.reload` and `pi.wait_idle`. Atlas drives the app
through the same socket with the integration's `desk` tools (PROTOCOL.md §8). The window uses the
same socket with a framed hello.

For local scripts, `build/deckhand --print-token script DIR` prints one
`export DECKHAND_SOCKET=… DECKHAND_TOKEN=…` line, then `build/deckhand --ctl '{"type":"get_state"}'`
talks to the running core (PROTOCOL.md §9). With a separate core, `--ctl` launches one if none
answers. Release builds have no `--print-token`; there the gear's **Copy a control token** puts
the same line on the clipboard.

### Sessions and tabs

A session's cwd comes from the header line of its pi session file, because pi's directory names
are lossy. Its title follows `pi --resume`: the latest `session_info` name, else the first user
message with text, then a `/goal` objective, else "Untitled session · <created>". Each file is
read once, then only what pi appended (`titles.odin`). Opening a session runs
`pi --session <file>` in its cwd; a new one runs `pi --session-id <uuid>` with a UUID Deckhand
picks. Both go through `$SHELL -l -c`.

`Tab_Kind` is a union (`Pi_Tab`, `Shell_Tab`, `Editor_Tab`, `Markdown_Tab`, browser and app tabs…).
Each open session has its agent's tab at index 0 plus any others. Sessions you switch away from
keep running. A Markdown tab is a read-only editor plus a preview laid out by `markdown_view.odin`
from Deckhand's own parser. See [BROWSER.md](BROWSER.md) and [TAB-PROTOCOL.md](TAB-PROTOCOL.md).

### Terminals

The child gets `TERM=xterm-256color`, `COLORTERM=truecolor` and `TERM_PROGRAM=Deckhand`, and the
identity variables of whatever terminal launched Deckhand are removed.

Printable keys travel as text from the CHAR event, right for any keyboard layout. Ctrl, Alt and
special keys are encoded from KEY_DOWN. Option acts as Alt, so Option+letter sends ESC+letter. The
macOS line-editing keys are Ghostty's defaults (`mac_key_text` in `term_view.odin`): ⌘⌫ sends
Ctrl-U, ⌘← Ctrl-A, ⌘→ Ctrl-E, ⌥← ESC b, ⌥→ ESC f; ⌥⌦ (ESC d) is Deckhand's own. ⌘K stays the
palette.

When the program tracks the mouse (pi does), clicks, drags and the wheel go to it, and Shift+drag
selects instead. Otherwise a drag selects and scrolls past the edges; double-click selects a word,
triple-click a line, Shift+click extends, ⌘C copies.

## Looks

`set_theme {"name": "graphite" | "warm" | "ghostty"}` switches the look live, and
`set_reduce_motion {"on": true}` turns off fades and the running pulse. Every size, colour and
timing the chrome uses is a token in `src/theme.odin`, so `ui.odin` has no raw numbers or colours.
A look also sets the terminals' default colours through libghostty-vt, so pi's TUI blends with the
chrome; `ghostty` is Ghostty 1.4.0's defaults. Motion redraws only while something moves.

Each look has a dark and a light variant. `set_appearance {"mode": "system" | "light" | "dark"}`
picks one; `system` follows macOS live through KVO on `NSApp.effectiveAppearance`.

When the terminals' default colours change, a program that enabled mode 2031 gets
`CSI ? 997 ; 1|2 n`, and `CSI ? 996 n` is answered. pi enables 2031 when its theme follows the
terminal (`pi --use-theme system`, say) and then queries the colours again. Light terminals derive
the 256-colour cube and grey ramp from the look's colours (Ghostty's `palette-generate`).

## Test mode and scenes

What tests exist and when to run them: [TESTING.md](TESTING.md). This section is how test mode
itself works.

> **Paid scenes start your real pi** with your own credentials (`bridge-e2e.sh`, `home-e2e.sh`,
> `text-pi.sh`, `LOOKS_PI=real looks.sh`). Every other scene uses a fake HOME and a fake pi, never
> touches your data and needs no network.

Scenes run `build/deckhand` as it is; `./build.sh scenes` builds it first when needed. Like the
app, scenes run with a separate core by default; `DECKHAND_SEPARATE_CORE=0` or `1` overrides the
saved setting for one run (test and development builds only).

### How test mode works

`DECKHAND_SCRIPT=file build/deckhand DIR` plays a script of synthetic events through the normal
event handler; the script commands are listed at the top of `src/autotest.odin`. Scripts submit
commands (`command {"type":"close_tab","tab_id":$tab}`) and check results with
`assert_state PATH VALUE` and `assert_result PATH VALUE`. The app exits with status 1 if an assert
failed. While a script runs, real keyboard and mouse input is ignored. With a separate core, every
state read first waits until the core ran what the window sent, and a script line's core half
(`jobs_clock`, `detach_window`) goes to the core as `script.core`.

Test mode is quiet, so scenes can run while someone uses the Mac: the app never activates, and its
window sits behind the desktop picture and ignores the mouse. It still draws, so frames, CPU
numbers and screenshots work. A script's copies and pastes use a pasteboard of its own.
`DECKHAND_QUIET=0` shows the window so you can watch a run.

`shot NAME` raises the window without taking focus and captures it into `build/shots/NAME.png`.
Test mode logs to `build/test-data/`, and saves and restores the workspace only when
`DECKHAND_DATA_DIR` is set. It draws at a fixed backing scale, `DECKHAND_SCALE` (1 to 4, default
1), so a scene's pixels are the same on every Mac.

**Test mode never starts a real `pi` or `claude` unless told to.** Every launch path runs a
stand-in or refuses, and prints the refusal on stderr:

- **pi tabs** run `DECKHAND_CMD` (it gets pi's arguments as `"$@"`); without it they exit 127,
  unless `DECKHAND_REAL_PI=1` opts in (the paid scenes).
- **Claude tabs** run `DECKHAND_CLAUDE_CMD`; without it they exit 127. No opt-in.
- **Jobs** run only the `pi_path` setting (a scene's fake), or pi from PATH with
  `DECKHAND_REAL_PI=1`.
- **Installs and updates** from the coding agents checklist run `DECKHAND_INSTALL_CMD`
  (`tests/scripts/fake-install.sh`); without it they exit 127. No opt-in.

**Which harnesses a scene has** (`src/core/harness.odin`): in test mode Deckhand looks for pi and
Claude Code only under the scene's fake HOME, never on PATH, so your own installs never change a
scene. pi counts as installed when `DECKHAND_CMD` is set or a stand-in is in `~/.pi/agent/bin`;
Claude Code when `claude-stub.sh` put one in `~/.local/bin`.

Other knobs: `DECKHAND_LOG_COMMANDS=1` prints every event. `deckhand --fresh` starts without
restoring the saved workspace and keeps the old file as `workspace.json.bak-<time>`.

### Test mode as an interface for external apps

Programs that run in app tabs ([ENGINE-BRIDGE.md](ENGINE-BRIDGE.md)) can test themselves end to end
in Deckhand's test mode, as the fake app does in `app-tab.sh`. For them these variables are a
**stable interface**: any change to one is noted in the release notes and here.

| Variable | Meaning |
|---|---|
| `DECKHAND_SCRIPT` | the script to play; turns test mode on |
| `DECKHAND_CMD` | replaces pi with this shell command (pi's arguments as `"$@"`) |
| `DECKHAND_DATA_DIR` | the data dir (workspace, app logs `apps/<tab_id>.log`, screenshots `apps/shots/`) |
| `DECKHAND_RUNTIME_DIR` | where the control socket lives (PROTOCOL.md §1); a fresh one per run keeps runs apart |
| `DECKHAND_SCALE` | the backing scale, 1 to 4, default 1 |
| `DECKHAND_QUIET` | `0` shows the window |

What an app's test can rely on:
- `command {...}` runs a command now. A long-running one (`app_call`, `app_screenshot`) is waited
  for, and its result is never missed. A script waits at most 120 s, or the command's own
  `timeout_ms` + 10 s, then fails with `TIMEOUT`.
- The app's hello reply is the first line Deckhand sends it (PROTOCOL.md §2).
- The exit status is 1 if an assert failed; the log has `ASSERT FAILED` or `TIMEOUT` lines and
  ends with `done: N asserts, M failed`.

`tests/scripts/app-calls.sh [ROUNDS] [CALLS]` checks these promises under load.

### Launch environment

`src/core/login_env.odin` runs at startup, before any thread.

**GUI launches import the login shell's environment.** A GUI launch is one whose parent is launchd
(Dock, Finder, Spotlight, `open`) or whose `PATH` is launchd's bare one; `DECKHAND_GUI_LAUNCH=1` or
`0` forces it, and test mode is never one without `DECKHAND_GUI_LAUNCH=1`. It runs
`$SHELL -i -l -c` (own session, stdin `/dev/null`, killed after 4 s), reads `env -0` and merges
(`login_env_compose`): the shell's values win, inherited variables it didn't print stay,
`PWD`/`OLDPWD`/`SHLVL`/`_`/`DECKHAND_*` never come from it, and `PATH` is the shell's order plus
inherited folders it lacks. With no answer: `PATH` plus the fallback folders that exist
(`DECKHAND_PATH_DIRS` in tests). Values are never printed or logged.

**Claude Code's session markers never pass through** (`claude_session_marker`: `CLAUDECODE`,
`CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_PID`, `CLAUDE_CODE_SESSION_*` and
the rest a running claude sets in its children). They leave the process environment at every
launch and `child_base_env` drops them again; otherwise a Deckhand opened from a Claude session
would start its Claude tabs as that session's children. A launch from inside a Claude session also
asks the login shell, and the parent's other Claude settings (`CLAUDE_CONFIG_DIR`,
`CLAUDE_EFFORT`…) are left out unless the shell sets them itself. `ANTHROPIC_*` always stay.
`DECKHAND_GUI_LAUNCH=0` keeps everything but the markers. A core launch also drops what Deckhand
sets for tabs (tokens, socket, tab ids: `core_launch_env`).

**Refresh shell environment** (`refresh_shell_env`) asks again on a worker and keeps the result for
new tabs, apps and jobs' default PATH; nothing calls `setenv` after startup. `PI_TAB_CMD` and
`CLAUDE_TAB_CMD` fall back to pi's managed install (`$PI_CODING_AGENT_DIR/bin`, `~/.pi/agent/bin`)
and Claude's (`~/.local/bin`, `~/.claude/local`), absolute folders only.

Deckhand's own sh scripts run as `$SHELL -l -c SCRIPT` for a POSIX login shell, and as
`/bin/sh -c SCRIPT` in the imported environment for a known non-POSIX one (fish, nushell, xonsh,
elvish, ysh, tcsh/csh, pwsh: `shell_is_posix`). Shell tabs still open `$SHELL -l`.

**Whether pi is installed** (`pi_installed`): a stat of the new tabs' PATH and pi's managed
install, else the login shell's `command -v pi` (on a worker, at most 10 s, pi never run). Until
the shell answers, pi counts as there; only a clean "no" says it is missing, so a pi that only
`.zprofile` adds is not reported missing after a timeout. `PI_CODING_AGENT_DIR` is read as pi
reads it; a custom `sessionDir` is not followed.

Unit tests: `src/core/login_env_test.odin` (fake shells, never yours).

### The scenes

`tests/scripts/run.sh SCRIPT` runs one script against a fake HOME and a fake pi; the other scenes
have their own shell scripts in `tests/scripts/`, each with a header saying what it checks.
[TESTING.md](TESTING.md#scenes) lists them by tier; `tests/scenes.txt` is the list the runner reads.

The layout audit (`src/layout_audit_test.odin`, in `./build.sh test`) checks that no text or icon
overlaps another or leaves its row, bar or column, at 800–2000 px, in every look, light and dark.

To see the project tree your own session store would give, without running the app (paths only,
from the newest session header of each folder):

```sh
python3 -I scripts/tree-dryrun.py > /tmp/store.tsv
DECKHAND_TREE_DRYRUN=/tmp/store.tsv odin test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.tree_dryrun
```
