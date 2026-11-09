package main

// Dragging a tab (panes_drag.odin; docs/plans/split-panes.md P5): where a drop lands, worked out
// from rects alone (the zones of a pane's body, a strip's gaps, the pi tab's place, the limits),
// the command each drop runs, what its indicator covers; then the drag itself on a laid-out
// window: a press that moves less than the threshold is a click, a reorder in the title bar, the
// first split by an edge, a move between strips, the pi tab moved, Esc.

import "base:runtime"
import "core:testing"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

// Two panes side by side, 400 px each and a divider: strips 30 px high, A holds the pi tab and
// s1, B s2 and s3 (100 px tabs). Ids: pi 1, s1 2, s2 3, s3 4; panes A 10, B 20.
@(private = "file")
dh_input :: proc(tab, from: u64) -> Tab_Drop_Input {
	a_tabs := make([]Drop_Tab, 2, context.temp_allocator)
	a_tabs[0], a_tabs[1] = {1, {0, 0, 100, 30}}, {2, {100, 0, 100, 30}}
	b_tabs := make([]Drop_Tab, 2, context.temp_allocator)
	b_tabs[0], b_tabs[1] = {3, {401, 0, 100, 30}}, {4, {501, 0, 100, 30}}
	panes := make([]Drop_Pane, 2, context.temp_allocator)
	all := [core.Pane_Dir]bool{.Left = true, .Right = true, .Up = true, .Down = true}
	panes[0] = {id = 10, zone = {0, 30, 400, 570}, strip = {0, 0, 400, 30}, tabs = a_tabs, room = all}
	panes[1] = {id = 20, zone = {401, 30, 399, 570}, strip = {401, 0, 399, 30}, tabs = b_tabs, room = all}
	return {panes = panes, tab = tab, from = from, from_count = 2, main = 1, edge_min = 40, edge_max = 120, mark_w = 2}
}

@(test)
tab_drop_zones :: proc(t: ^testing.T) {
	r := [4]f32{0, 0, 400, 300} // edge zones: 100 px across (a quarter), 75 px down
	check :: proc(t: ^testing.T, r: [4]f32, x, y: f32, want: core.Pane_Dir, want_edge: bool, loc := #caller_location) {
		dir, edge, ok := drop_zone_at(r, x, y, 40, 120)
		testing.expect(t, ok, "inside", loc = loc)
		testing.expect_value(t, edge, want_edge, loc = loc)
		if want_edge do testing.expect_value(t, dir, want, loc = loc)
	}
	check(t, r, 10, 150, .Left, true)
	check(t, r, 99, 150, .Left, true)
	check(t, r, 395, 150, .Right, true)
	check(t, r, 200, 5, .Up, true)
	check(t, r, 200, 295, .Down, true)
	check(t, r, 200, 150, .Left, false) // the centre
	check(t, r, 101, 150, .Left, false)
	check(t, r, 10, 20, .Left, true) // a corner: the nearer edge for its zone's size (10/100 < 20/75)
	check(t, r, 60, 5, .Up, true) // 60/100 > 5/75
	_, _, ok := drop_zone_at(r, 400, 10, 40, 120)
	testing.expect(t, !ok, "right of it: outside")
	// sizes clamp: 40 px at least (a third of a small pane at most), 120 px at most
	_, edge, _ := drop_zone_at({0, 0, 2000, 1000}, 130, 500, 40, 120)
	testing.expect(t, !edge, "a wide pane's edge zone stops at 120 px")
	dir, edge2, _ := drop_zone_at({0, 0, 120, 120}, 39, 60, 40, 120)
	testing.expect(t, edge2 && dir == .Left, "40 px at least…")
	_, edge3, _ := drop_zone_at({0, 0, 90, 90}, 31, 45, 40, 120)
	testing.expect(t, !edge3, "…but never past a third of the pane")
}

