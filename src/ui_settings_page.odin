package main

// The Settings page (⌘,, the gear's Settings…, View › Settings, the palette): every setting of
// this window and this Mac in the centre, by section, with a search over the settings and the
// files behind them.
//
//	┌ Appearance ─────┬──────────────────────────────────────────────┐
//	│ Notifications   │ ⌕ Search settings and files                  │
//	│ Coding agents 1 │ Appearance                                   │
//	│ Machines        │ ┌──────────────────────────────────────────┐ │
//	│ …               │ │ Appearance          System Light Dark    │ │
//	│ This project    │ │ Look                ● ● ●                │ │
//	│ api             │ └──────────────────────────────────────────┘ │
//	└─────────────────┴──────────────────────────────────────────────┘
//
// What shows comes from the settings registry (core/settings_registry.odin) and the Settings rows
// (core/settings_files.odin): each control runs what the gear, the palette or the old Settings
// tab ran (an action, or the row's own handler: settings_row_op), as the user, so caller_may
// decides as before; "Only you, at this Mac" is the command table's (setting_this_mac_only).
// Other agents' config is files: a click opens one in an editor tab of the session the page was
// opened from (that session shows again), Create makes a missing one on the click.
//
// Input: the page is the centre with no session shown, as the Deck view (ui_deck.odin): opening it
// sends Show_No_Session, so no pane is laid out, drawn, hit or typed into while it shows, and any
// session shown by any way ends it. Its keyboard is the focus widget "settings_page" (the user's
// only, never a hub's: commands.odin), whose field is the search box or, while one is open, the
// add/rename field; Esc, ⌘, or showing a session goes back. It and the Deck view never stack: one
// opening ends the other, and the session under both stays the one to go back to.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Hit_Spage :: distinct int // an item of the last layout (spage.items); SP_HIT_SEARCH: the search box

SP_HIT_SEARCH :: -2
SP_NAV_W :: 200 // the section list, at most
SP_NAV_MIN :: 112
SP_CARD_W :: 640 // the cards, at most
SP_WIDE :: 520 // narrower cards put a row's controls under its label
SP_FILES_MAX :: 60 // file hits shown in a search

// What an item does when clicked, or chosen with Enter or Space.
Sp_Do :: enum u8 {
	Nav, // show a section
	Action, // run an action (actions.odin): the setting's own
	Grid, // a cell of the notifications grid (pop_run: as the gear's)
	Pi_Ext, // a pi extension's switch (Set_Pi_Extension)
	Row, // a Settings row's own button (settings_row_op)
	Row_Remove,
	Row_Default,
	Row_Reset,
	Row_Reveal,
	Rename, // a machine's Rename… (the page's field)
	Open, // a file: in an editor tab of the session the page was opened from
	Create, // a missing file: made on this click, then opened
	Folder, // a folder: its files, in the search
	More, // a card's "All files…"
	Edit_Save,
	Edit_Cancel,
}

Sp_Item :: struct {
	do_:     Sp_Do,
	section: core.Setting_Section,
	action:  string, // .Action; .More: the card's key
	path:    string, // a row's or a file's; .Pi_Ext: the extension
	pop:     Pop_Item, // .Grid
}

Sp_Edit_Kind :: enum u8 {
	None,
	Add_Machine,
	Rename_Machine,
	Rename_Account,
	// a file row's menu (right click; settings_page_context): as the old Settings tab's name field
	New_File, // target: the folder
	New_Folder,
	Rename_File, // target: the path
}

Spage :: struct {
	on:      bool, // shows while no session is (settings_page_shown)
	section: core.Setting_Section,
	search:  Text_Field,
	sel:     int, // the keyboard's item (-1: none, the field's)
	scroll:  bool, // sel moved: into view after the next layout
	top:     bool, // from the top at the next layout (opened, another section)
	query:   string, // the last layout's search (owned): a new one starts the keyboard over
	items:   [dynamic]Sp_Item, // the last layout's, in order (hits, keys)
	arena:   virtual.Arena, // their strings
	more:    map[string]bool, // the cards showing all their files (owned keys)
	edit:    struct {
		kind:   Sp_Edit_Kind,
		target: string, // the row's path (owned)
		field:  Text_Field,
		err:    string, // why the last try failed (owned)
	},
	// layout state
	first_row: bool, // the next row is its card's first (no line above it)
	card_w:    f32, // the cards' width
}

spage: Spage

// Whether the page shows: opened, and no session on screen.
settings_page_shown :: proc() -> bool {return spage.on && core.cur_view() == nil}

// Opens the page (or moves to a section of it), with the keyboard in its search box.
settings_page_open :: proc {
	settings_page_open_here,
	settings_page_open_at,
}

settings_page_open_here :: proc() {sp_open(nil)}
settings_page_open_at :: proc(section: core.Setting_Section) {sp_open(section)}

@(private = "file")
sp_open :: proc(section: Maybe(core.Setting_Section)) {
	peek_close() // one look at a time (ui_peek.odin)
	if sec, ok := section.?; ok && sec != spage.section {
		spage.section = sec
		spage.top = true
		tf_set(&spage.search, "")
	}
	if !settings_page_shown() {
		ui_hover = nil // the pane's hover is not the page's
		deck.on = false // the Deck view gives way; the session under it stays under the page
		spage.sel, spage.top = -1, true
		// as the Deck view: no session on screen, so no pane is laid out or gets a key (waits for
		// the core's answer: the page shows at once, on a separate core too)
		if core.cur_view() != nil do ui_run(core.Show_No_Session{})
		spage.on = true
	}
	if state.focus_widget != "settings_page" do ui_do(core.Set_Focus{"settings_page"})
	app.redraw = true
}

// The palette's "Refresh settings files" (actions.odin): the page, after its prepare.
settings_page_open_default :: proc() {settings_page_open()}

// Off without going anywhere (the Deck view opening in its place).
settings_page_off :: proc() {
	spage.on = false
	sp_edit_end()
}

// Esc, ⌘, again: back to the session it was opened from, if it is still open (the Deck view's
// way: ui_deck.odin deck_back); else the empty centre.
settings_page_close :: proc() {
	back := deck_under()
	settings_page_off()
	if state.focus_widget == "settings_page" do ui_do(core.Set_Focus{""})
	if back != 0 do ui_do(core.Focus_Session{session = back})
	app.redraw = true
}

// Each layout, first: a session shown (by any way) ends it; the keyboard leaves its field when it
// does not show.
settings_page_sync :: proc() {
	if spage.on && core.cur_view() != nil do settings_page_off()
	core.settings_watch = settings_page_shown() // its folders are polled (settings_poll)
	if !settings_page_shown() && state.focus_widget == "settings_page" && client.focus_wait == "" do ui_do(core.Set_Focus{""})
}

// The focused field (ui.odin focused_field): the add/rename field while one is open, else the search.
settings_page_field :: proc() -> (f: ^Text_Field, text_id, box_id: clay.ElementId) {
	if spage.edit.kind != .None do return &spage.edit.field, clay.ID("sp_edit_text"), clay.ID("sp_edit_box")
	return &spage.search, clay.ID("sp_search_text"), clay.ID("sp_search_box")
}

