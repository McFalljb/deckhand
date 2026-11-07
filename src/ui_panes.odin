package main

import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

// The panes' input (panes.odin; docs/plans/split-panes.md §3.4, §5.2): which pane the pointer is
// for, a pane strip's "+", the "Click to show" placeholder.
//
// The per-tab handlers get the focused pane; the hit tests are the pane's under the pointer
// (hit_pane), so a strip's tab or "+" in any pane is hit there. A press on a placeholder only
// focuses its pane.

// The pane an event at (x, y) is for: the pane under the point, else the focused one (keys; a
// point outside every pane).
event_pane :: proc(e: ^sapp.Event) -> ^Pane {
	s := cur()
	if s == nil do return focused_pane()
	#partial switch e.type {
	case .MOUSE_DOWN, .MOUSE_UP, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_ENTER, .MOUSE_LEAVE:
		if p := pane_at(e.mouse_x, e.mouse_y); p != nil do return p
	}
	return focused_pane()
}

// The pane under the pointer for the hit tests (the last layout's rects), else the focused one.
hit_pane :: proc() -> ^Pane {
	if p := pane_at(app.pointer.x, app.pointer.y); p != nil do return p
	return focused_pane()
}

// A pane strip's "+" under the pointer.
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

// The pointer is over a "Click to show" pane's content (the plan's P4 makes pages and apps live
// in every pane): the page or app under it is not live, so nothing reaches it; a press there only
// focuses the pane. True: the event is used up.
pointer_over_placeholder :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN, .MOUSE_MOVE, .MOUSE_SCROLL, .MOUSE_UP:
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
