package main

// The scene runner's platform layer (autotest.odin; `./build.sh test`).

import "core:testing"

// A script's copies and pastes stay in the app: scenes run side by side (and beside other runs on
// the machine), and the system pasteboard is shared, so a copy in one scene could replace what
// another scene's page just put there (browser-act's "written by the page" read session info that
// a menus scene had copied), bump the change count browser scenes watch, and replace the user's own
// clipboard. Only a page (Chromium) still uses the system pasteboard.
@(test)
autotest_clipboard_stays_in_the_app :: proc(t: ^testing.T) {
	saved := platform
	defer {
		platform = saved
		delete(autotest.clipboard)
		delete(autotest.pasteboard)
		autotest.clipboard, autotest.pasteboard = "", ""
	}
	platform = {}
	autotest_platform()
	testing.expect(t, platform.get_clipboard != nil)
	platform.set_clipboard("copied in a scene")
	testing.expect_value(t, clipboard_text(), "copied in a scene")
	testing.expect_value(t, autotest.clipboard, "copied in a scene") // assert_clipboard
	// `paste`: what the next paste reads, not what Deckhand copied
	autotest_paste_set("typed by the script")
	testing.expect_value(t, clipboard_text(), "typed by the script")
	testing.expect_value(t, autotest.clipboard, "copied in a scene")
	// no platform (unit tests): nothing to paste
	platform = {}
	testing.expect_value(t, clipboard_text(), "")
}
