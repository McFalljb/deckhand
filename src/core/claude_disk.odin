package core

// Claude Code sessions started outside Deckhand, as rows (docs/CLAUDE.md §4c). For the selected
// project (and Chats), each account's <config>/projects/<folder>/<session id>.jsonl, where
// <folder> is Claude Code's name for the project's folder (claude_project_slug: computed from
// the project's path and its real path, never turned back into a path). When that name is not
// certain (a path with non-ASCII characters, one over 200 characters, or the one folder
// CLAUDE_CODE_PROJECT_DIR_NAME puts every project in), only transcripts whose recorded `cwd`
// is the project's folder (its real path) count.
//
//   - Rows: newest first with pi's (the file's modification time; its birth time is "created"),
//     at most MAX_SESSIONS per list; never a sidechain transcript (the first entry says
//     isSidechain) nor a subagent's (agent-*.jsonl, or the session's own subagents/ folder, which
//     is never listed); never one Deckhand already has (its history: that row, with this file's
//     created date) or a pi session's id. Titles: the user's /rename (custom-title, last wins),
//     else the first real prompt (not meta, a command, a command's output, a system reminder or a
//     sidechain; its first line, at most 80 characters), else Claude's own title (ai-title), else
//     a summary. Read from the file's first and last 64 KB only, as Claude Code's own resume
//     list does; within the listing's byte budget on the main thread (TITLE_INLINE_BUDGET), the
//     rest on a worker, then the rows are made again. Never saved, never given to agents beyond
//     the row (id, title, times, account label): no path.
//   - Deckhand's own history entries whose transcript is gone (Claude Code deletes transcripts
//     after cleanupPeriodDays, 30 by default; `claude` purge or a hand rm) show greyed: decided
//     by stat (the file it reported, else its account's folder for the project).
//   - A click resumes the conversation in a Claude-only session under its account, by the
//     transcript's absolute path (--resume <path>), with no flags (claude_disk_resume).
//   - Codex conversations (codex_disk_files, docs/CODEX.md §2b): the newest rollouts in Codex's
//     sessions/YYYY/MM/DD folders, read through the same cache and worker, but only their first
//     line (session_meta: its id and cwd); rows with no title and no path, resumed by id.
//   - Projects where only Claude ran (scan_projects, on the Rescan worker): every folder under
//     each account's projects/ whose newest transcript records a `cwd` whose own folder name is
//     that folder's; never a folder decoded from its name.

import "base:runtime"
import "core:encoding/json"
import jg "../jsonguard"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

CLAUDE_DISK_CHUNK :: 64 * 1024 // the head and the tail of a transcript read for its title (Claude Code's own)

// A Claude transcript of the listed project's: a row of its own (listed), or what the scan knows
// of one Deckhand's history has (its created date, or that its transcript is gone).
Claude_Disk :: struct {
	id:       string,
	path:     string, // the transcript (never in the snapshot)
	account:  string, // its config folder
	title:    string,
	modified: time.Time,
	created:  time.Time,
	listed:   bool, // a row of its own: Deckhand's history does not have it
	gone:     bool, // a history entry whose transcript is gone (no file)
	codex:    bool, // a Codex conversation (codex_disk_files): no path kept, resumed by id
}

// The title cache's size (tests lower it).
claude_disk_cache_max := 20_000
// Bytes a listing reads on the main thread (tests lower it).
claude_disk_inline_budget := i64(TITLE_INLINE_BUDGET)

// Whether the launch needs a Rescan for Claude's projects (any account has a projects/ folder):
// after the saved accounts are back (main.odin).
claude_startup_rescan_due :: proc() -> bool {
	for p in state.projects do if p.claude do return true // saved: confirmed or dropped
	for a in claude_accounts() do if path_kind(strings.concatenate({a.dir, "/projects"}, context.temp_allocator)) == .Dir do return true
	return false
}

// Bytes read from Claude transcripts (tests).
claude_disk_bytes_read: i64

@(private = "file")
found_arena: virtual.Arena
@(private = "file")
found_chats_arena: virtual.Arena

// ---- one transcript's head and tail ----

@(private = "file")
Found_Info :: struct {
	size:      i64,
	mtime:     i64,
	title:     string, // heap
	cwd:       string, // heap; "" = none in the head
	sidechain: bool,
}

@(private = "file")
found_cache: struct {
	mu:      sync.Mutex,
	entries: map[string]Found_Info, // keys: heap
	order:   [dynamic]string, // the keys, oldest first (a full cache drops the oldest)
	queue:   [dynamic]string,
	queued:  map[string]bool,
	running: bool,
	changed: bool,
}

// A transcript line Deckhand hands to the JSON parser: at most one chunk long and nested at most
// JSON_MAX_DEPTH (the parser recurses: a line 20,000 deep would overflow the stack, and the
// launch's scan would crash every start).
@(private = "file")
line_parsable :: proc(line: string) -> bool {
	return len(line) <= CLAUDE_DISK_CHUNK && json_depth_ok(line)
}

