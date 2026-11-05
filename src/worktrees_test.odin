package main

// Worktrees and branches through the command layer (worktrees.odin): a temp
// repository with a fake HOME (never the user's git config or repos): the
// main checkout, a merged clean worktree, a dirty worktree ahead of main, a
// detached one, one whose folder is gone, branches without a worktree.
// The scan, detection from inside a worktree, files_set_root, clean up's
// refusals and its confirmation, worktree_session.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Wt_Fixture :: struct {
	root, main, merged, dirty, detached, gone, unmerged: string,
	old_home:                                           string,
}

@(private = "file")
git_ok :: proc(dir: string, args: ..string) -> bool {
	full := make([dynamic]string, context.temp_allocator)
	append(&full, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main")
	append(&full, ..args)
	_, ok := git_run(dir, ..full[:])
	return ok
}

@(private = "file")
wt_write :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]u8)text)}

// A clean State with the repository as a project and an open session in
// the main checkout. ok = false without git.
@(private = "file")
wt_setup :: proc() -> (f: Wt_Fixture, ok: bool) {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	files_refresh()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/pi-desk-wt-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	f.root = fs_real(made, context.allocator)
	ensure(strings.contains(f.root, "/pi-desk-wt-test-") && os.is_directory(f.root), "worktree tests: no temp folder")
	// a fake HOME: git reads no user config here
	f.old_home = strings.clone(os.get_env("HOME", context.temp_allocator))
	os.make_directory_all(fmt.tprintf("%s/home", f.root))
	os.set_env("HOME", fmt.tprintf("%s/home", f.root))
	os.set_env("GIT_CONFIG_NOSYSTEM", "1")
	f.main = fmt.aprintf("%s/proj", f.root)
	f.merged = fmt.aprintf("%s/proj-merged", f.root)
	f.dirty = fmt.aprintf("%s/proj-dirty", f.root)
	f.detached = fmt.aprintf("%s/proj-detached", f.root)
	f.gone = fmt.aprintf("%s/proj-gone", f.root)
	f.unmerged = fmt.aprintf("%s/proj-unmerged", f.root)
	os.make_directory_all(f.main)
	if !git_ok(f.main, "init", "-q") do return f, false
	wt_write(fmt.tprintf("%s/a.txt", f.main), "a\n")
	wt_write(fmt.tprintf("%s/.gitignore", f.main), "node_modules/\ndist/\n.env*\n")
	git_ok(f.main, "add", ".")
	git_ok(f.main, "commit", "-qm", "init")
	git_ok(f.main, "branch", "-M", "main")
	// a branch without a worktree, one commit ahead of main
	git_ok(f.main, "checkout", "-q", "-b", "topic")
	wt_write(fmt.tprintf("%s/t.txt", f.main), "t\n")
	git_ok(f.main, "add", ".")
	git_ok(f.main, "commit", "-qm", "topic work")
	git_ok(f.main, "checkout", "-q", "main")
	git_ok(f.main, "branch", "lonely") // merged, no worktree
	git_ok(f.main, "worktree", "add", "-q", "-b", "merged-wt", f.merged)
	git_ok(f.main, "worktree", "add", "-q", "-b", "feature", f.dirty)
	wt_write(fmt.tprintf("%s/f.txt", f.dirty), "f\n")
	git_ok(f.dirty, "add", ".")
	git_ok(f.dirty, "commit", "-qm", "feature work")
	wt_write(fmt.tprintf("%s/a.txt", f.dirty), "changed\n") // dirty
	wt_write(fmt.tprintf("%s/new.txt", f.dirty), "untracked\n")
	git_ok(f.main, "worktree", "add", "-q", "--detach", f.detached, "HEAD")
	git_ok(f.main, "worktree", "add", "-q", "-b", "gone-wt", f.gone)
	os.remove_all(f.gone)
	git_ok(f.main, "worktree", "add", "-q", "-b", "unmerged", f.unmerged)
	wt_write(fmt.tprintf("%s/u.txt", f.unmerged), "u\n")
	git_ok(f.unmerged, "add", ".")
	git_ok(f.unmerged, "commit", "-qm", "unmerged work")
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(f.main), label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("w-1"), project_id = state.projects[0].id, cwd = strings.clone(f.main)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return f, true
}

@(private = "file")
wt_teardown :: proc(f: Wt_Fixture) {
	os.set_env("HOME", f.old_home)
	os.unset_env("GIT_CONFIG_NOSYSTEM")
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	os.remove_all(f.root)
}

