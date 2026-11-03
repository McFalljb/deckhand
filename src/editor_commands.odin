package main

// Editor and file commands (rows in command_table.odin; docs/PROTOCOL.md).
// run_command (commands.odin) hands them to editor_apply. Agents do not edit
// buffers: they edit files with their own tools and pi-desk follows the disk
// (editor_file.odin). They open, inspect, save, move the cursor, resolve a
// changed-on-disk conflict, and manage files inside project folders.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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

EDITOR_VIEW_NAMES := [Editor_View]string {
	.File      = "file",
	.Diff_Disk = "disk",
	.Diff_Head = "head",
	.Changes   = "changes",
}

@(private = "file")
editor_tab :: proc(id: u64) -> (^Open_Session, ^Tab, ^Editor) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	if _, is := tab.kind.(Editor_Tab); !is do return nil, nil, nil
	return s, tab, editor_of(id)
}

// The tab title for a file view.
@(private = "file")
title_for :: proc(path: string, view: Editor_View) -> string {
	base := filepath.base(path)
	switch view {
	case .File:      return strings.clone(base)
	case .Diff_Head: return fmt.aprintf("%s ↔ HEAD", base)
	case .Diff_Disk: return fmt.aprintf("%s ↔ disk", base)
	case .Changes:   return strings.clone("Changes")
	}
	return strings.clone(base)
}

