package core

// The browser's "web" state section (web_view.odin): its rows from State, and that it is computed
// again only when something it reads changed. Same rules as core_test.odin: shared global State,
// one thread, no processes.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:testing"

@(test)
web_view_section :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	p := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-view-alpha"}
	append(&state.projects, p)
	s := Open_Session{id = new_id(), project_id = p.id, pi_session_id = "pi-alpha", cwd = p.cwd}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle, waiting = true})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)

	// the rows: the open session listed, waiting counted, its title and place, no disk stamp yet
	secs := state_sections(&state)
	j := web_view_cached(secs[:])
	v, err := json.parse_string(j, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "the section is JSON")
	o := v.(json.Object)
	open := o["open"].(json.Array)
	testing.expect_value(t, len(open), 1)
	testing.expect_value(t, u64(open[0].(json.Float)), s.id)
	testing.expect_value(t, int(o["fleet"].(json.Object)["waiting"].(json.Float)), 1)
	ti := o["titles"].(json.Object)[fmt.tprint(s.id)].(json.Object)
	testing.expect_value(t, ti["title"].(json.String), "Untitled session")
	testing.expect_value(t, ti["place"].(json.String), "web-view-alpha")
	testing.expect_value(t, ti["at"].(json.Float), 0)

	// unchanged inputs: the same JSON, not computed again; a changed section: computed again
	n := web_view_last.builds
	testing.expect(t, web_view_cached(secs[:]) == j, "the same section")
	testing.expect_value(t, web_view_last.builds, n)
	state.open_sessions[0].tabs[0].waiting = false
	secs2 := state_sections(&state)
	j2 := web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 1)
	testing.expect(t, j2 != j, "a status change shows")
	// a session file's new stamp (web_view_tick's read) is a change even with the sections alike
	state.open_sessions[0].mtime._nsec = 1_700_000_000_000_000_000
	_ = web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 2)
	state = State{}
}
