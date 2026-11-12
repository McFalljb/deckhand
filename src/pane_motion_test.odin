package main

// Panes with presence (ui_pane_motion.odin, core/panes.odin's zoom, panes_commands.odin
// zoom_pane): the zoom's state and who may set it, the layout while zoomed (the zoomed pane fills
// the area; the others are neither laid out nor hit, and their terminals keep their sizes), the
// strip's marker and the menus, the dim overlay, the focus line's glide, the zoom's outline, the
// frames they ask for and Reduce motion. Same rules as panes_test.odin (shared State, one thread).

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

// ---- the core: state, clearing, authority ----

@(test)
pane_zoom_states :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	s := x.s
	// toggle the focused pane (B): zoomed, again: back
	r := core.run_command(core.Zoom_Pane{}, PT_UI)
	testing.expectf(t, r.ok, "zoom: %s", r.error)
	testing.expect_value(t, core.session_zoomed(s), x.b)
	testing.expect(t, core.pane_zoom_hidden(s, x.a) && !core.pane_zoom_hidden(s, x.b), "A hidden, B not")
	// A's shown tab is not on screen while hidden (not seen, not drawn); B's is
	testing.expect(t, !core.session_tab_shown(s, x.shell) && core.session_tab_shown(s, x.browser), "on screen: B's only")
	testing.expect(t, strings.contains(core.state_json(), fmt.tprintf(`"zoomed_pane":%d`, x.b)), "get_state says which")
	testing.expect(t, core.run_command(core.Zoom_Pane{}, PT_UI).ok, "toggle back")
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect(t, core.session_tab_shown(s, x.shell), "A's tab on screen again")
	testing.expect(t, !strings.contains(core.state_json(), `"zoomed_pane"`), "none: not in get_state")
	// another pane by id: it gets the keyboard too
	testing.expect(t, core.run_command(core.Zoom_Pane{pane = x.a}, PT_UI).ok, "zoom A")
	testing.expect_value(t, core.session_zoomed(s), x.a)
	testing.expect_value(t, s.focused_pane, x.a)
	testing.expect_value(t, s.active_tab, x.shell)
	// another pane while one is zoomed: that one instead
	testing.expect(t, core.run_command(core.Zoom_Pane{pane = x.b, zoom = true}, PT_UI).ok, "zoom B over A")
	testing.expect_value(t, core.session_zoomed(s), x.b)
	testing.expect_value(t, s.focused_pane, x.b)
	// zoom true on the zoomed one, and false twice: nothing more
	testing.expect(t, core.run_command(core.Zoom_Pane{pane = x.b, zoom = true}, PT_UI).ok, "again")
	testing.expect_value(t, core.session_zoomed(s), x.b)
	testing.expect(t, core.run_command(core.Zoom_Pane{zoom = false}, PT_UI).ok, "restore")
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect(t, core.run_command(core.Zoom_Pane{zoom = false}, PT_UI).ok, "restore when not zoomed: fine")
	testing.expect_value(t, s.focused_pane, x.b) // the keyboard stays where it was

	// focus moving to another pane by a command ends it; on the zoomed pane itself it stays
	core.run_command(core.Zoom_Pane{}, PT_UI)
	core.run_command(core.Focus_Pane{pane = x.b}, PT_UI)
	testing.expect_value(t, core.session_zoomed(s), x.b)
	core.run_command(core.Focus_Pane{direction = "left"}, PT_UI)
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect_value(t, s.focused_pane, x.a)
	// a hidden pane's tab picked (the palette, the left column): its pane gets the keyboard, the layout comes back
	core.run_command(core.Zoom_Pane{}, PT_UI) // A zoomed
	core.run_command(core.Focus_Tab{tab_id = x.editor}, PT_UI)
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect_value(t, s.focused_pane, x.b)
	// another tab of the zoomed pane: it stays zoomed
	core.run_command(core.Zoom_Pane{}, PT_UI) // B zoomed
	core.run_command(core.Focus_Tab{tab_id = x.app_id}, PT_UI)
	testing.expect_value(t, core.session_zoomed(s), x.b)
	// the focused tab moved to the other pane (the keyboard follows it): back
	core.run_command(core.Move_Tab{tab_id = x.app_id, pane = x.a, index = -1}, PT_UI)
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	core.run_command(core.Move_Tab{tab_id = x.app_id, pane = x.b, index = -1}, PT_UI)

	// a split while zoomed: the new pane is seen (and the tree stays whole: after_command_check)
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	r = core.run_command(core.Split_Pane{pane = x.b, direction = .Down, tab_id = x.app_id}, PT_UI)
	testing.expectf(t, r.ok, "split: %s", r.error)
	c := r.created_id
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect_value(t, len(s.panes), 3)
	// a hidden pane closed while one is zoomed: back
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	testing.expect(t, core.run_command(core.Close_Pane{pane = c}, PT_UI).ok, "close C")
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	// the zoomed pane closed: back, the tree whole, one pane left
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	testing.expect(t, core.run_command(core.Close_Pane{pane = x.b}, PT_UI).ok, "close B")
	testing.expect_value(t, len(s.panes), 1)
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect_value(t, s.zoomed_pane, u64(0))
	// the last pane: nothing to zoom
	testing.expect_value(t, core.run_command(core.Zoom_Pane{}, PT_UI).error, "one pane: nothing to zoom")
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	// a stale id (set by hand) never counts as a zoom
	s.zoomed_pane = 12345
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	s.zoomed_pane = 0
}

