package main

// Hot reload (ROADMAP G11). pi reads its settings, extensions, skills,
// prompts, themes and context files (AGENTS.md…) when it starts or on
// /reload, and its own code only when it starts. pi-desk watches those
// files and offers, in a bar over the centre (ui_reload.odin):
//
//   "pi settings changed — Reload N idle tabs"   pi_reload_all {only_changed}:
//        idle pi tabs get pi.reload now; working, waiting or blocked ones
//        (background shells or workers that /reload would stop: the
//        bridge's blockers, which the confirmation lists) are queued and
//        reloaded when they report idle with no blockers.
//   "pi updated to X — Restart N idle tabs"       pi_restart_updated: the
//        pi package on disk has another version than a tab started with
//        (or "pi extensions changed": the user turned an optional extension
//        of Deckhand's pi integration on or off since: pi_integration.odin);
//        idle tabs start again on their session (`pi --session <file>`),
//        busy ones are queued the same way.
//
// Later hides a bar until the next change (or version) and drops what was
// queued. A save in the editor of a file pi reads shows the bar at once,
// also with nothing to reload ("new pi tabs use this").
//
// What is watched (reload_build), each with the pi tabs it affects:
//   every pi tab  the agent dir's config, context and system-prompt files,
//                 its extensions/, skills/, prompts/, themes/ (and where
//                 their top-level symlinks lead), and the local packages
//                 and resource paths its settings.json lists; Deckhand's
//                 own pi integration (pi_integration.odin)
//   a folder      a pi tab's cwd/.pi (config files, the four resource
//                 folders, local packages of its settings.json), and the
//                 context files (AGENTS.override.md, AGENTS.md, CLAUDE.md)
//                 in the cwd and each folder above it: the tabs at or below
//   Atlas         its prompt file (ATLAS.md)
// Folders go to the editor's FSEvents watcher (editor_watch.odin); files,
// and the folders' own stamps, to a stat poll every RELOAD_POLL. Nothing
// is watched or polled while no pi tab runs. Changes are reported after
// RELOAD_DEBOUNCE without another one (Reload_Watch, internal). Only
// settings.json and package.json files are read; credential files are never
// read or listed (settings_credential).
//
// pi's version: the pi package's package.json, found once by a worker from
// `command -v pi` in a login shell (as pi tabs start pi), or
// PI_DESK_PI_PACKAGE (tests). Each pi tab records the version on disk when
// it is first seen running (Tab.reload.version).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

RELOAD_DEBOUNCE :: 1 * time.Second
RELOAD_POLL :: 2 * time.Second
RELOAD_CHANGED_MAX :: 50 // files listed in Details; the rest are counted
RELOAD_DIRS_MAX :: 64
RELOAD_FILES_MAX :: 512
RELOAD_SCOPE_ATLAS :: "@atlas" // a scope: only Atlas's tab
RELOAD_NOTE_MAX :: 160

// What the user asked for a pi tab that was not idle then.
Reload_Op :: enum u8 {
	None,
	Reload,
	Restart,
}
RELOAD_OP_NAMES := [Reload_Op]string {
	.None    = "",
	.Reload  = "reload",
	.Restart = "restart",
}

// What is under way for a pi tab: one queue entry gives one kick, one
// pi.reload or one restart.
Reload_Step :: enum u8 {
	None,
	Reload_Kicked, // Reload_Kick is in the inbox
	Reload_Sent, // pi.reload went to the bridge (inflight)
	Restart_Kicked, // Reload_Kick is in the inbox
	Restart_Asking, // pi.wait_idle went to the bridge (inflight): kill only on its OK
	Restart_Exiting, // the old pi was stopped (pid): the new one starts once it exited
}

// Sends a command to a pi tab's bridge (tests replace it).
reload_send := socket_bridge_send

RELOAD_STEP_NAMES := [Reload_Step]string {
	.None            = "",
	.Reload_Kicked   = "reload",
	.Reload_Sent     = "reloading",
	.Restart_Kicked  = "restart",
	.Restart_Asking  = "asking",
	.Restart_Exiting = "exiting",
}

// A pi tab's hot-reload bookkeeping (Tab.reload).
Tab_Reload :: struct {
	started:   bool, // seen running: version is what its process started with
	version:   string, // pi's version on disk when it started ("" = unknown)
	stale:     bool, // a file it reads changed since it started or reloaded
	stale_gen: u64, // State.reload.gen of that change
	queued:    Reload_Op, // chosen by the user (or Atlas); done once the tab is idle
	step:      Reload_Step,
	inflight:  u64, // request id of what went to the bridge (step), 0 = none
	pid:       i32, // Restart_Exiting: the old pi's process
	stopped:   time.Tick, // when it was hung up on
	sent_gen:  u64, // State.reload.gen when it was sent
	note:      string, // the last outcome, for Details ("reloaded", "reload failed: …")
	flags:     bool, // Claude tabs: a queued restart replays the user's saved flags (the user asked)
	all:       bool, // Claude tabs: a queued restart from restart-all (due though nothing changed)
	extras:    u64, // pi tabs: the optional extensions of the pi integration it started with (pi_integration_extras)
}

// The bar's model (State.reload). Changed by commands only.
Reload_Info :: struct {
	gen:               u64, // bumped by every reported change
	changed:           [dynamic]string, // files changed (Details), at most RELOAD_CHANGED_MAX
	changed_more:      int, // and this many more
	from_save:         bool, // an editor save: the bar shows even with nothing to reload
	dismissed:         bool, // Later: the reload bar hides until the next change
	pi_version:        string, // pi's version on disk now ("" = unknown)
	restart_dismissed: bool, // Later on the restart bar: until the next version
	claude:            Claude_Reload_Info, // Claude Code's bars (claude_reload.odin)
}

// pi_reload_all: reload every running pi tab (only_changed: those a watched
// file changed for); idle ones now, the others once idle.
Pi_Reload_All :: struct {
	only_changed: bool,
	confirm:      string, // class session_restart
}
// pi_restart_updated: restart the pi tabs that started with another pi
// version than the one on disk; idle ones now, the others once idle.
Pi_Restart_Updated :: struct {
	confirm: string, // class session_restart
}
// pi_reload_later: hide the reload bar (restart: the restart bar) until
// the next change and drop the reloads (restarts) still queued.
Pi_Reload_Later :: struct {
	restart: bool,
}
// Internal: watched files changed (after the debounce), or pi's version on
// disk is known or changed. paths: at most RELOAD_CHANGED_MAX, more: how
// many others; scopes: each once, "" (every pi tab), RELOAD_SCOPE_ATLAS,
// or a folder (tabs at or below it).
Reload_Watch :: struct {
	paths:     []string,
	more:      int,
	scopes:    []string,
	version:   string, // "" = unchanged
	from_save: bool,
}
// Internal: one step of a tab's reload or restart (its Tab.reload.step):
// pi.reload, or pi.wait_idle before a restart, or the start after the old
// pi exited. Does nothing unless that step is due.
Reload_Kick :: struct {
	tab_id: u64,
}

