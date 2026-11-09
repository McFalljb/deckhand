package main

// The commands that replaced the window's direct State writes (design §10.2, M2-A):
// focus_take, focus_release, set_last_harness. Deckhand's own; no outside caller sends them.

import "base:runtime"
import "core:mem"
import "core:testing"
import "core"

@(private = "file")
fc_redraws: int

@(test)
focus_commands_replace_direct_writes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := core.window
	defer core.window = saved
	core.window = window_hooks_app()
	core.window.state_changed = proc() {fc_redraws += 1}
	core.inbox_drain()
	state^ = core.State{}
	fc_redraws = 0
	// focus_take: no caller rules (the job sheet's, the URL field's, an install's sheet)
	r := core.run_command(core.Focus_Take{widget = "setup"})
	testing.expect(t, r.ok)
	testing.expect_value(t, state.focus_widget, "setup")
	testing.expect_value(t, fc_redraws, 1)
	r = core.run_command(core.Focus_Take{widget = "setup"}) // already there: nothing changes
	testing.expect_value(t, fc_redraws, 1)
	// focus_release: only the widget that has it
	r = core.run_command(core.Focus_Release{widget = "job_sheet"})
	testing.expect(t, r.ok)
	testing.expect_value(t, state.focus_widget, "setup")
	testing.expect_value(t, fc_redraws, 1)
	r = core.run_command(core.Focus_Release{widget = "setup"})
	testing.expect_value(t, state.focus_widget, "")
	testing.expect_value(t, fc_redraws, 2)
	r = core.run_command(core.Focus_Release{widget = ""})
	testing.expect_value(t, fc_redraws, 2)
	// set_last_harness, and the picker's harness_used goes through it
	r = core.run_command(core.Set_Last_Harness{harness = .Claude})
	testing.expect_value(t, state.settings.last_harness, core.Harness.Claude)
	testing.expect_value(t, fc_redraws, 3)
	core.harness_used(core.New_Chat{})
	testing.expect_value(t, state.settings.last_harness, core.Harness.Pi)
	testing.expect_value(t, fc_redraws, 4)
	// Deckhand's own: no socket caller may send them
	for kind in ([]core.Caller_Kind{.UI, .Script, .Control, .Panel, .App}) {
		testing.expectf(t, !core.run_command(core.Focus_Take{widget = "palette"}, {kind = kind}).ok, "%v", kind)
		testing.expectf(t, !core.run_command(core.Focus_Release{widget = "setup"}, {kind = kind}).ok, "%v", kind)
		testing.expectf(t, !core.run_command(core.Set_Last_Harness{harness = .Claude}, {kind = kind}).ok, "%v", kind)
	}
}

// An install on the setup sheet keeps the keyboard there through focus_take.
@(test)
focus_install_keeps_the_setup_sheet :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	old := core.harness_run.status
	defer core.harness_run.status = old
	core.harness_run.status = .Running
	state.focus_widget = "palette"
	harness_run_keep_sheet()
	testing.expect_value(t, state.focus_widget, "setup")
	setup_ui.step = 0
}

// focus_take frees the string it made when the keyboard moves on or is released, and never one it
// did not make (a literal, another writer's).
@(test)
focus_take_frees_only_its_own :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	state.focus_widget = "palette" // a literal: left alone
	core.run_command(core.Focus_Take{widget = "setup"})
	core.run_command(core.Focus_Take{widget = "browser_url"})
	testing.expect_value(t, state.focus_widget, "browser_url")
	core.run_command(core.Focus_Release{widget = "browser_url"})
	testing.expect_value(t, state.focus_widget, "")
	n := 0
	for _, e in track.allocation_map do if e.size == len("setup") || e.size == len("browser_url") do n += 1
	testing.expectf(t, n == 0, "focus_take's strings freed: %d left", n)
}
