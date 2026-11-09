package main

// The bell in the top bar (left of the gear) and its popover: the
// notification centre's entries (notify.odin), newest first, grouped Today
// and Earlier. The button shows the unread count; a click opens the popover
// (focus widget "notifications"). An entry shows an icon for what happened,
// what happened, where (project · session) and how long ago; a click
// focuses that session's tab (reopens a closed session) and marks it read.
// "Mark all read" and "Clear" in its header. Nothing animates: relative
// times are as of the last redraw.

import "core:fmt"
import "core:sys/posix"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Bell_Hit_What :: enum {
	Row, // an entry (id)
	Mark_All,
	Clear,
}
Hit_Bell :: struct {
	what: Bell_Hit_What,
	id:   u64, // Row: the entry
}

bell_open :: proc() -> bool {return state.focus_widget == "notifications"}

// UI state: the keyboard's row and what the last layout showed.
bell: struct {
	selected: int, // index into rows, -1 = none
	opened:   bool, // open in the last layout (the selection resets on open)
	rows:     [core.NOTICES_MAX]u64, // entry ids in display order
	n:        int,
}

// ---- the button ----

// The unread count beside the bell, when there is one ("" = none).
@(private = "file")
bell_count :: proc() -> string {
	n := core.notices_unread()
	if n == 0 do return ""
	return n > 99 ? "99+" : fmt.tprint(n)
}

// The button's width beyond a square tool button (the count's pill; a
// compact top bar shows a dot on the bell instead).
bell_extra_w :: proc() -> f32 {
	c := bell_count()
	if c == "" || bar_compact do return 0
	return max(text_w(c, FONT_UI_SMALL | FONT_BOLD) + px(2 * (SP_1 + 1)), px(BADGE_H)) + px(SP_1 + SP_1 + SP_1)
}

bell_button :: proc() {
	th := theme()
	id := clay.ID(BUTTONS[.Bell].element)
	count := bell_count()
	dot_only := count != "" && bar_compact
	if dot_only do count = ""
	bg, em := overlay(id, bell_open(), ui_hover == Hit(Hit_Button(.Bell)))
	pad: u16 = count != "" ? pu(SP_1 + 2) : 0
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit({min = px(TOOL_BUTTON)}), clay.SizingFixed(px(TOOL_BUTTON))}, padding = {pad, count != "" ? pu(SP_1) : 0, 0, 0}, childGap = pu(SP_1), childAlignment = {x = .Center, y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		icon(.Bell, mix(th.text_muted, th.text, count != "" || dot_only ? 1 : em), ICON_SIZE)
		if dot_only {
			d := px(DOT + 1)
			if clay.UI(clay.ID("bell_dot"))({
				layout = {sizing = {clay.SizingFixed(d), clay.SizingFixed(d)}},
				backgroundColor = cc(th.accent),
				cornerRadius = clay.CornerRadiusAll(d / 2),
				floating = {attachTo = .Parent, offset = {px(TOOL_BUTTON) - d - px(3), px(3)}, zIndex = 1, pointerCaptureMode = .Passthrough},
			}) {}
		}
		if count != "" {
			if clay.UI(clay.ID("bell_badge"))({
				layout = {sizing = {clay.SizingFit({min = px(BADGE_H)}), clay.SizingFixed(px(BADGE_H))}, padding = {pu(SP_1 + 1), pu(SP_1 + 1), 0, 0}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = cc(th.accent),
				cornerRadius = clay.CornerRadiusAll(px(BADGE_H / 2)),
			}) {
				clay.TextDynamic(count, {textColor = cc(th.text_on_accent), fontId = FONT_UI_SMALL | FONT_BOLD, wrapMode = .None})
			}
		}
	}
}

// ---- the popover ----

// The local calendar day of t (comparable, not a date).
@(private = "file")
local_day :: proc(t: time.Time) -> int {
	secs := posix.time_t(t._nsec / 1_000_000_000)
	tm: posix.tm
	if posix.localtime_r(&secs, &tm) == nil do return 0
	return int(tm.tm_year) * 400 + int(tm.tm_yday)
}

