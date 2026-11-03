package main

// Browser tab polish (browser_polish.odin; `./build.sh test`): safe download names and never
// overwriting, zoom steps, the right-click menu's "Open link in new tab" staying in the tab's own
// session, the blocked popup opening there, the commands being the user's only, the wire format.
// No CEF here: what needs a page is in tests/scripts/browser-polish*.txt.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
bp_reset :: proc() -> (a, b: u64) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	for id, _ in browsers do browser_drop(id)
	state = State{}
	platform = {}
	for name in ([]string{"alpha", "beta"}) {
		s := Open_Session{id = new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
	}
	state.current_session = state.open_sessions[0].id
	return state.open_sessions[0].id, state.open_sessions[1].id
}

@(test)
browser_download_safe_names :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"report.pdf", "report.pdf"},
		{"../../etc/passwd", "passwd"},
		{"a/b\\c.txt", "c.txt"},
		{".bashrc", "bashrc"},
		{"  ..hidden.txt", "hidden.txt"},
		{".hidden: report.txt", "hidden_ report.txt"},
		{"", "download"},
		{"..", "download"},
		{"dir/", "download"},
		{"a\x00b\x1fc\x7f.txt", "abc.txt"},
		{"evil‮txt.exe", "eviltxt.exe"},
		{"name.txt  ", "name.txt"},
		{"bücher.pdf", "bücher.pdf"},
	}
	for c in cases {
		got := download_safe_name(c[0])
		testing.expectf(t, got == c[1], "%q -> %q, want %q", c[0], got, c[1])
	}
	// long names: capped, the extension kept, never half a character
	long := strings.concatenate({strings.repeat("é", 150, context.temp_allocator), ".tar"}, context.temp_allocator)
	got := download_safe_name(long)
	testing.expect(t, len(got) <= DOWNLOAD_NAME_MAX && strings.has_suffix(got, ".tar"), got)
	testing.expect(t, strings.has_suffix(got[:len(got) - 4], "é"), "a whole character")
	// numbered names
	testing.expect_value(t, download_try_name("a.txt", 0), "a.txt")
	testing.expect_value(t, download_try_name("a.txt", 2), "a (2).txt")
	testing.expect_value(t, download_try_name("noext", 1), "noext (1)")
	testing.expect_value(t, download_try_name(".txt", 1), ".txt (1)")
}

// An existing file is never overwritten: the next free "name (n).ext" is reserved.
@(test)
browser_download_never_overwrites :: proc(t: ^testing.T) {
	dir := fmt.tprintf("build/test-data/bp-dl-%d", new_id())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	keep := fmt.tprintf("%s/a.txt", dir)
	_ = os.write_entire_file(keep, transmute([]u8)string("mine"))
	p1 := download_reserve(dir, "a.txt")
	p2 := download_reserve(dir, "a.txt")
	testing.expect_value(t, p1, fmt.tprintf("%s/a (1).txt", dir))
	testing.expect_value(t, p2, fmt.tprintf("%s/a (2).txt", dir))
	data, _ := os.read_entire_file(keep, context.temp_allocator)
	testing.expect_value(t, string(data), "mine")
	// a folder at the name is not taken either
	os.make_directory_all(fmt.tprintf("%s/sub", dir))
	p3 := download_reserve(dir, "sub")
	testing.expect_value(t, p3, fmt.tprintf("%s/sub (1)", dir))
	// no folder: nothing reserved
	testing.expect_value(t, download_reserve(fmt.tprintf("%s/missing", dir), "a.txt"), "")
}

