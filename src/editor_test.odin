package main

// Editor tabs and the file-system model through the command layer: open
// (dedupe, refusals), editing and undo, line endings, atomic saves, files
// changing on disk, find/replace, the git gutter, and the file commands
// (delete to the Trash confirms). No processes: the session is made by hand.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
trashed: [dynamic]string

// A clean State with one open session (its pi tab not running) in a fresh
// temp folder that is also a project. Returns that folder.
@(private = "file")
setup :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/pi-desk-editor-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir := fs_real(made, context.allocator)
	// these tests write files and run git in dir: never anywhere else
	cwd, _ := os.get_working_directory(context.temp_allocator)
	ensure(strings.has_prefix(dir, "/") && strings.contains(dir, "/pi-desk-editor-test-") && os.is_directory(dir) && dir != fs_real(cwd), "editor tests: no temp folder")
	append(&state.projects, Project{id = new_id(), cwd = dir, label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("s-1"), project_id = state.projects[0].id, cwd = dir}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	clear(&trashed)
	fs_trash_fn = proc(path: string) -> bool {
		append(&trashed, strings.clone(path, runtime.heap_allocator()))
		to := fmt.tprintf("%s.trashed", path)
		return os.rename(path, to) == nil
	}
	return dir
}

@(private = "file")
write :: proc(dir, name, text: string) -> string {
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	os.make_directory_all(filepath.dir(p))
	_ = os.write_entire_file(p, transmute([]u8)text)
	return p
}

@(private = "file")
read :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

@(private = "file")
open :: proc(t: ^testing.T, path: string, loc := #caller_location) -> ^Editor {
	r := run_command(Open_File{path = path}, {kind = .Script})
	testing.expectf(t, r.ok, "open %s: %s", path, r.error, loc = loc)
	return editor_of(r.created_id)
}

@(private = "file")
text_of :: proc(e: ^Editor) -> string {return tb_text(&e.buf, context.temp_allocator)}

@(test)
editor_open_dedupe_and_refusals :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	p := write(dir, "src/a.ts", "const a = 1;\n")
	r1 := run_command(Open_File{path = "src/a.ts", line = 1, col = 7}, {kind = .Script}) // relative to the session's folder
	testing.expect(t, r1.ok, r1.error)
	r2 := run_command(Open_File{path = p}, {kind = .Script})
	testing.expect_value(t, r2.created_id, r1.created_id) // the same tab, focused
	testing.expect_value(t, len(cur().tabs), 2)
	testing.expect_value(t, cur().active_tab, r1.created_id)
	_, tab, _ := find_tab(r1.created_id)
	testing.expect_value(t, tab.title, "a.ts")
	e := editor_of(r1.created_id)
	l, c := ed_line_col(e, e.cursor)
	testing.expect_value(t, l, 1)
	testing.expect_value(t, c, 7)
	testing.expect_value(t, e.sx.lang.name, "typescript")
	// state JSON shows the tab as an editor with its path and dirty flag
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.1.kind"), "editor")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.1.dirty"), "false")
	// refusals: missing, folder, binary
	testing.expect_value(t, run_command(Open_File{path = "nope.txt"}, {kind = .Script}).error, "no such file")
	testing.expect_value(t, run_command(Open_File{path = "src"}, {kind = .Script}).error, "that is a folder")
	bin := write(dir, "b.bin", "\x7fELF\x00\x01\x02")
	rb := run_command(Open_File{path = bin}, {kind = .Script})
	testing.expect(t, rb.ok)
	testing.expect_value(t, json_path(rb.data, "refused"), "Binary file: not shown")
	// a panel caller (a pi tab) may not open files
	testing.expect(t, !run_command(Open_File{path = p}, {kind = .Panel, tab_id = cur().tabs[0].id}).ok)
}

@(test)
editor_undo_groups_typing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	e := open(t, write(dir, "u.txt", "x\n"))
	ed_set_cursor(e, 1, false)
	for ch in "hello" do ed_insert(e, fmt.tprint(ch))
	ed_insert(e, " ")
	ed_insert(e, "w")
	testing.expect_value(t, text_of(e), "xhello w\n")
	testing.expect_value(t, len(e.undo), 1) // one typing burst
	testing.expect(t, editor_dirty(e))
	ed_backspace(e)
	ed_backspace(e)
	testing.expect_value(t, len(e.undo), 2) // deleting is its own step
	ed_newline(e)
	testing.expect_value(t, len(e.undo), 3)
	ed_undo(e)
	ed_undo(e)
	testing.expect_value(t, text_of(e), "xhello w\n")
	ed_undo(e)
	testing.expect_value(t, text_of(e), "x\n")
	testing.expect(t, !editor_dirty(e)) // back to what is on disk
	testing.expect_value(t, e.cursor, 1)
	ed_redo(e)
	testing.expect_value(t, text_of(e), "xhello w\n")
	// a cursor move ends the burst
	ed_insert(e, "1")
	ed_move_char(e, -1, false)
	ed_insert(e, "2")
	testing.expect_value(t, len(e.undo), 3)
	// save, then undo makes it dirty again; typing after a save is a new step
	testing.expect_value(t, editor_save(e), "")
	testing.expect(t, !editor_dirty(e))
	ed_insert(e, "3")
	testing.expect(t, editor_dirty(e))
	ed_undo(e)
	testing.expect(t, !editor_dirty(e))
}

