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
