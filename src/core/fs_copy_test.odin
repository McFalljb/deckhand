package core

// fs_copy (fs_copy.odin) and restore_path (fs_restore.odin): links copied as links, never written
// through a link that leaves the project, never into itself, credentials (the user's left out,
// anyone else's refuse the copy), .git left out, the caps, unique names, never over anything,
// modes kept, a midway failure; restore ids only the core issues, the user's only, a taken path
// or a gone folder refused, the XDG Trash's info file removed. All in scratch folders; the
// user's Trash is never touched (fs_trash_fn, XDG_DATA_HOME).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// A clean State with one project in a fresh scratch folder (real path), and an outside folder
// next to it (not a project).
@(private = "file")
csetup :: proc(tag: string) -> (proj, outside: string) {
	state = State{}
	base := fmt.tprintf("%s/dhc-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/proj", base))
	os.make_directory_all(fmt.tprintf("%s/outside", base))
	base = fs_real(base, context.allocator)
	proj = fmt.aprintf("%s/proj", base)
	outside = fmt.aprintf("%s/outside", base)
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(proj), label = "proj"})
	return
}

@(private = "file")
cwrite :: proc(path: string, text := "x") {
	os.make_directory_all(tdir(path))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
cread :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<missing>"
}

@(private = "file")
is_link :: proc(path: string) -> bool {
	st: posix.stat_t
	return posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK && posix.S_ISLNK(st.st_mode)
}

@(private = "file")
link_text :: proc(path: string) -> string {
	buf: [1024]u8
	n := posix.readlink(strings.clone_to_cstring(path, context.temp_allocator), raw_data(buf[:]), len(buf))
	return n < 0 ? "" : strings.clone(string(buf[:n]), context.temp_allocator)
}

// fs_copy_plan then fs_copy_run, on this thread (the worker's own steps).
@(private = "file")
copy_now :: proc(from, to: string, caller: Caller, unique := false) -> (plan: Fs_Copy_Plan, err: string, arena: ^virtual.Arena) {
	arena = new(virtual.Arena)
	_ = virtual.arena_init_growing(arena)
	plan, err = fs_copy_plan(from, to, unique, caller, virtual.arena_allocator(arena))
	if err != "" do return
	_, failed, rerr := fs_copy_run(plan)
	if rerr != "" do err = fmt.tprintf("%s: %s", failed, rerr)
	return
}

@(private = "file")
arena_done :: proc(a: ^virtual.Arena) {
	virtual.arena_destroy(a)
	free(a)
}

UI_HERE :: Caller{kind = .UI}

@(test)
fs_copy_links_stay_links :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := csetup("links")
	defer {os.remove_all(tdir(proj)); state = State{}}
	cwrite(fmt.tprintf("%s/secret.txt", outside), "outside")
	cwrite(fmt.tprintf("%s/src/a.txt", proj), "a")
	os.make_directory_all(fmt.tprintf("%s/outdir/deep", outside))
	cwrite(fmt.tprintf("%s/outdir/deep/f.txt", outside), "deep")
	posix.symlink(strings.clone_to_cstring(fmt.tprintf("%s/secret.txt", outside)), strings.clone_to_cstring(fmt.tprintf("%s/src/out.txt", proj)))
	posix.symlink("../../outside/outdir", strings.clone_to_cstring(fmt.tprintf("%s/src/outdir", proj)))
	posix.symlink("nowhere", strings.clone_to_cstring(fmt.tprintf("%s/src/dangling", proj)))
	_, err, a := copy_now(fmt.tprintf("%s/src", proj), fmt.tprintf("%s/dst", proj), UI_HERE)
	defer arena_done(a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, cread(fmt.tprintf("%s/dst/a.txt", proj)), "a")
	// each link is a link with the same text, never what it leads to
	for name in ([]string{"out.txt", "outdir", "dangling"}) {
		p := fmt.tprintf("%s/dst/%s", proj, name)
		testing.expectf(t, is_link(p), "%s is a link", name)
		testing.expect_value(t, link_text(p), link_text(fmt.tprintf("%s/src/%s", proj, name)))
	}
	// a link at the top is copied as a link too
	_, err2, a2 := copy_now(fmt.tprintf("%s/src/outdir", proj), fmt.tprintf("%s/linkcopy", proj), UI_HERE)
	defer arena_done(a2)
	testing.expect_value(t, err2, "")
	testing.expect(t, is_link(fmt.tprintf("%s/linkcopy", proj)), "the top link stays a link")
}

