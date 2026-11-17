# Codex tabs

How Deckhand runs the [Codex CLI](https://github.com/openai/codex) as a tab (new in 0.4.0; built
in #112): what works, what does not yet, how it was tested, and the rules that keep it safe. The user's view is in
[GUIDE.md](GUIDE.md#codex-tabs); the wire in [PROTOCOL.md](PROTOCOL.md) ("Claude Code tabs":
`harness`). Code: `src/core/codex.odin`, and the Claude tab's code it shares
([CLAUDE.md](CLAUDE.md)): `src/core/claude.odin`, `claude_status.odin`, `dead_tab.odin`,
`tools/deckhand-cli/hooks.odin`.

**One record, two harnesses.** A Codex tab is a Claude tab record (`Claude_Tab`, `Claude_Record`)
with `harness = .Codex` (on the state stream and in the history: the `codex` bool, as before). Everything that is not about Claude Code itself is shared as it is: the tab's
token and its process check, OSC 7501 status (marks, the bell, the fleet pill, ⌥⌘A, the Attention
and Deck views), the hooks' `claude.session` and `claude.turn` reports, held prompts, the dead-tab
bar and Restart, history rows and Resume, the session's place in the left column. A Codex-only
session is an open session with `agent: "claude"` whose main tab is a Codex tab. In the snapshot
and the wire a Codex tab and its history entry carry `"harness": "codex"`; Claude's fields and
formats are unchanged. The workspace saves a Codex tab as kind `"codex"` (an older Deckhand drops
it, never starting `claude` on its id) and its history entry with `"codex": true`.

## What works

- **New session** (the picker lists Codex once `codex` is found), **New Codex tab** in a project's
  or session's menu, `new_claude_session` / `new_claude_tab` with `"harness": "codex"`.
- **Status** from Codex's own OSC 7501 (`state=idle|working|blocked:kind=permission|done|clear`,
  `app=codex`), as for any program: the same marks and counts as a Claude tab.
- **Its row** in the project's sessions once its first prompt ran (Codex starts its session, and
  so its SessionStart hook, lazily: before that the tab has no session id and no row), titled by
  that prompt; **Resume** from the row runs `codex resume <id>`; a restored tab resumes when shown.
- **Held prompts** (`claude_prompt`, Atlas, scripts), with a stricter rule than Claude's (below).
- **Bars**: signed out, hooks not running; a Codex older than 0.163.0 runs as a plain tab with a
  bar (0.157.0 or later; older ones are not started, §5); not installed.
- **Dead tab**: Restart resumes the conversation (no "Restart with model…").
- **Comments** (§2a): pending comments go with the user's next message as UserPromptSubmit's
  `additionalContext`, as for Claude; **Send now**, **Send and close** and Changes' **Ask Codex to
  review** work for a Codex tab.
