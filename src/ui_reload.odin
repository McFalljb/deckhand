package main

// The hot-reload bars over the centre (reload.odin has the model): one for
// changed pi files ("pi settings changed — Reload N idle tabs") and one
// for a pi update ("pi updated to X — Restart N idle tabs"). Each has
// Details (which files changed, what each tab does), Later and its action.
// They replace the editor's old "reload pi" bar after saving a settings
// file: that save shows the reload bar at once.

import "core:fmt"
import "core:os"
import "core:strings"
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

// UI state: the Details lists that are open.
reload_ui: struct {
	details:         bool,
	restart_details: bool,
}

Reload_Counts :: struct {
	idle, busy, no_bridge: int, // need it, by what they can take now
	queued, reloading:     int, // the user chose it: waiting for idle, or sent
}

// The running pi tabs the reload bar (restart: the restart bar) is about.
reload_counts :: proc(restart: bool) -> (n: Reload_Counts) {
	want := restart ? Reload_Op.Restart : Reload_Op.Reload
	for &s in state.open_sessions {
		t := session_pi_tab(&s)
		if t == nil do continue
		if reload_step_is(t, restart) { 	// under way (a restarting tab is briefly not running)
			n.reloading += 1
			continue
		}
		if t.status != .Running do continue
		if t.reload.queued == want {
			n.queued += 1
			continue
		}
		if restart ? !reload_outdated(t) : !t.reload.stale do continue
		switch reload_class(t) {
		case .Idle:           n.idle += 1
		case .Busy, .Blocked: n.busy += 1
		case .No_Bridge:      n.no_bridge += 1
		}
	}
	return
}

reload_bar_shows :: proc() -> bool {
	if state.reload.dismissed do return false
	n := reload_counts(false)
	return n.idle + n.busy + n.no_bridge + n.queued + n.reloading > 0 || state.reload.from_save
}

restart_bar_shows :: proc() -> bool {
	if state.reload.restart_dismissed || state.reload.pi_version == "" do return false
	n := reload_counts(true)
	return n.idle + n.busy + n.no_bridge + n.queued + n.reloading > 0
}

// Whether a reload (restart) of this tab is under way.
reload_step_is :: proc(t: ^Tab, restart: bool) -> bool {
	#partial switch t.reload.step {
	case .Reload_Kicked, .Reload_Sent: return !restart
	case .Restart_Kicked, .Restart_Asking, .Restart_Exiting: return restart
	}
	return false
}

@(private = "file")
tabs_word :: proc(k: int) -> string {return k == 1 ? "tab" : "tabs"}

// The bar's text, and whether its action button shows.
reload_message :: proc(restart: bool) -> (msg: string, can: bool) {
	n := reload_counts(restart)
	if restart {
		head := fmt.tprintf("pi updated to %s", state.reload.pi_version)
		switch {
		case n.idle > 0:
			msg = fmt.tprintf("%s — Restart %d idle %s", head, n.idle, tabs_word(n.idle))
			if n.busy > 0 do msg = fmt.tprintf("%s · %d busy when idle", msg, n.busy)
			return msg, true
		case n.busy > 0:
			return fmt.tprintf("%s — %d busy %s restart when idle", head, n.busy, tabs_word(n.busy)), true
		case n.queued > 0:
			return fmt.tprintf("Restarting on pi %s — %d %s wait until idle", state.reload.pi_version, n.queued, tabs_word(n.queued)), false
		case n.reloading > 0:
			return fmt.tprintf("Restarting %d pi %s on pi %s…", n.reloading, tabs_word(n.reloading), state.reload.pi_version), false
		}
		return fmt.tprintf("%s — %d %s without pi-desk's bridge: restart by hand", head, n.no_bridge, tabs_word(n.no_bridge)), false
	}
	head := "pi settings changed"
	if ap := agent_prompt_path(); ap != "" && len(state.reload.changed) > 0 {
		only := true
		for p in state.reload.changed do if p != ap do only = false
		if only do head = fmt.tprintf("%s's prompt changed", agent_name())
	}
	switch {
	case n.idle > 0:
		msg = fmt.tprintf("%s — Reload %d idle %s", head, n.idle, tabs_word(n.idle))
		if n.busy > 0 do msg = fmt.tprintf("%s · %d busy when idle", msg, n.busy)
		return msg, true
	case n.busy > 0:
		return fmt.tprintf("%s — %d busy %s reload when idle", head, n.busy, tabs_word(n.busy)), true
	case n.queued > 0:
		return fmt.tprintf("Reloading pi — %d %s wait until idle", n.queued, tabs_word(n.queued)), false
	case n.reloading > 0:
		return fmt.tprintf("Reloading %d pi %s…", n.reloading, tabs_word(n.reloading)), false
	case n.no_bridge > 0:
		return fmt.tprintf("%s — %d %s without pi-desk's bridge: /reload there by hand", head, n.no_bridge, tabs_word(n.no_bridge)), false
	}
	return fmt.tprintf("%s — new pi tabs use it", head), false
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
tab_line :: proc(s: ^Open_Session, t: ^Tab, restart: bool) -> string {
	want := restart ? Reload_Op.Restart : Reload_Op.Reload
	what: string
	switch {
	case t.reload.queued == want:
		what = len(t.blockers) > 0 ? fmt.tprintf("waits for %s", t.blockers[0]) : (t.agent == .Working ? "working: when idle" : t.waiting ? "waiting for you: when idle" : "when idle")
	case reload_step_is(t, restart):
		what = restart ? "restarting" : "reloading"
	case restart ? reload_outdated(t) : t.reload.stale:
		switch reload_class(t) {
		case .Idle:      what = restart ? fmt.tprintf("idle, on pi %s", t.reload.version) : "idle"
		case .Busy:      what = t.waiting ? "waiting for you" : "working"
		case .Blocked:   what = fmt.tprintf("background work: %s", t.blockers[0])
		case .No_Bridge: what = "no status from its bridge"
		}
	case t.reload.note != "" && (restart == strings.has_prefix(t.reload.note, "restart")):
		what = t.reload.note
	case:
		return ""
	}
	return fmt.tprintf("%s — %s", session_where(s), what)
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
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
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
		t := session_pi_tab(&s)
		if t == nil || t.status != .Running do continue
		if l := tab_line(&s, t, restart); l != "" do append(&tabs, l)
	}
	if clay.UI(clay.ID(restart ? "restart_list" : "reload_list"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(TERM_PAD + DOT + SP_2), pu(TERM_PAD), pu(SP_1), pu(SP_2)}, childGap = pu(SP_1 / 2), layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
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
	case .Reload:          ui_do(Pi_Reload_All{only_changed = true})
	case .Restart:         ui_do(Pi_Restart_Updated{})
	case .Reload_Details:  reload_ui.details = !reload_ui.details
	case .Restart_Details: reload_ui.restart_details = !reload_ui.restart_details
	case .Reload_Later:
		reload_ui.details = false
		ui_do(Pi_Reload_Later{})
	case .Restart_Later:
		reload_ui.restart_details = false
		ui_do(Pi_Reload_Later{restart = true})
	}
	app.redraw = true
}
