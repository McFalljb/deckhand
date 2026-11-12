package main

// Status marks (agent_status.odin status_mark, ui.odin status_mark_el, icons.odin draw_mark): the
// mark each status and kind gets, progress in the view (bounded), since (a change moves it, a
// repeat report does not), another machine's status (cleaned, bounded, its since skew-safe), and
// the rows and tabs as drawn: the mark, the open row's "3m · what it asks", and no tab or row
// moving when its status changes. Same rules as core_test.odin: shared State, one thread.

import "base:runtime"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"

@(test)
status_mark_per_state :: proc(t: ^testing.T) {
	V :: core.Tab_Status_View
	cases := []struct {
		v:    V,
		want: core.Status_Mark,
	} {
		{V{dot = .None, progress = -1}, .Idle},
		{V{dot = .Exited, progress = -1}, .Exited},
		{V{dot = .Running, progress = -1}, .Working},
		{V{dot = .Running, progress = 0}, .Progress},
		{V{dot = .Running, progress = 0.4}, .Progress},
		{V{dot = .Waiting, progress = -1}, .Waiting},
		{V{dot = .Waiting, kind = .Permission, progress = -1}, .Permission},
		{V{dot = .Waiting, kind = .Question, progress = -1}, .Question},
		{V{dot = .Waiting, kind = .Auth, progress = -1}, .Auth},
		{V{dot = .Question, progress = -1}, .Question}, // its answer ended with a question
		{V{dot = .Unseen, progress = -1}, .Done},
		{V{dot = .Error, progress = -1}, .Error},
	}
	for c in cases do testing.expectf(t, core.status_mark(c.v) == c.want, "%v: %v, want %v", c.v.dot, core.status_mark(c.v), c.want)
	// every mark draws as its own icon (one box, one shape each)
	seen: map[core.Icon]bool
	defer delete(seen)
	for m in core.Status_Mark {
		if m == .None do continue
		testing.expectf(t, MARK_ICONS[m] != .None && !seen[MARK_ICONS[m]], "%v's icon", m)
		seen[MARK_ICONS[m]] = true
	}
	// the key: a kind matters only while waiting; progress never
	testing.expect(t, core.status_key({dot = .Waiting, kind = .Auth}) != core.status_key({dot = .Waiting, kind = .Question}))
	testing.expect_value(t, core.status_key({dot = .Running, progress = 0.1}), core.status_key({dot = .Running, progress = 0.9}))
}

// A fresh State: one project, one open session (current) with its pi tab and a shell.
@(private = "file")
sm_reset :: proc() -> (sid, pi_tab, sh_tab: u64) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	p := core.Project{id = core.new_id(), group = .Projects, cwd = "/tmp/sm-proj", label = "sm-proj"}
	append(&state.projects, p)
	state.selected_project = p.id
	s := core.Open_Session{id = core.new_id(), project_id = p.id, pi_session_id = "pi-sm", cwd = "/tmp/sm-proj", title = "Mark the rows"}
	append(&state.sessions, core.Session{id = "pi-sm", path = "/tmp/sm-proj/s.jsonl", title = "Mark the rows"})
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running})
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "shell 1", status = .Running})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return s.id, s.tabs[0].id, s.tabs[1].id
}

@(private = "file")
sm_report :: proc(tab: u64, reps: ..core.Prog_Report) {
	r: core.Prog_Records
	defer core.prog_free(&r)
	for x in reps do core.prog_apply(&r, x)
	core.run_command(core.Program_Status{tab_id = tab, summary = core.prog_summary(&r)})
}

