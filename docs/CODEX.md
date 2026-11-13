# Codex tabs

How Deckhand runs the [Codex CLI](https://github.com/openai/codex) as a tab, phase 1 (issue #112):
what works, what does not yet, and the rules that keep it safe. The user's view is in
[GUIDE.md](GUIDE.md#codex-tabs); the wire in [PROTOCOL.md](PROTOCOL.md) ("Claude Code tabs":
`harness`). Code: `src/core/codex.odin`, and the Claude tab's code it shares
([CLAUDE.md](CLAUDE.md)): `src/core/claude.odin`, `claude_status.odin`, `dead_tab.odin`,
`tools/deckhand-cli/hooks.odin`.

**One record, two harnesses.** A Codex tab is a Claude tab record (`Claude_Tab`, `Claude_Record`)
with `codex` set. Everything that is not about Claude Code itself is shared as it is: the tab's
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
- **Bars**: signed out, hooks not running; a Codex too old is not started; not installed.
- **Dead tab**: Restart resumes the conversation (no "Restart with model…").
- **Deckhand's tools** (phase 2a): the `deckhand` command's show, browser and app commands, as MCP
  tools of a per-run stdio server (§7).

## What does not yet (phase 2 and later)

- No comments: **Send now**, **Send and close** and Changes' review asks refuse a Codex tab
  (`"Codex tabs don't take comments yet …"`), and `claude.comments` is refused for it.
- No read-only chats: a Codex tab in a chat while **Start chats read-only** is on is refused (Codex is
  not offered there).
- No sessions found on disk (`~/.codex/sessions/`): only conversations Deckhand ran are listed.
- No extra flags and no accounts: the user's own Codex settings (`~/.codex/config.toml`, profiles)
  apply as they are.
- **Rename** changes Deckhand's title only, not Codex's own.
- Conversation ids are one space across harnesses: when a Codex record and Claude Code's own
  transcript share an id, Claude's transcript wins (its row resumes Claude Code, never codex).
- Not on another machine: `"Codex tabs run on this Mac only for now …"` (refused before it is sent:
  an older core there would start Claude Code instead); the picker never lists it for one.
- No hot-reload bars (Claude Code's file watching does not apply), no todos, subagents or
  background panels.

## 1. The command

```
$SHELL -l -c '<CODEX_TAB_CMD>' codex --no-daemon -C <cwd> -c hooks.SessionStart=[…] … -c hooks.state={…} -c mcp_servers.deckhand={…}
$SHELL -l -c '<CODEX_TAB_CMD>' codex resume <id> --no-daemon -C <cwd> -c … (a resume)
```

- **`--no-daemon` is mandatory.** Since 0.157 the TUI otherwise attaches to Codex's shared
  background server; its hooks would not descend from the tab's process and the token's process
  check (below) would refuse them.
- **Nothing that overrides the user's settings**: no `-s`, `-a`, `-m`, `-p`, `projects` or
  `notify`; `mcp_servers` only for Deckhand's own server (§7). Never `--dangerously-bypass-hook-trust` (it would run every hook unreviewed, a
  repository's `.codex/` hooks too).
- **Deckhand writes nothing under `~/.codex`** and never sets `CODEX_HOME`. Codex itself writes
  there as it always does (its sessions, history, logs).
- The argv is an argv: the cwd is its own element after `-C` (absolute; never inside TOML), the
  session id after `resume` passed `codex_id_ok` (a UUID: anything else would be taken for a
  session *name*). The only text inside a `-c` value is Deckhand's own: the CLI's absolute path
  (sh single quotes, then a TOML basic string: `"` and `\` escaped, control characters refused) and
  fixed words. The values are checked by `tomllib` in the scene's fake codex.
- `CODEX_TAB_CMD`: `codex` from the login shell's PATH (npm's global bin), else a line saying how
  to install it and exit 127. `DECKHAND_CODEX_CMD` replaces it in tests (test mode never runs the
  real codex); `DECKHAND_CODEX_BIN` names the binary whose version is read (test mode and unit
  tests find codex only this way, never on the developer's PATH).

## 2. The hooks and their trust

Deckhand passes four hooks per run, each `'<deckhand-cli>' hook codex-<event>` with `timeout=10`:
SessionStart → `claude.session` (its id, cwd, source, model), UserPromptSubmit → `claude.turn
submitted` (the prompt's first line names the row), PermissionRequest → `claude.turn waiting`,
Stop → `claude.turn idle` (with `question` when Codex's last message ends with `?`; the text is
never sent). SessionEnd is not passed: it carries nothing Deckhand uses. The CLI **never prints
anything** for these: Codex would add SessionStart's or UserPromptSubmit's output to the model's
context and read Stop's or PermissionRequest's as a decision.

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
row, drops the claim). A hub never makes a Codex tab here, even with this machine's own ids.

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

Everything else Deckhand puts into a Codex composer on its own goes through the same rule and only
while Codex is not working or blocked (`codex_paste_refusal`): a file dropped on the tab (its path:
`'/tmp/a @b.txt'` is refused: the window sends it as `send_text` with `generated`, the core
decides on its own state and the window toasts its reason) and anyone's `send_text` but the user's
own. The user's typing and ⌘V are theirs. Unicode look-alikes (a fullwidth `／`) are not checked: Codex does not read them as
commands either.

## 5. Installed, version, signed in

- **Installed**: `codex` on the PATH new tabs get, by stat (never run). The checklist (Settings →
  Coding agents) has a Codex row: Install runs `npm install -g @openai/codex@latest` after the
  user's click, as for the other harnesses.
- **Version**: from the npm package's `package.json` next to where `codex` links (or Homebrew's
  `Caskroom/codex/<v>/`). Below **0.163.0** (OSC 7501) a Codex tab does not start: the tab says
  how to update, the checklist offers Update.
- **Signed out**: `codex login status` (exit 1), run once per recheck through the login shell on a
  worker when a Codex tab starts or the checklist looks. Only its exit status is used. While it
  says signed out and the tab's Codex has reported no OSC 7501, the bar says to sign in on Codex's
  own screen; once the composer reports, the bar goes and the next start asks again.

## 6. Credentials

`~/.codex/auth.json` (and `CODEX_HOME`'s, when the user sets one: its whole folder, never HOME or
above; with `CODEX_HOME` at HOME or above, `$CODEX_HOME/auth.json` itself), anything
named `.codex/auth.json`, and everything in Codex's folder but its config (`config.toml`,
`AGENTS.md`, `AGENTS.override.md`, `prompts/`, `skills/`, `rules/`) is refused wherever Deckhand
refuses Claude's credentials (`settings_credential`: open, show, upload, list, watch, hard links by
inode): `sessions/` transcripts, `history.jsonl`, logs and databases included.

## 7. Deckhand's tools: a per-run MCP server

Codex's sandbox cannot reach Deckhand's socket, so a Codex tab gets the `deckhand` command's tools
as MCP tools instead. Deckhand passes one more `-c` for the run, one inline table (it replaces a
server of the user's own named `deckhand` for that run, never merges with it):

```
-c 'mcp_servers.deckhand={command="<deckhand-cli>",args=["mcp"],env_vars=["DECKHAND_SOCKET","DECKHAND_CLAUDE_TOKEN","DECKHAND_SHOTS_DIR"],tool_timeout_sec=620}'
```

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