@(test)
browser_zoom_steps :: proc(t: ^testing.T) {
	testing.expect_value(t, zoom_json(0), "1")
	l := zoom_next(0, .In)
	testing.expect_value(t, zoom_json(l), "1.1")
	l = zoom_next(l, .In)
	testing.expect_value(t, zoom_json(l), "1.25")
	testing.expect_value(t, zoom_percent(l), "125%")
	testing.expect_value(t, zoom_json(zoom_next(0, .Out)), "0.9")
	testing.expect_value(t, zoom_next(l, .Reset), 0.0)
	// the ends stay
	top := zoom_level(5)
	testing.expect_value(t, zoom_next(top, .In), top)
	bottom := zoom_level(0.25)
	testing.expect_value(t, zoom_next(bottom, .Out), bottom)
	testing.expect_value(t, zoom_json(zoom_level(1.0 / 3)), "0.33")
}

// The page's menu: "Open link in new tab" names the tab's own session, even with another on screen.
@(test)
browser_menu_link_stays_in_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	r := run_command(Browser_Open{session = b, url = "https://b.example"}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	tb := r.created_id
	testing.expect_value(t, state.current_session, a) // alpha on screen
	items := make([dynamic]Menu_Item, context.temp_allocator)
	browser_menu_items(Menu_Browser{tab_id = tb, link = "https://b.example/next", flags = CM_LINK}, &items)
	found := false
	for it in items {
		if it.label != "Open link in new tab" do continue
		found = true
		o, is := it.cmd.(Browser_Open)
		testing.expect(t, is && o.session == b && o.url == "https://b.example/next", "in beta")
		r = run_command(it.cmd, {kind = .UI})
		testing.expect(t, r.ok, r.error)
		s, _, _ := find_tab(r.created_id)
		testing.expect(t, s != nil && s.id == b, "opened in beta")
	}
	testing.expect(t, found, "Open link in new tab offered")
	// a link pi-desk does not open: no "Open link in new tab", Copy link still
	clear(&items)
	browser_menu_items(Menu_Browser{tab_id = tb, link = "javascript:alert(1)", flags = CM_LINK}, &items)
	labels := make([dynamic]string, context.temp_allocator)
	for it in items do append(&labels, it.sep ? "--" : it.label)
	testing.expect_value(t, strings.join(labels[:], "|", context.temp_allocator), "Reload|--|Copy link|--|Inspect")
	// an editable field that can paste
	clear(&items)
	clear(&labels)
	browser_menu_items(Menu_Browser{tab_id = tb, flags = CM_EDITABLE, edit = CM_CAN_PASTE | CM_CAN_SELECT_ALL}, &items)
	for it in items do append(&labels, it.sep ? "--" : it.label)
	testing.expect_value(t, strings.join(labels[:], "|", context.temp_allocator), "Reload|--|Paste|Select all|--|Inspect")
	// the ⋯ menu: every action has a row
	clear(&items)
	clear(&labels)
	browser_menu_items(Menu_Browser{tab_id = tb, more = true}, &items)
	for it in items do append(&labels, it.sep ? "--" : it.label)
	testing.expect_value(t, strings.join(labels[:], "|", context.temp_allocator), "Find in page|--|Zoom: 100%|Zoom in|Zoom out|Actual size|--|Copy URL|Open in default browser|--|DevTools|Show downloads folder")
}

// The blocked popup opens in the opener's session, not the one on screen; × only drops the bar.
@(test)
browser_popup_opens_in_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	r := run_command(Browser_Open{session = b, url = "https://b.example"}, {kind = .UI})
	tb := r.created_id
	r = run_command(Browser_Popup{tab_id = tb, open = true}, {kind = .UI})
	testing.expect(t, !r.ok && r.error == "no popup was blocked", r.error)
	run_command(Browser_Update{tab_id = tb, what = {.Blocked}, blocked = "https://pop.example/"}, {kind = .Internal})
	r = run_command(Browser_Popup{tab_id = tb, open = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	s, tab, _ := find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == b && state.current_session == a, "in beta, alpha stays on screen")
	testing.expect_value(t, tab.kind.(Browser_Tab).url, "https://pop.example/")
	_, tab, _ = find_tab(tb)
	testing.expect_value(t, tab.kind.(Browser_Tab).blocked_popup, "")
	run_command(Browser_Update{tab_id = tb, what = {.Blocked}, blocked = "https://pop.example/2"}, {kind = .Internal})
	n := len(find_session(b).tabs)
	r = run_command(Browser_Popup{tab_id = tb, open = false}, {kind = .UI})
	testing.expect(t, r.ok && len(find_session(b).tabs) == n, "× opens nothing")
	_, tab, _ = find_tab(tb)
	testing.expect_value(t, tab.kind.(Browser_Tab).blocked_popup, "")
}