// Scans the repository holding dir now (no gap) and waits for the result.
@(private = "file")
wt_scan_now :: proc(dir: string) -> ^Wt_Repo {
	if r := wt_repo_for(dir); r != nil {
		r.started = {}
		r.ok = false
	}
	r := wt_repo_for(dir)
	if r == nil do return nil
	for _ in 0 ..< 1000 {
		inbox_drain()
		if !r.loading && r.loaded do break
		time.sleep(10 * time.Millisecond)
	}
	return r
}

@(test)
wt_scan_lists_checkouts_and_branches :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return // no git here
	r := wt_scan_now(f.main)
	if !testing.expect(t, r != nil && r.loaded, "scanned") do return
	testing.expect_value(t, r.main, f.main)
	testing.expect_value(t, r.default_branch, "main")
	testing.expect_value(t, len(r.checkouts), 6)
	m := wt_checkout(r, f.main)
	if testing.expect(t, m != nil && m.main, "the main checkout") {
		testing.expect_value(t, r.checkouts[0].path, f.main) // first
		testing.expect_value(t, m.branch, "main")
		testing.expect_value(t, m.dirty, 0)
		testing.expect(t, !m.merged, "the default branch is not 'merged'")
	}
	mg := wt_checkout(r, f.merged)
	if testing.expect(t, mg != nil, "merged worktree") {
		testing.expect(t, mg.merged && mg.dirty == 0 && !mg.main, "merged and clean")
		testing.expect(t, wt_cleanable(r, mg^), "may be cleaned up")
	}
	d := wt_checkout(r, f.dirty)
	if testing.expect(t, d != nil, "dirty worktree") {
		testing.expect_value(t, d.branch, "feature")
		testing.expect_value(t, d.dirty, 2)
		testing.expect_value(t, d.ahead, 1)
		testing.expect_value(t, d.behind, 0)
		testing.expect(t, !d.merged && !wt_cleanable(r, d^), "not merged, not cleanable")
	}
	dt := wt_checkout(r, f.detached)
	if testing.expect(t, dt != nil, "detached worktree") {
		testing.expect(t, dt.detached && dt.branch == "", "detached")
		testing.expect(t, strings.has_prefix(wt_branch_label(dt^), "detached "), wt_branch_label(dt^))
		testing.expect_value(t, dt.ahead, 0)
		testing.expect(t, !wt_cleanable(r, dt^), "no branch: not cleanable")
	}
	g := wt_checkout(r, f.gone)
	if testing.expect(t, g != nil, "gone worktree") {
		testing.expect(t, g.missing && g.prunable, "missing and prunable")
		testing.expect(t, !wt_cleanable(r, g^), "not cleanable")
	}
	// branches without a worktree: topic (ahead, unmerged) and lonely (merged)
	topic, lonely: ^Wt_Branch
	for &b in r.branches {
		if b.name == "topic" do topic = &b
		if b.name == "lonely" do lonely = &b
	}
	if testing.expect(t, topic != nil && lonely != nil, "branches listed") {
		testing.expect(t, !topic.checkout && topic.ahead == 1 && !topic.merged, "topic: one ahead")
		testing.expect_value(t, topic.subject, "topic work")
		testing.expect(t, topic.date > 0, "a date")
		testing.expect(t, lonely.merged && !lonely.checkout, "lonely: merged")
	}
	// the command: read-only, for any caller; a pi tab only inside its own project
	res := run_command(List_Worktrees{}, {kind = .Script})
	testing.expect(t, res.ok, res.error)
	testing.expect_value(t, json_path(res.data, "worktrees.#"), "6")
	testing.expect_value(t, json_path(res.data, "worktrees.0.main"), "true")
	for i in 0 ..< 6 {
		path := json_path(res.data, fmt.tprintf("worktrees.%d.path", i))
		testing.expectf(t, json_path(res.data, fmt.tprintf("worktrees.%d.cleanable", i)) == (path == f.merged ? "true" : "<missing>"), "cleanable only for the merged one (%s)", path)
	}
	testing.expect_value(t, json_path(res.data, "default_branch"), "main")
	testing.expect_value(t, json_path(res.data, "loading"), "false")
	pan := run_command(List_Worktrees{path = f.main}, {kind = .Panel, tab_id = state.open_sessions[0].tabs[0].id})
	testing.expect(t, pan.ok, pan.error)
	testing.expect(t, !run_command(List_Worktrees{path = f.root}, {kind = .Script}).ok, "outside a project")
	// no change, inside the gap: no new scan
	runs := r.runs
	wt_repo_for(f.main)
	testing.expect_value(t, r.runs, runs)
	// a change under .git (HEAD, refs): scanned again when asked
	wt_path_changed(fmt.tprintf("%s/.git/refs/heads/topic", f.main))
	testing.expect(t, !r.ok, "a ref change makes it stale")
	wt_scan_now(f.main)
	testing.expect_value(t, r.runs, runs + 1)
	// a change in .git/objects is not one
	r.ok = true
	fs_model_changed(fmt.tprintf("%s/.git/objects/ab/cdef", f.main))
	testing.expect(t, r.ok, "objects: no rescan")
}

