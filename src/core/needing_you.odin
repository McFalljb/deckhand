package core

// "Next needing you" (next_needing_you; ⌥⌘A, ⇧⌥⌘A back): the open session that needs the user
// next, on this Mac or on another machine that is online, and the tab in it that does. The core
// picks it from State; the window only sends the command.
//
// The order (needing_you):
//   1. waiting for you: a tab blocked on a permission, a question or a login, or whose agent
//      ended its turn asking something (the Waiting and Question dots);
//   2. stopped with an error (Error);
//   3. finished, not seen yet (Unseen).
// Within a tier: this Mac's sessions, then each online machine's (state.machines' order), each in
// the order they were opened (state.open_sessions). That order does not move when the user visits
// one, so pressing again walks on and wraps round (the Open group's own order puts the current
// session first and the most recently shown next, which would bounce between two). No time is
// used: a tab's status time is not known for every source (Claude Code's hooks, other machines'
// tabs), so "longest waiting first" would rank only some of them.
//
// next_needing_target: the one after the current session in that order (before it, back), wrapping
// round; the first (the last, back) when the current session needs nothing. The current session is
// the target only when it is the only one; then its next needing tab after the focused one. In
// another session, the tab is its most urgent one: the focused tab when that is as urgent, else
// the first in tab order. Home never counts (it is not a session the user steps to). A caller from
// another machine (a hub viewing this one) gets this Mac's sessions only: never a third machine's.

// A tab's tier (0: needs nothing).
NEED_NONE :: 0
NEED_WAITING :: 1
NEED_ERROR :: 2
NEED_UNSEEN :: 3

tab_need :: proc(t: Tab) -> int {
	#partial switch tab_status_view(t).dot {
	case .Waiting, .Question: return NEED_WAITING
	case .Error:              return NEED_ERROR
	case .Unseen:             return NEED_UNSEEN
	}
	return NEED_NONE
}

Needing :: struct {
	session: ^Open_Session,
	tier:    int, // its most urgent tab's
}

// Whether machine no's sessions count: this Mac's always, another machine's while it is online
// (an offline one's rows show what it last sent, not what waits now) and never for a hub.
@(private = "file")
needing_machine_ok :: proc(no: u64, hub: bool) -> bool {
	if no == 0 do return true
	if hub do return false
	for m in state.machines do if m.no == no do return m.status == .Online
	return false
}

// The open sessions that need the user, in the order above (temp allocator).
needing_you :: proc(hub := false) -> []Needing {
	out := make([dynamic]Needing, context.temp_allocator)
	add :: proc(out: ^[dynamic]Needing, no: u64) {
		for &s in state.open_sessions {
			if s.home || s.machine != no do continue
			best := NEED_NONE
			for t in s.tabs do if n := tab_need(t); n != NEED_NONE && (best == NEED_NONE || n < best) do best = n
			if best != NEED_NONE do append(out, Needing{session = &s, tier = best})
		}
	}
	if needing_machine_ok(0, hub) do add(&out, 0)
	for m in state.machines do if needing_machine_ok(m.no, hub) do add(&out, m.no)
	// by tier; stable, so each tier keeps the machines' and the opening order
	for i in 1 ..< len(out) {
		x := out[i]
		j := i
		for j > 0 && out[j - 1].tier > x.tier {
			out[j] = out[j - 1]
			j -= 1
		}
		out[j] = x
	}
	return out[:]
}

// The session and tab next_needing_you goes to; nil: nothing needs the user.
next_needing_target :: proc(back := false, hub := false) -> (s: ^Open_Session, tab: ^Tab) {
	list := needing_you(hub)
	n := len(list)
	if n == 0 do return nil, nil
	at := -1
	for x, i in list do if x.session.id == state.current_session do at = i
	k: int
	switch {
	case at < 0: k = back ? n - 1 : 0
	case back:   k = (at - 1 + n) % n
	case:        k = (at + 1) % n
	}
	s = list[k].session
	focused := session_focused_tab(s)
	if s.id == state.current_session {
		// the only one: its needing tabs in turn, by tier then tab order, from the focused one on
		tabs := make([dynamic]^Tab, context.temp_allocator)
		for tier in NEED_WAITING ..= NEED_UNSEEN do for &t in s.tabs do if tab_need(t) == tier do append(&tabs, &t)
		m := len(tabs)
		j := -1
		for t, i in tabs do if focused != nil && t.id == focused.id do j = i
		switch {
		case j < 0: return s, tabs[back ? m - 1 : 0]
		case back:  return s, tabs[(j - 1 + m) % m]
		}
		return s, tabs[(j + 1) % m]
	}
	tier := list[k].tier
	if focused != nil && tab_need(focused^) == tier do return s, focused
	for &t in s.tabs do if tab_need(t) == tier do return s, &t
	return s, nil // not reached: the session has a tab of its tier
}
