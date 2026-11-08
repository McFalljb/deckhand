package main

import "base:runtime"
import "core:c/libc"
import "core:os"
import "core:strings"
import "core:sys/posix"

// Every test process's temp folders go in one folder of its own, removed when the process exits:
// the tests make folders and files in $TMPDIR (deckhand-editor-test-*, pd-home-*, deckhand-hm-*,
// ...) and leave many behind; run outside tests/unit.py (which gives each process a TMPDIR it
// removes), they piled up in the user's $TMPDIR by the hundred thousand. Under `odin test` only:
// the app build compiles this file too.
//
// The folder sits in $TMPDIR when that path is short, else in /tmp: the tests put the control
// socket in it, and a socket's path must fit sun_path (104 bytes). Removed by atexit (the test
// runner ends with os.exit, which skips @(fini)); a crash leaves it.
test_tmp_root: string

@(init)
test_tmpdir_init :: proc "contextless" () {
	test_tmpdir_ensure()
}

// Makes the folder and points TMPDIR at it, once: every @(init) that reads TMPDIR calls it first
// (the order of @(init)s across files is not fixed).
test_tmpdir_ensure :: proc "contextless" () {
	when ODIN_TEST {
		if test_tmp_root != "" do return
		context = runtime.default_context()
		base := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
		if base == "" || len(base) > 40 do base = "/tmp"
		tmpl := strings.clone_to_cstring(strings.concatenate({base, "/dkt-XXXXXX"}, context.temp_allocator))
		made := posix.mkdtemp(([^]u8)(tmpl))
		if made == nil do return // keep the TMPDIR there is
		test_tmp_root = strings.clone(string(made))
		os.set_env("TMPDIR", strings.concatenate({test_tmp_root, "/"}, context.temp_allocator))
		libc.atexit(proc "c" () {
			context = runtime.default_context()
			if test_tmp_root != "" do os.remove_all(test_tmp_root)
		})
	}
}