editor_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Open_File:
		// default session: the caller's own (a tab-bound caller), else the one on screen;
		// Home has only its pi tab, so Home's control opens files in the one on screen
		s := c.session != 0 ? find_session(c.session) : caller_session(caller)
		if s != nil && s.home && c.session == 0 do s = cur()
		if s == nil do return fail("no open session to open the file in"), false
		if s.home do return fail("Home has only its pi tab"), false
		if c.path == "" do return fail("path is empty"), false
		p := c.path
		if strings.has_prefix(p, "~/") do p = strings.concatenate({os.get_env("HOME", context.temp_allocator), p[1:]}, context.temp_allocator)
		if !filepath.is_abs(p) {
			// relative: from the named session's folder, else the caller's
			base := c.session != 0 ? s.cwd : fs_base_for(caller)
			if base == "" do base = s.cwd
			p, _ = filepath.join({base, p}, context.temp_allocator)
		}
		p, _ = filepath.clean(p, context.temp_allocator)
		if settings_credential(p) do return fail(CREDENTIAL_REFUSED), false // sign-ins and .env files: never shown (settings_files.odin)
		switch path_kind(p) {
		case .Missing: return fail("no such file"), false
		case .Dir:     return fail("that is a folder"), false
		case .File, .Other: // other kinds open as a tab that says why
		}
		rp := fs_real(p)
		for &tab in s.tabs {
			et, is := &tab.kind.(Editor_Tab)
			if !is || et.view != .File || fs_real(et.path) != rp do continue
			s.active_tab = tab.id
			if !c.preview do et.preview = false // opened for good (double-click, Enter)
			focus_session(s.id)
			if e := editor_of(tab.id); e != nil && c.line > 0 do ed_goto(e, c.line, c.col)
			return {ok = true, created_id = tab.id}, true
		}
		tab := Tab{id = new_id(), kind = Editor_Tab{path = strings.clone(p), preview = c.preview}, title = title_for(p, .File), status = .Running}
		e := editor_new(tab.id, p)
		if c.line > 0 do ed_goto(e, c.line, c.col)
		// a preview takes the place of the session's preview tab, unless that one has unsaved changes
		at := -1
		if c.preview {
			for t, i in s.tabs {
				et, is := t.kind.(Editor_Tab)
				if is && et.preview && !editor_dirty(editor_of(t.id)) do at = i
			}
		}
		if at >= 0 {
			old := &s.tabs[at]
			// as close_tab cleans up a tab
			drop_term(old.id)
			forget_confirmations_for(old.id)
			socket_forget_tab(old.id)
			tab_clear_panels(old)
			delete(old.panels)
			if et, is := old.kind.(Editor_Tab); is do delete(et.path)
			delete(old.title)
			old^ = tab
		} else {
			append(&s.tabs, tab)
		}
		s.active_tab = tab.id
		focus_session(s.id)
		r = {ok = true, created_id = tab.id}
		if e.refused != "" do r.data = fmt.aprintf(`{{"refused":%s}}`, quoted(e.refused))
		return r, true
	case Keep_Tab:
		_, tab, _ := editor_tab(c.tab_id)
		if tab == nil do return fail("no such editor tab"), false
		et := &tab.kind.(Editor_Tab)
		if !et.preview do return {ok = true}, false
		et.preview = false
		return {ok = true}, true
	case Editor_State:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return fail("no such editor tab"), false
		if e.view == .File do git_gutter_update(e, force = true)
		return {ok = true, data = strings.clone(editor_state_json(e))}, false
	case Save_File:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return fail("no such editor tab"), false
		if e.view != .File do return fail("a diff view cannot be saved"), false
		// never over a write we have not seen (the watcher may not have told us yet)
		editor_check_disk(e)
		if e.disk_changed do return fail("the file changed on disk: reload_file or keep_buffer first"), false
		// a JSON settings file pi reads: only what pi can read (settings_files.odin)
		if kind := settings_json_kind(e.path); kind != .None {
			if jerr := json_check(tb_text(&e.buf, context.temp_allocator), comments = kind == .Comments); jerr != "" {
				msg := fmt.tprintf("not saved: invalid JSON at %s", jerr)
				delete(e.notice)
				e.notice = strings.clone(msg)
				app.redraw = true
				return fail(msg), false
			}
		}
		if err := editor_save(e); err != "" {
			delete(e.notice)
			e.notice = strings.clone(err)
			return fail(err), false
		}
		settings_after_save(e.tab_id, e.path) // pi reads it at start: offer a reload
		return {ok = true}, true
	case Goto_Line:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return fail("no such editor tab"), false
		if c.line < 1 do return fail("line starts at 1"), false
		ed_goto(e, c.line, c.col)
		return {ok = true}, false // the cursor is the editor's, not State
	case Reload_File:
		s, tab, e := editor_tab(c.tab_id)
		if e == nil do return fail("no such editor tab"), false
		if e.view != .File || e.refused != "" do return fail("nothing to reload"), false
		if editor_dirty(e) && caller.kind != .UI {
			gr, go_on, ch := confirm_gate(cmd, .Tab_Close, caller, c.confirm, fmt.tprintf("discard the unsaved changes to %q in %s?", tab.title, session_where(s)))
			if !go_on do return gr, ch
		}
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
	case Keep_Buffer:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return fail("no such editor tab"), false
		if !e.disk_changed do return {ok = true}, false
		editor_keep_mine(e)
		return {ok = true}, true
	case Diff_File:
		s, tab, e := editor_tab(c.tab_id)
		if e == nil || e.view != .File do return fail("no such file tab"), false
		if c.against == .File do return fail("against: head or disk"), false
		path := strings.clone(e.path, context.temp_allocator)
		base_text: string
		switch c.against {
		case .Diff_Head:
			if !e.git.loaded || e.git.head_stale do git_load_head(e, sync_now = true) // asked for now: bounded by GIT_TIMEOUT
			if !e.git.in_repo do return fail("not in a git repository"), false
			base_text = e.git.head // "" when untracked: all added
		case .Diff_Disk:
			if e.disk_refused != "" do return fail(e.disk_refused), false
			if e.disk_changed do base_text = e.disk_text
			else {
				data, _, refused := disk_read(path, context.temp_allocator)
				if refused != "" do return fail(refused), false
				base_text = string(data)
			}
		case .File, .Changes:
		}
		name := filepath.base(path)
		text := unified_diff(base_text, tb_text(&e.buf, context.temp_allocator), c.against == .Diff_Head ? fmt.tprintf("HEAD:%s", name) : fmt.tprintf("%s (disk)", name), fmt.tprintf("%s (editor)", name))
		_ = tab
		// one diff tab per file and kind: refreshed when asked again
		for t in s.tabs {
			et, is := t.kind.(Editor_Tab)
			if !is || et.view != c.against || et.path != path do continue
			if d := editor_of(t.id); d != nil do editor_set_text(d, text)
			s.active_tab = t.id
			return {ok = true, created_id = t.id}, true
		}
		nt := Tab{id = new_id(), kind = Editor_Tab{path = strings.clone(path), view = c.against}, title = title_for(path, c.against), status = .Running}
		d := new(Editor)
		d.tab_id, d.view, d.readonly, d.goal_col = nt.id, c.against, true, -1
		d.path = strings.clone(path)
		d.eol, d.indent_w = "\n", 4
		tb_init(&d.buf, transmute([]u8)strings.clone(text))
		editors[nt.id] = d
		append(&s.tabs, nt)
		s.active_tab = nt.id
		return {ok = true, created_id = nt.id}, true
	case Set_Wrap:
		_, _, e := editor_tab(c.tab_id)
		if e == nil do return fail("no such editor tab"), false
		e.wrap = c.on
		e.scroll_x, e.top_sub = 0, 0
		e.follow = true
		app.redraw = true
		return {ok = true}, false
	case List_Dir:
		data, err := fs_list_json(c.path, caller, c.ignored)
		if err != "" do return fail(err), false
		return {ok = true, data = strings.clone(data)}, false
	// File commands: the path is resolved (for this caller) before any
	// confirmation, and the confirmation parks and shows that absolute path,
	// so confirming later acts on the same file whatever is on screen.
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
	case Git_Head_Done:
		// only the newest load's result counts; one for a path the tab no
		// longer has (renamed) ends the load and asks again
		if e := editor_of(c.tab_id); e != nil && c.gen == e.git.load_gen {
			if e.path == c.path do git_head_set(e, c.in_repo, c.tracked, c.head)
			else do e.git.loading, e.git.head_stale = false, true
		}
		return {ok = true}, false
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

