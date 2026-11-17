package core

// A browser's file_read and file_save (web_files.odin): a browser's only; inside a project
// folder; no credentials or secrets, .git, links out, binaries, oversize; a save replaces the
// file atomically with its permissions, refuses a file changed on disk unless forced, and its
// text is never in what events and the log write.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
web_files_read_and_save :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	tmpl := strings.clone_to_cstring(fmt.tprintf("%s/wf-XXXXXX", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")), context.temp_allocator)
	base := fs_real(string(posix.mkdtemp(([^]u8)(tmpl))))
	proj := fmt.tprintf("%s/proj", base)
	out := fmt.tprintf("%s/outside", base)
	for d in ([]string{proj, out, fmt.tprintf("%s/.git", proj), fmt.tprintf("%s/src", proj)}) do os.make_directory_all(d)
	put :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]u8)text)}
	put(fmt.tprintf("%s/README.md", proj), "# Hi\n")
	put(fmt.tprintf("%s/src/a.ts", proj), "let a = 1\n")
	put(fmt.tprintf("%s/secret.txt", out), "outside\n")
	put(fmt.tprintf("%s/.env", proj), "K=V\n")
	put(fmt.tprintf("%s/server.pem", proj), "-----BEGIN\n")
	put(fmt.tprintf("%s/.git/config", proj), "[core]\n")
	put(fmt.tprintf("%s/bin.dat", proj), "a\x00b\x00c")
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/secret.txt", out), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/link.txt", proj), context.temp_allocator))
	posix.symlink(strings.clone_to_cstring(out, context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/outdir", proj), context.temp_allocator))
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj)})
	web := Caller{kind = .UI, web = true}

	read :: proc(path: string, by: Caller, since := "") -> (json.Object, Result) {
		r := run_command(File_Read{path = path, since = since}, by)
		if !r.ok do return nil, r
		v, _ := json.parse_string(r.data, allocator = context.temp_allocator)
		return v.(json.Object), r
	}
	o, r := read(fmt.tprintf("%s/src/a.ts", proj), web)
	testing.expect(t, r.ok, r.error)
	if o == nil do return
	testing.expect_value(t, o["text"].(json.String), "let a = 1\n")
	testing.expect_value(t, o["markdown"].(json.Boolean), false)
	h := strings.clone(o["hash"].(json.String), context.temp_allocator)
	o2, _ := read(fmt.tprintf("%s/src/a.ts", proj), web, h)
	testing.expect(t, o2 != nil && o2["same"] != nil && o2["text"] == nil, "unchanged: no text")
	// a poll with the hash it has: an unchanged file (fstat: inode, size, times) is not read again
	reads0 := web_file_reads
	for _ in 0 ..< 3 {
		o3, _ := read(fmt.tprintf("%s/src/a.ts", proj), web, h)
		testing.expect(t, o3 != nil && o3["same"] != nil, "unchanged")
	}
	testing.expect_value(t, web_file_reads, reads0)
	// the same size and its old mtime put back: its ctime changed, so it is read (and not same)
	ast: posix.stat_t
	posix.stat(strings.clone_to_cstring(fmt.tprintf("%s/src/a.ts", proj), context.temp_allocator), &ast)
	put(fmt.tprintf("%s/src/a.ts", proj), "let b = 1\n")
	times := [2]posix.timespec{ast.st_atim, ast.st_mtim}
	posix.utimensat(posix.AT_FDCWD, strings.clone_to_cstring(fmt.tprintf("%s/src/a.ts", proj), context.temp_allocator), &times, {})
	o4, _ := read(fmt.tprintf("%s/src/a.ts", proj), web, h)
	testing.expect(t, o4 != nil && o4["text"] != nil && o4["text"].(json.String) == "let b = 1\n", "changed in place: read")
	testing.expect_value(t, web_file_reads, reads0 + 1)
	put(fmt.tprintf("%s/src/a.ts", proj), "let a = 1\n")
	md, _ := read(fmt.tprintf("%s/README.md", proj), web)
	testing.expect(t, md != nil && md["markdown"].(json.Boolean), "Markdown")

	// refused: the window, a script; outside; links out; secrets; .git; binary; relative; a folder
	refused :: proc(t: ^testing.T, path: string, by: Caller, why: string) {
		_, r := read(path, by)
		testing.expectf(t, !r.ok && strings.contains(r.error, why), "%s: %q (want %q)", path, r.error, why)
	}
	refused(t, fmt.tprintf("%s/src/a.ts", proj), Caller{kind = .UI}, "only a browser")
	refused(t, fmt.tprintf("%s/src/a.ts", proj), Caller{kind = .Script}, "not allowed for this caller") // a .User command
	refused(t, fmt.tprintf("%s/secret.txt", out), web, "only inside a project folder")
	refused(t, fmt.tprintf("%s/link.txt", proj), web, "a link")
	refused(t, fmt.tprintf("%s/outdir/secret.txt", proj), web, "only inside a project folder")
	refused(t, fmt.tprintf("%s/.env", proj), web, "credentials")
	refused(t, fmt.tprintf("%s/server.pem", proj), web, "secret")
	refused(t, fmt.tprintf("%s/.git/config", proj), web, ".git")
	refused(t, fmt.tprintf("%s/bin.dat", proj), web, "Binary")
	refused(t, "src/a.ts", web, "absolute")
	refused(t, fmt.tprintf("%s/src", proj), web, "not a regular file")
	refused(t, "/dev/null", web, "device")
	big := strings.repeat("x", WEB_FILE_MAX + 1, context.temp_allocator)
	put(fmt.tprintf("%s/big.txt", proj), big)
	refused(t, fmt.tprintf("%s/big.txt", proj), web, "too large")

	// save: with the hash it read; its mode kept; then a change on disk refuses the next save
	a := fmt.tprintf("%s/src/a.ts", proj)
	posix.chmod(strings.clone_to_cstring(a, context.temp_allocator), posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP})
	s := run_command(File_Save{path = a, text = "let a = 2\n", base = h}, web)
	testing.expect(t, s.ok, s.error)
	got, _ := os.read_entire_file(a, context.temp_allocator)
	testing.expect_value(t, string(got), "let a = 2\n")
	st: posix.stat_t
	posix.stat(strings.clone_to_cstring(a, context.temp_allocator), &st)
	testing.expect_value(t, st.st_mode & posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH}, posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP})
	stale := run_command(File_Save{path = a, text = "let a = 3\n", base = h}, web)
	testing.expect(t, !stale.ok && strings.contains(stale.data, `"changed"`), stale.error)
	forced := run_command(File_Save{path = a, text = "let a = 3\n", base = h, force = true}, web)
	testing.expect(t, forced.ok, forced.error)
	got, _ = os.read_entire_file(a, context.temp_allocator)
	testing.expect_value(t, string(got), "let a = 3\n")
	// no temp file left beside it
	entries, _ := os.read_all_directory_by_path(fmt.tprintf("%s/src", proj), context.temp_allocator)
	testing.expect_value(t, len(entries), 1)

	// save refused: through a link, outside, a secret, a new file, the window, too large
	save_refused :: proc(t: ^testing.T, path: string, by: Caller, why: string, text := "x") {
		r := run_command(File_Save{path = path, text = text, force = true}, by)
		testing.expectf(t, !r.ok && strings.contains(r.error, why), "save %s: %q (want %q)", path, r.error, why)
	}
	save_refused(t, fmt.tprintf("%s/link.txt", proj), web, "a link")
	save_refused(t, fmt.tprintf("%s/outdir/secret.txt", proj), web, "only inside a project folder")
	save_refused(t, fmt.tprintf("%s/.env", proj), web, "credentials")
	save_refused(t, fmt.tprintf("%s/new.txt", proj), web, "no such file")
	save_refused(t, a, Caller{kind = .UI}, "only a browser")
	save_refused(t, a, web, "too large", big)
	o3, _ := os.read_entire_file(fmt.tprintf("%s/secret.txt", out), context.temp_allocator)
	testing.expect_value(t, string(o3), "outside\n")

	// Review (P2): .git in another case (a case-insensitive volume opens the same entry), at
	// any component, read or saved: a worktree's .git file names its gitdir
	put(fmt.tprintf("%s/src/.git", proj), "gitdir: /elsewhere\n")
	for gp in ([]string{fmt.tprintf("%s/.GIT/config", proj), fmt.tprintf("%s/.Git/config", proj), fmt.tprintf("%s/src/.GIT", proj), fmt.tprintf("%s/src/.git", proj)}) {
		refused(t, gp, web, ".git")
		save_refused(t, gp, web, ".git")
	}
	gd, _ := os.read_entire_file(fmt.tprintf("%s/src/.git", proj), context.temp_allocator)
	testing.expect_value(t, string(gd), "gitdir: /elsewhere\n")
	os.remove(fmt.tprintf("%s/src/.git", proj))
	// Review (P3): a forced save checks the file on disk as a read does (binary, UTF-8)
	put(fmt.tprintf("%s/latin1.txt", proj), "caf\xe9\n")
	save_refused(t, fmt.tprintf("%s/bin.dat", proj), web, "Binary")
	save_refused(t, fmt.tprintf("%s/latin1.txt", proj), web, "not shown") // binary or not UTF-8
	bd, _ := os.read_entire_file(fmt.tprintf("%s/bin.dat", proj), context.temp_allocator)
	testing.expect_value(t, string(bd), "a\x00b\x00c")
	// Review (P3): a name near NAME_MAX saves (the temp file's name does not grow from it)
	long := fmt.tprintf("%s/src/%s.txt", proj, strings.repeat("n", 251, context.temp_allocator))
	put(long, "old\n")
	ls := run_command(File_Save{path = long, text = "new\n", force = true}, web)
	testing.expect(t, ls.ok, ls.error)
	lg, _ := os.read_entire_file(long, context.temp_allocator)
	testing.expect_value(t, string(lg), "new\n")

	// what events and the log write: the path and the length, never the text
	j := command_json(File_Save{path = a, text = "TOP-SECRET-TEXT", base = h}, redact = true) // events and the log
	testing.expect(t, !strings.contains(j, "TOP-SECRET") && strings.contains(j, `"text_bytes":15`), j)
	os.remove_all(base)
}

