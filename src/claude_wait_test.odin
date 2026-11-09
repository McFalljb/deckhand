package main

// claude_wait_idle (claude_wait.odin; `./build.sh test`): when a wait on a Claude tab ends. Same
// rules as core_test.odin: shared global State, one thread, harmless processes (`sleep` stands in
// for claude). The ticks are given (claude_wait_tick(now)), so no test sleeps.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"

@(private = "file")
W_UI :: core.Caller{kind = .UI}
@(private = "file")
W_SCRIPT :: core.Caller{kind = .Script}
@(private = "file")
W_CONTROL :: core.Caller{kind = .Control}

@(private = "file")
w_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	core.claude_wait_reset()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT},
	}
	core.persist = {}
	core.claude_installed_probe = stand_in_installed // the stand-in claude counts as installed
	core.platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	return runtime.heap_allocator()
}

// A project at a temp folder, one open session (its pi a `sleep`) and a Claude tab in it.
@(private = "file")
w_claude :: proc(t: ^testing.T, tag: string) -> (sess, id: u64) {
	d := fmt.aprintf("%s/deckhand-cwait-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	if r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:])); r != nil do d = strings.clone(string(r))
	pid := core.run_command(core.Add_Project{cwd = d}, W_UI).created_id
	r := core.run_command(core.New_Chat{project_id = pid}, W_UI)
	testing.expect(t, r.ok, r.error)
	sess = r.created_id
	r = core.run_command(core.New_Claude_Tab{session = sess}, W_UI)
	testing.expect(t, r.ok, r.error)
	return sess, r.created_id
}

@(private = "file")
w_osc :: proc(id: u64, st: core.Prog_State) {
	core.run_command(core.Program_Status{tab_id = id, summary = {state = st, app = "claude-code", records = 1, progress = -1}})
}

@(private = "file")
w_after :: proc(t0: time.Tick, ms: int) -> time.Tick {return time.tick_add(t0, time.Duration(ms) * time.Millisecond)}

// Idle means: its hooks say idle, Claude's own OSC 7501 is neither working nor blocked, nothing
// held for it, the user typing nothing; and that holds CLAUDE_WAIT_SETTLE.
@(test)
claude_wait_idle_conditions :: proc(t: ^testing.T) {
	context.allocator = w_reset()
	ends: map[u64]string
	core.claude_wait_test_finished = &ends
	defer core.claude_wait_test_finished = nil
	_, id := w_claude(t, "cond")
	_, tab, _ := core.claude_tab_of(id)
	t0 := time.tick_now()
	r := core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 60_000}, W_CONTROL, 101)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, r.pending, "long-running")
	settle := int(core.CLAUDE_WAIT_SETTLE / time.Millisecond)
	// starting (no hook yet): waits
	core.claude_wait_tick(w_after(t0, 10))
	core.claude_wait_tick(w_after(t0, 10 + 2 * settle))
	testing.expect(t, 101 not_in ends, "Claude is starting")
	// the hooks say idle but Claude's OSC 7501 says working: waits
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "idle"}, W_SCRIPT)
	w_osc(id, .Working)
	core.claude_wait_tick(w_after(t0, 1000))
	core.claude_wait_tick(w_after(t0, 1000 + 2 * settle))
	testing.expect(t, 101 not_in ends, "hooks idle, OSC 7501 working")
	testing.expect_value(t, core.claude_wait_why(tab), "Claude is working")
	// blocked per OSC 7501 (a dialog before its hook): waits
	w_osc(id, .Blocked)
	core.claude_wait_tick(w_after(t0, 2000))
	core.claude_wait_tick(w_after(t0, 2000 + 2 * settle))
	testing.expect(t, 101 not_in ends, "OSC 7501 blocked")
	// both idle, but a text is held for it: waits
	w_osc(id, .Idle)
	testing.expect(t, core.run_command(core.Claude_Prompt{tab_id = id, text = "next"}, W_CONTROL).ok)
	core.claude_wait_tick(w_after(t0, 3000))
	core.claude_wait_tick(w_after(t0, 3000 + 2 * settle))
	testing.expect(t, 101 not_in ends, "a held text")
	testing.expect_value(t, core.claude_wait_why(tab), "1 held text waits to go")
	testing.expect(t, core.run_command(core.Claude_Held_Op{tab_id = id, op = "drop"}, W_UI).ok)
	// the user is typing: waits
	core.claude_note_typed(tab)
	core.claude_wait_tick(w_after(t0, 4000))
	core.claude_wait_tick(w_after(t0, 4000 + 2 * settle))
	testing.expect(t, 101 not_in ends, "the user is typing")
	testing.expect_value(t, core.claude_wait_why(tab), "the user is typing in it")
	// their message goes and Claude's turn ends: idle, but only after it held CLAUDE_WAIT_SETTLE
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "submitted"}, W_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "idle"}, W_SCRIPT)
	testing.expect_value(t, core.claude_wait_why(tab), "")
	core.claude_wait_tick(w_after(t0, 5000))
	testing.expect(t, 101 not_in ends, "not settled yet")
	// a flicker back to working restarts the settle
	w_osc(id, .Working)
	core.claude_wait_tick(w_after(t0, 5000 + settle / 2))
	w_osc(id, .Idle)
	core.claude_wait_tick(w_after(t0, 5000 + settle + 10))
	testing.expect(t, 101 not_in ends, "the settle restarted")
	core.claude_wait_tick(w_after(t0, 5000 + 2 * settle + 20))
	testing.expect(t, 101 in ends, "idle")
	testing.expect_value(t, core.json_path(ends[101], "ok"), "true")
	testing.expect_value(t, core.claude_wait_count(), 0)
}

