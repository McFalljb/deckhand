package core

// The Files tree's selection (several rows: click, ⌘, shift, arrows, ⌘A, Esc), type-to-select,
// and delete_path with paths: every path checked before any moves, nested paths moved once, the
// cap, one confirmation that names what goes, and a Trash that fails midway.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
sel_rows :: proc() -> []Files_Row {return SEL_ROWS[:]}

@(private = "file")
SEL_ROWS := [?]Files_Row{
	{path = "/p/a", name = "a", kind = .Dir, expanded = true},
	{path = "/p/a/b.txt", name = "b.txt", depth = 1, kind = .File},
	{path = "/p/a/x", name = "", depth = 1, error = "cannot list"},
	{path = "/p/a", name = "", depth = 1, more = 3},
	{path = "/p/Beta.md", name = "Beta.md", kind = .File},
	{path = "/p/c.txt", name = "c.txt", kind = .File},
	{path = "/p/d.txt", name = "d.txt", kind = .File},
}

@(private = "file")
sel_text :: proc(v: ^Files_View, rows: []Files_Row) -> string {
	return strings.join(files_sel_paths(v, rows), " ", context.temp_allocator)
}

@(test)
files_selection_click_shift_cmd :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	v: Files_View
	rows := sel_rows()
	// a plain click: that row alone
	files_sel_click(&v, rows, 1, false, false)
	testing.expect_value(t, sel_text(&v, rows), "/p/a/b.txt")
	testing.expect_value(t, v.cursor, "/p/a/b.txt")
	// ⌘-click adds; again takes it out (the cursor goes to it either way)
	files_sel_click(&v, rows, 5, false, true)
	testing.expect_value(t, sel_text(&v, rows), "/p/a/b.txt /p/c.txt")
	files_sel_click(&v, rows, 1, false, true)
	testing.expect_value(t, sel_text(&v, rows), "/p/c.txt")
	testing.expect_value(t, v.cursor, "/p/a/b.txt")
	// shift-click: from the anchor (the last ⌘-click: b.txt) to the row, past "N more…" and error rows
	files_sel_click(&v, rows, 6, true, false)
	testing.expect_value(t, sel_text(&v, rows), "/p/a/b.txt /p/Beta.md /p/c.txt /p/d.txt")
	testing.expect_value(t, v.cursor, "/p/d.txt")
	testing.expect_value(t, v.anchor, "/p/a/b.txt")
	// shift again, upwards: the range is redrawn from the same anchor
	files_sel_click(&v, rows, 0, true, false)
	testing.expect_value(t, sel_text(&v, rows), "/p/a /p/a/b.txt")
	// ⌘⇧: the range added to what was
	files_sel_click(&v, rows, 6, false, false)
	files_sel_click(&v, rows, 4, true, true)
	testing.expect_value(t, sel_text(&v, rows), "/p/Beta.md /p/c.txt /p/d.txt")
	files_sel_click(&v, rows, 0, false, true)
	files_sel_click(&v, rows, 1, true, true)
	testing.expect_value(t, sel_text(&v, rows), "/p/a /p/a/b.txt /p/Beta.md /p/c.txt /p/d.txt")
	// ⌘-click on the last selected row: never nothing (the cursor's row stays)
	files_sel_click(&v, rows, 5, false, false)
	files_sel_click(&v, rows, 5, false, true)
	testing.expect_value(t, sel_text(&v, rows), "/p/c.txt")
	// rows that are not a file or folder are never selected
	files_sel_click(&v, rows, 3, false, false)
	files_sel_click(&v, rows, 2, false, true)
	testing.expect_value(t, sel_text(&v, rows), "/p/c.txt")
	files_sel_set(&v, nil)
	delete(v.selected)
	delete(v.cursor)
	delete(v.anchor)
}

