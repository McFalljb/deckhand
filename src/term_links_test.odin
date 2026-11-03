package main

// Links in terminal tabs (term_links.odin): which URLs are found in a row of
// text, which schemes are refused, OSC 8 hyperlinks read from libghostty-vt,
// soft-wrapped URLs, and where terminal_link opens one.

import "base:runtime"
import "core:strings"
import "core:testing"
import gh "ghostty"

@(private = "file")
opened: [dynamic]string

// The URL found at rune index `at` of `line` ("" = none).
@(private = "file")
url_in :: proc(line: string, at: int) -> string {
	rs := make([dynamic]rune, context.temp_allocator)
	for r in line do append(&rs, r)
	lo, hi, ok := find_url_at(rs[:], at)
	if !ok do return ""
	b := strings.builder_make(context.temp_allocator)
	for r in rs[lo:hi + 1] do strings.write_rune(&b, r)
	return strings.to_string(b)
}

@(test)
term_url_detection :: proc(t: ^testing.T) {
	// a plain URL, the pointer anywhere on it
	testing.expect_value(t, url_in("see https://example.com/a/b now", 4), "https://example.com/a/b")
	testing.expect_value(t, url_in("see https://example.com/a/b now", 20), "https://example.com/a/b")
	testing.expect_value(t, url_in("see https://example.com/a/b now", 2), "")
	testing.expect_value(t, url_in("see https://example.com/a/b now", 27), "")
	// trailing punctuation is not part of it
	testing.expect_value(t, url_in("Go to https://example.com/x.", 8), "https://example.com/x")
	testing.expect_value(t, url_in("at https://example.com/x, then", 8), "https://example.com/x")
	testing.expect_value(t, url_in("is it https://example.com/x?", 8), "https://example.com/x")
	testing.expect_value(t, url_in("'https://example.com/q?a=1&b=2';", 3), "https://example.com/q?a=1&b=2")
	testing.expect_value(t, url_in("\"http://example.com/\"", 3), "http://example.com/")
	// closing brackets: only the ones the URL opened stay
	testing.expect_value(t, url_in("(see https://example.com/x)", 8), "https://example.com/x")
	testing.expect_value(t, url_in("(https://en.wikipedia.org/wiki/Foo_(bar))", 8), "https://en.wikipedia.org/wiki/Foo_(bar)")
	testing.expect_value(t, url_in("[link](https://example.com/y).", 10), "https://example.com/y")
	testing.expect_value(t, url_in("<https://example.com/z>", 4), "https://example.com/z")
	testing.expect_value(t, url_in("https://example.com/a[1]]", 4), "https://example.com/a[1]")
	// box drawing (pi's frames) and wide characters end it
	testing.expect_value(t, url_in("│https://example.com/x│", 4), "https://example.com/x")
	// mailto
	testing.expect_value(t, url_in("mail mailto:someone@example.invalid.", 8), "mailto:someone@example.invalid")
	// the scheme must start a word, and have something after it
	testing.expect_value(t, url_in("xhttps://example.com", 4), "")
	testing.expect_value(t, url_in("https:// nothing", 2), "")
	testing.expect_value(t, url_in("HTTPS://EXAMPLE.COM/", 2), "HTTPS://EXAMPLE.COM/")
	// two on a row: the one under the pointer
	testing.expect_value(t, url_in("http://a.example http://b.example", 20), "http://b.example")
	// other schemes are never found in text
	testing.expect_value(t, url_in("file:///etc/passwd", 3), "")
	testing.expect_value(t, url_in("javascript:alert(1)", 3), "")
	testing.expect_value(t, url_in("ftp://example.com/", 3), "")
}

