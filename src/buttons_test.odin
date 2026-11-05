package main

// Buttons (ui_toolbar.odin): every action that has a button names a real
// action, has exactly one control, and that control is reachable in a real
// layout (Clay, with the system fonts) at its centre; its tooltip is the
// action's label and shortcut from the table. Same rules as core_test.odin
// (one thread, harmless processes).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
bt_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true},
	}
	menu = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	return runtime.heap_allocator()
}

// Fonts and Clay once, at 1x, without a window (layout only, no drawing).
@(private = "file")
bt_ui :: proc() -> bool {
	@(static) ready: bool
	if ready do return true
	app.dpi = 1
	font.size = ATLAS_MIN
	font.pixels = make([]u8, ATLAS_MIN * ATLAS_MIN * 4)
	if !fonts_apply(theme_font_config(theme()), 1) do return false
	ui_init()
	ready = true
	return true
}

// Lays out a window, then reports what a click at element `name`'s centre hits.
@(private = "file")
hit_at :: proc(name: string, index: u32 = 0) -> (Hit, bool) {
	_ = ui_layout(1400, 860)
	d := clay.GetElementData(clay.ID(name, index))
	if !d.found do return nil, false
	b := d.boundingBox
	clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
	return ui_hit(), true
}

// What set_hover records, without the window's pointer shape (no window here).
@(private = "file")
hover :: proc(h: Hit) {
	ui_hover = h
	tip_hover_changed()
}

@(private = "file")
expect_tip :: proc(t: ^testing.T, h: Hit, action_id: string, loc := #caller_location) {
	a := action_by_id(action_id)
	if !testing.expectf(t, a != nil, "no action %q", action_id, loc = loc) do return
	label, keys := hit_tip(h)
	testing.expectf(t, label == a.label && keys == a.keys, "tooltip of %v: %q %q, want %q %q", h, label, keys, a.label, a.keys, loc = loc)
}

@(test)
buttons_name_actions_once :: proc(t: ^testing.T) {
	seen := make(map[string]string, context.temp_allocator) // action -> control
	for b in Button {
		info := BUTTONS[b]
		if info.action == "" do continue
		testing.expectf(t, action_by_id(info.action) != nil, "button %v: no action %q", b, info.action)
		expect_tip(t, Hit_Button(b), info.action)
		// the empty states repeat a toolbar action on purpose (a bigger target)
		if b == .Empty_New_Chat || b == .Empty_Close do continue
		testing.expectf(t, info.action not_in seen, "action %q has two toolbar buttons (%s, %v)", info.action, seen[info.action], b)
		seen[info.action] = fmt.tprint(b)
	}
	for it in Pop_Item {
		id := POP_ACTIONS[it]
		testing.expectf(t, action_by_id(id) != nil, "popover row %v: no action %q", it, id)
		testing.expectf(t, id not_in seen, "action %q has a toolbar button and a popover row", id)
		seen[id] = fmt.tprint(it)
	}
	// element ids are unique
	names := make(map[string]bool, context.temp_allocator)
	for b in Button {
		testing.expectf(t, BUTTONS[b].element not_in names, "element %q twice", BUTTONS[b].element)
		names[BUTTONS[b].element] = true
	}
	// every shortcut in the sheet comes from the table (or the short extra list)
	for r in shortcut_rows() do testing.expect(t, r.label != "" && (r.keys != "") != r.head)
	testing.expect(t, len(shortcut_rows()) >= 10)
	testing.expect_value(t, NEW_MENU_TIP != "", true)
}

