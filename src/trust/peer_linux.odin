#+build linux
package trust

// Reading a peer on Linux (docs/plans/background-core.md §8.3, §10.4 M6-L1). SO_PEERCRED gives
// the process that called connect (or socketpair), fixed then: no live token, no pidversion,
// and no code signatures. So on Linux trust is the same user only. peer_allowed still checks the
// euid; peer_still holds by construction (the credentials never change); peer_dr_check allows,
// as the euid was checked before it. A process of the same user is trusted, as it is on macOS
// against a determined same-user process (§5.4).
//
// The session holder (M6-L3) asks about code too: may this binary have the terminals (an UPGRADE's
// path, the supervisor's core, the image a keeper hands them to)? With no signatures the answer is
// an anti-accident check on the file: a regular ELF file of ours that no other user may write
// (code_identity_of_file). Every such file has the core's identifier, so image_allowed passes it;
// another user's file (root's /bin/sh), a world-writable one or a non-ELF one does not.

import "core:fmt"
import "core:strings"
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

// The "token" carries the pid (val[5], as macOS's audit token does): code_identity_of_token reads
// that process's binary.
peer_read_token :: proc(fd: posix.FD) -> (Peer, Audit_Token) {
	p := peer_read(fd)
	tok: Audit_Token
	if p.ok do tok.val[5] = u32(p.pid)
	return p, tok
}

// This process as a peer would see it.
self_peer :: proc() -> Peer {return Peer{ok = true, pid = i32(posix.getpid()), euid = own_uid()}}

// No signature to read: Own_Signature{} (ok false). Only the holder's install asks (M6-L3).
own_signature :: proc() -> Own_Signature {return {}}

// No code signing on Linux: the caller checked the same user first (peer_allowed), and that is
// the check (§8.3).
peer_dr_check :: proc(tok: Audit_Token, ids: []string) -> (Decision, Code_Check) {return .Allow, {}}

// ---- code (the holder's image checks, image_allowed) ----

// This process's binary.
code_identity_self :: proc() -> Code_Identity {return code_identity_of_file("/proc/self/exe")}

// The binary the token's process runs now (/proc/<pid>/exe: the file the kernel ran, even if its
// path was swapped or removed since).
code_identity_of_token :: proc(tok: Audit_Token) -> Code_Identity {
	pid := tok.val[5]
	if pid == 0 do return {}
	return code_identity_of_file(fmt.tprintf("/proc/%d/exe", pid))
}

// A file as the holder's code (links followed): a regular file (else ok false), owned by us
// (else no identifier), not writable by other users and an ELF image (else not valid). The file
// opened is the one checked (fstat on it; O_NONBLOCK: a FIFO never blocks the open). Never
// executed or changed here.
code_identity_of_file :: proc(path: string) -> Code_Identity {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC, .NONBLOCK})
	if fd < 0 do return {}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) do return {}
	if u32(st.st_uid) != own_uid() do return {ok = true, valid = true}
	if .IWOTH in st.st_mode do return {ok = true}
	magic: [4]u8
	if posix.read(fd, &magic[0], 4) != 4 || string(magic[:]) != "\x7fELF" do return {ok = true}
	return {ok = true, valid = true, identifier = CORE_IDS[0]}
}