// ---- the add and rename fields (machines, Claude accounts) ----

sp_edit_begin :: proc(kind: Sp_Edit_Kind, target, text: string) {
	sp_edit_end()
	spage.edit.kind = kind
	spage.edit.target = strings.clone(target)
	tf_set(&spage.edit.field, text)
	tf_select_all(&spage.edit.field)
	spage.sel = -1
	if state.focus_widget != "settings_page" do ui_do(core.Set_Focus{"settings_page"})
	app.redraw = true
}

sp_edit_end :: proc() {
	spage.edit.kind = .None
	delete(spage.edit.target)
	delete(spage.edit.err)
	spage.edit.target, spage.edit.err = "", ""
	app.redraw = true
}

// Enter in the field: the same commands as the old Settings tab's name field (ui_files.odin).
sp_edit_commit :: proc() {
	name := strings.trim_space(tf_text(&spage.edit.field))
	r := core.Result{ok = true}
	switch spage.edit.kind {
	case .None:
		return
	case .Add_Machine: // empty: the core says what to type
		r = ui_run(core.Machine_Add{target = name})
	case .Rename_Machine:
		if name == "" do break
		if no, ok := core.machine_row_no(spage.edit.target); ok do r = ui_run(core.Machine_Rename{no = no, name = name})
	case .Rename_Account:
		if name == "" do break
		r = ui_run(core.Rename_Claude_Account{account = spage.edit.target[len(core.CLAUDE_ACCOUNT_ROW):], label = name})
	case .New_File, .New_Folder, .Rename_File:
		if err := files_name_error(name); err != "" {
			r = {error = err}
			break
		}
		if spage.edit.kind == .Rename_File && name == filepath.base(spage.edit.target) do break
		dir := spage.edit.kind == .Rename_File ? filepath.dir(spage.edit.target) : spage.edit.target
		path := strings.concatenate({dir, "/", name}, context.temp_allocator)
		#partial switch spage.edit.kind {
		case .New_File:
			r = ui_run(core.Create_File{path = path})
			if r.ok {
				sp_edit_end()
				sp_open_file(path) // made: then opened, as the Files tab's New file…
				return
			}
		case .New_Folder:  r = ui_run(core.Create_Dir{path = path})
		case .Rename_File: r = ui_run(core.Rename_Path{from = spage.edit.target, to = path})
		}
	}
	if !r.ok {
		delete(spage.edit.err)
		spage.edit.err = strings.clone(r.error)
		app.redraw = true
		return
	}
	back := machine_add_back && spage.edit.kind == .Add_Machine // added from the sidebar or the palette: back there
	machine_add_back = false
	sp_edit_end()
	if back do settings_page_close()
}

// ---- items ----

@(private = "file")
sp_item :: proc(it: Sp_Item) -> int {
	a := virtual.arena_allocator(&spage.arena)
	x := it
	x.action = strings.clone(it.action, a)
	x.path = strings.clone(it.path, a)
	append(&spage.items, x)
	return len(spage.items) - 1
}

@(private = "file")
sp_id :: proc(k: int) -> clay.ElementId {return clay.ID("spi", u32(k))}

@(private = "file")
sp_hovered :: proc(k: int) -> bool {return ui_hover == Hit(Hit_Spage(k))}

// The keyboard's ring: the accent around the selected control.
@(private = "file")
sp_ring :: proc(k: int) -> clay.BorderElementConfig {
	if k != spage.sel do return {}
	return {color = cc(theme().accent), width = clay.BorderOutside(pu(FOCUS_RING_W))}
}

settings_page_hit :: proc() -> Hit {
	if !settings_page_shown() do return nil
	if clay.PointerOver(clay.ID("sp_search_box")) do return Hit_Spage(SP_HIT_SEARCH)
	for _, k in spage.items do if clay.PointerOver(sp_id(k)) do return Hit_Spage(k)
	return nil
}

settings_page_click :: proc(k: int) {
	if state.focus_widget != "settings_page" do ui_do(core.Set_Focus{"settings_page"})
	spage.sel = -1 // the pointer's: no ring
	if k == SP_HIT_SEARCH {
		sp_edit_end()
		return
	}
	sp_run(k)
}

// Runs an item: what its control does.
@(private = "file")
sp_run :: proc(k: int) {
	if k < 0 || k >= len(spage.items) do return
	it := spage.items[k]
	app.redraw = true
	switch it.do_ {
	case .Nav:
		sp_edit_end()
		spage.section, spage.top = it.section, true
		tf_set(&spage.search, "")
	case .Action:      action_run(it.action)
	case .Grid:        pop_run(it.pop) // as the gear's grid: a sound plays as it is chosen
	case .Pi_Ext:      ui_do(core.Set_Pi_Extension{name = it.path, on = !core.pi_extension_on(it.path)})
	case .Row:         settings_row_op(it.path, .Button)
	case .Row_Remove:  settings_row_op(it.path, .Remove)
	case .Row_Default: settings_row_op(it.path, .Default)
	case .Row_Reset:   settings_row_op(it.path, .Reset)
	case .Row_Reveal:  settings_row_op(it.path, .Reveal)
	case .Rename:
		if no, ok := core.machine_row_no(it.path); ok do for m in state.machines do if m.no == no do sp_edit_begin(.Rename_Machine, it.path, m.name)
	case .Open:        sp_open_file(it.path)
	case .Create:
		if s := sp_file_session(); s != 0 {
			ui_do(core.Focus_Session{session = s})
			core.settings_create(it.path, s) // made only on this click (O_EXCL), then opened there
		}
	case .Folder:
		tf_set(&spage.search, fmt.tprintf("%s/", core.fs_display(it.path)))
		tf_end(&spage.search, false)
		spage.top = true
	case .More:
		if it.action in spage.more {
			key, _ := delete_key(&spage.more, it.action)
			delete(key)
		} else do spage.more[strings.clone(it.action)] = true
	case .Edit_Save:   sp_edit_commit()
	case .Edit_Cancel: sp_edit_end()
	}
}

// The session files open in: the one the page was opened from, this Mac's (0: none, said in a toast).
@(private = "file")
sp_file_session :: proc() -> u64 {
	if s := settings_page_session(); s != 0 do return s
	toast_show("Open a session on this Mac first: settings files open in its editor tabs")
	return 0
}

@(private = "file")
sp_open_file :: proc(path: string) {
	s := sp_file_session()
	if s == 0 do return
	ui_do(core.Focus_Session{session = s}) // shown again: the page goes
	ui_do(core.Open_File{path = path, session = s}) // an ordinary tab: opened from Settings to be edited
}

// ---- keys ----

