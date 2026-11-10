package core

// A machine's web page in a local browser tab (issue #5; the user's decision of 2026-11-09): the
// user asks for a port on another machine (a dev server on its localhost:3000), and this core
// starts an ssh of its own for that page alone, as its own process group, which only forwards:
//   ssh -o ControlMaster=no -o ControlPath=none -o BatchMode=yes … -N
//       -L 127.0.0.1:<local>:127.0.0.1:<port> -- <target>
// argv only, never through a shell; the user's ssh config applies (aliases, keys, ProxyJump), but
// never the link's ControlMaster: closing the page is ending that child (SIGTERM to its group,
// SIGKILL after PAGE_KILL_WAIT), and a dead child holds no listener. Nothing is asked of a master,
// so nothing can be left forwarded by one. BatchMode: it needs key-based login to the machine (no
// prompt can show). <local> is a free loopback port picked here (bound, read, closed), another one
// if ssh cannot bind it. Both ends are 127.0.0.1: the forward listens on this Mac's loopback only,
// and reaches only that machine's own loopback, never another host.
//
// The command answers pending; the core loop's tick waits (never blocking) until the port accepts
// a connection, then opens an ordinary local browser tab there (browser_open as the user) in the
// session on screen, or the last shown session of this Mac's when that is another machine's (Home
// holds no browser tabs), and finishes the request. The child exiting first, or PAGE_OPEN_WAIT
// passing, fails it with ssh's last line.
//
// User-only (who = .User), and never while this core is viewed from another machine (its window
// is a hub then). The child ends when the tab closes, the machine's link drops, the machine is
// removed, the setting goes off or the core stops; at most PAGE_FORWARDS_MAX children run at once,
// opening and closing ones too.
//
// Residuals: while a page is open, any process of this user on this Mac can reach that remote
// port through it, as with the user's own `ssh -L`. ssh has no option that skips the config's
// own LocalForward/RemoteForward but keeps the command line's -L (ClearAllForwardings clears
// both), so a forward the user's config gives that host is asked for again by this child: the
// link's master holds it already, so it fails to bind (ExitOnForwardFailure=no: that does not end
// the child; ours is checked by connecting to it). A port another local process binds between
// the pick and ssh's bind would be connected to as ours, unless ssh said its bind failed first.
//
// Test builds: a `via` machine has no ssh. Its "remote" is this Mac (a second core), so its
// forward is the port itself, with no child (tests/scripts/remote-page.sh).

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import "base:runtime"

// Open web page… on a machine: a local browser tab at its 127.0.0.1:port, path. User-only.
Machine_Open_Page :: struct {
	no:   u64,
	port: u64,
	path: string, // a URL path ("" = "/"): no scheme or host
}

PAGE_PATH_MAX :: 1024
PAGE_FORWARDS_MAX :: 16 // children at once, every machine's, opening and closing ones too
PAGE_OPEN_WAIT :: 10 * time.Second // ssh connects and forwards, or the request fails
PAGE_KILL_WAIT :: 1 * time.Second // SIGTERM, then SIGKILL
PAGE_SSH_TRIES :: 3 // a picked port another process took first: another one
PAGE_OUT_MAX :: 4096 // of ssh's output: its errors come first
PAGE_WAIT_TAB :: TAB_HOST_PENDING_DEFAULT + TAB_HOST_GRACE // a tab the window answered pending: until it is recorded

// ---- checks (pure) ----

machine_page_port_error :: proc(port: u64) -> string {
	if port < 1 || port > 65535 do return "the port is 1 to 65535"
	return ""
}

