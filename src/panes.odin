package main

import "core:fmt"
import clay "../build/clay-odin"

// Panes: an open session's tabs side by side (docs/plans/split-panes.md).
//
// Each open session has a binary layout tree (Open_Session.nodes, nodes[root]) whose leaves are
// its panes (Open_Session.panes). A pane shows one of its tabs (Pane.active); a tab knows its
// pane (Tab.pane), so a pane's strip is s.tabs filtered by pane and every loop over s.tabs still
// sees every tab. One pane is focused (Open_Session.focused_pane): its active tab is the one
// active_tab(), key_tab(), every action and every tick that means "the keyboard's tab" use, and
// s.active_tab mirrors it for the snapshot and the many readers of that field.
//
// Two words, two helpers, nothing implicit:
//   - focused (tab_focused): the focused pane's active tab of the current session;
//   - on screen (tab_on_screen): the active tab of any pane of the current session.
// Ticks loop over tabs and ask one of them. With one pane they are the same tab.
//
// For now every session has exactly one pane and no command splits it: the tree operations
// below are complete and tested, the commands, layout and keys come later (the plan's P2).
//
// All writes go through these helpers: session_panes_init (a new session), session_show_tab
// (a tab comes to the front), pane_add_tab (a new tab), pane_tab_gone (a tab closed),
// pane_split / pane_remove / pane_close / pane_move_tab (the tree). session_check says whether a
// session keeps the invariants (tests run it after commands).
//
// A session with no panes at all (a test's literal, a session read back from a snapshot, one
// being built) reads as one implicit pane holding every tab, its active tab s.active_tab; its
// first write gives it its real pane.

PANES_MAX :: 8 // panes per session
RATIO_MIN :: 0.05 // a split's share of either child, at least

Pane :: struct {
	id:     u64, // new_id(); runtime only
	active: u64, // the tab it shows (always one of its tabs)
	rect:   [4]f32, // its content's last laid-out rect (framebuffer px: x, y, w, h); {} = not laid out
	slot:   int, // its place among the session's leaves, left to right, top to bottom (Clay ids, scripts)
}

// Right: children side by side (a vertical divider); Down: stacked.
Split_Dir :: enum {
	Right,
	Down,
}

// Directions to a neighbouring pane.
Pane_Dir :: enum {
	Left,
	Right,
	Up,
	Down,
}

Layout_Node :: struct {
	id:     u64, // a leaf: its pane's id; a split: its own (a divider is addressed by it)
	leaf:   bool,
	pane:   u64, // leaf
	dir:    Split_Dir, // split
	ratio:  f32, // split: child a's share, in [RATIO_MIN, 1 - RATIO_MIN]
	a, b:   int, // split: indices into nodes
	parent: int, // -1 = the root
}

// ---- reading ----

session_pane :: proc(s: ^Open_Session, id: u64) -> ^Pane {
	if s == nil do return nil
	for &p in s.panes do if p.id == id do return &p
	return nil
}

// The session's focused pane (nil: no session). A session with no panes yet gets its implicit
// one (id 0, slot 0, showing s.active_tab): a copy, only for reading.
session_focused_pane :: proc(s: ^Open_Session) -> ^Pane {
	if s == nil do return nil
	if p := session_pane(s, s.focused_pane); p != nil do return p
	if len(s.panes) > 0 do return &s.panes[0]
	implicit_pane = Pane{active = s.active_tab}
	return &implicit_pane
}

@(private = "file")
implicit_pane: Pane

// The current session's focused pane, or nil.
focused_pane :: proc() -> ^Pane {return session_focused_pane(cur())}

// The pane holding tab `tab_id` of s, or nil.
pane_of_tab :: proc(s: ^Open_Session, tab_id: u64) -> ^Pane {
	if s == nil do return nil
	for t in s.tabs do if t.id == tab_id do return session_pane(s, t.pane)
	return nil
}

