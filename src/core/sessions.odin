package core

// pi stores sessions as ~/.pi/agent/sessions/--<cwd with / -> ->--/<timestamp>_<id>.jsonl.
// The first line is a header with the real cwd (the dir name is lossy:
// dashes in paths are ambiguous). Titles: titles.odin (pi's rule, cached).

import "core:encoding/json"
import jg "../jsonguard"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

// Left column groups. Projects come from pi's session dirs plus the ones
// added by hand. Chats is one project-like entry (group .Chats) for
// project-less sessions: full pi (read-only if Settings.chats_readonly) run
// in a visible folder, <main folder>/chats or ~/Chats by default (folder_of(.Chats), folders.odin), with pi's
// normal store, so `cd ~/Chats && pi --resume` finds them. That folder is
// never also a project; its sessions are listed in state.chats.
Sidebar_Group :: enum {
	Projects,
	Chats,
}

Project :: struct {
	id:      u64, // runtime id, kept across rescans (matched by cwd)
	machine: u64, // another machine's, mirrored (machine_mirror.odin: its number; 0 = this Mac's)
	group:   Sidebar_Group,
	name:    string, // display name; "" = use label
	dir:     string, // full path of the session directory
	cwd:     string,
	label:   string, // last path components, for the list
	newest:  time.Time, // newest session file's modification time
	created: time.Time, // oldest session file's modification time (zero: none)
	added:   time.Time, // added by hand in this run (zero: found by the scan)
	missing: bool, // cwd does not exist (any more)
	repo:    bool, // cwd has a .git (a repository's root, or a worktree): always a top-level row
	by_hand: bool, // added by hand (add_project; saved): a top-level row
	claude:  bool, // only found in a Claude Code account's projects/ (claude_disk.odin; saved): a Rescan that does not find it again drops it
	// project_tidy.odin: a temp folder; the listed project this one's row is
	// nested under (0 = none), or the folder of the group row it is in ("" = none)
	temp:      bool,
	parent:    u64,
	group_dir: string,
	group_in:  u64, // in a group row: the listed project that row is nested under (0 = top level)
	group_up:  string, // in a group row: the folder of the group row that row is inside ("" = none)
}

Session :: struct {
	id:       string, // pi's session id, from the file name
	path:     string,
	when_:    string, // "2026-08-21 01:20" from the file name (UTC): created
	title:    string, // name, first prompt or goal (titles.odin); "" = none
	untitled: string, // "Untitled session · <when_>" for a file without a title
	modified: time.Time, // the file's modification time: last activity
	claude:   bool, // a Claude Code session (Deckhand's history, or found on disk: claude_disk.odin), not a pi file
	account:  string, // Claude: its account's config folder ("" = the default)
	found:    bool, // Claude: a transcript found on disk, not in Deckhand's history
	gone:     bool, // Claude: Deckhand's history entry whose transcript is gone (greyed)
}

@(private = "file")
sessions_arena: virtual.Arena
@(private = "file")
chats_arena: virtual.Arena

SCAN_CHUNK :: 64 * 1024
MAX_SESSIONS :: 300

// pi's session store: <agent dir>/sessions (pi_agent_dir: PI_CODING_AGENT_DIR, else ~/.pi/agent).
sessions_root :: proc(allocator := context.allocator) -> string {
	p, _ := filepath.join({pi_agent_dir(), "sessions"}, allocator)
	return p
}

// One scan of pi's store: the project list and the arena it lives in.
Scan_Result :: struct {
	arena:    virtual.Arena,
	projects: [dynamic]Project,
}

// The scan state.projects currently points into.
@(private = "file")
current_scan: ^Scan_Result

