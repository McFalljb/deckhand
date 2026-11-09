package main

import "core"

// The window's State (docs/plans/background-core.md §10.2, "Qualified names, no alias file"):
// the core's own today, so the window keeps writing state.x; M3 points it at the window's
// replica. Written by scripts/core-move.py.
state: ^core.State = &core.state

// Atlas's pi runs and its terminal is the core's (what the drawer shows), from the replica.
agent_running :: proc() -> bool {
	for &s in state.open_sessions do if s.id == state.home {
		ht := core.session_pi_tab(&s)
		return ht != nil && ht.status == .Running && ht.has_term
	}
	return false
}

// An open session in the window's replica (what core.find_session is to the core's State).
find_session :: proc(id: u64) -> ^core.Open_Session {
	for &s in state.open_sessions do if s.id == id do return &s
	return nil
}

// The open session in the window's replica holding tab `id`, the tab, and its position in the
// session (what core.find_tab is to the core's State).
find_tab :: proc(id: u64) -> (s: ^core.Open_Session, t: ^core.Tab, index: int) {
	for &os in state.open_sessions {
		for &tab, i in os.tabs do if tab.id == id do return &os, &tab, i
	}
	return nil, nil, -1
}
