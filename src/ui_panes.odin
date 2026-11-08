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
// after the event, too late for this click), then acts there (click-through), on a page or an
// app too.

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

// A press: records its pane (capture) and focuses it when it has not the keyboard.
pane_press :: proc(e: ^sapp.Event) {
	s := cur()
	if s == nil || len(s.panes) <= 1 do return
	if over_overlay() || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) do return
	p := pane_at(e.mouse_x, e.mouse_y)
	if p == nil {
		pointer_capture = {window = true}
		return
	}
	pointer_capture = {pane = p.id}
	if p.id == s.focused_pane do return
	run_command(Focus_Pane{pane = p.id}, {kind = .UI}) // now: this same click acts in it
	// the click's own drag must outlive the focus change (drags_follow_focus ends the drags of
	// tabs that left the screen; this one's did not, but the focused tab changed)
	if tab := active_tab(); tab != nil do app.drag_tab = tab.id
	app.redraw = true
}

// The pane the pointer was last over (0: none, a column, the sidebar, a divider; a held press's
// pane while it is held): when it moves off it, that pane gets a mouse-leave, as when the pointer
// leaves the window (a page's hover and CEF's pointer state, an app's Inspect hover). Not
// event_pane's: off any pane that is the focused one, which would never hear it leave.
pointer_pane: u64