@(test)
status_progress_and_since :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, _, sh_id := sm_reset()
	defer core.platform = {}
	_, sh, _ := core.find_tab(sh_id)
	// progress: while working only, 0..1
	sm_report(sh_id, {state = .Working, progress = 40, msg = "building"})
	v := core.tab_status_view(sh^)
	testing.expect_value(t, v.progress, f32(0.4))
	testing.expect_value(t, core.status_mark(v), core.Status_Mark.Progress)
	sh.prog.progress = 120 // never more than all of it, whatever the field holds
	testing.expect_value(t, core.tab_status_view(sh^).progress, f32(1))
	sm_report(sh_id, {state = .Blocked, kind = .Permission, progress = 50, msg = "Apply these edits?"})
	v = core.tab_status_view(sh^)
	testing.expect_value(t, v.progress, f32(-1))
	testing.expect_value(t, core.status_mark(v), core.Status_Mark.Permission)

	// since: set when the status changes, kept on a repeat report or a new message
	long_ago := time.time_add(time.now(), -time.Hour)
	sh.status_since = long_ago
	sm_report(sh_id, {state = .Blocked, kind = .Permission, msg = "Apply these edits?"})
	sm_report(sh_id, {state = .Blocked, kind = .Permission, msg = "Apply these other edits?"})
	testing.expect_value(t, sh.status_since, long_ago)
	testing.expect_value(t, core.tab_status_view(sh^).since, long_ago)
	// another kind is another status
	sm_report(sh_id, {state = .Blocked, kind = .Question, msg = "Which one?"})
	testing.expectf(t, time.diff(sh.status_since, time.now()) < time.Minute, "a new kind: since now, got %v", sh.status_since)
	sh.status_since = long_ago
	sm_report(sh_id, {state = .Working, progress = 10})
	testing.expect(t, sh.status_since != long_ago, "working again: since now")
	sh.status_since = long_ago
	sm_report(sh_id, {state = .Working, progress = 90}) // progress is not a new status
	testing.expect_value(t, sh.status_since, long_ago)
	// the tooltip says how long, in words
	sh.status_since = time.time_add(time.now(), -3 * time.Minute - 5 * time.Second)
	sm_report(sh_id, {state = .Working, progress = 90})
	tip := core.status_explain(sh^)
	testing.expectf(t, strings.has_suffix(tip, "working · OSC 7501, for 3m"), "%q", tip)
}

