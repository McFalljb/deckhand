package core

// The file commands' guards (fs_model.odin): a rename that changes only a name's case, a
// credential's name kept from callers other than the user here, a running tab's folder, the
// Linux core's XDG Trash (trash_xdg.odin), and where the Files tree's new-name row goes.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// A clean State with one project in a fresh temp folder (real path).
@(private = "file")
gsetup :: proc(tag: string) -> string {
	state = State{}
	dir := fmt.tprintf("%s/dhx-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(dir)
	dir = fs_real(dir, context.allocator)
	append(&state.projects, Project{id = new_id(), cwd = dir, label = "proj"})
	return dir
}

@(private = "file")
gwrite :: proc(path: string) {_ = os.write_entire_file(path, transmute([]u8)string("x"))}

@(private = "file")
listed :: proc(dir, name: string) -> bool {
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	for e in entries do if e.name == name do return true
	return false
}

@(test)
fs_rename_case_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("case")
	defer {os.remove_all(dir); state = State{}}
	UI :: Caller{kind = .UI}
	gwrite(fmt.tprintf("%s/readme.md", dir))
	err := fs_rename(fmt.tprintf("%s/readme.md", dir), fmt.tprintf("%s/README.md", dir), UI)
	testing.expect_value(t, err, "")
	testing.expect(t, listed(dir, "README.md") && !listed(dir, "readme.md"), "the new spelling is on disk")
	// a real collision stays refused: another file whose name differs only in case
	gwrite(fmt.tprintf("%s/b.txt", dir))
	if os.exists(fmt.tprintf("%s/B.TXT", dir)) { 	// a volume that ignores case
		gwrite(fmt.tprintf("%s/other.txt", dir))
		testing.expect_value(t, fs_rename(fmt.tprintf("%s/other.txt", dir), fmt.tprintf("%s/B.TXT", dir), UI), "the new name already exists")
	} else { 	// one that keeps case: B.TXT is a name of its own
		gwrite(fmt.tprintf("%s/B.TXT", dir))
		testing.expect_value(t, fs_rename(fmt.tprintf("%s/b.txt", dir), fmt.tprintf("%s/B.TXT", dir), UI), "the new name already exists")
	}
	testing.expect(t, !fs_case_only_rename(fmt.tprintf("%s/README.md", dir), fmt.tprintf("%s/b.txt", dir)), "another name")
}

// pi's agent folder inside a project (PI_CODING_AGENT_DIR), for the tests below; restored by the
// returned proc's caller.
@(private = "file")
agent_in :: proc(dir: string) -> (agent: string, old: string, had: bool) {
	old, had = os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	agent = fmt.tprintf("%s/agent", dir)
	os.make_directory_all(agent)
	os.set_env("PI_CODING_AGENT_DIR", agent)
	return
}

@(test)
fs_rename_keeps_credential_names :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("cred")
	defer {os.remove_all(dir); state = State{}}
	agent, old, had := agent_in(dir)
	defer {if had do os.set_env("PI_CODING_AGENT_DIR", old); else do os.unset_env("PI_CODING_AGENT_DIR")}
	auth := fmt.tprintf("%s/auth.json", agent)
	plain := fmt.tprintf("%s/x.txt", agent)
	gwrite(auth)
	others := []Caller{{kind = .Control}, {kind = .Script}, {kind = .UI, web = true}, {kind = .UI, hub = true}, {kind = .Panel, tab_id = 7, claude = true}}
	for c in others {
		e := fs_rename(auth, plain, c)
		if c.kind == .Panel do testing.expect(t, e != "", "a tab's agent: refused (outside its own folder or by name)")
		else do testing.expect_value(t, e, CREDENTIAL_RENAME_REFUSED)
		testing.expect(t, os.exists(auth) && !os.exists(plain), "not moved")
	}
	// a key by its name (show_secret) too
	key := fmt.tprintf("%s/server.pem", dir)
	gwrite(key)
	testing.expect_value(t, fs_rename(key, fmt.tprintf("%s/k.txt", dir), Caller{kind = .Control}), CREDENTIAL_RENAME_REFUSED)
	// to another credential's name: still hidden, so allowed
	testing.expect_value(t, fs_rename(auth, fmt.tprintf("%s/models-store.json", agent), Caller{kind = .Control}), "")
	// the user at this window may
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/models-store.json", agent), plain, Caller{kind = .UI}), "")
	testing.expect(t, os.exists(plain), "renamed by the user")
	// the other way round is no secret's business; nor is a project's .env (an ordinary file)
	testing.expect_value(t, fs_rename(plain, fmt.tprintf("%s/y.txt", agent), Caller{kind = .Control}), "")
	env := fmt.tprintf("%s/.env", dir)
	gwrite(env)
	testing.expect_value(t, fs_rename(env, fmt.tprintf("%s/env.txt", dir), Caller{kind = .Control}), "")
}

