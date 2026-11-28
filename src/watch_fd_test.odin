#+build darwin
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import "core"

// The file watcher on 40 project folders under launchd's soft limit of 256 descriptors: it
// starts, and takes few descriptors (kFSEventStreamCreateFlagWatchRoot took about a dozen per
// folder, one per part of its path, and failed with EMFILE from about 20 folders).
@(test)
watch_many_folders_under_256 :: proc(t: ^testing.T) {
	rl: posix.rlimit
	testing.expect_value(t, posix.getrlimit(.NOFILE, &rl), posix.result.OK)
	orig := rl
	defer posix.setrlimit(.NOFILE, &orig)
	rl.rlim_cur = 256
	testing.expect_value(t, posix.setrlimit(.NOFILE, &rl), posix.result.OK)
	base := test_dir("watch-many")
	deep := fmt.tprintf("%s/a/b/c/d/e/f", base)
	folders := make([]string, 40, context.temp_allocator)
	for i in 0 ..< len(folders) {
		folders[i] = fmt.tprintf("%s/project-%d", deep, i)
		os.make_directory_all(folders[i])
	}
	before := open_fds()
	ok := fs_watch_set(folders, proc "c" (path: cstring, flags: u32) {})
	after := open_fds()
	defer fs_watch_set(nil, nil)
	testing.expect(t, ok, "the watcher started on 40 folders")
	testing.expectf(t, after - before < 40, "descriptors: %d before, %d after", before, after)
}

@(private = "file")
open_fds :: proc() -> int {
	n := 0
	for fd in 0 ..< 1024 do if posix.fcntl(posix.FD(fd), .GETFD) != -1 do n += 1
	return n
}

// The window's soft open-file limit is raised at start: to the hard one, at most FD_SOFT_MAX;
// never lowered.
@(test)
fd_soft_limit_wanted :: proc(t: ^testing.T) {
	testing.expect_value(t, fd_soft_wanted(256, 1 << 62), u64(FD_SOFT_MAX))
	testing.expect_value(t, fd_soft_wanted(256, 4096), u64(4096))
	testing.expect_value(t, fd_soft_wanted(20000, 1 << 62), u64(20000))
}

// Without WatchRoot, a watched folder that is renamed away (or replaced) is still reported, as
// RootChanged, by the stat of each watched folder (watch_roots_check).
@(test)
watch_root_moved_is_reported :: proc(t: ^testing.T) {
	base := test_dir("watch-root")
	dir := fmt.tprintf("%s/proj", base)
	os.make_directory_all(dir)
	saved := watch_folders_for_test(dir)
	defer {
		watch_folders_for_test(saved)
		watch_pending_clear_for_test()
	}
	testing.expect_value(t, len(watched_folders()), 1)
	testing.expect(t, os.rename(dir, fmt.tprintf("%s/proj-moved", base)) == nil)
	watch_roots_check(time.tick_add(time.tick_now(), 3 * WATCH_ROOTS_EVERY))
	paths, flags := watch_pending_for_test()
	found := false
	for p, i in paths do if p == dir && flags[i] & FSE_ROOT_CHANGED != 0 do found = true
	testing.expectf(t, found, "RootChanged for %s: %v", dir, paths)
}

// A watcher that fails waits out its backoff: no retry before retry_at, exactly one after it, and
// a success resets the backoff. Its failures are logged once, then at most once a minute.
@(test)
watch_failure_backs_off :: proc(t: ^testing.T) {
	@(static) sets, fails: int
	sets, fails = 0, 1000
	saved_hook := watch_set_hook
	defer watch_set_hook = saved_hook
	watch_set_hook = proc(folders: []string, cb: proc "c" (path: cstring, flags: u32)) -> bool {
		sets += 1
		return sets > fails
	}
	saved_log := window_log
	window_log = {}
	defer {
		core.log_file_close(&window_log)
		window_log = saved_log
	}
	path := fmt.tprintf("%s/window.log", test_dir("watch-backoff"))
	testing.expect(t, core.log_file_open(&window_log, path))
	dir := test_dir("watch-backoff-proj")
	saved := watch_folders_for_test(dir) // the first try: fails
	defer {
		watch_set_hook = saved_hook
		watch_folders_for_test(saved)
		watch_pending_clear_for_test()
	}
	testing.expect_value(t, sets, 1)
	t0 := time.tick_now()
	for i in 1 ..= 9 do watch_sync(time.tick_add(t0, time.Duration(i) * 100 * time.Millisecond))
	testing.expect_value(t, sets, 1) // within the first second: no retry, however often it syncs
	watch_sync(time.tick_add(t0, WATCH_RETRY_FIRST + 50 * time.Millisecond))
	testing.expect_value(t, sets, 2) // past it: exactly one
	watch_sync(time.tick_add(t0, WATCH_RETRY_FIRST + 60 * time.Millisecond))
	testing.expect_value(t, sets, 2)
	// many more failures within the minute: the log has one line for them, not one each
	at := time.tick_add(t0, 10 * time.Second)
	for _ in 0 ..< 20 {
		watch_sync(at)
		at = time.tick_add(at, watch_retry_for_test() + time.Millisecond)
		if time.tick_diff(t0, at) > 50 * time.Second do break
	}
	b, _ := os.read_entire_file(path, context.temp_allocator)
	lines := strings.count(string(b), "file watcher: FSEvents could not watch")
	testing.expectf(t, lines >= 1 && lines <= 2, "failure lines in a minute: %d\n%s", lines, string(b))
	fails = sets // the next one works
	watch_sync(time.tick_add(at, WATCH_RETRY_MAX + time.Second))
	testing.expect_value(t, watch_retry_for_test(), time.Duration(0))
}
