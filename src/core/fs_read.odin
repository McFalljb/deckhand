package core

// Reads in another checkout of a project (a browser's Files tree switched to a sibling worktree,
// page state only: never files_set_root). list_dir, find_files and file_read go through
// fs_check_read: fs_check, and when that says the path is in no project folder at all, also inside
// any checkout of a known project's repository that the last `git worktree list` listed
// (wt_checkout_err with listed: a real checkout, its .git verified, never a crafted .git file or
// a link), that checkout's folder then counting as the root. Everything else fs_check does still
// holds there: never the folder itself (unless allow_root), never inside .git, a pi tab's bridge
// only its own project's checkouts. Writes (create, rename, delete, copy, save) keep fs_check:
// refused there unless the checkout is a root already (files_set_root, a session in it).

import "core:path/filepath"

FS_NOT_IN_PROJECT :: "only inside a project folder" // fs_check's answer for a path in no project folder

fs_check_read :: proc(path: string, caller: Caller, allow_root := false) -> (abs, root: string, err: string) {
	abs, root, err = fs_check(path, caller, allow_root)
	if err != FS_NOT_IN_PROJECT do return
	a := fs_abs(path, caller)
	// as fs_check: the parent's real path decides (the path itself too when it may be the root)
	full := fs_real(a)
	if !allow_root {
		full, _ = filepath.join({fs_real(filepath.dir(a)), filepath.base(a)}, context.temp_allocator)
	}
	top := fs_read_checkout(allow_root ? full : filepath.dir(full), caller)
	if top == "" do return
	if fs_in_git(full[len(top):]) do return "", "", "not inside .git"
	return full, top, ""
}

// The checkout of a known project's repository that real path dir is in ("" = none): a folder at
// or above it holding a verified .git (wt_verified; a repository nested in it is passed over),
// listed by the last scan of a known project's (or open session's) repository; for a pi tab's
// bridge only its own project's.
@(private = "file")
fs_read_checkout :: proc(dir: string, caller: Caller) -> string {
	for d := dir; len(d) > 1; d = filepath.dir(d) {
		common := wt_verified(d)
		if common == "" do continue
		for r in fs_base_roots() {
			if caller.kind == .Panel && fs_outside_own(r, caller) do continue
			if wt_where(r).common == common && wt_checkout_err(r, d, listed = true) == "" do return d
		}
	}
	return ""
}

// fs_check's (read: fs_check_read's) error alone ("" = may).
fs_check_err :: proc(path: string, caller: Caller, read: bool) -> string {
	if read {
		_, _, e := fs_check_read(path, caller)
		return e
	}
	_, _, e := fs_check(path, caller)
	return e
}