@(test)
fs_guard_running_tab_folder :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("busy")
	defer {os.remove_all(dir); state = State{}}
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	fs_trash_fn = proc(path: string) -> bool {return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil}
	wt := fmt.tprintf("%s/wt", dir)
	os.make_directory_all(fmt.tprintf("%s/inner", wt))
	os.make_directory_all(fmt.tprintf("%s/free", dir))
	s := Open_Session{id = new_id(), project_id = state.projects[0].id, cwd = strings.clone(dir)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "build shell", status = .Running, cwd = strings.clone(fmt.tprintf("%s/inner", wt))})
	append(&state.open_sessions, s)
	UI :: Caller{kind = .UI}
	e := fs_rename(wt, fmt.tprintf("%s/wt2", dir), UI)
	testing.expect(t, strings.contains(e, "build shell") && strings.contains(e, "running"), e)
	testing.expect(t, os.is_dir(wt), "not renamed")
	e = fs_delete(wt, UI)
	testing.expect(t, strings.contains(e, "build shell"), e)
	testing.expect(t, os.is_dir(wt), "not deleted")
	// anyone else is not told which tab (nor its session)
	e = fs_rename(wt, fmt.tprintf("%s/wt2", dir), Caller{kind = .Control})
	testing.expect_value(t, e, FS_IN_USE)
	// another spelling of the folder on a volume that ignores case is the same folder
	if os.exists(fmt.tprintf("%s/WT", dir)) {
		e = fs_rename(fmt.tprintf("%s/WT", dir), fmt.tprintf("%s/wt3", dir), UI)
		testing.expect(t, strings.contains(e, "build shell"), e)
	}
	// a folder no running tab is in: fine; nor does an exited tab hold one
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/free", dir), fmt.tprintf("%s/free2", dir), UI), "")
	state.open_sessions[0].tabs[1].status = .Exited
	testing.expect_value(t, fs_delete(wt, UI), "")
}

@(test)
fs_trash_xdg_home_trash :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scratch := fmt.tprintf("%s/dhx-xdg-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/data", scratch))
	os.make_directory_all(fmt.tprintf("%s/work", scratch))
	defer os.remove_all(scratch)
	scratch = fs_real(scratch)
	old := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", scratch))
	defer {if old != "" do os.set_env("XDG_DATA_HOME", old); else do os.unset_env("XDG_DATA_HOME")}
	testing.expect_value(t, trash_xdg_dir(), fmt.tprintf("%s/data/Trash", scratch))
	f := fmt.tprintf("%s/work/a b%%.txt", scratch)
	gwrite(f)
	testing.expect_value(t, trash_xdg(f), "")
	testing.expect(t, !os.exists(f), "moved")
	testing.expect(t, os.exists(fmt.tprintf("%s/data/Trash/files/a b%%.txt", scratch)), "in files/")
	data, ok := os.read_entire_file(fmt.tprintf("%s/data/Trash/info/a b%%.txt.trashinfo", scratch), context.temp_allocator)
	testing.expect(t, ok == nil, "its info file")
	text := string(data)
	testing.expect(t, strings.has_prefix(text, "[Trash Info]\nPath="), text)
	testing.expect(t, strings.contains(text, "/work/a%20b%25.txt\n"), text)
	testing.expect(t, strings.contains(text, "\nDeletionDate=2"), text)
	// the same name again: a name of its own; a folder too
	gwrite(f)
	testing.expect_value(t, trash_xdg(f), "")
	testing.expect(t, os.exists(fmt.tprintf("%s/data/Trash/files/a b%%.txt.2", scratch)), "a unique name")
	testing.expect(t, os.exists(fmt.tprintf("%s/data/Trash/info/a b%%.txt.2.trashinfo", scratch)), "and its info")
	d := fmt.tprintf("%s/work/dir", scratch)
	os.make_directory_all(fmt.tprintf("%s/sub", d))
	testing.expect_value(t, trash_xdg(d), "")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/data/Trash/files/dir/sub", scratch)), "a folder")
	testing.expect_value(t, trash_xdg(fmt.tprintf("%s/work/gone", scratch)), "no such file or folder")
	// fs_delete says why the platform's Trash refused (another disk), and deletes nothing
	dir := gsetup("xdgdel")
	defer {os.remove_all(dir); state = State{}}
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	fs_trash_fn = proc(path: string) -> bool {fs_trash_why = TRASH_OTHER_DISK; return false}
	g := fmt.tprintf("%s/keep.txt", dir)
	gwrite(g)
	testing.expect_value(t, fs_delete(g, Caller{kind = .UI}), TRASH_OTHER_DISK)
	testing.expect(t, os.exists(g), "still there")
	fs_trash_fn = proc(path: string) -> bool {return false}
	testing.expect_value(t, fs_delete(g, Caller{kind = .UI}), "could not move it to the Trash")
}

