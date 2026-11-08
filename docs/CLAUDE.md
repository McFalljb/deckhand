# Claude Code tabs

How Deckhand runs [Claude Code](https://code.claude.com) as a first-class tab: the tab, the
bundled plugin and its `deckhand` command, the credential and its threat model, resume and
restore, comments, and how text from agents is kept out of a half-typed prompt. The user's view
is in [GUIDE.md](GUIDE.md#claude-code-tabs); the wire format in [PROTOCOL.md](PROTOCOL.md)
(§2 tokens, §3 "Claude Code tabs"). Code: `src/claude.odin`, `src/ui_claude.odin`, `src/claude_panels.odin`, `src/claude_status.odin`, `src/dead_tab.odin`,
`src/claude_reload.odin`, `src/ui_claude_reload.odin`, `src/claude_accounts.odin`, `src/claude_disk.odin`,
`integrations/claude-code/`, `tools/deckhand-cli/`.

## 1. The tab

- A Claude tab is a terminal tab (`Tab_Kind` `Claude_Tab`) inside an open session, like a shell
  tab, never in Home; it is the first tab only of a Claude-only session (below). It starts
  `$SHELL -l -c '<check>; exec claude "$@"' claude --plugin-dir <plugin> [--resume <id>] [flags]`
  in the session's folder (or a folder inside it), so `claude` gets the user's login PATH and
  environment. Deckhand does not set `CLAUDE_CODE_DISABLE_TERMINAL_TITLE`, does not touch
  `CLAUDE_CONFIG_DIR` (an inherited one is respected) and never switches accounts. Claude Code's
  session markers (`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ID`,
  `CLAUDE_PID`…) never reach a tab: Deckhand started from inside a Claude Code session would
  otherwise start its Claude tabs as that session's children (no transcript saved). Started
  there, the parent's `CLAUDE_CONFIG_DIR` and other `CLAUDE_*` settings count only when the login
  shell sets them too, or gives no answer (docs/DEVELOPING.md, "Launch environment";
  `DECKHAND_GUI_LAUNCH=0` keeps them). When `claude`
  is not on that PATH, the tab prints why and how to fix it (exit 127).
- **Where it opens.** `new_claude_tab` with `session`; or with `project_id`: the project's session
  on screen, else its most recently shown open session, else a new pi session is started to hold
  it.
- **Claude-only sessions.** `new_claude_session {project_id, cwd?, args?}` (the user's one **New
  session**: **+ New session**, a project's **+** and **…** menu, the **⌄** menu, ⇧⌘N, the File
  menu and the palette; its harness picker's **Claude Code** row, or at once when Claude Code is
  the only harness installed: `src/harness.odin`) makes an open session with `agent = .Claude` (`Session_Agent`, `src/state.odin`):
  its first tab is a Claude tab (its *main tab*) and it has no pi tab; other tabs open beside it
  as in a pi session. Rules where pi sessions assume a pi tab first:
  - **Key.** `Open_Session.pi_session_id` holds the main tab's Claude session id (set by its
    `claude.session`, also after `/clear`); pins, hide, unread, the Open group, `open_session`, the
    bell and the snapshot key on it as for pi. `""` until SessionStart reported (such a session
    has no list row and is not saved).
  - **Close.** The main tab closes only with the session (`close_tab` refuses it, as a pi tab).
  - **pi-only machinery** finds no pi tab (`session_pi_tab` = nil) and does nothing: the bridge,
    pi's panels, pi's hot reload and `pi_restart`. Claude has its own: the dead-tab bar
    (`tab_is_dead` covers Claude tabs; **Restart** is `claude_restart`, §4), the Claude bars and
    restarts (§4a), Todos and Subagents (§6a), and comments' Send now, Send and close and Changes'
    **Ask Claude to review**, which go to its main Claude tab (§6, §4b). A dead main tab keeps its
    output and the dead-tab bar in its session; the session still focuses, reports and closes.
    Comments made in it go to its Claude tab with the next message (§6).
  - **Status** rolls up from its tabs like any session (OSC 7501, `agent_status.odin`); the bell's
    "looking at it" is its main tab on screen.
  - **Title**: the history entry's (§4), "Untitled Claude session" before the first prompt. Its
    main tab reads "Claude · <project>".
  - **Claude chats.** `new_claude_session` with the Chats `project_id` (**New chat**'s
    picker: **+ New chat**, ⌘N, the **⌄** menu, File, the palette) starts one in the chats folder (made
    at the first chat); its row is in Chats, marked Claude; it is saved and restores into Chats.
    A Claude tab may open in a pi chat too (**New Claude tab**). With **Chats: read-only** off they
    start like a project's (the user's flags, no profile), as pi's chats are full pi then; with it
    on, read-only (§1a).
  - **Who.** `new_claude_session` is `Anyone` (the user, Atlas, scripts; never a pi or Claude tab,
    which gain nothing); an agent's opens behind (never changes what the user sees) and cannot pass
    flags.
