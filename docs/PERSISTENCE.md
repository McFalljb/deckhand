# Workspace persistence

What Deckhand saves so the next start restores the workspace: projects, open sessions, tabs,
layout, focus and settings. The core owns all of it: in its own process
(`deckhand-core-serve`) by default, else inside the window's
([How Deckhand runs](GUIDE.md#how-deckhand-runs)). Code: `src/core/persist.odin`; tests:
`src/persist_test.odin`, `tests/scripts/restore.sh`.

## Identities

Runtime ids (`project_id`, open session `id`, `tab_id`) are only stable within one run and are not
saved; a restore creates new ones. Saved data uses identities that outlive a run:

| Thing | Saved identity |
|---|---|
| project | `cwd` (absolute path) |
| session | pi's session id (UUID) + `cwd` + `session_dir` (`""` = pi's default store) |
| tab | position in its session + kind (+ kind-specific fields) |

Not the session file path: it encodes cwd and timestamps, and a session may live in its own
`--session-dir` (Home does).
Deckhand picks the UUID for new chats (`pi --session-id <uuid>`). On restore the session file is
looked up by UUID (in `session_dir`, else the project's folder in pi's store) and pi resumes it with
`pi --session <file>` in `cwd` (plus `--session-dir` when set). A session whose file or cwd is gone
is restored marked `missing` ("gone"): never started, never recreated empty.

## File

`<data dir>/workspace.json`. The data dir is `~/Library/Application Support/Deckhand` (Linux:
`$XDG_DATA_HOME/deckhand`, default `~/.local/share/deckhand`). Until the rename's data dir move,
an install that started as pi-desk keeps using `…/pi-desk`; `DECKHAND_DATA_DIR` overrides both
(`data_dir` in `src/core/platform.odin`). The file is mode `0600`, written whole and atomically
(temp file in the same dir, fsync, rename) one second after the first change to saved data (pi
status, panel, focus and tab-exit updates do not count), only when the content changed, and once
more when the core exits (a Quit, Stop All, SIGTERM at logout or a handover, the idle exit).
Test mode saves and restores only with an explicit `DECKHAND_DATA_DIR`.

```json
{"v":1,
"projects":[{"cwd":"/Users/me/w/app","name":"App"},{"cwd":"/Users/me/w/new"}],"selected_project":"/Users/me/w/app",
"open_sessions":[{"pi_session_id":"7df238b2-fd48-4586-9110-35ea73669d4d","cwd":"/Users/me/w/app","session_dir":"","project":"/Users/me/w/app","tabs":[{"kind":"pi"},{"kind":"shell","title":"shell 1","cwd":"/Users/me/w/app/src"}],"active_tab":1}],"current_session":0,
"home":{"pi_session_id":"0c41e9a2-5d0e-4b8e-9b7a-2f1c3d4e5f60"},
"layout":{"left_width":300,"right_width":320,"left_open":true,"right_open":true,"panels":[],"collapsed":["shells"],"left_tab":"files"},
"files":{"expanded":[{"root":"/Users/me/w/app","dirs":["src","src/ui"]}]},
"sidebar":{"pinned_projects":["/Users/me/w/app"],"pinned_sessions":["7df238b2-…"],"hidden_projects":["/Users/me/w/old"],"sort":{"projects":"name"},"folded":{"chats":true},"show_hidden":true},
"settings":{"confirm":{"control":{"tab_close":"trusted"}},"confirm_close":{"shell":"always"},"theme":"ghostty","reduce_motion":true,"appearance":"light","text_size":"large"}}
```

- `projects`: projects added by hand, renamed, selected, or holding a saved session. Projects
  derived from pi's store are found again by scanning; saved entries add names and bring back
  hand-added projects (on top, in saved order). A project whose folder is gone shows as missing.
- `open_sessions`: sessions restored from the file are always kept, even while gone (a volume may
  come back); sessions opened this run are saved once their session file exists (a new chat pi has
  not written yet is left out). File lookups are cached: a found file costs a stat, a missing one a
  stat of its dir until that dir changes. `tabs[0]` is the pi tab (a Claude-only session's: its Claude tab, below); shell tabs save
  their title and the live shell's cwd (read from the process; the start dir if unknown).
  Editor tabs save their file's `path` (diff views are not saved; unsaved edits are not kept:
  the tab reopens the file as it is on disk). Browser tabs save `url` and `title`
  (`{"kind":"browser","url":…,"title":…}`; not the back/forward list): they come back in their
  own session and load once shown (docs/BROWSER.md §2.4). A user name and password in the
  URL (`user:pw@`) are never saved (nor shown in State); the query string and fragment are kept as
  they are, and may hold sign-in tokens (an OAuth `code` or `access_token`). Unknown tab kinds are skipped on restore.
  Claude tabs save `{"kind":"claude","claude_session_id"?,"cwd","args"?,"readonly"?,"account"?}` (docs/CLAUDE.md): Claude
  Code's session id once its SessionStart hook reported it, where it ran, the user's extra
  flags, and `readonly: true` when it started with Deckhand's read-only profile (§1a: it starts
  read-only again, whatever the setting; `claude_sessions` entries carry the same field), and
  `account`: its account's config folder (§1b; it starts there again; absent: the default). A saved id that is not a session id, or flags Deckhand sets itself, drop the tab.