@(test)
term_url_allowed_cases :: proc(t: ^testing.T) {
	for u in ([]string{"https://example.com", "http://localhost:8080/x", "mailto:a@example.invalid", "HTTPS://Example.com/"}) {
		testing.expectf(t, term_url_allowed(u), "%s should open", u)
	}
	for u in ([]string{"file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "vscode://x", "ssh://host", "https://", "http:///x", "mailto:", "https://exa mple.com", "https://example.com/\x07", "", "about:blank", "  https://example.com"}) {
		testing.expectf(t, !term_url_allowed(u), "%q should be refused", u)
	}
}

// A terminal of 30x5 with `text` written to it.
@(private = "file")
vt :: proc(text: string, cols: u16 = 30, rows: u16 = 5) -> gh.Terminal {
	g: gh.Terminal
	gh.terminal_new(nil, &g, cols, rows)
	gh.terminal_vt_write(g, raw_data(text), len(text))
	return g
}

@(test)
term_link_osc8 :: proc(t: ^testing.T) {
	// an OSC 8 link whose text is not its target, then plain text, then a refused one
	g := vt("a \x1b]8;;https://example.com/osc8\x1b\\click me\x1b]8;;\x1b\\ b\r\n\x1b]8;id=x;javascript:alert(1)\x1b\\bad\x1b]8;;\x1b\\ https://example.com/t\r\n")
	defer gh.terminal_free(g)
	l, ok := term_link_at_cell(g, 30, 5, {4, 0})
	testing.expect(t, ok, "the OSC 8 link")
	testing.expect_value(t, l.url, "https://example.com/osc8")
	testing.expect(t, l.osc8)
	testing.expect_value(t, l.a, [2]int{2, 0})
	testing.expect_value(t, l.b, [2]int{9, 0})
	_, ok = term_link_at_cell(g, 30, 5, {0, 0})
	testing.expect(t, !ok, "no link before it")
	_, ok = term_link_at_cell(g, 30, 5, {11, 0})
	testing.expect(t, !ok, "no link after it")
	// a javascript: target is never a link, whatever its text says
	_, ok = term_link_at_cell(g, 30, 5, {1, 1})
	testing.expect(t, !ok, "javascript: refused")
	// plain text beside it still is
	l, ok = term_link_at_cell(g, 30, 5, {10, 1})
	testing.expect(t, ok)
	testing.expect_value(t, l.url, "https://example.com/t")
	testing.expect(t, !l.osc8)
	testing.expect_value(t, l.a, [2]int{4, 1})
	testing.expect_value(t, l.b, [2]int{24, 1})
}

@(test)
term_link_soft_wrap :: proc(t: ^testing.T) {
	// 20 columns: the URL soft-wraps onto the next two rows
	url := "https://example.com/aaaaaaaaaabbbbbbbbbbcccccccccc"
	g := vt(strings.concatenate({"go ", url, " ok\r\n"}, context.temp_allocator), 20, 5)
	defer gh.terminal_free(g)
	for at in ([][2]int{{3, 0}, {5, 1}, {12, 2}}) {
		l, ok := term_link_at_cell(g, 20, 5, at)
		testing.expectf(t, ok, "a link at %v", at)
		testing.expect_value(t, l.url, url)
		testing.expect_value(t, l.a, [2]int{3, 0})
		testing.expect_value(t, l.b, [2]int{12, 2})
	}
	_, ok := term_link_at_cell(g, 20, 5, {15, 2})
	testing.expect(t, !ok, "past its end")
	// a hard line break ends it
	g2 := vt("https://example.com/a\r\nbcd\r\n", 20, 5)
	defer gh.terminal_free(g2)
	l, ok2 := term_link_at_cell(g2, 20, 5, {2, 0})
	testing.expect(t, ok2)
	testing.expect_value(t, l.url, "https://example.com/a")
	_, ok2 = term_link_at_cell(g2, 20, 5, {1, 1})
	testing.expect(t, !ok2)
}

// A State with one open session holding a shell tab (no process) and Home.
@(private = "file")
link_setup :: proc() -> (shell_tab, home_tab_id: u64) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT}}
	clear(&opened)
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}, open_url = proc(url: string) -> bool {append(&opened, strings.clone(url, runtime.heap_allocator())); return true}}
	append(&state.projects, Project{id = new_id(), cwd = "/tmp", label = "proj"})
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("s-1"), project_id = state.projects[0].id, cwd = "/tmp"}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Exited})
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "sh", status = .Exited})
	shell_tab = s.tabs[1].id
	s.active_tab = shell_tab
	append(&state.open_sessions, s)
	state.current_session = s.id
	h := Open_Session{id = new_id(), home = true}
	append(&h.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "Atlas", status = .Exited})
	home_tab_id = h.tabs[0].id
	append(&state.open_sessions, h)
	return
}

