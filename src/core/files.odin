package core

// The Files tab's model: commands that change which folders are expanded
// (State.files, saved per tree root), and the tree itself, built lazily
// from directory listings (fs_read_dir) that are cached per folder until
// the watcher reports a change there. The tree's rows are one flat list
// (expanded folders' entries inline), rebuilt only when the expansion, a
// listing or the filter changed; ui_files.odin draws only the visible rows.
//
// The tree's root is the folder of the session on screen, else the
// selected project's (Chats: the chats folder). Git codes are looked up as
// rows are drawn (fs_git_code_cached), so a git status that arrives later
// recolours the rows without a rebuild.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

Set_Left_Tab :: struct {
	tab: Left_Tab,
}
// Expands or collapses a folder in its tree (collapsing keeps the folders
// below expanded for the next time, as file managers do).
Files_Expand :: struct {
	path:     string,
	expanded: bool,
}
// Collapses every folder of a tree.
Files_Collapse_All :: struct {
	root: string,
}
// Expands the folders above path and selects its row.
Files_Reveal :: struct {
	path: string,
}
Set_Files_Filter :: struct {
	text: string,
}

LEFT_TAB_NAMES := [Left_Tab]string {
	.Sessions = "sessions",
	.Files    = "files",
	.Settings = "settings",
	.Jobs     = "jobs",
}

FILES_DIR_MAX :: 20_000 // entries shown per folder; the rest is one "N more…" row
FILES_ROWS_MAX :: 200_000 // rows in the whole tree
FILES_FILTER_MAX :: 500 // filter matches shown

// Bumped by every change to State.files: the rows are rebuilt.
files_state_gen: u64

// ---- commands ----

files_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Set_Left_Tab:
		if state.layout.left_tab == c.tab && state.layout.left_open do return {ok = true}, false
		if state.layout.left_tab != .Sessions && c.tab != .Sessions && state.layout.left_tab != c.tab && state.files.filter != "" {
			// between the two trees the filter starts over: it was typed for the other one (they share the field)
			delete(state.files.filter)
			state.files.filter = ""
			files_state_gen += 1
		}
		state.layout.left_tab = c.tab
		state.layout.left_open = true // the tab must show
		return {ok = true}, true
	case Set_Files_Filter:
		text := one_line(c.text, context.temp_allocator)
		if len(text) > FILTER_MAX do return fail("filter text too long (max 200 bytes)"), false
		if text == state.files.filter do return {ok = true}, false
		delete(state.files.filter)
		state.files.filter = strings.clone(text)
		files_state_gen += 1
		return {ok = true}, true
	case Files_Expand:
		// keyed by the path as the tree shows it: a symlinked folder opens in
		// place (fs_check would follow the link, out of the project or onto
		// the folder it points at), and a known folder inside the tree (a
		// nested project, a session's worktree) opens in its parent's tree
		p := fs_abs(c.path, caller)
		if p == "" do return fail("path is empty (or relative with no project selected)"), false
		if caller.kind != .UI {
			// the control socket and scripts keep the real-path boundary: only
			// the user's own clicks follow a symlinked folder out of the project
			if _, _, err := files_tree_check(c.path, caller); err != "" do return fail(err), false
		}
		root, rel := files_expand_key(p)
		if root == "" {
			_, _, err := files_tree_check(c.path, caller)
			if err != "" do return fail(err), false
			if !c.expanded do return fail("a tree's root is always open"), false
			return {ok = true}, false // already open: a tree's root always is
		}
		if strings.contains(strings.concatenate({"/", rel, "/"}, context.temp_allocator), "/.git/") do return fail("not inside .git"), false
		if c.expanded && path_kind(p) != .Dir do return fail("not a folder"), false
		if !files_set_expanded(root, rel, c.expanded) do return {ok = true}, false
		return {ok = true}, true
	case Files_Collapse_All:
		_, root, err := files_tree_check(c.root, caller)
		if err != "" do return fail(err), false
		for &fr in state.files.expanded do if fr.root == root {
			if len(fr.dirs) == 0 do return {ok = true}, false
			for d in fr.dirs do delete(d)
			clear(&fr.dirs)
			files_state_gen += 1
			return {ok = true}, true
		}
		return {ok = true}, false
	case Files_Reveal:
		p, _, err := fs_check(c.path, caller, allow_root = true)
		if err != "" do return fail(err), false
		// every folder above it opens, up to the outermost known folder
		// (a nested project's folder opens in its parent's tree too)
		above := make([dynamic]string, context.temp_allocator)
		for d := filepath.dir(p); len(d) > 1; d = filepath.dir(d) {
			if root, _ := files_expand_key(d); root == "" do break
			append(&above, d)
		}
		ch := false
		#reverse for d in above { 	// outermost first: the saved order is the order they opened
			root, rel := files_expand_key(d)
			if files_set_expanded(root, rel, true) do ch = true
		}
		files_select(p) // the row the keyboard moves from (UI state)
		return {ok = true}, ch
	}
	return fail("unknown command"), false
}

