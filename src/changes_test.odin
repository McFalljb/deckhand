package main

// The Changes tab through the command layer (changes.odin): a temp
// repository with a fake HOME (never the user's git config or repos), on a
// branch one commit ahead of main, with every kind of uncommitted change.
// The scan (grouping, counts, staged state, the branch's commits), diff
// reading (headers dropped, untracked files, the line cap, the new file's
// line at a hunk), credential and binary files never read, caller rules,
// stage and unstage, discard's confirmations (two for a file git does not
// have), and commit running the user's hooks while reads never do.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
Ch_Fixture :: struct {
	root, repo, trash: string,
	old_home:          string,
	tab:               u64,
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
put :: proc(path, text: string) {_ = os.write_entire_file(path, transmute([]u8)text)}

@(private = "file")
fixture_trash: string
@(private = "file")
saved_trash_fn: proc(path: string) -> bool

@(private = "file")
ch_setup :: proc() -> (f: Ch_Fixture, ok: bool) {
	context.allocator = runtime.heap_allocator()
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
	made := fmt.tprintf("%s/deckhand-changes-test-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	f.root = fs_real(made, context.allocator)
	ensure(strings.contains(f.root, "/deckhand-changes-test-") && os.is_directory(f.root), "changes tests: no temp folder")
	f.old_home = strings.clone(os.get_env("HOME", context.temp_allocator))
	os.make_directory_all(fmt.tprintf("%s/home", f.root))
	os.set_env("HOME", fmt.tprintf("%s/home", f.root))
	os.set_env("GIT_CONFIG_NOSYSTEM", "1")
	f.trash = fmt.aprintf("%s/trash", f.root)
	os.make_directory_all(f.trash)
	fixture_trash = f.trash
	saved_trash_fn = fs_trash_fn
	fs_trash_fn = proc(path: string) -> bool {
		return os.rename(path, fmt.tprintf("%s/%d-%s", fixture_trash, time.now()._nsec, strings.trim_prefix(path[strings.last_index_byte(path, '/') + 1:], "."))) == nil
	}
	f.repo = fmt.aprintf("%s/proj", f.root)
	os.make_directory_all(f.repo)
	if !git_ok(f.repo, "init", "-q") do return f, false
	r := f.repo
	put(fmt.tprintf("%s/a.txt", r), "one\ntwo\nthree\n")
	put(fmt.tprintf("%s/b.txt", r), "b\n")
	put(fmt.tprintf("%s/gone.txt", r), "gone\n")
	put(fmt.tprintf("%s/old.txt", r), "rename me\nkeep these lines\nso git sees a rename\n")
	put(fmt.tprintf("%s/bin.dat", r), "\x00\x01\x02binary")
	git_ok(r, "add", ".")
	git_ok(r, "commit", "-qm", "init")
	git_ok(r, "branch", "-M", "main")
	// the branch: one commit ahead of main
	git_ok(r, "checkout", "-q", "-b", "feature")
	put(fmt.tprintf("%s/f.txt", r), "feature\n")
	put(fmt.tprintf("%s/a.txt", r), "one\ntwo\nthree\nfour\n")
	git_ok(r, "add", ".")
	git_ok(r, "commit", "-qm", "feature work")
	// uncommitted: modified, staged, deleted, renamed, added, untracked, a credential, binary, a long file
	put(fmt.tprintf("%s/a.txt", r), "one\nTWO\nthree\nfour\n")
	put(fmt.tprintf("%s/b.txt", r), "b changed\n")
	git_ok(r, "add", "b.txt")
	os.remove(fmt.tprintf("%s/gone.txt", r))
	git_ok(r, "mv", "old.txt", "new.txt")
	put(fmt.tprintf("%s/added.txt", r), "added\n")
	git_ok(r, "add", "added.txt")
	put(fmt.tprintf("%s/untracked.txt", r), "u1\nu2\n")
	put(fmt.tprintf("%s/.env", r), "TOKEN=not-a-real-secret-value\n")
	put(fmt.tprintf("%s/bin.dat", r), "\x00\x01\x02binary changed")
	big := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 12000 do fmt.sbprintf(&big, "line %d\n", i)
	put(fmt.tprintf("%s/big.txt", r), strings.to_string(big))
	append(&state.projects, Project{id = new_id(), cwd = strings.clone(f.repo), label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("c-1"), project_id = state.projects[0].id, cwd = strings.clone(f.repo)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return f, true
}

@(private = "file")
ch_teardown :: proc(f: Ch_Fixture) {
	for &s in state.open_sessions do for tab in s.tabs do drop_term(tab.id)
	for r in changes_repos {
		for r.loading {
			inbox_drain()
			time.sleep(5 * time.Millisecond)
		}
	}
	clear(&changes_repos) // (leaked per test: small)
	os.set_env("HOME", f.old_home)
	os.unset_env("GIT_CONFIG_NOSYSTEM")
	fs_trash_fn = saved_trash_fn
	os.remove_all(f.root)
}

// Lets the workers run until the checkout's scan and the tab's diff and
// action are done.
@(private = "file")
settle :: proc(f: Ch_Fixture) -> ^Changes_Repo {
	r := changes_repo(f.repo)
	for _ in 0 ..< 1000 {
		changes_ask(r)
		changes_tick()
		inbox_drain()
		v := changes_view(f.tab)
		if r.loaded && !r.loading && !r.stale && (v == nil || (!v.diff_loading && v.busy == "")) do break
		time.sleep(5 * time.Millisecond)
	}
	return r
}

@(private = "file")
open_tab :: proc(t: ^testing.T, f: ^Ch_Fixture) -> ^Changes_View {
	res := run_command(Changes_Open{}, {kind = .UI})
	testing.expect(t, res.ok, res.error)
	f.tab = res.created_id
	settle(f^)
	return changes_view(f.tab)
}

@(private = "file")
find :: proc(r: ^Changes_Repo, path: string, scope := Change_Scope.Uncommitted) -> Change_File {
	if f := changes_find(r, path, scope); f != nil do return f^
	return {}
}

@(test)
changes_scan_groups_and_counts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	r := changes_repo(f.repo)
	if !testing.expect(t, v != nil && r != nil && r.loaded, "scanned") do return
	testing.expect_value(t, r.branch, "feature")
	testing.expect_value(t, r.default_branch, "main")
	testing.expect_value(t, r.ahead, 1)
	a := find(r, "a.txt")
	testing.expect(t, a.status == 'M' && a.staged == .None && a.unstaged && a.added == 1 && a.removed == 1, fmt.tprint(a))
	b := find(r, "b.txt")
	testing.expect(t, b.status == 'M' && b.staged == .All && !b.unstaged, fmt.tprint(b))
	testing.expect_value(t, find(r, "gone.txt").status, u8('D'))
	n := find(r, "new.txt")
	testing.expect(t, n.status == 'R' && n.old_path == "old.txt" && n.staged == .All, fmt.tprint(n))
	ad := find(r, "added.txt")
	testing.expect(t, ad.status == 'A' && !ad.in_head, fmt.tprint(ad))
	u := find(r, "untracked.txt")
	testing.expect(t, u.status == '?' && u.added == 2 && u.unstaged, fmt.tprint(u))
	testing.expect(t, find(r, ".env").credential, "a .env file is a credential")
	testing.expect(t, find(r, "bin.dat").binary, "binary")
	// the branch's own commit, against main
	testing.expect_value(t, find(r, "f.txt", .Committed).status, u8('A'))
	testing.expect_value(t, find(r, "a.txt", .Committed).added, 1)
	// grouped: uncommitted first, by status M A D R ?, then committed
	order := make([dynamic]string, context.temp_allocator)
	for x in r.files do append(&order, fmt.tprintf("%v:%c:%s", x.scope, x.status, x.path))
	want := []string{"Uncommitted:M:a.txt", "Uncommitted:M:b.txt", "Uncommitted:M:bin.dat", "Uncommitted:A:added.txt", "Uncommitted:D:gone.txt", "Uncommitted:R:new.txt", "Uncommitted:?:.env", "Uncommitted:?:big.txt", "Uncommitted:?:untracked.txt", "Committed:M:a.txt", "Committed:A:f.txt"}
	testing.expect_value(t, strings.join(order[:], " "), strings.join(want, " "))
	rows := changes_rows(r)
	heads := make([dynamic]string, context.temp_allocator)
	for row in rows do if row.head != "" do append(&heads, row.head)
	testing.expect_value(t, strings.join(heads[:], " | "), "Uncommitted · 9 | Modified · 3 | Added · 1 | Deleted · 1 | Renamed · 1 | Untracked · 3 | On feature, not on main · 1 commit | Modified · 1 | Added · 1")
	testing.expect_value(t, changes_count(r), 10) // a.txt once
	// the first file is selected and its diff shown, without git's headers
	testing.expect_value(t, v.sel_path, "a.txt")
	e := editor_of(f.tab)
	text := tb_text(&e.buf, context.temp_allocator)
	testing.expect(t, strings.has_prefix(text, "@@ ") && strings.contains(text, "-two\n+TWO\n") && !strings.contains(text, "diff --git"), text)
	// the state lists the tab with its checkout
	testing.expect(t, strings.contains(state_json(), `"kind":"changes"`), "kind in the state")
}

@(test)
changes_diff_reading :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	e := editor_of(f.tab)
	show :: proc(f: Ch_Fixture, v: ^Changes_View, path: string, scope := Change_Scope.Uncommitted) -> string {
		changes_select(v, path, scope)
		settle(f)
		e := editor_of(f.tab)
		if e.refused != "" do return strings.concatenate({"refused: ", e.refused}, context.temp_allocator)
		return tb_text(&e.buf, context.temp_allocator)
	}
	// credentials and binaries: listed, never read (no worker started)
	gen := v.diff_gen
	testing.expect_value(t, show(f, v, ".env"), "refused: Credentials file: listed, never shown")
	testing.expect(t, v.diff_gen == gen + 1 && !v.diff_loading && v.diff == "", "no diff read for a credential")
	testing.expect_value(t, show(f, v, "bin.dat"), "refused: Binary file: contents not shown")
	// untracked: shown as added
	testing.expect_value(t, show(f, v, "untracked.txt"), "@@ -0,0 +1,2 @@ new file\n+u1\n+u2\n")
	// a rename: both names
	testing.expect(t, strings.contains(show(f, v, "new.txt"), "refused: Renamed from old.txt"), "pure rename")
	// committed: against the merge base
	c := show(f, v, "a.txt", .Committed)
	testing.expect(t, strings.contains(c, "+four") && !strings.contains(c, "TWO"), c)
	// the cap: 5000 lines, then 5000 more
	long := show(f, v, "big.txt")
	testing.expect_value(t, strings.count(long, "\n"), CHANGES_LINES_STEP)
	testing.expect(t, v.diff_lines == 12001, fmt.tprint(v.diff_lines))
	ok_more, _ := changes_tool_state(v, .More)
	testing.expect(t, ok_more, "Show more applies")
	changes_show_more(v)
	testing.expect_value(t, strings.count(tb_text(&e.buf, context.temp_allocator), "\n"), 2 * CHANGES_LINES_STEP)
	// next and previous file
	changes_select(v, "a.txt", .Uncommitted)
	changes_step(v, 1)
	testing.expect_value(t, v.sel_path, "b.txt")
	changes_step(v, -1)
	changes_step(v, -1)
	testing.expect_value(t, v.sel_path, "a.txt")
	// the new file's line at a hunk
	d := "@@ -1,3 +10,4 @@ x\n ctx\n-old\n+new1\n+new2\n ctx\n@@ -40,2 +50,2 @@\n a\n+b\n"
	testing.expect_value(t, diff_new_line(d, 0), 10)
	testing.expect_value(t, diff_new_line(d, 1), 10)
	testing.expect_value(t, diff_new_line(d, 3), 11) // +new1
	testing.expect_value(t, diff_new_line(d, 4), 12)
	testing.expect_value(t, diff_new_line(d, 8), 51)
	testing.expect_value(t, diff_hunk_start("@@ -0,0 +1 @@"), 1)
}

@(test)
changes_caller_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	pitab := state.open_sessions[0].tabs[0].id
	// the user's actions: never scripts, agents or pi tabs
	for c in ([]Caller{{kind = .Script}, {kind = .Control}, {kind = .Panel, tab_id = pitab}}) {
		for cmd in ([]Command{Changes_Stage{tab_id = f.tab, path = "a.txt"}, Changes_Unstage{tab_id = f.tab, path = "b.txt"}, Changes_Discard{tab_id = f.tab, path = "a.txt"}, Changes_Commit{tab_id = f.tab, message = "x"}}) {
			r := run_command(cmd, c)
			testing.expectf(t, !r.ok && r.error == "not allowed for this caller", "%v %v: %s", c.kind, command_type(cmd), r.error)
		}
	}
	testing.expect(t, len(state.pending_confirmations) == 0, "nothing parked")
	// control may list: paths and counts, never diff text
	r := run_command(Changes_List{path = f.repo}, {kind = .Control})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, strings.contains(r.data, `"path":"a.txt"`) && strings.contains(r.data, `"staged":"all"`) && strings.contains(r.data, `"credential":true`), r.data)
	testing.expect(t, !strings.contains(r.data, "TWO") && !strings.contains(r.data, "@@") && !strings.contains(r.data, "not-a-real-secret"), r.data)
	// not outside the projects; never for pi tabs
	testing.expect(t, !run_command(Changes_List{path = f.root}, {kind = .Control}).ok, "outside the projects")
	testing.expect(t, !run_command(Changes_List{path = f.repo}, {kind = .Panel, tab_id = pitab}).ok, "pi tabs may not")
	testing.expect(t, !run_command(Changes_Open{path = f.root}, {kind = .Script}).ok, "not a checkout of a project")
	// the user acts only on listed uncommitted files
	testing.expect_value(t, run_command(Changes_Stage{tab_id = f.tab, path = "../outside"}, {kind = .UI}).error, "not an uncommitted file of this checkout")
	testing.expect_value(t, run_command(Changes_Stage{tab_id = f.tab, path = "f.txt"}, {kind = .UI}).error, "not an uncommitted file of this checkout")
	// a second confirmation never comes first
	testing.expect_value(t, run_command(Changes_Discard{tab_id = f.tab, path = "untracked.txt", second = true}, {kind = .UI}).error, "the second confirmation comes after the first")
	// opening again focuses the same tab
	again := run_command(Changes_Open{}, {kind = .Script})
	testing.expect_value(t, again.created_id, f.tab)
}

