package main

import "core:fmt"

// A restored session's saved panes (docs/PERSISTENCE.md "Panes"; docs/plans/split-panes.md §1.4).
//
// The tabs always come back from the saved tab list (restore_tabs, commands.odin); the layout
// only says where they sit. persist.odin's panes_parse already turned a malformed `panes` key
// into no layout, clamped the ratios and checked the tree's shape; what is left here is what only
// the restore knows, which tabs came back:
//   - a tab whose saved pane is not known (-1) goes to the focused pane;
//   - a pane shows the tab it showed; else (that tab did not come back, or the file does not
//     say) the session's saved active tab (active_tab) if it is there; else its first tab;
//   - a pane left without tabs goes, its sibling taking its parent's place; when it had the
//     keyboard, the first pane left gets it;
//   - anything still wrong (session_check) gives the one pane restore_tabs made, as if the file
//     had no layout.

// A restored tab and where it was saved.
Restore_Place :: struct {
	tab:    u64, // its tab id
	pane:   int, // its saved pane (-1 = not known)
	active: bool, // its pane showed it
}

// Gives s (its tabs restored into one pane, s.active_tab the saved active tab) the saved
// layout. No layout, or one pane: s stays as it is.
restore_panes :: proc(s: ^Open_Session, layout: Restore_Layout, places: []Restore_Place) {
	n := layout.panes
	if len(layout.nodes) == 0 || n <= 1 || n > PANES_MAX || len(layout.nodes) != 2 * n - 1 || s.home do return
	one_pane_active := s.active_tab

	// the tree, checked again: a tree (each node below its parent, one parent each), every pane one leaf
	seen := make([]bool, n, context.temp_allocator)
	parent := make([]int, len(layout.nodes), context.temp_allocator)
	for &x in parent do x = -1
	for rn, i in layout.nodes {
		if rn.leaf {
			if rn.pane < 0 || rn.pane >= n || seen[rn.pane] do return
			seen[rn.pane] = true
			continue
		}
		for c in ([2]int{rn.a, rn.b}) {
			if c <= i || c >= len(layout.nodes) || parent[c] >= 0 do return
			parent[c] = i
		}
	}
	for x in seen do if !x do return

	ids := make([]u64, n, context.temp_allocator)
	for &id in ids do id = new_id()
	panes := make([dynamic]Pane, 0, n)
	for id in ids do append(&panes, Pane{id = id})
	nodes := make([dynamic]Layout_Node, 0, len(layout.nodes))
	for rn, i in layout.nodes {
		if rn.leaf do append(&nodes, Layout_Node{id = ids[rn.pane], leaf = true, pane = ids[rn.pane], parent = parent[i]})
		else do append(&nodes, Layout_Node{id = new_id(), dir = rn.dir, ratio = clamp(rn.ratio, RATIO_MIN, 1 - RATIO_MIN), a = rn.a, b = rn.b, parent = parent[i]})
	}
	delete(s.panes)
	delete(s.nodes)
	s.panes, s.nodes, s.root = panes, nodes, 0
	focus := ids[clamp(layout.focused, 0, n - 1)]

	// every tab into its saved pane (not known: the focused one)
	for &t in s.tabs {
		t.pane = focus
		for pl in places do if pl.tab == t.id {
			if pl.pane >= 0 && pl.pane < n do t.pane = ids[pl.pane]
			break
		}
	}
	// each pane's shown tab: the one it showed; else the session's saved active tab when it is
	// there; else its first
	for &p in s.panes {
		for pl in places do if pl.active {
			if owner := pane_of_tab(s, pl.tab); owner != nil && owner.id == p.id {
				p.active = pl.tab
				break
			}
		}
		if p.active == 0 do if owner := pane_of_tab(s, one_pane_active); owner != nil && owner.id == p.id do p.active = one_pane_active
		if p.active == 0 do for t in s.tabs do if t.pane == p.id {
			p.active = t.id
			break
		}
	}

	// panes whose tabs all failed to come back go; the tree closes over them
	s.focused_pane = focus
	clear(&s.pane_mru)
	append(&s.pane_mru, focus)
	panes_drop_empty(s)
	// leaf order and slots
	order := pane_leaf_order(s)
	sorted := make([dynamic]Pane, 0, len(s.panes))
	for id, i in order do for p in s.panes do if p.id == id {
		q := p
		q.slot = i
		append(&sorted, q)
	}
	delete(s.panes)
	s.panes = sorted
	if session_pane(s, focus) == nil && len(order) > 0 do focus = order[0]
	clear(&s.pane_mru)
	s.focused_pane = 0
	pane_focus(s, focus)

	if err := session_check(s); err != "" {
		fmt.eprintln("Deckhand: a saved pane layout was not restored:", err)
		session_panes_free(s)
		s.active_tab = one_pane_active
		session_panes_init(s)
	}
}

// Removes s's panes that hold no tab (pane_remove: the tree closes over each), never the last;
// stops at one pane_remove cannot take.
panes_drop_empty :: proc(s: ^Open_Session) {
	for {
		empty: u64
		for p in s.panes do if pane_tab_count(s, p.id) == 0 do empty = p.id
		if empty == 0 || len(s.panes) <= 1 do break
		n := len(s.panes)
		pane_remove(s, empty)
		if len(s.panes) == n do break // not removable (not in the tree): session_check refuses s
	}
}
