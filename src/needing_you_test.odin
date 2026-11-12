package main

// Next needing you (core/needing_you.odin; ⌥⌘A, ⌥⇧⌘A): the order (waiting, then errors, then
// finished and not seen; this Mac, then each online machine, in the order opened), cycling, the
// current session skipped unless it is the only one, offline machines left out, nothing → a toast;
// the command focuses the tab that needs you (and its pane), another machine's through the route a
// click takes; the action in the Window menu and the palette.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
NN_UI :: core.Caller{kind = .UI}

@(private = "file")
nn_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	toast_clear()
}

// A shell tab that needs: "" nothing, "waiting" (blocked on a permission), "question" (a pi tab
// that ended asking), "error", "unseen" (finished, not seen).
@(private = "file")
nn_tab :: proc(id: u64, need := "") -> core.Tab {
	t := core.Tab{id = id, kind = core.Shell_Tab{}, title = strings.clone(fmt.tprintf("tab %d", id)), status = .Running}
	switch need {
	case "waiting":
		t.prog.state, t.prog.kind = .Blocked, .Permission
	case "question":
		t.kind, t.agent, t.question = core.Pi_Tab{}, .Idle, true
	case "error":
		t.prog.state = .Error
	case "unseen":
		t.unseen = true
	}
	return t
}

// A session of this Mac's with these tabs (the first shown), in one pane.
@(private = "file")
nn_session :: proc(id: u64, tabs: ..core.Tab) {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("s%d", id)), cwd = strings.clone("/tmp"), title = strings.clone(fmt.tprintf("session %d", id))}
	for t in tabs do append(&s.tabs, t)
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
}

@(private = "file")
nn_order :: proc() -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	for x in core.needing_you() do append(&out, x.session.id)
	return out[:]
}

@(private = "file")
nn_same :: proc(a, b: []u64) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

@(test)
needing_you_order_and_cycle :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	nn_reset()
	defer nn_reset()
	nn_session(100, nn_tab(101, "unseen"))
	nn_session(200, nn_tab(201), nn_tab(202, "error"))
	nn_session(300, nn_tab(301)) // needs nothing
	nn_session(400, nn_tab(401, "waiting"))
	nn_session(500, nn_tab(501, "question"))
	nn_session(600, nn_tab(601, "unseen"), nn_tab(602, "waiting")) // its most urgent tab counts
	// waiting (and question) first, then the error, then unseen; each tier in opening order
	order := nn_order()
	testing.expectf(t, nn_same(order, {400, 500, 600, 200, 100}), "order %v", order)

	// nothing current: the first; then on round, the current one skipped, wrapping
	state.current_session = 0
	want := []u64{400, 500, 600, 200, 100, 400}
	tabs := []u64{401, 501, 602, 202, 101, 401}
	for w, i in want {
		r := core.run_command(core.Next_Needing_You{}, NN_UI)
		testing.expect(t, r.ok, r.error)
		testing.expectf(t, state.current_session == w, "step %d: session %d, want %d", i, state.current_session, w)
		s := core.find_session(w)
		testing.expectf(t, core.session_focused_id(s) == tabs[i], "step %d: tab %d, want %d", i, core.session_focused_id(s), tabs[i])
		testing.expect_value(t, r.data, fmt.tprintf(`{{"session":%d,"tab_id":%d}}`, w, tabs[i]))
		// arriving marks an unseen tab seen, as viewing it does: put it back for this walk
		if w == 100 do core.find_session(100).tabs[0].unseen = true
	}
	// back: the one before, wrapping
	state.current_session = 400
	core.run_command(core.Next_Needing_You{back = true}, NN_UI)
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect(t, !core.find_session(100).tabs[0].unseen, "arriving on it marked it seen")
	core.find_session(100).tabs[0].unseen = true
	core.run_command(core.Next_Needing_You{back = true}, NN_UI)
	testing.expect_value(t, state.current_session, u64(200))
	// from a session that needs nothing: the first (back: the last)
	state.current_session = 300
	core.run_command(core.Next_Needing_You{}, NN_UI)
	testing.expect_value(t, state.current_session, u64(400))
	state.current_session = 300
	core.run_command(core.Next_Needing_You{back = true}, NN_UI)
	testing.expect_value(t, state.current_session, u64(100))
	testing.expect_value(t, toast.text, "")
}