// How a pi tab can take a reload now.
Reload_Class :: enum u8 {
	Idle,
	Busy, // working, or a dialog is open
	Blocked, // idle, but with background work a reload would stop
	No_Bridge, // no status from the pi integration's bridge: pi-desk cannot reach it
}

reload_class :: proc(t: ^Tab) -> Reload_Class {
	if t.agent == .Unknown do return .No_Bridge
	if t.agent == .Working || t.waiting do return .Busy
	if len(t.blockers) > 0 do return .Blocked
	return .Idle
}

// Whether a session's pi reads files of `scope`.
reload_in_scope :: proc(s: ^Open_Session, scope: string) -> bool {
	if scope == "" do return true
	if scope == RELOAD_SCOPE_ATLAS do return s.home
	at :: proc(p, d: string) -> bool {
		if p == "" do return false
		return p == d || d == "/" || (len(p) > len(d) && strings.has_prefix(p, d) && p[len(d)] == '/')
	}
	return at(s.cwd, scope) || at(fs_real(s.cwd), scope)
}

// The running pi tab of a session, or nil.
@(private = "file")
running_pi :: proc(s: ^Open_Session) -> ^Tab {
	t := session_pi_tab(s)
	if t == nil || t.status != .Running do return nil
	return t
}

// Whether a pi tab needs a restart: it started with another pi than the one on disk, or with
// other optional extensions of the pi integration than the user's choices now (pi_integration.odin).
reload_outdated :: proc(t: ^Tab) -> bool {
	return reload_version_outdated(t) || pi_extras_outdated(t)
}

// Whether the restart is about a pi update: some running pi tab started on another version (else
// only the pi extensions changed).
restart_on_version :: proc() -> bool {
	for &s in state.open_sessions do if t := running_pi(&s); t != nil && reload_version_outdated(t) do return true
	return false
}

// Whether a pi tab started with another pi than the one on disk (not counting the extensions).
reload_version_outdated :: proc(t: ^Tab) -> bool {
	v := state.reload.pi_version
	return v != "" && t.reload.version != "" && t.reload.version != v
}

@(private = "file")
set_note :: proc(t: ^Tab, note: string) {
	delete(t.reload.note)
	t.reload.note = strings.clone(cut_utf8(one_line(note, context.temp_allocator), RELOAD_NOTE_MAX))
}

@(private = "file")
set_version :: proc(t: ^Tab, v: string) {
	if t.reload.version == v do return
	delete(t.reload.version)
	t.reload.version = strings.clone(v)
}

// What a confirmation says about the background work of tabs that are
// queued because of it: "recipe-box (shell sh1: npm test), +1 more".
@(private = "file")
blocked_list :: proc(tabs: []^Tab) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for t in tabs {
		if len(t.blockers) == 0 do continue
		if n == 2 {
			left := 0
			for x in tabs do if len(x.blockers) > 0 do left += 1
			fmt.sbprintf(&b, ", +%d more", left - 2)
			break
		}
		s, _, _ := find_tab(t.id)
		if n > 0 do strings.write_string(&b, ", ")
		more := len(t.blockers) > 1 ? fmt.tprintf("; +%d", len(t.blockers) - 1) : ""
		fmt.sbprintf(&b, "%s (%s%s)", s != nil ? session_project_name(s) : "?", cut_utf8(t.blockers[0], 60), more)
		n += 1
	}
	return strings.to_string(b)
}

// The confirmation of a reload or restart of several tabs.
@(private = "file")
reload_summary :: proc(restart: bool, now, later: []^Tab) -> string {
	n := len(now) + len(later)
	on := restart_on_version() ? fmt.tprintf(" on pi %s", state.reload.pi_version) : ""
	what := restart ? fmt.tprintf("restart %d pi tab%s%s? Each starts again on its session.", n, n == 1 ? "" : "s", on) : fmt.tprintf("reload %d pi tab%s?", n, n == 1 ? "" : "s")
	if bl := blocked_list(later); bl != "" {
		return fmt.tprintf("%s Background work that a %s would stop: %s. Those tabs wait until it ends.", what, restart ? "restart" : "reload", bl)
	}
	if len(later) > 0 do return fmt.tprintf("%s %d busy tab%s wait%s until idle.", what, len(later), len(later) == 1 ? "" : "s", len(later) == 1 ? "s" : "")
	return what
}

// For pi_reload's confirmation (commands.odin): the background work it
// would stop, or "".
reload_blockers_note :: proc(t: ^Tab) -> string {
	if t == nil || len(t.blockers) == 0 do return ""
	return fmt.tprintf(" Background work stops: %s.", strings.join(t.blockers[:min(len(t.blockers), 3)], "; ", context.temp_allocator))
}

@(private = "file")
ids_json :: proc(b: ^strings.Builder, name: string, tabs: []^Tab, first := false) {
	if !first do strings.write_byte(b, ',')
	fmt.sbprintf(b, `"%s":[`, name)
	for t, i in tabs {
		if i > 0 do strings.write_byte(b, ',')
		fmt.sbprintf(b, "%d", t.id)
	}
	strings.write_byte(b, ']')
}

// Starts the reload or restart of an idle tab: one Reload_Kick through the
// inbox (after this command: never inside a bridge's own report). The
// queue entry becomes the step, so it goes once.
@(private = "file")
kick :: proc(t: ^Tab, op: Reload_Op) {
	if op == .None || t.reload.step != .None do return
	t.reload.queued = .None
	t.reload.step = op == .Reload ? .Reload_Kicked : .Restart_Kicked
	set_note(t, op == .Reload ? "reloading" : "restarting")
	inbox_submit(Reload_Kick{tab_id = t.id}, {kind = .Internal})
}

// How long the bridge has to say pi is idle before a restart (pi.wait_idle:
// the pi integration's bridge answers once pi has been idle, with nothing queued and no
// background work, for 250 ms; else "timeout").
RESTART_IDLE_CHECK_MS :: 1500
// After this the old pi gets SIGKILL (it was hung up on).
RESTART_EXIT_WAIT :: 5 * time.Second

