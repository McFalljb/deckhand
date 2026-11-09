package main

// The quit paths as a table (main.odin's quit_route; docs/plans/background-core.md §10.3 M4-D):
// ⌘Q, the Dock's Quit, logout and Stop All, in process and with a separate core.

import "core:testing"

@(test)
quit_paths_table :: proc(t: ^testing.T) {
	Row :: struct {
		from:     Quit_From,
		separate: bool,
		quitting: bool,
		want:     Quit_Do,
	}
	rows := []Row {
		{.Menu, false, false, .Ask_Core}, // in process: ⌘Q asks the core (it confirms, then the holder's handover)
		{.Dock, false, false, .Ask_Core}, // the Dock's Quit is ⌘Q (it used to skip the handover)
		{.Logout, false, false, .Terminate}, // logout: cleanup saves, today's restore follows
		{.Stop_All, false, false, .Stop_All},
		{.Menu, true, false, .Close_Window}, // a separate core: the window goes, the sessions run on
		{.Dock, true, false, .Close_Window},
		{.Logout, true, false, .Terminate}, // the core saves and exits on its own SIGTERM
		{.Stop_All, true, false, .Stop_All}, // the core stops everything, then tells the window to quit
		// once a quit went through, macOS's terminate after the window closed goes ahead
		{.Dock, false, true, .Terminate},
		{.Dock, true, true, .Terminate},
		{.Logout, true, true, .Terminate},
	}
	for r in rows {
		testing.expectf(t, quit_route(r.from, r.separate, r.quitting) == r.want, "%v separate=%v quitting=%v: %v, want %v", r.from, r.separate, r.quitting, quit_route(r.from, r.separate, r.quitting), r.want)
	}
}
