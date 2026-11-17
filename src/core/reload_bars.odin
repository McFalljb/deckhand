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

// The running Claude tabs a bar is about (update: the update bar; harness .Codex: the Codex bar,
// which has no update bar).
claude_reload_counts :: proc(update: bool, harness := Harness.Claude) -> (n: Reload_Counts) {
	codex := harness_is_codex(harness)
	if codex && update do return
	for &s in state.open_sessions {
		if s.home || s.machine != 0 do continue // another machine's tabs are its core's
		for &t in s.tabs {
			if ct, is := t.kind.(Claude_Tab); !is || t.machine != 0 || harness_is_codex(ct.harness) != codex do continue
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

claude_bar_shows :: proc(update: bool, harness := Harness.Claude) -> bool {
	if harness_is_codex(harness) {
		info := state.reload.codex
		if update || info.dismissed do return false
		n := claude_reload_counts(false, .Codex)
		return n.idle + n.busy + n.no_bridge + n.queued + n.reloading > 0 || info.from_save
	}
	info := state.reload.claude
	if update {
		if info.update_dismissed || info.ident == "" do return false
	} else if info.dismissed do return false
	n := claude_reload_counts(update)
	return n.idle + n.busy + n.no_bridge + n.queued + n.reloading > 0 || (!update && info.from_save)
}

// A tab of the Claude bar (update: the update bar) whose waiting restart is held only by
// subagents silent for hours (the note: claude_reload.odin busy_why), and that silence ("a
// subagent silent for 2h 05m"): the bar offers Restart anyway for it (the window's, a browser's).
claude_reload_silent_tab :: proc(update: bool) -> (tab: ^Tab, why: string) {
	for &s in state.open_sessions {
		if s.home do continue
		for &t in s.tabs {
			if ct, is := t.kind.(Claude_Tab); !is || harness_is_codex(ct.harness) || t.status != .Running || t.reload.queued != .Restart do continue
			if update ? !claude_reload_outdated(&t) : !t.reload.stale do continue
			i := strings.index(t.reload.note, CLAUDE_SILENT_NOTE)
			if i < 0 do continue
			return &t, strings.trim_right(t.reload.note[i:], ")")
		}
	}
	return nil, ""
}

// The bar's text, and whether its Restart button shows.
claude_reload_message :: proc(update: bool, harness := Harness.Claude) -> (msg: string, can: bool) {
	if harness_is_codex(harness) do return codex_reload_message()
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

// The Codex bar's text (changed Codex files a running Codex reads only at start), and whether its
// Restart button shows.
codex_reload_message :: proc() -> (msg: string, can: bool) {
	n := claude_reload_counts(false, .Codex)
	head := "Codex settings changed"
	switch {
	case n.idle > 0:
		msg = fmt.tprintf("%s — Restart %d idle Codex %s", head, n.idle, tabs_word(n.idle))
		if n.busy > 0 do msg = fmt.tprintf("%s · %d busy when idle", msg, n.busy)
		return msg, true
	case n.busy > 0:
		return fmt.tprintf("%s — %d busy Codex %s restart when idle", head, n.busy, tabs_word(n.busy)), true
	case n.queued > 0:
		return fmt.tprintf("Restarting Codex — %d %s wait until idle", n.queued, tabs_word(n.queued)), false
	case n.reloading > 0:
		return fmt.tprintf("Restarting %d Codex %s…", n.reloading, tabs_word(n.reloading)), false
	case n.no_bridge > 0:
		// no conversation yet (SessionStart comes with the first prompt), or hooks not running
		one := n.no_bridge == 1
		return fmt.tprintf("%s — %d Codex %s %s no conversation yet: new settings apply when you restart %s", head, n.no_bridge, tabs_word(n.no_bridge), one ? "has" : "have", one ? "it" : "them"), false
	}
	return fmt.tprintf("%s — new Codex tabs use it", head), false
}
