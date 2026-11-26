package core

import "core:testing"

// #202: a peer is another login's only when both sessions are known and differ.
@(test)
login_other_table :: proc(t: ^testing.T) {
	Case :: struct {
		peer, own: u32,
		want:      bool,
	}
	cases := []Case {
		{100015, 100015, false}, // the same login
		{100001, 100015, true}, // a core or holder that outlived a logout
		{0, 100015, false}, // the peer's not known (no token, Linux)
		{100015, 0, false}, // ours not known
		{LOGIN_ASID_UNKNOWN, 100015, false},
		{100015, LOGIN_ASID_UNKNOWN, false},
		{0, 0, false},
	}
	for c in cases do testing.expectf(t, login_other(c.peer, c.own) == c.want, "login_other(%d, %d) = %v", c.peer, c.own, !c.want)
}

// This process's own session is readable (macOS: getaudit_addr), and the same as a token from it.
@(test)
login_asid_own_known :: proc(t: ^testing.T) {
	when ODIN_OS == .Darwin {
		own := login_asid_own()
		testing.expectf(t, own != 0 && own != LOGIN_ASID_UNKNOWN, "own asid %d", own)
		testing.expect(t, !login_other(own, own))
	} else {
		testing.expect_value(t, login_asid_own(), 0)
	}
}

@(test)
login_holder_replaced_text_counts :: proc(t: ^testing.T) {
	testing.expect_value(t, login_holder_replaced_text(0), "Deckhand's session holder was from an earlier login, so a new one replaced it.")
	testing.expect_value(t, login_holder_replaced_text(1), "Deckhand's session holder was from an earlier login, so a new one replaced it: 1 session restarts here (pi, Claude and Codex resume their conversations; shells start fresh).")
}

// ---- review round 1 (#204): only an ended GUI login is replaced, and only from the current one ----

// The decision: this process must be in the current GUI login, and the peer in another GUI-kind
// login (graphic access, not remote): a user has one GUI login at a time, so that one has ended.
// An ssh or other remote login, or one not known, is never replaced (#204 review, items 2 and 3).
@(test)
login_replace_table :: proc(t: ^testing.T) {
	Case :: struct {
		current: bool,
		own:     u32,
		peer:    Login,
		want:    bool,
		why:     string,
	}
	cases := []Case {
		{true, 100015, {asid = 100001, known = true, gui = true}, true, "an ended GUI login"},
		{true, 100015, {asid = 100015, known = true, gui = true}, false, "this login"},
		{true, 100015, {asid = 100020, known = true, gui = false}, false, "an ssh login (remote, or no graphic access)"},
		{true, 100015, {asid = 100001, known = false, gui = true}, false, "a session not known"},
		{false, 100015, {asid = 100001, known = true, gui = true}, false, "this process is not in the current GUI login (ssh, or itself ended)"},
		{true, 0, {asid = 100001, known = true, gui = true}, false, "own session not known"},
		{true, 100015, {asid = 0, known = true, gui = true}, false, "peer asid not known"},
	}
	for c in cases do testing.expectf(t, login_replace(c.current, c.own, c.peer) == c.want, "%s: got %v", c.why, !c.want)
}

// A session's flags: graphic access and not remote.
@(test)
login_flags_gui :: proc(t: ^testing.T) {
	testing.expect(t, login_flags_gui_kind(0x6030), "this Mac's console login (0x6030)")
	testing.expect(t, !login_flags_gui_kind(0x7030), "remote (0x1000)")
	testing.expect(t, !login_flags_gui_kind(0x0020), "a tty only (ssh without graphic access)")
	testing.expect(t, !login_flags_gui_kind(0), "none")
}

// The gui/<uid> domain's session, from `launchctl print gui/<uid>` (this Mac's, trimmed).
@(test)
launchctl_gui_asid_parse :: proc(t: ^testing.T) {
	out := "gui/501 = {\n\ttype = login\n\thandle = 100015\n\tsession = Aqua\n\tsecurity context = {\n\t\tuid = 501\n\t\tasid = 100015\n\t}\n\n\tbringup time = 83 ms\n"
	a, ok := launchctl_gui_asid(out)
	testing.expect(t, ok && a == 100015, "the asid in the security context")
	_, ok = launchctl_gui_asid("Could not print domain: 141: Reentrancy avoided\n")
	testing.expect(t, !ok, "an ended login's launchctl")
	_, ok = launchctl_gui_asid("gui/501 = {\n\tasid = x\n}\n")
	testing.expect(t, !ok, "not a number")
	_, ok = launchctl_gui_asid("gui/501 = {\n\tsecurity context = {\n\t\tasid = 0\n\t}\n}\n")
	testing.expect(t, !ok, "0 is not a session")
}

// DECKHAND_TEST_ASID's value: N (the current GUI login), N:ended (a GUI login that has ended),
// N:remote (an ssh login).
@(test)
login_hook_parse_values :: proc(t: ^testing.T) {
	a, gui, current, ok := login_hook_parse("222")
	testing.expect(t, ok && a == 222 && gui && current)
	a, gui, current, ok = login_hook_parse("111:ended")
	testing.expect(t, ok && a == 111 && gui && !current)
	a, gui, current, ok = login_hook_parse("333:remote")
	testing.expect(t, ok && a == 333 && !gui && !current)
	_, _, _, ok = login_hook_parse("x")
	testing.expect(t, !ok)
	_, _, _, ok = login_hook_parse("1:what")
	testing.expect(t, !ok)
}
