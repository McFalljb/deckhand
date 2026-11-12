package main

// The Settings page (ui_settings_page.odin): ⌘, opens it in the centre with no session shown (no
// pane laid out) and its own field; a control sends the setting's command; Esc goes back to the
// session it was opened from; it and the Deck view switch without stacking; only the user at this
// window opens it; an old saved "settings" tab shows Sessions; the layout audit at the smallest
// window, with long labels and paths, in every section and in a search.
// Under a temp HOME with a fake ~/.pi/agent: the user's real files are never read.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
sp_test_setup :: proc() {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true}}
	core.platform = {quit = proc() {}, notify = proc(title, body: string) {}}
	app.window_active = true
	ui_hover = nil
	deck = {cards = deck.cards}
	spage.on, spage.sel, spage.section = false, -1, .Appearance
	sp_edit_end()
	tf_set(&spage.search, "")
	state.settings.reduce_motion = true
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	base := fmt.tprintf("%s/deckhand-spage-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	home := fmt.tprintf("%s/home-with-a-rather-long-name-for-the-paths-on-the-page", base)
	proj := fmt.tprintf("%s/projects/a-project-with-a-long-folder-name", home)
	os.make_directory_all(fmt.tprintf("%s/.pi/agent/prompts", home))
	os.make_directory_all(proj)
	os.set_env("HOME", home)
	os.unset_env("PI_CODING_AGENT_DIR")
	os.unset_env("XDG_CONFIG_HOME")
	os.unset_env("PI_KIT_NOTES_DIR")
	os.unset_env("CLAUDE_CONFIG_DIR")
	core.home_root = fmt.aprintf("%s/data", base)
	core.pi_installed_probe = stand_in_installed
	core.claude_installed_probe = stand_in_installed
	core.harness_checklist_forget()
	_ = os.write_entire_file(fmt.tprintf("%s/.pi/agent/settings.json", home), transmute([]u8)string(`{"packages": []}`))
	_ = os.write_entire_file(fmt.tprintf("%s/.pi/agent/prompts/fix.md", home), transmute([]u8)string("fix"))
	state.settings.home_dir = strings.clone(fmt.tprintf("%s/Deckhand-main-folder-with-a-long-name", home))
	p := core.Project{id = 1, group = .Projects, cwd = strings.clone(proj), label = strings.clone("a-project-with-a-long-folder-name")}
	append(&state.projects, p)
	state.selected_project = p.id
	s := core.Open_Session{id = 10, project_id = 1, pi_session_id = strings.clone("s10"), cwd = strings.clone(proj), title = strings.clone("Work")}
	append(&s.tabs, core.Tab{id = 11, kind = core.Shell_Tab{}, title = strings.clone("sh"), status = .Exited})
	s.active_tab = 11
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	state.current_session = 10
}

// The item of the last layout that runs an action (-1: none).
@(private = "file")
sp_find :: proc(do_: Sp_Do, action := "", path := "") -> int {
	for it, k in spage.items do if it.do_ == do_ && (action == "" || it.action == action) && (path == "" || it.path == path) do return k
	return -1
}

