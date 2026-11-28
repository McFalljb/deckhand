package main

// Watching folders for the editor and the file-system model. The set of
// watched folders is the open files' folders plus the project folders that
// were listed; the platform watcher (FSEvents) reports changed paths on its
// own thread, they queue here, and editor_tick (main thread, every frame
// callback, cheap when nothing is queued) hands them to the open editors
// and the file-system model. A stat poll of the open files every
// EDITOR_POLL backs the watcher up.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"
import "core"

@(private = "file")
Watch :: struct {
	lock:      sync.Mutex,
	pending:   [dynamic]Watch_Event, // changed paths (heap), under lock
	any:       bool, // atomic: pending is not empty
	folders:   [dynamic]string, // project folders to watch (owned)
	last_set:  [dynamic]string, // what the platform watcher has (owned)
	last_ids:  [dynamic]Watch_Root_Id, // each one's identity when it was set (watch_roots_check)
	last_poll: time.Tick,
	roots_at:  time.Tick, // the last watch_roots_check
	retry_at:  time.Tick, // the watcher failed: not tried again before this
	retry_for: time.Duration, // ...and the wait after the next failure
}

// A watched folder's identity: gone, or moved (another folder at its path) shows as a change.
@(private = "file")
Watch_Root_Id :: struct {
	ok:  bool,
	dev: u64,
	ino: u64,
}

WATCH_ROOTS_EVERY :: 2 * time.Second // how often each watched folder is checked for a move
WATCH_RETRY_FIRST :: time.Second // a watcher that failed is tried again after this, doubling
WATCH_RETRY_MAX :: time.Minute
FSE_ROOT_CHANGED :: u32(0x20) // kFSEventStreamEventFlagRootChanged (a structural change: fs_model.odin)

@(private = "file")
watch: Watch

@(private = "file")
Watch_Event :: struct {
	path:  string, // heap
	flags: u32, // FSEvents flags
}

@(private = "file")
on_change :: proc "c" (path: cstring, flags: u32) {
	context = runtime.default_context()
	sync.mutex_lock(&watch.lock)
	append(&watch.pending, Watch_Event{strings.clone(string(path), runtime.heap_allocator()), flags})
	sync.mutex_unlock(&watch.lock)
	sync.atomic_store(&watch.any, true)
	if core.platform.wake != nil do core.platform.wake()
}

// Adds a project folder to the watched set (the file model listed it).
watch_folder :: proc(folder: string) {
	if folder == "" do return
	for f in watch.folders do if f == folder do return
	append(&watch.folders, strings.clone(folder))
	watch_sync()
}

// Hands the current set of folders to the platform watcher if it changed:
// the open files' folders and the listed project folders, without the
// ones inside another (watching is recursive).
//
// Watching is recursive, so only folders inside projects are watched, never
// the home folder or one above it: an open file outside every project (or in
// such a folder) is followed by the stat poll alone.
watch_sync :: proc() {
	want := make([dynamic]string, context.temp_allocator)
	home := core.fs_real(os.get_env("HOME", context.temp_allocator))
	too_wide :: proc(f, home: string) -> bool {
		return f == "/" || f == "" || f == home || (home != "" && strings.has_prefix(home, f) && home[len(f)] == '/')
	}
	for f in watch.folders do if !too_wide(f, home) do append(&want, f)
	for f in core.reload_watch_dirs() do if !too_wide(f, home) do append(&want, f) // pi's config folders (reload.odin)
	for _, e in editors {
		if e.view != .File || e.path == "" do continue
		d := core.fs_real(dir_of(e.path))
		if core.fs_root_of(d) == "" || too_wide(d, home) do continue
		append(&want, d)
	}
	keep := make([dynamic]string, context.temp_allocator)
	outer: for f, i in want {
		for g, j in want {
			if i == j do continue
			if g == f && j < i do continue outer // duplicate
			if g != f && strings.has_prefix(f, g) && len(f) > len(g) && f[len(g)] == '/' do continue outer
		}
		append(&keep, f)
	}
	same := len(keep) == len(watch.last_set)
	if same do for f, i in keep do if f != watch.last_set[i] do same = false
	if same do return
	// a watcher that failed waits out its backoff: never a tight loop of failing streams
	if watch.retry_at != {} && time.tick_diff(time.tick_now(), watch.retry_at) < 0 do return
	for f in watch.last_set do delete(f)
	clear(&watch.last_set)
	clear(&watch.last_ids)
	if !fs_watch_set(keep[:], on_change) {
		watch.retry_for = watch.retry_for == 0 ? WATCH_RETRY_FIRST : min(watch.retry_for * 2, WATCH_RETRY_MAX)
		watch.retry_at = time.tick_add(time.tick_now(), watch.retry_for)
		wlog(fmt.tprintf("file watcher: FSEvents could not watch %d folder(s); tried again in %v (the editor's stat poll still follows open files)", len(keep), watch.retry_for))
		return // last_set stays empty: the next sync after the wait tries again
	}
	if watch.retry_for != 0 do wlog(fmt.tprintf("file watcher: watching %d folder(s) again", len(keep)))
	watch.retry_at, watch.retry_for = {}, 0
	for f in keep {
		append(&watch.last_set, strings.clone(f))
		append(&watch.last_ids, watch_root_id(f))
	}
}

