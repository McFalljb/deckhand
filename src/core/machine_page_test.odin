package core

// A machine's web page in a local tab (machine_page.odin; issue #5): the page's ssh argv, the port
// and path checks, the palette's "PORT[/path]" and the page children. No ssh runs here: /bin/sh
// stands in for it (page_ssh_argv_for_test); the scene remote-page.sh opens one through a test
// build's `via` machine.

import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

// A release build (-define:DECKHAND_TEST_HOOKS=false) compiles _test files too, and these tests
// use helpers that exist only with the test hooks: the whole file is behind them.
when TEST_HOOKS {

@(test)
machine_page_ssh_argv_test :: proc(t: ^testing.T) {
	argv, why := machine_page_ssh_argv("me@nuc", 41234, 3000)
	testing.expect_value(t, why, "")
	// its own connection (never the link's master), no prompt, only our forward; the user's config
	// applies for the rest (aliases, keys, ProxyJump)
	want := []string{"ssh", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "-o", "RequestTTY=no", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=no", "-o", "ExitOnForwardFailure=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-N", "-L", "127.0.0.1:41234:127.0.0.1:3000", "--", "me@nuc"}
	testing.expectf(t, slice_eq(argv, want), "argv %v", argv)
	// what the user typed never becomes an option
	for bad in ([?]string{"-oProxyCommand=touch /tmp/x", "a;b", "host name", ""}) {
		_, why = machine_page_ssh_argv(bad, 41234, 3000)
		testing.expectf(t, why != "", "target %q refused", bad)
	}
	_, why = machine_page_ssh_argv("me@nuc", 0, 3000)
	testing.expect(t, why != "", "local port 0 refused")
	_, why = machine_page_ssh_argv("me@nuc", 41234, 70000)
	testing.expect(t, why != "", "remote port past 65535 refused")
	// what ssh says, for the user
	testing.expect(t, strings.contains(machine_page_ssh_error("me@nuc: Permission denied (publickey,password)."), "key-based login"), "BatchMode's auth failure")
	testing.expect_value(t, machine_page_ssh_error("debug\nssh: Could not resolve hostname nuc: nodename nor servname provided\n"), "ssh: Could not resolve hostname nuc: nodename nor servname provided")
	testing.expect_value(t, machine_page_ssh_error(""), "ssh ended")
	testing.expect(t, machine_page_bind_failed("bind [127.0.0.1]:41234: Address already in use\n", 41234), "our port's bind failed")
	testing.expect(t, !machine_page_bind_failed("bind [127.0.0.1]:5432: Address already in use\n", 41234), "a config forward's is not ours")

	slice_eq :: proc(a, b: []string) -> bool {
		if len(a) != len(b) do return false
		for x, i in a do if x != b[i] do return false
		return true
	}
}

// A listening socket on 127.0.0.1:port, this process's (-1: none).
test_listen :: proc(port: int) -> posix.FD {
	fd := posix.socket(.INET, .STREAM, .TCP)
	addr := posix.sockaddr_in{sin_family = .INET, sin_port = posix.in_port_t(port), sin_addr = {s_addr = 0x7f000001}}
	when ODIN_OS == .Darwin do addr.sin_len = size_of(addr)
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK || posix.listen(fd, 4) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

// review round 3: whose listener it is (Darwin: proc_pidinfo's socket offsets against the kernel)
@(test)
machine_page_owner :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	p := page_free_port()
	fd := test_listen(p)
	if !testing.expect(t, fd >= 0, "listen") do return
	defer posix.close(fd)
	me := posix.getpid()
	testing.expect(t, page_listener_owned(me, p), "this process listens there")
	testing.expect(t, !page_listener_owned(me, p + 1 if p < 65535 else p - 1), "not on another port")
	testing.expect(t, !page_listener_owned(posix.getppid(), p), "another process does not")
}

@(test)
machine_page_listening :: proc(t: ^testing.T) {
	p := page_free_port()
	testing.expect(t, !page_listening(p), "nothing listens on a free port")
	fd := posix.socket(.INET, .STREAM, .TCP)
	defer posix.close(fd)
	addr := posix.sockaddr_in{sin_family = .INET, sin_port = posix.in_port_t(p), sin_addr = {s_addr = 0x7f000001}}
	when ODIN_OS == .Darwin do addr.sin_len = size_of(addr)
	if !testing.expect(t, posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK, "bind") do return
	testing.expect(t, posix.listen(fd, 4) == .OK, "listen")
	testing.expect(t, page_listening(p), "a listener answers")
}

// The page children (review round 2, PR #75): one ssh per page, ended by a signal and gone once
// reaped; the tick never waits for one. /bin/sh stands in for ssh.
@(test)
machine_page_children :: proc(t: ^testing.T) {
	page_forwards_reset_for_test()
	page_test_finished = make(map[u64]string, 16) // allocated: an empty map is nil
	defer {
		page_forwards_reset_for_test()
		for _, v in page_test_finished do delete(v)
		delete(page_test_finished)
		page_test_finished = nil
	}
	m := Machine{no = 9, name = "nuc", target = "me@nuc"}
	ui := Caller{kind = .UI}
	sh :: proc(script: string) -> []string {
		a := make([]string, 3, context.temp_allocator)
		a[0], a[1], a[2] = "/bin/sh", "-c", script
		return a
	}
	// the loop's turns until request id finished (or 3 s)
	finished :: proc(id: u64) -> string {
		for _ in 0 ..< 150 {
			if r, ok := page_test_finished[id]; ok do return r
			page_forwards_tick(time.tick_now())
			time.sleep(20 * time.Millisecond)
		}
		return ""
	}
	// the loop's turns until the table is empty (or 3 s)
	settle :: proc() -> bool {
		for _ in 0 ..< 150 {
			if len(page_forwards_list()) == 0 do return true
			time.sleep(20 * time.Millisecond)
			page_forwards_tick(time.tick_now())
		}
		return false
	}
	// the loop's turns until every child said "ready" (its SIGTERM trap is set)
	ready :: proc() {
		for _ in 0 ..< 150 {
			all := true
			for f in page_forwards_list() do if f.out_n == 0 do all = false
			if all do return
			time.sleep(20 * time.Millisecond)
			page_forwards_tick(time.tick_now())
		}
	}

	// ssh ends before the port answers (BatchMode, no key): the request fails, the entry goes
	page_ssh_argv_for_test = sh("echo 'me@nuc: Permission denied (publickey).' >&2; exit 255")
	r, _ := page_forward_open(9, m, 3000, "/", ui, 71)
	testing.expect(t, r.ok && r.pending, "pending")
	got := finished(71)
	testing.expectf(t, strings.contains(got, `"ok":false`) && strings.contains(got, "key-based login"), "71: %s", got)
	testing.expect(t, settle(), "its entry went")

	// a port ssh could not bind: another port, at most PAGE_SSH_TRIES, then it fails
	page_ssh_argv_for_test = sh("echo 'bind [127.0.0.1]:%PORT%: Address already in use'; exec sleep 30")
	r, _ = page_forward_open(9, m, 3000, "/", ui, 72)
	got = finished(72)
	testing.expectf(t, strings.contains(got, "could not listen"), "72: %s", got)
	testing.expect(t, settle(), "its entry went")

	// a hung ssh: the turns return at once; past PAGE_OPEN_WAIT the request fails and the child ends
	page_ssh_argv_for_test = sh("exec sleep 30")
	r, _ = page_forward_open(9, m, 3000, "/", ui, 73)
	start := time.tick_now()
	page_forwards_tick(start)
	page_forwards_tick(time.tick_now())
	testing.expectf(t, time.tick_since(start) < 500 * time.Millisecond, "the turns took %v", time.tick_since(start))
	testing.expect_value(t, page_forwards_list()[0].phase, Page_Phase.Opening)
	page_forwards_tick(time.tick_add(time.tick_now(), PAGE_OPEN_WAIT + time.Second))
	got = finished(73)
	testing.expectf(t, strings.contains(got, "did not forward"), "73: %s", got)
	// closed at that later time: past its SIGKILL too, then reaped
	page_forwards_tick(time.tick_add(time.tick_now(), PAGE_OPEN_WAIT + PAGE_KILL_WAIT + 2 * time.Second))
	testing.expect(t, settle(), "SIGTERM, then SIGKILL to the group, then the reap")

	// an ssh that ignores SIGTERM: the link drops; the entry stays until the child is reaped, SIGKILL
	// after PAGE_KILL_WAIT
	page_ssh_argv_for_test = sh("trap '' TERM; echo ready; sleep 30; sleep 30")
	r, _ = page_forward_open(9, m, 3000, "/", ui, 74)
	ready()
	pid := page_forwards_list()[0].pid
	page_forwards_drop(9)
	got = finished(74)
	testing.expectf(t, strings.contains(got, "its link ended"), "74: %s", got)
	testing.expect_value(t, len(page_forwards_list()), 1)
	testing.expect_value(t, page_forwards_list()[0].phase, Page_Phase.Closing)
	testing.expect(t, posix.kill(pid, posix.Signal(0)) == .OK, "still running: not reaped, not forgotten")
	page_forwards_tick(time.tick_add(time.tick_now(), PAGE_KILL_WAIT + 100 * time.Millisecond))
	testing.expect(t, settle(), "SIGKILL ended it, and it was reaped")
	testing.expect(t, posix.kill(pid, posix.Signal(0)) != .OK, "gone")

	// review round 3: a page whose ssh ends by itself loses its tab (a reload never reaches whatever
	// takes the port next)
	page_test_closed_tab = 0
	page_ssh_argv_for_test = sh("sleep 0.3")
	_, _ = page_forward_open(9, m, 3000, "/", ui, 0)
	page_forwards_list()[0].phase, page_forwards_list()[0].tab_id = .Open, 555
	tab_555 :: proc(id: u64) -> bool {return id == 555}
	for _ in 0 ..< 100 {
		page_forwards_tick(time.tick_now(), tab_555)
		if page_forwards_list()[0].phase == .Closing do break
		time.sleep(20 * time.Millisecond)
	}
	testing.expect_value(t, page_test_closed_tab, u64(555))
	testing.expect(t, settle(), "its entry went")

	// review round 3: the group gets SIGKILL after PAGE_KILL_WAIT even when the ssh itself ended at
	// SIGTERM (a ProxyCommand helper that ignores it), and only then is the ssh reaped
	page_ssh_argv_for_test = sh("(trap '' TERM; exec sleep 31) & echo \"helper $!\"; wait")
	_, _ = page_forward_open(9, m, 3000, "/", ui, 75)
	ready()
	helper := 0
	{
		f := &page_forwards_list()[0]
		out := string(f.out[:f.out_n])
		if k := strings.index(out, "helper "); k >= 0 {
			line := out[k + 7:]
			if e := strings.index_byte(line, '\n'); e >= 0 do line = line[:e]
			helper, _ = strconv.parse_int(strings.trim_space(line))
		}
	}
	if !testing.expect(t, helper > 0, "the helper's pid") do return
	page_forwards_drop(9)
	time.sleep(300 * time.Millisecond) // the ssh stand-in ends at SIGTERM; its helper does not
	page_forwards_tick(time.tick_now())
	testing.expect_value(t, len(page_forwards_list()), 1)
	testing.expect(t, posix.kill(posix.pid_t(helper), posix.Signal(0)) == .OK, "the helper still runs: the entry stays")
	testing.expect(t, settle(), "SIGKILL to the group, then the reap")
	// killed with the group (its zombie is launchd's to reap: a moment later)
	gone := false
	for _ in 0 ..< 50 {
		if posix.kill(posix.pid_t(helper), posix.Signal(0)) != .OK {
			gone = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, gone, "the helper is gone too")

	// review round 3: a listener on the port that is not our ssh's is never taken for the page:
	// another port is tried
	page_ssh_argv_for_test = sh("exec sleep 30")
	_, _ = page_forward_open(9, m, 3000, "/", ui, 76)
	first := page_forwards_list()[0].local
	lfd := test_listen(first)
	defer posix.close(lfd)
	page_forwards_tick(time.tick_now())
	{
		f := page_forwards_list()[0]
		testing.expect_value(t, f.phase, Page_Phase.Opening)
		testing.expect_value(t, f.tries, 1)
		testing.expect(t, f.local != first, "another port")
	}
	page_forwards_reset_for_test()
	// and our ssh's own listener is (this test has no session: the tab cannot open, so it fails there)
	page_ssh_argv_for_test = {"python3", "-c", "import socket,sys,time\ns=socket.socket()\ns.bind(('127.0.0.1',int(sys.argv[1])))\ns.listen()\nprint('ready',flush=True)\ntime.sleep(30)", "%PORT%"}
	_, _ = page_forward_open(9, m, 3000, "/", ui, 77)
	got = finished(77)
	// (Linux has no window and no owner check: the listener is never ours there, so it fails earlier)
	when ODIN_OS == .Darwin do testing.expectf(t, strings.contains(got, "no session"), "77 reached the tab: %s", got)
	page_forwards_reset_for_test()

	// the cap counts every phase (opening, open, closing)
	via := Machine{no = 8, name = "test", via = "x connect"}
	for i in 0 ..< PAGE_FORWARDS_MAX do _, _ = page_forward_open(8, via, 3000 + i, "/", ui, 0)
	list := page_forwards_list()
	list[0].phase, list[1].phase = .Open, .Closing
	testing.expect(t, page_forwards_full(), "16 in any phase: full")
	page_forwards_reset_for_test()

	// the core stops: every child ends, SIGTERM-proof ones too, in about PAGE_KILL_WAIT
	page_ssh_argv_for_test = sh("trap '' TERM; echo ready; sleep 30; sleep 30")
	pids: [3]posix.pid_t
	for i in 0 ..< 3 {
		_, _ = page_forward_open(9, m, 3000, "/", ui, u64(80 + i))
		pids[i] = page_forwards_list()[i].pid
	}
	ready()
	start = time.tick_now()
	page_forwards_stop()
	testing.expect_value(t, len(page_forwards_list()), 0)
	testing.expectf(t, time.tick_since(start) < PAGE_KILL_WAIT + time.Second, "stop took %v", time.tick_since(start))
	for p in pids do testing.expectf(t, posix.kill(p, posix.Signal(0)) != .OK, "child %d gone", p)
	for i in 0 ..< 3 do testing.expectf(t, strings.contains(page_test_finished[u64(80 + i)], "Deckhand stopped"), "%d failed", 80 + i)
}

@(test)
machine_page_checks :: proc(t: ^testing.T) {
	testing.expect_value(t, machine_page_port_error(1), "")
	testing.expect_value(t, machine_page_port_error(65535), "")
	testing.expect(t, machine_page_port_error(0) != "", "port 0")
	testing.expect(t, machine_page_port_error(65536) != "", "port 65536")
	ok_paths := [][2]string{{"", "/"}, {"/", "/"}, {"admin", "/admin"}, {"/a/b?x=1&y=2#top", "/a/b?x=1&y=2#top"}, {"?q=http://x", "/?q=http://x"}, {"/redirect?to=//x", "/redirect?to=//x"}}
	for p in ok_paths {
		got, why := machine_page_path(p[0])
		testing.expectf(t, why == "" && got == p[1], "path %q: %q (%s)", p[0], got, why)
	}
	// no scheme or host, nothing outside printable ASCII, bounded
	for bad in ([?]string{"//evil.com/x", "http://evil.com/", "evil.com:80/x", "javascript:alert(1)", "/a b", "/a\\b", "/a\tb", "/é", "/a\x7fb", "@evil.com", strings.repeat("a", PAGE_PATH_MAX + 1, context.temp_allocator)}) {
		_, why := machine_page_path(bad)
		testing.expectf(t, why != "", "path %q refused", bad)
	}
	testing.expect_value(t, machine_page_url(41234, "/a?b=1"), "http://127.0.0.1:41234/a?b=1")
	// what the URL opens is always this Mac's loopback at that port, whatever the path
	for p in ok_paths {
		path, _ := machine_page_path(p[0])
		u, uerr := browser_url_normalize(machine_page_url(41234, path))
		testing.expectf(t, uerr == "" && strings.has_prefix(u, "http://127.0.0.1:41234/"), "%q -> %q", p[0], u)
	}
}

@(test)
machine_page_palette_spec :: proc(t: ^testing.T) {
	port, path, ok := machine_page_spec("3000")
	testing.expect(t, ok && port == 3000 && path == "", "3000")
	port, path, ok = machine_page_spec(" 8080/admin?x=1 ")
	testing.expect(t, ok && port == 8080 && path == "/admin?x=1", "8080/admin")
	port, path, ok = machine_page_spec(":5173/")
	testing.expect(t, ok && port == 5173 && path == "/", ":5173/")
	for bad in ([?]string{"", "abc", "0", "65536", "3000x", "localhost:3000", "3000 /x"}) {
		_, _, ok = machine_page_spec(bad)
		testing.expectf(t, !ok, "%q is not a port", bad)
	}
}

@(test)
machine_page_free_port :: proc(t: ^testing.T) {
	p := page_free_port()
	testing.expectf(t, p >= 1024 && p <= 65535, "a free loopback port: %d", p)
}


@(test)
machine_page_user_only :: proc(t: ^testing.T) {
	for k in Caller_Kind {
		spec := command_spec("machine_open_page")
		if !testing.expect(t, spec != nil, "machine_open_page has a row") do return
		may := who_allows(k, spec.who)
		testing.expectf(t, may == (k == .UI || k == .Internal), "%v may send machine_open_page: %v", k, may)
	}
}
} // when TEST_HOOKS