@(test)
status_mirror_cleaned_and_skew_safe :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	now := time.now()
	// a hostile summary: an unknown state, a kind off blocked, progress out of range, a message
	// with escapes, bidi and newlines, a time in the future
	bad := core.Prog_Summary{state = core.Prog_State(42), progress = 7}
	testing.expect_value(t, core.mirror_prog(bad, now, context.temp_allocator).state, core.Prog_State.None)
	h := core.Prog_Summary {
		state    = .Working,
		kind     = .Auth,
		progress = 120,
		app      = "deploy\x1b]0;pwned\x07",
		msg      = strings.concatenate({"Approve\u202e?\n\x1b[31mrm -rf /\x00 ", strings.repeat("x", 600, context.temp_allocator)}, context.temp_allocator),
		records  = 99999,
		at       = time.time_add(now, time.Hour),
	}
	m := core.mirror_prog(h, now, context.temp_allocator)
	testing.expect_value(t, m.state, core.Prog_State.Working)
	testing.expect_value(t, m.kind, core.Prog_Kind.None)
	testing.expect_value(t, m.progress, i8(-1))
	testing.expect_value(t, m.records, core.PROG_RECORDS_MAX)
	testing.expect(t, m.at == now, "never ahead of this Mac's clock")
	testing.expect(t, len(m.msg) <= core.PROG_MSG_MAX, "bounded")
	for r in m.msg do testing.expectf(t, r >= ' ' && r != 0x7f && r != 0x202e, "a control or bidi character kept: %q", m.msg)
	for r in m.app do testing.expectf(t, r >= ' ' && r != 0x7f, "%q", m.app)
	testing.expect(t, strings.has_prefix(m.msg, "Approve"), m.msg)
	m2 := core.mirror_prog({state = .Blocked, kind = .Permission, progress = 30}, now, context.temp_allocator)
	testing.expect_value(t, m2.kind, core.Prog_Kind.Permission)
	testing.expect_value(t, m2.progress, i8(30))

	// since: first seen, theirs, never ahead or absurd; then this Mac's clock
	k := u16(3)
	_, s := core.mirror_since(k, time.time_add(now, time.Hour), {}, false, now)
	testing.expect(t, s == now, "ahead: now")
	_, s = core.mirror_since(k, time.time_add(now, -5 * time.Minute), {}, false, now)
	testing.expect(t, s == time.time_add(now, -5 * time.Minute), "theirs")
	_, s = core.mirror_since(k, time.time_add(now, -3 * 365 * 24 * time.Hour), {}, false, now)
	testing.expect(t, s == {}, "absurdly old: not known")
	_, s = core.mirror_since(k, {}, {}, false, now)
	testing.expect(t, s == {}, "none: not known")
	old := time.time_add(now, -time.Hour)
	_, s = core.mirror_since(k, time.time_add(now, time.Hour), {key = k, since = old}, true, now)
	testing.expect(t, s == old, "unchanged: kept, whatever their clock says")
	last := time.time_add(now, -time.Minute)
	_, s = core.mirror_since(k, old, {key = k + 1, since = old, at = last}, true, now)
	testing.expect(t, s == last, "changed since the last merge: not before it")

	// through a merge: the tab's mark and message as this Mac shows them
	state^ = core.State{}
	state.settings.remote_machines = true
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", target = "jb@nuc", status = .Online}
	r: core.State
	append(&r.projects, core.Project{id = 5, group = .Projects, cwd = strings.clone("/home/jb/garden"), label = strings.clone("garden")})
	os := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/jb/garden"), title = strings.clone("Plant the beans")}
	tab := core.Tab{id = 10, kind = core.Claude_Tab{}, title = strings.clone("claude"), status = .Running, status_since = time.time_add(now, 10 * time.Minute)}
	tab.prog = {state = .Blocked, kind = .Permission, progress = -1, app = strings.clone("claude-code"), msg = strings.clone("Apply\u202e these\nedits?"), at = now}
	append(&os.tabs, tab)
	os.active_tab = 10
	append(&r.open_sessions, os)
	mm: core.Machine_Mirror
	core.mirror_merge(3, &r, &mm)
	defer {
		core.mirror_unmerge(3)
		core.mirror_free(&mm)
		core.replica_free(&r, runtime.heap_allocator())
		state^ = core.State{}
	}
	tid, _ := core.id_pack(3, 10)
	_, mt, _ := core.find_tab(tid)
	if !testing.expect(t, mt != nil, "merged") do return
	v := core.tab_status_view(mt^)
	testing.expect_value(t, core.status_mark(v), core.Status_Mark.Permission)
	testing.expect_value(t, v.msg, "Apply these edits?")
	testing.expectf(t, v.since != {} && time.diff(v.since, time.now()) >= 0, "never ahead: %v", v.since)
	first := v.since
	// a delta with the same status keeps it; a new one is this Mac's now
	core.mirror_merge(3, &r, &mm)
	_, mt, _ = core.find_tab(tid)
	testing.expect(t, mt.status_since == first, "the same status: kept")
	r.open_sessions[0].tabs[0].prog.state = .Working
	r.open_sessions[0].tabs[0].status_since = time.time_add(now, -48 * time.Hour) // their clock: ignored now
	core.mirror_merge(3, &r, &mm)
	_, mt, _ = core.find_tab(tid)
	testing.expect_value(t, core.status_mark(core.tab_status_view(mt^)), core.Status_Mark.Working)
	testing.expectf(t, time.diff(mt.status_since, time.now()) < time.Minute, "changed while watched: %v", mt.status_since)
}

// The custom elements of a layout that are status marks: icon and parameter, in order.
@(private = "file")
marks_drawn :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> (out: [dynamic][2]int) {
	out.allocator = context.temp_allocator
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Custom do continue
		ic, _, param := icon_of_command(c)
		if ic < .Mark_Idle || ic > .Mark_Error do continue
		b := c.boundingBox
		append(&out, b.width == px(MARK) && b.height == px(MARK) ? [2]int{int(ic), int(param)} : [2]int{-1, -1}) // -1: not one box
	}
	return
}

@(private = "file")
has_mark :: proc(got: [dynamic][2]int, ic: core.Icon, param := -1) -> bool {
	for x in got do if x[0] == int(ic) && (param < 0 || x[1] == param) do return true
	return false
}

@(private = "file")
texts_drawn :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> string {
	all := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		tx := c.renderData.text
		strings.write_string(&all, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&all, '\n')
	}
	return strings.to_string(all)
}

