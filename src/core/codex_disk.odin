package core

// Codex conversations started outside Deckhand, as rows (docs/CODEX.md §2b): what the found-row
// scan (claude_disk_scan, claude_disk.odin) reads of Codex's homes. Read only, never written.
//
//   - Where: each Codex account's <home>/sessions/YYYY/MM/DD folders, all of them (newest first,
//     up to the hard ceilings CODEX_DISK_DIRS_MAX folders and CODEX_DISK_FILES_MAX files a home:
//     only a broken folder reaches them); regular files named rollout-<time>-<uuid>.jsonl or
//     .jsonl.zst (Codex Desktop compresses older ones) only, the id from the name, the plain file
//     when both are there (codex_disk_files).
//   - What: the first line only (session_meta: its id, cwd and source), at most
//     CODEX_DISK_LINE_MAX (codex_first_line; of a .zst, only as much as decodes it, within the
//     CODEX_ZST_* caps: codex_zst_first_line), once per file ever: the meta cache (path, size,
//     mtime -> id, cwd, source, account, created) is saved in the data dir (CODEX_CACHE_FILE), so
//     a launch reads only new or changed rollouts. All of it on a worker (codex_pass): the main
//     thread only filters the cache (codex_disk_found).
//   - Which: source "cli" (the CLI) and "vscode" (Codex Desktop) only (codex_source_listed): never
//     `codex exec`'s, a sub-agent's (an object) or a source Deckhand does not know.
//   - Titles: <home>/session_index.jsonl (id, thread_name, updated_at; the last line for an id
//     wins), joined to the listed rows only, read again when its size or mtime changes.
//   - The scan picks a harness's lister and first-line reader by an exhaustive switch on Harness
//     (disk_files, disk_first_line): a new harness's found rows add a case to each.

import "base:runtime"
import "core:encoding/json"
import jg "../jsonguard"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "../zstd"

CODEX_DISK_DIRS_MAX :: 20_000 // folders walked a home (years, months, days): a hard ceiling
CODEX_DISK_FILES_MAX :: 50_000 // rollouts listed a home, newest first: a hard ceiling
CODEX_DISK_LINE_MAX :: 64 * 1024 // a rollout's first line (session_meta, ~25 KB); longer: skipped
CODEX_CWD_MAX :: 1024 // a rollout's cwd; longer (or with a NUL): skipped, never walked

// Directory entries one folder may have looked at (tests lower it): past it the folder is read no
// further (a broken or planted folder cannot make the lister stat, keep and sort millions).
codex_disk_dir_entries_max := 20_000
// Directory entries the lister has looked at (tests).
codex_disk_entries_seen: i64
// Passes run on the caller's thread (codex_disk_pass_now; tests).
codex_disk_passes_inline: int
// a compressed rollout (.jsonl.zst, codex_zst_first_line): measured, its first line is at most ~49 KB
// and decodes from its first 128 KB; past either cap without a newline it is skipped
CODEX_ZST_IN_MAX :: 256 * 1024 // compressed bytes read, at most
CODEX_ZST_OUT_MAX :: 256 * 1024 // decoded bytes, at most (the line itself: CODEX_DISK_LINE_MAX)
CODEX_ZST_READ :: 32 * 1024 // compressed bytes read at a time
CODEX_ZST_WINDOW_LOG_MAX :: 23 // 8 MiB: zstd -19 and every lower level; a larger window is refused

// A harness's conversation file found on disk: its id (from its name), path, dates and the home
// (account folder) it is in. Temp.
Disk_File :: struct {
	id, path, account: string,
	size:              i64,
	modified, created: time.Time,
}

// An account's folder (its home) and the folder its conversation files are in, as the main thread
// found them for a worker's listing.
Disk_Home :: struct {
	account, root: string,
}

// ---- per harness ----

// The accounts of harness h whose conversation files a worker lists (disk_files). Main thread
// (the accounts and the environment are the main thread's). Temp.
disk_homes :: proc(h: Harness) -> []Disk_Home {
	out := make([dynamic]Disk_Home, context.temp_allocator)
	switch h {
	case .Codex:
		for a in claude_accounts(codex = true) do if root := codex_sessions_dir(a.dir); root != "" do append(&out, Disk_Home{account = a.dir, root = root})
	case .Pi, .Claude:
	}
	return out[:]
}

// The conversation files of homes (disk_homes) of harness h, as its lister finds them, newest
// first. Claude Code's are listed per project by claude_disk_scan itself (its folder names); pi's
// are its own (sessions.odin). Any thread. Temp.
disk_files :: proc(h: Harness, homes: []Disk_Home) -> []Disk_File {
	switch h {
	case .Codex:
		return codex_disk_files(homes)
	case .Pi, .Claude:
		return nil
	}
	return nil
}