@(test)
files_selection_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	v: Files_View
	rows := sel_rows()
	// the cursor alone (files_select_in: a plain arrow, a reveal) is the selection
	files_select_in(&v, "/p/Beta.md")
	testing.expect_value(t, sel_text(&v, rows), "/p/Beta.md")
	testing.expect(t, !files_sel_collapse(&v), "Esc with one row: nothing to clear (it gives the keyboard back)")
	// shift-↓ twice extends from the anchor; shift-↑ shrinks
	files_sel_range(&v, rows, 5)
	files_sel_range(&v, rows, 6)
	testing.expect_value(t, sel_text(&v, rows), "/p/Beta.md /p/c.txt /p/d.txt")
	files_sel_range(&v, rows, 5)
	testing.expect_value(t, sel_text(&v, rows), "/p/Beta.md /p/c.txt")
	testing.expect_value(t, v.cursor, "/p/c.txt")
	// Esc: the cursor's row alone
	testing.expect(t, files_sel_collapse(&v), "Esc clears a multi-selection")
	testing.expect_value(t, sel_text(&v, rows), "/p/c.txt")
	// ⌘A: every file and folder that shows; the cursor stays
	files_sel_all(&v, rows)
	testing.expect_value(t, sel_text(&v, rows), "/p/a /p/a/b.txt /p/Beta.md /p/c.txt /p/d.txt")
	testing.expect_value(t, v.cursor, "/p/c.txt")
	testing.expect(t, files_sel_has(&v, "/p/d.txt") && !files_sel_has(&v, "/p/zzz"), "membership")
	// a plain move (files_select_in) ends it
	files_select_in(&v, "/p/a")
	testing.expect_value(t, sel_text(&v, rows), "/p/a")
	// an anchor that no longer shows: the range starts at the cursor
	delete(v.anchor)
	v.anchor = strings.clone("/p/gone")
	files_sel_range(&v, rows, 1)
	testing.expect_value(t, sel_text(&v, rows), "/p/a /p/a/b.txt")
	files_sel_set(&v, nil)
	delete(v.selected)
	delete(v.cursor)
	delete(v.anchor)
}

@(test)
files_type_to_select_match :: proc(t: ^testing.T) {
	rows := sel_rows()
	testing.expect_value(t, files_type_match(rows, 0, "b"), 1) // b.txt, from the top
	testing.expect_value(t, files_type_match(rows, 2, "b"), 4) // Beta.md: any case, past error and "more" rows
	testing.expect_value(t, files_type_match(rows, 5, "b"), 1) // round to the top
	testing.expect_value(t, files_type_match(rows, 0, "BE"), 4)
	testing.expect_value(t, files_type_match(rows, 0, "c.t"), 5)
	testing.expect_value(t, files_type_match(rows, 0, "q"), -1)
	testing.expect_value(t, files_type_match(rows, 0, ""), -1)
	testing.expect_value(t, files_type_match(nil, 0, "a"), -1)
	// the same letter again: the next row with it (no name starts "bb")
	testing.expect_value(t, files_type_match(rows, 1, "bb"), 4)
	testing.expect_value(t, files_type_match(rows, 4, "bbb"), 1)
}

