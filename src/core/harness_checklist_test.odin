package core

// The cached checklist (harness_checklist_refresh) keeps its strings on the heap, whatever
// allocator the caller has: a refresh from one test's (or one request's) allocator must not leave
// strings that a later refresh frees with another (a crash on Linux: the core's unit tests in
// one process, after Install agy's command refreshed the checklist from its test).

import "base:runtime"
import "core:mem"
import "core:testing"

@(test)
harness_checklist_strings_on_the_heap :: proc(t: ^testing.T) {
	saved := harness_facts_probe
	defer {
		harness_facts_probe = saved
		harness_checklist_refresh(bump = false)
	}
	harness_facts_probe = proc() -> Harness_Facts {
		f: Harness_Facts
		f.installed[.Pi] = true
		f.bin[.Pi] = "/u/.pi/agent/bin/pi"
		f.version[.Pi] = "99.0.0"
		return f
	}
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, runtime.heap_allocator())
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		harness_checklist_refresh(bump = false)
	}
	testing.expectf(t, len(track.allocation_map) == 0, "the checklist kept %d allocations of the caller's allocator", len(track.allocation_map))
	found := false
	for it in harness_items do if it.version == "99.0.0" do found = true
	testing.expect(t, found, "pi's version kept")
}
