package core

// The browser's "web" state section (web_view.odin): its rows from State, and that it is computed
// again only when something it reads changed. Same rules as core_test.odin: shared global State,
// one thread, no processes.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
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

	// the sections: the small part, the open session's row, the tree and its row
	sec :: proc(list: [][2]string, name: string) -> (string, bool) {
		for x in list do if x[0] == name do return x[1], true
		return "", false
	}
	parse :: proc(j: string) -> json.Value {
		v, err := json.parse_string(j, allocator = context.temp_allocator)
		if err != nil do return nil
		return v
	}
	secs := state_sections(&state)
	out := web_view_cached(secs[:])
	snap := make(map[string]string, context.temp_allocator)
	for x in out do snap[strings.clone(x[0], context.temp_allocator)] = strings.clone(x[1], context.temp_allocator) // the cache frees its own on a recompute
	w, _ := sec(out, "web")
	o := parse(w).(json.Object)
	open := o["open"].(json.Array)
	testing.expect_value(t, len(open), 1)
	testing.expect_value(t, u64(open[0].(json.Float)), s.id)
	testing.expect_value(t, int(o["fleet"].(json.Object)["waiting"].(json.Float)), 1)
	ws, has := sec(out, fmt.tprintf("webo:%d", s.id))
	testing.expect(t, has, "the open session's row")
	ti := parse(ws).(json.Object)
	testing.expect_value(t, ti["title"].(json.String), "Untitled session")
	testing.expect_value(t, ti["place"].(json.String), "web-view-alpha")
	testing.expect_value(t, ti["at"].(json.Float), 0)
	tree, _ := sec(out, "webtree")
	testing.expect_value(t, tree, fmt.tprintf(`["%d"]`, p.id))
	row, _ := sec(out, fmt.tprintf("webp:%d", p.id))
	testing.expect_value(t, parse(row).(json.Object)["path"].(json.String), "/tmp/web-view-alpha")

	// unchanged inputs: not computed again; a status flip: computed again, and of the browser's
	// sections only the small one changed (no tree row, no title row)
	n := web_view_last.builds
	_ = web_view_cached(secs[:])
	testing.expect_value(t, web_view_last.builds, n)
	state.open_sessions[0].tabs[0].waiting = false
	secs2 := state_sections(&state)
	out2 := web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 1)
	changed := make([dynamic]string, context.temp_allocator)
	for x in out2 do if snap[x[0]] != x[1] do append(&changed, x[0])
	testing.expect_value(t, len(changed), 1)
	if len(changed) == 1 do testing.expect_value(t, changed[0], "web")
	// a session file's new stamp (web_view_tick's read) is a change even with the sections alike
	state.open_sessions[0].mtime._nsec = 1_700_000_000_000_000_000
	_ = web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 2)

	// web_watch: a browser's only
	r := run_command(Web_Watch{projects = {p.id}}, Caller{kind = .UI})
	testing.expect(t, !r.ok && r.error != "", "refused for the window")
	state = State{}
}