@(test)
fs_copy_never_through_a_link_out :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := csetup("through")
	defer {os.remove_all(tdir(proj)); state = State{}}
	cwrite(fmt.tprintf("%s/a.txt", proj), "a")
	// a folder in the project that is a link to outside: the target's real parent decides
	posix.symlink(strings.clone_to_cstring(outside), strings.clone_to_cstring(fmt.tprintf("%s/escape", proj)))
	_, err, a := copy_now(fmt.tprintf("%s/a.txt", proj), fmt.tprintf("%s/escape/a.txt", proj), UI_HERE)
	defer arena_done(a)
	testing.expect_value(t, err, "only inside a project folder")
	testing.expect(t, !os.exists(fmt.tprintf("%s/a.txt", outside)), "nothing written outside")
	// nor read through one: the source's real parent is outside too
	cwrite(fmt.tprintf("%s/o.txt", outside), "o")
	_, err2, a2 := copy_now(fmt.tprintf("%s/escape/o.txt", proj), fmt.tprintf("%s/o.txt", proj), UI_HERE)
	defer arena_done(a2)
	testing.expect_value(t, err2, "only inside a project folder")
	// checked, then the target's folder swapped for a link out before the worker runs: refused there
	os.make_directory_all(fmt.tprintf("%s/into", proj))
	arena := new(virtual.Arena)
	_ = virtual.arena_init_growing(arena)
	defer arena_done(arena)
	plan, perr := fs_copy_plan(fmt.tprintf("%s/a.txt", proj), fmt.tprintf("%s/into/a.txt", proj), false, UI_HERE, virtual.arena_allocator(arena))
	testing.expect_value(t, perr, "")
	os.remove(fmt.tprintf("%s/into", proj))
	posix.symlink(strings.clone_to_cstring(outside), strings.clone_to_cstring(fmt.tprintf("%s/into", proj)))
	n, _, rerr := fs_copy_run(plan)
	testing.expect_value(t, n, 0)
	testing.expect_value(t, rerr, "the target's folder moved or cannot be opened")
	testing.expect(t, !os.exists(fmt.tprintf("%s/a.txt", outside)) || cread(fmt.tprintf("%s/a.txt", outside)) == "<missing>", "nothing written through the link")
}

@(test)
fs_copy_not_into_itself_never_over :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, _ := csetup("self")
	defer {os.remove_all(tdir(proj)); state = State{}}
	cwrite(fmt.tprintf("%s/d/sub/f.txt", proj), "f")
	_, err, a := copy_now(fmt.tprintf("%s/d", proj), fmt.tprintf("%s/d/sub/d2", proj), UI_HERE)
	defer arena_done(a)
	testing.expect_value(t, err, FS_COPY_INTO_ITSELF)
	_, err2, a2 := copy_now(fmt.tprintf("%s/d", proj), fmt.tprintf("%s/d/d", proj), UI_HERE)
	defer arena_done(a2)
	testing.expect_value(t, err2, FS_COPY_INTO_ITSELF)
	// never over anything: a taken name is refused without unique
	cwrite(fmt.tprintf("%s/x.txt", proj), "x")
	cwrite(fmt.tprintf("%s/y.txt", proj), "y")
	_, err3, a3 := copy_now(fmt.tprintf("%s/x.txt", proj), fmt.tprintf("%s/y.txt", proj), UI_HERE)
	defer arena_done(a3)
	testing.expect_value(t, err3, FS_COPY_TAKEN)
	testing.expect_value(t, cread(fmt.tprintf("%s/y.txt", proj)), "y")
	// a dangling link at the target is taken too
	posix.symlink("nowhere", strings.clone_to_cstring(fmt.tprintf("%s/dl", proj)))
	_, err4, a4 := copy_now(fmt.tprintf("%s/x.txt", proj), fmt.tprintf("%s/dl", proj), UI_HERE)
	defer arena_done(a4)
	testing.expect_value(t, err4, FS_COPY_TAKEN)
	// never the project folder itself, never into .git
	_, err5, a5 := copy_now(proj, fmt.tprintf("%s/p2", proj), UI_HERE)
	defer arena_done(a5)
	testing.expect_value(t, err5, "not on a project folder itself")
	os.make_directory_all(fmt.tprintf("%s/.GIT", proj))
	_, err6, a6 := copy_now(fmt.tprintf("%s/x.txt", proj), fmt.tprintf("%s/.GIT/x.txt", proj), UI_HERE)
	defer arena_done(a6)
	testing.expect_value(t, err6, "not inside .git")
}

