package main

// State changes you can see (ui.odin flash, status_flash; term_view.odin's copy shine; actions'
// done toasts): the one-shot curve and its end, which statuses flash and which never do (working,
// idle, a repeat report, a stale one, a connect's, Reduce motion), the wash's contrast in every
// look, the mark's pop inside its box, frames only while a flash is seen, and the toasts. Same
// rules as core_test.odin: shared State, one thread.

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"

@(test)
flash_curve :: proc(t: ^testing.T) {
	flash_reset_for_test()
	defer flash_reset_for_test()
	state.settings.reduce_motion = false
	t0 := time.tick_now()
	at :: proc(t0: time.Tick, ms: int) -> time.Tick {return time.tick_add(t0, time.Duration(ms) * time.Millisecond)}
	// at rest: stamp 0, first seen or not
	testing.expect_value(t, flash_at(1, 0, DUR_FLASH, t0), 0)
	// a new stamp: 1, then linearly down to 0 over the duration, then 0 for good
	testing.expect_value(t, flash_at(1, 7, DUR_FLASH, t0), 1)
	testing.expect_value(t, flash_at(1, 7, DUR_FLASH, at(t0, 300)), 0.5)
	r := flash_at(1, 7, DUR_FLASH, at(t0, 599))
	testing.expectf(t, r > 0 && r < 0.01, "near its end: %v", r)
	testing.expect_value(t, flash_at(1, 7, DUR_FLASH, at(t0, 600)), 0)
	testing.expect_value(t, flash_at(1, 7, DUR_FLASH, at(t0, 700)), 0)
	// the same stamp again (a repeat report): nothing
	testing.expect_value(t, flash_at(1, 7, DUR_FLASH, at(t0, 5000)), 0)
	// back to rest, then a new stamp: once more
	testing.expect_value(t, flash_at(1, 0, DUR_FLASH, at(t0, 6000)), 0)
	testing.expect_value(t, flash_at(1, 8, DUR_FLASH, at(t0, 7000)), 1)
	// a key first seen with a stamp starts (the caller decides what is news)
	testing.expect_value(t, flash_at(2, 3, DUR_FLASH, t0), 1)
	// Reduce motion: never, and turning it off later does not replay what changed meanwhile
	state.settings.reduce_motion = true
	testing.expect_value(t, flash_at(1, 9, DUR_FLASH, at(t0, 8000)), 0)
	testing.expect_value(t, flash_at(2, 3, DUR_FLASH, at(t0, 10)), 0) // a running one stops
	state.settings.reduce_motion = false
	testing.expect_value(t, flash_at(1, 9, DUR_FLASH, at(t0, 8001)), 0)
	testing.expect_value(t, flash_at(2, 3, DUR_FLASH, at(t0, 11)), 0)
	// the table stays bounded: past FLASHES_MAX the entries at rest go, a running one stays
	testing.expect_value(t, flash_at(3, 1, DUR_FLASH, t0), 1)
	for k in 10 ..< 10 + FLASHES_MAX + 10 do flash_at(u64(k), 0, DUR_FLASH, t0)
	testing.expect(t, len(flashes_for_test()) <= FLASHES_MAX, "bounded")
	testing.expect(t, flash_at(3, 1, DUR_FLASH, at(t0, 100)) > 0, "a running flash survives the prune")
}

