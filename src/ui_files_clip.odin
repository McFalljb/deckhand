package main

// The Files tree's file clipboard (phase 5): ⌘C copies the selection (as paths; the system
// clipboard gets them as text too, shell-quoted and space-separated, for a terminal), ⌘X cuts it
// (its rows dim until a paste or Esc), ⌘V pastes into the selected folder, else the selected
// file's folder, else the root: a copy is fs_copy per item ("name copy" on a clash), a cut is
// rename_path per item (a clash is refused, never renamed). ⌘D duplicates the selection in place.
// A drag with ⌥ held at the release copies instead of moving. And the tree's own Move to Trash
// (⌘⌫, the menu), which asks nothing where the core can put it back (delete_path undoable; the
// toast's Undo, ui_files_undo.odin).
//
// fs_copy is long-running and one at a time: a paste's items run in order, each waiting for its
// finished event (files_copy_on_event: window.test_event sees it in process and, over core.sock,
// the ones this window follows), then the toast says what was copied and what was left out, and
// the copies are selected. The clipboard is this window's only: it holds paths captured when ⌘C
// or ⌘X was pressed, never rows. Text on the system clipboard never pastes into the tree.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
Clip :: struct {
	paths: [dynamic]string, // owned: what ⌘C or ⌘X took
	cut:   bool,
}

@(private = "file")
clip: Clip

@(private = "file")
Copy_Job :: struct {
	running:    bool,
	items:      [dynamic]core.Files_Copy_Item, // owned strings: still to start, in order
	total:      int,
	made:       [dynamic]string, // owned: the copies made
	skipped:    [dynamic]string, // owned: what they left out, as the toast names it
	label:      string, // owned: where they go ("src/"); "" = duplicates
	root:       string, // owned: the tree's root at the start
	request_id: u64, // the running fs_copy's (0: its answer not in yet)
	early:      [dynamic]Early, // finished events seen before the request id was known
	finished:   bool, // the running one's finished came: result
	result:     core.Result, // heap
}

@(private = "file")
Early :: struct {
	request_id: u64,
	result:     core.Result, // heap
}

@(private = "file")
job: Copy_Job

// While a ⌥-drag (files_drag_alt): the drop copies.
files_drag_copy: bool

// The modifiers of a drag's latest event: whether ⌥ is held. True: it changed.
files_drag_alt :: proc(mods: u32) -> bool {
	on := mods & sapp.MODIFIER_ALT != 0
	if on == files_drag_copy do return false
	files_drag_copy = on
	app.redraw = true
	return true
}

// ---- the selection, the clipboard ----

// What ⌘C, ⌘X, ⌘D and Move to Trash act on: the selected rows that show (nested ones once), else
// the cursor's row; never the root. Temp.
files_clip_selection :: proc() -> []string {
	v := core.tree_view()
	root := core.files_root()
	sel := core.files_sel_paths(v, core.tree_rows())
	if len(sel) == 0 && v.cursor != "" && core.files_row_of(core.tree_rows(), v.cursor) >= 0 do sel = []string{v.cursor}
	out := make([dynamic]string, context.temp_allocator)
	for p in core.files_drop_sources(sel) do if p != root && core.within(p, root) do append(&out, p)
	return out[:]
}

// The paths a menu on path acts on: the selection it is in, else path alone (never the root).
@(private = "file")
menu_paths :: proc(path: string) -> []string {
	if multi := files_menu_multi(path); multi != nil do return core.files_drop_sources(multi)
	if path == "" || path == core.files_root() do return nil
	out := make([]string, 1, context.temp_allocator)
	out[0] = path
	return out
}

@(private = "file")
clip_set :: proc(paths: []string, cut: bool) {
	context.allocator = runtime.heap_allocator()
	for p in clip.paths do delete(p)
	clear(&clip.paths)
	for p in paths do append(&clip.paths, strings.clone(p))
	clip.cut = cut && len(paths) > 0
	app.redraw = true
}

// ⌘C (cut false) or ⌘X: the paths go on the window's file clipboard; ⌘C puts them on the system
// clipboard as text too (shell-quoted, space-separated: a terminal's paste takes them as words).
files_clip_take :: proc(paths: []string, cut: bool) {
	if len(paths) == 0 do return
	clip_set(paths, cut)
	if !cut && win_os.set_clipboard != nil {
		b := strings.builder_make(context.temp_allocator)
		for p, i in paths {
			if i > 0 do strings.write_byte(&b, ' ')
			strings.write_string(&b, shell_quote(p))
		}
		win_os.set_clipboard(strings.to_string(b))
	}
	what := core.files_what(paths)
	toast_show(cut ? fmt.tprintf("Cut %s: ⌘V in a folder moves it there", what) : fmt.tprintf("Copied %s: ⌘V in a folder pastes a copy", what))
}

