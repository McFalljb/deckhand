package core

import "core:fmt"
import "core:os"
import "core:strings"

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

// ---- the project's files (rows in command_table.odin): the core's own, no window needed ----

// File commands: the path is resolved (for this caller) before any confirmation, and the
// confirmation parks and shows that absolute path, so confirming later acts on the same file
// whatever is on screen.
files_cmd_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	quoted :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		json_quote(&b, s)
		return strings.to_string(b)
	}
	#partial switch c in cmd {
	case List_Dir:
		data, err := fs_list_json(c.path, caller, c.ignored)
		if err != "" do return fail(err), false
		return {ok = true, data = strings.clone(data)}, false
	case Create_File, Create_Dir:
		path, confirm := "", ""
		dir := false
		#partial switch x in cmd {
		case Create_File: path, confirm = x.path, x.confirm
		case Create_Dir:  path, confirm, dir = x.path, x.confirm, true
		}
		p, _, err := fs_check_write(path, caller)
		if err != "" do return fail(err), false
		ch := false
		if caller.kind == .Control && fs_outside_own(p, caller) {
			parked: Command = dir ? Command(Create_Dir{path = p}) : Command(Create_File{path = p})
			gr, go_on, gch := confirm_gate(parked, .Fs_Write, caller, confirm, fmt.tprintf("create %s %s?", dir ? "the folder" : "the file", p))
			if !go_on do return gr, gch
			ch = gch
		}
		created: string
		if dir do created, err = fs_create_dir(p, caller)
		else do created, err = fs_create_file(p, caller)
		if err != "" do return fail(err), ch
		return {ok = true, data = fmt.aprintf(`{{"path":%s}}`, quoted(created))}, ch
	case Rename_Path:
		a, _, e1 := fs_check_write(c.from, caller)
		if e1 != "" do return fail(e1), false
		b, _, e2 := fs_check_write(c.to, caller)
		if e2 != "" do return fail(e2), false
		ch := false
		if caller.kind == .Control && (fs_outside_own(a, caller) || fs_outside_own(b, caller)) {
			gr, go_on, gch := confirm_gate(Rename_Path{from = a, to = b}, .Fs_Write, caller, c.confirm, fmt.tprintf("rename %s to %s?", a, b))
			if !go_on do return gr, gch
			ch = gch
		}
		if err := fs_rename(a, b, caller); err != "" do return fail(err), ch
		return {ok = true}, true // open tabs may have new titles
	case Delete_Path:
		p, _, err := fs_check_write(c.path, caller)
		if err != "" do return fail(err), false
		if !os.exists(p) do return fail("no such file or folder"), false
		gr, go_on, ch := confirm_gate(Delete_Path{path = p}, .Delete, caller, c.confirm, fmt.tprintf("move %s to the Trash?", p))
		if !go_on do return gr, ch
		if derr := fs_delete(p, caller); derr != "" do return fail(derr), ch
		return {ok = true}, ch
	case Git_Status_Done:
		git_status_done(c)
		return {ok = true}, false
	case File_List_Done:
		file_list_done(c)
		return {ok = true}, false
	case Reveal_In_Finder:
		if err := fs_reveal_path(c.path, caller); err != "" do return fail(err), false
		return {ok = true}, false
	}
	return fail("unknown command"), false
}