@(test)
flash_pop_and_wash :: proc(t: ^testing.T) {
	// the pop: 1 at both ends, up to 1 + FLASH_POP early on, settled by FLASH_POP_PART
	testing.expect_value(t, flash_pop(0), 1)
	testing.expect_value(t, flash_pop(1), 1)
	testing.expect_value(t, flash_pop(1 - FLASH_POP_PART), 1)
	top: f32 = 0
	for i in 0 ..= 1000 {
		p := flash_pop(f32(i) / 1000)
		testing.expectf(t, p >= 1 && p <= 1 + FLASH_POP + 1e-4, "pop %v at %v", p, f32(i) / 1000)
		top = max(top, p)
	}
	testing.expectf(t, top > 1 + FLASH_POP - 0.01, "it pops to %v", top)
	// drawn larger, the marks' glyphs (2..14 of the 16 grid units) still stay inside their box
	testing.expect(t, (14.0 - 2.0) / 16.0 * (1 + FLASH_POP) <= 1, "the pop stays in the mark's box")
	// at rest the encoded scale is exactly 1, so the mark is drawn where it always was
	cmd: clay.RenderCommand
	cmd.boundingBox = {10, 20, 12, 12}
	cmd.renderData.custom.customData = rawptr(uintptr(core.Icon.Mark_Waiting))
	x, y, w, h := icon_draw_box(&cmd)
	testing.expect_value(t, [4]f32{x, y, w, h}, [4]f32{10, 20, 12, 12})
	grow := uintptr(FLASH_POP * ICON_GROW_STEPS) // 100: exactly 1.25
	cmd.renderData.custom.customData = rawptr(uintptr(core.Icon.Mark_Waiting) | grow << 16)
	x, y, w, h = icon_draw_box(&cmd)
	testing.expect_value(t, w, 15)
	testing.expect_value(t, x + w / 2, f32(16)) // about its centre
	testing.expect_value(t, y + h / 2, f32(26))

	// the wash: nothing at rest; at its peak, FLASH_ALPHA of the status colour; text stays readable
	// over it in every look (body and secondary text 4.5:1, the waiting row's own words 3:1)
	saved := state.settings.theme
	defer state.settings.theme = saved
	for look in core.Theme_Id do for light in ([]bool{false, true}) {
		th := light ? &THEMES_LIGHT[look] : &THEMES[look]
		state.settings.theme = look
		name := fmt.tprintf("%s %s", core.THEME_NAMES[look], light ? "light" : "dark")
		for dot in ([]core.Row_Status{.Waiting, .Question, .Unseen, .Error}) {
			col := dot == .Error ? th.error : dot == .Unseen ? th.accent : th.waiting
			// a row's or tab's own words: secondary at rest, full text when current or hovered (its
			// overlay under the wash); the waiting row's "Waiting for you" in the status colour
			for surface in ([]core.Rgba{th.bg_sidebar, th.bg_app, mix_over(th.selected, th.bg_sidebar), mix_over(th.hover, th.bg_sidebar)}) {
				bg := cc(surface)
				testing.expect_value(t, flash_wash(bg, dot, 0), bg)
				w := wash_of(surface, col, FLASH_ALPHA)
				over := surface != th.bg_sidebar && surface != th.bg_app
				for x in ([]struct {
					n: string,
					c: core.Rgba,
					min: f32,
				}{{"text", th.text, 4.5}, {"text_secondary", over ? th.text : th.text_secondary, 4.5}, {"its colour", dot == .Waiting ? col : th.text, 3}}) {
					r := core.contrast_ratio(x.c, w)
					testing.expectf(t, r >= x.min, "%s %v: %s over the wash %.2f:1, want >= %.1f", name, dot, x.n, r, x.min)
				}
				// muted words (a place, an age) keep 3/4 of their contrast at the peak (a moment: it eases out)
				before, after := core.contrast_ratio(th.text_muted, surface), core.contrast_ratio(th.text_muted, w)
				testing.expectf(t, after >= 0.75 * before, "%s %v: text_muted %.2f:1 -> %.2f:1 over the wash", name, dot, before, after)
			}
		}
	}
	// flash_wash itself, over an opaque surface: the same blend
	th := &THEMES[.Graphite]
	state.settings.theme = .Graphite
	got := flash_wash(cc(th.bg_sidebar), .Waiting, 1)
	want := wash_of(th.bg_sidebar, th.waiting, FLASH_ALPHA)
	for i in 0 ..< 3 do testing.expectf(t, abs(got[i] - f32(want[i])) <= 1, "channel %d: %v vs %v", i, got, want)
	testing.expect_value(t, got[3], 255)
}

// col at alpha a over the opaque surface bg.
@(private = "file")
wash_of :: proc(bg, col: core.Rgba, a: f32) -> core.Rgba {
	out := bg
	for i in 0 ..< 3 do out[i] = u8(f32(col[i]) * a + f32(bg[i]) * (1 - a) + 0.5)
	return out
}

// An overlay colour (with its alpha) over an opaque surface.
@(private = "file")
mix_over :: proc(over, bg: core.Rgba) -> core.Rgba {return wash_of(bg, {over.r, over.g, over.b, 255}, f32(over.a) / 255)}

