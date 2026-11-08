# Deckhand user guide

Deckhand is a desktop app for coding agents: [pi](https://pi.dev) and
[Claude Code](https://code.claude.com). It keeps your projects and their sessions in one window:
the list on the left, the agent's normal terminal screen in the middle, more tabs (shells, files,
web pages) beside it, a built-in assistant, **Atlas**, in a drawer on the right, and **jobs**:
prompts that pi runs for you on a schedule.

This guide covers what is in Deckhand today. Developers: the wire protocol and every command are in
[PROTOCOL.md](PROTOCOL.md); building and the code in [DEVELOPING.md](DEVELOPING.md); the saved
workspace in [PERSISTENCE.md](PERSISTENCE.md); the design of jobs (and what comes next for
them) in [ATLAS.md](ATLAS.md).

Every action has a button and most have a shortcut, and the menu bar lists them by menu (Deckhand,
File, Edit, View, Window, Help). When you forget one: **⌘K** searches every action by name, and
**⌘/** lists every shortcut, grouped like the menus.

## Contents

1. [The window](#the-window) (and [the first run](#the-first-run))
2. [Projects, sessions and chats](#projects-sessions-and-chats)
3. [Tabs](#tabs)
4. [The terminal](#the-terminal)
5. [Editor tabs](#editor-tabs)
6. [The Files tab](#the-files-tab)
7. [The Changes tab](#the-changes-tab)
8. [The Settings tab](#the-settings-tab)
9. [Hot reload](#hot-reload)
10. [Atlas](#atlas)
11. [Jobs](#jobs)
12. [The bell](#the-bell)
13. [The palette and the gear](#the-palette-and-the-gear)
14. [Updates](#updates)
15. [Your data](#your-data) (and [your folders](#your-folders))
16. [Troubleshooting](#troubleshooting)
17. [All shortcuts](#all-shortcuts)
18. [All palette actions](#all-palette-actions)
19. [Coming soon](#coming-soon)

## The window

From left to right:

- **The left column** (⌘B shows or hides it). Four tabs at its top: **Sessions** (your projects,
  sessions and chats), **Files** (⌘⇧E), **Settings** (⌘,) and **Jobs** (a dot when a job's run
  is unread). When the column is narrow the tabs show icons instead of names.
- **The centre**: the tabs of the session you are looking at, and the tab itself (pi, a shell, a
  file or the session's changes).
- **The right column** (⌥⌘B): panels that the session's pi publishes, such as its todo list,
  background shells and subagents. Click a panel's heading to fold it.
- **Atlas's drawer** (⌘J): slides in from the right, or stays as its own column when pinned.

The top bar holds, from left to right: show/hide the left column (⌘B), New chat (⌘N), the
search pill (⌘K), the session's tabs with **+** (new shell tab, ⌘T) and its **⌄** menu (new
tab, chat or session), **±** (the session's [changed files](#the-changes-tab)), the **bell**, the **gear** (quick settings), show/hide the right column
(⌥⌘B) and Atlas (⌘J). Empty parts of the top bar move the window; a double-click there zooms
it. Hover any button to see its name and shortcut.

To resize a column, drag its edge. To reset its width, double-click the edge.

When Deckhand needs you to confirm something (closing a running tab, quitting), a bar appears
above the tabs with **Cancel** and **Confirm**.

### The first run

The first time Deckhand starts without a main folder (new users, and once after the update that
added it), a **Set up Deckhand** sheet opens over the window. It has four steps (five when
Deckhand finds more than one Claude Code account):

0. **Your coding agents**: a checklist per harness (pi, Claude Code), from the
   [harness manifest](HARNESSES.md#6-the-harness-manifest):
   - **The harness**: installed or not, its version against the minimum (pi 1.4.0, Claude Code
     2.1.295) and how it was installed (its installer, Homebrew, npm, bun, pnpm, nix, mise).
     Deckhand finds this by looking where the binary links to; it never runs pi or claude to ask.
     A harness you don't have is one collapsed line, **Not installed**, with its official install
     command and **Install**: you need one harness, not both.
   - **Deckhand's integration** (its pi extensions, its Claude Code plugin): **Built in**. It ships
     inside the app; there is nothing to install. "Not loaded" says why (a pi older than 1.4.0).
   - **Recommended**: third-party items, each with a one-line reason, ticked when installed. For pi:
     [pi-subagents](https://www.npmjs.com/package/pi-subagents) and
     [rpiv-todo](https://www.npmjs.com/package/@juicesharp/rpiv-todo), which feed the Subagents and
     Todos panels, found in `~/.pi/agent/settings.json` (read, never written by Deckhand). Claude
     Code needs nothing more ("nothing else needed").

   Every **Install** and **Update** shows its exact command first and runs only when you click it,
   in a terminal on the sheet (its output live; the keyboard is the terminal's while it runs, so ⌃C
   stops it; the sheet stays until it ends). Something already installed is never installed again;
   the install script also stops if it finds the harness on your login shell's PATH. Afterwards
   Deckhand looks again and ticks what it finds. An update runs the copy Deckhand found, by its full
   path (and the npm, bun, pnpm or brew next to it), and refuses if that copy has changed since.
   Updates run for the official installer, Homebrew,
   npm, bun and pnpm installs; for nix, mise and anything Deckhand cannot place it shows the command
   with **Copy** (or says to use that package manager), and an npm folder that needs `sudo` is left
   to you: Deckhand never runs `sudo` (a `sudo` inside a run refuses and prints the command for you
   to run). A pi package installed from git or a local folder counts as found (its version can't be checked,
   and the sheet says so); a project's own `.pi/settings.json` is noted, and an old pin there is
   flagged, but never counts as installed. Settings → **Coding agents** lists the same, and its
   **Install…** and **Update…** open this step.
1. **The main folder**, where your notes, jobs, memory, Atlas's prompt and chats live (see
   [Your folders](#your-folders)):
   - **Use your notes folder**: offered when Deckhand finds one, with the path and why it found
     it: your `PI_KIT_NOTES_DIR`, or a folder named in pi's global `AGENTS.md`
     (`~/.pi/agent/AGENTS.md`), else in Claude Code's global `CLAUDE.md` (`~/.claude/CLAUDE.md`,
     or `$CLAUDE_CONFIG_DIR/CLAUDE.md`), that has a `sessions/` folder. Those two files are the
     only ones it reads, and only the path it finds is shown. pi's and Claude Code's own folders
     (`~/.pi/agent`, `~/.claude` and above), your home folder and git checkouts are never offered.
   - **Create ~/pi-desk**: the default when nothing is found.
   - **Choose another folder…**: any folder.
2. **Chats**: **Inside the main folder (chats/)** or a **Separate folder** (pre-selected when you
   picked one before, or when `~/Chats` already has chats; **Choose separate folder…** picks
   another). Files pi creates in chats land in that folder.
3. **Claude Code accounts**, only when two or more are found (see
   [Claude accounts](#claude-accounts)): each with a checkbox (offer it in Deckhand or not), its
   name (click to change it) and its folder, and **Default** (where new Claude sessions start).
   Type a folder's path (`~/…` or `/…`) and press **Add**, or **Add folder…** to pick one
   anywhere; a folder without Claude Code's files is added with a warning (Claude Code makes them
   at its first sign-in there). Nothing is written until **Done**, which saves the same list the
   Settings tab edits. With one account (or none) there is no such step.
4. **Your folders**: the layout as a small tree. **Done** makes the missing folders, empty, and
   closes the sheet. Nothing already there is moved or changed. The step also says whether
   Claude Code is installed (Deckhand looks for `claude`, never runs it): Claude tabs need it,
   nothing else does; with one account it names its folder. With both pi and Claude Code it says
   that **New session** asks which one to start; with Claude Code alone, that pi isn't installed
   (Atlas and jobs need it); with neither, how to install one. When your pi is older than 1.4.0
   it says so too (see [pi in Deckhand](#pi-in-deckhand)).

**Skip for now** (or Esc on the first step) closes it for good: jobs stay off, and the Jobs tab
and Atlas's drawer offer **Set up Deckhand…**. Reopen it any time from the gear's **Set up
Deckhand…**, the palette or the menu bar (Deckhand → Set up Deckhand…), or, while no main folder
is set, the Settings tab's **Folders** group. It starts at the coding agents with your current
folders filled in, and Esc there closes it without changing anything. Enter goes to the next step (Done on the
last), Esc goes back, ↑↓ change the choice.

If you already had a notes folder set (before the main folder existed), it simply becomes the
main folder and the sheet does not open.

### pi in Deckhand

Deckhand brings its own pi integration, so a pi tab needs nothing else installed: the status
dots, Atlas's tools, waits and prompts between tabs, reloads, comments for the agent, the Todos
and Subagents panels, and the agents' browser and app-tab tools all come from it. It ships inside
`Deckhand.app` and Deckhand loads it into every pi it starts (`pi -e`, for that run only). Nothing
is installed into pi or written to `~/.pi`: pi outside Deckhand runs exactly as before.

It needs **pi 1.4.0 or newer**. When Deckhand sees (from pi's files on disk; it never runs pi to
ask) that your pi is older, it starts pi without the integration and a bar over the tab says so,
with **Copy update command** (`pi update`) and **Dismiss**; the setup sheet says so too, with
**Update** for the layouts it can update. Update pi,
then restart the tab.

The Todos panel reads [rpiv-todo](https://www.npmjs.com/package/@juicesharp/rpiv-todo) and the
Subagents panel [pi-subagents](https://www.npmjs.com/package/pi-subagents), when you have them
installed in pi; another extension that publishes those panels itself takes them over.

[pi-kit](https://github.com/McFalljb/pi-kit) is optional extras that also work outside Deckhand:
guardrails, background shells, session notes, skills and agents for delegating and reviewing work,
and its sidebar in a plain terminal. Installed, it works next to Deckhand's integration: its own
Deckhand parts (`desk-bridge`, `desk`, `desk-browser`) stay inactive in Deckhand's tabs, because
Deckhand no longer gives pi the variables they wait for, and its sidebar hands its sections to
Deckhand's right column as before.

## Projects, sessions and chats

- A **project** is a folder you work in. Its **sessions** are the pi sessions you ran there (pi
  stores them in `~/.pi/agent/sessions`, or `$PI_CODING_AGENT_DIR/sessions` when you set that, a
  leading `~` meaning your home folder as pi reads it; Deckhand lists them, it does not copy them).
  pi's `PI_CODING_AGENT_SESSION_DIR` and its `sessionDir` setting are not followed yet: sessions
  kept there do not show in Deckhand.
- A **chat** is a pi conversation outside any project. Chats run in one folder, the main
  folder's `chats/` (or `~/Chats` without a main folder, or the folder you chose), so
  `cd <that folder> && pi --resume` finds them too. That folder has its own **chat
  instructions** (`AGENTS.md`, which pi reads there besides your global one): in chats pi is a
  conversation partner and researcher, not a coding agent. It explains, looks things up and
  cites sources, and draws diagrams in text. Edit them with the palette's **Edit chat
  instructions** or Settings → Chats.
- An **open session** is a session running in Deckhand now, with its tabs.
- A **Claude session** is a [Claude Code](#claude-code-tabs) conversation in a project. It is a
  session of its own, beside your pi sessions: its main tab is Claude, there is no pi tab.

The Sessions tab has three sections:

- **Open**: every open session, the one on screen first. A project's session shows a folder icon
  and `project ·` before its title; a chat shows a speech bubble. Only shown while something is
  open.
- **Projects**: a tree. Git repositories are top-level rows; other folders nest under the
  folder they sit in, or share a group row (see [A tidy project list](#a-tidy-project-list)).
  The selected project is expanded with its sessions (the first eight, then **Show more**),
  and **+ New session**. Its Claude sessions are listed with its pi sessions, marked **Claude**.
- **Chats**: your chats, with **+ New chat**.

A session's **title** is pi's own: the name you gave it with `/name` in pi, else your first
message, else "Untitled session · <date>" (see [Troubleshooting](#troubleshooting)).

### A tidy project list

Deckhand finds a project for every folder pi ever ran in, which gets cluttered. Three rules keep
the Projects list short. They only change what the list shows: no session file is touched, and
your own hidden list is never changed.

- **Temp folders are hidden.** A project in a temporary folder (`$TMPDIR`, `/tmp`,
  `/var/folders`, and their `/private/…` paths) does not get a row, unless you pinned it or one
  of its sessions is open. **Show hidden** lists it tagged **temp**, the filter finds it when you
  type part of its name or path, and so does the palette.
- **Folders nest; sessions never move.** Every session stays in the row of the exact folder you
  started it in: `github/` lists only the sessions you ran in `github/`, never those of
  `github/project1`. Only the rows are arranged:
  - a **git repository** (a folder with `.git`; worktrees count) is always a top-level row,
    wherever it lives; so is a folder you added by hand (+, a dropped folder, `deckhand DIR`,
    remembered across restarts) or pinned;
  - **a group row**: when two or more other folders (not hidden ones) sit side by side in a
    folder that is not a project itself (say the dated folders in
    `~/code/projects/_scratch/`), they show inside one row for that folder: its name and
    how many folders it holds, no sessions of its own. When two group folders share a name,
    their rows add the folders above it until they differ (`repoA/docs`, `repoB/docs`); hover a
    group row for its full path. A folder deeper inside it (`_scratch/run-1/gpt` when pi never ran in `run-1`) shows
    in the group row too. A group row sits under the project it is in (`_scratch` under
    `~/code/projects` when pi ran there), or inside another group row when its folder is
    in that group's (`_scratch/run-1` inside `_scratch` when pi never ran in `run-1`); with
    neither above it, it is a top-level row;
  - **a nested row**: any other folder inside a project shows under the nearest one
    (for example `…/run-1/try-C` under `run-1`). The parent row says how many
    folders it holds ("3 folders", counting the folders in a group row inside it, not the group
    itself); click that to open or collapse them. Folders match by whole names:
    `/a/foobar` is not inside `/a/foo`.

  Nested and grouped rows are ordinary projects: select one to see its sessions, and hover it
  for New session, Pin, Hide and the rest. Group rows and parents start collapsed; Deckhand
  remembers which ones you opened. Your home folder and `/` never hold rows (they stay
  ordinary rows), and neither does a hidden project: what it would hold goes under the next
  shown row above it, or to the top. The filter searches every row and opens
  the rows above a match; the selected project and work waiting for you are never tucked away
  inside a collapsed row. A row kept open that way does not react to clicks (no hand pointer;
  its tooltip says why) and your saved choice for it stays as it was.
- **Missing folders are hidden.** A project whose folder is gone (deleted, or on a drive that is
  not plugged in) is hidden unless pinned, open or waiting for you. **Show hidden** lists it,
  greyed and tagged **folder missing**, and the filter finds it. It comes back by itself at the next scan once the folder
  is there again (the gear's "Rescan sessions" scans now).

Under **Show hidden** every hidden project carries its reason: **temp**, **folder missing**, or
**hidden** (hidden by you). To see every folder as its own top-level row again, turn off **Tidy
project list** in the gear (or the palette); it is on by default and remembered.

### Status dots

A dot on a tab says what the program in it is doing, and a dot after a session's row says the
same for the most urgent of its tabs (a project's row: of its open sessions):

| Dot | Meaning |
|---|---|
| none | idle, not open, or not reporting yet |
| pulsing blue-green | working |
| amber, "Waiting for you" | it needs your answer: a pi dialog, or a program asking permission, a question or a login |
| green | it finished while you were not looking (or you marked it unread); looking at the tab clears it |
| faint amber | its last answer asked you a question |
| red | its last run ended with an error |
| grey | pi exited |

pi tabs report through Deckhand's pi integration ([pi in Deckhand](#pi-in-deckhand)). Any other program in a terminal tab can report too, with
the OSC 7501 program status protocol: Claude Code (2.1.295 or newer) does by itself. When both
could speak for a pi tab, its bridge wins. Hover a dot's tab or row to see what it is, where it
came from (pi bridge or OSC 7501) and how long ago it was reported.

Waiting work is never hidden: hidden rows, folded sections and filters always leave sessions
that wait for you visible.

### Everyday tasks

- **To add a project**, click **+** on the PROJECTS heading and pick a folder, drop a folder onto
  the left column, or use the palette's "Add project…". From a terminal, `build/deckhand DIR`
  adds DIR and starts a new session there.
- **To open a session**, click it. If it is already open, Deckhand shows it instead of starting it
  twice.
- **To start a new session in a project**, click **+ New session** under it (or the **+** on its
  row), use the **⌄** menu, or press ⇧⌘N (in the selected project). `build/deckhand --claude DIR`
  starts a Claude session in DIR.
- **To start a new chat**, click the New chat button in the top bar or **+ New chat**, or press ⌘N.
- **Which agent starts.** Deckhand looks for pi and Claude Code (it never runs them to find out).
  With both installed, **New session** and **New chat** open a small picker: **pi** and **Claude
  Code** (once per account when you have several), each with its icon, under the button or row you
  used. ↑↓ and Enter, a number key (1, 2…, the keypad's too) or a click picks; Esc closes it. The one you used last comes first and is selected, so
  Enter starts it again. With only one installed it starts at once, without a picker; with
  neither, a message says how to install one. Deckhand looks again each time you start one, so a
  harness you just installed is offered. The same picker opens from a project's **…** menu
  (**New session**) and a worktree's **New session here**.
- **To select a project**, click it; click it again to fold it.
- **To act on a row**, hover it and click **…**, or right-click it (or ⌃-click). Projects offer
  Pin, New session, New job for this project…, Rename…, the session order, Reveal in Finder, Copy
  path and Hide. Sessions offer Pin, Reveal in Finder, Copy path (of the session file), Copy
  session info, Send to Atlas, Mark as unread (open sessions; Mark as read when it is), Hide and
  Close session.
- **To come back to a session later**, use its **…** → **Mark as unread**: it keeps the green dot
  until you look at it again.
- **To start a job for a project**, click **New job…** under the selected project (below
  **+ New session**), or use its menu's **New job for this project…**: the [job
  sheet](#the-job-sheet) opens with that project chosen.
- **To give Atlas a session's details**, hover the session and click **ⓘ**: a menu shows the
  session's info (its id, session file, project, folder, title, when it was created and last
  changed, and its model when the session file's header names one) with **Copy session info** and
  **Send to Atlas**. The same two are on the session's right-click menu. The info is a short
  block of `key: value` lines that Atlas can use to look the session up; Deckhand reads only the
  session file's first line (its header) and the file's dates, never the conversation. **Send to
  Atlas** opens Atlas's drawer and puts the block into Atlas's input without sending it: type
  your question after it and press Enter. While Atlas's pi is starting the block waits for it.
  When it cannot go in (Atlas waits for you, its model selector is opening, or its input does
  not take pasted text), the block is copied to the clipboard instead and the bell says why.
- **To pin** a project or session to the top of its section, click the pin on its row or use
  **…** → Pin. Pinned rows get Move up / Move down in the same menu.
- **To rename a project**, use **…** → Rename…, or the palette's "Rename project". A pi session
  is named in pi: type `/name My title` in the session. A Claude row: **…** → Rename….
- **To hide** a project or session, use **…** → Hide. Nothing is deleted.
- **To see hidden rows**, click the sort button on a section heading and tick **Show hidden**
  (or the palette's "Show hidden projects and sessions"). Hidden rows then show, and their menu
  offers **Show again**.
- **To sort** a section, click the sort button on its heading: Recent activity, Name, Created or
  Needs attention (sessions waiting for you or stopped with an error first, then those that
  finished while you were away, then working ones, then the rest).
- **To fold** a section, click its heading. A folded Open section still shows waiting sessions.
- **To filter**, press ⌘⇧F (or click the Filter field) and type: words match project names and
  paths and session titles, loosely. The **Running**, **Waiting** and **Pinned** chips under it
  narrow the list further. Esc in the field clears it.
- **To pick up new pi sessions** started outside Deckhand, use the gear's "Rescan sessions".

### Chats settings (the gear)

- **Chats: read-only** starts chats as read-only pi instead of full pi. Off by default. pi itself
  limits what the model may call, with or without pi-kit: only pi's read tools (read, grep, find,
  ls) and `desk_show` (it shows you a file in a tab, nothing more), as a read-only job does without
  `desk_show` (`--tools read,grep,find,ls,desk_show --exclude-tools 'mcp__*' --no-mcp`).
  The model cannot call edit, write or bash, so it **cannot run shell commands**, and it has no
  MCP or other extension tools (Deckhand's own browser and app tools included; its status,
  waits and comments keep working, as they are not tools). With pi-kit
  installed its read-only guardrails (`PI_KIT_READONLY=1`) are on as well. What this does not
  cover: the extensions you installed still load and run their own code (their hooks and slash
  commands; an extension that commits or writes notes when a turn ends still does), and an
  extension tool named read, grep, find or ls replaces pi's own. Your own `!` commands typed into
  pi still run; they are yours, not the model's. Deckhand starts whatever `pi` your login shell
  finds: a wrapper or shim named `pi` that adds its own `--tools` could widen the list. Read-only
  chats need pi 1.0.4 or newer: with an older pi (as Deckhand last saw it on disk) a read-only chat
  does not start and says so; while Deckhand does not know pi's version yet it starts. It applies
  at every start of a chat's pi (new, resumed, restored, restarted): a running chat keeps what it
  started with until it starts again, and then follows the setting as it is then. That differs on
  purpose from Claude chats below, which stay read-only once started read-only. Claude in chats (**+ New chat**'s **Claude Code**, or a Claude tab in a
  chat) then starts read-only too, with Claude Code's own controls: plan mode, the tools that edit
  files, spawn agents, schedule work or use MCP denied, and Deckhand's guard on commands (the same
  list of mutating commands pi-kit blocks); it cannot click or type in your pages and apps either.
  The tab reads "read-only". Of your extra flags only `--model`, `--effort`, `--fallback-model`
  and `--verbose` go along. Turning the setting on applies when a Claude tab in a chat next starts;
  a tab that started read-only stays read-only (start a new chat for a full one). If Deckhand cannot confirm that Claude Code took its read-only settings
  (an older Claude Code), it stops the tab and says so: update Claude Code, then Restart.
- **Chats folder…** picks another folder for new chats; chats already in the old folder stay
  there, and that folder becomes an ordinary project. **Chats folder: back to the default**
  undoes it (the main folder's `chats/`, or `~/Chats` without a main folder). The same as the
  Folders group's chats row (see [Your folders](#your-folders)).

## Tabs

Each open session has one **pi tab** (always first) and any number of **shell tabs**,
**Claude tabs**, **editor tabs**, **browser tabs** and **app tabs**.

- **To open a shell tab**, click **+** in the tab strip or press ⌘T. It starts your login shell
  in the session's folder. The Files tab's row menu also has **Open terminal here**.
- **To open an app tab** (a program that draws into the tab, such as a game engine), pick
  **New app tab…** in the **+** menu or the palette, then type the command to run (or pick one
  of the project's `.pi-desk/apps.json` entries) and press Enter. It runs in the session's
  folder; its output goes to a log. Keys, clicks and the wheel go to the app while it is on
  screen and nothing else has the keyboard. If the app exits, its last picture stays, dimmed,
  under a bar with **Restart** and **Log**; if it stops drawing, the bar says "No frames for Ns",
  or "not responding" with **Restart** and **Wait**. The bar's **Inspect** button (or **Inspect
  app boxes** in the palette) draws the boxes the app reports (its entities, panels…) over it:
  point at one to see its label, click one to write a comment on it for the agent ([Comments for
  the agent](#comments-for-the-agent)). While Inspect is on, the mouse over the tab is Deckhand's; keys still go
  to the app. Agents drive it with `app_call` (any method the app offers; they ask it
  with `tab.describe`), `app_input`, `app_events` and `app_screenshot` (see PROTOCOL.md).
- **To open a Claude tab** (Claude Code in a terminal), pick **New Claude tab** in the **+**
  menu, the File menu or the palette, or **New Claude tab here** in a session row's menu, or
  press ⌥⌘T. See
  [Claude Code tabs](#claude-code-tabs).
- **To open a browser tab** (a web page, Chromium inside Deckhand), pick **New browser tab** in
  the **+** menu, the File menu or the palette: a blank page opens with the keyboard in its
  address field. Type an address and press Enter (or **Go**). See [Browser tabs](#browser-tabs).
- **To switch tabs**, click one or press ⌘1–⌘9; ⇧⌘] and ⇧⌘[ go to the next and previous tab.
  ⌥⌘↓ and ⌥⌘↑ go to the next and previous open session (Window menu).
- **To close a tab**, click its **×** or press ⌘W. Closing a tab that is busy asks first: a shell
  running a command, or an editor with unsaved changes.
- **To split the centre into panes**, press ⌘D (**Split pane right**) or ⇧⌘D (**Split pane
  down**): the pane with the keyboard splits in two and a new shell opens in the new half. A
  session has at most 8 panes, and a split needs room for two panes of at least 240 × 140
  points. Once split, each pane has its own strip of tabs (they leave the title bar), with a
  **+** for a new shell in that pane; the pane with the keyboard has an accent line under its
  strip. Click in a pane to give it the keyboard (the click also acts there, so a click in a
  shell starts a selection at once), or press ⌃⌘←, ⌃⌘→, ⌃⌘↑ or ⌃⌘↓ (**Focus pane left**,
  **Focus pane right**, **Focus pane up**, **Focus pane down**). A selection you drag from one
  pane over another stays in the pane where you pressed. ⌘1–⌘9, ⇧⌘] and ⇧⌘[ and ⌘W act on
  the tabs of the pane with the keyboard.
  - **To move a tab to another pane**, press ⇧⌃⌘←, ⇧⌃⌘→, ⇧⌃⌘↑ or ⇧⌃⌘↓ (**Move tab to the pane
    left**, **Move tab to the pane right**, **Move tab to the pane above**, **Move tab to the pane
    below**); with no pane that way, the tab splits off into a new pane there. A pane whose last
    tab closes or moves away closes too, and the keyboard goes back to the pane you used last.
  - **To drag a tab**, press it and move the pointer a few points (a click without moving still
    just shows the tab). A copy of the tab follows the pointer and shows where it will land:
    - over a strip of tabs (a pane's, or the title bar's while there is one pane): a line
      between two tabs; drop to put the tab there, which also reorders tabs in their own strip;
    - over a pane's edge (its outer quarter on each side): the half the tab would take is
      tinted; drop to split that pane that way with the tab in the new half. This is also how a
      session with one pane gets its first split from the title bar;
    - over the middle of another pane: the pane is tinted; drop to move the tab into it.
    Elsewhere the pointer shows that the tab can't go there, and letting go there (or outside
    the window) changes nothing. Press Esc to cancel. A split the session has no room for (8
    panes, or a pane too small for two halves) shows red with why, and dropping there changes
    nothing; a pane's only tab dropped beside another pane is never refused for the 8-pane limit,
    since its own pane closes. The session's pi tab (or Claude main tab) can move to another pane
    or split one too, but it always stays first in its strip.
  - **To resize panes**, drag the line between them; double-click it to make the two sides
    equal. **Even out panes** (palette, Window menu) gives every pane equal room.
  - **To unsplit**, press ⇧⌘W (**Close pane (its tabs stay)**): the pane goes and its tabs join
    the pane next to it; nothing is closed.
  - Browser and app tabs are live in every pane: pages load, play and scroll beside a shell,
    and each page or app fits its own pane. Only the pane with the keyboard gets your typing; a
    click in another pane's page gives that pane the keyboard and clicks there too.
  - Each session's panes come back when Deckhand restarts: the same splits and sizes, the
    same tabs in each pane, the tab each pane showed, and the pane with the keyboard. (A
    Deckhand from before panes opens the same workspace with every tab back in one pane.)
  - **Agents and panes.** A session's pi or Claude tab can't split panes or move tabs; it sees
    which tabs sit side by side, and the tabs it opens (a file it shows, a page, an app, a
    page its click opened) go behind what you see, in the pane that holds its own tab (a file
    right next to it), wherever you have moved that tab. Tabs you open go in the pane with the
    keyboard.
    Atlas can split, move and focus panes when you ask it to.
- **If pi exits** (it crashed, failed to start, or you quit it), its tab keeps its last output
  under a bar that says how it ended ("pi exited (code 1)", or the signal that stopped it, such
  as "signal 1 (SIGHUP)"); the tab and its row in the Open section say so too when you point at
  them. Click **Restart** to start pi again in the same tab on the same session. When it did not
  end cleanly the bar also has **Restart with model…**: pi starts again and opens its own model
  selector, so you can go on in the same session on another model (for example after a rate
  limit); not when pi was not found (code 127: see Troubleshooting). Opening the session again
  (its row, the palette, the bell) restarts it too. If pi cannot start, the tab stays as it was
  and a message says so.
- **To close a whole session**, click the pi tab's **×**, the **×** on its row in the Open
  section, its row menu's **Close session**, or the palette's "Close session". This always asks
  first, and says so when its processes are still running. pi's session file stays: you can
  open it again from the list.

Sessions you switch away from keep running in the background. When you quit (⌘Q) with sessions
running, Deckhand asks first; on the next start it restores your open sessions, tabs and layout,
and starts each session again when you first look at it.

**A tab belongs to one session.** A tab you open goes into the session on screen; one an agent
opens goes into that agent's own session, never "whichever session you happen to be looking at".
A page's popups and links that open a new window open in a new browser tab of the same
session. Tabs never move to another session, and whatever a tab sends to pi goes to its own
session's pi.

### Files an agent shows you

When you ask an agent to open or show a file "in a tab", it shows it in Deckhand: pi with its
`desk_show` tool, Claude with `deckhand show`. A Markdown file opens in a
[Markdown tab](#markdown-tabs), rendered; any other text file opens in an editor tab, at a line
if the agent gives one. A pi or Claude tab shows files only in its own session, right after its
own tab; Atlas names the session. The tab opens behind the one you are looking at, and a file
already open is not opened twice. It is display only: the agent cannot edit the tab, and nothing
of it goes back to the agent. Agents are refused credentials and secret files (`.env`, keys,
`~/.ssh`…), binary files, files over 20 MB, network and iCloud-only files, and more than 20 such
tabs per session. Read-only chats can show files too.

### Browser tabs

A browser tab shows a web page (Chromium, inside Deckhand). The bar above the page has:

- **‹** back, **›** forward (greyed out when there is nowhere to go), **↻** reload, which turns
  into **✕** (stop) while the page loads.
- **The address field.** Click it (or press ⌘L while the browser tab is on screen) to type an
  address, then press Enter or **Go**; Esc gives the keyboard back to the page. A full address
  (`https://…`, `http://…`, `file://…`) opens as typed; a bare host like `example.com` or
  `example.com/docs` gets `https://`, and `localhost:3000` or `127.0.0.1:8080` gets `http://`.
  Anything else (words, spaces) is refused with the reason under the field: searching from the
  address field is not built in yet.
- **The tab's title** is the page's title.
- **Annotate ⌘⇧.** at the right end turns comment mode on and off; while it is on, its hint
  takes the address field's place (see [Comments for the agent](#comments-for-the-agent)). ⌘⇧. works while
  you type an address too: the field lets go.
- **The zoom chip** ("125%") shows when the page is not at 100%; click it for 100%.
- **⋯** at the right end: **Find in page**, the zoom (**Zoom in**, **Zoom out**, **Actual
  size**), **Copy URL**, **Open in default browser** (web addresses only), **DevTools** (or
  **Close DevTools**) and **Show downloads folder**.
- The palette has **Browser: back**, **Browser: forward** and **Browser: reload page** for the
  browser tab on screen, and **Browser: find in page**, **Browser: zoom in**, **Browser: zoom
  out**, **Browser: actual size**, **Browser: DevTools**, **Browser: open in default browser**,
  **Browser: open the blocked popup** and **Browser: show downloads folder**.

**On the page:**

- **The pointer** takes the page's shape (a hand over links, a text bar over text) and the
  page's tooltips show next to it.
- **Right-click** opens Deckhand's menu: **Back**, **Forward**, **Reload**; over a link **Open
  link in new tab** (a new browser tab of the **same session**) and **Copy link**; over text or a
  field **Cut**, **Copy**, **Paste**, **Select all**; and **Inspect** (DevTools at that element).
- **Find in page** (⌘F with the browser tab on screen, **Edit ▸ Find in page**, or ⋯) opens a
  bar under the toolbar: type to find, "2 of 5" counts the matches, **‹** **›** (or ⇧Enter,
  Enter, ⌘G, ⇧⌘G) move between them, **×** or Esc closes it.
- **Zoom** with ⌘+, ⌘− and ⌘0 while a browser tab is on screen (there they zoom the page, not
  the text), **View ▸ Zoom page in / Zoom page out / Page actual size**, or ⋯. Chromium keeps
  the zoom per site. Comments picked on a zoomed page still land on the right element.
- **The bars** under the toolbar ignore a click (and Enter in a prompt's field) for half a
  second after any of the tab's bars appears, goes or changes, and after you switch to the tab,
  so a bar a page puts up or moves just as you click is never pressed by that click.
- **Page messages** (`alert`, `confirm`, `prompt`, "Leave this page?") show as a bar in the tab,
  naming the site that asks ("(embedded frame)" when a frame from another site asks):
  **OK** / **Cancel** (**Leave** / **Stay** for leaving a page; a prompt's bar has its text
  field: Enter is OK, Esc is Cancel). The page
  waits until you answer; nothing else in Deckhand does.
- **Downloads** go into your Downloads folder under a safe name (no folder part, no hidden
  name); an existing file is never replaced: the new one becomes "name (1).ext". A bar shows
  the progress, then **Open** and **Show in Finder** (**Cancel** while it runs, **×** to close
  the bar). Downloaded files are marked as downloaded, so macOS asks before opening a program;
  **Open** is not offered for a file that could not be marked, nor for `.command`, `.fileloc`,
  `.inetloc`, `.webloc`, `.terminal`, `.tool`, `.workflow`, `.action` and `.mobileconfig` files
  (use **Show in Finder**). One click (or Enter or Space) in the page lets it start one download;
  any other download it starts asks first: "<site> wants to download <name>", **Allow** or
  **Block**; while it waits, the page's other downloads are refused, and leaving the page drops
  it.
- **A popup the page opened without your click** is blocked; a bar says so ("3 popups blocked"
  when it keeps trying): **Open** opens the last one in a new tab of the same session, **×** drops
  it. A `file:` address opens this way (or with **Open link in new tab**) only from a `file:` page.
- **A page asking for notifications, your location, the camera or the microphone** gets a bar:
  **Allow** or **Block**, for this time only (nothing is remembered per site yet).
- **When the page crashes** a bar says so; **Reload** brings it back.
- **DevTools** (⋯, **View ▸ Developer tools**, or Inspect in the right-click menu) opens
  Chromium's DevTools for the page in a window of its own.

Keys and clicks go to the page while the tab is on screen and nothing else has the keyboard;
Deckhand's own shortcuts come first even then: ⌘T opens a shell tab, ⌘W closes the browser tab,
⌘1–⌘9 switch tabs, ⌘K opens the palette.

- **Links that open a new window** (`target=_blank`, `window.open` after a click) open in a new
  browser tab of the same session, next to the others; the page that opened it can still talk
  to it (sign-in popups need that). A page that tries to open a window without your click is
  blocked, with a bar to open it anyway.
- **One browser profile** for all of Deckhand: cookies and sign-ins are shared by every browser
  tab in every session, and kept across relaunches (in the data folder's `browser/profile`).
- **On relaunch**, each session's browser tabs come back in that session with their address and
  title; each page loads when you first look at its tab. The back/forward history is not
  kept, and an address's `name:password@` part is never saved.
- **Open pages**: Deckhand keeps at most 8 pages open at once. The tab you look at always gets
  its page: when all 8 are taken, the tab you looked at longest ago lets its page go (one of the
  same session first). A page unloaded to make room keeps its address and loads again when you
  show it, but it loses its back/forward history and anything typed into it. Only you cause
  that: a tab pi opens never takes another page's place (with all 8 taken it says "Too many
  open pages" and opens when one closes), and it opens behind the tab you are looking at.
- `file:` addresses are yours only: pi cannot open them.
- **Agents**: a session's pi can open and drive its own session's browser tabs with
  `browser_open`, `browser_navigate`, `browser_back`, `browser_forward`, `browser_reload` and
  `browser_stop`, and reads each tab's `url`, `title`, `loading`, `can_back` and `can_forward`
  in the state snapshot. A tab pi opens goes into pi's own session, never the one you look at,
  and opens behind that session's active tab;
  Atlas names the session (see PROTOCOL.md). pi can also read pages and act on them: click, type,
  press keys, scroll, choose, hover and upload. A strip on the tab says what it does, with
  **Take over** (pi waits until you press **Hand back**; your own click or key in the page while
  pi acts does the same) and **Stop**; in a narrow pane the strip takes a row of its own under
  the toolbar, and the palette has them too ("Browser: take over from the agent",
  "Browser: hand back to the agent", "Browser: stop the agent"). pi never types into password, card or one-time-code
  fields; an upload asks you first in a bar (**Allow** / **Block**); a page that changes your
  clipboard while pi acts is named in a toast. Details: BROWSER.md, step 8.
- **App tabs by agents**: a session's pi (or Claude) can open the apps your project lists in
  `.pi-desk/apps.json`, by name, in its own session: never another program, never another
  session. Deckhand does not ask you first: an agent that can write apps.json can already run
  that program from its own shell. A Claude tab's open, restart and close go through Claude
  Code's own permission mode (it asks unless you run it with permissions bypassed). The tab opens
  behind the one you are looking at and closes like any tab; pi can also restart and close its
  session's app tabs (not in read-only chats), and keeps at most 8 running per session.

### Claude Code tabs

A Claude tab runs [Claude Code](https://code.claude.com) (`claude`) in a terminal tab of the
session, in the session's folder, with your login shell's environment: your PATH, your
`CLAUDE_CONFIG_DIR` and account, your settings and plugins. Deckhand adds one thing: its own
plugin (`--plugin-dir`, from inside Deckhand.app; nothing is installed in your Claude Code
config). The plugin gives Claude:

- a `deckhand` command for the **browser and app tabs of its own session**, with exactly the
  rules pi has there (no JavaScript, refused password/card/code fields, your **Allow** for
  uploads, **Take over** and **Stop**), and `deckhand show` to show you a file in a tab
  ([Files an agent shows you](#files-an-agent-shows-you)). `deckhand --skill` prints its manual;
- your session's **comments** ([Comments for the agent](#comments-for-the-agent)) with your next message to
  Claude, the same way they go to pi;
- hooks that tell Deckhand Claude's session id and whether it is working or waiting for you,
  and what Claude is doing: its **todos** and **subagents** (each subagent's time, the tool it
  is using and its own todos), and its **Background** work (background shells, monitors and
  scheduled wakeups, as of Claude's last turn), shown in the right column while its tab is the
  one on screen (the same look as pi's Todos and Subagents; on pi's tab you see pi's). Deckhand
  can't stop Claude's background shells: ask Claude to, or restart it. Background work doesn't
  change Claude's dot: when its turn ends, it is done (a restart names what would stop).
  These hooks run in the background and add nothing to Claude's conversation.

**When something is missing.** On a Claude Code older than 2.1.295 the dots come from these
hooks (Claude Code's own status reports came later), and a bar says so with **Copy update
command** (the right one for how Claude Code was installed) and **Dismiss** (remembered for that
version). If Claude Code's
hooks don't run at all in a tab (`disableAllHooks` in your Claude settings, or an organisation
policy such as `allowManagedHooksOnly`), Deckhand can't save or resume that session, and comments,
held messages and the panels don't work; a bar over the tab says so after about 20 seconds (or,
if a startup dialog such as folder trust is still open, answer it first), with **Show settings**
and **Dismiss**.

**Claude sessions.** **New session** (**+ New session** under the selected project, the project's
**…** menu, the **⌄** menu, ⇧⌘N or the palette) offers **Claude Code** beside pi when both are
installed (see [Everyday tasks](#everyday-tasks)); with only Claude Code installed it starts Claude
Code at once. It runs on its own in the project's folder: a session whose main tab is Claude,
with no pi tab. You can open shell, browser and other tabs beside it as in any session. Its main
tab closes with the session (the **×** on its row). **New chat** does the same in Chats
(read-only while **Chats: read-only** is on: see [Chats settings](#chats-settings-the-gear)).

Every Claude conversation Deckhand ran in a project is a row of that project's session list,
beside the pi sessions, marked **Claude**: its title is your first message (or the name you gave
it with **Rename…** in the row's menu; Claude Code shows that name too the next time the session
starts), its time is when you last used it, and its dot shows Claude's status while it is open
(also the softer question dot when Claude's last answer asked you something, and the error dot
when its turn ended on an error such as a rate limit). Its **ⓘ** and menu have **Copy session
info**, **Send to Atlas**, **Reveal in Finder** and **Copy path** (Claude Code's transcript file
for it), as a pi row's; the info also names its model. Hover a Claude tab to see its model. **Pin**,
**Hide**, the filter, the **Running**, **Waiting** and **Pinned** chips and **Sort sessions by
attention** treat these rows like pi's (sorting by **created** uses their last use: Deckhand does
not know when Claude Code made them). Click a closed one to resume it (`claude --resume`, with
the extra flags it first ran with) in a Claude session; click an open one to go to it (also when
it runs as a tab of a pi session). The list comes from Deckhand's own record of the last 100
Claude sessions it ran, plus the Claude conversations you ran outside Deckhand (below).

**Every row shows its agent:** pi's logo for pi, Clawd (Claude Code's little orange mascot) for Claude Code, also on
the tabs and in the **New session** picker.
With more than one Claude account, Claude rows and tabs also show the account's name.

**Claude sessions you ran outside Deckhand** (in a terminal, an IDE) are rows too: Deckhand lists
the transcripts in each account's `projects/` folder for the selected project and for Chats,
newest first, and merges them with its own record (one row per conversation). Their title is
your first message (or the name you or Claude Code gave the conversation), read from the start
and end of the file only; nothing else of the transcript is read or shown, and agents never get
its path. Subagent and side-chain files are never rows. Click one to resume it in a Claude
session under its account. Folders where only Claude Code ran (by the folder each transcript
records) show up as projects. A row whose transcript is gone is greyed and reads **transcript
gone**. **Rescan sessions** looks again.

#### Claude accounts

An **account** in Deckhand is a Claude Code **config folder**: what `CLAUDE_CONFIG_DIR` names (its
sign-in, settings and transcripts). Sign-ins from your environment (an API key, `apiKeyHelper`,
Bedrock, Vertex) need no folder and keep working as before; Deckhand never stores a secret.

- **The default** is what plain `claude` uses in your shell: `CLAUDE_CONFIG_DIR` from your login
  shell when it is set, else `~/.claude`. It is always there and cannot be removed.
- Deckhand **finds** others by looking (no file is read) for Claude Code's account file in
  `~/.claude*` folders and in `~/.config/claude*` (or `$XDG_CONFIG_HOME/claude*`).
- **Add account…** (Settings tab → **Claude accounts**, or the palette: **Add Claude account…**)
  adds any folder, with a folder picker; not your home folder, nor one that holds a project,
  the main folder or the chats folder (Deckhand keeps an account's folder out of the editor and
  Files).

With one account nothing changes: no names on rows. With several, **New session**'s picker lists
**Claude Code · Name** once per account (the project's last account first, else your default,
else the last one used), the menus list one **New Claude tab · Name** row per account, and every
Claude tab starts with its account's folder (`CLAUDE_CONFIG_DIR`, set again after your login
profile ran; the default gets nothing). In the Settings tab, **Claude accounts** lists each one
with **Rename…**, **✓** (make it the default), **×** (remove it from Deckhand's list; its folder
is untouched), then **Add account…** and **Scan again** (look for folders again; with one
account there is only a quiet **More accounts…** row); each account
also has its own **Claude Code · Name (global)** group of settings files. Agents may start Claude
under an account you configured, never a folder of their own.

**New Claude tab** opens a Claude tab in the session on screen instead (a pi session's, or a
Claude session's, or a chat's: read-only while chats are); the project's **…** menu has it too (in the project's open session, or a new
pi session when none is open). When you quit with Claude sessions or tabs open, they come back on
the next start like other sessions and tabs, resuming their conversation with the same extra
flags. They start when you show them: if Atlas opens such a session first, its Claude tabs
wait ("not started") until you do, so your flags never run for an agent.

**Skipping permission prompts by default.** If you want your own Claude tabs to start with
`--dangerously-skip-permissions`, turn it on in the Settings tab (⌘,): the **Claude Code
(global)** group shows **Default flags for new tabs**, and its **Skip permissions** row has
**Turn on** / **Turn off** (or use the palette's **Claude Code: skip permissions in new tabs**). It is off until you turn it on. With
it, Claude edits files and runs commands without asking you first, so turn it on only if you
trust what you run it on; Deckhand asks you to confirm when you turn it on. It applies each time
you start Claude yourself: a new Claude tab, session or chat, your own resume, a restored tab when
you show it, and your Restart. It is never stored with a tab, so once you turn it off, none of
those get it any more. Tabs and sessions that Atlas, a pi tab, a Claude tab or an app opens or
restarts never get it. A read-only chat leaves it out and tells you so.

**Without Claude Code.** Deckhand works the same without it: **New session** and **New chat**
start pi at once (no picker), and the Claude-only menu rows (**New Claude tab**) are not shown.
The palette's and the menu bar's **New Claude tab** read "… — Claude Code not installed", and
running it shows how to install it (`curl -fsSL https://claude.ai/install.sh | bash`, or `brew
install --cask claude-code`) instead of opening a tab. For other ways, such as npm or an install your organization manages, see Claude Code's
setup page, [code.claude.com/docs/en/setup](https://code.claude.com/docs/en/setup). Your Claude rows stay listed. Deckhand looks for `claude` on your login shell's PATH and in
`~/.local/bin` and `~/.claude/local` (it never runs it to find out). After installing, click the
button again, or use **Refresh shell environment** (the palette), or restart Deckhand. A Claude
session or tab saved while Claude Code was installed and restored without it does not start: its
tab says why. If `claude` is installed but cannot start, the tab says so and how to fix it.

**Without pi.** Deckhand works with Claude Code alone. It looks for `pi` on your login shell's
PATH and in pi's managed install (`$PI_CODING_AGENT_DIR/bin`, `~/.pi/agent/bin`), never running
it; when neither has it, it asks your login shell (`command -v pi`, as a pi tab's shell would find
it: nvm, fnm, mise or pnpm set up in `~/.zprofile`), and until that answers, pi counts as
installed. Without pi, **New session**, **New chat** and `deckhand DIR` start Claude Code at once (no picker), Atlas's
button is not shown and ⌘J says that Atlas needs pi, and a job's run fails with "Jobs run pi,
which was not found…" (Atlas and jobs run on pi for now). The Settings tab, the palette and the gear
show no pi rows (pi's files, Ask Atlas…, Reload all pi tabs). With neither pi nor Claude Code,
**New session** says how to install either. After installing, use **Refresh shell
environment** or restart Deckhand.

**When Claude exits**, its tab stays with its last output and a bar: "Claude exited (code 1)" and
**Restart**, which starts Claude again in the same tab and goes on with the same conversation
(`claude --resume`), with your extra flags. Clicking its session's row, or the bell's entry about
it, restarts it too. If Claude Code is not installed (or not on your login PATH) the bar says so;
**Restart** looks again and, if it is still missing, tells you how to install it instead of
starting it. Nothing else in Deckhand needs Claude Code.

**Restart with model…** shows too when Claude ended with an error (as for pi): Claude starts
again on the same conversation, and once it is ready for a message (its turn idle, nothing typed)
Deckhand types `/model` for you, which opens Claude Code's own model picker: you pick from the
models Claude Code offers you. If Claude is not ready within 30 seconds, a note tells you to type
`/model` yourself.

**After you change Claude's settings, or Claude Code updates,** a bar offers to restart the
running Claude tabs that need it: see [Hot reload](#claude-tabs-claude-code-settings-and-updates).

**Messages from Atlas and scripts never land in what you are typing.** Text Deckhand sends to a
Claude tab (`claude_prompt`) waits until Claude has finished its turn and you have typed nothing
since your last message; a bar over the tab says so: "1 message from Atlas waits: you are typing
a message", the start of the text, **Drop** and **Send now** (it goes into the prompt as is, once
Claude has finished its turn; not while it is starting or asking you something: answer Claude
first). Text starting with `!`, `/`, `#` or `&` is never sent this way: Claude Code would run it
as a command. When an agent resumes a Claude session, your extra flags are not used; only your
own Resume brings them back. The palette has the
same: **Claude: send the waiting message now** and **Claude: drop the waiting messages**.

Closing a Claude tab asks first unless Claude is idle with nothing waiting. Its access to Deckhand
ends when it closes or exits.

### Comments for the agent

You can point at part of a tab and write a note for the session's agent; the note waits and goes
to that tab's session's pi or Claude tab **with your next message**: your text, what you picked,
and a cropped picture of it.
Today: **an app tab's Inspect boxes**: with **Inspect** on, click a box; a bar "Comment on box
“coin”:" takes your text (**Add** or Enter; **Cancel** or Esc). The picker for browser pages is on
its way and feeds the same path.

- **The strip.** While the session on screen has comments, a strip shows above its pi tab (and
  its browser and app tabs): "2 comments will go with your next message", with **View**, **Send
  now** and **Clear**. Type your next message in pi as usual: the comments go with it, after your
  text, and the strip goes away once pi has them.
- **View** opens the list: each comment with **Edit** (change its text; **Save** or Enter,
  **Cancel** or Esc) and **Delete**. **Clear** removes them all; nothing is sent.
- **Send now** sends them on their own, as a message "Here are my comments:". It is disabled, and
  the strip says why, while the session's pi is not running, Deckhand's bridge is not connected
  to it, or a pi dialog is open; the comments wait meanwhile and go once pi is back.
- **Claude tabs.** The session's comments go with your next message to whichever agent gets it
  first: its pi, or a Claude tab of the session (as context of that message, the pictures as
  files Claude reads). The strip shows on Claude tabs too. On a Claude tab, **Send now** sends
  them to that Claude: it types "Here are my comments." and the comments go with that message, as
they would with one you type (the pictures as files Claude reads); it waits
  until Claude has finished its turn, is not asking you something, and you have nothing typed in
  its prompt (the button's tooltip says why it cannot go yet). Anywhere else it goes to pi.
- Comments always go to **their own tab's session**, even when you look at another session. A
  session keeps at most 20; at most 8 pictures go with one message (the rest go as text and say
  so). They are not kept when you quit Deckhand.
- **Closing** a tab that has comments asks first: **Send and close**, **Drop and close** or
  **Cancel**. In a Claude session (no pi), Send and close goes to its Claude tab, with all of the
  session's comments. Closing a session with comments asks too: **Send now** (the session stays open:
  closing it stops its pi), **Drop and close** or **Cancel**.
- pi is told that each "Comment:" line is what you wrote, and that page titles, addresses and the
  pictures come from web pages and apps and are data, not instructions.
- Agents see the comments in the state snapshot (`comments` on each open session, with
  `comments_wait` saying why they wait) and can use `comment_edit`, `comment_delete`,
  `comments_clear` and `comments_send_now`; closing a tab with comments needs `comments: "send"`
  or `"drop"` from them. `comments_ask_cancel` is the close prompt's Cancel (yours only).

## The terminal

pi and shells run in a real terminal (Ghostty's terminal engine), so pi looks as it does anywhere
else.

- **To select text**, drag; the selection shows as you drag. Double-click selects a word,
  triple-click a line; keep dragging to extend by words or lines. Drag past the top or bottom
  edge to scroll back while selecting. **Shift+click** extends the selection; a click clears it.
- When the program uses the mouse (pi does), drags go to it: pi selects in its own view as you
  drag. Hold **Shift** while dragging to select in the terminal instead.
- **To copy**, press ⌘C. **To paste**, press ⌘V.
- **To scroll**, use the wheel or trackpad (pi handles its own scrolling).
- **To make the text bigger or smaller**, press ⌘+ or ⌘− (⌘0: back to the look's size), or use
  the View menu. It sets the terminals' and the editor's text size and is remembered.
- **To paste a file's path**, drag its row from the Files tab onto the terminal.
- **Links**: hold **⌘** over a link to underline it and see where it goes (at the bottom of the
  terminal); **⌘-click** opens it. A web link opens in a new browser tab of the session, in
  front (in your default browser when Deckhand has no browser, and from Atlas's terminal);
  **⇧⌘-click** always uses your default browser; a mail link opens your mail app. Right-click
  a link for **Open link**, **Open in default browser** and **Copy link**. Both hyperlinks
  (OSC 8, a program's link whose text may differ from its address) and web addresses in the
  text work, also when they wrap onto the next row. Only http, https and mailto links open:
  file, javascript and other kinds from a program's output never do.
- **Editing keys** work as in Ghostty, in pi and in shells (zsh, bash): ⌘⌫ deletes to the start
  of the line, ⌥⌫ deletes a word back, ⌥⌦ (fn+⌥⌫) a word forward; ⌘← and ⌘→ go to the start
  and end of the line, ⌥← and ⌥→ move by word.
- The Option key acts as Alt (pi's Alt+Enter works), so Option+letter sends Alt+letter rather
  than a special character.

## Editor tabs

Deckhand has a small code editor with syntax highlighting.

- **To open a file**, click it in the Files tab (a single click opens a *preview* tab that the
  next click replaces; double-click, Enter or editing keeps it), or press ⌘P and type part of its
  name. A double-click on a preview tab keeps it too.
- **To save**, press ⌘S or click **Save** in the editor's toolbar. Saving is atomic (a temp file,
  then a rename).
- **Find** ⌘F, **Find and replace** ⌥⌘F, next match ⌘G (⇧⌘G back), **Go to line** ⌘L (or ⌃G). Undo ⌘Z,
  redo ⇧⌘Z, toggle comment ⌘/, indent ⌘] and outdent ⌘[. The toolbar's **Wrap** toggles soft wrap.
  Right-click for Cut, Copy, Paste and more.
- **To diff a file with git HEAD**, click **Diff** in the toolbar (or right-click → Diff with
  HEAD, or the palette's "Diff with HEAD"). It opens a read-only diff tab.
- **When the file changes on disk**: a file without unsaved changes reloads by itself. With
  unsaved changes, a bar says "*file* changed on disk. You have unsaved changes." with
  **Compare** (a diff with the disk), **Keep mine** (your next save overwrites the file) and
  **Reload** (take the disk's version; one undo step). A file deleted on disk shows "Deleted on
  disk: ⌘S saves it again".
- Deckhand does not open binary files, files over 20 MB, or **credential files**: pi's sign-ins
  (`auth.json` and similar), other private files in pi's folder, and `.env` files. They show
  "Credentials file: managed by pi (/login), not opened".

## Markdown tabs

A Markdown tab shows a `.md` file as a document: headings, lists, task lists, tables, quotes,
links and code blocks coloured like the editor's. This guide opens in one (Help ▸ Deckhand user
guide).

- **To open one**, right-click a `.md` file in the Files tab → **Open Markdown preview**, click
  **Preview** in an editor tab of a `.md` file, or press ⇧⌘V there (View ▸ Markdown preview). An
  agent can also show you one ([Files an agent shows you](#files-an-agent-shows-you)).
- **Toolbar**: **Source**/**Preview** switches between the document and its text (⇧⌘V; it keeps
  your place), **Find** (⌘F; ⌘G next match), **Open in editor** (to edit the file) and **Reveal**.
  The source view is read-only and also has **Go to line** and **Wrap**.
- **Links**: a click follows a link (⌃-click does not). A web link opens in your browser (when an
  agent asks to open one, Deckhand asks you first); a link to another `.md` file opens it in a
  Markdown tab; a link to `#a-heading` scrolls there; other files open in the editor.
- **Live reload**: when the file changes on disk (you save it in the editor, or pi edits it),
  the tab shows the new version. If the file is deleted, or becomes something Deckhand cannot
  show, the tab keeps the last version and says so at the bottom.
- **Images** show as their alt text; Deckhand never fetches anything from the network.
  **Diagrams** (```` ```mermaid ```` blocks) show as code, labelled "diagram (coming soon)".

## The Files tab

**⌘⇧E** (or the Files tab at the top of the left column) shows the file tree of the session on
screen, else of the selected project. Press ⌘⇧E again to go back to Sessions.

- **Git status** colours rows and adds a letter: green **A** (added) and **U** (untracked),
  amber **M** (modified), **R** (renamed) and **•** (a folder with changes inside), red **D**
  (deleted) and **!** (conflict). Gitignored files are left out; `.git` never shows.
- **Mouse**: a click opens a folder or previews a file; drag a row onto a terminal to paste its
  path.
- **Keyboard** (while the tree has focus): ↑/↓ move, ←/→ close or open (or go to the parent or
  child), Enter opens, Space previews, F2 renames, ⌘⌫ moves to the Trash (it asks first), Esc
  gives the keyboard back.
- **Header buttons**: New file, New folder, Collapse all, Refresh, Reveal in Finder.
- **Row menu** (**…** or right-click): Open, Open in preview, New file…, New folder…, Rename…,
  Move to Trash…, Reveal in Finder, Copy path, Copy relative path, Open terminal here, and for
  `.md` files Open Markdown preview.
- **Filter**: type in the field above the tree to match paths loosely.
- **Folders inside folders**: a folder that is a project of its own (or a session's worktree)
  opens in the tree it sits in like any other folder, and so does a symlinked folder (in place,
  wherever it points).
- **A folder that cannot be opened** shows a red line under it saying why, with **Retry**. "macOS
  needs permission" means macOS privacy protects it (Desktop, Documents, Downloads, iCloud Drive,
  removable and network volumes): allow Deckhand in **System Settings › Privacy & Security ›
  Files and Folders** (or **Full Disk Access**), then click **Retry**. A build signed ad hoc (one
  you built yourself) is a new app to macOS after each update or rebuild, so it may ask again.

### Worktrees

Under the project's name, the **checkout switcher** says which checkout the tree shows ("main
checkout · main", "worktree · feature"). Click it to see the repository's **Worktrees** (main
first) and its **Branches without a worktree**, each with its state:

| Badge | Meaning |
|---|---|
| ↑2 ↓1 | commits ahead of / behind its upstream (or the default branch) |
| ● 3 | 3 changed files |
| ✓ merged | merged into the default branch |
| ⚠ missing, ⚠ prunable | the worktree's folder is gone |
| locked | git-locked |

- **To show another checkout in the tree**, click it. Deckhand remembers the choice per project.
- **Row actions** (**…**, or → / Space on the keyboard): Open terminal here, **New session
  here** (pi or Claude Code, as **New session** offers them; kept with the project's sessions),
  Show changes, Reveal in Finder, Copy path, Copy branch name.
- **Clean up…** appears for a worktree that is clean and merged. It runs `git worktree remove`
  (never forced) and `git branch -d`, after you confirm. It never touches the main checkout,
  and refuses while an ignored file in it looks like a secret.

Branches are only listed; Deckhand never checks them out.

## The Changes tab

What a session changed in its git checkout, and what to do about it.

- **To open it**, click **±** in the top bar (it shows how many files changed; it hides when the
  top bar has no room), run **Show changes** from the palette, or pick **Show changes** in a
  worktree row's menu in the Files tab (that worktree's changes). One Changes tab per session
  and checkout; opening it again focuses it.
- **On the left**, the changed files, grouped:
  - **Uncommitted**: staged, unstaged and untracked files, by status: **M** modified, **A**
    added, **D** deleted, **R** renamed, **U** conflict, **?** untracked. A green dot means
    staged, an amber one partly staged.
  - **On *branch*, not on *main***: the files changed by the branch's own commits, against the
    point where it left the default branch (origin's HEAD, else `main` or `master`).
  - Each row shows **+added −removed** lines (**bin** for a binary file).
- **On the right**, the selected file's diff (added lines green, removed red). Scroll, select
  and copy (⌘C) as in an editor tab, ⌘F finds. Long diffs stop at 5,000 lines: **Show more**
  adds 5,000. Binary files and credentials files (`.env`, keys, pi's sign-ins) are listed but
  never shown.
- **Moving between files**: **J** / **K** or **↓** / **↑**, or the **↑** **↓** buttons above the
  diff.
- **Buttons above the diff**: **Open** opens the file in an editor tab at the hunk you clicked
  in; **Stage** (`git add`) and **Unstage**; **Discard…** puts the file back as it was in the last
  commit, after you confirm. A file git does not have (untracked or newly added) goes to the
  Trash, and asks a second time first; an untracked folder goes with everything in it. Discard
  refuses a nested git repository, and a deleted file whose name is back in the work tree (it
  would overwrite that file).
- **Commit**: type a message in the field at the top and press Enter or click **Commit**. It
  commits what is staged. **Your git hooks run** (pre-commit, commit-msg, signing), as in your
  terminal: it runs through your login shell, so tools on your shell's PATH are found. If a hook
  refuses, the tab shows git's message and nothing is committed. A commit that runs past two
  minutes is stopped with its hooks; if git leaves `index.lock` behind the tab says so, and Deckhand
  never removes it.
- **Ask pi to review** sends this session's pi a prompt to review the uncommitted changes and
  the branch's commits. In a Claude session it reads **Ask Claude to review** and goes to its
  Claude tab once Claude is idle and you are not typing there.
- **Refresh** reads the changes again. The tab also refreshes by itself when files change
  (after a short pause) and when you switch to it; "Refreshing…" shows only if it takes a moment.
- **Merge into main…** is shown but not active yet: merging is coming later.

Deckhand's own git reads never run your repository's hooks; only Commit does. Reading the changes
does run the repository's configured clean filters (for example git-lfs) on changed files, as
`git status` does in a terminal.

## The Settings tab

**⌘,** (or the gear's **Edit settings files…**) shows your agents' settings as files, in groups.
Its title names the one you have installed ("pi settings", "Claude Code settings"), or reads
**Settings** with both. pi's groups (pi, this project's `.pi/`, extensions, Atlas) show only when
pi is installed; Claude Code's once it has been used:

- **pi (global)**: `settings.json` (model, theme, packages…), `models.json` (may hold API keys),
  `modes.json`, `keybindings.json`, `mcp.json`, your global instructions file (`AGENTS.md` or
  similar), `SYSTEM.md`, `APPEND_SYSTEM.md`, and the folders `prompts`, `skills` and
  `extensions`. Only these: never sessions, logs or sign-ins.
- **pi extensions (Deckhand's)**: extra pi extensions that ship with Deckhand, one row each with
  what it does, whether it is on, its default and **Turn on** / **Turn off**. They apply to pi
  tabs (not jobs). Only you can change them (Atlas and other agents can't). A change applies when
  a pi tab next starts; running tabs
  get the restart bar ("pi extensions changed — Restart N idle tabs"). Updating Deckhand
  updates them.
  - **guardrails** (on by default): your ask/block rules on shell commands (pi-kit's config
    files: `~/.pi/agent/extensions/guardrails/config.json`, a project's `.pi/guardrails.json`;
    with no rules nothing asks), read-only chats enforced, secret-looking strings redacted
    from tool output, file reads included: the agent sees `[REDACTED]` where a key or token is.
    So that a file it read is never saved with the marker in place of the real value, a write
    or edit carrying `[REDACTED]` is refused once something was redacted in that session.
    `/guardrails` lists the rules.
  - **shell** (on by default): background shells, monitors and timers for the agent
    (`bash_bg`, `monitor`, `wake_later`, `shell_stop`, `shell_list`, `/shells`), shown in a
    **Shells** panel. A reload or restart waits until they end.
  - **notes** (off by default): reminds the session to update its session note before pi
    compacts its context, naming your notes folder (`PI_KIT_NOTES_DIR`, see
    [Your folders](#your-folders)). Useful only if you keep session notes.

  With pi-kit installed too (or any pi extension with the same tool names), Deckhand's copy
  steps back where both would act: pi-kit's guardrails, notes and shell run instead of
  Deckhand's, a notice in the tab says so once, and `/guardrails` and `/shells` are pi-kit's.
  The Shells panel then shows pi-kit's shell. Your pi tab starts either way.
- **This project** (the session on screen's project): its `.pi/` folder and instructions file.
  A missing `.pi/settings.json` or `AGENTS.md` is dimmed with a **Create** button.
- **Extensions**: each extension's config file and folder, when it has one.
- **Atlas**: its prompt file `ATLAS.md`, `HEARTBEAT.md` when there is one, and its **Model**
  (with **Change…**).
- **Atlas's jobs**: every job note in the jobs folder (see [Jobs](#jobs)).
- **Chats**: **Chat instructions (AGENTS.md)**, the chats folder's instructions (with
  **Create** when missing).
- **Folders**: the main folder and each of its subfolders (see [Your folders](#your-folders)).
- **Claude Code (global)** (once Claude Code has a config folder, `~/.claude` or your
  `CLAUDE_CONFIG_DIR`): `settings.json`, `CLAUDE.md`, `keybindings.json`, and the folders
  `agents`, `skills`, `commands`, `output-styles`, `rules`. With Claude Code installed, also
  **Default flags for new tabs**, **Skip permissions** (**Turn on** / **Turn off** for
  `--dangerously-skip-permissions`) and a warning line (see [Claude Code tabs](#claude-code-tabs)).
- **Claude Code · project**: the project's `.claude/settings.json` (**Create** when missing),
  `.claude/settings.local.json`, `CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` (may hold tokens).
  A file pi reads too (a `CLAUDE.md` that is the project's instructions file) shows once.
- **Coding agents** (last): the [first run](#the-first-run)'s checklist as rows: each harness
  (its version and how it was installed, or **Not installed**) and, once installed, Deckhand's
  integration (**Built in**) and the recommended items. **Install…**, **Update…** and **Show…**
  open the setup sheet's coding agents step, where the command shows and runs. **Refresh** looks
  again.

Click a file to open it in an editor tab. Press ⌘, again to go back to Sessions.

- **Credential files never show** here, also not inside an opened folder, and the editor refuses
  them. For Claude Code that is everything of its own but its config: its sign-in
  (`.credentials.json`), its account and MCP state (`~/.claude.json` and its backups), and
  conversations, history, sessions and caches in its folder (`projects/`, `history.jsonl`…).
  That holds for `~/.claude` and `CLAUDE_CONFIG_DIR` both, and for any other folder that holds a
  Claude sign-in or account file (another profile). A relative `CLAUDE_CONFIG_DIR` is ignored.
- **JSON safety**: a JSON settings file that pi reads is saved only when it is valid JSON. If
  not, the save is refused and the error names the line and column.
- **The reload bar**: pi reads its settings when it starts or reloads. After you save one, the
  [hot-reload bar](#hot-reload) shows at once and offers **Reload** for the running pi tabs that
  read it (after saving `ATLAS.md`, only Atlas). Claude Code applies its `settings.json` files and
  `keybindings.json` by itself; after saving a Claude file it reads only at start (`CLAUDE.md`,
  `.mcp.json`…), the Claude bar shows at once.
- **Folders**: see [Your folders](#your-folders).

## Hot reload

pi reads its settings, extensions, skills, prompts, themes and instructions files (`AGENTS.md`,
`CLAUDE.md`) when it starts or on `/reload`. Deckhand watches those files while a pi tab runs and
tells you when a running pi has an old copy.

**The bar.** About a second after a change, a bar over the centre says, for example, "pi settings
changed — Reload 2 idle tabs · 1 busy when idle". Its buttons:

- **Reload**: idle pi tabs reload now (`/reload`; the session stays). A tab that is working,
  waiting for you, or running background shells or subagents reloads by itself once it is idle.
  Only when background work is involved does Deckhand ask first, and it names that work ("shell
  sh1: npm test"): a reload would stop it, so those tabs wait until it ends.
- **Details**: which files changed and what each pi tab is doing (idle, working, waits for a
  shell, reloaded, failed).
- **Later**: hides the bar until the next change, and cancels reloads still waiting for idle.

What counts: pi's agent folder (`~/.pi/agent`: `settings.json`, `keybindings.json`,
`models.json`, `mcp.json`, instructions and system-prompt files, the `extensions`, `skills`,
`prompts` and `themes` folders), local packages listed in `settings.json` (such as a pi-kit
checkout), each project's `.pi/` folder, and the instructions files in a tab's folder and the
folders above it. A change reaches only the tabs that read it: a project's `.pi/` its own
sessions, `ATLAS.md` only Atlas. Tabs whose pi integration did not connect (a pi older than
1.4.0) cannot be reloaded from Deckhand; the bar says so: type `/reload` in them.

**Reload all pi tabs** (the gear, or ⌘K) reloads every running pi tab the same way, changed or
not.

**After a pi update.** Deckhand notes which pi version each tab started with. When pi on disk is
updated (for example `npm install -g` or `brew upgrade`), a bar says "pi updated to 1.5.0 —
Restart 2 idle tabs". **Restart** starts each idle tab's pi again on the same session; busy tabs
restart once idle, with the same warning about background work. **Later** hides it until the
next version. The same bar says "pi extensions changed" after you turn one of
[Deckhand's pi extensions](#the-settings-tab) on or off. Before stopping a tab, Deckhand asks its
pi once more whether it is idle; if not, the tab waits. Atlas is a pi tab like the others: it is reloaded or restarted when idle, its
session stays.

Not counted as changes: `node_modules` and `.git` folders, and the keys pi writes into
`settings.json` itself (the model and thinking level you last picked, the changelog it showed,
its device id).

### Claude tabs: Claude Code settings and updates

Claude Code applies most of its settings to a running session by itself: its `settings.json`
files (permissions, hooks, env…), `keybindings.json`, skills and subagents. Deckhand leaves those
alone. What a running Claude reads only when it starts: the `CLAUDE.md` and `CLAUDE.local.md`
files (yours in `~/.claude`, the project's and the folders above it), rules, output styles and
commands (`~/.claude/rules`, `output-styles`, `commands`, and the project's `.claude/` ones), the
project's `.mcp.json`, a new `agents` or `skills` folder, and Deckhand's own Claude plugin.

When one of those changes, a bar says "Claude Code settings changed — Restart 1 idle Claude tab".
**Restart** starts each idle Claude tab again on the same conversation (`claude --resume`, with
your extra flags); Deckhand asks first, because anything Claude runs in the background there
(background shells, monitors) stops. A tab that is working, waiting for you, has something typed
or a subagent running restarts once it is idle. **Details** lists the files and each Claude
tab; **Later** hides the bar until the next change.

**After a Claude Code update.** Deckhand notes which Claude Code each Claude tab started with, by
looking at where `claude` points (it never runs it). When Claude Code updates itself, a bar says
"Claude Code updated to 2.1.301 — Restart 1 idle Claude tab", with the same **Restart** and
**Later**.

**Restart all Claude tabs** (the gear, or ⌘K) restarts every running Claude tab the same way,
changed or not; Deckhand asks first. The palette also has the bars' two restarts (**Restart Claude
tabs for changed settings**, **Restart Claude tabs on the new Claude Code**) and **Edit Claude
settings (settings.json)**, **Edit global CLAUDE.md** and **Edit project Claude settings** (`.claude/settings.json`),
which open those files from the Settings tab. Deckhand only looks at file names and times here; it never reads Claude's credentials,
account file or conversations.

## Atlas

Atlas is Deckhand's built-in assistant: its own pi (Atlas needs pi installed; without it, its
button is hidden and ⌘J says so), running in the drawer, that can see and drive
Deckhand for you ("open the api project's last session", "which sessions are waiting?", "tell me
when the build session finishes").

- **To open or hide the drawer**, press ⌘J, or click Atlas at the far right of the top bar. If
  the drawer is open but the keyboard is elsewhere, ⌘J gives it the keyboard first. ⌘W hides it
  too. Clicking in the centre hides a sliding drawer.
- **To pin it** as its own column, click 📌 in its header (the palette: "Dock the agent's
  drawer"). Click again to slide it over the right side again.
- **To resize it**, drag its left edge; double-click the edge to reset.
- **The header** shows its status (starting…, working…, needs you, error, stopped) and its model.
- The top bar's Atlas button counts the runs that finished while the drawer was shut, and is
  tinted while Atlas waits for you. While Deckhand is in the background, Atlas finishing or
  asking raises a macOS notification (gear: **Agent notifications**).
- **Where it works**: Atlas starts in your [main folder](#your-folders), or in the data dir's
  `home/` while no main folder is set or it cannot be reached; never in your home folder (`~`),
  even if you made `~` the main folder.
  Atlas runs as part of Deckhand, so macOS counts every file it opens as Deckhand's: from `~`,
  an ordinary `ls`, `find .` or `grep -r` would walk into Desktop, Documents and Downloads and
  ask "Deckhand would like to access…". It reaches your projects by their full paths. A new
  main folder applies from Atlas's next start. A main folder inside Documents or Desktop still
  gets that prompt once, for that folder.
- **Its conversation moves with it.** pi records the folder a conversation runs in and resumes
  it there. So when Atlas's conversation was recorded in another folder (`~`, where
  Atlas used to start, or your previous main folder), Atlas's next start
  copies it once into a new conversation in the new folder (pi's `--fork`), with all its
  history. The old session file in the data dir's `home/` is left as it was, as a backup.
  Atlas resumes as before, in the old folder, with a pi older than 1.4.0, a session file
  whose first line cannot be read, or while the main folder is set but cannot be reached
  (an unplugged drive: no copy each time it comes and goes). If pi fails to make the copy,
  Atlas's terminal says so and its next start resumes the old conversation where it was.

### Its model

Click **Model** in the drawer's header (or the gear's **Atlas model…**, the palette's "Atlas:
change model", or Settings → Atlas → **Change…**). It opens pi's own model selector (Ctrl+L) in
Atlas's terminal. Your pick stays with Atlas's session.

The `agent_model` setting ("provider/id", optionally ":thinking") is the model Atlas starts a
new session with; when it changes, Atlas uses it from its next start.

### Its prompt

- **ATLAS.md** is added to pi's system prompt for Atlas only. It lives in the atlas folder
  (`<main folder>/atlas/ATLAS.md`) once the main folder is set (Deckhand copies the data dir's
  `atlas/ATLAS.md` there the first time, never over a file, and keeps the old one as a
  fallback); without a main folder, the data dir's copy is used and the drawer says so in a
  line with **Set up Deckhand…**. Edit it in Settings → Atlas, or with the palette's "Atlas: edit prompt". Save, then
  click **Reload** in the [hot-reload bar](#hot-reload) ("Atlas's prompt changed").
- Your global **APPEND_SYSTEM.md** (pi's folder) is still added for Atlas, before ATLAS.md, as
  pi would.
- Deckhand writes a starter ATLAS.md when there is none. When a Deckhand update ships a newer
  starter, Deckhand replaces your file only if you never edited it (it keeps the old one as
  `ATLAS.md.bak-<date>`). If you edited it, it is left alone. To get the newest starter
  anyway, rename your file in Finder (to keep it), click **Create** on ATLAS.md in Settings →
  Atlas, then **Reload** in the hot-reload bar.
- This guide is copied to `atlas/GUIDE.md` in the data dir on every start, and Atlas is told
  where it is, so it can answer "how do I…" questions.

### What Atlas can do

Atlas uses the **desk tools** of Deckhand's pi integration; each tool's description in pi lists exactly what it accepts.
In short, Atlas can:

- look at what is open (projects, sessions, tabs, panels, status);
- do what you can do in the window: open, start, focus and close sessions and tabs, open files,
  change the layout and the look;
- send a prompt to another session, and wait for it to finish, in a pi tab or a Claude tab (its
  message waits like any other: never into what you are typing);
- **watch** a session when you ask ("tell me when it finishes / needs me / exits"): it gets one
  message when that happens and tells you (`desk_watch`; at most 5 at a time);
- tell you **what happened while you were away**, from the bell's entries (`desk_events`);
- **show you a file** in a tab of a session it names (`desk_show`; see
  [Files an agent shows you](#files-an-agent-shows-you)).

What it cannot do:

- **Confirm for you.** Anything that needs confirmation (closing a running tab, quitting,
  reloading pi, deleting files) shows the confirmation bar, and by default only you can click
  Confirm.
- Change your own settings that limit it (its model, its name, notifications, confirmation
  rules), hide its own drawer, or act on its own session.
- See credentials: it never gets tokens, and Deckhand never shows sign-in files.
- Know about changes by itself. Deckhand never pushes status updates to Atlas; you see them in
  the bell. Atlas only hears about a session when you asked it to watch it.

### Restarting Atlas

- If Atlas is stuck mid-answer, press Esc in its terminal (as in any pi).
- To reload its prompt, settings and extensions, type `/reload` in its terminal, or save
  ATLAS.md and click **Reload** in the [hot-reload bar](#hot-reload).
- If it stopped ("Atlas stopped"), press ⌘J twice: the drawer closes and opens again, and Atlas
  starts again, resuming its session.

## Jobs

A job is a prompt that pi runs for you, on a schedule or when you click **Run now**, while
Deckhand is open: "every weekday at 7, list the pull requests waiting on me", "every hour, check
the build". Each run is a fresh, one-shot pi that cannot ask you anything; it finishes and
reports. There are no jobs until you make one. Jobs need pi installed: without it, a run fails
and says so.

### The Jobs tab

Click **Jobs** at the top of the left column (palette: "Show jobs"). Job notes live in the jobs
folder (`<main folder>/jobs/`); without a main folder the tab says so and offers **Set up
Deckhand…**. The header has **New job** (+, the [job sheet](#the-job-sheet)), **Pause all** /
**Resume all** and **Limits**, and the count of unread runs.

Jobs are grouped by **who they belong to**: each of your projects that has jobs (by name), then
**Atlas**, **Chats** and **Other**. A group's row shows its name and how many jobs it has (a dot
while one has an unread run). Click its chevron to fold it; click the row to go to the project
(its sessions in the Sessions tab), to Atlas (the drawer) or to Chats; on Other it folds. Hover it
for **+**: a new job for that group. Folding lasts until Deckhand quits.

A job belongs to:

1. what its note's `for_project:` says, when it says something: `atlas`, `chats`, `none`
   (Other), or a project, by its folder (`~/code/api`, what New job writes: it survives renames)
   or its name (its rename, the name the list shows, or its folder's name; two projects with that
   name match neither). A `for_project:` that names none of your projects is shown on the open
   row, and the folder decides instead;
2. else its `folder:`: the deepest of your projects that holds it (by whole folder names, as the
   project list nests rows; hidden projects are skipped, and your home folder or `/` only when the
   job runs exactly there), or Atlas's folder (`<main folder>/atlas`) or the chats folder;
3. else **Other**.

The group is only for showing: it never changes where or how a job runs (`folder:` does).

Each row shows a status dot, the job's name, its folder when that is not its group's, the next
run or the last result, and a dot while a run is unread. Click a row to open it: its warnings,
what it needs from you, its last runs (skipped ones too, with why), and buttons: **Run now**,
**Stop**, **Edit**, **Open note**, **Last report** and **Mark read**. Its **…** menu (or a right
click) also has **Pause** / **Resume**, **Enable** / **Disable**, **Edit…**, **Open last
report**, **Open run folder** and **Delete…**.

### The job sheet

**New job** (and **Edit** on a job) opens a form over the window. The note stays the job's
definition: the form only writes it.

- **Name**; **Project** (your projects, then Atlas, Chats and None: it sets both `folder:` and
  `for_project:`); **Schedule**: Manual, Hourly, Every N hours, Daily or Weekdays at a time, or
  Custom (a cron line, `every 30m`, `at 2026-11-03 09:00`), with the next run (or what is
  wrong) under it as you type; **Prompt**; **Access** (read or full); **Notify** (always,
  attention, never); **Advanced** (folded): model, hours, max cost, timeout, max turns.
- On the right, the note the form will write, as you type (a narrow window: **Form** / **Note**
  at the top).
- **Edit as note** turns the sheet into the note's text (for Edit job: the whole note, its
  `## Recent runs` too) to edit by hand; **Back to form** reads it into the form again, and stays
  on the text while it cannot.
- **Create** writes the job's note (`enabled: true`); **Save** rewrites only the settings the
  form shows, the title and the `## Prompt` section (other settings, `## Check` and
  `## Recent runs` stay; a `summary:` of its own stays too, one that was the title follows the
  name). When a run or another editor changed the note while the sheet was open, Save is refused:
  the sheet keeps what you typed and says so, and **Reload** reads the note again (after asking
  "Discard your changes and load the new version?" when you changed something). Both say what is wrong
  instead when the note would not be a valid job. **Cancel** (Esc) changes nothing; after a
  change it asks "Discard your changes?" first (Cancel or Esc again discards). ⌘↩ is Create or
  Save; Tab moves between the fields. While the sheet is open it keeps the keyboard: the app's
  shortcuts, the menu bar's actions and dropped files wait until it closes, and Quit with
  changes in it asks "Discard your changes?" first.
- **Open note** still opens the note in an editor tab, to edit by hand.

### A job is a note

The [job sheet](#the-job-sheet)'s **Create** (and Atlas's `job_create`) writes a note in the
jobs folder (`<main folder>/jobs/`):

```markdown
---
id: 7f3a2c
enabled: true
schedule: "0 7 * * 1-5"      # cron, "every 2h", "at 2026-11-03 09:00" or "manual"
folder: ~/code/api            # where pi runs
access: read                  # read (look only) or full (pi's normal tools)
notify: always                # always, attention or never
for_project: ~/code/api       # who it belongs to (see The Jobs tab)
# optional: hours: "07-22", model: provider/id, max_cost: 0.50, timeout: 20m, max_turns: 40
---
# Morning PR triage

## Prompt
List the pull requests that wait on me, oldest first.
```

Edit it like any note (any editor works). Only these settings are allowed: a misspelled key is
an error on the row, and the job does not run. Below the prompt Deckhand keeps `## Recent runs`,
one line per run; do not edit that part.

### No approval step

Jobs need no approval: a job note runs on its schedule as it is written, whoever wrote it (you,
the job sheet, Atlas or another agent), and an edited note runs as edited. What stops a job:

- **Pause all** in the header stops every job, and only you can resume it (**Resume all**):
  Atlas and other agents can pause jobs but cannot undo a pause. **Pause** on one job works the
  same way for that job. Use these when you want jobs stopped until you say otherwise.
- **Disable** writes `enabled: false` in the job's note. It is per job and lasts only until
  something edits the note back to `enabled: true`, and anything that may edit notes can do that
  (Atlas, another agent).
- The [limits and safety stops](#limits-and-safety-stops).

Check new and changed jobs in the Jobs tab and the note itself.

Deckhand keeps nothing about jobs in your macOS Keychain. Older versions kept a "pi-desk jobs
approval key" there; it is no longer used, and you may delete it in Keychain Access.

### Running

- **Run now** runs it at once (also a paused or disabled job, when you click it). **Stop** ends
  a run (pi and everything it started).
- **Pause** / **Resume** one job, or **Pause all** / **Resume all** in the header (the palette:
  "Pause all jobs", "Resume all jobs", "Stop all running jobs"). Running runs finish.
- A run that was due while your Mac slept or Deckhand was closed runs late if it is only a little
  late (up to half the time between runs, 2 minutes to 2 hours); later than that it is skipped,
  not caught up, and its row says so ("skipped (asleep)" or "skipped (closed)"). A run still going when the next one is due: the next one is
  skipped.

### Limits and safety stops

**Limits** in the header: click a value to step through its choices. Off unless you set them:
cost, time and turns per run; spending per day, week and month (when reached, new runs are
skipped; a run already going finishes); runs at once. Always on (you can change the numbers,
not turn them off): the same tool call 5 times in a row stops a run (**looping**), 10 minutes
without a word from pi stops it (**stalled**), and 3 failures in a row pause the job and tell
you.

### Results

- Each run's report (the end of pi's answer: a `## Summary`, and `## Needs you` when something
  needs you) is one line in the row and the note, and in full under **Last report**.
- **The bell** gets every run's result (finished, needs you, failed); see [The bell](#the-bell).
- **macOS notifications** while Deckhand is in the background: runs that need you or failed come
  through the bell's notifications; a finished run raises one only with `notify: always`.
- A run's files live in Deckhand's data dir, `jobs/<id>/runs/<time>/` (**Open run folder**): its
  report `summary.md`, `meta.json`, pi's events and errors. Runs older than 30 days (or beyond
  the newest 100) are removed. Secrets that look like API keys are redacted from reports.
- Atlas does not get job results pushed to it; ask it ("what did my jobs report?") and it reads
  them.

### What a job may do

`access: read` runs pi with its read-only tools (read, grep, find, ls; no bash, MCP or extension
tools), as a read-only chat does (with the same limits: see [Chats settings](#chats-settings-the-gear)),
and pi-kit's read-only mode where pi-kit is installed. It needs pi 1.0.4 or newer: on an older pi
a read job fails with that message instead of starting. `access: full` runs pi with its normal tools and guardrails: an action the guardrails
would ask you about is blocked instead, and the run reports it under "Needs you". A job never
gets Deckhand's control socket, so it cannot create jobs through Deckhand (its prompt also tells
it not to create or edit jobs).

## The bell

The bell in the top bar collects what happened in sessions you were **not looking at**:

| Entry | When |
|---|---|
| Finished | pi went idle after working |
| Waiting for you | a pi dialog opened, or its answer ended with a question |
| Stopped with an error | pi's run ended with an error |
| pi exited | pi's process exited |
| Jobs | a job's run finished, needs you or failed ([Jobs](#jobs)) |

- The bell shows the unread count. Click it to see the entries, newest first, under Today and
  Earlier. Click an entry to go to that session (it reopens a closed one) and mark it read.
- **Mark all read** and **Clear** are in its header (also in the palette).
- Looking at a session marks its entries read. Entries from the same session within 10 seconds
  replace each other, so a flapping session does not flood the list. At most 200 entries are
  kept, and they are not saved: a restart empties the bell.
- **To choose what the bell collects**, use the gear's **Notify me about** chips: Finished,
  Waiting, Errors (errors and exits) and Jobs. Something you asked for that Deckhand could not do
  (Send to Atlas's text left on the clipboard, and why) always shows in the bell, even with Errors off.
- **macOS notifications** (gear: **Also notify in macOS**, on by default): while Deckhand is in the
  background, waiting, errors, exits and jobs that need you or failed also raise a notification
  (finished runs only go to the bell). Pacing: at most one per session every 10 seconds, and in a
  burst the first two, then one "N sessions need you" summary. A build run from the repo
  (no app bundle) bounces the Dock icon instead.

## The palette and the gear

### The palette (⌘K)

Press ⌘K (or click the search pill) and type: it searches actions, open tabs, sessions (the
selected project's and every open one) and projects, and remembers what you ran recently. ↑/↓ or
Tab move, Enter runs, ⌘1–⌘9 runs a numbered row, Esc closes. ⌘P opens it in file mode: the
current project's files. Every action in it runs exactly as its button does, confirmations
included. The full list is [below](#all-palette-actions).

### The gear: Quick settings

Click the gear in the top bar. Arrow keys move, Enter or Space runs, Esc closes.

- **Appearance**: System (follows macOS), Light or Dark.
- **Look**: Graphite, Warm or Ghostty (one swatch each). The terminals follow the look, so pi
  blends in.
- **Text size**: Small, Medium, Default or Large, for the sidebar, tabs, menus, popovers and
  panels (body and secondary text: 12/11, 13/11, 14/12, 15/13 pt). Terminals and the editor
  keep their size. It applies at once and is remembered.
- **Reduce motion**: no fades, slides or pulsing dots.
- **Agent notifications**: Atlas's macOS notifications.
- **Atlas model…**: see [Its model](#its-model).
- **Notify me about** and **Also notify in macOS**: see [The bell](#the-bell).
- **Chats: read-only**, **Chats folder…**: see [Chats settings](#chats-settings-the-gear).
- **Rescan sessions**, and, while such a tab runs, **Reload all pi tabs** and **Restart all Claude
  tabs** (see [Hot reload](#hot-reload)), **Refresh shell
  environment** (see [Where Deckhand's environment comes from](#troubleshooting): new tabs only),
  **Keyboard shortcuts** (⌘/) and **Edit settings files…** (⌘,).
- **Set up Deckhand…**: the [first run](#the-first-run) sheet again (coding agents, main folder, chats).
- **Check for updates automatically**: see [Updates](#updates). On by default.
- **Tidy project list**: hide temp and missing folders, nest subfolders and group sibling folders (see
  [A tidy project list](#a-tidy-project-list)). On by default.

## Updates

Deckhand checks for a newer release of itself a minute after it starts and then about once a day
while it runs. It asks GitHub for the latest published release of `McFalljb/deckhand` and sends
nothing about you (only `User-Agent: Deckhand/<version>`). Pre-releases and drafts are never
offered. If the check fails (offline, GitHub down) nothing shows; the attempt is in
`commands.log`.

**When a newer version exists**, a bar over the centre says "Deckhand 0.1.1 is available":

- **Release notes**: the release's page on GitHub, in your browser.
- **Skip this version**: it is not offered again (a newer one is). **Check for Updates…** offers
  it again.
- **Later**: hides the bar until the next check finds a release.
- **Update**: downloads the release and checks it. Nothing is replaced yet, and you can keep
  working. Then the bar says "Deckhand 0.1.1 is ready" with **Restart to update**.
- **Restart to update**: replaces Deckhand and restarts it. While sessions, shells or jobs run,
  Deckhand asks first: restarting stops them (sessions resume from their files afterwards).

**What is checked before anything is replaced.** The download goes into a private folder in the
data dir. Deckhand refuses it unless its size matches the release, its SHA-256 matches the
release's `.sha256`, and its **signature** (the release's `.sig`, made with Deckhand's release
key, whose public half is built into Deckhand) is valid for that version, file, size and SHA-256.
Only then is it unpacked. Then Deckhand also refuses it if it holds anything but `Deckhand.app`,
a link pointing outside the app, or a setuid file, if its bundle id is not `dev.pi-desk.app`, if
its version is not the release's, if a file in it is writable by others, if
`codesign --verify --deep --strict` fails, or if the app's code hash (CDHash) is not the one the
signature names. It never installs an older or the same version. Right before **Restart to
update** replaces Deckhand, it checks the prepared copy once more (yours, same code hash, same
version); a copy changed since is refused. The old app is kept as `Deckhand.app.old-<version>`
next to the new one until Deckhand starts a second time after the update (whatever version you
run then), which removes it.

**When Deckhand cannot replace itself**, the bar says why and offers only **Release notes**:
when it runs from a folder you cannot write to, from a disk image, or from macOS's temporary
read-only copy (App Translocation: move `Deckhand.app` to Applications with Finder and open it
from there). A development build (`build/Deckhand.app`) does not check for updates.

**Check for Updates…** is in the Deckhand menu and the palette; it checks now, whatever the
setting. **Check for updates automatically** (the gear, or the palette) turns the daily check
off. Your choices (the setting, the skipped version, the last check's time) are in
`<data dir>/update.json`.

**To update by hand**, download the zip from the
[releases page](https://github.com/McFalljb/deckhand/releases), check it with
`shasum -a 256 -c deckhand-<version>-macos-arm64.zip.sha256`, quit Deckhand and replace
`Deckhand.app` in Applications.

### From pi-desk to Deckhand

pi-desk is now Deckhand. pi-desk 0.1.x does not update itself to Deckhand: install it fresh. Quit
pi-desk first (the two must not run at the same time), delete `pi-desk.app`, then download Deckhand
from the [releases page](https://github.com/McFalljb/deckhand/releases) and move `Deckhand.app` to
Applications. Your projects, sessions, settings, Atlas, jobs and Claude accounts carry over.
While pi-desk runs, Deckhand does not start: it says so and quits. From Deckhand on, releases come
as `deckhand-<version>-macos-arm64.zip`.

**Names kept from pi-desk, on purpose.** Some internal names still say pi-desk, so that your data
and setup carry over and nothing you rely on breaks. They are not leftovers to rename:

- the bundle id, `dev.pi-desk.app`;
- the data dir, `~/Library/Application Support/pi-desk` (see [Where it lives](#where-it-lives));
- the `PI_DESK_*` environment variables (`PI_DESK_DATA_DIR` and the ones Deckhand sets in its tabs);
- the `pi-desk` command in Claude tabs, an alias of `deckhand`;
- the project file `.pi-desk/apps.json`, the default main folder `~/pi-desk`, and the control
  socket's folder (`$TMPDIR/pi-desk-<uid>`).

Agents (Atlas, pi tabs) can see whether an update is available (`get_state`), but cannot check,
download or install one: only you can.

## Your data

### Where it lives

Deckhand's data dir is `~/Library/Application Support/pi-desk` on macOS (Linux:
`~/.local/share/pi-desk`; the `PI_DESK_DATA_DIR` environment variable moves it). The name is kept
from Deckhand's old name ([From pi-desk to Deckhand](#from-pi-desk-to-deckhand)). It is private
to you (`0700`), and its files are `0600`:

| File | What |
|---|---|
| `workspace.json` | open sessions, tabs, projects you added, pins, hidden rows, sort, layout and settings |
| `session-titles.tsv` | a cache of session titles, so start-up does not reread every session |
| `commands.log` | every command run, one JSON line each, rotated at 10 MB (`commands.log.1`, `.2`) |
| `atlas/ATLAS.md` | Atlas's prompt (yours to edit) until a main folder is set; then the fallback |
| `atlas/GUIDE.md` | this guide, rewritten by Deckhand on start (do not edit) |
| `home/` | Atlas's own pi sessions |
| `jobs/<id>/` | each job's state, its runs (`runs/`) and pi's sessions of them (`sessions/`) |
| `jobs/scheduler.log` | what the scheduler did: runs started, skipped and why |
| `update.json` | [updates](#updates): the setting, a skipped version, when it last checked |
| `instance.lock` | held while Deckhand runs: a second Deckhand on the same data says "Deckhand is already running" and quits |
| `updates/` | an update being downloaded and checked (removed afterwards) |

Elsewhere:

- **pi's sessions** stay in pi's store, `~/.pi/agent/sessions`. Deckhand reads them; it never
  writes or deletes them (closing a session keeps its file).
- **Your folders**: notes, jobs, memory, Atlas's prompt and chats live in the main folder (see
  below). These are yours: Deckhand's data dir above is machine-only state.
- **Chats** run in the chats folder; their sessions are in pi's store like any other.
- The control socket lives in a private temporary folder (`$TMPDIR/pi-desk-<uid>`).

### Your folders

One **main folder** holds everything that is yours (new users: `~/pi-desk`; set it up in the
[first run](#the-first-run) sheet). Its standard subfolders:

| Folder | What |
|---|---|
| `sessions/` | session notes: pi-kit's notes skill writes `sessions/…` here |
| `jobs/` | Atlas's job notes (see [Jobs](#jobs)) |
| `memory/` | memory notes (for Atlas's shared memory, coming) |
| `atlas/` | Atlas's prompt `ATLAS.md` and `HEARTBEAT.md` |
| `chats/` | where chats run, with their `AGENTS.md` (chat instructions) |

- Setting the main folder makes the missing subfolders, empty. Nothing else in it is touched,
  and Deckhand **never moves files**: when you pick another main folder, the old one stays where
  it is and the Folders group shows it as **Old main folder** with **Reveal** (in Finder).
- **Each subfolder can live elsewhere.** Settings tab → **Folders** lists the main folder and
  each subfolder with its path and whether it is the **default** (inside the main folder) or
  **custom**. Each row has **Change…** (a folder picker), **Reset** (the circular arrow: back to
  the default) and **Reveal in Finder** (the folder icon). The main folder's row has
  **Change…** (palette: "Main folder…"), or **Set up…** while none is set. A sessions folder
  must be named `sessions` (pi-kit writes `sessions/` inside its notes folder). A separate
  chats folder is common: the chats row is the same as the gear's **Chats folder…**.
- **pi-kit's notes land here too.** Every pi tab and job run gets `PI_KIT_NOTES_DIR` set to the
  **sessions folder's parent**, so pi-kit's session notes go into `sessions/`. That is the main
  folder unless you moved `sessions/`: then it is the folder that holds your `sessions/` (and
  pi-kit's other notes go there too, not into the main folder). If
  your own environment sets `PI_KIT_NOTES_DIR` (Deckhand's, or your login shell's), yours wins:
  Deckhand passes it on unchanged, and the Folders group shows it as a **PI_KIT_NOTES_DIR**
  row. At start, scheduled jobs wait for your login shell's answer (up to 10 seconds) so a job
  due at launch gets your value, not the main folder.
- **Chat instructions**: Deckhand writes a starter `AGENTS.md` into the chats folder when it has
  none (at start once a main folder is set, at setup, when the chats folder changes, and on the first chat), never over a
  file and never beside an `AGENTS.override.md` or `CLAUDE.md` there (pi would read those
  instead). It never writes one when the chats folder is your home folder, `/`, or a folder
  that holds a project or a job's folder: pi applies `AGENTS.md` to every folder below it, so
  those pi tabs would be told they are not coding agents. Settings → Chats → **Chat
  instructions** still offers **Create** there if you want it. When an update ships a newer starter, Deckhand replaces yours only if you never
  edited it (keeping `AGENTS.md.bak-<date>`).

### What is stored about your sessions

- `session-titles.tsv` holds, per session file: its path, size, the name you gave it, and the
  **first 200 bytes of your first message** (used as the title). It never holds the rest of a
  session.
- `workspace.json` holds session ids and folders, never their content, tokens or typed text.
- `commands.log` holds commands with paths, project names and session titles; the text of
  prompts and pasted text is replaced with `<redacted N bytes>`.

### Privacy

- Deckhand never shows, opens or logs credential files (pi's sign-ins, private files in pi's
  folder, `.env`), not in the Settings tab, the Files tab's editor, or to Atlas.
- Connection tokens for the control socket are never logged or saved.
- Deckhand's only network call of its own is the [update check](#updates) (and the download
  you start with **Update**), to GitHub. Only pi (and its extensions) talk to model providers.

### Backups

To back up Deckhand, copy the data dir (with Deckhand closed) and `~/.pi/agent` (pi's sessions and
settings). Your projects are your own folders. Deckhand itself keeps:
`workspace.json.bak-<time>` when you start with `--fresh`, `workspace.json.bad-<time>` when the
saved workspace could not be read, and `atlas/ATLAS.md.bak-<date>` when a newer starter replaced
an unedited prompt.

## Troubleshooting

**A session says "Untitled session · <date>".** pi has no name or first message for it yet
(it was started and left empty, or started by `/goal`, which shows the goal instead). Give it a
name with `/name …` in pi. If titles look stale, use the gear's **Rescan sessions**.

**Atlas does not respond.** Look at its header: "working…" means it is busy (Esc stops it);
"needs you" means a pi dialog waits in its terminal; "stopped" means its pi exited: press ⌘J
twice. To start it fresh with its prompt and settings, type `/reload` in its terminal. If it
never starts, check that `pi` runs in a Terminal (Deckhand starts it through your login shell).

**A pi tab is stuck.** Click into the tab and press Esc (pi's interrupt). If pi itself hangs,
close the session from its row (**×** or **Close session**; it asks first) and open it again
from the list: pi resumes it from its file.

**A pi tab says "[process exited: …]".** Its pi ended: the line says the exit code or the
signal that stopped it, and its output above it says why. Click the bar's **Restart** (or
**Restart with model…**) or open the session again. `commands.log` records it (`tab_exited` with
`exit`).

**Where Deckhand's environment comes from.** Started from a terminal, Deckhand and everything it
starts use that terminal's environment, unchanged. Started from the Dock, Finder, Spotlight or
`open`, macOS gives an app only a minimal environment (often just `/usr/bin:/bin:/usr/sbin:/sbin`,
or a Nix profile's folders), so Deckhand asks your interactive login shell (`$SHELL -i -l`, as a
Terminal window would, at most 4 s) for its environment and merges it in: your shell's values
win, as in a terminal (so `AWS_PROFILE`, Homebrew's `brew shellenv` or a 1Password
`SSH_AUTH_SOCK` set in `~/.zshrc` reach your tabs), variables the shell does not set are kept, and
`PATH` becomes the shell's, in the shell's order, followed by any folders only the started-with
`PATH` had. If the shell fails or takes over
4 s, `PATH` gets `~/.pi/agent/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`,
`~/.npm-global/bin`, `~/.volta/bin` and `~/.bun/bin` where they exist. Values are never logged.

**You changed your shell profile.** Use the gear's **Refresh shell environment** (or ⌘K): it asks
your login shell again and new tabs (pi, Claude, shell, apps) use the result, as does the `PATH`
jobs use when none is saved for them; tabs already open keep the environment they started with
(restart a session's pi from its dead-tab bar, or close and reopen a tab). Jobs' other
variables, Deckhand's check for a newer pi on disk, and the git that the Changes tab and the
editor run keep the environment Deckhand started with until you restart it. Started from a terminal there is nothing to refresh: Deckhand uses that
terminal's environment, so start it again from there. Putting what GUI-started tools need in
`~/.zprofile` (for example `export PATH="$HOME/.pi/agent/bin:$PATH"`,
`eval "$(/opt/homebrew/bin/brew shellenv)"`, `export AWS_PROFILE=...`) still works and is read by
every login shell. If a provider in pi fails with a credentials or profile error only in Deckhand,
the variable it needs is probably set only in a file Deckhand's shells did not read: refresh, or
move it to `~/.zprofile`.

**A pi tab says "pi was not found".** pi is neither on your login shell's PATH nor in pi's own
install folder (`$PI_CODING_AGENT_DIR/bin` when it is an absolute path, else `~/.pi/agent/bin`). When pi is only in that
folder, the tab starts it from there and its first line says so ("pi is installed at … but is
not on your login shell's PATH"): add the folder to PATH in `~/.zprofile` so other tools find it
too. Otherwise check that `pi` runs in a new Terminal window, or put the line that adds its
folder to PATH in `~/.zprofile`, use **Refresh shell environment** and open the tab again. Claude
tabs do the same for `claude` with `~/.local/bin` and `~/.claude/local`.

**A session shows "Session gone".** Its session file or folder no longer exists; click the button
to close it.

**Where are the logs?** `commands.log` in the data dir (every command and its result). Errors at
start-up go to the terminal you started Deckhand from. A pi session's own logs are pi's.

**To reset the layout**, start Deckhand with `--fresh` (`build/deckhand --fresh`): it starts with
nothing open and keeps the old workspace as `workspace.json.bak-<time>`. To reset just one
column's width, double-click its edge.

## All shortcuts

Deckhand has a macOS **menu bar**, built from the same action table (`src/actions.odin`,
`src/menubar.odin`) as the palette (⌘K) and the shortcuts sheet (⌘/), so the three always agree.
Items that do not apply right now are greyed out (Save without unsaved changes, Close tab on the
pi tab), and switches show a checkmark (the columns, Atlas, the appearance and the look).

A shortcut works the same whether you press it or pick its menu item, and it goes first to
whatever has the keyboard: ⌘C copies from the text field, the editor or the terminal you are in;
⌘W in Atlas's drawer hides the drawer. Keys that belong to the terminal (⌘⌫, ⌘←, ⌘→ and the ⌥
keys) have no menu item and always reach the terminal. The tables below follow the menus.

**Deckhand**

| Menu item | Shortcut | Notes |
|---|---|---|
| About Deckhand |  | |
| Settings… | ⌘, | the left column's Settings tab (again: back to Sessions) |
| Set up Deckhand… |  | the first-run sheet: coding agents, main folder, chats (see [the first run](#the-first-run)) |
| Hide Deckhand | ⌘H | |
| Hide others | ⌥⌘H | Show all brings them back |
| Quit Deckhand | ⌘Q | asks while sessions run |

**File**

| Menu item | Shortcut | Notes |
|---|---|---|
| New chat | ⌘N | pi or Claude Code: a picker when both are installed |
| New session in project | ⇧⌘N | in the selected project; pi or Claude Code, as New chat |
| New shell tab | ⌘T | |
| New Claude tab | ⌥⌘T | Claude Code in the session on screen |
| New browser tab |  | a blank page, its address field ready |
| Add project… |  | |
| Open file… | ⌘P | the current project's files |
| Close tab | ⌘W | the pi tab: close the session, asks first; in Atlas: hide the drawer |
| Close session |  | asks first |
| Save | ⌘S | an editor tab with unsaved changes |

**Edit**

| Menu item | Shortcut | Notes |
|---|---|---|
| Undo, Redo | ⌘Z, ⇧⌘Z | in the editor |
| Cut | ⌘X | a text field or the editor |
| Copy | ⌘C | a text field, the editor or the terminal's selection |
| Paste | ⌘V | a text field, the editor or the terminal |
| Select all | ⌘A | a text field or the editor |
| Find… | ⌘F | Find in file, in the editor |
| Find and replace… | ⌥⌘F | |
| Find next, Find previous | ⌘G, ⇧⌘G | |
| Find in page | ⌘F | the browser tab on screen: the find bar |
| Go to line… | ⌘L | in a browser tab: its address field |
| Filter projects and sessions | ⌘⇧F | |

**View**

| Menu item | Shortcut | Notes |
|---|---|---|
| Toggle left column | ⌘B | |
| Sessions, Files, Settings files | ⌘⇧E (Files) | the left column's tabs (⌘⇧E again: back to Sessions) |
| Jobs |  | the left column's Jobs tab (Atlas's jobs) |
| Show changes |  | the Changes tab of the session's checkout |
| Toggle right panels | ⌥⌘B | the right column |
| Command palette | ⌘K | Search or run a command (the palette) |
| Bell |  | the notifications |
| Toggle Atlas | ⌘J | |
| Markdown preview | ⇧⌘V | a `.md` file as a document, or back to its source (Markdown tabs) |
| Appearance ▸ System, Light, Dark |  | |
| Look ▸ Graphite, Warm, Ghostty |  | |
| Reduce motion |  | |
| Bigger text, Smaller text, Actual text size | ⌘+, ⌘−, ⌘0 | the terminals' and the editor's text (9–28 pt; remembered) |
| Zoom page in, Zoom page out, Page actual size | ⌘+, ⌘−, ⌘0 with a browser tab on screen | the page's zoom |
| Developer tools |  | DevTools for the browser tab on screen |
| Enter full screen | ⌃⌘F | |

**Window**

| Menu item | Shortcut | Notes |
|---|---|---|
| Minimize | ⌘M | |
| Zoom |  | |
| Next tab, Previous tab | ⇧⌘], ⇧⌘[ | round the tabs of the pane with the keyboard |
| Tab 1, Tab 2, Tab 3, Tab 4, Tab 5, Tab 6, Tab 7, Tab 8, Tab 9 | ⌘1, ⌘2, ⌘3, ⌘4, ⌘5, ⌘6, ⌘7, ⌘8, ⌘9 (⌘1–⌘9) | the pane with the keyboard's tabs; in the palette: run its rows |
| Next session, Previous session | ⌥⌘↓, ⌥⌘↑ | in the Open section's order |
| Split pane right, Split pane down | ⌘D, ⇧⌘D | a new shell in the new pane |
| Close pane (its tabs stay) | ⇧⌘W | its tabs join the pane next to it |
| Even out panes |  | every pane gets equal room |
| Focus pane left, Focus pane right, Focus pane up, Focus pane down | ⌃⌘←, ⌃⌘→, ⌃⌘↑, ⌃⌘↓ | the neighbouring pane gets the keyboard |
| Move tab to the pane left, Move tab to the pane right, Move tab to the pane above, Move tab to the pane below | ⇧⌃⌘←, ⇧⌃⌘→, ⇧⌃⌘↑, ⇧⌃⌘↓ | or into a new pane that way |
| Bring all to front |  | |

**Help**

| Menu item | Shortcut | Notes |
|---|---|---|
| Deckhand user guide |  | this guide, in a Markdown tab (Atlas's copy in the data dir) |
| Keyboard shortcuts | ⌘/ | the shortcuts sheet (in an editor: toggle comment) |

**Terminal**

| Shortcut | Action |
|---|---|
| ⌘C | Copy the selection |
| ⌘V | Paste |
| Shift+drag | Select while the program uses the mouse |
| Shift+click | Extend the selection |
| ⌘⌫, ⌥⌫ | Terminal: delete to line start, word back |
| ⌥⌦ | Delete a word forward |
| ⌘←, ⌘→ | Terminal: line start, line end |
| ⌥←, ⌥→ | Terminal: word back, word forward |
| ⌘-click, ⇧⌘-click | Terminal: open a link (hold ⌘ to see it; ⇧: the default browser); right-click it for its menu |
| Esc | goes to the program: in pi, interrupt (also in Atlas's drawer, which stays open) |

**Editor**

| Shortcut | Action |
|---|---|
| ⌘S | Save |
| ⌘Z, ⇧⌘Z | Undo, redo |
| ⌘F, ⌥⌘F | Find in file, find and replace |
| ⌘G, ⇧⌘G | Next match, previous match |
| ⌘L, ⌃G | Go to line… (⌘L in a browser tab: its address field) |
| ⌘/ | Editor: toggle comment |
| ⌘], ⌘[ | Editor: indent, outdent |
| ⌘↑, ⌘↓ | Editor: start, end of the file |
| ⌘A, ⌘X | Select all, cut |
| ⌥←, ⌥→ | Move by word |

**Files tab**

| Shortcut | Action |
|---|---|
| ↑ ↓ ← → | Move, close or open folders |
| Enter | Open |
| Space | Open in preview |
| F2 | Files: rename |
| ⌘⌫ | Files: move to Trash (asks first) |
| Esc | Give the keyboard back |

**Atlas's drawer**: ⌃L opens pi's model selector (the Model button).

## All palette actions

Everything ⌘K can run. Some only appear when they apply (for example Save needs an editor tab).

| Action | Shortcut | What it does |
|---|---|---|
| New chat | ⌘N | a new chat in the Chats folder |
| New session | ⇧⌘N | a new session in the selected project (pi or Claude Code: a picker when both are installed) |
| Chats: read-only |  | start chats read-only or as full pi |
| Chats folder… |  | pick the folder chats run in |
| Chats folder: back to the default |  | undo the above |
| New shell tab | ⌘T | a shell in the session's folder |
| New browser tab |  | a web page in the session on screen (its address field takes the keyboard) |
| New Claude tab | ⌥⌘T | Claude Code in the session on screen, with Deckhand's plugin |
| Add Claude account… |  | add a Claude Code config folder as an account (a folder picker) |
| Claude: send the waiting message now |  | the Claude tab's held message goes into its prompt now |
| Claude: drop the waiting messages |  | the Claude tab's held messages are dropped |
| Browser: back, Browser: forward, Browser: reload page |  | the browser tab on screen |
| Browser: find in page | ⌘F in a browser tab | the find bar |
| Browser: zoom in, Browser: zoom out, Browser: actual size | ⌘+, ⌘−, ⌘0 in a browser tab | the page's zoom |
| Browser: DevTools |  | Chromium's DevTools for the page, in its own window |
| Browser: open in default browser |  | the page's address in your default browser (web addresses only) |
| Browser: open the blocked popup |  | the popup the page tried to open, in a new tab of the same session |
| Browser: show downloads folder |  | the folder downloads go to, in Finder |
| New app tab… |  | a program that draws into the tab (asks for the command) |
| Inspect app boxes |  | the app tab's **Inspect**: its boxes and their labels over it |
| Close tab | ⌘W | close the current (non-pi) tab |
| Close session |  | close the session on screen (asks) |
| Show changes |  | the Changes tab of the session's checkout |
| Ask Atlas… |  | open the drawer with the keyboard in it |
| Atlas: change model |  | pi's model selector in Atlas |
| Atlas: edit prompt |  | open ATLAS.md |
| Toggle Atlas | ⌘J | show or hide the drawer |
| Dock the agent's drawer |  | pin or unpin the drawer |
| Agent notifications |  | Atlas's macOS notifications on/off |
| Notifications |  | open the bell |
| Notifications: mark all read |  | |
| Notifications: clear |  | |
| Notify me about: Finished |  | bell group on/off |
| Notify me about: Waiting |  | bell group on/off |
| Notify me about: Errors |  | bell group on/off |
| Notify me about: Jobs |  | bell group on/off |
| Also notify in macOS |  | macOS notifications for the bell |
| Toggle left column | ⌘B | |
| Toggle right column | ⌥⌘B | |
| Bigger text, Smaller text, Actual text size | ⌘+, ⌘−, ⌘0 | the terminals' and the editor's text |
| Next tab, Previous tab | ⇧⌘], ⇧⌘[ | |
| Next session, Previous session | ⌥⌘↓, ⌥⌘↑ | |
| Split pane right, Split pane down | ⌘D, ⇧⌘D | |
| Close pane (its tabs stay) | ⇧⌘W | |
| Even out panes |  | |
| Focus pane left, Focus pane right, Focus pane up, Focus pane down | ⌃⌘←, ⌃⌘→, ⌃⌘↑, ⌃⌘↓ | |
| Move tab to the pane left, Move tab to the pane right, Move tab to the pane above, Move tab to the pane below | ⇧⌃⌘←, ⇧⌃⌘→, ⇧⌃⌘↑, ⇧⌃⌘↓ | |
| Deckhand user guide |  | this guide in a Markdown tab |
| Markdown preview | ⇧⌘V | a `.md` file as a document, or its source |
| Open in editor |  | edit the Markdown tab's file in an editor tab |
| Edit settings files… | ⌘, | the Settings tab |
| Edit pi settings (settings.json) |  | |
| Edit pi models (models.json) |  | |
| Edit global AGENTS.md |  | |
| Edit project pi settings (.pi/settings.json) |  | |
| Edit Claude settings (settings.json) |  | Claude Code's, in its config folder |
| Edit global CLAUDE.md |  | Claude Code's instructions for every project |
| Edit project Claude settings |  | the project's `.claude/settings.json` |
| Keyboard shortcuts | ⌘/ | the shortcuts sheet |
| Look: Graphite, Look: Warm, Look: Ghostty |  | the look |
| Appearance: System, Appearance: Light, Appearance: Dark |  | light or dark |
| Text size: Small, Text size: Medium, Text size: Default, Text size: Large |  | the chrome's text size |
| Reduce motion |  | |
| Rescan sessions |  | read pi's session store again (Claude rows are Deckhand's own history) |
| Refresh shell environment |  | ask your login shell for its environment again (started from the Dock or Finder); new tabs use it, open tabs keep theirs |
| Tidy project list |  | on or off: see [A tidy project list](#a-tidy-project-list) |
| Reload all pi tabs |  | `/reload` every idle pi tab, busy ones once idle ([Hot reload](#hot-reload)) |
| Check for Updates… |  | check for a newer Deckhand now ([Updates](#updates)) |
| Check for updates automatically |  | on or off: the daily check ([Updates](#updates)) |
| Restart to update Deckhand |  | once an update is downloaded and checked: install it and restart ([Updates](#updates)) |
| Restart pi tabs on the new pi |  | after a pi update: restart idle pi tabs on their sessions |
| Restart Claude tabs for changed settings |  | the Claude bar's Restart |
| Restart Claude tabs on the new Claude Code |  | the update bar's Restart |
| Restart all Claude tabs |  | every running Claude tab; asks first |
| Add project… |  | pick a folder |
| Rename project |  | rename the selected project |
| Filter projects and sessions | ⌘⇧F | |
| Clear filter |  | |
| Filter: running, Filter: waiting for you, Filter: pinned |  | the quick filters |
| Show hidden projects and sessions |  | |
| Pin project, Unpin project, Hide project |  | the selected project |
| Pin session, Unpin session, Hide session |  | the session on screen |
| Sort projects (next order), Sort sessions (next order), Sort chats (next order) |  | Recent → Name → Created |
| Quit Deckhand | ⌘Q | |
| Open file… | ⌘P | |
| Save | ⌘S | |
| Find in file | ⌘F | |
| Go to line… | ⌘L | |
| Toggle soft wrap |  | |
| Diff with HEAD |  | |
| Files | ⌘⇧E | the Files tab |
| Sessions and projects |  | the Sessions tab |
| New file…, New folder… |  | in the Files tab |
| Collapse all folders, Refresh files |  | the Files tab |
| Reveal in Finder |  | the Files tab's row, or the editor's file |
| Reveal active file in Files |  | |
| Collapse all settings folders, Refresh settings files |  | the Settings tab |
| Show jobs |  | the Jobs tab |
| New job |  | the job sheet: a form that writes a job note |
| Set up Deckhand… |  | the first-run sheet (coding agents, main folder, chats, summary) |
| Main folder… |  | pick the main folder |
| Edit chat instructions |  | the chats folder's AGENTS.md |
| Pause all jobs, Resume all jobs |  | the kill switch for jobs |
| Stop all running jobs |  | |

## Coming soon

Planned; this guide covers each once it ships:

- **Jobs while Deckhand is closed** (a background helper), heartbeat and no-agent check jobs,
  and Atlas's shared memory (design: [ATLAS.md](ATLAS.md)).
- **Merging** from the Changes tab.