@(test)
wt_detected_from_inside_a_worktree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	// the session runs in the dirty worktree (a project of its own)
	s := &state.open_sessions[0]
	delete(s.cwd)
	s.cwd = strings.clone(f.dirty)
	testing.expect_value(t, files_base(), f.dirty)
	w := wt_where(fmt.tprintf("%s", f.dirty))
	testing.expect(t, w.linked && w.top == f.dirty, "a linked worktree")
	testing.expect_value(t, w.common, wt_where(f.main).common)
	testing.expect(t, wt_checkout_err(f.dirty, f.main, listed = false) == "", "the main checkout is of the same repository")
	r := wt_scan_now(f.dirty)
	if !testing.expect(t, r != nil && r.loaded, "scanned") do return
	testing.expect_value(t, r.main, f.main)
	testing.expect_value(t, len(r.checkouts), 6)
	res := run_command(List_Worktrees{}, {kind = .Script})
	testing.expect(t, res.ok, res.error)
	testing.expect_value(t, json_path(res.data, "base"), f.dirty)
	testing.expect_value(t, json_path(res.data, "worktrees.0.path"), f.main)
	// a folder of a worktree: still its repository
	os.make_directory_all(fmt.tprintf("%s/sub", f.dirty))
	testing.expect_value(t, wt_where(fmt.tprintf("%s/sub", f.dirty)).top, f.dirty)
	// not a repository
	plain := fmt.tprintf("%s/plain", f.root)
	os.make_directory_all(plain)
	testing.expect_value(t, wt_where(plain).common, "")
}

@(test)
wt_files_set_root :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	testing.expect_value(t, files_root(), f.main)
	// a script before the scan: refused until git listed the worktrees
	testing.expect_value(t, run_command(Files_Set_Root{path = f.merged}, {kind = .Script}).error, "worktrees are being read: try again")
	wt_scan_now(f.main)
	r := run_command(Files_Set_Root{path = f.merged}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, files_root(), f.merged)
	testing.expect_value(t, json_path(state_json(), "files.checkouts.0.path"), f.merged)
	// its folder is a tree root now: folders open, files are made there
	os.make_directory_all(fmt.tprintf("%s/d", f.merged))
	testing.expect(t, run_command(Files_Expand{path = fmt.tprintf("%s/d", f.merged), expanded = true}, {kind = .Script}).ok)
	testing.expect(t, strings.contains(files_rows_text(files_rows(files_root())), "d/"))
	// refusals: not a checkout of this repository; a base that is not a project
	other := fmt.tprintf("%s/other", f.root)
	os.make_directory_all(other)
	git_ok(other, "init", "-q")
	testing.expect_value(t, run_command(Files_Set_Root{path = other}, {kind = .Script}).error, "not a checkout of the project's repository")
	testing.expect_value(t, run_command(Files_Set_Root{path = fmt.tprintf("%s/d", f.merged)}, {kind = .Script}).error, "not a checkout of the project's repository")
	testing.expect_value(t, run_command(Files_Set_Root{base = f.dirty, path = f.merged}, {kind = .Script}).error, "base must be a project or session folder")
	testing.expect(t, !run_command(Files_Set_Root{path = f.merged}, {kind = .Panel, tab_id = 1}).ok, "not for a pi tab")
	// back to the project's own folder
	testing.expect(t, run_command(Files_Set_Root{path = ""}, {kind = .Script}).ok)
	testing.expect_value(t, files_root(), f.main)
	testing.expect_value(t, json_path(state_json(), "files.checkouts.#"), "0")
	// saved and restored with the workspace
	run_command(Files_Set_Root{path = f.dirty}, {kind = .Script})
	saved := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(saved, `"checkouts"`), saved)
	// the folder goes: the tree shows the project again, and the scan drops the choice
	run_command(Files_Set_Root{path = f.merged}, {kind = .Script})
	os.remove_all(f.merged)
	testing.expect_value(t, files_root(), f.main)
	git_ok(f.main, "worktree", "prune")
	wt_scan_now(f.main)
	for c in state.files.checkouts do testing.expect(t, c.path != f.merged, "dropped")
}