@(test)
settings_page_opens_runs_and_goes_back :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sp_test_setup()
	defer sp_test_setup()
	// ⌘, (the action): no session on screen, the page with the keyboard in its field
	action_run("settings")
	core.inbox_drain()
	testing.expect(t, settings_page_shown(), "shown")
	testing.expect(t, core.cur_view() == nil, "no session on screen: no pane gets a key")
	testing.expect_value(t, state.shown_before, u64(10))
	testing.expect_value(t, state.focus_widget, "settings_page")
	f, _, _ := focused_field()
	testing.expect(t, f == &spage.search, "its field is the search")
	_ = ui_layout(1600, 900)
	testing.expect(t, clay.GetElementData(clay.ID("spage")).found, "the page laid out")
	testing.expect(t, !clay.GetElementData(pid(core.session_focused_pane(&state.open_sessions[0]), "pane")).found, "no pane laid out under it")
	// a switch sends its command: Reduce motion
	k := sp_find(.Action, "reduce_motion")
	testing.expect(t, k >= 0, "Reduce motion's switch")
	before := state.settings.reduce_motion
	settings_page_click(k)
	core.inbox_drain()
	testing.expect_value(t, state.settings.reduce_motion, !before)
	// keyboard: Tab to the next item, Space runs it (here the second section, Notifications)
	tab := sp_key(.TAB)
	settings_page_key(&tab)
	settings_page_key(&tab)
	testing.expect_value(t, spage.sel, 1)
	space := sp_key(.SPACE)
	settings_page_key(&space)
	testing.expect_value(t, spage.section, core.Setting_Section.Notifications)
	// "This project" is the session's project, from the session the page was opened from
	testing.expect(t, strings.contains(core.settings_project_cwd(), "a-project-with-a-long-folder-name"), "this project")
	// a folder: its files in the search
	settings_page_open(.Agents)
	_ = ui_layout(1600, 900)
	pk := -1
	for it, i in spage.items do if it.do_ == .Folder && strings.has_suffix(it.path, "agent/prompts") do pk = i
	testing.expect(t, pk >= 0, "prompts/ listed")
	if pk >= 0 {
		settings_page_click(pk)
		_ = ui_layout(1600, 900)
		fk := -1
		for it, i in spage.items do if it.do_ == .Open && strings.has_suffix(it.path, "prompts/fix.md") do fk = i
		testing.expectf(t, fk >= 0, "fix.md in the folder's search %q", tf_text(&spage.search))
	}
	// Esc: the search first, then back to the session
	tf_set(&spage.search, "dock")
	_ = ui_layout(1600, 900)
	testing.expect(t, sp_find(.Action, "bell_dock") >= 0, "the search finds Badge the Dock icon")
	ev := sp_key(.ESCAPE)
	testing.expect(t, settings_page_key(&ev), "Esc taken")
	testing.expect_value(t, tf_text(&spage.search), "")
	testing.expect(t, settings_page_shown(), "still shown")
	settings_page_key(&ev)
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !settings_page_shown(), "closed")
	testing.expect_value(t, state.current_session, u64(10))
	testing.expect_value(t, state.focus_widget, "")
}

@(private = "file")
sp_key :: proc(k: sapp.Keycode) -> sapp.Event {
	return {type = .KEY_DOWN, key_code = k}
}

// ⇧⌘\ and ⌘, switch between the Deck view and the page, never stacked; back goes to the session
// both were opened over.
@(test)
settings_page_and_deck_switch :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sp_test_setup()
	defer sp_test_setup()
	settings_page_open()
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, settings_page_shown() && !deck_shown(), "the page")
	deck_toggle()
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, deck_shown() && !settings_page_shown(), "the deck in its place")
	testing.expect_value(t, state.focus_widget, "")
	action_run("settings")
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, settings_page_shown() && !deck_shown(), "the page again")
	testing.expect_value(t, state.shown_before, u64(10))
	settings_page_close()
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	testing.expect(t, !settings_page_shown() && !deck_shown(), "neither: not stacked")
	testing.expect_value(t, state.current_session, u64(10))
	// a session shown by any way ends it
	settings_page_open()
	core.inbox_drain()
	core.run_command(core.Focus_Session{session = 10}, {kind = .UI})
	_ = ui_layout(1600, 900)
	testing.expect(t, !settings_page_shown() && !spage.on, "a session shown: gone")
}

// Only the user at this window opens it: not an agent, a script or another machine's core; an old
// saved Settings tab shows Sessions.
@(test)
settings_page_users_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	sp_test_setup()
	defer sp_test_setup()
	for caller in ([]core.Caller{{kind = .Control}, {kind = .Script}, {kind = .UI, hub = true}}) {
		r := core.run_command(core.Set_Focus{"settings_page"}, caller)
		testing.expectf(t, !r.ok, "%v opened it", caller)
	}
	testing.expect(t, core.run_command(core.Set_Focus{"settings_page"}, {kind = .UI}).ok, "the user")
	testing.expect(t, core.run_command(core.Set_Left_Tab{tab = .Settings}, {kind = .Control}).ok, "an old caller's set_left_tab settings: answered")
	testing.expect_value(t, state.layout.left_tab, core.Left_Tab.Sessions)
}