// The zoomed pane's last tab closing (its pane collapses) ends the zoom; so does a tab dragged out
// of it into a hidden pane, leaving it empty.
@(test)
pane_zoom_pane_goes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	s := x.s
	r := core.run_command(core.Split_Pane{pane = x.a, direction = .Down, tab_id = x.shell}, PT_UI)
	c := r.created_id
	core.run_command(core.Zoom_Pane{pane = c}, PT_UI)
	testing.expect_value(t, core.session_zoomed(s), c)
	delete_key(&core.terms, x.shell) // closes without a terminal
	rc := core.run_command(core.Close_Tab{tab_id = x.shell, confirm = "", comments = .Drop}, PT_UI)
	testing.expectf(t, rc.ok, "close: %s", rc.error)
	testing.expect(t, core.session_pane(s, c) == nil, "C collapsed")
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	testing.expect_value(t, s.zoomed_pane, u64(0))
	core.terms[x.shell] = x.term // pt_two_done's
	// B zoomed, its tabs dragged into A one by one: B goes, the zoom too
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	for id in ([]u64{x.editor, x.browser, x.app_id}) do core.run_command(core.Move_Tab{tab_id = id, pane = x.a, index = -1}, PT_UI)
	testing.expect_value(t, len(s.panes), 1)
	testing.expect_value(t, s.zoomed_pane, u64(0))
	testing.expect(t, core.session_check(s) == "", core.session_check(s))
}

// zoom_pane has its neighbours' authority (the command table's Anyone, as focus_pane): the user,
// scripts and control callers; never a pi or Claude tab nor an app. Home is refused.
@(test)
pane_zoom_authority :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	testing.expect_value(t, core.command_spec("zoom_pane").who, core.command_spec("focus_pane").who)
	testing.expect_value(t, core.command_spec("set_dim_panes").who, core.command_spec("set_reduce_motion").who)
	not :: "not allowed for this caller"
	testing.expect_value(t, core.run_command(core.Zoom_Pane{pane = x.a}, {kind = .Panel, tab_id = x.pi}).error, not)
	testing.expect_value(t, core.run_command(core.Zoom_Pane{pane = x.a}, {kind = .Panel, tab_id = x.pi, claude = true}).error, not)
	testing.expect_value(t, core.run_command(core.Zoom_Pane{pane = x.a}, {kind = .App, tab_id = x.app_id}).error, not)
	testing.expect_value(t, core.session_zoomed(x.s), u64(0))
	r := core.run_command(core.Zoom_Pane{pane = x.a}, core.Caller{kind = .Control})
	testing.expectf(t, r.ok, "control: %s", r.error)
	testing.expect_value(t, core.session_zoomed(x.s), x.a)
	testing.expect_value(t, core.run_command(core.Zoom_Pane{pane = 999}, PT_UI).error, "no such pane")
	// the wire: pane and zoom optional
	for c in ([]struct {
		text: string,
		want: core.Zoom_Pane,
	}{{`{"type":"zoom_pane"}`, {}}, {`{"type":"zoom_pane","pane":5,"zoom":false}`, {pane = 5, zoom = false}}, {`{"type":"zoom_pane","zoom":true}`, {zoom = true}}}) {
		cmd, err := core.parse_command(c.text, context.temp_allocator)
		testing.expectf(t, err == "", "%s: %s", c.text, err)
		z, is := cmd.(core.Zoom_Pane)
		testing.expectf(t, is && z.pane == c.want.pane && maybe_bool(z.zoom) == maybe_bool(c.want.zoom), "%s: %v", c.text, cmd)
	}
	// Home: one pane, refused
	hs := core.Open_Session{id = core.new_id(), home = true, cwd = "/tmp/pt"}
	append(&hs.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "agent", status = .Not_Started})
	hs.active_tab = hs.tabs[0].id
	core.session_panes_init(&hs)
	hp := hs.panes[0].id
	append(&state.open_sessions, hs)
	x.s = &state.open_sessions[0]
	testing.expect_value(t, core.run_command(core.Zoom_Pane{pane = hp}, PT_UI).error, core.HOME_NOT_A_SESSION)
}

