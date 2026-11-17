package main

// Sessions started outside Deckhand show without a manual Rescan (core.rescan_when_active,
// commands.odin): the window coming to the front runs one, at most once every
// RESCAN_ON_ACTIVE since the last scan began, never while one runs, and in tests only when asked.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(test)
rescan_when_window_active :: proc(t: ^testing.T) {
	when core.TEST_HOOKS {
		context.allocator = runtime.heap_allocator()
		base := fmt.tprintf("%s/pd-rescan-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
		old_dir := os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator)
		os.set_env("PI_CODING_AGENT_DIR", base)
		saved_active := app.window_active
		defer {
			if old_dir == "" do os.unset_env("PI_CODING_AGENT_DIR")
			else do os.set_env("PI_CODING_AGENT_DIR", old_dir)
			os.remove_all(base)
			core.rescan_on_active_tests = false
			app.window_active = saved_active
			client_test_facts()
			core.inbox_drain()
		}
		long_ago := time.tick_add(time.tick_now(), -core.RESCAN_ON_ACTIVE - time.Second)
		// pi ran in a terminal: its session is in the store, not in Deckhand's list
		d := fmt.tprintf("%s/sessions/--nowhere-outside--", base)
		os.make_directory_all(d)
		_ = os.write_entire_file(fmt.tprintf("%s/2026-11-16T10-00-00-000Z_s1.jsonl", d), transmute([]u8)string(`{"type":"session","version":3,"id":"s1","cwd":"/nowhere/outside"}` + "\n"))
		listed :: proc() -> bool {
			for p in state.projects do if p.cwd == "/nowhere/outside" do return true
			return false
		}
		testing.expect(t, !listed(), "not listed before")
		front :: proc() {
			app.window_active = false
			client_test_facts()
			core.inbox_drain()
			app.window_active = true
			client_test_facts()
			core.inbox_drain()
		}
		// unit tests: not unless asked
		core.rescan_at = long_ago
		front()
		testing.expect(t, core.scan_thread == nil, "a unit test that does not ask: none")
		core.rescan_on_active_tests = true
		// within RESCAN_ON_ACTIVE of the last scan: none
		core.rescan_at = time.tick_now()
		front()
		testing.expect(t, core.scan_thread == nil, "within RESCAN_ON_ACTIVE: none")
		// later: the window to the front runs one
		core.rescan_at = long_ago
		front()
		testing.expect(t, core.scan_thread != nil, "a Rescan runs")
		// never while one runs
		started := core.rescan_at
		testing.expect(t, time.tick_diff(long_ago, started) > core.RESCAN_ON_ACTIVE, "the Rescan is the last scan")
		core.rescan_at = long_ago
		testing.expect(t, !core.rescan_when_active(), "not while one runs")
		core.rescan_at = started
		deadline := time.tick_now()
		for core.scan_thread != nil && time.tick_since(deadline) < 10 * time.Second {
			core.inbox_drain()
			time.sleep(5 * time.Millisecond)
		}
		testing.expect(t, core.scan_thread == nil, "the Rescan finished")
		testing.expect(t, listed(), "the outside session's project listed")
		// it counts as the last scan: the next activation waits again
		front()
		testing.expect(t, core.scan_thread == nil, "just scanned: none")
	}
}
