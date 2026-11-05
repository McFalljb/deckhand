package main

// The Claude Code bars over the centre (claude_reload.odin has the model), beside pi's
// (ui_reload.odin) and in the same look: one for changed Claude files a running session reads
// only at start ("Claude Code settings changed — Restart N idle Claude tabs") and one for a
// Claude Code update ("Claude Code updated to X — Restart N idle Claude tabs"). Each has
// Details (which files changed, what each Claude tab does), Later and Restart.

import "core:fmt"
import "core:os"
import "core:strings"
import clay "../build/clay-odin"

Claude_Reload_Part :: enum u8 {
	Restart,
	Details,
	Later,
	Update_Restart,
	Update_Details,
	Update_Later,
}

Hit_Claude_Reload :: struct {
	part: Claude_Reload_Part,
}

@(private = "file")
IDS := [Claude_Reload_Part]string {
	.Restart        = "creload_go",
	.Details        = "creload_details",
	.Later          = "creload_later",
	.Update_Restart = "cupdate_go",
	.Update_Details = "cupdate_details",
	.Update_Later   = "cupdate_later",
}

// UI state: the Details lists that are open.
@(private = "file")
open_details: [2]bool // [0] settings, [1] update

// The running Claude tabs a bar is about (update: the update bar).
claude_reload_counts :: proc(update: bool) -> (n: Reload_Counts) {
	for &s in state.open_sessions {
		if s.home do continue
		for &t in s.tabs {
			if _, is := t.kind.(Claude_Tab); !is do continue
			if t.status == .Exited && restart_waiting(t.id) && strings.has_prefix(t.reload.note, "restarting") {
				n.reloading += 1
				continue
			}
			if t.status != .Running do continue
			if update ? !claude_reload_outdated(&t) : !t.reload.stale do continue
			if t.reload.queued == .Restart {
				n.queued += 1
				continue
			}
			switch claude_restart_class(&t) {
			case .Idle:           n.idle += 1
			case .Busy, .Blocked: n.busy += 1
			case .No_Bridge:      n.no_bridge += 1
			}
		}
	}
	return
}

claude_bar_shows :: proc(update: bool) -> bool {
	info := state.reload.claude
	if update {
		if info.update_dismissed || info.ident == "" do return false
	} else if info.dismissed do return false
	n := claude_reload_counts(update)
	return n.idle + n.busy + n.no_bridge + n.queued + n.reloading > 0 || (!update && info.from_save)
}

@(private = "file")
tabs_word :: proc(k: int) -> string {return k == 1 ? "tab" : "tabs"}

// The bar's text, and whether its Restart button shows.
claude_reload_message :: proc(update: bool) -> (msg: string, can: bool) {
	n := claude_reload_counts(update)
	head := "Claude Code settings changed"
	if update do head = fmt.tprintf("Claude Code updated to %s", claude_version_label(state.reload.claude.version))
	else if plugin := claude_plugin_dir(); plugin != "" && len(state.reload.claude.changed) > 0 {
		only := true
		for p in state.reload.claude.changed do if !strings.has_prefix(p, strings.concatenate({plugin, "/"}, context.temp_allocator)) do only = false
		if only do head = "Deckhand's Claude plugin changed"
	}
	switch {
	case n.idle > 0:
		msg = fmt.tprintf("%s — Restart %d idle Claude %s", head, n.idle, tabs_word(n.idle))
		if n.busy > 0 do msg = fmt.tprintf("%s · %d busy when idle", msg, n.busy)
		return msg, true
	case n.busy > 0:
		return fmt.tprintf("%s — %d busy Claude %s restart when idle", head, n.busy, tabs_word(n.busy)), true
	case n.queued > 0:
		return fmt.tprintf("Restarting Claude — %d %s wait until idle", n.queued, tabs_word(n.queued)), false
	case n.reloading > 0:
		return fmt.tprintf("Restarting %d Claude %s…", n.reloading, tabs_word(n.reloading)), false
	case n.no_bridge > 0:
		return fmt.tprintf("%s — %d Claude %s never reported its conversation: restart by hand", head, n.no_bridge, tabs_word(n.no_bridge)), false
	}
	return fmt.tprintf("%s — new Claude tabs use it", head), false
}

// ~ for the home folder.
@(private = "file")
short_path :: proc(p: string) -> string {
	h := os.get_env("HOME", context.temp_allocator)
	if h != "" && strings.has_prefix(p, h) && (len(p) == len(h) || p[len(h)] == '/') do return strings.concatenate({"~", p[len(h):]}, context.temp_allocator)
	return p
}

// What one Claude tab does about it, for Details ("" = not concerned).
@(private = "file")
tab_line :: proc(s: ^Open_Session, t: ^Tab, update: bool) -> string {
	what: string
	switch {
	case t.reload.queued == .Restart:
		what = t.reload.note != "" ? t.reload.note : "restarts when idle"
	case update ? claude_reload_outdated(t) : t.reload.stale:
		switch claude_restart_class(t) {
		case .Idle:      what = update ? fmt.tprintf("idle, on %s", claude_version_label(t.reload.version)) : "idle"
		case .Busy:      what = "busy: restarts once idle"
		case .Blocked:   what = "a subagent runs"
		case .No_Bridge: what = "never reported its conversation (its hooks did not run)"
		}
	case t.reload.note != "":
		what = t.reload.note
	case:
		return ""
	}
	return fmt.tprintf("%s · %s — %s", session_where(s), t.title, what)
}

