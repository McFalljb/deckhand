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
	real, ok := comments_crop_ok(ours)
	testing.expect(t, ok && real != "", "a crop of ours")
	_, ok = comments_crop_ok("")
	testing.expect(t, ok, "no crop")
	// round 2, finding 3: a link is refused even when it points at one of ours
	sib := fmt.tprintf("%s/comments/c-1-2.png", d)
	posix.symlink(strings.clone_to_cstring(ours, context.temp_allocator), strings.clone_to_cstring(sib, context.temp_allocator))
	_, ok = comments_crop_ok(sib)
	testing.expect(t, !ok, "a link to a crop of ours is refused")
	testing.expect(t, os.exists(ours), "and what it points at stays")
	link := fmt.tprintf("%s/comments/c-1-1.png", d)
	posix.symlink(strings.clone_to_cstring(victim, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	for bad in ([]string{victim, "/etc/hosts", fmt.tprintf("%s/comments/../victim.png", d), link, fmt.tprintf("%s/comments/other.png", d)}) {
		_, bad_ok := comments_crop_ok(bad)
		testing.expectf(t, !bad_ok, "%s accepted", bad)
		// refused, and never removed (a failing Comment_Add removes its crop)
		r := run_command(Comment_Add{source = .Browser, tab_id = 999, what = "x", text = "y", crop = bad}, {kind = .Internal})
		testing.expect(t, !r.ok && strings.contains(r.error, "crop"), r.error)
	}
	testing.expect(t, os.exists(victim), "the forged path's file is still there")
}
