package core

// The Files tree's copy, cut, paste, duplicate and undo, what is pure of them (the window's
// ui_files_clip.odin and ui_files_undo.odin run them): where a paste goes, the copies and moves it
// makes, a copy drop's target, fs_copy's and delete_path's result data, and the undo records,
// their checks ("changed since") and the commands that undo them. The core keeps every rule of
// its own: these only decide what to ask it.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import jg "../jsonguard"
import "core:encoding/json"

// ---- paste ----

// Where a paste goes: the selected folder, else the selected file's folder, else the root (also
// for a cursor outside root, or none).
files_paste_target :: proc(root, cursor: string, cursor_dir: bool) -> string {
	if cursor == "" || !within(cursor, root) do return root
	if cursor_dir do return cursor
	context.allocator = context.temp_allocator
	return filepath.dir(cursor)
}

Files_Copy_Item :: struct {
	from, to: string,
	unique:   bool, // the name is taken (or one before it in this paste takes it): "name copy"
}

// The copies a paste (or a copy drop) of sources into dir makes, in order: each source (nested
// ones once: a folder copies what is in it) to dir/its name; unique when that name is taken, by
// exists or by an item before it (a source in dir already: a duplicate). Temp allocator.
files_copy_items :: proc(sources: []string, dir: string, exists: proc(path: string) -> bool) -> []Files_Copy_Item {
	context.allocator = context.temp_allocator
	out := make([dynamic]Files_Copy_Item)
	names := make(map[string]bool)
	for s in files_drop_sources(sources) {
		name := filepath.base(s)
		to := strings.concatenate({dir, "/", name})
		taken := name in names || (exists != nil && exists(to))
		names[name] = true
		append(&out, Files_Copy_Item{from = s, to = to, unique = taken})
	}
	return out[:]
}

// Duplicate: each source (nested ones once) copied next to itself (from = to, unique). Temp.
files_duplicate_items :: proc(sources: []string) -> []Files_Copy_Item {
	context.allocator = context.temp_allocator
	out := make([dynamic]Files_Copy_Item)
	for s in files_drop_sources(sources) do append(&out, Files_Copy_Item{from = s, to = s, unique = true})
	return out[:]
}

// A drop with ⌥ held copies: the target as files_drop_at's (into a folder row, a file row's
// folder, below the rows the root; only this tree's items, never the root), but a taken name is
// no refusal (the copy is "name copy") and the sources' own folder is no no-op (it duplicates).
// Refused only into one of them or below it. Temp allocator.
files_copy_drop_at :: proc(input: Files_Drop_Input) -> Files_Drop {
	context.allocator = context.temp_allocator
	if input.root == "" || len(input.sources) == 0 do return {}
	dir := input.root
	if input.over != "" do dir = input.over_dir ? input.over : filepath.dir(input.over)
	if !within(dir, input.root) do return {}
	srcs := files_drop_sources(input.sources)
	for s in srcs do if s == input.root || !within(s, input.root) {
		return {dir = dir, refused = fmt.tprintf("%s is not in this tree", filepath.base(s))}
	}
	for s in srcs do if within(dir, s) {
		return {dir = dir, refused = fmt.tprintf("cannot copy %s into itself", filepath.base(s))}
	}
	return {dir = dir}
}

// Why a cut's paste into dir cannot run ("" = it can): one of them into itself or below it, a
// name dir already has (never "name copy": a move is never renamed), two of them with one name.
// label: dir as the toast names it. Each move is rename_path's then, with its own rules.
files_cut_refused :: proc(sources: []string, dir, label: string, exists: proc(path: string) -> bool) -> string {
	context.allocator = context.temp_allocator
	srcs := files_drop_sources(sources)
	for s in srcs do if within(dir, s) do return fmt.tprintf("cannot move %s into itself", filepath.base(s))
	names := make(map[string]bool)
	for m in files_drop_moves(srcs, dir) {
		name := filepath.base(m.to)
		if name in names do return fmt.tprintf("two of them are named %s", name)
		names[name] = true
		if exists != nil && exists(m.to) do return fmt.tprintf("%s already has %s", label, name)
	}
	return ""
}