// "now", "5m", "3h", "2d" (temp).
bell_ago :: proc(at: time.Time) -> string {
	m := int(time.duration_minutes(time.diff(at, core.notice_now())))
	switch {
	case m < 1:       return "now"
	case m < 60:      return fmt.tprintf("%dm", m)
	case m < 24 * 60: return fmt.tprintf("%dh", m / 60)
	}
	return fmt.tprintf("%dd", m / (24 * 60))
}

@(private = "file")
kind_icon :: proc(k: core.Notice_Kind) -> (core.Icon, core.Rgba) {
	th := theme()
	switch k {
	case .Finished:      return .Check, th.done
	case .Waiting:       return .Chat, th.waiting
	case .Error:         return .Alert, th.error
	case .Exited:        return .Close, th.error
	case .Job_Finished:  return .Clock, th.done
	case .Job_Needs_You: return .Clock, th.waiting
	case .Job_Failed:    return .Clock, th.error
	}
	return .None, th.text_muted
}

// An entry's two lines: what happened, then where (temp).
@(private = "file")
entry_lines :: proc(n: core.Notice) -> (what, where_: string) {
	what = core.notice_label(n)
	if n.job_id != "" {
		return fmt.tprintf("%s: %s", what, n.title), n.summary
	}
	if n.place != "" do return what, fmt.tprintf("%s · %s", n.place, n.title)
	return what, n.title
}

@(private = "file")
head_button :: proc(what: Bell_Hit_What, name, label: string) {
	th := theme()
	id := clay.ID(name)
	bg, em := overlay(id, false, ui_hover == Hit(Hit_Bell{what = what}))
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(CHIP_SMALL_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
	}) {
		clay.TextDynamic(label, txt(mix(th.text_secondary, th.text, em), FONT_UI_SMALL))
	}
}