// The polish commands are the user's only (agents get page tools in steps 7 and 8).
@(test)
browser_polish_commands_user_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	r := run_command(Browser_Open{session = a, url = "https://a.example"}, {kind = .UI})
	ta := r.created_id
	pi := find_session(a).tabs[0].id
	cmds := []Command {
		Browser_Zoom{ta, .In},
		Browser_Find{tab_id = ta, text = "x"},
		Browser_Find_Close{ta},
		Browser_Dialog{tab_id = ta, ok = true},
		Browser_Permission{ta, true},
		Browser_Popup{ta, true},
		Browser_Edit{ta, .Paste},
		Browser_Devtools{tab_id = ta, x = -1, y = -1},
		Browser_External{ta},
		Browser_Download{0, .Reveal},
	}
	for cmd in cmds {
		for caller in ([]Caller{{kind = .Panel, tab_id = pi}, {kind = .Control}, {kind = .Script}, {kind = .App, tab_id = 1}}) {
			r = run_command(cmd, caller)
			testing.expectf(t, !r.ok, "%s from %v should be refused", command_type(cmd), caller.kind)
		}
	}
	// the user's: refused for want of a page, not the caller
	r = run_command(Browser_Zoom{ta, .In}, {kind = .UI})
	testing.expect(t, !r.ok && r.error == "the page is not loaded", r.error)
	r = run_command(Browser_Zoom{pi, .In}, {kind = .UI})
	testing.expect(t, !r.ok && r.error == "not a browser tab", r.error)
	// Open in default browser: web addresses only
	testing.expect(t, browser_external_ok("https://x.example") && browser_external_ok("HTTP://x"))
	testing.expect(t, !browser_external_ok("file:///etc/passwd") && !browser_external_ok("pidesk-test://web/a.html") && !browser_external_ok("about:blank"))
}

@(test)
browser_polish_names_and_wire :: proc(t: ^testing.T) {
	testing.expect_value(t, perm_names(PERM_NOTIFICATIONS, ","), "notifications")
	testing.expect_value(t, perm_names(PERM_CAMERA | PERM_MIC, ","), "camera,microphone")
	testing.expect_value(t, perm_phrase(PERM_NOTIFICATIONS), "show notifications")
	testing.expect_value(t, perm_phrase(PERM_CAMERA | PERM_MIC), "use your camera and microphone")
	testing.expect_value(t, perm_phrase(PERM_GEOLOCATION | PERM_CAMERA), "know your location and use your camera")
	testing.expect_value(t, cef_cursor(2), sapp.Mouse_Cursor.POINTING_HAND)
	testing.expect_value(t, cef_cursor(3), sapp.Mouse_Cursor.IBEAM)
	testing.expect_value(t, cef_cursor(0), sapp.Mouse_Cursor.DEFAULT)
	testing.expect_value(t, cef_cursor(999), sapp.Mouse_Cursor.DEFAULT)
	// parsed by name, written back the same
	wire := []string {
		`{"type":"browser_zoom","tab_id":5,"step":"in"}`,
		`{"type":"browser_edit","tab_id":5,"op":"select_all"}`,
		`{"type":"browser_download","download_id":3,"op":"reveal"}`,
		`{"type":"browser_popup","tab_id":5,"open":true}`,
	}
	for w in wire {
		cmd, err := parse_command(w, context.temp_allocator)
		testing.expectf(t, err == "", "%s: %s", w, err)
		sb := strings.builder_make(context.temp_allocator)
		write_command(&sb, cmd)
		testing.expect_value(t, strings.to_string(sb), w)
	}
	_, err := parse_command(`{"type":"browser_zoom","tab_id":5,"step":"sideways"}`, context.temp_allocator)
	testing.expect(t, err != "", "an unknown step is refused")
	_, err = parse_command(`{"type":"browser_edit","tab_id":5,"op":"format"}`, context.temp_allocator)
	testing.expect(t, err != "", "an unknown op is refused")
}