@(test)
fs_copy_unique_names :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, _ := csetup("unique")
	defer {os.remove_all(tdir(proj)); state = State{}}
	cwrite(fmt.tprintf("%s/a.txt", proj), "a")
	cwrite(fmt.tprintf("%s/.env", proj), "e")
	cwrite(fmt.tprintf("%s/d/f", proj), "f")
	want := []string{"a copy.txt", "a copy 2.txt", "a copy 3.txt"}
	for w in want {
		plan, err, a := copy_now(fmt.tprintf("%s/a.txt", proj), fmt.tprintf("%s/a.txt", proj), UI_HERE, unique = true)
		testing.expect_value(t, err, "")
		testing.expect_value(t, plan.to, fmt.tprintf("%s/%s", proj, w))
		arena_done(a)
	}
	testing.expect_value(t, cread(fmt.tprintf("%s/a copy 2.txt", proj)), "a")
	plan, err, a := copy_now(fmt.tprintf("%s/.env", proj), fmt.tprintf("%s/.env", proj), UI_HERE, unique = true)
	testing.expect_value(t, err, "")
	testing.expect_value(t, plan.to, fmt.tprintf("%s/.env copy", proj))
	arena_done(a)
	plan, err, a = copy_now(fmt.tprintf("%s/d", proj), fmt.tprintf("%s/d", proj), UI_HERE, unique = true)
	testing.expect_value(t, err, "")
	testing.expect_value(t, plan.to, fmt.tprintf("%s/d copy", proj))
	testing.expect_value(t, cread(fmt.tprintf("%s/d copy/f", proj)), "f")
	arena_done(a)
	// a free name is used as asked
	plan, err, a = copy_now(fmt.tprintf("%s/a.txt", proj), fmt.tprintf("%s/b.txt", proj), UI_HERE, unique = true)
	testing.expect_value(t, plan.to, fmt.tprintf("%s/b.txt", proj))
	arena_done(a)
}