@(test)
editor_edit_commands :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	e := open(t, write(dir, "a.c", "int f() {\n    return 1;\n}\n"))
	testing.expect(t, !e.indent_tabs)
	testing.expect_value(t, e.indent_w, 4)
	// Enter after "{" between braces: indented line, closer on its own line
	e2 := open(t, write(dir, "b.c", "void g() {}\n"))
	ed_set_cursor(e2, len("void g() {"), false)
	ed_newline(e2)
	testing.expect_value(t, text_of(e2), "void g() {\n    \n}\n")
	testing.expect_value(t, e2.cursor, len("void g() {\n    "))
	// toggle comment on two lines and back
	ed_set_cursor(e, 0, false)
	ed_set_cursor(e, tb_line_start(&e.buf, 1) + 2, true)
	ed_toggle_comment(e)
	testing.expect_value(t, text_of(e), "// int f() {\n//     return 1;\n}\n") // at the block's indentation
	ed_toggle_comment(e)
	testing.expect_value(t, text_of(e), "int f() {\n    return 1;\n}\n")
	// indent / outdent the selected lines
	ed_indent_lines(e, false)
	testing.expect_value(t, text_of(e), "    int f() {\n        return 1;\n}\n")
	ed_indent_lines(e, true)
	testing.expect_value(t, text_of(e), "int f() {\n    return 1;\n}\n")
	// soft-tab backspace removes one indent level
	ed_set_cursor(e, tb_line_start(&e.buf, 1) + 4, false)
	ed_backspace(e)
	testing.expect_value(t, tb_line(&e.buf, 1, &e.scratch), "return 1;")
	// word moves and UTF-8 steps
	e3 := open(t, write(dir, "u.md", "héllo wörld\n"))
	ed_move_word(e3, 1, false)
	testing.expect_value(t, e3.cursor, len("héllo"))
	ed_move_char(e3, -1, false)
	testing.expect_value(t, e3.cursor, len("héll"))
	ed_set_cursor(e3, 1, false)
	ed_move_char(e3, 1, false)
	testing.expect_value(t, e3.cursor, 3) // é is two bytes
	// double-click selects the word, triple the line
	ed_click(e3, 8, 2, false)
	testing.expect_value(t, ed_selected_text(e3), "wörld")
	ed_click(e3, 8, 3, false)
	testing.expect_value(t, ed_selected_text(e3), "héllo wörld\n")
}

@(test)
editor_crlf_and_trailing_newline :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	p := write(dir, "w.txt", "one\r\ntwo\r\n")
	e := open(t, p)
	testing.expect_value(t, e.eol, "\r\n")
	testing.expect_value(t, tb_line_count(&e.buf), 3)
	testing.expect_value(t, tb_line(&e.buf, 0, &e.scratch), "one")
	ed_set_cursor(e, tb_line_end(&e.buf, 0), false)
	ed_newline(e)
	ed_insert(e, "x")
	ed_insert(e, "a\nb", .Other) // pasted LF becomes CRLF
	testing.expect_value(t, editor_save(e), "")
	testing.expect_value(t, read(p), "one\r\nxa\r\nb\r\ntwo\r\n")
	// arrows step over \r\n as one
	ed_set_cursor(e, tb_line_end(&e.buf, 0), false)
	ed_move_char(e, 1, false)
	testing.expect_value(t, e.cursor, tb_line_start(&e.buf, 1))
	// no trailing newline stays that way
	q := write(dir, "n.txt", "a\nb")
	f := open(t, q)
	ed_set_cursor(f, 0, false)
	ed_insert(f, "z")
	testing.expect_value(t, editor_save(f), "")
	testing.expect_value(t, read(q), "za\nb")
}

@(test)
editor_save_is_atomic :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	p := write(dir, "run.sh", "#!/bin/sh\necho hi\n")
	os.change_mode(p, os.perm_number(0o751))
	link := fmt.tprintf("%s/link.sh", dir)
	os.symlink(p, link)
	before, _ := os.stat(p, context.temp_allocator)
	e := open(t, link)
	ed_set_cursor(e, tb_len(&e.buf), false)
	ed_insert(e, "echo more\n")
	r := run_command(Save_File{e.tab_id}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	after, _ := os.stat(p, context.temp_allocator)
	testing.expect_value(t, read(p), "#!/bin/sh\necho hi\necho more\n")
	testing.expect_value(t, after.mode & os.perm_number(0o777), os.perm_number(0o751)) // permissions kept
	testing.expect(t, after.inode != before.inode, "written to a new file and renamed over")
	lfi, _ := os.lstat(link, context.temp_allocator)
	testing.expect_value(t, lfi.type, os.File_Type.Symlink) // the link stays a link
	// no temporary files left next to it
	infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for fi in infos do testing.expectf(t, !strings.contains(fi.name, ".pi-desk-"), "left %s", fi.name)
	testing.expect(t, !e.disk_changed)
	// our own save is not a change on disk
	editor_check_disk(e)
	testing.expect(t, !e.disk_changed && !editor_dirty(e))
}