// Codex's hooks in a project that holds a Codex home (CODEX_HOME there): a browser reads them, never
// saves them (codex_view_only), as the window's editor; its config there saves.
@(test)
web_files_codex_hooks_read_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	tmpl := strings.clone_to_cstring(fmt.tprintf("%s/wfc-XXXXXX", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")), context.temp_allocator)
	base := fs_real(string(posix.mkdtemp(([^]u8)(tmpl))))
	defer os.remove_all(base)
	proj := fmt.tprintf("%s/proj", base)
	cx := fmt.tprintf("%s/codex-home", proj)
	os.make_directory_all(cx)
	old, had := os.lookup_env("CODEX_HOME", context.temp_allocator)
	os.set_env("CODEX_HOME", cx)
	defer if had do os.set_env("CODEX_HOME", old); else do os.unset_env("CODEX_HOME")
	_ = os.write_entire_file(fmt.tprintf("%s/hooks.json", cx), transmute([]u8)string("{}\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/config.toml", cx), transmute([]u8)string("a = 1\n"))
	append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj)})
	web := Caller{kind = .UI, web = true}
	for name in ([]string{"hooks.json", "config.toml"}) {
		path := fmt.tprintf("%s/%s", cx, name)
		r := run_command(File_Read{path = path}, web)
		testing.expectf(t, r.ok, "%s read: %s", name, r.error)
		if !r.ok do continue
		v, _ := json.parse_string(r.data, allocator = context.temp_allocator)
		h := strings.clone(v.(json.Object)["hash"].(json.String), context.temp_allocator)
		r = run_command(File_Save{path = path, text = "changed\n", base = h}, web)
		if name == "hooks.json" {
			testing.expect_value(t, r.error, "Codex's hooks are read-only here")
			data, _ := os.read_entire_file(path, context.temp_allocator)
			testing.expect_value(t, string(data), "{}\n")
		} else do testing.expect(t, r.ok, r.error)
	}
}

