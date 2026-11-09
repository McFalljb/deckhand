package main

// The quit paths as a table (main.odin's quit_route; docs/plans/background-core.md §10.3 M4-D):
// ⌘Q, the Dock's Quit, logout and Stop All, in process and with a separate core.

import "core:testing"
import "core:time"

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

// A separate core that keeps stopping (client_core_tick): at most RECONNECTS_MAX reconnects in a
// minute, then the window gives up; a minute later it may again.
@(test)
reconnect_limit :: proc(t: ^testing.T) {
	t0 := time.Tick{_nsec = 1_000_000_000}
	since: time.Tick
	n: int
	for i in 0 ..< RECONNECTS_MAX do testing.expectf(t, reconnect_allowed(&since, &n, time.tick_add(t0, time.Duration(i) * time.Second)), "reconnect %d", i + 1)
	testing.expect(t, !reconnect_allowed(&since, &n, time.tick_add(t0, 30 * time.Second)), "one too many within the minute")
	testing.expect(t, reconnect_allowed(&since, &n, time.tick_add(t0, RECONNECTS_PER)), "a minute later")
}