@(test)
changes_stage_unstage_discard :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	// reads and our own git commands never run the repository's hooks
	marker := fmt.tprintf("%s/index-hook-ran", f.root)
	hook := fmt.tprintf("%s/.git/hooks/post-index-change", f.repo)
	os.make_directory_all(fmt.tprintf("%s/.git/hooks", f.repo))
	put(hook, fmt.tprintf("#!/bin/sh\ntouch '%s'\n", marker))
	_, _ = run_bounded("", {"chmod", "+x", hook}, GIT_TIMEOUT)
	act :: proc(f: Ch_Fixture, cmd: Command) -> Result {
		r := run_command(cmd, {kind = .UI})
		settle(f)
		return r
	}
	r := act(f, Changes_Stage{tab_id = f.tab, path = "a.txt"})
	testing.expect(t, r.ok && r.pending, r.error)
	repo := changes_repo(f.repo)
	testing.expect_value(t, find(repo, "a.txt").staged, Change_Staged.All)
	act(f, Changes_Unstage{tab_id = f.tab, path = "b.txt"})
	testing.expect_value(t, find(repo, "b.txt").staged, Change_Staged.None)
	testing.expect(t, !os.exists(marker), "no hook ran for stage, unstage or the scans")
	// discard a tracked file: one confirmation, then back to HEAD
	dr := run_command(Changes_Discard{tab_id = f.tab, path = "b.txt"}, {kind = .UI})
	testing.expect(t, !dr.ok && dr.error == "needs_confirmation" && dr.confirm_token != "", dr.error)
	testing.expect(t, strings.contains(dr.confirm_summary, "Discard the uncommitted changes to"), dr.confirm_summary)
	data, _ := os.read_entire_file(fmt.tprintf("%s/b.txt", f.repo), context.temp_allocator)
	testing.expect_value(t, string(data), "b changed\n") // not before the confirmation
	cr := act(f, Changes_Discard{tab_id = f.tab, path = "b.txt", confirm = dr.confirm_token})
	testing.expect(t, cr.ok && cr.pending, cr.error)
	data, _ = os.read_entire_file(fmt.tprintf("%s/b.txt", f.repo), context.temp_allocator)
	testing.expect_value(t, string(data), "b\n")
	testing.expect(t, changes_find(repo, "b.txt", .Uncommitted) == nil, "no longer listed")
	// an untracked file: two confirmations, then the Trash
	u := fmt.tprintf("%s/untracked.txt", f.repo)
	d1 := run_command(Changes_Discard{tab_id = f.tab, path = "untracked.txt"}, {kind = .UI})
	testing.expect_value(t, d1.error, "needs_confirmation")
	d2 := run_command(Changes_Discard{tab_id = f.tab, path = "untracked.txt", confirm = d1.confirm_token}, {kind = .UI})
	testing.expect(t, !d2.ok && d2.error == "needs_confirmation" && d2.confirm_token != "" && d2.confirm_token != d1.confirm_token, d2.error)
	testing.expect(t, strings.contains(d2.confirm_summary, "Really move"), d2.confirm_summary)
	testing.expect(t, os.exists(u), "still there after the first yes")
	testing.expect(t, !run_command(Changes_Discard{tab_id = f.tab, path = "untracked.txt", second = true, confirm = d1.confirm_token}, {kind = .UI}).ok, "the first token is used up")
	act(f, Changes_Discard{tab_id = f.tab, path = "untracked.txt", second = true, confirm = d2.confirm_token})
	testing.expect(t, !os.exists(u), "moved to the Trash")
	infos, _ := os.read_all_directory_by_path(f.trash, context.temp_allocator)
	testing.expect_value(t, len(infos), 1)
	// a staged new file: out of the index, to the Trash
	a1 := run_command(Changes_Discard{tab_id = f.tab, path = "added.txt"}, {kind = .UI})
	a2 := run_command(Changes_Discard{tab_id = f.tab, path = "added.txt", confirm = a1.confirm_token}, {kind = .UI})
	act(f, Changes_Discard{tab_id = f.tab, path = "added.txt", second = true, confirm = a2.confirm_token})
	testing.expect(t, !os.exists(fmt.tprintf("%s/added.txt", f.repo)) && changes_find(repo, "added.txt", .Uncommitted) == nil, "added file discarded")
	testing.expect(t, len(state.pending_confirmations) == 0, "nothing left parked")
}

