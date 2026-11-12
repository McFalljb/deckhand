package main

// The agent's drawer (⌘J): Atlas's pi in its normal terminal UI (agent.odin)
// sliding in from the right over the panels column, or, pinned (📌), as its
// own column. Header: the initial, the name, the status from its bridge
// (starting, working, needs you, error, stopped), the model, the Model
// button (pi's own model selector in the terminal), 📌 and ×. Below it the
// terminal, drawn by the frame like the centre's (main.odin) into the
// "drawer_term" element. Its left edge is a column divider (2, ui_sidebar.odin):
// drag to resize, double-click to reset.
//
// The keyboard: focus widget "agent_input" sends keys to Atlas's terminal
// (key_term); a click in it takes the keyboard there, a click in the centre
// gives it back (a sliding drawer closes). Esc belongs to pi; ⌘J and ⌘W hide
// the drawer.

import "core:strings"
import "core:unicode/utf8"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Drawer_Hit_Kind :: enum {
	Pin,
	Close,
	Model, // pi's model selector
	Term, // Atlas's terminal
	Notes, // the atlas-folder warning's Set up Deckhand… (docs/ATLAS.md §8)
}

Hit_Agent :: struct {
	what: Drawer_Hit_Kind,
}

@(private = "file")
drawer_ui: struct {
	mouse: bool, // a press in Atlas's terminal: moves and the release go there
}

@(private = "file")
hovered :: proc(h: Hit_Agent) -> bool {return ui_hover == Hit(h)}

// The drawer's width as laid out (framebuffer px): the saved one (or a drag
// of its edge in progress), at most DRAWER_MAX_FRACTION of the space right
// of the left column; pinned, the centre also keeps CENTRE_MIN beside the
// panels (down to the drawer's own minimum).
drawer_w :: proc() -> f32 {
	left, right := column_widths()
	avail := ui_win_w - left * app.dpi
	w := state.layout.drawer_width
	if divider.active && divider.which == 2 do w = divider.value
	if w <= 0 do w = core.DRAWER_WIDTH_DEFAULT
	most := avail * DRAWER_MAX_FRACTION
	if state.layout.drawer_pinned do most = max(min(most, avail - (right + CENTRE_MIN) * app.dpi), min(px(core.DRAWER_WIDTH_MIN), most))
	return min(px(w), most)
}

// The left edge's line: the column dividers' look, highlighted while hovered
// or dragged.
@(private = "file")
drawer_edge :: proc() -> core.Rgba {
	th := theme()
	if divider.active && divider.which == 2 do return th.accent
	if d, ok := ui_hover.(Hit_Divider); ok && int(d) == 2 do return mix(th.border, th.accent, 0.6)
	return th.border
}

@(private = "file")
drawer_top :: proc() -> f32 {return px(TAB_STRIP_H) + confirm_bar_h()}

// Sliding over the right side (not pinned).
drawer_floating :: proc(w, h: f32) {
	th := theme()
	v := fade(clay.ID("drawer"), 0, state.home_open ? 1 : 0, DUR_SLIDE)
	if v <= 0.001 || core.home_tab() == nil do return
	top := drawer_top()
	dw := drawer_w()
	if clay.UI(clay.ID("drawer"))({
		layout = {sizing = {clay.SizingFixed(dw), clay.SizingFixed(h - top)}, padding = {left = pu(core.BORDER_W)}, layoutDirection = .TopToBottom}, // children start after the edge's line (Atlas's terminal is drawn over them)
		backgroundColor = cc(th.bg_app),
		border = {color = cc(drawer_edge()), width = {left = pu(core.BORDER_W)}},
		floating = {attachTo = .Root, attachment = {element = .RightTop, parent = .RightTop}, offset = {(1 - v) * dw, top}, zIndex = 5},
	}) {
		drawer_content(dw)
	}
}

// Pinned: a column of the body, beside the terminal and the panels.
drawer_pinned_column :: proc() {
	th := theme()
	if !state.home_open || core.home_tab() == nil do return
	dw := drawer_w()
	if clay.UI(clay.ID("drawer"))({
		layout = {sizing = {clay.SizingFixed(dw), clay.SizingGrow()}, padding = {left = pu(core.BORDER_W)}, layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(drawer_edge()), width = {left = pu(core.BORDER_W)}},
	}) {
		drawer_content(dw)
	}
}

// The drawer is in this frame's layout (open, or sliding out).
drawer_laid_out: bool

