package main

// Clay layout: left column (projects, then the selected project's sessions),
// the tab strip and terminal pane, and an optional right column; widths come
// from State.layout. Clay runs only on frames that redraw; its render
// commands are drawn with the same sokol_gl quads as the terminal. All units
// are framebuffer pixels; every size and colour comes from theme.odin.
//
// Motion: hover and selection fade (ease-out), a pulsing dot for running
// tabs. Both only redraw while they move (ui_wants_frame); nothing animates
// while idle, and Settings.reduce_motion turns both off.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import clay "../build/clay-odin"
import sgl "../vendor/sokol-odin/sokol/gl"

// Renaming the selected project (its row in the left column).
rename_field: Text_Field
rename_session: string // the Claude session whose row the rename field takes (focus widget rename_session; ui_sidebar.odin)

ui_memory: []u8

// What the pointer is over (from the last layout), for hover states.
ui_hover: Hit

ui_init :: proc() {
	// the agent's chat lays out a line per element: room for long chats
	clay.SetMaxElementCount(1 << 16)
	clay.SetMaxMeasureTextCacheWordCount(1 << 17)
	size := clay.MinMemorySize()
	ui_memory = make([]u8, size)
	arena := clay.CreateArenaWithCapacityAndMemory(uint(size), raw_data(ui_memory))
	clay.Initialize(arena, {1, 1}, {handler = ui_error})
	clay.SetMeasureTextFunction(ui_measure_text, nil)
}

ui_error :: proc "c" (e: clay.ErrorData) {
	context = app_context
	fmt.eprintln("clay:", e.errorType, string(e.errorText.chars[:e.errorText.length]))
}

// Clay's fontId = font kind | FONT_BOLD (font.odin); UI text is proportional.
ui_measure_text :: proc "c" (text: clay.StringSlice, config: ^clay.TextElementConfig, user: rawptr) -> clay.Dimensions {
	context = app_context
	kind, bold := font_id_split(config.fontId)
	return {text_width(string(text.chars[:text.length]), kind, bold, font_id_italic(config.fontId), font_id_semibold(config.fontId)), text_line_height(kind)}
}

// ---- token helpers ----

px :: proc(v: f32) -> f32 {return v * app.dpi}
pu :: proc(v: f32) -> u16 {return u16(math.round(v * app.dpi))}
cc :: proc(c: Rgba) -> clay.Color {return {f32(c.r), f32(c.g), f32(c.b), f32(c.a)}}
to_rgba :: proc(c: clay.Color) -> Rgba {return {u8(c.r), u8(c.g), u8(c.b), u8(c.a)}}

with_alpha :: proc(c: Rgba, k: f32) -> Rgba {return {c.r, c.g, c.b, u8(f32(c.a) * clamp(k, 0, 1))}}

mix :: proc(a, b: Rgba, t: f32) -> Rgba {
	k := clamp(t, 0, 1)
	l :: proc(x, y: u8, k: f32) -> u8 {return u8(math.round(f32(x) + (f32(y) - f32(x)) * k))}
	return {l(a.r, b.r, k), l(a.g, b.g, k), l(a.b, b.b, k), l(a.a, b.a, k)}
}

txt :: proc(col: Rgba, weight: u16 = WEIGHT_REGULAR) -> clay.TextElementConfig {
	return {textColor = cc(col), fontId = weight, wrapMode = .None}
}

text_w :: proc(s: string, weight: u16 = WEIGHT_REGULAR) -> f32 {
	kind, bold := font_id_split(weight)
	return text_width(s, kind, bold, font_id_italic(weight), font_id_semibold(weight))
}

// Clips s to max_w pixels (temp allocator when cut), with an ellipsis.
clip :: proc(s: string, max_w: f32, weight: u16 = WEIGHT_REGULAR) -> string {
	kind, bold := font_id_split(weight)
	return text_clip(s, max_w, kind, bold, font_id_italic(weight), font_id_semibold(weight))
}

// s as at most max_lines lines no wider than max_w, joined with "\n" (temp
// allocator; draw with wrapMode .Newlines): broken at spaces, a word wider
// than a line cut between characters, the last line cut with an ellipsis
// when text is left over. n: the number of lines.
wrap_clip :: proc(s: string, max_w: f32, max_lines: int, weight: u16 = WEIGHT_REGULAR) -> (text: string, n: int) {
	kind, bold := font_id_split(weight)
	flat, _ := strings.replace_all(s, "\n", " ", context.temp_allocator)
	rest := strings.trim_space(flat)
	if rest == "" || max_w <= 0 || max_lines <= 0 do return "", 0
	b := strings.builder_make(context.temp_allocator)
	for rest != "" {
		if n > 0 do strings.write_byte(&b, '\n')
		n += 1
		fit := text_fit(rest, max_w, kind, bold, font_id_italic(weight), font_id_semibold(weight))
		if n == max_lines || fit == len(rest) {
			strings.write_string(&b, clip(rest, max_w, weight))
			break
		}
		cut := strings.last_index_byte(rest[:fit + 1], ' ') // a space right after the fit breaks there too
		if cut <= 0 {
			cut = fit
			if cut == 0 do _, cut = utf8.decode_rune_in_string(rest) // not even one character fits: one per line
		}
		strings.write_string(&b, strings.trim_right_space(rest[:cut]))
		rest = strings.trim_left_space(rest[cut:])
	}
	return strings.to_string(b), n
}

// "2026-08-21 01:20" (UTC, from the file name) -> "now", "5m", "3h", "2d", "6w", "1y".
rel_time :: proc(when_: string) -> string {
	if len(when_) < 16 do return ""
	n :: proc(s: string) -> int {v, _ := strconv.parse_int(s); return v}
	t, ok := time.components_to_time(n(when_[0:4]), n(when_[5:7]), n(when_[8:10]), n(when_[11:13]), n(when_[14:16]), 0)
	if !ok do return ""
	m := int(time.duration_minutes(time.since(t)))
	switch {
	case m < 1:              return "now"
	case m < 60:             return fmt.tprintf("%dm", m)
	case m < 24 * 60:        return fmt.tprintf("%dh", m / 60)
	case m < 7 * 24 * 60:    return fmt.tprintf("%dd", m / (24 * 60))
	case m < 365 * 24 * 60:  return fmt.tprintf("%dw", m / (7 * 24 * 60))
	}
	return fmt.tprintf("%dy", m / (365 * 24 * 60))
}

// ---- motion ----

Fade :: struct {
	from, to, value: f32,
	t0:              time.Tick,
}

@(private = "file")
fades: map[u32]Fade
@(private = "file")
animating: bool // a fade is mid-way: draw the next frame
@(private = "file")
pulsing: bool // a running dot is on screen: draw at PULSE_FPS
@(private = "file")
pulse_drawn: i64 // pulse step of the last drawn frame

@(private = "file")
pulse_step :: proc() -> i64 {
	// reduce motion: the dot is static; redraw once a second so it still
	// turns idle when output stops
	step := state.settings.reduce_motion ? time.Second : time.Second / PULSE_FPS
	return time.tick_now()._nsec / i64(step)
}

// Eases towards target (0..1) over dur; returns the current value. An
// element seen for the first time starts at its target.
fade :: proc(id: clay.ElementId, salt: u32, target: f32, dur: time.Duration) -> f32 {
	key := id.id ~ salt
	f, seen := fades[key]
	if !seen || state.settings.reduce_motion {
		fades[key] = {from = target, to = target, value = target}
		return target
	}
	if f.to != target do f.from, f.to, f.t0 = f.value, target, time.tick_now()
	k := f32(time.duration_seconds(time.tick_since(f.t0)) / time.duration_seconds(dur))
	if k >= 1 {
		f.value = f.to
	} else {
		e := 1 - (1 - k) * (1 - k) * (1 - k) // ease-out cubic
		f.value = f.from + (f.to - f.from) * e
		animating = true
	}
	fades[key] = f
	return f.value
}