// The id of the tab the session's focused pane shows (0 = none).
session_focused_id :: proc(s: ^Open_Session) -> u64 {
	if s == nil do return 0
	if p := session_focused_pane(s); p != nil do return p.active
	return s.active_tab // no panes yet: the one implicit pane
}

// The session's focused tab, or nil.
session_focused_tab :: proc(s: ^Open_Session) -> ^Tab {
	id := session_focused_id(s)
	if id == 0 do return nil
	for &t in s.tabs do if t.id == id do return &t
	return nil
}

// Tab `tab_id` is the active tab of one of s's panes (shown when s is on screen).
session_tab_shown :: proc(s: ^Open_Session, tab_id: u64) -> bool {
	if s == nil || tab_id == 0 do return false
	if len(s.panes) == 0 do return s.active_tab == tab_id
	for p in s.panes do if p.active == tab_id do return true
	return false
}

// The tab gets the keyboard's actions: the focused pane's active tab of the current session.
tab_focused :: proc(tab_id: u64) -> bool {
	return tab_id != 0 && session_focused_id(cur()) == tab_id
}

// The tab is on screen: the active tab of any pane of the current session.
tab_on_screen :: proc(tab_id: u64) -> bool {
	return session_tab_shown(cur(), tab_id)
}

// The tab a pane shows, or nil.
pane_tab :: proc(s: ^Open_Session, p: ^Pane) -> ^Tab {
	if s == nil || p == nil do return nil
	for &t in s.tabs do if t.id == p.active do return &t
	return nil
}

// What pane p of the current session shows (the layout's panes are always the current
// session's), by kind; nil when it shows another kind or nothing. The bars and handlers of the
// layout and event layer resolve their tab through these, never through the focused accessors.
pane_shown :: proc(p: ^Pane) -> ^Tab {return pane_tab(cur(), p)}
pane_term :: proc(p: ^Pane) -> ^Term {
	if t := pane_shown(p); t != nil do return term_of(t.id)
	return nil
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
pane_changes :: proc(p: ^Pane) -> ^Changes_View {
	t := pane_shown(p)
	if t == nil do return nil
	if _, is := t.kind.(Changes_Tab); !is do return nil
	return changes_view(t.id)
}

// The ids of pane p's tabs in strip order (p nil or implicit: every tab of s). Temp-allocated.
pane_strip :: proc(s: ^Open_Session, p: ^Pane) -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	if s == nil do return out[:]
	for t in s.tabs do if p == nil || p.id == 0 || t.pane == p.id do append(&out, t.id)
	return out[:]
}

// Pane p's content rect (framebuffer px): its laid-out rect, else the one the window last laid
// out (app.pane).
pane_rect :: proc(p: ^Pane) -> [4]f32 {
	if p != nil && p.rect.z > 0 do return p.rect
	return app.pane
}

// How many tabs pane `pane_id` holds.
pane_tab_count :: proc(s: ^Open_Session, pane_id: u64) -> int {
	n := 0
	for t in s.tabs do if t.pane == pane_id do n += 1
	return n
}

