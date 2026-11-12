package main

// The fleet (ui_fleet.odin, core/needing_you.odin fleet_counts): one count over needing_you's tiers
// for the pill, the machine headers, the empty centre and the Dock; offline machines left out; the
// pill drawn, hidden, collapsed and steady; a machine header's mini-counts; the empty centre's rows
// and buttons; the spinner's frames with only the pill turning.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"
import clay "../build/clay-odin"

@(private = "file")
fl_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	p := core.Project{id = 1, group = .Projects, cwd = "/tmp/fl-proj", label = "web"}
	append(&state.projects, p)
	state.selected_project = p.id
	ui_hover = nil
	toast_clear()
}

// A shell tab: "" idle, "waiting" (a permission), "question" (a pi tab that ended asking),
// "error", "unseen" (finished, not seen), "working".
@(private = "file")
fl_tab :: proc(id: u64, need := "") -> core.Tab {
	t := core.Tab{id = id, kind = core.Shell_Tab{}, title = strings.clone(fmt.tprintf("tab %d", id), runtime.heap_allocator()), status = .Running}
	t.prog.progress = -1
	switch need {
	case "waiting":  t.prog.state, t.prog.kind = .Blocked, .Permission
	case "question": t.kind, t.agent, t.question = core.Pi_Tab{}, .Idle, true
	case "error":    t.prog.state = .Error
	case "unseen":   t.unseen = true
	case "working":  t.prog.state = .Working
	}
	return t
}

@(private = "file")
fl_session :: proc(id: u64, title: string, tabs: ..core.Tab) {
	context.allocator = runtime.heap_allocator()
	s := core.Open_Session{id = id, project_id = 1, pi_session_id = strings.clone(fmt.tprintf("s%d", id)), cwd = strings.clone("/tmp/fl-proj"), title = strings.clone(title)}
	for t in tabs do append(&s.tabs, t)
	s.active_tab = s.tabs[0].id
	core.session_panes_init(&s)
	append(&state.open_sessions, s)
	append(&state.sessions, core.Session{id = s.pi_session_id, path = strings.clone(fmt.tprintf("/tmp/fl-proj/%d.jsonl", id)), title = s.title})
}

@(private = "file")
fl_texts :: proc(cmds: clay.ClayArray(clay.RenderCommand), within: clay.BoundingBox = {}) -> string {
	all := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		if within != {} && !fl_inside(c.boundingBox, within) do continue
		tx := c.renderData.text
		strings.write_string(&all, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&all, '\n')
	}
	return strings.to_string(all)
}

// The status marks drawn inside a box (every mark, when the box is {}).
@(private = "file")
fl_marks :: proc(cmds: clay.ClayArray(clay.RenderCommand), within: clay.BoundingBox = {}) -> []core.Icon {
	out := make([dynamic]core.Icon, context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Custom do continue
		ic, _, _ := icon_of_command(c)
		if ic < .Mark_Idle || ic > .Mark_Error do continue
		if within != {} && !fl_inside(c.boundingBox, within) do continue
		append(&out, ic)
	}
	return out[:]
}

// Lays out a window, then reports what a click at element `name`'s centre hits.
@(private = "file")
fl_hit_at :: proc(name: string, index: u32 = 0) -> (Hit, bool) {
	_ = ui_layout(1600, 900)
	d := clay.GetElementData(clay.ID(name, index))
	if !d.found do return nil, false
	b := d.boundingBox
	clay.SetPointerState({b.x + b.width / 2, b.y + b.height / 2}, false)
	return ui_hit(), true
}

@(private = "file")
fl_inside :: proc(a, b: clay.BoundingBox) -> bool {
	return a.x >= b.x - 0.5 && a.y >= b.y - 0.5 && a.x + a.width <= b.x + b.width + 0.5 && a.y + a.height <= b.y + b.height + 0.5
}

@(private = "file")
fl_box :: proc(name: string, i: u32 = 0) -> (clay.BoundingBox, bool) {
	d := clay.GetElementData(clay.ID(name, i))
	return d.boundingBox, d.found
}