// The timeout, the tab exiting, the requester cancelling; who may wait.
@(test)
claude_wait_idle_ends_and_refusals :: proc(t: ^testing.T) {
	context.allocator = w_reset()
	ends: map[u64]string
	core.claude_wait_test_finished = &ends
	defer core.claude_wait_test_finished = nil
	sess, id := w_claude(t, "ends")
	_, tab, _ := core.claude_tab_of(id)
	// a timeout says why it is still not idle
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "submitted"}, W_SCRIPT)
	r := core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 500}, W_CONTROL, 201)
	testing.expect(t, r.ok && r.pending, r.error)
	core.claude_wait_tick(w_after(time.tick_now(), 100))
	testing.expect(t, 201 not_in ends)
	core.claude_wait_tick(w_after(time.tick_now(), 1000))
	testing.expect(t, 201 in ends, "timed out")
	testing.expect_value(t, core.json_path(ends[201], "ok"), "false")
	testing.expect_value(t, core.json_path(ends[201], "data.code"), "timeout")
	testing.expect(t, strings.contains(core.json_path(ends[201], "error"), "Claude is working"), ends[201])
	// the requester cancels (or its connection closes)
	testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id}, W_CONTROL, 202).pending)
	testing.expect(t, core.run_command(core.Request_Cancel{request_id = 202}).ok)
	testing.expect_value(t, core.json_path(ends[202], "data.code"), "cancelled")
	testing.expect_value(t, core.claude_wait_count(), 0)
	// the tab's Claude exits: tab_gone
	testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 60_000}, W_SCRIPT, 203).pending)
	tab.status = .Exited
	core.claude_wait_tick()
	testing.expect_value(t, core.json_path(ends[203], "data.code"), "tab_gone")
	// not running: refused at once
	r = core.run_command(core.Claude_Wait_Idle{tab_id = id}, W_CONTROL, 204)
	testing.expect(t, !r.ok && !r.pending)
	testing.expect_value(t, r.error, "Claude is not running in this tab")
	tab.status = .Running
	// not a Claude tab
	pitab := core.find_session(sess).tabs[0].id
	testing.expect_value(t, core.run_command(core.Claude_Wait_Idle{tab_id = pitab}, W_CONTROL, 205).error, "no such Claude tab")
	// tab callers (pi tabs' bridges, Claude tabs' CLI) may not: Atlas, scripts and the user may
	testing.expect_value(t, core.run_command(core.Claude_Wait_Idle{tab_id = id}, core.Caller{kind = .Panel, tab_id = pitab}, 206).error, "not allowed for this caller")
	testing.expect_value(t, core.run_command(core.Claude_Wait_Idle{tab_id = id}, core.Caller{kind = .Panel, tab_id = id, claude = true}, 207).error, "not allowed for this caller")
	// a caller bound to that tab never waits on itself
	testing.expect_value(t, core.run_command(core.Claude_Wait_Idle{tab_id = id}, core.Caller{kind = .Control, tab_id = id}, 208).error, "a caller cannot act on its own tab")
	testing.expect_value(t, core.claude_wait_count(), 0)
	// the wire: parsed, listed for control and not for a tab's callers
	c, err := core.parse_command(`{"type":"claude_wait_idle","tab_id":7,"timeout_ms":1500}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	w, is := c.(core.Claude_Wait_Idle)
	testing.expect(t, is && w.tab_id == 7 && w.timeout_ms == 1500)
	testing.expect_value(t, core.command_type(c), "claude_wait_idle")
	spec := core.command_spec("claude_wait_idle")
	testing.expect(t, spec != nil && spec.long_running)
	testing.expect(t, core.who_allows(.Control, spec.who) && core.who_allows(.Script, spec.who) && !core.who_allows(.Panel, spec.who))
}

// Review round 1: waits are capped per requester connection (an orphaned wait blocks only its
// own connection), a restart in the same drain is not the same Claude, timeouts are clamped, a
// dropped held prompt ends the wait that names it, and a timer drives the waits while frames stop.
@(test)
claude_wait_review_1 :: proc(t: ^testing.T) {
	context.allocator = w_reset()
	ends: map[u64]string
	core.claude_wait_test_finished = &ends
	defer core.claude_wait_test_finished = nil
	sess, id := w_claude(t, "rev1")
	_, tab, ct := core.claude_tab_of(id)
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "submitted"}, W_SCRIPT)
	// per connection: request ids 1000.. from connection 1, 2000.. from connection 2
	core.claude_wait_conn_of = proc(request_id: u64) -> u64 {return request_id / 1000}
	defer core.claude_wait_conn_of = nil
	for i in 0 ..< core.CLAUDE_WAITS_PER_CONN do testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id}, W_CONTROL, u64(1000 + i)).pending)
	r := core.run_command(core.Claude_Wait_Idle{tab_id = id}, W_CONTROL, 1999)
	testing.expect(t, !r.ok && !r.pending, "the connection's cap")
	testing.expect(t, strings.contains(r.error, "from this connection"), r.error)
	testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id}, W_CONTROL, 2000).pending, "another connection still may")
	for i in 0 ..< core.CLAUDE_WAITS_PER_CONN do core.run_command(core.Request_Cancel{request_id = u64(1000 + i)})
	core.run_command(core.Request_Cancel{request_id = 2000})
	testing.expect_value(t, core.claude_wait_count(), 0)
	// a timer drives the waits (and held texts) while frames are paused: wanted while any exist
	testing.expect(t, !core.claude_wait_timer_wanted())
	testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 60_000}, W_SCRIPT, 3001).pending)
	testing.expect(t, core.claude_wait_timer_wanted(), "a wait")
	tab.status = .Exited
	core.run_command(core.Claude_Wait_Tick{}) // the timer's command runs the tick
	testing.expect_value(t, core.json_path(ends[3001], "data.code"), "tab_gone")
	testing.expect(t, !core.claude_wait_timer_wanted())
	tab.status = .Running
	testing.expect(t, core.run_command(core.Claude_Prompt{tab_id = id, text = "later"}, W_CONTROL).ok)
	testing.expect(t, core.claude_wait_timer_wanted(), "a held text")
	testing.expect(t, core.run_command(core.Claude_Held_Op{tab_id = id, op = "drop"}, W_UI).ok)
	// the exit and a restart in one drain: not the same Claude any more
	testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = 60_000}, W_SCRIPT, 3002).pending)
	tab.status = .Exited
	s := core.find_session(sess)
	testing.expect(t, core.claude_start(s, core.term_of(id), id, ct, s.cwd))
	tab.status = .Running
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "idle"}, W_SCRIPT)
	core.claude_wait_tick(w_after(time.tick_now(), 10))
	core.claude_wait_tick(w_after(time.tick_now(), 1000))
	testing.expect_value(t, core.json_path(ends[3002], "data.code"), "tab_gone")
	// a huge timeout_ms is clamped, not wrapped into the past
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "submitted"}, W_SCRIPT)
	testing.expect(t, core.run_command(core.Claude_Wait_Idle{tab_id = id, timeout_ms = max(u64)}, W_SCRIPT, 3003).pending)
	core.claude_wait_tick(w_after(time.tick_now(), 1000))
	testing.expect(t, 3003 not_in ends, "no instant timeout")
	core.run_command(core.Request_Cancel{request_id = 3003})
	// the user drops the held prompt a wait names: it ends with code dropped
	r = core.run_command(core.Claude_Prompt{tab_id = id, text = "do it"}, W_CONTROL)
	pid := core.json_path(r.data, "id")
	testing.expect(t, pid != "" && pid != "0", r.data)
	testing.expect(t, core.run_command(parse_ok(t, fmt.tprintf(`{{"type":"claude_wait_idle","tab_id":%d,"prompt_id":%s}}`, id, pid)), W_SCRIPT, 3004).pending)
	testing.expect(t, core.run_command(core.Claude_Held_Op{tab_id = id, op = "drop"}, W_UI).ok)
	core.claude_wait_tick(w_after(time.tick_now(), 10))
	testing.expect_value(t, core.json_path(ends[3004], "data.code"), "dropped")
	testing.expect_value(t, core.json_path(ends[3004], "ok"), "false")
	testing.expect_value(t, core.claude_wait_count(), 0)
}

@(private = "file")
parse_ok :: proc(t: ^testing.T, s: string) -> core.Command {
	c, err := core.parse_command(s, context.temp_allocator)
	testing.expect_value(t, err, "")
	return c
}
