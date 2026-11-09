package main

import "core:math"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

// Dragging a tab (docs/plans/split-panes.md §5.3, P5; docs/GUIDE.md "Split panes"): a press on a
// tab that moves more than TAB_DRAG_START px drags it. While it drags it owns the pointer (every
// move and the release are its own, wherever the pointer goes) and a ghost of the tab follows the
// pointer. Where it would land:
//   - a strip (a pane's own when split, the title bar's with one pane): an insertion mark between
//     tabs, move_tab at that place (a reorder in its own strip);
//   - a pane's body: its outer quarter on each side (TAB_DROP_EDGE_MIN..MAX px) splits that pane
//     that way with the tab (split_pane with tab_id), its centre moves the tab into that pane
//     (move_tab); a translucent rectangle shows the area the tab would take;
//   - anywhere else: nothing (the pointer says not allowed).
// Esc or the window losing focus cancel it; a release outside the window (or anywhere no tab
// goes) drops nothing. A drag whose tab closes, or whose release a menu took, ends. A drop the commands
// would refuse (PANES_MAX, a pane too small to split) is shown refused while hovered and says
// why when dropped. The pi/main tab can move to another pane or split one; it stays tabs[0], so it
// is always first in its strip and other tabs land after it (pane_move_tab).
//
// The drop is worked out by tab_drop_at from rects alone (Tab_Drop_Input, built from the last
// layout by tab_drop_input), so it is unit-tested without a window; the drop itself is one of the
// existing commands (tab_drop_command), so state, saving and the snapshot have one path.

TAB_DRAG_START :: 4 // logical px a press moves before it drags (less: a click)
TAB_DROP_EDGE :: 0.25 // a pane's edge zone: this share of its size …
TAB_DROP_EDGE_MIN :: 40 // … at least (logical px) …
TAB_DROP_EDGE_MAX :: 120 // … at most
TAB_DROP_MARK_W :: 2 // the insertion mark in a strip (logical px)

Tab_Drop_Kind :: enum {
	None, // not over a place a tab can go
	Strip, // into a strip at `gap`
	Centre, // into pane `pane` (the end of its strip)
	Edge, // a new pane on `dir` of pane `pane`
}

Tab_Drop :: struct {
	kind:    Tab_Drop_Kind,
	pane:    u64,
	dir:     core.Pane_Dir, // Edge
	gap:     int, // Strip: the mark's place among the strip's tabs as drawn (0 = before the first)
	index:   int, // Strip: move_tab's index (the strip position without the dragged tab)
	noop:    bool, // it is a place, but dropping there changes nothing (its own place, its only pane)
	refused: string, // the commands would refuse it: why (shown, nothing runs)
}

Drop_Tab :: struct {
	id:   u64,
	rect: [4]f32, // x, y, w, h (framebuffer px)
}

Drop_Pane :: struct {
	id:    u64,
	zone:  [4]f32, // the body the edge and centre zones divide (the pane less its strip)
	strip: [4]f32, // its tab strip ({}: none)
	tabs:  []Drop_Tab, // its tabs in strip order
	room:  [core.Pane_Dir]bool, // it can be split that way (min sizes)
}

Tab_Drop_Input :: struct {
	panes:         []Drop_Pane,
	tab:           u64, // the dragged tab
	from:          u64, // its pane
	from_count:    int, // how many tabs its pane holds
	main:          u64, // the session's pi/main tab (tabs[0])
	at_max:        bool, // the session has PANES_MAX panes
	edge_min:      f32, // TAB_DROP_EDGE_MIN, TAB_DROP_EDGE_MAX in framebuffer px
	edge_max:      f32,
	mark_w:        f32,
	covered:       [4]f32, // over the panes, where nothing drops (the drawer sliding over them; {}: none)
}

// Which part of rect r the point is in: an edge's zone (the side it is nearest, relative to the
// zones' sizes, in a corner) or the centre. ok false: outside r.
drop_zone_at :: proc(r: [4]f32, x, y, edge_min, edge_max: f32) -> (dir: core.Pane_Dir, edge: bool, ok: bool) {
	if r.z <= 0 || r.w <= 0 || x < r.x || y < r.y || x >= r.x + r.z || y >= r.y + r.w do return
	ok = true
	bw := min(clamp(r.z * TAB_DROP_EDGE, edge_min, edge_max), r.z / 3)
	bh := min(clamp(r.w * TAB_DROP_EDGE, edge_min, edge_max), r.w / 3)
	d := [core.Pane_Dir]f32 {
		.Left  = (x - r.x) / bw,
		.Right = (r.x + r.z - x) / bw,
		.Up    = (y - r.y) / bh,
		.Down  = (r.y + r.w - y) / bh,
	}
	best := f32(1)
	for v, k in d do if v < best {
		best = v
		dir = k
		edge = true
	}
	return
}