@(test)
fs_copy_credentials_and_git :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, _ := csetup("cred")
	defer {os.remove_all(tdir(proj)); state = State{}}
	cwrite(fmt.tprintf("%s/src/ok.txt", proj), "ok")
	cwrite(fmt.tprintf("%s/src/sub/.claude.json.backup", proj), "{}") // a credential by its name
	cwrite(fmt.tprintf("%s/src/.git/config", proj), "[core]")
	cwrite(fmt.tprintf("%s/src/sub/.Git", proj), "gitdir: x") // a worktree's .git file, in another case
	// the user here: the credential and .git left out, and said
	plan, err, a := copy_now(fmt.tprintf("%s/src", proj), fmt.tprintf("%s/dst", proj), UI_HERE)
	defer arena_done(a)
	testing.expect_value(t, err, "")
	testing.expect_value(t, cread(fmt.tprintf("%s/dst/ok.txt", proj)), "ok")
	testing.expect(t, !os.exists(fmt.tprintf("%s/dst/sub/.claude.json.backup", proj)), "the credential is not copied")
	testing.expect(t, !os.exists(fmt.tprintf("%s/dst/.git", proj)), ".git is not copied")
	testing.expect(t, !os.exists(fmt.tprintf("%s/dst/sub/.Git", proj)), ".Git is not copied")
	said := copy_skipped_text(plan.skipped)
	testing.expect(t, strings.contains(said, "sub/.claude.json.backup: a credential"), said)
	testing.expect(t, strings.contains(said, ".git: a git repository's folder"), said)
	testing.expect(t, strings.contains(said, "sub/.Git: a git"), said)
	// a folder holding Claude's account file is a config folder: what is in it is a credential too
	cwrite(fmt.tprintf("%s/src2/cfg/.claude.json", proj), "{}")
	cwrite(fmt.tprintf("%s/src2/cfg/history.jsonl", proj), "secret")
	cwrite(fmt.tprintf("%s/src2/plain.txt", proj), "p")
	plan2, err2, a1 := copy_now(fmt.tprintf("%s/src2", proj), fmt.tprintf("%s/dst3", proj), UI_HERE)
	defer arena_done(a1)
	testing.expect_value(t, err2, "")
	testing.expect_value(t, cread(fmt.tprintf("%s/dst3/plain.txt", proj)), "p")
	testing.expect(t, !os.exists(fmt.tprintf("%s/dst3/cfg/history.jsonl", proj)), "inside a config folder: not copied")
	testing.expect(t, strings.contains(copy_skipped_text(plan2.skipped), "cfg/history.jsonl: a credential"), copy_skipped_text(plan2.skipped))
	// anyone else: the whole copy refused, nothing written
	others := []Caller{{kind = .Control}, {kind = .Script}, {kind = .UI, web = true}, {kind = .UI, hub = true}}
	for c in others {
		_, e, a2 := copy_now(fmt.tprintf("%s/src", proj), fmt.tprintf("%s/dst2", proj), c)
		testing.expect_value(t, e, fmt.tprintf(FS_COPY_CREDENTIAL, "sub/.claude.json.backup"))
		testing.expect(t, !os.exists(fmt.tprintf("%s/dst2", proj)), "nothing written")
		arena_done(a2)
	}
	// a key by its name (what file_read refuses) too, and the credential itself at the top
	cwrite(fmt.tprintf("%s/k/server.pem", proj), "k")
	_, e3, a3 := copy_now(fmt.tprintf("%s/k", proj), fmt.tprintf("%s/k2", proj), Caller{kind = .Control})
	defer arena_done(a3)
	testing.expect_value(t, e3, fmt.tprintf(FS_COPY_CREDENTIAL, "server.pem"))
	_, e4, a4 := copy_now(fmt.tprintf("%s/k/server.pem", proj), fmt.tprintf("%s/k.txt", proj), Caller{kind = .Script})
	defer arena_done(a4)
	testing.expect_value(t, e4, fmt.tprintf(FS_COPY_CREDENTIAL, "."))
	_, e5, a5 := copy_now(fmt.tprintf("%s/src/sub/.claude.json.backup", proj), fmt.tprintf("%s/c.txt", proj), UI_HERE)
	defer arena_done(a5)
	testing.expect_value(t, e5, "it is a credential: not copied")
	// a folder that is a credential place by what it holds (Claude's marker): anyone else's refused
	cwrite(fmt.tprintf("%s/cfg/home/.credentials.json", proj), "{}")
	_, e6, a6 := copy_now(fmt.tprintf("%s/cfg", proj), fmt.tprintf("%s/cfg2", proj), Caller{kind = .Control})
	defer arena_done(a6)
	testing.expect(t, e6 != "" && !os.exists(fmt.tprintf("%s/cfg2", proj)), e6)
	// pi's agent folder inside the project: a credential place, anyone else's refused
	old, had := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer {if had do os.set_env("PI_CODING_AGENT_DIR", old); else do os.unset_env("PI_CODING_AGENT_DIR")}
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agentish/agent", proj))
	cwrite(fmt.tprintf("%s/agentish/agent/auth.json", proj), "{}")
	_, e7, a7 := copy_now(fmt.tprintf("%s/agentish", proj), fmt.tprintf("%s/ag2", proj), Caller{kind = .Control})
	defer arena_done(a7)
	testing.expect_value(t, e7, CREDENTIAL_PLACE_REFUSED)
	_, e8, a8 := copy_now(fmt.tprintf("%s/ok2.txt", proj), fmt.tprintf("%s/agentish/agent/x.txt", proj), Caller{kind = .Control})
	defer arena_done(a8)
	testing.expect(t, e8 != "", "into a credential place: refused")
	// another name for pi's sign-in (a hard link) inside an ordinary folder: a credential too
	cwrite(fmt.tprintf("%s/hl/ok.txt", proj), "ok")
	posix.link(strings.clone_to_cstring(fmt.tprintf("%s/agentish/agent/auth.json", proj)), strings.clone_to_cstring(fmt.tprintf("%s/hl/notes.txt", proj)))
	plan9, e9, a9 := copy_now(fmt.tprintf("%s/hl", proj), fmt.tprintf("%s/hl2", proj), UI_HERE)
	defer arena_done(a9)
	testing.expect_value(t, e9, "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/hl2/notes.txt", proj)) && os.exists(fmt.tprintf("%s/hl2/ok.txt", proj)), "the hard link is left out")
	testing.expect(t, strings.contains(copy_skipped_text(plan9.skipped), "notes.txt: a credential"), copy_skipped_text(plan9.skipped))
	_, e10, a10 := copy_now(fmt.tprintf("%s/hl", proj), fmt.tprintf("%s/hl3", proj), Caller{kind = .Control})
	defer arena_done(a10)
	testing.expect_value(t, e10, fmt.tprintf(FS_COPY_CREDENTIAL, "notes.txt"))
}