// #152 review: a folder on the way swapped for a link into Codex's home after the path was checked
// (CODEX_HOME inside the project): the save never lands in Codex's hooks.
@(test)
web_files_codex_hooks_swapped_folder :: proc(t: ^testing.T) {
	when TEST_HOOKS { // the swap needs web_file_save_race (hook-only)
		context.allocator = runtime.heap_allocator()
		inbox_drain()
		state = State{}
		defer state = State{}
		tmpl := strings.clone_to_cstring(fmt.tprintf("%s/wfs-XXXXXX", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")), context.temp_allocator)
		base := fs_real(string(posix.mkdtemp(([^]u8)(tmpl))))
		defer os.remove_all(base)
		proj := fmt.tprintf("%s/proj", base)
		cx := fmt.tprintf("%s/codex-home", proj)
		os.make_directory_all(fmt.tprintf("%s/hooks", cx))
		os.make_directory_all(fmt.tprintf("%s/a/hooks", proj))
		old, had := os.lookup_env("CODEX_HOME", context.temp_allocator)
		os.set_env("CODEX_HOME", cx)
		defer if had do os.set_env("CODEX_HOME", old); else do os.unset_env("CODEX_HOME")
		hook := fmt.tprintf("%s/hooks/pre.sh", cx)
		_ = os.write_entire_file(hook, transmute([]u8)string("echo hook\n"))
		_ = os.write_entire_file(fmt.tprintf("%s/a/hooks/pre.sh", proj), transmute([]u8)string("mine\n"))
		append(&state.projects, Project{id = new_id(), group = .Projects, cwd = strings.clone(proj)})
		@(static) swap_proj: string
		swap_proj = proj
		web_file_save_race = proc() {
			// proj/a -> proj/codex-home: proj/a/hooks is now Codex's hooks folder
			os.rename(fmt.tprintf("%s/a", swap_proj), fmt.tprintf("%s/a-old", swap_proj))
			posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/codex-home", swap_proj), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/a", swap_proj), context.temp_allocator))
		}
		defer web_file_save_race = nil
		r := run_command(File_Save{path = fmt.tprintf("%s/a/hooks/pre.sh", proj), text = "rm -rf ~\n", force = true}, Caller{kind = .UI, web = true})
		testing.expect(t, !r.ok, "not saved")
		data, _ := os.read_entire_file(hook, context.temp_allocator)
		testing.expect_value(t, string(data), "echo hook\n")
	}
}
