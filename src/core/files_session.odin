package core

// A project's Files session: the files the user opened in the project with no session of it on
// screen, as tabs, with no agent (Session_Agent.Files). At most one per project; nothing runs in
// it (terminals, browser, app and agent tabs are refused: the session holder never holds one of
// its tabs), it has no main tab (any tab closes; the last one closes the session), and it is
// saved by the project's folder ("files_sessions", persist.odin) so its file tabs come back.
//
// Who makes one: only the user, at this window or in a paired browser's Files tree (the ui
// caller, never over a hub link); scripts, agents and other machines' cores keep the refusal
// (no_session_for_file). Opening goes by the file's project: a file of another project than the
// Files session on screen opens in that project's Files session (made if needed).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Which the Files tree shows: what the user did last, showing a session (it shows that session's
// folder) or selecting a project in the sidebar (that project's, while a session of another
// project stays on screen). Seen from State as it changes (the current session and when it was
// last shown, the selected project), by this process alone: not in State, not on the wire, not
// saved; a relaunch starts on the session again.
@(private = "file")
files_follow: struct {
	session:    u64,
	shown_at:   i64,
	project:    u64,
	by_project: bool,
}

// The user clicked the selected project's row again (ui_sidebar.odin): the tree shows it, while
// a session of another project stays on screen. This window's alone, as files_follow.
files_tree_pick_project :: proc() {
	if cs := cur(); cs != nil do files_tree_follows_session(cs) // seen first, so this is the latest
	files_follow.by_project = true
}

// True: the Files tree shows cs's folder (cs on screen); false: the selected project's.
files_tree_follows_session :: proc(cs: ^Open_Session) -> bool {
	f := &files_follow
	if cs.id != f.session || cs.shown_at != f.shown_at {
		f.session, f.shown_at, f.project, f.by_project = cs.id, cs.shown_at, state.selected_project, false
	} else if state.selected_project != f.project {
		f.project, f.by_project = state.selected_project, true
	}
	if !f.by_project do return true
	p := find_project(state.selected_project)
	if p == nil || p.machine != 0 || p.group != .Projects do return true
	return cs.project_id == p.id // its own project: the session's folder (a worktree's checkout)
}

// The name the Files tab's header gives the folder it shows: its project's, as the sidebar names
// it, else the folder's.
files_tree_name :: proc() -> string {
	base := files_base()
	if base == "" do return ""
	if p := file_project(strings.concatenate({base, "/x"}, context.temp_allocator)); p != nil do return project_display(p^)
	return filepath.base(base)
}

// At most this many Files sessions, and file tabs in each, come back from the saved workspace.
FILES_SESSIONS_MAX :: 64
FILES_TABS_MAX :: 64

// s holds file p: inside its folder, its project's, or the folder its project's Files tree shows
// (a checkout). A file a nested project or a worktree inside it also holds stays in s.
session_holds_file :: proc(s: ^Open_Session, p: string) -> bool {
	rp := fs_real(p)
	if s.cwd != "" && within(rp, fs_real(s.cwd)) do return true // no folder: none of it
	if proj := find_project(s.project_id); proj != nil && proj.machine == 0 {
		root := fs_real(proj.cwd)
		if within(rp, root) || within(rp, files_root_for(root)) do return true
	}
	return false
}

// The user's open may make a project's Files session.
files_session_may_create :: proc(caller: Caller) -> bool {
	return caller.kind == .UI && !caller_from_hub(caller)
}

// The local project a file is in: its folder, or the checkout its Files tree shows (the deepest
// project when they nest); nil = none (or a relative path).
file_project :: proc(path: string) -> ^Project {
	if !filepath.is_abs(path) do return nil
	rp := fs_real(path)
	best: ^Project
	best_n := 0
	for &p in state.projects {
		if p.group != .Projects || p.machine != 0 || p.missing do continue
		root := fs_real(p.cwd)
		at := within(rp, root) ? len(root) : 0
		if at == 0 do if co := files_root_for(root); co != root && within(rp, co) do at = len(co)
		if at > best_n do best, best_n = &p, at
	}
	return best
}

// The project's Files session, nil = none.
files_session_of :: proc(project_id: u64) -> ^Open_Session {
	for &s in state.open_sessions do if s.agent == .Files && s.machine == 0 && s.project_id == project_id do return &s
	return nil
}

// The project's Files session, made (empty, not current) when there is none.
files_session_ensure :: proc(p: ^Project) -> ^Open_Session {
	if s := files_session_of(p.id); s != nil do return s
	// no pane until its first tab (pane_add_tab makes it): a session without panes is whole
	s := Open_Session{id = new_id(), agent = .Files, project_id = p.id, cwd = strings.clone(p.cwd)}
	append(&state.open_sessions, s)
	files_made[s.id] = time.tick_now()
	return &state.open_sessions[len(state.open_sessions) - 1]
}