// A folder of a tree (Files_Expand, Files_Collapse_All): its absolute path
// and the root its open state is kept under. A project's (fs_check, the
// innermost known folder), else for any caller but a pi tab's bridge one
// of the Settings tab's folders in pi's agent folder (settings_tree_root,
// as written: prompts/, skills/, extensions/ and below).
files_tree_check :: proc(path: string, caller: Caller) -> (abs, root, err: string) {
	p, _, e := fs_check(path, caller, allow_root = true)
	if e == "" do return p, fs_root_longest(p), ""
	if caller.kind != .Panel {
		a := fs_abs(path, caller)
		if r := settings_tree_root(a); r != "" do return a, r, ""
	}
	return "", "", e
}

// Where Files_Expand keeps an absolute path's open state: (root, rel),
// root "" = nowhere (outside every tree, or a tree's root itself). The root
// is the innermost known folder strictly above the path as written, so a
// row's own path (the tree's root, then names: below a symlinked folder
// too) finds its state without resolving links. A path written another way
// (/tmp for /private/tmp) is tried with its parent's real path.
files_expand_key :: proc(path: string) -> (root, rel: string) {
	p, _ := filepath.clean(path, context.temp_allocator)
	if r := fs_root_above(p); r != "" do return r, p[len(r) + 1:]
	full := strings.concatenate({fs_real(filepath.dir(p)), "/", filepath.base(p)}, context.temp_allocator)
	if r := fs_root_above(full); r != "" do return r, full[len(r) + 1:]
	if r := settings_tree_root(p); r != "" && r != p do return r, p[len(r) + 1:]
	return "", ""
}

// Whether a folder shows open (any tree).
files_is_open :: proc(path: string) -> bool {
	root, rel := files_expand_key(path)
	return root != "" && list_index(files_expanded_dirs(root), rel) >= 0
}

// Adds or removes rel in root's expanded list; true if it changed. The
// root moves to the front (most recently used); past FILES_ROOTS_MAX the
// last one goes, past FILES_EXPANDED_MAX a root's oldest folder.
@(private = "file")
files_set_expanded :: proc(root, rel: string, on: bool) -> bool {
	at := -1
	for fr, i in state.files.expanded do if fr.root == root do at = i
	if at < 0 {
		if !on do return false
		inject_at(&state.files.expanded, 0, Files_Root{root = strings.clone(root)})
		at = 0
		if len(state.files.expanded) > FILES_ROOTS_MAX {
			last := pop(&state.files.expanded)
			for d in last.dirs do delete(d)
			delete(last.dirs)
			delete(last.root)
		}
	} else if at > 0 {
		fr := state.files.expanded[at]
		ordered_remove(&state.files.expanded, at)
		inject_at(&state.files.expanded, 0, fr)
		at = 0
	}
	fr := &state.files.expanded[at]
	i := list_index(fr.dirs[:], rel)
	if on == (i >= 0) do return false
	if on {
		if len(fr.dirs) >= FILES_EXPANDED_MAX {
			delete(fr.dirs[0])
			ordered_remove(&fr.dirs, 0)
		}
		append(&fr.dirs, strings.clone(rel))
	} else {
		delete(fr.dirs[i])
		ordered_remove(&fr.dirs, i)
	}
	files_state_gen += 1
	return true
}

// A file or folder moved (rename_path): expanded folders at or below it
// follow, within the same tree; so does the selection.
files_renamed :: proc(from, to: string) {
	root := fs_root_longest(from)
	if root != "" && root == fs_root_longest(to) && from != root && to != root do files_renamed_in(root, from, to)
	else if r := settings_tree_root(from); r != "" && r == settings_tree_root(to) do files_renamed_in(r, from, to)
	for v in ([]^Files_View{&files_ui, &settings_ui}) {
		if v.cursor == from || strings.has_prefix(v.cursor, strings.concatenate({from, "/"}, context.temp_allocator)) {
			files_select_in(v, strings.concatenate({to, v.cursor[len(from):]}, context.temp_allocator))
			v.reveal = false
		}
	}
}

