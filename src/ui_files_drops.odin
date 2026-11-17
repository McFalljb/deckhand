package main

// Drops across the Files tree's edges (the rules: core/files_drops.odin).
//
// A tree drag released over the panes acts on the pane under the pointer, and only on it
// (files_pane_drop): a terminal gets the shell-quoted paths pasted, a pi, Claude Code or Codex
// tab gets them typed into its prompt (the same paste: never Enter, never sent), an editor,
// Markdown, browser, Changes or app tab (or a pane with no tab) opens the files there as tabs.
// While dragging, that pane is ringed and the ghost says what will happen (files_pane_drop_layout).
// A release over no pane, over the drawer or over the left column delivers nothing to any pane.
//
// Files dropped from Finder onto the tree's list (the Files tab showing) are copied into the
// folder under the drop (a folder row: into it; a file row: its folder; below the rows: the
// root), one fs_copy at a time with unique names (files_finder_drop, files_drops_tick); a toast
// says what was copied where and what was left out. Elsewhere in the left column folders become
// projects, as before (sidebar_drop). While a Finder drag hovers the list, the target folder shows
// the drop's band (files_finder_hover, from the window's draggingUpdated: platform_darwin's hook).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "core"
import clay "../build/clay-odin"

// ---- the tree onto a pane ----

Pane_Drop_Target :: struct {
	pane:   u64,
	rect:   [4]f32, // its frame (framebuffer px)
	tab_id: u64, // the tab it shows (0: none)
	tab:    core.Pane_Drop_Tab,
	action: core.Pane_Drop,
}

// The pane of the current session under (x, y) and what a drop there does. Nothing over the left
// column, the drawer, a job sheet, or where no pane is laid out (never the focused pane instead).
files_pane_target :: proc(x, y: f32) -> Pane_Drop_Target {
	if over_sidebar(x) || job_sheet_open() do return {}
	if state.home_open && inside(clay.ID("drawer"), x, y) do return {}
	s := core.cur()
	if s == nil do return {}
	for &p in s.panes {
		if core.pane_zoom_hidden(s, p.id) do continue
		r := p.frame.z > 0 ? p.frame : p.rect
		if r.z <= 0 || !(x >= r.x && y >= r.y && x < r.x + r.z && y < r.y + r.w) do continue
		tab := core.pane_tab(s, &p)
		kind := core.pane_drop_tab_of(tab)
		return {pane = p.id, rect = r, tab_id = tab != nil ? tab.id : 0, tab = kind, action = core.pane_drop_action(kind)}
	}
	return {}
}

// A tree drag released at (x, y) outside the left column: paths (captured at the press) go to
// the pane under the pointer only.
files_pane_drop :: proc(paths: []string, x, y: f32) {
	t := files_pane_target(x, y)
	switch t.action {
	case .None:
		if t.tab == .Exited do toast_show("Not dropped: the tab's program is not running", err = true)
	case .Paste_Path, .Insert_Prompt:
		text, err := core.pane_drop_text(t.action, t.tab, paths)
		if err != "" {
			toast_show(fmt.tprintf("Not dropped: %s", err), err = true)
			return
		}
		// Deckhand's text, the user's own gesture: the same paste as a file dropped on a terminal
		// (the core applies a Codex composer's rule on its own state and says why not)
		if r := client_call(core.Send_Text{tab_id = t.tab_id, text = text, generated = true}); !r.ok do toast_show(fmt.tprintf("Not dropped: %s", r.error), err = true)
	case .Open_Here:
		files_open_in_pane(t.pane, paths)
	}
}