// A clean State with one project in a fresh temp folder (real path) and a fake Trash (a rename to
// .trashed; one name may be made to fail).
@(private = "file")
bsetup :: proc(tag: string) -> string {
	state = State{}
	dir := fmt.tprintf("%s/dhx-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(dir)
	dir = fs_real(dir, context.allocator)
	append(&state.projects, Project{id = new_id(), cwd = dir, label = "proj"})
	batch_fail = ""
	fs_trash_fn = proc(path: string) -> bool {
		if batch_fail != "" && strings.has_suffix(path, batch_fail) do return false
		return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil
	}
	return dir
}

@(private = "file")
batch_fail: string

@(private = "file")
bwrite :: proc(dir, rel: string) {
	p := fmt.tprintf("%s/%s", dir, rel)
	os.make_directory_all(p[:strings.last_index_byte(p, '/')])
	_ = os.write_entire_file(p, transmute([]u8)string("x"))
}

@(test)
delete_batch_checks_every_path_first :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("batchcheck")
	defer {os.remove_all(dir); state = State{}}
	for f in ([]string{"a.txt", "b.txt", "src/x.txt", ".git/config"}) do bwrite(dir, f)
	UI :: Caller{kind = .UI}
	a, b := fmt.tprintf("%s/a.txt", dir), fmt.tprintf("%s/b.txt", dir)
	// one bad path anywhere: the whole batch refused, named, nothing moved (not even what came before it)
	for bad in ([]string{fmt.tprintf("%s/.git/config", dir), dir, "/etc/hosts", fmt.tprintf("%s/gone.txt", dir)}) {
		r := run_command(Delete_Path{paths = {a, bad, b}}, UI)
		testing.expectf(t, !r.ok && strings.has_prefix(r.error, bad) && strings.contains(r.error, "nothing was moved"), "%s: %q", bad, r.error)
		testing.expect(t, os.exists(a) && os.exists(b), "nothing moved")
		testing.expect_value(t, len(state.pending_confirmations), 0)
	}
	// a running terminal tab's folder
	s := Open_Session{id = new_id(), project_id = state.projects[0].id, cwd = strings.clone(dir)}
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "build shell", status = .Running, cwd = strings.clone(fmt.tprintf("%s/src", dir))})
	append(&state.open_sessions, s)
	r := run_command(Delete_Path{paths = {a, fmt.tprintf("%s/src", dir)}}, UI)
	testing.expectf(t, !r.ok && strings.contains(r.error, "build shell") && os.exists(a), "running tab: %q", r.error)
	// a credential place, for anyone but the user here (pi's agent folder)
	old, had := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer {if had do os.set_env("PI_CODING_AGENT_DIR", old); else do os.unset_env("PI_CODING_AGENT_DIR")}
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", dir))
	bwrite(dir, "agent/auth.json")
	state.settings.confirm[.Control][.Delete] = .Auto
	r = run_command(Delete_Path{paths = {a, fmt.tprintf("%s/agent/auth.json", dir)}}, Caller{kind = .Control})
	testing.expectf(t, !r.ok && strings.contains(r.error, CREDENTIAL_PLACE_REFUSED) && os.exists(a), "credential place: %q", r.error)
	// over the cap: refused before anything is looked at
	many := make([]string, FS_DELETE_MAX + 1, context.temp_allocator)
	for &p in many do p = a
	r = run_command(Delete_Path{paths = many}, UI)
	testing.expectf(t, !r.ok && strings.contains(r.error, "at most 500"), "cap: %q", r.error)
}

@(test)
delete_batch_nested_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("batchnest")
	defer {os.remove_all(dir); state = State{}}
	for f in ([]string{"a.txt", "src/x.txt", "src/deep/y.txt", "srcfile"}) do bwrite(dir, f)
	src := fmt.tprintf("%s/src", dir)
	plan, err := fs_delete_plan({fmt.tprintf("%s/src/deep/y.txt", dir), fmt.tprintf("%s/a.txt", dir), src, fmt.tprintf("%s/src/x.txt", dir), fmt.tprintf("%s/a.txt", dir), fmt.tprintf("%s/srcfile", dir)}, Caller{kind = .UI})
	testing.expect_value(t, err, "")
	testing.expect_value(t, strings.join(plan, " ", context.temp_allocator), fmt.tprintf("%s/a.txt %s %s/srcfile", dir, src, dir))
}

