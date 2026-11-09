package main

// M3-F review round 1, finding 11: a tab's facts the link refused are not taken as sent (the
// next push sends them again), and a closed tab's go on both sides.

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core"
import cw "corewire"

@(test)
client_facts_refused_not_sent :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_end := client.end
	defer client.end = saved_end
	e := new(Editor)
	e.tab_id, e.view = 9, .Changes
	editors[9] = e
	defer {
		delete_key(&editors, 9)
		free(e)
		client_facts_forget(9)
	}
	tr: cw.Mem_Transport
	a, b := cw.mem_open(&tr)
	defer cw.mem_destroy(&tr)
	client.end = a
	cw.mem_close(b)
	client_facts()
	testing.expect(t, 9 not_in client.tab_facts_sent, "refused: not taken as sent")
}

@(test)
tab_facts_go_with_the_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	e := new(Editor)
	e.tab_id, e.view = 31, .Changes
	editors[31] = e
	client_test_facts() // over the unit tests' host link (tabhost_link_test.odin), on this thread
	testing.expect(t, 31 in client.tab_facts_sent, "sent")
	testing.expect(t, core.window_tab_facts(31) != nil, "the core keeps them")
	delete_key(&editors, 31)
	free(e)
	core.drop_term(31)
	testing.expect(t, core.window_tab_facts(31) == nil, "the core's copy went with the tab")
	testing.expect(t, 31 not_in client.tab_facts_sent, "and the client's (tab_view_drop)")
}

// Finding 3: with no frames (the window hidden), the core's drains still apply deltas to the
// replica; what they replace is freed at a drain outside a frame or event, not kept forever.
@(test)
client_deferred_bounded_while_hidden :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tl_host_off() // the unit tests' tab host link (tabhost_link_test.odin): one window per core
	defer tl_host_on()
	saved_state, saved_client := state, client
	core.state = core.State{}
	client = {}
	client_attach()
	if !testing.expect(t, client.attached) do return
	defer {
		core.core_detach_window()
		core.replica_free(&client.replica, deferred_allocator(&client.deferred))
		deferred_release(&client.deferred)
		deferred_release(&client.deferred)
		for r in client.deferred.retired do delete(r)
		delete(client.results)
		delete(client.tab_facts_sent)
		client, state = saved_client, saved_state
		core.state = core.State{}
	}
	most := 0
	for i in 0 ..< 3000 {
		core.inbox_submit(core.Set_Files_Filter{text = fmt.aprintf("filter %d", i)}, {kind = .UI})
		core.inbox_drain()
		most = max(most, deferred_count(&client.deferred))
	}
	testing.expectf(t, most <= 2 * DEFERRED_MAX + 256, "retired blocks: %d at most", most)
}

// Round 2, finding 4: a frame inside something else busy (a modal loop under an event or a menu
// action) does not free what the replica retired: only a frame on its own (busy <= 1) does.
@(test)
client_after_tick_waits_while_nested :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := client
	defer client = saved
	client = {}
	deferred_init(&client.deferred)
	defer for r in client.deferred.retired do delete(r)
	client.attached = true // no link: the flush does nothing
	a := deferred_allocator(&client.deferred)
	for _ in 0 ..< 3 do free(new(int, a), a)
	client.busy = 2
	client_after_tick()
	client_after_tick()
	testing.expect_value(t, deferred_count(&client.deferred), 3)
	client.busy = 1
	client_after_tick()
	client_after_tick()
	testing.expect_value(t, deferred_count(&client.deferred), 0)
}