@(test)
buttons_reachable_in_layout :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	dir := fmt.tprintf("%s/pd-bt-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(dir)
	// Chats (New chat, ⌘N) needs a data dir; an empty pi store under a temp HOME
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("HOME", fmt.tprintf("%s/home", dir))
	defer os.set_env("HOME", old_home)
	old_root := home_root
	home_root = fmt.tprintf("%s/data", dir)
	defer home_root = old_root
	rescan_now()
	r := run_command(Add_Project{cwd = dir}, {kind = .UI})
	testing.expect(t, r.ok, r.error)

	// no session open: the toolbar, minus the tab strip's; the empty state's New chat
	for b in ([]Button{.Toggle_Left, .New_Chat, .Search, .Settings, .Toggle_Right, .Empty_New_Chat}) {
		h, found := hit_at(BUTTONS[b].element)
		testing.expectf(t, found, "%v: not laid out", b)
		testing.expectf(t, h == Hit(Hit_Button(b)), "%v: a click at its centre hits %v", b, h)
	}
	// a session open: the tab strip's buttons, every tab's close button
	run_command(New_Chat{project_id = state.selected_project}, {kind = .UI})
	run_command(New_Shell_Tab{session = cur().id}, {kind = .UI})
	for b in ([]Button{.Toggle_Left, .New_Chat, .Search, .New_Tab, .New_Menu, .Settings, .Toggle_Right}) {
		h, found := hit_at(BUTTONS[b].element)
		testing.expectf(t, found, "%v: not laid out", b)
		testing.expectf(t, h == Hit(Hit_Button(b)), "%v: a click at its centre hits %v", b, h)
	}
	_, empty := hit_at(BUTTONS[.Empty_New_Chat].element)
	testing.expect(t, !empty, "the empty state is gone while a tab shows")
	cs := cur()
	for tab, i in cs.tabs {
		h, found := hit_at("tabclose", u32(i))
		testing.expectf(t, found && h == Hit(Hit_Close_Tab(tab.id)), "tab %d: close hits %v", i, h)
	}
	expect_tip(t, Hit_Close_Tab(cs.tabs[0].id), "close_session") // the pi tab's closes the session
	expect_tip(t, Hit_Close_Tab(cs.tabs[1].id), "close_tab")
	expect_tip(t, Hit_Home{}, "toggle_agent") // the agent's button, far right
	ha, founda := hit_at("homebutton")
	testing.expectf(t, founda && ha == Hit(Hit_Home{}), "the agent's button: hits %v", ha)

	// the left column hidden: its two buttons move to the top bar
	run_command(Set_Layout{left_open = false}, {kind = .UI})
	for b in ([]Button{.Toggle_Left, .New_Chat}) {
		h, found := hit_at(BUTTONS[b].element)
		testing.expectf(t, found && h == Hit(Hit_Button(b)), "%v (left hidden): hits %v", b, h)
	}
	run_command(Set_Layout{left_open = true}, {kind = .UI})

	// the settings popover: every row and choice (back to ~/Chats shows while
	// another folder is set); the looks' tooltips
	r = run_command(Set_Folder{kind = .Chats, path = dir}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	run_command(Set_Focus{"settings"}, {kind = .UI})
	_ = ui_layout(1400, 860) // the popover anchors to the button's last box
	for it in Pop_Item {
		// Reload all pi tabs, Restart all Claude tabs: only while such a tab runs (pop_item_shown);
		// tests/scripts/claude-runtime.txt clicks the Claude one
		if !pop_item_shown(it) do continue
		h, found := hit_at("pop", u32(it))
		testing.expectf(t, found && h == Hit(Hit_Pop(it)), "popover %v: hits %v", it, h)
		if it >= .Look_Graphite && it <= .Look_Ghostty do expect_tip(t, h, POP_ACTIONS[it])
	}
	// nothing under it is hit
	h, _ := hit_at(BUTTONS[.Search].element)
	testing.expect(t, h == nil, "the popover covers the rest")
	run_command(Set_Focus{""}, {kind = .UI})

	// the shortcuts sheet: its close button
	run_command(Set_Focus{"shortcuts"}, {kind = .UI})
	h2, found2 := hit_at("sheet_close")
	testing.expect(t, found2 && h2 == Hit(Hit_Sheet_Close{}))
	run_command(Set_Focus{""}, {kind = .UI})

	// a project row's "…" (laid out while the row is hovered)
	if p := find_project(state.selected_project); p != nil {
		hover(Hit_Project(p.id))
		_ = ui_layout(1400, 860) // fades start at their target: shown at once
		h3, found3 := hit_at("projmore", 0)
		testing.expectf(t, found3 && h3 == Hit(Hit_More_Project(p.id)), "project row …: hits %v", h3)
		hover(nil)
	}
	run_command(Close_Session{session = cur().id}, {kind = .UI})
	for p in state.pending_confirmations do run_command(Cancel_Confirmation{token = p.token}, {kind = .UI})
}

@(test)
buttons_run_their_actions :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	ui := Caller{kind = .UI}
	// what a click runs goes through the inbox as the user
	button_click(.Toggle_Left)
	inbox_drain()
	testing.expect_value(t, state.layout.left_open, false)
	button_click(.Toggle_Right)
	inbox_drain()
	testing.expect_value(t, state.layout.right_open, false)
	button_click(.Search)
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "palette")
	button_click(.Settings)
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "settings")
	button_click(.Settings) // again: closes
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "")
	pop_run(.Appearance_Dark)
	pop_run(.Look_Warm)
	pop_run(.Reduce_Motion)
	inbox_drain()
	testing.expect_value(t, state.settings.appearance, Appearance.Dark)
	testing.expect_value(t, state.settings.theme, Theme_Id.Warm)
	testing.expect_value(t, state.settings.reduce_motion, true)
	run_command(Set_Focus{"settings"}, ui)
	pop_run(.Shortcuts) // the sheet replaces the popover
	inbox_drain()
	testing.expect_value(t, state.focus_widget, "shortcuts")
	// tooltips wait TIP_DELAY, then show once; a click hides them
	hover(Hit_Button(.New_Chat))
	testing.expect(t, !tip_due(), "not yet")
	tip.since = time.tick_add(time.tick_now(), -TIP_DELAY)
	testing.expect(t, tip_due(), "due")
	testing.expect(t, !tip_due(), "only once: no redraw loop")
	tip_dismiss()
	testing.expect(t, !tip.shown)
	hover(nil)
	run_command(Set_Focus{""}, ui)
}

