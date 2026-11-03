# pi-desk user guide

pi-desk is a desktop app for [pi](https://github.com/earendil-works), the coding agent. It keeps
your projects and pi sessions in one window: the list on the left, pi's normal terminal screen in
the middle, more tabs (shells, files) beside it, a built-in assistant, **Atlas**, in a drawer
on the right, and **jobs**: prompts that pi runs for you on a schedule.

This guide covers what is in pi-desk today. Developers: the wire protocol and every command are in
[PROTOCOL.md](PROTOCOL.md); the saved workspace in [PERSISTENCE.md](PERSISTENCE.md); the design
of jobs (and what comes next for them) in [ATLAS.md](ATLAS.md).

Every action has a button and most have a shortcut, and the menu bar lists them by menu (pi-desk,
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
14. [Your data](#your-data) (and [your folders](#your-folders))
15. [Troubleshooting](#troubleshooting)
16. [All shortcuts](#all-shortcuts)
17. [All palette actions](#all-palette-actions)
18. [Coming soon](#coming-soon)

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

When pi-desk needs you to confirm something (closing a running tab, quitting), a bar appears
above the tabs with **Cancel** and **Confirm**.

### The first run

The first time pi-desk starts without a main folder (new users, and once after the update that
added it), a **Set up pi-desk** sheet opens over the window. It has three steps:

1. **The main folder**, where your notes, jobs, memory, Atlas's prompt and chats live (see
   [Your folders](#your-folders)):
   - **Use your notes folder**: offered when pi-desk finds one, with the path and why it found
     it: your `PI_KIT_NOTES_DIR`, or a folder named in pi's global `AGENTS.md`
     (`~/.pi/agent/AGENTS.md`, the only file it reads) that has a `sessions/` folder. pi's own
     folder (`~/.pi/agent` and above), your home folder and git checkouts are never offered.
   - **Create ~/pi-desk**: the default when nothing is found.
   - **Choose another folder…**: any folder.
2. **Chats**: **Inside the main folder (chats/)** or a **Separate folder** (pre-selected when you
   picked one before, or when `~/Chats` already has chats; **Choose separate folder…** picks
   another). Files pi creates in chats land in that folder.
3. **Your folders**: the layout as a small tree. **Done** makes the missing folders, empty, and
   closes the sheet. Nothing already there is moved or changed.

**Skip for now** (or Esc on the first step) closes it for good: jobs stay off, and the Jobs tab
and Atlas's drawer offer **Set up pi-desk…**. Reopen it any time from the gear's **Set up
pi-desk…**, the palette or the menu bar (pi-desk → Set up pi-desk…), or, while no main folder
is set, the Settings tab's **Folders** group. It starts at step 1 with your current folders
filled in, and Esc on step 1 closes it without changing anything. Enter goes to the next step (Done on the
last), Esc goes back, ↑↓ change the choice.

If you already had a notes folder set (before the main folder existed), it simply becomes the
main folder and the sheet does not open.

## Projects, sessions and chats

- A **project** is a folder you work in. Its **sessions** are the pi sessions you ran there (pi
  stores them in `~/.pi/agent/sessions`; pi-desk lists them, it does not copy them).
- A **chat** is a pi conversation outside any project. Chats run in one folder, the main
  folder's `chats/` (or `~/Chats` without a main folder, or the folder you chose), so
  `cd <that folder> && pi --resume` finds them too. That folder has its own **chat
  instructions** (`AGENTS.md`, which pi reads there besides your global one): in chats pi is a
  conversation partner and researcher, not a coding agent. It explains, looks things up and
  cites sources, and draws diagrams in text. Edit them with the palette's **Edit chat
  instructions** or Settings → Chats.
- An **open session** is a session running in pi-desk now, with its tabs.

The Sessions tab has three sections:

- **Open**: every open session, the one on screen first. A project's session shows a folder icon
  and `project ·` before its title; a chat shows a speech bubble. Only shown while something is
  open.
- **Projects**: a tree. Git repositories are top-level rows; other folders nest under the
  folder they sit in, or share a group row (see [A tidy project list](#a-tidy-project-list)).
  The selected project is expanded with its sessions (the first eight, then **Show more**) and
  **+ New session**.
- **Chats**: your chats, with **+ New chat**.

A session's **title** is pi's own: the name you gave it with `/name` in pi, else your first
message, else "Untitled session · <date>" (see [Troubleshooting](#troubleshooting)).

### A tidy project list

pi-desk finds a project for every folder pi ever ran in, which gets cluttered. Three rules keep
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
    wherever it lives; so is a folder you added by hand (+, a dropped folder, `pi-desk DIR`,
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
  for New session, Pin, Hide and the rest. Group rows and parents start collapsed; pi-desk
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

A dot after a row (and on its tab) says what its pi is doing:

| Dot | Meaning |
|---|---|
| none | idle, not open, or not reporting yet |
| pulsing blue-green | working |
| amber, "Waiting for you" | a pi dialog is open: it needs your answer |
| faint amber | its last answer asked you a question |
| red | its last run ended with an error |
| grey | pi exited |

Waiting work is never hidden: hidden rows, folded sections and filters always leave sessions
that wait for you visible.

### Everyday tasks

- **To add a project**, click **+** on the PROJECTS heading and pick a folder, drop a folder onto
  the left column, or use the palette's "Add project…". From a terminal, `build/pi-desk DIR`
  adds DIR and starts a new session there.
- **To open a session**, click it. If it is already open, pi-desk shows it instead of starting it
  twice.
- **To start a new session in a project**, click **+ New session** under it, use the **⌄** menu, or
  press ⇧⌘N (in the selected project).
- **To start a new chat**, click the New chat button in the top bar or **+ New chat**, or press ⌘N.
- **To select a project**, click it; click it again to fold it.
- **To act on a row**, hover it and click **…**, or right-click it (or ⌃-click). Projects offer
  Pin, New session, New job for this project…, Rename…, the session order, Reveal in Finder, Copy
  path and Hide. Sessions offer Pin, Reveal in Finder, Copy path (of the session file), Copy
  session info, Send to Atlas, Hide and Close session.
- **To start a job for a project**, click **New job…** under the selected project (below
  **+ New session**), or use its menu's **New job for this project…**: the [job
  sheet](#the-job-sheet) opens with that project chosen.
- **To give Atlas a session's details**, hover the session and click **ⓘ**: a menu shows the
  session's info (its id, session file, project, folder, title, when it was created and last
  changed, and its model when the session file's header names one) with **Copy session info** and
  **Send to Atlas**. The same two are on the session's right-click menu. The info is a short
  block of `key: value` lines that Atlas can use to look the session up; pi-desk reads only the
  session file's first line (its header) and the file's dates, never the conversation. **Send to
  Atlas** opens Atlas's drawer and puts the block into Atlas's input without sending it: type
  your question after it and press Enter. While Atlas's pi is starting the block waits for it.
  When it cannot go in (Atlas waits for you, its model selector is opening, or its input does
  not take pasted text), the block is copied to the clipboard instead and the bell says why.
- **To pin** a project or session to the top of its section, click the pin on its row or use
  **…** → Pin. Pinned rows get Move up / Move down in the same menu.
- **To rename a project**, use **…** → Rename…, or the palette's "Rename project". Sessions are
  named in pi: type `/name My title` in the session.
- **To hide** a project or session, use **…** → Hide. Nothing is deleted.
- **To see hidden rows**, click the sort button on a section heading and tick **Show hidden**
  (or the palette's "Show hidden projects and sessions"). Hidden rows then show, and their menu
  offers **Show again**.
- **To sort** a section, click the sort button on its heading: Recent activity, Name or Created.
- **To fold** a section, click its heading. A folded Open section still shows waiting sessions.
- **To filter**, press ⌘⇧F (or click the Filter field) and type: words match project names and
  paths and session titles, loosely. The **Running**, **Waiting** and **Pinned** chips under it
  narrow the list further. Esc in the field clears it.
- **To pick up new sessions** started outside pi-desk, use the gear's "Rescan sessions".

### Chats settings (the gear)

- **Chats: read-only** starts new chats with pi-kit's read-only guardrails (`PI_KIT_READONLY=1`)
  instead of full pi. Off by default.
- **Chats folder…** picks another folder for new chats; chats already in the old folder stay
  there, and that folder becomes an ordinary project. **Chats folder: back to the default**
  undoes it (the main folder's `chats/`, or `~/Chats` without a main folder). The same as the
  Folders group's chats row (see [Your folders](#your-folders)).

## Tabs

Each open session has one **pi tab** (always first) and any number of **shell tabs**,
**editor tabs**, **browser tabs** and **app tabs**.

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
  point at one to see its label, click one to write a comment on it for pi ([Comments for
  pi](#comments-for-pi)). While Inspect is on, the mouse over the tab is pi-desk's; keys still go
  to the app. Agents drive it with `app_call` (any method the app offers; they ask it
  with `tab.describe`), `app_input`, `app_events` and `app_screenshot` (see PROTOCOL.md).
- **To open a browser tab** (a web page, Chromium inside pi-desk), pick **New browser tab** in
  the **+** menu, the File menu or the palette: a blank page opens with the keyboard in its
  address field. Type an address and press Enter (or **Go**). See [Browser tabs](#browser-tabs).
- **To switch tabs**, click one or press ⌘1–⌘9; ⇧⌘] and ⇧⌘[ go to the next and previous tab.
  ⌥⌘↓ and ⌥⌘↑ go to the next and previous open session (Window menu).
- **To close a tab**, click its **×** or press ⌘W. Closing a tab that is busy asks first: a shell
  running a command, or an editor with unsaved changes.
- **To close a whole session**, click the pi tab's **×**, the **×** on its row in the Open
  section, its row menu's **Close session**, or the palette's "Close session". This always asks
  first, and says so when its processes are still running. pi's session file stays: you can
  open it again from the list.

Sessions you switch away from keep running in the background. When you quit (⌘Q) with sessions
running, pi-desk asks first; on the next start it restores your open sessions, tabs and layout,
and starts each session again when you first look at it.

**A tab belongs to one session.** A tab you open goes into the session on screen; one an agent
opens goes into that agent's own session, never "whichever session you happen to be looking at".
A page's popups and links that open a new window open in a new browser tab of the same
session. Tabs never move to another session, and whatever a tab sends to pi goes to its own
session's pi.

### Browser tabs

A browser tab shows a web page (Chromium, inside pi-desk). The bar above the page has:

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
  takes the address field's place (see [Comments for pi](#comments-for-pi)). ⌘⇧. works while
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
- **Right-click** opens pi-desk's menu: **Back**, **Forward**, **Reload**; over a link **Open
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
  waits until you answer; nothing else in pi-desk does.
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
pi-desk's own shortcuts come first even then: ⌘T opens a shell tab, ⌘W closes the browser tab,
⌘1–⌘9 switch tabs, ⌘K opens the palette.

- **Links that open a new window** (`target=_blank`, `window.open` after a click) open in a new
  browser tab of the same session, next to the others; the page that opened it can still talk
  to it (sign-in popups need that). A page that tries to open a window without your click is
  blocked, with a bar to open it anyway.
- **One browser profile** for all of pi-desk: cookies and sign-ins are shared by every browser
  tab in every session, and kept across relaunches (in the data folder's `browser/profile`).
- **On relaunch**, each session's browser tabs come back in that session with their address and
  title; each page loads when you first look at its tab. The back/forward history is not
  kept, and an address's `name:password@` part is never saved.
- **Open pages**: pi-desk keeps at most 8 pages open at once. The tab you look at always gets
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
  pi acts does the same) and **Stop**. pi never types into password, card or one-time-code
  fields; an upload asks you first in a bar (**Allow** / **Block**); a page that changes your
  clipboard while pi acts is named in a toast. Details: BROWSER.md, step 8.

### Comments for pi

You can point at part of a tab and write a note for pi; the note waits and goes to that tab's
session's pi **with your next message**: your text, what you picked, and a cropped picture of it.
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
  the strip says why, while the session's pi is not running, pi-desk's bridge is not connected
  to it, or a pi dialog is open; the comments wait meanwhile and go once pi is back.
- Comments always go to **their own tab's session**, even when you look at another session. A
  session keeps at most 20; at most 8 pictures go with one message (the rest go as text and say
  so). They are not kept when you quit pi-desk.
- **Closing** a tab that has comments asks first: **Send and close**, **Drop and close** or
  **Cancel**. Closing a session with comments asks too: **Send now** (the session stays open:
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
  front (in your default browser when pi-desk has no browser, and from Atlas's terminal);
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

pi-desk has a small code editor with syntax highlighting.

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
- pi-desk does not open binary files, files over 20 MB, or **credential files**: pi's sign-ins
  (`auth.json` and similar), other private files in pi's folder, and `.env` files. They show
  "Credentials file: managed by pi (/login), not opened".

## Markdown tabs

A Markdown tab shows a `.md` file as a document: headings, lists, task lists, tables, quotes,
links and code blocks coloured like the editor's. This guide opens in one (Help ▸ pi-desk user
guide).

- **To open one**, right-click a `.md` file in the Files tab → **Open Markdown preview**, click
  **Preview** in an editor tab of a `.md` file, or press ⇧⌘V there (View ▸ Markdown preview).
- **Toolbar**: **Source**/**Preview** switches between the document and its text (⇧⌘V; it keeps
  your place), **Find** (⌘F; ⌘G next match), **Open in editor** (to edit the file) and **Reveal**.
  The source view is read-only and also has **Go to line** and **Wrap**.
- **Links**: a click follows a link (⌃-click does not). A web link opens in your browser (when an
  agent asks to open one, pi-desk asks you first); a link to another `.md` file opens it in a
  Markdown tab; a link to `#a-heading` scrolls there; other files open in the editor.
- **Live reload**: when the file changes on disk (you save it in the editor, or pi edits it),
  the tab shows the new version. If the file is deleted, or becomes something pi-desk cannot
  show, the tab keeps the last version and says so at the bottom.
- **Images** show as their alt text; pi-desk never fetches anything from the network.
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

- **To show another checkout in the tree**, click it. pi-desk remembers the choice per project.
- **Row actions** (**…**, or → / Space on the keyboard): Open terminal here, **New pi session
  here** (kept with the project's sessions), Reveal in Finder, Copy path, Copy branch name.
- **Clean up…** appears for a worktree that is clean and merged. It runs `git worktree remove`
  (never forced) and `git branch -d`, after you confirm. It never touches the main checkout,
  and refuses while an ignored file in it looks like a secret.

Branches are only listed; pi-desk never checks them out.

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
  minutes is stopped with its hooks; if git leaves `index.lock` behind the tab says so, and pi-desk
  never removes it.
- **Ask pi to review** sends this session's pi a prompt to review the uncommitted changes and
  the branch's commits.
- **Refresh** reads the changes again. The tab also refreshes by itself when files change
  (after a short pause) and when you switch to it; "Refreshing…" shows only if it takes a moment.
- **Merge into main…** is shown but not active yet: merging is coming later.

pi-desk's own git reads never run your repository's hooks; only Commit does. Reading the changes
does run the repository's configured clean filters (for example git-lfs) on changed files, as
`git status` does in a terminal.

## The Settings tab

**⌘,** (or the gear's **Edit settings files…**) shows pi's settings as files, in groups:

- **pi (global)**: `settings.json` (model, theme, packages…), `models.json` (may hold API keys),
  `modes.json`, `keybindings.json`, `mcp.json`, your global instructions file (`AGENTS.md` or
  similar), `SYSTEM.md`, `APPEND_SYSTEM.md`, and the folders `prompts`, `skills` and
  `extensions`. Only these: never sessions, logs or sign-ins.
- **This project** (the session on screen's project): its `.pi/` folder and instructions file.
  A missing `.pi/settings.json` or `AGENTS.md` is dimmed with a **Create** button.
- **Extensions**: each extension's config file and folder, when it has one.
- **Atlas**: its prompt file `ATLAS.md`, `HEARTBEAT.md` when there is one, and its **Model**
  (with **Change…**).
- **Atlas's jobs**: every job note in the jobs folder (see [Jobs](#jobs)).
- **Chats**: **Chat instructions (AGENTS.md)**, the chats folder's instructions (with
  **Create** when missing).
- **Folders**: the main folder and each of its subfolders (see [Your folders](#your-folders)).

Click a file to open it in an editor tab. Press ⌘, again to go back to Sessions.

- **Credential files never show** here, also not inside an opened folder, and the editor refuses
  them.
- **JSON safety**: a JSON settings file that pi reads is saved only when it is valid JSON. If
  not, the save is refused and the error names the line and column.
- **The reload bar**: pi reads its settings when it starts or reloads. After you save one, the
  [hot-reload bar](#hot-reload) shows at once and offers **Reload** for the running pi tabs that
  read it (after saving `ATLAS.md`, only Atlas).
- **Folders**: see [Your folders](#your-folders).

## Hot reload

pi reads its settings, extensions, skills, prompts, themes and instructions files (`AGENTS.md`,
`CLAUDE.md`) when it starts or on `/reload`. pi-desk watches those files while a pi tab runs and
tells you when a running pi has an old copy.

**The bar.** About a second after a change, a bar over the centre says, for example, "pi settings
changed — Reload 2 idle tabs · 1 busy when idle". Its buttons:

- **Reload**: idle pi tabs reload now (`/reload`; the session stays). A tab that is working,
  waiting for you, or running background shells or subagents reloads by itself once it is idle.
  Only when background work is involved does pi-desk ask first, and it names that work ("shell
  sh1: npm test"): a reload would stop it, so those tabs wait until it ends.
- **Details**: which files changed and what each pi tab is doing (idle, working, waits for a
  shell, reloaded, failed).
- **Later**: hides the bar until the next change, and cancels reloads still waiting for idle.

What counts: pi's agent folder (`~/.pi/agent`: `settings.json`, `keybindings.json`,
`models.json`, `mcp.json`, instructions and system-prompt files, the `extensions`, `skills`,
`prompts` and `themes` folders), local packages listed in `settings.json` (such as a pi-kit
checkout), each project's `.pi/` folder, and the instructions files in a tab's folder and the
folders above it. A change reaches only the tabs that read it: a project's `.pi/` its own
sessions, `ATLAS.md` only Atlas. Tabs without pi-kit's desk bridge cannot be reloaded from
pi-desk; the bar says so: type `/reload` in them.

**Reload all pi tabs** (the gear, or ⌘K) reloads every running pi tab the same way, changed or
not.

**After a pi update.** pi-desk notes which pi version each tab started with. When pi on disk is
updated (for example `npm install -g` or `brew upgrade`), a bar says "pi updated to 1.5.0 —
Restart 2 idle tabs". **Restart** starts each idle tab's pi again on the same session; busy tabs
restart once idle, with the same warning about background work. **Later** hides it until the
next version. Before stopping a tab, pi-desk asks its pi once more whether it is idle; if not,
the tab waits. Atlas is a pi tab like the others: it is reloaded or restarted when idle, its
session stays.

Not counted as changes: `node_modules` and `.git` folders, and the keys pi writes into
`settings.json` itself (the model and thinking level you last picked, the changelog it showed,
its device id).

## Atlas

Atlas is pi-desk's built-in assistant: its own pi, running in the drawer, that can see and drive
pi-desk for you ("open the api project's last session", "which sessions are waiting?", "tell me
when the build session finishes").

- **To open or hide the drawer**, press ⌘J, or click Atlas at the far right of the top bar. If
  the drawer is open but the keyboard is elsewhere, ⌘J gives it the keyboard first. ⌘W hides it
  too. Clicking in the centre hides a sliding drawer.
- **To pin it** as its own column, click 📌 in its header (the palette: "Dock the agent's
  drawer"). Click again to slide it over the right side again.
- **To resize it**, drag its left edge; double-click the edge to reset.
- **The header** shows its status (starting…, working…, needs you, error, stopped) and its model.
- The top bar's Atlas button counts the runs that finished while the drawer was shut, and is
  tinted while Atlas waits for you. While pi-desk is in the background, Atlas finishing or
  asking raises a macOS notification (gear: **Agent notifications**).

### Its model

Click **Model** in the drawer's header (or the gear's **Atlas model…**, the palette's "Atlas:
change model", or Settings → Atlas → **Change…**). It opens pi's own model selector (Ctrl+L) in
Atlas's terminal. Your pick stays with Atlas's session.

The `agent_model` setting ("provider/id", optionally ":thinking") is the model Atlas starts a
new session with; when it changes, Atlas uses it from its next start.

### Its prompt

- **ATLAS.md** is added to pi's system prompt for Atlas only. It lives in the atlas folder
  (`<main folder>/atlas/ATLAS.md`) once the main folder is set (pi-desk copies the data dir's
  `atlas/ATLAS.md` there the first time, never over a file, and keeps the old one as a
  fallback); without a main folder, the data dir's copy is used and the drawer says so in a
  line with **Set up pi-desk…**. Edit it in Settings → Atlas, or with the palette's "Atlas: edit prompt". Save, then
  click **Reload** in the [hot-reload bar](#hot-reload) ("Atlas's prompt changed").
- Your global **APPEND_SYSTEM.md** (pi's folder) is still added for Atlas, before ATLAS.md, as
  pi would.
- pi-desk writes a starter ATLAS.md when there is none. When a pi-desk update ships a newer
  starter, pi-desk replaces your file only if you never edited it (it keeps the old one as
  `ATLAS.md.bak-<date>`). If you edited it, it is left alone. To get the newest starter
  anyway, rename your file in Finder (to keep it), click **Create** on ATLAS.md in Settings →
  Atlas, then **Reload** in the hot-reload bar.
- This guide is copied to `atlas/GUIDE.md` in the data dir on every start, and Atlas is told
  where it is, so it can answer "how do I…" questions.

### What Atlas can do

Atlas uses pi-kit's **desk tools**; each tool's description in pi lists exactly what it accepts.
In short, Atlas can:

- look at what is open (projects, sessions, tabs, panels, status);
- do what you can do in the window: open, start, focus and close sessions and tabs, open files,
  change the layout and the look;
- send a prompt to another session, and wait for it to finish;
- **watch** a session when you ask ("tell me when it finishes / needs me / exits"): it gets one
  message when that happens and tells you (`desk_watch`; at most 5 at a time);
- tell you **what happened while you were away**, from the bell's entries (`desk_events`).

What it cannot do:

- **Confirm for you.** Anything that needs confirmation (closing a running tab, quitting,
  reloading pi, deleting files) shows the confirmation bar, and by default only you can click
  Confirm.
- Change your own settings that limit it (its model, its name, notifications, confirmation
  rules), hide its own drawer, or act on its own session.
- See credentials: it never gets tokens, and pi-desk never shows sign-in files.
- Know about changes by itself. pi-desk never pushes status updates to Atlas; you see them in
  the bell. Atlas only hears about a session when you asked it to watch it.

### Restarting Atlas

- If Atlas is stuck mid-answer, press Esc in its terminal (as in any pi).
- To reload its prompt, settings and extensions, type `/reload` in its terminal, or save
  ATLAS.md and click **Reload** in the [hot-reload bar](#hot-reload).
- If it stopped ("Atlas stopped"), press ⌘J twice: the drawer closes and opens again, and Atlas
  starts again, resuming its session.

## Jobs

A job is a prompt that pi runs for you, on a schedule or when you click **Run now**, while
pi-desk is open: "every weekday at 7, list the pull requests waiting on me", "every hour, check
the build". Each run is a fresh, one-shot pi that cannot ask you anything; it finishes and
reports. There are no jobs until you make one.

### The Jobs tab

Click **Jobs** at the top of the left column (palette: "Show jobs"). Job notes live in the jobs
folder (`<main folder>/jobs/`); without a main folder the tab says so and offers **Set up
pi-desk…**. The header has **New job** (+, the [job sheet](#the-job-sheet)), **Pause all** /
**Resume all** and **Limits**, and the count of unread runs.

Jobs are grouped by **who they belong to**: each of your projects that has jobs (by name), then
**Atlas**, **Chats** and **Other**. A group's row shows its name and how many jobs it has (a dot
while one has an unread run). Click its chevron to fold it; click the row to go to the project
(its sessions in the Sessions tab), to Atlas (the drawer) or to Chats; on Other it folds. Hover it
for **+**: a new job for that group. Folding lasts until pi-desk quits.

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
an error on the row, and the job does not run. Below the prompt pi-desk keeps `## Recent runs`,
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

pi-desk keeps nothing about jobs in your macOS Keychain. Older versions kept a "pi-desk jobs
approval key" there; it is no longer used, and you may delete it in Keychain Access.

### Running

- **Run now** runs it at once (also a paused or disabled job, when you click it). **Stop** ends
  a run (pi and everything it started).
- **Pause** / **Resume** one job, or **Pause all** / **Resume all** in the header (the palette:
  "Pause all jobs", "Resume all jobs", "Stop all running jobs"). Running runs finish.
- A run that was due while your Mac slept or pi-desk was closed runs late if it is only a little
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
- **macOS notifications** while pi-desk is in the background: runs that need you or failed come
  through the bell's notifications; a finished run raises one only with `notify: always`.
- A run's files live in pi-desk's data dir, `jobs/<id>/runs/<time>/` (**Open run folder**): its
  report `summary.md`, `meta.json`, pi's events and errors. Runs older than 30 days (or beyond
  the newest 100) are removed. Secrets that look like API keys are redacted from reports.
- Atlas does not get job results pushed to it; ask it ("what did my jobs report?") and it reads
  them.

### What a job may do

`access: read` runs pi with its read-only tools (read, grep, find, ls) and pi-kit's read-only
mode. `access: full` runs pi with its normal tools and guardrails: an action the guardrails
would ask you about is blocked instead, and the run reports it under "Needs you". A job never
gets pi-desk's control socket, so it cannot create jobs through pi-desk (its prompt also tells
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
  Waiting, Errors (errors and exits) and Jobs. Something you asked for that pi-desk could not do
  (Send to Atlas's text left on the clipboard, and why) always shows in the bell, even with Errors off.
- **macOS notifications** (gear: **Also notify in macOS**, on by default): while pi-desk is in the
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
- **Rescan sessions**, **Reload all pi tabs** (see [Hot reload](#hot-reload)), **Keyboard
  shortcuts** (⌘/) and **Edit settings files…** (⌘,).
- **Set up pi-desk…**: the [first run](#the-first-run) sheet again (main folder, chats).
- **Tidy project list**: hide temp and missing folders, nest subfolders and group sibling folders (see
  [A tidy project list](#a-tidy-project-list)). On by default.

## Your data

### Where it lives

pi-desk's data dir is `~/Library/Application Support/pi-desk` on macOS (Linux:
`~/.local/share/pi-desk`; the `PI_DESK_DATA_DIR` environment variable moves it). It is private
to you (`0700`), and its files are `0600`:

| File | What |
|---|---|
| `workspace.json` | open sessions, tabs, projects you added, pins, hidden rows, sort, layout and settings |
| `session-titles.tsv` | a cache of session titles, so start-up does not reread every session |
| `commands.log` | every command run, one JSON line each, rotated at 10 MB (`commands.log.1`, `.2`) |
| `atlas/ATLAS.md` | Atlas's prompt (yours to edit) until a main folder is set; then the fallback |
| `atlas/GUIDE.md` | this guide, rewritten by pi-desk on start (do not edit) |
| `home/` | Atlas's own pi sessions |
| `jobs/<id>/` | each job's state, its runs (`runs/`) and pi's sessions of them (`sessions/`) |
| `jobs/scheduler.log` | what the scheduler did: runs started, skipped and why |

Elsewhere:

- **pi's sessions** stay in pi's store, `~/.pi/agent/sessions`. pi-desk reads them; it never
  writes or deletes them (closing a session keeps its file).
- **Your folders**: notes, jobs, memory, Atlas's prompt and chats live in the main folder (see
  below). These are yours: pi-desk's data dir above is machine-only state.
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
  and pi-desk **never moves files**: when you pick another main folder, the old one stays where
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
  your own environment sets `PI_KIT_NOTES_DIR` (pi-desk's, or your login shell's), yours wins:
  pi-desk passes it on unchanged, and the Folders group shows it as a **PI_KIT_NOTES_DIR**
  row. At start, scheduled jobs wait for your login shell's answer (up to 10 seconds) so a job
  due at launch gets your value, not the main folder.
- **Chat instructions**: pi-desk writes a starter `AGENTS.md` into the chats folder when it has
  none (at start once a main folder is set, at setup, when the chats folder changes, and on the first chat), never over a
  file and never beside an `AGENTS.override.md` or `CLAUDE.md` there (pi would read those
  instead). It never writes one when the chats folder is your home folder, `/`, or a folder
  that holds a project or a job's folder: pi applies `AGENTS.md` to every folder below it, so
  those pi tabs would be told they are not coding agents. Settings → Chats → **Chat
  instructions** still offers **Create** there if you want it. When an update ships a newer starter, pi-desk replaces yours only if you never
  edited it (keeping `AGENTS.md.bak-<date>`).

### What is stored about your sessions

- `session-titles.tsv` holds, per session file: its path, size, the name you gave it, and the
  **first 200 bytes of your first message** (used as the title). It never holds the rest of a
  session.
- `workspace.json` holds session ids and folders, never their content, tokens or typed text.
- `commands.log` holds commands with paths, project names and session titles; the text of
  prompts and pasted text is replaced with `<redacted N bytes>`.

### Privacy

- pi-desk never shows, opens or logs credential files (pi's sign-ins, private files in pi's
  folder, `.env`), not in the Settings tab, the Files tab's editor, or to Atlas.
- Connection tokens for the control socket are never logged or saved.
- pi-desk has no network code of its own: only pi (and its extensions) talk to model providers.

### Backups

To back up pi-desk, copy the data dir (with pi-desk closed) and `~/.pi/agent` (pi's sessions and
settings). Your projects are your own folders. pi-desk itself keeps:
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
never starts, check that `pi` runs in a Terminal (pi-desk starts it through your login shell).

**A pi tab is stuck.** Click into the tab and press Esc (pi's interrupt). If pi itself hangs,
close the session from its row (**×** or **Close session**; it asks first) and open it again
from the list: pi resumes it from its file.

**A session shows "Session gone".** Its session file or folder no longer exists; click the button
to close it.

**Where are the logs?** `commands.log` in the data dir (every command and its result). Errors at
start-up go to the terminal you started pi-desk from. A pi session's own logs are pi's.

**To reset the layout**, start pi-desk with `--fresh` (`build/pi-desk --fresh`): it starts with
nothing open and keeps the old workspace as `workspace.json.bak-<time>`. To reset just one
column's width, double-click its edge.

## All shortcuts

pi-desk has a macOS **menu bar**, built from the same action table (`src/actions.odin`,
`src/menubar.odin`) as the palette (⌘K) and the shortcuts sheet (⌘/), so the three always agree.
Items that do not apply right now are greyed out (Save without unsaved changes, Close tab on the
pi tab), and switches show a checkmark (the columns, Atlas, the appearance and the look).

A shortcut works the same whether you press it or pick its menu item, and it goes first to
whatever has the keyboard: ⌘C copies from the text field, the editor or the terminal you are in;
⌘W in Atlas's drawer hides the drawer. Keys that belong to the terminal (⌘⌫, ⌘←, ⌘→ and the ⌥
keys) have no menu item and always reach the terminal. The tables below follow the menus.

**pi-desk**

| Menu item | Shortcut | Notes |
|---|---|---|
| About pi-desk |  | |
| Settings… | ⌘, | the left column's Settings tab (again: back to Sessions) |
| Set up pi-desk… |  | the first-run sheet: main folder, chats (see [the first run](#the-first-run)) |
| Hide pi-desk | ⌘H | |
| Hide others | ⌥⌘H | Show all brings them back |
| Quit pi-desk | ⌘Q | asks while sessions run |

**File**

| Menu item | Shortcut | Notes |
|---|---|---|
| New chat | ⌘N | |
| New session in project | ⇧⌘N | in the selected project |
| New shell tab | ⌘T | |
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
| Next tab, Previous tab | ⇧⌘], ⇧⌘[ | round the session's tabs |
| Tab 1, Tab 2, Tab 3, Tab 4, Tab 5, Tab 6, Tab 7, Tab 8, Tab 9 | ⌘1, ⌘2, ⌘3, ⌘4, ⌘5, ⌘6, ⌘7, ⌘8, ⌘9 (⌘1–⌘9) | in the palette: run its rows |
| Next session, Previous session | ⌥⌘↓, ⌥⌘↑ | in the Open section's order |
| Bring all to front |  | |

**Help**

| Menu item | Shortcut | Notes |
|---|---|---|
| pi-desk user guide |  | this guide, in a Markdown tab (Atlas's copy in the data dir) |
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
| New session | ⇧⌘N | a new session in the selected project |
| Chats: read-only |  | start chats read-only or as full pi |
| Chats folder… |  | pick the folder chats run in |
| Chats folder: back to the default |  | undo the above |
| New shell tab | ⌘T | a shell in the session's folder |
| New browser tab |  | a web page in the session on screen (its address field takes the keyboard) |
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
| pi-desk user guide |  | this guide in a Markdown tab |
| Markdown preview | ⇧⌘V | a `.md` file as a document, or its source |
| Open in editor |  | edit the Markdown tab's file in an editor tab |
| Edit settings files… | ⌘, | the Settings tab |
| Edit pi settings (settings.json) |  | |
| Edit pi models (models.json) |  | |
| Edit global AGENTS.md |  | |
| Edit project pi settings (.pi/settings.json) |  | |
| Keyboard shortcuts | ⌘/ | the shortcuts sheet |
| Look: Graphite, Look: Warm, Look: Ghostty |  | the look |
| Appearance: System, Appearance: Light, Appearance: Dark |  | light or dark |
| Text size: Small, Text size: Medium, Text size: Default, Text size: Large |  | the chrome's text size |
| Reduce motion |  | |
| Rescan sessions |  | read pi's store again |
| Tidy project list |  | on or off: see [A tidy project list](#a-tidy-project-list) |
| Reload all pi tabs |  | `/reload` every idle pi tab, busy ones once idle ([Hot reload](#hot-reload)) |
| Restart pi tabs on the new pi |  | after a pi update: restart idle pi tabs on their sessions |
| Add project… |  | pick a folder |
| Rename project |  | rename the selected project |
| Filter projects and sessions | ⌘⇧F | |
| Clear filter |  | |
| Filter: running, Filter: waiting for you, Filter: pinned |  | the quick filters |
| Show hidden projects and sessions |  | |
| Pin project, Unpin project, Hide project |  | the selected project |
| Pin session, Unpin session, Hide session |  | the session on screen |
| Sort projects (next order), Sort sessions (next order), Sort chats (next order) |  | Recent → Name → Created |
| Quit pi-desk | ⌘Q | |
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
| Set up pi-desk… |  | the first-run sheet (main folder, chats, summary) |
| Main folder… |  | pick the main folder |
| Edit chat instructions |  | the chats folder's AGENTS.md |
| Pause all jobs, Resume all jobs |  | the kill switch for jobs |
| Stop all running jobs |  | |

## Coming soon

Work in progress on other branches; this guide covers each once it ships:

- **Jobs while pi-desk is closed** (a background helper), heartbeat and no-agent check jobs,
  and Atlas's shared memory (design: [ATLAS.md](ATLAS.md)).
- **Merging** from the Changes tab.
