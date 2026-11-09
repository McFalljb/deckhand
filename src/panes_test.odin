package main

// Panes (panes.odin; docs/plans/split-panes.md): the layout tree's pure operations, and a
// session split in two built directly in State (no UI, no commands that split: those come with
// the plan's P2), to check that every focused accessor means the focused pane's tab, that "on
// screen" means any pane's, and that the bell, the keyboard's targets, the tab keys and a close
// pick the right tab. Every command any unit test runs is followed by session_check
// (after_command_check, set below). Same rules as core_test.odin: shared global State, one
// thread.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

// Every unit test's commands keep every session's panes whole, and run on the heap: the test
// runner's own allocator (context.allocator in a test proc) is wiped when the test ends, while what
// a command makes outlives it (core.terms' table, a Term and its reader thread, State's arrays),
// so a test that forgets `context.allocator = runtime.heap_allocator()` corrupts the tests after it.
// A test's own tracking allocator is fine when the heap is under it.
@(init)
pt_check_every_command :: proc "contextless" () {
	core.after_command_check = proc(cmd: core.Command) {
		if !pt_on_heap(context.allocator) do log.errorf("%v ran on the test runner's allocator (freed when the test ends): set context.allocator = runtime.heap_allocator() first", reflect.union_variant_typeid(cmd))
		for &s in state.open_sessions {
			if why := core.session_check(&s); why != "" do log.errorf("panes broken after %v: session %d: %s", reflect.union_variant_typeid(cmd), s.id, why)
		}
	}
}

pt_on_heap :: proc(a: runtime.Allocator) -> bool {
	a := a
	for a.procedure == mem.tracking_allocator_proc do a = (^mem.Tracking_Allocator)(a.data).backing
	return a.procedure == runtime.heap_allocator_proc
}

@(private = "file")
pt_active: bool

// One session in State with a pane: its pi tab and n shells (not started). Current.
pt_one :: proc(n: int) -> ^core.Open_Session {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	pt_active = true
	core.platform = {window_active = proc() -> bool {return pt_active}}
	s := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("pi-pt"), cwd = "/tmp/pt"}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Not_Started})
	for i in 0 ..< n do append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = fmt.aprintf("shell %d", i + 1), status = .Not_Started})
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	state.current_session = s.id
	return &state.open_sessions[0]
}

// The fixture of the plan: pane A (left) holds the pi tab and a shell, pane B (right) an editor,
// a browser and an app tab; B is focused and shows the browser, A shows the shell. Built as a
// State literal, with stand-in runtime objects (never started) for the lookups.
Two :: struct {
	s:                                  ^core.Open_Session,
	a, b:                               u64, // panes
	pi, shell, editor, browser, app_id: u64, // tabs
	term:                               ^core.Term,
	view:                               ^Term_View, // the window's copy of term (no core stream)
}

pt_two :: proc() -> Two {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	pt_active = true
	core.platform = {window_active = proc() -> bool {return pt_active}}
	x: Two
	x.a, x.b = core.new_id(), core.new_id()
	split := core.new_id()
	x.pi, x.shell, x.editor, x.browser, x.app_id = core.new_id(), core.new_id(), core.new_id(), core.new_id(), core.new_id()
	s := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("pi-two"), cwd = "/tmp/pt"}
	append(&s.tabs, core.Tab{id = x.pi, kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle, pane = x.a})
	append(&s.tabs, core.Tab{id = x.shell, kind = core.Shell_Tab{}, title = "shell 1", status = .Running, pane = x.a})
	append(&s.tabs, core.Tab{id = x.editor, kind = core.Editor_Tab{path = "/tmp/pt/a.txt"}, title = "a.txt", status = .Running, pane = x.b})
	append(&s.tabs, core.Tab{id = x.browser, kind = core.Browser_Tab{url = "about:blank"}, title = "Browser", status = .Running, pane = x.b})
	append(&s.tabs, core.Tab{id = x.app_id, kind = core.App_Tab{}, title = "app", status = .Running, pane = x.b})
	append(&s.panes, core.Pane{id = x.a, active = x.shell, slot = 0}, core.Pane{id = x.b, active = x.browser, slot = 1})
	append(&s.nodes, core.Layout_Node{id = split, dir = .Right, ratio = 0.5, a = 1, b = 2, parent = -1})
	append(&s.nodes, core.Layout_Node{id = x.a, leaf = true, pane = x.a, parent = 0}, core.Layout_Node{id = x.b, leaf = true, pane = x.b, parent = 0})
	s.root = 0
	s.focused_pane = x.b
	append(&s.pane_mru, x.a, x.b)
	s.active_tab = x.browser
	append(&state.open_sessions, s)
	state.current_session = s.id
	x.s = &state.open_sessions[0]
	// stand-ins: found by the lookups, never run
	x.term = new(core.Term)
	core.terms[x.shell] = x.term
	x.view = new(Term_View)
	x.view.tab_id = x.shell
	term_views[x.shell] = x.view
	ed := new(Editor)
	ed.tab_id = x.editor
	editors[x.editor] = ed
	br := new(Browser)
	br.tab_id = x.browser
	browsers[x.browser] = br
	ap := new(App_Proc)
	ap.tab_id, ap.pid = x.app_id, 1 // "running": app_wants_keys asks
	apps[x.app_id] = ap
	app.window_active = true
	return x
}

// The stand-ins go (never freed through drop_term: they never started).
pt_two_done :: proc(x: Two) {
	delete_key(&core.terms, x.shell)
	delete_key(&term_views, x.shell)
	free(x.view)
	delete_key(&editors, x.editor)
	delete_key(&browsers, x.browser)
	delete_key(&apps, x.app_id)
	core.platform = {}
}

pt_strip_titles :: proc(s: ^core.Open_Session, pane: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	for t in s.tabs do if t.pane == pane {
		if strings.builder_len(b) > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, t.title)
	}
	return strings.to_string(b)
}

// ---- the tree ----

@(test)
panes_one_per_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s := pt_one(2)
	testing.expect_value(t, core.session_check(s), "")
	testing.expect_value(t, len(s.panes), 1)
	testing.expect_value(t, len(s.nodes), 1)
	for tab in s.tabs do testing.expect_value(t, tab.pane, s.panes[0].id)
	testing.expect_value(t, s.panes[0].active, s.tabs[0].id)
	testing.expect_value(t, s.focused_pane, s.panes[0].id)
	testing.expect_value(t, s.panes[0].slot, 0)
	// slot 0: exactly today's Clay ids, so scripts and tests keep clicking them
	p := &s.panes[0]
	testing.expect_value(t, pid(p, "terminal"), clay.ID("terminal"))
	testing.expect_value(t, pidi(p, "chrow", 7), clay.ID("chrow", 7))
	q := core.Pane{slot = 2}
	testing.expect(t, pid(&q, "terminal") != pid(p, "terminal"), "another slot: another id")
	testing.expect(t, pidi(&q, "chrow", 7) != pidi(p, "chrow", 7), "another slot: another row id")
	// a session with no panes yet (a snapshot, a test's literal) reads as one implicit pane
	bare := core.Open_Session{id = core.new_id()}
	append(&bare.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}}, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}})
	bare.active_tab = bare.tabs[1].id
	testing.expect_value(t, core.session_focused_id(&bare), bare.tabs[1].id)
	testing.expect(t, core.session_tab_shown(&bare, bare.tabs[1].id) && !core.session_tab_shown(&bare, bare.tabs[0].id), "its active tab only")
	testing.expect_value(t, len(core.pane_strip(&bare, core.session_focused_pane(&bare))), 2)
	testing.expect_value(t, core.session_check(&bare), "")
	// its first write gives it its pane
	core.session_show_tab(&bare, bare.tabs[0].id)
	testing.expect_value(t, len(bare.panes), 1)
	testing.expect_value(t, bare.active_tab, bare.tabs[0].id)
	testing.expect_value(t, core.session_check(&bare), "")
}

@(test)
panes_split_remove_collapse :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s := pt_one(3)
	a := s.panes[0].id
	sh1, sh2, sh3 := s.tabs[1].id, s.tabs[2].id, s.tabs[3].id // moves reorder s.tabs: by id
	// right of a: [a | b]
	b := core.pane_split(s, a, .Right)
	testing.expect(t, b != 0, "split")
	testing.expect(t, core.pane_move_tab(s, sh3, b), "a tab into the new pane")
	testing.expect_value(t, core.session_check(s), "")
	testing.expect_value(t, len(s.panes), 2)
	testing.expect_value(t, core.pane_leaf_order(s)[0], a)
	testing.expect_value(t, core.pane_leaf_order(s)[1], b)
	testing.expect_value(t, core.session_pane(s, b).slot, 1)
	// below b: [a | (b / c)]; left of a, first: [(d | a) | (b / c)]
	c := core.pane_split(s, b, .Down)
	core.pane_move_tab(s, sh2, c)
	d := core.pane_split(s, a, .Right, first = true)
	core.pane_move_tab(s, sh1, d)
	testing.expect_value(t, core.session_check(s), "")
	order := core.pane_leaf_order(s)
	testing.expect_value(t, len(order), 4)
	testing.expect(t, order[0] == d && order[1] == a && order[2] == b && order[3] == c, "leaf order d a b c")
	for p, i in s.panes do testing.expect_value(t, p.slot, i)
	// neighbours by the tree's geometry
	testing.expect_value(t, core.pane_neighbour(s, a, .Left), d)
	testing.expect_value(t, core.pane_neighbour(s, a, .Right), b) // b's centre is nearer than c's
	testing.expect_value(t, core.pane_neighbour(s, c, .Up), b)
	testing.expect_value(t, core.pane_neighbour(s, b, .Down), c)
	testing.expect_value(t, core.pane_neighbour(s, d, .Left), 0)
	// focus c, then b: removing b (its tab moved away) collapses (b / c) into c; focus goes back to c
	core.pane_focus(s, c)
	core.pane_focus(s, b)
	testing.expect_value(t, s.active_tab, core.session_pane(s, b).active)
	core.pane_move_tab(s, sh3, a) // b's only tab: b empties and goes
	testing.expect(t, core.session_pane(s, b) == nil, "the emptied pane closed")
	testing.expect_value(t, core.session_check(s), "")
	testing.expect_value(t, s.focused_pane, c)
	testing.expect_value(t, len(s.nodes), 5) // (d | a) | c: two splits, three leaves
	// close d (unsplit): its tab joins a, which shows it
	dt := core.session_pane(s, d).active
	core.pane_close(s, d)
	testing.expect(t, core.session_pane(s, d) == nil, "closed")
	testing.expect_value(t, core.pane_of_tab(s, dt).id, a)
	testing.expect_value(t, core.session_pane(s, a).active, dt)
	testing.expect_value(t, core.session_check(s), "")
	// the last pane never goes
	core.pane_close(s, c)
	testing.expect_value(t, len(s.panes), 1)
	core.pane_remove(s, s.panes[0].id)
	core.pane_close(s, s.panes[0].id)
	testing.expect_value(t, len(s.panes), 1)
	testing.expect_value(t, len(s.nodes), 1)
	testing.expect_value(t, core.session_check(s), "")
}

