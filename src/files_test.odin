package main

// The Files tab through the command layer: the tree model (lazy listings,
// folders first in natural order, expand/collapse, ignored and dotfiles,
// git codes), virtualisation bounds, preview tabs, and file commands seen
// by the tree (rename, delete with confirmation, outside changes). No
// window: the session is made by hand, as in editor_test.odin.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

// A clean State with one open session in a fresh temp folder that is also a
// project. Returns the folder (real path).
@(private = "file")
fsetup :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	files_refresh()
	files_state_gen += 1
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/pi-desk-files-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir := fs_real(made, context.allocator)
	ensure(strings.contains(dir, "/pi-desk-files-test-") && os.is_directory(dir), "files tests: no temp folder")
	append(&state.projects, Project{id = new_id(), cwd = dir, label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("f-1"), project_id = state.projects[0].id, cwd = dir}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	fs_trash_fn = proc(path: string) -> bool {return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil}
	return dir
}

@(private = "file")
fwrite :: proc(dir, name, text: string) {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	os.make_directory_all(filepath.dir(p))
	_ = os.write_entire_file(p, transmute([]u8)text)
}

@(private = "file")
tree :: proc() -> string {return files_rows_text(files_rows(files_root()))}

@(private = "file")
wait_git :: proc() {
	for _ in 0 ..< 500 {
		inbox_drain()
		busy := false
		for s in fs_model.status do if s.loading do busy = true
		if !busy do return
		time.sleep(10 * time.Millisecond)
	}
}

@(test)
files_tree_sort_expand_collapse :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, "a10.txt", "")
	fwrite(dir, "a2.txt", "")
	fwrite(dir, "B.txt", "")
	fwrite(dir, ".env.example", "")
	fwrite(dir, "zdir/inner/deep.txt", "")
	fwrite(dir, "Adir/x.txt", "")
	testing.expect_value(t, files_root(), dir)
	// folders first, then natural, case-insensitive order; dotfiles listed
	testing.expect_value(t, tree(), "Adir\nzdir\n.env.example\na2.txt\na10.txt\nB.txt\n")
	// expand (relative to the session's folder), twice is a no-op
	r := run_command(Files_Expand{path = "zdir", expanded = true}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, run_command(Files_Expand{path = "zdir", expanded = true}, {kind = .Script}).ok)
	testing.expect(t, run_command(Files_Expand{path = "zdir/inner", expanded = true}, {kind = .Script}).ok)
	testing.expect_value(t, tree(), "Adir\nzdir/\n  inner/\n    deep.txt\n.env.example\na2.txt\na10.txt\nB.txt\n")
	// collapsing a parent keeps the child's state for next time
	testing.expect(t, run_command(Files_Expand{path = "zdir", expanded = false}, {kind = .Script}).ok)
	testing.expect_value(t, tree(), "Adir\nzdir\n.env.example\na2.txt\na10.txt\nB.txt\n")
	testing.expect(t, run_command(Files_Expand{path = "zdir", expanded = true}, {kind = .Script}).ok)
	testing.expect(t, strings.contains(tree(), "    deep.txt"))
	// state: per root, relative paths
	testing.expect_value(t, json_path(state_json(), "files.expanded.0.root"), dir)
	testing.expect_value(t, json_path(state_json(), "files.expanded.0.dirs.#"), "2")
	// collapse all
	testing.expect(t, run_command(Files_Collapse_All{root = dir}, {kind = .Script}).ok)
	testing.expect_value(t, tree(), "Adir\nzdir\n.env.example\na2.txt\na10.txt\nB.txt\n")
	// reveal: the folders above open, the row is selected
	testing.expect(t, run_command(Files_Reveal{path = "zdir/inner/deep.txt"}, {kind = .Script}).ok)
	testing.expect(t, strings.contains(tree(), "    deep.txt"))
	testing.expect_value(t, files_ui.cursor, fmt.tprintf("%s/zdir/inner/deep.txt", dir))
	// refused: a file, outside every project, .git
	testing.expect_value(t, run_command(Files_Expand{path = "a2.txt", expanded = true}, {kind = .Script}).error, "not a folder")
	testing.expect_value(t, run_command(Files_Expand{path = "/tmp", expanded = true}, {kind = .Script}).error, "only inside a project folder")
	// a pi tab's bridge may not drive another project's tree (who = anyone: not panels)
	testing.expect_value(t, run_command(Files_Expand{path = "zdir", expanded = false}, {kind = .Panel, tab_id = state.open_sessions[0].tabs[0].id}).error, "not allowed for this caller")
	// the left tab
	testing.expect(t, run_command(Set_Left_Tab{tab = .Files}, {kind = .Script}).ok)
	testing.expect_value(t, json_path(state_json(), "layout.left_tab"), "files")
	// natural order
	testing.expect(t, fs_name_less("a2", "a10") && !fs_name_less("a10", "a2"))
	testing.expect(t, fs_name_less("file", "File2") && fs_name_less("x01", "x2") && fs_name_less("Abc", "abd"))
}

