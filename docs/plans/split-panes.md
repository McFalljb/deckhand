# Deckhand split panes: implementation plan

Status: P1 in progress (branch `panes-p1`); the rest is plan. Investigated at `main` 7904ea7. fff MCP tools were not
available to the worker, so searches used `rg` (read-only).

Revision 2 (after review): the implicit `pane_ctx` is gone. `active_tab()`, `key_tab()`,
`key_term()`, every tick and every action mean strictly **the focused pane's tab**. An explicit
`^Pane` is threaded only through the bounded layout/event layer (the per-tab bar procs called
from `centre()` and the per-kind handlers in `event()`). Tick loops become per tab with two
helpers, `tab_focused` and `tab_on_screen`. Also fixed: pointer capture (H2), click-to-focus vs
`drags_follow_focus` (H3), exact tick flips per phase (M1, M5), per-tab bar guard (M2), field
ownership (M3), id/hit-test budget (M4), pane rect source (M6), restore details (L1–L3),
divider sizing (L4), P1 tests and caller rule (L5).

Decided by the user (binding): free splits (right/down, nested, draggable dividers); a tab strip
per pane (drag a tab to a pane edge to split, onto another pane to move it; commands and keys
too); a layout per open session, saved and restored; every tab kind may sit in a pane, browser
and app tabs included.

---

## 0. What assumes one pane today (inventory)