// Review fix 1: the pi tab's × and ⌘W close a whole session, so they always
// ask (the confirmation bar), even while pi is idle and no shell runs.
@(test)
pi_tab_close_always_asks :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	dir := fmt.tprintf("%s/pd-bt-close-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(dir)
	ui := Caller{kind = .UI}
	run_command(Add_Project{cwd = dir}, ui)
	run_command(New_Chat{project_id = state.selected_project}, ui)
	cs := cur()
	if !testing.expect(t, cs != nil) do return
	cs.tabs[0].agent = .Idle // pi idle: closing would not need a confirmation by itself
	id := cs.id
	close_tab_click(cs.tabs[0].id)
	inbox_drain()
	testing.expect_value(t, len(state.pending_confirmations), 1)
	testing.expect(t, find_session(id) != nil, "still open until the user confirms")
	// confirming (the bar's Confirm resends with the token) closes it
	if len(state.pending_confirmations) == 1 {
		confirm_pending(state.pending_confirmations[0].token)
		inbox_drain()
	}
	testing.expect(t, find_session(id) == nil, "closed after the confirmation")
	testing.expect_value(t, len(state.pending_confirmations), 0)
}

// Review fix 2: only the user opens the palette, the settings popover and the
// shortcuts sheet (they take the user's keys).
@(test)
overlays_are_the_users :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	for kind in ([]Caller_Kind{.Control, .Script, .Panel}) {
		for w in ([]string{"settings", "shortcuts", "palette"}) {
			r := run_command(Set_Focus{w}, {kind = kind})
			testing.expectf(t, !r.ok, "%v opened %s", kind, w)
			testing.expect_value(t, state.focus_widget, "")
		}
	}
	r := run_command(Set_Focus{"settings"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	run_command(Set_Focus{""}, {kind = .Control}) // closing is fine for anyone
	testing.expect_value(t, state.focus_widget, "")
}

// Review fix 3: hiding the left column mid-drag must not save its width as 0
// (clamped to the minimum).
@(test)
hide_left_during_drag_keeps_width :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	state.layout.left_width = 333
	divider = {active = true, which = 0, x0 = 0, w0 = 333, value = 360}
	run_command(Set_Layout{left_open = false}, {kind = .UI})
	divider_release()
	inbox_drain()
	testing.expect_value(t, state.layout.left_width, 333)
	testing.expect(t, !divider.active)
}