@(test)
files_tree_git_ignored_and_changes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	if _, ok := git_run(dir, "init", "-q"); !ok do return // no git: nothing to check
	fwrite(dir, ".gitignore", "node_modules/\n*.log\n")
	fwrite(dir, "mod.txt", "one\n")
	fwrite(dir, "same.txt", "x\n")
	fwrite(dir, "src/a.c", "int a;\n")
	git_run(dir, "add", ".")
	git_run(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "x")
	fwrite(dir, "mod.txt", "two\n")
	fwrite(dir, "new.txt", "")
	fwrite(dir, "staged.txt", "")
	git_run(dir, "add", "staged.txt")
	fwrite(dir, "debug.log", "")
	fwrite(dir, "node_modules/pkg/index.js", "")
	rows := files_rows(dir)
	wait_git()
	code :: proc(rows: []Files_Row, name: string) -> string {
		for r in rows do if r.name == name do return files_git_letter(fs_git_code_cached(r.path, r.kind == .Dir), r.kind == .Dir)
		return "<none>"
	}
	ignored :: proc(rows: []Files_Row, name: string) -> bool {
		for r in rows do if r.name == name do return r.ignored
		return false
	}
	rows = files_rows(dir)
	testing.expect_value(t, code(rows, "mod.txt"), "M")
	testing.expect_value(t, code(rows, "new.txt"), "U")
	testing.expect_value(t, code(rows, "staged.txt"), "A")
	testing.expect_value(t, code(rows, "same.txt"), "")
	testing.expect_value(t, code(rows, "src"), "")
	// ignored entries are listed, marked; .git is not
	testing.expect(t, ignored(rows, "node_modules") && ignored(rows, "debug.log") && !ignored(rows, "src"))
	testing.expect(t, !strings.contains(files_rows_text(rows), ".git\n"))
	// inside an ignored folder everything is ignored (git is not asked)
	testing.expect(t, run_command(Files_Expand{path = "node_modules", expanded = true}, {kind = .Script}).ok)
	testing.expect(t, run_command(Files_Expand{path = "node_modules/pkg", expanded = true}, {kind = .Script}).ok)
	rows = files_rows(dir)
	testing.expect(t, ignored(rows, "pkg") && ignored(rows, "index.js"))
	// a changed file in an expanded folder marks the folder's git code
	fwrite(dir, "src/a.c", "int b;\n")
	fs_model_changed(fmt.tprintf("%s/src/a.c", dir)) // as the watcher reports it
	testing.expect(t, run_command(Files_Expand{path = "src", expanded = true}, {kind = .Script}).ok)
	rows = files_rows(dir)
	code(rows, "src") // drawing a row asks for a fresh status (a worker; runs are FS_STATUS_GAP apart)
	wait_git()
	time.sleep(FS_STATUS_GAP)
	fs_model_tick()
	wait_git()
	testing.expect_value(t, code(rows, "src"), "•")
	testing.expect_value(t, code(rows, "a.c"), "M")
	// a file made outside shows up once the watcher reports it; expansion stays
	fwrite(dir, "src/b.c", "")
	before := files_rows_text(files_rows(dir))
	testing.expect(t, !strings.contains(before, "b.c"))
	fs_model_changed(fmt.tprintf("%s/src/b.c", dir))
	after := files_rows_text(files_rows(dir))
	testing.expect(t, strings.contains(after, "  b.c\n"), after)
	testing.expect(t, strings.contains(after, "src/\n"), after)
	// list_dir over the wire: ignored only when asked
	r := run_command(List_Dir{path = ".", ignored = true}, {kind = .Script})
	testing.expect(t, r.ok && strings.contains(r.data, `"name":"debug.log","kind":"file","ignored":true`), r.data)
	r = run_command(List_Dir{path = "."}, {kind = .Script})
	testing.expect(t, r.ok && !strings.contains(r.data, "debug.log"), r.data)
}

