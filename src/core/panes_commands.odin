package core

import "core:fmt"
import "core:slice"

// The pane commands (docs/PROTOCOL.md "Panes"; docs/plans/split-panes.md §4): split_pane,
// close_pane, focus_pane, move_tab, set_split, equalize_panes, zoom_pane. Who: Anyone (the user, scripts,
// control callers), never a pi or Claude tab's bridge nor an app (who_allows): agents do not
// change the layout. Home has one pane and is refused. The layout is saved per session
// (persist.odin write_panes; restored by panes_restore.odin).

panes_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Split_Pane:
		s, p := pane_find(c.pane)
		if p == nil do return fail("no such pane"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		moving: ^Tab
		leaving: u64 // the pane the moving tab empties (it closes): the split adds no pane then
		if c.tab_id != 0 {
			ts, tab, _ := find_tab(c.tab_id)
			if tab == nil || ts.id != s.id do return fail("no such tab in this pane's session"), false
			if pane_tab_count(s, tab.pane) <= 1 {
				if tab.pane == p.id do return fail("a pane's only tab cannot move to a new pane"), false
				leaving = tab.pane
			}
			moving = tab
		}
		if len(s.panes) - (leaving != 0 ? 1 : 0) >= PANES_MAX do return fail(fmt.tprintf("at most %d panes", PANES_MAX)), false
		if !pane_has_room_leaving(s, p.id, c.direction, leaving) do return fail("not enough room"), false
		split, first := pane_split_dir(c.direction)
		np := pane_split(s, p.id, split, first, limit = PANES_MAX + (leaving != 0 ? 1 : 0)) // one over for a moment: `leaving` closes below
		if np == 0 do return fail("could not split"), false
		shown: u64
		if moving != nil {
			shown = moving.id
			pane_move_tab(s, shown, np)
		} else {
			id, err := shell_tab_start(s, s.cwd, np)
			if err != "" {
				pane_remove(s, np)
				return fail(err), false
			}
			shown = id
		}
		session_show_tab(s, shown, focus = !c.no_focus)
		if !c.no_focus do focus_session(s.id, caller)
		return {ok = true, created_id = np}, true
	case Close_Pane:
		s, p := pane_find(c.pane)
		if p == nil || c.pane == 0 do return fail("no such pane"), false
		if len(s.panes) <= 1 do return fail("a session's last pane cannot close"), false
		pane_close(s, p.id)
		return {ok = true}, true
	case Focus_Pane:
		target: u64
		s: ^Open_Session
		if c.direction == "" {
			p: ^Pane
			s, p = pane_find(c.pane)
			if p == nil || c.pane == 0 do return fail("no such pane"), false
			target = p.id
		} else {
			if c.pane != 0 do return fail("pane or direction, not both"), false
			fp: ^Pane
			s, fp = pane_find(0)
			if fp == nil do return fail("no session on screen"), false
			switch c.direction {
			case "next", "prev":
				order := pane_leaf_order(s)
				for id, i in order do if id == fp.id {
					target = order[(i + (c.direction == "next" ? 1 : len(order) - 1)) % len(order)]
				}
			case:
				d, ok := pane_dir_parse(c.direction)
				if !ok do return fail("direction: left, right, up, down, next or prev"), false
				target = pane_neighbour(s, fp.id, d)
			}
			if target == 0 || target == fp.id do return fail("no pane that way"), false
		}
		if s.home do return fail(HOME_NOT_A_SESSION), false
		pane_focus(s, target)
		focus_session(s.id, caller)
		return {ok = true}, true
	case Move_Tab:
		s, tab, _ := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		if session_pane(s, c.pane) == nil do return fail("not a pane of the tab's session"), false
		was_focused := session_focused_id(s) == c.tab_id
		pane_move_tab(s, c.tab_id, c.pane, c.index)
		if was_focused do pane_focus(s, c.pane) // the keyboard follows the tab it was on
		return {ok = true}, true
	case Set_Split:
		for &s in state.open_sessions {
			for n in s.nodes do if !n.leaf && n.id == c.split {
				if c.ratio <= 0 || c.ratio >= 1 do return fail("ratio: between 0 and 1"), false
				pane_set_ratio(&s, c.split, pane_ratio_kept(&s, c.split, c.ratio))
				return {ok = true}, true
			}
		}
		return fail("no such split"), false
	case Equalize_Panes:
		s := c.session != 0 ? find_session(c.session) : cur()
		if s == nil do return fail("no such session"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		panes_equalize(s)
		return {ok = true}, true
	case Zoom_Pane:
		s, p := pane_find(c.pane)
		if p == nil do return fail("no such pane"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		zoomed := session_zoomed(s)
		want := c.zoom.? or_else (zoomed != p.id) // unset: toggle this pane's zoom
		if !want {
			if zoomed == 0 do return {ok = true}, false
			s.zoomed_pane = 0 // the layout comes back (whichever pane was zoomed)
			return {ok = true}, true
		}
		if len(s.panes) <= 1 do return fail("one pane: nothing to zoom"), false
		if zoomed == p.id do return {ok = true}, false
		pane_focus(s, p.id) // the zoomed pane has the keyboard (another's zoom ends here)
		s.zoomed_pane = p.id
		focus_session(s.id, caller)
		return {ok = true}, true
	}
	return fail("unknown command"), false
}

// The open session holding pane `id` and the pane; 0: the current session's focused pane.
pane_find :: proc(id: u64) -> (^Open_Session, ^Pane) {
	if id == 0 {
		s := cur()
		if s == nil do return nil, nil
		session_panes_init(s)
		return s, session_pane(s, s.focused_pane)
	}
	for &s in state.open_sessions do if p := session_pane(&s, id); p != nil do return &s, p
	return nil, nil
}

// split_pane's direction: the split, and whether the new pane comes first (left of or above).
pane_split_dir :: proc(d: Pane_Dir) -> (Split_Dir, bool) {
	switch d {
	case .Right: return .Right, false
	case .Left:  return .Right, true
	case .Down:  return .Down, false
	case .Up:    return .Down, true
	}
	return .Right, false
}

// The panes' area as the window last laid it out (its size, framebuffer px) and the window's
// scale: what the room and ratio checks measure against. The window sends it each layout
// (ui_pane_rects); zero = not laid out (no window yet, tests).
Pane_Centre :: struct {
	w, h, scale: f32,
}
pane_centre: Pane_Centre

pane_centre_set :: proc(w, h, scale: f32) {pane_centre = {w, h, scale}}

// The divider and a pane's least width and height at a scale (framebuffer px).
pane_mins :: proc(scale: f32) -> (divider, min_w, min_h: f32) {
	return BORDER_W * scale, PANE_MIN_W * scale, PANE_MIN_H * scale
}

// Pane `pane` of s can be split that way: once laid out, every pane keeps PANE_MIN_W x PANE_MIN_H
// (the split one's two halves, and every other pane along that axis). The split pane's own room
// too (pane_rects squeezes a tree whose minimums do not fit). Not laid out (no window yet,
// tests): yes.
pane_has_room :: proc(s: ^Open_Session, pane: u64, d: Pane_Dir) -> bool {
	c := pane_centre
	if c.w <= 0 || c.scale <= 0 do return true
	across := d == .Left || d == .Right
	div, mw, mh := pane_mins(c.scale)
	if pane_room_need(s, pane, across, div, mw, mh) > (across ? c.w : c.h) + 0.5 do return false
	for r in pane_rects(s, {0, 0, c.w, c.h}, div, mw, mh) do if r.pane == pane {
		size := across ? r.rect.z : r.rect.w
		return size + 0.5 >= 2 * (across ? mw : mh) + div
	}
	return true
}
// pane_has_room once pane `leaving` (0: none) has gone from the tree: a lone tab moving to a new
// pane beside another takes its own pane's room with it. Worked out on a copy of the tree.
pane_has_room_leaving :: proc(s: ^Open_Session, pane: u64, d: Pane_Dir, leaving: u64) -> bool {
	if leaving == 0 || leaving == pane || len(s.panes) <= 1 do return pane_has_room(s, pane, d)
	c := s^
	c.panes = slice.clone_to_dynamic(s.panes[:])
	c.nodes = slice.clone_to_dynamic(s.nodes[:])
	c.pane_mru = slice.clone_to_dynamic(s.pane_mru[:])
	pane_remove(&c, leaving) // touches only the copies (and s.tabs, not at all)
	defer {
		delete(c.panes)
		delete(c.nodes)
		delete(c.pane_mru)
	}
	return pane_has_room(&c, pane, d)
}

// Every divider by the panes on each side along its direction, so equal panes get equal room.
panes_equalize :: proc(s: ^Open_Session) {
	along :: proc(s: ^Open_Session, n: int, dir: Split_Dir) -> int {
		node := s.nodes[n]
		if node.leaf || node.dir != dir do return 1
		return along(s, node.a, dir) + along(s, node.b, dir)
	}
	for &n in s.nodes do if !n.leaf {
		a, b := along(s, n.a, n.dir), along(s, n.b, n.dir)
		n.ratio = clamp(f32(a) / f32(a + b), RATIO_MIN, 1 - RATIO_MIN)
	}
}

// A split's ratio kept so neither side goes under its panes' minimum sizes, at the split's last
// laid-out size (when it was laid out and there is room for both).
pane_ratio_kept :: proc(s: ^Open_Session, split: u64, ratio: f32) -> f32 {
	for n, i in s.nodes {
		if n.leaf || n.id != split do continue
		// laid out only in the current session, and only once the window sent its centre (not
		// before the window, nor in tests)
		c := pane_centre
		if s.id != state.current_session || c.w <= 0 || c.scale <= 0 do return ratio
		div, mw, mh := pane_mins(c.scale)
		r, ok := pane_split_rect(s, split, {0, 0, c.w, c.h}, div, mw, mh)
		if !ok do return ratio
		total := (n.dir == .Right ? r.z : r.w) - div
		return pane_split_share(s, i, ratio, total, c.scale)
	}
	return ratio
}