// ---- review round 1 ----

@(private = "file")
bp_at :: proc(ms: i64) -> time.Tick {return time.Tick{_nsec = 1_000_000_000_000 + ms * 1_000_000}}

// Downloads go without asking only just after the user's own click or key in the tab.
@(test)
browser_download_needs_the_users_click :: proc(t: ^testing.T) {
	p: Page_Extra
	testing.expect_value(t, download_take(&p, bp_at(0), 0), Download_Decision.Ask) // no click ever
	p.input_at = bp_at(1000)
	testing.expect_value(t, download_take(&p, bp_at(5900), 0), Download_Decision.Go)
	p.input_at = bp_at(1000)
	testing.expect_value(t, download_take(&p, bp_at(6100), 0), Download_Decision.Ask) // 5.1 s later
	p.ask_id = 3 // one waits for its bar: the next is refused, even right after a click
	p.input_at = bp_at(6000)
	testing.expect_value(t, download_take(&p, bp_at(6100), 0), Download_Decision.Refuse)
}

// A popup flood: counted, reported at most once a second per tab.
@(test)
browser_popup_flood_rate_limited :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	p: Page_Extra
	defer delete(p.popup_url)
	testing.expect(t, popup_blocked_note(&p, "https://a.example/1", bp_at(0)), "the first: reported")
	reported := 0
	for i in 1 ..< 20 do if popup_blocked_note(&p, fmt.tprintf("https://a.example/%d", i), bp_at(i64(i) * 50)) do reported += 1
	testing.expect_value(t, reported, 0) // 20 in under a second: one report
	testing.expect_value(t, p.popups_blocked, 20)
	testing.expect(t, p.popup_dirty, "the last one is still to report")
	testing.expect_value(t, p.popup_url, "https://a.example/19")
	testing.expect(t, popup_blocked_note(&p, "https://a.example/20", bp_at(1100)), "a second later: reported")
	testing.expect(t, !p.popup_dirty)
	testing.expect_value(t, p.popups_blocked, 21)
}

// page_downloads keeps the last DOWNLOADS_PER_TAB of each tab (never a running one).
@(test)
browser_downloads_capped_per_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	defer for &d in page_downloads {delete(d.name); delete(d.path); delete(d.url)}
	defer clear(&page_downloads)
	clear(&page_downloads)
	running := download_record(9, 1, "/tmp/x/running.bin", "")
	_ = running
	for i in 2 ..= 30 {
		d := download_record(7, u32(i), fmt.tprintf("/tmp/x/f%d.txt", i), "")
		d.state = .Done
	}
	other := download_record(9, 99, "/tmp/x/other.txt", "")
	other.state = .Done
	n7 := 0
	for d in page_downloads do if d.tab_id == 7 do n7 += 1
	testing.expect_value(t, n7, DOWNLOADS_PER_TAB)
	testing.expect(t, download_find(30) != nil && download_find(11) != nil && download_find(10) == nil, "the newest kept")
	testing.expect(t, download_find(1) != nil && download_find(99) != nil, "another tab's untouched")
}

// The permission bar keeps the end of the origin (the host's real name) and its phrase.
@(test)
browser_bar_text_clipped_from_the_left :: proc(t: ^testing.T) {
	m :: proc(s: string) -> f32 {return f32(strings.rune_count(s))}
	testing.expect_value(t, clip_left_by("https://example.com", 40, m), "https://example.com")
	testing.expect_value(t, clip_left_by("https://login.bank.example.com.evil.net", 12, m), "….evil.net")
	testing.expect_value(t, len(clip_left_by("https://a.b", 0, m)), 0)
}