@(private = "file")
maybe_bool :: proc(m: Maybe(bool)) -> int {
	v, ok := m.?
	return ok ? (v ? 1 : 0) : -1
}

// ---- the window ----

// Two panes laid out, B zoomed: B's pane fills the panes' area, A is not laid out (no strip, no
// rect: never hit; a point where A was is B's), A's terminals keep their size while B's grows;
// B's strip says "⤢ 2 of 2", which is a button that restores. Restored: the same rects and sizes
// as before.
@(test)
pane_zoom_layout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[2].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	a := s.tabs[0].pane
	for &tab in s.tabs do tab.has_term = true // sized like terminals (no process: term_fits only)
	ta, tb := s.tabs[1].id, s.tabs[2].id // A's shell (hidden behind the pi tab) and B's
	clear(&term_fits)
	defer clear(&term_fits)
	lay :: proc(s: ^core.Open_Session) {
		_ = ui_layout(1400, 860)
		ui_pane_rects(s)
		panes_fit_terms()
	}
	lay(s)
	pa, pb := core.session_pane(s, a), core.session_pane(s, b)
	a_frame, b_frame := pa.frame, pb.frame
	a_fit, b_fit := term_fits[ta], term_fits[tb]
	testing.expect(t, a_fit.cols > 0 && b_fit.cols > 0, "both sized")

	testing.expect(t, core.run_command(core.Zoom_Pane{}, PT_UI).ok, "zoom B")
	lay(s)
	pa, pb = core.session_pane(s, a), core.session_pane(s, b)
	testing.expect_value(t, pb.frame, app.centre)
	testing.expect_value(t, pa.frame, [4]f32{})
	testing.expect_value(t, pa.rect, [4]f32{})
	testing.expect(t, !clay.GetElementData(pid(pa, "pane_strip")).found, "A's strip not laid out")
	testing.expect(t, clay.GetElementData(pid(pb, "pane_strip")).found, "B keeps its strip")
	mid := [2]f32{a_frame.x + a_frame.z / 2, a_frame.y + a_frame.w / 2}
	testing.expect(t, pane_at(mid.x, mid.y) == pb, "where A was is B's")
	// A's terminals keep their grid; B's takes the whole area once
	testing.expect_value(t, term_fits[ta].rect, a_fit.rect)
	testing.expect_value(t, term_fits[ta].cols, a_fit.cols)
	testing.expect(t, term_fits[tb].cols > b_fit.cols && term_fits[tb].rect.x < b_fit.rect.x, "B's terminal fills the area")
	testing.expect_value(t, pane_width(), pb.frame.z) // its bars' width: the area's (ids_pane: focused B)
	// the marker: which of how many, a button that restores
	testing.expect_value(t, pane_zoom_label(s, pb), "⤢ 2 of 2")
	zd := clay.GetElementData(pid(pb, "pane_zoom"))
	if !testing.expect(t, zd.found, "the marker") do return
	sd := clay.GetElementData(pid(pb, "pane_strip")).boundingBox
	testing.expectf(t, zd.boundingBox.x + zd.boundingBox.width <= sd.x + sd.width + 0.5 && zd.boundingBox.y >= sd.y, "inside the strip: %v %v", zd.boundingBox, sd)
	app.pointer = {zd.boundingBox.x + zd.boundingBox.width / 2, zd.boundingBox.y + zd.boundingBox.height / 2}
	clay.SetPointerState(app.pointer, false)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, ui_hit(), Hit(Hit_Pane_Zoom(b)))
	label, keys := hit_tip(Hit_Pane_Zoom(b))
	testing.expect_value(t, label, "Restore panes")
	testing.expect_value(t, keys, "⇧⌘↩")
	app.pointer = {}
	clay.SetPointerState(app.pointer, false)
	pane_zoom_click(Hit_Pane_Zoom(b))
	core.inbox_drain()
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	lay(s)
	pa, pb = core.session_pane(s, a), core.session_pane(s, b)
	testing.expect_value(t, pa.frame, a_frame)
	testing.expect_value(t, pb.frame, b_frame)
	testing.expect_value(t, term_fits[tb].rect, b_fit.rect)
	testing.expect_value(t, term_fits[tb].cols, b_fit.cols)
	testing.expect(t, !clay.GetElementData(pid(pb, "pane_zoom")).found, "no marker at rest")
}