@(test)
files_rename_and_delete_through_commands :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, "d/old.txt", "x")
	testing.expect(t, run_command(Files_Expand{path = "d", expanded = true}, {kind = .UI}).ok)
	testing.expect_value(t, tree(), "d/\n  old.txt\n")
	// new file and folder (the tree's buttons): seen at once
	testing.expect(t, run_command(Create_File{path = fmt.tprintf("%s/d/new.txt", dir)}, {kind = .UI}).ok)
	testing.expect(t, run_command(Create_Dir{path = fmt.tprintf("%s/d/sub", dir)}, {kind = .UI}).ok)
	testing.expect_value(t, tree(), "d/\n  sub\n  new.txt\n  old.txt\n")
	// rename (the inline field): the row follows
	testing.expect(t, run_command(Rename_Path{from = "d/old.txt", to = "d/renamed.txt"}, {kind = .UI}).ok)
	testing.expect_value(t, tree(), "d/\n  sub\n  new.txt\n  renamed.txt\n")
	// delete asks the user first, then goes to the Trash (a fake here)
	r := run_command(Delete_Path{path = fmt.tprintf("%s/d/new.txt", dir)}, {kind = .UI})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect_value(t, tree(), "d/\n  sub\n  new.txt\n  renamed.txt\n")
	tok := state.pending_confirmations[0].token
	testing.expect(t, run_command(Delete_Path{path = fmt.tprintf("%s/d/new.txt", dir), confirm = tok}, {kind = .UI}).ok)
	testing.expect(t, os.exists(fmt.tprintf("%s/d/new.txt.trashed", dir)))
	testing.expect(t, strings.contains(tree(), "new.txt.trashed")) // the fake trash renames in place
	testing.expect(t, !strings.contains(tree(), "  new.txt\n"))
	// renaming a folder that is expanded: it stays open under its new name, and so does the selection
	files_select(fmt.tprintf("%s/d/sub", dir))
	testing.expect(t, run_command(Rename_Path{from = "d", to = "e"}, {kind = .UI}).ok)
	testing.expect_value(t, tree(), "e/\n  sub\n  new.txt.trashed\n  renamed.txt\n")
	testing.expect_value(t, files_ui.cursor, fmt.tprintf("%s/e/sub", dir))
}

@(test)
files_preview_tabs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, "a.txt", "a\n")
	fwrite(dir, "b.txt", "b\n")
	fwrite(dir, "c.txt", "c\n")
	s := &state.open_sessions[0]
	preview :: proc(s: ^Open_Session, i: int) -> bool {return i < len(s.tabs) && s.tabs[i].kind.(Editor_Tab).preview}
	// a single click: a preview tab
	ra := run_command(Open_File{path = "a.txt", preview = true}, {kind = .UI})
	testing.expect(t, ra.ok, ra.error)
	testing.expect_value(t, len(s.tabs), 2)
	testing.expect(t, preview(s, 1))
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.1.preview"), "true")
	// the next preview replaces it, in the same place
	rb := run_command(Open_File{path = "b.txt", preview = true}, {kind = .UI})
	testing.expect_value(t, len(s.tabs), 2)
	testing.expect_value(t, s.tabs[1].title, "b.txt")
	testing.expect_value(t, s.active_tab, rb.created_id)
	testing.expect(t, editor_of(ra.created_id) == nil)
	// a preview of a file already open only focuses it
	testing.expect_value(t, run_command(Open_File{path = "b.txt", preview = true}, {kind = .UI}).created_id, rb.created_id)
	// editing keeps it (editor_tick turns an edited preview into a tab)
	e := editor_of(rb.created_id)
	ed_insert(e, "x")
	files_keep_edited_preview()
	inbox_drain()
	testing.expect(t, !preview(s, 1))
	// now a preview opens beside it
	rc := run_command(Open_File{path = "c.txt", preview = true}, {kind = .UI})
	testing.expect_value(t, len(s.tabs), 3)
	testing.expect(t, preview(s, 2))
	// double-click / Enter (open for good) keeps the preview tab
	testing.expect_value(t, run_command(Open_File{path = "c.txt"}, {kind = .UI}).created_id, rc.created_id)
	testing.expect(t, !preview(s, 2))
	// keep_tab
	rd := run_command(Open_File{path = "a.txt", preview = true}, {kind = .UI})
	testing.expect(t, preview(s, 3))
	testing.expect(t, run_command(Keep_Tab{tab_id = rd.created_id}, {kind = .Script}).ok)
	testing.expect(t, !preview(s, 3))
	testing.expect_value(t, run_command(Keep_Tab{tab_id = s.tabs[0].id}, {kind = .Script}).error, "no such editor tab")
}

