package core

// The file-system model behind the editor and the future Files tab: lazy
// directory listings that hide .git and what .gitignore ignores, git status
// per path, the project's file list for "Open file…" (⌘P), and the file
// commands (create, rename, delete to the Trash, reveal in Finder). Folders
// that are listed get watched (editor_watch.odin); a change under one bumps
// fs_model.gen and drops the cached status and file lists.
//
// Paths: absolute, or relative to the current session's folder (else the
// selected project's). Commands only act inside a known project folder
// (projects and open sessions), never on a project root itself, and never
// inside .git.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

Fs_Kind :: enum u8 {
	File,
	Dir,
	Symlink,
}

FS_KIND_NAMES := [Fs_Kind]string {
	.File    = "file",
	.Dir     = "dir",
	.Symlink = "symlink",
}

Fs_Entry :: struct {
	name: string,
	kind: Fs_Kind,
	git:  string, // porcelain XY code ("M ", "??", "A "...); "" = clean or not in git
	ignored: bool, // gitignored (listed only when asked for)
}

// Per repository: `git status` (relative path -> XY), cached until a change.
Git_Status :: struct {
	root:  string, // repository top level (owned)
	codes: map[string]string, // owned keys and values
	ok:    bool, // codes are current
	loading: bool, // a worker runs git status now (Git_Status_Done)
	gen:     u64, // bumped by every change under root: a status started before one is not ok
	started: time.Tick, // the last run's start: runs are at least FS_STATUS_GAP apart
	want:    bool, // a run was asked for within the gap: fs_model_tick starts it
}

FS_STATUS_GAP :: 1500 * time.Millisecond // between git status runs of one repository
FS_LIST_GAP :: time.Second // between refreshes of one project file list
FS_IGNORED_MAX :: 4096 // ignored paths remembered (the set starts over past it)

// FSEvents flags that mean a folder's entries changed (created, removed,
// renamed, or events dropped / a rescan asked for); a content-only change
// (modified, metadata) does not change a listing or the file list.
FSE_STRUCTURE :: u32(0x1 | 0x2 | 0x4 | 0x20 | 0x100 | 0x200 | 0x800)

// A project's file list (⌘P, the Files filter). After a change it is kept
// (stale) and refreshed on a worker, at most once per FS_LIST_GAP.
File_List :: struct {
	list:    []string, // relative paths, sorted (owned)
	stale:   bool,
	loading: bool,
	last:    time.Tick, // made or refresh started
}

FILE_LIST_MAX :: 50_000

Fs_Model :: struct {
	gen:      u64, // bumped by every change seen under a watched folder
	status:   [dynamic]Git_Status,
	files:    map[string]File_List, // project root (owned) -> its file list
	ignored:  map[string]bool, // gitignored paths seen in listings (owned keys): changes there leave git status alone
	revealed: string, // test mode: what reveal_in_finder would have shown
}

fs_model: Fs_Model

// How often the model ran git or listed folders (tests count these).
Fs_Stats :: struct {
	status_runs:     int, // git status started
	list_runs_sync:  int, // project file lists made on the main thread
	list_runs_async: int, // project file lists refreshed on a worker
	relists:         int, // Files folder listings read
}
fs_stats: Fs_Stats

// Moves a path to the Trash. Tests and test mode swap in a fake that moves
// it into a folder of their own, so the user's Trash never fills up.
fs_trash_fn: proc(path: string) -> bool = fs_trash_or_fake

@(private = "file")
fs_trash_or_fake :: proc(path: string) -> bool {
	if !autotest_active do return platform.trash != nil && platform.trash(path)
	dir := "build/test-trash"
	os.make_directory_all(dir)
	to, _ := filepath.join({dir, fmt.tprintf("%d-%s", fs_model.gen, filepath.base(path))}, context.temp_allocator)
	return os.rename(path, to) == nil
}

// The real path (symlinks resolved): realpath of the longest part that
// exists, then the rest as written (cleaned). Relative paths are from the
// process's folder. Never "" for a non-empty path.
// Whether path is a regular file directly in dir: not a link itself (lstat), and the folder its
// resolved path is in is dir's resolved path exactly. real: that resolved path (temp allocator),
// what the caller uses from the check on.
fs_file_directly_in :: proc(path, dir: string) -> (real: string, ok: bool) {
	if path == "" || dir == "" do return "", false
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK || !posix.S_ISREG(st.st_mode) do return "", false
	real = fs_real(path)
	rdir := fs_real(dir)
	if real == "" || rdir == "" do return "", false
	{
		context.allocator = context.temp_allocator
		if filepath.dir(real) != rdir do return "", false
	}
	return real, true
}