// ⇧⌘↩, the menu bar, the palette and the pane's "+" menu: one action, titled by the state.
@(test)
pane_zoom_action_and_menus :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	s := pt_one(1)
	testing.expect(t, !action_ok("zoom_pane"), "one pane: no zoom")
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[1].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	a := action_by_id("zoom_pane")
	testing.expect_value(t, action_label(a), "Zoom pane")
	k, ok := parse_keys(a.keys)
	testing.expect(t, ok && k.code == .ENTER && k.mods == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT && k.equiv == "\r", "⇧⌘↩ is Return with Shift and Command")
	testing.expect_value(t, menubar_key_action(.ENTER, sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT), "zoom_pane")
	// the key (never with a text field focused: main.odin; ⌘↩ alone is not it)
	plain := sapp.Event{type = .KEY_DOWN, key_code = .ENTER, modifiers = sapp.MODIFIER_SUPER}
	testing.expect(t, !pane_key(&plain), "⌘↩ is not taken")
	ev := sapp.Event{type = .KEY_DOWN, key_code = .ENTER, modifiers = sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT}
	testing.expect(t, pane_key(&ev), "⇧⌘↩ taken")
	core.inbox_drain()
	testing.expect_value(t, core.session_zoomed(s), b)
	testing.expect_value(t, action_label(a), "Restore panes")
	// the pane's "+" menu ends with it
	menu_open(Menu_New{pane = b}, {10, 10})
	items := menu_items()
	testing.expect(t, len(items) > 0 && items[len(items) - 1].label == "Restore panes" && items[len(items) - 1].keys == "⇧⌘↩", "the + menu's last row")
	menu_close()
	testing.expect(t, pane_key(&ev), "again")
	core.inbox_drain()
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	menu_open(Menu_New{pane = b}, {10, 10})
	items = menu_items()
	testing.expect(t, len(items) > 0 && items[len(items) - 1].label == "Zoom pane", "Zoom pane at rest")
	menu_close()
	testing.expect(t, menubar_find_action("zoom_pane"), "in the menu bar")
	testing.expect(t, menubar_find_action("dim_panes"), "Dim inactive panes in the menu bar")
}

@(private = "file")
menubar_find_action :: proc(id: string) -> bool {
	for it in menubar_items() do if it.action == id do return true
	return false
}

