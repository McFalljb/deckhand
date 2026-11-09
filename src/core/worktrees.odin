package core

// Git worktrees and branches of the Files tab's repository (the checkout
// switcher, ui_worktrees.odin). Per repository, keyed by its common git dir:
// the checkouts (`git worktree list --porcelain`, run in the main checkout),
// the local branches (`git for-each-ref refs/heads`: upstream, last commit,
// ahead/behind the default branch), each checkout's changed-file count. One
// worker run reads it all (Worktrees_Done), at most once per WT_GAP, only
// while something asks (the switcher on screen, list_worktrees), and again
// after a change under .git (HEAD, refs, worktrees/) or in a checkout, or on
// Refresh. Every git call is bounded, with fsmonitor and optional locks off
// (git_run).
//
// Which repository a folder is in, and whether two folders are checkouts
// of the same one, comes from the files git keeps (`.git` folder, or a
// `.git` file naming the gitdir, whose `commondir` leads to the shared one),
// so the commands can check paths without running git.
//
// Commands: list_worktrees (read-only, any caller), files_set_root (the
// Files tree shows another checkout of its project), worktree_cleanup (the
// user's only, confirmed: `git worktree remove` then `git branch -d`, never
// forced) and worktree_session (a pi session in a checkout).

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

List_Worktrees :: struct {
	path: string, // a folder of the repository ("" = the Files tab's project)
}
// The Files tree of base (a project or session folder) shows path, another
// checkout of the same repository ("" or base itself = base again).
Files_Set_Root :: struct {
	base: string, // "" = the Files tab's project
	path: string,
}
// Removes a merged, clean worktree and deletes its merged branch (the
// user's only; confirms, class delete).
Worktree_Cleanup :: struct {
	path:    string,
	confirm: string,
}
// A new pi session of a project, running in one of its repository's checkouts.
Worktree_Session :: struct {
	project_id: u64,
	path:       string,
}
// Internal: a worker read a repository's worktrees and branches.
Worktrees_Done :: struct {
	common: string,
	gen:    u64,
	out:    string,
}

WT_GAP :: 2 * time.Second // between scans of one repository
WT_MAX :: 32 // checkouts read (their changed files counted)
WT_BRANCHES_MAX :: 100 // branches without a checkout, most recent first
WT_WHERE_MAX :: 256 // folders whose repository is remembered
WT_REMOVE_TIMEOUT :: 60 * time.Second // git worktree remove deletes the folder's files

Wt_Checkout :: struct {
	path:     string,
	branch:   string, // "" = detached (or bare)
	head:     string, // commit id
	main:     bool, // the main checkout (the first git lists)
	detached: bool,
	bare:     bool,
	locked:   bool,
	prunable: bool, // git says its folder is gone (git worktree prune would drop it)
	missing:  bool, // its folder is not there
	dirty:    int, // changed (and untracked) paths; -1 = not counted
	upstream: string,
	gone:     bool, // its upstream branch is gone
	ahead:    int, // vs its upstream when it has one, else vs the default branch; -1 = unknown
	behind:   int,
	merged:   bool, // its branch is in the default branch
}

Wt_Branch :: struct {
	name:     string,
	upstream: string,
	gone:     bool,
	up_ahead, up_behind: int, // vs its upstream (0 without)
	ahead:    int, // vs the default branch; -1 = unknown
	behind:   int,
	merged:   bool,
	date:     i64, // last commit (unix seconds)
	subject:  string,
	checkout: bool, // checked out in a worktree (listed with the checkouts)
}

Wt_Repo :: struct {
	common:         string, // key: the common git dir (owned)
	arena:          virtual.Arena, // everything below
	main:           string, // the main checkout's folder ("" = a bare repository)
	default_branch: string, // what "merged" and ahead/behind compare with ("" = none found)
	checkouts:      [dynamic]Wt_Checkout,
	branches:       [dynamic]Wt_Branch,
	err:            string,
	loaded:         bool, // a scan arrived
	ok:             bool, // current: no change under .git since
	files_changed:  bool, // a file in a checkout changed since (changed-file counts)
	loading:        bool,
	want:           bool, // asked for within the gap: wt_tick starts it
	gen:            u64, // bumped by every change: a scan started before one is not ok
	started:        time.Tick,
	runs:           int, // scans started (tests)
}

wt_repos: [dynamic]^Wt_Repo

// Where a folder is in git: the checkout's top folder (holding .git), the
// repository's common git dir, and whether it is a linked worktree.
Wt_Where :: struct {
	top, common: string, // owned; "" = not in a repository
	linked:      bool,
}

@(private = "file")
wt_where_cache: map[string]Wt_Where // folder (owned key) -> where

// ---- where a folder is (files only, no git) ----

// The common git dir named by top/.git ("" = none): a folder is it; a file
// "gitdir: X" leads to X, and X/commondir (if any) to the shared one: a
// linked worktree (a submodule's .git file has none).
@(private = "file")
wt_git_entry :: proc(top: string) -> (common: string, linked: bool) {
	g := strings.concatenate({top, "/.git"}, context.temp_allocator)
	if os.is_dir(g) do return fs_real(g), false
	data, err := os.read_entire_file(g, context.temp_allocator)
	if err != nil do return "", false
	s := strings.trim_space(string(data))
	if !strings.has_prefix(s, "gitdir:") do return "", false
	gd := strings.trim_space(s[len("gitdir:"):])
	if gd == "" do return "", false
	if !filepath.is_abs(gd) do gd, _ = filepath.join({top, gd}, context.temp_allocator)
	cd := gd
	if cdata, cerr := os.read_entire_file(strings.concatenate({gd, "/commondir"}, context.temp_allocator), context.temp_allocator); cerr == nil {
		c := strings.trim_space(string(cdata))
		if c != "" {
			cd = c
			if !filepath.is_abs(c) do cd, _ = filepath.join({gd, c}, context.temp_allocator)
			linked = true
		}
	}
	return fs_real(cd), linked
}

