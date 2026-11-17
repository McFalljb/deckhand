package core

// Moving by drag in the Files tree (ui_files.odin): where a drop lands, or why not
// (files_drop_at), and the renames it makes (files_drop_moves). Pure: names taken in the target
// come from a fake.

import "base:runtime"
import "core:strings"
import "core:testing"

@(private = "file")
TAKEN := [?]string{"/p/src/a.txt", "/p/docs/a.txt", "/p/docs/A.md"}

@(private = "file")
fake_exists :: proc(path: string) -> bool {
	for p in TAKEN do if p == path do return true
	return false
}

@(private = "file")
drop :: proc(sources: []string, over: string, over_dir := false) -> Files_Drop {
	return files_drop_at({sources = sources, root = "/p", over = over, over_dir = over_dir, exists = fake_exists})
}

@(test)
files_drop_targets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	// onto a folder row: into it
	d := drop({"/p/b.txt"}, "/p/lib", true)
	testing.expect_value(t, d.dir, "/p/lib")
	testing.expect(t, !d.noop && d.refused == "", "a folder row takes it")
	// onto a file row: into that file's folder
	d = drop({"/p/b.txt"}, "/p/lib/x/y.go")
	testing.expect_value(t, d.dir, "/p/lib/x")
	testing.expect(t, !d.noop && d.refused == "", "a file row: its folder")
	// below the rows: the root
	d = drop({"/p/lib/b.txt"}, "")
	testing.expect_value(t, d.dir, "/p")
	testing.expect(t, !d.noop && d.refused == "", "the root")
	// a file row in the root: the root too
	d = drop({"/p/lib/b.txt"}, "/p/c.txt")
	testing.expect_value(t, d.dir, "/p")
	// nothing dragged, or no tree: nowhere
	testing.expect_value(t, drop({}, "/p/lib", true).dir, "")
	testing.expect_value(t, files_drop_at({sources = {"/p/a"}, root = "", over = "", exists = fake_exists}).dir, "")
	// a row outside the root (stale): nowhere
	testing.expect_value(t, drop({"/p/b.txt"}, "/q/lib", true).dir, "")
}

@(test)
files_drop_noop_and_into_self :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	// onto its own row: nothing (a file, and a folder)
	testing.expect(t, drop({"/p/b.txt"}, "/p/b.txt").noop, "a file onto itself")
	d := drop({"/p/lib"}, "/p/lib", true)
	testing.expect(t, d.noop && d.refused == "", "a folder onto itself: nothing, no toast")
	// the folder it is in already: nothing
	testing.expect(t, drop({"/p/lib/b.txt"}, "/p/lib", true).noop, "same parent (its folder's row)")
	testing.expect(t, drop({"/p/lib/b.txt"}, "/p/lib/c.txt").noop, "same parent (a sibling's row)")
	testing.expect(t, drop({"/p/b.txt"}, "").noop, "same parent (the root)")
	// into itself or below it: refused
	d = drop({"/p/lib"}, "/p/lib/x", true)
	testing.expect(t, !d.noop && strings.contains(d.refused, "into itself"), "into a folder inside it")
	d = drop({"/p/lib"}, "/p/lib/x/y.go")
	testing.expect(t, strings.contains(d.refused, "into itself"), "onto a file inside it")
	// a name sharing a prefix is not inside
	d = drop({"/p/lib"}, "/p/library", true)
	testing.expect(t, d.refused == "" && !d.noop, "lib into library")
}

@(test)
files_drop_collisions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	d := drop({"/p/a.txt"}, "/p/src", true)
	testing.expect(t, strings.contains(d.refused, "already has a.txt"), "a.txt is taken in src/")
	testing.expect(t, strings.contains(d.refused, "src/"), "names the folder")
	// two dragged items with one name
	d = drop({"/p/x/n.txt", "/p/y/n.txt"}, "/p/z", true)
	testing.expect(t, strings.contains(d.refused, "n.txt"), "two named n.txt")
	// no collision elsewhere
	testing.expect_value(t, drop({"/p/a.txt"}, "/p/lib", true).refused, "")
}