// The dim: an overlay on every pane but the focused one, only when split and the setting is on,
// at the look's PANE_DIM once settled, below the strip; Reduce motion keeps it (no fade). Text
// stays readable under it in every look.
@(test)
pane_dim_overlay :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	saved_rm := state.settings.reduce_motion
	defer state.settings.reduce_motion = saved_rm
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.dims_n, 0) // one pane: none
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[2].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	a := s.tabs[0].pane
	_ = ui_layout(1400, 860)
	// A seen for the first time: at its target at once (no fade in from nothing)
	if !testing.expect_value(t, pane_motion.dims_n, 1) do return
	d := pane_motion.dims[0]
	testing.expect_value(t, d.pane, a)
	testing.expect_value(t, d.alpha, pane_dim_alpha())
	pa := core.session_pane(s, a)
	strip := clay.GetElementData(pid(pa, "pane_strip")).boundingBox
	frame := clay.GetElementData(pid(pa, "pane")).boundingBox
	testing.expect_value(t, d.rect, [4]f32{frame.x, strip.y + strip.height, frame.width, frame.y + frame.height - strip.y - strip.height})
	// the focus moves to A: A fades out, B fades in; under Reduce motion at once
	state.settings.reduce_motion = true
	core.run_command(core.Focus_Pane{pane = a}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.dims_n, 1)
	testing.expect_value(t, pane_motion.dims[0].pane, b)
	testing.expect_value(t, pane_motion.dims[0].alpha, pane_dim_alpha())
	testing.expect(t, !ui_wants_frame(), "no frames under Reduce motion")
	// with motion: mid-fade the next frame is asked for; it ends
	state.settings.reduce_motion = false
	core.run_command(core.Focus_Pane{pane = b}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect(t, ui_wants_frame(), "fading: frames")
	for i in 0 ..< 200 {
		if !ui_wants_frame() do break
		time.sleep(2 * time.Millisecond)
		_ = ui_layout(1400, 860)
	}
	_ = ui_layout(1400, 860)
	testing.expect(t, !ui_wants_frame(), "the fade ends: no more frames")
	testing.expect_value(t, pane_motion.dims_n, 1)
	testing.expect_value(t, pane_motion.dims[0].pane, a)
	testing.expect_value(t, pane_motion.dims[0].alpha, pane_dim_alpha())
	// zoomed: nothing dimmed (the hidden pane is not drawn)
	core.run_command(core.Zoom_Pane{}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.dims_n, 0)
	core.run_command(core.Zoom_Pane{zoom = false}, PT_UI)
	// the setting off: none, once its fade is done (Reduce motion: at once)
	state.settings.reduce_motion = true
	testing.expect(t, core.run_command(core.Set_Dim_Panes{on = false}, PT_UI).ok)
	testing.expect(t, state.settings.dim_panes_off)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.dims_n, 0)
	testing.expect(t, core.run_command(core.Set_Dim_Panes{on = true}, PT_UI).ok)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.dims_n, 1)
	// readable under it: body and terminal text 7:1, secondary 4.5:1, muted 3:1, every look
	for look in core.Theme_Id do for light in ([]bool{false, true}) {
		th := light ? &THEMES_LIGHT[look] : &THEMES[look]
		tc := core.term_colors_of(look, light)
		k := light ? PANE_DIM_LIGHT[look] : PANE_DIM[look]
		testing.expectf(t, k > 0 && k <= 0.12 && (!light || k < PANE_DIM[look]), "%v %v: %v", look, light, k)
		name := fmt.tprintf("%s %s", core.THEME_NAMES[look], light ? "light" : "dark")
		for c in ([]struct {
			n:      string,
			fg, bg: core.Rgba,
			min:    f32,
		}{{"text", th.text, th.bg_app, 7}, {"text_secondary", th.text_secondary, th.bg_app, 4.5}, {"text_muted", th.text_muted, th.bg_app, 3}, {"terminal text", tc.fg, tc.bg, 7}}) {
			dim_fg, dim_bg := mix(c.fg, th.bg_app, k), mix(c.bg, th.bg_app, k)
			cr := core.contrast_ratio(dim_fg, dim_bg)
			testing.expectf(t, cr >= c.min, "%s: %s under the dim %.2f:1, want >= %.1f", name, c.n, cr, c.min)
		}
	}
}