// Where a drop at (x, y) lands (framebuffer px): a strip first, then a pane's body.
tab_drop_at :: proc(input: Tab_Drop_Input, x, y: f32) -> Tab_Drop {
	if rect_has(input.covered, x, y) do return {}
	for p in input.panes do if rect_has(p.strip, x, y) do return strip_drop(input, p, x)
	for p in input.panes {
		dir, edge, ok := drop_zone_at(p.zone, x, y, input.edge_min, input.edge_max)
		if !ok do continue
		if !edge do return {kind = .Centre, pane = p.id, noop = p.id == input.from}
		d := Tab_Drop{kind = .Edge, pane = p.id, dir = dir}
		if p.id == input.from && input.from_count <= 1 {
			d.noop = true // a pane's only tab beside itself
		} else if input.at_max && input.from_count > 1 {
			// (a lone tab's own pane closes: the split adds no pane)
			d.refused = "at most 8 panes"
		} else if !p.room[dir] {
			d.refused = "not enough room"
		}
		return d
	}
	return {}
}

// A drop in pane p's strip at x: the gap between the tabs whose centres are left of x and the
// rest. Never before the main tab (it stays first); the main tab itself always goes first.
@(private = "file")
strip_drop :: proc(input: Tab_Drop_Input, p: Drop_Pane, x: f32) -> Tab_Drop {
	d := Tab_Drop{kind = .Strip, pane = p.id}
	own := -1 // the dragged tab's place in this strip
	for t, i in p.tabs {
		if t.id == input.tab do own = i
		if x > t.rect.x + t.rect.z / 2 do d.gap += 1
	}
	if input.tab == input.main {
		d.gap = 0
	} else if len(p.tabs) > 0 && p.tabs[0].id == input.main {
		d.gap = max(d.gap, 1)
	}
	d.index = d.gap
	if own >= 0 {
		if d.gap > own do d.index = d.gap - 1
		d.noop = d.index == own
	}
	return d
}

@(private = "file")
rect_has :: proc(r: [4]f32, x, y: f32) -> bool {
	return r.z > 0 && r.w > 0 && x >= r.x && y >= r.y && x < r.x + r.z && y < r.y + r.w
}

// The command a drop runs (false: none: nowhere, no change, or refused).
tab_drop_command :: proc(d: Tab_Drop, tab: u64) -> (core.Command, bool) {
	if d.noop || d.refused != "" do return nil, false
	switch d.kind {
	case .None:   return nil, false
	case .Strip:  return core.Move_Tab{tab_id = tab, pane = d.pane, index = d.index}, true
	case .Centre: return core.Move_Tab{tab_id = tab, pane = d.pane, index = -1}, true
	case .Edge:   return core.Split_Pane{pane = d.pane, direction = d.dir, tab_id = tab}, true
	}
	return nil, false
}

// What the drop indicator covers (framebuffer px; {}: nothing to show): the insertion mark in a
// strip, the pane for its centre, the half of it the new pane takes for an edge.
tab_drop_preview :: proc(input: Tab_Drop_Input, d: Tab_Drop) -> [4]f32 {
	p: Drop_Pane
	found := false
	for x in input.panes do if x.id == d.pane {
		p = x
		found = true
	}
	if !found do return {}
	r := p.zone
	switch d.kind {
	case .None:
		return {}
	case .Strip:
		h := p.strip.w
		y := p.strip.y
		cx := p.strip.x + input.mark_w
		if n := len(p.tabs); n > 0 {
			y, h = p.tabs[0].rect.y, p.tabs[0].rect.w
			if d.gap <= 0 {
				cx = p.tabs[0].rect.x - input.mark_w
			} else if d.gap >= n {
				last := p.tabs[n - 1].rect
				cx = last.x + last.z + input.mark_w
			} else {
				a, b := p.tabs[d.gap - 1].rect, p.tabs[d.gap].rect
				cx = (a.x + a.z + b.x) / 2
			}
		}
		return {cx - input.mark_w / 2, y, input.mark_w, h}
	case .Centre:
		if d.noop do return {}
		return r
	case .Edge:
		if d.noop do return {}
		switch d.dir {
		case .Left:  return {r.x, r.y, r.z / 2, r.w}
		case .Right: return {r.x + r.z / 2, r.y, r.z / 2, r.w}
		case .Up:    return {r.x, r.y, r.z, r.w / 2}
		case .Down:  return {r.x, r.y + r.w / 2, r.z, r.w / 2}
		}
	}
	return {}
}

// ---- the drag (input) ----

