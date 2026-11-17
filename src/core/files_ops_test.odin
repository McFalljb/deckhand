package core

// The Files tree's copy, paste, duplicate and undo helpers (files_ops.odin): where a paste goes,
// the copies (unique on a name clash) and a copy drop's target, a cut's refusals, the results'
// data, the undo stack, each record's "changed since" check and its inverse commands, and which
// deletes ask no confirmation.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
TAKEN := [?]string{"/p/src/a.txt", "/p/docs/b.txt"}

@(private = "file")
fake_exists :: proc(path: string) -> bool {
	for p in TAKEN do if p == path do return true
	return false
}

@(test)
files_ops_paste_target :: proc(t: ^testing.T) {
	testing.expect_value(t, files_paste_target("/p", "/p/src", true), "/p/src") // a folder: into it
	testing.expect_value(t, files_paste_target("/p", "/p/src/a.txt", false), "/p/src") // a file: its folder
	testing.expect_value(t, files_paste_target("/p", "", false), "/p") // nothing selected: the root
	testing.expect_value(t, files_paste_target("/p", "/q/x", true), "/p") // another tree's: the root
	testing.expect_value(t, files_paste_target("/p", "/pq/x", true), "/p") // a prefix is not inside
}

@(test)
files_ops_copy_items :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	// a.txt into src (taken there): unique; c.txt free: as named; src/x nested in src: once
	items := files_copy_items({"/p/a.txt", "/p/c.txt"}, "/p/src", fake_exists)
	testing.expect_value(t, len(items), 2)
	testing.expect_value(t, items[0], Files_Copy_Item{from = "/p/a.txt", to = "/p/src/a.txt", unique = true})
	testing.expect_value(t, items[1], Files_Copy_Item{from = "/p/c.txt", to = "/p/src/c.txt", unique = false})
	// nested sources copy once (the folder holds it)
	items = files_copy_items({"/p/lib", "/p/lib/x.go"}, "/p/docs", fake_exists)
	testing.expect_value(t, len(items), 1)
	testing.expect_value(t, items[0].to, "/p/docs/lib")
	// two with one name: the second is unique (never refused, never over the first)
	items = files_copy_items({"/p/a/n.txt", "/p/b/n.txt"}, "/p/out", fake_exists)
	testing.expect(t, !items[0].unique && items[1].unique, "the second n.txt becomes n copy.txt")
	// into its own folder: a duplicate (the name is taken by itself)
	items = files_copy_items({"/p/src/a.txt"}, "/p/src", fake_exists)
	testing.expect(t, items[0].unique && items[0].to == "/p/src/a.txt", "pasted in place: unique")
	// Duplicate: from = to, unique
	d := files_duplicate_items({"/p/a.txt", "/p/lib", "/p/lib/x"})
	testing.expect_value(t, len(d), 2)
	testing.expect_value(t, d[0], Files_Copy_Item{from = "/p/a.txt", to = "/p/a.txt", unique = true})
}

@(test)
files_ops_copy_drop :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	drop :: proc(sources: []string, over: string, over_dir := false) -> Files_Drop {
		return files_copy_drop_at({sources = sources, root = "/p", over = over, over_dir = over_dir, exists = fake_exists})
	}
	// its own folder: no no-op (a move's would be), it duplicates
	d := drop({"/p/a.txt"}, "/p/b.txt")
	testing.expect(t, d.dir == "/p" && !d.noop && d.refused == "", "into its own folder: a duplicate")
	// a taken name is no refusal (b.txt into docs, where b.txt is)
	d = drop({"/p/b.txt"}, "/p/docs", true)
	testing.expect(t, d.dir == "/p/docs" && d.refused == "", "a taken name: a copy")
	// into itself: refused
	d = drop({"/p/lib"}, "/p/lib/x", true)
	testing.expect_value(t, d.refused, "cannot copy lib into itself")
	// another tree's, the root: refused
	testing.expect_value(t, drop({"/q/a"}, "", false).refused, "a is not in this tree")
	testing.expect_value(t, drop({"/p"}, "/p/lib", true).refused, "p is not in this tree")
	// nowhere: outside the root
	testing.expect_value(t, files_copy_drop_at({sources = {"/p/a"}, root = "/p", over = "/q/z", over_dir = true}).dir, "")
}