// The focus line: at rest exactly the focused strip's bottom border; when the focus moves between
// two strips on screen it glides there over DUR_GLIDE (ease-out: from the old strip's line, past
// halfway at half time, at the new one at the end), asking for frames until it arrives; under
// Reduce motion, after a session switch or from a strip no longer on screen it is just there.
@(test)
pane_focus_glide :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	saved_rm := state.settings.reduce_motion
	defer state.settings.reduce_motion = saved_rm
	state.settings.reduce_motion = false
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[2].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	a := s.tabs[0].pane
	_ = ui_layout(1400, 860) // its first layout (the layout runs pane_motion_layout): B's line, at rest
	line_b := pane_focus_line(s, b)
	line_a := pane_focus_line(s, a)
	testing.expect(t, line_a.z > 0 && line_b.z > 0 && line_a.x < line_b.x, "two strips")
	testing.expect_value(t, pane_motion.bar, line_b)
	testing.expect(t, !pane_motion.moving, "at rest")
	sd := clay.GetElementData(pid(core.session_pane(s, b), "pane_strip")).boundingBox
	testing.expect_value(t, line_b, [4]f32{sd.x, sd.y + sd.height - f32(pu(core.BORDER_W)), sd.width, f32(pu(core.BORDER_W))})
	// to A: starts at B's line, glides, ends on A's (times from when the layout started it)
	core.run_command(core.Focus_Pane{pane = a}, PT_UI)
	_ = ui_layout(1400, 860)
	now := pane_motion.bar_t0
	if !testing.expect(t, now != {}, "a glide started") do return
	pane_motion_layout(s, now)
	testing.expect_value(t, pane_motion.bar, line_b)
	testing.expect(t, pane_motion.moving && ui_wants_frame(), "moving: frames")
	half := time.tick_add(now, DUR_GLIDE / 2)
	pane_motion_layout(s, half)
	mid := pane_motion.bar
	testing.expectf(t, mid.x < line_b.x && mid.x > line_a.x && (line_b.x - mid.x) > (line_b.x - line_a.x) / 2, "past halfway at half time (ease-out): %v", mid)
	pane_motion_layout(s, time.tick_add(now, DUR_GLIDE))
	testing.expect_value(t, pane_motion.bar, line_a)
	testing.expect(t, !pane_motion.moving, "arrived: no frames for it")
	// redirected mid-glide: from where it is drawn
	core.run_command(core.Focus_Pane{pane = b}, PT_UI)
	_ = ui_layout(1400, 860)
	t1 := pane_motion.bar_t0
	pane_motion_layout(s, time.tick_add(t1, DUR_GLIDE / 4))
	quarter := pane_motion.bar
	testing.expectf(t, quarter.x > line_a.x && quarter.x < line_b.x, "a quarter of the way: %v", quarter)
	core.run_command(core.Focus_Pane{pane = a}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.bar_from, quarter)
	testing.expect_value(t, pane_motion.bar, quarter)
	pane_motion_layout(s, time.tick_add(pane_motion.bar_t0, DUR_GLIDE))
	testing.expect_value(t, pane_motion.bar, line_a)
	// Reduce motion: there at once, no frames
	state.settings.reduce_motion = true
	core.run_command(core.Focus_Pane{pane = b}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.bar, line_b)
	testing.expect(t, !pane_motion.moving && !ui_wants_frame(), "Reduce motion: still")
	state.settings.reduce_motion = false
	// a zoom (A's strip goes): no glide, the line is under the zoomed strip
	core.run_command(core.Focus_Pane{pane = a}, PT_UI)
	core.run_command(core.Zoom_Pane{pane = b}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect(t, !pane_motion.moving, "no glide from a strip that went")
	testing.expect_value(t, pane_motion.bar, pane_focus_line(s, b))
	core.run_command(core.Zoom_Pane{zoom = false}, PT_UI)
	// one pane: no line
	core.run_command(core.Close_Pane{pane = b}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect_value(t, pane_motion.bar, [4]f32{})
}

// A zoom's outline: from the pane's rect before to the area (and back on restore) over DUR_ZOOM,
// fading out; frames only while it shows; none under Reduce motion or when another session is
// shown zoomed.
@(test)
pane_zoom_outline :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	saved_rm := state.settings.reduce_motion
	defer state.settings.reduce_motion = saved_rm
	state.settings.reduce_motion = false
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[2].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	_ = ui_layout(1400, 860)
	ui_pane_rects(s)
	before := core.session_pane(s, b).frame
	area := app.centre
	testing.expect(t, before.z > 0 && before.z < area.z, "B is half")
	core.run_command(core.Zoom_Pane{}, PT_UI)
	_ = ui_layout(1400, 860) // B's frame is still last layout's (ui_pane_rects comes after)
	now := pane_motion.ghost_t0
	if !testing.expect(t, now != {}, "an outline started") do return
	testing.expect_value(t, pane_motion.ghost_to, area)
	pane_motion_layout(s, now)
	testing.expect_value(t, pane_motion.ghost, before)
	testing.expect_value(t, pane_motion.ghost_alpha, f32(ZOOM_GHOST_ALPHA))
	testing.expect(t, ui_wants_frame(), "frames while it shows")
	ui_pane_rects(s)
	pane_motion_layout(s, time.tick_add(now, DUR_ZOOM / 2))
	g := pane_motion.ghost
	testing.expectf(t, g.x < before.x && g.z > before.z && pane_motion.ghost_alpha > 0 && pane_motion.ghost_alpha < ZOOM_GHOST_ALPHA / 2, "on its way, fading: %v %v", g, pane_motion.ghost_alpha)
	pane_motion_layout(s, time.tick_add(now, DUR_ZOOM))
	testing.expect_value(t, pane_motion.ghost_alpha, f32(0))
	testing.expect(t, !pane_motion.moving, "ended")
	// restore: from the area back to B's rect
	core.run_command(core.Zoom_Pane{}, PT_UI)
	_ = ui_layout(1400, 860)
	t1 := pane_motion.ghost_t0
	testing.expect_value(t, pane_motion.ghost_from, area)
	testing.expect_value(t, pane_motion.ghost_to, before)
	pane_motion_layout(s, t1)
	testing.expect_value(t, pane_motion.ghost, area)
	pane_motion_layout(s, time.tick_add(t1, DUR_ZOOM - time.Millisecond))
	testing.expectf(t, abs(pane_motion.ghost.x - before.x) < 1 && abs(pane_motion.ghost.z - before.z) < 1, "near B's rect: %v", pane_motion.ghost)
	pane_motion_layout(s, time.tick_add(t1, DUR_ZOOM))
	testing.expect(t, pane_motion.ghost_alpha == 0 && !pane_motion.moving, "ended")
	ui_pane_rects(s)
	// Reduce motion: none
	state.settings.reduce_motion = true
	core.run_command(core.Zoom_Pane{}, PT_UI)
	_ = ui_layout(1400, 860)
	testing.expect(t, pane_motion.ghost_alpha == 0 && !pane_motion.moving && !ui_wants_frame(), "Reduce motion: no outline")
	state.settings.reduce_motion = false
	ui_pane_rects(s)
	// another session shown, then this one again, zoomed: as it is (no outline)
	sid := s.id
	state.current_session = 0
	_ = ui_layout(1400, 860)
	state.current_session = sid
	_ = ui_layout(1400, 860)
	testing.expect(t, pane_motion.ghost_alpha == 0 && pane_motion.ghost_t0 == {}, "shown as it is")
	core.run_command(core.Zoom_Pane{zoom = false}, PT_UI)
}

