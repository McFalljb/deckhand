# Deckhand plugin for Claude Code

Makes Claude Code feel native in Deckhand's **Claude tabs**, without an MCP server (no tool
definitions in Claude's context):

- **`deckhand` command** (`bin/deckhand`, on the Bash tool's `PATH` while the plugin is enabled;
  `pi-desk` (`bin/pi-desk`) is a kept alias from Deckhand's old name): `show` (show the user a file
  in a tab next to the Claude tab: Markdown rendered, other text in the editor), your session's
  browser tabs (tabs, open, read, screenshot, wait, click, type, press, scroll, select, hover,
  upload, console, network, comments) and app tabs (list-declared, open, restart, close, call,
  screenshot, input, events). It runs the CLI inside the Deckhand app that started the tab (`$PI_DESK_CLI`), so the
  plugin and the app always match. One JSON object per call; page and app content only inside a
  fenced `content` string, as untrusted data.
- **Skill** (`skills/deckhand`): a short stub, so only its name and description sit in context; it
  tells Claude to run `deckhand --skill`, which prints the manual for the running Deckhand.
  Its `allowed-tools` approves the `deckhand` verbs while the skill is in use, **except `app open`,
  `app restart` and `app close`**: those go through Claude Code's own permission mode (it asks in
  its default mode), because Deckhand itself asks nothing before running a declared app
  ([docs/ENGINE-BRIDGE.md](../../docs/ENGINE-BRIDGE.md), apps.json's trust model). `tools/pi-desk-cli/cli_test.odin`
  (`skill_leaves_app_open_to_claude`) checks the list.
- **Hooks** (`hooks/hooks.json`): SessionStart tells Deckhand the Claude session id (so the tab can
  be resumed and restored), UserPromptSubmit / Stop / Notification tell it when a turn starts,
  ends or waits for the user (Deckhand types into the tab only when Claude is idle and nothing is
  typed), and UserPromptSubmit hands Claude the user's pending comments with the message.
- **Read-only chats** are not this folder's: for a chat while Deckhand's **Chats: read-only** is
  on, Deckhand adds plan mode, deny rules and its own PreToolUse guard (`pi-desk-cli hook
  readonly`, by absolute path, failing closed) with `--settings` ([docs/CLAUDE.md](../../docs/CLAUDE.md) §1a).

All rules (own session only, no JavaScript, refused password/card/one-time-code fields, the
user's Allow for uploads and downloads, Take over, Stop) are enforced by Deckhand, not here. See
[docs/GUIDE.md](../../docs/GUIDE.md) ("Claude tabs") and [docs/PROTOCOL.md](../../docs/PROTOCOL.md).

## How it is loaded

Deckhand ships this folder inside `Deckhand.app` and starts every Claude tab as
`claude --plugin-dir <app>/Contents/Resources/claude-code` (plus `--resume <id>` to resume):
the plugin is loaded for that session only, and nothing is installed into your Claude Code
configuration. Outside a Deckhand Claude tab the command says so and the hooks do nothing.

## Installing it yourself (optional, not needed for Deckhand)

The folder is also a one-plugin marketplace (`.claude-plugin/marketplace.json`). To install it
by hand, in Claude Code:

```
/plugin marketplace add /path/to/deckhand/integrations/claude-code
/plugin install deckhand@deckhand
```

It is not published anywhere. Installed this way it still only works inside Deckhand's Claude
tabs, which set `PI_DESK_SOCKET`, `PI_DESK_CLAUDE_TOKEN` and `PI_DESK_CLI` (the `PI_DESK_*` names
are kept from Deckhand's old name, pi-desk).