// Where dir is in git (files only; cached until wt_refresh). The checkout
// whose .git is nearest above it. Temp allocator (the cache may be dropped
// by the next change).
wt_where :: proc(dir: string) -> Wt_Where {
	if dir == "" do return {}
	w := wt_where_cached(dir)
	return {top = strings.clone(w.top, context.temp_allocator), common = strings.clone(w.common, context.temp_allocator), linked = w.linked}
}

@(private = "file")
wt_where_cached :: proc(dir: string) -> Wt_Where {
	if w, ok := wt_where_cache[dir]; ok do return w
	if len(wt_where_cache) >= WT_WHERE_MAX do wt_where_forget() // paths from commands: bounded
	w: Wt_Where
	for p := fs_real(dir); p != "" ; p = filepath.dir(p) {
		if os.exists(strings.concatenate({p, "/.git"}, context.temp_allocator)) {
			if c, linked := wt_git_entry(p); c != "" do w = {top = strings.clone(p), common = strings.clone(c), linked = linked}
			break
		}
		if p == "/" do break
	}
	wt_where_cache[strings.clone(dir)] = w
	return w
}

@(private = "file")
wt_where_forget :: proc() {
	for k, w in wt_where_cache {
		delete(k)
		delete(w.top)
		delete(w.common)
	}
	clear(&wt_where_cache)
}

// Forgets where folders are and marks every repository changed (Refresh).
wt_refresh :: proc() {
	wt_where_forget()
	for r in wt_repos {
		r.ok = false
		r.gen += 1
	}
}

// The common git dir of the checkout whose top folder is path, if it
// really is one ("" = not): its .git a folder that is the common dir
// itself, not a link (the main checkout); or a .git file naming a gitdir
// under the common dir's worktrees/ that points back at path/.git (a
// linked worktree). A crafted .git file or a link cannot claim another
// repository. Files only.
wt_verified :: proc(path: string) -> string {
	p := fs_real(path)
	g := strings.concatenate({p, "/.git"}, context.temp_allocator)
	fi, err := os.lstat(g, context.temp_allocator)
	if err != nil do return ""
	if fi.type == .Directory do return fs_real(g) == g ? g : ""
	if fi.type != .Regular do return ""
	common, linked := wt_git_entry(p)
	if common == "" || !linked do return ""
	data, _ := os.read_entire_file(g, context.temp_allocator)
	gd := strings.trim_space(strings.trim_space(string(data))[len("gitdir:"):])
	if !filepath.is_abs(gd) do gd, _ = filepath.join({p, gd}, context.temp_allocator)
	gd = fs_real(gd)
	if !wt_within(gd, strings.concatenate({common, "/worktrees"}, context.temp_allocator)) || gd == strings.concatenate({common, "/worktrees"}, context.temp_allocator) do return ""
	back, berr := os.read_entire_file(strings.concatenate({gd, "/gitdir"}, context.temp_allocator), context.temp_allocator)
	if berr != nil do return ""
	b := strings.trim_space(string(back))
	if !filepath.is_abs(b) do b, _ = filepath.join({gd, b}, context.temp_allocator)
	if fs_real(b) != g do return ""
	return common
}

// Why path may not be used as a checkout of the repository holding base
// ("" = it may): it must really be one (wt_verified) of that repository;
// listed: and the last `git worktree list` must have listed it (a scan
// starts when none is there yet).
wt_checkout_err :: proc(base, path: string, listed: bool) -> string {
	p := fs_real(path)
	common := wt_verified(p)
	if common == "" || common != wt_where(base).common do return "not a checkout of the project's repository"
	if !listed do return ""
	r := wt_repo_for(base)
	if r == nil || !r.loaded do return "worktrees are being read: try again"
	c := wt_checkout(r, p)
	if c == nil || c.missing do return "not a checkout of the project's repository"
	return ""
}

// Whether path is the top folder of a checkout of a known project's
// repository (projects and open sessions, not the Files tab's own
// choices), as the last scan listed it.
wt_known_checkout :: proc(path: string) -> bool {
	p := fs_real(path)
	common := wt_verified(p)
	if common == "" do return false
	for r in fs_base_roots() do if wt_where(r).common == common do return wt_checkout_err(r, p, listed = true) == ""
	return false
}

// ---- the model ----

// The repository holding dir, its scan started if it is not current (""
// or not in a repository: nil). counts: the changed-file counts must be
// current too (the switcher's menu, list_worktrees); without, only a
// change under .git scans again (the switcher's button).
wt_repo_for :: proc(dir: string, counts := true) -> ^Wt_Repo {
	w := wt_where(dir)
	if w.common == "" do return nil
	r: ^Wt_Repo
	for x in wt_repos do if x.common == w.common do r = x
	if r == nil {
		r = new(Wt_Repo)
		r.common = strings.clone(w.common)
		append(&wt_repos, r)
	}
	if !r.ok || (counts && r.files_changed) do wt_load(r, w.top)
	return r
}

