package main

// The tab view hooks (window_hooks.odin, tab_views.odin): the core keeps the tab records and tells
// the window when one appears or goes; it asks the window about buffers and sheets, and with no
// window the answers are the safe ones (nothing unsaved, nothing holds the quit).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
wv_opened: [dynamic]u64
@(private = "file")
wv_open_line: int
@(private = "file")
wv_dropped: [dynamic]u64

@(private = "file")
wv_reset :: proc() -> (session: u64, dir: string) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	platform = {}
	clear(&wv_opened)
	clear(&wv_dropped)
	wv_open_line = 0
	dir = fmt.aprintf("build/test-data/window-views-%d", os.get_pid())
	os.remove_all(dir)
	os.make_directory_all(dir)
	_ = os.write_entire_file(strings.concatenate({dir, "/notes.txt"}, context.temp_allocator), transmute([]u8)string("one\ntwo\nthree\n"))
	s := Open_Session{id = new_id(), pi_session_id = "pi-wv", cwd = fs_real(dir)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return s.id, dir
}

// A fake window that only records the view hooks.
@(private = "file")
wv_fake :: proc() -> Window_Hooks {
	h := window_hooks_app()
	h.view_open = proc(tab_id: u64, kind: Tab_Kind, line: int, anchor: string) {
		append(&wv_opened, tab_id)
		wv_open_line = line
	}
	h.view_drop = proc(tab_id: u64) {append(&wv_dropped, tab_id)}
	h.tab_dirty = proc(tab_id: u64) -> bool {return false}
	return h
}

// show_file makes a record and the window its view (at the line); closing the tab drops it.
@(test)
window_views_follow_tab_records :: proc(t: ^testing.T) {
	saved := window
	defer window = saved
	window = wv_fake()
	_, dir := wv_reset()
	defer os.remove_all(dir)
	r := run_command(Show_File{path = "notes.txt", line = 2}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(wv_opened), 1)
	if len(wv_opened) == 1 do testing.expect_value(t, wv_opened[0], r.created_id)
	testing.expect_value(t, wv_open_line, 2)
	testing.expect(t, editor_of(r.created_id) == nil) // the fake window made none
	c := run_command(Close_Tab{tab_id = r.created_id}, {kind = .Internal})
	testing.expect(t, c.ok, c.error)
	testing.expect_value(t, len(wv_dropped), 1)
	if len(wv_dropped) == 1 do testing.expect_value(t, wv_dropped[0], r.created_id)
}

// The app's window: the same record gets a real editor at the line, and it goes with the tab.
@(test)
window_views_app_window_makes_the_editor :: proc(t: ^testing.T) {
	saved := window
	defer window = saved
	window = window_hooks_app()
	_, dir := wv_reset()
	defer os.remove_all(dir)
	r := run_command(Show_File{path = "notes.txt", line = 3}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	testing.expect(t, e != nil)
	if e != nil do testing.expect_value(t, tb_line_of(&e.buf, e.cursor), 2) // 0-based
	testing.expect(t, !window_tab_dirty(r.created_id))
	testing.expect_value(t, window_unsaved_files(), 0)
	run_command(Close_Tab{tab_id = r.created_id}, {kind = .Internal})
	testing.expect(t, editor_of(r.created_id) == nil)
}

// No window: the tab record still opens, the queries say nothing is unsaved or held, and what
// only the window can do is refused.
@(test)
window_views_no_window :: proc(t: ^testing.T) {
	saved := window
	defer window = saved
	window = {}
	session, dir := wv_reset()
	defer os.remove_all(dir)
	r := run_command(Show_File{path = "notes.txt"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	_, tab, _ := find_tab(r.created_id)
	testing.expect(t, tab != nil)
	testing.expect(t, editor_of(r.created_id) == nil)
	testing.expect(t, !window_tab_dirty(r.created_id))
	testing.expect_value(t, window_unsaved_files(), 0)
	testing.expect_value(t, window_unsaved_files(dir), 0)
	testing.expect(t, !window_job_sheet_open())
	testing.expect(t, !window_job_sheet_holds_quit())
	testing.expect(t, !window_job_sheet_saved("x", ""))
	testing.expect(t, !window_changes_diff(r.created_id, "p", "text"))
	testing.expect_value(t, window_dpi(), f32(0))
	_, ok := window_setup_state()
	testing.expect(t, !ok)
	js := run_command(Job_Sheet{open = true}, {kind = .UI})
	testing.expect_value(t, js.error, "no window")
	tl := run_command(Terminal_Link{tab_id = find_session(session).tabs[0].id, url = "https://example.com"}, {kind = .UI})
	testing.expect_value(t, tl.error, "no window")
	// closing works without a window too
	c := run_command(Close_Tab{tab_id = r.created_id}, {kind = .Internal})
	testing.expect(t, c.ok, c.error)
}