// "a.txt" for one path, else "N items".
files_what :: proc(paths: []string) -> string {
	if len(paths) == 1 do return filepath.base(paths[0])
	return fmt.tprintf("%d items", len(paths))
}

// ---- results ----

// fs_copy's finished data: the copy's path and what it left out, each named as a toast says it
// (a credential as "a credential", never its name; else the entry's name). Temp allocator.
files_copy_result :: proc(data: string) -> (path: string, skipped: []string) {
	context.allocator = context.temp_allocator
	v, err := jg.parse_string(data, .JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	if err != nil || !ok do return "", nil
	path = string(obj["path"].(json.String) or_else "")
	out := make([dynamic]string)
	if arr, is := obj["skipped"].(json.Array); is do for e in arr {
		o, io := e.(json.Object)
		if !io do continue
		why := string(o["why"].(json.String) or_else "")
		rel := string(o["path"].(json.String) or_else "")
		if strings.has_prefix(why, "a credential") do append(&out, "a credential")
		else do append(&out, filepath.base(rel))
	}
	return path, out[:]
}

// "2 skipped: .git, a credential" (at most 3 named, then "and N more"); "" = none.
files_skipped_text :: proc(skipped: []string) -> string {
	if len(skipped) == 0 do return ""
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d skipped: ", len(skipped))
	for s, i in skipped {
		if i == 3 {
			fmt.sbprintf(&b, " and %d more", len(skipped) - 3)
			break
		}
		if i > 0 do strings.write_string(&b, ", ")
		strings.write_string(&b, s)
	}
	return strings.to_string(b)
}

Files_Restore :: struct {
	path, id: string,
}

// delete_path's data: how many moved, and the restore id of each that has one. Temp allocator.
files_trash_result :: proc(data: string) -> (trashed: int, restore: []Files_Restore) {
	context.allocator = context.temp_allocator
	v, err := jg.parse_string(data, .JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	if err != nil || !ok do return 0, nil
	if n, is := obj["trashed"].(json.Integer); is do trashed = int(n)
	else if f, isf := obj["trashed"].(json.Float); isf do trashed = int(f)
	out := make([dynamic]Files_Restore)
	if arr, is := obj["restore"].(json.Array); is do for e in arr {
		o, io := e.(json.Object)
		if !io do continue
		r := Files_Restore{path = string(o["path"].(json.String) or_else ""), id = string(o["id"].(json.String) or_else "")}
		if r.path != "" && r.id != "" do append(&out, r)
	}
	return trashed, out[:]
}

// ---- the user's own delete: Undo instead of a confirmation ----

// delete_path asks no confirmation (the Finder way: the window's toast says Undo) only for the
// user in the window (fs_user_here: never a paired browser, another machine's core, a script, an
// agent or a pi tab), only when the window marked it as the tree's own delete (undoable), and
// only when every item is promised a restore id before anything moves (fs_restore_promised).
// Everyone else, and a delete it cannot promise that for, confirms exactly as before.
files_delete_unasked :: proc(c: Delete_Path, caller: Caller, plan: []string) -> bool {
	return c.undoable && c.confirm == "" && fs_user_here(caller) && fs_restore_promised(plan)
}

// Whether moving these (checked) paths to the Trash gives each a restore id, known before any
// moves: test mode's fake Trash always; else at most FS_RESTORE_MAX of them (more would push the
// first ids out), each on the volume of the user's home folder, whose Trash says where it put an
// item (macOS: ~/.Trash, trashItemAtURL's resultingItemURL; Linux: the XDG home Trash, which
// refuses another file system anyway). Another volume (a USB disk, a network share, a disk image)
// may have no Trash or not say: there it asks first, as before.
fs_restore_promised :: proc(plan: []string) -> bool {
	if len(plan) == 0 || len(plan) > FS_RESTORE_MAX do return false
	if autotest_active do return true
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" do return false
	hs, _, hok := files_lstamp(home)
	if !hok do return false
	for p in plan {
		s, _, ok := files_lstamp(p)
		if !ok || s.dev != hs.dev do return false
	}
	return true
}

// ---- undo ----

FILES_UNDO_MAX :: 20 // operations kept

Files_Undo_Kind :: enum u8 {
	Create, // a new file or folder: undo moves it to the Trash while it is as it was made (a folder: empty)
	Move, // a rename or move: undo renames it back
	Copy, // a copy or duplicate: undo moves the copy to the Trash while it is as it was made
	Trash, // a delete: undo puts it back (restore_path)
}

Files_Undo_Item :: struct {
	path:  string, // Create, Copy: what was made; Move: where it went; Trash: where it was
	from:  string, // Move: where it was
	id:    string, // Trash: its restore id
	stamp: Disk_Stamp, // Create, Copy, Move: the item as the operation left it (lstat)
	dir:   bool,
	tree:  Files_Tree_Stamp, // Create, Copy of a folder: everything in it then
}

// A folder's whole tree, for "changed since": how many entries and the newest modification
// time among them (links not followed). over: past FILES_UNDO_WALK_MAX entries (never undone).
Files_Tree_Stamp :: struct {
	n:      int,
	newest: i64,
	over:   bool,
}

FILES_UNDO_WALK_MAX :: 20_000 // entries looked at in a folder's tree (fs_copy's own limit)

// The tree under folder path (not path itself), walked without following links, bounded.
files_tree_stamp :: proc(path: string) -> (s: Files_Tree_Stamp) {
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, path)
	for len(stack) > 0 {
		d := pop(&stack)
		f, err := os.open(d)
		if err != nil {
			s.over = true // unreadable: never "unchanged"
			return
		}
		names, rerr := os.read_dir(f, -1, context.temp_allocator)
		os.close(f)
		if rerr != nil {
			s.over = true
			return
		}
		for fi in names {
			s.n += 1
			if s.n > FILES_UNDO_WALK_MAX {
				s.over = true
				return
			}
			full := strings.concatenate({d, "/", fi.name}, context.temp_allocator)
			st, isdir, ok := files_lstamp(full)
			if !ok do continue
			s.newest = max(s.newest, st.mtime)
			if isdir do append(&stack, full)
		}
	}
	return
}

Files_Undo :: struct {
	kind:   Files_Undo_Kind,
	root:   string, // the tree's root then: every path is inside it
	items:  []Files_Undo_Item,
	serial: u64, // which one (a toast's Undo acts only on the last)
}

// The window's undo stack (heap): one tree root's last FILES_UNDO_MAX operations, newest last.
Files_Undo_Stack :: struct {
	root:   string,
	ops:    [dynamic]Files_Undo,
	serial: u64,
}

// The item at path as lstat sees it (not following a link). ok false: nothing there.
files_lstamp :: proc(path: string) -> (s: Disk_Stamp, dir: bool, ok: bool) {
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK do return {}, false, false
	return stamp_of_stat(&st), posix.S_ISDIR(st.st_mode), true
}

// An undo record for the items at paths now (heap; Create, Copy: from ""; Move: froms[i]).
// Items no longer there are left out.
files_undo_make :: proc(kind: Files_Undo_Kind, root: string, paths: []string, froms: []string = nil, ids: []string = nil) -> Files_Undo {
	h := context.allocator
	items := make([dynamic]Files_Undo_Item, h)
	for p, i in paths {
		it := Files_Undo_Item{path = strings.clone(p, h)}
		if froms != nil do it.from = strings.clone(froms[i], h)
		if ids != nil do it.id = strings.clone(ids[i], h)
		if kind != .Trash {
			s, d, ok := files_lstamp(p)
			if !ok {
				files_undo_item_free(it)
				continue
			}
			it.stamp, it.dir = s, d
			if d && (kind == .Copy || kind == .Create) do it.tree = files_tree_stamp(p)
		}
		append(&items, it)
	}
	return {kind = kind, root = strings.clone(root, h), items = items[:]}
}

@(private = "file")
files_undo_item_free :: proc(it: Files_Undo_Item) {
	delete(it.path)
	delete(it.from)
	delete(it.id)
}

files_undo_free :: proc(u: Files_Undo) {
	for it in u.items do files_undo_item_free(it)
	delete(u.items)
	delete(u.root)
}

// Pushes u (owned by the stack now) for root: another root's operations go first (the stack is one
// tree's), the oldest past FILES_UNDO_MAX too; nothing to undo (no items) is dropped. Its serial.
files_undo_push :: proc(st: ^Files_Undo_Stack, root: string, u: Files_Undo) -> u64 {
	if st.root != root do files_undo_clear(st, root)
	if len(u.items) == 0 {
		files_undo_free(u)
		return 0
	}
	st.serial += 1
	x := u
	x.serial = st.serial
	for len(st.ops) >= FILES_UNDO_MAX {
		files_undo_free(st.ops[0])
		ordered_remove(&st.ops, 0)
	}
	append(&st.ops, x)
	return x.serial
}

// Empties the stack; it is root's from now on.
files_undo_clear :: proc(st: ^Files_Undo_Stack, root: string) {
	for u in st.ops do files_undo_free(u)
	clear(&st.ops)
	if st.root != root {
		delete(st.root)
		st.root = strings.clone(root)
	}
}

// The last operation, for root (nil: none; another root's stack is emptied first).
files_undo_top :: proc(st: ^Files_Undo_Stack, root: string) -> ^Files_Undo {
	if st.root != root do files_undo_clear(st, root)
	if len(st.ops) == 0 do return nil
	return &st.ops[len(st.ops) - 1]
}

// Takes the last operation off (freed).
files_undo_pop :: proc(st: ^Files_Undo_Stack) {
	if len(st.ops) == 0 do return
	files_undo_free(pop(&st.ops))
}

// Why u cannot be undone now ("" = it can), checked against the disk before anything acts: the
// tree shows another root; a path outside the root it was done in; Create and Copy: the item is
// gone or not as it was made (another file there, or a file's size or modification time, a
// folder's contents changed: "changed since"); Move: the item is not the one moved (device and
// inode) or something is where it was (a case-only rename: that same item); Trash: something is
// where it was, or no restore id.
files_undo_check :: proc(u: Files_Undo, root: string) -> string {
	if u.root != root do return "the tree shows another folder now"
	for it in u.items {
		if !within(it.path, u.root) || it.path == u.root do return fmt.tprintf("%s is outside the project", it.path)
		if u.kind == .Move && (!within(it.from, u.root) || it.from == u.root) do return fmt.tprintf("%s is outside the project", it.from)
	}
	for it in u.items {
		name := filepath.base(it.path)
		switch u.kind {
		case .Create, .Copy:
			s, d, ok := files_lstamp(it.path)
			if !ok do return fmt.tprintf("%s is gone", name)
			if d != it.dir || s.dev != it.stamp.dev || s.inode != it.stamp.inode do return fmt.tprintf("%s changed since", name)
			if d {
				// a new folder: still empty; a copied one: nothing added or taken out at its top
				if u.kind == .Create && !files_dir_empty(it.path) do return fmt.tprintf("%s changed since (it is not empty)", name)
				if u.kind == .Copy {
					// the whole tree as the copy left it: an edit or a new file deep inside counts
					now := files_tree_stamp(it.path)
					if s.mtime != it.stamp.mtime || it.tree.over || now.over || now != it.tree do return fmt.tprintf("%s changed since", name)
				}
			} else if s.size != it.stamp.size || s.mtime != it.stamp.mtime {
				return fmt.tprintf("%s changed since", name)
			}
		case .Move:
			s, _, ok := files_lstamp(it.path)
			if !ok || s.dev != it.stamp.dev || s.inode != it.stamp.inode do return fmt.tprintf("%s changed since", name)
			// where it was: free (or that same item, a case-only rename on a volume that ignores case)
			if f, _, there := files_lstamp(it.from); there && !(f.dev == s.dev && f.inode == s.inode) {
				return fmt.tprintf("%s is taken", filepath.base(it.from))
			}
		case .Trash:
			if it.id == "" do return fmt.tprintf("%s cannot be put back", name)
			if _, _, there := files_lstamp(it.path); there do return fmt.tprintf("something is at %s now", name)
		}
	}
	return ""
}

// Whether folder path holds nothing.
files_dir_empty :: proc(path: string) -> bool {
	f, err := os.open(path)
	if err != nil do return false
	defer os.close(f)
	names, rerr := os.read_dir(f, 1, context.temp_allocator)
	return rerr == nil && len(names) == 0
}

// The commands that undo u, in order (temp): Create, Copy: one delete_path of them all (the
// window's own, undoable: no confirmation where the Trash gives restore ids); Move: each renamed
// back, the last first; Trash: each restore_path.
files_undo_commands :: proc(u: Files_Undo) -> []Command {
	context.allocator = context.temp_allocator
	out := make([dynamic]Command)
	switch u.kind {
	case .Create, .Copy:
		// a folder (a copy's may hold the user's work since): no undoable, the bar asks first
		paths := make([]string, len(u.items))
		folder := false
		for it, i in u.items {
			paths[i] = it.path
			if it.dir && u.kind == .Copy do folder = true
		}
		append(&out, Delete_Path{paths = paths, undoable = !folder})
	case .Move:
		#reverse for it in u.items do append(&out, Rename_Path{from = it.path, to = it.from})
	case .Trash:
		for it in u.items do append(&out, Restore_Path{id = it.id})
	}
	return out[:]
}

// What undoing u did, for its toast: "Moved a.txt back", "Put back 3 items".
files_undo_done_text :: proc(u: Files_Undo) -> string {
	paths := make([]string, len(u.items), context.temp_allocator)
	for it, i in u.items do paths[i] = it.path
	what := files_what(paths)
	switch u.kind {
	case .Create, .Copy: return fmt.tprintf("Undone: %s moved to the Trash", what)
	case .Move:   return fmt.tprintf("Undone: %s moved back", what)
	case .Trash:  return fmt.tprintf("Undone: %s put back", what)
	}
	return "Undone"
}

// Why the window's file clipboard cannot paste into the tree at root now ("" = it can): a cut is
// that tree's only (clip_root: where it was cut; never moved into another project or checkout
// from a clipboard); a path the tree hides now (ignored rows hidden: hidden, files_path_hidden) is
// never pasted, cut or copied. A copy into another project is the core's to allow (fs_copy).
files_clip_refused :: proc(root, clip_root: string, paths: []string, cut: bool, hidden: proc(root, path: string) -> bool) -> string {
	if cut && clip_root != root do return "the cut items are in another project or checkout: cut them again here"
	if hidden != nil do for p in paths do if hidden(clip_root, p) {
		return fmt.tprintf("%s is hidden now (ignored files are hidden): show them, or copy again", filepath.base(p))
	}
	return ""
}

// An undo of the last record that stopped after done of its commands (files_undo_commands): the
// record keeps only what was not undone (Trash: the ones after them; Move: the first ones, as
// moves undo the last first); none left: it goes.
files_undo_keep_rest :: proc(st: ^Files_Undo_Stack, done: int) {
	if len(st.ops) == 0 do return
	u := &st.ops[len(st.ops) - 1]
	n := len(u.items)
	if done <= 0 do return
	if done >= n {
		files_undo_pop(st)
		return
	}
	lo, hi := done, n // Trash: in order
	if u.kind == .Move do lo, hi = 0, n - done
	kept := make([]Files_Undo_Item, hi - lo)
	for it, i in u.items {
		if i >= lo && i < hi do kept[i - lo] = it
		else do files_undo_item_free(it)
	}
	delete(u.items)
	u.items = kept
}