// PULSE_MIN..1 brightness of a running dot, stepped at PULSE_FPS.
@(private = "file")
pulse :: proc() -> f32 {
	pulsing = true // keeps redraws coming until no running dot is left
	if state.settings.reduce_motion do return 1
	period := f64(PULSE_PERIOD) / f64(time.Second)
	t := f64(time.tick_now()._nsec / i64(time.Second / PULSE_FPS)) / PULSE_FPS
	wave := 0.5 + 0.5 * math.cos(2 * math.PI * t / period) // 1 -> 0 -> 1
	return PULSE_MIN + (1 - PULSE_MIN) * f32(wave)
}

// True if the next frame must be drawn for motion alone, or once more after the right column's
// offset was clamped (that layout was built at the old one).
ui_wants_frame :: proc() -> bool {
	again := panels_clamped
	panels_clamped = false
	return again || animating || (pulsing && pulse_step() != pulse_drawn)
}

// ---- status ----

// What a session row or tab shows. pi tabs: the bridge's pi.status; shell
// tabs: recent output (they have no bridge).
Row_Status :: enum {
	None, // not open, idle, or no bridge yet: no dot
	Running, // pi is working (pulses); a shell printed recently
	Waiting, // waiting for you: a pi dialog is open
	Question, // pi's last answer asked something (softer)
	Error, // pi's last run ended in an error
	Exited, // pi exited
	Unseen, // finished while you were not looking (or marked unread): agent_status.odin
}

// A tab's dot in the tab strip: its status (the bridge, OSC 7501 or unseen:
// agent_status.odin), else recent output or an agent acting in a browser tab.
tab_strip_status :: proc(tab: Tab, active: bool) -> Row_Status {
	view := tab_status_view(tab)
	_, is_pi := tab.kind.(Pi_Tab)
	if view.dot != .None || is_pi do return view.dot // a status (done or idle: no dot) leaves room for recent output
	if tab.status == .Running && tab_busy(tab.id) do return .Running // recent output
	if !active && browser_act_recent(tab.id) do return .Running // an agent acts in this tab behind (browser_act.odin)
	return .None
}

tab_busy :: proc(tab_id: u64) -> bool {
	t := term_of(tab_id)
	return t != nil && t.running && t.last_output != {} && time.tick_since(t.last_output) < ACTIVITY_WINDOW
}

pi_tab_status :: proc(tab: Tab) -> Row_Status {
	if tab.status == .Exited do return .Exited
	if tab.waiting do return .Waiting
	switch tab.agent {
	case .Error:   return .Error
	case .Working: return .Running
	case .Idle:    return tab.question ? .Question : .None
	case .Unknown: return .None
	}
	return .None
}

// A session's dot: the strongest of its open tabs (agent_status.odin).
session_status :: proc(pi_session_id: string) -> Row_Status {
	if pi_session_id == "" do return .None
	for &s in state.open_sessions {
		if s.pi_session_id != pi_session_id do continue
		st, _ := session_row_status(&s)
		return st
	}
	// a Claude session open as a tab of a pi session (its row in the left column): that tab's
	if id := claude_open_tab(pi_session_id); id != 0 do if _, tab, _ := find_tab(id); tab != nil do return tab_status_view(tab^).dot
	return .None
}

status_color :: proc(st: Row_Status) -> Rgba {
	th := theme()
	switch st {
	case .None:     return {}
	case .Running:  return with_alpha(th.running, pulse())
	case .Waiting:  return th.waiting
	case .Question: return with_alpha(th.waiting, QUESTION_ALPHA)
	case .Error:    return th.error
	case .Exited:   return with_alpha(th.text_muted, EXITED_ALPHA)
	case .Unseen:   return th.done
	}
	return {}
}

// ---- building blocks ----

SALT_SELECT :: 0x9e3779b9

// Background of a row/tab/button: selection and hover overlays, faded.
overlay :: proc(id: clay.ElementId, selected, hovered: bool) -> (bg: clay.Color, emphasis: f32) {
	th := theme()
	s := fade(id, SALT_SELECT, selected ? 1 : 0, DUR_SWITCH)
	h := fade(id, 0, hovered ? 1 : 0, DUR_HOVER)
	a := f32(th.selected.a) * s + f32(th.hover.a) * h
	return cc({th.selected.r, th.selected.g, th.selected.b, u8(min(a, 255))}), max(s, h)
}

row_cfg :: proc(bg: clay.Color, direction := clay.LayoutDirection.LeftToRight) -> clay.ElementDeclaration {
	return {
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H))},
			padding = {pu(PAD_ROW), pu(PAD_ROW), 0, 0},
			childGap = pu(GAP_INLINE),
			childAlignment = {y = .Center},
			layoutDirection = direction,
		},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}
}

spacer :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {}
}

gap :: proc(h: f32) {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(h))}}}) {}
}

dot :: proc(col: Rgba) {
	if clay.UI()({
		layout = {sizing = {clay.SizingFixed(px(DOT)), clay.SizingFixed(px(DOT))}},
		backgroundColor = cc(col),
		cornerRadius = clay.CornerRadiusAll(px(DOT / 2)),
	}) {}
}

@(private = "file")
section_header :: proc(id: clay.ElementId, label: string) {
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
	}) {
		clay.TextDynamic(label, txt(theme().text_muted, WEIGHT_BOLD))
	}
}

// A thin vertical line between button groups, GAP_GROUP wide.
group_separator :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingFixed(px(GAP_GROUP)), clay.SizingFixed(px(SEPARATOR_H))}, childAlignment = {x = .Center}}}) {
		if clay.UI()({layout = {sizing = {clay.SizingFixed(px(BORDER_W)), clay.SizingGrow()}}, backgroundColor = cc(theme().border)}) {}
	}
}

// The centre's width (framebuffer px): the window less the columns and a
// pinned agent drawer.
centre_width :: proc() -> f32 {
	left, right := column_widths()
	w := ui_win_w - (left + right) * app.dpi
	if state.layout.drawer_pinned && state.home_open && home_tab() != nil do w -= drawer_w()
	return w
}

// Two lines in a list that has nothing to show.
empty_state :: proc(title, hint: string, width: f32) {
	th := theme()
	if clay.UI()({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(SP_2), pu(SP_2), pu(SP_2), pu(SP_2)}, childGap = pu(SP_1), layoutDirection = .TopToBottom},
	}) {
		room := width - px(2 * SP_2)
		clay.TextDynamic(clip(title, room), txt(th.text_secondary))
		clay.TextDynamic(clip(hint, room), txt(th.text_muted))
	}
}

// ---- layout ----

// Layout passes so far (ui_layout): what was laid out in the last one is on screen.
ui_layout_pass: u64

ui_layout :: proc(w, h: f32) -> clay.ClayArray(clay.RenderCommand) {
	ui_layout_pass += 1
	animating, pulsing = false, false
	drawer_laid_out = false
	pulse_drawn = pulse_step()
	ui_win_w = w
	clay.SetLayoutDimensions({w, h})
	clay.BeginLayout()
	cs := cur()
	palette_sync()
	if clay.UI(clay.ID("root"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .LeftToRight},
		backgroundColor = cc(theme().bg_app),
	}) {
		sidebar(cs, h)
		// the top bar (tabs) spans the centre and the right column; it is
		// the window's title bar too (empty parts drag the window)
		if clay.UI(clay.ID("main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
			tab_strip(cs, w)
			if len(state.pending_confirmations) > 0 do confirm_bar(state.pending_confirmations[0])
			if clay.UI(clay.ID("body"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .LeftToRight}}) {
				centre(cs)
				if state.layout.right_open do right_column(cs)
				if state.layout.drawer_pinned do drawer_pinned_column()
			}
		}
		if !state.layout.drawer_pinned do drawer_floating(w, h)
		files_drag_layout()
		wt_menu_layout(w, h)
		menu_layout(w, h)
		settings_layout(w, h)
		bell_layout(w, h)
		shortcuts_layout(w, h)
		setup_layout(w, h) // the first-run sheet (ui_setup.odin)
		job_sheet_layout(w, h) // the job sheet (ui_job_sheet.odin)
		if palette_is_open() do palette_layout(w, h)
		term_link_tip_layout() // a terminal link's URL while ⌘ is held (term_links.odin)
		toast_layout(w, h) // a menu choice's outcome (toast.odin)
		tooltip_layout(w, h)
	}
	cmds := clay.EndLayout(0)
	if panels_scroll_clamp() do panels_clamped = true // drawn again at the clamped offset (ui_wants_frame)
	return cmds
}