@(test)
editor_follows_disk :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	p := write(dir, "f.txt", "a\nb\nc\nd\n")
	e := open(t, p)
	ed_set_cursor(e, tb_line_start(&e.buf, 3), false) // on "d"
	// clean: an agent edits the file -> silent reload, cursor stays on "d"
	time.sleep(10 * time.Millisecond)
	write(dir, "f.txt", "a\nNEW\nb\nc\nd\n")
	editor_check_disk(e)
	testing.expect_value(t, text_of(e), "a\nNEW\nb\nc\nd\n")
	testing.expect(t, !editor_dirty(e) && !e.disk_changed)
	testing.expect_value(t, tb_byte(&e.buf, e.cursor), u8('d'))
	ed_undo(e) // the reload is one undo step
	testing.expect_value(t, text_of(e), "a\nb\nc\nd\n")
	ed_redo(e)
	// dirty: the buffer is never touched; the banner shows
	ed_set_cursor(e, 0, false)
	ed_insert(e, "mine ")
	time.sleep(10 * time.Millisecond)
	write(dir, "f.txt", "theirs\n")
	editor_check_disk(e)
	testing.expect(t, e.disk_changed)
	testing.expect_value(t, text_of(e), "mine a\nNEW\nb\nc\nd\n")
	testing.expect_value(t, json_path(editor_state_json(e), "disk"), "changed")
	// saving is refused until resolved
	testing.expect(t, !run_command(Save_File{e.tab_id}, {kind = .Script}).ok)
	// compare: a read-only diff tab
	rd := run_command(Diff_File{e.tab_id, .Diff_Disk}, {kind = .Script})
	testing.expect(t, rd.ok, rd.error)
	d := editor_of(rd.created_id)
	testing.expect(t, d.readonly && strings.contains(text_of(d), "-theirs") && strings.contains(text_of(d), "+mine a"))
	// reload from a script asks first (unsaved changes); the user's banner button does not
	rr := run_command(Reload_File{tab_id = e.tab_id}, {kind = .Script})
	testing.expect_value(t, rr.error, "needs_confirmation")
	testing.expect(t, run_command(Reload_File{tab_id = e.tab_id}, {kind = .UI}).ok)
	testing.expect_value(t, text_of(e), "theirs\n")
	testing.expect(t, !editor_dirty(e) && !e.disk_changed)
	// keep mine: the buffer stays and saving overwrites
	ed_insert(e, "x")
	time.sleep(10 * time.Millisecond)
	write(dir, "f.txt", "again\n")
	editor_check_disk(e)
	testing.expect(t, e.disk_changed)
	testing.expect(t, run_command(Keep_Buffer{e.tab_id}, {kind = .Script}).ok)
	testing.expect(t, run_command(Save_File{e.tab_id}, {kind = .Script}).ok)
	testing.expect_value(t, read(p), text_of(e))
	// deleted on disk: kept, marked missing; saving writes it again
	os.remove(p)
	editor_check_disk(e)
	testing.expect(t, e.missing)
	testing.expect_value(t, json_path(editor_state_json(e), "disk"), "missing")
	testing.expect(t, run_command(Save_File{e.tab_id}, {kind = .Script}).ok)
	testing.expect(t, os.exists(p) && !e.missing)
}

@(test)
editor_close_dirty_asks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	e := open(t, write(dir, "c.txt", "x"))
	clean := run_command(Close_Tab{tab_id = e.tab_id}, {kind = .Script})
	testing.expect(t, clean.ok) // nothing unsaved: closes at once
	testing.expect(t, editor_of(clean.created_id) == nil)
	e = open(t, write(dir, "c.txt", "x"))
	id := e.tab_id
	ed_insert(e, "y")
	r := run_command(Close_Tab{tab_id = id}, {kind = .UI})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, strings.contains(r.confirm_summary, "unsaved changes"), r.confirm_summary)
	testing.expect(t, run_command(Close_Tab{tab_id = id, confirm = r.confirm_token}, {kind = .UI}).ok)
	testing.expect(t, editor_of(id) == nil)
	testing.expect_value(t, read(fmt.tprintf("%s/c.txt", dir)), "x")
}

@(test)
editor_find_replace :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	e := open(t, write(dir, "f.txt", "foo bar Foo\nfoo"))
	tf_set(&e.find.query, "foo")
	e.bar = .Find
	find_update(e)
	testing.expect_value(t, len(e.find.matches), 3) // case-insensitive by default
	e.find.case_sensitive = true
	find_update(e)
	testing.expect_value(t, len(e.find.matches), 2)
	find_step(e, 1)
	testing.expect_value(t, ed_selected_text(e), "foo")
	tf_set(&e.find.replace, "qux")
	n := replace_all(e)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, text_of(e), "qux bar Foo\nqux")
	ed_undo(e) // one step
	testing.expect_value(t, text_of(e), "foo bar Foo\nfoo")
	e.find.regex = true
	e.find.case_sensitive = false
	tf_set(&e.find.query, "f.o")
	find_update(e)
	testing.expect_value(t, len(e.find.matches), 3)
	tf_set(&e.find.query, "(")
	find_update(e)
	testing.expect(t, e.find.error != "")
}