@(test)
changes_commit_runs_hooks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	// the user's commit runs their hooks, as their terminal would
	git_ok(f.repo, "config", "user.name", "t")
	git_ok(f.repo, "config", "user.email", "t@example.invalid")
	git_ok(f.repo, "config", "commit.gpgsign", "false")
	marker := fmt.tprintf("%s/pre-commit-ran", f.root)
	hooks := fmt.tprintf("%s/.git/hooks", f.repo)
	os.make_directory_all(hooks)
	put(fmt.tprintf("%s/pre-commit", hooks), fmt.tprintf("#!/bin/sh\ntouch '%s'\n", marker))
	put(fmt.tprintf("%s/commit-msg", hooks), "#!/bin/sh\ngrep -q WIP \"$1\" && { echo 'commit-msg: no WIP commits' >&2; exit 1; }\nexit 0\n")
	_, _ = run_bounded("", {"chmod", "+x", fmt.tprintf("%s/pre-commit", hooks), fmt.tprintf("%s/commit-msg", hooks)}, GIT_TIMEOUT)
	// a tool the hook needs is only on the login shell's PATH (as when Deckhand starts from Finder)
	home := os.get_env("HOME", context.temp_allocator)
	os.make_directory_all(fmt.tprintf("%s/bin", home))
	tool_marker := fmt.tprintf("%s/login-path-tool-ran", f.root)
	put(fmt.tprintf("%s/bin/lint-from-login-path", home), fmt.tprintf("#!/bin/sh\ntouch '%s'\n", tool_marker))
	_, _ = run_bounded("", {"chmod", "+x", fmt.tprintf("%s/bin/lint-from-login-path", home)}, GIT_TIMEOUT)
	put(fmt.tprintf("%s/.profile", home), "export PATH=\"$HOME/bin:$PATH\"\n")
	put(fmt.tprintf("%s/pre-commit", hooks), fmt.tprintf("#!/bin/sh\ntouch '%s'\nlint-from-login-path\n", marker))
	old_shell := strings.clone(os.get_env("SHELL", context.temp_allocator), context.temp_allocator)
	os.set_env("SHELL", "/bin/sh")
	defer os.set_env("SHELL", old_shell)
	testing.expect_value(t, run_command(Changes_Commit{tab_id = f.tab, message = "  "}, {kind = .UI}).error, "a commit message is needed")
	// refused by the commit-msg hook: git's words in the tab, nothing committed
	r := run_command(Changes_Commit{tab_id = f.tab, message = "WIP: stuff"}, {kind = .UI})
	testing.expect(t, r.ok && r.pending, r.error)
	settle(f)
	testing.expect(t, v.notice_err && strings.contains(v.notice, "no WIP commits"), v.notice)
	head1, _ := git_run(f.repo, "rev-parse", "HEAD")
	r = run_command(Changes_Commit{tab_id = f.tab, message = "Change b, rename old, add added"}, {kind = .UI})
	settle(f)
	testing.expect(t, !v.notice_err && v.notice == "Committed", v.notice)
	testing.expect(t, os.exists(marker), "pre-commit ran")
	testing.expect(t, os.exists(tool_marker), "the hook found a tool on the login shell's PATH")
	head2, _ := git_run(f.repo, "rev-parse", "HEAD")
	testing.expect(t, head1 != head2, "committed")
	repo := changes_repo(f.repo)
	testing.expect_value(t, repo.ahead, 2)
	testing.expect(t, changes_find(repo, "b.txt", .Uncommitted) == nil && changes_find(repo, "b.txt", .Committed) != nil, "b.txt moved to the branch's commits")
	// nothing staged now: refused
	testing.expect_value(t, run_command(Changes_Commit{tab_id = f.tab, message = "again"}, {kind = .UI}).error, "nothing staged: stage files first")
}