@(test)
files_new_row_place :: proc(t: ^testing.T) {
	rows := []Files_Row{
		{path = "/p/a", name = "a", kind = .Dir, expanded = true},
		{path = "/p/a/b", name = "b", depth = 1, kind = .Dir},
		{path = "/p/a/f.txt", name = "f.txt", depth = 1, kind = .File},
		{path = "/p/z.txt", name = "z.txt", kind = .File},
	}
	i, d := files_new_row_at(rows, "/p", "/p")
	testing.expect(t, i == 0 && d == 0, "the root: the first row")
	i, d = files_new_row_at(rows, "/p", "/p/a")
	testing.expect(t, i == 1 && d == 1, "an open folder: its first child")
	i, d = files_new_row_at(rows, "/p", "/p/a/b")
	testing.expect(t, i == 2 && d == 2, "a closed folder: below its row, one deeper")
	i, _ = files_new_row_at(rows, "/p", "/p/a/c")
	testing.expect_value(t, i, -1)
	i, _ = files_new_row_at(rows, "/p", "/p/z.txt")
	testing.expect_value(t, i, -1)
	i, d = files_new_row_at(nil, "/p", "/p")
	testing.expect(t, i == 0 && d == 0, "an empty tree")
}

// A credential's name in another case is a credential's name: a case-only rename (auth.json to
// AUTH.JSON) keeps it, and file_read refuses AUTH.JSON. The target is judged by its name as typed
// (on a volume that ignores case, AUTH.JSON's real path is still auth.json until the rename).
@(test)
fs_credential_names_ignore_case :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("credcase")
	defer {os.remove_all(dir); state = State{}}
	agent, old, had := agent_in(dir)
	defer {if had do os.set_env("PI_CODING_AGENT_DIR", old); else do os.unset_env("PI_CODING_AGENT_DIR")}
	testing.expect(t, settings_credential(fmt.tprintf("%s/AUTH.JSON", agent)), "AUTH.JSON")
	testing.expect(t, settings_credential(fmt.tprintf("%s/Models-Store.Json", agent)), "Models-Store.Json")
	testing.expect(t, settings_credential(fmt.tprintf("%s/x/.CODEX/Auth.json", dir)), ".CODEX/Auth.json")
	testing.expect(t, settings_credential(fmt.tprintf("%s/.CREDENTIALS.JSON", dir)), ".CREDENTIALS.JSON")
	web := Caller{kind = .UI, web = true}
	ctl := Caller{kind = .Control}
	for pair in ([][2]string{{"auth.json", "AUTH.JSON"}, {"models-store.json", "Models-Store.JSON"}}) {
		from, to := fmt.tprintf("%s/%s", agent, pair[0]), fmt.tprintf("%s/%s", agent, pair[1])
		gwrite(from)
		testing.expect_value(t, fs_rename(from, to, ctl), "")
		testing.expect(t, listed(agent, pair[1]), pair[1])
		r := run_command(File_Read{path = to}, web)
		testing.expectf(t, !r.ok && strings.contains(r.error, "credentials"), "file_read %s: %v %q", pair[1], r.ok, r.error)
		// and from there to a plain name: refused
		testing.expect_value(t, fs_rename(to, fmt.tprintf("%s/plain.txt", agent), ctl), CREDENTIAL_RENAME_REFUSED)
		os.remove(to)
	}
}

