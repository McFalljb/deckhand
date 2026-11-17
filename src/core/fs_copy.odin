package core

// fs_copy: a file or a folder tree copied inside projects (the Files tree's Duplicate, Copy and
// Paste). Everything is checked and counted on the main thread before anything is written
// (fs_copy_plan: both paths pass fs_check, never into itself, credentials, .git, the caps); the
// bytes are copied on a worker (fs_copy_run), which comes back as Fs_Copy_Done.
//
// Links are never followed: a symlink is copied as a link (the same target text). Both trees are
// walked through folder descriptors (openat, NOFOLLOW) from their parents, whose real paths are
// checked again once open, so nothing is read or written through a link that leads elsewhere,
// and every source item is the one the checks saw (device and inode). Never over anything: the
// target and every item in it are made exclusively (O_EXCL, mkdirat). Mode bits are kept
// (0o777: no setuid, setgid or sticky), ownership is not. A failure midway leaves what was copied.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:thread"

// Internal: a copy's worker finished.
Fs_Copy_Done :: struct {
	request_id: u64,
	path:       string, // the target (absolute)
	copied:     int, // items made
	total:      int, // items planned
	failed:     string, // where it stopped, relative to the copy ("" = the copy itself; err says)
	err:        string, // "" = all copied
	skipped:    string, // what the plan left out, a JSON array ([{path, why}]; "" = none)
}

FS_COPY_MAX_ENTRIES :: 20_000 // files, folders and links in one copy
FS_COPY_MAX_BYTES :: i64(2) << 30 // regular files' bytes in one copy (2 GB)
FS_COPY_MAX_DEPTH :: 24 // folders inside folders: each level holds two descriptors while it copies, so
// a copy holds at most about 50 (one copy at a time: FS_COPY_RUNNING), well under the usual limit
FS_COPY_RUNNING :: "a copy is already running"
FS_COPY_TOO_MANY :: "too many to copy: more than %d files and folders; nothing was copied"
FS_COPY_NAMES_MAX :: 1000 // "name copy N" names tried

FS_COPY_INTO_ITSELF :: "a folder cannot be copied into itself"
FS_COPY_TAKEN :: "the target already exists"
FS_COPY_CREDENTIAL :: "a credential is in it (%s): only you, in Deckhand's window, may copy it; nothing was copied"

Fs_Copy_Kind :: enum u8 {
	File,
	Dir,
	Link,
}

Fs_Copy_Item :: struct {
	name:     string, // in its folder ("" = the copy's root)
	rel:      string, // relative to the copy ("" = its root)
	depth:    int, // 0 = the root
	kind:     Fs_Copy_Kind,
	mode:     u32, // permission bits (0o777)
	size:     i64, // a file's bytes the checks counted: no more are copied
	dev, ino: u64, // the source item the checks saw
}

Fs_Copy_Skip :: struct {
	rel, why: string,
}

// A checked copy: what goes where (the plan's allocator: an arena the worker frees).
Fs_Copy_Plan :: struct {
	from, to: string, // the source and the target (absolute: their folders' real paths)
	items:    []Fs_Copy_Item, // the root first, then each folder before what is in it
	skipped:  []Fs_Copy_Skip,
	bytes:    i64,
}

// The targets of copies in flight (owned keys): a unique name never picks one of them.
@(private = "file")
fs_copy_busy: map[string]bool

// The source and target checked: both inside a project (fs_check), the source there, the
// target's folder there. a, b: their absolute paths (b as asked, before a unique name).
// The user at this window may also copy IN from outside every project (fs_copy_outside_source).
fs_copy_paths :: proc(from, to: string, caller: Caller) -> (a, b: string, err: string) {
	e: string
	a, _, e = fs_check(from, caller)
	if e != "" {
		out, oerr, applies := fs_copy_outside_source(from, caller)
		if !applies do return "", "", e
		if oerr != "" do return "", "", oerr
		a = out
	}
	b, _, e = fs_check(to, caller)
	if e != "" do return "", "", e
	return a, b, ""
}