@(test)
editor_git_gutter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	if _, ok := git_run(dir, "init", "-q"); !ok do return // no git here
	p := write(dir, "g.txt", "one\ntwo\nthree\nfour\n")
	git_run(dir, "add", "g.txt")
	git_run(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "x")
	write(dir, ".gitignore", "ignored/\n")
	write(dir, "ignored/x.txt", "x")
	write(dir, "new.txt", "n")
	e := open(t, p)
	ed_replace(e, 0, 3, "ONE") // modified
	ed_replace(e, tb_line_start(&e.buf, 2), tb_line_start(&e.buf, 3), "") // "three" removed
	ed_set_cursor(e, tb_line_end(&e.buf, 2), false)
	ed_insert(e, "\nfive", .Other) // added
	settle(proc() -> bool {return !any_git_loading()}) // HEAD arrives from a worker
	git_gutter_update(e, force = true)
	testing.expect(t, e.git.tracked)
	testing.expect_value(t, e.git.marks[0], Git_Mark.Modified)
	testing.expect_value(t, e.git.marks[3], Git_Mark.Added)
	testing.expect(t, e.git.removed[2])
	testing.expect_value(t, e.git.counts, [3]int{1, 1, 1})
	// list_dir: .git and ignored hidden, git codes per entry
	run_command(List_Dir{path = "."}, {kind = .Script}) // starts git status on a worker
	settle(proc() -> bool {return !any_git_loading()})
	r := run_command(List_Dir{path = "."}, {kind = .Script})
	testing.expect(t, !strings.contains(r.data, "git_pending"), r.data)
	testing.expect(t, r.ok, r.error)
	names := make(map[string]string, context.temp_allocator)
	for i in 0 ..< 10 {
		n := json_path(r.data, fmt.tprintf("entries.%d.name", i))
		if n == "<missing>" do break
		names[n] = json_path(r.data, fmt.tprintf("entries.%d.git", i))
	}
	testing.expect(t, !(".git" in names) && !("ignored" in names), r.data)
	testing.expect_value(t, names["new.txt"], "??")
	testing.expect_value(t, names["g.txt"], "<missing>") // committed, saved file unchanged
	// the diff view against HEAD
	rd := run_command(Diff_File{e.tab_id, .Diff_Head}, {kind = .Script})
	testing.expect(t, rd.ok && strings.contains(text_of(editor_of(rd.created_id)), "+ONE"))
	// ⌘P's list: git's view of the project
	files := fs_project_files(dir)
	testing.expect(t, len(files) == 3, fmt.tprint(files)) // .gitignore, g.txt, new.txt
}

@(test)
fs_commands_inside_projects :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State outlives a test
	dir := setup()
	r := run_command(Create_File{path = "sub/new.txt"}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, os.exists(fmt.tprintf("%s/sub/new.txt", dir)))
	testing.expect_value(t, run_command(Create_File{path = "sub/new.txt"}, {kind = .Script}).error, "already exists")
	testing.expect(t, run_command(Create_Dir{path = "d1/d2"}, {kind = .Script}).ok)
	// outside every project, the project root itself, .git: refused
	testing.expect_value(t, run_command(Create_File{path = "/tmp/pi-desk-outside.txt"}, {kind = .Script}).error, "only inside a project folder")
	testing.expect_value(t, run_command(Delete_Path{path = dir}, {kind = .UI}).error, "not on a project folder itself")
	testing.expect_value(t, run_command(Create_File{path = ".git/x"}, {kind = .Script}).error, "not inside .git")
	testing.expect_value(t, run_command(Create_File{path = "../escape.txt"}, {kind = .Script}).error, "only inside a project folder")
	// rename: open tabs follow
	e := open(t, fmt.tprintf("%s/sub/new.txt", dir))
	testing.expect(t, run_command(Rename_Path{from = "sub", to = "moved"}, {kind = .Script}).ok)
	_, tab, _ := find_tab(e.tab_id)
	testing.expect_value(t, tab.kind.(Editor_Tab).path, fmt.tprintf("%s/moved/new.txt", dir))
	testing.expect_value(t, e.path, fmt.tprintf("%s/moved/new.txt", dir))
	// delete: always confirmed (class delete); a script cannot confirm it itself
	rs := run_command(Delete_Path{path = "moved/new.txt"}, {kind = .Script})
	testing.expect_value(t, rs.error, "needs_confirmation")
	testing.expect(t, rs.confirm_by_user)
	testing.expect(t, os.exists(fmt.tprintf("%s/moved/new.txt", dir)))
	testing.expect_value(t, len(state.pending_confirmations), 1)
	testing.expect_value(t, state.pending_confirmations[0].class, Command_Class.Delete)
	// the user confirms in the UI -> moved to the Trash
	tok := state.pending_confirmations[0].token
	testing.expect(t, run_command(Delete_Path{path = "moved/new.txt", confirm = tok}, {kind = .UI}).ok)
	testing.expect_value(t, len(trashed), 1)
	testing.expect(t, !os.exists(fmt.tprintf("%s/moved/new.txt", dir)))
	editor_check_disk(e)
	testing.expect(t, e.missing)
	// reveal in Finder: remembered, never opened from tests
	testing.expect(t, run_command(Reveal_In_Finder{path = "d1"}, {kind = .Script}).ok)
	testing.expect_value(t, fs_model.revealed, fmt.tprintf("%s/d1", dir))
	// editor_state over the wire
	st := run_command(Editor_State{e.tab_id}, {kind = .Control})
	testing.expect_value(t, json_path(st.data, "cursor.line"), "1")
	testing.expect_value(t, json_path(st.data, "language"), "plain")
}

