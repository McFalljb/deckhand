package core

// A machine's web page in a local browser tab (issue #5; the user's decision of 2026-11-09): the
// user asks for a port on another machine (a dev server on its localhost:3000), and this core asks
// that machine's ssh ControlMaster (machines.odin's `ssh-<n>.ctl`) for a local forward:
//   ssh -F /dev/null -S <ctl> -O forward -L 127.0.0.1:<local>:127.0.0.1:<port> -- <target>
// argv only, never through a shell. ssh takes no 0 for a local forward's port ("Bad local
// forwarding specification"), so <local> is a free loopback port picked here (bound, read, closed),
// tried again with another if ssh cannot bind it. Both ends are 127.0.0.1: the forward listens on
// this Mac's loopback only, and reaches only that machine's own loopback, never another host.
// The page opens in an ordinary local browser tab (browser_open as the user) in the session on
// screen, or the last shown session of this Mac's when that is another machine's (Home holds no
// browser tabs): only the user and this Mac's own agents drive it, as any local tab.
//
// User-only (who = .User), and never while this core is viewed from another machine (its window
// is a hub then). Each forward is kept with its tab; it is cancelled (`-O cancel`) when the tab
// closes, the machine's link drops, the machine is removed, the setting goes off or the core stops,
// without waiting: the core loop reaps each cancel and tries a failed one again until ssh has it
// (the forward table below). Opening waits for ssh (each try at most PAGE_SSH_WAIT).
// Residual: while a forward is open, any process of this user on this Mac can reach that remote
// port through it, as with the user's own `ssh -L`.
//
// Test builds: a `via` machine has no ssh. Its "remote" is this Mac (a second core), so its
// forward is the port itself, kept in the table with nothing to cancel (tests/scripts/remote-page.sh).

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
PAGE_FORWARDS_MAX :: 16 // open at once, every machine's
PAGE_SSH_WAIT :: 3 * time.Second // each `ssh -O`: the master is local, so it answers at once
PAGE_SSH_TRIES :: 3 // a picked port another process took first: another one
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

