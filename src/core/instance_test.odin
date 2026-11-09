package core

// One Deckhand per data dir (instance.odin): the lock, never inherited by what Deckhand starts,
// and a running pi-desk 0.1.x (which takes no lock) found by its control socket.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
inst_dir :: proc(name: string) -> string {
	d := fmt.tprintf("%s/build/test-instance-%s-%d", os.get_working_directory(context.temp_allocator) or_else ".", name, posix.getpid())
	os.remove_all(d)
	os.make_directory_all(d)
	return d
}

@(test)
instance_lock_excludes :: proc(t: ^testing.T) {
	d := inst_dir("excl")
	defer os.remove_all(d)
	c1, i1, r1 := instance_locks_take(d)
	testing.expect_value(t, r1, Instance_Refusal.None)
	_, _, r2 := instance_locks_take(d)
	testing.expect_value(t, r2, Instance_Refusal.Running) // core.lock: one app per data dir
	instance_lock_release(c1)
	instance_lock_release(i1)
	c3, i3, r3 := instance_locks_take(d)
	testing.expect_value(t, r3, Instance_Refusal.None) // free again once released
	instance_lock_release(c3)
	instance_lock_release(i3)
}

// The downgrade rule (§7.6): instance.lock is SH for this app and for holders; a Deckhand from
// before M1 takes it EX. So an EX taker fails while an SH holder lives (another fd, or a child
// that inherited one: a holder outliving the app), SH works beside SH, and while an older app
// holds EX this app is refused with its own message.
@(test)
instance_lock_shared_rule :: proc(t: ^testing.T) {
	d := inst_dir("shared")
	defer os.remove_all(d)
	sh1, ok1 := instance_lock_take(d, INSTANCE_LOCK_FILE, LOCK_SH)
	testing.expect(t, ok1, "SH")
	sh2, ok2 := instance_lock_take(d, INSTANCE_LOCK_FILE, LOCK_SH)
	testing.expect(t, ok2, "SH beside SH")
	_, ex_ok := instance_lock_take(d, INSTANCE_LOCK_FILE, LOCK_EX)
	testing.expect(t, !ex_ok, "an older app's EX fails while SH is held")
	instance_lock_release(sh2)
	// a child holds it: this fd without close-on-exec, then ours closed (the open file
	// description, and its lock, lives on in the child)
	posix.fcntl(sh1, .SETFD, 0)
	argv := []cstring{"/bin/sleep", "5", nil}
	pid: posix.pid_t
	spawned := posix.posix_spawn(&pid, "/bin/sleep", nil, nil, raw_data(argv), nil) == .NONE
	testing.expect(t, spawned, "a child runs")
	instance_lock_release(sh1)
	_, ex2 := instance_lock_take(d, INSTANCE_LOCK_FILE, LOCK_EX)
	testing.expect(t, !ex2, "EX fails while a child holds SH")
	c, i, r := instance_locks_take(d)
	testing.expect_value(t, r, Instance_Refusal.None) // the app starts beside a holder
	instance_lock_release(c)
	instance_lock_release(i)
	if spawned {
		posix.kill(pid, .SIGKILL)
		st: i32
		posix.waitpid(pid, &st, {})
	}
	// an older app holds EX: this app is refused, and says why
	ex, ex3 := instance_lock_take(d, INSTANCE_LOCK_FILE, LOCK_EX)
	testing.expect(t, ex3, "EX once nothing holds SH")
	c4, i4, r4 := instance_locks_take(d)
	testing.expect_value(t, r4, Instance_Refusal.Older)
	testing.expect_value(t, c4, posix.FD(-1))
	testing.expect_value(t, i4, posix.FD(-1))
	testing.expect_value(t, instance_message(0, r4), "An older Deckhand is running with the same data. Quit it first.")
	// and core.lock was let go with it: the next try, once the older app quit, succeeds
	instance_lock_release(ex)
	c5, i5, r5 := instance_locks_take(d)
	testing.expect_value(t, r5, Instance_Refusal.None)
	instance_lock_release(c5)
	instance_lock_release(i5)
}