// When each Files session was made or last given an open, until it has a tab (files_sessions_sweep),
// and the opens of each on their way to the window (an answer still to come).
@(private = "file")
files_made: map[u64]time.Tick
@(private = "file")
files_pending: map[u64]int

// An open of a file into s is on its way to the window (s a Files session): s is not closed or
// swept for being empty before its answer (files_open_end).
files_open_begin :: proc(s: ^Open_Session) {
	if s == nil || s.agent != .Files do return
	files_pending[s.id] += 1
	files_made[s.id] = time.tick_now()
}

// An open of a file into Files session id is on its way.
files_open_pending :: proc(id: u64) -> bool {return files_pending[id] > 0}

// Its answer came: true when no other open of that session is on its way.
files_open_end :: proc(id: u64) -> bool {
	n, ok := files_pending[id]
	if !ok do return true
	if n <= 1 {
		delete_key(&files_pending, id)
		return true
	}
	files_pending[id] = n - 1
	return false
}

FILES_SWEEP_AFTER :: 30 * time.Second

// A Files session made for a file the window never opened (its answer did not come: the window
// went, or the request was dropped) closes: one left without tabs a while after it was made.
// Run from the core's tick (core_loop.odin).
files_sessions_sweep :: proc(after := FILES_SWEEP_AFTER) {
	if len(files_made) == 0 do return
	gone := make([dynamic]u64, context.temp_allocator)
	empty := make([dynamic]u64, context.temp_allocator)
	for id, at in files_made {
		s := find_session(id)
		stale := time.tick_since(at) >= after
		if s == nil || stale do delete_key(&files_pending, id) // gone, or answers that never came (the window went): forgotten
		switch {
		case s == nil:          append(&gone, id)
		case len(s.tabs) > 0:   if !files_open_pending(id) do append(&gone, id) // its file came: nothing to sweep
		case stale:             append(&gone, id); append(&empty, id)
		}
	}
	for id in gone do delete_key(&files_made, id)
	for id in empty do if files_session_close_if_empty(id, {kind = .Internal}) do window_state_changed()
}

// Why s cannot hold what (a terminal, a browser tab, …): "" = it can (not a Files session).
files_only_refusal :: proc(s: ^Open_Session, what: string) -> string {
	if s == nil || s.agent != .Files do return ""
	name := "this project"
	if p := find_project(s.project_id); p != nil do name = project_display(p^) // as the sidebar names it
	return fmt.tprintf("Start a session in %s for %s", name, what)
}

// The session's main tab (pi's, or a Claude-only session's Claude tab: its first), 0 = none (a
// Files session's tabs are all files).
session_main_tab :: proc(s: ^Open_Session) -> u64 {
	if s == nil || s.agent == .Files || len(s.tabs) == 0 do return 0
	return s.tabs[0].id
}

// How many of s.tabs come before any other tab (the main tab stays first): 1, or 0 for a Files
// session.
session_main_count :: proc(s: ^Open_Session) -> int {
	return s.agent == .Files ? 0 : min(1, len(s.tabs))
}

// A saved file tab comes back when the normal open rules still allow it: a regular file, never an
// agent's sign-ins, inside the project (or the checkout its Files tree shows).
files_restore_ok :: proc(p: ^Project, path: string) -> bool {
	if !filepath.is_abs(path) || settings_credential(path) do return false
	if path_kind(path) != .File do return false
	rp := fs_real(path)
	if settings_credential(rp) do return false
	root := fs_real(p.cwd)
	return within(rp, root) || within(rp, files_root_for(root))
}

// One saved Files session back (persist.odin): its project's, with the tabs that still pass
// files_restore_ok, not started (they open when it is shown). nil = nothing came back.
files_session_restore :: proc(p: ^Project, tabs: []Restore_Tab) -> ^Open_Session {
	if p == nil || p.machine != 0 || files_session_of(p.id) != nil || !os.is_dir(p.cwd) do return nil
	keep := make([dynamic]Restore_Tab, context.temp_allocator)
	for rt in tabs {
		if rt.kind != .Editor && rt.kind != .Markdown do continue
		if files_restore_ok(p, rt.cwd) do append(&keep, rt)
	}
	if len(keep) == 0 do return nil
	s := Open_Session{id = new_id(), agent = .Files, project_id = p.id, cwd = strings.clone(p.cwd), restored = true}
	restore_tabs(&s, keep[:])
	if len(s.tabs) == 0 {
		session_panes_free(&s)
		delete(s.tabs)
		delete(s.cwd)
		return nil
	}
	if s.active_tab == 0 do session_show_tab(&s, s.tabs[0].id)
	append(&state.open_sessions, s)
	return &state.open_sessions[len(state.open_sessions) - 1]
}
