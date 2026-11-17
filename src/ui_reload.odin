package main

// The hot-reload bars over the centre (reload.odin has the model): one for
// changed pi files ("pi settings changed — Reload N idle tabs") and one
// for a pi update ("pi updated to X — Restart N idle tabs") or changed pi
// extensions ("pi extensions changed — …", Settings: pi_integration.odin). Each has
// Details (which files changed, what each tab does), Later and its action.
// They replace the editor's old "reload pi" bar after saving a settings
// file: that save shows the reload bar at once.

import "core:fmt"
import "core:os"
import "core:strings"
import "core"
import clay "../build/clay-odin"

Reload_Part :: enum u8 {
	Reload,
	Reload_Details,
	Reload_Later,
	Restart,
	Restart_Details,
	Restart_Later,
}

Hit_Reload :: struct {
	part: Reload_Part,
}

RELOAD_IDS := [Reload_Part]string {
	.Reload          = "reload_go",
	.Reload_Details  = "reload_details",
	.Reload_Later    = "reload_later",
	.Restart         = "restart_go",
	.Restart_Details = "restart_details",
	.Restart_Later   = "restart_later",
}

RELOAD_DETAIL_ROWS :: 6 // files and tabs each in Details; the rest counted

// The bars' model is the core's (reload_bars.odin): a browser shows the same text.
Reload_Counts :: core.Reload_Counts
reload_counts :: core.reload_counts
reload_bar_shows :: core.reload_bar_shows
restart_bar_shows :: core.restart_bar_shows
reload_message :: core.reload_message

// UI state: the Details lists that are open.
reload_ui: struct {
	details:         bool,
	restart_details: bool,
}

// ~ for the home folder.
@(private = "file")
short_path :: proc(p: string) -> string {
	h := os.get_env("HOME", context.temp_allocator)
	if h != "" && strings.has_prefix(p, h) && (len(p) == len(h) || p[len(h)] == '/') do return strings.concatenate({"~", p[len(h):]}, context.temp_allocator)
	return p
}

// What one pi tab does about it, for Details ("" = not concerned).
@(private = "file")
tab_line :: proc(s: ^core.Open_Session, t: ^core.Tab, restart: bool) -> string {
	want := restart ? core.Reload_Op.Restart : core.Reload_Op.Reload
	what: string
	switch {
	case t.reload.queued == want:
		what = len(t.blockers) > 0 ? fmt.tprintf("waits for %s", t.blockers[0]) : (t.agent == .Working ? "working: when idle" : t.waiting ? "waiting for you: when idle" : "when idle")
	case core.reload_step_is(t, restart):
		what = restart ? "restarting" : "reloading"
	case restart ? core.reload_outdated(t) : t.reload.stale:
		switch core.reload_class(t) {
		case .Idle:      what = restart ? (core.reload_version_outdated(t) ? fmt.tprintf("idle, on pi %s", t.reload.version) : "idle, started with other pi extensions") : "idle"
		case .Busy:      what = t.waiting ? "waiting for you" : "working"
		case .Blocked:   what = fmt.tprintf("background work: %s", t.blockers[0])
		case .No_Bridge: what = "no status from its bridge"
		}
	case t.reload.note != "" && (restart == strings.has_prefix(t.reload.note, "restart")):
		what = t.reload.note
	case:
		return ""
	}
	return fmt.tprintf("%s — %s", core.session_where(s), what)
}

// Both bars and their Details, at the top of the centre (ui.odin).
reload_bars :: proc() {
	if restart_bar_shows() do bar(true)
	if reload_bar_shows() do bar(false)
}