// Layout audit while zoomed: at small window sizes the zoomed pane's strip keeps its marker and
// "+" inside it, and nothing of the hidden pane is laid out.
@(test)
pane_zoom_small_windows :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	s := pt_one(3)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[3].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	core.run_command(core.Zoom_Pane{pane = b}, PT_UI)
	for size in ([][2]f32{{1400, 860}, {1000, 700}, {800, 600}, {640, 480}}) {
		_ = ui_layout(size.x, size.y)
		ui_pane_rects(s)
		pb := core.session_pane(s, b)
		testing.expectf(t, pb.frame == app.centre, "%v: B fills the area: %v vs %v", size, pb.frame, app.centre)
		strip := clay.GetElementData(pid(pb, "pane_strip")).boundingBox
		for name in ([]string{"pane_new", "pane_zoom"}) {
			d := clay.GetElementData(pid(pb, name))
			testing.expectf(t, d.found, "%v: %s laid out", size, name)
			bb := d.boundingBox
			testing.expectf(t, bb.x >= strip.x - 0.5 && bb.x + bb.width <= strip.x + strip.width + 0.5, "%v: %s inside the strip: %v in %v", size, name, bb, strip)
		}
		pa := core.session_pane(s, s.tabs[0].pane)
		testing.expectf(t, pa.frame == {} && !clay.GetElementData(pid(pa, "pane")).found, "%v: A not laid out", size)
	}
	core.run_command(core.Zoom_Pane{zoom = false}, PT_UI)
}

// ---- review fixes (#100) ----

// A split restored in a window narrowed while zoomed is laid out clamped at once: the small side
// keeps its minimum on the first layout, and its terminal is sized once (the next layout agrees).
@(test)
pane_zoom_restore_clamped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, pt_ui(), "fonts") do return
	defer centre_reset()
	defer clear(&term_fits)
	s := pt_one(2)
	state.layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true}
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = s.tabs[2].id}, PT_UI)
	if !testing.expectf(t, r.ok, "split: %s", r.error) do return
	b := r.created_id
	for &tab in s.tabs do tab.has_term = true
	lay :: proc(s: ^core.Open_Session, w: f32) {
		_ = ui_layout(w, 860)
		ui_pane_rects(s)
		panes_fit_terms()
	}
	lay(s, 1400)
	testing.expect(t, core.run_command(core.Set_Split{split = s.nodes[s.root].id, ratio = 0.8}, PT_UI).ok)
	lay(s, 1400)
	lay(s, 1400)
	testing.expect(t, core.run_command(core.Zoom_Pane{pane = s.tabs[0].pane}, PT_UI).ok, "zoom A")
	lay(s, 900)
	lay(s, 900)
	testing.expect(t, core.run_command(core.Zoom_Pane{zoom = false}, PT_UI).ok, "restore")
	lay(s, 900) // the first layout after the restore
	pb := core.session_pane(s, b)
	testing.expectf(t, pb.rect.z >= core.PANE_MIN_W - 1, "B at least its minimum at once: %v", pb.rect)
	first := term_fits[s.tabs[2].id]
	lay(s, 900)
	testing.expect_value(t, term_fits[s.tabs[2].id].cols, first.cols)
	testing.expect_value(t, core.session_pane(s, b).rect, pb.rect)
}