bell_layout :: proc(w, h: f32) {
	if !bell_open() {
		bell.opened = false
		return
	}
	if !bell.opened do bell.selected = -1
	bell.opened = true
	th := theme()
	box_w := min(px(BELL_POP_W), w - px(2 * SP_2))
	x, y := w - box_w - px(SP_2), px(TAB_STRIP_H)
	if d := clay.GetElementData(clay.ID(BUTTONS[.Bell].element)); d.found {
		b := d.boundingBox
		x, y = b.x + b.width - box_w, b.y + b.height + px(SP_1)
	}
	// over the right column it covers the column's width (as the gear's
	// popover), so nothing there shows half-covered beside it
	if d := clay.GetElementData(clay.ID("right")); d.found && state.layout.right_open && x + box_w > d.boundingBox.x {
		b := d.boundingBox
		box_w = min(max(box_w, b.width - px(2 * SP_2)), w - px(2 * SP_2))
		x = b.x + b.width - px(SP_2) - box_w
	}
	x = clamp(x, px(SP_2), max(w - box_w - px(SP_2), 0))
	items := state.notices.items[:]
	unread := core.notices_unread()
	head_h := px(HEADER_H + SP_1)
	// the list: its groups and rows, as tall as fits under the bar
	today := local_day(core.notice_now())
	content: f32 = 0
	groups := 0
	last := -1
	#reverse for n in items {
		g := local_day(n.at) == today ? 0 : 1
		if g != last {
			groups += 1
			last = g
		}
	}
	content = f32(groups) * px(BELL_GROUP_H) + f32(len(items)) * (px(BELL_ROW_H) + px(2))
	room := h - y - px(SP_4) - head_h - px(2 * PAD_OVERLAY + core.BORDER_W + 4)
	list_h := clamp(content, 0, max(room, px(BELL_ROW_H)))
	inner_w := box_w - px(2 * PAD_OVERLAY)
	bell.n = 0
	if clay.UI(clay.ID("bell_pop"))({
		layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFit()}, layoutDirection = .TopToBottom, padding = clay.PaddingAll(pu(PAD_OVERLAY)), childGap = pu(2)},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD + SP_1)),
		border = {color = cc(th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {x, y}, zIndex = 8},
	}) {
		overlay_shadow("bell_shadow", 8)
		if clay.UI(clay.ID("bell_head"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(head_h)}, padding = {pu(SP_2), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}},
		}) {
			clay.TextDynamic("Notifications", txt(th.text, WEIGHT_BOLD))
			spacer()
			if unread > 0 do head_button(.Mark_All, "bell_markall", "Mark all read")
			if len(items) > 0 do head_button(.Clear, "bell_clear", "Clear")
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(core.BORDER_W))}}, backgroundColor = cc(th.border)}) {}
		if len(items) == 0 {
			empty_state("No notifications", "Sessions you are not looking at report here", inner_w)
			return
		}
		if clay.UI(clay.ID("bell_list"))({
			layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(list_h)}, layoutDirection = .TopToBottom, childGap = pu(2)},
			clip = {vertical = true, childOffset = clay.GetScrollOffset()},
		}) {
			last = -1
			row_room := inner_w - px(2 * SP_2 + DOT + ICON_SIZE_SM + 3 * SP_2)
			#reverse for n in items {
				g := local_day(n.at) == today ? 0 : 1
				if g != last {
					last = g
					if clay.UI(clay.ID("bell_group", u32(g)))({
						layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BELL_GROUP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Bottom}},
					}) {
						clay.TextDynamic(g == 0 ? "Today" : "Earlier", txt(th.text_muted, FONT_UI_SMALL | WEIGHT_HEADER))
					}
				}
				i := bell.n
				bell.rows[i] = n.id
				bell.n += 1
				rid := clay.ID("bellrow", u32(i))
				bg, em := overlay(rid, false, ui_hover == Hit(Hit_Bell{what = .Row, id = n.id}) || bell.selected == i)
				ic, icol := kind_icon(n.kind)
				what, where_ := entry_lines(n)
				ago := bell_ago(n.at)
				room := row_room - text_w(ago, FONT_UI_SMALL)
				if clay.UI(rid)({
					layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BELL_ROW_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
					backgroundColor = bg,
					cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
				}) {
					// unread: an accent dot; read: its room stays
					if clay.UI()({
						layout = {sizing = {clay.SizingFixed(px(DOT)), clay.SizingFixed(px(DOT))}},
						backgroundColor = cc(n.read ? {} : th.accent),
						cornerRadius = clay.CornerRadiusAll(px(DOT / 2)),
					}) {}
					icon(ic, n.read ? with_alpha(icol, 0.7) : icol, ICON_SIZE_SM)
					if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, layoutDirection = .TopToBottom, childGap = pu(2)}}) {
						weight: u16 = n.read ? WEIGHT_REGULAR : WEIGHT_BOLD
						clay.TextDynamic(clip(what, room, weight), txt(n.read ? mix(th.text_secondary, th.text, em) : th.text, weight))
						if where_ != "" do clay.TextDynamic(clip(where_, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
					}
					clay.TextDynamic(ago, txt(th.text_muted, FONT_UI_SMALL))
				}
			}
		}
	}
}

bell_hit :: proc() -> Hit {
	if clay.PointerOver(clay.ID("bell_markall")) do return Hit_Bell{what = .Mark_All}
	if clay.PointerOver(clay.ID("bell_clear")) do return Hit_Bell{what = .Clear}
	if clay.PointerOver(clay.ID("bell_list")) {
		for i in 0 ..< bell.n do if clay.PointerOver(clay.ID("bellrow", u32(i))) do return Hit_Bell{what = .Row, id = bell.rows[i]}
	}
	if clay.PointerOver(clay.ID(BUTTONS[.Bell].element)) do return Hit_Button(.Bell)
	return nil
}

