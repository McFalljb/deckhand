package trust

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

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
	// a successor is named (§7.2): only the HELLO with its secret, until it is used or expires
	testing.expect(t, hello_answer(attached = false, wire_ok = true, reserved = true, secret_ok = false) == .Refuse_Secret)
	testing.expect(t, hello_answer(attached = false, wire_ok = true, reserved = true, secret_ok = true) == .Welcome_Successor)
	testing.expect(t, hello_answer(attached = true, wire_ok = true, reserved = true, secret_ok = true) == .Refuse_Attached)
	testing.expect(t, hello_answer(attached = false, wire_ok = false, reserved = true, secret_ok = true) == .Refuse_Wire)
	// no reservation: a secret, right or wrong, changes nothing
	testing.expect(t, hello_answer(attached = false, wire_ok = true, reserved = false, secret_ok = true) == .Welcome)
}

@(test)
welcome_peer_table :: proc(t: ^testing.T) {
	p := Peer{ok = true, pid = 42, pidversion = 3, euid = 501}
	testing.expect(t, welcome_peer_ok(p, 42) == .Allow)
	testing.expect(t, welcome_peer_ok(p, 43) == .Changed) // relayed or posing
	testing.expect(t, welcome_peer_ok(p, 0) == .Changed)
	testing.expect(t, welcome_peer_ok(p, -42) == .Changed)
	testing.expect(t, welcome_peer_ok(p, 42 + (1 << 32)) == .Changed) // no truncation to i32
	testing.expect(t, welcome_peer_ok(Peer{}, 42) == .No_Peer)
}