// A copy's source outside every project (files dropped from Finder onto the Files tree): only for
// the user at this window (fs_user_here; never a browser, another machine's core, a script, a
// control caller or Deckhand itself), only an absolute path, only one in no project at all (one
// inside a project keeps fs_check's refusal: its .git, the project's own folder), never in or at
// a .git folder (any case). abs: its folder's real path and its own name (the link itself, never
// followed: fs_copy_run opens that folder and checks its real path again). Everything else is
// fs_copy_plan's, unchanged: the target, into itself, credentials (the user's left out and said),
// .git left out, the caps.
// applies false: not such a source (the caller keeps fs_check's refusal); else abs, or err.
fs_copy_outside_source :: proc(from: string, caller: Caller) -> (abs, err: string, applies: bool) {
	context.allocator = context.temp_allocator // filepath's copies
	if !fs_user_here(caller) || !filepath.is_abs(from) do return "", "", false
	base := filepath.base(from)
	if base == "" || base == "." || base == ".." || base == "/" do return "", "", false
	parent := fs_real(filepath.dir(from))
	if parent == "" do return "", "", false
	full := parent == "/" ? strings.concatenate({"/", base}, context.temp_allocator) : strings.concatenate({parent, "/", base}, context.temp_allocator)
	roots := fs_roots()
	for r in roots do if within(full, r) do return "", "", false
	// nor one reached through a project (a link in it that leads out): every folder on the path as
	// given, by its real path too
	for d := filepath.dir(from); ; d = filepath.dir(d) {
		rd := fs_real(d)
		for r in roots do if within(d, r) || within(rd, r) do return "", "", false
		if d == "/" || d == "." || d == "" do break
	}
	if fs_in_git(full) do return "", "not inside .git", true
	return full, "", true
}