// What the scan reads of one of harness h's files (from disk_files): the cwd it ran in and how it
// was started (its source), or skip (not a conversation). Any thread.
disk_first_line :: proc(h: Harness, path: string) -> (cwd, source: string, skip, unreadable: bool) {
	switch h {
	case .Codex:
		return codex_first_line(path)
	case .Pi, .Claude:
		return "", "", true, false
	}
	return "", "", true, false
}

// ---- Codex's conversations (~/.codex/sessions; codex.odin) ----

// A rollout's session_meta (its first line, at most CODEX_DISK_LINE_MAX, never more of the file;
// of a compressed one, .jsonl.zst, only what decodes it: codex_zst_first_line): the cwd it ran in and its source (how it was started: "cli", "vscode", "exec"; cut to
// CODEX_SOURCE_MAX). skip: not a conversation to list (no session_meta, an id that is not the
// file's, a subagent's or another non-string source; a .zst that does not decode within its
// caps). Never written to; nothing in it reaches a shell or the screen (the cwd is only compared
// with the project's folder). unreadable: it could not be read now (open, stat or read failed:
// permissions, an I/O error), so skip says nothing of what it is: read it again later. Any thread.
codex_first_line :: proc(path: string) -> (cwd, source: string, skip, unreadable: bool) {
	skip = true
	// never a FIFO or a link swapped in since the listing (open would block, or go elsewhere)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .NOFOLLOW, .CLOEXEC})
	if fd < 0 {
		unreadable = posix.errno() != .ELOOP // a link (planted, never followed) is what it is
		return
	}
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK {
		unreadable = true
		return
	}
	if !posix.S_ISREG(st.st_mode) do return
	name, zst := codex_rollout_stem(filepath.base(path))
	line: string
	if zst {
		ok: bool
		if line, _, ok, unreadable = codex_zst_first_line(fd); !ok do return
	} else {
		buf := make([]u8, CODEX_DISK_LINE_MAX, context.temp_allocator)
		got := int(posix.pread(fd, raw_data(buf), len(buf), 0))
		if got < 0 {
			unreadable = true
			return
		}
		sync.atomic_add(&claude_disk_bytes_read, i64(max(got, 0)))
		nl := strings.index_byte(string(buf[:max(got, 0)]), '\n')
		if nl < 0 do return
		line = string(buf[:nl])
	}
	if len(line) < 2 do return
	if line[0] != '{' || !json_depth_ok(line) do return
	v, perr := jg.parse(transmute([]u8)line, .JSON, false, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	if t, _ := o["type"].(json.String); t != "session_meta" do return
	pl, _ := o["payload"].(json.Object)
	id, _ := pl["id"].(json.String)
	c, _ := pl["cwd"].(json.String)
	src, src_ok := pl["source"].(json.String)
	if !src_ok do return // a subagent's ({"subagent": …})
	if !codex_id_ok(string(id)) || !strings.has_suffix(name, string(id)) || !filepath.is_abs(string(c)) do return
	if len(c) > CODEX_CWD_MAX || strings.index_byte(string(c), 0) >= 0 do return
	return string(c), cut_utf8(string(src), CODEX_SOURCE_MAX), false, false
}

// A rollout file name without its extension, and whether it is compressed: "x.jsonl" -> "x", false;
// "x.jsonl.zst" (Codex Desktop compresses older rollouts with zstd) -> "x", true; anything else "".
codex_rollout_stem :: proc(name: string) -> (stem: string, zst: bool) {
	if strings.has_suffix(name, ".jsonl") do return strings.trim_suffix(name, ".jsonl"), false
	if strings.has_suffix(name, ".jsonl.zst") do return strings.trim_suffix(name, ".jsonl.zst"), true
	return "", false
}

// The first line (no newline) of a zstd-compressed rollout open at fd, decoded with the vendored
// decoder (src/zstd) as far as its first newline and no further. These files are not Deckhand's:
// at most CODEX_ZST_IN_MAX compressed bytes are read (CODEX_ZST_READ at a time), decoding stops at
// min(CODEX_ZST_OUT_MAX, CODEX_DISK_LINE_MAX) bytes without a newline, and a frame asking for a
// window over 2^CODEX_ZST_WINDOW_LOG_MAX is refused before zstd allocates it; any of those, a
// decode error or the end of the file first: ok false. decoded: the bytes decoded (tests). unreadable:
// a read failed (not what the file is). Any thread.
codex_zst_first_line :: proc(fd: posix.FD) -> (line: string, decoded: int, ok, unreadable: bool) {
	d := zstd.dctx_create()
	if d == nil do return
	defer zstd.dctx_free(d)
	if zstd.is_error(zstd.dctx_set_parameter(d, zstd.D_WINDOW_LOG_MAX, CODEX_ZST_WINDOW_LOG_MAX)) != 0 do return
	out := make([]u8, min(CODEX_ZST_OUT_MAX, CODEX_DISK_LINE_MAX), context.temp_allocator)
	in_buf := make([]u8, CODEX_ZST_READ, context.temp_allocator)
	read := 0
	for read < CODEX_ZST_IN_MAX {
		got := int(posix.pread(fd, raw_data(in_buf), uint(min(CODEX_ZST_READ, CODEX_ZST_IN_MAX - read)), posix.off_t(read)))
		unreadable = got < 0 // a read error: not what the file is
		if got <= 0 do return // the end (truncated: no newline yet) or an error
		read += got
		sync.atomic_add(&claude_disk_bytes_read, i64(got))
		input := zstd.In_Buffer{raw_data(in_buf), uint(got), 0}
		for input.pos < input.size {
			output := zstd.Out_Buffer{raw_data(out), uint(len(out)), uint(decoded)}
			before_in, before_out := input.pos, output.pos
			r := zstd.decompress_stream(d, &output, &input)
			if zstd.is_error(r) != 0 do return
			if nl := strings.index_byte(string(out[decoded:output.pos]), '\n'); nl >= 0 {
				return string(out[:decoded + nl]), int(output.pos), true, false
			}
			decoded = int(output.pos)
			if decoded == len(out) do return // the caps, and no newline
			if input.pos == before_in && output.pos == before_out do return // no progress: never spin
		}
	}
	return
}

// A Codex home's sessions folder ("" = none; in tests and test mode never the developer's own
// ~/.codex: the default only when they set CODEX_HOME, ~/.codex of the real home never). Main thread.
codex_sessions_dir :: proc(home: string) -> string {
	when TEST_HOOKS {
		if ODIN_TEST || test_mode() {
			if _, ok := env_lookup(child_base_env(), "CODEX_HOME"); !ok && home == codex_home() do return ""
			if real := account_home(); real != "" && home == strings.concatenate({strings.trim_right(real, "/"), "/.codex"}, context.temp_allocator) do return ""
		}
	}
	return home == "" ? "" : strings.concatenate({home, "/sessions"}, context.temp_allocator)
}

// The rollouts of each Codex home (disk_homes), newest first by their folders' and names' dates
// (sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl): all of them, up to the hard ceilings
// (CODEX_DISK_DIRS_MAX folders walked, CODEX_DISK_FILES_MAX files a home); regular files only.
// Any thread. Temp.
@(private = "file")
codex_disk_files :: proc(homes: []Disk_Home) -> []Disk_File {
	out := make([dynamic]Disk_File, context.temp_allocator)
	for h in homes do codex_disk_files_in(&out, h.account, h.root)
	return out[:]
}

// The rollouts of one home (root: its sessions folder, codex_sessions_dir, taken on the main
// thread), as codex_disk_files. Any thread.
codex_disk_files_in :: proc(all: ^[dynamic]Disk_File, home, root: string) {
	out := make([dynamic]Disk_File, context.temp_allocator)
	defer append(all, ..out[:])
	if root == "" do return
	// the numbered folders under dir, newest (largest) first (names only: nothing statted)
	numbered :: proc(dir: string) -> []string {
		list := make([dynamic]string, context.temp_allocator)
		for e in dir_entries(dir) {
			if e.type != .DIR && e.type != .UNKNOWN do continue
			digits := true
			for ch in transmute([]u8)e.name do if ch < '0' || ch > '9' do digits = false
			if !digits do continue
			p := strings.concatenate({dir, "/", e.name}, context.temp_allocator)
			if e.type == .UNKNOWN && path_kind_nofollow(p) != .DIR do continue
			append(&list, p)
		}
		slice.sort_by(list[:], proc(a, b: string) -> bool {return a > b})
		return list[:]
	}
	seen := make(map[string]int, allocator = context.temp_allocator) // id -> its index in out
	dirs := 0
	for y in numbered(root) {
		if dirs >= CODEX_DISK_DIRS_MAX do return
		dirs += 1
		for m in numbered(y) {
			if dirs >= CODEX_DISK_DIRS_MAX do return
			dirs += 1
			for d in numbered(m) {
				if dirs >= CODEX_DISK_DIRS_MAX || len(out) >= CODEX_DISK_FILES_MAX do return
				dirs += 1
				// the rollouts' names first (no stat); only those are statted
				names := make([dynamic]string, context.temp_allocator)
				for e in dir_entries(d) {
					if e.type != .REG && e.type != .UNKNOWN do continue
					if strings.has_prefix(e.name, "rollout-") do append(&names, e.name)
				}
				slice.sort_by(names[:], proc(a, b: string) -> bool {return a > b})
				for n in names {
					if len(out) >= CODEX_DISK_FILES_MAX do break
					name, zst := codex_rollout_stem(n)
					if name == "" || len(name) < 37 || name[len(name) - 37] != '-' do continue
					id := name[len(name) - 36:]
					if !codex_id_ok(id) do continue
					path := strings.concatenate({d, "/", n}, context.temp_allocator)
					e, err := os.lstat(path, context.temp_allocator)
					if err != nil || e.type != .Regular do continue
					created := e.creation_time != {} ? e.creation_time : e.modification_time
					f := Disk_File{id = id, path = path, account = home, size = e.size, modified = e.modification_time, created = created}
					// one row an id: the plain file when Codex has left both (it compresses a copy)
					if i, dup := seen[id]; dup {
						if !zst && strings.has_suffix(out[i].path, ".zst") do out[i] = f
						continue
					}
					seen[id] = len(out)
					append(&out, f)
				}
			}
		}
	}
}

// A folder's entry as readdir gives it: its name (temp) and type (UNKNOWN on a file system that
// does not say).
@(private = "file")
Dir_Entry :: struct {
	name: string,
	type: posix.D_Type,
}

// The entries of dir, read one at a time and at most codex_disk_dir_entries_max of them (past it
// the folder counts as cut short): never all of a folder of millions statted, kept and sorted.
// "." and ".." left out. Any thread. Temp.
@(private = "file")
dir_entries :: proc(dir: string) -> []Dir_Entry {
	out := make([dynamic]Dir_Entry, context.temp_allocator)
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil do return nil
	defer posix.closedir(d)
	n := 0
	for n < codex_disk_dir_entries_max {
		e := posix.readdir(d)
		if e == nil do break
		n += 1
		name := string(cstring(raw_data(e.d_name[:])))
		if name == "." || name == ".." || name == "" do continue
		append(&out, Dir_Entry{name = strings.clone(name, context.temp_allocator), type = e.d_type})
	}
	sync.atomic_add(&codex_disk_entries_seen, i64(n))
	return out[:]
}

// Whether path is a folder, not following a link (an entry readdir did not type).
@(private = "file")
path_kind_nofollow :: proc(path: string) -> posix.D_Type {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK do return .UNKNOWN
	if posix.S_ISDIR(st.st_mode) do return .DIR
	return .UNKNOWN
}

// ---- the saved meta cache and the titles (a worker) ----
//
// codex_disk_refresh (the scan, main thread) starts a pass on a worker, at most one at a time and
// one per codex_disk_gap: the saved file read (once a run), every home listed, the entries of
// files gone dropped, session_index.jsonl read again where its size or mtime changed, then the
// first line of each new or changed rollout read, CODEX_BATCH at a time, the rows made again after
// each batch (claude_disk_tick); the file saved at the end when anything changed.
//
// The saved file (CODEX_CACHE_FILE in the data dir, as titles.odin's: 0600, written atomically):
// a version line, then one line per rollout: size, mtime (ns), created (ns), source, id, account,
// cwd, path, tab-separated (an entry with a tab or a line break in it is not saved: read again).
// A different version, a file over CODEX_CACHE_BYTES_MAX or a line that does not parse is not
// used (those rollouts are read again); at most CODEX_CACHE_MAX entries.

CODEX_SOURCE_MAX :: 32 // bytes of a rollout's source kept
CODEX_CACHE_FILE :: "codex-sessions.tsv"
@(private = "file")
CODEX_CACHE_VERSION :: "deckhand codex sessions 1"
CODEX_CACHE_MAX :: 100_000 // rollouts known (and saved): a hard ceiling
@(private = "file")
CODEX_CACHE_BYTES_MAX :: 64 << 20 // a bigger saved file is not read
@(private = "file")
CODEX_CACHE_ROW_MAX :: 16 * 1024 // a saved row longer than this is not used (a path and a cwd fit far within it)
@(private = "file")
CODEX_BATCH :: 64 // first lines read between two showings of the rows
CODEX_INDEX_FILE :: "session_index.jsonl"
@(private = "file")
CODEX_INDEX_BYTES_MAX :: 16 << 20 // read of a home's session_index.jsonl: its last 16 MB
@(private = "file")
CODEX_INDEX_LINE_MAX :: 16 * 1024 // a longer index line is skipped

// The least time between the starts of two passes (tests: 0).
codex_disk_gap := 10 * time.Second

// What the cache knows of a rollout (by its path). Strings: heap.
@(private = "file")
Codex_Meta :: struct {
	size, mtime, created:     i64, // mtime and created: ns
	id, cwd, source, account: string, // source "" = not a conversation to list (skip, a sub-agent's)
}

// A home's session_index.jsonl as last read.
@(private = "file")
Codex_Index :: struct {
	size, mtime: i64,
	titles:      map[string]string, // id -> title; heap
}

@(private = "file")
codex_cache: struct {
	mu:      sync.Mutex,
	entries: map[string]Codex_Meta, // keys: heap
	index:   map[string]Codex_Index, // by home; keys: heap
	homes:   [dynamic]Disk_Home, // the next pass's homes (heap)
	file:    string, // the saved cache ("" = not saved); heap
	loaded:  bool, // the saved file was read (once a run)
	running: bool, // a pass is on
	changed: bool, // the rows are to be made again (claude_disk_tick)
	started: time.Tick, // the last pass's start
}

// A row's source the list shows: the CLI's and Codex Desktop's; never `codex exec`'s, a
// sub-agent's (no string: "") or one Deckhand does not know.
codex_source_listed :: proc(source: string) -> bool {
	return source == "cli" || source == "vscode"
}

// A listed rollout of a folder's, for the scan. Temp.
Codex_Found :: struct {
	id, account, title: string,
	modified, created:  time.Time,
}

// The listed rollouts (codex_source_listed) whose cwd is cwd or real, byte for byte, newest first,
// with their titles (session_index.jsonl; "" = none). Only the cache: no file is read. Main
// thread. Temp.
codex_disk_found :: proc(cwd, real: string) -> []Codex_Found {
	out := make([dynamic]Codex_Found, context.temp_allocator)
	sync.lock(&codex_cache.mu)
	for _, e in codex_cache.entries {
		if !codex_source_listed(e.source) || e.cwd == "" || (e.cwd != cwd && e.cwd != real) do continue
		title := ""
		if ix, ok := codex_cache.index[e.account]; ok do title = ix.titles[e.id]
		append(&out, Codex_Found{id = strings.clone(e.id, context.temp_allocator), account = strings.clone(e.account, context.temp_allocator), title = strings.clone(title, context.temp_allocator), modified = {_nsec = e.mtime}, created = {_nsec = e.created}})
	}
	sync.unlock(&codex_cache.mu)
	slice.sort_by(out[:], proc(a, b: Codex_Found) -> bool {return a.modified._nsec > b.modified._nsec})
	return out[:]
}

// The saved cache goes in dir (the data dir; titles_load) from now on, read by the next pass.
codex_disk_cache_at :: proc(dir: string) {
	heap := runtime.heap_allocator()
	path, _ := filepath.join({dir, CODEX_CACHE_FILE}, heap)
	sync.lock(&codex_cache.mu)
	defer sync.unlock(&codex_cache.mu)
	delete(codex_cache.file, heap)
	codex_cache.file = path
	codex_cache.loaded = false
}

// A pass over the Codex homes on the worker, unless one is on or started less than
// codex_disk_gap ago. Main thread (the scan).
codex_disk_refresh :: proc() {
	codex_disk_start(disk_homes(.Codex))
}

// A pass over homes on the worker, unless one is on, or (unless forced) started less than
// codex_disk_gap ago. Never waits. Main thread.
codex_disk_start :: proc(homes: []Disk_Home, force := false) {
	heap := runtime.heap_allocator()
	sync.lock(&codex_cache.mu)
	defer sync.unlock(&codex_cache.mu)
	if codex_cache.running || (!force && codex_cache.started != {} && time.tick_since(codex_cache.started) < codex_disk_gap) do return
	for h in codex_cache.homes {
		delete(h.account, heap)
		delete(h.root, heap)
	}
	clear(&codex_cache.homes)
	if codex_cache.homes.allocator.procedure == nil do codex_cache.homes = make([dynamic]Disk_Home, heap)
	for h in homes do append(&codex_cache.homes, Disk_Home{account = strings.clone(h.account, heap), root = strings.clone(h.root, heap)})
	codex_cache.running = true
	codex_cache.started = time.tick_now()
	context.allocator = heap // the thread frees itself with it
	thread.create_and_start(codex_pass, runtime.default_context(), self_cleanup = true)
}

// Whether the rows are to be made again (a pass stored something), and from now on not. Main thread.
codex_disk_take_changed :: proc() -> bool {
	sync.lock(&codex_cache.mu)
	defer sync.unlock(&codex_cache.mu)
	c := codex_cache.changed
	codex_cache.changed = false
	return c
}

// Whether a pass is on (tests wait on it).
codex_disk_busy :: proc() -> bool {
	sync.lock(&codex_cache.mu)
	defer sync.unlock(&codex_cache.mu)
	return codex_cache.running
}

// A pass over homes now, on the calling thread (the Rescan's scan, claude_scan_projects), after
// any pass already on; whatever the gap. With the cache warm it reads no rollout.
codex_disk_pass_now :: proc(homes: []Disk_Home) {
	codex_disk_passes_inline += 1
	heap := runtime.heap_allocator()
	for {
		sync.lock(&codex_cache.mu)
		if !codex_cache.running {
			for h in codex_cache.homes {
				delete(h.account, heap)
				delete(h.root, heap)
			}
			clear(&codex_cache.homes)
			if codex_cache.homes.allocator.procedure == nil do codex_cache.homes = make([dynamic]Disk_Home, heap)
			for h in homes do append(&codex_cache.homes, Disk_Home{account = strings.clone(h.account, heap), root = strings.clone(h.root, heap)})
			codex_cache.running = true
			codex_cache.started = time.tick_now()
			sync.unlock(&codex_cache.mu)
			break
		}
		sync.unlock(&codex_cache.mu)
		time.sleep(5 * time.Millisecond)
	}
	// its own scratch: the caller's temp data stays
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	codex_pass_run()
}

// A folder Codex ran in (a listed rollout's cwd, clean and absolute) and its newest and oldest
// rollout's dates. Temp.
Codex_Folder :: struct {
	cwd:            string,
	newest, oldest: time.Time,
}

// The folders of the listed rollouts (codex_source_listed) of homes' accounts, from the cache only.
// Any thread. Temp.
codex_disk_folders :: proc(homes: []Disk_Home) -> []Codex_Folder {
	out := make([dynamic]Codex_Folder, context.temp_allocator)
	sync.lock(&codex_cache.mu)
	defer sync.unlock(&codex_cache.mu)
	at := make(map[string]int, context.temp_allocator) // cwd -> its index in out
	for _, e in codex_cache.entries {
		if !codex_source_listed(e.source) || e.cwd == "" do continue
		mine := false
		for h in homes do if h.account == e.account do mine = true
		if !mine do continue
		t := time.Time{_nsec = e.mtime}
		if i, ok := at[e.cwd]; ok {
			f := &out[i]
			if t._nsec > f.newest._nsec do f.newest = t
			if t._nsec < f.oldest._nsec do f.oldest = t
			continue
		}
		c := strings.clone(e.cwd, context.temp_allocator)
		at[c] = len(out)
		append(&out, Codex_Folder{cwd = c, newest = t, oldest = t})
	}
	return out[:]
}

@(private = "file")
meta_free :: proc(m: ^Codex_Meta) {
	heap := runtime.heap_allocator()
	delete(m.id, heap)
	delete(m.cwd, heap)
	delete(m.source, heap)
	delete(m.account, heap)
	m^ = {}
}

// A source as kept: letters, digits, '_', '-' and '.' only, else "?" (one Deckhand does not know).
@(private = "file")
source_kept :: proc(s: string) -> string {
	for ch in transmute([]u8)s do if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-' || ch == '.') do return "?"
	return cut_utf8(s, CODEX_SOURCE_MAX)
}

// Stores what a rollout's first line says (under the lock).
@(private = "file")
meta_put :: proc(f: Disk_File, cwd, source: string) {
	heap := runtime.heap_allocator()
	m := Codex_Meta{size = f.size, mtime = f.modified._nsec, created = f.created._nsec, id = strings.clone(f.id, heap), cwd = strings.clone(cwd, heap), source = strings.clone(source_kept(source), heap), account = strings.clone(f.account, heap)}
	if e, ok := &codex_cache.entries[f.path]; ok {
		meta_free(e)
		e^ = m
		return
	}
	if len(codex_cache.entries) >= CODEX_CACHE_MAX {
		meta_free(&m)
		return
	}
	codex_cache.entries[strings.clone(f.path, heap)] = m
}

@(private = "file")
codex_publish :: proc() {
	sync.lock(&codex_cache.mu)
	codex_cache.changed = true
	sync.unlock(&codex_cache.mu)
	if platform.wake != nil do platform.wake()
}

// The worker of codex_disk_refresh: one pass.
@(private = "file")
codex_pass :: proc() {
	codex_pass_run()
	free_all(context.temp_allocator)
}

// One pass, by the thread that set running (codex_disk_refresh's worker, codex_disk_pass_now). Temp.
@(private = "file")
codex_pass_run :: proc() {
	heap := runtime.heap_allocator()
	sync.lock(&codex_cache.mu)
	homes := make([]Disk_Home, len(codex_cache.homes), context.temp_allocator)
	for h, i in codex_cache.homes do homes[i] = {account = strings.clone(h.account, context.temp_allocator), root = strings.clone(h.root, context.temp_allocator)}
	file := strings.clone(codex_cache.file, context.temp_allocator)
	load := !codex_cache.loaded && file != ""
	if load do codex_cache.loaded = true
	sync.unlock(&codex_cache.mu)

	saved: map[string]Codex_Meta // temp
	if load do saved = codex_cache_read(file)
	files := disk_files(.Codex, homes)
	todo := make([dynamic]Disk_File, context.temp_allocator)
	dirty, changed := false, false
	{
		sync.lock(&codex_cache.mu)
		defer sync.unlock(&codex_cache.mu)
		if codex_cache.entries.allocator.procedure == nil do codex_cache.entries = make(map[string]Codex_Meta, heap)
		seen := make(map[string]bool, len(files), context.temp_allocator)
		for f in files do seen[f.path] = true
		// files gone (or no longer listed: a home removed, past a ceiling)
		gone := make([dynamic]string, context.temp_allocator)
		for k in codex_cache.entries do if !seen[k] do append(&gone, k)
		for k in gone {
			e := codex_cache.entries[k]
			meta_free(&e)
			delete_key(&codex_cache.entries, k)
			delete(k, heap)
		}
		if len(gone) > 0 do dirty, changed = true, true
		carried := 0
		for f in files {
			if e, ok := codex_cache.entries[f.path]; ok {
				if e.size != f.size || e.mtime != f.modified._nsec do append(&todo, f)
				continue
			}
			if s, ok := saved[f.path]; ok && s.size == f.size && s.mtime == f.modified._nsec && s.id == f.id {
				meta_put(f, s.cwd, s.source)
				carried += 1
				changed = true
				continue
			}
			append(&todo, f)
		}
		if load && carried != len(saved) do dirty = true
	}
	if codex_index_refresh(homes) do changed = true
	if changed do codex_publish()
	// the first lines, each read in a scratch arena (a pass may read thousands)
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	for f, i in todo {
		{
			context.temp_allocator = virtual.arena_allocator(&scratch)
			cwd, source, skip, unreadable := disk_first_line(.Codex, f.path)
			if skip do cwd, source = "", ""
			else do cwd, _ = filepath.clean(cwd, context.temp_allocator) // as a project's cwd (a trailing slash, "/./")
			// not readable now (permissions, an I/O error): not remembered, so the next pass reads
			// it again (once a pass); only what was read and found wanting is kept
			if !unreadable {
				sync.lock(&codex_cache.mu)
				meta_put(f, cwd, source)
				sync.unlock(&codex_cache.mu)
				dirty = true
			}
		}
		free_all(virtual.arena_allocator(&scratch))
		if (i + 1) % CODEX_BATCH == 0 || i == len(todo) - 1 do codex_publish()
	}
	if dirty && file != "" do codex_cache_save(file)
	sync.lock(&codex_cache.mu)
	codex_cache.running = false
	sync.unlock(&codex_cache.mu)
	if platform.wake != nil do platform.wake()
}

// The saved cache's entries (by path), what of it parses. The worker. Temp.
@(private = "file")
codex_cache_read :: proc(file: string) -> map[string]Codex_Meta {
	out := make(map[string]Codex_Meta, context.temp_allocator)
	fi, err := os.stat(file, context.temp_allocator)
	if err != nil || fi.type != .Regular || fi.size > CODEX_CACHE_BYTES_MAX do return out
	data, rerr := os.read_entire_file(file, context.temp_allocator)
	if rerr != nil do return out
	text := string(data)
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first {
			first = false
			if line != CODEX_CACHE_VERSION do return out
			continue
		}
		if len(out) >= CODEX_CACHE_MAX do break
		// a row as codex_cache_save writes one: never split a long or many-tabbed line
		if len(line) > CODEX_CACHE_ROW_MAX || strings.count(line, "\t") != 7 do continue
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) != 8 do continue
		size, ok1 := strconv.parse_i64(f[0])
		mtime, ok2 := strconv.parse_i64(f[1])
		created, ok3 := strconv.parse_i64(f[2])
		source, id, account, cwd, path := f[3], f[4], f[5], f[6], f[7]
		if !ok1 || !ok2 || !ok3 || size < 0 || !codex_id_ok(id) || !filepath.is_abs(path) || !filepath.is_abs(account) do continue
		if source_kept(source) != source || strings.index_byte(line, 0) >= 0 do continue
		if cwd != "" && (!filepath.is_abs(cwd) || len(cwd) > CODEX_CWD_MAX) do continue
		if cwd != "" do cwd, _ = filepath.clean(cwd, context.temp_allocator)
		out[path] = {size = size, mtime = mtime, created = created, id = id, cwd = cwd, source = source, account = account}
	}
	return out
}