@(test)
term_link_command :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tab, home := link_setup()
	ui := Caller{kind = .UI}
	// refused schemes never open, whoever asks
	for u in ([]string{"file:///etc/passwd", "javascript:alert(1)", "data:text/html,x", "myapp://x"}) {
		r := run_command(Terminal_Link{tab_id = tab, url = u}, ui)
		testing.expectf(t, !r.ok, "%s refused", u)
	}
	testing.expect_value(t, len(opened), 0)
	// only the user (a click) opens links from a terminal
	r := run_command(Terminal_Link{tab_id = tab, url = "https://example.com/x"}, {kind = .Control})
	testing.expect(t, !r.ok, "not for agents")
	r = run_command(Terminal_Link{tab_id = tab, url = "https://example.com/x"}, {kind = .Script})
	testing.expect(t, !r.ok, "not for scripts")
	// mailto and ⇧⌘ (external) go to the default app
	r = run_command(Terminal_Link{tab_id = tab, url = "mailto:a@example.invalid"}, ui)
	testing.expect(t, r.ok, r.error)
	r = run_command(Terminal_Link{tab_id = tab, url = "https://example.com/ext", external = true}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(opened), 2)
	if len(opened) == 2 {
		testing.expect_value(t, opened[0], "mailto:a@example.invalid")
		testing.expect_value(t, opened[1], "https://example.com/ext")
	}
	// http(s): pi-desk's browser in the terminal's session, in front, when the build has
	// one; without CEF (this test build) the default browser
	n := len(state.open_sessions[0].tabs)
	r = run_command(Terminal_Link{tab_id = tab, url = "https://example.com/b"}, ui)
	testing.expect(t, r.ok, r.error)
	if CEF_BUILT_IN {
		testing.expect_value(t, len(state.open_sessions[0].tabs), n + 1)
		testing.expect_value(t, state.open_sessions[0].active_tab, r.created_id)
	} else {
		testing.expect_value(t, len(state.open_sessions[0].tabs), n)
		testing.expect_value(t, opened[len(opened) - 1], "https://example.com/b")
	}
	// Home's terminal (Atlas) has no browser tabs: the default browser
	before := len(opened)
	r = run_command(Terminal_Link{tab_id = home, url = "https://example.com/h"}, ui)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(opened), before + 1)
	// not a terminal tab
	r = run_command(Terminal_Link{tab_id = 999999, url = "https://example.com/x"}, ui)
	testing.expect(t, !r.ok)
}

@(test)
term_link_menu :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tab, _ := link_setup()
	menu_open(Menu_Term_Link{tab_id = tab, url = "https://example.com/m"}, {10, 10})
	defer menu_close()
	labels := make([dynamic]string, context.temp_allocator)
	open_cmd: Command
	copy := ""
	for it in menu_items() {
		append(&labels, it.label)
		if it.label == "Open link" do open_cmd = it.cmd
		if it.label == "Copy link" do copy = it.copy
	}
	testing.expectf(t, slice_has(labels[:], "https://example.com/m"), "the URL shows: %v", labels)
	testing.expectf(t, slice_has(labels[:], "Open link"), "Open link: %v", labels)
	testing.expectf(t, slice_has(labels[:], "Open in default browser"), "Open in default browser: %v", labels)
	testing.expect_value(t, copy, "https://example.com/m")
	c, is := open_cmd.(Terminal_Link)
	testing.expect(t, is && c.url == "https://example.com/m" && c.tab_id == tab && !c.external)
	// a mail link: no browser row
	menu_open(Menu_Term_Link{tab_id = tab, url = "mailto:a@example.invalid"}, {10, 10})
	for it in menu_items() do testing.expect(t, it.label != "Open in default browser")

	slice_has :: proc(xs: []string, x: string) -> bool {
		for y in xs do if y == x do return true
		return false
	}
}

// ---- review round 1 ----