// The page's path as the URL has it ("/…"), or why not: a plain path (and query, fragment) in
// printable ASCII, never a scheme or a host, at most PAGE_PATH_MAX bytes.
machine_page_path :: proc(path: string) -> (clean: string, why: string) {
	if len(path) > PAGE_PATH_MAX do return "", fmt.tprintf("the path has at most %d bytes", PAGE_PATH_MAX)
	for i in 0 ..< len(path) {
		c := path[i]
		if c <= 0x20 || c >= 0x7f || c == '\\' do return "", "the path holds only printable ASCII, no spaces or backslashes"
	}
	p := path
	if strings.has_prefix(p, "//") do return "", "a path, not a host (//host)"
	if !strings.has_prefix(p, "/") {
		// "admin", "?q=1": a path after the port; "http://…", "host:80/x", "javascript:…" are not
		head := p
		if k := strings.index_any(p, "/?#"); k >= 0 do head = p[:k]
		if strings.contains_any(head, ":@") do return "", "a path only: no scheme or host (the page is the machine's own 127.0.0.1)"
		p = strings.concatenate({"/", p}, context.temp_allocator)
	}
	return p, ""
}

// The tab's address: this Mac's end of the forward.
machine_page_url :: proc(local: int, path: string) -> string {
	return fmt.tprintf("http://127.0.0.1:%d%s", local, path)
}

// The palette's query: "PORT" or "PORT/path" (a leading ':' allowed).
machine_page_spec :: proc(q: string) -> (port: u64, path: string, ok: bool) {
	s := strings.trim_space(q)
	s = strings.trim_prefix(s, ":")
	end := len(s)
	if k := strings.index_any(s, "/?#"); k >= 0 do end = k
	digits := s[:end]
	if digits == "" || len(digits) > 5 do return 0, "", false
	for c in transmute([]u8)digits do if c < '0' || c > '9' do return 0, "", false
	n, _ := strconv.parse_u64(digits)
	if machine_page_port_error(n) != "" do return 0, "", false
	if _, why := machine_page_path(s[end:]); why != "" do return 0, "", false
	return n, s[end:], true
}


// A loopback port nothing listens on now (0: none): bound, read and closed, for ssh to bind next.
page_free_port :: proc() -> int {
	fd := posix.socket(.INET, .STREAM, .TCP)
	if fd < 0 do return 0
	defer posix.close(fd)
	addr := posix.sockaddr_in {
		sin_family = .INET,
		sin_port   = 0,
		sin_addr   = {s_addr = 0x7f000001}, // 127.0.0.1 (u32be)
	}
	when ODIN_OS == .Darwin do addr.sin_len = size_of(addr)
	if posix.bind(fd, (^posix.sockaddr)(&addr), size_of(addr)) != .OK do return 0
	got: posix.sockaddr_in
	n := posix.socklen_t(size_of(got))
	if posix.getsockname(fd, (^posix.sockaddr)(&got), &n) != .OK do return 0
	return int(got.sin_port)
}


// The page's own ssh (temp allocator): a new connection, never a ControlMaster's, that only
// forwards. The options come before the user's config (ssh takes the first value it is given):
// no agent or X11 forwarding, no LocalCommand, never a prompt, and a config's
// ClearAllForwardings=yes cannot clear our -L.
machine_page_ssh_argv :: proc(target: string, local, remote: int) -> (argv: []string, why: string) {
	if w := machine_target_error(target); w != "" do return nil, w
	if local < 1 || local > 65535 || remote < 1 || remote > 65535 do return nil, "the port is 1 to 65535"
	out := [?]string {
		"ssh",
		"-o", "ControlMaster=no",
		"-o", "ControlPath=none",
		"-o", "BatchMode=yes",
		"-o", "ClearAllForwardings=no",
		"-o", "ExitOnForwardFailure=no",
		"-o", "ForwardAgent=no",
		"-o", "ForwardX11=no",
		"-o", "PermitLocalCommand=no",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
		"-N",
		"-L", fmt.tprintf("127.0.0.1:%d:127.0.0.1:%d", local, remote),
		"--", target,
	}
	return slice_clone_temp(out[:]), ""

	slice_clone_temp :: proc(a: []string) -> []string {
		b := make([]string, len(a), context.temp_allocator)
		copy(b, a)
		return b
	}
}