// The keyboard's keys on the page (its field's, or with no widget): Esc closes the field, clears
// the search, then goes back; Tab, ↑↓ (and ←→ once a control has the keyboard) move across the
// sections and controls; Enter or Space runs the control (Enter in a field: the field's). True: taken.
settings_page_key :: proc(e: ^sapp.Event) -> bool {
	if !settings_page_shown() do return false
	shift := e.modifiers & sapp.MODIFIER_SHIFT != 0
	editing := spage.edit.kind != .None && state.focus_widget == "settings_page"
	#partial switch e.key_code {
	case .ESCAPE:
		switch {
		case spage.edit.kind != .None: sp_edit_end()
		case tf_text(&spage.search) != "":
			tf_set(&spage.search, "")
			spage.sel, spage.top = -1, true
		case: settings_page_close()
		}
	case .TAB: sp_step(shift ? -1 : 1)
	case .DOWN:
		if editing do return false
		sp_step(1)
	case .UP:
		if editing do return false
		sp_step(-1)
	case .LEFT, .RIGHT:
		if spage.sel < 0 do return false // the field's caret
		sp_step(e.key_code == .LEFT ? -1 : 1)
	case .ENTER, .KP_ENTER:
		if editing && spage.sel < 0 do sp_edit_commit()
		else if spage.sel >= 0 do sp_run(spage.sel)
	case .SPACE:
		if spage.sel < 0 do return false // a space in the field
		sp_run(spage.sel)
	case:
		return false
	}
	app.key_taken = true // its CHAR (Space) goes nowhere
	app.redraw = true
	return true
}

@(private = "file")
sp_step :: proc(d: int) {
	n := len(spage.items)
	if n == 0 do return
	if spage.sel < 0 do spage.sel = d > 0 ? 0 : n - 1
	else do spage.sel = (spage.sel + d + n) % n
	spage.scroll = true
}

// Its keys and wheel while no field of it has the keyboard, and its wheel always (main.odin).
// A typed character goes into the search. True: taken.
settings_page_event :: proc(e: ^sapp.Event) -> bool {
	if !settings_page_shown() do return false
	#partial switch e.type {
	case .KEY_DOWN:
		if state.focus_widget != "" do return false // the field's: widget_event
		if e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT) != 0 do return false
		return settings_page_key(e)
	case .CHAR:
		if state.focus_widget != "" || app.key_taken do return false
		if e.char_code >= 0x20 && e.char_code != 0x7f {
			if r, ok := utf16_unit(&app_surrogate, e.char_code); ok {
				tf_insert(&spage.search, utf8_string(r))
				ui_do(core.Set_Focus{"settings_page"})
				app.redraw = true
			}
			return true
		}
	case .MOUSE_SCROLL:
		if !inside(clay.ID("spage"), e.mouse_x, e.mouse_y) || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) do return false
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
		app.redraw = true
		return true
	}
	return false
}

// ---- layout ----

// The section list's notes: updates to make, machines that need the user.
@(private = "file")
sp_nav_note :: proc(sec: core.Setting_Section, rows: []core.Settings_File_Row) -> string {
	n := 0
	#partial switch sec {
	case .Agents:
		for r in rows do if r.group == "agents" && r.button == "Update…" do n += 1
		if n > 0 do return n == 1 ? "1 update" : fmt.tprintf("%d updates", n)
	case .Machines:
		for r in rows do if strings.has_prefix(r.path, core.MACHINE_ROW) {
			switch r.button {
			case "Log in…", "Try again", "Retry", "Keep running…", "Install…", "Update": n += 1
			}
		}
		if n > 0 do return fmt.tprintf("%d %s you", n, n == 1 ? "needs" : "need")
	}
	return ""
}

SP_SECTION_WHY := [core.Setting_Section]string {
	.Appearance    = "Applies at once, to this window.",
	.Notifications = "What reaches you from sessions you are not looking at.",
	.Agents        = "What is installed, and how Deckhand starts each one. Deckhand never edits these agents' own config: it opens their files for you.",
	.Machines      = "Other machines' sessions, over your own ssh.",
	.Sessions      = "",
	.Atlas         = "",
	.Folders       = "Where Deckhand keeps its own files.",
	.Deckhand      = "",
	.Project       = "This project's own files. Deckhand opens them for you to edit, and makes a missing one only when you click Create.",
}

settings_page_layout :: proc() {
	th := theme()
	virtual.arena_destroy(&spage.arena)
	_ = virtual.arena_init_growing(&spage.arena)
	if spage.items.allocator.procedure == nil do spage.items.allocator = runtime.heap_allocator() // for the window's life
	clear(&spage.items)
	sp_scroll_to()
	if spage.top {
		spage.top = false
		if sc := clay.GetScrollContainerData(clay.ID("spbody")); sc.found do sc.scrollPosition^ = {}
	}
	query := strings.trim_space(tf_text(&spage.search))
	if query != spage.query { 	// a new search: the keyboard starts over
		delete(spage.query)
		spage.query = strings.clone(query)
		spage.sel = -1
	}
	rows := core.settings_file_rows()
	project := core.settings_project_cwd()
	if spage.section == .Project && project == "" do spage.section = .Appearance
	total := centre_width()
	nav_w := clamp(total * 0.28, px(SP_NAV_MIN), px(SP_NAV_W))
	spage.card_w = min(total - nav_w - px(2 * SP_6), px(SP_CARD_W))
	if clay.UI(clay.ID("spage"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}, backgroundColor = cc(th.bg_app)}) {
		// the sections
		if clay.UI(clay.ID("spnav"))({
			layout = {sizing = {clay.SizingFixed(nav_w), clay.SizingGrow()}, padding = clay.PaddingAll(pu(SP_2)), childGap = pu(2), layoutDirection = .TopToBottom},
			backgroundColor = cc(th.bg_sidebar),
			border = {color = cc(th.border), width = {right = pu(core.BORDER_W)}},
		}) {
			room := nav_w - px(2 * SP_2 + 2 * SP_2)
			for sec in core.Setting_Section {
				if sec == .Project do continue
				sp_nav(sec, core.SETTING_SECTION_NAMES[sec], sp_nav_note(sec, rows), room)
			}
			if project != "" {
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(th.border)}) {}
				if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_2), pu(SP_1), 0}}}) {
					clay.TextDynamic(clip(core.SETTING_SECTION_NAMES[.Project], room), txt(th.text_muted, FONT_UI_SMALL | WEIGHT_HEADER))
				}
				sp_nav(.Project, filepath.base(project), "", room)
			}
		}
		// the search, then the section or the search's results
		if clay.UI(clay.ID("spbody"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, padding = {pu(SP_6), pu(SP_6), pu(SP_4), pu(SP_6)}, childGap = pu(SP_4), layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			sp_search_box()
			if core.sf_error != "" { 	// the last Create's
				lines, _ := wrap_clip(core.sf_error, spage.card_w, 3)
				cfg := txt(th.error)
				cfg.wrapMode = .Newlines
				clay.TextDynamic(lines, cfg)
			}
			sp_file_edit()
			if query != "" do sp_results(query, rows)
			else do sp_section(spage.section, rows, project)
		}
	}
}