// A child started with plain posix_spawn (every open fd without close-on-exec passes) must not
// keep the lock after Deckhand lets go: pi, shells, jobs and the update relaunch's sh outlive it.
@(test)
instance_lock_not_inherited :: proc(t: ^testing.T) {
	d := inst_dir("inherit")
	defer os.remove_all(d)
	cfd, fd, r := instance_locks_take(d)
	testing.expect_value(t, r, Instance_Refusal.None)
	argv := []cstring{"/bin/sleep", "5", nil}
	pid: posix.pid_t
	spawned := posix.posix_spawn(&pid, "/bin/sleep", nil, nil, raw_data(argv), nil) == .NONE
	testing.expect(t, spawned, "a child runs")
	defer if spawned {
		posix.kill(pid, .SIGKILL)
		st: i32
		posix.waitpid(pid, &st, {})
	}
	instance_lock_release(cfd)
	instance_lock_release(fd)
	time.sleep(50 * time.Millisecond)
	ex, ok2 := instance_lock_take(d, INSTANCE_LOCK_FILE, LOCK_EX) // as an older app would
	testing.expect(t, ok2, "the child does not hold the lock (O_CLOEXEC)")
	if ok2 do instance_lock_release(ex)
	cex, ok3 := instance_lock_take(d, CORE_LOCK_FILE, LOCK_EX)
	testing.expect(t, ok3, "nor core.lock")
	if ok3 do instance_lock_release(cex)
}

@(private = "file")
inst_alive :: proc(pid: int) -> bool {return pid == 101 || pid == 102 || pid == 103}
@(private = "file")
inst_exe :: proc(pid: int) -> string {
	switch pid {
	case 101: return "/Applications/pi-desk.app/Contents/MacOS/pi-desk"
	case 102: return "/Applications/Deckhand.app/Contents/MacOS/Deckhand"
	case 103: return "/Users/me/src/pi-desk/build/pi-desk.app/Contents/MacOS/pi-desk"
	}
	return ""
}

@(test)
instance_legacy :: proc(t: ^testing.T) {
	d := inst_dir("sock")
	defer os.remove_all(d)
	mk :: proc(d, name: string) {_ = os.write_entire_file(fmt.tprintf("%s/%s", d, name), transmute([]byte)string(""))}
	// ours, a dead one, a Deckhand (its lock decides), junk names
	for n in ([]string{"pi-desk-7.sock", "pi-desk-99.sock", "pi-desk-102.sock", "pi-desk-x.sock", "pi-desk-101.sockx", "other-101.sock"}) do mk(d, n)
	testing.expect_value(t, instance_legacy_find(d, 7, inst_alive, inst_exe), 0)
	mk(d, "pi-desk-101.sock")
	testing.expect_value(t, instance_legacy_find(d, 7, inst_alive, inst_exe), 101)
	testing.expect_value(t, instance_legacy_find(d, 101, inst_alive, inst_exe), 0) // that is us
	testing.expect_value(t, instance_legacy_find(fmt.tprintf("%s/none", d), 7, inst_alive, inst_exe), 0)
	// a pi-desk built from source (build/pi-desk.app beside build.sh) does not count
	testing.expect(t, instance_legacy_exe("/Applications/pi-desk.app/Contents/MacOS/pi-desk"))
	testing.expect(t, instance_legacy_exe("/Users/me/Apps/pi-desk.app/Contents/MacOS/pi-desk"))
	testing.expect(t, !instance_legacy_exe("/Applications/Deckhand.app/Contents/MacOS/Deckhand"))
	testing.expect(t, !instance_legacy_exe("/usr/bin/pi-desk-cli"))
	repo := inst_dir("repo")
	defer os.remove_all(repo)
	os.make_directory_all(fmt.tprintf("%s/build", repo))
	_ = os.write_entire_file(fmt.tprintf("%s/build.sh", repo), transmute([]byte)string("#!/bin/sh\n"))
	testing.expect(t, !instance_legacy_exe(fmt.tprintf("%s/build/pi-desk.app/Contents/MacOS/pi-desk", repo)))
	testing.expect(t, strings.contains(instance_message(0), "Deckhand is already running"))
	testing.expect(t, strings.contains(instance_message(101), "pi-desk"))
}