pane_pointer_moved :: proc(e: ^sapp.Event) {
	now: u64
	if pointer_capture.pane != 0 do now = pointer_capture.pane
	else if p := pane_at(e.mouse_x, e.mouse_y); p != nil do now = p.id
	if now == pointer_pane do return
	before := pointer_pane
	pointer_pane = now
	s := cur()
	if before == 0 || s == nil do return
	old := session_pane(s, before)
	if old == nil do return
	ids := ids_pane_begin(old)
	defer ids_pane_end(ids)
	leave := sapp.Event{type = .MOUSE_LEAVE}
	browser_event(old, &leave)
	app_event(old, &leave)
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
// A divider's line runs top to bottom (its split's panes are side by side).
pane_divider_across :: proc(split: u64) -> bool {
	s := cur()
	if s != nil do for n in s.nodes do if n.id == split do return n.dir == .Right
	return true
}

// ---- Clay ids and rects of panes (moved from panes.odin: the window's) ----

// A Clay id for an element of pane p: slot 0 gives exactly clay.ID(name), so a session with one
// pane keeps every id scripts and tests click; another slot hashes its own label ("name#slot"),
// so no slot's id can meet another's whatever the index.
pid :: proc(p: ^Pane, name: string) -> clay.ElementId {
	return pidi(p, name, 0)
}

// pid for an element that already takes an index (rows, buttons): slot 0 is clay.ID(name, i).
pidi :: proc(p: ^Pane, name: string, i: int) -> clay.ElementId {
	slot := p != nil ? p.slot : 0
	if slot == 0 do return clay.ID(name, u32(i))
	return clay.ID(fmt.tprintf("%s#%d", name, slot), u32(i)) // temp: an id lives for its frame
}

// ---- the pane the per-tab bars' Clay ids are for ----
//
// The per-tab bars (a browser's toolbar, an editor's find bar, a Changes tab's list…) are laid
// out once per pane, so their Clay ids carry the pane's slot (pid): cid(name) is pid(the pane
// being laid out, hit-tested or handled, name). pane_layout sets it while it lays a pane out,
// the per-pane handlers and hit tests while they look at one; elsewhere (key handling, the
// fields' cursors, ticks) it is the focused pane, whose tab has the keyboard. Only ids: which
// tab a bar acts on still comes from its pane explicitly (pane_shown and friends).

@(private = "file")
ids_pane_at: ^Pane

// Clay ids from now on are pane p's; returns the one before, for ids_pane_end.
ids_pane_begin :: proc(p: ^Pane) -> ^Pane {
	old := ids_pane_at
	ids_pane_at = p
	return old
}
ids_pane_end :: proc(old: ^Pane) {ids_pane_at = old}

// The pane the per-tab bars' ids are for now.
ids_pane :: proc() -> ^Pane {return ids_pane_at != nil ? ids_pane_at : focused_pane()}

cid :: proc(name: string, i: u32 = 0) -> clay.ElementId {return pidi(ids_pane(), name, int(i))}

// A pane's element (cid/pid) under x, y as the pane shows it: inside its box and its pane's frame.
// A bar is clipped to its pane; what is cut off there is never hit (a box can reach into the
// next pane or a column while its pane gets the event: event_pane's focused pane off any pane).
pane_inside :: proc(p: ^Pane, id: clay.ElementId, x, y: f32) -> bool {
	if !inside(id, x, y) do return false
	if p == nil || p.frame.z <= 0 do return true // not laid out yet
	f := p.frame
	return x >= f.x && x < f.x + f.z && y >= f.y && y < f.y + f.w
}

// pane_inside for the ids of the pane the event is for (cid).
cinside :: proc(name: string, x, y: f32, i: u32 = 0) -> bool {return pane_inside(ids_pane(), cid(name, i), x, y)}

// A bar's width across its pane: grows to the pane, never past it (with clip = {horizontal =
// true} on the bar: its content's width is never its minimum, so one wide bar does not stretch
// the others or the pane).
bar_w :: proc() -> clay.SizingAxis {return clay.SizingGrow({max = pane_width()})}

// The width (framebuffer px) the per-tab bars of the pane being laid out have: the centre's with
// one pane, else that pane's (its last layout, else its place in the tree).
pane_width :: proc() -> f32 {
	s := cur()
	if s == nil || len(s.panes) <= 1 do return centre_width()
	p := ids_pane()
	if p == nil do return centre_width()
	// its place in the tree in the centre (as laid out: not its content's last width, which a bar
	// wider than the pane would feed back into)
	if app.centre.z > 0 do for r in pane_rects(s, app.centre, px(BORDER_W), px(PANE_MIN_W), px(PANE_MIN_H)) do if r.pane == p.id do return r.rect.z
	if p.rect.z > 0 do return p.rect.z
	return centre_width()
}

// The rect a terminal tab is sized to (framebuffer px). Shown in its pane of the current session:
// where it draws (its "terminal" element: only its own bars, a Claude tab's or a dead pi tab's,
// take room). Hidden: its pane's content without any tab's bars (the pane less its strip), what it
// gets when shown without bars of its own; so a tab with bars (a Changes header, a browser's
// toolbar) coming and going never resizes the pane's other terminals. Else tab_rect.
term_target_rect :: proc(tab_id: u64) -> [4]f32 {
	s, tab, _ := find_tab(tab_id)
	if s == nil || tab == nil || s.id != state.current_session do return tab_rect(tab_id)
	p := pane_of_tab(s, tab_id)
	if p == nil || p.frame.z <= 0 do return tab_rect(tab_id)
	if p.active == tab_id {
		if d := clay.GetElementData(pid(p, "terminal")); d.found && d.boundingBox.width > 0 {
			b := d.boundingBox
			return {b.x, b.y, b.width, b.height}
		}
	}
	f := p.frame
	if len(s.panes) > 1 {
		strip := min(px(TAB_STRIP_H), f.w)
		f = {f.x, f.y + strip, f.z, f.w - strip}
	}
	return f
}

pane_editor :: proc(p: ^Pane) -> ^Editor {
	if t := pane_shown(p); t != nil do return editor_of(t.id)
	return nil
}

pane_browser :: proc(p: ^Pane) -> ^Browser {
	if t := pane_shown(p); t != nil do return browsers[t.id]
	return nil
}

pane_app :: proc(p: ^Pane) -> ^App_Proc {
	if t := pane_shown(p); t != nil do return app_of(t.id)
	return nil
}

// Pane p's content rect (framebuffer px): its laid-out rect, else the one the window last laid
// out (app.pane).
pane_rect :: proc(p: ^Pane) -> [4]f32 {
	if p != nil && p.rect.z > 0 do return p.rect
	return app.pane
}

// The pane of the current session whose content holds the point (framebuffer px), or nil. With
// no pane laid out yet: the focused pane.
pane_at :: proc(x, y: f32) -> ^Pane {
	s := cur()
	if s == nil do return nil
	laid := false
	for &p in s.panes {
		r := p.frame.z > 0 ? p.frame : p.rect
		if r.z <= 0 do continue
		laid = true
		if x >= r.x && y >= r.y && x < r.x + r.z && y < r.y + r.w do return &p
	}
	return laid ? nil : session_focused_pane(s)
}

// Where tab `tab_id` is drawn (framebuffer px): in the current session its pane's laid-out
// rect; else (another session, or not laid out yet) its pane's place in the session's tree
// inside the rect the window last laid out (app.pane), what it will get when shown.
tab_rect :: proc(tab_id: u64) -> [4]f32 {
	s, tab, _ := find_tab(tab_id)
	if tab == nil do return app.pane
	p := session_pane(s, tab.pane)
	if p == nil do return app.pane
	if s.id == state.current_session && p.rect.z > 0 do return p.rect
	centre := app.centre.z > 0 ? app.centre : app.pane
	if centre.z <= 0 do return app.pane
	if len(s.panes) <= 1 do return app.pane // one pane: its content is the centre's (under the session's bars)
	// the pane's place in the tree, less its strip (its tab's bars are not counted)
	for r in pane_rects(s, centre, px(BORDER_W), px(PANE_MIN_W), px(PANE_MIN_H)) do if r.pane == p.id {
		strip := min(px(TAB_STRIP_H), r.rect.w)
		return {r.rect.x, r.rect.y + strip, r.rect.z, r.rect.w - strip}
	}
	return app.pane
}
