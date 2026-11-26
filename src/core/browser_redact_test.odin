package core

// What leaves the core for events, the log and agents' snapshots holds no user:pass@ of an
// address (browser_url_redacted, browser_url_public).

import "core:strings"
import "core:testing"

@(test)
browser_url_redacted_shapes :: proc(t: ^testing.T) {
	cases := [?][2]string {
		{"https://user:pass@host.example/p?q=1#f", "https://host.example/p?q=1#f"},
		{"user:pass@host.example/p", "host.example/p"},
		// no scheme, an address with :// later in its query: still the user:pass@ before the host
		{"user:pass@host.example/?next=https://x.example", "host.example/?next=https://x.example"},
		{"user:pass@host.example?next=https://x.example", "host.example?next=https://x.example"},
		{"https://host.example/?next=https://user:pw@x.example", "https://host.example/?next=https://user:pw@x.example"},
		// a mail address keeps mailto: and its domain, not whom
		{"mailto:alice@example.com", "mailto:<redacted>@example.com"},
		{"MAILTO:alice@example.com?subject=hi", "MAILTO:<redacted>@example.com?subject=hi"},
		{"mailto:", "mailto:"},
		// scheme-relative: as with a scheme
		{"//user:pass@host.example/x", "//host.example/x"},
		{"example.com", "example.com"},
	}
	for c in cases do testing.expectf(t, browser_url_redacted(c[0]) == c[1], "%q: want %q, got %q", c[0], c[1], browser_url_redacted(c[0]))
}

// A refused popup's address in get_state's snapshot: without user:pass@ (State keeps it as the
// page asked: Browser_Popup opens it).
@(test)
browser_blocked_popup_snapshot :: proc(t: ^testing.T) {
	inbox_drain()
	state = State{}
	s := Open_Session{id = new_id(), pi_session_id = "s-pop", cwd = "/tmp"}
	tab := Tab{id = new_id(), title = "page", status = .Running, kind = Browser_Tab{url = "https://page.example/", blocked_popup = "https://user:pass@popup.example/x"}}
	append(&s.tabs, tab)
	s.active_tab = tab.id
	append(&state.open_sessions, s)
	js := state_json()
	testing.expectf(t, !strings.contains(js, "user:pass"), "snapshot holds user:pass: %s", js)
	testing.expect(t, strings.contains(js, `"blocked_popup":"https://popup.example/x"`), "the popup's address, without user:pass@")
	testing.expect_value(t, state.open_sessions[0].tabs[0].kind.(Browser_Tab).blocked_popup, "https://user:pass@popup.example/x")
	delete(state.open_sessions[0].tabs)
	delete(state.open_sessions)
	state = State{}
}