// A dialog bar names the asking origin, and says so when a frame of another origin asks.
@(test)
browser_dialog_bar_names_origin :: proc(t: ^testing.T) {
	testing.expect_value(t, url_origin("https://User@Example.com:8443/a?b#c"), "https://example.com:8443")
	testing.expect_value(t, url_origin("pidesk-test://web/polish.html"), "pidesk-test://web")
	testing.expect_value(t, url_origin("file:///tmp/a.html"), "file://")
	testing.expect_value(t, url_origin("about:blank"), "about:blank")
	testing.expect_value(t, dialog_bar_text(.Alert, "Hi\nthere", "pidesk-test://web/", "pidesk-test://web/polish.html"), "pidesk-test://web says: Hi there")
	testing.expect_value(t, dialog_bar_text(.Confirm, "Sure?", "https://ads.example/", "https://news.example/x"), "https://ads.example (embedded frame) says: Sure?")
	testing.expect_value(t, dialog_bar_text(.Leave, "", "", "https://news.example/x"), "Leave this page? Changes you made may not be saved.")
}

// Open: only a quarantined file, never a file that runs or opens an address when opened.
@(test)
browser_download_open_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	d := Page_Download{state = .Done, quarantined = true, path = "/tmp/x/report.pdf"}
	testing.expect_value(t, download_open_check(&d), "")
	d.quarantined = false
	testing.expect(t, strings.contains(download_open_check(&d), "not marked"), download_open_check(&d))
	d.quarantined = true
	for ext in ([]string{"run.command", "a.fileloc", "b.inetloc", "c.webloc", "D.WEBLOC"}) {
		d.path = ext
		testing.expectf(t, strings.contains(download_open_check(&d), "Show in Finder"), "%s: %s", ext, download_open_check(&d))
	}
	// through the command: refused, nothing opened
	bp_reset()
	clear(&page_downloads)
	defer clear(&page_downloads)
	opened := 0
	platform.open_url = proc(url: string) -> bool {return true}
	append(&page_downloads, Page_Download{id = 5, tab_id = 1, state = .Done, path = "/tmp/x/a.webloc", quarantined = true})
	r := run_command(Browser_Download{download_id = 5, op = .Open}, {kind = .UI})
	testing.expect(t, !r.ok, "a .webloc is not opened")
	_ = opened
	// CEF's own path wins when it differs
	d2 := Page_Download{name = strings.clone("a.txt"), path = strings.clone("/tmp/x/a.txt")}
	download_note_path(&d2, "/tmp/x/a (1).txt")
	testing.expect_value(t, d2.path, "/tmp/x/a (1).txt")
	testing.expect_value(t, d2.name, "a (1).txt")
	download_note_path(&d2, "")
	testing.expect_value(t, d2.path, "/tmp/x/a (1).txt")
}

// Invisible and direction characters never reach a download's name.
@(test)
browser_download_name_invisible :: proc(t: ^testing.T) {
	for c in ([][2]string{{"a​b.txt", "ab.txt"}, {"x⁦y⁩.pdf", "xy.pdf"}, {"؜doc­.txt", "doc.txt"}, {"tag\U000E0041.txt", "tag.txt"}, {"p q.txt", "pq.txt"}}) {
		got := download_safe_name(c[0])
		testing.expectf(t, got == c[1], "%q -> %q, want %q", c[0], got, c[1])
	}
}

