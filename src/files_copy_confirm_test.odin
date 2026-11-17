package main

// fs_copy confirmed in the window's bar (confirm_pending): the parked entry is used up and the copy
// runs once, by the asking agent's rules.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"

@(test)
fs_copy_confirmed_in_the_bar :: proc(t: ^testing.T) {
	when core.TEST_HOOKS {
		context.allocator = runtime.heap_allocator()
		core.inbox_drain()
		state^ = core.State{}
		defer {core.inbox_drain(); state^ = core.State{}}
		base := fmt.tprintf("%s/dhcc-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
		os.make_directory_all(fmt.tprintf("%s/c", base))
		defer os.remove_all(base)
		proj := core.fs_real(base, context.allocator)
		append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(proj), label = "p"})
		_ = os.write_entire_file(fmt.tprintf("%s/c/a.txt", proj), transmute([]u8)string("a"))
		wait :: proc() {
			for i := 0; i < 500 && core.fs_copy_running() > 0; i += 1 {
				core.inbox_drain()
				time.sleep(5 * time.Millisecond)
			}
			core.inbox_drain()
		}
		from, to := fmt.tprintf("%s/c", proj), fmt.tprintf("%s/c2", proj)
		r := core.run_command(core.Fs_Copy{from = from, to = to}, {kind = .Control})
		testing.expect_value(t, r.error, "needs_confirmation")
		if len(state.pending_confirmations) != 1 do return
		// a credential put there while it waits: the agent's rules refuse it at the confirmation
		_ = os.write_entire_file(fmt.tprintf("%s/c/.claude.json.backup", proj), transmute([]u8)string("{}"))
		confirm_pending(strings.clone(state.pending_confirmations[0].token, context.temp_allocator)) // the bar's Confirm
		core.inbox_drain()
		wait()
		testing.expect_value(t, len(state.pending_confirmations), 0)
		testing.expect(t, !os.exists(to), "the agent's copy with a credential in it is refused, not copied without it")
		// without it: once
		os.remove(fmt.tprintf("%s/c/.claude.json.backup", proj))
		r = core.run_command(core.Fs_Copy{from = from, to = to}, {kind = .Control})
		if len(state.pending_confirmations) != 1 do return
		tok := strings.clone(state.pending_confirmations[0].token, context.temp_allocator)
		confirm_pending(tok)
		core.inbox_drain()
		wait()
		testing.expect_value(t, len(state.pending_confirmations), 0)
		testing.expect(t, os.exists(fmt.tprintf("%s/a.txt", to)), "copied")
		confirm_pending(tok) // a second click: nothing pending any more
		core.inbox_drain()
		wait()
		entries, _ := os.read_all_directory_by_path(proj, context.temp_allocator)
		testing.expect_value(t, len(entries), 2)
	}
}