Tab_Drag :: struct {
	tab:     u64, // the tab pressed (0: none)
	session: u64,
	from:    [2]f32, // where the press was
	at:      [2]f32, // the pointer now
	active:  bool, // it moved past TAB_DRAG_START: a drag (until then a click)
	drop:    Tab_Drop, // where it would land now
	preview: [4]f32, // what its indicator covers (tab_drop_preview)
}
tab_drag: Tab_Drag

// A press on a tab (the click has already focused it): a drag may follow.
tab_drag_arm :: proc(tab_id: u64, x, y: f32) {
	s := core.cur()
	if s == nil || s.home do return
	core.session_panes_init(s)
	tab_drag = {tab = tab_id, session = s.id, from = {x, y}, at = {x, y}}
}

// The tab is being dragged (past the threshold).
tab_dragging :: proc() -> bool {return tab_drag.tab != 0 && tab_drag.active}

// The pointer moved with the button held: past the threshold the drag starts; then the drop
// follows the pointer.
tab_drag_move :: proc(x, y: f32) {
	if tab_drag.tab == 0 do return
	s := core.cur()
	if s == nil || s.id != tab_drag.session || core.pane_of_tab(s, tab_drag.tab) == nil {
		tab_drag_cancel() // the tab or its session went from the screen
		return
	}
	tab_drag.at = {x, y}
	if !tab_drag.active {
		dx, dy := x - tab_drag.from.x, y - tab_drag.from.y
		if math.sqrt(dx * dx + dy * dy) <= px(TAB_DRAG_START) do return
		tab_drag.active = true
		if sapp.isvalid() do set_hover(nil, false) // no hover under a drag (no window: tests)
	}
	input := tab_drop_input(s, tab_drag.tab)
	tab_drag.drop = tab_drop_at(input, x, y)
	tab_drag.preview = tab_drop_preview(input, tab_drag.drop)
	cursor := tab_drag.drop.kind == .None || tab_drag.drop.refused != "" ? sapp.Mouse_Cursor.NOT_ALLOWED : .DEFAULT
	tab_drag_cursor(cursor)
	app.redraw = true
}

@(private = "file")
tab_drag_cursor :: proc(c: sapp.Mouse_Cursor) {
	if sapp.isvalid() && sapp.get_mouse_cursor() != c do sapp.set_mouse_cursor(c)
}

// The button is up: a drag drops (true: the release was the drag's); a press that never moved
// was a click (false: the release goes on as any).
tab_drag_release :: proc(x, y: f32) -> bool {
	if tab_drag.tab == 0 do return false
	if !tab_drag.active {
		tab_drag = {}
		return false
	}
	tab_drag_move(x, y)
	d, tab := tab_drag.drop, tab_drag.tab
	tab_drag_cancel()
	if d.refused != "" do toast_show(d.refused, err = true)
	else if cmd, ok := tab_drop_command(d, tab); ok do ui_do(cmd)
	return true
}

// Esc, the pointer left the window, the window lost focus: no drag, nothing moves.
tab_drag_cancel :: proc() {
	if tab_drag.active {
		tab_drag_cursor(.DEFAULT)
		app.redraw = true
	}
	tab_drag = {}
}

// The events a press on a tab owns until its release (event(), before the panes' handlers):
// true: taken.
tab_drag_event :: proc(e: ^sapp.Event) -> bool {
	if tab_drag.tab == 0 do return false
	// the release went to something else (a menu, the job sheet): no press is held any more
	if menu.open || job_sheet_open() || (e.type == .MOUSE_MOVE && e.modifiers & sapp.MODIFIER_LMB == 0) {
		tab_drag_cancel()
		return false
	}
	#partial switch e.type {
	case .MOUSE_MOVE:
		tab_drag_move(e.mouse_x, e.mouse_y)
		return true
	case .MOUSE_UP:
		return tab_drag_release(e.mouse_x, e.mouse_y)
	case .MOUSE_DOWN:
		tab_drag_cancel() // another button
	case .MOUSE_LEAVE, .UNFOCUSED:
		// (sokol sends no MOUSE_LEAVE while the button is held: a release outside the window lands
		// outside every pane and strip, so it drops nothing; this covers a leave if one comes)
		was := tab_drag.active
		tab_drag_cancel()
		return was && e.type == .MOUSE_LEAVE
	case .KEY_DOWN:
		if e.key_code == .ESCAPE {
			was := tab_drag.active
			tab_drag_cancel()
			if was do app.key_taken = true
			return was // a press that never moved: Esc goes on as any
		}
	}
	return false
}