// Every rule of a copy, nothing written: the paths (fs_copy_paths), never into itself, credential
// places and credentials (fs_user_here: the user's are left out and said; anyone else's refuse the
// copy), .git folders left out, the caps; the target's name (unique: "name copy", "name copy 2",
// … when taken, else refused). The plan is made with allocator (its arena).
fs_copy_plan :: proc(from, to: string, unique: bool, caller: Caller, allocator: runtime.Allocator) -> (plan: Fs_Copy_Plan, err: string) {
	context.allocator = context.temp_allocator // filepath's copies; the plan is made with allocator
	a, b, e := fs_copy_paths(from, to, caller)
	if e != "" do return {}, e
	user := fs_user_here(caller)
	sa: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(a, context.temp_allocator), &sa) != .OK do return {}, "no such file or folder"
	if path_kind(filepath.dir(b)) != .Dir do return {}, "the target's folder does not exist"
	is_dir := posix.S_ISDIR(sa.st_mode)
	// into itself: a folder above the target is the source (by the file: another spelling of it
	// on a volume that ignores case is the same folder)
	if is_dir {
		for d := filepath.dir(b); ; d = filepath.dir(d) {
			sd: posix.stat_t
			if posix.stat(strings.clone_to_cstring(d, context.temp_allocator), &sd) == .OK && sd.st_dev == sa.st_dev && sd.st_ino == sa.st_ino do return {}, FS_COPY_INTO_ITSELF
			if d == "/" || d == "." || d == "" do break
		}
	}
	if !user && (fs_credential_place(a) || fs_credential_place(b)) do return {}, CREDENTIAL_PLACE_REFUSED
	if fs_copy_taken(b) {
		if !unique do return {}, FS_COPY_TAKEN
		b = fs_copy_free_name(b, is_dir)
		if b == "" do return {}, "no free name for the copy"
	}

	plan.from = strings.clone(a, allocator)
	plan.to = strings.clone(b, allocator)
	items := make([dynamic]Fs_Copy_Item, allocator)
	skipped := make([dynamic]Fs_Copy_Skip, allocator)
	// the root itself, by the full rule
	ids := credential_ids() // read once for the whole tree
	none: [1]Cred_Id
	if len(ids) == 0 do ids = none[:0] // no sign-in files: never nil (nil reads them again, per entry)
	home := fs_real(os.get_env("HOME", context.temp_allocator)) // show_secret's, once for the tree
	if cerr := copy_credential_check(a, ".", is_dir, user, true, ids, home); cerr != "" do return {}, cerr
	if user && settings_credential(a, ids) do return {}, "it is a credential: not copied"
	// in a credential place (at, above or inside one; the user's only by now), every entry is
	// checked by the full rule; else only below a folder that is one by what it holds, and links
	// (copy_credential)
	in_place := fs_credential_place(a)
	// pi's agent folder counts wherever it is (settings_credential's rule; fs_credential_place
	// leaves out HOME and above)
	for ad in ([2]string{pi_agent_dir(), fs_real(pi_agent_dir())}) do if ad != "" && within(a, strings.trim_right(ad, "/")) do in_place = true
	root, kind_ok := copy_item_of(&sa, "", "", 0)
	if !kind_ok do return {}, "not a file, folder or link"
	append(&items, root)
	if root.kind == .File do plan.bytes = i64(sa.st_size)
	// the tree, without following links: folders first, each before what is in it
	Frame :: struct {
		path, rel: string,
		depth:     int,
		place:     bool, // it or a folder above it is a credential place: its entries get the full rule
	}
	if root.kind == .Dir {
		stack := make([dynamic]Frame, context.temp_allocator)
		append(&stack, Frame{a, "", 0, in_place || copy_marked_folder(a)})
		for len(stack) > 0 {
			f := pop(&stack)
			names, lerr, over := copy_read_names(f.path, FS_COPY_MAX_ENTRIES - len(items))
			if over do return {}, fmt.tprintf(FS_COPY_TOO_MANY, FS_COPY_MAX_ENTRIES)
			if lerr != "" do return {}, fmt.tprintf("cannot list %s: %s", f.rel == "" ? "it" : f.rel, lerr)
			subs := make([dynamic]Frame, context.temp_allocator)
			for name in names {
				full := strings.concatenate({f.path, "/", name}, context.temp_allocator)
				rel := f.rel == "" ? name : strings.concatenate({f.rel, "/", name}, context.temp_allocator)
				st: posix.stat_t
				if posix.lstat(strings.clone_to_cstring(full, context.temp_allocator), &st) != .OK do continue // gone meanwhile
				if strings.equal_fold(name, ".git") {
					append(&skipped, Fs_Copy_Skip{strings.clone(rel, allocator), "a git repository's folder: not copied"})
					continue
				}
				d := posix.S_ISDIR(st.st_mode)
				full_rule := f.place || posix.S_ISLNK(st.st_mode) // a link: where it leads decides too
				if cerr := copy_credential_check(full, rel, d, user, full_rule, ids, home, &st); cerr != "" do return {}, cerr
				if user && !d && copy_credential(full, full_rule, ids, &st) {
					append(&skipped, Fs_Copy_Skip{strings.clone(rel, allocator), "a credential: not copied"})
					continue
				}
				it, ok := copy_item_of(&st, strings.clone(name, allocator), strings.clone(rel, allocator), f.depth + 1)
				if !ok {
					append(&skipped, Fs_Copy_Skip{strings.clone(rel, allocator), "not a file, folder or link: not copied"})
					continue
				}
				if len(items) >= FS_COPY_MAX_ENTRIES do return {}, fmt.tprintf(FS_COPY_TOO_MANY, FS_COPY_MAX_ENTRIES)
				if it.kind == .File {
					plan.bytes += i64(st.st_size)
					if plan.bytes > FS_COPY_MAX_BYTES do return {}, "too big to copy: more than 2 GB; nothing was copied"
				}
				if it.kind == .Dir {
					if it.depth > FS_COPY_MAX_DEPTH do return {}, fmt.tprintf("too deep to copy: more than %d folders inside each other; nothing was copied", FS_COPY_MAX_DEPTH)
					append(&subs, Frame{full, rel, it.depth, f.place || copy_marked_folder(full)})
				}
				append(&items, it)
			}
			// depth first, in order: a folder's own entries follow it before the next folder's.
			// The items list is rebuilt below in that order (each folder's entries after it).
			#reverse for s in subs do append(&stack, s)
		}
		plan.items = copy_preorder(items[:], allocator)
	} else {
		plan.items = items[:]
	}
	plan.skipped = skipped[:]
	return plan, ""
}