// The pane of the current session whose content holds the point (framebuffer px), or nil. With
// no pane laid out yet: the focused pane.
pane_at :: proc(x, y: f32) -> ^Pane {
	s := cur()
	if s == nil do return nil
	laid := false
	for &p in s.panes {
		r := p.rect
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
	if app.pane.z <= 0 do return app.pane
	for r in pane_rects(s, app.pane, 0, 0, 0) do if r.pane == p.id do return r.rect
	return app.pane
}

// A Clay id for an element of pane p: slot 0 gives exactly clay.ID(name) (clay.ID(x) is
// clay.ID(x, 0)), so a session with one pane keeps every id scripts and tests click.
pid :: proc(p: ^Pane, name: string) -> clay.ElementId {
	return clay.ID(name, u32(p != nil ? p.slot : 0))
}

// pid for an element that already takes an index (rows, buttons): the slot in the high bits.
pidi :: proc(p: ^Pane, name: string, i: int) -> clay.ElementId {
	return clay.ID(name, u32((p != nil ? p.slot : 0) << 16 | (i & 0xffff)))
}

// ---- writing ----

// Gives a session its one pane, holding every tab, showing s.active_tab (else its first tab).
// Every session made gets it (open_new_session, Restore_Session, Home, Claude's); a session that
// already has panes keeps them.
session_panes_init :: proc(s: ^Open_Session) {
	if len(s.panes) > 0 do return
	p := Pane{id = new_id(), active = s.active_tab}
	if p.active == 0 && len(s.tabs) > 0 do p.active = s.tabs[0].id
	append(&s.panes, p)
	clear(&s.nodes)
	append(&s.nodes, Layout_Node{id = p.id, leaf = true, pane = p.id, parent = -1})
	s.root = 0
	s.focused_pane = p.id
	clear(&s.pane_mru)
	append(&s.pane_mru, p.id)
	for &t in s.tabs do t.pane = p.id
	s.active_tab = p.active
}

// Frees a session's panes (close_session).
session_panes_free :: proc(s: ^Open_Session) {
	delete(s.panes)
	delete(s.nodes)
	delete(s.pane_mru)
	s.panes, s.nodes, s.pane_mru = {}, {}, {}
	s.focused_pane, s.root = 0, 0
}

// Keeps s.active_tab equal to the focused pane's active tab.
@(private = "file")
mirror_sync :: proc(s: ^Open_Session) {
	if p := session_focused_pane(s); p != nil do s.active_tab = p.active
}

// Tab `tab_id` comes to the front of its pane; focus: its pane is focused too (the tab gets the
// keyboard: s.active_tab). A background open never calls this (pane_add_tab alone).
session_show_tab :: proc(s: ^Open_Session, tab_id: u64, focus := true) {
	if s == nil do return
	session_panes_init(s)
	p := pane_of_tab(s, tab_id)
	if p == nil do return
	p.active = tab_id
	if focus do pane_focus(s, p.id)
	mirror_sync(s)
}

// Pane `pane_id` gets the keyboard (most recent in pane_mru).
pane_focus :: proc(s: ^Open_Session, pane_id: u64) {
	if session_pane(s, pane_id) == nil do return
	s.focused_pane = pane_id
	for id, i in s.pane_mru do if id == pane_id {
		ordered_remove(&s.pane_mru, i)
		break
	}
	append(&s.pane_mru, pane_id)
	mirror_sync(s)
}

// Adds a new tab to s and returns it. It goes into pane `pane` (0: the focused one) at the end of
// s.tabs, or, with `after`, right after that tab in its pane. It is not shown: the caller brings
// it to the front with session_show_tab (a background open does not).
pane_add_tab :: proc(s: ^Open_Session, tab: Tab, pane: u64 = 0, after: u64 = 0) -> ^Tab {
	session_panes_init(s)
	t := tab
	at := len(s.tabs)
	t.pane = pane
	if after != 0 do for o, i in s.tabs do if o.id == after {
		at = i + 1
		t.pane = o.pane
		break
	}
	if session_pane(s, t.pane) == nil {
		fp := session_focused_pane(s)
		t.pane = fp != nil ? fp.id : 0
	}
	at = max(at, min(1, len(s.tabs))) // the main tab stays tabs[0]
	inject_at(&s.tabs, at, t)
	if p := session_pane(s, t.pane); p != nil && p.active == 0 do p.active = t.id // an empty pane (being built) shows it
	mirror_sync(s)
	return &s.tabs[at]
}

// Tab `tab_id` (at index i of s.tabs, still there) is about to be removed: when its pane shows
// it, the pane's next tab takes over (else its previous one: the last tab's rule), within the
// pane. A pane it leaves empty closes (pane_remove). Call before removing it from s.tabs.
pane_tab_gone :: proc(s: ^Open_Session, tab_id: u64) {
	p := pane_of_tab(s, tab_id)
	if p == nil do return
	pane_id := p.id
	if p.active == tab_id {
		p.active = pane_next_tab(s, pane_id, tab_id)
		mirror_sync(s)
	}
	if p.active == 0 && len(s.panes) > 1 do pane_remove(s, pane_id)
}

// The tab of pane `pane_id` that takes over from `gone`: the one after it in the pane, else the
// one before (0: none left).
@(private = "file")
pane_next_tab :: proc(s: ^Open_Session, pane_id, gone: u64) -> u64 {
	prev: u64
	past := false
	for t in s.tabs {
		if t.pane != pane_id do continue
		if t.id == gone {
			past = true
			continue
		}
		if past do return t.id
		prev = t.id
	}
	return prev
}

// ---- the tree ----

// Splits pane `pane_id` in direction dir: its leaf becomes a split of the old pane and a new,
// empty pane (ratio 0.5); first: the new pane comes first (left of or above the old one). Returns
// the new pane's id, 0 when refused (Home, no such pane, PANES_MAX). The caller gives the new
// pane a tab (pane_add_tab or pane_move_tab) before anything reads it.
pane_split :: proc(s: ^Open_Session, pane_id: u64, dir: Split_Dir, first := false) -> u64 {
	if s == nil || s.home || len(s.panes) >= PANES_MAX do return 0
	session_panes_init(s)
	leaf := node_of_pane(s, pane_id)
	if leaf < 0 do return 0
	np := Pane{id = new_id()}
	append(&s.panes, np)
	old := s.nodes[leaf]
	nl := len(s.nodes)
	append(&s.nodes, Layout_Node{id = old.id, leaf = true, pane = old.pane, parent = leaf}) // the old pane, moved down
	append(&s.nodes, Layout_Node{id = np.id, leaf = true, pane = np.id, parent = leaf})
	a, b := nl, nl + 1
	if first do a, b = b, a
	s.nodes[leaf] = Layout_Node{id = new_id(), dir = dir, ratio = 0.5, a = a, b = b, parent = old.parent}
	panes_reslot(s)
	return np.id
}

// Removes pane `pane_id` from the tree (its tabs must have gone or moved): its sibling takes the
// parent's place. Focus, if it had it, goes to the most recently focused pane left. The last pane
// is never removed.
pane_remove :: proc(s: ^Open_Session, pane_id: u64) {
	if s == nil || len(s.panes) <= 1 do return
	leaf := node_of_pane(s, pane_id)
	if leaf < 0 do return
	parent := s.nodes[leaf].parent
	if parent < 0 do return
	sib := s.nodes[parent].a == leaf ? s.nodes[parent].b : s.nodes[parent].a
	// the sibling's subtree moves up into the parent's slot
	moved := s.nodes[sib]
	moved.parent = s.nodes[parent].parent
	s.nodes[parent] = moved
	if !moved.leaf {
		s.nodes[moved.a].parent = parent
		s.nodes[moved.b].parent = parent
	}
	nodes_drop(s, {leaf, sib})
	for p, i in s.panes do if p.id == pane_id {
		ordered_remove(&s.panes, i)
		break
	}
	for id, i in s.pane_mru do if id == pane_id {
		ordered_remove(&s.pane_mru, i)
		break
	}
	if s.focused_pane == pane_id {
		next: u64
		if len(s.pane_mru) > 0 do next = s.pane_mru[len(s.pane_mru) - 1]
		if session_pane(s, next) == nil do next = s.panes[0].id
		pane_focus(s, next)
	}
	panes_reslot(s)
	mirror_sync(s)
}

// Unsplits pane `pane_id`: its tabs join the nearest pane of its sibling (after that pane's
// tabs; the pane's active tab is active there), then it is removed. Nothing stops.
pane_close :: proc(s: ^Open_Session, pane_id: u64) {
	if s == nil || len(s.panes) <= 1 do return
	leaf := node_of_pane(s, pane_id)
	if leaf < 0 || s.nodes[leaf].parent < 0 do return
	parent := s.nodes[leaf].parent
	is_a := s.nodes[parent].a == leaf
	sib := is_a ? s.nodes[parent].b : s.nodes[parent].a
	// the sibling's leaf next to the closing pane: its first when the pane was before it, else its last
	to := sib
	for !s.nodes[to].leaf do to = is_a ? s.nodes[to].a : s.nodes[to].b
	target := s.nodes[to].pane
	p := session_pane(s, pane_id)
	shown := p.active
	moving := make([dynamic]u64, context.temp_allocator)
	for t in s.tabs do if t.pane == pane_id do append(&moving, t.id)
	for id in moving do pane_move_tab(s, id, target, remove_empty = false)
	if tp := session_pane(s, target); tp != nil && shown != 0 do tp.active = shown
	focused := s.focused_pane == pane_id
	pane_remove(s, pane_id)
	if focused do pane_focus(s, target)
	mirror_sync(s)
}

// Moves tab `tab_id` into pane `to` of its session, at strip position `index` there (-1: the
// end), or reorders it within its pane. It is shown in `to`; the pane it left hands over (the
// same rule as a close) and closes when empty (remove_empty). The main tab stays tabs[0]: it is
// never moved within s.tabs (only its pane changes), and another tab never lands before it.
pane_move_tab :: proc(s: ^Open_Session, tab_id: u64, to: u64, index := -1, remove_empty := true) -> bool {
	if s == nil || session_pane(s, to) == nil do return false
	from_i := -1
	for t, i in s.tabs do if t.id == tab_id do from_i = i
	if from_i < 0 do return false
	from := s.tabs[from_i].pane
	if from != to {
		if p := session_pane(s, from); p != nil && p.active == tab_id do p.active = pane_next_tab(s, from, tab_id)
	}
	if from_i > 0 {
		tab := s.tabs[from_i]
		ordered_remove(&s.tabs, from_i)
		// strip position `index` in `to` (without the tab): before the index-th tab of that pane, else after its last
		at := -1
		n, last := 0, -1
		for t, i in s.tabs {
			if t.pane != to do continue
			if n == index do at = i
			n += 1
			last = i
		}
		if at < 0 do at = last >= 0 ? last + 1 : len(s.tabs)
		at = max(at, 1)
		tab.pane = to
		inject_at(&s.tabs, at, tab)
	} else {
		s.tabs[0].pane = to
	}
	if tp := session_pane(s, to); tp != nil do tp.active = tab_id
	if from != to && remove_empty {
		if fp := session_pane(s, from); fp != nil && fp.active == 0 do pane_remove(s, from)
	}
	mirror_sync(s)
	return true
}

// The neighbouring pane of `pane_id` in direction dir: of the panes whose centre lies that way,
// the nearest (by the tree's geometry, not the window's). 0 = none.
pane_neighbour :: proc(s: ^Open_Session, pane_id: u64, dir: Pane_Dir) -> u64 {
	rects := pane_rects(s, {0, 0, 1000, 1000}, 0, 0, 0)
	from: [4]f32
	found := false
	for r in rects do if r.pane == pane_id {
		from = r.rect
		found = true
	}
	if !found do return 0
	cx, cy := from.x + from.z / 2, from.y + from.w / 2
	best: u64
	best_d := f32(1e9)
	for r in rects {
		if r.pane == pane_id do continue
		x, y := r.rect.x + r.rect.z / 2, r.rect.y + r.rect.w / 2
		dx, dy := x - cx, y - cy
		ok := false
		switch dir {
		case .Left:  ok = r.rect.x + r.rect.z <= from.x + 0.5
		case .Right: ok = r.rect.x >= from.x + from.z - 0.5
		case .Up:    ok = r.rect.y + r.rect.w <= from.y + 0.5
		case .Down:  ok = r.rect.y >= from.y + from.w - 0.5
		}
		if !ok do continue
		d := dx * dx + dy * dy
		if d < best_d {
			best, best_d = r.pane, d
		}
	}
	return best
}

Pane_Rect :: struct {
	pane: u64,
	rect: [4]f32,
}

// Every pane's rect inside `rect` (x, y, w, h), in leaf order: a split gives child a its ratio of
// the room left after the divider (`divider` px), kept so neither child is under its minimum
// (min_w, min_h per pane, summed along the split); when the room is too small for both minimums,
// the ratio alone decides (panes are squeezed, never hidden). Temp-allocated.
pane_rects :: proc(s: ^Open_Session, rect: [4]f32, divider, min_w, min_h: f32) -> []Pane_Rect {
	out := make([dynamic]Pane_Rect, context.temp_allocator)
	if s == nil do return out[:]
	if len(s.nodes) == 0 {
		for p in s.panes do append(&out, Pane_Rect{p.id, rect})
		return out[:]
	}
	walk :: proc(s: ^Open_Session, n: int, r: [4]f32, div, mw, mh: f32, out: ^[dynamic]Pane_Rect) {
		node := s.nodes[n]
		if node.leaf {
			append(out, Pane_Rect{node.pane, r})
			return
		}
		across := node.dir == .Right
		total := (across ? r.z : r.w) - div
		ma := node_min(s, node.a, across, div, across ? mw : mh)
		mb := node_min(s, node.b, across, div, across ? mw : mh)
		la := total * node.ratio
		if total >= ma + mb do la = clamp(la, ma, total - mb)
		la = max(la, 0)
		lb := max(total - la, 0)
		if across {
			walk(s, node.a, {r.x, r.y, la, r.w}, div, mw, mh, out)
			walk(s, node.b, {r.x + la + div, r.y, lb, r.w}, div, mw, mh, out)
		} else {
			walk(s, node.a, {r.x, r.y, r.z, la}, div, mw, mh, out)
			walk(s, node.b, {r.x, r.y + la + div, r.z, lb}, div, mw, mh, out)
		}
	}
	walk(s, s.root, rect, divider, min_w, min_h, &out)
	return out[:]
}

// The least size of node n's subtree along one axis (across: widths), m per pane.
@(private = "file")
node_min :: proc(s: ^Open_Session, n: int, across: bool, div, m: f32) -> f32 {
	node := s.nodes[n]
	if node.leaf do return m
	a, b := node_min(s, node.a, across, div, m), node_min(s, node.b, across, div, m)
	if (node.dir == .Right) == across do return a + div + b
	return max(a, b)
}

// Sets a split's ratio, clamped to [RATIO_MIN, 1 - RATIO_MIN]. False: no such split.
pane_set_ratio :: proc(s: ^Open_Session, split: u64, ratio: f32) -> bool {
	for &n in s.nodes do if !n.leaf && n.id == split {
		n.ratio = clamp(ratio, RATIO_MIN, 1 - RATIO_MIN)
		return true
	}
	return false
}

// The leaves' panes in order (left to right, top to bottom). Temp-allocated.
pane_leaf_order :: proc(s: ^Open_Session) -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	if s == nil || len(s.nodes) == 0 do return out[:]
	walk :: proc(s: ^Open_Session, n: int, out: ^[dynamic]u64) {
		if s.nodes[n].leaf {
			append(out, s.nodes[n].pane)
			return
		}
		walk(s, s.nodes[n].a, out)
		walk(s, s.nodes[n].b, out)
	}
	walk(s, s.root, &out)
	return out[:]
}

