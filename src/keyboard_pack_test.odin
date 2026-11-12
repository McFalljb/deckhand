package main

// The keyboard pack: Reopen closed tab (⇧⌘T; closed_tabs.odin, the window's), Recent session
// (⌥⌘` ⌥⇧⌘`), Mark as unread (⇧⌘U), Mark all sessions as read (⌥⇧⌘U; core/mark_read.odin) and Go to open
// session 1–6 (⌥⌘1–⌥⌘6): only the user's three close gestures record (kinds, order, cap, nothing
// secret, no app tabs), reopening, the recent toggle, the unread marks (waiting, errors untouched,
// also when one arrives just before), the Open section's rows, and the menus and keys.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
KP_UI :: core.Caller{kind = .UI}

@(private = "file")
kp_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	ids := make([dynamic]u64, context.temp_allocator)
	for id, _ in editors do append(&ids, id)
	for id in ids do editor_drop(id)
	for _, t in core.terms {
		core.reader_stop_and_close(t)
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	closed_tabs_clear()
	if menu.open do menu_close()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	toast_clear()
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
}

@(private = "file")
kp_dir :: proc() -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	dir := fmt.aprintf("%s/deckhand-keys-%d", strings.trim_right(tmp, "/"), time.now()._nsec, allocator = runtime.heap_allocator())
	os.make_directory_all(dir)
	return dir
}

// A session of this Mac's: its pi tab (exited: closes ask nothing) and these tabs, in one pane.
@(private = "file")
kp_session :: proc(id: u64, cwd: string, tabs: ..core.Tab) -> ^core.Open_Session {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("s%d", id)), cwd = strings.clone(cwd), title = strings.clone(fmt.tprintf("session %d", id))}
	append(&s.tabs, core.Tab{id = id + 1, kind = core.Pi_Tab{}, title = strings.clone("pi"), status = .Exited})
	for t in tabs do append(&s.tabs, t)
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	return core.find_session(id)
}

// Heap copies (a tab's kind frees them when it closes).
@(private = "file")
kp_strings :: proc(xs: ..string) -> []string {
	out := make([]string, len(xs), runtime.heap_allocator())
	for x, i in xs do out[i] = strings.clone(x, runtime.heap_allocator())
	return out
}

@(private = "file")
kp_tab :: proc(id: u64, kind: core.Tab_Kind, title := "tab", cwd := "") -> core.Tab {
	context.allocator = runtime.heap_allocator()
	return core.Tab{id = id, kind = kind, title = strings.clone(title), cwd = strings.clone(cwd), status = .Exited}
}

// ⌥⌘`: the session shown before this one; again: back. ⌥⇧⌘`: the one shown longest ago.
@(test)
recent_session_toggle :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	kp_session(100, "/tmp")
	state.current_session = 100
	testing.expect(t, !action_ok("recent_session"), "one session: nowhere to go")
	kp_session(200, "/tmp")
	kp_session(300, "/tmp")
	home := kp_session(900, "/tmp")
	home.home = true
	home.shown_at = 1 << 62 // Home never counts
	for id in ([]u64{100, 200, 300}) do core.run_command(core.Focus_Session{session = id}, KP_UI)
	for want in ([]u64{200, 300, 200, 300}) {
		action_run("recent_session")
		core.inbox_drain()
		testing.expect_value(t, state.current_session, want)
	}
	// the least recent: 100, then (100 now most recent) 200, then 300: round them all
	for want in ([]u64{100, 200, 300}) {
		action_run("least_recent_session")
		core.inbox_drain()
		testing.expect_value(t, state.current_session, want)
	}
	// an offline machine's session is left out
	state.machines = make([]core.Machine_View, 1)
	state.machines[0].no, state.machines[0].status = 7, .Offline
	off := kp_session(700, "/tmp")
	off.machine = 7
	off.shown_at = 1 << 61
	cmd, ok := session_recent(false)
	testing.expect(t, ok)
	if fs, is := cmd.(core.Focus_Session); is do testing.expect(t, fs.session != 700)
	// the key: ⌥⌘` (AppKit's equivalent "`")
	k, kok := parse_keys("⌥⌘`")
	testing.expect(t, kok && k.code == .GRAVE_ACCENT && k.equiv == "`" && k.ns_mods == NS_COMMAND | NS_OPTION)
	was := state.current_session
	e := sapp.Event{type = .KEY_DOWN, key_code = .GRAVE_ACCENT, modifiers = u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)}
	event(&e)
	core.inbox_drain()
	testing.expect(t, state.current_session != was, "⌥⌘` switched")
}