@(test)
panes_limits_and_rects :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s := pt_one(core.PANES_MAX + 1)
	shells := make([]u64, len(s.tabs), context.temp_allocator)
	for tab, i in s.tabs do shells[i] = tab.id // by id: moves reorder s.tabs
	for i in 1 ..< core.PANES_MAX {
		np := core.pane_split(s, s.panes[len(s.panes) - 1].id, i % 2 == 0 ? .Right : .Down)
		testing.expectf(t, np != 0, "split %d", i)
		core.pane_move_tab(s, shells[i], np)
	}
	testing.expect_value(t, len(s.panes), core.PANES_MAX)
	testing.expect_value(t, core.pane_split(s, s.panes[0].id, .Right), 0) // at most PANES_MAX
	testing.expect_value(t, core.session_check(s), "")
	// Home is never split
	h := core.Open_Session{id = core.new_id(), home = true}
	append(&h.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}})
	core.session_panes_init(&h)
	testing.expect_value(t, core.pane_split(&h, h.panes[0].id, .Right), 0)
	// rects: [a | b] in 1000×600 with a 2 px divider, then a ratio past the minimum is held at it
	s2 := pt_one(1)
	a := s2.panes[0].id
	b := core.pane_split(s2, a, .Right)
	core.pane_move_tab(s2, s2.tabs[1].id, b)
	split := s2.nodes[s2.root].id
	rs := core.pane_rects(s2, {10, 20, 1000, 600}, 2, 240, 140)
	testing.expect_value(t, len(rs), 2)
	testing.expect_value(t, rs[0].rect, [4]f32{10, 20, 499, 600})
	testing.expect_value(t, rs[1].rect, [4]f32{511, 20, 499, 600})
	testing.expect(t, core.pane_set_ratio(s2, split, 0.1), "set")
	rs = core.pane_rects(s2, {0, 0, 1000, 600}, 2, 240, 140)
	testing.expect_value(t, rs[0].rect.z, 240) // a's minimum
	testing.expect_value(t, rs[1].rect.z, 758)
	// a ratio is kept in [RATIO_MIN, 1 - RATIO_MIN]
	core.pane_set_ratio(s2, split, 2)
	testing.expect_value(t, s2.nodes[s2.root].ratio, 1 - core.RATIO_MIN)
	testing.expect(t, !core.pane_set_ratio(s2, 12345, 0.5), "no such split")
	// too small for both minimums: squeezed by the ratio, never hidden
	core.pane_set_ratio(s2, split, 0.5)
	rs = core.pane_rects(s2, {0, 0, 300, 600}, 0, 240, 140)
	testing.expect_value(t, rs[0].rect.z, 150)
	testing.expect_value(t, rs[1].rect.z, 150)
	testing.expect_value(t, core.session_check(s2), "")
}

// The pi tab is tabs[0] whatever moves: another tab never lands before it, and it changes only
// its pane, never its place.
@(test)
panes_main_tab_stays_first :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s := pt_one(3)
	pi := s.tabs[0].id
	a := s.panes[0].id
	sh1, sh2, sh3 := s.tabs[1].id, s.tabs[2].id, s.tabs[3].id
	// reorder within the pane: to strip position 0 (before the pi tab) lands right after it
	testing.expect(t, core.pane_move_tab(s, sh3, a, 0), "reorder")
	testing.expect_value(t, s.tabs[0].id, pi)
	testing.expect_value(t, s.tabs[1].id, sh3)
	testing.expect_value(t, pt_strip_titles(s, a), "pi,shell 3,shell 1,shell 2")
	// into the pi tab's pane at index 0, from another pane: after the pi tab too
	b := core.pane_split(s, a, .Right)
	core.pane_move_tab(s, sh1, b)
	testing.expect_value(t, pt_strip_titles(s, b), "shell 1")
	core.pane_move_tab(s, sh2, b) // shell 2 too, so b stays when shell 1 leaves
	core.pane_move_tab(s, sh1, a, 0)
	testing.expect_value(t, s.tabs[0].id, pi)
	testing.expect_value(t, pt_strip_titles(s, a), "pi,shell 1,shell 3")
	// the pi tab itself moves to b: its pane changes, it stays tabs[0]
	core.pane_move_tab(s, pi, b, 1)
	testing.expect_value(t, s.tabs[0].id, pi)
	testing.expect_value(t, s.tabs[0].pane, b)
	testing.expect_value(t, core.session_pane(s, b).active, pi)
	// a new tab never goes before it either
	nt := core.pane_add_tab(s, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "late"}, pane = b, after = 0)
	testing.expect(t, nt != nil && s.tabs[0].id == pi, "appended")
	testing.expect_value(t, core.session_check(s), "")
}

// ---- a session split in two ----

// Every focused accessor means pane B's tab; "on screen" means either pane's.
@(test)
panes_accessors_mean_the_focused_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	testing.expect_value(t, core.session_check(x.s), "")
	testing.expect_value(t, core.active_tab().id, x.browser)
	testing.expect_value(t, core.key_tab().id, x.browser)
	testing.expect(t, core.key_term() == nil && core.active_term() == nil, "B shows no terminal")
	testing.expect(t, tab_browser() == browsers[x.browser], "B's browser")
	testing.expect(t, tab_editor() == nil && tab_app() == nil, "nothing else of B's")
	testing.expect_value(t, core.focused_pane().id, x.b)
	// B shows its editor, then its app
	core.session_show_tab(x.s, x.editor)
	testing.expect(t, tab_editor() == editors[x.editor] && active_editor() == editors[x.editor], "B's editor")
	testing.expect(t, tab_browser() == nil, "not the hidden browser")
	core.session_show_tab(x.s, x.app_id)
	testing.expect(t, tab_app() == apps[x.app_id], "B's app")
	testing.expect_value(t, x.s.active_tab, x.app_id) // the mirror
	// on screen: both panes' active tabs; focused: B's only
	testing.expect(t, core.tab_on_screen(x.shell) && core.tab_on_screen(x.app_id), "both actives on screen")
	testing.expect(t, !core.tab_on_screen(x.pi) && !core.tab_on_screen(x.editor) && !core.tab_on_screen(x.browser), "hidden tabs are not")
	testing.expect(t, core.tab_focused(x.app_id) && !core.tab_focused(x.shell), "B's is focused, A's is not")
	// another session current: none of them
	state.current_session = 0
	testing.expect(t, !core.tab_on_screen(x.shell) && !core.tab_focused(x.app_id), "not on screen")
	state.current_session = x.s.id
	// A gets the keyboard: its shell's terminal is key_term now
	core.session_show_tab(x.s, x.shell)
	testing.expect(t, core.key_term() == x.term && core.active_term() == x.term, "A's terminal")
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, x.s.active_tab, x.shell)
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.app_id) // B still shows its app
	testing.expect_value(t, core.session_check(x.s), "")
	// the bars and handlers' pane lookups (pane_shown and friends) follow the pane given, not the focus
	b := core.session_pane(x.s, x.b)
	testing.expect(t, pane_app(b) == apps[x.app_id] && core.pane_term(b) == nil, "B's app")
	testing.expect(t, core.pane_term(core.session_pane(x.s, x.a)) == x.term, "A's terminal")
}

// The bell and unread: a tab visible in an unfocused pane counts as seen (the user's answer to
// the plan's Q7).
@(test)
panes_bell_counts_every_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	// A shows its pi tab, B (focused) its editor
	core.session_show_tab(x.s, x.pi, focus = false)
	core.session_show_tab(x.s, x.editor)
	testing.expect_value(t, core.focused_pane().id, x.b)
	testing.expect(t, core.status_on_screen(x.s, x.pi), "pi shown in the unfocused pane: on screen")
	testing.expect(t, core.status_on_screen(x.s, x.editor), "the focused tab: on screen")
	testing.expect(t, !core.status_on_screen(x.s, x.browser), "a hidden tab is not")
	testing.expect(t, core.notify_on_screen(x.s.id), "the session's pi tab is shown: its bell entries are seen")
	pt_active = false
	testing.expect(t, !core.status_on_screen(x.s, x.pi) && !core.notify_on_screen(x.s.id), "window behind: nothing seen")
	pt_active = true
	// seen: every pane's shown tab, not the hidden ones
	for &tab in x.s.tabs do tab.unseen = true
	ids := core.status_wants_seen()
	testing.expect_value(t, len(ids), 2)
	core.status_seen(x.s)
	for tab in x.s.tabs {
		shown := tab.id == x.pi || tab.id == x.editor
		testing.expectf(t, tab.unseen != shown, "%s: unseen %v", tab.title, tab.unseen)
	}
	// a pi tab only hidden in its pane: not on screen, the bell takes its entries
	core.session_show_tab(x.s, x.shell, focus = false)
	testing.expect(t, !core.notify_on_screen(x.s.id), "pi hidden behind the shell")
	// a pi run that ends while shown in the unfocused pane is not unseen
	core.session_show_tab(x.s, x.pi, focus = false)
	core.run_command(core.Pi_Status_Update{tab_id = x.pi, agent = .Working}, {kind = .Panel, tab_id = x.pi})
	core.run_command(core.Pi_Status_Update{tab_id = x.pi, agent = .Idle}, {kind = .Panel, tab_id = x.pi})
	_, pt, _ := core.find_tab(x.pi)
	testing.expect(t, !pt.unseen, "seen in pane A")
	testing.expect_value(t, len(state.notices.items), 0)
}

// The keyboard's targets: the page and the app get keys only while their tab is the focused one.
@(test)
panes_keyboard_targets :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	br, ap := browsers[x.browser], apps[x.app_id]
	testing.expect(t, browser_wants_keys(br), "B's page has the keyboard")
	testing.expect(t, !app_wants_keys(ap), "the hidden app has not")
	core.session_show_tab(x.s, x.app_id)
	testing.expect(t, app_wants_keys(ap) && !browser_wants_keys(br), "B's app now")
	// B's app on screen but A focused: no keys for it
	core.session_show_tab(x.s, x.shell)
	testing.expect(t, core.tab_on_screen(x.app_id), "B's app is still on screen (live in every pane)")
	testing.expect(t, !app_wants_keys(ap), "not focused: no keys")
	core.session_show_tab(x.s, x.app_id)
	state.focus_widget = "palette"
	testing.expect(t, !app_wants_keys(ap), "a widget has the keyboard")
	state.focus_widget = ""
	// the URL field belongs to its tab while that tab is focused
	core.session_show_tab(x.s, x.browser)
	state.focus_widget = "browser_url"
	browser_url_tab = x.browser
	testing.expect(t, !browser_url_check(), "kept on its own focused tab")
	core.session_show_tab(x.s, x.shell) // A focused: the field lets go
	testing.expect(t, browser_url_check(), "dropped")
	core.inbox_drain()
	state.focus_widget = ""
	browser_url_tab = 0
}

// ⌘1–9, ⇧⌘[ ] and ⌘W act in the focused pane.
@(test)
panes_tab_keys_in_the_focused_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	first := func_focus(tab_nth(0))
	testing.expect_value(t, first, x.editor) // B's first, not the session's (the pi tab)
	testing.expect_value(t, func_focus(tab_nth(2)), x.app_id)
	_, ok := tab_nth(3)
	testing.expect(t, !ok, "B has three tabs")
	testing.expect_value(t, func_focus(tab_step(1)), x.app_id)
	testing.expect_value(t, func_focus(tab_step(-1)), x.editor)
	core.session_show_tab(x.s, x.app_id)
	testing.expect_value(t, func_focus(tab_step(1)), x.editor) // wraps within B
	// ⌘W: B's tab
	for a in ACTIONS do if a.id == "close_tab" {
		cmd, ok2 := a.make()
		ct, is := cmd.(core.Close_Tab)
		testing.expect(t, ok2 && is && ct.tab_id == x.app_id, "closes B's tab")
	}
	// A focused: its strip
	core.session_show_tab(x.s, x.shell)
	testing.expect_value(t, func_focus(tab_nth(0)), x.pi)
	testing.expect_value(t, func_focus(tab_step(1)), x.pi)
}