@(private = "file")
reload_step_reloading :: proc(st: Reload_Step) -> bool {return st == .Reload_Kicked || st == .Reload_Sent}

// The hot-reload commands (commands.odin's apply hands them here).
reload_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Pi_Reload_All, Pi_Restart_Updated:
		restart := false
		only_changed := false
		token := ""
		if x, ok := c.(Pi_Reload_All); ok do only_changed, token = x.only_changed, x.confirm
		if x, ok := c.(Pi_Restart_Updated); ok do restart, token = true, x.confirm
		if restart do probe_again() // pi may have moved since
		now := make([dynamic]^Tab, context.temp_allocator)
		later := make([dynamic]^Tab, context.temp_allocator)
		cut := make([dynamic]^Tab, context.temp_allocator) // no bridge
		blocked := 0
		for &s in state.open_sessions {
			t := running_pi(&s)
			if t == nil || owns_tab(caller, t.id) || t.reload.step != .None do continue // one under way goes on
			if restart ? !reload_outdated(t) : (only_changed && !t.reload.stale) do continue
			switch reload_class(t) {
			case .Idle:      append(&now, t)
			case .Busy:      append(&later, t)
			case .Blocked:
				append(&later, t)
				blocked += 1
			case .No_Bridge: append(&cut, t)
			}
		}
		if len(now) + len(later) == 0 {
			if len(cut) > 0 do return fail("no pi tab here reports to Deckhand (its pi integration did not connect): restart them by hand"), false
			if restart do return fail("no pi tab runs an older pi or other pi extensions"), false
			return fail(only_changed ? "no pi tab needs a reload" : "no pi tab is running"), false
		}
		// the user's own click is the decision; background work is warned
		// about; Atlas always asks the user; scripts follow their policy
		ask := token != "" || (caller.kind == .UI && blocked > 0) || caller.kind == .Control || caller.kind == .Script || caller.kind == .Panel
		if ask {
			gr, go_on, ch := confirm_gate(cmd, .Session_Restart, caller, token, reload_summary(restart, now[:], later[:]), force_ask = caller.kind == .Control)
			if !go_on do return gr, ch
		}
		op := restart ? Reload_Op.Restart : Reload_Op.Reload
		for t in now do kick(t, op)
		for t in later {
			t.reload.queued = op
			set_note(t, len(t.blockers) > 0 ? fmt.tprintf("waits for %s", t.blockers[0]) : fmt.tprintf("%ss when idle", RELOAD_OP_NAMES[op]))
		}
		if restart do state.reload.restart_dismissed = false
		else {
			state.reload.dismissed = false
			state.reload.from_save = false
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '{')
		ids_json(&b, restart ? "restarting" : "reloading", now[:], first = true)
		ids_json(&b, "queued", later[:])
		ids_json(&b, "no_bridge", cut[:])
		strings.write_byte(&b, '}')
		return {ok = true, data = strings.to_string(b)}, true
	case Pi_Reload_Later:
		if c.restart do state.reload.restart_dismissed = true
		else {
			state.reload.dismissed = true
			state.reload.from_save = false
		}
		want := c.restart ? Reload_Op.Restart : Reload_Op.Reload
		for &s in state.open_sessions {
			if t := session_pi_tab(&s); t != nil && t.reload.queued == want {
				t.reload.queued = .None
				set_note(t, "")
			}
		}
		return {ok = true}, true
	case Reload_Watch:
		info := &state.reload
		if len(c.paths) > 0 || c.more > 0 {
			// a new round: Details lists only what changed since nothing was pending
			if !reload_any_pending() {
				for p in info.changed do delete(p)
				clear(&info.changed)
				info.changed_more = 0
			}
			info.gen += 1
			for p in c.paths {
				if slice.contains(info.changed[:], p) do continue
				if len(info.changed) < RELOAD_CHANGED_MAX do append(&info.changed, strings.clone(p))
				else do info.changed_more += 1
			}
			info.changed_more += c.more
			// each scope once, not each path
			for &s in state.open_sessions {
				t := running_pi(&s)
				if t == nil do continue
				for scope in c.scopes do if reload_in_scope(&s, scope) {
					t.reload.stale = true
					t.reload.stale_gen = info.gen
					break
				}
			}
			info.dismissed = false
			if c.from_save do info.from_save = true
		}
		if c.version != "" && c.version != info.pi_version {
			first := info.pi_version == ""
			delete(info.pi_version)
			info.pi_version = strings.clone(c.version)
			info.restart_dismissed = false
			// tabs seen before the version was known started with this one
			if first do for &s in state.open_sessions do if t := running_pi(&s); t != nil && t.reload.version == "" do set_version(t, c.version)
		}
		return {ok = true}, true
	case Reload_Kick:
		s, t, _ := find_tab(c.tab_id)
		if t == nil do return fail("no such pi tab"), false
		if _, is := t.kind.(Pi_Tab); !is do return fail("no such pi tab"), false
		step := t.reload.step
		if step == .Restart_Exiting {
			// the old pi exited: the new one starts on the same session
			if t.reload.pid > 0 && pty_dying(t.reload.pid) do return {ok = true}, false
			t.reload.step, t.reload.pid = .None, 0
			if !start_pi_tab_again(s, t) {
				set_note(t, "restart failed: could not start pi")
				return fail("could not start pi"), true
			}
			t.reload.started = true
			set_version(t, state.reload.pi_version)
			t.reload.stale = false
			set_note(t, state.reload.pi_version != "" ? fmt.tprintf("restarted on pi %s", state.reload.pi_version) : "restarted")
			return {ok = true}, true
		}
		// only a kick that is due: never a second reload for one queue entry
		if step != .Reload_Kicked && step != .Restart_Kicked do return {ok = true}, false
		t.reload.step = .None
		op := step == .Reload_Kicked ? Reload_Op.Reload : .Restart
		what := op == .Reload ? "reload" : "restart"
		if t.status != .Running {
			set_note(t, "")
			return fail("the tab's process has exited"), true
		}
		switch reload_class(t) {
		case .Idle:
		case .Busy, .Blocked:
			t.reload.queued = op // again when idle
			set_note(t, fmt.tprintf("%ss when idle", what))
			return {ok = true}, true
		case .No_Bridge:
			set_note(t, fmt.tprintf("not %sed: no status from its bridge", what))
			return fail("no status from the tab's bridge"), true
		}
		if op == .Restart {
			if !reload_outdated(t) {
				set_note(t, "")
				return {ok = true}, true
			}
			if !s.home && (s.session_file == "" || !os.exists(s.session_file)) {
				set_note(t, "not restarted: pi has not reported its session file")
				return fail("pi has not reported its session file"), true
			}
			// is pi truly idle? Killed only on the bridge's OK
			if !reload_send(t.id, request_id, Pi_Wait_Idle{tab_id = t.id, timeout_ms = RESTART_IDLE_CHECK_MS}) {
				set_note(t, "not restarted: no bridge connected")
				return fail("no bridge connected for this tab"), true
			}
			t.reload.step, t.reload.inflight = .Restart_Asking, request_id
			set_note(t, "restarting")
			return {ok = true, pending = true}, true
		}
		if !reload_send(t.id, request_id, Pi_Reload{tab_id = t.id}) {
			set_note(t, "reload failed: no bridge connected")
			return fail("no bridge connected for this tab"), true
		}
		t.reload.step, t.reload.inflight, t.reload.sent_gen = .Reload_Sent, request_id, state.reload.gen
		set_note(t, "reloading")
		return {ok = true, pending = true}, true
	}
	return fail("not a reload command"), false
}

