# Deckhand's pi integration

What makes pi feel native in Deckhand's **pi tabs** and lets **Atlas** drive Deckhand. Deckhand
ships this folder inside `Deckhand.app` (`Contents/Resources/pi`) and starts every pi tab with
one `-e <folder>/extensions/<name>` per extension in `extensions.json` (the required ones, and
optional ones the user turned on, in that order). `-e` loads them for that run only: nothing is
written to `~/.pi`, and pi outside Deckhand runs exactly as before. It needs pi 1.4.0 or newer
([docs/HARNESSES.md](../../docs/HARNESSES.md), the design).

| Extension | What it does | Active when |
|---|---|---|
| `bridge` | The tab's connection to Deckhand ([docs/PROTOCOL.md](../../docs/PROTOCOL.md) §4): `pi.session`, `pi.status`, `pi.prompt`, `pi.wait_idle`, `pi.reload` (`/deckhand-reload`), comments (`pi.attach`, the `input` hook), panels (`panel.set`), and other extensions' commands over its connection | `DECKHAND_SOCKET` + `DECKHAND_TOKEN`, interactive TUI |
| `desk` | Atlas's tools: `desk_state`, `desk_run`, `desk_prompt`, `desk_wait`, `desk_watch`, `desk_events`, `app_call`, `app_screenshot`, `app_input`, `app_events` | also `DECKHAND_CONTROL_TOKEN` (Home only) |
| `browser` | `browser_*` (read and act), `desk_show` (show the user a file in a tab next to the pi tab: Markdown rendered, others in the editor) and a pi tab's `app_*` tools, for its own session's tabs | `DECKHAND_SOCKET` + `DECKHAND_TOKEN`, TUI |
| `panels` | The Todos (rpiv-todo), Subagents (pi-subagents) and Shells (`kit:shell:rows`) panels | `DECKHAND_SOCKET` + `DECKHAND_TOKEN`, TUI |
| `guardrails` | Optional, on by default. pi-kit's guardrails: the user's ask/block rules on shell commands (pi-kit's config files), read-only with `PI_KIT_READONLY=1`, secrets redacted from tool output, `/guardrails` | always; steps back for another guardrails (below) |
| `shell` | Optional, on by default. pi-kit's shell: `bash_bg`, `monitor`, `wake_later`, `shell_stop`, `shell_list`, `/shells`; rows on `kit:shell:rows` (the Shells panel, the bridge's blockers) | not in read-only sessions |
| `notes` | Optional, off by default. pi-kit's notes reminder: past `PI_KIT_NOTES_REMIND_PERCENT` (75) of the context, one note to update the session note (in `PI_KIT_NOTES_DIR` when set) | not in pi-subagents children |

Optional ones are the user's Settings toggles (Settings tab, "pi extensions"; `extensions.json`
`default` until chosen) and apply at a tab's next start. `skills/deckhand-desk` is Atlas's desk
skill, passed with `--skill` to Atlas only. It has its own name because pi lists `--skill` paths
last and keeps the first skill of a name, so it cannot share pi-kit's `desk`.

Shared code is in `lib/`. It came from pi-kit (`extensions/desk-bridge`, `desk`, `desk-browser`,
`sidebar/rows.ts`, `guardrails/core.ts` → `guardrails.ts`, `shell/lines.ts` → `shell.ts`) and
keeps pi-kit's extension API usage. The differences:

- **Namespace.** `DECKHAND_*` variables (`DECKHAND_SOCKET`, `DECKHAND_TOKEN`,
  `DECKHAND_CONTROL_TOKEN`, `DECKHAND_SHOTS_DIR`), tokens kept under `Symbol.for("deckhand.*")`,
  internal events `deckhand:*` and the reload command `/deckhand-reload`. Deckhand no longer sets
  `PI_DESK_SOCKET`/`PI_DESK_TOKEN`/`PI_DESK_CONTROL_TOKEN` in pi tabs, so an installed pi-kit's
  desk extensions stay inert next to this copy.