@(test)
files_ops_cut_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	testing.expect_value(t, files_cut_refused({"/p/x/b.txt"}, "/p/docs", "docs/", fake_exists), "docs/ already has b.txt") // never "b copy.txt"
	testing.expect_value(t, files_cut_refused({"/p/lib"}, "/p/lib/sub", "lib/sub/", fake_exists), "cannot move lib into itself")
	testing.expect_value(t, files_cut_refused({"/p/a/n", "/p/b/n"}, "/p/c", "c/", fake_exists), "two of them are named n")
	testing.expect_value(t, files_cut_refused({"/p/c.txt"}, "/p/docs", "docs/", fake_exists), "")
	// already there: nothing to move, nothing refused
	testing.expect_value(t, files_cut_refused({"/p/docs/b.txt"}, "/p/docs", "docs/", fake_exists), "")
}

@(test)
files_ops_results :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	p, sk := files_copy_result(`{"path":"/p/a copy","copied":4,"skipped":[{"path":".git","why":"a git repository's folder: not copied"},{"path":"x/.claude.json","why":"a credential: not copied"}]}`)
	testing.expect_value(t, p, "/p/a copy")
	testing.expect_value(t, len(sk), 2)
	testing.expect_value(t, files_skipped_text(sk), "2 skipped: .git, a credential") // a credential is never named
	testing.expect_value(t, files_skipped_text({"a", "b", "c", "d", "e"}), "5 skipped: a, b, c and 2 more")
	testing.expect_value(t, files_skipped_text(nil), "")
	p, sk = files_copy_result("not json")
	testing.expect(t, p == "" && len(sk) == 0, "bad data: nothing")
	n, rs := files_trash_result(`{"trashed":2,"restore":[{"path":"/p/a","id":"i1"},{"path":"/p/b","id":""}]}`)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, len(rs), 1) // an empty id is no restore
	testing.expect_value(t, rs[0], Files_Restore{path = "/p/a", id = "i1"})
	n, rs = files_trash_result(`{"trashed":1}`)
	testing.expect(t, n == 1 && len(rs) == 0, "no restore ids")
}

// A temp folder (real path) with a file and an empty folder.
@(private = "file")
ops_dir :: proc() -> string {
	made := fmt.tprintf("%s/dh-ops-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(made)
	return fs_real(made, context.allocator)
}

@(test)
files_ops_undo_stack :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := ops_dir()
	defer os.remove_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/f", dir), transmute([]u8)string("x"))
	st: Files_Undo_Stack
	defer files_undo_clear(&st, "")
	f := fmt.tprintf("%s/f", dir)
	for i in 0 ..< FILES_UNDO_MAX + 5 do files_undo_push(&st, dir, files_undo_make(.Create, dir, {f}))
	testing.expect_value(t, len(st.ops), FILES_UNDO_MAX) // the last 20
	testing.expect_value(t, files_undo_top(&st, dir).serial, u64(FILES_UNDO_MAX + 5))
	// nothing there: no record
	testing.expect_value(t, files_undo_push(&st, dir, files_undo_make(.Create, dir, {fmt.tprintf("%s/gone", dir)})), u64(0))
	// another root: the stack is emptied (the tree shows another project or checkout)
	testing.expect(t, files_undo_top(&st, "/elsewhere") == nil, "another root: nothing to undo")
	testing.expect_value(t, len(st.ops), 0)
	files_undo_push(&st, dir, files_undo_make(.Create, dir, {f}))
	testing.expect_value(t, len(st.ops), 1) // and back: the old ones are gone
	files_undo_pop(&st)
	testing.expect(t, files_undo_top(&st, dir) == nil, "popped")
}