@(test)
term_url_refuses_misleading :: proc(t: ^testing.T) {
	// #2: a backslash anywhere, user info before the host
	for u in ([]string{"https://a.com\\@evil.com/", "https://a.com/x\\y", "https://user@evil.com/", "https://a.com:pw@evil.com", "http://good.example@evil.example/x"}) {
		testing.expectf(t, !term_url_allowed(u), "%q should be refused", u)
	}
	// an @ in the path or query is fine
	for u in ([]string{"https://example.com/@user", "https://example.com/?to=a@b.c", "mailto:a@example.invalid"}) {
		testing.expectf(t, term_url_allowed(u), "%q should open", u)
	}
	// #4: the scheme compares as ASCII (İ lowercases to i)
	testing.expect(t, !term_url_allowed("maİlto:a@example.invalid"), "maİlto refused")
	testing.expect(t, !term_url_allowed("httpſ://example.com"), "httpſ refused")
	testing.expect_value(t, url_in("x maİlto:a@example.invalid", 4), "")
	// #5: anything one_line would change, and invalid UTF-8
	for u in ([]string{"https://example.com/‮evil", "https://exa​mple.com/", "https://example.com/⁦x", "https://example.com/\xff", "https://example.com/­"}) {
		testing.expectf(t, !term_url_allowed(u), "%q should be refused", u)
	}
}

@(test)
term_link_wide :: proc(t: ^testing.T) {
	// #3: a wide character's second cell does not end the URL
	testing.expect_value(t, url_in("see https://日本.jp/x now", 6), "https://日本.jp/x")
	g := vt("a https://日本.jp/x b\r\n\x1b]8;;https://example.com/jp\x1b\\日本語\x1b]8;;\x1b\\ c\r\n")
	defer gh.terminal_free(g)
	// "a " then h..// (8 cells) at 2..9, 日 10-11, 本 12-13, ".jp/x" 14..18
	for x in ([]int{3, 10, 11, 13, 18}) {
		l, ok := term_link_at_cell(g, 30, 5, {x, 0})
		testing.expectf(t, ok, "a link at %d", x)
		testing.expect_value(t, l.url, "https://日本.jp/x")
		testing.expect_value(t, l.a, [2]int{2, 0})
		testing.expect_value(t, l.b, [2]int{18, 0})
	}
	// an OSC 8 link on wide text: every cell of it, the second halves too
	for x in ([]int{0, 1, 4, 5}) {
		l, ok := term_link_at_cell(g, 30, 5, {x, 1})
		testing.expectf(t, ok, "the OSC 8 link at %d", x)
		testing.expect_value(t, l.url, "https://example.com/jp")
		testing.expect_value(t, l.a, [2]int{0, 1})
		testing.expect_value(t, l.b, [2]int{5, 1})
	}
}

@(test)
term_link_events :: proc(t: ^testing.T) {
	// #6: an event never shows a user name or password; the command targets its tab
	red := command_json(Terminal_Link{tab_id = 5, url = "https://alice:pw@example.com/x"}, redact = true)
	testing.expectf(t, !strings.contains(red, "pw") && !strings.contains(red, "alice"), "redacted: %s", red)
	testing.expect_value(t, command_tab(Terminal_Link{tab_id = 5, url = "https://example.com"}), 5)
}

@(test)
term_link_label_keeps_host :: proc(t: ^testing.T) {
	// #2: a long URL is cut in its path or query, never in scheme://host
	long := strings.concatenate({"https://example.com/", strings.repeat("a", 300, context.temp_allocator), "/end"}, context.temp_allocator)
	got := link_label(long, 60)
	testing.expectf(t, strings.has_prefix(got, "https://example.com/"), "host kept: %q", got)
	testing.expectf(t, strings.has_suffix(got, "/end"), "end kept: %q", got)
	testing.expectf(t, strings.contains(got, "…") && strings.rune_count(got) <= 60, "cut to 60: %q", got)
	// a host longer than the budget: cut in its middle, its end kept (round 2)
	host := strings.concatenate({"https://", strings.repeat("b", 100, context.temp_allocator), ".example.com/path/x"}, context.temp_allocator)
	got = link_label(host, 60)
	testing.expectf(t, strings.has_prefix(got, "https://b") && strings.has_suffix(got, "bbb.example.com") && strings.rune_count(got) <= 60, "host cut in its middle: %q", got)
	// short ones as they are
	testing.expect_value(t, link_label("https://example.com/x", 60), "https://example.com/x")
}