// The agent drawer's left edge is a column divider (2) in both modes: a
// press there resizes the drawer even over Atlas's running terminal (which
// takes the presses a few px further in), the width is saved as laid out,
// and a double-click resets it.
@(test)
drawer_edge_resizes_not_terminal :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	home_root = fmt.aprintf("%s/pd-drawer-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(home_root)
	defer {
		// shut, slid out at once: later layouts start without the drawer
		state.home_open, state.layout.drawer_pinned = false, false
		state.settings.reduce_motion = true
		_ = ui_layout(1600, 900)
		for _, x in terms do reader_stop_and_close(x)
		home_root = ""
		divider = {}
	}
	r := run_command(Set_Home{open = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, agent_term() != nil, "Atlas's terminal")
	state.settings.reduce_motion = true // in place, not sliding
	for pinned in ([]bool{false, true}) {
		state.layout.drawer_pinned = pinned
		state.layout.drawer_width = DRAWER_WIDTH_DEFAULT
		_ = ui_layout(1600, 900)
		d := clay.GetElementData(clay.ID("drawer"))
		term := clay.GetElementData(clay.ID("drawer_term"))
		if !testing.expectf(t, d.found && term.found, "pinned=%v: drawer laid out", pinned) do continue
		x, y := d.boundingBox.x, term.boundingBox.y + term.boundingBox.height / 2 // over the terminal
		testing.expectf(t, divider_at(x + 2, y) == 2, "pinned=%v: the edge is a divider", pinned)
		testing.expectf(t, divider_at(x - 2, y) == 2, "pinned=%v: just outside the edge too", pinned)
		testing.expectf(t, divider_at(x + px(TERM_PAD), y) == -1, "pinned=%v: the terminal's first column is not", pinned)
		// a press on the edge starts the drag; the terminal does not get it
		e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x + 2, mouse_y = y}
		app.clicks = 1
		testing.expectf(t, drawer_event(&e), "pinned=%v: the drawer takes the press", pinned)
		testing.expectf(t, divider.active && divider.which == 2, "pinned=%v: a drag of the drawer's edge (%v)", pinned, divider)
		divider_move(x + 2 - 100)
		_ = ui_layout(1600, 900)
		testing.expectf(t, clay.GetElementData(clay.ID("drawer")).boundingBox.width == 520, "pinned=%v: live width", pinned)
		divider_release()
		inbox_drain()
		testing.expectf(t, state.layout.drawer_width == 520, "pinned=%v: saved %v", pinned, state.layout.drawer_width)
		// a double-click resets it
		app.clicks = 2
		_ = ui_layout(1600, 900)
		e.mouse_x = clay.GetElementData(clay.ID("drawer")).boundingBox.x
		drawer_event(&e)
		inbox_drain()
		testing.expectf(t, !divider.active && state.layout.drawer_width == DRAWER_WIDTH_DEFAULT, "pinned=%v: reset, %v", pinned, state.layout.drawer_width)
		// the clamps (moved from the drawer-resize scene): its minimum, 320; the room there is:
		// sliding over, 70% of the space right of the left column (0.7 * 1300); pinned, what
		// the panels (320) and the centre's minimum (360) leave of 1300
		Clamp :: struct {
			dx:   f32,
			want: f32,
		}
		for c in ([]Clamp{{400, 320}, {-2000, pinned ? 620 : 910}}) {
			app.clicks = 1
			_ = ui_layout(1600, 900)
			e.mouse_x = clay.GetElementData(clay.ID("drawer")).boundingBox.x + 2
			drawer_event(&e)
			divider_move(e.mouse_x + c.dx)
			divider_release()
			inbox_drain()
			testing.expectf(t, state.layout.drawer_width == c.want, "pinned=%v: dragged %v, width %v, want %v", pinned, c.dx, state.layout.drawer_width, c.want)
		}
	}
}

