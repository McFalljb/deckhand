package main

// The Attention view (ui_sidebar.odin attention_list, core/needing_you.odin attention_rows): the
// order (tiers, the longest first, the same as ⌥⌘A's), the groups and counts drawn, the machine
// column only with other machines, the filter and quick filters, a row's click and the keyboard,
// another machine's title drawn cleaned, the mode's command (its authority, the wire, saved and
// restored), the action and its key, and the layout at the narrowest column.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
AV_UI :: core.Caller{kind = .UI}

@(private = "file")
av_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	p := core.Project{id = 1, group = .Projects, cwd = strings.clone("/tmp/av-proj"), label = strings.clone("web")}
	append(&state.projects, p)
	state.selected_project = p.id
	ui_hover = nil
	attention_idle_open, attention_sel = false, 0
	state.settings.reduce_motion = true
	toast_clear()
}

// A shell tab: "" idle, "waiting", "error", "unseen", "working"; its status for `ago` ({}: not known).
@(private = "file")
av_tab :: proc(id: u64, need := "", ago: time.Duration = 0) -> core.Tab {
	t := core.Tab{id = id, kind = core.Shell_Tab{}, title = strings.clone(fmt.tprintf("tab %d", id), runtime.heap_allocator()), status = .Running}
	t.prog.progress = -1
	switch need {
	case "waiting": t.prog.state, t.prog.kind = .Blocked, .Permission
	case "error":   t.prog.state = .Error
	case "unseen":  t.unseen = true
	case "working": t.prog.state = .Working
	case "question": t.kind, t.agent, t.question = core.Pi_Tab{}, .Idle, true
	}
	t.status_key = core.status_key(core.tab_status_view(t))
	if ago > 0 do t.status_since = time.time_add(time.now(), -ago)
	return t
}

@(private = "file")
av_session :: proc(id: u64, title: string, tabs: ..core.Tab) {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("s%d", id)), cwd = strings.clone("/tmp/av-proj"), title = strings.clone(title), shown_at = i64(id)}
	for t in tabs do append(&s.tabs, t)
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	append(&state.sessions, core.Session{id = s.pi_session_id, path = strings.clone(fmt.tprintf("/tmp/av-proj/%d.jsonl", id)), title = s.title})
}

@(private = "file")
av_ids :: proc() -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	for r in core.attention_rows() do append(&out, r.session.id)
	return out[:]
}

@(private = "file")
av_same :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

// The texts drawn, one per line (inside a box, or all when {}).
@(private = "file")
av_texts :: proc(cmds: clay.ClayArray(clay.RenderCommand), within: clay.BoundingBox = {}) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		x := c.boundingBox
		if within != {} && !(x.x >= within.x - 0.5 && x.y >= within.y - 0.5 && x.x + x.width <= within.x + within.width + 0.5 && x.y + x.height <= within.y + within.height + 0.5) do continue
		tx := c.renderData.text
		strings.write_string(&b, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
av_box :: proc(name: string, i: u32 = 0) -> (clay.BoundingBox, bool) {
	d := clay.GetElementData(clay.ID(name, i))
	return d.boundingBox, d.found
}

// The open rows drawn, top to bottom (their session ids).
@(private = "file")
av_drawn :: proc() -> []u64 {return drawn.open[:]}

// Tiers first; within one, the longest in it first (a known start before an unknown one, ties in
// machine and opening order); the first row is where ⌥⌘A goes; the groups.
@(test)
attention_order_longest_first :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	av_reset()
	defer av_reset()
	av_session(100, "Idle one", av_tab(101))
	av_session(200, "Schema", av_tab(201, "waiting", 3 * time.Minute))
	av_session(300, "Login page", av_tab(301, "waiting", 9 * time.Minute))
	av_session(400, "Crash", av_tab(401, "error", 20 * time.Minute)) // longer, but errors after waiting
	av_session(500, "Bump deps", av_tab(501, "unseen", time.Minute))
	av_session(600, "Relay", av_tab(601, "working", 12 * time.Minute))
	av_session(700, "Unknown start", av_tab(701, "waiting")) // no start known: after the known ones
	av_session(800, "Two tabs", av_tab(801, "waiting", time.Minute), av_tab(802, "waiting", 30 * time.Minute)) // its longest tab counts
	want := []u64{800, 300, 200, 700, 400, 500, 600, 100}
	testing.expectf(t, av_same(av_ids(), want), "order: %v", av_ids())
	groups := []core.Attention_Group{.Needs_You, .Needs_You, .Needs_You, .Needs_You, .Needs_You, .Finished, .Working, .Idle}
	for r, i in core.attention_rows() do testing.expectf(t, r.group == groups[i], "row %d (%d): %v", i, r.session.id, r.group)
	// ⌥⌘A's order is the same list (needing_you), so its first stop is the top row
	needing := make([dynamic]u64, context.temp_allocator)
	for x in core.needing_you() do append(&needing, x.session.id)
	testing.expectf(t, av_same(needing[:], want[:6]), "needing_you: %v", needing)
	s, tab := core.next_needing_target()
	testing.expect(t, s != nil && s.id == 800, "⌥⌘A goes to the top row")
	testing.expect(t, tab != nil && tab.id == 801 || tab != nil && tab.id == 802, "to a waiting tab")
	// a visit moves nothing: from the top row, ⌥⌘A walks on down the list
	state.current_session = 800
	s, _ = core.next_needing_target()
	testing.expect(t, s != nil && s.id == 300, "then the next row")
	state.current_session = 0
	// the counts agree with the fleet's (no filter)
	f := core.fleet_tally()
	counts: [core.Attention_Group]int
	for r in core.attention_rows() do counts[r.group] += 1
	testing.expect_value(t, counts[.Needs_You], core.fleet_need(f))
	testing.expect_value(t, counts[.Finished], f.unseen)
	testing.expect_value(t, counts[.Working], f.working)
}