@(test)
files_ops_undo_checks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := ops_dir()
	defer os.remove_all(dir)
	f := fmt.tprintf("%s/f.txt", dir)
	d := fmt.tprintf("%s/d", dir)
	_ = os.write_entire_file(f, nil)
	os.make_directory(d)
	// Create: as made: undoable (one delete_path of them, the window's own)
	u := files_undo_make(.Create, dir, {f, d})
	defer files_undo_free(u)
	testing.expect_value(t, files_undo_check(u, dir), "")
	cmds := files_undo_commands(u)
	testing.expect_value(t, len(cmds), 1)
	dp, _ := cmds[0].(Delete_Path)
	testing.expect(t, dp.undoable && len(dp.paths) == 2, "a delete_path of both, undoable")
	// another root on screen: refused
	testing.expect_value(t, files_undo_check(u, "/elsewhere"), "the tree shows another folder now")
	// the folder got a file: changed since
	_ = os.write_entire_file(fmt.tprintf("%s/in", d), transmute([]u8)string("1"))
	testing.expect_value(t, files_undo_check(u, dir), "d changed since (it is not empty)")
	os.remove(fmt.tprintf("%s/in", d))
	// the file was written: changed since (size)
	_ = os.write_entire_file(f, transmute([]u8)string("hello"))
	testing.expect_value(t, files_undo_check(u, dir), "f.txt changed since")
	// gone
	os.remove(f)
	testing.expect_value(t, files_undo_check(u, dir), "f.txt is gone")
	// another file at that name: changed since (another inode, even with the same size)
	_ = os.write_entire_file(f, nil)
	keep := fmt.tprintf("%s/keep", dir) // holds the old inode number from being reused
	_ = os.write_entire_file(keep, nil)
	testing.expect(t, files_undo_check(u, dir) != "", "another file there")

	// Move: back while it is the same item and its old place is free
	a := fmt.tprintf("%s/a.txt", dir)
	b := fmt.tprintf("%s/b.txt", dir)
	_ = os.write_entire_file(b, transmute([]u8)string("b"))
	m := files_undo_make(.Move, dir, {b}, froms = {a})
	defer files_undo_free(m)
	testing.expect_value(t, files_undo_check(m, dir), "")
	rp, _ := files_undo_commands(m)[0].(Rename_Path)
	testing.expect_value(t, rp, Rename_Path{from = b, to = a})
	// edited since the move: still that item, still undoable
	_ = os.write_entire_file(b, transmute([]u8)string("bb"))
	testing.expect_value(t, files_undo_check(m, dir), "")
	// its old place is taken: refused
	_ = os.write_entire_file(a, nil)
	testing.expect_value(t, files_undo_check(m, dir), "a.txt is taken")
	os.remove(a)
	// a path outside the root it was done in (a forged record): refused
	bad := files_undo_make(.Move, dir, {b}, froms = {"/etc/a"})
	defer files_undo_free(bad)
	testing.expect_value(t, files_undo_check(bad, dir), "/etc/a is outside the project")
	// several moves undo the last first
	c := fmt.tprintf("%s/c.txt", dir)
	_ = os.write_entire_file(c, nil)
	m2 := files_undo_make(.Move, dir, {b, c}, froms = {fmt.tprintf("%s/x/b.txt", dir), fmt.tprintf("%s/x/c.txt", dir)})
	defer files_undo_free(m2)
	cm := files_undo_commands(m2)
	r0, _ := cm[0].(Rename_Path)
	testing.expect_value(t, r0.from, c)

	// Copy: a copied folder that got an entry: changed since
	cd := fmt.tprintf("%s/cd", dir)
	os.make_directory(cd)
	cp := files_undo_make(.Copy, dir, {cd})
	defer files_undo_free(cp)
	testing.expect_value(t, files_undo_check(cp, dir), "")
	time.sleep(20 * time.Millisecond)
	_ = os.write_entire_file(fmt.tprintf("%s/new", cd), nil)
	testing.expect_value(t, files_undo_check(cp, dir), "cd changed since")

	// Trash: restore ids; something at the old path: refused; no id: refused
	gone := fmt.tprintf("%s/gone.txt", dir)
	tr := files_undo_make(.Trash, dir, {gone, b}, ids = {"id1", "id2"})
	defer files_undo_free(tr)
	testing.expect_value(t, files_undo_check(tr, dir), "something is at b.txt now")
	tr2 := files_undo_make(.Trash, dir, {gone}, ids = {"id1"})
	defer files_undo_free(tr2)
	testing.expect_value(t, files_undo_check(tr2, dir), "")
	rr, _ := files_undo_commands(tr2)[0].(Restore_Path)
	testing.expect_value(t, rr.id, "id1")
}