@(private = "file")
sp_nav :: proc(sec: core.Setting_Section, label, note: string, room: f32) {
	th := theme()
	k := sp_item({do_ = .Nav, section = sec})
	id := sp_id(k)
	on := sec == spage.section && spage.query == ""
	bg, em := overlay(id, on, sp_hovered(k))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = sp_ring(k),
	}) {
		nw := note != "" ? min(text_w(note, FONT_UI_SMALL), room * 0.45) : 0
		clay.TextDynamic(clip(label, room - nw - (nw > 0 ? px(SP_2) : 0)), txt(on ? th.text : mix(th.text_secondary, th.text, em)))
		if note != "" {
			spacer()
			clay.TextDynamic(clip(note, nw, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		}
	}
}

@(private = "file")
sp_search_box :: proc() {
	th := theme()
	focused := state.focus_widget == "settings_page" && spage.edit.kind == .None
	if clay.UI(clay.ID("sp_search_box"))({
		layout = {sizing = {clay.SizingFixed(spage.card_w), clay.SizingFixed(px(FIELD_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(focused ? th.accent : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
	}) {
		icon(.Search, th.text_muted, ICON_SIZE_SM)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}, clip = {horizontal = true}}) {
			field_text(clay.ID("sp_search_text"), &spage.search, "Search settings and files")
		}
	}
}

// ---- sections ----

@(private = "file")
sp_heading :: proc(title, why: string) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingFixed(spage.card_w), clay.SizingFit()}, childGap = pu(SP_1), layoutDirection = .TopToBottom}}) {
		clay.TextDynamic(clip(title, spage.card_w, WEIGHT_HEADER), txt(th.text, WEIGHT_HEADER))
		if why != "" {
			lines, _ := wrap_clip(why, spage.card_w, 3, FONT_UI_SMALL)
			cfg := txt(th.text_muted, FONT_UI_SMALL)
			cfg.wrapMode = .Newlines
			clay.TextDynamic(lines, cfg)
		}
	}
}

@(private = "file")
sp_section :: proc(sec: core.Setting_Section, rows: []core.Settings_File_Row, project: string) {
	title := core.SETTING_SECTION_NAMES[sec]
	if sec == .Project do title = fmt.tprintf("%s · %s", title, filepath.base(project))
	sp_heading(title, SP_SECTION_WHY[sec])
	switch sec {
	case .Appearance:
		if sp_card("") {
			for id in ([]string{"appearance", "look", "text_size", "term_text", "reduce_motion", "dim_panes"}) do sp_setting(core.setting_by_id(id), rows)
		}
	case .Notifications:
		grid := core.setting_by_id("notify_grid")
		if sp_card(grid.label, core.setting_this_mac_only(grid) ? core.SETTING_THIS_MAC_BADGE : "") do sp_grid()
		if sp_card("") {
			sp_setting(core.setting_by_id("bell_dock"), rows)
			sp_setting(core.setting_by_id("agent_notify"), rows)
		}
	case .Agents:
		for card in ([]string{"pi", "Claude Code", "Codex"}) {
			if card == "pi" && !core.pi_installed() && !sp_has_status(card, rows) do continue
			if sp_card(card) {
				for &s in core.SETTINGS do if s.section == .Agents && s.card == card do sp_setting(&s, rows)
				sp_files(rows, .Agents, card)
			}
		}
	case .Machines:
		if sp_card("") {
			sp_setting(core.setting_by_id("remote_machines"), rows)
			if state.settings.remote_machines {
				sp_setting(core.setting_by_id("machines"), rows)
				sp_setting(core.setting_by_id("machine_add"), rows)
			}
		}
		if sp_card("") do sp_setting(core.setting_by_id("machines_reachable"), rows)
	case .Sessions:
		for card in ([]string{"Running", "Chats", "Fix-ups"}) {
			if sp_card(card) {
				for &s in core.SETTINGS do if s.section == .Sessions && s.card == card do sp_setting(&s, rows)
				sp_files(rows, .Sessions, card)
			}
		}
	case .Atlas:
		if !core.atlas_offered() {
			sp_note("Atlas runs on pi: install pi under Coding agents.")
			break
		}
		if sp_card("") {
			sp_setting(core.setting_by_id("atlas_model"), rows)
			sp_files(rows, .Atlas, "")
		}
		if sp_card("Jobs") {
			sp_setting(core.setting_by_id("jobs"), rows)
			sp_files(rows, .Atlas, "Jobs")
		}
	case .Folders:
		if sp_card("") {
			sp_setting(core.setting_by_id("main_folder"), rows)
			sp_setting(core.setting_by_id("subfolders"), rows)
		}
	case .Deckhand:
		if sp_card("") do for &s in core.SETTINGS do if s.section == .Deckhand do sp_setting(&s, rows)
	case .Project:
		for card in ([]string{"pi", "Claude Code"}) {
			has := false
			for r in rows do if sec2, c, ok := core.settings_group_section(r.group); ok && sec2 == .Project && c == card do has = true
			if !has do continue
			if sp_card(card) do sp_files(rows, .Project, card, links = false)
		}
		if pd := fmt.tprintf("%s/.pi", project); core.path_kind(pd) == .Dir {
			if sp_card("") {
				k := sp_item({do_ = .Folder, path = pd})
				sp_file_row(k, ".pi/", "every file in it, in the search", false)
			}
		}
	}
}

@(private = "file")
sp_has_status :: proc(card: string, rows: []core.Settings_File_Row) -> bool {
	for r in rows do if r.group == "agents" {
		if s := core.setting_for_row(r.path); s != nil && s.card == card do return true
	}
	return false
}

@(private = "file")
sp_note :: proc(text: string) {
	th := theme()
	lines, _ := wrap_clip(text, spage.card_w, 3)
	cfg := txt(th.text_muted)
	cfg.wrapMode = .Newlines
	clay.TextDynamic(lines, cfg)
}

// The search's results: by section in the page's order, each in a card; settings drawn as on the
// page, files and list rows as rows.
@(private = "file")
sp_results :: proc(query: string, rows: []core.Settings_File_Row) {
	hits := core.settings_search(query, rows, deep = true)
	if len(hits) == 0 {
		sp_note("No setting or file matches. Esc clears the search.")
		return
	}
	files := 0
	for sec in core.Setting_Section {
		n := 0
		for h in hits do if h.section == sec do n += 1
		if n == 0 do continue
		sp_heading(sec == .Project ? fmt.tprintf("%s · %s", core.SETTING_SECTION_NAMES[sec], filepath.base(core.settings_project_cwd())) : core.SETTING_SECTION_NAMES[sec], "")
		if sp_card("") {
			for h in hits do if h.section == sec {
				switch h.kind {
				case .Setting:
					sp_setting(h.setting, rows)
				case .Row:
					// a list's row, unless its whole setting is a hit too (drawn there)
					whole := false
					for x in hits do if x.kind == .Setting && x.setting == h.setting do whole = true
					if !whole do sp_list_row(h.row)
				case .File:
					files += 1
					if files <= SP_FILES_MAX do sp_file(h.row)
				}
			}
		}
	}
	if files > SP_FILES_MAX do sp_note(fmt.tprintf("%d more files: type more of the name", files - SP_FILES_MAX))
}

