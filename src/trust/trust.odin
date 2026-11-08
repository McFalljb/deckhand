// Who may talk to whom (docs/plans/background-core.md §5.3, §5.4). Every trust decision the
// session holder, its launcher and the app make about a socket peer is a pure proc here, so the
// rules can be read in one place and are table-tested (trust_test.odin). The getsockopt calls
// that feed them are at the bottom (peer_read).
//
// The facts (S2): LOCAL_PEERTOKEN reports the process that LAST did I/O on the peer socket,
// re-resolved on every call: after an exec it is the new image (same pid, new pidversion),
// after the fd went to a forked child it is that child, and once that process has exited the
// call fails (EINVAL). So a peer is read at accept, before any byte is read, and again before
// every read is acted on; any change of pid or pidversion, or a failed read, drops the peer.
//
// Ad hoc (no Developer ID yet, decision 5): there is no team identity to check, so identity is
// "the same user" (euid). That guards against accidents (another user, a stale socket, an fd
// that leaked into a child), not against a determined process of the same user (§5.4). The
// designated-requirement checks join here at D0, as a second Mode.
package trust

import "core:c"
import "core:sys/posix"

Mode :: enum {
	Adhoc, // same user only (every build until D0)
}

// A socket peer as getsockopt(LOCAL_PEERTOKEN) saw it at one moment.
Peer :: struct {
	ok:         bool, // false: the call failed (the last process to use the socket is gone)
	pid:        i32,
	pidversion: i32, // changes at every exec of that pid
	euid:       u32,
}

Decision :: enum {
	Allow,
	No_Peer, // the token could not be read
	Other_User, // a different effective user
	Changed, // not the process (or image) that was checked at accept
}

// At accept, before reading anything: may this peer talk to us at all?
peer_allowed :: proc(mode: Mode, own_uid: u32, at_accept: Peer) -> Decision {
	if !at_accept.ok do return .No_Peer
	switch mode {
	case .Adhoc:
		if at_accept.euid != own_uid do return .Other_User
	}
	return .Allow
}

// Before acting on bytes read from a peer that passed peer_allowed: still the same process and
// image? (An exec after connecting changes pidversion; an fd handed to a child changes pid.)
peer_still :: proc(at_accept, now: Peer) -> Decision {
	if !now.ok do return .No_Peer
	if now.pid != at_accept.pid || now.pidversion != at_accept.pidversion do return .Changed
	if now.euid != at_accept.euid do return .Changed
	return .Allow
}

// The launcher's ready socket (§6, P8): the peer must be the child it launched (the detached
// process's pid, which it learnt from the job) and pass peer_allowed, before it is sent the
// environment (which carries tokens) or a secret.
ready_peer_allowed :: proc(mode: Mode, own_uid: u32, launched_pid: i32, at_accept: Peer) -> Decision {
	if d := peer_allowed(mode, own_uid, at_accept); d != .Allow do return d
	if launched_pid <= 0 || at_accept.pid != launched_pid do return .Changed
	return .Allow
}

// The holder's answer to a HELLO that passed peer_allowed (§5.3 "Core → holder", §5.7).
// attached: another core is attached and has not missed pongs for PONG_TIMEOUT.
// wire_ok: holderwire.negotiate found a common version.
// Floors and successor secrets are not enforced yet (no versions to compare under ad hoc, and
// PR D's updater is the first successor); an unknown or wrong secret is ignored, not trusted.
Hello_Answer :: enum {
	Welcome,
	Refuse_Wire,
	Refuse_Attached,
}

hello_answer :: proc(attached, wire_ok: bool) -> Hello_Answer {
	if !wire_ok do return .Refuse_Wire
	if attached do return .Refuse_Attached
	return .Welcome
}

// The HMAC key (state-file authentication, §5.3 B3) goes only in a WELCOME, so only to a core
// that passed peer_allowed and hello_answer on this connection.

// ---- reading a peer ----

when ODIN_OS == .Darwin {
	SOL_LOCAL :: 0
	LOCAL_PEERTOKEN :: 0x006

	// audit_token_t: val[1] euid, val[5] pid, val[7] pidversion (bsm/libbsm.h's accessors)
	Audit_Token :: struct {
		val: [8]u32,
	}

	foreign import libc "system:System"
	@(default_calling_convention = "c")
	foreign libc {
		@(link_name = "getsockopt")
		trust_getsockopt :: proc(fd: c.int, level: c.int, name: c.int, value: rawptr, len: ^u32) -> c.int ---
	}

	// The peer of a connected Unix socket, now.
	peer_read :: proc(fd: posix.FD) -> Peer {
		tok: Audit_Token
		n := u32(size_of(tok))
		if trust_getsockopt(c.int(fd), SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &n) != 0 || n != size_of(tok) do return {}
		return Peer{ok = true, pid = i32(tok.val[5]), pidversion = i32(tok.val[7]), euid = tok.val[1]}
	}
} else {
	// Linux has no live token: SO_PEERCRED is the connecting process, fixed at connect (later).
	peer_read :: proc(fd: posix.FD) -> Peer {return {}}
}

own_uid :: proc() -> u32 {return u32(posix.geteuid())}
