package main

// The window reads only its replica and its own copies (docs/plans/background-core.md §10.3,
// M3-F2): no window file reaches the core's State, its terminals or its hook table directly, so
// the window can move to its own process (M4-C) as a transport swap. A grep over the window's
// files; the few places allowed say why.

import "core:os"
import "core:strings"
import "core:testing"

@(test)
window_reads_only_its_replica :: proc(t: ^testing.T) {
	// what reaches the core's memory instead of the replica
	needles := []string{"core.find_tab(", "core.term_of(", "core.terms", "core.state.", "&core.state", "core.window."}
	// file, needle, how many: what may stay
	allowed := []struct {
		file, needle: string,
		n:            int,
	} {
		{"main.odin", "core.state.", 1}, // init: the core's own setting, before the window attaches
		{"state_view.odin", "&core.state", 1}, // `state` before the attach (the window's unit tests)
		{"term_view_stream.odin", "core.term_of(", 1}, // test mode's screen-hash check against the core's terminal
		{"client.odin", "core.window.", 2}, // the unit tests' host link sets the test_facts hook
	}
	files, err := os.read_all_directory_by_path("src", context.temp_allocator)
	if !testing.expect(t, err == nil, "src") do return
	checked := 0
	for f in files {
		if !strings.has_suffix(f.name, ".odin") || strings.has_suffix(f.name, "_test.odin") do continue
		if strings.has_prefix(f.name, "autotest") do continue // test mode compares the two sides
		data, rerr := os.read_entire_file(f.fullpath, context.temp_allocator)
		if !testing.expect(t, rerr == nil, f.name) do continue
		checked += 1
		lines := strings.split_lines(string(data), context.temp_allocator)
		for n in needles {
			count := 0
			for line in lines {
				code := line
				if i := strings.index(code, "//"); i >= 0 do code = code[:i] // not what a comment says
				count += strings.count(code, n)
			}
			want := 0
			for a in allowed do if a.file == f.name && a.needle == n do want = a.n
			testing.expectf(t, count == want, "%s: %d × %s (allowed %d)", f.name, count, n, want)
		}
	}
	testing.expectf(t, checked > 50, "%d window files", checked)
}
