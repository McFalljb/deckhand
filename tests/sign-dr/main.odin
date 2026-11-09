// The checker tests/scripts/sign-dr.sh runs (docs/plans/background-core.md §5.4, §10.3 M4-A): the
// real designated-requirement check (src/trust) of a peer over a socketpair, by this process's own
// signature, as the script signed it.
//
//   sign-dr-check mode                 prints our own mode ("Self_Signed", ...)
//   sign-dr-check req ID               prints the requirement a peer with identifier ID must meet
//   sign-dr-check peer ID PEER         runs PEER with the socket as fd 3; prints the decision on
//                                      its code ("Allow", "Wrong_Signer", ...), then its version
//   sign-dr-check exec ID PEER         the same, then tells PEER to exec /bin/sleep and checks the
//                                      token saved before that again: prints its decision and status
//
// PEER (sign-dr.sh's peer.c): writes one byte on fd 3, reads one, then execs argv[1] if given.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../../src/trust"

main :: proc() {
	args := os.args[1:]
	if len(args) == 1 && args[0] == "mode" {
		own := trust.own_signature()
		fmt.println(own.ok ? fmt.tprint(own.mode) : "unreadable")
		return
	}
	if len(args) == 2 && args[0] == "req" {
		req, ok := trust.peer_requirement(trust.own_signature(), {args[1]})
		if !ok do os.exit(1)
		fmt.println(req)
		return
	}
	if len(args) != 3 || (args[0] != "peer" && args[0] != "exec") {
		fmt.eprintln("usage: sign-dr-check mode | req ID | peer ID PEER | exec ID PEER")
		os.exit(2)
	}
	ids := []string{args[1]}
	fds: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, .IP, &fds) != .OK do os.exit(1)
	peer := strings.clone_to_cstring(args[2])
	pid := posix.fork()
	if pid == 0 {
		posix.dup2(fds[1], 3)
		argv := []cstring{peer, args[0] == "exec" ? "/bin/sleep" : nil, args[0] == "exec" ? "5" : nil, nil}
		posix.execv(peer, raw_data(argv))
		posix._exit(127)
	}
	posix.close(fds[1])
	defer {
		posix.kill(pid, .SIGKILL)
		st: i32
		posix.waitpid(pid, &st, {})
	}
	one: [1]u8
	if posix.read(fds[0], &one[0], 1) != 1 {
		fmt.println("no byte from the peer")
		os.exit(1)
	}
	before, tok := trust.peer_read_token(fds[0])
	d, got := trust.peer_dr_check(tok, ids)
	fmt.println(d, got.version)
	if args[0] == "peer" do return
	posix.write(fds[0], &one[0], 1)
	for _ in 0 ..< 1000 {
		if now := trust.peer_read(fds[0]); now.ok && now.pidversion != before.pidversion do break
		time.sleep(2 * time.Millisecond)
	}
	d2, got2 := trust.peer_dr_check(tok, ids)
	fmt.println(d2, got2.status)
}