// Strips: the mark between tabs, its own place a no-op, never before the pi tab, the pi tab
// always first; every drop's command.
@(test)
tab_drop_strips :: proc(t: ^testing.T) {
	// s3 (B's second) to the front of B: before s2
	d := tab_drop_at(dh_input(4, 20), 410, 15)
	testing.expect(t, d.kind == .Strip && d.pane == 20 && d.gap == 0 && d.index == 0 && !d.noop, "s3 first in B")
	cmd, ok := tab_drop_command(d, 4)
	testing.expect(t, ok && cmd.(core.Move_Tab) == core.Move_Tab{tab_id = 4, pane = 20, index = 0}, "move_tab B 0")
	// s2 (B's first) to B's end: after s3, index counted without s2
	d = tab_drop_at(dh_input(3, 20), 700, 15)
	testing.expect(t, d.kind == .Strip && d.gap == 2 && d.index == 1 && !d.noop, "s2 last in B")
	// s2 just right of itself (left half of s3): its own place
	d = tab_drop_at(dh_input(3, 20), 540, 15)
	testing.expect(t, d.gap == 1 && d.noop, "its own place")
	_, ok = tab_drop_command(d, 3)
	testing.expect(t, !ok, "no command for its own place")
	// s1 dropped before the pi tab in its own strip: lands after it, its own place
	d = tab_drop_at(dh_input(2, 10), 10, 15)
	testing.expect(t, d.gap == 1 && d.index == 1 && d.noop, "never before the pi tab")
	// s2 into A's strip before the pi tab: after it
	d = tab_drop_at(dh_input(3, 20), 10, 15)
	testing.expect(t, d.kind == .Strip && d.pane == 10 && d.gap == 1 && d.index == 1 && !d.noop, "after the pi tab in A")
	// the pi tab into B's strip anywhere: first there
	d = tab_drop_at(dh_input(1, 10), 700, 15)
	testing.expect(t, d.kind == .Strip && d.pane == 20 && d.gap == 0 && d.index == 0 && !d.noop, "the pi tab first in B")
	cmd, ok = tab_drop_command(d, 1)
	testing.expect(t, ok && cmd.(core.Move_Tab).pane == 20, "the pi tab moves")
	// the pi tab in its own strip: it cannot leave index 0
	d = tab_drop_at(dh_input(1, 10), 190, 15)
	testing.expect(t, d.noop && d.gap == 0, "the pi tab stays first")
	// nowhere: right of the window's panes, or in the gap no strip covers
	d = tab_drop_at(dh_input(3, 20), 900, 15)
	testing.expect_value(t, d.kind, Tab_Drop_Kind.None)
	_, ok = tab_drop_command(d, 3)
	testing.expect(t, !ok, "nothing runs")
}

