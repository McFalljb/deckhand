package main

// The left column (layout and input): the filter field and quick filters,
// then one scrolling list: the Open group (open sessions of every project
// and chat), Projects as a tree (the selected project expanded with its
// sessions) and Chats. Project sessions carry a folder, chats a bubble. What
// shows and in what order comes from sidebar.odin; every action is a command
// (ui_do), so the palette, scripts and Home can do the same. Also the
// context and sort menus, and the column dividers (drag to resize).
//
// Element ids carry list positions (proj i, sess i, ...); the ids behind
// them are kept from the last layout in `drawn`, so a click never acts on a
// row that moved since it was drawn.

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

filter_field: Text_Field

// Window width (framebuffer px) of the last layout.
ui_win_w: f32

// Rows of the last layout, by element index.
Drawn :: struct {
	arena: virtual.Arena,
	open:  [dynamic]u64, // open session ids
	proj:  [dynamic]u64, // project ids
	sess:  [dynamic]string, // pi session ids (the selected project's)
	chat:  [dynamic]string, // pi session ids (Chats)
	group: [dynamic]string, // group rows' folders (the Projects tree)
}
drawn: Drawn

@(private = "file")
drawn_reset :: proc() {
	virtual.arena_destroy(&drawn.arena)
	_ = virtual.arena_init_growing(&drawn.arena)
	a := virtual.arena_allocator(&drawn.arena)
	drawn.open = make([dynamic]u64, a)
	drawn.proj = make([dynamic]u64, a)
	drawn.sess = make([dynamic]string, a)
	drawn.chat = make([dynamic]string, a)
	drawn.group = make([dynamic]string, a)
}

@(private = "file")
keep :: proc(s: string) -> string {return strings.clone(s, virtual.arena_allocator(&drawn.arena))}

// ---- column widths and dividers ----

Divider_Drag :: struct {
	active: bool,
	which:  int, // 0 = left column's edge, 1 = right column's, 2 = the agent drawer's left edge
	x0, w0: f32, // press position (framebuffer px), width then (logical px)
	value:  f32, // live width (logical px)
	most:   f32, // the widest it may go (logical px)
}
divider: Divider_Drag

// The columns' widths as laid out (logical px): the saved ones (or a drag in
// progress), shrunk on a small window so the centre keeps CENTRE_MIN (the
// right column first). The saved widths do not change.
column_widths :: proc() -> (left, right: f32) {
	left = state.layout.left_open ? state.layout.left_width : 0
	right = state.layout.right_open ? state.layout.right_width : 0
	if divider.active {
		if divider.which == 0 && left > 0 do left = divider.value
		else if divider.which == 1 do right = divider.value
	}
	if ui_win_w <= 0 do return
	over := left + right + CENTRE_MIN - ui_win_w / app.dpi
	if over > 0 && right > core.RIGHT_MIN {
		cut := min(over, right - core.RIGHT_MIN)
		right -= cut
		over -= cut
	}
	if over > 0 && left > core.LEFT_MIN do left -= min(over, left - core.LEFT_MIN) // (0 while hidden)
	return
}

// The divider under (x, y) framebuffer px: 0 left, 1 right, 2 the agent
// drawer's left edge, -1 none. Each grabs DIVIDER_HIT across its line; the
// drawer's reaches no further into its terminal than the terminal's padding.
divider_at :: proc(x, y: f32) -> int {
	if y < px(TAB_STRIP_H) || palette_is_open() || menu.open do return -1
	l, r := column_widths()
	half := px(DIVIDER_HIT) / 2
	right_end := ui_win_w // the right column's outer side: the window's, or a pinned drawer's edge
	if state.home_open && drawer_laid_out {
		if d := clay.GetElementData(clay.ID("drawer")); d.found {
			b := d.boundingBox
			if y >= b.y && y < b.y + b.height && abs(x - b.x) <= half do return 2
			if state.layout.drawer_pinned do right_end = b.x
		}
	}
	if l > 0 && abs(x - l * app.dpi) <= half do return 0
	covered := state.home_open && !state.layout.drawer_pinned // under the sliding drawer
	if r > 0 && !covered && abs(x - (right_end - r * app.dpi)) <= half do return 1
	return -1
}

// A press on a divider: a double-click resets the column, else a drag starts.
divider_press :: proc(which: int, x: f32, clicks: int) {
	if clicks == 2 {
		switch which {
		case 0: ui_do(core.Set_Layout{left_width = core.LEFT_WIDTH_DEFAULT})
		case 1: ui_do(core.Set_Layout{right_width = core.RIGHT_WIDTH_DEFAULT})
		case 2: ui_do(core.Set_Layout{drawer_width = core.DRAWER_WIDTH_DEFAULT})
		}
		return
	}
	l, r := column_widths()
	w := which == 0 ? l : r
	most: f32 = which == 0 ? core.LEFT_MAX : core.RIGHT_MAX
	if which == 2 do w, most = drawer_w() / app.dpi, core.DRAWER_WIDTH_MAX
	// beside a pinned drawer the panels take only the room the centre leaves:
	// the drawer keeps its width, so the line stays under the pointer
	if which == 1 && state.layout.drawer_pinned && state.home_open && drawer_laid_out {
		room := ui_win_w / app.dpi - l - drawer_w() / app.dpi - CENTRE_MIN
		most = clamp(math.floor(room), w, core.RIGHT_MAX)
	}
	divider = {active = true, which = which, x0 = x, w0 = w, value = w, most = most}
	app.redraw = true
}

divider_move :: proc(x: f32) {
	dx := (x - divider.x0) / app.dpi
	switch divider.which {
	case 0: divider.value = clamp(math.round(divider.w0 + dx), core.LEFT_MIN, divider.most)
	case 1: divider.value = clamp(math.round(divider.w0 - dx), core.RIGHT_MIN, divider.most)
	case 2: divider.value = clamp(math.round(divider.w0 - dx), core.DRAWER_WIDTH_MIN, divider.most)
	}
	app.redraw = true
}

// The drag ended: one set_layout with the width as laid out (saved, and
// the terminal gets its final size at the next frame). A bare click (no
// change) saves nothing: not the width a small window or the room drew.
divider_release :: proc() {
	l, r := column_widths()
	dw := math.round(drawer_w() / app.dpi)
	which := divider.which
	moved := divider.value != divider.w0
	divider.active = false
	app.redraw = true
	if !moved do return
	if which == 0 && !state.layout.left_open do return // hidden mid-drag (⌘B): keep the saved width
	if which == 2 && !state.home_open do return // shut mid-drag (⌘J): the same
	switch which {
	case 0: ui_do(core.Set_Layout{left_width = l})
	case 1: ui_do(core.Set_Layout{right_width = r})
	case 2: ui_do(core.Set_Layout{drawer_width = dw})
	}
}

// ---- menus ----

// An open session's Mark as unread, or Mark as read when it is ("done, not seen yet" by hand:
// agent_status.odin; looking at it marks it seen). Another machine's goes there by its "m<no>:"
// pi_session_id (machine_route.odin), which marks it and sends it back through the mirror.
@(private = "file")
unread_item :: proc(items: ^[dynamic]core.Menu_Item, id: u64, pi_session_id: string) {
	unread := false
	if s := core.find_session(id); s != nil do for tab in s.tabs do if tab.unseen do unread = true
	append(items, core.Menu_Item{label = unread ? "Mark as read" : "Mark as unread", cmd = core.Set_Unread{pi_session_id = pi_session_id, unread = !unread}})
}

// Another machine's open session's menu (#114): what acts there as the user's and nothing of this
// Mac's (no pins, paths, accounts or new tabs): Peek, Mark as unread or read. id is its row's own;
// a session that has no id there yet (a Claude session before it reported one: a bare "m<no>:")
// has nothing to mark.
@(private = "file")
remote_session_items :: proc(items: ^[dynamic]core.Menu_Item, id: u64, pi_session_id: string) {
	if peek_tab_of(find_session(id)) != nil do append(items, core.Menu_Item{label = "Peek", peek = id})
	if !remote_id_bare(pi_session_id) do unread_item(items, id, pi_session_id)
}

// Another machine's pi_session_id without its own id: "m<no>:" and nothing after (or none at all).
@(private = "file")
remote_id_bare :: proc(pi_session_id: string) -> bool {
	k := strings.index_byte(pi_session_id, ':')
	return k < 0 || k == len(pi_session_id) - 1
}

Menu_Project :: distinct u64 // project id
Menu_Session :: struct {
	project_id:    u64,
	pi_session_id: string, // owned
	info:          string, // owned: the ⓘ menu, the session's info block shown on top ("" = the row menu)
	session:       u64, // the open session whose row it is (another machine's: its menu acts on this, never on a lookup by pi_session_id)
}
Menu_Sort :: distinct core.Sort_Section
Menu_New :: struct {
	pane: u64, // a pane strip's "+" (ui_panes.odin): its new tab opens in that pane; 0 = the title bar's
} // the tab strip's "+" menu (ui_toolbar.odin)
Menu_Target :: union {
	core.Menu_New_Session, // the harness picker of "New session" (harness.odin)
	Menu_Project,
	Menu_Session,
	Menu_Sort,
	Menu_New,
	Menu_Editor, // the editor's text (editor_view.odin)
	Menu_Files, // a Files row (ui_files.odin)
	Menu_Worktree, // a checkout or branch of the Files tab's switcher (ui_worktrees.odin)
	Menu_Job, // a job's "…" (ui_jobs.odin)
	Menu_Browser, // a browser tab's page (right click) or its ⋯ (browser_polish.odin)
	Menu_Term_Link, // a link in a terminal (term_links.odin)
	Menu_Machine, // another machine's header (right click)
	Menu_Tab, // a tab (right click: ui_panes.odin)
	Menu_Handoff, // the palette's New session on another machine…, several matches (ui_handoff.odin)
}

Menu_Machine :: distinct u64 // its number

Menu :: struct {
	open:     bool,
	target:   Menu_Target,
	at:       [2]f32, // framebuffer px
	selected: int, // keyboard selection, -1 = none
}
menu: Menu

menu_open :: proc(target: Menu_Target, at: [2]f32) {
	menu_close()
	handoff_drawn_clear() // what the last menu drew (ui_handoff.odin)
	menu.target = target
	if s, ok := target.(Menu_Session); ok do menu.target = Menu_Session{s.project_id, strings.clone(s.pi_session_id), strings.clone(s.info), s.session}
	if f, ok := target.(Menu_Files); ok do menu.target = Menu_Files{strings.clone(f.path), f.page}
	if w, ok := target.(Menu_Worktree); ok do menu.target = Menu_Worktree{strings.clone(w.path), strings.clone(w.branch)}
	if j, ok := target.(Menu_Job); ok do menu.target = Menu_Job{strings.clone(j.id)}
	if m, ok := target.(Menu_Browser); ok {
		m.link = strings.clone(m.link)
		menu.target = m
	}
	if l, ok := target.(Menu_Term_Link); ok do menu.target = Menu_Term_Link{tab_id = l.tab_id, url = strings.clone(l.url)}
	if n, ok := target.(core.Menu_New_Session); ok do menu.target = core.Menu_New_Session{project_id = n.project_id, cwd = strings.clone(n.cwd), run = strings.clone(n.run), folder = strings.clone(n.folder)}
	menu.at = at
	menu.selected = -1
	menu.open = true
	app.redraw = true
}

menu_close :: proc() {
	if s, ok := menu.target.(Menu_Session); ok {
		delete(s.pi_session_id)
		delete(s.info)
	}
	if f, ok := menu.target.(Menu_Files); ok do delete(f.path)
	if j, ok := menu.target.(Menu_Job); ok do delete(j.id)
	if m, ok := menu.target.(Menu_Browser); ok do delete(m.link)
	if l, ok := menu.target.(Menu_Term_Link); ok do delete(l.url)
	if n, ok := menu.target.(core.Menu_New_Session); ok {
		delete(n.cwd)
		delete(n.run)
		delete(n.folder)
	}
	if w, ok := menu.target.(Menu_Worktree); ok {
		delete(w.path)
		delete(w.branch)
	}
	menu.target = nil
	menu.open = false
	app.redraw = true
}

