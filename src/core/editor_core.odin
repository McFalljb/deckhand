package core

// From src/editor.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

// What a tab shows: the file, or a read-only diff of it.
Editor_View :: enum u8 {
	File,
	Diff_Disk, // buffer vs the file on disk ("Compare" on the changed-on-disk banner)
	Diff_Head, // buffer vs git HEAD
	Changes, // a Changes tab's diff (changes.odin)
}
