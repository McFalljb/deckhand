package core

// The hot-reload bars' model (reload.odin, claude_reload.odin): which running tabs a bar is about
// and what it says. The native window draws them over the centre (ui_reload.odin,
// ui_claude_reload.odin); a browser gets the same text in its status strip (web_bars.odin).

import "core:fmt"
import "core:strings"

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
	if state.reload.restart_dismissed do return false
	n := reload_counts(true)
	return n.idle + n.busy + n.no_bridge + n.queued + n.reloading > 0
}

@(private = "file")
tabs_word :: proc(k: int) -> string {return k == 1 ? "tab" : "tabs"}

// The bar's text, and whether its action button shows.
reload_message :: proc(restart: bool) -> (msg: string, can: bool) {
	n := reload_counts(restart)
	if restart {
		version := restart_on_version() // else only the pi extensions changed
		head := version ? fmt.tprintf("pi updated to %s", state.reload.pi_version) : "pi extensions changed"
		on := version ? fmt.tprintf(" on pi %s", state.reload.pi_version) : ""
		switch {
		case n.idle > 0:
			msg = fmt.tprintf("%s — Restart %d idle %s", head, n.idle, tabs_word(n.idle))
			if n.busy > 0 do msg = fmt.tprintf("%s · %d busy when idle", msg, n.busy)
			return msg, true
		case n.busy > 0:
			return fmt.tprintf("%s — %d busy %s restart when idle", head, n.busy, tabs_word(n.busy)), true
		case n.queued > 0:
			return fmt.tprintf("Restarting%s — %d %s wait until idle", on != "" ? on : " pi tabs", n.queued, tabs_word(n.queued)), false
		case n.reloading > 0:
			return fmt.tprintf("Restarting %d pi %s%s…", n.reloading, tabs_word(n.reloading), on), false
		}
		return fmt.tprintf("%s — %d %s without Deckhand's bridge: restart by hand", head, n.no_bridge, tabs_word(n.no_bridge)), false
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
		return fmt.tprintf("%s — %d %s without Deckhand's bridge: /reload there by hand", head, n.no_bridge, tabs_word(n.no_bridge)), false
	}
	return fmt.tprintf("%s — new pi tabs use it", head), false
}

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