// For a caller other than the user here: a credential (copy_credential), a name file_read refuses
// (show_secret) or a folder that is a credential place by what it holds refuses the whole copy.
// The user's credentials are left out instead (fs_copy_plan).
@(private = "file")
copy_credential_check :: proc(full, rel: string, is_dir, user, full_rule: bool, ids: []Cred_Id, home: string, st: ^posix.stat_t = nil) -> string {
	if user do return ""
	if copy_credential(full, full_rule, ids, st) || show_secret(full, home) do return fmt.tprintf(FS_COPY_CREDENTIAL, rel)
	if is_dir && copy_marked_folder(full) do return fmt.tprintf(FS_COPY_CREDENTIAL, rel)
	return ""
}

// Whether a folder is a credential place by what it holds (fs_credential_place's own test): one
// holding Claude's sign-in or account file, a .codex folder holding auth.json.
@(private = "file")
copy_marked_folder :: proc(d: string) -> bool {
	if claude_marked_folder(d) do return true
	return strings.equal_fold(filepath.base(d), ".codex") && path_kind(strings.concatenate({d, "/auth.json"}, context.temp_allocator)) != .Missing
}

// settings_credential for an entry of the tree. full_rule: settings_credential itself (in or
// below a credential place, or a link). Otherwise the entry is in no place (the copy's root is
// not in, at or above one: fs_credential_place, and no folder on the way down holds a sign-in:
// copy_marked_folder), so of settings_credential's rules only those by name and by the file
// itself are left: Claude's sign-in and account file names in any case, Codex's .codex/auth.json,
// and another name (a hard link) for a sign-in file (credential_inode). Its full rule walks every
// folder above the entry for each entry (milliseconds each on a 20,000-entry tree).
@(private = "file")
copy_credential :: proc(full: string, full_rule: bool, ids: []Cred_Id, st: ^posix.stat_t) -> bool {
	if full_rule || st == nil do return settings_credential(full, ids)
	base := strings.to_lower(filepath.base(full), context.temp_allocator)
	if base == ".credentials.json" || base == ".claude.json" || strings.has_prefix(base, ".claude.json.") do return true
	if base == "auth.json" && strings.equal_fold(filepath.base(filepath.dir(full)), ".codex") do return true
	return posix.S_ISREG(st.st_mode) && credential_inode(u64(st.st_dev), u64(st.st_ino), ids)
}

@(private = "file")
copy_item_of :: proc(st: ^posix.stat_t, name, rel: string, depth: int) -> (it: Fs_Copy_Item, ok: bool) {
	it = {name = name, rel = rel, depth = depth, mode = u32(transmute(posix._mode_t)st.st_mode) & 0o777, size = i64(st.st_size), dev = u64(st.st_dev), ino = u64(st.st_ino)}
	switch {
	case posix.S_ISREG(st.st_mode): it.kind = .File
	case posix.S_ISDIR(st.st_mode): it.kind = .Dir
	case posix.S_ISLNK(st.st_mode): it.kind = .Link
	case: return it, false
	}
	return it, true
}

// A folder's names, sorted (temp). err: why it cannot be listed. over: it has more than max
// entries (read no further: a huge folder is refused without listing all of it).
@(private = "file")
copy_read_names :: proc(dir: string, max: int) -> (names: []string, err: string, over: bool) {
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil do return nil, strings.to_lower(string(posix.strerror(posix.errno())), context.temp_allocator), false
	defer posix.closedir(d)
	out := make([dynamic]string, context.temp_allocator)
	for {
		ent := posix.readdir(d)
		if ent == nil do break
		n := string(cstring(raw_data(ent.d_name[:])))
		if n == "." || n == ".." do continue
		if len(out) >= max do return nil, "", true
		append(&out, strings.clone(n, context.temp_allocator))
	}
	slice.sort_by(out[:], fs_name_less) // the tree's order
	return out[:], "", false
}

