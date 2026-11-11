#+build darwin, linux
package core

// Who holds a lock file in the data dir when instance_guard is refused (#78): the processes of
// this user with that file open (as lsof finds them: macOS's libproc, Linux's /proc/<pid>/fd), so
// the alert names a pid and a program instead of guessing. A leftover Deckhand process (its parent
// gone, its executable a Deckhand bundle's, e.g. an older app's fork child that hung before exec
// and kept the lock) may be ended from the alert: lock_holder_end, after the user confirms.

import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

Lock_Holder :: struct {
	pid:     i32, // 0 = none found
	ppid:    i32,
	start:   i64, // its start time: with pid and exe, its identity (pid reuse)
	exe:     string, // temp
	threads: int,
	dev:     u64, // the lock file (re-checked before each signal)
	ino:     u64,
	others:  int, // more processes with the file open (then it is never ended)
}

LOCK_HOLDERS_SCAN_MAX :: 8192 // processes looked at

// The first other process of this user with path open, and how many more there are.
lock_holder_find :: proc(path: string) -> (h: Lock_Holder) {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK do return
	self := i32(posix.getpid())
	for pid in lock_pids() {
		if pid <= 1 || pid == self || !lock_pid_has(pid, u64(st.st_dev), u64(st.st_ino)) do continue
		if h.pid != 0 {
			h.others += 1
			continue
		}
		if p, ok := lock_proc_ident(pid); ok do h = p
	}
	if h.pid != 0 do h.dev, h.ino = u64(st.st_dev), u64(st.st_ino)
	return
}

// The holder as the alert names it: "process 1234 (/path/to/program)", the path cleaned and
// bounded (another process's text).
lock_holder_text :: proc(h: Lock_Holder) -> string {
	exe := h.exe == "" ? "an unknown program" : text_clean(h.exe, 200)
	s := fmt.tprintf("process %d (%s)", h.pid, exe)
	if h.others > 0 do s = fmt.tprintf("%s and %d more", s, h.others)
	return s
}

// A Deckhand window's executable: …/<Deckhand*|pi-desk*>.app/Contents/MacOS/<Deckhand|pi-desk>
// (this app or an older one, wherever the bundle is: the Trash renames it "Deckhand 10.41.22.app").
// Only the window loads CEF, whose atfork handlers can hang a fork child. Never the background
// core (deckhand-core-serve: launchd's, ppid 1, single-threaded while it starts) or the session
// holder (deckhand-core).
lock_exe_deckhand :: proc(exe: string) -> bool {
	switch filepath.base(exe) {
	case "Deckhand", "pi-desk":
	case: return false
	}
	macos := filepath.dir(exe)
	contents := filepath.dir(macos)
	bundle := filepath.base(filepath.dir(contents))
	if filepath.base(macos) != "MacOS" || filepath.base(contents) != "Contents" || !strings.has_suffix(bundle, ".app") do return false
	return strings.has_prefix(bundle, "Deckhand") || strings.has_prefix(bundle, "pi-desk")
}

// The user may be offered to end it: the one process holding the file, a leftover running a
// Deckhand executable, not us. A leftover: its parent gone (ppid 1) and one thread, which a fork
// child that never reached exec has and a running app or core (launchd's: ppid 1 too) never has.
// macOS only (the window offers it).
lock_holder_endable :: proc(h: Lock_Holder) -> bool {
	when ODIN_OS == .Darwin {
		return h.pid > 1 && h.pid != i32(posix.getpid()) && h.others == 0 && h.ppid == 1 && h.threads == 1 && h.start != 0 && lock_exe_deckhand(h.exe)
	} else {
		return false
	}
}

// pid is still the process h found: alive (not a zombie), same start time and executable, still
// a leftover (ppid 1, one thread) and still holding the lock file open.
lock_holder_same :: proc(h: Lock_Holder) -> bool {
	if h.pid <= 1 do return false
	now, ok := lock_proc_ident(h.pid)
	return ok && lock_holder_still(h, now, lock_pid_has(h.pid, h.dev, h.ino))
}

// h, as looked up again now (has_file: it still has the lock file open), is the leftover found.
lock_holder_still :: proc(h, now: Lock_Holder, has_file: bool) -> bool {
	return has_file && now.pid == h.pid && now.ppid == 1 && now.threads == 1 && now.start == h.start && now.exe == h.exe
}

// Ends h after the user confirmed: SIGTERM, then SIGKILL if it is still there after a short
// wait; each signal only after h is checked again to be the same process. true = it is gone.
// Blocks up to about 4 s (the window, at start, behind its alert).
lock_holder_end :: proc(h: Lock_Holder, wait := 2 * time.Second) -> bool {
	if !lock_holder_endable(h) do return false
	for sig in ([2]posix.Signal{.SIGTERM, .SIGKILL}) {
		if !lock_holder_same(h) do return true
		posix.kill(posix.pid_t(h.pid), sig)
		deadline := time.tick_add(time.tick_now(), wait)
		for time.tick_diff(time.tick_now(), deadline) > 0 {
			time.sleep(50 * time.Millisecond)
			if !lock_holder_same(h) do return true
		}
	}
	return !lock_holder_same(h)
}