// What ssh's output says went wrong, for the user (at most MACHINE_ERROR_MAX bytes).
machine_page_ssh_error :: proc(out: string) -> string {
	if strings.contains(out, "Permission denied") do return "opening pages needs key-based login to this machine (ssh runs without prompts)"
	line := machine_last_line(out)
	if line == "" do return "ssh ended"
	return text_clean(line, MACHINE_ERROR_MAX)
}

// ssh could not listen on our port (another process took it after the pick).
machine_page_bind_failed :: proc(out: string, local: int) -> bool {
	return strings.contains(out, fmt.tprintf("cannot listen to port: %d", local)) || strings.contains(out, fmt.tprintf(":%d: Address already in use", local))
}

// Something accepts connections on this Mac's 127.0.0.1:port (never blocks past a few ms).
page_listening :: proc(port: int) -> bool {
	fd := posix.socket(.INET, .STREAM, .TCP)
	if fd < 0 do return false
	defer posix.close(fd)
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | posix.O_NONBLOCK)
	addr := posix.sockaddr_in {
		sin_family = .INET,
		sin_port   = posix.in_port_t(port),
		sin_addr   = {s_addr = 0x7f000001}, // 127.0.0.1 (u32be)
	}
	when ODIN_OS == .Darwin do addr.sin_len = size_of(addr)
	if posix.connect(fd, (^posix.sockaddr)(&addr), size_of(addr)) == .OK do return true
	if posix.errno() != .EINPROGRESS do return false
	pfd := posix.pollfd{fd = fd, events = {.OUT}}
	if posix.poll(&pfd, 1, 5) <= 0 do return false
	err: i32
	n := posix.socklen_t(size_of(err))
	if posix.getsockopt(fd, posix.SOL_SOCKET, .ERROR, &err, &n) != .OK do return false
	return err == 0
}

// ---- the page children (main thread) ----

Page_Phase :: enum u8 {
	Opening, // its ssh starts; the request waits for the port (or a via machine's next tick)
	Open, // its tab is open (or about to be)
	Closing, // SIGTERM sent (SIGKILL after PAGE_KILL_WAIT): gone once reaped
}

Page_Forward :: struct {
	machine:    u64,
	tab_id:     u64,
	local:      int, // this Mac's loopback port
	remote:     int, // the machine's
	phase:      Page_Phase,
	child:      bool, // false: a test build's via machine (no ssh)
	pid:        posix.pid_t, // 0: reaped (or none)
	fd:         posix.FD, // its output (stdout and stderr; ours non-blocking)
	started:    time.Tick, // Opening: the ssh's start; Closing: the SIGTERM's
	killed:     bool, // SIGKILL sent
	opened:     time.Tick,
	waiting:    bool, // its tab is not recorded yet (the window answered pending)
	tries:      int,
	request_id: u64, // Opening: the request it finishes (0: finished)
	caller:     Caller,
	path:       string, // heap
	name:       string, // heap: the machine's
	target:     string, // heap: its ssh target
	out:        [PAGE_OUT_MAX]u8,
	out_n:      int,
}

@(private = "file")
page: struct {
	forwards: [dynamic]Page_Forward,
}

when TEST_HOOKS {
	page_ssh_argv_for_test: []string // run in place of ssh, %PORT% the local port (unit tests)
	page_test_finished: map[u64]string // the requests finished: their results' JSON (unit tests)
}

page_forwards_list :: proc() -> []Page_Forward {return page.forwards[:]}

// PAGE_FORWARDS_MAX children: opening, open and closing ones alike.
page_forwards_full :: proc() -> bool {return len(page.forwards) >= PAGE_FORWARDS_MAX}

@(private = "file")
page_forward_remove :: proc(i: int) {
	f := &page.forwards[i]
	if f.fd >= 0 do posix.close(f.fd)
	heap := runtime.heap_allocator()
	delete(f.path, heap)
	delete(f.name, heap)
	delete(f.target, heap)
	ordered_remove(&page.forwards, i)
}

