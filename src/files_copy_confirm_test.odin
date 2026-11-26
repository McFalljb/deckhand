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

// create_file, create_dir, rename_path and delete_path (one path and a batch) asked by an agent and
// confirmed in the bar: the entry is used up, the command runs once, by the agent's rules (a
// credential place made meanwhile still refuses it).
@(test)
file_commands_confirmed_in_the_bar :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	defer {core.inbox_drain(); state^ = core.State{}}
	base := fmt.tprintf("%s/dhfc-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(base)
	defer os.remove_all(base)
	proj := core.fs_real(base, context.allocator)
	append(&state.projects, core.Project{id = core.new_id(), cwd = strings.clone(proj), label = "p"})
	saved := core.fs_trash_fn
	defer core.fs_trash_fn = saved
	core.fs_trash_fn = proc(path: string) -> bool {return os.rename(path, fmt.tprintf("%s.trashed", path)) == nil}
	put :: proc(p: string) {
		os.make_directory_all(core.tdir(p))
		_ = os.write_entire_file(p, transmute([]u8)string("x"))
	}
	AGENT :: core.Caller{kind = .Control}
	// asks, confirms in the bar, and clicks Confirm again: the pending list is empty after each
	confirm :: proc(t: ^testing.T, cmd: core.Command, between: proc() = nil) {
		r := core.run_command(cmd, AGENT)
		testing.expect_value(t, r.error, "needs_confirmation")
		if len(state.pending_confirmations) != 1 do return
		tok := strings.clone(state.pending_confirmations[0].token, context.temp_allocator)
		if between != nil do between()
		confirm_pending(tok)
		core.inbox_drain()
		testing.expect_value(t, len(state.pending_confirmations), 0)
		confirm_pending(tok) // a second click: nothing left to run
		core.inbox_drain()
	}
	// create: once
	f := fmt.tprintf("%s/new.txt", proj)
	confirm(t, core.Create_File{path = f})
	testing.expect(t, os.exists(f), "created")
	d := fmt.tprintf("%s/newdir", proj)
	confirm(t, core.Create_Dir{path = d})
	testing.expect(t, os.is_dir(d), "created")
	// rename: once; into a credential place it stays refused after Confirm
	confirm(t, core.Rename_Path{from = f, to = fmt.tprintf("%s/moved.txt", proj)})
	testing.expect(t, os.exists(fmt.tprintf("%s/moved.txt", proj)) && !os.exists(f), "renamed")
	old, had := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer {if had do os.set_env("PI_CODING_AGENT_DIR", old); else do os.unset_env("PI_CODING_AGENT_DIR")}
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", proj))
	put(fmt.tprintf("%s/agent/auth.json", proj))
	confirm(t, core.Rename_Path{from = fmt.tprintf("%s/agent/auth.json", proj), to = fmt.tprintf("%s/stolen.json", proj)})
	testing.expect(t, os.exists(fmt.tprintf("%s/agent/auth.json", proj)) && !os.exists(fmt.tprintf("%s/stolen.json", proj)), "the agent's rules refuse it after Confirm")
	// delete one path: a folder that became a credential place while it waited stays
	h := fmt.tprintf("%s/home1", proj)
	put(fmt.tprintf("%s/notes.txt", h))
	confirm(t, core.Delete_Path{path = h}, proc() {
		for p in state.projects do _ = os.write_entire_file(fmt.tprintf("%s/home1/.credentials.json", p.cwd), transmute([]u8)string("{}"))
		time.sleep(1100 * time.Millisecond) // claude_marked remembers a folder for a second (the user takes longer to click)
	})
	testing.expect(t, os.is_dir(h) && !os.exists(fmt.tprintf("%s.trashed", h)), "refused by the agent's rules")
	// and an ordinary one goes once
	g := fmt.tprintf("%s/g.txt", proj)
	put(g)
	confirm(t, core.Delete_Path{path = g})
	testing.expect(t, !os.exists(g) && os.exists(fmt.tprintf("%s.trashed", g)), "trashed")
	// a batch: the same
	b1, b2 := fmt.tprintf("%s/b1", proj), fmt.tprintf("%s/b2", proj)
	put(fmt.tprintf("%s/x", b1))
	put(fmt.tprintf("%s/x", b2))
	confirm(t, core.Delete_Path{paths = {b1, b2}}, proc() {
		for p in state.projects do _ = os.write_entire_file(fmt.tprintf("%s/b2/.claude.json", p.cwd), transmute([]u8)string("{}"))
		time.sleep(1100 * time.Millisecond) // claude_marked remembers a folder for a second (the user takes longer to click)
	})
	testing.expect(t, os.is_dir(b1) && os.is_dir(b2), "nothing moved: b2 is a credential place now")
	os.remove(fmt.tprintf("%s/b2/.claude.json", proj))
	time.sleep(1100 * time.Millisecond) // the remembered mark expires
	confirm(t, core.Delete_Path{paths = {b1, b2}})
	testing.expect(t, !os.exists(b1) && !os.exists(b2), "both trashed, once")
}
