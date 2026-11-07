package main

import "core:fmt"
import clay "../build/clay-odin"

// The pane commands (docs/PROTOCOL.md "Panes"; docs/plans/split-panes.md §4): split_pane,
// close_pane, focus_pane, move_tab, set_split, equalize_panes. Who: Anyone (the user, scripts,
// control callers), never a pi or Claude tab's bridge nor an app (who_allows): agents do not
// change the layout. Home has one pane and is refused. Panes are not saved yet (the plan's P3).

panes_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Split_Pane:
		s, p := pane_find(c.pane)
		if p == nil do return fail("no such pane"), false
		if s.home do return fail(HOME_NOT_A_SESSION), false
		if len(s.panes) >= PANES_MAX do return fail(fmt.tprintf("at most %d panes", PANES_MAX)), false
		if !pane_has_room(s, p.id, c.direction) do return fail("not enough room"), false
		moving: ^Tab
		if c.tab_id != 0 {
			ts, tab, _ := find_tab(c.tab_id)
			if tab == nil || ts.id != s.id do return fail("no such tab in this pane's session"), false
			if pane_tab_count(s, tab.pane) <= 1 && tab.pane == p.id do return fail("a pane's only tab cannot move to a new pane"), false
			moving = tab
		}
		split, first := pane_split_dir(c.direction)
		np := pane_split(s, p.id, split, first)
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

// Pane `pane` of s can be split that way: once laid out, every pane keeps PANE_MIN_W x PANE_MIN_H
// (the split one's two halves, and every other pane along that axis). The split pane's own room
// too (pane_rects squeezes a tree whose minimums do not fit). Not laid out (no window yet,
// tests): yes.
pane_has_room :: proc(s: ^Open_Session, pane: u64, d: Pane_Dir) -> bool {
	if app.centre.z <= 0 || app.dpi <= 0 do return true
	across := d == .Left || d == .Right
	div, mw, mh := px(BORDER_W), px(PANE_MIN_W), px(PANE_MIN_H)
	if pane_room_need(s, pane, across, div, mw, mh) > (across ? app.centre.z : app.centre.w) + 0.5 do return false
	for r in pane_rects(s, app.centre, div, mw, mh) do if r.pane == pane {
		size := across ? r.rect.z : r.rect.w
		return size + 0.5 >= 2 * (across ? mw : mh) + div
	}
	return true
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
		d := clay.GetElementData(clay.ID("pane_split", u32(split)))
		if !d.found || s.id != state.current_session do return ratio
		total := (n.dir == .Right ? d.boundingBox.width : d.boundingBox.height) - px(BORDER_W)
		return pane_split_share(s, i, ratio, total)
	}
	return ratio
}
