package main

// The Home session (docs/ROADMAP.md G9): pi-desk's own pi, the built-in
// agent ("Atlas", agent.odin), which drives the app through the control
// socket (pi-kit's `desk` extension). It is an open session without a
// project, with only its pi tab (its terminal shows in the drawer, ⌘J), not
// listed with the projects. It starts on
// the first open (lazy) and resumes its pi session across restarts
// (docs/PERSISTENCE.md).
//
// Where it lives: sessions in <data dir>/home (pi --session-dir), so they
// stay out of pi's project store and the left column; cwd = the user's home
// folder, because Home works across every project (relative paths such as
// code/app resolve as the user would type them).
//
// Its environment carries a bridge token (PI_DESK_TOKEN: its status) and
// PI_DESK_CONTROL_TOKEN, a single-use control token bound to Home's tab
// (agent_env): the hello result's tab_id is Home's tab, and that tab and
// session are off limits to it (owns_tab).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// pi-desk's data dir as the app uses it (set at startup; test mode: the
// test data dir). "" = no Home.
home_root: string

home_dir :: proc() -> string {
	d, _ := filepath.join({home_root, "home"}, context.allocator)
	os.make_directory_all(d, {.Read_User, .Write_User, .Execute_User})
	return d
}

home_cwd :: proc() -> string {
	h := os.get_env("HOME", context.temp_allocator)
	if h == "" || !os.is_dir(h) do return home_dir()
	return strings.clone(h)
}

// The session file for pi session id `id` in `dir` (temp), or "".
session_file_in :: proc(dir, id: string) -> string {
	if dir == "" || id == "" do return ""
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return ""
	return session_file_among(files, id)
}