// Bodies: the centre moves the tab into that pane (its own: nothing), an edge splits that pane
// with it (its pane's only tab beside itself: nothing); PANES_MAX and a pane too small are refused.
@(test)
tab_drop_bodies :: proc(t: ^testing.T) {
	d := tab_drop_at(dh_input(3, 20), 200, 300) // s2 to A's centre
	testing.expect(t, d.kind == .Centre && d.pane == 10 && !d.noop, "A's centre")
	cmd, ok := tab_drop_command(d, 3)
	testing.expect(t, ok && cmd.(core.Move_Tab) == core.Move_Tab{tab_id = 3, pane = 10, index = -1}, "move_tab to A's end")
	d = tab_drop_at(dh_input(3, 20), 600, 300) // its own pane's centre
	testing.expect(t, d.kind == .Centre && d.noop, "its own centre")
	_, ok = tab_drop_command(d, 3)
	testing.expect(t, !ok, "no command")
	// each edge of A: split_pane with the tab
	for c in ([]struct {
			x, y: f32,
			dir:  core.Pane_Dir,
		}{{10, 300, .Left}, {390, 300, .Right}, {200, 40, .Up}, {200, 590, .Down}}) {
		d = tab_drop_at(dh_input(3, 20), c.x, c.y)
		testing.expectf(t, d.kind == .Edge && d.pane == 10 && d.dir == c.dir && !d.noop && d.refused == "", "A's %v edge: %v", c.dir, d)
		cmd, ok = tab_drop_command(d, 3)
		testing.expect(t, ok && cmd.(core.Split_Pane) == core.Split_Pane{pane = 10, direction = c.dir, tab_id = 3}, "split_pane with the tab")
	}
	// its own pane's edge: a split of its own pane with it (it has another tab)…
	d = tab_drop_at(dh_input(3, 20), 790, 300)
	testing.expect(t, d.kind == .Edge && d.pane == 20 && d.dir == .Right && !d.noop, "own pane, two tabs: splits")
	// … unless it is that pane's only tab
	in1 := dh_input(3, 20)
	in1.from_count = 1
	d = tab_drop_at(in1, 790, 300)
	testing.expect(t, d.kind == .Edge && d.noop, "its only tab beside itself: nothing")
	_, ok = tab_drop_command(d, 3)
	testing.expect(t, !ok, "no command")
	// the pi tab may split another pane
	d = tab_drop_at(dh_input(1, 10), 410, 300)
	cmd, ok = tab_drop_command(d, 1)
	testing.expect(t, ok && cmd.(core.Split_Pane) == core.Split_Pane{pane = 20, direction = .Left, tab_id = 1}, "the pi tab splits B")
	// limits: refused with why, no command
	full := dh_input(3, 20)
	full.at_max = true
	d = tab_drop_at(full, 10, 300)
	testing.expect_value(t, d.refused, "at most 8 panes")
	_, ok = tab_drop_command(d, 3)
	testing.expect(t, !ok, "refused: no command")
	tight := dh_input(3, 20)
	tight.panes[0].room[.Left] = false
	d = tab_drop_at(tight, 10, 300)
	testing.expect_value(t, d.refused, "not enough room")
	d = tab_drop_at(tight, 390, 300)
	testing.expect_value(t, d.refused, "") // room the other way
	// a centre drop is never refused (no new pane), even at the limit
	d = tab_drop_at(full, 200, 300)
	testing.expect(t, d.kind == .Centre && d.refused == "", "a move at the limit")
}

// What the indicator covers: the half an edge's new pane takes, the whole pane for its centre,
// a thin mark in a strip's gap; nothing for a no-op body drop.
@(test)
tab_drop_previews :: proc(t: ^testing.T) {
	input := dh_input(3, 20)
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 390, 300)), [4]f32{200, 30, 200, 570})
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 200, 40)), [4]f32{0, 30, 400, 285})
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 200, 590)), [4]f32{0, 315, 400, 285})
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 10, 300)), [4]f32{0, 30, 200, 570})
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 200, 300)), [4]f32{0, 30, 400, 570})
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 600, 300)), [4]f32{}) // its own centre
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 410, 15)), [4]f32{398, 0, 2, 30}) // before s2
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 540, 15)), [4]f32{500, 0, 2, 30}) // between s2 and s3
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 700, 15)), [4]f32{602, 0, 2, 30}) // after s3
	testing.expect_value(t, tab_drop_preview(input, tab_drop_at(input, 900, 15)), [4]f32{})
}

