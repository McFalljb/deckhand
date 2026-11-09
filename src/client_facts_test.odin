package main

// M3-F review round 1, finding 11: a browser tab's facts the link refused are not taken as
// sent (the next pull sends them again), and a closed tab's go on both sides.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core"
import cw "corewire"

@(test)
client_pull_refused_not_sent :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_end, saved_sent := client.end, client.facts_sent
	defer client.end, client.facts_sent = saved_end, saved_sent
	tr: cw.Mem_Transport
	a, b := cw.mem_open(&tr)
	defer cw.mem_destroy(&tr)
	client.facts_sent = make(map[u64]string)
	defer {
		for _, v in client.facts_sent do delete(v)
		delete(client.facts_sent)
	}
	client.end = a
	cw.mem_close(b)
	client_pull(9)
	testing.expect(t, 9 not_in client.facts_sent, "refused: not taken as sent")
}

@(test)
browser_facts_go_with_the_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved_sent := client.facts_sent
	defer client.facts_sent = saved_sent
	client.facts_sent = make(map[u64]string)
	defer delete(client.facts_sent)
	client.facts_sent[31] = strings.clone("x")
	core.browser_facts_set(31, core.Browser_Facts{zoom = 2})
	core.drop_term(31)
	_, kept := core.browser_facts_get(31)
	testing.expect(t, !kept, "the core's copy went with the tab")
	tab_view_drop(31) // the window's hook (drop_term calls it when the window set its hooks)
	testing.expect(t, 31 not_in client.facts_sent, "and the client's")
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
		delete(client.facts_sent)
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