- **Panes** (docs/GUIDE.md, split panes): a session split into panes also saves `panes`; a
  session with one pane has no `panes` key:

  ```json
  {"pi_session_id":"…","tabs":[{"kind":"pi"},{"kind":"shell",…},{"kind":"shell",…},{"kind":"shell",…}],"active_tab":1,
   "panes":{"tree":{"split":"right","ratio":0.347,"a":{"pane":0},
                    "b":{"split":"down","ratio":0.500,"a":{"pane":1},"b":{"pane":2}}},
            "tab_pane":[1,0,1,2],"active":[1,0,3],"focused":0}}
  ```

  `tree` is the layout: a pane `{"pane":N}` or a split `{"split":"right"|"down","ratio","a","b"}`
  (`right`: `a` left of `b`; `down`: `a` above `b`; `ratio`: `a`'s share, 3 decimals). Panes are
  numbered in the tree's order (left to right, top to bottom). `tab_pane[j]` is the pane of the
  saved tab `j` (the pi tab, `tabs[0]`, may be in any pane), `active[N]` the saved tab pane `N`
  shows, `focused` the pane with the keyboard; `active_tab` stays the focused pane's shown tab.
  Pane ids, sizes, the focus history and drags are not saved.
  Restored with `restore_session` (`persist.odin` `panes_parse`, `panes_restore.odin`). The tabs
  always come back from `tabs`; `panes` only places them, and a layout that does not fit never
  fails the restore. A malformed tree, a single pane or more than 8 panes give one pane. A
  `ratio` is clamped into 0.05–0.95. A tab with no valid `tab_pane` goes to the focused pane (a
  bad `focused`: the first pane). A pane shows its `active` tab, else the saved `active_tab` if it
  is there, else its first tab. A pane none of whose tabs came back (app tabs, diff views and the
  other tabs every restore drops) is removed and the split around it closes.
- A Claude-only session (docs/CLAUDE.md §1) is saved in `open_sessions` as
  `{"agent":"claude","claude_session_id","pi_session_id":"","cwd","project","tabs":[{"kind":"claude",…},…],"active_tab"}`:
  `tabs[0]` is its main Claude tab (same id), never a pi tab; saved once Claude reported its
  session id; `pi_session_id` is `""`. Restored with `restore_session` and `agent: claude`; a
  saved id that is not a session id, or a first tab that is not that Claude tab, drops the
  session. No `agent`: a pi session.
- `claude_sessions`: `[{id, cwd, project, title?, used, args?, named?, transcript?, model?, account}]`, most recent first, at most 100:
  the Claude sessions Deckhand ran, the Claude rows of each project's session list. `title` is the
  first prompt's first line or the user's rename (≤ 80 characters); `used` the last prompt (or
  close). `named: true` when `title` is the user's rename (pushed to Claude
  Code as its session title, docs/CLAUDE.md §4b). `transcript`: Claude Code's transcript file as
  SessionStart reported it, kept only under Claude's config dir's `projects/` (checked again on
  load: one that is not is dropped); never read. `model`: the last model reported (SessionStart,
  PostModelSwitch). `account`: the config folder it ran under (written at each start; left out
  for an older entry, which means the default account as resolved when it is used, never stamped
  at load). `transcript` may be under any account's `projects/`. Restored with
  `claude_restore_history` (internal).