// A text field's text (with an input method's composition at the caret);
// the caret, selection and composition underline are drawn after the
// layout (ui_draw_field_cursor).
field_text :: proc(id: clay.ElementId, f: ^Text_Field, placeholder: string) {
	th := theme()
	shown, _, _ := tf_display(f, ime.marked)
	if clay.UI(id)({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
		if shown == "" && placeholder != "" do clay.TextDynamic(placeholder, txt(th.text_muted))
		else do clay.TextDynamic(shown, txt(th.text))
	}
}

// The focused text field, its text element and its box (for clicks).
focused_field :: proc() -> (f: ^Text_Field, text_id, box_id: clay.ElementId) {
	if job_sheet_open() do return &job_sheet.fields[job_sheet.focus], clay.ID("jstext"), clay.ID("jsfield", u32(job_sheet.focus))
	if setup_open() && setup_ui.edit != SETUP_EDIT_NONE do return &setup_ui.field, clay.ID("setup_field_text"), clay.ID("setup_field_box") // the setup sheet's accounts step
	switch state.focus_widget {
	case "rename_project", "rename_session": return &rename_field, clay.ID("rename_text"), clay.ID("rename_field")
	case "palette":        return &palette.field, clay.ID("palette_text"), clay.ID("palette_input")
	case "sidebar_filter": return &filter_field, clay.ID("filter_text"), clay.ID("filter_box")
	case "files_filter":   return &files_filter_field, clay.ID("files_filter_text"), clay.ID("files_filter_box")
	case "files_name":     return &files_name_field, clay.ID("files_name_text"), clay.ID("files_name_box")
	case "changes_message": return &changes_message_field, fid("ch_field_text"), fid("ch_field")
	case "comment_edit":   return &comment_edit_field, clay.ID("cm_edit_text"), clay.ID("cm_edit_box")
	case "comment_new":    return &comment_new_field, clay.ID("cm_new_text"), clay.ID("cm_new_box")
	case "browser_url":    return &browser_url_field, fid("br_url_text"), fid("br_url_box") // browser_nav.odin
	case "browser_find":   return &page_find_field, fid("pg_find_text"), fid("pg_find_box") // browser_polish.odin
	case "browser_prompt": return &page_prompt_field, fid("pg_prompt_text"), fid("pg_prompt_box")
	case:                  return editor_focused_field()
	}
}

// A per-tab bar's field id: the focused pane's (the keyboard's field is always in it), wherever
// the pointer or the layout is.
@(private = "file")
fid :: proc(name: string) -> clay.ElementId {return pid(focused_pane(), name)}

// A press on the focused field's box (focused_field): a pane's field (fid, the editor's bars) only
// inside its pane, where it shows (pane_inside: a field reaching past a narrow pane's edge is cut
// there); the others anywhere on their box.
field_inside :: proc(box_id: clay.ElementId, x, y: f32) -> bool {
	switch state.focus_widget {
	case "changes_message", "browser_url", "browser_find", "browser_prompt", "editor_find", "editor_replace", "editor_goto":
		return pane_inside(focused_pane(), box_id, x, y)
	}
	return inside(box_id, x, y)
}

// ---- command palette ----

// A scrim over the window and a box near its top: the query field, then the
// results. Drawn above the terminal (ui_draw draws the terminal first).
@(private = "file")
palette_layout :: proc(w, h: f32) {
	th := theme()
	rs := palette_results()
	palette.selected = clamp(palette.selected, 0, max(len(rs) - 1, 0))
	palette_keep_visible()
	box_w := px(PALETTE_W)
	if clay.UI(clay.ID("palette_scrim"))({
		layout = {sizing = {clay.SizingFixed(w), clay.SizingFixed(h)}, padding = {0, 0, pu(PALETTE_TOP), 0}, childAlignment = {x = .Center}},
		backgroundColor = cc(th.scrim),
		floating = {attachTo = .Root, zIndex = 10},
	}) {
		if clay.UI(clay.ID("palette_box"))({
			layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(SP_2))},
			backgroundColor = cc(th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		}) {
			if clay.UI(clay.ID("palette_input"))({
				layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(ROW_H + SP_2))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
			}) {
				field_text(clay.ID("palette_text"), &palette.field, palette.files ? "Open a file in this project" : palette.apps ? "A command to run in an app tab" : "Search actions, tabs, sessions, projects")
			}
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BORDER_W))}}, backgroundColor = cc(th.border)}) {}
			gap(SP_1)
			if len(rs) == 0 {
				empty_state("No matches", "Try fewer letters", box_w - px(2 * SP_2))
			}
			for i in palette.first ..< min(len(rs), palette.first + PALETTE_ROWS) {
				palette_row(rs[i], i, box_w - px(2 * SP_2))
			}
		}
	}
}

@(private = "file")
palette_row :: proc(it: Palette_Item, i: int, width: f32) {
	th := theme()
	id := clay.ID("palrow", u32(i))
	sel := i == palette.selected
	bg, _ := overlay(id, sel, ui_hover == Hit(Hit_Palette_Row(i)))
	if clay.UI(id)(row_cfg(bg)) {
		inner := width - px(2 * PAD_ROW)
		right := it.hint != "" ? it.hint : (it.chat ? "Chat" : PALETTE_KIND_NAMES[it.kind])
		// where a session or project is: a folder (a project) or a bubble (a chat)
		ic := Icon.None
		if it.kind == .Project || it.kind == .Session do ic = it.chat ? .Chat : .Folder
		room := inner - max(px(PALETTE_KIND_W), text_w(right)) - 2 * px(GAP_INLINE) // a spacer between title and kind
		if ic != .None do room -= px(KIND_ICON + GAP_INLINE)
		detail := clip(it.detail, room * 0.4)
		if detail != "" do room -= text_w(detail) + px(GAP_INLINE)
		title := clip(it.title, room)
		if ic != .None do icon(ic, th.text_muted, KIND_ICON)
		// matched characters at full strength, the rest secondary
		if clay.UI()({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
			start, ri := 0, 0
			cur_on := false
			for _, off in title {
				on := ri < 64 && it.matched & (1 << u64(ri)) != 0
				if off > start && on != cur_on {
					clay.TextDynamic(title[start:off], txt(cur_on ? th.text : th.text_secondary, cur_on ? WEIGHT_BOLD : WEIGHT_REGULAR))
					start = off
				}
				cur_on = on
				ri += 1
			}
			if start < len(title) do clay.TextDynamic(title[start:], txt(cur_on ? th.text : th.text_secondary, cur_on ? WEIGHT_BOLD : WEIGHT_REGULAR))
		}
		if detail != "" do clay.TextDynamic(detail, txt(th.text_muted))
		spacer()
		clay.TextDynamic(right, txt(th.text_muted))
	}
}

@(private = "file")
centre :: proc(cs: ^Open_Session) {
	if clay.UI(clay.ID("centre"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
		update_bar() // a pi-desk update: available, downloading, ready (ui_update.odin)
		reload_bars() // hot reload: pi settings changed, pi updated (ui_reload.odin)
		claude_reload_bars() // and Claude Code's (ui_claude_reload.odin)
		comments_bars() // pending comments: the close prompt, the strip and its list (ui_comments.odin)
		// the session's panes (panes.odin): its layout tree, or its one (implicit) pane
		if clay.UI(clay.ID("panes"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			if cs != nil && len(cs.nodes) > 0 && len(cs.panes) > 0 do pane_tree_layout(cs, cs.root)
			else do pane_layout(cs, session_focused_pane(cs))
		}
	}
}

// A node of cs's layout tree: a split lays out child a at its share, the divider, then child b
// in the rest (so b takes the divider and any rounding); a leaf, its pane.
@(private = "file")
pane_tree_layout :: proc(cs: ^Open_Session, n: int) {
	node := cs.nodes[n]
	if node.leaf {
		pane_layout(cs, session_pane(cs, node.pane))
		return
	}
	th := theme()
	across := node.dir == .Right
	ratio := pane_drag_ratio(node.id, node.ratio) // a divider being dragged: where it is now
	// kept off the panes' minimum sizes at the split's last laid-out size (pane_rects does the same)
	if d := clay.GetElementData(clay.ID("pane_split", u32(node.id))); d.found {
		kept := pane_split_share(cs, n, ratio, (across ? d.boundingBox.width : d.boundingBox.height) - px(BORDER_W))
		if abs(kept - ratio) > 0.0005 do app.redraw = true // laid out at last frame's size: once more at this one's
		ratio = kept
	}
	sz_a := across ? clay.Sizing{clay.SizingPercent(ratio), clay.SizingGrow()} : clay.Sizing{clay.SizingGrow(), clay.SizingPercent(ratio)}
	sz_div := across ? clay.Sizing{clay.SizingFixed(px(BORDER_W)), clay.SizingGrow()} : clay.Sizing{clay.SizingGrow(), clay.SizingFixed(px(BORDER_W))}
	if clay.UI(clay.ID("pane_split", u32(node.id)))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = across ? .LeftToRight : .TopToBottom}}) {
		if clay.UI(clay.ID("pane_side_a", u32(node.id)))({layout = {sizing = sz_a}}) do pane_tree_layout(cs, node.a)
		hot := pane_divider_hot(node.id)
		if clay.UI(clay.ID("pane_div", u32(node.id)))({layout = {sizing = sz_div}, backgroundColor = cc(hot ? th.accent : th.border)}) {}
		if clay.UI(clay.ID("pane_side_b", u32(node.id)))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) do pane_tree_layout(cs, node.b)
	}
}