@(test)
editor_line_diff :: proc(t: ^testing.T) {
	a := line_hashes_of_string("a\nb\nc\nd\ne\n")
	b := line_hashes_of_string("a\nB\nc\ne\nf\n")
	h := line_diff(a, b)
	testing.expect_value(t, len(h), 3)
	testing.expect_value(t, h[0], Diff_Hunk{1, 2, 1, 2}) // b -> B
	testing.expect_value(t, h[1], Diff_Hunk{3, 4, 3, 3}) // d removed
	testing.expect_value(t, h[2], Diff_Hunk{5, 5, 4, 5}) // f added
	u := unified_diff("a\nb\n", "a\nc\n", "x", "y")
	testing.expect(t, strings.contains(u, "-b\n+c\n"), u)
}

@(test)
editor_buttons_and_menu :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	e := open(t, write(dir, "m.c", "int x;\n"))
	labels :: proc(id: u64) -> string {
		items := make([dynamic]Menu_Item, context.temp_allocator)
		editor_menu_items(id, &items)
		b := strings.builder_make(context.temp_allocator)
		for it in items do if !it.sep do fmt.sbprintf(&b, "%s|", it.label)
		return strings.to_string(b)
	}
	l := labels(e.tab_id)
	for want in ([]string{"Cut|", "Copy|", "Paste|", "Select all|", "Toggle comment|", "Go to line…|", "Reveal in Finder|"}) do testing.expectf(t, strings.contains(l, want), "menu lacks %s: %s", want, l)
	editor_run_action(e.tab_id, .Select_All)
	editor_run_action(e.tab_id, .Toggle_Comment)
	testing.expect_value(t, text_of(e), "// int x;\n")
	editor_run_action(e.tab_id, .Undo)
	testing.expect_value(t, text_of(e), "int x;\n")
	editor_run_action(e.tab_id, .Redo)
	testing.expect_value(t, text_of(e), "// int x;\n")
	editor_run_action(e.tab_id, .Goto)
	testing.expect_value(t, e.bar, Editor_Bar.Goto)
	// a read-only diff view offers no edits
	time.sleep(10 * time.Millisecond)
	write(dir, "m.c", "long x;\n")
	editor_check_disk(e)
	rd := run_command(Diff_File{e.tab_id, .Diff_Disk}, {kind = .Script})
	ld := labels(rd.created_id)
	testing.expect(t, !strings.contains(ld, "Cut|") && !strings.contains(ld, "Paste|") && strings.contains(ld, "Copy|"), ld)
}

// Drains the inbox until done() (workers report through it), at most 5 s.
@(private = "file")
settle :: proc(done: proc() -> bool) {
	for _ in 0 ..< 500 {
		inbox_drain()
		if done() do return
		time.sleep(10 * time.Millisecond)
	}
}

@(private = "file")
any_git_loading :: proc() -> bool {
	for _, e in editors do if e.git.loading do return true
	for s in fs_model.status do if s.loading do return true
	return false
}

// ---- review round 1 ----

// A second project with an open session (not current); returns its folder and session.
@(private = "file")
second_session :: proc() -> (dir: string, s: ^Open_Session) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/pi-desk-editor-test-b-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir = fs_real(made, context.allocator)
	append(&state.projects, Project{id = new_id(), cwd = dir, label = "projb"})
	ns := Open_Session{id = new_id(), pi_session_id = strings.clone("s-2"), project_id = state.projects[len(state.projects) - 1].id, cwd = dir}
	append(&ns.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	ns.active_tab = ns.tabs[0].id
	append(&state.open_sessions, ns)
	return dir, &state.open_sessions[len(state.open_sessions) - 1]
}

@(test)
review_delete_parks_the_resolved_path :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a := setup()
	b, sb := second_session()
	write(a, "x.txt", "a")
	write(b, "x.txt", "b")
	r := run_command(Delete_Path{path = "x.txt"}, {kind = .Script}) // relative to session A (current)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, strings.contains(r.confirm_summary, fmt.tprintf("%s/x.txt", a)), r.confirm_summary)
	// the user switches to session B, then confirms the bar
	state.current_session = sb.id
	p := state.pending_confirmations[0]
	parked := p.command.(Delete_Path)
	testing.expect_value(t, parked.path, fmt.tprintf("%s/x.txt", a))
	testing.expect(t, run_command(Delete_Path{path = parked.path, confirm = p.token}, {kind = .UI}).ok)
	testing.expect(t, !os.exists(fmt.tprintf("%s/x.txt", a)), "A's file trashed")
	testing.expect(t, os.exists(fmt.tprintf("%s/x.txt", b)), "B's file kept")
}