// Whether any running pi tab is stale, queued or reloading.
reload_any_pending :: proc() -> bool {
	for &s in state.open_sessions {
		t := running_pi(&s)
		if t != nil && (t.reload.stale || t.reload.queued != .None || t.reload.step != .None) do return true
	}
	return false
}

// Hooks from commands.odin.

// A pi tab reported its status: its queued reload or restart goes now if
// it is idle (and, for a restart, still on an older pi), unless one is
// already under way.
reload_status_changed :: proc(t: ^Tab) {
	if t.reload.queued == .None || t.reload.step != .None || t.status != .Running || reload_class(t) != .Idle do return
	if t.reload.queued == .Restart && !reload_outdated(t) {
		t.reload.queued = .None
		return
	}
	kick(t, t.reload.queued)
}

// The user's own pi_reload went to the tab's bridge as `request_id`.
reload_sent :: proc(t: ^Tab, request_id: u64) {
	if t.reload.queued == .Reload do t.reload.queued = .None
	t.reload.step, t.reload.inflight, t.reload.sent_gen = .Reload_Sent, request_id, state.reload.gen
	set_note(t, "reloading")
}

// A bridge answered: a reload of ours finished, or it said whether pi is
// idle for a restart.
reload_bridge_done :: proc(c: Bridge_Done) {
	if c.request_id == 0 do return
	for &s in state.open_sessions {
		t := session_pi_tab(&s)
		if t == nil || t.reload.inflight != c.request_id do continue
		t.reload.inflight = 0
		step := t.reload.step
		t.reload.step = .None
		#partial switch step {
		case .Reload_Sent:
			if c.ok {
				if t.reload.stale_gen <= t.reload.sent_gen do t.reload.stale = false
				set_note(t, "reloaded")
			} else if strings.has_prefix(c.error, "not idle") {
				t.reload.queued = .Reload // it got busy meanwhile: again when idle
				set_note(t, "reloads when idle")
			} else {
				set_note(t, fmt.tprintf("reload failed: %s", c.error))
			}
		case .Restart_Asking:
			// not idle within the time (or the bridge went): never killed; again when idle
			if !c.ok || t.status != .Running || reload_class(t) != .Idle {
				t.reload.queued = .Restart
				set_note(t, "restarts when idle")
				return
			}
			t.reload.pid = stop_pi_tab(t)
			t.reload.step = .Restart_Exiting
			t.reload.stopped = time.tick_now()
			set_note(t, "restarting: waiting for the old pi to exit")
		}
		return
	}
}

// ---- the state snapshot ----

write_reload :: proc(b: ^strings.Builder, r: Reload_Info) {
	fmt.sbprintf(b, `{{"gen":%d,"changed":`, r.gen)
	write_strings(b, r.changed[:])
	fmt.sbprintf(b, `,"changed_more":%d,"from_save":%v,"dismissed":%v,"pi_version":`, r.changed_more, r.from_save, r.dismissed)
	json_quote(b, r.pi_version)
	fmt.sbprintf(b, `,"restart_dismissed":%v,"claude":`, r.restart_dismissed)
	write_claude_reload(b, r.claude) // claude_reload.odin
	strings.write_byte(b, '}')
}

write_tab_reload :: proc(b: ^strings.Builder, t: Tab_Reload) {
	fmt.sbprintf(b, `{{"stale":%v,"queued":"%s","step":"%s","version":`, t.stale, RELOAD_OP_NAMES[t.queued], RELOAD_STEP_NAMES[t.step])
	json_quote(b, t.version)
	strings.write_string(b, `,"note":`)
	json_quote(b, t.note)
	strings.write_byte(b, '}')
}

// After "type" in an event's command object.
reload_write :: proc(b: ^strings.Builder, cmd: Command) {
	#partial switch c in cmd {
	case Pi_Reload_All:
		if c.only_changed do strings.write_string(b, `,"only_changed":true`)
		if c.confirm != "" do strings.write_string(b, `,"confirm":"<redacted>"`)
	case Pi_Restart_Updated:
		if c.confirm != "" do strings.write_string(b, `,"confirm":"<redacted>"`)
	case Pi_Reload_Later:
		if c.restart do strings.write_string(b, `,"restart":true`)
	case Reload_Watch:
		fmt.sbprintf(b, `,"files":%d`, len(c.paths) + c.more)
		if c.version != "" {
			strings.write_string(b, `,"version":`)
			json_quote(b, c.version)
		}
	case Reload_Kick:
		fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
	}
}

reload_clone :: proc(cmd: Command, a: runtime.Allocator) -> Command {
	#partial switch c in cmd {
	case Pi_Reload_All:      return Pi_Reload_All{only_changed = c.only_changed, confirm = strings.clone(c.confirm, a)}
	case Pi_Restart_Updated: return Pi_Restart_Updated{confirm = strings.clone(c.confirm, a)}
	case Reload_Watch:
		paths := make([]string, len(c.paths), a)
		scopes := make([]string, len(c.scopes), a)
		for x, i in c.paths do paths[i] = strings.clone(x, a)
		for x, i in c.scopes do scopes[i] = strings.clone(x, a)
		return Reload_Watch{paths = paths, more = c.more, scopes = scopes, version = strings.clone(c.version, a), from_save = c.from_save}
	}
	return cmd
}

