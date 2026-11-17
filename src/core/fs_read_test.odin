package core

// Reads in another checkout of a known project (fs_read.odin): list_dir, find_files and file_read
// reach a worktree the last scan listed, for the callers that may read the project; never a
// sibling folder, a worktree of a repository no project is in, a crafted .git file, or one not
// listed yet; .git stays out; writes there stay refused; a symlinked path resolves as for a root.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
rd_git :: proc(dir: string, args: ..string) -> bool {
	full := make([dynamic]string, context.temp_allocator)
	append(&full, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main")
	append(&full, ..args)
	_, ok := git_run(dir, ..full[:])
	return ok
}

@(private = "file")
rd_put :: proc(path: string, text := "x\n") {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
rd_scan :: proc(dir: string) -> bool {
	if r := wt_repo_for(dir); r != nil {
		r.started = {}
		r.ok = false
	}
	r := wt_repo_for(dir)
	if r == nil do return false
	for _ in 0 ..< 1000 {
		inbox_drain()
		if !r.loading && r.loaded do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
fs_read_in_a_listed_checkout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/dh-read-%d", tmp, time.now()._nsec)
	os.make_directory_all(made)
	base := fs_real(made, context.allocator)
	defer os.remove_all(base)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	os.make_directory_all(fmt.tprintf("%s/home", base))
	os.set_env("HOME", fmt.tprintf("%s/home", base))
	os.set_env("GIT_CONFIG_NOSYSTEM", "1")
	defer {os.set_env("HOME", old_home); os.unset_env("GIT_CONFIG_NOSYSTEM")}

	proj := fmt.tprintf("%s/proj", base)
	wt := fmt.tprintf("%s/proj-wt", base) // a sibling worktree: no session, not files_set_root
	late := fmt.tprintf("%s/proj-late", base)
	plain := fmt.tprintf("%s/plain", base)
	other := fmt.tprintf("%s/other", base)
	other_wt := fmt.tprintf("%s/other-wt", base)
	fake := fmt.tprintf("%s/fake", base)
	os.make_directory_all(proj)
	if !rd_git(proj, "init", "-q") do return // no git here
	rd_put(fmt.tprintf("%s/a.txt", proj), "a\n")
	rd_put(fmt.tprintf("%s/src/main.odin", proj), "m\n")
	rd_git(proj, "add", ".")
	rd_git(proj, "commit", "-qm", "init")
	rd_git(proj, "worktree", "add", "-q", "-b", "feature", wt)
	rd_put(fmt.tprintf("%s/plain.txt", plain), "p\n")
	os.make_directory_all(other)
	rd_git(other, "init", "-q")
	rd_put(fmt.tprintf("%s/o.txt", other), "o\n")
	rd_git(other, "add", ".")
	rd_git(other, "commit", "-qm", "init")
	rd_git(other, "worktree", "add", "-q", "-b", "ow", other_wt)
	// a folder whose .git file claims the worktree's gitdir
	rd_put(fmt.tprintf("%s/.git", fake), fmt.tprintf("gitdir: %s/.git/worktrees/proj-wt\n", proj))
	rd_put(fmt.tprintf("%s/f.txt", fake), "f\n")
	alias := fmt.tprintf("%s/alias", base) // a link to the worktree
	posix.symlink(strings.clone_to_cstring(wt, context.temp_allocator), strings.clone_to_cstring(alias, context.temp_allocator))

	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj), label = "proj"})
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(plain), label = "plain"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("r-1"), project_id = state.projects[0].id, cwd = strings.clone(proj)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	own_tab := s.tabs[0].id
	append(&state.open_sessions, s)
	s2 := Open_Session{id = new_id(), pi_session_id = strings.clone("r-2"), project_id = state.projects[1].id, cwd = strings.clone(plain)}
	append(&s2.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	plain_tab := s2.tabs[0].id
	append(&state.open_sessions, s2)
	state.current_session = s.id

	user := Caller{kind = .UI}
	web := Caller{kind = .UI, web = true}
	ls :: proc(path: string, by: Caller) -> Result {return run_command(List_Dir{path = path}, by)}
	rf :: proc(path: string, by: Caller) -> Result {return run_command(File_Read{path = path}, by)}

	// before git listed it: refused (the scan starts)
	testing.expect_value(t, ls(wt, web).error, FS_NOT_IN_PROJECT)
	if !testing.expect(t, rd_scan(proj), "scanned") do return
	// the read check answers from the last scan: a file changed in a checkout (the counts stale)
	// starts no scan, however often the page polls
	if repo := wt_repo_for(proj, counts = false); repo != nil {
		runs := repo.runs
		repo.files_changed = true
		for _ in 0 ..< 5 do testing.expect(t, ls(wt, web).ok, "listed")
		testing.expect_value(t, repo.runs, runs)
		repo.files_changed = false
	}

	// a listed worktree of a known project: listed, read, searched, by the user and a paired browser
	for by in ([]Caller{user, web}) {
		r := ls(wt, by)
		testing.expect(t, r.ok && strings.contains(r.data, `"a.txt"`), r.error)
		testing.expect(t, ls(fmt.tprintf("%s/src", wt), by).ok, "a folder in it")
		f := run_command(Find_Files{root = wt, query = "main"}, by)
		testing.expect(t, f.ok && strings.contains(f.data, `"src/main.odin"`), f.error)
		testing.expect_value(t, json_path(f.data, "root"), wt)
	}
	r := rf(fmt.tprintf("%s/a.txt", wt), web)
	testing.expect(t, r.ok, r.error)
	if r.ok {
		v, _ := json.parse_string(r.data, allocator = context.temp_allocator)
		testing.expect_value(t, v.(json.Object)["text"].(json.String), "a\n")
	}
	// a script or control (list_dir is anyone's): as in the project
	for by in ([]Caller{{kind = .Script}, {kind = .Control}}) do testing.expect(t, ls(wt, by).ok && run_command(Find_Files{root = wt, query = "a"}, by).ok, "anyone's read")
	// a pi tab's bridge sends none of these; the check itself: no checkout reads at all, not even
	// its own project's (it keeps what fs_check gives it)
	_, _, pe := fs_check_read(wt, {kind = .Panel, tab_id = own_tab}, allow_root = true)
	testing.expect_value(t, pe, FS_NOT_IN_PROJECT)
	_, _, pe = fs_check_read(wt, {kind = .Panel, tab_id = plain_tab}, allow_root = true)
	testing.expect_value(t, pe, FS_NOT_IN_PROJECT)
	_, _, pe = fs_check_read(proj, {kind = .Panel, tab_id = own_tab}, allow_root = true)
	testing.expect_value(t, pe, "")
	// whoever is refused for the project is refused here too
	for by in ([]Caller{{}, {kind = .App}, {kind = .Tab_Host}, {kind = .Panel, tab_id = own_tab}}) {
		testing.expect(t, !ls(proj, by).ok && !ls(wt, by).ok, "not this caller")
	}
	testing.expect(t, !rf(fmt.tprintf("%s/a.txt", proj), {kind = .Script}).ok && !rf(fmt.tprintf("%s/a.txt", wt), {kind = .Script}).ok, "file_read: a browser's only")
	testing.expect(t, !rf(fmt.tprintf("%s/a.txt", wt), user).ok, "file_read: a browser's only")

	// never .git in it
	testing.expect_value(t, ls(fmt.tprintf("%s/.git", wt), web).error, "not inside .git")
	testing.expect(t, !rf(fmt.tprintf("%s/.git", wt), web).ok, "its .git file")
	testing.expect_value(t, run_command(Find_Files{root = fmt.tprintf("%s/src", wt), query = "main"}, web).error, "root must be a project folder")

	// a sibling folder, a worktree of a repository no project is in, a crafted .git file: no
	testing.expect_value(t, ls(fmt.tprintf("%s/..", plain), web).error, FS_NOT_IN_PROJECT)
	testing.expect_value(t, ls(base, web).error, FS_NOT_IN_PROJECT)
	testing.expect(t, rd_scan(other) || true)
	testing.expect_value(t, ls(other_wt, web).error, FS_NOT_IN_PROJECT)
	testing.expect(t, !rf(fmt.tprintf("%s/o.txt", other_wt), web).ok, "an unknown repository's worktree")
	testing.expect(t, !run_command(Find_Files{root = other_wt, query = "o"}, web).ok, "an unknown repository's worktree")
	testing.expect_value(t, ls(fake, web).error, FS_NOT_IN_PROJECT)
	testing.expect(t, !rf(fmt.tprintf("%s/f.txt", fake), web).ok, "a crafted .git file")
	// made after the last scan: not until it is listed
	rd_git(proj, "worktree", "add", "-q", "-b", "late", late)
	testing.expect_value(t, ls(late, web).error, FS_NOT_IN_PROJECT)
	rd_scan(proj)
	testing.expect(t, ls(late, web).ok, "listed now")

	// a symlinked path resolves as for a root: the worktree's real path
	r = ls(alias, web)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, json_path(r.data, "path"), wt)
	r = rf(fmt.tprintf("%s/a.txt", alias), web)
	testing.expect(t, r.ok, r.error)

	// writes there: refused for everyone (reads only), nothing made or changed
	a := fmt.tprintf("%s/a.txt", wt)
	refused :: proc(r: Result) -> bool {return !r.ok && r.error != "" && r.error != "needs_confirmation"}
	for by in ([]Caller{user, web}) {
		testing.expect(t, refused(run_command(Create_File{path = fmt.tprintf("%s/new.txt", wt)}, by)), "create_file")
		testing.expect(t, refused(run_command(Create_Dir{path = fmt.tprintf("%s/newdir", wt)}, by)), "create_dir")
		testing.expect(t, refused(run_command(Rename_Path{from = a, to = fmt.tprintf("%s/b.txt", wt)}, by)), "rename_path")
		testing.expect(t, refused(run_command(Delete_Path{path = a}, by)), "delete_path")
		testing.expect(t, refused(run_command(Fs_Copy{from = fmt.tprintf("%s/a.txt", proj), to = fmt.tprintf("%s/c.txt", wt)}, by)), "copy into it")
		testing.expect(t, refused(run_command(Fs_Copy{from = a, to = fmt.tprintf("%s/c.txt", proj)}, by)), "copy out of it")
	}
	testing.expect(t, refused(run_command(File_Save{path = a, text = "changed\n", force = true}, web)), "file_save")
	testing.expect(t, !os.exists(fmt.tprintf("%s/new.txt", wt)) && !os.exists(fmt.tprintf("%s/c.txt", wt)) && !os.exists(fmt.tprintf("%s/c.txt", proj)), "nothing made")
	data, _ := os.read_entire_file(a, context.temp_allocator)
	testing.expect_value(t, string(data), "a\n")
}