// `ssh -O forward` (or cancel) on machine m's ControlMaster. Temp allocator.
machine_forward_argv :: proc(m: Machine, run: string, local, remote: int, cancel := false) -> (argv: []string, why: string) {
	if m.via != "" do return nil, "this machine is reached through a test build's command: it has no ssh"
	if w := machine_target_error(m.target); w != "" do return nil, w
	if local < 1 || local > 65535 || remote < 1 || remote > 65535 do return nil, "the port is 1 to 65535"
	ctl := machine_ctl_path(run, m.no)
	if len(ctl) > MACHINE_CTL_MAX do return nil, fmt.tprintf("ssh's control socket %s is longer than %d bytes", ctl, MACHINE_CTL_MAX)
	// -F /dev/null: the mux client sends every forward ssh_config gives the host with ours, so a
	// cancel would also cancel the user's own LocalForward/RemoteForward (-S names the master: no
	// config is needed). ClearAllForwardings would clear the command line's -L too.
	out := make([]string, 11, context.temp_allocator)
	out[0], out[1], out[2], out[3], out[4] = "ssh", "-F", "/dev/null", "-S", ctl
	out[5], out[6] = "-O", cancel ? "cancel" : "forward"
	out[7], out[8] = "-L", fmt.tprintf("127.0.0.1:%d:127.0.0.1:%d", local, remote)
	out[9], out[10] = "--", m.target
	return out, ""
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

// ---- the forward table (main thread) ----
//
// A forward stays in the table until ssh says it is gone: its cancel exited 0, or the master is
// gone (no control socket, or ssh cannot connect to it: its listeners went with it). A cancel runs
// as a child the core loop reaps (never waited for here); one that fails or takes longer than
// PAGE_SSH_WAIT is tried again after 2, 4, 8… s (at most PAGE_RETRY_MAX), for as long as the core
// runs, whether or not the machine is still listed (each entry holds its own cancel argv).

PAGE_RETRY_MAX :: 60 * time.Second
PAGE_OUT_MAX :: 1024 // of a cancel's output: enough for ssh's one line

Page_Phase :: enum u8 {
	Open, // its tab is open (or about to be)
	Closing, // its cancel runs (pid)
	Retry, // its cancel is due at next_at ({}: now)
}

Page_Forward :: struct {
	machine: u64,
	tab_id:  u64,
	local:   int, // this Mac's loopback port
	remote:  int, // the machine's
	opened:  time.Tick,
	waiting: bool, // its tab is not recorded yet (the window answered pending)
	phase:   Page_Phase,
	cancel:  []string, // `ssh -O cancel` (heap; nil: a test build's via machine, nothing to cancel)
	ctl:     string, // its master's control socket (heap)
	pid:     posix.pid_t, // Closing: the cancel
	fd:      posix.FD, // and its output (stdout and stderr; ours non-blocking)
	started: time.Tick,
	tries:   int,
	next_at: time.Tick,
	out:     [PAGE_OUT_MAX]u8,
	out_n:   int,
}

@(private = "file")
page: struct {
	forwards: [dynamic]Page_Forward,
}

when TEST_HOOKS {
	page_cancel_argv_for_test: []string // run in place of each `ssh -O cancel` (unit tests: no ssh)
}

page_forwards_list :: proc() -> []Page_Forward {return page.forwards[:]}

@(private = "file")
page_port_kept :: proc(local: int) -> bool {
	for f in page.forwards do if f.cancel != nil && f.local == local do return true
	return false
}

page_forwards_open :: proc() -> int {
	n := 0
	for f in page.forwards do if f.phase == .Open do n += 1
	return n
}

// Keeps f with a heap copy of its cancel argv and control socket. False: f is open and
// PAGE_FORWARDS_MAX are (closing ones do not count: they wait only for ssh).
page_forward_add :: proc(f: Page_Forward, cancel: []string, ctl: string) -> bool {
	if f.phase == .Open && page_forwards_open() >= PAGE_FORWARDS_MAX do return false
	heap := runtime.heap_allocator()
	if page.forwards == nil do page.forwards = make([dynamic]Page_Forward, heap)
	x := f
	x.cancel, x.ctl, x.pid, x.fd = nil, "", 0, -1
	if cancel != nil {
		x.cancel = make([]string, len(cancel), heap)
		for a, i in cancel do x.cancel[i] = strings.clone(a, heap)
		x.ctl = strings.clone(ctl, heap)
	}
	append(&page.forwards, x)
	return true
}

@(private = "file")
page_forward_remove :: proc(i: int) {
	f := &page.forwards[i]
	if f.fd >= 0 do posix.close(f.fd)
	heap := runtime.heap_allocator()
	for a in f.cancel do delete(a, heap)
	delete(f.cancel, heap)
	delete(f.ctl, heap)
	ordered_remove(&page.forwards, i)
}

// An open forward is to be cancelled: the next tick starts it.
@(private = "file")
page_forward_close :: proc(f: ^Page_Forward, why: string) {
	if autotest_active do fmt.printfln("[autotest] page forward %d closed: %s", f.local, why)
	f.phase, f.next_at, f.tries = .Retry, {}, 0
}

// Machine no's open forwards are cancelled (0: every machine's): its link dropped, it was removed or
// the setting went off. They stay in the table until ssh has cancelled them.
page_forwards_drop :: proc(no: u64) {
	for &f in page.forwards do if f.phase == .Open && (no == 0 || f.machine == no) do page_forward_close(&f, "its link ended")
}

// The core stops: every forward's cancel is tried once more, all at once, for at most PAGE_SSH_WAIT.
page_forwards_stop :: proc() {
	page_forwards_drop(0)
	for &f in page.forwards do if f.phase == .Retry do f.next_at = {}
	page_forwards_tick(time.tick_now())
	for {
		running := false
		for f in page.forwards do if f.phase == .Closing do running = true
		if !running do break
		time.sleep(20 * time.Millisecond)
		page_forwards_tick(time.tick_now(), retry = false)
	}
}

// The core loop's turn: a forward whose tab closed is cancelled (one the window answered pending
// waits PAGE_WAIT_TAB for its tab); cancels due start, running ones are reaped. Never blocks.
page_forwards_tick :: proc(now: time.Tick, alive := page_tab_alive, retry := true) {
	for i := len(page.forwards) - 1; i >= 0; i -= 1 {
		f := &page.forwards[i]
		if f.phase == .Open {
			if alive(f.tab_id) {
				f.waiting = false
				continue
			}
			if f.waiting && time.tick_diff(f.opened, now) <= PAGE_WAIT_TAB do continue
			page_forward_close(f, "its tab closed")
		}
		if f.phase == .Retry && retry && (f.next_at == {} || time.tick_diff(f.next_at, now) >= 0) {
			if page_cancel_start(f, now) {
				page_forward_remove(i)
				continue
			}
		}
		if f.phase == .Closing && page_cancel_reap(f, now) do page_forward_remove(i)
	}
}

page_tab_alive :: proc(tab_id: u64) -> bool {
	_, tab, _ := find_tab(tab_id)
	if tab == nil do return false
	_, is := tab.kind.(Browser_Tab)
	return is
}

// True: nothing is left to cancel (a via machine's, or the master is gone with its listeners).
@(private = "file")
page_cancel_start :: proc(f: ^Page_Forward, now: time.Tick) -> (gone: bool) {
	if f.cancel == nil do return true
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(f.ctl, context.temp_allocator), &st) != .OK && posix.errno() == .ENOENT do return true
	argv := f.cancel
	when TEST_HOOKS do if page_cancel_argv_for_test != nil do argv = page_cancel_argv_for_test
	pid, fd, ok := page_spawn(argv)
	if !ok {
		page_cancel_later(f, now)
		return false
	}
	f.phase, f.pid, f.fd, f.started, f.out_n = .Closing, pid, fd, now, 0
	return false
}