// A press held in pane A while B is zoomed: A is not drawn, so its capture goes; moves and the
// wheel go to what is drawn.
@(test)
pane_zoom_drops_hidden_capture :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	defer pane_release()
	pointer_capture = {pane = x.a}
	core.run_command(core.Focus_Pane{pane = x.b}, PT_UI)
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	for ty in ([]sapp.Event_Type{.MOUSE_MOVE, .MOUSE_SCROLL}) {
		pointer_capture = {pane = x.a}
		e := sapp.Event{type = ty, mouse_x = 10, mouse_y = 10}
		p := event_pane(&e)
		testing.expectf(t, p != nil && p.id == x.b, "%v goes to B", ty)
		testing.expect_value(t, pointer_capture.pane, u64(0))
	}
	pointer_capture = {pane = x.a}
	e := sapp.Event{type = .MOUSE_MOVE, mouse_x = 10, mouse_y = 10}
	pane_pointer_moved(&e)
	testing.expect_value(t, pointer_capture.pane, u64(0))
	testing.expect(t, pointer_pane != x.a, "not over hidden A")
}

// Restoring shows the hidden panes' tabs: a tab that finished while hidden is seen, and its
// session's bell entries are read, as when a tab comes on screen any other way; also when the
// zoom ends because a pane went.
@(test)
pane_zoom_restore_marks_seen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	s := x.s
	core.session_show_tab(s, x.pi, focus = false) // A shows the pi tab
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	tab_of :: proc(s: ^core.Open_Session, id: u64) -> ^core.Tab {
		for &tb in s.tabs do if tb.id == id do return &tb
		return nil
	}
	tab_of(s, x.pi).unseen = true // finished while hidden
	append(&state.notices.items, core.Notice{id = core.new_id(), session = s.id, tab_id = x.pi})
	testing.expect(t, core.run_command(core.Zoom_Pane{zoom = false}, PT_UI).ok, "restore")
	testing.expect(t, !tab_of(s, x.pi).unseen, "seen once back on screen")
	testing.expect(t, state.notices.items[len(state.notices.items) - 1].read, "its bell entry read")
	// the zoom ended by a pane going: hidden A closed, its tabs join B showing A's pi tab
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	tab_of(s, x.pi).unseen = true
	core.run_command(core.Focus_Tab{tab_id = x.editor}, PT_UI) // within B: still zoomed
	testing.expect(t, tab_of(s, x.pi).unseen, "still hidden: unseen")
	core.run_command(core.Close_Pane{pane = x.a}, PT_UI)
	testing.expect_value(t, s.zoomed_pane, u64(0))
	testing.expect(t, core.session_tab_shown(s, x.pi), "pi shown in B")
	testing.expect(t, !tab_of(s, x.pi).unseen, "seen when it is drawn again")
}

// ⌥⌘A to a tab in a pane hidden by a zoom: the layout comes back, the tab is shown and focused
// (never focused but hidden); to another tab of the zoomed pane: the zoom stays.
@(test)
pane_zoom_next_needing_you :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	x := pt_two()
	defer pt_two_done(x)
	s := x.s
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	for &tb in s.tabs do if tb.id == x.shell do tb.unseen = true
	r := core.run_command(core.Next_Needing_You{}, PT_UI)
	testing.expectf(t, r.ok, "next: %s", r.error)
	testing.expect_value(t, core.session_focused_id(s), x.shell)
	testing.expect(t, core.session_tab_shown(s, x.shell), "shown")
	testing.expect_value(t, core.session_zoomed(s), u64(0))
	// within the zoomed pane
	core.run_command(core.Zoom_Pane{pane = x.b}, PT_UI)
	for &tb in s.tabs do if tb.id == x.editor do tb.prog.state = .Error
	r = core.run_command(core.Next_Needing_You{}, PT_UI)
	testing.expectf(t, r.ok, "next: %s", r.error)
	testing.expect_value(t, core.session_focused_id(s), x.editor)
	testing.expect(t, core.session_tab_shown(s, x.editor), "shown")
	testing.expect_value(t, core.session_zoomed(s), x.b)
}