// ---- cards and rows ----

@(private = "file")
sp_close :: proc() {clay._CloseElement()}

@(private = "file")
sp_close2 :: proc() {
	clay._CloseElement()
	clay._CloseElement()
}

// A card: a titled box of rows (deferred close).
@(deferred_none = sp_close)
sp_card :: proc(title: string, badge := "") -> bool {
	th := theme()
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout = {sizing = {clay.SizingFixed(spage.card_w), clay.SizingFit()}, layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_sidebar),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + 2)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
	})
	if title != "" {
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_3), pu(SP_3), pu(SP_2), 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
			bw := badge != "" ? text_w(badge, FONT_UI_SMALL) + px(2 * SP_1) + px(SP_2) : 0
			clay.TextDynamic(clip(strings.to_upper(title, context.temp_allocator), spage.card_w - px(2 * SP_3) - bw, FONT_UI_SMALL | WEIGHT_HEADER), txt(th.text_muted, FONT_UI_SMALL | WEIGHT_HEADER))
			if badge != "" do sp_badge(badge, true)
		}
	}
	spage.first_row = true
	return true
}

// A badge: "Only you, at this Mac" (lock) or "Next start" / "Next launch".
@(private = "file")
sp_badge :: proc(text: string, lock: bool) {
	th := theme()
	col := lock ? th.accent : th.waiting
	if clay.UI()({
		layout = {sizing = {clay.SizingFit(), clay.SizingFit()}, padding = {pu(SP_1), pu(SP_1), pu(1), pu(1)}},
		backgroundColor = cc(mix(th.bg_sidebar, col, 0.2)),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM - 1)),
	}) {
		clay.TextDynamic(text, txt(col, FONT_UI_SMALL))
	}
}

// Whether the card is narrow: a row's controls go under its label.
@(private = "file")
sp_narrow :: proc() -> bool {return spage.card_w < px(SP_WIDE)}

// A row: its label (and hint) on the left, its controls (the caller's, inside it) on the right, or
// under it in a narrow card. Deferred: closes the controls and the row.
@(deferred_none = sp_close2)
sp_row :: proc(label, hint: string, badges: []string = nil, mono_hint := false, dim := false, stack := false, controls_w: f32 = 0) -> bool {
	th := theme()
	narrow := stack || sp_narrow()
	room := spage.card_w - px(2 * SP_3)
	label_room := narrow ? room : room * 0.55
	clay._OpenElement()
	clay.ConfigureOpenElement({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit({min = px(44)})}, padding = {pu(SP_3), pu(SP_3), pu(SP_2), pu(SP_2)}, childGap = pu(narrow ? SP_2 : SP_3), childAlignment = {y = .Center}, layoutDirection = narrow ? .TopToBottom : .LeftToRight},
		border = {color = cc(th.border), width = {top = spage.first_row ? 0 : pu(core.BORDER_W)}},
	})
	spage.first_row = false
	if clay.UI()({layout = {sizing = {narrow ? clay.SizingGrow() : clay.SizingFixed(label_room), clay.SizingFit()}, childGap = pu(2), layoutDirection = .TopToBottom}}) {
		lines, _ := wrap_clip(label, label_room, 2)
		cfg := txt(dim ? th.text_muted : th.text)
		cfg.wrapMode = .Newlines
		clay.TextDynamic(lines, cfg)
		if hint != "" {
			w := mono_hint ? FONT_MONO : FONT_UI_SMALL
			hl, _ := wrap_clip(hint, label_room, 2, w)
			hc := txt(th.text_muted, w)
			hc.wrapMode = .Newlines
			clay.TextDynamic(hl, hc)
		}
	}
	clay._OpenElement()
	// buttons that do not fit side by side in a narrow card: one under the other
	down := narrow && controls_w > room
	clay.ConfigureOpenElement({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, childGap = pu(SP_2), childAlignment = {x = narrow ? .Left : .Right, y = .Center}, layoutDirection = down ? .TopToBottom : .LeftToRight}})
	for b in badges do if b != "" do sp_badge(b, b == core.SETTING_THIS_MAC_BADGE)
	return true
}

// A small button (an item).
@(private = "file")
sp_button :: proc(k: int, label: string, primary := false) {
	th := theme()
	id := sp_id(k)
	h := fade(id, 0, sp_hovered(k) ? 1 : 0, DUR_HOVER)
	bg := primary ? cc(mix(th.accent, th.text, h * TINT_PRIMARY_HOVER)) : cc(mix(th.bg_elevated, th.text, TINT_BUTTON + h * (TINT_BUTTON_HOVER - TINT_BUTTON)))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SEGMENT_H))}, padding = {pu(SP_2 + 2), pu(SP_2 + 2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = sp_ring(k),
	}) {
		clay.TextDynamic(clip(label, spage.card_w * 0.4, FONT_UI_SMALL), txt(primary ? th.text_on_accent : th.text_secondary, FONT_UI_SMALL))
	}
}

@(private = "file")
sp_switch :: proc(k: int, on: bool) {
	if clay.UI(sp_id(k))({layout = {padding = clay.PaddingAll(pu(2))}, cornerRadius = clay.CornerRadiusAll(px(SWITCH_H / 2 + 2)), border = sp_ring(k)}) {
		switch_control(on)
	}
}

// A segmented control: one item per choice.
@(private = "file")
sp_segments :: proc(s: ^core.Setting, chosen: int) {
	th := theme()
	if clay.UI()({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(SEGMENT_H))}, padding = clay.PaddingAll(pu(2)), childGap = pu(2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		for c, i in s.choices {
			k := sp_item({do_ = .Action, action = c.action})
			id := sp_id(k)
			on := i == chosen
			bg, em := overlay(id, false, sp_hovered(k))
			if on do bg = cc(mix(th.bg_elevated, th.text, TINT_SEGMENT))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFit(), clay.SizingGrow()}, padding = {pu(SEGMENT_PAD), pu(SEGMENT_PAD), 0, 0}, childAlignment = {y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				border = sp_ring(k),
			}) {
				clay.TextDynamic(c.name, txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
			}
		}
	}
}

// What a switch shows now.
@(private = "file")
sp_switch_on :: proc(s: ^core.Setting) -> bool {
	st := &state.settings
	switch s.id {
	case "reduce_motion":           return st.reduce_motion
	case "dim_panes":               return !st.dim_panes_off
	case "bell_dock":               return !st.bell_dock_off
	case "agent_notify":            return !st.notify_off
	case "claude_skip_permissions": return st.claude_skip_permissions
	case "codex_full_access":       return st.codex_full_access
	case "remote_machines":         return st.remote_machines
	case "machines_reachable":      return st.machines_reachable
	case "keep_sessions":           return st.keep_sessions
	case "separate_core":           return st.separate_core
	case "tidy_projects":           return !st.tidy_off
	case "update_checks":           return !core.update_view().checks_off
	}
	if s.ext != "" do return core.pi_extension_on(s.ext)
	return false
}

