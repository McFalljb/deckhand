package main

// The USAGE section at the foot of the Sessions tab (docs/GUIDE.md "Usage"): each coding-agent
// account's plan limits as its agent reports them (core/usage.odin). Unfolded: a row per account,
// its name and the read's age, then one bar per limit window (5h, wk) with its percent and reset
// time. Folded: one line per account, its fullest window. A bar is amber from 80% and red from 95%
// or a limit hit; the percent is always written, so colour is never the only signal. A read over
// an hour old fades; a window whose reset passed says "reset at 15:40, no new data". The hover
// has the plan, every window, credits, the source and the account's home.
//
// The rows come from core.usage_rows, so a full Usage page (a later step) draws the same.

import "core:fmt"
import clay "../build/clay-odin"
import "core"

USAGE_BAR_W :: 64 // logical px at most; narrower in a narrow column
USAGE_BAR_MIN_W :: 28
USAGE_BAR_H :: 6
USAGE_LINE_H :: 20 // a bar's line
USAGE_LABEL_W :: 22 // "5h", "wk"
USAGE_STALE_ALPHA :: 0.5 // a read over an hour old

// The USAGE section was drawn unfolded in the last layout (client_facts' usage_visible: the core
// reads usage only then). ui_layout clears it; usage_section sets it.
usage_section_shown: bool

// What client_facts sends as usage_visible: the section drawn unfolded in the last layout, its
// header inside the list's visible part (not scrolled out of it), and the column still showing it.
usage_visible_now :: proc() -> bool {
	if !usage_section_shown do return false
	// and still so now: a layout made before a change (the Files tab, the column closed) while
	// frames were stopped must not say so for a frame
	if !state.layout.left_open || state.layout.left_tab != .Sessions || state.sidebar.view != .Projects || state.sidebar.folded[.Usage] do return false
	head := clay.GetElementData(clay.ID("navhead", u32(core.Sidebar_Fold.Usage)))
	nav := clay.GetElementData(clay.ID("nav"))
	if !head.found || !nav.found do return false
	h, n := head.boundingBox, nav.boundingBox
	return h.y < n.y + n.height && h.y + h.height > n.y
}

// The section (nothing while no account has usage to show: Codex not installed).
usage_section :: proc(text_w_max: f32) {
	if len(state.usage) == 0 do return
	rows := core.usage_rows(state.usage, core.usage_now())
	gap(GAP_SECTION)
	usage_header(len(rows))
	folded := state.sidebar.folded[.Usage]
	usage_section_shown = !folded
	for r, i in rows {
		if folded do usage_line(r, i, text_w_max)
		else do usage_row_full(r, i, text_w_max)
	}
}

@(private = "file")
usage_header :: proc(n: int) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, childAlignment = {y = .Center}}}) {
		label_id := clay.ID("navhead", u32(core.Sidebar_Fold.Usage))
		hit := Hit(Hit_Fold(core.Sidebar_Fold.Usage))
		_, em := overlay(label_id, false, ui_hover == hit)
		folded := state.sidebar.folded[.Usage]
		if clay.UI(label_id)({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(HEADER_H))}, padding = {pu(PAD_ROW), pu(SP_1), 0, 0}, childGap = pu(SP_1), childAlignment = {y = .Center}}}) {
			col := mix(th.text_muted, th.text_secondary, em)
			clay.Text("USAGE", txt(col, FONT_UI_SMALL | WEIGHT_HEADER))
			a := fade(label_id, 7, folded || ui_hover == hit ? 1 : 0, DUR_HOVER)
			icon(folded ? .Chevron_Right : .Chevron_Down, with_alpha(col, a), ICON_SIZE_SM - 2)
		}
	}
}

// A bar's colour by its level.
@(private = "file")
usage_level_col :: proc(l: core.Usage_Level) -> core.Rgba {
	th := theme()
	switch l {
	case .Warn: return th.waiting
	case .Full: return th.error
	case .Normal:
	}
	return th.accent
}

// The text colour of a percent: the bar's for a warning or a full one, else the body's.
@(private = "file")
usage_pct_col :: proc(l: core.Usage_Level) -> core.Rgba {
	return l == .Normal ? theme().text_secondary : usage_level_col(l)
}

// The folded section's line: "Work   5h 82% · 4m ago".
@(private = "file")
usage_line :: proc(r: core.Usage_Row, i: int, text_w_max: f32) {
	th := theme()
	id := clay.ID("usagerow", u32(i))
	bg, _ := overlay(id, false, ui_hover == Hit(Hit_Usage_Row(i)))
	k: f32 = r.stale ? USAGE_STALE_ALPHA : 1
	if clay.UI(id)(row_cfg(bg)) {
		line := r.line
		lw := text_w(line, FONT_UI_SMALL)
		title_room := max(text_w_max - lw - px(GAP_INLINE), px(40))
		if title_room < text_w(r.title) && text_w_max - px(40 + GAP_INLINE) < lw do line = clip(line, max(text_w_max - px(40 + GAP_INLINE), px(20)), FONT_UI_SMALL)
		clay.TextDynamic(clip(r.title, title_room), txt(with_alpha(th.text, k)))
		spacer()
		col := th.text_muted
		if r.fullest >= 0 do col = usage_pct_col(r.bars[r.fullest].level)
		clay.TextDynamic(line, txt(with_alpha(col, k), FONT_UI_SMALL))
	}
}

