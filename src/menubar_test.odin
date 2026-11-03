package main

// The menu bar's table (menubar.odin) against the action table: ids,
// shortcuts (unique, never a terminal's key), enable and check rules, and
// the terminal text size (`./build.sh test`).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
reset :: proc() {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT, left_open = true}}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	tf_set(&palette.field, "")
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
}

@(private = "file")
state_of :: proc(id: string) -> (enabled, checked: bool) {
	it := menubar_find(id)
	if it == nil do return
	return menubar_state(menubar_tag(it))
}

@(test)
menubar_built_from_the_action_table :: proc(t: ^testing.T) {
	ids := make(map[string]bool, context.temp_allocator)
	keys := make(map[string]string, context.temp_allocator)
	in_menu := make(map[string]bool, context.temp_allocator)
	for it in menubar_items() {
		id := menubar_item_id(it)
		testing.expectf(t, id != "", "an item without an id or action: %q", it.title)
		testing.expectf(t, id not_in ids, "menu item id %q twice", id)
		ids[id] = true
		if it.action != "" {
			testing.expectf(t, action_by_id(it.action) != nil, "menu item %q: no such action", it.action)
			in_menu[it.action] = true
		} else {
			testing.expectf(t, it.title != "", "%s: a key or native item needs a title", id)
		}
		testing.expectf(t, menubar_item_title(it) != "", "%s: no title", id)
		k := menubar_keys(it)
		if k == "" do continue
		pk, ok := parse_keys(k)
		testing.expectf(t, ok && pk.equiv != "", "%s: shortcut %q does not parse", id, k)
		// shortcuts are chords: a plain or ⌥ key is the terminal's (and text's)
		testing.expectf(t, pk.mods & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL) != 0, "%s: %q is not a ⌘ or ⌃ chord", id, k)
		// ⌃ without ⌘ is the terminal's (readline ⌃G, ⌃A…): a menu item would flash on every press
		testing.expectf(t, pk.mods & sapp.MODIFIER_SUPER != 0 || it.native != .None, "%s: %q is a ⌃ key without ⌘", id, k)
		// ⌘⌫ ⌘← ⌘→ are the terminal's line editing: never a menu's
		testing.expectf(t, !(pk.code == .BACKSPACE || pk.code == .LEFT || pk.code == .RIGHT), "%s: %q is a terminal key", id, k)
		norm := fmt.tprintf("%v+%d", pk.code, pk.mods)
		testing.expectf(t, norm not_in keys, "shortcut %s on both %s and %s", k, keys[norm], id)
		keys[norm] = id
	}
	// every shortcut of the action table is unique and in the menu bar
	seen := make(map[string]string, context.temp_allocator)
	for a in ACTIONS {
		if a.keys == "" do continue
		testing.expectf(t, a.keys not_in seen, "actions %s and %s share %s", seen[a.keys], a.id, a.keys)
		seen[a.keys] = a.id
		testing.expectf(t, in_menu[a.id], "action %s (%s) has a shortcut but no menu item", a.id, a.keys)
	}
	// the extra shortcuts are not the menu bar's
	for x in SHORTCUTS_EXTRA {
		for part in strings.split(x.keys, ", ", context.temp_allocator) {
			pk, ok := parse_keys(part)
			if !ok do continue
			norm := fmt.tprintf("%v+%d", pk.code, pk.mods)
			testing.expectf(t, norm not_in keys || x.keys == "⌘/", "%s (%s) is also the menu's %s", part, x.label, keys[norm])
		}
	}
	// the sheet: grouped like the menus, every menu shortcut on it
	rows := shortcut_rows()
	testing.expect(t, rows[0].head && rows[0].label == "pi-desk")
	for it in menubar_items() {
		k := menubar_keys(it)
		if k == "" || strings.has_prefix(it.action, "tab_") do continue
		found := false
		for r in rows do if r.keys == k do found = true
		testing.expectf(t, found, "%s (%s) is not on the shortcuts sheet", menubar_item_id(it), k)
	}
}

