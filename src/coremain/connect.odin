package main

// `deckhand-core-serve connect [--from NAME] [--core ID]` (docs/plans/background-core.md §10.4 M6-A): run on
// this machine by another machine's ssh (its hub link, src/core/machines.odin). It dials this
// machine's core.sock, launching a core as `deckhand --ctl` does when none answers (≤ 15 s),
// checks that the process there is this user's and has the core's code (core_peer_check, as the
// window does), and says the hub hello: framed, "peer":"hub", this run's window token (it runs as
// this user, so it can read run/window.token), NAME, the other machine's (Viewed from <NAME>), and
// ID, its core's (64 hex: the door refuses a core that is its own hub).
// Then it copies bytes, stdin to the socket and the socket to stdout, until either side ends. It
// reads none of them: the hello reply and the frames are the other machine's to read.

import "core:fmt"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../core"

CONNECT_USAGE :: "usage: deckhand-core-serve connect [--from NAME] [--core ID]"

connect_main :: proc(args: []string) -> int {
	from, core_id := "", ""
	for i := 0; i < len(args); i += 2 {
		ok := i + 1 < len(args)
		if ok && args[i] == "--from" do from = args[i + 1]
		else if ok && args[i] == "--core" && core.hex64_ok(args[i + 1]) do core_id = args[i + 1]
		else {
			fmt.eprintln(CONNECT_USAGE)
			return 2
		}
	}
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	when core.TEST_HOOKS do core.autotest_active = core.hook_env(.Script) != ""
	data := core.data_dir()
	if data == "" {
		fmt.eprintln("deckhand-core-serve connect: no data dir (HOME is not set)")
		return 1
	}
	core.home_root = data
	run, rwhy := core.sock_runtime_dir_why(context.temp_allocator)
	if rwhy != "" {
		fmt.eprintln("deckhand-core-serve connect:", rwhy)
		return 1
	}
	path := fmt.tprintf("%s/%s", run, core.CORE_SOCK)
	fd: core.Sock_Fd = -1
	deadline := time.tick_add(time.tick_now(), 15 * time.Second)
	last_launch: time.Tick
	for fd < 0 {
		if s, ok := core.sock_connect(path); ok {
			if core.window_token_read(run) != "" do fd = s
			else do core.sock_close(s) // not a core's (yet): no window token
		}
		if fd >= 0 do break
		if last_launch == {} || time.tick_since(last_launch) >= time.Second {
			last_launch = time.tick_now()
			if _, ok, why := core.core_launch(core.executable_path(), run, data); !ok {
				fmt.eprintln("deckhand-core-serve connect: cannot start the core:", why)
				return 1
			}
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			fmt.eprintln("deckhand-core-serve connect: no core answered within 15 s")
			return 1
		}
		time.sleep(50 * time.Millisecond)
	}
	defer core.sock_close(fd)
	peer, why := core.core_peer_check(fd) // before a byte is sent (B4)
	if why != "" {
		fmt.eprintln("deckhand-core-serve connect:", why)
		return 1
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":"hub","v":%d,"type":"hello","framed":true,"peer":"hub","from":`, core.PROTOCOL_VERSION)
	core.json_quote(&b, from)
	if core_id != "" do fmt.sbprintf(&b, `,"core":"%s"`, core_id)
	fmt.sbprintf(&b, `,"token":"%s"}}`, core.window_token_read(run))
	strings.write_byte(&b, '\n')
	if !core.sock_write_all(fd, b.buf[:]) {
		fmt.eprintln("deckhand-core-serve connect: the core closed the connection")
		return 1
	}
	core.trust_wipe(b.buf[:])
	return connect_relay(fd, peer)
}

// stdin -> fd, fd -> stdout, until either ends. Every read from the core is from the process
// checked before the hello (trust.peer_still).
@(private = "file")
connect_relay :: proc(fd: core.Sock_Fd, peer: $P) -> int {
	buf: [64 << 10]u8
	pfd := [2]posix.pollfd{{fd = 0, events = {.IN}}, {fd = fd, events = {.IN}}}
	for {
		if posix.poll(&pfd[0], 2, -1) < 0 {
			if posix.errno() == .EINTR do continue
			return 1
		}
		if pfd[0].revents != {} {
			n := posix.read(0, &buf[0], len(buf))
			if n < 0 && posix.errno() == .EINTR do continue
			if n <= 0 do return 0 // the other machine went
			if !core.sock_write_all(fd, buf[:n]) do return 0
		}
		if pfd[1].revents != {} {
			n := core.sock_read(fd, buf[:])
			if n <= 0 do return 0 // the core went
			if !core.core_peer_still(fd, peer) {
				fmt.eprintln("deckhand-core-serve connect: the process on core.sock changed")
				return 1
			}
			if !write_all(1, buf[:n]) do return 0
		}
	}
}

@(private = "file")
write_all :: proc(fd: posix.FD, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return false
		rest = rest[n:]
	}
	return true
}