- **Panels.** pi-kit's contract is kept: producers emit `kit:desk:panels`, the bridge emits
  `kit:desk:mode`, so pi-kit's sidebar keeps handing its panels over. Loaded first (`-e`), the
  bridge says the mode again once every `session_start` has run (`resources_discover`) and on
  `kit:desk:mode?`, for a producer that listens only once its own `session_start` ran. The bridge merges panels from
  several producers by name.
- **Stepping back** (`lib/claims.ts`): at session start `panels` emits `deckhand:capabilities?`;
  an extension that answers `deckhand:capabilities` `{capability: "panels:todos" |
  "panels:subagents" | "panels:shells", owner, version}` (then or later) takes that panel over (ours is cleared
  first: one empty copy), as does any other producer that publishes it with rows on
  `kit:desk:panels`.
- **Tool names.** pi refuses to start (exit 1) when two extensions register one tool or flag name
  while loading, so none of these does: tools are registered at `session_start`, which pi never
  checks, and at run time the first extension in load order (`-e`: ours) has the name. `desk` and
  `browser` keep theirs that way; `shell` registers only when no tool already loaded has one of its
  names (`lib/claims.ts` `loadedTools`), and `/shells` and `/guardrails` only when no copy of the
  command is loaded (pi would rename both `name:1`, `name:2`).
- **Hooks** (the optional ones): `guardrails` steps back on a `guardrails` claim or when pi-kit's
  `/guardrails` is registered (its entry file, by `sourceInfo.path`), and blocks a write or edit
  that would put this session's `[REDACTED]` marker into a file; `notes` drops its reminder when pi-kit's
  (`pi-kit-notes`) is on the branch since it became due, or on a `notes` claim; `shell` steps back
  whole next to pi-kit's shell (or any extension with one of its tool names): it registers and
  publishes nothing and says so in the tab, and the Shells panel shows the other's `kit:shell:rows`.
  Standing, it draws under its own keys (`deckhand-shell`) and tags its rows, so another producer's
  empty `kit:shell:rows` never clears the Shells panel or the blockers.
- **Environment.** Every extension takes the `DECKHAND_*` variables out of `process.env` when it
  loads and keeps them in memory (`lib/protocol.ts` `adoptEnv`), so the children pi spawns after
  that (its bash tool, `!` commands, the rest) inherit none of them; a reload or session switch
  finds them in memory. Children pi spawned before the integration loaded (its own package
  installs at startup) may still have inherited them.
  Deckhand sets them only for a pi that loads this integration.

Read-only chats run pi with `--tools read,grep,find,ls,desk_show --exclude-tools mcp__* --no-mcp`,
which keeps every tool here but `desk_show` (display only) away from the model. Read-only jobs get
the same without `desk_show`. The bridge needs no tools: its status, waits and comments are hooks.
With `PI_KIT_READONLY=1`, `browser` also leaves out `app_open`, `app_restart` and `app_close` (it
keeps `desk_show`), `shell` registers nothing, and `guardrails` (when on) blocks edits, writes and
mutating bash.

## Tests

`node --test test/unit.test.ts test/deckhand.test.ts test/kit.test.ts test/optional.test.ts test/conflicts.test.ts test/mode.test.ts`
(Node 22.18 or newer strips the types; no `node_modules`, no pi). `./build.sh test` runs them.
They never start pi. `kit.test.ts` is pi-kit's tests of the guardrails and shell code;
`conflicts.test.ts` loads the extensions into a model of pi's own name rules (`test/pi-rules.ts`,
from pi's source: a tool or flag name registered by two extensions while loading stops pi).
`mode.test.ts` loads the bridge and a stand-in sidebar into that model against a fake Deckhand on a
unix socket (`kit:desk:mode` reaches a sidebar that gets ready late, by the time every `session_start` has run).
`PI_KIT_DIR=<a pi-kit checkout>` adds the overlap tests (`optional.test.ts`, `conflicts.test.ts`, `mode.test.ts`),
which load pi-kit's own extensions next to ours.