// ⇧⌘U marks the tab you are in; ⌥⇧⌘U clears finished-not-seen on this Mac, never a waiting tab's.
@(test)
mark_unread_and_all_read :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	waiting := kp_tab(12, core.Shell_Tab{})
	waiting.status = .Running
	waiting.prog.state, waiting.prog.kind = .Blocked, .Permission
	waiting.unseen = true
	kp_session(100, "/tmp", kp_tab(11, core.Shell_Tab{}), waiting)
	other := kp_tab(21, core.Shell_Tab{})
	other.unseen = true
	kp_session(200, "/tmp", other)
	remote := kp_tab(31, core.Shell_Tab{})
	remote.unseen = true
	rs := kp_session(300, "/tmp", remote)
	rs.machine = 7
	state.current_session = 100
	core.session_show_tab(core.find_session(100), 11)

	// ⇧⌘U: the focused terminal tab
	action_run("mark_unread")
	core.inbox_drain()
	_, t11, _ := core.find_tab(11)
	testing.expect(t, t11 != nil && t11.unseen)
	testing.expect_value(t, menubar_key_action(.U, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT)), "mark_unread")

	// ⌥⇧⌘U: this Mac's two sessions; the waiting tab exactly as it was; another machine's untouched
	action_run("mark_all_read")
	core.inbox_drain()
	testing.expect_value(t, toast.text, "Marked 2 as read")
	for id in ([]u64{11, 21}) {
		_, x, _ := core.find_tab(id)
		testing.expectf(t, x != nil && !x.unseen, "tab %d still unseen", id)
	}
	_, w, _ := core.find_tab(12)
	testing.expect(t, w != nil && w.unseen && core.tab_status_view(w^).dot == .Waiting, "waiting for you stays as it was")
	_, r, _ := core.find_tab(31)
	testing.expect(t, r != nil && r.unseen, "another machine's: its own")
	action_run("mark_all_read")
	core.inbox_drain()
	testing.expect_value(t, toast.text, "Nothing unread")
	testing.expect_value(t, menubar_key_action(.U, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT)), "mark_all_read")
}

// ⌥⌘1–⌥⌘6: the Open section's rows as ordered now; ⌘1–⌘9 stay the tabs'.
@(test)
open_session_nth :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	for id in ([]u64{100, 200, 300}) do kp_session(id, "/tmp", kp_tab(id + 5, core.Shell_Tab{}))
	for id in ([]u64{100, 200, 300}) do core.run_command(core.Focus_Session{session = id}, KP_UI)
	rows := core.sidebar_open()
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, rows[0].id, u64(300)) // the current first, then the most recently shown
	action_run("session_3")
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect(t, !action_ok("session_4"), "only three rows")
	testing.expect_value(t, session_nth_title(1), core.open_session_title(core.sidebar_open()[1]))
	// the keys: ⌥⌘2 a session, ⌘2 a tab of this one
	testing.expect_value(t, menubar_key_action(._2, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)), "session_2")
	want := core.sidebar_open()[1].id
	e := sapp.Event{type = .KEY_DOWN, key_code = ._2, modifiers = u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)}
	event(&e)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, want)
	cur := state.current_session
	e = sapp.Event{type = .KEY_DOWN, key_code = ._2, modifiers = u32(sapp.MODIFIER_SUPER)}
	event(&e)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, cur)
	testing.expect_value(t, core.session_focused_id(core.find_session(cur)), cur + 5)
	// a text field passes ⌥⌘digits on
	state.focus_widget = "sidebar_filter"
	defer state.focus_widget = ""
	e = sapp.Event{type = .KEY_DOWN, key_code = ._1, modifiers = u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)}
	testing.expect(t, !widget_event(&e))
	// Window menu, with the other session keys
	window: []Bar_Item
	for top in MENUBAR do if top.title == "Window" do window = top.sub
	ids := make([dynamic]string, context.temp_allocator)
	for it in window do if it.action != "" do append(&ids, it.action)
	joined := strings.join(ids[:], ",", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "prev_session,next_needing_you,prev_needing_you,peek_next_needing_you,recent_session,least_recent_session,session_1,session_2,session_3,session_4,session_5,session_6,mark_unread,mark_all_read"), joined)
}

