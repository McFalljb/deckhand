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
	testing.expect_value(t, r.confirm_summary, fmt.tprintf("Move 3 items to the Trash? a.txt, b.txt, src/ (in %s)", dir))
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
	testing.expect_value(t, r.confirm_summary, fmt.tprintf("Move 7 items to the Trash? f0.txt, f1.txt, f2.txt, f3.txt, f4.txt, and 2 more (in %s)", dir))
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