@(test)
fleet_counts_tiers_and_agreement :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fl_reset()
	defer fl_reset()
	fl_session(100, "a", fl_tab(101, "waiting"))
	fl_session(200, "b", fl_tab(201, "question"))
	fl_session(300, "c", fl_tab(301, "error"))
	fl_session(400, "d", fl_tab(401, "unseen"))
	fl_session(500, "e", fl_tab(501), fl_tab(502, "working"))
	fl_session(600, "f", fl_tab(601, "working"), fl_tab(602, "waiting")) // once, at its most urgent
	fl_session(700, "g", fl_tab(701)) // nothing
	f := core.fleet_counts()
	testing.expect_value(t, f, core.Fleet{waiting = 3, errors = 1, unseen = 1, working = 1})
	testing.expect_value(t, core.fleet_need(f), 4)
	testing.expect_value(t, core.sessions_waiting_count(), 4) // the Dock says what the pill says
	testing.expect_value(t, core.fleet_counts(0), f) // all of it this Mac's

	// the same order as ⌥⌘A: its sessions first, then the working ones
	need := core.needing_you()
	all := core.needing_you(working = true)
	testing.expect_value(t, len(need), core.fleet_need(f) + f.unseen)
	testing.expect_value(t, len(all), len(need) + f.working)
	for x, i in need do testing.expect_value(t, all[i].session.id, x.session.id)
	testing.expect_value(t, all[len(all) - 1].session.id, u64(500))
	testing.expect_value(t, all[len(all) - 1].tier, core.NEED_WORKING)
	testing.expect_value(t, core.session_need_tab(core.find_session(600), core.NEED_WAITING).id, u64(602))
	testing.expect_value(t, core.session_need_tab(core.find_session(500), core.NEED_WORKING).id, u64(502))
	// the empty centre's first row is where ⌥⌘A goes, on the same tab
	for step in 0 ..< 3 {
		s, tab := core.next_needing_target()
		first := core.needing_you(working = true)[0]
		testing.expectf(t, s != nil && s.id == first.session.id, "step %d: %v", step, s != nil ? s.id : 0)
		testing.expect_value(t, tab, core.session_need_tab(first.session, first.tier))
		// the first is answered: the next takes its place
		if s != nil do for &tb in s.tabs do tb.prog.state, tb.prog.kind, tb.question = .None, .None, false
	}
	// Home never counts
	before := core.fleet_counts()
	state.open_sessions[len(state.open_sessions) - 1].home = true
	state.open_sessions[len(state.open_sessions) - 1].tabs[0].prog.state = .Error
	testing.expect_value(t, core.fleet_counts(), before)
}