// Review round 1. An app's declaration rewritten after its tab closed: ⇧⌘T does not run the
// replacement (the closed tab's command and folder are what may reopen, nothing else).
// Mark all sessions as read clears finished-not-seen only: an error not seen yet stays (and its record).
@(test)
mark_all_read_keeps_errors :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	errd := kp_tab(21, core.Shell_Tab{})
	errd.status = .Running
	errd.prog.state = .Error
	errd.unseen = true
	kp_session(200, "/tmp", errd)
	kp_session(100, "/tmp")
	state.current_session = 100
	action_run("mark_all_read")
	core.inbox_drain()
	_, e, _ := core.find_tab(21)
	testing.expect(t, e != nil && e.unseen, "the error is still not seen")
	testing.expect(t, e != nil && core.tab_status_view(e^).dot == .Error)
	testing.expect_value(t, toast.text, "Nothing unread")
}

// ⌃⇥ is the programs' (a Kitty-protocol vim, an app, a page): Recent session is ⌥⌘` instead.
@(test)
recent_session_keys_are_cmd_chords :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	S, A, SH, C := u32(sapp.MODIFIER_SUPER), u32(sapp.MODIFIER_ALT), u32(sapp.MODIFIER_SHIFT), u32(sapp.MODIFIER_CTRL)
	testing.expect_value(t, menubar_key_action(.GRAVE_ACCENT, S | A), "recent_session")
	testing.expect_value(t, menubar_key_action(.GRAVE_ACCENT, S | A | SH), "least_recent_session")
	testing.expect_value(t, menubar_key_action(.TAB, C), "")
	testing.expect_value(t, menubar_key_action(.GRAVE_ACCENT, S), "") // the system's window cycle
	kp_session(100, "/tmp")
	kp_session(200, "/tmp")
	for id in ([]u64{100, 200}) do core.run_command(core.Focus_Session{session = id}, KP_UI)
	e := sapp.Event{type = .KEY_DOWN, key_code = .TAB, modifiers = C}
	event(&e)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(200)) // ⌃⇥ is not Deckhand's
	e = sapp.Event{type = .KEY_DOWN, key_code = .GRAVE_ACCENT, modifiers = S | A}
	event(&e)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(100))
	// a text field passes it on
	state.focus_widget = "sidebar_filter"
	defer state.focus_widget = ""
	testing.expect(t, !widget_event(&e))
}