@(test)
files_ops_delete_unasked :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := ops_dir()
	defer os.remove_all(dir)
	f := fmt.tprintf("%s/f", dir)
	_ = os.write_entire_file(f, nil)
	user := Caller{kind = .UI}
	plan := []string{f}
	home_dev := true
	{
		h, _, hok := files_lstamp(os.get_env("HOME", context.temp_allocator))
		s, _, _ := files_lstamp(f)
		home_dev = hok && h.dev == s.dev
	}
	// the user in the window, the tree's own delete, on the home volume: no confirmation
	testing.expect_value(t, files_delete_unasked(Delete_Path{paths = plan, undoable = true}, user, plan), home_dev)
	// not marked undoable (the bar's, a menu elsewhere): asks
	testing.expect(t, !files_delete_unasked(Delete_Path{paths = plan}, user, plan), "not undoable: asks")
	// a browser, another machine, a script, an agent, a pi tab: ask, undoable or not
	for c in ([]Caller{{kind = .UI, web = true}, {kind = .UI, hub = true}, {kind = .Script}, {kind = .Control}, {kind = .Panel}, {kind = .Internal}}) {
		testing.expectf(t, !files_delete_unasked(Delete_Path{paths = plan, undoable = true}, c, plan), "%v asks", c)
	}
	// a confirmed one is the gate's as before
	testing.expect(t, !files_delete_unasked(Delete_Path{paths = plan, undoable = true, confirm = "tok"}, user, plan), "a token: as before")
	// more than the restore ids kept: asks
	many := make([]string, FS_RESTORE_MAX + 1, context.temp_allocator)
	for &m in many do m = f
	testing.expect(t, !fs_restore_promised(many), "past FS_RESTORE_MAX: no promise")
	// a path on another volume than the home folder's (devfs): no promise
	testing.expect(t, !fs_restore_promised({"/dev/null"}), "another volume: asks")
	testing.expect(t, !fs_restore_promised({fmt.tprintf("%s/missing", dir)}), "missing: no promise")
}

// Review round 1 (P2-1): undo of a copied FOLDER compares the whole tree (an edit deep inside
// is "changed since"), and its delete always asks (no undoable: the bar confirms).
@(test)
files_ops_undo_copied_folder_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := ops_dir()
	defer os.remove_all(dir)
	api := fmt.tprintf("%s/api copy", dir)
	os.make_directory_all(fmt.tprintf("%s/handlers", api))
	x := fmt.tprintf("%s/handlers/x.go", api)
	_ = os.write_entire_file(x, transmute([]u8)string("package x"))
	f := fmt.tprintf("%s/f.txt", dir)
	_ = os.write_entire_file(f, nil)
	cp := files_undo_make(.Copy, dir, {api})
	defer files_undo_free(cp)
	testing.expect_value(t, files_undo_check(cp, dir), "")
	dp, _ := files_undo_commands(cp)[0].(Delete_Path)
	testing.expect(t, !dp.undoable, "a folder's undo asks in the bar")
	cf := files_undo_make(.Copy, dir, {f})
	defer files_undo_free(cf)
	df, _ := files_undo_commands(cf)[0].(Delete_Path)
	testing.expect(t, df.undoable, "a file's undo asks nothing")
	// an edit deep inside (the top folder's mtime does not change)
	time.sleep(20 * time.Millisecond)
	_ = os.write_entire_file(x, transmute([]u8)string("package x // edited"))
	testing.expect_value(t, files_undo_check(cp, dir), "api copy changed since")
	// a file added deep inside
	cp2 := files_undo_make(.Copy, dir, {api})
	defer files_undo_free(cp2)
	_ = os.write_entire_file(fmt.tprintf("%s/handlers/y.go", api), nil)
	testing.expect_value(t, files_undo_check(cp2, dir), "api copy changed since")
}