@(private = "file")
watch_root_id :: proc(path: string) -> Watch_Root_Id {
	st: posix.stat_t
	if posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK do return {}
	return {ok = true, dev = u64(st.st_dev), ino = u64(st.st_ino)}
}

// Every WATCH_ROOTS_EVERY: a watched folder that went, came back or is another folder now (a
// rename or move of it, or of a folder above it) is reported as FSEvents' RootChanged would be.
// Main thread (editor_tick); a stat per watched folder.
watch_roots_check :: proc(now: time.Tick) {
	if len(watch.last_set) == 0 || time.tick_diff(watch.roots_at, now) < WATCH_ROOTS_EVERY do return
	watch.roots_at = now
	for f, i in watch.last_set {
		id := watch_root_id(f)
		if id == watch.last_ids[i] do continue
		watch.last_ids[i] = id
		sync.mutex_lock(&watch.lock)
		append(&watch.pending, Watch_Event{strings.clone(f, runtime.heap_allocator()), FSE_ROOT_CHANGED})
		sync.mutex_unlock(&watch.lock)
		sync.atomic_store(&watch.any, true)
	}
}

// What the platform watcher watches now (recursively).
watched_folders :: proc() -> []string {return watch.last_set[:]}

@(private = "file")
dir_of :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return i <= 0 ? "/" : path[:i]
}

// Main thread, every frame callback: queued changes, the poll, and the
// git gutter of the shown editor once typing paused.
editor_tick :: proc() {
	core.fs_model_tick()
	core.settings_poll() // while the Settings page shows: its folders outside projects (settings_files.odin)
	// hot reload: pi's config files and version (reload.odin), and Claude Code's
	// (claude_reload.odin); a separate core runs them itself (serve.odin)
	if !client_separate() {
		core.reload_tick()
		core.claude_reload_tick()
	}
	watch_roots_check(time.tick_now())
	if sync.atomic_load(&watch.any) {
		sync.mutex_lock(&watch.lock)
		paths := watch.pending
		watch.pending = {}
		sync.atomic_store(&watch.any, false)
		sync.mutex_unlock(&watch.lock)
		if client_separate() { // a separate core's file models follow too (fs_model.odin's Fs_Changed)
			fc := core.Fs_Changed{paths = make([]string, len(paths), context.temp_allocator), flags = make([]u32, len(paths), context.temp_allocator)}
			for p, i in paths do fc.paths[i], fc.flags[i] = p.path, p.flags
			client_internal(fc)
		}
		for p in paths {
			if !client_separate() do core.reload_fs_event(p.path) // one of pi's config folders? (reload.odin; a separate core polls)
			editor_path_changed(p.path, p.flags)
			delete(p.path, runtime.heap_allocator())
		}
		delete(paths)
		app.redraw = true
	}
	if len(editors) > 0 && time.tick_since(watch.last_poll) > core.EDITOR_POLL {
		watch.last_poll = time.tick_now()
		for _, e in editors do editor_check_disk(e)
	}
	// every editor on screen (any pane's: an outside change shows in its gutter there too)
	for id, e in editors {
		if !core.tab_on_screen(id) do continue
		editor_keep_edited_previews()
		git_gutter_update(e)
		// a slow reparse waited for typing to pause (editor_syntax.odin): now
		if e.sx.stale && e.sx.tree != nil && !syntax_deferring(&e.sx) do app.redraw = true
	}
}

