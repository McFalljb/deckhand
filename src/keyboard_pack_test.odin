package main

// The keyboard pack: Reopen closed tab (⇧⌘T; core/closed_tabs.odin), Recent session (⌃⇥ ⌃⇧⇥),
// Mark as unread (⇧⌘U), Mark all as read (⌥⇧⌘U) and Go to open session 1–6 (⌥⌘1–⌥⌘6): the stack
// (order, cap, kinds, nothing secret kept, the user's closes only), reopening, the recent toggle,
// the unread marks (waiting untouched), the Open section's rows, and the menus and keys.

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
	core.closed_tabs_clear()
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

@(test)
closed_tabs_kinds_order_cap_and_secrets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	dir := kp_dir()
	defer os.remove_all(dir)
	// a declared app (apps.json) and its tab; a command line typed in the palette is not kept
	os.make_directory_all(fmt.tprintf("%s/.deckhand", dir))
	_ = os.write_entire_file(fmt.tprintf("%s/.deckhand/apps.json", dir), transmute([]u8)string(`{"apps":[{"name":"game","argv":["godot","--path","."]}]}`))
	game := kp_strings("godot", "--path", ".")
	adhoc := kp_strings("/bin/sh", "-c", "TOKEN=s3cret serve")
	kp_session(100, dir,
		kp_tab(10, core.Shell_Tab{}, cwd = fmt.tprintf("%s/sub", dir)),
		kp_tab(11, core.Editor_Tab{path = strings.clone("/x/a.odin")}),
		kp_tab(12, core.Markdown_Tab{path = strings.clone("/x/README.md")}),
		kp_tab(13, core.Browser_Tab{url = strings.clone("https://me:hunter2@example.com/p?q=1")}),
		kp_tab(14, core.Browser_Tab{url = strings.clone("")}),
		kp_tab(15, core.App_Tab{argv = game, cwd = strings.clone(dir)}, title = "game"),
		kp_tab(16, core.App_Tab{argv = adhoc, cwd = strings.clone(dir)}, title = "serve"),
		kp_tab(17, core.Claude_Tab{session_id = strings.clone("0b6a3c1e-0000-4000-8000-000000000001"), args = kp_strings("--model", "opus")}, cwd = dir),
		kp_tab(18, core.Claude_Tab{}), // before Claude reported its session: nothing to resume
		kp_tab(19, core.Changes_Tab{root = strings.clone(dir)}),
		kp_tab(20, core.Shell_Tab{}), // the session's folder
	)
	state.current_session = 100
	for id in 10 ..= u64(20) {
		r := core.run_command(core.Close_Tab{tab_id = id}, KP_UI)
		testing.expectf(t, r.ok, "close %d: %s", id, r.error)
	}
	Want :: struct {
		kind: core.Closed_Kind,
		what: string,
	}
	want := []Want {
		{.Shell, fmt.tprintf("%s/sub", dir)},
		{.Editor, "/x/a.odin"},
		{.Markdown, "/x/README.md"},
		{.Browser, "https://example.com/p?q=1"}, // no user:pass@
		{.App, "game"}, // by name, never its command line
		{.Claude, "0b6a3c1e-0000-4000-8000-000000000001"}, // its id only: no flags kept
		{.Changes, dir},
		{.Shell, dir},
	}
	testing.expect_value(t, len(core.closed_tabs), len(want))
	for w, i in want {
		if i >= len(core.closed_tabs) do break
		x := core.closed_tabs[i]
		testing.expectf(t, x.kind == w.kind && x.what == w.what && x.session == 100, "entry %d: %v %q, want %v %q", i, x.kind, x.what, w.kind, w.what)
		testing.expectf(t, !strings.contains(x.what, "hunter2") && !strings.contains(x.what, "s3cret") && !strings.contains(x.cwd, "opus"), "entry %d keeps a secret", i)
	}

	// only the user's closes on this Mac: a script's, an agent's or a hub's are not kept
	core.closed_tabs_clear()
	s := core.find_session(100)
	for id in 30 ..= u64(32) do core.pane_add_tab(s, kp_tab(id, core.Shell_Tab{}))
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 30}, {kind = .Script}).ok)
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 31}, {kind = .Control}).ok)
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 32}, {kind = .UI, hub = true}).ok)
	testing.expect_value(t, len(core.closed_tabs), 0)

	// at most CLOSED_TABS_MAX: the oldest goes
	for i in 0 ..< u64(core.CLOSED_TABS_MAX + 2) {
		id := 40 + i
		core.pane_add_tab(s, kp_tab(id, core.Editor_Tab{path = strings.clone(fmt.tprintf("/x/%d", i))}))
		testing.expect(t, core.run_command(core.Close_Tab{tab_id = id}, KP_UI).ok)
	}
	testing.expect_value(t, len(core.closed_tabs), core.CLOSED_TABS_MAX)
	testing.expect_value(t, core.closed_tabs[0].what, "/x/2")
	testing.expect_value(t, core.closed_tabs[core.CLOSED_TABS_MAX - 1].what, fmt.tprintf("/x/%d", core.CLOSED_TABS_MAX + 1))
}