// The drag on a laid-out window (one pane, then two): the threshold, a reorder in the title bar,
// the first split by an edge drop, a move to the other pane's strip, the pi tab to another pane
// (still tabs[0]), Esc cancels.
@(test)
tab_drag_on_the_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	defer tab_drag = {}
	s := pt_one(2) // pi, shell 1, shell 2
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	lay :: proc(s: ^core.Open_Session) {
		_ = ui_layout(1400, 860)
		ui_pane_rects(s)
	}
	centre :: proc(i: int) -> (f32, f32) {
		b := clay.GetElementData(clay.ID("tab", u32(i))).boundingBox
		return b.x + b.width / 2, b.y + b.height / 2
	}
	lay(s)
	pi, s1, s2 := s.tabs[0].id, s.tabs[1].id, s.tabs[2].id
	// under the threshold: a click (nothing moves, the release goes on)
	x, y := centre(1)
	tab_drag_arm(s1, x, y)
	tab_drag_move(x + 3, y)
	testing.expect(t, !tab_dragging(), "3 px: not a drag")
	testing.expect(t, !tab_drag_release(x + 3, y), "the release is a click's")
	testing.expect_value(t, tab_drag.tab, u64(0))
	// a reorder in the title bar: shell 2 before shell 1 (dropped before the pi tab: after it)
	x, y = centre(2)
	px0, _ := centre(0)
	tab_drag_arm(s2, x, y)
	tab_drag_move(px0 - 20, y)
	testing.expect(t, tab_dragging(), "a drag")
	testing.expect(t, tab_drag.drop.kind == .Strip && tab_drag.drop.gap == 1, "the mark after the pi tab")
	testing.expect(t, tab_drag.preview.z > 0, "a mark shows")
	testing.expect(t, tab_drag_release(px0 - 20, y), "the drag's release")
	core.inbox_drain()
	testing.expect_value(t, pt_strip_titles(s, s.panes[0].id), "pi,shell 2,shell 1")
	// the first split: shell 1 (now tabs[2]) to the pane's right edge
	lay(s)
	x, y = centre(2)
	z := s.panes[0].frame
	tab_drag_arm(s1, x, y)
	tab_drag_move(z.x + z.z - 10, z.y + z.w / 2)
	testing.expect(t, tab_drag.drop.kind == .Edge && tab_drag.drop.dir == .Right, "the right edge")
	testing.expectf(t, abs(tab_drag.preview.z - z.z / 2) < 1, "the right half previewed: %v", tab_drag.preview)
	tab_drag_release(z.x + z.z - 10, z.y + z.w / 2)
	core.inbox_drain()
	if !testing.expect_value(t, len(s.panes), 2) do return
	testing.expect_value(t, core.pane_of_tab(s, s1).id, s.panes[1].id)
	testing.expect_value(t, s.tabs[0].id, pi)
	// Esc cancels a drag; nothing moves
	lay(s)
	x, y = centre(1) // shell 2, in the left pane's strip now
	b := s.panes[1].frame
	tab_drag_arm(s2, x, y)
	tab_drag_move(b.x + b.z / 2, b.y + b.w / 2)
	testing.expect(t, tab_drag.drop.kind == .Centre && tab_drag.drop.pane == s.panes[1].id, "the right pane's centre")
	esc := sapp.Event{type = .KEY_DOWN, key_code = .ESCAPE}
	testing.expect(t, tab_drag_event(&esc), "Esc is the drag's")
	up := sapp.Event{type = .MOUSE_UP, mouse_x = b.x + b.z / 2, mouse_y = b.y + b.w / 2, mouse_button = .LEFT}
	testing.expect(t, !tab_drag_event(&up), "cancelled: the release goes on")
	core.inbox_drain()
	testing.expect_value(t, core.pane_of_tab(s, s2).id, s.panes[0].id)
	// a leave (sokol sends none while the button is held; should one come) cancels too
	tab_drag_arm(s2, x, y)
	tab_drag_move(b.x + b.z / 2, b.y + b.w / 2)
	leave := sapp.Event{type = .MOUSE_LEAVE}
	testing.expect(t, tab_drag_event(&leave), "the leave is the drag's")
	testing.expect(t, !tab_dragging(), "no drag")
	// shell 2 to the right pane's strip, after shell 1
	sb := clay.GetElementData(pid(&s.panes[1], "pane_strip")).boundingBox
	tab_drag_arm(s2, x, y)
	tab_drag_move(sb.x + sb.width - 40, sb.y + sb.height / 2)
	testing.expect(t, tab_drag.drop.kind == .Strip && tab_drag.drop.pane == s.panes[1].id && tab_drag.drop.gap == 1, "the end of the right strip")
	tab_drag_release(sb.x + sb.width - 40, sb.y + sb.height / 2)
	core.inbox_drain()
	if !testing.expect_value(t, core.pane_of_tab(s, s2).id, s.panes[1].id) do return
	testing.expect_value(t, pt_strip_titles(s, s.panes[1].id), "shell 1,shell 2")
	// the pi tab, alone in the left pane now, to the right pane's centre: that pane holds every
	// tab, the left one closes, the pi tab is still tabs[0] and first in its strip
	lay(s)
	x, y = centre(0)
	b = s.panes[1].frame
	tab_drag_arm(pi, x, y)
	tab_drag_move(b.x + b.z / 2, b.y + b.w / 2)
	tab_drag_release(b.x + b.z / 2, b.y + b.w / 2)
	core.inbox_drain()
	testing.expect_value(t, len(s.panes), 1)
	testing.expect_value(t, s.tabs[0].id, pi)
	testing.expect_value(t, pt_strip_titles(s, s.panes[0].id), "pi,shell 1,shell 2")
}