bell_tip :: proc(h: Hit_Bell) -> (label, keys: string) {
	switch h.what {
	case .Mark_All: return "Mark every notification read", ""
	case .Clear:    return "Remove every notification", ""
	case .Row:
		for n in state.notices.items do if n.id == h.id {
			if n.job_id != "" do return "", ""
			return core.find_session(n.session) != nil ? "Go to this session" : "Open this session again", ""
		}
	}
	return "", ""
}

// An entry clicked (or Enter on it): it is read; its session's tab shows
// (a closed session opens again); the popover closes. Jobs have nothing to
// open yet (their tab will).
bell_activate :: proc(id: u64) {
	ui_do(core.Notifications_Mark_Read{id = id})
	ui_do(core.Set_Focus{""})
	for n in state.notices.items {
		if n.id != id do continue
		if n.session == 0 do return
		if s := core.find_session(n.session); s != nil {
			if _, t, _ := find_tab(n.tab_id); t != nil {
				ui_do(core.Focus_Tab{tab_id = n.tab_id})
				// its pi exited: it starts again, as opening the session does (dead_tab.odin)
				if t == core.session_pi_tab(s) && core.tab_is_dead(t) do ui_do(core.Pi_Restart{tab_id = t.id})
				// a Claude tab that exited: Claude starts again (not while it is still not found)
				if _, is := t.kind.(core.Claude_Tab); is && core.tab_is_dead(t) && (!core.exit_not_found(t.exit) || core.claude_installed_now()) do ui_do(core.Claude_Restart{tab_id = t.id})
			} else do ui_do(core.Focus_Session{session = s.id, reopen = true})
		} else if n.pi_session_id != "" && core.find_project(n.project_id) != nil {
			ui_do(core.Open_Session_Cmd{project_id = n.project_id, pi_session_id = n.pi_session_id})
		}
		return
	}
}

@(private = "file")
bell_click :: proc(h: Hit_Bell) {
	switch h.what {
	case .Row:      bell_activate(h.id)
	case .Mark_All: ui_do(core.Notifications_Mark_Read{all = true})
	case .Clear:    ui_do(core.Notifications_Clear{})
	}
}

// Input while the popover is open: it takes everything but shortcuts. Up
// and Down move, Enter opens, Esc or a click outside (or on the bell) closes.
bell_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .KEY_DOWN:
		app.redraw = true
		if e.modifiers & sapp.MODIFIER_SUPER != 0 {
			ui_do(core.Set_Focus{""}) // a shortcut closes it and runs as usual
			return false
		}
		#partial switch e.key_code {
		case .ESCAPE: ui_do(core.Set_Focus{""})
		case .UP:     if bell.n > 0 do bell.selected = bell.selected <= 0 ? bell.n - 1 : bell.selected - 1
		case .DOWN, .TAB:
			if bell.n > 0 do bell.selected = (bell.selected + 1) %% bell.n
		case .ENTER, .KP_ENTER, .SPACE:
			if bell.selected >= 0 && bell.selected < bell.n do bell_activate(bell.rows[bell.selected])
		}
		return true
	case .MOUSE_MOVE:
		set_hover(chrome_hit({e.mouse_x, e.mouse_y}), false)
		return true
	case .MOUSE_DOWN:
		h := chrome_hit({e.mouse_x, e.mouse_y})
		if b, ok := h.(Hit_Bell); ok do bell_click(b)
		else do ui_do(core.Set_Focus{""}) // outside (or the bell again): closes
		app.redraw = true
		return true
	case .MOUSE_SCROLL:
		clay.SetPointerState({e.mouse_x, e.mouse_y}, false)
		clay.UpdateScrollContainers(false, {e.scroll_x, e.scroll_y} * SCROLL_STEP * app.dpi, 1.0 / 60)
		app.redraw = true
		return true
	case .KEY_UP, .CHAR, .CLIPBOARD_PASTED, .MOUSE_UP:
		return true
	}
	return false
}
