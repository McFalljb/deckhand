package main

// Editor and file commands (rows in command_table.odin; docs/PROTOCOL.md).
// run_command (commands.odin) hands them to editor_apply. Agents do not edit
// buffers: they edit files with their own tools and Deckhand follows the disk
// (editor_file.odin). They open, inspect, save, move the cursor, resolve a
// changed-on-disk conflict, and manage files inside project folders.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core"


@(private = "file")
editor_tab :: proc(id: u64) -> (^core.Open_Session, ^core.Tab, ^Editor) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	if _, is := tab.kind.(core.Editor_Tab); !is do return nil, nil, nil
	return s, tab, editor_of(id)
}

// The window's part of the editor commands: the buffer, its cursor and view (the core checked the
// caller, the file and the tab, made any confirmation, and keeps the tabs' records:
// tabhost_route.odin). tab_id: the tab open_file or diff_file makes (or refreshes).
editor_apply :: proc(cmd: core.Command, caller: core.Caller, tab_id: u64 = 0) -> (r: core.Result, changed: bool) {
	#partial switch c in cmd {
	case core.Open_File:
		// the core resolved the path and the session; its record follows (a preview's place too)
		if tab_id == 0 do return core.fail("no tab for the file"), false
		e := editor_of(tab_id)
		if e == nil do e = editor_new(tab_id, c.path)
		if c.line > 0 do ed_goto(e, c.line, c.col)
		r = {ok = true, created_id = tab_id}
		if e.refused != "" do r.data = fmt.aprintf(`{{"refused":%s}}`, quoted(e.refused))
		return r, true
	case core.Editor_State:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return core.fail("no such editor tab"), false
		if e.view == .File do git_gutter_update(e, force = true)
		return {ok = true, data = strings.clone(editor_state_json(e))}, false
	case core.Save_File:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return core.fail("no such editor tab"), false
		if e.view != .File do return core.fail("a diff view cannot be saved"), false
		// never over a write we have not seen (the watcher may not have told us yet)
		editor_check_disk(e)
		if e.disk_changed do return core.fail("the file changed on disk: reload_file or keep_buffer first"), false
		// a JSON settings file pi reads: only what pi can read (settings_files.odin)
		if kind := core.settings_json_kind(e.path); kind != .None {
			if jerr := core.json_check(tb_text(&e.buf, context.temp_allocator), comments = kind == .Comments); jerr != "" {
				msg := fmt.tprintf("not saved: invalid JSON at %s", jerr)
				delete(e.notice)
				e.notice = strings.clone(msg)
				app.redraw = true
				return core.fail(msg), false
			}
		}
		if err := editor_save(e); err != "" {
			delete(e.notice)
			e.notice = strings.clone(err)
			return core.fail(err), false
		}
		return {ok = true}, true // the core offers a reload for a file pi reads at start
	case core.Goto_Line:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return core.fail("no such editor tab"), false
		if c.line < 1 do return core.fail("line starts at 1"), false
		ed_goto(e, c.line, c.col)
		return {ok = true}, false // the cursor is the editor's, not State
	case core.Reload_File:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return core.fail("no such editor tab"), false
		if e.view != .File || e.refused != "" do return core.fail("nothing to reload"), false
		// unsaved changes: the core asked first (another caller's reload is confirmed)
		if e.disk_changed {
			editor_take_disk(e)
		} else {
			data, st, refused := disk_read(e.path, context.temp_allocator)
			if refused != "" {
				editor_reopen(e) // binary, huge or not a file now: the tab says why
				return {ok = true}, true
			}
			editor_reload_text(e, string(data))
			e.disk_hash = text_hash(data)
			e.disk = st
		}
		if e.refused == "" do e.saved_group = len(e.undo) > 0 ? e.undo[len(e.undo) - 1].id : 0
		return {ok = true}, true
	case core.Keep_Buffer:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return core.fail("no such editor tab"), false
		if !e.disk_changed do return {ok = true}, false
		editor_keep_mine(e)
		return {ok = true}, true
	case core.Diff_File:
		_, _, e := editor_tab(c.tab_id)
		if e == nil || e.view != .File do return core.fail("no such file tab"), false
		if c.against != .Diff_Head && c.against != .Diff_Disk do return core.fail("against: head or disk"), false
		if tab_id == 0 do return core.fail("no tab for the diff"), false
		path := strings.clone(e.path, context.temp_allocator)
		base_text: string
		switch c.against {
		case .Diff_Head:
			if !e.git.loaded || e.git.head_stale do git_load_head(e, sync_now = true) // asked for now: bounded by GIT_TIMEOUT
			if !e.git.in_repo do return core.fail("not in a git repository"), false
			base_text = e.git.head // "" when untracked: all added
		case .Diff_Disk:
			if e.disk_refused != "" do return core.fail(e.disk_refused), false
			if e.disk_changed do base_text = e.disk_text
			else {
				data, _, refused := disk_read(path, context.temp_allocator)
				if refused != "" do return core.fail(refused), false
				base_text = string(data)
			}
		case .File, .Changes:
		}
		name := filepath.base(path)
		text := unified_diff(base_text, tb_text(&e.buf, context.temp_allocator), c.against == .Diff_Head ? fmt.tprintf("HEAD:%s", name) : fmt.tprintf("%s (disk)", name), fmt.tprintf("%s (editor)", name))
		// one diff tab per file and kind (the core's): its view refreshed, else made
		if d := editor_of(tab_id); d != nil {
			editor_set_text(d, text)
			return {ok = true, created_id = tab_id}, true
		}
		d := new(Editor)
		d.tab_id, d.view, d.readonly, d.goal_col = tab_id, c.against, true, -1
		d.path = strings.clone(path)
		d.eol, d.indent_w = "\n", 4
		tb_init(&d.buf, transmute([]u8)strings.clone(text))
		editors[tab_id] = d
		return {ok = true, created_id = tab_id}, true
	case core.Set_Wrap:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return core.fail("no such editor tab"), false
		e.wrap = c.on
		e.scroll_x, e.top_sub = 0, 0
		e.follow = true
		app.redraw = true
		return {ok = true}, false
	case core.Git_Head_Done:
		// only the newest load's result counts; one for a path the tab no
		// longer has (renamed) ends the load and asks again
		if e := editor_of(c.tab_id); e != nil && c.gen == e.git.load_gen {
			if e.path == c.path do git_head_set(e, c.in_repo, c.tracked, c.head)
			else do e.git.loading, e.git.head_stale = false, true
		}
		return {ok = true}, false
	}
	return core.fail("unknown command"), false
}