@(private = "file")
files_renamed_in :: proc(root, from, to: string) {
	rf, rt := from[len(root) + 1:], to[len(root) + 1:]
	for &fr in state.files.expanded do if fr.root == root {
		for &d in fr.dirs {
			if d != rf && !(strings.has_prefix(d, rf) && d[len(rf)] == '/') do continue
			nd := strings.concatenate({rt, d[len(rf):]})
			delete(d)
			d = nd
			files_state_gen += 1
		}
	}
}

// The expanded folders of a tree root (relative paths; nil = none).
files_expanded_dirs :: proc(root: string) -> []string {
	for fr in state.files.expanded do if fr.root == root do return fr.dirs[:]
	return nil
}

// ---- the tree's root ----

// The folder the Files tab is for: the session on screen's, else the
// selected project's ("" = none). Real path.
files_base :: proc() -> string {
	if cs := cur(); cs != nil && !cs.home && cs.cwd != "" do return fs_real(cs.cwd)
	if p := find_project(state.selected_project); p != nil && p.machine == 0 do return fs_real(p.cwd) // another machine's folder is not this Mac's
	return ""
}

// The folder the Files tab shows: the checkout picked for its project
// (files_set_root) while that folder is there, else the project's own.
files_root :: proc() -> string {return files_root_for(files_base())}

files_root_for :: proc(base: string) -> string {
	for c in state.files.checkouts do if c.base == base && os.is_dir(c.path) do return c.path
	return base
}

// The Files tree of base shows path (a checkout of its repository; the
// caller checked). True if it changed.
files_checkout_set :: proc(base, path: string) -> bool {
	for c, i in state.files.checkouts do if c.base == base {
		if c.path == path && i == 0 do return false
		files_checkout_drop(i)
		break
	}
	inject_at(&state.files.checkouts, 0, Files_Checkout{strings.clone(base), strings.clone(path)})
	if len(state.files.checkouts) > FILES_ROOTS_MAX do files_checkout_drop(len(state.files.checkouts) - 1)
	files_state_gen += 1
	return true
}

files_checkout_drop :: proc(i: int) {
	c := state.files.checkouts[i]
	delete(c.base)
	delete(c.path)
	ordered_remove(&state.files.checkouts, i)
	files_state_gen += 1
}

// ---- listings (cached per folder) ----

Files_Dir :: struct {
	entries: [dynamic]Fs_Entry, // names owned
	err:     string, // owned; "" = listed
	stale:   bool, // something changed in it: listed again when next needed
	ignored: bool, // listed as ignored (inside an ignored folder)
	real:    string, // owned; the folder's real path where it differs (below a symlinked folder): changes come by it
}

@(private = "file")
files_cache: map[string]^Files_Dir // folder (abs, owned key) -> its listing
@(private = "file")
walked: map[string]bool // folders the last rebuild listed (keys borrowed from files_cache)

@(private = "file")
walk_roots: []string // the known folders, while files_rows walks (temp allocator)

// Bumped whenever a listing is (re)loaded or marked stale.
files_cache_gen: u64

// The listing of dir, loaded (or reloaded when stale) now.
files_dir :: proc(dir: string, ignored: bool) -> ^Files_Dir {
	d := files_cache[dir]
	if d != nil && !d.stale && d.ignored == ignored do return d
	if d == nil {
		d = new(Files_Dir)
		files_cache[strings.clone(dir)] = d
	}
	files_dir_clear(d)
	d.stale, d.ignored = false, ignored
	fs_stats.relists += 1
	t0 := time.tick_now()
	entries, err := fs_read_dir(dir, with_ignored = true, parent_ignored = ignored, for_user = true)
	if autotest_active && time.tick_since(t0) > 20 * time.Millisecond do fmt.eprintf("FILES listed %s: %d entries in %.1f ms\n", dir, len(entries), time.duration_milliseconds(time.tick_since(t0)))
	if err != "" do d.err = strings.clone(err)
	if r := fs_real(dir); r != dir do d.real = strings.clone(r)
	reserve(&d.entries, len(entries))
	for e in entries do append(&d.entries, Fs_Entry{name = strings.clone(e.name), kind = e.kind, ignored = e.ignored})
	files_cache_gen += 1
	return d
}