// Only a project (or session) folder that is its repository's top gets its sibling checkouts: a
// project in a subfolder of a repository (a monorepo's package; a folder under a HOME that is a
// dotfiles repository) gets none, so the repository's top and the rest of it stay unreadable; a
// checkout at or above HOME never; a checkout in a credential place only for the user here.
@(test)
fs_read_only_from_a_repository_top :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/dh-read2-%d", tmp, time.now()._nsec)
	os.make_directory_all(made)
	base := fs_real(made, context.allocator)
	defer os.remove_all(base)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	home := fmt.tprintf("%s/home", base)
	os.make_directory_all(home)
	os.set_env("HOME", home)
	os.set_env("GIT_CONFIG_NOSYSTEM", "1")
	defer {os.set_env("HOME", old_home); os.unset_env("GIT_CONFIG_NOSYSTEM")}
	web := Caller{kind = .UI, web = true}
	user := Caller{kind = .UI}
	ls :: proc(path: string, by: Caller) -> Result {return run_command(List_Dir{path = path}, by)}
	rf :: proc(path: string, by: Caller) -> Result {return run_command(File_Read{path = path}, by)}

	// a monorepo: the project is a package folder, with a sibling worktree of the repository
	mono := fmt.tprintf("%s/mono", base)
	mono_wt := fmt.tprintf("%s/mono-wt", base)
	rd_put(fmt.tprintf("%s/pkg/a/a.txt", mono), "a\n")
	rd_put(fmt.tprintf("%s/pkg/b/secret.txt", mono), "b\n")
	if !rd_git(mono, "init", "-q") do return // no git here
	rd_git(mono, "add", ".")
	rd_git(mono, "commit", "-qm", "init")
	rd_git(mono, "worktree", "add", "-q", "-b", "mw", mono_wt)
	pkg := fmt.tprintf("%s/pkg/a", mono)
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(pkg), label = "a"})
	testing.expect(t, rd_scan(pkg), "scanned")
	testing.expect(t, ls(pkg, web).ok, "the project itself")
	for by in ([]Caller{user, web, {kind = .Script}}) {
		testing.expect_value(t, ls(mono, by).error, FS_NOT_IN_PROJECT)
		testing.expect_value(t, ls(fmt.tprintf("%s/pkg/b", mono), by).error, FS_NOT_IN_PROJECT)
		testing.expect(t, !run_command(Find_Files{root = mono, query = "secret"}, by).ok, "find_files at the repository's top")
		testing.expect_value(t, ls(mono_wt, by).error, FS_NOT_IN_PROJECT)
	}
	testing.expect(t, !rf(fmt.tprintf("%s/pkg/b/secret.txt", mono), web).ok, "another package's file")
	testing.expect(t, !rf(fmt.tprintf("%s/pkg/a/a.txt", mono_wt), web).ok, "the worktree's copy of the package")

	// HOME is a dotfiles repository; the project is a plain folder under it
	rd_put(fmt.tprintf("%s/.zsh_history", home), "history\n")
	rd_put(fmt.tprintf("%s/code/foo/f.txt", home), "f\n")
	rd_git(home, "init", "-q")
	rd_git(home, "add", ".zsh_history")
	rd_git(home, "commit", "-qm", "dotfiles")
	foo := fmt.tprintf("%s/code/foo", home)
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(foo), label = "foo"})
	rd_scan(foo)
	testing.expect(t, ls(foo, web).ok, "the project itself")
	testing.expect_value(t, ls(home, web).error, FS_NOT_IN_PROJECT)
	testing.expect(t, !rf(fmt.tprintf("%s/.zsh_history", home), web).ok, "HOME's files")
	testing.expect(t, !run_command(Find_Files{root = home, query = "zsh"}, web).ok, "find_files in HOME")
	// ... and a project that is a worktree of that repository (its own top): HOME is still never one
	dots := fmt.tprintf("%s/dots-wt", base)
	rd_git(home, "worktree", "add", "-q", "-b", "dw", dots)
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(dots), label = "dots"})
	testing.expect(t, rd_scan(dots), "scanned")
	testing.expect_value(t, ls(home, web).error, FS_NOT_IN_PROJECT)
	testing.expect(t, !rf(fmt.tprintf("%s/.zsh_history", home), web).ok, "HOME's files")

	// a normal project at its repository's top: its sibling worktree reads; one in a credential place
	// (a folder holding .credentials.json) only for the user here
	proj := fmt.tprintf("%s/proj", base)
	wt := fmt.tprintf("%s/proj-wt", base)
	cw := fmt.tprintf("%s/proj-cred", base)
	rd_put(fmt.tprintf("%s/a.txt", proj), "a\n")
	rd_git(proj, "init", "-q")
	rd_git(proj, "add", ".")
	rd_git(proj, "commit", "-qm", "init")
	rd_git(proj, "worktree", "add", "-q", "-b", "w1", wt)
	rd_git(proj, "worktree", "add", "-q", "-b", "w2", cw)
	rd_put(fmt.tprintf("%s/.credentials.json", cw), "{}\n")
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj), label = "proj"})
	testing.expect(t, rd_scan(proj), "scanned")
	for by in ([]Caller{user, web, {kind = .Script}, {kind = .Control}}) do testing.expect(t, ls(wt, by).ok, "a sibling worktree")
	testing.expect(t, rf(fmt.tprintf("%s/a.txt", wt), web).ok, "its file")
	testing.expect(t, ls(cw, user).ok, "the user here: a credential place reads as in a project")
	for by in ([]Caller{web, {kind = .Script}, {kind = .Control}}) do testing.expect_value(t, ls(cw, by).error, FS_NOT_IN_PROJECT)
	testing.expect(t, !rf(fmt.tprintf("%s/a.txt", cw), web).ok, "a credential place: not for a browser")
	// a pi tab's bridge: nothing beyond what it has today
	_, _, pe := fs_check_read(wt, {kind = .Panel, tab_id = 1}, allow_root = true)
	testing.expect_value(t, pe, FS_NOT_IN_PROJECT)
}