// Lists project dirs that contain at least one .jsonl, newest first, into
// `scan`. Touches no State: safe on a worker thread (Rescan).
scan_projects :: proc(scan: ^Scan_Result) {
	_ = virtual.arena_init_growing(&scan.arena)
	context.allocator = virtual.arena_allocator(&scan.arena)
	scan.projects = make([dynamic]Project)

	root := sessions_root()
	dirs, _ := os.read_all_directory_by_path(root, context.allocator) // none: no pi sessions (Claude's may still be there)
	for d in dirs {
		if d.type != .Directory do continue
		files, ferr := os.read_all_directory_by_path(d.fullpath, context.allocator)
		if ferr != nil do continue
		newest, oldest: ^os.File_Info
		for &f in files {
			if !is_session_file(f) do continue
			if newest == nil || time.diff(newest.modification_time, f.modification_time) > 0 do newest = &f
			if oldest == nil || time.diff(f.modification_time, oldest.modification_time) > 0 do oldest = &f
		}
		if newest == nil do continue
		cwd := header_cwd(newest.fullpath)
		if cwd == "" do cwd = decode_dir_name(d.name)
		append(&scan.projects, Project{dir = d.fullpath, cwd = cwd, label = short_label(cwd), newest = newest.modification_time, created = oldest.modification_time, missing = !os.exists(cwd), repo = is_repo_root(cwd)})
	}
	claude_scan_projects(&scan.projects) // folders where only Claude Code ran (claude_disk.odin)
	slice.sort_by(scan.projects[:], proc(a, b: Project) -> bool {return time.diff(b.newest, a.newest) < 0})
}

// Main thread: makes `scan` the project list. Projects keep their id and
// name across scans (matched by cwd); projects added by hand that have no
// sessions yet stay at the top. The Chats entry (when Deckhand has a data
// dir) is last. Takes ownership of `scan`.
apply_scan :: proc(scan: ^Scan_Result) {
	heap := context.allocator
	context.allocator = virtual.arena_allocator(&scan.arena)
	kept := make([dynamic]Project)
	// the Chats folder's store entry is Chats, not a project
	chats: Project
	if home_root != "" {
		chats = Project{group = .Chats, label = "Chats", cwd = strings.clone(chats_cwd())}
		for p, i in scan.projects do if p.cwd == chats.cwd {
			chats.dir, chats.newest, chats.created = p.dir, p.newest, p.created
			ordered_remove(&scan.projects, i)
			break
		}
		if chats.dir == "" do chats.dir = strings.clone(pi_store_dir(chats.cwd))
	}
	for &p in scan.projects {
		p.id = 0
		for o in state.projects {
			if o.group != .Projects || o.machine != 0 || o.cwd != p.cwd do continue
			p.id = o.id
			p.added = o.added
			p.by_hand = o.by_hand
			if o.name != "" do p.name = strings.clone(o.name)
		}
		if p.id == 0 do p.id = new_id()
	}
	chats_id: u64
	for o in state.projects {
		if o.machine != 0 do continue // another machine's: added again below (machines_projects_again)
		if o.group == .Chats {
			chats_id = o.id
			continue
		}
		found := home_root != "" && o.cwd == chats.cwd // a project added at the Chats folder goes
		for p in scan.projects do if p.cwd == o.cwd do found = true
		if !found && o.dir == "" {
			// a folder only Claude ran in that this scan did not find (its account removed, its
			// transcripts gone): dropped unless the user added or named it or a session is open in it
			if o.claude && !o.by_hand && o.name == "" {
				open := false
				for s in state.open_sessions do if s.project_id == o.id do open = true
				if !open do continue
			}
			append(&kept, Project{id = o.id, cwd = strings.clone(o.cwd), label = strings.clone(o.label), name = strings.clone(o.name), added = o.added, by_hand = o.by_hand, claude = o.claude, missing = !os.exists(o.cwd), repo = is_repo_root(o.cwd)})
		}
	}
	inject_at(&scan.projects, 0, ..kept[:])
	if home_root != "" {
		if chats_id == 0 do chats_id = new_id()
		chats.id = chats_id
		append(&scan.projects, chats)
	}
	state.projects = scan.projects
	projects_tidy() // temp and missing folders, nested and grouped rows
	machines_projects_again() // other machines' projects (machine_mirror.odin)
	if current_scan != nil {
		virtual.arena_destroy(&current_scan.arena)
		free(current_scan, heap)
	}
	current_scan = scan
	context.allocator = heap
	if p := find_project(state.selected_project); p == nil || p.group != .Projects {
		state.selected_project = 0
		for q in state.projects do if q.group == .Projects {
			state.selected_project = q.id
			break
		}
	}
	// one main-thread budget for reading titles (titles.odin) in the whole rescan
	budget := i64(TITLE_INLINE_BUDGET)
	if p := find_project(state.selected_project); p != nil && p.machine != 0 {
		// another machine's: its core lists its sessions (machine_mirror.odin)
	} else if p != nil && p.dir != "" do scan_sessions(p^, &budget)
	else do clear(&state.sessions)
	scan_chats(&budget)
	claude_disk_rescan() // Claude Code's transcripts of the selected project and Chats (claude_disk.odin)
}