reload_free :: proc(cmd: Command, a: runtime.Allocator) {
	#partial switch c in cmd {
	case Pi_Reload_All:      delete(c.confirm, a)
	case Pi_Restart_Updated: delete(c.confirm, a)
	case Reload_Watch:
		for x in c.paths do delete(x, a)
		for x in c.scopes do delete(x, a)
		delete(c.paths, a)
		delete(c.scopes, a)
		delete(c.version, a)
	}
}

// ---- watching (runtime, main thread) ----

Reload_Src :: struct {
	path:   string, // as built; folders: their real path (what FSEvents reports)
	scope:  string,
	dir:    bool, // a folder: its contents come from FSEvents, its own stamp from the poll
	kind:   Path_Kind,
	stamp:  Disk_Stamp,
	digest: string, // a settings.json: its content without the keys pi writes itself (owned)
}

@(private = "file")
Reload_Watcher :: struct {
	srcs:       [dynamic]Reload_Src, // owned strings
	dirs:       [dynamic]int, // srcs that are folders (FSEvents matching)
	key:        string, // the running pi tabs' folders the sources were built for
	rebuild:    bool,
	last_poll:  time.Tick,
	pending:    [dynamic]string, // changed, not yet reported (owned), at most RELOAD_CHANGED_MAX
	more:       int, // and this many more
	scopes:     [dynamic]string, // the scopes they reach, each once (owned)
	due:        time.Tick,
	has_due:    bool,
	from_save:  bool,
	version:    string, // pi's version to report (owned)
	pkg:        string, // pi's package.json ("" = not known)
	pkg_stamp:  Disk_Stamp,
	probed:     bool, // looked for pi's package once
	last_probe: time.Tick,
}

@(private = "file")
rw: Reload_Watcher

@(private = "file")
probe: struct {
	lock:    sync.Mutex,
	done:    bool, // atomic: result is ready
	running: bool, // atomic: a worker looks
	result:  string, // heap
}

// The folders FSEvents should watch for us (editor_watch.odin's watch_sync).
reload_watch_dirs :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for i in rw.dirs do if rw.srcs[i].kind == .Dir do append(&out, rw.srcs[i].path)
	return out[:]
}

// A changed path from FSEvents (editor_watch.odin, main thread). Cheap per
// path: a burst (npm install, a checkout) is many thousands.
reload_fs_event :: proc(path: string) {
	if len(rw.dirs) == 0 do return
	best := -1
	for i in rw.dirs {
		d := rw.srcs[i].path
		if path == d || (len(path) > len(d) && path[len(d)] == '/' && strings.has_prefix(path, d)) {
			if best < 0 || len(d) > len(rw.srcs[best].path) do best = i
		}
	}
	if best < 0 do return
	// what installs and git churn through, below the watched folder
	rest := path[len(rw.srcs[best].path):]
	start := 0
	for i in 0 ..= len(rest) {
		if i < len(rest) && rest[i] != '/' do continue
		seg := rest[start:i]
		if seg == "node_modules" || seg == ".git" || seg == ".DS_Store" do return
		start = i + 1
	}
	if len(rw.pending) < RELOAD_CHANGED_MAX && settings_credential(path) do return
	reload_pending_add(path, rw.srcs[best].scope)
}

// Notes a changed file; reported once nothing changed for RELOAD_DEBOUNCE.
reload_pending_add :: proc(path, scope: string, at := time.Tick{}) {
	now := at == {} ? time.tick_now() : at
	if !slice.contains(rw.scopes[:], scope) do append(&rw.scopes, strings.clone(scope))
	// past the list only counted (a burst: no lookups; a path seen twice counts twice)
	if len(rw.pending) >= RELOAD_CHANGED_MAX do rw.more += 1
	else if !slice.contains(rw.pending[:], path) do append(&rw.pending, strings.clone(path))
	rw.due = time.tick_add(now, RELOAD_DEBOUNCE)
	rw.has_due = true
}

// Reports what changed if the debounce passed (true when it did).
reload_flush :: proc(at := time.Tick{}) -> bool {
	now := at == {} ? time.tick_now() : at
	if !rw.has_due || time.tick_diff(rw.due, now) < 0 do return false
	rw.has_due = false
	files := len(rw.pending) > 0 || rw.more > 0
	run_command(Reload_Watch{paths = rw.pending[:], more = rw.more, scopes = rw.scopes[:], version = rw.version, from_save = rw.from_save})
	for p in rw.pending do delete(p)
	for p in rw.scopes do delete(p)
	clear(&rw.pending)
	clear(&rw.scopes)
	rw.more = 0
	delete(rw.version)
	rw.version = ""
	rw.from_save = false
	if files do probe_again() // the bar may show: is pi still where it was?
	return true
}

// The editor saved a file pi reads (settings_after_save): the bar at once.
reload_note_save :: proc(path, scope: string) {
	reload_pending_add(path, scope)
	rw.due = time.tick_now()
	rw.from_save = true
	app.redraw = true
}

// Forgets the watcher's state (tests).
reload_watch_reset :: proc() {
	for s in rw.srcs {
		delete(s.path)
		delete(s.scope)
		delete(s.digest)
	}
	for p in rw.pending do delete(p)
	for p in rw.scopes do delete(p)
	delete(rw.srcs)
	delete(rw.dirs)
	delete(rw.pending)
	delete(rw.scopes)
	delete(rw.key)
	delete(rw.version)
	delete(rw.pkg)
	rw = {}
}

// Every frame callback (editor_tick): records each pi tab's version when
// it starts, starts a restarted pi once the old one exited, polls while a
// pi tab runs, reports after the debounce.
reload_tick :: proc() {
	any := false
	for &s in state.open_sessions {
		t := session_pi_tab(&s)
		if t == nil do continue
		if t.reload.step == .Restart_Exiting {
			if t.reload.pid > 0 && pty_dying(t.reload.pid) {
				// hung up on but not gone: make sure
				if time.tick_since(t.reload.stopped) > RESTART_EXIT_WAIT do posix.kill(posix.pid_t(t.reload.pid), .SIGKILL)
				continue
			}
			run_command(Reload_Kick{tab_id = t.id})
		}
		if t.status != .Running {
			t.reload.started = false
			continue
		}
		any = true
		if !t.reload.started {
			t.reload.started = true
			set_version(t, state.reload.pi_version)
		}
	}
	if !any {
		if len(rw.srcs) > 0 { 	// stop watching
			reload_build({})
			delete(rw.key)
			rw.key = ""
			watch_sync()
		}
		reload_flush()
		return
	}
	if !rw.probed {
		rw.probed = true
		probe_again()
	}
	if sync.atomic_load(&probe.done) {
		sync.lock(&probe.lock)
		if probe.result != rw.pkg {
			delete(rw.pkg)
			rw.pkg = strings.clone(probe.result)
			rw.pkg_stamp = {}
			rw.last_poll = {} // read its version now
		}
		sync.unlock(&probe.lock)
		sync.atomic_store(&probe.done, false)
	}
	if rw.last_poll == {} || time.tick_since(rw.last_poll) > RELOAD_POLL {
		rw.last_poll = time.tick_now()
		reload_poll()
	}
	if reload_flush() do app.redraw = true
}

