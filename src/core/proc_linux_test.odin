#+build linux
package core

// /proc and SO_PEERCRED (proc_linux.odin): what the Linux core reads in place of libproc.

import "core:fmt"
import "core:sys/posix"
import "core:testing"

@(test)
proc_stat_ppid_parse :: proc(t: ^testing.T) {
	cases := []struct {
		line: string,
		want: i32,
	} {
		{"1234 (bash) S 1000 1234 1234 34816 ...", 1000},
		{"77 (a b) c) R 42 77 77 0 -1", 42}, // spaces and ')' in comm: the last ')' counts
		{"5 ((sd-pam)) S 4 5 5", 4},
		{"9 (x) S", 0}, // no ppid
		{"9 x S 4", 0}, // no comm
		{"9 (x) S -3 1", 0},
		{"9 (x) S 99999999999 1", 0},
		{"", 0},
	}
	for c, i in cases do testing.expectf(t, proc_stat_ppid(c.line) == c.want, "case %d: %d", i, proc_stat_ppid(c.line))
}

@(test)
proc_reads_self :: proc(t: ^testing.T) {
	me := i32(posix.getpid())
	testing.expect_value(t, pid_parent(me), i32(posix.getppid()))
	testing.expect_value(t, pid_parent(-1), i32(0))
	testing.expect(t, pid_exe(me) != "" && pid_exe(me) == executable_path(), pid_exe(me))
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer posix.close(fds[0])
	defer posix.close(fds[1])
	testing.expect_value(t, sock_peer_pid(fds[0]), me)
	testing.expect_value(t, sock_peer_pid(-1), i32(0))
	// proc_look (the hub door's sshd check): this process, and init (root's)
	parent, uid, name := proc_look(me)
	testing.expect_value(t, parent, i32(posix.getppid()))
	testing.expect_value(t, uid, u32(posix.geteuid()))
	testing.expect(t, name != "", "own name")
	_, uid1, name1 := proc_look(1)
	testing.expect_value(t, uid1, u32(0))
	testing.expect(t, name1 != "", "pid 1's name")
	p0, u0, n0 := proc_look(0)
	testing.expect(t, p0 == 0 && u0 == 0 && n0 == "")
	_, sok := proc_status_euid("Name:\tx\nUid:\t1000\t1001\t1000\t1000\n")
	euid, _ := proc_status_euid("Name:\tx\nUid:\t1000\t1001\t1000\t1000\n")
	testing.expect(t, sok && euid == 1001)
	_, bad := proc_status_euid("Name:\tx\n")
	testing.expect(t, !bad)
	// another data dir keeps <data>/run; only the default one moves to ~/.local/state
	testing.expect_value(t, runtime_dir_linux(fmt.tprintf("/nonexistent/deckhand-%d", me)), "")
}
