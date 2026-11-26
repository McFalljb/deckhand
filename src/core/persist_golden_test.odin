package core

// Characterisation of the saved workspace (persist.odin): every file in tests/persist/fixtures/
// (files written by released Deckhands, by this one, and by hand for the keys only older ones
// wrote) is restored into an empty State, then the State (its sections in the window's own
// encoding, state_wire.odin, each one that differs from an empty State's) and what Deckhand
// would save from it (workspace_json) are written to build/persist-golden.txt and compared with
// tests/persist/golden.txt.
//
// The fixtures: released-vX.Y.Z-NN.json are what that release's own unit tests saved
// (workspace_json, run at the tag), current-NN.json what this code's saved before
// tests/persist/ was added, picked so that every key, tab kind and enum value any of them wrote is
// in one; hand-*.json the keys only older releases wrote, every key at once, and wrong types.
//
// A fixture's paths are under $ROOT: the test makes a temp folder, puts it there, makes every
// $ROOT path in the file (a folder, or an empty file when its last part has a dot; not one whose
// path says gone or missing), and writes
// $ROOT back in the output. HOME is $ROOT/home. A difference is a behaviour change; refreshing
// (only for a deliberate change of the file's format or of what a restore does): copy
// build/persist-golden.txt over the golden.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
PG_GOLDEN :: "tests/persist/golden.txt"
@(private = "file")
PG_ACTUAL :: "build/persist-golden.txt"
@(private = "file")
PG_FIXTURES :: "tests/persist/fixtures"

@(private = "file")
pg_root :: proc() -> string {
	return strings.trim_suffix(strings.trim_right(#directory, "/"), "/src/core")
}

// An empty State, as at launch before the restore.
@(private = "file")
pg_reset :: proc() {
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
	held_holder = "" // (allocated by the restore's allocator: left, as State's strings are)
	platform = {quit = proc() {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
}

// Every "$ROOT/..." string in text: made under root (a folder; a file when its last part has a dot).
@(private = "file")
pg_make_paths :: proc(text, root: string) {
	rest := text
	for {
		i := strings.index(rest, "$ROOT/")
		if i < 0 do break
		rest = rest[i:]
		end := strings.index_any(rest, "\"\\")
		if end < 0 do break
		rel := rest[len("$ROOT/"):end]
		rest = rest[end:]
		if rel == "" || strings.contains(rel, "..") || strings.contains(rel, "gone") || strings.contains(rel, "missing") do continue // a path meant to be gone stays gone
		path := strings.concatenate({root, "/", rel}, context.temp_allocator)
		if strings.contains_rune(filepath.base(rel), '.') {
			os.make_directory_all(filepath.dir(path))
			if !os.exists(path) do _ = os.write_entire_file(path, nil)
		} else do os.make_directory_all(path)
	}
}

// A fresh temp folder, resolved (macOS TMPDIR is behind a symlink).
@(private = "file")
pg_tmp :: proc(name: string) -> string {
	d := fmt.tprintf("%s/deckhand-pg-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r), context.temp_allocator) : d
}

// What a fixture restores to, and what is saved from that.
// State's sections (state_wire.odin) that differ from an empty State's (base) are written.
@(private = "file")
pg_case :: proc(b: ^strings.Builder, name, fixture: string, base: map[string]string) {
	pg_reset()
	root := pg_tmp(strings.trim_suffix(name, ".json"))
	home := strings.concatenate({root, "/home"}, context.temp_allocator)
	os.make_directory_all(home)
	saved_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("HOME", home)
	defer os.set_env("HOME", saved_home)
	pg_make_paths(fixture, root)
	text, _ := strings.replace_all(fixture, "$ROOT", root, context.temp_allocator)
	err := workspace_restore(text)
	back :: proc(s, root: string) -> string {
		out, _ := strings.replace_all(s, root, "$ROOT", context.temp_allocator)
		return out
	}
	fmt.sbprintf(b, "== %s\nerror: %s\n", name, err)
	for x in state_sections(&state) do if x[1] != base[x[0]] do fmt.sbprintf(b, "state %s: %s\n", x[0], back(x[1], root))
	fmt.sbprintf(b, "saved: %s", back(workspace_json(), root))
	if !strings.has_suffix(strings.to_string(b^), "\n") do strings.write_byte(b, '\n')
	pg_reset()
	os.remove_all(root)
}

@(test)
persist_golden :: proc(t: ^testing.T) {
	// State's strings outlive this test (the next one's reset leaves or frees them): the heap's
	context.allocator = runtime.heap_allocator()
	root := pg_root()
	dir := fmt.aprintf("%s/%s", root, PG_FIXTURES)
	defer delete(dir)
	entries, derr := os.read_all_directory_by_path(dir, context.allocator)
	if !testing.expectf(t, derr == nil, "%s: %v", dir, derr) do return
	defer os.file_info_slice_delete(entries, context.allocator)
	names := make([dynamic]string)
	defer delete(names)
	for e in entries do if strings.has_suffix(e.name, ".json") do append(&names, e.name)
	slice.sort(names[:])
	testing.expect(t, len(names) > 0, "fixtures found")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	pg_reset()
	base := make(map[string]string)
	defer {
		for k, v in base {
			delete(k)
			delete(v)
		}
		delete(base)
	}
	for x in state_sections(&state) do base[strings.clone(x[0])] = strings.clone(x[1])
	free_all(context.temp_allocator)
	for name in names {
		data, rerr := os.read_entire_file(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)
		if !testing.expectf(t, rerr == nil, "%s: %v", name, rerr) do continue
		pg_case(&b, name, string(data), base)
		free_all(context.temp_allocator)
	}
	got := strings.to_string(b)
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, PG_ACTUAL), transmute([]u8)got)
	want, werr := os.read_entire_file(fmt.tprintf("%s/%s", root, PG_GOLDEN), context.temp_allocator)
	if !testing.expectf(t, werr == nil, "%s missing (%s has the code's)", PG_GOLDEN, PG_ACTUAL) do return
	gl := strings.split_lines(got, context.temp_allocator)
	wl := strings.split_lines(string(want), context.temp_allocator)
	shown := 0
	for i in 0 ..< max(len(gl), len(wl)) {
		g := i < len(gl) ? gl[i] : "<none>"
		w := i < len(wl) ? wl[i] : "<none>"
		if g != w && shown < 10 {
			testing.expectf(t, false, "line %d", i + 1)
			shown += 1
		}
	}
	testing.expectf(t, got == string(want), "%s differs from %s (diff them)", PG_ACTUAL, PG_GOLDEN)
}