@(test)
files_virtualisation_bounds :: proc(t: ^testing.T) {
	// 10,000 rows of 24 px in a 600 px list: 26 rows laid out at most
	first, last, sc := files_visible(10_000, 0, 600, 24)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 26)
	testing.expect_value(t, sc, 0)
	first, last, sc = files_visible(10_000, 120_000, 600, 24)
	testing.expect_value(t, first, 5000)
	testing.expect_value(t, last, 5026)
	// past the end: clamped so the last row sits at the bottom
	first, last, sc = files_visible(10_000, 1e9, 600, 24)
	testing.expect_value(t, sc, f32(10_000 * 24 - 600))
	testing.expect_value(t, last, 10_000)
	testing.expect(t, last - first <= 26)
	// fewer rows than the list holds: no scrolling
	first, last, sc = files_visible(5, 300, 600, 24)
	testing.expect_value(t, first, 0)
	testing.expect_value(t, last, 5)
	testing.expect_value(t, sc, 0)
	first, last, _ = files_visible(0, 0, 600, 24)
	testing.expect_value(t, last, 0)
}

@(test)
files_big_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	os.make_directory_all(fmt.tprintf("%s/big", dir))
	for i in 0 ..< 10_000 {
		f, err := os.open(fmt.tprintf("%s/big/f%d.txt", dir, i), {.Write, .Create}, os.Permissions_Default_File)
		if err == nil do os.close(f)
	}
	t0 := time.tick_now()
	testing.expect(t, run_command(Files_Expand{path = "big", expanded = true}, {kind = .Script}).ok)
	rows := files_rows(dir)
	ms := time.duration_milliseconds(time.tick_since(t0))
	testing.expect_value(t, len(rows), 10_001)
	testing.expect_value(t, rows[1].name, "f0.txt")
	testing.expect_value(t, rows[3].name, "f2.txt") // natural order
	testing.expect_value(t, rows[10_000].name, "f9999.txt")
	// rows are cached: asking again is free
	t1 := time.tick_now()
	files_rows(dir)
	again := time.duration_milliseconds(time.tick_since(t1))
	fmt.printf("files_big_folder: 10k entries listed and laid out flat in %.1f ms, cached %.3f ms\n", ms, again)
	testing.expect(t, again < 5)
}

@(test)
files_expansion_is_saved :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, "a/b/c.txt", "")
	fwrite(dir, "gone/x.txt", "")
	testing.expect(t, run_command(Set_Left_Tab{tab = .Files}, {kind = .UI}).ok)
	testing.expect(t, run_command(Files_Reveal{path = "a/b/c.txt"}, {kind = .UI}).ok)
	testing.expect(t, run_command(Files_Expand{path = "gone", expanded = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Files_Filter{text = "c"}, {kind = .UI}).ok)
	text := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(text, `"left_tab":"files"`), text)
	testing.expect(t, !strings.contains(text, `"filter"`), "the filter is not saved")
	os.remove(fmt.tprintf("%s/gone/x.txt", dir))
	os.remove(fmt.tprintf("%s/gone", dir))
	// a fresh start with the same project: the tab and the folders come back (gone ones dropped)
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, state.layout.left_tab, Left_Tab.Files)
	testing.expect_value(t, json_path(state_json(), "files.expanded.0.root"), dir)
	testing.expect_value(t, json_path(state_json(), "files.expanded.0.dirs.#"), "2")
	testing.expect_value(t, json_path(state_json(), "files.expanded.0.dirs.0"), "a")
	testing.expect_value(t, json_path(state_json(), "files.expanded.0.dirs.1"), "a/b")
}

// FSEvents flags as the watcher reports them
@(private = "file")
FSE_MODIFIED :: u32(0x1000 | 0x10000) // ItemModified | ItemIsFile
@(private = "file")
FSE_CREATED :: u32(0x100 | 0x10000) // ItemCreated | ItemIsFile

@(private = "file")
git_commit_all :: proc(dir: string) -> bool {
	if _, ok := git_run(dir, "init", "-q"); !ok do return false
	git_run(dir, "add", ".")
	git_run(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "x")
	return true
}

