package main

// The Files tree's undo (phase 6): what this window did in the tree, the last 20 operations of
// the root it shows (another project or checkout empties it): a new file or folder (undo: to the
// Trash while it is as it was made; a folder: empty), a rename or move (undo: renamed back unless
// its old place is taken), a copy or duplicate (undo: the copy to the Trash while it is as it was
// made), a Move to Trash (undo: restore_path with the ids its result gave). ⌘Z while the tree
// has the keyboard undoes the last; each such operation's toast has an Undo button that undoes
// it while it is still the last. Every check runs on the disk before anything acts
// (core.files_undo_check); the core's own rules run again on each command. No redo.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core"

@(private = "file")
undo: core.Files_Undo_Stack

// Records what this window just did in the tree at root (paths: as they are now; Move: froms, where
// they were; Trash: ids, their restore ids). Its serial (0: nothing to undo).
files_undo_record :: proc(kind: core.Files_Undo_Kind, root: string, paths: []string, froms: []string, ids: []string = nil) -> u64 {
	if root == "" || len(paths) == 0 do return 0
	context.allocator = runtime.heap_allocator() // the stack's (core.files_undo_make clones)
	return core.files_undo_push(&undo, root, core.files_undo_make(kind, root, paths, froms, ids))
}

// A toast for an operation; while serial is the last one, it has an Undo button.
files_toast_undo :: proc(text: string, serial: u64) {
	if serial == 0 {
		toast_show(text)
		return
	}
	toast_show_action(text, "Undo", proc(serial: u64) {files_undo_last(serial)}, serial)
}

// Whether ⌘Z has something to undo in the tree on screen.
files_undo_ok :: proc() -> bool {
	return files_shown() && state.focus_widget == "files" && core.files_undo_top(&undo, core.files_root()) != nil
}

// Undoes the last operation (serial: only while it is that one, a toast's Undo; 0: ⌘Z), after
// checking it against the disk: one that cannot be undone is said why and dropped.
files_undo_last :: proc(serial: u64 = 0) {
	root := core.files_root()
	u := core.files_undo_top(&undo, root) // another root on screen: emptied
	if u == nil || (serial != 0 && u.serial != serial) {
		toast_show(serial != 0 ? "Not undone: something else was done in the tree since" : "Nothing to undo in the Files tree")
		return
	}
	if files_copy_running() {
		toast_show("A copy is still running", err = true)
		return
	}
	if why := core.files_undo_check(u^, root); why != "" {
		toast_show(fmt.tprintf("Not undone: %s", why), err = true)
		core.files_undo_pop(&undo)
		return
	}
	done_text := core.files_undo_done_text(u^)
	kind := u.kind
	paths, froms := make([]string, len(u.items), context.temp_allocator), make([]string, len(u.items), context.temp_allocator)
	for it, i in u.items do paths[i], froms[i] = strings.clone(it.path, context.temp_allocator), strings.clone(it.from, context.temp_allocator) // the record goes below
	failed, asks := "", false
	cmds := core.files_undo_commands(u^)
	done := 0
	for c in cmds {
		r := client_run(c)
		if !r.ok && r.error == "needs_confirmation" {
			asks = true // a copied folder (or another disk): the bar asks before it goes to the Trash
			break
		}
		if !r.ok {
			failed = r.error
			break
		}
		done += 1
		#partial switch x in c {
		case core.Rename_Path: core.files_path_changed(x.from); core.files_path_changed(x.to)
		case core.Restore_Path: core.files_path_changed(core.json_path(r.data, "path"))
		}
	}
	for p in paths do core.files_path_changed(p)
	if failed != "" && done > 0 && done < len(cmds) {
		// part of it: what was undone stays undone, the rest stays the last thing to undo
		core.files_undo_keep_rest(&undo, done)
		verb := kind == .Trash ? "Put back" : "Moved back"
		toast_show(fmt.tprintf("%s %d of %d, then: %s (⌘Z tries the rest again)", verb, done, len(cmds), failed), err = true)
		return
	}
	core.files_undo_pop(&undo) // done, asked, or refused: never twice
	if asks {
		toast_show(fmt.tprintf("Confirm in the bar to move %s to the Trash", core.files_what(paths)))
		return
	}
	if failed != "" {
		toast_show(fmt.tprintf("Not undone: %s", failed), err = true)
		return
	}
	toast_show(done_text)
	// what came back is selected
	#partial switch kind {
	case .Trash: files_undo_select(root, paths)
	case .Move:  files_undo_select(root, froms)
	}
	app.redraw = true
}

@(private = "file")
files_undo_select :: proc(root: string, paths: []string) {
	if len(paths) == 0 || core.files_root() != root do return
	core.files_select_in(core.tree_view(), paths[0])
	if len(paths) > 1 do core.files_sel_set(core.tree_view(), paths)
}
