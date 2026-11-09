package core

// From src/editor_git.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// Internal only: a worker read a file's HEAD version (Git_Head_Done) or a
// repository's status (Git_Status_Done).
Git_Head_Done :: struct {
	tab_id:  u64,
	gen:     u64, // Git_Gutter.load_gen when it started
	path:    string,
	in_repo: bool,
	tracked: bool,
	head:    string,
}

Git_Status_Done :: struct {
	root: string,
	gen:  u64, // Git_Status.gen when it started
	ok:   bool,
	out:  string, // git status --porcelain=v1 -z
}