@(test)
status_flash_rules :: proc(t: ^testing.T) {
	flash_reset_for_test()
	defer flash_reset_for_test()
	state.settings.reduce_motion = false
	host := clay.ElementId{id = 42}
	now := time.now()
	ago :: proc(now: time.Time, ms: int) -> time.Time {return time.time_add(now, -time.Duration(ms) * time.Millisecond)}
	flash_quiet(ago(now, 60_000)) // the link has been up a while
	V :: core.Tab_Status_View
	// waiting, finished not seen, an error, a question: a moment ago, they flash
	for dot, i in ([]core.Row_Status{.Waiting, .Unseen, .Error, .Question}) {
		testing.expectf(t, status_flash(host, u64(100 + i), V{dot = dot, since = ago(now, 100)}, now = now) == 1, "%v flashes", dot)
	}
	// working, idle, exited: never
	for dot, i in ([]core.Row_Status{.Running, .None, .Exited}) {
		testing.expectf(t, status_flash(host, u64(200 + i), V{dot = dot, since = ago(now, 100)}, now = now) == 0, "%v does not", dot)
	}
	// a repeat report keeps since: once it ended, it does not start again
	v := V{dot = .Waiting, since = ago(now, 100)}
	testing.expect_value(t, status_flash(host, 300, v, now = now), 1)
	flash_age_for_test(DUR_FLASH)
	testing.expect_value(t, status_flash(host, 300, v, now = time.time_add(now, 50 * time.Millisecond)), 0)
	// a new status (since moved): again
	v.dot, v.since = .Error, now
	testing.expect_value(t, status_flash(host, 300, v, now = now), 1)
	// one that began a while ago (a row that turned up later, another tab now the row's strongest)
	testing.expect_value(t, status_flash(host, 301, V{dot = .Waiting, since = ago(now, 3000)}, now = now), 0)
	// no since known: nothing
	testing.expect_value(t, status_flash(host, 302, V{dot = .Waiting}, now = now), 0)
	// the window's link just came up: what came with it stays still, what changes after flashes
	flash_quiet(now)
	testing.expect_value(t, status_flash(host, 303, V{dot = .Waiting, since = ago(now, 10)}, now = now), 0)
	later := time.time_add(now, FLASH_SETTLE + 500 * time.Millisecond)
	testing.expect_value(t, status_flash(host, 304, V{dot = .Waiting, since = ago(later, 100)}, now = later), 1)
	// another machine: first seen online, its rows settle first; offline, nothing; back online, settle again
	flash_quiet(ago(now, 60_000))
	testing.expect_value(t, status_flash(host, 305, V{dot = .Waiting, since = ago(now, 10)}, machine = 7, now = now), 0)
	t2 := time.time_add(now, 2 * FLASH_SETTLE)
	testing.expect_value(t, status_flash(host, 306, V{dot = .Waiting, since = ago(t2, 10)}, machine = 7, now = t2), 1)
	testing.expect_value(t, status_flash(host, 307, V{dot = .Waiting, since = ago(t2, 10)}, machine = 7, live = false, now = t2), 0)
	t3 := time.time_add(t2, 10 * time.Millisecond)
	testing.expect_value(t, status_flash(host, 308, V{dot = .Waiting, since = ago(t3, 5)}, machine = 7, now = t3), 0)
	// Reduce motion: nothing (the status still shows: only the motion is left out)
	state.settings.reduce_motion = true
	testing.expect_value(t, status_flash(host, 309, V{dot = .Waiting, since = ago(now, 10)}, now = now), 0)
	state.settings.reduce_motion = false
}

@(private = "file")
fl_reset :: proc() -> (sid, sh_tab: u64) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	p := core.Project{id = core.new_id(), group = .Projects, cwd = "/tmp/fl-proj", label = "fl-proj"}
	append(&state.projects, p)
	state.selected_project = p.id
	s := core.Open_Session{id = core.new_id(), project_id = p.id, pi_session_id = "pi-fl", cwd = "/tmp/fl-proj", title = "Flash the rows"}
	append(&state.sessions, core.Session{id = "pi-fl", path = "/tmp/fl-proj/s.jsonl", title = "Flash the rows"})
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running})
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "shell 1", status = .Running})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 300, .Sessions
	return s.id, s.tabs[1].id
}

@(private = "file")
fl_report :: proc(tab: u64, reps: ..core.Prog_Report) {
	r: core.Prog_Records
	defer core.prog_free(&r)
	for x in reps do core.prog_apply(&r, x)
	core.run_command(core.Program_Status{tab_id = tab, summary = core.prog_summary(&r)})
}