@(private = "file")
box_of_id :: proc(name: string, i: u32) -> clay.BoundingBox {
	return clay.GetElementData(clay.ID(name, i)).boundingBox
}

@(test)
status_marks_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	_, _, sh_id := sm_reset()
	defer {
		core.platform = {}
		state^ = core.State{}
	}
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 560, .Sessions
	state.settings.reduce_motion = true
	defer state.settings.reduce_motion = false
	_, sh, _ := core.find_tab(sh_id)

	// idle: quiet dots, in the tabs and the open row; the boxes they take
	cmds := ui_layout(2000, 900)
	got := marks_drawn(cmds)
	for x in got do testing.expectf(t, x[0] >= 0, "every mark in one MARK box: %v", got)
	testing.expectf(t, has_mark(got, .Mark_Idle), "idle: %v", got)
	tab_idle := box_of_id("tab", 1)
	row_idle := box_of_id("open", 0)

	// waiting for a yes or no: a shield, and the open row says for how long and what it asks
	sm_report(sh_id, {state = .Blocked, kind = .Permission, msg = "Apply these edits?"})
	sh.status_since = time.time_add(time.now(), -3 * time.Minute - 5 * time.Second)
	cmds = ui_layout(2000, 900)
	got = marks_drawn(cmds)
	text := texts_drawn(cmds)
	testing.expectf(t, has_mark(got, .Mark_Permission), "permission: %v", got)
	testing.expectf(t, strings.contains(text, "3m · Apply these edits?\n"), "the open row: %q", text)
	testing.expectf(t, strings.contains(text, "\nMark the rows\n"), "its title whole: %q", text)
	// nothing moved: the tab and the row keep their boxes
	testing.expect_value(t, box_of_id("tab", 1), tab_idle)
	testing.expect_value(t, box_of_id("open", 0), row_idle)

	// a narrow sidebar: the title keeps its room, the message goes first
	state.layout.left_width = 220
	text = texts_drawn(ui_layout(1200, 900))
	testing.expectf(t, strings.contains(text, "3m\n") || strings.contains(text, "3m · "), "narrow: %q", text)
	testing.expectf(t, !strings.contains(text, "3m · Apply these edits?\n"), "narrow: the message is cut or gone: %q", text)
	state.layout.left_width = 560

	// working with progress: a pie at that percent; then a question, a login, an error, done
	sm_report(sh_id, {state = .Working, progress = 40})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Progress, 40), "a pie at 40%")
	sm_report(sh_id, {state = .Working, progress = -1})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Working, 0), "still under Reduce motion")
	sm_report(sh_id, {state = .Blocked, kind = .Question, msg = "Which branch?"})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Question), "a question")
	sm_report(sh_id, {state = .Blocked, kind = .Auth})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Auth), "a login")
	sm_report(sh_id, {state = .Blocked})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Waiting), "waiting, kind unknown")
	sm_report(sh_id, {state = .Error, msg = "failed"})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Error), "an error")
	testing.expect_value(t, box_of_id("tab", 1), tab_idle)
	sh.unseen = true
	sm_report(sh_id, {state = .Done})
	testing.expect(t, has_mark(marks_drawn(ui_layout(2000, 900)), .Mark_Done), "done, not seen")
	testing.expect_value(t, box_of_id("open", 0), row_idle)
}

// Review 1: a status that changed while the link was down (or between two deltas) keeps that
// machine's own time for the change, bounded by when this Mac last saw the old status and by now.
@(test)
status_mirror_change_keeps_their_time :: proc(t: ^testing.T) {
	now := time.now()
	k := u16(3)
	seen_at := time.time_add(now, -4 * time.Hour) // the last merge that showed the old status
	prev := core.Mirror_Since{key = k + 1, since = time.time_add(now, -5 * time.Hour), at = seen_at}
	_, s := core.mirror_since(k, time.time_add(now, -3 * time.Hour), prev, true, now)
	testing.expectf(t, s == time.time_add(now, -3 * time.Hour), "theirs, inside the bounds: %v", s)
	_, s = core.mirror_since(k, time.time_add(now, -6 * time.Hour), prev, true, now)
	testing.expect(t, s == seen_at, "before the last time the old status was seen: that time")
	_, s = core.mirror_since(k, time.time_add(now, time.Hour), prev, true, now)
	testing.expect(t, s == now, "ahead: now")
	_, s = core.mirror_since(k, {}, prev, true, now)
	testing.expect(t, s == now, "none sent: now")
}