@(private = "file")
quoted :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	core.json_quote(&b, s)
	return strings.to_string(b)
}

// A new editor for a file tab (State gets the tab; this is the runtime side).
editor_new :: proc(tab_id: u64, path: string) -> ^Editor {
	e := new(Editor)
	e.tab_id = tab_id
	e.wrap = false
	editor_load(e, path)
	editors[tab_id] = e
	if e.refused == "" do git_load_head(e) // the gutter's HEAD text, on a worker
	watch_sync()
	return e
}

// Frees a tab's editor (the tab closed); no-op for other tabs.
editor_drop :: proc(tab_id: u64) {
	e := editor_of(tab_id)
	if e == nil do return
	editor_free(e)
	delete_key(&editors, tab_id)
	watch_sync()
}

// Replaces a read-only view's text (a refreshed diff).
editor_set_text :: proc(e: ^Editor, text: string) {
	tb_destroy(&e.buf)
	tb_init(&e.buf, transmute([]u8)strings.clone(text))
	e.cursor, e.anchor = 0, 0
	e.gen += 1
	app.redraw = true
}

// editor_state's data (temp allocator).
editor_state_json :: proc(e: ^Editor) -> string {
	b := strings.builder_make(context.temp_allocator)
	w :: proc(b: ^strings.Builder, k: string) {
		strings.write_string(b, `,"`)
		strings.write_string(b, k)
		strings.write_string(b, `":`)
	}
	strings.write_string(&b, `{"tab_id":`)
	strings.write_u64(&b, e.tab_id)
	w(&b, "path")
	core.json_quote(&b, e.path)
	w(&b, "view")
	core.json_quote(&b, core.EDITOR_VIEW_NAMES[e.view])
	w(&b, "dirty")
	strings.write_string(&b, editor_dirty(e) ? "true" : "false")
	w(&b, "language")
	core.json_quote(&b, e.sx.lang != nil ? e.sx.lang.name : "plain")
	w(&b, "lines")
	strings.write_int(&b, tb_line_count(&e.buf))
	w(&b, "bytes")
	strings.write_int(&b, tb_len(&e.buf))
	w(&b, "eol")
	core.json_quote(&b, e.eol == "\r\n" ? "crlf" : "lf")
	w(&b, "indent")
	core.json_quote(&b, e.indent_tabs ? "tabs" : fmt.tprintf("spaces:%d", e.indent_w))
	l, col := ed_line_col(e, e.cursor)
	w(&b, "cursor")
	fmt.sbprintf(&b, `{{"line":%d,"col":%d}}`, l, col)
	lo, hi := ed_selection(e)
	w(&b, "selection")
	if lo == hi {
		strings.write_string(&b, "null")
	} else {
		l0, c0 := ed_line_col(e, lo)
		l1, c1 := ed_line_col(e, hi)
		fmt.sbprintf(&b, `{{"from":{{"line":%d,"col":%d}},"to":{{"line":%d,"col":%d}},"bytes":%d,"text":`, l0, c0, l1, c1, hi - lo)
		core.json_quote(&b, tb_copy(&e.buf, lo, min(hi - lo, 64 * 1024), context.temp_allocator))
		strings.write_byte(&b, '}')
	}
	w(&b, "disk")
	core.json_quote(&b, e.missing ? "missing" : (e.disk_changed ? "changed" : "same"))
	w(&b, "wrap")
	strings.write_string(&b, e.wrap ? "true" : "false")
	w(&b, "visible") // the lines on screen at the last draw (1-based)
	fmt.sbprintf(&b, `{{"from":%d,"to":%d}}`, e.top + 1, min(e.top + e.view_rows, tb_line_count(&e.buf)))
	if e.refused != "" {
		w(&b, "refused")
		core.json_quote(&b, e.refused)
	}
	if e.git.in_repo {
		w(&b, "git")
		fmt.sbprintf(&b, `{{"tracked":%v,"added":%d,"modified":%d,"removed":%d}}`, e.git.tracked, e.git.counts[0], e.git.counts[1], e.git.counts[2])
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
