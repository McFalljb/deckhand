package main

// The Home session (docs/ROADMAP.md G9): Deckhand's own pi, the built-in
// agent ("Atlas", agent.odin), which drives the app through the control
// socket (the pi integration's `desk` extension, integrations/pi). It is an open session without a
// project, with only its pi tab (its terminal shows in the drawer, ⌘J), not
// listed with the projects. It starts on
// the first open (lazy) and resumes its pi session across restarts
// (docs/PERSISTENCE.md).
//
// Where it lives: sessions in <data dir>/home (pi --session-dir), so they
// stay out of pi's project store and the left column; cwd = the main folder,
// else the data dir's home/ (home_cwd: never ~, for macOS privacy prompts).
// Home works across every project by absolute path (desk_state lists them).
//
// Its environment carries a bridge token (DECKHAND_TOKEN: its status) and
// DECKHAND_CONTROL_TOKEN, a single-use control token bound to Home's tab
// (agent_env): the hello result's tab_id is Home's tab, and that tab and
// session are off limits to it (owns_tab).

import "core:crypto/hash"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Deckhand's data dir as the app uses it (set at startup; test mode: the
// test data dir). "" = no Home.
home_root: string

home_dir :: proc() -> string {
	d, _ := filepath.join({home_root, "home"}, context.allocator)
	os.make_directory_all(d, {.Read_User, .Write_User, .Execute_User})
	return d
}

// Where Atlas runs: the main folder when it is set and reachable, else the
// data dir's home/; never the user's home folder (also when the main folder
// is ~ itself). Atlas is Deckhand's child, so macOS privacy (TCC) counts what
// it touches as Deckhand's: from ~, an `ls`, `find .` or `grep -r` walks into
// Desktop, Documents and Downloads and asks "Deckhand would like to access…".
// Read at each start of Atlas's pi (start_restored_tabs): a new main folder
// applies at Atlas's next start.
home_cwd :: proc() -> string {
	if m := state.settings.home_dir; m != "" && os.is_dir(m) {
		h := os.get_env("HOME", context.temp_allocator)
		if h == "" || real_path(m) != real_path(h) do return strings.clone(m)
	}
	return home_dir()
}

// The oldest pi with `--fork <file> --session-id <id>` (both in 0.76 and later; checked in
// 1.4.0's source, PI_MIN_VERSION). A pi known to be older: Atlas resumes, never forks.
PI_FORK_MIN_PI :: "1.4.0"

pi_fork_too_old :: proc() -> bool {
	v, ok := semver_parse(state.reload.pi_version)
	if !ok do return false
	min, _ := semver_parse(PI_FORK_MIN_PI)
	return semver_less(v, min)
}

// The session file whose fork failed in this run of Deckhand (home_fork_exited): resumed, not
// forked again until the next launch ("" = none).
home_fork_skip: string

// The id Atlas's session `old_id` gets when forked into folder `cwd` (a real path): a
// name-based UUID (v8, SHA-256), so every attempt at the same move lands on the same id,
// whatever was saved before a crash.
home_fork_id :: proc(old_id, cwd: string) -> string {
	ns := uuid.Identifier{0x6d, 0x0b, 0x2e, 0x51, 0x3c, 0x4a, 0x4f, 0x0e, 0x9a, 0x47, 0x1d, 0x8e, 0x5b, 0x60, 0x2c, 0x73} // Deckhand's Atlas forks
	name := strings.concatenate({old_id, "\x00", cwd}, context.temp_allocator)
	return uuid.to_string(uuid.generate_v8_hash(ns, name, hash.Algorithm.SHA256), context.allocator)
}

// How Atlas's pi starts (start_restored_tabs): the session file it resumes
// ("" = none), or the file it forks into its session id.
//
// pi runs a resumed session in the cwd its header records, not in the cwd it
// was started in. So when that is not home_cwd() (after realpath: Atlas's
// sessions from before it moved out of ~, or a new main folder), Atlas forks
// it: id home_fork_id(old id, folder), whose copy pi writes with cwd =
// home_cwd(); the old file stays as it was. If that id's file is already
// there, it is resumed instead. Never saved here (the normal save cycle does:
// a start can run mid-restore). Until the copy is on disk, state.home_fork_from
// keeps the old file and the same fork is asked again; if pi exits without
// writing it, home_fork_exited goes back to the old session.
//
// Never forked: an unreadable header or one without a cwd (only the header's
// cwd is read: header_cwd, the first line), a pi known to be older than
// PI_FORK_MIN_PI, a main folder set but unreachable (an unmounted volume: a
// copy each time it comes and goes), a fork that failed in this run.
home_session_start :: proc(s: ^Open_Session) -> (path, fork: string) {
	path = session_file_in(s.session_dir, s.pi_session_id)
	m := state.settings.home_dir
	can := !pi_fork_too_old() && (m == "" || os.is_dir(m))
	if p := state.home_fork_from; p != "" {
		if path == "" && path_kind(p) == .File {
			if can do return "", p // the same fork again
			// not now (the main folder went away): the old session, where it was
			delete(s.pi_session_id)
			s.pi_session_id = strings.clone(session_id_from_name(filepath.base(p)))
			path = strings.clone(p, context.temp_allocator)
		}
		delete(state.home_fork_from) // done (or its old file is gone)
		state.home_fork_from = ""
		persist.gen += 1
		if !can do return
	}
	if path == "" || !can || path == home_fork_skip do return
	rc := header_cwd(path)
	defer delete(rc)
	to := real_path(s.cwd)
	if rc == "" || real_path(rc) == to do return
	id := home_fork_id(s.pi_session_id, to)
	if id == s.pi_session_id {
		delete(id)
		return
	}
	fp := session_file_in(s.session_dir, id)
	delete(s.pi_session_id)
	s.pi_session_id = id
	persist.gen += 1
	if fp != "" do return fp, "" // forked before (a save was lost): resumed
	state.home_fork_from = strings.clone(path)
	return "", state.home_fork_from
}

// Atlas's pi exited (Tab_Exited): a fork it was asked for and did not write is
// dropped; the old session is resumed at its next start, where it was.
home_fork_exited :: proc(s: ^Open_Session, tab: ^Tab) {
	from := state.home_fork_from
	if from == "" || session_file_in(s.session_dir, s.pi_session_id) != "" do return
	delete(s.pi_session_id)
	s.pi_session_id = strings.clone(session_id_from_name(filepath.base(from)))
	delete(home_fork_skip)
	home_fork_skip = from // owned now
	state.home_fork_from = ""
	persist.gen += 1
	if t := term_of(tab.id); t != nil do term_note(t, fmt.tprintf("Deckhand: %s could not move its conversation to %s; its next start resumes it where it was.", agent_name(), s.cwd))
}

// The session file for pi session id `id` in `dir` (temp), or "".
session_file_in :: proc(dir, id: string) -> string {
	if dir == "" || id == "" do return ""
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return ""
	return session_file_among(files, id)
}