// Opens each file as a tab in pane (folders are not opened). A file already open in another pane
// moves here, unless it is that pane's only tab (then it stays, and the toast says so).
@(private = "file")
files_open_in_pane :: proc(pane: u64, paths: []string) {
	s := core.cur()
	if s == nil do return
	sid := s.id
	if r := ui_run(core.Focus_Pane{pane = pane}); !r.ok {
		toast_show(fmt.tprintf("Not opened: %s", r.error), err = true)
		return
	}
	notes := make([dynamic]string, context.temp_allocator)
	opened := 0
	for p in paths {
		name := filepath.base(p)
		if core.path_kind(p) == .Dir {
			append(&notes, fmt.tprintf("%s: a folder", name))
			continue
		}
		r := ui_run(core.Open_File{path = p, session = sid})
		if !r.ok {
			append(&notes, fmt.tprintf("%s: %s", name, r.error))
			continue
		}
		opened += 1
		cs := core.find_session(sid)
		if cs == nil || r.created_id == 0 do continue
		if tp := core.pane_of_tab(cs, r.created_id); tp != nil && tp.id != pane {
			if core.pane_tab_count(cs, tp.id) > 1 do ui_run(core.Move_Tab{tab_id = r.created_id, pane = pane, index = -1})
			else do append(&notes, fmt.tprintf("%s: open in another pane", name))
		}
	}
	if len(notes) > 0 do toast_show(fmt.tprintf("%s%s", opened > 0 ? "Opened the rest; " : "Not opened: ", strings.join(notes[:], "; ", context.temp_allocator)), err = opened == 0)
}

// While a tree drag is over the panes: the pane under the pointer ringed (layout; the ghost's own
// words: files_pane_drop_label). From files_drag_layout, while the drag has left its row.
files_pane_drop_layout :: proc() {
	if over_sidebar(app.pointer.x) do return
	t := files_pane_target(app.pointer.x, app.pointer.y)
	if t.pane == 0 || t.action == .None do return
	th := theme()
	if clay.UI(clay.ID("files_pane_drop"))({
		layout = {sizing = {clay.SizingFixed(t.rect.z), clay.SizingFixed(t.rect.w)}},
		backgroundColor = cc(with_alpha(th.accent, FILES_DROP_TINT / 2)),
		border = {color = cc(th.accent), width = clay.BorderOutside(pu(2 * core.BORDER_W))},
		floating = {attachTo = .Root, offset = {t.rect.x, t.rect.y}, zIndex = 19, pointerCaptureMode = .Passthrough},
	}) {}
}

// What a release at the pointer would do, for the ghost ("" over the left column or nothing).
files_pane_drop_label :: proc() -> string {
	if over_sidebar(app.pointer.x) do return ""
	return core.PANE_DROP_LABELS[files_pane_target(app.pointer.x, app.pointer.y).action]
}

// ---- Finder onto the tree ----

@(private = "file")
Drops_Queue :: struct {
	copies:   [dynamic]core.Files_Drop_Copy, // owned strings
	next:     int, // the next copy to start
	waiting:  u64, // the core's request id of the copy running (0: none)
	name:     string, // owned: its source's name
	retry_at: time.Tick, // another copy was running: try again from then
	label:    string, // owned: the target folder, as the toast names it
	done:     [dynamic]string, // owned: the names copied (as they were made)
	notes:    [dynamic]string, // owned: "name: why" for what was not copied or left out
	finished: [dynamic]Drops_Finished, // finished events that came before their request id was known
}

@(private = "file")
Drops_Finished :: struct {
	request_id: u64,
	ok:         bool,
	error:      string, // owned
	data:       string, // owned
}

@(private = "file")
dq: Drops_Queue

DROPS_RETRY :: 200 * time.Millisecond
DROPS_CALL_WAIT :: 5 * time.Second // a copy's checks count the whole tree first (≤ 20,000 entries)

// Files dropped from Finder at (x, y) in the left column. True: the tree took them (the Files tab
// shows and the drop is on its list); false: not the tree's (sidebar_drop's own rule).
files_finder_drop :: proc(paths: []string, x, y: f32) -> bool {
	files_finder_hover_end()
	root := core.files_root()
	if !files_shown() || root == "" do return false
	over, over_dir, ok := files_drop_over(x, y)
	if !ok do return false
	dir := core.files_finder_drop_dir(root, over, over_dir, ok)
	if dir == "" {
		toast_show("Not copied: no folder of this tree there", err = true)
		return true
	}
	if files_drops_busy() {
		toast_show("Still copying the last drop: drop again once it is done", err = true)
		return true
	}
	copies := core.files_finder_drop_copies(paths, dir)
	if len(copies) == 0 do return true
	heap := runtime.heap_allocator()
	files_drops_reset()
	for c in copies do append(&dq.copies, core.Files_Drop_Copy{from = strings.clone(c.from, heap), to = strings.clone(c.to, heap)})
	dq.label = strings.clone(core.files_drop_dir_label(root, dir), heap)
	files_drops_tick()
	return true
}

