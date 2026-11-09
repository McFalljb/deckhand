package core

// A Claude tab's status for any setup (docs/CLAUDE.md §5a): what Deckhand can tell when Claude Code
// gives it less than the newest version does.
//
//   - Dots from the hooks. Claude Code reports its own status (OSC 7501) from v2.1.295; an older or
//     pinned one does not, but its hooks still say when a turn starts, waits and ends
//     (claude.turn). Until OSC 7501 is seen in the tab's process (tab.prog), its dot comes from the
//     hooks' turn (tab_status_view, agent_status.odin) and a turn that ends while the user looks
//     elsewhere leaves the unseen dot and a bell entry, as OSC 7501's done does
//     (claude_status_turn).
//   - Background work never changes the dot, the unseen dot or the bell, on either path: a turn
//     that ends with a dev server still running is a finished turn (its question or error dot
//     shows; the bell rings). The Background panel shows what runs; the restart confirmation names
//     it and a claude_wait_idle result lists it (pi's blockers likewise feed only its reload
//     confirmation).
//   - "Hooks not running". Every feed of the plugin is a hook. When `disableAllHooks` is set, a
//     managed `allowManagedHooksOnly` blocks Deckhand's plugin, or the plugin does not load, a
//     Claude tab reports nothing: no session id (a new one is not saved and cannot resume), no
//     comments, no held texts, empty panels. When no hook has reported a turn in this run of the
//     tab (a restored tab's saved session id does not count) CLAUDE_HOOKS_GRACE after Claude's
//     prompt came up (bracketed paste on, or its OSC 7501 other than blocked), a bar over the tab
//     says so and names the causes. A startup dialog (folder trust, login) can also have
//     bracketed paste on and hooks only run after it: the bar cannot tell those apart, so it waits
//     the grace and says to answer such a dialog first. A read-only tab has its own, stricter
//     check (it is stopped: claude_readonly_tick).
//   - A minimum-version hint. The version the tab started with (claude_reload.odin: where `claude`
//     links to, by stat; never run). Below CLAUDE_MIN_VERSION a bar says what is missing and how
//     to update; an unknown layout ("a new build") gets none.
//
// The bars (ui_claude.odin) are the user's: Dismiss hides the hooks bar for that run of the tab
// and the version bar for that version (saved in <data>/claude-hints.json).

import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

CLAUDE_HOOKS_GRACE :: 20 * time.Second
CLAUDE_MIN_VERSION :: "2.1.295" // OSC 7501 program status and hooks' onFailure (read-only chats)
CLAUDE_HINTS_FILE :: "claude-hints.json"

@(private = "file")
Status_Rt :: struct {
	up:        time.Tick, // Claude's prompt first came up in this run ({} = not yet)
	start:     u64, // the run it belongs to (claude_wait.odin's start count)
	dismissed: bool, // the hooks bar, for this run
	silent:    bool, // the bar was due at the last tick (a redraw when it becomes due)
}

@(private = "file")
status_rt: map[u64]Status_Rt
@(private = "file")
version_dismissed: string // the version whose hint the user dismissed (saved)
@(private = "file")
hints_loaded: bool

// Tests: nothing left from an earlier test.
claude_status_reset :: proc() {
	clear(&status_rt)
	delete(version_dismissed)
	version_dismissed = ""
	hints_loaded = false
}

// <data>/claude-hints.json (home_root: "" in unit tests unless one sets it: nothing saved then).
@(private = "file")
hints_path :: proc() -> string {
	d := update_data_dir()
	return d != "" ? strings.concatenate({strings.trim_right(d, "/"), "/", CLAUDE_HINTS_FILE}, context.temp_allocator) : ""
}

@(private = "file")
hints_load :: proc() {
	if hints_loaded do return
	hints_loaded = true
	p := hints_path()
	if p == "" do return
	data, err := os.read_entire_file(p, context.temp_allocator)
	if err != nil do return
	v, jerr := jg.parse(data, .JSON, allocator = context.temp_allocator) // hints_save writes it
	o, ok := v.(json.Object)
	if jerr != nil || !ok do return
	if s, sok := o["version_dismissed"].(json.String); sok && len(s) <= 40 {
		delete(version_dismissed)
		version_dismissed = strings.clone(s)
	}
}