// The background of element name/i in the last layout ({} = none drawn).
@(private = "file")
bg_of :: proc(cmds: clay.ClayArray(clay.RenderCommand), name: string, i: u32) -> clay.Color {
	id := clay.ID(name, i).id
	for k in 0 ..< cmds.length {
		c := &cmds.internalArray[k]
		if c.commandType == .Rectangle && c.id == id do return c.renderData.rectangle.backgroundColor
	}
	return {}
}

// The largest drawn scale of a status mark in the last layout, and whether every mark keeps its box.
@(private = "file")
mark_pop :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> (top: f32, boxed: bool) {
	top, boxed = 1, true
	for k in 0 ..< cmds.length {
		c := &cmds.internalArray[k]
		if c.commandType != .Custom do continue
		ic, _, _ := icon_of_command(c)
		if ic < .Mark_Idle || ic > .Mark_Error do continue
		top = max(top, icon_scale_of_command(c))
		if c.boundingBox.width != px(MARK) || c.boundingBox.height != px(MARK) do boxed = false
	}
	return
}

// Drawn: a status that turns waiting washes its open row and its tab and pops its mark, asks for
// frames while that is seen and only then, and ends; nothing moves; repeat reports, working and
// Reduce motion do nothing.
@(test)
status_flash_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	_, sh_id := fl_reset()
	flash_reset_for_test()
	defer {
		core.platform = {}
		state^ = core.State{}
		state.settings.reduce_motion = false
		flash_reset_for_test()
	}
	state.settings.reduce_motion = false
	flash_quiet(time.time_add(time.now(), -time.Minute))
	cmds := ui_layout(1400, 900)
	row0, tab0 := bg_of(cmds, "open", 0), bg_of(cmds, "tab", 1)
	row_box, tab_box := clay.GetElementData(clay.ID("open", 0)).boundingBox, clay.GetElementData(clay.ID("tab", 1)).boundingBox
	testing.expect(t, !ui_flashing(), "idle: no flash")

	// it asks for permission: the row and the tab wash in the waiting colour, frames come
	fl_report(sh_id, {state = .Blocked, kind = .Permission, msg = "Apply these edits?"})
	cmds = ui_layout(1400, 900)
	testing.expect(t, ui_flashing(), "a flash on screen asks for frames")
	testing.expect(t, ui_wants_frame(), "the next frame is wanted")
	row1, tab1 := bg_of(cmds, "open", 0), bg_of(cmds, "tab", 1)
	testing.expectf(t, row1 != row0 && row1[3] > row0[3], "the row washes: %v -> %v", row0, row1)
	testing.expectf(t, tab1 != tab0 && tab1[3] > tab0[3], "the tab washes: %v -> %v", tab0, tab1)
	// a little later the mark is popped, drawn larger inside its unchanged box; nothing moved
	flash_age_for_test(DUR_FLASH / 8)
	cmds = ui_layout(1400, 900)
	top, boxed := mark_pop(cmds)
	testing.expectf(t, top > 1.2 && top <= 1 + FLASH_POP + 0.01, "the mark pops: %v", top)
	testing.expect(t, boxed, "every mark keeps its MARK box")
	testing.expect_value(t, clay.GetElementData(clay.ID("open", 0)).boundingBox, row_box)
	testing.expect_value(t, clay.GetElementData(clay.ID("tab", 1)).boundingBox, tab_box)
	// it ends: back to its background, the mark at rest, no frames
	flash_age_for_test(DUR_FLASH)
	cmds = ui_layout(1400, 900)
	testing.expect(t, !ui_flashing(), "it ended")
	testing.expect_value(t, bg_of(cmds, "open", 0), row0)
	top, _ = mark_pop(cmds)
	testing.expect_value(t, top, 1)
	// a repeat report (a new message): no flash
	fl_report(sh_id, {state = .Blocked, kind = .Permission, msg = "Apply these other edits?"})
	_ = ui_layout(1400, 900)
	testing.expect(t, !ui_flashing(), "a repeat report does not flash")
	// working: no flash; then an error: a flash
	fl_report(sh_id, {state = .Working, progress = -1})
	_ = ui_layout(1400, 900)
	testing.expect(t, !ui_flashing(), "working does not flash")
	fl_report(sh_id, {state = .Error, msg = "failed"})
	_ = ui_layout(1400, 900)
	testing.expect(t, ui_flashing(), "an error flashes")
	flash_age_for_test(DUR_FLASH)
	_ = ui_layout(1400, 900)
	// Reduce motion: the status changes, nothing moves, no frames
	state.settings.reduce_motion = true
	fl_report(sh_id, {state = .Blocked, kind = .Question, msg = "Which branch?"})
	cmds = ui_layout(1400, 900)
	testing.expect(t, !ui_flashing(), "Reduce motion: no flash")
	top, _ = mark_pop(cmds)
	testing.expect_value(t, top, 1)
	state.settings.reduce_motion = false

	// another session in front: the flashing one's row is below, then out of sight: no frames
	other := core.Open_Session{id = core.new_id(), project_id = state.selected_project, pi_session_id = "pi-fl-other", cwd = "/tmp/fl-proj"}
	append(&other.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running})
	other.active_tab = other.tabs[0].id
	append(&state.open_sessions, other)
	state.current_session = other.id
	fl_report(sh_id, {state = .Error, msg = "failed again"})
	_ = ui_layout(1400, 900)
	testing.expect(t, ui_flashing(), "its row on screen flashes")
	_ = ui_layout(1400, 60)
	testing.expect(t, !ui_flashing(), "its row out of sight: no frames")
}