files_drops_busy :: proc() -> bool {return dq.next < len(dq.copies) || dq.waiting != 0}

@(private = "file")
files_drops_reset :: proc() {
	heap := runtime.heap_allocator()
	if dq.copies.allocator.procedure == nil {
		dq.copies.allocator, dq.done.allocator, dq.notes.allocator, dq.finished.allocator = heap, heap, heap, heap
	}
	for c in dq.copies {
		delete(c.from, heap)
		delete(c.to, heap)
	}
	for s in dq.done do delete(s, heap)
	for s in dq.notes do delete(s, heap)
	for f in dq.finished {
		delete(f.error, heap)
		delete(f.data, heap)
	}
	clear(&dq.copies)
	clear(&dq.done)
	clear(&dq.notes)
	clear(&dq.finished)
	delete(dq.name, heap)
	delete(dq.label, heap)
	dq.name, dq.label = "", ""
	dq.next, dq.waiting, dq.retry_at = 0, 0, {}
}

// A command whose result may be pending, and the core's request id for its finished event.
@(private = "file")
files_drops_call :: proc(cmd: core.Command) -> (r: core.Result, request_id: u64) {
	if !client.attached {
		reply: core.Reply
		request_id = core.inbox_submit(cmd, {kind = .UI}, &reply)
		core.inbox_drain()
		r = core.result_clone(reply.result, context.temp_allocator)
		core.result_free(reply.result)
		return
	}
	if client.sock != nil do return client_call_wait(cmd, DROPS_CALL_WAIT) // a separate core
	// in process: as client_run, its result's request id kept (client.odin)
	client_facts()
	id := client_next_id()
	client_send_raw(core.window_msg_command(cmd, id))
	for core.window_link_pump() {}
	core.inbox_drain()
	request_id = client.pending[id] or_else 0
	return client_take_result(id), request_id
}

// Per frame (main.odin): the next copy of a Finder drop starts once the last is done; the toast
// when all are. True: draw again (waiting to retry).
files_drops_tick :: proc() -> bool {
	if fh.dir != "" && time.tick_since(fh.at) > FINDER_HOVER_STALE do files_finder_hover_end() // a drag that left unsaid
	if !files_drops_busy() do return fh.dir != ""
	if dq.waiting != 0 {
		for f, i in dq.finished do if f.request_id == dq.waiting {
			files_drops_done(f.ok, f.error, f.data)
			delete(f.error, runtime.heap_allocator())
			delete(f.data, runtime.heap_allocator())
			ordered_remove(&dq.finished, i)
			break
		}
		if dq.waiting != 0 do return false // its finished event ends it (files_drops_on_event)
	}
	if dq.retry_at != {} && time.tick_since(dq.retry_at) < 0 do return true
	for dq.waiting == 0 && dq.next < len(dq.copies) {
		c := dq.copies[dq.next]
		r, rid := files_drops_call(core.Fs_Copy{from = c.from, to = c.to, unique = true})
		if !r.ok && r.error == core.FS_COPY_RUNNING {
			dq.retry_at = time.tick_add(time.tick_now(), DROPS_RETRY) // another copy (a paste): after it
			return true
		}
		dq.retry_at = {}
		dq.next += 1
		name := filepath.base(c.from)
		if !r.ok {
			append(&dq.notes, fmt.aprintf("%s: %s", name, r.error, allocator = runtime.heap_allocator()))
			continue
		}
		if !r.pending {
			append(&dq.done, strings.clone(name, runtime.heap_allocator()))
			continue
		}
		if rid == 0 {
			// no finished will say (the core's request id is not known): counted as copied
			append(&dq.done, strings.clone(name, runtime.heap_allocator()))
			continue
		}
		delete(dq.name, runtime.heap_allocator())
		dq.name = strings.clone(name, runtime.heap_allocator())
		dq.waiting = rid
		return files_drops_tick() // its finished may have come already
	}
	files_drops_toast() // once all are done
	return false
}