// A row the clipboard holds as cut (drawn dimmed until the paste or Esc).
files_clip_is_cut :: proc(path: string) -> bool {
	if !clip.cut do return false
	for p in clip.paths do if p == path do return true
	return false
}

// Esc: a cut is taken back (nothing moves). True: there was one.
files_clip_cancel_cut :: proc() -> bool {
	if !clip.cut do return false
	clip_set(nil, false)
	return true
}

files_clip_has :: proc() -> bool {return len(clip.paths) > 0}

// The tree has the keyboard (the Edit menu's Cut, Copy, Paste act on it then).
files_tree_keys :: proc() -> bool {return files_shown() && state.focus_widget == "files"}

// ⌘V: the clipboard into the folder the selection says (core.files_paste_target).
files_clip_paste :: proc() {
	root := core.files_root()
	if len(clip.paths) == 0 || root == "" do return // nothing of the tree's (text never pastes here)
	v := core.tree_view()
	cursor := v.cursor
	if core.files_row_of(core.tree_rows(), cursor) < 0 do cursor = "" // not a row that shows: the root
	dir := core.files_paste_target(root, cursor, cursor != "" && core.path_kind(cursor) == .Dir)
	paths := make([]string, len(clip.paths), context.temp_allocator)
	for p, i in clip.paths do paths[i] = strings.clone(p, context.temp_allocator)
	if clip.cut {
		files_move_into(paths, dir)
		return
	}
	files_copy_start(core.files_copy_items(paths, dir, proc(p: string) -> bool {return os.exists(p)}), core.files_drop_dir_label(root, dir))
}

// A cut's paste: each item renamed into dir (rename_path; its rules, the core's), in order,
// stopping at the first refusal; refused as a whole first when a name is taken there (never
// "name copy") or one would go into itself. The moved items are selected; Undo moves them back.
@(private = "file")
files_move_into :: proc(paths: []string, dir: string) {
	root := core.files_root()
	label := core.files_drop_dir_label(root, dir)
	if why := core.files_cut_refused(paths, dir, label, proc(p: string) -> bool {return os.exists(p)}); why != "" {
		toast_show(fmt.tprintf("Not moved: %s", why), err = true)
		return
	}
	moves := core.files_drop_moves(paths, dir)
	if len(moves) == 0 {
		clip_set(nil, false) // already there
		return
	}
	done, froms := make([dynamic]string, context.temp_allocator), make([dynamic]string, context.temp_allocator)
	stopped := ""
	for m in moves {
		r := ui_run(core.Rename_Path{from = m.from, to = m.to})
		if !r.ok {
			stopped = fmt.tprintf("%s: %s", filepath.base(m.from), r.error)
			break
		}
		append(&done, m.to)
		append(&froms, m.from)
		core.files_path_changed(m.from)
		core.files_path_changed(m.to)
	}
	if len(done) > 0 do clip_set(nil, false) // what moved is no longer on the clipboard
	serial := files_undo_record(.Move, root, done[:], froms[:])
	what := core.files_what(done[:])
	switch {
	case stopped != "" && len(done) == 0: toast_show(fmt.tprintf("Not moved %s", stopped), err = true)
	case stopped != "":                   toast_show(fmt.tprintf("Moved %s to %s, then stopped: %s", what, label, stopped), err = true)
	case:                                 files_toast_undo(fmt.tprintf("Moved %s to %s", what, label), serial)
	}
	files_select_made(root, done[:])
}

// The new or moved items selected where they are (their folder's row while it is closed).
@(private = "file")
files_select_made :: proc(root: string, made: []string) {
	if len(made) == 0 || core.files_root() != root do return
	v := core.tree_view()
	dir := core.tdir(made[0])
	if dir == root || core.files_is_open(dir) {
		core.files_select_in(v, made[0])
		if len(made) > 1 do core.files_sel_set(v, made)
	} else do core.files_select_in(v, dir)
	app.redraw = true
}

// ⌘D: the selection duplicated in place ("a copy.txt").
files_duplicate :: proc(paths: []string) {
	if len(paths) == 0 do return
	files_copy_start(core.files_duplicate_items(paths), "")
}

// A drop with ⌥ held at dir (core.files_copy_drop_at's, not refused): the sources copied there.
files_copy_drop_run :: proc(sources: []string, dir: string) {
	root := core.files_root()
	files_copy_start(core.files_copy_items(sources, dir, proc(p: string) -> bool {return os.exists(p)}), core.files_drop_dir_label(root, dir))
}

// ---- the copy, one item after another ----