- **Default flags** (`set_claude_default_flags`, user-only, off by default: the Settings tab's
  "Claude Code (global)" group: **Default flags for new tabs** (what is on), **Skip permissions**
  with **Turn on**/**Turn off**, and a warning line; the palette's **Claude Code: skip permissions in new tabs**). Turning it
  on is confirmed (`confirm_gate`, the user only, with the warning). `claude_start`'s `defaults`
  (`claude_with_defaults`) adds `--dangerously-skip-permissions` after the tab's flags at each
  start the USER makes: `new_claude_tab`, `new_claude_session` (a Claude chat too) and
  `claude_resume` with caller `ui`, a restored tab's start when shown, and the user's restart. It
  is the setting as it is at that start and is never saved into a tab's or a record's flags, so
  turning it off takes it from every later start. Not when the flags name it or set
  `--permission-mode`, nor past `CLAUDE_ARGS_MAX` (left out silently). Agents, scripts, panels
  and apps never get it (their starts pass no defaults). A read-only start (§1a) leaves it out
  and a toast says so.
- **Claude Code not installed.** `claude_installed()` looks for an executable `claude` (stat and
  `access(X_OK)` only, never run) on the PATH new tabs get (`child_base_env`, the login
  environment) and in `~/.local/bin` and `~/.claude/local` (where the tab's command also looks).
  Cached; looked up again after **Refresh shell environment**, after a Claude tab exits 127, and
  at the user's click while the cache says "no". While missing: every command that would start
  claude (`new_claude_tab`, `new_claude_session`, `claude_resume`, `open_session` of a Claude
  row) is refused with how to install it (`CLAUDE_MISSING`; the user also gets it as a toast),
  the menu, **+** and palette rows keep their place and read "… — Claude Code not installed",
  the rows of past Claude sessions still list, and a restored Claude tab is not started: its
  terminal says why and it shows as exited (exit 127), with no bell entry and no retry.
  The snapshot says `claude_installed`. pi works the same without Claude Code.
- **Flags.** Extra `args` come only from the user (and test scripts), at most 16; flags Deckhand
  sets or that pick another conversation (`--plugin-dir`, `--resume`/`-r`, `--continue`/`-c`,
  `--session-id`, `--fork-session`, `--print`/`-p`) are refused. They are kept with the tab and
  the history entry and passed again on resume and restore. Only their count is logged.
- **Plugin path.** `DECKHAND_CLAUDE_PLUGIN` (absolute; development), else
  `Deckhand.app/Contents/Resources/claude-code`, else `claude-code` next to the binary (a bare
  build: `build.sh` copies `integrations/claude-code` to `build/claude-code`). The CLI is
  `deckhand-cli` next to Deckhand's binary (`Contents/MacOS/deckhand-cli`), passed in `DECKHAND_CLI`,
  so the plugin and the app always match.
- **Tests.** `DECKHAND_CLAUDE_CMD` replaces the whole command line after `-c` (like `DECKHAND_CMD`
  for pi); it gets the same arguments as `"$@"`. `tests/scripts/fake-claude.py` is a fake claude
  that runs the plugin's hooks with Claude Code's JSON and logs what it got.

## 1a. Read-only Claude (chats while Chats: read-only is on)

**When.** A Claude tab starts read-only (`claude_tab_readonly`) when it started read-only before
(`Claude_Tab.readonly`, saved with the tab), its session is a chat while
`Settings.chats_readonly` is on (`claude_chat_readonly`), or the conversation it resumes ran
read-only (`Claude_Record.readonly`, saved in the history). It is decided in `claude_start`
itself, at **every** start: new, resume (a row, `claude_resume`, `new_claude_tab resume`),
restore, Restart (`claude_restart`, the dead tab's bar, a hung process's wait), whoever starts it.
It is the tab's, not the user's flags: an agent's resume or restart, which drops the user's
flags (§3), still gets it. Once read-only, a tab and its conversation stay read-only (turning the
setting off later does not loosen them; a new chat starts full); `--settings` is not kept by
`--resume`, so it is passed again each time.

**The profile** (`claude_readonly_profile`, last in argv, after the user's flags):

- `--permission-mode plan` (Claude Code: reads and read-only shell commands; anything else asks).
- `--setting-sources user`: the chats folder's project settings, hooks and `.mcp.json` are not
  loaded (a full chat could have planted them).
- `--settings <json>` (Deckhand's, inline; it outranks user and project settings; only managed
  settings outrank it): `permissions.defaultMode` plan, `disableBypassPermissionsMode` and
  `disableAutoMode` `"disable"` (no bypass, no auto-mode classifier approvals),
  `permissions.deny` (the tools below, and `Bash(x)`/`Bash(x *)` for pi-kit's mutating programs
  and git verbs: Claude Code applies a deny rule to every subcommand, a layer that holds if the
  guard does not run), `disableAllHooks: false` (a project setting cannot turn the guard off),
  `disableSkillShellExecution: true` (skills' `` !`cmd` `` never runs: it bypasses PreToolUse; Claude Code's bundled and managed skills are exempt), and
  the guard: a sync PreToolUse hook, matcher `*`, `'<deckhand-cli>' hook readonly || exit 2`,
  `timeout` 30, `onFailure: "block"`; and the **ack**: a SessionStart hook
  `'<deckhand-cli>' hook readonly-ack <nonce>` (below).
- `--disallowedTools Edit Write NotebookEdit MultiEdit PowerShell Monitor Agent Task Workflow
  CronCreate CronDelete ScheduleWakeup RemoteTrigger EnterWorktree ExitWorktree Artifact mcp__*
  ListMcpResourcesTool ReadMcpResourceTool ExitPlanMode` (`CLAUDE_READONLY_DENY`). A bare tool
  name in a deny rule takes the tool out of Claude's context; no mode (Shift+Tab), allow rule,
  `--allowedTools` or settings level below managed can give it back
  ([permissions](https://code.claude.com/docs/en/permissions): "If a tool is denied at any level,
  no other level can allow it").
- Environment: `DECKHAND_CLAUDE_READONLY=1` (for Claude's commands and the user's own hooks to see;
  the guard does not need it). Never inherited by other children (`term.odin` `child_env`).

**The user's flags** in a read-only tab: only `--model`, `--effort`, `--fallback-model` (with a
value) and `--verbose` (`CLAUDE_READONLY_KEEP`, an allowlist: a denylist would miss the next flag
that loosens it, e.g. `--dangerously-skip-permissions`, `--permission-mode`, `--settings`,
`--setting-sources`, `--allowedTools`, `--tools`, `--mcp-config`, `--add-dir`, `--agents`,
`--plugin-dir`, `--disallowedTools`). Others are refused when given (`new_claude_session`,
`new_claude_tab`: "… cannot go into a read-only chat …") and left out of a start when saved (from
before the tab was read-only); the tab and history keep them.

**The guard** (`tools/deckhand-cli/readonly.odin`, `deckhand hook readonly`): reads PreToolUse's
JSON; Bash: denies pi-kit's MUTATING (ported by hand: Odin's regex has no lookahead; the same
cases as pi-kit in `tests/readonly-vectors.json`), background commands (`run_in_background`, as
pi's read-only `bash_bg`), and `deckhand`/`deckhand-cli` act verbs; other tools: allowed only from
`READONLY_TOOLS` (Read, Glob, Grep, WebFetch, WebSearch, todos and tasks, AskUserQuestion,
EnterPlanMode, ToolSearch, LSP, Skill), so a tool a newer Claude Code adds is denied until
listed. Deckhand adds checks pi-kit's list does not have yet (`m_deckhand`; the vectors'
`deny_deckhand`): `git clean|restore|pull|add|init|update-ref`, `git
config` unless it only reads (`--get…`, `--list`; any set or unset is blocked), `rmdir`,
`unlink`, `ln`, `truncate`, `wget`, `dd of=`, `find -delete`, `perl -i` (the switch, not
`-MList::Util`), `curl` writing a file (`-o`, `-O`, `--output`, `--remote-name`, `-c`, `-D`),
`tar` extracting or creating. These match only as the command word of a segment (after
assignments, keywords and wrappers such as `sudo`, `xargs`, `env`, `command`, `timeout`; by
basename, so `/bin/ln`; also inside `$(…)` and a shell's `-c` string) or as git's subcommand
after its global options (`git -C . add`), so `cat ln.txt`, `grep -rn unlink src` and `git log --
add.md` run. `git config` has no scoped deny rule (it would block `--get`); the guard decides.
**ExitPlanMode** is denied: Claude cannot ask to leave plan mode (the user still can with
Shift+Tab). Plan mode is a permission mode, not the tool: per the permission-modes docs Claude
"reads files, runs shell commands to explore" and proposes; ExitPlanMode only presents a plan
for approval and leaves the mode, so without it Claude answers in the conversation. A denial exits 2 with the reason on stderr and the deny JSON on stdout; an allowed call
exits 0 with no output (never an `allow` decision: plan mode and Claude Code's own checks still
apply). Input it cannot read is denied. It needs no socket and nothing from the environment.

**Why Bash is allowed (for parity with pi's read-only chats when they ran read-only bash under
pi-kit; pi's read-only chats now have no bash at all, pi's own `--tools` allowlist) and why it
fails closed.** Claude Code treats a hook that cannot start, crashes, exits other than 0 or 2, or
times out as a *non-blocking* error unless the hook sets `onFailure: "block"` (v2.1.295+; hooks
docs, "Block the action when a hook fails"); exit 2 always blocks a PreToolUse call. So:
the CLI is named by its absolute path in Deckhand's own `--settings` (no PATH, no environment);
`|| exit 2` turns a missing or crashing CLI into a block even where `onFailure` is unknown;
`onFailure: "block"` covers a timeout; a read-only tab never starts without the CLI
(`claude_start`). If the guard still did not run, plan mode and the scoped deny rules remain.

**The ack: the profile must prove it loaded.** A Claude Code that rejects or ignores a key of
Deckhand's `--settings` (older than `onFailure`'s v2.1.295, or a different build) could lose the
guard and the deny rules silently. So the same `--settings` holds a SessionStart hook,
`'<deckhand-cli>' hook readonly-ack <nonce>`: a fresh 128-bit nonce per start, sent with the tab's
token as `claude.readonly_ack` (the tab's own, once). Deckhand **stops** the tab (kills its process
group, revokes its token, the terminal says why, the label reads "read-only guard not confirmed:
stopped") when no ack came within 10 s of its session report or 120 s after Claude's prompt came
up (bracketed paste on, or its OSC 7501 reporting other than blocked: not while a trust, login or
onboarding dialog sits open; the chats folder is not pre-trusted), or when a prompt is submitted
before the ack. The terminal's note names both causes (a startup dialog left open, or a Claude
Code that ignores Deckhand's settings). Why the ack can only come from that hook: Claude runs no tool
before the first prompt, and a prompt before the ack stops the tab, so nothing Claude runs can
send it; the nonce is new at each start (an old one is refused) and the token is the tab's own.
What can still send it: same-user code below the tab before the first prompt (the user's own
SessionStart hooks, a login profile): the user's trust, as §3. Restart tries again.

**Across a relaunch** (`keep_sessions`, on by default: the session holder keeps the tab's process
while Deckhand is closed). The ack state (needed, acked, a hash of the nonce) is saved per holder
terminal in the MAC'd `tokens.json` (PROTOCOL.md §2). When Deckhand reopens and adopts a
read-only tab, it keeps running only if that file verified and says it acked
(`claude_adopt_ro_ok`); otherwise (no file, a bad MAC, no entry, not acked yet) it is stopped as
above (`claude_adopt_ro_stop`; the terminal says "read-only guard not confirmed after Deckhand
reopened: stopped. Restart this tab.").

**Deckhand's own check.** A read-only tab's token may not send `browser_click`, `browser_type`,
`browser_press`, `browser_select`, `browser_upload`, `browser_hover` (it can fire page scripts),
`app_input`, `app_call`
(`claude_readonly_refuses`, before the command runs): reading, screenshots and navigation stay, as
for pi. pi's read-only chats have none of the bridge's tools (pi's `--tools` allowlist).

**State.** A read-only Claude tab says `"readonly": true` in the snapshot, and so does its history
entry. Read-only conversation ids are also kept apart (`claude_readonly_ids`, saved: the 10,000
most recently used, an id marked again moves to the back; a load puts the saved list first, then
read-only history entries it lacks while there is room), so a resume stays read-only after its history entry is gone (the 100 cap, or dropped on
load). The tab's label says what its process started with: "read-only" (`Claude_Tab.readonly`);
a full tab still running in a chat after the setting went on: "read-only after restart"; a tab not
started yet: what it will start as.

**With restarts (§4, §4a).** Restart with model… pastes `/model` into a read-only tab too: it only
changes the model, which a read-only tab may (`--model` is on its allowlist). Every restart
(the dead tab's bar, `claude_restart_changed`, the hung-process wait) goes through `claude_start`,
which applies the profile and a new ack. The settings-file watch is unaffected: the profile's
settings are inline, never a file.

## 1b. Accounts

`src/claude_accounts.odin`. **An account in Deckhand is a Claude Code config folder**: what
`CLAUDE_CONFIG_DIR` names (its sign-in, settings, transcripts). Sign-ins from the environment
(`ANTHROPIC_API_KEY`, `apiKeyHelper`, Bedrock, Vertex) need no folder and are untouched: claude
inherits the login environment as before. Deckhand stores folders and names, never a secret.

- **Sources** (all optional): the **default**, `CLAUDE_CONFIG_DIR` of the login environment when
  absolute, else `~/.claude` (always listed; never removed); `~/.claude` when the default is
  another; folders **found by stat only** (never read): `~/.claude*` and `~/.config/claude*`
  (or `$XDG_CONFIG_HOME/claude*`) holding `.claude.json` or `.credentials.json` (at most 32);
  folders the user **adds** anywhere (`add_claude_account`: Settings, the palette, the setup
  sheet). Labels come from the folder's name (`.claude-work` → `Work`); the user renames,
  removes (not the default) and chooses the **default for new sessions**
  (`set_claude_account_default`). No alias or folder name is assumed.
- **One account**: no account UI at all (no picker, no tags, no Settings rows but **Add
  account…** and **Scan again**), and every start is as before.
- **Starting.** A tab and a history entry keep their account's folder, written at a start (an
  entry from before accounts has none: the default as resolved when it is used, never stamped at
  load). Every start (new, resume,
  restore, restart, the read-only profile) sets it: nothing for the default; else
  `CLAUDE_CONFIG_DIR=<folder>` in the tab's environment and again in its shell after the login
  profile ran (`CLAUDE_ACCOUNT_SH`), so a profile that exports `CLAUDE_CONFIG_DIR` cannot move a tab
  to another account; `~/.claude` while the default is another: `CLAUDE_CONFIG_DIR` unset. A tab
  or entry whose account is no longer configured does not start (its tab says why).
- **Picking.** `account` on `new_claude_tab` / `new_claude_session` names a configured account
  (label or folder); agents can never name a folder of their own. Left out: the project's last
  account, else the chosen default, else the last used, else the environment's default.
- **The guard covers every account.** `claude_config_dirs` is `~/.claude`, the default, every
  found folder and every folder in the setting, removed ones included while they hold Claude
  Code's files (a removed hand-added folder without them is given back). So an account folder
  may not be HOME or above it, nor hold a project, the main folder or the chats folder
  (`claude_account_dir_refused`): their transcripts,
  state and sign-ins are refused to agents and the Files and Settings trees exactly as
  `~/.claude`'s (§3), the transcript-path check (§4b) accepts any of their `projects/`, and hot
  reload (§4a) watches each running account's config.
- **First run.** The setup sheet (GUIDE.md "The first run") has an accounts step when two or more
  are found: tick, rename, add (picker or typed path; a folder without the marker files is added
  with a warning), default. Done sends the same commands as Settings.

## 2. The plugin

`integrations/claude-code/` (copied into the bundle by `scripts/bundle-app.sh`):

| File | What |
|---|---|
| `.claude-plugin/plugin.json` | name `deckhand` |
| `.claude-plugin/marketplace.json` | lets the folder be added as a marketplace; **not published** (Deckhand passes `--plugin-dir`, nothing is installed) |
| `bin/deckhand` (and `bin/pi-desk`, an alias kept for pi-kit and older sessions) | on Claude's Bash PATH: `exec "$DECKHAND_CLI" "$@"`. Outside a Deckhand Claude tab: `hook readonly` exits 2 (denied), other `hook …` exit 0 silently, anything else prints an error JSON (exit 2) |
| `hooks/hooks.json` | SessionStart → `deckhand hook session-start`; UserPromptSubmit → `prompt-submit`; Stop → `stop`; StopFailure → `stop-failure`; Notification → `notification`; async (§6a): PostModelSwitch → `model`, PostToolUse `TodoWrite` → `todos`, PostToolUse `TaskUpdate` → `task-update`, PostToolUse `Bash` → `bash-bg`, TaskCreated → `task-created`, TaskCompleted → `task-completed`, PreToolUse `Agent\|Task` → `agent-launch`, PreToolUse `*` → `agent-tool`, SubagentStart → `subagent-start`, SubagentStop → `subagent-stop` |
| `skills/deckhand/SKILL.md` | a short stub: what the command is for; `deckhand --skill` prints the manual (`tools/deckhand-cli/manual.md`, embedded in the CLI) |

**The CLI** (`tools/deckhand-cli/`, Odin, no dependencies) mirrors the pi integration's `browser` and
`desk` extensions (`integrations/pi/extensions/`): `tabs`, `open`, `navigate`/`back`/`forward`/`reload`/`stop`, `read`,
`screenshot`, `wait`, `click`, `type`, `press`, `scroll`, `select`, `hover`, `upload`,
`console`, `network`, `comments`, `state`, `app call|screenshot|input|events`,
`app open|close|restart|list-declared`, and `show PATH [--line N | --anchor HEADING]`
(`show_file`, pi's `desk_show`: show the user a file in a tab of its own session, behind the
user's view; display only, so a read-only tab may use it). `deckhand --help` lists them. It prints one
JSON object per call. Page and app text is never a top-level field: it goes in `content`, after
the same untrusted-data note as the pi integration's browser tools and inside a fence longer than
any run of backticks in it. Screenshots are PNG files Deckhand writes in `DECKHAND_SHOTS_DIR`; the CLI checks the path
is directly in that folder, named `<tab>-<n>.png`, a PNG and at most 8 MB, then prints it (Claude
opens it with Read). Refusals keep Deckhand's `code` and add the same `hint` as the pi integration.

**The hooks** (`deckhand hook <event>`, reading Claude Code's hook JSON on stdin; never fail
Claude: errors exit 0 with nothing printed; the one exception is `hook readonly`, the read-only
guard, which is not in `hooks.json` but in Deckhand's `--settings` for read-only tabs and exits 2
to deny, §1a):

- `session-start` → `claude.session {session_id, cwd, source, transcript_path, model}` (the
  transcript's path only, never its content), and `claude.turn idle` for the sources `startup`,
  `resume` and `clear` only (a `compact` can run in the middle of a turn; a fork's state is
  unknown: their next Stop reports idle). When Deckhand answers with the user's title (§4b) it
  prints `{"hookSpecificOutput":{"hookEventName":"SessionStart","sessionTitle":…}}` and nothing
  else.
- `prompt-submit` → `claude.turn submitted` (with the prompt's first line as `title`), then
  `claude.comments`; if there are comments it prints
  `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":…}}` (the
  comments' text, then each crop's file path with the image number the text gives it; all of it
  under the hook's 10,000 character limit, or nothing at all and the comments stay pending) and
  sends `claude.attached`.
- `notification` `idle_prompt` → `claude.turn idle` with `idle_prompt: true` (not a turn's end:
  the dots stay).
- `stop` → `claude.background snapshot` (its `background_tasks` and `session_crons`, when Claude
  Code sends them: §6b), then `claude.turn idle`, with `question: true` when
  `last_assistant_message` ends with `?` (only the flag goes; the text never leaves the hook); `stop-failure` → `claude.turn error`
  (never the error's words); `model` (async, PostModelSwitch) → `claude.model {to_model}`;
  `notification`: `permission_prompt`, `elicitation_dialog`,
  `elicitation_url_dialog`, `agent_needs_input` → `claude.turn waiting`; `idle_prompt` → `idle`.
- `todos`, `task-*`, `agent-launch`, `agent-tool`, `subagent-*` → `claude.todos`, `claude.task`,
  `claude.subagent` (§6a); `bash-bg` and `subagent-stop`'s snapshot → `claude.background` (§6b).
  `agent-tool` runs at every tool call (async) and reports only inside a subagent (`agent_id`);
  for the main conversation's calls it exits without connecting. Async (`"async": true`): Claude never waits for them; they print
  nothing ever (Claude Code would hand an async hook's JSON output to Claude on its next turn), so
  they add nothing to Claude's context or token use.

## 3. The credential and its threat model

**What the tab gets.** At each start Deckhand mints a fresh 256-bit token (any earlier token of
the tab is revoked first) and puts it in the claude process's environment as
`DECKHAND_CLAUDE_TOKEN`, with `DECKHAND_SOCKET`, `DECKHAND_CLI`, `DECKHAND_SHOTS_DIR` and
`DECKHAND_CLAUDE_TAB`; also `PI_KIT_NOTES_DIR` as pi tabs get it (`notes_env_pi`: the main folder,
unless the user's own environment sets it). Shell tabs and other children never get these (they are removed from their
environment, `term.odin` `child_env`). The token is never in State, events, replies, the command
log or the workspace file.

**What it is.** Caller `{kind: panel, tab_id: <the Claude tab>, claude: true}`:

- every check that applies to a pi tab's bridge applies unchanged (`caller_may` in
  `src/commands.odin`, the command table's `who`, and each command's own session checks:
  `browser_*` and `app_call`/`app_screenshot`/`app_input`/`app_events`/`app_restart`/`app_close`
  only on its own session's tabs; `new_app_tab` only by an `apps.json` name, in its own session,
  behind the user's view (`deckhand app open NAME`; refused in a read-only chat, as `app call` and
  `app input` are; Deckhand asks nothing: the plugin's skill does not pre-approve `app open`,
  `app restart` or `app close`, so Claude Code's permission mode decides, docs/ENGINE-BRIDGE.md
  trust model); `show_file` (`deckhand show`) in its own session, behind the user's view;
  `get_state` filtered to its own session; the self-reference rule; confirmation policy of
  the `panel` caller);
- **minus** the pi bridge's reports: `pi.session`, `pi.status`, `panel.set`, `panel.remove`,
  `pi.attached` (`who` `Report`/`Bridge` are refused for a claude caller, and a claude connection
  never counts as the session's bridge: no `pi.attach`/`pi.prompt` is routed to it);
- **plus** `claude.session`, `claude.turn`, `claude.comments`, `claude.attached`,
  `claude.todos`, `claude.task`, `claude.subagent`, `claude.model` (`who` `Claude`) for **its own tab only** (the tab id is filled from the token; another id is
  refused). A pi tab's token cannot send these.
- Not valid for anything of the control set: no `send_text`, `pi_prompt`, `claude_prompt`, `claude_wait_idle`,
  `new_claude_tab`, `claude_restart`, `close_tab`, settings, Home, jobs, confirmations, Take over/Stop or Allow
  (those are the user's). `list_commands` lists exactly what it may send.

So a Claude tab can never do more than its session's pi tab can; it can do less.

**Multi-use, but only from its own processes.** pi's bridge swaps its env token for an
in-memory reconnect token at its first hello. That does not work here: the plugin's CLI and hooks
are a new process per call and have nowhere private to keep a second token. So the env token
stays valid until the tab exits or closes, and Deckhand adds a process check: at `hello` it reads
the connecting process's pid (`getsockopt(LOCAL_PEERPID)` on the Unix socket) and walks its
parents (`proc_pidinfo` `PROC_PIDTBSDINFO`, at most 64 steps) until it reaches the tab's own
process (the login shell that execs claude, recorded at start). Anything else gets `"this token
works only from its Claude tab's own processes"`. Off macOS the check fails closed.

**What the check is worth.** It stops naive reuse of a token read from outside the tab (`ps
eww`, a log, a crash report → connect from another program). It does **not** stop a same-user
attacker: code the user's account runs can arrange to run below the tab's process. The root is
`$SHELL -l`, so `~/.zprofile` (or `~/.bash_profile`) runs inside it; Claude Code runs the user's
own hooks (`~/.claude/settings.json`), MCP servers and commands; a shim earlier on PATH runs in
place of a tool Claude calls. Each of those is a descendant and gets the token. Against same-user
code the boundary is the user's account, as it is for pi tabs.

**Revocation.** When the tab's process exits or the tab closes (or Deckhand quits), the token is
revoked and its open connections are shut (`socket_forget_tab`); held messages are dropped.

**Threats and what stops them:**

| Threat | Mitigation | Left over |
|---|---|---|
| Another program reads the token (`ps eww`, a log, a crash report) and connects | the process check: it is not below the tab's process | anything that runs below the tab's process may use it: what Claude runs (Bash commands, MCP servers, the user's hooks) is the same trust as Claude, which can run `deckhand` anyway; same-user code that plants itself there (login profile, Claude settings hooks, a PATH shim) is not stopped |
| Prompt injection from a web page or app makes Claude misuse its powers | the same server-side rules as pi tabs: own session only, no JS eval, refused password/card/OTP fields and iframes, uploads and downloads wait for the user's Allow, Take over/Stop; page text fenced and labelled untrusted | whatever a pi tab could be talked into in its own session's tabs |
| Claude (or something it runs) reaches other sessions, closes or types into tabs, changes settings, approves its own requests | `caller_may` and the per-command session checks, as for pi tabs; confirmations are the user's | — |
| A token outlives its tab | revoked on exit/close; a restart mints a new one | — |
| Reports forged for another tab (hijacking resume, clearing another session's comments, writing another tab's panels) | claude.* only for the token's own tab; ids checked (`claude_id_ok`) before they reach argv; a session id already in another project's history is refused (`"that Claude session belongs to another project"`), so its entry's folder and flags are never rewritten | — |
| Page text typed into Claude's prompt by Send now (`@path` could attach a file) | Send now types only a fixed line; the comments go as hook context, fenced and labelled data | — |
| Claude's todo and subagent text (untrusted: a page can put words in Claude's mouth) shown in Deckhand | Deckhand builds the rows itself (no tones, ids or rows from the token); text one line, control, bidi and invisible characters dropped, ≤ 140 bytes; at most 50 todos, 16 subagents, 8 launches per tab; only on the token's own tab, never on pi's tab or panels (`panel.set` is pi tabs' only); refused once the tab is not running; never saved or logged | a todo can still *say* something misleading, as Claude's own output can |
| Text from an agent becoming a command, a file attachment or a dialog answer | `claude_prompt` refuses text starting with `!`, `/`, `#` or `&` (shell, slash command, memory; `&` in case a newer Claude Code uses it), text with an `@file` mention (`@/`, `@~`, `@.` at a word's start) and text with control characters other than tab and newline; held text goes only as a bracketed paste; **Send now** only at an idle turn | a dialog that opens without any hook while the turn is idle |
| An agent's resume replaying the user's flags (a permission bypass, `--settings`, `--allowedTools`, `--mcp-config`, …) | only the user's own resume or restart (caller `ui`) replays a session's saved flags; anyone else's `claude_resume` or `claude_restart` (Atlas, control, scripts) starts claude with only `--plugin-dir` and `--resume <id>` (the history and the tab keep the flags for the user); an agent that opens or focuses a restored session, or brings it to the front any other way (a new tab in it, a file opened in it, closing the one before it), never starts its Claude tabs (they keep the user's flags and wait, `not_started`, for the user to show them) | by design, a restored tab (§4) starts with its own saved flags whoever shows its session first |
| A Claude tab claiming another session's id (a prompt-injected Claude reporting its pi session's id, so that the pi row resumes Claude with the user's flags; or a `/resume` to a conversation open elsewhere) | `claude.session` refuses an id that is a pi session's (listed, its file in the project, or an open session's) or that another tab runs (`"that id is another session's"`); `open_session` looks for the pi session's file before the Claude history; a history entry with a pi session's id (older data) is not a second row | — |
| pid reuse: the tab's process exits and its pid is reused by another program | the token is revoked when the process exits, before the pid is recorded again | the window between exit and Deckhand reaping it (milliseconds) |
| The user resuming a read-only conversation by hand (`/resume` inside a full Claude tab, or `claude --resume` in a shell) | Deckhand's own resumes keep the profile (the history entry is read-only) | Claude Code's own `/resume` inside a tab runs with that tab's flags: the user's choice |
| A Claude tab in a read-only chat writing files, running mutating commands or scheduling work (§1a) | plan mode; bare-name deny rules for the tools that write, run in the background, spawn agents, schedule, publish or reach MCP (no mode, allow rule or flag gives them back); scoped Bash deny rules and the guard's MUTATING check (pi-kit's list, shared vectors), failing closed (`onFailure: "block"`, `\|\| exit 2`, absolute CLI path, never started without it); `--setting-sources user`; no bypass or auto mode; the user's flags from an allowlist; the profile is the tab's and applies at every start by anyone (restore, an agent's resume or restart) | as pi's read-only chats had under pi-kit alone (they now have no bash): Bash that writes without a listed word (`python -c`, `node -e`, `npm run`, `make`, `curl -X POST`, `git -c alias…`, a script file, `dd`, `install`, `ln`, a `$(…)`-built word) runs if plan mode lets it (it asks for anything it does not see as read-only; the user can approve), and runs **without asking** when the user's own allow rules in `~/.claude/settings.json` approve it (e.g. `Bash(npm run *)`): those rules skip plan mode's prompt for any command the guard does not recognise; the network (WebFetch, `curl` without writing a file) stays |
| An older or different Claude Code ignoring Deckhand's `--settings` (no guard, no deny rules) | the profile's SessionStart ack with a per-start nonce; no ack within 10 s of the session report or 120 s after its prompt came up, or a prompt before it: Deckhand stops the tab and revokes its token | same-user code that runs before the first prompt could send the ack (the user's own SessionStart hooks): the user's trust |
| The user's own Claude Code hooks, MCP servers and settings in a read-only chat | `--setting-sources user` drops the chats folder's project settings; MCP tools denied (`mcp__*`) | the user's own hooks (`~/.claude/settings.json`) and managed settings still run with the user's trust (Deckhand cannot and does not edit them); a user MCP server still starts (its tools are denied); managed `disableAllHooks` would turn the guard off (plan mode and the deny rules remain) |
| Leaving plan mode in a read-only chat | ExitPlanMode is denied (Claude cannot ask); the denied tools stay denied in every mode; bypass and auto mode are disabled; the guard runs in every mode | the user's own Shift+Tab: in default or acceptEdits mode Claude Code may run more Bash without asking (acceptEdits: some file commands) — the guard and the scoped deny rules still block Deckhand's list |
| A read-only tab acting on pages or apps through `deckhand` | Deckhand refuses the act commands from its token (`claude_readonly_refuses`); the guard denies the CLI's act verbs | none (pi's read-only chats have no such tools at all) |
| A user's own `deckhand` or `pi-desk` executable earlier on PATH shadows the plugin's `bin/deckhand` or `bin/pi-desk` | none (Claude Code appends plugin `bin/` to PATH) | it would get the token from the environment like any child; document, do not ship such a tool |
| The comment crops Claude reads | copies in `DECKHAND_SHOTS_DIR` (the user's data dir), created 0600, removed after a day | — |
| Same-user code that can read Claude's memory or ptrace it | none: out of scope (as for pi tabs) | — |

The error for a wrong process (vs `unknown token`) tells a caller holding a valid token that it
is valid; it learns nothing it can use from outside the tab.

## 4. Resume and restore

- `claude.session` (SessionStart, also after `/clear`, `/compact`, `--resume` and a fork) keeps
  Claude's session id with the tab and moves it to the front of `claude_history` (saved as
  `claude_sessions`, at most 100, with its folder, project and flags). The first submitted
  prompt's first line (≤ 80 characters) is its title, unless the user named it
  (`claude_rename`, the row's **Rename…**: Deckhand's own title, Claude Code never sees it);
  each submitted prompt marks it used. Titles are never logged.
- **Rows.** Each entry is a row of its project's session list (`sidebar.odin` `claude_rows`,
  `Session.claude`), with the pi sessions, marked **Claude**, sorted and filtered with them
  (title, last use, its open session's or tab's status dot; pins and hide by its id). Its created
  date is its transcript file's when §4c found it, else its last use. Conversations started
  outside Deckhand are listed from the transcripts (§4c); Deckhand never reads Claude Code's other
  files. Its ⓘ, **Copy session info**, **Send to
  Atlas**, **Reveal in Finder** and **Copy path** work from Deckhand's own record (§4b). A click sends `open_session` with its id: an open one is
  focused (its Claude-only session, or its tab in a pi session); a closed one resumes
  (`claude_resume`) in a new Claude-only session with `--resume <id>`, in the folder it ran in
  while that is still inside the project. The list shows every entry, with status, pins and
  filters.
- **Flags on resume.** Only the user's own (caller `ui`: a row click, the menu) replays the
  entry's saved flags; anyone else's, including `open_session` from Atlas, starts claude with
  only `--plugin-dir` and `--resume <id>` (§3).
- A Claude tab is saved with its id, folder and flags (PERSISTENCE.md) and comes back
  `not_started`; it starts with `--resume <id>` when its session is first shown, like the other
  tabs, with **the tab's own saved flags**, but only when the user (or Deckhand itself at launch,
  or a test script) shows it: an agent that focuses or opens the session (`focus_session`,
  `focus_tab`, `open_session`, `claude_resume` from Atlas) leaves its restored Claude tabs
  `not_started` (it sees that in the state), so the user's flags never start for an agent.
  `focus_session` takes the caller (no default), so every path that brings a session to the
  front passes whose it is: an agent's `new_shell_tab`, `open_file`, `open_markdown`,
  `open_changes`, app tab, or `close_session` (which shows the next open session) starts nothing
  of Claude's either. Claude tabs and Claude-only chats in Chats are saved and restored like a
  project's; a read-only one keeps its profile (`"readonly": true` with the tab and the history
  entry, §1a) and starts read-only whoever shows it, whatever the setting is then. A
  Claude-only session is saved with `"agent": "claude"` and its Claude session id once that is
  known, and comes back as a Claude-only session the same way. Without Claude Code installed
  then, the tab does not start (§1).
- **A dead tab.** When claude exits, the tab keeps its output and shows a bar: "Claude exited
  (code N) — its last output is below" and **Restart** (`claude_restart`): claude again in the
  same tab, `--resume <its session id>` (plain without one), a new token. Only the user's restart
  replays the tab's flags (§3); Atlas's or a script's starts without them. Opening the session
  again from its row restarts it too when it is the tab shown, and so does the bell's entry about
  it. A dead Claude-only session's main tab restarts in place from its row, `open_session` or
  `claude_resume` (never a second session with its id; flags only for the user's). Exit 127: "Claude Code isn't installed (or not on your login PATH)"; Restart first looks for
  `claude` (`claude_installed`: the children's PATH, `~/.local/bin`, `~/.claude/local`; stat
  only) and, still missing, says how to install it instead of starting it again: never a restart
  loop, and exit 127 makes no bell entry. Any other non-zero exit code makes a bell entry,
  "Claude exited" (its click restarts it, as the bar's Restart); exit 0 (the user's own `/exit`)
  makes none. A process that closed its terminal without
  exiting is waited for first (killed after 5 s), as for pi.
- **Restart with model…** (a failed exit that is not 127, as for pi; `claude_restart`
  `pick_model`): the same restart, then Deckhand pastes `/model` (Claude Code's model picker) and
  Enter, once, under §5's rules: the hooks' turn idle **and** OSC 7501 not working or blocked,
  bracketed paste on, nothing typed (`claude_paste_message` with `slash`, which takes only that
  fixed text: agents' `claude_prompt` still refuses every `/`). Not ready within 30 s: a toast
  says to type `/model`. Chosen over a picker passing `--model`: the user picks from what their
  Claude Code and organisation offer (no model list to keep in Deckhand), and the model stays a
  choice made in Claude Code, never a flag an agent could pass.

## 4a. Hot reload and Claude Code updates

`src/claude_reload.odin` (the bars: `src/ui_claude_reload.odin`), parity with pi's hot reload
(PROTOCOL.md "Hot reload"):

- **Kept sessions (Keep sessions on, GUIDE.md).** A Claude tab the session holder kept running
  while Deckhand was closed keeps the plugin, hooks and CLI it started with. After an update of
  Deckhand, the updated plugin reaches such a tab only when it restarts: the plugin bar offers
  that Restart as for any other change to Deckhand's plugin.
- **What is watched.** Only what a running Claude Code reads at start (its docs, "When edits take
  effect"; skills, subagents and memory pages): `CLAUDE.md`/`CLAUDE.local.md`/`.claude/CLAUDE.md`
  in the tab's folder and above it and the config folder's `CLAUDE.md`; `rules/`, `output-styles/`,
  `commands/` (config folder and the cwd's `.claude/`); the cwd's `.mcp.json`; `agents/` and
  `skills/` folders appearing (Claude Code only watches those that existed at its start); Deckhand's
  plugin. Settings files, `keybindings.json` and skills/subagents in existing folders are applied
  live by Claude Code: never watched, no bar (`claude_file_class`: Live / Restart / Ignored). The
  config folder is `$CLAUDE_CONFIG_DIR` (as the children get it), else `~/.claude`. A stat poll
  every 2 s while a Claude tab runs; folders by their entries' names, times and sizes. No file is
  read.
- **Restart** (`claude_restart_changed`; `all`: every running Claude tab, changed or not, as pi's
  **Reload all pi tabs**; the palette's **Restart all Claude tabs** and the gear's row): idle tabs (hooks' turn idle, OSC 7501 not working or
  blocked, nothing typed or held, no subagent running) are stopped (hung up on, as a pi restart)
  and started again once the old process exited, through the dead tab's restart wait, with
  `--resume <session id>` and a new token; busy ones queue and go from the frame tick once idle.
  A tab without a Claude session id is never restarted (no `--resume`: it would lose the
  conversation). Always confirmed: Claude's background shells and monitors stop; the confirmation
  names those Claude's last turn reported (§6b; a Claude Code without them: none named). Only the
  user's restart replays the saved flags (§3), also for a queued one. The
  palette also has **Restart Claude tabs for changed settings** and **Restart Claude tabs on the
  new Claude Code** (the bars' Restart), and **Edit Claude settings (settings.json)**, **Edit
  global CLAUDE.md** and **Edit project Claude settings** (`.claude/settings.json`; pi's
  `edit_pi_*` parity; listed while the file is there).
- **Claude Code's version.** The `claude` a tab would start (children's PATH, `~/.local/bin`,
  `~/.claude/local`) and where it links to, by stat and readlink: `…/versions/<v>` (native),
  `Caskroom/claude-code/<v>` (Homebrew), `@anthropic-ai/claude-code/package.json` (npm, bun,
  mise's npm backend), `/nix/store/<hash>-claude-code-<v>/` (nix), `mise/installs/<…claude-code…>/<v>/`
  (mise), and a small `#!` wrapper or shim script's path to `node_modules/@anthropic-ai/claude-code`
  (pnpm's shim, nix's makeWrapper; that script and the package.json are the only files read),
  else the file's identity ("a new build": a mise shim, for one). **Never run** (`claude --version` would
  start Claude Code's own config and update checks). Each Claude tab records it when first seen
  running; another one on disk shows the update bar. Tests: `DECKHAND_CLAUDE_BIN`; none while
  `DECKHAND_CLAUDE_CMD` replaces claude.
- **A Deckhand update** replaces the app and relaunches it. With Keep sessions on (the default),
  Claude tabs run on through it in the session holder (GUIDE.md "Updates"), still on the plugin,
  hooks and `deckhand` CLI they started with: the plugin bar then offers the Restart that moves
  each to the new plugin (as for kept sessions above), and nothing restarts by itself. With it off,
  every Claude tab starts again on the new plugin anyway. The plugin's files are watched for
  development builds (`DECKHAND_CLAUDE_PLUGIN`, `build/claude-code`).
- **Never touched** (`claude_credential`, also via `settings_credential` for the Settings tab, the
  editor, Files and the reload watchers): `.credentials.json`, `.claude.json` and its backups
  anywhere, and everything in a Claude config folder except `settings.json`, `settings.local.json`,
  `CLAUDE.md`, `keybindings.json` and the folders `agents`, `skills`, `commands`, `output-styles`,
  `rules`, `hooks`, `themes`, `workflows` (so `projects/` transcripts, `history.jsonl`,
  `sessions/`, `file-history/`, caches, plugin data and whatever a newer Claude Code adds are
  refused); hard links to those files by inode. Config folders: `~/.claude` and
  `$CLAUDE_CONFIG_DIR` both (whichever one is in use; each also where it links to), and any other
  folder that directly holds a `.credentials.json` or `.claude.json` (another profile's; a user's
  home folder is not one). A config folder that is HOME or above it (by any name): the file names
  only. A relative `CLAUDE_CONFIG_DIR` is ignored (`~/.claude` is used and guarded).
- **Who**: an agent's (`control`, a script's) `claude_restart_changed` is always confirmed by the
  user, whatever its confirm policy, and stays the agent's after the user's Confirm (its own
  session's tabs left out, no saved flags). `claude_reload_later` is the user's;
  `claude_restart`'s `pick_model` is honored for the user only.
- **Settings tab**: "Claude Code (global)" and "Claude Code · <project>" groups (once the config
  folder exists); Claude's settings JSON is saved only when valid (strict); a save of a
  restart-class file shows the Claude bar at once.
- **First run**: the notes folder may also be found in the config folder's `CLAUDE.md` (after
  pi's `AGENTS.md`; only the path is shown; the config folder itself never qualifies); step 3 says
  whether Claude Code is installed (`claude_installed`, stat only).

## 4b. Rows and tabs at parity with pi's

`src/claude_rows.odin`. What a pi row and tab show, from what Claude Code's hooks report (never
its files):

- **Transcript path and model.** SessionStart's `transcript_path` and `model` go with
  `claude.session` and are kept in the history entry (saved: PERSISTENCE.md). The path is kept
  only when it is a `.jsonl` under an account's config folder's `projects/` (§1b): absolute, no `.` or `..` parts, and its real path (symlinks
  resolved; for a file not written yet, its folder's) still inside. Otherwise it is ignored. The
  first path kept for an id stays: a later report (another `projects/<slug>` or file) never
  repoints it. It is
  checked again, file and real path, each time Reveal or Copy path uses it, and on load. The model
  (letters, digits and `-_.:/@[]`, at most 100) also comes from `claude.model` (async
  PostModelSwitch: `/model`, or Claude Code's own switch).
- **Row actions.** A Claude row has pi's ⓘ and menu: **Copy session info** and **Send to Atlas**
  (`session_info`: a `claude-session` block with `id`, `agent`, `file`, `project`, `folder`,
  `title`, `used`, `model`, from Deckhand's record), **Reveal in Finder** and **Copy path**
  (`reveal`, `copy_path` with its id: the transcript, only while the checks above pass; not
  offered otherwise).
- **Model** in the tab's tooltip ("Claude Code · model …"), its session info and the snapshot.
- **Dots.** Stop's `last_assistant_message` ending with `?` → the question dot; StopFailure → the
  error dot (and the turn is over, so held text may go). The CLI looks at the message and sends
  only the flag. They show while the tab runs and OSC 7501 says nothing stronger (working,
  waiting, its own error). Every Stop decides anew (also a turn with no prompt: a background
  wake, `/loop`, after a compaction), so a statement clears an old question or error; the next
  prompt, a dialog, a new conversation (not a compaction) or a new process clears them too.
  Notification's `idle_prompt` (idle a while after the Stop) is sent flagged and leaves them.
- **Title.** The user's **Rename…** (`claude_rename`) marks the entry `named`; at the next
  SessionStart (resume, restart, restore) Deckhand answers `claude.session` with it and the hook
  prints it as `sessionTitle`, so Claude Code shows that name too. A title taken from the first
  prompt is not pushed. A `/rename` inside Claude Code has no hook: Deckhand's name stays its own.
- **Bell.** A Claude tab that exits with a code other than 0 and 127 makes a "Claude exited" entry
  (§4).
- **Worktrees and Changes.** A worktree row's **New session here** (its picker's **Claude Code**) starts a Claude-only
  session of the project in that checkout (`new_claude_session` with `cwd`: a listed checkout of
  the project's repository may be outside the project folder; it resumes there later). In a
  Claude-only session the Changes tab's button reads **Ask Claude to review** and sends the same
  fixed prompt with `claude_prompt` to its main tab (held until it is idle and nothing is typed).
- **Starting one.** There is no separate Claude session action or shortcut:
  **New session** and **New chat** offer the installed harnesses (`src/harness.odin`), and
  `deckhand --claude DIR` adds DIR and starts a Claude session there (the user's own:
  in front; without Claude Code, the toast says how to install it). If DIR cannot be added
  (Chats' folder, say) nothing starts, never in the project selected before; the same for a
  plain `deckhand DIR`'s chat.
- **Not done:** a permission-mode badge (optional; not built).

## 4c. Sessions found on disk

`src/claude_disk.odin`. Claude conversations run outside Deckhand are rows too. Deckhand reads
them **in its own process only**: no transcript path or content ever reaches an agent (the
snapshot's found rows have id, title, dates, account; `session_info`, `reveal` and `copy_path`
work only from Deckhand's own record, so a found row gives them nothing).

- **Where.** For the selected project and Chats, each account's `projects/<folder>/` where
  `<folder>` is Claude Code's own name for the working folder (from Claude Code 2.1.317's
  code, never by running it): every UTF-16 unit that is not an ASCII letter or digit becomes
  `-`; longer than 200: the first 200, `-`, and the base-36 absolute value of its 32-bit
  `h = h*31 + unit` hash. Also the real path's name, and `CLAUDE_CODE_PROJECT_DIR_NAME` (honoured
  as Claude does: only with `CLAUDE_CONFIG_DIR` set, 1–64 of `[A-Za-z0-9_-]`). Names are lossy, so
  a file counts only when the `cwd` it records is the project's folder; a name is **never turned
  back into a path**. Projects where only Claude ran come from the same `cwd` (the newest files of
  each folder, on the Rescan worker).
- **Rows.** Only `<uuid>.jsonl` files (never `agent-*` or side-chain ones); title: a
  `custom-title` or the first real prompt (meta, command and reminder lines skipped), else
  `ai-title` or `summary`; read from the first and last 64 KB only, within a per-frame budget
  (the rest on a worker, cached by size and date), so scanning never blocks a frame. Sorted by the
  file's date; created from the file. Merged by id with Deckhand's record (one row each), under
  the MAX_SESSIONS cap. Chats' rows follow the read-only rules (§1a). A line goes to the JSON
  parser only when it is at most 64 KB and nested at most 64 deep (the parser recurses). The
  title cache drops its oldest entries when full.
- **Projects where only Claude ran** read each folder's newest transcripts' first 8 KB for the
  `cwd` (cached by path, size and date), on the Rescan worker; the launch's first scan reads no
  transcript, nor does restoring the saved workspace (a Rescan follows once the saved accounts
  are back; it drops a saved Claude-only folder no account has transcripts for any more). A
  line is parsed as strict JSON (JSON5's single quotes would hide brackets from the depth
  check). No project, main folder or chats folder may be inside another account's folder.
- **Resume** runs `claude --resume <absolute transcript path>` under the row's account, in a
  Claude-only session; a record whose transcript is gone (by stat: its reported file, else its
  id in its account's folder for the folder it ran in or the project's; a non-ASCII or long name
  never decides) shows greyed, "transcript gone". A recorded session stays in its account:
  `new_claude_tab` with `resume` refuses another `account`.
  **Rescan sessions** covers Claude too.

## 5. Text from agents never lands in a half-typed prompt

`send_text` from `control` into a Claude tab is refused. `claude_prompt` holds the text (at most 8,
64 KB each) and `claude_tick` delivers the first one when `claude_ready` says so:

- the tab is running;
- its **turn** is `idle`: the hooks report `idle` at SessionStart and Stop, `working` at
  UserPromptSubmit (and when Deckhand delivers a text), `waiting` at a permission, question or
  elicitation Notification (`idle_prompt` reports `idle`); `unknown` until the first hook (a
  tab without hooks never receives held text unless the user presses **Send now**);
- Claude's input has **bracketed paste** on (mode 2004, which its prompt turns on): without it a
  newline would send each line as a message and the Enter could answer a startup dialog;
- **nothing typed**: Deckhand marks the tab "typed" when a key that types or edits text, a paste or
  IME text reaches its terminal (not Enter, Esc or ⌘ shortcuts), and clears it when
  UserPromptSubmit reports the user's message went. Text typed and then deleted by hand still
  counts as typed until the next submit: the safe side.

Delivery is a bracketed paste, then Enter 80 ms later; the turn becomes `working` so only one goes
per turn. The user's bar over the tab says who waits and why, with a one-line preview of the
text (control characters shown as spaces, at most 48 bytes), **Drop** and **Send now**. Send now
goes into whatever is typed, and only at an idle turn: refused while Claude works (`"Claude is
busy: wait for its turn to end"`; a permission dialog can be up before its hook reports it),
while it is starting or waiting in a dialog (`"… : answer Claude first"`: its Enter would pick the
dialog's highlighted answer), and without bracketed paste. The preview drops bidi controls and
invisible characters (U+200B–200F, U+202A–202E, U+2066–2069, U+FEFF). `claude_prompt` refuses
text whose first non-blank character is `!`, `/`, `#` or `&` (Claude Code reads the first three
as a shell command, a slash command and a memory) and text with control characters other than tab
and newline (escapes, CR, DEL); and text with an `@file` mention (a word starting `@/`, `@~` or `@.`), which
Claude Code would turn into an attached file.

**Program status.** When Claude Code reports OSC 7501 program status (PROTOCOL.md §5), a held
text and the bar's **Send now** also need it not working and not blocked: `claude_ready` and Send
now require idle per both the hooks' turn and `tab_status_view`, so when they disagree nothing
goes in (never into a dialog). Once OSC 7501 is seen in a tab's process, the tab's status dot,
the unseen dot after a finished turn and the attention sort come from it alone, as for any
terminal tab. Until then (an older Claude Code, §5a) they come from the hooks' turn.

## 5a. Any setup: older Claude Code, hooks that do not run

`src/claude_status.odin` (bars: `src/ui_claude.odin`).

- **Dots from the hooks.** OSC 7501 needs Claude Code 2.1.295 or later. Until a tab's process has
  reported it (`tab.prog`), its dot comes from the hooks' turn (`claude_status_dot`): working →
  working, waiting → waiting; a turn that ends (Stop or StopFailure, not `idle_prompt`) while the
  user looks elsewhere leaves the unseen dot and a bell entry (`claude_status_turn`), as OSC
  7501's done does; the next prompt clears it. The tooltip names "Claude Code hooks" as the
  source; the snapshot's `agent_status.source` is `none`.
- **Background work never changes the dot** (both paths, one rule): a turn that ends with a dev
  server still running is a finished turn: its question or error dot shows, the unseen dot and
  the bell entry come as for any end of turn. What runs is in the Background panel (§6b), the
  restart confirmation and a wait's result; as pi's blockers, which feed only pi's reload
  confirmation.
- **Hooks not running.** Every feed is a hook, so `disableAllHooks` (any settings file; also turns
  the status line off), a managed `allowManagedHooksOnly` (only managed and force-enabled plugins'
  hooks run: a `--plugin-dir` plugin's do not) or a plugin that fails to load leave the tab with no
  session id (a new one is not saved, no resume, no row), no comments, no held texts, empty
  panels. When a full tab has had no turn report in this run (SessionStart's hook always sends
  one, also when Deckhand refuses its session id; a restored tab's saved id does not count) 20 s
  (`CLAUDE_HOOKS_GRACE`) after its prompt came up (bracketed paste on, or OSC 7501 other than
  blocked), a bar over it names these causes, with **Show settings** (the Settings tab: the Claude
  Code groups) and **Dismiss** (for this run of the tab); a redraw is scheduled when it becomes
  due. A startup dialog (folder trust, login) may have bracketed paste on too, and hooks run only
  after it: Deckhand cannot tell the two apart from outside, so the bar waits the grace and also
  says to answer such a dialog first. The snapshot says `"hooks":"silent"`.
  `strictPluginOnlyCustomization` does not stop plugin hooks (settings-reference). A read-only
  tab is stopped instead (§1a).
- **Minimum version.** The version the tab started with (§4a, where `claude` links to; never
  run). Below `CLAUDE_MIN_VERSION` (2.1.295: OSC 7501 and `onFailure`), a bar says what is
  missing, with **Copy update command** (`claude update`; `brew upgrade --cask claude-code` for a
  Homebrew cask; `bun add -g …` and `pnpm add -g …` for bun and pnpm installs;
  `npm install -g @anthropic-ai/claude-code@latest` for npm) and **Dismiss** (for
  that version; saved in `<data>/claude-hints.json`, so it stays hidden after a relaunch). An unknown layout ("a new build", a mise shim) gets no hint; a nix or mise install shows its version and no command to copy: the bar says to update it with the package manager that installed it (nix, mise), as `claude update` cannot replace a managed install. The snapshot
  says `claude_version_old`. With hooks not running too, the hooks bar names the old version
  among the causes.
- **API-key, Bedrock, Vertex.** Nothing here depends on the account or provider: hooks and the
  version by stat work the same.

**Waiting until Claude is idle** (`claude_wait_idle`, `src/claude_wait.odin`; PROTOCOL.md): the
same signals (hooks idle, OSC 7501 not working or blocked), nothing held, nobody typing, for
300 ms; it ends with `tab_gone` when Claude exits or restarts in the tab, and with `dropped` when
the user drops the held text it names (`prompt_id`). While waits or held texts exist a timer
drives them, so they go on while frames are paused (window hidden, App Nap). Two known limits:

- **Another plugin's Stop hook can block the stop** (`decision: "block"`): Claude goes on working
  after our Stop hook already said idle. With OSC 7501 the tab still reads working and the wait
  goes on; a Claude Code that reports no OSC 7501 status looks idle, and the wait can end early.
- **An interrupt (Esc) runs no Stop hook**: the turn stays `working` until the next prompt, so a
  wait times out (and held texts wait) even though Claude is idle. The user's next message, or
  OSC 7501 idle plus a new turn, puts it right.

## 6. Comments

A session's pending comments go with the user's next message to whichever agent takes them
first: its pi (`pi.attach`) or a Claude tab of the session. For Claude, UserPromptSubmit calls
`claude.comments` (whole comments only, as many as fit in 9,500 characters; the rest stay for
the next message), prints them as `additionalContext` (the same note and fence as for pi; images
as file paths) and then calls `claude.attached`, which clears those comments (an edited one stays)
and tells pi's bridge `pi.attach_clear`. A hook that fails before `claude.attached` leaves them
pending: they go with the next message instead.

**Send now** on the comment strip goes to the session's active agent tab: the active tab when it
is a running Claude tab, else pi (with no Claude tab, or a dead one, it goes to pi). Into Claude, Send now types only a fixed line, "Here are my comments.", never comment
or page text (Claude Code may read `@path` in a message as a file to attach), and the
UserPromptSubmit hook adds the comments as that message's context, exactly as for a message the
user types (whole comments, crops as file paths; cleared by `claude.attached`, so once). The line
is pasted with bracketed paste and Enter under §5's rules, stricter than the held bar's Send now:
only when the turn is idle per the hooks **and** OSC 7501, the input takes bracketed paste and
**nothing is typed** (it never joins a half-typed prompt); otherwise the strip's Send now is
disabled and its tooltip (and the command's refusal) says why. If Claude's hooks do not run, the
comments stay pending for the next message. If the session's pi or another of its Claude tabs takes the comments
first (a message sent there in between), the fixed line reaches Claude with nothing attached.
Send now for one tab's comments only (the close prompt's **Send and close**) goes by pi's path:
Claude's hook takes all of the session's comments. In a Claude-only session (no pi) it goes to
the main Claude tab by the rules above, and so takes all of the session's comments with that
message; the tab closes at once and the comments stay pending until the hook takes them.

## 6a. Todos and subagents in the right column

While a Claude tab is the active tab, the right column shows **its** panels, in the same look as
pi's: **Subagents** (`● Explore` running, `✓ Explore` done, its description below) and **Todos**
(`Todos 1/3`, `✓` done, `▸` in progress with its active form, `○` pending). On pi's tab (or any
other) the column shows pi's panels as before; a Claude tab with nothing yet shows "Nothing
running · Todos and subagents from Claude".

- **Where they come from**: the plugin's async hooks (§2): TodoWrite's list (`claude.todos`, the
  main conversation's only), the Task tools one task at a time (`claude.task`: TaskCreated,
  TaskUpdate, TaskCompleted; Claude Code uses these or TodoWrite, depending on the model and
  `CLAUDE_CODE_ENABLE_TASKS`), and subagents (`claude.subagent`: the Agent tool's PreToolUse gives
  type and description, SubagentStart/SubagentStop the agent's id). Never a prompt, a transcript
  path or a subagent's result.
- **Untrusted, bounded**: §3's table. Deckhand builds the rows; the CLI also cuts what it sends
  (100 todos, 200 bytes each).
- **Out of order**: async hooks can arrive in any order. Each report carries `seq` (the hook's
  start, monotonic ns): an older list or task change never overwrites a newer one; a subagent's
  launch and start pair by type either way round; a stop before its start stays done.
- **Subagents at work**: Deckhand times each from its SubagentStart to its SubagentStop and shows
  its current tool (`claude.subagent tool`: PreToolUse inside it carries `agent_id`, hooks docs
  "common input fields") and, once done, how many tool calls it made: `● Explore · 1m 05s ·
  Grep`, `✓ Explore · 2m 03s · 14 tools` (times under a second are left out; redrawn once a
  second while one runs, `claude_panels_tick`, but not for one silent 2 h: a lost SubagentStop). A TodoWrite inside a subagent is its own list
  (`claude.todos` with `agent_id`), shown under it (`Todos 1/3`, its items while it runs). The
  Task tools are one shared list (the main Todos panel). A report for a subagent Deckhand does
  not know yet (async order, an in-process teammate) is dropped.
- **Lifetime**: finished subagents go at the user's next message; everything goes with a new
  process (Restart, restore), a new conversation (`/clear`, a resume or fork; a compaction keeps
  them) and the tab's exit. Not saved.

## 6b. Background work

Claude Code's Stop and SubagentStop hooks carry `background_tasks` (id, type such as `shell`,
`subagent`, `monitor`, `workflow`; status, description, command for shells) and `session_crons`
(CronCreate, ScheduleWakeup, `/loop`: schedule, recurring, prompt), "so hooks can distinguish
'session is done' from 'session is paused waiting for background work'" (hooks docs, "Stop
input"; SubagentStop's are the parent session's). The plugin sends them as `claude.background
snapshot` before the turn's idle, and a background Bash's launch at once (`bash-bg`: PostToolUse,
`tool_response.backgroundTaskId`). Deckhand:

- shows them in a **Background** panel (between Subagents and Todos): `● shell · Start the dev
  server`, `✓ …` once a newer snapshot no longer lists it (until the user's next message),
  `⏲ */5 * * * * · repeats` with its prompt, "As of Claude's last turn" and "Deckhand can't stop
  these: ask Claude". A subagent's task is left to the Subagents panel. A task that ends between
  turns shows running until Claude's next Stop.
- **counts** only what a snapshot reports running (statuses `running`, `pending`, `in_progress`,
  `queued`, `starting`; any other is over) and one-shot wakeups; recurring crons never. A launch
  alone is shown but never counted, and a Stop that comes without a snapshot (an older Claude
  Code, which sends `backgroundTaskId` but no `background_tasks`; or a lost one) ends the
  launches still unconfirmed. A snapshot's task pairs with a launch by id, or for a shell by one
  id being the other's prefix or suffix (the two ids are documented separately). At most 16 kept;
  a running one is never pushed out (past 16 they are counted, "+N more running").
- **blocks nothing** (as pi's blockers, which feed only pi's reload confirmation): no dot change
  (§5a), and `claude_wait_idle` ends at the idle turn with `data.background: [{kind, label}]` and
  `data.background_count`. The restart confirmation names them (`claude_restart_changed`).
- **cannot stop them**: there is no documented way to stop one of Claude's tasks from outside
  (only Claude's own tools, or ending the process). Display only.
- text: Claude's, untrusted: one line, cleaned, bounded (§3). Names that leave the panel (a wait's
  result, the confirmation: both are broadcast and logged) are the description or `<kind>
  #<id>`, never the command. The panel (and the snapshot's panel rows) shows a shell's command
  only when it has no description, with secret-looking parts masked (`claude_mask_secrets`:
  `NAME=…` when the name says TOKEN, KEY, SECRET, PASSWORD, PASSWD or AUTH; the value after
  `--token`, `--password`, `--api-key`; an `Authorization:` header's value). A heuristic, as pi's
  shell panel shows its commands. The command log has ids and counts only.
- An older Claude Code sends no arrays: nothing is shown or counted, as before.

## 7. Tests

- Unit: `src/claude_test.odin` (flags and ids, who may send what, new tab, history and resume,
  held prompts, comments once, save and restore), `src/claude_extras_test.odin` (the dead tab's
  bar and Restart, 127, flags only for the user, the hung-process wait, the row and the bell;
  todos, tasks and subagents panels, bounds, order, scope; Send now into Claude and its refusals),
  `src/claude_sessions_test.odin` (Claude-only sessions, rows, pin/hide/filters/attention, resume
  from a row, restore and migration, a dead one, not installed), `src/claude_review_test.odin`
  (ids a Claude tab may not claim, a dead session resumed in place, agents and restored tabs,
  the history checked on load), `src/claude_chats_test.odin` (Claude in chats; the read-only
  profile: argv, refused flags, kept by restore, restart and an agent's resume, act verbs refused,
  never without the guard, the guard's command line failing closed, the ack, the read-only ids),
  `src/claude_rows_test.odin` (§4b: transcript path checks, model, row info, Reveal and Copy path,
  dots, title push, exit bell, Send and close, review, notes env, `--claude`),
  `src/claude_feeds_test.odin` (§5a, §6a, §6b: dots from the hooks, background work as busy, the
  Background panel, the restart confirmation, the hooks and version bars, subagents' tool, time
  and todos),
  `src/reload_test.odin` `claude_*` (live vs restart files, what is watched, the bar's Restart
  and queue, version drift with fake installs never run, a save), `src/settings_files_test.odin`
  `settings_files_claude_*` (the groups, credential and state files never listed or opened),
  `src/dead_tab_test.odin` `claude_restart_with_model`, `src/folders_test.odin`
  `folders_detect_claude_md`, `src/socket_test.odin`
  `socket_claude_token_scope` (the process check, scope, revocation),
  `tools/deckhand-cli/cli_test.odin` (the CLI's parsing, output, fencing, shots and hooks; the
  read-only guard and `tests/readonly-vectors.json`, the cases shared with pi-kit's guardrails:
  `node tests/scripts/readonly-vectors-pikit.mjs <pi-kit>/extensions/guardrails/core.ts
  tests/readonly-vectors.json` checks them against pi-kit's regexes).
- Scene: `tests/scripts/claude-runtime.sh` (the Claude bar and Restart, the update bar, the
  Settings groups, Restart with model…; fake `~/.claude` and fake install, never run).
- Scene: `tests/scripts/claude.sh` with the fake claude (new tab, hooks, CLI against a browser and
  an app tab, held prompts, comments and Send now, todos and subagents, resume from its row into
  a Claude-only session, the dead tab's Restart after exit 3 and 127, restore after a relaunch);
  `tests/scripts/claude-sessions.sh` (New session's picker → Claude Code, rows, rename, pin, filters, restore; and
  a run with no Claude Code anywhere); `tests/scripts/claude-readonly.sh` (a read-only Claude
  chat: the profile in argv, the guard's denials as Claude Code gets them, restored read-only
  with the setting off); `tests/scripts/claude-feeds.sh` (§5a, §6b: the version bar, the waiting
  dot from hooks, the Background panel and a wait that names it, a subagent at work, a tab whose
  hooks never run). Scenes put a stand-in `claude` in the fake HOME's
  `~/.local/bin` (`tests/scripts/claude-stub.sh`) so "installed" does not depend on the machine;
  it is never run.
- Never a real `claude` in tests, and never the user's `~/.claude`: the test binary drops an
  inherited `CLAUDE_CONFIG_DIR` before any test (a Claude Code session sets one), and the scene
  scripts unset it.

## 8. Not yet

- Secret redaction of tool output for Claude (pi-kit's guardrails redact; a sync PostToolUse
  `updatedToolOutput` hook could): not built.
- The process check on Linux (`SO_PEERCRED` and `/proc`) and Windows.