// The menu's rows for its target, now (temp allocator).
menu_items :: proc() -> []core.Menu_Item {
	items := make([dynamic]core.Menu_Item, context.temp_allocator)
	sep :: proc(items: ^[dynamic]core.Menu_Item) {append(items, core.Menu_Item{sep = true})}
	pin_moves :: proc(items: ^[dynamic]core.Menu_Item, at, n: int, p: u64, sid: string) {
		if at < 0 do return
		if at > 0 do append(items, core.Menu_Item{label = "Move up", cmd = core.Set_Pinned{project_id = p, pi_session_id = sid, pinned = true, index = at - 1}})
		if at < n - 1 do append(items, core.Menu_Item{label = "Move down", cmd = core.Set_Pinned{project_id = p, pi_session_id = sid, pinned = true, index = at + 1}})
	}
	switch t in menu.target {
	case Menu_Project:
		p := core.find_project(u64(t))
		if p == nil do break
		at := core.project_pinned(p^)
		append(&items, core.Menu_Item{label = at >= 0 ? "Unpin" : "Pin", cmd = core.Set_Pinned{project_id = p.id, pinned = at < 0}})
		pin_moves(&items, at, len(state.sidebar.pinned_projects), p.id, "")
		// one "New session": the installed harnesses' picker (harness.odin)
		append(&items, core.Menu_Item{label = "New session", picker = core.Menu_New_Session{project_id = p.id}})
		handoff_items(&items, p.id) // New session on <machine> in <project> (ui_handoff.odin)
		// Claude Code (claude.odin): a tab in the project's session (on screen, else its latest,
		// else a new one), once per account while there are several; only while it is installed
		if p.group == .Projects && core.claude_installed() do core.claude_account_items(&items, "New Claude tab", core.New_Claude_Tab{project_id = p.id})
		if p.group == .Projects && core.codex_offered(p.id) do append(&items, core.Menu_Item{label = "New Codex tab", cmd = core.New_Claude_Tab{project_id = p.id, codex = true}}) // codex.odin
		if core.folder_of(.Jobs) != "" do append(&items, core.Menu_Item{label = "New job for this project…", cmd = core.Job_Sheet{open = true, for_project = core.path_tilde(p.cwd)}})
		append(&items, core.Menu_Item{label = "Rename…", rename = true})
		sep(&items)
		// the sessions' order (one for every project), "Sort sessions: …"
		for by in core.Sort_By do append(&items, core.Menu_Item{label = SORT_SESSIONS[by], check = state.sidebar.sort[.Sessions] == by, cmd = core.Set_Sort{section = .Sessions, by = by}})
		sep(&items)
		append(&items, core.Menu_Item{label = "Reveal in Finder", cmd = core.Reveal_Path{project_id = p.id}})
		append(&items, core.Menu_Item{label = "Copy path", cmd = core.Copy_Path{project_id = p.id}})
		sep(&items)
		hidden := core.project_hidden(p^)
		append(&items, core.Menu_Item{label = hidden ? "Show again" : "Hide", cmd = core.Set_Hidden{project_id = p.id, hidden = !hidden}})
	case Menu_Session:
		info_items :: proc(items: ^[dynamic]core.Menu_Item, t: Menu_Session) {
			append(items, core.Menu_Item{label = "Copy session info", cmd = core.Session_Info{project_id = t.project_id, pi_session_id = t.pi_session_id, to = "clipboard"}})
			append(items, core.Menu_Item{label = fmt.tprintf("Send to %s", core.agent_name()), cmd = core.Session_Info{project_id = t.project_id, pi_session_id = t.pi_session_id, to = "agent"}})
		}
		if t.info != "" { 	// the ⓘ menu: the info, then what to do with it
			for l in strings.split_lines(t.info, context.temp_allocator) do if l != "" && !strings.has_prefix(l, "```") do append(&items, core.Menu_Item{label = l, note = true})
			sep(&items)
			info_items(&items, t)
			break
		}
		if id := t.session != 0 ? t.session : core.open_session_any(t.pi_session_id); id != 0 && core.id_machine(id) != 0 {
			remote_session_items(&items, id, t.pi_session_id)
			break
		}
		at := core.session_pinned(t.pi_session_id)
		known := core.session_known(t.pi_session_id)
		if known {
			append(&items, core.Menu_Item{label = at >= 0 ? "Unpin" : "Pin", cmd = core.Set_Pinned{pi_session_id = t.pi_session_id, pinned = at < 0}})
			pin_moves(&items, at, len(state.sidebar.pinned_sessions), 0, t.pi_session_id)
		}
		if id := core.open_session_any(t.pi_session_id); id != 0 && core.claude_installed() do core.claude_account_items(&items, "New Claude tab here", core.New_Claude_Tab{session = id}) // claude.odin
		if id := core.open_session_any(t.pi_session_id); id != 0 && core.codex_offered(id) do append(&items, core.Menu_Item{label = "New Codex tab here", cmd = core.New_Claude_Tab{session = id, codex = true}}) // codex.odin
		if r, _ := core.claude_record(t.pi_session_id); r != nil do append(&items, core.Menu_Item{label = "Rename…", rename = true}) // a Claude session's row: Deckhand's own title
		handoff_items(&items, t.project_id) // New session on <machine> in <project> (ui_handoff.odin)
		_, perr := core.sidebar_path(t.project_id, t.pi_session_id)
		claude_row := core.claude_row_record(t.project_id, t.pi_session_id) != nil // its info from Deckhand's history (claude_rows.odin)
		if perr == "" || claude_row {
			if len(items) > 0 do sep(&items)
			// a Claude row: its transcript, while Deckhand knows one under Claude's projects/
			if perr == "" {
				append(&items, core.Menu_Item{label = "Reveal in Finder", cmd = core.Reveal_Path{project_id = t.project_id, pi_session_id = t.pi_session_id}})
				append(&items, core.Menu_Item{label = "Copy path", cmd = core.Copy_Path{project_id = t.project_id, pi_session_id = t.pi_session_id}})
			}
			info_items(&items, t)
		}
		if len(items) > 0 do sep(&items)
		// a look at it without leaving the session on screen (ui_peek.odin), when it can be peeked
		if id := core.open_session_any(t.pi_session_id); id != 0 && peek_tab_of(find_session(id)) != nil do append(&items, core.Menu_Item{label = "Peek", peek = id})
		if id := core.open_session_any(t.pi_session_id); id != 0 do unread_item(&items, id, t.pi_session_id)
		if known {
			hidden := core.session_hidden(t.pi_session_id)
			append(&items, core.Menu_Item{label = hidden ? "Show again" : "Hide", cmd = core.Set_Hidden{pi_session_id = t.pi_session_id, hidden = !hidden}})
		}
		if id := core.open_session_any(t.pi_session_id); id != 0 {
			append(&items, core.Menu_Item{label = "Close session", cmd = core.Close_Session{session = id}})
		}
	case Menu_New:
		for id in ([]string{"new_shell_tab", "new_claude_tab", "new_browser_tab", "new_app_tab", "new_chat", "new_session"}) {
			if t.pane != 0 && (id == "new_chat" || id == "new_session") do continue // a pane's "+": tabs only
			a := action_by_id(id)
			if a == nil || !action_ok(id) do continue
			label := a.label
			// New chat, New session: the harness picker (harness.odin), under this menu
			if id == "new_session" do if p := core.find_project(state.selected_project); p != nil {
				append(&items, core.Menu_Item{label = fmt.tprintf("New session in %s", core.project_display(p^)), keys = a.keys, picker = core.Menu_New_Session{project_id = p.id}})
				continue
			}
			if id == "new_chat" do if c := core.chats_project(); c != nil {
				append(&items, core.Menu_Item{label = label, keys = a.keys, picker = core.Menu_New_Session{project_id = c.id}})
				continue
			}
			if id == "new_claude_tab" do label = action_label(a)
			// several Claude accounts: one row per account (claude_accounts.odin)
			if strings.has_prefix(id, "new_claude_") && core.claude_accounts_many() && core.claude_installed() {
				if c, ok := a.make(); ok {
					core.claude_account_items(&items, strings.trim_suffix(label, core.CLAUDE_MISSING_NOTE), c)
					continue
				}
			}
			append(&items, core.Menu_Item{label = label, keys = a.keys, action = id})
		}
		pane_split_items(&items) // Split pane right / down (ui_panes.odin)
	case core.Menu_New_Session:
		new_session_menu_items(t, &items)
	case Menu_Editor:
		editor_menu_items(u64(t), &items)
	case Menu_Files:
		files_menu_items(t.path, &items, t.page)
	case Menu_Worktree:
		wt_menu_items(t, &items)
	case Menu_Job:
		jobs_menu_items(t.id, &items)
	case Menu_Browser:
		browser_menu_items(t, &items)
	case Menu_Term_Link:
		term_link_menu_items(t, &items)
	case Menu_Machine:
		machine_menu_items(u64(t), &items)
	case Menu_Tab:
		tab_menu_items(u64(t), &items)
	case Menu_Handoff:
		handoff_items(&items, u64(t))
	case Menu_Sort:
		sec := core.Sort_Section(t)
		for by in core.Sort_By do append(&items, core.Menu_Item{label = SORT_LABELS[by], check = state.sidebar.sort[sec] == by, cmd = core.Set_Sort{section = sec, by = by}})
		sep(&items)
		append(&items, core.Menu_Item{label = "Show hidden", check = state.sidebar.show_hidden, cmd = core.Set_Filter{show_hidden = !state.sidebar.show_hidden}})
	}
	return items[:]
}

// Runs menu row i and closes the menu.
menu_run :: proc(i: int) {
	items := menu_items()
	if i < 0 || i >= len(items) || items[i].sep || items[i].note do return
	it := items[i]
	target := menu.target
	if ns, ok := it.picker.?; ok {
		// another menu's "New session": the picker opens where that menu was (harness.odin)
		at := menu.at
		cwd := strings.clone(ns.cwd, context.temp_allocator)
		menu_close()
		if core.id_machine(ns.project_id) != 0 do handoff_run(i, at) // New session on <machine>…: what row i showed (ui_handoff.odin)
		else do new_session_ui(ns.project_id, cwd, at)
		return
	}
	if t, ok := target.(core.Menu_New_Session); ok && handoff_picker_stale(t) do return // that machine restarted (ui_handoff.odin)
	if _, ok := target.(core.Menu_New_Session); ok do harness_used(it.cmd) // first next time
	if n, ok := target.(Menu_New); ok && n.pane != 0 do ui_do(core.Focus_Pane{pane = n.pane}) // new tabs open in the focused pane
	if it.peek != 0 {
		menu_close()
		peek_open_session(it.peek)
		return
	}
	if it.rename {
		if t, ok := target.(Menu_Session); ok {
			// a Claude session's row: its field takes the row (claude_rename on Enter)
			delete(rename_session)
			rename_session = strings.clone(t.pi_session_id)
			title := ""
			if r, _ := core.claude_record(t.pi_session_id); r != nil do title = r.title
			tf_set(&rename_field, title)
			tf_select_all(&rename_field) // typing replaces it
			ui_do(core.Set_Focus{"rename_session"})
		}
		if mm, ok := target.(Menu_Machine); ok do machine_edit_begin(u64(mm)) // its name field, in Settings
		if p, ok := target.(Menu_Project); ok {
			ui_do(core.Select_Project{u64(p)})
			if pp := core.find_project(u64(p)); pp != nil do tf_set(&rename_field, core.project_name(pp^))
			ui_do(core.Set_Focus{"rename_project"})
		}
	} else if it.action != "" {
		action_run(it.action, it.label)
	} else if it.editor != .None {
		if t, ok := target.(Menu_Editor); ok do editor_run_action(u64(t), it.editor)
	} else if it.copy != "" {
		if win_os.set_clipboard != nil {
			win_os.set_clipboard(it.copy)
			toast_show(fmt.tprintf("Copied: %s", it.copy))
		}
	} else if it.files != .None {
		if t, ok := target.(Menu_Files); ok {
			p := strings.clone(t.path, context.temp_allocator)
			if t.page ? settings_page_file_step(p, it.files) : files_step(p, it.files) do toast_show("Path copied")
		}
	} else if it.cmd != nil {
		// a tab's menu: Close tab is the user's own close (⇧⌘T reopens it: closed_tabs.odin)
		if _, on_tab := target.(Menu_Tab); on_tab do if ct, is := it.cmd.(core.Close_Tab); is do closed_tab_record(ct.tab_id)
		// a Settings page row's Open: its session shown again (the page goes), as the row's click
		if f, ok := target.(Menu_Files); ok && f.page {
			s := settings_page_session()
			#partial switch _ in it.cmd {
			case core.Open_File, core.Markdown_Open:
				if s == 0 {
					toast_show("Open a session on this Mac first: settings files open in its editor tabs")
					menu_close()
					return
				}
				ui_do(core.Focus_Session{session = s})
			}
		}
		ui_do_menu(it.cmd, it.label)
	} else if mm, ok := target.(Menu_Machine); ok && it.label == "Open web page…" {
		palette_open_pages(u64(mm)) // the palette asks for the port
		ui_do(core.Set_Focus{"palette"})
	}
	menu_close()
}

// Input while a menu is open: the keyboard moves and runs, a click outside
// closes it. Everything is consumed.
menu_event :: proc(e: ^sapp.Event) -> bool {
	if new_session_target_gone() {
		menu_close() // its project went (harness.odin)
		return true
	}
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		#partial switch e.key_code {
		case .ESCAPE:                   menu_close()
		case .UP:                       menu_step(-1)
		case .DOWN, .TAB:               menu_step(1)
		case .ENTER, .KP_ENTER, .SPACE: if menu.selected >= 0 do menu_run(menu.selected)
		case: new_session_number(e.key_code, e.modifiers) // the harness picker's 1-9 (harness.odin)
		}
		return true
	case .MOUSE_MOVE:
		h := chrome_hit({e.mouse_x, e.mouse_y})
		set_hover(h, false)
		if r, ok := h.(Hit_Menu_Row); ok && int(r) != menu.selected {
			menu.selected = int(r)
			app.redraw = true
		}
		return true
	case .MOUSE_DOWN:
		h := chrome_hit({e.mouse_x, e.mouse_y})
		if r, ok := h.(Hit_Menu_Row); ok do menu_run(int(r))
		else do menu_close() // a click outside only closes it
		return true
	case .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_SCROLL, .MOUSE_UP:
		return true
	}
	return false
}

@(private = "file")
menu_step :: proc(d: int) {
	items := menu_items()
	if len(items) == 0 do return
	i := menu.selected
	for _ in 0 ..< len(items) {
		i = (i + d + len(items)) %% len(items)
		if i < 0 do i = 0
		if !items[i].sep && !items[i].note do break
	}
	menu.selected = i
}

// Menu rows under the pointer (while a menu is open nothing else is hit).
menu_hit :: proc() -> Hit {
	for it, i in menu_items() do if !it.note && clay.PointerOver(clay.ID("menurow", u32(i))) do return Hit_Menu_Row(i)
	return nil
}

// ---- layout ----

// The project tree's view state (not saved): the selected project is the
// expanded one; a click on its row folds it, a click on another project
// selects and expands that one. "Show more" lists all of a list's rows.
Tree_View :: struct {
	project:      u64, // the selected project these flags are for
	folded:       bool, // its sessions are hidden (waiting ones still show)
	all_sessions: bool, // "Show more" under the project
	all_chats:    bool, // "Show more" under Chats
}
tree: Tree_View

@(private = "file")
tree_sync :: proc() {
	if tree.project == state.selected_project do return
	tree.project = state.selected_project
	tree.folded = false
	tree.all_sessions = false
}

// A click on a project row: select and expand it; on the selected one, fold
// or unfold its sessions.
project_row_click :: proc(id: u64) {
	tree_sync()
	if id == state.selected_project {
		tree.folded = !tree.folded
		app.redraw = true
		return
	}
	ui_do(core.Select_Project{id})
}