// One pane: its strip when the session is split (the tabs leave the title bar), its tab's bars,
// then its content (pid(p, "pane_body"): the rect its tabs are sized to) holding the
// "terminal" element its tab draws in. Every id inside is the pane's (cid, pid).
@(private = "file")
pane_layout :: proc(cs: ^Open_Session, p: ^Pane) {
	th := theme()
	old := ids_pane_begin(p)
	defer ids_pane_end(old)
	split := cs != nil && len(cs.panes) > 1
	empty := pane_term(p) == nil && pane_editor(p) == nil && pane_browser(p) == nil && pane_app(p) == nil
	if clay.UI(pid(p, "pane"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
		if split do pane_strip_layout(cs, p)
		// the tab's bars, clipped across: a bar wider than a narrow pane (its buttons, an agent's
		// strip) hides its end rather than widening the pane (a clip container has no minimum width)
		if clay.UI(pid(p, "pane_bars"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom}, clip = {horizontal = true}}) {
			claude_bars(p) // a Claude tab's held messages (ui_claude.odin)
			app_bar_layout(p) // an app tab that exited or stopped drawing (app_tab.odin)
			dead_tab_bar_layout(p) // a pi tab whose process exited: how, Restart (dead_tab.odin)
			browser_bar_layout(p) // a browser tab: Back, Forward, Reload / Stop, the URL field, Annotate (browser_nav.odin)
			changes_bars_layout(p) // a Changes tab: branch, actions, commit (ui_changes.odin)
			editor_bars_layout(p) // find, replace, go to line, changed on disk (editor_view.odin)
		}
		// a Changes tab's file list sits left of its diff (ui_changes.odin); other tabs: the pane alone
		if clay.UI(pid(p, "pane_body"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			changes_list_layout(p)
			if clay.UI(pid(p, "centre_main"))({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom}}) {
				changes_file_bar_layout(p)
				if clay.UI(pid(p, "terminal"))({
					layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom, childGap = pu(SP_2), childAlignment = {x = .Center, y = .Center}},
					backgroundColor = cc(th.bg_app),
				}) {
					if empty && cs != nil && cs.missing {
						clay.Text("Session gone", txt(th.text_secondary))
						clay.Text("Its session file or folder no longer exists", txt(th.text_muted))
						action_button(.Empty_Close, false)
					} else if b := pane_browser(p); b != nil && b.message != "" {
						clay.TextDynamic(b.message, txt(th.text_secondary))
						if b.closed_by_page do browser_reload_button() // browser.odin
					} else if empty {
						clay.Text("No session open", txt(th.text_secondary))
						clay.Text("Pick one on the left, or start a new chat", txt(th.text_muted))
						if button_enabled(.Empty_New_Chat) do action_button(.Empty_New_Chat, true)
					}
				}
				changes_more_layout(p)
			}
		}
	}
}