// A path as the user reads it: ~ for the home folder.
fs_display :: proc(p: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(p, home) do return strings.concatenate({"~", p[len(home):]}, context.temp_allocator)
	return p
}

@(private = "file")
quoted :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	json_quote(&b, s)
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

// A file or folder moved: open tabs follow it (path and title).
editors_renamed :: proc(from, to: string) {
	for &s in state.open_sessions do for &tab in s.tabs {
		path: ^string
		view := Editor_View.File
		#partial switch &k in tab.kind {
		case Editor_Tab:
			path, view = &k.path, k.view
		case Markdown_Tab:
			path = &k.path
		case:
			continue
		}
		rp := fs_real(path^)
		if rp != from && !strings.has_prefix(rp, strings.concatenate({from, "/"}, context.temp_allocator)) do continue
		np := strings.concatenate({to, rp[len(from):]})
		delete(path^)
		path^ = np
		delete(tab.title)
		tab.title = title_for(np, view)
		if e := editor_of(tab.id); e != nil {
			delete(e.path)
			e.path = strings.clone(np)
			e.disk, _ = disk_stamp(np)
			e.missing = false
		}
	}
	watch_sync()
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
	json_quote(&b, e.path)
	w(&b, "view")
	json_quote(&b, EDITOR_VIEW_NAMES[e.view])
	w(&b, "dirty")
	strings.write_string(&b, editor_dirty(e) ? "true" : "false")
	w(&b, "language")
	json_quote(&b, e.sx.lang != nil ? e.sx.lang.name : "plain")
	w(&b, "lines")
	strings.write_int(&b, tb_line_count(&e.buf))
	w(&b, "bytes")
	strings.write_int(&b, tb_len(&e.buf))
	w(&b, "eol")
	json_quote(&b, e.eol == "\r\n" ? "crlf" : "lf")
	w(&b, "indent")
	json_quote(&b, e.indent_tabs ? "tabs" : fmt.tprintf("spaces:%d", e.indent_w))
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
		json_quote(&b, tb_copy(&e.buf, lo, min(hi - lo, 64 * 1024), context.temp_allocator))
		strings.write_byte(&b, '}')
	}
	w(&b, "disk")
	json_quote(&b, e.missing ? "missing" : (e.disk_changed ? "changed" : "same"))
	w(&b, "wrap")
	strings.write_string(&b, e.wrap ? "true" : "false")
	w(&b, "visible") // the lines on screen at the last draw (1-based)
	fmt.sbprintf(&b, `{{"from":%d,"to":%d}}`, e.top + 1, min(e.top + e.view_rows, tb_line_count(&e.buf)))
	if e.refused != "" {
		w(&b, "refused")
		json_quote(&b, e.refused)
	}
	if e.git.in_repo {
		w(&b, "git")
		fmt.sbprintf(&b, `{{"tracked":%v,"added":%d,"modified":%d,"removed":%d}}`, e.git.tracked, e.git.counts[0], e.git.counts[1], e.git.counts[2])
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}