fs_real :: proc(path: string, allocator := context.temp_allocator) -> string {
	if path == "" do return ""
	p := path
	if !filepath.is_abs(p) {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		p, _ = filepath.join({cwd, p}, context.temp_allocator)
	}
	p, _ = filepath.clean(p, context.temp_allocator)
	rest := ""
	for {
		if r := posix.realpath(strings.clone_to_cstring(p, context.temp_allocator), nil); r != nil {
			s := rest == "" ? strings.clone(string(r), allocator) : strings.concatenate({string(r) == "/" ? "" : string(r), "/", rest}, allocator)
			posix.free(r)
			return s
		}
		if p == "/" || p == "" do break
		d, base := filepath.split(p)
		rest = rest == "" ? base : strings.concatenate({base, "/", rest}, context.temp_allocator)
		p = d == "" ? "/" : d
	}
	return strings.clone(p == "/" && rest != "" ? strings.concatenate({"/", rest}, context.temp_allocator) : p, allocator)
}

within :: proc(path, root: string) -> bool {
	return path == root || (strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/')
}

// Every known project folder (projects and open sessions, and the
// checkouts their Files trees show instead: files_set_root), real paths.
fs_roots :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	base := fs_base_roots()
	append(&out, ..base)
	for c in state.files.checkouts do if list_index(base, c.base) >= 0 && list_index(out[:], c.path) < 0 do append(&out, c.path)
	return out[:]
}

// The projects' and open sessions' folders, real paths.
fs_base_roots :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	add :: proc(out: ^[dynamic]string, p: string) {
		if p == "" do return
		r := fs_real(p)
		for x in out do if x == r do return
		append(out, r)
	}
	for p in state.projects do add(&out, p.cwd)
	for s in state.open_sessions do if !s.home do add(&out, s.cwd)
	return out[:]
}

// The folder relative paths start from: the current session's, else the
// selected project's ("" = none).
fs_base_dir :: proc() -> string {
	if cs := cur(); cs != nil && !cs.home do return cs.cwd
	if p := find_project(state.selected_project); p != nil do return p.cwd
	return ""
}

// The open session a caller acts from: a tab-bound caller's own (a pi
// tab's bridge, Home's control), else the one on screen.
caller_session :: proc(caller: Caller) -> ^Open_Session {
	if caller.tab_id != 0 {
		s, _, _ := find_tab(caller.tab_id)
		return s
	}
	return cur()
}

// The folder a caller's relative paths start from: a tab-bound caller's
// session folder, else the session on screen (fs_base_dir).
fs_base_for :: proc(caller: Caller) -> string {
	if caller.tab_id != 0 {
		s := caller_session(caller)
		return s != nil ? s.cwd : ""
	}
	return fs_base_dir()
}

// A tab-bound caller's own project folder, real path ("" = none: unbound,
// or Home).
fs_own_root :: proc(caller: Caller) -> string {
	if caller.tab_id == 0 do return ""
	s := caller_session(caller)
	if s == nil || s.home do return ""
	if p := find_project(s.project_id); p != nil do return fs_real(p.cwd)
	return fs_real(s.cwd)
}

// Whether path is outside the caller's own folders (always, without them):
// its project's folder and its session's folder (a session may run in a
// worktree outside the project folder).
fs_outside_own :: proc(path: string, caller: Caller) -> bool {
	own := fs_own_root(caller)
	if own == "" do return true
	if within(path, own) do return false
	s := caller_session(caller)
	return s == nil || !within(path, fs_real(s.cwd))
}

// An absolute, cleaned path for a command argument (temp allocator):
// relative paths start from the caller's folder (fs_base_for).
fs_abs :: proc(path: string, caller := Caller{kind = .UI}) -> string {
	if path == "" do return ""
	p := path
	if strings.has_prefix(p, "~/") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
	if !filepath.is_abs(p) {
		base := fs_base_for(caller)
		if base == "" do return ""
		p, _ = filepath.join({base, p}, context.temp_allocator)
	}
	c, _ := filepath.clean(p, context.temp_allocator)
	return c
}

// Checks that a command may touch path: inside a project folder, not the
// folder itself (unless allow_root), not inside .git. The parent's real path
// decides (a symlinked folder cannot lead outside). Returns the absolute
// path, its project root, or an error. A pi tab's bridge (panel caller)
// stays inside its own session's project.
fs_check :: proc(path: string, caller: Caller, allow_root := false) -> (abs, root: string, err: string) {
	abs = fs_abs(path, caller)
	if abs == "" do return "", "", "path is empty (or relative with no project selected)"
	parent := fs_real(filepath.dir(abs))
	full, _ := filepath.join({parent, filepath.base(abs)}, context.temp_allocator)
	if allow_root do full = fs_real(abs)
	for r in fs_roots() {
		if !within(full, r) do continue
		if full == r && !allow_root do return "", "", "not on a project folder itself"
		rel := full[len(r):]
		if strings.contains(strings.concatenate({rel, "/"}, context.temp_allocator), "/.git/") do return "", "", "not inside .git"
		if caller.kind == .Panel && fs_outside_own(full, caller) do return "", "", "only inside this session's project folder"
		return full, r, ""
	}
	return "", "", "only inside a project folder"
}