@(test)
closed_tabs_reopen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	dir := kp_dir()
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/a.txt", dir)
	_ = os.write_entire_file(path, transmute([]u8)string("hello\n"))
	kp_session(100, dir)
	kp_session(200, dir)
	state.current_session = 100

	// nothing closed: a toast for the user, ok
	r := core.run_command(core.Reopen_Closed_Tab{}, KP_UI)
	testing.expect(t, r.ok && r.created_id == 0)
	testing.expect_value(t, toast.text, "No closed tab to reopen")
	toast_clear()

	// an editor tab: its file again, in its session, brought to the front
	r = core.run_command(core.Open_File{path = path, session = 100}, KP_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = r.created_id}, KP_UI).ok)
	// a shell tab, in the other session
	s2 := core.find_session(200)
	core.pane_add_tab(s2, kp_tab(210, core.Shell_Tab{}, cwd = dir))
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 210}, KP_UI).ok)
	testing.expect_value(t, len(core.closed_tabs), 2)

	// newest first: the shell, as a NEW shell in its folder, said so
	r = core.run_command(core.Reopen_Closed_Tab{}, KP_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.current_session, u64(200))
	s2 = core.find_session(200)
	_, sh, _ := core.find_tab(r.created_id)
	testing.expect(t, sh != nil && sh.id != 210, "a new tab")
	if sh != nil {
		_, is_shell := sh.kind.(core.Shell_Tab)
		testing.expect(t, is_shell)
		testing.expect_value(t, core.session_focused_id(s2), sh.id)
	}
	testing.expect_value(t, toast.text, fmt.tprintf("Reopened a new terminal in %s", core.path_tilde(dir)))

	// then the editor, in session 100
	r = core.run_command(core.Reopen_Closed_Tab{}, KP_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.current_session, u64(100))
	_, ed, _ := core.find_tab(r.created_id)
	if ed != nil {
		et, is_ed := ed.kind.(core.Editor_Tab)
		testing.expect(t, is_ed && et.path == path)
	} else do testing.fail_now(t, "no editor tab")
	testing.expect_value(t, len(core.closed_tabs), 0)

	// a tab whose session has closed since is skipped
	core.pane_add_tab(s2, kp_tab(220, core.Editor_Tab{path = strings.clone(path)}))
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 220}, KP_UI).ok)
	for &s, i in state.open_sessions do if s.id == 200 {
		ordered_remove(&state.open_sessions, i)
		break
	}
	toast_clear()
	r = core.run_command(core.Reopen_Closed_Tab{}, KP_UI)
	testing.expect(t, r.ok && r.created_id == 0)
	testing.expect_value(t, toast.text, "No closed tab to reopen")
}