// Review fixes: a bare click on a divider saves nothing (not even the width a
// small window clamped it to), and beside a pinned drawer at its room limit
// the panels' divider cannot grow into the drawer (the drawer keeps its
// width; the line stays under the pointer up to the limit).
@(test)
divider_bare_click_and_pinned_panels :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	home_root = fmt.aprintf("%s/pd-divider-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(home_root)
	defer {
		state.home_open, state.layout.drawer_pinned = false, false
		state.settings.reduce_motion = true
		_ = ui_layout(1600, 900)
		for _, x in terms do reader_stop_and_close(x)
		home_root = ""
		divider = {}
	}
	// a small window draws the columns narrower than saved; a bare click keeps the saved widths
	state.layout.left_width, state.layout.right_width = 480, 560
	_ = ui_layout(900, 700)
	for which in 0 ..< 2 {
		divider_press(which, 0, 1)
		divider_release()
		inbox_drain()
	}
	testing.expect_value(t, state.layout.left_width, 480)
	testing.expect_value(t, state.layout.right_width, 560)
	state.layout.left_width, state.layout.right_width = LEFT_WIDTH_DEFAULT, RIGHT_WIDTH_DEFAULT
	// pinned at its room limit (1300 - 320 - 360 = 620), saved wider
	r := run_command(Set_Home{open = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	state.settings.reduce_motion = true
	state.layout.drawer_pinned = true
	state.layout.drawer_width = 1000
	_ = ui_layout(1600, 900)
	testing.expect_value(t, drawer_w(), 620)
	divider_press(2, 0, 1) // a bare click on the drawer's edge
	divider_release()
	inbox_drain()
	testing.expect_value(t, state.layout.drawer_width, 1000)
	// saved as a drag of its edge leaves it: at the limit
	state.layout.drawer_width = 620
	_ = ui_layout(1600, 900)
	// the panels' divider dragged 100 px wider: no room, the drawer keeps 620
	x := clay.GetElementData(clay.ID("right")).boundingBox.x
	divider_press(1, x, 1)
	divider_move(x - 100)
	_ = ui_layout(1600, 900)
	testing.expect_value(t, drawer_w(), 620)
	testing.expect_value(t, clay.GetElementData(clay.ID("right")).boundingBox.x, x)
	divider_release()
	inbox_drain()
	testing.expect_value(t, state.layout.right_width, 320)
	// narrower by 40, then wider by 100: back to the limit (320), the line under the pointer until then
	_ = ui_layout(1600, 900)
	divider_press(1, x, 1)
	divider_move(x + 40)
	divider_release()
	inbox_drain()
	testing.expect_value(t, state.layout.right_width, 280)
	_ = ui_layout(1600, 900)
	x = clay.GetElementData(clay.ID("right")).boundingBox.x
	divider_press(1, x, 1)
	divider_move(x - 30)
	_ = ui_layout(1600, 900)
	testing.expect_value(t, clay.GetElementData(clay.ID("right")).boundingBox.x, x - 30)
	divider_move(x - 100)
	divider_release()
	inbox_drain()
	testing.expect_value(t, state.layout.right_width, 320)
	_ = ui_layout(1600, 900)
	testing.expect_value(t, drawer_w(), 620)
}

// The input method's candidate window follows the job sheet's caret (the
// marked text's caret): on the caret's own line of a multi-line, wrapped
// Prompt, after the text before it on that line; not the field's last line.
@(test)
job_sheet_ime_anchor_follows_caret :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	defer {
		job_sheet.open, job_sheet.focus = false, .Name
		tf_set(&job_sheet.fields[.Prompt], "")
		state.focus_widget = ""
		delete(ime.marked)
		ime.marked, ime.caret = "", 0
	}
	job_sheet.open, job_sheet.focus = true, .Prompt
	state.focus_widget = "job_sheet"
	tf := &job_sheet.fields[.Prompt]
	tf.multiline = true
	long := strings.repeat("word ", 80, context.temp_allocator) // wraps
	head := "first line\nsecond line\nthird: "
	tf_set(tf, strings.concatenate({head, "the caret is here\n", long, "end"}, context.temp_allocator))
	tf.cursor, tf.anchor = len(head), len(head)
	lh := text_line_height(.UI)
	cmds := ui_layout(1400, 860)
	d := clay.GetElementData(clay.ID("jstext"))
	if !testing.expect(t, d.found, "the Prompt's text laid out") do return
	b := d.boundingBox
	testing.expectf(t, b.height > 5 * lh, "the long line wraps (%v high)", b.height)
	r, ok := job_sheet_caret_rect(cmds)
	if !testing.expect(t, ok, "a caret rect") do return
	testing.expectf(t, abs(r.y - (b.y + 2 * lh)) < 1, "third line: y %v, text top %v, line %v", r.y, b.y, lh)
	testing.expectf(t, abs(r.x - (b.x + text_width("third: ", .UI))) < 1, "after \"third: \": x %v, text left %v", r.x, b.x)
	// the composition's caret: after the marked text before it
	ime.marked, ime.caret = strings.clone("´e"), len("´") // a byte offset
	cmds = ui_layout(1400, 860)
	r2, ok2 := job_sheet_caret_rect(cmds)
	testing.expect(t, ok2, "a caret rect while composing")
	testing.expectf(t, abs(r2.x - (b.x + text_width("third: ´", .UI))) < 1, "after the marked \"´\": x %v", r2.x)
	// at the end of the wrapped text: below the third line
	tf.cursor, tf.anchor = len(tf.buf), len(tf.buf)
	delete(ime.marked)
	ime.marked, ime.caret = "", 0
	cmds = ui_layout(1400, 860)
	r3, ok3 := job_sheet_caret_rect(cmds)
	testing.expect(t, ok3, "a caret rect at the end")
	testing.expectf(t, r3.y > b.y + 4 * lh - 1 && r3.y < b.y + b.height, "last line: y %v in %v..%v", r3.y, b.y, b.y + b.height)
}

// Renaming a nested project: the field stays at the row's indent (the
// chevron's column), as a top-level row's does at its own.
@(test)
rename_field_keeps_tree_indent :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	defer {
		state.focus_widget = ""
		clear(&state.projects)
		clear(&state.sidebar.expanded)
	}
	append(&state.projects, Project{id = 101, group = .Projects, cwd = "/pd-test/parent", label = "parent"})
	append(&state.projects, Project{id = 102, group = .Projects, cwd = "/pd-test/parent/child", label = "child", parent = 101})
	append(&state.sidebar.expanded, "/pd-test/parent")
	field_x := proc(id: u64) -> (f32, bool) {
		state.selected_project = id
		state.focus_widget = "rename_project"
		_ = ui_layout(1400, 860)
		d := clay.GetElementData(clay.ID("rename_text"))
		return d.boundingBox.x, d.found
	}
	top, ok1 := field_x(101)
	nested, ok2 := field_x(102)
	if !testing.expect(t, ok1 && ok2, "the rename field laid out for both") do return
	testing.expectf(t, abs(nested - top - px(TREE_INDENT)) < 0.5, "nested %v, top %v: one level in (%v)", nested, top, px(TREE_INDENT))
}

