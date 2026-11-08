package main

// The Changes tab (ROADMAP phase 2): what a session changed in its checkout.
// One tab kind (Changes_Tab, drawn by ui_changes.odin) per session and
// checkout: the uncommitted files (staged, unstaged, untracked) and the
// files changed by commits on the branch that are not on the default branch
// (found as worktrees.odin finds it; `git diff <merge-base> HEAD`), grouped
// by status with +/- counts; the selected file's unified diff in a
// read-only editor view (editor_view.odin draws it, .Changes); actions:
// open the file at the hunk, stage, unstage, discard (confirmed, class
// delete; a file git does not have needs a second confirmation and goes to
// the Trash), commit, "Ask pi to review". Merge waits on the user's rules.
//
// The model is per checkout (Changes_Repo, keyed by its top folder) and
// shared by the tab and the top bar's "±" button (its count). It is read on
// a worker (changes_scan: a few bounded git calls, Changes_Scan_Done) only
// while something looks at it (the button or the tab was laid out in the
// last CHANGES_ASK_TTL), the first time at once, then after a change in the
// checkout or its git files (fs_model_changed -> changes_path_changed),
// CHANGES_DEBOUNCE after the last one and never within CHANGES_GAP of the
// previous scan; our own git commands and focusing the tab read it at once.
// Nothing runs per frame but a cheap check of the flags (changes_tick).
//
// Git safety: reads and stage/unstage/discard run through git_run
// (editor_git.odin: no hooks, no fsmonitor, no optional locks, bounded),
// diffs without external diff or textconv programs, paths as literal
// pathspecs. Commit is the exception, on purpose: it is the user's own
// commit, so it runs as their terminal would, through their login shell,
// with their hooks (pre-commit, commit-msg) and signing; bounded by
// changes_commit_timeout, the message on stdin. Every git call runs in its
// own process group (changes_run.odin): a timeout stops it and whatever it
// started, and output is read only up to a cap.
//
// Credential files (settings_credential, as the editor refuses them, and
// key or .env-like names: wt_secret_name) are listed but their diff is never
// read; binary files are listed without contents. changes_list (agents)
// carries paths and counts only, never diff text.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"

Changes_Tab :: struct {
	root: string, // the checkout's top folder (real path, owned)
}

// Opens (or focuses) the Changes tab of a checkout in an open session:
// path's checkout (default: the session's folder's).
Changes_Open :: struct {
	session: u64, // 0 = the current one
	path:    string, // a folder in the checkout ("" = the session's folder)
}
// The changed files of a checkout: paths and counts, no diff text.
Changes_List :: struct {
	tab_id: u64, // a Changes tab (its checkout)
	path:   string, // or a folder in a checkout ("" and no tab = the current session's)
}
// The user's actions on one listed file of a Changes tab (path relative to
// its checkout, as listed).
Changes_Stage :: struct {
	tab_id: u64,
	path:   string,
	status: string, // "M" "A" "D" "R" "U" "untracked": which entry when a path has two ("" = its only one)
}
Changes_Unstage :: struct {
	tab_id: u64,
	path:   string,
	status: string, // "M" "A" "D" "R" "U" "untracked": which entry when a path has two ("" = its only one)
}
// Discards a file's uncommitted changes (back to HEAD). Confirms (class
// delete); a file git does not have (untracked, newly added, a rename's new
// name) is moved to the Trash and confirms a second time (second).
Changes_Discard :: struct {
	tab_id:  u64,
	path:    string,
	status:  string, // as for Changes_Stage
	confirm: string,
	second:  bool,
}
// Commits what is staged with the user's hooks (see the top).
Changes_Commit :: struct {
	tab_id:  u64,
	message: string,
}
// Internal: a worker read a checkout's changes.
Changes_Scan_Done :: struct {
	root: string,
	gen:  u64,
	out:  string,
}
// Internal: a worker read one file's diff for a tab.
Changes_Diff_Done :: struct {
	tab_id: u64,
	gen:    u64,
	text:   string,
	err:    string,
}
// Internal: a worker ran a stage, unstage, discard or commit.
Changes_Op_Done :: struct {
	tab_id:     u64,
	root:       string,
	request_id: u64,
	what:       string, // "stage", "unstage", "discard", "commit"
	trash:      string, // discard: then this file goes to the Trash (main thread)
	err:        string, // "" = ok; shown in the tab (commit: git's own words)
}

CHANGES_DEBOUNCE :: 400 * time.Millisecond // after the last change before reading again
CHANGES_GAP :: 1500 * time.Millisecond // between two scans of one checkout
CHANGES_ASK_TTL :: 3 * time.Second // nobody laid it out for this long: not read
CHANGES_SLOW :: 300 * time.Millisecond // "Refreshing…" shows only past this
CHANGES_FILES_MAX :: 2000 // files listed per scope
CHANGES_UNTRACKED_COUNT_MAX :: 4 << 20 // untracked files up to this size get line counts
CHANGES_DIFF_BYTES_MAX :: 16 << 20 // a bigger diff is not shown
CHANGES_LINES_STEP :: 5000 // lines of one diff shown at first, and per "Show more"
CHANGES_OP_TIMEOUT :: 30 * time.Second // stage, unstage, discard
CHANGES_STATUS_MAX :: 32 << 20 // git status and numstat output read at most
changes_commit_timeout := 120 * time.Second // hooks may lint or test (tests shorten it)
CHANGES_WHERE_MAX :: 64 // checkouts kept
EMPTY_TREE :: "4b825dc642cb6eb9a060e54bf8d69288fbee4904" // git's empty tree (no HEAD yet)

Change_Scope :: enum u8 {
	Uncommitted,
	Committed, // on the branch, not on the default branch
}
Change_Staged :: enum u8 {
	None,
	Partly,
	All,
}

Change_File :: struct {
	path:       string, // relative to the checkout
	old_path:   string, // a rename's old name
	status:     u8, // 'M' 'A' 'D' 'R' '?' (untracked) 'U' (conflict)
	scope:      Change_Scope,
	staged:     Change_Staged,
	unstaged:   bool, // work-tree changes not staged (untracked counts)
	in_head:    bool, // HEAD has path (discard restores it; else it goes to the Trash)
	added:      int, // lines; -1 = unknown
	removed:    int,
	binary:     bool,
	credential: bool,
}

Changes_Repo :: struct {
	root:           string, // owned key: the checkout's top folder
	common:         string, // its repository's common git dir (owned)
	arena:          virtual.Arena, // files and strings below
	files:          [dynamic]Change_File,
	branch:         string, // "" = detached
	default_branch: string,
	merge_base:     string, // the default branch's merge base with HEAD ("" = none)
	ahead:          int, // commits on the branch not on the default branch
	has_head:       bool,
	truncated:      bool,
	err:            string,
	loaded:         bool,
	loading:        bool,
	slow:           bool, // the scan has run past CHANGES_SLOW (redrawn once for "Refreshing…")
	stale:          bool, // changed since the last scan started
	now:            bool, // read at once (our own command, the tab focused)
	gen:            u64, // bumped by every change
	changed_at:     time.Tick,
	started:        time.Tick,
	asked:          time.Tick,
	runs:           int, // scans started (tests)
}

changes_repos: [dynamic]^Changes_Repo