// The list as drawn: headers with counts in order, IDLE folded, no tree, the footer, rows that are
// the Open group's (a waiting row's message and age), the current session selected; a click goes
// where ⌥⌘A would; IDLE opens; the switch flips back.
@(test)
attention_list_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	av_reset()
	defer av_reset()
	av_session(100, "Quiet one", av_tab(101))
	av_session(200, "Schema", av_tab(201), av_tab(202, "waiting", 9 * time.Minute))
	av_session(300, "Login page", av_tab(301, "waiting", 3 * time.Minute))
	av_session(400, "Bump deps", av_tab(401, "unseen", time.Minute))
	av_session(500, "Relay", av_tab(501, "working", 12 * time.Minute))
	core.find_session(300).tabs[0].prog.msg = strings.clone("Apply these edits?", runtime.heap_allocator())
	state.current_session = 500
	state.layout.left_width = 420
	testing.expect(t, core.run_command(core.Set_Sidebar_View{view = .Attention}, AV_UI).ok, "set_sidebar_view")
	cmds := ui_layout(1600, 900)
	nav, ok := av_box("nav")
	testing.expect(t, ok, "the list")
	text := av_texts(cmds, nav)
	at :: proc(text, s: string) -> int {return strings.index(text, s)}
	testing.expectf(t, at(text, "NEEDS YOU\n2\n") >= 0 && at(text, "FINISHED\n1\n") > at(text, "NEEDS YOU") && at(text, "WORKING\n1\n") > at(text, "FINISHED") && at(text, "IDLE\n1\n") > at(text, "WORKING"), "headers: %q", text)
	testing.expectf(t, !strings.contains(text, "Quiet one"), "IDLE folded: %q", text)
	for no in ([]string{"PROJECTS", "CHATS", "OPEN", "Add a machine"}) do testing.expectf(t, !strings.contains(text, no), "no %s: %q", no, text)
	testing.expectf(t, strings.contains(av_texts(cmds), "This Mac · By project\n"), "footer: %q", av_texts(cmds))
	testing.expectf(t, av_same(av_drawn(), []u64{200, 300, 400, 500}), "rows: %v", av_drawn())
	// the waiting row: its place, title, age and what it asks
	r1, _ := av_box("open", 1)
	rt := av_texts(cmds, r1)
	testing.expectf(t, strings.contains(rt, "av-proj ·\nLogin page\n3m · Apply these edits?\n"), "row 1: %q", rt)
	testing.expectf(t, !strings.contains(rt, "this Mac"), "one machine: no machine column: %q", rt)
	// the current session (Relay) is selected: its row's background differs from an idle row's
	testing.expect(t, clay.GetElementData(clay.ID("open", 3)).found, "Relay's row")
	// the switch shows both segments
	sw, _ := av_box("viewswitch")
	testing.expectf(t, av_texts(cmds, sw) == "By project\nAttention\n", "switch: %q", av_texts(cmds, sw))

	// a click on the top row: that session, on its waiting tab (as ⌥⌘A), not its first
	d := clay.GetElementData(clay.ID("open", 0))
	clay.SetPointerState({d.boundingBox.x + 20, d.boundingBox.y + d.boundingBox.height / 2}, false)
	h := ui_hit()
	testing.expectf(t, h == Hit(Hit_Open_Row(200)), "hit %v", h)
	sidebar_click(h, {})
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(200))
	testing.expect_value(t, core.session_focused_id(core.find_session(200)), u64(202))

	// IDLE opens; its row last
	sidebar_click(Hit_Attention(ATTN_HIT_IDLE), {})
	cmds = ui_layout(1600, 900)
	testing.expectf(t, av_same(av_drawn(), []u64{200, 300, 400, 500, 100}), "with idle: %v", av_drawn())
	// the footer flips back to the tree
	h = nil
	if d = clay.GetElementData(clay.ID("attnfoot")); d.found {
		clay.SetPointerState({d.boundingBox.x + 10, d.boundingBox.y + 5}, false)
		h = ui_hit()
	}
	testing.expectf(t, h == Hit(Hit_Attention(ATTN_HIT_FOOTER)), "footer hit %v", h)
	sidebar_click(h, {})
	core.inbox_drain()
	testing.expect_value(t, state.sidebar.view, core.Sidebar_View.Projects)
	cmds = ui_layout(1600, 900)
	testing.expectf(t, strings.contains(av_texts(cmds), "PROJECTS\n"), "the tree again: %q", av_texts(cmds))
	_, ok = av_box("attnfoot")
	testing.expect(t, !ok, "no footer in the tree")
	// the switch's Attention segment
	if d = clay.GetElementData(clay.ID("viewseg", 1)); d.found {
		clay.SetPointerState({d.boundingBox.x + 5, d.boundingBox.y + 5}, false)
		h = ui_hit()
	}
	testing.expectf(t, h == Hit(Hit_Attention(core.Sidebar_View.Attention)), "segment hit %v", h)
	label, keys := hit_tip(h)
	testing.expectf(t, label != "" && keys == "⌥⌘.", "segment tip: %q %q", label, keys)
}

