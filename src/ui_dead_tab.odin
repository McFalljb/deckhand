package main

// The bar over a dead pi or Claude tab, its hits and tips (the window's; moved from
// dead_tab.odin, which keeps the restarts).

import "core:fmt"
import "core:strings"
import "core"
import clay "../build/clay-odin"

// ---- the bar over a dead pi tab (ui.odin's centre) ----

Dead_Part :: enum u8 {
	Restart,
	Restart_Model,
}

Hit_Dead_Tab :: struct {
	part: Dead_Part,
}

@(private = "file")
DEAD_IDS := [Dead_Part]string {
	.Restart       = "dead_restart",
	.Restart_Model = "dead_restart_model",
}

@(private = "file")
DEAD_LABELS := [Dead_Part]string {
	.Restart       = "Restart",
	.Restart_Model = "Restart with model…",
}
@(private = "file")
DEAD_MODEL_SHORT :: "Model…" // the narrow bar's

// The tab pane p shows when it is a dead pi or Claude tab (Home is the
// drawer's, with its own "stopped").
@(private = "file")
dead_shown :: proc(p: ^core.Pane) -> ^core.Tab {
	s := core.cur()
	if s == nil || s.home do return nil
	tab := core.pane_shown(p)
	if !core.tab_is_dead(tab) do return nil
	return tab
}

dead_tab_bar_layout :: proc(p: ^core.Pane) {
	th := theme()
	// a restart waiting for the old process: said, no buttons
	if s := core.cur(); s != nil && !s.home {
		if tab := core.pane_shown(p); tab != nil && tab.status == .Exited && core.restart_waiting(tab.id) {
			if clay.UI(cid("dead_bar"))({
				clip = {horizontal = true}, // its pane's width at most (bar_w)
				layout = {sizing = {bar_w(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_elevated),
				border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
			}) {
				dot(th.text_muted)
				_, is_claude := tab.kind.(core.Claude_Tab)
				clay.TextDynamic(clip(is_claude ? "Restarting: waiting for the old Claude to exit…" : "Restarting: waiting for the old pi to exit…", max(pane_width() - px(2 * TERM_PAD + DOT + SP_2), px(40))), txt(th.text))
			}
			return
		}
	}
	// its process runs on in a holder that stopped answering: said, no Restart (a second copy)
	if s := core.cur(); s != nil && !s.home {
		if tab := core.pane_shown(p); tab != nil && tab.status == .Exited && core.tab_held_away(tab) != 0 {
			if clay.UI(cid("dead_bar"))({
				clip = {horizontal = true},
				layout = {sizing = {bar_w(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
				backgroundColor = cc(th.bg_elevated),
				border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
			}) {
				dot(th.text_muted)
				clay.TextDynamic(clip(core.HELD_AWAY_TEXT, max(pane_width() - px(2 * TERM_PAD + DOT + SP_2), px(40))), txt(th.text))
			}
			return
		}
	}
	tab := dead_shown(p)
	if tab == nil do return
	failed := core.exit_failed(tab.exit)
	model := core.dead_tab_offers_model(tab) // "Restart with model…"
	msg := core.dead_tab_tip(tab)
	if failed do msg = strings.concatenate({msg, " — its last output is below"}, context.temp_allocator)
	// a narrow centre: the short label, so both buttons keep their text
	model_label := DEAD_LABELS[.Restart_Model]
	buttons_w :: proc(model_label: string, model: bool) -> f32 {
		w := text_w(DEAD_LABELS[.Restart], WEIGHT_BOLD) + px(2 * SP_3 + SP_2)
		if model do w += text_w(model_label) + px(2 * SP_3 + SP_2)
		return w
	}
	fixed := px(2 * TERM_PAD + DOT + 2 * SP_2)
	if model && pane_width() - fixed - buttons_w(model_label, model) < px(80) do model_label = DEAD_MODEL_SHORT
	room := max(pane_width() - fixed - buttons_w(model_label, model), px(40))
	if clay.UI(cid("dead_bar"))({
		clip = {horizontal = true}, // its pane's width at most (bar_w)
		layout = {sizing = {bar_w(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		dot(failed ? th.error : th.text_muted)
		clay.TextDynamic(clip(msg, room), txt(th.text))
		spacer()
		if model do button(cid(DEAD_IDS[.Restart_Model]), model_label, false, ui_hover == Hit(Hit_Dead_Tab{.Restart_Model}))
		button(cid(DEAD_IDS[.Restart]), DEAD_LABELS[.Restart], true, ui_hover == Hit(Hit_Dead_Tab{.Restart}))
	}
}

dead_tab_hit :: proc() -> Hit {
	if dead_shown(hit_pane()) == nil do return nil // the bar of the pane under the pointer (ui_panes.odin)
	for id, part in DEAD_IDS do if clay.PointerOver(cid(id)) do return Hit_Dead_Tab{part}
	return nil
}

dead_tab_tip_for :: proc(h: Hit_Dead_Tab) -> (label, keys: string) {
	if tab := dead_shown(hit_pane()); tab != nil {
		if _, is := tab.kind.(core.Claude_Tab); is {
			if h.part == .Restart_Model do return "Start Claude Code again, resuming its conversation, then pick another model (/model)", ""
			return "Start Claude Code again in this tab, resuming its conversation", ""
		}
	}
	switch h.part {
	case .Restart:       return "Start pi again in this tab, on the same session", ""
	case .Restart_Model: return "Start pi again on the same session, then pick another model in pi's selector", ""
	}
	return "", ""
}

dead_tab_click :: proc(p: ^core.Pane, h: Hit_Dead_Tab) {
	tab := dead_shown(p)
	if tab == nil do return
	if _, is := tab.kind.(core.Claude_Tab); is do ui_do(core.Claude_Restart{tab_id = tab.id, pick_model = h.part == .Restart_Model})
	else do ui_do(core.Pi_Restart{tab_id = tab.id, pick_model = h.part == .Restart_Model})
	if state.focus_widget != "" do ui_do(core.Set_Focus{""}) // the keyboard goes to the new pi
	app.redraw = true
}

// A dead pi or Claude tab's tooltip (its tab, its Open row): how it ended. "" = none.
dead_tab_hover_tip :: proc(tab: ^core.Tab) -> string {
	if !core.tab_is_dead(tab) do return ""
	return fmt.tprintf("%s — open it again to restart", core.dead_tab_tip(tab))
}
