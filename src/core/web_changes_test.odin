package core

// Review (P1): a browser's Changes tab diff never goes to a hub. A hub (another machine viewing
// this one) that takes the link while a diff is read gets nothing of it, the result is dropped;
// nothing the core asks of a Changes tab's diff is sent to a hub at all.

import "base:runtime"
import "core:strings"
import "core:testing"
import cw "../corewire"

@(private = "file")
wc_end: cw.Mem_End

@(private = "file")
wc_to_hub :: proc() -> (all: string) {
	b := strings.builder_make(context.temp_allocator)
	for {
		fr, err := cw.mem_recv(wc_end, context.temp_allocator)
		if err != .None do break
		strings.write_string(&b, string(fr.payload))
	}
	return strings.to_lower(strings.to_string(b), context.temp_allocator) // op names in any case
}

@(test)
web_changes_diff_never_to_a_hub :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	// a Changes tab whose diff is read for a browser (link 0 here: the test's browser is gone)
	v := new(Changes_View)
	v^ = {tab_id = 990_001, root = strings.clone("/nowhere/repo"), sel_path = strings.clone("a.txt"), diff_gen = 7, diff_loading = true, diff_link = 12345, shown = CHANGES_LINES_STEP}
	changes_views[v.tab_id] = v
	defer changes_drop(v.tab_id)
	ok: bool
	wc_end, ok = core_attach_window(proc() {})
	if !testing.expect(t, ok, "attached") do return
	defer core_detach_window()
	window_link_for_test().hub = true
	_ = wc_to_hub()
	// the browser's result arrives with the hub attached: dropped
	changes_diff_done({tab_id = v.tab_id, gen = 7, text = "@@ -1 +1 @@\n-x\n+SECRET-DIFF\n"})
	testing.expect(t, !v.diff_loading && v.diff == "", v.diff)
	sent := wc_to_hub()
	testing.expect(t, !strings.contains(sent, "secret-diff") && !strings.contains(sent, "changes_diff"), sent)
	// one read while the hub is attached: not sent either, nor a message or a rewind
	v.diff_gen, v.diff_loading, v.diff_link = 8, true, 0
	changes_diff_done({tab_id = v.tab_id, gen = 8, text = "@@ -1 +1 @@\n-x\n+SECRET-TWO\n"})
	window_changes_diff(v.tab_id, "/nowhere/repo/a.txt", "+SECRET-THREE\n", "msg")
	window_changes_rewind(v.tab_id)
	sent = wc_to_hub()
	testing.expect(t, !strings.contains(sent, "secret") && !strings.contains(sent, "changes_diff") && !strings.contains(sent, "changes_rewind"), sent)
}
