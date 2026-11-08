package main

// The runtime dir (socket_posix.odin, docs/plans/background-core.md §5.1): <data root>/run,
// private and ours, short enough for sun_path; the control socket core.sock in it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
rt_dir :: proc(name: string) -> string {
	d := fmt.tprintf("%s/rt-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name, time.now()._nsec % 1_000_000_000)
	os.make_directory_all(d)
	return d
}

@(test)
runtime_dir_checks :: proc(t: ^testing.T) {
	d := rt_dir("rt")
	defer os.remove_all(d)
	// fine: made, and made private
	ok_dir := fmt.tprintf("%s/run", d)
	testing.expect_value(t, runtime_dir_prepare(ok_dir, RUNTIME_CORE_NEED), "")
	st: posix.stat_t
	posix.lstat(strings.clone_to_cstring(ok_dir, context.temp_allocator), &st)
	testing.expect_value(t, st.st_mode & (posix.S_IRWXU | posix.S_IRWXG | posix.S_IRWXO), posix.S_IRWXU)
	posix.chmod(strings.clone_to_cstring(ok_dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP})
	testing.expect_value(t, runtime_dir_prepare(ok_dir, RUNTIME_CORE_NEED), "")
	posix.lstat(strings.clone_to_cstring(ok_dir, context.temp_allocator), &st)
	testing.expect(t, st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) == {}, "group bits removed")
	// too long: the holder's socket would not fit, the core's still does
	long := fmt.tprintf("%s/%s", d, strings.repeat("x", SUN_PATH_MAX - len(d) - 1 - RUNTIME_HOLDER_NEED, context.temp_allocator))
	testing.expect_value(t, runtime_dir_prepare(long, RUNTIME_HOLDER_NEED), "")
	longer := fmt.tprintf("%sy", long)
	why := runtime_dir_prepare(longer, RUNTIME_HOLDER_NEED)
	testing.expectf(t, strings.contains(why, "too long"), "too long: %q", why)
	testing.expect(t, !os.exists(longer), "not made")
	// a symlink to a good dir of ours
	link := fmt.tprintf("%s/link", d)
	posix.symlink(strings.clone_to_cstring(ok_dir, context.temp_allocator), strings.clone_to_cstring(link, context.temp_allocator))
	why = runtime_dir_prepare(link, RUNTIME_CORE_NEED)
	testing.expectf(t, strings.contains(why, "symlink"), "symlink: %q", why)
	// a file
	file := fmt.tprintf("%s/file", d)
	_ = os.write_entire_file(file, transmute([]byte)string("x"))
	testing.expect(t, strings.contains(runtime_dir_prepare(file, RUNTIME_CORE_NEED), "not a directory"))
	// not ours (root's)
	why = runtime_dir_prepare("/", RUNTIME_CORE_NEED)
	testing.expectf(t, strings.contains(why, "another user"), "not ours: %q", why)

	// the default: <data root>/run, the control socket core.sock in it (a stale one replaced)
	saved := strings.clone(os.get_env("PI_DESK_RUNTIME_DIR", context.temp_allocator), context.temp_allocator)
	os.unset_env("PI_DESK_RUNTIME_DIR")
	saved_root := home_root
	home_root = fmt.tprintf("%s/data", d)
	defer {
		home_root = saved_root
		if saved != "" do os.set_env("PI_DESK_RUNTIME_DIR", saved)
	}
	rd, rwhy := sock_runtime_dir_why(context.temp_allocator)
	testing.expect_value(t, rwhy, "")
	testing.expect_value(t, rd, fmt.tprintf("%s/data/run", d))
	_ = os.write_entire_file(fmt.tprintf("%s/%s", rd, CORE_SOCK), transmute([]byte)string("stale"))
	if testing.expect(t, socket_start(), "socket_start") {
		testing.expect_value(t, socket_path(), fmt.tprintf("%s/core.sock", rd))
		fd, cok := sock_connect(socket_path())
		testing.expect(t, cok, "connects")
		if cok do sock_close(fd)
		socket_stop(proc() {inbox_drain()})
	}
	home_root = ""
	_, nwhy := sock_runtime_dir_why(context.temp_allocator)
	testing.expect(t, nwhy != "", "no data root, no runtime dir")
	// the old place pi-desk 0.1.x used: never made, only found
	testing.expect_value(t, sock_legacy_runtime_dir(context.temp_allocator), sock_legacy_runtime_dir(context.temp_allocator))
	os.set_env("PI_DESK_RUNTIME_DIR", fmt.tprintf("%s/none", d))
	testing.expect_value(t, sock_legacy_runtime_dir(context.temp_allocator), "")
	testing.expect(t, !os.exists(fmt.tprintf("%s/none", d)))
	os.set_env("PI_DESK_RUNTIME_DIR", ok_dir)
	testing.expect_value(t, sock_legacy_runtime_dir(context.temp_allocator), ok_dir)
	os.unset_env("PI_DESK_RUNTIME_DIR")
}
