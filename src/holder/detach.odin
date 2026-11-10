package holder

// The holder's side of its launch (docs/plans/background-core.md §6, as the S2 spike proved it).
// The launcher (src/core/launchd_darwin.odin) bootstraps a launchd job whose program is
// `deckhand-core __detach hold-args...`:
//
//   __detach    the job's own process. It forks and exits; the child calls setsid and execs
//               `deckhand-core hold hold-args...`. The fork is required: the launcher's bootout
//               kills the job's own process, never a forked child in a session of its own.
//   --ready P   hold_main calls ready_handshake(P) before it serves: wait until launchd is our
//               parent (the job's process has exited), connect to the launcher's ready socket,
//               send our pid, receive the environment, make it ours, ack. The launcher checks
//               that the pid is the process on the socket, that its parent is launchd and that
//               it runs the binary it launched (trust.ready_peer_allowed), and boots the job out
//               before it sends the environment (it carries tokens).
//
// The wire, both ways plain bytes: holder → "<pid>\n"; launcher → the environment as
// NUL-terminated "KEY=VALUE" entries, then one more NUL (an empty entry ends it); holder → "ok\n".
// A core launched as a handover's successor (deckhand-core-serve) also gets the holder's successor
// secret as the entry READY_SECRET_KEY: taken out, never applied to the environment.
// SIGPIPE: the socket has SO_NOSIGPIPE, so a launcher that died mid-handshake is an error here,
// not a signal (S2: the waiting child died of SIGPIPE).

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../trust"

// How long the handshake waits for each step (launchd to adopt us, the launcher's environment).
READY_TIMEOUT :: 10 * time.Second
// The environment's cap (the launcher's is far smaller: a login environment).
READY_ENV_MAX :: 1 << 20
SUN_PATH_MAX :: 103 // sun_path is 104 bytes, its NUL included
READY_SECRET_KEY :: "DECKHAND_SUCCESSOR_SECRET" // the ready entry with a successor secret (never in our environment)

// `deckhand-core __detach hold-args...` (the launchd job): 0 in the job's process once the child
// is forked; the child never returns (exec), or exits 127.
detach_main :: proc(args: []string) -> int {
	self := os.args[0] // launchd runs ProgramArguments[0]: the absolute path the launcher gave
	if !strings.has_prefix(self, "/") {
		fmt.eprintln("deckhand-core __detach: not started by its absolute path:", self)
		return 2
	}
	// a relative --ready is the job's WorkingDirectory's (the launcher's temp dir, which it
	// removes): made absolute here, so the holder can leave that dir for "/"
	cwd, _ := os.get_working_directory(context.temp_allocator)
	leave := true
	argv := make([dynamic]cstring, context.temp_allocator)
	append(&argv, strings.clone_to_cstring(self, context.temp_allocator), "hold")
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == "--ready" && i + 1 < len(args) && !strings.has_prefix(args[i + 1], "/") {
			abs := fmt.tprintf("%s/%s", strings.trim_right(cwd, "/"), args[i + 1])
			if cwd == "" || len(abs) > SUN_PATH_MAX {
				leave = false // too long for sun_path: connect relative, from here
				abs = args[i + 1]
			}
			append(&argv, "--ready", strings.clone_to_cstring(abs, context.temp_allocator))
			i += 1
			continue
		}
		append(&argv, strings.clone_to_cstring(a, context.temp_allocator))
	}
	append(&argv, nil)
	pid := posix.fork()
	if pid < 0 {
		fmt.eprintln("deckhand-core __detach: fork:", posix.strerror(posix.errno()))
		return 1
	}
	if pid > 0 do return 0 // the job's process: done (launchd sees it exit; KeepAlive is off)
	posix.setsid()
	if leave do posix.chdir("/")
	posix.execv(argv[0], raw_data(argv[:]))
	fmt.eprintln("deckhand-core __detach: exec:", posix.strerror(posix.errno()))
	_exit(127)
}

