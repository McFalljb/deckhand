package main

// Opening a file from the Files tree with no session on screen (the tree shows the selected
// project's folder): refused with what to do, as a toast in the window; never opened in another
// project's session.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
fo_setup :: proc() -> (dir, other: string) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.platform = {quit = proc() {}}
	core.files_refresh()
	core.files_state_gen += 1
	toast_clear()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	base := fmt.tprintf("%s/deckhand-files-open-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/proj", base))
	os.make_directory_all(fmt.tprintf("%s/other", base))
	dir = core.fs_real(fmt.tprintf("%s/proj", base), context.allocator)
	other = core.fs_real(fmt.tprintf("%s/other", base), context.allocator)
	ensure(strings.contains(dir, "/deckhand-files-open-test-") && os.is_directory(dir), "files open tests: no temp folder")
	_ = os.write_entire_file(fmt.tprintf("%s/a.txt", dir), transmute([]u8)string("a\n"))
	append(&state.projects, core.Project{id = core.new_id(), cwd = dir, label = "proj"})
	append(&state.projects, core.Project{id = core.new_id(), cwd = other, label = "other"})
	state.selected_project = state.projects[0].id
	return
}

@(test)
files_open_no_session_says_what_to_do :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir, other := fo_setup()
	defer os.remove_all(strings.trim_suffix(dir, "/proj"))
	WANT :: "Open a session in proj to open files"
	path := fmt.tprintf("%s/a.txt", dir)
	// nothing open: the tree shows the selected project's folder
	testing.expect_value(t, core.files_root(), dir)
	r := core.run_command(core.Open_File{path = path, preview = true}, {kind = .UI})
	testing.expect_value(t, r.error, WANT)
	// the window's open (a click, Enter, Space): the refusal is a toast, not dropped
	files_open(path, preview = true)
	testing.expect_value(t, toast.text, WANT)
	testing.expect(t, toast.err)
	toast_clear()
	files_open(path)
	testing.expect_value(t, toast.text, WANT)

	// a session open in another project, none on screen: the same, and nothing opens over there
	s := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("o-1"), project_id = state.projects[1].id, cwd = strings.clone(other)}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = 0
	r = core.run_command(core.Open_File{path = path}, {kind = .UI})
	testing.expect_value(t, r.error, WANT)
	testing.expect_value(t, len(state.open_sessions[0].tabs), 1)
	// a paired browser's show_file (the web tree): the same words
	r = core.run_command(core.Show_File{path = path}, {kind = .UI, web = true})
	testing.expect_value(t, r.error, WANT)
	testing.expect_value(t, len(state.open_sessions[0].tabs), 1)
	// a file in no listed project: the general words
	r = core.run_command(core.Open_File{path = "/etc/hosts"}, {kind = .UI})
	testing.expect_value(t, r.error, "Open a session in proj to open files") // the selected project's, as the tree shows it
	// scripts and agents keep their own words (nothing to click for them)
	testing.expect_value(t, core.run_command(core.Open_File{path = path}, {kind = .Script}).error, "no open session to open the file in")
	testing.expect_value(t, core.run_command(core.Show_File{path = path}, {kind = .Script}).error, "no session on screen")
}
