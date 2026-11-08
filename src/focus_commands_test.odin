package main

// The commands that replaced the window's direct State writes (design §10.2, M2-A):
// focus_take, focus_release, set_last_harness. Deckhand's own; no outside caller sends them.

import "core:testing"

@(private = "file")
fc_redraws: int

@(test)
focus_commands_replace_direct_writes :: proc(t: ^testing.T) {
	saved := window
	defer window = saved
	window = window_hooks_app()
	window.state_changed = proc() {fc_redraws += 1}
	inbox_drain()
	state = State{}
	fc_redraws = 0
	// focus_take: no caller rules (the job sheet's, the URL field's, an install's sheet)
	r := run_command(Focus_Take{widget = "setup"})
	testing.expect(t, r.ok)
	testing.expect_value(t, state.focus_widget, "setup")
	testing.expect_value(t, fc_redraws, 1)
	r = run_command(Focus_Take{widget = "setup"}) // already there: nothing changes
	testing.expect_value(t, fc_redraws, 1)
	// focus_release: only the widget that has it
	r = run_command(Focus_Release{widget = "job_sheet"})
	testing.expect(t, r.ok)
	testing.expect_value(t, state.focus_widget, "setup")
	testing.expect_value(t, fc_redraws, 1)
	r = run_command(Focus_Release{widget = "setup"})
	testing.expect_value(t, state.focus_widget, "")
	testing.expect_value(t, fc_redraws, 2)
	r = run_command(Focus_Release{widget = ""})
	testing.expect_value(t, fc_redraws, 2)
	// set_last_harness, and the picker's harness_used goes through it
	r = run_command(Set_Last_Harness{harness = .Claude})
	testing.expect_value(t, state.settings.last_harness, Harness.Claude)
	testing.expect_value(t, fc_redraws, 3)
	harness_used(New_Chat{})
	testing.expect_value(t, state.settings.last_harness, Harness.Pi)
	testing.expect_value(t, fc_redraws, 4)
	// Deckhand's own: no socket caller may send them
	for kind in ([]Caller_Kind{.UI, .Script, .Control, .Panel, .App}) {
		testing.expectf(t, !run_command(Focus_Take{widget = "palette"}, {kind = kind}).ok, "%v", kind)
		testing.expectf(t, !run_command(Focus_Release{widget = "setup"}, {kind = kind}).ok, "%v", kind)
		testing.expectf(t, !run_command(Set_Last_Harness{harness = .Claude}, {kind = kind}).ok, "%v", kind)
	}
}

// An install on the setup sheet keeps the keyboard there through focus_take.
@(test)
focus_install_keeps_the_setup_sheet :: proc(t: ^testing.T) {
	inbox_drain()
	state = State{}
	old := harness_run.status
	defer harness_run.status = old
	harness_run.status = .Running
	state.focus_widget = "palette"
	harness_run_keep_sheet()
	testing.expect_value(t, state.focus_widget, "setup")
	setup_ui.step = 0
}