@(private = "file")
func_focus :: proc(cmd: core.Command, ok: bool) -> u64 {
	if !ok do return 0
	f, is := cmd.(core.Focus_Tab)
	return is ? f.tab_id : 0
}

// A closed tab hands over within its pane; the last tab of a pane closes it; focus_tab focuses
// the tab's pane.
@(test)
panes_close_hands_over_within_the_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	// no runtime for the closes below (the stand-ins are not real ones to free)
	pt_two_done(x)
	core.platform = {window_active = proc() -> bool {return pt_active}}
	// B shows its browser (the middle one): its next tab, the app, takes over; A keeps its shell
	r := core.run_command(core.Close_Tab{tab_id = x.browser}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.app_id)
	testing.expect_value(t, core.session_pane(x.s, x.a).active, x.shell)
	testing.expect_value(t, x.s.active_tab, x.app_id)
	// the last tab of B: the one before it
	core.run_command(core.Close_Tab{tab_id = x.app_id}, {kind = .UI})
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.editor)
	// focus_tab on A's pi tab focuses A
	testing.expect(t, core.run_command(core.Focus_Tab{tab_id = x.pi}, {kind = .UI}).ok, "focus")
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, x.s.active_tab, x.pi)
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.editor)
	// closing a tab hidden in an unfocused pane changes nothing shown
	core.run_command(core.Close_Tab{tab_id = x.shell}, {kind = .UI})
	testing.expect_value(t, core.session_pane(x.s, x.a).active, x.pi)
	// B's only tab, closed while B is not focused: B goes, A stays focused
	core.run_command(core.Close_Tab{tab_id = x.editor}, {kind = .UI})
	testing.expect(t, core.session_pane(x.s, x.b) == nil, "the emptied pane closed")
	testing.expect_value(t, len(x.s.panes), 1)
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, core.session_check(x.s), "")
	// and when the focused pane empties, focus goes to the pane focused before it
	b := core.pane_split(x.s, x.a, .Right)
	tab := core.pane_add_tab(x.s, core.Tab{id = core.new_id(), kind = core.Editor_Tab{path = "/tmp/pt/b.txt"}, title = "b.txt", status = .Running}, pane = b)
	core.session_show_tab(x.s, tab.id)
	testing.expect_value(t, x.s.focused_pane, b)
	core.run_command(core.Close_Tab{tab_id = tab.id}, {kind = .UI})
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, x.s.active_tab, x.pi)
	testing.expect_value(t, core.session_check(x.s), "")
}

// An agent's open goes behind: into its own pane (after its tab), never shown, never focused,
// whichever pane the user looks at.
@(test)
panes_background_open_leaves_panes_alone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	pt_two_done(x)
	core.platform = {window_active = proc() -> bool {return pt_active}}
	dir := fmt.aprintf("%s/pt-show-%d", os.get_env("TMPDIR", context.temp_allocator), os.get_pid())
	os.make_directory_all(dir)
	defer os.remove_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/notes.txt", dir), transmute([]u8)string("one\ntwo\n"))
	append(&state.projects, core.Project{id = core.new_id(), cwd = core.fs_real(dir)})
	x.s.cwd = core.fs_real(dir)
	x.s.project_id = state.projects[0].id
	r := core.run_command(core.Show_File{path = "notes.txt"}, {kind = .Panel, tab_id = x.pi}) // pi, in pane A
	testing.expectf(t, r.ok, "shown: %s", r.error)
	_, tab, i := core.find_tab(r.created_id)
	testing.expect(t, tab != nil && tab.pane == x.a, "in the agent's pane")
	testing.expect_value(t, i, 1) // right after the pi tab
	testing.expect_value(t, core.session_pane(x.s, x.a).active, x.shell) // A's view unchanged
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.browser)
	testing.expect_value(t, x.s.focused_pane, x.b)
	testing.expect_value(t, x.s.active_tab, x.browser)
	testing.expect_value(t, core.session_check(x.s), "")
	core.run_command(core.Close_Tab{tab_id = r.created_id}, {kind = .Internal})
	// the user's open of the same kind comes to the front in the focused pane
	r2 := core.run_command(core.Open_File{path = fmt.tprintf("%s/notes.txt", dir), session = x.s.id}, {kind = .UI})
	testing.expectf(t, r2.ok, "opened: %s", r2.error)
	testing.expect_value(t, core.pane_of_tab(x.s, r2.created_id).id, x.b)
	testing.expect_value(t, x.s.active_tab, r2.created_id)
	core.run_command(core.Close_Tab{tab_id = r2.created_id}, {kind = .Internal})
}

// An agent's opens (show_file, browser_open, new_app_tab, a popup its click opened) land behind,
// in the pane holding the agent's tab where it is now (moved, or its pane closed), not in the
// focused one; the user's land in the focused pane. A caller whose tab is not in the session gets
// the focused pane. An app tab an agent restarts stays where it is.
@(test)
panes_agent_opens_land_in_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	frames_ok = -1 // no frame server in unit tests
	dir := fmt.aprintf("%s/pt-agent-%d", os.get_env("TMPDIR", context.temp_allocator), os.get_pid())
	os.make_directory_all(fmt.tprintf("%s/.deckhand", dir))
	defer os.remove_all(dir)
	_ = os.write_entire_file(fmt.tprintf("%s/notes.txt", dir), transmute([]u8)string("one\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/.deckhand/apps.json", dir), transmute([]u8)string(`{"apps":[{"name":"fake","argv":["/nonexistent/deckhand-test-app"]}]}`))
	append(&state.projects, core.Project{id = core.new_id(), cwd = core.fs_real(dir)})
	x.s.cwd = core.fs_real(dir)
	x.s.project_id = state.projects[0].id
	opened: [dynamic]u64
	defer {
		for id in opened do core.run_command(core.Close_Tab{tab_id = id}, {kind = .Internal})
		delete(opened)
	}
	// where an open landed; it changed no pane's shown tab and not the focus
	lands :: proc(t: ^testing.T, x: Two, opened: ^[dynamic]u64, r: core.Result, want_pane: u64, what: string, loc := #caller_location) {
		testing.expectf(t, r.ok && r.created_id != 0, "%s: %s", what, r.error, loc = loc)
		if r.created_id == 0 do return
		append(opened, r.created_id)
		p := core.pane_of_tab(x.s, r.created_id)
		testing.expectf(t, p != nil && p.id == want_pane, "%s: in pane %d, got %v", what, want_pane, p != nil ? p.id : 0, loc = loc)
		for pn in x.s.panes do testing.expectf(t, pn.active != r.created_id, "%s: behind, not shown", what, loc = loc)
		testing.expect_value(t, core.session_check(x.s), "", loc = loc)
	}
	pi := core.Caller{kind = .Panel, tab_id = x.pi} // in pane A; B is focused
	lands(t, x, &opened, core.run_command(core.Show_File{path = "notes.txt"}, pi), x.a, "show_file")
	lands(t, x, &opened, core.run_command(core.Browser_Open{url = "https://a.example"}, pi), x.a, "browser_open")
	lands(t, x, &opened, core.run_command(core.New_App_Tab{name = "fake"}, pi), x.a, "new_app_tab")
	app_in_a := opened[len(opened) - 1]
	testing.expect_value(t, core.session_pane(x.s, x.a).active, x.shell)
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.browser)
	testing.expect_value(t, x.s.focused_pane, x.b)
	testing.expect_value(t, x.s.active_tab, x.browser)
	// a popup an agent's click opened: the clicking agent's pane, though its opener is in B
	op := new(Act_Op)
	op.tab_id, op.who, op.who_tab = x.browser, .Panel, x.pi
	append(&act_ops, op)
	testing.expect_value(t, browser_popup_pane(x.s, x.browser), x.a)
	browser_act_reset()
	testing.expect_value(t, browser_popup_pane(x.s, x.browser), u64(0)) // no agent: the focused pane
	// a Claude tab in B, the user focused on A: its opens go to B
	cl := core.new_id()
	append(&x.s.tabs, core.Tab{id = cl, kind = core.Claude_Tab{}, title = "claude", status = .Running, pane = x.b})
	claude := core.Caller{kind = .Panel, tab_id = cl, claude = true}
	testing.expect(t, core.run_command(core.Focus_Pane{pane = x.a}, PT_UI).ok, "focus A")
	lands(t, x, &opened, core.run_command(core.Browser_Open{url = "https://b.example"}, claude), x.b, "claude browser_open")
	testing.expect_value(t, x.s.focused_pane, x.a)
	// the Claude tab moved to A, the user on B: its opens follow it
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = cl, pane = x.a, index = -1}, PT_UI).ok, "move")
	testing.expect(t, core.run_command(core.Focus_Pane{pane = x.b}, PT_UI).ok, "focus B")
	lands(t, x, &opened, core.run_command(core.Browser_Open{url = "https://c.example"}, claude), x.a, "after a move")
	lands(t, x, &opened, core.run_command(core.Show_File{path = "notes.txt"}, claude), x.a, "show_file after a move")
	// restarting its app (in A) leaves it there, wherever the agent is
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = cl, pane = x.b, index = -1}, PT_UI).ok, "move back")
	// (its program is not there: the restart is reached and fails to start, the tab stays)
	rr := core.run_command(core.App_Restart{tab_id = app_in_a}, claude)
	testing.expectf(t, rr.error == "could not start the app", "the restart was reached: %v", rr)
	testing.expect_value(t, core.pane_of_tab(x.s, app_in_a).id, x.a)
	// A closes (its tabs join B): the pi tab's opens go where it is now
	testing.expect(t, core.run_command(core.Close_Pane{pane = x.a}, PT_UI).ok, "close A")
	testing.expect_value(t, core.pane_of_tab(x.s, x.pi).id, x.b)
	lands(t, x, &opened, core.run_command(core.Browser_Open{url = "https://d.example"}, pi), x.b, "after its pane closed")
	// split again, the user on the new pane: the user's open comes to the front there
	r := core.run_command(core.Split_Pane{pane = x.b, direction = .Right, tab_id = x.editor}, PT_UI)
	testing.expectf(t, r.ok, "split: %s", r.error)
	np := r.created_id
	u := core.run_command(core.Browser_Open{url = "https://e.example"}, PT_UI)
	testing.expectf(t, u.ok, "user's open: %s", u.error)
	append(&opened, u.created_id)
	testing.expect_value(t, core.pane_of_tab(x.s, u.created_id).id, np)
	testing.expect_value(t, x.s.active_tab, u.created_id)
	// a control caller whose tab is not in this session (Atlas, Home's): the focused pane, behind
	lands(t, x, &opened, core.run_command(core.Browser_Open{session = x.s.id, url = "https://f.example"}, {kind = .Control, tab_id = 999_999}), np, "control")
	testing.expect_value(t, x.s.active_tab, u.created_id)
	testing.expect_value(t, core.open_pane(x.s, {kind = .UI, tab_id = x.pi}), u64(0)) // the user's: the focused pane
}