// Reads a transcript's head and tail (at most CLAUDE_DISK_CHUNK each). Any thread.
@(private = "file")
found_read :: proc(path: string, size: i64) -> (title, cwd: string, sidechain: bool) {
	if strings.has_prefix(filepath.base(path), "rollout-") {
		cwd, sidechain = codex_first_line(path)
		return
	}
	f, err := os.open(path)
	if err != nil do return
	defer os.close(f)
	// up to two chunks: the whole file as one (no line cut between a head and a tail)
	head_n := size <= 2 * i64(CLAUDE_DISK_CHUNK) ? size : i64(CLAUDE_DISK_CHUNK)
	head := make([]u8, head_n, context.temp_allocator)
	got, _ := os.read_at(f, head, 0)
	sync.atomic_add(&claude_disk_bytes_read, i64(got))
	head = head[:max(got, 0)]
	tail: []u8
	if size > head_n {
		start := max(head_n, size - i64(CLAUDE_DISK_CHUNK))
		tail = make([]u8, size - start, context.temp_allocator)
		tg, _ := os.read_at(f, tail, start)
		sync.atomic_add(&claude_disk_bytes_read, i64(tg))
		tail = tail[:max(tg, 0)]
		// it starts inside a line (unless right after the head)
		if start > head_n {
			if nl := strings.index_byte(string(tail), '\n'); nl >= 0 do tail = tail[nl + 1:]
			else do tail = nil
		}
	}
	first, custom, ai, summary: string
	decided := false // the first entry with isSidechain said which kind of file this is
	look :: proc(text: string, in_head: bool, first, custom, ai, summary, cwd: ^string, sidechain, decided: ^bool) {
		rest := text
		for {
			nl := strings.index_byte(rest, '\n')
			if nl < 0 do break // a cut-off last line
			line := rest[:nl]
			rest = rest[nl + 1:]
			if len(line) < 2 || line[0] != '{' do continue
			wanted := strings.contains(line, `"custom-title"`) || strings.contains(line, `"ai-title"`) || strings.contains(line, `"summary"`) || strings.contains(line, `"isSidechain"`) || strings.contains(line, `"cwd"`)
			if !wanted || !line_parsable(line) do continue
			v, perr := jg.parse(transmute([]u8)line, .JSON, false, context.temp_allocator) // strict: JSON5's quotes would hide brackets from line_parsable
			if perr != nil do continue
			o, ok := v.(json.Object)
			if !ok do continue
			typ, _ := o["type"].(json.String)
			switch typ {
			case "custom-title":
				if t, tok := o["customTitle"].(json.String); tok do custom^ = t
				continue
			case "ai-title":
				if t, tok := o["aiTitle"].(json.String); tok do ai^ = t
				continue
			case "summary":
				if t, tok := o["summary"].(json.String); tok do summary^ = t
				continue
			}
			if !in_head do continue
			if c, cok := o["cwd"].(json.String); cok && cwd^ == "" do cwd^ = c
			sc, has_sc := o["isSidechain"].(json.Boolean)
			if has_sc && !decided^ {
				decided^ = true
				sidechain^ = bool(sc)
			}
			if typ != "user" || first^ != "" || bool(sc) do continue
			if m, _ := o["isMeta"].(json.Boolean); m do continue
			if m, _ := o["isCompactSummary"].(json.Boolean); m do continue
			msg, _ := o["message"].(json.Object)
			if role, _ := msg["role"].(json.String); role != "user" do continue
			text: string
			#partial switch c in msg["content"] {
			case json.String:
				text = string(c)
			case json.Array:
				for part in c {
					po, _ := part.(json.Object)
					if pt, _ := po["type"].(json.String); pt != "text" do continue
					t, _ := po["text"].(json.String)
					text = string(t)
					break
				}
			}
			t := strings.trim_space(text)
			if t == "" do continue
			skip := false
			for pre in ([]string{"<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<bash-input>", "<bash-stdout>", "<bash-stderr>", "<system-reminder>", "<user-memory-input>", "[Request interrupted", "Caveat:"}) do if strings.has_prefix(t, pre) do skip = true
			if skip do continue
			if nl2 := strings.index_byte(t, '\n'); nl2 >= 0 do t = t[:nl2]
			first^ = t
		}
	}
	look(string(head), true, &first, &custom, &ai, &summary, &cwd, &sidechain, &decided)
	if size <= head_n && len(head) > 0 && head[len(head) - 1] != '\n' {
		// a whole file without a final newline: its last line counts too
		look(strings.concatenate({string(head[strings.last_index_byte(string(head), '\n') + 1:]), "\n"}, context.temp_allocator), true, &first, &custom, &ai, &summary, &cwd, &sidechain, &decided)
	}
	if tail != nil do look(string(tail), false, &first, &custom, &ai, &summary, &cwd, &sidechain, &decided)
	title = custom
	if title == "" do title = first
	if title == "" do title = ai
	if title == "" do title = summary
	title = cut_utf8(strings.trim_space(one_line(title, context.temp_allocator)), CLAUDE_TITLE_MAX)
	return
}

