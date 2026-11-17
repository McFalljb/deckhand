package main

// Moving by drag in the Files tab (ui_files.odin), through event() on a laid-out tree: onto a
// folder row, below the rows (the root), a selection of several, a refusal (a name taken), Esc;
// what is dragged is the paths pressed (rows moving under the pointer change nothing); a release
// inside the left column never reaches a pane, and a tab drag never starts. The window's terminal
// is a stand-in (peek_test.odin's pk_*): what it would get is caught.

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

@(private = "file")
FD_W :: 1400
@(private = "file")
FD_H :: 860

// A session on screen in a fresh temp folder (a project), the Files tab showing, laid out.
@(private = "file")
fd_setup :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-fdrag-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir := core.fs_real(made, context.allocator)
	ensure(strings.contains(dir, "/deckhand-fdrag-") && os.is_directory(dir), "files drag tests: no temp folder")
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
fd_write :: proc(dir, name: string) {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	os.make_directory_all(filepath.dir(p))
	_ = os.write_entire_file(p, transmute([]u8)string("x"))
	core.files_path_changed(p)
}

@(private = "file")
fd_exists :: proc(dir, rel: string) -> bool {return os.exists(strings.concatenate({dir, "/", rel}, context.temp_allocator))}

// The centre of the drawn row whose path ends with suffix, after a layout.
@(private = "file")
fd_row :: proc(suffix: string) -> (x, y: f32, ok: bool) {
	_ = ui_layout(FD_W, FD_H)
	slot := files_drawn_slot(suffix)
	if slot < 0 do return
	d := clay.GetElementData(clay.ID("frow", u32(slot)))
	if !d.found do return
	b := d.boundingBox
	return b.x + b.width / 2, b.y + b.height / 2, true
}

// A point in the list's empty space below the rows.
@(private = "file")
fd_below :: proc() -> (x, y: f32) {
	_ = ui_layout(FD_W, FD_H)
	b := clay.GetElementData(clay.ID("files_list")).boundingBox
	return b.x + b.width / 2, b.y + b.height - 8
}

@(private = "file")
fd_ev :: proc(type: sapp.Event_Type, x, y: f32, mods: u32 = 0) {
	e := sapp.Event{type = type, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = mods}
	event(&e)
	core.inbox_drain()
}

@(private = "file")
fd_press_move :: proc(fx, fy, tx, ty: f32) {
	fd_ev(.MOUSE_DOWN, fx, fy)
	_ = ui_layout(FD_W, FD_H)
	fd_ev(.MOUSE_MOVE, fx, fy + 12, sapp.MODIFIER_LMB) // past the threshold: a drag
	_ = ui_layout(FD_W, FD_H)
	fd_ev(.MOUSE_MOVE, tx, ty, sapp.MODIFIER_LMB)
}

@(test)
files_drag_moves :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	dir := fd_setup()
	fd_write(dir, "a.txt")
	fd_write(dir, "b.txt")
	fd_write(dir, "c.txt")
	fd_write(dir, "src/keep.txt")
	fd_write(dir, "docs/b.txt")

	// a.txt onto the folder row src: into it; the toast says where
	ax, ay, ok1 := fd_row("/a.txt")
	sx, sy, ok2 := fd_row("/src")
	if !testing.expect(t, ok1 && ok2, "rows drawn") do return
	fd_press_move(ax, ay, sx, sy)
	when core.TEST_HOOKS {
		testing.expect(t, files_dragging(), "dragging")
		testing.expect_value(t, files_drop_for_test().dir, strings.concatenate({dir, "/src"}, context.temp_allocator))
	}
	testing.expect(t, tab_drag.tab == 0 && !tab_dragging(), "no tab drag from the tree")
	fd_ev(.MOUSE_UP, sx, sy)
	testing.expect(t, fd_exists(dir, "src/a.txt") && !fd_exists(dir, "a.txt"), "a.txt moved into src/")
	testing.expect_value(t, toast.text, "Moved a.txt to src/")
	testing.expect_value(t, pk_take(101), "") // nothing reached the terminal

	// a collision: b.txt onto docs (docs/b.txt exists): refused, nothing moves, the toast says why
	bx, by, _ := fd_row("/b.txt")
	dx, dy, _ := fd_row("/docs")
	fd_press_move(bx, by, dx, dy)
	when core.TEST_HOOKS do testing.expect(t, strings.contains(files_drop_for_test().refused, "already has b.txt"), "refused while hovering")
	fd_ev(.MOUSE_UP, dx, dy)
	testing.expect(t, fd_exists(dir, "b.txt") && fd_exists(dir, "docs/b.txt"), "nothing moved")
	testing.expect(t, strings.contains(toast.text, "docs/ already has b.txt") && toast.err, toast.text)

	// below the rows: the root (src/keep.txt shows once src is open)
	ui_do(core.Files_Expand{path = strings.concatenate({dir, "/src"}, context.temp_allocator), expanded = true})
	core.inbox_drain()
	kx, ky, ok3 := fd_row("/src/keep.txt")
	if !testing.expect(t, ok3, "src/keep.txt drawn") do return
	rx, ry := fd_below()
	fd_press_move(kx, ky, rx, ry)
	fd_ev(.MOUSE_UP, rx, ry)
	testing.expect(t, fd_exists(dir, "keep.txt") && !fd_exists(dir, "src/keep.txt"), "keep.txt moved to the root")

	// Esc cancels: nothing moves on the release
	cx, cy, _ := fd_row("/c.txt")
	sx, sy, _ = fd_row("/src")
	fd_press_move(cx, cy, sx, sy)
	esc := sapp.Event{type = .KEY_DOWN, key_code = .ESCAPE}
	event(&esc)
	when core.TEST_HOOKS do testing.expect(t, !files_dragging(), "Esc ended the drag")
	fd_ev(.MOUSE_UP, sx, sy)
	testing.expect(t, fd_exists(dir, "c.txt"), "Esc: nothing moved")
	testing.expect_value(t, pk_take(101), "")
	os.remove_all(dir)
}