// The filter and the quick filters work on the list (waiting work always shows); ↑↓ in the filter
// move the keyboard's row and Enter opens it; nothing open: what to do.
@(test)
attention_filter_and_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	av_reset()
	defer av_reset()
	state.sidebar.view = .Attention
	// nothing open
	cmds := ui_layout(1600, 900)
	nav, _ := av_box("nav")
	testing.expectf(t, strings.contains(av_texts(cmds, nav), "Nothing running."), "empty: %q", av_texts(cmds, nav))
	_, ok := av_box("addproject")
	testing.expect(t, ok, "Add project…")

	av_session(100, "Quiet one", av_tab(101))
	av_session(200, "Schema", av_tab(201, "waiting", 9 * time.Minute))
	av_session(300, "Relay", av_tab(301, "working", 2 * time.Minute))
	av_session(400, "Docs build", av_tab(401, "working", time.Minute))
	core.run_command(core.Set_Filter{text = "relay"}, AV_UI)
	testing.expectf(t, av_same(av_ids(), []u64{200, 300}), "filter: %v (waiting work stays)", av_ids())
	core.run_command(core.Set_Filter{text = ""}, AV_UI)
	core.run_command(core.Set_Filter{running = true}, AV_UI)
	testing.expectf(t, av_same(av_ids(), []u64{200, 300, 400}), "running: %v", av_ids())
	core.run_command(core.Set_Filter{running = false, waiting = true}, AV_UI)
	testing.expectf(t, av_same(av_ids(), []u64{200}), "waiting: %v", av_ids())
	core.run_command(core.Set_Filter{waiting = false, text = "quiet"}, AV_UI)
	testing.expectf(t, av_same(av_ids(), []u64{200, 100}), "an idle match: %v", av_ids())
	cmds = ui_layout(1600, 900)
	testing.expectf(t, av_same(av_drawn(), []u64{200, 100}), "filtering shows IDLE's matches: %v", av_drawn())
	core.run_command(core.Set_Filter{text = ""}, AV_UI)

	// the keyboard: ↓ from the filter field picks the first row, ↓ the next, ↑ wraps; Enter opens
	filter_focus()
	core.inbox_drain()
	defer tf_set(&filter_field, "")
	ev := sapp.Event{type = .KEY_DOWN, key_code = .DOWN}
	widget_event(&ev)
	testing.expect_value(t, attention_sel, u64(200))
	widget_event(&ev)
	testing.expect_value(t, attention_sel, u64(300))
	ev.key_code = .UP
	widget_event(&ev)
	widget_event(&ev)
	testing.expect_value(t, attention_sel, u64(400)) // IDLE folded: wraps to WORKING's last
	cmds = ui_layout(1600, 900)
	r2, _ := av_box("open", 2)
	testing.expect(t, clay.GetElementData(clay.ID("open", 2)).found && r2.height > 0, "the keyboard's row drawn")
	// ⌥⌘. passes the field on to the menu bar (the field keeps ⌘. and the rest)
	ev = {type = .KEY_DOWN, key_code = .PERIOD, modifiers = u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)}
	testing.expect(t, !widget_event(&ev), "⌥⌘. passes the filter field")
	ev = {type = .KEY_DOWN, key_code = .ENTER}
	widget_event(&ev)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(400))
	testing.expect_value(t, state.focus_widget, "")
}