// The merge with #169's rewritten delete_path: the user's undoable delete in the window asks
// nothing; a browser's, a control caller's and a plain one ask.
@(test)
files_ops_undoable_delete_through_run_command :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	state = State{}
	defer state = State{}
	dir := ops_dir()
	defer os.remove_all(dir)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(dir), label = "proj"})
	fs_trash_fn = proc(path: string) -> bool {return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil}
	home_dev := false
	{
		h, _, hok := files_lstamp(os.get_env("HOME", context.temp_allocator))
		s, _, _ := files_lstamp(dir)
		home_dev = hok && h.dev == s.dev
	}
	if !home_dev do return // the temp folder is on another volume: it asks (files_ops_delete_unasked)
	for name in ([]string{"a", "b", "c", "d", "e"}) do _ = os.write_entire_file(fmt.tprintf("%s/%s", dir, name), nil)
	p :: proc(dir, n: string) -> string {return fmt.tprintf("%s/%s", dir, n)}
	// the user in the window, undoable: one path and a batch, no confirmation
	r := run_command(Delete_Path{path = p(dir, "a"), undoable = true}, {kind = .UI})
	testing.expectf(t, r.ok && !os.exists(p(dir, "a")), "single: %q", r.error)
	r = run_command(Delete_Path{paths = {p(dir, "b"), p(dir, "c")}, undoable = true}, {kind = .UI})
	testing.expectf(t, r.ok && !os.exists(p(dir, "b")) && !os.exists(p(dir, "c")), "batch: %q", r.error)
	testing.expect_value(t, len(state.pending_confirmations), 0)
	// a browser, a control caller (its policy: ask), the user without undoable: ask
	state.settings.confirm[.Control][.Delete] = .Ask
	for c in ([]Caller{{kind = .UI, web = true}, {kind = .Control}}) {
		r = run_command(Delete_Path{path = p(dir, "d"), undoable = true}, c)
		testing.expectf(t, r.error == "needs_confirmation" && os.exists(p(dir, "d")), "%v: %q", c, r.error)
		r = run_command(Delete_Path{paths = {p(dir, "d"), p(dir, "e")}, undoable = true}, c)
		testing.expectf(t, r.error == "needs_confirmation" && os.exists(p(dir, "e")), "%v batch: %q", c, r.error)
	}
	r = run_command(Delete_Path{path = p(dir, "d")}, {kind = .UI})
	testing.expect_value(t, r.error, "needs_confirmation")
}

// Review round 1 (P2-2): a cut belongs to the tree it was cut in; a copy may go to another
// project (the core's rules decide); a row hidden since (ignored rows hidden) is never pasted.
@(test)
files_ops_clip_refused :: proc(t: ^testing.T) {
	hidden :: proc(root, path: string) -> bool {return strings.has_suffix(path, "/node_modules")}
	testing.expect_value(t, files_clip_refused("/p", "/p", {"/p/a"}, true, hidden), "")
	testing.expect_value(t, files_clip_refused("/q", "/p", {"/p/a"}, true, hidden), "the cut items are in another project or checkout: cut them again here")
	testing.expect_value(t, files_clip_refused("/q", "/p", {"/p/a"}, false, hidden), "") // a copy across projects: the core decides
	testing.expect_value(t, files_clip_refused("/p", "/p", {"/p/a", "/p/node_modules"}, false, hidden), "node_modules is hidden now (ignored files are hidden): show them, or copy again")
}

// P3 (a): Paste from a row's menu goes where that row says; from the empty space: the root.
@(test)
files_ops_menu_paste_target :: proc(t: ^testing.T) {
	testing.expect_value(t, files_paste_target("/p", "/p", true), "/p")
	testing.expect_value(t, files_paste_target("/p", "/p/lib", true), "/p/lib")
	testing.expect_value(t, files_paste_target("/p", "/p/lib/a.go", false), "/p/lib")
}

// P3 (b): an undo that stops partway keeps what was not undone (the last record shrinks).
@(test)
files_ops_undo_partial :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := ops_dir()
	defer os.remove_all(dir)
	st: Files_Undo_Stack
	defer files_undo_clear(&st, "")
	files_undo_push(&st, dir, files_undo_make(.Trash, dir, {"/x/1", "/x/2", "/x/3"}, ids = {"a", "b", "c"}))
	files_undo_keep_rest(&st, 2) // restored the first two
	u := files_undo_top(&st, dir)
	testing.expect(t, u != nil && len(u.items) == 1 && u.items[0].id == "c", "the third stays undoable")
	for n in ([]string{"m1", "m2", "m3"}) do _ = os.write_entire_file(fmt.tprintf("%s/%s", dir, n), nil)
	files_undo_push(&st, dir, files_undo_make(.Move, dir, {fmt.tprintf("%s/m1", dir), fmt.tprintf("%s/m2", dir), fmt.tprintf("%s/m3", dir)}, froms = {"/o/1", "/o/2", "/o/3"}))
	files_undo_keep_rest(&st, 1) // moves undo the last first: m3 went back
	u = files_undo_top(&st, dir)
	testing.expect(t, u != nil && len(u.items) == 2 && u.items[1].from == "/o/2", "m1 and m2 stay undoable")
	files_undo_keep_rest(&st, 2)
	testing.expect_value(t, len(st.ops), 1) // nothing left of it: gone
}