// Starts copying items (label: where to, "" = duplicates). One paste at a time: another while
// one runs is refused.
files_copy_start :: proc(items: []core.Files_Copy_Item, label: string) {
	if len(items) == 0 do return
	if job.running {
		toast_show("A copy is still running", err = true)
		return
	}
	context.allocator = runtime.heap_allocator()
	job_reset()
	job.running = true
	for it in items do append(&job.items, core.Files_Copy_Item{from = strings.clone(it.from), to = strings.clone(it.to), unique = it.unique})
	job.total = len(items)
	job.label = strings.clone(label)
	job.root = strings.clone(core.files_root())
	toast_show(fmt.tprintf("Copying %s…", len(items) == 1 ? filepath.base(items[0].from) : fmt.tprintf("%d items", len(items))))
	copy_next()
}

// Whether a paste is copying now.
files_copy_running :: proc() -> bool {return job.running}

// The next item's fs_copy (its answer waited for: pending, then its finished); none left: the end.
@(private = "file")
copy_next :: proc() {
	for job.running && !job.finished {
		if len(job.items) == 0 {
			copy_end("")
			return
		}
		it := job.items[0]
		ordered_remove(&job.items, 0)
		defer {delete(it.from); delete(it.to)}
		job.request_id = 0
		r, rid := client_run_req(core.Fs_Copy{from = it.from, to = it.to, unique = it.unique}, wait = FILES_COPY_ANSWER)
		if !r.ok {
			copy_end(fmt.tprintf("%s: %s", filepath.base(it.from), r.error))
			return
		}
		if !r.pending {
			copy_got(r) // answered at once (a core that finished it in the same turn)
			continue
		}
		if rid == 0 {
			// the core took it but its answer came too late to follow: it runs on, unwatched
			copy_end(fmt.tprintf("%s: still copying (Deckhand's core answered late; the tree shows it when done)", filepath.base(it.from)))
			return
		}
		job.request_id = rid
		for e in job.early do if e.request_id == rid {
			job.result = core.result_clone(e.result, runtime.heap_allocator())
			job.finished = true
			app.redraw = true // files_copy_tick takes it
		}
		early_clear()
		return // its finished event: files_copy_on_event, then files_copy_tick
	}
}

// How long the window waits for fs_copy's answer (its checks count the tree first).
FILES_COPY_ANSWER :: 5 * time.Second

// Every event the window's core hook sees (window.test_event): a running copy's finished is kept
// for files_copy_tick (never acted on here: this runs inside the core's drain).
files_copy_on_event :: proc(ev: core.Event) {
	context.allocator = runtime.heap_allocator()
	f, ok := ev.(core.Finished_Event)
	if !ok || !job.running || job.finished do return
	if job.request_id == 0 {
		append(&job.early, Early{request_id = f.request_id, result = core.result_clone(f.result, runtime.heap_allocator())})
		return
	}
	if f.request_id != job.request_id do return
	job.result = core.result_clone(f.result, runtime.heap_allocator())
	job.finished = true
	app.redraw = true
}

@(private = "file")
early_clear :: proc() {
	for e in job.early do core.result_free(e.result)
	clear(&job.early)
}

// Per frame: a copy's finished event came; the next item starts. True: draw again.
files_copy_tick :: proc() -> bool {
	if !job.running || !job.finished do return false
	r := job.result
	job.result = {}
	job.finished = false
	defer core.result_free(r)
	if !r.ok {
		copy_end(r.error)
		return true
	}
	copy_got(r)
	copy_next()
	return true
}

// One item copied: its path and what it left out.
@(private = "file")
copy_got :: proc(r: core.Result) {
	context.allocator = runtime.heap_allocator()
	path, skipped := core.files_copy_result(r.data)
	if path != "" {
		append(&job.made, strings.clone(path))
		core.files_path_changed(path) // listed again (a separate core's own watcher marks its listings)
	}
	for s in skipped do append(&job.skipped, strings.clone(s))
}

// The paste ended (err: why it stopped, as the core worded it; "" = all copied): the toast,
// the undo record, the copies selected.
@(private = "file")
copy_end :: proc(err: string) {
	made := make([]string, len(job.made), context.temp_allocator)
	for p, i in job.made do made[i] = strings.clone(p, context.temp_allocator)
	root := strings.clone(job.root, context.temp_allocator)
	dup := job.label == ""
	label := strings.clone(job.label, context.temp_allocator)
	total := job.total
	skipped := core.files_skipped_text(job.skipped[:])
	job_reset()
	serial := files_undo_record(.Copy, root, made, nil)
	if err != "" && len(made) == 0 {
		toast_show(fmt.tprintf("Not copied: %s", err), err = true)
		return
	}
	what := core.files_what(made)
	text: string
	switch {
	case err != "":
		text = fmt.tprintf("Copied %d of %d, then %s", len(made), total, err)
	case dup:
		text = fmt.tprintf("Duplicated as %s", what)
	case:
		text = fmt.tprintf("Copied %s to %s", what, label)
	}
	if skipped != "" do text = fmt.tprintf("%s; %s", text, skipped)
	if err != "" do toast_show(text, err = true)
	else do files_toast_undo(text, serial)
	files_select_made(root, made)
}

