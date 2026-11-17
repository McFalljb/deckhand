package core

// A Files session (files_session.odin) on the window's state stream: this window reads its agent;
// an older window (or an older hub reading this machine's stream) reads an agent name it does not
// know as the zero value, Pi: a pi session whose first tab is a file tab. Nothing it calls for a
// session's main tab may assume a pi tab is there (no crash, no tab mistaken for pi's).

import "core:testing"

@(test)
files_session_agent_on_the_wire :: proc(t: ^testing.T) {
	// this window: "files" reads as Files
	r: State
	now := `{"type":"state.full","version":1,"state":{"sessions":{"open_sessions":[{"id":10,"agent":"files","project_id":3,"cwd":"/p"}]},"tabs:10":[{"id":11,"kind":{"editor_tab":{"path":"/p/a.txt"}},"status":"running"}]}}`
	testing.expect_value(t, replica_apply(&r, now, context.temp_allocator), "")
	testing.expect_value(t, len(r.open_sessions), 1)
	testing.expect_value(t, r.open_sessions[0].agent, Session_Agent.Files)

	// an older window: an agent it does not know (as "files" is to it) is Pi, the session kept whole
	old: State
	newer := `{"type":"state.full","version":1,"state":{"sessions":{"open_sessions":[{"id":10,"agent":"files_of_a_newer_core","project_id":3,"cwd":"/p"}]},"tabs:10":[{"id":11,"kind":{"editor_tab":{"path":"/p/a.txt"}},"status":"running"}]}}`
	testing.expect_value(t, replica_apply(&old, newer, context.temp_allocator), "")
	testing.expect_value(t, len(old.open_sessions), 1)
	s := &old.open_sessions[0]
	testing.expect_value(t, s.agent, Session_Agent.Pi)
	testing.expect_value(t, len(s.tabs), 1)
	_, is_editor := s.tabs[0].kind.(Editor_Tab)
	testing.expect(t, is_editor)
	// what reads a session's main tab: no pi tab, no Claude tab, nothing to restart
	testing.expect(t, session_pi_tab(s) == nil)
	testing.expect(t, comments_claude_main(s) == nil)
	testing.expect_value(t, open_session_harness(s), Harness.Pi)
	// an enum number past the values (a newer core's, written as a number) reads as Pi too
	num: State
	n := `{"type":"state.full","version":1,"state":{"sessions":{"open_sessions":[{"id":10,"agent":9,"cwd":"/p"}]},"tabs:10":[]}}`
	testing.expect_value(t, replica_apply(&num, n, context.temp_allocator), "")
	testing.expect_value(t, num.open_sessions[0].agent, Session_Agent.Pi)
}