// A copy of s that lives as long as the project list (Project fields).
project_string :: proc(s: string) -> string {
	if current_scan == nil do return strings.clone(s)
	return strings.clone(s, virtual.arena_allocator(&current_scan.arena))
}

// The folder chats run in (temp): folder_of(.Chats) (its override, else
// <main folder>/chats, else ~/Chats); its real path once it exists (pi's cwd,
// and so its store dir, has no symlinks).
chats_cwd :: proc() -> string {
	return real_path(folder_of(.Chats))
}

// p with symlinks resolved if it exists, else p (temp).
real_path :: proc(p: string) -> string {
	buf: [posix.PATH_MAX]u8
	if r := posix.realpath(strings.clone_to_cstring(p, context.temp_allocator), raw_data(buf[:])); r != nil do return strings.clone(string(r), context.temp_allocator)
	return p
}

// The Chats entry in state.projects, or nil (no data dir).
chats_project :: proc() -> ^Project {
	for &p in state.projects do if p.group == .Chats do return &p
	return nil
}

// Lists the chats (state.chats), newest first.
scan_chats :: proc(budget: ^i64 = nil) {
	p := chats_project()
	read_sessions(p != nil ? p.dir : "", &chats_arena, &state.chats, true, budget)
}

// Synchronous scan (startup).
rescan_now :: proc(claude := true) {
	// a Rescan's worker reads the account folders now: leave them, and scan once more after it
	if scan_thread != nil {
		claude_rescan_again = true
		scan := new(Scan_Result)
		scan_projects(scan)
		apply_scan(scan)
		return
	}
	claude_scan_prepare() // each account's folder, for the scan (claude_disk.odin)
	// the launch's: no transcript read on the main thread, and the saved accounts are not back
	// yet; a Rescan after them finds Claude's projects (claude_startup_rescan_due)
	if !claude do claude_scan_clear()
	scan := new(Scan_Result)
	scan_projects(scan)
	apply_scan(scan)
}

// Where pi keeps the sessions of `cwd` in its default store (temp):
// "/Users/me/proj" -> <root>/--Users-me-proj--. For projects the scan has
// not seen yet (a new chat in a project added by hand).
pi_store_dir :: proc(cwd: string) -> string {
	name, _ := strings.replace_all(strings.trim_prefix(cwd, "/"), "/", "-", context.temp_allocator)
	p, _ := filepath.join({sessions_root(context.temp_allocator), strings.concatenate({"--", name, "--"}, context.temp_allocator)}, context.temp_allocator)
	return p
}

// A session file in a listing: a regular file (or a link to one) named
// "*.jsonl". pi-subagents keeps a folder named "<timestamp>_<id>" beside
// each session that ran subagents: never a session.
is_session_file :: proc(f: os.File_Info) -> bool {
	if !strings.has_suffix(f.name, ".jsonl") do return false
	return f.type == .Regular || (f.type == .Symlink && os.is_file(f.fullpath))
}

// The session file for pi session id `id` among `files` ("" = none).
session_file_among :: proc(files: []os.File_Info, id: string) -> string {
	for f in files do if is_session_file(f) && session_id_from_name(f.name) == id do return f.fullpath
	return ""
}

// "<timestamp>_<id>.jsonl" -> "<id>"
session_id_from_name :: proc(name: string) -> string {
	base := strings.trim_suffix(name, ".jsonl")
	if i := strings.index_byte(base, '_'); i >= 0 do return base[i + 1:]
	return base
}

