package core

// From src/editor_commands.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

Editor_Tab :: struct {
	path:    string, // absolute (owned)
	view:    Editor_View,
	preview: bool, // opened with a single click in Files: the next preview replaces it; editing or keep_tab keeps it
}

Open_File :: struct {
	path:    string, // absolute, or relative to the session's folder
	line:    int, // 1-based; 0 = keep the cursor
	col:     int,
	session: u64, // open session (0 = the current one)
	preview: bool, // a preview tab: replaces the session's clean preview tab (a file already open is only focused)
}

// A preview tab becomes an ordinary one (double-click, editing).
Keep_Tab :: struct {
	tab_id: u64,
}

Editor_State :: struct {
	tab_id: u64,
}

Save_File :: struct {
	tab_id: u64,
}

Goto_Line :: struct {
	tab_id:    u64,
	line, col: int,
}

// Discards the buffer for the file on disk (confirms while it has unsaved
// changes, class tab_close; the banner's Reload button is that confirmation).
Reload_File :: struct {
	tab_id:  u64,
	confirm: string,
}

// "Keep mine": the buffer stays as it is after the file changed on disk.
Keep_Buffer :: struct {
	tab_id: u64,
}

// A read-only diff of a file tab against git HEAD or the file on disk.
Diff_File :: struct {
	tab_id:  u64,
	against: Editor_View, // Diff_Head or Diff_Disk
}

Set_Wrap :: struct {
	tab_id: u64,
	on:     bool,
}

List_Dir :: struct {
	path:    string,
	ignored: bool, // also list gitignored entries (marked "ignored")
}

// create_file, create_dir and rename_path confirm (class fs_write) for a
// control caller outside its own project (Atlas, bound to Home, has none).
Create_File :: struct {
	path:    string,
	confirm: string,
}

Create_Dir :: struct {
	path:    string,
	confirm: string,
}

Rename_Path :: struct {
	from, to: string,
	confirm:  string,
}

Delete_Path :: struct {
	path:    string, // moved to the Trash; confirms (class delete)
	confirm: string,
}

Reveal_In_Finder :: struct {
	path: string,
}

// Internal: a worker refreshed a project's file list (NUL-separated paths).
File_List_Done :: struct {
	root, out: string,
}