// Another machine's sessions count while it is online; an offline one's never.
@(test)
fleet_counts_machines :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	fl_reset()
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", status = .Online}
	state.machines[1] = {no = 4, name = "box", status = .Offline}
	fl_session(100, "Login page", fl_tab(101, "working"))
	mirror :: proc(no: u64, need: string, r: ^core.State, m: ^core.Machine_Mirror) {
		s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me"), title = strings.clone("Schema")}
		tb := fl_tab(10, need)
		append(&s.tabs, tb)
		s.active_tab = 10
		append(&r.open_sessions, s)
		core.mirror_merge(no, r, m)
	}
	r3, r4: core.State
	m3, m4: core.Machine_Mirror
	mirror(3, "waiting", &r3, &m3)
	mirror(4, "error", &r4, &m4)
	defer {
		core.mirror_unmerge(3)
		core.mirror_unmerge(4)
		core.mirror_free(&m3)
		core.mirror_free(&m4)
		core.replica_free(&r3, runtime.heap_allocator())
		core.replica_free(&r4, runtime.heap_allocator())
		fl_reset()
	}
	testing.expect_value(t, core.fleet_counts(), core.Fleet{waiting = 1, working = 1})
	testing.expect_value(t, core.fleet_counts(0), core.Fleet{working = 1})
	testing.expect_value(t, core.fleet_counts(3), core.Fleet{waiting = 1})
	testing.expect_value(t, core.fleet_counts(4), core.Fleet{}) // offline: none
	testing.expect_value(t, core.sessions_waiting_count(), 1)

	// the headers: this Mac's says one working, nuc's one waiting, box's nothing
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 420, .Sessions
	state.settings.reduce_motion = true
	defer state.settings.reduce_motion = false
	cmds := ui_layout(1600, 1400)
	here, _ := fl_box("machhead", 0)
	nuc, _ := fl_box("machhead", 3)
	box, okb := fl_box("machhead", 4)
	testing.expect(t, okb, "box's header")
	testing.expectf(t, slice_eq(fl_marks(cmds, here), []core.Icon{.Mark_Working}), "this Mac's: %v", fl_marks(cmds, here))
	testing.expectf(t, slice_eq(fl_marks(cmds, nuc), []core.Icon{.Mark_Waiting}), "nuc's: %v", fl_marks(cmds, nuc))
	testing.expectf(t, len(fl_marks(cmds, box)) == 0, "box's (offline): %v", fl_marks(cmds, box))
	testing.expectf(t, strings.contains(fl_texts(cmds, nuc), "nuc\n"), "nuc's name whole: %q", fl_texts(cmds, nuc))
	testing.expectf(t, strings.contains(fl_texts(cmds, nuc), "1\n"), "nuc's count: %q", fl_texts(cmds, nuc))
	// the pill: both machines' (this Mac's working, nuc's waiting), box's not
	pill, ok := fl_box("fleetpill")
	testing.expect(t, ok, "the pill")
	testing.expectf(t, slice_eq(fl_marks(cmds, pill), []core.Icon{.Mark_Waiting, .Mark_Working}), "pill: %v", fl_marks(cmds, pill))

	// a narrow sidebar: the counts give way before the name (the most urgent alone, then none)
	state.machines[0].name = "a-machine-with-a-long-name"
	for lw in ([]f32{420, 260, 200}) {
		state.layout.left_width = lw
		cmds = ui_layout(1600, 1400)
		nuc, _ = fl_box("machhead", 3)
		text := fl_texts(cmds, nuc)
		marks := fl_marks(cmds, nuc)
		if len(marks) > 0 do testing.expectf(t, strings.contains(text, "a-machine-with-a-long-name\n"), "w=%v: counts only beside the whole name: %q", lw, text)
		testing.expectf(t, len(marks) <= 1, "w=%v: %v", lw, marks)
	}

	// the empty centre: a machine column, this Mac and nuc; nuc's row (needs you) first
	state.machines[0].name = "nuc"
	state.current_session = 0
	state.layout.left_width = 300
	cmds = ui_layout(1600, 900)
	text := fl_texts(cmds)
	testing.expectf(t, strings.contains(text, "1 needs you · 1 working\n"), "summary: %q", text)
	r0, _ := fl_box("fleetrow", 0)
	r1, _ := fl_box("fleetrow", 1)
	testing.expectf(t, strings.contains(fl_texts(cmds, r0), "Schema\nnuc\n"), "row 0: %q", fl_texts(cmds, r0))
	testing.expectf(t, strings.contains(fl_texts(cmds, r1), "fl-proj ·\nLogin page\nthis Mac\n"), "row 1: %q", fl_texts(cmds, r1))
	testing.expectf(t, slice_eq(fl_marks(cmds, r0), []core.Icon{.Mark_Permission}), "row 0's mark: %v", fl_marks(cmds, r0))
}

@(private = "file")
slice_eq :: proc(a, b: []core.Icon) -> bool {
	if len(a) != len(b) do return false
	for x, i in a do if b[i] != x do return false
	return true
}