@(test)
files_drop_multi :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	// a folder and what is in it: the folder moves (once)
	src := []string{"/p/lib", "/p/lib/b.txt", "/p/c.txt"}
	d := drop(src, "/p/docs", true)
	testing.expect_value(t, d.refused, "")
	moves := files_drop_moves(src, d.dir)
	testing.expect_value(t, len(moves), 2)
	if len(moves) == 2 {
		testing.expect_value(t, moves[0].from, "/p/lib")
		testing.expect_value(t, moves[0].to, "/p/docs/lib")
		testing.expect_value(t, moves[1].to, "/p/docs/c.txt")
	}
	// some there already: only the others move; all there: nothing
	src2 := []string{"/p/docs/q.md", "/p/c.txt"}
	d = drop(src2, "/p/docs", true)
	testing.expect(t, !d.noop && d.refused == "", "one moves")
	testing.expect_value(t, len(files_drop_moves(src2, d.dir)), 1)
	testing.expect(t, drop({"/p/docs/q.md", "/p/docs/r.md"}, "/p/docs/q.md").noop, "all there already")
	// one of them is the target or above it: refused
	d = drop({"/p/lib", "/p/c.txt"}, "/p/lib", true)
	testing.expect(t, strings.contains(d.refused, "into itself"), "onto a dragged folder")
	// a collision for any one refuses the drop
	d = drop({"/p/c.txt", "/p/a.txt"}, "/p/docs", true)
	testing.expect(t, strings.contains(d.refused, "already has a.txt"), "a.txt is taken in docs/")
	// the ghost's count: after nesting
	testing.expect_value(t, len(files_drop_sources(src)), 2)
	testing.expect_value(t, len(files_drop_sources({"/p/a", "/p/a", "/p/a/b/c", "/p/ab"})), 2)
}

@(test)
files_drop_labels :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect_value(t, files_drop_dir_label("/p", "/p/src/x"), "src/x/")
	testing.expect_value(t, files_drop_dir_label("/p", "/p"), "p/")
	// the band a drop highlights: the folder's row and what is below it
	d := Files_Drop{dir = "/p/src"}
	testing.expect(t, files_drop_band(d, "/p/src"), "its row")
	testing.expect(t, files_drop_band(d, "/p/src/a/b"), "inside it")
	testing.expect(t, !files_drop_band(d, "/p/srcx"), "not a sibling")
	testing.expect(t, !files_drop_band(Files_Drop{dir = "/p/src", refused = "no"}, "/p/src"), "refused: none")
	testing.expect(t, !files_drop_band(Files_Drop{dir = "/p/src", noop = true}, "/p/src"), "noop: none")
	testing.expect(t, files_drop_band(Files_Drop{dir = "/p"}, "/p/z"), "the root: every row")
}

// Review round 1: every source must be inside the tree's root (a root switch mid-drag), never the
// root itself; onto a terminal a drag pastes all it carries.
@(test)
files_drop_sources_in_root :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	d := drop({"/q/a.txt"}, "/p/lib", true)
	testing.expect(t, d.refused != "" && !d.noop, "a source from another tree")
	d = drop({"/p/b.txt", "/q/a.txt"}, "/p/lib", true)
	testing.expect(t, d.refused != "", "one source from another tree refuses them all")
	d = drop({"/p"}, "/p/lib", true)
	testing.expect(t, d.refused != "", "the root itself")
	// the paste onto a terminal: the pressed row, or every dragged one when it is among them
	testing.expect_value(t, strings.join(files_drag_paste_paths("/p/a", {"/p/a", "/p/a/x", "/p/b"}), " ", context.temp_allocator), "/p/a /p/b")
	testing.expect_value(t, strings.join(files_drag_paste_paths("/p/c", {"/p/c"}), " ", context.temp_allocator), "/p/c")
	testing.expect_value(t, strings.join(files_drag_paste_paths("/p/c", {"/p/a", "/p/b"}), " ", context.temp_allocator), "/p/c")
}
