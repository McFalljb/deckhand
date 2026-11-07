package main

import "core:fmt"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

// The panes' input (panes.odin; docs/plans/split-panes.md §3.4, §5.2): which pane the pointer is
// for, the dividers between panes, a pane strip's "+".
//
// Pointer capture: a press belongs to the pane it started in. Until the button is up (or the
// pointer leaves the window, or the window loses focus, or the pane goes) every move and the
// release go to that pane, wherever the pointer is: a selection dragged from pane A over pane B
// keeps selecting in A. Without a button, moves and the wheel go to the pane under the pointer.
// A press in a pane without the keyboard focuses it first (synchronously: the inbox drains
// after the event, too late for this click), then acts (click-through), except on a "Click to
// show" placeholder, which it only focuses.

Pointer_Capture :: struct {
	pane:   u64, // the pane a press started in (0 = none held)
	window: bool, // the press started outside every pane (the sidebar, a bar of the window…)
}
pointer_capture: Pointer_Capture

// A divider being dragged (live: the layout uses its ratio; one set_split on release).
Pane_Drag :: struct {
	split:  u64,
	ratio:  f32,
	active: bool,
}
pane_drag: Pane_Drag

// The pane an event at (x, y) is for: the press's pane while one is held, else the pane under
// the point, else the focused one (keys; a point outside every pane).
event_pane :: proc(e: ^sapp.Event) -> ^Pane {
	s := cur()
	if s == nil do return focused_pane()
	#partial switch e.type {
	case .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_ENTER, .MOUSE_LEAVE:
		if pointer_capture.pane != 0 {
			if p := session_pane(s, pointer_capture.pane); p != nil do return p
			pointer_capture = {} // its pane went
		}
		if p := pane_at(e.mouse_x, e.mouse_y); p != nil do return p
	}
	return focused_pane()
}

// The pane under the pointer for the hit tests (the last layout's rects), else the focused one.
hit_pane :: proc() -> ^Pane {
	if p := pane_at(app.pointer.x, app.pointer.y); p != nil do return p
	return focused_pane()
}

// A press: records its pane (capture) and focuses it when it has not the keyboard. True: the
// press is used up (it only focused a placeholder pane).
pane_press :: proc(e: ^sapp.Event) -> bool {
	s := cur()
	if s == nil || len(s.panes) <= 1 do return false
	if over_overlay() || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) do return false
	p := pane_at(e.mouse_x, e.mouse_y)
	if p == nil {
		pointer_capture = {window = true}
		return false
	}
	pointer_capture = {pane = p.id}
	if p.id == s.focused_pane do return false
	placeholder := pane_placeholder(s, p)
	run_command(Focus_Pane{pane = p.id}, {kind = .UI}) // now: this same click acts in it
	// the click's own drag must outlive the focus change (drags_follow_focus ends the drags of
	// tabs that left the screen; this one's did not, but the focused tab changed)
	if tab := active_tab(); tab != nil do app.drag_tab = tab.id
	app.redraw = true
	return placeholder
}

// The button is up, the pointer left the window or the window lost focus: no capture.
pane_release :: proc() {pointer_capture = {}}

// ---- dividers ----

pane_drag_ratio :: proc(split: u64, ratio: f32) -> f32 {
	return pane_drag.active && pane_drag.split == split ? pane_drag.ratio : ratio
}

pane_divider_hot :: proc(split: u64) -> bool {
	if pane_drag.active && pane_drag.split == split do return true
	h, ok := ui_hover.(Hit_Pane_Divider)
	return ok && u64(h) == split
}

// The divider under (x, y) (its split's id; 0 = none): DIVIDER_HIT px wide across its line.
pane_divider_at :: proc(x, y: f32) -> u64 {
	s := cur()
	if s == nil || len(s.panes) <= 1 do return 0
	grab := px(DIVIDER_HIT) / 2
	for n in s.nodes {
		if n.leaf do continue
		d := clay.GetElementData(clay.ID("pane_div", u32(n.id)))
		if !d.found do continue
		b := d.boundingBox
		if n.dir == .Right {
			if x >= b.x - grab && x < b.x + b.width + grab && y >= b.y && y < b.y + b.height do return n.id
		} else {
			if y >= b.y - grab && y < b.y + b.height + grab && x >= b.x && x < b.x + b.width do return n.id
		}
	}
	return 0
}

// A press on a divider: a drag starts; a double-click evens it.
pane_divider_press :: proc(split: u64, clicks: int) {
	if clicks >= 2 {
		pane_drag = {}
		ui_do(Set_Split{split = split, ratio = 0.5})
		return
	}
	s := cur()
	for n in s.nodes do if n.id == split do pane_drag = {split = split, ratio = n.ratio, active = true}
}

// The drag follows the pointer: the share it gives child a, kept so neither side is under its
// panes' minimum sizes (when there is room for both).
pane_divider_move :: proc(x, y: f32) {
	s := cur()
	if s == nil || !pane_drag.active do return
	for n, i in s.nodes {
		if n.leaf || n.id != pane_drag.split do continue
		d := clay.GetElementData(clay.ID("pane_split", u32(n.id)))
		if !d.found do return
		b := d.boundingBox
		across := n.dir == .Right
		total := (across ? b.width : b.height) - px(BORDER_W)
		if total <= 0 do return
		at := (across ? x - b.x : y - b.y) - px(BORDER_W) / 2
		ma, mb := pane_split_mins(s, i, px(BORDER_W), px(PANE_MIN_W), px(PANE_MIN_H))
		if total >= ma + mb do at = clamp(at, ma, total - mb)
		pane_drag.ratio = clamp(at / total, RATIO_MIN, 1 - RATIO_MIN)
		app.redraw = true
		return
	}
}