when ODIN_OS == .Darwin {
	PROC_UID_ONLY :: 4
	PROC_PIDFDVNODEINFO :: 1
	PROX_FDTYPE_VNODE :: 1
	VNODE_FDINFO_SIZE :: 176 // struct vnode_fdinfo; vi_stat.vst_dev at 24, vst_ino at 32
	SZOMB :: 5 // pbi_status
	PROC_PIDTASKINFO :: 4
	PROC_TASKINFO_SIZE :: 96 // struct proc_taskinfo; pti_threadnum at 84

	foreign import lockproc "system:proc"
	@(default_calling_convention = "c")
	foreign lockproc {
		proc_listpids :: proc(type: u32, typeinfo: u32, buffer: rawptr, buffersize: c.int) -> c.int ---
	}

	@(private = "file")
	lock_pids :: proc() -> []i32 {
		buf := make([]i32, LOCK_HOLDERS_SCAN_MAX, context.temp_allocator)
		n := proc_listpids(PROC_UID_ONLY, u32(posix.getuid()), raw_data(buf), c.int(len(buf) * size_of(i32)))
		return buf[:clamp(int(n) / size_of(i32), 0, len(buf))]
	}

	@(private = "file")
	lock_pid_has :: proc(pid: i32, dev, ino: u64) -> bool {
		need := proc_pidinfo(c.int(pid), PROC_PIDLISTFDS, 0, nil, 0)
		if need <= 0 do return false
		fds := make([]Proc_Fdinfo, int(need) / size_of(Proc_Fdinfo) + 16, context.temp_allocator)
		n := proc_pidinfo(c.int(pid), PROC_PIDLISTFDS, 0, raw_data(fds), c.int(len(fds) * size_of(Proc_Fdinfo)))
		if n <= 0 do return false
		for fd in fds[:min(int(n) / size_of(Proc_Fdinfo), len(fds))] {
			if fd.fdtype != PROX_FDTYPE_VNODE do continue
			info: [VNODE_FDINFO_SIZE]u8
			if proc_pidfdinfo(pid, fd.fd, PROC_PIDFDVNODEINFO, &info[0], size_of(info)) != size_of(info) do continue
			if u64((^u32)(&info[24])^) == dev && (^u64)(&info[32])^ == ino do return true
		}
		return false
	}

	// pid's parent, start time (µs since the epoch), executable and threads; not ok for a zombie
	lock_proc_ident :: proc(pid: i32) -> (h: Lock_Holder, ok: bool) {
		if pid <= 0 do return
		buf: [PROC_BSDINFO_SIZE]u8
		if proc_pidinfo(c.int(pid), PROC_PIDTBSDINFO, 0, &buf, size_of(buf)) != size_of(buf) do return
		if (^u32)(&buf[4])^ == SZOMB do return
		task: [PROC_TASKINFO_SIZE]u8
		if proc_pidinfo(c.int(pid), PROC_PIDTASKINFO, 0, &task, size_of(task)) == size_of(task) do h.threads = int((^i32)(&task[84])^)
		path: [4096]u8
		n := proc_pidpath(c.int(pid), &path[0], u32(len(path)))
		if n > 0 do h.exe = strings.clone(string(path[:n]), context.temp_allocator)
		h.pid, h.ppid = pid, (^i32)(&buf[16])^
		h.start = i64((^u64)(&buf[120])^) * 1_000_000 + i64((^u64)(&buf[128])^)
		return h, true
	}
} else {
	@(private = "file")
	lock_pids :: proc() -> []i32 {
		out := make([dynamic]i32, context.temp_allocator)
		entries, err := os.read_all_directory_by_path("/proc", context.temp_allocator)
		if err != nil do return nil
		for e in entries {
			n, ok := strconv.parse_int(e.name, 10)
			if ok && n > 0 && len(out) < LOCK_HOLDERS_SCAN_MAX do append(&out, i32(n))
		}
		return out[:]
	}

	@(private = "file")
	lock_pid_has :: proc(pid: i32, dev, ino: u64) -> bool {
		dir := fmt.tprintf("/proc/%d/fd", pid)
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return false // gone, or not ours
		for e in entries {
			st: posix.stat_t
			if posix.stat(strings.clone_to_cstring(fmt.tprintf("%s/%s", dir, e.name), context.temp_allocator), &st) != .OK do continue
			if u64(st.st_dev) == dev && u64(st.st_ino) == ino do return true
		}
		return false
	}

	// pid's parent, start time (clock ticks after boot: /proc/<pid>/stat's 22nd field),
	// executable and threads (the 20th); not ok for a zombie
	lock_proc_ident :: proc(pid: i32) -> (h: Lock_Holder, ok: bool) {
		if pid <= 0 do return
		b, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
		if err != nil do return
		s := string(b)
		close := strings.last_index_byte(s, ')')
		if close < 0 do return
		f := strings.fields(s[close + 1:], context.temp_allocator)
		if len(f) < 20 || f[0] == "Z" do return
		st, sok := strconv.parse_i64(f[19], 10)
		th, tok := strconv.parse_int(f[17], 10)
		if !sok || !tok do return
		return {pid = pid, ppid = proc_stat_ppid(s), start = st, exe = pid_exe(pid), threads = th}, true
	}
}