@(test)
closed_tabs_authority_wire_and_menu :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	spec := core.command_spec("reopen_closed_tab")
	testing.expect(t, spec != nil && spec.who == .User_Here, "the user's own, never a hub's")
	testing.expect(t, core.caller_may(KP_UI, core.Reopen_Closed_Tab{}))
	testing.expect(t, !core.caller_may({kind = .UI, hub = true}, core.Reopen_Closed_Tab{}), "never from another machine")
	testing.expect(t, !core.caller_may({kind = .Control}, core.Reopen_Closed_Tab{}), "not an agent's")
	testing.expect(t, !core.caller_may({kind = .Panel, tab_id = 5}, core.Reopen_Closed_Tab{}))
	testing.expect_value(t, core.command_wire_json(core.Reopen_Closed_Tab{}), `{"type":"reopen_closed_tab"}`)
	cmd, err := core.parse_command(`{"type":"reopen_closed_tab"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	_, is := cmd.(core.Reopen_Closed_Tab)
	testing.expect(t, is)
	// File menu, after Close session; always runs (the core says when there is nothing)
	file: []Bar_Item
	for top in MENUBAR do if top.title == "File" do file = top.sub
	at := -1
	for it, i in file do if it.action == "close_session" do at = i
	testing.expect(t, at >= 0 && at + 1 < len(file) && file[at + 1].action == "reopen_closed_tab")
	testing.expect_value(t, menubar_keys(menubar_find("reopen_closed_tab")), "⇧⌘T")
	testing.expect_value(t, menubar_key_action(.T, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT)), "reopen_closed_tab")
	testing.expect(t, action_ok("reopen_closed_tab"))
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
	testing.expect(t, strings.contains(joined, "prev_session,next_needing_you,prev_needing_you,recent_session,least_recent_session,session_1,session_2,session_3,session_4,session_5,session_6,mark_unread,mark_all_read"), joined)
}

// Review round 1. An app's declaration rewritten after its tab closed: ⇧⌘T does not run the
// replacement (the closed tab's command and folder are what may reopen, nothing else).
@(test)
closed_tabs_app_declaration_changed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	dir := kp_dir()
	defer os.remove_all(dir)
	os.make_directory_all(fmt.tprintf("%s/.deckhand", dir))
	apps := fmt.tprintf("%s/.deckhand/apps.json", dir)
	_ = os.write_entire_file(apps, transmute([]u8)string(`{"apps":[{"name":"game","argv":["godot","--path","."]}]}`))
	s := kp_session(100, dir, kp_tab(10, core.App_Tab{argv = kp_strings("godot", "--path", "."), cwd = strings.clone(dir)}, title = "game"))
	state.current_session = 100
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 10}, KP_UI).ok)
	testing.expect_value(t, len(core.closed_tabs), 1)
	// an agent rewrites the declaration under the same name
	_ = os.write_entire_file(apps, transmute([]u8)string(`{"apps":[{"name":"game","argv":["sh","-c","evil"]}]}`))
	n := len(s.tabs)
	r := core.run_command(core.Reopen_Closed_Tab{}, KP_UI)
	testing.expect(t, r.created_id == 0, "nothing started")
	testing.expect_value(t, len(core.find_session(100).tabs), n)
	testing.expect_value(t, toast.text, "That app's command changed: open it from the project")
	// its folder moved: the same
	_ = os.write_entire_file(apps, transmute([]u8)string(`{"apps":[{"name":"game","argv":["godot","--path","."],"cwd":"sub"}]}`))
	os.make_directory_all(fmt.tprintf("%s/sub", dir))
	core.pane_add_tab(core.find_session(100), kp_tab(11, core.App_Tab{argv = kp_strings("godot", "--path", "."), cwd = strings.clone(dir)}, title = "game"))
	_ = os.write_entire_file(apps, transmute([]u8)string(`{"apps":[{"name":"game","argv":["godot","--path","."]}]}`))
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = 11}, KP_UI).ok)
	_ = os.write_entire_file(apps, transmute([]u8)string(`{"apps":[{"name":"game","argv":["godot","--path","."],"cwd":"sub"}]}`))
	toast_clear()
	r = core.run_command(core.Reopen_Closed_Tab{}, KP_UI)
	testing.expect(t, r.created_id == 0, "nothing started")
	testing.expect_value(t, toast.text, "That app's command changed: open it from the project")
}

// Mark all as read clears finished-not-seen only: an error not seen yet stays (and its record).
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
@(test)
closed_tabs_confirmed_close_keeps_its_requester :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	kp_reset()
	defer kp_reset()
	state.settings.confirm_close[.Shell] = .Always
	running :: proc(id: u64) -> core.Tab {
		x := kp_tab(id, core.Shell_Tab{})
		x.status = .Running
		return x
	}
	kp_session(100, "/tmp", running(10), running(11))
	state.current_session = 100
	// the agent's: parked for the user, who confirms it in the bar (ui)
	r := core.run_command(core.Close_Tab{tab_id = 10}, {kind = .Control})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect_value(t, len(state.pending_confirmations), 1)
	if len(state.pending_confirmations) == 1 {
		tok := strings.clone(state.pending_confirmations[0].token, context.temp_allocator)
		r = core.run_command(core.Close_Tab{tab_id = 10, confirm = tok}, KP_UI)
		testing.expect(t, r.ok, r.error)
	}
	testing.expect_value(t, len(core.closed_tabs), 0)
	// the user's own, confirmed: kept
	r = core.run_command(core.Close_Tab{tab_id = 11}, KP_UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	r = core.run_command(core.Close_Tab{tab_id = 11, confirm = r.confirm_token}, KP_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, len(core.closed_tabs), 1)
}
