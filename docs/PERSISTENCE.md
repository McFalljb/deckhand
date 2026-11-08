# Workspace persistence

What Deckhand saves so the next start restores the workspace: projects, open sessions, tabs,
layout, focus and settings. Code: `src/persist.odin`; tests: `src/persist_test.odin`,
`tests/scripts/restore.sh`.

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

`<data dir>/workspace.json` (macOS: `~/Library/Application Support/pi-desk/workspace.json`; Linux:
`$XDG_DATA_HOME/pi-desk`, default `~/.local/share/pi-desk`; `PI_DESK_DATA_DIR` overrides). The
data dir keeps Deckhand's former name, pi-desk, so existing workspaces carry over. Mode
`0600`, written whole and atomically (temp file in the same dir, fsync, rename) one second after
the first change to saved data (pi status, panel, focus and tab-exit updates do not count), only
when the content changed, and once more at quit (before the
tabs' processes are stopped). Test mode saves and restores only with an explicit
`PI_DESK_DATA_DIR`.

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

`<data dir>/tokens.json` (only with `keep_sessions` on, Experimental): the control socket's
tokens of the tabs whose process runs in the session holder, so those processes can reconnect
after Deckhand reopens (PROTOCOL.md §2). Keyed by holder terminal, sha256 hashes only, never a
token. Mode `0600`, rewritten atomically on every mint and revoke, MAC'd with the holder's
in-memory key (`src/macfile.odin`: a `deckhand-mac 1 tokens <hmac>` line, then the JSON): a file
that does not verify is ignored whole.

With `keep_sessions` on, a terminal tab (pi, shell, Claude, Home's pi) whose process runs in the
session holder saves `"held": <terminal id>` (a pi tab started read-only also `"readonly":
true`), and at a quit that hands the sessions over (`src/holder_adopt.odin`) Deckhand writes
`<data dir>/handover/<id>.snap` (`0600`: each terminal's snapshot at the offset the holder
acked, `src/snapshot.odin`) and `<data dir>/handover.json`, MAC'd as `handover`:
`{"v":1,"min_reader":1,"holder":<WELCOME instance>,"boot":<kern.boottime>,"written":<unix>,
"terminals":[{"term","offset","sha256","format","inexact"}]}`. Both are read once at the next
launch and removed. They are used only when the MAC verifies, `min_reader` ≤ 1, `holder` is the
attached holder's instance, `boot` is this boot and the holder says the last core said goodbye
(`trust.handover_fresh`); each snapshot only when its sha256 matches. Otherwise the terminals are
rebuilt from the holder's tails (`inexact`).

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
  `account`: its account's config folder (§1b; it starts there again; left out from older files:
  the default). A saved id that is not a session id, or flags Deckhand sets itself, drop the tab.
- **Panes** (docs/GUIDE.md, split panes): a session split into panes also saves `panes`; a
  session with one pane has no `panes` key (its entry is exactly as before panes):

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
  shows, `focused` the pane with the keyboard; `active_tab` stays the focused pane's shown tab,
  so a file read by a Deckhand from before panes gives the same tab. Pane ids, sizes, the focus
  history and drags are not saved. `WORKSPACE_VERSION` is unchanged: **a Deckhand from before
  panes reads a file with `panes` and silently drops the layout** (every tab back in one pane,
  the focused pane's tab active); its next save leaves the key out.
  Restored with `restore_session` (`persist.odin` `panes_parse`, `panes_restore.odin`). The tabs
  always come back from `tabs`; `panes` only places them, and a layout that does not fit never
  fails the restore:
  - **One pane** (as from a file without `panes`): `panes` not an object; no `tree`, or a tree
    that is not one (a node neither a pane nor a split; a split whose `split` is not `right` or
    `down`, whose `ratio` is not a number or that lacks `a` or `b`; a pane number not an
    integer, used twice or not below the number of panes); a single pane; more than 8 panes;
    and, after the rules below, anything the session's pane checks refuse.
  - A `ratio` out of 0.05–0.95 is clamped into it.
  - A tab whose `tab_pane` entry is missing, not an integer or not a pane goes to the focused
    pane. A `focused` that is not a pane: the first pane.
  - A pane shows its `active` tab when that is one of its tabs and came back; else the saved
    `active_tab` when it is in that pane; else its first tab.
  - A pane none of whose tabs came back (an app tab, a diff view, a file that is no longer a
    regular file, a URL that does not open, a bad Claude session: the tabs every restore drops)
    is removed and the split around it closes; if it had the keyboard, the first pane left
    gets it.
- A Claude-only session (docs/CLAUDE.md §1) is saved in `open_sessions` as
  `{"agent":"claude","claude_session_id","pi_session_id":"","cwd","project","tabs":[{"kind":"claude",…},…],"active_tab"}`:
  `tabs[0]` is its main Claude tab (same id), never a pi tab; saved once Claude reported its
  session id. `pi_session_id` is `""` so a Deckhand from before Claude sessions skips it. Restored
  with `restore_session` and `agent: claude`; a saved id that is not a session id, or a first tab
  that is not that Claude tab, drops the session. Files from before have no `agent` (pi
  sessions): they load as they did.
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
  Deckhand's own and not saved. `fork_from`: Atlas's old session file while its fork is
  pending: when the session's header (first line only) records a cwd other than Atlas's
  (after realpath), Atlas's start moves to id `home_fork_id(old id, folder)` (a name-based
  UUID: every attempt at the same move gets the same id) and runs `pi --fork <old file>
  --session-id <that id>`; if that id's file already exists it is resumed instead. Nothing
  is saved at that moment (the start can run mid-restore); the normal save cycle saves the
  id and `fork_from`. Until the id's file is in `<data dir>/home` the next start asks for
  the same fork; then `fork_from` goes. If pi exits without writing it, the fork is dropped:
  back to the old id, resumed (not forked again until the next launch), with a note in the
  terminal. No fork: pi older than 1.4.0, an unreadable header or no cwd, or a main folder
  set but unreachable (a pending fork is dropped then too). The old file is never touched
  (home.odin `home_session_start`, `home_fork_exited`). Restored not started; the first open of the agent's drawer resumes it in its terminal
  (`pi --session-dir <data dir>/home --session <file>`, or `--session-id <id>` if pi never wrote
  it). `model_applied` is the `agent_model` it last ran with (recorded at pi's first status): `--model` is passed again only
  when the setting differs (docs/PROTOCOL.md §8). Home is not in `open_sessions`. Its prompt
  file `<data dir>/atlas/ATLAS.md` is the user's and never rewritten.
- `layout.drawer_width`, `layout.drawer_pinned`, `layout.drawer_open`: the agent's drawer. Open
  at quit = it opens (and the agent starts) at launch.
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
  `settings.tidy_projects: false` (when off), `settings.keep_sessions: true` (when on; the
  session holder's `tokens.json` is its own file, above). The tidy list's state (temp, missing, nesting) is
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
- Claude Code accounts (`src/claude_accounts.odin`, docs/CLAUDE.md §1b): `settings.claude_accounts`
  (`[{dir, label?, added?, removed?}]`: only what the user changed: a name of their own, a folder
  they added, one they removed; absolute folders, at most 64), `settings.claude_account_default`
  (the chosen default's folder; left out: the environment's) and `settings.claude_account_last`
  (the account a Claude session last started with). Folders and names only, never a secret or a
  file's content. Restored in place (no command); found folders are looked for again at start.
- Folders (`src/folders.odin`): `settings.home_dir` (the main folder), `settings.folders`
  (`{"chats": "/abs", …}`: only overridden subfolders) and `settings.setup_seen: true` (the
  first-run sheet was done or skipped), each when set. Restored with `set_folder` (overrides
  first), then `set_home_dir` as the internal caller: nothing is made at restore, and a main
  folder that is not there (an unplugged drive) stays set. Migration from older files, once:
  `notes_dir` becomes `home_dir` (no setup sheet); `chats_dir` becomes the chats override
  unless it is `<home_dir>/chats`; with a `notes_dir` but no `chats_dir`, chats keep running in
  `~/Chats` (it becomes the override), so nothing moves. The old keys are not written again.
  Nothing is ever moved between folders.
- `sidebar`: only what differs from the defaults. Pins (in pinned order) and hidden items by
  identity (project cwd with symlinks resolved, pi session id or a Claude row's Claude session id), so they survive rescans; project
  entries whose folder no longer exists are dropped at save;
  the sort per section (`projects`, `sessions`, `chats`; default `recent`), folded sections and
  `show_hidden`. The filter text and quick filters are not saved. Restored with the internal
  `restore_sidebar`, then `set_sort`, `set_sidebar_folded`, `set_filter`.
- `settings`: only non-default values. `confirm`/`confirm_close` are user-only settings; reading
  them back from the user's own file is the user setting them.
- Focus always comes back to the terminal (a text field's content is not saved).
- Not saved: runtime ids, `version`, the session list (rescanned), pending confirmations and their
  tokens, socket tokens, pi status and blockers, panel contents, the command log, text-field
  contents, terminal scrollback.

## Restore

At startup, after the store scan and before `deckhand DIR`, the file is replayed as ordinary
commands with caller `internal` (so they appear in the command log): `set_theme`,
`set_reduce_motion`, `set_appearance`, `set_text_size`, `set_confirm_policy`, `set_close_confirm`, `add_project` (projects the scan
did not find), `rename_project`, `restore_session` (internal only: an open session with its tabs
`not_started`; with `"home": true` the Home session), `set_panel`, `set_panel_collapsed`, `set_left_tab`, `set_layout`, `files_expand`, `restore_sidebar` (internal only), `set_sort`, `set_sidebar_folded`, `set_filter` (`show_hidden`), `select_project`. After the first
layout (the pane has a size) a `focus_tab` on the saved current tab starts that session; every
other session starts when it is focused (lazy restore). Shell tabs restart as a new login shell in
their saved cwd (the session's cwd if that is gone) and print a dim note that the old history is
not kept. Claude tabs start `claude --plugin-dir … --resume <id> <flags>` in their saved
cwd (without `--resume` when no id was reported), with a new token; a Claude-only session's
main tab the same. With Claude Code no longer installed they do not start: the tab says why and
shows as exited (docs/CLAUDE.md §1). `deckhand DIR` opening a new chat skips the restored focus.
The terminals' text size (`settings.terminal_text_size`, saved only when not the look's) is
replayed with the other settings, as `set_terminal_text_size`. Then, before the first layout,
tabs with a `held` id the session holder still lists are adopted at once (not lazily): their
terminal comes back from the handover snapshot plus the holder's tail (exact), or from the tail
alone (`inexact` in State), and their status is `running`; replies to queries in the replayed
bytes are dropped. Held terminals no tab claims are released (hung up). A `held` id the holder
no longer lists restores as above.

- Corrupt file, unknown `v`, not a regular file, or over 4 MB (checked before reading) → moved aside to `workspace.json.bad-<unix time>`, start
  empty. Nothing is changed before the file is validated.
- `deckhand --fresh` → no restore; an existing file is moved aside to `workspace.json.bak-<unix time>`
  and the new run saves normally.
- Restore time is logged to stderr (`workspace restored … in N ms`, `restored session started N ms
  after launch`).
