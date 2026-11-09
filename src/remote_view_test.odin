package main

// Another machine's session on screen (core/machine_mirror.odin; §10.4 M6-B, review round 2): the
// window draws its tab bar, and nothing it draws runs git on this Mac in the folder that machine
// named (the "±" button's session_repo would walk up to this repository).

import "base:runtime"
import "core:strings"
import "core:testing"
import "core"

@(test)
remote_session_no_local_git :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{}
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	clear(&core.changes_repos)
	r: core.State
	append(&r.projects, core.Project{id = 5, group = .Projects, cwd = strings.clone("/x"), label = strings.clone("x")})
	// a folder inside this repository (it exists here, as another machine may name any path)
	cwd := strings.clone(core.fs_real("src/core"))
	s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = cwd, title = strings.clone("t")}
	append(&s.tabs, core.Tab{id = 10, kind = core.Shell_Tab{}, title = strings.clone("sh"), status = .Running})
	s.active_tab = 10
	append(&r.open_sessions, s)
	m: core.Machine_Mirror
	core.mirror_merge(3, &r, &m)
	sid, _ := core.id_pack(3, 9)
	core.run_command(core.Focus_Session{session = sid}, {kind = .UI})
	cs := core.cur_view()
	testing.expect(t, cs != nil && cs.id == sid, "on screen")
	testing.expect(t, session_repo(cs) == nil, "no repository of this Mac's for another machine's session")
	testing.expect_value(t, len(core.changes_repos), 0)
	core.mirror_unmerge(3)
	core.mirror_free(&m)
	core.replica_free(&r, runtime.heap_allocator())
}