// A drag ends when its tab leaves the screen, not when another pane gets the focus.
@(test)
panes_drags_follow_the_screen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	core.session_show_tab(x.s, x.shell)
	drags_follow_focus()
	testing.expect_value(t, app.drag_tab, x.shell)
	x.view.mouse_down = true
	core.session_show_tab(x.s, x.browser) // B focused: A's shell is still on screen
	drags_follow_focus()
	testing.expect(t, x.view.mouse_down, "kept: still on screen")
	core.session_show_tab(x.s, x.pi) // A shows its pi tab: the shell left the screen
	drags_follow_focus()
	testing.expect(t, !x.view.mouse_down, "ended")
}

// Where a tab is drawn: its pane's laid-out rect in the current session; else, before a layout
// or in another session, its place in the tree inside the window's last centre (app.pane), the
// size it will get when shown. A terminal, a page or an app ring started there is sized by it.
@(test)
panes_tab_rect :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	saved := app.pane
	defer app.pane = saved
	app.pane = {100, 50, 1000, 600}
	// not laid out: from the tree ([A | B] at 0.5, a divider of BORDER_W), under each pane's strip
	app.dpi = 1
	testing.expect_value(t, tab_rect(x.shell), [4]f32{100, 50 + TAB_STRIP_H, 499.5, 600 - TAB_STRIP_H})
	testing.expect_value(t, tab_rect(x.app_id), [4]f32{600.5, 50 + TAB_STRIP_H, 499.5, 600 - TAB_STRIP_H})
	// laid out: the pane's own rect
	core.session_pane(x.s, x.b).rect = {610, 52, 480, 590}
	testing.expect_value(t, tab_rect(x.browser), [4]f32{610, 52, 480, 590})
	testing.expect_value(t, pane_rect(core.session_pane(x.s, x.b)), [4]f32{610, 52, 480, 590})
	// another session current: from the tree again (its rects are last time's)
	state.current_session = 0
	testing.expect_value(t, tab_rect(x.browser), [4]f32{600.5, 50 + TAB_STRIP_H, 499.5, 600 - TAB_STRIP_H})
	state.current_session = x.s.id
	// a tab not added yet (new_term before pane_add_tab), or unknown: the window's
	testing.expect_value(t, tab_rect(987654), app.pane)
	// one pane: exactly the centre, as before panes
	s := pt_one(1)
	testing.expect_value(t, tab_rect(s.tabs[1].id), app.pane)
}

// Fonts and Clay once, at 1x, without a window (layout only, no drawing): as buttons_test.odin.
pt_ui :: proc() -> bool {
	@(static) ready: bool
	if ready do return true
	app.dpi = 1
	font.size = ATLAS_MIN
	font.pixels = make([]u8, ATLAS_MIN * ATLAS_MIN * 4)
	if !fonts_apply(theme_font_config(theme()), 1) do return false
	ui_init()
	ready = true
	return true
}

// An editor only takes hits where it was drawn in the last frame drawn: Markdown tab M shown as
// source (its editor drawn), then editor E, then M's preview (M's editor not drawn): the pointer
// over M's preview is not over M's text (no I-beam, the chrome's hover stays).
@(test)
panes_editor_hits_only_where_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}
	_ = ui_layout(1400, 860)
	d := clay.GetElementData(clay.ID("terminal"))
	if !testing.expect(t, d.found, "the content laid out") do return
	cx, cy := d.boundingBox.x + d.boundingBox.width / 2, d.boundingBox.y + d.boundingBox.height / 2
	m, e := new(Editor), new(Editor)
	m.tab_id, e.tab_id = s.tabs[1].id, s.tabs[2].id
	editors[m.tab_id], editors[e.tab_id] = m, e
	defer {
		delete_key(&editors, m.tab_id)
		delete_key(&editors, e.tab_id)
	}
	drawn :: proc(x: ^Editor) {x.area, x.area_drawn = {lh = 20, cw = 8, rows = 10, cols = 40}, true} // as editor_draw
	editors_frame_begin() // M as source
	drawn(m)
	testing.expect(t, editor_text_hit(m, cx, cy), "drawn: hit")
	editors_frame_begin() // E
	drawn(e)
	editors_frame_begin() // M's preview: its editor is not drawn
	testing.expect(t, !editor_text_hit(m, cx, cy), "not drawn this frame: no hit")
	testing.expect(t, !editor_text_hit(e, cx, cy), "E is not on screen either")
}

// Page Down and Page Up in an editor that was never drawn (keys before its first frame) move by a
// page of its pane, not to the end of the file.
@(test)
panes_editor_keys_before_its_first_draw :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	s := pt_one(1)
	saved := app.pane
	defer app.pane = saved
	app.pane = {0, 0, 800, 600}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 500 do fmt.sbprintf(&b, "line %d\n", i)
	e := new(Editor)
	e.tab_id, e.goal_col, e.readonly = s.tabs[1].id, -1, true
	e.eol, e.indent_w = "\n", 4
	tb_init(&e.buf, transmute([]u8)strings.clone(strings.to_string(b)))
	editors[e.tab_id] = e
	defer delete_key(&editors, e.tab_id)
	up := sapp.Event{type = .KEY_DOWN, key_code = .PAGE_UP}
	editor_event(e, &up)
	testing.expect_value(t, e.top, 0)
	down := sapp.Event{type = .KEY_DOWN, key_code = .PAGE_DOWN}
	editor_event(e, &down)
	testing.expectf(t, e.top > 0 && e.top < 100, "one page down: top %d", e.top)
}

// A tab with no pane in a session that has panes (added around pane_add_tab) is adopted by the
// focused pane: focus_tab shows it, closing it hands over, s.active_tab never names a closed tab.
@(test)
panes_orphan_tab_adopted :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	s := pt_one(1)
	saved := core.after_command_check
	core.after_command_check = nil // the orphan breaks the check until adopted
	defer core.after_command_check = saved
	orphan := core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "orphan", status = .Not_Started}
	append(&s.tabs, orphan)
	testing.expect(t, core.run_command(core.Focus_Tab{tab_id = orphan.id}, {kind = .UI}).ok, "focus")
	testing.expect_value(t, s.active_tab, orphan.id)
	testing.expect_value(t, s.panes[0].active, orphan.id)
	testing.expect_value(t, core.session_check(s), "")
	// another orphan named by s.active_tab (written around session_show_tab), then closed
	o2 := core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "o2", status = .Not_Started}
	append(&s.tabs, o2)
	s.active_tab = o2.id
	testing.expect(t, core.run_command(core.Close_Tab{tab_id = o2.id}, {kind = .UI}).ok, "close")
	_, gone, _ := core.find_tab(s.active_tab)
	testing.expect(t, gone != nil, "s.active_tab names an open tab")
	testing.expect_value(t, core.session_check(s), "")
}

// pidi packs slot and index without collisions; slot 0 is clay.ID(name, i), as before panes.
@(test)
panes_pidi_no_collisions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	seen := make(map[u32]string, context.temp_allocator)
	for slot in 0 ..< 4 {
		p := core.Pane{slot = slot}
		for i in ([]int{0, 1, 65535, 65536, 65537, 1 << 20}) {
			id := pidi(&p, "chrow", i)
			if slot == 0 do testing.expect_value(t, id, clay.ID("chrow", u32(i)))
			key := fmt.tprintf("slot %d row %d", slot, i)
			if other, dup := seen[id.id]; dup do testing.expectf(t, false, "%s collides with %s", key, other)
			seen[id.id] = key
		}
		// pid is its slot's index 0, as clay.ID(x) is clay.ID(x, 0)
		testing.expect_value(t, pid(&p, "chrow").id, pidi(&p, "chrow", 0).id)
	}
}

// ---- P2: the pane commands ----

PT_UI :: core.Caller{kind = .UI}

// split_pane with a tab: the tab moves into the new pane, which gets the keyboard; created_id is
// the pane. Directions: left/up put the new pane first. Refusals: no such pane, a pane's only
// tab, Home, PANES_MAX.
@(test)
panes_cmd_split :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	r := core.run_command(core.Split_Pane{pane = x.b, direction = .Down, tab_id = x.editor}, PT_UI)
	testing.expectf(t, r.ok, "split: %s", r.error)
	np := r.created_id
	testing.expect_value(t, len(x.s.panes), 3)
	testing.expect_value(t, x.s.focused_pane, np)
	_, ed, _ := core.find_tab(x.editor)
	testing.expect_value(t, ed.pane, np)
	testing.expect_value(t, core.session_focused_id(x.s), x.editor)
	testing.expect_value(t, core.pane_neighbour(x.s, x.b, .Down), np)
	// left: the new pane comes first, the keyboard stays with focus: false
	r = core.run_command(core.Split_Pane{pane = x.a, direction = .Left, tab_id = x.shell, no_focus = true}, PT_UI)
	testing.expectf(t, r.ok, "split left: %s", r.error)
	testing.expect_value(t, core.pane_leaf_order(x.s)[0], r.created_id)
	testing.expect_value(t, x.s.focused_pane, np)
	// refusals
	testing.expect_value(t, core.run_command(core.Split_Pane{pane = 12345, direction = .Right}, PT_UI).error, "no such pane")
	testing.expect_value(t, core.run_command(core.Split_Pane{pane = r.created_id, direction = .Right, tab_id = x.shell}, PT_UI).error, "a pane's only tab cannot move to a new pane")
	// PANES_MAX
	s := pt_one(core.PANES_MAX + 1)
	ids: [core.PANES_MAX + 2]u64
	for tab, i in s.tabs do ids[i] = tab.id
	first := s.focused_pane
	for i in 1 ..< core.PANES_MAX do testing.expectf(t, core.run_command(core.Split_Pane{pane = first, direction = .Down, tab_id = ids[i + 1]}, PT_UI).ok, "split %d", i)
	testing.expect_value(t, len(s.panes), core.PANES_MAX)
	testing.expect_value(t, core.run_command(core.Split_Pane{pane = first, direction = .Right, tab_id = ids[1]}, PT_UI).error, fmt.tprintf("at most %d panes", core.PANES_MAX))
	// the wire: direction names, focus false
	cmd, err := core.parse_command(`{"type":"split_pane","direction":"up","tab_id":7,"focus":false}`)
	testing.expectf(t, err == "", "parse: %s", err)
	sp := cmd.(core.Split_Pane)
	testing.expect(t, sp.direction == .Up && sp.tab_id == 7 && sp.no_focus && sp.pane == 0, "parsed")
	_, err = core.parse_command(`{"type":"split_pane","direction":"sideways"}`)
	testing.expect(t, err != "", "a bad direction is refused")
}