- **Sessions found on disk** (§2b): Codex conversations of the project's folder in
  `~/.codex/sessions/` (and each account's home) are rows; a click runs `codex resume <id>`.
  Folders where only Codex ran are projects, as Claude-only ones are.
- **Palette**: **New Codex tab** in the session on screen.
- **Deckhand's tools** (phase 2a): the `deckhand` command's show, browser and app commands, as MCP
  tools of a per-run stdio server (§7).
- **The user's flags** (§1a): extra flags on a tab, from the user only, checked against Codex's
  own; and **Full access in new Codex tabs**, a default for the tabs the user starts.
- **On another machine** (phase 2d, §8): New session's picker in that machine's project, its
  rows, the palette in one of its sessions; Codex runs there, on that machine's own core.
- **Accounts** (§6a): Codex homes (`CODEX_HOME`) the user adds; a tab of one runs with
  `CODEX_HOME=<home>`, set again after the login profile.

## What does not yet

- **Rename** changes Deckhand's title only, not Codex's own.
- Conversation ids are one space across harnesses: when a Codex record and Claude Code's own
  transcript share an id, Claude's transcript wins (its row resumes Claude Code, never codex).
- No hot-reload bars (Claude Code's file watching does not apply), no todos, subagents or
  background panels.
- **Continue this conversation on <machine>** is pi only: a Codex conversation cannot be moved to
  another machine yet ([#115](https://github.com/McFalljb/deckhand/issues/115)).
- A Codex-only session whose codex exits before its first prompt (no session id yet) is not saved
  ([#146](https://github.com/McFalljb/deckhand/issues/146)).

## How it was tested

Codex tabs were built and are tested against a stand-in for Codex
(`tests/scripts/fake-codex.py`: it parses Deckhand's real argv with `tomllib`, checks every hook's
trust hash, runs the hooks lazily as Codex 0.167.2 does, starts the MCP server as Codex does, and
checks that nothing is written under `~/.codex`). Unit tests and test mode never find a real
`codex`. Checked against a real Codex 0.167.2, outside a Deckhand tab:

- `codex app-server` `hooks/list` given Deckhand's exact argv lists its four hooks as `trusted`
  and the user's own hooks unchanged (the pinned hash vectors come from it, §2);
- `codex mcp list --json` under a throwaway `CODEX_HOME` parses Deckhand's `mcp_servers.deckhand`
  override (§7);
- the flag allowlist follows its `--help` (§1a); a phase-0 spike showed UserPromptSubmit's
  `additionalContext` reaching the model and tool annotations working.

Not checked yet: a real Codex turn in a Deckhand tab and a real Codex tab on another machine (a
Linux core's `codex`, hook trust there), both tracked in
[#146](https://github.com/McFalljb/deckhand/issues/146); whether Codex shows the model the MCP server's `instructions`, how "Always allow" for a tool
persists, and `codex login status` and Codex's sign-in screen under an added account's home.

## 1. The command

```
$SHELL -l -c '<CODEX_ACCOUNT_SH><CODEX_TAB_CMD>' codex <user flags> --no-daemon -C <cwd> -c hooks.SessionStart=[…] … -c hooks.state={…} -c mcp_servers.deckhand={…}
$SHELL -l -c '<CODEX_ACCOUNT_SH><CODEX_TAB_CMD>' codex resume <id> <user flags> --no-daemon -C <cwd> -c … (a resume)
```

- **`--no-daemon` is mandatory.** Since 0.157 the TUI otherwise attaches to Codex's shared
  background server; its hooks would not descend from the tab's process and the token's process
  check (below) would refuse them.
- **Nothing of Deckhand's that overrides the user's settings**: Deckhand adds no `-s`, `-a`, `-m`,
  `-p`, `projects` or `notify`; `mcp_servers` only for Deckhand's own server (§7). Never
  `--dangerously-bypass-hook-trust` (it would run every hook unreviewed, a repository's `.codex/`
  hooks too). The user's own flags (§1a) go before Deckhand's, so Deckhand's `-c` come last.
- **Deckhand writes nothing under `~/.codex`** or any Codex home, and sets `CODEX_HOME` only for
  a tab of an account the user added (§6a). Codex itself writes there as it always does (its
  sessions, history, logs).
- The argv is an argv: the cwd is its own element after `-C` (absolute; never inside TOML), the
  session id after `resume` passed `codex_id_ok` (a UUID: anything else would be taken for a
  session *name*). The only text inside a `-c` value is Deckhand's own: the CLI's absolute path
  (sh single quotes, then a TOML basic string: `"` and `\` escaped, control characters refused) and
  fixed words. The values are checked by `tomllib` in the scene's fake codex.
- `CODEX_TAB_CMD`: `codex` from the login shell's PATH (npm's global bin), else a line saying how
  to install it and exit 127. `DECKHAND_CODEX_CMD` replaces it in tests (test mode never runs the
  real codex); `DECKHAND_CODEX_BIN` names the binary whose version is read (test mode and unit
  tests find codex only this way, never on the developer's PATH).

## 1a. The user's flags

- **A tab's flags**: `args` on `new_claude_tab` / `new_claude_session` with harness codex, from the
  user only (`ui`, `script`, Deckhand itself; as Claude's), at most 16. Kept with the tab and its
  history entry and passed again on the user's resume, restore and restart (an agent's resume or
  restart starts without them). Checked by `codex_args_check` when given and again at every start
  (a saved tab whose flags fail does not start; the tab says why).
- **An allowlist** (Codex 0.167.2's `--help`): `-m`/`--model`, `-s`/`--sandbox`,
  `-a`/`--ask-for-approval`, `-c`/`--config`, `--add-dir`, `--local-provider`, `--oss`, `--search`, `--no-alt-screen`, `--strict-config`,
  `--approve-for-me`, `--dangerously-bypass-approvals-and-sandbox`, `-p`/`--profile` (below); a value as `-m o3`, `-mo3` or
  `--model=o3` (a separate value never starts with `-`: it would take Deckhand's next flag). Refused,
  each with its reason: anything else, so a newer Codex's new flag waits until it is looked at; a
  word that is no flag's value (`codex exec`, `login` … would run a subcommand, else it is a
  prompt); `--no-daemon`, `-C`/`--cd`, `--worktree` (another folder), `--remote` and
  `--remote-auth-token-env` (another Codex: the hooks and the token check need the tab's own),
  `--dangerously-bypass-hook-trust`, `--last`, `--all`, `--include-non-interactive`, `-i`/`--image`,
  `-h`, `-V`; `--enable`, `--disable` and a `-c` under `features` (Codex features are set in the
  user's `config.toml`, not per tab: some turn hooks off, `codex_hooks` is an alias of `hooks`, and
  others bear on the daemon and MCP); a `-c` of `profile` or `profiles` (Codex itself rejects the
  legacy `-c profile=…`; choose one with `-p`); a `-c` whose key (before the first `=`, a dotted path, quotes ignored) is under
  `hooks`, is `mcp_servers` or under `mcp_servers.deckhand`.
- **Profiles** (checked against real Codex 0.167.2): `-p NAME`, `-pNAME`, `--profile NAME` or
  `--profile=NAME`, NAME a plain name (letters, digits, `_`, `-`, `.`; no `/`; not starting with `-`
  or `.`: `codex_profile_ok`), placed with the user's other flags before Deckhand's own. Codex layers
  `$CODEX_HOME/NAME.config.toml` over the base config, and every `-c` over both (base < profile <
  `-c`), so Deckhand's trailing `-c hooks…` and `-c mcp_servers.deckhand…` still win: its hooks and
  MCP server ran under `-p`. Codex itself refuses `-p ../x` and the legacy `-c profile=…`, and
  ignores an unknown name silently. A profile is the user's own config, like `config.toml`: it can
  turn hooks off (`features.hooks`, which Deckhand's "hooks silent" bar then reports) or bring hooks
  of its own, which Codex asks the user to review as it does for `config.toml`'s.
- **Typing them** (the window, `ui_flags.odin`): **New Codex tab with flags…** (the tab strip's **+**,
  the palette) and **New session with flags…** → **Codex with flags…** open the palette as a one-line field (the flags last used
  from that window), split as a shell splits words (quotes honoured, nothing expanded:
  `core.flags_split`), and send them as `args`; the row shows `codex_args_check`'s reason before
  anything starts. A start on another machine takes no flags from here.
- **Default Codex flags** (`set_harness_flags` with `"harness": "codex"`, Settings › Coding agents ›
  Codex › **Default flags…**, the palette's **Default Codex flags…**; `User_Here`; blank in a hub's
  or a browser's state stream): one line, checked by `codex_args_check` when set
  and again when used, put before the tab's own flags at each start the user makes (the same starts
  as full access below); a default flag the tab's flags name too (`-m` and `--model` are one, a `-c`
  by its key) is left out; never saved into a tab or its history entry
  (`harness_with_defaults`, `core/harness_flags.odin`).
- **Full access in new Codex tabs** (`set_claude_default_flags` with `"harness": "codex"`, off by
  default; Settings › Coding agents › Codex and the palette): `User_Here`, so only the user at this
  Mac changes it (never an agent, a script or a machine allowed to connect). Turning it on is
  confirmed (`CODEX_FULL_ACCESS_CONFIRM`). It adds `--dangerously-bypass-approvals-and-sandbox` after
  the tab's flags at each start the user makes (as Claude's skip-permissions: new tab or session,
  the user's resume, a restored tab shown, the user's restart), never saved into a tab's flags.
  Left out when the tab's flags set `-s`, `-a`, `--approve-for-me` (Codex refuses the flag beside
  `-a` or `--approve-for-me`) or a `-c` of `approval_policy`, `sandbox_mode` or
  `sandbox_workspace_write`, or name it, and past 16 flags. Agents', scripts', panels' and apps'
  starts never get it. A restart or resume of a Codex tab forwarded by a machine allowed to connect
  counts as the user's (its saved flags and this default apply), as for Claude tabs: such a machine
  acts as the user here.

## 2. The hooks and their trust

Deckhand passes four hooks per run, each `'<deckhand-cli>' hook codex-<event>` with `timeout=10`:
SessionStart → `claude.session` (its id, cwd, source, model), UserPromptSubmit → `claude.turn
submitted` (the prompt's first line names the row) and the pending comments (§2a),
PermissionRequest → `claude.turn waiting`, Stop → `claude.turn idle` (with `question` when Codex's
last message ends with `?`; the text is never sent). SessionEnd is not passed: it carries nothing
Deckhand uses. The CLI **prints nothing** for these but UserPromptSubmit's comments: Codex would add
SessionStart's output to the model's context and read Stop's or PermissionRequest's as a decision.

Codex asks the user to review new or changed hooks ("Hooks need review"). Deckhand trusts exactly
its own hooks for that run in the same `-c` layer, an inline table:

```
-c 'hooks.state={"/<session-flags>/config.toml:stop:0:0"={trusted_hash="sha256:…"}, …}'
```

The hash is Codex 0.167.2's recipe (`codex_hook_hash`): sha256 of the compact, key-sorted JSON
`{"event_name":"stop","hooks":[{"async":false,"command":"…","timeout":10,"type":"command"}]}`.
`src/codex_test.odin` pins vectors (`CODEX_HASH_PINNED`); they were checked against the
app-server's `hooks/list` `currentHash`. The layer merges with the user's: their own hooks keep
their own trust (checked: a user hook stays `trusted` or `untrusted` as it was). If a newer Codex
changes the recipe, Codex shows its review dialog and the hooks do not run until the user answers
it: status still comes from OSC 7501, and after a turn with no hook for 20 s the bar says
"Deckhand's hooks aren't running in this Codex tab …".

## 2a. Comments

The `codex-prompt-submit` hook does what Claude's `prompt-submit` does after its turn report: it
asks `claude.comments` for the session's pending comments, prints them as
`{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":…}}` (the only output
any Codex hook prints; Codex adds it to the model's context with the user's message: verified in the
phase 0 spike), and only then marks them delivered (`claude.attached`). The block, its 10,000-character
budget and the crops (PNG copies in the shots folder, 0600) are Claude's; the image line says to look
at each file rather than "the Read tool". Nothing pending: nothing printed. If the hook does not run
(hooks untrusted after a Codex update), the comments stay pending.

## 2b. Sessions found on disk

`claude_disk_scan` (`src/core/claude_disk.odin`; Codex's lister, first-line reader and saved cache in `src/core/codex_disk.odin`) lists Codex conversations beside Claude Code's for
the selected project and Chats. **Codex's files are read only, never written.**

- **Where**: `$CODEX_HOME/sessions` or `~/.codex/sessions` (`codex_home`), and each Codex
  account's `<home>/sessions` (§6a), every `YYYY/MM/DD/` folder, newest first (no age or count
  limit; hard ceilings against a broken folder: 20,000 folders walked and 50,000 files a home,
  `CODEX_DISK_DIRS_MAX`, `CODEX_DISK_FILES_MAX`; each folder read entry by entry, names only, and
  no further than 20,000 entries, `codex_disk_dir_entries_max`, so a folder of millions is never
  statted, kept or sorted whole; only rollout names are statted),
  regular files named `rollout-<time>-<uuid>.jsonl` or `.jsonl.zst` (Codex Desktop compresses older
  rollouts with zstd; when both are there, the plain one) only (no symlinks; opened without following one or blocking, and checked again as a regular file), the id from the name
  (`codex_id_ok`). Tests and test mode read only a `CODEX_HOME` they set or a home they added,
  never the real home's `~/.codex`.
- **What is read**: the first line only (`session_meta`), at most 64 KB (a longer one is skipped;
  of a `.zst`, only what decodes it, `codex_zst_first_line` with the vendored zstd decoder,
  `src/zstd`: at most 256 KB of it read, decoded no further than its first newline or the 64 KB
  line cap, a frame window of at most 8 MiB; a decode error, a truncated file or a cap reached
  without a newline skips the file, `CODEX_ZST_*`),
  once per file ever, never on the main thread (`codex_pass`, `codex_disk.odin`). The scan asks
  for a pass (`codex_disk_refresh`: one at a time, at most one per 10 s) and shows the cache
  (`codex_disk_found`); the pass lists every home, drops the entries of files gone, reads the
  first line of each new or changed rollout (size or mtime), and has the rows made again every 64
  files. What was read and found wanting is remembered; a rollout that could not be read (open,
  stat or read failed: permissions, an I/O error) is not, so each pass reads it again. The payload's `id` must be
  the file's, `cwd` absolute and the project's folder or its real path byte for byte (never a path from the file resolved; at most 1,024 bytes, no NUL), `source`
  `"cli"` (the CLI) or `"vscode"` (Codex Desktop) to be a row (`codex_source_listed`:
  `codex exec`'s, a subagent's, an object, and any source Deckhand does not know are not). The
  cwd is only compared; nothing from the file reaches a shell, the terminal or the snapshot but
  the id (a UUID). The file's path is not kept in a row.
- **The saved cache**: `codex-sessions.tsv` in the data dir, beside the session-title cache
  (`titles_load`): a version line (`deckhand codex sessions 1`), then per rollout its size, mtime,
  created time, source, id, account (home), cwd and path, tab-separated; written atomically, 0600,
  at the end of a pass that changed anything; at most 100,000 entries (`CODEX_CACHE_MAX`). A file
  over 64 MB, of another version, or a row over 16 KB, without exactly 8 tab-separated fields (counted
  before it is split) or that does not parse is not used (those rollouts are
  read again). A launch reads only new or changed rollouts.
- **Titles**: each home's `session_index.jsonl` (one object a line: `id`, `thread_name`,
  `updated_at`; the last line for an id wins), joined to the listed rows only (a row it does not
  name stays "Untitled Codex session" with the file's date). Read on the pass's worker, again only
  when its size or mtime changes; its last 16 MB at most, lines over 16 KB skipped; the name made
  one line as other titles are (`clean_title`, `one_line`, at most 80 bytes). Never written.
- **Which**: not one Deckhand's history has (its row is the history's), a pi session's id, or an
  id Claude Code's transcript has (one id, one harness: Claude's wins, in the scan and again at
  resume, `claude_conversation_seen`); at most `MAX_SESSIONS`.
- **A click** (`open_session` with its id; `codex_disk_resume`): a Codex-only session of the
  project running `codex resume <id>` in the project's folder, under the account whose home it was
  found in (refused once that account is removed); the history keeps it from then on.
  An agent's `open_session` finds only the rows listed for the selected project and Chats.
- **Codex Desktop's chats**: a listed rollout whose `cwd` is a folder below `~/Documents/Codex`
  (`HOME`'s spelling, its real path or the folder resolved; `codex_chat_roots`; Chat mode makes
  `<date>/<slug>` there) is a row in Chats, never a found project, unless that folder is a listed
  project by its text (one you added stays yours); its click, a resume from the history, a Restart
  and a relaunch run `codex resume` in that folder only (`Claude_Disk.cwd`, `codex_chat_cwd`): once
  it is gone they refuse ("the chat's folder is gone"), never the chats folder. A history
  entry 0.7.0 filed under such a folder's project is re-filed to Chats (saved) once that folder is
  no listed project (`codex_chats_refile`).
- **Projects where only Codex ran** (`claude_scan_projects`, Claude's own path, on the Rescan
  worker): the `cwd` of each listed rollout (source `"cli"` or `"vscode"`), from the found rows'
  saved cache after a pass on the Rescan worker (`codex_disk_pass_now`, `codex_disk_folders`: a
  Rescan reads no rollout the cache knows). The cwd is cleaned once, when it enters the cache, so
  a project and its rows match byte for byte (a trailing slash is the same folder). Merged by
  folder with pi's and Claude's (`found_project`); never the home folder itself (`HOME`, its
  real path, or any path that is the same folder by device and inode: a link to it, another case
  on a case-insensitive volume; a session started in `~` makes no project; a project added there
  by hand is left as it is). The check fails closed: a folder that cannot be stat'ed now (other than
  "no such folder"), or any folder while the home folder's own stat failed, is not a found project
  on that scan; the next tries again. On the main thread (`rescan_now`: a new Chats or main folder) the scan
  reads no rollout: it takes the cache as it is and starts a pass on the worker, which the next
  Rescan uses; a folder no one else knows is a project
  found on disk only, exactly as a Claude-only folder is (`Project.claude`: saved; a Rescan that
  no longer finds it drops it unless you added, named or opened it; temp and missing folders are
  hidden by the tidy rules, as any project's). The launch's first scan reads no rollout, and a Rescan follows when a
  Codex home has a `sessions/` folder (`claude_startup_rescan_due`). Each Codex home's sessions
  folder is taken on the main thread before the scan (`claude_scan_prepare`).

## 3. The token and the process check

A Codex tab gets a Claude tab's environment and token (`DECKHAND_SOCKET`,
`DECKHAND_CLAUDE_TOKEN`, `DECKHAND_CLI`, `DECKHAND_CLAUDE_TAB`, and their `PI_DESK_` twins; caller
`panel` with `claude` set): the same scope as a Claude tab's, for its own tab only, nothing new
written to disk. A hello with it is refused unless the connecting process descends from the tab's
own process (`socket_claude_peer_ok`): a hook run by Codex's shared server, or any other process,
fails closed. Codex passes the environment to its hooks and commands; a sandboxed command cannot
reach the socket anyway. In the session holder a Codex tab's process is recorded as `codex`
(tokens.json, MAC'd), never `claude`: a saved tab relabelled in workspace.json never adopts a
running codex as a Claude tab, nor the reverse. Without that record (tokens.json removed or failing
its MAC) no held pi, Claude or Codex is adopted into an agent tab: workspace.json alone never says
what a live process is.

**One id, one harness**, decided by where it was first legitimately seen: a Codex tab never claims
an id Deckhand knows as Claude Code's (its history, the disk index, a transcript of the project's
by stat), for its report or a `resume`; and a Codex claim on an id that Claude Code's own
transcript has never keeps Claude from it (the Claude tab's report, or opening the transcript's
row, drops the claim). A hub (another machine's Deckhand, §8) starts Codex tabs here under the
same rules as the user here, with this machine's own token, hooks and process check.

## 4. Text Deckhand types into Codex's composer

Held prompts go only when Codex's own OSC 7501 says it is not working or blocked (it reports
nothing behind its login or trust screen: nothing goes then), the hooks, once they report, agree,
the input takes bracketed paste and the user has typed nothing since their last message (Send now
skips only that last one). Enter during a turn would steer it, so a turn never takes one.
`codex_command_text` refuses (with the reason, when held and again when it goes):

- a first non-blank character (spaces, tabs and newlines skipped) `/` (slash command), `!` (shell)
  or `$` (skill);
- an `@word` or `$name` where a word starts (Codex's mention and skill pickers open on a paste);
- control characters other than tab and newline.

A later line starting with `/` or `!` is plain text: Codex reads a command only at the start of
the composer. The held text's Enter goes only if nothing changed after its paste: a submission
cancels it, and Codex working or blocked by then drops it.

Comments' **Send now** (and **Send and close**) pastes only Deckhand's fixed line ("Here are my
comments.") through `claude_paste_message`, under the same rule and the held prompts' readiness
(Codex idle per OSC 7501 and its hooks, bracketed paste, nothing typed); its Enter is re-checked
as a held text's. Changes' review ask is a held prompt (`claude_prompt`), so the rule applies.

Everything else Deckhand puts into a Codex composer on its own goes through the same rule and only
while Codex is not working or blocked (`codex_paste_refusal`): a file dropped on the tab (its path:
`'/tmp/a @b.txt'` is refused: the window sends it as `send_text` with `generated`, the core
decides on its own state and the window toasts its reason) and anyone's `send_text` but the user's
own. The user's typing and ⌘V are theirs. Unicode look-alikes (a fullwidth `／`) are not checked: Codex does not read them as
commands either.

## 5. Installed, version, signed in

- **Installed**: `codex` on the PATH new tabs get, by stat, else the login shell's
  `command -v codex` (on a worker; there meanwhile), never run: the lookup pi and Claude Code use
  too (`harness_installed`, [HARNESSES.md §6](HARNESSES.md#6-the-harness-manifest)). Its version
  is read from the path either one found. The checklist (Settings →
  Coding agents) has a Codex row: Install runs `npm install -g @openai/codex@latest` after the
  user's click, as for the other harnesses.
- **Version**: read from the install's own files, without running `codex`: the npm package's
  `package.json` next to where `codex` links, Homebrew's `Caskroom/codex/<v>/`, or Codex's own
  installer's release folder (`~/.local/bin/codex` -> `~/.codex/packages/standalone/releases/<v>-<target>/`:
  the version is in that path). Only any other install (a plain copy, as Codex's installer made
  before it kept releases) runs `codex --version` (argv, no shell, 3 s at most, once per binary:
  cached by its path, size, mtime and inode). Codex writes its helper links under
  `$CODEX_HOME/tmp/arg0` at every start, `--version` too, so that run gets `CODEX_HOME` set to a new
  empty 0700 folder in `$TMPDIR` (`deckhand-codex-XXXXXX`), removed right after: nothing under
  `~/.codex` is written (#135). Below **0.163.0** (OSC 7501) and from **0.157.0** (`--no-daemon`,
  `CODEX_PLAIN_MIN_VERSION`) a Codex tab starts **plain**: `codex [resume <id>] <user flags>
  --no-daemon -C <cwd>`, with no hooks, no `hooks.state`, no MCP server and **no token** in its
  environment (nothing of it can reach Deckhand, so the process check has nothing to admit), and a
  bar (`Codex 0.160.0 is older than 0.163.0: it runs here without Deckhand's hooks and status …
  Update it with …, then Restart the tab`; Dismiss hides it for that run). Deckhand types nothing
  into it: `claude_prompt` and every paste but the user's own are refused (`codex_paste_refusal`;
  held prompts would wait forever for an OSC 7501 that never comes), and the "hooks silent" bar
  never shows. The plain mark is the core's (`codex_plain_version`; the snapshot's
  `codex_version_old`), and is kept with the tab's start record in the MAC'd `tokens.json`
  (`"codex_plain":"0.160.0"`): a plain tab adopted from the session holder after a relaunch is
  marked again from that record, whatever its token trust and whatever codex is on disk now. Below **0.157.0** a
  Codex tab does not start: the tab says how to update for its install (npm, Homebrew, bun or
  pnpm: that command; Codex's own installer: run it again,
  `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, never npm), the command's refusal says
  the same in one line (`Codex 0.135.0 is older than 0.157.0: update it with …`), and the
  checklist offers Update (for Codex's own installer: that command, to copy).
- **Signed out**: `codex login status` (exit 1), run once per recheck through the login shell on a
  worker when a Codex tab starts or the checklist looks, per Codex home: a tab of an account asks
  under its `CODEX_HOME` (set after the login profile, as the tab's), the checklist for the
  default (up to 16 homes; past that no bar). Only its exit status is used. While it says signed
  out for the tab's home and the tab's Codex has reported no OSC 7501, the bar says to sign in on
  Codex's own screen; once the composer reports, the bar goes and the next start asks again.

## 6. Credentials

`~/.codex/auth.json` (and `CODEX_HOME`'s, when the user sets one: its whole folder, never HOME or
above; with `CODEX_HOME` at HOME or above, `$CODEX_HOME/auth.json` itself), anything
named `.codex/auth.json`, and everything in a Codex home but its config (`config.toml`,
`AGENTS.md`, `AGENTS.override.md`, `prompts/`, `skills/`, `rules/`) is refused wherever Deckhand
refuses Claude's credentials (`settings_credential`: open, show, upload, list, watch, hard links by
inode): `sessions/` transcripts, `history.jsonl`, logs and databases included. The Codex homes
(`claude_account_dirs(.Codex)`): `~/.codex`, the default (`CODEX_HOME`), every account's
home, and a removed account's while it still holds `auth.json` or `sessions/` (one that never
held Codex's files is given back); never HOME or a folder above it.

## 6a. Accounts

An account is a **Codex home**: the folder `CODEX_HOME` names (its sign-in, config, sessions).
Claude's accounts code with harness `.Codex` (`src/core/claude_accounts.odin`; docs/CLAUDE.md §1b):

- **Which**: the default, `CODEX_HOME` as tabs get it when absolute (never HOME or above it), else
  `~/.codex` (`codex_home`); `~/.codex` too while `CODEX_HOME` names another; then the folders the
  user added (Settings › Coding agents › Codex › **Add account…**, a folder picker; the wire's
  `add_claude_account` with `"harness":"codex"`). Nothing is looked for (Claude's found folders
  have no Codex equivalent). The folder must exist: **Deckhand never makes or writes a home**. A
  home is refused when it is HOME or above it, holds a project, the main folder or the chats
  folder, or is inside or holds another guarded Codex home or Claude config folder (or is one; a
  Claude account is never a Codex home either); a project is
  refused inside a non-default account's home.
- **Signing in**: on Codex's own screen in the account's first tab (the signed-out bar is per
  home, §5), or in a terminal with `CODEX_HOME=<home> codex login` (the Add row says so).
- **A tab**: `Claude_Tab.account` and the record's `account` are the home's folder (the default's
  when none was named; an older record's `""` is the default). Every start (new, resume, restore,
  restart, a found row) checks it is still configured (else the tab says so, nothing starts) and
  sets `DECKHAND_CODEX_ACCOUNT` and `CODEX_HOME` in the tab's environment; `CODEX_ACCOUNT_SH` sets
  `CODEX_HOME` again after the login profile ran and drops the marker, so a profile that exports
  `CODEX_HOME` cannot move a tab to another account. `~/.codex` while the default is another:
  `CODEX_HOME` unset. The default sets nothing: the environment as the profile leaves it.
- **Which account starts**: `account` on `new_claude_tab` / `new_claude_session` names a
  configured one by label or folder (`"no such Codex account …"` otherwise, an agent's folder and a
  hub's too: a forwarded start is resolved against that machine's own accounts); a resume stays in
  its record's account; else the project's last Codex account, the chosen default
  (`set_claude_account_default` with harness codex), the last used, the environment's.
- **Picker and menus**: with several accounts, **Codex · Name** once per account in New session's
  picker, **New Codex tab · Name** in the menus and the palette; tabs and rows show the account's
  name. Another machine's project or session: one row (its own accounts there).
- **Found sessions** (§2b): each account's `sessions/` is scanned (the caps per home); a row
  resumes under the home it was found in.
- **Settings** (Coding agents › Codex, once Codex is installed): with several accounts each with
  **Rename…**, **Make default**, **Remove**; **Add account…** (one account: **More accounts…**).
  `rename_claude_account`, `remove_claude_account`, `set_claude_account_default` take
  `"harness":"codex"`; all `user` only, as Claude's. Saved as `codex_accounts`,
  `codex_account_last`, `codex_account_default`; the snapshot lists `codex_accounts` as
  `claude_accounts` (labels and folders, no secret).
- Not done: the setup sheet's accounts step (Claude's lists found folders; Codex finds none),
  per-account hot-reload, and a copy button for the sign-in command.
- **Settings files** (Coding agents › Codex › Advanced): each home's `CODEX_CONFIG_FILES` and
  `CODEX_CONFIG_FOLDERS` (one group per account once there are several), edited by the user as
  Claude's; `CODEX_VIEW_FILES`/`CODEX_VIEW_FOLDERS` (`hooks.json`, `hooks/`) read-only in the editor
  (`codex_view_only`); never a Create. A save is refused over a credentials or state file by any
  name (`settings_credential` on the path and on where it leads at save time), so nothing outside
  the allowlist in a Codex home is written. `plugins/` stays Codex's (not listed, refused).
- Not checked without a real sign-in: that `codex login status` under an added home answers for
  that home, and that Codex's own sign-in screen in such a tab writes that home's `auth.json`.

## 7. Deckhand's tools: a per-run MCP server

Codex's sandbox cannot reach Deckhand's socket, so a Codex tab gets the `deckhand` command's tools
as MCP tools instead. Deckhand passes one more `-c` for the run, one inline table:

```
-c 'mcp_servers.deckhand={command="<deckhand-cli>",args=["mcp"],env_vars=["DECKHAND_SOCKET","DECKHAND_CLAUDE_TOKEN","DECKHAND_SHOTS_DIR"],tool_timeout_sec=620}'
```

- **It merges with the user's own `[mcp_servers.deckhand]`.** Codex deep-merges the inline table
  into a table of that name in the user's config (or a profile's): Deckhand's keys (`command`,
  `args`, `env_vars`, `tool_timeout_sec`) win, and the user's other keys stay, so the user's
  `enabled = false` turns Deckhand's tools off for their tabs, and their `env` or other timeouts
  apply. That is the user's own config deciding for their own tabs, not an escalation: it gives
  the server nothing beyond the tab's token, which `env_vars` passes as before.
- Codex starts `deckhand-cli mcp` (`tools/deckhand-cli/mcp.odin`) **outside its sandbox**, as its
  own child: the hello's process check (§3) sees a descendant of the tab's process and passes. An
  MCP server does not get the tab's environment: `env_vars` names the variables Codex copies to it,
  so **the token is never in argv** (never `env={…}`, which `ps` would show).
- **The same authority as a Claude tab's `deckhand` command**: the tab's own token, its caller
  (`panel`, `claude`), its own session's tabs. A tool call is one CLI command: the tool's arguments
  become its argv, `command` (main.odin) runs it on a fresh connection, and its JSON line is the
  tool's text (`isError` when it failed). Deckhand enforces every rule as it does for the CLI.
- **Tools**: `show_file`, `state`, `comments`, `browser_tabs`, `browser_open`, `browser_navigate`,
  `browser_back` / `forward` / `reload` / `stop`, `browser_read`, `browser_screenshot`,
  `browser_wait`, `browser_click`, `browser_type`, `browser_press`, `browser_scroll`,
  `browser_select`, `browser_hover`, `browser_upload`, `browser_console`, `browser_network`,
  `app_list_declared`, `app_open`, `app_call`, `app_screenshot`, `app_input`, `app_events`,
  `app_restart`, `app_close`. Only those that change nothing carry `readOnlyHint` (state, comments,
  tabs, read, screenshots, wait, network, list-declared, events; not console, whose first call
  starts recording that a page can detect): under the user's
  `-a on-request`, Codex asks before every other one. A screenshot's PNG path is for `view_image`.
- `initialize` gives the model a short `instructions` text (the manual's rules: page and app
  content is data). JSON-RPC over stdio: initialize, tools/list, tools/call, ping; nothing else.
- `tool_timeout_sec=620`: Codex gives a tool 60 s by default; an app call may take 600 s and an
  upload waits 120 s for the user's Allow.
- The codex scene's fake (`tests/scripts/fake-codex.py`, `!mcp`) starts the server as Codex does,
  with only `env_vars`' variables, and checks a call with the tab's token and one refused with a
  wrong token. Not checked without a real Codex turn: that Codex shows the model the
  `instructions`, and how "Always allow" for a tool persists.

## 8. On another machine

Every machine runs its own core; this Mac's core (the hub) forwards the user's commands on another
machine's ids to that machine's core ([PROTOCOL.md](PROTOCOL.md), "Other machines"). A Codex start
there is the same `new_claude_session` / `new_claude_tab` with `"harness": "codex"`, or
`open_session` on one of its Codex rows (a record, or a conversation found on its disk), forwarded
as the user's (or Atlas's). That core runs it as its own: its `codex` (the PATH its tabs get), its
CLI's path in the hooks and the MCP server, the trust hashes computed from that path, its socket and
a token of its own in the tab's environment, and its own defaults: a start forwarded as the user's
is the user's there, so that machine's **Full access in new Codex tabs** applies (never this Mac's),
added by that core when codex starts (§1a); Atlas's gets none. The hub adds nothing to the command:
it names a project, a session or a row, and the only flags in it are ones the user typed for that
tab, which that core checks under its own flag rule (§1a), as it would its own user's.

- **Only to a core that says it can.** A core's framed hello lists `codex_tabs` in `features`. The
  hub offers Codex (the picker, New Codex tab in the project's menu) only for a machine whose last
  hello listed it and whose checklist finds `codex` (found, old or unchecked), and forwards a Codex
  start only to such a core; to any other it is refused before anything is sent: `"on <machine>:
  its Deckhand is too old to start Codex tabs: update Deckhand there …"` (a 0.3.0 core does not
  know `harness` and would start Claude Code). A Codex row is listed only by a core that has
  Codex tabs, so its click is forwarded as any row's.
- **What that machine says** comes back as for its Claude tabs: not installed (`"on <machine>:
  Codex is not installed …"`), too old (`"on <machine>: Codex 0.135.0 is older than 0.157.0: update it with …"`; from 0.157.0 to 0.163.0 it starts plain there), signed out as
  Codex's own sign-in screen in the tab's relayed terminal; its checklist on the machine's row.
  The bars over a tab (signed out, hooks not running) are that machine's core's and are not
  mirrored, as for its Claude tabs; this Mac's own sign-in never puts one over it.
  Status marks and the bell come through the mirror (the tab's `codex` flag, its hooks' turn
  enums and its OSC 7501 summary, cleaned), as for a Claude tab there.
- **The rules stay where the tab is.** Text into its composer (a held prompt, a hub's
  `send_text`, a dropped path) is checked by that core under the composer rule (§4); one id, one
  harness, by that core's own records and disk. The hub never runs a command, picks a path or
  starts a Codex of its own for another machine's tab or row: their ids never start anything here
  (term_start refuses them), and a remote row's `codex` flag only chooses its icon and words.
- Not checked without a real second machine: a Linux core's `codex` (npm's global bin on its login
  PATH) and Codex's own hook trust there. The `remote-codex` scene runs both cores on one Mac with
  a stand-in codex.