// The copy shine: a band that is nowhere at its start and end, at most SHINE_ALPHA, and over in
// DUR_SHINE (its flash ends; no frames after).
@(test)
copy_shine_ends :: proc(t: ^testing.T) {
	flash_reset_for_test()
	defer flash_reset_for_test()
	state.settings.reduce_motion = false
	for i in 0 ..= 100 {
		u := f32(i) / 100
		testing.expect_value(t, shine_alpha(u, 0), 0)
		testing.expect_value(t, shine_alpha(u, 1), 0)
		for k in 1 ..< 20 {
			a := shine_alpha(u, f32(k) / 20)
			testing.expectf(t, a >= 0 && a <= SHINE_ALPHA, "alpha %v at u %v", a, u)
		}
	}
	// it sweeps: the left edge lights before the right one
	testing.expect(t, shine_alpha(0, 0.25) > shine_alpha(1, 0.25), "left first")
	testing.expect(t, shine_alpha(1, 0.75) > shine_alpha(0, 0.75), "right last")
	// one copy, one shine, then rest
	t0 := time.tick_now()
	key := u64(5) ~ SALT_SHINE
	testing.expect_value(t, flash_at(key, 0, DUR_SHINE, t0), 0)
	testing.expect_value(t, flash_at(key, 1, DUR_SHINE, t0), 1)
	testing.expect_value(t, flash_at(key, 1, DUR_SHINE, time.tick_add(t0, DUR_SHINE)), 0)
	testing.expect_value(t, flash_at(key, 1, DUR_SHINE, time.tick_add(t0, 10 * DUR_SHINE)), 0)
	// Reduce motion: none
	state.settings.reduce_motion = true
	testing.expect_value(t, flash_at(key, 2, DUR_SHINE, t0), 0)
	state.settings.reduce_motion = false
	// a copy marks its view (term_view_copied): the next draw's stamp
	v := new(Term_View, runtime.heap_allocator())
	defer free(v, runtime.heap_allocator())
	v.tab_id = 99
	term_views[99] = v
	defer delete_key(&term_views, 99)
	term_view_copied(99)
	testing.expect_value(t, v.copies, 1)
	testing.expect(t, v.changed, "drawn")
	term_view_copied(12345) // no such view: nothing
}

// Actions whose outcome nothing on screen shows say it in a toast; their wording follows the toggle.
@(test)
action_done_toasts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	fl_reset()
	defer {
		core.inbox_drain()
		toast_clear()
		core.platform = {}
		state^ = core.State{}
	}
	run := proc(id: string) -> string {
		toast_clear()
		run_action(action_by_id(id))
		core.inbox_drain()
		return toast.text
	}
	testing.expect_value(t, run("reduce_motion"), "Reduce motion on")
	testing.expect(t, state.settings.reduce_motion, "it ran")
	testing.expect_value(t, run("reduce_motion"), "Reduce motion off")
	testing.expect_value(t, run("bell_finished"), "Finished alerts off")
	testing.expect_value(t, run("bell_finished"), "Finished alerts on")
	testing.expect_value(t, run("pin_session"), "Pinned")
	testing.expect(t, core.session_pinned("pi-fl") >= 0, "pinned")
	testing.expect_value(t, run("unpin_session"), "Unpinned")
	testing.expect_value(t, run("pin_project"), "Pinned")
	testing.expect_value(t, run("unpin_project"), "Unpinned")
	// an action that shows itself has no toast of its own
	testing.expect_value(t, run("toggle_left"), "")
}