// Lists the sessions of one project, newest first (file names sort by time):
// only those run in its own folder (a subfolder is a project of its own).
scan_sessions :: proc(p: Project, budget: ^i64 = nil) {
	read_sessions(p.dir, &sessions_arena, &state.sessions, budget = budget)
}

// The sessions in `dir` into `out`, newest first (at most MAX_SESSIONS), in
// a fresh `arena` (the old list goes with the old arena).
@(private = "file")
read_sessions :: proc(dir: string, arena: ^virtual.Arena, out: ^[dynamic]Session, chat := false, budget: ^i64 = nil) {
	virtual.arena_destroy(arena)
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	out^ = make([dynamic]Session)

	if dir == "" do return

	files, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil do return
	names := make([dynamic]os.File_Info)
	for f in files do if is_session_file(f) do append(&names, f)
	slice.sort_by(names[:], proc(a, b: os.File_Info) -> bool {return a.name > b.name})
	own := i64(TITLE_INLINE_BUDGET)
	budget := budget != nil ? budget : &own
	for f in names[:min(len(names), MAX_SESSIONS)] {
		when_ := name_time(f.name)
		append(out, Session{id = session_id_from_name(f.name), path = f.fullpath, when_ = when_, title = title_of(f.fullpath, f.size, f.modification_time, budget), untitled = untitled_label(chat, when_), modified = f.modification_time})
	}
}

// "Untitled chat · 2026-08-21 01:20" (a chat) or "Untitled session · …".
untitled_label :: proc(chat: bool, when_: string, allocator := context.allocator) -> string {
	return strings.concatenate({chat ? "Untitled chat" : "Untitled session", " · ", when_}, allocator)
}

// The listed sessions take the titles the worker read (titles_tick); only
// changed ones are copied into the lists' arenas.
refresh_listed_titles :: proc() {
	for &s in state.sessions do if t := title_cached(s.path, context.temp_allocator); t != s.title do s.title = strings.clone(t, virtual.arena_allocator(&sessions_arena))
	for &s in state.chats do if t := title_cached(s.path, context.temp_allocator); t != s.title do s.title = strings.clone(t, virtual.arena_allocator(&chats_arena))
}

// Whether `list` has the pi session `id`.
session_listed :: proc(list: []Session, id: string) -> bool {
	for s in list do if s.id == id do return true
	return false
}

// "2026-08-21T01-20-21-137Z_<id>.jsonl" -> "2026-08-21 01:20"
name_time :: proc(name: string) -> string {
	if len(name) < 16 || name[10] != 'T' do return name
	return strings.concatenate({name[:10], " ", name[11:13], ":", name[14:16]})
}

// "--Users-me-proj--" -> "/Users/me/proj" (lossy fallback only)
decode_dir_name :: proc(name: string) -> string {
	s := strings.trim(name, "-")
	out, _ := strings.replace_all(s, "-", "/")
	return strings.concatenate({"/", out})
}

short_label :: proc(cwd: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(cwd, home) do return strings.concatenate({"~", cwd[len(home):]})
	return cwd
}

@(private = "file")
read_chunk :: proc(path: string, size: i64) -> []u8 {
	f, err := os.open(path)
	if err != nil do return nil
	defer os.close(f)
	n := min(size, i64(SCAN_CHUNK))
	buf := make([]u8, n, context.temp_allocator)
	got, _ := os.read_at(f, buf, 0)
	return buf[:got]
}

header_cwd :: proc(path: string) -> string {
	buf := read_chunk(path, SCAN_CHUNK)
	nl := strings.index_byte(string(buf), '\n')
	if nl < 0 do return ""
	v, err := jg.parse(buf[:nl], .JSON, allocator = context.temp_allocator) // pi writes it (JSON.stringify)
	if err != nil do return ""
	obj, ok := v.(json.Object)
	if !ok do return ""
	cwd, _ := obj["cwd"].(json.String)
	return strings.clone(cwd)
}