// ---- review fixes ----

// A lone tab from another pane dropped on an edge adds no pane (its own pane goes): at the limit
// it is not refused.
@(test)
tab_drop_lone_tab_at_the_limit :: proc(t: ^testing.T) {
	full := dh_input(3, 20)
	full.at_max = true
	full.from_count = 1
	d := tab_drop_at(full, 10, 300) // A's left edge, s2 alone in B
	testing.expect_value(t, d.refused, "")
	cmd, ok := tab_drop_command(d, 3)
	testing.expect(t, ok && cmd.(core.Split_Pane) == core.Split_Pane{pane = 10, direction = .Left, tab_id = 3}, "split_pane")
	full.from_count = 2
	d = tab_drop_at(full, 10, 300)
	testing.expect_value(t, d.refused, "at most 8 panes") // a tab with company: one more pane
}

// split_pane with a lone tab of another pane: at 8 panes it ends with 8 panes; and its room is the
// tree's without the pane the tab leaves.
@(test)
panes_cmd_split_lone_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s := pt_one(core.PANES_MAX - 1)
	shells := make([]u64, core.PANES_MAX - 1, context.temp_allocator)
	for i in 0 ..< core.PANES_MAX - 1 do shells[i] = s.tabs[i + 1].id
	for id in shells {
		r := core.run_command(core.Split_Pane{pane = s.panes[0].id, direction = .Right, tab_id = id}, PT_UI)
		testing.expectf(t, r.ok, "split: %s", r.error)
	}
	testing.expect_value(t, len(s.panes), core.PANES_MAX)
	r := core.run_command(core.Split_Pane{pane = core.pane_of_tab(s, shells[0]).id, direction = .Down}, PT_UI)
	testing.expect_value(t, r.error, "at most 8 panes") // a new shell: one more pane
	r = core.run_command(core.Split_Pane{pane = core.pane_of_tab(s, shells[0]).id, direction = .Down, tab_id = shells[1]}, PT_UI)
	testing.expectf(t, r.ok, "a lone tab from another pane: %s", r.error)
	testing.expect_value(t, len(s.panes), core.PANES_MAX)
	testing.expect_value(t, core.session_check(s), "")
	// room: pi | (s1 | s2) in 740 px; s2 (alone) beside pi needs pi's and s1's room, not s2's
	s = pt_one(2)
	pi, s1, s2 := s.tabs[0].id, s.tabs[1].id, s.tabs[2].id
	core.run_command(core.Split_Pane{pane = s.panes[0].id, direction = .Right, tab_id = s1}, PT_UI)
	core.run_command(core.Split_Pane{pane = core.pane_of_tab(s, s1).id, direction = .Right, tab_id = s2}, PT_UI)
	core.pane_set_ratio(s, s.nodes[s.root].id, 0.7)
	old_c, old_d, old_pc := app.centre, app.dpi, core.pane_centre
	defer app.centre, app.dpi, core.pane_centre = old_c, old_d, old_pc
	app.centre, app.dpi = {0, 0, 740, 600}, 1
	core.pane_centre_set(740, 600, 1)
	r = core.run_command(core.Split_Pane{pane = core.pane_of_tab(s, pi).id, direction = .Right, tab_id = s2}, PT_UI)
	testing.expectf(t, r.ok, "room without s2's pane: %s", r.error)
	testing.expect_value(t, len(s.panes), 3)
}

// A press whose button went up somewhere else (a menu, the job sheet took the release) never
// stays armed: a move without the button, or with a menu open, ends it.
@(test)
tab_drag_ends_without_the_button :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	defer tab_drag = {}
	s := pt_one(1)
	tab_drag_arm(s.tabs[1].id, 100, 10)
	held := sapp.Event{type = .MOUSE_MOVE, mouse_x = 101, mouse_y = 10, modifiers = sapp.MODIFIER_LMB}
	testing.expect(t, tab_drag_event(&held), "a held move under the threshold is the press's")
	testing.expect(t, tab_drag.tab != 0, "still armed")
	free := sapp.Event{type = .MOUSE_MOVE, mouse_x = 300, mouse_y = 300}
	testing.expect(t, !tab_drag_event(&free), "a move without the button goes on as any")
	testing.expect_value(t, tab_drag.tab, u64(0))
	tab_drag_arm(s.tabs[1].id, 100, 10)
	menu.open = true
	defer menu.open = false
	tab_drag_event(&held)
	testing.expect_value(t, tab_drag.tab, u64(0))
}