@(private = "file")
page_finish :: proc(f: ^Page_Forward, r: Result) {
	if f.request_id == 0 do return
	when TEST_HOOKS {
		if page_test_finished != nil do page_test_finished[f.request_id] = strings.clone(result_json(r))
	}
	emit_event(Finished_Event{request_id = f.request_id, result = r})
	f.request_id = 0
}

// f's ssh, on f.local. False: it did not start.
@(private = "file")
page_child_start :: proc(f: ^Page_Forward, now: time.Tick) -> bool {
	argv, why := machine_page_ssh_argv(f.target, f.local, f.remote)
	when TEST_HOOKS do if page_ssh_argv_for_test != nil {
		argv, why = make([]string, len(page_ssh_argv_for_test), context.temp_allocator), ""
		for a, i in page_ssh_argv_for_test do argv[i], _ = strings.replace_all(a, "%PORT%", fmt.tprint(f.local), context.temp_allocator)
	}
	if why != "" do return false
	pid, fd, ok := page_spawn(argv)
	if !ok do return false
	f.pid, f.fd, f.started, f.out_n, f.killed = pid, fd, now, 0, false
	return true
}

// Reads what f's ssh wrote (the first PAGE_OUT_MAX bytes kept; the rest drained) and reaps it if it
// ended. True: its child is gone (never for a via machine's).
@(private = "file")
page_child_poll :: proc(f: ^Page_Forward) -> (ended: bool) {
	if !f.child do return false
	if f.fd >= 0 {
		buf: [4096]u8
		for {
			n := posix.read(f.fd, &buf[0], len(buf))
			if n <= 0 do break
			f.out_n += copy(f.out[f.out_n:], buf[:n])
		}
	}
	if f.pid > 0 {
		st: i32
		if posix.waitpid(f.pid, &st, {.NOHANG}) != f.pid do return false
		f.pid = 0
	}
	return true
}

