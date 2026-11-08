#+build darwin
package holder

// The updater's relaunch helper (docs/plans/background-core.md §7.2 step 3.5, §7.4 step 3):
//
//   deckhand-core relaunch --pid P --app BUNDLE --exe EXE --run DIR [--no-open]
//
// The app that is updating starts it (src/update.odin) right after it swapped the new bundle in,
// before it quits. The helper:
//   1. listens on DIR/successor.sock (0600, in the runtime dir: 0700 and ours) and says "ready\n"
//      on stdout;
//   2. reads the successor secret from stdin: "<64 hex>\n" once the app's handover got it from the
//      session holder (GOODBYE{handover, successor}), "\n" or EOF when there is none. It is never in
//      argv, the environment, a file or a log;
//   3. waits for P (the old app) to exit, then runs `open BUNDLE` (not with --no-open: tests start
//      the new app themselves);
//   4. hands the secret to the first peer of successor.sock that passes the check, at most until
//      the secret expires (holderwire.SUCCESSOR_TTL after it arrived), then removes the socket and
//      exits. The new app connects at launch (src/holder_successor.odin) and says HELLO with it.
//
// The ready wire, plain bytes both ways: app → "<pid>\n"; helper → "<secret>\n"; app → "ok\n".
// The check (ad hoc, §5.4: it guards against accidents, not a same-user attacker): the peer is
// this user's (trust.ready_peer_allowed), it is the pid it claims, and that pid runs EXE (the new
// bundle's executable, by real path). A peer that fails is closed and the helper keeps waiting.

import "core:c"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../holderwire"
import "../trust"

SUCCESSOR_SOCK :: "successor.sock"
RELAUNCH_USAGE :: "usage: deckhand-core relaunch --pid P --app BUNDLE --exe EXE --run DIR [--no-open]"

Relaunch_Args :: struct {
	pid:     c.int,
	app:     string,
	exe:     string,
	run:     string,
	no_open: bool,
}

relaunch_args_parse :: proc(args: []string) -> (a: Relaunch_Args, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--no-open":
			a.no_open = true
			continue
		case "--pid", "--app", "--exe", "--run":
		case:
			return {}, false
		}
		if i + 1 >= len(args) do return {}, false
		v := args[i + 1]
		switch args[i] {
		case "--pid":
			n, nok := strconv.parse_int(v, 10)
			if !nok || n <= 1 || n > int(max(i32)) do return {}, false
			a.pid = c.int(n)
		case "--app": a.app = v
		case "--exe": a.exe = v
		case "--run": a.run = v
		}
		i += 1
	}
	for p in ([]string{a.app, a.exe, a.run}) do if !strings.has_prefix(p, "/") do return {}, false
	return a, a.pid > 0
}

relaunch_main :: proc(args: []string) -> int {
	a, ok := relaunch_args_parse(args)
	if !ok {
		fmt.eprintln(RELAUNCH_USAGE)
		return 2
	}
	ignore_sigpipe()
	path := fmt.tprintf("%s/%s", strings.trim_right(a.run, "/"), SUCCESSOR_SOCK)
	lfd, lok := relaunch_listen(a.run, path)
	if !lok {
		// no socket: still relaunch (the new app then finds no secret: a crash-style restart once
		// the secret expires, or at once when there was none)
		relaunch_say("cannot listen on %s: relaunching without a successor secret", path)
	}
	defer if lok {
		close(lfd)
		unlink(strings.clone_to_cstring(path, context.temp_allocator))
	}
	if !write_all(1, "ready\n") do relaunch_say("the app left before ready")
	secret := relaunch_read_secret(0)
	close(0)
	// the old app quits right after it sent the secret: wait for it, as the old /bin/sh helper did
	for kill(a.pid, 0) == 0 do time.sleep(100 * time.Millisecond)
	// open is not waited for before serving: it may return only once the new app has finished
	// launching, and the new app asks successor.sock for its secret before that
	opened: c.int = -1
	if !a.no_open {
		opened = relaunch_open(a.app)
		if opened < 0 do relaunch_say("cannot run open %s", a.app)
	}
	defer if opened > 0 {
		st: c.int
		waitpid(opened, &st, 0)
	}
	if !lok || secret == "" do return 0
	relaunch_serve(lfd, secret, a.exe, time.tick_add(time.tick_now(), holderwire.SUCCESSOR_TTL))
	return 0
}

@(private = "file")
relaunch_say :: proc(format: string, args: ..any) {
	fmt.eprintf("deckhand-core relaunch[%d]: %s\n", getpid(), fmt.tprintf(format, ..args))
}

@(private = "file")
ignore_sigpipe :: proc() {
	sa := Sigaction{handler = 1} // SIG_IGN
	sigaction(SIGPIPE, &sa, nil)
}

@(private = "file")
write_all :: proc(fd: c.int, s: string) -> bool {
	rest := transmute([]u8)s
	for len(rest) > 0 {
		n := write(fd, raw_data(rest), len(rest))
		if n < 0 && errno() == EINTR do continue
		if n <= 0 do return false
		rest = rest[n:]
	}
	return true
}

// "<64 hex>\n" from fd (blocking: the app writes it at its quit, or closes the pipe), else "".
@(private = "file")
relaunch_read_secret :: proc(fd: c.int) -> string {
	buf: [80]u8
	n := 0
	for n < len(buf) {
		r := read(fd, &buf[n], c.size_t(len(buf) - n))
		if r < 0 && errno() == EINTR do continue
		if r <= 0 do break
		n += int(r)
		if buf[n - 1] == '\n' do break
	}
	line := string(buf[:n])
	if len(line) != 65 || line[64] != '\n' || !hex64(line[:64]) do return ""
	return strings.clone(line[:64])
}