// A close an agent asked for and the user confirmed is the agent's: not kept for ⇧⌘T. The user's
// own close, confirmed, is.
// Only the user's own gestures record: a tab's ×, ⌘W, its menu's Close tab, and the menu bar's and the
// palette's Close tab. Not an agent's close (also confirmed by the user), a control caller's, a script's. The kinds kept,
// their order and cap; nothing secret; app tabs never.
@(test)
closed_tabs_only_the_users_gestures :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	dir := kp_dir()
	defer os.remove_all(dir)
	os.make_directory_all(fmt.tprintf("%s/.deckhand", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/.deckhand/apps.json", dir), transmute([]u8)string(`{"apps":[{"name":"game","argv":["godot"]}]}`))
	kp_session(100, dir,
		kp_tab(10, core.Shell_Tab{}, cwd = fmt.tprintf("%s/sub", dir)),
		kp_tab(11, core.Editor_Tab{path = strings.clone("/x/a.odin")}),
		kp_tab(12, core.Markdown_Tab{path = strings.clone("/x/README.md")}),
		kp_tab(13, core.Browser_Tab{url = strings.clone("https://example.com/p?q=1")}),
		kp_tab(14, core.Browser_Tab{url = strings.clone("")}),
		kp_tab(15, core.App_Tab{argv = kp_strings("godot"), cwd = strings.clone(dir)}, title = "game"),
		kp_tab(16, core.Claude_Tab{session_id = strings.clone("0b6a3c1e-0000-4000-8000-000000000001"), args = kp_strings("--model", "opus")}, cwd = dir),
		kp_tab(17, core.Claude_Tab{}),
		kp_tab(18, core.Changes_Tab{root = strings.clone(dir)}),
		kp_tab(19, core.Shell_Tab{}),
		kp_tab(20, core.Shell_Tab{}),
		kp_tab(21, core.Shell_Tab{}),
		kp_tab(22, core.Shell_Tab{}),
		kp_tab(23, core.Shell_Tab{}),
		kp_tab(24, core.Shell_Tab{}),
	)
	state.current_session = 100
	// the × and ⌘W (close_tab_click), each kind
	for id in 10 ..= u64(18) {
		close_tab_click(id)
		core.inbox_drain()
	}
	Want :: struct {
		kind: Closed_Kind,
		what: string,
	}
	want := []Want {
		{.Shell, fmt.tprintf("%s/sub", dir)},
		{.Editor, "/x/a.odin"},
		{.Markdown, "/x/README.md"},
		{.Browser, "https://example.com/p?q=1"},
		{.Claude, "0b6a3c1e-0000-4000-8000-000000000001"}, // its id: no flags kept
		{.Changes, dir},
	}
	testing.expect_value(t, len(closed_tabs), len(want)) // no blank page, app tab or id-less Claude tab
	for w, i in want {
		if i >= len(closed_tabs) do break
		x := closed_tabs[i]
		testing.expectf(t, x.kind == w.kind && x.what == w.what && x.session == 100, "entry %d: %v %q, want %v %q", i, x.kind, x.what, w.kind, w.what)
		testing.expectf(t, !strings.contains(x.cwd, "opus"), "entry %d keeps a flag", i)
	}
	// ⌘W, as pressed
	ui_do(core.Focus_Tab{19})
	core.inbox_drain()
	e := sapp.Event{type = .KEY_DOWN, key_code = .W, modifiers = u32(sapp.MODIFIER_SUPER)}
	event(&e)
	core.inbox_drain()
	testing.expect(t, len(closed_tabs) == len(want) + 1 && closed_tabs[len(closed_tabs) - 1].tab_id == 19, "⌘W recorded")
	// the tab menu's Close tab
	menu_open(Menu_Tab(20), {10, 10})
	at := -1
	for it, i in menu_items() do if it.label == "Close tab" do at = i
	testing.expect(t, at >= 0)
	menu_run(at)
	core.inbox_drain()
	testing.expect(t, closed_tabs[len(closed_tabs) - 1].tab_id == 20, "the tab menu recorded")
	n := len(closed_tabs)
	// the menu bar's File › Close Tab (and the palette's: the same action)
	ui_do(core.Focus_Tab{21})
	core.inbox_drain()
	file: []Bar_Item
	for top in MENUBAR do if top.title == "File" do file = top.sub
	bar := -1
	for it, i in file do if it.action == "close_tab" do bar = i
	testing.expect(t, bar >= 0, "File › Close Tab")
	if bar >= 0 do menubar_run(&file[bar])
	core.inbox_drain()
	_, gone, _ := core.find_tab(21)
	testing.expect(t, gone == nil, "the menu bar's close did close it")
	testing.expect(t, len(closed_tabs) == n + 1 && closed_tabs[len(closed_tabs) - 1].tab_id == 21, "the menu bar's Close tab recorded")
	ui_do(core.Focus_Tab{24})
	core.inbox_drain()
	action_run("close_tab") // the palette's (run_action, as palette_run)
	core.inbox_drain()
	testing.expect(t, len(closed_tabs) == n + 2 && closed_tabs[len(closed_tabs) - 1].tab_id == 24, "the palette's Close tab recorded")
	closed_tabs_settle()
	toast_clear()
	action_run("reopen_closed_tab") // ⇧⌘T brings it back: a new shell in its folder
	core.inbox_drain()
	testing.expect_value(t, toast.text, fmt.tprintf("Reopened a new terminal in %s", core.path_tilde(dir)))
	testing.expect_value(t, len(closed_tabs), n + 1)
	n = len(closed_tabs)
	// not: an agent's (control) or a script's
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 22}, {kind = .Control}).ok)
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 23}, {kind = .Script}).ok)
	testing.expect_value(t, len(closed_tabs), n)

	// at most CLOSED_TABS_MAX: the oldest goes
	s := core.find_session(100)
	for i in 0 ..< u64(CLOSED_TABS_MAX) {
		core.pane_add_tab(s, kp_tab(40 + i, core.Editor_Tab{path = strings.clone(fmt.tprintf("/y/%d", i))}))
		close_tab_click(40 + i)
		core.inbox_drain()
	}
	testing.expect_value(t, len(closed_tabs), CLOSED_TABS_MAX)
	testing.expect_value(t, closed_tabs[0].what, "/y/0")
}