// The drag ends: the divider's place is set (one set_split).
pane_divider_release :: proc() {
	if !pane_drag.active do return
	ui_do(Set_Split{split = pane_drag.split, ratio = pane_drag.ratio})
	pane_drag.active = false
	app.redraw = true
}

// ---- hits ----

// A pane strip's "+" or a divider under the pointer.
pane_hit :: proc() -> Hit {
	s := cur()
	if s == nil || len(s.panes) <= 1 do return nil
	for &p in s.panes do if clay.PointerOver(pid(&p, "pane_new")) do return Hit_Pane_New(p.id)
	return nil
}

pane_click :: proc(h: Hit_Pane_New) {
	s := cur()
	if s == nil do return
	ui_do(New_Shell_Tab{session = s.id, pane = u64(h)})
}

// The terminal throttles PTY resizes while a divider (a column's or a pane's) is dragged.
pane_dragging :: proc() -> bool {return pane_drag.active}

// ---- keys and actions ----

// The panes' shortcuts (their actions: actions.odin), before any tab or widget takes the key.
// True: it was one (whether or not it applied).
pane_key :: proc(e: ^sapp.Event) -> bool {
	m := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL)
	CMD :: sapp.MODIFIER_SUPER
	SH :: sapp.MODIFIER_SHIFT
	CT :: sapp.MODIFIER_CTRL
	id := ""
	#partial switch e.key_code {
	case .D:
		if m == CMD do id = "split_right"
		else if m == CMD | SH do id = "split_down"
	case .W:
		if m == CMD | SH do id = "close_pane"
	case .LEFT, .RIGHT, .UP, .DOWN:
		names := [4]string{"left", "right", "up", "down"}
		k := e.key_code == .LEFT ? 0 : e.key_code == .RIGHT ? 1 : e.key_code == .UP ? 2 : 3
		if m == CMD | CT do id = fmt.tprintf("focus_pane_%s", names[k])
		else if m == CMD | CT | SH do id = fmt.tprintf("move_tab_%s", names[k])
	}
	if id == "" do return false
	a := action_by_id(id)
	if a == nil do return false
	if _, ok := a.make(); !ok do return false // not here (one pane, Home…): ⌘W's close, the menu bar's
	action_run(id)
	return true
}

// ⌘D / ⇧⌘D: the focused pane splits; a new shell opens in the new pane.
pane_split_action :: proc(d: Pane_Dir) -> (Command, bool) {
	cs := cur()
	if cs == nil || cs.home || len(cs.panes) >= PANES_MAX do return nil, false
	return Split_Pane{direction = d}, true
}

pane_focus_action :: proc(d: Pane_Dir) -> (Command, bool) {
	cs := cur()
	if cs == nil || len(cs.panes) <= 1 do return nil, false
	if pane_neighbour(cs, cs.focused_pane, d) == 0 do return nil, false
	return Focus_Pane{direction = PANE_DIR_NAMES[d]}, true
}

// ⇧⌃⌘arrows: the focused tab moves to the neighbouring pane, or into a new pane that way when
// there is none (not a pane's only tab, not the main tab... it may: a pi tab moves like any).
pane_move_action :: proc(d: Pane_Dir) -> (Command, bool) {
	cs := cur()
	if cs == nil || cs.home do return nil, false
	session_panes_init(cs)
	tab := session_focused_id(cs)
	if tab == 0 do return nil, false
	if n := pane_neighbour(cs, cs.focused_pane, d); n != 0 do return Move_Tab{tab_id = tab, pane = n, index = -1}, true
	if pane_tab_count(cs, cs.focused_pane) <= 1 || len(cs.panes) >= PANES_MAX do return nil, false
	return Split_Pane{pane = cs.focused_pane, direction = d, tab_id = tab}, true
}

// The pointer is over a "Click to show" pane's content (the plan's P4 makes pages and apps live
// in every pane), no press held elsewhere: the page or app under it is not live, so nothing
// reaches it; a press there only focuses the pane (pane_press does that first). True: the event
// is used up.
pointer_over_placeholder :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_UP:
		if over_overlay() || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) do return false // the palette's, a menu's, the drawer's
		s := cur()
		p := event_pane(e)
		if s == nil || !pane_placeholder(s, p) do return false
		r := p.rect
		if !(r.z > 0 && e.mouse_x >= r.x && e.mouse_y >= r.y && e.mouse_x < r.x + r.z && e.mouse_y < r.y + r.w) do return false // its strip still hovers
		#partial switch e.type {
		case .MOUSE_MOVE:
			app.pointer = {e.mouse_x, e.mouse_y}
			set_hover(nil, false)
		case .MOUSE_DOWN:
			ui_do(Focus_Pane{pane = p.id})
			app.redraw = true
		}
		return true
	}
	return false
}
// A divider's line runs top to bottom (its split's panes are side by side).
pane_divider_across :: proc(split: u64) -> bool {
	s := cur()
	if s != nil do for n in s.nodes do if n.id == split do return n.dir == .Right
	return true
}