@(private = "file")
copy_skipped_text :: proc(s: []Fs_Copy_Skip) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x in s do fmt.sbprintf(&b, "%s: %s\n", x.rel, x.why)
	return strings.to_string(b)
}

@(test)
fs_copy_caps_before_writing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, _ := csetup("caps")
	defer {os.remove_all(tdir(proj)); state = State{}}
	// bytes: a sparse file just over 2 GB
	big := fmt.tprintf("%s/big/huge.bin", proj)
	cwrite(big, "")
	fd := posix.open(strings.clone_to_cstring(big), {.WRONLY})
	posix.ftruncate(fd, posix.off_t(FS_COPY_MAX_BYTES + 1))
	posix.close(fd)
	_, err, a := copy_now(fmt.tprintf("%s/big", proj), fmt.tprintf("%s/big2", proj), UI_HERE)
	defer arena_done(a)
	testing.expect_value(t, err, "too big to copy: more than 2 GB; nothing was copied")
	testing.expect(t, !os.exists(fmt.tprintf("%s/big2", proj)), "nothing written")
	// entries: one more than the cap
	many := fmt.aprintf("%s/many", proj)
	os.make_directory_all(many)
	for i in 0 ..< FS_COPY_MAX_ENTRIES {
		f := posix.open(strings.clone_to_cstring(fmt.tprintf("%s/%d", many, i), context.temp_allocator), {.WRONLY, .CREAT}, {.IRUSR, .IWUSR})
		posix.close(f)
		if i % 1000 == 0 do free_all(context.temp_allocator)
	}
	_, err2, a2 := copy_now(many, fmt.tprintf("%s/many2", proj), UI_HERE)
	defer arena_done(a2)
	testing.expect_value(t, err2, fmt.tprintf("too many to copy: more than %d files and folders; nothing was copied", FS_COPY_MAX_ENTRIES))
	testing.expect(t, !os.exists(fmt.tprintf("%s/many2", proj)), "nothing written")
}