@(test)
term_link_open_fails :: proc(t: ^testing.T) {
	// #5: the default app refusing the URL is a failure, not ok
	context.allocator = runtime.heap_allocator()
	tab, _ := link_setup()
	platform.open_url = proc(url: string) -> bool {return false}
	r := run_command(Terminal_Link{tab_id = tab, url = "mailto:a@example.invalid"}, {kind = .UI})
	testing.expect(t, !r.ok, "open_url refused: not ok")
}

@(test)
term_link_rescan :: proc(t: ^testing.T) {
	// #8: the hover is looked up again only when the pointer moved or the grid changed
	context.allocator = runtime.heap_allocator()
	saved_w, saved_h := font.cell_w, font.cell_h
	defer font.cell_w, font.cell_h = saved_w, saved_h
	font.cell_w, font.cell_h = 10, 20
	g := vt("a https://example.com/x b\r\n")
	tm := Term{gt = g, cols = 30, rows = 5, w = 300, h = 100}
	defer {
		term_link_clear(&tm)
		gh.terminal_free(g)
	}
	link_cmd_held = true
	defer link_cmd_held = false
	pt := [2]f32{term_pad() + 5 * 10 + 5, term_pad() + 10}
	testing.expect(t, term_link_tick(&tm, pt))
	testing.expect_value(t, tm.link.url, "https://example.com/x")
	scans := tm.link_scans
	for _ in 0 ..< 5 do term_link_tick(&tm, pt)
	testing.expect_value(t, tm.link_scans, scans)
	// output arrives: looked up again
	s := "more\r\n"
	gh.terminal_vt_write(g, raw_data(s), len(s))
	tm.bytes_in += len(s)
	term_link_tick(&tm, pt)
	testing.expect_value(t, tm.link_scans, scans + 1)
	// the pointer moves: again
	term_link_tick(&tm, pt + {10, 0})
	testing.expect_value(t, tm.link_scans, scans + 2)
	// ⌘ let go: no link, whatever the grid
	link_cmd_held = false
	testing.expect(t, !term_link_tick(&tm, pt))
	testing.expect(t, !tm.link_on)
}

// ---- review round 2 ----

@(test)
term_link_label_bounded :: proc(t: ^testing.T) {
	// a mail link with a huge body: cut after the address
	body := strings.repeat("x", 60 * 1024, context.temp_allocator)
	mail := strings.concatenate({"mailto:a@example.invalid?body=", body}, context.temp_allocator)
	got := link_label(mail, 80)
	testing.expectf(t, strings.rune_count(got) <= 80, "mailto within 80: %d runes", strings.rune_count(got))
	testing.expectf(t, strings.has_prefix(got, "mailto:a@example.invalid"), "address kept: %q", got[:min(len(got), 100)])
	// a 300-character host: cut in its middle, its end (the registrable domain) kept
	host := strings.concatenate({"https://accounts.google.com.", strings.repeat("q", 260, context.temp_allocator), ".evil.io/login"}, context.temp_allocator)
	for max in ([]int{80, 60, 40}) {
		got = link_label(host, max)
		testing.expectf(t, strings.rune_count(got) <= max, "host within %d: %d runes %q", max, strings.rune_count(got), got[:min(len(got), 120)])
		testing.expectf(t, strings.contains(got, "qqqq.evil.io"), "host tail kept: %q", got[:min(len(got), 120)])
		testing.expectf(t, strings.has_prefix(got, "https://"), "scheme kept: %q", got[:min(len(got), 120)])
	}
	// a host that fits leaves no room for the path: still bounded
	h2 := strings.concatenate({"https://", strings.repeat("b", 77, context.temp_allocator), ".io/", strings.repeat("p", 50, context.temp_allocator)}, context.temp_allocator)
	got = link_label(h2, 80)
	testing.expectf(t, strings.rune_count(got) <= 80, "tight budget within 80: %d", strings.rune_count(got))
}
