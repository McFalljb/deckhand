# Harnesses: what Deckhand ships, what it needs, what is optional

Deckhand runs three agent harnesses, **pi**, **Claude Code** and **Codex** (phase 1:
[CODEX.md](CODEX.md)). For each it ships its own integration and loads it per tab, for that run
only, so a user installs the harness and nothing else. This document covers what each integration does, how it is loaded, how it steps back when
the user has something of their own, and how setup checks and installs the harnesses. §9 lists
what still needs a check against a real pi.

Contents: 1. [Origin](#1-origin-pi-kit) ·
2. [pi: loading from a path](#2-pi-loading-from-a-path) ·
3. [The pi integration](#3-the-pi-integration) ·
4. [Overlap: how Deckhand steps back](#4-overlap-how-deckhand-steps-back) ·
5. [Claude Code](#5-claude-code---plugin-dir) ·
5a. [Codex](#5a-codex-hooks-per-run) ·
6. [The harness manifest](#6-the-harness-manifest) ·
7. [Install and update](#7-install-and-update) ·
8. [pi-kit](#8-pi-kit) · 9. [Not verified](#9-not-verified-without-a-real-pi)

**Where the integrations live.** Both are in the app bundle: `Contents/Resources/pi` and
`Contents/Resources/claude-code` in `Deckhand.app`, and `Contents/Resources/integrations/{pi,claude-code}`
in the nested `Deckhand Core.app`. The core uses its own copy. A separate core runs from its
installed copy under `<data>/core/<version>-<sha12>/`, which is kept while any process (a pi
with one of its `-e` paths, a holder, a core) still runs from it, so live tabs keep their paths
across an update (`src/core/core_versions.odin`).

## 1. Origin: pi-kit

Every pi feature of Deckhand's (the bridge, panels, Atlas's desk tools, the browser and app-tab
tools, and the optional guardrails, shell and notes) came from
[pi-kit](https://github.com/McFalljb/pi-kit), and the extension API use is unchanged. §3's table
names each extension's pi-kit source. The Claude integration was always Deckhand's own
(`integrations/claude-code`, `--plugin-dir`).

## 2. pi: loading from a path

- **`pi -e, --extension <path>`** loads an extension file or directory for one run and can be
  repeated (pi docs/cli.md "Resources"). Nothing is written to settings (packages.md). The
  packages pi supplies to extensions (`pi-coding-agent`, `pi-tui`, `pi-ai`, `typebox`) are mapped
  in, so the integration needs no `node_modules`: it imports only those, `node:*` and its own files.
- **No env var or settings override exists.** `PI_CODING_AGENT_DIR` would swap the user's whole
  config. `-e` is the only way, and it fits.
- **Load order.** `-e` paths come first, then the user's configured and discovered extensions
  (resource-loader.js `mergePaths(cli, enabled)`); the same resolved path loads once.
- **Duplicate tool names stop pi.** Two extensions that register one tool (or flag) name *while
  loading* are an error (`Tool "x" conflicts with <path>`, resource-loader.js
  `detectExtensionConflicts`), and any extension error makes pi exit 1 before the session starts
  (main.js; pi 1.4.0 and 1.5.0). A tool registered later, at `session_start`, is never checked
  (pi docs/extensions.md "Dynamic Tool Loading"); at run time the first extension in load order that
  has the name wins (runner.js `getAllRegisteredTools`). Duplicate commands get suffixes
  (`/cmd:1`, `/cmd:2`), on every copy. Shortcuts: the last wins, with a warning. **Event handlers
  from every copy run.** Only built-in extensions can be "replaceable".
- So **two copies of the bridge would break**: both would connect as the tab and both would answer
  `pi.prompt` and `pi.attach` (prompts and comments sent twice). §4 is how that is avoided.
- **Minimum pi: 1.4.0** (`PI_MIN_VERSION`, `src/core/pi_integration.odin`). Deckhand's code relies on
  pi 1.4 behaviour (`--tools` allowlists, image prompts) and pi-kit, where this code was proven,
  pins 1.5.0 (recommended). `-e` itself is much older. **Still to confirm with one real-pi run on
  1.4.0** (§9).

## 3. The pi integration

`integrations/pi/` (its [README](../integrations/pi/README.md)), copied into the bundles by
`build.sh` and `scripts/bundle-app.sh` (`build/pi` beside a bare build). `DECKHAND_PI_INTEGRATION`
overrides it in test mode only; test mode is itself set by the environment, the same trust
boundary as `DECKHAND_CMD`. It is watched like pi's own extensions: a change shows the reload bar
over pi tabs. Tests: `node --test` on `integrations/pi/test/*.test.ts`, run by `./build.sh test`;
they never start pi.

**Layout.** One folder per extension under `extensions/`, shared code in `lib/`, and
`extensions.json`, the manifest: each extension's name, whether it is required, and what it
does, in load order.

| Extension | From pi-kit | Active when |
|---|---|---|
| `bridge` | `extensions/desk-bridge` (+ `protocol.ts` → `lib/protocol.ts`) | `DECKHAND_SOCKET` + `DECKHAND_TOKEN`, TUI |
| `desk` | `extensions/desk` (+ `state.ts`, `commands.ts`, `app.ts` → `lib/`) | also `DECKHAND_CONTROL_TOKEN` (Atlas) |
| `browser` | `extensions/desk-browser` (+ `browser.ts` → `lib/`) | `DECKHAND_SOCKET` + `DECKHAND_TOKEN`, TUI |
| `panels` | `extensions/sidebar` (its data side; `rows.ts` → `lib/`) | `DECKHAND_SOCKET` + `DECKHAND_TOKEN`, TUI |
| `guardrails` (optional, on) | `extensions/guardrails` (`core.ts` → `lib/guardrails.ts`) | always (every mode); read-only with `PI_KIT_READONLY=1` |
| `shell` (optional, on) | `extensions/shell` (`lines.ts` → `lib/shell.ts`) | always but read-only sessions |
| `notes` (optional, off) | `extensions/notes` | interactive and print runs, not pi-subagents children |
| `skills/deckhand-desk` (Atlas) | `skills/desk` | `--skill`, Atlas only |

`lib/text.ts` carries the helpers the rows need from pi-kit's shell and guardrails (`clip`,
`redact`, `duration`).

**Loading** (`src/core/pi_integration.odin`). Every pi start (`start_pi`: a new tab, session or chat,
Atlas, a restore, Restart, a dead tab's restart, a hot-reload restart) gets one
`-e <dir>/extensions/<name>` per required extension, and per optional one turned on
(`pi_extension_on`: the user's choice on the Settings page (Coding agents › pi), `set_pi_extension`,
else the manifest's `default`), in the manifest's order, before pi's own arguments. Each pi tab
records which optional ones it started with; a later change marks it for the restart bar ("pi
extensions changed — Restart N idle tabs"), since `-e` is fixed for a process's life. Atlas also
gets `--skill <dir>/skills/deckhand-desk`. pi 1.5.0 lists `--skill` paths after the user's and
packages' skills (resource-loader.js `mergePaths([...cli, ...enabled], additionalSkillPaths)`) and
keeps the first skill of a name, so ours has its own name: one named `desk` would lose to pi-kit's
(test/optional.test.ts checks this with pi's own `loadSkills`, `PI_PACKAGE_DIR`). A pi-kit `desk`
skill may still be listed beside it; the Atlas prompt names ours. Jobs run `pi --mode json` and get
none: the required parts are inert there (each starts only in the interactive TUI), and the
optional ones are for pi tabs, not jobs (the Settings rows say so). A pi known to be older than
1.4.0 (its version read from its package on disk, never by running it) gets none either: its tabs show a bar ("pi X is older than
1.4.0…", Copy update command, Dismiss) and so does the setup sheet. Without the integration in the
build, pi starts without it.

**Read-only.** Read-only chats pass `--tools read,grep,find,ls,desk_show --exclude-tools mcp__*
--no-mcp` and read-only jobs the same without `desk_show`, which keeps every other extension tool
from the model. The bridge needs none: status, waits,
comments and reload are event hooks and a command, so they keep working. `PI_KIT_READONLY=1` also
keeps `browser` from registering `app_open`, `app_restart` and `app_close`, keeps `shell` from
registering at all, and turns the optional `guardrails` read-only (blocks `edit`, `write` and
mutating `bash`, plus secret redaction of what `read` returns). Its read-only `bash` guard is dead
code in Deckhand: `--tools` already makes `bash` (and `edit`, `write`) uncallable in read-only
chats. Guardrails follows its toggle in read-only chats too: the allowlist is the boundary there,
not it.

## 4. Overlap: how Deckhand steps back

1. **pi-kit's desk extensions: a namespace switch.** The bundled copy reads `DECKHAND_SOCKET`,
   `DECKHAND_TOKEN`, `DECKHAND_CONTROL_TOKEN` and `DECKHAND_SHOTS_DIR`, moves them out of
   `process.env` at load (`adoptEnv`, `lib/protocol.ts`), keeps tokens under
   `Symbol.for("deckhand.*")`, uses `deckhand:*` for its internal events (`deckhand:command`,
   `deckhand:control:command`, `deckhand:control`, `deckhand:tab`) and `/deckhand-reload`. A pi
   tab never gets `PI_DESK_SOCKET`, `PI_DESK_TOKEN` or `PI_DESK_CONTROL_TOKEN` (`socket_pi_env`),
   and pi-kit's desk-bridge, desk-browser and desk switch on only with those, so **an installed
   pi-kit goes inert by itself**: no duplicate tools, no second bridge, nothing to edit. The
   internal event names differ too: pi-kit's bridge and desk register `kit:desk:command` and
   `kit:desk:control:command` listeners at load, active or not, and its bridge registers
   `/desk-reload`. App tabs ([ENGINE-BRIDGE.md](ENGINE-BRIDGE.md)) and Claude tabs
   ([CLAUDE.md](CLAUDE.md) §3) have their own variables.
2. **The event bus as a public contract.** The bridge keeps emitting `kit:desk:mode` and accepting
   `kit:desk:panels` (now merged by panel name, so several producers can publish). pi-kit's
   sidebar keeps handing its panels over and doesn't draw its column in Deckhand. The mode is said
   again after every extension's `session_start` and on `kit:desk:mode?` (PROTOCOL.md §4), since
   the bridge loads first (`-e`) and pi-kit's sidebar listens only once its own `session_start` ran.
3. **Capability claims.** At session start `panels` emits `deckhand:capabilities?`
   `{from: "deckhand", capabilities: ["panels:todos", "panels:subagents"]}`. An extension that
   provides one itself answers `deckhand:capabilities` `{capability, owner, version}` (then or any
   time later), and Deckhand's producer leaves that panel to it, first publishing it once empty
   (the bridge keeps one copy per panel name, the last one any producer published, and the claimant
   may publish nothing). Another
   producer that publishes the panel with rows on `kit:desk:panels` (pi-kit's sidebar does) takes
   it over the same way; an empty one (`rows: []`) takes nothing over.
4. **Hooks of the optional extensions.** pi runs every copy's hooks, so two guardrails would ask
   twice for one command and two notes would remind twice. Deckhand's `guardrails` steps back
   (no hooks act; its `/guardrails` says so) when an extension claims `guardrails`, or when another
   `/guardrails` comes from pi-kit's own guardrails entry file (`getCommands()` `sourceInfo.path`
   is `…/extensions/guardrails/index.ts` or `readonly.ts` with pi-kit's `core.ts` beside it:
   `isKitGuardrails`), since pi-kit's makes no claim; it says so once at session start. Any other
   `/guardrails` leaves ours on. Deckhand's `notes` sends its reminder one turn after
   it is due, and drops it, for good, when pi-kit's `pi-kit-notes` reminder reached the session
   branch in between (or on a `notes` claim). Deckhand's `shell` steps back whole when a tool already loaded
   has one of its names (pi-kit's shell, or anyone's; item 5 below), and uses its own widget, status
   and notice keys (`deckhand-shell`). Tested next to pi-kit's own files (`test/optional.test.ts`, `PI_KIT_DIR`).
5. **Tool and command names.** No bundled extension registers a tool or flag while loading, so a
   user's extension with the same names can never stop pi (`test/conflicts.test.ts`, against a
   model of pi's rules from its source, `test/pi-rules.ts`). The required `desk` and `browser`
   register theirs at `session_start` and win by load order (`-e` first). The optional `shell`
   registers its tools at `session_start` only when `pi.getAllTools()` has none of their names;
   otherwise the other copy is the user's shell, ours registers nothing and publishes nothing (the
   Shells panel shows the other's `kit:shell:rows`), and a notice in the tab says
   `Deckhand's shell stepped back: … already loaded from <path>`. `/shells` and `/guardrails` are
   registered only when no copy of the name is loaded (`pi.getCommands()`), so the user's keeps its
   plain name. The decision happens inside pi, from what pi actually loaded (settings, packages,
   project `.pi`, `-e`), so Deckhand never has to re-implement pi's resolution of them.
6. **A static view in setup** (§6): Deckhand reads `~/.pi/agent/settings.json` `packages` (read
   only, already watched by hot reload) to tick the recommended packages the user already has.

## 5. Claude Code: `--plugin-dir`

Source: code.claude.com/docs/en/plugins/loading.md, "Name conflicts". The integration itself is
described in [CLAUDE.md](CLAUDE.md).

- `--plugin-dir` loads the folder as `<name>@inline` for that session only, in place; nothing goes
  into `~/.claude`.
- A plugin the user installed with the same name is **silently replaced** for that session.
  Outside Deckhand the installed copy is inert (its hooks exit 0 without `DECKHAND_*`).
- It can fail to load: managed settings that name the plugin id win; an admin can turn the flag
  off; `"<name>@inline": false` disables it. Deckhand's "hooks silent" bar catches all of these.
- **Minimum Claude Code 2.1.295** (`CLAUDE_MIN_VERSION`): OSC 7501 and hook `onFailure`.

## 5a. Codex: hooks per run

Codex has no plugin folder to load from a path. Deckhand passes its hooks on the command line for
that run (`-c hooks.<Event>=[…]`, the bundled `deckhand-cli` by absolute path) and trusts exactly
those for that run in the same layer (`-c hooks.state={…}` with each hook's `trusted_hash`,
Codex 0.167.2's recipe), so Codex shows no "Hooks need review" dialog for them and the user's own
hooks keep their own trust. Nothing goes into `~/.codex`; `CODEX_HOME` is never set; the user's own
settings (model, sandbox, approvals, profiles, `notify`, folder trust) apply untouched, and
`--no-daemon` keeps the TUI and its hooks in the tab's own process tree. A Codex that changes the
recipe shows its review dialog for Deckhand's hooks; status still works from its OSC 7501 and the
tab's bar explains. The details: [CODEX.md](CODEX.md).

- **Minimum Codex 0.163.0** (`CODEX_MIN_VERSION`): OSC 7501 program status. Older ones are not
  started.
- Codex starts its session at the first prompt: SessionStart (the session id, the row) comes then.

## 6. The harness manifest

One data table, `HARNESS_MANIFEST` in
[`src/core/harness_manifest.odin`](../src/core/harness_manifest.odin), one row per item; a new harness adds
rows (and its `Harness` value), not code paths. The setup sheet's first step and Settings →
Coding agents draw it (`src/ui_harness.odin`). Setup reads the user's harness config and never
writes it.

**A row** (`Harness_Row`): `harness`; `id` (stable: the state snapshot, Settings rows, the
runner); `name`; `kind` (`Harness`, `Built_In`: Deckhand's own, ships in the app, never installed,
or `Third_Party`); `need` (`Required` or `Recommended`); `min_version`; `detect` (`Binary`,
`Integration`, `Pi_Package` with `detect_arg` the npm name), always by looking, never by running;
`install` (the command when it is missing; "" for built-ins); `update` per install layout (§7) or
`update_any` for a third-party item; `why` (one line); `source` (where the command comes from).

| id | Harness | Kind | Need | Min | Detected by | Install | Source |
|---|---|---|---|---|---|---|---|
| `pi` | pi | harness | required | 1.4.0 (`PI_MIN_VERSION`) | `pi` on the tabs' PATH or in `$PI_CODING_AGENT_DIR/bin`, `~/.pi/agent/bin`; version from its `package.json` | `curl --proto '=https' --proto-redir '=https' -fsSL https://pi.dev/install.sh \| sh` | pi README "Getting started", `docs/quickstart.md` |
| `pi-integration` | pi | built in | required | (pi 1.4.0) | `integrations/pi` in the build | — | §3 |
| `pi-subagents` | pi | third-party | recommended | 0.84.0 (GHSA-6v8j-6w28-2w8r) | `npm:pi-subagents…` in `~/.pi/agent/settings.json` `packages`; version from `~/.pi/agent/npm/node_modules/pi-subagents`, else the spec | `pi install npm:pi-subagents@0.84.0` | npmjs.com/package/pi-subagents; pin: the first version with the GHSA-6v8j-6w28-2w8r fix (nicobailon/pi-subagents advisory); `pi install`: pi `docs/cli.md` |
| `rpiv-todo` | pi | third-party | recommended | — | `npm:@juicesharp/rpiv-todo…` in `packages` | `pi install npm:@juicesharp/rpiv-todo@2.15.0` | npmjs.com/package/@juicesharp/rpiv-todo; pin: a version in daily use; no advisories (juicesharp/rpiv-mono) |
| `pi-ask-user` | pi | third-party | recommended | — | `npm:pi-ask-user…` in `packages` | `pi install npm:pi-ask-user@0.17.0` | npmjs.com/package/pi-ask-user; pin: a version in daily use; no advisories (edlsh/pi-ask-user) |
| `pi-web-access` | pi | third-party | recommended | 0.24.1 (GHSA-8phw-6qw6-xhq6) | `npm:pi-web-access…` in `packages` | `pi install npm:pi-web-access@0.47.0` | npmjs.com/package/pi-web-access; pin: npm's latest on 2026-11-09; minimum: the GHSA-8phw-6qw6-xhq6 fix (nicobailon/pi-web-access advisory, ≤ 0.24.0) |
| `rpiv-btw` | pi | third-party | recommended | — | `npm:@juicesharp/rpiv-btw…` in `packages` | `pi install npm:@juicesharp/rpiv-btw@2.15.0` | npmjs.com/package/@juicesharp/rpiv-btw; pin: a version in daily use; no advisories (juicesharp/rpiv-mono) |
| `claude` | Claude Code | harness | required | 2.1.295 (`CLAUDE_MIN_VERSION`) | `claude` on the tabs' PATH or in `~/.local/bin`, `~/.claude/local`; version from where it links (`claude_version_of`) | `curl --proto '=https' --proto-redir '=https' -fsSL https://claude.ai/install.sh \| bash` | code.claude.com/docs/en/setup, "Native Install (Recommended)" |
| `claude-plugin` | Claude Code | built in | required | (Claude 2.1.295) | `integrations/claude-code` in the build | — | §5 |
| `codex` | Codex | harness | required | 0.163.0 (`CODEX_MIN_VERSION`) | `codex` on the tabs' PATH (npm's global bin); version from the npm package's `package.json` next to where it links, or Homebrew's `Caskroom/codex/<v>/`; signed in: `codex login status` (exit 1 = signed out, a note), run on a worker | `npm install -g @openai/codex@latest` | github.com/openai/codex README |

Why these: pi-subagents and rpiv-todo feed the bundled `panels` extension's Subagents and Todos
panels (§3); without them those panels stay empty. pi-ask-user (an `ask_user` tool), pi-web-access
(web search and fetching) and rpiv-btw (`/btw` side questions) are the tools we recommend with pi.
Each install is pinned to an exact version; advisories were checked on GitHub (the global advisory
database and each package's repository) when the pin was set. Claude Code needs nothing
third-party: its plugin is sh and Deckhand's own CLI and loads with every Claude tab, so its
Recommended list is empty and the sheet says "Nothing else to install". Codex needs nothing
either: its hooks are Deckhand's own CLI, passed per run (§5a).

**States** (`Harness_Item_State`) and what each shows:

| State | When | Shows |
|---|---|---|
| `missing` | a harness not found; a third-party item not in pi's own `settings.json` `packages` (a project's `.pi/settings.json` listing is only noted: a cloned repo never makes a package found) | Not installed, the install command, **Install**. A missing harness is one collapsed line |
| `too_old` | a known version below `min_version`, pi's own or a project's `.pi/settings.json` npm pin (that one: a note to change it there, nothing run) | the version, the update command, **Update** (runnable layouts) or **Copy** |
| `ok` | found, new enough, or its version unknown (never "too old" on a guess) | ✓, the version and layout |
| `unchecked` | a pi package from a `git:` or local-path source in pi's own settings: its version cannot be checked | ? Found, version not checked; no Install (another copy would be a second one) |
| `built_in` | Deckhand's own integration, in the build | ✓ Built in |
| `not_loaded` | in the build but pi is older than 1.4.0, or not in the build | why |
| `needs_harness` | a third-party item whose harness is missing or too old | Needs pi first |

The checklist is looked at again when the sheet opens, on Settings' **Refresh**, after Refresh
shell environment, and when a run ends (then the cached `pi_installed` and `claude_installed`
answers are dropped too, and pi's version probed again). Test mode never looks at PATH
(`detect_path`), only the fake HOME's install folders.

**Other machines** (Machines over SSH, [GUIDE.md](GUIDE.md)). Each machine's core checks its own
harnesses with this manifest. This Mac shows that machine's checklist read-only under Settings ›
Machines (`<machine>: <item>`, its state and the command to run there, with **Copy**; at most 16
rows, the text cleaned: `machines[].checklist` in the state snapshot, PROTOCOL.md §5a). No harness is
installed on another machine from here (`machine_install` installs only Deckhand's core). A new session on another machine offers only the
harnesses its checklist lists as found (`ok`, `too_old` or `unchecked`; pi alone before its
checklist arrives) and runs with that machine's own accounts and folders, never this Mac's
(`machine_harnesses` in `src/core/harness.odin`).

## 7. Install and update

`src/core/harness_install.odin`. Deckhand works out a harness's
layout from where its binary links to, without running it (`install_layout`).

| Layout (by real path) | pi | Claude Code | Runs after a click? |
|---|---|---|---|
| official installer (pi: under `~/.pi/agent`; Claude: `…/claude/versions/`) | `pi update --self` | `claude update` | yes |
| npm global (`/node_modules/`, Homebrew's node too) | `pi update --self` | `npm install -g @anthropic-ai/claude-code@latest` | yes, when its `node_modules` is writable (no `sudo`) |
| Homebrew (`/Caskroom/`, `/Cellar/`) | none named (no pi formula is known) | `brew upgrade --cask claude-code` (or `claude-code@latest`) | Claude: yes; pi: shown only |
| bun (`/.bun/`, `/install/global/node_modules/`) | `pi update --self` | `bun add -g @anthropic-ai/claude-code@latest` | yes |
| pnpm (`/pnpm/`, `/.pnpm/`) | `pi update --self` | `pnpm add -g @anthropic-ai/claude-code@latest` | yes |
| yarn (`/yarn/`, `/.yarn/`) | `pi update --self` | none named | shown only |
| nix (`/nix/store/`) | `nix profile upgrade pi` (pi `docs/quickstart.md`) | none named | shown only |
| mise (`/mise/installs/`) | none named | none named | shown only |
| unknown | `pi update --self` | `claude update` | shown only |

Codex (`install_layout(.Codex, …)`): npm global `npm install -g --prefix <prefix> @openai/codex@latest`,
Homebrew `brew upgrade --cask codex`, bun and pnpm `add -g @openai/codex@latest`, all after a click
as above; anything else (yarn, nix, mise, unknown) none named, shown only.

The table gives the command's shape; the one shown and run is aimed at the copy Deckhand detected
(`harness_plan`): the detected binary by absolute path (`/Users/me/.pi/agent/bin/pi update
--self`, `/Users/me/.local/bin/claude update`), and for brew, npm, bun and pnpm the package manager
next to that copy's prefix (`<prefix>/bin/npm install -g --prefix <prefix> …`; a prefix it cannot place shows as `PREFIX`, `<prefix>/bin/brew`,
`<bun root>/bin/bun`, `<PNPM_HOME>/pnpm`), never whichever one the login shell finds first. No
package manager there, or an npm prefix (`lib/node_modules` and `bin`) that is not writable: shown
only. The pm's folder goes first on PATH for the run, so `pi update --self` uses it too.

`pi update --self` updates pi only (not its packages) and handles pi's own installer, npm, bun,
pnpm and yarn; a user's `selfUpdateCommand`/`PI_SELF_UPDATE_COMMAND` runs through it.
`claude_update_command` (the Claude version bar) takes its command from the same table.
A third-party pi package updates with `<detected pi> install npm:<name>@<pin>`, whatever pi's
layout. The version bar keeps bare names (`harness_update_bare`), as a user types them.

**Running one.** Only the user's click on **Install** or **Update**, one run at a time, in a
terminal on the setup sheet's first step: the command shows before the click (on the row) and at
the top of the output; the keyboard is the terminal's while it runs and shows (⌃C stops it; ⌘Q still works;
Enter is ignored for a second after the click, so the habitual Enter cannot answer a prompt);
the sheet is modal until it ends: nothing moves the keyboard off it, an agent or the user's own
menus (`set_focus`, closing the sheet, a job sheet are refused; anything else is undone on the next
frame, back on the run's step), so its terminal and ⌃C stay reachable. Settings' **Install…**/**Update…** open that step. The
script (`harness_run_script`) runs in the login shell (`/bin/sh` for fish and co., as Deckhand's
other scripts), sets `pipefail` where the shell has it, and for a harness install first stops if
`command -v <name>` or the installer's own folder (`$PI_CODING_AGENT_DIR/bin`, a leading `~`
expanded as pi does) finds one: never a second copy. An update first checks that the detected
binary is still there and still links to the same file, by `/bin/realpath` (one on PATH only if
that is missing), with the login shell's own PATH (the run's PATH is set just before the command);
no realpath, no answer from it, or another file: it refuses and prints both paths. `command -v`
finding another copy is only noted. Never `sudo`:
the run's PATH starts with a temp folder whose `sudo` prints "Deckhand doesn't run sudo; run this
yourself: <command>" and exits 1, and `SUDO_ASKPASS=/usr/bin/false`; if that folder or its
executable `sudo` cannot be made, the run does not start. Leftover folders go at quit (this
Deckhand's) and at start (those whose Deckhand is gone, owned by the user). (A tool that calls
`/usr/bin/sudo` by absolute path gets past the shim and then asks in the terminal, where nothing
answers for the user.) The curl installers add `--proto '=https' --proto-redir '=https'` to the
official command.
`pi install` writes pi's own `settings.json`: that is pi's package manager doing it on the user's
click; Deckhand itself only reads it.

**Test mode** never runs a real install: `DECKHAND_INSTALL_CMD` stands in and gets the item's id and
the exact command as `"$@"` (`tests/scripts/fake-install.sh`); without it the run prints a refusal
and exits 127, and Deckhand's stderr says "test mode: refusing to run the real install command".
Afterwards the existing "restart N idle tabs" bars take over for tabs on the old version.

## 8. pi-kit

For people who already have pi-kit installed: its guardrails, shell, notes and sidebar work next
to the bundled integration (§4). pi-kit's desk-bridge, desk and desk-browser go inert in Deckhand (§4
item 1) and can be removed from pi-kit. Atlas memory ([ATLAS.md](ATLAS.md) §6) is planned as
part of Deckhand.

## 9. Not verified without a real pi

The integration's tests never start pi. These still need a check against a real pi:

- the bundled extensions loading from `-e <dir>` (a folder with `index.ts`, next to a
  `package.json` with `"type": "module"`), on pi 1.5.0 and on 1.4.0 (the minimum);
- the bridge connecting and reporting with `DECKHAND_*` (`bridge-e2e.sh`, `home-e2e.sh`);
- `-e` extensions reloading on `/deckhand-reload` (the code suggests yes);
- an installed pi-kit next to it: its desk extensions inert, its sidebar handing panels over
  (and not flashing its column before the bridge's handshake);
- whether a Homebrew formula for pi exists;
- the optional extensions under a real pi: shell's tools, widget and Shells panel, guardrails'
  ask dialog, notes' reminder timing (one turn after pi-kit's would be), and, next to an
  installed pi-kit, the step-backs (`getCommands` names for `/guardrails`, pi-kit's reminder on
  the branch before `turn_start`) and pi's conflict reports for the shell tools;
- Atlas with `--skill`: `deckhand-desk` listed (pi's `loadSkills` is tested, the CLI path is not).