// A pane's own strip (the session is split): its tabs, then "+" (a new shell in it). The focused
// pane's strip has an accent line along its bottom.
@(private = "file")
pane_strip_layout :: proc(cs: ^Open_Session, p: ^Pane) {
	th := theme()
	focused := p.id == cs.focused_pane
	// clipped across like the bars: many tabs in a narrow pane never widen it
	if clay.UI(pid(p, "pane_strip"))({
		clip = {horizontal = true},
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(TAB_STRIP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(focused ? th.accent : th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		new_w := px(TOOL_BUTTON + SP_1)
		strip_tabs(cs, p, pane_width() - px(2 * SP_2) - new_w)
		hovered := ui_hover == Hit(Hit_Pane_New(p.id))
		if clay.UI(pid(p, "pane_new"))({
			layout = {sizing = {clay.SizingFixed(px(TOOL_BUTTON)), clay.SizingFixed(px(TOOL_BUTTON))}, childAlignment = {x = .Center, y = .Center}},
			backgroundColor = cc(mix(th.bg_app, th.text, hovered ? TINT_BUTTON_HOVER : 0)),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			icon(.Plus, th.text_secondary, ICON_SIZE_SM)
		}
	}
}

// The oldest pending confirmation's summary as the bar shows it: wrapped to
// the room left of its buttons, at most CONFIRM_LINES lines (the last cut
// with an ellipsis), so Cancel and Confirm always stay in the window.
@(private = "file")
confirm_text :: proc(pc: Pending_Confirmation) -> (text: string, lines: int) {
	left, _ := column_widths()
	bar_w := ui_win_w - left * app.dpi // the bar spans the centre and the right column
	used := px(2 * TERM_PAD + DOT + SP_1 + 4 * SP_2 + 4 * SP_3) + text_w("Cancel") + text_w("Confirm", WEIGHT_BOLD)
	return wrap_clip(pc.summary, max(bar_w - used, px(80)), CONFIRM_LINES)
}

// The confirmation bar's height (0 without one): one line's bar, taller
// when its summary wraps.
confirm_bar_h :: proc() -> f32 {
	if len(state.pending_confirmations) == 0 do return 0
	_, n := confirm_text(state.pending_confirmations[0])
	return max(px(BAR_H), f32(n) * text_line_height(.UI) + px(2 * SP_2))
}

// The oldest pending confirmation, as a bar above the tabs.
@(private = "file")
confirm_bar :: proc(pc: Pending_Confirmation) {
	th := theme()
	text, _ := confirm_text(pc)
	if clay.UI(clay.ID("confirm_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(confirm_bar_h())}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		dot(th.waiting)
		gap_w :: proc() {if clay.UI()({layout = {sizing = {clay.SizingFixed(px(SP_1)), clay.SizingFit()}}}) {}}
		gap_w()
		// takes the room between the dot and the buttons (clipped, should a line still be too wide)
		if clay.UI(clay.ID("confirm_text"))({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}, clip = {horizontal = true}}) {
			cfg := txt(th.text)
			cfg.wrapMode = .Newlines
			clay.TextDynamic(text, cfg)
		}
		button(clay.ID("confirm_no"), "Cancel", false, ui_hover == Hit(Hit_Cancel(pc.token)))
		button(clay.ID("confirm_yes"), "Confirm", true, ui_hover == Hit(Hit_Confirm(pc.token)))
	}
}

button :: proc(id: clay.ElementId, label: string, primary, hovered: bool) {
	th := theme()
	bg: clay.Color
	col := th.text
	h := fade(id, 0, hovered ? 1 : 0, DUR_HOVER)
	if primary {
		bg = cc(mix(th.accent, th.text, h * TINT_PRIMARY_HOVER))
		col = th.text_on_accent
	} else {
		bg = cc(mix(th.bg_elevated, th.text, TINT_BUTTON + h * (TINT_BUTTON_HOVER - TINT_BUTTON)))
	}
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(label, txt(col, primary ? WEIGHT_BOLD : WEIGHT_REGULAR))
	}
}

// The top bar: (the left column's buttons while it is hidden), the tabs of
// the open session (pi tab first, then shells; later browser, markdown, app
// tabs), "+" and its menu, the search pill, Settings, the right column's
// toggle, and the agent's button at the far right. Every tab has a close button: a pi tab's closes its
// session (with the usual confirmation).
@(private = "file")
tab_strip :: proc(cs: ^Open_Session, w: f32) {
	th := theme()
	{
		left, _ := column_widths()
		bar_compact = w - left * app.dpi < px(TOP_BAR_COMPACT_W)
		changes_button_decide(cs, w - left * app.dpi) // the "±" only where the tabs keep their room
	}
	if clay.UI(clay.ID("tabs"))({
		// left edge of the first tab lines up with the terminal's cell grid
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(TAB_STRIP_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_app),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		if !state.layout.left_open do lights_buttons(px(LIGHTS_X + LIGHTS_W + SP_2 - TERM_PAD), px(SP_2))
		if cs != nil {
			if len(cs.panes) <= 1 {
				left, _ := column_widths()
				strip_tabs(cs, nil, w - left * app.dpi - top_bar_fixed_w())
			}
			tool_button(.New_Tab)
			tool_button(.New_Menu, menu.open && menu.target == Menu_Target(Menu_New{}))
			if changes_btn_shown do changes_tab_button(cs) // "±": the checkout's changed files (ui_changes.odin; the palette has it too)
		}
		left, _ := column_widths()
		wide := search_wide(cs, w - left * app.dpi)
		spacer()
		search_pill(wide)
		spacer()
		bell_button() // the notification centre (ui_bell.odin)
		tool_button(.Settings, settings_open())
		tool_button(.Toggle_Right)
		agent_button() // far right
	}
}

// The tabs of a strip: every tab of cs (p nil: the top bar of a session with one pane) or pane p's
// (its own strip, when split), in room px. Ids are by index in cs.tabs, unique across strips.
@(private = "file")
strip_tabs :: proc(cs: ^Open_Session, p: ^Pane, room: f32) {
	th := theme()
	max_tab, squeezed := tab_max_w(cs, room, p)
	for tab, i in cs.tabs {
		if p != nil && tab.pane != p.id do continue
		id := clay.ID("tab", u32(i))
		active := p != nil ? tab.id == p.active : tab.id == cs.active_tab
		// an unfocused pane's shown tab: a quieter tint than the focused one's
		quiet := active && p != nil && p.id != cs.focused_pane
		close_id := clay.ID("tabclose", u32(i))
		close_hover := ui_hover == Hit(Hit_Close_Tab(tab.id))
		hovered := ui_hover == Hit(Hit_Tab(tab.id)) || close_hover
		bg, em := overlay(id, active && !quiet, hovered || quiet)
		ic, label, extra := tab_label(cs, tab)
		st := tab_strip_status(tab, active)
		show_dot := st != .None && st != .Exited
		dirty := editor_dirty(editor_of(tab.id))
		font: u16 = WEIGHT_REGULAR
		if et, is := tab.kind.(Editor_Tab); is && et.preview do font |= FONT_ITALIC // a preview: the next one replaces it
		// the title is cut to the widest a tab may be; a short tab is padded to TAB_MIN_W
		// squeezed: only the active tab keeps its close button (the others: ⌘W once active)
		close := !squeezed || active
		fixed := tab_fixed_w(ic, show_dot, dirty, extra, close)
		room := max_tab + (close ? tab_close_w() : 0) - fixed
		title := clip(label, room, font)
		if clay.UI(id)({
			layout = {
				sizing = {clay.SizingFit({min = px(TAB_MIN_W)}), clay.SizingFixed(px(TAB_H))},
				padding = {pu(SP_3), pu(SP_1), 0, 0},
				childGap = pu(SP_2),
				childAlignment = {y = .Center},
			},
			backgroundColor = bg,
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		}) {
			if show_dot do dot(status_color(st))
			if dirty do dot(th.text_secondary) // unsaved changes
			col := mix(th.text_secondary, th.text, em)
			if tab.status != .Running do col = th.text_muted
			if ic != .None do icon(ic, col, KIND_ICON)
			clay.TextDynamic(title, txt(col, font))
			if extra != "" do clay.TextDynamic(extra, txt(th.text_muted))
			spacer() // the close button sits at the right edge of a padded tab
			if close {
				cbg, _ := overlay(close_id, false, close_hover)
				show := max(em, f32(active ? 1 : 0))
				if clay.UI(close_id)({
					layout = {sizing = {clay.SizingFixed(px(TAB_H - SP_2)), clay.SizingFixed(px(TAB_H - SP_2))}, childAlignment = {x = .Center, y = .Center}},
					backgroundColor = cbg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				}) {
					icon(.Close, with_alpha(close_hover ? th.text : th.text_muted, show), ICON_SIZE_SM)
				}
			}
		}
	}
}

// What a tab shows: the pi tab says where its session runs (a folder and the
// project, or a bubble and "Chat"); other tabs their title. `extra`: a muted
// note (exited, not started).
tab_label :: proc(cs: ^Open_Session, tab: Tab) -> (ic: Icon, label, extra: string) {
	label = tab.title
	if _, is_pi := tab.kind.(Pi_Tab); is_pi && cs != nil && !cs.home {
		_, label = session_place(cs)
		ic = harness_icon(.Pi) // which agent (sidebar.odin: Harness); the place is in the label
	}
	ct, is_claude := tab.kind.(Claude_Tab)
	tag := ""
	if is_claude {
		ic = harness_icon(.Claude)
		// several accounts: which one (claude_accounts.odin)
		tag = claude_account_tag(ct.account)
		if tag != "" do label = fmt.tprintf("%s · %s", tab.title, tag)
	}
	// a Claude-only session's main tab: Claude and where it runs
	if cs != nil && cs.agent == .Claude && len(cs.tabs) > 0 && cs.tabs[0].id == tab.id {
		_, place := session_place(cs)
		label = tag != "" ? fmt.tprintf("Claude · %s · %s", tag, place) : fmt.tprintf("Claude · %s", place)
	}
	if is_claude {
		// what the process started with (ct.readonly); a tab not started yet: what it will start as
		if tab.status == .Not_Started {
			if claude_tab_readonly(cs, &ct) do extra = "read-only"
		} else if ct.readonly do extra = "read-only"
		else if claude_tab_readonly(cs, &ct) do extra = "read-only after restart"
	}
	if tab.status == .Exited do extra = "exited"
	if is_claude && ct.guard_stopped do extra = "read-only guard not confirmed: stopped"
	if tab.status == .Not_Started do extra = cs != nil && cs.missing ? "gone" : "not started"
	return
}

// The widest a tab may be now (its close button aside): TAB_MAX_W, less when
// the session's tabs would not fit the top bar beside its buttons (never
// under TAB_MIN_W). Squeezed: they do not fit at their natural widths; only
// the active tab keeps its close button then.
tab_max_w :: proc(cs: ^Open_Session, room: f32, p: ^Pane = nil) -> (max_w: f32, squeezed: bool) {
	if cs == nil || len(cs.tabs) == 0 do return px(TAB_MAX_W), false
	n: f32 = 0
	for tab in cs.tabs do if p == nil || tab.pane == p.id do n += 1
	if n == 0 do return px(TAB_MAX_W), false
	avail := room - n * px(SP_1)
	natural: f32 = 0
	for tab in cs.tabs {
		if p != nil && tab.pane != p.id do continue
		ic, label, extra := tab_label(cs, tab)
		natural += clamp(text_w(label) + tab_fixed_w(ic, true, false, extra), px(TAB_MIN_W), px(TAB_MAX_W))
	}
	if natural <= avail do return px(TAB_MAX_W), false
	return clamp((avail - tab_close_w()) / n, px(TAB_MIN_W), px(TAB_MAX_W)), true
}

// A narrow top bar (under TOP_BAR_COMPACT_W): the agent's button shows its
// initial without its name (set by tab_strip for the layout).
bar_compact: bool

// The top bar's width besides the tabs at their narrowest: padding, the
// buttons (the search pill as an icon), the agent's button, the gaps.
top_bar_fixed_w :: proc() -> f32 {
	w := px(2 * TERM_PAD) + 5 * px(TOOL_BUTTON + SP_1) + px(NEW_MENU_W + SP_1) + bell_extra_w()
	w += px(SP_2 + SP_3 + AVATAR - 6 + SP_2 + DOT + SP_2) // the agent's button with a dot
	if !bar_compact do w += text_w(agent_name()) + px(SP_2) // and its name
	if changes_btn_shown do w += changes_button_w(cur()) // the "±" button (ui_changes.odin), when it fits
	if !state.layout.left_open do w += px(LIGHTS_X + LIGHTS_W + SP_2 - TERM_PAD) + 2 * px(TOOL_BUTTON + SP_1) + px(SP_2)
	return w
}

// A tab's close button and the gap before it.
tab_close_w :: proc() -> f32 {return px(TAB_H - SP_2 + SP_2)}

// A tab's width besides its title: padding, icon, dots, note, close button, gaps.
tab_fixed_w :: proc(ic: Icon, show_dot, dirty: bool, extra: string, close := true) -> f32 {
	w := px(SP_3 + SP_1) + px(SP_2) // padding, the gap before the spacer
	if close do w += tab_close_w()
	if ic != .None do w += px(KIND_ICON + SP_2)
	if show_dot do w += px(DOT + SP_2)
	if dirty do w += px(DOT + SP_2)
	if extra != "" do w += text_w(extra) + px(SP_2)
	return w
}

// The top bar's agent button (also ⌘J): its initial, name and status dot,
// selected while the drawer shows. Shut, it carries the unread count and a
// gentle waiting tint while the agent needs the user (a dialog in its pi,
// from its bridge status).
@(private = "file")
agent_button :: proc() {
	th := theme()
	id := clay.ID("homebutton")
	ch := &state.agent
	if !atlas_offered() do return // Atlas runs on pi: without it, no button (harness.odin; ⌘J says why)
	needs := !state.home_open && agent_needs_user()
	bg, em := overlay(id, state.home_open, ui_hover == Hit(Hit_Home{}))
	if needs do bg = cc(mix(to_rgba(bg), with_alpha(th.waiting, 1), 0.14))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TAB_H))}, padding = {pu(SP_2), pu(SP_3), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(needs ? with_alpha(th.waiting, 0.6) : {}), width = needs ? {pu(BORDER_W), pu(BORDER_W), pu(BORDER_W), pu(BORDER_W), 0} : {}},
	}) {
		avatar(AVATAR - 6)
		if !bar_compact do clay.TextDynamic(agent_name(), txt(needs ? th.waiting : mix(th.text_secondary, th.text, em)))
		if ht := home_tab(); ht != nil && !needs {
			if st := pi_tab_status(ht^); st != .None do dot(status_color(st))
		}
		if !state.home_open && ch.unread > 0 {
			n := ch.unread > 99 ? "99+" : fmt.tprint(ch.unread)
			if clay.UI(clay.ID("agent_unread"))({
				layout = {sizing = {clay.SizingFit({min = px(BADGE_H)}), clay.SizingFixed(px(BADGE_H))}, padding = {pu(SP_1 + 1), pu(SP_1 + 1), 0, 0}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = cc(th.accent),
				cornerRadius = clay.CornerRadiusAll(px(BADGE_H / 2)),
			}) {
				clay.TextDynamic(n, {textColor = cc(th.text_on_accent), fontId = FONT_UI_SMALL | FONT_BOLD, wrapMode = .None})
			}
		}
	}
}

