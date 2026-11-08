package trust

import "core:sys/posix"
import "core:testing"

@(test)
peer_allowed_table :: proc(t: ^testing.T) {
	me :: u32(501)
	cases := []struct {
		peer: Peer,
		want: Decision,
	} {
		{Peer{ok = true, pid = 10, pidversion = 1, euid = me}, .Allow},
		{Peer{ok = true, pid = 10, pidversion = 1, euid = 0}, .Other_User}, // root is another user too
		{Peer{ok = true, pid = 10, pidversion = 1, euid = 502}, .Other_User},
		{Peer{}, .No_Peer}, // the connecting process already exited
	}
	for c, i in cases do testing.expectf(t, peer_allowed(.Adhoc, me, c.peer) == c.want, "case %d: %v", i, peer_allowed(.Adhoc, me, c.peer))
}

@(test)
peer_still_table :: proc(t: ^testing.T) {
	a := Peer{ok = true, pid = 10, pidversion = 7, euid = 501}
	cases := []struct {
		now:  Peer,
		want: Decision,
	} {
		{a, .Allow},
		{Peer{ok = true, pid = 10, pidversion = 8, euid = 501}, .Changed}, // exec'd after connecting
		{Peer{ok = true, pid = 11, pidversion = 7, euid = 501}, .Changed}, // the fd went to a child
		{Peer{ok = true, pid = 10, pidversion = 7, euid = 0}, .Changed},
		{Peer{}, .No_Peer}, // the last writer exited (EINVAL)
	}
	for c, i in cases do testing.expectf(t, peer_still(a, c.now) == c.want, "case %d", i)
}

@(test)
ready_peer_table :: proc(t: ^testing.T) {
	p := Peer{ok = true, pid = 42, pidversion = 3, euid = 501}
	testing.expect(t, ready_peer_allowed(.Adhoc, 501, 42, p) == .Allow)
	testing.expect(t, ready_peer_allowed(.Adhoc, 501, 43, p) == .Changed) // not the launched child
	testing.expect(t, ready_peer_allowed(.Adhoc, 501, 0, p) == .Changed) // unknown child: never
	testing.expect(t, ready_peer_allowed(.Adhoc, 502, 42, p) == .Other_User)
	testing.expect(t, ready_peer_allowed(.Adhoc, 501, 42, Peer{}) == .No_Peer)
}

@(test)
hello_answer_table :: proc(t: ^testing.T) {
	testing.expect(t, hello_answer(attached = false, wire_ok = true) == .Welcome)
	testing.expect(t, hello_answer(attached = true, wire_ok = true) == .Refuse_Attached)
	testing.expect(t, hello_answer(attached = false, wire_ok = false) == .Refuse_Wire)
	testing.expect(t, hello_answer(attached = true, wire_ok = false) == .Refuse_Wire)
}

// The real getsockopt on a socketpair: this process on both ends, its own uid, stable.
@(test)
peer_read_socketpair :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer {posix.close(fds[0]); posix.close(fds[1])}
	p := peer_read(fds[0])
	testing.expect(t, p.ok)
	testing.expect_value(t, p.pid, i32(posix.getpid()))
	testing.expect_value(t, p.euid, own_uid())
	testing.expect(t, peer_allowed(.Adhoc, own_uid(), p) == .Allow)
	testing.expect(t, peer_still(p, peer_read(fds[0])) == .Allow)
}