// The rename field's keys (moved from the phase05 scene): typing replaces the
// selected name, Backspace edits, Enter renames and gives focus back, Cmd-A
// then typing replaces everything, Escape leaves the name as it was.
@(test)
rename_field_keys :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	defer {
		state.focus_widget = ""
		clear(&state.projects)
		tf_set(&rename_field, "")
	}
	append(&state.projects, Project{id = 201, group = .Projects, cwd = "/pd-test/proj", label = "proj"})
	state.selected_project = 201
	key :: proc(code: sapp.Keycode, mods: u32 = 0) {
		e := sapp.Event{type = .KEY_DOWN, key_code = code, modifiers = mods}
		widget_event(&e)
	}
	type :: proc(s: string) {
		for r in s {
			e := sapp.Event{type = .CHAR, char_code = u32(r)}
			widget_event(&e)
		}
	}
	open :: proc() {
		run_command(Set_Focus{widget = "rename_project"}, {kind = .UI})
		tf_set(&rename_field, project_name(find_project(201)^)) // as the palette's Rename project does
	}

	open()
	testing.expect_value(t, tf_selected_text(&rename_field), "proj")
	type("Renamed 1")
	key(.BACKSPACE)
	type("x")
	key(.LEFT)
	key(.LEFT, sapp.MODIFIER_SHIFT)
	key(.C, sapp.MODIFIER_SUPER) // copy leaves the text alone
	key(.ENTER)
	inbox_drain()
	testing.expect_value(t, find_project(201).name, "Renamed x")
	testing.expect_value(t, state.focus_widget, "")

	open()
	key(.A, sapp.MODIFIER_SUPER)
	type("Other")
	key(.ESCAPE)
	inbox_drain()
	testing.expect_value(t, find_project(201).name, "Renamed x")
	testing.expect_value(t, state.focus_widget, "")

	open()
	key(.A, sapp.MODIFIER_SUPER)
	type("Pasted name")
	key(.ENTER)
	inbox_drain()
	testing.expect_value(t, find_project(201).name, "Pasted name")
}