sidebar :: proc(cs: ^core.Open_Session, h: f32) {
	th := theme()
	drawn_reset()
	if !state.layout.left_open do return // hidden (⌘B): the top bar's toggle brings it back
	tree_sync()
	left, _ := column_widths()
	side_w := left * app.dpi
	row_w := side_w - px(2 * SP_2) // rows are inset from the column edge
	text_w_max := row_w - px(2 * PAD_ROW) // inside a row's padding
	// a filter set elsewhere (a command) shows in the field
	if state.focus_widget != "sidebar_filter" && tf_text(&filter_field) != state.sidebar.filter do tf_set(&filter_field, state.sidebar.filter)

	edge := th.border
	if divider.active && divider.which == 0 do edge = th.accent
	else if h, ok := ui_hover.(Hit_Divider); ok && int(h) == 0 do edge = mix(th.border, th.accent, 0.6)
	if clay.UI(clay.ID("sidebar"))({
		layout = {
			sizing = {clay.SizingFixed(side_w), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {pu(SP_2), pu(SP_2), 0, pu(SP_3)},
		},
		backgroundColor = cc(th.bg_sidebar),
		border = {color = cc(edge), width = {right = pu(core.BORDER_W)}},
	}) {
		// the title bar's part over the left column: the traffic lights sit here
		if clay.UI(clay.ID("sidebar_top"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(TAB_STRIP_H))}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}}}) {
			lights_buttons(px(LIGHTS_X + LIGHTS_W + SP_2 - SP_2)) // the column's padding is SP_2
		}
		left_tabs_switch() // Sessions | Files | Settings
		gap(SP_2)
		if state.layout.left_tab == .Jobs {
			jobs_panel(row_w) // ui_jobs.odin
			return
		}
		if state.layout.left_tab != .Sessions {
			files_panel(row_w) // ui_files.odin
			return
		}
		attention := state.sidebar.view == .Attention
		view_switch(row_w)
		gap(SP_2)
		filter_row(row_w)
		gap(SP_2)
		quick_chips(row_w)
		if !attention do waiting_filtered_row() // the Attention view lists every waiting session
		gap(SP_2)
		// one scrolling list: Open, Projects (a tree), Chats; or the Attention view's
		if clay.UI(clay.ID("nav"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			if attention do attention_list(cs, text_w_max, row_w)
			else do tree_list(cs, text_w_max, row_w)
		}
		if attention do attention_footer(text_w_max) // the way back, always in view
	}
}

// The By project view: this Mac's Open, Projects and Chats (under its header while Machines over
// SSH is on), then each other machine under its name.
@(private = "file")
tree_list :: proc(cs: ^core.Open_Session, text_w_max, row_w: f32) {
	th := theme()
	// this Mac's header over its own sections, while Machines over SSH is on (other machines
	// below). Folded: only its waiting open sessions (as Open folded); its count while folded
	// (the Open header counts them otherwise)
	here_folded := state.settings.remote_machines && state.sidebar.folded[.This_Mac]
	if state.settings.remote_machines do machine_header(0, th.done, core.machine_here_name(), "this Mac", "", here_folded ? len(core.sidebar_open()) : 0, text_w_max)
	if here_folded {
		// renaming a row it hides (the palette's Rename project): the field on top, as under a folded Projects
		if state.focus_widget == "rename_project" || state.focus_widget == "rename_session" do rename_field_layout()
		for s in core.sidebar_open() do if core.session_waiting(s.pi_session_id) do open_row(s, cs, text_w_max)
	} else {
		open_group(cs, text_w_max)
		projects_section(cs, text_w_max, row_w)
		gap(GAP_SECTION)
		chats_section(cs, text_w_max, row_w)
	}
	machines_sections(cs, text_w_max) // other machines, each under its name (Machines over SSH)
}

// The filter field: text and placeholder, ⇧⌘F, a clear button while it holds text.
@(private = "file")
filter_row :: proc(row_w: f32) {
	th := theme()
	focused := state.focus_widget == "sidebar_filter"
	hov := ui_hover == Hit(Hit_Filter{})
	ring := focused ? th.accent : mix(th.border, th.text_muted, hov ? 0.5 : 0)
	if clay.UI(clay.ID("filter_box"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FIELD_H))}, padding = clay.PaddingAll(pu(FOCUS_RING_W))},
		backgroundColor = cc(ring),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(SP_2 - FOCUS_RING_W), pu(SP_1), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD - FOCUS_RING_W)),
		}) {
			icon(.Search, focused ? th.text_secondary : th.text_muted, ICON_SIZE_SM)
			if focused {
				field_text(clay.ID("filter_text"), &filter_field, "Filter projects and sessions")
			} else {
				text := state.sidebar.filter
				room := row_w - px(3 * SP_2 + SP_6 + ICON_SIZE_SM) - text_w("⇧⌘F")
				if text != "" do clay.TextDynamic(clip(text, room), txt(th.text))
				else do clay.TextDynamic(clip("Filter", room), txt(th.text_muted))
			}
			spacer()
			if state.sidebar.filter != "" {
				id := clay.ID("filter_clear")
				bg, em := overlay(id, false, ui_hover == Hit(Hit_Filter_Clear{}))
				if clay.UI(id)({
					layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON - SP_1)), clay.SizingFixed(px(ROW_BUTTON - SP_1))}, childAlignment = {x = .Center, y = .Center}},
					backgroundColor = bg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				}) {
					icon(.Close, mix(th.text_muted, th.text, em), ICON_SIZE_SM - 2)
				}
			} else if !focused {
				clay.Text("⇧⌘F", txt(th.text_muted, FONT_UI_SMALL))
				if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_1)), clay.SizingFit()}}}) {}
			}
		}
	}
}

QUICK_LABELS := [3]string{"Running", "Waiting", "Pinned"}

// The quick filter chips. When the column is too narrow for them as they
// are, they share its width equally, without their dots, labels cut.
@(private = "file")
quick_chips :: proc(row_w: f32) {
	th := theme()
	sb := state.sidebar
	on := [3]bool{sb.only_running, sb.only_waiting, sb.only_pinned}
	need := 2 * px(SP_2)
	for label, i in QUICK_LABELS {
		need += 2 * px(CHIP_PAD) + text_w(label, FONT_UI_SMALL)
		if i < 2 do need += px(DOT + SP_2 - 2)
	}
	compact := need > row_w
	share := (row_w - 2 * px(SP_1)) / 3
	if clay.UI(clay.ID("quick"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(compact ? SP_1 : SP_2)}}) {
		for label, i in QUICK_LABELS {
			id := clay.ID("chip", u32(i))
			bg, em := overlay(id, on[i], ui_hover == Hit(Hit_Quick(i)))
			if clay.UI(id)({
				layout = {
					sizing = {compact ? clay.SizingFixed(share) : clay.SizingFit(), clay.SizingFixed(px(CHIP_H))},
					padding = {pu(compact ? SP_2 : CHIP_PAD), pu(compact ? SP_2 : CHIP_PAD), 0, 0},
					childGap = pu(SP_2 - 2),
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(CHIP_H / 2)),
				border = {color = cc(on[i] ? th.accent : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
			}) {
				if !compact && i == 0 do dot(th.running)
				if !compact && i == 1 do dot(th.waiting)
				text := compact ? clip(label, share - px(2 * SP_2), FONT_UI_SMALL) : label
				clay.TextDynamic(text, txt(on[i] ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
			}
		}
	}
}

// A section header (one style for Open, Projects and Chats): the label in
// small caps-style type and a count (a click folds the section; a chevron
// shows while folded or hovered), then the sort and "+" buttons on the right.
@(private = "file")
nav_header :: proc(name: string, fold: core.Sidebar_Fold, count: int, sort: Maybe(core.Sort_Section), plus: Hit, plus_id: clay.ElementId) {
	th := theme()
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, childGap = pu(GAP_BUTTONS), childAlignment = {y = .Center}},
	}) {
		label_id := clay.ID("navhead", u32(fold))
		hit := Hit(Hit_Fold(fold))
		_, em := overlay(label_id, false, ui_hover == hit)
		folded := state.sidebar.folded[fold]
		if clay.UI(label_id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
			col := mix(th.text_muted, th.text_secondary, em)
			clay.TextDynamic(name, txt(col, FONT_UI_SMALL | WEIGHT_HEADER))
			if count > 0 do clay.TextDynamic(fmt.tprint(count), txt(th.text_muted, FONT_UI_SMALL))
			a := fade(label_id, 7, folded || ui_hover == hit ? 1 : 0, DUR_HOVER)
			icon(folded ? .Chevron_Right : .Chevron_Down, with_alpha(col, a), ICON_SIZE_SM - 2)
		}
		if sec, ok := sort.?; ok do sort_control(sec)
		if plus != nil {
			bg, em2 := overlay(plus_id, false, ui_hover == plus)
			if clay.UI(plus_id)({
				layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				icon(.Plus, mix(th.text_muted, th.text, em2), ICON_SIZE_SM)
			}
		}
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(PAD_ROW - GAP_BUTTONS)), clay.SizingFit()}}}) {} // right edge = rows' padding
	}
}

SORT_SHORT := [core.Sort_By]string{.Recent = "Recent", .Name = "Name", .Created = "Created", .Attention = "Attention"}
SORT_LABELS := [core.Sort_By]string{.Recent = "Recent activity", .Name = "Name", .Created = "Created", .Attention = "Needs attention"}
SORT_SESSIONS := [core.Sort_By]string{.Recent = "Sessions by recent activity", .Name = "Sessions by name", .Created = "Sessions by created", .Attention = "Sessions by attention"}

// A section's sort button: an icon (its menu names the current order).
@(private = "file")
sort_control :: proc(sec: core.Sort_Section) {
	th := theme()
	id := clay.ID("sort", u32(sec))
	bg, em := overlay(id, menu.open && menu.target == Menu_Target(Menu_Sort(sec)), ui_hover == Hit(Hit_Sort(sec)))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		icon(.Sort, mix(th.text_muted, th.text, em), ICON_SIZE_SM)
	}
}

// The line between a list's pinned rows (on top, each with a ★ on hover)
// and the rest; no label.
@(private = "file")
pinned_divider :: proc(indent: f32 = 0) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(PINNED_GAP))}, padding = {pu(PAD_ROW + indent), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(theme().border)}) {}
	}
}

// A muted one-line note in a list ("No sessions yet"), indented like its rows.
@(private = "file")
list_note :: proc(text: string, indent, text_w_max: f32) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(PAD_ROW + indent), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
		clay.TextDynamic(clip(text, text_w_max - px(indent)), txt(theme().text_muted))
	}
}

// A row that runs something ("+ New session", "Show 4 more"): a muted icon
// or nothing, then muted text.
@(private = "file")
action_row :: proc(id: clay.ElementId, hit: Hit, ic: core.Icon, label: string, indent, text_w_max: f32) {
	th := theme()
	bg, em := overlay(id, false, ui_hover == hit)
	cfg := row_cfg(bg)
	cfg.layout.padding.left = pu(PAD_ROW + indent)
	if clay.UI(id)(cfg) {
		col := mix(th.text_muted, th.text, em)
		room := text_w_max - px(indent)
		if ic != .None {
			icon(ic, col, KIND_ICON)
			room -= px(KIND_ICON + GAP_INLINE)
		}
		clay.TextDynamic(clip(label, room), txt(col))
	}
}

// The Open group: every open session, current first; each row says where it
// runs (a folder and its project, or a bubble for a chat). Hidden while
// nothing is open (or the filter leaves none).
@(private = "file")
open_group :: proc(cs: ^core.Open_Session, text_w_max: f32) {
	rows := core.sidebar_open()
	if len(rows) == 0 do return
	nav_header("OPEN", .Open, len(rows), nil, nil, {})
	folded := state.sidebar.folded[.Open]
	for s in rows {
		// folded: only waiting work stays (it is never concealed)
		if folded && !core.session_waiting(s.pi_session_id) do continue
		open_row(s, cs, text_w_max)
	}
	gap(GAP_SECTION)
}