// The running pi tabs' folders, sorted ("@atlas" when Atlas runs).
@(private = "file")
reload_cwds :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for &s in state.open_sessions {
		if running_pi(&s) == nil do continue
		if s.home && !slice.contains(out[:], RELOAD_SCOPE_ATLAS) do append(&out, RELOAD_SCOPE_ATLAS)
		if s.cwd != "" && !slice.contains(out[:], s.cwd) do append(&out, s.cwd)
	}
	slice.sort(out[:])
	return out[:]
}

// One poll: the sources again if the tabs' folders changed, every file
// source's stamp, pi's version.
reload_poll :: proc() {
	now := time.tick_now()
	cwds := reload_cwds()
	key := strings.join(cwds, "\x00", context.temp_allocator)
	if key != rw.key || rw.rebuild {
		delete(rw.key)
		rw.key = strings.clone(key)
		reload_build(cwds)
		watch_sync()
	}
	for &s in rw.srcs {
		k, st := path_stat(s.path)
		if k == s.kind && (k == .Missing || (st.mtime == s.stamp.mtime && st.size == s.stamp.size && st.inode == s.stamp.inode)) do continue
		was := s.kind
		s.kind, s.stamp = k, st
		if s.dir {
			// its contents come from FSEvents; it appeared, went, or its
			// entries changed: watch it (and its links) anew
			rw.rebuild = true
			if (was == .Dir) != (k == .Dir) do reload_pending_add(s.path, s.scope, now)
			continue
		}
		base := filepath.base(s.path)
		if base == "settings.json" {
			// pi writes some keys itself (the model it last used…): not a change for the others
			d := settings_digest(s.path)
			same := d == s.digest
			delete(s.digest)
			s.digest = d
			if same do continue
			rw.rebuild = true // packages may have changed
		}
		if base == "package.json" do rw.rebuild = true
		reload_pending_add(s.path, s.scope, now)
	}
	// pi's version on disk
	if rw.pkg != "" {
		k, st := path_stat(rw.pkg)
		if k == .File && st != rw.pkg_stamp {
			if v := pkg_version(rw.pkg); v != "" {
				rw.pkg_stamp = st
				if v != state.reload.pi_version && v != rw.version {
					delete(rw.version)
					rw.version = strings.clone(v)
					rw.due = state.reload.pi_version == "" ? now : time.tick_add(now, RELOAD_DEBOUNCE)
					rw.has_due = true
				}
			}
		}
	}
}

// Keys of settings.json that pi writes itself in ordinary use (pi's
// settings-manager: setDefaultModelAndProvider and setDefaultThinkingLevel
// on /model and Ctrl+P, setModelThinkingLevel, setLastChangelogVersion at
// start, the device id): they only matter to new sessions, so a write that
// changes only these is no reason to reload.
PI_OWN_SETTINGS :: [?]string{"defaultProvider", "defaultModel", "defaultThinkingLevel", "modelThinkingLevels", "lastChangelogVersion", "deviceId"}

// A settings.json's content without PI_OWN_SETTINGS, keys sorted (owned;
// "" = not readable as JSON).
settings_digest :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	v, jerr := json.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return ""
	if obj, ok := v.(json.Object); ok do for k in PI_OWN_SETTINGS do delete_key(&obj, k)
	out, merr := json.marshal(v, {sort_maps_by_key = true}, context.temp_allocator)
	if merr != nil do return ""
	return strings.clone(string(out))
}

// "version" of a package.json ("" = unreadable).
pkg_version :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	v, jerr := json.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return ""
	obj, ok := v.(json.Object)
	if !ok do return ""
	s, _ := obj["version"].(json.String)
	return s
}

// Looks for pi's package (again): at the first pi tab, when the bar may
// show, before a restart. A worker, at most every 10 s; PI_DESK_PI_PACKAGE
// at once (tests). The result is taken by reload_tick.
@(private = "file")
probe_again :: proc() {
	if p := os.get_env("PI_DESK_PI_PACKAGE", context.temp_allocator); p != "" {
		sync.lock(&probe.lock)
		delete(probe.result, runtime.heap_allocator())
		probe.result = strings.clone(p, runtime.heap_allocator())
		sync.unlock(&probe.lock)
		sync.atomic_store(&probe.done, true)
		return
	}
	if os.get_env("PI_DESK_CMD", context.temp_allocator) != "" do return // pi is replaced (tests): no version
	if sync.atomic_load(&probe.running) do return
	if rw.last_probe != {} && time.tick_since(rw.last_probe) < 10 * time.Second do return
	rw.last_probe = time.tick_now()
	sync.atomic_store(&probe.running, true)
	thread.create_and_start(probe_worker, self_cleanup = true)
}

// Looks for pi's package again (an install or update from the harness checklist ended).
pi_version_probe_again :: proc() {
	rw.last_probe = {}
	probe_again()
}

// Worker: where pi's package.json is, as a login shell finds pi (a
// wrapper script gives none: no version, no restart offer).
@(private = "file")
probe_worker :: proc() {
	defer free_all(context.temp_allocator)
	shell := os.get_env("SHELL", context.temp_allocator)
	if shell == "" do shell = "/bin/zsh"
	out, ok := run_bounded("", shell_script_argv(shell, "command -v pi", "sh")[:], 10 * time.Second) // fish and co.: /bin/sh
	found := ""
	if ok {
		lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
		bin := len(lines) > 0 ? strings.trim_space(lines[len(lines) - 1]) : ""
		if filepath.is_abs(bin) do found = pi_package_of(bin)
	}
	if found == "" {
		if m := pi_managed_path(); m != "" do found = pi_package_of(m) // as PI_TAB_CMD falls back (login_env.odin)
	}
	sync.lock(&probe.lock)
	delete(probe.result, runtime.heap_allocator())
	probe.result = strings.clone(found, runtime.heap_allocator())
	sync.unlock(&probe.lock)
	sync.atomic_store(&probe.done, true)
	sync.atomic_store(&probe.running, false)
	if platform.wake != nil do platform.wake()
}