// A panel whose only row is its head row (pi-kit's "Todos 3/3" with the
// done items hidden) is just a header: no fold arrow, no empty body, not a
// toggle. A panel with rows keeps its arrow and folds.
@(test)
panel_head_only_is_not_a_dropdown :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	s := Open_Session{id = new_id(), pi_session_id = "pi-x", cwd = "/pd-test"}
	pi := Tab{id = new_id(), kind = Pi_Tab{}, title = "pi"}
	todos := Panel{id = strings.clone("todos"), title = strings.clone("Todos")}
	append(&todos.rows, Panel_Row{text = strings.clone("Todos 3/3"), head = true}, Panel_Row{text = ""})
	shells := Panel{id = strings.clone("shells"), title = strings.clone("Shells")}
	append(&shells.rows, Panel_Row{text = strings.clone("Shells 1"), head = true}, Panel_Row{text = strings.clone("● npm test")})
	append(&pi.panels, todos, shells)
	append(&s.tabs, pi)
	s.active_tab = pi.id
	append(&state.open_sessions, s)
	state.current_session = s.id
	state.layout.right_open = true
	defer {
		state.current_session = 0
		clear(&state.open_sessions)
		clear(&state.layout.collapsed)
	}
	drawn := proc(cmds: clay.ClayArray(clay.RenderCommand), text: string) -> int {
		n := 0
		for i in 0 ..< cmds.length {
			c := &cmds.internalArray[i]
			if c.commandType != .Text do continue
			td := c.renderData.text
			if string(td.stringContents.chars[:td.stringContents.length]) == text do n += 1
		}
		return n
	}
	for folded in ([]bool{false, true}) {
		clear(&state.layout.collapsed)
		if folded do append(&state.layout.collapsed, "todos", "shells")
		cmds := ui_layout(1400, 860)
		testing.expectf(t, drawn(cmds, "Todos 3/3") == 1, "folded=%v: the head row is the header", folded)
		testing.expectf(t, drawn(cmds, "▾") + drawn(cmds, "▸") == 1, "folded=%v: one arrow (the shells panel's), got ▾ %d ▸ %d", folded, drawn(cmds, "▾"), drawn(cmds, "▸"))
		testing.expectf(t, drawn(cmds, "● npm test") == (folded ? 0 : 1), "folded=%v: the shells panel's row", folded)
	}
	clear(&state.layout.collapsed)
	_ = ui_layout(1400, 860)
	for i in u32(0) ..< 2 {
		d := clay.GetElementData(clay.ID("panelhead", i))
		if !testing.expectf(t, d.found, "panel %d's header laid out", i) do continue
		b := d.boundingBox
		clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
		h := ui_hit()
		if i == 0 do testing.expectf(t, h == nil, "a head-only header is not a toggle: %v", h)
		else do testing.expectf(t, h == Hit(Hit_Panel_Head("shells")), "the shells header folds: %v", h)
	}
}

