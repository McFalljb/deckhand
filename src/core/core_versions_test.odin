package core

// Installed cores (core_versions.odin): current and previous switched by rename, and what is
// collected (nothing current, previous or named by a running process's command line).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
core_versions_current_previous_collect :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	vdir := fmt.tprintf("%s/dkcv-%d/core", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	defer remove_tree(vdir[:len(vdir) - len("/core")])
	for k in ([]string{"0.1.7-aaaaaaaaaaaa", "0.1.8-bbbbbbbbbbbb", "dev-cccccccccccc", "5-c0123456789ab", "dev-dddddddddddd"}) {
		testing.expect_value(t, os.make_directory_all(fmt.tprintf("%s/%s", vdir, k)), nil)
	}
	testing.expect_value(t, core_make_current(vdir, "0.1.7-aaaaaaaaaaaa"), "")
	testing.expect_value(t, core_link_read(vdir, CORE_CURRENT), "0.1.7-aaaaaaaaaaaa")
	testing.expect_value(t, core_link_read(vdir, CORE_PREVIOUS), "")
	testing.expect_value(t, core_make_current(vdir, "0.1.8-bbbbbbbbbbbb"), "")
	testing.expect_value(t, core_make_current(vdir, "0.1.8-bbbbbbbbbbbb"), "") // again: previous stays
	testing.expect_value(t, core_link_read(vdir, CORE_CURRENT), "0.1.8-bbbbbbbbbbbb")
	testing.expect_value(t, core_link_read(vdir, CORE_PREVIOUS), "0.1.7-aaaaaaaaaaaa")
	// a holder runs from an old A-style dir; a pi tab has an extension from dev-ccc
	in_use := fmt.tprintf("/x/y\n%s/5-c0123456789ab/Deckhand Core.app/Contents/MacOS/deckhand-core hold --run r\nnode pi -e %s/dev-cccccccccccc/Deckhand Core.app/Contents/Resources/integrations/pi/x.ts\n", vdir, vdir)
	core_collect(vdir, "?") // ps failed: nothing goes
	testing.expect(t, os.is_dir(fmt.tprintf("%s/dev-dddddddddddd", vdir)))
	core_collect(vdir, in_use)
	for k in ([]string{"0.1.7-aaaaaaaaaaaa", "0.1.8-bbbbbbbbbbbb", "dev-cccccccccccc", "5-c0123456789ab"}) {
		testing.expectf(t, os.is_dir(fmt.tprintf("%s/%s", vdir, k)), "%s was collected", k)
	}
	testing.expect(t, !os.is_dir(fmt.tprintf("%s/dev-dddddddddddd", vdir)), "an unused version was kept")
	testing.expect_value(t, core_link_read(vdir, CORE_CURRENT), "0.1.8-bbbbbbbbbbbb") // the links stay
	// a link that is not one path element is not followed
	os.remove(fmt.tprintf("%s/%s", vdir, CORE_PREVIOUS))
	os.symlink("../../etc", fmt.tprintf("%s/%s", vdir, CORE_PREVIOUS))
	testing.expect_value(t, core_link_read(vdir, CORE_PREVIOUS), "")
}

// core_handover is a separate core's, to an installed core only (core_handover.odin).
@(test)
core_handover_refusals :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_root, saved_sep := home_root, core_separate
	defer home_root, core_separate = saved_root, saved_sep
	home_root = fmt.tprintf("%s/dkch-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	core_separate = false
	r := run_command(Core_Handover{to = "current"}, {kind = .UI})
	testing.expect(t, !r.ok && strings.contains(r.error, "only a background core"), r.error)
	core_separate = true
	r = run_command(Core_Handover{to = "current"}, {kind = .UI})
	testing.expect(t, !r.ok && strings.contains(r.error, "no current core"), r.error)
	r = run_command(Core_Handover{to = "/bin/sh"}, {kind = .UI})
	testing.expect(t, !r.ok && strings.contains(r.error, "unknown target"), r.error)
	r = run_command(Core_Handover{to = "current"}, {kind = .Control})
	testing.expect(t, !r.ok, "a control caller handed the core over")
	testing.expect(t, !core_handover_pending())
}

// Use previous core is sticky: the marker holds while current is the build it turned from (a
// reinstall of that build keeps it); making another build current ends it. Nothing else does.
@(test)
core_use_previous_sticks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	data := fmt.tprintf("%s/dkup-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	defer remove_tree(data)
	vdir := core_versions_dir(data)
	for k in ([]string{"0.1.7-aaaaaaaaaaaa", "0.1.8-bbbbbbbbbbbb", "0.1.9-cccccccccccc"}) {
		bin := fmt.tprintf("%s/%s/%s/Contents/MacOS", vdir, k, CORE_APP)
		testing.expect_value(t, os.make_directory_all(bin), nil)
		_ = os.write_entire_file(fmt.tprintf("%s/%s", bin, CORE_SERVE_BIN), transmute([]u8)string("x"))
	}
	testing.expect(t, core_use_previous_set(data) != "", "no current core: nothing to go back from")
	testing.expect_value(t, core_make_current(vdir, "0.1.7-aaaaaaaaaaaa"), "")
	testing.expect(t, core_use_previous_set(data) != "", "no previous core")
	testing.expect_value(t, core_make_current(vdir, "0.1.8-bbbbbbbbbbbb"), "")
	testing.expect_value(t, core_use_previous_serve(data), "")
	testing.expect_value(t, core_use_previous_set(data), "")
	testing.expect(t, strings.contains(core_use_previous_serve(data), "/0.1.7-aaaaaaaaaaaa/"), core_use_previous_serve(data))
	testing.expect_value(t, core_make_current(vdir, "0.1.8-bbbbbbbbbbbb"), "") // the same build again
	testing.expect(t, core_use_previous_serve(data) != "", "a reinstall of the same build ended it")
	testing.expect_value(t, core_make_current(vdir, "0.1.9-cccccccccccc"), "") // an update
	testing.expect_value(t, core_use_previous_serve(data), "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/%s", vdir, CORE_USE_PREVIOUS)))
}