@(test)
handover_fresh_table :: proc(t: ^testing.T) {
	// no boot time: the holder's instance id is per holder run, so it implies the boot
	// (kern.boottime moves with wall-clock steps)
	cases := []struct {
		min_reader, ours: i64,
		holder, instance: string,
		previous:         string,
		want:             Handover_Decision,
	} {
		{1, 1, "ab", "ab", "handover", .Use},
		{2, 1, "ab", "ab", "handover", .Too_New},
		{0, 1, "ab", "ab", "handover", .Too_New}, // a missing min_reader is not "any"
		{1, 2, "ab", "ab", "handover", .Use},
		{1, 1, "ab", "cd", "handover", .Other_Holder},
		{1, 1, "", "", "handover", .Other_Holder}, // an empty id never matches
		{1, 1, "ab", "ab", "crash", .No_Goodbye},
		{1, 1, "ab", "ab", "none", .No_Goodbye},
		{1, 1, "ab", "ab", "upgrade", .No_Goodbye},
	}
	for c, i in cases {
		got := handover_fresh(c.min_reader, c.ours, c.holder, c.instance, c.previous)
		testing.expectf(t, got == c.want, "case %d: %v, want %v", i, got, c.want)
	}
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

@(test)
holder_start_table :: proc(t: ^testing.T) {
	cases := []struct {
		answered, keep: bool,
		want:           Holder_Start,
	} {
		{false, true, .Launch},
		{false, false, .Without},
		{true, true, .Warn_Running}, // a holder runs: never a second one
		{true, false, .Warn_Running}, // its sessions are from an earlier run: still say so
	}
	for c, i in cases {
		got := holder_start(c.answered, c.keep)
		testing.expectf(t, got == c.want, "case %d: %v, want %v", i, got, c.want)
	}
}

// The keeper's gate (§7.3 step 4): only the holder's own pid, after an exec (new pidversion).
@(test)
successor_image_table :: proc(t: ^testing.T) {
	me :: u32(501)
	cases := []struct {
		peer: Peer,
		want: Decision,
	} {
		{Peer{ok = true, pid = 100, pidversion = 8, euid = me}, .Allow}, // the holder, exec'd
		{Peer{ok = true, pid = 100, pidversion = 7, euid = me}, .Not_Exec}, // the old image itself
		{Peer{ok = true, pid = 101, pidversion = 8, euid = me}, .Changed}, // another process
		{Peer{ok = true, pid = 100, pidversion = 8, euid = 0}, .Other_User},
		{Peer{}, .No_Peer}, // it exited (EINVAL)
	}
	for c, i in cases do testing.expectf(t, successor_image_allowed(.Adhoc, me, 100, 7, c.peer) == c.want, "case %d: %v", i, successor_image_allowed(.Adhoc, me, 100, 7, c.peer))
	// a holder pid we do not know never matches
	testing.expect(t, successor_image_allowed(.Adhoc, me, 0, 7, Peer{ok = true, pid = 0, pidversion = 8, euid = me}) == .Changed)
}

// The dry run's gate: the child we forked, whatever it exec'd.
@(test)
dry_run_peer_table :: proc(t: ^testing.T) {
	p := Peer{ok = true, pid = 42, pidversion = 9, euid = 501}
	testing.expect(t, dry_run_peer_allowed(.Adhoc, 501, 42, p) == .Allow)
	testing.expect(t, dry_run_peer_allowed(.Adhoc, 501, 43, p) == .Changed)
	testing.expect(t, dry_run_peer_allowed(.Adhoc, 501, 0, p) == .Changed)
	testing.expect(t, dry_run_peer_allowed(.Adhoc, 502, 42, p) == .Other_User)
	testing.expect(t, dry_run_peer_allowed(.Adhoc, 501, 42, Peer{}) == .No_Peer)
}

// What ran (or will run) must carry our own signing identifier, with a valid signature (ad hoc:
// identifier only, §5.4, §7.3 4.6).
@(test)
image_allowed_table :: proc(t: ^testing.T) {
	own := Code_Identity{ok = true, valid = true, identifier = "dev.deckhand.core"}
	cases := []struct {
		own, got: Code_Identity,
		want:     Decision,
	} {
		{own, own, .Allow},
		{own, Code_Identity{ok = true, valid = true, identifier = "dev.deckhand.evil"}, .Wrong_Identity},
		{own, Code_Identity{ok = true, valid = true, identifier = "dev.deckhand.core.x"}, .Wrong_Identity},
		{own, Code_Identity{ok = true, valid = false, identifier = "dev.deckhand.core"}, .Bad_Signature},
		{own, Code_Identity{ok = true, valid = true, identifier = ""}, .Wrong_Identity},
		{own, Code_Identity{}, .No_Code}, // no code for the token (it exec'd again, or exited)
		{Code_Identity{}, own, .No_Code}, // our own identity unknown: nothing passes
		{Code_Identity{ok = true, valid = true, identifier = ""}, Code_Identity{ok = true, valid = true, identifier = ""}, .No_Code},
	}
	for c, i in cases do testing.expectf(t, image_allowed(.Adhoc, c.own, c.got) == c.want, "case %d: %v", i, image_allowed(.Adhoc, c.own, c.got))
}

// The live reads: our own token and code, and a file's static code.
@(test)
self_identity_reads :: proc(t: ^testing.T) {
	me := self_peer()
	testing.expect(t, me.ok)
	testing.expect_value(t, me.pid, i32(posix.getpid()))
	testing.expect_value(t, me.euid, own_uid())
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer posix.close(fds[0])
	defer posix.close(fds[1])
	b := [1]u8{1}
	posix.write(fds[1], &b[0], 1)
	p, tok := peer_read_token(fds[0])
	testing.expect(t, p.ok && p.pid == me.pid && p.pidversion == me.pidversion && p.euid == me.euid)
	when ODIN_OS == .Linux {
		// no code signing on Linux (§8.3): the same user is the whole check
		d, _ := peer_dr_check(tok, CORE_IDS)
		testing.expect_value(t, d, Decision.Allow)
		testing.expect_value(t, peer_still(p, peer_read(fds[0])), Decision.Allow)
	} else {
		// the test binary is linker-signed: some identifier, and the token's code is ours
		own := code_identity_self()
		testing.expect(t, own.ok && own.valid && own.identifier != "", "own code identity")
		got := code_identity_of_token(tok)
		testing.expectf(t, got.ok && got.identifier == own.identifier, "token code %v, own %v", got, own)
		testing.expect(t, image_allowed(.Adhoc, own, got) == .Allow)
		// a file: a system binary is Apple's, not ours; a missing file has no code
		sh := code_identity_of_file("/bin/sh")
		testing.expect(t, sh.ok && sh.identifier == "com.apple.sh", "/bin/sh")
		testing.expect(t, image_allowed(.Adhoc, own, sh) == .Wrong_Identity)
		testing.expect(t, !code_identity_of_file("/nonexistent/deckhand-core").ok)
	}
}

@(test)
successor_secret_compare :: proc(t: ^testing.T) {
	a := "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
	testing.expect(t, successor_secret_ok(a, a))
	testing.expect(t, !successor_secret_ok(a, "00112233445566778899aabbccddeeff00112233445566778899aabbccddeefe"))
	testing.expect(t, !successor_secret_ok(a, a[:62]))
	testing.expect(t, !successor_secret_ok(a, ""))
	testing.expect(t, !successor_secret_ok("", ""), "no secret is never a match")
	testing.expect(t, !successor_secret_ok(a[:10], a[:10]), "only 256-bit secrets")
}

// ---- designated requirements (§5.4): the three modes as tables ----

@(test)
mode_of_signature_table :: proc(t: ^testing.T) {
	leaf :: "0123456789abcdef0123456789abcdef01234567"
	cases := []struct {
		adhoc:  bool,
		leaf:   string,
		team:   string,
		apple:  bool,
		want:   Mode,
		wantok: bool,
	} {
		{true, "", "", false, .Adhoc, true}, // ad hoc and linker-signed
		{true, leaf, "ABCDE12345", true, .Adhoc, true}, // the ad-hoc flag wins: no signer to trust
		{false, leaf, "", false, .Self_Signed, true},
		{false, leaf, "ABCDE12345", true, .Developer_Id, true},
		{false, leaf, "ABCDE12345", false, .Self_Signed, true}, // a self-signed cert with an OU is still self-signed
		{false, leaf, "", true, .Adhoc, false}, // Apple-anchored without a Team ID: not ours to describe
		{false, leaf, "abcde12345", true, .Adhoc, false}, // a Team ID is [A-Z0-9]{10}
		{false, leaf, "ABCDE\"1234", true, .Adhoc, false},
		{false, "", "", false, .Adhoc, false}, // signed, but no leaf certificate read
		{false, "0123", "", false, .Adhoc, false},
		{false, "0123456789ABCDEF0123456789ABCDEF01234567", "", false, .Adhoc, false}, // lower-case hex only
	}
	for c, i in cases {
		m, ok := mode_of_signature(c.adhoc, c.leaf, c.team, c.apple)
		testing.expectf(t, ok == c.wantok && (!ok || m == c.want), "case %d: %v %v", i, m, ok)
	}
}

@(test)
peer_requirement_table :: proc(t: ^testing.T) {
	leaf :: "0123456789abcdef0123456789abcdef01234567"
	adhoc := Own_Signature{ok = true, mode = .Adhoc, identifier = "dev.deckhand.core"}
	self := Own_Signature{ok = true, mode = .Self_Signed, identifier = "dev.deckhand.core", leaf_sha1 = leaf}
	devid := Own_Signature{ok = true, mode = .Developer_Id, identifier = "dev.deckhand.core", leaf_sha1 = leaf, team_id = "ABCDE12345"}
	cases := []struct {
		own:  Own_Signature,
		ids:  []string,
		want: string, // "" = refused
	} {
		{adhoc, {"dev.deckhand.core"}, `identifier "dev.deckhand.core"`},
		{self, {"dev.deckhand.core"}, `identifier "dev.deckhand.core" and certificate leaf = H"` + leaf + `"`},
		{self, {"dev.pi-desk.app", "dev.deckhand.app"}, `(identifier "dev.pi-desk.app" or identifier "dev.deckhand.app") and certificate leaf = H"` + leaf + `"`},
		{devid, {"dev.deckhand.core"}, `anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and identifier "dev.deckhand.core"`},
		{devid, {"a", "b"}, `anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and (identifier "a" or identifier "b")`},
		{Own_Signature{}, {"dev.deckhand.core"}, ""}, // our own signature unknown
		{self, {}, ""}, // nobody
		{self, {""}, ""},
		{self, {`x" or anchor apple`}, ""}, // no requirement-language syntax through an identifier
		{self, {"dev.deckhand.core", "a b"}, ""},
		{Own_Signature{ok = true, mode = .Self_Signed, leaf_sha1 = "bad"}, {"x"}, ""},
		{Own_Signature{ok = true, mode = .Developer_Id, leaf_sha1 = leaf, team_id = `X" or "`}, {"x"}, ""},
	}
	for c, i in cases {
		got, ok := peer_requirement(c.own, c.ids)
		testing.expectf(t, ok == (c.want != "") && got == c.want, "case %d: %q %v", i, got, ok)
	}
}

@(test)
peer_code_allowed_table :: proc(t: ^testing.T) {
	leaf :: "0123456789abcdef0123456789abcdef01234567"
	ids := []string{"dev.pi-desk.app", "dev.deckhand.app"}
	good := Code_Check{found = true, valid = true, meets = true, identifier = "dev.pi-desk.app"}
	cases := []struct {
		mode: Mode,
		got:  Code_Check,
		want: Decision,
	} {
		{.Adhoc, good, .Allow},
		{.Self_Signed, good, .Allow},
		{.Self_Signed, Code_Check{found = true, valid = true, meets = true, identifier = "dev.deckhand.app"}, .Allow}, // the flip's id
		{.Self_Signed, Code_Check{found = true, valid = true, meets = false, identifier = "dev.pi-desk.app"}, .Wrong_Signer}, // ad hoc, or another certificate
		{.Self_Signed, Code_Check{found = true, valid = true, meets = true, identifier = "dev.deckhand.core"}, .Wrong_Identity}, // not a window
		{.Self_Signed, Code_Check{found = true, valid = true, meets = true, identifier = ""}, .Wrong_Identity},
		{.Self_Signed, Code_Check{found = true, valid = false, identifier = "dev.pi-desk.app"}, .Bad_Signature},
		{.Self_Signed, Code_Check{found = false, status = -67065}, .No_Code}, // exec'd since
		{.Adhoc, Code_Check{found = true, valid = true, meets = false, identifier = "dev.pi-desk.app"}, .Wrong_Signer},
		// Developer_Id: the hardened runtime, and never debuggable
		{.Developer_Id, Code_Check{found = true, valid = true, meets = true, identifier = "dev.pi-desk.app", flags = CS_RUNTIME}, .Allow},
		{.Developer_Id, good, .No_Runtime},
		{.Developer_Id, Code_Check{found = true, valid = true, meets = true, identifier = "dev.pi-desk.app", flags = CS_RUNTIME | CS_GET_TASK_ALLOW}, .Debuggable},
		{.Developer_Id, Code_Check{found = true, valid = true, meets = false, identifier = "dev.pi-desk.app", flags = CS_RUNTIME}, .Wrong_Signer},
		// the runtime flags only matter under a Developer ID (S2: ad hoc and self-signed can't load CEF with it)
		{.Self_Signed, Code_Check{found = true, valid = true, meets = true, identifier = "dev.pi-desk.app", flags = CS_GET_TASK_ALLOW}, .Allow},
	}
	for c, i in cases {
		own := Own_Signature{ok = true, mode = c.mode, identifier = "dev.deckhand.core", leaf_sha1 = leaf, team_id = "ABCDE12345"}
		got := peer_code_allowed(own, ids, c.got)
		testing.expectf(t, got == c.want, "case %d: %v, want %v", i, got, c.want)
	}
	testing.expect(t, peer_code_allowed(Own_Signature{}, ids, good) == .No_Code, "our own signature unknown: nothing passes")
	testing.expect(t, peer_code_allowed(Own_Signature{ok = true}, nil, good) == .Wrong_Identity, "no identifiers: nothing passes")
}

// The identifier tables (§10.3): one line each to change.
@(test)
identifier_tables :: proc(t: ^testing.T) {
	testing.expect_value(t, len(WINDOW_IDS), 1)
	testing.expect_value(t, WINDOW_IDS[0], "dev.pi-desk.app")
	testing.expect_value(t, len(CORE_IDS), 1)
	testing.expect_value(t, CORE_IDS[0], "dev.deckhand.core")
}

// The real Security framework on this (linker-signed: ad hoc) test binary: its own signature is
// Adhoc, a socketpair peer (ourselves) passes with our identifier and fails with another, and a
// token saved before its process exec'd finds no code (-67065).
@(test)
peer_dr_check_real :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	else {
		own := own_signature()
		if !testing.expect(t, own.ok && own.mode == .Adhoc && own.identifier != "", "own signature") do return
		testing.expect(t, own_signature().identifier == own.identifier, "read once, the same")
		fds: [2]posix.FD
		testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
		b := [1]u8{1}
		posix.write(fds[1], &b[0], 1)
		_, tok := peer_read_token(fds[0])
		d, got := peer_dr_check(tok, {own.identifier})
		testing.expectf(t, d == .Allow, "ourselves: %v %v", d, got)
		testing.expect_value(t, got.identifier, own.identifier)
		d2, _ := peer_dr_check(tok, {"dev.deckhand.other"})
		testing.expect_value(t, d2, Decision.Wrong_Identity)
		posix.close(fds[0])
		posix.close(fds[1])

		// a child that writes, then execs /bin/sleep: the token from before the exec has no code
		testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
		defer posix.close(fds[0])
		pid := posix.fork()
		if pid == 0 {
			posix.dup2(fds[1], 3)
			argv := []cstring{"/bin/sh", "-c", "printf x >&3; read y <&3; exec /bin/sleep 5", nil}
			posix.execv(argv[0], raw_data(argv))
			posix._exit(127)
		}
		posix.close(fds[1])
		defer {
			posix.kill(pid, .SIGKILL)
			st: i32
			posix.waitpid(pid, &st, {})
		}
		one: [1]u8
		testing.expect(t, posix.read(fds[0], &one[0], 1) == 1)
		before, btok := peer_read_token(fds[0])
		testing.expect(t, before.ok && before.pid == i32(pid))
		sh_d, sh := peer_dr_check(btok, {own.identifier})
		// (/bin/sh is a trampoline: by now it may be bash)
		testing.expectf(t, sh_d == .Wrong_Identity && strings.has_prefix(sh.identifier, "com.apple."), "/bin/sh: %v %v", sh_d, sh)
		posix.write(fds[0], raw_data(string("go\n")), 3)
		for _ in 0 ..< 500 {
			if now := peer_read(fds[0]); now.ok && now.pidversion != before.pidversion do break
			time.sleep(2 * time.Millisecond)
		}
		gone := code_check_token(btok, fmt.tprintf(`identifier "%s"`, sh.identifier))
		testing.expectf(t, !gone.found && gone.status == errSecCSNoSuchCode, "exec'd since: %v", gone)
		testing.expect(t, peer_code_allowed(own, {sh.identifier}, gone) == .No_Code)
	}
}