// An agent's close the user confirmed in the bar records nothing; the user's own ×, confirmed,
// records; cancelled, its entry is skipped at ⇧⌘T (the tab is still there).
@(test)
closed_tabs_confirmations :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	state.settings.confirm_close[.Shell] = .Always
	running :: proc(id: u64) -> core.Tab {
		x := kp_tab(id, core.Shell_Tab{}, cwd = "/tmp")
		x.status = .Running
		return x
	}
	kp_session(100, "/tmp", running(10), running(11), running(12))
	state.current_session = 100
	r := core.run_command(core.Close_Tab{tab_id = 10}, {kind = .Control})
	testing.expect_value(t, r.error, "needs_confirmation")
	if len(state.pending_confirmations) == 1 {
		tok := strings.clone(state.pending_confirmations[0].token, context.temp_allocator)
		confirm_pending(tok) // the bar's Confirm
		core.inbox_drain()
	}
	_, gone, _ := core.find_tab(10)
	testing.expect(t, gone == nil, "confirmed and closed")
	testing.expect_value(t, len(closed_tabs), 0)
	// the user's ×: it asks; not answered yet: nothing to reopen (its entry waits)
	close_tab_click(11)
	core.inbox_drain()
	testing.expect_value(t, len(closed_tabs), 1)
	_, still, _ := core.find_tab(11)
	testing.expect(t, still != nil, "waiting for the answer")
	n := len(core.find_session(100).tabs)
	action_run("reopen_closed_tab")
	core.inbox_drain()
	testing.expect_value(t, len(core.find_session(100).tabs), n)
	testing.expect_value(t, toast.text, "No closed tab to reopen")
	testing.expect(t, len(closed_tabs) == 1 && closed_tabs[0].pending, "still waiting for the answer")
}

// ⇧⌘T: newest first, in its session (brought to the front): a new shell in its folder (said so),
// then the editor's file; a tab whose session closed since is skipped; nothing left: a toast.
@(test)
closed_tabs_reopen_sends_the_opens :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	dir := kp_dir()
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/a.txt", dir)
	_ = os.write_entire_file(path, transmute([]u8)string("hello\n"))
	kp_session(100, dir)
	kp_session(200, dir, kp_tab(210, core.Shell_Tab{}, cwd = dir))
	state.current_session = 100
	action_run("reopen_closed_tab")
	testing.expect_value(t, toast.text, "No closed tab to reopen")
	toast_clear()
	r := core.run_command(core.Open_File{path = path, session = 100}, KP_UI)
	testing.expect(t, r.ok, r.error)
	close_tab_click(r.created_id)
	core.inbox_drain()
	close_tab_click(210)
	core.inbox_drain()
	testing.expect_value(t, len(closed_tabs), 2)
	state.current_session = 100
	action_run("reopen_closed_tab")
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(200))
	s2 := core.find_session(200)
	focused := core.session_focused_tab(s2)
	if focused != nil {
		_, is_shell := focused.kind.(core.Shell_Tab)
		testing.expect(t, is_shell && focused.id != 210, "a new shell")
	} else do testing.fail_now(t, "no tab")
	testing.expect_value(t, toast.text, fmt.tprintf("Reopened a new terminal in %s", core.path_tilde(dir)))
	action_run("reopen_closed_tab")
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(100))
	ed := core.session_focused_tab(core.find_session(100))
	if ed != nil {
		et, is_ed := ed.kind.(core.Editor_Tab)
		testing.expect(t, is_ed && et.path == path)
	} else do testing.fail_now(t, "no editor tab")
	// a tab whose session closed since: skipped
	core.pane_add_tab(s2, kp_tab(220, core.Editor_Tab{path = strings.clone(path)}))
	close_tab_click(220)
	core.inbox_drain()
	for &s, i in state.open_sessions do if s.id == 200 {
		ordered_remove(&state.open_sessions, i)
		break
	}
	toast_clear()
	action_run("reopen_closed_tab")
	testing.expect_value(t, toast.text, "No closed tab to reopen")
	// the menus and the key
	file: []Bar_Item
	for top in MENUBAR do if top.title == "File" do file = top.sub
	k := -1
	for it, i in file do if it.action == "close_session" do k = i
	testing.expect(t, k >= 0 && k + 1 < len(file) && file[k + 1].action == "reopen_closed_tab")
	testing.expect_value(t, menubar_key_action(.T, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT)), "reopen_closed_tab")
	testing.expect(t, action_ok("reopen_closed_tab"))
}