// The items in depth-first order: the root, then each folder followed by everything in it (the
// worker keeps one open folder per level). items: the root, then each folder's entries in the
// order its folder was listed.
@(private = "file")
copy_preorder :: proc(items: []Fs_Copy_Item, allocator: runtime.Allocator) -> []Fs_Copy_Item {
	children := make(map[string][dynamic]int, context.temp_allocator) // a folder's rel -> its entries
	for it, i in items {
		if i == 0 do continue
		parent := it.depth == 1 ? "" : it.rel[:len(it.rel) - len(it.name) - 1]
		list := children[parent] or_else make([dynamic]int, context.temp_allocator)
		append(&list, i)
		children[parent] = list
	}
	out := make([dynamic]Fs_Copy_Item, 0, len(items), allocator)
	add :: proc(out: ^[dynamic]Fs_Copy_Item, items: []Fs_Copy_Item, children: map[string][dynamic]int, i: int) {
		append(out, items[i])
		if items[i].kind != .Dir do return
		if list, ok := children[items[i].rel]; ok do for k in list do add(out, items, children, k)
	}
	add(&out, items, children, 0)
	return out[:]
}

// Whether a copy's worker is running (one at a time: FS_COPY_RUNNING).
fs_copy_in_flight :: proc() -> bool {return len(fs_copy_busy) > 0}

when TEST_HOOKS {
	// Copies whose worker has not come back yet (tests).
	fs_copy_running :: proc() -> int {return len(fs_copy_busy)}
}

// Whether something is at path (a dangling link too), or a copy in flight is making it.
@(private = "file")
fs_copy_taken :: proc(path: string) -> bool {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK do return true
	for k, _ in fs_copy_busy do if strings.equal_fold(k, path) do return true
	return false
}

// The first free "name copy", "name copy 2", … next to path (temp; "" = none of
// FS_COPY_NAMES_MAX): before a file's extension ("a copy.txt"); a name that starts with its only
// dot (".env") has none.
fs_copy_free_name :: proc(path: string, is_dir: bool) -> string {
	dir, base := filepath.split(path)
	dir = strings.trim_right(dir, "/")
	stem, ext := base, ""
	if !is_dir {
		if i := strings.last_index_byte(base, '.'); i > 0 do stem, ext = base[:i], base[i:]
	}
	for n in 1 ..= FS_COPY_NAMES_MAX {
		name := n == 1 ? fmt.tprintf("%s copy%s", stem, ext) : fmt.tprintf("%s copy %d%s", stem, n, ext)
		p := fmt.tprintf("%s/%s", dir, name)
		if !fs_copy_taken(p) do return p
	}
	return ""
}