// A Button setting's button and live hint.
@(private = "file")
sp_button_text :: proc(s: ^core.Setting) -> (button, hint: string) {
	hint = s.hint
	switch s.id {
	case "chats_dir":          return "Change…", action_detail("chats_dir")
	case "atlas_model":        return "Change…", action_detail("agent_model")
	case "machine_add":        return "Add…", s.hint
	case "setup":              return "Set up…", s.hint
	case "shortcuts":          return "Show ⌘/", s.hint
	case "control_token":      return "Copy", s.hint
	case "jobs":               return "Open", s.hint
	case "refresh_shell_env":  return "Refresh", s.hint
	case "rescan":             return "Rescan", s.hint
	case "reload_all_pi":      return "Reload", s.hint
	case "restart_all_claude": return "Restart…", s.hint
	}
	return "Open", hint
}

@(private = "file")
action_detail :: proc(id: string) -> string {
	a := action_by_id(id)
	return a != nil && a.detail != nil ? a.detail() : ""
}

// The badges a setting shows: when it applies, and "Only you, at this Mac" (the command table's).
@(private = "file")
sp_badges :: proc(s: ^core.Setting) -> []string {
	out := make([]string, 2, context.temp_allocator)
	out[0] = core.SETTING_APPLIES_BADGES[s.applies]
	out[1] = core.setting_this_mac_only(s) ? core.SETTING_THIS_MAC_BADGE : ""
	return out
}

// One setting as its rows.
@(private = "file")
sp_setting :: proc(s: ^core.Setting, rows: []core.Settings_File_Row) {
	if s == nil do return
	th := theme()
	label := strings.trim_suffix(core.setting_label(s), "…")
	switch s.kind {
	case .Switch:
		k: int
		if s.ext != "" {
			found := false
			for e in core.pi_integration_optional() do if e.name == s.ext do found = true
			if !found do return // not in this integration
			k = sp_item({do_ = .Pi_Ext, path = s.ext})
		} else if s.action != "" {
			k = sp_item({do_ = .Action, action = s.action})
		} else {
			k = sp_item({do_ = .Row, path = s.row}) // its Settings row's handler (Allow other machines: asks first)
		}
		if sp_row(label, s.hint, sp_badges(s)) do sp_switch(k, sp_switch_on(s))
	case .Choice:
		chosen := 0
		switch s.id {
		case "appearance": chosen = int(state.settings.appearance)
		case "look":       chosen = int(state.settings.theme)
		case "text_size":
			for size, i in TEXT_SIZE_ORDER do if size == state.settings.text_size do chosen = i
		}
		hint := s.hint
		if s.id == "look" do hint = fmt.tprintf("%s · %s", s.choices[int(state.settings.theme)].name, s.hint)
		if sp_row(label, hint, sp_badges(s)) {
			if s.id == "look" do sp_swatches(s)
			else do sp_segments(s, chosen)
		}
	case .Stepper: // the terminals' and the editor's text: − 14 pt + (⌘0: actual size, when changed)
		if sp_row(label, s.hint, sp_badges(s)) {
			sp_button(sp_item({do_ = .Action, action = "text_smaller"}), "−")
			clay.TextDynamic(fmt.tprintf("%d pt", int(term_text_pt())), txt(th.text_secondary, FONT_MONO))
			sp_button(sp_item({do_ = .Action, action = "text_bigger"}), "+")
			if state.settings.term_text_pt != 0 do sp_button(sp_item({do_ = .Action, action = "text_reset"}), "Actual size")
		}
	case .Grid:
		sp_grid()
	case .Button:
		if (s.id == "reload_all_pi" || s.id == "restart_all_claude") && !action_ok(s.action) do return // only while such a tab runs
		if s.id == "main_folder" {
			for r in rows do if r.path == core.FOLDER_MAIN_ROW do sp_list_row(r)
			return
		}
		btn, hint := sp_button_text(s)
		k := s.id == "machine_add" ? sp_item({do_ = .Row, path = core.MACHINE_ADD_ROW}) : sp_item({do_ = .Action, action = s.action})
		if sp_row(label, hint, sp_badges(s), mono_hint = s.id == "chats_dir") {
			sp_button(k, btn)
			if s.id == "chats_dir" && action_ok("chats_dir_default") do sp_button(sp_item({do_ = .Action, action = "chats_dir_default"}), "Default")
			if s.id == "update_checks" do sp_button(sp_item({do_ = .Action, action = "check_updates"}), "Check now")
		}
		if s.id == "machine_add" && spage.edit.kind == .Add_Machine do sp_edit_row("Add a machine", "user@host or an ~/.ssh/config name")
	case .Status:
		has := false
		for r in rows do if r.group == "agents" && core.setting_for_row(r.path) == s {
			has = true
			sp_list_row(r)
		}
		if !has do if sp_row(label, "Not checked yet") {}
	case .List:
		switch s.id {
		case "machines":
			for r in rows do if strings.has_prefix(r.path, core.MACHINE_ROW) || strings.has_prefix(r.path, core.MACHINE_CHECK_ROW) do sp_list_row(r)
		case "claude_accounts":
			for r in rows do if r.group == "claude-accounts" do sp_list_row(r)
		case "subfolders":
			for r in rows do if r.group == "folders" && r.path != core.FOLDER_MAIN_ROW do sp_list_row(r)
		}
	}
}

// A row of a setting's list (settings_file_rows): its label and what it says, its buttons as the
// old Settings tab had them; a machine's Rename…; the add/rename field under it while open.
@(private = "file")
sp_list_row :: proc(r: core.Settings_File_Row) {
	if !core.settings_setting_row(r.path) {
		sp_file(r)
		return
	}
	label := strings.trim_space(r.label)
	if r.path == core.MACHINE_REACH_ROW || r.path == core.CLAUDE_FLAGS_ROW || r.path == core.MACHINE_SSH_ROW || strings.has_prefix(r.path, core.PI_EXT_ROW) || r.path == core.ATLAS_MODEL_ROW {
		if s := core.setting_for_row(r.path); s != nil do sp_setting(s, nil) // a switch: drawn as its setting
		return
	}
	if r.path == core.CLAUDE_FLAGS_HEAD_ROW || r.path == core.CLAUDE_FLAGS_WARN_ROW do return // said by the switch's hint
	// its buttons: several go under its label (a machine: Rename…, Remove…, Log in…)
	names := make([dynamic]string, context.temp_allocator)
	if r.reveal do append(&names, "Reveal")
	if r.reset do append(&names, "Reset")
	if r.make_default do append(&names, "Make default")
	if _, ok := core.machine_row_no(r.path); ok do append(&names, "Rename…")
	if r.remove do append(&names, "Remove…")
	if r.button != "" do append(&names, r.button)
	cw: f32
	for n in names do cw += text_w(n, FONT_UI_SMALL) + px(2 * (SP_2 + 2) + SP_2)
	folder := strings.has_prefix(r.path, "deckhand:folder:")
	if sp_row(label, r.detail, mono_hint = folder, stack = len(names) >= 2, controls_w = cw) {
		if r.reveal do sp_button(sp_item({do_ = .Row_Reveal, path = r.path}), "Reveal")
		if r.reset do sp_button(sp_item({do_ = .Row_Reset, path = r.path}), "Reset")
		if r.make_default do sp_button(sp_item({do_ = .Row_Default, path = r.path}), "Make default")
		if _, ok := core.machine_row_no(r.path); ok do sp_button(sp_item({do_ = .Rename, path = r.path}), "Rename…")
		if r.remove do sp_button(sp_item({do_ = .Row_Remove, path = r.path}), "Remove…")
		if r.button != "" do sp_button(sp_item({do_ = .Row, path = r.path}), r.button, primary = r.button == "Log in…" || r.button == "Update…")
	}
	if spage.edit.kind != .None && spage.edit.target == r.path {
		sp_edit_row(spage.edit.kind == .Rename_Account ? "Rename the account" : "Rename the machine", "")
	}
}

