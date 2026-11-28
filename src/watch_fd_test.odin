#+build darwin
package main

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"

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