@(test)
files_drag_selection_and_safety :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	dir := fd_setup()
	fd_write(dir, "m.txt")
	fd_write(dir, "n.txt")
	fd_write(dir, "o.txt")
	fd_write(dir, "lib/x.go")
	p :: proc(dir, rel: string) -> string {return strings.concatenate({dir, "/", rel}, context.temp_allocator)}

	// two selected: a plain press on one of them drags both ("2 items"), into lib
	v := core.tree_view()
	core.files_select_in(v, p(dir, "m.txt"))
	core.files_sel_set(v, {p(dir, "m.txt"), p(dir, "n.txt")})
	mx, my, _ := fd_row("/m.txt")
	lx, ly, _ := fd_row("/lib")
	fd_press_move(mx, my, lx, ly)
	_ = ui_layout(FD_W, FD_H)
	testing.expect(t, clay.GetElementData(clay.ID("files_drag")).found, "the ghost shows")
	fd_ev(.MOUSE_UP, lx, ly)
	testing.expect(t, fd_exists(dir, "lib/m.txt") && fd_exists(dir, "lib/n.txt") && fd_exists(dir, "o.txt"), "both moved, o.txt stayed")
	testing.expect_value(t, toast.text, "Moved 2 items to lib/")

	// the rows move under the pointer mid-drag (a file appears above): what moves is still the
	// row pressed, by its path
	ox, oy, _ := fd_row("/o.txt")
	fd_ev(.MOUSE_DOWN, ox, oy)
	fd_write(dir, "0.txt") // sorts first: every row below it shifts down one
	fd_write(dir, "00.txt")
	_ = ui_layout(FD_W, FD_H)
	fd_ev(.MOUSE_MOVE, ox, oy + 12, sapp.MODIFIER_LMB)
	lx, ly, _ = fd_row("/lib")
	fd_ev(.MOUSE_MOVE, lx, ly, sapp.MODIFIER_LMB)
	fd_ev(.MOUSE_UP, lx, ly)
	testing.expect(t, fd_exists(dir, "lib/o.txt") && fd_exists(dir, "0.txt") && fd_exists(dir, "00.txt"), "o.txt moved; the new rows did not")

	// a release inside the left column but outside the tree (the Files header): nothing moves,
	// nothing reaches the terminal, no project is added
	zx, zy, _ := fd_row("/0.txt")
	_ = ui_layout(FD_W, FD_H)
	hb := clay.GetElementData(clay.ID("files_head")).boundingBox
	fd_press_move(zx, zy, hb.x + 20, hb.y + hb.height / 2)
	when core.TEST_HOOKS do testing.expect(t, files_drop_for_test().dir == "", "no drop over the header")
	testing.expect(t, tab_drag.tab == 0, "no tab drag")
	fd_ev(.MOUSE_UP, hb.x + 20, hb.y + hb.height / 2)
	testing.expect(t, fd_exists(dir, "0.txt"), "nothing moved")
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, len(state.projects), 1)
	// a press and release on its own row, no move: a click (no drag, nothing moves)
	zx, zy, _ = fd_row("/0.txt")
	fd_ev(.MOUSE_DOWN, zx, zy)
	fd_ev(.MOUSE_UP, zx, zy)
	when core.TEST_HOOKS do testing.expect(t, !files_dragging(), "a click")
	testing.expect(t, fd_exists(dir, "0.txt"), "a click moves nothing")
	// a press that moves past the drag threshold but stays on its own row: still a click (a folder
	// opens), no ghost, nothing moves
	lib := p(dir, "lib")
	if core.files_is_open(lib) {
		ui_do(core.Files_Expand{path = lib, expanded = false})
		core.inbox_drain()
	}
	lx, ly, _ = fd_row("/lib")
	fd_ev(.MOUSE_DOWN, lx, ly)
	fd_ev(.MOUSE_MOVE, lx + 6, ly + 2, sapp.MODIFIER_LMB)
	_ = ui_layout(FD_W, FD_H)
	testing.expect(t, !clay.GetElementData(clay.ID("files_drag")).found, "no ghost on its own row")
	fd_ev(.MOUSE_UP, lx + 6, ly + 2)
	testing.expect(t, core.files_is_open(lib), "the folder opened: a click")
	testing.expect(t, fd_exists(dir, "lib/x.go"), "nothing moved")
	os.remove_all(dir)
}