// instance_guard as main.odin calls it (moved from the instance.sh scene): the real liveness and
// executable lookups find a running pi-desk.app by its socket in the runtime dir; its leftover
// socket alone does not count once it quits; a second take of the same data dir is refused.
@(test)
instance_guard_whole :: proc(t: ^testing.T) {
	d := inst_dir("guard")
	defer os.remove_all(d)
	data := fmt.tprintf("%s/data", d)
	run := fmt.tprintf("%s/run", d)
	macos := fmt.tprintf("%s/old/pi-desk.app/Contents/MacOS", d)
	for x in ([]string{data, run, macos}) do os.make_directory_all(x)
	saved := strings.clone(os.get_env("DECKHAND_RUNTIME_DIR", context.temp_allocator), context.temp_allocator)
	os.set_env("DECKHAND_RUNTIME_DIR", run)
	defer {
		if saved == "" do os.unset_env("DECKHAND_RUNTIME_DIR")
		else do os.set_env("DECKHAND_RUNTIME_DIR", saved)
	}

	// a stand-in pi-desk 0.1.x that only sleeps (a copy of /bin/sleep is killed: Apple's
	// signature is for its own path)
	src := fmt.tprintf("%s/old/sleep.c", d)
	exe := fmt.tprintf("%s/pi-desk", macos)
	_ = os.write_entire_file(src, transmute([]byte)string("#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n"))
	cc := []cstring{"/usr/bin/cc", "-o", strings.clone_to_cstring(exe, context.temp_allocator), strings.clone_to_cstring(src, context.temp_allocator), nil}
	ccpid: posix.pid_t
	st: i32
	if !testing.expect(t, posix.posix_spawn(&ccpid, "/usr/bin/cc", nil, nil, raw_data(cc), nil) == .NONE, "cc runs") do return
	posix.waitpid(ccpid, &st, {})
	if !testing.expect(t, os.exists(exe), "the stand-in built") do return
	argv := []cstring{strings.clone_to_cstring(exe, context.temp_allocator), nil}
	old: posix.pid_t
	if !testing.expect(t, posix.posix_spawn(&old, argv[0], nil, nil, raw_data(argv), nil) == .NONE, "the stand-in runs") do return
	stopped := false
	stop := proc(pid: posix.pid_t) {
		posix.kill(pid, .SIGKILL)
		st: i32
		posix.waitpid(pid, &st, {})
	}
	defer if !stopped do stop(old)
	_ = os.write_entire_file(fmt.tprintf("%s/pi-desk-%d.sock", run, old), transmute([]byte)string(""))

	why := instance_guard(data, true)
	testing.expectf(t, strings.contains(why, "pi-desk is running"), "beside pi-desk: %q", why)
	testing.expect_value(t, instance_fd, posix.FD(-1)) // refused before the lock
	stop(old)
	stopped = true
	testing.expect_value(t, instance_guard(data, true), "") // its leftover socket alone does not count
	defer {
		instance_lock_release(instance_fd)
		instance_lock_release(instance_core_fd)
		instance_fd, instance_core_fd = -1, -1
	}
	fd := instance_fd
	testing.expect(t, fd >= 0, "the lock is held")
	again := instance_guard(data, false)
	testing.expectf(t, strings.contains(again, "Deckhand is already running"), "a second start: %q", again)
	testing.expect_value(t, instance_fd, fd) // the first take is kept
}