// fs_check for a command that creates, renames or deletes: the user's own
// commands (the Settings tab's row menu) may also act inside pi's prompts/,
// skills/ and extensions/ (settings_editable: never on those folders, never
// a credentials file, and the real folder above it must be there too).
fs_check_write :: proc(path: string, caller: Caller) -> (abs, root: string, err: string) {
	abs, root, err = fs_check(path, caller)
	if err != "" && caller.kind == .UI {
		if p, ok := settings_editable(fs_abs(path, caller)); ok do return p, "", ""
	}
	return
}

// ---- git status ----

@(private = "file")
status_for :: proc(dir: string) -> ^Git_Status {
	for &s in fs_model.status do if within(dir, s.root) do return &s
	top := git_toplevel(strings.concatenate({dir, "/x"}, context.temp_allocator))
	if top == "" do return nil
	top = fs_real(top)
	for &s in fs_model.status do if s.root == top do return &s
	append(&fs_model.status, Git_Status{root = strings.clone(top)})
	return &fs_model.status[len(fs_model.status) - 1]
}

// Starts git status for the repository on a worker thread (the codes come
// back as Git_Status_Done). Until then the old codes (or none) show and
// list_dir says "git_pending".
@(private = "file")
status_load :: proc(s: ^Git_Status) {
	if s.ok || s.loading do return
	// a repository that keeps changing (a build): not back to back
	if s.started != {} && time.tick_since(s.started) < FS_STATUS_GAP {
		s.want = true
		return
	}
	s.want = false
	s.started = time.tick_now()
	s.loading = true
	fs_stats.status_runs += 1
	Job :: struct {
		root: string,
		gen:  u64,
	}
	job := new_clone(Job{strings.clone(s.root, runtime.heap_allocator()), s.gen}, runtime.heap_allocator())
	thread.run_with_poly_data(job, proc(job: ^Job) {
		out, ok := git_run(job.root, "status", "--porcelain=v1", "-z", "--untracked-files=normal")
		inbox_submit(Git_Status_Done{root = job.root, gen = job.gen, ok = ok, out = out}, {kind = .Internal})
		delete(job.root, runtime.heap_allocator())
		free(job, runtime.heap_allocator())
		free_all(context.temp_allocator)
	})
}

// A worker's git status arrived (main thread).
git_status_done :: proc(c: Git_Status_Done) {
	window_state_changed() // the Files tree shows the codes
	s: ^Git_Status
	for &x in fs_model.status do if x.root == c.root do s = &x
	if s == nil do return
	s.loading = false
	for k, v in s.codes {
		delete(k)
		delete(v)
	}
	clear(&s.codes)
	s.ok = c.gen == s.gen // a change since it started: shown, but run again on the next listing
	if !c.ok do return
	rest := c.out
	for len(rest) > 3 {
		i := strings.index_byte(rest, 0)
		rec := i < 0 ? rest : rest[:i]
		rest = i < 0 ? "" : rest[i + 1:]
		if len(rec) < 4 do continue
		code, p := rec[:2], strings.trim_suffix(rec[3:], "/")
		s.codes[strings.clone(p)] = strings.clone(code)
		if code[0] == 'R' || code[0] == 'C' { 	// the old name follows
			j := strings.index_byte(rest, 0)
			rest = j < 0 ? "" : rest[j + 1:]
		}
	}
}

// The git code of a path ("" = clean); folders: "M " when anything below
// changed, "??" when the folder is untracked as a whole.
fs_git_code :: proc(abs: string, is_dir: bool) -> (code: string, pending: bool) {
	s := status_for(is_dir ? abs : filepath.dir(abs))
	if s == nil do return "", false
	status_load(s)
	return git_code_in(s, abs, is_dir), !s.ok
}

// The git code of a path from what is cached (the Files tree, as it draws):
// never runs git here, though a stale status starts a worker. "" = clean,
// unknown yet, or not in a known repository (fs_git_repo registers one).
fs_git_code_cached :: proc(abs: string, is_dir: bool) -> string {
	for &s in fs_model.status {
		if !within(abs, s.root) do continue
		status_load(&s)
		return git_code_in(&s, abs, is_dir)
	}
	return ""
}