- `current_session` and `active_tab` are positions in the saved lists (left out if none).
- `home`: `{"pi_session_id", "model_applied"?}` of the Home session, once it was opened. Its
  session dir (`<data dir>/home`) and cwd (the main folder when set and reachable, else
  `<data dir>/home`; never `~`, for macOS privacy prompts; looked up at each start) are
  Deckhand's own and not saved. `fork_from`: Atlas's old session file while a fork into the
  main folder is pending. When the old session's header records another cwd, Atlas starts with
  `pi --fork <old file> --session-id <id>` (`home_fork_id`: the same id for every attempt at the
  same move); once that file exists `fork_from` goes, and if pi exits without writing it the old
  session is resumed instead. The old file is never touched (`home_session_start`,
  `home_fork_exited` in `src/core/home.odin`). Restored not started; the first open of the
  agent's drawer resumes it (`pi --session-dir <data dir>/home --session <file>`, or
  `--session-id <id>` if pi never wrote
  it). `model_applied` is the `agent_model` it last ran with (recorded at pi's first status): `--model` is passed again only
  when the setting differs (docs/PROTOCOL.md §8). Home is not in `open_sessions`. Its prompt
  file `<data dir>/atlas/ATLAS.md` is the user's and never rewritten.
- `layout.drawer_width`, `layout.drawer_pinned`, `layout.drawer_open`: the agent's drawer. Open
  when saved = it opens (and the agent starts) at the next start.
- `layout.left_tab`: `"files"` while the left column shows the Files tab (left out for Sessions).
- `files.expanded`: the Files tab's open folders per tree root (a project or session folder, real
  path), most recently used first, relative to the root; at most 32 roots and 256 folders each.
  Restored with `files_expand` (folders that are gone are dropped). The filter is not saved.
- `files.checkouts`: `[{"base", "path"}]`, the checkout (a git worktree or the main checkout) a
  project's or session's Files tree shows instead of its own folder; restored first with
  `files_set_root` (dropped when the folder is gone or not a checkout of the same repository).
