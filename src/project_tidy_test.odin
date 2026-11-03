package main

// The tidy project list (project_tidy.odin): temp folders, subfolders folded
// into their project, missing folders. A fake pi store under a fake HOME.
// Same rules as core_test.odin (one thread, harmless processes).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// Test fixtures live in $TMPDIR, which rule 1 would hide: tests use a temp
// folder of their own (the tidy tests set theirs). Only under `odin test`:
// the app build compiles this file too.
@(init)
tidy_tests_init :: proc "contextless" () {
	when ODIN_TEST {
		temp_roots_override = NO_TEMP_ROOTS[:]
		nesting_off_for_tests = true
	}
}

NO_TEMP_ROOTS := [1]string{"/pd-tests-no-temp-root"}

@(private = "file")
tt_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	persist = {}
	home_root = ""
	temp_roots_override = NO_TEMP_ROOTS[:]
	platform = {quit = proc() {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	return runtime.heap_allocator()
}

// A fresh folder (real path) under $TMPDIR.
@(private = "file")
tt_dir :: proc(tag: string) -> string {
	d := fmt.tprintf("%s/pd-tidy-%s-%d", os.get_env("TMPDIR", context.temp_allocator), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r), context.temp_allocator) : d
}

// One session of `cwd` in the fake store (the folder is made unless `gone`).
@(private = "file")
tt_session :: proc(home, cwd, id: string, minute: int, age: time.Duration, gone := false) {
	if !gone do os.make_directory_all(cwd)
	name, _ := strings.replace_all(strings.trim_prefix(cwd, "/"), "/", "-", context.temp_allocator)
	dir := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
	os.make_directory_all(dir)
	path := fmt.tprintf("%s/2026-10-30T10-%02d-00-000Z_%s.jsonl", dir, minute, id)
	text := fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n"+`{{"type":"message","message":{{"role":"user","content":"%s"}}}}`+"\n", id, cwd, id)
	_ = os.write_entire_file(path, transmute([]u8)text)
	t := time.time_add(time.now(), -age)
	os.change_times(path, t, t)
}

@(private = "file")
tt_git :: proc(cwd: string, file := false) {
	p := fmt.tprintf("%s/.git", cwd)
	if file do _ = os.write_entire_file(p, transmute([]u8)string("gitdir: /elsewhere\n")) // a worktree
	else do os.make_directory_all(p)
}

// The project rows as folder names (base of cwd), in order.
@(private = "file")
tt_rows :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in sidebar_projects() {
		if i > 0 do strings.write_string(&b, ",")
		for _ in 0 ..< r.depth do strings.write_string(&b, "+")
		if r.project == nil do fmt.sbprintf(&b, "%s/(%d)", r.name, r.kids) // a group row
		else do strings.write_string(&b, project_display(r.project^))
	}
	return strings.to_string(b)
}

@(private = "file")
tt_project :: proc(cwd: string) -> ^Project {
	for &p in state.projects do if p.group == .Projects && p.cwd == cwd do return &p
	return nil
}

@(private = "file")
tt_reason :: proc(cwd: string) -> Hide_Reason {
	for r in sidebar_projects() do if r.project != nil && r.project.cwd == cwd do return r.reason
	return .None
}