// The unfolded row: the account's name and age, then each window's bar (or what it says instead).
@(private = "file")
usage_row_full :: proc(r: core.Usage_Row, i: int, text_w_max: f32) {
	th := theme()
	id := clay.ID("usagerow", u32(i))
	bg, _ := overlay(id, false, ui_hover == Hit(Hit_Usage_Row(i)))
	k: f32 = r.stale ? USAGE_STALE_ALPHA : 1
	if clay.UI(id)({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(PAD_ROW), pu(PAD_ROW), pu(SP_1), pu(SP_1)}, layoutDirection = .TopToBottom},
		backgroundColor = bg,
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		// the name, and how old the numbers are
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(USAGE_LINE_H))}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
			age := r.reading ? "reading…" : r.age
			aw := age != "" ? text_w(age, FONT_UI_SMALL) + px(GAP_INLINE) : 0
			clay.TextDynamic(clip(r.title, max(text_w_max - aw, px(20))), txt(with_alpha(th.text, k)))
			spacer()
			if age != "" do clay.TextDynamic(age, txt(with_alpha(th.text_muted, k), FONT_UI_SMALL))
		}
		if r.note != "" { // in place of bars, or with them ("limit reached")
			col := len(r.bars) > 0 ? th.error : th.text_muted
			if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(USAGE_LINE_H))}, childAlignment = {y = .Center}}}) {
				clay.TextDynamic(clip(r.note, text_w_max), txt(with_alpha(col, k), FONT_UI_SMALL))
			}
		}
		for b in r.bars do usage_bar_line(b, text_w_max, k)
	}
}

// One window: "5h [████░░░░] 42%  resets 15:40". A narrow column drops the reset time first,
// then narrows the bar; the percent always shows.
@(private = "file")
usage_bar_line :: proc(b: core.Usage_Bar, text_w_max: f32, k: f32) {
	th := theme()
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(USAGE_LINE_H))}, childGap = pu(GAP_INLINE), childAlignment = {y = .Center}}}) {
		label_w := max(px(USAGE_LABEL_W), text_w(b.label, FONT_UI_SMALL))
		if clay.UI()({layout = {sizing = {clay.SizingFixed(label_w), clay.SizingFit()}}}) {
			clay.TextDynamic(b.label, txt(with_alpha(th.text_muted, k), FONT_UI_SMALL))
		}
		if b.passed {
			clay.TextDynamic(clip(b.note, max(text_w_max - label_w - px(GAP_INLINE), px(20)), FONT_UI_SMALL), txt(with_alpha(th.text_muted, k), FONT_UI_SMALL))
			return
		}
		pct := b.percent >= 0 ? fmt.tprintf("%d%%", b.percent) : "?"
		pw := text_w("100%", FONT_UI_SMALL)
		room := text_w_max - label_w - pw - 2 * px(GAP_INLINE)
		reset := b.reset
		rw := reset != "" ? text_w(reset, FONT_UI_SMALL) + px(GAP_INLINE) : 0
		bar_w := min(px(USAGE_BAR_W), room - rw)
		if bar_w < px(USAGE_BAR_MIN_W) {
			reset, rw = "", 0
			bar_w = min(px(USAGE_BAR_W), room)
		}
		if bar_w >= px(USAGE_BAR_MIN_W) / 2 {
			if clay.UI()({
				layout = {sizing = {clay.SizingFixed(bar_w), clay.SizingFixed(px(USAGE_BAR_H))}},
				backgroundColor = cc(with_alpha(th.border, k)),
				cornerRadius = clay.CornerRadiusAll(px(USAGE_BAR_H / 2)),
			}) {
				fill := b.percent > 0 ? bar_w * f32(min(b.percent, 100)) / 100 : 0
				if fill > 0 {
					if clay.UI()({
						layout = {sizing = {clay.SizingFixed(max(fill, px(USAGE_BAR_H))), clay.SizingGrow()}},
						backgroundColor = cc(with_alpha(usage_level_col(b.level), k)),
						cornerRadius = clay.CornerRadiusAll(px(USAGE_BAR_H / 2)),
					}) {}
				}
			}
		}
		if clay.UI()({layout = {sizing = {clay.SizingFixed(pw), clay.SizingFit()}, childAlignment = {x = .Right}}}) {
			clay.TextDynamic(pct, txt(with_alpha(usage_pct_col(b.level), k), FONT_UI_SMALL))
		}
		if reset != "" do clay.TextDynamic(reset, txt(with_alpha(th.text_muted, k), FONT_UI_SMALL))
	}
}

// The hover of a usage row (ui_toolbar.odin hit_tip).
usage_row_tip :: proc(i: int) -> string {
	if i < 0 || i >= len(state.usage) do return ""
	return core.usage_tip(state.usage[i], core.usage_now())
}

// Which usage row is under the pointer (sidebar_hit).
usage_hit :: proc() -> Hit {
	for _, i in state.usage do if clay.PointerOver(clay.ID("usagerow", u32(i))) do return Hit_Usage_Row(i)
	return nil
}
