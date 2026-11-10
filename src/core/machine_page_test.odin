package core

// A machine's web page in a local tab (machine_page.odin; issue #5): the ssh argv, the port and
// path checks, the palette's "PORT[/path]" and the forward table. No ssh runs here; the scene
// remote-page.sh opens one through a test build's `via` machine.

import "core:strings"
import "core:testing"
import "core:time"

@(test)
machine_page_forward_argv :: proc(t: ^testing.T) {
	run := "/Users/someone/Library/Application Support/Deckhand/run"
	m := Machine{no = 7, name = "nuc", target = "me@nuc"}
	argv, why := machine_forward_argv(m, run, 41234, 3000)
	testing.expect_value(t, why, "")
	want := []string{"ssh", "-S", machine_ctl_path(run, 7), "-O", "forward", "-L", "127.0.0.1:41234:127.0.0.1:3000", "--", "me@nuc"}
	testing.expectf(t, slice_eq(argv, want), "forward argv %v", argv)
	argv, why = machine_forward_argv(m, run, 41234, 3000, cancel = true)
	want[4] = "cancel"
	testing.expectf(t, why == "" && slice_eq(argv, want), "cancel argv %v", argv)
	// what the user typed never becomes an option, and a via machine has no ssh
	for bad in ([?]string{"-oProxyCommand=touch /tmp/x", "a;b", "host name"}) {
		x := m
		x.target = bad
		_, why = machine_forward_argv(x, run, 41234, 3000)
		testing.expectf(t, why != "", "target %q refused", bad)
	}
	_, why = machine_forward_argv({no = 7, via = "x connect"}, run, 41234, 3000)
	testing.expect(t, why != "", "a via machine has no ssh to forward with")
	_, why = machine_forward_argv(m, run, 0, 3000)
	testing.expect(t, why != "", "local port 0 refused")
	_, why = machine_forward_argv(m, run, 41234, 70000)
	testing.expect(t, why != "", "remote port past 65535 refused")
	_, why = machine_forward_argv(m, strings.concatenate({run, "/a-much-longer-folder-name"}, context.temp_allocator), 41234, 3000)
	testing.expect(t, strings.contains(why, "control socket"), why)

	slice_eq :: proc(a, b: []string) -> bool {
		if len(a) != len(b) do return false
		for x, i in a do if x != b[i] do return false
		return true
	}
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
machine_page_forward_table :: proc(t: ^testing.T) {
	page_forwards_reset_for_test()
	defer page_forwards_reset_for_test()
	now := time.tick_now()
	// test builds' via machines (ssh false): nothing runs when one goes
	testing.expect(t, page_forward_add({machine = 3, tab_id = 10, local = 3000, remote = 3000, opened = now}))
	testing.expect(t, page_forward_add({machine = 3, tab_id = 11, local = 3001, remote = 3001, opened = now}))
	testing.expect(t, page_forward_add({machine = 4, tab_id = 12, local = 3002, remote = 3002, opened = now}))
	testing.expect(t, page_forward_add({machine = 4, tab_id = 13, local = 3003, remote = 3003, opened = now, waiting = true}))
	testing.expect_value(t, len(page_forwards_list()), 4)
	alive :: proc(id: u64) -> bool {return id == 10 || id == 12}
	// tab 11 closed: its forward goes; 13's tab is not recorded yet (the window answered pending)
	page_forwards_tick(now, alive)
	testing.expect_value(t, len(page_forwards_list()), 3)
	for f in page_forwards_list() do testing.expect(t, f.tab_id != 11, "tab 11's forward went")
	// still not there after the window's wait: it goes too
	page_forwards_tick(time.tick_add(now, PAGE_WAIT_TAB + time.Second), alive)
	testing.expect_value(t, len(page_forwards_list()), 2)
	// machine 3's link drops (or it is removed): its forwards go, machine 4's stay
	page_forwards_drop(3)
	testing.expect_value(t, len(page_forwards_list()), 1)
	testing.expect_value(t, page_forwards_list()[0].tab_id, u64(12))
	// a cap on how many are open
	for i in 0 ..< PAGE_FORWARDS_MAX - 1 do testing.expect(t, page_forward_add({machine = 5, tab_id = u64(100 + i), opened = now}))
	testing.expect(t, !page_forward_add({machine = 5, tab_id = 999, opened = now}), "past the cap: refused")
	page_forwards_drop(0) // 0: every machine's (the core stops)
	testing.expect_value(t, len(page_forwards_list()), 0)
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