// Registers the repository holding dir (runs git once) and starts its
// status. False when dir is not in a repository.
fs_git_repo :: proc(dir: string) -> bool {
	s := status_for(dir)
	if s == nil do return false
	status_load(s)
	return true
}

@(private = "file")
git_code_in :: proc(s: ^Git_Status, abs: string, is_dir: bool) -> string {
	if abs == s.root do return ""
	rel := abs[len(s.root) + 1:]
	if code, ok := s.codes[rel]; ok do return code
	if is_dir {
		prefix := strings.concatenate({rel, "/"}, context.temp_allocator)
		for k, _ in s.codes do if strings.has_prefix(k, prefix) do return "M "
	}
	// inside an untracked folder
	for d := filepath.dir(rel); d != "." && d != "" && d != "/"; d = filepath.dir(d) {
		if code, ok := s.codes[d]; ok && code == "??" do return "??"
	}
	return ""
}

// ---- listing ----

// A folder's entries, folders first, then by name (natural order); .git and
// gitignored entries left out, or kept and marked with with_ignored. Git
// codes for each entry (the List_Dir command). Temp allocator.
fs_list_dir :: proc(dir: string, with_ignored := false) -> (entries: []Fs_Entry, err: string, git_pending: bool) {
	entries, err = fs_read_dir(dir, with_ignored)
	if err != "" do return nil, err, false
	for &e in entries {
		full, _ := filepath.join({dir, e.name}, context.temp_allocator)
		pending: bool
		e.git, pending = fs_git_code(full, e.kind == .Dir)
		git_pending ||= pending
	}
	return entries, "", git_pending
}

// A folder's entries without git codes (the Files tree looks those up as it
// draws): .git and .DS_Store left out; gitignored entries left out unless
// with_ignored (then marked). An error names the folder, or with for_user
// says what the user can do (fs_list_error_text). In an ignored folder (parent_ignored) every
// entry is ignored and git is not asked. Folders first, then natural order.
// Temp allocator.
fs_read_dir :: proc(dir: string, with_ignored := false, parent_ignored := false, for_user := false) -> (entries: []Fs_Entry, err: string) {
	names_read, lerr := fs_read_names(dir)
	if lerr != nil {
		if for_user do return nil, fs_list_error_text(lerr) // the Files tab's row: what to do about it
		return nil, fmt.tprintf("cannot list %s: %s", dir, strings.to_lower(string(posix.strerror(lerr)), context.temp_allocator))
	}
	window_watch_folder(fs_root_of(dir))
	out := make([dynamic]Fs_Entry, 0, len(names_read), context.temp_allocator)
	names := make([dynamic]string, 0, len(names_read), context.temp_allocator)
	for e in names_read {
		if e.name == ".git" || e.name == ".DS_Store" do continue
		append(&out, Fs_Entry{name = e.name, kind = e.kind, ignored = parent_ignored})
		append(&names, e.name)
	}
	kept := out
	if !parent_ignored {
		ignored := git_ignored(dir, names[:])
		kept = make([dynamic]Fs_Entry, 0, len(out), context.temp_allocator)
		for &e in out {
			if ignored[e.name] {
				fs_remember_ignored(dir, e.name)
				if !with_ignored do continue
				e.ignored = true
			}
			append(&kept, e)
		}
	}
	slice.sort_by(kept[:], proc(a, b: Fs_Entry) -> bool {
		if (a.kind == .Dir) != (b.kind == .Dir) do return a.kind == .Dir
		return fs_name_less(a.name, b.name)
	})
	return kept[:], ""
}

// Natural order, as file managers sort: case-insensitive, runs of digits
// by value ("a2" before "a10"); ties by bytes, so the order is total.
fs_name_less :: proc(a, b: string) -> bool {
	is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}
	lower_ascii :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		ca, cb := a[i], b[j]
		if is_digit(ca) && is_digit(cb) {
			// compare the digit runs as numbers: skip leading zeros, then length, then digits
			si, sj := i, j
			for i < len(a) && is_digit(a[i]) do i += 1
			for j < len(b) && is_digit(b[j]) do j += 1
			ra, rb := strings.trim_left(a[si:i], "0"), strings.trim_left(b[sj:j], "0")
			if len(ra) != len(rb) do return len(ra) < len(rb)
			if ra != rb do return ra < rb
			continue
		}
		la, lb := lower_ascii(ca), lower_ascii(cb)
		if la != lb do return la < lb
		i += 1
		j += 1
	}
	if (len(a) - i) != (len(b) - j) do return len(a) - i < len(b) - j
	return a < b
}

