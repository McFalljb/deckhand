package main

// The scene runner's platform layer (autotest.odin; `./build.sh test`).

import "core:fmt"
import "core:testing"
import "core"

// A script's copies and pastes stay in the app: scenes run side by side (and beside other runs on
// the machine), and the system pasteboard is shared, so a copy in one scene could replace what
// another scene's page just put there (browser-act's "written by the page" read session info that
// a menus scene had copied), bump the change count browser scenes watch, and replace the user's own
// clipboard. Only a page (Chromium) still uses the system pasteboard.
@(test)
autotest_clipboard_stays_in_the_app :: proc(t: ^testing.T) {
	saved := core.platform
	defer {
		core.platform = saved
		delete(autotest.clipboard)
		delete(autotest.pasteboard)
		autotest.clipboard, autotest.pasteboard = "", ""
	}
	core.platform, win_os = {}, {}
	autotest_platform()
	testing.expect(t, win_os.get_clipboard != nil)
	win_os.set_clipboard("copied in a scene")
	testing.expect_value(t, clipboard_text(), "copied in a scene")
	testing.expect_value(t, autotest.clipboard, "copied in a scene") // assert_clipboard
	// `paste`: what the next paste reads, not what Deckhand copied
	autotest_paste_set("typed by the script")
	testing.expect_value(t, clipboard_text(), "typed by the script")
	testing.expect_value(t, autotest.clipboard, "copied in a scene")
	// no platform (unit tests): nothing to paste
	core.platform, win_os = {}, {}
	testing.expect_value(t, clipboard_text(), "")
}

// $tab, $pitab and $pisession name the session on screen's tabs, as $session names it, also when
// it is another machine's (a hub's window script): they were 0 there, as core.cur() is this Mac's
// sessions only.
@(test)
autotest_vars_another_machines_session :: proc(t: ^testing.T) {
	saved_open, saved_cur := state.open_sessions, state.current_session
	defer state.open_sessions, state.current_session = saved_open, saved_cur
	id := u64(2) << core.MACHINE_ID_SHIFT | 5
	s := core.Open_Session{id = id, machine = 2, pi_session_id = "s5", tabs = make([dynamic]core.Tab, context.temp_allocator)}
	append(&s.tabs, core.Tab{id = id + 1, kind = core.Pi_Tab{}}, core.Tab{id = id + 2, kind = core.Shell_Tab{}})
	s.active_tab = id + 2
	state.open_sessions = make([dynamic]core.Open_Session, context.temp_allocator)
	append(&state.open_sessions, s)
	state.current_session = id
	testing.expect_value(t, expand_vars("$session $tab $pitab $pisession"), fmt.tprintf("%d %d %d s5", id, id + 2, id + 1))
}