// The holder's half of the launcher's handshake (see the top). env: what the launcher sent,
// already applied (the process environment is replaced by it); ok = false: no launcher, a peer
// that is not ours, a timeout or a short read (logged to stderr). Called by hold_main for
// `--ready PATH`; the holder should exit on failure (the launcher falls back to a direct spawn).
ready_handshake :: proc(path: string, secret: ^[64]u8 = nil) -> (env: []string, ok: bool) {
	// the job's process exits at once after the fork; until launchd adopts us the launcher's
	// parent check would fail
	deadline := time.tick_now()._nsec + i64(READY_TIMEOUT)
	for posix.getppid() != 1 {
		if time.tick_now()._nsec > deadline {
			fmt.eprintln("deckhand-core: ready: never adopted by launchd (parent", posix.getppid(), ")")
			return nil, false
		}
		time.sleep(2 * time.Millisecond)
	}
	fd, cok := ready_connect(path)
	if !cok {
		fmt.eprintln("deckhand-core: ready: cannot connect to", path, posix.strerror(posix.errno()))
		return nil, false
	}
	defer posix.close(fd)
	// the launcher: the same user (its ready socket is in a 0700 dir of ours, this is the check)
	if d := trust.peer_allowed(.Adhoc, trust.own_uid(), trust.peer_read(fd)); d != .Allow {
		fmt.eprintln("deckhand-core: ready: refused the launcher:", d)
		return nil, false
	}
	env, ok = ready_exchange(fd, READY_TIMEOUT)
	if !ok do return nil, false
	os.clear_env()
	for e in env {
		k, _, v := strings.partition(e, "=")
		if k == READY_SECRET_KEY {
			if secret != nil && len(v) == len(secret) do copy(secret[:], v)
			trust.wipe(transmute([]u8)e)
			continue
		}
		// the holder's own setenv (sys_darwin.odin), not os.set_env: two foreign signatures for one
		// libc symbol in a package panic the compiler's LLVM backend at -o:speed
		if k != "" do setenv(strings.clone_to_cstring(k, context.temp_allocator), strings.clone_to_cstring(v, context.temp_allocator), 1)
	}
	if !ready_send(fd, "ok\n") {
		fmt.eprintln("deckhand-core: ready: the launcher left before the ack")
		return nil, false
	}
	return env, true
}

// The exchange on a connected fd, without the environment applied or the ack (tests drive it
// over a socketpair): sends our pid, reads the environment. env in the heap allocator.
ready_exchange :: proc(fd: posix.FD, timeout: time.Duration) -> (env: []string, ok: bool) {
	if !ready_send(fd, fmt.tprintf("%d\n", posix.getpid())) {
		fmt.eprintln("deckhand-core: ready: the launcher left before our pid")
		return nil, false
	}
	buf := make([dynamic]u8, context.temp_allocator)
	defer trust.wipe(buf[:]) // it may hold a successor secret (READY_SECRET_KEY)
	deadline := time.tick_now()._nsec + i64(timeout)
	chunk: [16 << 10]u8
	defer trust.wipe(chunk[:])
	for {
		// done: "\0\0" at the end (an empty environment is a lone "\0")
		n := len(buf)
		if (n == 1 && buf[0] == 0) || (n >= 2 && buf[n - 1] == 0 && buf[n - 2] == 0) do break
		left := (deadline - time.tick_now()._nsec) / i64(time.Millisecond)
		pfd := Pollfd{fd = c.int(fd), events = POLLIN}
		if left <= 0 || poll(&pfd, 1, c.int(left)) <= 0 {
			fmt.eprintln("deckhand-core: ready: no environment from the launcher in time")
			return nil, false
		}
		r := read(c.int(fd), &chunk[0], len(chunk))
		if r < 0 && posix.errno() == .EINTR do continue
		if r <= 0 {
			fmt.eprintln("deckhand-core: ready: the launcher closed before the environment ended")
			return nil, false
		}
		if len(buf) + int(r) > READY_ENV_MAX {
			fmt.eprintln("deckhand-core: ready: the environment is too large")
			return nil, false
		}
		append(&buf, ..chunk[:r])
	}
	out := make([dynamic]string)
	rest := string(buf[:])
	for {
		e, _, after := strings.partition(rest, "\x00")
		if e == "" do break
		append(&out, strings.clone(e))
		rest = after
	}
	return out[:], true
}

@(private = "file")
ready_send :: proc(fd: posix.FD, s: string) -> bool {
	rest := transmute([]u8)s
	for len(rest) > 0 {
		n := send(c.int(fd), raw_data(rest), c.size_t(len(rest)), 0)
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return false
		rest = rest[n:]
	}
	return true
}

@(private = "file")
ready_connect :: proc(path: string) -> (posix.FD, bool) {
	addr: posix.sockaddr_un
	if len(path) >= len(addr.sun_path) do return -1, false
	addr.sun_family = .UNIX
	for i in 0 ..< len(path) do addr.sun_path[i] = c.char(path[i])
	when ODIN_OS == .Darwin do addr.sun_len = u8(size_of(addr))
	fd := posix.FD(socket(AF_UNIX, SOCK_STREAM, 0))
	if fd < 0 do return -1, false
	set_cloexec(c.int(fd)) // never into the holder's children
	ready_nosigpipe(fd)
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

// A write to a socket whose peer is gone fails (EPIPE) instead of raising SIGPIPE.
// (The holder's own declarations, sys_darwin.odin: one foreign signature per libc symbol in this
// package, or the compiler's LLVM backend panics at -o:speed.)
ready_nosigpipe :: proc(fd: posix.FD) {set_nosigpipe(c.int(fd))}
