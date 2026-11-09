package main

// The window's side of the tab view hooks (window_hooks.odin, design §4: the core keeps the tab
// records, the window their views). A tab record's view is made when the core says the record
// appeared (view_open) and goes when it says the tab closed (view_drop): an editor tab's buffer,
// a Markdown tab's view (and its editor), a Changes tab's read-only diff editor, a browser tab's
// page. The core asks the window about its buffers (unsaved changes) through the queries here.

import "core:strings"
import "core"

// window.view_open: the tab's view, unless it has one, then line or anchor (tab_view_goto).
tab_view_open :: proc(tab_id: u64, kind: core.Tab_Kind, line: int, anchor: string) {
	#partial switch k in kind {
	case core.Editor_Tab:
		if editor_of(tab_id) == nil do editor_new(tab_id, k.path)
	case core.Markdown_Tab:
		if md_view_of(tab_id) == nil do md_view_new(tab_id, k.path)
	case core.Changes_Tab:
		if editor_of(tab_id) != nil do break
		e := new(Editor)
		e.tab_id, e.view, e.readonly, e.goal_col = tab_id, .Changes, true, -1
		e.path = strings.clone(k.root)
		e.eol, e.indent_w = "\n", 4
		tb_init(&e.buf, nil)
		editors[tab_id] = e
	case core.Browser_Tab:
		browser_restore(tab_id, k.url) // browser_nav.odin
	}
	view_goto(tab_id, kind, line, anchor) // the record may not be in its session yet (show_file)
}

// window.view_goto: a Markdown view scrolls to the heading (anchor), else to the source line; an
// editor goes to the line (column 1). 0 and "": stays.
tab_view_goto :: proc(tab_id: u64, line: int, anchor: string) {
	if _, tab, _ := core.find_tab(tab_id); tab != nil do view_goto(tab_id, tab.kind, line, anchor)
}

@(private = "file")
view_goto :: proc(tab_id: u64, kind: core.Tab_Kind, line: int, anchor: string) {
	#partial switch _ in kind {
	case core.Markdown_Tab:
		v := md_view_of(tab_id)
		if v == nil do return
		if anchor != "" {
			delete(v.want)
			v.want = strings.clone(anchor)
		} else if line > 0 {
			v.want_line = line
		}
	case core.Editor_Tab:
		if e := editor_of(tab_id); e != nil && line > 0 do ed_goto(e, line, 1)
	}
}

// window.view_drop: whatever view the tab had (drop_term).
tab_view_drop :: proc(tab_id: u64) {
	editor_drop(tab_id) // an editor tab's buffer (editor_commands.odin)
	md_drop(tab_id) // a Markdown tab's view (markdown_view.odin)
	browser_drop(tab_id) // a browser tab's page (browser.odin)
	client_facts_forget(tab_id) // its facts as last sent to the core (client.odin)
	app_drop(tab_id) // an app tab's process and frames (app_tab.odin)
}

// window.view_moved: the tab's file is now at path (fs_model.odin's editors_renamed).
tab_view_moved :: proc(tab_id: u64, path: string) {
	e := editor_of(tab_id)
	if e == nil do return
	delete(e.path)
	e.path = strings.clone(path)
	e.disk, _ = disk_stamp(path)
	e.missing = false
}

// window.files_deleted: the buffers of files under `under` look at the disk again.
tab_views_files_deleted :: proc(under: string) {
	for _, ed in editors do if core.within(core.fs_real(ed.path), under) do editor_check_disk(ed)
}

// window.changes_diff: the Changes tab's diff editor shows text, or why there is none (message;
// the editor draws a refused editor as the message with the path under it).
tab_view_changes_diff :: proc(tab_id: u64, path, text, message: string) -> bool {
	e := editor_of(tab_id)
	if e == nil do return false
	// copy, then free: path or message may be the editor's own (e.path, e.refused)
	refused, p := strings.clone(message), strings.clone(path)
	delete(e.refused)
	delete(e.path)
	e.refused, e.path = refused, p
	// no message: there is a diff, and text is it (a message keeps the last text under it)
	if message == "" do editor_set_text(e, text) // keeps the scroll position (a refresh of the same file)
	return true
}

// window.changes_rewind: another file was selected: its diff from the top.
tab_view_changes_rewind :: proc(tab_id: u64) {
	e := editor_of(tab_id)
	if e == nil do return
	e.top, e.top_sub, e.frac, e.scroll_x = 0, 0, 0, 0
	e.cursor, e.anchor = 0, 0
}

// window.unsaved_files: buffers with unsaved changes, all ("") or those of files in a folder
// (a worktree about to be removed: wt_within).
tab_views_unsaved :: proc(under: string) -> int {
	if under == "" do return editors_unsaved()
	n := 0
	for _, ed in editors do if ed.path != "" && core.wt_within(core.fs_real(ed.path), under) && editor_dirty(ed) do n += 1
	return n
}

// window.tab_dirty: the tab's buffer has unsaved changes.
tab_view_dirty :: proc(tab_id: u64) -> bool {return editor_dirty(editor_of(tab_id))}