// A change in the checkout reads it again after the debounce, once.
@(test)
changes_refresh_is_debounced :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	r := changes_repo(f.repo)
	runs := r.runs
	for i in 0 ..< 20 do changes_path_changed(fmt.tprintf("%s/a.txt", f.repo))
	changes_path_changed(fmt.tprintf("%s/.git/objects/ab/cdef", f.repo)) // not a status change… but the path test only looks at index/HEAD/refs
	changes_tick()
	testing.expect_value(t, r.runs, runs) // not yet: the debounce
	time.sleep(CHANGES_DEBOUNCE + CHANGES_GAP)
	changes_ask(r)
	changes_tick()
	testing.expect_value(t, r.runs, runs + 1)
	settle(f)
	changes_tick()
	testing.expect_value(t, r.runs, runs + 1) // nothing changed since: no more scans
	// nobody looks: no scan however much changes
	r.asked = {}
	changes_path_changed(fmt.tprintf("%s/a.txt", f.repo))
	time.sleep(CHANGES_DEBOUNCE)
	changes_tick()
	testing.expect_value(t, r.runs, runs + 1)
}

// One path, two entries (`git rm --cached` and the file still there: D and
// ??): rows, selection and actions keep them apart, and Discard never puts
// HEAD's version over the file in the work tree.
@(test)
changes_same_path_two_entries :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	git_ok(f.repo, "rm", "--cached", "-q", "a.txt")
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	r := changes_repo(f.repo)
	testing.expect_value(t, find_status(r, "a.txt", 'D').status, u8('D'))
	testing.expect_value(t, find_status(r, "a.txt", '?').status, u8('?'))
	// selection is per entry
	changes_select(v, "a.txt", .Uncommitted, '?')
	settle(f)
	testing.expect_value(t, v.sel_status, u8('?'))
	text := tb_text(&editor_of(f.tab).buf, context.temp_allocator)
	testing.expect(t, strings.has_prefix(text, "@@ -0,0 +1,4 @@"), text)
	changes_select(v, "a.txt", .Uncommitted, 'D')
	settle(f)
	testing.expect_value(t, v.sel_status, u8('D'))
	// a path alone is ambiguous
	amb := run_command(Changes_Discard{tab_id = f.tab, path = "a.txt"}, {kind = .UI})
	testing.expect(t, !amb.ok && strings.contains(amb.error, "status"), amb.error)
	// restoring the D entry would overwrite the work tree's a.txt: refused, nothing parked
	d := run_command(Changes_Discard{tab_id = f.tab, path = "a.txt", status = "D"}, {kind = .UI})
	testing.expect(t, !d.ok && strings.contains(d.error, "work tree"), d.error)
	testing.expect(t, len(state.pending_confirmations) == 0, "nothing parked")
	data, _ := os.read_entire_file(fmt.tprintf("%s/a.txt", f.repo), context.temp_allocator)
	testing.expect_value(t, string(data), "one\nTWO\nthree\nfour\n")
	// staging the untracked entry adds the file back: one M entry
	s := run_command(Changes_Stage{tab_id = f.tab, path = "a.txt", status = "untracked"}, {kind = .UI})
	testing.expect(t, s.ok, s.error)
	settle(f)
	n := 0
	for x in r.files do if x.path == "a.txt" && x.scope == .Uncommitted do n += 1
	testing.expect_value(t, n, 1)
	testing.expect_value(t, find(r, "a.txt").status, u8('M'))
}