// file: addresses open from a file: page only (the popup bar, Open link in new tab).
@(test)
browser_file_links_only_from_file_pages :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	r := run_command(Browser_Open{session = a, url = "https://a.example"}, {kind = .UI})
	tw := r.created_id
	r = run_command(Browser_Open{session = a, url = "file:///tmp/a.html"}, {kind = .UI})
	tf := r.created_id
	has_open :: proc(tab: u64, link: string) -> bool {
		items := make([dynamic]Menu_Item, context.temp_allocator)
		browser_menu_items(Menu_Browser{tab_id = tab, link = link, flags = CM_LINK}, &items)
		for it in items do if it.label == "Open link in new tab" do return true
		return false
	}
	testing.expect(t, !has_open(tw, "file:///etc/passwd"), "a web page's file: link")
	testing.expect(t, has_open(tf, "file:///tmp/b.html"), "a file: page's file: link")
	testing.expect(t, has_open(tw, "https://b.example"), "a web link")
	run_command(Browser_Update{tab_id = tw, what = {.Blocked}, blocked = "file:///etc/passwd"}, {kind = .Internal})
	r = run_command(Browser_Popup{tab_id = tw, open = true}, {kind = .UI})
	testing.expect(t, !r.ok && strings.contains(r.error, "file:"), r.error)
	run_command(Browser_Update{tab_id = tf, what = {.Blocked}, blocked = "file:///tmp/b.html"}, {kind = .Internal})
	r = run_command(Browser_Popup{tab_id = tf, open = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
}

// ---- review round 2 ----

// One timestamp per tab: any change in its set of bars (from state, not layout) or the tab coming
// on screen again holds clicks for 500 ms, with or without a frame drawn in between.
@(test)
browser_bars_guard_per_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	r1 := run_command(Browser_Open{session = a, url = "https://a.example"}, {kind = .UI})
	r2 := run_command(Browser_Open{session = a, url = "https://b.example"}, {kind = .UI})
	ta, tb := r1.created_id, r2.created_id
	p := page_extra(ta)
	p.perm = PERM_NOTIFICATIONS // the upper bar
	run_command(Browser_Update{tab_id = ta, what = {.Blocked}, blocked = "https://pop.example/"}, {kind = .Internal}) // the lower
	testing.expect(t, !bars_click_ok(ta, bp_at(0)), "the tab just came on screen")
	testing.expect(t, bars_click_ok(ta, bp_at(600)), "600 ms later")
	// the upper bar goes (a double click's first click, the page itself): no frame in between
	p.perm = 0
	testing.expect(t, !bars_click_ok(ta, bp_at(601)), "the bars changed: held")
	testing.expect(t, !bars_click_ok(ta, bp_at(1000)), "still held")
	testing.expect(t, bars_click_ok(ta, bp_at(1102)), "500 ms after the change")
	// another tab on screen, then this one again: held
	testing.expect(t, !bars_click_ok(tb, bp_at(2000)), "the other tab came on screen")
	testing.expect(t, !bars_click_ok(ta, bp_at(3000)), "back to this tab: held")
	testing.expect(t, bars_click_ok(ta, bp_at(3500)), "500 ms later")
	// a new request in the same bar (another download id) is a change
	p.ask_id = 4
	testing.expect(t, !bars_click_ok(ta, bp_at(4000)), "a download ask appeared")
	testing.expect(t, bars_click_ok(ta, bp_at(4500)), "")
	p.ask_id = 5
	testing.expect(t, !bars_click_ok(ta, bp_at(4501)), "another request in the same bar")
	delete(p.bars_sig)
	p.bars_sig = ""
}

// One click or key allows one download; at most 20 running ones per tab.
@(test)
browser_download_one_per_gesture :: proc(t: ^testing.T) {
	p: Page_Extra
	p.input_at = bp_at(0)
	testing.expect_value(t, download_take(&p, bp_at(100), 0), Download_Decision.Go)
	testing.expect_value(t, download_take(&p, bp_at(200), 1), Download_Decision.Ask) // the click is used up
	p.ask_id = 0
	p.input_at = bp_at(1000)
	testing.expect_value(t, download_take(&p, bp_at(1100), DOWNLOADS_PER_TAB), Download_Decision.Ask) // 20 running: ask
	testing.expect(t, p.input_at != {}, "an ask leaves the click for the next")
}