@(test)
fs_copy_modes_and_midway :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, _ := csetup("modes")
	defer {
		os.remove_all(tdir(proj))
		state = State{}
	}
	cwrite(fmt.tprintf("%s/m/run.sh", proj), "#!/bin/sh")
	posix.chmod(strings.clone_to_cstring(fmt.tprintf("%s/m/run.sh", proj)), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
	cwrite(fmt.tprintf("%s/m/ro/f.txt", proj), "f")
	posix.chmod(strings.clone_to_cstring(fmt.tprintf("%s/m/ro", proj)), {.IRUSR, .IXUSR, .IRGRP, .IXGRP})
	_, err, a := copy_now(fmt.tprintf("%s/m", proj), fmt.tprintf("%s/m2", proj), UI_HERE)
	defer arena_done(a)
	testing.expect_value(t, err, "")
	mode :: proc(p: string) -> u32 {
		st: posix.stat_t
		posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st)
		return u32(transmute(posix._mode_t)st.st_mode) & 0o7777
	}
	testing.expect_value(t, mode(fmt.tprintf("%s/m2/run.sh", proj)), 0o755)
	testing.expect_value(t, mode(fmt.tprintf("%s/m2/ro", proj)), 0o550)
	testing.expect_value(t, cread(fmt.tprintf("%s/m2/ro/f.txt", proj)), "f") // written before the folder's mode was set
	for p in ([]string{fmt.tprintf("%s/m/ro", proj), fmt.tprintf("%s/m2/ro", proj)}) do posix.chmod(strings.clone_to_cstring(p, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	// a source that changed after the checks: stops there, what was copied stays and is counted
	cwrite(fmt.tprintf("%s/s/a.txt", proj), "a")
	cwrite(fmt.tprintf("%s/s/b.txt", proj), "b")
	cwrite(fmt.tprintf("%s/s/c.txt", proj), "c")
	arena := new(virtual.Arena)
	_ = virtual.arena_init_growing(arena)
	defer arena_done(arena)
	plan, perr := fs_copy_plan(fmt.tprintf("%s/s", proj), fmt.tprintf("%s/s2", proj), false, UI_HERE, virtual.arena_allocator(arena))
	testing.expect_value(t, perr, "")
	os.remove(fmt.tprintf("%s/s/b.txt", proj))
	cwrite(fmt.tprintf("%s/s/b.txt", proj), "swapped") // another file at that name
	n, failed, rerr := fs_copy_run(plan)
	testing.expect_value(t, n, 2) // the folder and a.txt
	testing.expect_value(t, failed, "b.txt")
	testing.expect_value(t, rerr, "it changed while copying")
	testing.expect_value(t, cread(fmt.tprintf("%s/s2/a.txt", proj)), "a")
	testing.expect(t, !os.exists(fmt.tprintf("%s/s2/b.txt", proj)), "the swapped file is not copied")
	r := fs_copy_done(Fs_Copy_Done{path = plan.to, copied = n, total = len(plan.items), failed = failed, err = rerr})
	testing.expect_value(t, r.error, fmt.tprintf("copied 2 of 4, then b.txt: it changed while copying (what was copied stays at %s)", plan.to))
	testing.expect(t, strings.contains(r.data, `"failed":"b.txt"`) && strings.contains(r.data, `"copied":2`), r.data)
}

@(test)
fs_copy_command_runs_on_a_worker :: proc(t: ^testing.T) {
	when TEST_HOOKS {
		context.allocator = runtime.heap_allocator()
		inbox_drain()
		proj, _ := csetup("cmd")
		defer {os.remove_all(tdir(proj)); state = State{}}
		cwrite(fmt.tprintf("%s/d/a.txt", proj), "a")
		cwrite(fmt.tprintf("%s/d/.git/HEAD", proj), "ref")
		state.selected_project = state.projects[0].id // relative paths: from its folder
		r := run_command(Fs_Copy{from = "d", to = "d", unique = true}, Caller{kind = .Script})
		testing.expect(t, r.ok && r.pending, r.error)
		for i := 0; i < 500 && fs_copy_running() > 0; i += 1 {
			inbox_drain()
			time.sleep(5 * time.Millisecond)
		}
		inbox_drain()
		testing.expect_value(t, fs_copy_running(), 0)
		testing.expect_value(t, cread(fmt.tprintf("%s/d copy/a.txt", proj)), "a")
		testing.expect(t, !os.exists(fmt.tprintf("%s/d copy/.git", proj)), ".git left out")
		// a control caller outside its own project confirms (class fs_write), nothing copied first
		r2 := run_command(Fs_Copy{from = fmt.tprintf("%s/d", proj), to = fmt.tprintf("%s/e", proj)}, Caller{kind = .Control})
		testing.expect_value(t, r2.error, "needs_confirmation")
		testing.expect(t, strings.contains(r2.confirm_summary, "copy "), r2.confirm_summary)
		testing.expect(t, !os.exists(fmt.tprintf("%s/e", proj)), "not before the confirmation")
		// a refusal comes back at once (no worker)
		r3 := run_command(Fs_Copy{from = "d", to = "d"}, Caller{kind = .Script})
		testing.expect_value(t, r3.error, FS_COPY_TAKEN)
		// the wire
		cmd, err := parse_command(`{"type":"fs_copy","from":"a","to":"b","unique":true}`)
		testing.expect_value(t, err, "")
		if c, ok := cmd.(Fs_Copy); ok do testing.expect(t, c.from == "a" && c.to == "b" && c.unique, "read back")
		_, err2 := parse_command(`{"type":"fs_copy_done","path":"/x"}`)
		testing.expect(t, err2 != "", "the worker's answer is never read from JSON")
	}
}

// ---- restore_path ----

@(private = "file")
fake_trash_dir: string

// A Trash of the test's own: the item moves into fake_trash_dir and says where.
@(private = "file")
fake_trash :: proc(path: string) -> bool {
	to := fmt.tprintf("%s/%d-%s", fake_trash_dir, time.now()._nsec, tbase(path))
	if os.rename(path, to) != nil do return false
	fs_trash_where = to
	return true
}

@(private = "file")
tbase :: proc(p: string) -> string {
	i := strings.last_index_byte(p, '/')
	return i < 0 ? p : p[i + 1:]
}

// delete_path as the user does it (asked, then confirmed): its restore ids, by path.
@(private = "file")
delete_ids :: proc(t: ^testing.T, paths: ..string) -> map[string]string {
	ids := make(map[string]string, context.temp_allocator)
	cmd := len(paths) == 1 ? Delete_Path{path = paths[0]} : Delete_Path{paths = paths}
	r := run_command(cmd, UI_HERE)
	testing.expect_value(t, r.error, "needs_confirmation")
	tok := r.confirm_token
	c := len(paths) == 1 ? Delete_Path{path = paths[0], confirm = tok} : Delete_Path{paths = paths, confirm = tok}
	r = run_command(c, UI_HERE)
	testing.expect(t, r.ok, r.error)
	v, perr := json.parse_string(r.data, allocator = context.temp_allocator)
	if perr != nil do return ids
	o := v.(json.Object)
	testing.expect_value(t, int(o["trashed"].(json.Float)), len(paths))
	if list, ok := o["restore"].(json.Array); ok {
		for x in list {
			e := x.(json.Object)
			ids[e["path"].(json.String)] = e["id"].(json.String)
		}
	}
	return ids
}

@(test)
restore_path_user_only_core_ids :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	proj, outside := csetup("restore")
	defer {os.remove_all(tdir(proj)); state = State{}}
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	fake_trash_dir = outside
	fs_trash_fn = fake_trash
	f := fmt.tprintf("%s/a.txt", proj)
	cwrite(f, "a")
	ids := delete_ids(t, f)
	id := ids[f]
	testing.expect(t, id != "" && !os.exists(f), "trashed, with a restore id")
	// nobody but the user here: refused, the item stays in the Trash
	for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .UI, web = true}, {kind = .UI, hub = true}, {kind = .Internal}}) {
		r := run_command(Restore_Path{id = id}, c)
		testing.expect(t, !r.ok, "refused")
		testing.expect(t, !os.exists(f), "not restored")
	}
	testing.expect_value(t, run_command(Restore_Path{id = id}, Caller{kind = .UI, web = true}).error, FS_RESTORE_USER_ONLY)
	// only an id the core issued: a Trash path, a made-up id, nothing
	entries, _ := os.read_all_directory_by_path(outside, context.temp_allocator)
	for x in ([]string{fmt.tprintf("%s/%s", outside, entries[0].name), "00000000-0000-0000-0000-000000000000", ""}) {
		testing.expect_value(t, run_command(Restore_Path{id = x}, UI_HERE).error, FS_RESTORE_UNKNOWN)
	}
	// taken now: refused, nothing replaced; once free, it comes back
	cwrite(f, "new")
	r := run_command(Restore_Path{id = id}, UI_HERE)
	testing.expect_value(t, r.error, fmt.tprintf("something is at %s now", f))
	testing.expect_value(t, cread(f), "new")
	os.remove(f)
	r = run_command(Restore_Path{id = id}, UI_HERE)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, cread(f), "a")
	testing.expect(t, strings.contains(r.data, `"path":`), r.data)
	// an id is used once
	testing.expect_value(t, run_command(Restore_Path{id = id}, UI_HERE).error, FS_RESTORE_UNKNOWN)
	// its folder gone: refused
	g := fmt.tprintf("%s/sub/g.txt", proj)
	cwrite(g, "g")
	gid := delete_ids(t, g)[g]
	os.remove_all(fmt.tprintf("%s/sub", proj))
	testing.expect_value(t, run_command(Restore_Path{id = gid}, UI_HERE).error, fmt.tprintf("its folder is gone: %s/sub", proj))
	// no longer where the core put it (moved or emptied from the Trash): refused and forgotten
	h := fmt.tprintf("%s/h.txt", proj)
	cwrite(h, "h")
	hid := delete_ids(t, h)[h]
	for e in fs_trashed do if e.id == hid do os.rename(e.trashed, fmt.tprintf("%s.moved", e.trashed))
	testing.expect_value(t, run_command(Restore_Path{id = hid}, UI_HERE).error, FS_RESTORE_GONE)
	testing.expect_value(t, run_command(Restore_Path{id = hid}, UI_HERE).error, FS_RESTORE_UNKNOWN)
	// a batch: one id per item
	b1, b2 := fmt.tprintf("%s/b1", proj), fmt.tprintf("%s/b2/x", proj)
	cwrite(b1)
	cwrite(b2)
	bids := delete_ids(t, b1, fmt.tprintf("%s/b2", proj))
	testing.expect_value(t, len(bids), 2)
	testing.expect(t, run_command(Restore_Path{id = bids[fmt.tprintf("%s/b2", proj)]}, UI_HERE).ok, "the folder back")
	testing.expect_value(t, cread(b2), "x")
	// a Trash that does not say where: no id
	fs_trash_fn = proc(path: string) -> bool {return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil}
	n := fmt.tprintf("%s/n.txt", proj)
	cwrite(n)
	testing.expect_value(t, len(delete_ids(t, n)), 0)
	// the wire
	cmd, err := parse_command(`{"type":"restore_path","id":"abc"}`)
	testing.expect_value(t, err, "")
	if c, ok := cmd.(Restore_Path); ok do testing.expect_value(t, c.id, "abc")
}