@(private = "file")
found_store :: proc(path: string, size, mtime: i64, title, cwd: string, sidechain: bool) {
	heap := runtime.heap_allocator()
	sync.lock(&found_cache.mu)
	defer sync.unlock(&found_cache.mu)
	if found_cache.entries.allocator.procedure == nil do found_cache.entries = make(map[string]Found_Info, heap)
	if e, ok := &found_cache.entries[path]; ok {
		delete(e.title, heap)
		delete(e.cwd, heap)
		e^ = {size = size, mtime = mtime, title = strings.clone(title, heap), cwd = strings.clone(cwd, heap), sidechain = sidechain}
		return
	}
	if found_cache.order.allocator.procedure == nil do found_cache.order = make([dynamic]string, heap)
	// full (far beyond any listing): the oldest goes, so a new one is always kept (else the
	// worker would read it, the rows ask again, and so on)
	for len(found_cache.entries) >= max(claude_disk_cache_max, 1) && len(found_cache.order) > 0 {
		old := pop_front(&found_cache.order)
		if e, ok := found_cache.entries[old]; ok {
			delete(e.title, heap)
			delete(e.cwd, heap)
		}
		delete_key(&found_cache.entries, old)
		delete(old, heap)
	}
	k := strings.clone(path, heap)
	found_cache.entries[k] = {size = size, mtime = mtime, title = strings.clone(title, heap), cwd = strings.clone(cwd, heap), sidechain = sidechain}
	append(&found_cache.order, k)
}

// The cached info of path at size and mtime; else read now within *budget, else queued for the
// worker (known = false). Main thread.
@(private = "file")
found_info :: proc(path: string, size: i64, mtime: time.Time, budget: ^i64) -> (title, cwd: string, sidechain, known: bool) {
	sync.lock(&found_cache.mu)
	if e, ok := found_cache.entries[path]; ok && e.size == size && e.mtime == mtime._nsec {
		title, cwd, sidechain = strings.clone(e.title, context.temp_allocator), strings.clone(e.cwd, context.temp_allocator), e.sidechain
		sync.unlock(&found_cache.mu)
		return title, cwd, sidechain, true
	}
	busy := found_cache.queued[path]
	sync.unlock(&found_cache.mu)
	cost := min(size, 2 * i64(CLAUDE_DISK_CHUNK))
	if busy || cost > budget^ {
		if !busy do found_enqueue(path)
		return "", "", false, false
	}
	budget^ -= cost
	title, cwd, sidechain = found_read(path, size)
	found_store(path, size, mtime._nsec, title, cwd, sidechain)
	return title, cwd, sidechain, true
}

@(private = "file")
found_enqueue :: proc(path: string) {
	heap := runtime.heap_allocator()
	sync.lock(&found_cache.mu)
	defer sync.unlock(&found_cache.mu)
	if found_cache.queued.allocator.procedure == nil do found_cache.queued = make(map[string]bool, heap)
	if found_cache.queue.allocator.procedure == nil do found_cache.queue = make([dynamic]string, heap)
	if found_cache.queued[path] do return
	p := strings.clone(path, heap)
	found_cache.queued[p] = true
	append(&found_cache.queue, p)
	if !found_cache.running {
		found_cache.running = true
		context.allocator = heap
		thread.create_and_start(found_worker, runtime.default_context(), self_cleanup = true)
	}
}

@(private = "file")
found_worker :: proc() {
	heap := runtime.heap_allocator()
	for {
		sync.lock(&found_cache.mu)
		if len(found_cache.queue) == 0 {
			found_cache.running = false
			sync.unlock(&found_cache.mu)
			return
		}
		path := pop_front(&found_cache.queue)
		sync.unlock(&found_cache.mu)
		if fi, err := os.stat(path, context.temp_allocator); err == nil {
			title, cwd, sc := found_read(path, fi.size)
			found_store(path, fi.size, fi.modification_time._nsec, title, cwd, sc)
		}
		sync.lock(&found_cache.mu)
		delete_key(&found_cache.queued, path)
		found_cache.changed = true
		sync.unlock(&found_cache.mu)
		delete(path, heap)
		free_all(context.temp_allocator)
		if platform.wake != nil do platform.wake()
	}
}

// Main thread, every frame (titles_tick): once the worker read transcripts, the rows are made
// again from the cache.
claude_disk_tick :: proc() {
	sync.lock(&found_cache.mu)
	changed := found_cache.changed
	found_cache.changed = false
	sync.unlock(&found_cache.mu)
	if !changed do return
	claude_disk_rescan()
	window_state_changed()
}

// Tests: waits for the worker, then makes the rows again.
claude_disk_wait :: proc() {
	for _ in 0 ..< 500 {
		sync.lock(&found_cache.mu)
		busy := found_cache.running || len(found_cache.queue) > 0
		sync.unlock(&found_cache.mu)
		if !busy do break
		time.sleep(10 * time.Millisecond)
	}
	claude_disk_tick()
}

// ---- Codex's conversations (~/.codex/sessions; codex.odin) ----

CODEX_DISK_DAYS_MAX :: 60 // day folders looked at, newest first
CODEX_DISK_FILES_MAX :: 400 // rollouts looked at, newest first
CODEX_DISK_LINE_MAX :: 64 * 1024 // a rollout's first line (session_meta, ~25 KB); longer: skipped
CODEX_CWD_MAX :: 1024 // a rollout's cwd; longer (or with a NUL): skipped, never walked

