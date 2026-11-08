package main

// One Deckhand per data dir. At start, before anything is written there, Deckhand takes
// <data dir>/instance.lock (flock, exclusive, non-blocking; held until the process ends). The
// file is opened close-on-exec, so pi, shells, jobs and the update relaunch's sh never inherit
// it and never keep a later start out. pi-desk 0.1.x takes no lock: a live pi-desk is found by
// its control socket (<runtime dir>/pi-desk-<pid>.sock, a process whose executable is
// pi-desk's). Either way Deckhand says so and quits (main.odin, instance_guard).

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

INSTANCE_LOCK_FILE :: "instance.lock"

// flock, LOCK_EX and LOCK_NB: jobs_run.odin's (the jobs' run locks)

// The lock in dir (made 0700 if missing): its fd, or ok = false (another holds it, or the file
// cannot be opened).
instance_lock_take :: proc(dir: string) -> (fd: posix.FD, ok: bool) {
	os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User})
	p := strings.clone_to_cstring(fmt.tprintf("%s/%s", dir, INSTANCE_LOCK_FILE), context.temp_allocator)
	fd = posix.open(p, {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if fd < 0 do return -1, false
	if flock(c.int(fd), LOCK_EX | LOCK_NB) != 0 {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

instance_lock_release :: proc(fd: posix.FD) {
	if fd >= 0 do posix.close(fd)
}

// A live pi-desk 0.1.x's pid from its socket in the runtime dir, or 0. own: this process.
instance_old_pidesk_find :: proc(runtime_dir: string, own: int, alive: proc(pid: int) -> bool, exe: proc(pid: int) -> string) -> int {
	entries, err := os.read_all_directory_by_path(runtime_dir, context.temp_allocator)
	if err != nil do return 0
	for e in entries {
		n := e.name
		if !strings.has_prefix(n, "pi-desk-") || !strings.has_suffix(n, ".sock") do continue
		digits := n[len("pi-desk-"):len(n) - len(".sock")]
		pid, pok := strconv.parse_int(digits, 10)
		if !pok || pid <= 0 || pid == own || !alive(pid) do continue
		if instance_pidesk_exe(exe(pid)) do return pid
	}
	return 0
}

// pi-desk's executable (pi-desk.app's), not one built from source (build/pi-desk.app beside
// build.sh: its scenes run with their own data dirs).
instance_pidesk_exe :: proc(path: string) -> bool {
	if filepath.base(path) != "pi-desk" do return false
	macos := filepath.dir(path)
	contents := filepath.dir(macos)
	bundle := filepath.dir(contents)
	if filepath.base(macos) != "MacOS" || filepath.base(contents) != "Contents" || filepath.base(bundle) != "pi-desk.app" do return false
	parent := filepath.dir(bundle)
	if filepath.base(parent) == "build" && os.exists(fmt.tprintf("%s/../build.sh", parent)) do return false
	return true
}

// What the alert says (old: the pi-desk found, or 0).
instance_message :: proc(old: int) -> string {
	if old != 0 do return "pi-desk is running with the same data. Quit pi-desk first (and delete pi-desk.app: Deckhand replaces it), then open Deckhand again."
	return "Deckhand is already running (or pi-desk is using the same data). Quit it first."
}

@(private = "file")
instance_alive :: proc(pid: int) -> bool {return posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK || posix.errno() == .EPERM}

when ODIN_OS == .Darwin {
	// proc_pidpath: pty_posix.odin's
	@(private = "file")
	instance_exe :: proc(pid: int) -> string {
		buf: [4096]u8
		n := proc_pidpath(c.int(pid), &buf[0], u32(len(buf)))
		if n <= 0 do return ""
		return strings.clone(string(buf[:n]), context.temp_allocator)
	}
} else {
	@(private = "file")
	instance_exe :: proc(pid: int) -> string {return ""}
}

instance_fd: posix.FD = -1

// At start (main.odin init), before anything is written to dir: "" = go on (the lock is held
// until the process ends), else why not. check_old: look for a running pi-desk 0.1.x too.
instance_guard :: proc(dir: string, check_old: bool) -> string {
	if dir == "" do return ""
	if check_old {
		if rd := sock_legacy_runtime_dir(context.temp_allocator); rd != "" {
			if old := instance_old_pidesk_find(rd, int(posix.getpid()), instance_alive, instance_exe); old != 0 do return instance_message(old)
		}
	}
	fd, ok := instance_lock_take(dir)
	if !ok do return instance_message(0)
	instance_fd = fd
	return ""
}