// Review 2: a Claude session open as a tab of a pi session keeps its row's mark room while idle.
@(test)
status_marks_claude_tab_row_steady :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sid, _, _ := sm_reset()
	defer {
		core.platform = {}
		state^ = core.State{}
	}
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 300, .Sessions
	s := core.find_session(sid)
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Claude_Tab{session_id = "cl-1"}, title = "claude", status = .Running})
	ctab := s.tabs[len(s.tabs) - 1].id
	append(&state.sessions, core.Session{id = "cl-1", claude = true, path = "/tmp/sm-proj/cl-1.jsonl", title = "A Claude session with a title long enough to be cut"})
	row_line :: proc() -> string {
		for l in strings.split_lines(texts_drawn(ui_layout(1400, 900)), context.temp_allocator) do if strings.has_prefix(l, "A Claude session") do return l
		return ""
	}
	idle := row_line()
	testing.expect(t, idle != "", "its row")
	sm_report(ctab, {state = .Working, progress = -1})
	testing.expect_value(t, row_line(), idle)
}

// Review 3: Atlas's button keeps one width whether or not its agent has a status.
@(test)
status_marks_atlas_button_steady :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sm_reset()
	defer {
		core.platform = {}
		state^ = core.State{}
	}
	home := core.Open_Session{id = core.new_id(), home = true, pi_session_id = "home", cwd = "/tmp"}
	append(&home.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "Atlas", status = .Running, agent = .Idle})
	home.active_tab = home.tabs[0].id
	append(&state.open_sessions, home)
	state.home = home.id
	_ = ui_layout(2000, 900)
	d := clay.GetElementData(clay.ID("homebutton"))
	if !d.found do return // no pi here: no button to check
	idle := d.boundingBox
	core.home_tab().agent = .Working
	_ = ui_layout(2000, 900)
	testing.expect_value(t, clay.GetElementData(clay.ID("homebutton")).boundingBox, idle)
}

// Review 4: a turning mark asks for frames only while one is on screen and motion is on.
@(test)
status_marks_spin_frames :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	sid, _, sh_id := sm_reset()
	defer {
		core.platform = {}
		state^ = core.State{}
		state.settings.reduce_motion = false
	}
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 300, .Sessions
	sm_report(sh_id, {state = .Working, progress = -1})
	_ = ui_layout(1400, 900)
	testing.expect(t, ui_spinning(), "a working tab on screen turns")
	state.settings.reduce_motion = true
	_ = ui_layout(1400, 900)
	testing.expect(t, !ui_spinning(), "Reduce motion: still, no frames for it")
	state.settings.reduce_motion = false
	// another session in front: the working one's only mark is its row, out of sight below
	other := core.Open_Session{id = core.new_id(), project_id = state.selected_project, pi_session_id = "pi-other", cwd = "/tmp/sm-proj"}
	append(&other.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running})
	other.active_tab = other.tabs[0].id
	append(&state.open_sessions, other)
	state.current_session = other.id
	_ = ui_layout(1400, 900)
	testing.expect(t, ui_spinning(), "its row on screen turns")
	_ = sid
	// its row out of sight: the top bar's pill (ui_fleet.odin) still shows it working, and turns
	cmds := ui_layout(1400, 60)
	pill := clay.GetElementData(clay.ID("fleetpill")).boundingBox
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Custom do continue
		if ic, _, _ := icon_of_command(c); ic != .Mark_Working do continue
		b := c.boundingBox
		testing.expectf(t, b.x >= pill.x && b.x + b.width <= pill.x + pill.width && b.y >= pill.y && b.y + b.height <= pill.y + pill.height, "the only working mark on screen is the pill's: %v", b)
	}
	testing.expect(t, ui_spinning(), "the pill turns")
}
