package core

// A machine's web page in a local browser tab (issue #5; the user's decision of 2026-11-09): the
// user asks for a port on another machine (a dev server on its localhost:3000), and this core asks
// that machine's ssh ControlMaster (machines.odin's `ssh-<n>.ctl`) for a local forward:
//   ssh -S <ctl> -O forward -L 127.0.0.1:<local>:127.0.0.1:<port> -- <target>
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
// closes, the machine's link drops, the machine is removed, the setting goes off or the core stops.
// Residual: while a forward is open, any process of this user on this Mac can reach that remote
// port through it, as with the user's own `ssh -L`.
//
// Test builds: a `via` machine has no ssh. Its "remote" is this Mac (a second core), so its
// forward is the port itself, kept in the table with nothing to cancel (tests/scripts/remote-page.sh).

import "core:fmt"
import "core:strconv"
import "core:strings"
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

Page_Forward :: struct {
	machine: u64,
	tab_id:  u64,
	local:   int, // this Mac's loopback port
	remote:  int, // the machine's
	ssh:     bool, // false: a test build's via machine (nothing to cancel)
	opened:  time.Tick,
	waiting: bool, // its tab is not recorded yet (the window answered pending)
}

@(private = "file")
page: struct {
	forwards: [dynamic]Page_Forward,
}

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
	out := make([]string, 9, context.temp_allocator)
	out[0], out[1], out[2], out[3], out[4] = "ssh", "-S", ctl, "-O", cancel ? "cancel" : "forward"
	out[5], out[6] = "-L", fmt.tprintf("127.0.0.1:%d:127.0.0.1:%d", local, remote)
	out[7], out[8] = "--", m.target
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

page_forwards_list :: proc() -> []Page_Forward {return page.forwards[:]}

// False: PAGE_FORWARDS_MAX are open.
page_forward_add :: proc(f: Page_Forward) -> bool {
	if len(page.forwards) >= PAGE_FORWARDS_MAX do return false
	if page.forwards == nil do page.forwards = make([dynamic]Page_Forward, runtime.heap_allocator())
	append(&page.forwards, f)
	return true
}

// Machine no's forwards are cancelled (0: every machine's): its link dropped, it was removed, the
// setting went off, or the core stops.
page_forwards_drop :: proc(no: u64) {
	stuck: [PAGE_FORWARDS_MAX]u64 // machines whose master did not answer: their other cancels are not tried
	n := 0
	outer: for i := len(page.forwards) - 1; i >= 0; i -= 1 {
		f := page.forwards[i]
		if no != 0 && f.machine != no do continue
		ordered_remove(&page.forwards, i)
		for x in stuck[:n] do if x == f.machine {
			f.ssh = false // not tried: that master did not answer the last one
			_ = page_forward_cancel(f, "its link ended")
			continue outer
		}
		if page_forward_cancel(f, "its link ended") == .Timed_Out && n < len(stuck) {
			stuck[n] = f.machine
			n += 1
		}
	}
}

// The core loop's turn: a forward whose tab closed is cancelled (one the window answered pending
// waits PAGE_WAIT_TAB for its tab).
page_forwards_tick :: proc(now: time.Tick, alive := page_tab_alive) {
	for i := len(page.forwards) - 1; i >= 0; i -= 1 {
		f := &page.forwards[i]
		if alive(f.tab_id) {
			f.waiting = false
			continue
		}
		if f.waiting && time.tick_diff(f.opened, now) <= PAGE_WAIT_TAB do continue
		x := f^
		ordered_remove(&page.forwards, i)
		_ = page_forward_cancel(x, "its tab closed")
	}
}

page_tab_alive :: proc(tab_id: u64) -> bool {
	_, tab, _ := find_tab(tab_id)
	if tab == nil do return false
	_, is := tab.kind.(Browser_Tab)
	return is
}

@(private = "file")
page_forward_cancel :: proc(f: Page_Forward, why: string) -> Run_Status {
	if autotest_active do fmt.printfln("[autotest] page forward %d closed: %s", f.local, why)
	if !f.ssh do return .Ok
	m, ok := machine_entry(f.machine)
	run, rwhy := sock_runtime_dir_why(context.temp_allocator)
	if !ok || rwhy != "" do return .Ok // removed: machine_remove_apply cancels before the entry goes
	argv, aw := machine_forward_argv(m, run, f.local, f.remote, cancel = true)
	if aw != "" do return .Ok
	// a master already gone answers at once; the forward went with it
	_, st := run_group(argv, PAGE_SSH_WAIT, cap = MACHINE_STDERR_MAX, merge_stderr = true)
	return st
}

when TEST_HOOKS {
	page_forwards_reset_for_test :: proc() {
		clear(&page.forwards)
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
	if len(page.forwards) >= PAGE_FORWARDS_MAX do return fail(fmt.tprintf("%d web pages of other machines are open: close one first", PAGE_FORWARDS_MAX)), false
	s := machine_local_session()
	if s == nil do return fail("open a session on this Mac first: the page opens in a browser tab there"), false
	remote := int(c.port)
	local := 0
	via := m.via != ""
	if via {
		when !TEST_HOOKS do return fail("via is only for development and test builds"), false
		local = remote // a test build's "machine" is this Mac: its port is here already
	} else {
		run, rwhy := sock_runtime_dir_why(context.temp_allocator)
		if rwhy != "" do return fail(rwhy), false
		why := "no free port on this Mac"
		for _ in 0 ..< PAGE_SSH_TRIES {
			try := page_free_port()
			if try == 0 do continue
			argv, aw := machine_forward_argv(m, run, try, remote)
			if aw != "" do return fail(aw), false
			out, st := run_group(argv, PAGE_SSH_WAIT, cap = MACHINE_STDERR_MAX, merge_stderr = true)
			if st == .Ok {
				local = try
				break
			}
			why = st == .Timed_Out ? "ssh did not answer" : text_clean(machine_last_line(out), MACHINE_ERROR_MAX)
			if st == .Timed_Out || st == .Start_Failed do break
		}
		if local == 0 do return fail(fmt.tprintf("ssh could not forward port %d of %s: %s", remote, m.name, why)), false
	}
	f := Page_Forward{machine = c.no, local = local, remote = remote, ssh = !via, opened = time.tick_now()}
	r, ch, tab_id := browser_open_tab(s, machine_page_url(local, path), caller, request_id)
	if !r.ok {
		_ = page_forward_cancel(f, "its tab did not open")
		return r, ch
	}
	f.tab_id, f.waiting = tab_id, r.pending
	page_forward_add(f) // room checked above
	if autotest_active do fmt.printfln("[autotest] page forward %d: %s port %d", local, m.name, remote)
	if !r.pending && s.id != state.current_session {
		focus_session(s.id, caller)
		ch = true
	}
	return r, ch
}
