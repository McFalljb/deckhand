package core

// One Deckhand per data dir (docs/plans/background-core.md §7.6). At start, before anything is
// written there, Deckhand takes two flocks in <data dir> (non-blocking, held until the process
// ends): core.lock exclusive (one app per data dir) and instance.lock shared. Session holders
// (src/holder) take instance.lock shared too, and a Deckhand from before M1 wants it exclusive,
// so an older Deckhand is refused while this app or a holder lives, and this app is refused
// while an older one runs. The files are opened close-on-exec, so pi, shells, jobs and the
// update relaunch's sh never inherit them and never keep a later start out. pi-desk 0.1.x takes
// no lock: a live Deckhand is found by its control socket in its old runtime dir
// ($TMPDIR/pi-desk-<uid>/pi-desk-<pid>.sock, a process whose executable is Deckhand's). Either
// way Deckhand says so and quits (main.odin, instance_guard).

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

CORE_LOCK_FILE :: "core.lock"
INSTANCE_LOCK_FILE :: "instance.lock"
LOCK_SH :: 1

// flock, LOCK_EX and LOCK_NB: jobs_run.odin's (the jobs' run locks)

// The lock file name in dir (dir made 0700 if missing), taken with op (LOCK_EX or LOCK_SH;
// never blocks): its fd, or ok = false (a conflicting lock is held, or the file cannot be opened).
instance_lock_take :: proc(dir, name: string, op: c.int) -> (fd: posix.FD, ok: bool) {
	os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User})
	p := strings.clone_to_cstring(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)
	fd = posix.open(p, {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if fd < 0 do return -1, false
	if flock(c.int(fd), op | LOCK_NB) != 0 {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

Instance_Refusal :: enum u8 {
	None,
	Running, // core.lock is held: another Deckhand (M1 or later) runs with this data
	Older, // instance.lock is held exclusive: a Deckhand from before M1
}

// The app's two locks in dir: core.lock EX, then instance.lock SH. Both or neither.
instance_locks_take :: proc(dir: string) -> (core_fd, inst_fd: posix.FD, refused: Instance_Refusal) {
	core_ok, inst_ok: bool
	core_fd, core_ok = instance_lock_take(dir, CORE_LOCK_FILE, LOCK_EX)
	if !core_ok do return -1, -1, .Running
	inst_fd, inst_ok = instance_lock_take(dir, INSTANCE_LOCK_FILE, LOCK_SH)
	if !inst_ok {
		posix.close(core_fd)
		return -1, -1, .Older
	}
	return core_fd, inst_fd, .None
}

instance_lock_release :: proc(fd: posix.FD) {
	if fd >= 0 do posix.close(fd)
}

// A live pi-desk 0.1.x's pid from its socket in the runtime dir, or 0. own: this process.
instance_legacy_find :: proc(runtime_dir: string, own: int, alive: proc(pid: int) -> bool, exe: proc(pid: int) -> string) -> int {
	entries, err := os.read_all_directory_by_path(runtime_dir, context.temp_allocator)
	if err != nil do return 0
	for e in entries {
		n := e.name
		if !strings.has_prefix(n, "pi-desk-") || !strings.has_suffix(n, ".sock") do continue
		digits := n[len("pi-desk-"):len(n) - len(".sock")]
		pid, pok := strconv.parse_int(digits, 10)
		if !pok || pid <= 0 || pid == own || !alive(pid) do continue
		if instance_legacy_exe(exe(pid)) do return pid
	}
	return 0
}

// Deckhand's executable (pi-desk.app's), not one built from source (build/pi-desk.app beside
// build.sh: its scenes run with their own data dirs).
instance_legacy_exe :: proc(path: string) -> bool {
	if filepath.base(path) != "pi-desk" do return false
	macos := filepath.dir(path)
	contents := filepath.dir(macos)
	bundle := filepath.dir(contents)
	if filepath.base(macos) != "MacOS" || filepath.base(contents) != "Contents" || filepath.base(bundle) != "pi-desk.app" do return false
	parent := filepath.dir(bundle)
	if filepath.base(parent) == "build" && os.exists(fmt.tprintf("%s/../build.sh", parent)) do return false
	return true
}

// What the alert says (old: the Deckhand found, or 0; refused: which lock was held; holder: the
// process found holding it, lock_holder.odin).
instance_message :: proc(old: int, refused := Instance_Refusal.Running, holder := Lock_Holder{}) -> string {
	if old == 0 && holder.pid != 0 {
		if refused == .Older do return fmt.tprintf("Another program holds %s in Deckhand's data folder: %s. Quit it first.", INSTANCE_LOCK_FILE, lock_holder_text(holder))
		return fmt.tprintf("Deckhand is already running (or pi-desk is using the same data): %s holds %s. Quit it first.", lock_holder_text(holder), CORE_LOCK_FILE)
	}
	if refused == .Older do return "An older Deckhand is running with the same data. Quit it first."
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

instance_fd: posix.FD = -1 // instance.lock (SH)
instance_core_fd: posix.FD = -1 // core.lock (EX)
instance_refused_by: Lock_Holder // the process holding the lock that refused the last instance_guard (temp)

// Who holds the lock that refused (lock_holder_find on its file).
instance_holder_of :: proc(dir: string, refused: Instance_Refusal) -> Lock_Holder {
	return lock_holder_find(fmt.tprintf("%s/%s", dir, refused == .Older ? INSTANCE_LOCK_FILE : CORE_LOCK_FILE))
}

// The window, after its core refused (client_core_dial): whether the locks are still refused now
// and who holds the one that is. Takes them and lets them go at once when free.
instance_holder_now :: proc(dir: string) -> Lock_Holder {
	core_fd, inst_fd, refused := instance_locks_take(dir)
	if refused == .None {
		instance_lock_release(inst_fd)
		instance_lock_release(core_fd)
		return {}
	}
	return instance_holder_of(dir, refused)
}

// A separate core refused by instance_guard writes why to <run>/core.refused (0600), so its
// window says why instead of waiting out its start (client_core_dial).
CORE_REFUSED_FILE :: "core.refused"
CORE_REFUSED_MAX :: 1024

core_refused_write :: proc(run, why: string) {
	if run == "" do return
	// whole or not at all: the window reads and removes it every 20 ms
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s", run, CORE_REFUSED_FILE), context.temp_allocator)
	tmp := strings.clone_to_cstring(fmt.tprintf("%s/%s.tmp", run, CORE_REFUSED_FILE), context.temp_allocator)
	fd := posix.open(tmp, {.WRONLY, .CREAT, .TRUNC, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
	if fd < 0 do return
	text := why[:min(len(why), CORE_REFUSED_MAX)]
	ok := posix.write(fd, raw_data(text), uint(len(text))) == len(text)
	posix.close(fd)
	if !ok || posix.rename(tmp, path) != 0 do posix.unlink(tmp)
}

// What a refused core wrote, cleaned and bounded, and the file gone; "" = none.
core_refused_take :: proc(run: string) -> string {
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s", run, CORE_REFUSED_FILE), context.temp_allocator)
	fd := posix.open(path, {.CLOEXEC, .NOFOLLOW, .NONBLOCK})
	if fd < 0 do return ""
	buf: [CORE_REFUSED_MAX]u8
	n := posix.read(fd, &buf[0], len(buf))
	posix.close(fd)
	posix.unlink(path)
	if n <= 0 do return ""
	return text_clean(strings.trim_space(string(buf[:n])), CORE_REFUSED_MAX)
}

// At start (main.odin init), before anything is written to dir: "" = go on (the lock is held
// until the process ends), else why not. check_old: look for a running pi-desk 0.1.x too.
instance_guard :: proc(dir: string, check_old: bool) -> string {
	if dir == "" do return ""
	if check_old {
		if rd := sock_legacy_runtime_dir(context.temp_allocator); rd != "" {
			if old := instance_legacy_find(rd, int(posix.getpid()), instance_alive, instance_exe); old != 0 do return instance_message(old)
		}
	}
	core_fd, inst_fd, refused := instance_locks_take(dir)
	if refused != .None {
		instance_refused_by = instance_holder_of(dir, refused)
		return instance_message(0, refused, instance_refused_by)
	}
	instance_refused_by = {}
	instance_core_fd, instance_fd = core_fd, inst_fd
	return ""
}
