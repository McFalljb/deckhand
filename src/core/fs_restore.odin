package core

// Putting back what delete_path moved to the Trash (restore_path): each item delete_path moves
// gets a restore id, issued here and kept in memory only (the last FS_RESTORE_MAX; a core that
// starts again has none). Only an id is ever taken, never a Trash path from a caller: the core
// recorded where the platform's Trash put the item (fs_trash_where: macOS's resultingItemURL, the
// XDG Trash's files/<name>) and which file it was (device and inode). Restoring is the user's at
// this window only (fs_user_here), moves the item back without replacing anything, and passes
// the checks a create at that path does (fs_check_write).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

FS_RESTORE_MAX :: 200

FS_RESTORE_USER_ONLY :: "only you, in Deckhand's window or a paired browser, may restore from the Trash"
FS_RESTORE_UNKNOWN :: "no such restore id (the last 200 items moved to the Trash can be restored, until Deckhand's core restarts)"
FS_RESTORE_GONE :: "it is no longer where it was put in the Trash"

Fs_Trashed :: struct {
	id:       string, // issued here (owned)
	path:     string, // where it was (owned)
	trashed:  string, // where the Trash put it (owned)
	info:     string, // the XDG Trash's .trashinfo, removed on restore ("" = none; owned)
	info_text: string, // that file's text as the core wrote it (Path=, DeletionDate=; owned)
	dev, ino: u64, // the item itself, and as it was put there: a freed inode may be reused
	size:     i64,
	mtime:    i64, // ns
}

// Oldest first (heap).
fs_trashed: [dynamic]Fs_Trashed

// Where the last fs_trash_fn put its item ("" = not said: no restore id). Set by the trash call
// (a temp or constant string); fs_trash_checked reads and clears it.
fs_trash_where: string

// Records an item fs_trash_fn just moved from path (dev/ino: what was at path) to where. id: its
// restore id ("" = where is not known, or not that item).
fs_trashed_add :: proc(path, where_: string, dev, ino: u64) -> (id: string) {
	if where_ == "" do return ""
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(where_, context.temp_allocator), &st) != .OK || u64(st.st_dev) != dev || u64(st.st_ino) != ino do return ""
	h := runtime.heap_allocator()
	info, info_text := "", ""
	if xdg := trash_xdg_dir(); xdg != "" && tdir(where_) == strings.concatenate({xdg, "/files"}, context.temp_allocator) {
		info = fmt.tprintf("%s/info/%s.trashinfo", xdg, filepath.base(where_))
		data, rerr := os.read_entire_file(info, context.temp_allocator)
		if rerr != nil do return "" // no info file as the core wrote it: nothing to check against
		info_text = string(data)
	}
	stamp := stamp_of_stat(&st)
	if fs_trashed.allocator.procedure == nil do fs_trashed.allocator = h
	for len(fs_trashed) >= FS_RESTORE_MAX {
		fs_trashed_free(fs_trashed[0])
		ordered_remove(&fs_trashed, 0)
	}
	id = new_uuid()
	append(&fs_trashed, Fs_Trashed{id = strings.clone(id, h), path = strings.clone(path, h), trashed = strings.clone(where_, h), info = strings.clone(info, h), info_text = strings.clone(info_text, h), dev = dev, ino = ino, size = stamp.size, mtime = stamp.mtime})
	return fs_trashed[len(fs_trashed) - 1].id
}

@(private = "file")
fs_trashed_free :: proc(t: Fs_Trashed) {
	h := runtime.heap_allocator()
	delete(t.id, h)
	delete(t.path, h)
	delete(t.trashed, h)
	delete(t.info, h)
	delete(t.info_text, h)
}

@(private = "file")
fs_trashed_drop :: proc(i: int) {
	fs_trashed_free(fs_trashed[i])
	ordered_remove(&fs_trashed, i)
}

// filepath.dir in the temp allocator.
tdir :: proc(p: string) -> string {
	context.allocator = context.temp_allocator
	return filepath.dir(p)
}

// Whether the item of a record is still the one the Trash was given: the same file (device and
// inode), size and modification time, and (the XDG Trash) its info file as the core wrote it.
@(private = "file")
trashed_same :: proc(t: Fs_Trashed) -> bool {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(t.trashed, context.temp_allocator), &st) != .OK do return false
	s := stamp_of_stat(&st)
	if s.dev != t.dev || s.inode != t.ino || s.size != t.size || s.mtime != t.mtime do return false
	if t.info != "" {
		data, err := os.read_entire_file(t.info, context.temp_allocator)
		if err != nil || string(data) != t.info_text do return false
	}
	return true
}

// Who may restore: the user, in this window or a paired browser (which acts as the user); never
// another machine's core, a script, an agent or Deckhand itself.
fs_restore_may :: proc(caller: Caller) -> bool {return caller.kind == .UI && !caller_from_hub(caller)}

// Moves the item of a restore id back to where it was. path: that path.
fs_restore :: proc(id: string, caller: Caller) -> (path: string, err: string) {
	if !fs_restore_may(caller) do return "", FS_RESTORE_USER_ONLY
	i := -1
	for t, k in fs_trashed do if id != "" && t.id == id do i = k
	if i < 0 do return "", FS_RESTORE_UNKNOWN
	t := fs_trashed[i]
	st: posix.stat_t
	if !trashed_same(t) {
		fs_trashed_drop(i)
		return "", FS_RESTORE_GONE
	}
	// as a create at that path: inside a project, not its folder, not in .git
	p, _, e := fs_check_write(t.path, caller)
	if e != "" do return "", e
	if path_kind(tdir(p)) != .Dir do return "", fmt.tprintf("its folder is gone: %s", tdir(p))
	if posix.lstat(strings.clone_to_cstring(p, context.temp_allocator), &st) == .OK do return "", fmt.tprintf("something is at %s now", p)
	// never over anything put there meanwhile (renamex_np RENAME_EXCL, renameat2 NOREPLACE)
	switch trash_rename(strings.clone_to_cstring(t.trashed, context.temp_allocator), strings.clone_to_cstring(p, context.temp_allocator)) {
	case .Ok:
	case .Exists:     return "", fmt.tprintf("something is at %s now", p)
	case .Other_Disk: return "", "it is on another disk than its folder now: not moved"
	case .Failed:     return "", fmt.tprintf("cannot move it back: %s", strings.to_lower(string(posix.strerror(posix.errno())), context.temp_allocator))
	}
	if t.info != "" do posix.unlink(strings.clone_to_cstring(t.info, context.temp_allocator))
	path = strings.clone(p, context.temp_allocator)
	fs_trashed_drop(i)
	fs_changed_ours(path)
	return path, ""
}