// Callers: Anyone, so control callers may; a pi or Claude tab's bridge (panel) and an app may
// not. Home has one pane.
@(test)
panes_cmd_callers_and_home :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	not :: "not allowed for this caller"
	testing.expect_value(t, core.run_command(core.Focus_Pane{pane = x.a}, {kind = .Panel, tab_id = x.pi}).error, not)
	testing.expect_value(t, core.run_command(core.Move_Tab{tab_id = x.shell, pane = x.b, index = -1}, {kind = .App, tab_id = x.app_id}).error, not)
	r := core.run_command(core.Focus_Pane{pane = x.a}, {kind = .Control})
	testing.expectf(t, r.ok, "control: %s", r.error)
	testing.expect_value(t, x.s.focused_pane, x.a)
	// Home
	hs := core.Open_Session{id = core.new_id(), home = true, cwd = "/tmp/pt"}
	append(&hs.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "agent", status = .Not_Started})
	hs.active_tab = hs.tabs[0].id
	core.session_panes_init(&hs)
	hp := hs.panes[0].id
	append(&state.open_sessions, hs)
	x.s = &state.open_sessions[0]
	h := &state.open_sessions[1]
	testing.expect_value(t, core.run_command(core.Split_Pane{pane = hp, direction = .Right, tab_id = h.tabs[0].id}, PT_UI).error, core.HOME_NOT_A_SESSION)
	testing.expect_value(t, core.run_command(core.Focus_Pane{pane = hp}, PT_UI).error, core.HOME_NOT_A_SESSION)
	testing.expect_value(t, core.run_command(core.Move_Tab{tab_id = h.tabs[0].id, pane = hp, index = -1}, PT_UI).error, core.HOME_NOT_A_SESSION)
	testing.expect_value(t, core.run_command(core.Equalize_Panes{session = h.id}, PT_UI).error, core.HOME_NOT_A_SESSION)
	testing.expect_value(t, len(h.panes), 1)
	// unknown ids
	testing.expect_value(t, core.run_command(core.Close_Pane{pane = 999}, PT_UI).error, "no such pane")
	testing.expect_value(t, core.run_command(core.Focus_Pane{pane = 999}, PT_UI).error, "no such pane")
	testing.expect_value(t, core.run_command(core.Move_Tab{tab_id = 999, pane = x.a, index = -1}, PT_UI).error, "no such tab")
	testing.expect_value(t, core.run_command(core.Move_Tab{tab_id = x.shell, pane = hp, index = -1}, PT_UI).error, "not a pane of the tab's session")
	testing.expect_value(t, core.run_command(core.Set_Split{split = 999, ratio = 0.5}, PT_UI).error, "no such split")
	testing.expect_value(t, core.run_command(core.Equalize_Panes{session = 999}, PT_UI).error, "no such session")
}

// close_pane: non-destructive, its tabs join the neighbour (nothing stops); the last pane stays.
// The pane's shown tab stays shown there; focus goes to the most recently used pane.
@(test)
panes_cmd_close :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	n := len(x.s.tabs)
	r := core.run_command(core.Close_Pane{pane = x.b}, PT_UI)
	testing.expectf(t, r.ok, "close: %s", r.error)
	testing.expect_value(t, len(x.s.panes), 1)
	testing.expect_value(t, len(x.s.tabs), n)
	testing.expect_value(t, x.s.focused_pane, x.a)
	for tab in x.s.tabs do testing.expect_value(t, tab.pane, x.a)
	testing.expect_value(t, x.s.tabs[0].id, x.pi)
	testing.expect_value(t, core.run_command(core.Close_Pane{pane = x.a}, PT_UI).error, "a session's last pane cannot close")
}

// A pane collapses when its last tab closes; the keyboard goes to the most recently used pane.
@(test)
panes_last_tab_closes_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	// three panes: A, B, and C (the shell); focus order A, then C
	r := core.run_command(core.Split_Pane{pane = x.a, direction = .Down, tab_id = x.shell}, PT_UI)
	c := r.created_id
	core.run_command(core.Focus_Pane{pane = x.b}, PT_UI)
	core.run_command(core.Focus_Pane{pane = x.a}, PT_UI)
	core.run_command(core.Focus_Pane{pane = c}, PT_UI)
	delete_key(&core.terms, x.shell) // closes without a terminal
	rc := core.run_command(core.Close_Tab{tab_id = x.shell, confirm = "", comments = .Drop}, PT_UI)
	testing.expectf(t, rc.ok, "close tab: %s", rc.error)
	testing.expect_value(t, len(x.s.panes), 2)
	testing.expect(t, core.session_pane(x.s, c) == nil, "C collapsed")
	testing.expect_value(t, x.s.focused_pane, x.a) // the most recently used before C
}

// focus_pane: by id or direction (left/right/up/down, next/prev cycle); the pane's tab gets the
// keyboard; nothing that way is refused.
@(test)
panes_cmd_focus :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	testing.expect(t, core.run_command(core.Focus_Pane{direction = "left"}, PT_UI).ok, "left of B: A")
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, core.session_focused_id(x.s), x.shell)
	testing.expect_value(t, core.run_command(core.Focus_Pane{direction = "left"}, PT_UI).error, "no pane that way")
	testing.expect_value(t, core.run_command(core.Focus_Pane{direction = "up"}, PT_UI).error, "no pane that way")
	testing.expect(t, core.run_command(core.Focus_Pane{direction = "next"}, PT_UI).ok, "next")
	testing.expect_value(t, x.s.focused_pane, x.b)
	testing.expect(t, core.run_command(core.Focus_Pane{direction = "next"}, PT_UI).ok, "next wraps")
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect(t, core.run_command(core.Focus_Pane{direction = "prev"}, PT_UI).ok, "prev wraps")
	testing.expect_value(t, x.s.focused_pane, x.b)
	testing.expect_value(t, core.run_command(core.Focus_Pane{direction = "sideways"}, PT_UI).error, "direction: left, right, up, down, next or prev")
	testing.expect_value(t, core.run_command(core.Focus_Pane{pane = x.a, direction = "left"}, PT_UI).error, "pane or direction, not both")
	testing.expect(t, core.run_command(core.Focus_Pane{pane = x.a}, PT_UI).ok, "by id")
	testing.expect_value(t, x.s.focused_pane, x.a)
}

// move_tab: into another pane at an index or the end, or a reorder within its pane; the pi tab
// moves but stays tabs[0]; nothing lands before it; the keyboard follows the focused tab; a pane
// it leaves empty closes.
@(test)
panes_cmd_move_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	// the browser (focused) to A at index 0: never before the pi tab (tabs[0])
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = x.browser, pane = x.a, index = 0}, PT_UI).ok, "browser to A")
	testing.expect_value(t, x.s.focused_pane, x.a) // the keyboard followed it
	testing.expect_value(t, core.session_focused_id(x.s), x.browser)
	testing.expect_value(t, pt_strip_titles(x.s, x.a), "pi,Browser,shell 1")
	testing.expect_value(t, x.s.tabs[0].id, x.pi)
	// the pi tab to B: it moves (B shows it) but stays tabs[0]; the keyboard stays in A
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = x.pi, pane = x.b, index = -1}, PT_UI).ok, "pi to B")
	testing.expect_value(t, x.s.tabs[0].id, x.pi)
	testing.expect_value(t, core.pane_of_tab(x.s, x.pi).id, x.b)
	testing.expect_value(t, core.session_pane(x.s, x.b).active, x.pi)
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, pt_strip_titles(x.s, x.a), "Browser,shell 1")
	// a reorder within A
	testing.expect(t, core.run_command(core.Move_Tab{tab_id = x.browser, pane = x.a, index = -1}, PT_UI).ok, "reorder")
	testing.expect_value(t, pt_strip_titles(x.s, x.a), "shell 1,Browser")
	testing.expect_value(t, x.s.tabs[0].id, x.pi)
	// A's tabs all go to B: A closes
	core.run_command(core.Move_Tab{tab_id = x.browser, pane = x.b, index = -1}, PT_UI)
	core.run_command(core.Move_Tab{tab_id = x.shell, pane = x.b, index = -1}, PT_UI)
	testing.expect_value(t, len(x.s.panes), 1)
	testing.expect(t, core.session_pane(x.s, x.a) == nil, "A closed")
}

// set_split clamps to [RATIO_MIN, 1-RATIO_MIN] (bad ratios refused); equalize_panes gives equal
// panes equal room along each direction.
@(test)
panes_cmd_set_split_equalize :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	split := x.s.nodes[x.s.root].id
	testing.expect(t, core.run_command(core.Set_Split{split = split, ratio = 0.7}, PT_UI).ok, "set")
	testing.expect_value(t, x.s.nodes[x.s.root].ratio, f32(0.7))
	testing.expect(t, core.run_command(core.Set_Split{split = split, ratio = 0.999}, PT_UI).ok, "clamped")
	testing.expect_value(t, x.s.nodes[x.s.root].ratio, f32(1 - core.RATIO_MIN))
	testing.expect_value(t, core.run_command(core.Set_Split{split = split, ratio = 1.5}, PT_UI).error, "ratio: between 0 and 1")
	testing.expect_value(t, core.run_command(core.Set_Split{split = split, ratio = -1}, PT_UI).error, "ratio: between 0 and 1")
	// A | B | C (B split right again): the root gives A a third
	core.run_command(core.Split_Pane{pane = x.b, direction = .Right, tab_id = x.app_id}, PT_UI)
	testing.expect(t, core.run_command(core.Equalize_Panes{}, PT_UI).ok, "equalize")
	root := x.s.nodes[x.s.root]
	testing.expectf(t, abs(root.ratio - f32(1.0 / 3.0)) < 0.001, "root %v", root.ratio)
	testing.expectf(t, abs(x.s.nodes[root.b].ratio - 0.5) < 0.001, "inner %v", x.s.nodes[root.b].ratio)
	// a split across (down) counts as one along the other way
	core.run_command(core.Split_Pane{pane = x.a, direction = .Down, tab_id = x.shell}, PT_UI)
	core.run_command(core.Equalize_Panes{}, PT_UI)
	root = x.s.nodes[x.s.root]
	testing.expectf(t, abs(root.ratio - f32(1.0 / 3.0)) < 0.001, "root %v after a down split", root.ratio)
}

// The snapshot: per session focused_pane, panes (id, slot, active_tab, tabs) and the layout tree;
// per tab its pane and on_screen.
@(test)
panes_snapshot :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	js := core.state_json()
	split := x.s.nodes[x.s.root].id
	want := []string {
		fmt.tprintf(`"focused_pane":%d`, x.b),
		fmt.tprintf(`"panes":[{{"id":%d,"slot":0,"active_tab":%d,"tabs":[%d,%d]}},{{"id":%d,"slot":1,"active_tab":%d,"tabs":[%d,%d,%d]}}]`, x.a, x.shell, x.pi, x.shell, x.b, x.browser, x.editor, x.browser, x.app_id),
		fmt.tprintf(`"layout":{{"split":%d,"dir":"right","ratio":0.500,"a":{{"pane":%d}},"b":{{"pane":%d}}}}`, split, x.a, x.b),
		fmt.tprintf(`"id":%d,"kind":"shell","title":"shell 1","status":"running","pane":%d,"on_screen":true`, x.shell, x.a),
		fmt.tprintf(`"id":%d,"kind":"pi","title":"pi","status":"running","pane":%d,"on_screen":false`, x.pi, x.a),
	}
	for w in want do testing.expectf(t, strings.contains(js, w), "snapshot has %s", w)
}

