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
// Every peer is first "the same user" (euid, peer_allowed). Then, where the plan asks for it, its
// code is checked against a designated requirement (DR) built from our OWN signature (§5.4):
//
//   our signature           Mode          a peer's code must have
//   ad hoc (CI, "-")        Adhoc         the expected identifier
//   "Deckhand Self-Signed"  Self_Signed   the expected identifier and our certificate leaf hash
//   a Developer ID (D0)     Developer_Id  §5.3's requirement (Apple anchor, our Team ID, the
//                                         identifier), CS_RUNTIME and no get-task-allow
//
// So D0 is one line (SIGN_IDENTITY_DEFAULT in scripts/sign.sh): the mode follows the signature.
// Ad hoc and self-signed guard against accidents (another user, a stale socket, a stray or wrong
// binary, code signed by anyone else), not against a determined process of the same user: it can
// sign its own code with the self-signed key (codesign uses it without a prompt), or, without the
// hardened runtime, load a library into the genuine binary (§5.4, docs/GUIDE.md).
package trust

import "core:c"
import "core:mem"
import "core:strings"
import "core:sys/posix"

Mode :: enum {
	Adhoc, // signed ad hoc: same user and identifier
	Self_Signed, // "Deckhand Self-Signed": identifier and our certificate leaf hash
	Developer_Id, // from D0: the Apple anchor and our Team ID, hardened runtime
}

// The window's signing identifiers the core accepts (§10.3). The rename's 0.2.1 flip adds
// "dev.deckhand.app" here (docs/DEVELOPING.md "The rename").
WINDOW_IDS :: []string{"dev.pi-desk.app"}
// The core's and the holder's (Deckhand Core.app, scripts/bundle-app.sh).
CORE_IDS :: []string{"dev.deckhand.core"}

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
	Wrong_Signer, // our identifier, but not signed as we are (another certificate, or ad hoc)
	No_Runtime, // Developer_Id: no hardened runtime
	Debuggable, // Developer_Id: get-task-allow
}

// At accept, before reading anything: may this peer talk to us at all?
peer_allowed :: proc(mode: Mode, own_uid: u32, at_accept: Peer) -> Decision {
	if !at_accept.ok do return .No_Peer
	if at_accept.euid != own_uid do return .Other_User // every mode: the code is checked after (peer_code_allowed)
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

// May this code have the holder's terminals and key? The identifier only, in every mode (§5.4,
// §7.3 4.6), which must be our own and validly signed: a guard against accidents (a stray or
// wrong binary), not against a same-user attacker, who can sign anything with any identifier. It
// stays identifier-only because the upgrade's keeper, a forked child that never exec'd, makes it
// (the kernel's csops: Security.framework is not safe after fork); the core checks the new
// image's designated requirement when it reattaches (P9, peer_code_allowed).
image_allowed :: proc(mode: Mode, own, got: Code_Identity) -> Decision {
	if !own.ok || own.identifier == "" do return .No_Code
	if !got.ok do return .No_Code
	if !got.valid do return .Bad_Signature
	if got.identifier != own.identifier do return .Wrong_Identity
	return .Allow
}

// ---- designated requirements (§5.3, §5.4) ----

// Our own signature, read once (own_signature, code_darwin.odin). ok = false: it could not be
// read, and every DR check fails closed (.No_Code).
Own_Signature :: struct {
	ok:         bool,
	mode:       Mode,
	identifier: string,
	leaf_sha1:  string, // 40 lower-case hex digits: the leaf certificate's SHA-1 (not Adhoc)
	team_id:    string, // Developer_Id only
}

// The mode, from what our own signature says. adhoc: the signature has no signer (the
// kSecCodeSignatureAdhoc flag; linker-signed binaries have it too). leaf_sha1: the leaf
// certificate's SHA-1. apple_anchor: our code satisfies `anchor apple generic`. ok = false: a
// signer we cannot describe (no leaf hash, an Apple anchor without a Team ID, a bad Team ID).
mode_of_signature :: proc(adhoc: bool, leaf_sha1, team_id: string, apple_anchor: bool) -> (Mode, bool) {
	if adhoc do return .Adhoc, true
	if !is_hex40(leaf_sha1) do return .Adhoc, false
	if apple_anchor {
		if !team_id_ok(team_id) do return .Adhoc, false
		return .Developer_Id, true
	}
	return .Self_Signed, true
}

// The requirement a peer's code must satisfy: one of ids, signed as we are. "", false when it
// cannot be written (our signature unknown, no ids, or a character the requirement language could
// read as syntax: identifiers are [A-Za-z0-9.-], Team IDs [A-Z0-9]).
peer_requirement :: proc(own: Own_Signature, ids: []string, allocator := context.temp_allocator) -> (string, bool) {
	if !own.ok || len(ids) == 0 do return "", false
	b := strings.builder_make(allocator)
	if own.mode == .Developer_Id {
		if !team_id_ok(own.team_id) do return "", false
		strings.write_string(&b, `anchor apple generic and certificate leaf[subject.OU] = "`)
		strings.write_string(&b, own.team_id)
		strings.write_string(&b, `" and `)
	}
	if len(ids) > 1 do strings.write_byte(&b, '(')
	for id, i in ids {
		if !identifier_ok(id) do return "", false
		if i > 0 do strings.write_string(&b, " or ")
		strings.write_string(&b, `identifier "`)
		strings.write_string(&b, id)
		strings.write_byte(&b, '"')
	}
	if len(ids) > 1 do strings.write_byte(&b, ')')
	if own.mode == .Self_Signed {
		if !is_hex40(own.leaf_sha1) do return "", false
		strings.write_string(&b, ` and certificate leaf = H"`)
		strings.write_string(&b, own.leaf_sha1)
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b), true
}

// A peer's code as the Security framework saw it, by the audit token saved at accept
// (code_check_token, code_darwin.odin).
Code_Check :: struct {
	found:      bool, // there is code for the token (not: it exec'd since, or exited: -67065)
	valid:      bool, // its signature validates (kSecCSStrictValidate)
	meets:      bool, // and it satisfies peer_requirement
	identifier: string,
	flags:      u32, // the kernel's code-signing status for that process (CS_*)
	version:    string, // CFBundleShortVersionString from its signed Info.plist ("" if none)
	status:     i32, // the OSStatus of the check, for logs
}

CS_GET_TASK_ALLOW :: 0x4
CS_RUNTIME :: 0x10000

// May this code talk to us? ids: the identifiers its role may have (WINDOW_IDS, CORE_IDS).
// The same user is peer_allowed's, checked before this.
peer_code_allowed :: proc(own: Own_Signature, ids: []string, got: Code_Check) -> Decision {
	if !own.ok do return .No_Code
	if !got.found do return .No_Code
	if !got.valid do return .Bad_Signature
	known := false
	for id in ids do if got.identifier != "" && got.identifier == id do known = true
	if !known do return .Wrong_Identity
	if !got.meets do return .Wrong_Signer
	if own.mode == .Developer_Id {
		if got.flags & CS_RUNTIME == 0 do return .No_Runtime
		if got.flags & CS_GET_TASK_ALLOW != 0 do return .Debuggable
	}
	return .Allow
}

@(private = "file")
identifier_ok :: proc(s: string) -> bool {
	if s == "" || len(s) > 255 do return false
	for ch in transmute([]u8)s {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-':
		case:
			return false
		}
	}
	return true
}

