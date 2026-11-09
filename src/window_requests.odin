package main

// The window's side of window.request (src/core/window_hooks.odin; docs/plans/background-core.md
// §10.3, M3-F2): what the core asks the window to do. It runs on the main thread as it arrives
// (client.odin's client_on_frames) and answers window.reply when the request has an id.
//
// Nothing here is modal: the folder picker is only the window's own (palette.odin, ui_sidebar.odin
// pick a folder, then send the command), so the core never waits on the user.

import "core:fmt"
import "core:strings"
import "core"

window_on_request :: proc(text: string) {
	id, q, err := core.window_request_parse(text)
	if err != "" {
		fmt.eprintln("Deckhand: a window.request the window cannot read:", err)
		if id != "" do window_reply(id, {})
		return
	}
	r := window_request_run(q)
	if id != "" do window_reply(id, r)
}

// What a request asks, done; its reply. A separate core's window also runs the requests its own
// core package makes (core.replica_request: its caches' views, the Changes tab's diff, watched
// folders), as in process.
window_request_run :: proc(q: core.Window_Request) -> (r: core.Window_Reply) {
	switch q.op {
	case .None:
	case .Clipboard_Set:
		clipboard_set(q.text)
	case .Clipboard_Secret:
		if win_os.set_clipboard_secret != nil {
			r.count, r.ok = win_os.set_clipboard_secret(q.text), true
		} else do clipboard_set(q.text) // no concealed pasteboard (tests, test mode's own): plainly, nothing to clear
	case .Clipboard_Clear_If:
		if win_os.clear_clipboard_if != nil do win_os.clear_clipboard_if(q.count)
	case .Open_Url:
		r.ok = win_os.open_url != nil && win_os.open_url(q.text)
	case .Reveal:
		if win_os.reveal != nil do win_os.reveal(q.path)
	case .Appearance:
		if win_os.set_appearance != nil do win_os.set_appearance(q.mode)
	case .Copy_Selection:
		if s := term_view_selection(q.tab_id); s != "" {
			clipboard_set(s)
			r.ok = true
		}
	case .Term_Fit:
		rect := tab_rect(q.tab_id)
		if rect.z > 0 {
			r.cols, r.rows = term_grid_fit(rect.z, rect.w)
			r.cell, r.ok = {font.cell_w, font.cell_h}, true
		}
	case .View_Open:
		tab_view_open(q.tab_id, q.kind, q.line, q.anchor)
	case .View_Goto:
		tab_view_goto(q.tab_id, q.kind, q.line, q.anchor)
	case .View_Drop:
		tab_view_drop(q.tab_id)
	case .View_Moved:
		tab_view_moved(q.tab_id, q.path)
	case .Files_Deleted:
		tab_views_files_deleted(q.path)
	case .Changes_Diff:
		if tab_view_changes_diff(q.tab_id, q.path, q.text, q.message) do app.redraw = true
	case .Changes_Rewind:
		tab_view_changes_rewind(q.tab_id)
	case .Commit_Message_Clear:
		tf_set(&changes_message_field, "") // ui_changes.odin
	case .Watch_Folder:
		watch_folder(q.path) // editor_watch.odin
	case .Watch_Sync:
		watch_sync()
	case .Setup_Sheet:
		setup_sheet_op(q.setup, q.text) // ui_setup.odin
	case .Job_Sheet:
		r.result, r.changed = job_sheet_apply(q.job_sheet, q.caller) // ui_job_sheet.odin
		r.result = core.result_clone(r.result, context.temp_allocator)
	case .Job_Sheet_Saved:
		r.ok = job_sheet_saved(q.path, q.message)
	case .Job_Sheet_Holds_Quit:
		r.ok = job_sheet_holds_quit()
	case .Notify:
		if core.platform.notify != nil do core.platform.notify(q.text, q.message) // a separate core's (its own platform)
	case .Quit:
		client_core_quit(q.text) // the core ends on purpose, or another window took over: no reconnect (client_core.odin)
	case .App_Boxes:
		core.app_event_in(q.tab_id, "tab.boxes", q.text) // a separate core's: drawn as the app sent them (app_tab.odin)
	}
	return
}

@(private = "file")
window_reply :: proc(id: string, r: core.Window_Reply) {
	x := r
	client_send_raw(core.window_msg_reply(strings.clone(id, context.temp_allocator), &x))
}