// Clean up as the user: sync refusals come back at once; git's checks run
// on a worker (pending), then the confirmation is parked or an error kept.
@(private = "file")
cleanup :: proc(path: string, token := "") -> (err, summary, tok: string) {
	r := run_command(Worktree_Cleanup{path = path, confirm = token}, {kind = .UI})
	if !r.ok do return r.error, r.confirm_summary, r.confirm_token
	if !r.pending do return "", "", ""
	p := fs_real(path)
	for _ in 0 ..< 1000 {
		inbox_drain()
		if !wt_cleanup_busy(p) do break
		time.sleep(10 * time.Millisecond)
	}
	if e := wt_cleanup_error(p); e != "" do return e, "", ""
	for c in state.pending_confirmations do if wc, is := c.command.(Worktree_Cleanup); is && wc.path == p do return "needs_confirmation", c.summary, c.token
	return "", "", ""
}

@(test)
wt_cleanup_refusals_and_confirmation :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	wt_scan_now(f.main)
	// never for scripts, agents or pi tabs
	for c in ([]Caller{{kind = .Script}, {kind = .Control}, {kind = .Panel, tab_id = state.open_sessions[0].tabs[0].id}}) {
		r := run_command(Worktree_Cleanup{path = f.merged}, c)
		testing.expectf(t, !r.ok && r.confirm_token == "" && !r.pending, "%v refused: %s", c.kind, r.error)
	}
	testing.expect(t, os.is_dir(f.merged), "still there")
	err :: proc(path: string) -> string {e, _, _ := cleanup(path); return e}
	testing.expect_value(t, err(f.main), "the main checkout is never removed")
	testing.expect_value(t, err(f.dirty), "it has changed or untracked files")
	testing.expect_value(t, err(f.unmerged), "unmerged is not merged into main")
	testing.expect_value(t, err(f.detached), "detached HEAD: no branch to delete")
	testing.expect_value(t, err(f.gone), "no such folder")
	testing.expect_value(t, err(fmt.tprintf("%s/home", f.root)), "not a git checkout")
	// a shell running in it
	s := &state.open_sessions[0]
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "shell 1", status = .Exited, cwd = strings.clone(f.merged)})
	testing.expect_value(t, err(f.merged), "a shell tab runs in it")
	pop(&s.tabs)
	testing.expect(t, len(state.pending_confirmations) == 0, "nothing parked by a refusal")
	// a reference-transaction hook never runs (core.hooksPath off for every git call)
	hooks := fmt.tprintf("%s/.git/hooks", f.main)
	os.make_directory_all(hooks)
	marker := fmt.tprintf("%s/hook-ran", f.root)
	wt_write(fmt.tprintf("%s/reference-transaction", hooks), fmt.tprintf("#!/bin/sh\ntouch '%s'\n", marker))
	_, _ = run_bounded("", {"chmod", "+x", fmt.tprintf("%s/reference-transaction", hooks)}, GIT_TIMEOUT)
	// ignored files go too: listed in the question
	os.make_directory_all(fmt.tprintf("%s/node_modules/pkg", f.merged))
	wt_write(fmt.tprintf("%s/node_modules/pkg/index.js", f.merged), "x")
	os.make_directory_all(fmt.tprintf("%s/dist", f.merged))
	wt_write(fmt.tprintf("%s/dist/app.js", f.merged), "x")
	// the user: the checks run on a worker (pending; the row shows it), then the confirmation bar asks
	pr := run_command(Worktree_Cleanup{path = f.merged}, {kind = .UI})
	testing.expect(t, pr.ok && pr.pending, "checked on a worker")
	testing.expect(t, wt_cleanup_busy(f.merged), "busy while git runs")
	for _ in 0 ..< 1000 {
		inbox_drain()
		if !wt_cleanup_busy(f.merged) do break
		time.sleep(10 * time.Millisecond)
	}
	e, summary, tok := cleanup(f.merged) // asked again: the same parked confirmation
	testing.expect_value(t, e, "needs_confirmation")
	testing.expect(t, strings.contains(summary, "Remove worktree") && strings.contains(summary, "merged-wt"), summary)
	testing.expect(t, strings.contains(summary, "2 ignored") && strings.contains(summary, "node_modules/") && strings.contains(summary, "dist/"), summary)
	testing.expect(t, os.is_dir(f.merged), "not before the confirmation")
	e2, _, _ := cleanup(f.merged, tok)
	testing.expect_value(t, e2, "")
	testing.expect(t, !os.exists(f.merged), "worktree removed")
	_, has := git_run(f.main, "show-ref", "--verify", "-q", "refs/heads/merged-wt")
	testing.expect(t, !has, "branch deleted")
	_, kept := git_run(f.main, "show-ref", "--verify", "-q", "refs/heads/feature")
	testing.expect(t, kept, "other branches kept")
	testing.expect(t, os.is_dir(f.dirty) && os.is_dir(f.unmerged), "other worktrees kept")
	testing.expect(t, !os.exists(marker), "no git hook ran")
}