// An open session's row: its place's icon, [place ·], its agent's icon, title, then "Waiting for
// you" or its age and its dot, or (hovered) its "…" and close buttons. Another machine's (remote)
// has no buttons (right-click: Peek and Mark as unread only, sidebar_context) and no age (its session file is not
// on this Mac); while that machine is not online (live false) it is greyed, without a status.
// The Attention view's rows also name their machine (mach, in a column mach_w wide, before the
// mark) and show the keyboard's row (key_sel) as hovered; a row that can be peeked (peek) shows an
// eye while hovered, another machine's too (ui_peek.odin).
@(private = "file")
open_row :: proc(s: ^core.Open_Session, cs: ^core.Open_Session, text_w_max: f32, remote := false, live := true, mach := "", mach_w: f32 = 0, key_sel := false, from: ^core.Tab = nil, peek := false) {
	th := theme()
	mach_w := mach_w
	append(&drawn.open, s.id)
	k := u32(len(drawn.open) - 1) // ids follow the drawn rows (sidebar_hit)
	id := clay.ID("open", k)
	current := cs != nil && s.id == cs.id
	close_hover := !remote && ui_hover == Hit(Hit_Close_Session(s.id))
	more_hover := !remote && ui_hover == Hit(Hit_More_Open(s.id))
	row_hover := ui_hover == Hit(Hit_Open_Row(s.id))
	peek_hover := peek && ui_hover == Hit(Hit_Peek_Row(s.id))
	hovered := !remote && (row_hover || close_hover || more_hover || peek_hover) // its buttons show
	peek_shown := peek && (row_hover || close_hover || more_hover || peek_hover) // and its eye
	buttons := hovered || peek_shown
	bg, em := overlay(id, current, row_hover || hovered || peek_hover || key_sel)
	v := core.session_row_view(s) // the strongest of its tabs (agent_status.odin)
	if from != nil do v = core.tab_status_view(from^) // the Attention view's: the tab that put it in its group
	if !live do v = {progress = -1} // what it showed last: no status
	// it turned waiting, finished or error just now: a brief wash, its mark pops (by session: the
	// row moves up when it turns waiting)
	lit := status_flash(id, s.id ~ SALT_FLASH_ROW, v, s.machine, live)
	bg = flash_wash(bg, v.dot, lit)
	if clay.UI(id)(row_cfg(bg)) {
		st := v.dot
		ic, place := core.session_place(s)
		chat := ic == .Chat
		title := core.open_session_title(s)
		// how long its status has been what it is ("4m"), else how long ago it was used
		age := status_age(v)
		when_ := age
		if st == .Waiting do when_ = age != "" ? fmt.tprintf("%s · %s", age, "Waiting for you") : "Waiting for you"
		else if when_ == "" && !remote do when_ = core.open_session_age(s)
		// an agent acts in one of its browser tabs the user does not see (browser_act.odin)
		acting := !remote && st != .Waiting && browser_act_session_background(s)
		if acting do when_ = browser_act_session_text(s) // the acting tab's harness
		// children: icon, [place ·], harness icon, title, [tag], spacer, then time and mark, or the buttons
		right := px(MARK) // its mark: always there, so the row never moves when its status changes
		n := 5 // icon, harness icon, title, spacer, mark
		if buttons {
			if hovered {
				right += 2 * px(ROW_BUTTON)
				n += 2
			}
			if peek_shown {
				right += px(ROW_BUTTON)
				n += 1
			}
		} else if when_ != "" {
			n += 1
		}
		if !chat do n += 1
		// which agent it runs (a Claude-only session, else pi), and the account of several
		harness := core.open_session_harness(s)
		tag := "" // another machine's account is that machine's, unknown here: never this Mac's label
		if !remote && s.agent == .Claude && len(s.tabs) > 0 do if ct, is := s.tabs[0].kind.(core.Claude_Tab); is do tag = core.claude_account_tag(ct.account)
		if tag != "" {
			right += text_w(tag, FONT_UI_SMALL)
			n += 1
		}
		if mach_w > 0 {
			right += mach_w
			n += 1
		}
		room := text_w_max - px(KIND_ICON + HARNESS_ICON_SIZE) - right - f32(n - 1) * px(GAP_INLINE)
		lead := fmt.tprintf("%s ·", place)
		if !buttons && when_ != "" {
			// waiting: what it asks, after its time, in the room the title leaves (the title keeps
			// 60% of the row, or all it needs; at least 48 px of the message, else only the time)
			if st == .Waiting && !acting {
				need := text_w(title) + (chat ? 0 : text_w(lead) + px(GAP_INLINE))
				give := room - min(need, room * 0.6)
				prefix := age != "" ? fmt.tprintf("%s · ", age) : ""
				what := v.msg != "" ? v.msg : "Waiting for you"
				long := fmt.tprintf("%s%s", prefix, what)
				switch {
				case text_w(long) <= give:                            when_ = long
				case v.msg != "" && give - text_w(prefix) >= px(48):  when_ = clip(long, give) // enough of it to read
				case age != "":                                       when_ = age // the mark says waiting
				case:                                                 when_ = "Waiting for you"
				}
			}
			room -= text_w(when_)
		}
		// a column too narrow for the machine's name too: the title keeps its room (the tooltip
		// says where it runs)
		if mach_w > 0 && room < px(48) {
			room += mach_w + px(GAP_INLINE)
			mach_w = 0
		}
		// the session the centre shows, from another project than the selected one: its place in the accent
		elsewhere := current && !chat && s.project_id != state.selected_project
		icon(ic, elsewhere ? th.accent : th.text_muted, KIND_ICON)
		if !chat {
			pw := min(text_w(lead), max(room * 0.4, room - text_w(title)))
			clay.TextDynamic(clip(lead, pw), txt(elsewhere ? th.accent : th.text_muted))
			room -= pw
		}
		icon(core.harness_row_icon(harness, !live), th.text_muted, HARNESS_ICON_SIZE)
		clay.TextDynamic(clip(title, room), txt(live ? mix(th.text_secondary, th.text, em) : th.text_muted))
		if tag != "" do clay.TextDynamic(tag, txt(th.text_muted, FONT_UI_SMALL))
		spacer()
		if !buttons && when_ != "" do clay.TextDynamic(when_, txt(st == .Waiting ? th.waiting : acting ? th.accent : th.text_muted))
		// (not `mach_w > 0 && clay.UI()`: the element's close is deferred, opened or not)
		if mach_w > 0 {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(mach_w), clay.SizingFit()}}}) {
				clay.TextDynamic(clip(mach, mach_w, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		status_mark_el(v, lit)
		peek_row_button(clay.ID("openpeek", k), peek_shown, peek_hover)
		row_button(clay.ID("openmore", k), "", hovered, more_hover, .More)
		row_button(clay.ID("openclose", k), "", hovered, close_hover, .Close)
	}
}

// Projects as a tree: each project row (chevron, folder, name, open count);
// the selected one expanded with its sessions, "Show more" and "+ New session".
@(private = "file")
projects_section :: proc(cs: ^core.Open_Session, text_w_max, row_w: f32) {
	rows := core.sidebar_projects()
	nav_header("PROJECTS", .Projects, 0, core.Sort_Section.Projects, Hit_Add_Project{}, clay.ID("addproject"))
	// renaming a project whose row is not shown (folded, filtered out, hidden): the field on top
	if state.focus_widget == "rename_project" {
		drawn_row := false
		if !state.sidebar.folded[.Projects] do for r in rows do if r.project != nil && r.project.id == state.selected_project do drawn_row = true
		if !drawn_row do rename_field_layout()
	}
	// renaming a Claude session's row that is not shown (its project folded or not selected, the
	// row filtered out or past Show more): the field on top, as for a project
	if state.focus_widget == "rename_session" {
		drawn_row := false
		if !state.sidebar.folded[.Projects] && !tree.folded do for r in rows do if r.project != nil && r.project.id == state.selected_project {
			shown, _ := capped_rows(core.sidebar_sessions(.Sessions), tree.all_sessions)
			for x in shown do if x.session.id == rename_session do drawn_row = true
		}
		if !drawn_row do rename_field_layout()
	}
	if state.sidebar.folded[.Projects] do return
	n := 0
	for p in state.projects do if p.group == .Projects && p.machine == 0 do n += 1 // this Mac's (other machines' are under their names)
	if n == 0 do empty_state("No projects yet", "+ adds a folder, or drop one here", row_w)
	else if len(rows) == 0 do empty_state("No matching projects", filter_clear_hint(), row_w)
	for r, i in rows {
		if core.pinned_divider_before(rows, i) do pinned_divider()
		indent := f32(r.depth) * TREE_INDENT // nested rows (project_tidy.odin)
		if r.project == nil {
			group_row(r, len(drawn.group), indent, text_w_max)
			append(&drawn.group, keep(r.group))
			continue
		}
		p := r.project
		j := len(drawn.proj)
		append(&drawn.proj, p.id)
		selected := p.id == state.selected_project
		if selected && state.focus_widget == "rename_project" {
			rename_field_layout(indent) // at the row's own indent
		} else {
			project_row(r, j, cs, text_w_max, indent)
		}
		if selected do project_sessions(p, cs, text_w_max, indent)
	}
}

@(private = "file")
// Another machine's (remote): no buttons (its rows have no menu yet: sidebar_context); while that
// machine is not online (live false) greyed, without a status.
project_row :: proc(r: core.Sidebar_Row, i: int, cs: ^core.Open_Session, text_w_max: f32, indent: f32 = 0, remote := false, live := true) {
	th := theme()
	p := r.project
	id := clay.ID("proj", u32(i))
	pin_hover := !remote && ui_hover == Hit(Hit_Pin_Project(p.id))
	new_hover := !remote && ui_hover == Hit(Hit_New_In(p.id))
	more_hover := !remote && ui_hover == Hit(Hit_More_Project(p.id))
	row_hover := ui_hover == Hit(Hit_Project(p.id))
	// the "N folders" toggle is part of the row: the buttons stay while the pointer is on it (else
	// they go, the toggle slides right from under the pointer, the row is hovered, they come back: a flicker)
	hovered := !remote && (row_hover || ui_hover == Hit(Hit_Kids(p.id)) || pin_hover || new_hover || more_hover) // its buttons show
	selected := p.id == state.selected_project
	expanded := selected && !tree.folded
	// the expanded project is not "selected" in colour: its sessions carry the selection
	current := cs != nil && !core.open_session_is_chat(cs) && cs.project_id == p.id && !expanded
	bg, em := overlay(id, current, row_hover || hovered)
	cfg := row_cfg(bg)
	cfg.layout.padding.left = pu(PAD_ROW + indent)
	kids_hover := ui_hover == Hit(Hit_Kids(p.id)) && !r.forced // kept open: not clickable
	if clay.UI(id)(cfg) {
		v := core.project_status_view(p.id) // its open sessions' strongest
		if !live do v = {progress = -1}
		st := v.dot
		n_open := 0
		for s in state.open_sessions do if !s.home && s.project_id == p.id do n_open += 1
		marked := n_open > 0 || st != .None // a project with open sessions keeps its mark's room
		right_text := r.hidden ? core.HIDE_REASON_TAGS[r.reason] : (n_open > 0 ? fmt.tprint(n_open) : "")
		// children: chevron, folder, name, spacer, then count and dot, or three buttons
		right: f32
		n := 4
		if hovered {
			right = 3 * px(ROW_BUTTON)
			n += 3
		} else if right_text != "" {
			right = text_w(right_text)
			n += 1
		}
		if marked {
			right += px(MARK)
			n += 1
		}
		// a parent row: "N folders", a click opens or collapses its nested rows
		kids := r.kids > 0 ? fmt.tprintf("%d folder%s", r.kids, r.kids == 1 ? "" : "s") : ""
		kids_w: f32 = 0
		if kids != "" {
			kids_w = px(ICON_SIZE_SM) + px(GAP_INLINE) + text_w(kids, FONT_UI_SMALL)
			n += 1
		}
		room := text_w_max - px(indent) - px(TREE_CHEVRON + KIND_ICON) - right - kids_w - f32(n - 1) * px(GAP_INLINE)
		col := mix(th.text_secondary, th.text, em)
		if p.missing || r.hidden || !live do col = th.text_muted
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(TREE_CHEVRON)), clay.SizingFit()}, childAlignment = {x = .Center, y = .Center}}}) {
			icon(expanded ? .Chevron_Down : .Chevron_Right, th.text_muted, TREE_CHEVRON)
		}
		icon(.Folder, selected ? th.text_secondary : th.text_muted, KIND_ICON)
		clay.TextDynamic(clip(core.project_display(p^), room), txt(col, selected ? WEIGHT_BOLD : WEIGHT_REGULAR))
		spacer()
		if kids != "" {
			if clay.UI(clay.ID("projkids", u32(i)))({layout = {childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
				kc := kids_hover ? th.text : th.text_muted
				icon(r.open ? .Chevron_Down : .Chevron_Right, kc, ICON_SIZE_SM)
				clay.TextDynamic(kids, txt(kc, FONT_UI_SMALL))
			}
		}
		if right_text != "" && !hovered do clay.TextDynamic(right_text, txt(th.text_muted))
		if marked do status_mark_el(v)
		row_button(clay.ID("projpin", u32(i)), r.pin >= 0 ? "★" : "☆", hovered, pin_hover)
		row_button(clay.ID("projnew", u32(i)), "", hovered, new_hover, .Plus)
		row_button(clay.ID("projmore", u32(i)), "", hovered, more_hover, .More)
	}
}

// Whether a parent or group row is shown open (saved open, or opened by
// the filter, the selection or waiting work), and whether it is kept open
// (forced: a click does nothing).
row_state :: proc(path: string) -> (open, forced: bool) {
	for r in core.sidebar_projects() do if (r.kids > 0) && core.row_path(r) == path do return r.open, r.forced
	return core.list_index(state.sidebar.expanded[:], path) >= 0, false
}

// A row toggle that does nothing now (kept open): no pointing hand, no hover.
hit_inert :: proc(h: Hit) -> bool {
	#partial switch x in h {
	case Hit_Group:
		_, forced := row_state(string(x))
		return forced
	case Hit_Kids:
		if p := core.find_project(u64(x)); p != nil {
			_, forced := row_state(p.cwd)
			return forced
		}
	}
	return false
}

// Tooltips of the Projects tree's toggles: a group row's full folder; why a
// row stays open.
tree_tip :: proc(h: Hit) -> string {
	KEPT :: "kept open: it holds the selected project, waiting work or a filter match"
	#partial switch x in h {
	case Hit_Group:
		_, forced := row_state(string(x))
		return forced ? fmt.tprintf("%s (%s)", string(x), KEPT) : string(x)
	case Hit_Kids:
		p := core.find_project(u64(x))
		if p == nil do return ""
		open, forced := row_state(p.cwd)
		if forced do return fmt.tprintf("Folders inside (%s)", KEPT)
		return open ? "Hide the folders inside" : "Show the folders inside"
	}
	return ""
}

// A group row of the Projects tree (project_tidy.odin): chevron, folder,
// the folder's name, its count; a click opens or collapses it. No sessions.
@(private = "file")
group_row :: proc(r: core.Sidebar_Row, i: int, indent, text_w_max: f32) {
	th := theme()
	id := clay.ID("grp", u32(i))
	hovered := ui_hover == Hit(Hit_Group(r.group)) && !r.forced // kept open: not clickable
	bg, em := overlay(id, false, hovered)
	cfg := row_cfg(bg)
	cfg.layout.padding.left = pu(PAD_ROW + indent)
	if clay.UI(id)(cfg) {
		count := fmt.tprintf("%d", r.kids)
		room := text_w_max - px(indent) - px(TREE_CHEVRON + KIND_ICON) - text_w(count) - 3 * px(GAP_INLINE)
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(TREE_CHEVRON)), clay.SizingFit()}, childAlignment = {x = .Center, y = .Center}}}) {
			icon(r.open ? .Chevron_Down : .Chevron_Right, th.text_muted, TREE_CHEVRON)
		}
		icon(.Folder, th.text_muted, KIND_ICON)
		clay.TextDynamic(clip(r.name, room), txt(mix(th.text_secondary, th.text, em)))
		spacer()
		clay.TextDynamic(count, txt(th.text_muted))
	}
}