// Which of the names in dir git ignores (none outside a repository): one
// git run, the names on its stdin, however many there are.
@(private = "file")
git_ignored :: proc(dir: string, names: []string) -> map[string]bool {
	out := make(map[string]bool, context.temp_allocator)
	if len(names) == 0 do return out
	input := strings.builder_make(context.temp_allocator)
	for n in names {
		strings.write_string(&input, n)
		strings.write_byte(&input, 0)
	}
	res, _ := git_run_input(dir, strings.to_string(input), "check-ignore", "--stdin", "-z") // exit 1 = none ignored
	for p in strings.split(res, "\x00", context.temp_allocator) do if p != "" do out[filepath.base(strings.trim_suffix(p, "/"))] = true
	return out
}

// The innermost known folder (project or session) holding path, real
// path ("" = none): the root of its Files tree (a session in a worktree
// inside its project gets its own tree).
fs_root_longest :: proc(path: string) -> string {
	best := ""
	for r in fs_roots() do if within(path, r) && len(r) > len(best) do best = r
	return best
}

// The innermost known folder strictly above path ("" = none): where a
// folder's open state is kept (files_expand_key). Path as written.
fs_root_above :: proc(path: string) -> string {
	best := ""
	for r in fs_roots() do if path != r && within(path, r) && len(r) > len(best) do best = r
	return best
}

// The project folder holding path ("" = none).
fs_root_of :: proc(path: string) -> string {
	r := fs_real(path)
	for root in fs_roots() do if within(r, root) do return root
	return ""
}

// Main thread, every frame callback (editor_tick): restarts what a rate
// limit held back. Cheap when nothing waits.
fs_model_tick :: proc() {
	for &s in fs_model.status do if s.want && !s.ok && !s.loading && time.tick_since(s.started) >= FS_STATUS_GAP do status_load(&s)
	for root, &fl in fs_model.files do if fl.stale do list_refresh(root, &fl)
	wt_tick()
	changes_tick()
}

// A project file list is being refreshed on a worker.
fs_list_loading :: proc(root: string) -> bool {
	fl, ok := fs_model.files[root]
	return ok && fl.loading
}

@(private = "file")
fs_remember_ignored :: proc(dir, name: string) {
	if len(fs_model.ignored) >= FS_IGNORED_MAX {
		for k in fs_model.ignored do delete(k)
		clear(&fs_model.ignored)
	}
	p := strings.concatenate({dir, "/", name})
	if p in fs_model.ignored do delete(p)
	else do fs_model.ignored[p] = true
}

// Whether path is gitignored, or inside an ignored folder, as far as the
// listings so far have seen.
@(private = "file")
fs_path_ignored :: proc(path: string) -> bool {
	if len(fs_model.ignored) == 0 do return false
	for p := path; len(p) > 1; p = filepath.dir(p) {
		if p in fs_model.ignored do return true
	}
	return false
}

// ---- project file list (⌘P) ----

// The project's files, relative to root: git's view (tracked + untracked,
// not ignored) in a repository, else a walk that skips hidden folders.
// Cached until something under root changes.
fs_project_files :: proc(root: string) -> []string {
	if root == "" do return nil
	if fl, ok := &fs_model.files[root]; ok {
		if fl.stale do list_refresh(root, fl) // kept meanwhile
		return fl.list
	}
	window_watch_folder(root)
	fs_stats.list_runs_sync += 1
	list := project_list(root)
	fs_model.files[strings.clone(root)] = File_List{list = list, last = time.tick_now()}
	return list
}

// Refreshes a stale list on a worker (File_List_Done), at most once per
// FS_LIST_GAP; until then the old list stays.
@(private = "file")
list_refresh :: proc(root: string, fl: ^File_List) {
	if fl.loading || !fl.stale || time.tick_since(fl.last) < FS_LIST_GAP do return
	fl.loading, fl.stale, fl.last = true, false, time.tick_now()
	fs_stats.list_runs_async += 1
	job := new_clone(strings.clone(root, runtime.heap_allocator()), runtime.heap_allocator())
	thread.run_with_poly_data(job, proc(job: ^string) {
		list := project_list(job^)
		b := strings.builder_make(runtime.heap_allocator())
		for p in list {
			strings.write_string(&b, p)
			strings.write_byte(&b, 0)
			delete(p)
		}
		delete(list)
		inbox_submit(File_List_Done{root = job^, out = strings.to_string(b)}, {kind = .Internal})
		strings.builder_destroy(&b)
		delete(job^, runtime.heap_allocator())
		free(job, runtime.heap_allocator())
		free_all(context.temp_allocator)
	})
}