// Nothing drops under the drawer sliding over the panes.
@(test)
tab_drop_not_under_the_drawer :: proc(t: ^testing.T) {
	input := dh_input(3, 20)
	input.covered = {300, 0, 500, 600}
	testing.expect_value(t, tab_drop_at(input, 350, 300).kind, Tab_Drop_Kind.None)
	testing.expect_value(t, tab_drop_at(input, 350, 15).kind, Tab_Drop_Kind.None) // a strip under it too
	testing.expect_value(t, tab_drop_at(input, 200, 300).kind, Tab_Drop_Kind.Centre)
}

// The dragged tab closes mid-drag: the drag ends at the next layout (no preview of a gone tab).
@(test)
tab_drag_ends_when_its_tab_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	defer tab_drag = {}
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	_ = ui_layout(1400, 860)
	ui_pane_rects(s)
	b := clay.GetElementData(clay.ID("tab", 2)).boundingBox
	z := s.panes[0].frame
	id := s.tabs[2].id
	tab_drag_arm(id, b.x + b.width / 2, b.y + b.height / 2)
	tab_drag_move(z.x + z.z - 10, z.y + z.w / 2)
	testing.expect(t, tab_dragging(), "a drag")
	r := core.run_command(core.Close_Tab{tab_id = id}, PT_UI)
	testing.expectf(t, r.ok, "close: %s", r.error)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, tab_drag.tab, u64(0))
}

// Through event() (P4's pointer routing beside it): a press on a tab in A's strip arms the drag;
// held moves over B's app are the drag's (the app hears nothing, the pointer's pane stays A's, no
// leave fires); the release over B's middle moves the tab there.
@(test)
tab_drag_owns_the_pointer_in_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	defer tab_drag = {}
	x := pt_two()
	defer pt_two_done(x)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	core.session_show_tab(x.s, x.app_id)
	apps[x.app_id].inspect = true
	for _ in 0 ..< 3 {
		_ = ui_layout(1400, 860)
		ui_pane_rects(x.s)
	}
	tb := clay.GetElementData(clay.ID("tab", 1)).boundingBox // the shell, in A's strip
	pb := core.session_pane(x.s, x.b)
	cx, cy := pb.rect.x + pb.rect.z / 2, pb.rect.y + pb.rect.w / 2
	e := sapp.Event{type = .MOUSE_MOVE, mouse_x = tb.x + tb.width / 2, mouse_y = tb.y + tb.height / 2}
	event(&e)
	e = {type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = tb.x + tb.width / 2, mouse_y = tb.y + tb.height / 2}
	event(&e)
	testing.expect_value(t, tab_drag.tab, x.shell)
	testing.expect_value(t, pointer_pane, x.a)
	for i in 1 ..= 4 {
		f := f32(i) / 4
		e = {type = .MOUSE_MOVE, modifiers = sapp.MODIFIER_LMB, mouse_x = tb.x + (cx - tb.x) * f, mouse_y = tb.y + (cy - tb.y) * f}
		event(&e)
	}
	testing.expect(t, tab_dragging(), "a drag")
	testing.expect(t, !apps[x.app_id].hin, "B's app heard no move")
	testing.expect_value(t, pointer_pane, x.a)
	testing.expect(t, tab_drag.drop.kind == .Centre && tab_drag.drop.pane == x.b, "B's middle")
	e = {type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = cx, mouse_y = cy}
	event(&e)
	testing.expect_value(t, core.pane_of_tab(x.s, x.shell).id, x.b)
	testing.expect_value(t, tab_drag.tab, u64(0))
	testing.expect_value(t, pointer_capture.pane, u64(0))
}
