package main

// A first-time user's walkthrough of 0.3.0: a machine that refuses or is not supported offers Try
// again (its row's button, the palette's Connect to a machine), and only when clicked; Add a
// machine… with Machines over SSH off opens Settings at Machines and says why, without turning it on.

import "base:runtime"
import "core:testing"
import "core"

@(test)
walkthrough_machine_try_again_and_add_off :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_state := state^
	defer {
		state^ = saved_state
		toast_clear()
	}
	state^ = core.State{}
	state.layout.left_open = true
	state.settings.remote_machines = true
	views := make([]core.Machine_View, 3)
	defer delete(views)
	views[0] = {no = 2, name = "nuc", target = "me@nuc", status = .Refused}
	views[1] = {no = 3, name = "box", target = "box", status = .Unsupported, error = "FreeBSD amd64"}
	views[2] = {no = 4, name = "lab", target = "lab", status = .Online}
	state.machines = views
	testing.expect(t, machine_connectable(views[0]) && machine_connectable(views[1]), "refused and unsupported: listed")
	testing.expect(t, !machine_connectable(views[2]), "online: not listed")
	testing.expect_value(t, machine_action_tip(views[0]), "Try to connect again, once you have fixed it on that machine")
	testing.expect(t, action_ok("machine_connect"), "Connect to a machine is offered")
	palette.machine_pick = .Connect
	defer palette.machine_pick = {}
	items := machine_palette_results("")
	testing.expect_value(t, len(items), 2)
	if len(items) == 2 do testing.expect_value(t, items[0].title, "Try again nuc")

	// Machines over SSH off: Add a machine… is offered, and opens Settings at its row with why
	state.settings.remote_machines = false
	testing.expect(t, action_ok("machine_add"), "not greyed")
	toast_clear()
	action_run("machine_add")
	core.inbox_drain()
	testing.expect_value(t, toast.text, "Turn on Machines over SSH to add a machine")
	testing.expect(t, settings_page_shown() && spage.section == .Machines, "the Settings page at Machines (its switch)")
	testing.expect(t, !state.settings.remote_machines, "never turned on for the user")
	settings_page_off()
}