// The rows a list shows: the first TREE_SHOW unless "Show more" was pressed;
// waiting rows past them always show. Also how many are left out.
@(private = "file")
capped_rows :: proc(rows: []core.Sidebar_Row, all: bool) -> (shown: []core.Sidebar_Row, more: int) {
	if all || len(rows) <= TREE_SHOW do return rows, 0
	out := make([dynamic]core.Sidebar_Row, context.temp_allocator)
	for r, i in rows {
		if i < TREE_SHOW || core.session_waiting(r.session.id) do append(&out, r)
		else do more += 1
	}
	return out[:], more
}

// The selected project's sessions under its row (folded: only waiting ones).
@(private = "file")
project_sessions :: proc(p: ^core.Project, cs: ^core.Open_Session, text_w_max: f32, depth_indent: f32 = 0) {
	ind := TREE_INDENT + depth_indent // under a nested row: further in
	rows := core.sidebar_sessions(.Sessions)
	if tree.folded && !core.sidebar_filtering() { // filtering: the matches show
		waiting := make([dynamic]core.Sidebar_Row, context.temp_allocator)
		for r in rows do if core.session_waiting(r.session.id) do append(&waiting, r)
		session_rows(waiting[:], p.id, cs, "sess", text_w_max, ind)
		return
	}
	if len(rows) == 0 && !core.sidebar_filtering() do list_note("No sessions yet", ind, text_w_max)
	else if len(rows) == 0 do list_note("No matching sessions", ind, text_w_max)
	shown, more := capped_rows(rows, tree.all_sessions)
	session_rows(shown, p.id, cs, "sess", text_w_max, ind)
	if more > 0 do action_row(clay.ID("showmore", 0), Hit_Show_More(0), .None, fmt.tprintf("Show %d more", more), ind, text_w_max)
	action_row(clay.ID("new"), Hit_New{}, .Plus, "New session", ind, text_w_max) // the harness picker (harness.odin)
	// a job for this project (its owner and folder; ui_jobs.odin has the rest)
	if core.folder_of(.Jobs) != "" do action_row(clay.ID("newjob"), Hit_New_Job_In(p.id), .Clock, "New job…", ind, text_w_max)
}

// Chats: sessions outside any project, each with a bubble; "+ New chat".
@(private = "file")
chats_section :: proc(cs: ^core.Open_Session, text_w_max, row_w: f32) {
	c := core.chats_project()
	if c == nil do return
	nav_header("CHATS", .Chats, 0, core.Sort_Section.Chats, Hit_New_In(c.id), clay.ID("newchatchats"))
	if state.sidebar.folded[.Chats] do return
	rows := core.sidebar_sessions(.Chats)
	if len(rows) == 0 && !core.sidebar_filtering() do list_note("No chats yet", 0, text_w_max)
	else if len(rows) == 0 do list_note("No matching chats", 0, text_w_max)
	shown, more := capped_rows(rows, tree.all_chats)
	session_rows(shown, c.id, cs, "chat", text_w_max, 0)
	if more > 0 do action_row(clay.ID("showmore", 1), Hit_Show_More(1), .None, fmt.tprintf("Show %d more", more), KIND_ICON + GAP_INLINE, text_w_max)
	action_row(clay.ID("newchatrow"), Hit_New_In(c.id), .Plus, "New chat", 0, text_w_max) // the harness picker (harness.odin)
}

// Session rows (a project's, indented under it, or Chats, each with a
// bubble): title, then the time and status dot; on hover pin, "…" and, for
// an open session, close buttons instead of the time. Another machine's (remote): no buttons (its
// rows have no menu yet: sidebar_context); while that machine is not online (live false) greyed,
// without a status, and not clickable.
@(private = "file")
session_rows :: proc(rows: []core.Sidebar_Row, project_id: u64, cs: ^core.Open_Session, prefix: string, text_w_max, indent: f32, remote := false, live := true) {
	th := theme()
	chat := prefix == "chat"
	for r, i in rows {
		if i > 0 && rows[i - 1].pin >= 0 && r.pin < 0 do pinned_divider(indent)
		s := r.session
		id := clay.ID("sessoff", u32(i)) // not clickable while its machine is not online
		if live {
			if chat do append(&drawn.chat, keep(s.id))
			else do append(&drawn.sess, keep(s.id))
			id = clay.ID(prefix, u32(i))
		}
		current := cs != nil && s.id == cs.pi_session_id
		open_id := open_session_of(project_id, s.id)
		close_hover := !remote && open_id != 0 && ui_hover == Hit(Hit_Close_Session(open_id))
		pin_hover := !remote && ui_hover == Hit(Hit_Pin_Session(s.id))
		more_hover := !remote && ui_hover == Hit(Hit_More_Session(s.id))
		info_hover := !remote && ui_hover == Hit(Hit_Info_Session(s.id))
		row_hit: Hit = chat ? Hit(Hit_Chat(s.id)) : Hit(Hit_Session(s.id))
		row_hover := live && ui_hover == row_hit
		hovered := !remote && (row_hover || close_hover || pin_hover || more_hover || info_hover) // its buttons show
		bg, em := overlay(id, current, row_hover || hovered)
		cfg := row_cfg(bg)
		cfg.layout.padding.left = pu(PAD_ROW + indent)
		if state.focus_widget == "rename_session" && s.id == rename_session {
			rename_field_layout(indent) // renaming this Claude row (claude_rename on Enter)
			continue
		}
		if clay.UI(id)(cfg) {
			v := core.session_status_view(s.id)
			if !live do v = {progress = -1} // what it showed last: no status
			st := v.dot
			// an open session keeps its mark's room (a Claude session open as a tab of a pi one too)
			marked := open_id != 0 || st != .None || (s.claude && core.claude_open_tab(s.id) != 0)
			// "needs you" outranks the time
			when_ := st == .Waiting ? "Waiting for you" : (r.hidden ? "hidden" : rel_time(s.when_))
			if st != .Waiting && !r.hidden && state.sidebar.sort[chat ? .Chats : .Sessions] == .Recent do when_ = core.ago(s.modified)
			if st != .Waiting && !r.hidden && s.path == "" && !s.claude do when_ = "new" // pi has not written it yet
			if st != .Waiting && s.gone do when_ = "transcript gone" // Claude Code removed it (claude_disk.odin)
			tag := remote ? "" : core.session_account_tag(s^) // several Claude accounts: which one (claude_accounts.odin; another machine's is unknown here)
			// children: harness icon, title, [account], spacer, then time and dot, or the buttons
			right: f32
			n := 3
			if hovered {
				nb := open_id != 0 ? 4 : 3
				if !session_row_has_info(s^) do nb -= 1 // no ⓘ
				right = f32(nb) * px(ROW_BUTTON)
				n += nb
			} else {
				right = text_w(when_)
				n += 1
			}
			if tag != "" {
				right += text_w(tag, FONT_UI_SMALL)
				n += 1
			}
			if marked {
				right += px(MARK)
				n += 1
			}
			lead := px(HARNESS_ICON_SIZE)
			room := text_w_max - px(indent) - lead - right - f32(n - 1) * px(GAP_INLINE)
			col := mix(th.text_secondary, th.text, em)
			if r.hidden || s.gone || !live do col = th.text_muted
			// which agent it runs (pi or Claude Code): every row, in Chats too (in the bubble's place)
			icon(core.harness_row_icon(core.session_harness(s^), r.hidden || s.gone || !live), th.text_muted, HARNESS_ICON_SIZE)
			clay.TextDynamic(clip(core.session_label(s^, chat), room), txt(col))
			if tag != "" do clay.TextDynamic(tag, txt(th.text_muted, FONT_UI_SMALL))
			spacer()
			if !hovered do clay.TextDynamic(when_, txt(st == .Waiting ? th.waiting : th.text_muted))
			if marked do status_mark_el(v)
			row_button(clay.ID(chat ? "chatpin" : "sesspin", u32(i)), r.pin >= 0 ? "★" : "☆", hovered, pin_hover)
			if session_row_has_info(s^) do row_button(clay.ID(chat ? "chatinfo" : "sessinfo", u32(i)), "", hovered, info_hover, .Info) // a Claude row's: Deckhand's own record
			row_button(clay.ID(chat ? "chatmore" : "sessmore", u32(i)), "", hovered, more_hover, .More)
			if open_id != 0 do row_button(clay.ID(chat ? "chatclose" : "sessclose", u32(i)), "", hovered, close_hover, .Close)
		}
	}
}

// Whether a row has its ⓘ: a pi row's comes from its file; a Claude row's from Deckhand's history
// entry (an open Claude-only session not in it yet has none).
session_row_has_info :: proc(s: core.Session) -> bool {
	if !s.claude do return true
	r, _ := core.claude_record(s.id)
	return r != nil
}

// The eye on a hovered row that can be peeked (the Attention view's, the empty centre's, the
// bell's: ui_peek.odin).
peek_row_button :: proc(id: clay.ElementId, shown, hovered: bool) {
	row_button(id, "", shown, hovered, .Eye)
}

// A small button on a row, shown while the row is hovered (fades).
@(private = "file")
row_button :: proc(id: clay.ElementId, glyph: string, shown, hovered: bool, ic := core.Icon.None) {
	th := theme()
	a := fade(id, 1, shown ? 1 : 0, DUR_HOVER)
	if !shown do return // the row's time takes the place back at once
	bg, _ := overlay(id, false, hovered)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(px(ROW_BUTTON)), clay.SizingFixed(px(ROW_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		col := with_alpha(hovered ? th.text : th.text_muted, a)
		if ic != .None do icon(ic, col, ICON_SIZE_SM)
		else do clay.TextDynamic(glyph, txt(col))
	}
}


// The rename field takes the selected project's row while it has focus: an
// accent focus ring around the field surface.
@(private = "file")
rename_field_layout :: proc(indent: f32 = 0) {
	th := theme()
	if clay.UI(clay.ID("rename_field"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = clay.PaddingAll(pu(FOCUS_RING_W))},
		backgroundColor = cc(th.accent),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(PAD_ROW - FOCUS_RING_W + indent), 0, 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD - FOCUS_RING_W)),
		}) {
			field_text(clay.ID("rename_text"), &rename_field, "")
		}
	}
}

// The open menu, floating at its anchor, above the terminals.
menu_layout :: proc(w, h: f32) {
	if !menu.open do return
	th := theme()
	items := menu_items()
	if len(items) == 0 {
		menu_close()
		return
	}
	handoff_drawn_note(items) // what a click on a row acts on (ui_handoff.odin)
	box_h := px(2 * PAD_OVERLAY)
	// as wide as its longest row, between MENU_W and MENU_W_MAX (longer labels are cut)
	need: f32 = 0
	for it in items {
		box_h += it.sep ? px(MENU_SEP_H) : px(MENU_ROW_H)
		if !it.sep do need = max(need, menu_row_need(it))
	}
	box_w := clamp(need + px(2 * PAD_OVERLAY + 2 * PAD_ROW), px(MENU_W), px(MENU_W_MAX))
	inner := box_w - px(2 * PAD_OVERLAY + 2 * PAD_ROW)
	x := clamp(menu.at.x, 0, max(w - box_w, 0))
	y := clamp(menu.at.y, 0, max(h - box_h, 0))
	if clay.UI(clay.ID("menu"))({
		layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(PAD_OVERLAY))},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 8},
	}) {
		overlay_shadow("menu_shadow", 8)
		for it, i in items {
			if it.sep {
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_SEP_H))}, childAlignment = {y = .Center}}}) {
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(th.border)}) {}
				}
				continue
			}
			id := clay.ID("menurow", u32(i))
			if it.note {
				if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childAlignment = {y = .Center}}}) {
					clay.TextDynamic(clip(it.label, inner, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
				}
				continue
			}
			bg, em := overlay(id, i == menu.selected, ui_hover == Hit(Hit_Menu_Row(i)))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(MENU_ROW_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				if it.icon != .None do icon(it.icon, mix(th.text_muted, th.text_secondary, em), menu_icon_size(it.icon))
				clay.TextDynamic(clip(it.label, inner - (menu_row_need(it) - text_w(it.label))), txt(mix(th.text_secondary, th.text, em)))
				spacer()
				if it.keys != "" do clay.TextDynamic(it.keys, txt(th.text_muted, FONT_UI_SMALL))
				if it.check do icon(.Check, th.accent, ICON_SIZE_SM)
			}
		}
	}
}

// A menu row's icon: a harness's logo a little larger (the New session picker).
@(private = "file")
menu_icon_size :: proc(ic: core.Icon) -> f32 {return icon_logo(ic) != .None ? MENU_LOGO_SIZE : HARNESS_ICON_SIZE}

// A menu row's width without padding: label, then the shortcut or check
// after a spacer (two gaps).
@(private = "file")
menu_row_need :: proc(it: core.Menu_Item) -> f32 {
	w := it.note ? text_w(it.label, FONT_UI_SMALL) : text_w(it.label)
	if it.icon != .None do w += px(menu_icon_size(it.icon) + GAP_INLINE)
	if it.keys != "" do w += text_w(it.keys, FONT_UI_SMALL) + 2 * px(GAP_INLINE)
	if it.check do w += px(ICON_SIZE_SM) + 2 * px(GAP_INLINE)
	if it.keys != "" && it.check do w -= px(GAP_INLINE)
	return w
}

// A soft shadow under a floating box (menus, the settings popover, the
// sheet): a darker copy of it, a little larger and lower, drawn behind it.
// Its element id is in main.odin's overlay list (drawn above the terminal).
overlay_shadow :: proc(name: string, z: i16) {
	col := theme().shadow
	for layer in 0 ..< 2 {
		spread := px(SHADOW_SPREAD * f32(2 - layer)) // the outer, fainter layer first
		if clay.UI(clay.ID(name, u32(layer)))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}},
			backgroundColor = cc(with_alpha(col, layer == 0 ? 0.5 : 1)),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1) + spread),
			floating = {attachTo = .Parent, offset = {0, px(SHADOW_Y)}, expand = {spread, spread}, zIndex = z - 1, pointerCaptureMode = .Passthrough},
		}) {}
	}
}

// ---- hits and input ----