// A copy's finished event (every event the window sees: main.odin's hook).
files_drops_on_event :: proc(ev: core.Event) {
	f, ok := ev.(core.Finished_Event)
	if !ok || !files_drops_busy() do return
	if f.request_id == dq.waiting && dq.waiting != 0 {
		files_drops_done(f.result.ok, f.result.error, f.result.data)
		app.redraw = true
		return
	}
	// before its request id came back (a fast copy): kept until it does (a few at most)
	if len(dq.finished) >= 16 do return
	heap := runtime.heap_allocator()
	append(&dq.finished, Drops_Finished{f.request_id, f.result.ok, strings.clone(f.result.error, heap), strings.clone(f.result.data, heap)})
}

@(private = "file")
files_drops_done :: proc(ok: bool, error, data: string) {
	heap := runtime.heap_allocator()
	name := dq.name
	if ok {
		made := core.json_path(data, "path")
		append(&dq.done, strings.clone(made != "" && made[0] == '/' ? filepath.base(made) : name, heap))
		count, _ := strconv.parse_int(core.json_path(data, "skipped.#")) // "<missing>": none
		for i in 0 ..< min(count, 3) {
			append(&dq.notes, fmt.aprintf("%s/%s: %s", name, core.json_path(data, fmt.tprintf("skipped.%d.path", i)), core.json_path(data, fmt.tprintf("skipped.%d.why", i)), allocator = heap))
		}
		if count > 3 do append(&dq.notes, fmt.aprintf("%d more left out of %s", count - 3, name, allocator = heap))
	} else do append(&dq.notes, fmt.aprintf("%s: %s", name, error, allocator = heap))
	dq.waiting = 0
	files_drops_toast()
}

// Once every copy of the drop is done: what was copied where, and what was not.
@(private = "file")
files_drops_toast :: proc() {
	if len(dq.copies) == 0 || files_drops_busy() do return
	what := ""
	switch len(dq.done) {
	case 0:
	case 1: what = dq.done[0]
	case 2, 3: what = strings.join(dq.done[:], ", ", context.temp_allocator)
	case: what = fmt.tprintf("%s, %s and %d more", dq.done[0], dq.done[1], len(dq.done) - 2)
	}
	notes := strings.join(dq.notes[:], "; ", context.temp_allocator)
	switch {
	case len(dq.done) == 0: toast_show(fmt.tprintf("Not copied: %s", notes), err = true)
	case len(dq.notes) > 0: toast_show(fmt.tprintf("Copied %s to %s; not copied: %s", what, dq.label, notes), err = true)
	case:                   toast_show(fmt.tprintf("Copied %s to %s", what, dq.label))
	}
	files_drops_reset()
}

// ---- a Finder drag hovering the tree ----

@(private = "file")
Finder_Hover :: struct {
	dir: string, // owned: the folder a drop now would copy into ("": none)
	at:  time.Tick, // the last report (a drag that left without saying so ends after FINDER_HOVER_STALE)
}

@(private = "file")
fh: Finder_Hover

FINDER_HOVER_STALE :: 1500 * time.Millisecond // AppKit repeats draggingUpdated: while a drag stays over the window

// The window's draggingEntered/Updated (on: true) or draggingExited / the drop (false), at (x, y)
// framebuffer px.
files_finder_hover :: proc(x, y: f32, on: bool) {
	dir := ""
	if on && files_shown() && core.files_root() != "" && over_sidebar(x) {
		over, over_dir, ok := files_drop_over(x, y)
		dir = core.files_finder_drop_dir(core.files_root(), over, over_dir, ok)
	}
	fh.at = time.tick_now()
	if dir == fh.dir do return
	delete(fh.dir)
	fh.dir = strings.clone(dir)
	app.redraw = true
}

files_finder_hover_end :: proc() {files_finder_hover(0, 0, false)}

// Whether the row at path (list: the list itself, for the root) is in a Finder drag's band.
files_finder_band :: proc(path: string, list: bool) -> bool {
	if fh.dir == "" || time.tick_since(fh.at) > FINDER_HOVER_STALE do return false
	root := core.files_root()
	if list do return fh.dir == root
	return fh.dir != root && core.within(path, fh.dir)
}
