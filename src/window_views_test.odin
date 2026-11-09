package main

// The tab view requests (window_hooks.odin, tab_views.odin): the core keeps the tab records and
// tells the window when one appears or goes (window.request); the window reports its buffers and
// sheets (its facts), and with no window the answers are the safe ones (nothing unsaved, nothing
// holds the quit).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core"

@(private = "file")
wv_reset :: proc() -> (session: u64, dir: string) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.platform, win_os = {}, {}
	dir = fmt.aprintf("build/test-data/window-views-%d", os.get_pid())
	os.remove_all(dir)
	os.make_directory_all(dir)
	_ = os.write_entire_file(strings.concatenate({dir, "/notes.txt"}, context.temp_allocator), transmute([]u8)string("one\ntwo\nthree\n"))
	s := core.Open_Session{id = core.new_id(), pi_session_id = "pi-wv", cwd = core.fs_real(dir)}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return s.id, dir
}

// The app's window: the same record gets a real editor at the line, and it goes with the tab.
@(test)
window_views_app_window_makes_the_editor :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.window
	defer core.window = saved
	core.window = window_hooks_app()
	_, dir := wv_reset()
	defer os.remove_all(dir)
	r := core.run_command(core.Show_File{path = "notes.txt", line = 3}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	testing.expect(t, e != nil)
	if e != nil do testing.expect_value(t, tb_line_of(&e.buf, e.cursor), 2) // 0-based
	if dirty, dknown := core.window_tab_dirty(r.created_id); true do testing.expect(t, !dirty && dknown)
	n, known := core.window_unsaved_files()
	testing.expect(t, n == 0 && known)
	core.run_command(core.Close_Tab{tab_id = r.created_id}, {kind = .Internal})
	testing.expect(t, editor_of(r.created_id) == nil)
}

// No window: the tab record still opens, the queries say nothing is held, unsaved files are not
// known (never "none": a quit or a clean up asks or refuses), and what only the window can do is
// refused.
@(test)
window_views_no_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.window
	defer core.window = saved
	core.window = {}
	tl_host_off() // and no tab host link (tabhost_link.odin)
	defer tl_host_on()
	session, dir := wv_reset()
	defer os.remove_all(dir)
	r := core.run_command(core.Show_File{path = "notes.txt"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	_, tab, _ := core.find_tab(r.created_id)
	testing.expect(t, tab != nil)
	testing.expect(t, editor_of(r.created_id) == nil)
	if dirty, dknown := core.window_tab_dirty(r.created_id); true do testing.expect(t, !dirty && !dknown, "no window: not known")
	_, known := core.window_unsaved_files()
	testing.expect(t, !known, "no window: not known")
	_, known = core.window_unsaved_files(dir)
	testing.expect(t, !known)
	testing.expect(t, !core.window_job_sheet_open())
	testing.expect(t, !core.window_job_sheet_holds_quit())
	testing.expect(t, !core.window_job_sheet_saved("x", ""))
	testing.expect_value(t, core.window_dpi(), f32(0))
	_, ok := core.window_setup_state()
	testing.expect(t, !ok)
	js := core.run_command(core.Job_Sheet{open = true}, {kind = .UI})
	testing.expect_value(t, js.error, "no window")
	tl := core.run_command(core.Terminal_Link{tab_id = core.find_session(session).tabs[0].id, url = "https://example.com"}, {kind = .UI})
	testing.expect_value(t, core.json_path(tl.data, "code"), "no_window") // the user's ⌘-click needs the window
	// closing works without a window too
	c := core.run_command(core.Close_Tab{tab_id = r.created_id}, {kind = .Internal})
	testing.expect(t, c.ok, c.error)
}