@(private = "file")
files_dir_clear :: proc(d: ^Files_Dir) {
	for e in d.entries do delete(e.name)
	clear(&d.entries)
	delete(d.err)
	d.err = ""
	delete(d.real)
	d.real = ""
}

// Something changed at path (the watcher, or a file command): its folder's
// listing (and its own, for a folder) is read again when next needed. A
// changed .gitignore can change what is ignored anywhere below it.
files_path_changed :: proc(path: string) {
	if len(files_cache) == 0 do return
	dir := filepath.dir(path)
	gitignore := filepath.base(path) == ".gitignore"
	below := strings.concatenate({dir, "/"}, context.temp_allocator)
	hit :: proc(k, path, dir, below: string, gitignore: bool) -> bool {
		return k == path || k == dir || (gitignore && strings.has_prefix(k, below))
	}
	for k, d in files_cache {
		if d.stale do continue
		// by the path the tree shows, or by its real path (a folder open below a symlink)
		if hit(k, path, dir, below, gitignore) || (d.real != "" && hit(d.real, path, dir, below, gitignore)) {
			d.stale = true
			files_cache_gen += 1
		}
	}
}

// Drops every cached listing (Refresh).
files_refresh :: proc() {
	for k, d in files_cache {
		files_dir_clear(d)
		delete(d.entries)
		free(d)
		delete(k)
	}
	clear(&files_cache)
	files_cache_gen += 1
	delete(files_ui.repo_checked)
	files_ui.repo_checked = ""
	wt_refresh() // worktrees and branches are read again too
}

// ---- rows ----

Files_Row :: struct {
	path:     string, // absolute (view arena)
	name:     string,
	depth:    int, // 0 = in the root
	kind:     Fs_Kind,
	ignored:  bool,
	expanded: bool, // a folder shown open
	more:     int, // > 0: an "N more…" row standing for that many entries
	rel:      string, // filter results: the path relative to the root
	// the Settings tab's rows (settings_tree_rows)
	head:     bool, // a group's heading (name), not a file
	missing:  bool, // not there yet: shown dimmed with a Create button
	note:     string, // what the file is, beside its name
	button:   string, // a row that is a setting, not a file (path ATLAS_MODEL_ROW): its button's label
	reset:    bool, // a folder row (folders.odin): Reset and Reveal in Finder buttons too
	reveal:   bool,
	remove:   bool, // a Claude account's row (claude_accounts.odin): a Remove button
	make_default: bool, // a Claude account's row: a Make default button
	error:    string, // a folder that could not be listed (path): why, with a Retry button
}

Files_View :: struct {
	arena:        virtual.Arena,
	root:         string, // what the rows are for (arena)
	rows:         [dynamic]Files_Row,
	state_gen:    u64,
	cache_gen:    u64,
	files_list:   rawptr, // filter mode: the project file list the results are from
	built:        bool,
	repo_checked: string, // the root whose repository was registered (owned)
	// UI state (ui_files.odin)
	cursor:       string, // selected row's path (owned)
	scroll:       f32, // logical px from the top of the rows
	reveal:       bool, // scroll the cursor into view at the next layout
	active_file:  string, // the editor file last revealed (owned)
}
files_ui: Files_View
settings_ui: Files_View // the Settings tab's tree (rows: settings_tree_rows)

// The view of the tree the left column shows (Files, else Settings).
tree_view :: proc() -> ^Files_View {return state.layout.left_tab == .Settings ? &settings_ui : &files_ui}

// The rows of the tree the left column shows.
tree_rows :: proc() -> []Files_Row {
	if state.layout.left_tab == .Settings do return settings_tree_rows()
	return files_rows(files_root())
}

// Moves the Files tab's selection to path (and scrolls it into view at the next layout).
files_select :: proc(path: string) {files_select_in(&files_ui, path)}

files_select_in :: proc(v: ^Files_View, path: string) {
	if v.cursor != path {
		delete(v.cursor)
		v.cursor = strings.clone(path)
	}
	v.reveal = true
	window_state_changed()
}

