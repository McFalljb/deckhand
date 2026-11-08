package main

// A tidy project list (Settings.tidy_off turns all three rules off; on by
// default). Runs after every scan and when pins, hidden items, hand-added
// projects or the setting change. Nothing on disk is touched; the user's hidden list
// is never written.
//
// Also when a project is shown or hidden otherwise (a session opened or
// closed): nesting reads what is shown.
//
// 1. Temp folders: a project whose cwd is in a temp folder ($TMPDIR and its
//    real path, /tmp, /private/tmp, /var/folders, /private/var/folders) is
//    hidden ("temp") unless pinned, open or waiting. Show hidden lists it;
//    filter text that matches it finds it (a missing one too); so does
//    the palette.
// 2. Rows nest; sessions never move. Every session belongs to exactly the
//    folder it was run in: a project row lists only its own sessions.
//    - A git repository's root or worktree (.git folder or file), a project
//      added by hand and a pinned one are always top-level rows.
//    - Group rows: two or more other listed folders, not hidden, whose folder is not a
//      listed project (and not home or /) show inside a group row for that
//      folder (~/code/projects/_scratch: its name, a count, no
//      sessions).
//    - One rule places every other row, folder or group: under the row
//      above it (whole path components: /a/foo is not in /a/foobar), the
//      deepest of a listed project that is shown (hidden ones are skipped;
//      never home or /) and a group row's folder; top-level with none.
//      A folder: nested under the project (`parent`) or in the group
//      (`group_dir`; _scratch/run-1/gpt when run-1 has no sessions). A
//      group row: under the project (`group_in`: _scratch under
//      ~/code/projects when that is listed) or inside the other group
//      row (`group_up`: _scratch/run-1 inside _scratch).
//    Parent and group rows start collapsed; their fold state is saved per
//    path (Sidebar.expanded). The filter expands rows to show its matches;
//    the selected project's row is always reachable.
// 3. Missing folders: a project whose folder is gone is hidden ("folder
//    missing") unless pinned, open or waiting; back when the folder is
//    (the next scan sees it). A derived reason, never the user's hidden.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Why a project row is hidden (Show hidden shows it with this tag).
Hide_Reason :: enum {
	None,
	User, // hidden by the user (state.sidebar.hidden_projects)
	Temp, // rule 1
	Missing, // rule 3
}

HIDE_REASON_NAMES := [Hide_Reason]string {
	.None    = "",
	.User    = "user",
	.Temp    = "temp",
	.Missing = "missing",
}

// The row tag of a hidden project.
HIDE_REASON_TAGS := [Hide_Reason]string {
	.None    = "",
	.User    = "hidden",
	.Temp    = "temp",
	.Missing = "folder missing",
}

// Tests of other things keep a flat list (their fixtures are sibling
// folders in $TMPDIR, which would make a group row); the tree tests clear it.
nesting_off_for_tests: bool

// Tests set this instead of the system's temp folders (their fixtures live
// in $TMPDIR); nil = the system's.
temp_roots_override: []string

// The temp folders (temp allocator).
temp_roots :: proc() -> []string {
	if temp_roots_override != nil do return temp_roots_override
	// Scenes (a script running) whose fake HOME sits in /tmp, for a short
	// path, name the temp folders instead: DECKHAND_TEMP_ROOTS, ':'-separated
	// (empty pieces dropped: "" would make every path temp).
	if autotest.active {
		named := make([dynamic]string, context.temp_allocator)
		for r in strings.split(hook_env(.Temp_Roots), ":", context.temp_allocator) do if r != "" do append(&named, r)
		if len(named) > 0 do return named[:]
	}
	out := make([dynamic]string, context.temp_allocator)
	if t := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"); t != "" {
		append(&out, t)
		if r := real_path(t); r != t do append(&out, r)
	}
	append(&out, "/tmp", "/private/tmp", "/var/folders", "/private/var/folders")
	return out[:]
}

// Whether path is root or inside it, by whole path components.
path_within :: proc(path, root: string) -> bool {
	r := strings.trim_right(root, "/")
	if r == "" do return strings.has_prefix(path, "/") // root is "/"
	if !strings.has_prefix(path, r) do return false
	return len(path) == len(r) || path[len(r)] == '/'
}

is_temp_path :: proc(path: string, roots: []string) -> bool {
	for r in roots do if path_within(path, r) do return true
	return false
}

// A repository's root or a worktree (.git is a folder or a file).
is_repo_root :: proc(cwd: string) -> bool {
	p, _ := filepath.join({cwd, ".git"}, context.temp_allocator)
	return os.exists(p)
}