// Both bars and their Details, at the top of the centre (ui.odin), under pi's.
claude_reload_bars :: proc() {
	if claude_bar_shows(true) do bar(true)
	if claude_bar_shows(false) do bar(false)
}

@(private = "file")
bar :: proc(update: bool) {
	th := theme()
	msg, can := claude_reload_message(update)
	go := update ? Claude_Reload_Part.Update_Restart : .Restart
	details := update ? Claude_Reload_Part.Update_Details : .Details
	later := update ? Claude_Reload_Part.Update_Later : .Later
	open := open_details[update ? 1 : 0]
	labels := [3]string{open ? "Hide details" : "Details", "Later", "Restart"}
	used := px(2 * TERM_PAD + DOT + 2 * SP_2)
	for l, i in labels do if i < 2 || can do used += text_w(l, i == 2 ? WEIGHT_BOLD : WEIGHT_REGULAR) + px(2 * SP_3 + SP_2)
	if clay.UI(clay.ID(update ? "claude_update_bar" : "claude_reload_bar"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		dot(update ? th.done : th.accent)
		clay.TextDynamic(clip(msg, max(centre_width() - used, px(80))), txt(th.text))
		spacer()
		button(clay.ID(IDS[details]), labels[0], false, ui_hover == Hit(Hit_Claude_Reload{details}))
		button(clay.ID(IDS[later]), labels[1], false, ui_hover == Hit(Hit_Claude_Reload{later}))
		if can do button(clay.ID(IDS[go]), labels[2], true, ui_hover == Hit(Hit_Claude_Reload{go}))
	}
	if open do details_list(update)
}

@(private = "file")
details_list :: proc(update: bool) {
	th := theme()
	lines := make([dynamic]string, context.temp_allocator)
	if !update {
		ch := state.reload.claude.changed[:]
		for p, i in ch {
			if i == RELOAD_DETAIL_ROWS {
				append(&lines, fmt.tprintf("+%d more", len(ch) - i + state.reload.claude.changed_more))
				break
			}
			append(&lines, short_path(p))
		}
		if len(ch) <= RELOAD_DETAIL_ROWS && state.reload.claude.changed_more > 0 do append(&lines, fmt.tprintf("+%d more", state.reload.claude.changed_more))
	}
	tabs := make([dynamic]string, context.temp_allocator)
	for &s in state.open_sessions {
		if s.home do continue
		for &t in s.tabs {
			if _, is := t.kind.(Claude_Tab); !is || t.status != .Running do continue
			if l := tab_line(&s, &t, update); l != "" do append(&tabs, l)
		}
	}
	if clay.UI(clay.ID(update ? "claude_update_list" : "claude_reload_list"))({
		layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}, padding = {pu(TERM_PAD + DOT + SP_2), pu(TERM_PAD), pu(SP_1), pu(SP_2)}, childGap = pu(SP_1 / 2), layoutDirection = .TopToBottom},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		room := centre_width() - px(2 * TERM_PAD + DOT + SP_2)
		if len(lines) > 0 {
			clay.Text("Changed (read when Claude starts)", txt(th.text_secondary, FONT_UI_SMALL))
			for l in lines do clay.TextDynamic(clip(l, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
		}
		if len(tabs) > 0 {
			clay.Text("Claude tabs (each resumes its conversation; its background work stops)", txt(th.text_secondary, FONT_UI_SMALL))
			for l, i in tabs {
				if i == RELOAD_DETAIL_ROWS {
					clay.TextDynamic(fmt.tprintf("+%d more", len(tabs) - i), txt(th.text_muted, FONT_UI_SMALL))
					break
				}
				clay.TextDynamic(clip(l, room, FONT_UI_SMALL), txt(th.text_muted, FONT_UI_SMALL))
			}
		}
		if len(lines) == 0 && len(tabs) == 0 do clay.Text("No Claude tab is running", txt(th.text_muted, FONT_UI_SMALL))
	}
}

claude_reload_hit :: proc() -> Hit {
	for id, part in IDS do if clay.PointerOver(clay.ID(id)) do return Hit_Claude_Reload{part}
	return nil
}

claude_reload_tip :: proc(h: Hit_Claude_Reload) -> (label, keys: string) {
	switch h.part {
	case .Restart:        return "Restart the idle Claude tabs (each resumes its conversation; background work stops); busy ones once idle", ""
	case .Update_Restart: return "Restart the idle Claude tabs on the new Claude Code (each resumes its conversation); busy ones once idle", ""
	case .Details:        return open_details[0] ? "Hide the list" : "Which files changed, and what each Claude tab does", ""
	case .Update_Details: return open_details[1] ? "Hide the list" : "Which Claude tabs run an older Claude Code", ""
	case .Later:          return "Hide this until the next change (stops waiting restarts)", ""
	case .Update_Later:   return "Hide this until the next Claude Code update (stops waiting restarts)", ""
	}
	return "", ""
}

// A click on a bar's button (main.odin).
claude_reload_click :: proc(h: Hit_Claude_Reload) {
	switch h.part {
	case .Restart:        ui_do(Claude_Restart_Changed{})
	case .Update_Restart: ui_do(Claude_Restart_Changed{update = true})
	case .Details:        open_details[0] = !open_details[0]
	case .Update_Details: open_details[1] = !open_details[1]
	case .Later:
		open_details[0] = false
		ui_do(Claude_Reload_Later{})
	case .Update_Later:
		open_details[1] = false
		ui_do(Claude_Reload_Later{update = true})
	}
	app.redraw = true
}