// The rows of the tree at root, rebuilt if anything they show changed.
files_rows :: proc(root: string) -> []Files_Row {
	if root == "" do return nil
	files_list: rawptr
	if state.files.filter != "" do files_list = raw_data(fs_project_files(root))
	if files_ui.built && files_ui.root == root && files_ui.state_gen == files_state_gen && files_ui.cache_gen == files_cache_gen && files_ui.files_list == files_list do return files_ui.rows[:]
	if files_ui.repo_checked != root {
		// the repository's status, once per root (git runs once here; codes come from a worker)
		fs_git_repo(root)
		delete(files_ui.repo_checked)
		files_ui.repo_checked = strings.clone(root)
	}
	virtual.arena_destroy(&files_ui.arena)
	_ = virtual.arena_init_growing(&files_ui.arena)
	a := virtual.arena_allocator(&files_ui.arena)
	files_ui.rows = make([dynamic]Files_Row, a)
	files_ui.root = strings.clone(root, a)
	if state.files.filter != "" {
		files_filter_rows(root, a)
	} else {
		open := make(map[string]bool, context.temp_allocator)
		for d in files_expanded_dirs(root) do open[d] = true
		walk_roots = fs_roots() // once per rebuild (realpath per project)
		files_walk(&files_ui, root, "", 0, false, open, a)
		walk_roots = nil
		// listings of folders no longer shown are dropped: memory follows what is open
		drop := make([dynamic]string, context.temp_allocator)
		for k, _ in files_cache do if !(k in walked) do append(&drop, k)
		for k in drop {
			key, d := delete_key(&files_cache, k)
			files_dir_clear(d)
			delete(d.entries)
			free(d)
			delete(key)
		}
		clear(&walked)
	}
	// listing may have bumped the cache gen: these rows are current for it
	files_ui.state_gen, files_ui.cache_gen, files_ui.files_list, files_ui.built = files_state_gen, files_cache_gen, files_list, true
	return files_ui.rows[:]
}

// Appends dir's entries (and open folders' below them) to v's rows. The
// Settings tab's tree (settings): credential files are left out
// (settings_hidden) and a folder's open state is looked up by its path
// (files_is_open), as its folders live in more than one tree root.
files_walk :: proc(v: ^Files_View, dir, rel: string, depth: int, ignored: bool, open: map[string]bool, a: runtime.Allocator, settings := false) {
	d := files_dir(dir, ignored)
	walked[dir] = true
	if d.err != "" {
		// never an empty-looking folder: why, and a Retry (ui_files.odin)
		append(&v.rows, Files_Row{path = strings.clone(dir, a), depth = depth, error = strings.clone(d.err, a)})
		return
	}
	shown := 0
	for e, i in d.entries {
		if len(v.rows) >= FILES_ROWS_MAX || shown >= FILES_DIR_MAX {
			append(&v.rows, Files_Row{path = strings.clone(dir, a), depth = depth, more = len(d.entries) - i})
			return
		}
		full := strings.concatenate({dir, "/", e.name}, a)
		if settings && settings_hidden(full) do continue
		shown += 1
		r := rel == "" ? e.name : strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		is_open := e.kind == .Dir && (settings ? files_is_open(full) : r in open)
		append(&v.rows, Files_Row{path = full, name = full[len(dir) + 1:], depth = depth, kind = e.kind, ignored = e.ignored, expanded = is_open})
		if !is_open do continue
		if !settings && list_index(walk_roots, full) >= 0 {
			// a known folder (nested project, session worktree): the state of
			// the folders below it is kept under it (files_expand_key)
			sub := make(map[string]bool, context.temp_allocator)
			for x in files_expanded_dirs(full) do sub[x] = true
			files_walk(v, full, "", depth + 1, e.ignored, sub, a, settings)
		} else {
			files_walk(v, full, r, depth + 1, e.ignored, open, a, settings)
		}
	}
}

// The settings tree was built: the walked set starts over (the Files tab's
// rebuild drops listings it did not walk, these included).
files_walk_done :: proc() {clear(&walked)}

// The folders whose listings are cached at or below dir.
files_cached_dirs :: proc(dir: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	prefix := strings.concatenate({dir, "/"}, context.temp_allocator)
	for k, _ in files_cache do if k == dir || strings.has_prefix(k, prefix) do append(&out, k)
	return out[:]
}

