package main

import "core"

// A file row's open (a click, double-click, Enter, Space): open_file in the session on screen,
// and any refusal (no session on screen, credentials, too large, binary, gone) as a toast; a
// click must never seem to do nothing. The row menu's opens show theirs through menu_result.
files_open :: proc(path: string, preview := false) {
	r := ui_run(core.Open_File{path = path, session = files_open_session(), preview = preview})
	if !r.ok && r.error != "needs_confirmation" do toast_show(r.error != "" ? r.error : "The file did not open", true)
}

// The session on screen (Home's is none), as ui_files.odin's files_session.
@(private = "file")
files_open_session :: proc() -> u64 {
	if cs := core.cur(); cs != nil && !cs.home do return cs.id
	return 0
}
