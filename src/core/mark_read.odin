package core

// Mark all as read (mark_all_read; ⌥⇧⌘U): every tab of this Mac's open sessions whose status is
// "finished, not seen" right now (tab_status_view's Unseen dot) is seen. Decided here, in one
// command, against the core's State as it applies: a tab waiting for the user, with an error or a
// question is never touched, whatever the window last saw (an error that arrived a moment before
// keeps its unseen flag, so its record stays until the user looks: agent_status.odin). Other
// machines' sessions and Home are left as they are. Result data: {"count": sessions marked}.

import "core:fmt"

Mark_All_Read :: struct {}

mark_all_read_apply :: proc(caller: Caller) -> (Result, bool) {
	n := 0
	for &s in state.open_sessions {
		if s.home || s.machine != 0 do continue
		marked := false
		for &t in s.tabs {
			if !t.unseen || tab_status_view(t).dot != .Unseen do continue
			t.unseen = false
			marked = true
		}
		if marked do n += 1
	}
	if caller.kind == .UI do window_toast(n == 0 ? "Nothing unread" : fmt.tprintf("Marked %d as read", n))
	return {ok = true, data = fmt.tprintf(`{{"count":%d}}`, n)}, n > 0
}