@(test)
restore_path_keeps_the_last_200 :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	proj, outside := csetup("cap")
	defer {os.remove_all(tdir(proj)); state = State{}}
	f := fmt.tprintf("%s/f", outside)
	cwrite(f)
	st: posix.stat_t
	posix.lstat(strings.clone_to_cstring(f), &st)
	first := strings.clone(fs_trashed_add(fmt.tprintf("%s/f", proj), f, u64(st.st_dev), u64(st.st_ino)), context.temp_allocator)
	testing.expect(t, first != "", "recorded")
	for _ in 0 ..< FS_RESTORE_MAX do fs_trashed_add(fmt.tprintf("%s/f", proj), f, u64(st.st_dev), u64(st.st_ino))
	testing.expect_value(t, len(fs_trashed), FS_RESTORE_MAX)
	testing.expect_value(t, run_command(Restore_Path{id = first}, UI_HERE).error, FS_RESTORE_UNKNOWN)
	// another item at the place said: no id
	testing.expect_value(t, fs_trashed_add(fmt.tprintf("%s/f", proj), f, u64(st.st_dev), u64(st.st_ino) + 1), "")
}

@(test)
restore_path_xdg_trash :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	proj, outside := csetup("xdgr")
	defer {os.remove_all(tdir(proj)); state = State{}}
	old := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("XDG_DATA_HOME", outside)
	defer {if old != "" do os.set_env("XDG_DATA_HOME", old); else do os.unset_env("XDG_DATA_HOME")}
	saved := fs_trash_fn
	defer fs_trash_fn = saved
	fs_trash_fn = proc(path: string) -> bool {
		why := trash_xdg(path)
		fs_trash_why = why
		return why == ""
	}
	f := fmt.tprintf("%s/doc s.txt", proj)
	cwrite(f, "doc")
	id := delete_ids(t, f)[f]
	info := fmt.tprintf("%s/Trash/info/doc s.txt.trashinfo", outside)
	testing.expect(t, id != "" && os.exists(info) && os.exists(fmt.tprintf("%s/Trash/files/doc s.txt", outside)), "in the XDG Trash")
	r := run_command(Restore_Path{id = id}, UI_HERE)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, cread(f), "doc")
	testing.expect(t, !os.exists(info), "its info file is removed")
	testing.expect(t, !os.exists(fmt.tprintf("%s/Trash/files/doc s.txt", outside)), "out of files/")
}