// A project's .env is an ordinary file: listed, read and saved (a browser's editor), opened by
// `deckhand show`; whoever reaches these can run a shell in the project anyway.
@(test)
fs_env_files_are_ordinary :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("envok")
	defer {os.remove_all(dir); state = State{}}
	for n in ([]string{".env", ".env.local", ".ENV"}) do testing.expect(t, !settings_credential(fmt.tprintf("%s/%s", dir, n)), n)
	env := fmt.tprintf("%s/.env", dir)
	_ = os.write_entire_file(env, transmute([]u8)string("K=V\n"))
	data, err := fs_list_json(dir, Caller{kind = .UI}, false)
	testing.expect(t, err == "" && strings.contains(data, `"name":".env"`), data)
	web := Caller{kind = .UI, web = true}
	r := run_command(File_Read{path = env}, web)
	testing.expect(t, r.ok && strings.contains(r.data, "K=V"), r.error)
	s := run_command(File_Save{path = env, text = "K=W\n", force = true}, web)
	testing.expect(t, s.ok, s.error)
	got, _ := os.read_entire_file(env, context.temp_allocator)
	testing.expect_value(t, string(got), "K=W\n")
}

// A folder at or above a place whose files are credentials by where they are (pi's agent dir, a
// .codex folder holding auth.json) is renamed only by the user here.
@(test)
fs_rename_keeps_credential_places :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("credplace")
	defer {os.remove_all(dir); state = State{}}
	old, had := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer {if had do os.set_env("PI_CODING_AGENT_DIR", old); else do os.unset_env("PI_CODING_AGENT_DIR")}
	os.make_directory_all(fmt.tprintf("%s/tools/agent", dir))
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/tools/agent", dir))
	gwrite(fmt.tprintf("%s/tools/agent/auth.json", dir))
	os.make_directory_all(fmt.tprintf("%s/x/.codex", dir))
	gwrite(fmt.tprintf("%s/x/.codex/auth.json", dir))
	os.make_directory_all(fmt.tprintf("%s/free", dir))
	ctl := Caller{kind = .Control}
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/tools", dir), fmt.tprintf("%s/tools2", dir), ctl), CREDENTIAL_PLACE_REFUSED)
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/tools/agent", dir), fmt.tprintf("%s/tools/a2", dir), ctl), CREDENTIAL_PLACE_REFUSED)
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/x/.codex", dir), fmt.tprintf("%s/x/codex", dir), ctl), CREDENTIAL_PLACE_REFUSED)
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/free", dir), fmt.tprintf("%s/free2", dir), ctl), "")
	testing.expect_value(t, fs_rename(fmt.tprintf("%s/x/.codex", dir), fmt.tprintf("%s/x/codex", dir), Caller{kind = .UI}), "")
}

// .git in any case is .git (a volume that ignores case opens .GIT as .git).
@(test)
fs_check_git_any_case :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := gsetup("gitcase")
	defer {os.remove_all(dir); state = State{}}
	for p in ([]string{".GIT", ".Git/config", "sub/.gIt/HEAD"}) {
		_, _, e := fs_check(fmt.tprintf("%s/%s", dir, p), Caller{kind = .UI})
		testing.expect_value(t, e, "not inside .git")
	}
	_, e := fs_create_dir(fmt.tprintf("%s/.GIT", dir), Caller{kind = .UI})
	testing.expect_value(t, e, "not inside .git")
	_, _, e2 := fs_check(fmt.tprintf("%s/.github/x", dir), Caller{kind = .UI})
	testing.expect_value(t, e2, "")
}

// The home trash is made with its parents (a fresh host has no ~/.local/share), 0700.
@(test)
fs_trash_xdg_makes_parents :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	scratch := fmt.tprintf("%s/dhx-xdgp-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(scratch)
	defer os.remove_all(scratch)
	old := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/fresh/.local/share", scratch))
	defer {if old != "" do os.set_env("XDG_DATA_HOME", old); else do os.unset_env("XDG_DATA_HOME")}
	f := fmt.tprintf("%s/a.txt", scratch)
	gwrite(f)
	testing.expect_value(t, trash_xdg(f), "")
	testing.expect(t, os.exists(fmt.tprintf("%s/fresh/.local/share/Trash/files/a.txt", scratch)), "moved")
	k, st := path_stat(fmt.tprintf("%s/fresh/.local/share/Trash/files", scratch))
	testing.expect(t, k == .Dir && st.mode & 0o077 == 0, "0700")
}