// The add/rename field, its Save and Cancel, and why the last try failed.
@(private = "file")
sp_edit_row :: proc(title, placeholder: string) {
	th := theme()
	if sp_row(title, spage.edit.err) {
		if clay.UI(clay.ID("sp_edit_box"))({
			layout = {sizing = {clay.SizingFixed(min(px(240), spage.card_w * 0.5)), clay.SizingFixed(px(FIELD_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_field),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
			border = {color = cc(th.accent), width = clay.BorderOutside(pu(core.BORDER_W))},
			clip = {horizontal = true},
		}) {
			field_text(clay.ID("sp_edit_text"), &spage.edit.field, placeholder)
		}
		sp_button(sp_item({do_ = .Edit_Save}), "Save", primary = true)
		sp_button(sp_item({do_ = .Edit_Cancel}), "Cancel")
	}
}

// A file row menu's New file…, New folder… or Rename… (settings_page_file_step): its field, above
// the section or search it was asked from.
@(private = "file")
sp_file_edit :: proc() {
	title: string
	#partial switch spage.edit.kind {
	case .New_File:    title = fmt.tprintf("New file in %s", core.fs_display(spage.edit.target))
	case .New_Folder:  title = fmt.tprintf("New folder in %s", core.fs_display(spage.edit.target))
	case .Rename_File: title = fmt.tprintf("Rename %s", filepath.base(spage.edit.target))
	case: return
	}
	if sp_card("") do sp_edit_row(title, "name")
}

// An item's tooltip: the notifications grid's cells say what they are and the rule ("": none).
settings_page_tip :: proc(k: int) -> string {
	if k < 0 || k >= len(spage.items) do return ""
	if it := spage.items[k]; it.do_ == .Grid do return bell_grid_tip(it.pop)
	return ""
}

// A right click on a file or folder row: the old Settings tab's row menu (ui_files.odin
// settings_menu_items: the same commands and confirmations).
settings_page_context :: proc(k: int, at: [2]f32) {
	if k < 0 || k >= len(spage.items) do return
	it := spage.items[k]
	#partial switch it.do_ {
	case .Open, .Folder, .Create: menu_open(Menu_Files{path = it.path, page = true}, at)
	}
}

// The session a menu's Open goes to: the one the page was opened from, this Mac's (0: none).
settings_page_session :: proc() -> u64 {
	if s := core.find_session(deck_under()); s != nil && s.machine == 0 && !s.home do return s.id
	return 0
}

// A file row menu's step that is not a command (ui_sidebar.odin's menu): New file…, New folder…
// and Rename… open the page's field; Copy path. True: a path went on the clipboard.
settings_page_file_step :: proc(path: string, step: core.Files_Step) -> (copied: bool) {
	#partial switch step {
	case .New_File, .New_Folder:
		dir := core.path_kind(path) == .Dir ? path : filepath.dir(path)
		sp_edit_begin(step == .New_File ? .New_File : .New_Folder, dir, "")
	case .Rename:
		name := filepath.base(path)
		sp_edit_begin(.Rename_File, path, name)
		// the name without its extension is selected, as Finder does
		if dot := strings.last_index_byte(name, '.'); dot > 0 do spage.edit.field.cursor, spage.edit.field.anchor = dot, 0
	case .Copy_Path:
		if path == "" || win_os.set_clipboard == nil do return false
		win_os.set_clipboard(path)
		return true
	}
	return false
}

// The look's swatches: its background and its accent, the current one ringed.
@(private = "file")
sp_swatches :: proc(s: ^core.Setting) {
	th := theme()
	light := core.theme_is_light()
	for look in core.Theme_Id {
		k := sp_item({do_ = .Action, action = s.choices[int(look)].action})
		lt := light ? &THEMES_LIGHT[look] : &THEMES[look]
		on := state.settings.theme == look
		ring := on ? th.accent : (sp_hovered(k) || spage.sel == k ? th.text_muted : th.border)
		if clay.UI(sp_id(k))({
			layout = {sizing = {clay.SizingFixed(px(SWATCH + 4)), clay.SizingFixed(px(SWATCH + 4))}, padding = clay.PaddingAll(pu(2)), childAlignment = {x = .Center, y = .Center}},
			backgroundColor = cc(ring),
			cornerRadius = clay.CornerRadiusAll(px(SWATCH / 2 + 2)),
			border = sp_ring(k),
		}) {
			if clay.UI()({
				layout = {sizing = {clay.SizingFixed(px(SWATCH)), clay.SizingFixed(px(SWATCH))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = cc(lt.bg_app),
				cornerRadius = clay.CornerRadiusAll(px(SWATCH / 2)),
			}) {
				if clay.UI()({
					layout = {sizing = {clay.SizingFixed(px(SWATCH / 2 - 2)), clay.SizingFixed(px(SWATCH / 2 - 2))}},
					backgroundColor = cc(lt.accent),
					cornerRadius = clay.CornerRadiusAll(px(SWATCH / 4 - 1)),
				}) {}
			}
		}
	}
}

// The notifications grid: per kind, Bell (a switch), macOS and Sound (chips that step), as the gear's.
@(private = "file")
sp_grid :: proc() {
	th := theme()
	pad := px(2 * (SP_1 + 2))
	bw := max(px(SWITCH_W + 2 * SP_1), text_w("Bell", FONT_UI_SMALL))
	mw := text_w("macOS", FONT_UI_SMALL)
	for n in core.OS_WHEN_NAMES do mw = max(mw, text_w(n, FONT_UI_SMALL) + pad)
	sw := text_w("Sound", FONT_UI_SMALL)
	for n in core.BELL_SOUND_LABELS do sw = max(sw, text_w(n, FONT_UI_SMALL) + pad)
	lw := spage.card_w - px(2 * SP_3) - bw - mw - sw - px(3 * SP_2)
	line :: proc() -> clay.ElementDeclaration {
		return {layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(POPOVER_ROW_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}}}
	}
	cell :: proc(w: f32, text: string) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(w), clay.SizingFit()}, childAlignment = {x = .Center}}}) {
			clay.TextDynamic(text, txt(theme().text_muted, FONT_UI_SMALL))
		}
	}
	if clay.UI()(line()) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(max(lw, 0)), clay.SizingFit()}}}) {}
		cell(bw, "Bell")
		cell(mw, "macOS")
		cell(sw, "Sound")
	}
	for g in BELL_GRID_ORDER {
		if clay.UI()(line()) {
			if clay.UI()({layout = {sizing = {clay.SizingFixed(max(lw, 0)), clay.SizingFit()}}}) {
				clay.TextDynamic(clip(BELL_GRID_LABELS[g], max(lw, 0)), txt(th.text))
			}
			k := sp_item({do_ = .Grid, pop = Pop_Item(int(Pop_Item.Bell_Finished) + int(g))})
			if clay.UI()({layout = {sizing = {clay.SizingFixed(bw), clay.SizingFit()}, childAlignment = {x = .Center}}}) {
				sp_switch(k, g not_in state.settings.bell_off)
			}
			w := core.bell_os_when(state.settings, g)
			sp_chip(sp_item({do_ = .Grid, pop = Pop_Item(int(Pop_Item.Os_Finished) + int(g))}), core.OS_WHEN_NAMES[w], w != .Never, mw)
			so := core.bell_sound_of(state.settings, g)
			sp_chip(sp_item({do_ = .Grid, pop = Pop_Item(int(Pop_Item.Sound_Finished) + int(g))}), core.BELL_SOUND_LABELS[so], so != .None, sw)
		}
	}
	gap(SP_2)
}