@(private = "file")
find_status :: proc(r: ^Changes_Repo, path: string, status: u8) -> Change_File {
	if f := changes_find(r, path, .Uncommitted, status); f != nil do return f^
	return {}
}

// A credentials file renamed to an innocent name is still never shown, in
// both groups; a nested git repository is not discarded.
@(test)
changes_renamed_credential_and_nested_repo :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	r := f.repo
	// committed: .env.prod on main, renamed on the branch
	git_ok(r, "stash", "-q", "-u")
	git_ok(r, "checkout", "-q", "main")
	put(fmt.tprintf("%s/.env.prod", r), "PROD_TOKEN=not-a-real-secret\n")
	git_ok(r, "add", ".env.prod")
	git_ok(r, "commit", "-qm", "prod env")
	git_ok(r, "checkout", "-q", "feature")
	git_ok(r, "merge", "-q", "--no-edit", "main")
	git_ok(r, "mv", ".env.prod", "plain-prod.txt")
	git_ok(r, "commit", "-qm", "rename it")
	git_ok(r, "stash", "pop", "-q")
	// uncommitted: .env committed, then renamed
	git_ok(r, "add", ".env")
	git_ok(r, "commit", "-qm", "env")
	git_ok(r, "mv", ".env", "plain.txt")
	// a nested repository
	os.make_directory_all(fmt.tprintf("%s/sub", r))
	git_ok(fmt.tprintf("%s/sub", r), "init", "-q")
	put(fmt.tprintf("%s/sub/x.txt", r), "x\n")
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	repo := changes_repo(r)
	u := find(repo, "plain.txt")
	testing.expect(t, u.status == 'R' && u.old_path == ".env" && u.credential, fmt.tprint(u))
	c := find(repo, "plain-prod.txt", .Committed)
	testing.expect(t, c.status == 'R' && c.old_path == ".env.prod" && c.credential, fmt.tprint(c))
	for p in ([]struct {
			path:  string,
			scope: Change_Scope,
		}{{"plain.txt", .Uncommitted}, {"plain-prod.txt", .Committed}}) {
		changes_select(v, p.path, p.scope)
		settle(f)
		e := editor_of(f.tab)
		testing.expectf(t, e.refused != "" && v.diff == "", "%s not shown: %q", p.path, e.refused)
	}
	sub := find(repo, "sub/")
	testing.expect_value(t, sub.status, u8('?'))
	d := run_command(Changes_Discard{tab_id = f.tab, path = "sub/"}, {kind = .UI})
	testing.expect(t, !d.ok && strings.contains(d.error, "nested git repository"), d.error)
	testing.expect(t, os.exists(fmt.tprintf("%s/sub/x.txt", r)), "still there")
}