// The New chat buttons (top bar, the empty centre) open the harness picker under the button, not
// mid-window (harness.odin).
@(test)
new_chat_button_picker_at_button :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !bt_ui() {
		testing.fail_now(t, "no fonts")
	}
	pi_installed_probe = proc() -> bool {return true}
	claude_installed_probe = proc() -> bool {return true}
	defer {
		pi_installed_probe = nil
		claude_installed_probe = nil
		if menu.open do menu_close()
	}
	// Chats needs a data dir; an empty pi store under a temp HOME (as buttons_reachable_in_layout)
	dir := fmt.tprintf("%s/pd-bt-nchat-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(dir)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("HOME", fmt.tprintf("%s/home", dir))
	defer os.set_env("HOME", old_home)
	old_root := home_root
	home_root = fmt.tprintf("%s/data", dir)
	defer home_root = old_root
	rescan_now()
	testing.expect(t, chats_project() != nil, "a Chats project")
	for b in ([]Button{.New_Chat, .Empty_New_Chat}) {
		_ = ui_layout(1400, 860)
		d := clay.GetElementData(clay.ID(BUTTONS[b].element))
		if !d.found do continue // the empty centre's button: only with no session open
		button_click(b)
		testing.expectf(t, menu.open, "%v: the picker opens", b)
		_, is_ns := menu.target.(Menu_New_Session)
		testing.expectf(t, is_ns, "%v: the harness picker", b)
		bb := d.boundingBox
		testing.expectf(t, abs(menu.at.x - bb.x) < 1 && menu.at.y >= bb.y + bb.height && menu.at.y < bb.y + bb.height + px(SP_4), "%v: at the button %v, not %v", b, bb, menu.at)
		if menu.open do menu_close()
	}
}

// A command's long absolute path breaks after a "/" inside the setup card instead of widening it
// past the sheet (its button off screen); the words that fit are left alone.
@(test)
harness_command_breaks_long_paths :: proc(t: ^testing.T) {
	context.allocator = bt_reset()
	if !testing.expect(t, bt_ui(), "fonts") do return
	cmd := "$ /Users/someone/workspace/projects/deckhand-harness-setup/build/harness-setup/home-old/.pi/agent/bin/pi update --self"
	room := text_width("$ /Users/someone/workspace/projects/", .Mono)
	shown := break_long_words(cmd, room, .Mono)
	joined, _ := strings.replace_all(shown, "\n", "", context.temp_allocator)
	testing.expect_value(t, joined, cmd)
	for line in strings.split(shown, "\n", context.temp_allocator) {
		for word in strings.fields(line, context.temp_allocator) do testing.expectf(t, text_width(word, .Mono) <= room, "%q fits", word)
	}
	testing.expect(t, strings.contains(shown, "/\n"), "breaks after a slash")
	testing.expect_value(t, break_long_words("$ npm update", room, .Mono), "$ npm update")
	long := strings.repeat("x", 200, context.temp_allocator)
	testing.expect_value(t, strings.count(break_long_words(long, room, .Mono), "\n") > 0, true)
}