// One Changes tab's runtime side (its diff text is in editors[tab_id]).
Changes_View :: struct {
	tab_id:       u64,
	root:         string, // owned
	sel_path:     string, // owned; "" = none
	sel_scope:    Change_Scope,
	sel_status:   u8, // a path may have two entries (D and ??): the row is path, scope and status
	list_top:     int, // the list's first shown row
	diff:         string, // the selected file's whole diff (owned)
	diff_lines:   int,
	shown:        int, // lines shown (CHANGES_LINES_STEP, more per "Show more")
	diff_gen:     u64,
	diff_loading: bool,
	busy:         string, // an action running ("Staging…"); "" = none
	notice:       string, // the last action's outcome (owned)
	notice_err:   bool,
	// its list at its last layout (ui_changes.odin): drawn slot -> row index, rows that fit
	drawn:        [CHANGES_ROWS_DRAWN_MAX]int,
	drawn_n:      int,
	rows_fit:     int,
	laid_pass:    u64, // the layout pass that last laid it out (ui_layout_pass): 0 = never
}

changes_views: map[u64]^Changes_View

changes_view :: proc(tab_id: u64) -> ^Changes_View {return changes_views[tab_id] or_else nil}

// The checkout's model (made on first use; nil = not a git checkout).
changes_repo :: proc(root: string) -> ^Changes_Repo {
	if root == "" do return nil
	for r in changes_repos do if r.root == root do return r
	w := wt_where(root)
	if w.common == "" || w.top != root do return nil
	if len(changes_repos) >= CHANGES_WHERE_MAX {
		// the least recently asked for, unless it is loading
		old := -1
		for r, i in changes_repos do if !r.loading && (old < 0 || r.asked._nsec < changes_repos[old].asked._nsec) do old = i
		if old >= 0 {
			changes_repo_free(changes_repos[old])
			ordered_remove(&changes_repos, old)
		}
	}
	r := new(Changes_Repo)
	r.root = strings.clone(root)
	r.common = strings.clone(w.common)
	append(&changes_repos, r)
	watch_folder(root) // its files' changes come through fs_model_changed
	return r
}

@(private = "file")
changes_repo_free :: proc(r: ^Changes_Repo) {
	virtual.arena_destroy(&r.arena)
	delete(r.root)
	delete(r.common)
	free(r)
}

// The top folder of the checkout holding dir ("" = none).
changes_root_of :: proc(dir: string) -> string {
	if dir == "" do return ""
	return wt_where(fs_real(dir)).top
}

// Something lays out this checkout's changes (the tab, the button): keep
// it current. Main thread.
changes_ask :: proc(r: ^Changes_Repo) {
	if r != nil do r.asked = time.tick_now()
}

// Main thread, every frame callback (fs_model_tick): starts the scans that
// are due. Cheap when nothing is.
changes_tick :: proc() {
	for r in changes_repos {
		if r.loading {
			if !r.slow && time.tick_since(r.started) >= CHANGES_SLOW {
				r.slow = true
				window_state_changed()
			}
			continue
		}
		if r.loaded && !r.stale do continue
		if time.tick_since(r.asked) > CHANGES_ASK_TTL do continue // nobody looks: read when asked again
		if r.loaded && !r.now {
			if time.tick_since(r.changed_at) < CHANGES_DEBOUNCE do continue
			if time.tick_since(r.started) < CHANGES_GAP do continue
		}
		changes_scan_start(r)
	}
}

// A path changed (fs_model_changed: the watcher or our own file commands):
// a file in a checkout, or its index, HEAD or refs.
changes_path_changed :: proc(path: string) {
	for r in changes_repos {
		hit := false
		if within_dir(path, r.root) {
			rel := path[len(r.root):]
			hit = !strings.has_prefix(rel, "/.git/") || changes_git_file(rel)
		} else if within_dir(path, r.common) {
			hit = changes_git_file(path[len(r.common):])
		}
		if !hit do continue
		r.stale = true
		r.gen += 1
		r.changed_at = time.tick_now()
	}
}

// A git file whose change can change the status: the index, HEAD, refs.
@(private = "file")
changes_git_file :: proc(rel: string) -> bool {
	base := filepath.base(rel)
	return strings.has_prefix(base, "index") || strings.has_suffix(base, "HEAD") || strings.contains(rel, "/refs/") || strings.has_prefix(base, "packed-refs") || strings.has_suffix(rel, "/.git")
}

