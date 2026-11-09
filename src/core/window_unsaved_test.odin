package core

// With no window to ask, unsaved files are not known (design §10.2, an M3 must-do): a quit
// that keeps sessions asks first, and the prompt says why, instead of taking "none".

import "core:strings"
import "core:testing"

@(test)
window_unsaved_unknown_asks :: proc(t: ^testing.T) {
	saved_window, saved_platform, saved_on := window, platform, hc.on
	defer {
		window, platform, hc.on = saved_window, saved_platform, saved_on
		for &p in state.pending_confirmations {
			delete(p.token)
			delete(p.summary)
			command_free(p.command, context.allocator)
		}
		delete(state.pending_confirmations)
		state = State{}
	}
	state = State{}
	@(static) quits: int
	quits = 0
	platform = {quit = proc() {quits += 1}}
	window = {}
	n, known := window_unsaved_files()
	testing.expect(t, n == 0 && !known, "no window: not known")
	testing.expect(t, unsaved_files_note(0, false) != "")
	testing.expect_value(t, unsaved_files_note(0, true), "")

	// the session holder keeps sessions: nothing would stop, so only unsaved files could ask
	hc.on = true
	state.settings.keep_sessions = true
	r := run_command(Quit{}, {kind = .UI})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expectf(t, strings.contains(r.confirm_summary, "No window can say"), "%q", r.confirm_summary)
	testing.expect_value(t, quits, 0)
	// a window that says none: the quit goes on
	window.unsaved_files = proc(under: string) -> int {return 0}
	r = run_command(Quit{}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, quits, 1)

	// M3-F review round 1, finding 6: no sessions to stop and no holder: unknown still asks
	window = {}
	hc.on = false
	state.settings.keep_sessions = false
	r = run_command(Quit{}, {kind = .UI})
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect_value(t, quits, 1)
}

// Finding 6: an editor tab's unsaved changes with no window to ask are not known: closing it
// asks, and get_state does not say dirty:false.
@(test)
window_tab_dirty_unknown :: proc(t: ^testing.T) {
	saved_window := window
	defer window = saved_window
	window = {}
	tab := Tab{id = 77, kind = Editor_Tab{path = "/x/a.txt"}, status = .Running}
	dirty, known := window_tab_dirty(tab.id)
	testing.expect(t, !dirty && !known, "no window: not known")
	testing.expect(t, close_needs_confirm(tab), "unknown: closing asks")
	window.tab_dirty = proc(id: u64) -> bool {return false}
	dirty, known = window_tab_dirty(tab.id)
	testing.expect(t, !dirty && known, "a window that says clean")
	testing.expect(t, !close_needs_confirm(tab), "clean: closing goes on")
}
