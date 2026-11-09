package core

// What a window in another process shows of the core's runtime that is not State (a separate
// core, docs/plans/background-core.md §10.3 M4-C): the state stream's `live` section, as
// Tab_Live is for one tab. Filled by the core's tick only while a window is attached over
// core.sock (core_live_tick); zero in process, where the window reads the runtime itself.
// The window's helpers (update_view, harness_run_now, wt_cleanup_phase…) read it when
// replica_process is set.

import "base:runtime"
import "core:mem/virtual"
import "core:strings"

Core_Live :: struct {
	update:   Update_Live, // the update bar (ui_update.odin)
	harness:  Harness_Run_Live, // the setup sheet's install run (ui_harness.odin)
	cleanups: []Wt_Cleanup_Live, // the worktree switcher's clean ups in flight or failed
	watch:    []string, // pi's config folders the window's file watcher watches for hot reload (reload_watch_dirs)
}

Update_Live :: struct {
	current:   string, // the running version ("" = a development build)
	phase:     Update_Phase,
	release:   Release, // the latest release seen
	offered:   bool,
	dismissed: bool,
	message:   string,
	checks_off: bool,
	cannot:    string, // update_cannot_install(): why Update cannot go ahead ("" = it can)
	can_install: bool, // ...leaving the release aside (get_state's update.can_install)
	skipped:   string,
	last_ok:   i64, // the last good check (unix seconds)
	effects:   string, // update_restart_effects when it matters (the Ready bar's words; "" = none)
}

Harness_Run_Live :: struct {
	term_id: u64, // its terminal (streamed like a tab's: term.attach by this id)
	item:    string,
	action:  Harness_Action,
	command: string,
	status:  Harness_Run_Status,
	exit:    Exit_Info,
}

Wt_Cleanup_Live :: struct {
	path:  string,
	phase: string, // wt_cleanup_phase ("" = none running)
	error: string, // wt_cleanup_error
}

@(private = "file")
live_arena: virtual.Arena // what state.live points into (the core's; a replica's is the replica's)

// The update bar's facts, from the core's own update state (in a core, or in process).
update_live_now :: proc(allocator := context.temp_allocator) -> Update_Live {
	s :: proc(x: string, a: runtime.Allocator) -> string {return strings.clone(x, a)}
	u := Update_Live {
		current = s(upd.current, allocator), phase = upd.phase, offered = upd.offered, dismissed = upd.dismissed,
		message = s(upd.message, allocator), checks_off = upd.checks_off, cannot = s(update_cannot_install(), allocator),
		can_install = update_cannot_install(release = false) == "", skipped = s(upd.skipped, allocator), last_ok = upd.last_ok,
	}
	u.release = upd.release
	u.release.version, u.release.tag, u.release.notes_url = s(upd.release.version, allocator), s(upd.release.tag, allocator), s(upd.release.notes_url, allocator)
	if upd.phase == .Ready {
		keeps := holder_keeps_sessions()
		if quit_would_stop(keeps) || jobs_any_running() || keeps do u.effects = s(update_restart_effects(keeps), allocator)
	}
	return u
}

// What the window reads of the update: the core's (a replica's live section) or this process's.
update_view :: proc() -> Update_Live {
	if replica_process do return state.live.update
	return update_live_now()
}

// The setup sheet's install run: the core's (a replica's live section) or this process's.
harness_run_now :: proc() -> Harness_Run_Live {
	if replica_process do return state.live.harness
	r := harness_run
	return {term_id = r.term_id, item = r.item, action = r.action, command = r.command, status = r.status, exit = r.exit}
}

// Each tick, while a window is attached over core.sock: state.live again, if it changed (made
// in the temp allocator to compare, then again in an arena of its own).
core_live_tick :: proc() {
	if !window_link_is_sock() do return
	l := live_make(context.temp_allocator)
	if live_same(&l, &state.live) do return
	fresh: virtual.Arena
	if virtual.arena_init_growing(&fresh) != nil do return
	virtual.arena_destroy(&live_arena)
	live_arena = fresh
	state.live = live_make(virtual.arena_allocator(&live_arena))
	window_state_changed()
}

@(private = "file")
live_make :: proc(a: runtime.Allocator) -> Core_Live {
	l: Core_Live
	l.update = update_live_now(a)
	if harness_run.status != .None {
		l.harness = {term_id = harness_run.term_id, item = strings.clone(harness_run.item, a), action = harness_run.action, command = strings.clone(harness_run.command, a), status = harness_run.status, exit = harness_run.exit}
	}
	l.cleanups = wt_cleanups_live(a)
	dirs := reload_watch_dirs()
	l.watch = make([]string, len(dirs), a)
	for d, i in dirs do l.watch[i] = strings.clone(d, a)
	return l
}

@(private = "file")
live_same :: proc(a, b: ^Core_Live) -> bool {
	x, y := strings.builder_make(context.temp_allocator), strings.builder_make(context.temp_allocator)
	wire_write(&x, a, type_info_of(Core_Live))
	wire_write(&y, b, type_info_of(Core_Live))
	return strings.to_string(x) == strings.to_string(y)
}
