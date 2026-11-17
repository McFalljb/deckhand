package core

// Reads in another checkout of a project (a browser's Files tree switched to a sibling worktree,
// page state only: never files_set_root). list_dir, find_files and file_read go through
// fs_check_read: fs_check, and only when that says the path is in no project folder at all, also
// inside another checkout of a known project's repository, that checkout's folder then counting as
// the root. The rule (fs_read_checkout), all of it:
// - the project (or open session) folder must itself be its repository's top (the folder holding
//   .git): a project in a subfolder of a repository (a monorepo's package, a folder under a HOME
//   that is a dotfiles repository) gets no checkout reads at all;
// - the checkout is a real checkout of that same repository (wt_verified: a .git folder that is the
//   common dir, or a linked worktree's .git file whose gitdir points back; never a crafted .git file
//   or a link) that the last `git worktree list` listed and whose folder is there;
// - never a checkout at or above HOME, nor "/";
// - for anyone but the user here, never a checkout (or a path) in a credential place
//   (fs_credential_place);
// - a pi tab's bridge (Panel) gets none (it keeps what fs_check gives it);
// - inside it, never .git.
// The check reads the last scan only (wt_repo_for without counts: a scan starts only when none is
// current). Writes (create, rename, delete, copy, save) keep fs_check: refused there unless the
// checkout is a root already (files_set_root, a session in it).

import "core:os"
import "core:path/filepath"

FS_NOT_IN_PROJECT :: "only inside a project folder" // fs_check's answer for a path in no project folder

fs_check_read :: proc(path: string, caller: Caller, allow_root := false) -> (abs, root: string, err: string) {
	abs, root, err = fs_check(path, caller, allow_root)
	if err != FS_NOT_IN_PROJECT || caller.kind == .Panel do return
	a := fs_abs(path, caller)
	// as fs_check: the parent's real path decides (the path itself too when it may be the root)
	full := fs_real(a)
	if !allow_root {
		full, _ = filepath.join({fs_real(filepath.dir(a)), filepath.base(a)}, context.temp_allocator)
	}
	top := fs_read_checkout(allow_root ? full : filepath.dir(full))
	if top == "" do return
	if !fs_user_here(caller) && (fs_credential_place(top) || fs_credential_place(full)) do return
	if fs_in_git(full[len(top):]) do return "", "", "not inside .git"
	return full, top, ""
}

// The listed checkout of a known project's repository that real path dir is in ("" = none): a
// folder at or above it (below HOME) holding a verified .git that wt_sibling_err accepts for a
// project (or open session) folder.
@(private = "file")
fs_read_checkout :: proc(dir: string) -> string {
	homes, ok := wt_homes()
	if !ok do return "" // where HOME is cannot be told: no checkout reads
	for d := dir; len(d) > 1; d = filepath.dir(d) {
		if wt_home_or_above(d, homes) do return ""
		common := wt_verified(d)
		if common == "" do continue
		for r in fs_base_roots() do if wt_where(r).common == common && wt_sibling_err(r, d, listed = true) == "" do return d
	}
	return ""
}

WT_NOT_FROM_HERE :: "only a project at its repository's top folder shows its other checkouts"

// Why path may not be another checkout shown for base, a project (or open session) folder ("" = it
// may): the one rule for reads there (fs_check_read) and for files_set_root, for every caller.
// HOME must be set; base must be its repository's top folder (the folder holding .git; not a
// subfolder of a repository, so never the repository's top or another package from a monorepo's
// package, nor HOME from a folder under a dotfiles HOME) and below HOME; path must be below HOME
// (never HOME, above it, or /) and really a checkout of that repository (wt_verified: a .git folder
// that is the common dir, or a linked worktree's .git file pointing back; no crafted .git file, no
// link); listed: and the last scan listed it, its folder there (the scan is read, not started
// while one is current: wt_repo_for without counts).
wt_sibling_err :: proc(base, path: string, listed: bool) -> string {
	homes, ok := wt_homes()
	if !ok do return "HOME is not set: no other checkout"
	b := fs_real(base)
	if !wt_switchable_base(b) do return WT_NOT_FROM_HERE
	p := fs_real(path)
	if wt_home_or_above(p, homes) do return "not HOME or a folder above it"
	common := wt_verified(p)
	if common == "" || common != wt_where(b).common do return "not a checkout of the project's repository"
	if !listed do return ""
	r := wt_repo_for(b, counts = false)
	if r == nil || !r.loaded do return "worktrees are being read: try again"
	if c := wt_checkout(r, p); c == nil || c.missing do return "not a checkout of the project's repository"
	return ""
}

// Whether a project (or session) folder may show its repository's other checkouts: it is its
// repository's top folder, below HOME (HOME set).
wt_switchable_base :: proc(base: string) -> bool {
	homes, ok := wt_homes()
	if !ok do return false
	b := fs_real(base)
	w := wt_where(b)
	return w.common != "" && w.top == b && !wt_home_or_above(b, homes)
}

@(private = "file")
wt_homes :: proc() -> (homes: [2]string, ok: bool) {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return {}, false
	return {home, fs_real(home)}, true
}

@(private = "file")
wt_home_or_above :: proc(d: string, homes: [2]string) -> bool {
	if d == "" || d == "/" do return true
	for h in homes do if h != "" && within(h, d) do return true
	return false
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