@(test)
files_burst_content_changes_do_not_relist :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, "src/a.c", "int a;\n")
	testing.expect(t, run_command(Files_Expand{path = "src", expanded = true}, {kind = .Script}).ok)
	files_rows(dir)
	base := fs_stats.relists
	// a build rewriting a file 50 times: the folder's entries did not change
	for _ in 0 ..< 50 {
		fs_model_changed(fmt.tprintf("%s/src/a.c", dir), FSE_MODIFIED)
		files_rows(dir)
	}
	testing.expectf(t, fs_stats.relists == base, "content changes relisted %d times", fs_stats.relists - base)
	// a new file is a change of entries: listed again, once
	fwrite(dir, "src/b.c", "")
	fs_model_changed(fmt.tprintf("%s/src/b.c", dir), FSE_CREATED)
	testing.expect(t, strings.contains(files_rows_text(files_rows(dir)), "  b.c\n"))
	testing.expect_value(t, fs_stats.relists, base + 1)
}

@(test)
files_burst_git_status_is_rate_limited :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, ".gitignore", "node_modules/\n")
	fwrite(dir, "a.c", "int a;\n")
	fwrite(dir, "node_modules/x.js", "")
	if !git_commit_all(dir) do return
	a := fmt.tprintf("%s/a.c", dir)
	files_rows(dir) // registers the repository, lists node_modules as ignored
	wait_git()
	base := fs_stats.status_runs
	// a repository that keeps changing: git status is not restarted back to back
	for i in 0 ..< 30 {
		fwrite(dir, "a.c", fmt.tprintf("int a%d;\n", i))
		fs_model_changed(a, FSE_MODIFIED)
		fs_git_code_cached(a, false) // a draw asks for the codes
		wait_git()
	}
	testing.expectf(t, fs_stats.status_runs - base <= 1, "git status ran %d times for 30 quick changes", fs_stats.status_runs - base)
	// later, the held-back run happens: the codes catch up
	time.sleep(1600 * time.Millisecond)
	fs_model_tick()
	wait_git()
	testing.expect_value(t, fs_git_code_cached(a, false), " M")
	// changes under .git/objects or in an ignored folder do not make the status stale
	time.sleep(1600 * time.Millisecond)
	fs_model_tick()
	wait_git()
	runs := fs_stats.status_runs
	fs_model_changed(fmt.tprintf("%s/.git/objects/ab/cdef", dir), FSE_CREATED)
	fs_model_changed(fmt.tprintf("%s/node_modules/x.js", dir), FSE_MODIFIED)
	fs_git_code_cached(a, false)
	wait_git()
	testing.expect_value(t, fs_stats.status_runs, runs)
}

@(test)
files_burst_file_list_refreshes_off_the_main_thread :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := fsetup()
	fwrite(dir, "src/a.c", "")
	if !git_commit_all(dir) do return
	testing.expect(t, run_command(Set_Files_Filter{text = ".c"}, {kind = .UI}).ok)
	files_rows(dir)
	base := fs_stats.list_runs_sync
	// new files during a build: the list is kept, no git ls-files on the main thread
	for i in 0 ..< 20 {
		fwrite(dir, fmt.tprintf("src/f%d.c", i), "")
		fs_model_changed(fmt.tprintf("%s/src/f%d.c", dir, i), FSE_CREATED)
		files_rows(dir)
	}
	testing.expectf(t, fs_stats.list_runs_sync == base, "git ls-files ran %d times on the main thread", fs_stats.list_runs_sync - base)
	testing.expect(t, len(fs_project_files(dir)) > 0, "the old list stays meanwhile")
	// at most about once a second, on a worker: then the new files show
	time.sleep(1100 * time.Millisecond)
	async := fs_stats.list_runs_async
	fs_model_tick()
	for _ in 0 ..< 500 {
		inbox_drain()
		if !fs_list_loading(dir) do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, fs_stats.list_runs_async, async + 1)
	testing.expect(t, strings.contains(files_rows_text(files_rows(dir)), "src/f19.c"), files_rows_text(files_rows(dir)))
}

@(test)
files_new_names_are_checked :: proc(t: ^testing.T) {
	for bad in ([]string{"", " ", ".", "..", "a/b", "/x"}) do testing.expectf(t, files_name_error(bad) != "", "%q accepted", bad)
	for good in ([]string{"ok.txt", ".env", "a b", "x..y"}) do testing.expectf(t, files_name_error(good) == "", "%q refused", good)
}