// Writes the cache (codex_cache_read's format). The worker.
@(private = "file")
codex_cache_save :: proc(file: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, CODEX_CACHE_VERSION)
	strings.write_byte(&b, '\n')
	sync.lock(&codex_cache.mu)
	for p, e in codex_cache.entries {
		if strings.contains_any(p, "\t\n\r") || strings.contains_any(e.cwd, "\t\n\r") || strings.contains_any(e.account, "\t\n\r") do continue
		fmt.sbprintf(&b, "%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", e.size, e.mtime, e.created, e.source, e.id, e.account, e.cwd, p)
	}
	sync.unlock(&codex_cache.mu)
	if err := write_atomic(file, strings.to_string(b)); err != "" do log_ln("Deckhand: could not save the Codex session cache:", err)
}

// A title from session_index.jsonl as other titles are shown: one line, control characters and
// invalid UTF-8 replaced (clean_title), invisible characters dropped (one_line), at most
// CLAUDE_TITLE_MAX bytes. Temp.
@(private = "file")
codex_title_clean :: proc(s: string) -> string {
	return cut_utf8(strings.trim_space(one_line(clean_title(s, context.temp_allocator), context.temp_allocator)), CLAUDE_TITLE_MAX)
}

// Each home's session_index.jsonl read again where its size or mtime changed (only its last
// CODEX_INDEX_BYTES_MAX; lines over CODEX_INDEX_LINE_MAX skipped); a home gone, or its file, forgotten.
// Never written. Whether anything changed. The worker.
@(private = "file")
codex_index_refresh :: proc(homes: []Disk_Home) -> (changed: bool) {
	heap := runtime.heap_allocator()
	forget :: proc(k: string) {
		heap := runtime.heap_allocator()
		ix := codex_cache.index[k]
		for id, t in ix.titles {
			delete(id, heap)
			delete(t, heap)
		}
		delete(ix.titles)
		key := k
		delete_key(&codex_cache.index, k)
		delete(key, heap)
	}
	for h in homes {
		path := strings.concatenate({h.account, "/", CODEX_INDEX_FILE}, context.temp_allocator)
		// never a FIFO or a link (open would block, or go elsewhere)
		fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .NOFOLLOW, .CLOEXEC})
		st: posix.stat_t
		if fd < 0 || posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) {
			if fd >= 0 do posix.close(fd)
			sync.lock(&codex_cache.mu)
			if h.account in codex_cache.index {
				for k in codex_cache.index do if k == h.account {
					forget(k)
					break
				}
				changed = true
			}
			sync.unlock(&codex_cache.mu)
			continue
		}
		size := i64(st.st_size)
		mtime := i64(st.st_mtim.tv_sec) * 1e9 + i64(st.st_mtim.tv_nsec)
		sync.lock(&codex_cache.mu)
		old, had := codex_cache.index[h.account]
		sync.unlock(&codex_cache.mu)
		if had && old.size == size && old.mtime == mtime {
			posix.close(fd)
			continue
		}
		start := max(0, size - CODEX_INDEX_BYTES_MAX)
		buf := make([]u8, size - start, context.temp_allocator)
		got := 0
		for got < len(buf) {
			want := len(buf) - got
			n := int(posix.pread(fd, raw_data(buf[got:]), uint(want), posix.off_t(start + i64(got))))
			if n <= 0 do break
			got += n
		}
		posix.close(fd)
		text := string(buf[:got])
		if start > 0 { // it starts inside a line
			nl := strings.index_byte(text, '\n')
			text = nl >= 0 ? text[nl + 1:] : ""
		}
		titles := make(map[string]string, heap)
		for line in strings.split_lines_iterator(&text) {
			if len(line) < 2 || len(line) > CODEX_INDEX_LINE_MAX || line[0] != '{' || !json_depth_ok(line) do continue
			v, perr := jg.parse(transmute([]u8)line, .JSON, false, context.temp_allocator)
			if perr != nil do continue
			o, _ := v.(json.Object)
			id, _ := o["id"].(json.String)
			name, nok := o["thread_name"].(json.String)
			if !nok || !codex_id_ok(string(id)) do continue
			t := strings.clone(codex_title_clean(string(name)), heap)
			if prev, ok := &titles[string(id)]; ok {
				delete(prev^, heap)
				prev^ = t
			} else do titles[strings.clone(string(id), heap)] = t
		}
		sync.lock(&codex_cache.mu)
		if codex_cache.index.allocator.procedure == nil do codex_cache.index = make(map[string]Codex_Index, heap)
		for k in codex_cache.index do if k == h.account {
			forget(k)
			break
		}
		codex_cache.index[strings.clone(h.account, heap)] = {size = size, mtime = mtime, titles = titles}
		sync.unlock(&codex_cache.mu)
		changed = true
	}
	// homes no longer listed
	sync.lock(&codex_cache.mu)
	defer sync.unlock(&codex_cache.mu)
	stale := make([dynamic]string, context.temp_allocator)
	for k in codex_cache.index {
		kept := false
		for h in homes do if h.account == k do kept = true
		if !kept do append(&stale, k)
	}
	for k in stale do forget(k)
	if len(stale) > 0 do changed = true
	return
}

when TEST_HOOKS {
	// The rows of a saved cache file that would be used (tests).
	codex_disk_cache_rows :: proc(file: string) -> int {
		return len(codex_cache_read(file))
	}

	// Forgets everything, the saved file's place too (tests); waits for a pass first.
	codex_disk_cache_clear :: proc() {
		for codex_disk_busy() do time.sleep(time.Millisecond)
		heap := runtime.heap_allocator()
		sync.lock(&codex_cache.mu)
		defer sync.unlock(&codex_cache.mu)
		for k, &e in codex_cache.entries {
			meta_free(&e)
			delete(k, heap)
		}
		clear(&codex_cache.entries)
		ks := make([dynamic]string, context.temp_allocator)
		for k in codex_cache.index do append(&ks, k)
		for k in ks {
			ix := codex_cache.index[k]
			for id, t in ix.titles {
				delete(id, heap)
				delete(t, heap)
			}
			delete(ix.titles)
			delete_key(&codex_cache.index, k)
			delete(k, heap)
		}
		delete(codex_cache.file, heap)
		codex_cache.file = ""
		codex_cache.loaded = false
		codex_cache.changed = false
		codex_cache.started = {}
	}
}
