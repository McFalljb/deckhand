package main

// The window's soft RLIMIT_NOFILE. launchd starts an app with a soft limit of 256, and the window
// holds Chromium's sockets and pipes, each tab's files, the core's link, git workers and the file
// watcher: a burst (a watcher that failed while it held descriptors) could leave none for a
// reconnect's socket or the core's signature check. Raised at start, as the session holder raises
// its own (src/holder raise_fd_limit): to the hard limit, at most FD_SOFT_MAX (OPEN_MAX, what
// setrlimit takes on macOS).

import "core:fmt"
import "core:sys/posix"

FD_SOFT_MAX :: 10240

// The soft limit to ask for, given the current soft and hard limits (no change: cur).
fd_soft_wanted :: proc(cur, max: u64) -> u64 {
	want := min(max, FD_SOFT_MAX)
	return cur >= want ? cur : want
}

// Main thread, first thing in main().
fd_limit_raise :: proc() {
	rl: posix.rlimit
	if posix.getrlimit(.NOFILE, &rl) != .OK do return
	want := fd_soft_wanted(u64(rl.rlim_cur), u64(rl.rlim_max))
	if want == u64(rl.rlim_cur) do return
	rl.rlim_cur = type_of(rl.rlim_cur)(want)
	if posix.setrlimit(.NOFILE, &rl) != .OK do fmt.eprintln("Deckhand: cannot raise the open-file limit to", want)
}