// The rects a drop is worked out from, from the last layout: each pane's strip (with one pane,
// the title bar's tabs), its tabs and its body (the pane less its strip).
tab_drop_input :: proc(s: ^core.Open_Session, tab_id: u64) -> Tab_Drop_Input {
	box :: proc(id: clay.ElementId) -> [4]f32 {
		d := clay.GetElementData(id)
		if !d.found do return {}
		b := d.boundingBox
		return {b.x, b.y, b.width, b.height}
	}
	input := Tab_Drop_Input {
		tab      = tab_id,
		main     = len(s.tabs) > 0 ? s.tabs[0].id : 0,
		at_max   = len(s.panes) >= core.PANES_MAX,
		edge_min = px(TAB_DROP_EDGE_MIN),
		edge_max = px(TAB_DROP_EDGE_MAX),
		mark_w   = px(TAB_DROP_MARK_W),
	}
	if p := core.pane_of_tab(s, tab_id); p != nil {
		input.from = p.id
		input.from_count = core.pane_tab_count(s, p.id)
	}
	split := len(s.panes) > 1
	panes := make([]Drop_Pane, len(s.panes), context.temp_allocator)
	for &p, k in s.panes {
		dp := Drop_Pane{id = p.id, zone = p.frame.z > 0 ? p.frame : p.rect}
		tabs := make([dynamic]Drop_Tab, context.temp_allocator)
		for t, i in s.tabs do if t.pane == p.id {
			if r := box(clay.ID("tab", u32(i))); r.z > 0 do append(&tabs, Drop_Tab{id = t.id, rect = r})
		}
		dp.tabs = tabs[:]
		if split {
			dp.strip = box(pid(&p, "pane_strip"))
			if dp.strip.w > 0 && dp.zone.w > 0 {
				top := dp.strip.y + dp.strip.w
				dp.zone = {dp.zone.x, top, dp.zone.z, dp.zone.y + dp.zone.w - top}
			}
		} else if len(tabs) > 0 {
			// the title bar's tabs, and a tab's width past the last (the "+" beside them: the end)
			bar := box(clay.ID("tabs"))
			first, last := tabs[0].rect, tabs[len(tabs) - 1].rect
			right := last.x + last.z + px(TAB_MIN_W)
			dp.strip = {first.x, bar.w > 0 ? bar.y : first.y, right - first.x, bar.w > 0 ? bar.w : first.w}
		}
		// a lone tab takes its own pane's room with it (split_pane checks the same)
		leaving := input.from_count <= 1 ? input.from : 0
		for d in core.Pane_Dir do dp.room[d] = core.pane_has_room_leaving(s, p.id, d, leaving)
		panes[k] = dp
	}
	input.panes = panes
	if state.home_open && !state.layout.drawer_pinned do input.covered = box(clay.ID("drawer")) // it slides over the panes
	return input
}

// ---- the drag (drawing) ----

// The drop indicator and the tab's ghost under the pointer, above the panes' tabs ("tab_drop"
// and "tab_ghost" are drawn after them: main.odin frame()).
tab_drag_layout :: proc() {
	if tab_drag.tab != 0 && (core.pane_of_tab(core.cur(), tab_drag.tab) == nil || menu.open || job_sheet_open()) do tab_drag_cancel() // its tab closed, or something took over
	if !tab_dragging() do return
	th := theme()
	d := tab_drag.drop
	if r := tab_drag.preview; r.z > 0 && r.w > 0 {
		refused := d.refused != ""
		col := refused ? th.error : th.accent
		bg := d.kind == .Strip ? col : with_alpha(col, 0.18)
		if clay.UI(clay.ID("tab_drop"))({
			layout = {sizing = {clay.SizingFixed(r.z), clay.SizingFixed(r.w)}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = cc(bg),
			border = d.kind == .Strip ? {} : {color = cc(col), width = clay.BorderOutside(pu(core.BORDER_W))},
			cornerRadius = clay.CornerRadiusAll(d.kind == .Strip ? 0 : px(RADIUS_MD)),
			floating = {attachTo = .Root, offset = {r.x, r.y}, zIndex = 7},
		}) {
			if refused do clay.TextDynamic(d.refused, txt(th.text))
		}
	}
	s := core.cur()
	if s == nil do return
	_, tab, _ := find_tab(tab_drag.tab)
	if tab == nil do return
	ic, label, _ := tab_label(s, tab^)
	if clay.UI(clay.ID("tab_ghost"))({
		layout = {sizing = {clay.SizingFit({max = px(TAB_MAX_W)}), clay.SizingFixed(px(TAB_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(th.accent), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {tab_drag.at.x + px(SP_3), tab_drag.at.y + px(SP_2)}, zIndex = 7},
	}) {
		if ic != .None do icon(ic, th.text, KIND_ICON)
		clay.TextDynamic(clip(label, px(TAB_MAX_W - 2 * SP_3 - 20)), txt(th.text))
	}
}