@(test)
review_paths_resolve_against_the_callers_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a := setup()
	sa := cur()
	atab := sa.tabs[0].id
	b, sb := second_session()
	write(a, "f.txt", "in a")
	write(b, "f.txt", "in b")
	state.current_session = sb.id // the user looks at B
	ctl := Caller{kind = .Control, tab_id = atab} // bound to session A's pi tab
	r := run_command(Open_File{path = "f.txt"}, ctl)
	testing.expect(t, r.ok, r.error)
	e := editor_of(r.created_id)
	testing.expect(t, e != nil && e.path == fmt.tprintf("%s/f.txt", a), e != nil ? e.path : "nil")
	s, _, _ := find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == sa.id, "opened in the caller's own session")
	// inside its own project: no confirmation
	testing.expect(t, run_command(Create_File{path = "new.txt"}, ctl).ok)
	testing.expect(t, os.exists(fmt.tprintf("%s/new.txt", a)))
	// another known project: confirmation (class fs_write), the absolute path parked
	rc := run_command(Create_File{path = fmt.tprintf("%s/other.txt", b)}, ctl)
	testing.expect_value(t, rc.error, "needs_confirmation")
	testing.expect(t, !os.exists(fmt.tprintf("%s/other.txt", b)))
	testing.expect_value(t, state.pending_confirmations[len(state.pending_confirmations) - 1].class, Command_Class.Fs_Write)
	rr := run_command(Rename_Path{from = fmt.tprintf("%s/f.txt", b), to = fmt.tprintf("%s/g.txt", b)}, ctl)
	testing.expect_value(t, rr.error, "needs_confirmation")
	// a pi tab's bridge (panel caller) stays inside its own session's project
	pan := Caller{kind = .Panel, tab_id = atab}
	pr, _ := editor_apply(Create_File{path = fmt.tprintf("%s/p.txt", b)}, pan)
	testing.expect(t, !pr.ok && !os.exists(fmt.tprintf("%s/p.txt", b)), pr.error)
	// the user and scripts: the session on screen (opening the file showed A; back to B)
	state.current_session = sb.id
	testing.expect(t, run_command(Create_File{path = "user.txt"}, {kind = .Script}).ok)
	testing.expect(t, os.exists(fmt.tprintf("%s/user.txt", b)))
}

@(test)
review_reload_into_binary_refuses :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	p := write(dir, "r.txt", "text\n")
	e := open(t, p)
	// replaced by a binary file; nothing noticed it yet; the user reloads
	write(dir, "r.txt", "\x7fELF\x00\x00\x01")
	testing.expect(t, run_command(Reload_File{tab_id = e.tab_id}, {kind = .UI}).ok)
	testing.expect(t, e.refused != "", "shows why instead of the bytes")
	testing.expect(t, e.readonly)
	testing.expect(t, !strings.contains(text_of(e), "ELF"))
	// a dirty buffer, then binary on disk: banner; Reload refuses too (never empty and clean)
	q := write(dir, "s.txt", "text\n")
	f := open(t, q)
	ed_insert(f, "mine")
	time.sleep(10 * time.Millisecond)
	write(dir, "s.txt", "\x00\x01\x02")
	editor_check_disk(f)
	testing.expect(t, f.disk_changed)
	testing.expect(t, run_command(Reload_File{tab_id = f.tab_id}, {kind = .UI}).ok)
	testing.expect(t, f.refused != "", "binary on disk: refused, not an empty clean buffer")
}

@(test)
review_save_never_overwrites_a_newer_write :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	p := write(dir, "n.txt", "one\n")
	e := open(t, p)
	ed_insert(e, "mine ")
	time.sleep(10 * time.Millisecond)
	write(dir, "n.txt", "theirs\n") // the watcher has not told us yet
	r := run_command(Save_File{e.tab_id}, {kind = .Script})
	testing.expect(t, !r.ok, "refused")
	testing.expect_value(t, read(p), "theirs\n")
	testing.expect(t, e.disk_changed, "the banner shows")
}

@(test)
review_only_regular_files :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	fifo := fmt.tprintf("%s/pipe", dir)
	testing.expect(t, posix.mkfifo(strings.clone_to_cstring(fifo, context.temp_allocator), {.IRUSR, .IWUSR}) == .OK)
	// a writer that closes soon, so a read that blocks still ends (before the fix)
	th := thread.create_and_start_with_poly_data(fifo, proc(path: string) {
		// opens (without blocking) once a reader waits, then closes: a blocked read ends
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		for _ in 0 ..< 200 {
			time.sleep(10 * time.Millisecond)
			fd := posix.open(cpath, {.WRONLY, .NONBLOCK})
			if fd >= 0 {
				posix.close(fd)
				return
			}
		}
	})
	r := run_command(Open_File{path = fifo}, {kind = .Script})
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, r.ok, r.error)
	if e := editor_of(r.created_id); e != nil do testing.expect(t, e.refused != "", "a FIFO is not opened")
	rd := run_command(Open_File{path = "/dev/null"}, {kind = .Script})
	if e := editor_of(rd.created_id); e != nil do testing.expect(t, e.refused != "", "a device is not opened")
	// restored editor tabs on non-regular files are skipped
	run_command(Restore_Session{project_id = state.projects[0].id, pi_session_id = "s-r", tabs = {{kind = .Editor, cwd = fifo}}}, {kind = .Internal})
	last := state.open_sessions[len(state.open_sessions) - 1]
	testing.expect_value(t, len(last.tabs), 1) // only the pi tab
}

