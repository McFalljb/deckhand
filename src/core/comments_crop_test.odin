package core

// Comment_Add's crop comes from the window: the core reads, copies and removes it, so it must
// be one of the crops Deckhand writes (comments_crop_dir), never a path the sender chose.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"

@(test)
comments_crop_forged_path_refused :: proc(t: ^testing.T) {
	saved := home_root
	d := fmt.tprintf("%s/crop-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), os.get_pid())
	os.make_directory_all(d)
	home_root = d
	defer {
		home_root = saved
		os.remove_all(d)
	}
	victim := fmt.tprintf("%s/victim.png", d)
	_ = os.write_entire_file(victim, transmute([]u8)string("keep me"))
	ours := comments_crop_path()
	defer delete(ours)
	_ = os.write_entire_file(ours, transmute([]u8)string("png"))
	testing.expect(t, comments_crop_ok(ours), "a crop of ours")
	testing.expect(t, comments_crop_ok(""), "no crop")
	link := fmt.tprintf("%s/comments/c-1-1.png", d)
	posix.symlink(strings.clone_to_cstring(victim, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	for bad in ([]string{victim, "/etc/hosts", fmt.tprintf("%s/comments/../victim.png", d), link, fmt.tprintf("%s/comments/other.png", d)}) {
		testing.expectf(t, !comments_crop_ok(bad), "%s accepted", bad)
		// refused, and never removed (a failing Comment_Add removes its crop)
		r := run_command(Comment_Add{source = .Browser, tab_id = 999, what = "x", text = "y", crop = bad}, {kind = .Internal})
		testing.expect(t, !r.ok && strings.contains(r.error, "crop"), r.error)
	}
	testing.expect(t, os.exists(victim), "the forged path's file is still there")
}