| Area | Where | Assumption |
|---|---|---|
| The content rect | `App.pane` (`src/main.odin:30`), set each frame from `ui_terminal_rect()` (`src/ui.odin:1142`, Clay element `"terminal"`) | one rect for the current tab |
| Drawing | `frame()` `src/main.odin:265-278`: `tab_host(tab.kind).draw(active_tab(), app.pane…)` | one tab drawn |
| Terminal sizes | `src/main.odin:252-256` resizes **every** terminal of the current session to `app.pane` (except while a Changes tab shows); `new_term` (`src/commands.odin:2155`) sizes a new PTY to `app.pane` | one grid size per session |
| Active tab | `Open_Session.active_tab` (`src/state.odin:134`); `cur()`, `active_tab()`, `active_term()`, `key_tab()`, `key_term()` (`src/state.odin:385-418`) | one per session |
| Derived "the tab on screen" | `tab_editor()` (`src/editor.odin:110`, 28 uses), `tab_browser()` (`src/browser.odin:131`, 32 uses), `tab_app()` (`src/app_tab.odin:322`, 10), `active_changes()` (`src/ui_changes.odin:81`, 15), `md_preview_shown()`; `active_tab()` 24 uses; `s.active_tab` 49 uses in 22 files; ~30 writers `s.active_tab = …` (commands.odin, editor_commands.odin, app_tab.odin:433, browser.odin:148, claude.odin:927/959/992, changes.odin, markdown_view.odin, show_file.odin:118) | |
| "On screen" checks | `status_on_screen`/`status_seen`/`status_wants_seen` (`src/agent_status.odin:493-510`), `notify_on_screen`/`notify_pi_shown` (`src/notify.odin:273-284`), `browser_agent.odin:678` (`on_screen` in `browser_tabs`), `browser_act.odin:526`, `app_frames_tick` `visible := a == tab_app()` (`src/app_tab.odin:1082`), `app_screenshot`/`app_shot_now` `"visible"` (`:1454`, `:1470`), `browser_tick`/`browser_frames_tick`/`browser_pages` `on_screen := tab_browser()` (`src/browser.odin:398-640`), `browser_page_plan` "the tab on screen" (`src/browser_nav.odin:586`) | exactly one visible tab |
| App tabs | ring sized to `app.pane` (`app_tab.odin:1104-1108`, `:2185`); `in_tab`, `app_event` coords from `app.pane` (`:1806-1822`); `app_focus_tick` keyboard focus = `tab_app()`; `tab.visible` told = visible‖peek; test-mode `app_script` coords (`:2289-2345`) | |
| Browser tabs | CEF view size `app.pane/dpi` (`browser.odin:579-592`, `:630`); `in_page`/`browser_event` coords (`:735-760`); `pd_cef_set_hidden`, `pd_cef_focus` from `hidden := b != on_screen`; script coords (`:1071-1101`); polish/annotate overlays use `app.pane` (`browser_polish.odin:1162,1661,1950`, `browser_annotate.odin:696-744,976`) | CEF is windowless (off-screen, texture) so any rect works; 8 CEF slots app-wide |
| Editor | `editor_view.odin:71` global `last_area {tab, m}` (one editor's metrics); `editor_text_hit` uses `clay.ID("terminal")` (`:461-467`); `editor_bars_layout()` for `tab_editor()` | one editor drawn |
| Per-tab bars | `centre()` (`src/ui.odin:497-540`): `claude_bars`, `app_bar_layout`, `dead_tab_bar_layout`, `browser_bar_layout`, `changes_bars_layout`, `editor_bars_layout`, `changes_list_layout`, `changes_file_bar_layout`, `changes_more_layout`; empty/"gone" states | for the active tab; global Clay ids (`br_url_box`, `ed_tool`, `chtool`…) |
| Singleton fields | `browser_url_field` (`browser_nav.odin:378`, `browser_url_check`), `page_find_field`, `page_prompt_field` (`browser_polish.odin:484-486`), `changes_message_field`, editor find bars; `state.focus_widget` | bound to the tab on screen |
| Tab strip | `tab_strip()` (`src/ui.odin:611-700`) is also the window title bar (`main`/`tabs` elements, window drag on empty parts `main.odin:560`); ids `clay.ID("tab", i)`/`("tabclose", i)` by index in `s.tabs`; hits `Hit_Tab`/`Hit_Close_Tab` (`ui.odin:1091-1092`); `tab_max_w`, `top_bar_fixed_w` | one strip |
| Input routing | `event()` (`src/main.odin:291-675`): editor/markdown/annotate/browser/app handlers each take "the tab on screen"; `in_pane(t,…)` (`term.odin:697`) for the active term; scroll to `active_term()`; drops `sidebar_drop` (`ui_sidebar.odin:1525`) into `active_term()`; `drags_follow_focus` (`main.odin:282`) | |
| Keys | `⌘1–9`→`tab_nth`, `⇧⌘[ ]`→`tab_step` over `cs.tabs` (`actions.odin:443-453, 627`), `⌘W` closes `active_tab` (`actions.odin:161`, `main.odin:479`), `⌘T` new shell in the session | session-wide |
| Dividers | `divider` (`ui_sidebar.odin:65-160`): 3 column dividers, `Hit_Divider`, `RESIZE_THROTTLE` for PTYs only while `divider.active` (`term.odin:329`) | columns only |
| Right column | `right_panels_tab(s)` (`claude_panels.odin:452`): the active tab if Claude, else pi tab | follows the active tab |
| Persistence | `workspace_json` (`persist.odin:200-292`): `tabs` + `active_tab` index; load (`persist.odin:700-760`) → `Restore_Tab{active}` → `Restore_Session` (`commands.odin:288-310`, apply `:1515-1600`); `persist.focus_tab` → `persist_after_layout` | `WORKSPACE_VERSION` mismatch moves the file aside (`persist.odin:591-593`) |
| Snapshot | `json_write.odin:1158` `active_tab`, tabs `:1190-1270`, `focus.tab_id` `:1316-1320` | |
| Agents | `integrations/pi/lib/state.ts:69` "[active]"; `integrations/pi/lib/commands.ts` mirrors the command table; `tools/pi-desk-cli/format.odin` `on_screen`; `browser.ts`/`app.ts` "not on screen" texts | |
| Test mode | `autotest.odin` `$tab` = `cs.active_tab` (`:1255`), `clickid tab N`, `rclickid terminal` (12 uses), `divider N DX` (`:778`), `web_*`/`app_*` script commands act on `tab_browser()`/`tab_app()`; 10 scripts assert `open_sessions.N.active_tab` (plus `restore.sh` writes it in a fixture) |
| Other ticks keyed to "the tab on screen" | `editor_tick` gutter/reparse via `active_editor()` (`editor_watch.odin:104-130`, `editor.odin:117`); `shot_step` (`browser_agent.odin:1234`, hidden-tab screenshots); `browser_polish_tick` zoom/devtools and find/prompt field ownership (`browser_polish.odin:1342-1415`); `browser_polish_pending_tick` bar guard `bars_note`/`page_bars_tab` (`browser_polish.odin:291-330`, `:1420`); `browser_tick` `lazy`/`shown_at` (LRU for page eviction) (`browser.odin:552-560`); `browser_url_check`/`browser_url_tab` (`browser_nav.odin:380-480`); `term_links_frame` (`term_links.odin:412`) | one tab | |
| Layout tests | `layout_audit_test.odin` (no overlapping text, 4 widths × every look), `buttons_test.odin` (tab close hits by index) | |

Home (Atlas's session, `s.home`) is only the drawer: it is never split. Commands refuse it as
`focus_tab` does (`HOME_NOT_A_SESSION`).

---

## 1. Data model

### 1.1 Types (`src/state.odin`)

```odin
Pane :: struct {
	id:     u64, // new_id(); runtime only
	active: u64, // tab id shown in this pane (always one of its tabs)
	rect:   [4]f32, // last laid-out rect of the pane's CONTENT container (pid(p, "pane_body")), not
	                // of the inner "terminal" element (a Changes tab's list narrows that); {} = not laid out
	slot:   int, // ordinal among the session's leaves, left-to-right/top-to-bottom (Clay ids, scripts)
}
Split_Dir :: enum { Right, Down } // Right: children side by side (vertical divider); Down: stacked
Layout_Node :: struct {
	id:    u64, // splits get ids too (set_split addresses them); leaves: the pane's id
	leaf:  bool,
	pane:  u64, // leaf
	dir:   Split_Dir, // split
	ratio: f32, // split: share of child a, clamped by min sizes
	a, b:  int, // split: indices into nodes
	parent: int, // -1 = root
}
Tab :: struct { ..., pane: u64 } // the pane this tab lives in
Open_Session :: struct {
	...,
	tabs:         [dynamic]Tab, // unchanged: master list; pi/Claude main tab stays tabs[0]
	active_tab:   u64, // KEPT: always == the focused pane's active (a mirror; see 1.2)
	panes:        [dynamic]Pane,
	nodes:        [dynamic]Layout_Node, // binary tree, nodes[root]
	root:         int,
	focused_pane: u64,
	pane_mru:     [dynamic]u64, // focus history: where focus goes when a pane closes
}
```

Why `Tab.pane` instead of a tab-id list per pane: a pane's strip order is `s.tabs` filtered by
`pane`, so `close_tab`, `tab_free_kind`, persistence and every loop over `s.tabs` keep working,
there is no second list to keep consistent, and the "pi tab is `tabs[0]` and cannot close" rule
is unchanged (it is first in whichever pane holds it). Reordering/moving = moving the element in
`s.tabs` and setting `pane`. **The pi/main tab stays `tabs[0]`**: every move/reorder clamps
its target index in `s.tabs` to ≥ 1 for any other tab, and the pi tab itself is never moved
within `s.tabs` (only its `pane` changes). Strip positions are computed within the pane, then
mapped to an `s.tabs` index ≥ 1 (test in P2: move a shell before the pi tab in the same pane
and into the pi tab's pane at index 0 → it lands after the pi tab; `tabs[0]` unchanged).

Binary tree (tmux/VS Code-like behaviour, simplest resizing: one divider = one split node =
one ratio). A flat array with indices: no pointers, trivial to clone, save and test. Splitting a
pane in the same direction as its parent nests (the divider resizes just that pair);
`equalize_panes` rebalances.

### 1.2 Invariants (checked by `session_check(s) -> string` in tests, after every command)

1. Every tab has `pane` = an existing pane of its session; every pane has ≥ 1 tab.
2. `pane.active` is one of the pane's tabs; `s.active_tab == pane_of(s.focused_pane).active`.
3. The tree's leaves are exactly `s.panes`; ratios in `[RATIO_MIN, 1-RATIO_MIN]`.
4. `len(panes) ≤ PANES_MAX` (8 per session, proposed).
5. Home: exactly one pane, never split.

All writes go through a few helpers (new `src/panes.odin`):

- `session_show_tab(s, tab_id, focus := true)` — sets the tab's pane `active`; with `focus`
  also `focused_pane` and the `s.active_tab` mirror. Replaces the ~30 `s.active_tab = x`
  writes. A **background** open (agents, `browser_open` behind, `show_file` from an agent) goes
  through `pane_add_tab` only and **never sets `pane.active`** (nor the focus or the mirror),
  whether or not the pane is on screen — today a background open never changes the active tab
  either.
- `pane_add_tab(s, tab, pane := 0, after := 0)` — every `append(&s.tabs, tab)` (new shell,
  editor, browser, app, Claude, markdown, changes, show_file's `inject_at`) gives the tab a
  pane: default the focused pane, or the pane of the tab it opens "after" (show_file).
- `pane_tab_gone(s, tab_id)` — in `Close_Tab` (`commands.odin:869-897`): the next tab **of the
  same pane** takes over (today's `min(i, len-1)` rule within the pane); an emptied pane
  closes (1.3).
- `pane_split`, `pane_close`, `pane_move_tab`, `pane_neighbour(s, pane, dir)`, `pane_rects(s,
  rect) -> map/slice` — pure tree operations, unit-tested without UI.

### 1.3 Pane lifecycle rules

- **Split** a pane (direction right/down): the pane's leaf becomes a split node with the old
  pane as `a` and a new pane as `b` (ratio 0.5). The new pane gets a tab (see open question Q1:
  default = a new shell tab in the session's folder; "move tab to new pane" is a separate
  command and what a drag does). Refused if either half would be under the min size or at
  `PANES_MAX`.
- **Close / empty pane**: when the last tab leaves a pane (closed or moved away), the pane is
  removed and its sibling subtree takes the parent's place; focus goes to the most recent pane
  in `pane_mru` (else the sibling). A pane holding the pi tab never empties by closing.
- **`close_pane` (unsplit)**: non-destructive: its tabs move to the sibling's nearest pane
  (appended, the moved active stays active there), then the pane is removed. No confirmation
  needed (nothing stops).
- **Window shrink**: ratios stay; rects clamp at min sizes; if the centre is smaller than the
  tree's minimum, panes are squeezed below min (never hidden) — the layout audit covers the
  narrowest width.

### 1.4 Saving (`src/persist.odin`, `docs/PERSISTENCE.md`)

Keep `WORKSPACE_VERSION` = 1 (a bump would make older builds move the file aside). Add one
optional key per saved open session; older builds ignore it and still read `active_tab`.

```json
{"pi_session_id":"…","tabs":[{"kind":"pi"},{"kind":"shell",…},{"kind":"browser",…}],
 "active_tab":2,                              // KEPT: the focused pane's active tab (saved index)
 "panes":{"tree":{"split":"right","ratio":0.55,"a":{"pane":0},"b":{"pane":1}},
          "tab_pane":[0,0,1],                // per saved tab: its pane (saved pane index)
          "active":[0,2],                    // per pane: saved tab index
          "focused":1}}
```

- Writer: indices are positions in the saved `tabs` list (as `active_tab` already is). Panes
  numbered in leaf order. Ratios rounded to 3 decimals. `panes` omitted when a session has one
  pane (single-pane files stay byte-identical to today: no churn in existing fixtures).
- Loader: `Restore_Tab` gains `pane: int` (from `tab_pane[j]`, read **before** skipped tabs
  shift positions — today's loader already indexes by the saved `j`) and `pane_active: bool`.
  The pi/main tab is not a `Restore_Tab` (Restore_Session creates it as `tabs[0]`), so
  `Restore_Session` gains `pi_pane: int` and `pi_active: bool` (from `tab_pane[0]` and
  `active[k] == 0`), plus `layout: Restore_Layout {tree, focused}` (pure data). The apply in
  `commands.odin` builds panes; then **repairs**: tabs whose pane is unknown go to the focused
  (else first) pane; a pane whose saved active tab was dropped (failed restore) falls back to
  its **first** tab; panes left without tabs are dropped and the tree collapsed; bad ratios
  clamped; depth/pane count over `PANES_MAX` → everything into one pane; any parse error →
  single pane (never fails the restore). App tabs are not restored today (only `kind`), so
  their panes may vanish: handled by the repair. Fixtures include **the pi tab in pane 1**
  (not the first leaf) and a pane whose active tab failed to restore.
- **Migration** from today's files: no `panes` key → one pane with every tab, active =
  `active_tab` (exactly today's behaviour). Unit fixtures in `persist_test.odin`: old file,
  new file round-trip, corrupt `panes` variants, a pane whose only tab failed to restore.
- Not saved: pane ids, rects, MRU, drag state.
- **Release note**: an older Deckhand reading a file with `panes` silently drops the layout
  (every tab back in one pane, the focused pane's tab active); saving from it removes the key.
- `Restore_Session` is also logged (`json_write.odin:565`): add `pane` per tab and the tree.

---

## 2. Visibility and focus model

No implicit context. Two helpers decide everything outside the layout/event layer, and the
existing accessors keep exactly one meaning:

| Term | Meaning | Helper |
|---|---|---|
| **focused** | the active tab of the focused pane of the current session. `s.active_tab` mirrors it. Keyboard, CEF/app input focus, `focus_widget` owners, the right column, every action and menu item, test-mode `web_*`/`app_*` | `tab_focused(tab_id) -> bool`; `active_tab()`, `key_tab()`, `key_term()`, `tab_editor()`, `tab_browser()`, `tab_app()`, `active_changes()`, `active_editor()` all mean **only** this, everywhere |
| **on screen** | the active tab of **any** pane of the current session | `tab_on_screen(tab_id) -> bool` |
| **pointer owner** | the pane/tab a press started in (capture), else the pane under the pointer | `pane_at(x, y) -> ^Pane`, `pointer` capture (§3.4) |

Ticks never ask "the tab on screen": they loop over tabs and ask one of the two helpers.

### 2.1 What flips when (M1, M5)

**P1** (one pane: `tab_on_screen == tab_focused`, so no behaviour changes, but the loops are
already per tab and the right helper is chosen):

| Tick / check | Helper from P1 | Why that one |
|---|---|---|
| `status_on_screen`, `status_seen` (all on-screen tabs), `status_wants_seen` (list), `notify_pi_shown`, `notify_on_screen` | `tab_on_screen` | bell/unread: the user can see it (Q7) |
| `app_focus_tick` keyboard focus | `tab_focused` | keyboard |
| `browser_tick` `focused`/`pd_cef_focus`, `release_input` | `tab_focused` | keyboard |
| `browser_url_check`, `browser_polish_tick` find/prompt ownership | own tab id (`browser_url_tab`, `page_find_tab`, `page_prompt_tab`) + `tab_focused` (M3, below) | a field belongs to its tab |
| `editor_tick` gutter/reparse (`active_editor()`) | `tab_focused` in P1; on screen in P4 | typing happens in the focused one |
| `term_links_frame` | pointer owner's terminal | hover |
| `drags_follow_focus` | per tab, see H3 (§3.4) | |

**P4** (live content in unfocused panes) — these switch from `tab_focused` to `tab_on_screen`;
until P4 they stay on `tab_focused`, which is why P2 needs the placeholder:

| Tick | File | Change in P4 |
|---|---|---|
| `app_frames_tick` `visible`, `peek`, ring sizing, `tab.visible`, stall pings | `app_tab.odin:1039-1170` | per tab `tab_on_screen`; ring = its pane's rect |
| `app_screenshot` hidden path / `"visible"` meta | `app_tab.odin:1449-1470` | `tab_on_screen` |
| `browser_tick` `hidden`, `pd_cef_set_hidden`, view size, **`lazy = false` and `shown_at = now` for every on-screen page** (`shown_at` is the LRU the page plan evicts by) | `browser.odin:552-592` | per tab `tab_on_screen`, its pane's rect |
| `browser_frames_tick` frame take vs release | `browser.odin:398-420` | `tab_on_screen` |
| `browser_pages` `Page_Info.visible`; `browser_page_plan` with several visible | `browser.odin:595-640`, `browser_nav.odin:586` | `tab_on_screen` |
| `shot_step` hidden-tab screenshot painting | `browser_agent.odin:1234` | hidden = `!tab_on_screen` |
| `browser_tabs` `on_screen`, `browser_act.odin:526` | | `tab_on_screen` |
| `browser_polish_tick` zoom and devtools per page | `browser_polish.odin:1342-1395` | applied to every on-screen page (zoom is per tab already; the tick must not only touch the focused one) |
| `browser_polish_pending_tick` bar click guard `bars_note`/`page_bars_tab` (M2) | `browser_polish.odin:291-330, 1420` | `page_bars_tab` (one global) becomes a per-tab "bars on screen since" stamp: `bars_note(tab_id)` for **every** on-screen browser tab each frame; a tab that leaves the screen clears its stamp so coming back restarts `BARS_GUARD` |
| `editor_tick` git gutter / slow reparse | `editor_watch.odin:125-135` | every on-screen editor (so an unfocused pane's editor still gets its gutter after an outside change) |
| frame redraw trigger and `t.changed = false` | `main.odin:213, 300` | every on-screen terminal: set `changed` triggers redraw, and **every on-screen term's `changed` is cleared** after the draw (M6; today only `t`/`at`) |

### 2.2 P2 placeholder (until P4)
A browser or app tab active in an **unfocused** pane draws its last frame dimmed with "Click to
show". Its click is swallowed: it only focuses the pane (never reaches the page/app), and the
tab does not count as seen (the unread/bell rule uses `tab_on_screen` minus placeholder tabs
until P4: `tab_on_screen` returns false for a placeholder-shown texture tab in P2). Removed in P4.

### 2.3 Other effects
- **Browser input**: `browser_event(b, p, e)` gets the target explicitly: mouse → the pointer
  owner's page (after click-to-focus), keys → the focused one. Overlays (annotate, polish bars,
  agent-click rings) take the pane's rect instead of `app.pane`.
- **App input**: `app_event(a, p, e)` likewise; coordinates from `p.rect`.
- **Terminals**: every tab of the current session gets **its pane's** rect each frame (hidden
  tabs too, so switching tabs within a pane never reflows); moving a tab to another pane
  resizes its PTY once. The "skip while a Changes tab shows" exception goes away because
  `pane.rect` is the pane's content container (M6). `term_focus` (DECSET 1004) follows the
  focused pane. Unfocused panes draw a hollow cursor.
- **Editors/Markdown/Changes**: drawn per pane via `tab_host(kind).draw(id, p.rect)`; editor
  `last_area` moves into `Editor` (per tab).
- **Right column**: unchanged (focused tab: Claude → its panels, else the pi panels).
- **Window title**: unchanged (session-based).

---

## 3. Subsystem changes (by file)

### 3.1 New `src/panes.odin` (+ `src/panes_test.odin`)
Types' helpers (1.2), pure tree ops (split, remove/collapse, move, neighbour by direction using
rect centres, `pane_rects(nodes, root, rect, divider_px, min)`, ratio clamp from min sizes,
leaf order/slots), `session_check`, `tab_focused`, `tab_on_screen`, `pane_at`, `pid`/`pidi`, `tab_rect(tab_id)` (pane's
laid-out rect, else computed from the tree and the last centre rect: used by `new_term`
and restored starts before the first layout).

### 3.2 State and commands
- `src/state.odin`: types (1.1); `active_tab()` keeps its meaning; add `focused_pane()`.
- `src/commands.odin`: `New_Shell_Tab`, `Close_Tab`, `Focus_Tab` (focuses the tab's pane too),
  `Restore_Session` (layout), `new_term` (size from `tab_rect`), `focus_session` (marks
  on-screen tabs; `t.changed` for all on-screen terms), `start_restored_tabs` unchanged.
  New commands (§4).
- Writers of `s.active_tab` → `session_show_tab`/`pane_add_tab`: `editor_commands.odin`
  (147,178,282,293), `app_tab.odin:433`, `browser.odin:148` (`background`), `claude.odin`
  (927,959,992), `changes.odin` (1010,1020), `markdown_view.odin` (1480,1493),
  `show_file.odin` (118; `inject_at` 170 → in the agent tab's pane), `commands.odin`
  (865,893-902,1061,1521-1595).
- `src/actions.odin`: `tab_step`/`tab_nth` (443-453, 627) within the focused pane; `close_tab`
  (161) unchanged (focused); new actions (§5.4).

### 3.3 Layout and drawing
- `src/ui.odin`: `centre()` becomes `centre(cs)` → session-wide bars (`update_bar`,
  `reload_bars`, `claude_reload_bars`, `comments_bars`) stay above all panes; then
  `pane_tree_layout(cs, node)` recursively emits Clay containers (`LeftToRight` for Right
  splits, `TopToBottom` for Down). **Sizing (L4)**: child `a` gets `clay.SizingPercent(ratio)`
  on the split axis, the divider a fixed `BORDER_W` element (`pid_split(split, "pane_div")`),
  child `b` gets `SizingGrow()` — so `b` absorbs the divider and any rounding, and Clay's
  percent/childGap semantics don't matter (no childGap on split containers). Per leaf
  `pane_layout(cs, p: ^Pane)`: its strip (§5.1), then the per-tab bars, then its content
  container `pid(p, "pane_body")` holding the inner `pid(p, "terminal")` element.
- **Explicit pane, bounded layer.** The bar procs called from `centre()` take `p: ^Pane` (and
  resolve the tab as `p.active`), instead of calling `active_tab()`/`tab_browser()`/…:
  `claude_bars`, `app_bar_layout`, `dead_tab_bar_layout`, `browser_bar_layout` (+ the polish
  bars it draws), `changes_bars_layout`, `changes_list_layout`, `changes_file_bar_layout`,
  `changes_more_layout`, `editor_bars_layout`, the empty/"Session gone"/browser-message states
  in `centre()` (~10 procs). Their click handlers (`app_bar_click`, `dead_tab_click`,
  `claude_click`, `changes_event`, `browser_polish_event`, `annot_event`, `browser_url_key`,
  `editor_bar_event`, `markdown_event`, `editor_event`) get the pane the click was hit-tested
  in. Nothing else changes signature: ticks, commands and actions keep the focused accessors.
- **Clay ids**: `pid(p, name) = clay.ID(name, u32(p.slot))`. Clay's `ID(x) == ID(x, 0)`, so a
  single-pane session (slot 0) produces byte-identical ids (`br_url_box`, `ed_tool`, `chtool`,
  `terminal`…): every existing `clickid`/`rclickid` keeps working. Ids that already take an
  index (rows, buttons: `clay.ID("chrow", i)`) get `pidi(p, name, i) = clay.ID(name, u32(p.slot
  << 16 | i))` — slot 0 again leaves them unchanged. Tabs keep `clay.ID("tab", index in
  s.tabs)`/`("tabclose", i)` across all strips.
- **Budget (M4)**, counted at 7904ea7 in the per-tab files: Clay id sites — `browser_polish`
  46, `editor_view` 28, `ui_changes` 19, `browser_nav` 14, `app_tab` 10, `ui_claude` 8,
  `browser_annotate` 5, `browser_agent` 5, `dead_tab` 5, `markdown_view` 1, plus `centre()`'s
  own ≈ 5 → **≈ 145 sites** to convert to `pid`/`pidi`; hit tests (`PointerOver`,
  `inside(clay.ID…)`, `GetElementData`) in the same files ≈ **50**, plus the
  `ui_hit()`/`chrome_hit()` dispatch and `buttons_test`/`layout_audit_test` expectations. (The
  reviewer's ~130 / ~200 figures: my ~200-class number is repo-wide — `rg` finds ~170 hit
  tests in all of `src/`, most of them in the sidebar, files, jobs and sheets that don't move
  into panes.) Mechanical, but it is the bulk of P2: budget ~600–900 changed lines for it
  alone, and it is why P2 may be split (§6).
- `ui_terminal_rect()` → `ui_pane_rects(cs)`: reads each `pid(p, "pane_body")` (the content
  container, **not** the inner `"terminal"` element, which a Changes tab's list narrows: M6)
  into `p.rect`; `app.pane` stays as the focused pane's rect until its last caller migrates.
- `src/main.odin` `frame()`: resize every tab to its pane's rect; draw each pane's active tab
  `tab_host(kind).draw(id, p.rect)` inside a scissor per pane; IME marked text on the focused
  term; redraw when any on-screen terminal changed and clear `changed` on all of them after
  the draw; overlay order unchanged. A drop-preview overlay (§5.3) is drawn after the panes.
- `src/editor_view.odin`: `last_area` per editor; `editor_text_hit(p, x, y)` uses the pane.
- `src/ui_changes.odin`: file list and diff inside the pane.
- `layout_audit_test.odin`: a split variant (2 and 3 panes, right+down) at the 4 widths.

### 3.4 Input routing (`src/main.odin` `event()`)
- **Pointer capture (H2).** `MOUSE_DOWN` records `pointer = {pane, tab, kind}` for the press
  (the pane under the pointer, or the divider/strip/tab-drag it started on). Every
  `MOUSE_MOVE` and the `MOUSE_UP` while a button is held go to that owner, wherever the
  pointer is (a text selection dragged from pane A over pane B keeps selecting in A; an app or
  page keeps getting its moves and release, as `app_event` already does within one tab). The
  capture ends at the release, `MOUSE_LEAVE`, window `UNFOCUSED`, or when the owner tab leaves
  the screen. Without a button, moves/wheel go to the pane under the pointer.
- **Click-to-focus (H3).** On `MOUSE_DOWN` in a pane that is not focused:
  `run_command(Focus_Pane{p.id}, {kind = .UI})` synchronously (the inbox drains after
  `event()`, too late for this click), then **set `app.drag_tab` to the newly focused tab**
  before routing the click, so `drags_follow_focus` (`main.odin:312`, which cancels every
  terminal's drag when the focused tab changes) does not cancel the selection this same click
  starts. Also change `drags_follow_focus` to cancel only drags of tabs that **left the screen**
  (`!tab_on_screen`), not every terminal's: focusing another pane must not end a drag in a
  still-visible one. Then route the click (click-through).
- Wheel and hover: the pane under the pointer (explicit `p` to the handlers), no focus change.
- Keys/CHAR/paste: the focused pane (today's path, unchanged accessors).
- `divider_at` learns pane dividers (`Hit_Pane_Divider(split id)`; `RESIZE_EW` for Right,
  `RESIZE_NS` for Down); `term_set_rect`'s throttle also while a pane divider is dragged.
- `sidebar_drop` (files from Finder) → the terminal of the pane under the drop point.
- Top-bar window drag: unchanged; pane strips' empty parts don't drag the window.

### 3.5 Snapshot, protocol, agents
- `src/json_write.odin` (per open session): keep `active_tab`; add `focused_pane`,
  `panes: [{id, slot, active_tab, tabs: [ids], rect: {x,y,w,h} (logical px)}]`, `layout`
  (tree: `{"pane": id}` | `{"split": id, "dir": "right"|"down", "ratio", "a", "b"}`); per tab
  `pane` and `on_screen`. `focus.tab_id` unchanged.
- `src/json_read.odin`, `src/command_table.odin`: new commands (§4). `docs_test.odin` will
  demand the docs rows.
- `integrations/pi/lib/state.ts`: "[active]" → "[active in pane N]"/"[on screen]", one line
  per pane when split; `integrations/pi/lib/commands.ts` rows; `integrations/pi/test/unit.test.ts`.
- `tools/pi-desk-cli/format.odin`: nothing needed (reads `on_screen`); its tests stay.
- `docs/PROTOCOL.md` (commands, snapshot example around line 614), `docs/PERSISTENCE.md`
  (the `panes` key), `docs/GUIDE.md` (splitting, keys), `docs/TAB-PROTOCOL.md` +
  `docs/ENGINE-BRIDGE.md` (`tab.visible` = on screen in any pane; size = the pane's),
  `docs/BROWSER.md` (§ pages: several visible pages), `docs/ROADMAP.md` (editor "split view"
  line → done via panes, except one file in two panes).

### 3.6 Test mode (`src/autotest.odin`)
- Vars: `$pane` (focused pane id), `$pane0…$pane7` (by slot), `$tab` unchanged (focused).
- `divider` gets `divider pane SPLIT_SLOT DX|DY` (or `pane_divider`), using the divider
  element's centre.
- `dragtab TAB_INDEX TARGET_SLOT edge|centre|strip [INDEX]`: a left drag from the tab to the
  zone (built on `dragid`'s 8-step move).
- `web_*`/`app_*` script commands unchanged (focused tab).

---

## 4. Commands (protocol)

All `who = .Anyone` like `focus_tab`. `.Anyone` already means the user, scripts, control
callers (Atlas) and Deckhand itself, and **excludes** `Panel` (pi bridges and Claude tabs) and
`App` callers (`who_allows`, `command_table.odin:281`), so "agents can't change the layout in
v1" needs no extra check (Q5 would change the `who`). Refused for Home (`HOME_NOT_A_SESSION`) and unknown ids. All change
what is saved, so `persist_on_event` marks the workspace dirty with no extra code.

| Command | Args | Does |
|---|---|---|
| `split_pane` | `pane?` (default: focused, of the current session), `direction: right\|down\|left\|up`, `tab_id?`, `focus?` (default true) | splits; `tab_id` given: moved into the new pane (must be in the same session; may not be the pane's only tab); else a new shell tab (Q1). `created_id` = new pane id; refused `"not enough room"` (min sizes), `"at most 8 panes"` |
| `move_tab` | `tab_id`, `pane`, `index?` | moves a tab into another pane of its session (at strip position `index`, default end) or reorders within its pane; an emptied pane closes |
| `close_pane` | `pane` | unsplit: its tabs join the neighbouring pane (non-destructive) |
| `focus_pane` | `pane` \| `direction: left\|right\|up\|down\|next\|prev` | focuses a pane (its active tab gets the keyboard; session made current) |
| `set_split` | `split`, `ratio` | a divider's position (clamped by min sizes); what a divider drag sends on release |
| `equalize_panes` | `session?` | every ratio 0.5 (or by leaf count per axis) |

Unchanged but pane-aware: `focus_tab` (also focuses its pane), `close_tab` (handover within the
pane), `new_shell_tab` (`pane?` optional arg; default focused pane), `open_file`/`show_file`/
`browser_open`/`app_open`/`new_claude_tab` (tab lands in the focused pane, or the agent tab's
pane for an agent; `pane?` optional where the caller may change the view).

Backward compatibility: every existing command, argument and snapshot path keeps its meaning
for a single-pane session, which is every session until a user splits one. `active_tab` =
the focused pane's active tab, so the 10 scripts asserting `open_sessions.N.active_tab` and
agents reading `active_tab` keep working.

---

## 5. UX

### 5.1 Strips and the top bar
- One pane: **exactly today's** top bar (tabs in the title bar). No visual change until the
  user splits.
- Split (proposed, Q2): the top bar keeps the lights, "+", "⌄", "±", search, bell, settings,
  right-column toggle and agent button but shows no tabs (its empty part drags the window);
  every pane gets its own strip (`TAB_STRIP_H`, same tab look, `tab_max_w` per pane width,
  squeezed rule per pane) with a small "+" (new shell in that pane) and a pane "⋯" menu
  (Split right, Split down, Close pane, Equalize).
- Focused pane: its active tab drawn as today's active tab; unfocused panes' active tabs in a
  quieter tint, plus a 1 px accent line on the focused pane's strip bottom edge (only while
  split).

### 5.2 Dividers and sizes
- 1 px `th.border` line, `DIVIDER_HIT` (6 px) grab zone, accent on hover/drag (as the column
  dividers), double-click → ratio 0.5. Live drag re-lays out; terminals throttle PTY resizes
  (`RESIZE_THROTTLE`), app/browser rings settle (`RING_SETTLE`, `browser_ring_due`); one
  `set_split` on release.
- Min pane content: `PANE_MIN_W = 240`, `PANE_MIN_H = 140` logical px (≈ 28 cols × 6 rows at
  the default size; a browser at 240 css px is cramped but usable). The centre's own
  `CENTRE_MIN` (360) stays the floor for the whole tree.
- `PANES_MAX = 8` per session.

### 5.3 Drag and drop
- Press on a tab and move > 4 px: a tab drag starts (a click still focuses as today; a
  double-click still keeps a preview tab). A ghost of the tab follows the pointer.
- Targets while dragging:
  - **a strip** (any pane, its own too): insertion marker between tabs → `move_tab` at index
    (this also gives tab reordering, which Deckhand lacks today);
  - **a pane body**: 5 zones — the outer 25 % (at least 40 px, at most 120 px) of each edge →
    split that pane in that direction with the tab (`split_pane tab_id`), the centre → move
    into that pane; a translucent accent rectangle previews the resulting area;
  - anywhere else (sidebar, right column, drawer, top bar): no drop (pointer shows not-allowed);
    Esc cancels.
- No-ops: dropping a pane's only tab on its own centre or edge; dragging across sessions is not
  possible (one session on screen).
- The pi/main tab can be dragged (moved/split) but never closed.

### 5.4 Keys (checked against `actions.odin`, `menubar.odin`, `main.odin`, `editor_view.odin`)
Taken today: ⌘K ⌘P ⌘J ⌘, ⌘/ ⌘⇧F ⇧⌘N ⌘N ⌘⇧E ⌘C ⌘V ⌘X ⌘A ⌘Z ⇧⌘Z ⌘Q ⌘T ⌥⌘T ⌘L ⌘W ⌘B
⌥⌘B ⌘1–9 ⌘0 ⌘+ ⌘− ⇧⌘[ ⇧⌘] ⌥⌘↑ ⌥⌘↓ (sessions) ⌘[ ⌘] (editor indent) ⌘← ⌘→ ⌘↑ ⌘↓ ⌘⌫
(terminal/editor) ⌘F ⌥⌘F ⌘G ⇧⌘G ⌘S ⇧⌘V ⌘H ⌥⌘H ⌘M ⌃⌘F ⌃G.

Proposed (all free today):
| Keys | Action |
|---|---|
| ⌘D | Split right (iTerm's) |
| ⇧⌘D | Split down |
| ⌃⌘← ⌃⌘→ ⌃⌘↑ ⌃⌘↓ | Focus the neighbouring pane (⌥⌘↑/↓ are taken by sessions, ⌘[ ⌘] by the editor) |
| ⇧⌃⌘← → ↑ ↓ | Move the focused tab to the neighbouring pane (none that way: split that way) |
| ⇧⌘W | Close pane (unsplit; its tabs join the neighbour) |
| ⌘1–9, ⇧⌘[ ⇧⌘] | Now within the focused pane (identical with one pane) |
| ⌘W, ⌘T | Focused pane: close its active tab / new shell in it |

Palette and menu bar (Window or View menu): Split right, Split down, Move tab to new pane
right/down, Focus pane left/right/up/down, Close pane, Equalize panes. Verify during P2 that
⌘D/⌃⌘arrows are not swallowed by CEF (`browser_polish_event` runs before the global ⌘ keys)
and that the editor's ⌘ branch (`editor_view.odin` ~560) does not take ⌃⌘.

### 5.5 Closing the last tab of a pane
The pane closes and its sibling grows into the space; focus goes to the most recently focused
pane (`pane_mru`). The last pane of a session can't close (its pi/main tab can't). (Q3:
VS Code-style empty panes instead?)

### 5.6 Focus by mouse
A click anywhere in a pane (strip, bars, content) focuses it and the click also acts. Wheel
scrolls the pane under the pointer without focusing it.

---

## 6. Phased delivery (small mergeable PRs)

Each phase: `./build.sh test` + `./build.sh scenes --changed` (and `--all` for P1, which
touches `@all` files), plus the review rules in the user's CLAUDE.md (one reviewer round for
P2/P4/P5, two for P3: it is a data migration of the saved workspace).

**P1 — One pane, refactored (no visible change).** `src/panes.odin` types + helpers;
`Tab.pane`, one pane per session; every `s.active_tab` writer through `session_show_tab`/
`pane_add_tab` (background opens never set `pane.active`); `tab_focused()`/`tab_on_screen()`
and the per-tab tick loops of the P1 table in §2.1; `tab_rect()` used by `new_term`, app
rings, browser views, overlays and scripts (`app.pane` kept as the focused pane's rect);
editor `last_area` per editor; the bar procs and handlers take `p: ^Pane` and use `pid`
(always slot 0, so ids are unchanged); pi-tab index clamp. Tests (L5): `panes_test.odin`
**builds two-pane sessions directly** (state literals, no UI: pane A with pi + shell, pane B
with an editor + browser + app tab, B focused) and asserts that `active_tab()`, `key_tab()`,
`key_term()`, `tab_editor()`/`tab_browser()`/`tab_app()` return B's active tab;
`tab_on_screen` is true for both panes' actives and false for the hidden ones; the bell
(`status_on_screen`, `status_seen`, `notify_pi_shown` with pi in A), `app_focus_tick`'s
target and `browser_tick`'s focus pick the right tab; `tab_step`/`tab_nth`/⌘W act in B;
`Close_Tab` hands over within the pane; a background open leaves `pane.active` alone;
moving/reordering never displaces `tabs[0]`. Plus `session_check` after every command in the
existing command tests' helpers. All scenes unchanged (`--all`). Usable: identical app.

**P2 — Splits for every tab kind, by keys and palette.** Tree ops and commands
(`split_pane`, `close_pane`, `focus_pane`, `move_tab` (no drag yet), `set_split`,
`equalize_panes`); Clay per-pane layout (percent `a` / Grow `b`), per-pane strips and bars
with `pid` ids (≈145 id sites, ≈50 hit tests: §3.3), dividers (drag, double-click),
click-to-focus with pointer capture and the H3 drag rule, wheel-to-pointer-pane; the URL,
find and prompt fields check their own tab id (`browser_url_tab`, `page_find_tab`,
`page_prompt_tab`) and are only shown editable in that tab's pane; a click in another pane's
field focuses that pane first, then moves the field (M3); keys and palette/menu rows;
snapshot fields; docs (PROTOCOL, GUIDE, `commands.ts` rows). Browser/app tabs in unfocused
panes: the §2.2 placeholder (click swallowed, not counted as seen). Not saved yet.
Tests: unit — tree ops (split/remove/collapse/neighbour/rects/ratio clamp/min sizes/PANES_MAX),
command callers (Home refused; `.Anyone` already refuses `Panel`/`App` callers, i.e. pi and
Claude tabs and apps — a test asserts a panel caller gets "not allowed for this caller" and a
control caller succeeds), pi tab moves but stays `tabs[0]` (index clamp), handover within a
pane, emptied pane collapses and MRU focus, ⌘1–9 within pane, the placeholder swallows its
click; `drags_follow_focus` test: a press in unfocused pane B's terminal starts a selection
that survives the focus change, and a drag in A survives focusing B; layout audit with 2–3
panes; `buttons_test` hits in a second strip. Scenes `tests/scripts/panes.txt` (required):
split right/down, type into each shell and `assert_state`, click-focus, `divider pane` drag
changes `open_sessions.0.panes.1.rect.w` and the shell's cols, ⌘W the last tab collapses,
⌃⌘arrows; **`panes-capture.txt`**: press in pane A's terminal, drag over pane B, release
there → A's selection covers the dragged text, B got no selection and no click, focus is A
(and the same with an editor). Split into P2a (model, commands, snapshot, layout, ids) and P2b
(dividers, capture/drag rules, keys, menus) if the diff exceeds ~1500 lines — likely, given
the id budget.

**P3 — Saved and restored.** `panes` key writer/loader, `Restore_Tab.pane`/`pane_active`,
`Restore_Session.pi_pane`/`pi_active`/`layout`, repair rules (an active tab dropped → the
pane's first tab), PERSISTENCE.md, release note (older builds drop the layout silently).
Tests: `persist_test.odin` fixtures (old file → one pane, round-trip, **pi tab in pane 1**,
corrupt/partial `panes`, a pane whose active tab failed to restore, a pane whose only tab
failed, Claude-only session, chat); scene pair `panes-restore-1.txt`/`-2.txt` (split, quit,
relaunch, assert tree, ratios, active per pane, focused pane, terminal sizes).

**P4 — Live browser and app tabs in every pane.** The P4 table of §2.1, exactly: app
visibility/peek/rings/`tab.visible`/screenshots, browser hidden/view size/`lazy`/`shown_at`
for every on-screen page, frame take, page plan with several visible pages, `shot_step`,
`browser_tabs.on_screen`, zoom/devtools per on-screen page, the per-tab bar click guard
(`bars_note` for every on-screen browser, M2), editor gutter/reparse for on-screen editors;
remove the placeholder (texture tabs now count as seen). Tests: `browser_nav_test` page plan
with 2–4 visible pages and slot pressure, `shown_at` LRU never evicting an on-screen page;
`browser_polish_test` guard: two on-screen tabs each keep their own `bars_changed_at`, a tab
coming back on screen restarts its guard; app visibility/peek table tests; scenes
`app-split.txt` (two fake apps both framing, both `tab.visible` true, one moved behind
another tab → false, a divider drag → `ring_w` changes once after settling) and
`browser-split.txt` (two pages painting, typing goes to the focused one, click on the
unfocused one's bar right after it came on screen is refused by the guard, slots pinned).

**P5 — Drag and drop.** Tab drag state (on top of the pointer capture), strip insertion
(reorder; index ≥ 1 rule), pane edge/centre zones, preview overlay, Esc cancel, `dragtab`
script command. Tests: unit — zone geometry (`drop_zone_at(rect, x, y)`), no-op cases, drop
before the pi tab lands after it; scene `panes-drag.txt` (reorder, move to other strip,
split by edge drop in all 4 directions, drop on own pane no-op).

**P6 — Agent-facing polish.** `desk_state` summary per pane (`state.ts`), CLI texts,
`browser.ts`/`app.ts` "not on screen" wording, optional `pane` args for agent opens (only if
Q5 says so), ENGINE-BRIDGE/TAB-PROTOCOL/BROWSER docs. Tests: `integrations/pi` unit tests,
`agent-show.txt` additions.

---

## 7. Top risks

- **R1 Explicit-pane threading misses a site.** A bar proc or handler that still calls a
  focused accessor draws/acts on the focused pane's tab inside another pane. Mitigation: the
  bounded list in §3.3 is converted whole in P1 (accessor calls in those files are grepped to
  zero there), and the P1 two-pane `panes_test` plus the 2-pane layout audit catch leftovers.
- **R2 Singleton widgets bound to one tab**: URL, find, prompt and commit fields, editor find
  bars. Rule (M3): a field belongs to its tab id; other panes render static text; a click
  there focuses that pane first. Audit the commit-message and editor-bar fields the same way.
- **R3 Event ordering and capture.** Focus changes go through the inbox, so click-to-focus runs
  synchronously; capture and the H3 `app.drag_tab` rule keep that click's drag alive.
- **R4 Resource load with several live textures**: 8 CEF slots app-wide, paints and app frames
  for every visible tab, GPU memory per ring; divider drags across texture panes (debounced;
  measure with the `browser-ring`/`app-tab` stats).
- **R5 PTY resize storms** on divider drags and tab moves: the throttle must cover pane
  dividers; hidden tabs keep their pane's size.
- **R6 Clay id volume** (≈145 sites, ≈50 hit tests): mechanical but large; single-pane ids must
  stay identical (slot 0) so scripts keep working.
- **R7 Persistence**: tabs always restore from `tabs`; only placement comes from `panes`; any
  doubt → one pane. Older builds silently drop the layout (release note).
- **R8 Test churn**: only split sessions change visuals; new scenes go into `tests/scenes.txt`
  with areas so `--changed` picks them.

## 8. Open questions for the user

1. **Split without a tab**: ⌘D opens a **new shell** in the new pane (iTerm/tmux; proposed),
   or moves the focused tab there (VS Code duplicates the editor; Deckhand can't duplicate a
   process)?
2. **Strips when split**: tabs leave the title bar and each pane gets its own strip (proposed),
   or always per-pane strips even with one pane (consistent, but costs ~40 px and changes every
   screenshot)?
3. **Last tab closed in a pane**: the pane closes (proposed) or stays as an empty pane
   (VS Code)?
4. **⌘1–9 and ⇧⌘[ ]**: within the focused pane (proposed) or session-wide (jumping across
   panes)?
5. **Agents and panes**: may pi/Claude tabs split or move tabs? Should `show_file`/
   `browser_open`/`app_open` from an agent open "beside" it (in another pane when split)
   rather than in its own pane behind it? Proposed v1: no layout commands for agents; their
   tabs open in their own pane, behind, as today.
6. **Same file in two panes** (editor split view of one buffer): out of scope for v1?
7. **Unread/bell**: a tab visible in an unfocused pane counts as seen (proposed) or only the
   focused one?
8. Limits and keys: `PANES_MAX` 8, min 240×140 logical px, ⌘D/⇧⌘D, ⌃⌘arrows, ⇧⌃⌘arrows,
   ⇧⌘W — OK? Also wanted: a "maximize pane" toggle (iTerm ⇧⌘↩) later?

## User's answers (2026-11-07): every proposed default accepted
1. ⌘D / ⇧⌘D open a new shell in the new pane. 2. Split: a strip per pane, tabs leave the title bar.
3. A pane collapses when its last tab closes. 4. ⌘1–9 and ⇧⌘[ ] act within the focused pane.
5. Agents can't split panes in v1. 6. No same file in two panes in v1. 7. Visible unfocused tabs count as seen.
8. 8 panes max, 240×140 px min, the proposed keys; a maximize toggle later.
