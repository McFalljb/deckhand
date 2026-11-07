package main

// Watching folders for the editor and the file-system model. The set of
// watched folders is the open files' folders plus the project folders that
// were listed; the platform watcher (FSEvents) reports changed paths on its
// own thread, they queue here, and editor_tick (main thread, every frame
// callback, cheap when nothing is queued) hands them to the open editors
// and the file-system model. A stat poll of the open files every
// EDITOR_POLL backs the watcher up.

import "base:runtime"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

@(private = "file")
Watch :: struct {
	lock:      sync.Mutex,
	pending:   [dynamic]Watch_Event, // changed paths (heap), under lock
	any:       bool, // atomic: pending is not empty
	folders:   [dynamic]string, // project folders to watch (owned)
	last_set:  [dynamic]string, // what the platform watcher has (owned)
	last_poll: time.Tick,
}

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
	if platform.wake != nil do platform.wake()
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
	home := fs_real(os.get_env("HOME", context.temp_allocator))
	too_wide :: proc(f, home: string) -> bool {
		return f == "/" || f == "" || f == home || (home != "" && strings.has_prefix(home, f) && home[len(f)] == '/')
	}
	for f in watch.folders do if !too_wide(f, home) do append(&want, f)
	for f in reload_watch_dirs() do if !too_wide(f, home) do append(&want, f) // pi's config folders (reload.odin)
	for _, e in editors {
		if e.view != .File || e.path == "" do continue
		d := fs_real(dir_of(e.path))
		if fs_root_of(d) == "" || too_wide(d, home) do continue
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
	for f in watch.last_set do delete(f)
	clear(&watch.last_set)
	for f in keep do append(&watch.last_set, strings.clone(f))
	fs_watch_set(keep[:], on_change)
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
	fs_model_tick()
	settings_poll() // the Settings tab's folders outside projects (settings_files.odin)
	reload_tick() // hot reload: pi's config files and version (reload.odin)
	claude_reload_tick() // and Claude Code's (claude_reload.odin)
	if sync.atomic_load(&watch.any) {
		sync.mutex_lock(&watch.lock)
		paths := watch.pending
		watch.pending = {}
		sync.atomic_store(&watch.any, false)
		sync.mutex_unlock(&watch.lock)
		for p in paths {
			reload_fs_event(p.path) // one of pi's config folders? (reload.odin)
			editor_path_changed(p.path, p.flags)
			delete(p.path, runtime.heap_allocator())
		}
		delete(paths)
		app.redraw = true
	}
	if len(editors) > 0 && time.tick_since(watch.last_poll) > EDITOR_POLL {
		watch.last_poll = time.tick_now()
		for _, e in editors do editor_check_disk(e)
	}
	// every editor on screen (any pane's: an outside change shows in its gutter there too)
	for id, e in editors {
		if !tab_on_screen(id) do continue
		files_keep_edited_preview()
		git_gutter_update(e)
		// a slow reparse waited for typing to pause (editor_syntax.odin): now
		if e.sx.stale && e.sx.tree != nil && !syntax_deferring(&e.sx) do app.redraw = true
	}
}

// One changed path: the file model forgets what it cached there; an open
// file at (or in a folder event for) that path looks at the disk; a change
// under .git may have moved HEAD.
editor_path_changed :: proc(path: string, flags: u32 = 0) {
	fs_model_changed(path, flags)
	in_git := strings.contains(path, "/.git/") || strings.has_suffix(path, "/.git")
	for _, e in editors {
		if e.view != .File do continue
		rp := fs_real(e.path)
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
