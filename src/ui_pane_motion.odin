package main

// Split panes with presence (theme.odin DUR_DIM, DUR_GLIDE, DUR_ZOOM; docs/GUIDE.md "Split panes"):
//
//   - Dim: a pane without the keyboard has the background's colour over its content (its tab's
//     bars and what its tab draws: a terminal, a page, an app's frame), PANE_DIM of the look, an
//     overlay drawn after the content (input goes through: it is not an element). Fades over
//     DUR_DIM when the focus moves; Settings.dim_panes_off turns it off; Reduce motion only
//     drops the fade.
//   - Focus line: one accent bar under the focused pane's strip (the strips' own lines are all
//     the border colour). When the focus moves from one strip on screen to another it glides
//     there (x, y and width) over DUR_GLIDE; else, and under Reduce motion, it is just there.
//   - Zoom (zoom_pane, ⇧⌘↩): the layout switches at once (the zoomed pane alone is laid out, so
//     what is hit is what is drawn, and its terminal is resized once). An outline eases from the
//     pane's old rect to its new one over DUR_ZOOM, fading out as it goes.
//
// pane_motion_layout runs at the end of every layout (ui_layout) and works out what this frame
// draws; panes_draw draws it after each pane's content (main.odin). Frames are asked for only
// while the line or the outline moves (pane_motion.moving) or a dim fades (fade's own).

import "core:fmt"
import "core:time"
import "core"
import clay "../build/clay-odin"

Pane_Dim :: struct {
	pane:  u64,
	rect:  [4]f32, // below its strip (framebuffer px)
	alpha: f32, // of the background's colour, 0 < alpha <= the look's PANE_DIM
}

Pane_Motion :: struct {
	dims:         [core.PANES_MAX]Pane_Dim, // this layout's dimmed panes
	dims_n:       int,
	// the focus line
	bar_session:  u64, // the session and pane it was last under
	bar_pane:     u64,
	bar:          [4]f32, // where this frame draws it ({} = none)
	bar_from:     [4]f32,
	bar_t0:       time.Tick, // its glide started ({} = at rest)
	// the zoom's outline
	zoom_session: u64, // the session and its zoomed pane at the last layout
	zoom_pane:    u64,
	ghost_from:   [4]f32,
	ghost_to:     [4]f32,
	ghost_t0:     time.Tick, // {} = none
	ghost:        [4]f32, // where this frame draws it
	ghost_alpha:  f32, // 0 = not drawn
	moving:       bool, // the line or the outline moves: draw the next frame (ui_wants_frame)
}
pane_motion: Pane_Motion

// The look's dim, light or dark.
pane_dim_alpha :: proc() -> f32 {
	return core.theme_is_light() ? PANE_DIM_LIGHT[state.settings.theme] : PANE_DIM[state.settings.theme]
}

// Ease-out cubic of k in 0..1, as fade().
ease_out :: proc(k: f32) -> f32 {
	k := clamp(k, 0, 1)
	return 1 - (1 - k) * (1 - k) * (1 - k)
}

rect_lerp :: proc(a, b: [4]f32, e: f32) -> [4]f32 {return a + (b - a) * e}

@(private = "file")
box_of :: proc(id: clay.ElementId) -> [4]f32 {
	d := clay.GetElementData(id)
	if !d.found do return {}
	b := d.boundingBox
	return {b.x, b.y, b.width, b.height}
}

// Pane p's part under its strip (its tab's bars and content), as laid out; {} when not.
pane_dim_rect :: proc(p: ^core.Pane) -> [4]f32 {
	f := box_of(pid(p, "pane"))
	if f.z <= 0 do return {}
	top := f.y
	if s := box_of(pid(p, "pane_strip")); s.z > 0 do top = s.y + s.w
	return {f.x, top, f.z, f.y + f.w - top}
}

// The focus line's place under pane `pane_id`'s strip (its bottom border), {} when not laid out.
pane_focus_line :: proc(cs: ^core.Open_Session, pane_id: u64) -> [4]f32 {
	p := core.session_pane(cs, pane_id)
	if p == nil do return {}
	s := box_of(pid(p, "pane_strip"))
	if s.z <= 0 do return {}
	h := f32(pu(core.BORDER_W))
	return {s.x, s.y + s.w - h, s.z, h}
}