PI_PACKAGE :: "@earendil-works/pi-coding-agent"

// The package.json of the pi that bin runs ("" = none with a version), looked at, never run:
// a wrapper or shim script's target (pnpm's shim, nix's makeWrapper: script_target), else the
// first package.json above pi's real entry point (npm, bun, mise's npm backend: links into a
// node_modules) that is pi's (a package.json of something else, like a home folder's, is skipped).
pi_package_of :: proc(bin: string) -> string {
	real := fs_real(bin)
	if real == "" do real = bin
	if pkg := script_target(real, "node_modules/" + PI_PACKAGE); pkg != "" {
		p := strings.concatenate({pkg, "/package.json"}, context.temp_allocator)
		if pkg_version(p) != "" do return p
	}
	d := filepath.dir(real)
	for i := 0; i < 8 && d != "/" && d != "" && d != "."; i += 1 {
		p := strings.concatenate({d, "/package.json"}, context.temp_allocator)
		if path_kind(p) == .File && pkg_version(p) != "" {
			name := pkg_name(p)
			if name == "" || strings.has_suffix(name, "pi-coding-agent") do return p
		}
		d = filepath.dir(d)
	}
	return ""
}

// A package.json's "name" ("" = none or unreadable).
pkg_name :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	v, jerr := json.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return ""
	obj, ok := v.(json.Object)
	if !ok do return ""
	s, _ := obj["name"].(json.String)
	return s
}

// SCRIPT_TARGET_MAX: wrapper and shim scripts are small; anything bigger is a program, not read.
@(private = "file")
SCRIPT_TARGET_MAX :: 64 * 1024

// Where a wrapper or shim script (a small text file starting with "#!": pnpm's shims, nix's
// makeWrapper, npm's .bin scripts) points: the first absolute path in it, or one relative to its
// folder ("$basedir/…", as pnpm writes), that contains marker, cut just after marker; it must be a
// folder. Read only, never run. "" = not a script, or no such path.
script_target :: proc(script, marker: string) -> string {
	k, st := path_stat(script)
	if k != .File || st.size > SCRIPT_TARGET_MAX do return ""
	data, err := os.read_entire_file(script, context.temp_allocator)
	if err != nil || len(data) < 2 || data[0] != '#' || data[1] != '!' do return ""
	text := string(data)
	from := 0
	for {
		i := strings.index(text[from:], marker)
		if i < 0 do return ""
		at := from + i
		from = at + len(marker)
		if from < len(text) && text[from] != '/' && text[from] != '"' && text[from] != '\'' && text[from] != ' ' && text[from] != '\n' do continue // a longer name
		j := at
		for j > 0 && !strings.contains_rune("\"' \t\n=:(`", rune(text[j - 1])) do j -= 1
		p := text[j:from]
		if strings.has_prefix(p, "$basedir/") do p = strings.concatenate({filepath.dir(script), p[len("$basedir"):]}, context.temp_allocator)
		if !filepath.is_abs(p) do continue
		c, _ := filepath.clean(p, context.temp_allocator)
		if path_kind(c) == .Dir do return c
	}
}

// ---- the sources ----

@(private = "file")
RESOURCE_DIRS :: [?]string{"extensions", "skills", "prompts", "themes"}
@(private = "file")
AGENT_FILES :: [?]string{"settings.json", "keybindings.json", "models.json", "mcp.json", "modes.json", "SYSTEM.md", "APPEND_SYSTEM.md"}
@(private = "file")
PROJECT_FILES :: [?]string{"settings.json", "mcp.json", "SYSTEM.md", "APPEND_SYSTEM.md"}
@(private = "file")
CONTEXT_NAMES :: [?]string{"AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"}
@(private = "file")
CONTEXT_MISSING :: [?]string{"AGENTS.override.md", "AGENTS.md", "CLAUDE.md"} // watched for being made

// The sources for these folders (reload_cwds; none = stop). Stamps of
// sources already watched are kept, so a change between polls still shows.
reload_build :: proc(cwds: []string) {
	old := rw.srcs
	rw.srcs = {}
	rw.rebuild = false
	if len(cwds) > 0 {
		ad, _ := filepath.clean(pi_agent_dir(), context.temp_allocator)
		for f in AGENT_FILES do add_file(fmt.tprintf("%s/%s", ad, f), "")
		add_context(ad, "")
		for d in RESOURCE_DIRS do add_dir(fmt.tprintf("%s/%s", ad, d), "", links = true)
		add_settings_paths(fmt.tprintf("%s/settings.json", ad), ad, "")
		for c in cwds {
			if c == RELOAD_SCOPE_ATLAS {
				if p := agent_prompt_path(); p != "" do add_file(p, RELOAD_SCOPE_ATLAS)
				continue
			}
			pd := fmt.tprintf("%s/.pi", c)
			if pd == ad || strings.has_prefix(ad, strings.concatenate({pd, "/"}, context.temp_allocator)) {
				// HOME's .pi holds the agent dir: only its own config files
				for f in PROJECT_FILES do add_file(fmt.tprintf("%s/%s", pd, f), c)
			} else {
				for f in PROJECT_FILES do add_file(fmt.tprintf("%s/%s", pd, f), c)
				for d in RESOURCE_DIRS do add_dir(fmt.tprintf("%s/%s", pd, d), c)
				add_settings_paths(fmt.tprintf("%s/settings.json", pd), pd, c)
			}
			// context files: the cwd and every folder above it
			d, _ := filepath.clean(c, context.temp_allocator)
			for i := 0; i < 32; i += 1 {
				add_context(d, d)
				if d == "/" || d == "" || d == "." do break
				d = filepath.dir(d)
			}
		}
		// Deckhand's pi integration (pi_integration.odin): every pi tab loads it with -e. After the
		// projects', so under RELOAD_DIRS_MAX a project's .pi never loses its watch to it.
		if pd := pi_integration_dir(); pd != "" {
			add_file(fmt.tprintf("%s/extensions.json", pd), "")
			add_dir(fmt.tprintf("%s/extensions", pd), "")
			add_dir(fmt.tprintf("%s/lib", pd), "")
			add_dir(fmt.tprintf("%s/skills", pd), RELOAD_SCOPE_ATLAS) // Atlas's desk skill
		}
	}
	// keep what was known of sources still watched
	for &s in rw.srcs {
		for &o in old do if o.path == s.path && o.dir == s.dir {
			s.kind, s.stamp = o.kind, o.stamp
			s.digest, o.digest = o.digest, s.digest
			break
		}
	}
	for o in old {
		delete(o.path)
		delete(o.scope)
		delete(o.digest)
	}
	delete(old)
	clear(&rw.dirs)
	for s, i in rw.srcs do if s.dir do append(&rw.dirs, i)
}

