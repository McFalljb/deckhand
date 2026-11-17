package core

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
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
	since:   string, // the hash of the listing the caller has: unchanged, it answers same (no entries)
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
	paths:   []string, // a batch (path, if given, is one more): all checked before any moves, one confirmation (fs_delete_plan)
	confirm: string,
	undoable: bool, // the user's own delete in the window's Files tree: no confirmation when every item gets a restore id (fs_restore_promised; the window's Undo puts them back)
}

Reveal_In_Finder :: struct {
	path: string,
}

// A file or folder tree copied inside projects (fs_copy.odin): to is the copy's full path; unique:
// a taken name becomes "name copy", "name copy 2", … (else refused; never over anything). Confirms
// as create_file (class fs_write). Long-running: pending, then a finished event.
Fs_Copy :: struct {
	from, to: string,
	unique:   bool,
	confirm:  string,
}

// The fuzzy file filter the Files tree has, for a browser (fs_find_files): root a project folder
// ("" = the caller's), limit results (0 = 100, at most 500).
Find_Files :: struct {
	root, query: string,
	limit:       int,
}

// Puts an item delete_path moved to the Trash back where it was, by the restore id its result
// gave (fs_restore.odin). The user's at this window only.
Restore_Path :: struct {
	id: string,
}

// Internal: a worker refreshed a project's file list (NUL-separated paths).
File_List_Done :: struct {
	root, out: string,
}

// ---- the project's files (rows in command_table.odin): the core's own, no window needed ----

// list_dir's answer with its hash first ({"hash":…,"path":…,…}); since = that hash: only
// {"hash","path","same":true} (a browser's poll of an unchanged folder sends no entries).
// Temp allocator.
list_dir_since :: proc(data, since: string) -> string {
	h := fmt.tprintf("%016x", hash.fnv64a(transmute([]u8)data))
	if since != "" && since == h {
		p := strings.index(data, `,"`) // after {"path":"…" (a quote inside the path is escaped)
		if p < 0 do p = len(data) - 1
		return fmt.tprintf(`{{"hash":"%s",%s,"same":true}}`, h, data[1:p])
	}
	return fmt.tprintf(`{{"hash":"%s",%s`, h, data[1:])
}