@(test)
fleet_pill_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	fl_reset()
	defer fl_reset()
	state.settings.reduce_motion = true
	defer state.settings.reduce_motion = false
	fl_session(100, "here", fl_tab(101), fl_tab(102))
	state.current_session = 100

	// nothing going on: no pill, and no room kept for it
	cmds := ui_layout(1600, 900)
	fixed := top_bar_fixed_w()
	_, ok := fl_box("fleetpill")
	testing.expect(t, !ok, "no pill with nothing going on")
	testing.expect_value(t, fleet_pill_w(), 0)
	tab0, _ := fl_box("tab", 1)

	// one waiting, one working: ◉1 ◜1, on the bar's line with the bell, as tall
	fl_session(200, "w", fl_tab(201, "waiting"))
	fl_session(300, "r", fl_tab(301, "working"))
	cmds = ui_layout(1600, 900)
	pill, found := fl_box("fleetpill")
	bell, _ := fl_box("bell")
	testing.expect(t, found, "the pill")
	testing.expect_value(t, pill.height, px(TOOL_BUTTON))
	testing.expect_value(t, pill.y, bell.y)
	testing.expectf(t, pill.x + pill.width <= bell.x, "left of the bell: %v %v", pill, bell)
	testing.expectf(t, slice_eq(fl_marks(cmds, pill), []core.Icon{.Mark_Waiting, .Mark_Working}), "%v", fl_marks(cmds, pill))
	testing.expect_value(t, fl_texts(cmds, pill), "1\n1\n")
	testing.expect_value(t, top_bar_fixed_w(), fixed + fleet_pill_w() + px(SP_1))
	label, keys := hit_tip(Hit_Button(.Fleet))
	testing.expect_value(t, label, "1 needs you, 1 working: click to go to the next")
	testing.expect_value(t, keys, "⌥⌘A")
	h, _ := fl_hit_at("fleetpill")
	testing.expectf(t, h == Hit(Hit_Button(.Fleet)), "hit %v", h)
	// marks centred on their digits: the mark's middle within a pixel of the text's
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text || !fl_inside(c.boundingBox, pill) do continue
		mid := c.boundingBox.y + c.boundingBox.height / 2
		testing.expectf(t, abs(mid - (pill.y + pill.height / 2)) <= 1, "digit centred: %v in %v", c.boundingBox, pill)
	}
	testing.expectf(t, abs(digit_nudge_test() * 2) <= px(MARK), "the nudge stays small: %v", digit_nudge_test())

	// a second waiting one: the same width (one digit), nothing beside it moves
	fl_session(400, "w2", fl_tab(401, "waiting"))
	cmds = ui_layout(1600, 900)
	pill2, _ := fl_box("fleetpill")
	testing.expect_value(t, pill2, pill)
	testing.expect_value(t, fl_texts(cmds, pill2), "2\n1\n")
	tab1, _ := fl_box("tab", 1)
	testing.expect_value(t, tab1, tab0)
	// an error among them: the waiting mark in the error colour, and its words
	core.find_session(400).tabs[0].prog = {state = .Error, progress = -1}
	_ = ui_layout(1600, 900)
	parts, n := fleet_parts(core.fleet_counts())
	testing.expect_value(t, n, 2)
	testing.expect_value(t, parts[0].mark, core.Status_Mark.Waiting)
	testing.expect_value(t, parts[0].col, theme().error)
	label, _ = fleet_tip()
	testing.expect_value(t, label, "2 need you (1 error), 1 working: click to go to the next")
	// errors alone: the error mark
	core.find_session(200).tabs[0].prog = {state = .Error, progress = -1}
	parts, _ = fleet_parts(core.fleet_counts())
	testing.expect_value(t, parts[0].mark, core.Status_Mark.Error)

	// a compact bar: the most urgent part alone
	state.layout.left_width = 400
	cmds = ui_layout(1000, 900)
	testing.expect(t, bar_compact, "compact")
	pill, _ = fl_box("fleetpill")
	testing.expectf(t, slice_eq(fl_marks(cmds, pill), []core.Icon{.Mark_Error}), "compact: %v", fl_marks(cmds, pill))
	testing.expect_value(t, fl_texts(cmds, pill), "2\n")

	// only work going on: the click goes to the working session (not a "Nothing needs you")
	for id in ([]u64{200, 400}) do core.find_session(id).tabs[0].prog = {}
	state.layout.left_width = core.LEFT_WIDTH_DEFAULT
	cmds = ui_layout(1600, 900)
	label, keys = fleet_tip()
	testing.expect_value(t, label, "1 working: click to go to the next working session")
	testing.expect_value(t, keys, "")
	button_click(.Fleet)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(300))
}

@(private = "file")
digit_nudge_test :: proc() -> f32 {
	kind, _ := font_id_split(WEIGHT_REGULAR)
	set := font.sets[kind]
	return set.baseline - set.metrics.cap_height / 2 - set.line_h / 2
}

