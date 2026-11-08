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
	Not_Exec, // the holder's pid, but still the old image: nothing was exec'd (§7.3)
	No_Code, // no code for that process (it exited or exec'd again), or ours is unknown
	Bad_Signature, // its code's signature does not validate
	Wrong_Identity, // signed, but not with our identifier (a swapped binary)
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

// The holder upgrade's keeper (§7.3 step 4): the peer on its socketpair must be the holder's own
// pid running a NEW image (the exec happened: pidversion changed). Then image_allowed decides on
// what that image is. old_pidversion: the image that forked the keeper.
successor_image_allowed :: proc(mode: Mode, own_uid: u32, holder_pid, old_pidversion: i32, peer: Peer) -> Decision {
	if d := peer_allowed(mode, own_uid, peer); d != .Allow do return d
	if holder_pid <= 0 || peer.pid != holder_pid do return .Changed
	if peer.pidversion == old_pidversion do return .Not_Exec
	return .Allow
}

// The upgrade's dry run (§7.3 step 2): the peer must be the child the holder forked for it,
// whatever that child exec'd (image_allowed checks what). Only then does it get dup'd masters.
dry_run_peer_allowed :: proc(mode: Mode, own_uid: u32, child_pid: i32, peer: Peer) -> Decision {
	if d := peer_allowed(mode, own_uid, peer); d != .Allow do return d
	if child_pid <= 0 || peer.pid != child_pid do return .Changed
	return .Allow
}

// A process's (or a file's) code, as the Security framework saw it: from a live audit token
// (what the kernel actually ran), or a file's static code (only an early check: the file can be
// swapped before it runs, S2).
Code_Identity :: struct {
	ok:         bool, // there was code to look at
	valid:      bool, // its signature validates
	identifier: string, // its signing identifier ("dev.deckhand.core")
}

// May this code have the holder's terminals and key? Ad hoc (§5.4, §7.3 4.6): the identifier
// only, which must be our own and validly signed: a guard against accidents (a stray or wrong
// binary), not against a same-user attacker, who can sign anything with any identifier. The
// Developer ID's designated requirement joins here at D0.
image_allowed :: proc(mode: Mode, own, got: Code_Identity) -> Decision {
	if !own.ok || own.identifier == "" do return .No_Code
	if !got.ok do return .No_Code
	if !got.valid do return .Bad_Signature
	switch mode {
	case .Adhoc:
		if got.identifier != own.identifier do return .Wrong_Identity
	}
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

// The app's side of the holder socket (§5.3 "Core → holder"): the holder that WELCOMEd must be
// the process the socket's peer token named at connect. A WELCOME claiming another pid comes from
// something relaying for (or posing as) a holder: refused.
welcome_peer_ok :: proc(at_connect: Peer, welcome_pid: i64) -> Decision {
	if !at_connect.ok do return .No_Peer
	if welcome_pid <= 0 || welcome_pid != i64(at_connect.pid) do return .Changed
	return .Allow
}

// The app at launch, after trying every holder socket in the runtime dir (§6, §7.2): whether
// to launch a holder. answered: some socket took the connection (whatever came after: REFUSED,
// another wire after an update, no WELCOME in time, a bad TAIL), so a holder runs there and
// keeps its sessions. A second holder would leave them invisible while restored tabs start
// duplicates of them (pi --session on the same files), and both would number terminals from 1:
// so never, and the app runs without a holder and says so. Sockets nobody listens on (a holder
// killed with -9) are stale: they do not count.
Holder_Start :: enum {
	Launch, // none runs: launch one
	Without, // none runs and keep_sessions is off: nothing to do
	Warn_Running, // one runs but did not WELCOME: no holder this run, warn
}

holder_start :: proc(answered, keep_sessions: bool) -> Holder_Start {
	if answered do return .Warn_Running
	if !keep_sessions do return .Without
	return .Launch
}

// Whether a handover.json whose MAC verified describes the holder this launch attached to (§7.2,
// §7.7). Anything else is a crash restart (tails, inexact): a file from another holder run (its
// instance, random per run: so also from before a reboot), a newer writer (min_reader), or a
// holder that says the last core did not say goodbye (previous) never gives its snapshots to
// this launch. No boot-time check: kern.boottime moves with wall-clock steps.
Handover_Decision :: enum {
	Use,
	Too_New, // min_reader above what this reader understands
	Other_Holder, // written for another holder run (or before a reboot)
	No_Goodbye, // the holder's WELCOME.previous is not "handover"
}

handover_fresh :: proc(min_reader, our_reader: i64, file_holder, welcome_instance: string, previous: string) -> Handover_Decision {
	if min_reader < 1 || min_reader > our_reader do return .Too_New
	if file_holder == "" || file_holder != welcome_instance do return .Other_Holder
	if previous != "handover" do return .No_Goodbye
	return .Use
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
		p, _ := peer_read_token(fd)
		return p
	}

	// The same, with the whole token (for code_identity_of_token: one read, one process).
	peer_read_token :: proc(fd: posix.FD) -> (Peer, Audit_Token) {
		tok: Audit_Token
		n := u32(size_of(tok))
		if trust_getsockopt(c.int(fd), SOL_LOCAL, LOCAL_PEERTOKEN, &tok, &n) != 0 || n != size_of(tok) do return {}, {}
		return peer_of_token(tok), tok
	}

	peer_of_token :: proc(tok: Audit_Token) -> Peer {
		return Peer{ok = true, pid = i32(tok.val[5]), pidversion = i32(tok.val[7]), euid = tok.val[1]}
	}
} else {
	// Linux has no live token: SO_PEERCRED is the connecting process, fixed at connect (later).
	peer_read :: proc(fd: posix.FD) -> Peer {return {}}
	Audit_Token :: struct {
		val: [8]u32,
	}
	peer_read_token :: proc(fd: posix.FD) -> (Peer, Audit_Token) {return {}, {}}
}

own_uid :: proc() -> u32 {return u32(posix.geteuid())}