// The download-ask bar: the name middle-clipped, its extension kept; the origin keeps its room.
@(test)
browser_ask_bar_text_long_name :: proc(t: ^testing.T) {
	m :: proc(s: string) -> f32 {return f32(strings.rune_count(s))}
	name := strings.concatenate({strings.repeat("x", 200, context.temp_allocator), ".pdf"}, context.temp_allocator)
	got := ask_bar_text("https://example.com", name, 80, 19, m)
	testing.expect(t, m(got) <= 80, got)
	testing.expect(t, strings.has_prefix(got, "https://example.com wants to download "), got)
	testing.expect(t, strings.has_suffix(got, ".pdf") && strings.contains(got, "…"), got)
	// a long origin: clipped from the left down to its minimum, the name still shown
	got = ask_bar_text("https://a.very.long.subdomain.chain.example.com", name, 80, 19, m)
	testing.expect(t, m(got) <= 80 && strings.contains(got, "example.com wants to download ") && strings.has_suffix(got, ".pdf"), got)
	testing.expect_value(t, ask_bar_text("https://e.com", "a.txt", 80, 19, m), "https://e.com wants to download a.txt")
}

// Open: more file kinds that run or install something.
@(test)
browser_download_open_refused_more :: proc(t: ^testing.T) {
	for ext in ([]string{"a.terminal", "b.tool", "c.workflow", "d.action", "e.mobileconfig"}) {
		d := Page_Download{state = .Done, quarantined = true, path = ext}
		testing.expectf(t, strings.contains(download_open_check(&d), "Show in Finder"), "%s: %q", ext, download_open_check(&d))
	}
}

// An allowed ask keeps its address on the record.
@(test)
browser_download_ask_keeps_url :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	clear(&page_downloads)
	defer clear(&page_downloads)
	r := run_command(Browser_Open{session = a, url = "https://a.example"}, {kind = .UI})
	ta := r.created_id
	b := browser_of(ta)
	b.cef = 1 // as if loaded (no CEF here: the shim's answer is a stub)
	defer b.cef = 0
	p := page_extra(ta)
	p.cef = 1
	p.ask_id = 7
	p.ask_name = strings.clone("x.txt")
	p.ask_url = strings.clone("https://a.example/x.txt")
	home_root = fmt.aprintf("build/test-data/bp-ask-%d", new_id())
	defer {os.remove_all(home_root); home_root = ""}
	r = run_command(Browser_Download{download_id = 7, op = .Allow}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	d := download_find(7)
	testing.expect(t, d != nil && d.url == "https://a.example/x.txt", d != nil ? d.url : "no record")
}

// An agent's browser_* commands never count as the user's gesture for a download: only input
// pi-desk forwards from the user's own events does (browser_page_input).
@(test)
browser_agent_commands_are_not_a_gesture :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := bp_reset()
	defer for id, _ in browsers do browser_drop(id)
	r := run_command(Browser_Open{session = a, url = "https://a.example"}, {kind = .UI})
	ta := r.created_id
	pi := Caller{kind = .Panel, tab_id = find_session(a).tabs[0].id}
	cmds := []Command {
		Browser_Navigate{tab_id = ta, url = "https://a.example/next"},
		Browser_Reload{ta},
		Browser_Tabs{},
		Browser_Read{tab_id = ta},
		Browser_Page_Wait{tab_id = ta, what = "load"},
		Browser_Console{tab_id = ta},
		Browser_Network{tab_id = ta},
		Browser_Screenshot{tab_id = ta},
	}
	for cmd in cmds do run_command(cmd, pi)
	testing.expect(t, page_extra(ta).input_at == {}, "an agent's command counted as the user's gesture")
	p := page_extra(ta)
	testing.expect_value(t, download_take(p, bp_at(0), 0), Download_Decision.Ask)
}