// Hits in the left column (after the menu, Home and the palette had theirs).
sidebar_hit :: proc() -> Hit {
	if clay.PointerOver(clay.ID("waitingfiltered")) do return Hit_Waiting_Filtered{}
	for v in core.Sidebar_View do if clay.PointerOver(clay.ID("viewseg", u32(v))) do return Hit_Attention(v) // By project | Attention
	if clay.PointerOver(clay.ID("attnidle")) do return Hit_Attention(ATTN_HIT_IDLE)
	if clay.PointerOver(clay.ID("attnfoot")) do return Hit_Attention(ATTN_HIT_FOOTER)
	if clay.PointerOver(clay.ID("filter_clear")) do return Hit_Filter_Clear{}
	if clay.PointerOver(clay.ID("filter_box")) do return Hit_Filter{}
	for _, i in QUICK_LABELS do if clay.PointerOver(clay.ID("chip", u32(i))) do return Hit_Quick(i)
	for sec in core.Sort_Section do if clay.PointerOver(clay.ID("sort", u32(sec))) do return Hit_Sort(sec)
	if clay.PointerOver(clay.ID("addproject")) do return Hit_Add_Project{}
	if c := core.chats_project(); c != nil && clay.PointerOver(clay.ID("newchatchats")) do return Hit_New_In(c.id)
	for f in core.Sidebar_Fold do if clay.PointerOver(clay.ID("navhead", u32(f))) do return Hit_Fold(f)
	for i in 0 ..< 2 do if clay.PointerOver(clay.ID("showmore", u32(i))) do return Hit_Show_More(i)
	if clay.PointerOver(clay.ID("newjob")) do return Hit_New_Job_In(state.selected_project)
	if c := core.chats_project(); c != nil && clay.PointerOver(clay.ID("newchatrow")) do return Hit_New_In(c.id)
	for id, i in drawn.open {
		if clay.PointerOver(clay.ID("openpeek", u32(i))) && peek_tab_of(find_session(id)) != nil do return Hit_Peek_Row(id)
		if clay.PointerOver(clay.ID("openmore", u32(i))) do return Hit_More_Open(id)
		if clay.PointerOver(clay.ID("openclose", u32(i))) do return Hit_Close_Session(id)
		if clay.PointerOver(clay.ID("open", u32(i))) do return Hit_Open_Row(id)
	}
	for path, i in drawn.group do if clay.PointerOver(clay.ID("grp", u32(i))) do return Hit_Group(path)
	if state.settings.remote_machines && clay.PointerOver(clay.ID("machmore", 0)) do return Hit_Machine_More(0) // this Mac's "…"
	if state.settings.remote_machines && clay.PointerOver(clay.ID("machhead", 0)) do return Hit_Machine_Head(0) // this Mac's
	for m in state.machines {
		if clay.PointerOver(clay.ID("machact", u32(m.no))) do return Hit_Machine(m.no)
		if clay.PointerOver(clay.ID("machmore", u32(m.no))) do return Hit_Machine_More(m.no)
		if clay.PointerOver(clay.ID("machhead", u32(m.no))) do return Hit_Machine_Head(m.no)
	}
	if clay.PointerOver(clay.ID("machadd")) do return Hit_Machine_Add{}
	for id, i in drawn.proj {
		if clay.PointerOver(clay.ID("projkids", u32(i))) do return Hit_Kids(id)
		if clay.PointerOver(clay.ID("projpin", u32(i))) do return Hit_Pin_Project(id)
		if clay.PointerOver(clay.ID("projnew", u32(i))) do return Hit_New_In(id)
		if clay.PointerOver(clay.ID("projmore", u32(i))) do return Hit_More_Project(id)
		if clay.PointerOver(clay.ID("proj", u32(i))) do return Hit_Project(id)
	}
	if c := core.chats_project(); c != nil {
		for sid, i in drawn.chat {
			if clay.PointerOver(clay.ID("chatpin", u32(i))) do return Hit_Pin_Session(sid)
			if clay.PointerOver(clay.ID("chatinfo", u32(i))) do return Hit_Info_Session(sid)
			if clay.PointerOver(clay.ID("chatmore", u32(i))) do return Hit_More_Session(sid)
			if clay.PointerOver(clay.ID("chatclose", u32(i))) {
				if id := open_session_of(c.id, sid); id != 0 do return Hit_Close_Session(id)
			}
			if clay.PointerOver(clay.ID("chat", u32(i))) do return Hit_Chat(sid)
		}
	}
	for sid, i in drawn.sess {
		if clay.PointerOver(clay.ID("sesspin", u32(i))) do return Hit_Pin_Session(sid)
		if clay.PointerOver(clay.ID("sessinfo", u32(i))) do return Hit_Info_Session(sid)
		if clay.PointerOver(clay.ID("sessmore", u32(i))) do return Hit_More_Session(sid)
		if clay.PointerOver(clay.ID("sessclose", u32(i))) {
			if id := open_session_of(state.selected_project, sid); id != 0 do return Hit_Close_Session(id)
		}
		if clay.PointerOver(clay.ID("sess", u32(i))) do return Hit_Session(sid)
	}
	return nil
}

// A left click on a left-column hit (main.odin passes the new ones here).
sidebar_click :: proc(hit: Hit, at: [2]f32) {
	#partial switch h in hit {
	case Hit_Chat:
		if c := core.chats_project(); c != nil do ui_do(core.Open_Session_Cmd{c.id, string(h)})
	case Hit_Group:
		path := string(h)
		open, forced := row_state(path)
		if !forced do ui_do(core.Set_Row_Expanded{path = path, expanded = !open}) // kept open: the saved state stays
	case Hit_Kids:
		if p := core.find_project(u64(h)); p != nil {
			open, forced := row_state(p.cwd)
			if !forced do ui_do(core.Set_Row_Expanded{path = p.cwd, expanded = !open})
		}
	case Hit_Machine:
		machine_run_action(u64(h))
	case Hit_Machine_Head:
		machine_fold_toggle(u64(h))
	case Hit_Machine_More: // its menu, under the button (as a right click on its header opens it)
		at := at
		if d := clay.GetElementData(clay.ID("machmore", u32(u64(h)))); d.found do at = {d.boundingBox.x, d.boundingBox.y + d.boundingBox.height}
		menu_open(Menu_Machine(u64(h)), at)
	case Hit_Machine_Add:
		machine_add_open()
	case Hit_Attention:
		switch int(h) {
		case ATTN_HIT_IDLE:
			attention_idle_open = !attention_idle_open
			app.redraw = true
		case ATTN_HIT_FOOTER: ui_do(core.Set_Sidebar_View{view = .Projects})
		case:                 ui_do(core.Set_Sidebar_View{view = core.Sidebar_View(h)})
		}
	case Hit_Open_Row:
		// the Attention view's: where ⌥⌘A would go in it (its tab of its tier)
		if state.sidebar.view == .Attention {
			attention_go(u64(h))
			break
		}
		// focus it and show its project's sessions
		if s := core.find_session(u64(h)); s != nil {
			ui_do(core.Focus_Session{session = s.id, reopen = true}) // a dead pi starts again (dead_tab.odin)
			if p := core.find_project(s.project_id); p != nil && p.group == .Projects && p.id != state.selected_project do ui_do(core.Select_Project{p.id})
		}
	case Hit_Pin_Project:
		if p := core.find_project(u64(h)); p != nil do ui_do(core.Set_Pinned{project_id = p.id, pinned = core.project_pinned(p^) < 0})
	case Hit_Pin_Session:
		ui_do(core.Set_Pinned{pi_session_id = string(h), pinned = core.session_pinned(string(h)) < 0})
	case Hit_New_In:
		new_session_ui(u64(h), at = at) // the harness picker (harness.odin)
	case Hit_Add_Project:
		add_project_dialog()
	case Hit_Sort:
		if d := clay.GetElementData(clay.ID("sort", u32(core.Sort_Section(h)))); d.found {
			b := d.boundingBox
			menu_open(Menu_Sort(core.Sort_Section(h)), {b.x, b.y + b.height})
		}
	case Hit_Fold:
		f := core.Sidebar_Fold(h)
		ui_do(core.Set_Sidebar_Folded{section = f, folded = !state.sidebar.folded[f]})
	case Hit_Filter:
		filter_focus()
	case Hit_Filter_Clear:
		ui_do(core.Set_Filter{text = ""})
	case Hit_Waiting_Filtered:
		ui_do(core.Set_Filter{text = "", running = false, waiting = false, pinned = false})
	case Hit_More_Project, Hit_More_Session, Hit_More_Open:
		sidebar_context(hit, at) // the row's context menu, as a right click opens it
	case Hit_Info_Session:
		session_info_menu(string(h))
	case Hit_New_Job_In:
		if p := core.find_project(u64(h)); p != nil do ui_do(core.Job_Sheet{open = true, for_project = core.path_tilde(p.cwd)})
	case Hit_Show_More:
		if int(h) == 0 do tree.all_sessions = true
		else do tree.all_chats = true
		app.redraw = true
	case Hit_Quick:
		switch int(h) {
		case 0: ui_do(core.Set_Filter{running = !state.sidebar.only_running})
		case 1: ui_do(core.Set_Filter{waiting = !state.sidebar.only_waiting})
		case 2: ui_do(core.Set_Filter{pinned = !state.sidebar.only_pinned})
		}
	}
}

// A right click (or ⌃-click): the row's context menu. True if it had one.
sidebar_context :: proc(hit: Hit, at: [2]f32) -> bool {
	// another machine's rows have no full menu yet: what it offers would act there (M6-C). Its open
	// session, while that machine is online: only what acts there as the user's (#114: Peek, Mark as
	// unread or read; remote_session_items)
	#partial switch h in hit {
	case Hit_Project: if core.id_machine(u64(h)) != 0 do return false
	case Hit_Open_Row:
		if core.id_machine(u64(h)) != 0 {
			s := core.find_session(u64(h))
			if s == nil || !machine_online(s.machine) do return false
			if remote_id_bare(s.pi_session_id) && peek_tab_of(s) == nil do return false // nothing to offer
			menu_open(Menu_Session{project_id = s.project_id, pi_session_id = s.pi_session_id, session = s.id}, at)
			return true
		}
	case Hit_Session: if core.id_machine(state.selected_project) != 0 do return false
	}
	#partial switch h in hit {
	case Hit_Project, Hit_Pin_Project, Hit_More_Project:
		id: u64
		#partial switch x in h {
		case Hit_Project:      id = u64(x)
		case Hit_Pin_Project:  id = u64(x)
		case Hit_More_Project: id = u64(x)
		}
		menu_open(Menu_Project(id), at)
	case Hit_New_In:
		if p := core.find_project(u64(h)); p != nil && p.group == .Projects do menu_open(Menu_Project(p.id), at)
		else do return false
	case Hit_New_Job_In:
		menu_open(Menu_Project(u64(h)), at)
	case Hit_Machine_Head:
		menu_open(Menu_Machine(u64(h)), at) // this Mac's: Add a machine…, Machines settings…
	case Hit_Machine:      menu_open(Menu_Machine(u64(h)), at)
	case Hit_Machine_More: menu_open(Menu_Machine(u64(h)), at)
	case Hit_Session:
		menu_open(Menu_Session{project_id = state.selected_project, pi_session_id = string(h)}, at)
	case Hit_Chat:
		c := core.chats_project()
		if c == nil do return false
		menu_open(Menu_Session{project_id = c.id, pi_session_id = string(h)}, at)
	case Hit_Pin_Session, Hit_More_Session, Hit_Info_Session:
		sid: string
		#partial switch x in h {
		case Hit_Pin_Session:  sid = string(x)
		case Hit_More_Session: sid = string(x)
		case Hit_Info_Session: sid = string(x)
		}
		menu_open(Menu_Session{project_id = session_row_project(sid), pi_session_id = sid}, at)
	case Hit_Open_Row, Hit_Close_Session, Hit_More_Open:
		id: u64
		#partial switch x in h {
		case Hit_Open_Row:      id = u64(x)
		case Hit_Close_Session: id = u64(x)
		case Hit_More_Open:     id = u64(x)
		}
		s := core.find_session(id)
		if s == nil do return false
		menu_open(Menu_Session{project_id = s.project_id, pi_session_id = s.pi_session_id}, at)
	case:
		return false
	}
	return true
}

// A session row's ⓘ: a menu under it with the session's info (its header
// and file only, session_info.odin), Copy session info and Send to Atlas.
session_info_menu :: proc(sid: string) {
	pid := session_row_project(sid)
	_, text, err := core.session_info_build(pid, sid)
	if err != "" do text = fmt.tprintf("(%s)", err)
	at := app.pointer
	for name in ([]string{"sessinfo", "chatinfo"}) do for s, i in (name == "sessinfo" ? drawn.sess[:] : drawn.chat[:]) {
		if s != sid do continue
		if d := clay.GetElementData(clay.ID(name, u32(i))); d.found do at = {d.boundingBox.x, d.boundingBox.y + d.boundingBox.height}
	}
	menu_open(Menu_Session{project_id = pid, pi_session_id = sid, info = text}, at)
}

// The project (or Chats) a session row's buttons act in.
session_row_project :: proc(sid: string) -> u64 {
	if id := core.open_session_any(sid); id != 0 do return core.find_session(id).project_id // also a new one, not listed yet
	if c := core.chats_project(); c != nil && core.session_listed(state.chats[:], sid) do return c.id
	return state.selected_project
}

// The keyboard into the filter field (⇧⌘F, a click on it).
filter_focus :: proc() {
	if state.focus_widget != "sidebar_filter" do tf_set(&filter_field, state.sidebar.filter)
	tf_select_all(&filter_field)
	ui_do(core.Set_Focus{"sidebar_filter"})
}

// Enter in the filter: the best-scoring row (sidebar_best_match). A project
// is selected; a session or chat opens.
filter_enter :: proc() {
	if attention_enter() {} 	// the Attention view: its keyboard's row, else its first
	else if cmd := core.sidebar_best_match(); cmd != nil do ui_do(cmd)
	ui_do(core.Set_Focus{""})
}