@(private = "file")
sp_chip :: proc(k: int, text: string, on: bool, w: f32) {
	th := theme()
	id := sp_id(k)
	bg, em := overlay(id, false, sp_hovered(k))
	if on do bg = cc(mix(th.bg_sidebar, th.accent, 0.22 + 0.14 * em))
	border := clay.BorderElementConfig{color = cc(on ? with_alpha(th.accent, 0.6) : th.border), width = clay.BorderOutside(pu(core.BORDER_W))}
	if k == spage.sel do border = sp_ring(k)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(px(CHIP_SMALL_H))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = border,
	}) {
		clay.TextDynamic(clip(text, w, FONT_UI_SMALL), txt(on ? th.text : mix(th.text_muted, th.text_secondary, em), FONT_UI_SMALL))
	}
}

// ---- files ----

// A card's "Advanced: open the file": its common files, then "All files…" for the rest. links
// false: the card is files only (This project), no heading.
@(private = "file")
sp_files :: proc(rows: []core.Settings_File_Row, sec: core.Setting_Section, card: string, links := true) {
	th := theme()
	common, rare: [dynamic]core.Settings_File_Row
	common.allocator, rare.allocator = context.temp_allocator, context.temp_allocator
	for r in rows {
		if core.settings_setting_row(r.path) do continue
		s, c, ok := core.settings_group_section(r.group)
		if !ok || s != sec || c != card do continue
		if core.settings_file_rare(r) do append(&rare, r)
		else do append(&common, r)
	}
	if len(common) + len(rare) == 0 do return
	if links {
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_3), pu(SP_3), pu(SP_2), pu(2)}},
			border = {color = cc(th.border), width = {top = spage.first_row ? 0 : pu(core.BORDER_W)}},
		}) {
			clay.TextDynamic("Advanced: open the file", txt(th.text_muted, FONT_UI_SMALL))
		}
		spage.first_row = true
	}
	for r in common do sp_file(r)
	key := fmt.tprintf("%v/%s", sec, card)
	if len(rare) > 0 {
		open := key in spage.more
		k := sp_item({do_ = .More, action = key})
		sp_file_row(k, open ? "Fewer files" : fmt.tprintf("All files… (%d more)", len(rare)), "", false, link = true)
		if open do for r in rare do sp_file(r)
	}
	gap(SP_1)
}

// A file or folder row: opens it (a folder: its files in the search); a missing one: Create.
@(private = "file")
sp_file :: proc(r: core.Settings_File_Row) {
	if !r.exists && r.create {
		k := sp_item({do_ = .Create, path = r.path})
		sp_file_row(k, r.label, fmt.tprintf("%s · missing", r.detail), true, button = "Create")
		return
	}
	if r.kind == .Folder {
		sp_file_row(sp_item({do_ = .Folder, path = r.path}), fmt.tprintf("%s/", r.label), r.detail, false)
		return
	}
	sp_file_row(sp_item({do_ = .Open, path = r.path}), r.label, r.detail, false)
}

@(private = "file")
sp_file_row :: proc(k: int, name, detail: string, missing: bool, button := "", link := false) {
	th := theme()
	id := sp_id(k)
	bg, em := overlay(id, false, button == "" && sp_hovered(k))
	room := spage.card_w - px(2 * SP_3 + 2 * SP_2)
	bwid := button != "" ? text_w(button, FONT_UI_SMALL) + px(2 * (SP_2 + 2) + SP_2) : 0
	nw := min(text_w(name, FONT_MONO), (room - bwid) * 0.6)
	// a button row: the button is the item; else the whole row is
	row_id := button != "" ? clay.ID("spfile", u32(k)) : id
	if clay.UI(row_id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(FILES_ROW_H + 4))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = button != "" ? clay.Color{} : bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = button != "" ? clay.BorderElementConfig{} : sp_ring(k),
	}) {
		col := link ? th.accent : (missing ? th.text_muted : mix(th.accent, th.text, 0.25 * em))
		clay.TextDynamic(clip(name, nw, FONT_MONO), txt(col, FONT_MONO))
		if detail != "" do clay.TextDynamic(clip(detail, room - bwid - nw - px(SP_2), FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		if button != "" {
			spacer()
			sp_button(k, button)
		}
	}
}

// A scene's "spi @KEY" (autotest.odin script_index): a section by its name (Agents), an action's
// id (a notifications grid cell's too), a pi extension's name, a row's or a file's path by its end, a card's "All files…"
// (Agents/pi); the last layout's item (-1: none).
settings_page_slot :: proc(key: string) -> int {
	for it, k in spage.items {
		switch {
		case it.do_ == .Nav: if fmt.tprint(it.section) == key do return k
		case it.do_ == .Grid: if POP_ACTIONS[it.pop] == key do return k // a grid cell by its action (bell_os_waiting)
		case it.action == key: return k
		case it.path != "" && strings.has_suffix(it.path, key): return k
		}
	}
	return -1
}

// ---- the keyboard's item in view ----

@(private = "file")
sp_scroll_to :: proc() {
	if !spage.scroll || spage.sel < 0 do return
	spage.scroll = false
	sc := clay.GetScrollContainerData(clay.ID("spbody"))
	body, it := clay.GetElementData(clay.ID("spbody")), clay.GetElementData(sp_id(spage.sel))
	if !sc.found || !body.found || !it.found do return
	b, r := body.boundingBox, it.boundingBox
	top, bottom := b.y + px(SP_4), b.y + b.height - px(SP_6)
	if r.y < top do sc.scrollPosition.y += top - r.y
	else if r.y + r.height > bottom do sc.scrollPosition.y -= r.y + r.height - bottom
	else do return
	app.redraw = true
}