// The current session counts only when it is the only one: then its next needing tab in turn.
// Nothing needing you: the user's toast, no focus change.
@(test)
needing_you_only_current_and_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	nn_reset()
	defer nn_reset()
	nn_session(100, nn_tab(101), nn_tab(102, "unseen"), nn_tab(103, "waiting"))
	nn_session(200, nn_tab(201))
	state.current_session = 100
	core.session_show_tab(core.find_session(100), 101)
	s := core.find_session(100)
	// by tier, then tab order: 103 (waiting), 102 (unseen), round again
	for want in ([]u64{103, 102, 103}) {
		testing.expect(t, core.run_command(core.Next_Needing_You{}, NN_UI).ok)
		testing.expect_value(t, state.current_session, u64(100))
		testing.expect_value(t, core.session_focused_id(s), want)
		if want == 102 do s.tabs[1].unseen = true // seen by arriving: put back for the walk
	}
	// nothing needs you: a toast for the user, nothing moves
	s.tabs[1].unseen = false
	s.tabs[2].prog = {}
	testing.expect_value(t, len(core.needing_you()), 0)
	r := core.run_command(core.Next_Needing_You{}, NN_UI)
	testing.expect(t, r.ok)
	testing.expect_value(t, r.data, "")
	testing.expect_value(t, toast.text, "Nothing needs you")
	testing.expect_value(t, state.current_session, u64(100))
	toast_clear()
	// another caller (a script): no toast
	testing.expect(t, core.run_command(core.Next_Needing_You{}, {kind = .Script}).ok)
	testing.expect_value(t, toast.text, "")
	// Home never counts
	nn_session(900, nn_tab(901, "waiting"))
	core.find_session(900).home = true
	testing.expect_value(t, len(core.needing_you()), 0)
}

// The tab that needs you, in its pane: a split session's other pane gets the keyboard.
@(test)
needing_you_focuses_the_tab_and_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	nn_reset()
	defer nn_reset()
	nn_session(100, nn_tab(101))
	nn_session(200, nn_tab(201), nn_tab(202), nn_tab(203, "error"))
	state.current_session = 100
	s := core.find_session(200)
	// 203 in a pane of its own (the split moves it there), the keyboard back in the first pane
	r := core.run_command(core.Split_Pane{pane = s.focused_pane, direction = .Right, tab_id = 203}, NN_UI)
	testing.expect(t, r.ok, r.error)
	first := s.panes[0].id
	core.session_show_tab(s, 201)
	state.current_session = 100
	testing.expect(t, s.focused_pane == first, "the keyboard in the first pane")
	testing.expect(t, core.run_command(core.Next_Needing_You{}, NN_UI).ok)
	testing.expect_value(t, state.current_session, u64(200))
	testing.expect_value(t, core.session_focused_id(s), u64(203))
	testing.expect(t, s.focused_pane != first, "its pane has the keyboard")
}