// A split session laid out (1400 × 860, the default columns): one strip per pane and none of its
// tabs in the title bar; the panes' rects from their pane_body, side by side with a divider
// between; a tab in the second strip and its "+" are hit there (ids by tab index and pane slot);
// three panes (right, then down) keep every pane at least its minimum.
@(test)
panes_split_layout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	ids := [3]u64{s.tabs[0].id, s.tabs[1].id, s.tabs[2].id}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = ids[2]}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	_ = ui_layout(1400, 860)
	ui_pane_rects(s)
	pa, pb := core.session_pane(s, s.panes[0].id), core.session_pane(s, b)
	testing.expect(t, pa.rect.z > 0 && pb.rect.z > 0, "both laid out")
	testing.expectf(t, abs(pb.rect.x - (pa.rect.x + pa.rect.z + core.BORDER_W)) < 1, "B right of A past the divider: %v %v", pa.rect, pb.rect)
	testing.expectf(t, abs(pa.rect.z - pb.rect.z) <= 1, "even: %v %v", pa.rect.z, pb.rect.z)
	testing.expect(t, clay.GetElementData(pid(pa, "pane_strip")).found && clay.GetElementData(pid(pb, "pane_strip")).found, "a strip per pane")
	strip := clay.GetElementData(pid(pb, "pane_strip")).boundingBox
	testing.expectf(t, pb.frame.y == strip.y && pb.rect.y >= strip.y + strip.height, "B's content under its strip: %v %v", pb.rect, strip)
	// the second strip's tab (s.tabs index 2) and "+": hit where they are
	idx := -1
	for tab, i in s.tabs do if tab.id == ids[2] do idx = i
	tb := clay.GetElementData(clay.ID("tab", u32(idx)))
	if !testing.expect(t, tb.found, "B's tab laid out") do return
	testing.expectf(t, tb.boundingBox.x >= pb.frame.x && tb.boundingBox.y >= strip.y, "in B's strip: %v", tb.boundingBox)
	app.pointer = {tb.boundingBox.x + 4, tb.boundingBox.y + tb.boundingBox.height / 2}
	clay.SetPointerState(app.pointer, false)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, ui_hit(), Hit(Hit_Tab(ids[2])))
	nb := clay.GetElementData(pid(pb, "pane_new")).boundingBox
	app.pointer = {nb.x + nb.width / 2, nb.y + nb.height / 2}
	clay.SetPointerState(app.pointer, false)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, ui_hit(), Hit(Hit_Pane_New(b)))
	// three panes: B split down; nobody under the minimum
	r = core.run_command(core.Split_Pane{pane = b, direction = .Down, tab_id = ids[1]}, PT_UI)
	testing.expectf(t, r.ok, "split down: %s", r.error)
	_ = ui_layout(1400, 860)
	ui_pane_rects(s)
	for p in s.panes {
		testing.expectf(t, p.rect.z >= core.PANE_MIN_W && p.rect.w >= core.PANE_MIN_H - TAB_STRIP_H, "pane %d: %v", p.slot, p.rect)
	}
	// a split that leaves no room for two panes is refused (in a 1000 px window B is 350 wide: two
	// need 481); a new shell, not the pi tab: alone in A, it would take A's room with it
	_ = ui_layout(1000, 860)
	ui_pane_rects(s)
	r = core.run_command(core.Split_Pane{pane = b, direction = .Right}, PT_UI)
	testing.expect_value(t, r.error, "not enough room")
	centre_reset()
}


// H3: a press in unfocused pane A's terminal focuses A synchronously and its own drag survives the
// focus change; capture keeps the press's pane for moves over another pane until the release.
@(test)
panes_press_keeps_its_drag :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	core.session_pane(x.s, x.a).rect = {0, 0, 100, 100}
	core.session_pane(x.s, x.b).rect = {101, 0, 100, 100}
	drags_follow_focus()
	e := sapp.Event{type = .MOUSE_DOWN, mouse_x = 50, mouse_y = 50, mouse_button = .LEFT}
	pane_press(&e) // click-through
	x.view.mouse_down = true // the selection term_mouse_down starts
	drags_follow_focus() // the next event
	testing.expect(t, x.view.mouse_down, "the press's own drag survives the focus change")
	mv := sapp.Event{type = .MOUSE_MOVE, mouse_x = 150, mouse_y = 50}
	testing.expect_value(t, event_pane(&mv).id, x.a) // held: still A's
	pane_release()
	testing.expect_value(t, event_pane(&mv).id, x.b) // released: the pane under the pointer
	k := sapp.Event{type = .KEY_DOWN}
	testing.expect_value(t, event_pane(&k).id, x.a) // keys: the focused pane
}


// The panes' actions: ⌘D splits right (a new shell: the command, not run here), ⇧⌃⌘arrows move
// the tab to the neighbour or split that way; ⇧⌘W closes the pane; ⌃⌘arrows only where a pane is.
@(test)
panes_actions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	cmd, ok := pane_split_action(.Right)
	testing.expect(t, ok && cmd.(core.Split_Pane).direction == .Right && cmd.(core.Split_Pane).tab_id == 0, "⌘D: a new shell in a new pane")
	cmd, ok = pane_move_action(.Left)
	testing.expect(t, ok, "move left")
	mt := cmd.(core.Move_Tab)
	testing.expect(t, mt.tab_id == x.browser && mt.pane == x.a, "to A")
	cmd, ok = pane_move_action(.Down)
	sp := cmd.(core.Split_Pane)
	testing.expect(t, ok && sp.tab_id == x.browser && sp.direction == .Down && sp.pane == x.b, "no pane below: split down with the tab")
	_, ok = pane_focus_action(.Right)
	testing.expect(t, !ok, "nothing right of B")
	cmd, ok = pane_focus_action(.Left)
	testing.expect(t, ok && cmd.(core.Focus_Pane).direction == "left", "⌃⌘←")
	// one pane: no pane actions but the splits
	core.run_command(core.Close_Pane{pane = x.b}, PT_UI)
	_, ok = pane_focus_action(.Left)
	testing.expect(t, !ok, "one pane: no focus moves")
	cmd, ok = pane_move_action(.Right)
	testing.expect(t, ok && cmd.(core.Split_Pane).tab_id == x.browser, "one pane: ⇧⌃⌘→ splits with the tab")
	for a in ACTIONS do if a.id == "close_pane" {
		_, ok = a.make()
		testing.expect(t, !ok, "⇧⌘W with one pane")
	}
	// the keys parse (the menu bar shows them)
	k, kok := parse_keys("⇧⌃⌘←")
	testing.expect(t, kok && k.code == .LEFT && k.mods == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT | sapp.MODIFIER_CTRL, "⇧⌃⌘←")
}


// A pane divider: hit DIVIDER_HIT wide across its line; a drag follows the pointer live (the
// layout's ratio) and sets the split once, on release, kept off the panes' minimum; a
// double-click evens it.
@(test)
panes_divider_drag :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	s := pt_one(1)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[1].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	split := s.nodes[s.root].id
	_ = ui_layout(1400, 860)
	div := clay.GetElementData(clay.ID("pane_div", u32(split))).boundingBox
	x, y := div.x, div.y + 100
	testing.expect_value(t, pane_divider_at(x + DIVIDER_HIT / 2 - 0.5, y), split)
	testing.expect_value(t, pane_divider_at(x + DIVIDER_HIT, y), u64(0))
	pane_divider_press(split, 1)
	pane_divider_move(x - 100, y)
	testing.expect(t, pane_drag.active && pane_drag.ratio < 0.5, "live")
	testing.expect_value(t, s.nodes[s.root].ratio, f32(0.5)) // not set until the release
	pane_divider_move(0, y) // far past A's minimum
	pane_divider_release()
	core.inbox_drain()
	_ = ui_layout(1400, 860)
	ui_pane_rects(s)
	testing.expectf(t, abs(s.panes[0].rect.z - core.PANE_MIN_W) < 1, "A at its minimum: %v", s.panes[0].rect)
	pane_divider_press(split, 2)
	core.inbox_drain()
	testing.expect_value(t, s.nodes[s.root].ratio, f32(0.5))
	testing.expect(t, !pane_drag.active, "a double-click is no drag")
}

// A press in a pane without the keyboard focuses it at once (pane_press, before the handlers):
// then the click goes on there (click-through: a page gets it, and the keyboard), and the pane
// holds the press until the release.
@(test)
panes_press_focuses_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	core.run_command(core.Focus_Pane{pane = x.a}, PT_UI)
	core.session_pane(x.s, x.a).rect = {0, 0, 100, 100}
	core.session_pane(x.s, x.b).rect = {101, 0, 100, 100}
	e := sapp.Event{type = .MOUSE_DOWN, mouse_x = 150, mouse_y = 50, mouse_button = .LEFT}
	pane_press(&e) // on B's page: focuses B, and the click goes on to the page (click-through)
	testing.expect_value(t, x.s.focused_pane, x.b)
	testing.expect(t, browser_wants_keys(browsers[x.browser]), "the page has the keyboard now")
	pane_release()
	e.mouse_x = 50
	pane_press(&e)
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, pointer_capture.pane, x.a)
	pane_release()
	testing.expect_value(t, pointer_capture.pane, u64(0))
}

// ---- P2 review fixes ----

// A split session with a Changes tab in one pane and a shell in the other: the Changes tab is read
// again when it comes on screen, not on every layout (each pane's bars are laid out in turn).
@(test)
panes_changes_not_refreshed_every_layout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	s := pt_one(1)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	root := "/tmp/pt-changes"
	r := new(core.Changes_Repo)
	r.root = root
	append(&core.changes_repos, r)
	defer {
		pop(&core.changes_repos)
		free(r)
	}
	ct := core.pane_add_tab(s, core.Tab{id = core.new_id(), kind = core.Changes_Tab{root = root}, title = "Changes", status = .Running})
	cid_ := ct.id
	v := new(core.Changes_View)
	v.tab_id, v.root = cid_, root
	core.changes_views[cid_] = v
	defer {
		delete_key(&core.changes_views, cid_)
		free(v)
	}
	res := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[1].id}, PT_UI) // the shell to B; A shows Changes
	if !testing.expectf(t, res.ok, "split: %s", res.error) do return
	core.session_show_tab(s, cid_, focus = false)
	_ = ui_layout(1400, 860)
	gen := r.gen
	_ = ui_layout(1400, 860)
	testing.expect_value(t, r.gen, gen)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, r.gen, gen)
}

// A field's caret and hits are its pane's: a browser's URL field in pane slot 1 is found by
// focused_field (so it keeps the keyboard on a click inside, and draws its caret there).
@(test)
panes_field_in_second_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	state.focus_widget = "browser_url"
	browser_url_tab = x.browser
	defer {
		state.focus_widget = ""
		browser_url_tab = 0
	}
	_ = ui_layout(1400, 860)
	testing.expect(t, clay.GetElementData(pid(core.session_pane(x.s, x.b), "br_url_box")).found, "B's URL field laid out")
	f, text_id, box_id := focused_field()
	testing.expect(t, f == &browser_url_field, "the URL field")
	testing.expect(t, clay.GetElementData(box_id).found && clay.GetElementData(text_id).found, "focused_field finds it in slot 1")
	testing.expect_value(t, box_id.id, pid(core.session_pane(x.s, x.b), "br_url_box").id)
}

// A press under an overlay (the palette) or the agent's drawer focuses no pane and holds none.
@(test)
panes_press_under_an_overlay :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	core.run_command(core.Focus_Pane{pane = x.a}, PT_UI)
	core.session_pane(x.s, x.a).rect = {0, 0, 100, 100}
	core.session_pane(x.s, x.b).rect = {101, 0, 100, 100}
	e := sapp.Event{type = .MOUSE_DOWN, mouse_x = 150, mouse_y = 50, mouse_button = .LEFT}
	state.focus_widget = "palette"
	pane_press(&e) // the palette's click
	state.focus_widget = ""
	core.inbox_drain()
	testing.expect_value(t, x.s.focused_pane, x.a)
	testing.expect_value(t, pointer_capture.pane, u64(0))
}