// Whether a session of the project is open.
project_open :: proc(id: u64) -> bool {
	for s in state.open_sessions do if !s.home && s.project_id == id do return true
	return false
}

// Why a project row is hidden; .None = shown. Pinned or open beat the
// automatic reasons (waiting work: sidebar_projects).
project_hide_reason :: proc(p: Project) -> Hide_Reason {
	if project_hidden(p) do return .User
	if state.settings.tidy_off || !(p.temp || p.missing) do return .None
	if project_pinned(p) >= 0 || project_open(p.id) do return .None
	return p.temp ? .Temp : .Missing
}

// The folder holding path: a slice of it ("/a/b" -> "/a"; "/a" -> "/").
parent_dir :: proc(path: string) -> string {
	p := strings.trim_right(path, "/")
	i := strings.last_index_byte(p, '/')
	if i <= 0 do return "/"
	return p[:i]
}

// Which projects are shown when the rules last ran (tidy_shown_sig): nesting
// skips hidden rows, so a project shown or hidden by something else (a
// session opened or closed: run_command) runs them again.
tidy_shown: u64

// A hash of the projects' ids and whether each is shown.
tidy_shown_sig :: proc() -> u64 {
	h: u64 = 0xcbf29ce484222325
	for p in state.projects {
		if p.group != .Projects do continue
		h = (h ~ (p.id << 1 | u64(project_hide_reason(p) == .None))) * 0x100000001b3
	}
	return h
}

// Applies the rules to state.projects: temp, parent, group_dir (see the
// top of the file). The selected project's sessions are not touched: every
// project lists only its own.
projects_tidy :: proc() {
	on := !state.settings.tidy_off
	roots := temp_roots()
	for &p in state.projects {
		p.parent, p.group_dir, p.group_in, p.group_up = 0, "", 0, ""
		p.temp = on && p.group == .Projects && is_temp_path(p.cwd, roots)
	}
	tidy_shown = tidy_shown_sig()
	if !on || nesting_off_for_tests do return
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	home_real := home != "" ? real_path(home) : ""
	never :: proc(dir, home, home_real: string) -> bool {
		d := strings.trim_right(dir, "/")
		return d == "" || d == home || d == home_real
	}
	// a nestable row: not a repository, not added by hand, not pinned
	nestable :: proc(p: Project) -> bool {
		return p.group == .Projects && !p.repo && !p.by_hand && project_pinned(p) < 0
	}
	listed :: proc(dir: string) -> bool {
		for q in state.projects do if q.group == .Projects && q.cwd == dir do return true
		return false
	}
	// group rows first: 2+ nestable listed folders that are not hidden, in a
	// folder that is no project (a hidden one joins a group that exists)
	groups := make([dynamic]string, context.temp_allocator)
	for &p in state.projects {
		if !nestable(p) do continue
		d := parent_dir(p.cwd)
		if never(d, home, home_real) || listed(d) do continue
		n := 0
		for q in state.projects do if nestable(q) && parent_dir(q.cwd) == d && project_hide_reason(q) == .None do n += 1 // shown ones only
		if n < 2 do continue
		p.group_dir = d
		if !slice.contains(groups[:], d) do append(&groups, d)
	}
	// the row above a path: the deepest of a listed project that is shown
	// (hidden ones are skipped; never home or /) and a group row's folder;
	// (-1, "") = none (top level)
	above :: proc(path: string, groups: []string, home, home_real: string) -> (proj: int, group: string) {
		proj = -1
		for q, j in state.projects {
			if q.group != .Projects || q.cwd == path || !path_within(path, q.cwd) || never(q.cwd, home, home_real) || project_hide_reason(q) != .None do continue
			if proj < 0 || len(q.cwd) > len(state.projects[proj].cwd) do proj = j
		}
		for g in groups do if g != path && path_within(path, g) && len(g) > len(group) do group = g
		if group != "" && proj >= 0 && len(state.projects[proj].cwd) > len(group) do group = ""
		if group != "" do proj = -1
		return
	}
	// every other nestable folder: under the row above it (in a group: a
	// folder of the group's that has no row, _scratch/run-1/gpt)
	for &p in state.projects {
		if !nestable(p) || p.group_dir != "" do continue
		j, group := above(p.cwd, groups[:], home, home_real)
		if group != "" do p.group_dir = group
		else if j >= 0 do p.parent = state.projects[j].id
	}
	// a group row: under the row above its folder (a project, or another
	// group row: _scratch/run-1 inside _scratch); its members carry it
	for d in groups {
		j, group := above(d, groups[:], home, home_real)
		for &p in state.projects do if p.group_dir == d {
			p.group_up = group
			p.group_in = j >= 0 ? state.projects[j].id : 0
		}
	}
}