// A worker's refreshed file list arrived (main thread).
file_list_done :: proc(c: File_List_Done) {
	fl, ok := &fs_model.files[c.root]
	if !ok do return
	fl.loading = false
	for x in fl.list do delete(x)
	delete(fl.list)
	out := make([dynamic]string)
	for p in strings.split(c.out, "\x00", context.temp_allocator) do if p != "" do append(&out, strings.clone(p))
	fl.list = out[:]
	window_state_changed()
}

// The project's files, sorted (context allocator): git's view, else a walk.
@(private = "file")
project_list :: proc(root: string) -> []string {
	out := make([dynamic]string)
	if res, ok := git_run(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"); ok {
		for p in strings.split(res, "\x00", context.temp_allocator) {
			if p == "" || len(out) >= FILE_LIST_MAX do continue
			append(&out, strings.clone(p))
		}
	} else {
		walk(root, "", &out)
	}
	slice.sort(out[:])
	// a path listed twice (both cached and modified) appears once
	uniq := slice.unique(out[:])
	for x in out[len(uniq):] do delete(x)
	resize(&out, len(uniq))
	return out[:]
}

@(private = "file")
walk :: proc(root, rel: string, out: ^[dynamic]string) {
	dir, _ := filepath.join({root, rel}, context.temp_allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for fi in infos {
		if len(out) >= FILE_LIST_MAX do return
		if strings.has_prefix(fi.name, ".") || fi.name == "node_modules" do continue
		r := rel == "" ? fi.name : strings.concatenate({rel, "/", fi.name}, context.temp_allocator)
		if fi.type == .Directory do walk(root, r, out)
		else do append(out, strings.clone(r))
	}
}

// Something under path changed: drop what is cached for it. watcher_flags:
// the FSEvents flags of a watcher event (nil = one of our own file
// commands, which changed the folder's entries).
fs_model_changed :: proc(path: string, watcher_flags: Maybe(u32) = nil) {
	// git's object store and logs: not a change of status or of any file
	if strings.contains(path, "/.git/objects") || strings.contains(path, "/.git/logs") do return
	fs_model.gen += 1
	ours := watcher_flags == nil
	flags := watcher_flags.? or_else 0
	structural := ours || flags == 0 || flags & FSE_STRUCTURE != 0
	if structural do files_path_changed(path) // a content change leaves listings alone
	// an ignored path changes neither git status nor the file list
	if !ours && fs_path_ignored(path) do return
	wt_path_changed(path) // worktrees and branches (worktrees.odin)
	changes_path_changed(path) // the Changes tabs and the top bar's count (changes.odin)
	for &s in fs_model.status do if within(path, s.root) {
		s.ok = false
		s.gen += 1
	}
	// .git changes are status changes only; the file list follows the work tree
	if strings.contains(path, "/.git/") || strings.has_suffix(path, "/.git") do return
	if !structural do return
	for root, &fl in fs_model.files {
		if !within(path, root) do continue
		if !ours {
			fl.stale = true // refreshed on a worker, at most once a second
			break
		}
		// our own file command: the list is made again when next asked for
		if fl.loading { 	// its worker's result is dropped (file_list_done finds no entry)
			fl.stale = true
			break
		}
		for x in fl.list do delete(x)
		delete(fl.list)
		key := root
		delete_key(&fs_model.files, key)
		delete(key)
		break
	}
}

// ---- commands ----

fs_create_file :: proc(path: string, caller: Caller) -> (abs: string, err: string) {
	p, _, e := fs_check_write(path, caller)
	if e != "" do return "", e
	if os.exists(p) do return "", "already exists"
	if os.make_directory_all(filepath.dir(p)) != nil && path_kind(filepath.dir(p)) != .Dir do return "", "cannot create its folder"
	f, ferr := os.open(p, {.Write, .Create, .Excl}, os.Permissions_Default_File)
	if ferr != nil do return "", fmt.tprintf("cannot create: %v", ferr)
	os.close(f)
	fs_model_changed(p)
	return p, ""
}

fs_create_dir :: proc(path: string, caller: Caller) -> (abs: string, err: string) {
	p, _, e := fs_check_write(path, caller)
	if e != "" do return "", e
	if os.exists(p) do return "", "already exists"
	if derr := os.make_directory_all(p); derr != nil do return "", fmt.tprintf("cannot create: %v", derr)
	fs_model_changed(p)
	return p, ""
}

fs_rename :: proc(from, to: string, caller: Caller) -> (err: string) {
	a, ra, e1 := fs_check_write(from, caller)
	if e1 != "" do return e1
	b, rb, e2 := fs_check_write(to, caller)
	if e2 != "" do return e2
	_, _ = ra, rb
	if !os.exists(a) do return "no such file or folder"
	if os.exists(b) do return "the new name already exists"
	if os.make_directory_all(filepath.dir(b)) != nil && path_kind(filepath.dir(b)) != .Dir do return "cannot create the target folder"
	if rerr := os.rename(a, b); rerr != nil do return fmt.tprintf("cannot rename: %v", rerr)
	fs_model_changed(a)
	fs_model_changed(b)
	editors_renamed(a, b)
	files_renamed(a, b)
	return ""
}

// Moves to the Trash (the platform's; fails where there is none).
fs_delete :: proc(path: string, caller: Caller) -> (err: string) {
	p, _, e := fs_check_write(path, caller)
	if e != "" do return e
	if path_kind(p) == .Missing && !os.exists(p) do return "no such file or folder" // os.exists: a dangling link
	if !fs_trash_fn(p) do return "could not move it to the Trash"
	fs_model_changed(p)
	window_files_deleted(p) // open buffers of them say so
	return ""
}

fs_reveal_path :: proc(path: string, caller: Caller) -> string {
	p, _, e := fs_check(path, caller, allow_root = true)
	if e != "" && caller.kind == .UI && settings_revealable(fs_abs(path, caller)) do p, e = fs_abs(path, caller), "" // the Settings tab's rows
	if e != "" && caller.kind != .Panel && wt_known_checkout(fs_abs(path, caller)) do p, e = fs_real(fs_abs(path, caller)), "" // a worktree of a project
	if e != "" do return e
	if !os.exists(p) do return "no such file or folder"
	if autotest_active || platform.quit == nil || ODIN_TEST {
		// never opens Finder from tests: remembered instead
		delete(fs_model.revealed)
		fs_model.revealed = strings.clone(p)
		return ""
	}
	if platform.reveal != nil do platform.reveal(p)
	return ""
}

// list_dir's data: {"path", "entries": [{name, kind, git?, ignored?}]}.
fs_list_json :: proc(path: string, caller: Caller, with_ignored := false) -> (data: string, err: string) {
	p, _, e := fs_check(path, caller, allow_root = true)
	if e != "" do return "", e
	if path_kind(p) != .Dir do return "", "not a folder"
	entries, lerr, pending := fs_list_dir(p, with_ignored)
	if lerr != "" do return "", lerr
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"path":`)
	json_quote(&b, p)
	if pending do strings.write_string(&b, `,"git_pending":true`) // git status still running: ask again for the codes
	strings.write_string(&b, `,"entries":[`)
	for en, i in entries {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"name":`)
		json_quote(&b, en.name)
		strings.write_string(&b, `,"kind":`)
		json_quote(&b, FS_KIND_NAMES[en.kind])
		if en.git != "" {
			strings.write_string(&b, `,"git":`)
			json_quote(&b, en.git)
		}
		if en.ignored do strings.write_string(&b, `,"ignored":true`)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b), ""
}