// File commands: the path is resolved (for this caller) before any confirmation, and the
// confirmation parks and shows that absolute path, so confirming later acts on the same file
// whatever is on screen.
files_cmd_apply :: proc(cmd: Command, caller: Caller, request_id: u64 = 0) -> (r: Result, changed: bool) {
	quoted :: proc(s: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		json_quote(&b, s)
		return strings.to_string(b)
	}
	#partial switch c in cmd {
	case List_Dir:
		data, err := fs_list_json(c.path, caller, c.ignored)
		if err != "" do return fail(err), false
		return {ok = true, data = strings.clone(list_dir_since(data, c.since))}, false
	case Create_File, Create_Dir:
		path, confirm := "", ""
		dir := false
		#partial switch x in cmd {
		case Create_File: path, confirm = x.path, x.confirm
		case Create_Dir:  path, confirm, dir = x.path, x.confirm, true
		}
		// the path as this caller names it: what a confirmation is bound to
		p, _, err := fs_check_write(path, caller)
		if err != "" do return fail(err), false
		parked: Command = dir ? Command(Create_Dir{path = p}) : Command(Create_File{path = p})
		ch := false
		rules := caller
		if confirm != "" {
			// a confirmation: the entry is used up, then the asker's rules decide
			gr, go_on, gch, asker := confirm_use(parked, .Fs_Write, caller, confirm)
			if !go_on do return gr, gch
			ch, rules = gch, asker
			if _, _, e := fs_check_write(p, rules); e != "" do return fail(e), ch
		} else if caller.kind == .Control && fs_outside_own(p, caller) {
			gr, go_on, gch := confirm_gate(parked, .Fs_Write, caller, "", fmt.tprintf("create %s %s?", dir ? "the folder" : "the file", p))
			if !go_on do return gr, gch
			ch = gch
		}
		created: string
		if dir do created, err = fs_create_dir(p, rules)
		else do created, err = fs_create_file(p, rules)
		if err != "" do return fail(err), ch
		return {ok = true, data = fmt.aprintf(`{{"path":%s}}`, quoted(created))}, ch
	case Rename_Path:
		a, _, e1 := fs_check_write(c.from, caller)
		if e1 != "" do return fail(e1), false
		b, _, e2 := fs_check_write(c.to, caller)
		if e2 != "" do return fail(e2), false
		ch := false
		rules := caller
		if c.confirm != "" {
			gr, go_on, gch, asker := confirm_use(Rename_Path{from = a, to = b}, .Fs_Write, caller, c.confirm)
			if !go_on do return gr, gch
			ch, rules = gch, asker
			if _, _, e := fs_check_write(a, rules); e != "" do return fail(e), ch
			if _, _, e := fs_check_write(b, rules); e != "" do return fail(e), ch
		} else if caller.kind == .Control && (fs_outside_own(a, caller) || fs_outside_own(b, caller)) {
			gr, go_on, gch := confirm_gate(Rename_Path{from = a, to = b}, .Fs_Write, caller, "", fmt.tprintf("rename %s to %s?", a, b))
			if !go_on do return gr, gch
			ch = gch
		}
		if err := fs_rename(a, b, rules); err != "" do return fail(err), ch
		return {ok = true}, true // open tabs may have new titles
	case Delete_Path:
		if len(c.paths) > 0 do return delete_batch_apply(c, caller)
		p, _, err := fs_check_write(c.path, caller)
		if err != "" do return fail(err), false
		if !os.exists(p) do return fail("no such file or folder"), false
		ch := false
		rules := caller
		if c.confirm != "" {
			gr, go_on, gch, asker := confirm_use(Delete_Path{path = p}, .Delete, caller, c.confirm)
			if !go_on do return gr, gch
			ch, rules = gch, asker
		} else {
			// every rule before asking (as a batch does), and again when it runs
			if _, e := fs_delete_check(p, caller); e != "" do return fail(e), false
			gr, go_on, gch := confirm_gate(Delete_Path{path = p}, .Delete, caller, "", fmt.tprintf("move %s to the Trash?", p), skip = files_delete_unasked(c, caller, []string{p})) // the tree's own: Undo instead
			if !go_on do return gr, gch
			ch = gch
		}
		checked, derr := fs_delete_check(p, rules)
		id := ""
		if derr == "" do derr, id = fs_trash_checked(checked)
		if derr != "" do return fail(derr), ch
		ids := [1]string{id}
		paths := [1]string{checked}
		return {ok = true, data = fmt.aprintf(`{{"trashed":1%s}}`, restore_json(paths[:], ids[:]))}, ch
	case Fs_Copy:
		return fs_copy_apply(c, caller, request_id)
	case Fs_Copy_Done:
		fs_copy_done(c)
		return {ok = true}, true
	case Find_Files:
		data, err := fs_find_files(c.root, c.query, c.limit, caller)
		if err != "" do return fail(err), false
		return {ok = true, data = strings.clone(data)}, false
	case Restore_Path:
		p, err := fs_restore(c.id, caller)
		if err != "" do return fail(err), false
		return {ok = true, data = fmt.aprintf(`{{"path":%s}}`, quoted(p))}, true
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

// delete_path with paths: every path checked (fs_delete_plan) before the one confirmation (class
// delete, as one path), then each to the Trash in turn. data {"trashed": n}; a Trash that fails
// midway stops there: the error says how many went (they stay in the Trash) and data adds
// "failed": the path it stopped at.
@(private = "file")
delete_batch_apply :: proc(c: Delete_Path, caller: Caller) -> (r: Result, changed: bool) {
	all := make([dynamic]string, context.temp_allocator)
	if c.path != "" do append(&all, c.path)
	append(&all, ..c.paths)
	// the paths as this caller names them, checked and merged: what a confirmation is bound to
	plan, err := fs_delete_plan(all[:], caller)
	if err != "" do return fail(err), false
	// the checked paths park (one left after nesting: as a single delete_path)
	parked := len(plan) == 1 ? Delete_Path{path = plan[0]} : Delete_Path{paths = plan}
	ch := false
	rules := caller
	if c.confirm != "" {
		// a confirmation: the entry is used up, then every path again by the asker's rules
		gr, go_on, gch, asker := confirm_use(parked, .Delete, caller, c.confirm)
		if !go_on do return gr, gch
		ch, rules = gch, asker
		plan, err = fs_delete_plan(plan, rules)
		if err != "" do return fail(err), ch
	} else {
		gr, go_on, gch := confirm_gate(parked, .Delete, caller, "", fs_delete_summary(plan), skip = files_delete_unasked(c, caller, plan)) // the tree's own: Undo instead
		if !go_on do return gr, gch
		ch = gch
	}
	ids := make([]string, len(plan), context.temp_allocator)
	for p, i in plan {
		// checked again right before it moves (a tab may have started in it since)
		_, derr := fs_delete_check(p, rules) // by the asker's rules
		if derr == "" do derr, ids[i] = fs_trash_checked(p)
		if derr != "" {
			r = fail(fmt.tprintf("moved %d of %d to the Trash, then %s: %s (the %d moved stay in the Trash)", i, len(plan), p, derr, i))
			b := strings.builder_make(context.temp_allocator)
			json_quote(&b, p)
			r.data = fmt.aprintf(`{{"trashed":%d,"failed":%s%s}}`, i, strings.to_string(b), restore_json(plan[:i], ids[:i]))
			return r, true
		}
	}
	return {ok = true, data = fmt.aprintf(`{{"trashed":%d%s}}`, len(plan), restore_json(plan, ids))}, true
}