// mark_all_read decides in the core as it applies: an error that arrives after the window last saw
// the tab finished (unseen) and before the command applies keeps its unseen flag and its record.
// The user's at this Mac only; its count.
@(test)
mark_all_read_race_and_authority :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	x := kp_tab(21, core.Shell_Tab{})
	x.status = .Running
	x.unseen = true
	kp_session(200, "/tmp", x)
	kp_session(100, "/tmp")
	state.current_session = 100
	_, tab, _ := core.find_tab(21)
	testing.expect(t, core.tab_status_view(tab^).dot == .Unseen, "what the window sees")
	// the error arrives first, then the command
	core.run_command(core.Program_Status{tab_id = 21, summary = {state = .Error}}, {kind = .Internal})
	r := core.run_command(core.Mark_All_Read{}, KP_UI)
	testing.expect(t, r.ok)
	testing.expect_value(t, r.data, `{"count":0}`)
	_, tab, _ = core.find_tab(21)
	testing.expect(t, tab != nil && tab.unseen && core.tab_status_view(tab^).dot == .Error, "the error is kept, not seen")
	testing.expect_value(t, toast.text, "Nothing unread")
	// authority: the user's (#114: a hub's, on behalf of its user, marks this machine's own: that
	// is how another Mac's ⌥⇧⌘U reaches it; it goes no further, machine_route_test's
	// route_mark_all_read); never an agent's or a script's
	spec := core.command_spec("mark_all_read")
	testing.expect(t, spec != nil && spec.who == .User)
	testing.expect(t, core.caller_may({kind = .UI, hub = true}, core.Mark_All_Read{}))
	testing.expect(t, !core.caller_may({kind = .Control, hub = true}, core.Mark_All_Read{}))
	testing.expect(t, !core.caller_may({kind = .Control}, core.Mark_All_Read{}))
	testing.expect(t, !core.caller_may({kind = .Script}, core.Mark_All_Read{}))
	testing.expect_value(t, core.command_wire_json(core.Mark_All_Read{}), `{"type":"mark_all_read"}`)
	cmd, err := core.parse_command(`{"type":"mark_all_read"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	_, is := cmd.(core.Mark_All_Read)
	testing.expect(t, is)
}

// Review round 3. × → Cancel → an agent closes the tab later: ⇧⌘T does not reopen it. × × → the
// user's Confirm: exactly one entry.
@(test)
closed_tabs_cancel_and_repeat :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	state.settings.confirm_close[.Shell] = .Always
	state.settings.confirm[.Control][.Tab_Close] = .Auto
	running :: proc(id: u64) -> core.Tab {
		x := kp_tab(id, core.Shell_Tab{}, cwd = "/tmp")
		x.status = .Running
		return x
	}
	kp_session(100, "/tmp", running(10), running(11), running(12))
	state.current_session = 100
	close_tab_click(10)
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect_value(t, len(state.pending_confirmations), 1)
	if len(state.pending_confirmations) == 1 do cancel_pending(strings.clone(state.pending_confirmations[0].token, context.temp_allocator))
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 10}, {kind = .Control}).ok)
	closed_tabs_settle()
	action_run("reopen_closed_tab")
	core.inbox_drain()
	testing.expect_value(t, toast.text, "No closed tab to reopen")

	// × twice, one confirmation, the user's Confirm: one entry
	close_tab_click(11)
	core.inbox_drain()
	close_tab_click(11)
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect_value(t, len(state.pending_confirmations), 1)
	if len(state.pending_confirmations) == 1 do confirm_pending(strings.clone(state.pending_confirmations[0].token, context.temp_allocator))
	core.inbox_drain()
	closed_tabs_settle()
	_, gone, _ := core.find_tab(11)
	testing.expect(t, gone == nil, "closed")
	testing.expect_value(t, len(closed_tabs), 1)
	toast_clear()
	action_run("reopen_closed_tab")
	core.inbox_drain()
	testing.expect_value(t, toast.text, "Reopened a new terminal in /tmp")
	toast_clear()
	action_run("reopen_closed_tab")
	testing.expect_value(t, toast.text, "No closed tab to reopen")

	// the palette's (and the menu bar's) Close tab asks too: Cancel records nothing, Confirm one
	ui_do(core.Focus_Tab{12})
	core.inbox_drain()
	action_run("close_tab")
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect_value(t, len(state.pending_confirmations), 1)
	if len(state.pending_confirmations) == 1 do cancel_pending(strings.clone(state.pending_confirmations[0].token, context.temp_allocator))
	core.inbox_drain()
	closed_tabs_settle()
	_, kept, _ := core.find_tab(12)
	testing.expect(t, kept != nil, "cancelled: the tab stays")
	testing.expect_value(t, len(closed_tabs), 0)
	action_run("close_tab")
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect_value(t, len(state.pending_confirmations), 1)
	if len(state.pending_confirmations) == 1 do confirm_pending(strings.clone(state.pending_confirmations[0].token, context.temp_allocator))
	core.inbox_drain()
	closed_tabs_settle()
	_, gone12, _ := core.find_tab(12)
	testing.expect(t, gone12 == nil, "confirmed: closed")
	testing.expect(t, len(closed_tabs) == 1 && closed_tabs[0].tab_id == 12 && !closed_tabs[0].pending, "the user's confirmed close is reopenable")
}

// Another machine's page ("Open a machine's web page…") is at 127.0.0.1 through an ssh forward
// that ends with its tab: not kept.
@(test)
closed_tabs_not_machine_pages :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	kp_session(100, "/tmp", kp_tab(10, core.Browser_Tab{url = strings.clone("http://127.0.0.1:50123/app")}), kp_tab(11, core.Browser_Tab{url = strings.clone("http://localhost:3000/")}))
	state.current_session = 100
	close_tab_click(10)
	close_tab_click(11)
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect_value(t, len(closed_tabs), 1)
	if len(closed_tabs) == 1 do testing.expect_value(t, closed_tabs[0].what, "http://localhost:3000/")
}

// Review: the user's close stopped by the comments prompt and cancelled, then an agent's close of
// that tab: nothing to reopen. The prompt's Drop and close is the user's own: reopenable.
@(test)
closed_tabs_comments_prompt :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	defer state.comments_ask = {}
	kp_session(100, "/tmp", kp_tab(10, core.Browser_Tab{url = strings.clone("https://example.com/a")}), kp_tab(11, core.Browser_Tab{url = strings.clone("https://example.com/b")}))
	state.current_session = 100
	testing.expect(t, core.run_command(core.Comment_Add{source = .Browser, tab_id = 10, what = "w", text = "keep me"}, {kind = .Internal}).ok)
	close_tab_click(10)
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect_value(t, state.comments_ask, core.Comments_Ask{tab_id = 10, session = 100})
	comments_click(Hit_Comments{part = .Ask_Cancel})
	core.inbox_drain()
	closed_tabs_settle()
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 10, comments = .Drop}, {kind = .Control}).ok, "the agent's close")
	core.inbox_drain()
	closed_tabs_settle()
	toast_clear()
	action_run("reopen_closed_tab")
	core.inbox_drain()
	testing.expect_value(t, toast.text, "No closed tab to reopen")

	// the user's Drop and close: reopenable
	testing.expect(t, core.run_command(core.Comment_Add{source = .Browser, tab_id = 11, what = "w", text = "drop me"}, {kind = .Internal}).ok)
	close_tab_click(11)
	core.inbox_drain()
	closed_tabs_settle()
	comments_click(Hit_Comments{part = .Ask_Drop})
	core.inbox_drain()
	closed_tabs_settle()
	_, gone, _ := core.find_tab(11)
	testing.expect(t, gone == nil, "closed")
	testing.expect(t, len(closed_tabs) == 1 && closed_tabs[0].tab_id == 11 && !closed_tabs[0].pending, "the user's Drop and close is reopenable")
}