// Other machines: a machine column (this Mac and theirs), another machine's title drawn as the
// mirror cleaned it, an offline machine's sessions idle and greyed; the narrowest column passes
// the layout audit.
@(test)
attention_machines_and_narrow :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	av_reset()
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	state.machines[1] = {no = 4, name = "studio-with-a-long-name", status = .Offline}
	av_session(100, "Login page", av_tab(101, "working", 4 * time.Minute))
	mirror :: proc(no: u64, title, need: string, r: ^core.State, m: ^core.Machine_Mirror) {
		s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/api"), title = strings.clone(title)}
		tb := av_tab(10, need)
		append(&s.tabs, tb)
		s.active_tab = 10
		append(&r.open_sessions, s)
		core.mirror_merge(no, r, m)
	}
	r3, r4: core.State
	m3, m4: core.Machine_Mirror
	mirror(3, "Sch\x1b]0;owned\x07ema‮\nindex", "waiting", &r3, &m3)
	mirror(4, "Old one", "", &r4, &m4)
	defer {
		core.mirror_unmerge(3)
		core.mirror_unmerge(4)
		core.mirror_free(&m3)
		core.mirror_free(&m4)
		core.replica_free(&r3, runtime.heap_allocator())
		core.replica_free(&r4, runtime.heap_allocator())
		av_reset()
	}
	state.sidebar.view = .Attention
	attention_idle_open = true
	state.layout.left_width = 420
	cmds := ui_layout(1600, 900)
	testing.expect_value(t, len(av_drawn()), 3)
	if len(av_drawn()) == 3 {
		nuc := core.find_session(av_drawn()[0])
		testing.expect(t, nuc != nil && nuc.machine == 3, "nuc's waiting session first")
		r0, _ := av_box("open", 0)
		rt := av_texts(cmds, r0)
		testing.expectf(t, strings.contains(rt, "\nnuc\n"), "nuc's machine column: %q", rt)
		testing.expectf(t, !strings.contains(rt, "\x1b") && !strings.contains(rt, "\x07") && !strings.contains(rt, "‮") && strings.contains(rt, "Sch"), "cleaned title: %q", rt)
		r1, _ := av_box("open", 1)
		testing.expectf(t, strings.contains(av_texts(cmds, r1), "\nthis Mac\n"), "this Mac's: %q", av_texts(cmds, r1))
		off := core.find_session(av_drawn()[2])
		testing.expect(t, off != nil && off.machine == 4, "the offline machine's session idle, last")
	}
	testing.expectf(t, strings.contains(av_texts(cmds), "3 machines · By project\n"), "footer: %q", av_texts(cmds))
	// another machine's row (as its Open row): only Peek and Mark as unread or read, there (#114),
	// while it is online; an offline machine's: none
	if testing.expect(t, sidebar_context(Hit_Open_Row(av_drawn()[0]), {}), "an online machine's row: its menu") {
		for it in menu_items() do testing.expectf(t, it.label == "Peek" || strings.has_prefix(it.label, "Mark as "), "only what acts there: %q", it.label)
		menu_close()
	}
	if len(av_drawn()) == 3 do testing.expect(t, !sidebar_context(Hit_Open_Row(av_drawn()[2]), {}), "an offline machine's row: no menu")

	// the narrowest column, every window width, rows and IDLE hovered: nothing overlaps or spills
	problems := 0
	for lw in ([]f32{core.LEFT_MIN, 260}) {
		state.layout.left_width = lw
		for w in AUDIT_WIDTHS {
			for hv in ([]Hit{nil, Hit_Open_Row(100), Hit_Attention(ATTN_HIT_IDLE), Hit_Attention(0)}) {
				ui_hover = hv
				cmds = ui_layout(w, AUDIT_H)
				for b in audit(cmds, fmt.tprintf("attention left=%v w=%v hover %v", lw, w, hv), w) {
					problems += 1
					if problems <= 40 do testing.expectf(t, false, "%s", b)
				}
			}
		}
	}
	ui_hover = nil
	// nothing open at the narrowest: the empty state's buttons stack and fit
	core.mirror_unmerge(3)
	core.mirror_unmerge(4)
	clear(&state.open_sessions)
	state.layout.left_width = core.LEFT_MIN
	cmds = ui_layout(WINDOW_MIN_W, AUDIT_H)
	for b in audit(cmds, "attention empty narrow", WINDOW_MIN_W) do testing.expectf(t, false, "%s", b)
}