// One changed path: the file model forgets what it cached there; an open
// file at (or in a folder event for) that path looks at the disk; a change
// under .git may have moved HEAD.
editor_path_changed :: proc(path: string, flags: u32 = 0) {
	core.fs_model_changed(path, flags)
	in_git := strings.contains(path, "/.git/") || strings.has_suffix(path, "/.git")
	for _, e in editors {
		if e.view != .File do continue
		rp := core.fs_real(e.path)
		if in_git {
			repo := path[:strings.index(path, "/.git")]
			if strings.has_prefix(rp, repo) {
				e.git.head_stale = true
				e.git.stale = true
			}
			continue
		}
		if rp == path || e.path == path || dir_of(rp) == path do editor_check_disk(e)
	}
}

// An edited preview tab is kept, as a double-click does: Keep_Tab goes to the core (a separate
// core's too: never run on the window's replica). Per tab: once, and again while it is still a
// preview after KEEP_RESEND (#116: one remembered tab resent two previews every frame, and a
// send lost while the core was down was never repeated).
editor_keep_edited_previews :: proc() {
	for id in keep_previews_due(core.files_edited_previews(), time.tick_now()) do ui_do(core.Keep_Tab{tab_id = id})
}

// How long a Keep_Tab may go unanswered (the tab still an edited preview) before it is sent again:
// a send lost while a separate core was down or restarting.
KEEP_RESEND :: 2 * time.Second

@(private = "file")
Keep_Sent :: struct {
	tab: u64,
	at:  time.Tick,
}

// Per tab: when its Keep_Tab was sent (heap); a tab no longer an edited preview is forgotten.
@(private = "file")
keep_sent: [dynamic]Keep_Sent

// Of the edited previews IDS, the ones to send Keep_Tab for at NOW (temp allocator): each once,
// again after KEEP_RESEND while it is still one.
keep_previews_due :: proc(ids: []u64, now: time.Tick) -> []u64 {
	if keep_sent.allocator.procedure == nil do keep_sent.allocator = runtime.heap_allocator()
	for i := len(keep_sent) - 1; i >= 0; i -= 1 do if !slice.contains(ids, keep_sent[i].tab) do unordered_remove(&keep_sent, i)
	due := make([dynamic]u64, context.temp_allocator)
	next: for id in ids {
		for &k in keep_sent do if k.tab == id {
			if time.tick_diff(k.at, now) >= KEEP_RESEND {
				k.at = now
				append(&due, id)
			}
			continue next
		}
		append(&keep_sent, Keep_Sent{tab = id, at = now})
		append(&due, id)
	}
	return due[:]
}

// Tests: the changed paths queued and not taken yet, with their flags (temp).
watch_pending_for_test :: proc() -> (paths: []string, flags: []u32) {
	sync.mutex_lock(&watch.lock)
	defer sync.mutex_unlock(&watch.lock)
	paths = make([]string, len(watch.pending), context.temp_allocator)
	flags = make([]u32, len(watch.pending), context.temp_allocator)
	for e, i in watch.pending do paths[i], flags[i] = strings.clone(e.path, context.temp_allocator), e.flags
	return
}

// Tests: the watched project folders become just `folder` ("" = none), synced; returns the one
// watched before ("" = none) for the test to put back.
watch_folders_for_test :: proc(folder: string) -> string {
	was := len(watch.folders) > 0 ? strings.clone(watch.folders[0], context.temp_allocator) : ""
	for f in watch.folders do delete(f)
	clear(&watch.folders)
	watch.retry_at, watch.retry_for = {}, 0
	if folder != "" do append(&watch.folders, strings.clone(folder))
	watch_sync()
	return was
}