// Filter mode: the project's files (git's list, ignored ones left out)
// whose path matches every word, best first, flat.
@(private = "file")
files_filter_rows :: proc(root: string, a: runtime.Allocator) {
	files := fs_project_files(root)
	words := strings.fields(state.files.filter, context.temp_allocator)
	Hit :: struct {
		i, score: int,
	}
	hits := make([dynamic]Hit, context.temp_allocator)
	for f, i in files {
		total := 0
		ok := true
		name := filepath.base(f)
		for w in words {
			if s, _, hit := fuzzy_score(w, name); hit {
				total += 2 * s
				continue
			}
			s, _, hit := fuzzy_score(w, f)
			if !hit {
				ok = false
				break
			}
			total += s
		}
		if ok do append(&hits, Hit{i, total})
	}
	slice.sort_by(hits[:], proc(x, y: Hit) -> bool {
		if x.score != y.score do return x.score > y.score
		return x.i < y.i
	})
	for h, n in hits {
		if n >= FILES_FILTER_MAX {
			append(&files_ui.rows, Files_Row{path = strings.clone(root, a), more = len(hits) - n})
			break
		}
		rel := files[h.i]
		full := strings.concatenate({root, "/", rel}, a)
		append(&files_ui.rows, Files_Row{path = full, name = full[len(full) - len(filepath.base(rel)):], rel = full[len(root) + 1:], kind = .File})
	}
}

// The row index of path (-1 = not shown).
files_row_of :: proc(rows: []Files_Row, path: string) -> int {
	for r, i in rows do if r.more == 0 && r.error == "" && r.path == path do return i
	return -1
}

// The row of path's nearest shown folder above it, for a path not shown.
files_parent_row :: proc(rows: []Files_Row, path: string) -> int {
	for p := filepath.dir(path); len(p) > 1; p = filepath.dir(p) {
		if i := files_row_of(rows, p); i >= 0 do return i
	}
	return -1
}

// "M", "A", "U", "D", "R", "!" for a porcelain code (and the folder mark "•").
files_git_letter :: proc(code: string, is_dir: bool) -> string {
	if code == "" do return ""
	if is_dir do return code == "??" ? "U" : "•"
	if code == "??" do return "U"
	x, y := code[0], len(code) > 1 ? code[1] : ' '
	if x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D') do return "!"
	if x == 'D' || y == 'D' do return "D"
	if x == 'R' do return "R"
	if x == 'A' do return "A"
	return "M"
}

// A short description of a tree for logs and tests: one line per row,
// indented two spaces per level, with "/" after open folders; the Settings
// tab's headings in brackets, files not there yet with " (create)".
files_rows_text :: proc(rows: []Files_Row) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in rows {
		for _ in 0 ..< r.depth do strings.write_string(&b, "  ")
		if r.error != "" do fmt.sbprintf(&b, "! %s", r.error)
		else if r.more > 0 do fmt.sbprintf(&b, "%d more…", r.more)
		else if r.head do fmt.sbprintf(&b, "[%s]", r.name)
		else if r.rel != "" do strings.write_string(&b, r.rel)
		else do strings.write_string(&b, r.name)
		if r.expanded do strings.write_byte(&b, '/')
		if r.missing do strings.write_string(&b, " (create)")
		if r.button != "" do fmt.sbprintf(&b, ": %s [%s]", r.note, r.button)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// Virtualisation: the rows [first, last) that a viewport of view_h shows at
// scroll (all logical px), with scroll clamped to the list. Only these rows
// are laid out, whatever the tree's size.
files_visible :: proc(n: int, scroll, view_h, row_h: f32) -> (first, last: int, clamped: f32) {
	if n <= 0 || row_h <= 0 do return 0, 0, 0
	clamped = clamp(scroll, 0, max(f32(n) * row_h - view_h, 0))
	first = clamp(int(clamped / row_h), 0, n)
	last = clamp(int((clamped + view_h) / row_h) + 1, first, n)
	return
}

// An edited preview tab is kept (editing makes it an ordinary tab, as a
// double-click does). Main thread, every frame (editor_tick): cheap.
files_keep_edited_preview :: proc() {
	for s in state.open_sessions do for tab in s.tabs {
		et, is := tab.kind.(Editor_Tab)
		if dirty, _ := window_tab_dirty(tab.id); is && et.preview && dirty do run_command(Keep_Tab{tab_id = tab.id}, {kind = .Internal})
	}
}

// Lists a folder again when next needed (an error row's Retry).
files_retry :: proc(dir: string) {
	if d := files_cache[dir]; d != nil {
		d.stale = true
		files_cache_gen += 1
	}
	window_state_changed()
}