// A rollout's session_meta (its first line, at most CODEX_DISK_LINE_MAX, never more of the file):
// the cwd it ran in. skip: not a conversation to list (no session_meta, an id that is not the
// file's, a subagent's or another non-string source). Never written to; nothing in it reaches a
// shell or the screen (the cwd is only compared with the project's folder). Any thread.
codex_first_line :: proc(path: string) -> (cwd: string, skip: bool) {
	skip = true
	// never a FIFO or a link swapped in since the listing (open would block, or go elsewhere)
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .NOFOLLOW, .CLOEXEC})
	if fd < 0 do return
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) do return
	buf := make([]u8, CODEX_DISK_LINE_MAX, context.temp_allocator)
	got := int(posix.pread(fd, raw_data(buf), len(buf), 0))
	sync.atomic_add(&claude_disk_bytes_read, i64(max(got, 0)))
	nl := strings.index_byte(string(buf[:max(got, 0)]), '\n')
	if nl < 2 do return
	line := string(buf[:nl])
	if line[0] != '{' || !json_depth_ok(line) do return
	v, perr := jg.parse(transmute([]u8)line, .JSON, false, context.temp_allocator)
	if perr != nil do return
	o, _ := v.(json.Object)
	if t, _ := o["type"].(json.String); t != "session_meta" do return
	pl, _ := o["payload"].(json.Object)
	id, _ := pl["id"].(json.String)
	c, _ := pl["cwd"].(json.String)
	if _, src_ok := pl["source"].(json.String); !src_ok do return // a subagent's ({"subagent": …})
	name := strings.trim_suffix(filepath.base(path), ".jsonl")
	if !codex_id_ok(string(id)) || !strings.has_suffix(name, string(id)) || !filepath.is_abs(string(c)) do return
	if len(c) > CODEX_CWD_MAX || strings.index_byte(string(c), 0) >= 0 do return
	return string(c), false
}

// A rollout found on disk: its id (from its name), path, dates and the Codex home it is in. Temp.
@(private = "file")
Codex_File :: struct {
	id, path, account: string,
	size:              i64,
	modified, created: time.Time,
}

// A Codex home's sessions folder ("" = none; in tests and test mode never the developer's own
// ~/.codex: the default only when they set CODEX_HOME, ~/.codex of the real home never).
@(private = "file")
codex_sessions_dir :: proc(home: string) -> string {
	when TEST_HOOKS {
		if ODIN_TEST || test_mode() {
			if _, ok := env_lookup(child_base_env(), "CODEX_HOME"); !ok && home == codex_home() do return ""
			if real := account_home(); real != "" && home == strings.concatenate({strings.trim_right(real, "/"), "/.codex"}, context.temp_allocator) do return ""
		}
	}
	return home == "" ? "" : strings.concatenate({home, "/sessions"}, context.temp_allocator)
}

// The newest rollouts of each Codex account's home, by their folders' and names' dates
// (sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl): at most CODEX_DISK_DAYS_MAX day folders and
// CODEX_DISK_FILES_MAX files a home; regular files only. Temp.
@(private = "file")
codex_disk_files :: proc() -> []Codex_File {
	out := make([dynamic]Codex_File, context.temp_allocator)
	for a in claude_accounts(codex = true) do codex_disk_files_of(&out, a.dir)
	return out[:]
}

@(private = "file")
codex_disk_files_of :: proc(all: ^[dynamic]Codex_File, home: string) {
	out := make([dynamic]Codex_File, context.temp_allocator)
	defer append(all, ..out[:])
	root := codex_sessions_dir(home)
	if root == "" do return
	// the numbered folders under dir, newest (largest) first
	numbered :: proc(dir: string) -> []os.File_Info {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil do return nil
		list := make([dynamic]os.File_Info, context.temp_allocator)
		for e in entries {
			if e.type != .Directory || e.name == "" do continue
			digits := true
			for ch in transmute([]u8)e.name do if ch < '0' || ch > '9' do digits = false
			if digits do append(&list, e)
		}
		slice.sort_by(list[:], proc(a, b: os.File_Info) -> bool {return a.name > b.name})
		return list[:]
	}
	days := 0
	for y in numbered(root) {
		for m in numbered(y.fullpath) {
			for d in numbered(m.fullpath) {
				if days >= CODEX_DISK_DAYS_MAX || len(out) >= CODEX_DISK_FILES_MAX do return
				days += 1
				entries, err := os.read_all_directory_by_path(d.fullpath, context.temp_allocator)
				if err != nil do continue
				slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name > b.name})
				for e in entries {
					if len(out) >= CODEX_DISK_FILES_MAX do break
					if e.type != .Regular || !strings.has_prefix(e.name, "rollout-") || !strings.has_suffix(e.name, ".jsonl") do continue
					name := strings.trim_suffix(e.name, ".jsonl")
					if len(name) < 37 || name[len(name) - 37] != '-' do continue
					id := name[len(name) - 36:]
					if !codex_id_ok(id) do continue
					created := e.creation_time != {} ? e.creation_time : e.modification_time
					append(&out, Codex_File{id = id, path = e.fullpath, account = home, size = e.size, modified = e.modification_time, created = created})
				}
			}
		}
	}
}

// ---- where a project's transcripts are ----

@(private = "file")
Slug_Folder :: struct {
	path:   string,
	verify: bool, // the folder's name is not certain: only transcripts whose cwd is the project's
}

@(private = "file")
has_non_ascii :: proc(s: string) -> bool {
	for ch in transmute([]u8)s do if ch >= 0x80 do return true
	return false
}