@(test)
menubar_key_lookup :: proc(t: ^testing.T) {
	S, SH, A := u32(sapp.MODIFIER_SUPER), u32(sapp.MODIFIER_SHIFT), u32(sapp.MODIFIER_ALT)
	testing.expect_value(t, menubar_key_action(.EQUAL, S), "text_bigger") // ⌘=
	testing.expect_value(t, menubar_key_action(.EQUAL, S | SH), "text_bigger") // ⌘+ on a US keyboard
	testing.expect_value(t, menubar_key_action(.MINUS, S), "text_smaller")
	testing.expect_value(t, menubar_key_action(._0, S), "text_reset")
	testing.expect_value(t, menubar_key_action(.RIGHT_BRACKET, S | SH), "next_tab")
	testing.expect_value(t, menubar_key_action(.LEFT_BRACKET, S | SH), "prev_tab")
	testing.expect_value(t, menubar_key_action(.DOWN, S | A), "next_session")
	testing.expect_value(t, menubar_key_action(.UP, S | A), "prev_session")
	testing.expect_value(t, menubar_key_action(.RIGHT_BRACKET, S), "") // the editor's indent
	testing.expect_value(t, menubar_key_action(.BACKSPACE, S), "") // the terminal's
	testing.expect_value(t, menubar_key_action(.LEFT, S), "")
	testing.expect_value(t, menubar_key_action(.N, S | SH), "new_session")
	k, ok := parse_keys("⇧⌘N")
	testing.expect(t, ok && k.code == .N && k.mods == S | SH && k.equiv == "n" && k.ns_mods == NS_COMMAND | NS_SHIFT)
	k, ok = parse_keys("⌃⌘F")
	testing.expect(t, ok && k.equiv == "f" && k.ns_mods == NS_COMMAND | NS_CONTROL)
	// arrows: AppKit's function-key characters, written as escapes (never invisible in the source)
	k, ok = parse_keys("⌥⌘↓")
	testing.expect(t, ok && k.code == .DOWN && k.equiv == "\uF701" && k.ns_mods == NS_COMMAND | NS_OPTION)
	k, ok = parse_keys("⌥⌘↑")
	testing.expect(t, ok && k.code == .UP && k.equiv == "\uF700")
	_, ok = parse_keys("F2")
	testing.expect(t, !ok)
}