// The open session of a listed pi session in a project (0 = not open).
open_session_of :: proc(project_id: u64, pi_session_id: string) -> u64 {
	for s in state.open_sessions do if !s.home && s.project_id == project_id && s.pi_session_id == pi_session_id do return s.id
	return 0
}

// The tab whose panels the right column showed last (0 = none).
@(private = "file")
panels_shown: u64

// The last layout clamped the panels' offset: one more frame (ui_wants_frame clears it).
@(private = "file")
panels_clamped: bool

// Clay clamps a scroll offset only on wheel input: when the panels get shorter while scrolled
// (rows removed), the offset is clamped to the new end after the layout. Whether it moved.
@(private = "file")
panels_scroll_clamp :: proc() -> bool {
	d := clay.GetScrollContainerData(clay.ID("panels"))
	if !d.found do return false
	end := -max(d.contentDimensions.height - d.scrollContainerDimensions.height, 0)
	if d.scrollPosition.y >= end do return false
	d.scrollPosition.y = end
	return true
}

// Right column: the current session's pi tab panels, published by its
// bridge (subagents, shells, todos), as foldable sections.
@(private = "file")
right_column :: proc(cs: ^Open_Session) {
	th := theme()
	_, right := column_widths()
	col_w := right * app.dpi
	edge := th.border // the divider: highlighted while hovered or dragged
	if divider.active && divider.which == 1 do edge = th.accent
	else if d, ok := ui_hover.(Hit_Divider); ok && int(d) == 1 do edge = mix(th.border, th.accent, 0.6)
	inner_w := col_w - px(2 * SP_2) // inside the column's padding
	pt := right_panels_tab(cs) // the active Claude tab's, else pi's (claude_panels.odin)
	from_claude := false
	if pt != nil do _, from_claude = pt.kind.(Claude_Tab)
	if clay.UI(clay.ID("right"))({
		layout = {
			sizing = {clay.SizingFixed(col_w), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
			padding = {pu(SP_2), pu(SP_2), pu(SP_3), pu(SP_3)},
		},
		backgroundColor = cc(th.bg_panel),
		border = {color = cc(edge), width = {left = pu(BORDER_W)}},
	}) {
		// another tab's panels start at the top: Clay keeps the offset by element id, so the last
		// tab's would carry over (past the end of a shorter list)
		shown := pt != nil ? pt.id : 0
		if shown != panels_shown {
			panels_shown = shown
			if d := clay.GetScrollContainerData(clay.ID("panels")); d.found do d.scrollPosition^ = {}
		}
		if clay.UI(clay.ID("panels"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			if pt == nil || len(pt.panels) == 0 {
				if from_claude do empty_state("Nothing running", "Todos and subagents from Claude", inner_w)
				else do empty_state("Nothing running", RIGHT_EMPTY_HINT, inner_w)
			} else {
				for &p, i in pt.panels {
					if i > 0 do gap(SP_2)
					panel_section(&p, i, inner_w)
				}
			}
		}
	}
}

// A panel's header text and its body rows: a leading head row (pi-kit's
// "Todos 2/5") is the header text.
panel_parts :: proc(p: Panel) -> (title: string, rows: []Panel_Row) {
	rows = p.rows[:]
	title = p.title != "" ? p.title : p.id
	if len(rows) > 0 && rows[0].head {
		title = rows[0].text
		rows = rows[1:]
	}
	return
}

// Whether a panel has rows under its header (blank spacer rows aside): a
// panel without is just its header, not a fold.
panel_has_body :: proc(p: Panel) -> bool {
	_, rows := panel_parts(p)
	for r in rows do if r.text != "" do return true
	return false
}

// One panel: a header that folds it, then its rows. With no rows under the
// header (pi-kit's "Todos 3/3" with the done items hidden): the header
// alone, no fold arrow, not a toggle.
@(private = "file")
panel_section :: proc(p: ^Panel, i: int, width: f32) {
	th := theme()
	title, rows := panel_parts(p^)
	body := panel_has_body(p^)
	folded := body && panel_collapsed(p.id)
	id := clay.ID("panelhead", u32(i))
	bg, em := overlay(id, false, body && ui_hover == Hit(Hit_Panel_Head(p.id)))
	chevron := !body ? "" : folded ? "▸" : "▾"
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		col := mix(th.text_muted, th.text_secondary, em)
		room := width - px(3 * SP_2) - text_w(chevron)
		if chevron != "" do clay.TextDynamic(chevron, txt(col))
		clay.TextDynamic(clip(title, room, WEIGHT_HEADER), txt(col, WEIGHT_HEADER))
	}
	if folded || !body do return
	room := width - px(2 * SP_2)
	for r in rows {
		if r.text == "" {
			gap(SP_1)
			continue
		}
		weight: u16 = r.head ? WEIGHT_BOLD : WEIGHT_REGULAR
		if clay.UI()({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(PANEL_ROW_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		}) {
			clay.TextDynamic(clip(r.text, room, weight), txt(r.head ? th.text_secondary : tone_color(r.tone), weight))
		}
	}
}

// Panel tones onto the look's text and status colours.
@(private = "file")
tone_color :: proc(t: Panel_Tone) -> Rgba {
	th := theme()
	switch t {
	case .Normal:  return th.text
	case .Accent:  return th.running // pi-kit's accent marks running work
	case .Muted:   return th.text_secondary
	case .Dim:     return th.text_muted
	case .Warning: return th.waiting
	case .Success: return th.done
	case .Error:   return th.error
	}
	return th.text
}

// What the click at the current pointer position hit, from the last layout.
// List positions stay in here: hits carry ids.
Hit :: union {
	Hit_Project,
	Hit_Session,
	Hit_New,
	Hit_Tab,
	Hit_Close_Tab,
	Hit_Pane_New,
	Hit_Pane_Divider,
	Hit_Confirm,
	Hit_Cancel,
	Hit_Panel_Head,
	Hit_Palette_Row,
	Hit_Home,
	Hit_Close_Session,
	// left column (ui_sidebar.odin)
	Hit_Chat,
	Hit_Open_Row,
	Hit_Pin_Project,
	Hit_Pin_Session,
	Hit_New_In,
	Hit_Add_Project,
	Hit_Sort,
	Hit_Fold,
	Hit_Filter,
	Hit_Filter_Clear,
	Hit_Quick,
	Hit_Menu_Row,
	Hit_Divider,
	Hit_Waiting_Filtered,
	Hit_Agent,
	Hit_More_Project,
	Hit_More_Session,
	Hit_More_Open,
	Hit_Show_More,
	Hit_Group,
	Hit_Kids,
	Hit_Info_Session,
	Hit_New_Job_In,
	// the toolbar, settings popover, shortcuts sheet (ui_toolbar.odin)
	Hit_Button,
	Hit_Pop,
	Hit_Sheet_Close,
	Hit_Setup, // the first-run sheet (ui_setup.odin)
	Hit_Job_Sheet, // the job sheet (ui_job_sheet.odin)
	Hit_Editor_Tool, // the editor's toolbar (editor_view.odin)
	Hit_Files, // the left column's tab switch and the Files tab (ui_files.odin)
	Hit_Reload, // the hot-reload bars' buttons (ui_reload.odin)
	Hit_Claude_Reload, // Claude Code's (ui_claude_reload.odin)
	Hit_Dead_Tab, // the bar over a pi tab whose process exited (dead_tab.odin)
	Hit_Update, // the update bar's buttons (ui_update.odin)
	Hit_Comments, // the pending comments' strip, list and close prompt (ui_comments.odin)
	Hit_Claude, // a Claude tab's held messages bar (ui_claude.odin)
	Hit_Bell, // the bell's popover (ui_bell.odin)
	Hit_Jobs, // the Jobs tab (ui_jobs.odin)
	Hit_Changes, // the Changes tab and the top bar's "±" (ui_changes.odin)
}
Hit_Editor_Tool :: distinct int // button index
Hit_Project :: distinct u64 // project id
Hit_Session :: distinct string // pi session id
Hit_New :: struct {}
Hit_Tab :: distinct u64 // tab id
Hit_Close_Tab :: distinct u64 // tab id (a pi tab's closes its session)
Hit_Pane_New :: distinct u64 // a pane strip's "+": a new shell in that pane (pane id)
Hit_Pane_Divider :: distinct u64 // a divider between panes (its split's id)
Hit_Confirm :: distinct string // confirmation token
Hit_Cancel :: distinct string
Hit_Panel_Head :: distinct string // panel id: folds its section
Hit_Palette_Row :: distinct int // result index
Hit_Home :: struct {}
Hit_Close_Session :: distinct u64 // open session id
Hit_Chat :: distinct string // pi session id of a chat
Hit_Open_Row :: distinct u64 // open session id (the Open group)
Hit_Pin_Project :: distinct u64 // project id
Hit_Pin_Session :: distinct string // pi session id
Hit_New_In :: distinct u64 // project id (Chats too): a new chat there
Hit_Add_Project :: struct {}
Hit_Sort :: distinct Sort_Section
Hit_Fold :: distinct Sidebar_Fold
Hit_Filter :: struct {}
Hit_Filter_Clear :: struct {}
Hit_Quick :: distinct int // 0 running, 1 waiting, 2 pinned
Hit_Menu_Row :: distinct int
Hit_Divider :: distinct int // 0 left column's edge, 1 right column's, 2 the agent drawer's left edge
Hit_Waiting_Filtered :: struct {} // "N waiting (filtered)": clears the filter
Hit_More_Project :: distinct u64 // a row's "…": its context menu
Hit_More_Session :: distinct string // pi session id (a project's or a chat)
Hit_More_Open :: distinct u64 // open session id (the Open group)
Hit_Show_More :: distinct int // 0: the selected project's sessions, 1: Chats
Hit_Group :: distinct string // a group row of the Projects tree: its folder (opens or collapses it)
Hit_Kids :: distinct u64 // a parent row's "N folders": opens or collapses its nested rows
Hit_Info_Session :: distinct string // a session row's ⓘ: its info menu (pi session id)
Hit_New_Job_In :: distinct u64 // "New job…" under the selected project (project id)
Hit_Button :: distinct Button
Hit_Pop :: distinct Pop_Item
Hit_Sheet_Close :: struct {}

ui_hit :: proc() -> Hit {
	if palette_is_open() {
		// the palette covers everything: nothing under it is hit
		for i in palette.first ..< palette.first + PALETTE_ROWS do if clay.PointerOver(clay.ID("palrow", u32(i))) do return Hit_Palette_Row(i)
		return nil
	}
	if shortcuts_open() do return sheet_hit() // so does the shortcuts sheet
	if setup_open() do return setup_hit() // and the first-run sheet (ui_setup.odin)
	if job_sheet_open() do return job_sheet_hit() // and the job sheet (ui_job_sheet.odin)
	if settings_open() do return settings_hit() // and the settings popover
	if bell_open() do return bell_hit() // and the bell's
	if menu.open do return menu_hit() // the menu covers everything too
	if wt_menu.open do return wt_menu_hit() // and the checkout switcher's (ui_worktrees.odin)
	if h := toolbar_hit(); h != nil do return h
	// the per-tab bars below are tested with the ids of the pane under the pointer (cid)
	old_ids := ids_pane_begin(hit_pane())
	defer ids_pane_end(old_ids)
	if h := pane_hit(); h != nil do return h // a pane strip's "+" (ui_panes.odin)
	if clay.PointerOver(clay.ID("homebutton")) do return Hit_Home{}
	if state.home_open && clay.PointerOver(clay.ID("drawer")) do return drawer_hit() // nothing under the drawer is hit
	if h := empty_hit(); h != nil do return h
	if clay.PointerOver(clay.ID("new")) do return Hit_New{}
	if len(state.pending_confirmations) > 0 {
		token := state.pending_confirmations[0].token
		if clay.PointerOver(clay.ID("confirm_yes")) do return Hit_Confirm(token)
		if clay.PointerOver(clay.ID("confirm_no")) do return Hit_Cancel(token)
	}
	if h := comments_hit(); h != nil do return h
	if h := claude_hit(); h != nil do return h
	if h := update_hit(); h != nil do return h
	if h := reload_hit(); h != nil do return h
	if h := claude_reload_hit(); h != nil do return h
	if h := dead_tab_hit(); h != nil do return h
	if h := changes_hit(); h != nil do return h
	if h := editor_tool_hit(); h != nil do return h
	if h := files_hit(); h != nil do return h
	if h := jobs_hit(); h != nil do return h
	if h := sidebar_hit(); h != nil do return h
	if pt := right_panels_tab(cur()); pt != nil && state.layout.right_open {
		for p, i in pt.panels do if panel_has_body(p) && clay.PointerOver(clay.ID("panelhead", u32(i))) do return Hit_Panel_Head(p.id)
	}
	if cs := cur(); cs != nil {
		for t, i in cs.tabs do if clay.PointerOver(clay.ID("tabclose", u32(i))) do return Hit_Close_Tab(t.id)
		for t, i in cs.tabs do if clay.PointerOver(clay.ID("tab", u32(i))) do return Hit_Tab(t.id)
	}
	return nil
}

// Caret, selection and composition underline of the focused field (after
// ui_draw). Also remembers the caret for the input method's candidate window.
ui_draw_field_cursor :: proc(cmds: clay.ClayArray(clay.RenderCommand)) {
	f, text_id, _ := focused_field()
	if f == nil do return
	d := clay.GetElementData(text_id)
	if !d.found do return
	if job_sheet_open() {
		// the sheet draws its own caret and composition (multi-line fields);
		// the input method's candidate window goes under that caret
		if r, ok := job_sheet_caret_rect(cmds); ok {
			ime.caret_rect = r
			return
		}
		b := d.boundingBox
		ime.caret_rect = {b.x, b.y + b.height - text_line_height(.UI), px(CARET_W), text_line_height(.UI)}
		return
	}
	th := theme()
	b := d.boundingBox
	lh := text_line_height(.UI)
	shown, mlo, mhi := tf_display(f, ime.marked)
	if ime.marked != "" {
		x0, x1 := text_width(shown[:mlo], .UI), text_width(shown[:mhi], .UI)
		draw_rect(b.x + x0, b.y + lh - px(BORDER_W), x1 - x0, px(BORDER_W), th.text)
		xc := text_width(shown[:mlo + clamp(ime.caret, 0, mhi - mlo)], .UI)
		draw_rect(b.x + xc, b.y, max(1, px(CARET_W)), lh, th.accent)
		ime.caret_rect = {b.x + xc, b.y, px(CARET_W), lh}
		return
	}
	lo, hi := tf_selection(f)
	s := tf_text(f)
	xc, xlo, xhi := text_width(s[:f.cursor], .UI), text_width(s[:lo], .UI), text_width(s[:hi], .UI)
	if hi > lo do draw_rect(b.x + xlo, b.y, xhi - xlo, lh, th.selection)
	draw_rect(b.x + xc, b.y, max(1, px(CARET_W)), lh, th.accent)
	ime.caret_rect = {b.x + xc, b.y, px(CARET_W), lh}
}

// Byte offset in the focused field under x (framebuffer px).
field_offset_at :: proc(f: ^Text_Field, text_id: clay.ElementId, x: f32) -> int {
	d := clay.GetElementData(text_id)
	if !d.found do return len(f.buf)
	return text_offset_at(tf_text(f), x - d.boundingBox.x, .UI)
}

// The focused pane's content rect (its "terminal" element) at the last layout.
ui_terminal_rect :: proc() -> (x, y, w, h: f32, ok: bool) {
	d := clay.GetElementData(pid(focused_pane(), "terminal"))
	if !d.found do return
	b := d.boundingBox
	return b.x, b.y, b.width, b.height, true
}

// Every pane of cs from the last layout: p.rect its content container (pid(p, "pane_body")),
// p.frame the whole pane; app.centre the panes' area. A pane not laid out: {}.
ui_pane_rects :: proc(cs: ^Open_Session) {
	box :: proc(id: clay.ElementId) -> [4]f32 {
		d := clay.GetElementData(id)
		if !d.found do return {}
		b := d.boundingBox
		return {b.x, b.y, b.width, b.height}
	}
	app.centre = box(clay.ID("panes"))
	if cs == nil do return
	for &p in cs.panes {
		p.rect = box(pid(&p, "pane_body"))
		p.frame = box(pid(&p, "pane"))
	}
}

// Where pane p's tab draws: its "terminal" element (a Changes tab's diff, right of its list),
// else its content rect.
pane_draw_rect :: proc(p: ^Pane) -> [4]f32 {
	d := clay.GetElementData(pid(p, "terminal"))
	if !d.found do return pane_rect(p)
	b := d.boundingBox
	return {b.x, b.y, b.width, b.height}
}

// A filled rectangle with rounded corners, drawn as one quad per pixel row
// in the corners, with an anti-aliased edge pixel.
draw_round_rect :: proc(x, y, w, h, radius: f32, col: Rgba) {
	r := math.floor(min(radius, w / 2, h / 2))
	if r < 1 {
		draw_rect(x, y, w, h, col)
		return
	}
	draw_rect(x, y + r, w, h - 2 * r, col)
	for i in 0 ..< int(r) {
		dy := r - f32(i) - 0.5
		inset := r - math.sqrt(r * r - dy * dy)
		full := math.ceil(inset)
		edge := with_alpha(col, full - inset)
		rows := [2]f32{y + f32(i), y + h - 1 - f32(i)}
		for row_y in rows {
			draw_rect(x + full, row_y, w - 2 * full, 1, col)
			if full - inset > 0.01 {
				draw_rect(x + full - 1, row_y, 1, 1, edge)
				draw_rect(x + w - full, row_y, 1, 1, edge)
			}
		}
	}
}

// Index of the first command of an overlay element (the Home pane, the
// palette's scrim), or cmds.length: terminals are drawn between the chrome
// and the overlays (floating elements come last, by zIndex).
ui_overlay_start :: proc(cmds: clay.ClayArray(clay.RenderCommand), name: string) -> i32 {
	id := clay.ID(name).id
	for i in 0 ..< cmds.length do if cmds.internalArray[i].id == id do return i
	return cmds.length
}

// Draws Clay's commands [from, to) (inside draw_begin/draw_end).
ui_draw :: proc(cmds: clay.ClayArray(clay.RenderCommand), from, to: i32) {
	for i in from ..< to {
		cmd := &cmds.internalArray[i]
		b := cmd.boundingBox
		switch cmd.commandType {
		case .Rectangle:
			rd := cmd.renderData.rectangle
			if rd.backgroundColor.a == 0 do continue
			draw_round_rect(b.x, b.y, b.width, b.height, rd.cornerRadius.topLeft, to_rgba(rd.backgroundColor))
		case .Text:
			t := cmd.renderData.text
			col := to_rgba(t.textColor)
			if col.a == 0 do continue
			kind, bold := font_id_split(t.fontId)
			draw_text(b.x, b.y, string(t.stringContents.chars[:t.stringContents.length]), col, kind, bold, font_id_italic(t.fontId), font_id_semibold(t.fontId))
		case .Border:
			bd := cmd.renderData.border
			col := to_rgba(bd.color)
			draw_rect(b.x, b.y, b.width, f32(bd.width.top), col)
			draw_rect(b.x, b.y + b.height - f32(bd.width.bottom), b.width, f32(bd.width.bottom), col)
			draw_rect(b.x, b.y, f32(bd.width.left), b.height, col)
			draw_rect(b.x + b.width - f32(bd.width.right), b.y, f32(bd.width.right), b.height, col)
		case .ScissorStart:
			sgl.end()
			sgl.scissor_rect(i32(b.x), i32(b.y), i32(b.width), i32(b.height), true)
			sgl.begin_quads()
		case .ScissorEnd:
			sgl.end()
			sgl.scissor_rect(0, 0, 1 << 15, 1 << 15, true)
			sgl.begin_quads()
		case .Custom:
			ic, col := icon_of_command(cmd)
			draw_icon(ic, b.x, b.y, b.width, b.height, col)
		case .None, .Image, .OverlayColorStart, .OverlayColorEnd:
		}
	}
}

// The right column's empty state.
RIGHT_EMPTY_HINT :: "Subagents, shells and todos show here"