@(private = "file")
bar :: proc(restart: bool) {
	th := theme()
	msg, can := reload_message(restart)
	go := restart ? Reload_Part.Restart : .Reload
	details := restart ? Reload_Part.Restart_Details : .Reload_Details
	later := restart ? Reload_Part.Restart_Later : .Reload_Later
	open := restart ? reload_ui.restart_details : reload_ui.details
	labels := [3]string{open ? "Hide details" : "Details", "Later", restart ? "Restart" : "Reload"}
	used := px(2 * TERM_PAD + DOT + 2 * SP_2)
	for l, i in labels do if i < 2 || can do used += text_w(l, i == 2 ? WEIGHT_BOLD : WEIGHT_REGULAR) + px(2 * SP_3 + SP_2)
	if clay.UI(clay.ID(restart ? "restart_bar" : "reload_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		dot(restart ? th.done : th.accent)
		clay.TextDynamic(clip(msg, max(centre_width() - used, px(80))), txt(th.text))
		spacer()
		button(clay.ID(RELOAD_IDS[details]), labels[0], false, ui_hover == Hit(Hit_Reload{details}))
		button(clay.ID(RELOAD_IDS[later]), labels[1], false, ui_hover == Hit(Hit_Reload{later}))
		if can do button(clay.ID(RELOAD_IDS[go]), labels[2], true, ui_hover == Hit(Hit_Reload{go}))
	}
	if open do details_list(restart)
}

@(private = "file")
details_list :: proc(restart: bool) {
	th := theme()
	lines := make([dynamic]string, context.temp_allocator)
	if !restart {
		ch := state.reload.changed[:]
		for p, i in ch {
			if i == RELOAD_DETAIL_ROWS {
				append(&lines, fmt.tprintf("+%d more files", len(ch) - i + state.reload.changed_more))
				break
			}
			append(&lines, short_path(p))
		}
		if len(ch) <= RELOAD_DETAIL_ROWS && state.reload.changed_more > 0 do append(&lines, fmt.tprintf("+%d more files", state.reload.changed_more))
	}
	tabs := make([dynamic]string, context.temp_allocator)
	for &s in state.open_sessions {
		t := core.session_pi_tab(&s)
		if t == nil || t.status != .Running do continue
		if l := tab_line(&s, t, restart); l != "" do append(&tabs, l)
	}
	if clay.UI(clay.ID(restart ? "restart_list" : "reload_list"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(TERM_PAD + DOT + SP_2), pu(TERM_PAD), pu(SP_1), pu(SP_2)}, childGap = pu(SP_1 / 2), layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(core.BORDER_W)}},
	}) {
		room := centre_width() - px(2 * TERM_PAD + DOT + SP_2)
		if len(lines) > 0 {
			clay.Text("Changed", txt(th.text_secondary, FONT_UI_SMALL))
			for l in lines do clay.TextDynamic(clip(l, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		}
		if len(tabs) > 0 {
			clay.Text("pi tabs", txt(th.text_secondary, FONT_UI_SMALL))
			for l, i in tabs {
				if i == RELOAD_DETAIL_ROWS {
					clay.TextDynamic(fmt.tprintf("+%d more", len(tabs) - i), txt(th.text_muted, FONT_UI_SMALL))
					break
				}
				clay.TextDynamic(clip(l, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		if len(lines) == 0 && len(tabs) == 0 do clay.Text("No pi tab is running", txt(th.text_muted, FONT_UI_SMALL))
	}
}

reload_hit :: proc() -> Hit {
	for id, part in RELOAD_IDS do if clay.PointerOver(clay.ID(id)) do return Hit_Reload{part}
	return nil
}

reload_tip :: proc(h: Hit_Reload) -> (label, keys: string) {
	switch h.part {
	case .Reload:          return "Reload the idle pi tabs now (/reload; sessions stay); busy ones once idle", ""
	case .Restart:         return "Restart the idle pi tabs on the new pi (same session); busy ones once idle", ""
	case .Reload_Details:  return reload_ui.details ? "Hide the list" : "Which files changed, and what each pi tab does", ""
	case .Restart_Details: return reload_ui.restart_details ? "Hide the list" : "Which pi tabs run an older pi", ""
	case .Reload_Later:    return "Hide this until the next change (stops waiting reloads)", ""
	case .Restart_Later:   return "Hide this until the next pi update (stops waiting restarts)", ""
	}
	return "", ""
}

// A click on a bar's button (main.odin).
reload_click :: proc(h: Hit_Reload) {
	switch h.part {
	case .Reload:          ui_do(core.Pi_Reload_All{only_changed = true})
	case .Restart:         ui_do(core.Pi_Restart_Updated{})
	case .Reload_Details:  reload_ui.details = !reload_ui.details
	case .Restart_Details: reload_ui.restart_details = !reload_ui.restart_details
	case .Reload_Later:
		reload_ui.details = false
		ui_do(core.Pi_Reload_Later{})
	case .Restart_Later:
		reload_ui.restart_details = false
		ui_do(core.Pi_Reload_Later{restart = true})
	}
	app.redraw = true
}