// Another machine's sessions count while it is online; an offline one's never. Going to one is a
// click on its row (focus_session here and there) and on its tab (focus_tab, run there).
@(test)
needing_you_other_machines :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	nn_reset()
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	state.machines[1] = {no = 4, name = "box", status = .Offline}
	nn_session(100, nn_tab(101, "unseen"))
	nn_session(150, nn_tab(151))
	mirror :: proc(no: u64, r: ^core.State, m: ^core.Machine_Mirror) {
		s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me"), title = strings.clone("there")}
		append(&s.tabs, core.Tab{id = 10, kind = core.Pi_Tab{}, title = strings.clone("pi"), status = .Running, agent = .Idle})
		append(&s.tabs, core.Tab{id = 11, kind = core.Pi_Tab{}, title = strings.clone("pi 2"), status = .Running, waiting = true})
		s.active_tab = 10
		append(&r.open_sessions, s)
		core.mirror_merge(no, r, m)
	}
	r3, r4: core.State
	m3, m4: core.Machine_Mirror
	mirror(3, &r3, &m3)
	mirror(4, &r4, &m4)
	core.machine_test_links.on = true
	core.machine_test_links.up = make(map[u64]bool)
	core.machine_test_links.up[3] = true
	defer {
		core.machine_route_down(3, gone = true)
		core.machine_test_links.on = false
		for x in core.machine_test_links.texts do delete(x)
		clear(&core.machine_test_links.texts)
		delete(core.machine_test_links.up)
		core.mirror_unmerge(3)
		core.mirror_unmerge(4)
		core.mirror_free(&m3)
		core.mirror_free(&m4)
		core.replica_free(&r3, runtime.heap_allocator())
		core.replica_free(&r4, runtime.heap_allocator())
		nn_reset()
	}
	s3, _ := core.id_pack(3, 9)
	t3, _ := core.id_pack(3, 11)
	// the online machine's waiting session before this Mac's unseen one; the offline one's never
	order := nn_order()
	testing.expectf(t, nn_same(order, {s3, 100}), "order %v", order)
	state.current_session = 150
	r := core.run_command(core.Next_Needing_You{}, NN_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.current_session, s3)
	testing.expect_value(t, r.data, fmt.tprintf(`{{"session":%d,"tab_id":%d}}`, s3, t3))
	// sent there as a click's: focus_session (no reply wanted), then focus_tab with that machine's ids
	texts := core.machine_test_links.texts[:]
	testing.expect_value(t, len(texts), 2)
	if len(texts) == 2 {
		testing.expect(t, strings.contains(texts[0], `"type":"focus_session","session":9`), texts[0])
		testing.expect(t, strings.contains(texts[1], `"type":"focus_tab","tab_id":11`), texts[1])
		testing.expect(t, strings.contains(texts[1], `"on_behalf":{"kind":"ui"}`), texts[1])
	}
	// next: this Mac's unseen one, then round to the machine's
	core.run_command(core.Next_Needing_You{}, NN_UI)
	testing.expect_value(t, state.current_session, u64(100))
	core.find_session(100).tabs[0].unseen = true // seen by arriving: put back
	// a hub (another machine viewing this one) is never sent to a third machine's sessions
	order_hub := make([dynamic]u64, context.temp_allocator)
	for x in core.needing_you(hub = true) do append(&order_hub, x.session.id)
	testing.expectf(t, nn_same(order_hub[:], {100}), "hub order %v", order_hub)
	// the machine goes offline: its sessions no longer count
	state.machines[0].status = .Offline
	order = nn_order()
	testing.expectf(t, nn_same(order, {100}), "offline order %v", order)
}

// Who may send it: as focus_session (the user, scripts, Atlas; never a pi tab); the action in the
// Window menu next to the session stepping, with its shortcuts, and in the palette.
@(test)
needing_you_action_menu_and_authority :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	nn_reset()
	defer nn_reset()
	spec := core.command_spec("next_needing_you")
	testing.expect(t, spec != nil && spec.who == core.command_spec("focus_session").who, "the same authority as focus_session")
	testing.expect(t, !core.caller_may({kind = .Panel, tab_id = 5}, core.Next_Needing_You{}), "never a pi tab")
	testing.expect(t, core.caller_may({kind = .Control}, core.Next_Needing_You{}))
	// the wire: back only when set
	testing.expect_value(t, core.command_wire_json(core.Next_Needing_You{back = true}), `{"type":"next_needing_you","back":true}`)
	cmd, err := core.parse_command(`{"type":"next_needing_you","back":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	nn, is := cmd.(core.Next_Needing_You)
	testing.expect(t, is && nn.back)
	// the menu bar: Window, after Previous session
	testing.expect_value(t, menubar_keys(menubar_find("next_needing_you")), "⌥⌘A")
	testing.expect_value(t, menubar_keys(menubar_find("prev_needing_you")), "⌥⇧⌘A")
	window: []Bar_Item
	for top in MENUBAR do if top.title == "Window" do window = top.sub
	at := -1
	for it, i in window do if it.action == "prev_session" do at = i
	testing.expect(t, at >= 0 && at + 2 < len(window) && window[at + 1].action == "next_needing_you" && window[at + 2].action == "prev_needing_you", "after the session stepping")
	testing.expect_value(t, menubar_key_action(.A, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT)), "next_needing_you")
	testing.expect_value(t, menubar_key_action(.A, u32(sapp.MODIFIER_SUPER | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT)), "prev_needing_you")
	// always runs (the core says when nothing needs you): listed in the palette
	testing.expect(t, action_ok("next_needing_you") && action_ok("prev_needing_you"))
}