@(private = "file")
job_reset :: proc() {
	context.allocator = runtime.heap_allocator()
	for it in job.items {
		delete(it.from)
		delete(it.to)
	}
	clear(&job.items)
	for p in job.made do delete(p)
	clear(&job.made)
	for p in job.skipped do delete(p)
	clear(&job.skipped)
	delete(job.label)
	delete(job.root)
	early_clear()
	if job.finished do core.result_free(job.result)
	job.label, job.root, job.result = "", "", {}
	job.running, job.finished, job.request_id, job.total = false, false, 0, 0
}

// ---- the tree's own delete ----

// ⌘⌫ and Move to Trash: the paths to the Trash, the user's own delete (undoable: no confirmation
// where the core can put them back; elsewhere it asks in the bar as before). The toast's Undo puts
// them back.
files_trash :: proc(paths: []string) {
	if len(paths) == 0 do return
	root := core.files_root()
	r := client_run(len(paths) == 1 ? core.Delete_Path{path = paths[0], undoable = true} : core.Delete_Path{paths = paths, undoable = true})
	if !r.ok && r.error == "needs_confirmation" do return // the bar asks (another volume, more than 200 items)
	n, restore := core.files_trash_result(r.data)
	ps, ids := make([]string, len(restore), context.temp_allocator), make([]string, len(restore), context.temp_allocator)
	for x, i in restore do ps[i], ids[i] = x.path, x.id
	serial := files_undo_record(.Trash, root, ps, nil, ids)
	for p in paths do core.files_path_changed(p)
	if !r.ok {
		toast_show(n > 0 ? r.error : fmt.tprintf("Not moved to the Trash: %s", r.error), err = true)
		return
	}
	what := len(paths) == 1 ? filepath.base(paths[0]) : fmt.tprintf("%d items", max(n, len(restore)))
	switch {
	case len(restore) == 0: toast_show(fmt.tprintf("Moved %s to the Trash (the Trash did not say where: no Undo)", what))
	case len(restore) < n:  files_toast_undo(fmt.tprintf("Moved %s to the Trash (%d cannot be put back)", what, n - len(restore)), serial)
	case:                   files_toast_undo(fmt.tprintf("Moved %s to the Trash", what), serial)
	}
}

// ---- keys and the menu ----

// A ⌘ key while the tree has the keyboard (files_key): ⌘C ⌘X ⌘V ⌘D ⌘Z. True: taken.
files_clip_key :: proc(e: ^sapp.Event) -> bool {
	if e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT | sapp.MODIFIER_ALT | sapp.MODIFIER_CTRL) != sapp.MODIFIER_SUPER do return false
	#partial switch e.key_code {
	case .C: files_clip_take(files_clip_selection(), false)
	case .X: files_clip_take(files_clip_selection(), true)
	case .V: files_clip_paste()
	case .D: files_duplicate(files_clip_selection())
	case .Z: files_undo_last()
	case: return false
	}
	app.redraw = true
	return true
}

// The row menu's Cut, Copy, Paste, Duplicate (paths: what it acts on; Paste shows muted while the
// clipboard is empty, and on a selection of several it is not offered).
files_clip_menu_items :: proc(path: string, items: ^[dynamic]core.Menu_Item, multi: bool) {
	if path != core.files_root() {
		append(items, core.Menu_Item{label = "Cut", keys = "⌘X", files = .Cut})
		append(items, core.Menu_Item{label = "Copy", keys = "⌘C", files = .Copy})
	}
	if !multi {
		if files_clip_has() do append(items, core.Menu_Item{label = "Paste", keys = "⌘V", files = .Paste})
		else do append(items, core.Menu_Item{label = "Paste", keys = "⌘V", note = true})
	}
	if path != core.files_root() do append(items, core.Menu_Item{label = "Duplicate", keys = "⌘D", files = .Duplicate})
}

// The row menu's step on path (files_step).
files_clip_step :: proc(path: string, step: core.Files_Step) {
	#partial switch step {
	case .Copy:      files_clip_take(menu_paths(path), false)
	case .Cut:       files_clip_take(menu_paths(path), true)
	case .Paste:     files_clip_paste() // the menu selected its row: into it (a folder) or its folder
	case .Duplicate: files_duplicate(menu_paths(path))
	case .Trash:     files_trash(menu_paths(path))
	}
}
