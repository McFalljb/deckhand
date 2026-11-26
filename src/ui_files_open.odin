package main

import "core:strings"
import "core"

// A file row's open (a click, double-click, Enter, Space): open_file naming no session, so the
// core opens it by the file's project (the session on screen when it is that project's, else the
// project's Files session: core/files_session.odin), and any refusal (credentials, too large,
// binary, gone, outside every project) as a toast; a click must never seem to do nothing. The
// row menu's opens show theirs through menu_result.
files_open :: proc(path: string, preview := false) {
	r := ui_run(core.Open_File{path = path, preview = preview})
	if !r.ok && r.error != "needs_confirmation" do toast_show(r.error != "" ? r.error : "The file did not open", true)
}

// The editor's active file is revealed in the Files tree only while the tree shows its folder
// (files_follow_active): never yanked back from a project the user is browsing.
files_reveals :: proc(file, root: string) -> bool {
	return root != "" && strings.has_prefix(file, strings.concatenate({root, "/"}, context.temp_allocator))
}

// The Files tree shows s's own folder (not a project selected since), and s can hold a terminal
// (not a Files session): "Open terminal here" is offered only then.
files_tree_is_session :: proc(s: ^core.Open_Session) -> bool {
	return s != nil && !s.home && s.agent != .Files && s.cwd != "" && core.files_base() == core.fs_real(s.cwd)
}