@(test)
wt_cleanup_refuses_secrets_and_unsaved_edits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	wt_scan_now(f.main)
	err :: proc(path: string) -> string {e, _, _ := cleanup(path); return e}
	// an ignored .env: never deleted with the worktree
	wt_write(fmt.tprintf("%s/.env", f.merged), "TOKEN=dummy\n")
	testing.expect(t, strings.contains(err(f.merged), "secret"), err(f.merged))
	os.remove(fmt.tprintf("%s/.env", f.merged))
	// also inside an ignored folder
	os.make_directory_all(fmt.tprintf("%s/dist/conf", f.merged))
	wt_write(fmt.tprintf("%s/dist/conf/.env.local", f.merged), "TOKEN=dummy\n")
	testing.expect(t, strings.contains(err(f.merged), "secret"), err(f.merged))
	os.remove_all(fmt.tprintf("%s/dist", f.merged))
	// an editor tab with unsaved changes under it
	testing.expect(t, run_command(Files_Set_Root{path = f.merged}, {kind = .UI}).ok)
	r := run_command(Open_File{path = fmt.tprintf("%s/a.txt", f.merged)}, {kind = .UI})
	if testing.expect(t, r.ok, r.error) {
		ed_insert(editor_of(r.created_id), "edit")
		testing.expect_value(t, err(f.merged), "an editor tab has unsaved changes in it")
	}
	testing.expect(t, os.is_dir(f.merged), "still there")
}

@(test)
wt_full_refs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	// a tag named like the default branch, at the unmerged branch's commit
	git_ok(f.main, "tag", "main", "unmerged")
	r := wt_scan_now(f.main)
	if c := wt_checkout(r, f.unmerged); testing.expect(t, c != nil) {
		testing.expect(t, !c.merged, "not merged into the branch main")
		testing.expect_value(t, c.ahead, 1)
	}
	e, _, _ := cleanup(f.unmerged)
	testing.expect_value(t, e, "unmerged is not merged into main")
}

@(test)
wt_crafted_git_file_is_not_a_checkout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	wt_scan_now(f.main)
	// a folder whose .git file claims the merged worktree's gitdir
	fake := fmt.tprintf("%s/fake", f.root)
	os.make_directory_all(fake)
	wt_write(fmt.tprintf("%s/.git", fake), fmt.tprintf("gitdir: %s/.git/worktrees/proj-merged\n", f.main))
	testing.expect(t, !run_command(Files_Set_Root{path = fake}, {kind = .Script}).ok, "crafted .git file")
	testing.expect(t, !run_command(Files_Set_Root{path = fake}, {kind = .UI}).ok, "crafted .git file (user)")
	testing.expect(t, !run_command(New_Shell_Tab{session = state.open_sessions[0].id, cwd = fake}, {kind = .Script}).ok, "no shell there")
	testing.expect(t, !run_command(Reveal_In_Finder{path = fake}, {kind = .Script}).ok, "no reveal there")
	for r in fs_roots() do testing.expect(t, r != fake, "never a tree root")
	// a .git symlink to the project's .git
	link := fmt.tprintf("%s/link", f.root)
	os.make_directory_all(link)
	_, _ = run_bounded("", {"ln", "-s", fmt.tprintf("%s/.git", f.main), fmt.tprintf("%s/.git", link)}, GIT_TIMEOUT)
	testing.expect(t, !run_command(Files_Set_Root{path = link}, {kind = .Script}).ok, ".git symlink")
	// a worktree made after the last scan: a script waits for the scan to list it
	late := fmt.tprintf("%s/proj-late", f.root)
	git_ok(f.main, "worktree", "add", "-q", "-b", "late", late)
	testing.expect(t, !run_command(Files_Set_Root{path = late}, {kind = .Script}).ok, "not listed yet")
	wt_scan_now(f.main)
	r := run_command(Files_Set_Root{path = late}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
}