@(private = "file")
drawer_content :: proc(dw: f32) {
	drawer_laid_out = true
	drawer_header(dw)
	drawer_notes_warning(dw)
	// the terminal (drawn after the layout, main.odin), or why there is none
	if clay.UI(clay.ID("drawer_term"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
		if !agent_running() {
			ht := core.home_tab()
			if ht != nil && ht.status == .Exited do empty_state(strings.concatenate({core.agent_name(), " stopped"}, context.temp_allocator), "Press ⌘J twice to start it again", dw)
			else do empty_state(strings.concatenate({"Starting ", core.agent_name(), "…"}, context.temp_allocator), "Its pi starts in the background", dw)
		}
	}
}

@(private = "file")
drawer_header :: proc(dw: f32) {
	th := theme()
	ht := core.home_tab()
	status, col := agent_status_text()
	model := core.agent_model_short()
	if model == "" do model = "pi's default"
	// what the model's name may take: the header less everything else on it
	gap := px(SP_2)
	button_w := text_w("Model", FONT_UI_SMALL) + px(2 * SP_2)
	used := px(DRAWER_PAD + SP_2) + px(AVATAR) + text_w(core.agent_name(), WEIGHT_BOLD) + 2 * px(TAB_H) + button_w + 6 * gap
	if ht != nil && ht.agent == .Working do used += px(MARK) + gap
	if status != "" do used += text_w(status, FONT_UI_SMALL) + gap
	room := dw - used
	if clay.UI(clay.ID("drawer_head"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H + SP_3))}, padding = {pu(DRAWER_PAD), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_panel),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		avatar(AVATAR)
		clay.TextDynamic(core.agent_name(), txt(th.text, WEIGHT_BOLD))
		if ht != nil && ht.agent == .Working do status_mark_el({dot = .Running, progress = -1}) // working: the turning arc
		if status != "" do clay.TextDynamic(status, txt(col, FONT_UI_SMALL))
		spacer()
		// the model as Deckhand knows it, then the button that opens pi's selector
		if room >= px(24) {
			if clay.UI(clay.ID("drawer_model_name"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
				clay.TextDynamic(clip(model, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		model_id := clay.ID("drawer_model")
		mbg, mem := overlay(model_id, false, hovered({what = .Model}))
		if !hovered({what = .Model}) do mbg = cc(mix(th.bg_panel, th.text, TINT_BUTTON))
		if clay.UI(model_id)({
			layout = {sizing = {clay.SizingFixed(button_w), clay.SizingFixed(px(TAB_H - 4))}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = mbg,
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			clay.Text("Model", txt(mix(th.text_secondary, th.text, mem), FONT_UI_SMALL))
		}
		pin_id := clay.ID("drawer_pin")
		bg, em := overlay(pin_id, state.layout.drawer_pinned, hovered({what = .Pin}))
		if clay.UI(pin_id)({
			layout = {sizing = {clay.SizingFixed(px(TAB_H)), clay.SizingFixed(px(TAB_H))}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = bg,
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			clay.Text("📌", txt(with_alpha(th.text, state.layout.drawer_pinned ? 1 : 0.45 + 0.4 * em), FONT_UI_SMALL))
		}
		close_id := clay.ID("drawer_close")
		cbg, cem := overlay(close_id, false, hovered({what = .Close}))
		if clay.UI(close_id)({
			layout = {sizing = {clay.SizingFixed(px(TAB_H)), clay.SizingFixed(px(TAB_H))}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = cbg,
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			clay.Text("×", txt(mix(th.text_muted, th.text, cem)))
		}
	}
}

// One line under the header while Atlas's prompt cannot live in the atlas
// folder (no main folder, or not reachable): it uses the data folder's copy.
@(private = "file")
drawer_notes_warning :: proc(dw: f32) {
	msg := core.agent_prompt_warning()
	if msg == "" do return
	th := theme()
	label := "Set up Deckhand…"
	bw := text_w(label, FONT_UI_SMALL) + px(2 * SP_2)
	if clay.UI(clay.ID("drawer_notes_line"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))}, padding = {pu(DRAWER_PAD), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(with_alpha(th.waiting, 0.12)),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		clay.TextDynamic(clip(msg, dw - px(DRAWER_PAD + 2 * SP_2) - bw, FONT_UI_SMALL), txt(th.text_secondary, FONT_UI_SMALL))
		spacer()
		id := clay.ID("drawer_notes")
		bg, em := overlay(id, false, hovered({what = .Notes}))
		if !hovered({what = .Notes}) do bg = cc(mix(th.bg_panel, th.text, TINT_BUTTON))
		if clay.UI(id)({
			layout = {sizing = {clay.SizingFixed(bw), clay.SizingFixed(px(TAB_H - 6))}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = bg,
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			clay.TextDynamic(label, txt(mix(th.text_secondary, th.text, em), FONT_UI_SMALL))
		}
	}
}

// The agent's initial in an accent circle.
avatar :: proc(size: f32) {
	th := theme()
	name := core.agent_name()
	r, n := utf8.decode_rune(name)
	initial := r >= 'a' && r <= 'z' ? utf8_string(r - 32) : name[:n]
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(px(size)), clay.SizingFixed(px(size))}, childAlignment = {x = .Center, y = .Center}},
		backgroundColor = cc(th.accent),
		cornerRadius = clay.CornerRadiusAll(px(size / 2)),
	}) {
		clay.TextDynamic(initial, txt(th.text_on_accent, size < AVATAR ? FONT_UI_SMALL : WEIGHT_BOLD))
	}
}

// "starting…", "working…", "needs you", "error", "stopped" and its colour,
// from Atlas's tab (its bridge status).
@(private = "file")
agent_status_text :: proc() -> (string, core.Rgba) {
	th := theme()
	ht := core.home_tab()
	switch {
	case ht == nil || ht.status == .Exited: return "stopped", th.text_muted
	case ht.waiting:                        return "needs you", th.waiting
	case ht.agent == .Unknown:              return "starting…", th.text_muted
	case ht.agent == .Working:              return "working…", th.running
	case ht.agent == .Error:                return "error", th.error
	}
	return "", th.text_muted
}

// Atlas's terminal box after the layout: its grid follows it.
drawer_term_rect :: proc() -> (x, y, w, h: f32, ok: bool) {
	if !drawer_laid_out do return // shut (it still shows while it slides out)
	d := clay.GetElementData(clay.ID("drawer_term"))
	if !d.found || d.boundingBox.width < 1 || d.boundingBox.height < 1 do return
	b := d.boundingBox
	return b.x, b.y, b.width, b.height, true
}

// ---- input ----

drawer_hit :: proc() -> Hit {
	if clay.PointerOver(clay.ID("drawer_pin")) do return Hit_Agent{what = .Pin}
	if clay.PointerOver(clay.ID("drawer_close")) do return Hit_Agent{what = .Close}
	if clay.PointerOver(clay.ID("drawer_model")) do return Hit_Agent{what = .Model}
	if clay.PointerOver(clay.ID("drawer_notes")) do return Hit_Agent{what = .Notes}
	if clay.PointerOver(clay.ID("drawer_term")) do return Hit_Agent{what = .Term}
	return nil
}

drawer_click :: proc(h: Hit_Agent) {
	switch h.what {
	case .Pin:   ui_do(core.Set_Layout{drawer_pinned = !state.layout.drawer_pinned})
	case .Close: ui_do(core.Set_Home{open = false})
	case .Model: action_run("agent_model")
	case .Notes: action_run("setup") // the first-run sheet (ui_setup.odin)
	case .Term:  if state.focus_widget != "agent_input" do ui_do(core.Set_Focus{"agent_input"})
	}
	app.redraw = true
}

drawer_tip :: proc(h: Hit_Agent) -> (label, keys: string) {
	switch h.what {
	case .Model:  return "Change the model: pi's model selector", "⌃L"
	case .Pin:    return state.layout.drawer_pinned ? "Unpin: slide over" : "Pin as a column", ""
	case .Close:  return "Hide", "⌘J"
	case .Notes:  return "Set up Deckhand's main folder: Atlas's prompt moves to its atlas/ (a copy; the old file stays)", ""
	case .Term:
	}
	return "", ""
}

// Drawer input: a press or hover on its left edge (a divider, before the
// terminal under it and the editor and Files tab beside it), and the mouse in
// Atlas's terminal (press, drag, release, wheel). The drag itself is the
// dividers' (main.odin). True if consumed.
drawer_event :: proc(e: ^sapp.Event) -> bool {
	if !drawer_ui.mouse && (e.type == .MOUSE_DOWN || e.type == .MOUSE_MOVE) && divider_at(e.mouse_x, e.mouse_y) == 2 {
		app.pointer = {e.mouse_x, e.mouse_y}
		if e.type == .MOUSE_DOWN && e.mouse_button == .LEFT {
			divider_press(2, e.mouse_x, app.clicks)
			return true
		}
		if e.type == .MOUSE_MOVE && e.modifiers & sapp.MODIFIER_LMB == 0 {
			set_hover(Hit_Divider(2), false)
			return true
		}
	}
	t := agent_view()
	in_term := state.home_open && t != nil && inside(clay.ID("drawer_term"), e.mouse_x, e.mouse_y) && !over_overlay()
	#partial switch e.type {
	case .MOUSE_DOWN:
		if !in_term do return false
		app.pointer = {e.mouse_x, e.mouse_y}
		if term_link_mouse_down(t, e) do return true // ⌘-click or right-click on a link (term_links.odin)
		if e.mouse_button != .LEFT do return false
		if state.focus_widget != "agent_input" do ui_do(core.Set_Focus{"agent_input"})
		term_mouse_down(t, e, app.clicks)
		drawer_ui.mouse = true
		app.redraw = true
		return true
	case .MOUSE_MOVE:
		if drawer_ui.mouse || in_term {
			app.pointer = {e.mouse_x, e.mouse_y}
			if t != nil do term_mouse_move(t, e)
			set_hover(nil, true)
			term_links_frame()
			return true
		}
	case .MOUSE_UP:
		if drawer_ui.mouse {
			drawer_ui.mouse = false
			if t != nil do term_mouse_up(t, e)
			return true
		}
	case .MOUSE_SCROLL:
		if in_term {
			term_scroll(t, e)
			app.redraw = true
			return true
		}
		if state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y) do return true
	}
	return false
}

// An overlay (palette, menu, popover, sheet) covers the pointer.
over_overlay :: proc() -> bool {
	return palette_is_open() || menu.open || settings_open() || shortcuts_open() || setup_open() || cover_is_open()
}
