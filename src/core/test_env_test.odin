package core

// The core's test binary has none of the window's test files: the two @(init)s that set up the
// whole binary's environment (claude_accounts_test.odin's and project_tidy_test.odin's, window
// tests) are here too, so the core's tests run as they did in one binary.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// A fake HOME (made here, empty): no test may list or read the real ~/.claude*, whose projects/
// the scans of Claude transcripts would otherwise look at.
@(init)
core_fake_home_init :: proc "contextless" () {
	when ODIN_TEST {
		test_tmpdir_ensure() // in the process's own temp folder (tmpdir_test.odin)
		context = runtime.default_context()
		d := fmt.aprintf("%s/deckhand-test-home-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
		os.make_directory_all(d)
		buf: [posix.PATH_MAX]u8
		if r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:])); r != nil do d = strings.clone(string(r))
		os.set_env("HOME", d)
		os.unset_env("CLAUDE_CONFIG_DIR")
		os.unset_env("CLAUDE_CODE_PROJECT_DIR_NAME")
	}
}

// Test fixtures live in $TMPDIR, which the tidy list's rule 1 would hide, and in folders nested
// in each other: under `odin test` neither rule applies (the tidy tests set their own).
@(init)
core_tidy_tests_init :: proc "contextless" () {
	when ODIN_TEST {
		temp_roots_override = CORE_NO_TEMP_ROOTS[:]
		nesting_off_for_tests = true
	}
}

@(private = "file")
CORE_NO_TEMP_ROOTS := [1]string{"/pd-tests-no-temp-root"}