@(test)
tidy_paths :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	// whole path components
	testing.expect(t, path_within("/a/foo", "/a/foo"))
	testing.expect(t, path_within("/a/foo/b", "/a/foo"))
	testing.expect(t, path_within("/a/foo/b", "/a/foo/"))
	testing.expect(t, !path_within("/a/foobar", "/a/foo"))
	testing.expect(t, !path_within("/a", "/a/foo"))
	testing.expect(t, path_within("/x", "/"))
	testing.expect_value(t, parent_dir("/a/foo/gpt-C"), "/a/foo")
	testing.expect_value(t, parent_dir("/a"), "/")
	// the system's temp folders, $TMPDIR by its real path too
	base := tt_dir("tmpdir")
	real := fmt.tprintf("%s/real-tmp", base)
	link := fmt.tprintf("%s/link-tmp", base)
	os.make_directory_all(real)
	posix.symlink(strings.clone_to_cstring(real, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	old := strings.clone(os.get_env("TMPDIR", context.temp_allocator), context.temp_allocator)
	defer os.set_env("TMPDIR", old)
	os.set_env("TMPDIR", fmt.tprintf("%s/", link))
	temp_roots_override = nil
	defer temp_roots_override = NO_TEMP_ROOTS[:]
	roots := temp_roots()
	testing.expect(t, is_temp_path(fmt.tprintf("%s/run-1", link), roots), "$TMPDIR as set")
	testing.expect(t, is_temp_path(fmt.tprintf("%s/run-1", real), roots), "$TMPDIR's real path")
	testing.expect(t, !is_temp_path(fmt.tprintf("%s/other", base), roots) || strings.has_prefix(base, "/private/var/folders") || strings.has_prefix(base, "/var/folders"), "a sibling only by /var/folders")
	for p in ([]string{"/tmp", "/tmp/x", "/private/tmp/y", "/var/folders/ab/cd/T/z", "/private/var/folders/ab"}) do testing.expectf(t, is_temp_path(p, roots), "temp: %s", p)
	// /tmp is a symlink on macOS: pi records the real path, also temp
	testing.expect(t, is_temp_path(fmt.tprintf("%s/run-1", real_path("/tmp")), roots), "the real /tmp")
	for p in ([]string{"/tmpx", "/Users/me/tmp", "/var/foldersx/a", "/private/var/db"}) do testing.expectf(t, !is_temp_path(p, roots), "not temp: %s", p)
}

// Rules 1 and 3: temp and missing folders are hidden (a reason, not the
// user's hidden list) unless pinned or open; Show hidden and the filter
// show them; a folder that comes back shows again.
@(test)
tidy_hiding :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	home := tt_dir("home")
	os.set_env("HOME", home)
	w := tt_dir("w")
	tmp := fmt.tprintf("%s/tmp", w)
	roots := []string{tmp}
	temp_roots_override = roots
	defer temp_roots_override = NO_TEMP_ROOTS[:]
	tt_session(home, fmt.tprintf("%s/run-xyz", tmp), "t-1", 1, time.Hour)
	tt_session(home, fmt.tprintf("%s/run-abc", tmp), "t-2", 2, time.Hour)
	gone := fmt.tprintf("%s/unplugged", w)
	tt_session(home, gone, "m-1", 1, time.Hour, gone = true)
	tt_session(home, fmt.tprintf("%s/kept", w), "k-1", 1, 2 * time.Hour)
	rescan_now()
	testing.expect_value(t, tt_rows(), "kept")
	testing.expect_value(t, len(state.sidebar.hidden_projects), 0) // never the user's list
	// Show hidden: all, with the reason
	run_command(Set_Filter{show_hidden = true})
	testing.expect_value(t, tt_reason(fmt.tprintf("%s/run-xyz", tmp)), Hide_Reason.Temp)
	testing.expect_value(t, tt_reason(gone), Hide_Reason.Missing)
	testing.expect_value(t, tt_reason(fmt.tprintf("%s/kept", w)), Hide_Reason.None)
	run_command(Set_Hidden{cwd = fmt.tprintf("%s/kept", w), hidden = true})
	testing.expect_value(t, tt_reason(fmt.tprintf("%s/kept", w)), Hide_Reason.User)
	run_command(Set_Hidden{cwd = fmt.tprintf("%s/kept", w), hidden = false})
	run_command(Set_Filter{show_hidden = false})
	// get_state says why
	b := strings.builder_make(context.temp_allocator)
	write_state(&b, state)
	js := strings.to_string(b)
	testing.expect(t, strings.contains(js, `"hidden_reason":"temp"`) && strings.contains(js, `"hidden_reason":"missing"`) && strings.contains(js, `"tidy_projects":true`), js)
	// the filter finds a temp folder and a missing one
	run_command(Set_Filter{text = "run-xyz"})
	testing.expect_value(t, tt_rows(), "run-xyz")
	run_command(Set_Filter{text = "unplugged"})
	testing.expect_value(t, tt_rows(), "unplugged")
	run_command(Set_Filter{text = ""})
	// pinned shows
	run_command(Set_Pinned{cwd = gone, pinned = true}, {kind = .UI})
	testing.expect_value(t, tt_rows(), "unplugged,kept")
	run_command(Set_Pinned{cwd = gone, pinned = false}, {kind = .UI})
	// open shows (and so does waiting work, which is open)
	pt := tt_project(fmt.tprintf("%s/run-abc", tmp))
	r := run_command(Open_Session_Cmd{project_id = pt.id, pi_session_id = "t-2"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, strings.contains(tt_rows(), "run-abc"), tt_rows())
	s := find_session(r.created_id)
	run_command(Pi_Status_Update{tab_id = s.tabs[0].id, agent = .Idle, waiting = true}, {kind = .Script})
	run_command(Set_Hidden{cwd = pt.cwd, hidden = true}, {kind = .Control})
	testing.expect(t, strings.contains(tt_rows(), "run-abc"), "waiting work shows")
	run_command(Set_Hidden{cwd = pt.cwd, hidden = false})
	cr := run_command(Close_Session{session = s.id}, {kind = .Internal})
	testing.expect(t, cr.ok && len(state.open_sessions) == 0, cr.error)
	testing.expect_value(t, tt_rows(), "kept")
	// the folder comes back (a drive mounted again): shown at the next scan
	os.make_directory_all(gone)
	rescan_now()
	testing.expect_value(t, tt_rows(), "unplugged,kept")
	os.remove(gone)
	rescan_now()
	testing.expect_value(t, tt_rows(), "kept")
	// off: all shown
	run_command(Set_Tidy_Projects{on = false}, {kind = .UI})
	testing.expect_value(t, len(sidebar_projects()), 4)
	// saved and restored (default on is not written)
	persist_init(w)
	text := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(text, `"tidy_projects":false`), text)
	run_command(Set_Tidy_Projects{on = true}, {kind = .UI})
	testing.expect(t, !strings.contains(workspace_json(), `"tidy_projects"`), "default not saved")
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect(t, state.settings.tidy_off, "restored off")
}