// "+" on the Projects header (and the palette's Add project…): the folder
// picker (a modal loop: run outside this event handler), then add_project.
add_project_dialog :: proc() {
	if core.platform.run_later == nil || win_os.pick_folder == nil do return
	core.platform.run_later(proc() {
		path := strings.clone(win_os.pick_folder())
		defer delete(path)
		if path != "" do ui_do(core.Add_Project{cwd = path})
	})
}

// Files dropped on the window at (x, y) framebuffer px. On the left column
// folders become projects (files are ignored; the last one is selected). On
// the current tab's terminal the paths are pasted shell-quoted,
// as other terminals do. Anywhere else: nothing.
sidebar_drop :: proc(paths: []string, x, y: f32) {
	if job_sheet_open() do return // the job sheet is modal: nothing behind it takes files
	if over_sidebar(x) {
		for p in paths do if os.is_dir(p) do ui_do(core.Add_Project{cwd = p})
		return
	}
	tab: ^core.Tab
	if !(state.home_open && inside(clay.ID("drawer"), x, y)) {
		if t := active_view(); t != nil && in_pane(t, x, y) do tab = core.active_tab()
	}
	if tab == nil || len(paths) == 0 do return
	b := strings.builder_make(context.temp_allocator)
	for p in paths {
		strings.write_string(&b, shell_quote(p))
		strings.write_byte(&b, ' ')
	}
	// Deckhand's text, not the user's typing: the core applies a Codex composer's rule (a path with
	// " @x" would open its picker) on its own state and says why not
	if r := client_call(core.Send_Text{tab_id = tab.id, text = strings.to_string(b), generated = true}); !r.ok do toast_show(fmt.tprintf("Not dropped: %s", r.error), err = true)
}

// 'path' for a POSIX shell (a ' inside becomes '\'').
shell_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", `'\''`, context.temp_allocator)
	return strings.concatenate({"'", q, "'"}, context.temp_allocator)
}

// "N waiting (filtered)": waiting sessions the filter took out of a list; a
// click clears the filter.
@(private = "file")
waiting_filtered_row :: proc() {
	n := core.sidebar_waiting_filtered()
	if n == 0 do return
	th := theme()
	id := clay.ID("waitingfiltered")
	bg, em := overlay(id, false, ui_hover == Hit(Hit_Waiting_Filtered{}))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(CHIP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		dot(th.waiting)
		clay.TextDynamic(fmt.tprintf("%d waiting (filtered)", n), txt(mix(th.waiting, th.text, em), FONT_UI_SMALL))
		spacer()
		clay.Text("Clear filter", txt(th.text_muted, FONT_UI_SMALL))
	}
}

// The picker's project is gone (a rescan dropped it): the menu closes.
new_session_target_gone :: proc() -> bool {
	t, ok := menu.target.(core.Menu_New_Session)
	return ok && core.find_project(t.project_id) == nil
}

// ---- other machines (machine_mirror.odin; Settings › Machines over SSH) ----

// What a machine's button does, the sidebar's and Settings' alike (core.machine_action_label).
// A failure shows as a toast (ui_do_menu): never a click that does nothing.
machine_run_action :: proc(no: u64) {
	for m in state.machines do if m.no == no {
		label := core.machine_action_label(m)
		switch label {
		case "Cancel":         ui_do_menu(core.Machine_Install{no = no, cancel = true}, "Cancel the install")
		case "Install…", "Update", "Retry": ui_do_menu(core.Machine_Install{no = no}, label == "Update" ? "Update" : "Install")
		case "Keep running…":  ui_do_menu(core.Machine_Linger{no = no}, label) // the user said yes: linger --enable there
		case "Log in…":        ui_do_menu(core.Machine_Login{no = no}, label)
		case "Connect", "Take back", "Try again": ui_do_menu(core.Machine_Connect{no = no}, label)
		}
	}
}

// What a machine's button does, in a few words (its tooltip, the sidebar's and Settings').
machine_action_tip :: proc(m: core.Machine_View) -> string {
	switch core.machine_action_label(m) {
	case "Cancel":        return "Stop the install (what it copied is removed)"
	case "Retry":         return "Try the install again"
	case "Install…":      return "Install Deckhand there over your ssh (nothing runs there but Deckhand's own install)"
	case "Update":        return "Install this Mac's version there; its sessions keep running"
	case "Keep running…": return "Keep its jobs running after you log out of it (asks its login manager; no password)"
	case "Log in…":       return "Open a tab here that runs ssh to it, so you can type its password or passphrase"
	case "Take back":     return "Show its sessions here again (its own window lets go)"
	case "Connect":       return "Try to connect now"
	case "Try again":     return "Try to connect again, once you have fixed it on that machine"
	}
	return ""
}

// A machine in a tooltip: its name and target, why (or its status), then ssh's own words.
machine_tip :: proc(m: core.Machine_View) -> string {
	label, why, raw := core.machine_status_text(m)
	head := m.name
	if m.target != "" && m.target != m.name do head = fmt.tprintf("%s (%s)", m.name, m.target)
	tip := fmt.tprintf("%s: %s", head, why != "" ? why : label)
	if m.status == .Online && m.version != "" && why == "" do tip = fmt.tprintf("%s, Deckhand %s", tip, m.version)
	if raw != "" && raw != why do tip = fmt.tprintf("%s\n%s", tip, raw) // cleaned and bounded where it was kept (text_clean)
	return tip
}

MACHINE_ADD_TIP :: "Add a machine you reach with ssh: user@host or a name from ~/.ssh/config. Deckhand uses your own ssh and keys"

// The sidebar's + Add a machine… and the palette's: the add field in Settings; once the machine is
// added, back to Sessions (machine_add_back). Settings' own row opens the field and stays there.
machine_add_open :: proc() {
	machine_edit_begin()
	machine_add_back = true
}

// The add field was opened from the sidebar or the palette: a machine added goes back to Sessions.
machine_add_back: bool

// Each other machine under its name, after this Mac's sections: a status dot, what is wrong (two
// lines at most; its tooltip has ssh's own words), its open sessions, then its projects (the
// selected one with its sessions), drawn as this Mac's rows are and through the same filter and
// quick filters. While it is not online its rows are greyed: what it showed last (kept in memory
// only). Folded (its header): only its waiting open sessions. Then + Add a machine…, while Machines
// over SSH is on.
@(private = "file")
machines_sections :: proc(cs: ^core.Open_Session, text_w_max: f32) {
	if !state.settings.remote_machines do return
	if core.machines_in_sidebar() do for m in state.machines {
		live := m.status == .Online
		gap(GAP_SECTION)
		label, why, _ := core.machine_status_text(m)
		// an online machine's sentence is in its tooltip, but for an update to make there (no button says it)
		note := why
		if live && m.update != .Command_Only do note = ""
		opens := core.machine_open_rows(m.no)
		folded := machine_folded(m.no)
		// a note under it says what is wrong: the header keeps its name and button, not the status too
		machine_header(m.no, machine_dot(m), m.name, note != "" ? "" : label, core.machine_action_label(m), len(opens), text_w_max)
		if note != "" do wrapped_note(note, text_w_max)
		for o in opens {
			if folded && !core.session_waiting(o.pi_session_id) do continue // folded: only waiting work stays
			open_row(o, cs, text_w_max, remote = true, live = live)
		}
		if folded do continue
		projects := core.machine_project_rows(m.no)
		for r in projects {
			append(&drawn.proj, r.project.id)
			project_row(r, len(drawn.proj) - 1, cs, text_w_max, 0, remote = true, live = live)
			if r.project.id == state.selected_project && !tree.folded do machine_sessions(cs, live, label, text_w_max)
		}
		if len(opens) + len(projects) > 0 do continue
		if core.sidebar_filtering() do list_note("No matches", 0, text_w_max)
		// nothing there: what makes a project appear (this Mac can't add one there)
		else if live do wrapped_note(MACHINE_EMPTY_HINT, text_w_max)
	}
	gap(GAP_SECTION)
	action_row(clay.ID("machadd"), Hit_Machine_Add{}, .Plus, "Add a machine…", 0, text_w_max)
}

// How to see everything again: Esc clears the filter's text, not a quick filter's chip.
filter_clear_hint :: proc() -> string {
	return state.sidebar.filter != "" ? "Esc in the filter clears it" : "Click the chip again to show all"
}

MACHINE_EMPTY_HINT :: "No projects there yet: start pi or Claude Code in a folder on it"

// The machines whose header is folded (not saved; this Mac's is the saved .This_Mac fold).
machines_folded: [dynamic]u64

machine_folded :: proc(no: u64) -> bool {
	if no == 0 do return state.sidebar.folded[.This_Mac]
	for x in machines_folded do if x == no do return true
	return false
}

// A click on a machine's header: fold or unfold it (this Mac's by command, so it is saved).
machine_fold_toggle :: proc(no: u64) {
	if no == 0 {
		ui_do(core.Set_Sidebar_Folded{section = .This_Mac, folded = !state.sidebar.folded[.This_Mac]})
		return
	}
	for x, i in machines_folded do if x == no {
		unordered_remove(&machines_folded, i)
		app.redraw = true
		return
	}
	append(&machines_folded, no)
	app.redraw = true
}

// A muted note of at most two lines under a machine's header (what is wrong, what to do).
@(private = "file")
wrapped_note :: proc(text: string, text_w_max: f32) {
	cfg := txt(theme().text_muted)
	cfg.wrapMode = .Newlines
	lines, _ := wrap_clip(text, text_w_max, 2)
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit({min = px(ROW_H)})}, padding = {pu(PAD_ROW), pu(PAD_ROW), pu(SP_1), pu(SP_1)}, childAlignment = {y = .Center}}}) {
		clay.TextDynamic(lines, cfg)
	}
}

// A machine's header: its dot, its name, its status (or "this Mac"), its mini-counts (what needs
// you and what works there, as the top bar's pill: ui_fleet.odin; none while it is offline), a
// count (its open sessions) and a fold chevron (shown while folded or hovered: a click folds it, as Open, Projects and Chats
// fold), then its button and, for another machine, its "…" (the right-click menu). no 0 = this Mac.
@(private = "file")
machine_header :: proc(no: u64, dot_col: core.Rgba, name, label, act: string, count: int, text_w_max: f32) {
	th := theme()
	id := clay.ID("machhead", u32(no))
	hit := Hit(Hit_Machine_Head(no))
	folded := machine_folded(no)
	_, em := overlay(id, false, ui_hover == hit)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}},
	}) {
		dot(dot_col)
		cnt := count > 0 ? fmt.tprint(count) : ""
		// children: dot, name, status, [mini-counts], [count], chevron, spacer, [button], [more]
		n := 6
		room := text_w_max - px(DOT + ICON_SIZE_SM - 2)
		if cnt != "" {
			room -= text_w(cnt, FONT_UI_SMALL)
			n += 1
		}
		if act != "" {
			room -= text_w(act, FONT_UI_SMALL) + px(2 * SP_2)
			n += 1
		}
		room -= px(ROW_BUTTON) // its "…"
		n += 1
		room -= f32(n - 1) * px(GAP_INLINE)
		nw := text_w(name, FONT_UI_SMALL | WEIGHT_HEADER)
		// its mini-counts, where the whole name still fits beside them (else the most urgent alone,
		// else none): they give way before the name, the status before them
		counts := fleet_of(no) // this frame's (ui_fleet.odin)
		counts_compact := false
		counts_w: f32 = 0
		if core.fleet_any(counts) {
			for compact in ([]bool{false, true}) {
				w := fleet_counts_w(counts, compact, FONT_UI_SMALL, px(HEAD_COUNTS_GAP))
				if room - nw - px(GAP_INLINE) >= w {
					counts_w, counts_compact = w, compact
					break
				}
			}
		}
		if counts_w > 0 do room -= counts_w + px(GAP_INLINE)
		// its name (never cut to nothing: the status gives way first), its status
		name_w := max(min(nw, max(room * 0.6, room - text_w(label, FONT_UI_SMALL))), min(nw, px(48)))
		if counts_w > 0 do name_w = nw // the room above was kept for it
		col := mix(th.text_secondary, th.text, em)
		clay.TextDynamic(clip(name, name_w, FONT_UI_SMALL | WEIGHT_HEADER), txt(col, FONT_UI_SMALL | WEIGHT_HEADER))
		if lw := room - name_w; label != "" && lw > px(SP_6) do clay.TextDynamic(clip(label, lw, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		if counts_w > 0 do fleet_counts_el(counts, counts_compact, FONT_UI_SMALL, px(HEAD_COUNTS_GAP), th.text_muted)
		if cnt != "" do clay.TextDynamic(cnt, txt(th.text_muted, FONT_UI_SMALL))
		a := fade(id, 7, folded || ui_hover == hit ? 1 : 0, DUR_HOVER)
		icon(folded ? .Chevron_Right : .Chevron_Down, with_alpha(col, a), ICON_SIZE_SM - 2)
		spacer()
		if act != "" {
			bid := clay.ID("machact", u32(no))
			bg, bem := overlay(bid, false, ui_hover == Hit(Hit_Machine(no)))
			if clay.UI(bid)({
				layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(ROW_BUTTON))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				clay.TextDynamic(act, txt(mix(th.text_secondary, th.text, bem), FONT_UI_SMALL))
			}
		}
		// every action has a button: its menu (Rename…, Remove…, Open web page…, Try again; this
		// Mac's: Add a machine…, Machines settings…) here too
		row_button(clay.ID("machmore", u32(no)), "", true, ui_hover == Hit(Hit_Machine_More(no)), .More)
	}
}

HEAD_COUNTS_GAP :: SP_2 // between a machine header's mini-counts

MACHINE_HERE_TIP :: "This Mac. Other machines you add appear below it."

machine_dot :: proc(m: core.Machine_View) -> core.Rgba {
	th := theme()
	if core.machine_install_failed(m) do return th.error
	#partial switch m.status {
	case .Online:     return th.done
	case .Connecting: return th.running
	case .Needs_Login, .Needs_Update, .Not_Installed, .Refused: return th.waiting
	}
	return with_alpha(th.text_muted, EXITED_ALPHA)
}