// Starts a scan on a worker unless one runs or the last one is current; a
// scan within WT_GAP of the last waits (wt_tick).
@(private = "file")
wt_load :: proc(r: ^Wt_Repo, dir: string) {
	if r.loading do return
	if r.started != {} && time.tick_since(r.started) < WT_GAP {
		r.want = true
		return
	}
	r.want = false
	r.started = time.tick_now()
	r.loading = true
	r.files_changed = false // a change from now on is not in this scan
	r.runs += 1
	Job :: struct {
		common, dir: string,
		gen:         u64,
	}
	h := runtime.heap_allocator()
	job := new_clone(Job{strings.clone(r.common, h), strings.clone(dir, h), r.gen}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		out := wt_scan(job.common, job.dir)
		inbox_submit(Worktrees_Done{common = job.common, gen = job.gen, out = out}, {kind = .Internal}) // copied
		delete(out, h)
		delete(job.common, h)
		delete(job.dir, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// Main thread, every frame callback (fs_model_tick): a scan the gap held back.
wt_tick :: proc() {
	for r in wt_repos {
		if r.want && !r.loading && time.tick_since(r.started) >= WT_GAP {
			main := r.main != "" ? r.main : (filepath.base(r.common) == ".git" ? filepath.dir(r.common) : r.common)
			wt_load(r, main)
		}
	}
}

// The repository holding dir changed (our own git command): scanned again when next asked for.
wt_stale :: proc(dir: string) {
	common := wt_where(dir).common
	for r in wt_repos do if r.common == common {
		r.ok = false
		r.gen += 1
	}
}

// Something changed at path (fs_model_changed; ignored paths left out): a
// repository's refs, HEADs or worktree list, or a file in one of its
// checkouts (changed-file counts). Scanned again when next asked for.
wt_path_changed :: proc(path: string) {
	if strings.has_suffix(path, "/.git") do wt_where_forget() // a repository made or removed: looked up again
	if len(wt_repos) == 0 do return
	for r in wt_repos {
		if wt_within(path, r.common) {
			rel := path[len(r.common):]
			if rel == "" || strings.has_prefix(rel, "/HEAD") || strings.has_prefix(rel, "/refs") || strings.has_prefix(rel, "/packed-refs") || strings.has_prefix(rel, "/worktrees") || strings.has_prefix(rel, "/index") {
				r.ok = false
				r.gen += 1
			}
			continue
		}
		for c in r.checkouts do if wt_within(path, c.path) {
			r.files_changed = true
			break
		}
	}
}

wt_within :: proc(path, root: string) -> bool {
	return root != "" && (path == root || (strings.has_prefix(path, root) && len(path) > len(root) && path[len(root)] == '/'))
}

// ---- the scan (any thread; temp allocator) ----

// Lines of fields split by \x1f: "R main default", "W path branch head
// flags dirty", "B name upstream track date ahead behind merged subject",
// "E message". Values holding a line break or \x1f are left out.
wt_scan :: proc(common, dir: string) -> string {
	b := strings.builder_make(runtime.heap_allocator())
	clean :: proc(s: string) -> bool {return strings.index_any(s, "\n\x1f") < 0}
	line :: proc(b: ^strings.Builder, fields: ..string) {
		for f, i in fields {
			if i > 0 do strings.write_byte(b, 0x1f)
			strings.write_string(b, f)
		}
		strings.write_byte(b, '\n')
	}
	main := filepath.base(common) == ".git" ? filepath.dir(common) : ""
	at := main != "" && os.is_dir(main) ? main : dir
	out, ok := git_run(at, "worktree", "list", "--porcelain", "-z")
	if !ok {
		line(&b, "E", "git worktree list failed")
		return strings.to_string(b)
	}
	Wt :: struct {
		path, head, branch:                   string,
		bare, detached, locked, prunable: bool,
	}
	wts := make([dynamic]Wt, context.temp_allocator)
	in_rec := false
	for f in strings.split(out, "\x00", context.temp_allocator) {
		if f == "" {
			in_rec = false
			continue
		}
		if strings.has_prefix(f, "worktree ") {
			append(&wts, Wt{path = f[len("worktree "):]})
			in_rec = true
			continue
		}
		if !in_rec do continue
		w := &wts[len(wts) - 1]
		switch {
		case strings.has_prefix(f, "HEAD "):    w.head = f[len("HEAD "):]
		case strings.has_prefix(f, "branch "):  w.branch = strings.trim_prefix(f[len("branch "):], "refs/heads/")
		case f == "bare":                       w.bare = true
		case f == "detached":                   w.detached = true
		case strings.has_prefix(f, "locked"):   w.locked = true
		case strings.has_prefix(f, "prunable"): w.prunable = true
		}
	}
	// local branches: name, upstream, its track, last commit date and subject
	Br :: struct {
		name, upstream, track, date, subject: string,
		ab:                                   string, // "A B" vs the default branch
		merged:                               bool,
	}
	brs := make([dynamic]Br, context.temp_allocator)
	if refs, rok := git_run(at, "for-each-ref", "--format=%(refname:short)%00%(upstream:short)%00%(upstream:track,nobracket)%00%(committerdate:unix)%00%(subject)", "refs/heads"); rok {
		for l in strings.split_lines(refs, context.temp_allocator) {
			f := strings.split(l, "\x00", context.temp_allocator)
			if len(f) < 5 || f[0] == "" do continue
			append(&brs, Br{name = f[0], upstream = f[1], track = f[2], date = f[3], subject = f[4]})
		}
	}
	has_local :: proc(brs: []Br, name: string) -> bool {
		for x in brs do if x.name == name do return true
		return false
	}
	// the default branch: origin's HEAD, else main or master, else the main checkout's
	def := ""
	if o, sok := git_run(at, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"); sok {
		def = strings.trim_prefix(strings.trim_space(o), "origin/")
	}
	if def == "" || !has_local(brs[:], def) {
		def = ""
		for c in ([]string{"main", "master"}) do if has_local(brs[:], c) {
			def = c
			break
		}
	}
	if def == "" && len(wts) > 0 && !wts[0].bare do def = wts[0].branch
	if def != "" {
		// ahead/behind the default branch for every branch at once (git 2.41+); merged = nothing ahead
		def_ref := strings.concatenate({"refs/heads/", def}, context.temp_allocator) // never a tag of the same name
		if ab, aok := git_run(at, "for-each-ref", fmt.tprintf("--format=%%(refname:short)%%00%%(ahead-behind:%s)", def_ref), "refs/heads"); aok {
			for l in strings.split_lines(ab, context.temp_allocator) {
				f := strings.split(l, "\x00", context.temp_allocator)
				if len(f) < 2 do continue
				for &x in brs do if x.name == f[0] {
					x.ab = f[1]
					x.merged = strings.has_prefix(f[1], "0 ")
				}
			}
		} else if m, mok := git_run(at, "for-each-ref", fmt.tprintf("--merged=%s", def_ref), "--format=%(refname:short)", "refs/heads"); mok {
			for l in strings.split_lines(m, context.temp_allocator) do for &x in brs do if x.name == l do x.merged = true
		}
	}
	line(&b, "R", clean(main) ? main : "", clean(def) ? def : "")
	for w, i in wts {
		if i >= WT_MAX || !clean(w.path) || !clean(w.branch) do continue
		flags := strings.builder_make(context.temp_allocator)
		if i == 0 do strings.write_byte(&flags, 'm')
		if w.detached do strings.write_byte(&flags, 'd')
		if w.bare do strings.write_byte(&flags, 'b')
		if w.locked do strings.write_byte(&flags, 'l')
		if w.prunable do strings.write_byte(&flags, 'p')
		dirty := "-1"
		ahead, behind := "-1", "-1"
		if !w.bare && os.is_dir(w.path) {
			if st, stok := git_run(w.path, "status", "--porcelain=v1", "-z", "--untracked-files=normal"); stok do dirty = fmt.tprint(wt_count_status(st))
		} else if !w.bare {
			strings.write_byte(&flags, 'x') // its folder is gone
		}
		if w.detached && def != "" && w.head != "" {
			// a detached checkout: ahead/behind the default branch
			if c, cok := git_run(at, "rev-list", "--left-right", "--count", fmt.tprintf("refs/heads/%s...%s", def, w.head)); cok {
				f := strings.fields(c, context.temp_allocator)
				if len(f) == 2 do behind, ahead = f[0], f[1]
			}
		}
		line(&b, "W", w.path, w.branch, w.head, strings.to_string(flags), dirty, ahead, behind)
	}
	// branches, most recent first
	slice.sort_by(brs[:], proc(x, y: Br) -> bool {
		a, _ := strconv.parse_i64(x.date)
		c, _ := strconv.parse_i64(y.date)
		if a != c do return a > c
		return x.name < y.name
	})
	n := 0
	for x in brs {
		out_of_tree := true
		for w in wts do if w.branch == x.name do out_of_tree = false
		if out_of_tree {
			if n >= WT_BRANCHES_MAX do continue
			n += 1
		}
		if !clean(x.name) || !clean(x.upstream) || !clean(x.track) do continue
		subject, _ := strings.replace_all(x.subject, "\x1f", " ", context.temp_allocator)
		ahead, behind := "-1", "-1"
		if f := strings.fields(x.ab, context.temp_allocator); len(f) == 2 do ahead, behind = f[0], f[1]
		line(&b, "B", x.name, x.upstream, x.track, x.date, ahead, behind, x.merged ? "1" : "0", subject)
	}
	return strings.to_string(b)
}

// The number of paths in `git status --porcelain=v1 -z` output.
wt_count_status :: proc(out: string) -> int {
	n := 0
	rest := out
	for len(rest) > 3 {
		i := strings.index_byte(rest, 0)
		rec := i < 0 ? rest : rest[:i]
		rest = i < 0 ? "" : rest[i + 1:]
		if len(rec) < 4 do continue
		n += 1
		if rec[0] == 'R' || rec[0] == 'C' { 	// the old name follows
			j := strings.index_byte(rest, 0)
			rest = j < 0 ? "" : rest[j + 1:]
		}
	}
	return n
}

// "ahead 3, behind 1" (git's upstream track) -> 3, 1; "gone" -> gone.
@(private = "file")
wt_track :: proc(track: string) -> (ahead, behind: int, gone: bool) {
	if track == "gone" do return 0, 0, true
	for part in strings.split(track, ",", context.temp_allocator) {
		f := strings.fields(part, context.temp_allocator)
		if len(f) != 2 do continue
		n, _ := strconv.parse_int(f[1])
		if f[0] == "ahead" do ahead = n
		if f[0] == "behind" do behind = n
	}
	return
}

// A worker's scan arrived (main thread). Choices of the Files tree that
// point at a checkout no longer there are dropped (true: state changed).
worktrees_done :: proc(c: Worktrees_Done) -> bool {
	window_state_changed()
	r: ^Wt_Repo
	for x in wt_repos do if x.common == c.common do r = x
	if r == nil do return false
	r.loading = false
	r.ok = c.gen == r.gen // a change since it started: shown, but scanned again when next asked
	r.loaded = true
	virtual.arena_destroy(&r.arena)
	_ = virtual.arena_init_growing(&r.arena)
	a := virtual.arena_allocator(&r.arena)
	r.checkouts = make([dynamic]Wt_Checkout, a)
	r.branches = make([dynamic]Wt_Branch, a)
	r.main, r.default_branch, r.err = "", "", ""
	num :: proc(s: string) -> int {
		n, ok := strconv.parse_int(s)
		return ok ? n : -1
	}
	for l in strings.split_lines(c.out, context.temp_allocator) {
		f := strings.split(l, "\x1f", context.temp_allocator)
		switch f[0] {
		case "E":
			if len(f) > 1 do r.err = strings.clone(f[1], a)
		case "R":
			if len(f) < 3 do continue
			r.main = strings.clone(f[1], a)
			r.default_branch = strings.clone(f[2], a)
		case "W":
			if len(f) < 8 do continue
			fl := f[4]
			append(&r.checkouts, Wt_Checkout{
				path = strings.clone(f[1], a), branch = strings.clone(f[2], a), head = strings.clone(f[3], a),
				main = strings.contains(fl, "m"), detached = strings.contains(fl, "d"), bare = strings.contains(fl, "b"),
				locked = strings.contains(fl, "l"), prunable = strings.contains(fl, "p"), missing = strings.contains(fl, "x"),
				dirty = num(f[5]), ahead = num(f[6]), behind = num(f[7]),
			})
		case "B":
			if len(f) < 9 do continue
			ua, ub, gone := wt_track(f[3])
			date, _ := strconv.parse_i64(f[4])
			append(&r.branches, Wt_Branch{
				name = strings.clone(f[1], a), upstream = strings.clone(f[2], a), gone = gone, up_ahead = ua, up_behind = ub,
				date = date, ahead = num(f[5]), behind = num(f[6]), merged = f[7] == "1", subject = strings.clone(f[8], a),
			})
		}
	}
	// a checkout's branch: its upstream (ahead/behind that) else the default branch's
	for &co in r.checkouts {
		if co.branch == "" do continue
		for &br in r.branches do if br.name == co.branch {
			br.checkout = true
			co.upstream, co.gone, co.merged = br.upstream, br.gone, br.merged && co.branch != r.default_branch
			if br.upstream != "" && !br.gone do co.ahead, co.behind = br.up_ahead, br.up_behind
			else do co.ahead, co.behind = br.ahead, br.behind
		}
	}
	// the Files tree's choices: a checkout of this repository that is gone goes back to its project
	changed := false
	for i := len(state.files.checkouts) - 1; i >= 0; i -= 1 {
		ch := state.files.checkouts[i]
		if wt_where(ch.base).common != r.common do continue
		found := false
		for co in r.checkouts do if co.path == ch.path && !co.missing do found = true
		if found && os.is_dir(ch.path) do continue
		files_checkout_drop(i)
		changed = true
	}
	return changed
}

// ---- reading the model ----

// The checkout of r at path (nil = none).
wt_checkout :: proc(r: ^Wt_Repo, path: string) -> ^Wt_Checkout {
	if r == nil do return nil
	for &c in r.checkouts do if c.path == path do return &c
	return nil
}

// A checkout's place for the switcher: "main checkout" or "worktree".
wt_kind :: proc(c: Wt_Checkout) -> string {return c.main ? "main checkout" : "worktree"}

// What a checkout has on: its branch, else "detached <short id>".
wt_branch_label :: proc(c: Wt_Checkout) -> string {
	if c.branch != "" do return c.branch
	if c.bare do return "bare"
	return fmt.tprintf("detached %s", c.head[:min(len(c.head), 7)])
}

// Whether Clean up applies (the menu offers it; worktree_cleanup checks
// again with git): a linked worktree whose folder is there, on a branch
// merged into the default branch, nothing changed, not locked.
wt_cleanable :: proc(r: ^Wt_Repo, c: Wt_Checkout) -> bool {
	return r != nil && !c.main && !c.bare && !c.missing && !c.prunable && !c.locked && c.branch != "" && c.branch != r.default_branch && c.merged && c.dirty == 0
}

// list_worktrees' data.
wt_json :: proc(base: string, r: ^Wt_Repo) -> string {
	b := strings.builder_make(context.temp_allocator)
	str :: proc(b: ^strings.Builder, k, v: string) {
		fmt.sbprintf(b, `,"%s":`, k)
		json_quote(b, v)
	}
	num :: proc(b: ^strings.Builder, k: string, v: int) {if v >= 0 do fmt.sbprintf(b, `,"%s":%d`, k, v)}
	yes :: proc(b: ^strings.Builder, k: string, v: bool) {if v do fmt.sbprintf(b, `,"%s":true`, k)}
	strings.write_string(&b, `{"base":`)
	json_quote(&b, base)
	str(&b, "root", files_root_for(base))
	fmt.sbprintf(&b, `,"loading":%v`, r.loading || !r.loaded)
	str(&b, "main", r.main)
	str(&b, "default_branch", r.default_branch)
	if r.err != "" do str(&b, "error", r.err)
	strings.write_string(&b, `,"worktrees":[`)
	for c, i in r.checkouts {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"path":`)
		json_quote(&b, c.path)
		if c.branch != "" do str(&b, "branch", c.branch)
		str(&b, "head", c.head)
		yes(&b, "main", c.main)
		yes(&b, "detached", c.detached)
		yes(&b, "bare", c.bare)
		yes(&b, "locked", c.locked)
		yes(&b, "prunable", c.prunable)
		yes(&b, "missing", c.missing)
		num(&b, "dirty", c.dirty)
		if c.upstream != "" do str(&b, "upstream", c.upstream)
		num(&b, "ahead", c.ahead)
		num(&b, "behind", c.behind)
		yes(&b, "merged", c.merged)
		yes(&b, "cleanable", wt_cleanable(r, c))
		if ph := wt_cleanup_phase(c.path); ph != "" do str(&b, "cleanup", ph)
		if e := wt_cleanup_error(c.path); e != "" do str(&b, "cleanup_error", e)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `],"branches":[`)
	n := 0
	for br in r.branches {
		if br.checkout do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		strings.write_string(&b, `{"name":`)
		json_quote(&b, br.name)
		if br.upstream != "" do str(&b, "upstream", br.upstream)
		num(&b, "ahead", br.ahead)
		num(&b, "behind", br.behind)
		yes(&b, "merged", br.merged)
		fmt.sbprintf(&b, `,"date":%d`, max(br.date, 0))
		str(&b, "subject", br.subject)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// ---- commands ----

worktrees_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case List_Worktrees:
		// a pi tab's default is its own session's folder; anyone else's the Files tab's
		base := files_base()
		if caller.kind == .Panel {
			s := caller_session(caller)
			base = s != nil && !s.home ? s.cwd : ""
		}
		if c.path != "" do base = c.path
		if base == "" do return fail("no project: give a path"), false
		p, _, err := fs_check(base, caller, allow_root = true)
		if err != "" do return fail(err), false
		repo := wt_repo_for(p)
		if repo == nil do return fail("not in a git repository"), false
		return {ok = true, data = strings.clone(wt_json(p, repo))}, false
	case Files_Set_Root:
		base := c.base != "" ? fs_real(fs_abs(c.base, caller)) : files_base()
		if base == "" do return fail("no project"), false
		if list_index(fs_base_roots(), base) < 0 do return fail("base must be a project or session folder"), false
		p := c.path != "" ? fs_real(fs_abs(c.path, caller)) : base
		if p == base || p == "" {
			for ch, i in state.files.checkouts do if ch.base == base {
				files_checkout_drop(i)
				files_state_gen += 1
				return {ok = true}, true
			}
			return {ok = true}, false
		}
		if !os.is_dir(p) do return fail("no such folder"), false
		if err := wt_checkout_err(base, p, listed = caller.kind != .Internal); err != "" do return fail(err), false
		return {ok = true}, files_checkout_set(base, p)
	case Worktree_Session:
		// commands.odin starts it (open_new_session); the checks are here
		return fail("unknown command"), false
	case Worktree_Cleanup:
		if caller.kind != .UI do return fail("only the user can clean up a worktree, in Deckhand"), false
		p := fs_real(fs_abs(c.path, caller))
		main, err := wt_cleanup_pre(p)
		if err != "" do return fail(err), false
		ch := false
		if c.confirm != "" {
			// confirmed: the token is used up here, git checks again on the worker before removing
			gr, go_on, gch := confirm_gate(Worktree_Cleanup{path = p}, .Delete, caller, c.confirm, "")
			if !go_on do return gr, gch
			ch = gch
		}
		wt_cleanup_start(p, main, request_id, remove = c.confirm != "")
		return {ok = true, pending = true}, ch
	case Worktree_Cleanup_Done:
		return wt_cleanup_done(c)
	case Worktrees_Done:
		return {ok = true}, worktrees_done(c)
	}
	return fail("unknown command"), false
}

// Whether worktree_session may start in path for project p: a checkout of
// its repository ("" = yes). listed: one the last scan listed (see
// wt_checkout_err).
wt_session_check :: proc(p: ^Project, path: string, listed: bool) -> (abs: string, err: string) {
	if p == nil do return "", "no such project"
	if p.group == .Chats do return "", CHATS_NOT_A_PROJECT
	a := fs_real(path)
	if a == "" || !os.is_dir(a) do return "", "no such folder"
	if e := wt_checkout_err(p.cwd, a, listed); e != "" do return "", e
	return a, ""
}

// ---- clean up (worktree_cleanup) ----

Wt_Busy :: enum u8 {
	Checking, // git's checks run on a worker
	Removing, // git worktree remove, then git branch -d
}

// Clean ups in flight and why the last one of a path stopped, by path
// (owned keys and values). UI state: the switcher's rows show them.
@(private = "file")
wt_busy: map[string]Wt_Busy
@(private = "file")
wt_errors: map[string]string

// Internal: a clean up's worker finished (its checks, or the removal).
Worktree_Cleanup_Done :: struct {
	path:       string,
	main:       string,
	request_id: u64,
	remove:     bool, // the removal ran (else only the checks)
	removed:    bool, // the worktree is gone (the branch may not be)
	branch:     string,
	ignored:    string, // the checks: "N ignored paths (a/, b/ …)" ("" = none)
	err:        string,
}

// Whether a clean up of path is being checked or run on a worker.
wt_cleanup_busy :: proc(path: string) -> bool {return path in wt_busy}

// A clean up in flight for path: "checking", "removing" ("" = none).
wt_cleanup_phase :: proc(path: string) -> string {
	b, ok := wt_busy[path]
	if !ok do return ""
	return b == .Checking ? "checking" : "removing"
}

// Why the last clean up of path stopped ("" = none).
wt_cleanup_error :: proc(path: string) -> string {return wt_errors[path] or_else ""}

@(private = "file")
wt_set_error :: proc(path, err: string) {
	if path in wt_errors {
		k, v := delete_key(&wt_errors, path)
		delete(k)
		delete(v)
	}
	if err != "" do wt_errors[strings.clone(path)] = strings.clone(err)
}

// The checks that need no git (main thread): a linked worktree of a known
// project's repository that the last scan listed, its folder there, no
// open session, shell or unsaved editor tab in it, no clean up running.
wt_cleanup_pre :: proc(p: string) -> (main, err: string) {
	if p == "" || !os.is_dir(p) do return "", "no such folder"
	w := wt_where(p)
	if w.common == "" || w.top != p do return "", "not a git checkout"
	if !w.linked do return "", "the main checkout is never removed"
	if !wt_known_checkout(p) do return "", "not a worktree of a known project"
	main = filepath.base(w.common) == ".git" ? filepath.dir(w.common) : ""
	if main == "" || !os.is_dir(main) do return "", "no main checkout to run git in"
	if wt_cleanup_busy(p) do return "", "a clean up of it is running"
	for s in state.open_sessions {
		if s.home do continue
		if wt_within(fs_real(s.cwd), p) do return "", "a session runs in it"
		for tab in s.tabs do if _, is := tab.kind.(Shell_Tab); is && tab.cwd != "" && wt_within(fs_real(tab.cwd), p) do return "", "a shell tab runs in it"
	}
	unsaved, known := window_unsaved_files(p)
	if !known do return "", "no window can say whether an editor tab has unsaved changes in it" // never taken as none
	if unsaved > 0 do return "", "an editor tab has unsaved changes in it"
	return main, ""
}

// Runs the git checks (and with remove, the removal) on a worker; the
// result comes back as Worktree_Cleanup_Done.
@(private = "file")
wt_cleanup_start :: proc(p, main: string, request_id: u64, remove: bool) {
	wt_set_error(p, "")
	wt_busy[strings.clone(p)] = remove ? .Removing : .Checking
	window_state_changed()
	Job :: struct {
		path, main: string,
		request_id: u64,
		remove:     bool,
	}
	h := runtime.heap_allocator()
	job := new_clone(Job{strings.clone(p, h), strings.clone(main, h), request_id, remove}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		d := Worktree_Cleanup_Done{path = job.path, main = job.main, request_id = job.request_id, remove = job.remove}
		d.branch, d.ignored, d.err = wt_cleanup_git(job.path, job.main)
		if d.err == "" && job.remove {
			if _, ok := git_run_for(job.main, WT_REMOVE_TIMEOUT, "worktree", "remove", job.path); !ok {
				d.err = "git worktree remove refused (changed or untracked files?)"
			} else {
				d.removed = true
				if _, bok := git_run(job.main, "branch", "-d", d.branch); !bok {
					d.err = fmt.tprintf("the worktree is removed; git branch -d %s refused (not merged into the main checkout's branch?)", d.branch)
				}
			}
		}
		inbox_submit(d, {kind = .Internal}) // copied
		delete(job.path, h)
		delete(job.main, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// A clean up's worker finished (main thread): after the checks the
// confirmation is parked (the user's, in the confirmation bar); after the
// removal the model is read again.
@(private = "file")
wt_cleanup_done :: proc(c: Worktree_Cleanup_Done) -> (r: Result, changed: bool) {
	if c.path in wt_busy {
		k, _ := delete_key(&wt_busy, c.path)
		delete(k)
	}
	window_state_changed()
	if c.removed {
		fs_model_changed(c.path)
		wt_stale(c.main)
		changed = true
	}
	if c.err != "" {
		wt_set_error(c.path, c.err)
		r = fail(c.err)
	} else if !c.remove {
		what := fmt.tprintf("Remove worktree %s and delete merged branch %s?", fs_display(c.path), c.branch)
		if c.ignored != "" do what = fmt.tprintf("%s It also deletes %s.", what, c.ignored)
		gr, _, gch := confirm_gate(Worktree_Cleanup{path = c.path}, .Delete, {kind = .UI}, "", what)
		r = gr
		changed ||= gch
	} else {
		r = {ok = true}
	}
	emit_event(Finished_Event{request_id = c.request_id, result = r})
	return {ok = true}, changed
}

// Clean up's git checks (any thread): on a branch other than the default
// one and merged into it, not locked, nothing changed or untracked, no
// ignored file that looks like a secret (.env, keys); the ignored paths
// that go with it, for the question.
wt_cleanup_git :: proc(p, main: string) -> (branch, ignored, err: string) {
	head, hok := git_run(p, "symbolic-ref", "-q", "--short", "HEAD")
	branch = strings.trim_space(head)
	if !hok || branch == "" do return "", "", "detached HEAD: no branch to delete"
	def := wt_default_branch(main)
	if def == "" do return "", "", "no default branch to compare with"
	if branch == def do return "", "", "the default branch is never deleted"
	if gd, gok := git_run(p, "rev-parse", "--absolute-git-dir"); gok && os.exists(strings.concatenate({strings.trim_space(gd), "/locked"}, context.temp_allocator)) {
		return "", "", "the worktree is locked"
	}
	st, sok := git_run(p, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored=matching")
	if !sok do return "", "", "git status failed"
	paths := make([dynamic]string, context.temp_allocator)
	changed := 0
	rest := st
	for len(rest) > 3 {
		i := strings.index_byte(rest, 0)
		rec := i < 0 ? rest : rest[:i]
		rest = i < 0 ? "" : rest[i + 1:]
		if len(rec) < 4 do continue
		if rec[:2] == "!!" {
			append(&paths, rec[3:])
			continue
		}
		changed += 1
		if rec[0] == 'R' || rec[0] == 'C' {
			j := strings.index_byte(rest, 0)
			rest = j < 0 ? "" : rest[j + 1:]
		}
	}
	if changed > 0 do return "", "", "it has changed or untracked files"
	if _, mok := git_run(main, "merge-base", "--is-ancestor", strings.concatenate({"refs/heads/", branch}, context.temp_allocator), strings.concatenate({"refs/heads/", def}, context.temp_allocator)); !mok {
		return "", "", fmt.tprintf("%s is not merged into %s", branch, def)
	}
	// ignored files go with the folder: never one that looks like a secret
	seen := 0
	for ip in paths {
		full := strings.concatenate({p, "/", strings.trim_suffix(ip, "/")}, context.temp_allocator)
		if name, found, over := wt_find_secret(full, &seen); found {
			return "", "", fmt.tprintf("it holds an ignored file that may be a secret (%s): remove the worktree by hand", name)
		} else if over {
			return "", "", "too many ignored files to check for secrets: remove the worktree by hand"
		}
	}
	if len(paths) > 0 {
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "%d ignored %s (", len(paths), len(paths) == 1 ? "path" : "paths")
		for ip, i in paths[:min(len(paths), 3)] {
			if i > 0 do strings.write_string(&b, ", ")
			strings.write_string(&b, ip)
		}
		strings.write_string(&b, len(paths) > 3 ? " …)" : ")")
		ignored = strings.to_string(b)
	}
	return branch, ignored, ""
}

WT_SECRET_WALK_MAX :: 100_000 // entries looked at in ignored folders (node_modules/ skipped)

// Whether the name looks like a secret: .env files, keys, credentials.
wt_secret_name :: proc(name: string) -> bool {
	n := strings.to_lower(name, context.temp_allocator)
	if strings.has_prefix(n, ".env") || strings.contains(n, "secret") || strings.contains(n, "credential") do return true
	if strings.has_prefix(n, "id_rsa") || strings.has_prefix(n, "id_ed25519") || strings.has_prefix(n, "id_ecdsa") do return true
	for ext in ([]string{".pem", ".key", ".p12", ".pfx", ".keystore", ".jks"}) do if strings.has_suffix(n, ext) do return true
	for f in ([]string{".npmrc", ".netrc", ".pypirc", "auth.json", ".htpasswd"}) do if n == f do return true
	return false
}

// A secret-looking file at or below path (an ignored path), links not
// followed; over: the walk hit WT_SECRET_WALK_MAX.
@(private = "file")
wt_find_secret :: proc(path: string, seen: ^int) -> (name: string, found, over: bool) {
	base := filepath.base(path)
	if wt_secret_name(base) do return base, true, false
	fi, err := os.lstat(path, context.temp_allocator)
	if err != nil || fi.type != .Directory || base == "node_modules" do return "", false, false
	infos, rerr := os.read_all_directory_by_path(path, context.temp_allocator)
	if rerr != nil do return "", false, false
	for e in infos {
		seen^ += 1
		if seen^ > WT_SECRET_WALK_MAX do return "", false, true
		if n, f, o := wt_find_secret(e.fullpath, seen); f || o do return n, f, o
	}
	return "", false, false
}

// Git in dir with a longer timeout (git_run's flags).
git_run_for :: proc(dir: string, timeout: time.Duration, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	flags := GIT_FLAGS
	append(&cmd, ..flags[:])
	append(&cmd, "-C", dir)
	append(&cmd, ..args)
	return run_bounded("", cmd[:], timeout)
}

// The default branch, as the scan picks it: origin's HEAD if it is a local
// branch, else main or master, else the main checkout's ("" = none). Runs git (bounded).
wt_default_branch :: proc(main: string) -> string {
	local :: proc(main, name: string) -> bool {
		_, ok := git_run(main, "show-ref", "--verify", "-q", strings.concatenate({"refs/heads/", name}, context.temp_allocator))
		return ok
	}
	if o, ok := git_run(main, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"); ok {
		if d := strings.trim_prefix(strings.trim_space(o), "origin/"); d != "" && local(main, d) do return d
	}
	for c in ([]string{"main", "master"}) do if local(main, c) do return c
	if o, ok := git_run(main, "symbolic-ref", "-q", "--short", "HEAD"); ok do return strings.trim_space(o) // the main checkout's
	return ""
}