// The editor's find bar keeps the keyboard when the pointer moves over another pane; the bar's
// keys act on the focused pane's editor.
@(test)
panes_editor_bar_keeps_focus_on_moves :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	core.session_show_tab(x.s, x.editor) // B focused, its editor
	state.focus_widget = "editor_find"
	defer state.focus_widget = ""
	mv := sapp.Event{type = .MOUSE_MOVE, mouse_x = 10, mouse_y = 10}
	testing.expect(t, !editor_bar_event(core.session_pane(x.s, x.a), &mv), "a move is not the bar's")
	core.inbox_drain()
	testing.expect_value(t, state.focus_widget, "editor_find")
}

// The wheel and moves over a pane's Markdown preview are that pane's, not the focused tab's.
@(test)
panes_markdown_preview_of_the_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	_, ed, _ := core.find_tab(x.editor)
	ed.kind = core.Markdown_Tab{path = "/tmp/pt/a.md"}
	mv := new(Md_View)
	md_views[x.editor] = mv
	defer {
		delete_key(&md_views, x.editor)
		free(mv)
	}
	core.session_show_tab(x.s, x.editor, focus = false) // B shows the preview
	core.run_command(core.Focus_Pane{pane = x.a}, PT_UI) // A (its shell) has the keyboard
	testing.expect(t, md_preview_shown(core.session_pane(x.s, x.b)), "B's preview")
	testing.expect(t, !md_preview_shown(core.session_pane(x.s, x.a)), "A's shell")
}

// split_pane's room check counts every pane's minimum (not only the split one's halves), and
// set_split keeps every pane at its minimum.
@(test)
panes_room_and_ratio_keep_minimums :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	s := pt_one(3)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	ids := [4]u64{s.tabs[0].id, s.tabs[1].id, s.tabs[2].id, s.tabs[3].id}
	a := s.focused_pane
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = ids[3]}, PT_UI)
	b := r.created_id
	split := s.nodes[s.root].id
	_ = ui_layout(1000, 860) // the centre: 700 wide
	ui_pane_rects(s)
	// set_split 0.95: B would be 35 wide; kept at its minimum
	testing.expect(t, core.run_command(core.Set_Split{split = split, ratio = 0.95}, PT_UI).ok, "set")
	_ = ui_layout(1000, 860)
	ui_pane_rects(s)
	testing.expectf(t, core.session_pane(s, b).rect.z >= core.PANE_MIN_W - 1, "B kept at its minimum: %v (ratio %v)", core.session_pane(s, b).rect, s.nodes[s.root].ratio)
	// A is about 459 wide now; splitting it right needs 481 for its halves, and B's 240 too
	r = core.run_command(core.Split_Pane{pane = a, direction = .Right, tab_id = ids[1]}, PT_UI)
	testing.expect_value(t, r.error, "not enough room")
}

// ⇧⌘W with one pane is not the panes' key (⌘W's tab close and the menu bar get it); ⌘D on Home
// is not either.
@(test)
panes_keys_fall_through_when_they_do_not_apply :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	w := sapp.Event{type = .KEY_DOWN, key_code = .W, modifiers = sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT}
	core.run_command(core.Close_Pane{pane = x.b}, PT_UI)
	testing.expect(t, !pane_key(&w), "one pane: not taken")
	d := sapp.Event{type = .KEY_DOWN, key_code = .D, modifiers = sapp.MODIFIER_SUPER}
	testing.expect(t, pane_key(&d), "⌘D splits")
	core.inbox_drain()
}

// A hidden terminal is sized to its pane's content without any tab's bars (the pane less its
// strip), so showing a tab with bars (a Changes header) and back never resizes the others.
@(test)
panes_terminal_rect_ignores_other_tabs_bars :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	app.dpi = 1
	pa := core.session_pane(x.s, x.a)
	pa.frame = {0, 0, 500, 600}
	pa.rect = {0, 140, 500, 460} // under a Changes tab's header
	core.session_show_tab(x.s, x.pi, focus = false) // A shows its pi tab: the shell is hidden
	testing.expect_value(t, term_target_rect(x.shell), [4]f32{0, TAB_STRIP_H, 500, 600 - TAB_STRIP_H})
}

// ---- P4: browser and app tabs live in every pane ----

// A page or an app shown in a pane without the keyboard is on screen (drawn, seen, visible to the
// page plan and the app), but only the focused one gets keys.
@(test)
panes_texture_tabs_live_in_every_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	core.run_command(core.Focus_Pane{pane = x.a}, PT_UI) // A's shell has the keyboard; B shows its page
	testing.expect(t, core.tab_on_screen(x.browser), "B's page is on screen")
	testing.expect(t, !browser_wants_keys(browsers[x.browser]), "but has no keys")
	for &tab in x.s.tabs do tab.unseen = true
	core.status_seen(x.s)
	_, br, _ := core.find_tab(x.browser)
	testing.expect(t, !br.unseen, "seen in B")
	core.session_show_tab(x.s, x.app_id, focus = false)
	testing.expect(t, core.tab_on_screen(x.app_id), "B's app is on screen")
	testing.expect(t, !app_wants_keys(apps[x.app_id]), "without keys")
	// the agent's view: browser_tabs says on screen for B's page
	core.session_show_tab(x.s, x.browser, focus = false)
	r := core.run_command(core.Browser_Tabs{session = x.s.id}, {kind = .Control})
	testing.expectf(t, strings.contains(r.data, `"on_screen":true`), "browser_tabs: %s", r.data)
}

// Several visible pages and no free slot: each takes a different hidden page's slot, never the
// same one twice, and never a visible one's; one that finds none waits.
@(test)
panes_page_plan_several_visible :: proc(t: ^testing.T) {
	pages := []Page_Info {
		{session = 1, wants = true, visible = true, shown = 10},
		{session = 1, wants = true, visible = true, shown = 11},
		{session = 1, live = true, shown = 5}, // hidden: the one victim
		{session = 1, live = true, visible = true, shown = 12}, // on screen in a third pane: never
	}
	p := browser_page_plan(pages, 0)
	testing.expect_value(t, len(p.unload), 1)
	testing.expect_value(t, len(p.load), 1)
	testing.expect_value(t, len(p.wait), 1)
	if len(p.unload) == 1 do testing.expect_value(t, p.unload[0], 2)
}

// The bars' click guard is per tab: two pages on screen at once keep their own "bars unchanged
// since"; a tab that leaves the screen starts its guard again when it comes back.
@(test)
panes_bars_guard_per_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	other := core.new_id()
	core.pane_add_tab(x.s, core.Tab{id = other, kind = core.Browser_Tab{url = "about:blank"}, title = "Other", status = .Running}, pane = x.a)
	br := new(Browser)
	br.tab_id = other
	browsers[other] = br
	defer delete_key(&browsers, other)
	core.session_show_tab(x.s, other, focus = false) // A shows Other, B the browser: both on screen
	t0 := time.tick_now()
	bars_note(x.browser, t0)
	bars_note(other, t0)
	later := time.tick_add(t0, BARS_GUARD + time.Millisecond)
	bars_note(other, later)
	testing.expect(t, bars_click_ok(x.browser, later), "B's bars stayed: its click counts")
	testing.expect(t, bars_click_ok(other, later), "and A's")
	// Other leaves the screen and comes back: its guard starts again
	core.session_show_tab(x.s, x.shell, focus = false)
	browser_polish_pending_tick()
	core.session_show_tab(x.s, other, focus = false)
	testing.expect(t, !bars_click_ok(other, time.tick_add(later, time.Millisecond)), "just came back")
}

// A page's toolbar wider than its narrow pane (buttons, an agent's strip) hides its end: the pane
// and its content keep their share of the centre, so the page's view is its pane's size.
@(test)
panes_bars_never_widen_a_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	for _ in 0 ..< 3 {
		_ = ui_layout(800, 860) // the centre: 500 wide, B about 250
		ui_pane_rects(x.s)
	}
	pb := core.session_pane(x.s, x.b)
	bar := clay.GetElementData(pid(pb, "browser_bar"))
	testing.expect(t, bar.found, "B's toolbar laid out")
	testing.expectf(t, abs(pb.rect.z - pane_width_of(x.s, x.b)) < 1, "B's content keeps its share: %v, share %v (toolbar %v)", pb.rect, pane_width_of(x.s, x.b), bar.boundingBox.width)
	testing.expectf(t, pb.frame.x + pb.frame.z <= 800 + 0.5, "inside the window: %v", pb.frame)
}

@(private = "file")
pane_width_of :: proc(s: ^core.Open_Session, pane: u64) -> f32 {
	for r in core.pane_rects(s, app.centre, px(core.BORDER_W), px(core.PANE_MIN_W), px(core.PANE_MIN_H)) do if r.pane == pane do return r.rect.z
	return 0
}

// P4 review 1: a narrow right pane with the right column open, a page asking for a permission and
// a prompt: each bar is its pane's width at most (one wide bar never stretches the others), and a
// press beside the pane at a bar's height (the right column) is never a bar's: it grants nothing
// and reaches the column.
@(test)
panes_bars_hit_only_inside_their_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	defer delete_key(&page_extras, x.browser)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true}
	p := page_extra(x.browser)
	p.perm = PERM_NOTIFICATIONS
	p.dialog, p.dialog_kind = true, .Prompt
	W :: 1180 // the centre about 600: B about 300
	for _ in 0 ..< 3 {
		_ = ui_layout(W, 860)
		ui_pane_rects(x.s)
	}
	pb := core.session_pane(x.s, x.b)
	right := pb.frame.x + pb.frame.z
	testing.expectf(t, right < W - px(100), "the right column is beside B: %v", pb.frame)
	for name in ([]string{"browser_bar", "pg_perm", "pg_dialog"}) {
		d := clay.GetElementData(pid(pb, name))
		testing.expectf(t, d.found, "%s laid out", name)
		testing.expectf(t, d.boundingBox.x + d.boundingBox.width <= right + 0.5, "%s within B: %v, B ends at %v", name, d.boundingBox, right)
	}
	// presses right of B along every bar's row: none is a bar's (none sends a command)
	old := ids_pane_begin(pb)
	defer ids_pane_end(old)
	for name in ([]string{"browser_bar", "pg_perm", "pg_dialog"}) {
		d := clay.GetElementData(pid(pb, name))
		y := d.boundingBox.y + d.boundingBox.height / 2
		for xx := right + 2; xx < W - 2; xx += 8 {
			e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = xx, mouse_y = y}
			testing.expectf(t, !browser_polish_event(pb, &e), "%s's row at x=%v: the bars took it", name, xx)
			testing.expectf(t, !browser_bar_click(pb, &e), "%s's row at x=%v: the toolbar took it", name, xx)
			testing.expectf(t, !annot_event(pb, &e), "%s's row at x=%v: Annotate took it", name, xx)
		}
	}
	core.inbox_drain()
}