// True: the forward is gone. A cancel that failed (or ran past PAGE_SSH_WAIT: killed) is tried later.
@(private = "file")
page_cancel_reap :: proc(f: ^Page_Forward, now: time.Tick) -> (gone: bool) {
	page_cancel_read(f)
	st: i32
	if posix.waitpid(f.pid, &st, {.NOHANG}) != f.pid {
		if time.tick_diff(f.started, now) <= PAGE_SSH_WAIT do return false
		posix.killpg(f.pid, .SIGKILL)
		for posix.waitpid(f.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
		page_cancel_done(f)
		page_cancel_later(f, now)
		return false
	}
	page_cancel_read(f)
	page_cancel_done(f)
	if posix.WIFEXITED(st) && posix.WEXITSTATUS(st) == 0 do return true
	// "Control socket connect(<ctl>): Connection refused" (or No such file): no master, no listeners;
	// "… forwarding request failed: port not found" (mux.c): the master has no such forward (one it
	// never added, or an earlier cancel that it took before that ssh was killed)
	out := string(f.out[:f.out_n])
	if strings.contains(out, "Control socket connect") || strings.contains(out, "port not found") do return true
	page_cancel_later(f, now)
	return false
}

@(private = "file")
page_cancel_read :: proc(f: ^Page_Forward) {
	buf: [4096]u8
	for {
		n := posix.read(f.fd, &buf[0], len(buf))
		if n <= 0 do return
		k := copy(f.out[f.out_n:], buf[:n])
		f.out_n += k
	}
}

@(private = "file")
page_cancel_done :: proc(f: ^Page_Forward) {
	if f.fd >= 0 do posix.close(f.fd)
	f.pid, f.fd = 0, -1
}

@(private = "file")
page_cancel_later :: proc(f: ^Page_Forward, now: time.Tick) {
	f.tries += 1
	wait := time.Second << uint(min(f.tries, 6))
	if wait > PAGE_RETRY_MAX do wait = PAGE_RETRY_MAX
	f.phase, f.next_at = .Retry, time.tick_add(now, wait)
	if autotest_active do fmt.printfln("[autotest] page forward %d: cancel failed, again in %v", f.local, wait)
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
			f := &page.forwards[0]
			if f.pid > 0 {
				posix.killpg(f.pid, .SIGKILL)
				st: i32
				posix.waitpid(f.pid, &st, {})
			}
			page_forward_remove(0)
		}
		page_cancel_argv_for_test = nil
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
	if page_forwards_open() >= PAGE_FORWARDS_MAX do return fail(fmt.tprintf("%d web pages of other machines are open: close one first", PAGE_FORWARDS_MAX)), false
	s := machine_local_session()
	if s == nil do return fail("open a session on this Mac first: the page opens in a browser tab there"), false
	remote := int(c.port)
	local := 0
	cancel: []string // nil: a via machine's (nothing to cancel)
	ctl: string
	if m.via != "" {
		when !TEST_HOOKS do return fail("via is only for development and test builds"), false
		local = remote // a test build's "machine" is this Mac: its port is here already
	} else {
		run, rwhy := sock_runtime_dir_why(context.temp_allocator)
		if rwhy != "" do return fail(rwhy), false
		ctl = machine_ctl_path(run, m.no)
		why := "no free port on this Mac"
		for _ in 0 ..< PAGE_SSH_TRIES {
			try := page_free_port()
			if try == 0 || page_port_kept(try) do continue // one still being cancelled: never reused
			argv, aw := machine_forward_argv(m, run, try, remote)
			if aw != "" do return fail(aw), false
			undo, _ := machine_forward_argv(m, run, try, remote, cancel = true)
			out, st := run_group(argv, PAGE_SSH_WAIT, cap = MACHINE_STDERR_MAX, merge_stderr = true)
			if st == .Ok {
				local, cancel = try, undo
				break
			}
			why = st == .Timed_Out ? "ssh did not answer" : text_clean(machine_last_line(out), MACHINE_ERROR_MAX)
			if st == .Timed_Out || st == .Too_Big {
				// the master may still open it when it answers: cancelled as a closed tab's would be
				page_forward_add({machine = c.no, local = try, remote = remote, phase = .Retry}, undo, ctl)
				break
			}
			if st == .Start_Failed do break
		}
		if local == 0 do return fail(fmt.tprintf("ssh could not forward port %d of %s: %s", remote, m.name, why)), false
	}
	f := Page_Forward{machine = c.no, local = local, remote = remote, opened = time.tick_now()}
	r, ch, tab_id := browser_open_tab(s, machine_page_url(local, path), caller, request_id)
	if !r.ok {
		if autotest_active do fmt.printfln("[autotest] page forward %d closed: its tab did not open", local)
		f.phase = .Retry
		page_forward_add(f, cancel, ctl)
		return r, ch
	}
	f.tab_id, f.waiting = tab_id, r.pending
	page_forward_add(f, cancel, ctl) // room checked above
	if autotest_active do fmt.printfln("[autotest] page forward %d: %s port %d", local, m.name, remote)
	if !r.pending && s.id != state.current_session {
		focus_session(s.id, caller)
		ch = true
	}
	return r, ch
}