// Puts s.panes in leaf order and numbers their slots.
@(private = "file")
panes_reslot :: proc(s: ^Open_Session) {
	order := pane_leaf_order(s)
	for id, i in order {
		for j in i ..< len(s.panes) do if s.panes[j].id == id {
			if j != i do s.panes[i], s.panes[j] = s.panes[j], s.panes[i]
			break
		}
		s.panes[i].slot = i
	}
}

// The index in s.nodes of pane `pane_id`'s leaf, -1 = none.
@(private = "file")
node_of_pane :: proc(s: ^Open_Session, pane_id: u64) -> int {
	for n, i in s.nodes do if n.leaf && n.pane == pane_id do return i
	return -1
}

// Takes nodes out of s.nodes, fixing every index into it.
@(private = "file")
nodes_drop :: proc(s: ^Open_Session, drop: []int) {
	remap := make([]int, len(s.nodes), context.temp_allocator)
	j := 0
	for i in 0 ..< len(s.nodes) {
		gone := false
		for d in drop do if d == i do gone = true
		remap[i] = gone ? -1 : j
		if !gone do j += 1
	}
	kept := make([dynamic]Layout_Node, 0, j)
	for n, i in s.nodes {
		if remap[i] < 0 do continue
		m := n
		if m.parent >= 0 do m.parent = remap[m.parent]
		if !m.leaf {
			m.a, m.b = remap[m.a], remap[m.b]
		}
		append(&kept, m)
	}
	s.root = remap[s.root]
	delete(s.nodes)
	s.nodes = kept
}