// What a copy left out, as JSON ([{path, why}]; "" = nothing). Temp allocator.
@(private = "file")
copy_skipped_json :: proc(skipped: []Fs_Copy_Skip) -> string {
	if len(skipped) == 0 do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for s, i in skipped {
		if i > 0 do strings.write_byte(&b, ',')
		strings.write_string(&b, `{"path":`)
		json_quote(&b, s.rel)
		strings.write_string(&b, `,"why":`)
		json_quote(&b, s.why)
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// Starts a checked copy on a worker (main thread); Fs_Copy_Done comes back with request_id.
// The plan lives in arena, which the worker frees.
fs_copy_start :: proc(plan: Fs_Copy_Plan, arena: ^virtual.Arena, request_id: u64) {
	if fs_copy_busy.allocator.procedure == nil do fs_copy_busy.allocator = runtime.heap_allocator()
	fs_copy_busy[strings.clone(plan.to, runtime.heap_allocator())] = true
	Job :: struct {
		plan:       Fs_Copy_Plan,
		arena:      ^virtual.Arena,
		request_id: u64,
		skipped:    string, // heap
	}
	h := runtime.heap_allocator()
	job := new_clone(Job{plan, arena, request_id, strings.clone(copy_skipped_json(plan.skipped), h)}, h)
	thread.run_with_poly_data(job, proc(job: ^Job) {
		h := runtime.heap_allocator()
		copied, failed, err := fs_copy_run(job.plan)
		inbox_submit(Fs_Copy_Done{request_id = job.request_id, path = job.plan.to, copied = copied, total = len(job.plan.items), failed = failed, err = err, skipped = job.skipped}, {kind = .Internal}) // copied
		virtual.arena_destroy(job.arena)
		free(job.arena, h)
		delete(job.skipped, h)
		free(job, h)
		free_all(context.temp_allocator)
	})
}

// A copy's worker finished (main thread): the model forgets the target's folder, the requester
// gets its finished event. data {path, copied, skipped?}; midway: the error says how many were
// made, data {path, copied, failed}.
fs_copy_done :: proc(c: Fs_Copy_Done) -> (r: Result) {
	if c.path in fs_copy_busy {
		k, _ := delete_key(&fs_copy_busy, c.path)
		delete(k, runtime.heap_allocator())
	}
	if c.copied > 0 do fs_changed_ours(c.path)
	q := strings.builder_make(context.temp_allocator)
	json_quote(&q, c.path)
	if c.err == "" {
		skipped := c.skipped != "" ? fmt.tprintf(`,"skipped":%s`, c.skipped) : ""
		r = {ok = true, data = fmt.aprintf(`{{"path":%s,"copied":%d%s}}`, strings.to_string(q), c.copied, skipped)}
	} else {
		where_ := c.failed == "" ? "" : fmt.tprintf("%s: ", c.failed)
		r = fail(c.copied == 0 ? fmt.tprintf("nothing was copied: %s%s", where_, c.err) : fmt.tprintf("copied %d of %d, then %s%s (what was copied stays at %s)", c.copied, c.total, where_, c.err, c.path))
		f := strings.builder_make(context.temp_allocator)
		json_quote(&f, c.failed)
		r.data = fmt.aprintf(`{{"path":%s,"copied":%d,"failed":%s}}`, strings.to_string(q), c.copied, strings.to_string(f))
	}
	emit_event(Finished_Event{request_id = c.request_id, result = r})
	return r
}

// Copies a checked plan (any thread; the file system only). copied: items made; failed: the item
// it stopped at (its rel; "" with err: before the first). Both trees are reached only through
// folder descriptors opened without following links, from the parents whose real paths the plan
// names; every source item must still be the one the plan saw.
fs_copy_run :: proc(plan: Fs_Copy_Plan) -> (copied: int, failed: string, err: string) {
	if len(plan.items) == 0 do return 0, "", "nothing to copy"
	open_dir :: proc(path: string) -> posix.FD {
		fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
		if fd < 0 do return -1
		if fd_real_path(fd) != path {
			posix.close(fd)
			return -1
		}
		return fd
	}
	from_dir, to_dir := tdir(plan.from), tdir(plan.to)
	sroot := open_dir(from_dir)
	if sroot < 0 do return 0, "", "the source's folder moved or cannot be opened"
	droot := open_dir(to_dir)
	if droot < 0 {
		posix.close(sroot)
		return 0, "", "the target's folder moved or cannot be opened"
	}
	Level :: struct {
		src, dst: posix.FD,
		mode:     u32, // the folder's own mode, set once its entries are in (it may not be writable)
		owned:    bool, // a folder this copy made (the parents are not)
	}
	levels := make([dynamic]Level, context.temp_allocator)
	append(&levels, Level{sroot, droot, 0, false})
	close_level :: proc(l: Level) {
		if l.owned do posix.fchmod(l.dst, transmute(posix.mode_t)posix._mode_t(l.mode))
		posix.close(l.src)
		posix.close(l.dst)
	}
	defer for len(levels) > 0 do close_level(pop(&levels))
	errno_text :: proc() -> string {return strings.to_lower(string(posix.strerror(posix.errno())), context.temp_allocator)}
	same :: proc(fd: posix.FD, it: Fs_Copy_Item) -> bool {
		st: posix.stat_t
		return posix.fstat(fd, &st) == .OK && u64(st.st_dev) == it.dev && u64(st.st_ino) == it.ino
	}
	buf := make([]u8, 1 << 20, context.temp_allocator)
	total: i64 // bytes copied so far: never past FS_COPY_MAX_BYTES, whatever grew since the checks
	base_from, base_to := filepath.base(plan.from), filepath.base(plan.to)
	for it in plan.items {
		for len(levels) > it.depth + 1 do close_level(pop(&levels))
		if len(levels) != it.depth + 1 do return copied, it.rel, "the plan's folders are out of order"
		l := levels[len(levels) - 1]
		sname := strings.clone_to_cstring(it.depth == 0 ? base_from : it.name, context.temp_allocator)
		dname := strings.clone_to_cstring(it.depth == 0 ? base_to : it.name, context.temp_allocator)
		switch it.kind {
		case .Dir:
			s := posix.openat(l.src, sname, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
			if s < 0 do return copied, it.rel, "it changed while copying"
			if !same(s, it) {
				posix.close(s)
				return copied, it.rel, "it changed while copying"
			}
			if posix.mkdirat(l.dst, dname, {.IRUSR, .IWUSR, .IXUSR}) != .OK {
				e := errno_text()
				posix.close(s)
				return copied, it.rel, fmt.tprintf("cannot make the folder: %s", e)
			}
			d := posix.openat(l.dst, dname, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
			if d < 0 {
				posix.close(s)
				return copied + 1, it.rel, "the new folder changed while copying"
			}
			copied += 1
			append(&levels, Level{s, d, it.mode, true})
		case .File:
			s := posix.openat(l.src, sname, {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
			if s < 0 do return copied, it.rel, "it changed while copying"
			defer posix.close(s)
			if !same(s, it) do return copied, it.rel, "it changed while copying"
			d := posix.openat(l.dst, dname, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, posix.mode_t{.IRUSR, .IWUSR})
			if d < 0 do return copied, it.rel, fmt.tprintf("cannot make the file: %s", errno_text())
			copied += 1 // made, even if its bytes fail below: it stays, and says so
			ok := true
			left := it.size // a file that grew since the checks: only what they counted
			grew := false
			for left > 0 {
				n := int(posix.read(s, raw_data(buf), uint(min(i64(len(buf)), left))))
				if n < 0 && posix.errno() == .EINTR do continue
				if n <= 0 {
					ok = n == 0
					break
				}
				w := 0
				for w < n {
					m := int(posix.write(d, raw_data(buf[w:]), uint(n - w)))
					if m < 0 && posix.errno() == .EINTR do continue
					if m <= 0 {
						ok = false
						break
					}
					w += m
				}
				if !ok do break
				left -= i64(n)
				total += i64(n)
				if total > FS_COPY_MAX_BYTES {
					grew = true
					break
				}
			}
			e := ok ? "" : errno_text()
			posix.fchmod(d, transmute(posix.mode_t)posix._mode_t(it.mode))
			posix.close(d)
			if !ok do return copied, it.rel, fmt.tprintf("cannot copy its bytes: %s", e)
			if grew do return copied, it.rel, "the files grew past 2 GB while copying"
		case .Link:
			lst: posix.stat_t
			if posix.fstatat(l.src, sname, &lst, {.SYMLINK_NOFOLLOW}) != .OK || !posix.S_ISLNK(lst.st_mode) || u64(lst.st_dev) != it.dev || u64(lst.st_ino) != it.ino {
				return copied, it.rel, "it changed while copying"
			}
			lbuf: [posix.PATH_MAX]u8
			n := posix.readlinkat(l.src, sname, raw_data(lbuf[:]), len(lbuf) - 1)
			if n < 0 do return copied, it.rel, "it changed while copying"
			lbuf[n] = 0
			if posix.symlinkat(cstring(raw_data(lbuf[:])), l.dst, dname) != .OK do return copied, it.rel, fmt.tprintf("cannot make the link: %s", errno_text())
			copied += 1
		}
	}
	return copied, "", ""
}