// Adds a source; one per path (a scope of every tab wins).
@(private = "file")
add_src :: proc(path, scope: string, dir: bool) {
	for &s in rw.srcs {
		if s.path != path || s.dir != dir do continue
		if scope == "" && s.scope != "" {
			delete(s.scope)
			s.scope = strings.clone(scope)
		}
		return
	}
	n := 0
	for s in rw.srcs do if s.dir == dir do n += 1
	if n >= (dir ? RELOAD_DIRS_MAX : RELOAD_FILES_MAX) do return
	k, st := path_stat(path)
	digest := !dir && filepath.base(path) == "settings.json" ? settings_digest(path) : ""
	append(&rw.srcs, Reload_Src{path = strings.clone(path), scope = strings.clone(scope), dir = dir, kind = k, stamp = st, digest = digest})
}

@(private = "file")
add_file :: proc(path, scope: string) {
	if path == "" do return
	add_src(path, scope, false)
}

// A folder (its real path, as FSEvents reports). links: also where its
// top-level symlinks lead, when that is outside it.
@(private = "file")
add_dir :: proc(path, scope: string, links := false) {
	if path == "" do return
	real := fs_real(path)
	if real == "" do real = path
	add_src(real, scope, true)
	if !links || path_kind(real) != .Dir do return
	entries, err := os.read_all_directory_by_path(real, context.temp_allocator)
	if err != nil do return
	for e in entries {
		if e.type != .Symlink do continue
		to := fs_real(e.fullpath)
		if to == "" || strings.has_prefix(to, strings.concatenate({real, "/"}, context.temp_allocator)) do continue
		switch path_kind(to) {
		case .Dir:  add_src(to, scope, true)
		case .File: add_file(to, scope)
		case .Missing, .Other:
		}
	}
}

// The context files of a folder: the ones there (once per file: names
// differing in case may be one file) and the main names while missing.
@(private = "file")
add_context :: proc(dir, scope: string) {
	seen := make([dynamic]u64, context.temp_allocator)
	for name in CONTEXT_NAMES {
		p := fmt.tprintf("%s/%s", dir == "/" ? "" : dir, name)
		k, st := path_stat(p)
		if k != .File || slice.contains(seen[:], st.inode) do continue
		append(&seen, st.inode)
		add_file(p, scope)
	}
	for name in CONTEXT_MISSING {
		p := fmt.tprintf("%s/%s", dir == "/" ? "" : dir, name)
		if path_kind(p) == .Missing do add_file(p, scope)
	}
}

// Local packages and resource paths a settings.json lists (relative to
// base, the folder holding it); npm, git and URL sources are pi's to update.
@(private = "file")
add_settings_paths :: proc(settings, base, scope: string) {
	if path_kind(settings) != .File do return
	data, err := os.read_entire_file(settings, context.temp_allocator)
	if err != nil do return
	v, jerr := json.parse(data, .JSON, true, context.temp_allocator)
	if jerr != nil do return
	obj, ok := v.(json.Object)
	if !ok do return
	if arr, is := obj["packages"].(json.Array); is {
		for e in arr {
			src := ""
			#partial switch x in e {
			case json.String: src = x
			case json.Object: src, _ = x["source"].(json.String)
			}
			add_local(src, base, scope, pkg = true)
		}
	}
	for k in RESOURCE_DIRS {
		if arr, is := obj[k].(json.Array); is do for e in arr do if s, is_s := e.(json.String); is_s do add_local(s, base, scope, pkg = false)
	}
}

// A local path from a settings file: a package (its package.json, its
// resource folders, the folders its "pi" manifest names) or a resource
// file or folder.
@(private = "file")
add_local :: proc(spec, base, scope: string, pkg: bool) {
	s := strings.trim_space(spec)
	if s == "" || s[0] == '-' || s[0] == '!' do return
	if s[0] == '+' do s = s[1:]
	if c := strings.index_byte(s, ':'); c >= 0 && (strings.index_byte(s, '/') < 0 || c < strings.index_byte(s, '/')) do return // npm:, git:, https:, builtin:
	if strings.has_prefix(s, "~/") do s = strings.concatenate({os.get_env("HOME", context.temp_allocator), s[1:]}, context.temp_allocator)
	p := s
	if !filepath.is_abs(p) do p, _ = filepath.join({base, p}, context.temp_allocator)
	p, _ = filepath.clean(p, context.temp_allocator)
	if g := strings.index_any(p, "*?[{"); g >= 0 do p = filepath.dir(p[:g + 1]) // a glob: the folder before it
	switch path_kind(p) {
	case .File:
		add_file(p, scope)
	case .Dir:
		if !pkg {
			add_dir(p, scope)
			return
		}
		pj := fmt.tprintf("%s/package.json", p)
		add_file(pj, scope)
		for d in RESOURCE_DIRS do if path_kind(fmt.tprintf("%s/%s", p, d)) == .Dir do add_dir(fmt.tprintf("%s/%s", p, d), scope)
		// the manifest's paths: the folder each starts in
		data, err := os.read_entire_file(pj, context.temp_allocator)
		if err != nil do return
		v, jerr := json.parse(data, .JSON, true, context.temp_allocator)
		if jerr != nil do return
		root, ok := v.(json.Object)
		if !ok do return
		man, mok := root["pi"].(json.Object)
		if !mok do return
		for k in RESOURCE_DIRS {
			arr, is := man[k].(json.Array)
			if !is do continue
			for e in arr {
				rel, is_s := e.(json.String)
				if !is_s do continue
				rel = strings.trim_prefix(strings.trim_prefix(rel, "!"), "./")
				first, _, _ := strings.partition(rel, "/")
				if first == "" || first == ".." || strings.index_any(first, "*?[{") >= 0 do continue
				at := fmt.tprintf("%s/%s", p, first)
				if path_kind(at) == .Dir do add_dir(at, scope)
				else if path_kind(at) == .File do add_file(at, scope)
			}
		}
	case .Missing, .Other:
	}
}

// For tests: the sources now (path → scope; folders end in "/").
reload_sources_for_test :: proc() -> map[string]string {
	m := make(map[string]string, context.temp_allocator)
	for s in rw.srcs do m[s.dir ? strings.concatenate({s.path, "/"}, context.temp_allocator) : s.path] = s.scope
	return m
}