@(private = "file")
hints_save :: proc() {
	p := hints_path()
	if p == "" do return
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"version_dismissed":`)
	json_quote(&b, version_dismissed)
	strings.write_string(&b, "}\n")
	if e := write_atomic(p, strings.to_string(b)); e != "" do fmt.eprintln("Deckhand: could not save", p, ":", e)
}

// This run's record of a tab (a restart starts a new one).
@(private = "file")
rt_of :: proc(tab_id: u64) -> ^Status_Rt {
	run := claude_wait_run(tab_id)
	if r, has := &status_rt[tab_id]; has && r.start == run do return r
	status_rt[tab_id] = {start = run}
	return &status_rt[tab_id]
}

// Frame upkeep (claude_wait_tick): when each running Claude tab's prompt first came up, and a
// redraw when a hooks bar becomes due.
claude_status_tick :: proc(now := time.Tick{}) {
	now := now == {} ? time.tick_now() : now
	for &s in state.open_sessions do for &tab in s.tabs {
		ct, is := &tab.kind.(Claude_Tab)
		if !is || tab.status != .Running do continue
		r := rt_of(tab.id)
		if r.up == {} {
			t := term_of(tab.id)
			up := t != nil && t.running && mode_on(t, 2004)
			if v := tab_status_view(tab); v.source == .Osc7501 && v.state != .Blocked do up = true
			if up do r.up = now
		}
		silent := claude_hooks_silent(&tab, now)
		if silent != r.silent {
			r.silent = silent
			window_state_changed()
		}
	}
	gone := make([dynamic]u64, context.temp_allocator)
	for id in status_rt do if _, tab, _ := find_tab(id); tab == nil do append(&gone, id)
	for id in gone do delete_key(&status_rt, id)
}

// Whether a running Claude tab's hooks never reported in this run: no turn (SessionStart's
// hook always reports one), CLAUDE_HOOKS_GRACE after its prompt came up. Read-only tabs have
// their own check.
claude_hooks_silent :: proc(tab: ^Tab, now := time.Tick{}) -> bool {
	if replica_process do return tab.live.claude_quiet // the core's (Tab_Live)
	ct, is := &tab.kind.(Claude_Tab)
	if !is || tab.status != .Running || ct.readonly || ct.turn != .Unknown do return false
	r, has := status_rt[tab.id]
	if !has || r.start != claude_wait_run(tab.id) || r.up == {} do return false
	now := now == {} ? time.tick_now() : now
	return time.tick_diff(r.up, now) >= CLAUDE_HOOKS_GRACE
}

// Whether version v is a known version below min (dotted numbers; a suffix such as -beta.1 is
// ignored). Anything else ("", "build:…", another scheme): false, no hint.
claude_version_below :: proc(v, min: string) -> bool {
	parse :: proc(s: string) -> (n: [3]int, ok: bool) {
		core := s
		if i := strings.index_any(core, "-+"); i >= 0 do core = core[:i]
		parts := strings.split(core, ".", context.temp_allocator)
		if len(parts) != 3 do return {}, false
		for p, i in parts {
			if p == "" || len(p) > 6 do return {}, false
			x := 0
			for c in transmute([]u8)p {
				if c < '0' || c > '9' do return {}, false
				x = x * 10 + int(c - '0')
			}
			n[i] = x
		}
		return n, true
	}
	a, ok_a := parse(v)
	b, ok_b := parse(min)
	if !ok_a || !ok_b do return false
	for i in 0 ..< 3 do if a[i] != b[i] do return a[i] < b[i]
	return false
}

// How to update Claude Code for where `claude` links to (claude_version_of's layouts): the harness
// manifest's command for that layout (harness_manifest.odin); "" for nix, mise and yarn (their
// package manager's own way); the native installer's command for a layout nobody knows.
claude_update_command :: proc(real: string) -> string {
	r, _ := harness_row("claude")
	return harness_update_bare(r, install_layout(.Claude, real, ""), real)
}

// How the version bar says to update: the command, or ("" = none) the package manager's job.
claude_update_how :: proc(cmd: string) -> string {
	if cmd == "" do return "Update it with the package manager that installed it (nix, mise)"
	return fmt.tprintf("Update it: %s", cmd)
}

// The update command for the `claude` new tabs start.
claude_update_command_now :: proc() -> string {
	b := claude_binary_path()
	if b == "" do return "claude update"
	real := fs_real(b)
	return claude_update_command(real != "" ? real : b)
}

// The version a tab's Claude Code started with, when it is old ("" = new enough or unknown).
@(private = "file")
old_version :: proc(tab: ^Tab) -> string {
	v := tab.reload.version
	if !claude_version_below(v, CLAUDE_MIN_VERSION) do return ""
	return v
}

// The bar over a Claude tab ("" = none): its hooks never reported, else its Claude Code is older
// than Deckhand's minimum.
claude_status_message :: proc(tab: ^Tab, now := time.Tick{}) -> string {
	if tab == nil do return ""
	if _, is := tab.kind.(Claude_Tab); !is || tab.status != .Running do return ""
	old := old_version(tab)
	if claude_hooks_silent(tab, now) {
		if !replica_process && rt_of(tab.id).dismissed do return ""
		why := "`disableAllHooks` in your Claude settings, or your organisation's managed `allowManagedHooksOnly`"
		if old != "" do why = fmt.tprintf("Claude Code %s (older than %s), %s", old, CLAUDE_MIN_VERSION, why)
		return fmt.tprintf("Deckhand's Claude Code hooks aren't running here (likely %s; or a startup dialog is still open: answer it first): a new session is not saved and can't resume; comments, held messages and panels don't work", why)
	}
	if old != "" {
		hints_load()
		if version_dismissed == old do return ""
		return fmt.tprintf("Claude Code %s is older than %s: status comes from Deckhand's hooks only and read-only chats can't start. %s", old, CLAUDE_MIN_VERSION, claude_update_how(claude_update_command_now()))
	}
	return ""
}

// The bar's Dismiss: the hooks bar for this run of the tab, the version bar for that version
// (saved: it stays hidden after a relaunch until another old version shows).
claude_status_dismiss :: proc(tab: ^Tab, now := time.Tick{}) {
	if tab == nil do return
	window_state_changed()
	if replica_process do return // the core's runtime is in the other process (separate core: in-process only)
	if claude_hooks_silent(tab, now) {
		rt_of(tab.id).dismissed = true
		return
	}
	old := old_version(tab)
	if old == "" do return
	hints_load()
	delete(version_dismissed)
	version_dismissed = strings.clone(old)
	hints_save()
}

// claude.turn (claude.odin). A Stop's idle that came without a background snapshot ends the
// unconfirmed launches (claude_panels.odin), on either path. For a tab whose Claude Code
// reports no OSC 7501: a turn that starts clears the unseen dot; one that ends (idle or error,
// not idle_prompt) while the user looks elsewhere leaves it, with a bell entry; a dialog makes
// one too. Background work changes none of it. True when the tab's look changed.
claude_status_turn :: proc(s: ^Open_Session, tab: ^Tab, was: Claude_Turn, st: string, idle_prompt: bool) -> bool {
	if tab.status != .Running do return false
	changed := st == "idle" && !idle_prompt && claude_work_turn_end(tab)
	if s == nil || s.home || tab.prog.state != .None do return changed
	switch st {
	case "submitted":
		if !tab.unseen do return changed
		tab.unseen = false
		return true
	case "waiting":
		if was != .Waiting do notify_session(s, tab, .Waiting, tab_shown = true)
	case "idle", "error":
		if idle_prompt || was != .Working do return changed
		if !status_on_screen(s, tab.id) do tab.unseen = true
		notify_session(s, tab, st == "error" ? .Error : .Finished, tab_shown = true)
		return true
	}
	return changed
}

// The dot's fallback (tab_status_view): a running Claude tab whose process never reported OSC
// 7501 gets its dot from the hooks' turn.
claude_status_dot :: proc(tab: Tab, dot: Row_Status) -> Row_Status {
	ct, is := tab.kind.(Claude_Tab)
	if !is || tab.status != .Running || tab.prog.state != .None || dot != .None do return dot
	#partial switch ct.turn {
	case .Working: return .Running
	case .Waiting: return .Waiting
	}
	return dot
}

// The snapshot's fields for a Claude tab (claude_tab_json): counts only, never Claude's text.
claude_status_tab_json :: proc(b: ^strings.Builder, tab: Tab) {
	tab := tab
	if n := claude_background_running(tab.id); n > 0 do fmt.sbprintf(b, `,"background":%d`, n)
	if claude_hooks_silent(&tab) do strings.write_string(b, `,"hooks":"silent"`)
	if v := old_version(&tab); v != "" {
		strings.write_string(b, `,"claude_version_old":`)
		json_quote(b, v)
	}
}

// The hooks banner was dismissed for this tab (tab_live_tick).
claude_status_dismissed :: proc(tab_id: u64) -> bool {
	r, has := status_rt[tab_id]
	return has && r.dismissed
}