// ---- checks ----

// What is wrong with s's panes ("" = nothing; a session with no panes yet is whole): every tab in
// one of its panes; every pane with a
// tab, showing one of its own; s.active_tab the focused pane's; the tree's leaves exactly the
// panes, parents and ratios right; at most PANES_MAX; Home one pane; the main tab first.
session_check :: proc(s: ^Open_Session) -> string {
	if s == nil || len(s.panes) == 0 do return "" // no panes yet: its implicit one, whole by definition
	if len(s.panes) > PANES_MAX do return fmt.tprintf("%d panes", len(s.panes))
	if s.home && len(s.panes) != 1 do return "Home split"
	for t in s.tabs do if session_pane(s, t.pane) == nil do return fmt.tprintf("tab %d in no pane (%d)", t.id, t.pane)
	for p in s.panes {
		n := pane_tab_count(s, p.id)
		if n == 0 do return fmt.tprintf("pane %d has no tab", p.id)
		owner := pane_of_tab(s, p.active)
		if owner == nil || owner.id != p.id do return fmt.tprintf("pane %d shows tab %d, not one of its own", p.id, p.active)
	}
	fp := session_pane(s, s.focused_pane)
	if fp == nil do return "no focused pane"
	if s.active_tab != fp.active do return fmt.tprintf("active_tab %d is not the focused pane's %d", s.active_tab, fp.active)
	if s.root < 0 || s.root >= len(s.nodes) || s.nodes[s.root].parent != -1 do return "bad root"
	leaves := 0
	for n, i in s.nodes {
		if n.leaf {
			leaves += 1
			if session_pane(s, n.pane) == nil do return fmt.tprintf("leaf %d: no pane %d", i, n.pane)
			continue
		}
		if n.a < 0 || n.a >= len(s.nodes) || n.b < 0 || n.b >= len(s.nodes) do return fmt.tprintf("split %d: bad children", i)
		if s.nodes[n.a].parent != i || s.nodes[n.b].parent != i do return fmt.tprintf("split %d: children's parent", i)
		if n.ratio < RATIO_MIN || n.ratio > 1 - RATIO_MIN do return fmt.tprintf("split %d: ratio %v", i, n.ratio)
	}
	if leaves != len(s.panes) || len(pane_leaf_order(s)) != len(s.panes) do return "leaves are not the panes"
	for p, i in s.panes do if p.slot != i do return fmt.tprintf("pane %d: slot %d at %d", p.id, p.slot, i)
	return ""
}