// What this frame draws of the panes' motion, from the layout just made (cs: the session it laid
// out). p.frame is still the last layout's here (ui_pane_rects runs after): where a pane was.
pane_motion_layout :: proc(cs: ^core.Open_Session, now := time.Tick{}) {
	now := now != {} ? now : time.tick_now()
	m := &pane_motion
	m.dims_n, m.moving = 0, false
	reduce := state.settings.reduce_motion
	split := cs != nil && len(cs.panes) > 1
	sid: u64 = cs != nil ? cs.id : 0
	elapsed :: proc(t0, now: time.Tick, dur: time.Duration) -> f32 {
		return f32(time.duration_seconds(time.tick_diff(t0, now)) / time.duration_seconds(dur))
	}

	// dim: every pane on screen but the focused one
	if split do for &p in cs.panes {
		if core.pane_zoom_hidden(cs, p.id) do continue
		target: f32 = !state.settings.dim_panes_off && p.id != cs.focused_pane ? 1 : 0
		k := fade(clay.ID("pane_dim", u32(p.id)), 0, target, DUR_DIM)
		r := pane_dim_rect(&p)
		if k <= 0 || r.z <= 0 || r.w <= 0 || m.dims_n >= len(m.dims) do continue
		m.dims[m.dims_n] = {p.id, r, k * pane_dim_alpha()}
		m.dims_n += 1
	}

	// the focus line: glides when the focus moved from one strip on screen to another
	focused: u64 = cs != nil ? cs.focused_pane : 0
	line: [4]f32
	if split do line = pane_focus_line(cs, focused)
	if sid != m.bar_session || focused != m.bar_pane {
		was := pane_focus_line(cs, m.bar_pane) // the strip it was under, still on screen
		glide := !reduce && sid == m.bar_session && line.z > 0 && m.bar.z > 0 && was.z > 0
		m.bar_from, m.bar_t0 = m.bar, glide ? now : {}
	}
	m.bar_session, m.bar_pane = sid, focused
	m.bar = line
	if m.bar_t0 != {} {
		k := elapsed(m.bar_t0, now, DUR_GLIDE)
		if reduce || line.z <= 0 || k >= 1 || k < 0 {
			m.bar_t0 = {}
		} else {
			m.bar = rect_lerp(m.bar_from, line, ease_out(k))
			m.moving = true
		}
	}

	// the zoom's outline: from the pane's rect before (its last layout's frame) to its rect now
	z := core.session_zoomed(cs)
	if sid == m.zoom_session && z != m.zoom_pane && !reduce {
		id := z != 0 ? z : m.zoom_pane
		if p := core.session_pane(cs, id); p != nil {
			to := box_of(pid(p, "pane"))
			if p.frame.z > 0 && to.z > 0 && p.frame != to do m.ghost_from, m.ghost_to, m.ghost_t0 = p.frame, to, now
		}
	}
	if sid != m.zoom_session do m.ghost_t0 = {} // another session: as it is
	m.zoom_session, m.zoom_pane = sid, z
	m.ghost_alpha = 0
	if m.ghost_t0 != {} {
		k := elapsed(m.ghost_t0, now, DUR_ZOOM)
		if reduce || k >= 1 || k < 0 {
			m.ghost_t0 = {}
		} else {
			e := ease_out(k)
			m.ghost = rect_lerp(m.ghost_from, m.ghost_to, e)
			m.ghost_alpha = ZOOM_GHOST_ALPHA * (1 - e)
			m.moving = true
		}
	}
}

// The panes' tabs on screen (a zoom hides the others), each dimmed when it has no keyboard, then
// the focus line and a zoom's outline over them (below the drawer and the overlays: main.odin).
panes_draw :: proc(cs: ^core.Open_Session, t: ^Term_View, typing: bool) {
	th := theme()
	m := &pane_motion
	for &p in cs.panes {
		if core.pane_zoom_hidden(cs, p.id) do continue
		pane_draw(&p, t, typing)
		for d in m.dims[:m.dims_n] do if d.pane == p.id do draw_rect(d.rect.x, d.rect.y, d.rect.z, d.rect.w, with_alpha(th.bg_app, d.alpha))
	}
	if m.bar.z > 0 do draw_rect(m.bar.x, m.bar.y, m.bar.z, m.bar.w, th.accent)
	if m.ghost_alpha > 0 {
		g, w := m.ghost, px(ZOOM_GHOST_W)
		col := with_alpha(th.accent, m.ghost_alpha)
		draw_rect(g.x, g.y, g.z, w, col)
		draw_rect(g.x, g.y + g.w - w, g.z, w, col)
		draw_rect(g.x, g.y + w, w, g.w - 2 * w, col)
		draw_rect(g.x + g.z - w, g.y + w, w, g.w - 2 * w, col)
	}
}

// ---- zoom: the action, the strip's marker ----

// ⇧⌘↩, the menus' Zoom pane / Restore panes: the focused pane's zoom toggles (pane 0: the core
// takes the pane focused when it runs, so a pane's "+" menu, which focuses its pane first, zooms
// that one).
pane_zoom_action :: proc() -> (core.Command, bool) {
	cs := core.cur()
	if cs == nil || cs.home || len(cs.panes) <= 1 do return nil, false
	return core.Zoom_Pane{}, true
}

// The current session has a zoomed pane.
pane_zoomed_now :: proc() -> bool {return core.session_zoomed(core.cur()) != 0}

// The zoomed pane's strip marker: which pane of how many ("⤢ 2 of 3"); a click restores.
pane_zoom_label :: proc(cs: ^core.Open_Session, p: ^core.Pane) -> string {
	return fmt.tprintf("⤢ %d of %d", p.slot + 1, len(cs.panes))
}