// A commit that runs past its time: the whole process group (git, the
// hook and the hook's children) is stopped, TERM then KILL; a lock git
// left is reported, never removed.
@(test)
changes_commit_timeout_stops_the_group :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f, ok := ch_setup()
	defer ch_teardown(f)
	if !ok do return
	v := open_tab(t, &f)
	if !testing.expect(t, v != nil, "opened") do return
	git_ok(f.repo, "config", "user.name", "t")
	git_ok(f.repo, "config", "user.email", "t@example.invalid")
	hooks := fmt.tprintf("%s/.git/hooks", f.repo)
	os.make_directory_all(hooks)
	hook := fmt.tprintf("%s/pre-commit", hooks)
	put(hook, fmt.tprintf(`#!/bin/sh
trap '' TERM
echo $$ > '%s/hook.pid'
( trap '' TERM; while :; do sleep 0.05; done ) &
echo $! > '%s/child.pid'
while :; do touch "$GIT_INDEX_FILE.lock" "$(git rev-parse --git-dir)/index.lock" 2>/dev/null; sleep 0.05; done
`, f.root, f.root))
	_, _ = run_bounded("", {"chmod", "+x", hook}, GIT_TIMEOUT)
	old_timeout, old_grace := changes_commit_timeout, changes_kill_grace
	// 4 s: git must reach the hook before the timeout, which takes over 1.5 s on a busy CI runner
	changes_commit_timeout, changes_kill_grace = 4 * time.Second, 300 * time.Millisecond
	defer changes_commit_timeout, changes_kill_grace = old_timeout, old_grace
	start := time.tick_now()
	r := run_command(Changes_Commit{tab_id = f.tab, message = "slow"}, {kind = .UI})
	testing.expect(t, r.ok && r.pending, r.error)
	settle(f)
	testing.expect(t, time.tick_since(start) < 10 * time.Second, "stopped at the timeout")
	testing.expect(t, v.notice_err && strings.contains(v.notice, "timed out"), v.notice)
	lock := fmt.tprintf("%s/.git/index.lock", f.repo)
	testing.expect(t, os.exists(lock), "the lock stays (never removed for the user)")
	testing.expect(t, strings.contains(v.notice, "index.lock") && strings.contains(v.notice, "remove it only if none is"), v.notice)
	time.sleep(300 * time.Millisecond)
	for name in ([]string{"hook.pid", "child.pid"}) {
		data, _ := os.read_entire_file(fmt.tprintf("%s/%s", f.root, name), context.temp_allocator)
		pid, pok := strconv.parse_int(strings.trim_space(string(data)))
		testing.expectf(t, pok && posix.kill(posix.pid_t(pid), posix.Signal(0)) != .OK, "%s (%d) stopped with the group", name, pid)
	}
	os.remove(lock)
}

// Output past a cap stops the reading and the process.
@(test)
changes_run_group_caps_output :: proc(t: ^testing.T) {
	start := time.tick_now()
	out, st := run_group({"/bin/sh", "-c", "yes x"}, 10 * time.Second, cap = 1000)
	testing.expect_value(t, st, Run_Status.Too_Big)
	testing.expect(t, len(out) <= 1000, fmt.tprint(len(out)))
	testing.expect(t, time.tick_since(start) < 3 * time.Second, "stopped early")
	out2, st2 := run_group({"/bin/sh", "-c", "cat; echo err >&2; exit 3"}, 5 * time.Second, input = "in\n", merge_stderr = true)
	testing.expect_value(t, st2, Run_Status.Failed)
	testing.expect_value(t, out2, "in\nerr\n")
	out3, st3 := run_group({"/bin/sh", "-c", "echo ok; echo err >&2"}, 5 * time.Second)
	testing.expect_value(t, st3, Run_Status.Ok)
	testing.expect_value(t, out3, "ok\n")
}