// The Projects tree (rule 2): every session stays in the folder it was run
// in; repositories are top-level rows, other subfolders nest under the
// nearest listed project, siblings in an unlisted folder share a group row.
@(test)
tidy_tree :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	nesting_off_for_tests = false
	defer nesting_off_for_tests = true
	home := tt_dir("home")
	os.set_env("HOME", home)
	w := fmt.tprintf("%s/w", home) // short labels (~/w/...): the filter also matches paths
	// github/ with two repositories and two plain folders below it
	gh := fmt.tprintf("%s/a/github", w) // (github and projects in different folders: else a group row)
	tt_session(home, gh, "gh-1", 1, 5 * time.Hour)
	for r, i in ([]string{"project1", "project2"}) {
		tt_session(home, fmt.tprintf("%s/%s", gh, r), fmt.tprintf("r%d", i), 2 + i, time.Duration(i + 1) * time.Hour)
		tt_git(fmt.tprintf("%s/%s", gh, r), file = i == 1) // a worktree counts
	}
	tt_session(home, fmt.tprintf("%s/notes", gh), "n-1", 4, 3 * time.Hour)
	tt_session(home, fmt.tprintf("%s/notes/yak", gh), "nd-1", 5, 3 * time.Hour)
	// ~/workspace/projects: listed, repositories in it, and _scratch with 12 plain folders
	ws := fmt.tprintf("%s/b/projects", w)
	tt_session(home, ws, "ws-1", 1, 20 * time.Hour)
	tt_session(home, fmt.tprintf("%s/dataloader", ws), "bt-1", 1, 21 * time.Hour)
	tt_git(fmt.tprintf("%s/dataloader", ws))
	for i in 0 ..< 12 do tt_session(home, fmt.tprintf("%s/_scratch/ev-%02d", ws, i), fmt.tprintf("ev-%d", i), 1, time.Duration(30 + i) * time.Hour)
	tt_session(home, fmt.tprintf("%s/_scratch/ev-03/zulu", ws), "gc-1", 1, 30 * time.Hour)
	// a folder deeper in _scratch whose own folder has no sessions: in the group row (its nearest row), not under projects
	tt_session(home, fmt.tprintf("%s/_scratch/run-x/gpt-check", ws), "gx-1", 1, 45 * time.Hour)
	// home is never a parent nor a group
	tt_session(home, home, "h-1", 1, 50 * time.Hour)
	tt_session(home, fmt.tprintf("%s/scratch", home), "hs-1", 1, 51 * time.Hour)
	tt_session(home, fmt.tprintf("%s/notes2", home), "hn-1", 1, 52 * time.Hour)
	rescan_now()

	pg := tt_project(gh)
	p1, p2 := tt_project(fmt.tprintf("%s/project1", gh)), tt_project(fmt.tprintf("%s/project2", gh))
	notes := tt_project(fmt.tprintf("%s/notes", gh))
	testing.expect(t, p1.parent == 0 && p1.group_dir == "" && p2.parent == 0, "repositories are top-level")
	testing.expect_value(t, notes.parent, pg.id)
	testing.expect_value(t, tt_project(fmt.tprintf("%s/notes/yak", gh)).parent, notes.id)
	for c in ([]string{fmt.tprintf("%s/scratch", home), fmt.tprintf("%s/notes2", home)}) {
		q := tt_project(c)
		testing.expectf(t, q.parent == 0 && q.group_dir == "", "%s: home is never a parent or group", c)
	}
	ev := tt_project(fmt.tprintf("%s/_scratch/ev-03", ws))
	testing.expect_value(t, ev.group_dir, fmt.tprintf("%s/_scratch", ws))
	testing.expect_value(t, tt_project(fmt.tprintf("%s/_scratch/ev-03/zulu", ws)).parent, ev.id)
	gx := tt_project(fmt.tprintf("%s/_scratch/run-x/gpt-check", ws))
	testing.expect_value(t, gx.parent, u64(0))
	testing.expect_value(t, gx.group_dir, fmt.tprintf("%s/_scratch", ws))
	testing.expect_value(t, tt_project(fmt.tprintf("%s/dataloader", ws)).parent, u64(0))
	// collapsed: the _scratch group row is inside projects (its parent project), github with "1 folder", no nested rows shown
	testing.expect_value(t, tt_rows(), fmt.tprintf("project1,project2,github,projects,dataloader,%s,scratch,notes2", filepath.base(home)))

	// every session stays in its own folder
	testing.expect(t, run_command(Select_Project{project_id = pg.id}).ok)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, state.sessions[0].id, "gh-1")
	testing.expect(t, !strings.contains(tt_rows(), "+notes"), "selecting a parent leaves its rows collapsed")
	testing.expect(t, run_command(Select_Project{project_id = tt_project(ws).id}).ok)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, state.sessions[0].id, "ws-1")

	// open the parent row: its folder shows nested; the group opens too
	testing.expect(t, run_command(Set_Row_Expanded{path = gh, expanded = true}, {kind = .UI}).ok)
	testing.expect(t, strings.contains(tt_rows(), "github,+notes,"), tt_rows())
	testing.expect(t, run_command(Set_Row_Expanded{path = fmt.tprintf("%s/_scratch", ws), expanded = true}, {kind = .UI}).ok)
	testing.expect(t, !strings.contains(tt_rows(), "_scratch"), "projects is collapsed: its group row is inside")
	testing.expect(t, run_command(Set_Row_Expanded{path = ws, expanded = true}, {kind = .UI}).ok)
	testing.expect(t, strings.contains(tt_rows(), "projects,+_scratch/(13),++ev-00,++ev-01,++ev-02,++ev-03,++ev-04"), tt_rows())

	// a nested project: its own sessions; resume runs in exactly its folder
	testing.expect(t, run_command(Select_Project{project_id = notes.id}).ok)
	testing.expect_value(t, len(state.sessions), 1)
	out := fmt.aprintf("%s/args", w)
	os.set_env("PI_DESK_CMD", fmt.tprintf(`echo "$* CWD=$(pwd)" > '%s'; exec sleep 30`, out))
	r := run_command(Open_Session_Cmd{project_id = notes.id, pi_session_id = "n-1"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	args := ""
	for _ in 0 ..< 200 {
		if data, err := os.read_entire_file(out, context.temp_allocator); err == nil && len(data) > 0 {
			args = strings.trim_space(string(data))
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(t, strings.has_suffix(args, fmt.tprintf("CWD=%s", notes.cwd)), "pi args: %q", args)
	// the parent's id does not find it: sessions never move
	testing.expect_value(t, run_command(Open_Session_Cmd{project_id = pg.id, pi_session_id = "nd-1"}, {kind = .UI}).error, "no such session in this project")

	// get_state: parent and group_dir
	b := strings.builder_make(context.temp_allocator)
	write_state(&b, state)
	js := strings.to_string(b)
	testing.expect(t, strings.contains(js, fmt.tprintf(`"parent":%d`, pg.id)) && strings.contains(js, fmt.tprintf(`"group_dir":"%s/_scratch"`, ws)) && strings.contains(js, fmt.tprintf(`"group_in":%d`, tt_project(ws).id)), js)

	// fold state is saved per path, and comes back
	persist_init(w)
	text := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(text, fmt.tprintf(`"expanded":["%s","%s/_scratch","%s"]`, gh, ws, ws)), text)
	tt_reset()
	nesting_off_for_tests = false
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect(t, strings.contains(tt_rows(), "github,+notes,") && strings.contains(tt_rows(), "projects,+_scratch/(13),") && strings.contains(tt_rows(), "++ev-11"), tt_rows())
	testing.expect(t, run_command(Select_Project{project_id = tt_project(ws).id}).ok) // (the selected row's parents stay open)
	testing.expect(t, run_command(Set_Row_Expanded{path = gh, expanded = false}, {kind = .UI}).ok)
	testing.expect(t, !strings.contains(tt_rows(), "+notes"), tt_rows())

	// the filter searches nested rows and opens the rows above a match
	run_command(Set_Filter{text = "zulu"})
	testing.expect_value(t, tt_rows(), "projects,+_scratch/(1),++ev-03,+++zulu")
	run_command(Set_Filter{text = "yak"})
	testing.expect_value(t, tt_rows(), "github,+notes,++yak")
	run_command(Set_Filter{text = ""})

	// added by hand or pinned: top-level, also after a restart; a hidden parent is skipped
	notes = tt_project(fmt.tprintf("%s/notes", gh)) // (the restore made a new list)
	testing.expect(t, run_command(Add_Project{cwd = notes.cwd}, {kind = .UI}).ok)
	testing.expect_value(t, tt_project(notes.cwd).parent, u64(0))
	text = strings.clone(workspace_json(), context.temp_allocator)
	tt_reset()
	nesting_off_for_tests = false
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "")
	notes = tt_project(fmt.tprintf("%s/notes", gh))
	testing.expect_value(t, notes.parent, u64(0))
	testing.expect_value(t, tt_project(fmt.tprintf("%s/notes/yak", gh)).parent, notes.id)
	testing.expect(t, run_command(Set_Hidden{cwd = notes.cwd, hidden = true}, {kind = .UI}).ok)
	testing.expect_value(t, tt_project(fmt.tprintf("%s/notes/yak", gh)).parent, tt_project(gh).id) // past the hidden one: the next shown row

	// off: a flat list
	testing.expect(t, run_command(Set_Tidy_Projects{on = false}, {kind = .UI}).ok)
	for p in state.projects do testing.expectf(t, p.parent == 0 && p.group_dir == "", "%s flat", p.cwd)
}

// Review round 1 (project-tree): the pinned divider, group labels and tips,
// hidden folders in the 2+ rule, clicks on rows kept open.
@(test)
tidy_tree_review :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	nesting_off_for_tests = false
	defer nesting_off_for_tests = true
	home := tt_dir("home")
	os.set_env("HOME", home)
	w := fmt.tprintf("%s/w", home)
	app, lib := fmt.tprintf("%s/app", w), fmt.tprintf("%s/lib", w)
	tt_session(home, app, "app-1", 1, 1 * time.Hour)
	tt_session(home, fmt.tprintf("%s/notes", app), "an-1", 2, 2 * time.Hour)
	tt_session(home, lib, "lib-1", 3, 3 * time.Hour)
	tt_session(home, fmt.tprintf("%s/other/zed", home), "z-1", 4, 4 * time.Hour)
	tt_git(fmt.tprintf("%s/other/zed", home))
	// two group rows whose folders share a name
	for r in ([]string{"repoA", "repoB"}) do for c in ([]string{"a", "b"}) {
		tt_session(home, fmt.tprintf("%s/x/%s/docs/%s", home, r, c), fmt.tprintf("%s-%s", r, c), 5, 5 * time.Hour)
	}
	// a folder whose only sibling is missing: no group row
	tt_session(home, fmt.tprintf("%s/y/g/alive", home), "ga-1", 6, 6 * time.Hour)
	tt_session(home, fmt.tprintf("%s/y/g/gone", home), "gg-1", 7, 7 * time.Hour, gone = true)
	rescan_now()

	// 3. hidden folders do not count toward a group row
	testing.expect_value(t, tt_project(fmt.tprintf("%s/y/g/alive", home)).group_dir, "")

	// 2. group rows: a label that tells them apart, the full path as the tip
	rows := tt_rows()
	testing.expectf(t, strings.contains(rows, "repoA/docs/(2)") && strings.contains(rows, "repoB/docs/(2)"), "group labels: %s", rows)
	ga := fmt.tprintf("%s/x/repoA/docs", home)
	tip, _ := hit_tip(Hit_Group(ga))
	testing.expect_value(t, tip, ga)

	// 1. the divider: only between top-level rows (a pinned parent's nested rows are not "unpinned rows")
	testing.expect(t, run_command(Set_Pinned{cwd = app, pinned = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Pinned{cwd = lib, pinned = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Row_Expanded{path = app, expanded = true}, {kind = .UI}).ok)
	prs := sidebar_projects()
	testing.expectf(t, len(prs) > 3 && prs[1].depth == 1 && prs[2].project != nil && prs[2].project.cwd == lib, "rows: %s", tt_rows())
	div := make([dynamic]int, context.temp_allocator)
	for _, i in prs do if pinned_divider_before(prs, i) do append(&div, i)
	testing.expectf(t, len(div) == 1 && div[0] == 3, "divider before rows %v (%s)", div[:], tt_rows())

	// group rows with no listed folder above them stay top-level
	for r in sidebar_projects() do if r.project == nil do testing.expectf(t, r.depth == 0, "%s at depth %d", r.name, r.depth)

	// 4. a row kept open (it holds the selected project) ignores clicks: the saved state stays
	notes := tt_project(fmt.tprintf("%s/notes", app))
	testing.expect(t, run_command(Select_Project{project_id = notes.id}).ok)
	sidebar_click(Hit_Kids(tt_project(app).id), {})
	inbox_drain()
	testing.expect(t, list_index(state.sidebar.expanded[:], app) >= 0, "saved open state kept")
	// a group row kept open by the filter: the same
	testing.expect(t, run_command(Set_Row_Expanded{path = ga, expanded = true}, {kind = .UI}).ok)
	run_command(Set_Filter{text = "repoA"})
	sidebar_click(Hit_Group(ga), {})
	inbox_drain()
	run_command(Set_Filter{text = ""})
	testing.expect(t, list_index(state.sidebar.expanded[:], ga) >= 0, "a click on a row the filter keeps open changes nothing")

	// the divider with a pinned parent holding a group row: still only before the first unpinned top-level row
	repoA := fmt.tprintf("%s/x/repoA", home)
	tt_session(home, repoA, "ra-1", 8, 8 * time.Hour)
	rescan_now()
	testing.expect(t, run_command(Set_Pinned{cwd = repoA, pinned = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Row_Expanded{path = repoA, expanded = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Row_Expanded{path = ga, expanded = true}, {kind = .UI}).ok)
	prs = sidebar_projects()
	rows = tt_rows()
	testing.expectf(t, strings.contains(rows, "repoA,+repoA/docs/(2),++"), "group under its pinned parent: %s", rows)
	clear(&div)
	for _, i in prs do if pinned_divider_before(prs, i) do append(&div, i)
	first := -1
	for r, i in prs do if r.depth == 0 && r.pin < 0 {first = i; break}
	testing.expectf(t, len(div) == 1 && div[0] == first, "divider before rows %v, first unpinned top-level row %d (%s)", div[:], first, rows)
}

// Review round 2 (project-tree): a group inside another group's folder,
// one hidden-parent rule for folders and groups, "N folders" counts what a
// row holds, a hidden member joins an existing group.
@(test)
tidy_tree_review2 :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	nesting_off_for_tests = false
	defer nesting_off_for_tests = true
	home := tt_dir("home")
	os.set_env("HOME", home)
	w := fmt.tprintf("%s/w", home)
	tt_session(home, w, "w-1", 1, 1 * time.Hour)
	ev := fmt.tprintf("%s/_scratch", w)
	tt_session(home, fmt.tprintf("%s/a", ev), "a", 2, 2 * time.Hour)
	tt_session(home, fmt.tprintf("%s/b", ev), "b", 3, 3 * time.Hour)
	tt_session(home, fmt.tprintf("%s/c", ev), "c", 4, 10 * time.Hour)
	run1 := fmt.tprintf("%s/run-1", ev) // never run in
	tt_session(home, fmt.tprintf("%s/gpt", run1), "g", 4, 4 * time.Hour)
	tt_session(home, fmt.tprintf("%s/claude", run1), "cl", 5, 5 * time.Hour)
	h := fmt.tprintf("%s/h", w) // hidden by the user: a single folder and a group inside
	tt_session(home, h, "h", 6, 6 * time.Hour)
	tt_session(home, fmt.tprintf("%s/single", h), "s", 7, 7 * time.Hour)
	tt_session(home, fmt.tprintf("%s/grp/x", h), "x", 8, 8 * time.Hour)
	tt_session(home, fmt.tprintf("%s/grp/y", h), "y", 9, 9 * time.Hour)
	rescan_now()
	testing.expect(t, run_command(Set_Hidden{cwd = h, hidden = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Hidden{cwd = fmt.tprintf("%s/c", ev), hidden = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Row_Expanded{path = w, expanded = true}, {kind = .UI}).ok)
	testing.expect(t, run_command(Set_Row_Expanded{path = ev, expanded = true}, {kind = .UI}).ok)
	wp := tt_project(w)

	// 4. a hidden member still joins a group that exists (a and b are shown)
	testing.expect_value(t, tt_project(fmt.tprintf("%s/c", ev)).group_dir, ev)

	// 1. the run-1 group is inside the _scratch group, not beside it
	g := tt_project(fmt.tprintf("%s/gpt", run1))
	testing.expect_value(t, g.group_dir, run1)
	testing.expect_value(t, g.group_up, ev)
	testing.expect_value(t, g.group_in, u64(0))
	b := strings.builder_make(context.temp_allocator)
	write_state(&b, state)
	testing.expect(t, strings.contains(strings.to_string(b), fmt.tprintf(`"group_up":"%s"`, ev)), "get_state: group_up")
	rows := tt_rows()
	testing.expectf(t, strings.has_prefix(rows, "w,+_scratch/(4),") && strings.contains(rows, ",++run-1/(2),"), "rows: %s", rows)

	// 2. one rule past a hidden parent: the single folder and the group both go under w
	testing.expect_value(t, tt_project(fmt.tprintf("%s/single", h)).parent, wp.id)
	testing.expect_value(t, tt_project(fmt.tprintf("%s/grp/x", h)).group_in, wp.id)

	// 3. "N folders": the folders a row holds, a group's members counted (not the group as one)
	for r in sidebar_projects() {
		if r.project != nil && r.project.cwd == w do testing.expectf(t, r.kids == 7, "w holds %d (a, b, gpt, claude, single, x, y)", r.kids)
	}
}

// Nesting follows what is shown: a temp parent that opens takes its open
// temp child under it; when it closes (hidden again), the child goes back to
// the top level, not left under a hidden row that shows only to hold it.
@(test)
tidy_tree_follows_open :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	nesting_off_for_tests = false
	defer nesting_off_for_tests = true
	home := tt_dir("home")
	os.set_env("HOME", home)
	w := tt_dir("w")
	tmp := fmt.tprintf("%s/tmp", w)
	temp_roots_override = []string{tmp}
	defer temp_roots_override = NO_TEMP_ROOTS[:]
	pd, cd := fmt.tprintf("%s/run-x", tmp), fmt.tprintf("%s/run-x/sub", tmp)
	tt_session(home, pd, "p-1", 1, time.Hour)
	tt_session(home, cd, "c-1", 2, time.Hour)
	tt_session(home, fmt.tprintf("%s/kept", w), "k-1", 1, 2 * time.Hour)
	rescan_now()
	testing.expect_value(t, tt_rows(), "kept")
	cr := run_command(Open_Session_Cmd{project_id = tt_project(cd).id, pi_session_id = "c-1"}, {kind = .UI})
	testing.expect(t, cr.ok, cr.error)
	testing.expect_value(t, tt_project(cd).parent, u64(0))
	pr := run_command(Open_Session_Cmd{project_id = tt_project(pd).id, pi_session_id = "p-1"}, {kind = .UI})
	testing.expect(t, pr.ok, pr.error)
	testing.expect_value(t, tt_project(cd).parent, tt_project(pd).id) // the parent shows: the child nests
	r := run_command(Close_Session{session = pr.created_id}, {kind = .Internal})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, tt_project(cd).parent, u64(0)) // hidden again: back to the top level
	testing.expect(t, !strings.contains(tt_rows(), "run-x,"), tt_rows())
	testing.expect(t, strings.contains(tt_rows(), "sub"), tt_rows())
	run_command(Close_Session{session = cr.created_id}, {kind = .Internal})
	for _, x in terms do reader_stop_and_close(x)
}

// PI_DESK_TEMP_ROOTS names the temp folders only in script mode (autotest
// running), and an empty piece is no root (it would make every path temp).
@(test)
tidy_temp_roots_env :: proc(t: ^testing.T) {
	context.allocator = tt_reset()
	temp_roots_override = nil
	defer temp_roots_override = NO_TEMP_ROOTS[:]
	old_script := strings.clone(os.get_env("PI_DESK_SCRIPT", context.temp_allocator), context.temp_allocator)
	defer os.set_env("PI_DESK_SCRIPT", old_script)
	defer os.unset_env("PI_DESK_TEMP_ROOTS")
	was := autotest.active
	defer autotest.active = was
	os.set_env("PI_DESK_TEMP_ROOTS", "/pd-a::/pd-b:")
	// not running a script: the env var (even with PI_DESK_SCRIPT set) is ignored
	autotest.active = false
	os.set_env("PI_DESK_SCRIPT", "x.txt")
	testing.expect(t, slice.contains(temp_roots(), "/tmp"), "the system's roots")
	// running a script: just the named ones, no empty piece
	autotest.active = true
	roots := temp_roots()
	testing.expectf(t, len(roots) == 2 && roots[0] == "/pd-a" && roots[1] == "/pd-b", "roots %v", roots)
	testing.expect(t, !is_temp_path("/Users/x/proj", roots), "an empty piece is no root")
}