@(test)
wt_list_from_a_pi_tab_is_its_own_project :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	pitab := state.open_sessions[0].tabs[0].id
	// another project's session is on screen
	other := fmt.tprintf("%s/other", f.root)
	os.make_directory_all(other)
	git_ok(other, "init", "-q")
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(other), label = "other"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("o-1"), project_id = state.projects[1].id, cwd = strings.clone(other)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	wt_scan_now(f.main)
	r := run_command(List_Worktrees{}, {kind = .Panel, tab_id = pitab})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, json_path(r.data, "base"), f.main)
	testing.expect(t, !run_command(List_Worktrees{path = other}, {kind = .Panel, tab_id = pitab}).ok, "not another project")
}

@(test)
wt_restore_session_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	p := state.projects[0]
	r1 := run_command(Restore_Session{project_id = p.id, pi_session_id = "wt-s", cwd = f.dirty})
	testing.expect(t, r1.ok, r1.error)
	if s := find_session(r1.created_id); testing.expect(t, s != nil) do testing.expect_value(t, s.cwd, f.dirty)
	r2 := run_command(Restore_Session{project_id = p.id, pi_session_id = "wt-s", cwd = f.dirty})
	testing.expect(t, !r2.ok, "restored once")
}

@(test)
wt_session_in_a_worktree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 5")
	defer os.unset_env("PI_DESK_CMD")
	wt_scan_now(f.main)
	p := state.projects[0]
	testing.expect_value(t, run_command(Worktree_Session{project_id = p.id, path = fmt.tprintf("%s/home", f.root)}, {kind = .Script}).error, "not a checkout of the project's repository")
	r := run_command(Worktree_Session{project_id = p.id, path = f.dirty}, {kind = .Script})
	if !testing.expect(t, r.ok, r.error) do return
	s := find_session(r.created_id)
	if !testing.expect(t, s != nil, "opened") do return
	testing.expect_value(t, s.cwd, f.dirty)
	testing.expect_value(t, s.project_id, p.id)
	testing.expect(t, s.session_dir != "", "kept with the project's sessions")
	// a shell in a worktree outside the project folder, and Reveal there
	sh := run_command(New_Shell_Tab{session = state.open_sessions[0].id, cwd = f.unmerged}, {kind = .Script})
	testing.expect(t, sh.ok, sh.error)
	testing.expect(t, run_command(Reveal_In_Finder{path = f.unmerged}, {kind = .Script}).ok)
	testing.expect(t, !run_command(New_Shell_Tab{session = state.open_sessions[0].id, cwd = fmt.tprintf("%s/home", f.root)}, {kind = .Script}).ok, "not elsewhere")
}

// A worktree row's New session here, Claude Code picked: a Claude-only session of the project in a checkout
// outside the project folder (kept with its project's rows); elsewhere is refused.
@(test)
wt_claude_session_in_a_worktree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := wt_setup()
	defer wt_teardown(f)
	if !ok do return
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CLAUDE_CMD", "sleep 5")
	defer os.set_env("PI_DESK_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("PI_DESK_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	claude_found = .Yes
	wt_scan_now(f.main)
	p := state.projects[0]
	testing.expect(t, !run_command(New_Claude_Session{project_id = p.id, cwd = fmt.tprintf("%s/home", f.root)}, {kind = .UI}).ok, "not elsewhere")
	r := run_command(New_Claude_Session{project_id = p.id, cwd = f.dirty}, {kind = .UI})
	if !testing.expect(t, r.ok, r.error) do return
	s := find_session(r.created_id)
	if !testing.expect(t, s != nil && s.agent == .Claude) do return
	testing.expect_value(t, s.project_id, p.id)
	testing.expect_value(t, s.tabs[0].cwd, f.dirty)
	// its history entry resumes there
	sid := "b1b1b1b1-0000-4000-8000-000000000001"
	testing.expect(t, run_command(Claude_Session_Report{tab_id = s.tabs[0].id, session_id = sid, source = "startup"}, {kind = .Script}).ok)
	rec, _ := claude_record(sid)
	if testing.expect(t, rec != nil) do testing.expect_value(t, rec.cwd, f.dirty)
	for _, tm in terms do reader_stop_and_close(tm)
}
