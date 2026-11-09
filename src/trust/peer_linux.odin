#+build linux
package trust

// Reading a peer on Linux (docs/plans/background-core.md §8.3, §10.4 M6-L1). SO_PEERCRED gives
// the process that called connect (or socketpair), fixed then: no live token, no pidversion,
// and no code signatures. So on Linux trust is the same user only. peer_allowed still checks the
// euid; peer_still holds by construction (the credentials never change); peer_dr_check allows,
// as the euid was checked before it. A process of the same user is trusted, as it is on macOS
// against a determined same-user process (§5.4); there is no "stray binary" guard.

import "core:sys/posix"

SO_PEERCRED :: 17 // asm-generic/socket.h: x86_64 and aarch64

// No audit token on Linux: the type is here so the callers' signatures stay the same.
Audit_Token :: struct {
	val: [8]u32,
}

// The peer of a connected Unix socket: its credentials at connect.
peer_read :: proc(fd: posix.FD) -> Peer {
	cred: struct {
		pid:      i32,
		uid, gid: u32,
	}
	n := posix.socklen_t(size_of(cred))
	if posix.getsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_PEERCRED), &cred, &n) != .OK || n != size_of(cred) || cred.pid <= 0 do return {}
	return Peer{ok = true, pid = cred.pid, euid = cred.uid}
}

peer_read_token :: proc(fd: posix.FD) -> (Peer, Audit_Token) {return peer_read(fd), {}}

// This process as a peer would see it.
self_peer :: proc() -> Peer {return Peer{ok = true, pid = i32(posix.getpid()), euid = own_uid()}}

// No signature to read: Own_Signature{} (ok false). Only the holder's install asks (M6-L3).
own_signature :: proc() -> Own_Signature {return {}}

// No code signing on Linux: the caller checked the same user first (peer_allowed), and that is
// the check (§8.3).
peer_dr_check :: proc(tok: Audit_Token, ids: []string) -> (Decision, Code_Check) {return .Allow, {}}