@(test)
review_big_files_are_plain_text :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	b := strings.builder_make(context.temp_allocator)
	for strings.builder_len(b) < SYNTAX_MAX_BYTES + 1000 do strings.write_string(&b, "int x = 1; // padding padding padding\n")
	e := open(t, write(dir, "huge.c", strings.to_string(b)))
	testing.expect(t, e.sx.lang == nil, "over the limit: plain text")
	// a parse that runs out of time falls back to plain text
	old := syntax_budget
	syntax_budget = 1 * time.Microsecond
	defer syntax_budget = old
	f := open(t, write(dir, "slow.c", strings.to_string(b)[:SYNTAX_MAX_BYTES / 2]))
	scratch: [dynamic]u8
	defer delete(scratch)
	toks := syntax_tokens(&f.sx, &f.buf, 0, 100, &scratch)
	testing.expect(t, toks == nil && f.sx.parser == nil, "timed out: plain")
}

@(test)
review_git_runs_bounded_and_raw :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	// a stuck command is killed at the timeout
	k := time.tick_now()
	_, ok := run_bounded(dir, {"sleep", "5"}, 200 * time.Millisecond)
	testing.expect(t, !ok)
	testing.expect(t, time.tick_since(k) < 2 * time.Second)
	if _, gok := git_run(dir, "init", "-q"); !gok do return
	// textconv must not change what the gutter compares against
	write(dir, ".gitattributes", "*.txt diff=upper\n")
	git_run(dir, "config", "diff.upper.textconv", "tr a-z A-Z")
	p := write(dir, "low.txt", "abc\n")
	git_run(dir, "add", ".")
	git_run(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "x")
	e := open(t, p)
	// the HEAD text arrives from a worker thread
	for i := 0; i < 300 && !e.git.loaded; i += 1 {
		inbox_drain()
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, e.git.loaded && e.git.tracked)
	testing.expect_value(t, e.git.head, "abc\n")
}

@(test)
review_diff_memory_is_bounded :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a := make([]u64, 3000, context.temp_allocator)
	b := make([]u64, 3000, context.temp_allocator)
	for i in 0 ..< 3000 {
		a[i] = u64(i * 2)
		b[i] = u64(i * 2 + (i % 3 == 0 ? 1 : 0)) // every third line differs
	}
	arena: runtime.Arena
	defer runtime.arena_destroy(&arena)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.arena_allocator(&arena), runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	context.temp_allocator = mem.tracking_allocator(&track)
	h := line_diff(a, b)
	testing.expect(t, len(h) > 0)
	used := int(track.total_memory_allocated)
	log.infof("line_diff allocated %d KB, %d hunks", used >> 10, len(h))
	testing.expectf(t, used < 8 << 20, "line_diff used %d MB", used >> 20)
	// still correct: rebuilding b from a and the hunks
	out := make([dynamic]u64, context.temp_allocator)
	at := 0
	for x in h {
		append(&out, ..a[at:x.a_lo])
		append(&out, ..b[x.b_lo:x.b_hi])
		at = x.a_hi
	}
	append(&out, ..a[at:])
	testing.expect(t, slice.equal(out[:], b))
	// under the cap: real hunks, and they rebuild b
	for i in 0 ..< 3000 do b[i] = u64(i * 2 + (i % 10 == 0 ? 1 : 0))
	h2 := line_diff(a, b)
	testing.expect_value(t, len(h2), 300)
	clear(&out)
	at = 0
	for x in h2 {
		append(&out, ..a[at:x.a_lo])
		append(&out, ..b[x.b_lo:x.b_hi])
		at = x.a_hi
	}
	append(&out, ..a[at:])
	testing.expect(t, slice.equal(out[:], b))
}

@(test)
review_watch_only_projects_and_files :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	setup()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	outside := fmt.tprintf("%s/pi-desk-outside-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(outside)
	defer os.remove_all(outside)
	open(t, write(outside, "loose.txt", "x"))
	for f in watched_folders() do testing.expectf(t, !strings.has_prefix(f, fs_real(outside)), "watches %s recursively", f)
	home := os.get_env("HOME", context.temp_allocator)
	watch_folder(fs_real(home))
	for f in watched_folders() do testing.expectf(t, f != fs_real(home), "watches the home folder recursively")
}

@(test)
review_save_refuses_read_only_files :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	p := write(dir, "ro.txt", "keep\n")
	os.change_mode(p, os.perm_number(0o444))
	defer os.change_mode(p, os.perm_number(0o644))
	e := open(t, p)
	ed_insert(e, "x")
	r := run_command(Save_File{e.tab_id}, {kind = .Script})
	testing.expect(t, !r.ok)
	testing.expect(t, strings.contains(r.error, "read-only"), r.error)
	testing.expect_value(t, read(p), "keep\n")
}

// ---- review round 2 ----

@(private = "file")
git_repo_with :: proc(t: ^testing.T, dir, name, text: string) -> (path: string, ok: bool) {
	if _, gok := git_run(dir, "init", "-q"); !gok do return "", false
	path = write(dir, name, text)
	git_run(dir, "add", ".")
	git_run(dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "x")
	return path, true
}