@(test)
fleet_empty_centre :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	fl_reset()
	defer fl_reset()
	state.settings.reduce_motion = true
	defer state.settings.reduce_motion = false
	// nothing open, nothing going on: as before
	fl_session(100, "Quiet one", fl_tab(101))
	cmds := ui_layout(1600, 900)
	text := fl_texts(cmds)
	testing.expectf(t, strings.contains(text, "No session open\n"), "%q", text)
	_, ok := fl_box("fleetrow", 0)
	testing.expect(t, !ok, "no rows")

	// working, waiting, finished: the summary, the rows (needing you first), the buttons
	fl_session(200, "Build the docs", fl_tab(201, "working"))
	fl_session(300, "Login page", fl_tab(301, "waiting"))
	fl_session(400, "Schema", fl_tab(401, "unseen"))
	cmds = ui_layout(1600, 900)
	text = fl_texts(cmds)
	testing.expectf(t, !strings.contains(text, "No session open"), "%q", text)
	testing.expectf(t, strings.contains(text, "1 needs you · 1 finished · 1 working\n"), "%q", text)
	want := []string{"Login page", "Schema", "Build the docs"}
	marks := []core.Icon{.Mark_Permission, .Mark_Done, .Mark_Working}
	for w, i in want {
		b, found := fl_box("fleetrow", u32(i))
		testing.expectf(t, found, "row %d", i)
		rt := fl_texts(cmds, b)
		testing.expectf(t, strings.contains(rt, fmt.tprintf("fl-proj ·\n%s\n", w)), "row %d: %q", i, rt)
		testing.expectf(t, !strings.contains(rt, "this Mac"), "one machine: no machine column: %q", rt)
		testing.expectf(t, slice_eq(fl_marks(cmds, b), marks[i:i + 1]), "row %d mark: %v", i, fl_marks(cmds, b))
	}
	testing.expectf(t, strings.contains(text, "Go to next\n⌥⌘A\n"), "%q", text)
	testing.expectf(t, strings.contains(text, "Add project…\n"), "%q", text)
	h, _ := fl_hit_at("emptynext")
	testing.expectf(t, h == Hit(Hit_Button(.Empty_Next)), "hit %v", h)
	h, _ = fl_hit_at("fleetrow", 2)
	testing.expectf(t, h == Hit(Hit_Fleet_Row(200)), "hit %v", h)
	label, _ := hit_tip(h)
	testing.expectf(t, strings.contains(label, "working"), "row tip: %q", label)
	// a row's click: that session, on its tab, as ⌥⌘A goes
	fleet_go(200)
	core.inbox_drain()
	testing.expect_value(t, state.current_session, u64(200))
	testing.expect_value(t, core.find_session(200).active_tab, u64(201))

	// only work going on: no Go to next; New chat is the main button again (when Chats exists)
	state.current_session = 0
	core.find_session(300).tabs[0].prog = {}
	core.find_session(400).tabs[0].unseen = false
	cmds = ui_layout(1600, 900)
	text = fl_texts(cmds)
	testing.expectf(t, strings.contains(text, "1 working\n") && !strings.contains(text, "Go to next"), "%q", text)

	// more than five: five rows and "and N more"
	for i in u64(0) ..< 6 do fl_session(500 + i * 10, fmt.tprintf("Job %d", i), fl_tab(501 + i * 10, "working"))
	cmds = ui_layout(1600, 900)
	text = fl_texts(cmds)
	_, ok = fl_box("fleetrow", 4)
	testing.expect(t, ok, "five rows")
	_, ok = fl_box("fleetrow", 5)
	testing.expect(t, !ok, "not six")
	testing.expectf(t, strings.contains(text, "and 2 more\n"), "%q", text)
}

// The spinner: frames only while a turning mark is seen and motion is on, the pill's too.
@(test)
fleet_pill_spin_frames :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	fl_reset()
	defer fl_reset()
	state.layout.left_open = false // no rows: the pill is the only working mark on screen
	fl_session(100, "here", fl_tab(101))
	fl_session(200, "there", fl_tab(201, "working"))
	state.current_session = 100
	cmds := ui_layout(1400, 900)
	testing.expectf(t, slice_eq(fl_marks(cmds), []core.Icon{.Mark_Idle, .Mark_Working}), "the tab's idle mark and the pill's: %v", fl_marks(cmds))
	testing.expect(t, ui_spinning(), "the pill turns")
	state.settings.reduce_motion = true
	_ = ui_layout(1400, 900)
	testing.expect(t, !ui_spinning(), "Reduce motion: still")
	state.settings.reduce_motion = false
	core.find_session(200).tabs[0].prog = {}
	_ = ui_layout(1400, 900)
	testing.expect(t, !ui_spinning(), "nothing works: no frames")
}
