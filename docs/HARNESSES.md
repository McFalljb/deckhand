# Harnesses: what Deckhand ships, what it needs, what is optional

Deckhand runs three agent harnesses: **pi**, **Claude Code** and **Codex**. For each it brings its
own integration and passes it per run, so the user installs only the harness and Deckhand itself
writes nothing into the harness's config (setup's **Install** runs the harness's own installer, §7). This document covers what each integration does, how it is
loaded, how it steps back when the user has something of their own, and how setup checks and
installs the harnesses. The Claude and Codex tabs themselves: [CLAUDE-TABS.md](CLAUDE-TABS.md),
[CODEX.md](CODEX.md).

| | pi | Claude Code | Codex |
|---|---|---|---|
| Deckhand's part | `integrations/pi`: extensions, Atlas's skill (§3) | `integrations/claude-code`: a plugin (hooks, the `deckhand` command, a skill) (§5) | none on disk: hooks and an MCP server, both the bundled CLI (§5a) |
| Loaded with | `-e <dir>` per extension | `--plugin-dir <dir>` | `-c hooks.…`, `-c hooks.state=…`, `-c mcp_servers.deckhand=…` |
| Minimum | 1.4.0 (`PI_MIN_VERSION`) | 2.1.295 (`CLAUDE_MIN_VERSION`) | 0.163.0 (`CODEX_MIN_VERSION`) |
| Older than that | starts without the integration; a bar with the update command | starts; status from the hooks only; a bar saying how to update | from 0.157.0 (`--no-daemon`): starts plain (no hooks, MCP server or token; nothing typed into it); a bar saying how to update. Older: not started; the tab says how to update |
| Version read from | its `package.json`, never run | where `claude` links, never run | its install's files; else `codex --version` under a throwaway `CODEX_HOME` |
| Accounts | — | config folders ([CLAUDE-TABS.md §1b](CLAUDE-TABS.md#1b-accounts)) | Codex homes ([CODEX.md §6a](CODEX.md#6a-accounts)) |
| On another machine | yes | yes | when that machine's core starts Codex tabs (§6) |
| Continue this conversation on <machine> | yes, pi 1.4.0 or later there | not yet ([#115](https://github.com/McFalljb/deckhand/issues/115)) | not yet (#115) |

Contents: 1. [Origin](#1-origin-pi-kit) ·
2. [pi: loading from a path](#2-pi-loading-from-a-path) ·
3. [The pi integration](#3-the-pi-integration) ·
3a. [Antigravity in pi tabs](#3a-antigravity-in-pi-tabs-preview) ·
4. [Overlap: how Deckhand steps back](#4-overlap-how-deckhand-steps-back) ·
5. [Claude Code](#5-claude-code---plugin-dir) ·
5a. [Codex](#5a-codex-hooks-per-run) ·
6. [The harness manifest](#6-the-harness-manifest) ·
7. [Install and update](#7-install-and-update) ·
8. [pi-kit](#8-pi-kit) · 9. [Not verified](#9-not-verified-without-a-real-pi)

**Where the integrations live.** In the app bundle: `Contents/Resources/pi` and
`Contents/Resources/claude-code` in `Deckhand.app`, and `Contents/Resources/integrations/{pi,claude-code}`
in the nested `Deckhand Core.app`. Codex's hooks and MCP server are the bundled CLI, by its
absolute path ([CLAUDE-TABS.md](CLAUDE-TABS.md) §1, "Plugin and CLI paths"). The core uses its own copy. A separate core runs from its
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
  pins 1.5.0 (recommended). `-e` itself is much older. Another machine needs it too to take a
  conversation continued from this Mac (`pi --fork` there). **Still to confirm with one real-pi run
  on 1.4.0** (§9).

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
| `antigravity` | Deckhand's own (ACP client after t3code's; `acp.ts`, `agy.ts`, `agy-accounts.ts`, `agy-login.ts`, `antigravity.ts` in `lib/`) | an agy binary found (§3a); every mode |
| `guardrails` (optional, on) | `extensions/guardrails` (`core.ts` → `lib/guardrails.ts`) | always (every mode); read-only with `PI_KIT_READONLY=1` |
| `shell` (optional, on) | `extensions/shell` (`lines.ts` → `lib/shell.ts`) | always but read-only sessions |
| `notes` (optional, off) | `extensions/notes` | interactive and print runs, not pi-subagents children |
| `skills/deckhand-desk` (Atlas) | `skills/desk` | `--skill`, Atlas only |

`lib/text.ts` carries the helpers the rows need from pi-kit's shell and guardrails (`clip`,
`redact`, `duration`).

**Loading** (`src/core/pi_integration.odin`). Every pi start (`start_pi`: a new tab, session or chat,
Atlas, a restore, Restart, a dead tab's restart, a hot-reload restart) gets one
`-e <dir>/extensions/<name>` per required extension, and per optional one turned on
(`pi_extension_on`: the user's choice on the Settings page (Coding agents › pi; `set_pi_extension`,
this Mac's user only), else the manifest's `default`), in the manifest's order, before pi's own arguments. Each pi tab
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

**Read-only.** Read-only jobs (`access: read`) pass `--tools read,grep,find,ls --exclude-tools
mcp__* --no-mcp`, which keeps every extension tool from the model. `PI_KIT_READONLY=1` also keeps
`shell` from registering at all, and turns the optional `guardrails` read-only (blocks `edit`,
`write` and mutating `bash`, plus secret redaction of what `read` returns). Chats are full pi (the
former **Start chats read-only** is gone): what a chat's agent may do is the chats folder's
`AGENTS.md`'s to say.

## 3a. Antigravity in pi tabs (preview)

`extensions/antigravity` gives pi one provider per Antigravity account, backed by the user's own
Google Antigravity CLI over ACP (`agy acp`: JSON-RPC 2.0, one message per line on stdio), as t3code
drives it. agy runs the whole turn (model, tools, system prompt) and keeps the conversation and the
sign-in; pi keeps its transcript. Deckhand never reads agy's credentials or calls Google.

- **Without agy, only `/antigravity`.** `findAgy` (`lib/acp.ts`): the `agyPath` the user set with
  `/antigravity path` in `accounts.json` (used only when it is an absolute path to an executable
  file, never looked up; else ignored, and the status says so), else `agy` on `PATH`
  (only that name, as t3code: `antigravity` may be the Antigravity IDE's launcher; another name
  needs `/antigravity path`); a few stats at load. No environment variable picks the binary (what Deckhand ships reads
  only the variables `scripts/check-env-reads.py` lists). Not found: the extension registers
  only `/antigravity`, which says where to get agy (1.5.12 or newer) and offers `/antigravity path`;
  no provider, hook, status line or output. Found (at load, or when `/antigravity path` sets a path
  later in the session): the accounts' providers, `/antigravity-login`, and hooks for
  `session_start`, `session_shutdown` and `session_before_compact` (pi takes providers, hooks and
  commands after load; the command's context stands in for the `session_start` already past). No
  tools or flags.
- **Handshake** (`lib/agy.ts`): `initialize` as `deckhand-pi` (v2's fields and v1's
  `clientInfo`/`clientCapabilities`: agy answers `protocolVersion: 2` in the v1 shape), no fs and
  no terminal capability; agy older than 1.5.1 (`agentInfo.version`) is refused; `session/new`
  (or `session/resume`), agy's `default` mode, then the model and thinking by config option
  (`session/set_config_option`, `model` and the `thought_level` category). `authenticate` with
  the account's method always comes before `session/new`, as in t3code (agy picks its credential
  source from it). A sign-in link on agy's output, auth_required (-32000) or "No browser is
  available here" (-32603) mean "not signed in", and the error names the account's command.
- **Accounts** (`lib/agy-accounts.ts`, after t3code's provider instances): `accounts.json` in
  `<data dir>/antigravity` (macOS `~/Library/Application Support/Deckhand`, or `pi-desk` when only
  that exists; Linux `$XDG_DATA_HOME/deckhand` or `~/.local/share/deckhand`; tests set `HOME`)
  holds names, methods (`oauth-personal`, `oauth-business`, `gemini-api-key`, `agent-platform`),
  GCP project/location and agy's path when set, mode 0600, never a secret. The account `default` is
  implicit (a Google account). Each account is a provider (`antigravity`, `antigravity-<name>`)
  and a profile, `profiles/<name>` (0700): agy runs as `agy acp --gemini-dir <profile>
  --app-data-dir antigravity-acp`, with the method in `antigravity-acp/settings.json`, and the
  user's `~/.gemini` `config/skills`, `antigravity-cli/skills`, `config/skills.json`, `AGENTS.md`
  and `GEMINI.md` linked in. No automatic switching, rotation or fallback between accounts.
- **agy's environment** (`agyEnvFor`): pi's, without t3code's list (`GEMINI_API_KEY`,
  `GOOGLE_API_KEY`, `GOOGLE_CLOUD_*`, `GOOGLE_GENAI_USE_VERTEXAI`,
  `GCLOUD_PROJECT`, `CLOUDSDK_CORE_PROJECT`, `AGY_ACP_*`, `GEMINI_HOME`, `BROWSER`, …, matched
  case-insensitively), any other `GOOGLE_*` and `DECKHAND_*`; then `GEMINI_HOME` (the profile),
  `AGY_ACP_FORCE_FILE_STORAGE=1`, `AGY_CLI_DISABLE_AUTO_UPDATE=true`, `TMPDIR` (the process's
  own folder, below), and the account's key as `GEMINI_API_KEY` (`gemini-api-key`) or
  `GOOGLE_API_KEY` (`agent-platform`). A Google-account (`oauth-personal`) agy also gets
  `SSH_CONNECTION=127.0.0.1 0 127.0.0.1 0`, as in t3code: agy 1.5 ignores file storage and keeps
  Google sign-ins in one OS keyring entry for every profile unless it believes it runs over SSH, so
  without it two accounts would share one sign-in; over "SSH" it signs in by the pasted code
  (`--login`). `BROWSER` is not set (t3code points it at a helper; here agy's link is shown in pi).
  `GOOGLE_APPLICATION_CREDENTIALS`, `CLOUDSDK_CONFIG` and `CLOUDSDK_AUTH_*` reach only an
  `agent-platform` account with a project and no key (Application Default Credentials are its
  sign-in); t3code drops the first for every method and keeps `CLOUDSDK_*`.
- **agy's processes**: each gets its own TMPDIR, `antigravity-acp/tmp/<pi's pid>-<random>` (0700;
  agy unpacks its runtime there), marked with agy's pid and removed when it ends. Before each
  launch, folders whose pi and agy processes are both gone are removed (t3code's
  `retireAntigravityRuntimeTempDirs` removes all of them, as one process owns its profile; pi
  processes share one). Closing agy: its stdin first, SIGTERM if it is still there after 1 s,
  SIGKILL after 5 s more. agy's own children are not killed as a group (nor in t3code): an open
  risk once approvals let agy run commands.
- **Mode and model, fail closed**: a session (new or resumed) that reports no mode option and no
  modes, or whose mode option does not take `default`, is refused before any prompt; so is a model
  other than `default` when agy offers no model option.
- **API keys**: `gemini-api-key` and key-based `agent-platform` accounts use pi's own credential
  store: the provider's `auth.apiKey.login` asks with pi's masked secret prompt (`/login
  antigravity-<name>`), pi keeps the key in `~/.pi/agent/auth.json` (0600) like every API key, and
  passes it to the provider per turn; it reaches agy only in its process environment. `/logout`
  removes it.
- **`/antigravity`** (`remove` needs `--yes` without a UI; accounts.json changes are made under a
  lock file and read again inside): the status (agy's path and version from an `initialize`, each account's
  provider, method, sign-in state and model count; "signed in" is the existence of agy's
  `acp_token.json`, which is never read, or a key in pi's store) and, with a UI, a menu;
  `add <name> [method]`, `login`, `logout` (agy's ACP `logout`, when advertised; the history
  stays), `remove` (confirmed; its provider unregistered and its profile deleted; `default` stays)
  `models [name]` and `path [/abs/agy]` (sets agy's path after the same check, or with no
  argument clears it; every account's provider then runs the new binary). `/antigravity-login` is
  the default account's sign-in. Gemini Enterprise
  signs in by agy's own browser flow (`authenticate`, its link shown, up to 5 minutes).
  `SUBSCRIPTION_REQUIRED` from agy becomes a message that links https://antigravity.google/docs/plans.
- **Approvals: none yet.** Every `session/request_permission` is answered `reject_once` (else
  `cancelled`), every ask_question (`interaction_…`) and elicitation declined, `fs/*` and
  `terminal/*` "method not found". Granting approvals is a later, separately reviewed change.
- **Sign-in** (`lib/agy-login.ts`): `agy acp --login` in the account's profile; the accounts.google.com link is checked
  and shown, the pasted code (or the callback page's URL for this sign-in) is checked and written
  to agy's stdin as one line; agy stores the credential.
- **Models**: `<provider>/default` (agy's own choice) always; the account's from a session's
  `model` option (a throwaway session on `/antigravity models` and after sign-in; every real
  session too), in memory only.
- **Turns** (`lib/antigravity.ts`): one agy process and session per pi session and account
  (`options.sessionId`); its id is each answer's `responseId`, also on an answer that failed before
  its prompt. Only the user messages after the last answer are sent. An agy session is picked up
  again (`session/resume`, after a restart, crash, `/resume` or `/fork`) only when
  `lib/agy-ledger.ts` says it ends at the transcript's last answer and no other pi session holds
  it: per profile, `antigravity-acp/deckhand-sessions/` keeps each session's answers ({ts, ok},
  written temp then rename) and a lock (O_EXCL, with the holder's pid; a dead holder's is taken
  over). Otherwise (another provider answered, `/tree` or `/fork` to an older answer, a session
  another pi holds, an agy without `session/resume`, no record) a new agy session gets the
  transcript as text first. A message pi sends again after a failed turn that had reached agy
  (its auto-retry) gets a note first that agy may already have it; Deckhand's own error texts do
  not match pi's retry patterns. Text streams as text, thoughts as thinking, tool calls, plan and
  declined requests as lines of thinking and the status line, never as pi tool calls. Abort sends
  `session/cancel` and waits 10 s, then stops the process. Usage is agy's per-turn
  `PromptResponse.usage`; cost 0. pi's summaries (compaction, branch summaries) are answered
  without agy; replays (`disableContinuation`) are refused.
- **Tests**: `test/antigravity.test.ts` against `test/fake-agy.mjs`, a stand-in agy (t3code's
  fixtures' shapes; it checks the method against the profile's settings and its environment, and
  logs the variables it got), with a temporary HOME and accounts folder; never a real agy. `test/temp-home.ts`, imported first
  by every test that loads the extension, points `HOME` and `XDG_DATA_HOME` into a temporary folder,
  and loading refuses to go on when they or Deckhand's data dir are not in it.

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
   ([CLAUDE-TABS.md](CLAUDE-TABS.md) §3) have their own variables.
2. **The event bus as a public contract.** The bridge keeps emitting `kit:desk:mode` and accepting
   `kit:desk:panels` (now merged by panel name, so several producers can publish). pi-kit's
   sidebar keeps handing its panels over and doesn't draw its column in Deckhand. The mode is said
   again after every extension's `session_start` and on `kit:desk:mode?` (PROTOCOL.md §4), since
   the bridge loads first (`-e`) and pi-kit's sidebar listens only once its own `session_start` ran.
3. **Capability claims.** At session start `panels` emits `deckhand:capabilities?`
   `{from: "deckhand", capabilities: ["panels:todos", "panels:subagents", "panels:shells"]}`. An extension that
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
described in [CLAUDE-TABS.md](CLAUDE-TABS.md).

- `--plugin-dir` loads the folder as `<name>@inline` for that session only, in place; nothing goes
  into `~/.claude`.
- A plugin the user installed with the same name is **silently replaced** for that session.
  Outside Deckhand the installed copy is inert (its hooks exit 0 without `DECKHAND_*`).
- It can fail to load: managed settings that name the plugin id win; an admin can turn the flag
  off; `"<name>@inline": false` disables it. Deckhand's "hooks silent" bar catches all of these.
- **Minimum Claude Code 2.1.295** (`CLAUDE_MIN_VERSION`): OSC 7501 and hook `onFailure`. An older
  one still starts; its status comes from the hooks only and a bar says how to update
  ([CLAUDE-TABS.md §5a](CLAUDE-TABS.md#5a-any-setup-older-claude-code-hooks-that-do-not-run)).

## 5a. Codex: hooks per run

Codex has no plugin folder to load from a path. Deckhand passes its hooks on the command line for
that run (`-c hooks.<Event>=[…]`, the bundled `deckhand-cli` by absolute path) and trusts exactly
those for that run in the same layer (`-c hooks.state={…}` with each hook's `trusted_hash`,
Codex 0.167.2's recipe), so Codex shows no "Hooks need review" dialog for them and the user's own
hooks keep their own trust. Nothing goes into `~/.codex` or any Codex home; `CODEX_HOME` is set only for a tab of an account the user added ([CODEX.md §6a](CODEX.md#6a-accounts)); the user's own
settings (model, sandbox, approvals, profiles, `notify`, folder trust) apply untouched (the user's
extra flags and **Full access in new Codex tabs** come before Deckhand's own: CODEX.md §1a), and
`--no-daemon` keeps the TUI and its hooks in the tab's own process tree. A Codex that changes the
recipe shows its review dialog for Deckhand's hooks; status still works from its OSC 7501 and the
tab's bar explains. The details: [CODEX.md](CODEX.md).

- **Minimum Codex 0.163.0** (`CODEX_MIN_VERSION`): OSC 7501 program status. Older ones from
  0.157.0 (`CODEX_PLAIN_MIN_VERSION`, `--no-daemon`) start as plain tabs: no hooks, no MCP server,
  no token, nothing typed into them by Deckhand, a bar saying how to update; older still are not
  started. The version is read from the install's files; only an install that gives none runs
  `codex --version`, with `CODEX_HOME` at a new empty temp folder, so nothing is written under
  `~/.codex` ([CODEX.md §5](CODEX.md#5-installed-version-signed-in)).
- Codex starts its session at the first prompt: SessionStart (the session id, the row) comes then.
- Deckhand's tools: a per-run stdio MCP server (`-c mcp_servers.deckhand={…}`, `deckhand-cli mcp`),
  the tab's token passed by name in `env_vars` ([CODEX.md §7](CODEX.md#7-deckhands-tools-a-per-run-mcp-server)).
- Built and tested against a stand-in for Codex; checked against a real Codex 0.167.2 only for
  its argv, hook trust and MCP config ([CODEX.md](CODEX.md), "How it was tested").

## 6. The harness manifest

One data table, `HARNESS_MANIFEST` in
[`src/core/harness_manifest.odin`](../src/core/harness_manifest.odin), one row per item. It
covers the checklist only: a new harness adds its rows and its `Harness` value here, and code of
its own elsewhere (its tab and how it starts, its integration, its flag rule, its sessions found
on disk). Some of those places are an exhaustive `switch` on `Harness`, so the compiler names
them (`harness_version_of`, `harness_args_check`, `disk_files`, `disk_first_line`). The
setup sheet's first step and Settings → Coding agents draw it (`src/ui_harness.odin`). Setup reads the user's harness config and never
writes it.

**A harness on the Claude tab kind.** Claude Code and Codex share the Claude tab kind: a
Claude tab, its history record and the commands that start or configure one carry `harness:
Harness` (`Claude_Tab.harness`, `Claude_Record.harness`, `New_Claude_Tab`, `New_Claude_Session`,
the account commands, `Set_Claude_Default_Flags`), `.Claude` or `.Codex`; pi has `Pi_Tab`.
`.Pi` is `Harness`'s zero value and never a Claude tab's: every literal sets the harness, and
`claude_harness_check` fails a test (or a scene) that starts, records or restores one with
`.Pi`. Another harness on this kind is a `Harness` value plus the arms the compiler then asks
for: the exhaustive `switch`es where the harnesses differ (`claude_start`'s dispatch,
`claude_harness_missing`, the accounts' settings and folders, `marked`, `claude_account_env`),
plus the one-off `== .Codex` comparisons for wording and rules, which it does not list (search
for `.Codex`). The wires keep their names: a command's `"harness":"codex"`, workspace.json's tab
kind `"codex"`, the history's `"codex": true`, and on the state stream the `"codex"` bool
(`STATE_WIRE_CODEX_BOOLS`, `src/core/state_wire.odin`), so a new harness on this kind needs a
wire form of its own there too.

**A row** (`Harness_Row`): `harness`; `id` (stable: the state snapshot, Settings rows, the
runner); `name`; `kind` (`Harness`, `Built_In`: Deckhand's own, ships in the app, never installed,
or `Third_Party`); `need` (`Required` or `Recommended`); `min_version`; `detect` (`Binary`,
`Integration`, `Pi_Package` with `detect_arg` the npm name), always by looking, never by running;
`install` (the command when it is missing; "" for built-ins); `update` per install layout (§7) or
`update_any` for a third-party item; `why` (one line); `source` (where the command comes from).

| id | Harness | Kind | Need | Min | Detected by | Install | Source |
|---|---|---|---|---|---|---|---|
| `pi` | pi | harness | required | 1.4.0 (`PI_MIN_VERSION`) | `pi` on the tabs' PATH or in `$PI_CODING_AGENT_DIR/bin`, `~/.pi/agent/bin`, else the login shell's `command -v pi` (`harness_installed`); version from its `package.json` | `curl --proto '=https' --proto-redir '=https' -fsSL https://pi.dev/install.sh \| sh` | pi README "Getting started", `docs/quickstart.md` |
| `pi-integration` | pi | built in | required | (pi 1.4.0) | `integrations/pi` in the build | — | §3 |
| `pi-subagents` | pi | third-party | recommended | 0.84.0 (GHSA-6v8j-6w28-2w8r) | `npm:pi-subagents…` in `~/.pi/agent/settings.json` `packages`; version from `~/.pi/agent/npm/node_modules/pi-subagents`, else the spec | `pi install npm:pi-subagents@0.84.0` | npmjs.com/package/pi-subagents; pin: the first version with the GHSA-6v8j-6w28-2w8r fix (nicobailon/pi-subagents advisory); `pi install`: pi `docs/cli.md` |
| `rpiv-todo` | pi | third-party | recommended | — | `npm:@juicesharp/rpiv-todo…` in `packages` | `pi install npm:@juicesharp/rpiv-todo@2.15.0` | npmjs.com/package/@juicesharp/rpiv-todo; pin: a version in daily use; no advisories (juicesharp/rpiv-mono) |
| `pi-ask-user` | pi | third-party | recommended | — | `npm:pi-ask-user…` in `packages` | `pi install npm:pi-ask-user@0.17.0` | npmjs.com/package/pi-ask-user; pin: a version in daily use; no advisories (edlsh/pi-ask-user) |
| `pi-web-access` | pi | third-party | recommended | 0.24.1 (GHSA-8phw-6qw6-xhq6) | `npm:pi-web-access…` in `packages` | `pi install npm:pi-web-access@0.47.0` | npmjs.com/package/pi-web-access; pin: npm's latest on 2026-11-09; minimum: the GHSA-8phw-6qw6-xhq6 fix (nicobailon/pi-web-access advisory, ≤ 0.24.0) |
| `rpiv-btw` | pi | third-party | recommended | — | `npm:@juicesharp/rpiv-btw…` in `packages` | `pi install npm:@juicesharp/rpiv-btw@2.15.0` | npmjs.com/package/@juicesharp/rpiv-btw; pin: a version in daily use; no advisories (juicesharp/rpiv-mono) |
| `claude` | Claude Code | harness | required | 2.1.295 (`CLAUDE_MIN_VERSION`) | `claude` on the tabs' PATH or in `~/.local/bin`, `~/.claude/local`, else the login shell's `command -v claude`; version from where it links (`claude_version_of`) | `curl --proto '=https' --proto-redir '=https' -fsSL https://claude.ai/install.sh \| bash` | code.claude.com/docs/en/setup, "Native Install (Recommended)" |
| `claude-plugin` | Claude Code | built in | required | (Claude 2.1.295) | `integrations/claude-code` in the build | — | §5 |
| `codex` | Codex | harness | required | 0.163.0 (`CODEX_MIN_VERSION`) | `codex` on the tabs' PATH, else the login shell's `command -v codex`; version from where it links (the npm package's `package.json`, Homebrew's `Caskroom/codex/<v>/`, Codex's installer's `releases/<v>-<target>/`), else `codex --version` under a throwaway `CODEX_HOME` (`codex_version_of`); signed in: `codex login status` per Codex home (exit 1 = signed out, a note), run on a worker | `npm install -g @openai/codex@latest` | github.com/openai/codex README |

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
| `unchecked` (a harness's row) | the harness not found by stat while the login shell is still being asked (`command -v pi`, `claude` or `codex`): New session still offers it; the row is made again when the shell answers | ? Looking for pi (Claude Code, Codex) in the login shell… |
| `built_in` | Deckhand's own integration, in the build | ✓ Built in |
| `not_loaded` | in the build but pi is older than 1.4.0, or not in the build | why |
| `needs_harness` | a third-party item whose harness is missing or too old | Needs pi first |

The checklist is looked at again when the sheet opens, on Settings' **Refresh**, after Refresh
shell environment, and when a run ends; after Refresh shell environment and a run's end the cached
`harness_installed` answers are dropped too, the login shell's included (after a run's end, pi's
version is probed again as well), and a tab whose command exits 127 (not found) drops its own.

**Whether a harness is installed** (`harness_installed`, `src/core/harness.odin`) is one lookup for
all three, in the order a tab's own command finds it: the PATH new tabs get, then the folders its
own installer uses (`harness_folders`: pi's `$PI_CODING_AGENT_DIR/bin` and `~/.pi/agent/bin`,
Claude Code's `~/.local/bin` and `~/.claude/local`, none for Codex; the same ones `PI_TAB_CMD` and
`CLAUDE_TAB_CMD` fall back to), then the Node version managers' folders read from disk
(`src/core/harness_node.odin`: nvm's under `$NVM_DIR` or `~/.nvm`, its default alias's version
first, so nvm loaded lazily from `.zshrc` is found; fnm's default alias and versions), then the
login shell's `command -v <name>` on a worker (at most 10 s), so one that only a `.zprofile` puts
on PATH (asdf, mise, pnpm) is found. The shell's answer is the last line of its output that is an
absolute path (rc and logout noise around it); a shell function or alias does not count. Stat,
`access(X_OK)`, reading alias files and `command -v` only: a harness, nvm, fnm or node is never run
to find it. Until the shell answers, the harness counts as there. Only a clean "no" says it is
missing (`command -v`'s exit 1, or a path that is not a runnable binary); a timeout, a signal, any
other exit or exit 0 naming no path is unknown: never cached, the harness counts as there, and the
shell is asked again later (after 15 s, doubling to 5 min; a recheck resets it). What is cached has
its folder's links resolved, so fnm's per-shell folder (`fnm_multishells/<id>`), which goes away
with its shell, becomes the install it points to.

**Which binary a tab starts.** Each start decides its binary once (`harness_path`: by stat, else
what the login shell named) and uses it for both its version checks (Codex's minimum, pi's `-e`
rule) and what the tab runs: the command gets that folder (`_dh_found=<dir>`, `harness_found_sh`)
and puts it first on PATH (the node next to it comes too). A Codex start with no binary to check
(the login shell still asked, or no clear answer) does not start: the tab says why.

**Versions** are read from where the binary links, per harness (`harness_version_of`). A Volta shim
(`~/.volta/bin/<name>` -> `volta-shim`) is read through the package Volta installed
(`tools/image/packages/<package>/lib/node_modules/<package>`), and with none there it has no
version. That is Volta's default copy: in a project whose `package.json` depends on the same
package, Volta's shim runs the project's own copy instead, which Deckhand does not read, so the
version shown can differ from the one that tab runs. Nothing is run for a version, with one
exception: a Codex install whose layout Deckhand does not recognise (a plain `~/.local/bin/codex`
from Codex's older installer) gets `codex --version` run once per binary, with a throwaway
`CODEX_HOME` (`codex_version_run`, [CODEX.md §5](CODEX.md#5-installed-version-signed-in)); never
for a Volta shim, and never to find Codex. Test mode never looks at PATH (`detect_path`) or asks
the login shell (unless `DECKHAND_REAL_PI=1`), only the fake HOME's install folders; unit tests ask
the login shell only when a test turns `harness_lookup_in_unit_tests` on.

**Other machines** (Machines over SSH, [GUIDE.md](GUIDE.md)). Each machine's core checks its own
harnesses with this manifest. This Mac shows that machine's checklist read-only under Settings ›
Machines (`<machine>: <item>`, its state, the version found there and the command to run there,
with **Copy**; at most 16 rows, the text cleaned: `machines[].checklist` in the state snapshot,
PROTOCOL.md §5a). No harness is installed on another machine from here (`machine_install` installs
only Deckhand's core). A new session on another machine offers only the harnesses its checklist
lists as found (`ok`, `too_old` or `unchecked`; pi alone before its checklist arrives), Codex only
when that core's hello lists `codex_tabs` (CODEX.md §8), and runs with that machine's own
accounts, folders and default flags, never this Mac's (`machine_harnesses` in
`src/core/harness.odin`). **Continue this conversation on <machine>** moves pi conversations only,
from this Mac outward (GUIDE.md, [Projects, sessions and chats](GUIDE.md#projects-sessions-and-chats)).

## 7. Install and update

`src/core/harness_install.odin`. Deckhand works out a harness's
layout from where its binary links to, without running it (`install_layout`).

| Layout (by real path) | pi | Claude Code | Codex | Runs after a click? |
|---|---|---|---|---|
| official installer (pi: under `~/.pi/agent`; Claude: `…/claude/versions/`; Codex: `…/packages/standalone/releases/`) | `pi update --self` | `claude update` | its installer again, `curl -fsSL https://chatgpt.com/codex/install.sh \| sh` | pi, Claude: yes; Codex: shown only (to copy) |
| npm global (`/node_modules/`, Homebrew's node too) | `pi update --self` | `npm install -g @anthropic-ai/claude-code@latest` | `npm install -g @openai/codex@latest` | yes, when its `node_modules` is writable (no `sudo`) |
| Homebrew (`/Caskroom/`, `/Cellar/`) | none named (no pi formula is known) | `brew upgrade --cask claude-code` (or `claude-code@latest`) | `brew upgrade --cask codex` | Claude, Codex: yes; pi: shown only |
| bun (`/.bun/`, `/install/global/node_modules/`) | `pi update --self` | `bun add -g @anthropic-ai/claude-code@latest` | `bun add -g @openai/codex@latest` | yes |
| pnpm (`/pnpm/`, `/.pnpm/`) | `pi update --self` | `pnpm add -g @anthropic-ai/claude-code@latest` | `pnpm add -g @openai/codex@latest` | yes |
| yarn (`/yarn/`, `/.yarn/`) | `pi update --self` | none named | none named | shown only |
| nix (`/nix/store/`) | `nix profile upgrade pi` (pi `docs/quickstart.md`) | none named | none named | shown only |
| mise (`/mise/installs/`) | none named | none named | none named | shown only |
| unknown | `pi update --self` | `claude update` | none named | shown only |

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

The integration's tests never start pi. These still need a check against a real pi (Codex's
open checks are in [CODEX.md](CODEX.md), "How it was tested"):

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
- Antigravity against a real agy (none was available): the sign-in, accounts, profiles, models,
  streaming, cancel and resume are tested against a stand-in only (the SSH_CONNECTION keyring
  behaviour is t3code's finding, not checked here); one offline pi 1.5.2 print run with no
  credentials used the provider against the stand-in (two turns, one agy session). `/model`
  listing the models published after start, and the TUI's status line, are unchecked in a real pi.