// SIGKILL to f's group and reap it at once (a killed process ends at once): a retry's.
@(private = "file")
page_child_kill_now :: proc(f: ^Page_Forward) {
	if f.pid > 0 {
		posix.killpg(f.pid, .SIGKILL)
		st: i32
		for posix.waitpid(f.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
	}
	if f.fd >= 0 do posix.close(f.fd)
	f.pid, f.fd = 0, -1
}

// f ends: an opening request fails (why), and its ssh gets SIGTERM (reaped by the tick).
@(private = "file")
page_forward_close :: proc(f: ^Page_Forward, why: string, now: time.Tick) {
	if f.phase == .Closing do return
	if autotest_active do fmt.printfln("[autotest] page forward %d closed: %s", f.local, why)
	if f.phase == .Opening do page_finish(f, fail(fmt.tprintf("the page of %s did not open: %s", f.name, why)))
	if f.pid > 0 do posix.killpg(f.pid, .SIGTERM)
	f.phase, f.started, f.killed = .Closing, now, false
}

// Machine no's pages end (0: every machine's): its link dropped, it was removed or the setting
// went off.
page_forwards_drop :: proc(no: u64) {
	now := time.tick_now()
	for &f in page.forwards do if no == 0 || f.machine == no do page_forward_close(&f, "its link ended", now)
}

// The core stops: every page's ssh ends, waited for at most PAGE_KILL_WAIT and a little more.
page_forwards_stop :: proc() {
	now := time.tick_now()
	for &f in page.forwards do page_forward_close(&f, "Deckhand stopped", now)
	deadline := time.tick_add(now, PAGE_KILL_WAIT + 500 * time.Millisecond)
	for len(page.forwards) > 0 && time.tick_diff(time.tick_now(), deadline) > 0 {
		page_forwards_tick(time.tick_now())
		if len(page.forwards) > 0 do time.sleep(20 * time.Millisecond)
	}
	for len(page.forwards) > 0 {
		page_child_kill_now(&page.forwards[0])
		page_forward_remove(0)
	}
}

// The core loop's turn (never blocks): an opening page's port is tried and its tab opened; a page
// whose tab closed ends (one the window answered pending waits PAGE_WAIT_TAB for its tab); ended
// children are reaped and their entries go.
page_forwards_tick :: proc(now: time.Tick, alive := page_tab_alive) {
	for i := len(page.forwards) - 1; i >= 0; i -= 1 {
		f := &page.forwards[i]
		ended := page_child_poll(f)
		switch f.phase {
		case .Closing:
			if !f.child || ended {
				page_forward_remove(i)
				continue
			}
			if !f.killed && time.tick_diff(f.started, now) > PAGE_KILL_WAIT {
				posix.killpg(f.pid, .SIGKILL)
				f.killed = true
			}
		case .Open:
			if ended { // the connection ended (the network, the machine): its tab no longer loads
				if autotest_active do fmt.printfln("[autotest] page forward %d closed: its ssh ended", f.local)
				page_forward_remove(i)
				continue
			}
			if alive(f.tab_id) {
				f.waiting = false
				continue
			}
			if f.waiting && time.tick_diff(f.opened, now) <= PAGE_WAIT_TAB do continue
			page_forward_close(f, "its tab closed", now)
		case .Opening:
			out := string(f.out[:f.out_n])
			if f.child && machine_page_bind_failed(out, f.local) {
				page_child_kill_now(f)
				f.tries += 1
				if f.tries < PAGE_SSH_TRIES {
					if f.local = page_pick_port(); f.local != 0 && page_child_start(f, now) do continue
				}
				page_forward_close(f, "ssh could not listen on a port of this Mac", now)
			} else if ended {
				page_forward_close(f, machine_page_ssh_error(out), now)
			} else if !f.child || page_listening(f.local) {
				page_open_tab(f, now)
			} else if time.tick_diff(f.started, now) > PAGE_OPEN_WAIT {
				page_forward_close(f, fmt.tprintf("ssh did not forward the port in %v", PAGE_OPEN_WAIT), now)
			}
		}
	}
}

// The port answers: its tab opens, and the request finishes (the window's own finished does it
// when it answers pending).
@(private = "file")
page_open_tab :: proc(f: ^Page_Forward, now: time.Tick) {
	s := machine_local_session()
	if s == nil {
		page_forward_close(f, "no session of this Mac's is open: the page opens in a browser tab there", now)
		return
	}
	r, ch, tab_id := browser_open_tab(s, machine_page_url(f.local, f.path), f.caller, f.request_id)
	if !r.ok {
		page_finish(f, r)
		page_forward_close(f, "its tab did not open", now)
		return
	}
	if autotest_active do fmt.printfln("[autotest] page forward %d: %s port %d", f.local, f.name, f.remote)
	f.phase, f.tab_id, f.waiting, f.opened = .Open, tab_id, r.pending, now
	if r.pending {
		f.request_id = 0 // the window's finished ends it
	} else {
		if s.id != state.current_session {
			focus_session(s.id, f.caller)
			ch = true
		}
		page_finish(f, r)
	}
	if ch {
		state.version += 1
		window_state_changed()
	}
}

page_tab_alive :: proc(tab_id: u64) -> bool {
	_, tab, _ := find_tab(tab_id)
	if tab == nil do return false
	_, is := tab.kind.(Browser_Tab)
	return is
}

// A free loopback port no page uses (0: none).
@(private = "file")
page_pick_port :: proc() -> int {
	outer: for _ in 0 ..< 4 {
		p := page_free_port()
		if p == 0 do return 0
		for f in page.forwards do if f.local == p do continue outer
		return p
	}
	return 0
}

// Spawns argv (looked up on PATH) in its own process group: stdin /dev/null, stdout and stderr one
// pipe (fd, ours: non-blocking). Nothing else of ours reaches it.
@(private = "file")
page_spawn :: proc(argv: []string) -> (pid: posix.pid_t, fd: posix.FD, ok: bool) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	p: [2]posix.FD
	if posix.pipe(&p) != .OK do return 0, -1, false
	null_fd := posix.open("/dev/null", {.RDWR, .CLOEXEC})
	defer if null_fd >= 0 do posix.close(null_fd)
	if null_fd < 0 {
		posix.close(p[0]); posix.close(p[1])
		return 0, -1, false
	}
	for x in p do posix.fcntl(x, .SETFD, i32(posix.FD_CLOEXEC))
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawnattr_setpgroup(&attr, 0)
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(null_fd), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(p[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(p[1]), 2)
	sync.rw_mutex_shared_lock(&fork_lock)
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(p[1])
	if err != .NONE {
		posix.close(p[0])
		return 0, -1, false
	}
	posix.fcntl(p[0], .SETFL, posix.fcntl(p[0], .GETFL) | posix.O_NONBLOCK)
	return pid, p[0], true
}

when TEST_HOOKS {
	page_forwards_reset_for_test :: proc() {
		for len(page.forwards) > 0 {
			page_child_kill_now(&page.forwards[0])
			page_forward_remove(0)
		}
		page_ssh_argv_for_test = nil
	}
}

// ---- the command ----

machine_open_page_apply :: proc(c: Machine_Open_Page, caller: Caller, request_id: u64) -> (Result, bool) {
	if !state.settings.remote_machines do return fail("turn on Settings › Experimental › Machines over SSH first"), false
	// the user's only, at this Mac's own window: never a hub's (another machine viewing this one)
	if caller.kind != .UI && caller.kind != .Internal do return fail("only the user opens a machine's web page"), false
	if window_link_hub() do return fail("this machine is viewed from another one: open the page there"), false
	if w := machine_page_port_error(c.port); w != "" do return fail(w), false
	path, pwhy := machine_page_path(c.path)
	if pwhy != "" do return fail(pwhy), false
	m, ok := machine_entry(c.no)
	if !ok do return fail(fmt.tprintf("no machine %d", c.no)), false
	if !machine_link_up(c.no) do return fail(fmt.tprintf("%s is not online", m.name)), false
	if !tab_host_up() do return no_window(), false
	if page_forwards_full() do return fail(fmt.tprintf("%d web pages of other machines are open or closing: close one first", PAGE_FORWARDS_MAX)), false
	if machine_local_session() == nil do return fail("open a session on this Mac first: the page opens in a browser tab there"), false
	return page_forward_open(c.no, m, int(c.port), path, caller, request_id)
}

// Starts the page's ssh (none for a via machine): the tick opens its tab. Pending, or why not.
page_forward_open :: proc(no: u64, m: Machine, remote: int, path: string, caller: Caller, request_id: u64) -> (Result, bool) {
	now := time.tick_now()
	heap := runtime.heap_allocator()
	f := Page_Forward{machine = no, remote = remote, phase = .Opening, started = now, request_id = request_id, caller = caller, fd = -1}
	if m.via != "" {
		when !TEST_HOOKS do return fail("via is only for development and test builds"), false
		f.local = remote // a test build's "machine" is this Mac: its port is here already
	} else {
		f.child = true
		f.local = page_pick_port()
		if f.local == 0 do return fail("no free port on this Mac"), false
		if _, why := machine_page_ssh_argv(m.target, f.local, remote); why != "" do return fail(why), false
	}
	f.path, f.name, f.target = strings.clone(path, heap), strings.clone(m.name, heap), strings.clone(m.target, heap)
	if page.forwards == nil do page.forwards = make([dynamic]Page_Forward, heap)
	append(&page.forwards, f)
	last := &page.forwards[len(page.forwards) - 1]
	if f.child && !page_child_start(last, now) {
		last.request_id = 0
		page_forward_remove(len(page.forwards) - 1)
		return fail("ssh could not start"), false
	}
	return {ok = true, pending = true}, false
}