within_dir :: proc(path, root: string) -> bool {
	return root != "" && (path == root || (strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/'))
}

// Read at once (our own git command, the tab focused).
changes_refresh :: proc(r: ^Changes_Repo) {
	if r == nil do return
	r.stale, r.now = true, true
	r.gen += 1
	r.asked = time.tick_now()
	window_state_changed()
}

@(private = "file")
changes_scan_start :: proc(r: ^Changes_Repo) {
	r.loading, r.stale, r.now, r.slow = true, false, false, false
	r.started = time.tick_now()
	r.runs += 1
	main := filepath.base(r.common) == ".git" ? filepath.dir(r.common) : r.root
	if !os.is_dir(main) do main = r.root
	Job :: struct {
		root, main: string,
		gen:        u64,
	}
	h := runtime.heap_allocator()
	job := new_clone(Job{strings.clone(r.root, h), strings.clone(main, h), r.gen}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		out := changes_scan(job.root, job.main)
		inbox_submit(Changes_Scan_Done{root = job.root, gen = job.gen, out = out}, {kind = .Internal}) // copied
		delete(out, h)
		delete(job.root, h)
		delete(job.main, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// ---- the scan (any thread) ----

// A checkout's changes as NUL-separated fields (heap): records "B" branch
// default merge_base ahead has_head, "F" scope status x y added removed
// path old_path, "T" (truncated), "E" message.
changes_scan :: proc(root, main: string) -> string {
	b := strings.builder_make(runtime.heap_allocator())
	put :: proc(b: ^strings.Builder, fields: ..string) {
		for f in fields {
			strings.write_string(b, f)
			strings.write_byte(b, 0)
		}
	}
	st, sst := git_group(root, GIT_TIMEOUT, CHANGES_STATUS_MAX, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if sst != .Ok {
		put(&b, "E", sst == .Too_Big ? "too many changes to list" : "git status failed")
		return strings.to_string(b)
	}
	_, has_head := git_run(root, "rev-parse", "--verify", "-q", "HEAD")
	base := has_head ? "HEAD" : EMPTY_TREE
	branch := ""
	if o, bok := git_run(root, "symbolic-ref", "-q", "--short", "HEAD"); bok do branch = strings.trim_space(o)
	Count :: struct {
		added, removed: int,
		binary:         bool,
	}
	numstat :: proc(out: string, counts: ^map[string]Count) {
		// "A\tD\tpath\0" or, for a rename, "A\tD\t\0old\0new\0"
		toks := strings.split(out, "\x00", context.temp_allocator)
		for i := 0; i < len(toks); i += 1 {
			t := toks[i]
			f := strings.split_n(t, "\t", 3, context.temp_allocator)
			if len(f) < 3 do continue
			path := f[2]
			if path == "" {
				if i + 2 >= len(toks) do break
				path = toks[i + 2]
				i += 2
			}
			c := Count{binary = f[0] == "-"}
			c.added, _ = strconv.parse_int(f[0])
			c.removed, _ = strconv.parse_int(f[1])
			counts[path] = c
		}
	}
	counts := make(map[string]Count, 64, context.temp_allocator)
	if out, nst := git_group(root, GIT_TIMEOUT, CHANGES_STATUS_MAX, "--literal-pathspecs", "diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-textconv", base); nst == .Ok do numstat(out, &counts)
	// uncommitted: git status's records ("XY path", then the old name of a rename)
	toks := strings.split(st, "\x00", context.temp_allocator)
	n := 0
	for i := 0; i < len(toks); i += 1 {
		rec := toks[i]
		if len(rec) < 4 do continue
		x, y := rec[0], rec[1]
		path := rec[3:]
		old := ""
		if x == 'R' || x == 'C' || y == 'R' || y == 'C' {
			if i + 1 < len(toks) do old = toks[i + 1]
			i += 1
		}
		if n >= CHANGES_FILES_MAX {
			put(&b, "T")
			break
		}
		n += 1
		status: u8
		switch {
		case x == '?':                                          status = '?'
		case x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D'): status = 'U'
		case x == 'R' || y == 'R':                              status = 'R'
		case x == 'C' || y == 'C' || x == 'A':                  status = 'A'
		case x == 'D' || y == 'D':                              status = 'D'
		case:                                                   status = 'M'
		}
		added, removed := "-1", "-1"
		if status == '?' {
			a, bin := changes_count_file(strings.concatenate({root, "/", path}, context.temp_allocator))
			added, removed = fmt.tprint(a), "0"
			if bin do added, removed = "b", "b"
		} else if c, has := counts[path]; has {
			added, removed = fmt.tprint(c.added), fmt.tprint(c.removed)
			if c.binary do added, removed = "b", "b"
		}
		if status == 'R' && x == 'C' do status = 'A' // a copy: a new file
		put(&b, "F", "u", string([]u8{status}), string([]u8{x}), string([]u8{y}), added, removed, path, x == 'C' ? "" : old)
	}
	// the branch's own commits: against the default branch's merge base
	def := wt_default_branch(main)
	mb := ""
	ahead := 0
	if has_head && def != "" && branch != def {
		def_ref := strings.concatenate({"refs/heads/", def}, context.temp_allocator)
		if o, mok := git_run(root, "merge-base", def_ref, "HEAD"); mok do mb = strings.trim_space(o)
		if mb != "" {
			if o, cok := git_run(root, "rev-list", "--count", strings.concatenate({mb, "..HEAD"}, context.temp_allocator)); cok do ahead, _ = strconv.parse_int(strings.trim_space(o))
		}
		if ahead > 0 {
			ccounts := make(map[string]Count, 64, context.temp_allocator)
			if out, nst := git_group(root, GIT_TIMEOUT, CHANGES_STATUS_MAX, "diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-textconv", mb, "HEAD"); nst == .Ok do numstat(out, &ccounts)
			if ns, sst2 := git_group(root, GIT_TIMEOUT, CHANGES_STATUS_MAX, "diff", "--name-status", "-z", "-M", "--no-ext-diff", mb, "HEAD"); sst2 == .Ok {
				ct := strings.split(ns, "\x00", context.temp_allocator)
				m := 0
				for i := 0; i + 1 < len(ct); i += 1 {
					code := ct[i]
					if code == "" do continue
					path, old := ct[i + 1], ""
					i += 1
					if code[0] == 'R' || code[0] == 'C' {
						if i + 1 >= len(ct) do break
						old, path = path, ct[i + 1]
						i += 1
					}
					if m >= CHANGES_FILES_MAX {
						put(&b, "T")
						break
					}
					m += 1
					status := code[0]
					switch status {
					case 'C':           status, old = 'A', ""
					case 'M', 'A', 'D', 'R':
					case:               status = 'M' // T (type), U, X
					}
					added, removed := "-1", "-1"
					if c, has := ccounts[path]; has {
						added, removed = fmt.tprint(c.added), fmt.tprint(c.removed)
						if c.binary do added, removed = "b", "b"
					}
					put(&b, "F", "c", string([]u8{status}), " ", " ", added, removed, path, old)
				}
			}
		}
	}
	put(&b, "B", branch, def, mb, fmt.tprint(ahead), has_head ? "1" : "0")
	return strings.to_string(b)
}

// Lines of an untracked file (and whether it looks binary: a NUL in its
// first 8000 bytes, as git decides). -1 = too big to count.
changes_count_file :: proc(path: string) -> (lines: int, binary: bool) {
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil || fi.type != .Regular do return 0, false
	if fi.size > CHANGES_UNTRACKED_COUNT_MAX do return -1, false
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return -1, false
	if strings.index_byte(string(data[:min(len(data), 8000)]), 0) >= 0 do return 0, true
	n := strings.count(string(data), "\n")
	if len(data) > 0 && data[len(data) - 1] != '\n' do n += 1
	return n, false
}

// A worker's scan arrived (main thread). The tabs on this checkout follow.
changes_scan_done :: proc(c: Changes_Scan_Done) {
	r: ^Changes_Repo
	for x in changes_repos do if x.root == c.root do r = x
	if r == nil do return
	window_state_changed()
	r.loading, r.slow = false, false
	r.loaded = true
	if c.gen != r.gen do r.stale = true // a change since it started: read again after the debounce
	virtual.arena_destroy(&r.arena)
	_ = virtual.arena_init_growing(&r.arena)
	a := virtual.arena_allocator(&r.arena)
	r.files = make([dynamic]Change_File, a)
	r.branch, r.default_branch, r.merge_base, r.err = "", "", "", ""
	r.ahead, r.has_head, r.truncated = 0, false, false
	toks := strings.split(c.out, "\x00", context.temp_allocator)
	num :: proc(s: string) -> (int, bool) {
		if s == "b" do return -1, true
		n, ok := strconv.parse_int(s)
		return ok ? n : -1, false
	}
	for i := 0; i < len(toks); {
		switch toks[i] {
		case "E":
			if i + 1 < len(toks) do r.err = strings.clone(toks[i + 1], a)
			i += 2
		case "T":
			r.truncated = true
			i += 1
		case "B":
			if i + 5 >= len(toks) {
				i = len(toks)
				break
			}
			r.branch = strings.clone(toks[i + 1], a)
			r.default_branch = strings.clone(toks[i + 2], a)
			r.merge_base = strings.clone(toks[i + 3], a)
			r.ahead, _ = strconv.parse_int(toks[i + 4])
			r.has_head = toks[i + 5] == "1"
			i += 6
		case "F":
			if i + 8 >= len(toks) {
				i = len(toks)
				break
			}
			f := toks[i + 1:i + 9]
			i += 9
			added, bin := num(f[4])
			removed, _ := num(f[5])
			x, y := f[2][0], f[3][0]
			cf := Change_File {
				path     = strings.clone(f[6], a),
				old_path = strings.clone(f[7], a),
				status   = f[1][0],
				scope    = f[0] == "c" ? .Committed : .Uncommitted,
				added    = added,
				removed  = removed,
				binary   = bin,
			}
			if cf.scope == .Uncommitted {
				staged_x := x != ' ' && x != '?'
				cf.unstaged = y != ' ' || x == '?'
				cf.staged = !staged_x ? .None : (cf.unstaged ? .Partly : .All)
				cf.in_head = x != '?' && x != 'A' && x != 'C' && y != 'A' // and HEAD exists (after the loop); a rename: its old name is in HEAD
			}
			abs := strings.concatenate({r.root, "/", cf.path}, context.temp_allocator)
			cf.credential = changes_credential(abs)
			if cf.old_path != "" do cf.credential ||= changes_credential(strings.concatenate({r.root, "/", cf.old_path}, context.temp_allocator)) // a renamed credentials file is one still
			append(&r.files, cf)
		case:
			i += 1
		}
	}
	if !r.has_head do for &f in r.files do f.in_head = false // ("B" comes last)
	// grouped: scope, then status (M A D R U ?), then path
	slice.sort_by(r.files[:], proc(x, y: Change_File) -> bool {
		if x.scope != y.scope do return x.scope < y.scope
		if a, b := change_status_rank(x.status), change_status_rank(y.status); a != b do return a < b
		return x.path < y.path
	})
	for _, v in changes_views do if v.root == r.root do changes_view_follow(v, r)
}

// Never shown: what the editor refuses (sign-ins, .env files) and names
// that look like keys or secrets.
changes_credential :: proc(abs: string) -> bool {
	return settings_credential(abs) || wt_secret_name(filepath.base(abs))
}

CHANGE_STATUS_ORDER :: "MADRU?"

change_status_rank :: proc(s: u8) -> int {
	i := strings.index_byte(CHANGE_STATUS_ORDER, s)
	return i < 0 ? len(CHANGE_STATUS_ORDER) : i
}

change_status_name :: proc(s: u8) -> string {
	switch s {
	case 'M': return "Modified"
	case 'A': return "Added"
	case 'D': return "Deleted"
	case 'R': return "Renamed"
	case 'U': return "Conflicted"
	case '?': return "Untracked"
	}
	return "Changed"
}

// The listed file of a checkout: path, scope and status (0 = the first of
// that path and scope; nil = not listed).
changes_find :: proc(r: ^Changes_Repo, path: string, scope: Change_Scope, status: u8 = 0) -> ^Change_File {
	if r == nil do return nil
	for &f in r.files do if f.path == path && f.scope == scope && (status == 0 || f.status == status) do return &f
	return nil
}

// A status on the wire: "untracked" or its letter.
change_status_wire :: proc(s: u8) -> string {
	switch s {
	case 'M': return "M"
	case 'A': return "A"
	case 'D': return "D"
	case 'R': return "R"
	case 'U': return "U"
	case '?': return "untracked"
	}
	return ""
}

change_status_of_wire :: proc(s: string) -> u8 {
	if s == "untracked" || s == "?" do return '?'
	if len(s) == 1 && strings.index_byte(CHANGE_STATUS_ORDER, s[0]) >= 0 do return s[0]
	return 0
}

// Distinct changed paths (the button's count).
changes_count :: proc(r: ^Changes_Repo) -> int {
	if r == nil do return 0
	n := 0
	for f, i in r.files {
		if f.scope == .Committed {
			dup := false
			for g in r.files[:i] do if g.scope == .Uncommitted && g.path == f.path do dup = true
			if dup do continue
		}
		n += 1
	}
	return n
}

// ---- the tab's view ----

// The tab's view and its read-only diff editor (editors[tab_id]).
changes_view_new :: proc(tab_id: u64, root: string) -> ^Changes_View {
	v := new(Changes_View)
	v.tab_id = tab_id
	v.root = strings.clone(root)
	v.shown = CHANGES_LINES_STEP
	changes_views[tab_id] = v
	e := new(Editor)
	e.tab_id, e.view, e.readonly, e.goal_col = tab_id, .Changes, true, -1
	e.path = strings.clone(root)
	e.eol, e.indent_w = "\n", 4
	tb_init(&e.buf, nil)
	editors[tab_id] = e
	changes_message(v, "Reading the changes…")
	if r := changes_repo(root); r != nil {
		changes_ask(r)
		if r.loaded do changes_view_follow(v, r)
	}
	return v
}

// The tab closed (drop_term): its view goes (its editor goes with editor_drop).
changes_drop :: proc(tab_id: u64) {
	v := changes_view(tab_id)
	if v == nil do return
	delete(v.root)
	delete(v.sel_path)
	delete(v.diff)
	delete(v.notice)
	free(v)
	delete_key(&changes_views, tab_id)
}

// The diff area says why there is nothing to show (editor_draw draws a
// refused editor as a message with the path under it).
@(private = "file")
changes_message :: proc(v: ^Changes_View, msg: string, path := "") {
	e := editor_of(v.tab_id)
	if e == nil do return
	delete(e.refused)
	e.refused = strings.clone(msg)
	delete(e.path)
	e.path = strings.clone(path != "" ? path : v.root)
	window_state_changed()
}

// The rows of the list, in order (temp allocator): scope and status
// headers, then files. The layout, j/k and next/previous walk the same list.
Changes_Row :: struct {
	head:  string, // a header ("" = a file)
	file:  int, // index into the repo's files
	scope: bool, // a scope header (else a status header)
}

changes_rows :: proc(r: ^Changes_Repo) -> []Changes_Row {
	out := make([dynamic]Changes_Row, context.temp_allocator)
	if r == nil do return out[:]
	last_scope := -1
	last_status: u8 = 0
	for f, i in r.files {
		if int(f.scope) != last_scope {
			last_scope = int(f.scope)
			last_status = 0
			n := 0
			for g in r.files do if g.scope == f.scope do n += 1
			head := fmt.tprintf("Uncommitted · %d", n)
			if f.scope == .Committed {
				on := r.branch != "" ? r.branch : "this commit"
				head = fmt.tprintf("On %s, not on %s · %d %s", on, r.default_branch, r.ahead, r.ahead == 1 ? "commit" : "commits")
			}
			append(&out, Changes_Row{head = head, scope = true})
		}
		if f.status != last_status {
			last_status = f.status
			n := 0
			for g in r.files do if g.scope == f.scope && g.status == f.status do n += 1
			append(&out, Changes_Row{head = fmt.tprintf("%s · %d", change_status_name(f.status), n)})
		}
		append(&out, Changes_Row{file = i})
	}
	return out[:]
}

// The selected file (nil = none, or no longer listed).
changes_selected :: proc(v: ^Changes_View) -> (^Changes_Repo, ^Change_File) {
	r := changes_repo(v.root)
	if r == nil || v.sel_path == "" do return r, nil
	return r, changes_find(r, v.sel_path, v.sel_scope, v.sel_status)
}

// Selects an entry of the list (path, scope and status; status 0 = the
// first of that path and scope) and reads its diff.
changes_select :: proc(v: ^Changes_View, path: string, scope: Change_Scope, status: u8 = 0) {
	status := status
	if status == 0 {
		if f := changes_find(changes_repo(v.root), path, scope); f != nil do status = f.status
	}
	same := v.sel_path == path && v.sel_scope == scope && v.sel_status == status
	if !same {
		delete(v.sel_path)
		v.sel_path = strings.clone(path)
		v.sel_scope = scope
		v.sel_status = status
		v.shown = CHANGES_LINES_STEP
		if e := editor_of(v.tab_id); e != nil {
			e.top, e.top_sub, e.frac, e.scroll_x = 0, 0, 0, 0
			e.cursor, e.anchor = 0, 0
		}
	}
	changes_diff_start(v)
	window_state_changed()
}

// Next or previous file in the list (j/k, arrows, the ◀ ▶ buttons).
changes_step :: proc(v: ^Changes_View, dir: int) {
	r := changes_repo(v.root)
	if r == nil || len(r.files) == 0 do return
	at := -1
	for f, i in r.files do if changes_is_selected(v, f) do at = i
	next := at < 0 ? 0 : clamp(at + dir, 0, len(r.files) - 1)
	if next == at do return
	f := r.files[next]
	changes_select(v, f.path, f.scope, f.status)
	changes_keep_visible(v)
}

// The list scrolls so the selected row shows (rows that fit: the last layout's).
changes_keep_visible :: proc(v: ^Changes_View) {
	r := changes_repo(v.root)
	rows := changes_rows(r)
	at := -1
	for row, i in rows do if row.head == "" && changes_is_selected(v, r.files[row.file]) do at = i
	if at < 0 do return
	fit := max(v.rows_fit > 0 ? v.rows_fit : 20, 1) // rows that fit at its last layout
	if at - 1 < v.list_top do v.list_top = max(at - 1, 0) // its header too, if it is right above
	if at >= v.list_top + fit do v.list_top = at - fit + 1
}

// Whether f is the selected entry (path, scope and status).
changes_is_selected :: proc(v: ^Changes_View, f: Change_File) -> bool {
	return f.path == v.sel_path && f.scope == v.sel_scope && f.status == v.sel_status
}

// A scan arrived: the selection stays on its file if it is still listed,
// else the nearest one; its diff is read again.
@(private = "file")
changes_view_follow :: proc(v: ^Changes_View, r: ^Changes_Repo) {
	if r.err != "" {
		changes_message(v, r.err)
		return
	}
	if len(r.files) == 0 {
		delete(v.sel_path)
		v.sel_path = ""
		changes_message(v, r.has_head || r.loaded ? "No changes" : "Nothing yet", v.root)
		return
	}
	if v.sel_path != "" && changes_find(r, v.sel_path, v.sel_scope, v.sel_status) != nil {
		changes_diff_start(v)
		return
	}
	// the same path, now another status (staged ?? -> A, D and ?? -> M)
	if f := changes_find(r, v.sel_path, v.sel_scope); v.sel_path != "" && f != nil {
		changes_select(v, f.path, f.scope, f.status)
		return
	}
	// the first file of the same scope, else the first
	pick := 0
	for f, i in r.files do if f.scope == v.sel_scope {
		pick = i
		break
	}
	changes_select(v, r.files[pick].path, r.files[pick].scope, r.files[pick].status)
}

// Reads the selected file's diff on a worker (Changes_Diff_Done); binary
// and credential files are never read.
changes_diff_start :: proc(v: ^Changes_View) {
	r, f := changes_selected(v)
	if f == nil {
		changes_message(v, "Pick a file on the left")
		return
	}
	abs := strings.concatenate({v.root, "/", f.path}, context.temp_allocator)
	v.diff_gen += 1
	if f.credential || f.binary {
		delete(v.diff)
		v.diff, v.diff_lines = "", 0
	}
	if f.credential {
		v.diff_loading = false
		changes_message(v, "Credentials file: listed, never shown", abs)
		return
	}
	if f.binary {
		v.diff_loading = false
		changes_message(v, "Binary file: contents not shown", abs)
		return
	}
	v.diff_loading = true
	Job :: struct {
		tab_id, gen:           u64,
		root, path, old, base: string,
		scope:                 Change_Scope,
		status:                u8,
	}
	h := runtime.heap_allocator()
	base := r.has_head ? "HEAD" : EMPTY_TREE
	if f.scope == .Committed do base = r.merge_base
	job := new_clone(Job{v.tab_id, v.diff_gen, strings.clone(v.root, h), strings.clone(f.path, h), strings.clone(f.old_path, h), strings.clone(base, h), f.scope, f.status}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		text, err := changes_diff_read(job.root, job.path, job.old, job.base, job.scope, job.status)
		inbox_submit(Changes_Diff_Done{tab_id = job.tab_id, gen = job.gen, text = text, err = err}, {kind = .Internal}) // copied
		delete(job.root, h)
		delete(job.path, h)
		delete(job.old, h)
		delete(job.base, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// One file's unified diff without git's file headers: its hunks (temp
// allocator; any thread). An untracked file is read and shown as added.
changes_diff_read :: proc(root, path, old, base: string, scope: Change_Scope, status: u8) -> (text, err: string) {
	if status == '?' {
		full := strings.concatenate({root, "/", path}, context.temp_allocator)
		fi, ferr := os.lstat(full, context.temp_allocator)
		if ferr != nil do return "", "the file is gone"
		if fi.type != .Regular do return "", "not a regular file"
		if fi.size > CHANGES_DIFF_BYTES_MAX do return "", "too large to show"
		data, rerr := os.read_entire_file(full, context.temp_allocator)
		if rerr != nil do return "", "cannot read it"
		if len(data) == 0 do return "", "Empty new file"
		lines := strings.split_lines(strings.trim_suffix(string(data), "\n"), context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "@@ -0,0 +1,%d @@ new file\n", len(lines))
		for l in lines {
			strings.write_byte(&b, '+')
			strings.write_string(&b, strings.trim_suffix(l, "\r"))
			strings.write_byte(&b, '\n')
		}
		return strings.to_string(b), ""
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "-M", base)
	if scope == .Committed do append(&args, "HEAD")
	append(&args, "--", path)
	if old != "" do append(&args, old)
	out, dst := git_group(root, GIT_TIMEOUT, CHANGES_DIFF_BYTES_MAX, ..args[:])
	if dst == .Too_Big do return "", "too large to show" // read up to the cap, then git is stopped
	if dst != .Ok do return "", dst == .Timed_Out ? "git diff took too long" : "git diff failed"
	at := strings.index(out, "\n@@ ")
	if strings.has_prefix(out, "@@ ") do at = -1
	if at < 0 && !strings.has_prefix(out, "@@ ") {
		if old != "" do return "", fmt.tprintf("Renamed from %s, no content changes", old)
		return "", "No content changes (mode or type only)"
	}
	return at < 0 ? out : out[at + 1:], ""
}

// A diff arrived for a tab (main thread): shown up to v.shown lines.
changes_diff_done :: proc(c: Changes_Diff_Done) {
	v := changes_view(c.tab_id)
	if v == nil || c.gen != v.diff_gen do return
	v.diff_loading = false
	delete(v.diff)
	v.diff = ""
	v.diff_lines = 0
	_, f := changes_selected(v)
	abs := f != nil ? strings.concatenate({v.root, "/", f.path}, context.temp_allocator) : v.root
	if c.err != "" {
		changes_message(v, c.err, abs)
		return
	}
	v.diff = strings.clone(c.text)
	v.diff_lines = strings.count(v.diff, "\n")
	changes_show(v, abs)
}

// Puts the first v.shown lines of the diff in the editor.
@(private = "file")
changes_show :: proc(v: ^Changes_View, abs: string) {
	e := editor_of(v.tab_id)
	if e == nil do return
	text := v.diff
	if v.diff_lines > v.shown {
		end := 0
		for _ in 0 ..< v.shown {
			i := strings.index_byte(text[end:], '\n')
			if i < 0 do break
			end += i + 1
		}
		text = text[:end]
	}
	delete(e.refused)
	e.refused = ""
	delete(e.path)
	e.path = strings.clone(abs)
	editor_set_text(e, text) // keeps the scroll position (a refresh of the same file)
}

// "Show more": CHANGES_LINES_STEP more lines of a long diff.
changes_show_more :: proc(v: ^Changes_View) {
	if v.diff_lines <= v.shown do return
	v.shown += CHANGES_LINES_STEP
	e := editor_of(v.tab_id)
	top := e != nil ? e.top : 0
	changes_show(v, e != nil ? strings.clone(e.path, context.temp_allocator) : v.root)
	if e != nil do e.top = top
}

// The new file's line at the diff editor's cursor: the hunk above it
// ("@@ -a,b +c,d @@"), counted down to the cursor's line (0 = no hunk).
changes_line_at_cursor :: proc(v: ^Changes_View) -> int {
	e := editor_of(v.tab_id)
	if e == nil || e.refused != "" do return 0
	text := tb_text(&e.buf, context.temp_allocator)
	return diff_new_line(text, tb_line_of(&e.buf, e.cursor))
}

// The new file's line for diff line `at` (0-based) of a unified diff's
// hunks; 0 = before any hunk.
diff_new_line :: proc(text: string, at: int) -> int {
	lines := strings.split_lines(text, context.temp_allocator)
	start, hunk := 0, -1
	for i := min(at, len(lines) - 1); i >= 0; i -= 1 {
		if strings.has_prefix(lines[i], "@@ ") {
			hunk = i
			break
		}
	}
	if hunk < 0 {
		// before the first hunk: the first hunk's start
		for l in lines do if strings.has_prefix(l, "@@ ") do return diff_hunk_start(l)
		return 0
	}
	start = diff_hunk_start(lines[hunk])
	n := start
	for i in hunk + 1 ..< min(at + 1, len(lines)) {
		if strings.has_prefix(lines[i], "-") do continue
		if i == at do break
		n += 1
	}
	return max(n, 1)
}

// "@@ -a,b +c,d @@" -> c.
diff_hunk_start :: proc(head: string) -> int {
	i := strings.index(head, " +")
	if i < 0 do return 1
	rest := head[i + 2:]
	j := strings.index_any(rest, ", ")
	if j >= 0 do rest = rest[:j]
	n, _ := strconv.parse_int(rest)
	return max(n, 1)
}

// ---- commands ----

changes_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Changes_Open:
		s := c.session != 0 ? find_session(c.session) : caller_session(caller)
		if s != nil && s.home && c.session == 0 do s = cur() // Home's control: the session on screen
		if s == nil do return fail("no open session to show the changes in"), false
		if s.home do return fail("Home has only its pi tab"), false
		dir := c.path != "" ? c.path : s.cwd
		if caller.kind != .UI && caller.kind != .Internal && c.path != "" {
			if _, _, err := fs_check(c.path, caller, allow_root = true); err != "" do return fail(err), false
		}
		root, err := changes_root_check(fs_real(fs_abs(dir, caller)))
		if err != "" do return fail(err), false
		for tab in s.tabs {
			if ct, is := tab.kind.(Changes_Tab); is && ct.root == root {
				session_show_tab(s, tab.id)
				focus_session(s.id, caller)
				changes_refresh(changes_repo(root))
				return {ok = true, created_id = tab.id}, true
			}
		}
		title := "Changes"
		if root != fs_real(s.cwd) && changes_root_of(s.cwd) != root do title = fmt.tprintf("Changes · %s", filepath.base(root))
		tab := Tab{id = new_id(), kind = Changes_Tab{root = strings.clone(root)}, title = strings.clone(title), status = .Running}
		pane_add_tab(s, tab)
		session_show_tab(s, tab.id)
		focus_session(s.id, caller)
		changes_view_new(tab.id, root)
		return {ok = true, created_id = tab.id}, true
	case Changes_List:
		root := ""
		if c.tab_id != 0 {
			v := changes_view(c.tab_id)
			if v == nil do return fail("no such changes tab"), false
			root = v.root
		} else {
			dir := c.path
			if dir == "" {
				s := caller_session(caller)
				if s == nil || s.home do s = cur()
				if s == nil || s.home do return fail("no session: give a path"), false
				dir = s.cwd
			} else if caller.kind != .UI && caller.kind != .Internal {
				if _, _, err := fs_check(dir, caller, allow_root = true); err != "" do return fail(err), false
			}
			err: string
			root, err = changes_root_check(fs_real(fs_abs(dir, caller)))
			if err != "" do return fail(err), false
		}
		repo := changes_repo(root)
		if repo == nil do return fail("not in a git repository"), false
		changes_ask(repo)
		return {ok = true, data = strings.clone(changes_json(repo))}, false
	case Changes_Stage, Changes_Unstage:
		tab_id: u64
		path, status: string
		stage := false
		#partial switch x in cmd {
		case Changes_Stage:   tab_id, path, status, stage = x.tab_id, x.path, x.status, true
		case Changes_Unstage: tab_id, path, status = x.tab_id, x.path, x.status
		}
		v, repo, f, err := changes_target(tab_id, path, status)
		if err != "" do return fail(err), false
		if v.busy != "" do return fail("another action on this checkout is running"), false
		if stage && !f.unstaged do return fail("nothing to stage"), false
		if !stage && f.staged == .None do return fail("nothing staged"), false
		args := make([dynamic]string, context.temp_allocator)
		if stage {
			append(&args, "--literal-pathspecs", "add", "-A", "--", f.path)
		} else if repo.has_head {
			append(&args, "--literal-pathspecs", "restore", "--staged", "--", f.path)
		} else {
			append(&args, "--literal-pathspecs", "rm", "--cached", "-q", "--", f.path)
		}
		if f.old_path != "" do append(&args, f.old_path)
		changes_op_start(v, request_id, stage ? "stage" : "unstage", args[:], "")
		return {ok = true, pending = true}, false
	case Changes_Discard:
		v, repo, f, err := changes_target(c.tab_id, c.path, c.status)
		if err != "" do return fail(err), false
		if v.busy != "" do return fail("another action on this checkout is running"), false
		if f.status == 'U' do return fail("a conflicted file: resolve it in a terminal"), false
		abs := strings.concatenate({repo.root, "/", strings.trim_suffix(f.path, "/")}, context.temp_allocator)
		folder := strings.has_suffix(f.path, "/") || path_kind(abs) == .Dir
		if folder && os.exists(strings.concatenate({abs, "/.git"}, context.temp_allocator)) do return fail("a nested git repository: not discarded here (its own changes would go too)"), false
		// restoring from HEAD writes the work tree: never over a file the list does not say is this entry's
		restores := f.in_head && f.status != '?'
		if restores {
			target := f.status == 'R' ? f.old_path : f.path
			if (f.status == 'D' || f.status == 'R') && changes_on_disk(strings.concatenate({repo.root, "/", target}, context.temp_allocator)) {
				return fail(fmt.tprintf("%s is also in the work tree (untracked): restoring it from HEAD would overwrite it. Discard or stage that entry first.", target)), false
			}
		}
		new_file := !f.in_head || f.status == 'R' // its (new) name goes to the Trash
		where_ := fs_display(abs)
		if folder do where_ = fmt.tprintf("the folder %s (and everything in it)", where_)
		if c.second && c.confirm == "" do return fail("the second confirmation comes after the first"), false
		wire := change_status_wire(f.status)
		parked := Changes_Discard{tab_id = c.tab_id, path = f.path, status = wire, second = c.second}
		what: string
		switch {
		case c.second:
			what = fmt.tprintf("Really move %s to the Trash? Git does not have this file, so it cannot bring it back.", where_)
		case new_file:
			what = fmt.tprintf("Discard %s? It is not in the last commit: it goes to the Trash (a second question follows).", where_)
		case:
			what = fmt.tprintf("Discard the uncommitted changes to %s? Staged and unstaged changes are lost.", where_)
		}
		gr, go_on, ch := confirm_gate(parked, .Delete, caller, c.confirm, what)
		if !go_on do return gr, ch
		if new_file && !c.second {
			// the first yes: now the second question (the user's again)
			gr2, _, ch2 := confirm_gate(Changes_Discard{tab_id = c.tab_id, path = f.path, status = wire, second = true}, .Delete, caller, "", fmt.tprintf("Really move %s to the Trash? Git does not have this file, so it cannot bring it back.", where_))
			return gr2, ch || ch2
		}
		args := make([dynamic]string, context.temp_allocator)
		trash := ""
		switch {
		case f.status == '?':
			trash = f.path
		case f.status == 'R':
			// the old name back from HEAD, the new one out of the index and to the Trash
			append(&args, "--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--", f.old_path)
			trash = f.path
		case !f.in_head:
			append(&args, "--literal-pathspecs", "rm", "--cached", "-q", "--", f.path)
			trash = f.path
		case:
			append(&args, "--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--", f.path)
		}
		if f.status == 'R' {
			// two git steps: restore, then rm --cached (the worker runs them in order)
			append(&args, "\x00", "--literal-pathspecs", "rm", "--cached", "-q", "--ignore-unmatch", "--", f.path)
		}
		changes_op_start(v, request_id, "discard", args[:], trash)
		return {ok = true, pending = true}, ch
	case Changes_Commit:
		v := changes_view(c.tab_id)
		if v == nil do return fail("no such changes tab"), false
		repo := changes_repo(v.root)
		if repo == nil do return fail("not in a git repository"), false
		if v.busy != "" do return fail("another action on this checkout is running"), false
		msg := strings.trim_space(c.message)
		if msg == "" do return fail("a commit message is needed"), false
		staged := false
		for f in repo.files do if f.scope == .Uncommitted && f.staged != .None do staged = true
		if !staged do return fail("nothing staged: stage files first"), false
		changes_commit_start(v, request_id, msg)
		return {ok = true, pending = true}, false
	case Changes_Scan_Done:
		changes_scan_done(c)
		return {ok = true}, false
	case Changes_Diff_Done:
		changes_diff_done(c)
		return {ok = true}, false
	case Changes_Op_Done:
		return changes_op_done(c)
	}
	return fail("unknown command"), false
}

// The checkout of dir if it may be shown: a real checkout (wt_verified)
// holding a project or session folder, inside one, or a known checkout of
// a project's repository.
changes_root_check :: proc(dir: string) -> (root, err: string) {
	if dir == "" || !os.is_dir(dir) do return "", "no such folder"
	top := changes_root_of(dir)
	if top == "" do return "", "not in a git repository"
	if wt_verified(top) == "" do return "", "not a git checkout"
	for b in fs_base_roots() do if within_dir(b, top) || within_dir(top, b) do return top, ""
	if wt_known_checkout(top) do return top, ""
	return "", "not a checkout of a project"
}

// The tab, its checkout and the listed uncommitted file a user action is about.
@(private = "file")
changes_target :: proc(tab_id: u64, path, status: string) -> (v: ^Changes_View, r: ^Changes_Repo, f: ^Change_File, err: string) {
	v = changes_view(tab_id)
	if v == nil do return nil, nil, nil, "no such changes tab"
	r = changes_repo(v.root)
	if r == nil || !r.loaded do return nil, nil, nil, "the changes are being read: try again"
	st := change_status_of_wire(status)
	if status != "" && st == 0 do return nil, nil, nil, "status: M, A, D, R, U or untracked"
	n := 0
	for x in r.files do if x.path == path && x.scope == .Uncommitted do n += 1
	if n > 1 && st == 0 do return nil, nil, nil, fmt.tprintf("%s has %d entries: give its status", path, n)
	f = changes_find(r, path, .Uncommitted, st)
	if f == nil do return nil, nil, nil, "not an uncommitted file of this checkout"
	return v, r, f, ""
}

// Something is at path (a file, a folder, a link, even a dangling one).
changes_on_disk :: proc(path: string) -> bool {
	_, err := os.lstat(path, context.temp_allocator)
	return err == nil
}

@(private = "file")
op_busy :: proc(what: string) -> string {
	switch what {
	case "stage":   return "Staging…"
	case "unstage": return "Unstaging…"
	case "discard": return "Discarding…"
	}
	return "Committing…"
}

// Runs git steps (args; "\x00" splits steps) on a worker in the checkout;
// Changes_Op_Done comes back. Hooks off (git_run_for).
@(private = "file")
changes_op_start :: proc(v: ^Changes_View, request_id: u64, what: string, args: []string, trash: string) {
	delete(v.notice)
	v.notice, v.notice_err = "", false
	v.busy = op_busy(what)
	window_state_changed()
	Job :: struct {
		tab_id, request_id: u64,
		root, what, trash:  string,
		args:               []string,
	}
	h := runtime.heap_allocator()
	cargs := make([]string, len(args), h)
	for a, i in args do cargs[i] = strings.clone(a, h)
	job := new_clone(Job{v.tab_id, request_id, strings.clone(v.root, h), what, strings.clone(trash, h), cargs}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		err := ""
		start := 0
		for i in 0 ..= len(job.args) {
			if i < len(job.args) && job.args[i] != "\x00" do continue
			if i > start {
				if _, st := git_group(job.root, CHANGES_OP_TIMEOUT, 1 << 20, ..job.args[start:i]); st != .Ok {
					err = fmt.tprintf("git %s %s", job.args[start + 1], st == .Timed_Out ? "timed out" : "failed")
					if st == .Timed_Out do err = changes_lock_note(job.root, err)
					break
				}
			}
			start = i + 1
		}
		inbox_submit(Changes_Op_Done{tab_id = job.tab_id, root = job.root, request_id = job.request_id, what = job.what, trash = err == "" ? job.trash : "", err = err}, {kind = .Internal}) // copied
		for a in job.args do delete(a, h)
		delete(job.args, h)
		delete(job.root, h)
		delete(job.trash, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// git commit as the user's terminal runs it (their hooks and signing):
// the message on stdin, git's own output kept for the tab.
@(private = "file")
changes_commit_start :: proc(v: ^Changes_View, request_id: u64, msg: string) {
	delete(v.notice)
	v.notice, v.notice_err = "", false
	v.busy = op_busy("commit")
	window_state_changed()
	Job :: struct {
		tab_id, request_id: u64,
		root, msg:          string,
	}
	h := runtime.heap_allocator()
	job := new_clone(Job{v.tab_id, request_id, strings.clone(v.root, h), strings.clone(msg, h)}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		// as a terminal runs it: the user's login shell (its PATH finds gpg, pre-commit, husky
		// when Deckhand started from Finder), their hooks, its own process group
		shell := os.get_env("SHELL", context.temp_allocator)
		if shell == "" do shell = "/bin/zsh"
		argv := shell_script_argv(shell, `cd "$1" && exec git commit -F -`, "deckhand-commit") // fish and co.: /bin/sh
		append(&argv, job.root)
		out, st := run_group(argv[:], changes_commit_timeout, input = strings.concatenate({job.msg, "\n"}, context.temp_allocator), cap = 1 << 20, merge_stderr = true)
		err := ""
		switch st {
		case .Ok:
		case .Timed_Out:    err = changes_lock_note(job.root, fmt.tprintf("git commit timed out after %v and was stopped (with its hooks)", changes_commit_timeout))
		case .Start_Failed: err = "could not start git commit"
		case .Failed, .Too_Big: err = changes_last_lines(out, "git commit failed (a hook may have refused it)")
		}
		inbox_submit(Changes_Op_Done{tab_id = job.tab_id, root = job.root, request_id = job.request_id, what = "commit", err = err}, {kind = .Internal})
		delete(job.root, h)
		delete(job.msg, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// The last few lines of git's output, one line for the tab (temp allocator).
changes_last_lines :: proc(out, fallback: string) -> string {
	lines := strings.split_lines(strings.trim_space(out), context.temp_allocator)
	kept := make([dynamic]string, context.temp_allocator)
	for i := len(lines) - 1; i >= 0 && len(kept) < 3; i -= 1 {
		l := strings.trim_space(lines[i])
		if l != "" do inject_at(&kept, 0, l)
	}
	if len(kept) == 0 do return fallback
	s := strings.join(kept[:], " · ", context.temp_allocator)
	if len(s) > 300 do s = fmt.tprintf("%s…", cut_utf8(s, 300))
	return one_line(s, context.temp_allocator)
}

// After a stopped git: a lock it left is named, never removed (another
// git may hold it).
changes_lock_note :: proc(root, err: string) -> string {
	gd, ok := git_run(root, "rev-parse", "--absolute-git-dir")
	if !ok do return err
	if !os.exists(strings.concatenate({strings.trim_space(gd), "/index.lock"}, context.temp_allocator)) do return err
	return fmt.tprintf("%s. git left index.lock — another git process may be running; remove it only if none is.", err)
}

// An action's worker finished (main thread): a discarded new file goes to
// the Trash, the checkout is read again, the tab says how it went.
@(private = "file")
changes_op_done :: proc(c: Changes_Op_Done) -> (r: Result, changed: bool) {
	err := c.err
	if err == "" && c.trash != "" {
		p := strings.concatenate({c.root, "/", c.trash}, context.temp_allocator)
		if os.exists(p) && !fs_trash_fn(p) do err = "could not move it to the Trash"
	}
	fs_model_changed(c.root) // the Files tab's git status too
	changes_refresh(changes_repo(c.root))
	if v := changes_view(c.tab_id); v != nil {
		v.busy = ""
		delete(v.notice)
		v.notice_err = err != ""
		switch {
		case err != "":         v.notice = strings.clone(err)
		case c.what == "commit": v.notice = strings.clone("Committed")
		case:                    v.notice = ""
		}
		if c.what == "commit" && err == "" do tf_set(&changes_message_field, "")
	}
	window_state_changed()
	res := Result{ok = err == ""}
	if err != "" do res.error = c.what == "commit" ? "git commit failed (the Changes tab shows git's output)" : err
	emit_event(Finished_Event{request_id = c.request_id, result = res})
	return {ok = true}, false
}

// The commit message field (ui_changes.odin; focus widget changes_message).
changes_message_field: Text_Field

// changes_list's data: paths and counts, never diff text (temp allocator).
changes_json :: proc(r: ^Changes_Repo) -> string {
	b := strings.builder_make(context.temp_allocator)
	str :: proc(b: ^strings.Builder, k, v: string) {
		fmt.sbprintf(b, `,"%s":`, k)
		json_quote(b, v)
	}
	strings.write_string(&b, `{"root":`)
	json_quote(&b, r.root)
	fmt.sbprintf(&b, `,"loading":%v`, r.loading || !r.loaded)
	str(&b, "branch", r.branch)
	str(&b, "default_branch", r.default_branch)
	fmt.sbprintf(&b, `,"ahead":%d`, r.ahead)
	if r.truncated do strings.write_string(&b, `,"truncated":true`)
	if r.err != "" do str(&b, "error", r.err)
	staged_names := [Change_Staged]string{.None = "none", .Partly = "partly", .All = "all"}
	strings.write_string(&b, `,"files":[`)
	for f, i in r.files {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"path":`)
		json_quote(&b, f.path)
		if f.old_path != "" do str(&b, "old_path", f.old_path)
		str(&b, "status", f.status == '?' ? "untracked" : string([]u8{f.status}))
		str(&b, "scope", f.scope == .Committed ? "committed" : "uncommitted")
		if f.scope == .Uncommitted do str(&b, "staged", staged_names[f.staged])
		if f.added >= 0 do fmt.sbprintf(&b, `,"added":%d,"removed":%d`, f.added, f.removed)
		if f.binary do strings.write_string(&b, `,"binary":true`)
		if f.credential do strings.write_string(&b, `,"credential":true`)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// ---- command plumbing (inbox.odin, json_write.odin) ----

changes_command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	s :: proc(x: string, a: runtime.Allocator) -> string {return strings.clone(x, a)}
	#partial switch c in cmd {
	case Changes_Open:      return Changes_Open{session = c.session, path = s(c.path, allocator)}
	case Changes_List:      return Changes_List{tab_id = c.tab_id, path = s(c.path, allocator)}
	case Changes_Stage:     return Changes_Stage{tab_id = c.tab_id, path = s(c.path, allocator), status = s(c.status, allocator)}
	case Changes_Unstage:   return Changes_Unstage{tab_id = c.tab_id, path = s(c.path, allocator), status = s(c.status, allocator)}
	case Changes_Discard:   return Changes_Discard{tab_id = c.tab_id, path = s(c.path, allocator), status = s(c.status, allocator), confirm = s(c.confirm, allocator), second = c.second}
	case Changes_Commit:    return Changes_Commit{tab_id = c.tab_id, message = s(c.message, allocator)}
	case Changes_Scan_Done: return Changes_Scan_Done{root = s(c.root, allocator), gen = c.gen, out = s(c.out, allocator)}
	case Changes_Diff_Done: return Changes_Diff_Done{tab_id = c.tab_id, gen = c.gen, text = s(c.text, allocator), err = s(c.err, allocator)}
	case Changes_Op_Done:   return Changes_Op_Done{tab_id = c.tab_id, root = s(c.root, allocator), request_id = c.request_id, what = c.what, trash = s(c.trash, allocator), err = s(c.err, allocator)}
	}
	return cmd
}

changes_command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Changes_Open:    delete(c.path, allocator)
	case Changes_List:    delete(c.path, allocator)
	case Changes_Stage:
		delete(c.path, allocator)
		delete(c.status, allocator)
	case Changes_Unstage:
		delete(c.path, allocator)
		delete(c.status, allocator)
	case Changes_Discard:
		delete(c.path, allocator)
		delete(c.status, allocator)
		delete(c.confirm, allocator)
	case Changes_Commit:  delete(c.message, allocator)
	case Changes_Scan_Done:
		delete(c.root, allocator)
		delete(c.out, allocator)
	case Changes_Diff_Done:
		delete(c.text, allocator)
		delete(c.err, allocator)
	case Changes_Op_Done:
		delete(c.root, allocator)
		delete(c.trash, allocator)
		delete(c.err, allocator)
	}
}

changes_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Changes_Open:      return "changes_open"
	case Changes_List:      return "changes_list"
	case Changes_Stage:     return "changes_stage"
	case Changes_Unstage:   return "changes_unstage"
	case Changes_Discard:   return "changes_discard"
	case Changes_Commit:    return "changes_commit"
	case Changes_Scan_Done: return "changes_scan_done"
	case Changes_Diff_Done: return "changes_diff_done"
	case Changes_Op_Done:   return "changes_op_done"
	}
	return ""
}
