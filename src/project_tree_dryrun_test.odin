package main

// A dry run of the Projects tree (project_tidy.odin) against a real store,
// opt-in: DECKHAND_TREE_DRYRUN=<file> names a TSV of store folders made by
// scripts/tree-dryrun.py (store dir, header cwd, newest and oldest mtime in
// ns: only the cwd of each folder's newest session header, nothing else from
// the sessions). Prints the rows with every parent and group row open, and
// checks that every project is listed exactly once, at its own folder (its
// sessions are the ones in its own store dir: none move). Without the
// variable it does nothing. Usage:
//   python3 -I scripts/tree-dryrun.py > /tmp/store.tsv
//   DECKHAND_TREE_DRYRUN=/tmp/store.tsv odin test src -define:ODIN_TEST_THREADS=1 \
//     -define:ODIN_TEST_NAMES=main.tree_dryrun

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(test)
tree_dryrun :: proc(t: ^testing.T) {
	file := os.get_env("DECKHAND_TREE_DRYRUN", context.temp_allocator)
	if file == "" do return
	context.allocator = context.temp_allocator // (a one-off: the state is dropped after)
	data, err := os.read_entire_file(file, context.allocator)
	testing.expect(t, err == nil, "read the TSV")
	if err != nil do return
	state^ = core.State{}
	core.temp_roots_override = nil // the system's temp folders
	core.nesting_off_for_tests = false
	defer {
		core.temp_roots_override = NO_TEMP_ROOTS[:]
		core.nesting_off_for_tests = true
	}
	dirs := make(map[u64]string, context.temp_allocator) // project id -> store dir
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 4 do continue
		newest, _ := strconv.parse_i64(f[2])
		oldest, _ := strconv.parse_i64(f[3])
		cwd := f[1]
		id := core.new_id()
		dirs[id] = f[0]
		append(&state.projects, core.Project{id = id, dir = f[0], cwd = cwd, label = core.short_label(cwd), newest = time.Time{_nsec = newest}, created = time.Time{_nsec = oldest}, missing = !os.exists(cwd), repo = core.is_repo_root(cwd)})
	}
	core.projects_tidy()
	// every parent and group row open
	for p in state.projects {
		append(&state.sidebar.expanded, p.cwd)
		if p.group_dir != "" do append(&state.sidebar.expanded, p.group_dir)
	}

	shown := core.sidebar_projects()
	n_groups, n_nested := 0, 0
	fmt.println("== Projects tree (visible rows, all open; no pins, renames or hidden items applied)")
	for r in shown {
		ind := strings.repeat("  ", r.depth, context.temp_allocator)
		if r.project == nil {
			n_groups += 1
			fmt.printfln("%s[group] %s/ (%d)", ind, core.short_label(r.group), r.kids)
			continue
		}
		if r.depth > 0 do n_nested += 1
		tags := ""
		if r.project.repo do tags = " [repo]"
		if r.kids > 0 do tags = fmt.tprintf("%s [%d folder%s]", tags, r.kids, r.kids == 1 ? "" : "s")
		fmt.printfln("%s%s%s", ind, core.short_label(r.project.cwd), tags)
	}

	// with Show hidden: every project exactly once, at its own folder
	state.sidebar.show_hidden = true
	all := core.sidebar_projects()
	seen := make(map[u64]int, context.temp_allocator)
	hidden := 0
	for r in all {
		if r.project == nil do continue
		seen[r.project.id] += 1
		if r.hidden do hidden += 1
		testing.expect_value(t, r.project.dir, dirs[r.project.id]) // its sessions: its own store dir
	}
	for p in state.projects {
		testing.expectf(t, seen[p.id] == 1, "%s listed %d times", p.cwd, seen[p.id])
	}
	fmt.printfln("== %d store folders -> %d project rows (%d visible, %d hidden as temp/missing), %d group rows, %d nested rows visible", len(state.projects), len(seen), len(seen) - hidden, hidden, n_groups, n_nested)
}
