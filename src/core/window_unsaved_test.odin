package core

// With no window to ask, unsaved files are not known (design §10.2, an M3 must-do): a quit
// that keeps sessions asks first, and the prompt says why, instead of taking "none".

import "core:strings"
import "core:testing"

@(test)
window_unsaved_unknown_asks :: proc(t: ^testing.T) {
	saved_platform, saved_on := platform, hc.on
	defer {
		core_detach_window()
		platform, hc.on = saved_platform, saved_on
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
	fw_attach()
	fw_facts({})
	r = run_command(Quit{}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, quits, 1)

	// M3-F review round 1, finding 6: no sessions to stop and no holder: unknown still asks
	core_detach_window()
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
	defer core_detach_window()
	tab := Tab{id = 77, kind = Editor_Tab{path = "/x/a.txt"}, status = .Running}
	dirty, known := window_tab_dirty(tab.id)
	testing.expect(t, !dirty && !known, "no window: not known")
	testing.expect(t, close_needs_confirm(tab), "unknown: closing asks")
	fw_attach()
	fw_facts({}) // a window that reports no dirty buffer
	dirty, known = window_tab_dirty(tab.id)
	testing.expect(t, !dirty && known, "a window that says clean")
	testing.expect(t, !close_needs_confirm(tab), "clean: closing goes on")
}