// The part of the folder name that is certain: up to the first character that came from a
// non-ASCII one (which NFC or NFD would count otherwise), or the first 200.
@(private = "file")
slug_prefix :: proc(cwd: string) -> string {
	s := claude_project_slug(cwd)
	n := 0
	for i := 0; i < len(cwd); i += 1 {
		if cwd[i] >= 0x80 do break
		n += 1
	}
	return s[:min(n, len(s), CLAUDE_SLUG_MAX)]
}

// The folders under root (an account's projects/) that may hold cwd's transcripts. Temp.
@(private = "file")
slug_folders :: proc(root, cwd, account: string) -> []Slug_Folder {
	out := make([dynamic]Slug_Folder, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	real := fs_real(cwd)
	for c in ([2]string{cwd, real}) {
		n := claude_project_slug(c)
		if !slice.contains(names[:], n) do append(&names, n)
	}
	exact := false
	for n in names {
		p := strings.concatenate({root, "/", n}, context.temp_allocator)
		if path_kind(p) == .Dir {
			// a long name's hash, or a non-ASCII path's spelling, is not certain: check the cwd
			append(&out, Slug_Folder{path = p, verify = len(n) > CLAUDE_SLUG_MAX || has_non_ascii(cwd) || has_non_ascii(real)})
			exact = true
		}
	}
	if o := claude_project_dir_override(account); o != "" {
		p := strings.concatenate({root, "/", o}, context.temp_allocator)
		if path_kind(p) == .Dir && !slice.contains(names[:], o) do append(&out, Slug_Folder{path = p, verify = true})
	}
	uncertain := has_non_ascii(cwd) || has_non_ascii(real) || len(names[0]) > CLAUDE_SLUG_MAX
	if !exact && uncertain {
		prefixes := [2]string{slug_prefix(cwd), slug_prefix(real)}
		entries, err := os.read_all_directory_by_path(root, context.temp_allocator)
		if err == nil {
			n := 0
			for e in entries {
				if e.type != .Directory || n >= 8 do continue
				for pre in prefixes do if pre != "" && strings.has_prefix(e.name, pre) {
					append(&out, Slug_Folder{path = e.fullpath, verify = true})
					n += 1
					break
				}
			}
		}
	}
	return out[:]
}

// A transcript's file name: <uuid>.jsonl, never a subagent's.
@(private = "file")
transcript_id :: proc(e: os.File_Info) -> string {
	if e.type != .Regular || !strings.has_suffix(e.name, ".jsonl") || strings.has_prefix(e.name, "agent-") do return ""
	id := strings.trim_suffix(e.name, ".jsonl")
	if !claude_id_ok(id) || len(id) < 8 do return ""
	return id
}

@(private = "file")
same_folder :: proc(a, b: string) -> bool {
	if a == "" || b == "" do return false
	return a == b || fs_real(a) == fs_real(b)
}

// ---- the listing ----

// The selected project's and Chats' found transcripts again (Select_Project, Rescan, the worker).
claude_disk_rescan :: proc() {
	claude_disk_scan(find_project(state.selected_project), false)
	claude_disk_scan(chats_project(), true)
}

// The found transcripts of project p into state.claude_disk (chats: state.claude_disk_chats).
claude_disk_scan :: proc(p: ^Project, chats: bool) {
	arena := chats ? &found_chats_arena : &found_arena
	out := chats ? &state.claude_disk_chats : &state.claude_disk
	virtual.arena_destroy(arena)
	_ = virtual.arena_init_growing(arena)
	context.allocator = virtual.arena_allocator(arena)
	out^ = make([dynamic]Claude_Disk)
	if p == nil || p.cwd == "" || p.machine != 0 do return // another machine's transcripts are not on this Mac
	if chats != (p.group == .Chats) do return
	Cand :: struct {
		id, path, account: string,
		size:              i64,
		modified, created: time.Time,
		verify:            bool,
	}
	cands := make([dynamic]Cand, context.temp_allocator)
	scanned := make([dynamic]string, context.temp_allocator) // accounts whose projects/ was looked at
	for a in claude_accounts() {
		root := strings.concatenate({a.dir, "/projects"}, context.temp_allocator)
		if path_kind(root) != .Dir do continue
		append(&scanned, a.dir)
		for sf in slug_folders(root, p.cwd, a.dir) {
			entries, err := os.read_all_directory_by_path(sf.path, context.temp_allocator)
			if err != nil do continue
			for e in entries {
				id := transcript_id(e)
				if id == "" do continue
				dup := false
				for c in cands do if c.id == id do dup = true
				if dup do continue
				created := e.creation_time != {} ? e.creation_time : e.modification_time
				append(&cands, Cand{id = id, path = e.fullpath, account = a.dir, size = e.size, modified = e.modification_time, created = created, verify = sf.verify})
			}
		}
	}
	slice.sort_by(cands[:], proc(a, b: Cand) -> bool {return time.diff(b.modified, a.modified) < 0})
	budget := claude_disk_launching ? 0 : claude_disk_inline_budget // the launch: all on the worker
	n := 0
	for c in cands {
		rec, _ := claude_record(c.id)
		if rec != nil && !rec.codex { // a Codex claim on Claude Code's own transcript never hides it (codex_claim_drop)
			// Deckhand's own: its row is the history's; only what the file tells
			append(out, Claude_Disk{id = strings.clone(c.id), account = strings.clone(c.account), modified = c.modified, created = c.created})
			continue
		}
		if session_listed(state.sessions[:], c.id) || session_listed(state.chats[:], c.id) do continue
		if n >= MAX_SESSIONS do continue
		title, cwd, sidechain, known := found_info(c.path, c.size, c.modified, &budget)
		if known && sidechain do continue
		// Claude's folder names collide (/a/b-c, /a/b/c and "/a/b c" share one): the recorded cwd
		// decides whenever there is one; an uncertain folder needs it
		if known && cwd != "" && !same_folder(cwd, p.cwd) do continue
		// a non-ASCII path's folder name is not certain: its cwd must be the project's, as spelled
		if known && c.verify && (has_non_ascii(p.cwd) || has_non_ascii(cwd)) && cwd != p.cwd && cwd != fs_real(p.cwd) do continue
		if c.verify && (!known || cwd == "") do continue
		n += 1
		append(out, Claude_Disk{id = strings.clone(c.id), path = strings.clone(c.path), account = strings.clone(c.account), title = strings.clone(title), modified = c.modified, created = c.created, listed = true})
	}
	// Codex conversations that ran in p's folder. Deckhand's own are its history's rows; an id
	// Claude's transcript has is Claude's (one id, one harness: codex.odin)
	m := 0
	// the cwd as Codex wrote it, byte for byte: the project's path or its real path (never a
	// path from the file resolved: a planted one would cost a walk per file per rescan)
	preal := fs_real(p.cwd)
	for c in codex_disk_files() {
		if m >= MAX_SESSIONS do break
		if rec, _ := claude_record(c.id); rec != nil do continue
		if session_listed(state.sessions[:], c.id) || session_listed(state.chats[:], c.id) do continue
		dup := false
		for f in out do if f.id == c.id do dup = true
		if dup do continue
		_, cwd, skip, known := found_info(c.path, c.size, c.modified, &budget)
		if !known || skip || (cwd != p.cwd && cwd != preal) do continue
		m += 1
		append(out, Claude_Disk{id = strings.clone(c.id), account = strings.clone(c.account), modified = c.modified, created = c.created, listed = true, codex = true})
	}
	// history entries of this project whose transcript is gone (stat only)
	for r in state.claude_history {
		if r.project != p.cwd || r.codex do continue // a Codex conversation has no Claude transcript (codex.odin)
		have := false
		for f in out do if f.id == r.id do have = true
		if have do continue
		gone := false
		if r.transcript != "" {
			gone = path_kind(r.transcript) == .Missing
		} else if r.title != "" {
			// it had a prompt, so Claude wrote a transcript: in its account's folder for the folder
			// it ran in (or the project's), if that account was looked at; a name that is not
			// certain (non-ASCII, long) never decides
			acc := claude_account_dir(r.account)
			if slice.contains(scanned[:], acc) {
				gone = true
				for c in ([3]string{r.cwd, fs_real(r.cwd), p.cwd}) {
					if c == "" do continue
					n := claude_project_slug(c)
					if has_non_ascii(c) || len(n) > CLAUDE_SLUG_MAX do gone = false
					if path_kind(strings.concatenate({acc, "/projects/", n, "/", r.id, ".jsonl"}, context.temp_allocator)) != .Missing do gone = false
				}
			}
		}
		if gone do append(out, Claude_Disk{id = strings.clone(r.id), account = strings.clone(r.account), gone = true})
	}
}

// What the scan knows of a history entry's transcript (nil = nothing).
claude_disk_of :: proc(id: string) -> ^Claude_Disk {
	for &f in state.claude_disk do if f.id == id do return &f
	for &f in state.claude_disk_chats do if f.id == id do return &f
	return nil
}

// A found transcript of project p's with this id: the listed rows first, else by stat in each
// account's folders for p (an agent's open_session of a project not selected). Temp.
claude_disk_lookup :: proc(p: ^Project, id: string) -> (f: Claude_Disk, ok: bool) {
	if r, _ := claude_record(id); r != nil && !r.codex do return {}, false
	if f, ok = claude_disk_find(p, id); ok do return
	// a Codex conversation listed for p (its scan's rows only: the selected project and Chats)
	if p == nil do return {}, false
	list := p.group == .Chats ? state.claude_disk_chats[:] : (p.id == state.selected_project ? state.claude_disk[:] : nil)
	for x in list do if x.listed && x.codex && x.id == id do return x, true
	return {}, false
}

// claude_disk_lookup whatever Deckhand's history says (codex.odin: whose conversation an id is).
claude_disk_find :: proc(p: ^Project, id: string) -> (f: Claude_Disk, ok: bool) {
	if p == nil || !claude_id_ok(id) do return {}, false
	list := p.group == .Chats ? state.claude_disk_chats[:] : (p.id == state.selected_project ? state.claude_disk[:] : nil)
	for x in list do if x.listed && !x.codex && x.id == id do return x, true
	for a in claude_accounts() {
		root := strings.concatenate({a.dir, "/projects"}, context.temp_allocator)
		if path_kind(root) != .Dir do continue
		for sf in slug_folders(root, p.cwd, a.dir) {
			path := strings.concatenate({sf.path, "/", id, ".jsonl"}, context.temp_allocator)
			k, st := path_stat(path)
			if k != .File do continue
			title, cwd, sidechain := found_read(path, st.size)
			if sidechain || (cwd != "" && !same_folder(cwd, p.cwd)) || (sf.verify && cwd == "") do continue
			if sf.verify && (has_non_ascii(p.cwd) || has_non_ascii(cwd)) && cwd != p.cwd && cwd != fs_real(p.cwd) do continue
			return Claude_Disk{id = strings.clone(id, context.temp_allocator), path = path, account = a.dir, title = title, modified = time.Time{_nsec = st.mtime}, listed = true}, true
		}
	}
	return {}, false
}

// A found row as session rows show it.
claude_disk_rows :: proc(p: Project, out: ^[dynamic]Session) {
	list := p.group == .Chats ? state.claude_disk_chats[:] : (p.id == state.selected_project ? state.claude_disk[:] : nil)
	for f in list {
		if !f.listed || session_listed(out[:], f.id) do continue
		append(out, Session{id = f.id, title = f.title, untitled = f.codex ? "Untitled Codex session" : "Untitled Claude session", when_ = utc_minute(f.created), modified = f.modified, claude = true, codex = f.codex, account = f.account, found = true})
	}
}

// The snapshot's found rows (as claude_sessions' entries: no path).
claude_disk_json :: proc(b: ^strings.Builder, p: ^Project, list: []Claude_Disk, first: ^bool) {
	if p == nil do return
	for f in list {
		if !f.listed do continue
		if !first^ do strings.write_byte(b, ',')
		first^ = false
		strings.write_string(b, `{"id":`)
		json_quote(b, f.id)
		strings.write_string(b, `,"project":`)
		json_quote(b, p.cwd)
		strings.write_string(b, `,"title":`)
		json_quote(b, f.title)
		strings.write_string(b, `,"used":`)
		strings.write_i64(b, time.to_unix_seconds(f.modified))
		strings.write_string(b, `,"created":`)
		strings.write_i64(b, time.to_unix_seconds(f.created))
		if tag := claude_account_tag(f.account, f.codex); tag != "" {
			strings.write_string(b, `,"account":`)
			json_quote(b, tag)
		}
		if f.codex do strings.write_string(b, `,"harness":"codex"`)
		strings.write_string(b, `,"found":true,"open":false}`)
	}
}

// A found row clicked (open_session): resumed in a Claude-only session under its account, by
// the transcript's path; the history keeps it from now on (with its title).
claude_disk_resume :: proc(p: ^Project, f: Claude_Disk, caller: Caller) -> (Result, bool) {
	if f.codex do return codex_disk_resume(p, f, caller)
	if mr, missing := claude_missing(caller); missing do return mr, false
	if !claude_account_known(f.account) do return fail("its Claude account is no longer in Settings → Claude accounts"), false
	if p.missing || !os.is_dir(p.cwd) do return fail("the project's folder is gone"), false
	codex_claim_drop(p, f.id) // Claude Code's transcript: a Codex claim on its id goes (claude.odin)
	r, ch := claude_open_disk(p, f, caller)
	if !r.ok do return r, ch
	if rec, _ := claude_record(f.id); rec != nil && rec.title == "" && f.title != "" do rec.title = strings.clone(f.title)
	return r, true
}

// ---- projects where only Claude ran (the Rescan worker) ----

CLAUDE_CWD_CHUNK :: 8 * 1024 // read for a transcript's cwd (its first lines)

@(private = "file")
Cwd_Info :: struct {
	size, mtime: i64,
	cwd:         string, // heap
	sidechain:   bool,
}

// cwds by transcript (path, size, date): a Rescan reads only new or changed files. Any thread.
@(private = "file")
cwd_cache: struct {
	mu:      sync.Mutex,
	entries: map[string]Cwd_Info, // keys: heap
	order:   [dynamic]string,
}

// The cwd a transcript records first, and whether it is a side chain: from its first 8 KB, else
// its first chunk. Temp.
@(private = "file")
found_cwd :: proc(path: string, size, mtime: i64) -> (cwd: string, sidechain: bool) {
	heap := runtime.heap_allocator()
	sync.lock(&cwd_cache.mu)
	if e, ok := cwd_cache.entries[path]; ok && e.size == size && e.mtime == mtime {
		cwd, sidechain = strings.clone(e.cwd, context.temp_allocator), e.sidechain
		sync.unlock(&cwd_cache.mu)
		return
	}
	sync.unlock(&cwd_cache.mu)
	f, err := os.open(path)
	if err != nil do return
	decided := false
	for want in ([2]i64{CLAUDE_CWD_CHUNK, CLAUDE_DISK_CHUNK}) {
		n := min(size, want)
		buf := make([]u8, n, context.temp_allocator)
		got, _ := os.read_at(f, buf, 0)
		sync.atomic_add(&claude_disk_bytes_read, i64(max(got, 0)))
		rest := string(buf[:max(got, 0)])
		if i64(got) == size && size > 0 && rest[len(rest) - 1] != '\n' do rest = strings.concatenate({rest, "\n"}, context.temp_allocator)
		for cwd == "" || !decided {
			nl := strings.index_byte(rest, '\n')
			if nl < 0 do break
			line := rest[:nl]
			rest = rest[nl + 1:]
			if len(line) < 2 || line[0] != '{' do continue
			if !strings.contains(line, `"cwd"`) && !strings.contains(line, `"isSidechain"`) do continue
			if !line_parsable(line) do continue
			v, perr := jg.parse(transmute([]u8)line, .JSON, false, context.temp_allocator) // strict: JSON5's quotes would hide brackets from line_parsable
			if perr != nil do continue
			o, ok := v.(json.Object)
			if !ok do continue
			if c, cok := o["cwd"].(json.String); cok && cwd == "" do cwd = string(c)
			if sc, has := o["isSidechain"].(json.Boolean); has && !decided {
				decided = true
				sidechain = bool(sc)
			}
		}
		if cwd != "" || size <= n do break
	}
	os.close(f)
	sync.lock(&cwd_cache.mu)
	defer sync.unlock(&cwd_cache.mu)
	if cwd_cache.entries.allocator.procedure == nil do cwd_cache.entries = make(map[string]Cwd_Info, heap)
	if cwd_cache.order.allocator.procedure == nil do cwd_cache.order = make([dynamic]string, heap)
	if e, ok := &cwd_cache.entries[path]; ok {
		delete(e.cwd, heap)
		e^ = {size = size, mtime = mtime, cwd = strings.clone(cwd, heap), sidechain = sidechain}
		return
	}
	for len(cwd_cache.entries) >= max(claude_disk_cache_max, 1) && len(cwd_cache.order) > 0 {
		old := pop_front(&cwd_cache.order)
		if e, ok := cwd_cache.entries[old]; ok do delete(e.cwd, heap)
		delete_key(&cwd_cache.entries, old)
		delete(old, heap)
	}
	k := strings.clone(path, heap)
	cwd_cache.entries[k] = {size = size, mtime = mtime, cwd = strings.clone(cwd, heap), sidechain = sidechain}
	append(&cwd_cache.order, k)
	return
}

// Each account's folder and its CLAUDE_CODE_PROJECT_DIR_NAME, taken on the main thread before a
// scan (scan_projects runs on a worker and touches no State). Heap.
Claude_Scan_Dir :: struct {
	dir, override: string,
}
claude_scan_dirs: [dynamic]Claude_Scan_Dir

// The launch (main.odin, until the saved workspace is back): no transcript read on the main thread.
claude_disk_launching: bool

// A Claude account was added while a Rescan ran: one more after it (commands.odin).
claude_rescan_again: bool

// No account folders for the next scan (rescan_now(claude = false)).
claude_scan_clear :: proc() {
	heap := runtime.heap_allocator()
	for d in claude_scan_dirs {
		delete(d.dir, heap)
		delete(d.override, heap)
	}
	clear(&claude_scan_dirs)
}

claude_scan_prepare :: proc() {
	heap := runtime.heap_allocator()
	for d in claude_scan_dirs {
		delete(d.dir, heap)
		delete(d.override, heap)
	}
	clear(&claude_scan_dirs)
	if claude_scan_dirs.allocator.procedure == nil do claude_scan_dirs = make([dynamic]Claude_Scan_Dir, heap)
	for a in claude_accounts() do append(&claude_scan_dirs, Claude_Scan_Dir{dir = strings.clone(a.dir, heap), override = strings.clone(claude_project_dir_override(a.dir), heap)})
}

// Adds the folders Claude ran in to scan.projects (allocated there), merged with pi's by cwd.
// Any thread (reads only claude_scan_dirs, set before the scan).
claude_scan_projects :: proc(projects: ^[dynamic]Project) {
	for sd in claude_scan_dirs {
		root := strings.concatenate({sd.dir, "/projects"}, context.temp_allocator)
		dirs, err := os.read_all_directory_by_path(root, context.temp_allocator)
		if err != nil do continue
		for d in dirs {
			if d.type != .Directory do continue
			files, ferr := os.read_all_directory_by_path(d.fullpath, context.temp_allocator)
			if ferr != nil do continue
			list := make([dynamic]os.File_Info, context.temp_allocator)
			for f in files do if transcript_id(f) != "" do append(&list, f)
			if len(list) == 0 do continue
			slice.sort_by(list[:], proc(a, b: os.File_Info) -> bool {return time.diff(b.modification_time, a.modification_time) < 0})
			shared := sd.override != "" && d.name == sd.override
			tries := shared ? 20 : 3
			for f in list[:min(len(list), tries)] {
				cwd, sidechain := found_cwd(f.fullpath, f.size, f.modification_time._nsec)
				if sidechain || cwd == "" || !filepath.is_abs(cwd) do continue
				c, _ := filepath.clean(cwd, context.temp_allocator)
				// the cwd must be this folder's (its name from the cwd, never the other way)
				if !shared {
					s := claude_project_slug(c)
					if s != d.name && !(len(s) > CLAUDE_SLUG_MAX && strings.has_prefix(d.name, s[:CLAUDE_SLUG_MAX])) && !(has_non_ascii(c) && strings.has_prefix(d.name, slug_prefix(c))) do continue
				}
				newest, oldest := list[0].modification_time, list[len(list) - 1].modification_time
				found := false
				for &p in projects do if p.cwd == c {
					if time.diff(p.newest, newest) > 0 do p.newest = newest
					if p.created == {} || time.diff(oldest, p.created) > 0 do p.created = oldest
					found = true
				}
				if !found {
					cc := strings.clone(c)
					append(projects, Project{cwd = cc, label = short_label(cc), newest = newest, created = oldest, missing = !os.exists(cc), repo = is_repo_root(cc), claude = true})
				}
				if !shared do break
			}
		}
	}
}