@(test)
delete_batch_one_confirmation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("batchconfirm")
	defer {os.remove_all(dir); state = State{}}
	for f in ([]string{"a.txt", "b.txt", "src/x.txt"}) do bwrite(dir, f)
	UI :: Caller{kind = .UI}
	paths := []string{fmt.tprintf("%s/a.txt", dir), fmt.tprintf("%s/b.txt", dir), fmt.tprintf("%s/src", dir), fmt.tprintf("%s/src/x.txt", dir)}
	r := run_command(Delete_Path{paths = paths}, UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expectf(t, strings.has_prefix(r.confirm_summary, "Move 3 items to the Trash (1 folder, 2 files)? src/, a.txt, b.txt (in "), "%q", r.confirm_summary)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	// asked again: the same one
	r = run_command(Delete_Path{paths = paths}, UI)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	testing.expect(t, os.exists(fmt.tprintf("%s/a.txt", dir)), "nothing moved before the answer")
	// the confirmation is for this batch only
	tok := r.confirm_token
	r2 := run_command(Delete_Path{paths = paths[:2], confirm = tok}, UI)
	testing.expect_value(t, r2.error, "unknown or expired confirmation token")
	r = run_command(Delete_Path{paths = paths, confirm = tok}, UI)
	testing.expectf(t, r.ok, "confirmed: %q", r.error)
	testing.expect_value(t, r.data, `{"trashed":3}`)
	for f in ([]string{"a.txt", "b.txt", "src"}) do testing.expectf(t, !os.exists(fmt.tprintf("%s/%s", dir, f)) && os.exists(fmt.tprintf("%s/%s.trashed", dir, f)), "%s trashed", f)
	// more than five: the first five in full, then how many more
	for i in 0 ..< 7 do bwrite(dir, fmt.tprintf("f%d.txt", i))
	seven := make([]string, 7, context.temp_allocator)
	for &p, i in seven do p = fmt.tprintf("%s/f%d.txt", dir, i)
	r = run_command(Delete_Path{paths = seven}, UI)
	testing.expectf(t, strings.has_prefix(r.confirm_summary, "Move 7 items to the Trash (7 files)? f0.txt, f1.txt, f2.txt, f3.txt, f4.txt, and 2 more (in "), "%q", r.confirm_summary)
	// the Trash fails midway: what went stays gone, the error says so and where it stopped
	batch_fail = "f3.txt"
	r = run_command(Delete_Path{paths = seven, confirm = r.confirm_token}, UI)
	testing.expect(t, !r.ok, "failed")
	testing.expect_value(t, r.error, fmt.tprintf("moved 3 of 7 to the Trash, then %s/f3.txt: could not move it to the Trash (the 3 moved stay in the Trash)", dir))
	testing.expect_value(t, r.data, fmt.tprintf(`{{"trashed":3,"failed":"%s/f3.txt"}}`, dir))
	testing.expect(t, !os.exists(seven[2]) && os.exists(seven[3]) && os.exists(seven[6]), "stopped at f3.txt")
	// one path left after nesting: as a single delete_path's confirmation
	batch_fail = ""
	r = run_command(Delete_Path{paths = {seven[4], seven[4]}}, UI)
	testing.expect_value(t, r.confirm_summary, fmt.tprintf("Move %s to the Trash?", seven[4]))
}