@(private = "file")
team_id_ok :: proc(s: string) -> bool {
	if len(s) != 10 do return false
	for ch in transmute([]u8)s do if !(ch >= 'A' && ch <= 'Z') && !(ch >= '0' && ch <= '9') do return false
	return true
}

@(private = "file")
is_hex40 :: proc(s: string) -> bool {
	if len(s) != 40 do return false
	for ch in transmute([]u8)s do if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') do return false
	return true
}

// The holder's answer to a HELLO that passed peer_allowed (§5.3 "Core → holder", §5.7).
// attached: another core is attached and has not missed pongs for PONG_TIMEOUT.
// wire_ok: holderwire.negotiate found a common version.
// reserved: the last core named a successor (GOODBYE{handover, successor}, §7.2) and its secret
// is neither used nor expired; secret_ok: this HELLO carries that secret (successor_secret_ok).
// While reserved, only the successor is welcomed; without a reservation a secret, right or
// wrong, changes nothing. Floors are not enforced yet (no versions to compare under ad hoc).
Hello_Answer :: enum {
	Welcome,
	Welcome_Successor, // welcomed, and the secret is used up
	Refuse_Wire,
	Refuse_Attached,
	Refuse_Secret,
}

hello_answer :: proc(attached, wire_ok: bool, reserved := false, secret_ok := false) -> Hello_Answer {
	if !wire_ok do return .Refuse_Wire
	if attached do return .Refuse_Attached
	if reserved do return secret_ok ? .Welcome_Successor : .Refuse_Secret
	return .Welcome
}

// A HELLO's successor secret against the holder's: both 64 hex digits (256 bits), compared in
// constant time. An empty secret never matches.
successor_secret_ok :: proc(want, got: string) -> bool {
	if len(want) != 64 || len(got) != 64 do return false
	diff: u8
	for i in 0 ..< 64 do diff |= want[i] ~ got[i]
	return diff == 0
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
} else when ODIN_OS != .Linux { // Linux: peer_linux.odin
	// another OS (none is built yet): no peer reads, every check fails closed
	peer_read :: proc(fd: posix.FD) -> Peer {return {}}
	Audit_Token :: struct {
		val: [8]u32,
	}
	peer_read_token :: proc(fd: posix.FD) -> (Peer, Audit_Token) {return {}, {}}
	// no code signatures to read: every DR check fails closed
	own_signature :: proc() -> Own_Signature {return {}}
	peer_dr_check :: proc(tok: Audit_Token, ids: []string) -> (Decision, Code_Check) {return .No_Code, {}}
}

own_uid :: proc() -> u32 {return u32(posix.geteuid())}

// Zeroes b in a way the compiler keeps (a secret's bytes once used: the successor secret).
wipe :: proc(b: []u8) {
	if len(b) > 0 do mem.zero_explicit(raw_data(b), len(b))
}