// P4 review 2: at its least width a page's pane still shows the agent strip's buttons whole (the
// address and the strip's text give way first): Take over / Hand back and Stop are always in reach.
@(test)
panes_agent_strip_buttons_fit_a_narrow_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	_, bt, _ := core.find_tab(x.browser)
	bt.kind = core.Browser_Tab{url = "https://a-rather-long-host-name.example.com/and/a/long/path?with=a&query=too"}
	x.s.nodes[0].ratio = 0.95 // B at its least width (clamped)
	at := agent_tab(x.browser)
	defer {delete_key(&agent_tabs, x.browser); free(at)}
	at.want_console, at.want_net = true, true // the strip shows: "pi is recording console, network"
	for handback in ([]bool{false, true}) {
		at.user_control = handback
		for _ in 0 ..< 3 {
			_ = ui_layout(1100, 860)
			ui_pane_rects(x.s)
		}
		pb := core.session_pane(x.s, x.b)
		testing.expectf(t, abs(pb.frame.z - px(core.PANE_MIN_W)) < 2, "B at its least width: %v", pb.frame)
		right := pb.frame.x + pb.frame.z
		for name in ([]string{handback ? "br_agent_handback" : "br_agent_takeover", "br_agent_stop"}) {
			d := clay.GetElementData(pid(pb, name))
			testing.expectf(t, d.found, "%s laid out", name)
			testing.expectf(t, d.boundingBox.x >= pb.frame.x && d.boundingBox.x + d.boundingBox.width <= right + 0.5, "%s whole in B: %v, B %v", name, d.boundingBox, pb.frame)
			// and a press there is the button's
			old := ids_pane_begin(pb)
			e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = d.boundingBox.x + d.boundingBox.width / 2, mouse_y = d.boundingBox.y + d.boundingBox.height / 2}
			testing.expectf(t, browser_bar_click(pb, &e), "a press on %s is the toolbar's", name)
			ids_pane_end(old)
		}
	}
	// the palette offers the strip's buttons too
	at.user_control = true
	testing.expect(t, pt_action_offered("browser_agent_handback"), "the palette's Hand back")
	testing.expect(t, pt_action_offered("browser_agent_stop"), "the palette's Stop")
	at.user_control = false
	testing.expect(t, !pt_action_offered("browser_agent_handback"), "no Hand back while the agent has it")
	testing.expect(t, pt_action_offered("browser_agent_takeover"), "the palette's Take over")
	clear_inbox_for_test()
}

@(private = "file")
pt_action_offered :: proc(id: string) -> bool {
	for a in ACTIONS do if a.id == id {
		_, ok := a.make()
		return ok
	}
	return false
}

@(private = "file")
clear_inbox_for_test :: proc() {
	// what the presses queued: against stand-ins (no page), refused and gone
	core.inbox_drain()
}

// P4 review 3: the pointer moving from one pane into another: the pane it left hears it leave
// (an app's hover goes; a page gets CEF's mouse-leave), as when it leaves the window.
@(test)
panes_pointer_leaves_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	core.session_show_tab(x.s, x.app_id)
	ap := apps[x.app_id]
	ap.inspect = true // its hover is Deckhand's: a.hin says the pointer is over it
	for _ in 0 ..< 3 {
		_ = ui_layout(1400, 860)
		ui_pane_rects(x.s)
	}
	pa, pb := core.session_pane(x.s, x.a), core.session_pane(x.s, x.b)
	e := sapp.Event{type = .MOUSE_MOVE, mouse_x = pb.rect.x + pb.rect.z / 2, mouse_y = pb.rect.y + pb.rect.w / 2}
	event(&e)
	testing.expect(t, ap.hin, "over the app")
	e = {type = .MOUSE_MOVE, mouse_x = pa.rect.x + pa.rect.z / 2, mouse_y = pa.rect.y + pa.rect.w / 2}
	event(&e)
	testing.expect(t, !ap.hin, "the pointer left the app's pane: its hover went")
	core.inbox_drain()
}

// P4 round 2, 1: the focused prompt field reaching past its narrow pane's edge: a press there,
// beside the pane, is not the field's (the field's editing ends; the press goes on as usual).
@(test)
panes_field_press_only_inside_its_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	defer delete_key(&page_extras, x.browser)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true}
	p := page_extra(x.browser)
	p.dialog, p.dialog_kind = true, .Prompt
	page_prompt_tab = x.browser
	defer page_prompt_tab = 0
	state.focus_widget = "browser_prompt"
	W :: 1180
	for _ in 0 ..< 3 {
		_ = ui_layout(W, 860)
		ui_pane_rects(x.s)
	}
	pb := core.session_pane(x.s, x.b)
	right := pb.frame.x + pb.frame.z
	d := clay.GetElementData(pid(pb, "pg_prompt_box"))
	if !testing.expectf(t, d.found && d.boundingBox.x + d.boundingBox.width > right + 4, "the field reaches past B's edge: %v, B ends at %v", d.boundingBox, right) do return
	e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = right + 2, mouse_y = d.boundingBox.y + d.boundingBox.height / 2}
	testing.expect(t, !widget_event(&e), "beside B: not the field's")
	core.inbox_drain()
	testing.expectf(t, state.focus_widget == "", "the field's editing ended: %q", state.focus_widget)
}

// P4 round 2, 2: the pointer leaving the focused pane for no pane (a column): it hears it leave.
@(test)
panes_pointer_leaves_for_a_column :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	x := pt_two()
	defer pt_two_done(x)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	core.session_show_tab(x.s, x.app_id)
	ap := apps[x.app_id]
	ap.inspect = true
	for _ in 0 ..< 3 {
		_ = ui_layout(1400, 860)
		ui_pane_rects(x.s)
	}
	pb := core.session_pane(x.s, x.b)
	testing.expect(t, x.s.focused_pane == x.b, "B has the keyboard")
	e := sapp.Event{type = .MOUSE_MOVE, mouse_x = pb.rect.x + pb.rect.z / 2, mouse_y = pb.rect.y + pb.rect.w / 2}
	event(&e)
	testing.expect(t, ap.hin, "over the app")
	e = {type = .MOUSE_MOVE, mouse_x = px(40), mouse_y = pb.rect.y + pb.rect.w / 2} // the left column
	event(&e)
	testing.expect(t, !ap.hin, "the pointer left for the left column: its hover went")
	// the pane it left is known to have been left (a page there gets CEF's leave; cef 0 here)
	testing.expectf(t, pointer_pane == 0, "over no pane now: %v", pointer_pane)
	// a held press keeps its pane: no leave while it drags outside
	e = {type = .MOUSE_MOVE, mouse_x = pb.rect.x + pb.rect.z / 2, mouse_y = pb.rect.y + pb.rect.w / 2}
	event(&e)
	pointer_capture = {pane = x.b}
	defer pointer_capture = {}
	e = {type = .MOUSE_MOVE, mouse_x = px(40), mouse_y = pb.rect.y + pb.rect.w / 2}
	event(&e)
	testing.expectf(t, pointer_pane == x.b, "the press's pane while held: %v", pointer_pane)
	core.inbox_drain()
}

// The window's centre back to "not laid out" (app.centre and what it sent the core).
centre_reset :: proc() {
	app.centre = {}
	core.pane_centre = {}
}

// split_pane's room check from the centre size the window sent (no Clay, no layout): at scale 1
// two panes across need 2 * 240 + 1 px, at scale 2 twice that; down, 2 * 140 + 1.
@(test)
pane_room_from_the_sent_centre :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	defer centre_reset()
	s := pt_one(3)
	p := s.panes[0].id
	core.pane_centre_set(480, 1000, 1)
	testing.expect(t, !core.pane_has_room(s, p, .Right))
	testing.expect(t, core.pane_has_room(s, p, .Down))
	core.pane_centre_set(481, 280, 1)
	testing.expect(t, core.pane_has_room(s, p, .Right))
	testing.expect(t, !core.pane_has_room(s, p, .Down))
	core.pane_centre_set(900, 600, 2) // 450 logical px: no room across
	testing.expect(t, !core.pane_has_room(s, p, .Right))
	r := core.run_command(core.Split_Pane{pane = p, direction = .Right}, PT_UI)
	testing.expect_value(t, r.error, "not enough room")
	core.pane_centre_set(1000, 600, 1)
	r = core.run_command(core.Split_Pane{pane = p, direction = .Right, tab_id = s.tabs[1].id}, PT_UI)
	testing.expectf(t, r.ok, "split: %s", r.error)
	// two across in 1000: each ~500; a third beside either needs 3 * 240 + 2 = 722 across: yes,
	// but the 500 px pane itself has room for two halves (481) too
	testing.expect(t, core.pane_has_room(s, s.panes[0].id, .Right))
	core.pane_centre_set(700, 600, 1) // 3 * 240 + 2 = 722 > 700
	testing.expect(t, !core.pane_has_room(s, s.panes[0].id, .Right))
	// not laid out: every split has room
	core.pane_centre = {}
	testing.expect(t, core.pane_has_room(s, s.panes[0].id, .Right))
}

// set_split's ratio is kept off the panes' minimums at the split's size from the sent centre
// (no Clay): in 1001 px across (1000 + the divider), a pane is at least 240 px, so 0.1 becomes 0.24.
@(test)
pane_ratio_from_the_sent_centre :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	defer centre_reset()
	s := pt_one(2)
	r := core.run_command(core.Split_Pane{pane = s.panes[0].id, direction = .Right, tab_id = s.tabs[1].id}, PT_UI)
	testing.expectf(t, r.ok, "split: %s", r.error)
	split := s.nodes[s.root].id
	// not laid out: the ratio as given
	r = core.run_command(core.Set_Split{split = split, ratio = 0.1})
	testing.expect(t, r.ok)
	testing.expect(t, abs(s.nodes[s.root].ratio - 0.1) < 1e-4)
	core.pane_centre_set(1001, 600, 1)
	r = core.run_command(core.Set_Split{split = split, ratio = 0.1})
	testing.expect(t, r.ok)
	testing.expectf(t, abs(s.nodes[s.root].ratio - 0.24) < 1e-4, "kept: %v", s.nodes[s.root].ratio)
	r = core.run_command(core.Set_Split{split = split, ratio = 0.95})
	testing.expectf(t, abs(s.nodes[s.root].ratio - 0.76) < 1e-4, "kept: %v", s.nodes[s.root].ratio)
	r = core.run_command(core.Set_Split{split = split, ratio = 0.5})
	testing.expect(t, abs(s.nodes[s.root].ratio - 0.5) < 1e-4)
	// scale 2: 901 framebuffer px is 450 logical: no room for both, the ratio alone decides
	core.pane_centre_set(901, 600, 2)
	r = core.run_command(core.Set_Split{split = split, ratio = 0.1})
	testing.expect(t, abs(s.nodes[s.root].ratio - 0.1) < 1e-4)
	// a nested split's size is its place in the tree: the right half of 1001 at 0.5 is 500 px
	core.pane_centre_set(1001, 600, 1)
	core.run_command(core.Set_Split{split = split, ratio = 0.5})
	right := s.nodes[s.nodes[s.root].b].pane // child b of the root
	np := core.pane_split(s, right, .Down)
	testing.expect(t, np != 0)
	left := s.nodes[s.nodes[s.root].a].pane
	mv: u64 // the shell beside the pi tab in the left pane
	for tab in s.tabs[1:] do if tab.pane == left do mv = tab.id
	testing.expect(t, core.pane_move_tab(s, mv, np))
	inner: u64
	for n in s.nodes do if !n.leaf && n.dir == .Down do inner = n.id
	rect, ok := core.pane_split_rect(s, inner, {0, 0, 1001, 600}, 1, 240, 140)
	testing.expect(t, ok)
	testing.expectf(t, abs(rect.z - 500) < 0.5 && abs(rect.w - 600) < 0.5, "inner split: %v", rect)
	r = core.run_command(core.Set_Split{split = inner, ratio = 0.05}) // 599 px down: at least 140 / 599
	testing.expect(t, r.ok)
	for n in s.nodes do if n.id == inner do testing.expectf(t, abs(n.ratio - 140.0 / 599) < 1e-3, "inner kept: %v", n.ratio)
}