// A folder's names and kinds, unsorted (temp allocator). Unlike
// os.read_all_directory, an entry that cannot be stat'ed does not fail the
// listing: one that vanished meanwhile is left out, any other keeps the kind
// readdir gives (a folder that is readable but not searchable lists its
// names). A symlink to a folder is a folder; a dangling one stays a symlink.
// err: opendir's (or a failed first readdir's) errno.
fs_read_names :: proc(dir: string) -> (entries: []Fs_Entry, err: posix.Errno) {
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil do return nil, posix.errno()
	defer posix.closedir(d)
	fd := posix.dirfd(d)
	out := make([dynamic]Fs_Entry, context.temp_allocator)
	for {
		posix.set_errno(nil)
		ent := posix.readdir(d)
		if ent == nil {
			if e := posix.errno(); e != nil && len(out) == 0 do return nil, e
			break
		}
		cname := cstring(raw_data(ent.d_name[:]))
		if cname == "." || cname == ".." do continue
		kind := Fs_Kind.File
		st: posix.stat_t
		if posix.fstatat(fd, cname, &st, {.SYMLINK_NOFOLLOW}) == .OK {
			switch {
			case posix.S_ISDIR(st.st_mode): kind = .Dir
			case posix.S_ISLNK(st.st_mode):
				kind = .Symlink
				if posix.fstatat(fd, cname, &st, {}) == .OK && posix.S_ISDIR(st.st_mode) do kind = .Dir
			}
		} else {
			if posix.errno() == .ENOENT do continue // gone since readdir
			#partial switch ent.d_type {
			case .DIR: kind = .Dir
			case .LNK: kind = .Symlink
			}
		}
		append(&out, Fs_Entry{name = strings.clone(string(cname), context.temp_allocator), kind = kind})
	}
	return out[:], nil
}

