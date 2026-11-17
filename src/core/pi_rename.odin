package core

// Rename a pi session (pi_rename; the sidebar row's Rename…, as a Claude row's claude_rename).
// Deckhand never writes pi's session files: it asks the session's running pi, through its tab's
// bridge (`pi.name`, docs/PROTOCOL.md §4), to name it with pi's own setSessionName, which is what
// `/name` does (a `session_info` entry pi appends; titles.odin reads the name from it). So only a
// session open on this Mac whose pi runs and whose bridge reported can be renamed; the bridge
// refuses while pi is busy, and a pi without setSessionName says to type /name instead.
// Long-running: `pending`, then a `finished` event with pi's answer.

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

PI_NAME_MAX :: 80 // characters, as a Claude row's title (CLAUDE_TITLE_MAX)
PI_RENAME_NOT_OPEN :: "this pi session is not open in a running pi tab here: open it, then rename it (or type /name in pi)"
PI_RENAME_BUSY :: "pi is busy: rename it once it is idle"

Pi_Rename :: struct {
	pi_session_id: string,
	name:          string, // trimmed; one line
}

// The pi tab that can rename session id now: its open session on this Mac (not Home), its pi
// running and its bridge reporting (nil = none).
pi_rename_tab :: proc(id: string) -> ^Tab {
	if id == "" do return nil
	for &s in state.open_sessions {
		if s.home || s.machine != 0 || s.agent != .Pi || s.pi_session_id != id do continue
		t := session_pi_tab(&s)
		if t != nil && t.status == .Running && t.agent != .Unknown do return t
	}
	return nil
}

// Whether a session row offers Rename… for pi (the window's menu; a replica's state says it too).
pi_rename_offered :: proc(id: string) -> bool {return pi_rename_tab(id) != nil}

// The name as it goes to pi: trimmed, one line, no control characters, at most PI_NAME_MAX.
pi_rename_name :: proc(name: string) -> (clean, err: string) {
	n := strings.trim_space(name)
	if !utf8.valid_string(n) do return "", "the name must be valid UTF-8"
	for r in n do if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029 {
		return "", "the name must be one line, without control characters"
	}
	if utf8.rune_count_in_string(n) > PI_NAME_MAX do return "", fmt.tprintf("the name is too long (at most %d characters)", PI_NAME_MAX)
	if n == "" do return "", "the name is empty"
	return n, ""
}

pi_rename_apply :: proc(c: Pi_Rename, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	name, err := pi_rename_name(c.name)
	if err != "" do return fail(err), false
	tab := pi_rename_tab(c.pi_session_id)
	if tab == nil do return fail(PI_RENAME_NOT_OPEN), false
	if owns_tab(caller, tab.id) do return fail("a caller cannot act on its own tab"), false
	// as pi.reload: only while pi is idle with nothing open or running (the bridge checks again)
	if tab.agent != .Idle || tab.waiting || len(tab.blockers) > 0 do return fail(PI_RENAME_BUSY), false
	if !socket_bridge_send(tab.id, request_id, Pi_Rename{pi_session_id = c.pi_session_id, name = name}) do return fail("no bridge connected for this tab"), false
	return {ok = true, pending = true}, false
}