hex64 :: proc(s: string) -> bool {
	if len(s) != 64 do return false
	for ch in transmute([]u8)s do if !(ch >= '0' && ch <= '9') && !(ch >= 'a' && ch <= 'f') do return false
	return true
}

// Listens on path, in run: a real 0700 directory of ours. A stale socket of ours at path (an
// earlier helper that was killed) is replaced.
relaunch_listen :: proc(run, path: string) -> (fd: c.int, ok: bool) {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(run, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() || st.st_mode & (posix.S_IRWXG | posix.S_IRWXO) != {} do return -1, false
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.lstat(cpath, &st) == .OK {
		if !posix.S_ISSOCK(st.st_mode) || st.st_uid != posix.getuid() do return -1, false
		unlink(cpath)
	}
	addr := Sockaddr_Un{sun_family = AF_UNIX}
	if len(path) >= len(addr.sun_path) do return -1, false
	copy(addr.sun_path[:], path)
	addr.sun_len = size_of(addr)
	sync_lock()
	fd = socket(AF_UNIX, SOCK_STREAM, 0)
	if fd >= 0 do set_cloexec(fd)
	sync_unlock()
	if fd < 0 do return -1, false
	old := umask(0o177)
	bound := bind(fd, &addr, size_of(addr)) == 0
	umask(old)
	if !bound || listen(fd, 4) != 0 {
		close(fd)
		return -1, false
	}
	return fd, true
}

// Accepts until a peer passes and acks, or deadline. True: the secret was taken.
relaunch_serve :: proc(lfd: c.int, secret, exe: string, deadline: time.Tick) -> bool {
	want := real_path(exe)
	if want == "" {
		relaunch_say("the new app's executable %s is not there: no secret handed out", exe)
		return false
	}
	set_nonblock(lfd)
	for {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 {
			relaunch_say("no successor came for the secret in time")
			return false
		}
		pfd := Pollfd{fd = lfd, events = POLLIN}
		if poll(&pfd, 1, c.int(max(time.duration_milliseconds(left), 1))) <= 0 do continue
		cfd := accept(lfd, nil, nil)
		if cfd < 0 do continue
		set_cloexec(cfd)
		set_nosigpipe(cfd)
		why := relaunch_one(cfd, secret, want, deadline)
		close(cfd)
		if why == "" do return true
		relaunch_say("refused a peer: %s", why)
	}
}

// One peer: "" once it took the secret and acked, else why not (never the secret).
@(private = "file")
relaunch_one :: proc(cfd: c.int, secret, want_exe: string, deadline: time.Tick) -> string {
	at_accept := trust.peer_read(posix.FD(cfd)) // before any byte is read
	line, lok := read_line(cfd, 16, deadline)
	if !lok do return "no pid"
	n, nok := strconv.parse_int(strings.trim_suffix(line, "\n"), 10)
	if !nok || n <= 0 || n > int(max(i32)) do return "a bad pid"
	claimed := i32(n)
	if d := trust.ready_peer_allowed(.Adhoc, trust.own_uid(), claimed, at_accept); d != .Allow do return fmt.tprintf("%v", d)
	if got := real_path(pid_path(claimed)); got != want_exe do return fmt.tprintf("pid %d runs %q, not the new app", claimed, got)
	if trust.peer_still(at_accept, trust.peer_read(posix.FD(cfd))) != .Allow do return "the peer changed"
	if !write_all(cfd, fmt.tprintf("%s\n", secret)) do return "it left before the secret"
	ack, aok := read_line(cfd, 4, deadline)
	if !aok || ack != "ok\n" do return "no ack"
	return ""
}

@(private = "file")
read_line :: proc(fd: c.int, max_n: int, deadline: time.Tick) -> (string, bool) {
	buf := make([dynamic]u8, context.temp_allocator)
	one: [1]u8
	for len(buf) < max_n {
		left := time.tick_diff(time.tick_now(), deadline)
		if left <= 0 do return "", false
		pfd := Pollfd{fd = fd, events = POLLIN}
		if poll(&pfd, 1, c.int(min(max(time.duration_milliseconds(left), 1), 5000))) <= 0 do return "", false
		if read(fd, &one[0], 1) != 1 do return "", false
		append(&buf, one[0])
		if one[0] == '\n' do return string(buf[:]), true
	}
	return "", false
}

@(private = "file")
pid_path :: proc(pid: i32) -> string {
	buf: [4096]u8
	n := proc_pidpath(c.int(pid), &buf[0], u32(len(buf)))
	if n <= 0 do return ""
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

@(private = "file")
real_path :: proc(p: string) -> string {
	if p == "" do return ""
	r := posix.realpath(strings.clone_to_cstring(p, context.temp_allocator), nil)
	if r == nil do return ""
	defer posix.free(r)
	return strings.clone(string(r), context.temp_allocator)
}

// `/usr/bin/open BUNDLE`, detached, with a plain environment and /dev/null for its stdio.
@(private = "file")
// Starts `open BUNDLE`; its pid (the caller reaps it), or -1.
relaunch_open :: proc(app: string) -> c.int {
	// our stdin is closed already; stdout and stderr go to /dev/null for open
	null := open("/dev/null", O_RDWR)
	if null >= 0 {
		posix.dup2(posix.FD(null), 0)
		posix.dup2(posix.FD(null), 1)
		if null > 1 do close(null)
	}
	argv := []cstring{"/usr/bin/open", strings.clone_to_cstring(app, context.temp_allocator), nil}
	env := []cstring{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", nil}
	pid: c.int
	if posix_spawn(&pid, "/usr/bin/open", nil, nil, raw_data(argv), raw_data(env)) != 0 do return -1
	return pid
}