@(test)
delete_batch_wire :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	cmd, err := parse_command(`{"type":"delete_path","paths":["a.txt","/p/b"]}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	d, ok := cmd.(Delete_Path)
	testing.expect(t, ok && d.path == "" && len(d.paths) == 2 && d.paths[1] == "/p/b", "paths read, path optional")
	cmd, err = parse_command(`{"type":"delete_path","paths":"a.txt"}`, context.temp_allocator)
	testing.expect(t, err != "", "paths must be a list")
	// cloned for the inbox and a parked confirmation (another batch's token: delete_batch_one_confirmation)
	c := command_clone(Delete_Path{paths = {"/p/a", "/p/b"}}, context.allocator)
	cd := c.(Delete_Path)
	testing.expect(t, len(cd.paths) == 2 && cd.paths[0] == "/p/a" && raw_data(cd.paths[0]) != raw_data(string("/p/a")), "a copy")
	command_free(c, context.allocator)
}

// The batch's confirmation shows what matters whatever the caller sent: folders first, how many
// of each in the lead, every name on one line, cut to a budget, so the count, "and N more" and
// the project always fit the bar.
@(test)
delete_batch_summary_folders_first_and_bounded :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("batchsum")
	defer {os.remove_all(dir); state = State{}}
	UI :: Caller{kind = .UI}
	names := []string{"a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "src/k", "docs/k", ".github/k"}
	for f in names do bwrite(dir, f)
	paths := make([]string, 8, context.temp_allocator)
	for f, i in names do paths[i] = fmt.tprintf("%s/%s", dir, f[:strings.index_byte(f, '/') if strings.contains(f, "/") else len(f)])
	r := run_command(Delete_Path{paths = paths}, UI)
	// the project folder: cut from the front past FS_DELETE_ROOT_SHOWN (a long temp folder here)
	s0 := r.confirm_summary
	testing.expectf(t, strings.has_prefix(s0, "Move 8 items to the Trash (3 folders, 5 files)? src/, docs/, .github/, a.txt, b.txt, and 3 more (in "), "%q", s0)
	testing.expectf(t, strings.has_suffix(s0, fmt.tprintf("%s)", dir[len(dir) - 30:])), "the project's tail: %q", s0)
	// hostile names: the longest a name may be, a line break, a direction override, a name that
	// reads like the tail
	long := strings.concatenate({strings.repeat("x", 251, context.temp_allocator), ".txt"}, context.temp_allocator)
	odd := []string{long, "line\nbreak.txt", "abc‮txt.exe", "and 3 more"}
	op := make([dynamic]string, context.temp_allocator)
	for n in odd {
		p := fmt.tprintf("%s/%s", dir, n)
		_ = os.write_entire_file(p, transmute([]u8)string("x"))
		testing.expectf(t, os.exists(p), "made %q", n)
		append(&op, p)
	}
	append(&op, fmt.tprintf("%s/a.txt", dir), fmt.tprintf("%s/b.txt", dir), fmt.tprintf("%s/c.txt", dir))
	s := run_command(Delete_Path{paths = op[:]}, UI).confirm_summary
	testing.expectf(t, strings.has_prefix(s, "Move 7 items to the Trash (7 files)? "), "lead: %q", s)
	testing.expectf(t, strings.contains(s, ", and 2 more (in ") && strings.has_suffix(s, fmt.tprintf("%s)", dir[len(dir) - 30:])), "tail: %q", s)
	testing.expectf(t, !strings.contains(s, "\n") && !strings.contains(s, "‮"), "one line, no reordering: %q", s)
	testing.expectf(t, !strings.contains(s, long) && strings.contains(s, "xxxxxxxx…"), "a long name is cut: %q", s)
	testing.expectf(t, strings.contains(s, `"and 3 more"`), "a name that reads like the tail is quoted: %q", s)
	testing.expectf(t, len(s) <= FS_DELETE_SUMMARY_MAX, "bounded: %d bytes", len(s))
	// the longest a summary can be: 500 paths, long names, folders and files, a long project folder
	deep := fmt.tprintf("%s/%s", dir, strings.repeat("p", 200, context.temp_allocator))
	os.make_directory_all(deep)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(deep), label = "deep"})
	many := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< FS_DELETE_MAX {
		p := fmt.tprintf("%s/%03d %s", deep, i, strings.repeat("é", 60, context.temp_allocator))
		if i % 2 == 0 do os.make_directory_all(p)
		else do _ = os.write_entire_file(p, transmute([]u8)string("x"))
		append(&many, p)
	}
	s = run_command(Delete_Path{paths = many[:]}, UI).confirm_summary
	testing.expectf(t, strings.has_prefix(s, "Move 500 items to the Trash (250 folders, 250 files)? ") && strings.contains(s, ", and 495 more (in …"), "%q", s)
	testing.expectf(t, len(s) <= FS_DELETE_SUMMARY_MAX, "the longest: %d bytes", len(s))
}

// Each path is checked again right before it moves: a running tab that started in a later one
// (here: while the first moved) stops the batch there.
@(test)
delete_batch_rechecks_before_each_move :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("batchre")
	defer {os.remove_all(dir); state = State{}}
	bwrite(dir, "a.txt")
	bwrite(dir, "src/x.txt")
	batch_dir = dir
	fs_trash_fn = proc(path: string) -> bool {
		if strings.has_suffix(path, "/a.txt") {
			s := Open_Session{id = new_id(), project_id = state.projects[0].id, cwd = strings.clone(batch_dir)}
			append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "late shell", status = .Running, cwd = strings.clone(fmt.tprintf("%s/src", batch_dir))})
			append(&state.open_sessions, s)
		}
		return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil
	}
	UI :: Caller{kind = .UI}
	paths := []string{fmt.tprintf("%s/a.txt", dir), fmt.tprintf("%s/src", dir)}
	r := run_command(Delete_Path{paths = paths}, UI)
	r = run_command(Delete_Path{paths = paths, confirm = r.confirm_token}, UI)
	testing.expectf(t, !r.ok && strings.has_prefix(r.error, "moved 1 of 2 to the Trash, then ") && strings.contains(r.error, "late shell"), "%q", r.error)
	testing.expect(t, os.is_dir(fmt.tprintf("%s/src", dir)), "src stays")
}

@(private = "file")
batch_dir: string

// On a volume that ignores case, Src and src/x are one folder and what is in it; a.txt and A.TXT
// one file.
@(test)
delete_batch_merges_by_the_real_file :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("batchcase")
	defer {os.remove_all(dir); state = State{}}
	bwrite(dir, "src/x.txt")
	bwrite(dir, "a.txt")
	if !os.exists(fmt.tprintf("%s/SRC", dir)) do return // a volume that keeps case: nothing to merge
	plan, err := fs_delete_plan({fmt.tprintf("%s/Src", dir), fmt.tprintf("%s/src/x.txt", dir), fmt.tprintf("%s/a.txt", dir), fmt.tprintf("%s/A.TXT", dir)}, Caller{kind = .UI})
	testing.expect_value(t, err, "")
	testing.expect_value(t, len(plan), 2)
	testing.expect_value(t, len(fs_delete_merge({fmt.tprintf("%s/src", dir), fmt.tprintf("%s/SRC/x.txt", dir)})), 1)
}

// A project folder inside another project (a folder a session once ran in): the user at the
// window may rename, move, trash, restore and copy it like any folder, the outer project its root;
// every other caller is refused, as is a project folder inside no other project, for everyone.
@(test)
fs_check_nested_project_root_user_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	dir := bsetup("nestroot")
	defer {os.remove_all(dir); state = State{}}
	inner := fmt.tprintf("%s/inner", dir)
	bwrite(dir, "inner/x.txt")
	bwrite(dir, "dest/keep.txt")
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(inner), label = "inner"})
	UI :: Caller{kind = .UI}
	// everyone else: refused with the old message, nothing moves
	for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .Panel}, {kind = .Internal}, {kind = .UI, web = true}, {kind = .UI, hub = true}}) {
		_, _, e := fs_check(inner, c)
		testing.expectf(t, e == "not on a project folder itself", "%v fs_check: %q", c, e)
		testing.expectf(t, fs_delete(inner, c) == "not on a project folder itself", "%v delete", c)
		testing.expectf(t, fs_rename(inner, fmt.tprintf("%s/moved", dir), c) == "not on a project folder itself", "%v rename", c)
		r := run_command(Rename_Path{from = inner, to = fmt.tprintf("%s/moved", dir)}, c)
		panel := c.kind == .Panel // an unbound panel is refused before any path
		testing.expectf(t, !r.ok && (panel || r.error == "not on a project folder itself"), "%v rename_path: %q", c, r.error)
		r = run_command(Delete_Path{paths = {fmt.tprintf("%s/inner/x.txt", dir), inner}}, c)
		testing.expectf(t, !r.ok && (panel || strings.contains(r.error, "not on a project folder itself")), "%v delete_path: %q", c, r.error)
		testing.expect(t, os.is_dir(inner), "still there")
	}
	// another spelling of it (a volume that ignores case, macOS's default) is the same folder:
	// still refused, nothing moves
	other := fmt.tprintf("%s/INNER", dir)
	if os.exists(other) {
		for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .UI, web = true}}) {
			_, _, e := fs_check(other, c)
			testing.expectf(t, e == "not on a project folder itself", "%v fs_check INNER: %q", c, e)
			r := run_command(Rename_Path{from = other, to = fmt.tprintf("%s/moved", dir)}, c)
			testing.expectf(t, !r.ok && r.error == "not on a project folder itself", "%v rename_path INNER: %q", c, r.error)
			r = run_command(Delete_Path{path = other}, c)
			testing.expectf(t, !r.ok && r.error == "not on a project folder itself", "%v delete_path INNER: %q", c, r.error)
			testing.expect(t, os.is_dir(inner), "still there")
		}
		_, _, eu := fs_check(other, UI)
		testing.expect_value(t, eu, "") // the user here: as by its own spelling
		_, _, eg := fs_check(fmt.tprintf("%s/.GIT", dir), Caller{kind = .Control})
		testing.expect_value(t, eg, "not inside .git")
		// the user here changes only the case of its name, and back
		testing.expect_value(t, fs_rename(inner, other, UI), "")
		testing.expect_value(t, fs_rename(other, inner, UI), "")
		testing.expect(t, os.is_dir(inner), "back")
	}
	// a link to it is the link, not the project: renamed or trashed as before, by anyone
	lnk := fmt.tprintf("%s/lnk", dir)
	testing.expect(t, os.symlink(inner, lnk) == nil, "link made")
	for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .UI, web = true}, UI}) {
		_, _, e := fs_check(lnk, c)
		testing.expectf(t, e == "", "%v fs_check link: %q", c, e)
	}
	os.remove(lnk)
	// a project folder inside no other project: refused for the user too
	_, _, e0 := fs_check(dir, UI)
	testing.expect_value(t, e0, "not on a project folder itself")
	testing.expect_value(t, fs_rename(dir, fmt.tprintf("%s-moved", dir), UI), "not on a project folder itself")
	testing.expect_value(t, fs_delete(dir, UI), "not on a project folder itself")
	// the user here: the outer project is its root
	p, root, e := fs_check(inner, UI)
	testing.expect_value(t, e, "")
	testing.expect_value(t, p, inner)
	testing.expect_value(t, root, dir)
	// copied (duplicated)
	_, _, ce := fs_copy_paths(inner, fmt.tprintf("%s/inner copy", dir), UI)
	testing.expect_value(t, ce, "")
	// moved into another folder, and back; folders open inside it stay open, as a plain folder's
	moved := fmt.tprintf("%s/dest/inner", dir)
	os.make_directory_all(fmt.tprintf("%s/sub", inner))
	testing.expect(t, run_command(Files_Expand{path = inner, expanded = true}, UI).ok, "open inner")
	testing.expect(t, run_command(Files_Expand{path = fmt.tprintf("%s/sub", inner), expanded = true}, UI).ok, "open sub")
	testing.expect_value(t, fs_rename(inner, moved, UI), "")
	testing.expect(t, !os.exists(inner) && os.exists(fmt.tprintf("%s/x.txt", moved)), "moved")
	testing.expect(t, files_is_open(moved), "the moved folder stays open")
	testing.expect(t, files_is_open(fmt.tprintf("%s/sub", moved)), "its open folder stays open")
	testing.expect_value(t, fs_rename(moved, inner, UI), "")
	testing.expect(t, os.exists(fmt.tprintf("%s/x.txt", inner)), "moved back")
	// trashed, with a restore id, and restored
	trash := fmt.tprintf("%s/dest/trash", dir)
	os.make_directory_all(trash)
	nested_trash_dir = trash
	fs_trash_fn = proc(path: string) -> bool {
		to := fmt.tprintf("%s/%d-inner", nested_trash_dir, time.now()._nsec)
		if os.rename(path, to) != nil do return false
		fs_trash_where = to
		return true
	}
	plan, perr := fs_delete_plan({inner}, UI)
	testing.expect_value(t, perr, "")
	testing.expect_value(t, len(plan), 1)
	derr, id := fs_trash_checked(plan[0])
	testing.expect_value(t, derr, "")
	testing.expect(t, id != "" && !os.exists(inner), "trashed, with a restore id")
	_, rerr := fs_restore(id, UI)
	testing.expect_value(t, rerr, "")
	testing.expect(t, os.exists(fmt.tprintf("%s/x.txt", inner)), "restored")
	// a running terminal in it still refuses (fs_in_use_by)
	s := Open_Session{id = new_id(), project_id = state.projects[1].id, cwd = strings.clone(inner)}
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "sh", status = .Running})
	append(&state.open_sessions, s)
	e1 := fs_rename(inner, moved, UI)
	testing.expectf(t, strings.contains(e1, "is running in it"), "%q", e1)
	testing.expect(t, os.is_dir(inner), "still there")
	// what is inside it is fine
	testing.expect_value(t, fs_delete(fmt.tprintf("%s/inner/x.txt", dir), UI), "")
}

@(private = "file")
nested_trash_dir: string
