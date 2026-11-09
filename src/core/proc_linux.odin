#+build linux
package core

// Linux's /proc and SO_PEERCRED in place of macOS's libproc and LOCAL_PEERPID
// (docs/plans/background-core.md §10.4 M6-L1). pty_posix.odin reads a tab's cwd and executable
// from /proc already; jobs_run.odin a run's children (proc_tree).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

// The executable pid runs now (readlink /proc/<pid>/exe), or "" (gone, or not ours to read).
// Temp-allocated.
pid_exe :: proc(pid: i32) -> string {
	if pid <= 0 do return ""
	p, err := os.read_link(fmt.tprintf("/proc/%d/exe", pid), context.temp_allocator)
	return err == nil ? p : ""
}

// The session holder's executable (holder_client.odin, holder_successor.odin); no holder runs on
// Linux until M6-L3.
holder_pid_exe :: proc(pid: i32) -> string {return pid_exe(pid)}

// The process at the other end of a connected Unix socket: SO_PEERCRED, the process that called
// connect (or socketpair), fixed then. 0 = unknown.
sock_peer_pid :: proc(fd: Sock_Fd) -> i32 {
	SO_PEERCRED :: 17
	cred: struct {
		pid:      i32,
		uid, gid: u32,
	}
	n := posix.socklen_t(size_of(cred))
	if posix.getsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_PEERCRED), &cred, &n) != .OK || n != size_of(cred) do return 0
	return cred.pid
}

// pid's parent (the ppid in /proc/<pid>/stat), 0 when unknown.
pid_parent :: proc(pid: i32) -> i32 {
	if pid <= 0 do return 0
	b, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil do return 0
	return proc_stat_ppid(string(b))
}

// The ppid field of a /proc/<pid>/stat line: "pid (comm) state ppid ...". comm may hold spaces
// and parentheses, so the fields start after the LAST ')'. 0 when malformed.
proc_stat_ppid :: proc(stat: string) -> i32 {
	close := strings.last_index_byte(stat, ')')
	if close < 0 do return 0
	fields := strings.fields(stat[close + 1:], context.temp_allocator)
	if len(fields) < 2 do return 0
	ppid, ok := strconv.parse_int(fields[1], 10)
	if !ok || ppid < 0 || ppid > int(max(i32)) do return 0
	return i32(ppid)
}

// window_sock.odin's Proc_Look on Linux: the ppid (/proc/<pid>/stat), the effective uid (the
// second Uid field of /proc/<pid>/status) and the name: /proc/<pid>/exe's base name where it can
// be read, else /proc/<pid>/comm (another user's exe, root's sshd, can't be read). 0, 0, "" when
// unknown. Temp-allocated.
// Residual: comm is the execve path's base name (15 bytes), so a setuid-root binary run through
// a link named sshd shows as root's "sshd". That needs a setuid binary that then runs the user's
// code; the same user is Linux's trust boundary anyway (background-core.md §8.3).
proc_look :: proc(pid: i32) -> (parent: i32, uid: u32, name: string) {
	if pid <= 0 do return 0, 0, ""
	stat, e1 := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	status, e2 := os.read_entire_file(fmt.tprintf("/proc/%d/status", pid), context.temp_allocator)
	comm, e3 := os.read_entire_file(fmt.tprintf("/proc/%d/comm", pid), context.temp_allocator)
	if e1 != nil || e2 != nil || e3 != nil do return 0, 0, ""
	euid, ok := proc_status_euid(string(status))
	if !ok do return 0, 0, ""
	name = strings.trim_right(string(comm), "\n")
	if exe := pid_exe(pid); exe != "" do name = exe[strings.last_index_byte(exe, '/') + 1:]
	return proc_stat_ppid(string(stat)), euid, name
}

// The effective uid in a /proc/<pid>/status text ("Uid:\treal\teffective\tsaved\tfs").
proc_status_euid :: proc(status: string) -> (uid: u32, ok: bool) {
	rest := status
	for line in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(line, "Uid:") do continue
		f := strings.fields(line[4:], context.temp_allocator)
		if len(f) < 2 do return 0, false
		v, vok := strconv.parse_u64(f[1], 10)
		if !vok || v > u64(max(u32)) do return 0, false
		return u32(v), true
	}
	return 0, false
}

// The runtime dir for data (socket_posix.odin): ~/.local/state/deckhand/run when data is the
// default data dir (~/.local/share/deckhand), else "" (<data>/run). Its parent is made here
// (0700); runtime_dir_prepare makes and checks run itself. Temp-allocated.
runtime_dir_linux :: proc(data: string) -> string {
	home := data_home(TEST_HOOKS, context.temp_allocator)
	if !strings.has_prefix(home, "/") || data != data_dir_under(home, context.temp_allocator) do return ""
	parent := fmt.tprintf("%s/.local/state/deckhand", strings.trim_right(home, "/"))
	os.make_directory_all(parent, {.Read_User, .Write_User, .Execute_User})
	return fmt.tprintf("%s/run", parent)
}