// The command: the user's at this Mac only (never a control caller, a script or a hub), on the
// wire to the window, saved and restored; the action (View menu, palette, ⌥⌘.) shows the Sessions
// tab and toggles.
@(test)
attention_mode_command_saved_and_key :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	av_reset()
	defer av_reset()
	testing.expect(t, core.caller_may(AV_UI, core.Set_Sidebar_View{view = .Attention}), "the user")
	testing.expect(t, !core.caller_may({kind = .Control}, core.Set_Sidebar_View{view = .Attention}), "not a control caller")
	testing.expect(t, !core.caller_may({kind = .Script}, core.Set_Sidebar_View{view = .Attention}), "not a script")
	cmd, err := core.parse_command(`{"type":"set_sidebar_view","view":"attention"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, cmd.(core.Set_Sidebar_View).view, core.Sidebar_View.Attention)
	testing.expect(t, core.run_command(cmd, AV_UI).ok, "runs")
	testing.expect_value(t, state.sidebar.view, core.Sidebar_View.Attention)
	// the window's replica gets it
	r: core.State
	testing.expect_value(t, core.replica_apply(&r, core.state_full_json(state)), "")
	testing.expect_value(t, r.sidebar.view, core.Sidebar_View.Attention)
	core.replica_free(&r, runtime.heap_allocator())
	// saved and restored (only when not the default)
	text := strings.clone(core.workspace_json(), context.temp_allocator)
	testing.expectf(t, strings.contains(text, `"view":"attention"`), "saved: %q", text)
	core.run_command(core.Set_Sidebar_View{view = .Projects}, AV_UI)
	testing.expect_value(t, core.workspace_restore(text), "")
	testing.expect_value(t, state.sidebar.view, core.Sidebar_View.Attention)
	core.run_command(core.Set_Sidebar_View{view = .Projects}, AV_UI)
	testing.expect(t, !strings.contains(core.workspace_json(), `"view"`), "the default is not saved")

	// the action: ⌥⌘. in the View menu; from the Files tab it shows Sessions in the Attention view
	testing.expect_value(t, menubar_key_action(.PERIOD, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)), "attention_view")
	it := menubar_find("attention_view")
	testing.expect(t, it != nil && menubar_keys(it) == "⌥⌘.", "View › Attention view ⌥⌘.")
	state.layout.left_tab = .Files
	action_run("attention_view")
	core.inbox_drain()
	testing.expect_value(t, state.layout.left_tab, core.Left_Tab.Sessions)
	testing.expect_value(t, state.sidebar.view, core.Sidebar_View.Attention)
	action_run("attention_view")
	core.inbox_drain()
	testing.expect_value(t, state.sidebar.view, core.Sidebar_View.Projects)
	found := false
	for a in ACTIONS do if a.id == "attention_view" && a.label == "Toggle Attention view" && !a.no_palette do found = true
	testing.expect(t, found, "the palette's Toggle Attention view")
}

// The status marks drawn inside a box.
@(private = "file")
av_marks :: proc(cmds: clay.ClayArray(clay.RenderCommand), within: clay.BoundingBox) -> []core.Icon {
	out := make([dynamic]core.Icon, context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Custom do continue
		ic, _, _ := icon_of_command(c)
		if ic < .Mark_Idle || ic > .Mark_Error do continue
		x := c.boundingBox
		if x.x >= within.x - 0.5 && x.y >= within.y - 0.5 && x.x + x.width <= within.x + within.width + 0.5 && x.y + x.height <= within.y + within.height + 0.5 do append(&out, ic)
	}
	return out[:]
}

// Review fixes: a question needs you as a waiting tab does (the filter and the Waiting chip keep
// it, as the pill counts it); a row draws the tab that put it in its group (its mark, its age);
// the keyboard's row scrolls into view; Enter with no rows opens nothing.
@(test)
attention_review_fixes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	av_reset()
	defer {
		tf_set(&filter_field, "")
		av_reset()
	}
	state.sidebar.view = .Attention
	// 1. a question-only session survives a filter that does not match it, and the Waiting chip
	av_session(100, "Asks a thing", av_tab(101, "question", 2 * time.Minute))
	av_session(200, "Other", av_tab(201, "working", time.Minute))
	core.run_command(core.Set_Filter{text = "other"}, AV_UI)
	testing.expectf(t, av_same(av_ids(), []u64{100, 200}), "a question stays through the filter: %v", av_ids())
	core.run_command(core.Set_Filter{text = "", waiting = true}, AV_UI)
	testing.expectf(t, av_same(av_ids(), []u64{100}), "the Waiting chip keeps a question: %v", av_ids())
	core.run_command(core.Set_Filter{waiting = false}, AV_UI)

	// 2. a question and an unseen tab: under NEEDS YOU with the question's mark, not ✓; two
	// waiting tabs (1m focused, 30m): the row says 30m, as it sorted
	clear(&state.open_sessions)
	av_session(300, "Mixed", av_tab(301, "unseen", time.Minute), av_tab(302, "question", 5 * time.Minute))
	av_session(400, "Two waits", av_tab(401, "waiting", time.Minute), av_tab(402, "waiting", 30 * time.Minute))
	state.layout.left_width = 420
	cmds := ui_layout(1600, 900)
	for sid, k in drawn.open {
		b, _ := av_box("open", u32(k))
		if sid == 300 do testing.expectf(t, len(av_marks(cmds, b)) == 1 && av_marks(cmds, b)[0] == .Mark_Question, "Mixed's mark: %v", av_marks(cmds, b))
		if sid == 400 do testing.expectf(t, strings.contains(av_texts(cmds, b), "30m"), "Two waits' age: %q", av_texts(cmds, b))
	}

	// 3. many rows in a short window: ↓ to the last one scrolls it into the list's view
	clear(&state.open_sessions)
	for i in u64(0) ..< 40 do av_session(1000 + i * 10, fmt.tprintf("Job %d", i), av_tab(1001 + i * 10, "working", time.Duration(40 - i) * time.Minute))
	filter_focus()
	core.inbox_drain()
	ev := sapp.Event{type = .KEY_DOWN, key_code = .DOWN}
	for _ in 0 ..< 40 {
		cmds = ui_layout(1200, 500)
		widget_event(&ev)
	}
	for _ in 0 ..< 3 do cmds = ui_layout(1200, 500)
	nav, _ := av_box("nav")
	k := -1
	for sid, i in drawn.open do if sid == attention_sel do k = i
	testing.expect(t, k >= 0, "the keyboard's row is drawn")
	if k >= 0 {
		r, _ := av_box("open", u32(k))
		testing.expectf(t, r.y >= nav.y - 0.5 && r.y + r.height <= nav.y + nav.height + 0.5, "the keyboard's row in view: row %v, list %v", r, nav)
	}

	// 4. no row matches: Enter opens nothing (not a closed session from the hidden history)
	core.run_command(core.Set_Filter{text = "zebra"}, AV_UI)
	append(&state.sessions, core.Session{id = strings.clone("zz"), path = strings.clone("/tmp/av-proj/zz.jsonl"), title = strings.clone("zebra crossing")})
	n := len(state.open_sessions)
	ev = {type = .KEY_DOWN, key_code = .ENTER}
	widget_event(&ev)
	core.inbox_drain()
	testing.expect_value(t, len(state.open_sessions), n)
}