- An open session running in a worktree of its project (`worktree_session`) saves its `cwd`;
  `restore_session` starts it there again while that folder is still a checkout of the project's
  repository (else in the project's folder).
- `settings.agent_name`, `settings.agent_model` (when set), `settings.notify: false` and
  `settings.tidy_projects: false` (when off), `settings.keep_sessions` (only once you changed it;
  absent: the default, on; the session holder's `tokens.json` is its own file, above),
  `settings.separate_core` (only when it differs from the default, on: read by the window at
  launch, to run the core in its own process or not). The tidy list's state (temp, missing, nesting) is
  derived at each scan and not saved. A project added by hand is saved in `projects` with
  `"added": true`, so a subfolder you added stays a top-level row across restarts (as pinned
  ones do); restored as saved (`added` absent: a found row that nests), never selected one by
  one. A folder only Claude Code ran in (docs/CLAUDE.md §4c) is saved with `"claude": true`: the
  Rescan after launch keeps it while an account still has its transcripts, else drops it
  (unless added, named or open). `sidebar.expanded`: the Projects tree's parent and group rows you opened, by folder
  path (collapsed by default; restored with `set_row_expanded`).
- `close_session` removes a session from the open sessions, so the next save drops it.
- Chats: the Chats entry is not in `projects` (it is always there when Deckhand has a data dir).
  An open chat is saved like any session plus `"chat": true` (`cwd` = the Chats folder, pi's
  normal store) and goes back into Chats while chats still run in that folder; a chat from an
  earlier Chats folder (the chats folder changed) goes back into that folder's project.
  `settings.chats_readonly` is saved when set.
- Claude Code accounts (`src/core/claude_accounts.odin`, docs/CLAUDE.md §1b): `settings.claude_accounts`
  (`[{dir, label?, added?, removed?}]`: only what the user changed: a name of their own, a folder
  they added, one they removed; absolute folders, at most 64), `settings.claude_account_default`
  (the chosen default's folder; left out: the environment's) and `settings.claude_account_last`
  (the account a Claude session last started with). Folders and names only, never a secret or a
  file's content. Restored in place (no command); found folders are looked for again at start.
- Folders (`src/core/folders.odin`): `settings.home_dir` (the main folder), `settings.folders`
  (`{"chats": "/abs", …}`: only overridden subfolders) and `settings.setup_seen: true` (the
  first-run sheet was done or skipped), each when set. Restored with `set_folder` (overrides
  first), then `set_home_dir` as the internal caller: nothing is made at restore, and a main
  folder that is not there (an unplugged drive) stays set. Old keys are read once: `notes_dir`
  becomes `home_dir`; `chats_dir` becomes the chats override unless it is `<home_dir>/chats`
  (with a `notes_dir` but no `chats_dir`, `~/Chats` becomes the override). Nothing is ever moved
  between folders.
- `sidebar`: only what differs from the defaults. Pins (in pinned order) and hidden items by
  identity (project cwd with symlinks resolved, pi session id or a Claude row's Claude session id), so they survive rescans; project
  entries whose folder no longer exists are dropped at save;
  the sort per section (`projects`, `sessions`, `chats`; default `recent`), folded sections,
  `view` (`attention`: the Sessions column's Attention view; default `projects`, not written) and
  `show_hidden`. The filter text and quick filters are not saved. Restored with the internal
  `restore_sidebar`, then `set_sort`, `set_sidebar_folded`, `set_sidebar_view`, `set_filter`.
- `settings`: only non-default values. `confirm`/`confirm_close` are user-only settings; reading
  them back from the user's own file is the user setting them.
- Focus always comes back to the terminal (a text field's content is not saved).
- Not saved: runtime ids, `version`, the session list (rescanned), pending confirmations and their
  tokens, socket tokens, pi status and blockers, panel contents, the command log, text-field
  contents, terminal scrollback.

## Kept sessions

With `keep_sessions` on (the default), the session holder keeps the tabs' processes running
across core restarts and updates (on Linux too, where the holder runs in a systemd scope of its
own; an orphan an upgrade's keeper adopts ends with an unknown exit code there). These let the next core take them back:

- **`<data dir>/tokens.json`**: the socket tokens of the tabs whose process runs in the holder, so
  those processes can reconnect to the next core (PROTOCOL.md §2). Keyed by holder terminal,
  sha256 hashes only, never a token. Per terminal it also says what was started there (`kind`:
  shell, pi or claude; for pi `pi_ro` and its optional extensions `extras`): a restored tab of
  another kind never adopts that terminal, and an adopted pi tab is never less read-only than it
  started. A challenge-only reconnect token says `"hello":"challenge"`; its hash is the challenge
  hello's key (PROTOCOL.md §2). Written whenever a holder is attached, rewritten atomically on
  every mint and revoke, MAC'd with the holder's in-memory key (`src/core/macfile.odin`: a
  `deckhand-mac 1 tokens <hmac>` line, then the JSON). A file that does not verify is ignored
  whole. A new holder (no terminals) removes the old file; entries for terminals the holder no
  longer lists are dropped at start.
- **`workspace.json`'s `held` ids.** A terminal tab (pi, shell, Claude, Home's pi) whose process
  runs in the holder saves `"held": <terminal id>` (a pi tab started read-only also
  `"readonly": true`), and the file has a top-level `"holder": <its instance id>`: held ids are
  adopted only from that same holder.
- **`<data dir>/handover.json` and `<data dir>/handover/<id>.snap`**, written when the core stops
  and hands its sessions to the holder or to a new core (`src/core/holder_adopt.odin`,
  `src/core/core_handover.odin`). Each snapshot (`0600`) is a terminal's screen at the offset the
  holder acked (`src/core/snapshot.odin`). `handover.json` is MAC'd as `handover`:
  `{"v":1,"min_reader":1,"holder":<WELCOME instance>,"written":<unix>,
  "terminals":[{"term","offset","sha256","format","inexact"}]}`. Both are read once by the next
  core and removed. They are used only when the MAC verifies, `min_reader` ≤ 1, `holder` is the
  attached holder's instance (random per holder run, so also this boot) and the holder says the
  last core said goodbye (`trust.handover_fresh`); each snapshot only when its sha256 matches.
  Otherwise the terminals are rebuilt from the holder's tails (`inexact`). If the handover can't
  be written (disk full, an unwritable data dir), nothing is sent to the holder: the sessions run
  on and the next core rebuilds them from the tails.

Other files of the core and the window:

- `<data dir>/window-floor`: one `X.Y.Z` line, the newest window version that attached, so a core
  that starts again still refuses an older window (PROTOCOL.md §5a).
- `<data dir>/background-core-noticed`: an empty marker, written by the window once the first
  ⌘Q's notice (the sessions run on) was shown.
- `<data dir>/core/`: the installed copies of Deckhand Core.app, `current` and `previous`, and
  `use-previous` while the user chose **Use previous core**
  ([background-core.md](plans/background-core.md) §7.1).

## Restore

When the core starts, after the store scan and before `deckhand DIR`, the file is replayed as
ordinary commands with caller `internal` (so they appear in the command log): `set_theme`,
`set_reduce_motion`, `set_dim_panes`, `set_appearance`, `set_text_size`, `set_terminal_text_size`,
`set_confirm_policy`, `set_close_confirm`, `add_project` (projects the scan did not find),
`rename_project`, `restore_session` (internal only: an open session with its tabs `not_started`;
with `"home": true` the Home session), `set_panel`, `set_panel_collapsed`, `set_left_tab`,
`set_layout`, `files_expand`, `restore_sidebar` (internal only), `set_sort`,
`set_sidebar_folded`, `set_sidebar_view`, `set_filter` (`show_hidden`), `select_project`.

- **Held tabs first.** Tabs with a `held` id the session holder still lists are adopted at once
  (not lazily): the terminal comes back from the handover snapshot plus the holder's tail
  (exact), or from the tail alone (`inexact` in State), and the tab is `running`. Replies to
  queries in the replayed bytes are dropped. A held terminal no tab claims is hung up only when
  nothing can be lost: it already ended, or the file restored cleanly, was saved with this holder
  and listed it. Otherwise (`--fresh`, a file moved aside, a crash before the first save, another
  holder's ids) it keeps running unseen, and a toast says how many ("N kept sessions weren't
  restored"); **Quit Deckhand and Stop All Sessions…** ends them. A `held` id the holder no longer
  lists restores as below.
- **Then the current session.** The core focuses the saved current tab (`persist_after_layout`),
  which starts that session; every other session starts when it is focused (lazy restore).
  `deckhand DIR` opening a new chat skips this.
- Shell tabs restart as a new login shell in their saved cwd (the session's if that is gone) and
  print a dim note that the old history is not kept. Claude tabs start `claude --plugin-dir …
  --resume <id> <flags>` in their saved cwd (no `--resume` when no id was reported), with a new
  token; with Claude Code not installed they say why and show as exited (docs/CLAUDE.md §1).
- Corrupt file, unknown `v`, not a regular file, or over 4 MB (checked before reading) → moved
  aside to `workspace.json.bad-<unix time>`, start empty. Nothing is changed before the file is
  validated.
- `deckhand --fresh` → no restore; an existing file is moved aside to
  `workspace.json.bak-<unix time>` and the new run saves normally.
- Restore time is logged to stderr (`workspace restored … in N ms`, `restored session started N ms
  after launch`).