// A confirmation token sent with a file command: the parked entry it names is used up (confirm_gate:
// the user, or a trusted asker itself; bound to the exact arguments parked), and asker is the caller
// that asked for it, whose rules the command then runs by (an agent's rename confirmed by the user
// still may not move a credential). go_on false: r says why.
@(private = "file")
confirm_use :: proc(cmd: Command, class: Command_Class, caller: Caller, token: string) -> (r: Result, go_on, changed: bool, asker: Caller) {
	asker = caller
	for p in state.pending_confirmations do if p.token == token do asker = p.caller
	r, go_on, changed = confirm_gate(cmd, class, caller, token, "", force_ask = false)
	if !go_on do asker = caller
	return
}

// delete_path's restore ids, as `,"restore":[{"path","id"}]` after its other members: one per item
// moved whose place in the Trash is known (restore_path takes the id). "" = none. Temp allocator.
@(private = "file")
restore_json :: proc(paths, ids: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for id, i in ids {
		if id == "" do continue
		strings.write_string(&b, n == 0 ? `,"restore":[` : ",")
		n += 1
		strings.write_string(&b, `{"path":`)
		json_quote(&b, paths[i])
		strings.write_string(&b, `,"id":`)
		json_quote(&b, id)
		strings.write_byte(&b, '}')
	}
	if n > 0 do strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// fs_copy: every rule checked and the tree counted (fs_copy_plan) before the confirmation (a
// control caller outside its own project, class fs_write, as create_file) and before anything
// is written; then the copy runs on a worker: pending, and a finished event (fs_copy_done).
@(private = "file")
fs_copy_apply :: proc(c: Fs_Copy, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	arena := new(virtual.Arena, runtime.heap_allocator())
	if virtual.arena_init_growing(arena) != nil {
		free(arena, runtime.heap_allocator())
		return fail("out of memory"), false
	}
	keep := false
	defer if !keep {
		virtual.arena_destroy(arena)
		free(arena, runtime.heap_allocator())
	}
	if fs_copy_in_flight() do return fail(FS_COPY_RUNNING), false
	ch := false
	plan: Fs_Copy_Plan
	err: string
	if c.confirm != "" {
		// a confirmation (the bar's Confirm, a browser's, or a trusted asker's own token): the parked
		// entry is used up, and the copy runs by the rules of whoever asked for it, not of who
		// confirmed (an agent's copy confirmed by the user still refuses credentials)
		a, b, perr := fs_copy_paths(c.from, c.to, caller) // as this caller names them: what the token is bound to
		if perr != "" do return fail(perr), false
		gr, go_on, gch, asker := confirm_use(Fs_Copy{from = a, to = b, unique = c.unique}, .Fs_Write, caller, c.confirm)
		if !go_on do return gr, gch
		ch = gch
		plan, err = fs_copy_plan(a, b, c.unique, asker, virtual.arena_allocator(arena))
		if err != "" do return fail(err), ch
	} else {
		plan, err = fs_copy_plan(c.from, c.to, c.unique, caller, virtual.arena_allocator(arena))
		if err != "" do return fail(err), false
		if caller.kind == .Control && (fs_outside_own(plan.from, caller) || fs_outside_own(plan.to, caller)) {
			// parked with the paths as checked (the target as asked: a unique name is picked when it runs)
			a, b, _ := fs_copy_paths(c.from, c.to, caller)
			gr, go_on, gch := confirm_gate(Fs_Copy{from = a, to = b, unique = c.unique}, .Fs_Write, caller, "", fmt.tprintf("copy %s to %s?", a, b))
			if !go_on do return gr, gch // parked (else its policy is auto: on)
			ch = gch
		}
	}
	keep = true
	fs_copy_start(plan, arena, request_id)
	return {ok = true, pending = true}, ch
}
