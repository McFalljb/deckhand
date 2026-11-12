package main

// This Mac's header over its own rows while Machines over SSH is on (ui_sidebar.odin's
// machine_header, ui_jobs.odin's jobs_machine_header): its name and "this Mac", in the sidebar
// and in the Jobs tab; nothing of it while the feature is off.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"

@(private = "file")
drawn_now :: proc() -> string {
	cmds := ui_layout(2000, 1400)
	all := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		tx := c.renderData.text
		strings.write_string(&all, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&all, '\n')
	}
	return strings.to_string(all)
}

@(test)
machine_header_this_mac :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	saved_layout, saved_on, saved_home := state.layout, state.settings.remote_machines, state.settings.home_dir
	state.settings.home_dir = strings.clone("/tmp/pd-mhead-notes")
	defer {
		clear(&state.jobs)
		state.layout, state.settings.remote_machines, state.settings.home_dir = saved_layout, saved_on, saved_home
	}
	name := core.machine_here_name()
	testing.expect(t, name != "", "a name")
	state.layout.left_open, state.layout.left_width = true, 900

	// the sidebar: its header over this Mac's sections, with no machine added yet
	state.layout.left_tab = .Sessions
	state.settings.remote_machines = true
	got := drawn_now()
	testing.expectf(t, strings.contains(got, fmt.tprintf("%s\nthis Mac\n", name)), "the sidebar's header: %q", got)
	state.settings.remote_machines = false
	testing.expect(t, !strings.contains(drawn_now(), "this Mac"), "off: no header")

	// the Jobs tab: On <name>, this Mac, its count; none while it has no jobs
	state.layout.left_tab = .Jobs
	state.settings.remote_machines = true
	testing.expect(t, !strings.contains(drawn_now(), "this Mac"), "no jobs: no header")
	append(&state.jobs, core.Job_Row{id = "h1", name = "Nightly", schedule = "manual", path = "/tmp/pd-mhead-notes/jobs/h.md"})
	got = drawn_now()
	testing.expectf(t, strings.contains(got, fmt.tprintf("On %s\nthis Mac\n1\n", name)), "the Jobs tab's header: %q", got)
	state.settings.remote_machines = false
	got = drawn_now()
	testing.expect(t, !strings.contains(got, "this Mac") && strings.contains(got, "Nightly"), "off: the jobs, no header")
}