@(test)
menubar_enable_and_check_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	reset()
	// nothing open: no tab or editor items; the app's always are
	e, c := state_of("new_shell_tab")
	testing.expect(t, !e, "new shell tab needs a session")
	e, _ = state_of("save_file")
	testing.expect(t, !e, "save needs an editor")
	e, _ = state_of("quit")
	testing.expect(t, e)
	e, _ = state_of("about")
	testing.expect(t, e, "AppKit's own items are AppKit's to validate")
	for id in ([]string{"undo", "cut", "copy", "paste", "select_all", "find_next"}) {
		e, _ = state_of(id)
		testing.expectf(t, !e, "%s with nothing to act on", id)
	}
	// checkmarks follow the state
	_, c = state_of("toggle_left")
	testing.expect(t, c)
	run_command(Set_Layout{left_open = false})
	_, c = state_of("toggle_left")
	testing.expect(t, !c)
	_, c = state_of("appearance_system")
	testing.expect(t, c)
	_, c = state_of("appearance_dark")
	testing.expect(t, !c)
	run_command(Set_Appearance{mode = .Dark})
	_, c = state_of("appearance_dark")
	testing.expect(t, c)
	// a text field has the keyboard: the Edit items act on it
	run_command(Set_Focus{"palette"}, {kind = .UI})
	for id in ([]string{"cut", "copy", "paste", "select_all"}) {
		e, _ = state_of(id)
		testing.expectf(t, e, "%s in the palette's field", id)
	}
	e, _ = state_of("undo")
	testing.expect(t, !e, "fields have no undo")
	run_command(Set_Focus{""}, {kind = .UI})

	// an editor: Save only with changes; undo, find
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	dir := fmt.tprintf("%s/pi-desk-menubar-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(dir), label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("s-1"), project_id = state.projects[0].id, cwd = strings.clone(dir)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	path := fmt.tprintf("%s/a.txt", dir)
	_ = os.write_entire_file(path, transmute([]u8)string("hello\n"))
	r := run_command(Open_File{path = path}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	ed := editor_of(r.created_id)
	if ed == nil do return
	e, _ = state_of("save_file")
	testing.expect(t, !e, "a clean editor: nothing to save")
	ed_insert(ed, "x")
	e, _ = state_of("save_file")
	testing.expect(t, e, "unsaved changes: Save")
	for id in ([]string{"undo", "redo", "cut", "copy", "paste", "select_all", "find_in_file", "find_next", "goto_line"}) {
		e, _ = state_of(id)
		testing.expectf(t, e, "%s in an editor", id)
	}
	// tabs: next and previous with two; Tab 2 exists, Tab 3 does not
	e, _ = state_of("next_tab")
	testing.expect(t, e)
	e, _ = state_of("tab_2")
	testing.expect(t, e)
	e, _ = state_of("tab_3")
	testing.expect(t, !e)
	cmd, ok := action_by_id("next_tab").make()
	testing.expect(t, ok)
	if ft, is := cmd.(Focus_Tab); is do testing.expect_value(t, ft.tab_id, state.open_sessions[0].tabs[0].id) // round to the pi tab
	// one session: nothing to step to
	e, _ = state_of("next_session")
	testing.expect(t, !e)
	editor_drop(r.created_id)
}

@(test)
menubar_terminal_text_size :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	reset()
	testing.expect_value(t, term_text_pt(), f32(TYPE_CODE_PX))
	e, _ := state_of("text_reset")
	testing.expect(t, !e, "already the look's size")
	action_run("text_bigger")
	inbox_drain()
	testing.expect_value(t, state.settings.term_text_pt, TYPE_CODE_PX + 1)
	testing.expect_value(t, theme_font_config(theme()).mono_pt, f32(TYPE_CODE_PX + 1))
	action_run("text_smaller")
	inbox_drain()
	testing.expect_value(t, state.settings.term_text_pt, 0) // back to the look's: stored as 0
	r := run_command(Set_Terminal_Text_Size{pt = TERM_TEXT_MAX + 1})
	testing.expect(t, !r.ok, "too big")
	r = run_command(Set_Terminal_Text_Size{pt = TERM_TEXT_MIN})
	testing.expect(t, r.ok)
	e, _ = state_of("text_smaller")
	testing.expect(t, !e, "the smallest size")
	e, _ = state_of("text_reset")
	testing.expect(t, e)
	run_command(Set_Terminal_Text_Size{pt = 0})
}

// Help › pi-desk user guide: Atlas's copy of the guide, read-only, only when
// it exists.
@(test)
menubar_user_guide_read_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	dir := fmt.aprintf("%s/pi-desk-guide-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/atlas", dir))
	defer os.remove_all(dir)
	was := home_root
	home_root = dir
	defer home_root = was
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(dir), label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("s-g"), project_id = state.projects[0].id, cwd = strings.clone(dir)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	e, _ := state_of("user_guide")
	testing.expect(t, !e, "no copy of the guide yet: disabled")
	path := agent_guide_path()
	_ = os.write_entire_file(path, transmute([]u8)string("# guide\n"))
	e, _ = state_of("user_guide")
	testing.expect(t, e, "the copy exists: enabled")
	action_run("user_guide")
	inbox_drain()
	ed := tab_editor()
	testing.expect(t, ed != nil && ed.readonly, "opens read-only")
	if ed == nil do return
	ed_insert(ed, "x")
	testing.expect(t, !editor_dirty(ed), "no edits")
	r := run_command(Save_File{ed.tab_id})
	testing.expect(t, !r.ok, "no saves")
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "# guide\n")
	// opened another way (Files, an agent): read-only too
	r = run_command(Close_Tab{tab_id = ed.tab_id})
	testing.expect(t, r.ok, r.error)
	r = run_command(Open_File{path = path}, {kind = .Script})
	ed2 := editor_of(r.created_id)
	testing.expect(t, ed2 != nil && ed2.readonly, "the guide copy is always read-only")
	if ed2 != nil do editor_drop(ed2.tab_id)
}
