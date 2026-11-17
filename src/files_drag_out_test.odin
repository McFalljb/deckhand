package main

// A Files drag out of the window (files_drag_out.odin, src/native/dragout_macos.m): what it
// carries (paths inside the tree's project, nested ones once, no credential files), the picture's
// label, Copy only and only to other apps, the pasteboard items as AppKit reads them back, and
// through event(): the in-window drag ends when the pointer leaves, nothing moves, and the release
// after it reaches nothing.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(test)
files_drag_out_what_it_carries :: proc(t: ^testing.T) {
	no_creds :: proc(p: string) -> bool {return false}
	// inside the root only, not the root itself; a folder carries what is in it (once)
	paths, skipped := files_drag_out_paths("/p/proj", {"/p/proj/a.txt", "/p/proj/src", "/p/proj/src/x.go", "/p/proj", "/p/other/b", "/p/proj-2/c"}, no_creds)
	testing.expect_value(t, len(paths), 2)
	if len(paths) == 2 {
		testing.expect_value(t, paths[0], "/p/proj/a.txt")
		testing.expect_value(t, paths[1], "/p/proj/src")
	}
	testing.expect_value(t, skipped, 0)
	// credential files are left out and counted
	creds :: proc(p: string) -> bool {return strings.has_suffix(p, "auth.json")}
	paths, skipped = files_drag_out_paths("/p/proj", {"/p/proj/auth.json", "/p/proj/a.txt"}, creds)
	testing.expect_value(t, len(paths), 1)
	testing.expect_value(t, skipped, 1)
	paths, skipped = files_drag_out_paths("/p/proj", {"/p/proj/auth.json"}, creds)
	testing.expect_value(t, len(paths), 0)
	testing.expect_value(t, skipped, 1)
	// no root (the tree shows another one than the drag's): nothing
	paths, _ = files_drag_out_paths("", {"/p/proj/a.txt"}, no_creds)
	testing.expect_value(t, len(paths), 0)

	testing.expect_value(t, files_drag_out_label({"/p/proj/a.txt"}), "a.txt")
	testing.expect_value(t, files_drag_out_label({"/p/proj/a\nb.txt"}), "a b.txt") // a name is one line
	testing.expect_value(t, files_drag_out_label({"/p/a", "/p/b", "/p/c"}), "3 items")

	testing.expect(t, !files_drag_out_outside(0, 0, 100, 50), "the corner is inside")
	testing.expect(t, files_drag_out_outside(-1, 10, 100, 50) && files_drag_out_outside(10, -1, 100, 50), "left, above")
	testing.expect(t, files_drag_out_outside(100, 10, 100, 50) && files_drag_out_outside(10, 50, 100, 50), "right, below")
}

@(test)
files_drag_out_native :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	// Copy (1) to other apps; nothing inside Deckhand (no drop of our own files on our window)
	testing.expect_value(t, platform_drag_out_mask(true), 1)
	testing.expect_value(t, platform_drag_out_mask(false), 0)
	// the items: a file URL each (percent-encoded) and its quoted path as text
	got, ok := platform_drag_out_test_items({"/tmp/dh drag/a b.txt", "/tmp/dh drag/it's"}, {shell_quote("/tmp/dh drag/a b.txt"), shell_quote("/tmp/dh drag/it's")})
	if !testing.expect(t, ok, "a pasteboard") do return
	testing.expect_value(t, got, "file:///tmp/dh%20drag/a%20b.txt\t'/tmp/dh drag/a b.txt'\nfile:///tmp/dh%20drag/it's\t'/tmp/dh drag/it'\\''s'\n")
}

// A session on screen in a fresh temp folder, the Files tab showing (as files_drag_test.odin's).
@(private = "file")
fo_setup :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-fout-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir := core.fs_real(made, context.allocator)
	ensure(strings.contains(dir, "/deckhand-fout-") && os.is_directory(dir), "files drag out tests: no temp folder")
	state.projects[0].cwd = dir
	pk_session(100, "Here", pk_tab(101))
	state.open_sessions[0].cwd = strings.clone(dir)
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	state.layout.left_tab = .Files
	core.files_refresh()
	core.files_state_gen += 1
	return dir
}

@(private = "file")
fo_ev :: proc(type: sapp.Event_Type, x, y: f32, mods: u32 = 0) {
	e := sapp.Event{type = type, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = mods}
	event(&e)
	core.inbox_drain()
}

@(test)
files_drag_out_from_the_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	when core.TEST_HOOKS {
		W, H :: 1400, 860
		defer pk_reset()
		files_out_test = {on = true, w = W, h = H}
		defer files_out_test = {}
		defer files_out = {}
		dir := fo_setup()
		for n in ([]string{"a.txt", "lib/x.go"}) {
			p, _ := filepath.join({dir, n}, context.temp_allocator)
			os.make_directory_all(filepath.dir(p))
			_ = os.write_entire_file(p, transmute([]u8)string("x"))
			core.files_path_changed(p)
		}
		_ = ui_layout(W, H)
		slot := files_drawn_slot("/a.txt")
		if !testing.expect(t, slot >= 0, "a.txt drawn") do return
		b := clay.GetElementData(clay.ID("frow", u32(slot))).boundingBox
		ax, ay := b.x + b.width / 2, b.y + b.height / 2

		// a drag from a.txt that leaves the window (to the left): the system's drag carries a.txt
		fo_ev(.MOUSE_DOWN, ax, ay)
		_ = ui_layout(W, H)
		fo_ev(.MOUSE_MOVE, ax, ay + 12, sapp.MODIFIER_LMB)
		testing.expect(t, files_dragging() && !files_out_test.started, "an in-window drag first")
		fo_ev(.MOUSE_MOVE, -4, ay, sapp.MODIFIER_LMB)
		testing.expect(t, files_out_test.started, "the system's drag started")
		testing.expect(t, !files_dragging(), "the in-window drag ended")
		a := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
		testing.expect(t, len(files_out_test.paths) == 1 && files_out_test.paths[0] == a, "it carries a.txt")
		testing.expect(t, len(files_out_test.texts) == 1 && files_out_test.texts[0] == shell_quote(a), "its quoted path")
		testing.expect_value(t, files_out_test.label, "a.txt")

		// the release (AppKit's own, or the one sent to let go of sokol's button) reaches nothing:
		// nothing moves, nothing goes to the terminal; the next press ends that
		_ = pk_take(101)
		e := sapp.Event{type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = 700, mouse_y = 400}
		testing.expect(t, files_drag_out_event(&e), "the release is eaten")
		fo_ev(.MOUSE_UP, 700, 400)
		testing.expect(t, os.exists(a), "nothing moved")
		testing.expect_value(t, pk_take(101), "")
		testing.expect(t, files_out.eat_release, "until the next press")
		fo_ev(.MOUSE_DOWN, ax, ay)
		testing.expect(t, !files_out.eat_release, "a press ends it")
		fo_ev(.MOUSE_UP, ax, ay)
		os.remove_all(dir)
	}
}