@(test)
review2_git_results_follow_their_load :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	p, ok := git_repo_with(t, dir, "a.txt", "a\n")
	if !ok do return
	e := open(t, p)
	settle(proc() -> bool {return !any_git_loading()})
	// a load whose file is renamed before its result lands: not stuck loading
	e.git.head_stale = true
	git_load_head(e)
	testing.expect(t, e.git.loading)
	testing.expect(t, run_command(Rename_Path{from = p, to = fmt.tprintf("%s/b.txt", dir)}, {kind = .Script}).ok)
	settle(proc() -> bool {return !any_git_loading()})
	testing.expect(t, !e.git.loading, "a dropped result ends the load")
	testing.expect(t, e.git.head_stale, "and asks for another")
	// a .git change while a load runs: the older result leaves HEAD stale
	settle(proc() -> bool {
		for _, ed in editors do if ed.git.head_stale && !ed.git.loading do git_gutter_update(ed)
		return !any_git_loading()
	})
	e.git.head_stale = true
	git_load_head(e)
	editor_path_changed(fmt.tprintf("%s/.git/HEAD", dir))
	settle(proc() -> bool {return !any_git_loading()})
	testing.expect(t, e.git.head_stale, "a change during the load is not lost")
	// status: a change while git status runs leaves it not ok
	run_command(List_Dir{path = "."}, {kind = .Script})
	fs_model_changed(fmt.tprintf("%s/b.txt", dir))
	settle(proc() -> bool {return !any_git_loading()})
	found := false
	for s in fs_model.status do if s.root == fs_real(dir) {
		found = true
		testing.expect(t, !s.ok, "a change during git status: not ok")
	}
	testing.expect(t, found)
}

@(test)
review2_read_errors_refuse :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	p := write(dir, "big.txt", strings.repeat("x", 200_000, context.temp_allocator))
	old := disk_read_chunk
	defer disk_read_chunk = old
	disk_read_chunk = proc(f: ^os.File, b: []u8) -> (int, os.Error) {
		@(static) calls := 0
		calls += 1
		if calls % 2 == 0 do return 0, .Invalid_File // the second read fails
		return os.read(f, b)
	}
	e := open(t, p)
	testing.expect(t, e.refused != "", "a failed read is not a short file")
	testing.expect_value(t, tb_len(&e.buf), 0)
	// reload with a failing read: never a truncated clean buffer
	disk_read_chunk = old
	f := open(t, write(dir, "c.txt", strings.repeat("y", 200_000, context.temp_allocator)))
	disk_read_chunk = proc(f: ^os.File, b: []u8) -> (int, os.Error) {
		@(static) calls := 0
		calls += 1
		if calls % 2 == 0 do return 0, .Invalid_File
		return os.read(f, b)
	}
	run_command(Reload_File{tab_id = f.tab_id}, {kind = .UI})
	testing.expect(t, f.refused != "" || tb_len(&f.buf) == 200_000, "reload: refused or whole")
	testing.expect(t, !(f.refused == "" && tb_len(&f.buf) < 200_000), "never truncated")
}

@(test)
review2_own_root_includes_the_session_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	s := cur()
	// the session runs in a worktree outside the project folder
	wt := fmt.tprintf("%s-wt", dir)
	os.make_directory_all(wt)
	defer os.remove_all(wt)
	s.cwd = fs_real(wt, context.allocator)
	ctl := Caller{kind = .Control, tab_id = s.tabs[0].id}
	testing.expect(t, run_command(Create_File{path = "in-wt.txt"}, ctl).ok, "inside its own session folder: no confirmation")
	testing.expect(t, os.exists(fmt.tprintf("%s/in-wt.txt", s.cwd)))
	pr, _ := editor_apply(Create_File{path = "p.txt"}, Caller{kind = .Panel, tab_id = s.tabs[0].id})
	testing.expect(t, pr.ok, pr.error)
	testing.expect(t, run_command(Create_File{path = fmt.tprintf("%s/in-proj.txt", dir)}, ctl).ok, "the project folder too")
}

@(test)
review2_cmd_slash_in_read_only_tabs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	e := open(t, write(dir, "s.c", "int x;\n"))
	testing.expect(t, editor_takes_cmd_slash(), "a file: toggles a comment")
	time.sleep(10 * time.Millisecond)
	write(dir, "s.c", "long x;\n")
	ed_insert(e, "y")
	editor_check_disk(e)
	rd := run_command(Diff_File{e.tab_id, .Diff_Disk}, {kind = .Script})
	testing.expect(t, rd.ok)
	testing.expect(t, !editor_takes_cmd_slash(), "a diff view: the shortcuts sheet")
	bin := run_command(Open_File{path = write(dir, "b.bin", "\x00\x01")}, {kind = .Script})
	testing.expect(t, bin.ok)
	testing.expect(t, !editor_takes_cmd_slash(), "a refused file: the shortcuts sheet")
}

// Select all, then Indent (the right-click menu's row or ⌘]) twice: the
// selection still covers every line (an end past the changed lines moves
// with the text), so the second Indent and an Outdent act on all of them.
@(test)
editor_indent_keeps_select_all :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := setup()
	e := open(t, write(dir, "a.txt", "hello\nworld\nchanged\n"))
	ed_select_all(e)
	ed_indent_lines(e, false)
	testing.expect_value(t, text_of(e), "    hello\n    world\n    changed\n")
	testing.expect_value(t, ed_selected_text(e), "    hello\n    world\n    changed\n")
	ed_indent_lines(e, false)
	testing.expect_value(t, text_of(e), "        hello\n        world\n        changed\n")
	ed_indent_lines(e, true)
	ed_indent_lines(e, true)
	testing.expect_value(t, text_of(e), "hello\nworld\nchanged\n")
	testing.expect_value(t, ed_selected_text(e), "hello\nworld\nchanged\n")
}