// The layout audit: the smallest window to a wide one, Default and Large text, every section and a
// search, a control and a nav row selected: nothing overlaps or spills.
@(test)
settings_page_layout_audit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sp_test_setup()
	defer {
		state.settings.text_size = .Default
		fonts_apply(theme_font_config(theme()), 1)
		sp_test_setup()
	}
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 1, name = "a-machine-with-a-very-long-name-indeed", status = .Needs_Login}
	settings_page_open()
	core.inbox_drain()
	problems := 0
	for size in ([]core.Text_Size{.Default, .Large}) {
		state.settings.text_size = size
		fonts_apply(theme_font_config(theme()), 1)
		for w in ([]f32{WINDOW_MIN_W, 1280, 2000}) {
			for cols in 0 ..< 2 {
				state.layout.left_open, state.layout.right_open = cols == 0, cols == 0
				views := make([dynamic]string, context.temp_allocator)
				for sec in core.Setting_Section do append(&views, fmt.tprint(sec))
				append(&views, "search:json", "search:machine", "search:nothing-matches-this")
				for v in views {
					tf_set(&spage.search, strings.has_prefix(v, "search:") ? v[len("search:"):] : "")
					for sec in core.Setting_Section do if fmt.tprint(sec) == v do spage.section = sec
					spage.sel = 3
					_ = ui_layout(w, AUDIT_H) // the items, then their boxes
					cmds := ui_layout(w, AUDIT_H)
					for b in audit(cmds, fmt.tprintf("settings page %v w=%v columns=%v %s", size, w, cols == 0, v), w) {
						problems += 1
						if problems <= 40 do testing.expectf(t, false, "%s", b)
					}
				}
			}
		}
	}
	testing.expectf(t, problems == 0, "%d layout problems", problems)
}

// The old Settings tab's row menu, on the page's file rows (right click): pi's own config files have
// no Rename or Trash; a prompt has New file…, Rename… and Move to Trash…; New file… opens the page's
// field, and Enter makes the file and opens it in the session the page was opened from.
@(test)
settings_page_file_menu :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sp_test_setup()
	defer sp_test_setup()
	defer menu_close()
	labels :: proc() -> string {
		b := strings.builder_make(context.temp_allocator)
		for it in menu_items() do if !it.sep do fmt.sbprintf(&b, "%s|", it.label)
		return strings.to_string(b)
	}
	settings_page_open(.Agents)
	core.inbox_drain()
	_ = ui_layout(1600, 900)
	k := -1
	for it, i in spage.items do if it.do_ == .Open && strings.has_suffix(it.path, "agent/settings.json") do k = i
	if !testing.expect(t, k >= 0, "settings.json listed") do return
	settings_page_context(k, {10, 10})
	testing.expect_value(t, labels(), "Open|Open in preview|Reveal in Finder|Copy path|")
	menu_close()
	// a prompt (in its folder's search)
	tf_set(&spage.search, "fix")
	_ = ui_layout(1600, 900)
	k = -1
	for it, i in spage.items do if it.do_ == .Open && strings.has_suffix(it.path, "prompts/fix.md") do k = i
	if !testing.expect(t, k >= 0, "fix.md found") do return
	settings_page_context(k, {10, 10})
	testing.expect_value(t, labels(), "Open|Open in preview|Open Markdown preview|New file…|New folder…|Rename…|Move to Trash…|Reveal in Finder|Copy path|")
	n := -1
	for it, i in menu_items() do if it.label == "New file…" do n = i
	menu_run(n)
	testing.expect(t, !menu.open, "the menu closed")
	testing.expect_value(t, spage.edit.kind, Sp_Edit_Kind.New_File)
	testing.expect(t, strings.has_suffix(spage.edit.target, ".pi/agent/prompts"), "in prompts/")
	_ = ui_layout(1600, 900)
	testing.expect(t, clay.GetElementData(clay.ID("sp_edit_box")).found, "its field shows")
	f, _, _ := focused_field()
	testing.expect(t, f == &spage.edit.field, "the field has the keyboard")
	tf_set(&spage.edit.field, "new.md")
	enter := sp_key(.ENTER)
	settings_page_key(&enter)
	core.inbox_drain()
	testing.expect(t, os.exists(fmt.tprintf("%s/.pi/agent/prompts/new.md", os.get_env("HOME", context.temp_allocator))), "made")
	_ = ui_layout(1600, 900)
	testing.expect(t, !settings_page_shown(), "opened: the session shows")
	s := core.find_session(10)
	testing.expect(t, s != nil && len(s.tabs) == 2 && s.tabs[1].title == "new.md", "in the session it was opened from")
}
