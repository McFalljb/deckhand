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