// What the Files tree says about a folder it cannot list, by errno. EPERM
// on a folder the user owns is macOS privacy (TCC: Desktop, Documents,
// Downloads, iCloud Drive, removable and network volumes): only System
// Settings changes that.
fs_list_error_text :: proc(e: posix.Errno) -> string {
	#partial switch e {
	case .EPERM:
		return "Can't open: macOS needs permission. Allow Deckhand in System Settings › Privacy & Security › Files and Folders (or Full Disk Access)"
	case .EACCES:
		return "Can't open: permission denied"
	case .ENOENT:
		return "Can't open: it is not there any more"
	}
	return fmt.tprintf("Can't open: %s", strings.to_lower(string(posix.strerror(e)), context.temp_allocator))
}

Disk_Stamp :: struct {
	size:  i64,
	mtime: i64, // ns
	inode: u64,
	dev:   u64,
	mode:  u32, // permission bits
}

Path_Kind :: enum {
	Missing,
	File, // regular
	Dir,
	Other, // FIFO, device, socket
}

// stat(2) (symlinks followed) without opening anything: core:os's stat
// opens the path, which blocks on a FIFO.
path_stat :: proc(path: string) -> (kind: Path_Kind, st: Disk_Stamp) {
	sb: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &sb) != .OK do return .Missing, {}
	switch {
	case posix.S_ISREG(sb.st_mode): kind = .File
	case posix.S_ISDIR(sb.st_mode): kind = .Dir
	case: kind = .Other
	}
	return kind, stamp_of_stat(&sb)
}

path_kind :: proc(path: string) -> Path_Kind {k, _ := path_stat(path); return k}

// A stat result as a Disk_Stamp (editor_file.odin too).
stamp_of_stat :: proc(sb: ^posix.stat_t) -> Disk_Stamp {
	return {size = i64(sb.st_size), mtime = i64(sb.st_mtim.tv_sec) * 1e9 + i64(sb.st_mtim.tv_nsec), inode = u64(sb.st_ino), dev = u64(sb.st_dev), mode = u32(transmute(posix._mode_t)sb.st_mode) & 0o7777}
}

// Binary: a NUL byte in the first 8 KB, or mostly bytes that are neither
// UTF-8 nor text controls.
looks_binary :: proc(data: []u8) -> bool {
	head := data[:min(len(data), 8192)]
	bad := 0
	i := 0
	for i < len(head) {
		c := head[i]
		if c == 0 do return true
		if c < 0x20 && c != '\n' && c != '\r' && c != '\t' && c != 0x1b && c != 0x0c && c != 0x08 do bad += 1
		if c < 0x80 {
			i += 1
			continue
		}
		r, n := utf8.decode_rune(head[i:])
		if r == utf8.RUNE_ERROR && n <= 1 {
			// a sequence cut by the 8 KB window is fine
			if len(head) - i < 4 && len(head) < len(data) do break
			bad += 1
			n = 1
		}
		i += n
	}
	return bad * 10 > len(head) // more than 10%
}

// One read for disk_read (tests swap in a failing one).
disk_read_chunk: proc(f: ^os.File, p: []u8) -> (int, os.Error) = proc(f: ^os.File, p: []u8) -> (int, os.Error) {return os.read(f, p)}

// Whether path is a regular file, or not there at all (restored tabs).
regular_or_missing :: proc(path: string) -> bool {
	k := path_kind(path)
	return k == .Missing || k == .File
}

// A path as the user reads it: ~ for the home folder.
fs_display :: proc(p: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(p, home) do return strings.concatenate({"~", p[len(home):]}, context.temp_allocator)
	return p
}

// The tab title for a file view.
title_for :: proc(path: string, view: Editor_View) -> string {
	base := filepath.base(path)
	switch view {
	case .File:      return strings.clone(base)
	case .Diff_Head: return fmt.aprintf("%s ↔ HEAD", base)
	case .Diff_Disk: return fmt.aprintf("%s ↔ disk", base)
	case .Changes:   return strings.clone("Changes")
	}
	return strings.clone(base)
}

// A file or folder moved: open tabs follow it (path and title).
editors_renamed :: proc(from, to: string) {
	for &s in state.open_sessions do for &tab in s.tabs {
		path: ^string
		view := Editor_View.File
		#partial switch &k in tab.kind {
		case Editor_Tab:
			path, view = &k.path, k.view
		case Markdown_Tab:
			path = &k.path
		case:
			continue
		}
		rp := fs_real(path^)
		if rp != from && !strings.has_prefix(rp, strings.concatenate({from, "/"}, context.temp_allocator)) do continue
		np := strings.concatenate({to, rp[len(from):]})
		delete(path^)
		path^ = np
		delete(tab.title)
		tab.title = title_for(np, view)
		window_view_moved(tab.id, np) // its buffer follows (tab_views.odin)
	}
	window_watch_sync()
}