// A machine header's right-click menu: what applies to it now, then Settings' Machines group
// (machines_settings). This Mac's (no 0): Add a machine… and Machines settings….
machine_menu_items :: proc(no: u64, items: ^[dynamic]core.Menu_Item) {
	settings := core.Menu_Item{label = "Machines settings…", action = "machines_settings"}
	if no == 0 {
		append(items, core.Menu_Item{label = "Add a machine…", action = "machine_add"})
		append(items, settings)
		return
	}
	for m in state.machines do if m.no == no {
		#partial switch m.status {
		case .Needs_Login: append(items, core.Menu_Item{label = "Log in…", cmd = core.Machine_Login{no = no}})
		case .Taken:       append(items, core.Menu_Item{label = "Take back", cmd = core.Machine_Connect{no = no}})
		case .Offline:     append(items, core.Menu_Item{label = "Connect", cmd = core.Machine_Connect{no = no}})
		case .Refused, .Unsupported: append(items, core.Menu_Item{label = "Try again", cmd = core.Machine_Connect{no = no}}) // after the fix on that machine
		}
		if m.status == .Online do append(items, core.Menu_Item{label = "Open web page…"}) // menu_run: the palette asks for the port
		if len(items) > 0 do append(items, core.Menu_Item{sep = true})
		append(items, core.Menu_Item{label = "Rename…", rename = true})
		append(items, core.Menu_Item{label = "Remove…", cmd = core.Machine_Remove{no = no}})
		append(items, core.Menu_Item{sep = true})
		append(items, settings)
	}
}

// The selected project's sessions, as that machine lists them, drawn as this Mac's are. While it
// is online a click opens one there (Open_Session_Cmd, as a local row's: machine_route.odin sends
// it), and + New session starts one there (the local row's harness picker).
@(private = "file")
machine_sessions :: proc(cs: ^core.Open_Session, live: bool, label: string, text_w_max: f32) {
	rows := core.sidebar_sessions(.Sessions)
	if len(rows) == 0 && !live do list_note(label, TREE_INDENT, text_w_max)
	else if len(rows) == 0 && !core.sidebar_filtering() do list_note("No sessions yet", TREE_INDENT, text_w_max)
	else if len(rows) == 0 do list_note("No matching sessions", TREE_INDENT, text_w_max)
	shown, more := capped_rows(rows, tree.all_sessions)
	session_rows(shown, state.selected_project, cs, "sess", text_w_max, TREE_INDENT, remote = true, live = live)
	if more > 0 do action_row(clay.ID("showmore", 0), Hit_Show_More(0), .None, fmt.tprintf("Show %d more", more), TREE_INDENT, text_w_max)
	if live do action_row(clay.ID("new"), Hit_New{}, .Plus, "New session", TREE_INDENT, text_w_max) // the harness picker (harness.odin)
}

// ---- the Attention view (state.sidebar.view; ⌥⌘., View › Attention view) ----

SIDEBAR_VIEW_LABELS := [core.Sidebar_View]string{.Projects = "By project", .Attention = "Attention"}
ATTENTION_LABELS := [core.Attention_Group]string{.Needs_You = "NEEDS YOU", .Finished = "FINISHED", .Working = "WORKING", .Idle = "IDLE"}

// The Attention view's controls (Hit_Attention): its switch's two segments (a Sidebar_View), the
// IDLE header (folds it), the footer (back to By project).
ATTN_HIT_IDLE :: 2
ATTN_HIT_FOOTER :: 3

// Window state, not saved: IDLE shows its rows (folded by default; shown while filtering anyway),
// and the row the keyboard is on (↑↓ in the filter field; an open session id, 0 = none).
attention_idle_open: bool
attention_sel: u64
attention_keyed: bool // attention_sel was picked with ↑↓ since the field was typed in: Space peeks at it (ui_peek.odin)

// By project | Attention, at the top of the Sessions tab: a two-segment switch in the left tabs'
// style, a little lower.
@(private = "file")
view_switch :: proc(row_w: f32) {
	th := theme()
	if clay.UI(clay.ID("viewswitch"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(CHIP_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		seg := (row_w - px(4 + 2)) / 2
		for v in core.Sidebar_View {
			id := clay.ID("viewseg", u32(v))
			on := state.sidebar.view == v
			bg, em := overlay(id, false, ui_hover == Hit(Hit_Attention(v)))
			if on do bg = cc(mix(th.bg_elevated, th.text, TINT_SEGMENT))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				col := on ? th.text : mix(th.text_muted, th.text_secondary, em)
				clay.TextDynamic(clip(SIDEBAR_VIEW_LABELS[v], seg - px(2 * SP_1), FONT_UI_SMALL), txt(col, FONT_UI_SMALL))
			}
		}
	}
}

// The rows the Attention view shows now, in order: core.attention_rows without IDLE's while it is
// folded (temp allocator).
attention_shown :: proc() -> []core.Attention_Row {
	rows := core.attention_rows()
	if attention_idle_open || core.sidebar_filtering() do return rows
	n := 0
	for r in rows do if r.group != .Idle do n += 1
	return rows[:n] // IDLE's rows are last
}

// Where a row of the Attention view says it runs (its machine column).
@(private = "file")
attention_machine :: proc(no: u64) -> string {return no == 0 ? "this Mac" : core.machine_name(no)}

// The Attention view: every open session on this Mac and the other machines, one list by what
// needs you (core.attention_rows: needing_you's order: ⌥⌘A walks it, from after the current session),
// under small headers with their counts, an empty group left out:
//
//	NEEDS YOU  2      waiting for you, then errors; the longest waiting first
//	FINISHED  1       finished, not seen yet
//	WORKING  3
//	IDLE  4 ›         every other open session (folded until opened; shown while filtering)
//
// Each row is the Open group's (open_row: its place, title, what it asks, its age and mark, the
// current session selected; its menu as there), with a machine column while other machines are in
// play. The filter and quick filters apply as to the Open group. Built once per layout, while shown.
@(private = "file")
attention_list :: proc(cs: ^core.Open_Session, text_w_max, row_w: f32) {
	attention_scroll_to() // the keyboard's row moved: into view (by the last layout's boxes)
	// renaming a project or a Claude session from the palette: the field on top (no tree here)
	if state.focus_widget == "rename_project" || state.focus_widget == "rename_session" do rename_field_layout()
	rows := core.attention_rows()
	if len(rows) == 0 {
		any_open := false
		for s in state.open_sessions do if !s.home do any_open = true
		if any_open do empty_state("No matching sessions", filter_clear_hint(), row_w)
		else do attention_empty(row_w)
		return
	}
	counts: [core.Attention_Group]int
	for r in rows do counts[r.group] += 1
	// the machine column while other machines are in play: as wide as its widest name, at most a
	// quarter of the row (120 px), so the names line up
	mach_w: f32
	if state.settings.remote_machines && len(state.machines) > 0 {
		for r in rows do mach_w = max(mach_w, text_w(attention_machine(r.session.machine), FONT_UI_SMALL))
		mach_w = min(mach_w, px(120), text_w_max / 4)
	}
	keys := state.focus_widget == "sidebar_filter" // the keyboard's row shows while the filter has it
	first := true
	for g in core.Attention_Group {
		if counts[g] == 0 do continue
		if !first do gap(SP_2)
		first = false
		idle := g == .Idle
		open := !idle || attention_idle_open || core.sidebar_filtering()
		attention_header(g, counts[g], idle, open)
		if !open do continue
		for r in rows {
			if r.group != g do continue
			s := r.session
			live := s.machine == 0
			for m in state.machines do if m.no == s.machine do live = m.status == .Online
			from := r.tier != core.NEED_NONE ? core.session_tier_tab(s, r.tier) : nil // the tab its place comes from
			open_row(s, cs, text_w_max, remote = s.machine != 0, live = live, mach = attention_machine(s.machine), mach_w = mach_w, key_sel = keys && s.id == attention_sel, from = from, peek = peek_tab_of(s) != nil)
		}
	}
}

// A group's header, in the section headers' style (nav_header): its name in small caps and its
// count; IDLE's folds (a chevron while folded or hovered).
@(private = "file")
attention_header :: proc(g: core.Attention_Group, count: int, foldable, open: bool) {
	th := theme()
	id := foldable ? clay.ID("attnidle") : clay.ID("attnhead", u32(g))
	hit := Hit(Hit_Attention(ATTN_HIT_IDLE))
	_, em := overlay(id, false, foldable && ui_hover == hit)
	if clay.UI(id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
		col := mix(th.text_muted, th.text_secondary, em)
		clay.TextDynamic(ATTENTION_LABELS[g], txt(col, FONT_UI_SMALL | WEIGHT_HEADER))
		clay.TextDynamic(fmt.tprint(count), txt(g == .Needs_You ? th.waiting : th.text_muted, FONT_UI_SMALL))
		if foldable {
			a := fade(id, 7, !open || ui_hover == hit ? 1 : 0, DUR_HOVER)
			icon(open ? .Chevron_Down : .Chevron_Right, with_alpha(col, a), ICON_SIZE_SM - 2)
		}
	}
}

// Nothing open anywhere: what to do, with the empty centre's two buttons (their hits are the
// Chats "+ New chat" row's and the Projects header's "+": the same pickers).
@(private = "file")
attention_empty :: proc(row_w: f32) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_2), pu(SP_2), pu(SP_2)}, childGap = pu(SP_3), layoutDirection = .TopToBottom}}) {
		room := row_w - px(2 * SP_2)
		lines, _ := wrap_clip("Nothing running. Start a chat or open a project.", room, 3)
		cfg := txt(th.text_secondary)
		cfg.wrapMode = .Newlines
		clay.TextDynamic(lines, cfg)
		chat_label, add_label := "New chat", "Add project…"
		if a := action_by_id("new_chat"); a != nil do chat_label = action_label(a)
		if a := action_by_id("add_project"); a != nil do add_label = action_label(a)
		// side by side while both fit, else one under the other
		both := text_w(chat_label, WEIGHT_BOLD) + text_w(add_label) + px(4 * SP_3 + SP_2)
		if clay.UI()({layout = {childGap = pu(SP_2), layoutDirection = both <= room ? .LeftToRight : .TopToBottom}}) {
			if c := core.chats_project(); c != nil do button(clay.ID("newchatrow"), chat_label, true, ui_hover == Hit(Hit_New_In(c.id)))
			button(clay.ID("addproject"), add_label, false, ui_hover == Hit(Hit_Add_Project{}))
		}
	}
}

// "3 machines · By project" under the list: the way back to the tree, always in view.
@(private = "file")
attention_footer :: proc(text_w_max: f32) {
	n := 1
	if state.settings.remote_machines do n += len(state.machines)
	label := n == 1 ? "This Mac · By project" : fmt.tprintf("%d machines · By project", n)
	action_row(clay.ID("attnfoot"), Hit_Attention(ATTN_HIT_FOOTER), .None, label, 0, text_w_max)
}

// What a row of the Attention view opens: where ⌥⌘A would go in it (fleet_go: its tab of its
// tier, another machine's through its row and tab), an idle one as the Open group's row does.
attention_go :: proc(sid: u64) {
	s := core.find_session(sid)
	if s == nil do return
	if core.session_need(s) != core.NEED_NONE do fleet_go(sid)
	else do ui_do(core.Focus_Session{session = sid, reopen = true}) // a dead pi starts again (dead_tab.odin)
}

// ↑↓ in the filter field while the Attention view shows: the keyboard's row moves (wrapping round).
// False: not this view (the field's own Home and End).
attention_step :: proc(d: int) -> bool {
	if state.sidebar.view != .Attention || state.layout.left_tab != .Sessions do return false
	rows := attention_shown()
	app.redraw = true
	if len(rows) == 0 do return true
	at := -1
	for r, i in rows do if r.session.id == attention_sel do at = i
	k := at < 0 ? (d > 0 ? 0 : len(rows) - 1) : (at + d + len(rows)) %% len(rows)
	attention_sel = rows[k].session.id
	attention_keyed = true
	attention_scroll = true
	return true
}

// The keyboard's row moved: the list scrolls it into view (attention_scroll_to, after the layout
// that draws it, from its box and the list's).
attention_scroll: bool

attention_scroll_to :: proc() {
	if !attention_scroll do return
	k := -1 // its row's element: the rows are drawn in attention_shown's order (drawn.open is reset by now)
	for r, i in attention_shown() do if r.session.id == attention_sel do k = i
	sc := clay.GetScrollContainerData(clay.ID("nav"))
	list, row := clay.GetElementData(clay.ID("nav")), clay.GetElementData(clay.ID("open", u32(max(k, 0))))
	if k < 0 || !sc.found || !list.found || !row.found do return
	attention_scroll = false
	l, r := list.boundingBox, row.boundingBox
	if r.y < l.y do sc.scrollPosition.y += l.y - r.y
	else if r.y + r.height > l.y + l.height do sc.scrollPosition.y -= r.y + r.height - l.y - l.height
	else do return
	app.redraw = true // drawn again where it scrolled to
}

// Enter in the filter field while the Attention view shows: the keyboard's row, else the first;
// no row: nothing (never the hidden tree's best match). False: not this view.
attention_enter :: proc() -> bool {
	if state.sidebar.view != .Attention || state.layout.left_tab != .Sessions do return false
	rows := attention_shown()
	if len(rows) == 0 do return true
	sid := rows[0].session.id
	for r in rows do if r.session.id == attention_sel do sid = r.session.id
	attention_go(sid)
	return true
}

// Toggle Attention view (⌥⌘., View menu, palette): on, showing the Sessions tab; off when it
// already shows.
attention_view_next :: proc() -> core.Sidebar_View {
	shown := state.layout.left_open && state.layout.left_tab == .Sessions
	return shown && state.sidebar.view == .Attention ? .Projects : .Attention
}

attention_view_toggle :: proc() {
	v := attention_view_next()
	if state.focus_widget == "files" do ui_do(core.Set_Focus{""}) // the Files or Settings tree had the keyboard
	if !state.layout.left_open || state.layout.left_tab != .Sessions do ui_do(core.Set_Left_Tab{tab = .Sessions})
	ui_do(core.Set_Sidebar_View{view = v})
}
